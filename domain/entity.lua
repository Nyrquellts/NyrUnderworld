--- The shape every persistent thing in the city shares.
--
-- A vehicle, a property, a crew, a warrant, a shipment: each is an entity. An
-- entity has a stable id, knows when it was made and last changed, sits in a
-- named lifecycle state, validates what is put into it, serialises to a plain
-- table a database will accept, remembers what happened to it, and prints as
-- something a developer can read at three in the morning.
--
-- Two rules earn their keep here:
--
--   Unknown fields are refused, not ignored. Every entity eventually gets
--   built from something a client sent. Ignoring an unexpected key is how a
--   client sets a field the server never meant to expose.
--
--   States are a declared graph, not a string. "stored" -> "spawned" is legal;
--   "impounded" -> "spawned" is not, and the refusal is the rule rather than
--   an if-statement somebody forgets to write in the second call site.
--
-- Pure Lua. No FiveM natives, no globals. The clock is injectable.

local Id = require("domain.id")
local Money = require("domain.money")
local Schema = require("domain.schema")

local Entity = {}

local HISTORY_LIMIT = 64
local registry = {}

-- ----------------------------------------------------------------- the clock

local clock = function() return math.floor(os.time()) * 1000 end

--- Install a millisecond clock. The server adapter passes the real one; specs
--- pass a pinned one so a serialised record is identical across runs. Returns
--- the clock it replaced, so a caller can put it back.
function Entity.set_clock(fn)
    assert(type(fn) == "function", "a clock is a function returning integer milliseconds")
    local previous = clock
    clock = fn
    return previous
end

function Entity.now() return clock() end

-- ------------------------------------------------------------ field checking

-- One implementation of "is this value acceptable", shared with commands and
-- anything else that takes input from somewhere it does not control. Two
-- implementations would drift, and the one that drifts is the one somebody is
-- pushing against. See domain/schema.lua.
local CHECKERS = Schema.CHECKERS
local check_plain = Schema.check_plain
local check_field = Schema.check_field

