--- The city has its own time, and it is not the wall clock.
--
-- Rent is due on a day, shops restock in the morning, heat cools overnight,
-- payroll runs weekly. All of that is measured in city time, which runs faster
-- than real time and can be paused, sped up for a test, or wound forward by an
-- admin. Nothing in the simulation should ever read os.time directly; it reads
-- this.
--
-- The clock does not tick itself. Something outside calls advance() with how
-- much real time has passed, and the clock converts. That is what makes a week
-- of city life testable in a millisecond, and it is why nothing here needs a
-- game running.

local Clock = {}
Clock.__index = Clock

local MS_PER_SECOND = 1000
local MS_PER_MINUTE = 60 * MS_PER_SECOND
local MS_PER_HOUR = 60 * MS_PER_MINUTE
local MS_PER_DAY = 24 * MS_PER_HOUR
local DAYS = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }

Clock.MS_PER_SECOND, Clock.MS_PER_MINUTE = MS_PER_SECOND, MS_PER_MINUTE
Clock.MS_PER_HOUR, Clock.MS_PER_DAY = MS_PER_HOUR, MS_PER_DAY
Clock.DAYS = DAYS

--- opts.rate     city milliseconds per real millisecond. 60 means one real
---               minute is one city hour, which is the usual roleplay pace.
--- opts.start_at city time to start at, in milliseconds since day zero.
--- opts.paused   start stopped.
function Clock.new(opts)
    opts = opts or {}
    local rate = opts.rate or 60
    assert(type(rate) == "number" and rate > 0 and rate == rate and rate ~= math.huge,
        "a clock rate is a positive number of city milliseconds per real millisecond")
    local start_at = opts.start_at or (8 * MS_PER_HOUR)   -- eight in the morning
    assert(math.type(start_at) == "integer" and start_at >= 0, "a clock starts at an integer millisecond")
    return setmetatable({
        _now = start_at,
        _rate = rate,
        _paused = opts.paused == true,
        _real_elapsed = 0,
        _carry = 0.0,
    }, Clock)
end

--- City time, in whole milliseconds since day zero.
function Clock:now() return self._now end

--- Real time fed in so far, in milliseconds. For measuring, not for rules.
function Clock:real_elapsed() return self._real_elapsed end

function Clock:rate() return self._rate end

function Clock:is_paused() return self._paused end

function Clock:pause() self._paused = true return self end

function Clock:resume() self._paused = false return self end

--- Change the pace without losing the fraction of a millisecond already owed.
function Clock:set_rate(rate)
    assert(type(rate) == "number" and rate > 0 and rate == rate and rate ~= math.huge,
        "a clock rate is a positive number")
    self._rate = rate
    return self
end

--- Feed in real elapsed milliseconds. Returns how much city time passed.
---
--- The fractional remainder is carried rather than dropped. A 16 ms frame at a
--- rate that does not divide evenly would otherwise lose a sliver every frame,
--- and a clock that loses a sliver sixty times a second drifts by minutes an
--- hour, which players notice as rent arriving late.
function Clock:advance(real_ms)
    assert(type(real_ms) == "number" and real_ms >= 0 and real_ms == real_ms, "advance takes real milliseconds")
    self._real_elapsed = self._real_elapsed + real_ms
    if self._paused then return 0 end
    local exact = real_ms * self._rate + self._carry
    local whole = math.floor(exact)
    self._carry = exact - whole
    whole = math.tointeger(whole) or 0
    self._now = self._now + whole
    return whole
end

--- Move city time directly. For an admin command and for a test that wants to
--- be at Friday evening without simulating the week.
function Clock:set(now)
    assert(math.type(now) == "integer" and now >= 0, "city time is an integer millisecond count")
    assert(now >= self._now, "city time does not go backwards; make a new clock instead")
    local moved = now - self._now
    self._now = now
    return moved
end

function Clock:skip(city_ms)
    assert(math.type(city_ms) == "integer" and city_ms >= 0, "skip takes whole city milliseconds")
    return self:set(self._now + city_ms)
end

--- Where the city is in its day and week.
function Clock:calendar(at)
    local now = at or self._now
    local day_number = now // MS_PER_DAY
    local into_day = now % MS_PER_DAY
    return {
        day = day_number,
        weekday = DAYS[(day_number % 7) + 1],
        hour = into_day // MS_PER_HOUR,
        minute = (into_day % MS_PER_HOUR) // MS_PER_MINUTE,
        second = (into_day % MS_PER_MINUTE) // MS_PER_SECOND,
        into_day = into_day,
    }
end

--- Readable city time: "day 3 friday 18:45".
function Clock:describe(at)
    local c = self:calendar(at)
    return ("day %d %s %02d:%02d"):format(c.day, c.weekday, c.hour, c.minute)
end

--- The next city time at which it is `hour`:`minute`, strictly after now. What
--- a daily job schedules itself against.
function Clock:next_at(hour, minute, at)
    assert(math.type(hour) == "integer" and hour >= 0 and hour < 24, "an hour is 0..23")
    minute = minute or 0
    assert(math.type(minute) == "integer" and minute >= 0 and minute < 60, "a minute is 0..59")
    local now = at or self._now
    local day_start = (now // MS_PER_DAY) * MS_PER_DAY
    local target = day_start + hour * MS_PER_HOUR + minute * MS_PER_MINUTE
    if target <= now then target = target + MS_PER_DAY end
    return target
end

--- Whether the city is between two hours, wrapping over midnight so that
--- is_between(22, 6) means night.
function Clock:is_between(from_hour, to_hour, at)
    local hour = self:calendar(at).hour
    if from_hour <= to_hour then return hour >= from_hour and hour < to_hour end
    return hour >= from_hour or hour < to_hour
end

--- Persisted so the city is at the same time it was when the server stopped.
function Clock:serialize()
    return { now = self._now, rate = self._rate, paused = self._paused }
end

function Clock.deserialize(record)
    if type(record) ~= "table" then return nil, "a clock record is a table" end
    if math.type(record.now) ~= "integer" or record.now < 0 then return nil, "clock time is missing" end
    return Clock.new({ start_at = record.now, rate = record.rate, paused = record.paused })
end

return Clock
