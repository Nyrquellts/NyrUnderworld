--- Theft without a buyer is a hobby. A fence pays badly, asks nothing, and is
--- itself a crime to use.
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
local Vehicles = require("systems.vehicles")
local Fencing = require("systems.fencing")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"

local function catalogue()
    local items = Items.catalogue()
    items:define("watch", { label = "Gold Watch", weight = 200, stack = 5,
                            category = "valuable", illegal = true })
    items:define("scrap", { label = "Scrap Metal", weight = 2000, stack = 20, category = "material" })
    return items
end

local function build(world, fencing_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Property.system())
    world:install(Police.system())
    world:install(Vehicles.system())
    world:install(Fencing.system(fencing_opts))
    return world
end

TestFencing = {}

function TestFencing:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.thief = self:person("John", "Roe", BOB)
    self.owner = self:person("Jane", "Doe", ALICE)
    self.officer = self:person("Kate", "Ward", CARLA)

    self.place = self.world.services.property.build("Scrapyard, Cypress Flats",
        { kind = "shop", x = 1.0, y = 2.0, z = 3.0, radius = 8.0 })
    self.fence = self.world.services.fencing.open("Nobody's", self.place.id, {
        pays = { watch = 4000, scrap = 300 },
        chops = true,
    })
    self.car = self.world.services.vehicles.register(self.owner,
        { model = "sultan", plate = "NYR 001", value = 200000 })

    self.at, self.seen = {}, {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.witnesses = function() return self.seen end
    self.at[self.thief] = self.place.id
end

function TestFencing:person(first, last, account)
    local id = self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
    self.world:dispatch("character.select", { character = id }, { account = account })
    return id
end

function TestFencing:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    local stock, stock_problems = self.world.services.inventory:verify()
    lu.assertTrue(stock, table.concat(stock_problems, "; "))
    self.world:deactivate()
end

function TestFencing:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.thief, account = account or BOB })
end

function TestFencing:test_a_fence_says_what_it_takes_and_nothing_about_selling()
    local outcome = self:ask("fence.list", { fence = self.fence.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.name, "Nobody's")
    lu.assertTrue(outcome.value.chops)
    lu.assertEquals(#outcome.value.lines, 2)
    lu.assertEquals(outcome.value.lines[1].item, "scrap")
    lu.assertEquals(outcome.value.lines[2].pays, 4000)
end

function TestFencing:test_handing_something_over_pays_what_the_fence_pays()
    self.world.services.inventory:spawn("loot", self.thief, "watch", 3)
    local outcome = self:ask("fence.sell", { fence = self.fence.id, item = "watch", count = 3 })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 12000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.of(120))
    lu.assertEquals(self.world.services.inventory:count(self.thief, "watch"), 0)
    lu.assertEquals(self.world.services.inventory:count(
        Fencing.counter(self.fence.id), "watch"), 3)
    -- the goods still exist, they just changed hands
    lu.assertEquals(self.world.services.inventory:total("watch"), 3)
end

function TestFencing:test_the_seller_never_says_what_it_is_worth()
    local described = self.world.commands:describe("fence.sell")
    for _, field in ipairs(described.args) do
        lu.assertNotEquals(field.name, "price")
        lu.assertNotEquals(field.name, "paid")
        lu.assertNotEquals(field.name, "value")
    end
    self.world.services.inventory:spawn("loot", self.thief, "watch", 1)
    local lying = self:ask("fence.sell",
        { fence = self.fence.id, item = "watch", count = 1, price = 9999999 })
    lu.assertEquals(lying.code, "bad_args")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.zero)
end

function TestFencing:test_a_fence_takes_only_what_it_wants()
    self.world.services.inventory:spawn("loot", self.thief, "watch", 1)
    lu.assertEquals(self:ask("fence.sell",
        { fence = self.fence.id, item = "moonrock", count = 1 }).code, "not_wanted")
    lu.assertEquals(self:ask("fence.sell",
        { fence = self.fence.id, item = "watch", count = 5 }).code, "not_carrying")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.zero)
end

