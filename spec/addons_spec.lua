--- What another resource may ask of this city, and what it is told.
---
--- This exists because a framework nobody can call is a product with one
--- customer. Before it there were no exports at all and every event stayed
--- inside the resource, so an addon written against this could not ask it
--- anything and could not be told anything.
local modname = ...
local lu = require("luaunit")
local Addons = require("adapter.addons")
local Money = require("domain.money")

TestAddonRequest = {}

function TestAddonRequest:test_an_addon_asks_the_way_a_key_press_does()
    local name, args, context = Addons.request("me.status", {}, { account = "license:abc" }, "my_addon")
    lu.assertEquals(name, "me.status")
    lu.assertEquals(args, {})
    lu.assertEquals(context.account, "license:abc")
end

TestAddonActing = {}

function TestAddonActing:test_an_addon_cannot_say_who_is_acting()
    -- The one that matters. For a client, who is acting is derived from the
    -- account's session and never taken from what the client sent, and every
    -- other guarantee rests on that: ownership, money and the criminal record
    -- all attach to whoever acted. An addon naming its own actor would be
    -- acting as anybody it could name -- including a member of staff whose id
    -- it read out of `character.list` a moment earlier, since `admin.give`
    -- checks the actor's level and not the caller's.
    local name, why = Addons.request("admin.give",
        { character = "chr_victim", amount = 100000, reason = "because" },
        { account = "license:addon", actor = "chr_a_real_admin" }, "greedy_addon")
    lu.assertNil(name, "an addon named its own actor")
    lu.assertStrContains(why, "actor")
end

