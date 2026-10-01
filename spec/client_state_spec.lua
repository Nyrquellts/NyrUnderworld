--- The part of the client that is not natives, tested where it can be.
local modname = ...
local lu = require("luaunit")
local ClientState = require("adapter.client_state")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Overview = require("systems.overview")

local ALICE = "license:aaaa1111"

TestClientState = {}

function TestClientState:setUp()
    self.now = 1000
    self.state = ClientState.new({ timeout_ms = 5000, now = function() return self.now end })
end

function TestClientState:test_an_answer_finds_the_question_that_asked_it()
    local got
    local token = self.state:token()
    self.state:open(token, function(outcome) got = outcome end)
    lu.assertEquals(self.state:pending_count(), 1)

    local handler, outcome = self.state:reply(token, { ok = true, value = 42 })
    lu.assertNotNil(handler)
    handler(outcome)
    lu.assertEquals(got.value, 42)
    lu.assertEquals(self.state:pending_count(), 0)
end

function TestClientState:test_an_answer_to_a_question_nobody_asked_is_dropped()
    -- It did not come from anything this client did, so it is not acted on.
    lu.assertNil(self.state:reply("not-a-token", { ok = true }))
    lu.assertNil(self.state:reply(nil, { ok = true }))
end

function TestClientState:test_the_same_answer_twice_is_only_acted_on_once()
    local token = self.state:token()
    self.state:open(token, function() end)
    lu.assertNotNil(self.state:reply(token, { ok = true }))
    lu.assertNil(self.state:reply(token, { ok = true }))
end

function TestClientState:test_two_tokens_are_never_the_same()
    local seen = {}
    for _ = 1, 100 do
        local token = self.state:token()
        lu.assertNil(seen[token])
        seen[token] = true
    end
end

function TestClientState:test_a_question_nobody_answers_is_given_up_on()
    local token = self.state:token()
    local got
    self.state:open(token, function(outcome) got = outcome end)

    self.now = 1000 + 4999
    lu.assertEquals(#self.state:expire(), 0)
    lu.assertEquals(self.state:pending_count(), 1)

    self.now = 1000 + 5000
    local lapsed = self.state:expire()
    lu.assertEquals(#lapsed, 1)
    lu.assertEquals(lapsed[1].token, token)
    lapsed[1].handler(lapsed[1].outcome)
    -- shaped exactly like a real refusal, so nothing downstream has to tell
    -- the difference between refused and never answered
    lu.assertFalse(got.ok)
    lu.assertEquals(got.code, "no_answer")
    lu.assertEquals(self.state:pending_count(), 0)
end

function TestClientState:test_the_view_is_a_cache_for_drawing_and_nothing_else()
    self.state:remember("me.status", { wallet = 100 })
    lu.assertEquals(self.state:view("me.status").wallet, 100)
    lu.assertNil(self.state:view("nothing"))
    self.state:forget()
    lu.assertNil(self.state:view("me.status"))
end

-- ------------------------------------------------------------------ money

function TestClientState:test_money_reads_the_way_a_person_reads_it()
    lu.assertEquals(ClientState.money(0), "$0.00")
    lu.assertEquals(ClientState.money(5), "$0.05")
    lu.assertEquals(ClientState.money(1250), "$12.50")
    lu.assertEquals(ClientState.money(100000), "$1,000.00")
    lu.assertEquals(ClientState.money(123456789), "$1,234,567.89")
    lu.assertEquals(ClientState.money(-2550), "-$25.50")
end

function TestClientState:test_money_that_is_not_whole_minor_units_is_not_money()
    -- The display of a number that is exact everywhere else is not the place
    -- it stops being exact.
    for _, bad in ipairs({ 12.5, "1250", true }) do
        lu.assertEquals(ClientState.money(bad), "?")
    end
    lu.assertEquals(ClientState.money(nil), "?")
end

-- ------------------------------------------------------------- what to say

function TestClientState:test_a_refusal_shows_its_own_words()
    lu.assertEquals(ClientState.say({ ok = false, code = "not_enough_money",
                                      message = "You cannot afford that." }),
                    "You cannot afford that.")
end

function TestClientState:test_a_failure_never_shows_its_message()
    -- That text is a stack trace or an internal name. It is for the server
    -- log, and handing it to whoever is poking at the server tells them where
    -- to poke next.
    local line = ClientState.say({ ok = false, code = "failed",
        message = "shop.buy failed: systems/shops.lua:214: attempt to index a nil value" })
    lu.assertEquals(line, "Something went wrong. It has been logged.")
    lu.assertNotStrContains(line, "shops.lua")
    lu.assertNotStrContains(line, "nil value")
end

function TestClientState:test_a_success_says_nothing_by_itself()
    lu.assertNil(ClientState.say({ ok = true, code = "ok" }))
end

function TestClientState:test_anything_unrecognised_still_says_something_sane()
    lu.assertEquals(ClientState.say(nil), "Something went wrong.")
    lu.assertEquals(ClientState.say("not an outcome"), "Something went wrong.")
    lu.assertEquals(ClientState.say({ ok = false, code = "odd" }),
                    "That is not something you can do.")
end

-- ------------------------------------------------------------------- hud

function TestClientState:test_the_hud_is_built_from_what_is_there()
    -- A server without banking has no bank line and should not have a gap
    -- where one would be.
    local bare = ClientState.hud({ wallet = 12345, hp = 80 })
    lu.assertStrContains(bare, "$123.45")
    lu.assertStrContains(bare, "hp 80")
    lu.assertNotStrContains(bare, "bank")
    lu.assertNotStrContains(bare, "heat")

    local full = ClientState.hud({ wallet = 100, bank = 500000, hp = 40, condition = "down",
                                   heat = 35, crew_tag = "BAL", on_duty = true,
                                   working = "delivery" })
    for _, expected in ipairs({ "$1.00", "bank $5,000.00", "hp 40", "down",
                                "heat 35", "[BAL]", "on duty", "working delivery" }) do
        lu.assertStrContains(full, expected)
    end
    lu.assertEquals(ClientState.hud(nil), "")
    lu.assertEquals(ClientState.hud({}), "")
end

function TestClientState:test_no_heat_is_not_shown_as_heat_nothing()
    lu.assertNotStrContains(ClientState.hud({ wallet = 1, heat = 0 }), "heat")
end

-- The game draws help text in the top-left corner, and the press-E prompt at
-- every counter, branch and door is help text. In the 2026-09-13 recording the
-- status line, drawn at 0.012, 0.016, sat on top of "Alta Street, Apt 57".
local HELP_TEXT_CORNER = { right = 0.35, bottom = 0.15 }

function TestClientState:test_the_hud_is_not_drawn_where_the_game_draws_help_text()
    local at = ClientState.HUD_AT
    lu.assertNotNil(at, "the hud has no position of its own, so nothing here can say where it is")
    -- A centred line reaches about 0.15 either side of its middle at this size.
    local left_edge = at.centre and (at.x - 0.15) or at.x
    lu.assertFalse(left_edge < HELP_TEXT_CORNER.right and at.y < HELP_TEXT_CORNER.bottom,
        ("the hud at %.3f, %.3f is drawn over the press-E prompt"):format(at.x, at.y))
end

function TestClientState:test_the_client_draws_the_hud_where_client_state_says()
    local text = assert(io.open("adapter/client.lua")):read("a")
    lu.assertStrContains(text, "DrawText(at.x, at.y)")
    lu.assertNil(text:find("DrawText%(%s*[%d.]"),
        "adapter/client.lua draws text at numbers of its own, which no spec reads")
end

-- --------------------------------------------------- what the hud reads

TestOverview = {}

function TestOverview:setUp()
    local items = Items.catalogue()
    items:define("water", { label = "Water", weight = 500, stack = 12, category = "consumable" })
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system({ opening = 0 }))
    self.world:install(Memory.system())
    self.world:install(InventorySystem.system({ items = items, slots = 10, weight = 30000 }))
    self.world:install(Overview.system())
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.world:dispatch("character.select", { character = self.jane }, { account = ALICE })
    self.world.ledger:transfer("stake", "external:mint",
        Characters.wallet(self.jane), Money.of(1000))
end

function TestOverview:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    self.world:deactivate()
end

function TestOverview:test_one_answer_carries_what_a_display_needs()
    local outcome = self.world:dispatch("me.status", {}, { actor = self.jane, account = ALICE })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.name, "Jane Doe")
    lu.assertEquals(outcome.value.state, "active")
    lu.assertEquals(outcome.value.wallet, 100000)
    lu.assertEquals(outcome.value.capacity, 30000)
    lu.assertStrContains(outcome.value.at, "monday")
    -- and it draws
    lu.assertStrContains(ClientState.hud(outcome.value), "$1,000.00")
