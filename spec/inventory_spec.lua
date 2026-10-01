--- Item duplication is the oldest exploit in this genre. The inventory keeps
--- the same promise the ledger keeps about money, so this spec attacks it the
--- same way.
local modname = ...
local lu = require("luaunit")
local Items = require("domain.items")
local Inventory = require("domain.inventory")

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    items:define("burger", { label = "Burger", weight = 250, stack = 6, category = "consumable" })
    items:define("brick", { label = "Gold Brick", weight = 12000, stack = 1, category = "valuable" })
    items:define("pistol", { label = "Pistol", weight = 1200, unique = true, category = "weapon",
                             illegal = true, droppable = false })
    items:define("passport", { label = "Passport", weight = 30, unique = true, category = "document",
                               sellable = false })
    return items
end

TestItems = {}

function TestItems:test_a_catalogue_holds_what_things_are()
    local items = catalogue()
    lu.assertEquals(items:weight("water"), 500)
    lu.assertEquals(items:stack_size("water"), 12)
    lu.assertTrue(items:is_unique("pistol"))
    lu.assertFalse(items:is_unique("water"))
    lu.assertEquals(items:get("pistol").label, "Pistol")
    lu.assertTrue(items:get("pistol").illegal)
    lu.assertFalse(items:get("pistol").droppable)
    lu.assertTrue(items:get("water").droppable)     -- true unless said otherwise
    lu.assertEquals(items:count(), 5)
    lu.assertEquals(items:in_category("consumable"), { "burger", "water" })
end

function TestItems:test_a_nonsense_definition_is_caught_at_load()
    local items = Items.catalogue()
    lu.assertError(function() return items:define("Water", { label = "x" }) end)
    lu.assertError(function() return items:define("water", {}) end)
    lu.assertError(function() return items:define("water", { label = "x", weight = -1 }) end)
    lu.assertError(function() return items:define("water", { label = "x", weight = 1.5 }) end)
    lu.assertError(function() return items:define("water", { label = "x", stack = 0 }) end)
    lu.assertError(function() return items:define("water", { label = "x", category = "spicy" }) end)
    -- unique and stacking are contradictory, and silently picking one is worse
    lu.assertError(function() return items:define("water", { label = "x", unique = true, stack = 4 }) end)
    items:define("water", { label = "Water" })
    lu.assertError(function() return items:define("water", { label = "Water Again" }) end)
end

function TestItems:test_asking_for_an_item_that_does_not_exist_is_loud()
    local items = catalogue()
    lu.assertNil(items:get("moonrock"))
    lu.assertFalse(items:has("moonrock"))
    -- inside the simulation a miss is a typo in the server, not a player action
    lu.assertError(function() return items:require("moonrock") end)
end

TestInventory = {}

function TestInventory:setUp()
    self.tick = 1757500000000
    self.items = catalogue()
    self.inventory = Inventory.new({
        items = self.items,
        clock = function()
            self.tick = self.tick + 1
            return self.tick
        end,
    })
    self.inventory:define_container("chr_a", { slots = 8, weight = 30000 })
    self.inventory:define_container("chr_b", { slots = 8, weight = 30000 })
    self.inventory:define_container("shop:store", {})      -- no limits
    self.inventory:spawn("seed-a", "chr_a", "water", 10)
end

