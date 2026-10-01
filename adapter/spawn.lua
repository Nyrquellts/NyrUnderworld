--- Somewhere to stand.
--
-- A FiveM client joins into nothing. There is no ped, no camera and no ground
-- until something puts them there, and the loading screen stays up forever
-- until something takes it down. Most servers get this from `spawnmanager`,
-- which ships with the Legacy server and does **not** ship with the Enhanced
-- one, so a resource that relies on it works on one and shows a black screen on
-- the other.
--
-- This is the black screen, fixed. It asks the game for nothing clever: a
-- freemode ped, a known corner of Los Santos, the loading screen down and the
-- fade up. Every native here long predates the Legacy/Enhanced split.
--
-- The city itself does not care where anybody is standing. Position is a
-- client-side fact the server reads when it needs proximity, and nothing in the
-- simulation is decided from it.

local MODEL = "mp_m_freemode_01"

-- How long a body is held where it was put, waiting for the ground under it.
--
-- This used to let go first and then wait three seconds at most, and on
-- 2026-09-13 all three joins to the Enhanced server fell through the map: z 30
-- at the spawn, z 1 a few seconds later, and once z -57 behind the character
-- picker. A player waits on the loading screen for as long as this takes, which
-- is better than arriving underneath the city.
local GROUND_WAIT_MS = 20000

local READY_EVENT = "nyr:spawned"

local function load_model(name)
    local model = GetHashKey(name)
    if not IsModelInCdimage(model) or not IsModelValid(model) then
        return nil
    end
    RequestModel(model)
    -- Bounded: a model that never arrives must not hang the client forever.
    for _ = 1, 200 do
        if HasModelLoaded(model) then return model end
        Wait(50)
    end
    return nil
end

--- Hold on until the ground under `ped` has loaded, or the wait runs out.
--- Returns whether the ground arrived.
local function wait_for_ground(ped, at)
    local began = GetGameTimer()
    local elapsed = 0
    while elapsed >= 0 and elapsed < GROUND_WAIT_MS do
        -- A request is for the streaming going on now, not a standing order,
        -- so it is made again every frame until the answer is yes.
        RequestCollisionAtCoord(at.x, at.y, at.z)
        if HasCollisionLoadedAroundEntity(ped) then return true end
        Wait(0)
        elapsed = GetGameTimer() - began
    end
    return false
end

--- Put the body at `at` alive: held, placed, resurrected, the ground waited for,
--- then let go.
---
--- The join does this once. A body killed in the world needs it again, and a
--- second routine written for that would be a second thing to fall through the
--- map, so both go through this one. `dress` is for the join only: a model just
--- set has no clothes at all, and a body standing up again has its own.
local function stand(at, dress)
    local lease = NyrWorldSuspend and NyrWorldSuspend()
    if NyrWorldSuspend and not lease then
        print("[nyr] another relocation is still in progress")
        return false
    end
    local ped
    local ok, ground_ready = pcall(function()
        ped = PlayerPedId()
        -- Hold the body before moving it over ground that may not exist yet.
        FreezeEntityPosition(ped, true)
        RequestCollisionAtCoord(at.x, at.y, at.z)
        SetEntityCoordsNoOffset(ped, at.x, at.y, at.z, false, false, false)
        SetEntityHeading(ped, at.heading)
        NetworkResurrectLocalPlayer(at.x, at.y, at.z, at.heading, true, false)
        -- Resurrection may replace the ped; never reuse the old handle.
        ped = PlayerPedId()
        FreezeEntityPosition(ped, true)
        ClearPedTasksImmediately(ped)
        if dress then SetPedDefaultComponentVariation(ped) end
        SetEntityVisible(ped, true, false)
        SetPlayerInvincible(PlayerId(), false)
        local loaded = wait_for_ground(ped, at)
        if not loaded then
            print(("[nyr] the ground at %.0f, %.0f had not loaded after %d seconds; letting the player go anyway")
                :format(at.x, at.y, GROUND_WAIT_MS // 1000))
        end
        if not NyrWorldLeaseCurrent or NyrWorldLeaseCurrent(lease) then
            SetEntityCoordsNoOffset(ped, at.x, at.y, at.z, false, false, false)
            SetEntityHeading(ped, at.heading)
        end
        return loaded
    end)
    -- Cleanup also runs if a native throws after yielding or fails to unfreeze.
    if ped then pcall(FreezeEntityPosition, ped, false) end
    if NyrWorldRelease then pcall(NyrWorldRelease, lease) end
    if not ok then print("[nyr] body relocation failed: " .. tostring(ground_ready)); return false end
    return ground_ready
end

--- Stand the body up again: "here", where it lies, or "spawn". `done` is called
--- once it is up, or once it is plain that nothing will be.
---
--- Where is decided in `NyrClientState.stand_at`, where a spec reads it; when
--- is decided in client.lua from what the server says.
function NyrStand(where, done)
    CreateThread(function()
        local ok, why = pcall(function()
            local ped = PlayerPedId()
            local at = NyrClientState.stand_at(where, GetEntityCoords(ped), GetEntityHeading(ped))
            if at then stand(at, false)
            else print(("[nyr] nowhere called %s to stand the body up"):format(tostring(where))) end
        end)
        if not ok then print("[nyr] body relocation failed: " .. tostring(why)) end
        if done then pcall(done) end
    end)
end

CreateThread(function()
    -- Nothing below works until the session exists.
    local session_began = GetGameTimer()
    while not NetworkIsSessionStarted() do
        local elapsed = GetGameTimer() - session_began
        if elapsed < 0 or elapsed >= 60000 then
            print("[nyr] the network session did not arrive; world requests remain gated")
            return
        end
        Wait(100)
    end

    -- A restart of this resource starts this script again under players who
    -- are already standing in the city, and it used to spawn every one of them
    -- again. Which case this is, is decided in client_state.
    if NyrClientState.arrival(GetIsLoadingScreenActive(), DoesEntityExist(PlayerPedId())) == "announce" then
        TriggerEvent(READY_EVENT)
        return
    end

    local model = load_model(MODEL)
    if model then
        SetPlayerModel(PlayerId(), model)
        -- Changing the model destroys the old ped and makes a new one, and the
        -- new one does not exist until the next frame. Reading PlayerPedId()
        -- before that hands back a handle to something on its way out, and
        -- every native below would then be dressing a corpse.
        Wait(0)
        SetModelAsNoLongerNeeded(model)
    end

    stand(NyrClientState.SPAWN, true)

    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    DoScreenFadeIn(500)

    TriggerEvent(READY_EVENT)
end)
