--- The mirror of the payout rule: an officer names a person and nothing else.
--- The server works out what they are wanted for and what it costs.
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
local Police = require("systems.police")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"
local MINUTE = Clock.MS_PER_MINUTE

local function catalogue()
    local items = Items.catalogue()
    items:define("lockpick", { label = "Lockpick", weight = 150, stack = 4, category = "tool" })
    return items
end

local function build(world, memory_opts, police_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system(memory_opts))
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Vehicles.system())
    world:install(Police.system(police_opts))
    return world
end

TestPolice = {}

function TestPolice:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.officer = self.world:dispatch("character.create",
        { first_name = "Kate", last_name = "Ward" }, { account = ALICE }).value
    self.crook = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.witness = self.world:dispatch("character.create",
        { first_name = "Mary", last_name = "Poe" }, { account = CARLA }).value
    self.world.ledger:transfer("stake", "external:mint", Characters.wallet(self.crook), Money.of(2000))

    self.at = {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.police.commission(self.officer)
    self.world:dispatch("police.duty", { on = true }, { actor = self.officer, account = ALICE })
end

function TestPolice:tearDown()
    self.world:deactivate()
end

function TestPolice:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.officer, account = account or ALICE })
end

function TestPolice:crime(kind, seen)
    return self.world.services.remember(("c:%s:%d"):format(kind, self.world.clock:now()), {
        subject = self.crook, kind = kind, weight = 30,
        witnesses = seen == false and {} or { self.witness },
    })
end

function TestPolice:test_a_commission_is_granted_not_claimed()
    local outcome = self:ask("police.duty", { on = true }, self.crook, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_an_officer")
    lu.assertFalse(self.world.services.police.is_on_duty(self.crook))
    -- and the command has no field to claim one with
    for _, field in ipairs(self.world.commands:describe("police.duty").args) do
        lu.assertEquals(field.name, "on")
    end
end

function TestPolice:test_an_officer_off_duty_does_nothing()
    self:ask("police.duty", { on = false })
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    lu.assertEquals(self:ask("police.arrest", { suspect = self.crook }).code, "not_on_duty")
    lu.assertEquals(self:ask("police.lookup", { suspect = self.crook }).code, "not_on_duty")
end

function TestPolice:test_the_officer_does_not_say_what_the_charge_is()
    -- The mirror of the payout rule. There is no charge field and no fine
    -- field, so there is nothing to invent.
    local described = self.world.commands:describe("police.arrest")
    lu.assertEquals(#described.args, 1)
    lu.assertEquals(described.args[1].name, "suspect")

    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    local lying = self.world:dispatch("police.arrest",
        { suspect = self.crook, fine = 999999, minutes = 0 },
        { actor = self.officer, account = ALICE })
    lu.assertEquals(lying.code, "bad_args")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.crook)), Money.of(2000))
end

