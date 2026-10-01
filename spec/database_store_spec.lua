--- What the database store adds over the contract it shares.
--
-- The contract in store_spec proves it behaves like a store. This proves the
-- three things that are only true here: it writes the rows that changed rather
-- than the collection, it goes to the database few times rather than many, and
-- it never lets a database that is away look like a city that is empty.
local modname = ...
local lu = require("luaunit")
local json = require("support.json")
local DatabaseStore = require("persistence.database_store")
local FakeSql = require("spec.fake_sql")

local function opened()
    local driver = FakeSql.new()
    local store = DatabaseStore.new({ driver = driver })
    assert(store:ensure_schema())
    return store, driver
end

local function normalise(sql)
    return (sql:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function statements_of(driver, kind)
    local out = {}
    for _, statement in ipairs(driver.statements) do
        if kind == nil or statement.sql:match("^%s*" .. kind) then
            out[#out + 1] = statement
        end
    end
    return out
end

-- ------------------------------------------------------------ writing late

TestDatabaseStoreWrites = {}

function TestDatabaseStoreWrites:setUp()
    self.store, self.driver = opened()
end

function TestDatabaseStoreWrites:test_nothing_reaches_the_database_until_flush()
    self.store:put("city", "a", { n = 1 })
    lu.assertEquals(self.driver:row_count("city"), 0)
    lu.assertTrue(self.store:is_dirty("city"))
    lu.assertEquals(self.store:pending(), 1)

    lu.assertTrue(self.store:flush())
    lu.assertEquals(self.driver:row_count("city"), 1)
    lu.assertFalse(self.store:is_dirty("city"))
    lu.assertEquals(self.store:pending(), 0)
end

function TestDatabaseStoreWrites:test_only_the_rows_that_changed_are_written()
    for _, key in ipairs({ "a", "b", "c" }) do self.store:put("city", key, { k = key }) end
    lu.assertTrue(self.store:flush())

    local before = self.driver:statement_count()
    self.store:put("city", "b", { k = "b", changed = true })
    lu.assertTrue(self.store:flush())

    -- One statement, carrying one row. A store that rewrote the collection
    -- would carry three, and on a real city, four thousand.
    lu.assertEquals(self.driver:statement_count(), before + 1)
    local last = self.driver:last_statement()
    lu.assertEquals(#last.params, 3)
    lu.assertEquals(last.params[2], "b")
end

function TestDatabaseStoreWrites:test_a_restart_finds_everything_that_was_flushed()
    self.store:put("city", "a", { name = "Vic", money = 1250 })
    self.store:put("city", "b", { name = "Lena", money = 40 })
    lu.assertTrue(self.store:flush())

    local restarted = DatabaseStore.new({ driver = self.driver })
    lu.assertEquals(restarted:keys("city"), { "a", "b" })
    local record = restarted:get("city", "a")
    lu.assertEquals(record.name, "Vic")
    lu.assertEquals(record.money, 1250)
    -- Money is counted in whole pennies everywhere, and a round trip through
    -- JSON is where that quietly becomes a float.
    lu.assertEquals(math.type(record.money), "integer")
end

function TestDatabaseStoreWrites:test_a_delete_removes_the_row()
    self.store:put("city", "a", { n = 1 })
    self.store:put("city", "b", { n = 2 })
    lu.assertTrue(self.store:flush())

    lu.assertTrue(self.store:delete("city", "a"))
    lu.assertTrue(self.store:flush())
    lu.assertEquals(self.driver:row_count("city"), 1)

    local restarted = DatabaseStore.new({ driver = self.driver })
    lu.assertEquals(restarted:keys("city"), { "b" })
end

function TestDatabaseStoreWrites:test_a_key_written_after_it_was_deleted_is_not_deleted()
    self.store:put("city", "a", { n = 1 })
    lu.assertTrue(self.store:flush())

    self.store:delete("city", "a")
    self.store:put("city", "a", { n = 2 })
    lu.assertTrue(self.store:flush())

    local restarted = DatabaseStore.new({ driver = self.driver })
    lu.assertEquals(restarted:get("city", "a").n, 2)
end

function TestDatabaseStoreWrites:test_a_key_deleted_after_it_was_written_is_not_written()
    self.store:put("city", "a", { n = 1 })
    self.store:delete("city", "a")
    lu.assertTrue(self.store:flush())
    lu.assertEquals(self.driver:row_count("city"), 0)
end

function TestDatabaseStoreWrites:test_two_keys_differing_only_in_case_are_two_records()
    -- The default collation would merge these. The column is declared binary
    -- for exactly this reason, and the fake enforces it.
    self.store:put("city", "Bob", { who = "upper" })
    self.store:put("city", "bob", { who = "lower" })
    lu.assertTrue(self.store:flush())

    local restarted = DatabaseStore.new({ driver = self.driver })
    lu.assertEquals(restarted:get("city", "Bob").who, "upper")
    lu.assertEquals(restarted:get("city", "bob").who, "lower")
end

-- ------------------------------------------------------------ few round trips

TestDatabaseStoreConcurrentWrites = {}

function TestDatabaseStoreConcurrentWrites:test_a_flush_writes_the_city_as_it_was_when_the_flush_began()
    -- This used to assert the opposite: that a row changed during an await was
    -- written before the flush said it was done. The world's own records -- the
    -- ledger, ownership, the receipts -- were handed to the store before the
    -- flush began, so a row from after that moment beside them is a checkpoint
    -- of a city that never existed. Measured: a car bought during the await
    -- was in MySQL after a restart, and the money paid for it was not.
    local store, driver = opened()
    store:put("city", "wallet", { money = 100 })
    local execute = driver.execute
    driver.execute = function(sql, params)
        local result = execute(sql, params)
        if sql:match("^INSERT") then
            driver.execute = execute
            store:put("city", "wallet", { money = 75 })
            store:put("city", "car", { plate = "LATER" })
        end
        return result
    end
    lu.assertTrue(store:flush())
    local reread = DatabaseStore.new({ driver = driver })
    lu.assertEquals(reread:get("city", "wallet").money, 100, "a value from after the flush began was written")
    lu.assertNil(reread:get("city", "car"), "a row made after the flush began was written")
    -- Not lost: still marked, and the next flush writes both.
    lu.assertTrue(store:is_dirty("city"))
    lu.assertTrue(store:flush())
    reread = DatabaseStore.new({ driver = driver })
    lu.assertEquals(reread:get("city", "wallet").money, 75)
    lu.assertEquals(reread:get("city", "car").plate, "LATER")
end

function TestDatabaseStoreConcurrentWrites:test_a_driver_that_can_commit_gets_the_whole_checkpoint_in_one_call()
    -- One call is one round trip: a resource that stops while it waits for the
    -- answer has still handed the database every row, and the database commits
    -- them together or not at all. Chunk by chunk, a stop landed the first
    -- statement and nothing after it.
    local driver = FakeSql.new({ transactions = true })
    local store = DatabaseStore.new({ driver = driver })
    assert(store:ensure_schema())
    for index = 1, DatabaseStore.CHUNK + 5 do store:put("chr", ("c%04d"):format(index), { n = index }) end
    store:put("world", "ledger", { balances = {} })
    store:put("world", "gone", { x = 1 })
    lu.assertTrue(store:flush())
    store:delete("world", "gone")
    store:put("world", "clock", { now = 1 })
    local before = #driver.statements
    driver.transactions = {}
    lu.assertTrue(store:flush())
    lu.assertEquals(#driver.transactions, 1, "the checkpoint went in more than one call")
    lu.assertEquals(#driver.statements - before, #driver.transactions[1],
        "a statement went outside the transaction")
    local reread = DatabaseStore.new({ driver = driver })
    lu.assertNil(reread:get("world", "gone"))
    lu.assertEquals(reread:get("world", "clock").now, 1)
    lu.assertEquals(reread:get("chr", "c0001").n, 1)
end

function TestDatabaseStoreConcurrentWrites:test_a_row_that_will_not_encode_keeps_the_whole_checkpoint_back()
    local store, driver = opened()
    store:put("chr", "a", { name = "Ada" })
    store:put("world", "notes", { [1] = "one", ["1"] = "also one" })
    local before = #driver.statements
    local ok, why = store:flush()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(why, "; "), "world/notes")
    lu.assertEquals(#driver.statements, before, "part of a checkpoint that could not be whole was sent")
    lu.assertTrue(store:is_dirty("chr"))
end

function TestDatabaseStoreConcurrentWrites:test_a_checkpoint_the_database_rolls_back_is_all_still_to_write()
    local driver = FakeSql.new({ transactions = true })
    local store = DatabaseStore.new({ driver = driver })
    assert(store:ensure_schema())
    store:put("world", "ledger", { total = 0 })
    store:put("chr", "a", { name = "Ada" })
    driver:fail_next(1, "deadlock")
    local ok, why = store:flush()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(why, "; "), "deadlock")
    lu.assertTrue(store:is_dirty("world"))
    lu.assertTrue(store:is_dirty("chr"))
    lu.assertEquals(driver:row_count("chr"), 0, "a rolled-back checkpoint left rows behind")
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("chr", "a").name, "Ada")
end

function TestDatabaseStoreConcurrentWrites:test_a_delete_during_an_await_is_not_lost()
    local store, driver = opened()
    store:put("city", "item", { count = 1 })
    local execute = driver.execute
    driver.execute = function(sql, params)
        local result = execute(sql, params)
        if sql:match("^INSERT") then
            driver.execute = execute
            store:delete("city", "item")
        end
        return result
    end
    lu.assertTrue(store:flush())
    lu.assertTrue(store:flush())
    lu.assertNil(DatabaseStore.new({ driver = driver }):get("city", "item"))
end

function TestDatabaseStoreConcurrentWrites:test_a_second_flush_cannot_overtake_an_awaiting_write()
    local store, driver = opened()
    store:put("city", "wallet", { money = 100 })
    local execute = driver.execute
    local nested_ok
    driver.execute = function(sql, params)
        if sql:match("^INSERT") then
            driver.execute = execute
            store:put("city", "wallet", { money = 75 })
            nested_ok = store:flush()
        end
        return execute(sql, params)
    end
    lu.assertTrue(store:flush())
    lu.assertFalse(nested_ok)
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 75)
end

function TestDatabaseStoreConcurrentWrites:test_a_failed_close_preserves_the_unsaved_value_for_retry()
    local store, driver = opened()
    store:put("city", "wallet", { money = 100 })
    lu.assertTrue(store:flush())
    store:put("city", "wallet", { money = 75 })
    driver:fail_next(1, "temporary outage")
    lu.assertFalse(store:close())
    lu.assertEquals(store:get("city", "wallet").money, 75)
    lu.assertTrue(store:close())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 75)
