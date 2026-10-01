--- Standing decay is a NYR-Lang rule (tools/nyr/standing_decay.nyr, compiled by nyrc into
--- domain/rules/standing_decay.lua). It must decide exactly what the hand-written settle it
--- replaced decided, in whole numbers, for every kind of entry: at rest, above and below it,
--- rate 0, a clock that has not moved a whole period, a clock that went back, city times the
--- size os.time() * 1000 gives, and periods of one millisecond.
local modname = ...
local lu = require("luaunit")
local Decay = require("domain.rules.standing_decay")

-- settle as domain/standing.lua had it at 8839f7c, before the rule moved into NYR-Lang.
local function before(entry, rate, period, now)
    if entry.score == entry.floor then
        entry.decayed_at = now
        return entry
    end
    if rate == 0 then return entry end
    local elapsed = now - entry.decayed_at
    if elapsed < period then return entry end
    local steps = elapsed // period
    entry.decayed_at = entry.decayed_at + steps * period
    local movement = steps * rate
    if entry.score > entry.floor then
        entry.score = math.max(entry.floor, entry.score - movement)
    else
        entry.score = math.min(entry.floor, entry.score + movement)
    end
    return entry
end

-- settle as it is now: the rule's decision, applied the way domain/standing.lua applies it.
local function after(entry, rate, period, now)
    local decided = Decay.evaluate({
        score = entry.score, rest = entry.floor, decayed_at = entry.decayed_at, now = now,
        period = period, rate = rate,
    })
    for _, update in ipairs(decided.updates) do
        entry[update.name] = assert(math.tointeger(update.value), "standing decay left a fraction")
    end
    return entry
end

local function same(case)
    local old = before({ score = case.score, floor = case.floor, decayed_at = case.decayed_at },
        case.rate, case.period, case.now)
    local new = after({ score = case.score, floor = case.floor, decayed_at = case.decayed_at },
        case.rate, case.period, case.now)
    local where = ("score %d floor %d decayed_at %d now %d period %d rate %d"):format(
        case.score, case.floor, case.decayed_at, case.now, case.period, case.rate)
    lu.assertEquals(new.score, old.score, where)
    lu.assertEquals(new.decayed_at, old.decayed_at, where)
    lu.assertEquals(math.type(new.score), "integer", where)
    lu.assertEquals(math.type(new.decayed_at), "integer", where)
end

TestStandingDecay = {}

function TestStandingDecay:test_the_named_cases()
    local hour = 3600000
    for _, case in ipairs({
        { score = -100, floor = 0, decayed_at = 0, now = 10 * hour, period = hour, rate = 5 },       -- heat cools
        { score = 100, floor = 0, decayed_at = 0, now = 10 * hour, period = hour, rate = 5 },        -- trust fades
        { score = -100, floor = -90, decayed_at = 0, now = 100 * hour, period = hour, rate = 5 },    -- stops at its floor
        { score = 40, floor = 40, decayed_at = 5, now = 7 * hour, period = hour, rate = 5 },          -- at rest
        { score = -100, floor = 0, decayed_at = 0, now = hour - 1, period = hour, rate = 5 },        -- not a whole period
        { score = -100, floor = 0, decayed_at = 0, now = hour, period = hour, rate = 5 },            -- exactly one
        { score = -100, floor = 0, decayed_at = 5 * hour, now = hour, period = hour, rate = 5 },     -- the clock went back
        { score = -100, floor = 0, decayed_at = 0, now = 50 * hour, period = hour, rate = 0 },       -- this party never drifts
        { score = 7, floor = -3, decayed_at = 1700000000000, now = 1700000000000 + 3 * hour + 17,
          period = hour, rate = 4 },                                                                -- os.time() * 1000
    }) do
        same(case)
    end
end

function TestStandingDecay:test_a_seeded_sweep()
    math.randomseed(20260925)
    local periods = { 1, 2, 7, 1000, 60000, 3600000 }
    for _ = 1, 20000 do
        local period = math.random(1, 3) == 1 and math.random(1, 10000000) or periods[math.random(#periods)]
        local floor = math.random(1, 4) == 1 and 0 or math.random(-1000, 1000)
        local score = math.random(1, 8) == 1 and floor or math.random(-1000, 1000)
        local decayed_at = math.random(1, 2) == 1 and math.random(0, 10000000) or math.random(0, 2 ^ 42)
        local now = decayed_at + math.random(-2 * period, 400 * period)
        same({ score = score, floor = floor, decayed_at = decayed_at, now = now, period = period,
               rate = math.random(1, 6) == 1 and 0 or math.random(1, 50) })
    end
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
