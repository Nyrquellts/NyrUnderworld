--- Places: bought once, locked properly, and taken back when the rent stops.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Property = require("systems.property")
local Overview = require("systems.overview")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    return items
end

local function build(world, property_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Property.system(property_opts))
    -- `me.nearby` is the only thing that ever tells a player an address
    -- exists, so what it says about a door is a property rule and is tested
    -- where the doors are.
    world:install(Overview.system())
    return world
end

TestProperty = {}

function TestProperty:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world.ledger:transfer("stake-a", "external:mint", Characters.wallet(self.jane), Money.of(5000))
    self.world.ledger:transfer("stake-b", "external:mint", Characters.wallet(self.john), Money.of(5000))
    self.flat = self.world.services.property.build("12 Vespucci",
        { kind = "apartment", price = 250000, rent = 5000, slots = 20, weight = 50000 })
    -- A proximity service, as the adapter would install one.
    self.at = {}
    self.world.services.proximity = function(actor, place) return self.at[actor] == place end
end

function TestProperty:tearDown()
    self.world:deactivate()
end

function TestProperty:ask(name, args, actor, account, operation_id)
    return self.world:dispatch(name, args,
        { actor = actor or self.jane, account = account or ALICE, operation_id = operation_id })
end

--- Somebody else, for the cases two people are not enough for.
function TestProperty:person(first, last, account)
    return self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
end

--- Everything Jane has, spent, so the next rent day is one she misses.
function TestProperty:broke()
    local wallet = Characters.wallet(self.jane)
    self.world.ledger:transfer("spent", wallet, "external:estate", self.world.ledger:balance(wallet))
end

-- ----------------------------------------------------- finding the city

function TestProperty:test_the_map_says_where_things_are()
    -- `me.nearby` answers "what is within reach", which only helps once you are
    -- standing at it. Nothing answered "where is anything", so nothing could be
    -- put on a map and a player could not find a shop they had not been told
    -- the coordinates of.
    local out = self:ask("me.map", {})
    lu.assertTrue(out:succeeded())
    local found
    for _, place in ipairs(out.value.places) do
        if place.place == self.flat.id then found = place end
    end
    lu.assertNotNil(found, "a place in the city is not on the map")
    lu.assertEquals(found.x, self.flat:get("x"))
    lu.assertEquals(found.y, self.flat:get("y"))
    lu.assertEquals(found.z, self.flat:get("z"))
    lu.assertEquals(found.kind, "apartment")
    lu.assertTrue(found.for_sale)
    lu.assertEquals(found.price, 250000)
end

function TestProperty:test_the_map_needs_no_body_to_answer()
    -- Deliberately not proximity. A map read while standing nowhere is the
    -- normal case: it is asked once when somebody spawns, before they have
    -- walked anywhere.
    self.at[self.jane] = nil
    lu.assertTrue(self:ask("me.map", {}):succeeded())
    lu.assertTrue(#self:ask("me.map", {}).value.places > 0)
end

function TestProperty:test_a_place_somebody_lives_in_is_on_the_map_without_a_price()
    self:ask("property.buy", { place = self.flat.id })
    for _, place in ipairs(self:ask("me.map", {}).value.places) do
        if place.place == self.flat.id then
            lu.assertFalse(place.for_sale)
            lu.assertNil(place.price, "what a place cost its owner is theirs")
        end
    end
end

function TestProperty:test_the_map_answers_before_anybody_is_somebody()
    -- This used to assert the opposite, next to a test saying the map is asked
    -- once on spawn. Both held, and together they meant the only read a client
    -- makes was refused every time: the spawn comes before the picker, so at
    -- that moment nobody is playing anybody, and the map a player saw was empty.
    local out = self.world:dispatch("me.map", {}, { account = ALICE })
    lu.assertTrue(out:succeeded(), "a player who has only just arrived was refused the map")
    local found
    for _, place in ipairs(out.value.places) do
        if place.place == self.flat.id then found = place end
    end
    lu.assertNotNil(found, "the map answered and named nothing")
end

function TestProperty:test_what_the_map_says_does_not_depend_on_who_asks()
    -- Answering somebody who is nobody yet is only safe while nothing in the
    -- answer is about the asker. Held here, so a field added later that is
    -- somebody's own business cannot ride out to strangers unnoticed.
    --
    -- Asked as somebody who owns a place. Written first as somebody who owned
    -- nothing, it could not fail: a field telling an owner from a stranger is
    -- the same for two people who own nothing, and a mutation adding one passed.
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }):succeeded())
    local as_nobody = self.world:dispatch("me.map", {}, { account = "license:someone_else" })
    local as_owner = self:ask("me.map", {})
    lu.assertEquals(as_nobody.value, as_owner.value)
end

-- ------------------------------------------------------- finding a door

