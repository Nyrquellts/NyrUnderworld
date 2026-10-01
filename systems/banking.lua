--- Money you are not carrying.
--
-- A bank account is the same ledger with a different account name. That is not
-- a simplification, it is the whole design: there is no second place money can
-- live, no balance column, and no code path that adds to an account rather
-- than moving into it. Everything the earlier systems promise about money is
-- therefore already true here, including that the books sum to nothing after
-- every transfer.
--
-- What a bank adds over a wallet is three things a wallet cannot do:
--
--   Hold what you are not carrying. Being robbed takes your pockets and not
--   your account, which is the entire reason a player uses one.
--
--   Be reached by somebody who is not standing next to you. A transfer goes by
--   account number, which is a thing a person can read out, rather than by
--   character id, which is an internal identifier a client should never need
--   to know and should never be trusted to supply.
--
--   Say what happened. A statement is read straight off the ledger history
--   that is already being kept, so it cannot disagree with the balance.
--
-- The risk worth naming: a transfer command is the fastest way to launder a
-- duplication bug, because it turns "money that should not exist" into "money
-- in somebody else's account" in one hop. So every path here is checked
-- against the books summing to nothing, and the spec asserts that after every
-- single case, including the ones that fail.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Id = require("domain.id")
local Characters = require("systems.characters")
local Property = require("systems.property")

local Banking = {}

local BANK_FEES = "external:bank"
-- Where a retired person's money leaves the world, as systems/characters.lua
-- sends their wallet.
local ESTATE = "external:estate"
local DEFAULT_MAX_ACCOUNTS = 1
local DEFAULT_OPENING_FEE = 0
local MAX_AMOUNT = 100000000          -- a million, in minor units

Banking.Account = Entity.define("acc", {
    fields = {
        holder = { type = "id", kind = "chr", required = true },
        number = { type = "string", required = true, min = 8, max = 20 },
        label = { type = "string", max = 32, default = "current" },
    },
    states = {
        -- Frozen is not closed. A frozen account still holds what is in it and
        -- still appears on a statement; it simply cannot move money either way,
        -- which is what an investigation wants and what a closure does not.
        open = { "frozen", "closed" },
        frozen = { "open", "closed" },
        closed = {},
    },
    initial = "open",
})

local Account = Banking.Account

--- The ledger account a bank account holds its money in.
function Banking.vault(account_id) return "bank:" .. account_id end

-- A number a person can read down a phone. Derived from the account id, so it
-- is stable for the life of the account and needs nothing stored to stay
-- unique; checked against the ones already issued anyway, because "effectively
-- unique" is not a thing to rely on for something people type.
local ALPHABET = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"   -- no I or O: they read as 1 and 0

