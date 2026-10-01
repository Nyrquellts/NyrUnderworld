--- Staff, and proof of what they did.
--
-- Every other system in this project is built so that nobody can reach past
-- the rules. This one exists because somebody has to be able to, and that is
-- the whole difficulty with it. An admin system is a deliberate hole in
-- everything above, so the only honest way to build one is to make the hole
-- narrow, named, and impossible to use quietly.
--
--   Narrow: an admin command does one thing, with a declared argument list and
--   a cap, like every other command. There is no console passthrough and no
--   "run this Lua", because a server that can run arbitrary code on request is
--   a server whose rules are decorative.
--
--   Named: a level is granted from the server console, never claimed, exactly
--   like a police commission. Nobody promotes themselves.
--
--   Impossible to use quietly: **every admin action goes on the record**, with
--   who did it, to whom, and what it was. Not into a log file that can be
--   rotated away, but into the same record the city keeps about everybody
--   else, which is the thing a server owner can read back and a member of
--   staff cannot edit.
--
-- Money made here crosses `external:admin`, so it is as visible in the books
-- as every other pound that entered the world from outside. An economy with a
-- silent mint is an economy nobody can audit; this one has a mint with a name
-- on it.

local Money = require("domain.money")
local Characters = require("systems.characters")

local Admin = {}

local MODERATOR, ADMIN, OWNER = 1, 2, 3
local LEVEL_NAMES = { [MODERATOR] = "moderator", [ADMIN] = "admin", [OWNER] = "owner" }
local MINT = "external:admin"
local DEFAULT_MAX_GIVE = 1000000          -- ten thousand, in minor units
local DEFAULT_MAX_ITEMS = 100

Admin.MODERATOR, Admin.ADMIN, Admin.OWNER = MODERATOR, ADMIN, OWNER
Admin.LEVEL_NAMES = LEVEL_NAMES

