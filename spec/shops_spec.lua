--- The loop closes here: work pays, a shop takes the money, the goods are
--- worth taking, and taking them is a crime the police already handle.
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
local Police = require("systems.police")
local Shops = require("systems.shops")
local Overview = require("systems.overview")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    items:define("brick", { label = "Gold Brick", weight = 12000, stack = 1, category = "valuable" })
    items:define("passport", { label = "Passport", weight = 30, unique = true,
                               category = "document", sellable = false })
    return items
end

local function build(world, shop_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue(), slots = 10, weight = 30000 }))
    world:install(Property.system())
    world:install(Police.system())
    world:install(Shops.system(shop_opts))
    world:install(Overview.system())
    return world
end

TestShops = {}

function TestShops:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world.ledger:transfer("stake-a", "external:mint", Characters.wallet(self.jane), Money.of(1000))
    self.world.ledger:transfer("stake-b", "external:mint", Characters.wallet(self.john), Money.of(1000))

    self.place = self.world.services.property.build("Rob's Liquor, Grove Street",
        { kind = "shop", price = 0, rent = 0, x = 1.0, y = 2.0, z = 3.0, radius = 5.0 })
    self.shop = self.world.services.shops.open("Rob's Liquor", self.place.id, {
        prices = { water = { buy = 250, sell = 100 }, brick = { buy = 900000, sell = 400000 } },
        restock = { water = 40 },
        float = 50000,
    })

    self.at, self.seen = {}, {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.witnesses = function() return self.seen end
    self.at[self.jane] = self.place.id
    self.at[self.john] = self.place.id
end

function TestShops:tearDown()
    -- Nothing here is allowed to create or destroy money or goods.
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    local stock, stock_problems = self.world.services.inventory:verify()
    lu.assertTrue(stock, table.concat(stock_problems, "; "))
    self.world:deactivate()
end

function TestShops:ask(name, args, actor, account, operation_id)
    return self.world:dispatch(name, args,
        { actor = actor or self.jane, account = account or ALICE, operation_id = operation_id })
end

function TestShops:counter() return Shops.counter(self.shop.id) end

function TestShops:test_a_shop_opens_stocked_and_with_a_float()
    lu.assertEquals(self.shop.state, "open")
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "water"), 40)
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(500))
    lu.assertEquals(self.world.services.inventory:total("water"), 40)
end

function TestShops:test_the_list_says_what_it_sells_and_what_it_pays()
    local outcome = self:ask("shop.list", { shop = self.shop.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.name, "Rob's Liquor")
    lu.assertEquals(#outcome.value.lines, 2)
    lu.assertEquals(outcome.value.lines[1].item, "brick")
    lu.assertEquals(outcome.value.lines[2].item, "water")
    lu.assertEquals(outcome.value.lines[2].buy, 250)
    lu.assertEquals(outcome.value.lines[2].sell, 100)
    lu.assertEquals(outcome.value.lines[2].stock, 40)
end

function TestShops:test_buying_moves_money_one_way_and_goods_the_other()
    local outcome = self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 4 })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 1000)
    lu.assertEquals(self.world.services.inventory:count(self.jane, "water"), 4)
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "water"), 36)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(990))
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(510))
    -- and nothing was created on either side
    lu.assertEquals(self.world.services.inventory:total("water"), 40)
end

function TestShops:test_the_buyer_never_says_what_it_costs()
    -- There is no price field, so there is nothing to forge.
    local described = self.world.commands:describe("shop.buy")
    for _, field in ipairs(described.args) do
        lu.assertNotEquals(field.name, "price")
        lu.assertNotEquals(field.name, "paid")
        lu.assertNotEquals(field.name, "total")
    end
    local lying = self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1, price = 0 })
    lu.assertEquals(lying.code, "bad_args")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
end

function TestShops:test_you_cannot_buy_what_it_does_not_sell_or_does_not_have()
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "passport", count = 1 }).code,
        "not_stocked")
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "brick", count = 1 }).code,
        "out_of_stock")
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 100 }).code,
        "out_of_stock")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
end

