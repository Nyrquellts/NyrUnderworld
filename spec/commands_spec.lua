--- Commands are the only door into the simulation, so the door is where a
--- lying client gets stopped.
local modname = ...
local lu = require("luaunit")
local Money = require("domain.money")
local Outcome = require("core.outcome")
local Events = require("core.events")
local Commands = require("core.commands")

TestCommands = {}

function TestCommands:setUp()
    self.tick = 1757500000000
    self.failures = {}
    self.events = Events.new({ clock = function() return self.tick end })
    self.bus = Commands.new({
        events = self.events,
        clock = function() return self.tick end,
        services = { bank = { balance = Money.of(1000) } },
        on_error = function(message, name) self.failures[#self.failures + 1] = { message = message, name = name } end,
    })
    self.ran = 0

    self.bus:define("shop.buy", {
        summary = "buy one item from a shop",
        args = {
            item = { type = "string", required = true, max = 32 },
            quantity = { type = "integer", default = 1, min = 1, max = 10 },
            gift_to = { type = "id", kind = "chr" },
        },
        handler = function(ctx, args)
            self.ran = self.ran + 1
            local price = Money.of(100):times(args.quantity)
            if price > ctx.services.bank.balance then
                return ctx.refuse("not_enough_money", "You cannot afford that.", { short = true })
            end
            ctx.services.bank.balance = ctx.services.bank.balance:sub(price)
            ctx.emit("shop.sold", { item = args.item, quantity = args.quantity, actor = ctx.actor })
            return ctx.ok({ paid = price:to_minor() })
        end,
    })
end

function TestCommands:test_a_valid_request_runs_and_announces_what_happened()
    local heard = {}
    self.events:on("shop.sold", function(payload) heard[#heard + 1] = payload end, { label = "log" })
    local outcome = self.bus:dispatch("shop.buy", { item = "water", quantity = 2 }, { actor = "chr_a" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 20000)
    lu.assertEquals(#heard, 1)
    lu.assertEquals(heard[1].item, "water")
    lu.assertEquals(heard[1].actor, "chr_a")
    lu.assertEquals(self.bus.services.bank.balance, Money.of(800))
end

function TestCommands:test_a_default_fills_in_and_an_undeclared_field_is_refused()
    local outcome = self.bus:dispatch("shop.buy", { item = "water" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.paid, 10000)     -- quantity defaulted to 1

    -- The client sends a price it made up. It does not reach the handler.
    local lying = self.bus:dispatch("shop.buy", { item = "water", price = 0 })
    lu.assertTrue(lying:was_refused())
    lu.assertEquals(lying.code, "bad_args")
    lu.assertStrContains(lying.message, "price is not an expected field")
end

function TestCommands:test_arguments_are_checked_before_the_handler_sees_them()
    local cases = {
        { {}, "item is required" },
        { { item = 42 }, "item must be a string" },
        { { item = "water", quantity = 0 }, "quantity must be at least 1" },
        { { item = "water", quantity = 99 }, "quantity must be at most 10" },
        { { item = "water", quantity = 1.5 }, "quantity must be a integer" },
        { { item = "water", gift_to = "veh_000000000000000000a" }, "gift_to must be a chr id" },
        { { item = string.rep("x", 40) }, "item must be at most 32 characters" },
    }
    for _, case in ipairs(cases) do
        local outcome = self.bus:dispatch("shop.buy", case[1])
        lu.assertEquals(outcome.code, "bad_args")
        lu.assertStrContains(outcome.message, case[2])
    end
    lu.assertEquals(self.ran, 0, "no handler should have run")
end

function TestCommands:test_an_unknown_command_is_a_refusal_not_a_crash()
    local outcome = self.bus:dispatch("shop.rob", { item = "water" })
    lu.assertEquals(outcome.code, "unknown_command")
    lu.assertFalse(outcome:is_failure())
end

function TestCommands:test_a_refusal_announces_nothing()
    -- Being short of cash is a normal answer, and no listener may act on a
    -- sale that did not happen.
    self.bus.services.bank.balance = Money.of(50)
    local heard = 0
    self.events:on("shop.sold", function() heard = heard + 1 end, { label = "log" })
    local outcome = self.bus:dispatch("shop.buy", { item = "water" })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_enough_money")
    lu.assertEquals(outcome.message, "You cannot afford that.")
    lu.assertTrue(outcome.details.short)
    lu.assertEquals(heard, 0)
    lu.assertEquals(#self.events:history(), 0)
end

function TestCommands:test_a_broken_handler_announces_nothing_and_reads_as_a_bug()
    self.bus:define("shop.explode", {
        handler = function(ctx)
            ctx.emit("shop.sold", { item = "ghost" })
            error("handler is broken")
        end,
    })
    local heard = 0
    self.events:on("shop.sold", function() heard = heard + 1 end, { label = "log" })
    local outcome = self.bus:dispatch("shop.explode", {})
    lu.assertTrue(outcome:is_failure())
    lu.assertStrContains(outcome.message, "handler is broken")
    lu.assertEquals(heard, 0, "a command that failed must not announce anything")
    lu.assertEquals(#self.failures, 1)
end

function TestCommands:test_a_handler_returning_the_wrong_thing_is_a_bug_not_a_success()
    self.bus:define("shop.sloppy", { handler = function() return "sure" end })
    local outcome = self.bus:dispatch("shop.sloppy", {})
    lu.assertTrue(outcome:is_failure())
    lu.assertStrContains(outcome.message, "instead of an outcome")
end

function TestCommands:test_a_handler_that_returns_nothing_counts_as_done()
    self.bus:define("shop.quiet", { handler = function() end })
    lu.assertTrue(self.bus:dispatch("shop.quiet", {}):succeeded())
end

function TestCommands:test_authorisation_refuses_with_a_code_the_interface_can_use()
    self.bus:define("shop.restock", {
        authorise = function(ctx) return ctx.actor == "chr_boss", "not_the_boss" end,
        handler = function() return Outcome.ok("restocked") end,
    })
    local refused = self.bus:dispatch("shop.restock", {}, { actor = "chr_a" })
    lu.assertTrue(refused:was_refused())
    lu.assertEquals(refused.code, "not_the_boss")
    local allowed = self.bus:dispatch("shop.restock", {}, { actor = "chr_boss" })
    lu.assertTrue(allowed:succeeded())
    lu.assertEquals(allowed.value, "restocked")
end

function TestCommands:test_a_broken_authoriser_fails_closed()
    self.bus:define("shop.audit", {
        authorise = function() error("permissions service is down") end,
        handler = function() return Outcome.ok("saw the books") end,
    })
    local outcome = self.bus:dispatch("shop.audit", {})
    lu.assertTrue(outcome:is_failure())
    lu.assertStrContains(outcome.message, "could not decide")
end

function TestCommands:test_the_same_operation_id_buys_one_bottle_of_water()
    local first = self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "op-1" })
    local second = self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "op-1" })
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.ran, 1)
    lu.assertEquals(self.bus.services.bank.balance, Money.of(900))
    -- and the first caller still holds an outcome that does not claim to be a repeat
    lu.assertNil(first.details.duplicate)
end

function TestCommands:test_a_failed_command_can_be_retried_with_the_same_id()
    -- Nothing applied, so nothing is remembered; a retry has to be free to work.
    local attempts = 0
    self.bus:define("shop.flaky", {
        handler = function()
            attempts = attempts + 1
            if attempts == 1 then error("the database blinked") end
            return Outcome.ok("second time")
        end,
    })
    lu.assertTrue(self.bus:dispatch("shop.flaky", {}, { operation_id = "op-2" }):is_failure())
    local retry = self.bus:dispatch("shop.flaky", {}, { operation_id = "op-2" })
    lu.assertTrue(retry:succeeded())
    lu.assertEquals(retry.value, "second time")
    lu.assertEquals(attempts, 2)
end

function TestCommands:test_a_refused_command_can_be_retried_too()
    self.bus.services.bank.balance = Money.of(50)
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "op-3" }):was_refused())
    self.bus.services.bank.balance = Money.of(1000)
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "op-3" }):succeeded())
end

