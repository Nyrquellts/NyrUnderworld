--- Being hurt, going down, bleeding out, and coming back.
--
-- This closes the same gap for violence that shops closed for theft.
-- `crime.assault` and `crime.murder` have both had a consequence line and a
-- price in the offence table since before anything in the city could produce
-- either, because nothing could be hurt. Now something can, and police and the
-- record handle it with no change to either.
--
-- The rule, a fourth time and pointed at damage:
--
--   In work, the player never says what a job pays.
--   In police, the officer never says what the charge is.
--   In shops, the buyer never says what anything costs.
--   Here, nobody says how much it hurt.
--
-- There is no command that takes an amount of damage. Damage arrives as a
-- service call from the adapter, which reads it off the server's own copy of
-- what happened to a ped. A command with a damage field would be a command
-- that lets anybody kill anybody from anywhere, and it is the single most
-- obvious thing to reach for when a resource exposes a net event.
--
-- Two states short of dead, on purpose. Being **down** is recoverable by
-- somebody else and is what makes a medic a role rather than a costume; being
-- **dead** is not, and costs a trip to a hospital. A city where a fight ends
-- instantly in death has no room for anybody to intervene.

local Clock = require("core.clock")
local Money = require("domain.money")
local Characters = require("systems.characters")

local Health = {}

local MAX_HP = 100
-- Real time, both of them: a medic runs to a body and a fight is thrown in real
-- seconds. They were city time, and at the pace config.lua ships -- sixty city
-- milliseconds to a real one -- five minutes of bleeding was five real seconds,
-- so nobody was ever revived in time, and a beating's one-minute incident was
-- one real second, so every punch two seconds apart was its own assault. Every
-- spec ran at a rate of one, where the two are the same number.
local DEFAULT_BLEED_MS = 5 * Clock.MS_PER_MINUTE
local DEFAULT_REVIVE_HP = 25
local DEFAULT_RESPAWN_HP = 60
local DEFAULT_RESPAWN_FEE = 50000        -- five hundred, in minor units
local DEFAULT_INCIDENT_MS = 60 * Clock.MS_PER_SECOND
local DEFAULT_KIT = "bandage"
local HOSPITAL = "external:hospital"

Health.MAX_HP = MAX_HP

