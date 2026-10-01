--- The bridge decides four things a client does not get a say in. Those
--- decisions are plain functions on purpose, so they can be attacked here
--- without a server running.
local modname = ...
local lu = require("luaunit")
local Bridge = require("adapter.bridge")

TestBridge = {}

function TestBridge:test_only_allowlisted_commands_are_reachable()
    local allow = { ["character.create"] = true }
    lu.assertTrue(Bridge.check_request(allow, "character.create", {}))
    -- A command added tomorrow is not reachable until somebody says so.
    local ok, why = Bridge.check_request(allow, "admin.giveall", {})
    lu.assertFalse(ok)
    lu.assertEquals(why, "unknown_command")
end

function TestBridge:test_a_request_that_is_not_shaped_like_one_is_refused()
    local allow = { ["character.create"] = true }
    for _, name in ipairs({ 42, "", "character.retire" }) do
        lu.assertFalse(Bridge.check_request(allow, name, {}))
    end
    lu.assertFalse(Bridge.check_request(allow, "character.create", "not a table"))
    lu.assertFalse(Bridge.check_request(allow, "character.create", 7))
    -- no args at all is fine; the command declares its own requirements
    lu.assertTrue(Bridge.check_request(allow, "character.create", nil))
end

function TestBridge:test_the_account_comes_from_the_server_and_the_actor_from_the_session()
    local meta = Bridge.meta_for("license:abc", "chr_000000000000000000a", nil, 3)
    lu.assertEquals(meta.account, "license:abc")
    lu.assertEquals(meta.actor, "chr_000000000000000000a")
    lu.assertEquals(meta.source, "client:3")
    lu.assertNil(meta.operation_id)
end

function TestBridge:test_a_client_token_is_namespaced_before_it_is_used()
    -- Without this, one player could send the token "x" and have another
    -- player's later request swallowed as a duplicate of it.
    local mine = Bridge.meta_for("license:aaa", nil, "x", 1)
    local theirs = Bridge.meta_for("license:bbb", nil, "x", 2)
    lu.assertEquals(mine.operation_id, "license:aaa/x")
    lu.assertNotEquals(mine.operation_id, theirs.operation_id)
end

function TestBridge:test_a_junk_token_is_dropped_rather_than_used()
    for _, token in ipairs({ { "" }, { 42 }, { {} }, { string.rep("x", 200) }, { nil } }) do
        local meta = Bridge.meta_for("license:aaa", nil, token[1], 1)
        lu.assertNil(meta.operation_id, ("token %s should have been dropped"):format(tostring(token[1])))
    end
end

function TestBridge:test_the_identity_is_taken_in_the_order_it_is_worth_trusting()
    local available = {}
    _G.GetPlayerIdentifierByType = function(_, kind) return available[kind] end

    available = { discord = "discord:123", steam = "steam:456", license = "license:abc" }
    lu.assertEquals(Bridge.account_of(1), "license:abc")

    available = { discord = "discord:123", steam = "steam:456" }
    lu.assertEquals(Bridge.account_of(1), "steam:456")

    available = { discord = "discord:123" }
    lu.assertEquals(Bridge.account_of(1), "discord:123")

    -- Nobody the server can identify is nobody it can be accountable for.
    available = {}
    lu.assertNil(Bridge.account_of(1))
    available = { license = "" }
    lu.assertNil(Bridge.account_of(1))

    _G.GetPlayerIdentifierByType = nil
end

-- ------------------------------------------------- an address is not a person

function TestBridge:test_the_host_is_read_out_of_every_shape_an_endpoint_comes_in()
    lu.assertEquals(Bridge.host_of("127.0.0.1:50000"), "127.0.0.1")
    lu.assertEquals(Bridge.host_of("[::1]:50000"), "::1")
    lu.assertEquals(Bridge.host_of("::1"), "::1")
    lu.assertEquals(Bridge.host_of("192.168.1.20"), "192.168.1.20")
    lu.assertEquals(Bridge.host_of("localhost:30120"), "localhost")
    lu.assertNil(Bridge.host_of(nil))
    lu.assertNil(Bridge.host_of(""))
end

function TestBridge:test_only_this_machine_and_a_private_network_are_near()
    for _, host in ipairs({ "127.0.0.1", "127.8.0.1", "::1", "::ffff:127.0.0.1", "10.0.0.5",
        "172.16.3.4", "172.31.255.1", "192.168.1.20", "fe80::1", "fd12::3" }) do
        lu.assertTrue(Bridge.is_near(host), host .. " should be near")
    end
    for _, host in ipairs({ "198.51.100.23", "172.32.0.1", "172.15.0.1", "8.8.8.8", "11.0.0.1",
        "2001:db8::1", "local", "" }) do
        lu.assertFalse(Bridge.is_near(host), host .. " should not be near")
    end
    lu.assertFalse(Bridge.is_near(nil))
    lu.assertTrue(Bridge.is_loopback("127.0.0.1"))
    lu.assertFalse(Bridge.is_loopback("192.168.1.20"))
end

