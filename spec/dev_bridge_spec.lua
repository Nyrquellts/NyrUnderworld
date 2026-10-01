-- Actual development adapters with mocked FiveM transport and natives.
-- These tests prove routing and refusal, not a player's native view or position.
local modname = ...
local lu = require("luaunit")
local json = require("support.json")

local function server(lan)
    local harness = { sent = {} }
    local env = setmetatable({
        GetConvar = function() return lan and "true" or "false" end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        SetHttpHandler = function(handler) harness.handler = handler end,
        TriggerClientEvent = function(name, player, body)
            harness.sent[#harness.sent + 1] = { name = name, player = player, body = body }
        end,
        GetPlayers = function() return { "1", "2" } end,
        GetCurrentResourceName = function() return "fixture" end,
        -- Every server has these; install prints its address from a thread.
        CreateThread = function() end,
        GetConvarInt = function(_, fallback) return fallback end,
        print = function() end,
        json = json,
    }, { __index = _G })
    assert(loadfile("adapter/devbridge.lua", "t", env))().install({}, {})
    function harness:request(path)
        local status, body
        self.handler({ path = path, address = "127.0.0.1:50001" }, {
            writeHead = function(code) status = code end,
            send = function(text) body = assert(json.decode(text)) end,
        })
        return status, body
    end
    return harness
end

TestDevActionServer = {}
function TestDevActionServer:setUp() self.bridge = server(true) end
function TestDevActionServer:test_public_server_installs_no_http_handler()
    lu.assertNil(server(false).handler)
end
-- With one client connected the bridge acts on that client when p is left out
-- (spec/devbridge_spec.lua holds that). With several it will not guess.
function TestDevActionServer:test_with_several_connected_the_target_must_be_named()
    lu.assertEquals(self.bridge:request("/act?show=pockets"), 400)
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_invalid_targets_never_broadcast_or_send()
    for _, player in ipairs({ "-1", "0", "1.5", "nope", "1e309", "99999999999999999999" }) do
        lu.assertEquals(self.bridge:request("/act?p=" .. player .. "&show=pockets"), 400)
    end
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_disconnected_target_is_not_reported_as_sent()
    lu.assertEquals(self.bridge:request("/act?p=99&show=pockets"), 404)
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_complete_finite_position_is_required()
    for _, query in ipairs({ "x=1", "x=1&y=2", "x=bad&y=2&z=3", "x=1e309&y=2&z=3" }) do
        lu.assertEquals(self.bridge:request("/act?p=1&show=pockets&" .. query), 400)
    end
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_unknown_screen_rejects_the_entire_action()
    lu.assertEquals(self.bridge:request("/act?p=1&show=typo&x=1&y=2&z=3"), 400)
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_heading_requires_position_and_must_be_finite()
    for _, query in ipairs({ "show=pockets&h=90", "x=1&y=2&z=3&h=bad", "x=1&y=2&z=3&h=1e309" }) do
        lu.assertEquals(self.bridge:request("/act?p=1&" .. query), 400)
    end
    lu.assertEquals(self.bridge.sent, {})
end
function TestDevActionServer:test_valid_actions_send_to_one_numeric_target()
    for _, screen in ipairs({ "picker", "pockets", "phone", "nearby", "close" }) do
        local code, body = self.bridge:request("/act?p=1&show=" .. screen)
        lu.assertEquals(code, 200)
        lu.assertTrue(body.ok)
        lu.assertEquals(body.to, 1)
        lu.assertEquals(self.bridge.sent[#self.bridge.sent].player, 1)
    end
    lu.assertEquals(self.bridge:request("/act?p=2&x=-5&y=10&z=25&h=90"), 200)
    local sent = self.bridge.sent[#self.bridge.sent]
    lu.assertEquals(sent.name, "nyr:dev:act")
    lu.assertEquals(sent.player, 2)
    lu.assertEquals(sent.body.at, { x = -5, y = 10, z = 25 })
    lu.assertEquals(sent.body.heading, 90)
end

local function client()
    local harness = { events = {}, calls = {}, open = false }
    local function call(name, ...) harness.calls[#harness.calls + 1] = { name, ... } end
    local env = setmetatable({
        RegisterNetEvent = function() end,
        AddEventHandler = function(name, handler) harness.events[name] = handler end,
        CreateThread = function() end,
        Wait = function(ms) call("wait", ms) end,
        PlayerPedId = function() return 42 end,
        SetEntityCoords = function(ped, x, y, z) call("move", ped, x, y, z) end,
        SetEntityHeading = function(ped, heading) call("heading", ped, heading) end,
        NyrPickerIsOpen = function() return harness.open end,
        NyrPickerClose = function() harness.open = false; call("close") end,
    }, { __index = _G })
    for name, screen in pairs({ NyrPickerOpen = "picker", NyrPocketsOpen = "pockets", NyrPhoneOpen = "phone", NyrNearbyOpen = "nearby" }) do
        env[name] = function() harness.open = true; call(screen) end
    end
    harness.gate, harness.facts, harness.sample = require("spec.readiness_harness")(env)
    assert(loadfile("adapter/devclient.lua", "t", env))()
    function harness:enable() self.events["nyr:dev:on"]() end
    function harness:act(body) self.events["nyr:dev:act"](body) end
    return harness
end

TestDevActionClient = {}
function TestDevActionClient:setUp() self.client = client() end
function TestDevActionClient:test_action_requires_the_development_enable_event()
    self.client:act({ show = "pockets", at = { x = 1, y = 2, z = 3 } })
    lu.assertEquals(self.client.calls, {})
end
function TestDevActionClient:test_bad_payload_is_rejected_before_any_native_or_screen_action()
    self.client:enable()
    self.client:act("pockets")
    self.client:act(nil)
    for _, body in ipairs({
        { show = "typo", at = { x = 1, y = 2, z = 3 } },
        { show = "pockets", at = { x = 1, y = 2 } },
        { show = "pockets", at = { x = 0/0, y = 2, z = 3 } },
        { show = "pockets", at = { x = 1, y = 2, z = 3 }, heading = math.huge },
        { show = "pockets", heading = 90 },
    }) do self.client:act(body) end
    lu.assertEquals(self.client.calls, {})
end
function TestDevActionClient:test_valid_position_and_screen_reach_the_expected_adapters()
    self.client:enable()
    self.client:act({ show = "pockets", at = { x = 1, y = 2, z = 3 }, heading = 90 })
    lu.assertEquals(self.client.calls, { { "move", 42, 1, 2, 3 }, { "heading", 42, 90 }, { "pockets" } })
end
function TestDevActionClient:test_switching_screens_closes_the_previous_one_first()
    self.client:enable()
    self.client.open = true
    self.client:act({ show = "phone" })
    lu.assertEquals(self.client.calls, { { "close" }, { "wait", 60 }, { "phone" } })
end

function TestDevActionClient:test_action_waits_for_world_and_copies_queued_arguments()
    self.client:enable()
    self.client.facts.collision = false; self.client.sample()
    local body = { show = "phone" }
    self.client:act(body); body.show = "pockets"
    lu.assertEquals(self.client.calls, {})
    self.client.facts.collision = true; self.client.sample()
    lu.assertEquals(self.client.calls, { { "phone" } })
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
