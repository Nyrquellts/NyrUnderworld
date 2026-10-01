--- The client half of the window, which only opens when the server asks.
--
-- It says what is actually on this machine's screen: whether there is a body,
-- whether the interface is up, what line it is showing, and anything that
-- threw. Without this, finding out why a player is looking at a black screen
-- means asking the player.
--
-- It does nothing at all until a LAN server sends `nyr:dev:on`. A public server
-- never sends it, so on a real server this file is inert.
--
-- It also takes instructions, on the same condition: `nyr:dev:act` opens a
-- screen or moves the body. That is how a session gets driven and recorded
-- without somebody at the keyboard, and it is the same reason the read half
-- exists -- finding out what is on screen should not mean asking a person.

local EVERY_MS = 2000
local KEEP_ERRORS = 12

local on = false
local errors = {}
-- How many things have thrown, ever. Each kept line carries its number, so a
-- reader that sees the list twice can tell a new error from the last one
-- said again -- the same reason `did` below is numbered.
local thrown = 0
-- The last instruction this half actually carried out, so that "sent to the
-- client" and "the client did it" stop being the same claim read twice.
local did = nil
-- Numbered, so the same key pressed twice leaves two different last words. A
-- journey reads `did` changing as the proof that a press arrived, and without
-- the number a second press of one key is indistinguishable from the first.
local done = 0

