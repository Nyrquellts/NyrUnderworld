--- The store contract, and the implementation that keeps nothing.
--
-- A store is a dumb key-value box for plain tables. It knows nothing about
-- entities, money or the city. Everything above it talks to this interface, so
-- the same repository runs against memory in a spec, a JSON file on a dev box
-- and a database on a live server without one line of gameplay code changing.
--
-- The contract every store keeps:
--
--   get(collection, key)      the record, or nil
--   put(collection, key, rec) store a plain table
--   delete(collection, key)   true if something was there
--   keys(collection)          sorted, so output is stable
--   each(collection)          iterate key, record in sorted order
--   count(collection)
--   collections()             sorted
--   flush()                   make it durable; ok, err
--   close()                   flush and release
--
-- Records go in and come out deep-copied. A caller that keeps a reference to
-- what it stored cannot reach back in and change it, which is the same class
-- of bug as two objects claiming one id.

local MemoryStore = {}
MemoryStore.__index = MemoryStore

-- Collection names become file names in the file store and table names in the
-- database one, so they are constrained here, once, for every store.
local COLLECTION_PATTERN = "^%l[%l%d_]*$"
local COLLECTION_MAX = 48

function MemoryStore.is_collection(name)
    return type(name) == "string" and #name <= COLLECTION_MAX and name:match(COLLECTION_PATTERN) ~= nil
end

MemoryStore.COLLECTION_PATTERN = COLLECTION_PATTERN

local function require_collection(name)
    if not MemoryStore.is_collection(name) then
        error(("collection name must be lowercase letters, digits and underscores, got %s")
            :format(tostring(name)), 3)
    end
    return name
end

local function require_key(key)
    if type(key) ~= "string" or key == "" then
        error(("a store key must be a non-empty string, got %s"):format(tostring(key)), 3)
    end
    return key
end

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    if getmetatable(value) ~= nil then
        error("a store holds plain tables only; this one has a metatable", 4)
    end
    local out = {}
    for key, item in pairs(value) do out[deep_copy(key)] = deep_copy(item) end
    return out
end

MemoryStore.deep_copy = deep_copy

function MemoryStore.new()
    return setmetatable({ _data = {}, _writes = 0 }, MemoryStore)
end

function MemoryStore:get(collection, key)
    require_collection(collection)
    require_key(key)
    local bucket = self._data[collection]
    if not bucket then return nil end
    local record = bucket[key]
    if record == nil then return nil end
    return deep_copy(record)
end

function MemoryStore:put(collection, key, record)
    require_collection(collection)
    require_key(key)
    if type(record) ~= "table" then
        error("a store holds tables; got " .. type(record), 2)
    end
    local bucket = self._data[collection]
    if not bucket then
        bucket = {}
        self._data[collection] = bucket
    end
    bucket[key] = deep_copy(record)
    self._writes = self._writes + 1
    return true
end

function MemoryStore:delete(collection, key)
    require_collection(collection)
    require_key(key)
    local bucket = self._data[collection]
    if not bucket or bucket[key] == nil then return false end
    bucket[key] = nil
    if next(bucket) == nil then self._data[collection] = nil end
    self._writes = self._writes + 1
    return true
end

function MemoryStore:keys(collection)
    require_collection(collection)
    local bucket = self._data[collection]
    if not bucket then return {} end
    local out = {}
    for key in pairs(bucket) do out[#out + 1] = key end
    table.sort(out)
    return out
end

--- Iterate a collection in key order. Sorted because an unsorted iteration
--- makes a bug reproduce on one machine and not the next.
function MemoryStore:each(collection)
    local keys = self:keys(collection)
    local index = 0
    return function()
        index = index + 1
        local key = keys[index]
        if key == nil then return nil end
        return key, self:get(collection, key)
    end
end

function MemoryStore:count(collection)
    return #self:keys(collection)
end

function MemoryStore:collections()
    local out = {}
    for name in pairs(self._data) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Memory is never durable, and saying so is better than pretending.
function MemoryStore:flush() return true end

function MemoryStore:close()
    self._data = {}
    return true
end

--- How many writes this store has taken. A spec asserts on it to prove a
--- repository is not writing the same record over and over.
function MemoryStore:writes() return self._writes end

return MemoryStore
