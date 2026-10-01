local modname = ...
local lu = require("luaunit")
local Drain = require("adapter.drain")
local World = require("core.world")
local Money = require("domain.money")
TestRestartDrain = {}
function TestRestartDrain:setUp()
    self.now, self.open, self.busy, self.work = 0, true, false, {}
    self.drain = Drain.new({ now = function() return self.now end, timeout = 100,
        busy = function() return self.busy end,
        close_input = function() self.open = false end,
        finish = function() lu.assertFalse(self.open); return true end,
        spawn = function(fn) self.work[#self.work + 1] = fn end })
end
function TestRestartDrain:test_closes_input_before_waiting_and_saves_once()
    self.busy = true
    lu.assertTrue(self.drain:begin()); lu.assertFalse(self.open)
    lu.assertEquals(self.drain:poll(), "WAITING"); lu.assertEquals(#self.work, 0)
    self.busy = false; lu.assertEquals(self.drain:poll(), "SAVING")
    self.drain:poll(); lu.assertEquals(#self.work, 1)
    lu.assertFalse(self.drain:report().safe_to_stop)
    self.work[1](); lu.assertEquals(self.drain:report(), { status = "DRAINED", safe_to_stop = true })
    lu.assertFalse(self.drain:begin())
end
function TestRestartDrain:test_hung_old_writer_never_starts_an_overlapping_write()
    self.busy = true; self.drain:begin(); self.now = 100
    lu.assertEquals(self.drain:poll(), "UNKNOWN"); lu.assertFalse(self.drain:report().safe_to_stop)
    self.busy = false; self.drain:poll(); lu.assertEquals(#self.work, 0)
end
function TestRestartDrain:test_late_save_completion_cannot_claim_shutdown_ready()
    self.drain:begin(); self.drain:poll(); self.now = 101
    self.work[1](); lu.assertEquals(self.drain.status, "UNKNOWN")
    lu.assertFalse(self.open); lu.assertFalse(self.drain:report().safe_to_stop)
end
function TestRestartDrain:test_failure_or_throw_leaves_the_city_closed()
    for _, finish in ipairs({ function() return false, { "disk full" } end, function() error("database gone") end }) do
        self:setUp(); self.drain.opts.finish = finish; self.drain:begin(); self.drain:poll(); self.work[1]()
        lu.assertEquals(self.drain.status, "FAILED"); lu.assertFalse(self.open)
        lu.assertFalse(self.drain:report().safe_to_stop)
    end
end
function TestRestartDrain:test_final_world_save_includes_changes_after_the_old_snapshot()
    local world = World.new()
    local store = world.store
    store.flush = function() coroutine.yield("backend"); return true end
    local old = coroutine.create(function() return world:save() end)
    lu.assertTrue(coroutine.resume(old)); lu.assertTrue(world:is_saving())
    local checkpoint = store:get("world", "ledger")
    world.ledger:transfer("accepted-before-drain", "external:mint", "chr:later", Money.of(10))
    self.drain.opts.busy = function() return world:is_saving() end
    self.drain.opts.finish = function() return world:close() end
    self.drain:begin(); lu.assertEquals(self.drain:poll(), "WAITING")
    lu.assertEquals(store:get("world", "ledger"), checkpoint)
    lu.assertTrue(coroutine.resume(old)); lu.assertFalse(world:is_saving())
    store.flush = function() return true end
    self.drain:poll(); self.work[1]()
    lu.assertEquals(self.drain.status, "DRAINED")
    lu.assertNotEquals(store:get("world", "ledger"), checkpoint)
end
if modname == nil then os.exit(lu.LuaUnit.run()) end
