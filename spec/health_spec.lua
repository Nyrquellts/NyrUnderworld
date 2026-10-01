--- Nobody says how much it hurt. Damage is a service the server calls, never a
--- command a client sends, because a command with a damage field lets anybody
--- kill anybody from anywhere.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Police = require("systems.police")
local Health = require("systems.health")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"

local function catalogue()
    local items = Items.catalogue()
    items:define("bandage", { label = "Bandage", weight = 100, stack = 10, category = "consumable" })
    return items
end

local function build(world, health_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Police.system())
    world:install(Health.system(health_opts))
    return world
end

TestHealth = {}

function TestHealth:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self:person("Jane", "Doe", ALICE)
    self.john = self:person("John", "Roe", BOB)
    self.medic = self:person("Mary", "Poe", CARLA)
    self.world.ledger:transfer("stake", "external:mint", Characters.wallet(self.jane), Money.of(1000))

    self.at, self.seen = {}, {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.world.services.witnesses = function() return self.seen end
    self.health = self.world.services.health
end

function TestHealth:person(first, last, account)
    local id = self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
    self.world:dispatch("character.select", { character = id }, { account = account })
    return id
end

function TestHealth:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestHealth:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.jane, account = account or ALICE })
end

function TestHealth:test_everybody_starts_whole()
    local status = self.health.status(self.jane)
    lu.assertEquals(status.hp, Health.MAX_HP)
    lu.assertEquals(status.state, "well")
    lu.assertNil(status.down_at)
end

function TestHealth:test_there_is_no_command_that_takes_damage()
    -- The single most obvious thing to reach for when a resource exposes a net
    -- event. It is not there to reach for.
    for _, name in ipairs(self.world.commands:names()) do
        local described = self.world.commands:describe(name)
        for _, field in ipairs(described.args) do
            lu.assertNotEquals(field.name, "damage", name)
            lu.assertNotEquals(field.name, "amount", name .. " " .. field.name)
            lu.assertNotEquals(field.name, "hp", name)
        end
    end
    lu.assertNil(self.world.commands:describe("health.harm"))
    lu.assertFalse(self.world.commands:defined("health.harm"))
end

function TestHealth:test_being_hurt_takes_health_and_says_so()
    local heard
    self.world:on("character.hurt", function(payload) heard = payload end, { label = "spec" })
    local status = self.health.harm("hit-1", self.jane, 30, { by = self.john, cause = "fists" })
    lu.assertEquals(status.hp, 70)
    lu.assertEquals(status.state, "well")
    lu.assertEquals(heard.by, self.john)
    lu.assertEquals(heard.cause, "fists")
end

function TestHealth:test_running_out_of_health_puts_you_down_not_in_the_ground()
    -- A fight that ends instantly in death leaves nobody room to intervene.
    local heard
    self.world:on("character.down", function(payload) heard = payload end, { label = "spec" })
    self.health.harm("hit-1", self.jane, 150, { by = self.john, cause = "bat" })
    local status = self.health.status(self.jane)
    lu.assertEquals(status.state, "down")
    lu.assertEquals(status.hp, 0)
    lu.assertNotNil(heard.bleeds_at)
    lu.assertTrue(self.health.is_down(self.jane))
    lu.assertFalse(self.health.is_dead(self.jane))
    -- and they are still an active character, because they are not dead
    lu.assertEquals(self.world:repository(Characters.Character):load(self.jane).state, "active")
end

function TestHealth:test_hitting_somebody_who_is_already_down_finishes_it()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    local status = self.health.harm("hit-2", self.jane, 1, { by = self.john })
    lu.assertEquals(status.state, "dead")
    lu.assertEquals(self.world:repository(Characters.Character):load(self.jane).state, "dead")
end

function TestHealth:test_the_dead_cannot_be_hurt_again()
    self.health.kill("k1", self.jane, "fell")
    local status, why = self.health.harm("hit-1", self.jane, 10, { by = self.john })
    lu.assertNil(status)
    lu.assertStrContains(why, "already dead")
end

function TestHealth:test_somebody_who_does_not_exist_cannot_be_hurt()
    local status, why = self.health.harm("hit-1", "chr_000000000000000000a", 10)
    lu.assertNil(status)
    lu.assertStrContains(why, "no such person")
end

function TestHealth:test_nonsense_damage_is_a_programming_error_and_is_loud()
    lu.assertError(function() return self.health.harm("", self.jane, 10) end)
    lu.assertError(function() return self.health.harm("h", self.jane, 0) end)
    lu.assertError(function() return self.health.harm("h", self.jane, -5) end)
    lu.assertError(function() return self.health.harm("h", self.jane, 1.5) end)