function TestShops:test_what_will_not_fit_is_refused_before_the_money_moves()
    -- She can carry thirty kilograms and a gold brick is twelve, so three will
    -- not go. The fit is checked before the price, which is why this is
    -- refused rather than paid for and then refunded.
    self.world.services.inventory:spawn("gold", self:counter(), "brick", 3)
    local outcome = self:ask("shop.buy", { shop = self.shop.id, item = "brick", count = 3 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "cannot_carry")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "brick"), 3)
    -- two of them would fit, and then the price is what stops her
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "brick", count = 2 }).code,
        "cannot_afford")
end

function TestShops:test_what_you_cannot_afford_is_refused_and_costs_nothing()
    self.world.services.inventory:spawn("gold", self:counter(), "brick", 1)
    local outcome = self:ask("shop.buy", { shop = self.shop.id, item = "brick", count = 1 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "cannot_afford")
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "brick"), 1)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
end

function TestShops:test_two_people_cannot_buy_the_last_one()
    -- Drain it to a single bottle, then have both of them reach for it.
    self.world.services.inventory:destroy("drain", self:counter(), "water", 39)
    lu.assertTrue(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }):succeeded())
    local second = self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }, self.john, BOB)
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "out_of_stock")
    -- the loser paid nothing
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(1000))
    lu.assertEquals(self.world.services.inventory:total("water"), 1)
end

function TestShops:test_the_same_purchase_arriving_twice_buys_once()
    local first = self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 2 }, nil, nil, "buy-1")
    local second = self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 2 }, nil, nil, "buy-1")
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.world.services.inventory:count(self.jane, "water"), 2)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(995))
end

-- ------------------------------------------------------------------ selling

function TestShops:test_selling_pays_from_the_till_at_the_shop_price()
    self.world.services.inventory:spawn("seed", self.jane, "water", 6)
    local outcome = self:ask("shop.sell", { shop = self.shop.id, item = "water", count = 6 })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 600)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1006))
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(494))
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "water"), 46)
end

function TestShops:test_a_shop_that_cannot_pay_does_not_buy()
    self.world.services.inventory:spawn("seed", self.jane, "brick", 2)
    local outcome = self:ask("shop.sell", { shop = self.shop.id, item = "brick", count = 2 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "till_empty")
    -- the till did not go negative and she still has her bricks
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(500))
    lu.assertEquals(self.world.services.inventory:count(self.jane, "brick"), 2)
end

function TestShops:test_some_things_are_not_sellable_and_some_shops_do_not_buy()
    self.world.services.inventory:spawn("papers", self.jane, "passport", 1)
    lu.assertEquals(self:ask("shop.sell", { shop = self.shop.id, item = "passport", count = 1 }).code,
        "not_buying")
    self.world.services.inventory:spawn("seed", self.jane, "water", 1)
    lu.assertTrue(self:ask("shop.sell", { shop = self.shop.id, item = "water", count = 1 }):succeeded())
end

