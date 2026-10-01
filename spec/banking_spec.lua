--- A transfer command is the fastest way to launder a duplication bug, so
--- every case here, including every one that fails, ends by asserting the
--- books still sum to nothing.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Property = require("systems.property")
local Banking = require("systems.banking")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    return items
end

local function build(world, banking_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Property.system())
    world:install(Banking.system(banking_opts))
    return world
end

TestBanking = {}

function TestBanking:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world.ledger:transfer("stake-a", "external:mint", Characters.wallet(self.jane), Money.of(1000))
    self.world.ledger:transfer("stake-b", "external:mint", Characters.wallet(self.john), Money.of(1000))

    self.branch = self.world.services.banking.branch("Pillbox Hill Branch",
        { x = 150.0, y = -1040.0, z = 29.0, radius = 5.0 })
    self.at = {}
    self.world.services.proximity = function(actor, place) return self.at[actor] == place end
    self.at[self.jane] = self.branch.id
    self.at[self.john] = self.branch.id
end

function TestBanking:tearDown()
    -- The one assertion every case shares: whatever happened, no money was
    -- created and none went missing.
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestBanking:ask(name, args, actor, account, operation_id)
    return self.world:dispatch(name, args,
        { actor = actor or self.jane, account = account or ALICE, operation_id = operation_id })
end

function TestBanking:open(actor, account)
    return self:ask("bank.open", { branch = self.branch.id }, actor, account)
end

function TestBanking:test_a_branch_is_a_place_with_a_door()
    lu.assertEquals(self.branch:get("kind"), "bank")
    lu.assertFalse(self.branch:get("for_sale"))
    lu.assertEquals(self.world.services.property.holder(self.branch.id), Property.COUNCIL)
end

function TestBanking:test_opening_an_account_gives_a_number_a_person_can_read()
    local outcome = self:open()
    lu.assertTrue(outcome:succeeded())
    lu.assertStrMatches(outcome.value.number, "NYR%-%u%d?[%u%d][%u%d][%u%d]%-[%u%d][%u%d][%u%d][%u%d]")
    -- no I and no O: those read as 1 and 0 down a phone
    lu.assertNil(outcome.value.number:find("[IO]"))
    lu.assertEquals(self.world.services.banking.balance_of(
        self.world.services.banking.accounts:load(outcome.value.account)), Money.zero)
end

function TestBanking:test_two_accounts_never_share_a_number()
    local seen = {}
    for index = 1, 40 do
        -- Each one is a different account, so each one has its own rate
        -- bucket. That is the fix this test forced: keyed on the actor alone,
        -- everybody still at the character screen shared one bucket and the
        -- seventh person could not make anybody.
        local who = "license:x" .. index
        local made = self.world:dispatch("character.create",
            { first_name = "Test", last_name = "Case" }, { account = who })
        lu.assertTrue(made:succeeded(), made.message)
        self.at[made.value] = self.branch.id
        local outcome = self:ask("bank.open", { branch = self.branch.id }, made.value, who)
        lu.assertTrue(outcome:succeeded(), outcome.message)
        lu.assertNil(seen[outcome.value.number], "two accounts got the same number")
        seen[outcome.value.number] = true
    end
end

function TestBanking:test_you_have_to_be_at_the_counter()
    self.at[self.jane] = nil
    lu.assertEquals(self:open().code, "too_far")
    self.world.services.proximity = nil
    lu.assertEquals(self:open().code, "no_proximity")
end

function TestBanking:test_somewhere_that_is_not_a_bank_is_not_a_bank()
    local flat = self.world.services.property.build("12 Vespucci", { price = 1, rent = 1 })
    self.at[self.jane] = flat.id
    lu.assertEquals(self:ask("bank.open", { branch = flat.id }).code, "no_such_branch")
end

function TestBanking:test_one_person_one_account()
    lu.assertTrue(self:open():succeeded())
    local second = self:open()
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "too_many_accounts")
end

