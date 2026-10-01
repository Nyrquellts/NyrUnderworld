--- Which things exist, and where they are.
--
-- Item duplication is the oldest exploit in this genre and it always has the
-- same shape: two code paths both believed they were holding the same stack.
-- So the inventory keeps the same promise the ledger keeps about money, and
-- keeps it the same way.
--
--   Things move; they do not appear. A move changes where a count is, never
--   how much of it there is in the world.
--
--   Things enter and leave the world across a named reason, so creation and
--   destruction are recorded lines rather than a number changing.
--
--   Every change is idempotent by operation id, so a retried command, a
--   replayed event or a doubled click does it once.
--
--   Every change is checked in full before any of it is applied, so a move
--   that does not fit leaves nothing half-done.
--
-- The conservation law is a single assertion an admin can run on a live
-- server: for every kind of thing, what is in containers equals what was
-- issued into the world minus what was destroyed. verify() checks it.

local Id = require("domain.id")

local Inventory = {}
Inventory.__index = Inventory

local CONTAINER_PATTERN = "^[%w_%-%.:]+$"
local CONTAINER_MAX = 96
local APPLIED_LIMIT = 5000            -- the changes whose operation ids are remembered

function Inventory.is_container_id(value)
    return type(value) == "string" and value ~= "" and #value <= CONTAINER_MAX
        and value:match(CONTAINER_PATTERN) ~= nil
end

local function require_container_id(value)
    if not Inventory.is_container_id(value) then
        error(("a container id is letters, digits and . _ - : ; got %s"):format(tostring(value)), 3)
    end
    return value
end

local function require_operation(operation_id)
    if type(operation_id) ~= "string" or operation_id == "" then
        error("every inventory change needs an operation id", 3)
    end
    return operation_id
end

local function require_count(count)
    if math.type(count) ~= "integer" or count <= 0 then
        error(("a count is a whole number above zero; got %s"):format(tostring(count)), 3)
    end
    return count
end

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deep_copy(item) end
    return out
end

--- opts.items          a catalogue from domain/items
--- opts.clock          function returning integer milliseconds
--- opts.applied_limit  how many of the latest changes keep their operation ids
function Inventory.new(opts)
    opts = opts or {}
    assert(opts.items and opts.items.require, "an inventory needs an item catalogue")
    return setmetatable({
        items = opts.items,
        _containers = {},        -- id -> { id, slots, weight, stacks = {} }
        _issued = {},            -- item -> net count that entered the world
        _applied = {},           -- operation id -> the change it made; successes only
        _applied_order = {},     -- those ids, oldest first, from _applied_first to _applied_last
        _applied_first = 1,
        _applied_last = 0,
        _applied_limit = opts.applied_limit or APPLIED_LIMIT,
        _log = {},
        _log_limit = opts.log_limit or 2000,
        _clock = opts.clock or function() return math.floor(os.time()) * 1000 end,
    }, Inventory)
end

-- ------------------------------------------------------------- containers

--- Declare a container. slots and weight may both be nil, meaning no limit,
--- which is what a shop stockroom or the world itself wants.
function Inventory:define_container(id, spec)
    require_container_id(id)
    spec = spec or {}
    if self._containers[id] then return self._containers[id] end
    assert(spec.slots == nil or (math.type(spec.slots) == "integer" and spec.slots > 0),
        ("container %s needs a positive slot count or none at all"):format(id))
    assert(spec.weight == nil or (math.type(spec.weight) == "integer" and spec.weight > 0),
        ("container %s needs a positive weight limit in grams or none at all"):format(id))
    local container = {
        id = id,
        slots = spec.slots,
        weight = spec.weight,
        label = spec.label,
        stacks = {},
    }
    self._containers[id] = container
    return container
end

function Inventory:has_container(id) return self._containers[id] ~= nil end

local function container_or_error(self, id, what)
    require_container_id(id)
    local container = self._containers[id]
    if not container then
        error(("there is no container called %s (%s)"):format(id, what or "container"), 3)
    end
    return container
end

