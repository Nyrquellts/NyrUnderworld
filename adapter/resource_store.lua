--- The store contract, over the two file calls a FiveM server actually has.
--
-- The file store in persistence/ uses io.open, which is the right thing under
-- a plain interpreter and the wrong thing to rely on inside FXServer. The two
-- calls that are always there are LoadResourceFile and SaveResourceFile, so
-- this is the same store written against those.
--
-- There is no rename, so the rotation is different and the ordering matters:
--
--   1. read what is currently in <name>.json
--   2. write that to <name>.json.bak
--   3. write the new content to <name>.json
--
-- A crash between 2 and 3 leaves the previous version in the backup, which is
-- what the loader falls back to. The previous version is never removed before
-- the new one is written, so there is no moment where neither exists.
--
-- This is the development and small-server story. A server with a few hundred
-- players wants the database adapter instead, which keeps the same contract.

local json = require("support.json")
local MemoryStore = require("persistence.memory_store")

local ResourceStore = {}
ResourceStore.__index = ResourceStore

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

--- opts.resource   defaults to the current resource
--- opts.folder     where the files live inside it; "data" by default
--- opts.on_notice  called with a message when a fallback or repair happens
function ResourceStore.new(opts)
    opts = opts or {}
    return setmetatable({
        _resource = opts.resource or GetCurrentResourceName(),
        _folder = opts.folder or "data",
        _indent = opts.indent ~= false,
        _notice = opts.on_notice,
        _guard = opts.guard,
        _data = {},
        _loaded = {},
        _dirty = {},
        _known = {},
        _writes = 0,
        _notices = {},
        _recovered = {},
        -- collection -> the exact text last read or written back intact, so a
        -- file that is still that text is known to be a city without parsing it
        _good = {},
        _warned = {},
    }, ResourceStore)
end

function ResourceStore:path(collection)
    return ("%s/%s.json"):format(self._folder, require_collection(collection))
end

