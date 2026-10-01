--- The ledger's promise: money moves, it never appears or vanishes.
local modname = ...
local lu = require("luaunit")
local Money = require("domain.money")
local Ledger = require("domain.ledger")

TestLedger = {}

function TestLedger:setUp()
    self.ledger = Ledger.new()
    -- Money enters the simulation across a named external account, so its
    -- arrival is a visible posting rather than a number growing on its own.
    self.ledger:transfer("seed-1", "external:mint", "player:1", Money.of(1000))
    self.ledger:transfer("seed-2", "external:mint", "business:club", Money.of(500))
end

function TestLedger:test_the_sum_of_every_balance_is_always_zero()
    lu.assertEquals(self.ledger:total(), Money.zero)
    self.ledger:transfer("t1", "player:1", "business:club", Money.of(250))
    lu.assertEquals(self.ledger:total(), Money.zero)
    lu.assertEquals(self.ledger:balance("player:1"), Money.of(750))
    lu.assertEquals(self.ledger:balance("business:club"), Money.of(750))
end

function TestLedger:test_an_unbalanced_posting_is_a_programming_error_and_is_loud()
    lu.assertErrorMsgContains("must balance to zero", function()
        self.ledger:post("bad", { { account = "player:1", amount = Money.of(100) } })
    end)
    -- and it changed nothing
    lu.assertEquals(self.ledger:balance("player:1"), Money.of(1000))
    lu.assertEquals(self.ledger:total(), Money.zero)
end

function TestLedger:test_an_account_cannot_spend_what_it_does_not_have()
    local ok, err = self.ledger:transfer("t2", "player:1", "business:club", Money.of(5000))
    lu.assertFalse(ok)
    lu.assertStrContains(err, "player:1")
    -- refused cleanly: no partial effect anywhere
    lu.assertEquals(self.ledger:balance("player:1"), Money.of(1000))
    lu.assertEquals(self.ledger:balance("business:club"), Money.of(500))
    lu.assertEquals(self.ledger:total(), Money.zero)
end

function TestLedger:test_external_accounts_may_go_negative_because_they_are_the_outside_world()
    lu.assertTrue(self.ledger:balance("external:mint"):is_negative())
    lu.assertEquals(self.ledger:balance("external:mint"), Money.of(-1500))
end

function TestLedger:test_the_same_operation_applied_twice_pays_once()
    -- A retried command, a replayed event, a duplicated client request.
    local ok1 = self.ledger:transfer("payout-99", "business:club", "player:1", Money.of(100))
    local ok2, _, info = self.ledger:transfer("payout-99", "business:club", "player:1", Money.of(100))
    lu.assertTrue(ok1)
    lu.assertTrue(ok2)
    lu.assertTrue(info.duplicate)
    lu.assertEquals(self.ledger:balance("player:1"), Money.of(1100))
    lu.assertEquals(self.ledger:balance("business:club"), Money.of(400))
end

function TestLedger:test_a_multi_party_posting_settles_atomically()
    -- A raid settlement: the crew splits the take three ways, out of a stash.
    local shares = Money.of(900):split(3)
    local ok = self.ledger:post("raid-7", {
        { account = "business:club", amount = Money.of(900):negate() },
        { account = "player:1", amount = shares[1] },
        { account = "player:2", amount = shares[2] },
        { account = "player:3", amount = shares[3] },
    }, { incident = "raid-7" })
    lu.assertFalse(ok)  -- the club only holds 500; the whole settlement is refused
    lu.assertEquals(self.ledger:balance("player:2"), Money.zero)
    lu.assertEquals(self.ledger:total(), Money.zero)
end

function TestLedger:test_a_settlement_that_fits_pays_everyone_exactly()
    local shares = Money.of(500):split(3)
    local ok = self.ledger:post("raid-8", {
        { account = "business:club", amount = Money.of(500):negate() },
        { account = "player:1", amount = shares[1] },
        { account = "player:2", amount = shares[2] },
        { account = "player:3", amount = shares[3] },
    })
    lu.assertTrue(ok)
    lu.assertEquals(self.ledger:balance("business:club"), Money.zero)
    local paid = self.ledger:balance("player:1"):add(self.ledger:balance("player:2"))
        :add(self.ledger:balance("player:3"))
    lu.assertEquals(paid, Money.of(1500))   -- 1000 seeded + 500 settled, to the cent
    lu.assertEquals(self.ledger:total(), Money.zero)
end