end

TestDatabaseStoreBatching = {}

function TestDatabaseStoreBatching:test_a_thousand_records_are_not_a_thousand_statements()
    local store, driver = opened()
    for index = 1, 1000 do
        store:put("city", ("char:%04d"):format(index), { n = index })
    end
    local before = driver:statement_count()
    lu.assertTrue(store:flush())

    -- 1000 rows at 200 to a statement is five, plus the one SELECT that loaded
    -- the collection before the first write.
    lu.assertEquals(driver:statement_count() - before, 5)
    lu.assertEquals(driver:row_count("city"), 1000)
end

function TestDatabaseStoreBatching:test_deletes_are_batched_the_same_way()
    local store, driver = opened()
    for index = 1, 450 do store:put("city", ("k%03d"):format(index), { n = index }) end
    lu.assertTrue(store:flush())
    for index = 1, 450 do store:delete("city", ("k%03d"):format(index)) end

    local before = driver:statement_count()
    lu.assertTrue(store:flush())
    lu.assertEquals(driver:statement_count() - before, 3)
    lu.assertEquals(driver:row_count("city"), 0)
end

-- ------------------------------------------------- a database that is away

TestDatabaseStoreFailure = {}

function TestDatabaseStoreFailure:test_a_collection_that_cannot_be_read_is_not_an_empty_one()
    local store, driver = opened()
    driver:fail_all("connection refused")

    -- The whole reason this store exists in this shape. An empty answer here
    -- would let the character system make a fresh character over the top of
    -- one that is already in the database, and then write it down.
    lu.assertErrorMsgContains("refusing to treat it as empty",
        function() return store:get("city", "a") end)