end

-- ------------------------------------------------------------- the record

function TestHealth:test_a_beating_is_one_assault_and_not_forty()
    -- Forty records would bury the one that matters under the noise of the
    -- ones that do not.
    for index = 1, 10 do
        self.health.harm("hit-" .. index, self.jane, 5, { by = self.john, cause = "fists" })
    end
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.assault" }), 1)
    -- a minute later is a second incident
    self.world.clock:skip(61 * Clock.MS_PER_SECOND)
    self.health.harm("hit-later", self.jane, 5, { by = self.john })
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.assault" }), 2)
end

function TestHealth:test_killing_somebody_is_a_murder_on_the_record()
    self.seen = { self.medic }
    self.health.harm("hit-1", self.jane, 150, { by = self.john, cause = "bat" })
    self.health.harm("hit-2", self.jane, 1, { by = self.john, cause = "bat" })
    local murders = self.world.services.recall(self.john, { kind = "crime.murder" })
    lu.assertEquals(#murders, 1)
    lu.assertEquals(murders[1].meta.victim, self.jane)
    lu.assertEquals(murders[1].meta.cause, "bat")
    -- and it is findable from the victim side, which is how a body gets a name
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "crime.murder" }), 1)
end

function TestHealth:test_a_murder_nobody_saw_leaves_no_heat_and_a_full_record()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    self.health.harm("hit-2", self.jane, 1, { by = self.john })
    lu.assertEquals(self.world.services.heat(self.john), 0)
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.murder" }), 1)
end

function TestHealth:test_a_murder_somebody_saw_is_arrestable_with_nothing_else_changed()
    self.seen = { self.medic }
    self.health.harm("hit-1", self.jane, 150, { by = self.john, cause = "bat" })
    self.health.harm("hit-2", self.jane, 1, { by = self.john, cause = "bat" })
    -- assault plus murder, both witnessed
    lu.assertEquals(self.world.services.heat(self.john), 145)

    self.world.services.police.commission(self.medic)
    self.world:dispatch("police.duty", { on = true }, { actor = self.medic, account = CARLA })
    self.at[self.medic] = self.john
    local arrest = self.world:dispatch("police.arrest", { suspect = self.john },
        { actor = self.medic, account = CARLA })
    lu.assertTrue(arrest:succeeded())
    lu.assertEquals(#arrest.value.offences, 2)
    lu.assertEquals(arrest.value.minutes, 53)          -- assault 8 plus murder 45
    lu.assertEquals(self.world.services.heat(self.john), 0)
end

function TestHealth:test_dying_with_nobody_to_blame_blames_nobody()
    self.health.harm("hit-1", self.jane, 150, {})
    self.health.kill("k1", self.jane, "fell off a roof")
    lu.assertEquals(#self.world.services.record:search({ kind = "crime.murder" }), 0)
    lu.assertTrue(self.health.is_dead(self.jane))
end

-- ------------------------------------------------------------- bleeding out

function TestHealth:test_being_down_runs_out()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    local died
    self.world:on("character.died", function(payload) died = payload end, { label = "spec" })

    self.world:tick(2 * Clock.MS_PER_MINUTE)
    lu.assertTrue(self.health.is_down(self.jane))
    lu.assertNil(died)

    self.world:tick(4 * Clock.MS_PER_MINUTE)
    lu.assertTrue(self.health.is_dead(self.jane))
    lu.assertEquals(died.character, self.jane)
    lu.assertEquals(died.cause, "bled out")
    -- bleeding out is not a murder charge on whoever put them down
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.murder" }), 0)
end

function TestHealth:test_a_revive_beats_the_clock()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    self.world.services.inventory:spawn("kit", self.medic, "bandage", 1)
    self.at[self.medic] = self.jane

    local outcome = self:ask("health.revive", { target = self.jane }, self.medic, CARLA)
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(self.health.status(self.jane).state, "well")
    lu.assertEquals(self.health.status(self.jane).hp, 25)
    -- the kit was used up and left the world
    lu.assertEquals(self.world.services.inventory:count(self.medic, "bandage"), 0)
    lu.assertEquals(self.world.services.inventory:total("bandage"), 0)
    -- and the clock no longer has them
    for _ = 1, 3 do self.world:tick(2 * Clock.MS_PER_MINUTE) end
    lu.assertFalse(self.health.is_dead(self.jane))
end

function TestHealth:test_a_revive_needs_a_kit_a_body_and_being_there()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    self.at[self.medic] = self.jane
    lu.assertEquals(self:ask("health.revive", { target = self.jane }, self.medic, CARLA).code, "no_kit")

    self.world.services.inventory:spawn("kit", self.medic, "bandage", 1)
    self.at[self.medic] = nil
    lu.assertEquals(self:ask("health.revive", { target = self.jane }, self.medic, CARLA).code, "too_far")

    self.at[self.medic] = self.jane
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("health.revive", { target = self.jane }, self.medic, CARLA).code,
        "no_proximity")
end

function TestHealth:test_you_cannot_revive_the_dead_or_the_standing_or_yourself()
    self.world.services.inventory:spawn("kit", self.medic, "bandage", 3)
    self.at[self.medic] = self.jane
    lu.assertEquals(self:ask("health.revive", { target = self.jane }, self.medic, CARLA).code, "not_down")

    self.health.kill("k1", self.jane, "shot")
    lu.assertEquals(self:ask("health.revive", { target = self.jane }, self.medic, CARLA).code, "too_late")

    self.at[self.medic] = self.medic
    lu.assertEquals(self:ask("health.revive", { target = self.medic }, self.medic, CARLA).code,
        "not_yourself")
    -- and no kit was spent on any of those
    lu.assertEquals(self.world.services.inventory:count(self.medic, "bandage"), 3)
end

function TestHealth:test_a_revive_does_not_let_the_medic_say_how_much()
    local described = self.world.commands:describe("health.revive")
    lu.assertEquals(#described.args, 1)
    lu.assertEquals(described.args[1].name, "target")
end

-- --------------------------------------------------------------- respawning

function TestHealth:test_the_hospital_charges_and_sends_you_out()
    self.health.kill("k1", self.jane, "shot")
    local outcome = self:ask("health.respawn", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.hp, 60)
    lu.assertEquals(outcome.value.paid, 50000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))
    lu.assertEquals(self.world.ledger:balance("external:hospital"), Money.of(500))
    lu.assertEquals(self.health.status(self.jane).state, "well")
    lu.assertEquals(self.world:repository(Characters.Character):load(self.jane).state, "active")
end

function TestHealth:test_nobody_is_kept_dead_for_being_broke()
    self.world.ledger:transfer("spent", Characters.wallet(self.jane), "external:mint", Money.of(1000))
    self.health.kill("k1", self.jane, "shot")
    local outcome = self:ask("health.respawn", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 0)
    -- the wallet did not go negative, which is what the books depend on
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.zero)
end