function TestInventory:test_things_go_in_and_can_be_counted()
    lu.assertEquals(self.inventory:count("chr_a", "water"), 10)
    lu.assertEquals(self.inventory:used_weight("chr_a"), 5000)
    lu.assertEquals(self.inventory:used_slots("chr_a"), 1)      -- ten of twelve, one stack
    lu.assertTrue(self.inventory:has("chr_a", "water", 10))
    lu.assertFalse(self.inventory:has("chr_a", "water", 11))
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_stacks_fill_before_new_ones_open()
    self.inventory:spawn("seed-b", "chr_a", "water", 5)
    local contents = self.inventory:contents("chr_a")
    lu.assertEquals(#contents, 2)
    lu.assertEquals(contents[1].count, 12)      -- filled to its limit first
    lu.assertEquals(contents[2].count, 3)
    lu.assertEquals(self.inventory:count("chr_a", "water"), 15)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_moving_changes_where_things_are_not_how_many()
    lu.assertTrue(self.inventory:move("m1", "chr_a", "chr_b", "water", 4))
    lu.assertEquals(self.inventory:count("chr_a", "water"), 6)
    lu.assertEquals(self.inventory:count("chr_b", "water"), 4)
    -- the count in the world is untouched, which is the whole promise
    lu.assertEquals(self.inventory:total("water"), 10)
    lu.assertEquals(self.inventory:issued("water"), 10)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_two_moves_of_one_stack_cannot_both_take_it()
    -- The duplication bug, staged: both callers believe chr_a holds ten.
    local first = self.inventory:move("m1", "chr_a", "chr_b", "water", 10)
    local second, why = self.inventory:move("m2", "chr_a", "shop:store", "water", 10)
    lu.assertTrue(first)
    lu.assertFalse(second)
    lu.assertStrContains(why, "holds 0 of water")
    lu.assertEquals(self.inventory:total("water"), 10)
    lu.assertEquals(self.inventory:count("chr_b", "water"), 10)
    lu.assertEquals(self.inventory:count("shop:store", "water"), 0)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_the_same_move_applied_twice_moves_it_once()
    lu.assertTrue(self.inventory:move("m1", "chr_a", "chr_b", "water", 4))
    local ok, _, info = self.inventory:move("m1", "chr_a", "chr_b", "water", 4)
    lu.assertTrue(ok)
    lu.assertTrue(info.duplicate)
    lu.assertEquals(self.inventory:count("chr_b", "water"), 4)
    lu.assertEquals(self.inventory:total("water"), 10)
end

function TestInventory:test_one_operation_id_cannot_mean_two_different_moves()
    self.inventory:move("m1", "chr_a", "chr_b", "water", 4)
    lu.assertErrorMsgContains("already applied", function()
        return self.inventory:move("m1", "chr_a", "chr_b", "water", 6)
    end)
end

function TestInventory:test_a_refusal_is_not_remembered()
    -- A refusal changed nothing, so its operation id is still free. It was
    -- kept, and the same id sent again with other arguments -- a client told
    -- no, trying again with its token -- raised "already applied" instead of
    -- being answered, which the command door reports as a server failure.
    lu.assertFalse(self.inventory:move("m1", "chr_a", "chr_b", "water", 50))
    lu.assertTrue(self.inventory:move("m1", "chr_a", "chr_b", "water", 4))
    lu.assertFalse(self.inventory:spawn("s1", "chr_b", "brick", 3))          -- 36kg in a 30kg bag
    lu.assertTrue(self.inventory:spawn("s1", "chr_b", "brick", 1))
    lu.assertEquals(self.inventory:count("chr_b", "water"), 4)
    lu.assertEquals(self.inventory:count("chr_b", "brick"), 1)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_a_refusal_tried_again_once_it_would_work_does_the_work()
    -- And the same request again is not answered with the old no.
    lu.assertFalse(self.inventory:destroy("d1", "chr_b", "water", 2))
    self.inventory:move("m1", "chr_a", "chr_b", "water", 2)
    local ok, _, info = self.inventory:destroy("d1", "chr_b", "water", 2)
    lu.assertTrue(ok)
    lu.assertNil(info, "a retry was answered as a duplicate of a refusal")
    lu.assertEquals(self.inventory:count("chr_b", "water"), 0)
    lu.assertEquals(self.inventory:issued("water"), 8)

    self.inventory:spawn("gun", "chr_a", "pistol", 1, { serial = "AF-1129" })
    local gun = self.inventory:contents("chr_a")[2].instance
    lu.assertFalse(self.inventory:move_instance("i1", "chr_a", gun))          -- already there
    lu.assertTrue(self.inventory:move_instance("i1", "chr_b", gun))
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_only_the_most_recent_changes_are_remembered()
    -- The receipts are kept in memory and were never written down, so a
    -- restart forgets them all already; what stops a client's retry is the
    -- receipt the command door keeps. Kept without end, they grew with every
    -- move the city ever made.
    local small = Inventory.new({ items = self.items, applied_limit = 3 })
    small:define_container("a", {})
    for index = 1, 4 do lu.assertTrue(small:spawn("s" .. index, "a", "water", 1)) end
    local ok, _, info = small:spawn("s4", "a", "water", 1)
    lu.assertTrue(ok)
    lu.assertTrue(info ~= nil and info.duplicate, "the newest change was forgotten")
    lu.assertEquals(small:count("a", "water"), 4)

    local again, _, first = small:spawn("s1", "a", "water", 1)
    lu.assertTrue(again)
    lu.assertNil(first, "the oldest change was still remembered")
    lu.assertEquals(small:count("a", "water"), 5)
    local remembered = 0
    for _ in pairs(small._applied) do remembered = remembered + 1 end
    lu.assertEquals(remembered, 3)
    lu.assertTrue(small:verify())
end

function TestInventory:test_a_move_that_does_not_fit_leaves_both_sides_alone()
    -- Thirty kilograms of gold will not go in a bag that holds thirty.
    self.inventory:spawn("gold", "shop:store", "brick", 5)      -- 60kg
    local ok, why = self.inventory:move("m1", "shop:store", "chr_b", "brick", 5)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "cannot carry")
    lu.assertEquals(self.inventory:count("shop:store", "brick"), 5)
    lu.assertEquals(self.inventory:count("chr_b", "brick"), 0)
    lu.assertEquals(self.inventory:used_weight("chr_b"), 0)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_a_move_that_will_not_fit_in_the_slots_is_refused_whole()
    -- Gold never stacks, so five bricks is five slots. The bag has eight, one
    -- of which already holds water.
    self.inventory:spawn("gold", "shop:store", "brick", 20)
    local light = Inventory.new({ items = self.items })
    light:define_container("bag", { slots = 3 })
    light:define_container("pile", {})
    light:spawn("s", "pile", "brick", 5)
    local ok, why = light:move("m1", "pile", "bag", "brick", 5)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "no room")
    lu.assertEquals(light:count("bag", "brick"), 0)
    lu.assertTrue(light:verify())
    -- three of them do fit
    lu.assertTrue(light:move("m2", "pile", "bag", "brick", 3))
    lu.assertEquals(light:used_slots("bag"), 3)