function TestCommands:test_a_nonsense_operation_id_is_refused()
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "" }).code, "bad_args")
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = 7 }).code, "bad_args")
end

function TestCommands:test_asking_too_often_is_refused_per_actor()
    self.bus:define("shop.shout", { rate = { per_minute = 3 }, handler = function() end })
    for _ = 1, 3 do
        lu.assertTrue(self.bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded())
    end
    lu.assertEquals(self.bus:dispatch("shop.shout", {}, { actor = "chr_a" }).code, "too_fast")
    -- somebody else is unaffected
    lu.assertTrue(self.bus:dispatch("shop.shout", {}, { actor = "chr_b" }):succeeded())
    -- and a minute later the window has moved on
    self.tick = self.tick + 61000
    lu.assertTrue(self.bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded())
end

function TestCommands:test_a_window_left_by_a_clock_that_was_replaced_does_not_stay_shut()
    -- A world that loads a saved city replaces its clock, and real time starts
    -- again from nothing. A stamp from the old clock sits in the new one's
    -- future; kept, it would count against the window until the new clock
    -- caught up with the old one -- an hour's play of refusals after an hour.
    local real = 3600000
    local bus = Commands.new({ clock = function() return 0 end, rate_clock = function() return real end })
    bus:define("shop.shout", { rate = { per_minute = 1 }, handler = function() end })
    lu.assertTrue(bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded())
    lu.assertEquals(bus:dispatch("shop.shout", {}, { actor = "chr_a" }).code, "too_fast")
    real = 0
    lu.assertTrue(bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded(),
        "a stamp from a replaced clock held the window shut")
