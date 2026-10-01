--- The same store contract, backed by a SQL table.
--
-- This is the adapter a server with more than a handful of players wants. The
-- file stores rewrite a whole collection to keep one field; this writes the
-- rows that changed and nothing else.
--
-- Shape
-- -----
-- One table, not one per collection. Collections are made by gameplay code,
-- and a store that issues CREATE TABLE at runtime is a store that can fail
-- halfway through a Tuesday. One table is also one thing for the owner to back
-- up, and one thing to look at when they want to know what the city knows.
--
--   collection  VARCHAR(48)   the collection name, already constrained
--   store_key   VARCHAR(190)  case-sensitive key; trailing ASCII space refused
--   payload     LONGTEXT      the record as JSON
--   updated_at  TIMESTAMP     so an owner can see what moved
--
-- 190 characters because an index on utf8mb4 is limited to 767 bytes on the
-- older MySQL an owner may still be running, and 190 * 4 fits. The key column
-- is `utf8mb4_bin`: the default collation is case-insensitive, which would
-- quietly merge two different records whose ids differ only in case.
-- That collation still ignores trailing ASCII spaces during key comparison.
-- Those keys are rejected rather than trimmed, so an upsert cannot merge them.
--
-- Reading and writing
-- -------------------
-- Load a collection once, keep it in memory, serve every read from there, and
-- push the changed rows at flush. Same write-behind shape as the file store,
-- for a second reason here: every MySQL resource a FiveM server has is
-- asynchronous, and the store contract is not. Confining the database to two
-- moments -- load and flush -- is what lets a synchronous contract sit on an
-- asynchronous driver without a coroutine in every getter.
--
-- Failure
-- -------
-- A read that fails does not return an empty collection. This is the single
-- most important line in the file. If a dead database looked like an empty
-- one, the character system would find no character, make a fresh one over the
-- top of somebody's, and the next flush would write it down. Instead the
-- collection is marked unreadable and every call touching it errors until
-- `reload` succeeds. A refused command is recoverable; a city overwritten with
-- a blank one is not.
--
-- The driver
-- ----------
-- Two plain functions, so a shim over oxmysql, mysql-async or a spec's fake is
-- a table with two closures and nothing else:
--
--   driver.query(sql, params)    -> rows (array of maps) | nil, err
--   driver.execute(sql, params)  -> affected (number)    | nil, err
--
-- Both are synchronous from this store's point of view. On the FiveM side that
-- means the shim uses the driver's `await` form, which is why flush runs on a
-- thread and not inside an event handler.

local json = require("support.json")
local MemoryStore = require("persistence.memory_store")

local DatabaseStore = {}
DatabaseStore.__index = DatabaseStore

local deep_copy = MemoryStore.deep_copy

-- How many records go into one statement. Three placeholders per row, so 200
-- rows is 600 of the 65,535 a prepared statement allows, and one round trip
-- instead of two hundred.
local CHUNK = 200

local DEFAULT_TABLE = "nyr_store"

local function require_collection(name)
    if not MemoryStore.is_collection(name) then
        error(("collection name must be lowercase letters, digits and underscores, got %s")
            :format(tostring(name)), 3)
    end
    return name
end

-- The key column holds 190 characters. A longer key truncates on a permissive
-- MySQL, and two records that truncate to the same thing become one, with the
-- second silently overwriting the first. So the limit is enforced here, at the
-- call that made the key, rather than discovered inside a save loop.
local KEY_MAX = 190

