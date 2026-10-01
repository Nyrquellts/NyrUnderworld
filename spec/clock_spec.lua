--- City time runs faster than real time, and it is not allowed to drift.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")

TestClock = {}

function TestClock:setUp()
    -- one real minute is one city hour, starting at eight in the morning
    self.clock = Clock.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR })
end

function TestClock:test_it_starts_where_it_was_told_to()
    lu.assertEquals(self.clock:now(), 8 * Clock.MS_PER_HOUR)
    lu.assertEquals(self.clock:calendar().hour, 8)
    lu.assertEquals(self.clock:calendar().day, 0)
    lu.assertEquals(self.clock:describe(), "day 0 monday 08:00")
end

function TestClock:test_real_time_converts_at_the_rate()
    local moved = self.clock:advance(1000)          -- one real second
    lu.assertEquals(moved, 60000)                   -- one city minute
    lu.assertEquals(self.clock:describe(), "day 0 monday 08:01")
    self.clock:advance(59 * 1000)                   -- the rest of the real minute
    lu.assertEquals(self.clock:describe(), "day 0 monday 09:00")
end

function TestClock:test_the_fraction_of_a_millisecond_is_carried_not_dropped()
    -- A clock that throws away a sliver sixty times a second drifts by minutes
    -- an hour, and players notice that as rent arriving late.
    local drifting = Clock.new({ rate = 1.5, start_at = 0 })
    for _ = 1, 60 do drifting:advance(1) end
    lu.assertEquals(drifting:now(), 90)             -- truncating each step would give 60
    lu.assertEquals(math.type(drifting:now()), "integer")

    -- and over a realistic frame rate, for a real minute
    local framed = Clock.new({ rate = 60, start_at = 0 })
    for _ = 1, 3600 do framed:advance(1000 / 60) end
    lu.assertEquals(framed:describe(), "day 0 monday 01:00")
end

function TestClock:test_a_paused_city_does_not_move()
    self.clock:pause()
    lu.assertEquals(self.clock:advance(10000), 0)
    lu.assertEquals(self.clock:now(), 8 * Clock.MS_PER_HOUR)
    lu.assertTrue(self.clock:is_paused())
    lu.assertEquals(self.clock:real_elapsed(), 10000)   -- real time still counted
    self.clock:resume()
    lu.assertEquals(self.clock:advance(1000), 60000)
end

function TestClock:test_the_pace_can_change()
    self.clock:set_rate(1)
    lu.assertEquals(self.clock:advance(1000), 1000)
    lu.assertEquals(self.clock:rate(), 1)
    lu.assertError(function() return self.clock:set_rate(0) end)
    lu.assertError(function() return self.clock:set_rate(-1) end)
    lu.assertError(function() return Clock.new({ rate = 0 }) end)
end

function TestClock:test_time_can_be_wound_forward_but_never_back()
    local moved = self.clock:skip(Clock.MS_PER_HOUR * 4)
    lu.assertEquals(moved, Clock.MS_PER_HOUR * 4)
    lu.assertEquals(self.clock:describe(), "day 0 monday 12:00")
    lu.assertError(function() return self.clock:set(0) end)
    lu.assertError(function() return self.clock:skip(-1) end)
end

function TestClock:test_the_week_turns_over()
    self.clock:skip(Clock.MS_PER_DAY * 4)
    lu.assertEquals(self.clock:calendar().weekday, "friday")
    lu.assertEquals(self.clock:calendar().day, 4)
    self.clock:skip(Clock.MS_PER_DAY * 3)
    lu.assertEquals(self.clock:calendar().weekday, "monday")
    lu.assertEquals(self.clock:calendar().day, 7)
end

function TestClock:test_the_next_time_it_is_a_given_hour()
    -- it is 08:00, so the next 18:00 is today and the next 06:00 is tomorrow
    lu.assertEquals(self.clock:describe(self.clock:next_at(18, 0)), "day 0 monday 18:00")
    lu.assertEquals(self.clock:describe(self.clock:next_at(6, 30)), "day 1 tuesday 06:30")
    -- and the current hour exactly counts as tomorrow, not right now
    lu.assertEquals(self.clock:describe(self.clock:next_at(8, 0)), "day 1 tuesday 08:00")
    lu.assertError(function() return self.clock:next_at(24) end)
    lu.assertError(function() return self.clock:next_at(1, 60) end)
end

function TestClock:test_night_wraps_over_midnight()
    lu.assertFalse(self.clock:is_between(22, 6))    -- 08:00 is not night
    lu.assertTrue(self.clock:is_between(6, 22))
    self.clock:skip(Clock.MS_PER_HOUR * 15)         -- 23:00
    lu.assertTrue(self.clock:is_between(22, 6))
    self.clock:skip(Clock.MS_PER_HOUR * 3)          -- 02:00 the next day
    lu.assertTrue(self.clock:is_between(22, 6))
    lu.assertFalse(self.clock:is_between(6, 22))
end

function TestClock:test_the_city_restarts_at_the_time_it_stopped()
    self.clock:skip(Clock.MS_PER_HOUR * 30)
    self.clock:set_rate(120)
    local restored = assert(Clock.deserialize(self.clock:serialize()))
    lu.assertEquals(restored:now(), self.clock:now())
    lu.assertEquals(restored:rate(), 120)
    lu.assertEquals(restored:describe(), self.clock:describe())
    lu.assertNil(Clock.deserialize({}))
    lu.assertNil(Clock.deserialize("nope"))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
