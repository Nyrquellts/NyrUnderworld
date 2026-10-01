--- The drawn interface, wired to the game.
--
-- Everything with an opinion in it lives in `adapter/nui_state.lua`, which is
-- plain Lua and is tested. This file is the part that cannot be tested outside
-- the game: registering callbacks, sending messages to the page, and taking
-- the mouse.
--
-- The shape it keeps: a callback from the page is checked against the declared
-- set before it becomes anything, the server is asked, and the page is told
-- what the server said. The page is never told why. A NUI page is a browser on
-- the player's own machine with developer tools in it, so it is treated as the
-- least trustworthy thing in the client, and the client was already untrusted.

local PICKER_OPEN_AFTER_MS = 2500

local open = false
local showing = nil
local shown_stash, shown_stash_address

-- How many times the interface has been closed, the Lua half of the page's own
-- count. Go in answers the page and then reads the stash, and Escape in the
-- middle of that closed the page and gave the mouse back -- and then the read
-- landed, put the stash up and took the mouse again. A read that began before
-- the last close draws nothing.
local closings = 0

--- What the picker is doing, for the development bridge to read. Costs
--- nothing when nothing is asking.
function NyrPickerIsOpen() return open end
function NyrPickerShowing() return showing end

-- Who the last list said this account is playing, which is what the picker was
-- drawn from. Kept so that Play on somebody else can let go of them first; see
-- `NuiState.steps`.
local shown_playing = nil

--- Ask the server who this account can play. `done(value)` gets the answer, or
--- nil when the read itself was refused.
local function read(done)
    NyrAsk("character.list", {}, function(outcome)
        if type(outcome) == "table" and outcome.ok then
            shown_playing = type(outcome.value) == "table" and outcome.value.playing or nil
            done(outcome.value)
        else
            done(nil, outcome)
        end
    end)
end

--- Ask each request in turn, and hand `done` the last one's answer. Every one
--- is asked whatever the one before it said: which requests to make, and why a
--- refused one before the last is no reason to stop, is `NuiState.steps`.
local function in_turn(steps, done, from)
    local index = from or 1
    local step = steps[index]
    NyrAsk(step.command, step.args, function(outcome)
        if index >= #steps then
            done(outcome)
        else
            in_turn(steps, done, index + 1)
        end
    end)
end

local function show(value, message, ok)
    local view = NyrNuiState.picker(value)
    showing = message or (view.empty and "picker: nobody yet"
                          or ("picker: %d people"):format(view.used))
    SendNUIMessage({
        type = "picker",
        view = view,
        message = message,
        ok = ok,
    })
    if not open then
        SetNuiFocus(true, true)
        open = true
    end
end

function NyrPickerClose()
    closings = closings + 1
    if not open then return end
    open = false
    showing = nil
    shown_stash, shown_stash_address = nil, nil
    SetNuiFocus(false, false)
    SendNUIMessage({ type = "hide" })
end

--- Open the picker with nothing in it, and the reason printed on it.
---
--- This used to return without drawing anything and print to a console nobody
--- was looking at. What a player got was a black screen, with no way to tell a
--- refusal from a crash from a resource that never started. A screen that says
--- why is worth more than no screen, every time.
local function show_refusal(refused)
    local why = NyrClientState.say(refused) or "The server did not answer."
    print(("[nyr] the picker opened with nothing in it: %s"):format(why))
    show(nil, why, false)
end

function NyrPickerOpen()
    read(function(value, refused)
        if value then show(value) else show_refusal(refused) end
    end)
end

-- ----------------------------------------------------------------- pockets

--- Ask what the acting character is carrying.
local function read_pockets(done)
    NyrAsk("me.pockets", {}, function(outcome)
        if type(outcome) == "table" and outcome.ok then done(outcome.value) else done(nil, outcome) end
    end)
end

function NyrPocketsOpen()
    read_pockets(function(value, refused)
        showing = value and "pockets" or "pockets: nothing"
        SendNUIMessage({
            type = "pockets",
            view = NyrNuiState.pockets(value),
            message = not value and (NyrClientState.say(refused) or "The server did not answer.") or nil,
            ok = value ~= nil,
        })
        if not open then
            SetNuiFocus(true, true)
            open = true
        end
    end)
end

-- ------------------------------------------------------------------- phone

--- The phone is two reads: who has been in touch, and one conversation. They
--- are asked separately because the server answers them separately, and the
--- page is given both at once because that is what it draws. `done` gets both
--- answers as they came, refusals and all; what is drawn from them is the
--- caller's, because a refused read drawn as an empty phone is the defect.
local function read_phone(with, done)
    NyrAsk("phone.inbox", {}, function(inbox)
        if not with then
            done(inbox, nil)
            return
        end
        NyrAsk("phone.thread", { with = with }, function(thread)
            done(inbox, thread)
        end)
    end)