function TestShops:test_selling_what_you_do_not_have_pays_nothing()
    local outcome = self:ask("shop.sell", { shop = self.shop.id, item = "water", count = 3 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_carrying")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
end

function TestShops:test_a_shop_never_pays_more_than_it_charges()
    -- Buy low from the shop, sell high to the same shop, repeat until the
    -- economy is meaningless. Refused at the moment the shop is declared, with
    -- the item named, which is how this was caught on a real server start.
    lu.assertErrorMsgContains("money printer", function()
        return self.world.services.shops.open("Money Printer", self.place.id,
            { prices = { water = { buy = 100, sell = 500 } } })
    end)
    lu.assertError(function()
        return self.world.services.shops.open("Sells Nothing", self.place.id,
            { prices = { water = {} } })
    end)
end

function TestShops:test_a_shop_can_buy_something_it_does_not_sell()
    -- A scrapyard takes metal and stocks none of it. That is a price entry
    -- with a sell side and no buy side, not a buy price of nothing, which
    -- would be the money printer above.
    local yard_place = self.world.services.property.build("Scrapyard", { kind = "shop" })
    local yard = self.world.services.shops.open("Scrapyard", yard_place.id,
        { prices = { brick = { sell = 100 } }, float = 50000 })
    self.at[self.jane] = yard_place.id
    self.world.services.inventory:spawn("seed", self.jane, "brick", 2)

    lu.assertEquals(self:ask("shop.buy", { shop = yard.id, item = "brick", count = 1 }).code,
        "not_stocked")
    lu.assertTrue(self:ask("shop.sell", { shop = yard.id, item = "brick", count = 2 }):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1002))
    -- and it reads as sell-only in the listing
    local lines = self:ask("shop.list", { shop = yard.id }).value.lines
    lu.assertEquals(#lines, 1)
    lu.assertNil(lines[1].buy)
    lu.assertEquals(lines[1].sell, 100)
end

-- ----------------------------------------------------------------- robbery

function TestShops:rob(actor, account)
    local first = self:ask("shop.rob", { shop = self.shop.id }, actor, account)
    self.world.clock:skip(45 * Clock.MS_PER_SECOND)
    return first, self:ask("shop.rob", { shop = self.shop.id }, actor, account)
end

function TestShops:test_robbing_takes_what_is_in_the_till_and_takes_time()
    local started, finished = self:rob(self.john, BOB)
    lu.assertEquals(started.code, "working")
    lu.assertEquals(started.details.seconds, 45)
    lu.assertTrue(finished:succeeded())
    lu.assertEquals(finished.value.taken, 50000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(1500))
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.zero)
    lu.assertEquals(self.world.services.shops.shops:load(self.shop.id).state, "robbed")
end

function TestShops:test_the_robber_never_says_what_the_take_is()
    local described = self.world.commands:describe("shop.rob")
    lu.assertEquals(#described.args, 1)
    lu.assertEquals(described.args[1].name, "shop")
    local lying = self:ask("shop.rob", { shop = self.shop.id, taken = 99999999 }, self.john, BOB)
    lu.assertEquals(lying.code, "bad_args")
end

function TestShops:test_the_take_is_capped_by_the_server()
    self.world.ledger:transfer("fat", "external:mint", self:counter(), Money.of(9000))
    local _, finished = self:rob(self.john, BOB)
    lu.assertTrue(finished:succeeded())
    lu.assertEquals(finished.value.taken, 100000)      -- the cap, not the till
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(8500))
end

function TestShops:test_an_empty_till_is_not_worth_robbing()
    self.world.ledger:transfer("empty", self:counter(), "external:mint", Money.of(500))
    local outcome = self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "nothing_to_take")
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.robbery" }), 0)
end

function TestShops:test_a_robbery_nobody_saw_leaves_no_heat_and_a_full_record()
    local _, finished = self:rob(self.john, BOB)
    lu.assertFalse(finished.value.witnessed)
    lu.assertEquals(self.world.services.heat(self.john), 0)
    local record = self.world.services.recall(self.john, { kind = "crime.robbery" })
    lu.assertEquals(#record, 1)
    lu.assertEquals(record[1].place, self.place.id)
    lu.assertEquals(record[1].meta.shop, "Rob's Liquor")
    lu.assertEquals(record[1].meta.taken, 50000)
end

function TestShops:test_a_robbery_somebody_saw_makes_you_wanted_and_arrestable()
    -- The whole loop, and nothing in police or memory changed to allow it.
    self.seen = { self.jane }
    local _, finished = self:rob(self.john, BOB)
    lu.assertTrue(finished.value.witnessed)
    lu.assertEquals(self.world.services.heat(self.john), 40)

    local officer = self.world:dispatch("character.create",
        { first_name = "Kate", last_name = "Ward" }, { account = "license:cccc3333" }).value
    self.world.services.police.commission(officer)
    self.world:dispatch("police.duty", { on = true }, { actor = officer, account = "license:cccc3333" })
    self.at[officer] = self.john

    local arrest = self.world:dispatch("police.arrest", { suspect = self.john },
        { actor = officer, account = "license:cccc3333" })
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(arrest.value.offences, { "robbery" })
    lu.assertEquals(arrest.value.minutes, 15)
    lu.assertEquals(self.world.services.heat(self.john), 0)
    -- and the shop is on the record as the place it happened
    lu.assertEquals(self.world.services.record:tally(self.john,
        { kind = "crime.robbery", place = self.place.id }), 1)
end

function TestShops:test_the_neighbourhood_thinks_less_of_it_whether_or_not_anybody_saw()
    self:rob(self.john, BOB)
    lu.assertEquals(self.world.services.standing:score(self.john, "place:" .. self.place.id), -15)
end

function TestShops:test_a_shop_that_was_just_robbed_is_shut_and_then_is_not()
    self:rob(self.john, BOB)
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }).code, "shut")
    lu.assertEquals(self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB).code, "shut")
    -- it opens again on its own; a shop robbed once must not become scenery
    for _ = 1, 3 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.shops.shops:load(self.shop.id).state, "open")
    lu.assertTrue(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }):succeeded())