function Inventory:containers()
    local out = {}
    for id in pairs(self._containers) do out[#out + 1] = id end
    table.sort(out)
    return out
end

--- What is in a container, in slot order, as plain data.
function Inventory:contents(id)
    local container = container_or_error(self, id)
    local out = {}
    for index, stack in ipairs(container.stacks) do
        out[index] = {
            item = stack.item,
            count = stack.count,
            instance = stack.instance,
            meta = stack.meta and deep_copy(stack.meta) or nil,
        }
    end
    return out
end

function Inventory:used_slots(id)
    return #container_or_error(self, id).stacks
end

function Inventory:used_weight(id)
    local container = container_or_error(self, id)
    local total = 0
    for _, stack in ipairs(container.stacks) do
        total = total + self.items:weight(stack.item) * stack.count
    end
    return total
end

function Inventory:space(id)
    local container = container_or_error(self, id)
    return {
        slots = container.slots,
        slots_used = #container.stacks,
        slots_free = container.slots and (container.slots - #container.stacks) or nil,
        weight = container.weight,
        weight_used = self:used_weight(id),
        weight_free = container.weight and (container.weight - self:used_weight(id)) or nil,
    }
end

function Inventory:count(id, item)
    local container = container_or_error(self, id)
    local total = 0
    for _, stack in ipairs(container.stacks) do
        if stack.item == item then total = total + stack.count end
    end
    return total
end

function Inventory:has(id, item, count)
    return self:count(id, item) >= (count or 1)
end

--- Find a unique instance: which container holds it, and the stack itself.
---
--- The guard is not decoration. A stackable stack has no instance, so without
--- it a nil or malformed instance matches the first ordinary stack in the
--- world, and a "move this one named thing" turns into moving one unit out of
--- somebody bag of water and destroying the rest of it.
function Inventory:find(instance)
    if not Id.is_a(instance, "itm") then return nil end
    for _, container_id in ipairs(self:containers()) do
        for _, stack in ipairs(self._containers[container_id].stacks) do
            if stack.instance == instance then
                return container_id, { item = stack.item, count = stack.count,
                                       instance = stack.instance,
                                       meta = stack.meta and deep_copy(stack.meta) or nil }
            end
        end
    end
    return nil
end

-- ------------------------------------------------------ planning a change
--
-- Nothing below mutates until every check has passed. A move that does not fit
-- must leave both containers exactly as they were.

--- How many new slots adding this many of an item would need, given that it
--- fills part-full stacks of the same kind first.
local function plan_add(self, container, item_id, count)
    local definition = self.items:require(item_id)
    if definition.unique then return count end      -- one slot each, never merged
    local remaining = count
    for _, stack in ipairs(container.stacks) do
        if stack.item == item_id and stack.count < definition.stack then
            remaining = remaining - math.min(remaining, definition.stack - stack.count)
            if remaining <= 0 then return 0 end
        end
    end
    return math.ceil(remaining / definition.stack)
end

local function fits(self, container, item_id, count)
    local definition = self.items:require(item_id)
    if container.weight then
        local after = self:used_weight(container.id) + definition.weight * count
        if after > container.weight then
            return false, ("%s cannot carry that much; %d grams over"):format(
                container.id, after - container.weight)
        end
    end
    if container.slots then
        local needed = plan_add(self, container, item_id, count)
        if #container.stacks + needed > container.slots then
            return false, ("%s has no room; %d more slot(s) needed"):format(
                container.id, #container.stacks + needed - container.slots)
        end
    end
    return true
end

--- Whether a container could take this, without changing anything. What a shop
--- interface asks before offering to sell.
function Inventory:would_fit(id, item, count)
    local container = container_or_error(self, id)
    self.items:require(item)
    return fits(self, container, item, require_count(count))
end

-- ------------------------------------------------------ applying a change

local function add_to(self, container, item_id, count, meta, instances)
    local definition = self.items:require(item_id)
    if definition.unique then
        for index = 1, count do
            container.stacks[#container.stacks + 1] = {
                item = item_id,
                count = 1,
                instance = instances and instances[index] or Id.new("itm", { now = self._clock() }),
                meta = meta and deep_copy(meta) or nil,
            }
        end
        return
    end
    local remaining = count
    for _, stack in ipairs(container.stacks) do
        if stack.item == item_id and stack.count < definition.stack then
            local room = definition.stack - stack.count
            local taken = math.min(room, remaining)
            stack.count = stack.count + taken
            remaining = remaining - taken
            if remaining == 0 then return end
        end
    end
    while remaining > 0 do
        local taken = math.min(definition.stack, remaining)
        container.stacks[#container.stacks + 1] = { item = item_id, count = taken }
        remaining = remaining - taken
    end
end

--- Remove `count` of an item, taking from the earliest stacks first so the
--- result does not depend on table order. Returns what was taken, which for a
--- unique item carries the instances and their notes so they survive the move.
local function remove_from(container, item_id, count)
    local taken, remaining = {}, count
    local index = 1
    while index <= #container.stacks and remaining > 0 do
        local stack = container.stacks[index]
        if stack.item == item_id then
            local amount = math.min(stack.count, remaining)
            taken[#taken + 1] = { count = amount, instance = stack.instance, meta = stack.meta }
            stack.count = stack.count - amount
            remaining = remaining - amount
            if stack.count == 0 then
                table.remove(container.stacks, index)
            else
                index = index + 1
            end
        else
            index = index + 1
        end
    end
    return taken
end

local function record(self, operation_id, action, detail)
    local entry = { at = self._clock(), operation_id = operation_id, action = action }
    for key, value in pairs(detail) do entry[key] = value end
    self._log[#self._log + 1] = entry
    while #self._log > self._log_limit do table.remove(self._log, 1) end
    return entry
end

--- Remember a change that was made, so the same operation id makes it once.
---
--- Only a change that was made. A refusal changed nothing, so there is nothing
--- to protect and its id is still free: refusals were kept, and a client told
--- no that tried again with the same token and other arguments raised "already
--- applied" inside the handler, which the command door reports as a server
--- failure. core/commands.lua keeps only successes for the same reason.
---
--- And not for ever. These live in memory and are never written down, so a
--- restart already forgets every one; what stops a client's retry across time
--- is the receipt the command door saves, and the ledger's. What these hold
--- together is one id doing one thing within a run -- the same id reached
--- twice in one request, one tick, one catch-up -- and the most recent
--- thousands of changes cover that many times over, where keeping them all
--- grew with every move the city ever made.
local function remember(self, operation_id, signature)
    if self._applied[operation_id] == nil then
        self._applied_last = self._applied_last + 1
        self._applied_order[self._applied_last] = operation_id
    end
    self._applied[operation_id] = { signature = signature }
    while self._applied_last - self._applied_first + 1 > self._applied_limit do
        local oldest = self._applied_order[self._applied_first]
        self._applied_order[self._applied_first] = nil
        self._applied_first = self._applied_first + 1
        self._applied[oldest] = nil
    end
    return true
end

local function replay(self, operation_id, signature)
    local previous = self._applied[operation_id]
    if not previous then return nil end
    if previous.signature ~= signature then
        error(("operation %s was already applied to %s; it cannot also mean %s")
            :format(operation_id, previous.signature, signature), 3)
    end
    return previous
end

-- --------------------------------------------------------------- the verbs

--- Put something into the world. The only way a count goes up.
function Inventory:spawn(operation_id, container_id, item_id, count, meta)
    require_operation(operation_id)
    local container = container_or_error(self, container_id)
    self.items:require(item_id)
    require_count(count)
    local signature = ("spawn:%s:%s:%d"):format(container_id, item_id, count)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    local room, why = fits(self, container, item_id, count)
    if not room then return false, why end

    add_to(self, container, item_id, count, meta)
    self._issued[item_id] = (self._issued[item_id] or 0) + count
    record(self, operation_id, "spawn", { container = container_id, item = item_id,
        count = count, reason = meta and meta.reason })
    return remember(self, operation_id, signature)
end

--- Take something out of the world. The only way a count goes down.
function Inventory:destroy(operation_id, container_id, item_id, count, meta)
    require_operation(operation_id)
    local container = container_or_error(self, container_id)
    self.items:require(item_id)
    require_count(count)
    local signature = ("destroy:%s:%s:%d"):format(container_id, item_id, count)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    local held = self:count(container_id, item_id)
    if held < count then
        return false, ("%s holds %d of %s, not %d"):format(container_id, held, item_id, count)
    end

    remove_from(container, item_id, count)
    self._issued[item_id] = (self._issued[item_id] or 0) - count
    record(self, operation_id, "destroy", { container = container_id, item = item_id,
        count = count, reason = meta and meta.reason })
    return remember(self, operation_id, signature)
end

--- Move things between containers. The count in the world does not change.
function Inventory:move(operation_id, from_id, to_id, item_id, count, meta)
    require_operation(operation_id)
    local from = container_or_error(self, from_id, "source")
    local to = container_or_error(self, to_id, "destination")
    self.items:require(item_id)
    require_count(count)
    local signature = ("move:%s:%s:%s:%d"):format(from_id, to_id, item_id, count)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    if from_id == to_id then
        return false, "that is the same container"
    end
    local held = self:count(from_id, item_id)
    if held < count then
        return false, ("%s holds %d of %s, not %d"):format(from_id, held, item_id, count)
    end
    local room, why = fits(self, to, item_id, count)
    if not room then return false, why end

    -- Both sides have been checked, so from here nothing can fail part way.
    local taken = remove_from(from, item_id, count)
    for _, part in ipairs(taken) do
        add_to(self, to, item_id, part.count, part.meta, part.instance and { part.instance } or nil)
    end
    record(self, operation_id, "move", { from = from_id, to = to_id, item = item_id,
        count = count, reason = meta and meta.reason })
    return remember(self, operation_id, signature)
end

--- Move one named unique thing, so a specific pistol with a specific serial
--- goes where it is meant to and not whichever one happened to be first.
function Inventory:move_instance(operation_id, to_id, instance, meta)
    require_operation(operation_id)
    local to = container_or_error(self, to_id, "destination")
    local signature = ("instance:%s:%s"):format(to_id, tostring(instance))
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    if not Id.is_a(instance, "itm") then
        return false, ("%s is not the name of a thing"):format(tostring(instance))
    end
    local from_id, stack = self:find(instance)
    if not from_id then
        return false, ("nothing anywhere is %s"):format(tostring(instance))
    end
    if from_id == to_id then
        return false, "it is already there"
    end
    local room, why = fits(self, to, stack.item, 1)
    if not room then return false, why end

    local from = self._containers[from_id]
    for index, candidate in ipairs(from.stacks) do
        if candidate.instance == instance then
            table.remove(from.stacks, index)
            break
        end
    end
    to.stacks[#to.stacks + 1] = { item = stack.item, count = 1, instance = instance, meta = stack.meta }
    record(self, operation_id, "move", { from = from_id, to = to_id, item = stack.item,
        count = 1, instance = instance, reason = meta and meta.reason })
    return remember(self, operation_id, signature)
end

-- ------------------------------------------------------------------ audit

--- What is in the world, per item, across every container.
function Inventory:total(item_id)
    local total = 0
    for _, container in pairs(self._containers) do
        for _, stack in ipairs(container.stacks) do
            if stack.item == item_id then total = total + stack.count end
        end
    end
    return total
end

function Inventory:issued(item_id) return self._issued[item_id] or 0 end

--- The conservation law, checkable on a live server: for every kind of thing,
--- what is in containers is exactly what was put into the world. If this is
--- ever false, something duplicated or vanished, and the log says when.
function Inventory:verify()
    local problems = {}
    local seen = {}
    for item_id in pairs(self._issued) do seen[item_id] = true end
    for _, container in pairs(self._containers) do
        for _, stack in ipairs(container.stacks) do
            seen[stack.item] = true
            if math.type(stack.count) ~= "integer" or stack.count <= 0 then
                problems[#problems + 1] = ("%s in %s has a count of %s")
                    :format(stack.item, container.id, tostring(stack.count))
            end
            local limit = self.items:stack_size(stack.item)
            if stack.count > limit then
                problems[#problems + 1] = ("%s in %s stacks %d above its limit of %d")
                    :format(stack.item, container.id, stack.count, limit)
            end
            -- A unique thing is one thing with a name; an ordinary one is a
            -- count with no name. A stack that is neither is corruption, and
            -- it is worth catching here rather than when somebody trades it.
            if self.items:is_unique(stack.item) then
                if stack.count ~= 1 then
                    problems[#problems + 1] = ("%s in %s is unique but has a count of %d")
                        :format(stack.item, container.id, stack.count)
                end
                if not Id.is_a(stack.instance, "itm") then
                    problems[#problems + 1] = ("a %s in %s has no name of its own")
                        :format(stack.item, container.id)
                end
            elseif stack.instance ~= nil then
                problems[#problems + 1] = ("%s in %s does not stack but carries a name")
                    :format(stack.item, container.id)
            end
        end
        if container.slots and #container.stacks > container.slots then
            problems[#problems + 1] = ("%s holds %d stacks in %d slots")
                :format(container.id, #container.stacks, container.slots)
        end
    end
    for item_id in pairs(seen) do
        local held, issued = self:total(item_id), self:issued(item_id)
        if held ~= issued then
            problems[#problems + 1] = ("%s: %d in containers but %d issued into the world")
                :format(item_id, held, issued)
        end
    end
    local instances = {}
    for _, container in pairs(self._containers) do
        for _, stack in ipairs(container.stacks) do
            if stack.instance then
                if instances[stack.instance] then
                    problems[#problems + 1] = ("%s is in %s and in %s at once")
                        :format(stack.instance, instances[stack.instance], container.id)
                end
                instances[stack.instance] = container.id
            end
        end
    end
    table.sort(problems)
    return #problems == 0, problems
end

--- Everything that happened, newest last. What an admin reads when a player
--- says their bag emptied itself.
function Inventory:log(limit)
    local out = {}
    local from = limit and math.max(1, #self._log - limit + 1) or 1
    for index = from, #self._log do out[#out + 1] = deep_copy(self._log[index]) end
    return out
end

-- ------------------------------------------------------------ persistence

function Inventory:serialize()
    local containers = {}
    for id, container in pairs(self._containers) do
        local stacks = {}
        for index, stack in ipairs(container.stacks) do
            stacks[index] = { item = stack.item, count = stack.count,
                              instance = stack.instance,
                              meta = stack.meta and deep_copy(stack.meta) or nil }
        end
        containers[id] = { slots = container.slots, weight = container.weight,
                           label = container.label, stacks = stacks }
    end
    local issued = {}
    for item_id, count in pairs(self._issued) do issued[item_id] = count end
    return { containers = containers, issued = issued }
end

function Inventory.deserialize(record_table, opts)
    if type(record_table) ~= "table" then return nil, "an inventory record is a table" end
    local inventory = Inventory.new(opts)
    for id, container in pairs(record_table.containers or {}) do
        if not Inventory.is_container_id(id) then
            return nil, ("%s is not a container id"):format(tostring(id))
        end
        local made = inventory:define_container(id, { slots = container.slots,
            weight = container.weight, label = container.label })
        for index, stack in ipairs(container.stacks or {}) do
            if not inventory.items:has(stack.item) then
                return nil, ("%s in %s is not an item this build knows"):format(tostring(stack.item), id)
            end
            if math.type(stack.count) ~= "integer" or stack.count <= 0 then
                return nil, ("%s in %s has a count of %s"):format(stack.item, id, tostring(stack.count))
            end
            made.stacks[index] = { item = stack.item, count = stack.count,
                                   instance = stack.instance,
                                   meta = stack.meta and deep_copy(stack.meta) or nil }
        end
    end
    for item_id, count in pairs(record_table.issued or {}) do
        if math.type(count) ~= "integer" then
            return nil, ("%s was issued a non-whole count"):format(tostring(item_id))
        end
        inventory._issued[item_id] = count
    end
    -- A stored inventory that does not add up is corrupt, and loading it would
    -- either duplicate things or make them vanish.
    local ok, problems = inventory:verify()
    if not ok then
        return nil, ("the stored inventory does not add up: %s"):format(problems[1])
    end
    return inventory
end

return Inventory