end

local function show_phone(inbox, thread, refused)
    showing = inbox and "phone" or "phone: nothing"
    SendNUIMessage({
        type = "phone",
        view = { inbox = NyrNuiState.inbox(inbox), thread = thread and NyrNuiState.thread(thread) or nil },
        message = refused and (NyrClientState.say(refused) or "The server did not answer.") or nil,
        ok = inbox ~= nil,
    })
    if not open then
        SetNuiFocus(true, true)
        open = true
    end
end

function NyrPhoneOpen()
    read_phone(nil, function(inbox)
        local inbox_value = type(inbox) == "table" and inbox.ok and inbox.value or nil
        -- Written out. `inbox_value and nil or inbox` is `inbox` whichever way
        -- the read went, so every phone that opened fine opened on "The server
        -- did not answer."
        local refused = nil
        if inbox_value == nil then refused = inbox end
        show_phone(inbox_value, nil, refused)
    end)
end

-- ----------------------------------------------------------- around you

--- Ask for one command and hand the answer straight on. Most of the screens
--- below are one read and one drawing, and writing that out five times is
--- five chances to get it slightly different.
local function one(command, args, kind, build, extra)
    NyrAsk(command, args or {}, function(outcome)
        local ok = type(outcome) == "table" and outcome.ok
        local message = nil
        if not ok then
            message = NyrClientState.say(outcome) or "The server did not answer."
        end
        showing = kind .. (ok and "" or ": nothing")
        local payload = { type = kind, view = build(ok and outcome.value or nil),
                          message = message, ok = ok == true }
        for key, value in pairs(extra or {}) do payload[key] = value end
        SendNUIMessage(payload)
        if not open then
            SetNuiFocus(true, true)
            open = true
        end
    end)
end

-- The answer Around you was last drawn from, so a door is bought at the price
-- it was drawn with; see `NuiState.priced`.
local shown_nearby = nil

function NyrNearbyOpen()
    one("me.nearby", {}, "nearby", function(value)
        shown_nearby = value
        return NyrNuiState.nearby(value)
    end)
end

--- A bank counter. `branch` is the place, carried back to the page so every
--- button it draws names which branch it is standing at -- the same way the
--- shop screen carries its shop.
function NyrBankOpen(branch)
    one("bank.statement", {}, "bank",
        function(value) return NyrNuiState.bank(value) end, { branch = branch })
end

--- Who is hiring. No branch and no place: an employer here is external, so
--- there is nowhere to stand and this opens on a key like the pockets do.
function NyrJobsOpen()
    one("work.list", {}, "jobs", function(value) return NyrNuiState.jobs(value) end)
end

function NyrShopOpen(shop)
    one("shop.list", { shop = shop }, "shop",
        function(value) return NyrNuiState.shop(value) end, { shop = shop })
end

-- ------------------------------------------------------------- a stash
--
-- Entering is what grants reach to a stash, so the screen cannot be drawn
-- before it happens: without the entry every move is refused, which is the
-- point of the entry. The three reads run in order for that reason, not for
-- tidiness.

local function show_stash(stash, address, pockets, contents, message)
    showing = stash and "stash" or "stash: nothing"
    shown_stash, shown_stash_address = stash, address
    SendNUIMessage({
        type = "stash",
        view = NyrNuiState.stash(pockets, contents,
            { pockets = pockets and pockets.container, stash = stash, address = address }),
        message = message, ok = message == nil,
    })
    if not open then
        SetNuiFocus(true, true)
        open = true
    end
end

--- Read both containers and draw them side by side.
local function read_stash(stash, address)
    local asked = closings
    NyrAsk("me.pockets", {}, function(mine)
        if asked ~= closings then return end
        local pockets = type(mine) == "table" and mine.ok and mine.value or nil
        if not pockets then
            show_stash(stash, address, nil, nil, NyrClientState.say(mine))
            return
        end
        -- The stash's own contents come from the same read, asked about the
        -- other container. A screen that guessed at them would be drawing
        -- something nobody said.
        NyrAsk("inventory.look", { container = stash }, function(theirs)
            if asked ~= closings then return end
            -- A stash that could not be read is not an empty one. It was drawn
            -- as "Nothing put down yet." and reported to the page as opened.
            local contents = type(theirs) == "table" and theirs.ok and theirs.value or nil
            local message = nil
            if contents == nil then
                message = NyrClientState.say(theirs) or "The server did not answer."
            end
            show_stash(stash, address, pockets, contents, message)
        end)
    end)
end