local function number_from(id, salt)
    local parsed = Id.parse(id)
    local body = (parsed and parsed.body or id):gsub("[^%w]", "")
    local digits = {}
    local seed = salt or 0
    for index = 1, 8 do
        local position = ((body:byte(((index + seed - 1) % #body) + 1) or 65) + seed * index) % #ALPHABET
        digits[index] = ALPHABET:sub(position + 1, position + 1)
    end
    return ("NYR-%s-%s"):format(table.concat(digits, "", 1, 4), table.concat(digits, "", 5, 8))
end

Banking.number_from = number_from

--- opts.max_accounts  how many accounts one person may hold
--- opts.opening_fee   what opening one costs, in minor units
--- opts.fee_percent   a whole percentage taken from each transfer
function Banking.system(opts)
    opts = opts or {}
    local max_accounts = opts.max_accounts or DEFAULT_MAX_ACCOUNTS
    local opening_fee = opts.opening_fee or DEFAULT_OPENING_FEE
    local fee_percent = opts.fee_percent or 0
    assert(math.type(max_accounts) == "integer" and max_accounts >= 1, "an account limit is at least one")
    assert(math.type(opening_fee) == "integer" and opening_fee >= 0, "an opening fee is whole minor units")
    assert(math.type(fee_percent) == "integer" and fee_percent >= 0 and fee_percent < 100,
        "a transfer fee is a whole percentage below one hundred")

    return {
        name = "banking",
        requires = { "characters", "memory", "property" },
        install = function(world)
            local accounts = world:repository(Account)
            local by_number = {}          -- account number -> account id

            local function index(account)
                by_number[account:get("number")] = account.id
            end

            local function reindex()
                by_number = {}
                for _, account in ipairs(accounts:all()) do
                    if account.state ~= "closed" then index(account) end
                end
            end

            local function held_by(character)
                local out = {}
                for _, account in ipairs(accounts:where(function(candidate)
                    return candidate:get("holder") == character and candidate.state ~= "closed"
                end)) do
                    out[#out + 1] = account
                end
                return out
            end

            local function find_by_number(number)
                local id = by_number[number]
                if not id then return nil end
                local account = accounts:load(id)
                if not account or account.state == "closed" then return nil end
                return account
            end

            local function balance_of(account)
                return world.ledger:balance(Banking.vault(account.id))
            end

            local function is_branch(place_id)
                local place = world.services.property.places:load(place_id)
                if not place or place:get("kind") ~= "bank" then return nil end
                return place
            end

            local function at_branch(ctx, place_id)
                local place = is_branch(place_id)
                if not place then
                    return nil, ctx.refuse("no_such_branch", "That is not a bank.")
                end
                local check = world.services.proximity
                if type(check) ~= "function" then
                    return nil, ctx.refuse("no_proximity", "The server cannot tell where you are.")
                end
                if check(ctx.actor, place_id) ~= true then
                    return nil, ctx.refuse("too_far", "You are not at the counter.")
                end
                return place, nil
            end

            world.services.banking = {
                accounts = accounts,
                vault = Banking.vault,
                held_by = held_by,
                find_by_number = find_by_number,
                balance_of = balance_of,
                --- Put a branch on the map. A bank is a place with a door, so
                --- it is a place: the same entity, the same coordinates, the
                --- same proximity service as every other door in the city.
                branch = function(address, branch_opts)
                    branch_opts = branch_opts or {}
                    branch_opts.kind = "bank"
                    branch_opts.price = branch_opts.price or 0
                    branch_opts.rent = branch_opts.rent or 0
                    -- Not on the market, which `Property.premises` now says
                    -- for every kind of premises rather than this one line
                    -- saying it for banks alone. It was the only thing in the
                    -- city that knew a business's front door is not housing,
                    -- and a shop's premises went on sale at a price of zero
                    -- because nothing said it there.
                    return world.services.property.build(address, branch_opts)
                end,
                --- Freeze or unfreeze. A service and not a command: this is
                --- what an investigation does to somebody, and nobody freezes
                --- their own account by asking nicely.
                freeze = function(account_id, frozen)
                    local account = accounts:load(account_id)
                    if not account then return false, "no such account" end
                    local wanted = frozen ~= false and "frozen" or "open"
                    if account.state == wanted then return true end
                    local ok, why = account:transition(wanted, { reason = "by order" })
                    if not ok then return false, why end
                    accounts:save(account)
                    world.events:emit("bank.frozen", { account = account.id,
                        holder = account:get("holder"), frozen = wanted == "frozen" })
                    return true
                end,
            }

            -- Retiring somebody emptied their wallet and left their account
            -- open with its balance: money sent to the number they had handed
            -- out still landed, and nobody could ever take it out again. So a
            -- retired person's accounts close, and what is in them leaves the
            -- world the way their wallet does. A frozen one closes too: a hold
            -- is placed against somebody, and a retired person is never played
            -- again, so there is nobody left to hold it against.
            local function close_for_retirement(account)
                local held = balance_of(account)
                if held:is_positive() then
                    local moved, why = world.ledger:transfer("retire:" .. account.id,
                        Banking.vault(account.id), ESTATE, held,
                        { reason = "retired", number = account:get("number") })
                    if not moved then
                        error(("%s could not be emptied for a retirement: %s"):format(account.id, tostring(why)), 0)
                    end
                end
                account:transition("closed", { reason = "holder retired" })
                accounts:save(account)
            end

            world:on("character.retired", function(payload)
                for _, account in ipairs(held_by(payload.character)) do close_for_retirement(account) end
            end, { label = "banking:retired" })

            world:on("world.loaded", function()
                -- Somebody retired under a build that closed nothing still
                -- holds an open account, and it is closed the same way.
                local people = world.services.characters.repository
                for _, account in ipairs(accounts:all()) do
                    local holder = people:load(account:get("holder"))
                    if account.state ~= "closed" and holder and holder.state == "retired" then
                        close_for_retirement(account)
                    end
                end
                reindex()
            end, { label = "banking:load" })

            world:define("bank.open", {
                summary = "open an account at a branch",
                rate = { per_minute = 4 },
                args = { branch = { type = "id", kind = "prp", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local _, refused = at_branch(ctx, args.branch)
                    if refused then return refused end
                    if #held_by(ctx.actor) >= max_accounts then
                        return ctx.refuse("too_many_accounts",
                            ("You already have %d."):format(max_accounts))
                    end

                    -- The number has to be unique because people type it. The
                    -- id it comes from is unique already; this is the check
                    -- that turns "effectively" into "actually".
                    local account, why = accounts:create({ holder = ctx.actor, number = "NYR-0000-0000" })
                    if not account then return ctx.refuse("cannot_open", why) end
                    local number
                    for salt = 0, 32 do
                        local candidate = number_from(account.id, salt)
                        if not by_number[candidate] then
                            number = candidate
                            break
                        end
                    end
                    if not number then
                        accounts:delete(account.id)
                        return ctx.refuse("cannot_open", "could not find a free account number")
                    end
                    account:set("number", number)
                    accounts:save(account)
                    index(account)

                    if opening_fee > 0 then
                        local paid, fee_why = world.ledger:transfer(
                            "opening:" .. account.id, Characters.wallet(ctx.actor), BANK_FEES,
                            Money.from_minor(opening_fee), { reason = "account opening" })
                        if not paid then
                            accounts:delete(account.id)
                            by_number[number] = nil
                            return ctx.refuse("cannot_afford", "You cannot cover the opening fee.",
                                { detail = fee_why })
                        end
                    end

                    ctx.emit("bank.opened", { account = account.id, number = number, holder = ctx.actor })
                    return ctx.ok({ account = account.id, number = number })
                end,
            })

            local function own_open_account(ctx)
                local mine = held_by(ctx.actor)
                if #mine == 0 then return nil, ctx.refuse("no_account", "You do not have an account.") end
                local account = mine[1]
                if account.state ~= "open" then
                    return nil, ctx.refuse("frozen", "That account is frozen.")
                end
                return account, nil
            end

            world:define("bank.deposit", {
                summary = "put what you are carrying into your account",
                rate = { per_minute = 20 },
                args = {
                    branch = { type = "id", kind = "prp", required = true },
                    amount = { type = "integer", required = true, min = 1, max = MAX_AMOUNT },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local _, refused = at_branch(ctx, args.branch)
                    if refused then return refused end
                    local account, no_account = own_open_account(ctx)
                    if no_account then return no_account end

                    -- The amount is a request to move the player's own money,
                    -- and the ledger is what decides whether it is there. A
                    -- deposit larger than the wallet is refused by the posting
                    -- before anything moves, not by a check that could be
                    -- forgotten at the next call site.
                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("deposit:%s:%d"):format(account.id, ctx.now),
                        Characters.wallet(ctx.actor), Banking.vault(account.id),
                        Money.from_minor(args.amount), { reason = "deposit" })
                    if not ok then
                        return ctx.refuse("not_carrying", "You are not carrying that much.", { detail = why })
                    end
                    ctx.emit("bank.deposited", { account = account.id, holder = ctx.actor,
                        amount = args.amount })
                    return ctx.ok({ balance = balance_of(account):to_minor() })
                end,
            })

            world:define("bank.withdraw", {
                summary = "take money out of your account",
                rate = { per_minute = 20 },
                args = {
                    branch = { type = "id", kind = "prp", required = true },
                    amount = { type = "integer", required = true, min = 1, max = MAX_AMOUNT },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local _, refused = at_branch(ctx, args.branch)
                    if refused then return refused end
                    local account, no_account = own_open_account(ctx)
                    if no_account then return no_account end

                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("withdraw:%s:%d"):format(account.id, ctx.now),
                        Banking.vault(account.id), Characters.wallet(ctx.actor),
                        Money.from_minor(args.amount), { reason = "withdrawal" })
                    if not ok then
                        return ctx.refuse("insufficient", "There is not that much in there.", { detail = why })
                    end
                    ctx.emit("bank.withdrawn", { account = account.id, holder = ctx.actor,
                        amount = args.amount })
                    return ctx.ok({ balance = balance_of(account):to_minor() })
                end,
            })

            world:define("bank.transfer", {
                summary = "send money to another account by its number",
                rate = { per_minute = 20 },
                args = {
                    to = { type = "string", required = true, min = 8, max = 20 },
                    amount = { type = "integer", required = true, min = 1, max = MAX_AMOUNT },
                    reference = { type = "string", max = 48 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local from, no_account = own_open_account(ctx)
                    if no_account then return no_account end

                    -- Looked up before a single unit moves. A number nobody
                    -- holds is a typo, and a typo must cost nothing.
                    local to = find_by_number(args.to)
                    if not to then
                        return ctx.refuse("no_such_account", "There is no account with that number.")
                    end
                    if to.id == from.id then
                        return ctx.refuse("same_account", "That is your own account.")
                    end
                    if to.state ~= "open" then
                        return ctx.refuse("recipient_frozen", "That account cannot take money right now.")
                    end

                    local amount = Money.from_minor(args.amount)
                    local fee, sent = Money.zero, amount
                    if fee_percent > 0 then
                        fee, sent = amount:percent(fee_percent)
                    end

                    -- One posting, three entries where there is a fee. The
                    -- whole thing lands or none of it does, so a transfer
                    -- cannot leave the fee taken and the money not sent.
                    local entries = {
                        { account = Banking.vault(from.id), amount = amount:negate() },
                        { account = Banking.vault(to.id), amount = sent },
                    }
                    if fee:is_positive() then
                        entries[#entries + 1] = { account = BANK_FEES, amount = fee }
                    end
                    local ok, why = world.ledger:post(
                        ctx.operation_id or ("transfer:%s:%d"):format(from.id, ctx.now),
                        entries,
                        { reason = "transfer", reference = args.reference,
                          to_number = args.to, from_number = from:get("number") })
                    if not ok then
                        return ctx.refuse("insufficient", "There is not that much in there.", { detail = why })
                    end

                    -- Who paid whom is exactly the sort of thing an
                    -- investigation follows, so it goes on the record as well
                    -- as into the books. One record per request: built from the
                    -- two accounts and the time, a second transfer between them
                    -- in the same tick moved the money and was never written.
                    world.services.remember("transfer:" .. ctx.operation_id, {
                        subject = ctx.actor, kind = "bank.transfer", weight = 1,
                        involved = { to:get("holder") },
                        meta = { amount = args.amount, fee = fee:to_minor(),
                                 reference = args.reference, to_number = args.to },
                    })
                    ctx.emit("bank.transferred", {
                        from = from.id, to = to.id, amount = args.amount,
                        fee = fee:to_minor(), reference = args.reference,
                    })
                    return ctx.ok({ sent = sent:to_minor(), fee = fee:to_minor(),
                                    balance = balance_of(from):to_minor() })
                end,
            })

            world:define("bank.statement", {
                read_only = true,
                summary = "what your account has done",
                rate = { per_minute = 20 },
                args = { limit = { type = "integer", default = 20, min = 1, max = 100 } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local mine = held_by(ctx.actor)
                    if #mine == 0 then return ctx.refuse("no_account", "You do not have an account.") end
                    local account = mine[1]

                    -- Read off the books rather than kept alongside them. A
                    -- statement that is maintained separately is a statement
                    -- that can disagree with the balance, and then nobody
                    -- knows which one is lying.
                    local history = world.ledger:history(Banking.vault(account.id))
                    local lines, from = {}, math.max(1, #history - args.limit + 1)
                    for position = from, #history do
                        local entry = history[position]
                        lines[#lines + 1] = {
                            sequence = entry.sequence,
                            amount = entry.amount:to_minor(),
                            reason = entry.meta and entry.meta.reason or nil,
                            reference = entry.meta and entry.meta.reference or nil,
                        }
                    end
                    return ctx.ok({
                        account = account.id,
                        number = account:get("number"),
                        state = account.state,
                        balance = balance_of(account):to_minor(),
                        lines = lines,
                    })
                end,
            })
        end,
    }
end

Banking.Property = Property

return Banking
