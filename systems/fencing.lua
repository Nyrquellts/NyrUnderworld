--- Somewhere for stolen things to go.
--
-- Theft without a buyer is a hobby. A car taken from a street is worth nothing
-- until somebody will pay for it, and a shop that will not touch it is most
-- shops. This is the other end of the crime economy: a fence that asks no
-- questions, pays badly, and is itself a crime to use.
--
-- The rule, a sixth time and in its plainest form here: **a fence decides what
-- it pays, and it pays a fraction**. There is no price argument and no value
-- argument. What a car is worth is written on the car by the server; what a
-- chop shop hands over is a percentage of that, set by the server; and the
-- seller's only decision is whether to walk in.
--
-- What makes this a crime rather than a trade is the record. Selling here
-- writes `crime.handling`, which the police system prices and the memory
-- system already turns into heat when somebody is watching. Neither of those
-- changed to allow it: the offence line and the consequence line were added
-- beside the ones that were already there, which is the whole point of
-- consequence living in its own system.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")
local Vehicles = require("systems.vehicles")

local Fencing = {}

local DEFAULT_CHOP_PERCENT = 30
-- Real milliseconds: somebody waits at the chop shop for this, and the answer
-- tells them how many seconds. Counted in city time, the minute was a single
-- tick at the shipped rate of 60.
local DEFAULT_CHOP_MS = 60 * Clock.MS_PER_SECOND
local UNDERWORLD = "external:underworld"

-- How long a first press at a chop shop stays good once its wait is over, in
-- real milliseconds, for the reason a till's does in shops.lua: presence is
-- asked at each press and never between them, and a first press that never ran
-- out let a car be started on days ahead and paid for with one press.
local ATTEMPT_LIFE_MS = 60 * Clock.MS_PER_SECOND

Fencing.Fence = Entity.define("fnc", {
    fields = {
        place = { type = "id", kind = "prp", required = true },
        name = { type = "string", required = true, max = 48 },
        -- item id -> whole minor units paid per unit. A fence has no buy side:
        -- it does not sell anything, it only takes things off people.
        pays = { type = "table", default = {} },
        -- Whether it will take a car apart.
        chops = { type = "boolean", default = false },
    },
    states = { open = { "shut" }, shut = { "open" } },
    initial = "open",
})

local Fence = Fencing.Fence

--- Where a fence keeps what it has taken in. It has no till of its own: it
--- pays out of the underworld and what it takes in vanishes into it, because a
--- fence that ran out of money would stop being a fence and start being a shop.
function Fencing.counter(fence_id) return "fence:" .. fence_id end

local function check_pays(pays)
    for item, price in pairs(pays) do
        assert(type(item) == "string", "a fence price is keyed by item id")
        assert(math.type(price) == "integer" and price >= 0,
            ("%s has a price that is not whole minor units"):format(item))
    end
    return pays
end

