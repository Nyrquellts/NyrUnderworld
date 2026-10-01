--- Taking a car that is not yours is not a refusal, it is a crime, and the
--- city decides who saw it rather than the person taking it.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Vehicles = require("systems.vehicles")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

local function catalogue()
    local items = Items.catalogue()
    items:define("lockpick", { label = "Lockpick", weight = 150, stack = 4,
                               category = "tool", illegal = true })
    items:define("scrap", { label = "Scrap Metal", weight = 2000, stack = 20, category = "material" })
    return items
end

local function build(world)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Vehicles.system())
    return world
end

TestVehicles = {}

function TestVehicles:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world.ledger:transfer("stake-a", "external:mint", Characters.wallet(self.jane), Money.of(1000))
    self.world.ledger:transfer("stake-b", "external:mint", Characters.wallet(self.john), Money.of(1000))
    self.car = self.world.services.vehicles.register(self.jane,
        { model = "sultan", plate = "NYR 001", fee = 25000 })

    self.at = {}
    self.seen = {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.witnesses = function() return self.seen end
end

function TestVehicles:tearDown()
    self.world:deactivate()
end

function TestVehicles:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.jane, account = account or ALICE })
end

function TestVehicles:test_a_registered_car_has_an_owner_and_a_boot()
    lu.assertEquals(self.world.services.vehicles.holder(self.car.id), self.jane)
    lu.assertEquals(self.car.state, "stored")
    lu.assertTrue(self.world.services.inventory:has_container(Vehicles.boot(self.car.id)))
    lu.assertTrue(self.world:verify())
end

function TestVehicles:test_the_owner_at_it_can_take_it_out()
    self.at[self.jane] = self.car.id
    local outcome = self:ask("vehicle.take", { vehicle = self.car.id })
    lu.assertTrue(outcome:succeeded())
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertEquals(car.state, "out")
    lu.assertEquals(car:get("driver"), self.jane)
    lu.assertFalse(car:get("stolen"))
    lu.assertTrue(self.world.services.access:may(self.jane, Vehicles.boot(self.car.id)))
end

function TestVehicles:test_somebody_without_keys_cannot_just_take_it()
    self.at[self.john] = self.car.id
    local outcome = self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_key")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "stored")
end

function TestVehicles:test_a_lock_that_cannot_tell_where_you_are_stays_shut()
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("vehicle.take", { vehicle = self.car.id }).code, "no_proximity")
    lu.assertEquals(self:ask("vehicle.boot", { vehicle = self.car.id }).code, "no_proximity")
end

function TestVehicles:test_being_at_it_is_not_something_you_can_claim()
    lu.assertEquals(self:ask("vehicle.take", { vehicle = self.car.id }).code, "too_far")
    for _, field in ipairs(self.world.commands:describe("vehicle.take").args) do
        lu.assertEquals(field.name, "vehicle")
    end
end

function TestVehicles:test_one_car_cannot_be_taken_out_twice()
    self.at[self.jane] = self.car.id
    self.at[self.john] = self.car.id
    self:ask("vehicle.take", { vehicle = self.car.id })
    self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john })
    local second = self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB)
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "already_out")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id):get("driver"), self.jane)
end

function TestVehicles:test_a_key_can_be_given_and_taken_back()
    self.at[self.john] = self.car.id
    lu.assertEquals(self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB).code, "no_key")
    lu.assertTrue(self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john }):succeeded())
    lu.assertTrue(self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB):succeeded())
    lu.assertTrue(self:ask("vehicle.store", { vehicle = self.car.id }, self.john, BOB):succeeded())
    lu.assertTrue(self:ask("vehicle.key",
        { vehicle = self.car.id, holder = self.john, give = false }):succeeded())
    lu.assertEquals(self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB).code, "no_key")
end

function TestVehicles:test_only_the_owner_hands_out_keys()
    lu.assertEquals(self:ask("vehicle.key",
        { vehicle = self.car.id, holder = self.john }, self.john, BOB).code, "not_yours")
end

