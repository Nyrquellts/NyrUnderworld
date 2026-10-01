--- A database small enough to read, for testing the one that is not.
--
-- This understands exactly the six statements the resource sends and
-- refuses everything else. That refusal is the point: if the store ever starts
-- sending a statement nobody wrote down, a spec fails here rather than a server
-- failing in front of players.
--
-- It enforces the two constraints that bite in production and are invisible in
-- a Lua table otherwise:
--
--   * the key column is compared byte for byte, so "Bob" and "bob" are two
--     rows -- a case-insensitive collation would merge them
--   * a key longer than the column truncates on a permissive MySQL, which
--     turns two records into one; here it is an error
--
-- It can also be told to fail, because how a store behaves when the database
-- is away is most of what a store is for.

local FakeSql = {}
FakeSql.__index = FakeSql

local KEY_MAX = 190
local COLLECTION_MAX = 48

--- opts.transactions  true for a driver that can commit several statements as
---                    one, the way oxmysql's transaction does
function FakeSql.new(opts)
    opts = opts or {}
    local self = setmetatable({
        rows = {},         -- collection -> key -> payload text
        statements = {},   -- every statement, in order
        transactions = {}, -- every transaction, as the statements it carried
        _table = nil,      -- nil until CREATE TABLE has run
        _fail = nil,       -- message to fail with
        _fail_times = 0,   -- how many more statements fail; -1 for all of them
    }, FakeSql)

    -- Plain closures, because that is the whole driver contract.
    self.query = function(sql, params) return self:_run(sql, params, "query") end
    self.execute = function(sql, params) return self:_run(sql, params, "execute") end
    if opts.transactions then
        self.transaction = function(statements) return self:_transaction(statements) end
    end
    return self
end

local function copy_rows(rows)
    local out = {}
    for collection, bucket in pairs(rows) do
        out[collection] = {}
        for key, payload in pairs(bucket) do out[collection][key] = payload end
    end
    return out
end

--- Every statement, or none of them: a statement that fails puts every row
--- back the way it was before the first, which is what a rollback is.
function FakeSql:_transaction(statements)
    self.transactions[#self.transactions + 1] = statements
    local before = copy_rows(self.rows)
    for _, statement in ipairs(statements) do
        local ran, result, why = pcall(self._run, self, statement.sql, statement.params, "execute")
        if not ran or result == nil then
            self.rows = before
            return nil, ran and why or result
        end
    end
    return true
end

--- The next `times` statements fail with `message`.
function FakeSql:fail_next(times, message)
    self._fail_times = times
    self._fail = message or "connection refused"
    return self
end

--- Every statement fails until healed.
function FakeSql:fail_all(message)
    return self:fail_next(-1, message)
end

function FakeSql:heal()
    self._fail_times, self._fail = 0, nil
    return self
end

--- How many statements have run. A spec asserts on it to prove a flush of a
--- thousand records is not a thousand round trips.
function FakeSql:statement_count() return #self.statements end

function FakeSql:last_statement() return self.statements[#self.statements] end

--- Put a row in without going through the store, to stand for what a previous
--- run of the server left behind.
function FakeSql:seed(collection, key, payload_text)
    self._table = self._table or "nyr_store"
    self.rows[collection] = self.rows[collection] or {}
    self.rows[collection][key] = payload_text
    return self
end

function FakeSql:row_count(collection)
    local bucket = self.rows[collection]
    if not bucket then return 0 end
    local n = 0
    for _ in pairs(bucket) do n = n + 1 end
    return n
end

-- ------------------------------------------------------------------ parsing

local function normalise(sql)
    return (sql:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function check_collection(name)
    if type(name) ~= "string" or #name > COLLECTION_MAX then
        error(("collection column takes %d characters; got %s")
            :format(COLLECTION_MAX, tostring(name)), 0)
    end
end

local function check_key(key)
    if type(key) ~= "string" or #key > KEY_MAX then
        error(("store_key column takes %d characters; a longer key would truncate " ..
               "and collide with another record"):format(KEY_MAX), 0)
    end
end

function FakeSql:_run(sql, params, kind)
    params = params or {}
    self.statements[#self.statements + 1] = { sql = sql, params = params, kind = kind }

    if self._fail_times ~= 0 then
        if self._fail_times > 0 then self._fail_times = self._fail_times - 1 end
        return nil, self._fail
    end

    local text = normalise(sql)

    -- The connection check, which reaches no table on purpose.
    if text == "SELECT 1 AS ok" then
        return { { ok = 1 } }
    end

    local created = text:match("^CREATE TABLE IF NOT EXISTS `([%w_]+)`")
    if created then
        self._table = created
        return 0
    end

    local function table_ready(name)
        if self._table == nil then
            error(("table `%s` does not exist"):format(name), 0)
        end
    end

    local select_collection = text:match(
        "^SELECT `store_key`, `payload` FROM `([%w_]+)` WHERE `collection` = %?$")
    if select_collection then
        table_ready(select_collection)
        check_collection(params[1])
        local bucket = self.rows[params[1]] or {}
        local out, keys = {}, {}
        for key in pairs(bucket) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            out[#out + 1] = { store_key = key, payload = bucket[key] }
        end
        return out
    end

    local select_distinct = text:match("^SELECT DISTINCT `collection` FROM `([%w_]+)`$")
    if select_distinct then
        table_ready(select_distinct)
        local names = {}
        for name, bucket in pairs(self.rows) do
            if next(bucket) ~= nil then names[#names + 1] = name end
        end
        table.sort(names)
        local out = {}
        for _, name in ipairs(names) do out[#out + 1] = { collection = name } end
        return out
    end

    local inserted, values = text:match(
        "^INSERT INTO `([%w_]+)` %(`collection`, `store_key`, `payload`%) VALUES (.-) " ..
        "ON DUPLICATE KEY UPDATE `payload` = VALUES%(`payload`%)$")
    if inserted then
        table_ready(inserted)
        local rows = 0
        for _ in values:gmatch("%(%?, %?, %?%)") do rows = rows + 1 end
        if rows == 0 or rows * 3 ~= #params then
            error(("%d placeholder rows against %d parameters"):format(rows, #params), 0)
        end
        for index = 1, #params, 3 do
            local collection, key, payload = params[index], params[index + 1], params[index + 2]
            check_collection(collection)
            check_key(key)
            if type(payload) ~= "string" then
                error("payload must be text", 0)
            end
            self.rows[collection] = self.rows[collection] or {}
            self.rows[collection][key] = payload
        end
        return rows
    end

    local deleted, placeholders = text:match(
        "^DELETE FROM `([%w_]+)` WHERE `collection` = %? AND `store_key` IN %((.-)%)$")
    if deleted then
        table_ready(deleted)
        local slots = 0
        for _ in placeholders:gmatch("%?") do slots = slots + 1 end
        if slots + 1 ~= #params then
            error(("%d placeholders against %d parameters"):format(slots + 1, #params), 0)
        end
        local collection = params[1]
        check_collection(collection)
        local bucket = self.rows[collection]
        local affected = 0
        for index = 2, #params do
            local key = params[index]
            check_key(key)
            if bucket and bucket[key] ~= nil then
                bucket[key] = nil
                affected = affected + 1
            end
        end
        if bucket and next(bucket) == nil then self.rows[collection] = nil end
        return affected
    end

    error("the fake driver does not understand: " .. text, 0)
end

return FakeSql
