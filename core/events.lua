--- Domain events: what the simulation says happened.
--
-- The simulation never calls a native, never draws a notification and never
-- writes to a database. It says "money.transferred" and goes back to work.
-- Everything that reacts to the city lives on the other side of this bus, so
-- the rules can be run and tested with no game attached.
--
-- Three properties it has to keep:
--
--   One bad listener cannot stop the others. A notification script erroring
--   must not prevent the bank from recording the transfer. Every handler runs
--   inside a pcall and the failure is reported, not thrown.
--
--   A payload is plain data. It gets logged, replayed and in some cases sent
--   to a client, so it may hold only what JSON can hold. Checking that at emit
--   is the difference between a clear error here and a save failing later.
--
--   Emission is bounded. A handler emitting an event that leads back to itself
--   is a stack overflow on a live server; the depth guard turns it into a
--   reported error with the chain named.

local Schema = require("domain.schema")

local Events = {}
Events.__index = Events

-- namespace.name, optionally deeper: money.transferred, vehicle.impound.due
local NAME_PATTERN = "^%l[%l%d_]*%.[%l%d_]+[%l%d_%.]*$"
local MAX_DEPTH = 16
local HISTORY_LIMIT = 256

Events.MAX_DEPTH = MAX_DEPTH

function Events.is_name(name)
    return type(name) == "string" and #name <= 64 and name:match(NAME_PATTERN) ~= nil
        and not name:find("%.%.") and not name:find("%.$")
end

local function require_name(name)
    if not Events.is_name(name) then
        error(("an event name looks like money.transferred; got %s"):format(tostring(name)), 3)
    end
    return name
end

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deep_copy(item) end
    return out
end

--- opts.clock          function returning integer milliseconds
--- opts.on_error       called with (message, event, subscriber_name)
--- opts.history_limit  how many recent events to keep for debugging
function Events.new(opts)
    opts = opts or {}
    return setmetatable({
        _subscribers = {},      -- name -> array of subscriptions, priority order
        _watchers = {},         -- every event, whatever its name
        _history = {},
        _history_limit = opts.history_limit or HISTORY_LIMIT,
        _clock = opts.clock or function() return math.floor(os.time()) * 1000 end,
        _on_error = opts.on_error,
        _sequence = 0,
        _depth = 0,
        _chain = {},
        _deep_failures = {},
        _errors = 0,
    }, Events)
end

--- Listen. Higher priority runs first, which is how a rule that can veto sits
--- ahead of a cosmetic reaction. opts.once removes it after one delivery.
function Events:on(name, handler, opts)
    require_name(name)
    assert(type(handler) == "function", "a subscriber is a function")
    opts = opts or {}
    local subscription = {
        name = name,
        handler = handler,
        label = opts.label or "anonymous",
        priority = opts.priority or 0,
        once = opts.once == true,
        calls = 0,
    }
    local list = self._subscribers[name]
    if not list then
        list = {}
        self._subscribers[name] = list
    end
    list[#list + 1] = subscription
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.label < b.label
    end)
    return subscription
end

