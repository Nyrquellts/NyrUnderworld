--- An id has to name one thing forever, say what kind of thing it is, and
--- sort into the order the things were made.
local modname = ...
local lu = require("luaunit")
local Id = require("domain.id")

TestId = {}

function TestId:test_the_shape_is_fixed_and_readable()
    local id = Id.from_parts("veh", 1757500000000, 0, 12345)
    lu.assertStrContains(id, "veh_")
    -- kind, then exactly the declared body width, so a column can be sized
    lu.assertEquals(#id, #"veh_" + Id.BODY_WIDTH)
    lu.assertEquals(Id.kind_of(id), "veh")
end

function TestId:test_parse_returns_what_was_put_in()
    local id = Id.from_parts("chr", 1757500000000, 7, 999)
    local parsed = Id.parse(id)
    lu.assertEquals(parsed.kind, "chr")
    lu.assertEquals(parsed.time_ms, 1757500000000)
    lu.assertEquals(parsed.sequence, 7)
    lu.assertEquals(parsed.random, 999)
end

function TestId:test_lexicographic_order_is_chronological_order()
    -- This is the whole reason for base36 and the fixed widths: an index on
    -- this column, sorted as text, is a timeline.
    local ids = {
        Id.from_parts("veh", 1757500000000, 0, 1),
        Id.from_parts("veh", 1757500000001, 0, 1),
        Id.from_parts("veh", 1757509999999, 0, 1),
        Id.from_parts("veh", 1000, 0, 1),
    }
    table.sort(ids)
    lu.assertEquals(Id.parse(ids[1]).time_ms, 1000)
    lu.assertEquals(Id.parse(ids[2]).time_ms, 1757500000000)
    lu.assertEquals(Id.parse(ids[3]).time_ms, 1757500000001)
    lu.assertEquals(Id.parse(ids[4]).time_ms, 1757509999999)
end

function TestId:test_two_ids_made_in_the_same_millisecond_still_order()
    local now = 1757500000000
    local a = Id.new("veh", { now = now, random = function() return 5 end })
    local b = Id.new("veh", { now = now, random = function() return 5 end })
    lu.assertNotEquals(a, b)
    lu.assertTrue(a < b, "the second id in a millisecond must sort after the first")
    lu.assertEquals(Id.parse(b).sequence, Id.parse(a).sequence + 1)
end

function TestId:test_before_compares_across_kinds()
    local early = Id.from_parts("veh", 1000, 0, 0)
    local late = Id.from_parts("chr", 2000, 0, 0)
    -- plain string order groups by kind; Id.before reads the clock instead
    lu.assertTrue(late < early)
    lu.assertTrue(Id.before(early, late))
    lu.assertFalse(Id.before(late, early))
end

function TestId:test_junk_is_not_an_id()
    -- Each case is wrapped in its own table so the nil case survives the list.
    -- A bare nil in an ipairs list ends the loop early and quietly stops
    -- testing everything after it, which is a green suite that checks nothing.
    local junk = {
        { "" }, { "veh" }, { "veh_" }, { "_abc" }, { "VEH_0000000000000000000" },
        { 42 }, { nil }, { {} }, { true },
        { "veh_tooshort" },
        { "veh_000000000000000000!" },      -- right length, not base36
        { "veh_00000000000000000 0" },      -- a space is not base36 either
        { "veh_0000000000000000000000" },   -- too long
    }
    lu.assertEquals(#junk, 13, "the junk list lost entries; the loop is not testing what it says")
    for index = 1, #junk do
        local value = junk[index][1]
        lu.assertFalse(Id.is_valid(value), ("%s should not be an id"):format(tostring(value)))
    end
end

function TestId:test_a_kind_mismatch_is_caught()
    local vehicle = Id.from_parts("veh", 1000, 0, 0)
    lu.assertTrue(Id.is_a(vehicle, "veh"))
    -- the check that stops a vehicle id being accepted where a property goes
    lu.assertFalse(Id.is_a(vehicle, "prop"))
    lu.assertError(function() return Id.require(vehicle, "prop") end)
    lu.assertEquals(Id.require(vehicle, "veh"), vehicle)
end

function TestId:test_kinds_are_lowercase_and_short()
    lu.assertTrue(Id.is_kind("veh"))
    lu.assertTrue(Id.is_kind("gang2"))
    lu.assertFalse(Id.is_kind("VEH"))       -- case-only differences are a trap
    lu.assertFalse(Id.is_kind("2veh"))      -- must start with a letter
    lu.assertFalse(Id.is_kind("ve_h"))
    lu.assertFalse(Id.is_kind(""))
    lu.assertFalse(Id.is_kind("waytoolongakind"))
    lu.assertError(function() return Id.new("VEH") end)
end

function TestId:test_out_of_range_parts_are_refused()
    lu.assertError(function() return Id.from_parts("veh", -1, 0, 0) end)
    lu.assertError(function() return Id.from_parts("veh", 1.5, 0, 0) end)
    lu.assertError(function() return Id.from_parts("veh", 1000, 0, 36 ^ 6) end)
    lu.assertError(function() return Id.new("veh", { now = 1.5 }) end)
    lu.assertError(function() return Id.new("veh", { random = function() return -1 end }) end)
end

function TestId:test_a_real_id_is_unique_enough_to_use()
    local seen, now = {}, 1757500000000
    for _ = 1, 2000 do
        local id = Id.new("veh", { now = now })
        lu.assertNil(seen[id], "Id.new handed out a duplicate")
        seen[id] = true
    end
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
