--- The part of the client that is not natives.
--
-- A client is mostly calls into the game, which cannot be tested outside it.
-- What can be tested is everything else: matching an answer to the question
-- that asked it, giving up when no answer comes, holding the last thing the
-- server said so a display has something to draw, and turning an outcome into
-- a line a person reads. All of that is here, as plain Lua with no natives in
-- it, so it runs in the spec suite.
--
-- The rule this file exists to keep: **the client decides nothing.** It holds
-- what it was told and shows it. It does not work out whether something is
-- affordable, allowed, in range or in stock, because a client that knows what
-- it is not allowed to do is a client that can be edited to allow it. Every
-- refusal is text to display, never a branch to act on.

local ClientState = {}
ClientState.__index = ClientState

local DEFAULT_TIMEOUT_MS = 15000

--- opts.timeout_ms  how long to wait before giving up on an answer
--- opts.now         function returning a millisecond count
function ClientState.new(opts)
    opts = opts or {}
    return setmetatable({
        _pending = {},
        _view = {},
        _timeout = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
        _now = opts.now or function() return 0 end,
        _counter = 0,
        _session = opts.session,
    }, ClientState)
end

--- A token for one request. Only ever used to match an answer to a question:
--- the server namespaces it by account before it means anything, so it is not
--- a thing to guess at.
function ClientState:token()
    self._counter = self._counter + 1
    local token = ("%d-%d"):format(self._now(), self._counter)
    return self._session and (self._session .. "-" .. token) or token
end

function ClientState:open(token, handler)
    self._pending[token] = { at = self._now(), handler = handler }
    return token
end

function ClientState:pending_count()
    local n = 0
    for _ in pairs(self._pending) do n = n + 1 end
    return n
end

--- A late wire answer cannot revive callbacks from before a world transition.
function ClientState:cancel(outcome)
    local pending = self._pending
    self._pending = {}
    for _, waiting in pairs(pending) do
        if waiting.handler then pcall(waiting.handler, { ok = false, code = "outcome_unknown",
            message = "The connection changed after sending. Refresh the result before retrying.",
            cause = outcome.code }) end
    end
end

--- Deliver an answer. Returns the handler that was waiting, or nil when
--- nothing was: an answer to a question nobody asked is dropped rather than
--- acted on, because it did not come from anything this client did.
function ClientState:reply(token, outcome)
    local waiting = self._pending[token]
    if not waiting then return nil end
    self._pending[token] = nil
    return waiting.handler, outcome
end

--- Everything that has waited too long, as token and a synthetic outcome. The
--- outcome is shaped exactly like a real one so a caller never has to tell the
--- difference between "refused" and "never answered".
function ClientState:expire()
    local now, out = self._now(), {}
    for token, waiting in pairs(self._pending) do
        local elapsed = now - waiting.at
        if elapsed < 0 or elapsed >= self._timeout then
            self._pending[token] = nil
            out[#out + 1] = {
                token = token,
                handler = waiting.handler,
                outcome = { ok = false, code = "no_answer",
                            message = "The server did not answer." },
            }
        end
    end
    table.sort(out, function(a, b) return a.token < b.token end)
    return out
end

-- --------------------------------------------------------------- the view

--- Hold what the server last said. This is a cache for drawing, and it is
--- never consulted to decide anything: every question goes back to the server.
function ClientState:remember(key, value)
    self._view[key] = value
    return value
end

function ClientState:view(key)
    if key == nil then return self._view end
    return self._view[key]
end

function ClientState:forget()
    self._view = {}
end

-- ---------------------------------------------------------------- display

--- Money as a person reads it. Integer arithmetic throughout, because the
--- display of a number that is exact everywhere else should not be the place
--- it stops being exact.
function ClientState.money(minor)
    if math.type(minor) ~= "integer" then return "?" end
    local negative = minor < 0
    local whole = (negative and -minor or minor) // 100
    local part = (negative and -minor or minor) % 100
    local text = tostring(whole)
    local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return ("%s$%s.%02d"):format(negative and "-" or "", grouped, part)
end

