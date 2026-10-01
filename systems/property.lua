--- Places, who holds them, and what they cost to keep.
--
-- Property is where several of the earlier promises meet. Who owns it is the
-- ownership register, so two people buying the same flat in the same tick
-- cannot both win. What it costs is the ledger, so rent moves and never
-- appears. When it costs is the scheduler, in city time, so a month of arrears
-- can be tested in milliseconds. What happened to it is the record, so the
-- flat that was seized twice this year is a thing the city knows.
--
-- Two rules shape the rest:
--
--   Being near something is not something a client gets to claim. "I am at the
--   door" is exactly the sort of statement a cheat makes about a door on the
--   other side of the map. The system asks a proximity service, and if no
--   proximity service is installed it refuses. Failing closed is the only
--   acceptable default for a lock.
--
--   Rent does not put anybody in debt. An owner who cannot pay accrues arrears
--   as a count of missed days, not as a negative balance, because a negative
--   balance is money that does not exist and the books would stop summing to
--   nothing. Enough missed days and the place is taken back.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local Property = {}

local COUNCIL = "state:council"
local ESTATE = "external:estate"
local RENT_ACCOUNT = "external:council"
local DEFAULT_GRACE = 3

Property.COUNCIL = COUNCIL

Property.Place = Entity.define("prp", {
    fields = {
        address = { type = "string", required = true, max = 64 },
        -- Adding a kind is backward-compatible: a stored place keeps the kind
        -- it was saved with, and every one of those is still in this list.
        kind = { type = "string", enum = { "apartment", "house", "garage", "lockup", "office",
                                           "bank", "shop" },
                 default = "apartment" },
        price = { type = "integer", required = true, min = 0 },
        rent = { type = "integer", required = true, min = 0 },
        arrears = { type = "integer", default = 0, min = 0 },
        slots = { type = "integer", default = 40, min = 1, max = 500 },
        weight = { type = "integer", default = 200000, min = 1 },
        for_sale = { type = "boolean", default = true },
        keys = { type = "table", default = {} },
        -- Where it is. Plain numbers, not a game vector: the simulation needs
        -- to know one place is not another place, and nothing more. Whatever
        -- decides what "near" means reads these and does its own arithmetic.
        x = { type = "number", default = 0.0 },
        y = { type = "number", default = 0.0 },
        z = { type = "number", default = 0.0 },
        radius = { type = "number", default = 3.0, min = 0.5, max = 200.0 },
    },
    -- On the market is `listed`, off it and somebody's is `owned`, taken back
    -- for rent is `seized`. Who holds a place is the ownership register, not
    -- this: the council holds a place that is `listed` or `seized`, and an
    -- owner holds one that is `owned` or that they put up for sale.
    --
    -- `seized` could only become `listed`, and the sale went on without asking,
    -- so a seized place that was bought stayed `seized` under its buyer. And a
    -- `listed` place could not be seized, so an owner in arrears who put it on
    -- the market kept it.
    states = {
        listed = { "owned", "seized" },
        owned = { "listed", "seized" },
        seized = { "listed", "owned" },
    },
    initial = "listed",
})

local Place = Property.Place

--- The container a place holds things in, and the name the record uses for it.
function Property.stash(place_id) return "prp:" .. place_id end

--- Premises a business trades from, which the city does not put on the market.
---
--- A bank and a shop are places with doors, so they are places: the same
--- entity, the same coordinates, the same proximity check as a flat. What they
--- are not is housing.
---
--- Every place is born `listed`, and the settings file gives a shop's premises
--- a price of nothing because nobody was ever meant to buy them. Nothing said
--- so, so the city's liquor store sat on the market at a price of zero and
--- `property.buy` handed the front door to whoever asked for it by id, wallet
--- untouched. Banking knew this and took each branch off the market by hand
--- after building it; nothing did it for a shop.
---
--- A rule here rather than that line repeated wherever a place is built,
--- because the adapter has to ask the same question about a place it did not
--- build this boot.
local PREMISES = { bank = true, shop = true }

function Property.premises(kind)
    return PREMISES[kind] == true
end

