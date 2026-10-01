--- The city remembers.
--
-- This is the system the product is named after, and it is two things kept
-- deliberately apart.
--
--   The record is what happened. It is written whether or not anybody saw it,
--   it is never edited, and it never expires. A burglary nobody witnessed
--   still leaves a record, and that record is what lets a detective find it
--   later instead of needing an eyewitness who no longer plays here.
--
--   Standing is what the city currently thinks. It moves when things happen
--   and it drifts back toward nothing when they stop. Heat cools.
--
-- The interesting mechanic falls out of keeping them apart: a crime with no
-- witnesses generates no heat and a full record. Nobody is looking for you,
-- and the evidence is sitting there with your name on it. Wait out your heat
-- and you are no longer hunted and still the person who did it.
--
-- A consequence table says which records move which standing, so adding a new
-- kind of crime is a line of configuration rather than a new code path in
-- three systems.

local Record = require("domain.record")
local Standing = require("domain.standing")
local Clock = require("core.clock")

local Memory = {}

--- The default consequence table. A server owner replaces or extends it; the
--- shape is what matters.
---
---   party            who changes their mind. A string, or a function of the
---                    record, for when it depends on where it happened.
---   points           how much, signed. A number, or a function of the record,
---                    for when it scales with what was taken.
---   requires_witness only if somebody saw it. This is what separates being
---                    hunted from having done it.
---   floor            standing this can never decay past, for allegiance that
---                    is earned rather than lent.
local DEFAULT_CONSEQUENCES = {
    ["crime.robbery"] = {
        { party = "police", points = -40, requires_witness = true },
        { party = function(entry) return entry.place and ("place:" .. entry.place) end, points = -15 },
    },
    ["crime.burglary"] = {
        { party = "police", points = -30, requires_witness = true },
    },
    ["crime.vehicle_theft"] = {
        { party = "police", points = -35, requires_witness = true },
    },
    ["crime.handling"] = {
        { party = "police", points = -20, requires_witness = true },
    },
    ["crime.assault"] = {
        { party = "police", points = -25, requires_witness = true },
    },
    ["crime.murder"] = {
        { party = "police", points = -120, requires_witness = true },
    },
    ["police.arrest"] = {
        -- Being caught clears what the police were looking for you about, and
        -- exactly that: the arresting system writes down how much heat there
        -- was, so a fixed number cannot leave somebody still wanted after
        -- serving for it. The record of the arrest, and of everything before
        -- it, stays.
        { party = "police", points = function(entry)
            return (entry.meta and math.type(entry.meta.cleared) == "integer" and entry.meta.cleared) or 200
        end },
    },
    ["trade.honoured"] = {
        { party = function(entry) return entry.meta and entry.meta.with end, points = 5 },
    },
    ["trade.cheated"] = {
        { party = function(entry) return entry.meta and entry.meta.with end, points = -30 },
    },
}

Memory.DEFAULT_CONSEQUENCES = DEFAULT_CONSEQUENCES

local function resolve(value, entry)
    if type(value) == "function" then return value(entry) end
    return value
end

-- Lines leaving the record's window go to the store a page at a time, and a
-- volume of pages is one store collection, so no single file is rewritten or
-- read back whole as the history grows.
local ARCHIVE_PAGE = 500
local ARCHIVE_VOLUME = 20

--- The store collection that holds one volume of the record's archive.
function Memory.archive_collection(volume)
    return ("record_archive_%04d"):format(volume)
end

local function read_archive(stored)
    if stored == nil then return { pages = 0, pending = {} } end
    if type(stored) ~= "table" or math.type(stored.pages) ~= "integer" or stored.pages < 0
        or (stored.pending ~= nil and type(stored.pending) ~= "table") then
        return nil, "the record archive does not say how many pages it has written"
    end
    local pending = {}
    for position, line in ipairs(stored.pending or {}) do
        if type(line) ~= "table" or type(line.id) ~= "string" or not Record.is_subject(line.subject)
            or not Record.is_kind(line.kind) or math.type(line.at) ~= "integer" then
            return nil, ("line %d waiting for the record archive is not a line"):format(position)
        end
        pending[position] = line
    end
    return { pages = stored.pages, pending = pending }
end

