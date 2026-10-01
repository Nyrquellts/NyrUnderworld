--- Work the city owes itself later: due once, in a stable order, and never
--- allowed to spam the log forever.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local Scheduler = require("core.scheduler")

TestScheduler = {}

function TestScheduler:setUp()
    self.clock = Clock.new({ rate = 1, start_at = 0 })
    self.errors, self.notices = {}, {}
    self.sched = Scheduler.new({
        clock = self.clock,
        on_error = function(message, label) self.errors[#self.errors + 1] = { message = message, label = label } end,
        on_notice = function(message, label) self.notices[#self.notices + 1] = { message = message, label = label } end,
    })
    self.log = {}
end

function TestScheduler:note(label)
    return function() self.log[#self.log + 1] = label end
end

function TestScheduler:test_nothing_runs_before_it_is_due()
    self.sched:after(1000, self:note("rent"), "rent")
    lu.assertEquals(self.sched:run(), 0)
    lu.assertEquals(self.log, {})
    lu.assertEquals(self.sched:next_due(), 1000)
    self.clock:skip(999)
    lu.assertEquals(self.sched:run(), 0)
    self.clock:skip(1)
    lu.assertEquals(self.sched:run(), 1)
    lu.assertEquals(self.log, { "rent" })
end

function TestScheduler:test_a_one_off_task_runs_once_and_is_gone()
    self.sched:at(500, self:note("restock"), "restock")
    self.clock:skip(600)
    self.sched:run()
    self.sched:run()
    lu.assertEquals(self.log, { "restock" })
    lu.assertEquals(self.sched:count(), 0)
    lu.assertNil(self.sched:next_due())
end

function TestScheduler:test_a_repeating_task_keeps_its_place()
    self.sched:every(100, self:note("tick"), "tick")
    self.clock:skip(100)
    self.sched:run()
    self.clock:skip(100)
    self.sched:run()
    lu.assertEquals(#self.log, 2)
    lu.assertEquals(self.sched:count(), 1)
    lu.assertEquals(self.sched:pending()[1].runs, 2)
end

function TestScheduler:test_a_repeating_task_can_be_told_when_to_start()
    self.sched:every(1000, self:note("payroll"), "payroll", { first = 50 })
    self.clock:skip(50)
    lu.assertEquals(self.sched:run(), 1)
    lu.assertEquals(self.sched:next_due(), 1050)
end

function TestScheduler:test_rebase_preserves_the_next_daily_boundary_without_replaying_history()
    self.sched:every(Clock.MS_PER_DAY, self:note("rent"), "rent", { first = 9 * Clock.MS_PER_HOUR })
    local saved = Clock.new({ rate = 1, start_at = 57 * Clock.MS_PER_DAY + 8 * Clock.MS_PER_HOUR })
    self.sched:set_clock(saved):rebase()
    lu.assertEquals(self.sched:run(), 0)
    self.sched:tick(Clock.MS_PER_HOUR)
    lu.assertEquals(self.log, { "rent" })
    lu.assertEquals(self.sched:next_due(), 58 * Clock.MS_PER_DAY + 9 * Clock.MS_PER_HOUR)
end

function TestScheduler:test_rebase_does_not_repeat_a_job_already_due_at_the_exact_save_time()
    self.sched:every(100, self:note("daily"), "daily")
    self.sched:at(50, self:note("recovery"), "recovery")
    self.clock:skip(1000)
    self.sched:rebase()
    self.sched:run()
    lu.assertEquals(self.log, { "recovery" })
    lu.assertEquals(self.sched:next_due(), 1100)
    self.sched:tick(100)
    lu.assertEquals(self.log, { "recovery", "daily" })
end

function TestScheduler:test_a_run_is_reproducible()
    -- Same due time, so order falls back to the order they were added. A run
    -- that shuffles is a bug that reproduces on one machine and not the next.
    self.sched:at(100, self:note("first"), "first")
    self.sched:at(100, self:note("second"), "second")
    self.sched:at(50, self:note("earlier"), "earlier")
    self.clock:skip(200)
    self.sched:run()
    lu.assertEquals(self.log, { "earlier", "first", "second" })
end

function TestScheduler:test_one_broken_task_does_not_stop_the_others()
    self.sched:at(100, function() error("rent table is missing") end, "rent")
    self.sched:at(100, self:note("payroll"), "payroll")
    self.clock:skip(100)
    local ran, failures = self.sched:run()
    lu.assertEquals(ran, 1)
    lu.assertEquals(#failures, 1)
    lu.assertStrContains(failures[1], "rent")
    lu.assertStrContains(failures[1], "rent table is missing")
    lu.assertEquals(self.log, { "payroll" })
    lu.assertEquals(self.errors[1].label, "rent")
end

function TestScheduler:test_a_task_that_keeps_failing_is_stopped_not_left_shouting()
    local attempts = 0
    self.sched:every(10, function()
        attempts = attempts + 1
        error("still broken")
    end, "broken")
    for _ = 1, Scheduler.FAILURE_LIMIT do
        self.clock:skip(10)
        self.sched:run()
    end
    lu.assertEquals(attempts, Scheduler.FAILURE_LIMIT)
    lu.assertEquals(self.sched:count(), 0)
    lu.assertStrContains(self.errors[#self.errors].message, "has been stopped")
    -- and it stays stopped
    self.clock:skip(1000)
    lu.assertEquals(self.sched:run(), 0)
    lu.assertEquals(attempts, Scheduler.FAILURE_LIMIT)
end

function TestScheduler:test_a_task_that_recovers_forgets_its_failures()
    local attempts = 0
    self.sched:every(10, function()
        attempts = attempts + 1
        if attempts <= 2 then error("flaky") end
    end, "flaky")
    for _ = 1, 6 do
        self.clock:skip(10)
        self.sched:run()
    end
    lu.assertEquals(attempts, 6)                 -- never hit the limit in a row
    lu.assertEquals(self.sched:count(), 1)
    lu.assertEquals(self.sched:pending()[1].failures, 0)
end

function TestScheduler:test_a_long_freeze_does_not_run_the_whole_backlog()
    -- The server was away for a very long time. A minute task must not get
    -- hundreds of runs the moment it comes back.
    self.sched:every(100, self:note("tick"), "tick")
    self.clock:skip(100000)
    local ran, failures, notices = self.sched:run()
    lu.assertEquals(ran, Scheduler.CATCH_UP_LIMIT)
    lu.assertEquals(#self.log, Scheduler.CATCH_UP_LIMIT)
    -- Skipping a backlog is healthy, not a failure. Reporting it as one trains
    -- people to ignore the failure list, which is where real breakage lives.
    lu.assertEquals(failures, {})
    lu.assertStrContains(table.concat(notices, " | "), "skipped")
    lu.assertEquals(#self.errors, 0)
    lu.assertEquals(#self.notices, 1)
    lu.assertTrue(self.sched:next_due() > self.clock:now())
    lu.assertTrue(self.sched:stats().skipped > 900)
    -- and it is back on its normal footing
    self.clock:skip(100)
    lu.assertEquals(self.sched:run(), 1)
end

function TestScheduler:test_a_task_can_be_cancelled()
    local task = self.sched:after(100, self:note("cancelled"), "cancelled")
    lu.assertTrue(self.sched:cancel(task))
    lu.assertFalse(self.sched:cancel(task))
    self.clock:skip(200)
    lu.assertEquals(self.sched:run(), 0)
    lu.assertEquals(self.log, {})
end

function TestScheduler:test_a_task_can_cancel_itself_from_inside()
    local task
    task = self.sched:every(10, function()
        self.log[#self.log + 1] = "once"
        self.sched:cancel(task)
    end, "self_cancelling")
    self.clock:skip(100)
    self.sched:run()
    lu.assertEquals(self.log, { "once" })
    lu.assertEquals(self.sched:count(), 0)
end

function TestScheduler:test_a_task_is_told_when_it_was_due()
    local seen
    self.sched:at(100, function(due, now) seen = { due = due, now = now } end, "stamped")
    self.clock:skip(150)
    self.sched:run()
    lu.assertEquals(seen.due, 100)
    lu.assertEquals(seen.now, 150)
end

function TestScheduler:test_tick_advances_the_city_and_runs_what_falls_due()
    local fast = Clock.new({ rate = 60, start_at = 0 })
    local sched = Scheduler.new({ clock = fast })
    local runs = 0
    sched:every(Clock.MS_PER_HOUR, function() runs = runs + 1 end, "hourly")
    sched:tick(60000)      -- at rate 60, one real minute is one city hour
    lu.assertEquals(runs, 1)
    sched:tick(60000)
    lu.assertEquals(runs, 2)
    lu.assertEquals(fast:describe(), "day 0 monday 02:00")
end

function TestScheduler:test_pending_reads_as_a_list_in_due_order()
    self.sched:at(300, self:note("c"), "c")
    self.sched:at(100, self:note("a"), "a")
    self.sched:every(200, self:note("b"), "b")
    local pending = self.sched:pending()
    lu.assertEquals(#pending, 3)
    lu.assertEquals(pending[1].label, "a")
    lu.assertEquals(pending[2].label, "b")
    lu.assertTrue(pending[2].repeating)
    lu.assertEquals(pending[3].label, "c")
end

function TestScheduler:test_nonsense_schedules_are_refused()
    lu.assertError(function() return self.sched:every(0, function() end) end)
    lu.assertError(function() return self.sched:every(-5, function() end) end)
    lu.assertError(function() return self.sched:after(-1, function() end) end)
    lu.assertError(function() return self.sched:at(1.5, function() end) end)
    lu.assertError(function() return self.sched:at(100, "not a function") end)
    lu.assertError(function() return Scheduler.new({}) end)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