-- ------------------------------------------------------------------- copying

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deep_copy(item) end
    return out
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if getmetatable(a) or getmetatable(b) then return a == b end
    for key, item in pairs(a) do
        if not deep_equal(item, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

Entity.deep_equal = deep_equal

-- ------------------------------------------------------------------- methods

local Methods = {}

function Methods:get(field)
    return self.data[field]
end

--- Whole-entity validation. Cheap enough to call at a system boundary, and it
--- is the one place that says what a valid one of these means.
function Methods:validate()
    local spec = getmetatable(self).__type
    if not Id.is_a(self.id, self.kind) then
        return false, ("id %s is not a %s id"):format(tostring(self.id), self.kind)
    end
    if spec.states and not spec.states[self.state] then
        return false, ("%s is not a state of %s"):format(tostring(self.state), self.kind)
    end
    for name, field in pairs(spec.fields) do
        local value = self.data[name]
        if value == nil then
            if field.required then return false, name .. " is required" end
        else
            local ok, why = check_field(name, field, value)
            if not ok then return false, why end
        end
    end
    for name in pairs(self.data) do
        if not spec.fields[name] then return false, name .. " is not a field of " .. self.kind end
    end
    return true
end

function Methods:touch(now)
    self.updated_at = now or clock()
    return self
end

--- Append to the chain of custody. Capped: an unbounded history on a live
--- server is a memory leak with a nice name, so the oldest entries go and the
--- count of what went is kept, which is the honest thing to show in a UI.
function Methods:record(event, meta, now)
    assert(type(event) == "string" and event ~= "", "an entry needs an event name")
    if meta ~= nil then
        local ok, why = check_plain(meta, "meta")
        if not ok then error("history meta " .. why, 2) end
    end
    local entry = { at = now or clock(), event = event, meta = meta and deep_copy(meta) or nil }
    self.history[#self.history + 1] = entry
    while #self.history > HISTORY_LIMIT do
        table.remove(self.history, 1)
        self.history_dropped = self.history_dropped + 1
    end
    return entry
end

--- Set one field. Returns ok, err rather than throwing: most callers are
--- reacting to a player doing something, and a refusal is a normal outcome.
function Methods:set(field, value, opts)
    local spec = getmetatable(self).__type
    local field_spec = spec.fields[field]
    if not field_spec then return false, field .. " is not a field of " .. self.kind end
    if value == nil then
        if field_spec.required then return false, field .. " is required" end
    else
        local ok, why = check_field(field, field_spec, value)
        if not ok then return false, why end
    end
    opts = opts or {}
    local before = self.data[field]
    self.data[field] = type(value) == "table" and not Money.is(value) and deep_copy(value) or value
    self:touch(opts.now)
    if opts.record ~= false then
        self:record("set:" .. field, { from = tostring(before), to = tostring(value) }, opts.now)
    end
    return true
end

--- Set several fields at once, all or nothing. A half-applied update is worse
--- than a refused one.
---
--- This cannot clear a field. `{ driver = nil }` is a table with no keys at
--- all, so a patch asking for it silently does nothing. Use `set(field, nil)`,
--- which says what it means and is checked.
function Methods:patch(changes, opts)
    local spec = getmetatable(self).__type
    for field, value in pairs(changes) do
        local field_spec = spec.fields[field]
        if not field_spec then return false, field .. " is not a field of " .. self.kind end
        if value ~= nil then
            local ok, why = check_field(field, field_spec, value)
            if not ok then return false, why end
        end
    end
    for field, value in pairs(changes) do
        self:set(field, value, opts)
    end
    return true
end

--- Move along the declared lifecycle graph.
function Methods:transition(state, opts)
    local spec = getmetatable(self).__type
    if not spec.states then return false, self.kind .. " has no lifecycle" end
    if not spec.states[state] then return false, tostring(state) .. " is not a state of " .. self.kind end
    if state == self.state then return false, ("already %s"):format(state) end
    local permitted = false
    for _, candidate in ipairs(spec.states[self.state]) do
        if candidate == state then permitted = true break end
    end
    if not permitted then
        return false, ("%s cannot go from %s to %s"):format(self.kind, self.state, state)
    end
    opts = opts or {}
    local from = self.state
    self.state = state
    self:touch(opts.now)
    self:record("state", { from = from, to = state, reason = opts.reason }, opts.now)
    return true
end

function Methods:can_transition(state)
    local spec = getmetatable(self).__type
    if not (spec.states and spec.states[self.state]) then return false end
    for _, candidate in ipairs(spec.states[self.state]) do
        if candidate == state then return true end
    end
    return false
end

--- A plain table, safe to hand to a JSON encoder or a database driver. Money
--- becomes its integer minor units, which is also how it should sit in a
--- column.
function Methods:serialize()
    local spec = getmetatable(self).__type
    local data = {}
    for name, field in pairs(spec.fields) do
        local value = self.data[name]
        if value ~= nil then
            if field.type == "money" then
                data[name] = value:to_minor()
            else
                data[name] = deep_copy(value)
            end
        end
    end
    return {
        id = self.id,
        kind = self.kind,
        schema = spec.schema,
        created_at = self.created_at,
        updated_at = self.updated_at,
        state = self.state,
        data = data,
        history = deep_copy(self.history),
        history_dropped = self.history_dropped,
    }
end

function Methods:equals(other)
    if type(other) ~= "table" then return false end
    return deep_equal(self:serialize(), other.serialize and other:serialize() or other)
end

local function describe(self)
    local spec = getmetatable(self).__type
    local names = {}
    for name in pairs(spec.fields) do names[#names + 1] = name end
    table.sort(names)
    local shown = {}
    for _, name in ipairs(names) do
        local value = self.data[name]
        if value ~= nil then
            local text = type(value) == "table" and not Money.is(value) and "{...}" or tostring(value)
            if #text > 24 then text = text:sub(1, 21) .. "..." end
            shown[#shown + 1] = ("%s=%s"):format(name, text)
        end
        if #shown >= 4 then break end
    end
    return ("<%s %s %s%s%s>"):format(self.kind, self.id, self.state,
        #shown > 0 and " " or "", table.concat(shown, " "))
end

Methods.describe = describe

-- ------------------------------------------------------------------ defining

-- A kind with no declared lifecycle still has a state, so every record has the
-- same shape and every debug line prints. It simply cannot move.
local IMPLICIT_STATE = "active"

local function normalise_states(spec)
    if not spec.states then return nil, IMPLICIT_STATE end
    local states = {}
    for name, nexts in pairs(spec.states) do
        assert(type(name) == "string", "a state name is a string")
        assert(type(nexts) == "table", ("state %s must list the states it can go to"):format(name))
        states[name] = nexts
    end
    for name, nexts in pairs(states) do
        for _, target in ipairs(nexts) do
            assert(states[target], ("state %s goes to %s, which is not a state"):format(name, target))
        end
    end
    local initial = spec.initial
    assert(initial and states[initial], "a lifecycle needs an initial state that exists")
    return states, initial
end

--- Declare a kind of thing.
function Entity.define(kind, spec)
    assert(Id.is_kind(kind), ("entity kind %s is not a valid id kind"):format(tostring(kind)))
    assert(not registry[kind], ("entity kind %s is already defined"):format(kind))
    assert(type(spec) == "table" and type(spec.fields) == "table", "an entity needs fields")

    for name, field in pairs(spec.fields) do
        assert(type(name) == "string" and name:match("^[%a_][%w_]*$"),
            ("field name %s is not a plain identifier"):format(tostring(name)))
        assert(CHECKERS[field.type], ("field %s has unknown type %s"):format(name, tostring(field.type)))
        if field.default ~= nil then
            local ok, why = check_field(name, field, field.default)
            assert(ok, ("default for %s is invalid: %s"):format(name, tostring(why)))
        end
    end

    local states, initial = normalise_states(spec)
    local type_obj = {
        kind = kind,
        fields = spec.fields,
        states = states,
        initial = initial,
        schema = spec.schema or 1,
        migrate = spec.migrate,
    }
    local mt = { __index = Methods, __tostring = describe, __type = type_obj, __name = "entity:" .. kind }
    type_obj.metatable = mt

    --- Build one. opts.now pins the clock, opts.id supplies an id, opts.random
    --- pins the randomness inside a generated id.
    function type_obj.new(attrs, opts)
        attrs, opts = attrs or {}, opts or {}
        local now = opts.now or clock()
        local data = {}
        for name, field in pairs(spec.fields) do
            local value = attrs[name]
            if value == nil then value = field.default end
            if value == nil then
                if field.required then return nil, name .. " is required" end
            else
                local ok, why = check_field(name, field, value)
                if not ok then return nil, why end
                data[name] = type(value) == "table" and not Money.is(value) and deep_copy(value) or value
            end
        end
        for name in pairs(attrs) do
            if not spec.fields[name] then return nil, name .. " is not a field of " .. kind end
        end
        local id = opts.id or Id.new(kind, { now = now, random = opts.random })
        if not Id.is_a(id, kind) then return nil, ("%s is not a %s id"):format(tostring(id), kind) end
        local entity = setmetatable({
            id = id,
            kind = kind,
            created_at = now,
            updated_at = now,
            state = initial,
            data = data,
            history = {},
            history_dropped = 0,
        }, mt)
        entity:record("created", opts.because and { because = opts.because } or nil, now)
        return entity
    end

    --- Build one from a serialised record. Refuses anything it cannot make a
    --- valid entity out of, because a half-loaded entity corrupts quietly.
    function type_obj.deserialize(record)
        if type(record) ~= "table" then return nil, "a record is a table" end
        if record.kind ~= kind then
            return nil, ("record is a %s, not a %s"):format(tostring(record.kind), kind)
        end
        local schema = record.schema or 1
        if schema ~= type_obj.schema then
            if not type_obj.migrate then
                return nil, ("%s record is schema %s, this build reads %s, and no migration is declared")
                    :format(kind, tostring(schema), type_obj.schema)
            end
            local migrated, why = type_obj.migrate(deep_copy(record), schema)
            if not migrated then return nil, why or "migration failed" end
            record = migrated
            if (record.schema or 1) ~= type_obj.schema then
                return nil, "migration did not reach the current schema"
            end
        end
        local data = {}
        for name, field in pairs(spec.fields) do
            local value = (record.data or {})[name]
            -- A field added after this record was written falls back to its
            -- default, so adding an optional field with a default is
            -- backward-compatible and needs no migration. A field with no
            -- default and no stored value stays absent, and is refused below
            -- if it was required.
            if value == nil and field.default ~= nil then value = field.default end
            if value ~= nil then
                if field.type == "money" then
                    if math.type(value) ~= "integer" then
                        return nil, name .. " should be stored as integer minor units"
                    end
                    value = Money.from_minor(value)
                else
                    value = deep_copy(value)
                end
                local ok, why = check_field(name, field, value)
                if not ok then return nil, why end
                data[name] = value
            elseif field.required then
                return nil, name .. " is required"
            end
        end
        for name in pairs(record.data or {}) do
            if not spec.fields[name] then return nil, name .. " is not a field of " .. kind end
        end
        if not Id.is_a(record.id, kind) then
            return nil, ("%s is not a %s id"):format(tostring(record.id), kind)
        end
        if states and record.state ~= nil and not states[record.state] then
            return nil, ("%s is not a state of %s"):format(tostring(record.state), kind)
        end
        return setmetatable({
            id = record.id,
            kind = kind,
            created_at = record.created_at or clock(),
            updated_at = record.updated_at or record.created_at or clock(),
            state = record.state or initial,
            data = data,
            history = deep_copy(record.history or {}),
            history_dropped = record.history_dropped or 0,
        }, mt)
    end

    registry[kind] = type_obj
    return type_obj
end

--- Rebuild anything, when the kind is only known at runtime: a save file, a
--- database row, a message off the wire.
function Entity.deserialize(record)
    if type(record) ~= "table" then return nil, "a record is a table" end
    local type_obj = registry[record.kind]
    if not type_obj then return nil, ("no entity kind %s is defined"):format(tostring(record.kind)) end
    return type_obj.deserialize(record)
end

function Entity.of(kind) return registry[kind] end

function Entity.kinds()
    local names = {}
    for name in pairs(registry) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function Entity.is(value)
    local mt = getmetatable(value)
    return mt ~= nil and mt.__type ~= nil and registry[mt.__type.kind] == mt.__type
end

Entity.HISTORY_LIMIT = HISTORY_LIMIT

return Entity
