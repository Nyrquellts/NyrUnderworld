--- Entities in, entities out, over any store.
--
-- A repository is the only thing in the project that turns a record into an
-- entity or an entity into a record. Gameplay code never touches a store
-- directly, so the day the file store becomes a database, gameplay code does
-- not change.
--
-- The rule that matters most here is the identity map: loading the same id
-- twice hands back the same Lua table. Two in-memory copies of one vehicle is
-- the duplication bug wearing a different hat, and it is far harder to see
-- than two rows, because both copies look right on their own. So the
-- repository refuses to hold two objects for one id, and says so.
--
-- The second rule: nothing invalid is written. An entity that fails its own
-- validation is refused at save, where the stack trace still names whatever
-- put the bad value in, rather than at load, three restarts later.

local Entity = require("domain.entity")
local Id = require("domain.id")

local Repository = {}
Repository.__index = Repository

--- entity_type    the table Entity.define returned
--- store          anything keeping the store contract
--- opts.collection  defaults to the entity kind
function Repository.new(entity_type, store, opts)
    assert(type(entity_type) == "table" and entity_type.kind and entity_type.deserialize,
        "a repository needs a type from Entity.define")
    assert(type(store) == "table" and store.get and store.put, "a repository needs a store")
    opts = opts or {}
    return setmetatable({
        type = entity_type,
        kind = entity_type.kind,
        store = store,
        collection = opts.collection or entity_type.kind,
        clock = opts.clock,
        _live = {},        -- id -> entity, the identity map
        _loaded_all = false,
    }, Repository)
end

local function check_id(self, id)
    if not Id.is_a(id, self.kind) then
        return nil, ("%s is not a %s id"):format(tostring(id), self.kind)
    end
    return id
end

--- The entity already in memory, if there is one. No disk access.
function Repository:get(id)
    return self._live[id]
end

--- Fetch by id: from the identity map if it is already live, from the store
--- otherwise. Returns nil with no error when it simply does not exist, and nil
--- with a reason when it exists but will not load.
function Repository:load(id)
    local ok, why = check_id(self, id)
    if not ok then return nil, why end
    local live = self._live[id]
    if live then return live end
    local record = self.store:get(self.collection, id)
    if record == nil then return nil end
    local entity, err = self.type.deserialize(record)
    if not entity then
        return nil, ("%s in %s will not load: %s"):format(id, self.collection, tostring(err))
    end
    self._live[id] = entity
    return entity
end

--- Write an entity. Validates first, refuses a second object for a live id.
function Repository:save(entity)
    if not Entity.is(entity) then return false, "not an entity" end
    if entity.kind ~= self.kind then
        return false, ("a %s repository will not store a %s"):format(self.kind, entity.kind)
    end
    local existing = self._live[entity.id]
    if existing ~= nil and existing ~= entity then
        return false, ("two different objects both claim %s"):format(entity.id)
    end
    local valid, why = entity:validate()
    if not valid then
        return false, ("%s is not valid: %s"):format(entity.id, tostring(why))
    end
    self.store:put(self.collection, entity.id, entity:serialize())
    self._live[entity.id] = entity
    return true
end

--- Make one and store it in a single step, so a caller cannot forget the save.
function Repository:create(attrs, opts)
    opts = opts or {}
    -- Entities created through a repository are stamped in the time the world
    -- runs on, not the wall clock, so a save file reads in city time.
    if opts.now == nil and self.clock then opts.now = self.clock() end
    local entity, why = self.type.new(attrs, opts)
    if not entity then return nil, why end
    local ok, err = self:save(entity)
    if not ok then return nil, err end
    return entity
end

function Repository:exists(id)
    if self._live[id] then return true end
    return self.store:get(self.collection, id) ~= nil
end

function Repository:delete(id)
    local ok, why = check_id(self, id)
    if not ok then return false, why end
    self._live[id] = nil
    return self.store:delete(self.collection, id)
end

--- Stop holding an entity in memory without deleting it. For a character who
--- logged out: the record stays, the object goes.
function Repository:forget(id)
    local entity = self._live[id]
    self._live[id] = nil
    self._loaded_all = false
    return entity
end

function Repository:ids()
    return self.store:keys(self.collection)
end

function Repository:count()
    return self.store:count(self.collection)
end

--- Every entity in the collection, in id order, which is creation order. Loads
--- what is not yet live. Returns the list and, separately, anything that would
--- not load, because a boot that silently skips three broken vehicles is worse
--- than one that says which three.
function Repository:all()
    local out, broken = {}, {}
    for _, id in ipairs(self:ids()) do
        local entity, why = self:load(id)
        if entity then
            out[#out + 1] = entity
        elseif why then
            broken[#broken + 1] = why
        end
    end
    self._loaded_all = true
    return out, broken
end

--- Every live entity matching a predicate. Reads memory only, so it is cheap
--- enough to call in a tick; call all() first if the collection is cold.
function Repository:where(predicate)
    local out = {}
    for _, entity in pairs(self._live) do
        if predicate(entity) then out[#out + 1] = entity end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Validate and serialize changed entities without writing to the store.
--- World prepares every repository before applying any part of a checkpoint.
function Repository:prepare_save()
    local pending, failures = {}, {}
    for id, entity in pairs(self._live) do
        local valid, why = entity:validate()
        if not valid then
            failures[#failures + 1] = ("%s is not valid: %s"):format(id, tostring(why))
        else
            local record = entity:serialize()
            if type(record) ~= "table" then
                failures[#failures + 1] = ("%s did not serialize to a record"):format(id)
            elseif not Entity.deep_equal(record, self.store:get(self.collection, id)) then
                pending[#pending + 1] = { collection = self.collection, key = id, record = record }
            end
        end
    end
    table.sort(failures)
    return #failures == 0, pending, failures
end

--- Write changed live entities, then make the store durable.
function Repository:persist()
    local prepared, pending, failures = self:prepare_save()
    if not prepared then return false, 0, failures end
    for _, write in ipairs(pending) do
        self.store:put(write.collection, write.key, write.record)
    end
    if #failures == 0 then
        local ok, why = self.store:flush()
        if not ok then
            if type(why) == "table" then
                for _, message in ipairs(why) do failures[#failures + 1] = message end
            else
                failures[#failures + 1] = tostring(why)
            end
        end
    end
    table.sort(failures)
    return #failures == 0, #pending, failures
end

function Repository:live_count()
    local n = 0
    for _ in pairs(self._live) do n = n + 1 end
    return n
end

return Repository