function TestHealth:test_you_cannot_respawn_while_alive()
    lu.assertEquals(self:ask("health.respawn", {}).code, "not_dead")
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    lu.assertEquals(self:ask("health.respawn", {}).code, "not_dead")   -- down is not dead
end

function TestHealth:test_respawning_clears_the_slate_not_the_record()
    self.health.harm("hit-1", self.jane, 150, { by = self.john })
    self.health.harm("hit-2", self.jane, 1, { by = self.john })
    self:ask("health.respawn", {})
    lu.assertEquals(self.health.status(self.jane).hp, 60)
    -- what happened to them is still what happened to them
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "crime.murder" }), 1)
end

function TestHealth:test_your_own_status_is_all_you_can_read()
    local described = self.world.commands:describe("health.status")
    lu.assertEquals(described.args, {})
    self.health.harm("hit-1", self.jane, 40, {})
    lu.assertEquals(self:ask("health.status", {}).value.hp, 60)
    lu.assertEquals(self.world:dispatch("health.status", {}, { account = ALICE }).code, "not_playing")
end

function TestHealth:test_asking_about_somebody_writes_nothing_down()
    -- A health sheet was made, and saved, for every id anybody asked about:
    -- reading your own status did it, and so did a revive aimed at a made-up
    -- id, refused, twelve times a minute, growing the saved city without end.
    local ghost = "chr_000000000000000000a"
    self.at[self.medic] = ghost
    lu.assertEquals(self.health.status(ghost).state, "well")
    lu.assertEquals(self.health.status(ghost).hp, Health.MAX_HP)
    lu.assertFalse(self.health.is_down(ghost))
    lu.assertFalse(self.health.is_dead(ghost))
    lu.assertEquals(self:ask("health.status", {}).value.hp, Health.MAX_HP)
    lu.assertEquals(self:ask("health.revive", { target = ghost }, self.medic, CARLA).code, "not_down")
    lu.assertEquals(self:ask("health.respawn", {}).code, "not_dead")
    lu.assertEquals(self.health.heal("mend", ghost, 10).hp, Health.MAX_HP)
    lu.assertTrue(self.world:save())
    lu.assertEquals(self.world.store:get("world", "health").sheets, {})

    -- and something actually happening to somebody is still written down
    self.health.harm("hit-1", self.jane, 10, {})
    lu.assertTrue(self.world:save())
    lu.assertEquals(self.world.store:get("world", "health").sheets[self.jane].hp, 90)
