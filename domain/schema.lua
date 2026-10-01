--- One answer to "is this value acceptable".
--
-- Entities validate what is written into them. Commands validate what a client
-- sent. Config validates what a server owner typed. Three implementations of
-- the same idea would drift, and the one that drifts is the one somebody is
-- pushing against.
--
-- A field spec is a small table:
--
--   { type = "integer", required = true, min = 0, max = 1000 }
--   { type = "string", enum = { "black", "white" }, default = "black" }
--   { type = "id", kind = "chr" }
--   { type = "money" }
--   { type = "table" }                  -- must still be JSON-safe
--   { type = "string", check = function(v) return v ~= "root", "reserved" end }
--
-- Absent means absent. A field with a default gets it; a field marked required
-- must be supplied; anything else may simply be missing. Unknown keys are
-- refused rather than ignored, which is the rule that stops a client setting
-- something the server never meant to expose.

local Id = require("domain.id")
local Money = require("domain.money")

local Schema = {}

local function is_finite_number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

Schema.is_finite_number = is_finite_number

local CHECKERS = {
    string  = function(v) return type(v) == "string" end,
    integer = function(v) return math.type(v) == "integer" end,
    number  = is_finite_number,
    boolean = function(v) return type(v) == "boolean" end,
    money   = function(v) return Money.is(v) end,
    id      = function(v) return Id.is_valid(v) end,
    table   = function(v) return type(v) == "table" end,
}

Schema.CHECKERS = CHECKERS

--- How deep a plain value may nest. A value is written inside its record and
--- its record inside a collection, so it is held a few levels short of what the
--- encoder takes (support/json.lua MAX_DEPTH, 64).
local PLAIN_DEPTH = 56

Schema.PLAIN_DEPTH = PLAIN_DEPTH

--- Whether a value can survive a JSON round trip. A table field, an event
--- payload and a history entry all have to, and catching a function or a
--- metatable here beats discovering it when the save runs.
---
--- The rules are the encoder's, all of them. A table with keys 1 and "1", or
--- nested past what the encoder writes, passed here and then failed to encode
--- at flush, after other collections had already been written -- a refund on
--- disk from a save that answered false, beside a stash from the save before.
local function check_plain(value, path, seen, depth)
    seen = seen or {}
    depth = depth or 1
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return true end
    if kind == "number" then
        if not is_finite_number(value) then return false, path .. " is not a finite number" end
        return true
    end
    if kind ~= "table" then return false, ("%s holds a %s, which does not persist"):format(path, kind) end
    if seen[value] then return false, path .. " contains a cycle" end
    if getmetatable(value) ~= nil then return false, path .. " has a metatable, which does not persist" end
    if depth > PLAIN_DEPTH then
        return false, ("%s is nested deeper than %d, which does not persist"):format(path, PLAIN_DEPTH)
    end
    seen[value] = true
    local written = {}
    for key, item in pairs(value) do
        local key_kind = type(key)
        if key_kind ~= "string" and math.type(key) ~= "integer" then
            seen[value] = nil
            return false, ("%s has a %s key, which does not persist"):format(path, key_kind)
        end
        local as_text = key_kind == "string" and key or tostring(key)
        if written[as_text] then
            seen[value] = nil
            return false, ("%s has two keys that both write as %s"):format(path, as_text)
        end
        written[as_text] = true
        local ok, why = check_plain(item, ("%s.%s"):format(path, tostring(key)), seen, depth + 1)
        if not ok then
            seen[value] = nil
            return false, why
        end
    end
    seen[value] = nil
    return true
end

Schema.check_plain = check_plain

--- Check one value against one field spec. Returns true, or false and a
--- sentence naming the field, because this text reaches a player.
local function check_field(name, spec, value)
    local checker = CHECKERS[spec.type]
    if not checker then
        return false, ("%s has unknown type %s"):format(name, tostring(spec.type))
    end
    if not checker(value) then
        return false, ("%s must be a %s, got %s"):format(name, spec.type, type(value))
    end
    if spec.type == "id" and spec.kind and not Id.is_a(value, spec.kind) then
        return false, ("%s must be a %s id, got %s"):format(name, spec.kind, value)
    end
    if spec.type == "table" then
        local ok, why = check_plain(value, name)
        if not ok then return false, why end
    end
    if spec.enum then
        local found = false
        for _, allowed in ipairs(spec.enum) do
            if value == allowed then found = true break end
        end
        if not found then
            return false, ("%s must be one of %s, got %s")
                :format(name, table.concat(spec.enum, ", "), tostring(value))
        end
    end
    if spec.type == "string" then
        if spec.max and #value > spec.max then
            return false, ("%s must be at most %d characters, got %d"):format(name, spec.max, #value)
        end
        if spec.min and #value < spec.min then
            return false, ("%s must be at least %d characters, got %d"):format(name, spec.min, #value)
        end
        if spec.pattern and not value:match(spec.pattern) then
            return false, ("%s is not in the expected form"):format(name)
        end
    end
    if spec.type == "integer" or spec.type == "number" then
        if spec.min and value < spec.min then
            return false, ("%s must be at least %s, got %s"):format(name, spec.min, value)
        end
        if spec.max and value > spec.max then
            return false, ("%s must be at most %s, got %s"):format(name, spec.max, value)
        end
    end
    if spec.type == "money" then
        if spec.min and value < spec.min then
            return false, ("%s must be at least %s, got %s"):format(name, tostring(spec.min), tostring(value))
        end
        if spec.max and value > spec.max then
            return false, ("%s must be at most %s, got %s"):format(name, tostring(spec.max), tostring(value))
        end
        if spec.positive and not value:is_positive() then
            return false, ("%s must be more than nothing"):format(name)
        end
    end
    if spec.check then
        local ok, why = spec.check(value)
        if not ok then return false, why or (name .. " failed its check") end
    end
    return true
end

Schema.check_field = check_field

--- Check that a field spec itself makes sense, at definition time rather than
--- at three in the morning.
function Schema.check_spec(name, spec)
    if type(spec) ~= "table" then return false, ("field %s needs a spec table"):format(tostring(name)) end
    if not CHECKERS[spec.type] then
        return false, ("field %s has unknown type %s"):format(name, tostring(spec.type))
    end
    if spec.default ~= nil then
        local ok, why = check_field(name, spec, spec.default)
        if not ok then return false, ("default for %s is invalid: %s"):format(name, tostring(why)) end
    end
    if spec.enum ~= nil and type(spec.enum) ~= "table" then
        return false, ("enum for %s must be a list"):format(name)
    end
    if spec.check ~= nil and type(spec.check) ~= "function" then
        return false, ("check for %s must be a function"):format(name)
    end
    return true
end

--- Validate a whole table of values against a table of field specs. Returns a
--- clean copy holding exactly the declared fields, or nil and the first
--- problem. The copy matters: what comes back is what the caller may use, so a
--- stray key in the input cannot reach anything downstream.
function Schema.validate(fields, values, opts)
    opts = opts or {}
    if values ~= nil and type(values) ~= "table" then
        return nil, "expected a table of values"
    end
    values = values or {}
    local clean = {}
    for name, spec in pairs(fields) do
        local value = values[name]
        if value == nil and opts.defaults ~= false then value = spec.default end
        if value == nil then
            if spec.required then return nil, name .. " is required" end
        else
            local ok, why = check_field(name, spec, value)
            if not ok then return nil, why end
            clean[name] = value
        end
    end
    for name in pairs(values) do
        if fields[name] == nil then
            return nil, ("%s is not an expected field"):format(tostring(name))
        end
    end
    return clean
end

return Schema