--- opts.max_give   the most one command may create or remove, in minor units
--- opts.max_items  the most one command may spawn
function Admin.system(opts)
    opts = opts or {}
    local max_give = opts.max_give or DEFAULT_MAX_GIVE
    local max_items = opts.max_items or DEFAULT_MAX_ITEMS
    assert(math.type(max_give) == "integer" and max_give > 0, "a limit is whole minor units above zero")

    return {
        name = "admin",
        requires = { "characters", "memory" },
        install = function(world)
            local people = world:repository(Characters.Character)
            local levels = {}          -- character -> level, persisted

            local function level_of(character) return levels[character] or 0 end

            --- Write down what a member of staff did, to the same record the
            --- city keeps about everybody. This is the point of the system.
            ---
            --- Under the command's own operation id. Named by who, what and the
            --- city millisecond, two gives in one server tick were one line: the
            --- second was paid and never written down.
            local function log(ctx, action, target, meta)
                local details = { action = action }
                for key, value in pairs(meta or {}) do details[key] = value end
                world.services.remember(("admin:%s"):format(ctx.operation_id), {
                    subject = ctx.actor, kind = "admin.acted", weight = 0,
                    involved = target and { target } or nil,
                    meta = details,
                })
            end

            local function staff(ctx, needed)
                if not ctx.actor then
                    return nil, ctx.refuse("not_playing", "You are not playing anybody.")
                end
                local held = level_of(ctx.actor)
                if held < (needed or MODERATOR) then
                    return nil, ctx.refuse("not_staff", "That is not yours to do.")
                end
                return held, nil
            end

            world.services.admin = {
                level_of = level_of,
                is_staff = function(character) return level_of(character) > 0 end,
                --- Give somebody a level. From the console, never from a
                --- command, for the same reason a commission is.
                grant = function(character, level)
                    if level == nil or level == 0 then
                        levels[character] = nil
                        return 0
                    end
                    assert(math.type(level) == "integer" and level >= MODERATOR and level <= OWNER,
                        "a staff level is moderator, admin or owner")
                    levels[character] = level
                    return level
                end,
                staff = function()
                    local out = {}
                    for character, level in pairs(levels) do
                        out[#out + 1] = { character = character, level = level,
                                          title = LEVEL_NAMES[level] }
                    end
                    table.sort(out, function(a, b)
                        if a.level ~= b.level then return a.level > b.level end
                        return a.character < b.character
                    end)
                    return out
                end,
            }

            world:persist_with("admin", {
                save = function()
                    local out = {}
                    for character, level in pairs(levels) do out[character] = level end
                    return { levels = out }
                end,
                load = function(stored)
                    levels = {}
                    for character, level in pairs((stored or {}).levels or {}) do
                        if math.type(level) ~= "integer" or level < MODERATOR or level > OWNER then
                            return false, ("%s has a staff level that is not a level"):format(character)
                        end
                        levels[character] = level
                    end
                    return true
                end,
            })

            world:define("admin.who", {
                summary = "who is playing right now",
                rate = { per_minute = 30 },
                args = {},
                handler = function(ctx)
                    local _, refused = staff(ctx)
                    if refused then return refused end
                    local out = {}
                    for _, session in ipairs(world.services.sessions:active()) do
                        local person = people:load(session.character)
                        out[#out + 1] = {
                            character = session.character,
                            name = person and Characters.full_name(person) or "?",
                            state = person and person.state or "?",
                            staff = level_of(session.character),
                        }
                    end
                    return ctx.ok({ online = out })
                end,
            })

            world:define("admin.look", {
                summary = "everything the city has on somebody",
                rate = { per_minute = 30 },
                args = {
                    character = { type = "id", kind = "chr", required = true },
                    limit = { type = "integer", default = 20, min = 1, max = 100 },
                },
                handler = function(ctx, args)
                    local _, refused = staff(ctx)
                    if refused then return refused end
                    local person = people:load(args.character)
                    if not person then return ctx.refuse("no_such_person", "There is no such person.") end

                    local found = world.services.record:about(args.character, { limit = args.limit })
                    local lines = {}
                    for position, entry in ipairs(found) do
                        lines[position] = { at = entry.at, kind = entry.kind, place = entry.place,
                                            witnessed = #entry.witnesses > 0 }
                    end
                    -- Looking somebody up is itself an action, so it is logged
                    -- like every other one. A search with no reason is exactly
                    -- what an owner wants to be able to find.
                    log(ctx, "look", args.character, {})
                    return ctx.ok({
                        character = args.character,
                        name = Characters.full_name(person),
                        state = person.state,
                        wallet = world.ledger:balance(Characters.wallet(args.character)):to_minor(),
                        heat = world.services.heat(args.character),
                        records = lines,
                    })
                end,
            })

            world:define("admin.give", {
                summary = "put money into somebody's pocket",
                rate = { per_minute = 20 },
                args = {
                    character = { type = "id", kind = "chr", required = true },
                    amount = { type = "integer", required = true, min = 1 },
                    reason = { type = "string", required = true, min = 3, max = 120 },
                },
                handler = function(ctx, args)
                    local _, refused = staff(ctx, ADMIN)
                    if refused then return refused end
                    if args.amount > max_give then
                        return ctx.refuse("too_much",
                            ("That is more than one command may create."):format())
                    end
                    if not people:load(args.character) then
                        return ctx.refuse("no_such_person", "There is no such person.")
                    end
                    -- Across a named account, so it is as visible in the books
                    -- as every other pound that came in from outside.
                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("admingive:%s:%d"):format(args.character, ctx.now),
                        MINT, Characters.wallet(args.character), Money.from_minor(args.amount),
                        { reason = "admin", note = args.reason, by = ctx.actor })
                    if not ok then return ctx.refuse("cannot", why) end
                    log(ctx, "give", args.character, { amount = args.amount, reason = args.reason })
                    ctx.emit("admin.gave", { by = ctx.actor, character = args.character,
                        amount = args.amount, reason = args.reason })
                    return ctx.ok({ amount = args.amount })
                end,
            })

            world:define("admin.take", {
                summary = "take money back out",
                rate = { per_minute = 20 },
                args = {
                    character = { type = "id", kind = "chr", required = true },
                    amount = { type = "integer", required = true, min = 1 },
                    reason = { type = "string", required = true, min = 3, max = 120 },
                },
                handler = function(ctx, args)
                    local _, refused = staff(ctx, ADMIN)
                    if refused then return refused end
                    if args.amount > max_give then
                        return ctx.refuse("too_much", "That is more than one command may remove.")
                    end
                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("admintake:%s:%d"):format(args.character, ctx.now),
                        Characters.wallet(args.character), MINT, Money.from_minor(args.amount),
                        { reason = "admin", note = args.reason, by = ctx.actor })
                    if not ok then
                        return ctx.refuse("not_carrying", "They do not have that much.", { detail = why })
                    end
                    log(ctx, "take", args.character, { amount = args.amount, reason = args.reason })
                    ctx.emit("admin.took", { by = ctx.actor, character = args.character,
                        amount = args.amount, reason = args.reason })
                    return ctx.ok({ amount = args.amount })
                end,
            })

            if world:has("inventory") then
                world:define("admin.item", {
                    summary = "put something in somebody's pockets",
                    rate = { per_minute = 20 },
                    args = {
                        character = { type = "id", kind = "chr", required = true },
                        item = { type = "string", required = true, max = 32 },
                        count = { type = "integer", default = 1, min = 1 },
                        reason = { type = "string", required = true, min = 3, max = 120 },
                    },
                    handler = function(ctx, args)
                        local _, refused = staff(ctx, ADMIN)
                        if refused then return refused end
                        if args.count > max_items then
                            return ctx.refuse("too_much", "That is more than one command may make.")
                        end
                        if not world.services.items:has(args.item) then
                            return ctx.refuse("no_such_item", "There is no such thing.")
                        end
                        if not people:load(args.character) then
                            return ctx.refuse("no_such_person", "There is no such person.")
                        end
                        local ok, why = world.services.inventory:spawn(
                            ctx.operation_id or ("adminitem:%s:%d"):format(args.character, ctx.now),
                            args.character, args.item, args.count,
                            { reason = "admin: " .. args.reason })
                        if not ok then return ctx.refuse("will_not_fit", why) end
                        log(ctx, "item", args.character,
                            { item = args.item, count = args.count, reason = args.reason })
                        ctx.emit("admin.made", { by = ctx.actor, character = args.character,
                            item = args.item, count = args.count, reason = args.reason })
                        return ctx.ok({ item = args.item, count = args.count })
                    end,
                })
            end

            world:define("admin.trail", {
                summary = "what staff have been doing",
                rate = { per_minute = 20 },
                args = {
                    who = { type = "id", kind = "chr" },
                    limit = { type = "integer", default = 30, min = 1, max = 100 },
                },
                handler = function(ctx, args)
                    -- Reading the trail is an owner's job, and it is the one
                    -- admin command that is not itself logged, because logging
                    -- a read of the log is how a log becomes unreadable.
                    local _, refused = staff(ctx, OWNER)
                    if refused then return refused end
                    local found = args.who
                        and world.services.record:about(args.who,
                            { kind = "admin.acted", limit = args.limit })
                        or world.services.record:search({ kind = "admin.acted", limit = args.limit })
                    local lines = {}
                    for position, entry in ipairs(found) do
                        lines[position] = { at = entry.at, by = entry.subject,
                                            action = entry.meta and entry.meta.action,
                                            reason = entry.meta and entry.meta.reason,
                                            amount = entry.meta and entry.meta.amount,
                                            on = entry.involved[1] }
                    end
                    return ctx.ok({ actions = lines })
                end,
            })
        end,
    }
end

return Admin