end

function TestHealth:test_dying_twice_in_one_tick_is_two_hospital_bills()
    -- The bill was named by who and the city millisecond, and every command
    -- between two server ticks shares one: a second respawn in the same tick
    -- was told it had paid five hundred and paid nothing.
    self.health.kill("k1", self.jane, "fell")
    local first = self:ask("health.respawn", {})
    self.health.kill("k2", self.jane, "fell again")
    local second = self:ask("health.respawn", {})
    lu.assertEquals(first.value.paid, 50000)
    lu.assertEquals(second.value.paid, 50000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.zero)
    lu.assertEquals(self.world.ledger:balance("external:hospital"), Money.of(1000))
end

function TestHealth:test_two_medics_on_one_patient_in_one_tick_is_not_a_server_error()
    -- The bandage a revive used was named by the patient and the city
    -- millisecond. A second medic treating the same person in the same tick
    -- built that id again for a different pocket, and the inventory threw.
    local DAN = "license:dddd4444"
    local second = self:person("Paul", "Vane", DAN)
    self.world.services.inventory:spawn("kit-1", self.medic, "bandage", 1)
    self.world.services.inventory:spawn("kit-2", second, "bandage", 1)
    self.at[self.medic], self.at[second] = self.jane, self.jane
    self.health.harm("down-1", self.jane, 150, {})
    lu.assertTrue(self:ask("health.revive", { target = self.jane }, self.medic, CARLA):succeeded())
    self.health.harm("down-2", self.jane, 150, {})
    local again = self:ask("health.revive", { target = self.jane }, second, DAN)
    lu.assertFalse(again:is_failure(), tostring(again.message))
    lu.assertTrue(again:succeeded())
    lu.assertEquals(self.world.services.inventory:count(second, "bandage"), 0)
end

function TestHealth:test_reviving_twice_in_one_tick_uses_two_bandages()
    -- The same medic, the same patient, the same millisecond: the second
    -- revive was a duplicate of the first bandage and cost nothing.
    self.world.services.inventory:spawn("kit", self.medic, "bandage", 2)
    self.at[self.medic] = self.jane
    self.health.harm("down-1", self.jane, 150, {})
    lu.assertTrue(self:ask("health.revive", { target = self.jane }, self.medic, CARLA):succeeded())
    self.health.harm("down-2", self.jane, 150, {})
    lu.assertTrue(self:ask("health.revive", { target = self.jane }, self.medic, CARLA):succeeded())
    lu.assertEquals(self.world.services.inventory:count(self.medic, "bandage"), 0)
    lu.assertEquals(self.world.services.inventory:total("bandage"), 0)
end

function TestHealth:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Health.system()) end)
    lu.assertError(function() return Health.system({ bleed_ms = 0 }) end)
    lu.assertError(function() return Health.system({ revive_hp = 0 }) end)
    lu.assertError(function() return Health.system({ revive_hp = 500 }) end)
end

-- -------------------------------------------------------------- real time

--- The pace config.lua ships: sixty city milliseconds to a real one, and a
--- server tick every real second. Everything above runs at a rate of one, where
--- a real millisecond and a city millisecond are the same number.
TestHealthPace = {}

function TestHealthPace:setUp()
    self.world = build(World.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = TestHealth.person(self, "Jane", "Doe", ALICE)
    self.john = TestHealth.person(self, "John", "Roe", BOB)
    self.medic = TestHealth.person(self, "Mary", "Poe", CARLA)
    self.at = {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.health = self.world.services.health
end

function TestHealthPace:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestHealthPace:seconds(count)
    for _ = 1, count do self.world:tick(1000) end
end

function TestHealthPace:test_somebody_down_stays_down_long_enough_for_a_medic_to_get_there()
    -- Five city minutes of bleeding is five real seconds at the shipped pace.
    -- Nobody could reach a body in that time, so being down was a slower way
    -- of being dead and a medic was a costume.
    self.world.services.inventory:spawn("kit", self.medic, "bandage", 1)
    local heard
    self.world:on("character.down", function(payload) heard = payload end, { label = "spec" })
    self.health.harm("down", self.jane, 150, {})
    -- what a screen is told to count down to is five real minutes away too
    local FIVE_REAL_MINUTES = 5 * Clock.MS_PER_MINUTE * self.world.clock:rate()
    local status = self.health.status(self.jane)
    lu.assertEquals(status.bleeds_at - status.down_at, FIVE_REAL_MINUTES)
    lu.assertEquals(heard.bleeds_at, status.bleeds_at)
    self:seconds(60)
    lu.assertTrue(self.health.is_down(self.jane), "bled out inside a real minute")
    self.at[self.medic] = self.jane
    lu.assertTrue(self.world:dispatch("health.revive", { target = self.jane },
        { actor = self.medic, account = CARLA }):succeeded())

    -- and five real minutes is still where it ends
    self.health.harm("down-again", self.jane, 150, {})
    self:seconds(299)
    lu.assertTrue(self.health.is_down(self.jane))
    self:seconds(1)
    lu.assertTrue(self.health.is_dead(self.jane))
end

function TestHealthPace:test_a_beating_at_the_pace_the_city_runs_is_one_assault()
    -- Hits within a minute of the first are one incident. Sixty city seconds
    -- is one real second at the shipped pace, so a beating with a punch every
    -- two seconds was a crime per punch.
    for index = 1, 10 do
        self.health.harm("hit-" .. index, self.jane, 1, { by = self.john, cause = "fists" })
        self:seconds(2)
    end
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.assault" }), 1)
    self:seconds(41)
    self.health.harm("hit-later", self.jane, 1, { by = self.john })
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "crime.assault" }), 2)
end

