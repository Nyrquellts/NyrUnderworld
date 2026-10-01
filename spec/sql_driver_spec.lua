--- Choosing a database resource, and turning its answers into the two
--- functions the store expects.
--
-- Every branch here runs against a fake `exports` table. What is deliberately
-- not covered is the one call per driver that reaches a real database; that is
-- named in the file itself and proved on the owner's server by `nyr store
-- check`. Everything around it -- which resource is chosen, what is said when
-- none is there, how an error becomes a returned reason rather than a throw --
-- is covered, because that is where this would otherwise go wrong quietly.
local modname = ...
local lu = require("luaunit")
local SqlDriver = require("adapter.sql_driver")
local DatabaseStore = require("persistence.database_store")
local FakeSql = require("spec.fake_sql")

--- A stand-in for a FiveM server: which resources are up, and what they export.
local function server(resources)
    return {
        state = function(name)
            local entry = resources[name]
            if entry == nil then return "missing" end
            return entry.state or "started"
        end,
        export = function(name)
            local entry = resources[name]
            return entry and entry.export or nil
        end,
    }
end

--- An oxmysql that answers out of the fake database, so the whole stack from
--- the store down to the statement runs in one test.
local function fake_oxmysql(sql)
    return {
        query_async = function(_, statement, params)
            local rows, err = sql.query(statement, params)
            if rows == nil then error(err, 0) end
            return rows
        end,
        execute_async = function(_, statement, params)
            local affected, err = sql.execute(statement, params)
            if affected == nil then error(err, 0) end
            return affected
        end,
        -- oxmysql 2.14.1: `{ query, values }` rows, committed together or
        -- rolled back together, answering true or false -- a failed statement
        -- is a false, not a throw (src/database/rawTransaction.ts).
        transaction_async = function(_, queries)
            sql.transaction_calls = (sql.transaction_calls or 0) + 1
            local statements = {}
            for index, row in ipairs(queries) do
                assert(type(row.query) == "string", "a transaction row carries its query as `query`")
                statements[index] = { sql = row.query, params = row.values }
            end
            return sql:_transaction(statements) == true
        end,
    }
end

-- ------------------------------------------------------------ which one

TestSqlDriverChoice = {}

function TestSqlDriverChoice:test_the_current_one_is_preferred_when_both_are_running()
    local _, name = SqlDriver.find(nil, server({
        ["oxmysql"] = { export = {} },
        ["mysql-async"] = { export = {} },
    }))
    lu.assertEquals(name, "oxmysql")
end

function TestSqlDriverChoice:test_an_older_server_still_finds_its_driver()
    local driver, name = SqlDriver.find(nil, server({ ["mysql-async"] = { export = {} } }))
    lu.assertNotNil(driver)
    lu.assertEquals(name, "mysql-async")
end

function TestSqlDriverChoice:test_asking_for_no_one_in_particular_takes_whichever_is_up()
    -- Every one of these means "whatever is running". `auto` is what the convar
    -- defaults to, and it used to be read as the name of a driver and refused,
    -- so a server with oxmysql running was told oxmysql was not a thing.
    for _, said in ipairs({ "auto", "" }) do
        local driver, name = SqlDriver.find(said, server({ ["oxmysql"] = { export = {} } }))
        lu.assertNotNil(driver, said)
        lu.assertEquals(name, "oxmysql", said)
    end
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {} } }))
    lu.assertNotNil(driver)
end

function TestSqlDriverChoice:test_an_owner_can_name_the_one_to_use()
    local _, name = SqlDriver.find("mysql-async", server({
        ["oxmysql"] = { export = {} },
        ["mysql-async"] = { export = {} },
    }))
    lu.assertEquals(name, "mysql-async")
end

function TestSqlDriverChoice:test_naming_one_that_is_not_running_does_not_fall_through_to_another()
    -- An owner who said mysql-async and silently got oxmysql would be reading
    -- the wrong logs for an hour.
    local driver, why = SqlDriver.find("mysql-async", server({ ["oxmysql"] = { export = {} } }))
    lu.assertNil(driver)
    lu.assertStrContains(why, "mysql-async")
    lu.assertNotStrContains(why, "oxmysql (")
end

function TestSqlDriverChoice:test_a_name_this_does_not_know_says_what_it_does_know()
    local driver, why = SqlDriver.find("postgres", server({}))
    lu.assertNil(driver)
    lu.assertStrContains(why, "oxmysql")
    lu.assertStrContains(why, "mysql-async")
end

function TestSqlDriverChoice:test_nothing_running_names_everything_it_looked_for()
    local driver, why = SqlDriver.find(nil, server({}))
    lu.assertNil(driver)
    lu.assertStrContains(why, "no database resource is running")
    lu.assertStrContains(why, "oxmysql (missing)")
    lu.assertStrContains(why, "mysql-async (missing)")
end

function TestSqlDriverChoice:test_a_resource_that_is_stopped_is_reported_with_its_state()
    local driver, why = SqlDriver.find(nil, server({ ["oxmysql"] = { state = "stopped" } }))
    lu.assertNil(driver)
    lu.assertStrContains(why, "oxmysql (stopped)")
end

function TestSqlDriverChoice:test_started_with_no_exports_is_said_plainly_and_the_next_is_tried()
    local driver, name = SqlDriver.find(nil, server({
        ["oxmysql"] = { export = nil },
        ["mysql-async"] = { export = {} },
    }))
    lu.assertNotNil(driver)
    lu.assertEquals(name, "mysql-async")

    local none, why = SqlDriver.find(nil, server({ ["oxmysql"] = { export = nil } }))
    lu.assertNil(none)
    lu.assertStrContains(why, "its exports are not there")
end

-- ------------------------------------------------------- what it hands back

TestSqlDriverAnswers = {}

function TestSqlDriverAnswers:test_rows_come_back_as_rows()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        query_async = function() return { { ok = 1 } } end,
    } } }))
    lu.assertEquals(driver.query("SELECT 1", {}), { { ok = 1 } })
end

function TestSqlDriverAnswers:test_a_driver_that_throws_becomes_a_reason_not_a_crash()
    -- The save loop calls this. A throw here would take the city tick with it.
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        query_async = function() error("connection refused", 0) end,
        execute_async = function() error("table is full", 0) end,
    } } }))
    local rows, why = driver.query("SELECT 1", {})
    lu.assertNil(rows)
    lu.assertStrContains(why, "connection refused")

    local affected, reason = driver.execute("INSERT", {})
    lu.assertNil(affected)
    lu.assertStrContains(reason, "table is full")
end

function TestSqlDriverAnswers:test_an_answer_that_is_not_rows_is_a_failure_not_an_empty_city()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        query_async = function() return nil end,
    } } }))
    local rows, why = driver.query("SELECT 1", {})
    lu.assertNil(rows)
    lu.assertStrContains(why, "not rows")
end

function TestSqlDriverAnswers:test_a_statement_that_counts_nothing_still_succeeded()
    -- CREATE TABLE answers with nothing on some versions. Reading that as a
    -- failure would make every boot report a broken table it had just made.
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        execute_async = function() return nil end,
    } } }))
    lu.assertEquals(driver.execute("CREATE TABLE x", {}), 0)
end

--- What oxmysql 2.14.1 really hands back, measured on a running server rather
--- than read off its TypeScript: MariaDB 12.3.3 behind oxmysql, the statements
--- this store actually issues.
---
---   execute_async INSERT       table {affectedRows=1, insertId=1, ...}
---   execute_async DELETE none  table {affectedRows=0, ...}
---   execute_async bad sql      throws; it never answers nil
---   query_async   SELECT none  {}
---
--- The point of writing it down here is the first row. `execute` is documented
--- to the store as returning a number and the store fails a write on nil, but
--- the untyped oxmysql path returns mysql2's raw result header. `tonumber` of a
--- table is nil, so `tonumber(affected) or 0` is what keeps the documented
--- contract true -- and a later tidy that returns `affected` straight through
--- would hand the store a table and break the contract with nothing failing.
local RESULT_HEADER = {
    fieldCount = 0, affectedRows = 1, insertId = 1,
    info = "", serverStatus = 2, warningStatus = 0, changedRows = 0,
}

function TestSqlDriverAnswers:test_the_shape_oxmysql_actually_answers_a_write_with()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        execute_async = function() return RESULT_HEADER end,
    } } }))
    local affected = driver.execute("INSERT INTO nyr_store VALUES (?)", { "x" })
    -- A number, whatever oxmysql felt like returning. The store documents a
    -- number and branches on nil; a table here would satisfy the nil check by
    -- accident and be wrong the moment anybody compared it to anything.
    lu.assertEquals(type(affected), "number")
    lu.assertNotNil(affected)
end

function TestSqlDriverAnswers:test_a_write_that_changed_nothing_is_not_a_failed_write()
    -- DELETE matching no rows comes back with affectedRows 0 and is a success.
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        execute_async = function()
            return { fieldCount = 0, affectedRows = 0, insertId = 0,
                     info = "", serverStatus = 2, warningStatus = 0, changedRows = 0 }
        end,
    } } }))
    local affected, why = driver.execute("DELETE FROM nyr_store WHERE store_key = ?", { "gone" })
    lu.assertNotNil(affected)
    lu.assertNil(why)
end

TestSqlDriverCheck = {}

function TestSqlDriverCheck:test_the_connection_is_proved_rather_than_assumed()
    local sql = FakeSql.new()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = fake_oxmysql(sql) } }))
    lu.assertTrue(SqlDriver.check(driver))
    lu.assertEquals(sql:last_statement().sql, "SELECT 1 AS ok")
end

function TestSqlDriverCheck:test_a_database_that_answers_nothing_is_not_a_working_one()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        query_async = function() return {} end,
    } } }))
    local ok, why = SqlDriver.check(driver)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "permissions")
end

function TestSqlDriverCheck:test_a_database_that_refuses_says_why()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = {
        query_async = function() error("access denied for user 'nyr'", 0) end,
    } } }))
    local ok, why = SqlDriver.check(driver)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "access denied")
end

-- --------------------------------------------------- the whole way through

TestSqlDriverWithTheStore = {}

function TestSqlDriverWithTheStore:test_a_character_goes_all_the_way_down_and_comes_back()
    local sql = FakeSql.new()
    local driver, name = SqlDriver.find(nil, server({
        ["oxmysql"] = { export = fake_oxmysql(sql) },
    }))
    lu.assertEquals(name, "oxmysql")

    local store = DatabaseStore.new({ driver = driver })
    lu.assertTrue(store:ensure_schema())
    lu.assertTrue(SqlDriver.check(driver))

    store:put("city", "char:1", { name = "Vic Ortega", money = 1250 })
    lu.assertTrue(store:flush())

    local restarted = DatabaseStore.new({ driver = driver })
    local record = restarted:get("city", "char:1")
    lu.assertEquals(record.name, "Vic Ortega")
    lu.assertEquals(math.type(record.money), "integer")
end

function TestSqlDriverWithTheStore:test_a_checkpoint_reaches_oxmysql_as_one_transaction()
    local sql = FakeSql.new()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = fake_oxmysql(sql) } }))
    local store = DatabaseStore.new({ driver = driver })
    lu.assertTrue(store:ensure_schema())
    lu.assertTrue(store:commits_whole())
    for index = 1, DatabaseStore.CHUNK + 1 do store:put("chr", ("c%04d"):format(index), { n = index }) end
    store:put("world", "ledger", { total = 0 })
    lu.assertTrue(store:flush())
    lu.assertEquals(sql.transaction_calls, 1)
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("chr", "c0201").n, 201)
end

function TestSqlDriverWithTheStore:test_a_transaction_oxmysql_rolls_back_is_a_save_that_did_not_happen()
    local sql = FakeSql.new()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = fake_oxmysql(sql) } }))
    local store = DatabaseStore.new({ driver = driver })
    lu.assertTrue(store:ensure_schema())
    store:put("chr", "a", { name = "Ada" })
    store:put("world", "ledger", { total = 0 })
    sql:fail_next(1, "Lock wait timeout exceeded")
    local ok, why = store:flush()
    lu.assertFalse(ok, "a rolled-back checkpoint was reported as saved")
    lu.assertStrContains(table.concat(why, "; "), "rolled the checkpoint back")
    lu.assertEquals(sql:row_count("chr"), 0)
    lu.assertTrue(store:is_dirty("chr"))
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("chr", "a").name, "Ada")
end

function TestSqlDriverWithTheStore:test_mysql_async_still_writes_a_statement_at_a_time()
    -- Its transaction takes named parameters shared by every statement, which
    -- the store's positional statements are not; so it is not wired, and the
    -- store says it does not commit whole.
    local sql = FakeSql.new()
    local driver = SqlDriver.find(nil, server({ ["mysql-async"] = { export = {
        mysql_sync_fetch_all = function(_, statement, params) return sql.query(statement, params) end,
        mysql_sync_execute = function(_, statement, params) return sql.execute(statement, params) end,
    } } }))
    local store = DatabaseStore.new({ driver = driver })
    lu.assertTrue(store:ensure_schema())
    lu.assertFalse(store:commits_whole())
    store:put("chr", "a", { name = "Ada" })
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("chr", "a").name, "Ada")
end

function TestSqlDriverWithTheStore:test_a_database_that_goes_away_mid_session_refuses_rather_than_forgets()
    local sql = FakeSql.new()
    local driver = SqlDriver.find(nil, server({ ["oxmysql"] = { export = fake_oxmysql(sql) } }))
    local store = DatabaseStore.new({ driver = driver })
    lu.assertTrue(store:ensure_schema())
    store:put("city", "char:1", { name = "Vic" })
    lu.assertTrue(store:flush())

    sql:fail_all("the server has gone away")
    local fresh = DatabaseStore.new({ driver = driver })
    lu.assertErrorMsgContains("refusing to treat it as empty",
        function() return fresh:get("city", "char:1") end)

    sql:heal()
    lu.assertTrue(fresh:reload("city"))
    lu.assertEquals(fresh:get("city", "char:1").name, "Vic")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
