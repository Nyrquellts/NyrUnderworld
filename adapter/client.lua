--- The client half, which knows nothing and decides nothing.
--
-- It sends a request and shows the answer. It does not hold a balance, does
-- not work out whether something is affordable, does not know who owns what
-- and does not know what it is not allowed to do. Every one of those would be
-- a number or a branch a cheat can edit, and a rule enforced where it can be
-- edited is not a rule.
--
-- Every refusal is text to display, never a branch to act on. That is the
-- whole client-side discipline, and it is why this file is short.
--
-- It runs on both versions of the game. Nothing here is version-specific: chat
-- commands, a server event, a timer and a text draw, all of them natives that
-- long predate the split. There are no assets, no models and no map data.

local REQUEST_EVENT = "nyr:request"
local REPLY_EVENT = "nyr:outcome"
local HUD_EVERY_MS = 5000

-- Timers restart when a client reconnects. An independent session prefix keeps
-- honest new requests distinct from the server's durable payment receipts.
-- This is a correlation id, never authentication or an authorization secret.
local state = NyrClientState.new({ now = function() return GetGameTimer() end,
    session = ("%x-%x"):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) })
local showing_hud = true
local readiness = NyrReadiness.new({ now = function() return GetGameTimer() end,
    on_reset = function(outcome) state:cancel(outcome) end })

function NyrWorldReady() return readiness.ready end
function NyrWorldRevision() return readiness.generation end
function NyrWorldSuspend() return readiness:suspend() end
function NyrWorldRelease(lease) return readiness:release(lease) end
function NyrWorldLeaseCurrent(lease) return readiness:current(lease) end
function NyrWhenWorldReady(send, fail)
    fail = fail or function() end
    return readiness:submit(function(epoch, generation)
        -- A dev action may await streaming; never stall the readiness sampler.
        CreateThread(function()
            if readiness.ready and readiness.session == epoch and readiness.generation == generation then
                local ok = pcall(send, epoch, generation)
                if not ok then pcall(fail, { ok = false, code = "dispatch_failed" }) end
            else pcall(fail, { ok = false, code = "world_changed" }) end
        end)
    end, fail)
end

RegisterNetEvent("nyr:session")
AddEventHandler("nyr:session", function(epoch) readiness:set_session(epoch) end)
CreateThread(function()
    local hello, previous_ped = -5000, nil
    while true do
        Wait(100)
        local now, ped = GetGameTimer(), PlayerPedId()
        local network = NetworkIsSessionStarted()
        local exists = ped ~= 0 and DoesEntityExist(ped)
        if exists and previous_ped and previous_ped ~= ped then readiness:reset("body_changed") end
        previous_ped = exists and ped or nil
        readiness:observe({ network = network, ped = exists,
            collision = exists and HasCollisionLoadedAroundEntity(ped),
            loading = GetIsLoadingScreenActive(),
            switching = IsPlayerSwitchInProgress and IsPlayerSwitchInProgress() or false })
        if network and (now - hello >= 2000 or now < hello) then
            hello = now
            TriggerServerEvent("nyr:session:hello")
        end
    end
end)

-- The player's body: what the game says about it, what the server says about
-- its person, and whether it is being stood up. Decided in client_state.
local BODY_EVERY_MS = 1000
local body = NyrClientState.body({ now = function() return GetGameTimer() end })

-- ------------------------------------------------------------------ saying

--- Say one line to the player, somewhere they will actually see it.
---
--- This used to be the `chat:addMessage` line alone, which is another
--- resource's event: on a server with no chat resource every answer this
--- resource gives was dropped, and a command that worked looked exactly like a
--- command that did not exist. Which channels to use is decided in
--- `client_state`, where a spec can reach it; the natives are here.
local function tell(line)
    if not line or line == "" then return end
    local where = NyrClientState.channels(
        GetResourceState and GetResourceState("chat") or nil)

    if where.chat then
        TriggerEvent("chat:addMessage", { args = { "[nyr]", line } })
    end
    if where.notify then
        -- The game's own feed. It needs no other resource, which is the whole
        -- point of it being the fallback.
        BeginTextCommandThefeedPost("STRING")
        AddTextComponentSubstringPlayerName("[nyr] " .. line)
        EndTextCommandThefeedPostTicker(false, true)
    end
    if where.console then
        print("[nyr] " .. line)
    end
end

local function tell_lines(lines)
    for _, line in ipairs(lines) do tell(line) end
end

-- ----------------------------------------------------------------- asking

--- Ask the server to do something. `done` is called with the outcome summary.
--- The token only matches an answer to its question; the server namespaces it
--- by account before it means anything.
function NyrAsk(name, args, done)
    local token = state:token()
    local handler = done or function(outcome)
        tell(NyrClientState.say(outcome))
    end
    local settled = false
    local function finish(outcome)
        if settled then return end
        settled = true
        handler(outcome)
    end
    local copied, payload = pcall(NyrReadiness.copy, args or {})
    if not copied then
        finish({ ok = false, code = "invalid_arguments", message = "The request could not be queued." })
        return token
    end
    readiness:submit(function(epoch)
        state:open(token, finish)
        TriggerServerEvent(REQUEST_EVENT, name, payload, token, epoch)
    end, function(outcome)
        state:reply(token, outcome)
        finish(outcome)
    end)
    return token
