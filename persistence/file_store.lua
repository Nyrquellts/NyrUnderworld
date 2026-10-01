--- The same store contract, backed by JSON files that survive a crash.
--
-- One file per collection. Writes are held in memory and land on disk at
-- flush, because a server that writes a whole collection on every field change
-- spends its frame budget on the filesystem.
--
-- Crash safety, given that a plain rename over an existing file is not atomic
-- on Windows:
--
--   1. write the new content to <name>.json.tmp and close it
--   2. move the current <name>.json aside to <name>.json.bak
--   3. rename the tmp into place
--
-- A crash in step 2 or 3 leaves the previous version in .bak, and load falls
-- back to it and says so. The window where both are gone does not exist: the
-- old file is only removed after the new one is written.
--
-- A corrupt main file is treated the same way as a missing one: fall back,
-- report, never silently start a fresh empty collection over the top of
-- somebody data. Losing a city quietly is the worst outcome available here.

local json = require("support.json")
local MemoryStore = require("persistence.memory_store")

local FileStore = {}
FileStore.__index = FileStore

local deep_copy = MemoryStore.deep_copy

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

local function read_file(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

local function write_file(path, text)
    local handle, why = io.open(path, "wb")
    if not handle then return false, why end
    local ok, err = handle:write(text)
    if not ok then
        handle:close()
        return false, err
    end
    handle:close()
    return true
end

local function exists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

--- opts.root      directory holding the files; required
--- opts.indent    write readable JSON (default true; these files get opened)
--- opts.on_notice called with a message when a fallback or a repair happens
function FileStore.new(opts)
    opts = opts or {}
    assert(type(opts.root) == "string" and opts.root ~= "", "a file store needs a root directory")
    local root = opts.root:gsub("[\\/]+$", "")
    return setmetatable({
        _root = root,
        _indent = opts.indent ~= false,
        _notice = opts.on_notice,
        _data = {},        -- collection -> key -> record
        _loaded = {},      -- collection -> true once read from disk
        _dirty = {},       -- collection -> true when it differs from disk
        _writes = 0,
        _notices = {},
        _recovered = {},
    }, FileStore)
end

function FileStore:path(collection)
    return ("%s/%s.json"):format(self._root, require_collection(collection))
end

local function notice(self, message)
    self._notices[#self._notices + 1] = message
    if self._notice then self._notice(message) end
end

--- Everything the store had to say: a fallback to a backup, a file it could
--- not parse. A server prints these at boot; a spec asserts on them.
function FileStore:notices() return deep_copy(self._notices) end

local function load_collection(self, collection)
    if self._blocked then error(self._blocked, 2) end
    if self._loaded[collection] then return end
    self._loaded[collection] = true
    self._data[collection] = {}

    local path = self:path(collection)
    local text = read_file(path)
    local from_backup = false
    if text then
        local decoded, why = json.decode(text)
        if type(decoded) == "table" then
            self._data[collection] = decoded
            return
        end
        notice(self, ("%s.json did not parse (%s); falling back to the backup")
            :format(collection, tostring(why)))
        from_backup = true
    elseif exists(path .. ".bak") then
        notice(self, ("%s.json is missing; falling back to the backup"):format(collection))
        from_backup = true
    end

    if from_backup then
        local backup = read_file(path .. ".bak")
        local decoded = backup and json.decode(backup)
        if type(decoded) == "table" then
            self._data[collection] = decoded
            -- The backup is now the truth, so the next flush must write it
            -- back into place rather than leaving the bad file there.
            self._dirty[collection] = true
            self._recovered[collection] = true
            notice(self, ("%s recovered from its backup"):format(collection))
        else
            self._blocked = ("%s could not be recovered; restore its save before restarting"):format(collection)
            notice(self, self._blocked)
            error(self._blocked, 2)
        end
    end
end

function FileStore:get(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    local record = self._data[collection][key]
    if record == nil then return nil end
    return deep_copy(record)
end

function FileStore:put(collection, key, record)
    require_collection(collection)
    require_key(key)
    if type(record) ~= "table" then error("a store holds tables; got " .. type(record), 2) end
    load_collection(self, collection)
    self._data[collection][key] = deep_copy(record)
    self._dirty[collection] = true
    self._writes = self._writes + 1
    return true
end

function FileStore:delete(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    if self._data[collection][key] == nil then return false end
    self._data[collection][key] = nil
    self._dirty[collection] = true
    self._writes = self._writes + 1
    return true
end

function FileStore:keys(collection)
    require_collection(collection)
    load_collection(self, collection)
    local out = {}
    for key in pairs(self._data[collection]) do out[#out + 1] = key end
    table.sort(out)
    return out
end

function FileStore:each(collection)
    local keys = self:keys(collection)
    local index = 0
    return function()
        index = index + 1
        local key = keys[index]
        if key == nil then return nil end
        return key, self:get(collection, key)
    end
end

function FileStore:count(collection)
    return #self:keys(collection)
end

--- Collections this store knows about: loaded ones, plus every file on disk it
--- has not opened yet.
function FileStore:collections()
    local seen = {}
    for name in pairs(self._data) do seen[name] = true end
    for _, name in ipairs(self._known or {}) do seen[name] = true end
    local out = {}
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Tell the store a collection exists before anything has touched it, so a
--- boot sequence can preload. Needed because a pure Lua store has no way to
--- list a directory without shelling out, which it will not do.
function FileStore:declare(collection)
    require_collection(collection)
    self._known = self._known or {}
    for _, name in ipairs(self._known) do
        if name == collection then return self end
    end
    self._known[#self._known + 1] = collection
    return self
end

local function write_collection(self, collection)
    local path = self:path(collection)
    local text, why = json.encode(self._data[collection], { indent = self._indent })
    if not text then return false, ("%s could not be encoded: %s"):format(collection, tostring(why)) end

    local temporary = path .. ".tmp"
    local ok, err = write_file(temporary, text)
    if not ok then return false, ("%s could not be written: %s"):format(collection, tostring(err)) end

    -- Read it back before trusting it. A short write on a full disk is exactly
    -- the failure that would otherwise destroy the previous good file.
    local verify = read_file(temporary)
    if verify ~= text then
        os.remove(temporary)
        return false, ("%s did not write completely; the previous file is untouched"):format(collection)
    end

    local backup = path .. ".bak"
    if self._recovered[collection] then
        -- Keep the known-good backup if installing the repaired primary fails.
        if exists(path) then
            local removed, remove_err = os.remove(path)
            if not removed then return false, ("%s could not be repaired: %s"):format(collection, tostring(remove_err)) end
        end
    elseif exists(path) then
        os.remove(backup)
        local moved, move_err = os.rename(path, backup)
        if not moved then
            os.remove(temporary)
            return false, ("%s could not be rotated: %s"):format(collection, tostring(move_err))
        end
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        -- The previous version is in .bak and load will find it.
        return false, ("%s could not be put into place: %s"):format(collection, tostring(rename_err))
    end
    self._recovered[collection] = nil
    return true
end

--- Make every pending change durable. Returns false and the list of failures
--- rather than throwing, so a save loop can report and carry on with the rest.
function FileStore:flush()
    if self._blocked then return false, { self._blocked } end
    local failures = {}
    for collection in pairs(self._dirty) do
        local ok, why = write_collection(self, collection)
        if ok then
            self._dirty[collection] = nil
        else
            failures[#failures + 1] = why
        end
    end
    table.sort(failures)
    if #failures > 0 then return false, failures end
    return true
end

function FileStore:is_dirty(collection)
    if collection then return self._dirty[collection] == true end
    return next(self._dirty) ~= nil
end

function FileStore:close()
    local ok, why = self:flush()
    if not ok then return false, why end
    self._data, self._loaded = {}, {}
    return true
end

function FileStore:writes() return self._writes end

return FileStore