end

function TestInventory:test_moving_to_the_same_container_is_refused()
    local ok, why = self.inventory:move("m1", "chr_a", "chr_a", "water", 1)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "same container")
    lu.assertEquals(self.inventory:count("chr_a", "water"), 10)
end

function TestInventory:test_a_partial_stack_move_splits_and_the_rest_stays()
    self.inventory:spawn("seed-b", "chr_a", "water", 14)       -- 24: two stacks, 12 and 12
    lu.assertTrue(self.inventory:move("m1", "chr_a", "chr_b", "water", 18))
    lu.assertEquals(self.inventory:count("chr_a", "water"), 6)
    lu.assertEquals(self.inventory:count("chr_b", "water"), 18)
    lu.assertEquals(self.inventory:total("water"), 24)
    -- and the destination restacked properly rather than keeping odd fragments
    local contents = self.inventory:contents("chr_b")
    lu.assertEquals(#contents, 2)
    lu.assertEquals(contents[1].count, 12)
    lu.assertEquals(contents[2].count, 6)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_things_only_enter_and_leave_the_world_on_purpose()
    lu.assertEquals(self.inventory:issued("water"), 10)
    lu.assertTrue(self.inventory:destroy("drink", "chr_a", "water", 3, { reason = "drunk" }))
    lu.assertEquals(self.inventory:count("chr_a", "water"), 7)
    lu.assertEquals(self.inventory:issued("water"), 7)
    lu.assertEquals(self.inventory:total("water"), 7)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_you_cannot_destroy_what_is_not_there()
    local ok, why = self.inventory:destroy("d1", "chr_b", "water", 1)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "holds 0 of water")
    lu.assertEquals(self.inventory:issued("water"), 10)
end

function TestInventory:test_a_unique_thing_keeps_its_own_notes()
    self.inventory:spawn("issue", "chr_a", "pistol", 1, { serial = "AF-1129", rounds = 7 })
    local contents = self.inventory:contents("chr_a")
    local gun
    for _, stack in ipairs(contents) do
        if stack.item == "pistol" then gun = stack end
    end
    lu.assertNotNil(gun)
    lu.assertEquals(gun.count, 1)
    lu.assertEquals(gun.meta.serial, "AF-1129")
    lu.assertStrContains(gun.instance, "itm_")

    -- and the notes travel with it
    lu.assertTrue(self.inventory:move("m1", "chr_a", "chr_b", "pistol", 1))
    local moved = self.inventory:contents("chr_b")[1]
    lu.assertEquals(moved.meta.serial, "AF-1129")
    lu.assertEquals(moved.instance, gun.instance)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_unique_things_never_merge_into_one_stack()
    self.inventory:spawn("a", "chr_a", "pistol", 1, { serial = "AA-1" })
    self.inventory:spawn("b", "chr_a", "pistol", 1, { serial = "BB-2" })
    local guns = 0
    for _, stack in ipairs(self.inventory:contents("chr_a")) do
        if stack.item == "pistol" then
            guns = guns + 1
            lu.assertEquals(stack.count, 1)
        end
    end
    lu.assertEquals(guns, 2)
    lu.assertEquals(self.inventory:count("chr_a", "pistol"), 2)
