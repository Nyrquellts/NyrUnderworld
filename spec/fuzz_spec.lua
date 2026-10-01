--- A few cities played by nobody in particular, every time the suite runs.
---
--- `tools/fuzz.lua` is the long run; this is the short one that keeps it
--- honest. Fixed seeds, so a finding here is the same finding on every
--- machine, and the seed and step in the message replay it:
---
---   lua tools/fuzz.lua --seed <seed> --steps <steps> --trail
local modname = ...
local lu = require("luaunit")
local Fuzz = require("tools.fuzz")

local SEEDS = { 1, 2, 3 }
local STEPS = 400

-- Each seed is played once and both tests read the same runs: three cities
-- are a few seconds of the suite, and six would be double that for nothing.
local reports
local function played()
    if reports then return reports end
    reports = {}
    for _, seed in ipairs(SEEDS) do
        reports[#reports + 1] = Fuzz.run({ seed = seed, steps = STEPS })
    end
    return reports
end

TestFuzz = {}

function TestFuzz:test_nothing_a_player_can_do_breaks_what_must_hold()
    for _, report in ipairs(played()) do
        lu.assertEquals(#report.findings, 0, table.concat(Fuzz.describe(report), "\n"))
    end
end

function TestFuzz:test_the_runs_reach_past_the_first_refusal()
    -- A fuzzer that only ever hears "you are not playing anybody" has tested
    -- one line. Across the short runs together, hold it to reaching the parts
    -- of the city that matter. Together, not per seed: which rare command one
    -- seed happens to pick changes whenever the city does.
    local reached, restarts, views = {}, 0, 0
    for _, report in ipairs(played()) do
        for name, row in pairs(report.by_command) do
            if row.ok > 0 then reached[name] = true end
        end
        restarts = restarts + report.restarts
        views = views + report.views
    end
    for _, name in ipairs({ "character.create", "character.select", "me.pockets", "phone.send",
        "work.start", "bank.open", "admin.give", "shop.buy", "bank.deposit" }) do
        lu.assertTrue(reached[name] == true, name .. " never answered ok in the short runs")
    end
    lu.assertTrue(restarts > 0, "the short runs never restarted the city")
    lu.assertTrue(views > 0, "the short runs never drew a screen")
end

function TestFuzz:test_a_seed_replays_the_same_city()
    local first = Fuzz.run({ seed = 11, steps = 120 })
    local second = Fuzz.run({ seed = 11, steps = 120 })
    lu.assertEquals(second.codes, first.codes)
    lu.assertEquals(second.commands, first.commands)
end

if modname == nil then
    os.exit(lu.LuaUnit.run())
end