end

RegisterNetEvent(REPLY_EVENT)
AddEventHandler(REPLY_EVENT, function(token, outcome)
    local handler = state:reply(token, outcome)
    if handler and type(outcome) == "table" and outcome.code == "stale_session" then
        readiness:reset("server_restarted")
        readiness.session = nil
    end
    if handler then handler(outcome) end
end)

-- Give up on anything that was never answered, and say so, rather than leaving
-- a player waiting on a reply that is not coming.
CreateThread(function()
    while true do
        Wait(1000)
        for _, lapsed in ipairs(state:expire()) do
            if lapsed.handler then lapsed.handler(lapsed.outcome) end
        end
    end
end)

-- ---------------------------------------------------------------- commands
--
-- The table itself lives in `adapter/commands.lua`, beside the names the key
-- mappings claim, because nothing here could see those and both files claimed
-- `nyrpockets`. What is left here is the registering.

local PlayerCommands = NyrCommands or require("adapter.commands")
local COMMANDS = PlayerCommands.TYPED

--- Stand the body up, where `where` says. The routine is adapter/spawn.lua's,
--- the same one the join uses, and it tells this file when the body is up.
local function stand(where)
    if not NyrStand then return end
    body:standing(true)
    NyrStand(where, function() body:standing(false) end)
end

-- What the typed words become, and what an answer says, are both decided where
-- a spec can read them: `Commands.args` and `ClientState.answer`. Both used to be
-- here, and every chat command that moves money sent dollars as cents and then
-- said "done".
for _, row in ipairs(COMMANDS) do
    local chat, command, spec = row[1], row[2], row[3]
    RegisterCommand(chat, function(_, words)
        local args, complaint = PlayerCommands.args(spec, words)
        if not args then
            tell(complaint)
            return
        end
        NyrAsk(command, args, function(outcome)
            local line = NyrClientState.say(outcome)
            if line then
                tell(line)
                return
            end
            state:remember(command, outcome.value)
            tell_lines(NyrClientState.answer(command, outcome.value, args))
            -- A respawn that worked was answered while the body lay where it
            -- fell, and nothing ever moved it; a door bought or listed stayed
            -- marked as it was on the map read at spawn.
            local follows = NyrClientState.follows(command, outcome)
            if follows.stand then stand(follows.stand) end
            if follows.map and NyrWorldRefresh then NyrWorldRefresh() end
        end)
    end, false)
end

RegisterCommand("nyrhelp", function()
    tell("chat commands, in groups:")
    local line, count = {}, 0
    for _, row in ipairs(COMMANDS) do
        line[#line + 1] = "/" .. row[1]
        count = count + 1
        if count % 8 == 0 then
            tell("  " .. table.concat(line, "  "))
            line = {}
        end
    end
    if #line > 0 then tell("  " .. table.concat(line, "  ")) end
end, false)

-- ---------------------------------------------------------------------- hud

RegisterCommand("nyrhud", function()
    showing_hud = not showing_hud
    tell(showing_hud and "hud on" or "hud off")
end, false)

-- Asks for the whole picture on a slow timer and draws the last answer every
-- frame. Drawing from a cache rather than asking every frame is the difference
-- between a display and a denial of service.
--
-- Asked while the body lies dead too, with the display off or on: it is the only
-- way a medic's revive reaches this machine. The server tells the medic, not the
-- person on the ground.
CreateThread(function()
    while true do
        Wait(HUD_EVERY_MS)
        if showing_hud or body:is_dead() then
            local asked_at = GetGameTimer()
            NyrAsk("me.status", {}, function(outcome)
                if not (outcome and outcome.ok) then return end
                state:remember("me.status", outcome.value)
                local condition = type(outcome.value) == "table" and outcome.value.condition or nil
                local where = body:said(condition, asked_at)
                if where then stand(where) end
            end)
        end
    end
end)

-- The body, once a second. A player lying dead is told what is happening and
-- what they can do about it, rather than left looking at a corpse.
CreateThread(function()
    while true do
        Wait(BODY_EVERY_MS)
        local ped = PlayerPedId()
        local dead = ped ~= 0 and DoesEntityExist(ped) and IsEntityDead(ped)
        local line = body:seen(dead == true)
        if line then tell(line) end
    end
end)

-- Drawing has to happen every frame, but only while there is something to
-- draw. With the display off, or before the first answer has arrived, this
-- idles at two ticks a second instead of taking a slice of every frame for the
-- life of the resource. A thread that waits 0 forever is a thread that costs a
-- server owner frames they never agreed to spend.
CreateThread(function()
    while true do
        local status = showing_hud and state:view("me.status")
        local text = status and NyrClientState.hud(status) or ""
        if text ~= "" then
            -- Where is decided in client_state, where a spec can read it.
            local at = NyrClientState.HUD_AT
            SetTextFont(4)
            SetTextScale(0.34, 0.34)
            SetTextColour(235, 235, 235, 220)
            SetTextOutline()
            SetTextCentre(at.centre)
            SetTextEntry("STRING")
            AddTextComponentString(text)
            DrawText(at.x, at.y)
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then readiness:stop() end
    if name == GetCurrentResourceName() then state:forget() end
end)
