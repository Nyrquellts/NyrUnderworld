--- Carrying things, and the question of what you are allowed to reach.
--
-- The inventory itself already guarantees nothing duplicates. What this adds
-- is the other half of the problem: which containers a given person may touch.
--
-- That question cannot be answered from the client. "I am standing next to the
-- trunk" is a claim, and a client that can make it can make it about any trunk
-- in the city. So reach is a grant the server issues and the server expires:
-- something that knows where people actually are opens a container for one
-- person for a short while, and the command layer checks the grant. A client
-- never grants itself anything.
--
-- Your own pockets are the one container you always reach, because they follow
-- you around by definition.

local Items = require("domain.items")
local Inventory = require("domain.inventory")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local InventorySystem = {}

local DEFAULT_SLOTS = 30
local DEFAULT_WEIGHT = 40000          -- forty kilograms
-- Real seconds, not city ones. Reach is how long somebody standing at a stash
-- or a boot has to use it, and a person waits in real time. This was thirty
-- thousand city milliseconds, which at the pace config.lua ships -- sixty city
-- milliseconds to a real one, a tick a second -- is half a real second: a
-- stash opened by walking in was shut again by the next tick, before anything
-- could be dragged into it. Every spec ran at a rate of one, where the two
-- units are the same number.
local DEFAULT_GRANT_MS = 30 * Clock.MS_PER_SECOND

--- The container a character carries.
function InventorySystem.pockets(character_id)
    return character_id
end

-- ------------------------------------------------------------------- reach

local Access = {}
Access.__index = Access

function Access.new(clock)
    return setmetatable({ _grants = {}, _clock = clock }, Access)
end

--- Open a container for one person until a city time. Only server-side code
--- that actually knows where somebody is should call this.
function Access:grant(actor, container, until_at)
    assert(type(actor) == "string" and actor ~= "", "a grant is to somebody")
    assert(type(container) == "string" and container ~= "", "a grant is to a container")
    local per_actor = self._grants[actor]
    if not per_actor then
        per_actor = {}
        self._grants[actor] = per_actor
    end
    per_actor[container] = until_at
    return true
end

function Access:revoke(actor, container)
    local per_actor = self._grants[actor]
    if not per_actor then return false end
    if container == nil then
        self._grants[actor] = nil
        return true
    end
    local had = per_actor[container] ~= nil
    per_actor[container] = nil
    if next(per_actor) == nil then self._grants[actor] = nil end
    return had
end

--- Shut a container for everybody who has it open. For something that has
--- just changed hands: whoever had it open was let in by the last holder, and
--- a grant lasts long enough to take what the new one puts there.
function Access:close(container)
    for actor, per_actor in pairs(self._grants) do
        if per_actor[container] ~= nil then
            per_actor[container] = nil
            if next(per_actor) == nil then self._grants[actor] = nil end
        end
    end
end

--- Whether somebody may reach a container right now. Your own pockets always;
--- anything else only while a grant is live.
function Access:may(actor, container)
    if actor == nil or container == nil then return false end
    if container == InventorySystem.pockets(actor) then return true end
    local per_actor = self._grants[actor]
    if not per_actor then return false end
    local until_at = per_actor[container]
    if not until_at then return false end
    if until_at <= self._clock() then
        per_actor[container] = nil
        return false
    end
    return true
end

