--- The dev bridge decides who it is driving and whether it can be driven.
---
--- Those decisions used to live inside `DevBridge.install`, which needs a
--- running FXServer to call and therefore could not be attacked from here at
--- all. Three defects sat in it and were found by reading, not by a test: a
--- position built from `tonumber("oops")` and sent with no `x`; a screen name
--- forwarded without anybody checking there was such a screen; and a target
--- left as the string it arrived as, where `-1` means every client.
---
--- All three answered `200 ok`, which is the shape of the answer that worked.
--- A recording rig reads that and carries on to the next beat.
---
--- So the decisions moved onto the module and the route below them only calls
--- and sends. This file attacks them, and then loads the client's half the way
--- the client loads it -- no `require`, natives stubbed -- to check that what
--- the server refuses to send is also what the client refuses to do.
local modname = ...
local lu = require("luaunit")
local DevBridge = require("adapter.devbridge")

--- One client, id 1, the way `GetPlayers()` hands them over: as strings.
local ALONE = { "1" }
local NOBODY = {}

TestDevBridgeAct = {}

-- ------------------------------------------------ the three that were found

function TestDevBridgeAct:test_a_position_missing_a_number_is_refused_not_sent()
    -- `tonumber("oops")` is nil, and a table with a nil in it is a table with
    -- one fewer key. What arrived at the client was {y, z} and a 200.
    local plan, why = DevBridge.act_plan({ p = "1", x = "oops", y = "1", z = "2" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "x=oops")

    -- And two axes out of three is a typo, not a place. Left out and mistyped
    -- are different mistakes, and the answer says which.
    local _, missing = DevBridge.act_plan({ p = "1", x = "1", y = "2" }, ALONE)
    lu.assertStrContains(missing, "z is missing")
    lu.assertNotStrContains(missing, "nil")
    lu.assertNil(DevBridge.act_plan({ p = "1", z = "2" }, ALONE))
end

function TestDevBridgeAct:test_a_screen_nobody_has_is_refused_and_the_real_ones_are_named()
    local plan, why = DevBridge.act_plan({ p = "1", show = "misspelled" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "misspelled")
    -- Refusing without saying what would have worked is half an answer.
    lu.assertStrContains(why, "pockets")
end

function TestDevBridgeAct:test_the_target_is_a_connected_whole_number_not_a_string()
    local plan = DevBridge.act_plan({ p = "1", show = "pockets" }, ALONE)
    lu.assertEquals(plan.to, 1)
    lu.assertEquals(math.type(plan.to), "integer")

    -- -1 is every client everywhere else in FiveM. A recording drives one.
    lu.assertNil(DevBridge.act_plan({ p = "-1", show = "pockets" }, ALONE))
    lu.assertNil(DevBridge.act_plan({ p = "0", show = "pockets" }, ALONE))
    lu.assertNil(DevBridge.act_plan({ p = "1.5", show = "pockets" }, ALONE))
    lu.assertNil(DevBridge.act_plan({ p = "abc", show = "pockets" }, ALONE))
    lu.assertNil(DevBridge.act_plan({ p = "", show = "pockets" }, ALONE))
end

-- --------------------------------------------------------- and their family

function TestDevBridgeAct:test_a_target_that_is_not_here_is_refused()
    local plan, why, status = DevBridge.act_plan({ p = "2", show = "pockets" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "no client 2")
    -- Saying who is here is the difference between one more request and ten.
    lu.assertStrContains(why, "connected: 1")
    -- Nothing about the instruction is wrong, so it is not answered as though it
    -- were: 404, the player is not here. Nobody at all counts the same way.
    lu.assertEquals(status, 404)
    lu.assertEquals(select(3, DevBridge.act_plan({ show = "pockets" }, NOBODY)), 404)
end

function TestDevBridgeAct:test_a_target_nobody_could_name_is_a_bad_request()
    for _, asked in ipairs({ "-1", "0", "1.5", "abc" }) do
        local plan, _, status = DevBridge.act_plan({ p = asked, show = "pockets" }, ALONE)
        lu.assertNil(plan)
        lu.assertEquals(status, 400, ("p=%s was not answered as a bad request"):format(asked))
    end
    lu.assertEquals(select(3, DevBridge.act_plan({ show = "pockets" }, { "3", "1" })), 400)
end

function TestDevBridgeAct:test_with_nobody_named_the_one_client_here_is_the_one_driven()
    lu.assertEquals(DevBridge.act_plan({ show = "pockets" }, ALONE).to, 1)
    -- The rig sends one beat after another at whoever is connected. Making it
    -- name a client it did not choose is a lie waiting to be recorded.
    lu.assertEquals(DevBridge.act_plan({ show = "pockets" }, { "7" }).to, 7)
end

function TestDevBridgeAct:test_with_nobody_connected_there_is_nothing_to_drive()
    local plan, why = DevBridge.act_plan({ show = "pockets" }, NOBODY)
    lu.assertNil(plan)
    lu.assertStrContains(why, "no client is connected")
end

function TestDevBridgeAct:test_with_several_here_the_rig_has_to_say_which()
    local plan, why = DevBridge.act_plan({ show = "pockets" }, { "3", "1" })
    lu.assertNil(plan)
    lu.assertStrContains(why, "1, 3")
    -- Naming one of them works.
    lu.assertEquals(DevBridge.act_plan({ p = "3", show = "pockets" }, { "3", "1" }).to, 3)
end

function TestDevBridgeAct:test_a_coordinate_that_is_not_finite_is_not_a_place()
    -- tonumber("1e999") is infinity, and is perfectly happy about it.
    lu.assertNil(DevBridge.act_plan({ p = "1", x = "1e999", y = "2", z = "3" }, ALONE))
    lu.assertNil(DevBridge.act_plan({ p = "1", x = "1", y = "2", z = "3", h = "1e999" }, ALONE))
end

function TestDevBridgeAct:test_a_heading_with_nowhere_to_face_is_refused()
    local plan, why = DevBridge.act_plan({ p = "1", h = "90" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "x, y and z")
    lu.assertNil(DevBridge.act_plan({ p = "1", x = "1", y = "2", z = "3", h = "north" }, ALONE))
end

function TestDevBridgeAct:test_an_empty_instruction_is_refused()
    local plan, why = DevBridge.act_plan({ p = "1" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "nothing to do")
    lu.assertNil(DevBridge.act_plan(nil, ALONE))
end

function TestDevBridgeAct:test_a_bad_request_is_reported_as_bad_even_with_nobody_connected()
    -- The rig gets written against a server with no players in it. A request
    -- shape can be checked long before there is a client to send it to.
    local _, why = DevBridge.act_plan({ show = "misspelled" }, NOBODY)
    lu.assertStrContains(why, "misspelled")
end

function TestDevBridgeAct:test_what_it_does_accept_arrives_as_numbers()
    local plan = DevBridge.act_plan(
        { p = "1", x = "-1.5", y = "0", z = "72.25", h = "180" }, ALONE)
    lu.assertEquals(plan.what.at, { x = -1.5, y = 0, z = 72.25 })
    lu.assertEquals(plan.what.heading, 180)
    lu.assertNil(plan.what.show)

    -- A screen and a place in one instruction is one beat of a recording.
    local both = DevBridge.act_plan(
        { p = "1", show = "phone", x = "1", y = "2", z = "3" }, ALONE)
    lu.assertEquals(both.what.show, "phone")
    lu.assertEquals(both.what.at.x, 1)
end

function TestDevBridgeAct:test_every_screen_the_bridge_declares_is_one_it_accepts()
    for _, screen in ipairs(DevBridge.SCREENS) do
        local plan = DevBridge.act_plan({ p = "1", show = screen }, ALONE)
        lu.assertNotNil(plan, screen .. " is declared and refused")
        lu.assertEquals(plan.what.show, screen)
    end
end

TestDevBridgeWhere = {}

--- The line the bridge prints at boot is the first thing anybody reads about
--- it, and it was wrong on one of the two servers for as long as nobody looked.
---
--- `netPort` is the right convar on both. What differs is when it can be read,
--- measured with the same probe on each:
---
---                      at script load   in a thread body
---     legacy 35245         30151             30151
---     enhanced 139             0             30150
---
--- `install` runs at script load, so on Enhanced it built its URL from 0 and
--- printed http://127.0.0.1:0/nyr_underworld/state with a straight face.

function TestDevBridgeWhere:test_a_real_port_becomes_somewhere_to_go()
    local line = DevBridge.where(30120, "nyr_underworld")
    lu.assertStrContains(line, "http://127.0.0.1:30120/nyr_underworld/state")
end

function TestDevBridgeWhere:test_a_port_the_server_has_not_bound_is_not_dressed_as_a_url()
    -- 0 is what Enhanced answers for the whole of script load. A URL built from
    -- it cannot be opened, and looks exactly like one that can.
    --
    -- Listed with an explicit count rather than as an array: `nil` in a table
    -- literal ends it as far as `ipairs` is concerned, so a loop over
    -- `{ 0, -1, nil, "" }` silently stops at the second value and the rest of
    -- the cases are never tried. The first draft of this test did exactly that.
    local unbound = { 0, -1, nil, "", "later", 1.5, 65536, 70000, n = 8 }
    for i = 1, unbound.n do
        local line = DevBridge.where(unbound[i], "nyr_underworld")
        lu.assertNotStrContains(line, "http://")
        lu.assertNotStrContains(line, ":0/")
        -- Still says where the bridge is, just not a port it cannot vouch for.
        lu.assertStrContains(line, "/nyr_underworld/state")
        lu.assertStrContains(line, "endpoint_add_tcp")
    end
end

function TestDevBridgeWhere:test_it_names_the_resource_it_is_actually_in()
    -- Renaming the folder renames the routes; a line naming the old one sends
    -- the reader to a 404.
    lu.assertStrContains(DevBridge.where(30120, "someone_elses_name"),
        "/someone_elses_name/state")
end

TestDevBridgeQuery = {}

function TestDevBridgeQuery:test_a_url_becomes_the_arguments_a_plan_is_made_from()
    -- End to end from the string the route actually receives.
    lu.assertEquals(DevBridge.act_plan(DevBridge.query_of("/act?p=1&show=pockets"), ALONE).to, 1)

    local moving = DevBridge.query_of("/act?p=1&x=-1.5&y=0&z=72.25&h=180")
    lu.assertEquals(DevBridge.act_plan(moving, ALONE).what.at.y, 0)

    -- And the one that used to answer 200.
    lu.assertNil(DevBridge.act_plan(DevBridge.query_of("/act?p=1&x=oops&y=1&z=2"), ALONE))
end

function TestDevBridgeQuery:test_a_path_with_no_query_asks_for_nothing()
    lu.assertEquals(DevBridge.query_of("/act"), {})
end


-- --------------------------------------- and the half that is on the client

--- Load `adapter/devclient.lua` the way the client does.
---
--- Not `require`: a FiveM client has no module system, so the file is executed
--- into a namespace that already has the natives in it. Here that namespace
--- holds the standard library and stubs that record what was called, which is
--- how a native reached by mistake becomes a failing assertion instead of a
--- body that moved on somebody's screen in the middle of a recording.
local function load_devclient(world)
    local calls = { coords = {}, heading = {}, opened = {}, errors = {}, ran = {}, reports = {},
                    walks = {}, pressed = 0 }
    local handlers, threads = {}, {}
    local lapped = false
    local sandbox = {}
    for _, name in ipairs({
        "assert", "error", "ipairs", "math", "next", "pairs", "pcall", "select",
        "setmetatable", "getmetatable", "string", "table", "tonumber", "tostring",
        "type", "os",
    }) do
        sandbox[name] = _G[name]
    end

    sandbox.RegisterNetEvent = function() end
    sandbox.AddEventHandler = function(name, fn) handlers[name] = fn end
    -- Threads are kept, not started. The reporting loop never ends, so a test
    -- that wants a report runs it for one lap with `report_once` below.
    sandbox.CreateThread = function(fn) threads[#threads + 1] = fn end
    sandbox.Wait = function()
        if lapped then error("one lap", 0) end
    end
    sandbox.TriggerServerEvent = function(name, body)
        if name == "nyr:dev:report" then
            calls.reports[#calls.reports + 1] = body
            lapped = true
        end
    end
    sandbox.ExecuteCommand = function(name) calls.ran[#calls.ran + 1] = name end

    sandbox.PlayerPedId = function() return 7 end
    sandbox.DoesEntityExist = function() return true end
    sandbox.GetEntityCoords = function() return { x = 1.0, y = 2.0, z = 3.0 } end
    sandbox.IsScreenFadedOut = function() return false end
    sandbox.IsEntityVisible = function() return 1 end
    sandbox.GetEntityModel = function() return 1885233650 end
    sandbox.GetEntityHealth = function() return 200 end
    sandbox.SetEntityCoords = function(ped, x, y, z)
        calls.coords[#calls.coords + 1] = { ped = ped, x = x, y = y, z = z }
    end
    sandbox.SetEntityHeading = function(_, h) calls.heading[#calls.heading + 1] = h end
    sandbox.TaskFollowNavMeshToCoord = function(ped, x, y, z, speed)
        calls.walks[#calls.walks + 1] = { ped = ped, x = x, y = y, z = z, speed = speed }
    end
    sandbox.NyrWorldPress = function() calls.pressed = calls.pressed + 1 return true end
    sandbox.NyrPickerIsOpen = function() return false end
    for _, opener in ipairs({ "NyrPickerOpen", "NyrPocketsOpen", "NyrPhoneOpen",
                             "NyrNearbyOpen", "NyrJobsOpen", "NyrPickerClose" }) do
        sandbox[opener] = function() calls.opened[#calls.opened + 1] = opener end
    end
    -- What `adapter/world.lua` defines on a real client, when a test says so.
    for name, fn in pairs(world or {}) do sandbox[name] = fn end

    require("spec.readiness_harness")(sandbox)

    assert(loadfile("adapter/devclient.lua", "t", sandbox))()

    -- Its own error keeper is a local, so this is the only way to read it.
    -- Replacing it after the file has loaded works because the call sites look
    -- the name up when they call, not when they were written. The real one is
    -- kept too, for the tests about what it keeps.
    calls.keep_error = sandbox.NyrDevError
    sandbox.NyrDevError = function(_, message)
        calls.errors[#calls.errors + 1] = tostring(message)
    end

    --- One lap of the reporting loop, and what it sent. The loop is the last
    --- thread started, which is the one `nyr:dev:on` starts.
    local function report_once()
        local sent = #calls.reports
        lapped = false
        local ok, why = pcall(threads[#threads])
        lapped = false
        assert(not ok and why == "one lap", "the reporting loop did not lap: " .. tostring(why))
        assert(#calls.reports == sent + 1, "a lap of the reporting loop sent no report")
        return calls.reports[#calls.reports]
    end

    return handlers, calls, report_once
end

TestDevClientActs = {}

function TestDevClientActs:test_it_does_nothing_at_all_until_a_lan_server_says_so()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:act"]({ show = "pockets" })
    lu.assertEquals(calls.opened, {})
    -- On a public server `nyr:dev:on` is never sent, so that is the whole file.
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ show = "pockets" })
    lu.assertEquals(calls.opened, { "NyrPocketsOpen" })
end

function TestDevClientActs:test_every_screen_the_server_will_send_is_one_the_client_opens()
    -- The two lists are in different files, one of which the server never
    -- loads and the other the client never loads. Nothing but this keeps them
    -- equal, and a screen the server accepts and the client drops is another
    -- 200 that did nothing.
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    for _, screen in ipairs(DevBridge.SCREENS) do
        handlers["nyr:dev:act"]({ show = screen })
    end
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(#calls.opened, #DevBridge.SCREENS)
end

function TestDevClientActs:test_the_client_declares_no_screen_the_server_cannot_reach()
    -- The other direction: a screen only the client knows about is a screen
    -- that nothing can ever ask for.
    local text = assert(io.open("adapter/devclient.lua")):read("a")
    local block = assert(text:match("local SCREENS = {(.-)\n}"))
    local declared = {}
    for name in block:gmatch("([%w_]+)%s*=%s*function") do declared[#declared + 1] = name end
    table.sort(declared)

    local sent = { table.unpack(DevBridge.SCREENS) }
    table.sort(sent)
    lu.assertEquals(declared, sent)
end

function TestDevClientActs:test_a_screen_the_server_would_refuse_never_reaches_a_native()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ show = "misspelled" })
    lu.assertEquals(calls.opened, {})
    lu.assertStrContains(calls.errors[1], "misspelled")
end

function TestDevClientActs:test_a_position_missing_a_number_never_reaches_a_native()
    -- SetEntityCoords(ped, nil + 0.0, ...) throws, the pcall swallows it, and
    -- the body is where it was. Refusing by name says so instead.
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ at = { y = 1, z = 2 } })
    handlers["nyr:dev:act"]({ at = { x = "1", y = 1, z = 2 } })
    handlers["nyr:dev:act"]({ at = "over there" })
    handlers["nyr:dev:act"]({ at = { x = 1, y = 2, z = 3 }, heading = "north" })
    lu.assertEquals(calls.coords, {})
    lu.assertEquals(#calls.errors, 4)
end

function TestDevClientActs:test_a_well_formed_move_is_carried_out()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ at = { x = 1.5, y = 2, z = 3 }, heading = 180 })
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(calls.coords[1].x, 1.5)
    lu.assertEquals(calls.coords[1].ped, 7)
    lu.assertEquals(calls.heading[1], 180)
end

function TestDevClientActs:test_what_the_bridge_plans_is_what_the_client_accepts()
    -- The whole path, from the URL the rig sends to the native that runs:
    -- nothing in between reinterprets it.
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    local plan = DevBridge.act_plan(
        DevBridge.query_of("/act?p=1&show=phone&x=10&y=20&z=30&h=90"), ALONE)
    handlers["nyr:dev:act"](plan.what)
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(calls.coords[1].x, 10.0)
    lu.assertEquals(calls.heading[1], 90.0)
    lu.assertEquals(calls.opened, { "NyrPhoneOpen" })
end

-- ------------------------------------- walking there, and pressing E there
--
-- A recording that teleports between places looks like one, and one that asks
-- a person to walk and press keys for it put a person through a take that
-- failed twice on 2026-09-13. So the body can be walked, by the game's own
-- route finding, and E can be pressed through the function the key calls.

function TestDevClientActs:test_a_walk_goes_through_route_finding_at_walking_pace()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ walk = { x = 149, y = -1040.5, z = 29 } })
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(#calls.walks, 1)
    lu.assertEquals(calls.walks[1].ped, 7)
    lu.assertEquals(calls.walks[1].y, -1040.5)
    lu.assertEquals(calls.walks[1].speed, 1.0)
    handlers["nyr:dev:act"]({ walk = { x = 1, y = 2, z = 3 }, pace = "run" })
    lu.assertEquals(calls.walks[2].speed, 2.0)
    -- Walking is not a teleport.
    lu.assertEquals(calls.coords, {})
end

function TestDevClientActs:test_a_walk_missing_a_number_never_reaches_a_native()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ walk = { x = 1, y = 2 } })
    handlers["nyr:dev:act"]({ walk = "the bank" })
    handlers["nyr:dev:act"]({ walk = { x = 1, y = 2, z = 3 }, pace = "fly" })
    lu.assertEquals(calls.walks, {})
    lu.assertEquals(#calls.errors, 3)
end

function TestDevClientActs:test_a_press_is_what_e_does_and_nothing_else()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ press = true })
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(calls.pressed, 1)
    handlers["nyr:dev:act"]({ press = "yes" })
    lu.assertEquals(calls.pressed, 1)
    lu.assertEquals(#calls.errors, 1)
end

function TestDevClientActs:test_the_e_key_and_the_bridge_press_are_one_function()
    -- A second way to open a counter would be a second thing to be wrong. The
    -- key handler in world.lua calls the same `press` the bridge reaches.
    local text = assert(io.open("adapter/world.lua")):read("a")
    lu.assertStrContains(text, "function NyrWorldPress()")
    local key = text:match("IsControlJustReleased%(0, 38%)%s*then%s*(.-)%s*end")
    lu.assertEquals(key, "press(place)")
end

function TestDevBridgeAct:test_a_walk_needs_three_numbers_and_says_which_is_wrong()
    local plan = DevBridge.act_plan({ p = "1", wx = "149", wy = "-1040", wz = "29" }, ALONE)
    lu.assertEquals(plan.what.walk, { x = 149, y = -1040, z = 29 })
    lu.assertEquals(plan.what.pace, "walk")
    lu.assertEquals(DevBridge.act_plan({ p = "1", wx = "1", wy = "2", wz = "3", pace = "run" }, ALONE).what.pace, "run")

    local _, missing = DevBridge.act_plan({ p = "1", wx = "1", wy = "2" }, ALONE)
    lu.assertStrContains(missing, "wz is missing")
    local _, typo = DevBridge.act_plan({ p = "1", wx = "oops", wy = "2", wz = "3" }, ALONE)
    lu.assertStrContains(typo, "wx=oops")
    local _, pace = DevBridge.act_plan({ p = "1", wx = "1", wy = "2", wz = "3", pace = "fly" }, ALONE)
    lu.assertStrContains(pace, "fly")
end

function TestDevBridgeAct:test_a_body_is_walked_or_moved_not_both()
    local plan, why = DevBridge.act_plan(
        { p = "1", x = "1", y = "2", z = "3", wx = "4", wy = "5", wz = "6" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "walk")
end

function TestDevBridgeAct:test_a_safe_move_is_a_move_that_asks_for_ground()
    -- Put at a shop's own coordinates, a body stood on top of the counter. A safe
    -- move asks the game for the nearest place a person can stand instead.
    local plan = DevBridge.act_plan({ p = "1", x = "-47", y = "-1757", z = "29", safe = "1" }, ALONE)
    lu.assertTrue(plan.what.safe)
    local _, why = DevBridge.act_plan({ p = "1", safe = "1", show = "pockets" }, ALONE)
    lu.assertStrContains(why, "safe")
end

function TestDevClientActs:test_a_safe_move_stands_the_body_where_the_game_says_is_ground()
    local handlers, calls = load_devclient({
        GetSafeCoordForPed = function(x, y, z) return true, { x = x + 2.0, y = y, z = z - 1.0 } end,
    })
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ at = { x = -47, y = -1757, z = 29 }, safe = true })
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(calls.coords[1].x, -45.0)
    lu.assertEquals(calls.coords[1].z, 28.0)
    -- And where the game finds nothing, the body goes where it was asked to.
    local handlers2, calls2 = load_devclient({ GetSafeCoordForPed = function() return false, nil end })
    handlers2["nyr:dev:on"]()
    handlers2["nyr:dev:act"]({ at = { x = 1, y = 2, z = 3 }, safe = true })
    lu.assertEquals(calls2.coords[1].x, 1.0)
end

function TestDevBridgeAct:test_press_is_a_yes_or_it_is_refused()
    lu.assertTrue(DevBridge.act_plan({ p = "1", press = "1" }, ALONE).what.press)
    lu.assertTrue(DevBridge.act_plan({ p = "1", press = "true" }, ALONE).what.press)
    local plan, why = DevBridge.act_plan({ p = "1", press = "maybe" }, ALONE)
    lu.assertNil(plan)
    lu.assertStrContains(why, "press")
end

function TestDevClientActs:test_a_walk_and_a_press_the_bridge_plans_are_what_the_client_does()
    local handlers, calls = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"](DevBridge.act_plan(
        DevBridge.query_of("/act?p=1&wx=10&wy=20&wz=30&pace=run"), ALONE).what)
    handlers["nyr:dev:act"](DevBridge.act_plan(DevBridge.query_of("/act?p=1&press=1"), ALONE).what)
    lu.assertEquals(calls.errors, {})
    lu.assertEquals(calls.walks[1].x, 10.0)
    lu.assertEquals(calls.walks[1].speed, 2.0)
    lu.assertEquals(calls.pressed, 1)
end

-- ------------------------------------------ what the client says it drew

TestDevClientReports = {}

function TestDevClientReports:test_the_marks_and_the_prompt_the_world_drew_are_reported()
    local handlers, _, report_once = load_devclient({
        NyrWorldMarked = function() return 4 end,
        NyrWorldPrompt = function() return "Press ~INPUT_CONTEXT~ to shop" end,
    })
    handlers["nyr:dev:on"]()
    local body = report_once()
    lu.assertEquals(body.marked, 4)
    lu.assertEquals(body.prompt, "Press ~INPUT_CONTEXT~ to shop")
end

function TestDevClientReports:test_a_map_with_nothing_on_it_arrives_as_nothing_not_as_silence()
    -- The measurement this field exists for. Zero marks is the defect a player
    -- sees as an empty map, and a zero that became nil on the way would read
    -- as a client that never said -- which is how `visible` spent its life.
    local handlers, _, report_once = load_devclient({
        NyrWorldMarked = function() return 0 end,
        NyrWorldPrompt = function() return nil end,
    })
    handlers["nyr:dev:on"]()
    local body = report_once()
    lu.assertEquals(body.marked, 0)
    lu.assertNil(body.prompt)

    DevBridge.report(11, body)
    local said = DevBridge.about(DevBridge.seen(11), true)
    lu.assertEquals(said.marked, 0, "zero marks did not survive the bridge")
    lu.assertNil(said.prompt)
end

function TestDevClientReports:test_without_a_world_layer_nothing_is_claimed_about_marks()
    local handlers, _, report_once = load_devclient()
    handlers["nyr:dev:on"]()
    lu.assertNil(report_once().marked)
end

function TestDevClientReports:test_the_same_key_pressed_twice_leaves_two_different_last_words()
    -- A journey takes `did` changing as the proof a press arrived. Without a
    -- number in it, a second press of one key reads exactly like the first.
    local handlers, calls, report_once = load_devclient()
    handlers["nyr:dev:on"]()
    handlers["nyr:dev:act"]({ run = "nyrboard" })
    local first = report_once().did
    handlers["nyr:dev:act"]({ run = "nyrboard" })
    local second = report_once().did
    lu.assertEquals(calls.ran, { "nyrboard", "nyrboard" })
    lu.assertEquals(calls.errors, {})
    lu.assertStrContains(first, "run nyrboard ")
    lu.assertStrContains(second, "run nyrboard ")
    lu.assertStrContains(second, "returned")
    lu.assertNotEquals(first, second)
end

-- --------------------------------------------- running what a player runs

TestActRun = {}

function TestActRun:test_it_runs_a_command_this_resource_registers()
    local plan = DevBridge.act_plan({ p = "1", run = "nyrjobs" }, { "1" })
    lu.assertNotNil(plan, "a registered command was refused")
    lu.assertEquals(plan.what.run, "nyrjobs")
    lu.assertEquals(plan.to, 1)
end

function TestActRun:test_it_runs_a_key_binding_too()
    -- A key mapping is a command with a key on it, so pressing F3 and running
    -- `nyrpockets` are the same door.
    local plan = DevBridge.act_plan({ p = "1", run = "nyrpockets" }, { "1" })
    lu.assertNotNil(plan)
    lu.assertEquals(plan.what.run, "nyrpockets")
end

function TestActRun:test_it_will_not_run_anything_else()
    -- Not a console line, not another resource's command, not a native. A
    -- bridge that runs whatever a URL says is a much larger thing than one
    -- that presses this resource's own buttons, and this is the smaller thing.
    for _, name in ipairs({ "quit", "restart", "load_server_icon", "nyrnope", "" }) do
        local plan, why = DevBridge.act_plan({ p = "1", run = name }, { "1" })
        lu.assertNil(plan, ("%q was allowed to run"):format(name))
        lu.assertStrContains(why, "registers")
    end
end

function TestActRun:test_running_and_moving_and_showing_can_arrive_together()
    local plan = DevBridge.act_plan(
        { p = "1", run = "nyrjobs", x = "1", y = "2", z = "3" }, { "1" })
    lu.assertEquals(plan.what.run, "nyrjobs")
    lu.assertEquals(plan.what.at, { x = 1.0, y = 2.0, z = 3.0 })
end

function TestActRun:test_an_empty_instruction_still_says_what_to_send()
    local plan, why = DevBridge.act_plan({ p = "1" }, { "1" })
    lu.assertNil(plan)
    lu.assertStrContains(why, "run=")
end

-- ------------------------------------------- what a native calls yes

TestBoolish = {}

function TestBoolish:test_a_native_that_answers_one_means_yes()
    -- `IsEntityVisible` on a player's own ped answers the number 1, and the
    -- field that read it compared against `true`. Which is false for 1, so a
    -- ped that was plainly drawn was reported as not drawn -- every time,
    -- since the field was written.
    lu.assertTrue(DevBridge.boolish(1))
    lu.assertTrue(DevBridge.boolish(true))
end

function TestBoolish:test_a_native_that_answers_zero_means_no()
    lu.assertFalse(DevBridge.boolish(0))
    lu.assertFalse(DevBridge.boolish(false))
end

function TestBoolish:test_nobody_said_is_not_no()
    -- Absent is false here on purpose: a client that sent no field is a client
    -- that is not reporting, and the snapshot already says so separately.
    lu.assertFalse(DevBridge.boolish(nil))
    -- But a value that is not an answer at all is not turned into one.
    for _, junk in ipairs({ "yes", "", 2, -1, {} }) do
        lu.assertNil(DevBridge.boolish(junk),
            ("%s was read as an answer"):format(tostring(junk)))
    end
end

function TestBoolish:test_what_the_client_measures_survives_the_bridge()
    -- The whole defect in one test. The client measures, `report` keeps, the
    -- snapshot reads -- and the middle step dropped three of these on the
    -- floor for as long as they existed, while the snapshot turned the missing
    -- ones into a confident `false`.
    DevBridge.report(7, {
        spawned = 1, visible = 1, nui = 0, model = 1885233650,
        hp = 200, pos = "1, 2, 3", showing = "pockets",
        marked = 5, prompt = "Press ~INPUT_CONTEXT~ to bank",
    })
    local kept = DevBridge.seen(7)
    lu.assertNotNil(kept, "the bridge kept nothing at all")
    lu.assertTrue(kept.spawned)
    lu.assertTrue(kept.visible, "the field that catches an invisible player was dropped again")
    lu.assertFalse(kept.nui)
    lu.assertEquals(kept.model, 1885233650)
    lu.assertEquals(kept.hp, 200)
    lu.assertEquals(kept.pos, "1, 2, 3")
    lu.assertEquals(kept.showing, "pockets")
    lu.assertEquals(kept.marked, 5, "the marks the client drew were dropped")
    lu.assertEquals(kept.prompt, "Press ~INPUT_CONTEXT~ to bank")
end

function TestBoolish:test_a_client_that_says_it_is_not_drawn_is_believed()
    DevBridge.report(8, { spawned = true, visible = 0 })
    lu.assertFalse(DevBridge.seen(8).visible,
        "a client reporting an undrawn body was not taken at its word")
end

-- ------------------------------------- what a snapshot says about a client

TestAbout = {}

function TestAbout:test_a_fresh_report_reaches_the_snapshot_intact()
    local said = DevBridge.about({
        spawned = true, visible = true, model = 1885233650, nui = false,
        hp = 200, pos = "1, 2, 3", showing = "pockets", loaded = "commands=table",
        marked = 5, prompt = "Press ~INPUT_CONTEXT~ to shop",
    }, true)
    lu.assertTrue(said.reporting)
    lu.assertTrue(said.spawned)
    lu.assertTrue(said.visible)
    lu.assertEquals(said.model, 1885233650)
    lu.assertEquals(said.hp, 200)
    lu.assertEquals(said.pos, "1, 2, 3")
    lu.assertEquals(said.showing, "pockets")
    lu.assertEquals(said.loaded, "commands=table")
    lu.assertEquals(said.marked, 5)
    lu.assertEquals(said.prompt, "Press ~INPUT_CONTEXT~ to shop")
end

function TestAbout:test_a_client_saying_no_is_not_turned_into_a_client_saying_nothing()
    -- `fresh and report.visible or nil` reads well and is wrong for exactly the
    -- values that matter: false becomes nil, so "this player has no body drawn"
    -- -- the one thing this field exists to say -- arrives as "no answer".
    local said = DevBridge.about({ spawned = true, visible = false, nui = false }, true)
    lu.assertFalse(said.visible, "an undrawn player was reported as unknown")
    lu.assertFalse(said.nui)
    lu.assertNotNil(said.visible)
end

function TestAbout:test_a_stale_client_contributes_nothing_it_measured()
    -- Whatever it last said about its body was true some time ago, which is
    -- not a claim worth making now.
    local said = DevBridge.about({
        spawned = true, visible = true, hp = 200, pos = "1, 2, 3",
        loaded = "commands=table", marked = 5, prompt = "Press E",
    }, false)
    lu.assertFalse(said.reporting)
    lu.assertNil(said.spawned)
    lu.assertNil(said.visible)
    lu.assertNil(said.hp)
    lu.assertNil(said.pos)
    lu.assertNil(said.marked)
    lu.assertNil(said.prompt)
    -- What it loaded and what threw are not moment-to-moment facts, so they
    -- survive: a client that has stopped reporting is exactly when they matter.
    lu.assertEquals(said.loaded, "commands=table")
end

function TestAbout:test_a_client_that_has_never_said_anything()
    local said = DevBridge.about(nil, nil)
    lu.assertFalse(said.reporting)
    lu.assertNil(said.visible)
end

-- ------------------------------------------------ before the city has opened

--- The city is read and seeded on a thread after this handler is up. Measured
--- on the legacy server: a journey made a character, asked for the map and was
--- told there was nothing on it, and the console said the city had not been
--- read yet -- while the same run, a few seconds on, was handed six places.

TestDevBridgeGate = {}

function TestDevBridgeGate:test_nothing_that_acts_is_answered_before_the_city_opens()
    for _, route in ipairs({ "/do", "/act" }) do
        local status, refusal = DevBridge.gate(route, false)
        lu.assertNotNil(status, route .. " was let through to a city that is not open")
        lu.assertFalse(refusal.ok)
        lu.assertEquals(refusal.code, "not_open")
        -- The code is for a rig. The reason is for whoever reads its report.
        lu.assertStrContains(refusal.why, "/state")
    end
end

function TestDevBridgeGate:test_each_route_refuses_the_way_it_already_says_no()
    -- A reader of /do takes anything but a 200 as a bridge that did not
    -- answer, and this bridge did answer.
    lu.assertEquals((DevBridge.gate("/do", false)), 200)
    -- A reader of /act takes a 200 as done, and this is not done.
    lu.assertEquals((DevBridge.gate("/act", false)), 503)
end

function TestDevBridgeGate:test_what_only_reads_answers_while_the_city_is_shut()
    -- /state is how anybody finds out the city is not open, so it cannot be
    -- the thing that waits for it.
    for _, route in ipairs({ "/state", "/", "/log" }) do
        lu.assertNil(DevBridge.gate(route, false), route .. " was refused while the city opened")
    end
end

function TestDevBridgeGate:test_once_the_city_is_open_the_gate_stands_aside()
    for _, route in ipairs({ "/do", "/act", "/state", "/log", "/nonsense" }) do
        lu.assertNil(DevBridge.gate(route, true), route .. " was refused in an open city")
    end
end

function TestDevBridgeGate:test_a_route_nobody_has_called_a_read_waits_for_the_city()
    -- The list is of what may answer. A route added tomorrow that acts is safe
    -- the day it is written, rather than the day somebody notices.
    local status, refusal = DevBridge.gate("/reset", false)
    lu.assertEquals(status, 503)
    lu.assertEquals(refusal.code, "not_open")
end

function TestDevBridgeGate:test_a_gate_told_nothing_has_not_been_told_yes()
    -- nil is "nobody said". Nobody saying the city is open is not the city
    -- being open, and reading it as open is the whole defect again.
    lu.assertNotNil(DevBridge.gate("/do", nil))
    lu.assertNotNil(DevBridge.gate("/act", nil))
end

-- --------------------------------------- the gate, where requests arrive

--- `DevBridge.gate` deciding correctly is half of it. The other half is the
--- handler asking it, before every route, with the predicate it was given --
--- and a gate nobody calls passes every spec above. So `install` is run here
--- against stubbed natives and a world that records what it was asked to run,
--- and requests go through the handler it registers.

--- The natives `install` reaches for. Put back by name after each test rather
--- than with `pairs` over what was saved: `pairs` skips a native that was nil,
--- which would leave it stubbed for every spec that runs after this one.
local NATIVES = { "GetConvar", "RegisterNetEvent", "AddEventHandler", "SetHttpHandler",
                  "CreateThread", "GetPlayers", "GetPlayerIdentifierByType",
                  "GetPlayerEndpoint", "GetPlayerName", "GetGameTimer",
                  "TriggerClientEvent", "json" }

TestDevBridgeInstalled = {}

function TestDevBridgeInstalled:setUp()
    self.saved = {}
    for _, name in ipairs(NATIVES) do self.saved[name] = _G[name] end
    self.handler = nil
    self.dispatched, self.sent, self.logged = {}, {}, {}

    _G.GetConvar = function(name, default)
        if name == "sv_lan" then return "true" end
        return default
    end
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function() end
    _G.SetHttpHandler = function(fn) self.handler = fn end
    -- Kept, not started: the one thread `install` starts prints where it is.
    _G.CreateThread = function() end
    _G.GetPlayers = function() return { "1" } end
    _G.GetPlayerIdentifierByType = function() return nil end
    _G.GetPlayerEndpoint = function() return "127.0.0.1:50000" end
    _G.GetPlayerName = function() return "somebody" end
    _G.GetGameTimer = function() return 0 end
    _G.TriggerClientEvent = function(name, to, what)
        self.sent[#self.sent + 1] = { name = name, to = to, what = what }
    end
    _G.json = require("support.json")
end

function TestDevBridgeInstalled:tearDown()
    for _, name in ipairs(NATIVES) do _G[name] = self.saved[name] end
end

--- What `server.lua` passes: the predicate, and somewhere to say a refusal.
function TestDevBridgeInstalled:gated(ready)
    return { ready = ready, on_log = function(line) self.logged[#self.logged + 1] = line end }
end

--- Enough of a city for the bridge to answer every route, recording what it
--- was asked to run. A test that wants a route to go wrong bends this first.
function TestDevBridgeInstalled:world()
    local dispatched = self.dispatched
    local function clean() return { verify = function() return true, {} end } end
    return {
        services = { inventory = clean(), record = clean(), standing = clean() },
        clock = { describe = function() return "day 0 monday 08:00" end },
        commands = {
            names = function() return { "character.create", "me.status" } end,
            describe = function(_, name)
                return { name = name, summary = "",
                         args = { { name = "first_name", type = "string", required = true } } }
            end,
        },
        repository = function() return { load = function() return nil end } end,
        dispatch = function(_, name, args, meta)
            dispatched[#dispatched + 1] = { name = name, args = args, meta = meta }
            return { ok = true, code = "ok", value = { ran = name } }
        end,
        verify = function() return true, {} end,
        summary = function() return { accounts = 1, errors = 0 } end,
        errors = function() return { { at = 1, message = "boom", source = "tick" } } end,
        notices = function() return {} end,
        audit = function() return {} end,
    }
end

--- Install the bridge with `opts` and hand back a way to send it a request.
function TestDevBridgeInstalled:bridge(opts, world)
    world = world or self:world()
    DevBridge.install(world, { Character = {} }, opts)
    lu.assertNotNil(self.handler, "install registered no HTTP handler")
    -- From this machine unless a test says otherwise: the bridge answers
    -- nobody else (see test_the_bridge_answers_this_machine_and_nobody_else).
    return function(path, address)
        local answer = {}
        self.handler({ path = path, address = address or "127.0.0.1:50001" }, {
            writeHead = function(status) answer.status = status end,
            send = function(text) answer.body = json.decode(text) end,
        })
        return answer
    end
end

function TestDevBridgeInstalled:test_a_command_sent_before_the_city_opens_runs_nothing()
    local open = false
    local get = self:bridge(self:gated(function() return open end))

    local early = get("/do?p=1&c=character.create&a=%7B%7D")
    lu.assertEquals(early.status, 200)
    lu.assertFalse(early.body.ok)
    lu.assertEquals(early.body.code, "not_open")
    lu.assertEquals(#self.dispatched, 0, "a command ran against a city that had not opened")

    -- Asked afresh each time, not once at install: the city opens after that.
    open = true
    local later = get("/do?p=1&c=character.create&a=%7B%7D")
    lu.assertTrue(later.body.ok)
    lu.assertEquals(#self.dispatched, 1)
    lu.assertEquals(self.dispatched[1].name, "character.create")
end

function TestDevBridgeInstalled:test_nothing_is_sent_to_a_client_before_the_city_opens()
    local open = false
    local get = self:bridge(self:gated(function() return open end))

    local early = get("/act?p=1&show=pockets")
    lu.assertEquals(early.status, 503)
    lu.assertEquals(early.body.code, "not_open")
    lu.assertEquals(self.sent, {}, "an instruction reached a client before the city opened")

    open = true
    lu.assertEquals(get("/act?p=1&show=pockets").status, 200)
    lu.assertEquals(#self.sent, 1)
end

function TestDevBridgeInstalled:test_state_answers_while_the_city_opens_and_says_whether_it_has()
    -- A predicate that answers nothing, which a bare `return ready()` would
    -- pass on as a field JSON leaves out.
    local open = nil
    local get = self:bridge(self:gated(function() return open end))

    local shut = get("/state")
    lu.assertEquals(shut.status, 200)
    -- False, not absent. A driver reads a missing field as an older bridge and
    -- starts walking, which is the defect this field is here to end.
    lu.assertNotNil(shut.body.open, "/state said nothing about whether the city is open")
    lu.assertFalse(shut.body.open)
    lu.assertEquals(self.logged, {}, "a read was reported as refused")

    open = true
    lu.assertTrue(get("/state").body.open)
end

function TestDevBridgeInstalled:test_a_refusal_is_said_in_the_log_with_what_was_asked()
    -- The console is where the order of a request and the city opening can be
    -- read afterwards, and a refusal that says nothing there is the kind that
    -- cost the client bridge an afternoon.
    local get = self:bridge(self:gated(function() return false end))
    get("/do?p=1&c=me.map&a=%7B%7D")
    lu.assertEquals(#self.logged, 1)
    lu.assertStrContains(self.logged[1], "me.map")
    lu.assertStrContains(self.logged[1], "before the city was open")
end

function TestDevBridgeInstalled:test_a_bridge_installed_without_a_gate_answers_as_it_always_did()
    local get = self:bridge(nil)
    lu.assertTrue(get("/do?p=1&c=me.status&a=%7B%7D").body.ok)
    lu.assertEquals(#self.dispatched, 1)
    lu.assertTrue(get("/state").body.open)
end

function TestDevBridgeInstalled:test_the_server_puts_both_doors_behind_the_same_gate()
    -- `server.lua` is FiveM from its first line and cannot be loaded here, so
    -- it is read. The gate is only as good as the predicate it is handed, and
    -- installed with none the bridge is open from the moment the resource is.
    --
    -- Each call is read as its own balanced parentheses. Read up to the next
    -- `})` instead, a dev bridge installed with no options at all ran on into
    -- the client bridge's call and found that one's gate: the first draft of
    -- this test passed with the gate removed, and a mutation caught it.
    local text = assert(io.open("adapter/server.lua")):read("a")
    local dev = text:match("\nDevBridge%.install(%b())")
    local client = text:match("\nBridge%.attach(%b())")
    lu.assertNotNil(dev, "server.lua does not install the dev bridge")
    lu.assertNotNil(client, "server.lua does not attach the client bridge")
    lu.assertStrContains(dev, "ready = is_open")
    lu.assertStrContains(client, "ready = is_open")
end

-- ------------------------------------------------- the log, drained by number
--
-- Forty lines is what a person reads. A rig that asks every few seconds
-- wants every line, in order, and to be told when it has missed some --
-- because the line about a save failing is the kind that scrolls.

TestDevBridgeLog = {}

function TestDevBridgeLog:test_since_hands_back_only_what_is_newer_and_counts_what_is_gone()
    local kept = { { n = 101, said = "a" }, { n = 102, said = "b" }, { n = 103, said = "c" } }
    local page = DevBridge.since(kept, "101")
    lu.assertEquals(#page.log, 2)
    lu.assertEquals(page.log[1].n, 102)
    lu.assertEquals(page.seq, 103)
    lu.assertEquals(page.dropped, 0)
    -- Asked from 50, with 101 the oldest kept: lines 51 to 100 are gone, and
    -- the reader is told exactly how many rather than handed a gap in silence.
    local late = DevBridge.since(kept, "50")
    lu.assertEquals(late.dropped, 50)
    lu.assertEquals(#late.log, 3)
    -- Asked from the newest: an empty page, no loss, the same number back.
    local none = DevBridge.since(kept, "103")
    lu.assertEquals(none.log, {})
    lu.assertEquals(none.dropped, 0)
    lu.assertEquals(none.seq, 103)
    -- Nothing kept at all is an empty page from zero, not an error.
    local empty = DevBridge.since({}, "0")
    lu.assertEquals(empty.log, {})
    lu.assertEquals(empty.dropped, 0)
    lu.assertEquals(empty.seq, 0)
end

function TestDevBridgeLog:test_since_refuses_anything_that_is_not_a_line_number()
    for _, junk in ipairs({ "abc", "", "-1", "1.5", "1e999" }) do
        local page, why = DevBridge.since({ { n = 1, said = "a" } }, junk)
        lu.assertNil(page, ("since=%s was answered"):format(junk))
        lu.assertStrContains(why, "since=")
    end
    lu.assertNil(DevBridge.since({}, nil))
end

function TestDevBridgeLog:test_the_tail_is_the_last_few_oldest_first()
    lu.assertEquals(DevBridge.tail({ 1, 2, 3 }, 2), { 2, 3 })
    lu.assertEquals(DevBridge.tail({ 1 }, 40), { 1 })
    lu.assertEquals(DevBridge.tail({}, 40), {})
end

function TestDevBridgeInstalled:test_the_log_can_be_drained_by_number_without_losing_a_line()
    local get = self:bridge(nil)
    DevBridge.remember("one")
    DevBridge.remember("two")
    local all = get("/log?since=0")
    lu.assertEquals(all.status, 200)
    local last = all.body.log[#all.body.log]
    lu.assertEquals(last.said, "two")
    lu.assertEquals(last.n, all.body.seq)
    lu.assertEquals(all.body.log[#all.body.log - 1].said, "one")

    DevBridge.remember("three")
    local rest = get("/log?since=" .. all.body.seq)
    lu.assertEquals(#rest.body.log, 1)
    lu.assertEquals(rest.body.log[1].said, "three")
    lu.assertEquals(rest.body.dropped, 0)
    -- Nothing new is an empty page and the same number back, not an error.
    lu.assertEquals(get("/log?since=" .. rest.body.seq).body.log, {})
    -- Junk is refused as junk.
    for _, junk in ipairs({ "abc", "-1", "1.5", "1e999" }) do
        lu.assertEquals(get("/log?since=" .. junk).status, 400, junk)
    end
    -- A bare /log is still the tail it always was, and says where it ends.
    local bare = get("/log")
    lu.assertNotNil(bare.body.log)
    lu.assertEquals(bare.body.seq, rest.body.seq)
    lu.assertTrue(#bare.body.log <= DevBridge.LOG_LINES)
end

-- -------------------------------------------------- every check the city has
--
-- `nyr verify` on the console ran the books, the ownership register, every
-- entity, the stock and the record. A rig could not ask for any of it, so a
-- step that passed and left the books off by a dollar passed.

TestDevBridgeVerify = {}

local function city()
    local function clean() return { verify = function() return true, {} end } end
    return {
        services = { inventory = clean(), record = clean(), standing = clean() },
        verify = function() return true, {} end,
    }
end

function TestDevBridgeVerify:test_a_clean_city_is_clean_and_says_what_it_checked()
    local verdict = DevBridge.verify_of(city())
    lu.assertTrue(verdict.ok)
    lu.assertEquals(verdict.problems, {})
    lu.assertEquals(verdict.checked, { "world", "inventory", "record", "standing" })
    lu.assertEquals(verdict.missing, {})
end

function TestDevBridgeVerify:test_every_problem_is_named_with_where_it_was_found()
    local world = city()
    world.verify = function() return false, { "the books are off by $1.00" } end
    world.services.record.verify = function() return false, { "rec_1 appears twice" } end
    local verdict = DevBridge.verify_of(world)
    lu.assertFalse(verdict.ok)
    lu.assertEquals(verdict.problems, {
        { where = "world", problem = "the books are off by $1.00" },
        { where = "record", problem = "rec_1 appears twice" },
    })
end

function TestDevBridgeVerify:test_a_check_that_throws_is_a_problem_and_the_rest_still_run()
    local world = city()
    world.services.inventory.verify = function() error("attempt to index a nil value", 0) end
    world.services.standing.verify = function() return false, { "x with y is 999, outside 0..100" } end
    local verdict = DevBridge.verify_of(world)
    lu.assertFalse(verdict.ok)
    lu.assertEquals(#verdict.problems, 2)
    lu.assertEquals(verdict.problems[1].where, "inventory")
    lu.assertStrContains(verdict.problems[1].problem, "the check itself failed")
    lu.assertStrContains(verdict.problems[1].problem, "nil value")
    lu.assertEquals(verdict.problems[2].where, "standing")
end

function TestDevBridgeVerify:test_a_no_with_no_reason_is_still_a_no()
    local world = city()
    world.verify = function() return false end
    local verdict = DevBridge.verify_of(world)
    lu.assertFalse(verdict.ok)
    lu.assertStrContains(verdict.problems[1].problem, "without saying why")
    -- And only the boolean true is a yes.
    world.verify = function() return 1 end
    lu.assertFalse(DevBridge.verify_of(world).ok)
end

function TestDevBridgeVerify:test_a_verifier_the_city_does_not_have_is_named_not_skipped_in_silence()
    local world = city()
    world.services.standing = nil
    local verdict = DevBridge.verify_of(world)
    lu.assertTrue(verdict.ok)
    lu.assertEquals(verdict.missing, { "standing" })
    lu.assertEquals(verdict.checked, { "world", "inventory", "record" })
end

function TestDevBridgeInstalled:test_verify_waits_for_the_city_and_then_answers_with_the_summary()
    local open = false
    local get = self:bridge(self:gated(function() return open end))
    -- A verdict on a city that has not been read is a verdict on nothing.
    lu.assertEquals(get("/verify").status, 503)
    open = true
    local said = get("/verify")
    lu.assertEquals(said.status, 200)
    lu.assertTrue(said.body.ok)
    lu.assertEquals(said.body.checked, { "world", "inventory", "record", "standing" })
    lu.assertEquals(said.body.summary.accounts, 1)
end

function TestDevBridgeInstalled:test_errors_and_commands_answer_while_the_city_is_still_shut()
    -- A city that failed to open is the moment its errors are worth reading.
    local get = self:bridge(self:gated(function() return false end))
    local said = get("/errors?limit=5")
    lu.assertEquals(said.status, 200)
    lu.assertEquals(said.body.errors[1].message, "boom")
    lu.assertNotNil(said.body.notices)
    lu.assertNotNil(said.body.audit)
    local listed = get("/commands")
    lu.assertEquals(listed.status, 200)
    lu.assertEquals(listed.body.commands[1].name, "character.create")
    lu.assertEquals(listed.body.commands[1].args[1].type, "string")
    lu.assertTrue(#listed.body.allowed > 0)
    lu.assertEquals(self.logged, {}, "a read was reported as refused")
end

-- --------------------------------------- what a request cannot take down
--
-- A route that throws used to be a request that was never answered. From a
-- rig that reads exactly like a server that has died, and the two are found
-- out in very different ways.

function TestDevBridgeInstalled:test_a_route_that_throws_is_answered_500_and_said_in_the_log()
    local world = self:world()
    world.commands.names = function() error("the command bus is gone", 0) end
    local get = self:bridge(self:gated(function() return true end), world)
    local said = get("/commands")
    lu.assertEquals(said.status, 500)
    lu.assertFalse(said.body.ok)
    lu.assertEquals(said.body.code, "bridge_failed")
    lu.assertStrContains(said.body.why, "the command bus is gone")
    lu.assertEquals(#self.logged, 1)
    lu.assertStrContains(self.logged[1], "/commands")
    -- And the next request is answered as though nothing happened.
    lu.assertEquals(get("/state").status, 200)
end

function TestDevBridgeInstalled:test_state_survives_a_player_the_natives_will_not_describe()
    -- A player leaving in the middle of a snapshot is a thing a game does.
    _G.GetPlayers = function() return { "1", "2" } end
    _G.GetPlayerName = function(id)
        if id == "2" then error("player 2 has gone", 0) end
        return "somebody"
    end
    local get = self:bridge(nil)
    local said = get("/state")
    lu.assertEquals(said.status, 200)
    lu.assertEquals(#said.body.players, 2)
    lu.assertEquals(said.body.players[1].name, "somebody")
    lu.assertEquals(said.body.players[2].id, 2)
    lu.assertStrContains(said.body.players[2].trouble, "player 2 has gone")
    -- What a rig compares before and after a step, and where the log is up to.
    lu.assertEquals(said.body.summary.accounts, 1)
    lu.assertNotNil(said.body.seq)
    lu.assertTrue(#said.body.log <= DevBridge.LOG_LINES)
end

function TestDevBridgeInstalled:test_do_refuses_a_player_and_arguments_that_are_not_ones()
    local get = self:bridge(nil)
    for _, p in ipairs({ "abc", "-1", "0", "1.5", "1e999" }) do
        lu.assertEquals(get("/do?p=" .. p .. "&c=me.status&a=%7B%7D").status, 400, "p=" .. p)
    end
    -- 5, "x" and {{{ are each something a client can send; none is a request.
    for _, a in ipairs({ "5", "%22x%22", "%7B%7B%7B" }) do
        lu.assertEquals(get("/do?p=1&c=me.status&a=" .. a).status, 400, "a=" .. a)
    end
    lu.assertEquals(#self.dispatched, 0, "junk reached the command bus")
    -- No arguments at all is still no arguments.
    lu.assertTrue(get("/do?p=1&c=me.status&a=").body.ok)
    lu.assertTrue(get("/do?p=1&c=me.status").body.ok)
    lu.assertEquals(#self.dispatched, 2)
    lu.assertEquals(self.dispatched[1].args, {})
end

function TestDevBridgeInstalled:test_the_bridge_answers_this_machine_and_nobody_else()
    -- Measured before: with sv_lan true a request from 198.51.100.23 read every
    -- player's license and wallet off /state, and /do released a session.
    local get = self:bridge(self:gated(function() return true end))
    lu.assertEquals(get("/state").status, 200)
    lu.assertEquals(get("/state", "[::1]:40000").status, 200)
    for _, stranger in ipairs({ "198.51.100.23:40000", "192.168.1.20:40000", "", nil }) do
        local address = stranger
        local answer = {}
        self.handler({ path = "/state", address = address }, {
            writeHead = function(status) answer.status = status end,
            send = function(text) answer.body = text end,
        })
        lu.assertEquals(answer.status, 404, "the bridge answered " .. tostring(address))
        lu.assertEquals(answer.body, "")
    end
    lu.assertEquals(get("/do?p=1&c=character.release&a=%7B%7D", "198.51.100.23:40000").status, 404)
    lu.assertEquals(#self.dispatched, 0, "a stranger ran a command")
    lu.assertTrue(#self.logged >= 1 and #self.logged <= 5, "a turned-away request was not said, or said without end")
end

function TestDevBridgeInstalled:test_a_server_taken_out_of_lan_mode_closes_the_bridge_at_once()
    local lan = "true"
    _G.GetConvar = function(name, default)
        if name == "sv_lan" then return lan end
        return default
    end
    local get = self:bridge(nil)
    lu.assertEquals(get("/state").status, 200)
    lan = "false"
    lu.assertEquals(get("/state").status, 404, "sv_lan false left the bridge open")
    lu.assertEquals(get("/do?p=1&c=me.status&a=%7B%7D").status, 404)
    lu.assertEquals(#self.dispatched, 0)
end

function TestDevBridgeInstalled:test_do_asks_about_the_player_it_checked()
    -- `p=1.0` passed the check as player 1 and was then looked up as the text
    -- "1.0", which matched nobody: it acted as the account nobody holds.
    _G.GetPlayers = function() return { "1" } end
    _G.GetPlayerIdentifierByType = function(id, kind)
        if tostring(id) == "1" and kind == "license" then return "license:abc" end
        return nil
    end
    local get = self:bridge(nil)
    for _, p in ipairs({ "1", "1.0", "01", "%2B1", "0x1" }) do
        lu.assertTrue(get("/do?p=" .. p .. "&c=me.status&a=%7B%7D").body.ok, "p=" .. p)
        lu.assertEquals(self.dispatched[#self.dispatched].meta.account, "license:abc", "p=" .. p)
    end
end

function TestDevBridgeInstalled:test_an_encoded_plus_arrives_as_a_plus()
    local args = DevBridge.query_of("/do?a=%7B%22to%22%3A%22%2B15550100%22%7D&b=a+b")
    lu.assertEquals(args.a, '{"to":"+15550100"}')
    lu.assertEquals(args.b, "a b")
end

function TestDevBridgeInstalled:test_do_for_a_player_who_is_not_here_asks_no_native_about_them()
    -- Found by the storm on the Enhanced server: GetPlayerIdentifierByType
    -- throws for an id nobody holds, and /do?p=99999 was a request with no
    -- answer. The natives are asked about connected players only; anybody
    -- else is the account nobody is connected as.
    _G.GetPlayers = function() return { "1" } end
    _G.GetPlayerIdentifierByType = function(id)
        if tostring(id) ~= "1" then error('Expected an numeric client id as a argument.', 0) end
        return "license:abc"
    end
    _G.GetPlayerEndpoint = function(id)
        if tostring(id) ~= "1" then error("no such player", 0) end
        return "127.0.0.1:50000"
    end
    local get = self:bridge(nil)
    local absent = get("/do?p=99999&c=me.status&a=%7B%7D")
    lu.assertEquals(absent.status, 200)
    lu.assertTrue(absent.body.ok)
    lu.assertEquals(self.dispatched[1].meta.account, "dev:local")
    -- And a player who is here is still who the natives say they are.
    lu.assertTrue(get("/do?p=1&c=me.status&a=%7B%7D").body.ok)
    lu.assertEquals(self.dispatched[2].meta.account, "license:abc")
    lu.assertEquals(self.logged, {}, "a well-formed request was reported as trouble")
end

function TestBoolish:test_a_number_a_client_sends_is_finite_or_it_is_nothing()
    -- `tonumber("1e999")` is infinity, and a snapshot with an infinity in it
    -- cannot be encoded as JSON: every /state for the next eight seconds
    -- would have answered 500 for one report.
    DevBridge.report(12, { hp = "1e999", model = 0 / 0, pos = string.rep("x", 500), marked = "1e999" })
    local kept = DevBridge.seen(12)
    lu.assertNil(kept.hp)
    lu.assertNil(kept.model)
    lu.assertNil(kept.marked)
    lu.assertEquals(#kept.pos, 60)
    DevBridge.report(13, { hp = 200, model = "1885233650", pos = "1, 2, 3" })
    lu.assertEquals(DevBridge.seen(13).hp, 200)
    lu.assertEquals(DevBridge.seen(13).model, 1885233650)
    lu.assertEquals(DevBridge.seen(13).pos, "1, 2, 3")
    lu.assertNil(DevBridge.number("abc"))
    lu.assertNil(DevBridge.number(nil))
end

function TestBoolish:test_what_a_client_says_threw_is_kept_bounded()
    lu.assertNil(DevBridge.errors_of(nil))
    lu.assertNil(DevBridge.errors_of("boom"))
    lu.assertNil(DevBridge.errors_of({}))
    lu.assertEquals(DevBridge.errors_of({ "#1 a: b" }), { "#1 a: b" })
    local many = {}
    for i = 1, 40 do many[i] = "#" .. i end
    local kept = DevBridge.errors_of(many)
    lu.assertEquals(#kept, 24)
    lu.assertEquals(kept[1], "#17")
    lu.assertEquals(kept[24], "#40")
    lu.assertEquals(#DevBridge.errors_of({ string.rep("x", 1000) })[1], 300)
    DevBridge.report(9, { errors = many })
    lu.assertEquals(#DevBridge.seen(9).errors, 24)
end

-- ------------------------------------ and the client, whatever a native does

function TestDevClientReports:test_what_threw_is_numbered_so_a_repeat_is_not_the_same_line()
    local handlers, calls, report_once = load_devclient()
    handlers["nyr:dev:on"]()
    calls.keep_error("dev:act", "no screen called x")
    calls.keep_error("dev:act", "no screen called x")
    lu.assertEquals(report_once().errors,
        { "#1 dev:act: no screen called x", "#2 dev:act: no screen called x" })
end

function TestDevClientReports:test_a_native_that_throws_does_not_end_the_reporting()
    -- A client that has stopped reporting looks, from outside, exactly like
    -- one that was never armed. What threw goes into the report instead.
    local handlers, calls, report_once = load_devclient({
        GetEntityHealth = function() error("GetEntityHealth: invalid entity", 0) end,
    })
    handlers["nyr:dev:on"]()
    local body = report_once()
    lu.assertEquals(#calls.errors, 1)
    lu.assertStrContains(calls.errors[1], "invalid entity")
    lu.assertNotNil(body.loaded, "the report that survived said nothing about what loaded")
    -- And the lap after it reports again.
    report_once()
    lu.assertEquals(#calls.errors, 2)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