--- Dollars as a person types them, as whole cents, or nil.
---
--- "200", "200.5", "200.50", "$1,200.00". The box at a bank counter used to send
--- what was typed as the amount, and the amount is cents: on 2026-09-13 somebody
--- typed 200 and paid in $2.00. Read as two whole numbers, never through a float,
--- because the ledger is whole cents. A negative is not money here; whether an
--- amount is allowed at all is still the server's to say.
---
--- It lives beside `money`, its other half, because two doors use it: the bank
--- screen through `nui_state`, and every chat command that moves money through
--- `commands`. Chat had its own reading, a whole number of cents, and went on
--- moving two dollars for 200 for two days after the screen stopped.
function ClientState.cents(typed)
    if type(typed) ~= "string" then return nil end
    -- A literal space rather than %s, the same as every other trim here.
    local text = typed:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
    text = text:gsub("^%$", "", 1)
    local whole, fraction = text:match("^([%d,]+)%.(%d%d?)$")
    if not whole then whole = text:match("^([%d,]+)$") end
    if not whole or not whole:match("^%d") then return nil end
    if whole:find(",", 1, true) then
        -- Thousands separators, and only those: 1,200 is money and 1,20 is not.
        local groups = {}
        for group in (whole .. ","):gmatch("([^,]*),") do groups[#groups + 1] = group end
        if not groups[1]:match("^%d%d?%d?$") then return nil end
        for i = 2, #groups do
            if not groups[i]:match("^%d%d%d$") then return nil end
        end
        whole = whole:gsub(",", "")
    end
    if #whole > 12 then return nil end
    local dollars = math.tointeger(tonumber(whole))
    if not dollars then return nil end
    local minor = 0
    if fraction then
        minor = math.tointeger(tonumber(fraction)) * (#fraction == 1 and 10 or 1)
    end
    return dollars * 100 + minor
end

--- The line to show a player for an outcome.
---
--- A failure never shows its message. That text is a stack trace or an
--- internal name, it is for the server log, and handing it to whoever is
--- poking at the server tells them where to poke next.
function ClientState.say(outcome)
    if type(outcome) ~= "table" then return "Something went wrong." end
    if outcome.ok then return nil end
    if outcome.code == "failed" then return "Something went wrong. It has been logged." end
    if outcome.code == "no_answer" then return "The server did not answer." end
    if type(outcome.message) == "string" and outcome.message ~= "" then
        return outcome.message
    end
    return "That is not something you can do."
end

--- Where a line meant for a player should be sent.
---
--- `chat:addMessage` is another resource's event, and this one assumed it was
--- always there. On a server with no chat resource nothing listens, every line
--- this resource says to a player is dropped, and the player sees exactly what
--- they would see if the command did not exist. Three rounds of "it works"
--- came back from a client in that state before anybody noticed.
---
--- `chat` stays on whatever the answer is, because a server may listen for
--- that event under a resource called something else and it costs nothing to
--- trigger an event nobody handles. The game's own feed is added only when
--- nothing named `chat` is running, so a stock server behaves exactly as it
--- did. The console is always on: it is free, it is not on screen, and it
--- means the answer is somewhere even when both of the others are wrong.
---
--- The one case this gets mildly wrong is a server whose chat resource has
--- another name, which sees a line twice. Twice is a great deal better than
--- never.
function ClientState.channels(chat_state)
    local running = chat_state == "started"
    return { chat = true, notify = not running, console = true }
end

-- ------------------------------------------------------- what chat says back

local money = ClientState.money

--- How an answer to a chat command is shown. Anything without an entry shows
--- "done", which is the right default: a refusal has already been said by
--- `say`, and the server already said the thing worth saying.
local SHOW = {
    ["me.status"] = function(value)
        -- Appended one at a time. This was one table literal with
        -- `value.account and ... or nil` in the middle of it, and a nil in a
        -- literal ends the list for ipairs: anybody without a bank account was
        -- told their name and their money, and not their phone number or the
        -- time.
        local lines = { ("%s  (%s)"):format(value.name, value.state) }
        local hud = ClientState.hud(value)
        if hud ~= "" then lines[#lines + 1] = hud end
        if value.account then lines[#lines + 1] = ("account %s"):format(value.account) end
        if value.phone then lines[#lines + 1] = ("phone %s"):format(value.phone) end
        if value.at then lines[#lines + 1] = tostring(value.at) end
        return lines
    end,
    ["me.pockets"] = function(value)
        local lines = { ("carrying %d of %d slots, %dg of %dg"):format(
            value.slots_used, value.slots or 0, value.weight, value.capacity or 0) }
        for _, row in ipairs(value.items) do
            lines[#lines + 1] = ("  %-24s x%d"):format(row.label, row.count)
        end
        return lines
    end,
    ["bank.statement"] = function(value)
        local lines = { ("%s   %s"):format(value.number, money(value.balance)) }
        for _, row in ipairs(value.lines) do
            lines[#lines + 1] = ("  %-12s %s"):format(row.reason or "", money(row.amount))
        end
        return lines
    end,
    ["shop.list"] = function(value)
        local lines = { ("%s (%s)"):format(value.name, value.state) }
        for _, row in ipairs(value.lines) do
            lines[#lines + 1] = ("  %-22s buy %s   sell %s   stock %d"):format(
                row.label,
                row.buy and money(row.buy) or "-",
                row.sell and money(row.sell) or "-",
                row.stock)
        end
        return lines
    end,
    ["fence.list"] = function(value)
        local lines = { ("%s%s"):format(value.name, value.chops and " (takes cars)" or "") }
        for _, row in ipairs(value.lines) do
            lines[#lines + 1] = ("  %-22s %s"):format(row.label, money(row.pays))
        end
        return lines
    end,
    ["gang.roster"] = function(value)
        local lines = { ("%s [%s]   treasury %s"):format(
            value.name, value.tag, money(value.treasury)) }
        for _, row in ipairs(value.members) do
            lines[#lines + 1] = ("  %-26s %s"):format(row.character, row.title)
        end
        return lines
    end,
    ["phone.inbox"] = function(value)
        local lines = { ("your number is %s"):format(value.number) }
        for _, row in ipairs(value.threads) do
            lines[#lines + 1] = ("  %-12s %s%s"):format(
                row.number, row.outgoing and "you: " or "", row.last)
        end
        return lines
    end,
    ["phone.thread"] = function(value)
        local lines = {}
        for _, row in ipairs(value.messages) do
            lines[#lines + 1] = ("  %-12s %s"):format(row.from, row.body)
        end
        if #lines == 0 then lines[1] = "nothing between you" end
        return lines
    end,
    ["record.mine"] = function(value)
        local lines = { ("heat %d"):format(value.heat or 0) }
        for _, row in ipairs(value.records) do
            lines[#lines + 1] = ("  %-22s %s"):format(row.kind,
                row.witnessed and "seen" or "unseen")
        end
        return lines
    end,
    ["admin.who"] = function(value)
        local lines = {}
        for _, row in ipairs(value.online) do
            lines[#lines + 1] = ("  %-26s %-20s %s"):format(row.character, row.name, row.state)
        end
        return lines
    end,
    ["admin.trail"] = function(value)
        local lines = {}
        for _, row in ipairs(value.actions) do
            lines[#lines + 1] = ("  %-8s %-26s %s"):format(
                row.action or "?", row.on or "-", row.reason or "")
        end
        return lines
    end,
}

--- What a command that moves money says it moved.
---
--- Every one of these said "done". So did the same commands while 500 typed
--- meant five dollars, and a player listing a flat for $30.00 instead of $3,000
--- was told "done" in the same words as one who had it right. The amount is
--- the server's where it answers with one, and otherwise what was sent, which
--- the server moves exactly or refuses. Each gets `value` as a table, empty
--- when the answer carried none, and the arguments that were sent.
local MOVED = {
    ["bank.deposit"] = function(value, args)
        local line = ("paid in %s"):format(money(args.amount))
        if value.balance then line = line .. (", balance %s"):format(money(value.balance)) end
        return { line }
    end,
    ["bank.withdraw"] = function(value, args)
        local line = ("took out %s"):format(money(args.amount))
        if value.balance then line = line .. (", balance %s"):format(money(value.balance)) end
        return { line }
    end,
    ["bank.transfer"] = function(value, args)
        -- What arrived is `sent`: a fee comes out of the amount, not on top.
        local line = ("sent %s to %s"):format(money(value.sent or args.amount), tostring(args.to))
        if math.type(value.fee) == "integer" and value.fee > 0 then
            line = line .. (", fee %s"):format(money(value.fee))
        end
        if value.balance then line = line .. (", balance %s"):format(money(value.balance)) end
        return { line }
    end,
    ["gang.deposit"] = function(value, args)
        local line = ("put %s in the treasury"):format(money(args.amount))
        if value.treasury then line = line .. (", which holds %s"):format(money(value.treasury)) end
        return { line }
    end,
    ["gang.withdraw"] = function(value, args)
        local line = ("took %s from the treasury"):format(money(args.amount))
        if value.treasury then line = line .. (", which holds %s"):format(money(value.treasury)) end
        return { line }
    end,
    ["admin.give"] = function(value, args)
        return { ("gave %s to %s"):format(money(value.amount or args.amount), tostring(args.character)) }
    end,
    ["admin.take"] = function(value, args)
        return { ("took %s from %s"):format(money(value.amount or args.amount), tostring(args.character)) }
    end,
    ["health.respawn"] = function(value)
        local line = ("you wake up with %s health"):format(tostring(value.hp or "some"))
        if math.type(value.paid) == "integer" and value.paid > 0 then
            line = line .. ("; the hospital took %s"):format(money(value.paid))
        end
        return { line }
    end,
    ["property.list"] = function(_, args)
        -- The answer carries nothing, so the price is the one sent. Leaving it
        -- out keeps the price the place already had, which this does not know.
        if args.price then return { ("on the market at %s"):format(money(args.price)) } end
        return { "on the market" }
    end,
}

--- The lines a player reads for a chat command that worked.
---
--- `value` is what the server answered with and `args` what was sent. Lives
--- here rather than in `adapter/client.lua`, which no spec can load, so that
--- what a command says it did is something a spec reads.
function ClientState.answer(command, value, args)
    local moved = MOVED[command]
    if moved then
        return moved(type(value) == "table" and value or {}, type(args) == "table" and args or {})
    end
    local show = SHOW[command]
    if show and type(value) == "table" then return show(value) end
    return { "done" }
end

-- ------------------------------------------------------- finding things

--- What to put on the map for one place, or nothing.
---
--- Until this existed the resource drew no blips, no markers and no prompts at
--- all, so the only way to find a shop was to already know where it was and
--- press F5 standing on top of it. A city nobody can navigate is a city with
--- one player: the person who wrote the settings file.
---
--- Sprite and colour are GTA's own numbers. A kind nothing is listed for gets
--- no blip rather than a default one, because a map full of identical marks is
--- the same as no map.
local BLIPS = {
    shop      = { sprite = 52,  colour = 2,  name = "Shop" },
    bank      = { sprite = 108, colour = 2,  name = "Bank" },
    apartment = { sprite = 40,  colour = 3,  name = "For sale" },
    house     = { sprite = 40,  colour = 3,  name = "For sale" },
}

function ClientState.blip(place)
    if type(place) ~= "table" then return nil end
    local kind = place.kind
    -- A home is only worth marking while somebody could buy it. One already
    -- lived in is scenery, and marking every door in the city is noise.
    if kind == "apartment" or kind == "house" then
        if place.for_sale ~= true then return nil end
    end
    -- Premises of the shop kind with no counter in them -- the fence's
    -- scrapyard -- have nothing a key opens. The mark was chosen by kind and the
    -- light, the prompt and the key by the counter, so the scrapyard sat on the
    -- map as a Shop that led nowhere.
    if kind == "shop" and not place.shop then return nil end
    local blip = BLIPS[kind]
    if not blip then return nil end
    return {
        sprite = blip.sprite,
        colour = blip.colour,
        -- The shop's own name where it has one, because that is what somebody
        -- is looking for on a map.
        label = place.name or blip.name,
    }
end

--- The line above the ground when somebody is close enough to act.
---
--- Nil where there is nothing to press. A prompt that leads nowhere is worse
--- than no prompt: it is a promise the city does not keep, and this city still
--- has no screen for banking.
function ClientState.prompt(place)
    if type(place) ~= "table" then return nil end
    if place.shop then
        return ("~INPUT_CONTEXT~  %s"):format(place.name or "Shop")
    end
    -- A bank had a blip and no prompt while there was no banking screen for a
    -- key to open, because a promise the city does not keep is worse than
    -- silence. There is one now.
    if place.kind == "bank" then
        return ("~INPUT_CONTEXT~  %s"):format(place.name or "Bank")
    end
    if place.for_sale == true then
        return ("~INPUT_CONTEXT~  %s   %s"):format(
            place.name or "For sale", ClientState.money(place.price))
    end
    return nil
end

--- What a place looks like on the ground, or nothing.
---
--- Same rule as the prompt: a marker is drawn where there is something to walk
--- up to. Colour follows the blip so the map and the world agree.
local MARKER = { shop = { 240, 200, 120 }, bank = { 150, 200, 170 },
                 sale = { 217, 154, 63 } }

function ClientState.marker(place)
    if type(place) ~= "table" then return nil end
    if place.shop then return { colour = MARKER.shop, height = 0.6 } end
    if place.kind == "bank" then return { colour = MARKER.bank, height = 0.6 } end
    if place.for_sale == true then return { colour = MARKER.sale, height = 0.6 } end
    return nil
end

--- Which screen pressing the key should open at this place.
---
--- The screen, not the command: a player presses one key and the interface
--- takes over, the same as F3 or F5. A place with no screen returns nothing
--- and draws no prompt, which is why banking has neither yet.
function ClientState.opens(place)
    if type(place) ~= "table" then return nil end
    if place.shop then return "shop", place.shop end
    -- The branch, because every button the bank screen draws has to name which
    -- one it is standing at -- the server decides whether it is.
    if place.kind == "bank" then return "bank", place.place end
    if place.for_sale == true then return "nearby", nil end
    return nil
end

--- How often the map is read again, and how close together two reads may be.
---
--- It was read once, at spawn. A flat that sold kept its mark, its light and its
--- "press E ... $2,500.00" on every other player's screen for as long as they
--- stayed, and a flat put on the market after they joined never appeared.
--- `every_ms` brings in what other people did; a door this client bought or
--- listed asks sooner. `me.map` allows six reads a minute, and `gap_ms` holds
--- every read, however it was asked for, to three.
ClientState.MAP_READ = { every_ms = 120000, gap_ms = 20000 }

--- Whether to ask for the map now.
---
--- now     milliseconds
--- last    when it was last asked for, or nil when it never has been
--- wanted  something this client did has changed it
--- marked  whether any answer has been drawn yet: the spawn's read can come
---         before the city has opened, and a map with no marks on it looks
---         exactly like a city with nothing in it
function ClientState.map_due(now, last, wanted, marked)
    if last == nil then return true end
    local since = now - last
    if since < ClientState.MAP_READ.gap_ms then return false end
    if wanted or not marked then return true end
    return since >= ClientState.MAP_READ.every_ms
end

--- How near is near enough, in metres.
---
--- `draw` is when a marker appears, `act` is when the key works. The second is
--- deliberately larger than a place's own radius is small: the server decides
--- whether somebody is close enough to trade, and this only decides when to
--- offer. Offering slightly too eagerly costs a refusal; offering too late
--- costs a player who never finds out the place is interactive at all.
ClientState.NEAR = { draw = 25.0, act = 3.0 }

--- Where the status line is drawn, as a share of the screen.
---
--- It was drawn at 0.012, 0.016: the top-left corner, which is where the game
--- draws help text, and the press-E prompt at every counter, branch and door is
--- help text. The 2026-09-13 recording shows the two on top of each other.
--- Top centre is clear of the prompt.
ClientState.HUD_AT = { x = 0.5, y = 0.012, centre = true }

--- One line of heads-up display from a me.status answer. Built from whatever
--- fields are present, because a server without banking has no bank line and
--- should not have a gap where one would be.
function ClientState.hud(status)
    if type(status) ~= "table" then return "" end
    local parts = {}
    if status.wallet then parts[#parts + 1] = ClientState.money(status.wallet) end
    if status.bank then parts[#parts + 1] = "bank " .. ClientState.money(status.bank) end
    if status.hp then parts[#parts + 1] = ("hp %d"):format(status.hp) end
    if status.condition and status.condition ~= "well" then
        parts[#parts + 1] = status.condition
    end
    if status.heat and status.heat > 0 then parts[#parts + 1] = ("heat %d"):format(status.heat) end
    if status.crew_tag then parts[#parts + 1] = "[" .. status.crew_tag .. "]" end
    if status.on_duty then parts[#parts + 1] = "on duty" end
    if status.working then parts[#parts + 1] = "working " .. status.working end
    return table.concat(parts, "   ")
end

-- ------------------------------------------------------------------ a body

--- Where everybody arrives: Legion Square. Central, flat, and the one place
--- measured to hold a body -- on 2026-09-13 the lowest point over 45 seconds
--- after a join was the ground.
ClientState.SPAWN = { x = 195.17, y = -933.77, z = 30.69, heading = 145.0 }

--- Where to stand a body up: "here", where it lies, or "spawn".
---
--- A respawn is "wake up at the hospital", and the city has no hospital as a
--- place yet, so the body goes to the spawn: the one spot known to have ground
--- under it. A position nobody has measured is how a body ends up under the map.
---
--- `here` is whatever GetEntityCoords handed back, which in the game is a
--- vector3 and not a table: `type()` of one says "vector3". So it is read by its
--- fields and never checked for being a table, which every spec would pass and
--- every revive in the game would fail.
function ClientState.stand_at(where, here, heading)
    if where == "spawn" then return ClientState.SPAWN end
    if where ~= "here" or here == nil then return nil end
    local read, x, y, z = pcall(function() return here.x, here.y, here.z end)
    if not read or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z, heading = type(heading) == "number" and heading or 0.0 }
end

--- What the client does as its script starts: "spawn" a body into the city, or
--- only "announce" that there already is one.
---
--- The spawn ran whenever its script started, and `restart nyr_underworld`
--- starts every client script again for everybody connected: every player in the
--- city was given a new model, moved to Legion Square and frozen for as long as
--- the ground took. A join arrives behind the loading screen and a restart does
--- not, so only the one case that is plainly a restart -- no loading screen, and
--- a body standing there -- is left alone. Anything unsure spawns, as every join
--- always has, because a player left with no body is worse than one moved.
function ClientState.arrival(loading, body)
    if loading == false and body == true then return "announce" end
    return "spawn"
end

--- `grace_ms`: how long after the game says a body died before the server's
--- word on it counts. The server reads every ped's health from its own copy once
--- a second, so an answer to a question asked sooner can say "well" about a body
--- that has just died -- and standing it up then would undo a death the server
--- never got to count. `remind_ms`: how often a player lying there is told again.
ClientState.BODY = { grace_ms = 5000, remind_ms = 30000 }

--- What a player lying dead reads, by what the server says they are.
local LYING = {
    down = "You are down. Somebody can still bring you round.",
    dead = "You are gone. Type /nyrrespawn to wake up at the hospital.",
}

local Body = {}
Body.__index = Body

--- What to do about the player's body, which only the game can see and only the
--- server can judge.
---
--- The body was resurrected once, at the join, and never again. On a server
--- with no spawnmanager -- every Enhanced server -- a player killed in the world
--- stayed a corpse: `/nyrrespawn` was answered and paid for, a medic's revive
--- reached the server, the server's numbers said the person was on their feet,
--- and the body lay where it fell with nothing on screen saying what to do.
---
--- The game says whether the body is dead (`seen`); the server says what the
--- person is (`said`). Nothing here decides that anybody is hurt or healed: a
--- body is stood up only because the server says its person is well.
---
--- opts.now  function returning a millisecond count
function ClientState.body(opts)
    opts = opts or {}
    return setmetatable({
        _now = opts.now or function() return 0 end,
        _grace = opts.grace_ms or ClientState.BODY.grace_ms,
        _remind = opts.remind_ms or ClientState.BODY.remind_ms,
        _dead_since = nil,
        _condition = nil,
        _standing = false,
        _told = nil,
        _told_at = nil,
    }, Body)
end

--- The game's word on the body. Returns a line to say to the player, or nil.
function Body:seen(dead)
    if dead ~= true then
        self._dead_since, self._told, self._told_at = nil, nil, nil
        return nil
    end
    local now = self._now()
    if self._dead_since == nil then self._dead_since = now end
    if self._standing then return nil end
    local line = LYING[self._condition]
    if line == nil then return nil end
    if line ~= self._told or now - self._told_at >= self._remind then
        self._told, self._told_at = line, now
        return line
    end
    return nil
end

--- The server's word, from a `me.status` answer to a question asked at
--- `asked_at`. Returns "here" when the body should be stood up where it lies.
function Body:said(condition, asked_at)
    self._condition = condition
    if self._standing or self._dead_since == nil then return nil end
    if condition ~= "well" then return nil end
    if math.type(asked_at) ~= "integer" or asked_at < self._dead_since + self._grace then
        return nil
    end
    return "here"
end

--- Whether a body is being stood up now. Nothing is told, and nothing is stood
--- up a second time, until it is done.
function Body:standing(yes)
    self._standing = yes == true
    if self._standing then self._told, self._told_at = nil, nil end
end

function Body:is_dead() return self._dead_since ~= nil end

--- What an answered command sets going on this machine, beyond saying so.
---
--- `stand`: where to stand the body up. A respawn that worked is the server
--- saying the person woke up at the hospital, and it was answered while the
--- body lay where it fell.
---
--- `map`: the map is out of date. A door bought or put up for sale changes what
--- is marked, and the map was only ever read at spawn.
function ClientState.follows(command, outcome)
    if type(outcome) ~= "table" or outcome.ok ~= true then return {} end
    if command == "health.respawn" then return { stand = "spawn" } end
    if command == "property.buy" or command == "property.list" then return { map = true } end
    return {}
end

-- Client scripts share one namespace, so this is how client.lua reaches it.
-- The return is for the spec suite, which loads the same file under a plain
-- interpreter: one file, tested where it can be tested, used where it is used.
NyrClientState = ClientState

return ClientState
