--- Where an untrusted client meets the simulation.
--
-- Everything a client sends arrives here and is treated as a suggestion. The
-- bridge establishes four things the client does not get a say in, and then
-- hands the rest to the command bus, which checks the arguments against the
-- command declaration before any handler sees them.
--
--   Which commands exist for clients at all. An allowlist, not a deny list:
--   a command added tomorrow is not reachable from a client until somebody
--   puts it on the list deliberately.
--
--   Who is asking. The account comes from the server identifier of the socket
--   the message arrived on, never from the payload.
--
--   Who they are being. The acting character is whatever the session says they
--   selected. A client naming a character id gets it ignored.
--
--   Which operation this is. A client may supply an idempotency token, and it
--   is namespaced by account before use. Without that, one player could send a
--   token and have another player's later request swallowed as a duplicate.
--
-- What goes back is the outcome summary and nothing else. A refusal carries a
-- code and a sentence; a failure carries neither, because a stack trace is for
-- the server log and not for whoever is poking at the server.

local Bridge = {}

local REQUEST_EVENT = "nyr:request"
local REPLY_EVENT = "nyr:outcome"
local MAX_TOKEN = 64

Bridge.REQUEST_EVENT = REQUEST_EVENT
Bridge.REPLY_EVENT = REPLY_EVENT

--- The identity FiveM gives the server for a connected player. A license is
--- tied to the game install and is the usual anchor; the rest are fallbacks in
--- the order they are worth trusting.
local IDENTIFIER_ORDER = { "license", "license2", "steam", "fivem", "discord" }

--- Is this server in LAN mode? LAN mode skips the Cfx.re identity handshake,
--- so a player connecting to it can arrive carrying no identifier at all.
local function is_lan()
    local value = GetConvar and GetConvar("sv_lan", "false") or "false"
    return value == "true" or value == "1"
end

Bridge.is_lan = is_lan

--- The host out of an endpoint as FiveM reports one: `127.0.0.1:50000`,
--- `[::1]:50000`, or a bare address. Nil for anything that names no host.
function Bridge.host_of(endpoint)
    if type(endpoint) ~= "string" or endpoint == "" then return nil end
    local bracketed = endpoint:match("^%[([^%]]+)%]")
    if bracketed then return bracketed:lower() end
    local v4 = endpoint:match("^(%d+%.%d+%.%d+%.%d+)")
    if v4 then return v4 end
    -- A bare IPv6 address has colons of its own; only one colon is a port.
    local _, colons = endpoint:gsub(":", "")
    if colons == 1 then return endpoint:match("^([^:]*)") end
    return endpoint:lower()
end

local function octets(host)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

--- This machine.
function Bridge.is_loopback(host)
    if type(host) ~= "string" then return false end
    if host == "::1" then return true end
    local a = octets(host:match("^::ffff:(.+)$") or host)
    return a == 127
end

--- This machine, or an address no router forwards from the internet: the
--- private IPv4 ranges and IPv6 unique-local and link-local addresses.
function Bridge.is_near(host)
    if type(host) ~= "string" or host == "" then return false end
    if Bridge.is_loopback(host) then return true end
    local a, b = octets(host:match("^::ffff:(.+)$") or host)
    if a then
        return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
    end
    local lead = host:match("^(%x%x?%x?%x?):")
    if not lead then return false end
    local word = tonumber(lead, 16)
    return (word >= 0xfc00 and word <= 0xfdff) or (word >= 0xfe80 and word <= 0xfebf)
end

--- Something a client chose, made safe to put on one console line: quoted, so a
--- newline in it cannot start a line of its own that reads like the server's,
--- and cut, so one request cannot print a page.
function Bridge.printable(value)
    local quoted = ("%q"):format(tostring(value):sub(1, 64)):gsub("\\\n", "\\n")
    return quoted
end

function Bridge.account_of(source)
    for _, kind in ipairs(IDENTIFIER_ORDER) do
        local identifier = GetPlayerIdentifierByType(source, kind)
        if identifier and identifier ~= "" then
            -- FiveM hands these back already shaped as "license:abcdef".
            return identifier
        end
    end

    -- Nothing in the preferred order. Take whatever else FiveM knows before
    -- giving up: a build may expose an identity this list has not heard of,
    -- and an unknown-but-real identity is worth more than none.
    local count = GetNumPlayerIdentifiers and GetNumPlayerIdentifiers(source) or 0
    for index = 0, count - 1 do
        local identifier = GetPlayerIdentifier(source, index)
        if identifier and identifier ~= "" and not identifier:find("^ip:") then
            return identifier
        end
    end

    -- On a LAN server there may genuinely be nothing. That is not a player
    -- doing anything wrong; it is what `sv_lan true` means, and it is the
    -- normal state of a development server on loopback. Without this, every
    -- request is refused with `no_account` and the first screen never opens --
    -- which looks exactly like a resource that does not work.
    --
    -- An address is a weak identity, good enough only where it cannot be
    -- shared or reached from outside. LAN mode is a switch, not a wall: a VPS
    -- set to `sv_lan true` is still on the internet, and everybody behind one
    -- carrier NAT arrives from one address -- so an address gave strangers one
    -- account, a character played by whoever connected second, and a session
    -- released by whoever left first. Only this machine and a private network
    -- are given an account by address now; anybody else with no identifier is
    -- nobody the server can be accountable for, which is what it always was.
    if is_lan() then
        local endpoint = GetPlayerEndpoint and GetPlayerEndpoint(source) or nil
        local host = Bridge.host_of(endpoint)
        if Bridge.is_near(host) then
            -- The spelling a dev city already keeps its people under.
            if host:match("^%d+%.%d+%.%d+%.%d+$") then return "dev:" .. host end
            if Bridge.is_loopback(host) then return "dev:local" end
            return "dev:" .. host
        end
    end

    return nil