function TestProperty:test_a_place_for_sale_says_what_it_costs()
    -- The only thing that ever names an address said what the door was called
    -- and not what it cost, so a flat on the market for $2,500 was drawn
    -- exactly like one somebody already lived in and the only thing the screen
    -- offered was to walk in, which was locked. A player could not find out
    -- either without reading the page's own JavaScript.
    self.at[self.jane] = self.flat.id
    local near = self:ask("me.nearby", {})
    lu.assertEquals(#near.value.places, 1, "standing at the flat and it is not listed")
    local door = near.value.places[1]
    lu.assertTrue(door.for_sale, "a flat on the market does not say so")
    lu.assertEquals(door.price, 250000)

    -- And the id it hands over is one the sale accepts, at the price it named.
    local bought = self:ask("property.buy", { place = door.place })
    lu.assertTrue(bought:succeeded())
    lu.assertEquals(bought.value.paid, door.price)
end

function TestProperty:test_premises_say_they_are_not_somewhere_you_walk_in()
    -- `property.enter` refuses a branch and a shop's premises every time, for
    -- everybody, forever: they are held by the council and nobody lives in
    -- them. The screen drew a Go in on all of them anyway, so a seeded city
    -- offered four buttons out of seven that could not work.
    local liquor = self.world.services.property.build("Rob's Liquor, Grove Street",
        { kind = "shop", price = 0, rent = 0 })
    self.at[self.jane] = liquor.id
    local row = self:ask("me.nearby", {}).value.places[1]
    lu.assertEquals(row.place, liquor.id)
    lu.assertFalse(row.enterable, "premises claimed to be somewhere you walk in")

    -- And the refusal it would have run into, so the two agree.
    lu.assertEquals(self:ask("property.enter", { place = liquor.id }).code, "no_key")
end

function TestProperty:test_a_home_is_somewhere_you_walk_in_even_when_it_is_not_yours()
    -- The distinction. A flat is refused because of who is asking today, and
    -- the same door opens the day they own it -- so the screen goes on
    -- offering it and the server goes on deciding.
    self.at[self.john] = self.flat.id
    local before = self:ask("me.nearby", {}, self.john, BOB).value.places[1]
    lu.assertTrue(before.enterable)
    lu.assertFalse(before.may_enter)

    self:ask("property.buy", { place = self.flat.id }, self.john, BOB)
    local after = self:ask("me.nearby", {}, self.john, BOB).value.places[1]
    lu.assertTrue(after.enterable)
    lu.assertTrue(after.may_enter, "buying it did not open the door it offered")
end

function TestProperty:test_a_door_somebody_lives_behind_has_no_price_on_it()
    -- What a place cost its owner is theirs. Once it is sold it is not on the
    -- market, so there is nothing to say and no price is sent.
    self:ask("property.buy", { place = self.flat.id })
    self.at[self.john] = self.flat.id
    local door = self:ask("me.nearby", {}, self.john, BOB).value.places[1]
    lu.assertFalse(door.for_sale)
    lu.assertNil(door.price)
end

function TestProperty:test_a_place_taken_off_the_market_stops_saying_a_price()
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.list", { place = self.flat.id, for_sale = false })
    self.at[self.john] = self.flat.id
    local door = self:ask("me.nearby", {}, self.john, BOB).value.places[1]
    lu.assertFalse(door.for_sale)
    lu.assertNil(door.price)
end

function TestProperty:test_the_door_says_what_the_sale_would_say()
    -- `for_sale` and the state are two facts, and `property.buy` refuses
    -- unless both agree. Nothing in the commands can make them disagree --
    -- listing a place puts it in `listed` and taking it off puts it back in
    -- `owned` -- so the door asks the same question the sale asks rather than
    -- the easier half of it. Forced apart here, the screen must not advertise
    -- something the sale refuses.
    self:ask("property.buy", { place = self.flat.id })
    local places = self.world:repository(Property.Place)
    local held = places:load(self.flat.id)
    held:patch({ for_sale = true })
    places:save(held)
    lu.assertEquals(held.state, "owned")

    self.at[self.john] = self.flat.id
    local door = self:ask("me.nearby", {}, self.john, BOB).value.places[1]
    lu.assertFalse(door.for_sale, "a door offered for sale that the sale refuses")
    lu.assertNil(door.price)
    lu.assertEquals(self:ask("property.buy", { place = self.flat.id }, self.john, BOB).code,
        "not_for_sale")
end

-- --------------------------------------------------- what is not for sale

function TestProperty:test_a_business_front_door_is_not_on_the_market()
    -- The settings file prices a shop's premises at nothing because nobody was
    -- meant to buy them, and every place is born listed. So the city's liquor
    -- store sat on the market at a price of zero and the sale handed the front
    -- door to whoever asked for it by id, wallet untouched. Banking was the
    -- only thing in the city that knew, and it only knew about banks.
    local liquor = self.world.services.property.build("Rob's Liquor, Grove Street",
        { kind = "shop", price = 0, rent = 0 })
    lu.assertFalse(liquor:get("for_sale"))

    self.at[self.jane] = liquor.id
    local door = self:ask("me.nearby", {}).value.places[1]
    lu.assertEquals(door.place, liquor.id)
    lu.assertFalse(door.for_sale, "the shop's front door is offered for sale")
    lu.assertNil(door.price)

    local taken = self:ask("property.buy", { place = liquor.id })
    lu.assertFalse(taken:succeeded())
    lu.assertEquals(taken.code, "not_for_sale")
    lu.assertEquals(self.world.services.property.holder(liquor.id), Property.COUNCIL)
end

function TestProperty:test_premises_are_the_kinds_that_are_traded_from()
    lu.assertTrue(Property.premises("shop"))
    lu.assertTrue(Property.premises("bank"))
    lu.assertFalse(Property.premises("apartment"))
    lu.assertFalse(Property.premises("house"))
    lu.assertFalse(Property.premises("garage"))
    lu.assertFalse(Property.premises(nil))
end

function TestProperty:test_a_city_saved_before_this_has_its_premises_put_right()
    -- Building skips an address that already exists, so a city played before
    -- premises were kept off the market keeps a liquor store whose front door
    -- is for sale at a price of nothing. What the adapter walks at boot, it
    -- asks here.
    local liquor = self.world.services.property.build("Rob's Liquor, Grove Street",
        { kind = "shop", price = 0, rent = 0, for_sale = true })
    lu.assertTrue(Property.left_on_the_market(liquor, Property.COUNCIL))

    -- A flat is housing and the city is meant to be selling it.
    lu.assertFalse(Property.left_on_the_market(self.flat, Property.COUNCIL))
    -- One already put right is not put right twice.
    local shut = self.world.services.property.build("Cypress Flats Scrapyard", { kind = "shop" })
    lu.assertFalse(Property.left_on_the_market(shut, Property.COUNCIL))
    -- And nothing at all is not a place.
    lu.assertFalse(Property.left_on_the_market(nil, Property.COUNCIL))
end

function TestProperty:test_a_shop_the_city_once_sold_stays_sellable()
    -- The migration is for premises that were never meant to be on the market
    -- and have never left the city's hands. A shopfront the server listed,
    -- sold, and took back for arrears is a different thing: it is back with
    -- the council and for sale because it was seized, and boot is not the
    -- place to decide that was a mistake.
    local unit = self.world.services.property.build("Unit 4, Popular Street",
        { kind = "shop", price = 100000, rent = 5000, for_sale = true })
    self:ask("property.buy", { place = unit.id })
    self.world.ledger:transfer("spent", Characters.wallet(self.jane),
        "external:estate", Money.of(4000))
    for _ = 1, 4 * 24 do self.world:tick(Clock.MS_PER_HOUR) end

    local taken = self.world:repository(Property.Place):load(unit.id)
    lu.assertEquals(taken.state, "seized")
    lu.assertTrue(taken:get("for_sale"))
    lu.assertEquals(self.world.services.property.holder(unit.id), Property.COUNCIL)
    lu.assertFalse(Property.left_on_the_market(taken, Property.COUNCIL),
        "a shopfront the city sold once was taken off the market at boot")
end

function TestProperty:test_a_door_nobody_could_stand_at_is_moved_to_where_it_is_now()
    -- `Integrity Way, Apt 28` shipped at z=89, which is the flat's place in
    -- the game's own world and fifty-one metres above the street. A player put
    -- there falls, so nothing was ever within four metres of it and it could
    -- not be found or bought. Correcting config.lua does not reach a city that
    -- has already been played, because building skips an address that exists.
    local flat = self.world.services.property.build("Integrity Way, Apt 28",
        { kind = "apartment", price = 250000, x = -47.0, y = -589.0, z = 89.0, radius = 4.0 })

    local changes = Property.misplaced(flat,
        { x = -47.0, y = -589.0, z = 38.0, radius = 4.0 })
    lu.assertNotNil(changes, "a door fifty-one metres up was left where it was")
    lu.assertEquals(changes, { z = 38.0 })

    flat:patch(changes)
    lu.assertEquals(flat:get("z"), 38.0)
    lu.assertEquals(flat:get("x"), -47.0, "moving one axis moved another")
end

function TestProperty:test_a_place_already_where_it_belongs_is_left_alone()
    -- Nothing to do is nothing to write, so a boot that changes nothing says
    -- nothing and saves nothing.
    lu.assertNil(Property.misplaced(self.flat,
        { x = self.flat:get("x"), y = self.flat:get("y"),
          z = self.flat:get("z"), radius = self.flat:get("radius") }))
    lu.assertNil(Property.misplaced(nil, { x = 1.0 }))
    lu.assertNil(Property.misplaced(self.flat, nil))
end

function TestProperty:test_an_axis_the_settings_file_omits_is_not_an_instruction()
    -- A settings file that leaves out `radius` is not asking for a place with
    -- no radius. Only what it says is applied.
    local changes = Property.misplaced(self.flat, { z = 12.0 })
    lu.assertEquals(changes, { z = 12.0 })
    lu.assertNil(changes.radius)
    lu.assertNil(changes.x)

    -- And a settings entry that says nothing about position asks for nothing.
    -- Without the check that a wanted value is a number this still looks like
    -- four differences -- every one of them an assignment of nil, which writes
    -- nothing -- so it answers "move it" with an empty list of moves, and the
    -- boot line then reports an address moved that did not move.
    lu.assertNil(Property.misplaced(self.flat, {}),
        "a place was reported as misplaced against a settings entry with no position in it")
end

function TestProperty:test_a_shop_somebody_owns_is_left_alone()
    -- An owner who put their own shop up for sale said so. Boot is not the
    -- place to overrule them, and a place that is somebody's is not the
    -- city's to take off the market.
    local unit = self.world.services.property.build("Unit 4, Popular Street",
        { kind = "shop", price = 100000, for_sale = true })
    self:ask("property.buy", { place = unit.id })
    lu.assertEquals(self.world.services.property.holder(unit.id), self.jane)
    self:ask("property.list", { place = unit.id, price = 150000 })

    local held = self.world:repository(Property.Place):load(unit.id)
    lu.assertTrue(held:get("for_sale"))
    lu.assertEquals(held.state, "listed")
    lu.assertFalse(Property.left_on_the_market(held,
        self.world.services.property.holder(unit.id)),
        "an owner's own shop taken off the market at boot")
end

function TestProperty:test_the_city_can_still_say_what_it_is_selling()
    -- The rule is a default, not a lock. A server that wants to sell a lockup
    -- as a shopfront says so and it is sold.
    local unit = self.world.services.property.build("Unit 4, Popular Street",
        { kind = "shop", price = 100000, for_sale = true })
    lu.assertTrue(unit:get("for_sale"))
    self.at[self.jane] = unit.id
    lu.assertTrue(self:ask("me.nearby", {}).value.places[1].for_sale)

    -- And the other way: a flat the city is keeping.
    local kept = self.world.services.property.build("14 Vespucci",
        { kind = "apartment", price = 250000, for_sale = false })
    lu.assertFalse(kept:get("for_sale"))
end

function TestProperty:test_a_new_place_belongs_to_the_city_and_is_for_sale()
    lu.assertEquals(self.world.services.property.holder(self.flat.id), Property.COUNCIL)
    lu.assertEquals(self.flat.state, "listed")
    lu.assertTrue(self.flat:get("for_sale"))
    lu.assertTrue(self.world.services.inventory:has_container(Property.stash(self.flat.id)))
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_buying_moves_the_money_and_the_keys_together()
    local outcome = self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 250000)
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.jane)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2500))
    lu.assertEquals(self.world.ledger:balance("external:estate"), Money.of(2500))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id).state, "owned")
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_two_people_cannot_buy_one_flat()
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }):succeeded())
    local second = self:ask("property.buy", { place = self.flat.id }, self.john, BOB)
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "not_for_sale")
    -- and the loser paid nothing
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(5000))
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.jane)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_buyer_beaten_to_it_gets_their_money_back()
    -- Force the race the compare-and-swap exists for: the register changes
    -- hands between the sale check and the transfer.
    local place = self.world:repository(Property.Place):load(self.flat.id)
    local original = self.world.ownership.transfer
    self.world.ownership.transfer = function(register, operation, asset, from, to, meta)
        register.transfer = original
        -- somebody else got it first
        original(register, "sneak", asset, from, self.john, {})
        return original(register, operation, asset, from, to, meta)
    end
    local outcome = self:ask("property.buy", { place = place.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "sold_already")
    -- money returned, books still sum to nothing
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(5000))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(self.world.services.property.holder(place.id), self.john)
end