function TestBanking:test_money_goes_in_and_comes_out()
    self:open()
    lu.assertTrue(self:ask("bank.deposit", { branch = self.branch.id, amount = 60000 }):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(400))
    local account = self.world.services.banking.held_by(self.jane)[1]
    lu.assertEquals(self.world.services.banking.balance_of(account), Money.of(600))

    lu.assertTrue(self:ask("bank.withdraw", { branch = self.branch.id, amount = 25000 }):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(650))
    lu.assertEquals(self.world.services.banking.balance_of(account), Money.of(350))
end

function TestBanking:test_depositing_more_than_you_carry_moves_nothing()
    self:open()
    local outcome = self:ask("bank.deposit", { branch = self.branch.id, amount = 500000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_carrying")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
    local account = self.world.services.banking.held_by(self.jane)[1]
    lu.assertEquals(self.world.services.banking.balance_of(account), Money.zero)
end

function TestBanking:test_withdrawing_more_than_is_there_moves_nothing()
    self:open()
    self:ask("bank.deposit", { branch = self.branch.id, amount = 10000 })
    local outcome = self:ask("bank.withdraw", { branch = self.branch.id, amount = 20000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "insufficient")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(900))
end

function TestBanking:test_an_account_cannot_go_negative_however_it_is_asked()
    self:open()
    for _, amount in ipairs({ 1, 100, 100000000 }) do
        local outcome = self:ask("bank.withdraw", { branch = self.branch.id, amount = amount })
        lu.assertTrue(outcome:was_refused(), tostring(amount))
    end
    local account = self.world.services.banking.held_by(self.jane)[1]
    lu.assertEquals(self.world.services.banking.balance_of(account), Money.zero)
    lu.assertFalse(self.world.services.banking.balance_of(account):is_negative())
end

function TestBanking:test_nonsense_amounts_never_reach_a_handler()
    self:open()
    for _, amount in ipairs({ 0, -100, 1.5, 999999999 }) do
        local outcome = self:ask("bank.deposit", { branch = self.branch.id, amount = amount })
        lu.assertEquals(outcome.code, "bad_args", tostring(amount))
    end
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(1000))
end

-- ------------------------------------------------------------- transfers

function TestBanking:two_accounts()
    local mine = self:open().value
    local theirs = self:open(self.john, BOB).value
    self:ask("bank.deposit", { branch = self.branch.id, amount = 50000 })
    return mine, theirs
end

function TestBanking:test_a_transfer_goes_by_number_and_lands()
    local mine, theirs = self:two_accounts()
    local outcome = self:ask("bank.transfer", { to = theirs.number, amount = 20000, reference = "for the car" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.sent, 20000)
    lu.assertEquals(outcome.value.fee, 0)
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(300))
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.of(200))
end

function TestBanking:test_a_number_nobody_holds_costs_nothing()
    local mine = self:two_accounts()
    local outcome = self:ask("bank.transfer", { to = "NYR-ZZZZ-ZZZZ", amount = 20000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_such_account")
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(500))
end

function TestBanking:test_sending_more_than_you_have_sends_nothing()
    local mine, theirs = self:two_accounts()
    local outcome = self:ask("bank.transfer", { to = theirs.number, amount = 90000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "insufficient")
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(500))
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.zero)
end

function TestBanking:test_sending_to_yourself_is_refused()
    local mine = self:two_accounts()
    lu.assertEquals(self:ask("bank.transfer", { to = mine.number, amount = 100 }).code, "same_account")
end

function TestBanking:test_the_same_transfer_arriving_twice_sends_once()
    local mine, theirs = self:two_accounts()
    local first = self:ask("bank.transfer", { to = theirs.number, amount = 20000 }, nil, nil, "pay-1")
    local second = self:ask("bank.transfer", { to = theirs.number, amount = 20000 }, nil, nil, "pay-1")
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.of(200))
end

