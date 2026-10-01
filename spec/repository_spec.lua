--- The repository is the only place a record becomes an entity, so it is the
--- only place that can hand out two of the same thing.
local modname = ...
local lu = require("luaunit")
local Money = require("domain.money")
local Entity = require("domain.entity")
local MemoryStore = require("persistence.memory_store")
local FileStore = require("persistence.file_store")
local Repository = require("persistence.repository")

local ROOT = "run/spec"

local Property = Entity.define("prop", {
    fields = {
        address = { type = "string", required = true, max = 48 },
        price = { type = "money", required = true },
        rooms = { type = "integer", default = 1, min = 1, max = 20 },
    },
    states = { listed = { "owned" }, owned = { "listed", "seized" }, seized = { "listed" } },
    initial = "listed",
})

TestRepository = {}

function TestRepository:setUp()
    self.tick = 1757500000000
    self.restore_clock = Entity.set_clock(function()
        self.tick = self.tick + 1
        return self.tick
    end)
    self.store = MemoryStore.new()
    self.repo = Repository.new(Property, self.store)
    self.house = assert(self.repo:create({ address = "12 Vespucci", price = Money.of(450000), rooms = 4 }))
end

function TestRepository:tearDown()
    Entity.set_clock(self.restore_clock)
end

function TestRepository:test_create_stores_it_so_a_caller_cannot_forget_to_save()
    lu.assertEquals(self.store:count("prop"), 1)
    lu.assertEquals(self.repo:count(), 1)
    lu.assertTrue(self.repo:exists(self.house.id))
end

function TestRepository:test_loading_the_same_id_twice_gives_the_same_object()
    -- Two in-memory copies of one property is the duplication bug wearing a
    -- different hat: both look correct on their own.
    local again = self.repo:load(self.house.id)
    lu.assertIs(again, self.house)
    self.repo:forget(self.house.id)
    local reloaded = self.repo:load(self.house.id)
    lu.assertNotIs(reloaded, self.house)          -- a genuine reload, after forgetting
    lu.assertIs(self.repo:load(self.house.id), reloaded)
    lu.assertTrue(reloaded:equals(self.house))
end

function TestRepository:test_two_objects_cannot_claim_one_id()
    local impostor = assert(Property.new({ address = "elsewhere", price = Money.of(1) },
        { id = self.house.id }))
    local ok, why = self.repo:save(impostor)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "two different objects")
    lu.assertEquals(self.repo:load(self.house.id):get("address"), "12 Vespucci")
end

function TestRepository:test_an_invalid_entity_is_refused_at_save_not_at_load()
    self.house.data.rooms = 99            -- as a bug elsewhere would leave it
    local ok, why = self.repo:save(self.house)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "rooms")
    -- and what is stored is still the last good version
    local stored = self.store:get("prop", self.house.id)
    lu.assertEquals(stored.data.rooms, 4)
end

function TestRepository:test_the_wrong_kind_is_refused()
    local ok, why = self.repo:save({ id = "x", kind = "veh" })
    lu.assertFalse(ok)
    lu.assertStrContains(why, "not an entity")
    lu.assertNil(self.repo:load("veh_000000000000000000a"))
    local bad, reason = self.repo:load("not-an-id")
    lu.assertNil(bad)
    lu.assertStrContains(reason, "not a prop id")
end

function TestRepository:test_loading_something_that_is_not_there_is_not_an_error()
    local missing, why = self.repo:load("prop_000000000000000000a")
    lu.assertNil(missing)
    lu.assertNil(why)
end

function TestRepository:test_delete_removes_it_from_memory_and_from_the_store()
    lu.assertTrue(self.repo:delete(self.house.id))
    lu.assertNil(self.repo:get(self.house.id))
    lu.assertNil(self.repo:load(self.house.id))
    lu.assertEquals(self.repo:count(), 0)
    lu.assertFalse(self.repo:delete(self.house.id))
end