--- opts.bleed_ms     how long somebody stays down before dying, in real milliseconds
--- opts.revive_hp    what a revive brings them back to
--- opts.respawn_hp   what a hospital sends them out with
--- opts.respawn_fee  what the hospital charges, in minor units
--- opts.incident_ms  how close two hits have to be to be one assault, in real milliseconds
--- opts.kit          the item a revive costs
function Health.system(opts)
    opts = opts or {}
    local bleed_ms = opts.bleed_ms or DEFAULT_BLEED_MS
    local revive_hp = opts.revive_hp or DEFAULT_REVIVE_HP
    local respawn_hp = opts.respawn_hp or DEFAULT_RESPAWN_HP
    local respawn_fee = opts.respawn_fee or DEFAULT_RESPAWN_FEE
    local incident_ms = opts.incident_ms or DEFAULT_INCIDENT_MS
    local kit = opts.kit or DEFAULT_KIT
    assert(math.type(bleed_ms) == "integer" and bleed_ms > 0, "a bleed-out time is whole milliseconds")
    assert(math.type(revive_hp) == "integer" and revive_hp > 0 and revive_hp <= MAX_HP,
        "a revive brings somebody back to between one and full health")

    return {
        name = "health",
        requires = { "characters", "memory", "inventory" },
        install = function(world)
            local people = world:repository(Characters.Character)
            -- character -> { hp, state, down_at, incidents = { attacker -> at } }
            local sheets = {}

            -- Real time as city time at the pace the city is running now,
            -- rounded up: the same reckoning reach uses in systems/inventory.
            -- The clock is asked every time, because loading a saved city
            -- replaces it.
            local function city_span(real_ms)
                return math.ceil(real_ms * world.clock:rate())
            end

            -- A sheet is made when something happens to somebody, and only
            -- then. Made on every read, one was saved for every id anybody
            -- asked about: the status line every screen draws, and a revive
            -- aimed at made-up ids, refused, twelve times a minute, growing
            -- the saved city without end.
            local function sheet(character)
                local found = sheets[character]
                if not found then
                    found = { hp = MAX_HP, state = "well", down_at = nil, incidents = {} }
                    sheets[character] = found
                end
                return found
            end

            --- What a read sees: the sheet, or somebody nothing has happened to.
            --- Never stored, so a read or a refusal leaves nothing behind.
            local function peek(character)
                return sheets[character] or { hp = MAX_HP, state = "well", down_at = nil, incidents = {} }
            end

            local function is_playing(character)
                local person = people:load(character)
                return person ~= nil and (person.state == "active" or person.state == "dead"), person
            end

            local function witnesses_at(subject, given)
                if given ~= nil then
                    local seen = {}
                    for _, who in ipairs(given) do
                        if who ~= subject then seen[#seen + 1] = who end
                    end
                    return seen
                end
                local look = world.services.witnesses
                if type(look) ~= "function" then return {} end
                local seen = {}
                for _, who in ipairs(look(subject) or {}) do
                    if who ~= subject then seen[#seen + 1] = who end
                end
                return seen
            end

            -- One incident, not one record per hit. A beating is a crime; it is
            -- not forty crimes, and forty records would bury the one that
            -- matters under the noise of the ones that do not.
            local function record_assault(subject, attacker, now, seen, cause)
                local card = sheet(subject)
                local last = card.incidents[attacker]
                if last and now - last < city_span(incident_ms) then return false end
                card.incidents[attacker] = now
                world.services.remember(("assault:%s:%s:%d"):format(attacker, subject, now), {
                    subject = attacker, kind = "crime.assault", weight = 20,
                    involved = { subject }, witnesses = seen,
                    meta = { victim = subject, cause = cause },
                })
                return true
            end

            local function die(character, card, now, by, cause, seen)
                card.hp = 0
                card.state = "dead"
                card.down_at = nil
                local person = people:load(character)
                if person and person.state == "active" then
                    person:transition("dead", { reason = cause or "killed" })
                    people:save(person)
                end
                if by then
                    world.services.remember(("murder:%s:%s:%d"):format(by, character, now), {
                        subject = by, kind = "crime.murder", weight = 80,
                        involved = { character }, witnesses = seen,
                        meta = { victim = character, cause = cause },
                    })
                end
                world.events:emit("character.died",
                    { character = character, by = by, cause = cause, witnessed = #(seen or {}) > 0 })
            end

            world.services.health = {
                MAX_HP = MAX_HP,
                --- What the server knows about somebody.
                status = function(character)
                    local card = peek(character)
                    return { hp = card.hp, state = card.state, down_at = card.down_at,
                             bleeds_at = card.down_at and (card.down_at + city_span(bleed_ms)) or nil }
                end,
                is_down = function(character) return peek(character).state == "down" end,
                is_dead = function(character) return peek(character).state == "dead" end,

                --- Hurt somebody. A service and not a command, because a
                --- command with a damage field lets anybody kill anybody from
                --- anywhere. The adapter calls this from the server's own copy
                --- of what happened.
                harm = function(operation_id, subject, amount, harm_opts)
                    harm_opts = harm_opts or {}
                    if type(operation_id) ~= "string" or operation_id == "" then
                        error("every injury needs an operation id", 2)
                    end
                    if math.type(amount) ~= "integer" or amount <= 0 then
                        error(("damage is a whole number above zero; got %s"):format(tostring(amount)), 2)
                    end
                    local playing = is_playing(subject)
                    if not playing then return nil, "there is no such person" end

                    local card = sheet(subject)
                    if card.state == "dead" then return nil, "they are already dead" end

                    local now = world.clock:now()
                    local seen = witnesses_at(subject, harm_opts.witnesses)
                    if harm_opts.by and harm_opts.by ~= subject then
                        record_assault(subject, harm_opts.by, now, seen, harm_opts.cause)
                    end

                    if card.state == "down" then
                        -- Already down. More damage finishes it rather than
                        -- taking a second helping off a health value that is
                        -- already nothing.
                        die(subject, card, now, harm_opts.by, harm_opts.cause, seen)
                        return world.services.health.status(subject)
                    end

                    card.hp = math.max(0, card.hp - amount)
                    if card.hp > 0 then
                        world.events:emit("character.hurt", { character = subject, by = harm_opts.by,
                            cause = harm_opts.cause, hp = card.hp })
                        return world.services.health.status(subject)
                    end

                    card.state = "down"
                    card.down_at = now
                    world.events:emit("character.down", { character = subject, by = harm_opts.by,
                        cause = harm_opts.cause, bleeds_at = now + city_span(bleed_ms),
                        witnessed = #seen > 0 })
                    return world.services.health.status(subject)
                end,

                --- Mend somebody. Also a service: what heals and by how much is
                --- the server's business.
                heal = function(operation_id, subject, amount)
                    if math.type(amount) ~= "integer" or amount <= 0 then
                        error("healing is a whole number above zero", 2)
                    end
                    local card = sheets[subject]
                    -- No sheet is nobody hurt, and nothing to mend.
                    if not card then return world.services.health.status(subject) end
                    if card.state ~= "well" then return nil, "they are not on their feet" end
                    card.hp = math.min(MAX_HP, card.hp + amount)
                    return world.services.health.status(subject)
                end,

                --- Kill outright, for a fall, a drowning, an explosion: things
                --- with no attacker and no meaningful health value left.
                kill = function(operation_id, subject, cause, by)
                    local playing = is_playing(subject)
                    if not playing then return nil, "there is no such person" end
                    local card = sheet(subject)
                    if card.state == "dead" then return nil, "they are already dead" end
                    die(subject, card, world.clock:now(), by, cause,
                        witnesses_at(subject, nil))
                    return world.services.health.status(subject)
                end,
            }

            world:persist_with("health", {
                save = function()
                    local out = {}
                    for character, card in pairs(sheets) do
                        local incidents = {}
                        for attacker, at in pairs(card.incidents) do incidents[attacker] = at end
                        out[character] = { hp = card.hp, state = card.state,
                                           down_at = card.down_at, incidents = incidents }
                    end
                    return { sheets = out }
                end,
                load = function(stored)
                    sheets = {}
                    for character, card in pairs((stored or {}).sheets or {}) do
                        if math.type(card.hp) ~= "integer" then
                            return false, ("%s has a health value that is not whole"):format(character)
                        end
                        local incidents = {}
                        for attacker, at in pairs(card.incidents or {}) do
                            if math.type(at) == "integer" then incidents[attacker] = at end
                        end
                        -- A sheet that says nothing ever happened is no sheet.
                        -- Before reads stopped making them, every look at
                        -- anybody's health and every refused revive of a made-up
                        -- id wrote one into the save; a city saved then sheds
                        -- them here instead of carrying them for good.
                        local untouched = card.hp == MAX_HP and (card.state == nil or card.state == "well")
                            and card.down_at == nil and next(incidents) == nil
                        if not untouched then
                            -- Somebody who was down when the server stopped is
                            -- put back on their feet rather than bled out during
                            -- the downtime. They could not act on it, so it is
                            -- not theirs to lose.
                            local state = card.state
                            local hp, down_at = card.hp, card.down_at
                            if state == "down" then
                                state, hp, down_at = "well", revive_hp, nil
                            end
                            sheets[character] = { hp = hp, state = state,
                                                  down_at = down_at, incidents = incidents }
                        end
                    end
                    return true
                end,
            })

            world:define("health.status", {
                read_only = true,
                summary = "how you are doing",
                rate = { per_minute = 60 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    return ctx.ok(world.services.health.status(ctx.actor))
                end,
            })

            world:define("health.revive", {
                summary = "bring somebody who is down back to their feet",
                rate = { per_minute = 12 },
                -- A person and nothing else. What a revive restores is the
                -- server's decision, not the medic's.
                args = { target = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if args.target == ctx.actor then
                        return ctx.refuse("not_yourself", "You cannot do that to yourself.")
                    end
                    local card = peek(args.target)
                    if card.state == "dead" then
                        return ctx.refuse("too_late", "They are gone. They need a hospital.")
                    end
                    if card.state ~= "down" then
                        return ctx.refuse("not_down", "They are on their feet.")
                    end

                    local check = world.services.proximity
                    if type(check) ~= "function" then
                        return ctx.refuse("no_proximity", "The server cannot tell where you are.")
                    end
                    if check(ctx.actor, args.target) ~= true then
                        return ctx.refuse("too_far", "You are not next to them.")
                    end

                    local inventory = world.services.inventory
                    if not inventory:has(ctx.actor, kit, 1) then
                        return ctx.refuse("no_kit", "You have nothing to treat them with.")
                    end
                    -- Under this command's operation id. Named by the patient and
                    -- the city millisecond, a second medic in the same server tick
                    -- built the first medic's id for a different pocket and the
                    -- inventory threw, and the same medic twice used one bandage.
                    local used = inventory:destroy(
                        ("revive:%s"):format(ctx.operation_id), ctx.actor, kit, 1,
                        { reason = "used treating somebody" })
                    if not used then return ctx.refuse("no_kit", "You have nothing to treat them with.") end

                    card.state = "well"
                    card.hp = revive_hp
                    card.down_at = nil
                    ctx.emit("character.revived", { character = args.target, by = ctx.actor, hp = revive_hp })
                    return ctx.ok({ target = args.target, hp = revive_hp })
                end,
            })

            world:define("health.respawn", {
                summary = "wake up at the hospital",
                rate = { per_minute = 6 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local card = peek(ctx.actor)
                    if card.state ~= "dead" then
                        return ctx.refuse("not_dead", "You are not dead.")
                    end

                    -- The bill is taken from what they can pay, never leaving a
                    -- wallet negative, because a negative wallet is money that
                    -- does not exist and the books would stop summing to
                    -- nothing. Nobody is kept dead for being broke.
                    local owed = Money.from_minor(respawn_fee)
                    local held = world.ledger:balance(Characters.wallet(ctx.actor))
                    local taken = held < owed and held or owed
                    -- Under this command's operation id: named by who and the
                    -- city millisecond, a second respawn in one server tick was
                    -- told it had paid and paid nothing.
                    if taken:is_positive() then
                        world.ledger:transfer(("hospital:%s"):format(ctx.operation_id),
                            Characters.wallet(ctx.actor), HOSPITAL, taken,
                            { reason = "hospital" })
                    end

                    card.state = "well"
                    card.hp = respawn_hp
                    card.down_at = nil
                    card.incidents = {}
                    local person = people:load(ctx.actor)
                    if person and person.state == "dead" then
                        person:transition("active", { reason = "discharged" })
                        people:save(person)
                    end
                    ctx.emit("character.respawned", { character = ctx.actor, hp = respawn_hp,
                        paid = taken:to_minor(), unpaid = owed:sub(taken):to_minor() })
                    return ctx.ok({ hp = respawn_hp, paid = taken:to_minor() })
                end,
            })

            -- Bleeding out. Checked on a schedule rather than with a timer per
            -- person, so a thousand downed players is one loop and not a
            -- thousand pending callbacks.
            world:every(10 * Clock.MS_PER_SECOND, function()
                local now = world.clock:now()
                for character, card in pairs(sheets) do
                    if card.state == "down" and card.down_at and now - card.down_at >= city_span(bleed_ms) then
                        die(character, card, now, nil, "bled out", {})
                    end
                end
            end, "health:bleed")

            world:on("character.released", function(payload)
                -- Logging out does not heal anybody, but it does end whatever
                -- incident was running, so coming back tomorrow is not still
                -- the same fight.
                local card = sheets[payload.character]
                if card then card.incidents = {} end
            end, { label = "health:release" })
        end,
    }
end

return Health