--- Watch every event, whatever it is called.
---
--- `on` is for a handler that knows the name it wants. A watcher is for the
--- things that cannot: a log, and the surface that hands this city's events to
--- the rest of the server, which has to work for events written after it.
---
--- Returns a handle to pass to `unwatch`.
function Events:watch(handler, opts)
    assert(type(handler) == "function", "a watcher is a function")
    opts = opts or {}
    local watcher = { handler = handler, label = opts.label or "anonymous", calls = 0 }
    self._watchers[#self._watchers + 1] = watcher
    return watcher
end

function Events:unwatch(watcher)
    for index, held in ipairs(self._watchers) do
        if held == watcher then
            table.remove(self._watchers, index)
            return true
        end
    end
    return false
end

function Events:watching()
    return #self._watchers
end

function Events:off(subscription)
    if type(subscription) ~= "table" then return false end
    local list = self._subscribers[subscription.name]
    if not list then return false end
    for index, candidate in ipairs(list) do
        if candidate == subscription then
            table.remove(list, index)
            if #list == 0 then self._subscribers[subscription.name] = nil end
            return true
        end
    end
    return false
end

function Events:count(name)
    if name then return #(self._subscribers[name] or {}) end
    local total = 0
    for _, list in pairs(self._subscribers) do total = total + #list end
    return total
end

function Events:names()
    local out = {}
    for name in pairs(self._subscribers) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Build an event record without delivering it. The command bus uses this to
--- hold events until its handler has succeeded, so a command that fails
--- half-way announces nothing.
function Events:build(name, payload)
    require_name(name)
    if payload ~= nil then
        local ok, why = Schema.check_plain(payload, "payload")
        if not ok then
            error(("event %s carries something that does not persist: %s"):format(name, why), 3)
        end
    end
    self._sequence = self._sequence + 1
    -- Nothing is an empty payload; anything else, `false` included, is kept.
    -- `payload and deep_copy(payload) or {}` turned a `false` into a table.
    local carried = {}
    if payload ~= nil then carried = deep_copy(payload) end
    return {
        name = name,
        at = self._clock(),
        sequence = self._sequence,
        payload = carried,
    }
end

local function remember(self, event)
    self._history[#self._history + 1] = event
    while #self._history > self._history_limit do table.remove(self._history, 1) end
end

-- A failure deep inside a chain of handlers has nobody above it to report to:
-- the handler that caused it sees a normal return, so its own pcall succeeds.
-- These are collected on the bus and drained by the outermost publish, which
-- is where a caller actually looks.
--- Everything watching, whatever the name. Watchers run after the subscribers
--- for that name, so what they see is the event as it ended up, errors and all.
---
--- A watcher that throws is a watcher that throws. It is counted and reported
--- the same way a subscriber is, and it cannot stop the others or the caller:
--- a log, or another resource listening in, has no business breaking the city.
local function tell_watchers(self, event)
    for _, watcher in ipairs(self._watchers) do
        local ok, err = pcall(watcher.handler, event)
        watcher.calls = watcher.calls + 1
        if not ok then
            self._errors = self._errors + 1
            if self._on_error then
                self._on_error(("%s watching %s: %s"):format(watcher.label, event.name, tostring(err)),
                    event, watcher.label)
            end
        end
    end
end

local function finish(self, event, ran, failures, outermost)
    if outermost and #self._deep_failures > 0 then
        for _, message in ipairs(self._deep_failures) do failures[#failures + 1] = message end
        self._deep_failures = {}
        event.errors = failures
    end
    tell_watchers(self, event)
    return event, ran, failures
end

--- Deliver an already-built event. Returns the event, the number of handlers
--- that ran, and the list of handlers that failed.
function Events:publish(event)
    assert(type(event) == "table" and event.name, "publish takes an event from Events:build")
    local outermost = self._depth == 0

    if self._depth >= MAX_DEPTH then
        local chain = table.concat(self._chain, " -> ")
        local message = ("event recursion is %d deep: %s -> %s"):format(self._depth, chain, event.name)
        self._errors = self._errors + 1
        if self._on_error then self._on_error(message, event, "bus") end
        event.errors = { message }
        remember(self, event)
        self._deep_failures[#self._deep_failures + 1] = message
        return event, 0, event.errors
    end

    remember(self, event)
    local list = self._subscribers[event.name]
    if not list or #list == 0 then return finish(self, event, 0, {}, outermost) end

    -- Copy the list: a handler may subscribe or unsubscribe while we deliver,
    -- and changing the array being walked is how one gets skipped.
    local delivering = {}
    for index, subscription in ipairs(list) do delivering[index] = subscription end

    self._depth = self._depth + 1
    self._chain[#self._chain + 1] = event.name

    local ran, failures = 0, {}
    for _, subscription in ipairs(delivering) do
        local ok, err = pcall(subscription.handler, event.payload, event)
        subscription.calls = subscription.calls + 1
        if subscription.once then self:off(subscription) end
        if ok then
            ran = ran + 1
        else
            local message = ("%s handling %s: %s"):format(subscription.label, event.name, tostring(err))
            failures[#failures + 1] = message
            self._errors = self._errors + 1
            if self._on_error then self._on_error(message, event, subscription.label) end
        end
    end

    self._chain[#self._chain] = nil
    self._depth = self._depth - 1

    if #failures > 0 then event.errors = failures end
    return finish(self, event, ran, failures, outermost)
end

--- Build and deliver in one step, which is what most callers want.
function Events:emit(name, payload)
    return self:publish(self:build(name, payload))
end

--- The last events, newest last. For an admin command and for working out
--- what actually happened before a report came in.
function Events:history(limit)
    local out = {}
    local from = limit and math.max(1, #self._history - limit + 1) or 1
    for index = from, #self._history do out[#out + 1] = self._history[index] end
    return out
end

function Events:errors() return self._errors end

function Events:clear_history()
    self._history = {}
    return self
end

return Events