end

function TestOverview:test_a_system_that_is_not_installed_contributes_no_field()
    -- A server without banking should not have a phone that crashes asking
    -- about one.
    local outcome = self.world:dispatch("me.status", {}, { actor = self.jane, account = ALICE })
    lu.assertNil(outcome.value.bank)
    lu.assertNil(outcome.value.crew)
    lu.assertNil(outcome.value.phone)
    lu.assertNil(outcome.value.officer)
    -- but health and standing are installed through memory and inventory
    lu.assertEquals(outcome.value.heat, 0)
    lu.assertEquals(outcome.value.slots, 10)
end

function TestOverview:test_it_reads_you_and_takes_no_argument_naming_anybody()
    local described = self.world.commands:describe("me.status")
    lu.assertEquals(described.args, {})
    lu.assertEquals(self.world.commands:describe("me.pockets").args, {})
    lu.assertEquals(self.world:dispatch("me.status", {}, { account = ALICE }).code, "not_playing")
end

function TestOverview:test_pockets_lists_what_is_carried()
    self.world.services.inventory:spawn("seed", self.jane, "water", 5)
    local outcome = self.world:dispatch("me.pockets", {}, { actor = self.jane, account = ALICE })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.items, 1)
    lu.assertEquals(outcome.value.items[1].label, "Water")
    lu.assertEquals(outcome.value.items[1].count, 5)
    lu.assertEquals(outcome.value.weight, 2500)
    lu.assertEquals(outcome.value.slots_used, 1)
end