function TestFencing:test_selling_something_illegal_is_itself_a_crime()
    self.world.services.inventory:spawn("loot", self.thief, "watch", 2)
    self:ask("fence.sell", { fence = self.fence.id, item = "watch", count = 2 })
    local record = self.world.services.recall(self.thief, { kind = "crime.handling" })
    lu.assertEquals(#record, 1)
    lu.assertEquals(record[1].meta.item, "watch")
    lu.assertEquals(record[1].place, self.place.id)
    -- nobody saw it, so no heat and a full record
    lu.assertEquals(self.world.services.heat(self.thief), 0)
end

function TestFencing:test_two_sales_in_one_tick_are_both_on_the_record()
    -- A record's id was who sold and when, and city time only moves on a tick,
    -- so the second of two sales in one tick was taken for the first again and
    -- never written down: no record of it, and none of the heat it earned.
    self.seen = { self.officer }
    self.world.services.inventory:spawn("loot", self.thief, "watch", 2)
    lu.assertTrue(self:ask("fence.sell", { fence = self.fence.id, item = "watch", count = 1 }):succeeded())
    lu.assertTrue(self:ask("fence.sell", { fence = self.fence.id, item = "watch", count = 1 }):succeeded())
    lu.assertEquals(#self.world.services.recall(self.thief, { kind = "crime.handling" }), 2)
    lu.assertEquals(self.world.services.heat(self.thief), 40)
end

function TestFencing:test_what_cannot_be_sold_cannot_be_fenced_either()
    -- A shop refuses anything marked not sellable. A fence never asked, so a
    -- passport could be handed over for cash.
    self.world.services.items:define("passport", { label = "Passport", weight = 30, unique = true,
                                                   category = "document", sellable = false })
    local pawn = self.world.services.fencing.open("Pawn", self.place.id, { pays = { passport = 10000 } })
    self.world.services.inventory:spawn("papers", self.thief, "passport", 1)
    local outcome = self:ask("fence.sell", { fence = pawn.id, item = "passport", count = 1 })
    lu.assertEquals(outcome.code, "not_sellable")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.zero)
    lu.assertEquals(self.world.services.inventory:count(self.thief, "passport"), 1)
end

function TestFencing:test_selling_something_ordinary_is_just_selling()
    self.world.services.inventory:spawn("junk", self.thief, "scrap", 4)
    self:ask("fence.sell", { fence = self.fence.id, item = "scrap", count = 4 })
    lu.assertEquals(#self.world.services.recall(self.thief, { kind = "crime.handling" }), 0)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.of(12))
end

function TestFencing:test_being_seen_at_a_fence_is_what_makes_it_heat()
    self.seen = { self.officer }
    self.world.services.inventory:spawn("loot", self.thief, "watch", 1)
    local outcome = self:ask("fence.sell", { fence = self.fence.id, item = "watch", count = 1 })
    lu.assertTrue(outcome.value.witnessed)
    lu.assertEquals(self.world.services.heat(self.thief), 20)
end

-- ------------------------------------------------------------- chop shop

function TestFencing:steal()
    self.at[self.thief] = self.car.id
    self.world.services.inventory:define_container(self.thief)
    local items = self.world.services.items
    if not items:has("lockpick") then
        items:define("lockpick", { label = "Lockpick", weight = 150, stack = 4,
                                   category = "tool", illegal = true })
    end
    self.world.services.inventory:spawn("kit", self.thief, "lockpick", 1)
    self:ask("vehicle.hotwire", { vehicle = self.car.id })
    self.world.clock:skip(30 * Clock.MS_PER_SECOND)
    self:ask("vehicle.hotwire", { vehicle = self.car.id })
    self.at[self.thief] = self.place.id
end

function TestFencing:chop(vehicle)
    local first = self:ask("fence.chop", { fence = self.fence.id, vehicle = vehicle or self.car.id })
    self.world.clock:skip(60 * Clock.MS_PER_SECOND)
    return first, self:ask("fence.chop", { fence = self.fence.id, vehicle = vehicle or self.car.id })
end

function TestFencing:test_a_stolen_car_is_worth_a_fraction_of_what_it_is_worth()
    self:steal()
    local started, finished = self:chop()
    lu.assertEquals(started.code, "working")
    lu.assertEquals(started.details.seconds, 60)
    lu.assertTrue(finished:succeeded())
    lu.assertEquals(finished.value.paid, 60000)        -- thirty per cent of two thousand
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.of(600))
end

function TestFencing:test_a_chopped_car_stops_being_a_car()
    self:steal()
    self:chop()
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertEquals(car.state, "wrecked")
    lu.assertNil(car:get("driver"))
    -- nobody owns parts, and the register keeps the last line saying so
    lu.assertNil(self.world.services.vehicles.holder(self.car.id))
    local chain = self.world.ownership:chain(self.car.id)
    lu.assertEquals(chain[#chain].action, "release")
    lu.assertTrue(self.world.ownership:verify())
end

function TestFencing:test_a_chopped_car_cannot_be_taken_out_or_collected()
    self:steal()
    self:chop()
    self.at[self.owner] = self.car.id
    lu.assertEquals(self.world:dispatch("vehicle.take", { vehicle = self.car.id },
        { actor = self.owner, account = ALICE }).code, "no_key")
    lu.assertEquals(self.world:dispatch("vehicle.retrieve", { vehicle = self.car.id },
        { actor = self.owner, account = ALICE }).code, "not_impounded")
    -- and it says what is actually true rather than the nearest refusal
    local _, again = self:chop()
    lu.assertEquals(again.code, "already_gone")
end

function TestFencing:test_a_chop_cannot_be_started_days_ahead()
    -- Where somebody is gets asked at each press and never between them, and
    -- the first press never ran out: start the job, drive off, and one press
    -- two days later was paid for the car.
    self:steal()
    local fence = { fence = self.fence.id, vehicle = self.car.id }
    lu.assertEquals(self:ask("fence.chop", fence).code, "working")
    self.world.clock:skip(2 * Clock.MS_PER_DAY)
    local again = self:ask("fence.chop", fence)
    lu.assertEquals(again.code, "working")
    lu.assertEquals(again.details.seconds, 60)
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "out")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.thief)), Money.zero)
    self.world.clock:skip(60 * Clock.MS_PER_SECOND)
    lu.assertTrue(self:ask("fence.chop", fence):succeeded())
