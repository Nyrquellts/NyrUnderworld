--- The bus carries what the simulation says happened. One broken listener is
--- not allowed to stop the city.
local modname = ...
local lu = require("luaunit")
local Events = require("core.events")

TestEvents = {}

function TestEvents:setUp()
    self.tick = 1757500000000
    self.errors = {}
    self.bus = Events.new({
        clock = function()
            self.tick = self.tick + 1
            return self.tick
        end,
        on_error = function(message, event, label)
            self.errors[#self.errors + 1] = { message = message, event = event.name, label = label }
        end,
    })
    self.seen = {}
end

function TestEvents:listener(label)
    return function(payload)
        self.seen[#self.seen + 1] = { label = label, payload = payload }
    end
end

function TestEvents:test_a_listener_hears_what_was_emitted()
    self.bus:on("money.transferred", self:listener("bank"), { label = "bank" })
    local event, ran = self.bus:emit("money.transferred", { amount = 2500, to = "player:1" })
    lu.assertEquals(ran, 1)
    lu.assertEquals(#self.seen, 1)
    lu.assertEquals(self.seen[1].payload.amount, 2500)
    lu.assertEquals(event.name, "money.transferred")
    lu.assertEquals(event.sequence, 1)
    lu.assertEquals(event.at, 1757500000001)
end

function TestEvents:test_a_false_payload_is_carried_as_false()
    -- `payload and deep_copy(payload) or {}` handed every listener an empty
    -- table for an event that said `false`.
    lu.assertEquals(self.bus:build("door.locked", false).payload, false)
    lu.assertEquals(self.bus:build("door.locked", nil).payload, {})
    lu.assertEquals(self.bus:build("door.locked", { by = "chr_a" }).payload, { by = "chr_a" })
    local Outcome = require("core.outcome")
    lu.assertEquals(Outcome.ok(false).value, false, "an answer of no reached the client as nothing")
    lu.assertEquals(Outcome.ok(false):summary().value, false)
    lu.assertNil(Outcome.ok().value)
end

function TestEvents:test_nobody_listening_is_not_a_problem()
    local event, ran, failures = self.bus:emit("money.transferred", { amount = 1 })
    lu.assertEquals(ran, 0)
    lu.assertEquals(failures, {})
    lu.assertEquals(#self.bus:history(), 1)   -- still recorded
    lu.assertEquals(event.payload.amount, 1)
end

function TestEvents:test_higher_priority_runs_first()
    -- A rule that can veto has to see the event before a cosmetic reaction.
    self.bus:on("job.finished", self:listener("hud"), { label = "hud", priority = 0 })
    self.bus:on("job.finished", self:listener("payout"), { label = "payout", priority = 100 })
    self.bus:on("job.finished", self:listener("stats"), { label = "stats", priority = 50 })
    self.bus:emit("job.finished", {})
    lu.assertEquals(self.seen[1].label, "payout")
    lu.assertEquals(self.seen[2].label, "stats")
    lu.assertEquals(self.seen[3].label, "hud")
end

function TestEvents:test_one_broken_listener_does_not_stop_the_others()
    -- The whole reason the bus exists: a notification script erroring must not
    -- stop the bank recording the transfer.
    self.bus:on("money.transferred", function() error("boom") end, { label = "notify", priority = 100 })
    self.bus:on("money.transferred", self:listener("bank"), { label = "bank", priority = 0 })
    local event, ran, failures = self.bus:emit("money.transferred", { amount = 10 })
    lu.assertEquals(ran, 1)
    lu.assertEquals(#failures, 1)
    lu.assertStrContains(failures[1], "notify")
    lu.assertStrContains(failures[1], "boom")
    lu.assertEquals(#self.seen, 1)
    lu.assertEquals(self.seen[1].label, "bank")
    lu.assertEquals(#self.errors, 1)
    lu.assertEquals(self.errors[1].label, "notify")
    lu.assertEquals(event.errors, failures)
    lu.assertEquals(self.bus:errors(), 1)
end

function TestEvents:test_a_listener_can_be_removed()
    local subscription = self.bus:on("money.transferred", self:listener("bank"), { label = "bank" })
    lu.assertEquals(self.bus:count("money.transferred"), 1)
    lu.assertTrue(self.bus:off(subscription))
    lu.assertFalse(self.bus:off(subscription))
    self.bus:emit("money.transferred", {})
    lu.assertEquals(#self.seen, 0)
    lu.assertEquals(self.bus:count(), 0)
    lu.assertEquals(self.bus:names(), {})
end

function TestEvents:test_a_once_listener_hears_one_event()
    self.bus:on("shop.opened", self:listener("tutorial"), { label = "tutorial", once = true })
    self.bus:emit("shop.opened", {})
    self.bus:emit("shop.opened", {})
    lu.assertEquals(#self.seen, 1)
    lu.assertEquals(self.bus:count("shop.opened"), 0)
end

function TestEvents:test_subscribing_during_delivery_does_not_change_this_delivery()
    self.bus:on("job.finished", function()
        self.bus:on("job.finished", self:listener("late"), { label = "late" })
    end, { label = "adder", priority = 100 })
    self.bus:on("job.finished", self:listener("existing"), { label = "existing" })
    self.bus:emit("job.finished", {})
    lu.assertEquals(#self.seen, 1)
    lu.assertEquals(self.seen[1].label, "existing")
    -- but it hears the next one
    self.bus:emit("job.finished", {})
    lu.assertEquals(#self.seen, 3)
end

function TestEvents:test_a_payload_must_be_something_that_can_be_logged()
    lu.assertError(function() return self.bus:emit("job.finished", { on_done = function() end }) end)
    local cycle = {}
    cycle.self = cycle
    lu.assertError(function() return self.bus:emit("job.finished", cycle) end)
end

function TestEvents:test_the_payload_the_emitter_keeps_is_not_the_one_delivered()
    local payload = { amount = 10 }
    self.bus:on("money.transferred", self:listener("bank"), { label = "bank" })
    self.bus:emit("money.transferred", payload)
    payload.amount = 99999
    lu.assertEquals(self.seen[1].payload.amount, 10)
end

function TestEvents:test_event_names_are_namespaced()
    for _, bad in ipairs({ "transferred", "Money.Transferred", "money.", ".transferred",
                           "money..transferred", "money transferred", "", "money.transferred." }) do
        lu.assertFalse(Events.is_name(bad), ("%q should not be an event name"):format(bad))
        lu.assertError(function() return self.bus:emit(bad, {}) end)
    end
    lu.assertTrue(Events.is_name("money.transferred"))
    lu.assertTrue(Events.is_name("vehicle.impound.due"))
end

function TestEvents:test_an_event_that_leads_back_to_itself_is_stopped_and_named()
    self.bus:on("loop.tick", function() self.bus:emit("loop.tick", {}) end, { label = "looper" })
    local _, _, failures = self.bus:emit("loop.tick", {})
    lu.assertEquals(#failures, 1)
    lu.assertStrContains(failures[1], "recursion")
    lu.assertStrContains(failures[1], "loop.tick")
    lu.assertTrue(self.bus:errors() > 0)
end

function TestEvents:test_history_is_bounded_and_newest_last()
    local small = Events.new({ history_limit = 3 })
    for index = 1, 10 do small:emit("tick.happened", { index = index }) end
    local history = small:history()
    lu.assertEquals(#history, 3)
    lu.assertEquals(history[1].payload.index, 8)
    lu.assertEquals(history[3].payload.index, 10)
    lu.assertEquals(#small:history(2), 2)
    small:clear_history()
    lu.assertEquals(#small:history(), 0)
end

function TestEvents:test_build_makes_an_event_without_delivering_it()
    -- What the command bus uses to hold events until its handler has succeeded.
    self.bus:on("money.transferred", self:listener("bank"), { label = "bank" })
    local event = self.bus:build("money.transferred", { amount = 5 })
    lu.assertEquals(#self.seen, 0)
    lu.assertEquals(#self.bus:history(), 0)
    self.bus:publish(event)
    lu.assertEquals(#self.seen, 1)
    lu.assertEquals(#self.bus:history(), 1)
end

-- --------------------------------------------- watching everything at once

TestWatch = {}

function TestWatch:setUp()
    self.bus = Events.new({ clock = function() return 1 end })
end

function TestWatch:test_a_watcher_sees_every_event_whatever_it_is_called()
    -- `on` is for a handler that knows the name it wants. A watcher is for the
    -- things that cannot know: a log, and the surface that hands this city's
    -- events to the rest of the server, which has to work for events written
    -- after it was.
    local seen = {}
    self.bus:watch(function(event) seen[#seen + 1] = event.name end, { label = "spec" })
    self.bus:emit("character.created", { character = "chr_1" })
    self.bus:emit("property.bought", { place = "prp_1" })
    lu.assertEquals(seen, { "character.created", "property.bought" })
end

function TestWatch:test_a_watcher_sees_one_nobody_subscribed_to()
    -- The case that matters: an event with no subscribers returns early, and
    -- if watchers were told inside the delivery loop they would never hear it.
    local seen = 0
    self.bus:watch(function() seen = seen + 1 end)
    self.bus:emit("nobody.listening", {})
    lu.assertEquals(seen, 1)
end

function TestWatch:test_a_watcher_is_given_the_event_as_it_ended_up()
    local held
    self.bus:on("thing.happened", function() error("a subscriber broke") end, { label = "bad" })
    self.bus:watch(function(event) held = event end)
    self.bus:emit("thing.happened", { a = 1 })
    lu.assertEquals(held.name, "thing.happened")
    lu.assertEquals(held.payload.a, 1)
    lu.assertNotNil(held.errors, "a watcher was not told the event had failed a subscriber")
end

function TestWatch:test_a_watcher_that_throws_stops_nothing()
    -- A log, or another resource listening in, has no business breaking the
    -- city. It is counted and reported the way a subscriber is.
    local errors = {}
    local bus = Events.new({ clock = function() return 1 end,
                             on_error = function(message) errors[#errors + 1] = message end })
    local after = 0
    bus:watch(function() error("the listener fell over") end, { label = "bad-watcher" })
    bus:watch(function() after = after + 1 end, { label = "good-watcher" })
    local delivered = select(2, bus:emit("thing.happened", {}))
    lu.assertEquals(after, 1, "one watcher throwing stopped the next")
    lu.assertEquals(delivered, 0)
    lu.assertEquals(#errors, 1)
    lu.assertStrContains(errors[1], "bad-watcher")
    lu.assertEquals(bus:errors(), 1)
end

function TestWatch:test_a_watcher_can_be_taken_off_again()
    local seen = 0
    local watcher = self.bus:watch(function() seen = seen + 1 end)
    self.bus:emit("thing.happened", {})
    lu.assertEquals(self.bus:watching(), 1)
    lu.assertTrue(self.bus:unwatch(watcher))
    self.bus:emit("thing.happened", {})
    lu.assertEquals(seen, 1)
    lu.assertEquals(self.bus:watching(), 0)
    lu.assertFalse(self.bus:unwatch(watcher), "taking the same watcher off twice said it worked")
end

function TestWatch:test_watching_nothing_is_what_a_bus_starts_as()
    lu.assertEquals(self.bus:watching(), 0)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