function TestVehicles:test_a_car_cannot_be_put_away_from_under_its_driver()
    self.at[self.jane] = self.car.id
    self.at[self.john] = self.car.id
    self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john })
    self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB)
    -- the owner has a key, but John has it out
    local outcome = self:ask("vehicle.store", { vehicle = self.car.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_yours")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "out")
end

function TestVehicles:test_the_boot_holds_things_and_survives_being_put_away()
    self.at[self.jane] = self.car.id
    self:ask("vehicle.take", { vehicle = self.car.id })
    self.world.services.inventory:spawn("seed", self.jane, "scrap", 5)
    lu.assertTrue(self:ask("inventory.move", { from = self.jane, to = Vehicles.boot(self.car.id),
        item = "scrap", count = 5 }):succeeded())
    self:ask("vehicle.store", { vehicle = self.car.id })
    lu.assertEquals(self.world.services.inventory:count(Vehicles.boot(self.car.id), "scrap"), 5)
    lu.assertTrue(self.world.services.inventory:verify())
end

-- ------------------------------------------------------------------ theft

function TestVehicles:hotwire(actor, account)
    -- two calls: the first starts it, the second finishes it once the clock
    -- says enough city time has gone by
    local first = self:ask("vehicle.hotwire", { vehicle = self.car.id }, actor, account)
    self.world.clock:skip(30 * Clock.MS_PER_SECOND)
    return first, self:ask("vehicle.hotwire", { vehicle = self.car.id }, actor, account)
end

function TestVehicles:test_taking_a_car_without_keys_takes_tools_and_time()
    self.at[self.john] = self.car.id
    local no_tools = self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    lu.assertEquals(no_tools.code, "no_tools")

    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local started, finished = self:hotwire(self.john, BOB)
    lu.assertEquals(started.code, "working")
    lu.assertEquals(started.details.seconds, 30)
    lu.assertTrue(finished:succeeded())

    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertEquals(car.state, "out")
    lu.assertEquals(car:get("driver"), self.john)
    lu.assertTrue(car:get("stolen"))
    -- the tool is gone, and it left the world rather than moving
    lu.assertEquals(self.world.services.inventory:count(self.john, "lockpick"), 0)
    lu.assertEquals(self.world.services.inventory:total("lockpick"), 0)
    lu.assertTrue(self.world.services.inventory:verify())
    -- the owner still owns it
    lu.assertEquals(self.world.services.vehicles.holder(self.car.id), self.jane)
end

function TestVehicles:test_a_theft_nobody_saw_leaves_no_heat_and_a_full_record()
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local _, finished = self:hotwire(self.john, BOB)
    lu.assertTrue(finished:succeeded())
    lu.assertFalse(finished.value.witnessed)
    lu.assertEquals(self.world.services.heat(self.john), 0)

    local record = self.world.services.recall(self.john, { kind = "crime.vehicle_theft" })
    lu.assertEquals(#record, 1)
    lu.assertEquals(record[1].meta.plate, "NYR 001")
    -- and the owner can find it from their side
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "crime.vehicle_theft" }), 1)
end

function TestVehicles:test_a_theft_somebody_saw_makes_you_wanted()
    self.at[self.john] = self.car.id
    self.seen = { self.jane }
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local _, finished = self:hotwire(self.john, BOB)
    lu.assertTrue(finished.value.witnessed)
    lu.assertEquals(self.world.services.heat(self.john), 35)
end

function TestVehicles:test_the_thief_does_not_get_to_say_who_saw_them()
    -- There is no witness field on the command, so there is nothing to lie
    -- with. The server asks its own service.
    for _, field in ipairs(self.world.commands:describe("vehicle.hotwire").args) do
        lu.assertNotEquals(field.name, "witnesses")
        lu.assertNotEquals(field.name, "seen")
    end
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    self.seen = { self.jane }
    local outcome = self.world:dispatch("vehicle.hotwire",
        { vehicle = self.car.id, witnesses = {} }, { actor = self.john, account = BOB })
    lu.assertEquals(outcome.code, "bad_args")
end

