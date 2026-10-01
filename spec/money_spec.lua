--- Money keeps every unit, or the economy is wrong before anything is built.
local modname = ...
local lu = require("luaunit")
local Money = require("domain.money")

TestMoney = {}

function TestMoney:test_of_and_from_minor_agree()
    lu.assertEquals(Money.of(12, 50):to_minor(), 1250)
    lu.assertEquals(Money.of(0, 5):to_minor(), 5)
    lu.assertEquals(Money.of(7):to_minor(), 700)
    lu.assertEquals(tostring(Money.of(12, 50)), "12.50")
    lu.assertEquals(tostring(Money.of(0, 5)), "0.05")
end

function TestMoney:test_negative_amounts_read_correctly()
    lu.assertEquals(Money.of(-3, 25):to_minor(), -325)
    lu.assertEquals(tostring(Money.of(-3, 25)), "-3.25")
    lu.assertEquals(tostring(Money.from_minor(-5)), "-0.05")
end

function TestMoney:test_floats_and_nonsense_are_refused()
    lu.assertError(Money.from_minor, 10.5)
    lu.assertError(Money.from_minor, "100")
    lu.assertError(Money.from_minor, 0 / 0)
    lu.assertError(Money.from_minor, math.huge)
    lu.assertError(Money.of, 1, 100)   -- minor must be 0..99
    lu.assertError(Money.of, 1, -1)
end

function TestMoney:test_the_classic_float_error_does_not_happen()
    -- 0.1 + 0.2 ~= 0.3 in doubles. In minor units it is exact, every time.
    local dime, twenty = Money.of(0, 10), Money.of(0, 20)
    lu.assertEquals(dime:add(twenty), Money.of(0, 30))
    -- And it stays exact over a long chain, where a float would drift away.
    local running = Money.zero
    for _ = 1, 10000 do running = running:add(Money.of(0, 1)) end
    lu.assertEquals(running, Money.of(100, 0))
end

function TestMoney:test_arithmetic_and_comparison()
    lu.assertEquals(Money.of(10):sub(Money.of(3, 50)), Money.of(6, 50))
    lu.assertEquals(Money.of(2, 50):times(4), Money.of(10))
    lu.assertEquals(Money.of(5):negate(), Money.of(-5))
    lu.assertTrue(Money.of(5) < Money.of(6))
    lu.assertTrue(Money.of(5) <= Money.of(5))
    lu.assertEquals(Money.of(5):compare(Money.of(6)), -1)
    lu.assertTrue(Money.of(5) == Money.from_minor(500))
    lu.assertTrue(Money.zero:is_zero())
    lu.assertTrue(Money.of(-1):is_negative())
end

function TestMoney:test_times_refuses_a_fraction()
    lu.assertError(function() return Money.of(10):times(0.5) end)
end

function TestMoney:test_a_percentage_cut_names_its_remainder()
    local cut, left = Money.of(10):percent(30)
    lu.assertEquals(cut, Money.of(3))
    lu.assertEquals(left, Money.of(7))
    lu.assertEquals(cut:add(left), Money.of(10))
    -- Rounding is half away from zero, and the pair still sums to the whole.
    local odd_cut, odd_left = Money.from_minor(101):percent(50)
    lu.assertEquals(odd_cut:to_minor(), 51)
    lu.assertEquals(odd_cut:add(odd_left):to_minor(), 101)
end

function TestMoney:test_a_split_always_sums_back_to_the_whole()
    for _, case in ipairs({ { 1000, 3 }, { 101, 2 }, { 7, 7 }, { 5, 8 }, { 0, 4 }, { -1000, 3 } }) do
        local amount, parts = Money.from_minor(case[1]), case[2]
        local shares = amount:split(parts)
        lu.assertEquals(#shares, parts)
        local total = Money.zero
        for _, share in ipairs(shares) do total = total:add(share) end
        lu.assertEquals(total, amount,
            string.format("splitting %s into %d lost or gained money", tostring(amount), parts))
    end
end

function TestMoney:test_ten_dollars_three_ways_gives_the_odd_cent_to_someone()
    local shares = Money.of(10):split(3)
    lu.assertEquals(tostring(shares[1]), "3.34")
    lu.assertEquals(tostring(shares[2]), "3.33")
    lu.assertEquals(tostring(shares[3]), "3.33")
end

function TestMoney:test_split_refuses_nonsense()
    lu.assertError(function() return Money.of(10):split(0) end)
    lu.assertError(function() return Money.of(10):split(-1) end)
    lu.assertError(function() return Money.of(10):split(2.5) end)
end

function TestMoney:test_magnitudes_that_would_stop_being_exact_are_refused()
    lu.assertError(Money.from_minor, 2 ^ 53)
    lu.assertError(Money.from_minor, -(2 ^ 53))
end

function TestMoney:test_mixing_money_with_plain_numbers_is_refused()
    lu.assertError(function() return Money.of(1):add(5) end)
    lu.assertError(function() return Money.of(1):sub(nil) end)
end

-- Run alone when invoked directly; stay quiet when the whole suite requires us.
if modname == nil then os.exit(lu.LuaUnit.run()) end
