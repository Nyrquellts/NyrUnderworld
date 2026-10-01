--- Everything persists through this, so it is not allowed to change a value
--- on the way past.
local modname = ...
local lu = require("luaunit")
local json = require("support.json")
local Id = require("domain.id")
local Money = require("domain.money")
local Entity = require("domain.entity")

TestJson = {}

function TestJson:test_an_integer_stays_an_integer()
    -- The whole reason this module exists. A balance of 2,500,000 minor units
    -- that comes back as 2500000.0 fails its own validation on load.
    local decoded = json.decode('{"minor":2500000}')
    lu.assertEquals(decoded.minor, 2500000)
    lu.assertEquals(math.type(decoded.minor), "integer")
    lu.assertEquals(json.encode({ minor = 2500000 }), '{"minor":2500000}')
end

function TestJson:test_a_float_stays_a_float()
    local text = json.encode({ heading = 90.0, pitch = 1.5 })
    local back = json.decode(text)
    lu.assertEquals(math.type(back.heading), "float")
    lu.assertEquals(back.heading, 90.0)
    lu.assertEquals(back.pitch, 1.5)
end

function TestJson:test_awkward_numbers_round_trip_exactly()
    for _, value in ipairs({ 0, -1, 1, 2 ^ 53 - 1, -(2 ^ 53) + 1, 0.1, -0.1, 1e-7, 1.7976931348623157e308 }) do
        local back = json.decode(json.encode({ v = value })).v
        lu.assertEquals(back, value, ("%s did not survive the round trip"):format(tostring(value)))
        lu.assertEquals(math.type(back), math.type(value))
    end
end

function TestJson:test_numbers_too_big_for_an_integer_are_refused_not_rounded()
    local value, why = json.decode('{"n":99999999999999999999}')
    lu.assertNil(value)
    lu.assertStrContains(why, "does not fit")
end

function TestJson:test_keys_are_sorted_so_two_saves_can_be_diffed()
    local text = json.encode({ zebra = 1, apple = 2, mango = 3 })
    lu.assertEquals(text, '{"apple":2,"mango":3,"zebra":1}')
    -- and the same table written twice gives the same bytes
    lu.assertEquals(json.encode({ b = 1, a = 2 }), json.encode({ a = 2, b = 1 }))
end

function TestJson:test_arrays_and_objects_keep_their_shape()
    lu.assertEquals(json.encode({ 1, 2, 3 }), "[1,2,3]")
    lu.assertEquals(json.encode({}), "{}")
    lu.assertEquals(json.decode("[]"), {})
    lu.assertEquals(json.decode('[1,"two",true,null]')[2], "two")
    lu.assertEquals(json.decode('[1,"two",true,null]')[4], json.null)
end

function TestJson:test_a_table_that_is_half_array_becomes_an_object()
    -- Nothing is lost, which is the point; JSON has no such shape.
    local text = json.encode({ "first", name = "crew" })
    local back = json.decode(text)
    lu.assertEquals(back["1"], "first")
    lu.assertEquals(back.name, "crew")
end

function TestJson:test_colliding_keys_are_refused_rather_than_dropped()
    local text, why = json.encode({ [1] = "numeric", ["1"] = "textual", other = true })
    lu.assertNil(text)
    lu.assertStrContains(why, "two keys")
end

function TestJson:test_strings_survive_quotes_newlines_and_unicode()
    local awkward = 'he said "no" \\ then\nleft\tat 3\0 with an emoji and an accent'
    local back = json.decode(json.encode({ note = awkward })).note
    lu.assertEquals(back, awkward)
    lu.assertEquals(json.decode('"\\u00e9"'), "\u{e9}")
    lu.assertStrContains(json.encode({ n = "\0" }), "\\u0000")
end

function TestJson:test_a_character_outside_the_basic_plane_decodes_to_itself()
    -- A surrogate pair is how JSON escapes one character. Decoded half at a
    -- time it became six bytes that are not UTF-8, which utf8.len refuses and a
    -- name check then rejects -- from any file edited or exported elsewhere.
    lu.assertEquals(json.decode('"\\ud83d\\ude00"'), "\u{1F600}")
    lu.assertEquals(utf8.len(json.decode('"a\\ud83d\\ude00b"')), 3)
    for _, lone in ipairs({ '"\\ud83d"', '"\\ude00"', '"\\ud83dx"', '"\\ud83d\\u0041"' }) do
        local value, why = json.decode(lone)
        lu.assertNil(value, lone .. " decoded")
        lu.assertStrContains(why, "surrogate")
    end