function TestProperty:test_you_cannot_buy_what_you_cannot_afford()
    local dear = self.world.services.property.build("1 Alta", { price = 9000000, rent = 100 })
    local outcome = self:ask("property.buy", { place = dear.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "cannot_afford")
    lu.assertEquals(self.world.services.property.holder(dear.id), Property.COUNCIL)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(5000))
end

function TestProperty:test_buying_your_own_place_is_refused()
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.list", { place = self.flat.id, price = 100, for_sale = true })
    local outcome = self:ask("property.buy", { place = self.flat.id })
    lu.assertEquals(outcome.code, "already_yours")
end

function TestProperty:test_selling_on_hands_the_money_to_the_owner()
    self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 300000 }):succeeded())
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }, self.john, BOB):succeeded())
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.john)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(5500))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(2000))
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_only_the_owner_lists_it()
    self:ask("property.buy", { place = self.flat.id })
    local outcome = self:ask("property.list", { place = self.flat.id, price = 1 }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_yours")
end

function TestProperty:test_a_lock_that_cannot_tell_where_you_are_stays_shut()
    -- Failing closed is the only acceptable default for a lock.
    self:ask("property.buy", { place = self.flat.id })
    self.world.services.proximity = nil
    local outcome = self:ask("property.enter", { place = self.flat.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_proximity")
end

function TestProperty:test_being_at_the_door_is_not_something_you_can_claim()
    self:ask("property.buy", { place = self.flat.id })
    local away = self:ask("property.enter", { place = self.flat.id })
    lu.assertTrue(away:was_refused())
    lu.assertEquals(away.code, "too_far")
    -- the command has no field to put a location in
    for _, field in ipairs(self.world.commands:describe("property.enter").args) do
        lu.assertEquals(field.name, "place")
    end
end

function TestProperty:test_the_owner_at_the_door_gets_into_the_stash()
    self:ask("property.buy", { place = self.flat.id })
    self.at[self.jane] = self.flat.id
    local outcome = self:ask("property.enter", { place = self.flat.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.stash, Property.stash(self.flat.id))
    lu.assertTrue(self.world.services.access:may(self.jane, Property.stash(self.flat.id)))

    -- and can actually put something in it
    self.world.services.inventory:spawn("seed", self.jane, "water", 4)
    lu.assertTrue(self:ask("inventory.move", { from = self.jane, to = Property.stash(self.flat.id),
        item = "water", count = 4 }):succeeded())
    lu.assertEquals(self.world.services.inventory:count(Property.stash(self.flat.id), "water"), 4)
    lu.assertTrue(self.world.services.inventory:verify())
end

function TestProperty:test_somebody_without_a_key_gets_nothing_even_at_the_door()
    self:ask("property.buy", { place = self.flat.id })
    self.at[self.john] = self.flat.id
    local outcome = self:ask("property.enter", { place = self.flat.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_key")
    lu.assertFalse(self.world.services.access:may(self.john, Property.stash(self.flat.id)))
end

function TestProperty:test_a_key_can_be_given_and_taken_back()
    self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(self:ask("property.key", { place = self.flat.id, holder = self.john }):succeeded())
    self.at[self.john] = self.flat.id
    lu.assertTrue(self:ask("property.enter", { place = self.flat.id }, self.john, BOB):succeeded())

    lu.assertTrue(self:ask("property.key",
        { place = self.flat.id, holder = self.john, give = false }):succeeded())
    lu.assertEquals(self:ask("property.enter", { place = self.flat.id }, self.john, BOB).code, "no_key")
    -- and who was given a key is on the record, which is what gets asked after
    -- a burglary with no forced entry
    local keys = self.world.services.recall(self.jane, { kind = "property.key" })
    lu.assertEquals(#keys, 2)
    lu.assertFalse(keys[1].meta.given)
    lu.assertTrue(keys[2].meta.given)
end

function TestProperty:test_a_key_goes_only_to_somebody_who_exists()
    -- A key named any well-formed character id and wrote a record line each
    -- time, with no rate limit: the same way to push history out of the record
    -- that police.lookup had.
    self:ask("property.buy", { place = self.flat.id })
    local nobody = "chr_000000000000000000a"
    local refused = self:ask("property.key", { place = self.flat.id, holder = nobody })
    lu.assertEquals(refused.code, "no_such_person")
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "property.key" }), 0)
    lu.assertNil(self.flat:get("keys")[nobody])
    local declared = self.world.commands:describe("property.key")
    lu.assertNotNil(declared.rate, "handing out keys has no rate limit")
end

function TestProperty:test_only_the_owner_hands_out_keys()
    self:ask("property.buy", { place = self.flat.id })
    lu.assertEquals(self:ask("property.key",
        { place = self.flat.id, holder = self.john }, self.john, BOB).code, "not_yours")
end

-- ------------------------------------------------- keys change hands too

function TestProperty:test_a_key_from_before_the_sale_does_not_open_the_buyers_door()
    -- The keys stayed on the place when it changed hands, and a key opens the
    -- door whoever holds the place. A seller who had handed one to a friend,
    -- or to themselves, walked into the buyer's home after the sale and
    -- emptied the stash.
    local friend = self:person("Fred", "Friend", CARLA)
    self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(self:ask("property.key", { place = self.flat.id, holder = friend }):succeeded())
    -- A key to herself, as a city saved before that was refused still has.
    local places = self.world:repository(Property.Place)
    local keys = places:load(self.flat.id):get("keys")
    keys[self.jane] = true
    places:load(self.flat.id):set("keys", keys)
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 300000 }):succeeded())
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }, self.john, BOB):succeeded())

    self.at[friend] = self.flat.id
    self.at[self.jane] = self.flat.id
    self.at[self.john] = self.flat.id
    lu.assertEquals(self:ask("property.enter", { place = self.flat.id }, friend, CARLA).code, "no_key")
    lu.assertEquals(self:ask("property.enter", { place = self.flat.id }).code, "no_key")
    lu.assertEquals(places:load(self.flat.id):get("keys"), {})
    lu.assertTrue(self:ask("property.enter", { place = self.flat.id }, self.john, BOB):succeeded())
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_key_to_your_own_place_is_refused()
    -- An owner needs no key. The only thing a key to yourself ever did was
    -- outlast the sale.
    self:ask("property.buy", { place = self.flat.id })
    local outcome = self:ask("property.key", { place = self.flat.id, holder = self.jane })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "already_yours")
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id):get("keys"), {})
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "property.key" }), 0)
end