function TestHealthPace:test_however_slowly_the_city_runs_going_down_is_not_already_over()
    -- Real time turned into city time is rounded up. At a pace where five real
    -- minutes is less than a city millisecond, rounding down puts the moment
    -- somebody bleeds out at the moment they went down.
    local slow = build(World.new({ rate = 0.000001, start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = TestHealth.person({ world = slow }, "Jane", "Doe", ALICE)
    slow.services.health.harm("down", jane, 150, {})
    local status = slow.services.health.status(jane)
    lu.assertEquals(status.state, "down")
    lu.assertTrue(status.bleeds_at > status.down_at, "bled out at the moment of going down")
    slow:deactivate()
end

TestHealthRestart = {}

function TestHealthRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestHealthRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestHealthRestart:test_a_save_full_of_untouched_sheets_is_read_back_without_them()
    -- Before reads stopped making sheets, every look at anybody's health, and
    -- every refused revive of a made-up id, wrote a sheet into the save. A
    -- sheet that says nothing happened is the same as no sheet, so a city saved
    -- by that build sheds them when it is read.
    local store = FileStore.new({ root = ROOT })
    local first = build(World.new({ store = store, rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first:dispatch("character.select", { character = jane }, { account = ALICE })
    first.services.health.harm("hit-1", jane, 30, { cause = "fall" })
    lu.assertTrue(first:save())
    local saved = store:get("world", "health")
    saved.sheets["chr_000000000000000000a"] = { hp = 100, state = "well", incidents = {} }
    saved.sheets["chr_000000000000000000b"] = { hp = 100, state = "well", incidents = {} }
    store:put("world", "health", saved)
    lu.assertTrue(store:flush())
    first:deactivate()

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems or {}, "; "))
    lu.assertTrue(self.world:save())
    local sheets = self.world.store:get("world", "health").sheets
    lu.assertNil(sheets["chr_000000000000000000a"], "an untouched sheet came back")
    lu.assertNil(sheets["chr_000000000000000000b"])
    lu.assertEquals(sheets[jane].hp, 70, "a real injury was shed with the junk")
end

function TestHealthRestart:test_injuries_survive_and_bleeding_out_does_not_happen_offline()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first:dispatch("character.select", { character = jane }, { account = ALICE })
    local john = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first:dispatch("character.select", { character = john }, { account = BOB })

    first.services.health.harm("hit-1", jane, 40, { by = john, cause = "fists" })
    first.services.health.harm("hit-2", john, 150, { by = jane, cause = "bat" })
    lu.assertTrue(first.services.health.is_down(john))
    lu.assertTrue(first:close())

    -- a long time passes with the server off
    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    -- a wound is still a wound
    lu.assertEquals(self.world.services.health.status(jane).hp, 60)
    -- but nobody bleeds out during downtime they could not act on
    lu.assertFalse(self.world.services.health.is_dead(john))
    lu.assertEquals(self.world.services.health.status(john).state, "well")
    -- and the record of what was done is untouched. Two assaults happened, one
    -- each way, and both are findable from either side, which is why asking
    -- about a person returns both and asking who did it returns one.
    lu.assertEquals(#self.world.services.recall(jane, { kind = "crime.assault" }), 2)
    lu.assertEquals(#self.world.services.record:search(
        { subject = john, kind = "crime.assault" }), 1)
    lu.assertEquals(#self.world.services.record:search(
        { subject = jane, kind = "crime.assault" }), 1)
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
