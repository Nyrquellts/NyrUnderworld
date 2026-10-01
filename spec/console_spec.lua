--- The server console's decisions, held where `server.lua` cannot be.
local modname = ...
local lu = require("luaunit")
local Console = require("adapter.console")

TestConsole = {}

function TestConsole:test_a_staff_level_is_one_of_four_whole_numbers()
    for typed, level in pairs({ ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3, ["2.0"] = 2 }) do
        lu.assertEquals(Console.staff_level(typed), level, typed)
    end
end

function TestConsole:test_a_mistyped_level_is_refused_rather_than_read_as_stand_down()
    -- Before: every one of these quietly removed a member of staff.
    for _, typed in ipairs({ "abc", "1.5", "", "4", "-1", "0x10" }) do
        local level, usage = Console.staff_level(typed)
        lu.assertNil(level, typed .. " was accepted")
        lu.assertStrContains(usage, "nyr staff")
    end
    lu.assertNil(Console.staff_level(nil))
end

function TestConsole:test_a_shutdown_through_a_database_says_what_a_stop_cannot_hear()
    lu.assertNil(Console.shutdown_note(false, false))
    lu.assertStrContains(Console.shutdown_note(true, true), "one transaction")
    lu.assertStrContains(Console.shutdown_note(true, false), "nyr save")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
