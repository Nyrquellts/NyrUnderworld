local modname = ...
local lu = require("luaunit")
local Readiness = require("adapter.readiness")
local ClientState = require("adapter.client_state")
local GOOD = { network = true, ped = true, collision = true, loading = false, switching = false }
TestWorldReadiness = {}
function TestWorldReadiness:setUp()
    self.now, self.sent, self.failed, self.resets = 0, {}, {}, {}
    self.gate = Readiness.new({ now = function() return self.now end, timeout = 100, limit = 2,
        on_reset = function(outcome) self.resets[#self.resets + 1] = outcome.code end })
end
function TestWorldReadiness:queue()
    return self.gate:submit(function(epoch) self.sent[#self.sent + 1] = epoch end,
        function(result) self.failed[#self.failed + 1] = result.code end)
end
function TestWorldReadiness:open()
    self.gate:set_session("epoch-a"); self.gate:observe(GOOD); self.gate:observe(GOOD)
end
function TestWorldReadiness:test_every_fact_and_server_epoch_are_required()
    self:queue(); self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.sent, {})
    self.gate:set_session("epoch-a")
    for key, value in pairs(GOOD) do
        local bad = Readiness.copy(GOOD); bad[key] = not value
        self.gate:observe(bad); self.gate:observe(GOOD)
        lu.assertEquals(self.sent, {}, key)
    end
    self.gate:observe(GOOD)
    lu.assertEquals(self.sent, { "epoch-a" })
end
function TestWorldReadiness:test_queue_is_bounded_and_timeout_never_sends_later()
    lu.assertTrue(self:queue()); lu.assertTrue(self:queue()); lu.assertFalse(self:queue())
    lu.assertEquals(self.failed, { "world_queue_full" })
    self.now = 100; self:open()
    lu.assertEquals(self.failed, { "world_queue_full", "world_timeout", "world_timeout" })
    lu.assertEquals(self.sent, {})
end
function TestWorldReadiness:test_clock_reversal_expires_instead_of_hanging()
    self:queue(); self.now = -1; self:open()
    lu.assertEquals(self.failed, { "world_timeout" }); lu.assertEquals(self.sent, {})
end
function TestWorldReadiness:test_restart_cancels_old_queue_and_requires_new_samples()
    self.gate:set_session("epoch-a"); self:queue(); self.gate:set_session("epoch-b")
    lu.assertEquals(self.failed, { "server_restarted" })
    self:queue(); self.gate:observe(GOOD); lu.assertEquals(self.sent, {})
    self.gate:observe(GOOD); lu.assertEquals(self.sent, { "epoch-b" })
end
function TestWorldReadiness:test_relocation_cannot_be_released_by_another_operation()
    self:open()
    local lease = self.gate:suspend()
    lu.assertNotNil(lease); lu.assertNil(self.gate:suspend())
    lu.assertFalse(self.gate:release({})); self:queue()
    self.gate:observe(GOOD); self.gate:observe(GOOD); lu.assertEquals(self.sent, {})
    lu.assertTrue(self.gate:release(lease)); lu.assertFalse(self.gate:release(lease))
    self.gate:observe(GOOD); lu.assertEquals(self.sent, {})
    self.gate:observe(GOOD); lu.assertEquals(self.sent, { "epoch-a" })
end
function TestWorldReadiness:test_restart_invalidates_an_awaiting_relocation()
    self:open(); local lease = self.gate:suspend(); lu.assertTrue(self.gate:current(lease))
    self.gate:set_session("epoch-b"); lu.assertFalse(self.gate:current(lease))
    self.gate:release(lease); self:queue(); self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.sent, { "epoch-b" })
end
function TestWorldReadiness:test_a_callback_that_starts_relocation_cancels_the_rest()
    self.gate:set_session("epoch-a")
    self.gate:submit(function() self.gate:suspend() end, function() end)
    self:queue(); self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.sent, {}); lu.assertEquals(self.failed, { "world_changed" })
end
function TestWorldReadiness:test_callback_errors_do_not_kill_the_sampler()
    self.gate:set_session("epoch-a")
    self.gate:submit(function() error("bad callback") end, function() error("bad failure callback") end)
    self:queue(); self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.sent, { "epoch-a" })
    lu.assertFalse(self.gate:submit(function() error("immediate") end, function() end))
end
function TestWorldReadiness:test_stop_rejects_and_does_not_revive_with_a_session()
    self:queue(); self.gate:stop(); self.gate:set_session("later"); self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertFalse(self:queue()); lu.assertEquals(self.sent, {})
    lu.assertEquals(self.failed, { "resource_stopped", "resource_stopped" })
end
function TestWorldReadiness:test_dispatched_request_is_unknown_after_transition_and_late_reply_is_dropped()
    local state = ClientState.new()
    local got = {}
    state:open("sent", function(answer) got[#got + 1] = answer end)
    state:cancel({ code = "world_relocating" })
    lu.assertEquals(#got, 1); lu.assertEquals(got[1].code, "outcome_unknown")
    lu.assertNil(state:reply("sent", { ok = true })); lu.assertEquals(state:pending_count(), 0)
end
function TestWorldReadiness:test_arguments_are_snapshotted_and_cycles_rejected()
    local args = { nested = { count = 1 } }
    local copy = Readiness.copy(args); args.nested.count = 100
    lu.assertEquals(copy.nested.count, 1)
    args.loop = args
    lu.assertError(Readiness.copy, args)
    lu.assertError(Readiness.copy, { function() end })
end
function TestWorldReadiness:test_timeout_callback_cannot_resurrect_cancelled_requests()
    self.gate:set_session("old")
    self:queue() -- younger retained request sits before the expired request
    self.gate.queue[1].at = 50
    self.gate:submit(function() error("expired request sent") end, function()
        self.gate:set_session("new")
        self.gate:submit(function(epoch) self.sent[#self.sent + 1] = epoch end, function() end)
    end)
    self.now = 100; self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.failed, { "server_restarted" })
    lu.assertEquals(self.sent, { "new" })
end
function TestWorldReadiness:test_reentrant_timeout_queue_preserves_capacity_and_new_requests()
    self.gate:set_session("epoch-a")
    self.gate:submit(function() end, function()
        self:queue(); self:queue()
    end)
    self.now = 50; self:queue(); self.now = 100
    self.gate:observe(GOOD)
    lu.assertEquals(#self.gate.queue, 2)
    lu.assertEquals(self.failed, { "world_queue_full" })
    self.gate:observe(GOOD); lu.assertEquals(self.sent, { "epoch-a", "epoch-a" })
end
function TestWorldReadiness:test_timeout_reset_cancels_later_detached_requests_exactly_once()
    self.gate:set_session("old")
    self.gate:submit(function() end, function() self.gate:set_session("new") end)
    self.now = 50; self:queue(); self.now = 100
    self.gate:observe(GOOD); self.gate:observe(GOOD)
    lu.assertEquals(self.failed, { "world_changed" }); lu.assertEquals(self.sent, {})
end
function TestWorldReadiness:test_dispatched_timeout_handles_signed_timer_rollover()
    local now = 2147483640
    local state = ClientState.new({ now = function() return now end })
    state:open("old", function() end); now = -2147483640
    lu.assertEquals(#state:expire(), 1); lu.assertEquals(state:pending_count(), 0)
end
if modname == nil then os.exit(lu.LuaUnit.run()) end