--- opts.chop_percent  what a chop shop pays, as a whole percentage of value
--- opts.chop_ms       how long taking a car apart takes, in real milliseconds
function Fencing.system(opts)
    opts = opts or {}
    local chop_percent = opts.chop_percent or DEFAULT_CHOP_PERCENT
    local chop_ms = opts.chop_ms or DEFAULT_CHOP_MS
    assert(math.type(chop_percent) == "integer" and chop_percent > 0 and chop_percent < 100,
        "a chop rate is a whole percentage between one and ninety-nine")

    return {
        name = "fencing",
        requires = { "characters", "memory", "inventory", "property", "vehicles" },
        install = function(world)
            local fences = world:repository(Fence)
            local jobs = {}          -- actor -> { vehicle, fence, at }

            local function witnesses_of(actor)
                local look = world.services.witnesses
                if type(look) ~= "function" then return {} end
                local seen = {}
                for _, who in ipairs(look(actor) or {}) do
                    if who ~= actor then seen[#seen + 1] = who end
                end
                return seen
            end

            world.services.fencing = {
                fences = fences,
                counter = Fencing.counter,
                --- Put a fence on the map. Not a command, for the same reason
                --- shops are not: what exists in the city is the city's
                --- business.
                open = function(name, place_id, fence_opts)
                    fence_opts = fence_opts or {}
                    local fence, why = fences:create({
                        place = place_id, name = name,
                        pays = check_pays(fence_opts.pays or {}),
                        chops = fence_opts.chops == true,
                    })
                    if not fence then error(("cannot open %s: %s"):format(name, tostring(why)), 2) end
                    world.services.inventory:define_container(Fencing.counter(fence.id),
                        { label = name })
                    return fence
                end,
            }

            local function fence_at(ctx, fence_id)
                local fence = fences:load(fence_id)
                if not fence then return nil, ctx.refuse("no_such_fence", "There is nobody there.") end
                if fence.state ~= "open" then
                    return nil, ctx.refuse("shut", ("%s is not around."):format(fence:get("name")))
                end
                local check = world.services.proximity
                if type(check) ~= "function" then
                    return nil, ctx.refuse("no_proximity", "The server cannot tell where you are.")
                end
                if check(ctx.actor, fence:get("place")) ~= true then
                    return nil, ctx.refuse("too_far", "You are not there.")
                end
                return fence, nil
            end

            world:define("fence.list", {
                read_only = true,
                summary = "what a fence will take",
                rate = { per_minute = 30 },
                args = { fence = { type = "id", kind = "fnc", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local fence, refused = fence_at(ctx, args.fence)
                    if refused then return refused end
                    local lines = {}
                    for item, price in pairs(fence:get("pays")) do
                        local definition = world.services.items:get(item)
                        lines[#lines + 1] = { item = item, pays = price,
                                              label = definition and definition.label or item }
                    end
                    table.sort(lines, function(a, b) return a.item < b.item end)
                    return ctx.ok({ name = fence:get("name"), chops = fence:get("chops"),
                                    lines = lines })
                end,
            })

            world:define("fence.sell", {
                summary = "hand something over and take what you are given",
                rate = { per_minute = 30 },
                -- No price field. A fence pays what a fence pays.
                args = {
                    fence = { type = "id", kind = "fnc", required = true },
                    item = { type = "string", required = true, max = 32 },
                    count = { type = "integer", required = true, min = 1, max = 1000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local fence, refused = fence_at(ctx, args.fence)
                    if refused then return refused end

                    local price = fence:get("pays")[args.item]
                    if not price then
                        return ctx.refuse("not_wanted", ("%s has no use for that."):format(fence:get("name")))
                    end
                    -- The rule shop.sell keeps. A fence asks no questions about
                    -- where a thing came from, but a passport is not for sale to
                    -- anybody, and without this one could be handed over for cash.
                    local definition = world.services.items:get(args.item)
                    if definition and not definition.sellable then
                        return ctx.refuse("not_sellable", ("A %s is not something you can sell.")
                            :format(definition.label))
                    end
                    local inventory = world.services.inventory
                    if inventory:count(ctx.actor, args.item) < args.count then
                        return ctx.refuse("not_carrying", "You do not have that many.")
                    end

                    local total = Money.from_minor(price):times(args.count)
                    local operation = ctx.operation_id
                        or ("fence:%s:%s:%d"):format(fence.id, ctx.actor, ctx.now)
                    -- The money comes from outside the simulated economy, the
                    -- same way an out-of-town employer pays wages. A fence is
                    -- somebody else's money arriving; it is not a shop with a
                    -- till that can be robbed.
                    local paid, pay_why = world.ledger:transfer(operation, UNDERWORLD,
                        Characters.wallet(ctx.actor), total,
                        { reason = "fenced", item = args.item, count = args.count })
                    if not paid then return ctx.refuse("cannot_pay", pay_why) end

                    local moved, move_why = inventory:move("handed:" .. operation,
                        ctx.actor, Fencing.counter(fence.id), args.item, args.count,
                        { reason = "fenced" })
                    if not moved then
                        world.ledger:transfer("unfence:" .. operation,
                            Characters.wallet(ctx.actor), UNDERWORLD, total, { reason = "refund" })
                        return ctx.refuse("not_carrying", "You do not have those.", { detail = move_why })
                    end

                    local seen = witnesses_of(ctx.actor)
                    if definition and definition.illegal then
                        -- One record per request. Built from who and when, two
                        -- sales in one tick shared an id, and the second was
                        -- never written down, heat and all.
                        world.services.remember("handling:" .. ctx.operation_id, {
                            subject = ctx.actor, kind = "crime.handling", weight = 15,
                            place = fence:get("place"), witnesses = seen,
                            meta = { item = args.item, count = args.count, fence = fence:get("name") },
                        })
                    end
                    ctx.emit("fence.sold", { fence = fence.id, seller = ctx.actor,
                        item = args.item, count = args.count, paid = total:to_minor(),
                        witnessed = #seen > 0 })
                    return ctx.ok({ paid = total:to_minor(), witnessed = #seen > 0 })
                end,
            })

            world:define("fence.chop", {
                summary = "have a car taken apart",
                rate = { per_minute = 6 },
                -- No value field and no price field. What the car is worth is
                -- written on the car, and what this pays is a fraction of it.
                args = {
                    fence = { type = "id", kind = "fnc", required = true },
                    vehicle = { type = "id", kind = "veh", required = true },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local fence, refused = fence_at(ctx, args.fence)
                    if refused then return refused end
                    if not fence:get("chops") then
                        return ctx.refuse("not_a_chop_shop", ("%s does not do cars."):format(fence:get("name")))
                    end

                    local cars = world.services.vehicles.cars
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if car.state == "wrecked" then
                        return ctx.refuse("already_gone", "That is already parts.")
                    end
                    -- It has to be here, with them, which means they drove it
                    -- in. A car chopped from across town is a car nobody stole.
                    if car:get("driver") ~= ctx.actor or car.state ~= "out" then
                        return ctx.refuse("not_yours_to_chop", "Bring it in first.")
                    end

                    -- Real time, turned into city time at the rate the clock
                    -- runs when it is asked.
                    local rate = world.clock:rate()
                    local wait = math.ceil(chop_ms * rate)
                    local jobbing = jobs[ctx.actor]
                    if jobbing and ctx.now - jobbing.at > math.ceil((chop_ms + ATTEMPT_LIFE_MS) * rate) then
                        jobbing = nil
                    end
                    if not jobbing or jobbing.vehicle ~= car.id then
                        jobs[ctx.actor] = { vehicle = car.id, fence = fence.id, at = ctx.now }
                        return ctx.refuse("working", "This takes a while.",
                            { seconds = chop_ms // Clock.MS_PER_SECOND })
                    end
                    if ctx.now - jobbing.at < wait then
                        local left = math.ceil((wait - (ctx.now - jobbing.at)) / rate)
                        return ctx.refuse("working", "Not yet.",
                            { seconds = left // Clock.MS_PER_SECOND + 1 })
                    end
                    jobs[ctx.actor] = nil

                    local owner = world.services.vehicles.holder(car.id)
                    local stolen = owner ~= nil and owner ~= ctx.actor
                    local cut = Money.from_minor(car:get("value")):percent(chop_percent)
                    local operation = ("chop:%s:%d"):format(car.id, ctx.now)

                    if cut:is_positive() then
                        local paid, why = world.ledger:transfer(operation, UNDERWORLD,
                            Characters.wallet(ctx.actor), cut,
                            { reason = "chopped", plate = car:get("plate") })
                        if not paid then return ctx.refuse("cannot_pay", why) end
                    end

                    -- The car stops existing as a car. Ownership is released
                    -- rather than transferred, because nobody owns parts, and
                    -- the register keeps the chain so the write-off is
                    -- auditable: a car that vanished has a last line saying so.
                    if owner then
                        world.ownership:release("chopped:" .. operation, car.id, owner,
                            { reason = "chopped", by = ctx.actor })
                    end
                    car:patch({ stolen = false })
                    car:set("driver", nil)
                    car:transition("wrecked", { reason = "chopped" })
                    cars:save(car)

                    local seen = witnesses_of(ctx.actor)
                    world.services.remember(operation, {
                        subject = ctx.actor, kind = "crime.handling", weight = 30,
                        place = fence:get("place"), witnesses = seen,
                        involved = (stolen and owner and { owner }) or nil,
                        meta = { plate = car:get("plate"), model = car:get("model"),
                                 paid = cut:to_minor(), stolen = stolen,
                                 fence = fence:get("name") },
                    })
                    ctx.emit("fence.chopped", { fence = fence.id, vehicle = car.id,
                        by = ctx.actor, paid = cut:to_minor(), stolen = stolen,
                        witnessed = #seen > 0 })
                    return ctx.ok({ paid = cut:to_minor(), witnessed = #seen > 0 })
                end,
            })

            world:on("world.loaded", function()
                jobs = {}
                for _, fence in ipairs(fences:all()) do
                    world.services.inventory:define_container(Fencing.counter(fence.id),
                        { label = fence:get("name") })
                end
            end, { label = "fencing:load" })

            world:on("character.released", function(payload)
                jobs[payload.character] = nil
            end, { label = "fencing:release" })
        end,
    }
end

Fencing.Vehicles = Vehicles

return Fencing
