-- The spawn, with the game's natives stubbed so the order of the calls can be read.
--
-- Measured before this spec existed, on 2026-09-13, with a real FiveM client
-- on the Enhanced server: all three joins that day put the body at Legion
-- Square at z 30 and within seconds it reported z 1 and 2, and on the third
-- z -57, falling under the map behind the character picker. The file let go of
-- the body before it waited for the ground, and waited three seconds at most.
--
-- What these tests hold is the order: held, then placed, then the ground asked
-- for until it is there, and only then let go. They cannot show what the game
-- streams or how long it takes; a connected join is the proof of that.
local modname = ...
local lu = require("luaunit")

local SPAWN_Z = 30.69

--- Run adapter/spawn.lua once, against natives that write down what they were
--- asked. `ground_after_ms` is how much game time passes before the ground under
--- the current body counts as loaded; nil means it never does.
local function spawn(options)
    options = options or {}
    local log, clock = {}, 0
    local ped, next_ped = 100, 100
    local collision_checks, collision_requests = 0, 0
    local printed = {}

    local function note(entry) log[#log + 1] = entry end

    local sandbox = {}
    for _, name in ipairs({ "assert", "error", "ipairs", "math", "pairs", "pcall", "setmetatable",
                            "string", "table", "tonumber", "tostring", "type" }) do
        sandbox[name] = _G[name]
    end
    -- The game's Lua has vectors as a type of their own: `type()` of what
    -- GetEntityCoords returns is "vector3", not "table". A fake handing back a
    -- plain table would pass code that checks for a table and fails in the game.
    local VECTOR = {}
    local function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, VECTOR) end
    sandbox.type = function(value)
        if getmetatable(value) == VECTOR then return "vector3" end
        return type(value)
    end

    sandbox.CreateThread = function(fn) fn() end
    -- A frame is sixteen milliseconds; `Wait(0)` is one frame, not no time,
    -- or a loop bounded by the clock would never end.
    sandbox.Wait = function(ms) clock = clock + math.max(16, ms or 0) end
    sandbox.GetGameTimer = function() return clock end
    sandbox.NetworkIsSessionStarted = function() return true end
    -- Loaded into the same namespace, so it sees the game's `type` too.
    assert(loadfile("adapter/client_state.lua", "t", sandbox))()
    -- Where the body is, as the game would say: wherever it was last put.
    local position = { x = 0.0, y = 0.0, z = 0.0 }
    local heading = 0.0
    sandbox.GetEntityCoords = function() return vector3(position.x, position.y, position.z) end
    sandbox.GetEntityHeading = function() return heading end
    sandbox.DoesEntityExist = function() return options.body ~= false end
    -- A join arrives behind the loading screen; a script restarted under a
    -- player already in the city does not.
    sandbox.GetIsLoadingScreenActive = function() return options.loading ~= false end

    sandbox.GetHashKey = function() return 1885233650 end
    sandbox.IsModelInCdimage = function() return true end
    sandbox.IsModelValid = function() return true end
    sandbox.RequestModel = function() end
    sandbox.HasModelLoaded = function() return true end
    sandbox.SetModelAsNoLongerNeeded = function() end
    sandbox.PlayerId = function() return 0 end
    sandbox.SetPlayerModel = function() note({ "model" }) end

    sandbox.PlayerPedId = function() return ped end
    -- Less polite than the game may be: a resurrection here always hands the
    -- player a different ped, so a handle carried across it is a handle to
    -- nothing, and anything done to it shows up below as done to the wrong body.
    sandbox.NetworkResurrectLocalPlayer = function(x, y, z)
        next_ped = ped + 1
        ped = next_ped
        note({ "resurrect", z = z })
    end

    sandbox.SetPedDefaultComponentVariation = function(p) note({ "dress", ped = p }) end
    sandbox.FreezeEntityPosition = function(p, frozen) note({ "freeze", ped = p, frozen = frozen }) end
    sandbox.SetEntityCoordsNoOffset = function(p, x, y, z)
        position = { x = x, y = y, z = z }
        note({ "place", ped = p, x = x, y = y, z = z })
    end
    sandbox.SetEntityHeading = function(_, h) heading = h end
    sandbox.ClearPedTasksImmediately = function() end
    sandbox.SetEntityVisible = function(p, visible) note({ "visible", ped = p, visible = visible }) end
    sandbox.SetPlayerInvincible = function() end
    sandbox.RequestCollisionAtCoord = function() collision_requests = collision_requests + 1 end
    sandbox.HasCollisionLoadedAroundEntity = function(p)
        collision_checks = collision_checks + 1
        local loaded = p == ped and options.ground_after_ms ~= nil and clock >= options.ground_after_ms
        if loaded then note({ "ground", ped = p, at = clock }) end
        return loaded
    end
    sandbox.ShutdownLoadingScreen = function() note({ "loading down", at = clock }) end
    sandbox.ShutdownLoadingScreenNui = function() end
    sandbox.DoScreenFadeIn = function() note({ "fade in", at = clock }) end
    sandbox.TriggerEvent = function(name) note({ "event", name = name }) end
    sandbox.print = function(line) printed[#printed + 1] = tostring(line) end

    assert(loadfile("adapter/spawn.lua", "t", sandbox))()

    return {
        log = log, clock = clock, ped = ped, printed = printed,
        collision_checks = collision_checks, collision_requests = collision_requests,
        sandbox = sandbox,
        -- For what happens after the join: the body moved somewhere by the
        -- world, as a fall or a fight would leave it.
        lay = function(x, y, z, h) position = { x = x, y = y, z = z }; heading = h or 0.0 end,
        now_ped = function() return ped end,
    }
end

local function index_of(log, pred, from)
    for i = from or 1, #log do
        if pred(log[i]) then return i end
    end
    return nil
end

local function let_go(entry) return entry[1] == "freeze" and entry.frozen == false end

TestSpawn = {}

function TestSpawn:test_a_native_failure_always_releases_the_readiness_lease()
    local run = spawn({ ground_after_ms = 0, loading = false })
    local gate, _, sample = require("spec.readiness_harness")(run.sandbox)
    run.sandbox.FreezeEntityPosition = function() error("native failed") end
    local completed = 0
    run.sandbox.NyrStand("spawn", function() completed = completed + 1 end)
    sample()
    lu.assertEquals(completed, 1); lu.assertFalse(gate.blocked); lu.assertTrue(gate.ready)
end
function TestSpawn:test_signed_timer_wrap_exits_collision_wait_and_releases_lease()
    local run = spawn({ ground_after_ms = 0, loading = false })
    local now, waits = 2147483640, 0
    local gate = require("spec.readiness_harness")(run.sandbox, { now = function() return now end })
    run.sandbox.HasCollisionLoadedAroundEntity = function() return false end
    run.sandbox.Wait = function() waits = waits + 1; assert(waits < 4, "rollover hung collision wait"); now = -2147483640 end
    run.sandbox.NyrStand("spawn")
    lu.assertEquals(waits, 1); lu.assertFalse(gate.blocked)
end

function TestSpawn:test_the_body_is_not_let_go_until_the_ground_under_it_has_loaded()
    -- Five seconds: longer than the three the file used to give it.
    local run = spawn({ ground_after_ms = 5000 })
    local ground = index_of(run.log, function(e) return e[1] == "ground" end)
    lu.assertNotNil(ground, "the ground was never seen to load")
    local released = index_of(run.log, let_go)
    lu.assertNotNil(released, "the body was never let go")
    lu.assertTrue(released > ground,
        "the body was let go before the ground under it had loaded, which is how it fell through the map")
    -- And nothing let it go earlier than that, to be caught again later.
    lu.assertEquals(index_of(run.log, let_go), released)
end

function TestSpawn:test_the_body_is_held_before_it_is_put_anywhere()
    local run = spawn({ ground_after_ms = 0 })
    local placed = index_of(run.log, function(e) return e[1] == "place" end)
    local held = index_of(run.log, function(e) return e[1] == "freeze" and e.frozen == true end)
    lu.assertNotNil(held, "the body was never held")
    lu.assertTrue(held < placed, "the body was put in the air before anything held it there")
end

function TestSpawn:test_the_ground_is_asked_for_again_while_waiting_for_it()
    local run = spawn({ ground_after_ms = 2000 })
    -- A request is streaming asked for now, not a standing order.
    lu.assertTrue(run.collision_requests > 10,
        ("the ground was asked for %d time(s) across two seconds of waiting"):format(run.collision_requests))
end

function TestSpawn:test_what_is_held_and_let_go_is_the_body_the_game_has_after_resurrection()
    local run = spawn({ ground_after_ms = 1000 })
    local resurrected = index_of(run.log, function(e) return e[1] == "resurrect" end)
    lu.assertNotNil(resurrected)
    local released = index_of(run.log, let_go)
    lu.assertEquals(run.log[released].ped, run.ped,
        "the body let go was a handle from before resurrection, not the player's ped")
    local held_after = index_of(run.log, function(e) return e[1] == "freeze" and e.frozen == true end, resurrected)
    lu.assertNotNil(held_after, "nothing held the body the game had after resurrection")
    lu.assertEquals(run.log[held_after].ped, run.ped)
    local dressed_after = index_of(run.log, function(e) return e[1] == "dress" end, resurrected)
    lu.assertNotNil(dressed_after, "the body after resurrection was never dressed, and an undressed freemode ped draws as nothing")
    lu.assertEquals(run.log[dressed_after].ped, run.ped)
end

function TestSpawn:test_the_loading_screen_stays_up_while_the_body_waits()
    local run = spawn({ ground_after_ms = 4000 })
    local down = index_of(run.log, function(e) return e[1] == "loading down" end)
    local ground = index_of(run.log, function(e) return e[1] == "ground" end)
    lu.assertTrue(down > ground, "the loading screen came down while the body was still waiting for ground")
end

function TestSpawn:test_it_is_put_back_where_it_stands_once_the_ground_is_there()
    local run = spawn({ ground_after_ms = 3000 })
    local ground = index_of(run.log, function(e) return e[1] == "ground" end)
    local placed_after = index_of(run.log, function(e) return e[1] == "place" end, ground)
    lu.assertNotNil(placed_after, "nothing put the body back at the spawn once there was ground to stand on")
    lu.assertEquals(run.log[placed_after].z, SPAWN_Z)
    lu.assertTrue(placed_after < index_of(run.log, let_go))
end

function TestSpawn:test_ground_that_never_loads_does_not_hold_a_player_forever_and_says_so()
    local run = spawn({ ground_after_ms = nil })
    lu.assertNotNil(index_of(run.log, let_go), "a player whose ground never loaded was left frozen")
    lu.assertNotNil(index_of(run.log, function(e) return e[1] == "loading down" end),
        "a player whose ground never loaded was left on the loading screen")
    lu.assertTrue(run.clock <= 60000, ("the wait ran %d ms of game time"):format(run.clock))
    lu.assertTrue(run.clock >= 10000, ("the wait gave up after %d ms, which a cold load can outlast"):format(run.clock))
    lu.assertEquals(#run.printed, 1, "letting go without ground has to be said, once")
    lu.assertStrContains(run.printed[1], "ground")
end

function TestSpawn:test_the_rest_of_the_spawn_still_happens_and_ends_in_the_ready_event()
    local run = spawn({ ground_after_ms = 0 })
    local visible = index_of(run.log, function(e) return e[1] == "visible" and e.visible == true end)
    lu.assertNotNil(visible, "the body was not made visible")
    lu.assertEquals(run.log[visible].ped, run.ped)
    lu.assertNotNil(index_of(run.log, function(e) return e[1] == "fade in" end))
    lu.assertEquals(run.log[#run.log][1], "event")
    lu.assertEquals(run.log[#run.log].name, "nyr:spawned")
end

-- ------------------------------------------------------------- a restart

--- `restart nyr_underworld` starts every client script again for everybody
--- connected, and the spawn ran whenever its script started: every player in
--- the city was given a new model, moved to Legion Square and frozen for as long
--- as the ground took, in the middle of whatever they were doing. Read, not run:
--- nobody has restarted the resource under a connected client to watch it.
TestRestart = {}

local function did(run, what)
    return index_of(run.log, function(e) return e[1] == what end) ~= nil
end

function TestRestart:test_a_restart_leaves_a_body_already_in_the_city_where_it_is()
    local run = spawn({ ground_after_ms = 0, loading = false })
    lu.assertFalse(did(run, "model"), "a restart changed the model of a player standing in the city")
    lu.assertFalse(did(run, "resurrect"), "a restart respawned a player standing in the city")
    lu.assertFalse(did(run, "place"), "a restart moved a player standing in the city")
    lu.assertFalse(did(run, "freeze"), "a restart froze a player standing in the city")
    -- Still announced, because the map and the picker wait for it.
    lu.assertEquals(run.log[#run.log][1], "event")
    lu.assertEquals(run.log[#run.log].name, "nyr:spawned")
end

function TestRestart:test_a_join_is_still_a_spawn()
    local run = spawn({ ground_after_ms = 0, loading = true })
    lu.assertTrue(did(run, "model"))
    lu.assertTrue(did(run, "resurrect"))
    lu.assertEquals(run.log[#run.log].name, "nyr:spawned")
end

function TestRestart:test_a_restart_with_no_body_still_makes_one()
    local run = spawn({ ground_after_ms = 0, loading = false, body = false })
    lu.assertTrue(did(run, "resurrect"), "a player with no body was left with none")
end

-- ------------------------------------------------------------- standing up

--- The body was resurrected once, at the join, and never again. On a server with
--- no spawnmanager -- every Enhanced server -- a player killed in the world stayed
--- a corpse through `/nyrrespawn` and through a medic's revive: the server's
--- numbers changed and nothing on the client did. The join's own routine -- held,
--- placed, resurrected, the ground waited for, let go -- is what stands a body
--- up again, and these hold that it is the same routine and not a second one.
---
--- What these cannot show is the game: whether a resurrected ped gets up, what
--- the camera does, or how the death looked. That needs a connected client.
TestStandingUp = {}

local function after_the_join()
    local run = spawn({ ground_after_ms = 0 })
    return run, #run.log + 1
end

function TestStandingUp:test_a_body_stood_up_here_is_resurrected_where_it_lies()
    local run, from = after_the_join()
    run.lay(412.0, -980.5, 29.4, 90.0)
    local finished = false
    run.sandbox.NyrStand("here", function() finished = true end)
    local resurrected = index_of(run.log, function(e) return e[1] == "resurrect" end, from)
    lu.assertNotNil(resurrected, "nothing resurrected the body")
    lu.assertEquals(run.log[resurrected].z, 29.4, "the body was not stood up where it lay")
    local held = index_of(run.log, function(e) return e[1] == "freeze" and e.frozen == true end, from)
    lu.assertNotNil(held)
    lu.assertTrue(held < resurrected, "the body was moved before anything held it")
    local released = index_of(run.log, let_go, from)
    lu.assertNotNil(released, "a body stood up was left frozen")
    lu.assertTrue(released > resurrected)
    lu.assertEquals(run.log[released].ped, run.now_ped(), "what was let go was the body from before")
    lu.assertTrue(finished, "whoever asked was never told the body is up")
end

function TestStandingUp:test_a_body_stood_up_at_the_spawn_goes_to_the_spawn()
    local run, from = after_the_join()
    run.lay(412.0, -980.5, 29.4, 90.0)
    run.sandbox.NyrStand("spawn")
    local resurrected = index_of(run.log, function(e) return e[1] == "resurrect" end, from)
    lu.assertNotNil(resurrected)
    lu.assertEquals(run.log[resurrected].z, SPAWN_Z)
    local placed = index_of(run.log, function(e) return e[1] == "place" end, resurrected)
    lu.assertNotNil(placed, "the body was not put back once the ground was there")
    lu.assertEquals(run.log[placed].z, SPAWN_Z)
end

function TestStandingUp:test_standing_up_is_not_a_join()
    local run, from = after_the_join()
    run.sandbox.NyrStand("here")
    lu.assertNil(index_of(run.log, function(e) return e[1] == "event" end, from),
        "standing up announced a spawn, which opens the picker and reads the map again")
    lu.assertNil(index_of(run.log, function(e) return e[1] == "loading down" end, from))
    lu.assertNil(index_of(run.log, function(e) return e[1] == "model" end, from),
        "standing up changed the model, which makes a new body")
    lu.assertNil(index_of(run.log, function(e) return e[1] == "dress" end, from),
        "standing up undressed the body back to the default")
end

function TestStandingUp:test_a_place_nobody_named_stands_nothing_up_and_says_so()
    local run, from = after_the_join()
    local finished = false
    run.sandbox.NyrStand("the moon", function() finished = true end)
    lu.assertNil(index_of(run.log, function(e) return e[1] == "resurrect" end, from))
    lu.assertTrue(finished, "a stand that did nothing never finished, so the next could never start")
    lu.assertStrContains(run.printed[#run.printed] or "", "the moon")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
