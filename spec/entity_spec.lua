--- Every persistent thing in the city is one of these, so the base has to be
--- strict about what goes in and honest about what comes out.
local modname = ...
local lu = require("luaunit")
local Id = require("domain.id")
local Money = require("domain.money")
local Entity = require("domain.entity")

-- Defined once, at load: a kind is registered globally, so redefining it in
-- setUp would be a different bug every run.
-- A made-up kind, deliberately not "veh": production kinds belong to the
-- systems that ship, and a fixture squatting on one would collide the day that
-- system is written.
local Vehicle = Entity.define("demo", {
    fields = {
        model = { type = "string", required = true, max = 32 },
        plate = { type = "string", required = true, min = 2, max = 8 },
        owner = { type = "id", kind = "chr" },
        engine = { type = "integer", default = 1000, min = 0, max = 1000 },
        value = { type = "money" },
        colour = { type = "string", enum = { "black", "white", "primary" }, default = "black" },
        mods = { type = "table" },
    },
    states = {
        stored = { "spawned", "impounded" },
        spawned = { "stored", "impounded", "destroyed" },
        impounded = { "stored" },
        destroyed = {},
    },
    initial = "stored",
})

-- A second kind, at a later schema, to exercise migration.
local Note = Entity.define("note", {
    schema = 2,
    fields = { body = { type = "string", required = true } },
    migrate = function(record, from)
        if from ~= 1 then return nil, ("cannot migrate a note from schema %s"):format(tostring(from)) end
        record.data.body = record.data.text
        record.data.text = nil
        record.schema = 2
        return record
    end,
})

local OWNER = Id.from_parts("chr", 1757400000000, 0, 7)

TestEntity = {}

function TestEntity:setUp()
    self.tick = 1757500000000
    self.restore_clock = Entity.set_clock(function() return self.tick end)
    self.car = assert(Vehicle.new({ model = "sultan", plate = "NYR 001", owner = OWNER }))
end

function TestEntity:tearDown()
    Entity.set_clock(self.restore_clock)
end

function TestEntity:test_a_new_entity_knows_what_and_when_it_is()
    lu.assertTrue(Id.is_a(self.car.id, "demo"))
    lu.assertEquals(self.car.kind, "demo")
    lu.assertEquals(self.car.state, "stored")
    lu.assertEquals(self.car.created_at, 1757500000000)
    lu.assertEquals(self.car.updated_at, self.car.created_at)
    lu.assertTrue(Entity.is(self.car))
    lu.assertTrue(self.car:validate())
end

function TestEntity:test_defaults_fill_in_and_absent_optionals_stay_absent()
    lu.assertEquals(self.car:get("engine"), 1000)
    lu.assertEquals(self.car:get("colour"), "black")
    lu.assertNil(self.car:get("value"))
end

function TestEntity:test_a_missing_required_field_is_refused()
    local car, err = Vehicle.new({ model = "sultan" })
    lu.assertNil(car)
    lu.assertStrContains(err, "plate is required")
end

function TestEntity:test_an_unknown_field_is_refused_rather_than_ignored()
    -- Ignoring this is how a client sets something the server never exposed.
    local car, err = Vehicle.new({ model = "sultan", plate = "NYR 002", godmode = true })
    lu.assertNil(car)
    lu.assertStrContains(err, "godmode is not a field")
    local ok, why = self.car:set("godmode", true)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "not a field")
end

function TestEntity:test_field_rules_are_enforced_on_the_way_in()
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "X" }))                      -- too short
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 0001 TOO LONG" }))      -- too long
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 003", engine = 2000 })) -- above max
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 003", engine = 1.5 }))  -- not an integer
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 003", colour = "gold" }))
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 003", owner = "chr_nope" }))
    -- a vehicle id where a character id belongs
    lu.assertNil(Vehicle.new({ model = "sultan", plate = "NYR 003", owner = self.car.id }))
end

function TestEntity:test_a_table_field_must_be_something_a_database_can_hold()
    local ok = self.car:set("mods", { turbo = true, wheels = { "sport", "chrome" } })
    lu.assertTrue(ok)
    local bad, why = self.car:set("mods", { on_spawn = function() end })
    lu.assertFalse(bad)
    lu.assertStrContains(why, "does not persist")
    local cycle = {}
    cycle.self = cycle
    local looped, loop_why = self.car:set("mods", cycle)
    lu.assertFalse(looped)
    lu.assertStrContains(loop_why, "cycle")