end

function TestDatabaseStoreFailure:test_the_refusal_sticks_rather_than_hammering_the_database()
    local store, driver = opened()
    driver:fail_all("connection refused")
    pcall(function() return store:get("city", "a") end)

    local after_first = driver:statement_count()
    for _ = 1, 5 do pcall(function() return store:get("city", "a") end) end
    lu.assertEquals(driver:statement_count(), after_first)
end

function TestDatabaseStoreFailure:test_every_way_in_refuses_not_just_reading()
    local store, driver = opened()
    driver:fail_all("connection refused")
    for _, attempt in ipairs({
        function() return store:get("city", "a") end,
        function() return store:put("city", "a", { n = 1 }) end,
        function() return store:delete("city", "a") end,
        function() return store:keys("city") end,
        function() return store:count("city") end,
    }) do
        lu.assertError(attempt)
    end
end

function TestDatabaseStoreFailure:test_reload_recovers_once_the_database_is_back()
    local store, driver = opened()
    driver:seed("city", "a", json.encode({ name = "Vic" }))
    driver:fail_all("connection refused")
    lu.assertError(function() return store:get("city", "a") end)

    driver:heal()
    lu.assertTrue(store:reload("city"))
    lu.assertEquals(store:get("city", "a").name, "Vic")
end

