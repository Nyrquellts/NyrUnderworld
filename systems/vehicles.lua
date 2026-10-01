--- Cars: who holds the keys, where it is, and who took it.
--
-- Most of the machinery for this already exists. A car is an entity, its owner
-- is the ownership register, its boot is an inventory container, its keys work
-- the way property keys do. What is new is that a car is somewhere, it can be
-- driven off, and it can end up in an impound lot.
--
-- The interesting part is taking one that is not yours. That is not a refusal;
-- it is a crime, and the difference matters. Refusing it makes theft
-- impossible and the city poorer. Treating it as a crime means it works, it
-- costs something, and the city writes it down: the plate, the place, the time,
-- and whether anybody was standing there.
--
-- Who was standing there is decided by the server, never by the thief. A
-- command that accepted a witness list would let the person committing the
-- crime declare that nobody saw them.
--
-- There is no real-world technique here of any kind. Taking a car without its
-- keys costs a lockpick item and some time, and that is the whole of it.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local Vehicles = {}

local IMPOUND = "state:impound"
local IMPOUND_ACCOUNT = "external:impound"
local DEFAULT_FEE = 25000
local DEFAULT_PICK = "lockpick"
local DEFAULT_HOTWIRE_MS = 30 * Clock.MS_PER_SECOND

Vehicles.IMPOUND = IMPOUND

Vehicles.Vehicle = Entity.define("veh", {
    fields = {
        model = { type = "string", required = true, max = 32 },
        plate = { type = "string", required = true, min = 2, max = 8 },
        colour = { type = "string", max = 24, default = "black" },
        garage = { type = "id", kind = "prp" },
        slots = { type = "integer", default = 15, min = 1, max = 200 },
        weight = { type = "integer", default = 80000, min = 1 },
        keys = { type = "table", default = {} },
        fee = { type = "integer", default = DEFAULT_FEE, min = 0 },
        -- What it is worth, in whole minor units. A chop shop pays a fraction
        -- of this, which is what makes one car worth taking over another.
        value = { type = "integer", default = 200000, min = 0 },
        -- Whoever currently has it out. Not the owner: the owner is the
        -- ownership register, and the two differ precisely when it has been
        -- taken, which is the case worth being able to see.
        driver = { type = "id", kind = "chr" },
        stolen = { type = "boolean", default = false },
        x = { type = "number", default = 0.0 },
        y = { type = "number", default = 0.0 },
        z = { type = "number", default = 0.0 },
    },
    states = {
        stored = { "out", "impounded", "wrecked" },
        out = { "stored", "impounded", "wrecked" },
        impounded = { "stored", "wrecked" },
        -- Terminal. A chopped car is parts; there is nothing to come back to.
        wrecked = {},
    },
    initial = "stored",
})

local Vehicle = Vehicles.Vehicle

--- The container a car carries things in.
function Vehicles.boot(vehicle_id) return "veh:" .. vehicle_id end

