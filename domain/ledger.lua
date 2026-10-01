--- Double-entry accounts, so money cannot be created by accident.
--
-- "No accidental money creation" and "no accidental money deletion" are not
-- properties you can test for after the fact across a hundred scripts that
-- each add and subtract balances. They have to be structural.
--
-- So there is one rule here and everything else follows from it:
--
--     every posting's entries sum to zero.
--
-- Money never appears or vanishes; it only moves. A payout is not "give the
-- player 500", it is "move 500 from the business account to the player
-- account". If money genuinely must enter or leave the simulation -- an
-- admin grant, a sink -- it moves across a named external account, which
-- makes creation a thing you can see in the ledger and audit, instead of a
-- number that quietly got bigger.
--
-- The invariant is checkable at any moment: the sum of every balance,
-- including the external accounts, is always zero.
--
-- Pure Lua. No FiveM natives. Testable without a game.

local Money = require("domain.money")

local Ledger = {}
Ledger.__index = Ledger

--- Accounts whose balance is allowed to go negative because they represent
-- the world outside the simulation. Everything else is a real holder of money
-- and may not spend what it does not have.
local EXTERNAL_PREFIX = "external:"

--- How many postings stay in memory. Balances are authoritative and never
--- trimmed; the posting list is the readable history behind them, and on a
--- server that runs for months it cannot be unbounded. When the window
--- overflows, the oldest postings are handed to opts.on_archive, which is
--- where a durable history writer hooks in.
local HISTORY_LIMIT = 5000

Ledger.HISTORY_LIMIT = HISTORY_LIMIT

function Ledger.new(opts)
    opts = opts or {}
    return setmetatable({
        balances = {},
        postings = {},
        seen = {},              -- operation id -> sequence number, for idempotency
        fingerprints = {},      -- binds an operation to its original entries
        sequence = 0,
        archived = 0,
        history_limit = opts.history_limit or HISTORY_LIMIT,
        on_archive = opts.on_archive,
    }, Ledger)
end

