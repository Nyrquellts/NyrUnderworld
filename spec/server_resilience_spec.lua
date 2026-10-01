local modname = ...
local lu = require("luaunit")
local MemoryStore = require("persistence.memory_store")
-- Load the actual server entrypoint with a real pure-Lua city and controlled
-- native time. No network, game process, file store or database is started.
local function server()
    local h = { clock = 0, threads = {}, exports = {}, commands = {}, handlers = {}, logs = {},
        path = "C:/owned/nyr_underworld", configuration = "fixture", players_read = 0 }
    local env = setmetatable({}, { __index = _G }); env._G = env
    env.GetCurrentResourceName = function() return "nyr_underworld" end
    env.GetResourceMetadata = function() return "fixture" end
    env.GetResourcePath = function() return h.path end
    env.LoadResourceFile = function() return h.configuration end
    env.GetConvar = function(_, default) return default end
    env.GetGameTimer = function() return h.clock end
    env.GetInvokingResource = function() return "owned_spec" end
    env.GetPlayers = function() h.players_read = h.players_read + 1; return {} end
    env.TriggerEvent = function() end
    env.exports = function(name, fn) h.exports[name] = fn end
    env.AddEventHandler = function(name, fn)
        h.handlers[name] = h.handlers[name] or {}; table.insert(h.handlers[name], fn)
    end
    env.RegisterCommand = function(name, fn) h.commands[name] = fn end
    env.print = function(line) h.logs[#h.logs + 1] = line end
    env.Wait = function(ms) coroutine.yield(ms) end
    env.CreateThread = function(fn) h.threads[#h.threads + 1] = { co = coroutine.create(fn), wake = h.clock } end
    env.require = function(name)
        if name == "adapter.resource_store" then return { new = function()
            local store = MemoryStore.new(); store.writable = function() return true end; return store
        end } end
        if name == "adapter.devbridge" then return { remember = function() end,
            install = function(_, _, opts) h.dev_ready = opts.ready end } end
        if name == "adapter.bridge" then return { attach = function(_, opts) h.ready = opts.ready end,
            account_of = function() return "license:owned" end } end
        return require(name)
    end
    assert(loadfile("adapter/server.lua", "t", env))()
    h.world = env.NyrUnderworld.world
    function h:run(ms)
        local until_at = self.clock + ms
        for step = 1, 100000 do
            assert(step < 100000, "fake scheduler step budget exhausted")
            local next_thread
            for _, thread in ipairs(self.threads) do
                if coroutine.status(thread.co) ~= "dead" and (not next_thread or thread.wake < next_thread.wake) then next_thread = thread end
            end
            if not next_thread or next_thread.wake > until_at then break end
            self.clock = next_thread.wake
            local ok, waited = coroutine.resume(next_thread.co); assert(ok, waited)
            next_thread.wake = self.clock + math.max(1, waited or 0)
        end
        self.clock = until_at
    end
    h.spawn = env.CreateThread
    h.wait = env.Wait
    function h:stop() for _, fn in ipairs(self.handlers.onResourceStop) do fn("nyr_underworld") end end
    h:run(0)
    return h
end
TestServerResilience = {}
function TestServerResilience:setUp() self.server = server() end
function TestServerResilience:tearDown() self.server.world:deactivate() end
function TestServerResilience:test_drain_blocks_network_dev_addon_console_health_and_ticks()
    local h = self.server; lu.assertTrue(h.ready()); lu.assertTrue(h.dev_ready())
    h:run(1000)
    local city_time, health_reads = h.world.clock:now(), h.players_read
    local calls = 0; h.world.services.police.commission = function() calls = calls + 1 end
    h.exports.drain()
    lu.assertFalse(h.ready()); lu.assertFalse(h.dev_ready())
    lu.assertEquals(h.exports.ask("me.status", {}).code, "not_open")
    h.commands.nyr(0, { "commission", "chr:test" }); lu.assertEquals(calls, 0)
    h:run(2000)
    lu.assertEquals(h.exports.drainStatus().status, "DRAINED")
    lu.assertEquals(h.world.clock:now(), city_time); lu.assertEquals(h.players_read, health_reads)
end
function TestServerResilience:test_restart_waits_for_old_save_and_does_not_save_twice_on_stop()
    local h, saves = self.server, 0
    h.world.store.flush = function() saves = saves + 1; h.wait(500); return true end
    h.spawn(function() h.world:save() end); h:run(0)
    lu.assertTrue(h.world:is_saving()); h.exports.drain(); h:run(100)
    lu.assertEquals(h.exports.drainStatus().status, "WAITING"); lu.assertEquals(saves, 1)
    h:run(1000); lu.assertEquals(h.exports.drainStatus().status, "DRAINED")
    lu.assertEquals(saves, 2); h:stop(); lu.assertEquals(saves, 2)
end
function TestServerResilience:test_resource_relocation_closes_all_doors_and_skips_shutdown_write()
    local h = self.server
    local writes = 0; h.world.store.flush = function() writes = writes + 1; return true end
    h.path = "C:/owned/moved"
    lu.assertFalse(h.ready()); lu.assertFalse(h.dev_ready())
    h:stop(); lu.assertEquals(writes, 0)
    lu.assertStrContains(table.concat(h.logs, "\n"), "UNKNOWN")
end
function TestServerResilience:test_config_change_closes_the_city_even_if_later_reverted()
    local h = self.server
    h.configuration = "changed"; lu.assertFalse(h.ready())
    h.configuration = "fixture"; lu.assertFalse(h.ready())
    lu.assertFalse(h.exports.drainStatus().safe_to_stop)
end
if modname == nil then os.exit(lu.LuaUnit.run()) end
