--- Reach is the other half of the duplication problem. The inventory already
--- refuses to create things; this decides who is allowed to touch what, and
--- the answer never comes from the client.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Phone = require("systems.phone")
local FileStore = require("persistence.file_store")
local MemoryStore = require("persistence.memory_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    items:define("brick", { label = "Gold Brick", weight = 12000, stack = 1, category = "valuable" })
    items:define("passport", { label = "Passport", weight = 30, unique = true,
                               category = "document", droppable = false })
    items:define("phone", { label = "Phone", weight = 200, unique = true, category = "tool" })
    return items
end

TestInventorySystem = {}

function TestInventorySystem:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system())
    self.world:install(InventorySystem.system({ items = catalogue(), slots = 6, weight = 20000 }))
    self.inventory = self.world.services.inventory

    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.world:dispatch("character.select", { character = self.jane }, { account = ALICE })

    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world:dispatch("character.select", { character = self.john }, { account = BOB })

    self.inventory:define_container("shop:store", {})
    self.inventory:spawn("stock", "shop:store", "water", 50)
end

function TestInventorySystem:tearDown()
    -- Worlds activate like a stack, so the ones a test made go back first.
    for index = #(self.others or {}), 1, -1 do self.others[index]:deactivate() end
    self.others = nil
    self.world:deactivate()
end