function TestProperty:test_a_stash_the_seller_had_open_shuts_when_the_place_is_sold()
    -- Reach lasts thirty real seconds and a sale did not end it, so a seller
    -- standing in the flat as it sold could take what the buyer put in the
    -- stash a moment later.
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.list", { place = self.flat.id, price = 300000 })
    self.at[self.jane] = self.flat.id
    lu.assertTrue(self:ask("property.enter", { place = self.flat.id }):succeeded())
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }, self.john, BOB):succeeded())

    local stash = Property.stash(self.flat.id)
    lu.assertFalse(self.world.services.access:may(self.jane, stash), "the seller's stash stayed open")
    self.world.services.inventory:spawn("seed", self.jane, "water", 2)
    lu.assertEquals(self:ask("inventory.move",
        { from = self.jane, to = stash, item = "water", count = 2 }).code, "out_of_reach")
end

function TestProperty:test_an_owner_turned_out_for_rent_cannot_let_anybody_back_in()
    -- Taking a place back for arrears moved the register and left the keys,
    -- so everybody the owner had handed one to went on walking in, and so did
    -- an owner with a key to herself.
    local friend = self:person("Fred", "Friend", CARLA)
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.key", { place = self.flat.id, holder = friend })
    local places = self.world:repository(Property.Place)
    local keys = places:load(self.flat.id):get("keys")
    keys[self.jane] = true
    places:load(self.flat.id):set("keys", keys)
    self:broke()

    -- Standing in the flat, stash open, ten seconds before the third rent
    -- day she cannot pay.
    self.world:tick(2 * Clock.MS_PER_DAY + 59 * Clock.MS_PER_MINUTE + 50 * Clock.MS_PER_SECOND)
    self.at[self.jane] = self.flat.id
    lu.assertTrue(self:ask("property.enter", { place = self.flat.id }):succeeded())
    self.world:tick(20 * Clock.MS_PER_SECOND)
    lu.assertEquals(self.world.services.property.holder(self.flat.id), Property.COUNCIL)
    lu.assertFalse(self.world.services.access:may(self.jane, Property.stash(self.flat.id)),
        "the stash stayed open for the owner it was taken from")

    self.at[friend] = self.flat.id
    lu.assertEquals(self:ask("property.enter", { place = self.flat.id }, friend, CARLA).code, "no_key")
    lu.assertEquals(self:ask("property.enter", { place = self.flat.id }).code, "no_key")
    lu.assertEquals(places:load(self.flat.id):get("keys"), {})
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_rent_comes_out_every_day()
    self:ask("property.buy", { place = self.flat.id })
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2500))
    -- rent is 5,000 minor units, which is fifty a day
    for _ = 1, 3 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2350))
    lu.assertEquals(self.world.ledger:balance("external:council"), Money.of(150))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_missing_the_rent_is_a_count_of_days_not_a_debt()
    self:ask("property.buy", { place = self.flat.id })
    -- spend everything
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:estate", Money.of(2500))
    local arrears = {}
    self.world:on("property.arrears", function(payload) arrears[#arrears + 1] = payload end, { label = "spec" })

    for _ = 1, 2 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(#arrears, 2)
    lu.assertEquals(arrears[2].missed, 2)
    -- the wallet did not go negative, which is the invariant that matters
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.zero)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.jane)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_enough_missed_days_and_the_city_takes_it_back()
    self:ask("property.buy", { place = self.flat.id })
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:estate", Money.of(2500))
    local seized
    self.world:on("property.seized", function(payload) seized = payload end, { label = "spec" })

    for _ = 1, 4 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertNotNil(seized)
    lu.assertEquals(seized.missed, 3)
    lu.assertEquals(self.world.services.property.holder(self.flat.id), Property.COUNCIL)
    local place = self.world:repository(Property.Place):load(self.flat.id)
    lu.assertEquals(place.state, "seized")
    lu.assertTrue(place:get("for_sale"))
    lu.assertEquals(place:get("arrears"), 0)
    -- and being turned out is on the record for good
    local history = self.world.services.recall(self.jane, { kind = "property.seized" })
    lu.assertEquals(#history, 1)
    lu.assertEquals(history[1].meta.address, "12 Vespucci")
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_paying_what_you_owe_clears_it()
    self:ask("property.buy", { place = self.flat.id })
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:estate", Money.of(2500))
    for _ = 1, 2 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id):get("arrears"), 2)

    self.world.ledger:transfer("wages", "external:payroll", Characters.wallet(self.jane), Money.of(200))
    local outcome = self:ask("property.settle", { place = self.flat.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value, { paid = 10000 })
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id):get("arrears"), 0)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(100))

    -- and now it is not taken away
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.jane)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_settling_nothing_is_refused()
    self:ask("property.buy", { place = self.flat.id })
    lu.assertEquals(self:ask("property.settle", { place = self.flat.id }).code, "nothing_owed")
    lu.assertEquals(self:ask("property.settle", { place = self.flat.id }, self.john, BOB).code, "not_yours")
