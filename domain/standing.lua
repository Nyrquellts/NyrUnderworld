--- What the city currently thinks of you, as opposed to what it remembers.
--
-- Standing is a signed score between one subject and one party: a character
-- and the police, a character and a gang, a business and a neighbourhood.
-- Negative with the police is heat. Positive with a gang is trust. It moves
-- when things happen and it drifts back toward nothing when they stop.
--
-- The decay is the point. A server where consequence is permanent is a server
-- nobody plays twice, and a server where consequence is instant is a server
-- with no consequence. Standing fades; the record underneath it does not. A
-- player who waits out their heat is no longer hunted, and is still the person
-- who did it, and a detective who looks them up can still see all of it.
--
-- Scores are integers and decay is exact. A float score losing a fraction on
-- every tick drifts, and a drifting heat level is one that expires at a
-- different time on Tuesday than it did on Monday, which players notice and
-- cannot explain.

-- The decay rule itself is NYR-Lang (tools/nyr/standing_decay.nyr), compiled by nyrc into this module.
local Decay = require("domain.rules.standing_decay")

local Standing = {}
Standing.__index = Standing

local DEFAULT_MIN, DEFAULT_MAX = -1000, 1000
local DEFAULT_PERIOD = 3600000        -- one city hour
local DEFAULT_RATE = 5                -- points back toward nothing per period
local NAME_MAX = 96

function Standing.is_name(value)
    return type(value) == "string" and value ~= "" and #value <= NAME_MAX
        and value:match("^[%w_%-%.:]+$") ~= nil
end

local function require_name(value, what)
    if not Standing.is_name(value) then
        error(("%s must be an id or a namespaced name; got %s"):format(what, tostring(value)), 3)
    end
    return value
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--- opts.min, opts.max    the range a score lives in
--- opts.period           city milliseconds per decay step
--- opts.rate             points moved toward nothing per step
--- opts.clock            function returning integer city milliseconds
--- opts.rates            per-party overrides: { police = 3, ["gang:ballas"] = 1 }
function Standing.new(opts)
    opts = opts or {}
    local min = opts.min or DEFAULT_MIN
    local max = opts.max or DEFAULT_MAX
    assert(math.type(min) == "integer" and math.type(max) == "integer" and min < max,
        "a standing range is two whole numbers, low then high")
    local period = opts.period or DEFAULT_PERIOD
    assert(math.type(period) == "integer" and period > 0, "a decay period is whole milliseconds above zero")
    local rate = opts.rate or DEFAULT_RATE
    assert(math.type(rate) == "integer" and rate >= 0, "a decay rate is a whole number of points")
    return setmetatable({
        _scores = {},        -- subject -> party -> { score, decayed_at, floor }
        _applied = {},
        _min = min,
        _max = max,
        _period = period,
        _rate = rate,
        _rates = opts.rates or {},
        _clock = opts.clock or function() return math.floor(os.time()) * 1000 end,
    }, Standing)
end

function Standing:range() return self._min, self._max end

local function rate_for(self, party)
    local rate = self._rates[party]
    if rate == nil then return self._rate end
    return rate
end

-- Decay is computed in whole steps from the last time it was computed, so it
-- is exact and does not depend on how often anybody asks. Ten separate
-- questions in one hour and one question after ten hours give the same answer.
-- The rule is tools/nyr/standing_decay.nyr; this applies what it decides.
local function settle(self, entry, party, now)
    local decided = Decay.evaluate({
        score = entry.score, rest = entry.floor, decayed_at = entry.decayed_at, now = now,
        period = self._period, rate = rate_for(self, party),
    })
    -- The rule computes in floats; every value it hands back is a whole number
    -- (its inputs are, and it only adds, multiplies and floors them).
    for _, update in ipairs(decided.updates) do
        entry[update.name] = assert(math.tointeger(update.value), "standing decay left a fraction")
    end
    return entry
end

local function entry_for(self, subject, party, now, create)
    local per_subject = self._scores[subject]
    if not per_subject then
        if not create then return nil end
        per_subject = {}
        self._scores[subject] = per_subject
    end
    local entry = per_subject[party]
    if not entry then
        if not create then return nil end
        entry = { score = 0, decayed_at = now, floor = 0 }
        per_subject[party] = entry
    end
    return settle(self, entry, party, now)
end

--- The score right now, with decay applied.
function Standing:score(subject, party, at)
    local entry = entry_for(self, subject, party, at or self._clock(), false)
    return entry and entry.score or 0
end

--- Heat is standing with an authority, read the way a player thinks about it:
--- a number that goes up when you do crime and comes down when you stop.
function Standing:heat(subject, authority, at)
    local score = self:score(subject, authority or "police", at)
    return score < 0 and -score or 0
end

--- Move a score. Idempotent by operation id, so an event delivered twice moves
--- it once.
function Standing:adjust(operation_id, subject, party, delta, meta)
    if type(operation_id) ~= "string" or operation_id == "" then
        error("every change of standing needs an operation id", 2)
    end
    require_name(subject, "subject")
    require_name(party, "party")
    if math.type(delta) ~= "integer" then
        error(("standing moves by whole points; got %s"):format(tostring(delta)), 2)
    end
    local previous = self._applied[operation_id]
    if previous then
        return self:score(subject, party), true
    end

    local now = self._clock()
    local entry = entry_for(self, subject, party, now, true)
    entry.score = clamp(entry.score + delta, self._min, self._max)
    entry.decayed_at = now
    if meta and meta.floor ~= nil then
        if math.type(meta.floor) ~= "integer" then error("a floor is a whole number", 2) end
        entry.floor = clamp(meta.floor, self._min, self._max)
    end
    self._applied[operation_id] = true
    return entry.score, false