--- opts.fee          default impound fee, in minor units
--- opts.pick         the item taking a car without keys costs
--- opts.hotwire_ms   how long that takes, in real milliseconds
function Vehicles.system(opts)
    opts = opts or {}
    local pick = opts.pick or DEFAULT_PICK
    local hotwire_ms = opts.hotwire_ms or DEFAULT_HOTWIRE_MS

    return {
        name = "vehicles",
        requires = { "characters", "memory", "inventory" },
        install = function(world)
            local cars = world:repository(Vehicle)
            local attempts = {}        -- actor -> { vehicle, at }

            -- Real time as city time at the pace the city is running now,
            -- rounded up: the same reckoning reach uses in systems/inventory.
            -- The clock is asked every time, because loading a saved city
            -- replaces it.
            local function city_span(real_ms)
                return math.ceil(real_ms * world.clock:rate())
            end

            local function holder(vehicle_id)
                return world.ownership:owner_of(vehicle_id)
            end

            local function has_key(car, actor)
                if holder(car.id) == actor then return true end
                return car:get("keys")[actor] == true
            end

            --- Whether somebody is at a thing. Nil when nothing can answer, and
            --- the callers below treat nil as a refusal rather than a yes.
            local function near(actor, target)
                local check = world.services.proximity
                if type(check) ~= "function" then return nil end
                return check(actor, target) == true
            end

            --- Who saw it. The absence of a witness service means nobody saw
            --- it, which is the conservative direction: it never accuses
            --- anybody, and the record is written either way.
            local function witnesses_of(actor)
                local look = world.services.witnesses
                if type(look) ~= "function" then return {} end
                local seen = {}
                for _, who in ipairs(look(actor) or {}) do
                    if who ~= actor then seen[#seen + 1] = who end
                end
                return seen
            end

            world.services.vehicles = {
                cars = cars,
                holder = holder,
                has_key = has_key,
                boot = Vehicles.boot,
                --- Put a car in the world and give it to somebody. Not a
                --- command: cars come from a dealership or an admin, never
                --- from a client asking for one.
                register = function(owner, attrs)
                    local car, why = cars:create(attrs)
                    if not car then error(("cannot register that car: %s"):format(tostring(why)), 2) end
                    world.ownership:claim("built:" .. car.id, car.id, owner)
                    world.services.inventory:define_container(Vehicles.boot(car.id),
                        { slots = car:get("slots"), weight = car:get("weight"),
                          label = car:get("plate") })
                    return car
                end,
                --- Take a car off the street. The police system calls this;
                --- there is no client command for it.
                impound = function(operation_id, vehicle_id, reason)
                    local car = cars:load(vehicle_id)
                    if not car then return false, "no such vehicle" end
                    if car.state == "impounded" then return false, "already impounded" end
                    local ok, why = car:transition("impounded", { reason = reason or "impounded" })
                    if not ok then return false, why end
                    car:set("driver", nil)
                    cars:save(car)
                    world.services.remember(operation_id, {
                        subject = holder(car.id) or IMPOUND, kind = "vehicle.impounded", weight = 5,
                        meta = { plate = car:get("plate"), reason = reason },
                    })
                    world.events:emit("vehicle.impounded",
                        { vehicle = car.id, plate = car:get("plate"), reason = reason })
                    return true
                end,
            }

            world:persist_with("vehicles", {
                save = function()
                    local out = {}
                    for actor, attempt in pairs(attempts) do
                        out[actor] = { vehicle = attempt.vehicle, at = attempt.at }
                    end
                    return { attempts = out }
                end,
                load = function(stored)
                    attempts = {}
                    for actor, attempt in pairs((stored or {}).attempts or {}) do
                        if math.type(attempt.at) == "integer" then
                            attempts[actor] = { vehicle = attempt.vehicle, at = attempt.at }
                        end
                    end
                    return true
                end,
            })

            -- Takes the id of the thing to be near, not the thing itself: a
            -- car is checked against its garage when it is being taken out or
            -- put away, and against itself everywhere else.
            local function require_here(ctx, target)
                local at = near(ctx.actor, target)
                if at == nil then
                    return ctx.refuse("no_proximity", "The server cannot tell where you are.")
                end
                if not at then return ctx.refuse("too_far", "You are not at it.") end
                return nil
            end

            world:define("vehicle.take", {
                summary = "take out a car you have the keys to",
                rate = { per_minute = 20 },
                args = { vehicle = { type = "id", kind = "veh", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if not has_key(car, ctx.actor) then
                        return ctx.refuse("no_key", "You do not have the keys.")
                    end
                    -- Nothing asked, so a key from before a car was chopped
                    -- drove off a pile of parts.
                    if car.state == "wrecked" then
                        return ctx.refuse("wrecked", "That is parts now.")
                    end
                    if car.state == "impounded" then
                        return ctx.refuse("impounded", "It is in the impound lot.")
                    end
                    -- Not who: the refusal used to name the driver by their
                    -- character id, which a client is never meant to be handed.
                    if car.state == "out" then
                        return ctx.refuse("already_out", "Somebody already has it out.")
                    end
                    local refused = require_here(ctx, car:get("garage") or car.id)
                    if refused then return refused end

                    -- What the lifecycle answers is read, and read first: a
                    -- refused move changes nothing, so the car is only written
                    -- to once it has moved. The answer was dropped, and a
                    -- wrecked car that could not go out was given a driver.
                    local moved = car:transition("out", { reason = "taken out" })
                    if not moved then
                        return ctx.refuse("cannot_take", "It cannot be taken out.")
                    end
                    car:patch({ driver = ctx.actor, stolen = false })
                    cars:save(car)
                    world.services.reach(ctx.actor, Vehicles.boot(car.id))
                    ctx.emit("vehicle.taken", { vehicle = car.id, plate = car:get("plate"),
                        driver = ctx.actor })
                    return ctx.ok({ vehicle = car.id, boot = Vehicles.boot(car.id) })
                end,
            })

            world:define("vehicle.store", {
                summary = "put a car away",
                rate = { per_minute = 20 },
                args = { vehicle = { type = "id", kind = "veh", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if car.state ~= "out" then
                        return ctx.refuse("not_out", "It is not out.")
                    end
                    -- Only whoever has it. A car being put away by somebody
                    -- who is not in it is how one gets pulled out from under a
                    -- driver mid-chase.
                    if car:get("driver") ~= ctx.actor then
                        return ctx.refuse("not_yours", "Somebody else has it.")
                    end
                    if car:get("stolen") then
                        return ctx.refuse("stolen", "It is not yours to put away.")
                    end
                    local refused = require_here(ctx, car:get("garage") or car.id)
                    if refused then return refused end

                    car:set("driver", nil)
                    car:transition("stored", { reason = "put away" })
                    cars:save(car)
                    ctx.emit("vehicle.stored", { vehicle = car.id, plate = car:get("plate") })
                    return ctx.ok()
                end,
            })

            world:define("vehicle.boot", {
                summary = "open the boot",
                rate = { per_minute = 30 },
                args = { vehicle = { type = "id", kind = "veh", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if car.state == "wrecked" then
                        return ctx.refuse("wrecked", "That is parts now.")
                    end
                    if car.state == "impounded" then
                        return ctx.refuse("impounded", "It is in the impound lot.")
                    end
                    -- Whoever is driving it can open it, keys or not: that is
                    -- what makes a stolen car worth taking.
                    if not (has_key(car, ctx.actor) or car:get("driver") == ctx.actor) then
                        return ctx.refuse("no_key", "It is locked.")
                    end
                    local refused = require_here(ctx, car.id)
                    if refused then return refused end
                    world.services.reach(ctx.actor, Vehicles.boot(car.id))
                    return ctx.ok({ boot = Vehicles.boot(car.id) })
                end,
            })

            world:define("vehicle.key", {
                summary = "give somebody a set of keys, or take them back",
                args = {
                    vehicle = { type = "id", kind = "veh", required = true },
                    holder = { type = "id", kind = "chr", required = true },
                    give = { type = "boolean", default = true },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if holder(car.id) ~= ctx.actor then
                        return ctx.refuse("not_yours", "That is not yours to hand out keys to.")
                    end
                    local keys = {}
                    for who in pairs(car:get("keys")) do keys[who] = true end
                    if args.give then keys[args.holder] = true else keys[args.holder] = nil end
                    car:set("keys", keys)
                    cars:save(car)
                    ctx.emit("vehicle.key", { vehicle = car.id, holder = args.holder, given = args.give })
                    return ctx.ok()
                end,
            })

            world:define("vehicle.hotwire", {
                summary = "take a car you do not have the keys to",
                rate = { per_minute = 10 },
                args = { vehicle = { type = "id", kind = "veh", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    -- First, so nobody is told to take a pile of parts with
                    -- their keys. Hotwiring a wreck spent a lockpick, opened
                    -- the boot and wrote the theft of a car that was gone.
                    if car.state == "wrecked" then
                        return ctx.refuse("wrecked", "That is parts now.")
                    end
                    if has_key(car, ctx.actor) then
                        return ctx.refuse("have_keys", "You have the keys. Just take it.")
                    end
                    if car.state == "impounded" then
                        return ctx.refuse("impounded", "It is behind a fence.")
                    end
                    if car.state == "out" and car:get("driver") ~= nil then
                        return ctx.refuse("occupied", "Somebody is in it.")
                    end
                    local refused = require_here(ctx, car.id)
                    if refused then return refused end

                    local inventory = world.services.inventory
                    local pockets = ctx.actor
                    -- Somebody with no pockets has no tools. Asked, because a
                    -- missing container throws: that was a server error for
                    -- trying a car door.
                    if not (inventory:has_container(pockets) and inventory:has(pockets, pick, 1)) then
                        return ctx.refuse("no_tools", "You do not have what you need.")
                    end

                    -- Two steps, so it takes time rather than being a button.
                    -- The first attempt starts the clock; the second, once
                    -- enough time has passed, finishes it.
                    --
                    -- Real time: somebody stands at the car for it. It was
                    -- thirty city seconds, which is half a real second at the
                    -- pace config.lua ships, so a second press one server tick
                    -- after the first finished the job and "Give it a minute"
                    -- was a double click.
                    local attempt = attempts[ctx.actor]
                    if not attempt or attempt.vehicle ~= car.id then
                        attempts[ctx.actor] = { vehicle = car.id, at = ctx.now }
                        return ctx.refuse("working", "Give it a minute.",
                            { seconds = hotwire_ms // Clock.MS_PER_SECOND })
                    end
                    local needed = city_span(hotwire_ms)
                    local waited = ctx.now - attempt.at
                    if waited < needed then
                        local left = math.ceil((needed - waited) / world.clock:rate())
                        return ctx.refuse("working", "Not yet.",
                            { seconds = left // Clock.MS_PER_SECOND + 1 })
                    end
                    attempts[ctx.actor] = nil

                    -- Whether it can be driven off is asked before the
                    -- lockpick is spent, which cannot be given back, and what
                    -- the move answers is read.
                    if car.state ~= "out" and not car:can_transition("out") then
                        return ctx.refuse("cannot_take", "It cannot be taken.")
                    end
                    local spent = inventory:destroy(
                        ("hotwire:%s:%d"):format(ctx.actor, ctx.now), pockets, pick, 1,
                        { reason = "used on a car" })
                    if not spent then return ctx.refuse("no_tools", "You do not have what you need.") end

                    if car.state ~= "out" then
                        local moved, why = car:transition("out", { reason = "taken" })
                        if not moved then
                            error(("%s could not be driven off: %s"):format(car.id, tostring(why)))
                        end
                    end
                    car:patch({ driver = ctx.actor, stolen = true })
                    cars:save(car)
                    world.services.reach(ctx.actor, Vehicles.boot(car.id))

                    -- The plate, the place, the time, and whoever was standing
                    -- there. Decided by the server; the thief says none of it.
                    local seen = witnesses_of(ctx.actor)
                    world.services.remember(("theft:%s:%d"):format(car.id, ctx.now), {
                        subject = ctx.actor, kind = "crime.vehicle_theft", weight = 35,
                        witnesses = seen,
                        involved = holder(car.id) and { holder(car.id) } or nil,
                        meta = { plate = car:get("plate"), model = car:get("model") },
                    })
                    ctx.emit("vehicle.stolen", { vehicle = car.id, plate = car:get("plate"),
                        thief = ctx.actor, witnessed = #seen > 0 })
                    return ctx.ok({ vehicle = car.id, witnessed = #seen > 0 })
                end,
            })

            world:define("vehicle.retrieve", {
                summary = "pay to get a car out of the impound lot",
                args = { vehicle = { type = "id", kind = "veh", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local car = cars:load(args.vehicle)
                    if not car then return ctx.refuse("no_such_vehicle", "There is no such car.") end
                    if car.state ~= "impounded" then
                        return ctx.refuse("not_impounded", "It is not in the impound lot.")
                    end
                    if holder(car.id) ~= ctx.actor then
                        return ctx.refuse("not_yours", "That is not yours to collect.")
                    end
                    local fee = Money.from_minor(car:get("fee"))
                    if fee:is_positive() then
                        local paid, why = world.ledger:transfer(
                            ctx.operation_id or ("impound:%s:%d"):format(car.id, ctx.now),
                            Characters.wallet(ctx.actor), IMPOUND_ACCOUNT, fee,
                            { reason = "impound fee", plate = car:get("plate") })
                        if not paid then
                            return ctx.refuse("cannot_afford", "You cannot cover the fee.", { detail = why })
                        end
                    end
                    car:patch({ stolen = false })
                    car:set("driver", nil)
                    car:transition("stored", { reason = "collected" })
                    cars:save(car)
                    ctx.emit("vehicle.retrieved", { vehicle = car.id, plate = car:get("plate"),
                        paid = car:get("fee") })
                    return ctx.ok({ paid = car:get("fee") })
                end,
            })

            -- Whoever was driving is not driving after a restart, and a
            -- half-finished attempt at a car does not survive one either.
            world:on("world.loaded", function()
                attempts = {}
                for _, car in ipairs(cars:all()) do
                    world.services.inventory:define_container(Vehicles.boot(car.id),
                        { slots = car:get("slots"), weight = car:get("weight"),
                          label = car:get("plate") })
                    if car.state == "out" then
                        car:set("driver", nil)
                        car:transition("stored", { reason = "server restarted" })
                        cars:save(car)
                    end
                end
            end, { label = "vehicles:load" })

            world:on("character.released", function(payload)
                for _, car in ipairs(cars:where(function(candidate)
                    return candidate:get("driver") == payload.character
                end)) do
                    car:set("driver", nil)
                    if car.state == "out" then
                        car:transition("stored", { reason = "driver left" })
                    end
                    cars:save(car)
                end
                attempts[payload.character] = nil
            end, { label = "vehicles:release" })

            -- A chopped car is parts, and parts have no boot. Its boot stayed
            -- full, with nothing that could ever take those things out again,
            -- and open to whoever had it open -- the thief's own hotwire opens
            -- it -- so they could go on reaching into a car that was gone.
            -- What was left in it goes with the car, out of the world across a
            -- named reason, and the boot is shut for everybody.
            --
            -- Listened for rather than done by the chop, which is
            -- systems/fencing's: what a car's boot is belongs here.
            world:on("fence.chopped", function(payload)
                local car = cars:load(payload.vehicle)
                if not car or car.state ~= "wrecked" then return end
                local boot = Vehicles.boot(car.id)
                local inventory = world.services.inventory
                world.services.access:close(boot)
                if not inventory:has_container(boot) then return end
                local counts, order = {}, {}
                for _, stack in ipairs(inventory:contents(boot)) do
                    if counts[stack.item] == nil then
                        counts[stack.item] = 0
                        order[#order + 1] = stack.item
                    end
                    counts[stack.item] = counts[stack.item] + stack.count
                end
                for _, item in ipairs(order) do
                    local gone, why = inventory:destroy(("scrapped:%s:%s"):format(car.id, item),
                        boot, item, counts[item], { reason = "went with the car" })
                    if not gone then
                        error(("the boot of %s could not be emptied: %s"):format(car.id, tostring(why)))
                    end
                end
            end, { label = "vehicles:chopped" })
        end,
    }
end

return Vehicles