--- A city running at a pace, with one person in it and a stockroom to reach
--- into. The setUp city runs at a rate of one, where a real millisecond and a
--- city millisecond are the same number and a mix-up between them cannot show.
function TestInventorySystem:paced(rate)
    local world = World.new({ rate = rate, start_at = 8 * Clock.MS_PER_HOUR })
    self.others = self.others or {}
    self.others[#self.others + 1] = world
    world:install(Characters.system())
    world:install(InventorySystem.system({ items = catalogue(), slots = 6, weight = 20000 }))
    local jane = world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    world.services.inventory:define_container("shop:store", {})
    world.services.inventory:spawn("stock", "shop:store", "water", 50)
    return world, jane
end

function TestInventorySystem:ask(name, args, account, actor)
    return self.world:dispatch(name, args, { account = account, actor = actor })
end

function TestInventorySystem:test_everybody_gets_pockets_when_they_exist()
    lu.assertTrue(self.inventory:has_container(self.jane))
    lu.assertEquals(self.inventory:space(self.jane).slots, 6)
    lu.assertEquals(self.inventory:space(self.jane).weight, 20000)
end

function TestInventorySystem:test_you_cannot_reach_into_a_shop_you_were_not_let_into()
    -- This is the whole point. Without a grant, the container is not yours to
    -- touch, however close the client says you are standing.
    local outcome = self:ask("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 5 }, ALICE, self.jane)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "out_of_reach")
    lu.assertEquals(self.inventory:count(self.jane, "water"), 0)
    lu.assertEquals(self.inventory:total("water"), 50)
end

function TestInventorySystem:test_a_grant_from_the_server_opens_it_for_one_person()
    self.world.services.reach(self.jane, "shop:store")
    lu.assertTrue(self:ask("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 5 }, ALICE, self.jane):succeeded())
    lu.assertEquals(self.inventory:count(self.jane, "water"), 5)
    lu.assertEquals(self.inventory:count("shop:store", "water"), 45)
    lu.assertEquals(self.inventory:total("water"), 50)

    -- and it opened for her, not for everybody
    local other = self:ask("inventory.move",
        { from = "shop:store", to = self.john, item = "water", count = 5 }, BOB, self.john)
    lu.assertEquals(other.code, "out_of_reach")
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_a_grant_runs_out()
    self.world.services.reach(self.jane, "shop:store", 5000)
    lu.assertTrue(self.world.services.access:may(self.jane, "shop:store"))
    self.world.clock:skip(4999)
    lu.assertTrue(self.world.services.access:may(self.jane, "shop:store"))
    self.world.clock:skip(1)
    lu.assertFalse(self.world.services.access:may(self.jane, "shop:store"))
    lu.assertEquals(self:ask("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 1 }, ALICE, self.jane).code,
        "out_of_reach")
end

function TestInventorySystem:test_reach_lasts_long_enough_to_use_at_the_pace_the_city_ships_at()
    -- config.lua runs the city at sixty city milliseconds to a real one and
    -- ticks once a real second. A grant was thirty thousand city milliseconds,
    -- which at that pace is half a real second: walking into a flat opened the
    -- stash and the next tick shut it again, before anything could be dragged
    -- into it. The same for every boot.
    for _, rate in ipairs({ 1, 60, 600 }) do
        local world, jane = self:paced(rate)
        world.services.reach(jane, "shop:store")
        world:tick(1000)
        local moved = world:dispatch("inventory.move",
            { from = "shop:store", to = jane, item = "water", count = 1 }, { account = ALICE, actor = jane })
        lu.assertTrue(moved:succeeded(), ("at rate %d a grant shut one tick after it opened"):format(rate))

        -- Thirty real seconds, whatever the pace.
        for _ = 1, 28 do world:tick(1000) end
        lu.assertTrue(world.services.access:may(jane, "shop:store"),
            ("at rate %d a grant shut before thirty real seconds"):format(rate))
        world:tick(1000)
        lu.assertFalse(world.services.access:may(jane, "shop:store"),
            ("at rate %d a grant was still open after thirty real seconds"):format(rate))
    end
end

function TestInventorySystem:test_reach_is_open_when_it_is_given_however_slow_the_city_runs()
    -- Real time turned into city time is rounded up. At a pace where thirty
    -- real seconds is less than a city millisecond, rounding down gives a
    -- grant that has already ended at the moment it is made.
    local world, jane = self:paced(0.00001)
    world.services.reach(jane, "shop:store")
    lu.assertTrue(world.services.access:may(jane, "shop:store"), "a grant was shut when it was given")
    world:tick(1000)
    lu.assertTrue(world.services.access:may(jane, "shop:store"), "a grant did not survive one tick")
end

function TestInventorySystem:test_your_own_pockets_need_no_grant()
    lu.assertTrue(self.world.services.access:may(self.jane, self.jane))
    lu.assertFalse(self.world.services.access:may(self.jane, self.john))
    -- so one person cannot reach into another person
    self.inventory:spawn("seed", self.john, "water", 3)
    local theft = self:ask("inventory.move",
        { from = self.john, to = self.jane, item = "water", count = 3 }, ALICE, self.jane)
    lu.assertEquals(theft.code, "out_of_reach")
    lu.assertEquals(self.inventory:count(self.john, "water"), 3)
end

function TestInventorySystem:test_nobody_can_move_anything_without_being_somebody()
    local outcome = self.world:dispatch("inventory.move",
        { from = "shop:store", to = "shop:store", item = "water", count = 1 }, { account = ALICE })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_playing")
end

function TestInventorySystem:test_a_container_or_an_item_that_does_not_exist_is_refused()
    lu.assertEquals(self:ask("inventory.move",
        { from = "shop:nowhere", to = self.jane, item = "water", count = 1 }, ALICE, self.jane).code,
        "no_such_container")
    lu.assertEquals(self:ask("inventory.move",
        { from = "shop:store", to = self.jane, item = "moonrock", count = 1 }, ALICE, self.jane).code,
        "no_such_item")
end

function TestInventorySystem:test_what_does_not_fit_is_refused_and_nothing_moves()
    self.world.services.reach(self.jane, "shop:store")
    self.inventory:spawn("gold", "shop:store", "brick", 4)        -- 48kg, she carries 20
    local outcome = self:ask("inventory.move",
        { from = "shop:store", to = self.jane, item = "brick", count = 4 }, ALICE, self.jane)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "will_not_fit")
    lu.assertEquals(self.inventory:count(self.jane, "brick"), 0)
    lu.assertEquals(self.inventory:count("shop:store", "brick"), 4)
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_dropping_something_throws_it_away_and_says_so()
    -- This said a drop put things on the ground where they still existed. It
    -- moved them into a new container that nothing could ever reach -- nothing
    -- grants reach to one and the adapter does not know where one is -- and
    -- nothing ever removed, so what was dropped was gone for everybody while
    -- its pile stayed in the saved city for good. Thrown away is what it was,
    -- and now it says so, across a named reason.
    self.inventory:spawn("seed", self.jane, "water", 4)
    local containers = #self.inventory:containers()
    local heard
    self.world:on("inventory.dropped", function(payload) heard = payload end, { label = "spec" })
    local outcome = self:ask("inventory.drop", { item = "water", count = 3 }, ALICE, self.jane)
    lu.assertTrue(outcome:succeeded())

    lu.assertEquals(self.inventory:count(self.jane, "water"), 1)
    lu.assertEquals(self.inventory:total("water"), 51)     -- 50 stock and the one she kept
    lu.assertEquals(self.inventory:issued("water"), 51)
    lu.assertEquals(#self.inventory:containers(), containers, "a drop left a container behind")
    lu.assertEquals(heard.actor, self.jane)
    lu.assertEquals(heard.item, "water")
    lu.assertEquals(heard.count, 3)
    local line = self.inventory:log(1)[1]
    lu.assertEquals(line.action, "destroy")
    lu.assertEquals(line.reason, "dropped")
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_a_refused_drop_leaves_nothing_behind()
    -- The pile was made before the drop was checked, so every refused drop
    -- wrote an empty container into the city: one client made thirty-six
    -- thousand of them in ten real minutes.
    self.inventory:spawn("seed", self.jane, "water", 2)
    local before = self.inventory:serialize()
    local outcome = self:ask("inventory.drop", { item = "water", count = 3 }, ALICE, self.jane)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_carrying")
    lu.assertNil(outcome.message:find(self.jane, 1, true), "the refusal named her character id")
    lu.assertEquals(self.inventory:serialize(), before)
end

function TestInventorySystem:test_some_things_are_not_left_lying_about()
    self.inventory:spawn("papers", self.jane, "passport", 1, { name = "Jane Doe" })
    local outcome = self:ask("inventory.drop", { item = "passport", count = 1 }, ALICE, self.jane)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "cannot_drop")
    lu.assertEquals(self.inventory:count(self.jane, "passport"), 1)
end

function TestInventorySystem:test_dropping_what_you_do_not_have_is_refused()
    local outcome = self:ask("inventory.drop", { item = "water", count = 1 }, ALICE, self.jane)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_carrying")
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_using_something_takes_it_out_of_the_world_and_says_so()
    self.inventory:spawn("seed", self.jane, "water", 2)
    local heard
    self.world:on("inventory.used", function(payload) heard = payload end, { label = "spec" })
    lu.assertTrue(self:ask("inventory.use", { item = "water" }, ALICE, self.jane):succeeded())
    lu.assertEquals(self.inventory:count(self.jane, "water"), 1)
    lu.assertEquals(self.inventory:total("water"), 51)
    lu.assertEquals(self.inventory:issued("water"), 51)
    lu.assertEquals(heard.item, "water")
    lu.assertEquals(heard.category, "consumable")
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_only_what_gets_used_up_can_be_used()
    -- Use destroyed whatever it was asked to, and nothing listens for what it
    -- announces: a passport "used" was a document gone that a drop will not
    -- even let go of.
    self.inventory:spawn("papers", self.jane, "passport", 1, { name = "Jane Doe" })
    self.inventory:spawn("gold", self.jane, "brick", 1)
    local heard = 0
    self.world:on("inventory.used", function() heard = heard + 1 end, { label = "spec" })
    for _, item in ipairs({ "passport", "brick" }) do
        local outcome = self:ask("inventory.use", { item = item }, ALICE, self.jane)
        lu.assertTrue(outcome:was_refused(), ("%s was used up"):format(item))
        lu.assertEquals(outcome.code, "cannot_use")
        lu.assertEquals(self.inventory:count(self.jane, item), 1)
    end
    lu.assertEquals(heard, 0)
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_using_a_phone_does_not_cost_you_your_phone()
    -- A phone is handed out once, when somebody is made, and sold nowhere.
    -- "Using" it destroyed it, and phone.send refused that person for good.
    local world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.others = { world }
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Phone.system())
    local jane = world:dispatch("character.create", { first_name = "Jane", last_name = "Doe" },
        { account = ALICE }).value
    local john = world:dispatch("character.create", { first_name = "John", last_name = "Roe" },
        { account = BOB }).value
    lu.assertEquals(world.services.inventory:count(jane, "phone"), 1)

    lu.assertEquals(world:dispatch("inventory.use", { item = "phone" },
        { actor = jane, account = ALICE }).code, "cannot_use")
    lu.assertEquals(world.services.inventory:count(jane, "phone"), 1)
    local number = world:dispatch("phone.number", {}, { actor = john, account = BOB }).value.number
    lu.assertTrue(world:dispatch("phone.send", { to = number, body = "still here" },
        { actor = jane, account = ALICE }):succeeded())
end

function TestInventorySystem:test_somebody_with_no_pockets_is_refused_not_failed()
    -- A missing container throws, and pockets are made in one place. A
    -- character whose pockets were lost got a server error from drop and use
    -- every time, reported as a bug in the error channel.
    self.inventory._containers[self.jane] = nil      -- past the verbs, on purpose
    for _, request in ipairs({
        { "inventory.drop", { item = "water", count = 1 } },
        { "inventory.use", { item = "water" } },
    }) do
        local outcome = self:ask(request[1], request[2], ALICE, self.jane)
        lu.assertTrue(outcome:was_refused(), ("%s answered %s"):format(request[1], tostring(outcome)))
        lu.assertEquals(outcome.code, "not_carrying")
    end
    lu.assertEquals(#self.world:errors(), 0)
end

function TestInventorySystem:test_a_token_used_again_after_a_refusal_is_answered_not_failed()
    -- The bridge hands a client's token through as the operation id. A refused
    -- move was remembered under it, so the same token with other arguments --
    -- somebody told no, trying again with less -- raised inside the handler
    -- and came back `failed`, into the error channel.
    self.world.services.reach(self.jane, "shop:store")
    local token = ALICE .. "/1700000000-7"
    local refused = self:ask2("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 51 }, ALICE, self.jane, token)
    lu.assertTrue(refused:was_refused())
    local retried = self:ask2("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 5 }, ALICE, self.jane, token)
    lu.assertTrue(retried:succeeded(), tostring(retried))
    lu.assertEquals(#self.world:errors(), 0)
    lu.assertEquals(self.inventory:count(self.jane, "water"), 5)
    lu.assertTrue(self.inventory:verify())
end

function TestInventorySystem:test_the_same_request_twice_moves_things_once()
    self.world.services.reach(self.jane, "shop:store")
    local first = self:ask2("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 5 }, ALICE, self.jane, "op-1")
    local second = self:ask2("inventory.move",
        { from = "shop:store", to = self.jane, item = "water", count = 5 }, ALICE, self.jane, "op-1")
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.inventory:count(self.jane, "water"), 5)
    lu.assertEquals(self.inventory:total("water"), 50)
end

function TestInventorySystem:ask2(name, args, account, actor, operation_id)
    return self.world:dispatch(name, args, { account = account, actor = actor, operation_id = operation_id })
end

function TestInventorySystem:test_logging_out_closes_what_you_had_open()
    self.world.services.reach(self.jane, "shop:store")
    lu.assertTrue(self.world.services.access:may(self.jane, "shop:store"))
    self.world:dispatch("character.release", {}, { account = ALICE })
    lu.assertFalse(self.world.services.access:may(self.jane, "shop:store"))
    lu.assertEquals(self.world.services.access:open_for(self.jane), {})
end

function TestInventorySystem:test_a_system_that_needs_characters_says_so()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(InventorySystem.system()) end)
    lu.assertFalse(bare:has("inventory"))
end

TestInventoryRestart = {}

function TestInventoryRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestInventoryRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestInventoryRestart:test_what_people_were_carrying_is_still_there()
    local first = World.new({ store = FileStore.new({ root = ROOT }), rate = 1 })
    first:install(Characters.system())
    first:install(InventorySystem.system({ items = catalogue() }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.services.inventory:spawn("seed", jane, "water", 7)
    first.services.inventory:spawn("papers", jane, "passport", 1, { name = "Jane Doe" })
    lu.assertTrue(first:close())
    lu.assertEquals(first:persisted(), { "inventory" })

    self.world = World.new({ store = FileStore.new({ root = ROOT }) })
    self.world:install(Characters.system())
    self.world:install(InventorySystem.system({ items = catalogue() }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local inventory = self.world.services.inventory
    lu.assertEquals(inventory:count(jane, "water"), 7)
    lu.assertEquals(inventory:total("water"), 7)
    lu.assertEquals(inventory:contents(jane)[2].meta.name, "Jane Doe")
    lu.assertStrContains(inventory:contents(jane)[2].instance, "itm_")
    lu.assertTrue(inventory:verify())
    -- and the service the system handed out still points at the loaded one
    lu.assertTrue(self.world.services.inventory:has_container(jane))
end

function TestInventoryRestart:test_somebody_saved_without_pockets_has_them_after_a_restart()
    -- Characters and the inventory are written to different collections. A
    -- save that landed one and not the other left somebody who exists with
    -- nothing to carry things in, and pockets were only ever made at creation.
    local store = MemoryStore.new()
    local first = World.new({ store = store, rate = 1 })
    first:install(Characters.system())
    first:install(InventorySystem.system({ items = catalogue(), slots = 6, weight = 20000 }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    lu.assertTrue(first:close())
    local record = store:get("world", "inventory")
    record.containers[jane] = nil
    store:put("world", "inventory", record)

    self.world = World.new({ store = store })
    self.world:install(Characters.system())
    self.world:install(InventorySystem.system({ items = catalogue(), slots = 6, weight = 20000 }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems or {}, "; "))
    local inventory = self.world.services.inventory
    lu.assertTrue(inventory:has_container(jane), "somebody who exists has no pockets")
    lu.assertEquals(inventory:space(jane).slots, 6)
    lu.assertEquals(inventory:space(jane).weight, 20000)
    lu.assertTrue(inventory:verify())
end

function TestInventoryRestart:test_a_stored_inventory_that_does_not_add_up_is_reported()
    local store = FileStore.new({ root = ROOT })
    store:put("world", "inventory", { containers = { box = { stacks = { { item = "water", count = 3 } } } },
                                      issued = { water = 99 } })
    self.world = World.new({ store = store })
    self.world:install(Characters.system())
    self.world:install(InventorySystem.system({ items = catalogue() }))
    local ok, problems = self.world:load()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(problems, " | "), "does not add up")
    -- left empty rather than loaded wrong
    lu.assertEquals(self.world.services.inventory:total("water"), 0)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
