--- The drawn interface: what the page may ask for, and what it is told back.
local modname = ...
local lu = require("luaunit")
local ClientState = require("adapter.client_state")
local NuiState = require("adapter.nui_state")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Characters = require("systems.characters")

local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

TestNuiAdapterCallbacks = {}

function TestNuiAdapterCallbacks:test_moving_an_item_preserves_the_stash_address()
    local callbacks, sent = {}, {}
    local env = setmetatable({
        NyrNuiState = NuiState, NyrClientState = ClientState,
        RegisterNUICallback = function(name, fn) callbacks[name] = fn end,
        RegisterCommand = function() end, RegisterKeyMapping = function() end,
        AddEventHandler = function() end, CreateThread = function() end,
        SetNuiFocus = function() end,
        SendNUIMessage = function(value) sent[#sent + 1] = value end,
        NyrAsk = function(command, args, done)
            if command == "property.enter" then
                done({ ok = true, value = { stash = "prp:demo", address = "12 Vespucci" } })
            elseif command == "me.pockets" then
                done({ ok = true, value = { container = "chr:demo", items = {}, slots = 20, weight = 0, capacity = 40000 } })
            elseif command == "inventory.look" then
                done({ ok = true, value = { container = "prp:demo", items = {}, slots = 40, weight = 0, capacity = 200000 } })
            elseif command == "inventory.move" then
                done({ ok = true })
            else error("unexpected fixture command: " .. command) end
        end,
    }, { __index = _G })
    assert(loadfile("adapter/nui.lua", "t", env))()
    env.NyrStashOpen("demo")
    lu.assertEquals(sent[#sent].view.address, "12 Vespucci")
    local answer
    callbacks.stow({ from = "chr:demo", to = "prp:demo", item = "water", count = "1" },
        function(value) answer = value end)
    lu.assertTrue(answer.ok)
    lu.assertEquals(answer.view.address, "12 Vespucci")
end

--- adapter/nui.lua against fake natives, answering from `answers`.
---
--- Each answer is an outcome, or a function of the arguments that returns one. A
--- command with no answer here is an error rather than a silence, because a
--- screen that asks for something unexpected is what these tests are for. An
--- answer of "hold" is kept until `release` gives it one, so an answer can be
--- made to arrive late.
local function load_nui(answers)
    local loaded = { callbacks = {}, sent = {}, focus = {}, asked = {}, printed = {}, handlers = {},
                     held = {} }
    local env = setmetatable({
        NyrNuiState = NuiState, NyrClientState = ClientState,
        RegisterNUICallback = function(name, fn) loaded.callbacks[name] = fn end,
        RegisterCommand = function() end, RegisterKeyMapping = function() end,
        AddEventHandler = function(name, fn) loaded.handlers[name] = fn end,
        CreateThread = function() end,
        SetNuiFocus = function(has, cursor) loaded.focus[#loaded.focus + 1] = { has, cursor } end,
        SendNUIMessage = function(value) loaded.sent[#loaded.sent + 1] = value end,
        GetCurrentResourceName = function() return "nyr_underworld" end,
        print = function(line) loaded.printed[#loaded.printed + 1] = tostring(line) end,
        NyrWorldRefresh = function() loaded.refreshed = (loaded.refreshed or 0) + 1 end,
        NyrAsk = function(command, args, done)
            loaded.asked[#loaded.asked + 1] = { command = command, args = args }
            local answer = answers[command]
            if answer == nil then error("unexpected fixture command: " .. command) end
            if answer == "hold" then
                loaded.held[#loaded.held + 1] = { command = command, done = done }
                return
            end
            if type(answer) == "function" then answer = answer(args) end
            done(answer)
        end,
    }, { __index = _G })
    assert(loadfile("adapter/nui.lua", "t", env))()
    loaded.env = env
    --- Answer the oldest held question for `command`.
    function loaded.release(command, outcome)
        for i, waiting in ipairs(loaded.held) do
            if waiting.command == command then
                table.remove(loaded.held, i)
                waiting.done(outcome)
                return
            end
        end
        error("nothing is waiting for " .. command)
    end
    function loaded.count(command)
        local n = 0
        for _, asked in ipairs(loaded.asked) do
            if asked.command == command then n = n + 1 end
        end
        return n
    end
    return loaded
end

local INBOX = { ok = true, value = { number = "555-014200", threads = {
    { number = "555-014201", last = "Meet me by the corner shop.", outgoing = false, at = 60000 } } } }

function TestNuiAdapterCallbacks:test_a_phone_that_was_read_opens_without_a_complaint()
    -- `inbox_value and nil or inbox` is `inbox` whatever inbox_value is, so
    -- every F4 that worked opened on "The server did not answer.", drawn in the
    -- colour of good news.
    local nui = load_nui({ ["phone.inbox"] = INBOX })
    nui.env.NyrPhoneOpen()
    local shown = nui.sent[#nui.sent]
    lu.assertEquals(shown.type, "phone")
    lu.assertTrue(shown.ok)
    lu.assertNil(shown.message, "a phone that was read opened saying something went wrong")
    lu.assertEquals(#shown.view.inbox.threads, 1)
end

local NEARBY = { ok = true, value = { shops = {}, places = {
    { place = "prp_demo", address = "12 Vespucci", kind = "apartment", mine = true, may_enter = true } } } }
local ENTERED = { ok = true, value = { stash = "prp:demo", address = "12 Vespucci" } }
local CARRIED = { ok = true, value = { container = "chr:demo", items = {}, slots = 20, weight = 0, capacity = 40000 } }
local PUT_DOWN = { ok = true, value = { container = "prp:demo", items = {}, slots = 40, weight = 0, capacity = 200000 } }

function TestNuiAdapterCallbacks:test_a_stash_read_that_lands_after_escape_does_not_open_it()
    -- Go in answers the page and then reads the stash, two more round trips.
    -- Escape in between closed the page and gave the mouse back, and then the
    -- read landed and put the stash up and took the mouse again: a screen the
    -- player had just closed, opened over them.
    local nui = load_nui({ ["me.nearby"] = NEARBY, ["property.enter"] = ENTERED,
                           ["me.pockets"] = "hold", ["inventory.look"] = PUT_DOWN })
    nui.env.NyrNearbyOpen()
    local answered
    nui.callbacks.enter({ place = "prp_demo" }, function(value) answered = value end)
    lu.assertTrue(answered.ok)
    nui.callbacks.close({}, function() end)
    local sent, focus = #nui.sent, #nui.focus
    nui.release("me.pockets", CARRIED)
    for i = sent + 1, #nui.sent do
        lu.assertNotEquals(nui.sent[i].type, "stash", "a read that landed after Escape opened the stash")
    end
    for i = focus + 1, #nui.focus do
        lu.assertFalse(nui.focus[i][1], "a read that landed after Escape took the mouse back")
    end
end

function TestNuiAdapterCallbacks:test_a_stash_read_refused_after_escape_does_not_open_it_either()
    -- A refusal draws the stash too, with the reason on it, so it is held to
    -- the same rule as an answer.
    local nui = load_nui({ ["me.nearby"] = NEARBY, ["property.enter"] = ENTERED,
                           ["me.pockets"] = "hold" })
    nui.env.NyrNearbyOpen()
    nui.callbacks.enter({ place = "prp_demo" }, function() end)
    nui.callbacks.close({}, function() end)
    local sent = #nui.sent
    nui.release("me.pockets", { ok = false, code = "too_fast", message = "that is being asked for too often" })
    for i = sent + 1, #nui.sent do
        lu.assertNotEquals(nui.sent[i].type, "stash", "a refused read that landed after Escape opened the stash")
    end
end

function TestNuiAdapterCallbacks:test_a_stash_read_that_lands_while_the_page_is_up_opens_it()
    -- The other half, so the test above cannot pass by never opening a stash.
    local nui = load_nui({ ["me.nearby"] = NEARBY, ["property.enter"] = ENTERED,
                           ["me.pockets"] = "hold", ["inventory.look"] = PUT_DOWN })
    nui.env.NyrNearbyOpen()
    nui.callbacks.enter({ place = "prp_demo" }, function() end)
    nui.release("me.pockets", CARRIED)
    lu.assertEquals(nui.sent[#nui.sent].type, "stash")
    lu.assertEquals(nui.sent[#nui.sent].view.address, "12 Vespucci")
end

function TestNuiAdapterCallbacks:test_a_stash_read_that_lands_after_a_key_closed_the_page_does_not_open_it()
    local nui = load_nui({ ["me.nearby"] = NEARBY, ["property.enter"] = ENTERED,
                           ["me.pockets"] = "hold", ["inventory.look"] = PUT_DOWN })
    nui.env.NyrNearbyOpen()
    nui.callbacks.enter({ place = "prp_demo" }, function() end)
    nui.env.NyrPickerClose()
    local sent = #nui.sent
    nui.release("me.pockets", CARRIED)
    for i = sent + 1, #nui.sent do
        lu.assertNotEquals(nui.sent[i].type, "stash", "a read that landed after the key closed the page opened the stash")
    end
end

local function listed(playing)
    return { ok = true, value = { limit = 3, playing = playing, characters = {
        { character = "chr_a", name = "Jane Doe", state = playing == "chr_a" and "active" or "offline",
          wallet = 100, playing = playing == "chr_a" },
        { character = "chr_b", name = "John Roe", state = "offline", wallet = 100, playing = false },
    } } }
end

function TestNuiAdapterCallbacks:test_play_on_somebody_else_lets_go_of_who_you_are_first()
    local playing = "chr_a"
    local nui = load_nui({
        ["character.list"] = function() return listed(playing) end,
        ["character.release"] = function() playing = nil; return { ok = true } end,
        ["character.select"] = function(args)
            if playing and playing ~= args.character then
                return { ok = false, code = "already_playing", message = "license:x is already playing chr_a" }
            end
            playing = args.character
            return { ok = true, value = args.character }
        end,
    })
    nui.env.NyrPickerOpen()
    local answer
    nui.callbacks.select({ character = "chr_b" }, function(value) answer = value end)
    lu.assertTrue(answer.ok, "Play on somebody else was refused: " .. tostring(answer.message))
    lu.assertEquals(playing, "chr_b")
    lu.assertEquals(nui.count("character.release"), 1)
end

function TestNuiAdapterCallbacks:test_resume_lets_go_of_nobody()
    local nui = load_nui({
        ["character.list"] = listed("chr_a"),
        ["character.select"] = { ok = true, value = "chr_a" },
    })
    nui.env.NyrPickerOpen()
    local answer
    nui.callbacks.select({ character = "chr_a" }, function(value) answer = value end)
    lu.assertTrue(answer.ok)
end

function TestNuiAdapterCallbacks:test_begin_that_made_somebody_and_could_not_play_them_does_not_say_done()
    local nui = load_nui({
        ["character.list"] = listed("chr_a"),
        ["character.create"] = { ok = true, value = "chr_new" },
        ["character.release"] = { ok = true },
        ["character.select"] = { ok = false, code = "cannot_wake", message = "cannot move from dead to active" },
    })
    nui.env.NyrPickerOpen()
    local answer
    nui.callbacks.create({ first_name = "Mia", last_name = "Lane" }, function(value) answer = value end)
    lu.assertFalse(answer.ok, "the page was told the new person was being played")
    lu.assertNotNil(answer.view, "the picker was not drawn again with the new person in it")
    lu.assertNotStrContains(answer.message, "dead to active")
end

function TestNuiAdapterCallbacks:test_a_phone_that_was_refused_says_why()
    local nui = load_nui({ ["phone.inbox"] = { ok = false, code = "no_phone",
                                               message = "You do not have a phone." } })
    nui.env.NyrPhoneOpen()
    local shown = nui.sent[#nui.sent]
    lu.assertFalse(shown.ok)
    lu.assertEquals(shown.message, "You do not have a phone.")
end

local THREAD = { ok = true, value = { number = "555-014200", with = "555-014201", messages = {
    { from = "555-014201", body = "Meet me by the corner shop.", at = 60000, sequence = 1 } } } }
local FAST = { ok = false, code = "too_fast", message = "that is being asked for too often" }

function TestNuiAdapterCallbacks:test_a_message_sent_and_not_read_back_leaves_the_phone_as_it_was()
    for _, answers in ipairs({
        { ["phone.send"] = { ok = true }, ["phone.inbox"] = FAST, ["phone.thread"] = THREAD },
        { ["phone.send"] = { ok = true }, ["phone.inbox"] = INBOX, ["phone.thread"] = FAST },
    }) do
        local nui = load_nui(answers)
        local answer
        nui.callbacks.send({ to = "555-014201", body = "on my way" }, function(value) answer = value end)
        lu.assertTrue(answer.ok, "a message that was sent was reported as not sent")
        lu.assertNil(answer.view, "a phone that could not be read again was drawn empty")
        lu.assertNotNil(answer.message, "nothing said the screen was out of date")
    end
end

function TestNuiAdapterCallbacks:test_a_move_not_read_back_leaves_the_stash_as_it_was()
    local nui = load_nui({ ["inventory.move"] = { ok = true }, ["me.pockets"] = CARRIED,
                           ["inventory.look"] = FAST })
    local answer
    nui.callbacks.stow({ from = "chr:demo", to = "prp:demo", item = "water", count = "1" },
        function(value) answer = value end)
    lu.assertTrue(answer.ok)
    lu.assertNil(answer.view, "a stash that could not be read again was drawn as empty")
end

function TestNuiAdapterCallbacks:test_a_move_whose_pockets_were_not_read_asks_about_nothing_else()
    -- With no pockets read there is no telling which end is the stash, and the
    -- guess was the pockets themselves.
    local nui = load_nui({ ["inventory.move"] = { ok = true }, ["me.pockets"] = FAST,
                           ["inventory.look"] = PUT_DOWN })
    local answer
    nui.callbacks.stow({ from = "chr:demo", to = "prp:demo", item = "water", count = "1" },
        function(value) answer = value end)
    lu.assertNil(answer.view)
    lu.assertEquals(nui.count("inventory.look"), 0, "a container was guessed at and read")
end

function TestNuiAdapterCallbacks:test_a_stash_opened_and_not_read_says_why_rather_than_drawing_it_empty()
    local nui = load_nui({ ["me.nearby"] = NEARBY, ["property.enter"] = ENTERED,
                           ["me.pockets"] = CARRIED, ["inventory.look"] = FAST })
    nui.env.NyrNearbyOpen()
    nui.callbacks.enter({ place = "prp_demo" }, function() end)
    local shown = nui.sent[#nui.sent]
    lu.assertEquals(shown.type, "stash")
    lu.assertFalse(shown.ok, "a stash that was never read was drawn as an empty one")
    lu.assertEquals(shown.message, "that is being asked for too often")
end

function TestNuiAdapterCallbacks:test_a_door_bought_from_around_you_asks_for_the_map()
    local nui = load_nui({ ["property.buy"] = { ok = true, value = { place = "prp_1", paid = 250000 } },
                           ["me.nearby"] = NEARBY })
    nui.callbacks.purchase({ place = "prp_1" }, function() end)
    lu.assertEquals(nui.refreshed, 1, "a flat bought on the screen kept its mark and its price")

    local refused = load_nui({ ["property.buy"] = { ok = false, code = "cannot_afford", message = "You cannot afford that." } })
    refused.callbacks.purchase({ place = "prp_1" }, function() end)
    lu.assertNil(refused.refreshed)
end

function TestNuiAdapterCallbacks:test_a_door_is_bought_at_the_price_it_was_drawn_with()
    -- property.buy refuses price_changed when the price a buyer was shown is
    -- not what the seller asks now, so a seller cannot put the price up between
    -- the screen being drawn and Buy being pressed. The screen has to say what
    -- it showed, and the number comes from the answer Lua drew the screen from,
    -- never from the page.
    local on_sale = { ok = true, value = { shops = {}, places = {
        { place = "prp_1", address = "Alta Street, Apt 57", kind = "apartment",
          for_sale = true, price = 320000, enterable = true } } } }
    local nui = load_nui({ ["me.nearby"] = on_sale,
                           ["property.buy"] = { ok = true, value = { place = "prp_1", paid = 320000 } } })
    nui.env.NyrNearbyOpen()
    -- A page that names its own price is still refused before anything is sent.
    local told
    nui.callbacks.purchase({ place = "prp_1", price = 1 }, function(reply) told = reply end)
    lu.assertFalse(told.ok)
    nui.callbacks.purchase({ place = "prp_1" }, function() end)
    local bought
    for _, asked in ipairs(nui.asked) do
        if asked.command == "property.buy" then bought = asked.args end
    end
    lu.assertNotNil(bought, "the purchase was never asked for")
    lu.assertEquals(bought.price, 320000)

    -- A door the screen did not draw goes without a price, and the sale checks
    -- nothing -- including a door beside one that was drawn.
    local asked_before = #nui.asked
    nui.callbacks.purchase({ place = "prp_9" }, function() end)
    lu.assertEquals(nui.asked[asked_before + 1].command, "property.buy")
    lu.assertNil(nui.asked[asked_before + 1].args.price, "a door that was not drawn took another's price")
    local unseen = load_nui({ ["property.buy"] = { ok = false, code = "not_for_sale", message = "No." },
                              ["me.nearby"] = on_sale })
    unseen.callbacks.purchase({ place = "prp_1" }, function() end)
    lu.assertNil(unseen.asked[1].args.price)
end

function TestNuiAdapterCallbacks:test_one_press_of_counter_asks_for_the_shop_once()
    -- The action is itself a shop.list, and it was read back with a second one:
    -- two requests a press against a limit of thirty a minute.
    local nui = load_nui({ ["shop.list"] = { ok = true, value = { name = "Rob's Liquor", state = "open",
        lines = { { item = "water", label = "Water", buy = 250, sell = 100, stock = 12 } } } } })
    local answer
    nui.callbacks.shop({ shop = "shp_1" }, function(value) answer = value end)
    lu.assertEquals(nui.count("shop.list"), 1)
    lu.assertTrue(answer.ok)
    lu.assertEquals(answer.view.name, "Rob's Liquor")
    lu.assertEquals(answer.view.lines[1].buy, "$2.50")
end

function TestNuiAdapterCallbacks:test_buying_still_reads_the_counter_back()
    local nui = load_nui({ ["shop.buy"] = { ok = true },
                           ["shop.list"] = { ok = true, value = { name = "Rob's Liquor", state = "open", lines = {} } } })
    local answer
    nui.callbacks.buy({ shop = "shp_1", item = "water", count = "1" }, function(value) answer = value end)
    lu.assertEquals(nui.count("shop.list"), 1, "a purchase was not read back")
    lu.assertEquals(answer.view.name, "Rob's Liquor")
end

function TestNuiAdapterCallbacks:test_every_screen_read_back_that_fails_draws_nothing()
    -- The rule for every screen an action redraws, not only the two found.
    for action, case in pairs({
        drop = { payload = { item = "water", count = "1" }, command = "inventory.drop", read = "me.pockets" },
        buy = { payload = { shop = "shp_1", item = "water", count = "1" }, command = "shop.buy", read = "shop.list" },
        deposit = { payload = { branch = "prp_1", amount = "10" }, command = "bank.deposit", read = "bank.statement" },
        clockon = { payload = { employer = "emp_1", job = "delivery" }, command = "work.start", read = "work.list" },
        purchase = { payload = { place = "prp_1" }, command = "property.buy", read = "me.nearby" },
    }) do
        local nui = load_nui({ [case.command] = { ok = true }, [case.read] = FAST })
        local answer
        nui.callbacks[action](case.payload, function(value) answer = value end)
        lu.assertTrue(answer.ok, action)
        lu.assertNil(answer.view, action .. " drew a screen from a read that failed")
        lu.assertNotNil(answer.message, action .. " said nothing about a read that failed")
    end
end

-- ------------------------------------------------------- what it may ask for

TestNuiRequests = {}

function TestNuiRequests:test_a_declared_action_becomes_a_server_request()
    local command, args = NuiState.request("create",
        { first_name = "Jane", last_name = "Doe" })
    lu.assertEquals(command, "character.create")
    lu.assertEquals(args, { first_name = "Jane", last_name = "Doe" })

    command, args = NuiState.request("select", { character = "chr_abc" })
    lu.assertEquals(command, "character.select")
    lu.assertEquals(args, { character = "chr_abc" })
end

function TestNuiRequests:test_an_undeclared_action_is_refused()
    -- The page is a browser with developer tools in it. Anyone can call any
    -- callback this resource registers, so the set of things it may ask for is
    -- closed and this is the wall.
    for _, action in ipairs({ "admin.grant", "shop.buy", "", "create ", "CREATE" }) do
        local command, why = NuiState.request(action, {})
        lu.assertNil(command)
        lu.assertEquals(why, "That is not something you can do.")
    end
    lu.assertNil(NuiState.request(nil, {}))
    lu.assertNil(NuiState.request(42, {}))
end

function TestNuiRequests:test_an_undeclared_field_is_refused_not_dropped()
    -- Ignoring it silently means a bug and somebody trying one on look the
    -- same, and neither is ever noticed.
    local command, why = NuiState.request("select",
        { character = "chr_abc", account = "license:cccc3333" })
    lu.assertNil(command)
    lu.assertEquals(why, "That is not something you can do.")
end

function TestNuiRequests:test_a_missing_or_wrong_typed_field_is_refused()
    for _, payload in ipairs({
        { { last_name = "Doe" } },
        { { first_name = "Jane" } },
        { { first_name = 42, last_name = "Doe" } },
        { { first_name = "Jane", last_name = { "Doe" } } },
        { { first_name = "Jane", last_name = "" } },
        { { first_name = "  ", last_name = "Doe" } },
    }) do
        local command, why = NuiState.request("create", payload[1])
        lu.assertNil(command)
        lu.assertEquals(why, "Fill that in.")
    end
end

function TestNuiRequests:test_a_field_nobody_typed_is_refused_before_it_is_sent()
    local command, why = NuiState.request("create",
        { first_name = string.rep("a", NuiState.MAX_FIELD + 1), last_name = "Doe" })
    lu.assertNil(command)
    lu.assertEquals(why, "That is too long.")
    -- and exactly at the limit is still a request, because the ceiling is a
    -- guard against absurd payloads, not an opinion about names
    lu.assertEquals(NuiState.request("create",
        { first_name = string.rep("a", NuiState.MAX_FIELD), last_name = "Doe" }),
        "character.create")
end

function TestNuiRequests:test_spaces_around_what_somebody_typed_are_a_convenience()
    local _, args = NuiState.request("create",
        { first_name = "  Jane ", last_name = "\tDoe  " })
    lu.assertEquals(args.first_name, "Jane")
    lu.assertEquals(args.last_name, "Doe")
end

function TestNuiRequests:test_trimming_never_makes_a_name_the_server_would_refuse_into_one_it_allows()
    -- Whether something is a name is the server's business. Trimming only
    -- removes surrounding space; it cannot repair what is inside.
    local _, args = NuiState.request("create", { first_name = " J4ne ", last_name = "Doe" })
    lu.assertEquals(args.first_name, "J4ne")
    lu.assertNil(args.first_name:match(Characters.NAME_PATTERN))
end

-- ------------------------------------------------------ what it is told back

TestNuiReplies = {}

function TestNuiReplies:test_a_reply_never_carries_the_refusal_code()
    -- The page cannot branch on a code it is never given, which makes "show a
    -- refusal as text" a property of the message rather than a rule somebody
    -- has to keep remembering.
    local reply = NuiState.reply({ ok = false, code = "too_many_characters",
                                   message = "You already have 3 people. Retire one first." })
    lu.assertFalse(reply.ok)
    lu.assertEquals(reply.message, "You already have 3 people. Retire one first.")
    lu.assertNil(reply.code)
    lu.assertNil(reply.view)
end

function TestNuiReplies:test_a_failure_still_never_shows_its_message()
    local reply = NuiState.reply({ ok = false, code = "failed",
        message = "character.list failed: systems/characters.lua:180: attempt to index a nil value" })
    lu.assertEquals(reply.message, "Something went wrong. It has been logged.")
    lu.assertNotStrContains(reply.message, "characters.lua")
end

function TestNuiReplies:test_a_view_is_only_attached_to_something_that_worked()
    local view = { people = {} }
    lu.assertEquals(NuiState.reply({ ok = true, code = "ok" }, view).view, view)
    lu.assertNil(NuiState.reply({ ok = false, code = "no_account" }, view).view)
end

--- A read after an action can fail on its own, and was drawn as an answer.
---
--- Asked too often, or not answered in time, the phone's re-read after a message
--- was sent drew an inbox with nobody in it and no conversation, and the stash's
--- drew a stash that had just been filled as "Nothing put down yet." -- each
--- reported to the page as a success. Nothing was lost; the screen said it was.
local TOO_FAST = { ok = false, code = "too_fast", message = "that is being asked for too often" }

function TestNuiReplies:test_a_read_back_that_came_back_is_drawn()
    local built
    local answer = NuiState.read_back({ ok = true }, function(a, b) built = { a, b }; return "view" end,
        { ok = true, value = "first" }, { ok = true, value = "second" })
    lu.assertTrue(answer.ok)
    lu.assertEquals(answer.view, "view")
    lu.assertEquals(built, { "first", "second" })
end

function TestNuiReplies:test_a_read_back_that_failed_draws_nothing_and_says_so()
    for _, reads in ipairs({ { TOO_FAST }, { { ok = true, value = {} }, TOO_FAST },
                             { TOO_FAST, { ok = true, value = {} } } }) do
        local called = false
        local answer = NuiState.read_back({ ok = true }, function() called = true; return {} end,
            table.unpack(reads, 1, 2))
        lu.assertNil(answer.view, "a failed read back was drawn as an answer")
        lu.assertFalse(called, "a view was built from a read that failed")
        lu.assertTrue(answer.ok, "the action worked and was reported as refused")
        lu.assertStrContains(answer.message, "could not be read again")
    end
end

function TestNuiReplies:test_a_read_back_that_never_arrived_counts_as_failed()
    -- A nil among the reads is a read that did not happen, not the end of the
    -- list: counted by select, never by ipairs.
    local answer = NuiState.read_back({ ok = true }, function() return "view" end,
        { ok = true, value = 1 }, nil)
    lu.assertNil(answer.view)
    answer = NuiState.read_back({ ok = true }, function() return "view" end, nil, { ok = true, value = 1 })
    lu.assertNil(answer.view)
end

function TestNuiReplies:test_a_refused_action_is_still_a_refusal()
    local refused = { ok = false, code = "cannot_afford", message = "You cannot afford that." }
    local answer = NuiState.read_back(refused, function() return "view" end, { ok = true, value = 1 })
    lu.assertFalse(answer.ok)
    lu.assertEquals(answer.message, "You cannot afford that.")
    lu.assertNil(answer.view)
    -- And a refusal whose read back failed too is the refusal, not "that went
    -- through".
    answer = NuiState.read_back(refused, function() return "view" end, TOO_FAST)
    lu.assertFalse(answer.ok, "a refused action was reported as having gone through")
    lu.assertEquals(answer.message, "You cannot afford that.")
end

-- ------------------------------------------------------------- what is drawn

TestNuiPicker = {}

function TestNuiPicker:test_the_picker_draws_what_the_server_said()
    local view = NuiState.picker({
        limit = 3,
        playing = "chr_2",
        characters = {
            { character = "chr_1", name = "Jane Doe", state = "offline", wallet = 125000, playing = false },
            { character = "chr_2", name = "John Roe", state = "active", wallet = 50, playing = true },
        },
    })
    lu.assertEquals(view.used, 2)
    lu.assertEquals(view.limit, 3)
    lu.assertFalse(view.empty)
    lu.assertEquals(view.people[1].name, "Jane Doe")
    lu.assertEquals(view.people[1].money, "$1,250.00")
    lu.assertFalse(view.people[1].playing)
    lu.assertEquals(view.people[2].money, "$0.50")
    lu.assertTrue(view.people[2].playing)
end

function TestNuiPicker:test_somebody_in_hospital_says_so_and_nothing_else_does()
    local view = NuiState.picker({ limit = 3, characters = {
        { character = "chr_1", name = "Jane Doe", state = "dead", wallet = 0 },
        { character = "chr_2", name = "John Roe", state = "offline", wallet = 0 },
    } })
    lu.assertEquals(view.people[1].note, "in hospital")
    lu.assertNil(view.people[2].note)
end

function TestNuiPicker:test_a_new_player_gets_an_empty_picker_and_not_an_error()
    local view = NuiState.picker({ limit = 3, characters = {} })
    lu.assertTrue(view.empty)
    lu.assertEquals(view.used, 0)
    lu.assertEquals(view.people, {})
    -- and nothing at all still draws
    lu.assertTrue(NuiState.picker(nil).empty)
    lu.assertTrue(NuiState.picker("not an answer").empty)
end

function TestNuiPicker:test_being_full_is_a_count_to_print_and_not_a_decision()
    -- The page always offers to make somebody new. Whether that is allowed is
    -- answered by the server refusing it, never by a screen that can be edited
    -- to stop refusing.
    local view = NuiState.picker({ limit = 3, characters = {
        { character = "chr_1", name = "A B", state = "offline", wallet = 0 },
        { character = "chr_2", name = "C D", state = "offline", wallet = 0 },
        { character = "chr_3", name = "E F", state = "offline", wallet = 0 },
    } })
    lu.assertEquals(view.used, 3)
    lu.assertEquals(view.limit, 3)
    lu.assertNil(view.can_create)
    lu.assertNil(view.full)
end

-- ------------------------------------------------------ what the picker asks

TestCharacterList = {}

function TestCharacterList:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system({ opening = 50000, limit = 3 }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = ALICE }).value
end

function TestCharacterList:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    self.world:deactivate()
end

function TestCharacterList:test_it_lists_your_people_with_what_a_picker_needs()
    local outcome = self.world:dispatch("character.list", {}, { account = ALICE })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.characters, 2)
    lu.assertEquals(outcome.value.limit, 3)
    local first = outcome.value.characters[1]
    lu.assertEquals(first.character, self.jane)
    lu.assertEquals(first.name, "Jane Doe")
    lu.assertEquals(first.state, "offline")
    lu.assertEquals(first.wallet, 50000)
    lu.assertFalse(first.playing)
    -- and it draws
    lu.assertEquals(NuiState.picker(outcome.value).people[1].money, "$500.00")
end

function TestCharacterList:test_it_lists_yours_and_only_yours()
    self.world:dispatch("character.create",
        { first_name = "Mallory", last_name = "Poe" }, { account = BOB })
    local mine = self.world:dispatch("character.list", {}, { account = ALICE })
    lu.assertEquals(#mine.value.characters, 2)
    for _, row in ipairs(mine.value.characters) do
        lu.assertNotEquals(row.name, "Mallory Poe")
    end
    lu.assertEquals(#self.world:dispatch("character.list", {}, { account = BOB }).value.characters, 1)
end

function TestCharacterList:test_it_takes_no_argument_naming_anybody()
    lu.assertEquals(self.world.commands:describe("character.list").args, {})
    lu.assertEquals(self.world:dispatch("character.list", {}, {}).code, "no_account")
end

function TestCharacterList:test_it_says_which_one_is_being_played()
    self.world:dispatch("character.select", { character = self.john }, { account = ALICE })
    local outcome = self.world:dispatch("character.list", {}, { account = ALICE })
    lu.assertEquals(outcome.value.playing, self.john)
    local playing = {}
    for _, row in ipairs(outcome.value.characters) do playing[row.name] = row.playing end
    lu.assertFalse(playing["Jane Doe"])
    lu.assertTrue(playing["John Roe"])
    lu.assertTrue(NuiState.picker(outcome.value).people[2].playing)
end

function TestCharacterList:test_the_order_is_the_order_they_were_made_and_does_not_move()
    -- A picker whose rows move around between reads is a picker you misclick.
    local first = self.world:dispatch("character.list", {}, { account = ALICE }).value
    for _ = 1, 10 do
        local again = self.world:dispatch("character.list", {}, { account = ALICE }).value
        for i, row in ipairs(again.characters) do
            lu.assertEquals(row.character, first.characters[i].character)
        end
    end
    lu.assertEquals(first.characters[1].character, self.jane)
    lu.assertEquals(first.characters[2].character, self.john)
end

function TestCharacterList:test_somebody_retired_is_not_somebody_you_can_play()
    self.world:dispatch("character.retire", { character = self.jane }, { account = ALICE })
    local outcome = self.world:dispatch("character.list", {}, { account = ALICE })
    lu.assertEquals(#outcome.value.characters, 1)
    lu.assertEquals(outcome.value.characters[1].character, self.john)
end

function TestCharacterList:test_it_reads_and_never_changes_anything()
    -- The first screen asks this, and asks it again after everything, so a
    -- read that wrote would fill the record with somebody looking at a menu.
    local postings = self.world.ledger:posting_count()
    for _ = 1, 20 do
        self.world:dispatch("character.list", {}, { account = ALICE })
    end
    lu.assertEquals(self.world.ledger:posting_count(), postings)
    lu.assertTrue(self.world:verify())
end

-- ------------------------------------------------------- carrying and calling

TestNuiPockets = {}

function TestNuiPockets:test_what_is_carried_is_drawn_from_what_the_server_said()
    local view = NuiState.pockets({
        slots_used = 2, slots = 30, weight = 2700, capacity = 40000,
        items = {
            { item = "phone", label = "Phone", count = 1, instance = "itm_1" },
            { item = "water", label = "Water", count = 5 },
        },
    })
    lu.assertFalse(view.empty)
    lu.assertEquals(view.weight, "2.7kg")
    lu.assertEquals(view.capacity, "40kg")
    lu.assertEquals(view.full, 6)
    -- A stack of one carries no number; five does.
    lu.assertNil(view.items[1].stack)
    lu.assertEquals(view.items[2].stack, "5")
end

function TestNuiPockets:test_empty_pockets_draw_rather_than_break()
    for _, nothing in ipairs({ { items = {} }, {}, "not an answer" }) do
        local view = NuiState.pockets(nothing)
        lu.assertTrue(view.empty)
        lu.assertEquals(view.items, {})
    end
end

function TestNuiPockets:test_how_full_is_a_bar_to_draw_and_not_a_rule()
    -- Whether one more thing fits is answered by the server refusing to put it
    -- there, never by a page that can be edited to stop refusing.
    local view = NuiState.pockets({ weight = 40000, capacity = 40000, items = {} })
    lu.assertEquals(view.full, 100)
    lu.assertNil(view.can_carry)
    lu.assertNil(view.room)
end

function TestNuiPockets:test_grams_read_the_way_somebody_says_them()
    lu.assertEquals(NuiState.weight(0), "0g")
    lu.assertEquals(NuiState.weight(500), "500g")
    lu.assertEquals(NuiState.weight(999), "999g")
    lu.assertEquals(NuiState.weight(1000), "1kg")
    lu.assertEquals(NuiState.weight(2700), "2.7kg")
    lu.assertEquals(NuiState.weight(40000), "40kg")
    lu.assertEquals(NuiState.weight("500"), "?")
end

TestNuiPhone = {}

function TestNuiPhone:test_a_conversation_reads_downwards()
    -- The server answers newest first, which is the right order to page
    -- through and the wrong order to read.
    local view = NuiState.thread({
        number = "555-1", with = "555-2",
        messages = {
            { from = "555-1", to = "555-2", body = "second", sequence = 2, at = 0 },
            { from = "555-2", to = "555-1", body = "first", sequence = 1, at = 0 },
        },
    })
    lu.assertEquals(view.messages[1].body, "first")
    lu.assertEquals(view.messages[2].body, "second")
    lu.assertFalse(view.messages[1].mine)
    lu.assertTrue(view.messages[2].mine)
end

function TestNuiPhone:test_who_has_been_in_touch()
    local view = NuiState.inbox({
        number = "555-1",
        threads = { { number = "555-2", last = "tonight", outgoing = true, at = 122631720 } },
    })
    lu.assertEquals(view.number, "555-1")
    lu.assertEquals(view.threads[1].number, "555-2")
    lu.assertTrue(view.threads[1].outgoing)
    lu.assertEquals(view.threads[1].when, "day 1, 10:03")
    lu.assertFalse(view.empty)
end

function TestNuiPhone:test_a_phone_nobody_has_written_to_still_draws()
    lu.assertTrue(NuiState.inbox({ number = "555-1", threads = {} }).empty)
    lu.assertTrue(NuiState.inbox(nil).empty)
    lu.assertTrue(NuiState.thread(nil).empty)
end

function TestNuiPhone:test_city_time_reads_as_a_day_and_a_clock()
    lu.assertEquals(NuiState.when(0), "day 0, 00:00")
    lu.assertEquals(NuiState.when(86400000 + 3600000 * 14 + 60000 * 32), "day 1, 14:32")
    lu.assertEquals(NuiState.when(-1), "")
    lu.assertEquals(NuiState.when(1.5), "")
end

TestNuiNewActions = {}

function TestNuiNewActions:test_a_server_command_name_is_not_an_action_name()
    -- The page asks for `drop`, never for `inventory.drop`. The mapping is the
    -- declaration's job and there is no way round it.
    lu.assertNil(NuiState.request("inventory.drop", { item = "water", count = 1 }))
    lu.assertNil(NuiState.request("phone.send", { to = "555-2", body = "x" }))
end

function TestNuiNewActions:test_a_count_typed_into_a_box_becomes_a_number()
    local command, args = NuiState.request("drop", { item = "water", count = "3" })
    lu.assertEquals(command, "inventory.drop")
    lu.assertEquals(args.count, 3)
    lu.assertEquals(math.type(args.count), "integer")
end

function TestNuiNewActions:test_something_that_is_not_a_number_is_refused_before_it_is_sent()
    for _, bad in ipairs({ "many", "", "3.5", "1e400" }) do
        local command, why = NuiState.request("drop", { item = "water", count = bad })
        lu.assertNil(command, bad)
        lu.assertEquals(why, "That needs to be a number.")
    end
end

-- A person types dollars into the bank's box, and the ledger moves cents.
-- Measured on 2026-09-13 with a connected client: 200 typed at Pillbox Hill
-- Branch paid in $2.00, because the box sent the number it was given as the
-- amount, and the amount is whole cents.
function TestNuiNewActions:test_an_amount_typed_at_the_bank_is_dollars_and_arrives_as_cents()
    for typed, cents in pairs({ ["200"] = 20000, ["200.5"] = 20050, ["200.50"] = 20050,
                                ["0.01"] = 1, [" 45 "] = 4500, ["$1,200.00"] = 120000,
                                ["0"] = 0 }) do
        local command, args = NuiState.request("deposit", { branch = "prp_1", amount = typed })
        lu.assertEquals(command, "bank.deposit", typed)
        lu.assertEquals(args.amount, cents, typed)
        lu.assertEquals(math.type(args.amount), "integer", typed)
    end
    local command, args = NuiState.request("withdraw", { branch = "prp_1", amount = "60" })
    lu.assertEquals(command, "bank.withdraw")
    lu.assertEquals(args.amount, 6000)
end

function TestNuiNewActions:test_an_amount_that_is_not_money_is_refused_before_it_is_sent()
    for _, bad in ipairs({ "", "much", "-5", "1.234", "1e3", "12.3.4", "1,20", "$", ".",
                           ".5", "9999999999999", 200 }) do
        local command, why = NuiState.request("deposit", { branch = "prp_1", amount = bad })
        lu.assertNil(command, tostring(bad))
        lu.assertEquals(why, "That needs to be an amount of money, like 200 or 12.50.", tostring(bad))
    end
end

function TestNuiNewActions:test_the_bank_box_asks_for_dollars_and_sends_what_was_typed()
    local html = assert(io.open("adapter/nui/index.html")):read("a")
    local input = html:match('<input id="bank%-amount"[^>]*>')
    lu.assertNotNil(input, "no bank amount box")
    lu.assertStrContains(input, 'step="0.01"')
    local label = html:match('<span>([^<]*)</span>%s*<input id="bank%-amount"')
    lu.assertStrContains(label or "", "$")
    -- The page does not round what was typed to a whole number on its way out:
    -- 200.50 cut down to 200 in the page is fifty cents nobody asked to lose.
    local js = assert(io.open("adapter/nui/app.js")):read("a")
    local asked = js:match("function amountAsked%(%)%s*(%b{})")
    lu.assertNotNil(asked, "no amountAsked in app.js")
    lu.assertNil(asked:find("parseInt"), "the bank box rounds what was typed before the server sees it")
end

function TestNuiNewActions:test_a_message_carries_no_sender()
    -- There is no `from` field to send, because the sending number is the one
    -- the server wrote on this character.
    local command, args = NuiState.request("send", { to = "555-2", body = "tonight" })
    lu.assertEquals(command, "phone.send")
    lu.assertNil(args.from)
    lu.assertNil(NuiState.request("send", { to = "555-2", body = "x", from = "555-9" }))
end


-- ------------------------------------------------------- a counter and a stash

TestNuiShop = {}

function TestNuiShop:test_a_counter_shows_what_the_shop_charges()
    local view = NuiState.shop({ name = "Rob's Liquor", state = "open", lines = {
        { item = "water", label = "Water", buy = 250, sell = 100, stock = 12 },
        { item = "burger", label = "Cheeseburger", buy = 500, stock = 0 },
        { item = "scrap", label = "Scrap Metal", sell = 900, stock = 0 },
    } })
    lu.assertEquals(view.name, "Rob's Liquor")
    lu.assertFalse(view.shut)
    lu.assertEquals(view.lines[1].buy, "$2.50")
    lu.assertEquals(view.lines[1].sell, "$1.00")
    lu.assertFalse(view.lines[1].bare)
    -- A shop that sells a thing and will not buy it back, and one that buys
    -- and does not sell. Both are real, and a dash is the honest drawing.
    lu.assertNil(view.lines[2].sell)
    lu.assertNil(view.lines[3].buy)
    lu.assertTrue(view.lines[2].bare)
end

function TestNuiShop:test_a_shut_shop_says_so_and_still_draws_its_prices()
    local view = NuiState.shop({ name = "Rob's Liquor", state = "shut", lines = {} })
    lu.assertTrue(view.shut)
    lu.assertTrue(view.empty)
end

function TestNuiShop:test_nothing_at_all_still_draws()
    for _, nothing in ipairs({ {}, "not an answer" }) do
        lu.assertTrue(NuiState.shop(nothing).empty)
    end
end

function TestNuiShop:test_out_of_stock_is_drawn_and_is_not_a_rule()
    -- Buying the last one is refused by the shop, never by a page that can be
    -- edited to stop refusing.
    local view = NuiState.shop({ lines = { { item = "x", buy = 1, stock = 0 } } })
    lu.assertTrue(view.lines[1].bare)
    lu.assertNil(view.lines[1].can_buy)
end

TestNuiNearby = {}

function TestNuiNearby:test_what_is_close_enough_to_walk_up_to()
    local view = NuiState.nearby({
        shops = { { shop = "shp_1", name = "Rob's Liquor", state = "open" } },
        places = { { place = "prp_1", address = "12 Grove", kind = "house",
                     mine = true, may_enter = true } },
    })
    lu.assertEquals(view.shops[1].name, "Rob's Liquor")
    lu.assertFalse(view.shops[1].shut)
    lu.assertEquals(view.places[1].address, "12 Grove")
    lu.assertTrue(view.places[1].mine)
    lu.assertFalse(view.empty)
end

function TestNuiNearby:test_standing_nowhere_is_an_answer_and_not_an_error()
    lu.assertTrue(NuiState.nearby({ shops = {}, places = {} }).empty)
    lu.assertTrue(NuiState.nearby(nil).empty)
end

function TestNuiNearby:test_a_door_for_sale_is_drawn_with_its_price_on_it()
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "12 Grove", kind = "apartment",
          mine = false, may_enter = false, for_sale = true, price = 250000 } } })
    lu.assertTrue(view.places[1].for_sale)
    lu.assertEquals(view.places[1].price, "$2,500.00")
end

function TestNuiNearby:test_a_door_that_is_not_for_sale_has_no_price_on_it()
    -- What a place cost the person living in it is theirs. The server sends no
    -- price for a place that is not on the market, and a page handed one
    -- anyway does not draw it.
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "12 Grove", mine = true, may_enter = true,
          for_sale = false, price = 250000 } } })
    lu.assertFalse(view.places[1].for_sale)
    lu.assertNil(view.places[1].price)
    -- And a shop counter is not a door with a price either.
    local counter = NuiState.nearby({ shops = { { shop = "shp_1", name = "Rob's" } } })
    lu.assertNil(counter.shops[1].price)
end

function TestNuiNearby:test_premises_do_not_offer_a_door_nobody_is_let_through()
    -- A bank branch and a shop's premises are held by the council and are not
    -- somewhere a person lives, so `property.enter` refuses them every time,
    -- for everybody, forever. The page drew a Go in on all of them: on a seeded
    -- city that was four rows out of seven carrying a control that cannot work.
    for _, kind in ipairs({ "bank", "shop" }) do
        local view = NuiState.nearby({ places = {
            { place = "prp_1", address = "Pillbox Hill Branch", kind = kind,
              mine = false, may_enter = false, enterable = false } } })
        lu.assertEquals(view.places[1].offers, {},
            ("a %s offered an action nothing can accept"):format(kind))
        lu.assertFalse(view.places[1].enterable)
    end
end

function TestNuiNearby:test_a_home_still_offers_its_door()
    -- The rule is unchanged for anywhere a person could live. A flat somebody
    -- else owns is refused because of who is asking today, which is exactly
    -- the refusal the server is meant to give -- and the day they buy it, the
    -- same button works.
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "12 Grove", kind = "apartment",
          mine = false, may_enter = false, enterable = true } } })
    lu.assertEquals(view.places[1].offers, { "enter" })
end

function TestNuiNearby:test_a_door_for_sale_offers_both()
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "Alta Street", kind = "apartment",
          for_sale = true, price = 320000, enterable = true } } })
    lu.assertEquals(view.places[1].offers, { "purchase", "enter" })
end

function TestNuiNearby:test_a_server_that_does_not_say_still_offers_the_door()
    -- An older server sends no `enterable`. Offering it then is the behaviour
    -- that shipped, and it is the safe way to be wrong: a refusal rather than
    -- no way in at all.
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "12 Grove", kind = "apartment" } } })
    lu.assertEquals(view.places[1].offers, { "enter" })