function NyrStashOpen(place)
    NyrAsk("property.enter", { place = place }, function(outcome)
        if type(outcome) ~= "table" or not outcome.ok then
            SendNUIMessage({ type = "stash", view = NyrNuiState.stash(nil, nil, {}),
                             message = NyrClientState.say(outcome) or "The server did not answer.",
                             ok = false })
            if not open then
                SetNuiFocus(true, true)
                open = true
            end
            return
        end
        read_stash(outcome.value and outcome.value.stash, outcome.value and outcome.value.address)
    end)
end

-- --------------------------------------------------------------- callbacks

--- One endpoint per declared action and no endpoint for anything else, so an
--- undeclared action has nothing to call. `NyrNuiState.request` refuses it a
--- second time anyway: the two together are why a page with developer tools
--- open is not a way into the server.
for _, action in ipairs(NyrNuiState.actions()) do
    RegisterNUICallback(action, function(payload, send_back)
        -- On a refusal the second return is the line to show; on a request it
        -- is the arguments. There is only ever one of the two.
        local command, args_or_why = NyrNuiState.request(action, payload)
        if not command then
            send_back({ ok = false, message = args_or_why })
            return
        end
        -- Everything below answers through this, so something that worked says
        -- so, in a line decided in nui_state.
        local function respond(reply)
            send_back(NyrNuiState.told(action, args_or_why, reply))
        end
        -- Usually the one request. Play on somebody else is two, and which is
        -- decided in nui_state.
        args_or_why = NyrNuiState.priced(action, args_or_why, shown_nearby)
        in_turn(NyrNuiState.steps(action, command, args_or_why, shown_playing), function(outcome)
            if type(outcome) ~= "table" or not outcome.ok then
                respond(NyrNuiState.reply(outcome))
                return
            end
            -- The same as a chat command: a door bought here changes the map,
            -- which was otherwise read at spawn and never again.
            if NyrClientState.follows(command, outcome).map and NyrWorldRefresh then
                NyrWorldRefresh()
            end
            -- Read back rather than assume. The page draws what the server now
            -- says, never what the press was expected to do -- and it reads
            -- back through the screen the action belongs to, so dropping a
            -- thing redraws the pockets and sending a message redraws the
            -- conversation. A read back that fails draws nothing, and says so:
            -- `NuiState.read_back`.
            if action == "drop" or action == "use" then
                NyrAsk("me.pockets", {}, function(mine)
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.pockets, mine))
                end)
            elseif action == "shop" then
                -- The action is itself the read. It was read back with a second
                -- shop.list, so every press of Counter asked twice against a
                -- limit of thirty a minute.
                respond(NyrNuiState.read_back(outcome, NyrNuiState.shop, outcome))
            elseif action == "buy" or action == "sell" then
                NyrAsk("shop.list", { shop = args_or_why.shop }, function(listed)
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.shop, listed))
                end)
            elseif action == "account" or action == "deposit" or action == "withdraw" then
                -- Read the account back rather than trusting the move. What is
                -- in it is what the ledger says after the fact, which is the
                -- only number worth drawing.
                NyrAsk("bank.statement", {}, function(said)
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.bank, said))
                end)
            elseif action == "clockon" or action == "clockoff" or action == "walkoff" then
                NyrAsk("work.list", {}, function(board)
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.jobs, board))
                end)
            elseif action == "purchase" then
                -- Read back through the screen the press was made on, the same
                -- as a counter does. A door that has just been bought is drawn
                -- again as somewhere to walk into rather than somewhere to buy,
                -- and it is drawn that way because the server now says so.
                NyrAsk("me.nearby", {}, function(near)
                    if type(near) == "table" and near.ok then shown_nearby = near.value end
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.nearby, near))
                end)
            elseif action == "enter" then
                respond(NyrNuiState.reply(outcome, nil))
                read_stash(outcome.value and outcome.value.stash,
                           outcome.value and outcome.value.address)
            elseif action == "stow" then
                NyrAsk("me.pockets", {}, function(mine)
                    if not (type(mine) == "table" and mine.ok and type(mine.value) == "table") then
                        -- Without the pockets there is no telling which end of
                        -- the move is the stash, and the guess was the pockets
                        -- themselves, read and drawn as the stash.
                        respond(NyrNuiState.read_back(outcome, nil, nil))
                        return
                    end
                    local self_id = mine.value.container
                    -- Whichever end is not you is the stash.
                    local other = args_or_why.from == self_id and args_or_why.to or args_or_why.from
                    NyrAsk("inventory.look", { container = other }, function(theirs)
                        respond(NyrNuiState.read_back(outcome, function(pockets, contents)
                            return NyrNuiState.stash(pockets, contents,
                                { pockets = self_id, stash = other,
                                  address = other == shown_stash and shown_stash_address or nil })
                        end, mine, theirs))
                    end)
                end)
            elseif action == "send" or action == "thread" then
                local with = args_or_why.to or args_or_why.with
                read_phone(with, function(inbox, thread)
                    respond(NyrNuiState.read_back(outcome, function(inbox_value, thread_value)
                        return { inbox = NyrNuiState.inbox(inbox_value),
                                 thread = NyrNuiState.thread(thread_value) }
                    end, inbox, thread))
                end)
            elseif action == "create" then
                -- Making somebody and then not being them is a dead end, and it
                -- was the one a new player fell into: the character existed, no
                -- character was selected, and the screen sat on a generic error
                -- while the server answered `not_playing` forever.
                --
                -- It is fixed here rather than in the page because the page is
                -- never told the id of what it just made -- `reply` carries ok,
                -- a line and a view, and nothing else. This is the only place
                -- that holds the new character's id, so this is the place that
                -- can play them.
                local steps = NyrNuiState.follow_up(action, outcome, shown_playing)
                if #steps == 0 then
                    -- `follow_up` returns nothing when there is nothing to
                    -- follow up: a refused create, or an answer with no id in
                    -- it. Asking anyway sent the server a request whose command
                    -- was nil, which it refused as `unknown_command`, and the
                    -- refusal -- not the create -- is what the player was shown.
                    -- The log read: create ok, then "asked for nil and was
                    -- refused", then a generic error on screen over a character
                    -- that had in fact been made.
                    read(function(value)
                        respond(NyrNuiState.reply(outcome,
                            value and NyrNuiState.picker(value) or nil))
                    end)
                    return
                end
                in_turn(steps, function(chosen)
                    -- The create happened whatever the select said, so the
                    -- picker is drawn again with them in it. Whether they are
                    -- being played is the select's answer, and `made` does not
                    -- report a person nobody is playing as done.
                    read(function(value)
                        respond(NyrNuiState.made(outcome, chosen,
                            value and NyrNuiState.picker(value) or nil))
                    end)
                end)
            else
                read(function(value, refused)
                    local listed = refused
                    if value ~= nil then listed = { ok = true, value = value } end
                    respond(NyrNuiState.read_back(outcome, NyrNuiState.picker, listed))
                end)
            end
        end)
    end)
