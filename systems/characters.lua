--- People, and which one a player is being right now.
--
-- Everything the city remembers hangs off a character: what they own, what
-- they owe, who they have wronged, what the police have on them. So the
-- character is the first system, and the rules about it are strict.
--
-- The identity that matters is the account, and it never comes from the
-- client. A player connecting gives the server a platform identifier; the
-- adapter puts that on the request as `account`, and it is the one fact in a
-- request that cannot be forged. A client asking to play a character it does
-- not own is refused here, not trusted and repaired later.
--
-- One account plays one character at a time. That is the same invariant as
-- one asset having one owner, and it is load-bearing for the same reason: two
-- live copies of one person is how the same wallet gets spent twice.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Outcome = require("core.outcome")

local Characters = {}

-- A platform identity: license:abc123, steam:1100001, discord:12345.
local ACCOUNT_PATTERN = "^%l[%l%d]*:[%w_%-%.]+$"
-- Letters, single spaces, apostrophes and hyphens, starting and ending on a
-- letter. Deliberately narrow: a name goes into chat, onto an ID card and into
-- a database, and a name full of control characters is a bug in three places
-- at once. The space here is a literal space and not %s, which would also
-- match a newline and let a name break every line it is printed on.
local NAME_PATTERN = "^%a[%a '%-]*%a$"

local DEFAULT_LIMIT = 3
local DEFAULT_OPENING = 50000            -- five hundred, in minor units

Characters.ACCOUNT_PATTERN = ACCOUNT_PATTERN
Characters.NAME_PATTERN = NAME_PATTERN

function Characters.is_account(value)
    return type(value) == "string" and #value <= 64 and value:match(ACCOUNT_PATTERN) ~= nil
end

--- The ledger account a character keeps their walking-around money in.
function Characters.wallet(character_id)
    return "chr:" .. character_id
end

Characters.Character = Entity.define("chr", {
    fields = {
        account = { type = "string", required = true, max = 64, pattern = ACCOUNT_PATTERN },
        first_name = { type = "string", required = true, min = 2, max = 24, pattern = NAME_PATTERN },
        last_name = { type = "string", required = true, min = 2, max = 24, pattern = NAME_PATTERN },
        phone = { type = "string", max = 12 },
        born = { type = "integer", min = 0 },
    },
    states = {
        offline = { "active", "retired" },
        active = { "offline", "dead", "retired" },
        -- Dead goes back to active: respawning at a hospital is the normal
        -- end of dying, and a city where death is permanent by default is a
        -- city people play once.
        dead = { "offline", "active" },
        retired = {},
    },
    initial = "offline",
})

local Character = Characters.Character

function Characters.full_name(character)
    return ("%s %s"):format(character:get("first_name"), character:get("last_name"))
end

-- ----------------------------------------------------------------- sessions

--- Which account is playing which character. One each way, and both
--- directions are checked, because a bug that lets one character be played
--- from two accounts is the same shape as a duplication bug.
local Sessions = {}
Sessions.__index = Sessions

function Sessions.new()
    return setmetatable({ _by_account = {}, _by_character = {} }, Sessions)
end

function Sessions:bind(account, character_id)
    local current = self._by_account[account]
    if current == character_id then return true end
    if current then
        return false, ("%s is already playing %s"):format(account, current)
    end
    local holder = self._by_character[character_id]
    if holder then
        return false, ("%s is already being played by %s"):format(character_id, holder)
    end
    self._by_account[account] = character_id
    self._by_character[character_id] = account
    return true
end

function Sessions:release(account)
    local character_id = self._by_account[account]
    if not character_id then return false end
    self._by_account[account] = nil
    self._by_character[character_id] = nil
    return true, character_id
end

function Sessions:character_of(account) return self._by_account[account] end
function Sessions:account_of(character_id) return self._by_character[character_id] end

function Sessions:count()
    local n = 0
    for _ in pairs(self._by_account) do n = n + 1 end
    return n
end

