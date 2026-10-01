--- A window into a running city, for whoever is building it.
--
-- FiveM can be driven while it runs. That is the whole difference from a game
-- that cannot: there is no bake-run-observe cycle here, because the server
-- holds an HTTP handler and the client can be asked questions over an event.
-- Not using that means reading console logs to find out what is on somebody's
-- screen, which is slow, expensive and usually wrong.
--
-- So: one endpoint that answers what is happening, in as few bytes as it can.
--
--   GET  /nyr_underworld/state           everything at once
--   GET  /nyr_underworld/log             the last lines the server printed
--   GET  /nyr_underworld/log?since=N     every kept line numbered after N, so a
--                                        reader that keeps asking misses nothing
--   GET  /nyr_underworld/errors          what the city recorded as errors, notices
--                                        and audit, with their city time
--   GET  /nyr_underworld/commands        every command and what it declares
--   GET  /nyr_underworld/verify          every consistency check the city has
--   GET  /nyr_underworld/do?p=1&c=me.status&a={"x":1}   run a command as a player
--   GET  /nyr_underworld/act?p=1&show=pockets           open a screen on a client
--   GET  /nyr_underworld/act?p=1&x=..&y=..&z=..&h=..    put that client's body somewhere
--
-- Until the city is open only the reads answer, and `/state` says `open`.
--
-- Nothing a request carries and nothing a native answers may take a route
-- down without a reply: a route that throws answers 500 and says what threw,
-- because a request that hangs reads, from a rig, exactly like a server that
-- has died -- and the two are found out in very different ways.
--
-- **Only on a LAN server.** A public server never installs any of this: the
-- routes would let anybody on the internet read the city and act as any player
-- in it, which is every rule in this resource handed away at once.

local PlayerCommands = NyrCommands or require("adapter.commands")
local Bridge = require("adapter.bridge")

local DevBridge = {}

-- What `/state` and a bare `/log` carry: the tail, small enough to read.
local LOG_LINES = 40
-- What `/log?since=` can drain from. A rig that asks every few seconds keeps
-- every line; one that asks every ten minutes is told how many it lost.
local LOG_KEEP = 600
local REPORT_STALE_MS = 8000
-- The most lines of what threw that one client's report is allowed to say.
local CLIENT_ERRORS = 24

DevBridge.LOG_LINES = LOG_LINES
DevBridge.LOG_KEEP = LOG_KEEP

local lines = {}
local sequence = 0
local reports = {}

local function lan()
    local value = GetConvar and GetConvar("sv_lan", "false") or "false"
    return value == "true" or value == "1"
end

DevBridge.enabled = lan