function TestOverview:test_it_composes_and_never_changes_anything()
    -- It is drawn on a heads-up display, so it is asked for constantly. A read
    -- that wrote anything would fill the record with somebody looking at their
    -- own money.
    local money = self.world.ledger:balance(Characters.wallet(self.jane))
    local records = #self.world.services.recall(self.jane)
    local postings = self.world.ledger:posting_count()

    for _ = 1, 20 do
        self.world:dispatch("me.status", {}, { actor = self.jane, account = ALICE })
        self.world:dispatch("me.pockets", {}, { actor = self.jane, account = ALICE })
    end

    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), money)
    lu.assertEquals(#self.world.services.recall(self.jane), records)
    lu.assertEquals(self.world.ledger:posting_count(), postings)
    lu.assertTrue(self.world:verify())
end

-- --------------------------------------------------------- finding things

TestFinding = {}

function TestFinding:test_a_shop_goes_on_the_map_under_its_own_name()
    -- What somebody is looking for is "Rob's Liquor", not the address it
    -- happens to trade from.
    local blip = ClientState.blip({ kind = "shop", name = "Rob's Liquor", shop = "shp_1" })
    lu.assertNotNil(blip, "a shop was left off the map")
    lu.assertEquals(blip.label, "Rob's Liquor")
    lu.assertEquals(blip.sprite, 52)
end

function TestFinding:test_a_bank_goes_on_the_map()
    lu.assertNotNil(ClientState.blip({ kind = "bank", name = "Pillbox Hill Branch" }))
end

function TestFinding:test_a_home_is_marked_while_somebody_could_buy_it()
    local selling = ClientState.blip({ kind = "apartment", name = "Alta Street", for_sale = true })
    lu.assertNotNil(selling, "a flat on the market was left off the map")
    lu.assertEquals(selling.label, "Alta Street")
end

function TestFinding:test_a_home_somebody_lives_in_is_not_marked()
    -- Otherwise every door in the city is a mark, which is the same as no map.
    lu.assertNil(ClientState.blip({ kind = "apartment", name = "Alta Street", for_sale = false }))
    lu.assertNil(ClientState.blip({ kind = "house", name = "12 Grove" }))
end

function TestFinding:test_a_kind_nothing_is_listed_for_gets_no_mark()
    lu.assertNil(ClientState.blip({ kind = "lockup" }))
    lu.assertNil(ClientState.blip({ kind = "office" }))
    lu.assertNil(ClientState.blip(nil))
end

function TestFinding:test_shop_premises_with_no_counter_get_no_shop_mark()
    -- The fence trades from premises of the shop kind, and has no counter a key
    -- can open. The mark was chosen by kind and everything else by the counter,
    -- so the scrapyard had a Shop blip on the map and nothing behind it.
    lu.assertNil(ClientState.blip({ kind = "shop", name = "Cypress Flats Scrapyard", place = "prp_9" }))
    lu.assertNotNil(ClientState.blip({ kind = "shop", name = "Rob's Liquor", shop = "shp_1" }))
end

function TestFinding:test_every_mark_on_the_shipped_map_has_something_behind_it()
    -- The general rule, held against what the shipped city actually sends: a
    -- mark on the map is a promise that walking there leads somewhere.
    local City = require("adapter.city")
    local Settings = require("support.settings")
    local MemoryStore = require("persistence.memory_store")
    local settings = assert(Settings.read(require("config")))
    local world = City.build(settings, { store = MemoryStore.new() })
    assert(world:load())
    City.seed(world, settings)
    local answer = world:dispatch("me.map", {}, { account = ALICE }):summary()
    lu.assertTrue(answer.ok)
    lu.assertTrue(#answer.value.places > 0)
    local empty = {}
    for _, place in ipairs(answer.value.places) do
        if ClientState.blip(place) and not (ClientState.opens(place)
            and ClientState.marker(place) and ClientState.prompt(place)) then
            empty[#empty + 1] = tostring(place.name)
        end
    end
    world:deactivate()
    lu.assertEquals(empty, {}, "marked on the map with nothing to walk up to")
end

function TestFinding:test_a_prompt_is_only_offered_where_a_key_does_something()
    -- A prompt that leads nowhere is a promise the city does not keep. A bank
    -- had a blip and no prompt for exactly as long as there was no banking
    -- screen for a key to open; there is one now, so it has both.
    lu.assertNotNil(ClientState.prompt({ shop = "shp_1", name = "Rob's Liquor" }))
    lu.assertNotNil(ClientState.prompt({ for_sale = true, name = "Alta Street", price = 320000 }))
    lu.assertNotNil(ClientState.prompt({ kind = "bank", name = "Pillbox Hill Branch" }))

    -- And still nothing where there is still nothing behind it.
    for _, place in ipairs({ { kind = "apartment", for_sale = false },
                             { kind = "lockup" }, { kind = "office" },
                             { kind = "garage", for_sale = false } }) do
        lu.assertNil(ClientState.prompt(place),
            ("%s offered a key press with nothing behind it"):format(place.kind))
    end
end

function TestFinding:test_a_door_for_sale_says_what_it_costs_on_the_ground()
    local prompt = ClientState.prompt({ for_sale = true, name = "Alta Street", price = 320000 })
    lu.assertStrContains(prompt, "$3,200.00")
end

function TestFinding:test_a_marker_is_drawn_where_a_prompt_is_offered()
    -- The two travel together, in both directions: a light on the ground with
    -- nothing behind it is the same broken promise as the prompt, and a place
    -- that can be used with no light on it cannot be found.
    for _, place in ipairs({ { shop = "shp_1" }, { for_sale = true },
                             { kind = "bank" } }) do
        lu.assertNotNil(ClientState.marker(place))
        lu.assertNotNil(ClientState.prompt(place))
        lu.assertNotNil(ClientState.opens(place))
    end
    for _, place in ipairs({ { kind = "apartment", for_sale = false }, { kind = "lockup" } }) do
        lu.assertNil(ClientState.marker(place))
        lu.assertNil(ClientState.prompt(place))
        lu.assertNil(ClientState.opens(place))
    end
end

function TestFinding:test_the_key_opens_the_screen_that_belongs_to_the_place()
    local screen, which = ClientState.opens({ shop = "shp_1" })
    lu.assertEquals(screen, "shop")
    lu.assertEquals(which, "shp_1", "the counter was opened without saying which")

    lu.assertEquals(ClientState.opens({ for_sale = true }), "nearby")

    -- A bank names its branch for the same reason a shop names its counter:
    -- every button the screen draws has to say which one it is standing at.
    local at, branch = ClientState.opens({ kind = "bank", place = "prp_9" })
    lu.assertEquals(at, "bank")
    lu.assertEquals(branch, "prp_9", "the bank was opened without saying which branch")

    lu.assertNil(ClientState.opens({ kind = "lockup" }))
end

function TestFinding:test_the_key_works_further_out_than_a_door_is_wide()
    -- The server decides whether somebody is close enough to trade. This only
    -- decides when to offer, and offering late is how a player never finds out
    -- the place was interactive at all.
    lu.assertTrue(ClientState.NEAR.act >= 3.0)
    lu.assertTrue(ClientState.NEAR.draw > ClientState.NEAR.act,
        "a marker appears no sooner than the key works, so nothing draws you in")
end

-- ------------------------------------------------- reading the map again

--- The map was read once, at spawn. A flat sold kept its mark, its light and its
--- "press E ... $2,500.00" on every other player's screen for as long as they
--- stayed connected, and a flat put on the market afterwards never appeared.
--- `me.map` allows six reads a minute.
TestMapReads = {}

function TestMapReads:test_a_map_never_read_is_read()
    lu.assertTrue(ClientState.map_due(5000, nil, false, false))
end

function TestMapReads:test_nothing_is_read_closer_together_than_the_gap()
    local gap = ClientState.MAP_READ.gap_ms
    lu.assertFalse(ClientState.map_due(1000 + gap - 1, 1000, true, false))
    lu.assertTrue(ClientState.map_due(1000 + gap, 1000, true, true))
end

function TestMapReads:test_a_map_this_client_changed_is_read_once_the_gap_is_over()
    local gap = ClientState.MAP_READ.gap_ms
    lu.assertFalse(ClientState.map_due(1000 + gap, 1000, false, true))
    lu.assertTrue(ClientState.map_due(1000 + gap, 1000, true, true))
end

function TestMapReads:test_a_map_that_was_never_drawn_is_asked_for_again()
    -- The first read comes on spawn, which can be before the city has opened,
    -- and a map with no marks on it looks like a city with nothing in it.
    lu.assertTrue(ClientState.map_due(1000 + ClientState.MAP_READ.gap_ms, 1000, false, false))
end

function TestMapReads:test_a_drawn_map_is_read_again_now_and_then_for_what_others_did()
    local every = ClientState.MAP_READ.every_ms
    lu.assertFalse(ClientState.map_due(1000 + every - 1, 1000, false, true))
    lu.assertTrue(ClientState.map_due(1000 + every, 1000, false, true))
end

function TestMapReads:test_however_it_is_asked_for_it_stays_well_under_the_limit()
    -- A player buying or listing every second for ten minutes, checked the way
    -- world.lua checks: once a second.
    local reads = {}
    local last, marked = nil, false
    for now = 0, 600000, 1000 do
        if ClientState.map_due(now, last, true, marked) then
            reads[#reads + 1] = now
            last, marked = now, true
        end
    end
    for i = 1, #reads do
        local within = 0
        for j = i, #reads do
            if reads[j] - reads[i] < 60000 then within = within + 1 end
        end
        lu.assertTrue(within <= 3, ("%d reads of me.map inside a minute, and it allows six"):format(within))
    end
end

function TestMapReads:test_a_door_bought_or_put_up_for_sale_asks_for_the_map()
    lu.assertTrue(ClientState.follows("property.buy", { ok = true, value = { place = "prp_1", paid = 250000 } }).map)
    lu.assertTrue(ClientState.follows("property.list", { ok = true }).map)
    lu.assertNil(ClientState.follows("property.buy", { ok = false, code = "cannot_afford" }).map)
    lu.assertNil(ClientState.follows("property.enter", { ok = true }).map)
end

--- adapter/world.lua against fake natives, its threads on a fake clock.
local function load_world()
    local loaded = { handlers = {}, threads = {}, asked = {}, blips = 0, clock = 1000, printed = {} }
    local env = setmetatable({}, { __index = _G })
    env.NyrClientState = ClientState
    env.GetGameTimer = function() return loaded.clock end
    env.CreateThread = function(fn)
        loaded.threads[#loaded.threads + 1] = { routine = coroutine.create(fn), wake = loaded.clock }
    end
    env.Wait = function(ms) coroutine.yield(ms) end
    env.AddEventHandler = function(name, fn) loaded.handlers[name] = fn end
    env.GetCurrentResourceName = function() return "nyr_underworld" end
    env.print = function(line) loaded.printed[#loaded.printed + 1] = tostring(line) end
    env.PlayerPedId = function() return 7 end
    env.DoesEntityExist = function() return true end
    env.GetEntityCoords = function() return { x = 5000.0, y = 5000.0, z = 0.0 } end
    env.AddBlipForCoord = function() loaded.blips = loaded.blips + 1; return loaded.blips end
    env.RemoveBlip = function() end
    for _, name in ipairs({ "SetBlipSprite", "SetBlipColour", "SetBlipScale", "SetBlipAsShortRange",
                            "BeginTextCommandSetBlipName", "AddTextComponentSubstringPlayerName",
                            "EndTextCommandSetBlipName", "DrawMarker", "BeginTextCommandDisplayHelp",
                            "EndTextCommandDisplayHelp" }) do
        env[name] = function() end
    end
    env.IsControlJustReleased = function() return false end
    env.NyrAsk = function(command, args, done)
        loaded.asked[#loaded.asked + 1] = { command = command, done = done, at = loaded.clock }
    end
    assert(loadfile("adapter/world.lua", "t", env))()
    loaded.env = env

    function loaded.run(ms)
        local until_at = loaded.clock + ms
        for step = 1, 100000 do
            assert(step < 100000, "fake scheduler step budget exhausted")
            local next_thread
            for _, thread in ipairs(loaded.threads) do
                if coroutine.status(thread.routine) ~= "dead"
                    and (not next_thread or thread.wake < next_thread.wake) then
                    next_thread = thread
                end
            end
            if not next_thread or next_thread.wake > until_at then break end
            loaded.clock = math.max(loaded.clock, next_thread.wake)
            local ok, waited = coroutine.resume(next_thread.routine)
            assert(ok, waited)
            next_thread.wake = loaded.clock + math.max(16, waited or 0)
        end
        loaded.clock = until_at
    end

    function loaded.reads()
        local n = 0
        for _, asked in ipairs(loaded.asked) do if asked.command == "me.map" then n = n + 1 end end
        return n
    end

    function loaded.answer_map(places)
        for i = #loaded.asked, 1, -1 do
            if loaded.asked[i].command == "me.map" and not loaded.asked[i].answered then
                loaded.asked[i].answered = true
                loaded.asked[i].done({ ok = true, value = { places = places } })
                return
            end
        end
        error("nothing asked for the map")
    end
    return loaded
end

local function flat(for_sale)
    return { place = "prp_apt28", kind = "apartment", name = "Integrity Way, Apt 28",
             x = 1.0, y = 2.0, z = 3.0, for_sale = for_sale, price = for_sale and 250000 or nil }
end
local COUNTER = { place = "prp_robs", kind = "shop", shop = "shp_robs", name = "Rob's Liquor", x = 9.0, y = 9.0, z = 9.0 }

TestWorldMap = {}

function TestWorldMap:test_a_sold_flat_loses_its_mark_once_this_client_bought_it()
    local world = load_world()
    world.handlers["nyr:spawned"]()
    world.run(100)
    lu.assertEquals(world.reads(), 1, "the map was not read on spawn")
    world.answer_map({ flat(true), COUNTER })
    lu.assertEquals(world.env.NyrWorldMarked(), 2)

    -- Bought through Around you or /nyrbuy.
    world.env.NyrWorldRefresh()
    world.run(ClientState.MAP_READ.gap_ms + 1000)
    lu.assertEquals(world.reads(), 2, "buying a flat did not read the map again")
    world.answer_map({ flat(false), COUNTER })
    lu.assertEquals(world.env.NyrWorldMarked(), 1, "a flat that was sold kept its mark")
end

function TestWorldMap:test_what_somebody_else_did_reaches_the_map_in_time()
    local world = load_world()
    world.handlers["nyr:spawned"]()
    world.run(100)
    world.answer_map({ COUNTER })
    world.run(ClientState.MAP_READ.every_ms + 1000)
    lu.assertEquals(world.reads(), 2, "the map was never read again")
    world.answer_map({ flat(true), COUNTER })
    lu.assertEquals(world.env.NyrWorldMarked(), 2, "a flat listed after spawn never appeared")
end

function TestWorldMap:test_a_map_that_could_not_be_read_keeps_its_marks()
    local world = load_world()
    world.handlers["nyr:spawned"]()
    world.run(100)
    world.answer_map({ flat(true), COUNTER })
    world.env.NyrWorldRefresh()
    world.run(ClientState.MAP_READ.gap_ms + 1000)
    world.asked[#world.asked].done({ ok = false, code = "too_fast", message = "that is being asked for too often" })
    lu.assertEquals(world.env.NyrWorldMarked(), 2, "a refused read wiped the map")
end

function TestWorldMap:test_nothing_is_read_before_the_spawn()
    local world = load_world()
    world.run(ClientState.MAP_READ.every_ms * 2)
    lu.assertEquals(world.reads(), 0)
end

-- ------------------------------------------------- where a line is said

TestChannels = {}

function TestChannels:test_a_stock_server_is_unchanged()
    local where = ClientState.channels("started")
    lu.assertTrue(where.chat)
    lu.assertFalse(where.notify, "a server with chat gets every line twice")
end

function TestChannels:test_a_server_without_chat_still_shows_the_player()
    -- Nothing listens for chat:addMessage there, so every answer this resource
    -- gave was dropped and a working command looked like a missing one.
    for _, state in ipairs({ "missing", "stopped", "uninitialized" }) do
        local where = ClientState.channels(state)
        lu.assertTrue(where.notify, ("chat %s and nothing is drawn"):format(state))
    end
end

function TestChannels:test_a_build_that_cannot_answer_is_treated_as_no_chat()
    -- `GetResourceState` missing is not "chat is fine", it is "unknown", and
    -- the safe reading of unknown is the one where the player still sees it.
    local where = ClientState.channels(nil)
    lu.assertTrue(where.notify)
end

function TestChannels:test_the_console_always_gets_it()
    -- Free, off-screen, and the reason an answer is never nowhere.
    for _, state in ipairs({ "started", "missing", "stopped" }) do
        lu.assertTrue(ClientState.channels(state).console)
    end
end

-- ---------------------------------------------------- what a chat answer says

TestChatAnswers = {}

--- A command that moves money says how much moved. They all said "done", which
--- is also what they said while 500 typed meant five dollars: nothing a player
--- could read would have shown them the difference.
function TestChatAnswers:test_a_command_that_moves_money_says_how_much()
    local said = table.concat(ClientState.answer("bank.deposit",
        { balance = 120000 }, { branch = "prp_1", amount = 20000 }), "\n")
    lu.assertStrContains(said, "$200.00")
    lu.assertStrContains(said, "$1,200.00")

    said = table.concat(ClientState.answer("bank.withdraw",
        { balance = 100000 }, { branch = "prp_1", amount = 6000 }), "\n")
    lu.assertStrContains(said, "$60.00")
    lu.assertStrContains(said, "$1,000.00")

    -- What arrived, and what the bank kept, as the server counted them.
    said = table.concat(ClientState.answer("bank.transfer",
        { sent = 49500, fee = 500, balance = 250000 },
        { to = "4412-0001", amount = 50000, reference = "rent" }), "\n")
    lu.assertStrContains(said, "$495.00")
    lu.assertStrContains(said, "$5.00")
    lu.assertStrContains(said, "4412-0001")

    for _, command in ipairs({ "gang.deposit", "gang.withdraw" }) do
        said = table.concat(ClientState.answer(command, { treasury = 900000 }, { amount = 20000 }), "\n")
        lu.assertStrContains(said, "$200.00", false, command)
        lu.assertStrContains(said, "$9,000.00", false, command)
    end
    for _, command in ipairs({ "admin.give", "admin.take" }) do
        said = table.concat(ClientState.answer(command, { amount = 20000 },
            { character = "chr_1", amount = 20000, reason = "a refund" }), "\n")
        lu.assertStrContains(said, "$200.00", false, command)
    end
end

function TestChatAnswers:test_a_listing_says_the_price_it_was_put_up_at()
    -- `property.list` answers with no value at all, so the line comes from what
    -- was sent, and it is the line that would have said $30.00.
    local said = table.concat(ClientState.answer("property.list", nil,
        { place = "prp_1", price = 300000 }), "\n")
    lu.assertStrContains(said, "$3,000.00")
    lu.assertNotStrContains(table.concat(ClientState.answer("property.list", nil,
        { place = "prp_1" }), "\n"), "$")
end

function TestChatAnswers:test_an_answer_with_nothing_to_show_says_done()
    lu.assertEquals(ClientState.answer("property.enter", nil, { place = "prp_1" }), { "done" })
    lu.assertEquals(ClientState.answer("me.pockets", "not a table", {}), { "done" })
end

function TestChatAnswers:test_nyrme_says_everything_it_was_told_whatever_is_missing()
    -- The lines were a table literal with `account and ... or nil` in the
    -- middle. A nil there ends the list for ipairs, so anybody without a bank
    -- account lost their phone number and the time as well.
    local lines = ClientState.answer("me.status", { name = "Jane Doe", state = "active",
        wallet = 50000, hp = 100, condition = "well", phone = "555-014200", at = "day 1, 08:00" }, {})
    local said = {}
    for _, line in ipairs(lines) do said[#said + 1] = line end
    lu.assertEquals(#said, 4, table.concat(said, " | "))
    lu.assertStrContains(said[3], "555-014200")
    lu.assertEquals(said[4], "day 1, 08:00")

    -- And with nothing optional at all, still the name and the time.
    said = {}
    for _, line in ipairs(ClientState.answer("me.status",
        { name = "Jane Doe", state = "active", at = "day 1, 08:00" }, {})) do
        said[#said + 1] = line
    end
    lu.assertEquals(said, { "Jane Doe  (active)", "day 1, 08:00" })

    -- Everything, in the order it always had.
    said = {}
    for _, line in ipairs(ClientState.answer("me.status", { name = "Jane Doe", state = "active",
        wallet = 50000, account = "4412-0001", bank = 0, phone = "555-014200", at = "day 1, 08:00" }, {})) do
        said[#said + 1] = line
    end
    lu.assertEquals(#said, 5)
    lu.assertEquals(said[3], "account 4412-0001")
    lu.assertEquals(said[4], "phone 555-014200")
end

function TestChatAnswers:test_a_listing_answer_still_lists()
    local lines = ClientState.answer("me.pockets", { slots_used = 1, slots = 20, weight = 500,
        capacity = 40000, items = { { label = "Water", count = 2 } } }, {})
    lu.assertEquals(#lines, 2)
    lu.assertStrContains(lines[2], "Water")
end

-- ------------------------------------------------------------------ a body

--- A player killed in the world stayed a corpse.
---
--- The body was resurrected once, at join, by adapter/spawn.lua. On a server
--- with no spawnmanager -- every Enhanced server -- nothing resurrected it again:
--- `/nyrrespawn` was answered, the hospital took its fee, the server's numbers
--- said the person was on their feet, and the body lay where it fell. A revive
--- by a medic reached the server and never reached the body at all.
TestBody = {}

function TestBody:setUp()
    self.now = 100000
    self.body = ClientState.body({ now = function() return self.now end })
    self.grace = ClientState.BODY.grace_ms
    self.remind = ClientState.BODY.remind_ms
end

function TestBody:test_a_body_that_is_down_is_told_so_once_and_then_now_and_again()
    lu.assertNil(self.body:seen(true), "a line was said before the server had said anything")
    self.body:said("down", self.now)
    local line = self.body:seen(true)
    lu.assertNotNil(line, "a body the server says is down was told nothing")
    lu.assertStrContains(line, "down")
    self.now = self.now + 1000
    lu.assertNil(self.body:seen(true), "the same line was said again a second later")
    self.now = self.now + self.remind
    lu.assertEquals(self.body:seen(true), line, "a player who missed the line was never told again")
end

function TestBody:test_a_body_that_is_gone_is_told_what_to_type()
    self.body:seen(true)
    self.body:said("dead", self.now)
    local line = self.body:seen(true)
    lu.assertNotNil(line)
    lu.assertStrContains(line, "/nyrrespawn")
end

function TestBody:test_a_body_the_server_has_on_its_feet_is_stood_up_where_it_lies()
    -- How a revive reaches the body: the server says well, asked after the
    -- body died, and the medic is standing over it.
    self.body:seen(true)
    self.body:said("down", self.now + 1000)
    lu.assertEquals(self.body:said("well", self.now + self.grace + 4000), "here")
end

function TestBody:test_an_answer_asked_before_the_server_could_see_the_death_changes_nothing()
    -- The server reads health once a second from its own copy. An answer to a
    -- question asked in that moment says well about a body that has just died,
    -- and standing it up then would undo the death before it was counted.
    self.body:seen(true)
    lu.assertNil(self.body:said("well", self.now - 3000))
    lu.assertNil(self.body:said("well", self.now + self.grace - 1))
    lu.assertEquals(self.body:said("well", self.now + self.grace), "here")
end

function TestBody:test_a_living_body_is_never_stood_up_or_told_anything()
    lu.assertNil(self.body:seen(false))
    self.body:said("dead", self.now)
    lu.assertNil(self.body:seen(false))
    lu.assertNil(self.body:said("well", self.now + 60000))
    lu.assertFalse(self.body:is_dead())
end

function TestBody:test_a_body_being_stood_up_is_not_stood_up_twice_or_nagged()
    self.body:seen(true)
    self.body:said("dead", self.now)
    self.body:standing(true)
    lu.assertNil(self.body:said("well", self.now + 60000))
    -- An answer asked just before the respawn still says gone, and the body is
    -- already on its way up.
    self.body:said("dead", self.now + 60000)
    self.now = self.now + self.remind
    lu.assertNil(self.body:seen(true), "a body being stood up was told it was gone")
end

function TestBody:test_a_second_death_waits_its_own_grace()
    self.body:seen(true)
    self.body:standing(true)
    self.body:standing(false)
    self.body:seen(false)
    self.now = self.now + 60000
    self.body:seen(true)
    lu.assertNil(self.body:said("well", self.now + 1000), "the first death's wait was counted for the second")
    lu.assertEquals(self.body:said("well", self.now + self.grace), "here")
end

function TestBody:test_the_server_saying_nothing_about_health_changes_nothing()
    self.body:seen(true)
    lu.assertNil(self.body:said(nil, self.now + 60000))
    lu.assertNil(self.body:seen(true))
end

TestFollows = {}

function TestFollows:test_a_respawn_that_worked_stands_the_body_up_at_the_spawn()
    lu.assertEquals(ClientState.follows("health.respawn", { ok = true, value = { hp = 60, paid = 50000 } }),
        { stand = "spawn" })
    lu.assertEquals(ClientState.follows("health.respawn", { ok = false, code = "not_dead" }), {})
    lu.assertEquals(ClientState.follows("health.respawn", nil), {})
    -- A revive is the medic's command. Their own body is not the one to move.
    lu.assertEquals(ClientState.follows("health.revive", { ok = true, value = { hp = 25 } }), {})
end

function TestFollows:test_where_a_body_is_stood_up()
    local spawn = ClientState.stand_at("spawn")
    lu.assertEquals(spawn, ClientState.SPAWN)
    lu.assertEquals(ClientState.stand_at("here", { x = 1.5, y = -2.0, z = 30.25 }, 90.0),
        { x = 1.5, y = -2.0, z = 30.25, heading = 90.0 })
    lu.assertNil(ClientState.stand_at("here", nil, 0))
    lu.assertNil(ClientState.stand_at("somewhere"))
end

function TestFollows:test_a_script_starting_under_a_player_already_in_the_city_does_not_spawn_them()
    -- The loading screen is up for a join and down for a restart. Only the one
    -- case that is plainly a restart -- no loading screen and a body standing
    -- there -- is left alone; anything unsure spawns, as a join always has.
    lu.assertEquals(ClientState.arrival(true, true), "spawn")
    lu.assertEquals(ClientState.arrival(false, true), "announce")
    lu.assertEquals(ClientState.arrival(false, false), "spawn")
    lu.assertEquals(ClientState.arrival(nil, true), "spawn")
    lu.assertEquals(ClientState.arrival(false, nil), "spawn")
end

function TestFollows:test_waking_up_says_what_the_hospital_took()
    local said = table.concat(ClientState.answer("health.respawn", { hp = 60, paid = 50000 }, {}), "\n")
    lu.assertStrContains(said, "60")
    lu.assertStrContains(said, "$500.00")
end

-- ---------------------------------------------------- the client, wired up

--- adapter/client.lua against fake natives, its threads run on a fake clock.
---
--- The decisions are tested above. This is the wiring: that a respawn which
--- worked reaches the body, that a dead body is asked about with the status
--- line switched off, and that what the server says is what stands it up.
local function load_client(cold)
    local loaded = { sent = {}, said = {}, commands = {}, handlers = {}, threads = {},
                     stood = {}, clock = 1000, dead = false }
    local env = setmetatable({}, { __index = _G })
    env.NyrClientState = ClientState
    env.NyrCommands = require("adapter.commands")
    env.NyrReadiness = require("adapter.readiness")
    env.GetGameTimer = function() return loaded.clock end
    env.CreateThread = function(fn)
        loaded.threads[#loaded.threads + 1] = { routine = coroutine.create(fn), wake = loaded.clock }
    end
    env.Wait = function(ms) coroutine.yield(ms) end
    env.RegisterNetEvent = function() end
    env.AddEventHandler = function(name, fn) loaded.handlers[name] = fn end
    env.TriggerServerEvent = function(event, name, args, token, epoch)
        if event == "nyr:session:hello" then return end
        loaded.sent[#loaded.sent + 1] = { name = name, args = args, token = token, epoch = epoch, at = loaded.clock }
    end
    env.RegisterCommand = function(name, fn) loaded.commands[name] = fn end
    env.GetResourceState = function() return "started" end
    env.TriggerEvent = function(name, payload)
        if name == "chat:addMessage" then loaded.said[#loaded.said + 1] = payload.args[2] end
    end
    env.print = function() end
    env.GetCurrentResourceName = function() return "nyr_underworld" end
    env.PlayerPedId = function() return 7 end
    env.DoesEntityExist = function() return true end
    loaded.collision, loaded.network = true, true
    env.NetworkIsSessionStarted = function() return loaded.network end
    env.HasCollisionLoadedAroundEntity = function() return loaded.collision end
    env.GetIsLoadingScreenActive = function() return false end
    env.IsEntityDead = function() return loaded.dead end
    for _, name in ipairs({ "SetTextFont", "SetTextScale", "SetTextColour", "SetTextOutline",
                            "SetTextCentre", "SetTextEntry", "AddTextComponentString", "DrawText" }) do
        env[name] = function() end
    end
    loaded.refreshed = 0
    env.NyrWorldRefresh = function() loaded.refreshed = loaded.refreshed + 1 end
    env.NyrStand = function(where, done)
        loaded.stood[#loaded.stood + 1] = where
        loaded.stand_done = done
    end
    assert(loadfile("adapter/client.lua", "t", env))()

    --- Move the clock on, running every thread whose wait is over.
    function loaded.run(ms)
        local until_at = loaded.clock + ms
        for step = 1, 100000 do
            assert(step < 100000, "fake scheduler step budget exhausted")
            local next_thread
            for _, thread in ipairs(loaded.threads) do
                if coroutine.status(thread.routine) ~= "dead"
                    and (not next_thread or thread.wake < next_thread.wake) then
                    next_thread = thread
                end
            end
            if not next_thread or next_thread.wake > until_at then break end
            loaded.clock = math.max(loaded.clock, next_thread.wake)
            local ok, waited = coroutine.resume(next_thread.routine)
            assert(ok, waited)
            -- A frame is sixteen milliseconds, so a Wait(0) loop cannot spin.
            next_thread.wake = loaded.clock + math.max(16, waited or 0)
        end
        loaded.clock = until_at
    end

    --- Answer the latest request for `name`.
    function loaded.answer(name, outcome)
        for i = #loaded.sent, 1, -1 do
            if loaded.sent[i].name == name then
                loaded.handlers["nyr:outcome"](loaded.sent[i].token, outcome)
                return loaded.sent[i]
            end
        end
        error("nothing asked for " .. name)
    end

    function loaded.asked(name)
        local n = 0
        for _, request in ipairs(loaded.sent) do
            if request.name == name then n = n + 1 end
        end
        return n
    end
    loaded.ask = env.NyrAsk
    loaded.ready = env.NyrWorldReady
    if not cold then loaded.handlers["nyr:session"]("fixture-epoch"); loaded.run(200) end
    return loaded
end

TestClientBody = {}

function TestClientBody:test_client_asks_nothing_before_stable_world_and_server_handshake()
    local client = load_client(true)
    local got, args = {}, { nested = { value = 1 } }
    client.ask("character.list", args, function(outcome) got[#got + 1] = outcome end)
    args.nested.value = 99; client.run(400)
    lu.assertEquals(client.asked("character.list"), 0)
    client.collision = false; client.handlers["nyr:session"]("new-epoch"); client.run(400)
    lu.assertEquals(client.asked("character.list"), 0)
    client.collision = true; client.run(200)
    lu.assertEquals(client.asked("character.list"), 1)
    local sent = client.sent[#client.sent]
    lu.assertEquals(sent.epoch, "new-epoch"); lu.assertEquals(sent.args.nested.value, 1)
    client.handlers["nyr:session"]("restart-epoch")
    lu.assertEquals(got[1].code, "outcome_unknown")
    client.handlers["nyr:outcome"](sent.token, { ok = true })
    lu.assertEquals(#got, 1)
end

function TestClientBody:test_a_respawn_that_worked_stands_the_body_up()
    local client = load_client()
    client.commands.nyrrespawn(0, {})
    client.answer("health.respawn", { ok = true, value = { hp = 60, paid = 50000 } })
    lu.assertEquals(client.stood, { "spawn" }, "the hospital was paid and the body stayed where it fell")
    lu.assertStrContains(client.said[#client.said], "$500.00")
end

function TestClientBody:test_a_door_bought_or_listed_in_chat_asks_for_the_map()
    local client = load_client()
    client.commands.nyrbuy(0, { "prp_1" })
    client.answer("property.buy", { ok = true, value = { place = "prp_1", paid = 250000 } })
    lu.assertEquals(client.refreshed, 1, "a flat bought in chat left the map as it was")
    client.commands.nyrlist(0, { "prp_1", "3000" })
    client.answer("property.list", { ok = true })
    lu.assertEquals(client.refreshed, 2, "a flat listed in chat never reached the map")
    client.commands.nyrbuy(0, { "prp_2" })
    client.answer("property.buy", { ok = false, code = "cannot_afford", message = "You cannot afford that." })
    lu.assertEquals(client.refreshed, 2)
end

function TestClientBody:test_a_respawn_that_was_refused_moves_nothing()
    local client = load_client()
    client.commands.nyrrespawn(0, {})
    client.answer("health.respawn", { ok = false, code = "not_dead", message = "You are not dead." })
    lu.assertEquals(client.stood, {})
    lu.assertEquals(client.said[#client.said], "You are not dead.")
end

local function status(condition)
    return { ok = true, value = { name = "Jane Doe", state = "active", wallet = 100, hp = 0,
                                  condition = condition, at = "day 1, 08:00" } }
end

function TestClientBody:test_a_body_left_lying_is_told_and_then_stood_up_when_the_server_says_so()
    local client = load_client()
    client.run(1500)
    client.dead = true
    client.run(5000)
    client.answer("me.status", status("down"))
    client.run(1000)
    lu.assertStrContains(client.said[#client.said], "down", false, "a player lying down was told nothing")
    lu.assertEquals(client.stood, {})

    -- A medic brings them round; the next status says so.
    client.run(5000)
    client.answer("me.status", status("well"))
    lu.assertEquals(client.stood, { "here" }, "revived on the server and still lying on the ground")
end

function TestClientBody:test_a_status_asked_as_the_body_died_does_not_stand_it_up_however_late_it_lands()
    -- What counts is when the question was asked, not when the answer landed:
    -- the answer says what the server knew then.
    local client = load_client()
    client.run(1500)
    client.dead = true
    client.run(5000)
    -- Asked at 6000, a second or so after the death was seen, and answered late.
    client.run(3000)
    local request
    for _, sent in ipairs(client.sent) do
        if sent.name == "me.status" and sent.at < 7000 then request = sent end
    end
    lu.assertNotNil(request, "the status was not asked for in the moment after the death")
    client.handlers["nyr:outcome"](request.token, status("well"))
    lu.assertEquals(client.stood, {}, "an answer about the moment of death stood the body up")
end

function TestClientBody:test_a_dead_body_is_asked_about_with_the_status_line_off()
    local client = load_client()
    client.commands.nyrhud(0, {})
    client.run(11000)
    lu.assertEquals(client.asked("me.status"), 0, "the status line was off and still asked for")
    client.dead = true
    client.run(11000)
    lu.assertTrue(client.asked("me.status") >= 1,
        "nothing asked the server about a dead body, so a revive could never reach it")
end

function TestClientState:test_new_sessions_distinguish_identical_timer_and_counter_values()
    local first = NyrClientState or require("adapter.client_state")
    local a = first.new({ now = function() return 1200 end, session = "first-session" })
    local b = first.new({ now = function() return 1200 end, session = "second-session" })
    lu.assertNotEquals(a:token(), b:token())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
