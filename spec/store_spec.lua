--- One contract, run against every store, plus what the file store alone
--- promises about surviving a crash.
local modname = ...
local lu = require("luaunit")
local json = require("support.json")
local MemoryStore = require("persistence.memory_store")
local FileStore = require("persistence.file_store")
local DatabaseStore = require("persistence.database_store")
local FakeSql = require("spec.fake_sql")

local ROOT = "run/spec"

local function scrub(collection)
    for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
        os.remove(("%s/%s%s"):format(ROOT, collection, suffix))
    end
end

local function read(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

local function write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

-- ------------------------------------------------------- the shared contract

local function contract(name, make_store)
    local suite = {}

    function suite:setUp()
        scrub("things")
        self.store = make_store()
    end

    function suite:test_what_goes_in_comes_back_out()
        lu.assertNil(self.store:get("things", "a"))
        self.store:put("things", "a", { colour = "black", worth = 1250 })
        local record = self.store:get("things", "a")
        lu.assertEquals(record.colour, "black")
        lu.assertEquals(record.worth, 1250)
        lu.assertEquals(math.type(record.worth), "integer")
    end

    function suite:test_the_store_hands_out_copies_not_its_own_tables()
        local original = { tags = { "fast" } }
        self.store:put("things", "a", original)
        original.tags[1] = "slow"                    -- the caller keeps its table
        lu.assertEquals(self.store:get("things", "a").tags[1], "fast")
        local fetched = self.store:get("things", "a")
        fetched.tags[1] = "stolen"                   -- and the caller mutates what it got
        lu.assertEquals(self.store:get("things", "a").tags[1], "fast")
    end

    function suite:test_delete_says_whether_anything_was_there()
        self.store:put("things", "a", { n = 1 })
        lu.assertTrue(self.store:delete("things", "a"))
        lu.assertFalse(self.store:delete("things", "a"))
        lu.assertNil(self.store:get("things", "a"))
        lu.assertEquals(self.store:count("things"), 0)
    end

    function suite:test_keys_come_back_sorted_so_output_is_stable()
        for _, key in ipairs({ "c", "a", "b" }) do self.store:put("things", key, { k = key }) end
        lu.assertEquals(self.store:keys("things"), { "a", "b", "c" })
        local seen = {}
        for key, record in self.store:each("things") do
            seen[#seen + 1] = key
            lu.assertEquals(record.k, key)
        end
        lu.assertEquals(seen, { "a", "b", "c" })
        lu.assertEquals(self.store:count("things"), 3)
    end

    function suite:test_a_collection_name_cannot_escape_the_store()
        -- these become file names and table names, so they are checked once here
        for _, bad in ipairs({ "../../etc/passwd", "Things", "th ings", "th/ings", "", "1things" }) do
            lu.assertError(function() return self.store:get(bad, "a") end)
            lu.assertError(function() return self.store:put(bad, "a", {}) end)
        end
    end

    function suite:test_junk_keys_and_junk_records_are_refused()
        lu.assertError(function() return self.store:put("things", "", {}) end)
        lu.assertError(function() return self.store:put("things", 42, {}) end)
        lu.assertError(function() return self.store:put("things", "a", "not a table") end)
        lu.assertError(function() return self.store:put("things", "a", setmetatable({}, {})) end)
    end

    function suite:test_collections_are_listed()
        self.store:put("things", "a", { n = 1 })
        lu.assertEquals(self.store:collections(), { "things" })
    end

    local named = {}
    for key, value in pairs(suite) do named[key] = value end
    return named, name
end

TestMemoryStoreContract = contract("memory", function() return MemoryStore.new() end)
TestFileStoreContract = contract("file", function() return FileStore.new({ root = ROOT }) end)
TestDatabaseStoreContract = contract("database", function()
    local driver = FakeSql.new()
    local store = DatabaseStore.new({ driver = driver })
    assert(store:ensure_schema())
    return store
end)

-- ---------------------------------------------------- what the file store adds

TestFileStore = {}

function TestFileStore:setUp()
    scrub("city")
    self.store = FileStore.new({ root = ROOT })
end

function TestFileStore:tearDown()
    scrub("city")
end

function TestFileStore:test_nothing_reaches_disk_until_flush()
    self.store:put("city", "a", { n = 1 })
    lu.assertNil(read(ROOT .. "/city.json"))
    lu.assertTrue(self.store:is_dirty("city"))
    lu.assertTrue(self.store:flush())
    lu.assertFalse(self.store:is_dirty("city"))
    lu.assertIsString(read(ROOT .. "/city.json"))
end

function TestFileStore:test_a_restart_finds_everything_that_was_flushed()
    self.store:put("city", "a", { worth = 250000, name = "docks" })
    self.store:put("city", "b", { worth = 1, name = "kiosk" })
    lu.assertTrue(self.store:flush())

    local restarted = FileStore.new({ root = ROOT })
    lu.assertEquals(restarted:keys("city"), { "a", "b" })
    lu.assertEquals(restarted:get("city", "a").name, "docks")
    -- and money-shaped integers are still integers after the file round trip
    lu.assertEquals(math.type(restarted:get("city", "a").worth), "integer")
    lu.assertEquals(restarted:notices(), {})
end

function TestFileStore:test_a_second_flush_keeps_the_previous_version_as_a_backup()
    self.store:put("city", "a", { version = 1 })
    self.store:flush()
    self.store:put("city", "a", { version = 2 })
    self.store:flush()
    lu.assertEquals(json.decode(read(ROOT .. "/city.json")).a.version, 2)
    lu.assertEquals(json.decode(read(ROOT .. "/city.json.bak")).a.version, 1)
    lu.assertNil(read(ROOT .. "/city.json.tmp"))   -- no litter
end

function TestFileStore:test_a_corrupt_file_falls_back_instead_of_starting_empty()
    -- The failure this is all for: half a file on disk after a hard crash.
    self.store:put("city", "a", { version = 1, name = "docks" })
    self.store:flush()
    self.store:put("city", "a", { version = 2, name = "docks" })
    self.store:flush()
    write(ROOT .. "/city.json", '{"a":{"vers')

    local recovered = FileStore.new({ root = ROOT })
    lu.assertEquals(recovered:get("city", "a").version, 1)
    local notices = table.concat(recovered:notices(), " | ")
    lu.assertStrContains(notices, "did not parse")
    lu.assertStrContains(notices, "recovered from its backup")
    -- the recovered content is pending, so the next flush repairs the bad file
    lu.assertTrue(recovered:is_dirty("city"))
    lu.assertTrue(recovered:flush())
    lu.assertEquals(json.decode(read(ROOT .. "/city.json")).a.version, 1)
end

function TestFileStore:test_a_missing_file_with_a_backup_is_recovered()
    self.store:put("city", "a", { version = 1 })
    self.store:flush()
    self.store:put("city", "a", { version = 2 })
    self.store:flush()
    os.remove(ROOT .. "/city.json")

    local recovered = FileStore.new({ root = ROOT })
    lu.assertEquals(recovered:get("city", "a").version, 1)
    lu.assertStrContains(table.concat(recovered:notices(), " | "), "is missing")
end

function TestFileStore:test_a_first_boot_with_no_files_is_quiet()
    local fresh = FileStore.new({ root = ROOT })
    lu.assertEquals(fresh:keys("city"), {})
    lu.assertEquals(fresh:notices(), {})     -- nothing lost, so nothing to say
end

function TestFileStore:test_both_files_unreadable_is_reported_not_hidden()
    write(ROOT .. "/city.json", "{ broken")
    write(ROOT .. "/city.json.bak", "also broken")
    local store = FileStore.new({ root = ROOT })
    lu.assertErrorMsgContains("could not be recovered", function() store:keys("city") end)
    lu.assertError(function() store:put("city", "new", { value = 1 }) end)
    lu.assertFalse(store:flush())
    lu.assertEquals(read(ROOT .. "/city.json"), "{ broken")
    lu.assertEquals(read(ROOT .. "/city.json.bak"), "also broken")
    lu.assertStrContains(table.concat(store:notices(), " | "), "could not be recovered")
end

function TestFileStore:test_a_record_json_cannot_hold_fails_the_flush_and_keeps_the_old_file()
    self.store:put("city", "a", { version = 1 })
    self.store:flush()
    -- a bug upstream divides by zero and stores the result; NaN is a number,
    -- so it reaches the store intact and only JSON refuses it
    self.store:put("city", "a", { version = 2, share = 0 / 0 })
    local ok, failures = self.store:flush()
    lu.assertFalse(ok)
    lu.assertStrContains(failures[1], "could not be encoded")
    lu.assertEquals(json.decode(read(ROOT .. "/city.json")).a.version, 1)
    lu.assertTrue(self.store:is_dirty("city"))   -- still pending, not silently dropped
end

function TestFileStore:test_declared_collections_are_listed_before_they_are_touched()
    self.store:declare("city"):declare("crews")
    lu.assertEquals(self.store:collections(), { "city", "crews" })
end

function TestFileStore:test_failed_close_keeps_the_record_that_needs_repair()
    self.store:put("city", "a", { version = 1 })
    lu.assertTrue(self.store:flush())
    self.store:put("city", "a", { version = 2, share = 0 / 0 })
    lu.assertFalse(self.store:close())
    lu.assertEquals(self.store:get("city", "a").version, 2)
    self.store:put("city", "a", { version = 2, share = 1 })
    lu.assertTrue(self.store:close())
    lu.assertEquals(FileStore.new({ root = ROOT }):get("city", "a").version, 2)
end

TestResourceStoreRecovery = {}

function TestResourceStoreRecovery:setUp()
    self.old_load, self.old_save = LoadResourceFile, SaveResourceFile
    self.files, self.writes, self.fail_primary = {}, {}, false
    LoadResourceFile = function(_, path) return self.files[path] end
    SaveResourceFile = function(_, path, text)
        self.writes[#self.writes + 1] = path
        if self.fail_primary and path == "data/world.json" then return false end
        self.files[path] = text
        return true
    end
    self.store = require("adapter.resource_store").new({ resource = "fixture" })
end

function TestResourceStoreRecovery:tearDown()
    LoadResourceFile, SaveResourceFile = self.old_load, self.old_save
end

function TestResourceStoreRecovery:test_broken_and_empty_saves_block_every_write()
    for _, broken in ipairs({ "{ broken", "" }) do
        self.files["data/world.json"] = broken
        local store = require("adapter.resource_store").new({ resource = "fixture" })
        lu.assertErrorMsgContains("could not be recovered", function() store:keys("world") end)
        lu.assertError(function() store:put("world", "clock", {}) end)
        lu.assertError(function() store:put("chr", "new", {}) end)
        lu.assertFalse(store:flush())
        lu.assertEquals(self.files["data/world.json"], broken)
    end
    lu.assertEquals(self.writes, {})
end

function TestResourceStoreRecovery:test_failed_repair_keeps_the_good_backup()
    self.files["data/world.json"] = "{ broken"
    self.files["data/world.json.bak"] = '{"clock":{"at":100}}'
    local good = self.files["data/world.json.bak"]
    lu.assertEquals(self.store:get("world", "clock").at, 100)
    self.fail_primary = true
    lu.assertFalse(self.store:flush())
    lu.assertEquals(self.files["data/world.json.bak"], good)
    self.fail_primary = false
    lu.assertTrue(self.store:flush())
    lu.assertEquals(self.files["data/world.json.bak"], good)
    lu.assertEquals(json.decode(self.files["data/world.json"]).clock.at, 100)
end

--- A disk that fills while the city grows. Opening a file for writing empties
--- it, and what does not fit is lost -- a real short write. The fake in setUp
--- refuses before it touches anything, which is politer than a full disk, and a
--- fake politer than the real dependency is how the defect below hid. `says` is
--- what the native answers for a short write: false, or a lie.
local function fill_the_disk(self, capacity, says)
    SaveResourceFile = function(_, path, text)
        self.writes[#self.writes + 1] = path
        self.files[path] = ""
        local used = 0
        for _, held in pairs(self.files) do used = used + #held end
        self.files[path] = text:sub(1, math.max(0, capacity - used))
        if #self.files[path] < #text then return says end
        return true
    end
end

function TestResourceStoreRecovery:test_a_short_write_never_reaches_the_only_good_backup()
    -- Measured before the fix, in both modes: save three cut the primary short,
    -- save four copied that over the backup, and a restart said the world
    -- could not be recovered -- clock, ledger, ownership and receipts gone.
    for _, says in ipairs({ false, true }) do
        self.files, self.writes = {}, {}
        fill_the_disk(self, 9000, says)
        local store = require("adapter.resource_store").new({ resource = "fixture" })
        local receipts = {}
        for save = 1, 6 do
            for i = 1, 60 do receipts[("license:x/s-%d-%d"):format(save, i)] = "t3:..." end
            store:put("world", "ledger", { balances = { ["chr:alice"] = 250000 + save } })
            store:put("world", "commands", { completed = receipts })
            store:flush()
        end
        local reopened = require("adapter.resource_store").new({ resource = "fixture" })
        local read, ledger = pcall(reopened.get, reopened, "world", "ledger")
        lu.assertTrue(read, ("a short write the native answered %s for lost the city: %s")
            :format(tostring(says), tostring(ledger)))
        lu.assertNotNil(ledger)
    end
end

function TestResourceStoreRecovery:test_a_backup_cut_short_leaves_the_city_it_was_copying_alone()
    self.files["data/world.json"] = json.encode({ clock = { at = 1 } })
    lu.assertEquals(self.store:get("world", "clock").at, 1)
    -- Room for the city that is there and a sliver more: the copy to .bak is
    -- cut short and the native says it went fine.
    fill_the_disk(self, #self.files["data/world.json"] + 8, true)
    self.store:put("world", "clock", { at = 2, note = string.rep("x", 100) })
    lu.assertFalse(self.store:flush())
    local reopened = require("adapter.resource_store").new({ resource = "fixture" })
    local read, clock = pcall(reopened.get, reopened, "world", "clock")
    lu.assertTrue(read, "a backup cut short took the city it was copying with it: " .. tostring(clock))
    lu.assertEquals(clock.at, 1)
end

function TestResourceStoreRecovery:test_a_save_that_does_not_read_back_as_written_has_failed()
    fill_the_disk(self, 60, true)
    self.store:put("world", "clock", { at = 10, note = string.rep("x", 200) })
    local ok, why = self.store:flush()
    lu.assertFalse(ok, "a save the disk cut short reported success")
    lu.assertStrContains(table.concat(why, "; "), "did not read back")
    lu.assertTrue(self.store:is_dirty("world"), "a save that did not land must be tried again")
end

function TestResourceStoreRecovery:test_a_new_store_with_no_saves_can_be_written()
    lu.assertEquals(self.store:keys("world"), {})
    self.store:put("world", "clock", { at = 10 })
    lu.assertTrue(self.store:flush())
    lu.assertEquals(json.decode(self.files["data/world.json"]).clock.at, 10)
end

function TestResourceStoreRecovery:test_failed_close_keeps_the_latest_city_for_retry()
    self.store:put("world", "clock", { at = 10 })
    lu.assertTrue(self.store:flush())
    self.store:put("world", "clock", { at = 20 })
    self.fail_primary = true
    lu.assertFalse(self.store:close())
    lu.assertEquals(self.store:get("world", "clock").at, 20)
    self.fail_primary = false
    lu.assertTrue(self.store:close())
    lu.assertEquals(json.decode(self.files["data/world.json"]).clock.at, 20)
end

function TestFileStore:test_missing_primary_and_empty_backup_do_not_create_an_empty_city()
    write(ROOT .. "/city.json.bak", "")
    lu.assertError(function() self.store:keys("city") end)
    lu.assertFalse(self.store:flush())
    lu.assertNil(read(ROOT .. "/city.json"))
    lu.assertEquals(read(ROOT .. "/city.json.bak"), "")
end

function TestResourceStoreRecovery:test_missing_primary_and_empty_backup_do_not_create_an_empty_city()
    self.files["data/world.json.bak"] = ""
    lu.assertError(function() self.store:keys("world") end)
    lu.assertFalse(self.store:flush())
    lu.assertEquals(self.writes, {})
    lu.assertNil(self.files["data/world.json"])
    lu.assertEquals(self.files["data/world.json.bak"], "")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
