--- An admin system is a deliberate hole in every rule above it, so the hole
--- has to be narrow, named, and impossible to use quietly.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Admin = require("systems.admin")
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

local function build(world, admin_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Admin.system(admin_opts))
    return world
end

TestAdmin = {}

function TestAdmin:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.owner = self:person("Kate", "Ward", ALICE)
    self.mod = self:person("Mary", "Poe", BOB)
    self.player = self:person("John", "Roe", CARLA)
    self.admin = self.world.services.admin
    self.admin.grant(self.owner, Admin.OWNER)
    self.admin.grant(self.mod, Admin.MODERATOR)
end

function TestAdmin:person(first, last, account)
    local id = self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
    self.world:dispatch("character.select", { character = id }, { account = account })
    return id
end

function TestAdmin:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestAdmin:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.owner, account = account or ALICE })
end

function TestAdmin:test_a_level_is_granted_and_never_claimed()
    -- There is no command that raises your own level, the same as a police
    -- commission and a gang rank.
    for _, name in ipairs(self.world.commands:names()) do
        lu.assertNotStrContains(name, "grant")
        lu.assertNotStrContains(name, "promote")
    end
    lu.assertEquals(self.admin.level_of(self.player), 0)
    lu.assertFalse(self.admin.is_staff(self.player))
    lu.assertEquals(self:ask("admin.who", {}, self.player, CARLA).code, "not_staff")
end

function TestAdmin:test_a_moderator_can_look_and_not_touch()
    lu.assertTrue(self:ask("admin.who", {}, self.mod, BOB):succeeded())
    lu.assertTrue(self:ask("admin.look", { character = self.player }, self.mod, BOB):succeeded())
    lu.assertEquals(self:ask("admin.give",
        { character = self.player, amount = 100, reason = "because" }, self.mod, BOB).code,
        "not_staff")
end

function TestAdmin:test_who_is_playing_right_now()
    local outcome = self:ask("admin.who", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.online, 3)
    local found
    for _, row in ipairs(outcome.value.online) do
        if row.character == self.player then found = row end
    end
    lu.assertNotNil(found)
    lu.assertEquals(found.name, "John Roe")
    lu.assertEquals(found.staff, 0)
end

function TestAdmin:test_looking_somebody_up_shows_what_the_city_has()
    self.world.services.remember("c1", { subject = self.player, kind = "crime.robbery",
                                         weight = 30, witnesses = { self.mod } })
    local outcome = self:ask("admin.look", { character = self.player })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.name, "John Roe")
    lu.assertEquals(outcome.value.heat, 40)
    lu.assertEquals(#outcome.value.records, 1)
    lu.assertEquals(outcome.value.records[1].kind, "crime.robbery")
end

function TestAdmin:test_money_made_here_comes_from_somewhere_with_a_name()
    -- An economy with a silent mint is an economy nobody can audit.
    local outcome = self:ask("admin.give",
        { character = self.player, amount = 50000, reason = "compensation for a lost car" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.player)), Money.of(500))
    lu.assertEquals(self.world.ledger:balance("external:admin"), Money.of(500):negate())
    lu.assertEquals(self.world.ledger:total(), Money.zero)
end

function TestAdmin:test_taking_it_back_cannot_go_negative()
    self:ask("admin.give", { character = self.player, amount = 20000, reason = "a mistake" })
    local outcome = self:ask("admin.take",
        { character = self.player, amount = 50000, reason = "undoing the mistake" })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_carrying")
    lu.assertTrue(self:ask("admin.take",
        { character = self.player, amount = 20000, reason = "undoing the mistake" }):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.player)), Money.zero)
end

function TestAdmin:test_one_command_has_a_ceiling()
    lu.assertEquals(self:ask("admin.give",
        { character = self.player, amount = 99999999, reason = "why not" }).code, "too_much")
    lu.assertEquals(self:ask("admin.item",
        { character = self.player, item = "water", count = 5000, reason = "why not" }).code,
        "too_much")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.player)), Money.zero)
end

function TestAdmin:test_a_reason_is_not_optional()
    for _, args in ipairs({
        { character = self.player, amount = 100 },
        { character = self.player, amount = 100, reason = "x" },
    }) do
        lu.assertEquals(self:ask("admin.give", args).code, "bad_args")
    end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.player)), Money.zero)
end

