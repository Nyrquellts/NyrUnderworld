--- The suite runs every spec there is.
---
--- `tools/run_specs.lua` names each spec by hand, and a file that is not named
--- there is simply never run. That is not a hypothetical: a spec was written
--- this week, the suite was run, it reported the same count as before, and the
--- new tests had not executed once. It was caught by comparing a number, which
--- is not a thing anybody should have to remember to do.
---
--- The hand-written list stays -- it is the order specs run in and it reads as
--- a table of contents. What changes is that leaving a file out of it is now a
--- failure rather than a silence.
---
--- `fake_sql` is a fixture other specs load, not a spec. Anything else new is
--- assumed to be a spec, because assuming a new file should run and being
--- wrong costs one line here, while assuming it should not and being wrong
--- costs whatever the untested code does.
local modname = ...
local lu = require("luaunit")

local RUNNER = "tools/run_specs.lua"
local FIXTURES = { fake_sql = true, readiness_harness = true }

local function read(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

--- Every `spec/<name>.lua` on disk.
---
--- Read by asking the filesystem rather than by keeping a second list, since a
--- second list is the thing that went out of step in the first place.
local function on_disk()
    local names = {}
    -- Two shells, because the suite is run from a .cmd here and by whatever is
    -- to hand elsewhere. Whichever answers first is the one used.
    for _, command in ipairs({ 'dir /b "spec\\*.lua" 2>nul', 'ls -1 spec/*.lua 2>/dev/null' }) do
        local pipe = io.popen(command)
        if pipe then
            for line in pipe:lines() do
                local name = line:match("([%w_]+)%.lua%s*$")
                if name then names[name] = true end
            end
            pipe:close()
        end
        if next(names) then return names end
    end
    return names
end

TestSuite = {}

function TestSuite:test_every_spec_on_disk_is_in_the_runner()
    local runner = read(RUNNER)
    lu.assertNotNil(runner, RUNNER .. " is not where this spec expects it")

    local listed = {}
    for name in runner:gmatch('"spec%.([%w_]+)"') do listed[name] = true end

    local found = on_disk()
    if not next(found) then
        -- Neither shell answered. Say so rather than passing on an empty list,
        -- which is the shape of this check quietly testing nothing.
        lu.fail("could not list spec/ with either dir or ls, so this checked nothing")
    end

    local missing = {}
    for name in pairs(found) do
        if not listed[name] and not FIXTURES[name] then
            missing[#missing + 1] = name
        end
    end
    table.sort(missing)
    lu.assertEquals(#missing, 0,
        "written and never run -- add to " .. RUNNER .. ": " .. table.concat(missing, ", "))
end

function TestSuite:test_the_runner_names_nothing_that_is_not_there()
    -- The other direction: a spec renamed or deleted leaves a line behind, and
    -- `require` on a missing module stops the whole suite rather than one test.
    local runner = read(RUNNER)
    local found = on_disk()
    local ghosts = {}
    for name in runner:gmatch('"spec%.([%w_]+)"') do
        if not found[name] then ghosts[#ghosts + 1] = name end
    end
    table.sort(ghosts)
    lu.assertEquals(#ghosts, 0, "named in the runner and not on disk: " .. table.concat(ghosts, ", "))
end

function TestSuite:test_this_spec_is_itself_in_the_runner()
    -- A checker that is not run checks nothing, and this one is exactly the
    -- kind of file the thing it checks for would swallow.
    local runner = read(RUNNER)
    lu.assertStrContains(runner, '"spec.suite_spec"')
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