end

function TestShops:test_a_robbery_cannot_be_started_days_ahead()
    -- The server asks where somebody is when they press and at no time in
    -- between, and the first press never ran out. Press once, walk off, come
    -- back two days later, and one press took the till.
    lu.assertEquals(self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB).code, "working")
    self.at[self.john] = nil
    self.world.clock:skip(2 * Clock.MS_PER_DAY)
    self.at[self.john] = self.place.id
    local again = self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB)
    lu.assertEquals(again.code, "working")
    lu.assertEquals(again.details.seconds, 45)
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(500))
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.robbery" }), 0)
    -- and the wait it starts is the ordinary one
    self.world.clock:skip(45 * Clock.MS_PER_SECOND)
    lu.assertTrue(self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB):succeeded())
end

function TestShops:test_a_first_press_is_good_for_a_minute_after_the_wait()
    -- A minute is longer than somebody still at the counter takes to press
    -- again. This world runs a city millisecond to a real one.
    lu.assertEquals(self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB).code, "working")
    self.world.clock:skip(45 * Clock.MS_PER_SECOND + 59 * Clock.MS_PER_SECOND)
    lu.assertTrue(self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB):succeeded())

    local other_place = self.world.services.property.build("Second Shop", { kind = "shop" })
    local other = self.world.services.shops.open("Second Shop", other_place.id,
        { prices = { water = { buy = 250 } }, float = 50000 })
    self.at[self.john] = other_place.id
    lu.assertEquals(self:ask("shop.rob", { shop = other.id }, self.john, BOB).code, "working")
    self.world.clock:skip(45 * Clock.MS_PER_SECOND + 61 * Clock.MS_PER_SECOND)
    lu.assertEquals(self:ask("shop.rob", { shop = other.id }, self.john, BOB).code, "working")
    lu.assertEquals(self.world.services.shops.till_of(other), Money.of(500))
end

function TestShops:test_starting_on_one_shop_does_not_finish_another()
    local other_place = self.world.services.property.build("Second Shop", { kind = "shop" })
    local other = self.world.services.shops.open("Second Shop", other_place.id,
        { prices = { water = { buy = 250 } }, float = 50000 })
    self:ask("shop.rob", { shop = self.shop.id }, self.john, BOB)
    self.world.clock:skip(45 * Clock.MS_PER_SECOND)
    self.at[self.john] = other_place.id
    lu.assertEquals(self:ask("shop.rob", { shop = other.id }, self.john, BOB).code, "working")
    lu.assertEquals(self.world.services.shops.till_of(other), Money.of(500))
end

-- ------------------------------------------------------------- the basics

function TestShops:test_a_shop_is_on_the_map_under_its_own_name()
    -- The map has to name the shop, not the building. A player looking for
    -- Rob's Liquor is not looking for "Rob's Liquor, Grove Street" -- and a
    -- shop is not where the shop is, it is where its premises are, which is
    -- the mistake that once made `me.nearby` list nothing at all.
    local out = self:ask("me.map", {})
    lu.assertTrue(out:succeeded())
    local counter
    for _, place in ipairs(out.value.places) do
        if place.shop == self.shop.id then counter = place end
    end
    lu.assertNotNil(counter, "the shop is not on the map")
    lu.assertEquals(counter.name, self.shop:get("name"))
    lu.assertEquals(counter.x, self.place:get("x"))
    lu.assertEquals(counter.y, self.place:get("y"))

    -- And the id it puts on the map is one the counter accepts.
    lu.assertTrue(self:ask("shop.list", { shop = counter.shop }).ok)
end