function TestVehicles:test_a_stolen_car_cannot_be_put_away_as_if_it_were_yours()
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    self:hotwire(self.john, BOB)
    local outcome = self:ask("vehicle.store", { vehicle = self.car.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "stolen")
end

function TestVehicles:test_a_thief_can_open_the_boot_of_what_they_took()
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    self.world.services.inventory:spawn("loot", Vehicles.boot(self.car.id), "scrap", 3)
    self:hotwire(self.john, BOB)
    lu.assertTrue(self:ask("vehicle.boot", { vehicle = self.car.id }, self.john, BOB):succeeded())
    lu.assertTrue(self:ask("inventory.move", { from = Vehicles.boot(self.car.id), to = self.john,
        item = "scrap", count = 3 }, self.john, BOB):succeeded())
    lu.assertEquals(self.world.services.inventory:count(self.john, "scrap"), 3)
end

function TestVehicles:test_you_cannot_take_one_somebody_is_sitting_in()
    self.at[self.jane] = self.car.id
    self.at[self.john] = self.car.id
    self:ask("vehicle.take", { vehicle = self.car.id })
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local outcome = self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    lu.assertEquals(outcome.code, "occupied")
end

function TestVehicles:test_a_thief_with_no_pockets_is_refused_not_failed()
    -- A missing container throws, so somebody whose pockets were lost got a
    -- server error for trying a car door.
    self.at[self.john] = self.car.id
    self.world.services.inventory._containers[self.john] = nil      -- past the verbs, on purpose
    local outcome = self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused(), tostring(outcome))
    lu.assertEquals(outcome.code, "no_tools")
    lu.assertEquals(#self.world:errors(), 0)
end

function TestVehicles:test_having_the_keys_is_not_a_reason_to_break_in()
    self.at[self.jane] = self.car.id
    self.world.services.inventory:spawn("kit", self.jane, "lockpick", 1)
    lu.assertEquals(self:ask("vehicle.hotwire", { vehicle = self.car.id }).code, "have_keys")
    lu.assertEquals(self.world.services.inventory:count(self.jane, "lockpick"), 1)
end

function TestVehicles:test_starting_on_one_car_does_not_finish_another()
    local second = self.world.services.vehicles.register(self.jane,
        { model = "banshee", plate = "NYR 002" })
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 2)
    self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    self.world.clock:skip(30 * Clock.MS_PER_SECOND)
    self.at[self.john] = second.id
    local outcome = self:ask("vehicle.hotwire", { vehicle = second.id }, self.john, BOB)
    lu.assertEquals(outcome.code, "working")     -- the clock starts again on this one
    lu.assertEquals(self.world.services.vehicles.cars:load(second.id).state, "stored")
end

-- ---------------------------------------------------------------- impound

function TestVehicles:test_impounding_takes_it_off_the_street()
    self.at[self.jane] = self.car.id
    self:ask("vehicle.take", { vehicle = self.car.id })
    lu.assertTrue(self.world.services.vehicles.impound("imp-1", self.car.id, "abandoned"))
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertEquals(car.state, "impounded")
    lu.assertNil(car:get("driver"))
    lu.assertEquals(self:ask("vehicle.take", { vehicle = self.car.id }).code, "impounded")
    lu.assertEquals(self:ask("vehicle.boot", { vehicle = self.car.id }).code, "impounded")
    -- and it is on the record
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "vehicle.impounded" }), 1)
end

function TestVehicles:test_getting_it_back_costs_the_fee()
    self.world.services.vehicles.impound("imp-1", self.car.id, "parked badly")
    local outcome = self:ask("vehicle.retrieve", { vehicle = self.car.id })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 25000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(750))
    lu.assertEquals(self.world.ledger:balance("external:impound"), Money.of(250))
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "stored")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestVehicles:test_a_fee_you_cannot_pay_leaves_it_in_the_lot()
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:mint", Money.of(1000))
    self.world.services.vehicles.impound("imp-1", self.car.id, "parked badly")
    local outcome = self:ask("vehicle.retrieve", { vehicle = self.car.id })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "cannot_afford")
    lu.assertEquals(self.world.services.vehicles.cars:load(self.car.id).state, "impounded")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestVehicles:test_only_the_owner_collects_it()
    self.world.services.vehicles.impound("imp-1", self.car.id, "parked badly")
    lu.assertEquals(self:ask("vehicle.retrieve", { vehicle = self.car.id }, self.john, BOB).code,
        "not_yours")
    -- and a car that is not impounded is not collectable
    self:ask("vehicle.retrieve", { vehicle = self.car.id })
    lu.assertEquals(self:ask("vehicle.retrieve", { vehicle = self.car.id }).code, "not_impounded")