end

function TestEntity:test_a_table_field_is_copied_not_captured()
    local mods = { turbo = true }
    self.car:set("mods", mods)
    mods.turbo = false                      -- the caller keeps mutating its own table
    lu.assertTrue(self.car:get("mods").turbo)
end

function TestEntity:test_the_lifecycle_graph_is_the_rule()
    lu.assertTrue(self.car:can_transition("spawned"))
    lu.assertTrue(self.car:transition("spawned"))
    lu.assertEquals(self.car.state, "spawned")

    lu.assertTrue(self.car:transition("destroyed", { reason = "collision" }))
    -- destroyed is terminal: nothing comes back from it
    local ok, why = self.car:transition("spawned")
    lu.assertFalse(ok)
    lu.assertStrContains(why, "cannot go from destroyed to spawned")
end

function TestEntity:test_nonsense_transitions_are_refused()
    local unknown, why = self.car:transition("teleported")
    lu.assertFalse(unknown)
    lu.assertStrContains(why, "not a state")
    local same, same_why = self.car:transition("stored")
    lu.assertFalse(same)
    lu.assertStrContains(same_why, "already stored")
    -- stored cannot reach destroyed without passing through spawned
    lu.assertFalse(self.car:transition("destroyed"))
end

function TestEntity:test_changes_are_timestamped_and_remembered()
    self.tick = 1757500009999
    self.car:transition("spawned", { reason = "player asked" })
    lu.assertEquals(self.car.updated_at, 1757500009999)
    local last = self.car.history[#self.car.history]
    lu.assertEquals(last.event, "state")
    lu.assertEquals(last.meta.from, "stored")
    lu.assertEquals(last.meta.to, "spawned")
    lu.assertEquals(last.meta.reason, "player asked")
    lu.assertEquals(self.car.history[1].event, "created")
end

function TestEntity:test_history_is_capped_and_says_what_it_dropped()
    for index = 1, 100 do
        self.car:record("tick", { index = index })
    end
    lu.assertEquals(#self.car.history, Entity.HISTORY_LIMIT)
    lu.assertEquals(self.car.history_dropped, 101 - Entity.HISTORY_LIMIT)
    -- the newest entry is kept, the oldest went
    lu.assertEquals(self.car.history[#self.car.history].meta.index, 100)
end

function TestEntity:test_patch_is_all_or_nothing()
    local ok, why = self.car:patch({ model = "banshee", engine = 99999 })
    lu.assertFalse(ok)
    lu.assertStrContains(why, "engine")
    lu.assertEquals(self.car:get("model"), "sultan")   -- the good half did not land
    lu.assertTrue(self.car:patch({ model = "banshee", engine = 800 }))
    lu.assertEquals(self.car:get("model"), "banshee")
    lu.assertEquals(self.car:get("engine"), 800)
end

function TestEntity:test_patch_cannot_clear_a_field_and_says_so()
    -- { owner = nil } is a table with no keys at all, so a patch asking for it
    -- silently does nothing. That has cost real time before; set says what it
    -- means and is checked.
    lu.assertEquals(self.car:get("owner"), OWNER)
    lu.assertTrue(self.car:patch({ owner = nil }))
    lu.assertEquals(self.car:get("owner"), OWNER)
    lu.assertTrue(self.car:set("owner", nil))
    lu.assertNil(self.car:get("owner"))
    -- and clearing something required is still refused
    local ok, why = self.car:set("plate", nil)
    lu.assertFalse(ok)
    lu.assertStrContains(why, "plate is required")
end

function TestEntity:test_money_persists_as_integer_minor_units()
    self.car:set("value", Money.of(25000))
    local record = self.car:serialize()
    lu.assertEquals(record.data.value, 2500000)
    lu.assertEquals(math.type(record.data.value), "integer")
    local restored = Vehicle.deserialize(record)
    lu.assertTrue(Money.is(restored:get("value")))
    lu.assertEquals(restored:get("value"), Money.of(25000))
end

function TestEntity:test_serialise_then_load_gives_back_the_same_thing()
    self.car:set("value", Money.of(25000, 50))
    self.car:set("mods", { turbo = true, wheels = { "sport" } })
    self.car:transition("spawned")
    local record = self.car:serialize()
    local restored = assert(Vehicle.deserialize(record))
    lu.assertTrue(self.car:equals(restored))
    lu.assertTrue(Entity.deep_equal(record, restored:serialize()))
    lu.assertEquals(restored.id, self.car.id)
    lu.assertEquals(restored.state, "spawned")
    lu.assertEquals(restored.history_dropped, 0)
end

function TestEntity:test_a_serialised_record_is_plain_data()
    local record = self.car:serialize()
    lu.assertNil(getmetatable(record))
    lu.assertNil(getmetatable(record.data))
    for _, value in pairs(record.data) do
        lu.assertNotEquals(type(value), "function")
    end
end

function TestEntity:test_the_loader_refuses_a_corrupt_record()
    local record = self.car:serialize()
    record.state = "airborne"
    lu.assertNil(Vehicle.deserialize(record))

    record = self.car:serialize()
    record.data.engine = 5000
    lu.assertNil(Vehicle.deserialize(record))

    record = self.car:serialize()
    record.data.smuggled = true
    lu.assertNil(Vehicle.deserialize(record))

    record = self.car:serialize()
    record.id = Id.from_parts("prop", 1000, 0, 0)
    lu.assertNil(Vehicle.deserialize(record))

    record = self.car:serialize()
    record.data.plate = nil
    local loaded, why = Vehicle.deserialize(record)
    lu.assertNil(loaded)
    lu.assertStrContains(why, "plate is required")
end

function TestEntity:test_a_record_from_an_older_build_is_migrated_not_guessed()
    local old = { id = Id.from_parts("note", 1000, 0, 0), kind = "note", schema = 1,
                  created_at = 1000, updated_at = 1000, data = { text = "meet at the docks" }, history = {} }
    local note = assert(Note.deserialize(old))
    lu.assertEquals(note:get("body"), "meet at the docks")
    -- a kind with no declared lifecycle still has a state, so every record has
    -- the same shape and every debug line prints
    lu.assertEquals(note.state, "active")
    lu.assertStrContains(tostring(note), "active")
    lu.assertFalse(note:transition("archived"))

    -- and a schema with no path forward is refused rather than half-read
    local future = { id = Id.from_parts("note", 1000, 0, 0), kind = "note", schema = 9,
                     created_at = 1000, updated_at = 1000, data = { body = "x" }, history = {} }
    local loaded, why = Note.deserialize(future)
    lu.assertNil(loaded)
    lu.assertStrContains(why, "cannot migrate")
end

function TestEntity:test_a_field_added_later_falls_back_to_its_default()
    -- Adding an optional field with a default must not need a migration, or
    -- every small addition becomes a schema bump and a rewrite of every row.
    local record = self.car:serialize()
    record.data.engine = nil
    record.data.colour = nil
    local loaded = assert(Vehicle.deserialize(record))
    lu.assertEquals(loaded:get("engine"), 1000)
    lu.assertEquals(loaded:get("colour"), "black")
    lu.assertTrue(loaded:validate())
    -- but a field with no default stays absent, and is still refused if it
    -- was required
    record = self.car:serialize()
    record.data.owner = nil
    lu.assertNil(assert(Vehicle.deserialize(record)):get("owner"))
end

function TestEntity:test_anything_can_be_loaded_when_the_kind_is_only_known_at_runtime()
    local record = self.car:serialize()
    local loaded = assert(Entity.deserialize(record))
    lu.assertEquals(loaded.kind, "demo")
    local nothing, why = Entity.deserialize({ kind = "dragon", data = {} })
    lu.assertNil(nothing)
    lu.assertStrContains(why, "no entity kind dragon")
    lu.assertEquals(Entity.of("demo"), Vehicle)
end

function TestEntity:test_it_prints_as_something_readable()
    local text = tostring(self.car)
    lu.assertStrContains(text, "<demo ")
    lu.assertStrContains(text, self.car.id)
    lu.assertStrContains(text, "stored")
    lu.assertStrContains(text, "model=sultan")
end

function TestEntity:test_a_bad_definition_is_caught_at_load_not_at_runtime()
    lu.assertError(function() return Entity.define("demo", { fields = {} }) end)          -- already defined
    lu.assertError(function() return Entity.define("Veh", { fields = {} }) end)          -- not an id kind
    lu.assertError(function()
        return Entity.define("badone", { fields = { x = { type = "colour" } } })
    end)
    lu.assertError(function()
        return Entity.define("badtwo", {
            fields = { x = { type = "string" } },
            states = { a = { "nowhere" } }, initial = "a",
        })
    end)
    lu.assertError(function()
        return Entity.define("badthree", { fields = { x = { type = "integer", default = "no" } } })
    end)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
