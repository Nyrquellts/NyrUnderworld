--- Somewhere to spend it, and somewhere worth robbing.
--
-- This is the job that turns a set of systems into a loop. Work pays. A shop
-- takes the money and hands over goods. The goods are worth taking. Taking
-- them is a crime, and the record and the police already know exactly what to
-- do with one, because `crime.robbery` has had a consequence line and a price
-- in the offence table since before anything could produce it.
--
-- Nothing in police.lua or memory.lua changes to make this work. That is the
-- payoff of keeping consequence in its own system: a new crime is a record
-- kind that something finally emits.
--
-- The rule, the same shape as the two before it:
--
--   In work, the player never says what a job pays.
--   In police, the officer never says what the charge is.
--   Here, the buyer never says what anything costs.
--
-- A price comes out of the shop's own table at the moment of sale. There is no
-- price argument, so there is nothing to forge, and a shop that changes its
-- prices changes them for everybody at once because there is one copy.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local Shops = {}

-- Real milliseconds, where the others here are city ones: somebody stands at
-- the counter for this, and the answer tells them how many seconds. Counted in
-- city time, the forty-five seconds were one tick at the shipped rate of 60.
local DEFAULT_ROB_MS = 45 * Clock.MS_PER_SECOND
local DEFAULT_MAX_TAKE = 100000        -- a thousand, in minor units
local DEFAULT_SHUT_MS = 2 * Clock.MS_PER_HOUR
local DEFAULT_FLOAT = 50000            -- five hundred, in minor units
local SUPPLIER = "external:supplier"

-- How long a first press at a till stays good once its wait is over, in real
-- milliseconds. The server can only ask where somebody is when they press, and
-- a first press that never ran out let a robber press once, walk off, and take
-- the till days later with a single press. A minute is longer than anybody still
-- at the counter takes to press again, and nothing like the days a wait could
-- be started ahead.
local ATTEMPT_LIFE_MS = 60 * Clock.MS_PER_SECOND

Shops.Shop = Entity.define("shp", {
    fields = {
        place = { type = "id", kind = "prp", required = true },
        name = { type = "string", required = true, max = 48 },
        -- item id -> { buy = what a customer pays, sell = what the shop pays }
        -- Whole minor units, both of them, decided here and nowhere else.
        prices = { type = "table", required = true },
        -- item id -> how many it carries when full
        restock = { type = "table", default = {} },
        slots = { type = "integer", default = 120, min = 1, max = 1000 },
        weight = { type = "integer", default = 5000000, min = 1 },
        -- What the till is floated back up to every morning, in minor units.
        -- Kept on the shop because the server installs this system with no
        -- options: the morning top-up used the system's figure, so a shop's
        -- own float only ever set its first day.
        float = { type = "integer", min = 0 },
        -- The city time a robbed shop opens again. Written on the shop because
        -- a timer is not: reopening used to be a timer and nothing else, and a
        -- shop saved while robbed never opened again after a restart.
        reopens = { type = "integer", min = 0 },
    },
    states = {
        open = { "shut", "robbed" },
        shut = { "open" },
        -- Not shut and not open: it was just robbed, and it opens again on its
        -- own. A shop that closed forever after one robbery would be robbed
        -- once and then be scenery.
        robbed = { "open" },
    },
    initial = "open",
})

local Shop = Shops.Shop

--- The container a shop keeps its stock in, and the account it keeps its money
--- in. The same name in two registries, because it is the same shop.
function Shops.counter(shop_id) return "shop:" .. shop_id end

-- A price entry has a buy side, a sell side, or both. Absent means the shop
-- does not do that: no buy price is a scrapyard that takes metal and sells
-- nothing, no sell price is a chemist that will not buy your medicine back.
--
-- The one combination that is refused outright is paying more than it charges.
-- That is not a pricing decision, it is a money printer: buy low from the shop,
-- sell high to the same shop, repeat until the economy is meaningless. It is
-- checked here so it fails at boot with the item named, which is exactly how
-- it was caught on the first real server start.
local function check_prices(prices)
    for item, price in pairs(prices) do
        assert(type(item) == "string", "a price is keyed by item id")
        assert(type(price) == "table", ("%s needs a price table"):format(item))
        assert(price.buy ~= nil or price.sell ~= nil,
            ("%s has neither a buy price nor a sell price, so the shop does nothing with it"):format(item))
        assert(price.buy == nil or (math.type(price.buy) == "integer" and price.buy >= 0),
            ("%s has a buy price that is not whole minor units"):format(item))
        assert(price.sell == nil or (math.type(price.sell) == "integer" and price.sell >= 0),
            ("%s has a sell price that is not whole minor units"):format(item))
        assert(price.buy == nil or price.sell == nil or price.sell <= price.buy,
            ("%s would pay more than it charges, which is a money printer"):format(item))
    end
    return prices