end

function TestFencing:test_a_first_press_at_a_chop_shop_is_good_for_a_minute_after_the_wait()
    -- This world runs a city millisecond to a real one.
    self:steal()
    local fence = { fence = self.fence.id, vehicle = self.car.id }
    lu.assertEquals(self:ask("fence.chop", fence).code, "working")
    self.world.clock:skip(60 * Clock.MS_PER_SECOND + 59 * Clock.MS_PER_SECOND)
    lu.assertTrue(self:ask("fence.chop", fence):succeeded())
end

function TestFencing:test_a_first_press_at_a_chop_shop_runs_out_a_minute_after_the_wait()
    self:steal()
    local fence = { fence = self.fence.id, vehicle = self.car.id }
    lu.assertEquals(self:ask("fence.chop", fence).code, "working")
    self.world.clock:skip(60 * Clock.MS_PER_SECOND + 61 * Clock.MS_PER_SECOND)
    lu.assertEquals(self:ask("fence.chop", fence).code, "working")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "out")
end

function TestFencing:test_you_have_to_drive_it_in()
    -- A car chopped from across town is a car nobody stole.
    local outcome = self:ask("fence.chop", { fence = self.fence.id, vehicle = self.car.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_yours_to_chop")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "stored")
end

function TestFencing:test_chopping_is_handling_and_says_whose_it_was()
    self:steal()
    self:chop()
    local record = self.world.services.recall(self.thief, { kind = "crime.handling" })
    lu.assertEquals(#record, 1)
    lu.assertEquals(record[1].meta.plate, "NYR 001")
    lu.assertTrue(record[1].meta.stolen)
    -- and the owner can find out what happened to their car
    lu.assertEquals(#self.world.services.recall(self.owner, { kind = "crime.handling" }), 1)
end

function TestFencing:test_a_witnessed_chop_is_arrestable_with_the_theft()
    self.seen = { self.officer }
    self:steal()
    self:chop()
    -- taking it, then handling it
    lu.assertEquals(self.world.services.heat(self.thief), 55)

    self.world.services.police.commission(self.officer)
    self.world:dispatch("police.duty", { on = true }, { actor = self.officer, account = CARLA })
    self.at[self.officer] = self.thief
    local arrest = self.world:dispatch("police.arrest", { suspect = self.thief },
        { actor = self.officer, account = CARLA })
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(#arrest.value.offences, 2)
    lu.assertEquals(arrest.value.minutes, 18)          -- taking a vehicle 12, handling 6
end

function TestFencing:test_a_fence_that_does_not_do_cars_does_not_do_cars()
    local other_place = self.world.services.property.build("Pawn Shop", { kind = "shop" })
    local pawn = self.world.services.fencing.open("Pawn", other_place.id, { pays = { watch = 100 } })
    self:steal()
    self.at[self.thief] = other_place.id
    lu.assertEquals(self:ask("fence.chop", { fence = pawn.id, vehicle = self.car.id }).code,
        "not_a_chop_shop")
end

function TestFencing:test_you_have_to_be_there_at_all()
    self.at[self.thief] = nil
    lu.assertEquals(self:ask("fence.list", { fence = self.fence.id }).code, "too_far")
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("fence.list", { fence = self.fence.id }).code, "no_proximity")
end

function TestFencing:test_nobody_fences_without_being_somebody()
    local cases = {
        { "fence.list", { fence = self.fence.id } },
        { "fence.sell", { fence = self.fence.id, item = "watch", count = 1 } },
        { "fence.chop", { fence = self.fence.id, vehicle = self.car.id } },
    }
    for _, case in ipairs(cases) do
        lu.assertEquals(self.world:dispatch(case[1], case[2], { account = BOB }).code,
            "not_playing", case[1])
    end
end

function TestFencing:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Fencing.system()) end)
    lu.assertError(function() return Fencing.system({ chop_percent = 0 }) end)
    lu.assertError(function() return Fencing.system({ chop_percent = 100 }) end)
end

--- The shipped clock, a city minute to a real second, ticked the way
--- adapter/server.lua ticks it: once a real second.
TestFencingAtTheShippedRate = {}

function TestFencingAtTheShippedRate:setUp()
    self.world = build(World.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR }))
    self.thief = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    local owner = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local place = self.world.services.property.build("Scrapyard", { kind = "shop" })
    self.fence = self.world.services.fencing.open("Nobody's", place.id, { chops = true })
    -- Driven in by somebody who does not own it. How long taking it took is the
    -- vehicles system's business; how long the chop takes is what is timed.
    local car = self.world.services.vehicles.register(owner, { model = "sultan", plate = "NYR 001" })
    car:patch({ driver = self.thief, stolen = true })
    car:transition("out", { reason = "taken" })
    lu.assertTrue(self.world.services.vehicles.cars:save(car))
    self.car = car
    self.world.services.proximity = function() return true end
    self.world.services.witnesses = function() return {} end