end

function TestJson:test_a_number_too_large_to_hold_is_refused_not_infinite()
    for _, huge in ipairs({ "1e999", "-1e999", "[1e400]" }) do
        local value, why = json.decode(huge)
        lu.assertNil(value, huge .. " decoded")
        lu.assertStrContains(why, "too large")
    end
    lu.assertEquals(json.decode("1e2"), 100.0)
end

function TestJson:test_a_key_written_twice_is_refused_rather_than_one_kept()
    -- Last value silently won: a save edited by hand with a balance written
    -- twice loaded one of them and said nothing.
    local value, why = json.decode('{"balance": 100, "balance": 900}')
    lu.assertNil(value)
    lu.assertStrContains(why, "twice")
    lu.assertEquals(json.decode('{"a": {"b": 1}, "b": 2}'), { a = { b = 1 }, b = 2 })
end

function TestJson:test_what_json_cannot_carry_is_refused_loudly()
    local text, why = json.encode({ on_use = function() end })
    lu.assertNil(text)
    lu.assertStrContains(why, "cannot encode a function")
    lu.assertNil(json.encode({ n = 0 / 0 }))
    lu.assertNil(json.encode({ n = math.huge }))
    local cycle = {}
    cycle.self = cycle
    local looped, loop_why = json.encode(cycle)
    lu.assertNil(looped)
    lu.assertStrContains(loop_why, "itself")
end

function TestJson:test_nesting_has_a_limit_in_both_directions()
    local deep = {}
    local node = deep
    for _ = 1, json.MAX_DEPTH + 5 do
        node.child = {}
        node = node.child
    end
    lu.assertNil(json.encode(deep))
    local text = string.rep("[", json.MAX_DEPTH + 5) .. string.rep("]", json.MAX_DEPTH + 5)
    local value, why = json.decode(text)
    lu.assertNil(value)
    lu.assertStrContains(why, "deeper than")
end

function TestJson:test_malformed_input_says_where_it_went_wrong()
    for _, bad in ipairs({
        "", "{", "[1,", '{"a"}', '{"a":}', "{a:1}", '{"a":1,}', "[1 2]",
        "tru", '"unterminated', "1 2", "@", '{"a":1} trailing',
    }) do
        local value, why = json.decode(bad)
        lu.assertNil(value, ("%q should not decode"):format(bad))
        lu.assertIsString(why)
        lu.assertStrContains(why, "offset")
    end
    lu.assertNil(json.decode(42))
end

function TestJson:test_indented_output_is_readable_and_still_decodes()
    local record = { name = "crew", members = { "alice", "bob" }, cash = 1250 }
    local text = json.encode(record, { indent = true })
    lu.assertStrContains(text, "\n")
    lu.assertEquals(json.decode(text), record)
end

function TestJson:test_an_entity_record_survives_the_whole_round_trip()
    -- The integration that matters: a real serialised entity, through JSON,
    -- back into an entity, with money still exact.
    local Shipment = Entity.define("ship", {
        fields = {
            cargo = { type = "string", required = true },
            value = { type = "money", required = true },
            crates = { type = "integer", default = 1 },
            manifest = { type = "table" },
        },
        states = { packed = { "moving" }, moving = { "packed", "seized" }, seized = {} },
        initial = "packed",
    })
    local restore = Entity.set_clock(function() return 1757500000000 end)
    local shipment = assert(Shipment.new({
        cargo = "electronics",
        value = Money.of(12345, 67),
        crates = 9,
        manifest = { { sku = "tv", count = 4 }, { sku = "radio", count = 5 } },
    }))
    shipment:transition("moving")

    local text = json.encode(shipment:serialize())
    lu.assertIsString(text)
    local loaded = assert(Shipment.deserialize(json.decode(text)))
    Entity.set_clock(restore)

    lu.assertEquals(loaded.id, shipment.id)
    lu.assertEquals(loaded.state, "moving")
    lu.assertEquals(loaded:get("value"), Money.of(12345, 67))
    lu.assertEquals(loaded:get("value"):to_minor(), 1234567)
    lu.assertEquals(loaded:get("crates"), 9)
    lu.assertEquals(loaded:get("manifest")[2].sku, "radio")
    lu.assertTrue(shipment:equals(loaded))
    lu.assertTrue(Id.is_a(loaded.id, "ship"))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