end

RegisterNUICallback("close", function(_, respond)
    -- The page has already hidden itself; this is the half that gives the
    -- mouse back to the game.
    closings = closings + 1
    shown_stash, shown_stash_address = nil, nil
    if open then
        open = false
        SetNuiFocus(false, false)
    end
    respond({ ok = true })
end)

-- ----------------------------------------------------------------- opening

-- One row per screen, from the same table the chat commands come out of, so
-- that what claims a name and what else claims a name are one list. They were
-- two lists and both had `nyrpockets` in them: the game kept one handler and
-- load order picked which, while the other silently never ran.
local OPEN = {
    picker = NyrPickerOpen,
    pockets = NyrPocketsOpen,
    phone = NyrPhoneOpen,
    nearby = NyrNearbyOpen,
    jobs = NyrJobsOpen,
}

for _, row in ipairs((NyrCommands or require("adapter.commands")).PRESSED) do
    local name, screen, says, key = row[1], row[2], row[3], row[4]
    local opener = OPEN[screen]
    if opener then
        -- Every key closes whatever is up, so a second press puts the mouse
        -- back rather than swapping one screen for another.
        RegisterCommand(name, function()
            if open then NyrPickerClose() else opener() end
        end, false)
        RegisterKeyMapping(name, says, "keyboard", key)
    else
        print(("[nyr] no screen called %s, so %s opens nothing"):format(screen, name))
    end
end

-- The first screen a player sees should not be a chat command, and it should
-- not arrive before there is anything behind it: `adapter/spawn.lua` says when
-- the player is standing somewhere and the loading screen is down.
--
-- The timer is a fallback, not the plan. If the spawn never announces itself
-- the picker still opens, because a player looking at nothing needs a screen
-- more than a player looking at a city does.
local opened_once = false

local function open_first_screen()
    if opened_once then return end
    opened_once = true
    -- One read, not two: asking again on a refusal only makes a player wait
    -- twice for the same answer.
    read(function(value, refused)
        if not value then
            show_refusal(refused)
        elseif not value.playing then
            show(value)
        end
    end)
end

AddEventHandler("nyr:spawned", function()
    Wait(400)
    open_first_screen()
end)

CreateThread(function()
    Wait(PICKER_OPEN_AFTER_MS)
    open_first_screen()
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- A resource that stops with the mouse taken leaves the player unable to
    -- move, and restarting a resource is a thing that happens on a live
    -- server all day.
    if open then
        open = false
        SetNuiFocus(false, false)
    end
end)
