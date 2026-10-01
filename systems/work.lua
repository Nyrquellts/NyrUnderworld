--- Legal work, and the one rule every exploited server gets wrong.
--
-- A client finishes a job and tells the server so. The temptation is to let it
-- say what the job was worth, because the client already knows and the server
-- would have to look it up. Every server that gives in to that gets robbed,
-- usually within a week, usually by somebody who read the net event names out
-- of the resource.
--
-- So: **the payout is never taken from a completion report.** A client says "I
-- am done". The server finds the shift it opened, checks it belongs to whoever
-- is asking, checks the clock says enough time has passed, looks up what that
-- job pays from its own configuration, and moves that much money through the
-- ledger. There is no payout argument to validate, because there is no payout
-- argument.
--
-- The rest follows the same principle. The server decides when a shift
-- started, whether one is already open, whether the cooldown has passed, and
-- whether the employer can actually pay. The client decides nothing except
-- when to ask.
--
-- Finished shifts go on the record, so a work history is something the city
-- holds rather than something a player claims.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local Work = {}

local MINUTE = Clock.MS_PER_MINUTE
local PAYROLL = "external:payroll"

Work.Employer = Entity.define("emp", {
    fields = {
        name = { type = "string", required = true, max = 48 },
        -- An employer outside the simulated economy: a delivery company whose
        -- clients are out of town. Their wages enter the world across a named
        -- account, so the books still balance and the entry is auditable.
        -- A player-owned business is not external and pays from what it holds.
        external = { type = "boolean", default = false },
        offers = { type = "table", required = true },
    },
    states = { hiring = { "closed" }, closed = { "hiring" } },
    initial = "hiring",
})

Work.Shift = Entity.define("shf", {
    fields = {
        worker = { type = "id", kind = "chr", required = true },
        employer = { type = "id", kind = "emp", required = true },
        job = { type = "string", required = true, max = 32 },
        started = { type = "integer", required = true, min = 0 },
        pay = { type = "integer", min = 0 },
    },
    states = {
        open = { "finished", "abandoned", "expired" },
        finished = {}, abandoned = {}, expired = {},
    },
    initial = "open",
})

--- The jobs a plain server offers. A server owner replaces this wholesale.
--- Pay is whole minor units, decided here and nowhere else.
local DEFAULT_JOBS = {
    delivery = { label = "Delivery Driver", pay = 12000, duration = 12 * MINUTE,
                 cooldown = 5 * MINUTE, expires = 2 * Clock.MS_PER_HOUR },
    refuse = { label = "Refuse Collection", pay = 9000, duration = 15 * MINUTE,
               cooldown = 5 * MINUTE, expires = 2 * Clock.MS_PER_HOUR },
    bartender = { label = "Bartender", pay = 15000, duration = 20 * MINUTE,
                  cooldown = 10 * MINUTE, expires = 3 * Clock.MS_PER_HOUR },
}

Work.DEFAULT_JOBS = DEFAULT_JOBS

function Work.account(employer)
    if employer:get("external") then return PAYROLL end
    return "emp:" .. employer.id
end

-- The table is copied, not aliased. A server that adjusts what a job pays, or
-- a system that drops one at run time, must not reach into the defaults every
-- other world is also using.
local function check_jobs(source)
    local jobs = {}
    for key, job in pairs(source) do
        local copy = {}
        for field, value in pairs(job) do copy[field] = value end
        jobs[key] = copy
    end
    for key, job in pairs(jobs) do
        assert(type(key) == "string" and key:match("^%l[%l%d_]*$"),
            ("job key %s is not lowercase letters, digits and underscores"):format(tostring(key)))
        assert(type(job.label) == "string" and job.label ~= "", ("job %s needs a label"):format(key))
        assert(math.type(job.pay) == "integer" and job.pay >= 0,
            ("job %s pays whole minor units"):format(key))
        assert(math.type(job.duration) == "integer" and job.duration > 0,
            ("job %s takes a whole number of city milliseconds"):format(key))
        assert(job.cooldown == nil or (math.type(job.cooldown) == "integer" and job.cooldown >= 0),
            ("job %s has a nonsense cooldown"):format(key))
        assert(job.expires == nil or (math.type(job.expires) == "integer" and job.expires > 0),
            ("job %s has a nonsense expiry"):format(key))
    end
    return jobs
end