end

--- Build the meta for a request. Split out so it can be tested without a
--- server: everything decided here is decided from server-side facts.
function Bridge.meta_for(account, session_character, token, source)
    local meta = { account = account, actor = session_character, source = "client:" .. tostring(source) }
    if type(token) == "string" and token ~= "" and #token <= MAX_TOKEN then
        -- Namespaced, so one player cannot spend another player's token.
        meta.operation_id = account .. "/" .. token
    end
    return meta
end

--- Decide whether a request is even shaped like one, before any of it is used.
function Bridge.check_request(allow, name, args)
    if type(name) ~= "string" or not allow[name] then
        return false, "unknown_command"
    end
    if args ~= nil and type(args) ~= "table" then
        return false, "bad_args"
    end
    return true
end

--- Attach the bridge to a world.
---
--- opts.allow    list of command names clients may ask for
--- opts.on_log   called with a line for every request, for the server console
--- opts.ready    optional; while it answers false every request is refused
---
--- `ready` exists because a database-backed city is read on a thread after the
--- resource starts, and a player who connects during that second must not be
--- handed a city that has not been read yet -- they would look like somebody
--- with no character, make a new one, and the load would land on top of it.
function Bridge.attach(world, opts)
    opts = opts or {}
    local allow = {}
    for _, name in ipairs(opts.allow or {}) do
        assert(world.commands:defined(name), ("%s is on the client allowlist but is not defined"):format(name))
        allow[name] = true
    end
    local log = opts.on_log or function() end
    local ready = opts.ready or function() return true end
    local epoch = opts.epoch
    if epoch then
        RegisterNetEvent("nyr:session:hello")
        AddEventHandler("nyr:session:hello", function()
            if ready() then TriggerClientEvent("nyr:session", source, epoch) end
        end)
    end

    local function handle(source, name, args, token, asked_epoch)
        -- The two refusals below used to return without a word in the log, and
        -- they are the two that refuse *everything*: a city that never opened
        -- and a player the server cannot name are not one bad request, they
        -- are every request from that client, for as long as it lasts.
        --
        -- That cost a whole afternoon. Every command a connected client sent
        -- was refused here, the log stayed clean, and with no chat resource on
        -- that server the player saw nothing either -- so "it works" and "the
        -- server has never heard of you" looked identical from both ends.
        if not ready() then
            log(("%s asked for %s before the city was open"):format(tostring(source), Bridge.printable(name)))
            TriggerClientEvent(REPLY_EVENT, source, token, { ok = false, code = "not_open",
                message = "The city is still opening. Try again in a moment." })
            return
        end

        local account = Bridge.account_of(source)
        if epoch and asked_epoch ~= epoch then
            TriggerClientEvent(REPLY_EVENT, source, token, { ok = false, code = "stale_session",
                message = "The server restarted. Wait for the city to reconnect before retrying." })
            return
        end
        if not account then
            -- No server identity means no identity at all. This is not a
            -- player the server can be accountable for.
            log(("%s asked for %s and the server could not identify them")
                :format(tostring(source), Bridge.printable(name)))
            TriggerClientEvent(REPLY_EVENT, source, token, { ok = false, code = "no_account",
                message = "The server could not identify you." })
            return
        end

        local shaped, why = Bridge.check_request(allow, name, args)
        if not shaped then
            -- The name is whatever the client sent, so it is quoted and cut: one
            -- request once printed lines that read as the server's own.
            log(("%s asked for %s and was refused: %s"):format(account, Bridge.printable(name), why))
            TriggerClientEvent(REPLY_EVENT, source, token, { ok = false, code = why,
                message = "That is not something you can ask for." })
            return
        end

        local meta = Bridge.meta_for(account, world.services.sessions
            and world.services.sessions:character_of(account) or nil, token, source)
        local outcome = world:dispatch(name, args or {}, meta)

        local reply = outcome:summary()
        if outcome:is_failure() then
            -- A broken handler is a bug report for the log, not a hint for
            -- whoever is poking at the server.
            log(("%s failed for %s: %s"):format(name, account, tostring(outcome.message)))
            reply.message = "Something went wrong. It has been logged."
        else
            log(("%s for %s: %s"):format(name, account, outcome.code))
        end
        TriggerClientEvent(REPLY_EVENT, source, token, reply)
    end

    RegisterNetEvent(REQUEST_EVENT)
    AddEventHandler(REQUEST_EVENT, function(name, args, token, asked_epoch)
        local player = source
        local ok, err = pcall(handle, player, name, args, token, asked_epoch)
        if not ok then
            -- Nothing a client sends may take the handler down; the next
            -- request has to still work.
            log(("request from %s broke the bridge: %s"):format(tostring(player), tostring(err)))
        end
    end)

    -- A player who leaves is no longer playing anybody. Without this their
    -- character stays bound and they cannot pick it up when they come back.
    AddEventHandler("playerDropped", function()
        if not ready() then return end
        local player = source
        local account = Bridge.account_of(player)
        if not account then return end
        if world.services.sessions and world.services.sessions:character_of(account) then
            world:dispatch("character.release", {}, { account = account, source = "dropped" })
        end
    end)

    return { allow = allow }
end

return Bridge