function Ledger.is_external(account)
    return account:sub(1, #EXTERNAL_PREFIX) == EXTERNAL_PREFIX
end

function Ledger:balance(account)
    return Money.from_minor(self.balances[account] or 0)
end

--- Every account that has ever been touched, sorted, for audit and debug.
function Ledger:accounts()
    local names = {}
    for account in pairs(self.balances) do names[#names + 1] = account end
    table.sort(names)
    return names
end

--- The sum of every balance. Structurally always zero; asserted by tests and
-- cheap enough to assert in a live consistency audit.
function Ledger:total()
    local sum = 0
    for _, minor in pairs(self.balances) do sum = sum + minor end
    return Money.from_minor(sum)
end

local function describe(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = string.format("%s %s", entry.account, tostring(entry.amount))
    end
    return table.concat(parts, ", ")
end

local function fingerprint(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        local account = entry.account
        parts[#parts + 1] = #account .. ":" .. account .. "=" .. entry.amount:to_minor() .. ";"
    end
    table.sort(parts)
    return table.concat(parts)
end

--- Post a balanced set of entries atomically.
--
-- `operation_id` makes the posting idempotent: the same operation applied
-- twice posts once. That is what stops a retried command, a replayed event or
-- a duplicated client request from paying someone twice.
--
-- Returns ok, error. It never raises on a business failure -- insufficient
-- funds is an answer, not a crash -- but it does raise on a malformed call,
-- because that is a programming mistake and should be loud.
function Ledger:post(operation_id, entries, meta)
    assert(type(operation_id) == "string" and operation_id ~= "", "a posting needs an operation id")
    assert(type(entries) == "table" and #entries > 0, "a posting needs at least one entry")

    local sum = 0
    for index, entry in ipairs(entries) do
        assert(type(entry.account) == "string" and entry.account ~= "",
            "entry " .. index .. " needs an account")
        assert(Money.is(entry.amount), "entry " .. index .. " needs a Money amount")
        sum = sum + entry.amount:to_minor()
    end
    if sum ~= 0 then
        error(string.format(
            "a posting must balance to zero, this one is off by %s (%s)",
            tostring(Money.from_minor(sum)), describe(entries)), 2)
    end

    local request = fingerprint(entries)
    if self.seen[operation_id] then
        if self.fingerprints[operation_id] ~= request then
            return false, "this operation id already belongs to a different or unverifiable posting"
        end
        return true, nil, { duplicate = true, sequence = self.seen[operation_id] }
    end

    -- Check every account can afford its side before changing anything, so a
    -- refused posting leaves no partial effect.
    local proposed = {}
    for _, entry in ipairs(entries) do
        local account = entry.account
        proposed[account] = (proposed[account] or self.balances[account] or 0) + entry.amount:to_minor()
    end
    for account, minor in pairs(proposed) do
        if minor < 0 and not Ledger.is_external(account) then
            return false, string.format("%s cannot go to %s; it holds %s",
                account, tostring(Money.from_minor(minor)), tostring(self:balance(account)))
        end
    end

    for account, minor in pairs(proposed) do
        self.balances[account] = minor
    end
    -- The entries are copied, not kept. A caller that reuses or mutates the
    -- table it passed must not be able to rewrite history after the fact.
    local kept = {}
    for index, entry in ipairs(entries) do
        kept[index] = { account = entry.account, amount = entry.amount }
    end

    self.sequence = self.sequence + 1
    local posting = {
        operation_id = operation_id,
        entries = kept,
        meta = meta,
        sequence = self.sequence,
    }
    self.postings[#self.postings + 1] = posting
    self.seen[operation_id] = posting.sequence
    self.fingerprints[operation_id] = request

    if #self.postings > self.history_limit then
        local removed = {}
        while #self.postings > self.history_limit do
            removed[#removed + 1] = table.remove(self.postings, 1)
            self.archived = self.archived + 1
        end
        if self.on_archive then self.on_archive(removed) end
    end

    return true, nil, { duplicate = false, posting = posting }
end

--- How many postings are held in memory, and how many have left the window.
function Ledger:posting_count() return #self.postings end
function Ledger:archived_count() return self.archived end

--- The common case: move an amount from one account to another.
function Ledger:transfer(operation_id, from, to, amount, meta)
    assert(Money.is(amount), "transfer needs a Money amount")
    assert(not amount:is_negative(), "transfer amount must not be negative; swap the accounts instead")
    return self:post(operation_id, {
        { account = from, amount = amount:negate() },
        { account = to, amount = amount },
    }, meta)
end

--- Everything that ever touched an account, in order. This is the answer to
-- "where did this money come from", which is the question an economy has to
-- be able to answer about itself.
function Ledger:history(account)
    local found = {}
    for _, posting in ipairs(self.postings) do
        for _, entry in ipairs(posting.entries) do
            if entry.account == account then
                found[#found + 1] = {
                    sequence = posting.sequence,
                    operation_id = posting.operation_id,
                    amount = entry.amount,
                    meta = posting.meta,
                }
                break
            end
        end
    end
    return found
end

--- A plain table for persistence. Money becomes integer minor units, which is
--- also how it should sit in a column.
---
--- Balances are written as well as postings even though the postings could
--- rebuild them. That is deliberate: the window of postings is not the whole
--- history, so replaying it would not reproduce the balances, and a stored
--- total that disagrees with the entries is exactly the corruption worth
--- detecting on load rather than papering over.
function Ledger:serialize()
    local balances = {}
    for account, minor in pairs(self.balances) do balances[account] = minor end
    local postings = {}
    for index, posting in ipairs(self.postings) do
        local entries = {}
        for position, entry in ipairs(posting.entries) do
            entries[position] = { account = entry.account, amount = entry.amount:to_minor() }
        end
        postings[index] = {
            operation_id = posting.operation_id,
            sequence = posting.sequence,
            entries = entries,
            meta = posting.meta,
        }
    end
    local seen, fingerprints = {}, {}
    for id, sequence in pairs(self.seen) do seen[id] = sequence end
    for id, request in pairs(self.fingerprints) do fingerprints[id] = request end
    return { balances = balances, postings = postings, sequence = self.sequence,
        archived = self.archived, seen = seen, fingerprints = fingerprints }
end

function Ledger.deserialize(record, opts)
    if type(record) ~= "table" then return nil, "a ledger record is a table" end
    if type(record.balances) ~= "table" or type(record.postings) ~= "table"
        or math.type(record.sequence) ~= "integer" or record.sequence < 0
        or math.type(record.archived) ~= "integer" or record.archived < 0
        or record.archived + #record.postings ~= record.sequence then
        return nil, "stored ledger is corrupt: invalid balances, postings or sequence"
    end
    if (record.seen == nil) ~= (record.fingerprints == nil) then
        return nil, "stored payment receipt maps must be present together"
    end
    local ledger = Ledger.new(opts)
    local sum = 0
    for account, minor in pairs(record.balances or {}) do
        if type(account) ~= "string" or account == "" or math.type(minor) ~= "integer" then
            return nil, ("account %s has a balance that is not whole minor units"):format(tostring(account))
        end
        if minor < 0 and not Ledger.is_external(account) then
            return nil, "an ordinary account has a negative stored balance"
        end
        ledger.balances[account] = minor
        sum = sum + minor
    end
    if sum ~= 0 then
        -- Every posting sums to zero, so every set of balances does too. A
        -- stored ledger that does not is corrupt, and loading it would put
        -- money into the world from nowhere.
        return nil, ("stored balances sum to %s instead of nothing; the ledger is corrupt")
            :format(tostring(Money.from_minor(sum)))
    end
    for index, posting in ipairs(record.postings or {}) do
        if type(posting) ~= "table" or type(posting.operation_id) ~= "string" or posting.operation_id == ""
            or posting.sequence ~= record.archived + index or type(posting.entries) ~= "table"
            or #posting.entries == 0 or ledger.seen[posting.operation_id] then
            return nil, "stored posting has an invalid id, sequence or entries"
        end
        local entries = {}
        local posting_sum = 0
        for position, entry in ipairs(posting.entries or {}) do
            if type(entry) ~= "table" or type(entry.account) ~= "string" or entry.account == "" or math.type(entry.amount) ~= "integer" then
                return nil, ("posting %d holds an amount that is not whole minor units"):format(index)
            end
            entries[position] = { account = entry.account, amount = Money.from_minor(entry.amount) }
            posting_sum = posting_sum + entry.amount
        end
        if posting_sum ~= 0 then return nil, "a stored posting does not balance" end
        ledger.postings[index] = {
            operation_id = posting.operation_id,
            sequence = posting.sequence or index,
            entries = entries,
            meta = posting.meta,
        }
        if posting.operation_id then
            ledger.seen[posting.operation_id] = posting.sequence or index
            ledger.fingerprints[posting.operation_id] = fingerprint(entries)
        end
    end
    ledger.sequence = record.sequence or #ledger.postings
    ledger.archived = record.archived or 0
    if record.seen ~= nil then
        if type(record.seen) ~= "table" or type(record.fingerprints) ~= "table" then
            return nil, "stored payment receipts are invalid"
        end
        for id, sequence in pairs(record.seen) do
            if type(id) ~= "string" or id == "" or math.type(sequence) ~= "integer"
                or sequence < 1 or sequence > ledger.sequence then
                return nil, "stored payment receipt has an invalid sequence"
            end
            local request = record.fingerprints[id]
            if type(request) ~= "string" or request == ""
                or (ledger.seen[id] and ledger.seen[id] ~= sequence)
                or (ledger.fingerprints[id] and ledger.fingerprints[id] ~= request) then
                return nil, "stored payment receipt disagrees with its posting"
            end
            ledger.seen[id], ledger.fingerprints[id] = sequence, request
        end
        local sequences = {}
        for id, sequence in pairs(record.seen) do
            if sequences[sequence] then return nil, "stored payment receipts repeat a sequence" end
            sequences[sequence] = true
        end
        for id in pairs(record.fingerprints) do
            if not record.seen[id] then return nil, "stored payment receipt is missing its sequence" end
        end
        for _, posting in ipairs(ledger.postings) do
            if not record.seen[posting.operation_id] then return nil, "stored posting is missing its receipt" end
        end
    end
    return ledger
end

Ledger.EXTERNAL_PREFIX = EXTERNAL_PREFIX

return Ledger