end

function TestProperty:test_paying_rent_again_clears_an_old_arrear()
    self:ask("property.buy", { place = self.flat.id })
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:estate", Money.of(2500))
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id):get("arrears"), 1)
    self.world.ledger:transfer("wages", "external:payroll", Characters.wallet(self.jane), Money.of(500))
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world:repository(Property.Place):load(self.flat.id):get("arrears"), 0)
end

function TestProperty:test_rent_for_days_the_server_was_away_is_rent_for_each_of_them()
    -- Catching up after a stall runs the rent task once for every day missed,
    -- all at the same moment. The charge was named after that moment, so each
    -- day after the first was the same operation as the first and was waved
    -- through as a duplicate: five days owed, one charged, no arrears.
    self:ask("property.buy", { place = self.flat.id })
    self.world:tick(5 * Clock.MS_PER_DAY)
    lu.assertEquals(self.world.ledger:balance("external:council"), Money.of(250))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2250))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

-- ---------------------------------------- on the market and still owed

function TestProperty:test_a_place_put_on_the_market_still_pays_rent()
    -- Rent was charged by state, and only in `owned`. Listing moves a place
    -- to `listed`, so putting it up at a price nobody would pay stopped the
    -- rent for good.
    self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 1000000000 }):succeeded())
    for _ = 1, 2 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2400))
    lu.assertEquals(self.world.ledger:balance("external:council"), Money.of(100))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_place_taken_back_off_the_market_is_owned_again()
    -- Nothing moved a place back out of `listed`, so one put up and taken
    -- straight down again went on saying it was on the market.
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.list", { place = self.flat.id, price = 1000000000 })
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, for_sale = false }):succeeded())
    local place = self.world:repository(Property.Place):load(self.flat.id)
    lu.assertEquals(place.state, "owned")
    lu.assertFalse(place:get("for_sale"))
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(2450))
    lu.assertEquals(self:ask("property.buy", { place = self.flat.id }, self.john, BOB).code, "not_for_sale")
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_putting_a_place_in_arrears_on_the_market_does_not_keep_it()
    -- Arrears stopped counting while a place was listed, so an owner about to
    -- be turned out could list it and keep it for ever.
    self:ask("property.buy", { place = self.flat.id })
    self:broke()
    for _ = 1, 2 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 1000000000 }):succeeded())
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.property.holder(self.flat.id), Property.COUNCIL)
    local place = self.world:repository(Property.Place):load(self.flat.id)
    lu.assertEquals(place.state, "seized")
    lu.assertTrue(place:get("for_sale"))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_place_the_city_took_back_and_sold_again_is_an_ordinary_home()
    -- `seized` could only become `listed`, and the sale ignored the answer, so
    -- a seized flat that was bought went on saying seized: no rent, and never
    -- a way back on the market.
    self:ask("property.buy", { place = self.flat.id })
    self:broke()
    for _ = 1, 4 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    local place = self.world:repository(Property.Place):load(self.flat.id)
    lu.assertEquals(place.state, "seized")

    lu.assertTrue(self:ask("property.buy", { place = self.flat.id }, self.john, BOB):succeeded())
    lu.assertEquals(place.state, "owned")
    lu.assertFalse(place:get("for_sale"))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(2500))
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(2450))
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 300000 }, self.john, BOB):succeeded())
    lu.assertEquals(place.state, "listed")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_sale_the_place_cannot_make_takes_no_money()
    -- Whether the place can end up owned is asked before anything moves. A
    -- sale that took the money and the register and only then found the place
    -- could not be owned would leave it half sold.
    local place = self.world:repository(Property.Place):load(self.flat.id)
    place.can_transition = function() return false end
    local outcome = self:ask("property.buy", { place = self.flat.id })
    place.can_transition = nil
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_for_sale")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(5000))
    lu.assertEquals(self.world.services.property.holder(self.flat.id), Property.COUNCIL)
    lu.assertTrue(place:get("for_sale"))
    lu.assertEquals(place.state, "listed")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_a_listing_the_place_cannot_make_changes_nothing()
    -- The same question, asked before the listing touches the place: a place
    -- left for sale in `for_sale` and not in its state is a door the screen
    -- offers and the sale refuses.
    self:ask("property.buy", { place = self.flat.id })
    local place = self.world:repository(Property.Place):load(self.flat.id)
    place.can_transition = function() return false end
    local outcome = self:ask("property.list", { place = self.flat.id, price = 300000 })
    place.can_transition = nil
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "bad_listing")
    lu.assertFalse(place:get("for_sale"))
    lu.assertEquals(place:get("price"), 250000)
    lu.assertEquals(place.state, "owned")