end

function TestVehicles:test_a_stolen_car_that_is_impounded_comes_back_clean()
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    self:hotwire(self.john, BOB)
    self.world.services.vehicles.impound("imp-1", self.car.id, "recovered")
    lu.assertTrue(self:ask("vehicle.retrieve", { vehicle = self.car.id }):succeeded())
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertFalse(car:get("stolen"))
    lu.assertNil(car:get("driver"))
    -- and the theft is still on the thief record
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.vehicle_theft" }), 1)
end

function TestVehicles:test_logging_out_puts_the_car_away()
    self.at[self.jane] = self.car.id
    self.world:dispatch("character.select", { character = self.jane }, { account = ALICE })
    self:ask("vehicle.take", { vehicle = self.car.id })
    self.world:dispatch("character.release", {}, { account = ALICE })
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertEquals(car.state, "stored")
    lu.assertNil(car:get("driver"))
end

function TestVehicles:test_nobody_can_do_any_of_it_without_being_somebody()
    for _, name in ipairs({ "vehicle.take", "vehicle.store", "vehicle.boot",
                            "vehicle.hotwire", "vehicle.retrieve" }) do
        lu.assertEquals(self.world:dispatch(name, { vehicle = self.car.id }, { account = ALICE }).code,
            "not_playing")
    end
end

function TestVehicles:test_a_car_somebody_has_out_does_not_say_who_they_are()
    -- The refusal named the driver by their character id, an identifier a
    -- client is never meant to be handed.
    self.at[self.jane] = self.car.id
    self.at[self.john] = self.car.id
    self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john })
    self:ask("vehicle.take", { vehicle = self.car.id })
    local second = self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB)
    lu.assertEquals(second.code, "already_out")
    lu.assertNil(second.message:find(self.jane, 1, true), "the refusal named the driver's character id")
end

-- ------------------------------------------------------------------ parts

--- What a chop shop leaves behind: nobody owns it, nobody is in it, and it is
--- parts. systems/fencing does this; here it is done the same way by hand.
function TestVehicles:wreck()
    local car = self.world.services.vehicles.cars:load(self.car.id)
    lu.assertTrue(self.world.ownership:release("scrapped", car.id, self.jane))
    car:set("driver", nil)
    lu.assertTrue(car:transition("wrecked", { reason = "chopped" }))
    lu.assertTrue(self.world.services.vehicles.cars:save(car))
    return car
end

function TestVehicles:test_a_car_that_is_parts_cannot_be_driven_off_with_an_old_key()
    -- Nothing asked whether a car was wrecked, and the move to `out` was
    -- refused by the lifecycle and not read. So a key from before the chop
    -- "took out" a pile of parts: a driver, a boot opened, and a state that
    -- still said wrecked.
    self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john })
    local car = self:wreck()
    self.at[self.john] = self.car.id
    local outcome = self:ask("vehicle.take", { vehicle = self.car.id }, self.john, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "wrecked")
    lu.assertEquals(car.state, "wrecked")
    lu.assertNil(car:get("driver"))
    lu.assertFalse(self.world.services.access:may(self.john, Vehicles.boot(self.car.id)))
    lu.assertTrue(self.world:verify())
end