function TestShops:test_a_shop_is_something_a_player_can_find()
    -- `me.nearby` is the only thing that ever tells a player a shop id, and it
    -- asked proximity about the shop's own id. Nothing on the server knows
    -- where a `shp` is -- `position_of` answers for a prp, a veh, a trf and a
    -- chr -- so the answer was always no, the list was always empty, and the
    -- counter could not be reached at all in ordinary play. Nothing failed and
    -- nothing was logged; the shop was simply never mentioned.
    local near = self:ask("me.nearby", {})
    lu.assertTrue(near.ok)
    lu.assertEquals(#near.value.shops, 1, "standing at the shop and it is not listed")
    lu.assertEquals(near.value.shops[1].shop, self.shop.id)

    -- And the id it hands over is one the counter accepts.
    lu.assertTrue(self:ask("shop.list", { shop = near.value.shops[1].shop }).ok)
end

function TestShops:test_a_shop_across_town_is_not_listed()
    self.at[self.jane] = nil
    lu.assertEquals(#self:ask("me.nearby", {}).value.shops, 0)
end

function TestShops:test_you_have_to_be_there()
    self.at[self.jane] = nil
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }).code, "too_far")
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 1 }).code,
        "no_proximity")
end

function TestShops:test_nobody_shops_without_being_somebody()
    for _, name in ipairs({ "shop.list", "shop.buy", "shop.sell", "shop.rob" }) do
        local args = { shop = self.shop.id, item = "water", count = 1 }
        if name == "shop.list" or name == "shop.rob" then args = { shop = self.shop.id } end
        lu.assertEquals(self.world:dispatch(name, args, { account = ALICE }).code, "not_playing", name)
    end
end

function TestShops:test_a_delivery_arrives_every_morning()
    self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 10 })
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "water"), 30)
    self.world.ledger:transfer("empty", self:counter(), "external:mint",
        self.world.services.shops.till_of(self.shop))

    -- six in the morning, the next day
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.inventory:count(self:counter(), "water"), 40)
    lu.assertTrue(self.world.services.shops.till_of(self.shop):is_positive())
end

--- Another shop, on its own premises, with Jane standing at its counter.
function TestShops:corner(shop_opts, name)
    name = name or "Corner Two"
    local place = self.world.services.property.build(name, { kind = "shop" })
    self.at[self.jane] = place.id
    return self.world.services.shops.open(name, place.id, shop_opts)
end

function TestShops:morning()
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
end

function TestShops:test_what_a_shop_only_buys_does_not_fill_its_stockroom_for_good()
    -- Nothing took out what a shop buys and never sells. Once its stockroom
    -- was full of it, selling to the shop was refused for good, and the
    -- morning delivery could not be placed, so what it did sell ran out too.
    local corner = self:corner({ prices = { water = { buy = 250, sell = 100 }, brick = { sell = 100 } },
        restock = { water = 24 }, slots = 3, float = 50000 })
    local inventory = self.world.services.inventory
    local counter = Shops.counter(corner.id)
    inventory:spawn("brick-1", self.jane, "brick", 1)
    lu.assertTrue(self:ask("shop.sell", { shop = corner.id, item = "brick", count = 1 }):succeeded())
    lu.assertTrue(self:ask("shop.buy", { shop = corner.id, item = "water", count = 24 }):succeeded())
    inventory:destroy("drunk", self.jane, "water", 24)
    for n = 2, 3 do
        inventory:spawn("brick-" .. n, self.jane, "brick", 1)
        lu.assertTrue(self:ask("shop.sell", { shop = corner.id, item = "brick", count = 1 }):succeeded())
    end
    inventory:spawn("brick-4", self.jane, "brick", 1)
    lu.assertEquals(self:ask("shop.sell", { shop = corner.id, item = "brick", count = 1 }).code, "shop_full")

    self:morning()
    lu.assertEquals(inventory:count(counter, "brick"), 0)
    lu.assertEquals(inventory:count(counter, "water"), 24)
    lu.assertTrue(self:ask("shop.sell", { shop = corner.id, item = "brick", count = 1 }):succeeded())
    -- They left the world across a named reason, the way stock comes into it.
    local returned
    for _, entry in ipairs(inventory:log()) do
        if entry.action == "destroy" and entry.container == counter and entry.item == "brick" then
            returned = entry
        end
    end
    lu.assertNotNil(returned, "the bricks went without a line saying so")
    lu.assertEquals(returned.count, 3)
    lu.assertEquals(returned.reason, "returned to the supplier")
end