end

function TestProperty:test_listing_is_a_change_not_a_question()
    -- property.list was declared read_only, which tells the command door it
    -- changes nothing. So it kept no receipt -- a retried listing ran again --
    -- and it had no rate, while it rewrote the place every time.
    self:ask("property.buy", { place = self.flat.id })
    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 300000 },
        nil, nil, "list-1"):succeeded())
    local again = self:ask("property.list", { place = self.flat.id, price = 300000 }, nil, nil, "list-1")
    lu.assertTrue(again.details ~= nil and again.details.duplicate == true, "a retried listing ran again")
    local too_fast = false
    for index = 1, 20 do
        if self:ask("property.list", { place = self.flat.id, price = 300000 + index }).code == "too_fast" then
            too_fast = true
            break
        end
    end
    lu.assertTrue(too_fast, "listing had no rate")
end

-- ------------------------------------------------------ what was shown

function TestProperty:test_a_buyer_pays_the_price_they_were_shown_or_nothing()
    -- The sale named the place and not the price, so a seller who put the
    -- price up between the buyer reading the door and pressing buy was paid
    -- the new one. The buyer says what they saw, and a different price now is
    -- a refusal before anything moves.
    self:ask("property.buy", { place = self.flat.id })
    self:ask("property.list", { place = self.flat.id, price = 100000 })
    self.at[self.john] = self.flat.id
    local shown = self:ask("me.nearby", {}, self.john, BOB).value.places[1].price
    lu.assertEquals(shown, 100000)

    lu.assertTrue(self:ask("property.list", { place = self.flat.id, price = 490000 }):succeeded())
    local outcome = self:ask("property.buy", { place = self.flat.id, price = shown }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "price_changed")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(5000))
    lu.assertEquals(self.world.services.property.holder(self.flat.id), self.jane)

    -- And at the price the door says now, it sells.
    local now_shown = self:ask("me.nearby", {}, self.john, BOB).value.places[1].price
    lu.assertTrue(self:ask("property.buy", { place = self.flat.id, price = now_shown },
        self.john, BOB):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(100))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestProperty:test_nobody_can_do_any_of_it_without_being_somebody()
    for _, name in ipairs({ "property.buy", "property.enter", "property.settle" }) do
        lu.assertEquals(self.world:dispatch(name, { place = self.flat.id }, { account = ALICE }).code,
            "not_playing")
    end