function TestPolice:test_an_arrest_costs_what_the_server_says_it_costs()
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    local outcome = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.offences, { "robbery" })
    lu.assertEquals(outcome.value.fined, 50000)
    lu.assertEquals(outcome.value.unpaid, 0)
    lu.assertEquals(outcome.value.minutes, 15)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.crook)), Money.of(1500))
    lu.assertEquals(self.world.ledger:balance("external:court"), Money.of(500))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_several_offences_add_up()
    self:crime("crime.robbery")
    self.world.clock:skip(1000)
    self:crime("crime.vehicle_theft")
    self.at[self.officer] = self.crook
    local outcome = self:ask("police.arrest", { suspect = self.crook })
    lu.assertEquals(#outcome.value.offences, 2)
    lu.assertEquals(outcome.value.fined, 90000)     -- 50,000 plus 40,000
    lu.assertEquals(outcome.value.minutes, 27)
end

function TestPolice:test_nothing_on_them_means_no_arrest()
    self.at[self.officer] = self.crook
    local outcome = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_warrant")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.crook)), Money.of(2000))
end

function TestPolice:test_a_crime_nobody_saw_is_not_something_to_arrest_on_sight_for()
    -- It is on the record, and a detective can find it, but it is not a
    -- warrant. The city knows; the officer in the street does not.
    self:crime("crime.burglary", false)
    self.at[self.officer] = self.crook
    lu.assertEquals(self:ask("police.arrest", { suspect = self.crook }).code, "no_warrant")
    lu.assertEquals(#self.world.services.recall(self.crook, { kind = "crime.burglary" }), 1)
end

function TestPolice:test_you_have_to_be_standing_next_to_them()
    self:crime("crime.robbery")
    lu.assertEquals(self:ask("police.arrest", { suspect = self.crook }).code, "too_far")
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("police.arrest", { suspect = self.crook }).code, "no_proximity")
end

function TestPolice:test_being_caught_clears_exactly_what_they_were_wanted_for()
    self:crime("crime.murder")
    lu.assertEquals(self.world.services.heat(self.crook), 120)
    self.at[self.officer] = self.crook
    lu.assertTrue(self:ask("police.arrest", { suspect = self.crook }):succeeded())
    lu.assertEquals(self.world.services.heat(self.crook), 0)
    -- and there is nothing left to arrest them for
    lu.assertEquals(self:ask("police.arrest", { suspect = self.crook }).code, "already_held")
end

function TestPolice:test_the_crimes_stay_on_the_record_after_the_arrest()
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    self:ask("police.arrest", { suspect = self.crook })
    local history = self.world.services.recall(self.crook)
    lu.assertEquals(history[1].kind, "police.arrest")
    lu.assertEquals(history[2].kind, "crime.robbery")
    -- which is the whole promise: you served for it and you still did it
    lu.assertEquals(#self.world.services.recall(self.crook, { prefix = "crime." }), 1)
end

function TestPolice:test_doing_it_again_after_serving_is_a_fresh_warrant()
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    self:ask("police.arrest", { suspect = self.crook })
    self.world.clock:skip(20 * MINUTE)
    self.world:tick(MINUTE)                       -- time served
    lu.assertNil(self.world.services.police.detained_until(self.crook))

    self:crime("crime.assault")
    local again = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(again:succeeded())
    -- only the new one, because the arrest closed the old
    lu.assertEquals(again.value.offences, { "assault" })
    lu.assertEquals(again.value.minutes, 8)
end

function TestPolice:test_the_victim_of_a_crime_is_not_wanted_for_it()
    -- The record finds a murder from the victim's side too, which is how a
    -- body gets a name. Read as a warrant, it had a woman killed in front of a
    -- witness fined and jailed for her own murder when she came back.
    self.world.ledger:transfer("stake-victim", "external:mint", Characters.wallet(self.witness), Money.of(2000))
    self.world.services.remember("murder-1", { subject = self.crook, kind = "crime.murder", weight = 80,
        witnesses = { self.officer }, involved = { self.witness } })
    self.at[self.officer] = self.witness
    lu.assertEquals(self:ask("police.arrest", { suspect = self.witness }).code, "no_warrant")
    lu.assertEquals(self:ask("police.lookup", { suspect = self.witness }).value.wanted_for, {})
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.witness)), Money.of(2000))
    lu.assertNil(self.world.services.police.detained_until(self.witness))
    -- and whoever did it still is
    lu.assertEquals(self:ask("police.lookup", { suspect = self.crook }).value.wanted_for, { "murder" })
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_the_owner_of_a_stolen_car_is_not_wanted_for_taking_it()
    -- Taking a car names its owner on the theft, so the owner could be found.
    -- Read as a warrant, the owner was the one fined for "taking a vehicle".
    local car = self.world.services.vehicles.register(self.witness, { model = "sultan", plate = "NYR 009" })
    self.world.ledger:transfer("stake-owner", "external:mint", Characters.wallet(self.witness), Money.of(2000))
    self.world.services.inventory:spawn("pick", self.crook, "lockpick", 1)
    self.world.services.witnesses = function() return { self.officer } end
    self.at[self.crook] = car.id
    local thief = { actor = self.crook, account = BOB }
    lu.assertEquals(self.world:dispatch("vehicle.hotwire", { vehicle = car.id }, thief).code, "working")
    self.world.clock:skip(31 * Clock.MS_PER_SECOND)
    lu.assertTrue(self.world:dispatch("vehicle.hotwire", { vehicle = car.id }, thief):succeeded())

    self.at[self.officer] = self.witness
    lu.assertEquals(self:ask("police.arrest", { suspect = self.witness }).code, "no_warrant")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.witness)), Money.of(2000))
    self.at[self.officer] = self.crook
    local arrest = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(arrest.value.offences, { "taking a vehicle" })
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_making_an_arrest_does_not_close_the_officers_own_warrant()
    -- An officer is named on every arrest they make. Read as their own last
    -- arrest, it closed everything they had done before it: an officer who
    -- beat somebody in front of a witness only had to arrest anybody at all.
    local ERIN = "license:eeee5555"
    self.world.services.remember("beating", { subject = self.officer, kind = "crime.assault", weight = 20,
        witnesses = { self.witness }, involved = { self.crook } })
    self.world.clock:skip(1000)
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    lu.assertTrue(self:ask("police.arrest", { suspect = self.crook }):succeeded())
    lu.assertEquals(#self.world.services.police.wanted_for(self.officer), 1)

    local second = self.world:dispatch("character.create",
        { first_name = "Paul", last_name = "Vane" }, { account = ERIN }).value
    self.world.services.police.commission(second)
    self.world:dispatch("police.duty", { on = true }, { actor = second, account = ERIN })
    self.at[second] = self.officer
    local arrest = self:ask("police.arrest", { suspect = self.officer }, second, ERIN)
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(arrest.value.offences, { "assault" })
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_a_crime_in_the_same_moment_as_an_arrest_is_still_a_warrant()
    -- Everything between two server ticks happens at one city millisecond.
    -- Compared by the clock, a punch thrown in the tick of an arrest came
    -- neither before it nor after, so it raised heat and could never be
    -- charged. The record writes lines in an order, and that is what "since
    -- the last arrest" means.
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    lu.assertTrue(self:ask("police.arrest", { suspect = self.crook }):succeeded())
    self.world.services.remember("swing", { subject = self.crook, kind = "crime.assault", weight = 20,
        witnesses = { self.witness }, involved = { self.officer } })
    lu.assertEquals(self.world.services.heat(self.crook), 25)

    self.world.clock:skip(20 * MINUTE)
    self.world:tick(MINUTE)                       -- time served for the robbery
    lu.assertNil(self.world.services.police.detained_until(self.crook))
    local again = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(again:succeeded())
    lu.assertEquals(again.value.offences, { "assault" })
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_a_fine_larger_than_they_hold_takes_what_there_is()
    self.world.ledger:transfer("spent", Characters.wallet(self.crook), "external:mint", Money.of(1800))
    self:crime("crime.murder")
    self.at[self.officer] = self.crook
    local outcome = self:ask("police.arrest", { suspect = self.crook })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.fined, 20000)         -- two hundred, all they had
    lu.assertEquals(outcome.value.unpaid, 130000)
    -- the wallet did not go negative, which is what the books depend on
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.crook)), Money.zero)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
    -- and what was not paid is on the record rather than forgotten
    lu.assertEquals(self.world.services.recall(self.crook, { kind = "police.arrest" })[1].meta.unpaid,
        130000)