function TestBridge:test_a_lan_server_gives_no_account_to_a_public_address()
    -- `sv_lan true` is a switch, not a wall. On a VPS in LAN mode everybody
    -- behind one carrier NAT arrived as one account, and a stranger played your
    -- character.
    local saved = { GetConvar = _G.GetConvar, GetPlayerEndpoint = _G.GetPlayerEndpoint,
        GetPlayerIdentifierByType = _G.GetPlayerIdentifierByType }
    local endpoint
    _G.GetConvar = function(name, default)
        if name == "sv_lan" then return "true" end
        return default
    end
    _G.GetPlayerIdentifierByType = function() return nil end
    _G.GetPlayerEndpoint = function() return endpoint end

    endpoint = "127.0.0.1:50000"
    lu.assertEquals(Bridge.account_of(1), "dev:127.0.0.1")
    endpoint = "[::1]:50000"
    lu.assertEquals(Bridge.account_of(1), "dev:local")
    endpoint = "192.168.1.20:50000"
    lu.assertEquals(Bridge.account_of(1), "dev:192.168.1.20")
    endpoint = "198.51.100.23:50000"
    lu.assertNil(Bridge.account_of(1))
    endpoint = nil
    lu.assertNil(Bridge.account_of(1))

    for name, fn in pairs(saved) do _G[name] = fn end
end

function TestBridge:test_a_name_a_client_chose_cannot_forge_a_console_line()
    local forged = "x\n[nyr] the city was written down at day 3"
    local shown = Bridge.printable(forged)
    lu.assertNil(shown:find("\n", 1, true), "a newline reached the console")
    lu.assertEquals(select("#", Bridge.printable("a")), 1)
    lu.assertTrue(#Bridge.printable(string.rep("a", 5000)) <= 70)
end

-- ------------------------------------------------- a city that is not open yet

--- A server small enough to attach a bridge to: the handlers it registers, the
--- replies it sends, and a world that records what it was asked to do.
local function attached(opts)
    local handlers, replies, dispatched = {}, {}, {}
    local saved = {
        RegisterNetEvent = _G.RegisterNetEvent,
        AddEventHandler = _G.AddEventHandler,
        TriggerClientEvent = _G.TriggerClientEvent,
        GetPlayerIdentifierByType = _G.GetPlayerIdentifierByType,
        GetConvar = _G.GetConvar,
    }
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(name, fn) handlers[name] = fn end
    _G.TriggerClientEvent = function(event, target, token, reply)
        replies[#replies + 1] = { event = event, to = target, token = token, reply = reply }
    end
    _G.GetPlayerIdentifierByType = function(_, kind)
        return kind == "license" and "license:abc" or nil
    end
    _G.GetConvar = function() return "false" end

    local world = {
        commands = { defined = function() return true end },
        services = {},
        dispatch = function(_, name, args, meta)
            dispatched[#dispatched + 1] = { name = name, args = args, meta = meta }
            return {
                summary = function() return { ok = true, code = "did_it" } end,
                is_failure = function() return false end,
            }
        end,
    }

    Bridge.attach(world, opts)

    return {
        handlers = handlers,
        world = world,
        request = function(player, name, args, token, epoch)
            _G.source = player
            handlers[Bridge.REQUEST_EVENT](name, args, token, epoch)
            _G.source = nil
        end,
        replies = replies,
        dispatched = dispatched,
        release = function()
            for key, value in pairs(saved) do _G[key] = value end
        end,
    }
end

TestBridgeReadiness = {}

function TestBridgeReadiness:test_old_epoch_never_dispatches_even_when_city_has_reopened()
    local server = attached({ allow = { "character.list" }, epoch = "current" })
    server.request(3, "character.list", {}, "a", "old")
    server.request(3, "character.list", {}, "b")
    lu.assertEquals(#server.dispatched, 0)
    lu.assertEquals(server.replies[1].reply.code, "stale_session")
    server.request(3, "character.list", {}, "c", "current")
    lu.assertEquals(#server.dispatched, 1)
    server.release()
end
function TestBridgeReadiness:test_handshake_and_disconnect_writes_stop_during_drain()
    local open = true
    local server = attached({ allow = {}, epoch = "current", ready = function() return open end })
    server.world.services.sessions = { character_of = function() return "chr:one" end }
    _G.source = 3; server.handlers["nyr:session:hello"]()
    lu.assertEquals(server.replies[1].event, "nyr:session")
    open = false
    server.handlers["nyr:session:hello"](); server.handlers.playerDropped()
    lu.assertEquals(#server.replies, 1); lu.assertEquals(#server.dispatched, 0)
    _G.source = nil; server.release()
end

function TestBridgeReadiness:test_a_city_that_is_not_open_refuses_instead_of_answering()
    -- A database-backed city is read on a thread after the resource starts. A
    -- player who got through during that second would look like somebody with
    -- no character, make a new one, and have the load land on top of it.
    local open = false
    local server = attached({
        allow = { "character.list" },
        ready = function() return open end,
    })

    server.request(3, "character.list", {}, "t1")
    lu.assertEquals(#server.dispatched, 0)
    lu.assertEquals(server.replies[1].reply.code, "not_open")
    lu.assertFalse(server.replies[1].reply.ok)

    open = true
    server.request(3, "character.list", {}, "t2")
    lu.assertEquals(#server.dispatched, 1)
    lu.assertEquals(server.replies[2].reply.code, "did_it")
    server.release()
end

function TestBridgeReadiness:test_a_bridge_with_no_gate_answers_as_it_always_did()
    local server = attached({ allow = { "character.list" } })
    server.request(3, "character.list", {}, "t1")
    lu.assertEquals(#server.dispatched, 1)
    server.release()
end

function TestBridgeReadiness:test_the_refusal_reaches_the_player_who_asked()
    local server = attached({ allow = { "character.list" }, ready = function() return false end })
    server.request(7, "character.list", {}, "t1")
    lu.assertEquals(server.replies[1].to, 7)
    lu.assertEquals(server.replies[1].token, "t1")
    server.release()
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