function TestBanking:test_a_fee_is_taken_in_the_same_posting_as_the_transfer()
    self.world:deactivate()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }), { fee_percent = 10 })
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.world.ledger:transfer("stake", "external:mint", Characters.wallet(self.jane), Money.of(1000))
    self.branch = self.world.services.banking.branch("Pillbox Hill Branch")
    self.at = { [self.jane] = self.branch.id, [self.john] = self.branch.id }
    self.world.services.proximity = function(actor, place) return self.at[actor] == place end

    local mine, theirs = self:two_accounts()
    local outcome = self:ask("bank.transfer", { to = theirs.number, amount = 20000 })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.fee, 2000)
    lu.assertEquals(outcome.value.sent, 18000)
    -- the sender lost the whole amount, the recipient got the rest, the bank
    -- took the difference, and it was one posting
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(300))
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.of(180))
    lu.assertEquals(self.world.ledger:balance("external:bank"), Money.of(20))
end

function TestBanking:test_a_transfer_that_cannot_pay_takes_no_fee_either()
    self.world:deactivate()
    self.world = build(World.new({ rate = 1 }), { fee_percent = 10 })
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.branch = self.world.services.banking.branch("Pillbox Hill Branch")
    self.at = { [self.jane] = self.branch.id, [self.john] = self.branch.id }
    self.world.services.proximity = function(actor, place) return self.at[actor] == place end
    local _, theirs = self:open().value, self:open(self.john, BOB).value

    local outcome = self:ask("bank.transfer", { to = theirs.number, amount = 5000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(self.world.ledger:balance("external:bank"), Money.zero)
end

function TestBanking:test_a_transfer_goes_on_the_record()
    local _, theirs = self:two_accounts()
    self:ask("bank.transfer", { to = theirs.number, amount = 20000, reference = "rent" })
    local history = self.world.services.recall(self.jane, { kind = "bank.transfer" })
    lu.assertEquals(#history, 1)
    lu.assertEquals(history[1].meta.amount, 20000)
    lu.assertEquals(history[1].meta.reference, "rent")
    -- and it is findable from the other side, which is what following money means
    lu.assertEquals(#self.world.services.recall(self.john, { kind = "bank.transfer" }), 1)
end

function TestBanking:test_two_transfers_in_one_tick_are_both_on_the_record()
    -- The record's id was the two accounts and the time, and city time only
    -- moves on a tick, so a second transfer between the same two accounts in
    -- one tick moved the money and was never written down.
    local _, theirs = self:two_accounts()
    lu.assertTrue(self:ask("bank.transfer", { to = theirs.number, amount = 10000, reference = "first" }):succeeded())
    lu.assertTrue(self:ask("bank.transfer", { to = theirs.number, amount = 20000, reference = "second" }):succeeded())
    local history = self.world.services.recall(self.jane, { kind = "bank.transfer" })
    lu.assertEquals(#history, 2)
    lu.assertEquals(history[1].meta.reference, "second")
    lu.assertEquals(history[2].meta.reference, "first")
end

function TestBanking:test_a_transfer_arriving_twice_is_on_the_record_once()
    local _, theirs = self:two_accounts()
    self:ask("bank.transfer", { to = theirs.number, amount = 10000 }, nil, nil, "pay-1")
    self:ask("bank.transfer", { to = theirs.number, amount = 10000 }, nil, nil, "pay-1")
    lu.assertEquals(#self.world.services.recall(self.jane, { kind = "bank.transfer" }), 1)
end

-- -------------------------------------------------------------- retirement

function TestBanking:test_retiring_somebody_closes_their_account_and_its_money_leaves_with_their_wallet()
    -- Retiring a person emptied their wallet and left their account open with
    -- its balance. Money sent to the number they had handed out still landed,
    -- and nobody could ever take a unit of it out again.
    local mine, theirs = self:two_accounts()
    self:ask("bank.deposit", { branch = self.branch.id, amount = 60000 }, self.john, BOB)
    lu.assertTrue(self.world:dispatch("character.retire", { character = self.john },
        { account = BOB }):succeeded())

    lu.assertEquals(self.world.services.banking.accounts:load(theirs.account).state, "closed")
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.zero)
    -- four hundred from the wallet and six hundred from the account
    lu.assertEquals(self.world.ledger:balance("external:estate"), Money.of(1000))
    lu.assertNil(self.world.services.banking.find_by_number(theirs.number))
    lu.assertEquals(self:ask("bank.transfer", { to = theirs.number, amount = 20000 }).code, "no_such_account")
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(500))
end

function TestBanking:test_a_frozen_account_closes_too_when_its_holder_retires()
    -- A hold is placed against somebody, and a retired person is never played
    -- again, so there is nobody left to hold it against. The money leaves on
    -- the record, the same as an open account's.
    local _, theirs = self:two_accounts()
    self:ask("bank.deposit", { branch = self.branch.id, amount = 30000 }, self.john, BOB)
    lu.assertTrue(self.world.services.banking.freeze(theirs.account, true))
    lu.assertTrue(self.world:dispatch("character.retire", { character = self.john },
        { account = BOB }):succeeded())
    lu.assertEquals(self.world.services.banking.accounts:load(theirs.account).state, "closed")
    lu.assertEquals(self.world.ledger:balance("bank:" .. theirs.account), Money.zero)
    lu.assertEquals(self.world.ledger:balance("external:estate"), Money.of(1000))
end

function TestBanking:test_somebody_else_retiring_leaves_your_account_alone()
    local mine = self:two_accounts()
    lu.assertTrue(self.world:dispatch("character.retire", { character = self.john },
        { account = BOB }):succeeded())
    lu.assertEquals(self.world.services.banking.accounts:load(mine.account).state, "open")
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(500))
end

-- ---------------------------------------------------------------- freezing

function TestBanking:test_a_frozen_account_moves_nothing_either_way()
    local mine, theirs = self:two_accounts()
    lu.assertTrue(self.world.services.banking.freeze(mine.account, true))

    lu.assertEquals(self:ask("bank.withdraw", { branch = self.branch.id, amount = 100 }).code, "frozen")
    lu.assertEquals(self:ask("bank.deposit", { branch = self.branch.id, amount = 100 }).code, "frozen")
    lu.assertEquals(self:ask("bank.transfer", { to = theirs.number, amount = 100 }).code, "frozen")
    -- and nobody can send to it either
    self.world.services.banking.freeze(theirs.account, true)
    self.world.services.banking.freeze(mine.account, false)
    lu.assertEquals(self:ask("bank.transfer", { to = theirs.number, amount = 100 }).code, "recipient_frozen")
    -- what is in it is still in it
    lu.assertEquals(self.world.ledger:balance("bank:" .. mine.account), Money.of(500))
end

function TestBanking:test_freezing_is_not_something_a_player_asks_for()
    for _, name in ipairs(self.world.commands:names()) do
        lu.assertNotStrContains(name, "freeze")
    end
    lu.assertTrue(self.world.services.banking.freeze(self:open().value.account, true))
    lu.assertFalse(self.world.services.banking.freeze("acc_000000000000000000a", true))
end

-- --------------------------------------------------------------- statement

function TestBanking:test_a_statement_is_read_off_the_books()
    local mine, theirs = self:two_accounts()
    self:ask("bank.transfer", { to = theirs.number, amount = 20000, reference = "for the car" })
    self:ask("bank.withdraw", { branch = self.branch.id, amount = 10000 })

    local outcome = self:ask("bank.statement", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.number, mine.number)
    lu.assertEquals(outcome.value.state, "open")
    -- the statement cannot disagree with the balance, because it is the same books
    lu.assertEquals(outcome.value.balance,
        self.world.ledger:balance("bank:" .. mine.account):to_minor())
    lu.assertEquals(#outcome.value.lines, 3)
    lu.assertEquals(outcome.value.lines[1].amount, 50000)      -- the deposit
    lu.assertEquals(outcome.value.lines[1].reason, "deposit")
    lu.assertEquals(outcome.value.lines[2].amount, -20000)     -- the transfer out
    lu.assertEquals(outcome.value.lines[2].reference, "for the car")
    lu.assertEquals(outcome.value.lines[3].amount, -10000)     -- the withdrawal
end

function TestBanking:test_a_statement_is_only_your_own()
    -- There is no field on the command to name somebody else with.
    local described = self.world.commands:describe("bank.statement")
    lu.assertEquals(#described.args, 1)
    lu.assertEquals(described.args[1].name, "limit")
    lu.assertEquals(self:ask("bank.statement", {}, self.john, BOB).code, "no_account")
end

function TestBanking:test_nobody_banks_without_being_somebody()
    local cases = {
        { "bank.open", { branch = self.branch.id } },
        { "bank.deposit", { branch = self.branch.id, amount = 100 } },
        { "bank.withdraw", { branch = self.branch.id, amount = 100 } },
        { "bank.transfer", { to = "NYR-AAAA-AAAA", amount = 100 } },
        { "bank.statement", {} },
    }
    for _, case in ipairs(cases) do
        lu.assertEquals(self.world:dispatch(case[1], case[2], { account = ALICE }).code,
            "not_playing", case[1])
    end
end

function TestBanking:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Banking.system()) end)
    lu.assertError(function() return Banking.system({ fee_percent = 100 }) end)
    lu.assertError(function() return Banking.system({ max_accounts = 0 }) end)
    lu.assertError(function() return Banking.system({ opening_fee = -1 }) end)
end

TestBankingRestart = {}

function TestBankingRestart:setUp()
    for _, name in ipairs({ "world", "chr", "prp", "acc" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestBankingRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestBankingRestart:test_an_account_and_its_number_survive_a_restart()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(jane), Money.of(1000))
    local branch = first.services.banking.branch("Pillbox Hill Branch")
    first.services.proximity = function() return true end
    local opened = first:dispatch("bank.open", { branch = branch.id },
        { actor = jane, account = ALICE }).value
    first:dispatch("bank.deposit", { branch = branch.id, amount = 60000 },
        { actor = jane, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local account = self.world.services.banking.find_by_number(opened.number)
    lu.assertNotNil(account, "the account number index did not come back")
    lu.assertEquals(account.id, opened.account)
    lu.assertEquals(self.world.services.banking.balance_of(account), Money.of(600))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(jane)), Money.of(400))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    -- and it still works
    lu.assertTrue(self.world:dispatch("bank.withdraw", { branch = branch.id, amount = 10000 },
        { actor = jane, account = ALICE }):succeeded())
    lu.assertTrue(self.world:verify())
end

function TestBankingRestart:test_an_account_an_older_build_left_open_at_retirement_is_closed_on_load()
    -- Cities saved before retiring closed anything still have retired people
    -- with open accounts taking transfers.
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local john = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first.ledger:transfer("stake-a", "external:mint", Characters.wallet(jane), Money.of(1000))
    first.ledger:transfer("stake-b", "external:mint", Characters.wallet(john), Money.of(1000))
    local branch = first.services.banking.branch("Pillbox Hill Branch")
    first.services.proximity = function() return true end
    local theirs = first:dispatch("bank.open", { branch = branch.id }, { actor = john, account = BOB }).value
    first:dispatch("bank.deposit", { branch = branch.id, amount = 60000 }, { actor = john, account = BOB })
    first:dispatch("bank.open", { branch = branch.id }, { actor = jane, account = ALICE })
    first:dispatch("bank.deposit", { branch = branch.id, amount = 50000 }, { actor = jane, account = ALICE })
    -- retired the way an older build did it, which touched no account
    local people = first:repository(Characters.Character)
    local person = people:load(john)
    person:transition("retired", { reason = "retired by owner" })
    people:save(person)
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    lu.assertEquals(self.world.services.banking.accounts:load(theirs.account).state, "closed")
    lu.assertEquals(self.world.ledger:balance(Banking.vault(theirs.account)), Money.zero)
    lu.assertEquals(self.world.ledger:balance("external:estate"), Money.of(600))
    lu.assertEquals(self.world:dispatch("bank.transfer", { to = theirs.number, amount = 20000 },
        { actor = jane, account = ALICE }).code, "no_such_account")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