local function require_key(key)
    if type(key) ~= "string" or key == "" then
        error(("a store key must be a non-empty string, got %s"):format(tostring(key)), 3)
    end
    if #key > KEY_MAX then
        error(("a store key is at most %d characters here, because that is the column; " ..
               "got %d"):format(KEY_MAX, #key), 3)
    end
    if key:sub(-1) == " " then
        error("a store key must not end with an ASCII space; SQL can merge it with another record", 3)
    end
    return key
end

--- A table name cannot be a bound parameter, so it is the one thing that
--- reaches the statement as text. It is checked here rather than trusted.
local function require_table(name)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") or #name > 64 then
        error(("a table name must be letters, digits and underscores, got %s")
            :format(tostring(name)), 3)
    end
    return name
end

--- opts.driver     { query = f, execute = f }; required
--- opts.table      table name, default nyr_store
--- opts.on_notice  called with a message when something is worth saying
function DatabaseStore.new(opts)
    opts = opts or {}
    local driver = opts.driver
    assert(type(driver) == "table", "a database store needs a driver")
    assert(type(driver.query) == "function", "a driver needs query(sql, params)")
    assert(type(driver.execute) == "function", "a driver needs execute(sql, params)")
    return setmetatable({
        _driver = driver,
        _table = require_table(opts.table or DEFAULT_TABLE),
        _notice = opts.on_notice,
        _data = {},      -- collection -> key -> record
        _loaded = {},    -- collection -> true once read
        _failed = {},    -- collection -> why it could not be read
        _dirty = {},     -- collection -> key -> mutation sequence
        _removed = {},   -- collection -> key -> mutation sequence
        _flushing = false,
        _known = {},     -- declared before anything touched them
        _writes = 0,
        _notices = {},
    }, DatabaseStore)
end

function DatabaseStore:table_name() return self._table end

local function notice(self, message)
    self._notices[#self._notices + 1] = message
    if self._notice then self._notice(message) end
end

--- Everything the store had to say: a row it could not read, a collection it
--- could not reach. A server prints these at boot; a spec asserts on them.
function DatabaseStore:notices() return deep_copy(self._notices) end

-- ------------------------------------------------------------------ schema

--- The table this store needs, as the owner would write it. Handed back rather
--- than only run, because an owner who wants to look before anything touches
--- their database should be able to.
function DatabaseStore:schema()
    return ([[
CREATE TABLE IF NOT EXISTS `%s` (
  `collection` VARCHAR(48)  NOT NULL,
  `store_key`  VARCHAR(190) NOT NULL COLLATE utf8mb4_bin,
  `payload`    LONGTEXT     NOT NULL,
  `updated_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`collection`, `store_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(self._table)
end

--- Create the table if it is not there. Safe to run at every boot.
function DatabaseStore:ensure_schema()
    local ok, err = self._driver.execute(self:schema(), {})
    if ok == nil then
        return false, ("the store table could not be created: %s"):format(tostring(err))
    end
    return true
end

-- ------------------------------------------------------------------ loading

local function unreadable(self, collection)
    local why = self._failed[collection]
    if why then
        error(("the %s collection could not be read from the database (%s); " ..
               "refusing to treat it as empty"):format(collection, why), 3)
    end
end

local function load_collection(self, collection)
    unreadable(self, collection)
    if self._loaded[collection] then return end

    local sql = ("SELECT `store_key`, `payload` FROM `%s` WHERE `collection` = ?")
        :format(self._table)
    local rows, err = self._driver.query(sql, { collection })
    if rows == nil then
        self._failed[collection] = tostring(err)
        notice(self, ("%s could not be read: %s"):format(collection, tostring(err)))
        unreadable(self, collection)
    end

    if type(rows) ~= "table" then
        self._failed[collection] = "the query did not return a row list"
        unreadable(self, collection)
    end
    local bucket = {}
    for _, row in ipairs(rows) do
        local key = type(row) == "table" and (row.store_key or row.STORE_KEY)
        local payload = type(row) == "table" and (row.payload or row.PAYLOAD)
        local decoded = type(payload) == "string" and json.decode(payload) or nil
        local valid_key, key_error = pcall(require_key, key)
        if type(decoded) == "table" and valid_key and bucket[key] == nil then
            bucket[key] = decoded
        else
            -- Publishing only the readable rows makes an existing citizen or
            -- asset look absent. Keep the entire collection closed until the
            -- operator repairs the row and explicitly reloads it.
            self._failed[collection] = not valid_key and tostring(key_error)
                or ("row %s is unreadable or duplicated"):format(tostring(key))
            notice(self, ("%s/%s did not parse or has an unsafe/duplicate key; left in the database untouched")
                :format(collection, tostring(key)))
            unreadable(self, collection)
        end
    end

    self._data[collection] = bucket
    self._loaded[collection] = true
end

--- Try a failed collection again. Until this succeeds every call touching it
--- errors, which is the point.
function DatabaseStore:reload(collection)
    require_collection(collection)
    if self._flushing or self:is_dirty(collection) then
        return false, "cannot reload a collection with pending or in-flight writes"
    end
    self._failed[collection] = nil
    self._loaded[collection] = nil
    local ok, why = pcall(load_collection, self, collection)
    if not ok then return false, self._failed[collection] or tostring(why) end
    return true
end

--- Read every declared collection before anyone plays. A server that cannot
--- reach its database should find out at boot, not when the first player picks
--- a character.
function DatabaseStore:preload()
    local failures = {}
    for _, collection in ipairs(self._known) do
        local ok = pcall(load_collection, self, collection)
        if not ok then
            failures[#failures + 1] = ("%s: %s"):format(collection, self._failed[collection])
        end
    end
    table.sort(failures)
    if #failures > 0 then return false, failures end
    return true
end

--- Name a collection before anything has touched it, so preload has a list.
function DatabaseStore:declare(collection)
    require_collection(collection)
    for _, name in ipairs(self._known) do
        if name == collection then return self end
    end
    self._known[#self._known + 1] = collection
    return self
end

-- ------------------------------------------------------- the store contract

function DatabaseStore:get(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    local record = self._data[collection][key]
    if record == nil then return nil end
    return deep_copy(record)
end

local function mark(set, collection, key, sequence)
    local bucket = set[collection]
    if not bucket then
        bucket = {}
        set[collection] = bucket
    end
    bucket[key] = sequence
end

local function unmark(set, collection, key)
    local bucket = set[collection]
    if bucket then
        bucket[key] = nil
        if next(bucket) == nil then set[collection] = nil end
    end
end

function DatabaseStore:put(collection, key, record)
    require_collection(collection)
    require_key(key)
    if type(record) ~= "table" then error("a store holds tables; got " .. type(record), 2) end
    load_collection(self, collection)
    self._data[collection][key] = deep_copy(record)
    self._writes = self._writes + 1
    mark(self._dirty, collection, key, self._writes)
    -- A key written after it was deleted is not deleted. The two sets stay
    -- disjoint so flush can never be asked to both write and remove a row.
    unmark(self._removed, collection, key)
    return true
end

function DatabaseStore:delete(collection, key)
    require_collection(collection)
    require_key(key)
    load_collection(self, collection)
    if self._data[collection][key] == nil then return false end
    self._data[collection][key] = nil
    self._writes = self._writes + 1
    mark(self._removed, collection, key, self._writes)
    unmark(self._dirty, collection, key)
    return true
end

function DatabaseStore:keys(collection)
    require_collection(collection)
    load_collection(self, collection)
    local out = {}
    for key in pairs(self._data[collection]) do out[#out + 1] = key end
    table.sort(out)
    return out
end

function DatabaseStore:each(collection)
    local keys = self:keys(collection)
    local index = 0
    return function()
        index = index + 1
        local key = keys[index]
        if key == nil then return nil end
        return key, self:get(collection, key)
    end
end

function DatabaseStore:count(collection)
    return #self:keys(collection)
end

--- What is in memory, what was declared, and what the database has that this
--- process has not opened. The file store cannot answer the last one; a
--- database can, in one statement.
function DatabaseStore:collections()
    local seen = {}
    for name in pairs(self._data) do seen[name] = true end
    for _, name in ipairs(self._known) do seen[name] = true end

    local sql = ("SELECT DISTINCT `collection` FROM `%s`"):format(self._table)
    local rows = self._driver.query(sql, {})
    if rows then
        for _, row in ipairs(rows) do
            local name = row.collection or row.COLLECTION
            if MemoryStore.is_collection(name) then seen[name] = true end
        end
    end

    local out = {}
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- ----------------------------------------------------------------- flushing

local function sorted_keys(bucket)
    local out = {}
    for key in pairs(bucket or {}) do out[#out + 1] = key end
    table.sort(out)
    return out
end

local function insert_statement(self, collection, rows)
    local placeholders, params = {}, {}
    for _, row in ipairs(rows) do
        placeholders[#placeholders + 1] = "(?, ?, ?)"
        params[#params + 1] = collection
        params[#params + 1] = row.key
        params[#params + 1] = row.text
    end
    -- VALUES(payload) rather than the row-alias form. The alias is MySQL 8.0.20
    -- and later; MariaDB, which is what a FiveM server almost always runs, does
    -- not take it. VALUES() is deprecated there and works everywhere.
    local sql = ("INSERT INTO `%s` (`collection`, `store_key`, `payload`) VALUES %s " ..
                 "ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)")
        :format(self._table, table.concat(placeholders, ", "))
    return sql, params
end

local function delete_statement(self, collection, rows)
    local placeholders, params = {}, { collection }
    for _, row in ipairs(rows) do
        placeholders[#placeholders + 1] = "?"
        params[#params + 1] = row.key
    end
    local sql = ("DELETE FROM `%s` WHERE `collection` = ? AND `store_key` IN (%s)")
        :format(self._table, table.concat(placeholders, ", "))
    return sql, params
end

--- Every row marked at this moment, encoded at this moment.
---
--- Taken before the first statement is sent, because sending one yields. A
--- flush used to read each row as it reached it, and to go round again for rows
--- marked while it waited -- but the world hands its own records (the ledger,
--- ownership, the receipts) to the store before the flush begins, so a row from
--- after that moment written beside them is a checkpoint of a city that never
--- existed. Measured: a car bought during the await was in MySQL after a
--- restart, and the money paid for it was not. A row marked during the await
--- stays marked, and the next flush -- with the world's records from its own
--- moment -- writes it.
local function snapshot(self)
    local batches, failures = {}, {}

    -- Removals first. The two sets are disjoint, so the order is a choice
    -- rather than a correctness matter; doing them first means a flush that
    -- half-fails leaves fewer rows behind than it should rather than more.
    for _, collection in ipairs(sorted_keys(self._removed)) do
        local rows = {}
        for _, key in ipairs(sorted_keys(self._removed[collection])) do
            rows[#rows + 1] = { key = key, version = self._removed[collection][key] }
        end
        batches[#batches + 1] = { kind = "remove", collection = collection, rows = rows }
    end

    for _, collection in ipairs(sorted_keys(self._dirty)) do
        local rows = {}
        for _, key in ipairs(sorted_keys(self._dirty[collection])) do
            local text, why = json.encode(self._data[collection][key])
            if not text then
                failures[#failures + 1] = ("%s/%s could not be encoded: %s"):format(collection, key, tostring(why))
            else
                rows[#rows + 1] = { key = key, version = self._dirty[collection][key], text = text }
            end
        end
        batches[#batches + 1] = { kind = "write", collection = collection, rows = rows }
    end
    return batches, failures
end

--- The batches as statements, CHUNK rows at a time, each knowing which markers
--- it clears once it has landed.
local function statements_of(self, batches)
    local out = {}
    for _, batch in ipairs(batches) do
        local index = 1
        while index <= #batch.rows do
            local chunk = {}
            for step = index, math.min(index + CHUNK - 1, #batch.rows) do
                chunk[#chunk + 1] = batch.rows[step]
            end
            local sql, params
            if batch.kind == "remove" then
                sql, params = delete_statement(self, batch.collection, chunk)
            else
                sql, params = insert_statement(self, batch.collection, chunk)
            end
            out[#out + 1] = { sql = sql, params = params, kind = batch.kind,
                              collection = batch.collection, rows = chunk }
            index = index + #chunk
        end
    end
    return out
end

--- A statement landed: clear every marker it wrote, unless the row was marked
--- again while it waited, in which case the newer value is still to go.
local function landed(self, statement)
    local set = statement.kind == "remove" and self._removed or self._dirty
    for _, row in ipairs(statement.rows) do
        if set[statement.collection] and set[statement.collection][row.key] == row.version then
            unmark(set, statement.collection, row.key)
        end
    end
end

--- Write the snapshot. Returns false and the list of failures rather than
--- throwing, so a save loop reports and carries on. Anything that did not land
--- keeps its marker, so the next flush tries it again and nothing is lost by a
--- database that was briefly away.
local function flush_pending(self)
    local failures = {}
    for collection, why in pairs(self._failed) do
        failures[#failures + 1] = ("%s remains unreadable: %s"):format(collection, why)
    end
    if #failures > 0 then table.sort(failures); return false, failures end

    local batches, refused = snapshot(self)
    -- A row that will not encode is a checkpoint that cannot be whole, so none
    -- of it is sent.
    if #refused > 0 then table.sort(refused); return false, refused end

    local statements = statements_of(self, batches)
    if #statements == 0 then return true end

    -- One call when the driver can commit several statements as one. That is
    -- one round trip: the database has every row before this coroutine waits,
    -- so a resource that stops while it waits has still handed the whole
    -- checkpoint over, and the database commits it or rolls all of it back.
    -- Chunk by chunk, a stop landed the first statement and nothing after it,
    -- and a failure half way left a checkpoint that was half this save.
    if type(self._driver.transaction) == "function" then
        local list = {}
        for index, statement in ipairs(statements) do
            list[index] = { sql = statement.sql, params = statement.params }
        end
        local committed, why = self._driver.transaction(list)
        if not committed then
            return false, { ("the checkpoint was not committed, and nothing in it was written: %s")
                :format(tostring(why)) }
        end
        for _, statement in ipairs(statements) do landed(self, statement) end
        return true
    end

    -- A driver with no transaction sends a statement at a time. A collection
    -- stops at its first failure; the others still go.
    local stopped = {}
    for _, statement in ipairs(statements) do
        if not stopped[statement.collection] then
            local affected, why = self._driver.execute(statement.sql, statement.params)
            if affected == nil then
                stopped[statement.collection] = true
                if statement.kind == "remove" then
                    failures[#failures + 1] = ("%s could not have rows removed: %s")
                        :format(statement.collection, tostring(why))
                else
                    failures[#failures + 1] = ("%s could not be written: %s")
                        :format(statement.collection, tostring(why))
                end
            else
                landed(self, statement)
            end
        end
    end

    table.sort(failures)
    if #failures > 0 then return false, failures end
    return true
end

function DatabaseStore:flush()
    if self._flushing then return false, { "a database flush is already in progress" } end
    self._flushing = true
    -- Awaiting SQL yields to other server coroutines. A newer put/delete keeps
    -- its own marker, and another flush must not overtake this one.
    local ran, ok, failures = pcall(flush_pending, self)
    self._flushing = false
    if not ran then return false, { "database flush failed: " .. tostring(ok) } end
    return ok, failures
end

--- Whether this store commits a checkpoint in one call.
function DatabaseStore:commits_whole()
    return type(self._driver.transaction) == "function"
end

function DatabaseStore:is_dirty(collection)
    if collection then
        return self._dirty[collection] ~= nil or self._removed[collection] ~= nil
    end
    return next(self._dirty) ~= nil or next(self._removed) ~= nil
end

--- How many rows are waiting to go to the database. An owner watching this
--- climb knows their database is not keeping up before a player does.
function DatabaseStore:pending()
    local total = 0
    for _, set in ipairs({ self._dirty, self._removed }) do
        for _, bucket in pairs(set) do
            for _ in pairs(bucket) do total = total + 1 end
        end
    end
    return total
end

function DatabaseStore:close()
    local ok, why = self:flush()
    if not ok then return false, why end
    if self:is_dirty() then
        return false, { "new database writes arrived during close; retry after gameplay stops" }
    end
    self._data, self._loaded = {}, {}
    return true
end

function DatabaseStore:writes() return self._writes end

DatabaseStore.CHUNK = CHUNK
DatabaseStore.KEY_MAX = KEY_MAX
DatabaseStore.DEFAULT_TABLE = DEFAULT_TABLE

return DatabaseStore