function TestShops:test_a_morning_delivery_takes_back_what_is_over_the_restock_level()
    -- Restock is how many a shop carries when full, and that is all the
    -- stockroom keeps: water bought back from people past it, and bricks it
    -- sells but does not carry, would otherwise fill it the same way.
    local inventory = self.world.services.inventory
    inventory:spawn("crate", self.jane, "water", 12)
    lu.assertTrue(self:ask("shop.sell", { shop = self.shop.id, item = "water", count = 12 }):succeeded())
    inventory:spawn("gold", self:counter(), "brick", 2)
    lu.assertEquals(inventory:count(self:counter(), "water"), 52)

    self:morning()
    lu.assertEquals(inventory:count(self:counter(), "water"), 40)
    lu.assertEquals(inventory:count(self:counter(), "brick"), 0)
end

function TestShops:test_the_morning_float_is_the_one_the_shop_was_opened_with()
    -- The top-up used the system's own figure, and the server installs shops
    -- with none, so every till was floated to five hundred: a shop opened with
    -- no float was handed five hundred every morning, and one opened with five
    -- thousand was topped back up to five hundred.
    local none = self:corner({ prices = { water = { buy = 250, sell = 100 } }, float = 0 }, "Pawn Counter")
    local big = self:corner({ prices = { water = { buy = 250, sell = 100 } }, float = 500000 }, "Big Buyer")
    self.world.ledger:transfer("spent", Shops.counter(big.id), "external:mint", Money.of(4000))
    self:morning()
    lu.assertEquals(self.world.services.shops.till_of(none), Money.zero)
    lu.assertEquals(self.world.services.shops.till_of(big), Money.of(5000))
end

function TestShops:test_a_shop_is_not_stocked_with_what_it_does_not_sell()
    local corner = self:corner({ prices = { brick = { sell = 100 } }, restock = { brick = 2 } })
    local inventory = self.world.services.inventory
    lu.assertEquals(inventory:count(Shops.counter(corner.id), "brick"), 0)
    inventory:spawn("gold", Shops.counter(corner.id), "brick", 2)
    self:morning()
    lu.assertEquals(inventory:count(Shops.counter(corner.id), "brick"), 0)
end