function TestDatabaseStoreFailure:test_a_failed_flush_keeps_the_rows_and_tries_again()
    local store, driver = opened()
    store:put("city", "a", { n = 1 })
    driver:fail_next(1, "the server has gone away")

    local ok, failures = store:flush()
    lu.assertFalse(ok)
    lu.assertEquals(#failures, 1)
    lu.assertStrContains(failures[1], "city could not be written")
    -- Nothing was lost: the row is still waiting.
    lu.assertTrue(store:is_dirty("city"))
    lu.assertEquals(store:pending(), 1)

    lu.assertTrue(store:flush())
    lu.assertEquals(driver:row_count("city"), 1)
end

function TestDatabaseStoreFailure:test_a_half_written_flush_only_retries_the_half_that_failed()
    local store, driver = opened()
    for index = 1, 400 do store:put("city", ("k%03d"):format(index), { n = index }) end

    -- Two chunks; the second one fails.
    driver:fail_next(0)
    local original = driver.execute
    local seen = 0
    driver.execute = function(sql, params)
        seen = seen + 1
        if seen == 2 then return nil, "lost connection mid-flush" end
        return original(sql, params)
    end

    local ok, failures = store:flush()
    lu.assertFalse(ok)
    lu.assertEquals(#failures, 1)
    lu.assertEquals(driver:row_count("city"), 200)
    lu.assertEquals(store:pending(), 200)

    driver.execute = original
    lu.assertTrue(store:flush())
    lu.assertEquals(driver:row_count("city"), 400)
    lu.assertEquals(store:pending(), 0)
end

function TestDatabaseStoreFailure:test_preload_names_the_collections_it_could_not_read()
    local store, driver = opened()
    store:declare("city"):declare("vehicles")
    driver:fail_all("connection refused")

    local ok, failures = store:preload()
    lu.assertFalse(ok)
    lu.assertEquals(#failures, 2)
    lu.assertStrContains(failures[1], "city")
    lu.assertStrContains(failures[2], "vehicles")
end

function TestDatabaseStoreFailure:test_preload_is_quiet_when_the_database_answers()
    local store = opened()
    store:declare("city"):declare("vehicles")
    lu.assertTrue(store:preload())
end

function TestDatabaseStoreFailure:test_a_missing_table_is_reported_rather_than_thrown()
    local driver = FakeSql.new()
    local store = DatabaseStore.new({ driver = driver })
    driver:fail_all("access denied for user")
    local ok, why = store:ensure_schema()
    lu.assertFalse(ok)
    lu.assertStrContains(why, "access denied")
end

-- ------------------------------------------------------------ a bad row

TestDatabaseStoreBadRows = {}

function TestDatabaseStoreBadRows:test_a_bad_row_blocks_the_collection_and_preserves_every_row()
    local driver = FakeSql.new()
    driver:seed("city", "a", json.encode({ name = "Vic" }))
    driver:seed("city", "b", "{ this is not json")
    local store = DatabaseStore.new({ driver = driver })

    lu.assertErrorMsgContains("refusing to treat it as empty", function() store:keys("city") end)
    lu.assertError(function() store:get("city", "a") end)
    lu.assertError(function() store:put("city", "b", { name = "Replacement" }) end)
    local said = table.concat(store:notices(), "\n")
    lu.assertStrContains(said, "city/b did not parse")

    -- And the row is still in the database, because a record nobody can read
    -- is still a record somebody may want back.
    lu.assertFalse(store:flush())
    lu.assertEquals(driver.rows.city.a, json.encode({ name = "Vic" }))
    lu.assertEquals(driver.rows.city.b, "{ this is not json")
end

function TestDatabaseStoreBadRows:test_an_operator_repair_and_reload_reopens_the_collection()
    local driver = FakeSql.new()
    driver:seed("city", "b", "{ this is not json")
    local store = DatabaseStore.new({ driver = driver })
    store:declare("city")
    lu.assertFalse(store:preload())
    driver:seed("city", "b", json.encode({ name = "Lena" }))
    lu.assertTrue(store:reload("city"))
    lu.assertEquals(store:get("city", "b").name, "Lena")
    lu.assertTrue(store:flush())

    local restarted = DatabaseStore.new({ driver = driver })
    lu.assertEquals(restarted:get("city", "b").name, "Lena")
end

function TestDatabaseStoreBadRows:test_reload_cannot_discard_unsaved_changes()
    local store, driver = opened()
    store:put("city", "a", { n = 1 })
    lu.assertFalse(store:reload("city"))
    lu.assertEquals(store:get("city", "a").n, 1)
    lu.assertTrue(store:flush())
    lu.assertTrue(store:reload("city"))
    lu.assertEquals(store:get("city", "a").n, 1)
end

function TestDatabaseStoreConcurrentWrites:test_a_driver_exception_releases_the_flush_lock_and_keeps_data()
    local store, driver = opened()
    store:put("city", "wallet", { money = 75 })
    local execute = driver.execute
    driver.execute = function() error("driver disconnected") end
    lu.assertFalse(store:flush())
    lu.assertTrue(store:is_dirty())
    driver.execute = execute
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 75)
end

function TestDatabaseStoreConcurrentWrites:test_a_change_arriving_during_close_keeps_the_cache_until_it_is_written()
    -- A flush writes the city as it was when it began, so a change that arrives
    -- while close waits is not in that write. Close says so and keeps the cache
    -- rather than releasing a value nobody has written; closing again writes it.
    local store, driver = opened()
    store:put("city", "wallet", { money = 100 })
    local execute = driver.execute
    driver.execute = function(sql, params)
        local result = execute(sql, params)
        if sql:match("^INSERT") then
            driver.execute = execute
            store:put("city", "wallet", { money = 75 })
        end
        return result
    end
    local closed, why = store:close()
    lu.assertFalse(closed)
    lu.assertStrContains(table.concat(why, "; "), "arrived during close")
    lu.assertEquals(store:get("city", "wallet").money, 75)
    lu.assertTrue(store:close())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 75)
end

function TestDatabaseStoreConcurrentWrites:test_continuous_changes_never_keep_a_flush_going()
    -- Each flush writes one moment and returns. A city that never stops
    -- changing is written a moment at a time, never chased.
    local store, driver = opened()
    store:put("city", "wallet", { money = 100 })
    local execute, updates = driver.execute, 0
    driver.execute = function(sql, params)
        local result = execute(sql, params)
        if sql:match("^INSERT") then
            updates = updates + 1
            store:put("city", "wallet", { money = 100 - updates })
        end
        return result
    end
    lu.assertTrue(store:flush())
    lu.assertEquals(updates, 1)
    lu.assertTrue(store:is_dirty())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 100)
    driver.execute = execute
    lu.assertTrue(store:flush())
    lu.assertEquals(DatabaseStore.new({ driver = driver }):get("city", "wallet").money, 99)