function TestRepository:test_all_returns_them_in_creation_order()
    local second = assert(self.repo:create({ address = "1 Alta", price = Money.of(900000) }))
    local third = assert(self.repo:create({ address = "3 Del Perro", price = Money.of(120000) }))
    local everything, broken = self.repo:all()
    lu.assertEquals(#everything, 3)
    lu.assertEquals(broken, {})
    lu.assertIs(everything[1], self.house)
    lu.assertIs(everything[2], second)
    lu.assertIs(everything[3], third)
end

function TestRepository:test_all_names_what_it_could_not_load_rather_than_skipping_it()
    -- A record written by an older build, or corrupted; a boot that quietly
    -- drops it is worse than one that says which.
    self.store:put("prop", "prop_000000000000000000b", { id = "prop_000000000000000000b",
        kind = "prop", schema = 1, state = "listed", data = { address = "nowhere" }, history = {} })
    local everything, broken = self.repo:all()
    lu.assertEquals(#everything, 1)
    lu.assertEquals(#broken, 1)
    lu.assertStrContains(broken[1], "price is required")
end

function TestRepository:test_where_filters_what_is_live()
    self.repo:create({ address = "1 Alta", price = Money.of(900000) })
    self.repo:create({ address = "3 Del Perro", price = Money.of(120000) })
    local expensive = self.repo:where(function(entity) return entity:get("price") > Money.of(400000) end)
    lu.assertEquals(#expensive, 2)
    lu.assertEquals(expensive[1].id, self.house.id)
end

function TestRepository:test_persist_writes_only_what_changed()
    self.repo:all()
    local before = self.store:writes()
    local ok, written = self.repo:persist()
    lu.assertTrue(ok)
    lu.assertEquals(written, 0)                    -- nothing changed since create
    lu.assertEquals(self.store:writes(), before)

    self.house:set("rooms", 5)
    local ok2, written2 = self.repo:persist()
    lu.assertTrue(ok2)
    lu.assertEquals(written2, 1)
    lu.assertEquals(self.store:get("prop", self.house.id).data.rooms, 5)
end

function TestRepository:test_persist_reports_an_entity_it_will_not_write()
    self.house.data.rooms = 99
    local ok, written, failures = self.repo:persist()
    lu.assertFalse(ok)
    lu.assertEquals(written, 0)
    lu.assertStrContains(failures[1], "rooms")
end

function TestRepository:test_money_is_exact_all_the_way_to_the_store_and_back()
    local odd = assert(self.repo:create({ address = "9 Mirror Park", price = Money.of(333333, 33) }))
    lu.assertEquals(self.store:get("prop", odd.id).data.price, 33333333)
    self.repo:forget(odd.id)
    lu.assertEquals(self.repo:load(odd.id):get("price"), Money.of(333333, 33))
end

-- ------------------------------------------------- and the same over a file

TestRepositoryOnDisk = {}

function TestRepositoryOnDisk:setUp()
    for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
        os.remove(ROOT .. "/prop" .. suffix)
    end
    self.tick = 1757500000000
    self.restore_clock = Entity.set_clock(function()
        self.tick = self.tick + 1
        return self.tick
    end)
end

function TestRepositoryOnDisk:tearDown()
    Entity.set_clock(self.restore_clock)
end

function TestRepositoryOnDisk:test_the_city_is_still_there_after_a_restart()
    local store = FileStore.new({ root = ROOT })
    local repo = Repository.new(Property, store)
    local house = assert(repo:create({ address = "12 Vespucci", price = Money.of(450000), rooms = 4 }))
    house:transition("owned")
    local ok = repo:persist()
    lu.assertTrue(ok)

    -- a whole new process would build these the same way
    local reopened = Repository.new(Property, FileStore.new({ root = ROOT }))
    local loaded = assert(reopened:load(house.id))
    lu.assertEquals(loaded:get("address"), "12 Vespucci")
    lu.assertEquals(loaded:get("price"), Money.of(450000))
    lu.assertEquals(loaded.state, "owned")
    lu.assertEquals(loaded.created_at, house.created_at)
    lu.assertTrue(house:equals(loaded))
    -- the history came with it, so the city remembers what happened to it
    lu.assertEquals(loaded.history[#loaded.history].event, "state")
    lu.assertEquals(loaded.history[#loaded.history].meta.to, "owned")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
