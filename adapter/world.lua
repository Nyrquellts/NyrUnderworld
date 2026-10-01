--- Marks on the map, lights on the ground, and one key that opens the thing.
--
-- This resource drew none of these. There were no blips, no markers, no help
-- prompts and no interaction key anywhere in it, so a player could only find a
-- shop by already knowing its coordinates and pressing F5 while standing on it.
-- Every system behind that was correct and unreachable, which is the defect this
-- whole project keeps rediscovering under different names.
--
-- What to draw is decided in `adapter/client_state.lua`, where a spec can reach
-- it: which kind gets which blip, what the prompt says, which screen the key
-- opens, and how near is near enough. What is here is the natives, and the two
-- threads that call them.
--
-- The two threads matter as much as the drawing:
--
--   one is slow and finds the nearest place, because walking a list of every
--   door in the city every frame is how a resource costs a server its frames;
--
--   one draws, and only while there is something within sight. With nothing
--   near it waits half a second at a time rather than taking a slice of every
--   frame for the life of the resource.
--
-- The map was asked for once, when the player spawned, on the reasoning that it
-- changes when the city is seeded and almost never again. A door changes every
-- time it is bought or put up for sale, and a flat sold kept its mark and its
-- price on everybody's screen. It is asked for on spawn, again soon after this
-- client buys or lists a door, and now and then for what others did -- when is
-- `NyrClientState.map_due`, which keeps well under what `me.map` allows.

local NEAR = NyrClientState.NEAR
local MAP_CHECK_MS = 1000

local places = {}          -- what the server said is in the city
local blips = {}           -- what we put on the map, so it can be taken off
local closest = nil        -- the one place worth drawing, or none
local prompting = nil      -- the help line on screen right now, or none
local spawned = false      -- nothing is read before there is somebody to read it for
local asked_at = nil       -- when the map was last asked for
local wanted = false       -- something this client did changed the map
local marked = false       -- whether any answer has been drawn

--- What this client has actually put in front of a player, for the development
--- bridge to read. A map with no marks on it looks exactly like a city with
--- nothing in it, and a prompt that never appears looks exactly like a player
--- who has not walked far enough -- so neither is left to somebody's eyes.
function NyrWorldMarked() return #blips end
function NyrWorldPrompt() return prompting end

--- What E opens at a place: the counter at a shop, the bank at a branch, Around
--- you at a door. Returns whether it opened anything.
local function press(place)
    local screen, which = NyrClientState.opens(place)
    if screen == "shop" and which then
        NyrShopOpen(which)
        return true
    elseif screen == "bank" and which then
        NyrBankOpen(which)
        return true
    elseif screen == "nearby" then
        NyrNearbyOpen()
        return true
    end
    return false
end

--- E, for the development bridge: the same `press` the key calls, and only where
--- the key would do something -- standing close enough that the prompt is up.
function NyrWorldPress()
    if not prompting or not closest then return false end
    return press(closest)
end