end

--- opts.rob_ms    how long taking a till takes, in real milliseconds
--- opts.max_take  the most a single robbery yields, in minor units
--- opts.shut_ms   how long a shop stays shut after being robbed, in city milliseconds
function Shops.system(opts)
    opts = opts or {}
    local rob_ms = opts.rob_ms or DEFAULT_ROB_MS
    local max_take = opts.max_take or DEFAULT_MAX_TAKE
    local shut_ms = opts.shut_ms or DEFAULT_SHUT_MS
    assert(math.type(max_take) == "integer" and max_take > 0, "a maximum take is whole minor units")

    return {
        name = "shops",
        requires = { "characters", "memory", "inventory", "property" },
        install = function(world)
            local shops = world:repository(Shop)
            local attempts = {}        -- actor -> { shop, at }

            local function near(actor, target)
                local check = world.services.proximity
                if type(check) ~= "function" then return nil end
                return check(actor, target) == true
            end

            local function witnesses_of(actor)
                local look = world.services.witnesses
                if type(look) ~= "function" then return {} end
                local seen = {}
                for _, who in ipairs(look(actor) or {}) do
                    if who ~= actor then seen[#seen + 1] = who end
                end
                return seen
            end

            local function till_of(shop) return world.ledger:balance(Shops.counter(shop.id)) end

            -- How many of an item a stockroom keeps: its restock level if the
            -- shop sells it, and none if it does not.
            local function level_of(shop, item)
                local price = shop:get("prices")[item]
                local wanted = shop:get("restock")[item]
                if not (price and price.buy) then return 0 end
                if math.type(wanted) ~= "integer" or wanted < 0 then return 0 end
                return wanted
            end

            --- Fill a stockroom to its restock levels. Returns how many items
            --- were filled, and a sentence for each that could not be placed.
            local function restock(shop)
                local inventory = world.services.inventory
                local counter = Shops.counter(shop.id)
                local items = {}
                for item in pairs(shop:get("restock")) do items[#items + 1] = item end
                table.sort(items)
                local filled, unplaced = 0, {}
                for _, item in ipairs(items) do
                    local wanted = level_of(shop, item)
                    if wanted > 0 and world.services.items:has(item) then
                        local have = inventory:count(counter, item)
                        if have < wanted then
                            -- Stock enters the world from outside, across a
                            -- named reason, the same way money does.
                            local ok, why = inventory:spawn(
                                ("restock:%s:%s:%d"):format(shop.id, item, world.clock:now()),
                                counter, item, wanted - have, { reason = "delivery" })
                            if ok then
                                filled = filled + 1
                            else
                                unplaced[#unplaced + 1] = { item = item,
                                    line = ("%s could not be restocked with %d %s: %s")
                                        :format(shop:get("name"), wanted - have, item, tostring(why)) }
                            end
                        end
                    end
                end
                return filled, unplaced
            end

            -- What a shop buys and never sells, and what people sold it past
            -- what it carries when full, went into the stockroom and nothing
            -- took it out again. Once the stockroom was full, selling to the
            -- shop was refused for good and the delivery could not be placed,
            -- so what it did sell ran out too. The delivery takes it back.
            local function clear_out(shop, stamp)
                local inventory = world.services.inventory
                local counter = Shops.counter(shop.id)
                local held, items = {}, {}
                for _, stack in ipairs(inventory:contents(counter)) do
                    if not held[stack.item] then items[#items + 1] = stack.item end
                    held[stack.item] = (held[stack.item] or 0) + stack.count
                end
                table.sort(items)
                for _, item in ipairs(items) do
                    local surplus = held[item] - level_of(shop, item)
                    if surplus > 0 then
                        inventory:destroy(("returned:%s:%s:%d"):format(shop.id, item, stamp),
                            counter, item, surplus, { reason = "returned to the supplier" })
                    end
                end
            end

            world.services.shops = {
                shops = shops,
                counter = Shops.counter,
                till_of = till_of,
                restock = restock,
                --- Open a shop. Not a command: what exists in the city is the
                --- city's business, never a client asking for it.
                open = function(name, place_id, shop_opts)
                    shop_opts = shop_opts or {}
                    local shop, why = shops:create({
                        place = place_id,
                        name = name,
                        prices = check_prices(shop_opts.prices or {}),
                        restock = shop_opts.restock,
                        slots = shop_opts.slots,
                        weight = shop_opts.weight,
                        float = shop_opts.float,
                    })
                    if not shop then error(("cannot open %s: %s"):format(name, tostring(why)), 2) end
                    world.services.inventory:define_container(Shops.counter(shop.id),
                        { slots = shop:get("slots"), weight = shop:get("weight"), label = name })
                    if shop_opts.float and shop_opts.float > 0 then
                        world.ledger:transfer("float:" .. shop.id, SUPPLIER,
                            Shops.counter(shop.id), Money.from_minor(shop_opts.float),
                            { reason = "opening float" })
                    end
                    restock(shop)
                    return shop
                end,
            }

            local function shop_at(ctx, shop_id, want_open)
                local shop = shops:load(shop_id)
                if not shop then return nil, ctx.refuse("no_such_shop", "There is no such shop.") end
                if want_open and shop.state ~= "open" then
                    return nil, ctx.refuse("shut", ("%s is not open."):format(shop:get("name")))
                end
                local at = near(ctx.actor, shop:get("place"))
                if at == nil then
                    return nil, ctx.refuse("no_proximity", "The server cannot tell where you are.")
                end
                if not at then return nil, ctx.refuse("too_far", "You are not there.") end
                return shop, nil
            end

            world:define("shop.list", {
                read_only = true,
                summary = "what a shop sells and what it pays",
                rate = { per_minute = 30 },
                args = { shop = { type = "id", kind = "shp", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shop, refused = shop_at(ctx, args.shop, false)
                    if refused then return refused end
                    local inventory = world.services.inventory
                    local counter = Shops.counter(shop.id)
                    local lines = {}
                    for item, price in pairs(shop:get("prices")) do
                        local definition = world.services.items:get(item)
                        lines[#lines + 1] = {
                            item = item,
                            label = definition and definition.label or item,
                            buy = price.buy,
                            sell = price.sell,
                            stock = inventory:count(counter, item),
                        }
                    end
                    table.sort(lines, function(a, b) return a.item < b.item end)
                    return ctx.ok({ name = shop:get("name"), state = shop.state, lines = lines })
                end,
            })

            world:define("shop.buy", {
                summary = "buy something",
                rate = { per_minute = 40 },
                -- No price field. The buyer says what and how many, and the
                -- shop says what that costs.
                args = {
                    shop = { type = "id", kind = "shp", required = true },
                    item = { type = "string", required = true, max = 32 },
                    count = { type = "integer", required = true, min = 1, max = 1000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shop, refused = shop_at(ctx, args.shop, true)
                    if refused then return refused end

                    local price = shop:get("prices")[args.item]
                    if not (price and price.buy) then
                        return ctx.refuse("not_stocked", ("%s does not sell that."):format(shop:get("name")))
                    end
                    local inventory = world.services.inventory
                    local counter = Shops.counter(shop.id)
                    if inventory:count(counter, args.item) < args.count then
                        return ctx.refuse("out_of_stock", "There are not that many.")
                    end
                    -- Asked before the money moves, so a purchase that will not
                    -- fit never becomes money taken for goods not handed over.
                    local fits, why = inventory:would_fit(ctx.actor, args.item, args.count)
                    if not fits then
                        return ctx.refuse("cannot_carry", "You cannot carry that.", { detail = why })
                    end

                    local total = Money.from_minor(price.buy):times(args.count)
                    local operation = ctx.operation_id or ("buy:%s:%s:%d"):format(shop.id, ctx.actor, ctx.now)
                    local paid, pay_why = world.ledger:transfer(operation,
                        Characters.wallet(ctx.actor), counter, total,
                        { reason = "purchase", item = args.item, count = args.count })
                    if not paid then
                        return ctx.refuse("cannot_afford", "You cannot afford that.", { detail = pay_why })
                    end

                    local moved, move_why = inventory:move("goods:" .. operation,
                        counter, ctx.actor, args.item, args.count, { reason = "bought" })
                    if not moved then
                        -- Somebody else took the last one between the check and
                        -- here. The money goes straight back: a sale that did
                        -- not happen must not cost anything.
                        world.ledger:transfer("refund:" .. operation, counter,
                            Characters.wallet(ctx.actor), total, { reason = "refund" })
                        return ctx.refuse("out_of_stock", "Somebody else got the last one.",
                            { detail = move_why })
                    end

                    ctx.emit("shop.bought", { shop = shop.id, buyer = ctx.actor,
                        item = args.item, count = args.count, paid = total:to_minor() })
                    return ctx.ok({ paid = total:to_minor(), count = args.count })
                end,
            })

            world:define("shop.sell", {
                summary = "sell something to a shop",
                rate = { per_minute = 40 },
                args = {
                    shop = { type = "id", kind = "shp", required = true },
                    item = { type = "string", required = true, max = 32 },
                    count = { type = "integer", required = true, min = 1, max = 1000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shop, refused = shop_at(ctx, args.shop, true)
                    if refused then return refused end

                    local price = shop:get("prices")[args.item]
                    if not (price and price.sell) then
                        return ctx.refuse("not_buying", ("%s does not buy that."):format(shop:get("name")))
                    end
                    local definition = world.services.items:get(args.item)
                    if definition and not definition.sellable then
                        return ctx.refuse("not_sellable", ("A %s is not something you can sell.")
                            :format(definition.label))
                    end
                    local inventory = world.services.inventory
                    local counter = Shops.counter(shop.id)
                    if inventory:count(ctx.actor, args.item) < args.count then
                        return ctx.refuse("not_carrying", "You do not have that many.")
                    end
                    local fits, fit_why = inventory:would_fit(counter, args.item, args.count)
                    if not fits then
                        return ctx.refuse("shop_full", "They have no room for those.", { detail = fit_why })
                    end

                    local total = Money.from_minor(price.sell):times(args.count)
                    local operation = ctx.operation_id or ("sell:%s:%s:%d"):format(shop.id, ctx.actor, ctx.now)
                    -- The till pays, so a shop cannot buy what it cannot afford
                    -- and cannot go negative doing it.
                    local paid, pay_why = world.ledger:transfer(operation, counter,
                        Characters.wallet(ctx.actor), total,
                        { reason = "sale", item = args.item, count = args.count })
                    if not paid then
                        return ctx.refuse("till_empty", ("%s cannot pay for those right now.")
                            :format(shop:get("name")), { detail = pay_why })
                    end
                    local moved, move_why = inventory:move("goods:" .. operation,
                        ctx.actor, counter, args.item, args.count, { reason = "sold" })
                    if not moved then
                        world.ledger:transfer("refund:" .. operation, Characters.wallet(ctx.actor),
                            counter, total, { reason = "refund" })
                        return ctx.refuse("not_carrying", "You do not have those.", { detail = move_why })
                    end

                    ctx.emit("shop.sold", { shop = shop.id, seller = ctx.actor,
                        item = args.item, count = args.count, paid = total:to_minor() })
                    return ctx.ok({ paid = total:to_minor(), count = args.count })
                end,
            })

            world:define("shop.rob", {
                summary = "take what is in the till",
                rate = { per_minute = 6 },
                -- No amount field. What is in the till is what is in the till,
                -- and the server is the only thing that knows.
                args = { shop = { type = "id", kind = "shp", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shop, refused = shop_at(ctx, args.shop, true)
                    if refused then return refused end

                    local till = till_of(shop)
                    if not till:is_positive() then
                        return ctx.refuse("nothing_to_take", "There is nothing in the till.")
                    end

                    -- Two steps, so it takes time rather than being a button.
                    -- A first press from too long ago is not this robbery, and
                    -- the wait starts again. Both are real time, turned into
                    -- city time at the rate the clock runs when it is asked.
                    local rate = world.clock:rate()
                    local wait = math.ceil(rob_ms * rate)
                    local attempt = attempts[ctx.actor]
                    if attempt and ctx.now - attempt.at > math.ceil((rob_ms + ATTEMPT_LIFE_MS) * rate) then
                        attempt = nil
                    end
                    if not attempt or attempt.shop ~= shop.id then
                        attempts[ctx.actor] = { shop = shop.id, at = ctx.now }
                        return ctx.refuse("working", "This takes a minute.",
                            { seconds = rob_ms // Clock.MS_PER_SECOND })
                    end
                    if ctx.now - attempt.at < wait then
                        local left = math.ceil((wait - (ctx.now - attempt.at)) / rate)
                        return ctx.refuse("working", "Not yet.",
                            { seconds = left // Clock.MS_PER_SECOND + 1 })
                    end
                    attempts[ctx.actor] = nil

                    -- The take is whatever is actually there, capped. Decided
                    -- here, from the books, and never from the request.
                    local take = till
                    local ceiling = Money.from_minor(max_take)
                    if take > ceiling then take = ceiling end

                    local operation = ("robbery:%s:%d"):format(shop.id, ctx.now)
                    local got, why = world.ledger:transfer(operation,
                        Shops.counter(shop.id), Characters.wallet(ctx.actor), take,
                        { reason = "robbery", shop = shop:get("name") })
                    if not got then
                        return ctx.refuse("nothing_to_take", "The till is empty.", { detail = why })
                    end

                    shop:set("reopens", ctx.now + shut_ms)
                    shop:transition("robbed", { reason = "robbed" })
                    shops:save(shop)

                    -- The record kind police already act on and the offence
                    -- table already prices. Nothing in either system changed to
                    -- make this work.
                    local seen = witnesses_of(ctx.actor)
                    world.services.remember(operation, {
                        subject = ctx.actor, kind = "crime.robbery",
                        weight = math.min(100, take:to_minor() // 1000),
                        place = shop:get("place"),
                        witnesses = seen,
                        meta = { shop = shop:get("name"), taken = take:to_minor() },
                    })
                    ctx.emit("shop.robbed", { shop = shop.id, robber = ctx.actor,
                        taken = take:to_minor(), witnessed = #seen > 0 })
                    return ctx.ok({ taken = take:to_minor(), witnessed = #seen > 0 })
                end,
            })

            -- A delivery every morning, and the till floated back up so a shop
            -- that was cleaned out can still buy things tomorrow.
            local unplaced_said = {}     -- shop id -> item -> true, already reported
            world:daily(6, 0, function(scheduled_for)
                local unsaid = {}
                for _, shop in ipairs(shops:where(function() return true end)) do
                    clear_out(shop, scheduled_for)
                    local _, unplaced = restock(shop)
                    local said, still = unplaced_said[shop.id] or {}, {}
                    for _, miss in ipairs(unplaced) do
                        still[miss.item] = true
                        if not said[miss.item] then unsaid[#unsaid + 1] = miss.line end
                    end
                    if next(still) then unplaced_said[shop.id] = still else unplaced_said[shop.id] = nil end
                    local float = shop:get("float")
                    if float == nil then
                        -- Saved before a shop carried its own float, or opened
                        -- without one: floated to the system's figure every
                        -- morning then, and still.
                        float = opts.float or DEFAULT_FLOAT
                    end
                    local short = Money.from_minor(float):sub(till_of(shop))
                    if short:is_positive() then
                        world.ledger:transfer(
                            ("float:%s:%d"):format(shop.id, world.clock:now()),
                            SUPPLIER, Shops.counter(shop.id), short, { reason = "daily float" })
                    end
                end
                -- A delivery that will not fit is a stockroom smaller than what
                -- it is meant to carry: nothing the city can put right, so it
                -- is said, as this task failing. Only after every shop has had
                -- its delivery, and once until it clears, because the same
                -- mistake five mornings running would stop the task for every
                -- shop in the city.
                if #unsaid > 0 then error(table.concat(unsaid, "; "), 0) end
            end, "shops:delivery")

            -- A robbed shop opens when the time written on it comes. Asked once
            -- a city minute rather than left to a timer, because the time is in
            -- the save and a timer is not: a restart in between changes nothing.
            world:every(Clock.MS_PER_MINUTE, function()
                local now = world.clock:now()
                for _, shop in ipairs(shops:where(function(candidate) return candidate.state == "robbed" end)) do
                    local reopens = shop:get("reopens")
                    if reopens == nil then
                        -- Robbed under a build that kept no time on the shop.
                        -- When it happened is not written down anywhere, so the
                        -- shut time starts now: never shorter than a robbery
                        -- shuts a shop for, and never forever.
                        shop:set("reopens", now + shut_ms)
                        shops:save(shop)
                    elseif reopens <= now then
                        shop:set("reopens", nil)
                        shop:transition("open", { reason = "reopened" })
                        shops:save(shop)
                        world.events:emit("shop.reopened", { shop = shop.id })
                    end
                end
            end, "shops:reopen")

            world:on("world.loaded", function()
                attempts = {}
                for _, shop in ipairs(shops:all()) do
                    world.services.inventory:define_container(Shops.counter(shop.id),
                        { slots = shop:get("slots"), weight = shop:get("weight"),
                          label = shop:get("name") })
                end
            end, { label = "shops:load" })

            world:on("character.released", function(payload)
                attempts[payload.character] = nil
            end, { label = "shops:release" })
        end,
    }
end

return Shops
