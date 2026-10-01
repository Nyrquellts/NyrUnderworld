--- Work the city owes itself later.
--
-- Rent falls due, payroll runs, a shop restocks, heat cools, a stolen car is
-- reported, a contract expires. All of it is "at this city time, do this", and
-- doing it with a pile of hand-rolled timers is how a server ends up with rent
-- charged twice and payroll never.
--
-- The scheduler holds tasks in city time, runs everything due in a stable
-- order, and keeps three promises that matter on a live server:
--
--   A task that throws does not stop the others, and is reported.
--
--   A repeating task that keeps throwing is disabled rather than allowed to
--   fill the log forever. A broken rent tick should be loud once, not sixty
--   times a minute until somebody notices.
--
--   Catching up is bounded. If the server was frozen for ten city hours, a
--   task that repeats every city minute does not get six hundred runs; it runs
--   a capped number of times and says how many it skipped.

local Scheduler = {}
Scheduler.__index = Scheduler

local FAILURE_LIMIT = 5
local CATCH_UP_LIMIT = 8

Scheduler.FAILURE_LIMIT = FAILURE_LIMIT
Scheduler.CATCH_UP_LIMIT = CATCH_UP_LIMIT

--- opts.clock      a Clock, or anything with now()
--- opts.on_error   called with (message, label) when a task throws
--- opts.on_notice  called with (message, label) for something healthy worth
---                 saying, such as skipping a backlog after a long freeze.
---                 Kept apart from on_error on purpose: an expected event
---                 reported as an error teaches people to ignore errors.
function Scheduler.new(opts)
    opts = opts or {}
    assert(opts.clock and opts.clock.now, "a scheduler needs a clock")
    return setmetatable({
        _clock = opts.clock,
        _tasks = {},
        _sequence = 0,
        _on_error = opts.on_error,
        _on_notice = opts.on_notice,
        _ran = 0,
        _failed = 0,
        _skipped = 0,
        _catch_up = opts.catch_up_limit or CATCH_UP_LIMIT,
        _failure_limit = opts.failure_limit or FAILURE_LIMIT,
    }, Scheduler)
end

