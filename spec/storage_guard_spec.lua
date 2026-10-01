local modname = ...
local lu = require("luaunit")
local Guard = require("adapter.storage_guard")
local ResourceStore = require("adapter.resource_store")
TestStorageIdentity = {}
function TestStorageIdentity:test_path_or_config_or_driver_change_latches_closed_even_if_reverted()
    for _, key in ipairs({ "path", "configuration", "store", "driver", "table" }) do
        local current = { path = "C:/owned/a", configuration = "return {}", store = "db", driver = "auto", table = "city" }
        local guard = Guard.new(function() return current end)
        lu.assertTrue(guard:check())
        local before = current[key]; current[key] = "changed"
        lu.assertFalse(guard:check(), key); current[key] = before
        lu.assertFalse(guard:check(), "reverting a changed identity must not reopen it")
    end
end
function TestStorageIdentity:test_unknown_identity_and_driver_restart_fail_closed()
    lu.assertFalse(Guard.new(function() error("native unavailable") end):check())
    lu.assertFalse(Guard.new(function() return { path = "a" } end):check())
    local guard = Guard.new(function() return { path = "a", configuration = "b" } end)
    guard:invalidate(); lu.assertFalse(guard:check())
end
function TestStorageIdentity:test_database_change_during_yield_is_unknown_and_never_retried()
    local path, calls = "a", 0
    local guard = Guard.new(function() return { path = path, configuration = "b" } end)
    local driver = guard:driver({ transaction = function() calls = calls + 1; coroutine.yield(); return true end })
    local answer, why
    local thread = coroutine.create(function() answer, why = driver.transaction({}) end)
    lu.assertTrue(coroutine.resume(thread)); path = "moved"
    lu.assertTrue(coroutine.resume(thread))
    lu.assertNil(answer); lu.assertStrContains(why, "UNKNOWN")
    lu.assertNil(driver.transaction({})); lu.assertEquals(calls, 1)
end
function TestStorageIdentity:test_file_write_does_not_follow_a_moved_resource()
    local saved_load, saved_save = _G.LoadResourceFile, _G.SaveResourceFile
    local path, writes, disk = "a", 0, {}
    local guard = Guard.new(function() return { path = path, configuration = "b" } end)
    _G.LoadResourceFile = function(_, name) return disk[name] end
    _G.SaveResourceFile = function(_, name, text) writes = writes + 1; disk[name] = text; return 1 end
    local store = ResourceStore.new({ resource = "owned", guard = function() return guard:check() end })
    store:put("city", "x", { n = 1 }); lu.assertTrue(store:flush())
    store:put("city", "x", { n = 2 }); local before = writes; path = "moved"
    local ok = store:flush(); lu.assertFalse(ok); lu.assertEquals(writes, before)
    lu.assertTrue(store:is_dirty("city"))
    _G.LoadResourceFile, _G.SaveResourceFile = saved_load, saved_save
end
if modname == nil then os.exit(lu.LuaUnit.run()) end