function Access:open_for(actor)
    local out = {}
    local per_actor = self._grants[actor] or {}
    local now = self._clock()
    for container, until_at in pairs(per_actor) do
        if until_at > now then out[#out + 1] = container end
    end
    table.sort(out)
    return out
end

InventorySystem.Access = Access

-- ------------------------------------------------------------------ system

--- opts.items    a catalogue; one is made and left empty if not given
--- opts.slots    how many slots a person carries
--- opts.weight   how many grams a person carries
--- opts.grant_ms how long a reach grant lasts by default, in real milliseconds
function InventorySystem.system(opts)
    opts = opts or {}
    local slots = opts.slots or DEFAULT_SLOTS
    local weight = opts.weight or DEFAULT_WEIGHT
    local grant_ms = opts.grant_ms or DEFAULT_GRANT_MS

    return {
        name = "inventory",
        requires = { "characters" },
        install = function(world)
            local items = opts.items or Items.catalogue()
            local city_now = function() return world.clock:now() end
            local inventory = Inventory.new({ items = items, clock = city_now })
            local access = Access.new(city_now)

            world.services.items = items
            world.services.inventory = inventory
            world.services.access = access

            -- Real time as city time at the pace the city is running now.
            -- Rounded up: rounded down, a slow enough city turns thirty real
            -- seconds into no city time at all, and the grant has ended at
            -- the moment it is made. The clock is asked every time, because
            -- loading a saved city replaces it.
            local function city_span(real_ms)
                return math.ceil(real_ms * world.clock:rate())
            end

            --- Open a container for somebody. The adapter calls this when it
            --- has checked, server-side, that they are actually near it.
            --- `duration` is real milliseconds, the same as the default.
            world.services.reach = function(actor, container, duration)
                inventory:define_container(container)
                return access:grant(actor, container, city_now() + city_span(duration or grant_ms))
            end

            world:persist_with("inventory", {
                save = function() return inventory:serialize() end,
                load = function(record)
                    local loaded, why = Inventory.deserialize(record,
                        { items = items, clock = city_now })
                    if not loaded then return false, why end
                    -- Swap the contents in rather than the object, so every
                    -- reference handed out at install still points at the one
                    -- the world is using.
                    inventory._containers = loaded._containers
                    inventory._issued = loaded._issued
                    return true
                end,
            })

            -- Everybody gets pockets the moment they exist.
            world:on("character.created", function(payload)
                inventory:define_container(InventorySystem.pockets(payload.character),
                    { slots = slots, weight = weight, label = "pockets" })
            end, { label = "inventory:pockets" })

            -- And everybody who exists has them once the city is read. That
            -- was the only place pockets were made, and a character and the
            -- inventory are written to different collections: a save that
            -- landed one and not the other left somebody who exists with
            -- nothing to carry things in, for good. Somebody who has pockets
            -- keeps the ones they have.
            world:on("world.loaded", function()
                for _, person in ipairs(world:repository(Characters.Character):all()) do
                    inventory:define_container(InventorySystem.pockets(person.id),
                        { slots = slots, weight = weight, label = "pockets" })
                end
            end, { label = "inventory:load" })

            local function require_reach(ctx, container, what)
                if not access:may(ctx.actor, container) then
                    return ctx.refuse("out_of_reach", ("You cannot reach %s."):format(what or "that"))
                end
                return nil
            end

            --- What is in something you can reach.
            ---
            --- Reach is the whole check. A stash is readable because entering
            --- the house granted it and for as long as that lasts; somebody
            --- standing in the street asking about the same container is
            --- refused, and asking is how they would find out what is worth
            --- coming back for.
            world:define("inventory.look", {
                read_only = true,
                summary = "what is in something you can reach",
                rate = { per_minute = 60 },
                args = { container = { type = "string", required = true, max = 96 } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not inventory:has_container(args.container) then
                        return ctx.refuse("no_such_container", "That is not somewhere things go.")
                    end
                    local refused = require_reach(ctx, args.container, "there")
                    if refused then return refused end

                    local lines = {}
                    for _, stack in ipairs(inventory:contents(args.container)) do
                        local definition = items:get(stack.item)
                        lines[#lines + 1] = {
                            item = stack.item,
                            label = definition and definition.label or stack.item,
                            count = stack.count,
                            instance = stack.instance,
                        }
                    end
                    local space = inventory:space(args.container)
                    return ctx.ok({ container = args.container, items = lines,
                                    weight = space.weight_used, capacity = space.weight,
                                    slots_used = space.slots_used, slots = space.slots })
                end,
            })

            world:define("inventory.move", {
                summary = "move things between two containers you can reach",
                rate = { per_minute = 120 },
                args = {
                    from = { type = "string", required = true, max = 96 },
                    to = { type = "string", required = true, max = 96 },
                    item = { type = "string", required = true, max = 32 },
                    count = { type = "integer", required = true, min = 1, max = 10000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not items:has(args.item) then
                        return ctx.refuse("no_such_item", "There is no such thing.")
                    end
                    if not (inventory:has_container(args.from) and inventory:has_container(args.to)) then
                        return ctx.refuse("no_such_container", "That is not somewhere things go.")
                    end
                    local refused = require_reach(ctx, args.from, "there")
                        or require_reach(ctx, args.to, "there")
                    if refused then return refused end

                    local ok, why = inventory:move(
                        ctx.operation_id or ("move:%s:%d"):format(ctx.actor, ctx.now),
                        args.from, args.to, args.item, args.count, { reason = "moved" })
                    if not ok then return ctx.refuse("will_not_fit", why) end

                    ctx.emit("inventory.moved", { actor = ctx.actor, from = args.from,
                        to = args.to, item = args.item, count = args.count })
                    return ctx.ok()
                end,
            })

            --- Whether somebody is carrying this many of something. False, not
            --- a thrown error, for somebody with no pockets at all: a missing
            --- container throws, and a character whose pockets were lost got a
            --- server error from every drop and use instead of an answer.
            local function carrying(actor, item, count)
                local pockets = InventorySystem.pockets(actor)
                return inventory:has_container(pockets) and inventory:has(pockets, item, count)
            end

            --- Getting rid of something you are carrying.
            ---
            --- Gone, not on the ground. A drop made a new container and moved
            --- the things into it, and nothing in the city could ever reach
            --- one: nothing grants reach to a pile, the adapter does not know
            --- where one is, and nothing ever removed one. So what was dropped
            --- could never be picked up by anybody, and every drop wrote a
            --- container into the saved city for good -- every refused drop as
            --- well, because the pile was made before the drop was checked.
            --- One client made thirty-six thousand of them in ten real minutes.
            --- A thing on the ground that nobody can ever reach is a thing
            --- thrown away, so that is what this does, out of the world across
            --- a named reason in the inventory's log, and it says so.
            world:define("inventory.drop", {
                summary = "throw away things you are carrying",
                rate = { per_minute = 60 },
                args = {
                    item = { type = "string", required = true, max = 32 },
                    count = { type = "integer", required = true, min = 1, max = 10000 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local definition = items:get(args.item)
                    if not definition then return ctx.refuse("no_such_item", "There is no such thing.") end
                    if not definition.droppable then
                        return ctx.refuse("cannot_drop", ("A %s is not something you can leave lying about.")
                            :format(definition.label))
                    end
                    -- In words, not the inventory's own sentence, which names
                    -- the pockets by the character id.
                    if not carrying(ctx.actor, args.item, args.count) then
                        return ctx.refuse("not_carrying", "You do not have that many.")
                    end
                    local ok, why = inventory:destroy(
                        ctx.operation_id or ("drop:%s:%d"):format(ctx.actor, ctx.now),
                        InventorySystem.pockets(ctx.actor), args.item, args.count,
                        { reason = "dropped" })
                    if not ok then
                        return ctx.refuse("not_carrying", "You do not have that many.", { detail = why })
                    end

                    ctx.emit("inventory.dropped", { actor = ctx.actor,
                        item = args.item, count = args.count })
                    return ctx.ok()
                end,
            })

            world:define("inventory.use", {
                summary = "use up one of something you are carrying",
                rate = { per_minute = 60 },
                args = { item = { type = "string", required = true, max = 32 } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local definition = items:get(args.item)
                    if not definition then return ctx.refuse("no_such_item", "There is no such thing.") end
                    -- Only what gets used up. This destroyed whatever it was
                    -- asked to, and nothing listens for what it announces:
                    -- "using" a phone threw away the only one a person is ever
                    -- handed, and the phone refused them from then on; "using"
                    -- a passport destroyed a document a drop will not let go of.
                    if definition.category ~= "consumable" then
                        return ctx.refuse("cannot_use", ("A %s is not something you use up.")
                            :format(definition.label))
                    end
                    local pockets = InventorySystem.pockets(ctx.actor)
                    if not carrying(ctx.actor, args.item, 1) then
                        return ctx.refuse("not_carrying", ("You have no %s."):format(definition.label))
                    end
                    -- The item leaves the world here. What using it actually
                    -- does is somebody else listening for the event, which is
                    -- how food, medicine and tools stay separate systems.
                    local ok, why = inventory:destroy(
                        ctx.operation_id or ("use:%s:%d"):format(ctx.actor, ctx.now),
                        pockets, args.item, 1, { reason = "used" })
                    if not ok then
                        return ctx.refuse("not_carrying", ("You have no %s."):format(definition.label),
                            { detail = why })
                    end
                    ctx.emit("inventory.used", { actor = ctx.actor, item = args.item,
                        category = definition.category })
                    return ctx.ok()
                end,
            })

            -- Leaving closes everything you had open. Otherwise a grant
            -- outlives the person it was made to and the next holder of that
            -- character id inherits it.
            world:on("character.released", function(payload)
                access:revoke(payload.character)
            end, { label = "inventory:release" })
        end,
    }
end

return InventorySystem