function TestLedger:test_history_answers_where_the_money_came_from()
    self.ledger:transfer("wages-1", "business:club", "player:1", Money.of(50), { reason = "shift" })
    local history = self.ledger:history("player:1")
    lu.assertEquals(#history, 2)
    lu.assertEquals(history[1].operation_id, "seed-1")
    lu.assertEquals(history[2].operation_id, "wages-1")
    lu.assertEquals(history[2].meta.reason, "shift")
    lu.assertEquals(history[2].amount, Money.of(50))
end

function TestLedger:test_malformed_calls_are_refused_loudly()
    lu.assertError(function() return self.ledger:post("", {}) end)
    lu.assertError(function() return self.ledger:post("x", { { account = "a", amount = 5 } }) end)
    lu.assertError(function()
        return self.ledger:transfer("x", "a", "b", Money.of(-5))
    end)
end

function TestLedger:test_accounts_are_listed_for_audit()
    local accounts = self.ledger:accounts()
    lu.assertEquals(accounts, { "business:club", "external:mint", "player:1" })
end

function TestLedger:test_history_cannot_be_rewritten_by_the_caller()
    local entries = {
        { account = "player:1", amount = Money.of(10):negate() },
        { account = "business:club", amount = Money.of(10) },
    }
    self.ledger:post("tip-1", entries)
    entries[1].amount = Money.of(999999)          -- the caller reuses its table
    entries[2].account = "player:2"
    local history = self.ledger:history("player:1")
    lu.assertEquals(history[#history].amount, Money.of(10):negate())
    lu.assertEquals(self.ledger:balance("player:1"), Money.of(990))
end

function TestLedger:test_the_posting_window_is_bounded_and_hands_over_what_it_drops()
    local archived = {}
    local small = Ledger.new({ history_limit = 3, on_archive = function(removed)
        for _, posting in ipairs(removed) do archived[#archived + 1] = posting end
    end })
    small:transfer("seed", "external:mint", "player:1", Money.of(100))
    for index = 1, 10 do
        small:transfer("pay-" .. index, "player:1", "business:club", Money.of(1))
    end
    lu.assertEquals(small:posting_count(), 3)
    lu.assertEquals(small:archived_count(), 8)
    lu.assertEquals(#archived, 8)
    lu.assertEquals(archived[1].operation_id, "seed")
    -- balances are authoritative and untouched by trimming
    lu.assertEquals(small:balance("player:1"), Money.of(90))
    lu.assertEquals(small:total(), Money.zero)
    -- and sequence numbers keep counting rather than restarting
    lu.assertEquals(small.postings[#small.postings].sequence, 11)
end

function TestLedger:test_an_operation_is_still_only_applied_once_after_trimming()
    local small = Ledger.new({ history_limit = 2 })
    small:transfer("seed", "external:mint", "player:1", Money.of(100))
    for index = 1, 5 do
        small:transfer("pay-" .. index, "player:1", "business:club", Money.of(1))
    end
    local ok, _, info = small:transfer("pay-1", "player:1", "business:club", Money.of(1))
    lu.assertTrue(ok)
    lu.assertTrue(info.duplicate)
    lu.assertEquals(small:balance("player:1"), Money.of(95))
end

function TestLedger:test_the_books_survive_a_restart()
    self.ledger:transfer("wages-1", "business:club", "player:1", Money.of(50), { reason = "shift" })
    local restored = assert(Ledger.deserialize(self.ledger:serialize()))
    lu.assertEquals(restored:balance("player:1"), Money.of(1050))
    lu.assertEquals(restored:balance("business:club"), Money.of(450))
    lu.assertEquals(restored:total(), Money.zero)
    lu.assertEquals(restored:accounts(), self.ledger:accounts())
    local history = restored:history("player:1")
    lu.assertEquals(history[#history].meta.reason, "shift")
    lu.assertEquals(history[#history].amount, Money.of(50))
    -- and a replayed operation still pays once after the restart
    local _, _, info = restored:transfer("wages-1", "business:club", "player:1", Money.of(50))
    lu.assertTrue(info.duplicate)
    lu.assertEquals(restored:balance("player:1"), Money.of(1050))
end

function TestLedger:test_stored_books_that_do_not_balance_are_refused()
    -- Loading these would put money into the world from nowhere, which is the
    -- one thing the ledger exists to prevent.
    local record = self.ledger:serialize()
    record.balances["player:1"] = record.balances["player:1"] + 1
    local loaded, why = Ledger.deserialize(record)
    lu.assertNil(loaded)
    lu.assertStrContains(why, "corrupt")

    local fractional = self.ledger:serialize()
    fractional.balances["player:1"] = 10.5
    lu.assertNil(Ledger.deserialize(fractional))
    lu.assertNil(Ledger.deserialize("not a record"))
end

function TestLedger:test_a_payment_id_cannot_acknowledge_a_different_payment()
    lu.assertTrue(self.ledger:transfer("bound", "player:1", "business:club", Money.of(100)))
    local before = self.ledger:serialize()
    lu.assertFalse(self.ledger:transfer("bound", "player:1", "business:club", Money.of(900)))
    lu.assertFalse(self.ledger:transfer("bound", "player:1", "player:2", Money.of(100)))
    lu.assertEquals(self.ledger:serialize(), before)
end

function TestLedger:test_trimmed_payment_receipts_survive_restart()
    local ledger = Ledger.new({ history_limit = 1 })
    lu.assertTrue(ledger:transfer("old", "external:mint", "player:1", Money.of(100)))
    lu.assertTrue(ledger:transfer("new", "player:1", "business:club", Money.of(20)))
    local restored = assert(Ledger.deserialize(ledger:serialize()))
    local before = restored:serialize()
    lu.assertTrue(restored:transfer("old", "external:mint", "player:1", Money.of(100)))
    lu.assertFalse(restored:transfer("old", "external:mint", "player:1", Money.of(200)))
    lu.assertEquals(restored:serialize(), before)
    local corrupt = ledger:serialize()
    corrupt.fingerprints.new = "different"
    lu.assertNil(Ledger.deserialize(corrupt))
end

function TestLedger:test_valid_json_with_missing_or_invalid_ledger_state_is_refused()
    lu.assertNil(Ledger.deserialize({}))
    local record = self.ledger:serialize()
    record.balances["player:1"] = -100000
    record.balances["external:mint"] = 50000
    lu.assertNil(Ledger.deserialize(record))
    record = self.ledger:serialize()
    record.seen = nil
    lu.assertNil(Ledger.deserialize(record))
    record = self.ledger:serialize()
    record.seen, record.fingerprints = nil, nil
    lu.assertNotNil(Ledger.deserialize(record), "legacy saved books still load")
    record.postings[1].entries[1].amount = 5
    lu.assertNil(Ledger.deserialize(record))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