end

function TestCommands:test_the_rate_clock_decides_the_window_not_the_city_clock()
    local city, real = 0, 0
    local bus = Commands.new({ clock = function() return city end, rate_clock = function() return real end })
    bus:define("shop.shout", { rate = { per_minute = 1 }, handler = function() end })
    lu.assertTrue(bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded())
    city = city + 3600000
    lu.assertEquals(bus:dispatch("shop.shout", {}, { actor = "chr_a" }).code, "too_fast",
        "an hour of city time counted as a real minute")
    real = real + 61000
    lu.assertTrue(bus:dispatch("shop.shout", {}, { actor = "chr_a" }):succeeded())
end

function TestCommands:test_people_with_no_character_yet_do_not_share_a_bucket()
    -- Before somebody has chosen a character there is no actor. Keyed on the
    -- actor alone, every player still at the character screen lands in one
    -- shared bucket, and the seventh person to connect cannot create anybody.
    -- The account is established by the server, so it is safe to key on.
    self.bus:define("account.setup", { rate = { per_minute = 2 }, handler = function() end })
    for _, who in ipairs({ "license:aaa", "license:bbb", "license:ccc" }) do
        for _ = 1, 2 do
            lu.assertTrue(self.bus:dispatch("account.setup", {}, { account = who }):succeeded(), who)
        end
        lu.assertEquals(self.bus:dispatch("account.setup", {}, { account = who }).code, "too_fast", who)
    end
end

function TestCommands:test_a_character_is_still_the_bucket_when_there_is_one()
    -- Two characters on one account get a bucket each, because the acting
    -- character is the more specific answer and is used when it exists.
    self.bus:define("shop.browse", { rate = { per_minute = 1 }, handler = function() end })
    lu.assertTrue(self.bus:dispatch("shop.browse", {},
        { account = "license:aaa", actor = "chr_a" }):succeeded())
    lu.assertTrue(self.bus:dispatch("shop.browse", {},
        { account = "license:aaa", actor = "chr_b" }):succeeded())
    lu.assertEquals(self.bus:dispatch("shop.browse", {},
        { account = "license:aaa", actor = "chr_a" }).code, "too_fast")
end

function TestCommands:test_emitting_with_no_bus_attached_is_caught()
    local lonely = Commands.new({ clock = function() return self.tick end })
    lonely:define("shop.buy", { handler = function(ctx) ctx.emit("shop.sold", {}) end })
    local outcome = lonely:dispatch("shop.buy", {})
    lu.assertTrue(outcome:is_failure())
    lu.assertStrContains(outcome.message, "no event bus")
end