function TestVehicles:test_a_car_that_is_parts_cannot_be_hotwired()
    -- Hotwiring a wreck spent a lockpick, opened the boot and wrote a second
    -- theft of a car that no longer existed on the thief's record.
    local car = self:wreck()
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local started, finished = self:hotwire(self.john, BOB)
    lu.assertEquals(started.code, "wrecked")
    lu.assertEquals(finished.code, "wrecked")
    lu.assertEquals(self.world.services.inventory:count(self.john, "lockpick"), 1)
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.vehicle_theft" }), 0)
    lu.assertEquals(car.state, "wrecked")
    lu.assertFalse(car:get("stolen"))
    lu.assertFalse(self.world.services.access:may(self.john, Vehicles.boot(self.car.id)))
end

function TestVehicles:test_the_boot_of_a_car_that_is_parts_stays_shut()
    self:ask("vehicle.key", { vehicle = self.car.id, holder = self.john })
    self:wreck()
    self.at[self.john] = self.car.id
    local outcome = self:ask("vehicle.boot", { vehicle = self.car.id }, self.john, BOB)
    lu.assertEquals(outcome.code, "wrecked")
    lu.assertFalse(self.world.services.access:may(self.john, Vehicles.boot(self.car.id)))
end

function TestVehicles:test_a_car_the_lifecycle_will_not_move_is_not_taken_out()
    -- What a transition answers is read. A refused move changes nothing, so
    -- it is made before anything else is written to the car.
    self.at[self.jane] = self.car.id
    local car = self.world.services.vehicles.cars:load(self.car.id)
    car.transition = function() return false, "not today" end
    local outcome = self:ask("vehicle.take", { vehicle = self.car.id })
    car.transition = nil
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(car.state, "stored")
    lu.assertNil(car:get("driver"))
    lu.assertFalse(self.world.services.access:may(self.jane, Vehicles.boot(self.car.id)))
end

function TestVehicles:test_a_car_the_lifecycle_will_not_move_costs_no_lockpick()
    -- And asked before the lockpick is spent, which cannot be given back.
    self.at[self.john] = self.car.id
    self.world.services.inventory:spawn("kit", self.john, "lockpick", 1)
    local car = self.world.services.vehicles.cars:load(self.car.id)
    self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    self.world.clock:skip(30 * Clock.MS_PER_SECOND)
    car.can_transition = function() return false end
    local outcome = self:ask("vehicle.hotwire", { vehicle = self.car.id }, self.john, BOB)
    car.can_transition = nil
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(self.world.services.inventory:count(self.john, "lockpick"), 1)
    lu.assertEquals(car.state, "stored")
    lu.assertNil(car:get("driver"))
    lu.assertFalse(car:get("stolen"))
end

-- ------------------------------------------------------------ a chop shop

--- A car taken apart by the real chop shop rather than a hand-made wreck:
--- what happens to the boot hangs on what systems/fencing announces.
TestVehiclesChopped = {}

