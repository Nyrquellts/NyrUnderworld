--- JSON that does not quietly change the numbers.
--
-- The reason this is not a one-line dependency: most Lua JSON libraries decode
-- every number as a float. Money in this project is a whole count of minor
-- units, and an integer field that comes back as 2500000.0 fails its own
-- validation on load. So the decoder returns an integer whenever the literal
-- was written as one, and the encoder writes integers without a decimal point.
--
-- It also sorts object keys. A save file that differs only by table order is a
-- save file nobody can diff, and a diff is how you find out what a bug wrote.
--
-- Pure Lua, no globals, no dependencies. Encoding refuses what JSON cannot
-- carry: NaN, infinity, functions, cycles. Decoding refuses malformed input
-- rather than guessing, and stops at a depth limit so a hostile payload cannot
-- exhaust the stack.

local json = {}

local MAX_DEPTH = 64

json.MAX_DEPTH = MAX_DEPTH

-- A stand-in for JSON null, since a Lua table cannot hold nil. Decoding turns
-- null into this; encoding turns it back.
json.null = setmetatable({}, { __tostring = function() return "null" end, __name = "json.null" })

-- --------------------------------------------------------------- encoding

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_string(text)
    return (text:gsub('[%z\1-\31"\\]', function(char)
        return ESCAPES[char] or ("\\u%04x"):format(char:byte())
    end))
end

local function encode_number(value)
    if value ~= value then error("cannot encode NaN as JSON", 0) end
    if value == math.huge or value == -math.huge then error("cannot encode infinity as JSON", 0) end
    if math.type(value) == "integer" then return tostring(value) end
    -- %.17g round-trips a double exactly. If it comes out looking like an
    -- integer, say so, or a float field silently becomes an integer field on
    -- the next load and a type check somewhere downstream starts failing.
    local text = ("%.17g"):format(value)
    if not text:find("[%.eEn]") then text = text .. ".0" end
    return text
end