end

function TestFencingAtTheShippedRate:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestFencingAtTheShippedRate:chop()
    return self.world:dispatch("fence.chop", { fence = self.fence.id, vehicle = self.car.id },
        { actor = self.thief, account = BOB })
end

function TestFencingAtTheShippedRate:seconds(n)
    for _ = 1, n do self.world:tick(1000) end
end

function TestFencingAtTheShippedRate:test_a_chop_takes_the_minute_it_says_it_takes()
    -- The wait was city time, which runs sixty times as fast as real time
    -- here: the sixty seconds the answer promised were a single tick.
    lu.assertEquals(self:chop().details.seconds, 60)
    self:seconds(59)
    local not_yet = self:chop()
    lu.assertEquals(not_yet.code, "working")
    lu.assertEquals(not_yet.details.seconds, 2)
    self:seconds(1)
    lu.assertTrue(self:chop():succeeded())
end

function TestFencingAtTheShippedRate:test_a_first_press_runs_out_a_real_minute_after_the_wait()
    lu.assertEquals(self:chop().code, "working")
    self:seconds(60 + 61)
    local again = self:chop()
    lu.assertEquals(again.code, "working")
    lu.assertEquals(again.details.seconds, 60)
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "out")
end

TestFencingRestart = {}

function TestFencingRestart:setUp()
    for _, name in ipairs({ "world", "chr", "prp", "veh", "fnc" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestFencingRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestFencingRestart:test_what_a_fence_took_in_is_still_there()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local thief = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first:dispatch("character.select", { character = thief }, { account = BOB })
    local place = first.services.property.build("Scrapyard", { kind = "shop" })
    local fence = first.services.fencing.open("Nobody's", place.id, { pays = { watch = 4000 } })
    first.services.proximity = function() return true end
    first.services.inventory:spawn("loot", thief, "watch", 3)
    first:dispatch("fence.sell", { fence = fence.id, item = "watch", count = 3 },
        { actor = thief, account = BOB })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    lu.assertEquals(self.world.services.inventory:count(
        Fencing.counter(fence.id), "watch"), 3)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(thief)), Money.of(120))
    lu.assertEquals(#self.world.services.recall(thief, { kind = "crime.handling" }), 1)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
    lu.assertTrue(self.world.services.inventory:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