function TestAdmin:test_making_something_puts_it_in_the_world_on_the_record()
    local outcome = self:ask("admin.item",
        { character = self.player, item = "water", count = 3, reason = "replacing a lost crate" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(self.world.services.inventory:count(self.player, "water"), 3)
    lu.assertEquals(self.world.services.inventory:total("water"), 3)
    lu.assertTrue(self.world.services.inventory:verify())
end

function TestAdmin:test_everything_staff_do_goes_on_the_record()
    -- Not into a log file that can be rotated away, but into the same record
    -- the city keeps about everybody else.
    self:ask("admin.give", { character = self.player, amount = 10000, reason = "a gift" })
    self:ask("admin.item", { character = self.player, item = "water", count = 1, reason = "thirsty" })
    self:ask("admin.look", { character = self.player })

    local trail = self.world.services.recall(self.owner, { kind = "admin.acted" })
    lu.assertEquals(#trail, 3)
    -- and it is findable from the other side too: what was done to this person
    lu.assertEquals(#self.world.services.recall(self.player, { kind = "admin.acted" }), 3)
end

function TestAdmin:test_the_trail_reads_back_and_is_for_an_owner()
    self:ask("admin.give", { character = self.player, amount = 10000, reason = "a gift" })
    lu.assertEquals(self:ask("admin.trail", {}, self.mod, BOB).code, "not_staff")

    local outcome = self:ask("admin.trail", {})
    lu.assertTrue(outcome:succeeded())
    local gave
    for _, row in ipairs(outcome.value.actions) do
        if row.action == "give" then gave = row end
    end
    lu.assertNotNil(gave)
    lu.assertEquals(gave.by, self.owner)
    lu.assertEquals(gave.on, self.player)
    lu.assertEquals(gave.amount, 10000)
    lu.assertEquals(gave.reason, "a gift")
end

function TestAdmin:test_the_trail_can_be_narrowed_to_one_member_of_staff()
    self.admin.grant(self.mod, Admin.ADMIN)
    self:ask("admin.give", { character = self.player, amount = 100, reason = "one" })
    self:ask("admin.give", { character = self.player, amount = 100, reason = "two" }, self.mod, BOB)
    lu.assertEquals(#self:ask("admin.trail", { who = self.mod }).value.actions, 1)
    lu.assertEquals(#self:ask("admin.trail", {}).value.actions, 2)
end

function TestAdmin:test_two_actions_in_one_server_tick_are_both_on_the_trail()
    -- Every command between two server ticks happens at one city millisecond,
    -- and a trail line was named by who, what and that millisecond. A second
    -- give in the same tick -- ten thousand to a friend, straight after a
    -- small refund to a stranger -- was paid and never written down.
    local friend = self:person("Paul", "Vane", "license:dddd4444")
    lu.assertTrue(self:ask("admin.give",
        { character = self.player, amount = 100, reason = "refund for a bug" }):succeeded())
    lu.assertTrue(self:ask("admin.give",
        { character = friend, amount = 1000000, reason = "compensation" }):succeeded())
    lu.assertEquals(#self:ask("admin.trail", {}).value.actions, 2)
    local about_friend = self.world.services.recall(friend, { kind = "admin.acted" })
    lu.assertEquals(#about_friend, 1)
    lu.assertEquals(about_friend[1].meta.amount, 1000000)
end

function TestAdmin:test_there_is_no_way_to_run_arbitrary_code()
    -- A server that runs whatever it is sent is a server whose rules are
    -- decoration.
    for _, name in ipairs(self.world.commands:names()) do
        for _, banned in ipairs({ "exec", "eval", "run", "lua", "sql", "console" }) do
            lu.assertNotStrContains(name, banned, name)
        end
        for _, field in ipairs(self.world.commands:describe(name).args) do
            lu.assertNotEquals(field.name, "code", name)
            lu.assertNotEquals(field.name, "command", name)
            lu.assertNotEquals(field.name, "query", name)
        end
    end
end

function TestAdmin:test_somebody_who_does_not_exist_gets_nothing()
    lu.assertEquals(self:ask("admin.give",
        { character = "chr_000000000000000000a", amount = 100, reason = "ghost" }).code,
        "no_such_person")
    lu.assertEquals(self:ask("admin.look", { character = "chr_000000000000000000a" }).code,
        "no_such_person")
    lu.assertEquals(self:ask("admin.item",
        { character = self.player, item = "moonrock", count = 1, reason = "testing" }).code,
        "no_such_item")
end

function TestAdmin:test_a_level_can_be_taken_away()
    lu.assertEquals(self.admin.grant(self.mod, nil), 0)
    lu.assertFalse(self.admin.is_staff(self.mod))
    lu.assertEquals(self:ask("admin.who", {}, self.mod, BOB).code, "not_staff")
    lu.assertError(function() return self.admin.grant(self.mod, 9) end)
end

function TestAdmin:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Admin.system()) end)
    lu.assertError(function() return Admin.system({ max_give = 0 }) end)
end

TestAdminRestart = {}

function TestAdminRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestAdminRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestAdminRestart:test_levels_and_the_trail_survive_a_restart()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local owner = first:dispatch("character.create",
        { first_name = "Kate", last_name = "Ward" }, { account = ALICE }).value
    local player = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = CARLA }).value
    first:dispatch("character.select", { character = owner }, { account = ALICE })
    first.services.admin.grant(owner, Admin.OWNER)
    first:dispatch("admin.give", { character = player, amount = 25000, reason = "a gift" },
        { actor = owner, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    lu.assertEquals(self.world.services.admin.level_of(owner), Admin.OWNER)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(player)), Money.of(250))
    -- restarting the server is not a way to clear what staff did
    local trail = self.world.services.recall(owner, { kind = "admin.acted" })
    lu.assertEquals(#trail, 1)
    lu.assertEquals(trail[1].meta.reason, "a gift")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
