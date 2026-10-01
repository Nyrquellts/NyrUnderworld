--- Being caught, and what it costs.
--
-- The record and standing systems are the memory half of consequence. This is
-- the acting half, and it is built on the same rule that work is built on,
-- pointed the other way.
--
--   In work, the player never says what a job pays.
--   Here, the officer never says what the charge is.
--
-- An arrest names a person and nothing else. The server works out what they
-- are wanted for by reading the record, looks up what each offence costs from
-- its own table, and applies that. There is no charge argument and no fine
-- argument, so an officer cannot invent either, and neither can anybody who
-- has read the net event names out of the resource.
--
-- What somebody is wanted for is derived rather than stored: it is the crimes
-- on their record, that somebody saw, since the last time they were arrested.
-- Nothing has to be kept in step, nothing can drift, and an arrest closes the
-- lot of it by being written down after them.
--
-- Being an officer is not something a client claims either. A commission is
-- granted by the server; going on duty only works if you hold one.

local Clock = require("core.clock")
local Money = require("domain.money")
local Characters = require("systems.characters")

local Police = {}

local COURT = "external:court"
local MINUTE = Clock.MS_PER_MINUTE
local CRIME = "crime."

--- What each offence costs. A server owner replaces this; the shape is what
--- matters. Fines are whole minor units, time is whole city minutes.
local DEFAULT_OFFENCES = {
    ["crime.robbery"] = { fine = 50000, minutes = 15, label = "robbery" },
    ["crime.burglary"] = { fine = 35000, minutes = 10, label = "burglary" },
    ["crime.vehicle_theft"] = { fine = 40000, minutes = 12, label = "taking a vehicle" },
    ["crime.handling"] = { fine = 20000, minutes = 6, label = "handling stolen goods" },
    ["crime.assault"] = { fine = 25000, minutes = 8, label = "assault" },
    ["crime.murder"] = { fine = 150000, minutes = 45, label = "murder" },
}

Police.DEFAULT_OFFENCES = DEFAULT_OFFENCES

local function check_offences(source)
    local offences = {}
    for kind, offence in pairs(source) do
        assert(type(kind) == "string" and kind:match("^%l[%l%d_]*%.[%l%d_]+$"),
            ("%s is not a record kind"):format(tostring(kind)))
        assert(math.type(offence.fine) == "integer" and offence.fine >= 0,
            ("%s has a fine that is not whole minor units"):format(kind))
        assert(math.type(offence.minutes) == "integer" and offence.minutes >= 0,
            ("%s has a sentence that is not whole minutes"):format(kind))
        offences[kind] = { fine = offence.fine, minutes = offence.minutes,
                           label = offence.label or kind }
    end
    return offences
end