--- Put the city on the map.
local function mark(found)
    for _, blip in ipairs(blips) do RemoveBlip(blip) end
    blips, places = {}, found or {}

    for _, place in ipairs(places) do
        local wanted = NyrClientState.blip(place)
        if wanted then
            local blip = AddBlipForCoord(place.x + 0.0, place.y + 0.0, place.z + 0.0)
            SetBlipSprite(blip, wanted.sprite)
            SetBlipColour(blip, wanted.colour)
            SetBlipScale(blip, 0.8)
            -- Short range: a map covered in marks from every corner of the
            -- island tells somebody nothing about where they are.
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(wanted.label)
            EndTextCommandSetBlipName(blip)
            blips[#blips + 1] = blip
        end
    end
end

--- Ask the server where everything is.
local function read_map()
    asked_at, wanted = GetGameTimer(), false
    NyrAsk("me.map", {}, function(outcome)
        if type(outcome) == "table" and outcome.ok and type(outcome.value) == "table" then
            mark(outcome.value.places)
            marked = true
        else
            -- Said out loud, and what was marked stays marked: a read refused
            -- for being asked too often is not a city that emptied. A city with
            -- no marks on it looks exactly like a city with nothing in it, and
            -- that is the failure this file exists to stop being invisible.
            print("[nyr] the map could not be read, so it was not redrawn: "
                .. tostring(NyrClientState.say(outcome)))
        end
    end)
end

--- Something this client did changed the map: a door bought, or put up for
--- sale. Read again once the gap allows, not at once.
function NyrWorldRefresh()
    wanted = true
end

-- First on spawn, which is before anybody has picked who to be: `me.map`
-- answers a player who is nobody yet for exactly that reason. There used to be
-- a second read here, on an event meant to arrive when somebody was selected.
-- Nothing ever sent it, so the only read was the spawn one, and while the map
-- refused anybody not playing, that read was refused for every player there was.
AddEventHandler("nyr:spawned", function()
    spawned = true
    if NyrClientState.map_due(GetGameTimer(), asked_at, wanted, marked) then read_map() end
end)

CreateThread(function()
    while true do
        Wait(MAP_CHECK_MS)
        if spawned and NyrClientState.map_due(GetGameTimer(), asked_at, wanted, marked) then
            read_map()
        end
    end
end)

-- ----------------------------------------------------------- what is near

CreateThread(function()
    while true do
        Wait(500)
        local ped = PlayerPedId()
        if ped ~= 0 and DoesEntityExist(ped) and #places > 0 then
            local here = GetEntityCoords(ped)
            local nearest, best = nil, NEAR.draw * NEAR.draw
            for _, place in ipairs(places) do
                -- Squared, because a square root per door per half second buys
                -- nothing: the comparison is the same either way.
                local dx, dy, dz = here.x - place.x, here.y - place.y, here.z - place.z
                local away = dx * dx + dy * dy + dz * dz
                if away < best and NyrClientState.marker(place) then
                    nearest, best = place, away
                end
            end
            closest = nearest
        else
            closest = nil
        end
    end
end)

-- --------------------------------------------------------------- drawing

CreateThread(function()
    while true do
        local place = closest
        if not place then
            -- Nothing in sight, so nothing to draw. Half a second at a time
            -- rather than a slice of every frame for the life of the resource.
            prompting = nil
            Wait(500)
        else
            local marker = NyrClientState.marker(place)
            DrawMarker(1, place.x + 0.0, place.y + 0.0, place.z - 0.95,
                       0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                       1.2, 1.2, marker.height,
                       marker.colour[1], marker.colour[2], marker.colour[3], 120,
                       false, false, 2, false, nil, nil, false)

            local ped = PlayerPedId()
            local here = GetEntityCoords(ped)
            local dx, dy, dz = here.x - place.x, here.y - place.y, here.z - place.z
            local within = (dx * dx + dy * dy + dz * dz) <= (NEAR.act * NEAR.act)

            -- A prompt only within reach, and only where something is behind it.
            local prompt = nil
            if within then prompt = NyrClientState.prompt(place) end
            prompting = prompt
            if prompt then
                BeginTextCommandDisplayHelp("STRING")
                AddTextComponentSubstringPlayerName(prompt)
                EndTextCommandDisplayHelp(0, false, true, -1)
                -- 38 is INPUT_CONTEXT, which is E on a keyboard and the
                -- key every FiveM server already teaches its players.
                if IsControlJustReleased(0, 38) then
                    press(place)
                end
            end
            Wait(0)
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- A resource that stops leaving its blips behind leaves them on the map
    -- until the game restarts, and restarting a resource is a thing that
    -- happens on a live server all day.
    for _, blip in ipairs(blips) do RemoveBlip(blip) end
    blips, places, closest, prompting = {}, {}, nil, nil
end)