-- An array to JSON is a table whose keys are exactly 1..n. Anything else is an
-- object. A table with both, such as { 1, 2, name = "x" }, cannot be either
-- and is refused rather than silently losing half its content.
local function array_length(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    local length = 0
    for index in ipairs(value) do length = index end
    if count == 0 then return nil end
    if count == length then return length end
    return nil, count
end

local encode_value

local function encode_table(value, out, depth, seen)
    if depth > MAX_DEPTH then error("JSON nesting is deeper than " .. MAX_DEPTH, 0) end
    if seen[value] then error("cannot encode a table that contains itself", 0) end
    seen[value] = true

    local length = array_length(value)
    if length then
        out[#out + 1] = "["
        for index = 1, length do
            if index > 1 then out[#out + 1] = "," end
            encode_value(value[index], out, depth + 1, seen)
        end
        out[#out + 1] = "]"
    else
        local keys, seen_key = {}, {}
        for key in pairs(value) do
            local key_type = type(key)
            local as_text = key_type == "string" and key or tostring(key)
            if seen_key[as_text] then
                error(("object has two keys that both write as %s"):format(as_text), 0)
            end
            seen_key[as_text] = true
            if key_type == "string" then
                keys[#keys + 1] = key
            elseif math.type(key) == "integer" then
                -- A sparse or one-based-broken array becomes an object with
                -- numeric keys as strings, which is what JSON can carry.
                keys[#keys + 1] = tostring(key)
            else
                error(("cannot encode a %s key as JSON"):format(key_type), 0)
            end
        end
        table.sort(keys)
        out[#out + 1] = "{"
        for index, key in ipairs(keys) do
            if index > 1 then out[#out + 1] = "," end
            out[#out + 1] = '"' .. escape_string(key) .. '":'
            local item = value[key]
            if item == nil then item = value[tonumber(key)] end
            encode_value(item, out, depth + 1, seen)
        end
        out[#out + 1] = "}"
    end
    seen[value] = nil
end

encode_value = function(value, out, depth, seen)
    if value == json.null or value == nil then
        out[#out + 1] = "null"
    elseif type(value) == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif type(value) == "number" then
        out[#out + 1] = encode_number(value)
    elseif type(value) == "string" then
        out[#out + 1] = '"' .. escape_string(value) .. '"'
    elseif type(value) == "table" then
        encode_table(value, out, depth, seen)
    else
        error(("cannot encode a %s as JSON"):format(type(value)), 0)
    end
end

--- Encode. Returns the text, or nil plus a reason.
--- opts.indent writes it out readable, for a file a person will open.
function json.encode(value, opts)
    local out = {}
    local ok, err = pcall(encode_value, value, out, 1, {})
    if not ok then return nil, err end
    local text = table.concat(out)
    if opts and opts.indent then return json.prettify(text) end
    return text
end

--- Re-space compact JSON for a human reader. Kept separate from the encoder so
--- the encoder stays one straightforward pass.
function json.prettify(text)
    local out, depth, in_string, escaped = {}, 0, false, false
    local pad = function(n) return "\n" .. string.rep("  ", n) end
    for index = 1, #text do
        local char = text:sub(index, index)
        if in_string then
            out[#out + 1] = char
            if escaped then escaped = false
            elseif char == "\\" then escaped = true
            elseif char == '"' then in_string = false end
        elseif char == '"' then
            in_string = true
            out[#out + 1] = char
        elseif char == "{" or char == "[" then
            depth = depth + 1
            out[#out + 1] = char .. pad(depth)
        elseif char == "}" or char == "]" then
            depth = depth - 1
            out[#out + 1] = pad(depth) .. char
        elseif char == "," then
            out[#out + 1] = "," .. pad(depth)
        elseif char == ":" then
            out[#out + 1] = ": "
        else
            out[#out + 1] = char
        end
    end
    return table.concat(out)
end

-- --------------------------------------------------------------- decoding

local function skip_space(text, position)
    local _, stop = text:find("^[ \t\r\n]*", position)
    return stop + 1
end

local parse_value

local function fail(position, message)
    error({ position = position, message = message }, 0)
end

local UNESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

-- Every loop in this parser is bounded by the length of the input rather than
-- written as `while true`. The input is untrusted: if any path ever failed to
-- advance the position, an unbounded loop would spin forever and take the
-- server thread with it, and no amount of care in the body is a substitute for
-- a loop that cannot run away.
local function parse_string(text, position)
    position = position + 1
    local out = {}
    while position <= #text do
        local char = text:sub(position, position)
        if char == '"' then return table.concat(out), position + 1 end
        if char == "\\" then
            local code = text:sub(position + 1, position + 1)
            if UNESCAPES[code] then
                out[#out + 1] = UNESCAPES[code]
                position = position + 2
            elseif code == "u" then
                local hex = text:sub(position + 2, position + 5)
                local point = #hex == 4 and hex:match("^%x%x%x%x$") and tonumber(hex, 16)
                if not point then fail(position, "bad \\u escape") end
                position = position + 6
                -- One character beyond the basic plane is escaped as two halves,
                -- and each half on its own is not a character. Decoded apart they
                -- made six bytes that are not UTF-8, which every name check then
                -- refused. A half with no partner is refused rather than guessed.
                if point >= 0xDC00 and point <= 0xDFFF then
                    fail(position - 6, "a lone low surrogate in a \\u escape")
                elseif point >= 0xD800 and point <= 0xDBFF then
                    local low_hex = text:sub(position, position + 1) == "\\u"
                        and text:sub(position + 2, position + 5) or ""
                    local low = #low_hex == 4 and low_hex:match("^%x%x%x%x$") and tonumber(low_hex, 16)
                    if not low or low < 0xDC00 or low > 0xDFFF then
                        fail(position - 6, "a high surrogate with no low surrogate after it")
                    end
                    point = 0x10000 + ((point - 0xD800) << 10) + (low - 0xDC00)
                    position = position + 6
                end
                out[#out + 1] = utf8.char(point)
            else
                fail(position, "unknown escape \\" .. code)
            end
        else
            if char:byte() < 32 then fail(position, "a raw control character in a string") end
            out[#out + 1] = char
            position = position + 1
        end
    end
    fail(position, "unterminated string")
end

local function parse_number(text, position)
    local literal = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", position)
    if not literal or literal == "" then fail(position, "not a number") end
    -- The point of this module: an integer literal stays an integer.
    local is_integer = not literal:find("[%.eE]")
    local value
    if is_integer then
        value = math.tointeger(tonumber(literal))
        if value == nil then
            -- Too large for a Lua integer. Refusing beats handing back a float
            -- that silently lost the low digits of somebody's balance.
            fail(position, "integer literal does not fit in a Lua integer: " .. literal)
        end
    else
        value = tonumber(literal)
        if value == nil then fail(position, "malformed number: " .. literal) end
        -- `1e999` is infinity to tonumber. The encoder refuses to write one, so
        -- the decoder refuses to read one: a value that cannot be saved again
        -- is not a value a save may contain.
        if value == math.huge or value == -math.huge then
            fail(position, "a number too large to hold: " .. literal)
        end
    end
    return value, position + #literal
end

local function parse_array(text, position, depth)
    position = skip_space(text, position + 1)
    local out = {}
    if text:sub(position, position) == "]" then return out, position + 1 end
    while position <= #text do
        local value
        value, position = parse_value(text, position, depth + 1)
        out[#out + 1] = value
        position = skip_space(text, position)
        local char = text:sub(position, position)
        if char == "]" then return out, position + 1 end
        if char ~= "," then fail(position, "expected , or ] in an array") end
        position = skip_space(text, position + 1)
    end
    fail(position, "an array was never closed")
end

local function parse_object(text, position, depth)
    position = skip_space(text, position + 1)
    local out = {}
    if text:sub(position, position) == "}" then return out, position + 1 end
    while position <= #text do
        if text:sub(position, position) ~= '"' then fail(position, "an object key must be a string") end
        local key
        local key_at = position
        key, position = parse_string(text, position)
        -- The encoder refuses to write two keys that collide, so the decoder
        -- refuses to read them: with the last one silently winning, a save
        -- edited by hand with a balance written twice loaded one of them.
        if out[key] ~= nil then fail(key_at, ("the key %q appears twice in an object"):format(key)) end
        position = skip_space(text, position)
        if text:sub(position, position) ~= ":" then fail(position, "expected : after an object key") end
        position = skip_space(text, position + 1)
        local value
        value, position = parse_value(text, position, depth + 1)
        out[key] = value
        position = skip_space(text, position)
        local char = text:sub(position, position)
        if char == "}" then return out, position + 1 end
        if char ~= "," then fail(position, "expected , or } in an object") end
        position = skip_space(text, position + 1)
    end
    fail(position, "an object was never closed")
end

parse_value = function(text, position, depth)
    if depth > MAX_DEPTH then fail(position, "nesting is deeper than " .. MAX_DEPTH) end
    local char = text:sub(position, position)
    if char == "" then fail(position, "input ended early") end
    if char == '"' then return parse_string(text, position) end
    if char == "{" then return parse_object(text, position, depth) end
    if char == "[" then return parse_array(text, position, depth) end
    if text:sub(position, position + 3) == "true" then return true, position + 4 end
    if text:sub(position, position + 4) == "false" then return false, position + 5 end
    if text:sub(position, position + 3) == "null" then return json.null, position + 4 end
    if char:match("[%d%-]") then return parse_number(text, position) end
    fail(position, "unexpected character " .. char)
end

--- Decode. Returns the value, or nil plus a reason naming the offset, because
--- "invalid JSON" on a 40kB save file is not a usable error message.
function json.decode(text)
    if type(text) ~= "string" then return nil, "JSON input must be a string" end
    local ok, value, position = pcall(function()
        local start = skip_space(text, 1)
        local result, stop = parse_value(text, start, 1)
        return result, stop
    end)
    if not ok then
        local err = value
        if type(err) == "table" then
            return nil, ("%s at offset %d"):format(err.message, err.position)
        end
        return nil, tostring(err)
    end
    local tail = skip_space(text, position)
    if tail <= #text then
        return nil, ("trailing content at offset %d"):format(tail)
    end
    return value
end

return json