--- opts.offences  the offence table
--- opts.authority the standing party heat is measured against
function Police.system(opts)
    opts = opts or {}
    local offences = check_offences(opts.offences or DEFAULT_OFFENCES)
    local authority = opts.authority or "police"

    return {
        name = "police",
        requires = { "characters", "memory" },
        install = function(world)
            local commissioned = {}    -- character -> true, persisted
            local on_duty = {}         -- character -> true, not persisted
            local detained = {}        -- character -> city time they are out

            local function near(actor, target)
                local check = world.services.proximity
                if type(check) ~= "function" then return nil end
                return check(actor, target) == true
            end

            --- The last time somebody was arrested. Their own arrest only: an
            --- officer is named on every arrest they make, and reading that as
            --- the officer's own closed everything the officer had done.
            local function last_arrest(subject)
                return world.services.record:about(subject,
                    { kind = "police.arrest", involved = false, limit = 1 })[1]
            end

            --- Whether a line is something to be wanted for at all: an
            --- offence, that somebody saw.
            local function chargeable(entry)
                return offences[entry.kind] ~= nil and entry.kind:sub(1, #CRIME) == CRIME
                    and #entry.witnesses > 0
            end

            --- Whether a line was written after an arrest, or there was none.
            ---
            --- "After" is the order the record wrote things down, not the
            --- clock. Everything between two server ticks happens in one city
            --- millisecond, so by the clock a punch thrown in the tick of an
            --- arrest came neither before it nor after, and was never charged.
            local function after(entry, arrest)
                return arrest == nil or entry.sequence > arrest.sequence
            end

            --- The crimes somebody is wanted for: what is on their record,
            --- that somebody saw, since the last time they were arrested.
            --- Derived, so nothing has to be kept in step and nothing drifts.
            ---
            --- Only what they did. The record finds a crime from the victim's
            --- side too, which is how a body gets a name, and counting that
            --- fined a murdered woman for her own murder and a car's owner for
            --- having it taken.
            local function wanted_for(subject)
                local arrest = last_arrest(subject)
                local found = {}
                for _, entry in ipairs(world.services.record:about(subject,
                        { prefix = CRIME, witnessed = true, involved = false })) do
                    if chargeable(entry) and after(entry, arrest) then found[#found + 1] = entry end
                end
                return found
            end

            local function charges_for(subject)
                local fine, minutes, labels = 0, 0, {}
                for _, entry in ipairs(wanted_for(subject)) do
                    local offence = offences[entry.kind]
                    fine = fine + offence.fine
                    minutes = minutes + offence.minutes
                    labels[#labels + 1] = offence.label
                end
                return fine, minutes, labels
            end

            -- A warrant is a line in the record's window, and the window lets
            -- its oldest lines go. Anything that writes lines could push one
            -- out -- an officer searching often enough pushed their own
            -- witnessed murder out, and with it every warrant for it -- so a
            -- line stays for as long as somebody is wanted for it, and goes the
            -- way everything else does once an arrest has closed it. Only an
            -- arrest can close one, so only an arrest has it asked again.
            -- Finding somebody's last arrest walks everything about them, so
            -- it is asked only of a line that could be a warrant at all.
            world.services.record:hold(function(entry)
                return chargeable(entry) and after(entry, last_arrest(entry.subject))
            end, { "police.arrest" })

            world.services.police = {
                offences = offences,
                wanted_for = wanted_for,
                charges_for = charges_for,
                is_officer = function(character) return commissioned[character] == true end,
                is_on_duty = function(character) return on_duty[character] == true end,
                --- Make somebody an officer. Not a command: a commission comes
                --- from the server, never from a client asking for one.
                commission = function(character, granted)
                    if granted == false then
                        commissioned[character] = nil
                        on_duty[character] = nil
                        return false
                    end
                    commissioned[character] = true
                    return true
                end,
                detained_until = function(character)
                    local until_at = detained[character]
                    if not until_at then return nil end
                    if until_at <= world.clock:now() then
                        detained[character] = nil
                        return nil
                    end
                    return until_at
                end,
                officers = function()
                    local out = {}
                    for character in pairs(on_duty) do out[#out + 1] = character end
                    table.sort(out)
                    return out
                end,
            }

            world:persist_with("police", {
                save = function()
                    local held = {}
                    for character, until_at in pairs(detained) do held[character] = until_at end
                    local badges = {}
                    for character in pairs(commissioned) do badges[#badges + 1] = character end
                    table.sort(badges)
                    return { detained = held, commissioned = badges }
                end,
                load = function(stored)
                    detained, commissioned, on_duty = {}, {}, {}
                    for character, until_at in pairs((stored or {}).detained or {}) do
                        if math.type(until_at) ~= "integer" then
                            return false, ("%s has a release time that is not whole"):format(character)
                        end
                        detained[character] = until_at
                    end
                    for _, character in ipairs((stored or {}).commissioned or {}) do
                        commissioned[character] = true
                    end
                    -- Nobody comes back on duty after a restart. A roster that
                    -- survives one says officers are out there when they are not.
                    return true
                end,
            })

            world:define("police.duty", {
                summary = "go on or off duty",
                rate = { per_minute = 10 },
                args = { on = { type = "boolean", default = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not commissioned[ctx.actor] then
                        return ctx.refuse("not_an_officer", "You do not hold a commission.")
                    end
                    on_duty[ctx.actor] = args.on or nil
                    ctx.emit("police.duty", { officer = ctx.actor, on = args.on })
                    return ctx.ok({ on = args.on })
                end,
            })

            world:define("police.arrest", {
                summary = "arrest somebody you are standing next to",
                rate = { per_minute = 20 },
                -- A person and nothing else. No charge, no fine, no sentence:
                -- there is nothing here for an officer to invent.
                args = { suspect = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not on_duty[ctx.actor] then
                        return ctx.refuse("not_on_duty", "You are not on duty.")
                    end
                    if args.suspect == ctx.actor then
                        return ctx.refuse("not_yourself", "You cannot arrest yourself.")
                    end
                    local people = world:repository(Characters.Character)
                    local suspect = people:load(args.suspect)
                    if not suspect then return ctx.refuse("no_such_person", "There is no such person.") end
                    if world.services.police.detained_until(args.suspect) then
                        return ctx.refuse("already_held", "They are already inside.")
                    end

                    local at = near(ctx.actor, args.suspect)
                    if at == nil then
                        return ctx.refuse("no_proximity", "The server cannot tell where you are.")
                    end
                    if not at then return ctx.refuse("too_far", "They are not here.") end

                    local fine, minutes, labels = charges_for(args.suspect)
                    if #labels == 0 then
                        return ctx.refuse("no_warrant", "There is nothing on them.")
                    end

                    -- Take what they have toward the fine. What they cannot pay
                    -- is recorded as unpaid, never as a negative balance: the
                    -- books have to keep summing to nothing.
                    local wallet = Characters.wallet(args.suspect)
                    local held = world.ledger:balance(wallet)
                    local owed = Money.from_minor(fine)
                    local taken = owed
                    if held < owed then taken = held end
                    -- The fine and the arrest go under this command's operation
                    -- id. Named by the suspect and the city millisecond, a second
                    -- arrest in the same server tick was told it was fined and
                    -- paid nothing, and was never written down.
                    if taken:is_positive() then
                        world.ledger:transfer(
                            ("fine:%s"):format(ctx.operation_id),
                            wallet, COURT, taken,
                            { reason = "fine", offences = table.concat(labels, ", ") })
                    end

                    local out_at = ctx.now + minutes * MINUTE
                    detained[args.suspect] = out_at

                    -- The arrest is written after the crimes, so it is what
                    -- closes them: wanted_for reads everything since the last
                    -- one. The crimes themselves stay on the record for good.
                    world.services.remember(("arrest:%s"):format(ctx.operation_id), {
                        subject = args.suspect, kind = "police.arrest",
                        weight = math.min(100, #labels * 10),
                        involved = { ctx.actor },
                        meta = {
                            officer = ctx.actor,
                            offences = table.concat(labels, ", "),
                            count = #labels,
                            fined = taken:to_minor(),
                            unpaid = owed:sub(taken):to_minor(),
                            minutes = minutes,
                            -- Exactly the heat there was, so being caught
                            -- clears what they were being looked for about
                            -- rather than a fixed amount that might not.
                            cleared = world.services.standing:heat(args.suspect, authority),
                        },
                    })

                    ctx.emit("police.arrested", {
                        suspect = args.suspect, officer = ctx.actor,
                        offences = labels, fined = taken:to_minor(),
                        unpaid = owed:sub(taken):to_minor(), minutes = minutes, out_at = out_at,
                    })
                    return ctx.ok({ offences = labels, fined = taken:to_minor(),
                                    unpaid = owed:sub(taken):to_minor(), minutes = minutes })
                end,
            })

            world:define("police.lookup", {
                summary = "pull up what the city has on somebody",
                rate = { per_minute = 30 },
                args = {
                    suspect = { type = "id", kind = "chr", required = true },
                    limit = { type = "integer", default = 20, min = 1, max = 100 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not on_duty[ctx.actor] then
                        return ctx.refuse("not_on_duty", "You are not on duty.")
                    end
                    -- Every search is a line on the record, so a search for an
                    -- id nobody has was a line about nobody: thirty a minute of
                    -- made-up people, filling the window the warrants live in.
                    if not world:repository(Characters.Character):load(args.suspect) then
                        return ctx.refuse("no_such_person", "There is no such person.")
                    end
                    local found = world.services.record:about(args.suspect, { limit = args.limit })
                    local summary = {}
                    for position, entry in ipairs(found) do
                        summary[position] = { at = entry.at, kind = entry.kind, place = entry.place,
                                              weight = entry.weight, witnessed = #entry.witnesses > 0 }
                    end
                    local fine, minutes, labels = charges_for(args.suspect)
                    -- Looking somebody up is itself a thing the city remembers,
                    -- because a search with no reason is a thing worth finding.
                    world.services.remember(("lookup:%s:%s:%d"):format(ctx.actor, args.suspect, ctx.now), {
                        subject = ctx.actor, kind = "police.lookup", weight = 0,
                        involved = { args.suspect },
                    })
                    return ctx.ok({
                        records = summary,
                        heat = world.services.standing:heat(args.suspect, authority),
                        wanted_for = labels, fine = fine, minutes = minutes,
                        detained_until = world.services.police.detained_until(args.suspect),
                    })
                end,
            })

            if world:has("vehicles") then
                world:define("police.seize", {
                    summary = "have a car taken to the impound lot",
                    rate = { per_minute = 10 },
                    args = { vehicle = { type = "id", kind = "veh", required = true } },
                    handler = function(ctx, args)
                        if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                        if not on_duty[ctx.actor] then
                            return ctx.refuse("not_on_duty", "You are not on duty.")
                        end
                        local at = near(ctx.actor, args.vehicle)
                        if at == nil then
                            return ctx.refuse("no_proximity", "The server cannot tell where you are.")
                        end
                        if not at then return ctx.refuse("too_far", "You are not at it.") end
                        -- Under this command's operation id: named by the car
                        -- and the city millisecond, a car seized, paid out and
                        -- seized again in one server tick was on the record once.
                        local ok, why = world.services.vehicles.impound(
                            ("seize:%s"):format(ctx.operation_id), args.vehicle, "seized")
                        if not ok then return ctx.refuse("cannot_seize", why) end
                        ctx.emit("police.seized", { vehicle = args.vehicle, officer = ctx.actor })
                        return ctx.ok()
                    end,
                })
            end

            -- Let people out when their time is up.
            world:every(MINUTE, function()
                local now = world.clock:now()
                for character, until_at in pairs(detained) do
                    if until_at <= now then
                        detained[character] = nil
                        world.events:emit("police.released", { character = character, at = now })
                    end
                end
            end, "police:release")

            -- Going off the server is going off duty. A roster that outlives a
            -- session says officers are out there when they are not.
            world:on("character.released", function(payload)
                on_duty[payload.character] = nil
            end, { label = "police:off_duty" })
        end,
    }
end

return Police