function TestCommands:test_the_audit_says_what_was_asked_for_and_what_came_back()
    self.bus:dispatch("shop.buy", { item = "water" }, { actor = "chr_a", operation_id = "op-9" })
    self.bus:dispatch("shop.buy", {}, { actor = "chr_b" })
    self.bus:dispatch("shop.nothing", {}, { actor = "chr_c" })
    local audit = self.bus:audit()
    lu.assertEquals(#audit, 3)
    lu.assertEquals(audit[1].code, "ok")
    lu.assertEquals(audit[1].actor, "chr_a")
    lu.assertEquals(audit[1].events, 1)
    lu.assertEquals(audit[2].code, "bad_args")
    lu.assertEquals(audit[3].code, "unknown_command")
    lu.assertEquals(#self.bus:audit(1), 1)
end

function TestCommands:test_a_command_describes_itself()
    local described = self.bus:describe("shop.buy")
    lu.assertEquals(described.name, "shop.buy")
    lu.assertEquals(described.summary, "buy one item from a shop")
    lu.assertEquals(described.args[1].name, "gift_to")
    lu.assertEquals(described.args[2].name, "item")
    lu.assertTrue(described.args[2].required)
    lu.assertEquals(described.args[3].default, 1)
    lu.assertNil(self.bus:describe("shop.nothing"))
    lu.assertEquals(self.bus:names(), { "shop.buy" })
end

function TestCommands:test_a_bad_definition_is_caught_at_load()
    lu.assertError(function() return self.bus:define("shop.buy", { handler = function() end }) end)
    lu.assertError(function() return self.bus:define("buy", { handler = function() end }) end)
    lu.assertError(function() return self.bus:define("shop.x", {}) end)
    lu.assertError(function()
        return self.bus:define("shop.y", { args = { n = { type = "colour" } }, handler = function() end })
    end)
    lu.assertError(function()
        return self.bus:define("shop.z", { rate = { per_minute = 0 }, handler = function() end })
    end)
end

function TestCommands:test_the_outcome_summarises_for_a_log_line()
    local outcome = self.bus:dispatch("shop.buy", { item = "water" }, { actor = "chr_a" })
    local summary = outcome:summary()
    lu.assertTrue(summary.ok)
    lu.assertEquals(summary.code, "ok")
    lu.assertEquals(summary.events, { "shop.sold" })
    lu.assertStrContains(tostring(Outcome.refused("not_enough_money", "no")), "not_enough_money")
end

function TestCommands:test_receipts_are_bound_to_arguments_account_actor_and_command()
    local meta = { operation_id = "bound", actor = "chr_a", account = "license:a" }
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, meta).ok)
    lu.assertTrue(self.bus:dispatch("shop.buy", { quantity = 1, item = "water" }, meta).details.duplicate)
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water", quantity = 2 }, meta).code, "operation_conflict")
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water", price = 0 }, meta).code, "bad_args")
    for _, changed in ipairs({
        { operation_id = "bound", actor = "chr_b", account = "license:a" },
        { operation_id = "bound", actor = "chr_a", account = "license:b" },
    }) do
        lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water" }, changed).code, "operation_conflict")
    end
    self.bus:define("shop.other", { args = { item = { type = "string" }, quantity = { type = "integer", default = 1 } },
        handler = function() error("must not run") end })
    lu.assertEquals(self.bus:dispatch("shop.other", { item = "water" }, meta).code, "operation_conflict")
    lu.assertEquals(self.ran, 1)
end

function TestCommands:test_restored_receipts_refuse_delivery_even_when_payment_would_be_a_duplicate()
    local meta = { operation_id = "saved" }
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, meta).ok)
    lu.assertTrue(self.bus:restore(self.bus:serialize()))
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water" }, meta).code, "already_completed")
    lu.assertEquals(self.ran, 1)
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "fresh" }).ok)
    lu.assertFalse(self.bus:restore({ completed = { broken = false } }))
    lu.assertFalse(self.bus:restore({}))
end

-- ---------------------------------------------- receipts are kept, not hoarded
--
-- Every successful client request carries a token. Each kept its whole answer
-- in memory for the life of the server and its receipt in every save for the
-- life of the city: 80,000 requests made a 20 MiB commands record, spent 1.6 s
-- of the server thread on every save, and on MySQL overflowed the packet limit
-- so that the clock, the ledger, ownership and the receipts all stopped saving.

function TestCommands:waving()
    local waved = 0
    self.bus:define("shop.wave", { handler = function(ctx) waved = waved + 1; return ctx.ok() end })
    return function() return waved end
end

function TestCommands:test_remembered_answers_are_a_bounded_cache()
    local waved = self:waving()
    local total = Commands.ANSWERS_KEPT + 50
    for n = 1, total do self.bus:dispatch("shop.wave", {}, { operation_id = "op-" .. n }) end
    lu.assertTrue(self.bus:answers_kept() <= Commands.ANSWERS_KEPT,
        ("%d answers kept"):format(self.bus:answers_kept()))
    lu.assertTrue(self.bus:dispatch("shop.wave", {}, { operation_id = "op-" .. total }).details.duplicate)
    -- An answer let go is still a request that was done: refused, never run.
    lu.assertEquals(self.bus:dispatch("shop.wave", {}, { operation_id = "op-1" }).code, "already_completed")
    lu.assertEquals(waved(), total)
end

function TestCommands:test_a_receipt_is_let_go_once_nobody_would_retry_it()
    local waved = self:waving()
    self.bus:dispatch("shop.wave", {}, { operation_id = "old" })
    self.tick = self.tick + Commands.RECEIPT_KEEP_MS + 1
    self.bus:dispatch("shop.wave", {}, { operation_id = "new" })
    local saved = self.bus:serialize()
    lu.assertNil(saved.completed.old, "a receipt older than any retry was kept")
    lu.assertNotNil(saved.completed.new)
    lu.assertEquals(waved(), 2)
end