function TestVehiclesChopped:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.world:install(require("systems.property").system())
    self.world:install(require("systems.fencing").system())
    self.owner = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.thief = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.yard = self.world.services.property.build("Scrapyard, Cypress Flats", { kind = "shop" })
    self.fence = self.world.services.fencing.open("Nobody's", self.yard.id, { chops = true })
    self.car = self.world.services.vehicles.register(self.owner, { model = "sultan", plate = "NYR 001" })
    self.at = {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.witnesses = function() return {} end
end

function TestVehiclesChopped:tearDown()
    self.world:deactivate()
end

function TestVehiclesChopped:test_what_was_left_in_the_boot_goes_with_the_car()
    -- A chopped car is parts, and its boot stayed full: nothing could ever
    -- take those things out again, and anybody the boot was still open for
    -- could go on reaching into a car that no longer existed.
    local inventory = self.world.services.inventory
    local boot = Vehicles.boot(self.car.id)
    inventory:spawn("left", boot, "scrap", 3)
    inventory:spawn("kit", self.thief, "lockpick", 1)
    inventory:spawn("own", self.thief, "scrap", 1)
    local function ask(name, args)
        return self.world:dispatch(name, args, { actor = self.thief, account = BOB })
    end

    self.at[self.thief] = self.car.id
    ask("vehicle.hotwire", { vehicle = self.car.id })
    self.world.clock:skip(30 * Clock.MS_PER_SECOND)
    lu.assertTrue(ask("vehicle.hotwire", { vehicle = self.car.id }):succeeded())
    self.at[self.thief] = self.yard.id
    ask("fence.chop", { fence = self.fence.id, vehicle = self.car.id })
    self.world.clock:skip(60 * Clock.MS_PER_SECOND)
    -- The boot open in the yard as the car is taken apart.
    self.world.services.reach(self.thief, boot)
    lu.assertTrue(ask("fence.chop", { fence = self.fence.id, vehicle = self.car.id }):succeeded())

    lu.assertEquals(inventory:contents(boot), {})
    lu.assertEquals(inventory:issued("scrap"), 1, "what was in the boot did not leave the world")
    lu.assertEquals(inventory:count(self.thief, "scrap"), 1)
    lu.assertEquals(ask("inventory.move", { from = self.thief, to = boot, item = "scrap", count = 1 }).code,
        "out_of_reach")
    lu.assertTrue(inventory:verify())
    lu.assertTrue(self.world:verify())
    lu.assertEquals(self.world.ledger:total(), Money.zero)
end

-- -------------------------------------------------------------- real time

--- The pace config.lua ships: sixty city milliseconds to a real one, and a
--- server tick every real second. Everything above runs at a rate of one,
--- where a real millisecond and a city millisecond are the same number.
TestVehiclesPace = {}

function TestVehiclesPace:setUp()
    self.world = build(World.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.car = self.world.services.vehicles.register(self.jane, { model = "sultan", plate = "NYR 001" })
    self.world.services.proximity = function() return true end
    self.world.services.witnesses = function() return {} end
end

function TestVehiclesPace:tearDown()
    self.world:deactivate()
end

function TestVehiclesPace:test_hotwiring_takes_real_time_at_the_pace_the_city_ships_at()
    -- Thirty city seconds is half a real second at sixty to one, so a second
    -- press one server tick after the first finished the job, and "Give it a
    -- minute" was a double click.
    local inventory = self.world.services.inventory
    inventory:spawn("kit", self.john, "lockpick", 1)
    local function press()
        return self.world:dispatch("vehicle.hotwire", { vehicle = self.car.id },
            { actor = self.john, account = BOB })
    end
    lu.assertEquals(press().code, "working")
    self.world:tick(1000)
    local early = press()
    lu.assertEquals(early.code, "working", "one tick after starting on it, the car was already taken")
    lu.assertEquals(early.details.seconds, 30, "what is left is said in real seconds")
    lu.assertEquals(inventory:count(self.john, "lockpick"), 1)

    for _ = 1, 29 do self.world:tick(1000) end
    lu.assertTrue(press():succeeded(), "thirty real seconds at the car was not enough")
    lu.assertEquals(inventory:count(self.john, "lockpick"), 0)
    lu.assertTrue(inventory:verify())
end

TestVehiclesRestart = {}

function TestVehiclesRestart:setUp()
    for _, name in ipairs({ "world", "chr", "veh" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestVehiclesRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestVehiclesRestart:test_nobody_is_left_driving_across_a_restart()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1 }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local car = first.services.vehicles.register(jane, { model = "sultan", plate = "NYR 001" })
    first.services.proximity = function() return true end
    first:dispatch("vehicle.take", { vehicle = car.id }, { actor = jane, account = ALICE })
    first.services.inventory:spawn("loot", Vehicles.boot(car.id), "scrap", 4)
    lu.assertEquals(first.services.vehicles.cars:load(car.id).state, "out")
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local loaded = self.world.services.vehicles.cars:load(car.id)
    lu.assertEquals(loaded.state, "stored")
    lu.assertNil(loaded:get("driver"))
    lu.assertEquals(self.world.services.vehicles.holder(car.id), jane)
    -- and what was in the boot is still in the boot
    lu.assertEquals(self.world.services.inventory:count(Vehicles.boot(car.id), "scrap"), 4)
    lu.assertTrue(self.world.services.inventory:verify())
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