--- Whether a place that already exists was left on the market by a city saved
--- before premises were kept off it.
---
--- `build` skips an address that is already there, so the rule above never
--- reaches one: a city played before this change has a liquor store whose
--- front door is still for sale at a price of nothing. Something has to walk
--- what is stored and put it right, and the thing that can is the adapter,
--- which no spec can load. So the decision is here and the adapter is left
--- with the patch and the save -- the same split as `NuiState.follow_up`.
---
--- Never a place somebody owns, and never one still listed by an owner who
--- put their own shop up for sale. That is a thing an owner may do and this
--- is not the place to overrule them.
function Property.left_on_the_market(place, held_by)
    if type(place) ~= "table" then return false end
    if not Property.premises(place:get("kind")) then return false end
    if place:get("for_sale") ~= true then return false end
    if place.state ~= "listed" then return false end
    return held_by == COUNCIL
end

--- Where the settings file says a place is, when the stored place disagrees.
---
--- Nothing at run time moves a door: a place's position comes from the
--- settings file and only from there, so the settings file is the authority
--- and a stored place that differs is simply out of date. `build` skips an
--- address that already exists, so without this a corrected coordinate never
--- reaches a city that has been played -- and one of them was wrong: an
--- address fifty-one metres above the street, which a player fell out of and
--- could therefore never buy.
---
--- Returns the fields to patch, or nil when the stored place is already right.
function Property.misplaced(place, where)
    if type(place) ~= "table" or type(where) ~= "table" then return nil end
    local changes, differs = {}, false
    for _, field in ipairs({ "x", "y", "z", "radius" }) do
        local wanted = where[field]
        -- A settings file that leaves one out is not saying "move it to nil".
        if type(wanted) == "number" and place:get(field) ~= wanted then
            changes[field] = wanted
            differs = true
        end
    end
    if not differs then return nil end
    return changes
end