end

function TestNuiNearby:test_nothing_is_offered_that_the_page_cannot_ask_for()
    -- The general rule, from the other end. A button the page draws and cannot
    -- ask for is the same defect as an action nothing draws: the two lists have
    -- to be one list, and this is what holds them together.
    local view = NuiState.nearby({
        shops = { { shop = "shp_1", name = "Rob's Liquor", state = "open" } },
        places = {
            { place = "prp_1", address = "Alta Street", kind = "apartment",
              for_sale = true, price = 320000, enterable = true },
            { place = "prp_2", address = "Pillbox Hill Branch", kind = "bank",
              enterable = false },
        },
    })
    -- Both directions. Everything offered must be askable, and a row with
    -- something to offer must offer it -- an empty list satisfies the first
    -- rule for free, which is how this check came to pass against a counter
    -- that had quietly stopped being reachable.
    lu.assertEquals(view.shops[1].offers, { "shop" },
        "a counter stopped offering the one thing it is for")
    lu.assertEquals(view.places[1].offers, { "purchase", "enter" })
    lu.assertEquals(view.places[2].offers, {})

    local rows = {}
    for _, row in ipairs(view.shops) do rows[#rows + 1] = row end
    for _, row in ipairs(view.places) do rows[#rows + 1] = row end
    lu.assertTrue(#rows > 0)

    for _, row in ipairs(rows) do
        lu.assertIsTable(row.offers, "a row was drawn without saying what it offers")
        for _, action in ipairs(row.offers) do
            local declared = NuiState.ACTIONS[action]
            lu.assertNotNil(declared,
                ("a row offers %q, which the page cannot ask for"):format(action))
            -- And it carries what that action needs, so the button is not
            -- pressable into a refusal the page could have avoided.
            for field in pairs(declared.fields) do
                lu.assertNotNil(row[field] or row.place or row.shop,
                    ("%s needs %s and the row carries neither it nor an id")
                        :format(action, field))
            end
        end
    end
end

function TestNuiNearby:test_a_door_is_drawn_whether_or_not_it_opens()
    local view = NuiState.nearby({ places = {
        { place = "prp_1", address = "12 Grove", mine = false, may_enter = false } } })
    lu.assertFalse(view.places[1].may_enter)
    -- The page still offers it. property.enter is what says no.
    lu.assertNil(view.places[1].hidden)
end

TestNuiBank = {}

function TestNuiBank:test_a_counter_draws_what_the_ledger_says()
    local view = NuiState.bank({
        account = "acc_1", number = "NYR-1234-5678", state = "open", balance = 412050,
        lines = { { sequence = 2, amount = -2500, reason = "withdrawal" },
                  { sequence = 1, amount = 120000, reason = "wages" } },
    })
    lu.assertTrue(view.open)
    lu.assertEquals(view.number, "NYR-1234-5678")
    lu.assertEquals(view.balance, "$4,120.50")
    lu.assertEquals(view.lines[1].amount, "-$25.00")
    lu.assertFalse(view.lines[1].incoming, "money leaving was drawn as money arriving")
    lu.assertTrue(view.lines[2].incoming)
end

function TestNuiBank:test_somebody_with_no_account_gets_a_screen_not_a_hole()
    -- "You have no account here" is a thing to draw and a reason to offer
    -- opening one, not a missing screen.
    local view = NuiState.bank({})
    lu.assertFalse(view.open)
    lu.assertTrue(view.empty)
    lu.assertEquals(view.balance, "")
    lu.assertTrue(NuiState.bank(nil).empty)
end

function TestNuiBank:test_a_frozen_account_says_so()
    local view = NuiState.bank({ account = "acc_1", state = "frozen", balance = 0 })
    lu.assertTrue(view.frozen)
    -- Drawn, never obeyed: what a frozen account refuses is the server's.
    lu.assertTrue(view.open)
end

TestNuiJobs = {}

function TestNuiJobs:test_a_board_draws_what_it_pays_and_how_long()
    local view = NuiState.jobs({ employers = { {
        employer = "emp_1", name = "Postal OP", hiring = true,
        jobs = { { job = "delivery", label = "Delivery Driver", pay = 12000,
                   minutes = 12, ready_in = 0 } },
    } } })
    local row = view.employers[1].jobs[1]
    lu.assertEquals(view.employers[1].name, "Postal OP")
    lu.assertEquals(row.pay, "$120.00")
    lu.assertEquals(row.minutes, 12)
    lu.assertNil(row.waiting, "a job that is ready said it was not")
end

function TestNuiJobs:test_a_wait_is_drawn_and_is_not_a_rule()
    local view = NuiState.jobs({ employers = { {
        employer = "emp_1", name = "Postal OP", hiring = true,
        jobs = { { job = "delivery", label = "Delivery Driver", pay = 12000,
                   minutes = 12, ready_in = 4 } },
    } } })
    lu.assertEquals(view.employers[1].jobs[1].waiting, "4 min")
    -- Nothing here says the row cannot be pressed. work.start refuses.
    lu.assertNil(view.employers[1].jobs[1].can_take)
end

function TestNuiJobs:test_the_board_says_what_you_are_already_on()
    lu.assertEquals(NuiState.jobs({ employers = {}, working = "delivery" }).working, "delivery")
    lu.assertNil(NuiState.jobs({ employers = {} }).working)
end

function TestNuiJobs:test_nobody_hiring_is_an_answer()
    lu.assertTrue(NuiState.jobs({ employers = {} }).empty)
    lu.assertTrue(NuiState.jobs(nil).empty)
end

-- ------------------------------------------------------- words, not keys

--- The screens printed the server's own keys: a bank line said "deposit" and
--- "withdrawal", a door said "apartment · for sale" and a bank "bank", and the
--- job board said "on a shift: delivery". Turning a key into words is display,
--- the same as money is, so it is done here where a spec reads it.
TestNuiWords = {}

function TestNuiWords:test_a_bank_line_says_what_happened()
    local view = NuiState.bank({ account = "acc_1", number = "NYR-1", state = "open", balance = 100, lines = {
        { sequence = 1, amount = 45000, reason = "deposit" },
        { sequence = 2, amount = -6000, reason = "withdrawal" },
        { sequence = 3, amount = 2500, reason = "transfer", reference = "rent" },
        { sequence = 4, amount = -2500, reason = "transfer" },
        { sequence = 5, amount = -500, reason = "account opening" },
        { sequence = 6, amount = 100, reason = "wages_paid" },
        { sequence = 7, amount = 100 },
    } })
    local said = {}
    for _, line in ipairs(view.lines) do said[#said + 1] = line.label end
    lu.assertEquals(said, { "Paid in", "Taken out", "Transfer in", "Transfer out",
                            "Account opening fee", "Wages paid", "Moved" })
    -- The key is still there for anything that wants it.
    lu.assertEquals(view.lines[1].reason, "deposit")
end

function TestNuiWords:test_a_place_says_what_it_is()
    local view = NuiState.nearby({
        shops = { { shop = "shp_1", name = "Rob's Liquor", state = "open" },
                  { shop = "shp_2", name = "Liquor Ace", state = "shut" } },
        places = {
            { place = "prp_1", address = "Alta Street, Apt 57", kind = "apartment", for_sale = true, price = 320000 },
            { place = "prp_2", address = "Integrity Way, Apt 28", kind = "apartment", mine = true },
            { place = "prp_3", address = "Pillbox Hill Branch", kind = "bank", enterable = false },
            { place = "prp_4", address = "Cypress Flats Scrapyard", kind = "shop", enterable = false },
            { place = "prp_5", address = "Unit 4", kind = "lockup" },
        } })
    lu.assertEquals(view.shops[1].where, "Shop")
    lu.assertEquals(view.shops[2].where, "Shut")
    lu.assertEquals(view.places[1].where, "Apartment · for sale")
    lu.assertEquals(view.places[2].where, "Yours")
    lu.assertEquals(view.places[3].where, "Bank branch")
    lu.assertEquals(view.places[4].where, "Shop premises")
    lu.assertEquals(view.places[5].where, "Lock-up")
end

function TestNuiWords:test_every_kind_of_place_the_city_allows_has_words()
    for _, kind in ipairs({ "apartment", "house", "garage", "lockup", "office", "bank", "shop" }) do
        local where = NuiState.nearby({ places = { { place = "prp_1", address = "x", kind = kind } } }).places[1].where
        lu.assertNotEquals(where, kind, kind .. " was printed as the key")
        lu.assertStrMatches(where, "%u.*", nil, nil, kind .. " was not written as words")
    end
end

function TestNuiWords:test_the_board_names_the_shift_you_are_on_and_what_each_job_is()
    local board = { working = "delivery", employers = { {
        employer = "emp_1", name = "Postal OP", hiring = true,
        jobs = { { job = "delivery", label = "Delivery Driver", pay = 12000, minutes = 12, ready_in = 0 },
                 { job = "sorting", label = "Sorting Office", pay = 9000, minutes = 20, ready_in = 4 } },
    } } }
    local view = NuiState.jobs(board)
    lu.assertEquals(view.working_label, "Delivery Driver")
    lu.assertEquals(view.working, "delivery")
    lu.assertEquals(view.employers[1].jobs[1].where, "Postal OP · 12 min")
    lu.assertEquals(view.employers[1].jobs[2].where, "Postal OP · 20 min · ready in 4 min")

    board.working = "night_shift"
    lu.assertEquals(NuiState.jobs(board).working_label, "Night shift",
        "a shift the board does not list was printed as its key")
    lu.assertNil(NuiState.jobs({ employers = {} }).working_label)
end

--- A short line when something worked.
---
--- The page drew a refusal in words and a success in silence: Buy, Pay in and
--- Take it answered with a redrawn screen and nothing said, so nothing on screen
--- told a player the press had done anything but the numbers moving. The line
--- comes from here, never from the page.
TestNuiDone = {}

function TestNuiDone:test_something_that_worked_says_so()
    lu.assertEquals(NuiState.told("deposit", { branch = "prp_1", amount = 20000 }, { ok = true }).message,
        "Paid in $200.00.")
    lu.assertEquals(NuiState.told("withdraw", { branch = "prp_1", amount = 6000 }, { ok = true }).message,
        "Took out $60.00.")
    lu.assertEquals(NuiState.told("buy", { shop = "shp_1", item = "water", count = 2 }, { ok = true }).message,
        "Bought.")
end

function TestNuiDone:test_a_refusal_and_an_out_of_date_screen_keep_their_own_words()
    local refused = NuiState.told("buy", { count = 1 }, { ok = false, message = "You cannot afford that." })
    lu.assertEquals(refused.message, "You cannot afford that.")
    lu.assertFalse(refused.ok)
    local stale = NuiState.read_back({ ok = true }, nil, nil)
    local line = stale.message
    lu.assertStrContains(line, "out of date")
    lu.assertEquals(NuiState.told("buy", { count = 1 }, stale).message, line)
end

function TestNuiDone:test_a_read_and_a_screen_that_closes_say_nothing()
    for _, action in ipairs({ "shop", "thread", "select", "enter" }) do
        lu.assertNil(NuiState.told(action, {}, { ok = true }).message, action)
    end
end

function TestNuiDone:test_everything_that_changes_something_says_so()
    -- Every declared action, so the next one added is not silent by default.
    local reads = { shop = true, thread = true, select = true, enter = true, create = true }
    for _, action in ipairs(NuiState.actions()) do
        if not reads[action] then
            lu.assertNotNil(NuiState.told(action, { amount = 100 }, { ok = true }).message,
                action .. " worked and said nothing")
        end
    end
end

function TestNuiAdapterCallbacks:test_paying_in_at_the_bank_says_how_much_went_in()
    local nui = load_nui({ ["bank.deposit"] = { ok = true, value = { balance = 1000 } },
                           ["bank.statement"] = { ok = true, value = { account = "acc_1", number = "NYR-1",
                                                                       balance = 1000, lines = {} } } })
    local answer
    nui.callbacks.deposit({ branch = "prp_1", amount = "10" }, function(value) answer = value end)
    lu.assertTrue(answer.ok)
    lu.assertEquals(answer.message, "Paid in $10.00.")
    lu.assertNotNil(answer.view)
end

TestNuiStash = {}

function TestNuiStash:test_both_containers_are_drawn_the_same_way()
    -- Moving a thing is the same gesture in both directions; which container
    -- it is in is the only difference.
    local view = NuiState.stash(
        { items = { { item = "water", label = "Water", count = 2 } }, weight = 1000, capacity = 40000 },
        { items = { { item = "scrap", label = "Scrap", count = 9 } }, weight = 9000, capacity = 200000 },
        { pockets = "chr_1", stash = "prp:prp_1", address = "12 Grove" })
    lu.assertEquals(view.here.items[1].label, "Water")
    lu.assertEquals(view.there.items[1].label, "Scrap")
    lu.assertEquals(view.here.weight, "1kg")
    lu.assertEquals(view.there.capacity, "200kg")
    lu.assertEquals(view.pockets_id, "chr_1")
    lu.assertEquals(view.stash_id, "prp:prp_1")
    lu.assertEquals(view.address, "12 Grove")
end

function TestNuiStash:test_an_empty_stash_draws_as_an_empty_stash()
    local view = NuiState.stash({ items = {} }, nil, {})
    lu.assertTrue(view.here.empty)
    lu.assertTrue(view.there.empty)
end

TestNuiCounterActions = {}

function TestNuiCounterActions:test_the_declared_set_grew_again_and_is_still_closed()
    lu.assertEquals(NuiState.actions(),
        { "account", "buy", "clockoff", "clockon", "create", "deposit", "drop",
          "enter", "purchase", "retire", "select", "sell", "send", "shop",
          "stow", "thread", "use", "walkoff", "withdraw" })
    lu.assertNil(NuiState.request("shop.rob", { shop = "shp_1" }))
    lu.assertNil(NuiState.request("admin.give", {}))
end

function TestNuiCounterActions:test_buying_a_door_is_not_buying_from_a_counter()
    -- Two commands that both spend money, so they get two names. One action
    -- serving both is how a page ends up asking the wrong one.
    local command, args = NuiState.request("purchase", { place = "prp_1" })
    lu.assertEquals(command, "property.buy")
    lu.assertEquals(args, { place = "prp_1" })
    lu.assertEquals(NuiState.request("buy",
        { shop = "shp_1", item = "water", count = "1" }), "shop.buy")
end

function TestNuiCounterActions:test_a_door_is_bought_at_the_price_the_city_is_asking()
    -- There is no price field, so a page with developer tools open has nothing
    -- to put a smaller number in. Sending one is refused rather than ignored.
    lu.assertNil(NuiState.request("purchase", { place = "prp_1", price = 1 }))
    lu.assertNil(NuiState.request("purchase", {}))
end

function TestNuiCounterActions:test_a_purchase_names_no_price()
    -- The buyer never says what anything costs. There is no price field to
    -- send, so there is nothing to edit.
    local command, args = NuiState.request("buy",
        { shop = "shp_1", item = "water", count = "2" })
    lu.assertEquals(command, "shop.buy")
    lu.assertEquals(args, { shop = "shp_1", item = "water", count = 2 })
    lu.assertNil(args.price)
    lu.assertNil(NuiState.request("buy",
        { shop = "shp_1", item = "water", count = "2", price = 1 }))
end

function TestNuiCounterActions:test_a_move_names_both_ends()
    local command, args = NuiState.request("stow",
        { from = "chr_1", to = "prp:prp_1", item = "scrap", count = "5" })
    lu.assertEquals(command, "inventory.move")
    lu.assertEquals(args.from, "chr_1")
    lu.assertEquals(args.to, "prp:prp_1")
    lu.assertEquals(args.count, 5)
end


-- ------------------------------------------------------- how it gets loaded

--- A FiveM client has no module system. Client scripts share one namespace and
--- are ordered only by `client_scripts` in the manifest, so a file that reads a
--- global some later file defines is a bug that appears on the player's machine
--- and nowhere else -- not in the spec suite, which has `require`, and not in a
--- server boot, which never runs a client script at all.
---
--- These load the real files the way the client does: no `require`, in the
--- order the manifest declares.
--- The shape a client actually receives.
---
--- Everything else in this file reads `.value` off an Outcome object, because
--- that is what `world:dispatch` returns. A client never sees an Outcome. It
--- sees `Outcome:summary()`, which `adapter/bridge.lua` sends and which is the
--- only thing it sends -- and `summary()` used to drop `value`.
---
--- So every screen came up blank on a real client while all of this passed:
--- pockets reported "nothing" with a phone in them, and `follow_up` could not
--- read the id of a character that had just been created, so the create
--- dead-ended on a generic error. Found by connecting a client, not by testing.
---
--- These drive the boundary rather than the object behind it.
TestTheShapeAClientGets = {}

local function summary_of(world, command, args, meta)
    -- Exactly what the bridge puts on the wire, and nothing the bridge does not.
    return world:dispatch(command, args or {}, meta):summary()
end

function TestTheShapeAClientGets:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system({ opening = 50000, limit = 3 }))
    self.meta = { account = ALICE, source = "spec" }
end

function TestTheShapeAClientGets:tearDown()
    self.world:deactivate()
end

function TestTheShapeAClientGets:test_a_reply_carries_the_answer_and_not_only_that_it_worked()
    local made = summary_of(self.world, "character.create",
        { first_name = "Jo", last_name = "Vance" }, self.meta)
    lu.assertTrue(made.ok)
    -- The id of what was just made. Without it there is no way to play them.
    lu.assertEquals(type(made.value), "string")
    lu.assertStrContains(made.value, "chr_")
end

function TestTheShapeAClientGets:test_the_create_that_follows_itself_works_on_that_shape()
    -- The exact handoff the interface performs, driven through the wire shape:
    -- create, then read the id out of the reply and select it.
    local made = summary_of(self.world, "character.create",
        { first_name = "Jo", last_name = "Vance" }, self.meta)
    local steps = NuiState.follow_up("create", made)
    lu.assertEquals(#steps, 1)
    lu.assertEquals(steps[1].command, "character.select")
    lu.assertNotNil(steps[1].args.character)

    local chosen = summary_of(self.world, steps[1].command, steps[1].args, self.meta)
    lu.assertTrue(chosen.ok)
end

--- The steps, the way the adapter runs them: each asked in turn, and the last
--- one's answer is the answer.
local function run_steps(world, steps, meta)
    local last
    for _, step in ipairs(steps) do last = summary_of(world, step.command, step.args, meta) end
    return last
end

local function playing_of(world, meta)
    return summary_of(world, "character.list", {}, meta).value.playing
end

function TestTheShapeAClientGets:test_play_on_somebody_else_works_against_the_real_rules()
    local jane = summary_of(self.world, "character.create", { first_name = "Jane", last_name = "Doe" }, self.meta).value
    local john = summary_of(self.world, "character.create", { first_name = "John", last_name = "Roe" }, self.meta).value
    lu.assertTrue(summary_of(self.world, "character.select", { character = jane }, self.meta).ok)

    -- What the page sent before: the select alone, refused while Jane is played.
    lu.assertFalse(summary_of(self.world, "character.select", { character = john }, self.meta).ok)

    local command, args = NuiState.request("select", { character = john })
    local chosen = run_steps(self.world, NuiState.steps("select", command, args, playing_of(self.world, self.meta)), self.meta)
    lu.assertTrue(chosen.ok, "Play on somebody else was refused")
    lu.assertEquals(playing_of(self.world, self.meta), john)
end

function TestTheShapeAClientGets:test_begin_while_playing_somebody_plays_the_new_person()
    local jane = summary_of(self.world, "character.create", { first_name = "Jane", last_name = "Doe" }, self.meta).value
    summary_of(self.world, "character.select", { character = jane }, self.meta)

    local command, args = NuiState.request("create", { first_name = "Mia", last_name = "Lane" })
    local made = summary_of(self.world, command, args, self.meta)
    local chosen = run_steps(self.world, NuiState.follow_up("create", made, playing_of(self.world, self.meta)), self.meta)
    lu.assertTrue(chosen.ok, "the person just made could not be played")
    lu.assertEquals(playing_of(self.world, self.meta), made.value)
end

function TestTheShapeAClientGets:test_a_screen_can_be_drawn_from_what_arrives()
    summary_of(self.world, "character.create",
        { first_name = "Jo", last_name = "Vance" }, self.meta)
    local listed = summary_of(self.world, "character.list", {}, self.meta)
    -- picker(nil) is an empty picker, which is what the interface drew for
    -- every player: a screen that opens and shows nobody.
    lu.assertNotNil(listed.value)
    local view = NuiState.picker(listed.value)
    lu.assertFalse(view.empty)
end

function TestTheShapeAClientGets:test_a_refusal_still_says_nothing_it_should_not()
    local refused = summary_of(self.world, "character.select",
        { character = "chr_nobody" }, self.meta)
    lu.assertFalse(refused.ok)
    -- Events stay named rather than carried, value or no value.
    lu.assertEquals(type(refused.events), "table")
end

TestClientLoadOrder = {}

--- A fresh client namespace: the standard library and nothing else.
---
--- Falling back to `_G` would not do. This spec file has already `require`d
--- both modules, so their globals are sitting in `_G`, and a sandbox that
--- reads through to it would find `NyrClientState` however it was loaded --
--- which is exactly the thing being tested, passing for the wrong reason.
local function client_sandbox()
    local sandbox = {}
    for _, name in ipairs({
        "assert", "error", "ipairs", "math", "next", "pairs", "pcall", "rawequal",
        "rawget", "rawlen", "rawset", "select", "setmetatable", "getmetatable",
        "string", "table", "tonumber", "tostring", "type", "os",
    }) do
        sandbox[name] = _G[name]
    end
    -- No `require`, no natives, and nothing this suite happens to have loaded.
    return sandbox
end

local function manifest_client_scripts()
    local text = assert(io.open("fxmanifest.lua")):read("a")
    local block = text:match("client_scripts%s*{(.-)}")
    local files = {}
    for path in block:gmatch("'([^']+)'") do files[#files + 1] = path end
    return files
end

function TestClientLoadOrder:test_the_manifest_declares_the_order_the_files_need()
    local files = manifest_client_scripts()
    local at = {}
    for i, path in ipairs(files) do at[path] = i end
    lu.assertNotNil(at["adapter/client_state.lua"])
    lu.assertNotNil(at["adapter/nui_state.lua"])
    -- nui_state reads NyrClientState while it is loading, not later
    lu.assertTrue(at["adapter/client_state.lua"] < at["adapter/nui_state.lua"])
    -- nui calls NyrAsk, which client defines
    lu.assertTrue(at["adapter/client.lua"] < at["adapter/nui.lua"])
end

function TestClientLoadOrder:test_that_order_is_enough_with_no_require_anywhere()
    local sandbox = client_sandbox()
    assert(loadfile("adapter/client_state.lua", "t", sandbox))()
    assert(loadfile("adapter/nui_state.lua", "t", sandbox))()
    lu.assertNotNil(sandbox.NyrClientState)
    lu.assertNotNil(sandbox.NyrNuiState)
    -- loaded, and working: money came from the client_state it found
    local view = sandbox.NyrNuiState.picker({ limit = 1, characters = {
        { character = "chr_1", name = "Jane Doe", state = "offline", wallet = 100 },
    } })
    lu.assertEquals(view.people[1].money, "$1.00")
end

function TestClientLoadOrder:test_the_wrong_order_fails_loudly_rather_than_quietly()
    -- If this ever stops erroring, the ordering above stopped being
    -- load-bearing and the test asserting it became decoration.
    local sandbox = client_sandbox()
    local ok = pcall(assert(loadfile("adapter/nui_state.lua", "t", sandbox)))
    lu.assertFalse(ok)
end

-- ------------------------------------------- making somebody, and being them

--- The bug this covers was found by a person playing, not by a spec.
---
--- `character.create` succeeded, the picker closed, and nothing selected the
--- new character. The server answered `not_playing` every five seconds and the
--- screen sat on "Something went wrong." A character existed that its own
--- maker could not be.
---
--- It survived 720 specs because it lived in the one file the suite cannot
--- load -- adapter/nui.lua needs FiveM natives. So the decision moved here.

TestNuiFollowUp = {}

local RELEASE = { command = "character.release", args = {} }
local function select_step(character) return { command = "character.select", args = { character = character } } end

function TestNuiFollowUp:test_creating_somebody_plays_them()
    lu.assertEquals(NuiState.follow_up("create", { ok = true, value = "chr_0001" }),
        { select_step("chr_0001") })
end

function TestNuiFollowUp:test_nothing_else_chains()
    -- Selecting, dropping, buying: each of those is finished when it answers.
    for _, action in ipairs({ "select", "retire", "drop", "use", "send", "thread",
                              "shop", "buy", "sell", "enter", "stow" }) do
        lu.assertEquals(NuiState.follow_up(action, { ok = true, value = "chr_0001" }, "chr_0002"), {}, action)
    end
end

function TestNuiFollowUp:test_a_create_that_was_refused_chains_nothing()
    -- There is nobody to be, so asking to be them would be a second failure on
    -- top of the first.
    lu.assertEquals(NuiState.follow_up("create", { ok = false, code = "too_many_characters" }), {})
    lu.assertEquals(NuiState.follow_up("create", nil), {})
    lu.assertEquals(NuiState.follow_up("create", { ok = true }), {})
    lu.assertEquals(NuiState.follow_up("create", { ok = true, value = "" }), {})
    lu.assertEquals(NuiState.follow_up("create", { ok = true, value = 42 }), {})
end

--- Switching.
---
--- `character.select` refuses an account that is already playing somebody else,
--- and `character.release` is, in the server's own words, "stop playing, on
--- disconnect or when switching". The page sent the select alone: once somebody
--- had been played, Play on anybody else was refused every time, and Begin made
--- a person, failed to play them, told the page it had worked and closed on the
--- player still being whoever they were.
function TestNuiFollowUp:test_playing_somebody_else_lets_go_of_who_you_are_first()
    lu.assertEquals(NuiState.steps("select", "character.select", { character = "chr_b" }, "chr_a"),
        { RELEASE, select_step("chr_b") })
end

function TestNuiFollowUp:test_playing_whoever_you_are_already_is_the_one_request()
    -- Letting go of somebody to pick them straight back up would end whatever
    -- they were doing -- a shift, an incident -- for nothing.
    lu.assertEquals(NuiState.steps("select", "character.select", { character = "chr_a" }, "chr_a"),
        { select_step("chr_a") })
    lu.assertEquals(NuiState.steps("select", "character.select", { character = "chr_a" }, nil),
        { select_step("chr_a") })
end

function TestNuiFollowUp:test_every_other_action_is_the_request_it_names()
    lu.assertEquals(NuiState.steps("drop", "inventory.drop", { item = "water", count = 1 }, "chr_a"),
        { { command = "inventory.drop", args = { item = "water", count = 1 } } })
    lu.assertEquals(NuiState.steps("retire", "character.retire", { character = "chr_b" }, "chr_a"),
        { { command = "character.retire", args = { character = "chr_b" } } })
end

function TestNuiFollowUp:test_making_somebody_while_playing_somebody_else_lets_go_first()
    lu.assertEquals(NuiState.follow_up("create", { ok = true, value = "chr_new" }, "chr_a"),
        { RELEASE, select_step("chr_new") })
end

function TestNuiFollowUp:test_made_and_not_played_is_not_told_as_done()
    -- Told ok, the page closed, and the player was still the person before.
    local view = { people = { { name = "Mia Lane" } } }
    local answer = NuiState.made({ ok = true, value = "chr_new" },
        { ok = false, code = "already_playing",
          message = "license:0123456789abcdef is already playing chr_0000h5a80000c6ltauv" }, view)
    lu.assertFalse(answer.ok, "a person made and not played was reported as done")
    lu.assertEquals(answer.view, view, "the new person was not drawn to be picked")
    lu.assertNotStrContains(answer.message, "license:")
    lu.assertNotStrContains(answer.message, "chr_")
    lu.assertStrContains(answer.message, "Play")

    local played = NuiState.made({ ok = true, value = "chr_new" }, { ok = true, value = "chr_new" }, view)
    lu.assertTrue(played.ok)
    lu.assertEquals(played.view, view)
end

function TestNuiFollowUp:test_the_page_is_still_not_told_what_was_made()
    -- The chain exists precisely because the page cannot do it: a reply carries
    -- ok, a line and a view, and never the id. That stays true.
    local answer = NuiState.reply({ ok = true, value = "chr_0001" }, { people = {} })
    lu.assertNil(answer.value)
    lu.assertNil(answer.character)
    lu.assertTrue(answer.ok)
end

-- -------------------------------------------------- every screen is a panel

--- A screen in the page is a `<main id>`. What makes it a screen rather than text
--- over the game is a rule in the stylesheet that names it -- by its id or by a
--- class it carries -- places it, and paints a ground. The bank counter and the job
--- board were added with markup and script and no such rule, and drew as bare
--- text over the game world. Every check passed: the client reported the screen as
--- showing, which it was. It was found by drawing the real page in a browser to
--- bake the listing.
---
--- The second rule came later. Every screen was placed over the whole viewport
--- with a near-black ground, so opening the pockets or a counter took the city
--- away. Only the character picker covers the game now; every other screen has a
--- size that leaves it in view.

local function read_file(path)
    local handle = assert(io.open(path, "r"))
    local text = handle:read("a")
    handle:close()
    return text
end

--- Every `<main id="..." class="...">` in some markup, in order, as the names a
--- selector could reach it by: `#id` and `.class` for each class.
local function screens_in(markup)
    local screens = {}
    for attributes in markup:gmatch("<main(%s[^>]*)>") do
        local id = attributes:match('%sid="([%w_%-]+)"')
        if id then
            local names = { "#" .. id }
            for class in (attributes:match('%sclass="([^"]*)"') or ""):gmatch("[%w_%-]+") do
                names[#names + 1] = "." .. class
            end
            screens[#screens + 1] = { id = id, names = names }
        end
    end
    return screens
end

local function ids_of(screens)
    local ids = {}
    for _, screen in ipairs(screens) do ids[#ids + 1] = screen.id end
    return ids
end

--- Every rule in a stylesheet with its comments taken out, as the `#id` and
--- `.class` names its selectors mention and its body.
local function rules_in(css)
    local rules = {}
    for selectors, body in css:gsub("/%*.-%*/", ""):gmatch("([^{}]+){([^{}]*)}") do
        local names = {}
        for name in selectors:gmatch("[#%.][%w_%-]+") do names[name] = true end
        rules[#rules + 1] = { names = names, body = body }
    end
    return rules
end

--- The names a stylesheet draws as panels: mentioned in a rule whose body places
--- it absolutely, with an inset, and paints a background.
local function panels_in(css)
    local covered = {}
    for _, rule in ipairs(rules_in(css)) do
        local body = rule.body
        if body:find("position:%s*absolute") and body:find("inset:") and body:find("background") then
            for name in pairs(rule.names) do covered[name] = true end
        end
    end
    return covered
end

--- The names a stylesheet gives a size smaller than the game: a maximum height
--- and a width that is bounded.
local function bounded_in(css)
    local bounded = {}
    for _, rule in ipairs(rules_in(css)) do
        local body = rule.body
        if body:find("max%-height:") and (body:find("max%-width:") or body:find("[^%-]width:%s*min%(")) then
            for name in pairs(rule.names) do bounded[name] = true end
        end
    end
    return bounded
end

local function reached(names, set)
    for _, name in ipairs(names) do
        if set[name] then return true end
    end
    return false
end

TestScreensArePanels = {}

function TestScreensArePanels:test_a_screen_with_no_panel_rule_is_caught()
    -- Against made-up markup first. On the real files there is nothing left to
    -- catch, so a check that could not see a missing rule would pass there too.
    local css = "#a, .floating { position: absolute; inset: 0; margin: auto; background: #000;\n"
        .. "  width: min(900px, 90vw); max-height: 80vh; }\n"
        .. "/* #c { position: absolute; inset: 0; background: #000; } */\n#c { color: red; }\n"
        .. "#d { position: absolute; inset: 0; background: #000; }"
    local covered, bounded = panels_in(css), bounded_in(css)
    local screens = screens_in('<main id="a" hidden></main>\n<main id="b" class="x floating" hidden>'
        .. '</main>\n<main id="c"></main>\n<main id="d"></main>')
    lu.assertEquals(ids_of(screens), { "a", "b", "c", "d" })
    lu.assertTrue(reached(screens[1].names, covered))
    lu.assertTrue(reached(screens[2].names, covered), "a screen placed by its class was not seen")
    lu.assertFalse(reached(screens[3].names, covered),
        "a commented-out rule or one that is not a panel counted as a panel")
    lu.assertTrue(reached(screens[4].names, covered))
    lu.assertTrue(reached(screens[2].names, bounded))
    lu.assertFalse(reached(screens[4].names, bounded), "a screen over the whole game counted as sized")
end

function TestScreensArePanels:test_every_screen_in_the_page_is_drawn_as_a_panel()
    local screens = screens_in(read_file("adapter/nui/index.html"))
    lu.assertTrue(#screens >= 8, ("the page lists %d screens and has eight"):format(#screens))
    local covered = panels_in(read_file("adapter/nui/style.css"))
    local bare = {}
    for _, screen in ipairs(screens) do
        if not reached(screen.names, covered) then bare[#bare + 1] = screen.id end
    end
    lu.assertEquals(bare, {}, "these screens would draw as bare text over the game")
end

function TestScreensArePanels:test_only_the_picker_covers_the_game()
    local screens = screens_in(read_file("adapter/nui/index.html"))
    local bounded = bounded_in(read_file("adapter/nui/style.css"))
    local covering = {}
    for _, screen in ipairs(screens) do
        if not reached(screen.names, bounded) then covering[#covering + 1] = screen.id end
    end
    lu.assertEquals(covering, { "picker" },
        "only the character picker should take the city away; these cover the whole game")
end

-- --------------------------------------------------------- one grammar

--- The screens were eight screens drawn eight ways: a price in a monospace
--- face, a wallet in grey, a balance in a large serif, a wage in amber; Close at
--- the bottom left of some and nowhere near the top of any; a wait drawn on the
--- picker and on nothing else. These hold the parts every screen shares, read
--- from the files, so a ninth screen added the old way is caught.
TestOneGrammar = {}

--- Each `<main ...>...</main>` block of the page, by id.
local function screen_blocks(markup)
    local blocks = {}
    for attributes, inner in markup:gmatch("<main(%s[^>]*)>(.-)</main>") do
        local id = attributes:match('%sid="([%w_%-]+)"')
        if id then blocks[id] = inner end
    end
    return blocks
end

function TestOneGrammar:test_every_screen_has_close_at_the_top_with_its_key()
    local blocks = screen_blocks(read_file("adapter/nui/index.html"))
    local ids = {}
    for id in pairs(blocks) do ids[#ids + 1] = id end
    lu.assertTrue(#ids >= 8)
    local wrong = {}
    for id, inner in pairs(blocks) do
        local head = inner:match("<header.-</header>")
        local close = head and head:match("<button[^>]-close%-button[^>]*>.-</button>")
        if not (close and close:find("<kbd>Esc</kbd>", 1, true)) then wrong[#wrong + 1] = id end
    end
    table.sort(wrong)
    lu.assertEquals(wrong, {}, "these screens have no Close with its key in their head")
end

function TestOneGrammar:test_every_amount_of_money_is_drawn_in_the_one_style()
    -- Everything app.js writes an amount into carries the money class.
    local markup = read_file("adapter/nui/index.html")
    local wrong = {}
    for tag in markup:gmatch("<[%a]+[^>]*>") do
        local class = tag:match('class="([^"]*)"') or ""
        local id = tag:match('id="([^"]*)"') or ""
        local holds_money = id == "bank-balance"
        for _, name in ipairs({ "place-price", "price-buy", "price-sell", "money" }) do
            if (" " .. class .. " "):find(" " .. name .. " ", 1, true) then holds_money = true end
        end
        if holds_money and not (" " .. class .. " "):find(" money ", 1, true) then
            wrong[#wrong + 1] = tag
        end
    end
    lu.assertEquals(wrong, {}, "an amount is drawn outside the money style")
    lu.assertStrContains(read_file("adapter/nui/style.css"), "tabular-nums")
end

function TestOneGrammar:test_the_wait_is_drawn_on_every_screen_and_not_on_close()
    local css = read_file("adapter/nui/style.css"):gsub("/%*.-%*/", "")
    local disabled, line = false, false
    for selectors, body in css:gmatch("([^{}]+){([^{}]*)}") do
        if selectors:find("main%.waiting button") and body:find("pointer%-events:%s*none") then
            disabled = true
            lu.assertStrContains(selectors, ":not(.close-button)", false,
                "Close is stopped while the server is asked, so a mouse cannot leave")
        end
        if selectors:find("main%.waiting %.screen%-head::after") and body:find("animation") then line = true end
    end
    lu.assertTrue(disabled, "no screen but the picker stops a second press while it waits")
    lu.assertTrue(line, "nothing moves while a screen waits")
    for id, inner in pairs(screen_blocks(read_file("adapter/nui/index.html"))) do
        if id ~= "picker" then
            lu.assertStrContains(inner, 'class="screen-head"', false, id .. " has no head for the wait to be drawn under")
        end
    end
end

function TestOneGrammar:test_an_armed_button_runs_out_in_the_time_it_stays_armed()
    local css = read_file("adapter/nui/style.css")
    lu.assertNotNil(css:find("%.confirming::after%s*{[^}]-animation:[^};]-var%(%-%-confirm%-for"),
        "the line under an armed button is not timed by --confirm-for")
    local js = read_file("adapter/nui/app.js")
    lu.assertNotNil(js:find("setProperty%('%-%-confirm%-for', `%${CONFIRM_FOR_MS}ms`%)"),
        "app.js does not time the line from the number that takes the question back")
end

function TestOneGrammar:test_every_empty_state_has_a_pictogram_and_words()
    local markup = read_file("adapter/nui/index.html")
    local count = 0
    for block in markup:gmatch('<div id="[%w%-]+" class="empty[^"]*" hidden>(.-)</div>') do
        count = count + 1
        lu.assertStrContains(block, '<use href="#item-')
        lu.assertNotNil(block:find("<p>[^<]+</p>"), "an empty state with no words")
    end
    lu.assertTrue(count >= 8, ("%d empty states have a pictogram"):format(count))
end

-- ------------------------------------------------------ what the page does

--- The page's own behaviour, which no Lua can run.
---
--- `tools/page_check.js` runs the real app.js under node against a fake DOM
--- built from the real index.html, with a clock and requests that answer only
--- when told. A double-click retired a character and bought a flat, and a
--- counter that answered after Escape came up with the mouse already given
--- back, and all of it passed this suite, which had never run a line of the
--- page. Run from here so that a green suite includes it.
---
--- Where node is not installed the check is skipped and says so: unmade is not
--- passed, and a skip is counted as a skip.
TestThePage = {}

--- The page checks there must be at least, so a file that quietly ran nothing
--- is a failure and not a pass.
local PAGE_CHECKS_AT_LEAST = 18

function TestThePage:test_the_page_checks_pass()
    local probe = io.popen("node --version 2>&1")
    local version = probe and probe:read("a") or ""
    if probe then probe:close() end
    if not version:match("^v%d+") then
        lu.skip("node is not on PATH, so tools/page_check.js was not run")
    end
    local run = assert(io.popen("node tools/page_check.js 2>&1"))
    local said = run:read("a")
    local finished = run:close()
    local failed = {}
    for line in said:gmatch("[^\r\n]+") do
        if line:match("^FAIL") then failed[#failed + 1] = line end
    end
    lu.assertEquals(failed, {}, said)
    lu.assertTrue(finished, "tools/page_check.js did not finish cleanly:\n" .. said)
    local passed, of = said:match("(%d+) of (%d+) page checks passed")
    lu.assertNotNil(passed, "tools/page_check.js never said how many checks it ran:\n" .. said)
    lu.assertTrue(tonumber(of) >= PAGE_CHECKS_AT_LEAST,
        ("tools/page_check.js ran %s checks and there are %d"):format(of, PAGE_CHECKS_AT_LEAST))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
