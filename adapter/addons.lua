--- What another resource on this server may ask of this city, and what it is
--- told back.
---
-- Until this existed there was no answer to either. This resource registered no
-- exports at all and every event it raised stayed inside it, so a second
-- resource written against this one could not ask it anything and could not be
-- told anything. That is fine for a closed product and useless for a framework,
-- which is what this is sold as.
--
-- Two surfaces, and they are deliberately the two that already exist inside:
--
--   ask    runs a command on the same bus a player's key press uses, and
--          answers with the same shape a client receives
--   events every domain event, forwarded as it happens
--
-- **An addon is not a client.** It is server-side Lua the owner installed, as
-- trusted as the server itself, so there is no allowlist here -- that list
-- exists because a client is untrusted, and an addon that could only reach what
-- a client can reach would be unable to do the things addons are for. What
-- replaces it is a record: every call is stamped with the resource that made
-- it, so an owner reading the log can see which addon did what.
--
-- None of this is a native, so all of it is tested.

local Money = require("domain.money")

local Addons = {}

-- Deep enough for anything this city emits, shallow enough that a payload with
-- a cycle in it cannot take the server with it.
local MAX_DEPTH = 6

--- The meta an addon may set on a dispatch, and nothing else.
---
--- Undeclared keys are refused rather than dropped, the same way the drawn
--- page's are: a caller passing something this does not understand is either a
--- bug or a misunderstanding, and silently ignoring it means neither is ever
--- noticed.
---
--- **`actor` is not on this list, and that is the whole of it.** For a client,
--- who is acting is derived from the account's session by `Bridge.meta_for` and
--- never taken from what the client sent -- that one rule is what every other
--- guarantee in this city rests on, because ownership, money and the criminal
--- record all attach to whoever acted. An addon that could name its own actor
--- would be acting as anybody it could name, including a member of staff whose
--- id it read out of `character.list` a moment earlier, and `admin.give` checks
--- the actor's level rather than the caller's.
---
--- So an addon says which account, and who that is is looked up the same way it
--- is for everybody else. A character nobody is playing is not acting, and the
--- command says so.
local META = { account = "string", operation_id = "string" }

--- Turn a payload into something that survives leaving this resource.
---
--- What crosses between resources is plain data. A `Money` is a table with a
--- metatable, so it would arrive as whatever fields it happens to have today --
--- an addon reading `.minor` would be reading an internal shape and would break
--- the day it changed. It crosses as the whole number of minor units, which is
--- what the ledger is denominated in and what every other number here already
--- is.
---
--- A function cannot cross at all and is left out rather than crashing the
--- serialiser. Depth is capped because a payload that refers to itself would
--- otherwise be copied until something gives.
function Addons.payload(value, depth)
    depth = depth or 0
    if Money.is(value) then return value:to_minor() end

    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" then return nil end
    if depth >= MAX_DEPTH then return nil end

    local out = {}
    for key, held in pairs(value) do
        local key_kind = type(key)
        if key_kind == "string" or key_kind == "number" then
            local crossed = Addons.payload(held, depth + 1)
            if crossed ~= nil then out[key] = crossed end
        end
    end
    return out
end

--- What an addon asked for, shaped into a dispatch.
---
--- Returns `command, args, meta`, or `nil, why` when the asking was malformed.
--- The reason is for a server owner reading a log, so it says what was wrong
--- rather than what to do about it.
---
--- `from` is the resource that called, which FiveM knows and the caller does
--- not choose. It goes into `source`, so every entry in the command log says
--- which addon is responsible for it.
function Addons.request(command, args, meta, from)
    if type(command) ~= "string" or command == "" then
        return nil, "an addon asked for something that is not a command name"
    end
    if not command:find("%.") then
        return nil, ("%s is not a command: they are named system.verb"):format(command)
    end
    if args ~= nil and type(args) ~= "table" then
        return nil, ("%s was given arguments that are not a table"):format(command)
    end
    if meta ~= nil and type(meta) ~= "table" then
        return nil, ("%s was given a context that is not a table"):format(command)
    end

    local shaped = {}
    for key, held in pairs(meta or {}) do
        local wanted = META[key]
        if not wanted then
            return nil, ("%s was given %q, which is not something an addon sets")
                :format(command, tostring(key))
        end
        if type(held) ~= wanted then
            return nil, ("%s was given a %s that is not a %s"):format(command, key, wanted)
        end
        shaped[key] = held
    end

    -- Stamped here and not taken from the caller. An addon does not get to say
    -- it was somebody else.
    shaped.source = "addon:" .. (type(from) == "string" and from ~= "" and from or "unknown")
    -- An operation id is namespaced by the resource that sent it, the way a
    -- client's token is namespaced by its account. Receipts are durable, so two
    -- addons that both counted from 1 refused each other for good, and an id
    -- that matched one the city makes for itself was refused as already done.
    if shaped.operation_id ~= nil then
        shaped.operation_id = shaped.source .. "/" .. shaped.operation_id
    end
    return command, args or {}, shaped
end

--- Who is acting, for an addon's dispatch.
---
--- The same question `Bridge.meta_for` answers for a client and the same
--- answer: the character the account is playing, looked up, never named by the
--- caller. `playing` is the session's `character_of`, passed in so this stays
--- something a spec can call.
---
--- An account playing nobody gets no actor, and the command refuses. That is
--- the correct refusal: an offline character is not doing anything.
function Addons.acting(context, playing)
    if type(context) ~= "table" then return context end
    if type(context.account) == "string" and type(playing) == "function" then
        context.actor = playing(context.account)
    end
    return context
end

--- What an addon is told about this resource before it commits to anything.
---
--- A version an addon can branch on, and the two names it needs to reach the
--- rest of this. Kept small on purpose: the way to find out what this city can
--- do is to ask it, not to read a manifest of everything.
function Addons.about(resource, version)
    return {
        resource = resource,
        version = version,
        ask = "exports['" .. tostring(resource) .. "']:ask(command, args, meta)",
        events = "nyr:event",
    }
end

NyrAddons = Addons

return Addons