--- Keep what the server printed, so nobody has to tail a console to read it.
---
--- Numbered as it arrives. A reader that only ever saw the last forty lines
--- saw whatever a busy minute had not scrolled past, and a line about a save
--- failing is exactly the kind that scrolls.
function DevBridge.remember(message)
    sequence = sequence + 1
    lines[#lines + 1] = { n = sequence, at = os.date("%H:%M:%S"), said = tostring(message) }
    while #lines > LOG_KEEP do table.remove(lines, 1) end
end

--- The last `count` of what is kept, oldest first.
function DevBridge.tail(kept, count)
    local out = {}
    for index = math.max(1, #kept - count + 1), #kept do out[#out + 1] = kept[index] end
    return out
end

--- Every kept line numbered after `asked`, and how many after it are gone.
---
--- Returns nothing and the reason when `asked` is not a line number. A reader
--- sends back the `seq` it was last given and gets only what it has not seen;
--- `dropped` above zero means it waited too long and the oldest of what it
--- missed has scrolled out of what is kept.
function DevBridge.since(kept, asked)
    local wanted = asked ~= nil and math.tointeger(tonumber(asked)) or nil
    if wanted == nil or wanted < 0 then
        return nil, ("since=%s is not a line number: /log?since=0 reads everything kept")
            :format(tostring(asked))
    end
    local newest = kept[#kept] and kept[#kept].n or 0
    local oldest = kept[1] and kept[1].n or (newest + 1)
    local out = { since = wanted, seq = newest, dropped = 0, log = {} }
    if wanted + 1 < oldest then out.dropped = oldest - (wanted + 1) end
    for _, line in ipairs(kept) do
        if line.n > wanted then out.log[#out.log + 1] = line end
    end
    return out
end

--- What a client said threw, as at most CLIENT_ERRORS strings of a bounded
--- length, the most recent kept. This arrives from off this machine.
function DevBridge.errors_of(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for index = math.max(1, #value - CLIENT_ERRORS + 1), #value do
        local entry = value[index]
        if entry ~= nil then out[#out + 1] = tostring(entry):sub(1, 300) end
    end
    if #out == 0 then return nil end
    return out
end

--- Every consistency check the city has, run and gathered.
---
--- A verifier that throws is a finding, not a dead request: it is written
--- down as a problem in its own name and the others still run. A verifier
--- that says no without a list is written down too, because "no" with no
--- reason is the answer a check that has stopped working gives.
DevBridge.VERIFIERS = { "inventory", "record", "standing" }

function DevBridge.verify_of(world)
    local problems, checked, missing = {}, {}, {}
    local function gather(where, run)
        checked[#checked + 1] = where
        local ran, ok, found = pcall(run)
        if not ran then
            problems[#problems + 1] = { where = where,
                problem = ("the check itself failed: %s"):format(tostring(ok)) }
            return
        end
        if ok == true then return end
        if type(found) ~= "table" or #found == 0 then
            problems[#problems + 1] = { where = where, problem = "said no without saying why" }
            return
        end
        for _, problem in ipairs(found) do
            problems[#problems + 1] = { where = where, problem = tostring(problem) }
        end
    end
    gather("world", function() return world:verify() end)
    for _, name in ipairs(DevBridge.VERIFIERS) do
        local service = world.services and world.services[name]
        if service and type(service.verify) == "function" then
            gather(name, function() return service:verify() end)
        else
            missing[#missing + 1] = name
        end
    end
    return { ok = #problems == 0, problems = problems, checked = checked, missing = missing }
end

--- What one client last said about itself.
--- A native's idea of yes, which is not always Lua's.
---
--- FiveM hands back a Lua boolean from some natives and the number 0 or 1 from
--- others, with nothing at the call site to say which. `IsEntityVisible` on a
--- player's own ped answers `1`, so `body.visible == true` was false for a ped
--- that was plainly drawn.
---
--- Anything that is not an answer either way comes back nil, because "nobody
--- said" and "no" are different things and collapsing them is how a field
--- comes to report `false` forever.
function DevBridge.boolish(value)
    if value == true or value == 1 then return true end
    if value == false or value == 0 or value == nil then return false end
    return nil
end

--- A number a snapshot can carry: finite, or nothing. `tonumber("1e999")` is
--- infinity, JSON has nothing to encode it as, and a report that carries one
--- is a `/state` that cannot be answered for as long as the report is fresh.
function DevBridge.number(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

function DevBridge.report(source, body)
    if type(body) ~= "table" then return end
    reports[tostring(source)] = {
        at = GetGameTimer and GetGameTimer() or 0,
        did = type(body.did) == "string" and body.did:sub(1, 160) or nil,
        registered = type(body.registered) == "string" and body.registered:sub(1, 900) or nil,
        loaded = type(body.loaded) == "string" and body.loaded:sub(1, 200) or nil,
        spawned = DevBridge.boolish(body.spawned),
        -- Whether there is a body to look at. The client has always measured
        -- this and this function has never kept it: the snapshot read a field
        -- that was not here, found nil, and sent `false`. Every time, since it
        -- was written. The one field meant to catch a player spawning invisible
        -- could not tell that from a player standing in the street.
        visible = DevBridge.boolish(body.visible),
        model = DevBridge.number(body.model),
        nui = DevBridge.boolish(body.nui),
        hp = DevBridge.number(body.hp),
        -- Three numbers and two commas, from a client; bounded like the rest.
        pos = type(body.pos) == "string" and body.pos:sub(1, 60) or nil,
        showing = type(body.showing) == "string" and body.showing:sub(1, 120) or nil,
        -- How many marks the client has on its map, and the prompt it has on
        -- screen. Kept as the client said them: zero marks is an answer, and
        -- the one this field exists to be able to give.
        marked = math.tointeger(tonumber(body.marked)),
        prompt = type(body.prompt) == "string" and body.prompt:sub(1, 120) or nil,
        errors = DevBridge.errors_of(body.errors),
    }
end

--- What a client says about itself, ready to go into a snapshot.
---
--- Three fields went missing between the client measuring them and the
--- snapshot reading them, and nothing said so. This is the joint they went
--- missing at, so it is a function rather than a block inside `install`, which
--- no spec can call.
---
--- `fresh` is whether the report is recent enough to mean anything. A stale
--- one contributes nothing rather than its last known values, and a value the
--- client did not send stays absent rather than becoming a confident `false`.
function DevBridge.about(report, fresh)
    report = report or {}
    local out = {
        did = report.did,
        registered = report.registered,
        loaded = report.loaded,
        errors = report.errors,
        reporting = fresh == true,
    }
    if not fresh then return out end
    -- Written out rather than `fresh and x or nil`, which reads well and
    -- answers the wrong thing for every value that is false: it turns "the
    -- client said no" into "the client did not say". This is the file where
    -- that mattered most.
    for _, field in ipairs({ "spawned", "visible", "model", "nui", "hp", "pos", "showing",
                             "marked", "prompt" }) do
        out[field] = report[field]
    end
    return out
end

--- What one client last said, for a spec to read back.
---
--- `report` writing a field and the snapshot reading it are two halves, and
--- three fields went missing between them for as long as they existed. A spec
--- that can only see one half cannot catch that.
function DevBridge.seen(source)
    return reports[tostring(source)]
end

local function decode(text)
    if not text or text == "" then return nil end
    local ok, value = pcall(json.decode, text)
    return ok and value or nil
end

local function query_of(path)
    local found = {}
    for key, value in (path:match("%?(.*)$") or ""):gmatch("([^&=]+)=([^&]*)") do
        -- Only the characters a query actually carries; anything else stays as
        -- typed, because guessing at an encoding is how a name gets mangled.
        --
        -- A `+` is a space, and is turned into one before anything is decoded:
        -- decoded first, `%2B` became a `+` and then a space, and a phone number
        -- could never be sent through `/do`.
        found[key] = value:gsub("%+", " "):gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    end
    return found
end

DevBridge.query_of = query_of

-- ------------------------------------------------------------ what /act does
--
-- The decisions below are plain functions on this module, and the route at the
-- bottom of the file only calls them. That split is not tidiness: `install`
-- cannot run outside FiveM, so anything decided inside it is decided where no
-- test can reach, and three defects duly lived there -- a position with no `x`,
-- a screen nobody has, and a target that was still a string. Each answered 200
-- and did nothing, which is the worst answer a recording rig can be given,
-- because it is shaped exactly like the one that worked.

--- Every screen `/act` can open. The client holds the same names against the
--- functions that open them, and a spec keeps the two lists equal.
DevBridge.SCREENS = { "picker", "pockets", "phone", "nearby", "jobs", "close" }

--- A number the game could actually hold. `tonumber` is happy to return
--- infinity for `1e999`, and a coordinate that is not finite is not a place.
local function finite(text)
    local value = tonumber(text)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

--- Which client to act on, given what was asked for and who is actually here.
---
--- Everywhere else in FiveM `-1` means every client. A recording drives one,
--- and "every client" is not somewhere to arrive at by leaving a field out or
--- by a string that happened to look like a number, so this returns a whole
--- positive id that is connected, or it returns nothing, why, and the status
--- that says which kind of no it is: 400 for a target nobody could name, 404
--- for a well-named player who is not here. The second is not a malformed
--- instruction, and a rig that reads every refusal as its own mistake goes
--- looking for a typo in a URL that had none.
local function target_of(asked, connected)
    local here, ids = {}, {}
    for _, id in ipairs(connected or {}) do
        local whole = math.tointeger(tonumber(id))
        if whole and not here[whole] then
            here[whole] = true
            ids[#ids + 1] = whole
        end
    end
    table.sort(ids)

    if asked == nil then
        if #ids == 1 then return ids[1] end
        if #ids == 0 then
            return nil, "no client is connected: /act needs a running game to act on", 404
        end
        return nil, ("several clients are connected (%s): name one with p=")
            :format(table.concat(ids, ", ")), 400
    end

    -- `finite` has already refused a name, a blank and an infinity, so what
    -- reaches here is a real number; a player id is a whole one above zero.
    local value = finite(asked)
    local whole = value and math.tointeger(value)
    if not whole or whole <= 0 then
        return nil, ("p=%s is not a player: name one connected client by id")
            :format(tostring(asked)), 400
    end
    if not here[whole] then
        return nil, ("no client %d is connected (%s)"):format(whole,
            #ids > 0 and ("connected: " .. table.concat(ids, ", ")) or "none are"), 404
    end
    return whole
end

--- What `/act` should do, decided without touching the game.
---
--- Returns `{ to, what }`, or nothing, why not, and the status to answer with --
--- 404 when the only thing wrong is that nobody by that id is here, 400 for
--- everything else. It sends nothing: the caller
--- sends, and what comes back from a send is that it was sent, never that the
--- game did it. Those are two different claims and /state answers the second.
---
--- `connected` is what `GetPlayers()` returns -- ids as strings.
function DevBridge.act_plan(args, connected)
    args = args or {}
    local what = {}

    if args.show ~= nil then
        local known = false
        for _, name in ipairs(DevBridge.SCREENS) do
            if name == args.show then known = true break end
        end
        if not known then
            return nil, ("no screen called %q: try %s")
                :format(tostring(args.show), table.concat(DevBridge.SCREENS, ", "))
        end
        what.show = args.show
    end

    -- All three axes or none. Two of them is a typo, and a body moved to a
    -- position missing one of its numbers is how a ped ends up under the map.
    if args.x ~= nil or args.y ~= nil or args.z ~= nil then
        local at = {}
        for _, axis in ipairs({ "x", "y", "z" }) do
            local value = finite(args[axis])
            if value == nil then
                -- Left out and mistyped are different mistakes and the rig
                -- author is looking at a URL, not at a Lua value, so `nil` is
                -- not a word that belongs in the answer.
                return nil, args[axis] == nil
                    and ("%s is missing: /act needs x, y and z together"):format(axis)
                    or ("%s=%s is not a coordinate"):format(axis, tostring(args[axis]))
            end
            at[axis] = value
        end
        what.at = at
        if args.h ~= nil then
            local heading = finite(args.h)
            if heading == nil then
                return nil, ("h=%s is not a heading"):format(tostring(args.h))
            end
            what.heading = heading
        end
    elseif args.h ~= nil then
        return nil, "h= turns a body that is not being moved: send x, y and z too"
    end

    -- A move to a shop's own coordinates stood the body on top of its counter.
    -- safe=1 asks the game for the nearest place a person can stand instead.
    if args.safe ~= nil then
        if not what.at then
            return nil, "safe=1 is a kind of move: send x, y and z too"
        end
        if args.safe ~= "1" and args.safe ~= "true" then
            return nil, ("safe=%s: safe is safe=1 or nothing"):format(tostring(args.safe))
        end
        what.safe = true
    end

    -- Run a command the way a player would, because otherwise the only way to
    -- find out whether one is registered is to ask a person to type it. That
    -- was asked three times in one session, and each time the answer was "it
    -- works" while the server had seen nothing at all -- there was no chat
    -- resource on that server, so there was nowhere to type and nowhere for
    -- the answer to go, and nobody could tell.
    --
    -- Only the names this resource registers. Not an arbitrary console line:
    -- a bridge that runs anything a URL says is a different and much larger
    -- thing than one that presses this resource's own buttons.
    if args.run ~= nil then
        local name = tostring(args.run)
        if not PlayerCommands.claimed()[name] then
            return nil, ("nothing here registers %q, so /act will not run it"):format(name)
        end
        what.run = name
    end

    -- Walk there rather than appear there: the game's own route finding, so a
    -- recording shows somebody arriving instead of a cut. All three or none, for
    -- the same reason as a move, and not together with a move.
    if args.wx ~= nil or args.wy ~= nil or args.wz ~= nil then
        if what.at then
            return nil, "a body is either walked (wx, wy, wz) or moved (x, y, z), not both"
        end
        local to = {}
        for _, axis in ipairs({ "x", "y", "z" }) do
            local key = "w" .. axis
            local value = finite(args[key])
            if value == nil then
                return nil, args[key] == nil
                    and ("%s is missing: a walk needs wx, wy and wz together"):format(key)
                    or ("%s=%s is not a coordinate"):format(key, tostring(args[key]))
            end
            to[axis] = value
        end
        what.walk = to
        local pace = args.pace == nil and "walk" or tostring(args.pace)
        if pace ~= "walk" and pace ~= "run" then
            return nil, ("pace=%s: a walk is at pace=walk or pace=run"):format(pace)
        end
        what.pace = pace
    elseif args.pace ~= nil then
        return nil, "pace= is the pace of a walk: send wx, wy and wz too"
    end

    -- What E does where the body is standing, through the function the key
    -- calls: the counter at a shop, the bank at a branch, Around you at a door.
    if args.press ~= nil then
        if args.press ~= "1" and args.press ~= "true" then
            return nil, ("press=%s: press is press=1 or nothing"):format(tostring(args.press))
        end
        what.press = true
    end

    if not what.show and not what.at and not what.run and not what.walk and not what.press then
        return nil, "nothing to do: /act?p=1&show=pockets, /act?p=1&run=nyrjobs,"
            .. " /act?p=1&x=..&y=..&z=..&h=.., /act?p=1&wx=..&wy=..&wz=.. or /act?p=1&press=1"
    end

    -- Last, so a malformed request is reported as malformed even when nobody
    -- is connected. The rig can be checked against a server with no players in
    -- it, which is the state it is written in.
    local target, why, status = target_of(args.p, connected)
    if not target then return nil, why, status end

    return { to = target, what = what }
end

-- ------------------------------------------------ before the city has opened
--
-- The city is read on a thread once the resource has started, and seeded from
-- config.lua after that. This handler is registered before either, and it ran
-- whatever it was asked straight away. So for that second `/do` acted on a city
-- that had not been read: a journey made a character, asked for the map, was
-- told there was nothing on it and failed -- and a second journey on the same
-- server was handed six places. The client bridge has refused during that
-- second since it was written. This one never did.
--
-- An answer from that second is not evidence of anything. A step that fails
-- there fails for the moment it ran in, not for the city, and a step that
-- passes has built something the load then lands on top of.

--- The routes that answer before the city is open. Each only reads, and what
--- it reads says the city is not open rather than describing one.
---
--- A list of what may answer, not of what may not: a route added tomorrow
--- waits for the city until somebody decides that it only reads.
---
--- `/errors` reads while the city is shut on purpose: a city that failed to
--- open is the moment its errors are worth reading. `/verify` is not here,
--- because a verdict on an unread city is a verdict on nothing.
DevBridge.READS = { ["/"] = true, ["/state"] = true, ["/log"] = true,
                    ["/errors"] = true, ["/commands"] = true }

--- Whether a route can be answered yet, and if it cannot, the refusal.
---
--- Returns nothing when it can, or the status and the body to send. `open` is
--- whether the city has opened, and only `true` is a yes: a gate that was told
--- nothing has not been told the city is open.
---
--- One refusal, sent the way each route already says no. `/do` answers 200
--- whatever the city said -- `not_playing` arrives that way -- and a reader of
--- `/do` takes any other status as a bridge that did not answer, which is not
--- what happened. A reader of `/act` takes a 200 as done. So there it is a 503:
--- refused for now, and not a malformed instruction either.
function DevBridge.gate(route, open)
    if open == true or DevBridge.READS[route] then return nil end
    local refusal = {
        ok = false, code = "not_open",
        why = "the city has not opened yet. /state says open = true once it has;"
            .. " if it never does, the server console says why",
    }
    if route == "/do" then return 200, refusal end
    return 503, refusal
end

--- Whether a request may reach the bridge at all.
---
--- `sv_lan` was read once, at install, and was the whole gate -- and LAN mode is
--- a switch, not a wall. A staging VPS set to `sv_lan true` with the default
--- `endpoint_add_tcp "0.0.0.0:30120"` answered `/state` to anybody who could
--- reach the port, with every player's license and wallet in it, and `/do` let
--- them act as any connected player. Setting `sv_lan false` afterwards left the
--- routes open. Measured with a request from 198.51.100.23 before this.
---
--- So every request is asked both, now: is this server in LAN mode at this
--- moment, and is the caller this machine. The rig and Nyr's journeys call from
--- 127.0.0.1; nothing else has a reason to.
function DevBridge.admits(address, lan_now)
    if lan_now ~= true then return false end
    return Bridge.is_loopback(Bridge.host_of(address))
end

--- Where to find this bridge, as a line somebody can act on.
---
--- `port` is 0 when the server has not bound its endpoint yet, and a line
--- built from it reads `http://127.0.0.1:0/...` -- a port that cannot be
--- opened, printed with exactly the confidence of one that can. So an unusable
--- port does not get dressed up as a URL: the line says the path and sends the
--- reader to the server's own port instead, which is at least true.
function DevBridge.where(port, resource)
    resource = resource or "this resource"
    port = tonumber(port)
    if not port or port ~= math.floor(port) or port <= 0 or port > 65535 then
        return ("[nyr] dev bridge on: /%s/state, on whichever port this server "
                .. "is listening on (see endpoint_add_tcp in server.cfg)"):format(resource)
    end
    return ("[nyr] dev bridge on: http://127.0.0.1:%d/%s/state"):format(port, resource)
end

--- Put the bridge on this server, if it is a LAN server.
---
--- opts.ready    optional; while it answers false only a read is answered
--- opts.on_log   called with a line for every request refused while it does
---
--- `ready` is the predicate the client bridge is attached with, so both doors
--- into the city open at the same moment.
function DevBridge.install(world, Characters, opts)
    if not lan() then
        print("[nyr] dev bridge off: this server is not in LAN mode")
        return
    end

    opts = opts or {}
    local ready = opts.ready or function() return true end
    local log = opts.on_log or function() end

    --- Asked afresh for every request. Written out, because a predicate's yes
    --- is whatever Lua calls true and `/state` sends a boolean either way.
    local function is_open()
        if ready() then return true end
        return false
    end

    RegisterNetEvent("nyr:dev:report")
    AddEventHandler("nyr:dev:report", function(body)
        DevBridge.report(source, body)
    end)

    AddEventHandler("playerJoining", function()
        TriggerClientEvent("nyr:dev:on", source)
    end)

    -- A client half that has just started, asking whether this is a server
    -- that answers.
    --
    -- Arming on `playerJoining` alone was not enough: it does not fire for
    -- somebody who never left, so restarting this resource under a connected
    -- client left that client deaf -- no report, no position, and `/act`
    -- sending instructions to a half that was not listening. Arming everybody
    -- already connected from here does not fix it either, because both halves
    -- restart at once and the client has not registered its handler yet when
    -- the server reaches this line. That was measured, not guessed: the loop
    -- was written, run, and the client still reported nothing.
    --
    -- So the asking belongs to the half that knows it has just started. What
    -- it is asking for is still entirely the server's to give: on anything but
    -- a LAN server `install` has already returned, and there is no handler
    -- here to answer with.
    RegisterNetEvent("nyr:dev:hello")
    AddEventHandler("nyr:dev:hello", function()
        TriggerClientEvent("nyr:dev:on", source)
    end)

    --- The account a player id stands for, the way the client bridge decides it.
    ---
    --- Only a connected player is asked about. On the Enhanced server the
    --- identifier native throws for an id nobody holds -- "Expected an
    --- numeric client id" -- and a `/do` for a player who is not here was a
    --- request that never got an answer. A player who is not here is the
    --- account nobody is connected as, which is what `p=1` on an empty
    --- server has always meant.
    ---
    --- It asks `Bridge.account_of`, the one decision about who a connection is.
    --- This used to be a second copy of it, kept here where no spec reached,
    --- and it had drifted: an IPv6 client was `dev:local` here and itself there.
    local function account_of(id)
        local here = false
        for _, connected in ipairs(GetPlayers()) do
            if tostring(connected) == tostring(id) then here = true break end
        end
        if here then
            local account = Bridge.account_of(id)
            if account then return account end
        end
        return "dev:local"
    end

    --- One connected player, as the snapshot describes them.
    local function describe(id, sessions, people)
        local account = account_of(id)
        local character = sessions and sessions:character_of(account) or nil
        local person = character and people:load(character) or nil
        local report = reports[tostring(id)] or {}
        local fresh = report.at and GetGameTimer and (GetGameTimer() - report.at) < REPORT_STALE_MS
        local out = {
            id = tonumber(id), name = GetPlayerName(id),
            account = account,
            character = character,
            who = person and Characters.full_name(person) or nil,
            wallet = character and world.ledger:balance(
                Characters.wallet(character)):to_minor() or nil,
        }
        for field, value in pairs(DevBridge.about(report, fresh)) do out[field] = value end
        return out
    end

    local function snapshot()
        local sessions = world.services.sessions
        local people = world:repository(Characters.Character)
        -- `open` is how a driver knows a walk can begin. The bridge answering
        -- was taken as that, and it answers a second before the city is there.
        --
        -- `seq` is the number of the newest log line, so a reader knows what
        -- `/log?since=` to ask for; `log` is only the tail.
        local out = { at = world.clock:describe(), open = is_open(), players = {},
                      seq = sequence, log = DevBridge.tail(lines, LOG_LINES) }
        for _, id in ipairs(GetPlayers()) do
            -- A player leaving in the middle of this is a real thing a game
            -- does, and a native asked about a player who has just gone throws.
            -- One player's trouble is that player's line, not the whole answer.
            local ran, person = pcall(describe, id, sessions, people)
            if ran then
                out.players[#out.players + 1] = person
            else
                out.players[#out.players + 1] = { id = tonumber(id), trouble = tostring(person) }
            end
        end
        -- The counts a rig compares before and after a step: entities, accounts,
        -- what is owned, what is pending, and how many errors the city has
        -- recorded. A step that passes and leaves that last number higher is a
        -- step that broke something quietly.
        local counted, summary = pcall(world.summary, world)
        if counted then out.summary = summary else out.summary = { trouble = tostring(summary) } end
        return out
    end

    --- The city's own record of what went wrong, what was fine, and what was asked.
    local function errors(args)
        local limit = math.tointeger(tonumber(args.limit)) or 50
        if limit < 1 then limit = 1 elseif limit > 256 then limit = 256 end
        return { errors = world:errors(limit), notices = world:notices(limit),
                 audit = world:audit(limit) }
    end

    --- Every command the city defines and what each declares, so a rig can
    --- send each one exactly what it says it does not accept.
    local function commands()
        local out = {}
        for _, name in ipairs(world.commands:names()) do
            out[#out + 1] = world.commands:describe(name)
        end
        return { commands = out, allowed = PlayerCommands.ALLOWED }
    end

    local turned_away = 0
    SetHttpHandler(function(request, response)
        if not DevBridge.admits(request.address, lan()) then
            -- Nothing here, as far as anybody else can tell. Said on the console
            -- a few times, not every time: the refusal must not be a way to
            -- flood the log either.
            turned_away = turned_away + 1
            if turned_away <= 5 then
                log(("the dev bridge turned away a request from %s: it answers this machine on a LAN server only")
                    :format(Bridge.printable(request.address)))
            end
            response.writeHead(404)
            response.send("")
            return
        end
        local path = request.path or "/"
        local route = path:match("^([^?]*)") or "/"
        local answered = false
        local send = function(code, body)
            -- Encoded before anything touches the response: a body that will
            -- not encode is still a request that gets an answer, below.
            local text = json.encode(body)
            answered = true
            response.writeHead(code, { ["Content-Type"] = "application/json; charset=utf-8" })
            response.send(text)
        end

        local ok, err = pcall(function()
            -- Before any route, so no route can act on a city that is not open.
            -- Said in the log as well as in the answer: the client bridge's silent
            -- refusals once cost an afternoon, and the console is where the order
            -- of a request and the city opening can be read afterwards.
            local status, refusal = DevBridge.gate(route, is_open())
            if status then
                log(("the dev bridge was asked for %s before the city was open"):format(path:sub(1, 160)))
                send(status, refusal)
                return
            end

            if route == "/state" or route == "/" then
                send(200, snapshot())
            elseif route == "/log" then
                local args = query_of(path)
                if args.since == nil then
                    send(200, { seq = sequence, log = DevBridge.tail(lines, LOG_LINES) })
                else
                    local drained, why = DevBridge.since(lines, args.since)
                    if not drained then
                        send(400, { ok = false, why = why })
                    else
                        send(200, drained)
                    end
                end
            elseif route == "/errors" then
                send(200, errors(query_of(path)))
            elseif route == "/commands" then
                send(200, commands())
            elseif route == "/verify" then
                local verdict = DevBridge.verify_of(world)
                local counted, summary = pcall(world.summary, world)
                verdict.summary = counted and summary or { trouble = tostring(summary) }
                send(200, verdict)
            elseif route == "/do" then
                local args = query_of(path)
                local command = args.c
                if not command then
                    send(400, { ok = false, why = "no command: /do?p=1&c=me.status&a={}" })
                    return
                end
                -- A player id is a whole number above zero. Handed anything
                -- else, the identifier natives answer nothing on one server
                -- and throw on the other; neither is an answer about a player.
                local player = args.p or "1"
                local who = math.tointeger(tonumber(player))
                if not who or who <= 0 then
                    send(400, { ok = false, why = ("p=%s is not a player id"):format(tostring(player)) })
                    return
                end
                -- `a` is the command's arguments as JSON, and only an object
                -- is arguments. `5`, `"x"` and `{{{` are each something a
                -- client can send and none of them is a request.
                local given = {}
                if args.a ~= nil and args.a ~= "" then
                    given = decode(args.a)
                    if type(given) ~= "table" then
                        send(400, { ok = false, why = "a= must be a JSON object of arguments" })
                        return
                    end
                end
                -- The id that was checked, not the text it came in as: `p=1.0`
                -- passed the check as player 1 and was then looked up as "1.0",
                -- which matched nobody and acted as the account nobody holds.
                local account = account_of(who)
                local sessions = world.services.sessions
                local outcome = world:dispatch(command, given, {
                    account = account,
                    actor = sessions and sessions:character_of(account) or nil,
                    source = "devbridge",
                })
                send(200, { ok = outcome.ok, code = outcome.code,
                            message = outcome.message, value = outcome.value })
            elseif route == "/act" then
                -- Drive the client: open a screen, move the body. The read half of
                -- this bridge says what is on screen; this is what puts something
                -- there, so a session can be recorded without somebody at a
                -- keyboard. LAN only, like everything else here.
                --
                -- Every decision about whether this is a thing that can be done is
                -- in `act_plan` above, where a spec can reach it. What is left here
                -- is the one native call, and an answer that claims only what it
                -- knows: the instruction went to the client. Whether the game did
                -- it is a second claim, and /state is where it is read.
                local plan, why, status = DevBridge.act_plan(query_of(path), GetPlayers())
                if not plan then
                    send(status or 400, { ok = false, why = why })
                    return
                end
                TriggerClientEvent("nyr:dev:act", plan.to, plan.what)
                send(200, { ok = true, to = plan.to, sent = plan.what,
                            note = "sent to the client, not confirmed done: read /state" })
            else
                send(404, { ok = false,
                            why = "try /state, /log, /errors, /commands, /verify, /do or /act" })
            end
        end)

        if not ok then
            -- A route that threw is a finding about the bridge, and it is
            -- answered as one. Left to FiveM the request would simply never
            -- be answered, and from a rig that reads exactly like a server
            -- that has died -- which is found out in a very different way.
            local said = ("dev bridge: %s threw: %s"):format(route, tostring(err))
            log(said)
            if not answered then
                pcall(send, 500, { ok = false, code = "bridge_failed", why = tostring(err) })
            end
        end
    end)

    -- The port comes from the server, not from a constant. A boot probe picks
    -- a free port, so a printed 30120 sent a reader to whichever server was
    -- already there -- which is the same mistake in a message that the probe
    -- itself used to make in a socket.
    --
    -- Asked from inside a thread rather than here, because `netPort` is not
    -- readable yet while a resource is still loading. Measured on both, with
    -- the same probe:
    --
    --                      at script load   in a thread body
    --     legacy 35245         30151             30151
    --     enhanced 139             0             30150
    --
    -- So the name was never wrong and the moment was. This printed port 0 on
    -- Enhanced for as long as nobody read the line on that server, because on
    -- Legacy it was right from the first line of the file.
    CreateThread(function()
        print(DevBridge.where(GetConvarInt and GetConvarInt("netPort", 0) or 0,
                              GetCurrentResourceName()))
    end)
end

return DevBridge