function TestCommands:test_a_quiet_city_saves_no_receipt_past_its_day()
    -- Nothing asked for since: the save itself lets the old receipts go.
    self:waving()
    self.bus:dispatch("shop.wave", {}, { operation_id = "old" })
    self.tick = self.tick + Commands.RECEIPT_KEEP_MS + 1
    lu.assertNil(self.bus:serialize().completed.old)
end

function TestCommands:test_a_receipt_read_back_keeps_the_age_it_was_saved_with()
    local waved = self:waving()
    self.bus:dispatch("shop.wave", {}, { operation_id = "aged" })
    local saved = self.bus:serialize()
    self.tick = self.tick + Commands.RECEIPT_KEEP_MS + 1
    local fresh = Commands.new({ events = self.events, clock = function() return self.tick end })
    fresh:define("shop.wave", { handler = function(ctx) waved(); return ctx.ok() end })
    lu.assertTrue(fresh:restore(saved))
    lu.assertNil(fresh:serialize().completed.aged, "a restart made a day-old receipt new again")
end

function TestCommands:test_receipts_are_bounded_however_fast_they_come()
    self:waving()
    local total = Commands.RECEIPTS_KEPT + 10
    for n = 1, total do self.bus:dispatch("shop.wave", {}, { operation_id = "r-" .. n }) end
    local saved = self.bus:serialize()
    local count = 0
    for _ in pairs(saved.completed) do count = count + 1 end
    lu.assertTrue(count <= Commands.RECEIPTS_KEPT, ("%d receipts saved"):format(count))
    lu.assertNotNil(saved.completed["r-" .. total], "the newest receipt was the one let go")
    lu.assertNil(saved.completed["r-1"], "the oldest receipt was kept over a newer one")
end

function TestCommands:test_receipts_restored_keep_their_age_and_old_saves_still_refuse()
    local waved = self:waving()
    self.bus:dispatch("shop.wave", {}, { operation_id = "kept" })
    local saved = self.bus:serialize()
    local fresh = Commands.new({ events = self.events, clock = function() return self.tick end })
    fresh:define("shop.wave", { handler = function(ctx) waved(); return ctx.ok() end })
    lu.assertTrue(fresh:restore(saved))
    lu.assertEquals(fresh:dispatch("shop.wave", {}, { operation_id = "kept" }).code, "already_completed")
    -- A save written before receipts had ages is read as receipts made now.
    lu.assertTrue(fresh:restore({ completed = { legacy = saved.completed.kept }, sequence = 1 }))
    lu.assertEquals(fresh:dispatch("shop.wave", {}, { operation_id = "legacy" }).code, "already_completed")
    self.tick = self.tick + Commands.RECEIPT_KEEP_MS + 1
    fresh:dispatch("shop.wave", {}, { operation_id = "later" })
    lu.assertNil(fresh:serialize().completed.legacy)
end

function TestCommands:test_a_legacy_payment_receipt_blocks_handler_execution()
    self.bus.services.ledger = { seen = { legacy = 1 } }
    lu.assertEquals(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "legacy" }).code, "already_completed")
    lu.assertEquals(self.ran, 0)
end

function TestCommands:test_event_listener_retry_does_not_repeat_the_effect()
    self.events:on("shop.sold", function()
        lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "nested" }).details.duplicate)
    end, { label = "retry" })
    lu.assertTrue(self.bus:dispatch("shop.buy", { item = "water" }, { operation_id = "nested" }).ok)
    lu.assertEquals(self.ran, 1)
    lu.assertEquals(#self.failures, 0)
end

function TestCommands:test_queries_do_not_persist_receipts_or_return_stale_cached_views()
    self.bus:define("shop.view", { read_only = true, handler = function(ctx) return ctx.ok(self.ran) end })
    for index = 1, 100 do
        self.ran = index
        lu.assertEquals(self.bus:dispatch("shop.view", {}, { operation_id = "poll" }).value, index)
    end
    lu.assertEquals(self.bus:serialize(), { completed = {}, completed_at = {}, sequence = 0 })
end

function TestCommands:test_account_scoped_receipts_survive_a_session_actor_change()
    local ran = 0
    self.bus:define("character.select", { receipt_scope = "account", handler = function() ran = ran + 1 end })
    lu.assertTrue(self.bus:dispatch("character.select", {}, { account = "license:a", operation_id = "select" }).ok)
    lu.assertTrue(self.bus:dispatch("character.select", {},
        { account = "license:a", actor = "chr_a", operation_id = "select" }).details.duplicate)
    lu.assertEquals(self.bus:dispatch("character.select", {},
        { account = "license:b", actor = "chr_a", operation_id = "select" }).code, "operation_conflict")
    lu.assertEquals(ran, 1)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