function TestShops:test_a_delivery_that_will_not_fit_is_said_once_and_the_others_still_arrive()
    -- Twenty-four bottles need two slots and this stockroom has one. That is a
    -- mistake the city cannot put right, so it is reported, not swallowed.
    self:corner({ prices = { water = { buy = 250, sell = 100 } }, restock = { water = 24 }, slots = 1 })
    local after_it = self:corner({ prices = { water = { buy = 250, sell = 100 } }, restock = { water = 12 } },
        "Corner Three")
    local inventory = self.world.services.inventory
    local before = #self.world:errors()
    self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 10 }, self.john, BOB)
    self:ask("shop.buy", { shop = after_it.id, item = "water", count = 5 })

    self:morning()
    local errors = self.world:errors()
    lu.assertEquals(#errors, before + 1)
    lu.assertStrContains(errors[#errors].message, "Corner Two")
    lu.assertStrContains(errors[#errors].message, "24 water")
    lu.assertEquals(inventory:count(self:counter(), "water"), 40)
    lu.assertEquals(inventory:count(Shops.counter(after_it.id), "water"), 12)

    -- The same mistake every morning for a week is said once, and never costs
    -- another shop its delivery.
    for _ = 1, 5 do self:morning() end
    self:ask("shop.buy", { shop = self.shop.id, item = "water", count = 10 }, self.john, BOB)
    self:morning()
    lu.assertEquals(#self.world:errors(), before + 1)
    lu.assertEquals(inventory:count(self:counter(), "water"), 40)
end

function TestShops:test_a_delivery_that_will_not_fit_again_is_said_again()
    local corner = self:corner({ prices = { water = { buy = 250, sell = 100 } }, restock = { water = 24 }, slots = 1 })
    local before = #self.world:errors()
    self:morning()
    lu.assertEquals(#self.world:errors(), before + 1)
    corner:set("restock", { water = 12 })
    self:morning()
    lu.assertEquals(#self.world:errors(), before + 1)
    corner:set("restock", { water = 24 })
    self:morning()
    lu.assertEquals(#self.world:errors(), before + 2)
end

function TestShops:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Shops.system()) end)
end

--- The shipped clock, a city minute to a real second, ticked the way
--- adapter/server.lua ticks it: once a real second. Every other case here runs
--- a city millisecond to a real one, where city time and real time cannot be
--- told apart.
TestShopsAtTheShippedRate = {}

function TestShopsAtTheShippedRate:setUp()
    self.world = build(World.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR }))
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    local place = self.world.services.property.build("Rob's Liquor", { kind = "shop" })
    self.shop = self.world.services.shops.open("Rob's Liquor", place.id,
        { prices = { water = { buy = 250, sell = 100 } }, restock = { water = 40 }, float = 50000 })
    self.world.services.proximity = function() return true end
    self.world.services.witnesses = function() return {} end
end

function TestShopsAtTheShippedRate:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestShopsAtTheShippedRate:rob()
    return self.world:dispatch("shop.rob", { shop = self.shop.id }, { actor = self.john, account = BOB })
end

function TestShopsAtTheShippedRate:seconds(n)
    for _ = 1, n do self.world:tick(1000) end
end

function TestShopsAtTheShippedRate:test_a_robbery_takes_the_45_seconds_it_says_it_takes()
    -- The wait was city time, and city time runs sixty times as fast as real
    -- time here: the forty-five seconds the answer promised were one tick, and
    -- the till was taken a second after the first press.
    lu.assertEquals(self:rob().details.seconds, 45)
    self:seconds(44)
    local not_yet = self:rob()
    lu.assertEquals(not_yet.code, "working")
    lu.assertEquals(not_yet.details.seconds, 2)
    self:seconds(1)
    lu.assertTrue(self:rob():succeeded())
end

function TestShopsAtTheShippedRate:test_a_first_press_runs_out_a_real_minute_after_the_wait()
    lu.assertEquals(self:rob().code, "working")
    self:seconds(45 + 61)
    local again = self:rob()
    lu.assertEquals(again.code, "working")
    lu.assertEquals(again.details.seconds, 45)
    lu.assertEquals(self.world.services.shops.till_of(self.shop), Money.of(500))
end

function TestShopsAtTheShippedRate:test_a_robbed_shop_is_shut_for_two_hours_of_the_city_day()
    -- How long a shop stays shut is a stretch of the city's day, like the
    -- morning delivery, and not a wait anybody stands through: two city hours
    -- are two real minutes here.
    self:rob()
    self:seconds(45)
    lu.assertTrue(self:rob():succeeded())
    self:seconds(119)
    lu.assertEquals(self.world.services.shops.shops:load(self.shop.id).state, "robbed")
    self:seconds(2)
    lu.assertEquals(self.world.services.shops.shops:load(self.shop.id).state, "open")
end

TestShopsRestart = {}

function TestShopsRestart:setUp()
    for _, name in ipairs({ "world", "chr", "prp", "shp" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestShopsRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestShopsRestart:test_the_stock_and_the_till_are_still_there()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(jane), Money.of(1000))
    local place = first.services.property.build("Rob's Liquor", { kind = "shop" })
    local shop = first.services.shops.open("Rob's Liquor", place.id, {
        prices = { water = { buy = 250, sell = 100 } }, restock = { water = 40 }, float = 50000 })
    first.services.proximity = function() return true end
    first:dispatch("shop.buy", { shop = shop.id, item = "water", count = 4 },
        { actor = jane, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local counter = Shops.counter(shop.id)
    lu.assertEquals(self.world.services.inventory:count(counter, "water"), 36)
    lu.assertEquals(self.world.services.inventory:count(jane, "water"), 4)
    lu.assertEquals(self.world.services.shops.till_of(
        self.world.services.shops.shops:load(shop.id)), Money.of(510))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    -- and it still trades
    lu.assertTrue(self.world:dispatch("shop.buy", { shop = shop.id, item = "water", count = 1 },
        { actor = jane, account = ALICE }):succeeded())
    lu.assertTrue(self.world:verify())
    lu.assertTrue(self.world.services.inventory:verify())
end

--- Rob a shop in a city on disk, let an hour of its shut time go by, and stop
--- the server. Returns the shop's id.
local function robbed_and_stopped()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local john = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    local place = first.services.property.build("Rob's Liquor", { kind = "shop" })
    local shop = first.services.shops.open("Rob's Liquor", place.id, {
        prices = { water = { buy = 250, sell = 100 } }, restock = { water = 40 }, float = 50000 })
    first.services.proximity = function() return true end
    first.services.witnesses = function() return {} end
    local meta = { actor = john, account = BOB }
    first:dispatch("shop.rob", { shop = shop.id }, meta)
    first.clock:skip(45 * Clock.MS_PER_SECOND)
    lu.assertTrue(first:dispatch("shop.rob", { shop = shop.id }, meta):succeeded())
    first:tick(Clock.MS_PER_HOUR)
    lu.assertTrue(first:close())
    return shop.id
end

function TestShopsRestart:reopen(store)
    self.world = build(World.new({ store = store or FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))
    return self.world.services.shops.shops
end

function TestShopsRestart:can_buy_at(shop_id)
    local jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.world.ledger:transfer("stake:" .. jane, "external:mint", Characters.wallet(jane), Money.of(10))
    local bought = self.world:dispatch("shop.buy", { shop = shop_id, item = "water", count = 1 },
        { actor = jane, account = ALICE })
    lu.assertTrue(self.world.ledger:total():is_zero())
    lu.assertTrue(self.world:verify())
    return bought:succeeded(), bought.code
end

function TestShopsRestart:test_a_shop_robbed_before_a_restart_still_opens_again()
    -- Reopening was a timer and nothing else, and a timer does not survive a
    -- restart. A shop saved while it was shut stayed shut for good: nobody
    -- could buy, sell or rob there again, and in the shipped city it is the
    -- only shop.
    local shop_id = robbed_and_stopped()
    local shops = self:reopen()

    -- A restart is not a way to open a shop that was just robbed...
    lu.assertEquals(shops:load(shop_id).state, "robbed")
    lu.assertEquals(select(2, self:can_buy_at(shop_id)), "shut")
    -- ...and it opens two hours after the robbery, not two after the restart.
    self.world:tick(Clock.MS_PER_HOUR + 2 * Clock.MS_PER_MINUTE)
    lu.assertEquals(shops:load(shop_id).state, "open")
    -- An open shop says nothing about when it opens.
    lu.assertNil(shops:load(shop_id):get("reopens"))
    lu.assertTrue(self:can_buy_at(shop_id))
end

function TestShopsRestart:test_a_shop_an_older_build_saved_while_robbed_opens_again()
    -- Saves written before a shop carried the time it reopens have a robbed
    -- shop and no time. When that robbery happened is not written down, so its
    -- shut time is counted from when this build first sees it.
    local shop_id = robbed_and_stopped()
    local store = FileStore.new({ root = ROOT })
    local record = store:get("shp", shop_id)
    record.data.reopens = nil
    store:put("shp", shop_id, record)
    lu.assertTrue(store:flush())
    local shops = self:reopen(store)

    self.world:tick(Clock.MS_PER_MINUTE)
    lu.assertEquals(shops:load(shop_id).state, "robbed")
    self.world:tick(Clock.MS_PER_HOUR)
    lu.assertEquals(shops:load(shop_id).state, "robbed")
    self.world:tick(Clock.MS_PER_HOUR + 2 * Clock.MS_PER_MINUTE)
    lu.assertEquals(shops:load(shop_id).state, "open")
    lu.assertTrue(self:can_buy_at(shop_id))
end

function TestShopsRestart:test_a_shop_saved_before_its_float_was_kept_is_floated_as_it_was()
    -- A shop saved before it carried its own float has none on its record, and
    -- was floated to the system's five hundred every morning. It still is.
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local place = first.services.property.build("Rob's Liquor", { kind = "shop" })
    local shop = first.services.shops.open("Rob's Liquor", place.id,
        { prices = { water = { buy = 250, sell = 100 } }, float = 100000 })
    lu.assertTrue(first:close())
    local store = FileStore.new({ root = ROOT })
    local record = store:get("shp", shop.id)
    record.data.float = nil
    store:put("shp", shop.id, record)
    lu.assertTrue(store:flush())

    local shops = self:reopen(store)
    self.world.ledger:transfer("spent", Shops.counter(shop.id), "external:mint", Money.of(1000))
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.shops.till_of(shops:load(shop.id)), Money.of(500))
    lu.assertTrue(self.world.ledger:total():is_zero())
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