end

function TestProperty:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Property.system()) end)
end

TestPropertyRestart = {}

function TestPropertyRestart:setUp()
    for _, name in ipairs({ "world", "chr", "prp" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestPropertyRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestPropertyRestart:test_a_place_is_still_yours_and_the_stash_is_still_full()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(jane), Money.of(5000))
    local flat = first.services.property.build("12 Vespucci", { price = 250000, rent = 5000 })
    first:dispatch("property.buy", { place = flat.id }, { actor = jane, account = ALICE })
    first.services.inventory:spawn("seed", Property.stash(flat.id), "water", 9)
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    lu.assertEquals(self.world.services.property.holder(flat.id), jane)
    lu.assertEquals(self.world.services.inventory:count(Property.stash(flat.id), "water"), 9)
    lu.assertEquals(self.world.services.inventory:space(Property.stash(flat.id)).slots, 40)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(jane)), Money.of(2500))
    lu.assertTrue(self.world:verify())
    lu.assertTrue(self.world.services.inventory:verify())
end

function TestPropertyRestart:test_restart_does_not_replay_rent_from_the_beginning_of_the_city()
    local store = require("persistence.memory_store").new()
    local first = build(World.new({ store = store, rate = 1,
        start_at = 3 * Clock.MS_PER_DAY + 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(jane), Money.of(2500))
    local flat = first.services.property.build("Restart Apartment", { price = 250000, rent = 5000 })
    lu.assertTrue(first:dispatch("property.buy", { place = flat.id }, { actor = jane, account = ALICE }).ok)
    lu.assertTrue(first:close())
    self.world = build(World.new({ store = store, rate = 1 }))
    lu.assertTrue(self.world:load())
    self.world:tick(Clock.MS_PER_HOUR)
    local place = self.world:repository(Property.Place):load(flat.id)
    lu.assertEquals(place:get("arrears"), 1)
    lu.assertEquals(self.world.services.property.holder(flat.id), jane)
    lu.assertEquals(place.state, "owned")
end

function TestPropertyRestart:test_a_seized_place_bought_before_this_is_owned_after_a_restart()
    -- A city played before a sale could make a seized place owned still has
    -- places saying `seized` under the people who bought them. Taking one of
    -- those back for rent would be a move from `seized` to `seized`, which is
    -- not a move, so its owner could stop paying and keep it.
    local store = require("persistence.memory_store").new()
    local first = build(World.new({ store = store, rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(jane), Money.of(2500))
    local flat = first.services.property.build("Seized Apartment", { price = 250000, rent = 5000 })
    lu.assertTrue(first:dispatch("property.buy", { place = flat.id }, { actor = jane, account = ALICE }).ok)
    -- What the sale left behind before it asked whether the place could be owned.
    flat.state = "seized"
    lu.assertTrue(first.services.property.places:save(flat))
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = store, rate = 1 }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems or {}, "; "))
    local place = self.world:repository(Property.Place):load(flat.id)
    lu.assertEquals(place.state, "owned")
    lu.assertEquals(self.world.services.property.holder(flat.id), jane)

    -- And missing the rent takes it back like any other.
    for _ = 1, 4 * 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.property.holder(flat.id), Property.COUNCIL)
    lu.assertEquals(place.state, "seized")
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