local function add(self, task)
    assert(type(task.work) == "function", "a scheduled task is a function")
    self._sequence = self._sequence + 1
    task.sequence = self._sequence
    task.label = task.label or ("task " .. self._sequence)
    task.failures = 0
    task.runs = 0
    task.live = true
    self._tasks[#self._tasks + 1] = task
    return task
end

--- Run once, at a city time.
function Scheduler:at(when, work, label)
    assert(math.type(when) == "integer", "a scheduled time is an integer city millisecond")
    return add(self, { due = when, work = work, label = label, repeating = false })
end

--- Run once, after this much city time.
function Scheduler:after(delay, work, label)
    assert(math.type(delay) == "integer" and delay >= 0, "a delay is whole city milliseconds")
    return self:at(self._clock:now() + delay, work, label)
end

--- Run again and again. opts.first sets when the first run happens; by default
--- it is one interval from now, not immediately.
function Scheduler:every(interval, work, label, opts)
    assert(math.type(interval) == "integer" and interval > 0, "an interval is whole city milliseconds above zero")
    opts = opts or {}
    local first = opts.first or (self._clock:now() + interval)
    return add(self, { due = first, work = work, label = label, repeating = true, interval = interval })
end

function Scheduler:cancel(task)
    if type(task) ~= "table" then return false end
    for index, candidate in ipairs(self._tasks) do
        if candidate == task then
            table.remove(self._tasks, index)
            task.live = false
            return true
        end
    end
    return false
end

function Scheduler:pending()
    local out = {}
    for _, task in ipairs(self._tasks) do
        out[#out + 1] = { label = task.label, due = task.due, repeating = task.repeating,
                          interval = task.interval, runs = task.runs, failures = task.failures }
    end
    table.sort(out, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        return a.label < b.label
    end)
    return out
end

function Scheduler:count() return #self._tasks end

--- Swap the clock, for a world that has just loaded a saved city time.
function Scheduler:set_clock(clock)
    assert(clock and clock.now, "a scheduler needs a clock")
    self._clock = clock
    return self
end

--- Installation schedules repeating work against a new clock. After loading
--- saved city time, move those tasks to the next boundary strictly after the
--- save. Loading must not replay days already lived, including a task whose
--- last run landed exactly on the saved time. One-off recovery work is kept.
function Scheduler:rebase()
    local now = self._clock:now()
    for _, task in ipairs(self._tasks) do
        if task.live and task.repeating and task.due <= now then
            local elapsed = (now - task.due) // task.interval + 1
            task.due = task.due + elapsed * task.interval
        end
    end
    return self
end

--- The city time of the next thing due, or nil if nothing is waiting.
function Scheduler:next_due()
    local soonest
    for _, task in ipairs(self._tasks) do
        if not soonest or task.due < soonest then soonest = task.due end
    end
    return soonest
end

local function report(self, message, label)
    self._failed = self._failed + 1
    if self._on_error then self._on_error(message, label) end
end

--- Run everything due now. Returns how many ran, the list of failures, and
--- the list of notices: things that happened and are fine.
---
--- Order is by due time then by the order tasks were added, so a run is
--- reproducible: a bug that shows up on one machine shows up on the next.
function Scheduler:run()
    local now = self._clock:now()
    local due = {}
    for _, task in ipairs(self._tasks) do
        if task.live and task.due <= now then due[#due + 1] = task end
    end
    table.sort(due, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        return a.sequence < b.sequence
    end)

    local ran, failures, notices = 0, {}, {}
    for _, task in ipairs(due) do
        if task.live then
            local runs_this_pass = 0
            repeat
                local scheduled_for = task.due
                local ok, err = pcall(task.work, scheduled_for, self._clock:now())
                task.runs = task.runs + 1
                runs_this_pass = runs_this_pass + 1
                if ok then
                    ran = ran + 1
                    self._ran = self._ran + 1
                    task.failures = 0
                else
                    task.failures = task.failures + 1
                    local message = ("%s failed: %s"):format(task.label, tostring(err))
                    failures[#failures + 1] = message
                    report(self, message, task.label)
                    if task.failures >= self._failure_limit then
                        local disabled = ("%s failed %d times in a row and has been stopped")
                            :format(task.label, task.failures)
                        failures[#failures + 1] = disabled
                        report(self, disabled, task.label)
                        self:cancel(task)
                    end
                end

                if not task.live then break end
                if task.repeating then
                    task.due = task.due + task.interval
                    if runs_this_pass >= self._catch_up and task.due <= now then
                        -- The server was away for a long time. Skip forward to
                        -- the next interval after now rather than running the
                        -- backlog, and say how much was skipped.
                        local behind = now - task.due
                        local missed = behind // task.interval + 1
                        task.due = task.due + missed * task.interval
                        self._skipped = self._skipped + missed
                        -- Not a failure. The server was away and the task is
                        -- deliberately not running the backlog, which is the
                        -- behaviour that stops a week offline becoming ten
                        -- thousand rent charges on the way back up.
                        local message = ("%s skipped %d runs to catch up"):format(task.label, missed)
                        notices[#notices + 1] = message
                        if self._on_notice then self._on_notice(message, task.label) end
                        break
                    end
                else
                    self:cancel(task)
                    break
                end
            until task.due > now
        end
    end
    return ran, failures, notices
end

--- Advance the clock and run whatever falls due on the way. The one call a
--- server tick makes.
function Scheduler:tick(real_ms)
    self._clock:advance(real_ms)
    return self:run()
end

function Scheduler:stats()
    return { ran = self._ran, failed = self._failed, skipped = self._skipped, pending = #self._tasks }
end

return Scheduler