end

function TestPolice:test_they_are_held_for_the_time_and_then_let_out()
    self:crime("crime.assault")
    self.at[self.officer] = self.crook
    self:ask("police.arrest", { suspect = self.crook })
    local out_at = self.world.services.police.detained_until(self.crook)
    lu.assertEquals(out_at, self.world.clock:now() + 8 * MINUTE)

    local released
    self.world:on("police.released", function(payload) released = payload end, { label = "spec" })
    self.world:tick(4 * MINUTE)
    lu.assertNotNil(self.world.services.police.detained_until(self.crook))
    lu.assertNil(released)
    self.world:tick(5 * MINUTE)
    lu.assertNotNil(released)
    lu.assertEquals(released.character, self.crook)
    lu.assertNil(self.world.services.police.detained_until(self.crook))
end

function TestPolice:test_two_officers_cannot_arrest_one_person_twice()
    local second = self.world:dispatch("character.create",
        { first_name = "Paul", last_name = "Vane" }, { account = CARLA }).value
    self.world.services.police.commission(second)
    self.world:dispatch("police.duty", { on = true }, { actor = second, account = CARLA })
    self:crime("crime.robbery")
    self.at[self.officer] = self.crook
    self.at[second] = self.crook

    lu.assertTrue(self:ask("police.arrest", { suspect = self.crook }):succeeded())
    local race = self:ask("police.arrest", { suspect = self.crook }, second, CARLA)
    lu.assertTrue(race:was_refused())
    lu.assertEquals(race.code, "already_held")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.crook)), Money.of(1500))
    lu.assertEquals(#self.world.services.recall(self.crook, { kind = "police.arrest" }), 1)
end

function TestPolice:test_an_officer_cannot_arrest_themselves()
    lu.assertEquals(self:ask("police.arrest", { suspect = self.officer }).code, "not_yourself")
end

function TestPolice:test_looking_somebody_up_says_what_is_on_them()
    self:crime("crime.robbery")
    self.world.clock:skip(1000)
    self:crime("crime.burglary", false)
    local outcome = self:ask("police.lookup", { suspect = self.crook })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.records, 2)          -- both, seen or not
    lu.assertEquals(outcome.value.wanted_for, { "robbery" })   -- only what was seen
    lu.assertEquals(outcome.value.fine, 50000)
    lu.assertEquals(outcome.value.heat, 40)