function TestAddonActing:test_who_is_acting_is_looked_up_from_the_account()
    local asked = {}
    local context = Addons.acting({ account = "license:abc" }, function(account)
        asked[#asked + 1] = account
        return "chr_1"
    end)
    lu.assertEquals(asked, { "license:abc" })
    lu.assertEquals(context.actor, "chr_1")
end

function TestAddonActing:test_an_account_playing_nobody_is_acting_as_nobody()
    -- Not an error here. The command refuses `not_playing`, which is the right
    -- refusal and the same one a player gets.
    local context = Addons.acting({ account = "license:abc" }, function() return nil end)
    lu.assertNil(context.actor)
end

function TestAddonActing:test_a_call_with_no_account_looks_nothing_up()
    local asked = 0
    local context = Addons.acting({}, function() asked = asked + 1 return "chr_1" end)
    lu.assertEquals(asked, 0, "an account that was never given was looked up anyway")
    lu.assertNil(context.actor)
end

function TestAddonActing:test_a_server_with_no_sessions_does_not_invent_one()
    local context = Addons.acting({ account = "license:abc" }, nil)
    lu.assertNil(context.actor)
end

function TestAddonRequest:test_the_calling_resource_is_stamped_and_not_claimed()
    -- Who called is something FiveM knows and the caller does not choose. An
    -- addon does not get to say it was somebody else, and an owner reading the
    -- log needs to know which one did what.
    local _, _, context = Addons.request("me.status", {}, {}, "shop_extras")
    lu.assertEquals(context.source, "addon:shop_extras")

    local _, _, forged = Addons.request("me.status", {}, { source = "nyr_underworld" }, "shop_extras")
    lu.assertNil(forged, "an addon set its own source")
end

function TestAddonRequest:test_an_addons_operation_ids_are_its_own()
    -- Receipts are durable. Two addons that both numbered their requests from 1
    -- refused each other's first request, and went on refusing it after a
    -- restart; an id that happened to match one the city makes for itself was
    -- refused as already done.
    local _, _, shop = Addons.request("me.status", {}, { account = "license:a", operation_id = "1" }, "shop_extras")
    local _, _, phone = Addons.request("me.status", {}, { account = "license:a", operation_id = "1" }, "phone_extras")
    lu.assertEquals(shop.operation_id, "addon:shop_extras/1")
    lu.assertNotEquals(shop.operation_id, phone.operation_id)
    local _, _, city_like = Addons.request("me.status", {}, { operation_id = "opening:chr_x" }, "a")
    lu.assertNotEquals(city_like.operation_id, "opening:chr_x")
    local _, _, none = Addons.request("me.status", {}, {}, "a")
    lu.assertNil(none.operation_id)
end

function TestAddonRequest:test_a_caller_the_server_cannot_name_is_still_named()
    local _, _, context = Addons.request("me.status", {}, {}, nil)
    lu.assertEquals(context.source, "addon:unknown")
    lu.assertStrContains(context.source, "addon:", "an unnamed caller lost its mark entirely")
end

function TestAddonRequest:test_only_the_context_an_addon_is_allowed_to_set()
    -- Undeclared keys are refused rather than dropped: a caller passing
    -- something this does not understand is a bug or a misunderstanding, and
    -- ignoring it silently means neither is ever noticed.
    for _, key in ipairs({ "now", "player", "priority", "bypass" }) do
        local name, why = Addons.request("me.status", {}, { [key] = "x" }, "a")
        lu.assertNil(name, ("%s was accepted"):format(key))
        lu.assertStrContains(why, key)
    end
end

function TestAddonRequest:test_a_context_field_of_the_wrong_shape_is_refused()
    local name, why = Addons.request("me.status", {}, { account = 7 }, "a")
    lu.assertNil(name)
    lu.assertStrContains(why, "account")
end

function TestAddonRequest:test_something_that_is_not_a_command_is_refused()
    for _, asked in ipairs({ "", "status", "me status", "nyrme" }) do
        local name, why = Addons.request(asked, {}, {}, "a")
        lu.assertNil(name, ("%q was accepted as a command"):format(asked))
        lu.assertIsString(why)
    end
    lu.assertNil(Addons.request(nil, {}, {}, "a"))
    lu.assertNil(Addons.request(42, {}, {}, "a"))
end

function TestAddonRequest:test_arguments_that_are_not_arguments_are_refused()
    lu.assertNil(Addons.request("me.status", "not a table", {}, "a"))
    lu.assertNil(Addons.request("me.status", {}, "not a table", "a"))
    -- Leaving them out entirely is fine: plenty of commands take none.
    local name, args = Addons.request("me.status", nil, nil, "a")
    lu.assertEquals(name, "me.status")
    lu.assertEquals(args, {})
end

TestAddonPayload = {}

function TestAddonPayload:test_plain_facts_cross_unchanged()
    local crossed = Addons.payload({
        place = "prp_1", buyer = "chr_1", price = 250000, first = true,
    })
    lu.assertEquals(crossed, { place = "prp_1", buyer = "chr_1", price = 250000, first = true })
end

function TestAddonPayload:test_money_crosses_as_the_number_it_is_counted_in()
    -- A Money is a table with a metatable, so it would arrive as whatever
    -- fields it happens to have today -- and an addon reading those would break
    -- the day they changed. It crosses as minor units, which is what the ledger
    -- is denominated in and what every other number in a payload already is.
    local crossed = Addons.payload({ wage = Money.of(120), rent = Money.from_minor(5000) })
    lu.assertEquals(crossed.wage, 12000)
    lu.assertEquals(crossed.rent, 5000)
    lu.assertEquals(math.type(crossed.wage), "integer")
end

function TestAddonPayload:test_money_on_its_own_crosses_too()
    lu.assertEquals(Addons.payload(Money.of(7)), 700)
end

function TestAddonPayload:test_what_cannot_cross_is_left_out_rather_than_thrown()
    local crossed = Addons.payload({ ok = "yes", work = function() end })
    lu.assertEquals(crossed.ok, "yes")
    lu.assertNil(crossed.work)
end

function TestAddonPayload:test_a_payload_that_refers_to_itself_does_not_run_forever()
    local loop = { name = "deep" }
    loop.again = loop
    local crossed = Addons.payload(loop)
    lu.assertEquals(crossed.name, "deep")
    -- It stops somewhere. What matters is that it stops.
    local depth, walk = 0, crossed
    while type(walk) == "table" and walk.again ~= nil and depth < 50 do
        walk = walk.again
        depth = depth + 1
    end
    lu.assertTrue(depth < 50, "a payload with a cycle in it was copied without end")
end

function TestAddonPayload:test_nested_facts_survive()
    local crossed = Addons.payload({ shift = { job = "delivery", pay = Money.of(120) } })
    lu.assertEquals(crossed.shift.job, "delivery")
    lu.assertEquals(crossed.shift.pay, 12000)
end

TestAddonAbout = {}

function TestAddonAbout:test_an_addon_is_told_what_it_is_talking_to()
    local about = Addons.about("nyr_underworld", "0.1.0")
    lu.assertEquals(about.resource, "nyr_underworld")
    lu.assertEquals(about.version, "0.1.0")
    lu.assertStrContains(about.ask, "nyr_underworld")
    lu.assertEquals(about.events, "nyr:event")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