--- Anything that threw, kept so it can be read from outside the game.
function NyrDevError(where, message)
    thrown = thrown + 1
    errors[#errors + 1] = ("#%d %s: %s"):format(thrown, tostring(where), tostring(message))
    while #errors > KEEP_ERRORS do table.remove(errors, 1) end
end

--- Which halves of this client actually loaded. A file that throws while
--- loading registers nothing and says nothing, and from outside that is
--- indistinguishable from a client that is fine and simply never asked for
--- anything.
local function loaded()
    return ("commands=%s ask=%s nui=%s state=%s open=%s"):format(
        type(NyrCommands), type(NyrAsk), type(NyrNuiState),
        type(NyrClientState), type(NyrPocketsOpen))
end

--- What this client can say about itself right now. Every native it asks is
--- one the game may answer strangely or not at all, which is why the loop
--- below calls this through pcall rather than trusting it.
local function measure()
    local ped = PlayerPedId()
    local alive = ped and ped ~= 0 and DoesEntityExist(ped)
    local position = nil
    if alive then
        local where = GetEntityCoords(ped)
        position = ("%.0f, %.0f, %.0f"):format(where.x, where.y, where.z)
    end
    -- What this client has actually registered, which is the only
    -- honest answer to "is that command there". Asking a person to
    -- type it and believing the answer cost an afternoon: there was no
    -- chat resource on that server, so there was nowhere to type and
    -- nowhere for a reply to go, and nobody could tell.
    local registered = nil
    if GetRegisteredCommands then
        local names = {}
        for _, entry in ipairs(GetRegisteredCommands()) do
            local name = entry.name or entry[1]
            if type(name) == "string" and name:sub(1, 3) == "nyr" then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        registered = table.concat(names, " ")
    end

    -- What the world layer has drawn: marks on the map and the prompt
    -- on screen. Natives draw both and nothing else can see them, so a
    -- city whose map was never read looked, from outside, exactly like
    -- a city that had been. Written out rather than `f and f() or nil`:
    -- a count of nothing has to arrive as 0, not as "did not say".
    local marked, prompt = nil, nil
    if NyrWorldMarked then marked = NyrWorldMarked() end
    if NyrWorldPrompt then prompt = NyrWorldPrompt() end

    return {
        did = did,
        registered = registered,
        loaded = loaded(),
        spawned = alive and not IsScreenFadedOut(),
        -- Whether there is a body to look at. A ped can be alive, at
        -- the right coordinates and undrawn, and nothing else here
        -- would say so -- which cost a session to find out from a
        -- person instead of from the bridge.
        visible = alive and IsEntityVisible(ped) or false,
        -- `dressed` was here: `GetNumberOfPedDrawableVariations(ped, 3)
        -- ~= nil`, against a native that answers a number and never
        -- nil, so it was true for every ped that has ever existed. It
        -- was the backup for `visible`, and between them they could not
        -- have told a drawn player from an undrawn one.
        model = alive and GetEntityModel(ped) or nil,
        nui = NyrPickerIsOpen and NyrPickerIsOpen() or false,
        hp = alive and GetEntityHealth(ped) or nil,
        pos = position,
        showing = NyrPickerShowing and NyrPickerShowing() or nil,
        marked = marked,
        prompt = prompt,
        errors = #errors > 0 and errors or nil,
    }
end

RegisterNetEvent("nyr:dev:on")
AddEventHandler("nyr:dev:on", function()
    if on then return end
    on = true

    CreateThread(function()
        while on do
            Wait(EVERY_MS)
            -- A native that throws must not take the reporting down with it.
            -- A client that has stopped reporting looks, from outside, exactly
            -- like one that was never armed, and the one line that would have
            -- said why is the line that never got sent. So what threw goes
            -- into the report, and the report still goes.
            local measured, body = pcall(measure)
            if not measured then
                NyrDevError("dev:report", body)
                body = { did = did, loaded = loaded(), errors = errors }
            end
            TriggerServerEvent("nyr:dev:report", body)
        end
    end)
end)

-- ------------------------------------------------------------------ acting

--- Open a screen, or put the body somewhere, on a LAN server's say-so.
---
--- Every screen is opened through the same function its key press calls, so
--- nothing here is a second way in: what is recorded is what a player sees.
local SCREENS = {
    picker = function() if NyrPickerOpen then NyrPickerOpen() end end,
    pockets = function() if NyrPocketsOpen then NyrPocketsOpen() end end,
    phone = function() if NyrPhoneOpen then NyrPhoneOpen() end end,
    nearby = function() if NyrNearbyOpen then NyrNearbyOpen() end end,
    -- A bank needs to know which branch, so it is not driveable by name
    -- alone: `/act run=` presses the key, and E at the marker names one.
    jobs = function() if NyrJobsOpen then NyrJobsOpen() end end,
    close = function() if NyrPickerClose then NyrPickerClose() end end,
}

--- A number that is a number: not a string, not nil, not NaN, not infinite.
--- This arrives from off this machine, so none of that is given.
local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

RegisterNetEvent("nyr:dev:act")
local function perform(what)
    -- `on` is only ever true because a LAN server said so. Without this, a
    -- public server that somehow triggered the event could move a player.
    if not on or type(what) ~= "table" then return end

    -- All of it is read and checked before any of it happens. Moving the body
    -- and only then finding out the screen name was wrong leaves a player
    -- standing somewhere nobody asked for, with nothing on screen to say why.
    --
    -- The server decides what is well formed and a spec holds it to that, so
    -- this is the second check rather than the first. It is here because of
    -- what the failure looks like without it: a native handed a coordinate that
    -- is not a finite number throws or misplaces the body inside the pcall
    -- below, and a body that quietly did not move reads exactly like a screen
    -- that quietly did not open. Refusing by name puts the reason where /state
    -- can show it.
    local show = nil
    if what.show ~= nil then
        if type(what.show) ~= "string" or not SCREENS[what.show] then
            NyrDevError("dev:act", ("no screen called %s"):format(tostring(what.show)))
            return
        end
        show = what.show
    end

    local at, heading = nil, nil
    if what.at ~= nil then
        if type(what.at) ~= "table" then
            NyrDevError("dev:act", "a move needs x, y and z, and this is not a position")
            return
        end
        if not (finite(what.at.x) and finite(what.at.y) and finite(what.at.z)) then
            NyrDevError("dev:act", "a move needs x, y and z, all finite numbers")
            return
        end
        at = { x = what.at.x + 0.0, y = what.at.y + 0.0, z = what.at.z + 0.0 }
        if what.heading ~= nil then
            if not finite(what.heading) then
                NyrDevError("dev:act", "a heading that is not a finite number")
                return
            end
            heading = what.heading + 0.0
        end
    elseif what.heading ~= nil then
        NyrDevError("dev:act", "a heading without a position turns nothing")
        return
    end

    if what.run ~= nil and type(what.run) ~= "string" then
        NyrDevError("dev:act", "a command to run that is not a name")
        return
    end

    -- A walk goes through the game's route finding, at a walk or a run.
    local walk, speed = nil, nil
    if what.walk ~= nil then
        if type(what.walk) ~= "table"
            or not (finite(what.walk.x) and finite(what.walk.y) and finite(what.walk.z)) then
            NyrDevError("dev:act", "a walk needs x, y and z, all finite numbers")
            return
        end
        local pace = what.pace == nil and "walk" or what.pace
        if pace ~= "walk" and pace ~= "run" then
            NyrDevError("dev:act", ("a walk at pace %s"):format(tostring(what.pace)))
            return
        end
        walk = { x = what.walk.x + 0.0, y = what.walk.y + 0.0, z = what.walk.z + 0.0 }
        speed = pace == "run" and 2.0 or 1.0
    end

    if what.press ~= nil and what.press ~= true then
        NyrDevError("dev:act", "press is true or not sent")
        return
    end

    if not show and not at and what.run == nil and not walk and not what.press then
        NyrDevError("dev:act", "nothing to do")
        return
    end

    local lease
    local revision = NyrWorldRevision and NyrWorldRevision()
    local ok, err = pcall(function()
        if walk and not at then
            local ped = PlayerPedId()
            if ped and ped ~= 0 then
                -- Stopping within 0.75 m: close enough to stand in a prompt's
                -- three metres, without circling the exact point.
                TaskFollowNavMeshToCoord(ped, walk.x, walk.y, walk.z, speed, -1, 0.75, false, 0.0)
                done = done + 1
                did = ("#%d walk to %.1f, %.1f, %.1f"):format(done, walk.x, walk.y, walk.z)
            end
        end
        if what.press and not at then
            done = done + 1
            local pressed = false
            if NyrWorldPress then pressed = NyrWorldPress() == true end
            if pressed then
                did = ("#%d press: opened"):format(done)
            else
                did = ("#%d press: nothing here to open"):format(done)
            end
        end
        if at then
            lease = NyrWorldSuspend and NyrWorldSuspend()
            if NyrWorldSuspend and not lease then error("another relocation is still in progress") end
            local ped = PlayerPedId()
            if ped and ped ~= 0 then
                if what.safe == true and GetSafeCoordForPed then
                    -- The nearest place a person can stand, as the game sees it;
                    -- where it finds none, the body goes where it was asked.
                    local found, ground = GetSafeCoordForPed(at.x, at.y, at.z, true, 16)
                    if found and ground and finite(ground.x) and finite(ground.y) and finite(ground.z) then
                        at = { x = ground.x + 0.0, y = ground.y + 0.0, z = ground.z + 0.0 }
                    end
                end
                SetEntityCoords(ped, at.x, at.y, at.z,
                                false, false, false, false)
                if heading then SetEntityHeading(ped, heading) end
                local began = GetGameTimer()
                local elapsed = 0
                while elapsed >= 0 and elapsed < 20000 do
                    RequestCollisionAtCoord(at.x, at.y, at.z)
                    if HasCollisionLoadedAroundEntity(ped) then break end
                    Wait(0)
                    elapsed = GetGameTimer() - began
                end
            end
            local current = not NyrWorldLeaseCurrent or NyrWorldLeaseCurrent(lease)
            if NyrWorldRelease then NyrWorldRelease(lease) end
            lease = nil
            if not current then NyrDevError("dev:act", "world changed during relocation"); return end
            -- A location's commands must wait for the next readiness samples.
            local follow = { show = what.show, run = what.run, walk = what.walk, pace = what.pace, press = what.press }
            if follow.show or follow.run or follow.walk or follow.press then
                if NyrWorldReady and not NyrWorldReady() then
                    NyrWhenWorldReady(function() perform(follow) end,
                        function(result) NyrDevError("dev:act", result.code) end)
                else perform(follow) end
            end
            return
        end
        if show then
            -- Close first: the screens are one page and opening a second over
            -- the first is what a key press would not do.
            if show ~= "close" and NyrPickerIsOpen and NyrPickerIsOpen() then
                SCREENS.close()
                Wait(60)
                if NyrWorldReady and (not NyrWorldReady() or NyrWorldRevision and NyrWorldRevision() ~= revision) then
                    NyrDevError("dev:act", "world changed while switching screens"); return
                end
            end
            SCREENS[show]()
        end
        if what.run then
            -- The same door a key press and a chat line go through. Whether
            -- the name is one this resource registers was decided on the
            -- server, in `act_plan`, where a spec can reach it.
            done = done + 1
            did = ("#%d run %s (ExecuteCommand %s)"):format(done, what.run, type(ExecuteCommand))
            ExecuteCommand(what.run)
            did = did .. " returned"
        end
    end)
    if not ok then
        if lease and NyrWorldRelease then NyrWorldRelease(lease) end
        NyrDevError("dev:act", err)
    end
end
AddEventHandler("nyr:dev:act", function(what)
    if not on or type(what) ~= "table" then return end
    if NyrWhenWorldReady then
        local copied, request = pcall(NyrReadiness.copy, what)
        if not copied then NyrDevError("dev:act", "invalid queued action"); return end
        NyrWhenWorldReady(function() perform(request) end,
            function(result) NyrDevError("dev:act", result.code) end)
    else
        NyrDevError("dev:act", "world readiness gate unavailable")
    end
end)

-- Say hello until the server answers, or until it is plainly not going to.
--
-- This half does nothing until it is armed, and the server used to arm it only
-- when somebody joined. Nobody joins on a resource restart, so a connected
-- client came back deaf and the rig looked broken from the outside: reporting
-- false, no position, and instructions going to nobody.
--
-- Asking is this half's job because this is the half that knows it has just
-- started. Ten tries and then it stops, because a server that has not answered
-- ten times is a public one, and a public server is meant never to answer.
CreateThread(function()
    for _ = 1, 10 do
        if on then return end
        TriggerServerEvent("nyr:dev:hello")
        Wait(1000)
    end
end)