end

function TestPolice:test_looking_somebody_up_is_itself_remembered()
    -- A search with no reason is a thing worth being able to find.
    self:ask("police.lookup", { suspect = self.crook })
    local searches = self.world.services.recall(self.officer, { kind = "police.lookup" })
    lu.assertEquals(#searches, 1)
    lu.assertEquals(searches[1].involved, { self.crook })
    lu.assertEquals(#self.world.services.recall(self.crook, { kind = "police.lookup" }), 1)
    -- Findable, and not by the person searched: their own record reads what
    -- they did, so it does not tell a suspect the police are looking.
    local theirs = self.world:dispatch("record.mine", {}, { actor = self.crook, account = BOB })
    lu.assertEquals(theirs.value.records, {})
    local mine = self.world:dispatch("record.mine", {}, { actor = self.officer, account = ALICE })
    lu.assertEquals(#mine.value.records, 1)
    lu.assertEquals(mine.value.records[1].kind, "police.lookup")
end

function TestPolice:test_looking_up_somebody_who_does_not_exist_writes_nothing()
    -- Every search is a line on the record, and a search for a made-up id was
    -- one too: thirty a minute of people who do not exist, filling the window
    -- the city's warrants live in.
    local before = self.world.services.record:count()
    local outcome = self:ask("police.lookup", { suspect = "chr_000000000000000000a" })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_such_person")
    lu.assertEquals(self.world.services.record:count(), before)
end

function TestPolice:test_an_officer_cannot_search_their_own_warrant_out_of_the_record()
    -- The record keeps a window of lines and drops the oldest. An officer who
    -- searched often enough pushed their own witnessed murder out of it, and
    -- with it the only thing anybody was wanted for it by.
    local ERIN = "license:eeee5555"
    self.world:deactivate()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }), { limit = 8 })
    local world = self.world
    local officer = world:dispatch("character.create", { first_name = "Kate", last_name = "Ward" },
        { account = ALICE }).value
    local neighbour = world:dispatch("character.create", { first_name = "John", last_name = "Roe" },
        { account = BOB }).value
    local witness = world:dispatch("character.create", { first_name = "Mary", last_name = "Poe" },
        { account = CARLA }).value
    world.ledger:transfer("stake", "external:mint", Characters.wallet(officer), Money.of(2000))
    world.services.police.commission(officer)
    world:dispatch("police.duty", { on = true }, { actor = officer, account = ALICE })
    world.services.remember("murder", { subject = officer, kind = "crime.murder", weight = 80,
        witnesses = { witness }, involved = { neighbour } })

    for _ = 1, 20 do
        world.clock:skip(1000)
        lu.assertTrue(world:dispatch("police.lookup", { suspect = neighbour },
            { actor = officer, account = ALICE }):succeeded())
    end
    lu.assertTrue(world.services.record:archived_count() > 0)
    lu.assertEquals(#world.services.police.wanted_for(officer), 1)

    local second = world:dispatch("character.create", { first_name = "Paul", last_name = "Vane" },
        { account = ERIN }).value
    world.services.police.commission(second)
    world:dispatch("police.duty", { on = true }, { actor = second, account = ERIN })
    world.services.proximity = function(actor, target) return actor == second and target == officer end
    local arrest = world:dispatch("police.arrest", { suspect = officer }, { actor = second, account = ERIN })
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(arrest.value.offences, { "murder" })
    -- and once it is closed, it leaves the window like everything else
    for _ = 1, 10 do
        world.clock:skip(1000)
        world:dispatch("police.lookup", { suspect = neighbour }, { actor = second, account = ERIN })
    end
    lu.assertEquals(#world.services.record:search({ subject = officer, kind = "crime.murder" }), 0)
    lu.assertEquals(world.ledger:total(), Money.zero)
    lu.assertTrue(world:verify())
end

function TestPolice:test_an_officer_can_have_a_car_taken_away()
    local car = self.world.services.vehicles.register(self.crook,
        { model = "sultan", plate = "NYR 001" })
    self.at[self.officer] = car.id
    lu.assertTrue(self:ask("police.seize", { vehicle = car.id }):succeeded())
    lu.assertEquals(self.world.services.vehicles.cars:load(car.id).state, "impounded")
    -- and not from across town, and not off duty
    local other = self.world.services.vehicles.register(self.crook,
        { model = "banshee", plate = "NYR 002" })
    lu.assertEquals(self:ask("police.seize", { vehicle = other.id }).code, "too_far")
    self:ask("police.duty", { on = false })
    self.at[self.officer] = other.id
    lu.assertEquals(self:ask("police.seize", { vehicle = other.id }).code, "not_on_duty")
end

function TestPolice:test_a_car_seized_twice_in_one_tick_is_on_the_record_twice()
    -- A seizure was written down under the car and the city millisecond, and
    -- every command between two server ticks shares one: a car taken, paid
    -- out and taken again in the same tick went to the lot twice and onto the
    -- record once.
    local car = self.world.services.vehicles.register(self.crook, { model = "sultan", plate = "NYR 003" })
    self.at[self.officer] = car.id
    lu.assertTrue(self:ask("police.seize", { vehicle = car.id }):succeeded())
    lu.assertTrue(self.world:dispatch("vehicle.retrieve", { vehicle = car.id },
        { actor = self.crook, account = BOB }):succeeded())
    lu.assertTrue(self:ask("police.seize", { vehicle = car.id }):succeeded())
    lu.assertEquals(#self.world.services.recall(self.crook, { kind = "vehicle.impounded" }), 2)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestPolice:test_two_arrests_in_one_tick_are_two_fines_and_two_arrests()
    -- A fine and an arrest were named by who and the city millisecond. With an
    -- offence that carries no time inside, somebody arrested, doing it again
    -- in front of the officer and arrested again in the same tick was told
    -- they were fined twice, paid once, and had one arrest written down, so
    -- the second crime stayed a warrant.
    self.world:deactivate()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }), nil,
        { offences = { ["crime.assault"] = { fine = 10000, minutes = 0, label = "assault" } } })
    local world = self.world
    local officer = world:dispatch("character.create", { first_name = "Kate", last_name = "Ward" },
        { account = ALICE }).value
    local crook = world:dispatch("character.create", { first_name = "John", last_name = "Roe" },
        { account = BOB }).value
    world.ledger:transfer("stake", "external:mint", Characters.wallet(crook), Money.of(2000))
    world.services.police.commission(officer)
    world:dispatch("police.duty", { on = true }, { actor = officer, account = ALICE })
    world.services.proximity = function() return true end
    local O = { actor = officer, account = ALICE }

    world.services.remember("first", { subject = crook, kind = "crime.assault", witnesses = { officer } })
    lu.assertEquals(world:dispatch("police.arrest", { suspect = crook }, O).value.fined, 10000)
    world.services.remember("second", { subject = crook, kind = "crime.assault", witnesses = { officer } })
    lu.assertEquals(world:dispatch("police.arrest", { suspect = crook }, O).value.fined, 10000)

    lu.assertEquals(world.ledger:balance(Characters.wallet(crook)), Money.of(1800))
    lu.assertEquals(#world.services.recall(crook, { kind = "police.arrest" }), 2)
    lu.assertEquals(world.services.police.wanted_for(crook), {})
    lu.assertEquals(world.ledger:total(), Money.zero)
    lu.assertTrue(world:verify())
end

function TestPolice:test_logging_out_takes_you_off_duty()
    self.world:dispatch("character.select", { character = self.officer }, { account = ALICE })
    lu.assertTrue(self.world.services.police.is_on_duty(self.officer))
    self.world:dispatch("character.release", {}, { account = ALICE })
    lu.assertFalse(self.world.services.police.is_on_duty(self.officer))
    lu.assertTrue(self.world.services.police.is_officer(self.officer))   -- still commissioned
end

function TestPolice:test_a_commission_can_be_taken_away()
    self.world.services.police.commission(self.officer, false)
    lu.assertFalse(self.world.services.police.is_officer(self.officer))
    lu.assertFalse(self.world.services.police.is_on_duty(self.officer))
    lu.assertEquals(self:ask("police.duty", { on = true }).code, "not_an_officer")
end

function TestPolice:test_a_nonsense_offence_table_is_caught_at_load()
    lu.assertError(function() return Police.system({ offences = { robbery = { fine = 1, minutes = 1 } } }) end)
    lu.assertError(function()
        return Police.system({ offences = { ["crime.x"] = { fine = 1.5, minutes = 1 } } })
    end)
    lu.assertError(function()
        return Police.system({ offences = { ["crime.x"] = { fine = 1, minutes = -1 } } })
    end)
end

TestPoliceRestart = {}

function TestPoliceRestart:setUp()
    for _, name in ipairs({ "world", "chr", "veh" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestPoliceRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestPoliceRestart:test_a_sentence_survives_a_restart_and_a_roster_does_not()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local officer = first:dispatch("character.create",
        { first_name = "Kate", last_name = "Ward" }, { account = ALICE }).value
    local crook = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(crook), Money.of(2000))
    first.services.proximity = function() return true end
    first.services.police.commission(officer)
    first:dispatch("police.duty", { on = true }, { actor = officer, account = ALICE })
    first.services.remember("c1", { subject = crook, kind = "crime.murder",
                                    weight = 60, witnesses = { officer } })
    local arrest = first:dispatch("police.arrest", { suspect = crook },
        { actor = officer, account = ALICE })
    lu.assertTrue(arrest:succeeded())
    local out_at = first.services.police.detained_until(crook)
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    -- still inside, for exactly as long as they had left
    lu.assertEquals(self.world.services.police.detained_until(crook), out_at)
    -- restarting the server does not clear a record or a fine
    lu.assertEquals(#self.world.services.recall(crook, { kind = "police.arrest" }), 1)
    lu.assertEquals(self.world.ledger:balance("external:court"), Money.of(1500))
    -- the commission survives; being on duty does not
    lu.assertTrue(self.world.services.police.is_officer(officer))
    lu.assertFalse(self.world.services.police.is_on_duty(officer))
    lu.assertEquals(self.world.services.police.officers(), {})
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