end

function TestInventory:test_a_named_thing_goes_where_it_is_meant_to()
    self.inventory:spawn("a", "chr_a", "pistol", 1, { serial = "AA-1" })
    self.inventory:spawn("b", "chr_a", "pistol", 1, { serial = "BB-2" })
    local wanted
    for _, stack in ipairs(self.inventory:contents("chr_a")) do
        if stack.meta and stack.meta.serial == "BB-2" then wanted = stack.instance end
    end
    lu.assertTrue(self.inventory:move_instance("m1", "chr_b", wanted))
    local moved = self.inventory:contents("chr_b")[1]
    lu.assertEquals(moved.meta.serial, "BB-2")
    -- and the other one stayed
    lu.assertEquals(self.inventory:count("chr_a", "pistol"), 1)
    lu.assertEquals(self.inventory:contents("chr_a")[2].meta.serial, "AA-1")
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_a_named_thing_that_is_nowhere_cannot_be_moved()
    local ok, why = self.inventory:move_instance("m1", "chr_b", "itm_000000000000000000a")
    lu.assertFalse(ok)
    lu.assertStrContains(why, "nothing anywhere")
end

function TestInventory:test_a_nameless_move_does_not_grab_the_first_ordinary_stack()
    -- An ordinary stack has no name of its own. Without a guard, asking to
    -- move a thing called nil matches the first one of those in the world, and
    -- moving "it" takes one unit across and destroys the other nine.
    for _, junk in ipairs({ { nil }, { "" }, { 42 }, { "water" }, { "chr_a" }, { {} } }) do
        local ok, why = self.inventory:move_instance("m" .. tostring(junk[1]), "chr_b", junk[1])
        lu.assertFalse(ok, ("%s should not name a thing"):format(tostring(junk[1])))
        lu.assertStrContains(why, "not the name of a thing")
    end
    lu.assertEquals(self.inventory:count("chr_a", "water"), 10)
    lu.assertEquals(self.inventory:total("water"), 10)
    lu.assertTrue(self.inventory:verify())
end

function TestInventory:test_verify_notices_a_stack_that_is_neither_one_thing_nor_a_count()
    self.inventory._containers["chr_b"].stacks[1] = { item = "water", count = 1, instance = "itm_0a" }
    local ok, problems = self.inventory:verify()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(problems, " | "), "does not stack but carries a name")

    local other = Inventory.new({ items = self.items })
    other:define_container("box", {})
    other._containers.box.stacks[1] = { item = "pistol", count = 3 }
    other._issued.pistol = 3
    local fine, found = other:verify()
    lu.assertFalse(fine)
    local text = table.concat(found, " | ")
    lu.assertStrContains(text, "unique but has a count of 3")
    lu.assertStrContains(text, "no name of its own")
end

function TestInventory:test_finding_a_named_thing_says_where_it_is()
    self.inventory:spawn("a", "chr_a", "passport", 1, { name = "Jane Doe" })
    local instance = self.inventory:contents("chr_a")[2].instance
    local where, stack = self.inventory:find(instance)
    lu.assertEquals(where, "chr_a")
    lu.assertEquals(stack.meta.name, "Jane Doe")
    lu.assertNil(self.inventory:find("itm_000000000000000000a"))
end

function TestInventory:test_space_reads_as_something_an_interface_can_draw()
    local space = self.inventory:space("chr_a")
    lu.assertEquals(space.slots, 8)
    lu.assertEquals(space.slots_used, 1)
    lu.assertEquals(space.slots_free, 7)
    lu.assertEquals(space.weight, 30000)
    lu.assertEquals(space.weight_used, 5000)
    lu.assertEquals(space.weight_free, 25000)
    -- and a container with no limits says so rather than inventing a number
    local shop = self.inventory:space("shop:store")
    lu.assertNil(shop.slots)
    lu.assertNil(shop.weight_free)