--- opts.jobs   the job table; the default one if not given
--- opts.sweep  how often abandoned shifts are cleaned up, in city milliseconds
function Work.system(opts)
    opts = opts or {}
    local jobs = check_jobs(opts.jobs or DEFAULT_JOBS)
    local sweep = opts.sweep or (30 * MINUTE)

    return {
        name = "work",
        requires = { "characters", "memory" },
        install = function(world)
            local employers = world:repository(Work.Employer)
            local shifts = world:repository(Work.Shift)
            local cooldowns = {}         -- worker -> job -> city time it is free again

            local function open_shift_of(worker)
                for _, shift in ipairs(shifts:where(function(candidate)
                    return candidate.state == "open" and candidate:get("worker") == worker
                end)) do
                    return shift
                end
                return nil
            end

            world.services.work = {
                jobs = jobs,
                employers = employers,
                shifts = shifts,
                open_shift_of = open_shift_of,
                --- Put an employer on the map. Not a command: employers are
                --- placed by the server or by another system, never by a
                --- client asking for one.
                employ = function(name, employ_opts)
                    employ_opts = employ_opts or {}
                    local offers = {}
                    for _, key in ipairs(employ_opts.offers or {}) do
                        assert(jobs[key], ("no job called %s"):format(tostring(key)))
                        offers[key] = true
                    end
                    return employers:create({
                        name = name,
                        external = employ_opts.external ~= false,
                        offers = offers,
                    })
                end,
                cooldown_left = function(worker, job)
                    local per_worker = cooldowns[worker]
                    local until_at = per_worker and per_worker[job]
                    if not until_at then return 0 end
                    local left = until_at - world.clock:now()
                    return left > 0 and left or 0
                end,
            }

            world:persist_with("work", {
                save = function()
                    local out = {}
                    for worker, per_worker in pairs(cooldowns) do
                        local copy = {}
                        for job, until_at in pairs(per_worker) do copy[job] = until_at end
                        out[worker] = copy
                    end
                    return { cooldowns = out }
                end,
                load = function(stored)
                    cooldowns = {}
                    for worker, per_worker in pairs((stored or {}).cooldowns or {}) do
                        local copy = {}
                        for job, until_at in pairs(per_worker) do
                            if math.type(until_at) ~= "integer" then
                                return false, ("%s has a cooldown that is not a whole time"):format(worker)
                            end
                            copy[job] = until_at
                        end
                        cooldowns[worker] = copy
                    end
                    return true
                end,
            })

            --- Who is hiring, and for what.
            ---
            --- `work.start` takes an employer id, and nothing in this city ever
            --- gave a player one. `me.nearby` answers for shop counters and for
            --- doors, and an employer is external: it has no address, so it is
            --- near nothing and never will be. There was no other read, no
            --- screen, and no chat command that named one. Earning worked and
            --- could not be reached, exactly the way the shop counter and the
            --- priced door could not.
            ---
            --- No argument names anybody and no argument names an employer,
            --- because this is the read that says they exist. Every number in
            --- the answer is a count to draw: whether this person can take a
            --- shift on is `work.start` refusing, not a field here.
            world:define("work.list", {
                -- A read, and declared one. Undeclared, every look at the
                -- board with a client's token was a receipt kept in every save
                -- and an answer held in memory for the life of the server.
                read_only = true,
                summary = "who is hiring, and for what",
                rate = { per_minute = 30 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local hiring = {}
                    employers:all()
                    for _, employer in ipairs(employers:where(function() return true end)) do
                        local offers = {}
                        for key in pairs(employer:get("offers")) do
                            local job = jobs[key]
                            -- A job the server has since stopped hiring for is
                            -- left out rather than drawn as a name with no
                            -- pay beside it.
                            if job then
                                local left = world.services.work.cooldown_left(ctx.actor, key)
                                offers[#offers + 1] = {
                                    job = key,
                                    label = job.label,
                                    pay = job.pay,
                                    minutes = job.duration // MINUTE,
                                    -- Minutes to wait, rounded up so that "1"
                                    -- never means "now". Drawn, never obeyed.
                                    ready_in = left > 0 and (left // MINUTE + 1) or 0,
                                }
                            end
                        end
                        table.sort(offers, function(a, b) return a.job < b.job end)
                        hiring[#hiring + 1] = {
                            employer = employer.id,
                            name = employer:get("name"),
                            -- The same shape a shut shop has: it is still in
                            -- the list, and it says so.
                            hiring = employer.state == "hiring",
                            jobs = offers,
                        }
                    end
                    table.sort(hiring, function(a, b) return a.employer < b.employer end)
                    local open = open_shift_of(ctx.actor)
                    return ctx.ok({
                        employers = hiring,
                        -- What you are on now, so nothing has to ask twice.
                        working = open and open:get("job") or nil,
                    })
                end,
            })

            world:define("work.start", {
                summary = "clock on",
                rate = { per_minute = 10 },
                args = {
                    employer = { type = "id", kind = "emp", required = true },
                    job = { type = "string", required = true, max = 32 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local job = jobs[args.job]
                    if not job then return ctx.refuse("no_such_job", "Nobody hires for that.") end

                    local employer = employers:load(args.employer)
                    if not employer then return ctx.refuse("no_such_employer", "There is no such employer.") end
                    if employer.state ~= "hiring" then
                        return ctx.refuse("not_hiring", ("%s is not taking anybody on."):format(employer:get("name")))
                    end
                    if not employer:get("offers")[args.job] then
                        return ctx.refuse("not_offered", ("%s does not hire for that."):format(employer:get("name")))
                    end
                    if open_shift_of(ctx.actor) then
                        return ctx.refuse("already_working", "You are already on a shift.")
                    end

                    local left = world.services.work.cooldown_left(ctx.actor, args.job)
                    if left > 0 then
                        return ctx.refuse("too_soon",
                            ("You cannot take that on again for another %d minutes."):format(left // MINUTE + 1),
                            { minutes = left // MINUTE + 1 })
                    end

                    local shift, why = shifts:create({
                        worker = ctx.actor, employer = employer.id,
                        job = args.job, started = ctx.now, pay = job.pay,
                    })
                    if not shift then return ctx.refuse("cannot_start", why) end

                    ctx.emit("work.started", { shift = shift.id, worker = ctx.actor,
                        employer = employer.id, job = args.job })
                    return ctx.ok({ shift = shift.id, minutes = job.duration // MINUTE })
                end,
            })

            world:define("work.finish", {
                summary = "clock off and get paid",
                rate = { per_minute = 10 },
                -- There is no payout argument. There is nothing here a client
                -- could put a number in. That is the whole design.
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shift = open_shift_of(ctx.actor)
                    if not shift then return ctx.refuse("not_working", "You are not on a shift.") end

                    local job = jobs[shift:get("job")]
                    if not job then
                        -- The job was removed from the server between clocking
                        -- on and clocking off. Close the shift, pay nothing,
                        -- and say so rather than paying a remembered number.
                        shift:transition("abandoned", { reason = "the job no longer exists" })
                        shifts:save(shift)
                        return ctx.refuse("job_withdrawn", "That work does not exist any more.")
                    end

                    local worked = ctx.now - shift:get("started")
                    if worked < job.duration then
                        local left = job.duration - worked
                        return ctx.refuse("not_done",
                            ("There is another %d minutes in that."):format(left // MINUTE + 1),
                            { minutes = left // MINUTE + 1 })
                    end

                    local employer = employers:load(shift:get("employer"))
                    if not employer then return ctx.refuse("no_such_employer", "Your employer is gone.") end

                    -- The pay comes from the job table, looked up here, now.
                    local wages = Money.from_minor(job.pay)
                    local paid, why = world.ledger:transfer(
                        "wages:" .. shift.id,
                        Work.account(employer), Characters.wallet(ctx.actor), wages,
                        { reason = "wages", job = shift:get("job") })
                    if not paid then
                        -- The employer cannot pay. The shift stays open, so
                        -- the work is not lost; it can be claimed once they
                        -- are funded again.
                        return ctx.refuse("employer_broke",
                            ("%s cannot pay you right now."):format(employer:get("name")), { detail = why })
                    end

                    shift:transition("finished", { reason = "completed" })
                    shifts:save(shift)

                    local per_worker = cooldowns[ctx.actor]
                    if not per_worker then
                        per_worker = {}
                        cooldowns[ctx.actor] = per_worker
                    end
                    per_worker[shift:get("job")] = ctx.now + (job.cooldown or 0)

                    -- A work history the city holds, rather than one a player
                    -- claims. Honest work is as much a matter of record as the
                    -- other kind.
                    world.services.remember("shift:" .. shift.id, {
                        subject = ctx.actor, kind = "work.shift", weight = 1,
                        involved = { employer.id },
                        meta = { job = shift:get("job"), paid = job.pay, employer = employer:get("name") },
                    })

                    ctx.emit("work.finished", { shift = shift.id, worker = ctx.actor,
                        employer = employer.id, job = shift:get("job"), paid = job.pay })
                    return ctx.ok({ paid = job.pay })
                end,
            })

            world:define("work.abandon", {
                summary = "walk off the job",
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local shift = open_shift_of(ctx.actor)
                    if not shift then return ctx.refuse("not_working", "You are not on a shift.") end
                    shift:transition("abandoned", { reason = "walked off" })
                    shifts:save(shift)
                    ctx.emit("work.abandoned", { shift = shift.id, worker = ctx.actor,
                        job = shift:get("job") })
                    return ctx.ok()
                end,
            })

            -- A shift left open past its expiry is closed. Without this, one
            -- forgotten shift blocks that person from ever working again.
            world:every(sweep, function()
                local now = world.clock:now()
                for _, shift in ipairs(shifts:where(function(candidate) return candidate.state == "open" end)) do
                    local job = jobs[shift:get("job")]
                    local expires = job and job.expires
                    if expires and now - shift:get("started") > expires then
                        shift:transition("expired", { reason = "left open too long" })
                        shifts:save(shift)
                        world.events:emit("work.expired", { shift = shift.id,
                            worker = shift:get("worker"), job = shift:get("job") })
                    end
                end
            end, "work:sweep")

            -- Logging out does not finish a shift. It stays open until it is
            -- finished or expires, which is what a player expects after a
            -- disconnect two minutes from the end.
            world:on("world.loaded", function()
                shifts:all()
                employers:all()
            end, { label = "work:load" })
        end,
    }
end

return Work