--- opts.consequences  replaces the default table
--- opts.also          extends the default table instead of replacing it
--- opts.decay         { period = ms, rate = points, rates = { party = points } }
--- opts.limit         how many records stay in memory
--- opts.archive_page  how many lines leaving memory are written to the store at once
function Memory.system(opts)
    opts = opts or {}
    local page_size = opts.archive_page or ARCHIVE_PAGE
    assert(math.type(page_size) == "integer" and page_size > 0, "an archive page holds at least one line")
    local consequences = opts.consequences or DEFAULT_CONSEQUENCES
    if opts.also then
        local merged = {}
        for kind, list in pairs(consequences) do merged[kind] = list end
        for kind, list in pairs(opts.also) do merged[kind] = list end
        consequences = merged
    end
    local decay = opts.decay or {}

    return {
        name = "memory",
        install = function(world)
            local city_now = function() return world.clock:now() end

            -- The record keeps a window in memory, and what left the window
            -- was handed to nobody: gone from the city and from the save,
            -- whatever it was, from a record that promises never to expire.
            -- What leaves now waits here until there is a page of it, the page
            -- goes into the store, and what is still waiting is saved with the
            -- record, so a restart loses none of it.
            local archive = { pages = 0, pending = {} }
            local function archive_lines(removed)
                for _, line in ipairs(removed) do archive.pending[#archive.pending + 1] = line end
                while #archive.pending >= page_size do
                    local page, rest = {}, {}
                    for position, line in ipairs(archive.pending) do
                        if position <= page_size then page[position] = line else rest[#rest + 1] = line end
                    end
                    -- Keyed by the page's first line rather than by a count, so a
                    -- page written again after a crash replaces itself, and a city
                    -- that has not been read yet cannot write over a real page.
                    world.store:put(Memory.archive_collection(archive.pages // ARCHIVE_VOLUME + 1),
                        page[1].id, { lines = page })
                    archive.pages = archive.pages + 1
                    archive.pending = rest
                end
            end

            local book = Record.new({ clock = city_now, limit = opts.limit, on_archive = archive_lines })
            local standing = Standing.new({
                clock = city_now,
                period = decay.period or Clock.MS_PER_HOUR,
                rate = decay.rate or 5,
                rates = decay.rates,
                min = decay.min,
                max = decay.max,
            })

            world.services.record = book
            world.services.standing = standing

            --- Write down that something happened, and let it change what the
            --- city thinks. The one call every other system makes.
            ---
            --- Returns the record and the list of standing changes it caused,
            --- so a caller can tell a player what it cost them.
            world.services.remember = function(operation_id, entry)
                local written, duplicate = book:write(operation_id, entry)
                if duplicate then return written, {}, true end

                local changes = {}
                for position, consequence in ipairs(consequences[written.kind] or {}) do
                    local witnessed = #written.witnesses > 0
                    if not (consequence.requires_witness and not witnessed) then
                        local party = resolve(consequence.party, written)
                        local points = resolve(consequence.points, written)
                        if party and math.type(points) == "integer" and points ~= 0 then
                            local score = standing:adjust(
                                ("%s#%d"):format(operation_id, position),
                                written.subject, party, points,
                                consequence.floor and { floor = consequence.floor } or nil)
                            changes[#changes + 1] = { party = party, points = points, score = score }
                        end
                    end
                end

                world.events:emit("city.remembered", {
                    record = written.id,
                    subject = written.subject,
                    kind = written.kind,
                    witnessed = #written.witnesses > 0,
                    place = written.place,
                    changes = changes,
                })
                return written, changes, false
            end

            world.services.recall = function(subject, query) return book:about(subject, query) end
            world.services.heat = function(subject, authority) return standing:heat(subject, authority) end

            world:persist_with("memory", {
                save = function()
                    local pending = {}
                    for position, line in ipairs(archive.pending) do pending[position] = line end
                    return { record = book:serialize(), standing = standing:serialize(),
                             archive = { pages = archive.pages, pending = pending } }
                end,
                load = function(stored)
                    local loaded, why = Record.deserialize(stored.record or {}, { clock = city_now,
                        limit = opts.limit })
                    if not loaded then return false, why end
                    local kept, kept_why = read_archive(stored.archive)
                    if not kept then return false, kept_why end
                    local scores, score_why = Standing.deserialize(stored.standing or {}, {
                        clock = city_now,
                        period = decay.period or Clock.MS_PER_HOUR,
                        rate = decay.rate or 5,
                        rates = decay.rates,
                        min = decay.min, max = decay.max,
                    })
                    if not scores then return false, score_why end
                    -- Swap contents rather than objects, so every reference
                    -- handed out at install still points at what is in use.
                    book._entries, book._by_subject = loaded._entries, loaded._by_subject
                    book._written, book._sequence = loaded._written, loaded._sequence
                    book._archived = loaded._archived
                    book._front, book._held_of = loaded._front, loaded._held_of
                    standing._scores = scores._scores
                    archive = kept
                    return true
                end,
            })

            -- Bring scores up to date once a city hour. Nothing depends on
            -- this for correctness, because a score settles itself when it is
            -- read; it keeps listings fresh and stops the table holding an
            -- entry for every pair that ever interacted.
            world:every(Clock.MS_PER_HOUR, function()
                standing:settle_all()
            end, "memory:settle")

            world:define("record.mine", {
                read_only = true,
                summary = "what the city has on you",
                rate = { per_minute = 20 },
                args = {
                    kind = { type = "string", max = 48 },
                    limit = { type = "integer", default = 20, min = 1, max = 100 },
                },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    -- What they did, and not what they were drawn into. A row
                    -- here says a kind and nothing about whose it was, so a
                    -- murder victim read "crime.murder" as her own, and anybody
                    -- an officer or a member of staff pulled up could read
                    -- that they had been.
                    local found = book:about(ctx.actor,
                        { kind = args.kind, limit = args.limit, involved = false })
                    local summary = {}
                    for position, entry in ipairs(found) do
                        summary[position] = {
                            at = entry.at, kind = entry.kind, place = entry.place,
                            weight = entry.weight, witnessed = #entry.witnesses > 0,
                        }
                    end
                    return ctx.ok({ records = summary, heat = standing:heat(ctx.actor) })
                end,
            })
        end,
    }
end

return Memory