end

function TestInventory:test_would_fit_answers_without_changing_anything()
    lu.assertTrue(self.inventory:would_fit("chr_b", "water", 12))
    local ok, why = self.inventory:would_fit("chr_b", "brick", 3)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "cannot carry")
    lu.assertEquals(self.inventory:used_slots("chr_b"), 0)
end

function TestInventory:test_nonsense_calls_are_refused_loudly()
    lu.assertError(function() return self.inventory:move("", "chr_a", "chr_b", "water", 1) end)
    lu.assertError(function() return self.inventory:move("m", "chr_a", "chr_b", "water", 0) end)
    lu.assertError(function() return self.inventory:move("m", "chr_a", "chr_b", "water", 1.5) end)
    lu.assertError(function() return self.inventory:move("m", "chr_a", "chr_b", "moonrock", 1) end)
    lu.assertError(function() return self.inventory:move("m", "chr_a", "nowhere", "water", 1) end)
    lu.assertError(function() return self.inventory:spawn("s", "chr a b", "water", 1) end)
    lu.assertError(function() return self.inventory:define_container("chr_c", { slots = 0 }) end)
    lu.assertError(function() return self.inventory:define_container("chr_c", { weight = -5 }) end)
end

function TestInventory:test_the_log_says_what_happened_to_somebodys_bag()
    self.inventory:move("m1", "chr_a", "chr_b", "water", 2, { reason = "traded" })
    self.inventory:destroy("d1", "chr_b", "water", 1, { reason = "drunk" })
    local log = self.inventory:log()
    lu.assertEquals(#log, 3)
    lu.assertEquals(log[1].action, "spawn")
    lu.assertEquals(log[2].action, "move")
    lu.assertEquals(log[2].reason, "traded")
    lu.assertEquals(log[2].count, 2)
    lu.assertEquals(log[3].action, "destroy")
    lu.assertTrue(log[1].at < log[3].at)
end

function TestInventory:test_verify_notices_a_count_that_came_from_nowhere()
    -- Reach past the verbs on purpose: this is what a duplication bug looks
    -- like from the outside, and the check has to catch it.
    self.inventory._containers["chr_b"].stacks[1] = { item = "water", count = 5 }
    local ok, problems = self.inventory:verify()
    lu.assertFalse(ok)
    lu.assertStrContains(problems[1], "15 in containers but 10 issued")
end

function TestInventory:test_verify_notices_one_thing_in_two_places()
    self.inventory:spawn("a", "chr_a", "pistol", 1, { serial = "AA-1" })
    local instance = self.inventory:contents("chr_a")[2].instance
    self.inventory._containers["chr_b"].stacks[1] = { item = "pistol", count = 1, instance = instance }
    self.inventory._issued.pistol = 2
    local ok, problems = self.inventory:verify()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(problems, " | "), "at once")
end

function TestInventory:test_everything_survives_a_restart()
    self.inventory:spawn("gun", "chr_a", "pistol", 1, { serial = "AF-1129" })
    self.inventory:move("m1", "chr_a", "chr_b", "water", 4)
    local restored = assert(Inventory.deserialize(self.inventory:serialize(), { items = self.items }))
    lu.assertEquals(restored:count("chr_a", "water"), 6)
    lu.assertEquals(restored:count("chr_b", "water"), 4)
    lu.assertEquals(restored:total("water"), 10)
    lu.assertEquals(restored:issued("pistol"), 1)
    lu.assertEquals(restored:space("chr_a").slots, 8)
    lu.assertEquals(restored:contents("chr_a")[2].meta.serial, "AF-1129")
    lu.assertTrue(restored:verify())
    -- and it carries on being an inventory
    lu.assertTrue(restored:move("m2", "chr_b", "chr_a", "water", 4))
end

function TestInventory:test_a_stored_inventory_that_does_not_add_up_is_refused()
    local record = self.inventory:serialize()
    record.issued.water = 999
    local loaded, why = Inventory.deserialize(record, { items = self.items })
    lu.assertNil(loaded)
    lu.assertStrContains(why, "does not add up")

    local unknown = self.inventory:serialize()
    unknown.containers["chr_a"].stacks[1].item = "moonrock"
    lu.assertNil(Inventory.deserialize(unknown, { items = self.items }))
    lu.assertNil(Inventory.deserialize("not a record", { items = self.items }))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