end

-- ------------------------------------------------- what it says to the database

TestDatabaseStoreStatements = {}

function TestDatabaseStoreStatements:test_the_statements_are_the_ones_the_file_documents()
    local store, driver = opened()
    store:put("city", "a", { n = 1 })
    store:flush()
    store:delete("city", "a")
    store:flush()
    store:collections()

    local said = {}
    for _, statement in ipairs(driver.statements) do
        said[#said + 1] = normalise(statement.sql):match("^%u[%u ]*%u")
    end
    lu.assertEquals(said, {
        "CREATE TABLE IF NOT EXISTS", "SELECT", "INSERT INTO", "DELETE FROM",
        "SELECT DISTINCT",
    })
end

function TestDatabaseStoreStatements:test_values_reach_the_database_as_parameters_never_as_text()
    local store, driver = opened()
    store:put("city", "a'; DROP TABLE nyr_store; --", { note = "'); DELETE FROM nyr_store; --" })
    lu.assertTrue(store:flush())

    local insert = statements_of(driver, "INSERT")[1]
    lu.assertNotStrContains(insert.sql, "DROP TABLE")
    lu.assertEquals(insert.params[2], "a'; DROP TABLE nyr_store; --")

    local restarted = DatabaseStore.new({ driver = driver })
    lu.assertStrContains(restarted:get("city", "a'; DROP TABLE nyr_store; --").note, "DELETE FROM")
end

function TestDatabaseStoreStatements:test_the_table_name_is_checked_because_it_cannot_be_a_parameter()
    for _, bad in ipairs({ "nyr store", "nyr`store", "nyr;store", "1store", "", 42,
                           "store` (SELECT" }) do
        lu.assertError(function()
            return DatabaseStore.new({ driver = FakeSql.new(), table = bad })
        end)
    end
    local named = DatabaseStore.new({ driver = FakeSql.new(), table = "city_store" })
    lu.assertEquals(named:table_name(), "city_store")
    lu.assertStrContains(named:schema(), "`city_store`")
end

function TestDatabaseStoreStatements:test_a_key_too_long_for_the_column_is_refused_at_the_put()
    -- Two keys that truncate to the same thing become one record on a
    -- permissive MySQL, and the record that loses is gone. The column length is
    -- a real constraint, so it is enforced where the mistake is made rather
    -- than three minutes later inside a save loop.
    local store = opened()
    lu.assertErrorMsgContains("190",
        function() return store:put("city", ("k"):rep(191), { n = 1 }) end)
    lu.assertTrue(store:put("city", ("k"):rep(190), { n = 1 }))
    lu.assertTrue(store:flush())
end

function TestDatabaseStoreStatements:test_collections_sees_what_this_process_never_opened()
    local driver = FakeSql.new()
    driver:seed("vehicles", "v1", json.encode({ plate = "NYR 001" }))
    local store = DatabaseStore.new({ driver = driver })
    store:put("city", "a", { n = 1 })
    lu.assertEquals(store:collections(), { "city", "vehicles" })
end

TestDatabaseStoreKeyPadding = {}

function TestDatabaseStoreKeyPadding:test_padded_keys_are_refused_before_query_or_mutation()
    local store, driver = opened()
    local before = driver:statement_count()
    for _, key in ipairs({ "citizen ", "citizen   ", " " }) do
        lu.assertErrorMsgContains("end with", function() store:get("city", key) end)
        lu.assertErrorMsgContains("end with", function() store:put("city", key, { owner = "other" }) end)
        lu.assertErrorMsgContains("end with", function() store:delete("city", key) end)
    end
    lu.assertEquals(driver:statement_count(), before)
    lu.assertEquals(store:pending(), 0)
    lu.assertEquals(store:writes(), 0)
end

function TestDatabaseStoreKeyPadding:test_refusal_keeps_the_original_pending_record()
    local store, driver = opened()
    store:put("city", "citizen", { owner = "first" })
    lu.assertError(function() store:put("city", "citizen ", { owner = "second" }) end)
    lu.assertError(function() store:delete("city", "citizen ") end)
    lu.assertEquals(store:pending(), 1)
    lu.assertTrue(store:flush())
    local restarted = DatabaseStore.new({ driver = driver })
    lu.assertEquals(restarted:get("city", "citizen"), { owner = "first" })
    lu.assertEquals(driver:row_count("city"), 1)
end

function TestDatabaseStoreKeyPadding:test_stored_padded_key_blocks_the_collection_until_repaired()
    local driver = FakeSql.new()
    local original = json.encode({ owner = "first" })
    local padded = json.encode({ owner = "second" })
    driver:seed("city", "citizen", original)
    driver:seed("city", "padded ", padded)
    local store = DatabaseStore.new({ driver = driver })
    store:declare("city")
    lu.assertFalse(store:preload())
    lu.assertErrorMsgContains("end with", function() store:get("city", "citizen") end)
    lu.assertError(function() store:put("city", "new", { owner = "new" }) end)
    lu.assertFalse(store:flush())
    lu.assertEquals(driver.rows.city, { citizen = original, ["padded "] = padded })
    -- An operator repair is explicit; the store never trims or rewrites it.
    driver.rows.city["padded "] = nil
    lu.assertTrue(store:reload("city"))
    lu.assertEquals(store:get("city", "citizen"), { owner = "first" })
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