end

--- Set a floor a score never decays past, for standing that is earned rather
--- than lent: a made member of a gang does not drift back to stranger.
function Standing:set_floor(subject, party, floor)
    require_name(subject, "subject")
    require_name(party, "party")
    if math.type(floor) ~= "integer" then error("a floor is a whole number", 2) end
    local entry = entry_for(self, subject, party, self._clock(), true)
    entry.floor = clamp(floor, self._min, self._max)
    if (entry.floor > 0 and entry.score < entry.floor) or (entry.floor < 0 and entry.score > entry.floor) then
        entry.score = entry.floor
    end
    return entry.floor
end

function Standing:floor(subject, party)
    local entry = entry_for(self, subject, party, self._clock(), false)
    return entry and entry.floor or 0
end

--- Bring every score up to date. A scheduled task calls this so that listing
--- and sorting see settled numbers rather than stale ones.
function Standing:settle_all(at)
    local now = at or self._clock()
    local moved = 0
    for subject, per_subject in pairs(self._scores) do
        for party, entry in pairs(per_subject) do
            local before = entry.score
            settle(self, entry, party, now)
            if entry.score ~= before then moved = moved + 1 end
            -- A score that has reached nothing with nothing holding it there
            -- is the same as never having had one, and keeping it is a slow
            -- leak of one table entry per pair that ever interacted.
            if entry.score == 0 and entry.floor == 0 then
                per_subject[party] = nil
            end
        end
        if next(per_subject) == nil then self._scores[subject] = nil end
    end
    return moved
end

--- Everybody this party has an opinion about, worst first, which is the order
--- a police board and a gang hit list both want.
function Standing:ranked(party, opts)
    opts = opts or {}
    local now = opts.at or self._clock()
    local out = {}
    for subject, per_subject in pairs(self._scores) do
        local entry = per_subject[party]
        if entry then
            settle(self, entry, party, now)
            if not opts.min_magnitude or math.abs(entry.score) >= opts.min_magnitude then
                out[#out + 1] = { subject = subject, score = entry.score }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.subject < b.subject
    end)
    if opts.limit and #out > opts.limit then
        for index = #out, opts.limit + 1, -1 do out[index] = nil end
    end
    return out
end

--- Every party with an opinion about somebody.
function Standing:parties(subject, at)
    local per_subject = self._scores[subject]
    if not per_subject then return {} end
    local now = at or self._clock()
    local out = {}
    for party, entry in pairs(per_subject) do
        settle(self, entry, party, now)
        out[#out + 1] = { party = party, score = entry.score, floor = entry.floor }
    end
    table.sort(out, function(a, b) return a.party < b.party end)
    return out
end

function Standing:subjects()
    local out = {}
    for subject in pairs(self._scores) do out[#out + 1] = subject end
    table.sort(out)
    return out
end

function Standing:verify()
    local problems = {}
    for subject, per_subject in pairs(self._scores) do
        for party, entry in pairs(per_subject) do
            if math.type(entry.score) ~= "integer" then
                problems[#problems + 1] = ("%s with %s has a score of %s")
                    :format(subject, party, tostring(entry.score))
            elseif entry.score < self._min or entry.score > self._max then
                problems[#problems + 1] = ("%s with %s is %d, outside %d..%d")
                    :format(subject, party, entry.score, self._min, self._max)
            end
            if math.type(entry.decayed_at) ~= "integer" then
                problems[#problems + 1] = ("%s with %s has no settled time"):format(subject, party)
            end
        end
    end
    table.sort(problems)
    return #problems == 0, problems
end

-- ------------------------------------------------------------ persistence

function Standing:serialize()
    local scores = {}
    for subject, per_subject in pairs(self._scores) do
        local out = {}
        for party, entry in pairs(per_subject) do
            out[party] = { score = entry.score, decayed_at = entry.decayed_at, floor = entry.floor }
        end
        scores[subject] = out
    end
    return { scores = scores }
end

function Standing.deserialize(record, opts)
    if type(record) ~= "table" then return nil, "a standing record is a table" end
    local standing = Standing.new(opts)
    for subject, per_subject in pairs(record.scores or {}) do
        if not Standing.is_name(subject) then
            return nil, ("%s is not a subject"):format(tostring(subject))
        end
        local rebuilt = {}
        for party, entry in pairs(per_subject) do
            if not Standing.is_name(party) then
                return nil, ("%s is not a party"):format(tostring(party))
            end
            if math.type(entry.score) ~= "integer" then
                return nil, ("%s with %s has a score that is not whole"):format(subject, party)
            end
            rebuilt[party] = {
                score = clamp(entry.score, standing._min, standing._max),
                decayed_at = math.type(entry.decayed_at) == "integer" and entry.decayed_at or standing._clock(),
                floor = math.type(entry.floor) == "integer" and entry.floor or 0,
            }
        end
        standing._scores[subject] = rebuilt
    end
    return standing
end

return Standing