function Sessions:active()
    local out = {}
    for account, character_id in pairs(self._by_account) do
        out[#out + 1] = { account = account, character = character_id }
    end
    table.sort(out, function(a, b) return a.account < b.account end)
    return out
end

Characters.Sessions = Sessions

-- ------------------------------------------------------------------ queries

--- Every character an account has, oldest first. A read, not a command, so the
--- adapter calls it directly rather than dispatching.
function Characters.of_account(world, account)
    local repository = world:repository(Character)
    repository:all()
    return repository:where(function(character)
        return character:get("account") == account and character.state ~= "retired"
    end)
end

-- ------------------------------------------------------------------- system

--- opts.limit    how many living characters one account may keep
--- opts.opening  allowance for the account's first `limit` characters, in minor units
function Characters.system(opts)
    opts = opts or {}
    local limit = opts.limit or DEFAULT_LIMIT
    local opening = opts.opening or DEFAULT_OPENING

    return {
        name = "characters",
        install = function(world)
            local people = world:repository(Character)
            local sessions = Sessions.new()
            world.services.sessions = sessions
            world.services.characters = {
                repository = people,
                wallet = Characters.wallet,
                of_account = function(account) return Characters.of_account(world, account) end,
            }

            world:define("character.list", {
                read_only = true,
                summary = "the people you can play",
                -- The first screen a player sees asks this, and asks it again
                -- after every change, so the limit is generous.
                rate = { per_minute = 30 },
                -- No argument naming an account. There is no way to ask this
                -- about somebody else.
                args = {},
                handler = function(ctx)
                    if not Characters.is_account(ctx.account) then
                        return ctx.refuse("no_account", "The server did not say who you are.")
                    end
                    local playing = ctx.services.sessions:character_of(ctx.account)
                    local found = Characters.of_account(world, ctx.account)
                    -- Ids are time-ordered text, so sorting them is sorting by
                    -- when the person was made. A picker whose rows move
                    -- around between reads is a picker you misclick.
                    table.sort(found, function(a, b) return a.id < b.id end)

                    local rows = {}
                    for _, character in ipairs(found) do
                        rows[#rows + 1] = {
                            character = character.id,
                            name = Characters.full_name(character),
                            state = character.state,
                            born = character:get("born"),
                            wallet = world.ledger:balance(
                                Characters.wallet(character.id)):to_minor(),
                            playing = character.id == playing,
                        }
                    end
                    -- `limit` is a count to print, not permission to grant.
                    -- Whether another person can be made is answered by
                    -- character.create refusing, never by a screen deciding.
                    return ctx.ok({ characters = rows, limit = limit, playing = playing })
                end,
            })

            world:define("character.create", {
                receipt_scope = "account",
                summary = "make a new person",
                rate = { per_minute = 6 },
                args = {
                    first_name = { type = "string", required = true, min = 2, max = 24, pattern = NAME_PATTERN },
                    last_name = { type = "string", required = true, min = 2, max = 24, pattern = NAME_PATTERN },
                },
                handler = function(ctx, args)
                    if not Characters.is_account(ctx.account) then
                        return ctx.refuse("no_account", "The server did not say who you are.")
                    end
                    local existing = Characters.of_account(world, ctx.account)
                    if #existing >= limit then
                        return ctx.refuse("too_many_characters",
                            ("You already have %d people. Retire one first."):format(limit))
                    end
                    -- Retired people still count toward lifetime allowances.
                    -- Replacing a character frees a slot, never a money grant.
                    local lifetime = #people:where(function(person)
                        return person:get("account") == ctx.account
                    end)
                    local character, why = people:create({
                        account = ctx.account,
                        first_name = args.first_name,
                        last_name = args.last_name,
                        born = ctx.now,
                    })
                    if not character then return ctx.refuse("bad_name", why) end

                    if opening > 0 and lifetime < limit then
                        -- Money arrives across a named external account, so a
                        -- starting allowance is an auditable posting rather
                        -- than a number appearing.
                        ctx.services.ledger:transfer(
                            "opening:" .. character.id, "external:mint",
                            Characters.wallet(character.id), Money.from_minor(opening),
                            { reason = "opening balance" })
                    end

                    ctx.emit("character.created", {
                        character = character.id,
                        account = ctx.account,
                        name = Characters.full_name(character),
                    })
                    return ctx.ok(character.id)
                end,
            })

            world:define("character.select", {
                receipt_scope = "account",
                summary = "start playing one of your people",
                rate = { per_minute = 12 },
                args = { character = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    if not Characters.is_account(ctx.account) then
                        return ctx.refuse("no_account", "The server did not say who you are.")
                    end
                    local character = people:load(args.character)
                    if not character then
                        return ctx.refuse("no_such_character", "That person does not exist.")
                    end
                    -- The check that makes the account the identity that
                    -- matters: a client naming somebody else is refused.
                    if character:get("account") ~= ctx.account then
                        return ctx.refuse("not_yours", "That is not one of your people.")
                    end
                    if character.state == "retired" then
                        return ctx.refuse("retired", "That person has retired.")
                    end
                    local bound = ctx.services.sessions:bind(ctx.account, character.id)
                    if not bound then
                        -- A refusal is drawn on the player's screen, which is often
                        -- on a stream, so it names nobody. This one was the
                        -- session's own reason, which names the account and the
                        -- person: "license:... is already playing chr_...".
                        if ctx.services.sessions:character_of(ctx.account) then
                            return ctx.refuse("already_playing",
                                "You are already playing somebody. Stop playing them first.")
                        end
                        return ctx.refuse("already_playing", "That person is already being played.")
                    end
                    if character.state ~= "active" then
                        local moved, move_why = character:transition("active", { reason = "selected" })
                        if not moved then
                            ctx.services.sessions:release(ctx.account)
                            return ctx.refuse("cannot_wake", move_why)
                        end
                    end
                    people:save(character)
                    ctx.emit("character.selected", {
                        character = character.id, account = ctx.account,
                        name = Characters.full_name(character),
                    })
                    return ctx.ok(character.id)
                end,
            })

            world:define("character.release", {
                receipt_scope = "account",
                summary = "stop playing, on disconnect or when switching",
                args = {},
                handler = function(ctx)
                    local released, character_id = ctx.services.sessions:release(ctx.account)
                    if not released then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local character = people:load(character_id)
                    if character and character.state == "active" then
                        character:transition("offline", { reason = "released" })
                        people:save(character)
                    end
                    ctx.emit("character.released", { character = character_id, account = ctx.account })
                    return ctx.ok(character_id)
                end,
            })

            world:define("character.retire", {
                receipt_scope = "account",
                summary = "put a person away for good",
                args = { character = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    local character = people:load(args.character)
                    if not character or character:get("account") ~= ctx.account then
                        return ctx.refuse("not_yours", "That is not one of your people.")
                    end
                    if ctx.services.sessions:account_of(character.id) then
                        return ctx.refuse("still_playing", "Stop playing them first.")
                    end
                    local retired, why = character:transition("retired", { reason = "retired by owner" })
                    if not retired then return ctx.refuse("cannot_retire", why) end
                    people:save(character)
                    -- What they were carrying goes back out of the world the
                    -- same way it came in, so the books still sum to nothing.
                    local wallet = Characters.wallet(character.id)
                    local held = ctx.services.ledger:balance(wallet)
                    if held:is_positive() then
                        ctx.services.ledger:transfer("retire:" .. character.id, wallet,
                            "external:estate", held, { reason = "retired" })
                    end
                    ctx.emit("character.retired", { character = character.id, account = ctx.account })
                    return ctx.ok()
                end,
            })

            -- A character who was active when the server stopped is not
            -- playing when it starts again. Left alone, they would be
            -- unselectable forever, with the session that owned them gone.
            world:on("world.loaded", function()
                for _, character in ipairs(people:all()) do
                    if character.state == "active" then
                        character:transition("offline", { reason = "server restarted" })
                        people:save(character)
                    end
                end
            end, { label = "characters:restart" })
        end,
    }
end

Characters.Outcome = Outcome

return Characters
