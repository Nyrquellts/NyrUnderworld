--- Stable identity for everything the city remembers.
--
-- An id has to survive a server restart, a database round trip, a log line and
-- a support ticket. So it is a plain string, it says what kind of thing it
-- names, and two ids sort into the order the things were created.
--
--   veh_0m4k2p8q10003x7f2ka
--   |   |        |   |
--   |   |        |   +-- 6 random base36 digits: uniqueness across servers
--   |   |        +------ 4 base36 digits: order within one millisecond
--   |   +--------------- 9 base36 digits: milliseconds since the epoch
--   +------------------- the kind, so a stray id in a log says what it was
--
-- Base36 and a fixed width together mean lexicographic order is chronological
-- order, which is what makes an index on this column useful and what lets a
-- sorted list of ids be read as a timeline.
--
-- Pure: no globals, no FiveM natives. The clock and the randomness are
-- injectable so a spec can pin them.

local Id = {}

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local TIME_WIDTH, SEQ_WIDTH, RAND_WIDTH = 9, 4, 6
local BODY_WIDTH = TIME_WIDTH + SEQ_WIDTH + RAND_WIDTH
local TIME_MAX = math.tointeger(36 ^ TIME_WIDTH) - 1   -- year 5138; long enough
local SEQ_MAX = math.tointeger(36 ^ SEQ_WIDTH) - 1     -- 1,679,615 ids in one millisecond
local RAND_MAX = math.tointeger(36 ^ RAND_WIDTH) - 1
local KIND_PATTERN = "^%l[%l%d]*$"
local KIND_MAX = 12

Id.TIME_WIDTH, Id.SEQ_WIDTH, Id.RAND_WIDTH = TIME_WIDTH, SEQ_WIDTH, RAND_WIDTH
Id.BODY_WIDTH = BODY_WIDTH

local function encode(value, width)
    local out, n = {}, value
    repeat
        local digit = n % 36
        table.insert(out, 1, DIGITS:sub(digit + 1, digit + 1))
        n = n // 36
    until n == 0
    local text = table.concat(out)
    return string.rep("0", width - #text) .. text
end

local function decode(text)
    local n = 0
    for i = 1, #text do
        local digit = DIGITS:find(text:sub(i, i), 1, true)
        if not digit then return nil end
        n = n * 36 + (digit - 1)
    end
    return n
end

--- Whether a string could be a kind. Lowercase so ids never differ by case
--- alone, which is a class of bug that only shows up on a case-sensitive
--- database after it has already shipped.
function Id.is_kind(kind)
    return type(kind) == "string" and #kind >= 1 and #kind <= KIND_MAX
        and kind:match(KIND_PATTERN) ~= nil
end

local function check_kind(kind)
    if not Id.is_kind(kind) then
        error(("id kind must be 1-%d lowercase letters or digits, starting with a letter; got %s")
            :format(KIND_MAX, tostring(kind)), 3)
    end
end

-- The default clock. Second resolution is all a plain interpreter offers, so
-- the sequence counter does the real tie-breaking; the randomness does the
-- rest. A caller with a millisecond clock (GetGameTimer on a server, a
-- database NOW(3)) should pass it in.
local function default_now()
    return math.floor(os.time()) * 1000
end

local last_now, sequence = -1, -1

local function next_sequence(now)
    if now ~= last_now then
        last_now, sequence = now, 0
    else
        sequence = sequence + 1
        if sequence > SEQ_MAX then
            -- Over a million ids in one millisecond is not a real workload; it
            -- is a runaway loop. Refusing beats handing out a duplicate.
            error("id sequence exhausted within one millisecond", 3)
        end
    end
    return sequence
end

--- Build an id from stated parts. Deterministic, so specs and fixtures can
--- name an exact id instead of matching a pattern.
function Id.from_parts(kind, time_ms, seq, rand)
    check_kind(kind)
    local parts = { { "time_ms", time_ms, TIME_MAX }, { "sequence", seq, SEQ_MAX }, { "random", rand, RAND_MAX } }
    for _, part in ipairs(parts) do
        local name, value, limit = part[1], part[2], part[3]
        if math.type(value) ~= "integer" or value < 0 or value > limit then
            error(("id %s must be an integer in 0..%d; got %s"):format(name, limit, tostring(value)), 2)
        end
    end
    return ("%s_%s%s%s"):format(kind, encode(time_ms, TIME_WIDTH), encode(seq, SEQ_WIDTH), encode(rand, RAND_WIDTH))
end

--- A fresh id for a new thing.
--- opts.now      integer milliseconds, for a real clock or a pinned one
--- opts.random   function() -> integer in 0..RAND_MAX
function Id.new(kind, opts)
    check_kind(kind)
    opts = opts or {}
    local now = opts.now or default_now()
    if math.type(now) ~= "integer" or now < 0 or now > TIME_MAX then
        error(("id clock must be an integer millisecond count in 0..%d; got %s")
            :format(TIME_MAX, tostring(now)), 2)
    end
    local rand
    if opts.random then
        rand = opts.random()
        if math.type(rand) ~= "integer" or rand < 0 or rand > RAND_MAX then
            error(("id randomness must return an integer in 0..%d; got %s"):format(RAND_MAX, tostring(rand)), 2)
        end
    else
        rand = math.random(0, RAND_MAX)
    end
    return Id.from_parts(kind, now, next_sequence(now), rand)
end

--- Take an id apart. Returns nil plus a reason rather than throwing, because
--- the usual caller is validating something a client sent.
function Id.parse(id)
    if type(id) ~= "string" then return nil, "not a string" end
    local kind, body = id:match("^([^_]+)_(.+)$")
    if not kind then return nil, "missing the kind separator" end
    if not Id.is_kind(kind) then return nil, "bad kind" end
    if #body ~= BODY_WIDTH then return nil, ("body must be %d characters"):format(BODY_WIDTH) end
    local time_ms = decode(body:sub(1, TIME_WIDTH))
    local seq = decode(body:sub(TIME_WIDTH + 1, TIME_WIDTH + SEQ_WIDTH))
    local rand = decode(body:sub(TIME_WIDTH + SEQ_WIDTH + 1))
    if not (time_ms and seq and rand) then return nil, "body has a non-base36 character" end
    return { kind = kind, time_ms = time_ms, sequence = seq, random = rand, body = body }
end

function Id.is_valid(id) return Id.parse(id) ~= nil end

function Id.kind_of(id)
    local parsed = Id.parse(id)
    return parsed and parsed.kind or nil
end

--- Kinds must match as well as shape. This is the check that stops a vehicle
--- id being accepted where a property id belongs, which is how one system's
--- bug becomes another system's stolen asset.
function Id.is_a(id, kind)
    local parsed = Id.parse(id)
    return parsed ~= nil and parsed.kind == kind
end

function Id.require(id, kind)
    local parsed, why = Id.parse(id)
    if not parsed then error(("not an id: %s (%s)"):format(tostring(id), why), 2) end
    if kind and parsed.kind ~= kind then
        error(("expected a %s id, got a %s id: %s"):format(kind, parsed.kind, id), 2)
    end
    return id
end

--- Chronological order, across kinds. Within one kind a plain string compare
--- already does this, which is the point of the fixed widths.
function Id.before(a, b)
    local pa, pb = Id.parse(a), Id.parse(b)
    if not (pa and pb) then error("Id.before needs two ids", 2) end
    return pa.body < pb.body
end

return Id
