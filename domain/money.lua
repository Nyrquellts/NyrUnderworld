--- Money as whole minor units, because floats lose it.
--
-- The directive's hardest invariants are "no accidental money creation" and
-- "no accidental money deletion". Most economies in this genre violate both
-- by accident on the first day, for one reason: they store money as a Lua
-- number and Lua numbers are doubles. 0.1 + 0.2 is not 0.3, a long chain of
-- percentage cuts drifts, and a large enough balance silently loses its last
-- cents. None of that announces itself.
--
-- So money here is an integer count of minor units (cents), never a float,
-- and every operation that could produce a fraction has to say what it does
-- with the remainder. `split` is the clearest example: dividing $10 three
-- ways gives 334, 333, 333 -- the extra cent goes somewhere explicit rather
-- than evaporating.
--
-- Pure Lua. No FiveM natives, no globals, no side effects. It runs under a
-- plain interpreter so the rules can be tested without a game.

local Money = {}
Money.__index = Money

local MINOR_PER_MAJOR = 100
-- 2^53 is where a double stops counting integers exactly. Staying well under
-- it means a balance can always be handed to JSON, NUI or a database that
-- rounds to a double without changing.
local MAX_MINOR = 2 ^ 53 - 1

local function is_whole(value)
    return type(value) == "number" and value == math.floor(value) and value == value
        and value ~= math.huge and value ~= -math.huge
end

--- A Money value from a whole number of minor units.
function Money.from_minor(minor)
    assert(is_whole(minor), "money must be a whole number of minor units, got " .. tostring(minor))
    assert(minor <= MAX_MINOR and minor >= -MAX_MINOR,
        "money magnitude exceeds what stays exact as an integer: " .. tostring(minor))
    return setmetatable({ minor = math.tointeger(minor) or minor }, Money)
end

--- A Money value from major and minor parts, e.g. of(12, 50) is $12.50.
function Money.of(major, minor)
    minor = minor or 0
    assert(is_whole(major) and is_whole(minor), "major and minor must be whole numbers")
    assert(minor >= 0 and minor < MINOR_PER_MAJOR, "minor must be 0..99, got " .. tostring(minor))
    local sign = major < 0 and -1 or 1
    return Money.from_minor(major * MINOR_PER_MAJOR + sign * minor)
end

Money.zero = Money.from_minor(0)

function Money.is(value)
    return getmetatable(value) == Money
end

local function coerce(value, what)
    assert(Money.is(value), (what or "value") .. " must be Money, got " .. type(value))
    return value
end

function Money:add(other)
    return Money.from_minor(self.minor + coerce(other, "addend").minor)
end

function Money:sub(other)
    return Money.from_minor(self.minor - coerce(other, "subtrahend").minor)
end

function Money:negate()
    return Money.from_minor(-self.minor)
end

--- Multiply by a whole count. Not by a fraction: see `percent` and `split`.
function Money:times(count)
    assert(is_whole(count), "times takes a whole count; use percent or split for fractions")
    return Money.from_minor(self.minor * count)
end

--- A whole-percent cut, rounded half away from zero, with the remainder named.
-- Returns the cut and what is left, so a caller can never lose the difference
-- by forgetting it existed.
function Money:percent(whole_percent)
    assert(is_whole(whole_percent), "percent takes a whole number")
    local exact = self.minor * whole_percent / 100
    local cut = exact >= 0 and math.floor(exact + 0.5) or -math.floor(-exact + 0.5)
    local taken = Money.from_minor(cut)
    return taken, self:sub(taken)
end

--- Divide into `parts` shares that sum back to exactly this amount.
-- The remainder is handed out one minor unit at a time from the front, so
-- $10.00 into 3 is 3.34, 3.33, 3.33 and never 3.33, 3.33, 3.33 with a cent
-- quietly gone.
function Money:split(parts)
    assert(is_whole(parts) and parts > 0, "split needs a positive whole number of parts")
    local base = self.minor // parts
    local remainder = self.minor - base * parts
    local shares = {}
    for index = 1, parts do
        local extra = 0
        if remainder > 0 then
            extra, remainder = 1, remainder - 1
        elseif remainder < 0 then
            extra, remainder = -1, remainder + 1
        end
        shares[index] = Money.from_minor(base + extra)
    end
    return shares
end

function Money:is_zero() return self.minor == 0 end
function Money:is_negative() return self.minor < 0 end
function Money:is_positive() return self.minor > 0 end

function Money:compare(other)
    local mine, theirs = self.minor, coerce(other, "comparand").minor
    return mine < theirs and -1 or mine > theirs and 1 or 0
end

Money.__eq = function(a, b) return Money.is(a) and Money.is(b) and a.minor == b.minor end
Money.__lt = function(a, b) return coerce(a).minor < coerce(b).minor end
Money.__le = function(a, b) return coerce(a).minor <= coerce(b).minor end

--- A stable, human-readable form. Never used for arithmetic.
function Money:__tostring()
    local sign = self.minor < 0 and "-" or ""
    local magnitude = self.minor < 0 and -self.minor or self.minor
    return string.format("%s%d.%02d", sign, magnitude // MINOR_PER_MAJOR, magnitude % MINOR_PER_MAJOR)
end

--- What goes into the database and over the wire: the integer, nothing else.
function Money:to_minor() return self.minor end

Money.MINOR_PER_MAJOR = MINOR_PER_MAJOR
Money.MAX_MINOR = MAX_MINOR

return Money
