--- Nobody says who a message is from. A message that appears to come from
--- somebody else is not a cosmetic bug: it is a way to get a person killed by
--- their own crew.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Police = require("systems.police")
local Phone = require("systems.phone")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"

local function catalogue()
    local items = Items.catalogue()
    items:define("phone", { label = "Phone", weight = 200, unique = true, category = "tool" })
    return items
end

local function build(world, phone_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Police.system())
    world:install(Phone.system(phone_opts))
    return world
end

TestPhone = {}

function TestPhone:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self:person("Jane", "Doe", ALICE)
    self.john = self:person("John", "Roe", BOB)
    self.officer = self:person("Kate", "Ward", CARLA)
    self.phone = self.world.services.phone
end

function TestPhone:person(first, last, account)
    local id = self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
    self.world:dispatch("character.select", { character = id }, { account = account })
    return id
end

function TestPhone:tearDown()
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestPhone:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.jane, account = account or ALICE })
end

function TestPhone:test_everybody_gets_a_number_and_a_phone()
    local outcome = self:ask("phone.number", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertStrMatches(outcome.value.number, "555%-%d%d%d%d%d%d")
    lu.assertTrue(outcome.value.carrying)
    lu.assertEquals(self.world.services.inventory:count(self.jane, "phone"), 1)
    lu.assertEquals(self.phone.holder_of(outcome.value.number), self.jane)
end

function TestPhone:test_two_people_never_share_a_number()
    local seen = {}
    for index = 1, 40 do
        local who = "license:x" .. index
        local made = self.world:dispatch("character.create",
            { first_name = "Test", last_name = "Case" }, { account = who })
        lu.assertTrue(made:succeeded(), made.message)
        local number = self.phone.number_of(made.value)
        lu.assertNotNil(number)
        lu.assertNil(seen[number], "two people got the same number")
        seen[number] = true
    end
end

function TestPhone:test_a_message_lands_and_reads_back()
    local theirs = self.phone.number_of(self.john)
    local heard
    self.world:on("phone.message", function(payload) heard = payload end, { label = "spec" })
    local outcome = self:ask("phone.send", { to = theirs, body = "meet me at the docks" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(heard.to, theirs)
    lu.assertEquals(heard.recipient, self.john)

    local thread = self:ask("phone.thread", { with = self.phone.number_of(self.jane) },
        self.john, BOB).value
    lu.assertEquals(#thread.messages, 1)
    lu.assertEquals(thread.messages[1].body, "meet me at the docks")
    lu.assertEquals(thread.messages[1].from, self.phone.number_of(self.jane))
end

function TestPhone:test_nobody_says_who_a_message_is_from()
    -- There is no from field, so there is nothing to spoof.
    local described = self.world.commands:describe("phone.send")
    for _, field in ipairs(described.args) do
        lu.assertNotEquals(field.name, "from")
        lu.assertNotEquals(field.name, "sender")
    end
    local lying = self:ask("phone.send",
        { to = self.phone.number_of(self.john), body = "hi", from = "555-000000" })
    lu.assertEquals(lying.code, "bad_args")
    lu.assertEquals(self.phone.count(), 0)
end

function TestPhone:test_a_number_nobody_holds_takes_nothing()
    local outcome = self:ask("phone.send", { to = "555-999999", body = "hello?" })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_such_number")
    lu.assertEquals(self.phone.count(), 0)
end

function TestPhone:test_you_cannot_text_yourself()
    lu.assertEquals(self:ask("phone.send",
        { to = self.phone.number_of(self.jane), body = "note to self" }).code, "not_yourself")
end

function TestPhone:test_a_message_too_long_never_reaches_a_handler()
    local outcome = self:ask("phone.send",
        { to = self.phone.number_of(self.john), body = string.rep("x", 300) })
    lu.assertEquals(outcome.code, "bad_args")
    lu.assertEquals(self:ask("phone.send",
        { to = self.phone.number_of(self.john), body = "" }).code, "bad_args")
    lu.assertEquals(self.phone.count(), 0)
end

function TestPhone:test_a_phone_that_is_not_on_you_is_a_phone_you_cannot_use()
    self.world.services.inventory:destroy("taken", self.jane, "phone", 1)
    for _, case in ipairs({ { "phone.send", { to = "555-000000", body = "hi" } },
                            { "phone.thread", { with = "555-000000" } },
                            { "phone.inbox", {} } }) do
        lu.assertEquals(self:ask(case[1], case[2]).code, "no_phone", case[1])
    end
    -- and your own number is still your own number
    lu.assertTrue(self:ask("phone.number", {}):succeeded())
end

function TestPhone:test_you_only_read_threads_your_own_number_is_in()
    -- There is no argument that names whose thread to read.
    local described = self.world.commands:describe("phone.thread")
    lu.assertEquals(#described.args, 2)
    for _, field in ipairs(described.args) do
        lu.assertNotEquals(field.name, "number")
        lu.assertNotEquals(field.name, "of")
    end

    local mine, theirs = self.phone.number_of(self.jane), self.phone.number_of(self.john)
    local third = self.phone.number_of(self.officer)
    self:ask("phone.send", { to = third, body = "private" }, self.john, BOB)
    -- Jane asking about a thread between the other two sees nothing, because
    -- the thread that is read is hers.
    local thread = self:ask("phone.thread", { with = third }).value
    lu.assertEquals(thread.number, mine)
    lu.assertEquals(#thread.messages, 0)
    lu.assertEquals(#self:ask("phone.thread", { with = theirs }, self.officer, CARLA).value.messages, 1)
end

function TestPhone:test_the_inbox_is_one_line_per_person_newest_first()
    local theirs, third = self.phone.number_of(self.john), self.phone.number_of(self.officer)
    self:ask("phone.send", { to = theirs, body = "first" })
    self.world.clock:skip(1000)
    self:ask("phone.send", { to = third, body = "second" })
    self.world.clock:skip(1000)
    self:ask("phone.send", { to = theirs, body = "third" })

    local inbox = self:ask("phone.inbox", {}).value
    lu.assertEquals(#inbox.threads, 2)
    lu.assertEquals(inbox.threads[1].number, theirs)
    lu.assertEquals(inbox.threads[1].last, "third")
    lu.assertTrue(inbox.threads[1].outgoing)
    lu.assertEquals(inbox.threads[2].number, third)
end

function TestPhone:test_a_thread_reads_newest_first_and_is_capped()
    local theirs = self.phone.number_of(self.john)
    for index = 1, 10 do
        self:ask("phone.send", { to = theirs, body = "message " .. index })
        self.world.clock:skip(100)
    end
    local thread = self:ask("phone.thread", { with = theirs, limit = 3 }).value
    lu.assertEquals(#thread.messages, 3)
    lu.assertEquals(thread.messages[1].body, "message 10")
    lu.assertEquals(thread.messages[3].body, "message 8")
end

function TestPhone:test_the_message_store_is_bounded()
    local small = build(World.new({ rate = 1, activate = false }), { limit = 5 })
    small:activate()
    local a = small:dispatch("character.create",
        { first_name = "Ann", last_name = "One" }, { account = ALICE }).value
    local b = small:dispatch("character.create",
        { first_name = "Ben", last_name = "Two" }, { account = BOB }).value
    small:dispatch("character.select", { character = a }, { account = ALICE })
    local theirs = small.services.phone.number_of(b)
    for index = 1, 12 do
        small:dispatch("phone.send", { to = theirs, body = "m" .. index },
            { actor = a, account = ALICE })
    end
    lu.assertEquals(small.services.phone.count(), 5)
    lu.assertEquals(small.services.phone.dropped(), 7)
    small:deactivate()
    self.world:activate()
end

-- ------------------------------------------------------------------- the mdt

function TestPhone:test_a_terminal_pulls_a_thread_and_is_remembered_for_it()
    local theirs = self.phone.number_of(self.john)
    self:ask("phone.send", { to = theirs, body = "bring the van" })

    self.world.services.police.commission(self.officer)
    self.world:dispatch("police.duty", { on = true }, { actor = self.officer, account = CARLA })
    local outcome = self:ask("mdt.messages", { number = theirs }, self.officer, CARLA)
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.holder, self.john)
    lu.assertEquals(#outcome.value.messages, 1)
    lu.assertEquals(outcome.value.messages[1].body, "bring the van")
    -- a search with no reason is a thing worth being able to find
    lu.assertEquals(#self.world.services.recall(self.officer, { kind = "police.lookup" }), 1)
end

function TestPhone:test_a_terminal_is_for_officers_on_duty()
    local theirs = self.phone.number_of(self.john)
    lu.assertEquals(self:ask("mdt.messages", { number = theirs }).code, "not_on_duty")
    self.world.services.police.commission(self.officer)
    lu.assertEquals(self:ask("mdt.messages", { number = theirs }, self.officer, CARLA).code,
        "not_on_duty")
    self.world:dispatch("police.duty", { on = true }, { actor = self.officer, account = CARLA })
    lu.assertTrue(self:ask("mdt.messages", { number = theirs }, self.officer, CARLA):succeeded())
    lu.assertEquals(self:ask("mdt.messages", { number = "555-999999" }, self.officer, CARLA).code,
        "no_such_number")
end

function TestPhone:test_nobody_phones_without_being_somebody()
    -- Each command gets the arguments it declares. Sharing one table across
    -- commands with different declarations tests argument validation, not the
    -- thing this is about.
    local cases = {
        { "phone.number", {} },
        { "phone.send", { to = "555-000000", body = "hi" } },
        { "phone.thread", { with = "555-000000" } },
        { "phone.inbox", {} },
    }
    for _, case in ipairs(cases) do
        lu.assertEquals(self.world:dispatch(case[1], case[2], { account = ALICE }).code,
            "not_playing", case[1])
    end
end

function TestPhone:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Phone.system()) end)
end

TestPhoneRestart = {}

function TestPhoneRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestPhoneRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestPhoneRestart:test_numbers_and_messages_survive_a_restart()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local john = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first:dispatch("character.select", { character = jane }, { account = ALICE })
    local hers = first.services.phone.number_of(jane)
    local his = first.services.phone.number_of(john)
    first:dispatch("phone.send", { to = his, body = "the docks at nine" },
        { actor = jane, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local phone = self.world.services.phone
    lu.assertEquals(phone.number_of(jane), hers)
    lu.assertEquals(phone.holder_of(his), john)
    lu.assertEquals(phone.count(), 1)
    local thread = phone.between(hers, his)
    lu.assertEquals(#thread, 1)
    lu.assertEquals(thread[1].body, "the docks at nine")
    -- and it still sends
    self.world:dispatch("character.select", { character = john }, { account = BOB })
    lu.assertTrue(self.world:dispatch("phone.send", { to = hers, body = "see you there" },
        { actor = john, account = BOB }):succeeded())
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