local function notice(self, message)
    self._notices[#self._notices + 1] = message
    if self._notice then self._notice(message) end
end

function ResourceStore:notices() return deep_copy(self._notices) end

local function load_collection(self, collection)
    if self._guard then
        local ok, why = self._guard()
        if not ok then self._blocked = why end
    end
    if self._blocked then error(self._blocked, 2) end
    if self._loaded[collection] then return end
    self._loaded[collection] = true
    self._data[collection] = {}

    local path = self:path(collection)
    local text = LoadResourceFile(self._resource, path)
    local try_backup = false
    if text ~= nil then
        local decoded, why = json.decode(text)
        if type(decoded) == "table" then
            self._data[collection] = decoded
            self._good[collection] = text
            return
        end
        notice(self, ("%s did not parse (%s); falling back to the backup"):format(path, tostring(why)))
        try_backup = true
    else
        local backup = LoadResourceFile(self._resource, path .. ".bak")
        if backup ~= nil then
            notice(self, ("%s is missing; falling back to the backup"):format(path))
            try_backup = true
        end
    end

    if try_backup then
        local backup = LoadResourceFile(self._resource, path .. ".bak")
        local decoded = backup and json.decode(backup)
        if type(decoded) == "table" then
            self._data[collection] = decoded
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

function ResourceStore:get(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    local record = self._data[collection][key]
    if record == nil then return nil end
    return deep_copy(record)
end

function ResourceStore:put(collection, key, record)
    require_collection(collection)
    require_key(key)
    if type(record) ~= "table" then error("a store holds tables; got " .. type(record), 2) end
    load_collection(self, collection)
    self._data[collection][key] = deep_copy(record)
    self._dirty[collection] = true
    self._writes = self._writes + 1
    return true
end

function ResourceStore:delete(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    if self._data[collection][key] == nil then return false end
    self._data[collection][key] = nil
    self._dirty[collection] = true
    self._writes = self._writes + 1
    return true
end

function ResourceStore:keys(collection)
    require_collection(collection)
    load_collection(self, collection)
    local out = {}
    for key in pairs(self._data[collection]) do out[#out + 1] = key end
    table.sort(out)
    return out
end

function ResourceStore:each(collection)
    local keys = self:keys(collection)
    local index = 0
    return function()
        index = index + 1
        local key = keys[index]
        if key == nil then return nil end
        return key, self:get(collection, key)
    end
end

function ResourceStore:count(collection)
    return #self:keys(collection)
end

function ResourceStore:declare(collection)
    require_collection(collection)
    for _, name in ipairs(self._known) do
        if name == collection then return self end
    end
    self._known[#self._known + 1] = collection
    return self
end

function ResourceStore:collections()
    local seen = {}
    for name in pairs(self._data) do seen[name] = true end
    for _, name in ipairs(self._known) do seen[name] = true end
    local out = {}
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function write_collection(self, collection)
    if self._guard then
        local ok, why = self._guard()
        if not ok then return false, why end
    end
    local path = self:path(collection)
    local text, why = json.encode(self._data[collection], { indent = self._indent })
    if not text then
        return false, ("%s could not be encoded: %s"):format(collection, tostring(why))
    end

    -- Keep the current version before overwriting it, never after -- and only a
    -- version that is a city. A disk that fills while the city grows writes
    -- part of a file, and SaveResourceFile can answer true for it. Copying
    -- whatever was on disk into the backup put that half-file over the only good
    -- copy a save later, and a restart said the city could not be recovered.
    -- So the current file is backed up only when it is the text this store last
    -- saw intact, or when it parses; and the backup is read back before the
    -- primary is touched, so at every moment one of the two is a city.
    local current = LoadResourceFile(self._resource, path)
    if current and current ~= "" and not self._recovered[collection] then
        local sound = current == self._good[collection]
        if not sound then sound = type(json.decode(current)) == "table" end
        if sound then
            if self._guard then
                local ok, why = self._guard()
                if not ok then return false, why end
            end
            if not SaveResourceFile(self._resource, path .. ".bak", current, -1)
                or LoadResourceFile(self._resource, path .. ".bak") ~= current then
                return false, ("%s could not be backed up; the current file is left alone"):format(collection)
            end
        elseif not self._warned[collection] then
            self._warned[collection] = true
            notice(self, ("%s on disk is not a whole city, so its backup is kept as it is"):format(path))
        end
    end

    if self._guard then
        local ok, why = self._guard()
        if not ok then return false, why end
    end
    if not SaveResourceFile(self._resource, path, text, -1) then
        -- SaveResourceFile returns false and says nothing about why. The cause
        -- that is not obvious from the message is a missing folder: it does not
        -- create directories, so with no data/ every collection fails at once
        -- and the report reads like a disk problem. Say so, once, here.
        return false, ("%s could not be written to %s. If every collection failed, the folder is " ..
                       "missing: SaveResourceFile does not create one, and %s/ has to exist in the " ..
                       "resource before the server starts")
            :format(collection, path, self._folder)
    end
    -- Read back rather than trusted: the native's answer is not the file.
    if self._guard then
        local ok, why = self._guard()
        if not ok then return false, why end
    end
    if LoadResourceFile(self._resource, path) ~= text then
        return false, ("%s did not read back as it was written to %s -- a full disk writes part of a " ..
                       "file and can still report success. The backup is kept, and the save is tried again")
            :format(collection, path)
    end
    self._good[collection] = text
    self._warned[collection] = nil
    self._recovered[collection] = nil
    return true
end

function ResourceStore:flush()
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

function ResourceStore:is_dirty(collection)
    if collection then return self._dirty[collection] == true end
    return next(self._dirty) ~= nil
end

function ResourceStore:close()
    local ok, why = self:flush()
    if not ok then return false, why end
    self._data, self._loaded = {}, {}
    return true
end

function ResourceStore:writes() return self._writes end

-- ------------------------------------------------ whether it can write at all

--- The file a boot writes to find out, inside the store's folder. It starts
--- with an underscore, which no collection name can, so it is never read as a
--- collection or written over one. It is JSON so that git and a release leave
--- it behind the same way they leave the city's own files.
ResourceStore.CHECK_FILE = "_can_write.json"

local checks = 0

--- Whether this store can write the city down, found out before the city opens.
---
--- SaveResourceFile answers false and says nothing about why, and the first
--- save comes a minute after boot. So a store that could not write was a city
--- that opened, let people play in it, and then printed a failure for every
--- collection every minute while none of it was kept.
---
--- That was measured, not supposed. The same files under four folder names, on
--- both servers, each run past its first save:
---
---                         legacy 35245    enhanced 139
---     NyrUnderworld          saves        every save fails
---     Nyr_Underworld         saves        every save fails
---     nyrunderworld          saves        saves
---     nyr_underworld         saves        saves
---
--- A capital letter, on the Enhanced server, and nothing else about the name.
--- That is a fact about one server build, so it is not written here as a rule
--- about names: the write is tried, on whatever server this is. A legacy server
--- keeps the city under all four names and is not refused for any of them, and
--- a later Enhanced build that fixes it stops being refused without a change
--- here.
---
--- A write that answers yes is read back, and what it wrote is something no
--- earlier boot could have left there: a server that said yes and put the file
--- somewhere this store never reads from loses the city just the same.
---
--- Returns true, or false with a one-line reason and the lines that say what to
--- do about it.
function ResourceStore:writable()
    if self._guard then
        local ok, why = self._guard()
        if not ok then return false, why end
    end
    checks = checks + 1
    local path = ("%s/%s"):format(self._folder, ResourceStore.CHECK_FILE)
    local mark = json.encode({
        written = ("%d-%d-%d"):format(os.time(), checks, math.random(1, 2147483647)),
    })
    if SaveResourceFile(self._resource, path, mark, -1) then
        if LoadResourceFile(self._resource, path) == mark then return true end
    end
    return false, ResourceStore.unwritable(self._resource, self._folder)
end

--- What an owner is told when nothing can be written, decided from the names
--- alone so that a spec can hold every branch of it.
---
--- Returns the reason as one line, and what to do as lines.
function ResourceStore.unwritable(resource, folder)
    resource, folder = tostring(resource), tostring(folder)
    local why = ("nothing can be written to %s/%s, so nothing anybody did would be kept")
        :format(resource, folder)
    local function missing(name)
        return ("%s/%s has to exist before the server starts: SaveResourceFile does not"):format(name, folder),
            "create folders. If it is there, something is stopping the server writing to it."
    end
    if not resource:find("%u") then return why, { missing(resource) } end
    local first, second = missing("nyr_underworld")
    return why, {
        ("The folder is named %s, with a capital letter. On FiveM for GTAV Enhanced a"):format(resource),
        "resource named that way cannot write a file at all (measured on server build 139).",
        "",
        "Rename the folder to nyr_underworld, change server.cfg to `ensure nyr_underworld`,",
        "and restart the server. If it still does not start after that,",
        first,
        second,
    }
end

return ResourceStore