--- opts.grace      missed rent days before it is taken back
--- opts.rent_hour  the city hour rent falls due
function Property.system(opts)
    opts = opts or {}
    local grace = opts.grace or DEFAULT_GRACE
    local rent_hour = opts.rent_hour or 9
    assert(math.type(grace) == "integer" and grace >= 1, "a grace period is at least one day")

    return {
        name = "property",
        requires = { "characters", "memory", "inventory" },
        install = function(world)
            local places = world:repository(Place)

            --- Whether somebody is at a place. The adapter installs the real
            --- one; without it nothing opens, which is the correct default for
            --- a lock.
            local function near(actor, place_id)
                local check = world.services.proximity
                if type(check) ~= "function" then return nil end
                return check(actor, place_id) == true
            end

            local function holder(place_id)
                return world.ownership:owner_of(place_id) or COUNCIL
            end

            local function may_enter(place, actor)
                if holder(place.id) == actor then return true end
                return place:get("keys")[actor] == true
            end

            --- New locks for a place that has just changed hands.
            ---
            --- The keys stayed on the place, and a key opens the door whoever
            --- holds it. So a seller who had handed one to a friend, or to
            --- themselves, walked into the buyer's home after the sale and
            --- emptied the stash, and an owner turned out for rent went on
            --- letting themselves in. A stash somebody had open shuts as well:
            --- reach lasts thirty real seconds, long enough to take whatever
            --- the new holder puts in it.
            local function change_locks(place)
                place:set("keys", {})
                world.services.access:close(Property.stash(place.id))
            end

            world.services.property = {
                places = places,
                holder = holder,
                may_enter = may_enter,
                stash = Property.stash,
                --- Put a place on the map. Not a command: the city decides
                --- what exists, never a client asking for it.
                build = function(address, build_opts)
                    build_opts = build_opts or {}
                    -- On the market unless it is premises, and whatever the
                    -- caller said either way. Written out rather than folded
                    -- into an `and`/`or`, which reads well and answers the
                    -- wrong thing for an explicit `false`.
                    local for_sale = build_opts.for_sale
                    if for_sale == nil then
                        for_sale = not Property.premises(build_opts.kind)
                    end
                    local place, why = places:create({
                        address = address,
                        kind = build_opts.kind,
                        price = build_opts.price or 0,
                        rent = build_opts.rent or 0,
                        for_sale = for_sale,
                        slots = build_opts.slots,
                        weight = build_opts.weight,
                        x = build_opts.x, y = build_opts.y, z = build_opts.z,
                        radius = build_opts.radius,
                    })
                    if not place then error(("cannot build %s: %s"):format(address, tostring(why)), 2) end
                    world.ownership:claim("built:" .. place.id, place.id, COUNCIL)
                    world.services.inventory:define_container(Property.stash(place.id),
                        { slots = place:get("slots"), weight = place:get("weight"), label = address })
                    return place
                end,
            }

            world:define("property.buy", {
                summary = "buy a place that is for sale",
                rate = { per_minute = 6 },
                args = {
                    place = { type = "id", kind = "prp", required = true },
                    -- The price the buyer was shown. The sale named only the
                    -- place, so a seller who put the price up between the
                    -- buyer reading the door and pressing buy was paid the new
                    -- one. Optional so that a client which does not send it
                    -- buys as it always did, at whatever the place costs now.
                    price = { type = "integer", min = 0, max = 1000000000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local place = places:load(args.place)
                    if not place then return ctx.refuse("no_such_place", "There is no such address.") end
                    if not place:get("for_sale") or place.state == "owned" then
                        return ctx.refuse("not_for_sale", ("%s is not for sale."):format(place:get("address")))
                    end
                    -- A sale ends with the place owned, and whether it can be
                    -- is asked before anything moves. It used to be asked of
                    -- nobody after the money had gone.
                    if not place:can_transition("owned") then
                        return ctx.refuse("not_for_sale", ("%s is not for sale."):format(place:get("address")))
                    end

                    local seller = holder(place.id)
                    if seller == ctx.actor then
                        return ctx.refuse("already_yours", "You already own it.")
                    end
                    if args.price ~= nil and args.price ~= place:get("price") then
                        return ctx.refuse("price_changed",
                            ("The price of %s has changed. Look again before you buy."):format(place:get("address")))
                    end
                    local seller_account = seller == COUNCIL and ESTATE or Characters.wallet(seller)
                    local price = Money.from_minor(place:get("price"))

                    local operation = ctx.operation_id or ("buy:%s:%s"):format(place.id, ctx.actor)
                    if price:is_positive() then
                        local paid, why = world.ledger:transfer(operation,
                            Characters.wallet(ctx.actor), seller_account, price,
                            { reason = "property", address = place:get("address") })
                        if not paid then
                            return ctx.refuse("cannot_afford", "You cannot afford that.", { detail = why })
                        end
                    end

                    -- Compare-and-swap on who holds it. If somebody bought it
                    -- between the check above and here, this is where they win
                    -- and this buyer is refused with their money already moved,
                    -- so the money goes back before anything else happens.
                    local moved, move_why = world.ownership:transfer(
                        "sold:" .. operation, place.id, seller, ctx.actor,
                        { price = place:get("price") })
                    if not moved then
                        if price:is_positive() then
                            world.ledger:transfer("refund:" .. operation,
                                seller_account, Characters.wallet(ctx.actor), price,
                                { reason = "refund", address = place:get("address") })
                        end
                        return ctx.refuse("sold_already", "Somebody else got there first.",
                            { detail = move_why })
                    end

                    place:patch({ for_sale = false, arrears = 0 })
                    local owned, why = place:transition("owned", { reason = "bought" })
                    if not owned then
                        -- Asked before a cent moved, so this is a bug, and a
                        -- bug is loud rather than a place half sold in silence.
                        error(("%s was sold and cannot be owned: %s"):format(place.id, tostring(why)))
                    end
                    change_locks(place)
                    places:save(place)

                    world.services.remember("bought:" .. place.id .. ":" .. operation, {
                        subject = ctx.actor, kind = "property.bought", weight = 5,
                        place = place.id,
                        meta = { address = place:get("address"), price = place:get("price") },
                    })
                    ctx.emit("property.bought", { place = place.id, buyer = ctx.actor,
                        seller = seller, price = place:get("price") })
                    return ctx.ok({ place = place.id, paid = place:get("price") })
                end,
            })

            -- Not read_only, which is a promise to the command door that
            -- nothing changes. It was declared so while it rewrote the place,
            -- so a listing kept no receipt -- a retried one ran again -- and
            -- had no rate.
            world:define("property.list", {
                summary = "put your place on the market, or take it off",
                rate = { per_minute = 6 },
                args = {
                    place = { type = "id", kind = "prp", required = true },
                    price = { type = "integer", min = 0, max = 1000000000 },
                    for_sale = { type = "boolean", default = true },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local place = places:load(args.place)
                    if not place then return ctx.refuse("no_such_place", "There is no such address.") end
                    if holder(place.id) ~= ctx.actor then
                        return ctx.refuse("not_yours", "That is not yours to sell.")
                    end
                    -- On the market is `listed` and off it is `owned`, both
                    -- ways. Only the first way was written, so a place put up
                    -- and taken straight back down went on saying `listed`.
                    -- Asked before anything changes, so a place is never left
                    -- for sale in one field and not in the other.
                    local wanted, reason = "owned", "taken off the market"
                    if args.for_sale then wanted, reason = "listed", "put up for sale" end
                    if place.state ~= wanted and not place:can_transition(wanted) then
                        return ctx.refuse("bad_listing",
                            ("%s cannot be put on or taken off the market now."):format(place:get("address")))
                    end
                    local changes = { for_sale = args.for_sale }
                    if args.price then changes.price = args.price end
                    local ok, why = place:patch(changes)
                    if not ok then return ctx.refuse("bad_listing", why) end
                    if place.state ~= wanted then
                        local moved, move_why = place:transition(wanted, { reason = reason })
                        if not moved then
                            error(("%s cannot be %s: %s"):format(place.id, wanted, tostring(move_why)))
                        end
                    end
                    places:save(place)
                    ctx.emit("property.listed", { place = place.id, owner = ctx.actor,
                        price = place:get("price"), for_sale = args.for_sale })
                    return ctx.ok()
                end,
            })

            world:define("property.enter", {
                summary = "open a place you can get into",
                rate = { per_minute = 30 },
                args = { place = { type = "id", kind = "prp", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local place = places:load(args.place)
                    if not place then return ctx.refuse("no_such_place", "There is no such address.") end
                    if not may_enter(place, ctx.actor) then
                        return ctx.refuse("no_key", "You do not have a key.")
                    end

                    local at = near(ctx.actor, place.id)
                    if at == nil then
                        -- No proximity service installed. Refusing is the only
                        -- safe answer: the alternative is a lock that opens
                        -- from anywhere on the map.
                        return ctx.refuse("no_proximity",
                            "The server cannot tell where you are.")
                    end
                    if not at then return ctx.refuse("too_far", "You are not there.") end

                    world.services.reach(ctx.actor, Property.stash(place.id))
                    ctx.emit("property.entered", { place = place.id, who = ctx.actor })
                    return ctx.ok({ stash = Property.stash(place.id) })
                end,
            })

            world:define("property.key", {
                summary = "give somebody a key, or take it back",
                -- Every key given or taken writes a line on the record, so it is
                -- limited like every other command that writes one.
                rate = { per_minute = 20 },
                args = {
                    place = { type = "id", kind = "prp", required = true },
                    holder = { type = "id", kind = "chr", required = true },
                    give = { type = "boolean", default = true },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local place = places:load(args.place)
                    if not place then return ctx.refuse("no_such_place", "There is no such address.") end
                    if holder(place.id) ~= ctx.actor then
                        return ctx.refuse("not_yours", "That is not yours to hand out keys to.")
                    end
                    -- An owner needs no key. The only thing a key to yourself
                    -- ever did was outlast the sale.
                    if args.holder == ctx.actor then
                        return ctx.refuse("already_yours", "It is yours. You do not need a key.")
                    end
                    -- A key goes to somebody. Any well-formed id was taken, and
                    -- each wrote a line on the record: a way to push history out
                    -- of it that police.lookup was closed against. Taking a key
                    -- back is always allowed, whoever it was given to.
                    if args.give and world:repository(Characters.Character):load(args.holder) == nil then
                        return ctx.refuse("no_such_person", "There is nobody by that description.")
                    end
                    local keys = {}
                    for who in pairs(place:get("keys")) do keys[who] = true end
                    if args.give then keys[args.holder] = true else keys[args.holder] = nil end
                    place:set("keys", keys)
                    places:save(place)
                    -- Who has a key to what is exactly the sort of thing a
                    -- detective asks about after a burglary with no forced entry.
                    -- Giving a key and taking it back are different events.
                    -- Without the action in the operation id they collide when
                    -- they happen in the same millisecond, and the second one
                    -- is silently dropped as a duplicate of the first.
                    world.services.remember(
                        ctx.operation_id or ("key:%s:%s:%s:%d")
                            :format(place.id, args.holder, tostring(args.give), ctx.now), {
                        subject = ctx.actor, kind = "property.key", weight = 1,
                        place = place.id, involved = { args.holder },
                        meta = { given = args.give, address = place:get("address") },
                    })
                    ctx.emit("property.key", { place = place.id, holder = args.holder, given = args.give })
                    return ctx.ok()
                end,
            })

            world:define("property.settle", {
                summary = "pay off what you owe on a place",
                args = { place = { type = "id", kind = "prp", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local place = places:load(args.place)
                    if not place then return ctx.refuse("no_such_place", "There is no such address.") end
                    if holder(place.id) ~= ctx.actor then
                        return ctx.refuse("not_yours", "That is not yours.")
                    end
                    local owed = place:get("arrears") * place:get("rent")
                    if owed == 0 then return ctx.refuse("nothing_owed", "You are straight.") end
                    local paid, why = world.ledger:transfer(
                        ctx.operation_id or ("arrears:%s:%d"):format(place.id, ctx.now),
                        Characters.wallet(ctx.actor), RENT_ACCOUNT, Money.from_minor(owed),
                        { reason = "arrears", address = place:get("address") })
                    if not paid then
                        return ctx.refuse("cannot_afford", "You cannot cover that.", { detail = why })
                    end
                    place:set("arrears", 0)
                    places:save(place)
                    ctx.emit("property.settled", { place = place.id, owner = ctx.actor, paid = owed })
                    return ctx.ok({ paid = owed })
                end,
            })

            --- Take a place back for rent. Whether it can be seized is asked
            --- before the register moves, and what the register answers is
            --- read rather than assumed: a place that cannot be taken back
            --- stays with its owner, arrears still counting, and is asked
            --- again at the next rent day.
            local function seize(place, owner, missed, due)
                if not place:can_transition("seized") then return end
                local operation = ("seized:%s:%d"):format(place.id, due)
                local moved = world.ownership:transfer(operation, place.id, owner, COUNCIL,
                    { reason = "unpaid rent" })
                if not moved then return end
                place:patch({ arrears = 0, for_sale = true })
                local taken, why = place:transition("seized", { reason = "unpaid rent" })
                if not taken then
                    error(("%s was taken back and cannot be seized: %s"):format(place.id, tostring(why)))
                end
                change_locks(place)
                world.services.remember(operation, {
                    subject = owner, kind = "property.seized", weight = 20,
                    place = place.id,
                    meta = { address = place:get("address"), missed = missed },
                })
                world.events:emit("property.seized",
                    { place = place.id, owner = owner, missed = missed })
            end

            -- Rent, once a city day, from whoever holds a place.
            --
            -- Asked of the holder, not the state. It was charged only in
            -- `owned`, and listing moves a place to `listed`, so putting a
            -- place on the market -- or on and straight back off -- stopped
            -- its rent for good, and its arrears stopped counting.
            --
            -- Named after the day it is for, which the scheduler hands over,
            -- and not after the moment it runs. Catching up after a stall runs
            -- this once for every day missed, all at the same moment, so every
            -- day after the first had the first one's operation id and was
            -- waved through as a duplicate: five days owed, one charged.
            world:daily(rent_hour, 0, function(due)
                for _, place in ipairs(places:where(function(candidate)
                    return holder(candidate.id) ~= COUNCIL
                end)) do
                    local owner = holder(place.id)
                    local rent = place:get("rent")
                    if rent > 0 then
                        local paid = world.ledger:transfer(
                            ("rent:%s:%d"):format(place.id, due),
                            Characters.wallet(owner), RENT_ACCOUNT, Money.from_minor(rent),
                            { reason = "rent", address = place:get("address") })
                        if paid then
                            if place:get("arrears") > 0 then place:set("arrears", 0) end
                        else
                            -- Not a debt. A count of days, because a negative
                            -- balance is money that does not exist.
                            local missed = place:get("arrears") + 1
                            place:set("arrears", missed)
                            world.events:emit("property.arrears",
                                { place = place.id, owner = owner, missed = missed, of = grace })
                            if missed >= grace then seize(place, owner, missed, due) end
                        end
                        places:save(place)
                    end
                end
            end, "property:rent")

            world:on("world.loaded", function()
                local loaded = places:all()
                for _, place in ipairs(loaded) do
                    world.services.inventory:define_container(Property.stash(place.id),
                        { slots = place:get("slots"), weight = place:get("weight"),
                          label = place:get("address") })
                end
                -- A city saved before a seized place could be owned has places
                -- that were bought and still say `seized`, under somebody who
                -- is not the council. Taking one back for rent is a move from
                -- `seized` to `seized`, which is not a move, so its owner could
                -- stop paying and keep it. After every stash exists, so a place
                -- this cannot put right costs nobody their stash.
                for _, place in ipairs(loaded) do
                    if place.state == "seized" and holder(place.id) ~= COUNCIL then
                        local owned, why = place:transition("owned", { reason = "bought while seized" })
                        if not owned then
                            error(("%s is held by %s and cannot be owned: %s")
                                :format(place.id, holder(place.id), tostring(why)))
                        end
                        places:save(place)
                    end
                end
            end, { label = "property:load" })
        end,
    }
end

return Property
