--- A number, and the things said between numbers.
--
-- Most of what a phone shows already exists as a read behind a command: your
-- own record, your bank statement, your crew roster, what you are wanted for.
-- The genuinely new capability here is people talking to each other, and that
-- is the one that needs the rules.
--
-- The rule, a fifth time:
--
--   In work, the player never says what a job pays.
--   In police, the officer never says what the charge is.
--   In shops, the buyer never says what anything costs.
--   In health, nobody says how much it hurt.
--   Here, nobody says who a message is from.
--
-- The sending number is the one the server has written on the character. There
-- is no `from` field, so there is nothing to spoof, which matters more here
-- than anywhere else: a message that appears to come from somebody else is not
-- a cosmetic bug, it is a way to get a person killed by their own crew.
--
-- Messages are kept here rather than on the record. Everything anybody ever
-- typed would bury a record whose value is that it is worth reading. What goes
-- on the record is a detective pulling a thread up, because a search with no
-- reason is a thing worth being able to find.

local Clock = require("core.clock")
local Characters = require("systems.characters")

local Phone = {}

local DEFAULT_LIMIT = 4000
local DEFAULT_ITEM = "phone"
local PREFIX = "555"
local DIGITS = 6

--- A number a person can read out. Derived from the character id so it is
--- stable for the life of the character and needs nothing stored to stay
--- unique, and checked against the ones already issued anyway.
function Phone.number_from(character_id, salt)
    local body = character_id:gsub("[^%w]", "")
    local digits, seed = {}, salt or 0
    for index = 1, DIGITS do
        local at = ((index + seed - 1) % #body) + 1
        digits[index] = tostring(((body:byte(at) or 48) + seed * index) % 10)
    end
    return ("%s-%s"):format(PREFIX, table.concat(digits))
end

--- opts.limit  how many messages stay in memory
--- opts.item   the item a phone is; nobody without one can use one
--- opts.issue  false to stop new characters being handed a phone
function Phone.system(opts)
    opts = opts or {}
    local limit = opts.limit or DEFAULT_LIMIT
    local item = opts.item or DEFAULT_ITEM
    local issue = opts.issue ~= false

    return {
        name = "phone",
        requires = { "characters", "memory", "inventory" },
        install = function(world)
            local people = world:repository(Characters.Character)
            local messages = {}        -- oldest first
            local by_number = {}       -- number -> character
            local threads = {}         -- number -> array of messages
            local sequence, dropped = 0, 0

            local function index_number(character, number)
                by_number[number] = character
            end

            local function number_of(character)
                local person = people:load(character)
                return person and person:get("phone") or nil
            end

            local function holder_of(number) return by_number[number] end

            local function reindex()
                by_number = {}
                for _, person in ipairs(people:all()) do
                    local number = person:get("phone")
                    if number then index_number(person.id, number) end
                end
            end

            --- Give somebody a number. Derived, then checked, because people
            --- type these and "effectively unique" is not good enough for
            --- something typed.
            local function assign(character)
                local person = people:load(character)
                if not person then return nil end
                if person:get("phone") then return person:get("phone") end
                for salt = 0, 64 do
                    local candidate = Phone.number_from(character, salt)
                    if not by_number[candidate] then
                        person:set("phone", candidate)
                        people:save(person)
                        index_number(character, candidate)
                        return candidate
                    end
                end
                return nil
            end

            local function remember_message(entry)
                messages[#messages + 1] = entry
                for _, number in ipairs({ entry.from, entry.to }) do
                    local thread = threads[number]
                    if not thread then
                        thread = {}
                        threads[number] = thread
                    end
                    thread[#thread + 1] = entry
                end
                while #messages > limit do
                    local oldest = table.remove(messages, 1)
                    dropped = dropped + 1
                    for _, number in ipairs({ oldest.from, oldest.to }) do
                        local thread = threads[number]
                        if thread then
                            for position, candidate in ipairs(thread) do
                                if candidate == oldest then
                                    table.remove(thread, position)
                                    break
                                end
                            end
                            if #thread == 0 then threads[number] = nil end
                        end
                    end
                end
            end

            local function between(one, other, count)
                local out = {}
                local thread = threads[one] or {}
                for position = #thread, 1, -1 do
                    local entry = thread[position]
                    if entry.from == other or entry.to == other then
                        out[#out + 1] = { at = entry.at, from = entry.from, to = entry.to,
                                          body = entry.body, sequence = entry.sequence }
                        if count and #out >= count then break end
                    end
                end
                return out
            end

            world.services.phone = {
                number_of = number_of,
                holder_of = holder_of,
                assign = assign,
                between = between,
                count = function() return #messages end,
                dropped = function() return dropped end,
            }

            world:persist_with("phone", {
                save = function()
                    local out = {}
                    for position, entry in ipairs(messages) do
                        out[position] = { at = entry.at, from = entry.from, to = entry.to,
                                          body = entry.body, sequence = entry.sequence }
                    end
                    return { messages = out, sequence = sequence, dropped = dropped }
                end,
                load = function(stored)
                    messages, threads = {}, {}
                    sequence = (stored or {}).sequence or 0
                    dropped = (stored or {}).dropped or 0
                    for _, entry in ipairs((stored or {}).messages or {}) do
                        if type(entry.from) ~= "string" or type(entry.to) ~= "string" then
                            return false, "a stored message has no sender or no recipient"
                        end
                        if math.type(entry.at) ~= "integer" then
                            return false, "a stored message did not happen at a whole millisecond"
                        end
                        remember_message({ at = entry.at, from = entry.from, to = entry.to,
                                           body = tostring(entry.body or ""),
                                           sequence = entry.sequence or 0 })
                    end
                    return true
                end,
            })

            world:on("world.loaded", function() reindex() end, { label = "phone:load" })

            if issue then
                world:on("character.created", function(payload)
                    assign(payload.character)
                    -- A phone is a thing you carry, so it is an item and can be
                    -- taken off you, which is the point.
                    if world.services.items:has(item) then
                        world.services.inventory:spawn(
                            ("phone:%s"):format(payload.character), payload.character, item, 1,
                            { reason = "first phone" })
                    end
                end, { label = "phone:issue" })
            end

            local function carrying(actor)
                if not world.services.items:has(item) then return true end
                return world.services.inventory:has(actor, item, 1)
            end

            world:define("phone.number", {
                summary = "your own number",
                rate = { per_minute = 20 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local mine = number_of(ctx.actor) or assign(ctx.actor)
                    if not mine then return ctx.refuse("no_number", "You have no number.") end
                    return ctx.ok({ number = mine, carrying = carrying(ctx.actor) })
                end,
            })

            world:define("phone.send", {
                summary = "send a message",
                rate = { per_minute = 30 },
                -- There is no `from` field. The sending number is the one the
                -- server wrote on this character, and a message that appears to
                -- come from somebody else is not a cosmetic bug: it is a way to
                -- get a person killed by their own crew.
                args = {
                    to = { type = "string", required = true, min = 4, max = 16 },
                    body = { type = "string", required = true, min = 1, max = 240 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not carrying(ctx.actor) then
                        return ctx.refuse("no_phone", "You do not have a phone on you.")
                    end
                    local mine = number_of(ctx.actor) or assign(ctx.actor)
                    if not mine then return ctx.refuse("no_number", "You have no number.") end
                    if args.to == mine then
                        return ctx.refuse("not_yourself", "That is your own number.")
                    end
                    -- Looked up before anything is written down, so a wrong
                    -- number is a wrong number and not a message into the void.
                    if not holder_of(args.to) then
                        return ctx.refuse("no_such_number", "Nobody answers on that number.")
                    end

                    sequence = sequence + 1
                    remember_message({ at = ctx.now, from = mine, to = args.to,
                                       body = args.body, sequence = sequence })
                    ctx.emit("phone.message", { from = mine, to = args.to,
                        sender = ctx.actor, recipient = holder_of(args.to) })
                    return ctx.ok({ from = mine, to = args.to, sequence = sequence })
                end,
            })

            world:define("phone.thread", {
                read_only = true,
                summary = "what was said between you and one number",
                rate = { per_minute = 30 },
                args = {
                    with = { type = "string", required = true, min = 4, max = 16 },
                    limit = { type = "integer", default = 30, min = 1, max = 100 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not carrying(ctx.actor) then
                        return ctx.refuse("no_phone", "You do not have a phone on you.")
                    end
                    local mine = number_of(ctx.actor)
                    if not mine then return ctx.refuse("no_number", "You have no number.") end
                    -- Only threads your own number is in. There is no argument
                    -- that names whose thread to read, so there is no way to
                    -- ask for anybody else's.
                    return ctx.ok({ number = mine, with = args.with,
                                    messages = between(mine, args.with, args.limit) })
                end,
            })

            world:define("phone.inbox", {
                read_only = true,
                summary = "who has been in touch",
                rate = { per_minute = 20 },
                args = { limit = { type = "integer", default = 20, min = 1, max = 50 } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not carrying(ctx.actor) then
                        return ctx.refuse("no_phone", "You do not have a phone on you.")
                    end
                    local mine = number_of(ctx.actor)
                    if not mine then return ctx.refuse("no_number", "You have no number.") end
                    local thread, seen, out = threads[mine] or {}, {}, {}
                    for position = #thread, 1, -1 do
                        local entry = thread[position]
                        local other = entry.from == mine and entry.to or entry.from
                        if not seen[other] then
                            seen[other] = true
                            out[#out + 1] = { number = other, at = entry.at,
                                              last = entry.body, outgoing = entry.from == mine }
                            if #out >= args.limit then break end
                        end
                    end
                    return ctx.ok({ number = mine, threads = out })
                end,
            })

            -- The mobile data terminal side. Only defined when there is a
            -- police system to gate it, and gated by being on duty rather than
            -- by holding a phone, because this is a terminal in a car.
            if world:has("police") then
                world:define("mdt.messages", {
                    summary = "pull up a thread between two numbers",
                    rate = { per_minute = 10 },
                    args = {
                        number = { type = "string", required = true, min = 4, max = 16 },
                        with = { type = "string", min = 4, max = 16 },
                        limit = { type = "integer", default = 30, min = 1, max = 100 },
                    },
                    handler = function(ctx, args)
                        if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                        if not world.services.police.is_on_duty(ctx.actor) then
                            return ctx.refuse("not_on_duty", "You are not on duty.")
                        end
                        local holder = holder_of(args.number)
                        if not holder then
                            return ctx.refuse("no_such_number", "That number is not in service.")
                        end
                        local found
                        if args.with then
                            found = between(args.number, args.with, args.limit)
                        else
                            local thread, out = threads[args.number] or {}, {}
                            for position = #thread, 1, -1 do
                                local entry = thread[position]
                                out[#out + 1] = { at = entry.at, from = entry.from,
                                                  to = entry.to, body = entry.body }
                                if #out >= args.limit then break end
                            end
                            found = out
                        end
                        -- Pulling a thread up is itself a thing the city keeps,
                        -- because a search with no reason is worth finding.
                        world.services.remember(
                            ("mdt:%s:%s:%d"):format(ctx.actor, args.number, ctx.now), {
                            subject = ctx.actor, kind = "police.lookup", weight = 0,
                            involved = { holder },
                            meta = { number = args.number, terminal = true },
                        })
                        return ctx.ok({ number = args.number, holder = holder, messages = found })
                    end,
                })
            end
        end,
    }
end

return Phone
