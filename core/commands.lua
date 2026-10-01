--- The only door into the simulation.
--
-- Nothing reaches the rules except through a defined command, and a command
-- declares what it accepts before it accepts anything. That is the whole
-- defence against a client that lies, and clients lie: about payouts, about
-- quantities, about who owns what, about whether a job was finished. The
-- server takes the name of the command and an argument table, checks the
-- arguments against the declaration, throws away anything not declared, and
-- only then lets a handler see it.
--
-- Four rules hold this together:
--
--   Nothing undeclared gets through. Extra keys are refused, not ignored.
--
--   Events are held until the handler succeeds. A command that fails half way
--   announces nothing, so no listener acts on a thing that did not happen.
--
--   The same operation id runs once. A retried request, a double click, a
--   replayed packet: one effect. Successful responses are remembered. A failed
--   request that reached the ledger also keeps its payment receipt, including
--   after a refund, so replay cannot authorize a second delivery. A fresh user
--   attempt uses a new id. Mutating handlers use primitives that take the same
--   operation id, including the ledger and ownership register.
--
--   A refusal and a failure are different outcomes. Being short of cash is a
--   normal answer; a broken handler is a bug report. They never look alike.

local Schema = require("domain.schema")
local Outcome = require("core.outcome")
local Money = require("domain.money")

local Commands = {}
Commands.__index = Commands

local NAME_PATTERN = "^%l[%l%d_]*%.[%l%d_]+$"
local AUDIT_LIMIT = 256
local ALWAYS = function() return true end

-- How much of what was done is remembered, and for how long.
--
-- Every successful client request carries a token, and each one used to keep
-- its whole answer in memory for the life of the server and its receipt in
-- every save for the life of the city. Measured: 80,000 requests made a 20 MiB
-- commands record, 1.6 s of the server thread on every save, and on MySQL a
-- packet the server refused -- so the clock, the ledger, ownership and the
-- receipts all stopped being saved at once.
--
-- A token is for a retry: a double click, a packet sent twice, a request sent
-- again after a restart. The client gives up on an answer after fifteen
-- seconds. So an answer is cached for the last few hundred requests, and a
-- receipt is kept for a city day (24 real minutes at the shipped pace) and for
-- the newest few thousand, whichever is less. A receipt let go refuses nothing
-- afterwards, which costs nothing: a client that wants a request run again can
-- always send it with a new token. What must never run twice -- a payment -- is
-- held by the ledger's own receipt, not this one.
local ANSWERS_KEPT = 512
local RECEIPTS_KEPT = 4096
local RECEIPT_KEEP_MS = 24 * 60 * 60 * 1000

Commands.ANSWERS_KEPT = ANSWERS_KEPT
Commands.RECEIPTS_KEPT = RECEIPTS_KEPT
Commands.RECEIPT_KEEP_MS = RECEIPT_KEEP_MS

-- Ids in the order they were remembered. An id can be in here after it was
-- let go by another route; whoever pops it checks.
local function queue() return { items = {}, head = 1, tail = 0 } end

local function push(q, id)
    q.tail = q.tail + 1
    q.items[q.tail] = id
end

local function oldest(q) return q.items[q.head] end

local function pop(q)
    q.items[q.head] = nil
    q.head = q.head + 1
    if q.head > q.tail then q.items, q.head, q.tail = {}, 1, 0 end
end

-- A deterministic, typed encoding binds a receipt to the validated request.
-- Length prefixes keep separators in names/text from creating collisions.
local function fingerprint(value)
    if Money.is(value) then return "m" .. tostring(value:to_minor()) .. ";" end
    local kind = type(value)
    if kind == "table" then
        local parts = {}
        for key, item in pairs(value) do
            parts[#parts + 1] = fingerprint(key) .. fingerprint(item)
        end
        table.sort(parts)
        return "t" .. #parts .. ":" .. table.concat(parts)
    end
    local rendered = kind == "number" and math.type(value) ~= "integer"
        and string.format("%.17g", value) or tostring(value)
    return kind .. #rendered .. ":" .. rendered
end

function Commands.is_name(name)
    return type(name) == "string" and #name <= 48 and name:match(NAME_PATTERN) ~= nil
end

--- opts.events      an event bus; commands publish through it
--- opts.clock       function returning integer milliseconds
--- opts.rate_clock  function returning real milliseconds, for rate limits;
---                  `clock` when not given
--- opts.services    a table handed to every handler as ctx.services
--- opts.on_error    called with (message, name, actor) when a handler breaks
function Commands.new(opts)
    opts = opts or {}
    local clock = opts.clock or function() return math.floor(os.time()) * 1000 end
    return setmetatable({
        _defined = {},
        _audit = {},
        _audit_limit = opts.audit_limit or AUDIT_LIMIT,
        _applied = {},       -- operation id -> the outcome it already had
        _answers = queue(),
        _answer_count = 0,
        _completed = {},     -- durable operation id -> request fingerprint
        _completed_at = {},  -- durable operation id -> city ms it completed at
        _receipts = queue(),
        _receipt_count = 0,
        _sequence = 0,       -- durable ids for requests without a client token
        _rates = {},         -- command -> actor -> array of timestamps
        _clock = clock,
        _rate_clock = opts.rate_clock or clock,
        _errors = 0,
        events = opts.events,
        services = opts.services or {},
        _on_error = opts.on_error,
    }, Commands)
end

--- Declare a command.
---
---   spec.args       field specs, checked by domain/schema
---   spec.handler    function(ctx, args) -> Outcome, or nothing for a plain ok
---   spec.authorise  function(ctx, args) -> true, or false plus a code
---   spec.rate       { per_minute = n } per actor
---   spec.summary    one line, for the command listing
function Commands:define(name, spec)
    assert(Commands.is_name(name), ("a command name looks like vehicle.store; got %s"):format(tostring(name)))
    assert(not self._defined[name], ("command %s is already defined"):format(name))
    assert(type(spec) == "table" and type(spec.handler) == "function", "a command needs a handler")
    local args = spec.args or {}
    for field, field_spec in pairs(args) do
        local ok, why = Schema.check_spec(field, field_spec)
        assert(ok, ("command %s: %s"):format(name, tostring(why)))
    end
    assert(spec.authorise == nil or type(spec.authorise) == "function", "authorise is a function")
    assert(spec.read_only == nil or type(spec.read_only) == "boolean", "read_only is a boolean")
    assert(spec.receipt_scope == nil or spec.receipt_scope == "account", "receipt_scope may be account")
    if spec.rate then
        assert(math.type(spec.rate.per_minute) == "integer" and spec.rate.per_minute > 0,
            ("command %s has a nonsense rate limit"):format(name))
    end
    self._defined[name] = {
        name = name,
        args = args,
        handler = spec.handler,
        authorise = spec.authorise,
        rate = spec.rate,
        summary = spec.summary or "",
        read_only = spec.read_only == true,
        receipt_scope = spec.receipt_scope,
    }
    return self
end

function Commands:defined(name) return self._defined[name] ~= nil end

function Commands:names()
    local out = {}
    for name in pairs(self._defined) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- What a command accepts, for a help listing or a generated client stub.
function Commands:describe(name)
    local command = self._defined[name]
    if not command then return nil end
    local fields = {}
    for field, spec in pairs(command.args) do
        fields[#fields + 1] = {
            name = field,
            type = spec.type,
            required = spec.required == true,
            default = spec.default,
            enum = spec.enum,
        }
    end
    table.sort(fields, function(a, b) return a.name < b.name end)
    return { name = name, summary = command.summary, args = fields, rate = command.rate }
end

local function record_audit(self, entry)
    self._audit[#self._audit + 1] = entry
    while #self._audit > self._audit_limit do table.remove(self._audit, 1) end
end

-- A sliding window per caller. Cheap, and it forgets on its own rather than
-- growing a timestamp list for every player who ever connected.
--
-- The bucket is the acting character, and the account when there is no
-- character yet. That second part is not a nicety: before somebody has chosen
-- a character there is no actor, so keying on the actor alone puts every
-- player who is still at the character screen into one shared bucket, and six
-- people connecting at once rate-limit each other out of creating anybody.
-- The account is established by the server, so it is safe to key on.
local function within_rate(self, command, actor, account, now)
    if not command.rate then return true end
    local per_command = self._rates[command.name]
    if not per_command then
        per_command = {}
        self._rates[command.name] = per_command
    end
    local bucket = actor or account or "anonymous"
    local stamps = per_command[bucket]
    if not stamps then
        stamps = {}
        per_command[bucket] = stamps
    end
    local cutoff = now - 60000
    local kept = {}
    for _, stamp in ipairs(stamps) do
        -- A stamp from after `now` belongs to a clock that has since been
        -- replaced, and would hold a window shut until the new one caught up.
        if stamp > cutoff and stamp <= now then kept[#kept + 1] = stamp end
    end
    if #kept >= command.rate.per_minute then
        per_command[bucket] = kept
        return false
    end
    kept[#kept + 1] = now
    per_command[bucket] = kept
    return true
end

--- Ask the simulation to do something.
---
---   args   whatever the caller has; only declared fields survive
---   meta   { actor = "chr_...", operation_id = "...", source = "client" }
function Commands:dispatch(name, args, meta)
    meta = meta or {}
    local now = self._clock()
    local actor = meta.actor

    local command = self._defined[name]
    if not command then
        local outcome = Outcome.refused("unknown_command", ("there is no command called %s"):format(tostring(name)))
        record_audit(self, { at = now, name = tostring(name), actor = actor, code = outcome.code })
        return outcome
    end

    local operation_id = meta.operation_id
    local client_receipt = operation_id ~= nil
    if operation_id ~= nil then
        if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
            return Outcome.refused("bad_args", "an operation id must contain 1 to 256 characters")
        end
    end

    local clean, why = Schema.validate(command.args, args)
    if not clean then
        local outcome = Outcome.refused("bad_args", why)
        record_audit(self, { at = now, name = name, actor = actor, code = outcome.code, detail = why })
        return outcome
    end

    -- Queries always read the current view and do not grow durable receipts.
    if command.read_only then operation_id, client_receipt = nil, false end
    local receipt_actor = actor
    if command.receipt_scope == "account" then receipt_actor = nil end
    local request = operation_id and fingerprint({ name = name, args = clean,
        actor = receipt_actor, account = meta.account })
    if operation_id then
        local receipt = self._completed[operation_id]
        local previous = self._applied[operation_id]
        local code
        if receipt and receipt ~= request then
            code = "operation_conflict"
        elseif previous then
            record_audit(self, { at = now, name = name, actor = actor, code = "duplicate",
                operation_id = operation_id })
            local repeated = Outcome.ok(previous.value, { events = previous.events })
            repeated.details = { duplicate = true, first_seen = previous.details.first_seen }
            return repeated
        elseif receipt or (self.services.ledger and self.services.ledger.seen[operation_id]) then
            -- After restart the old response is gone, but the effect is not.
            -- Legacy saves also carry payment ids in their ledger. Never let
            -- a duplicate payment acknowledgment authorize delivery again.
            code = "already_completed"
        end
        if code then
            record_audit(self, { at = now, name = name, actor = actor, code = code,
                operation_id = operation_id })
            return Outcome.refused(code, "This request was already recorded. Refresh the view before trying a new request.")
        end
    end

    if not within_rate(self, command, actor, meta.account, self._rate_clock()) then
        local outcome = Outcome.refused("too_fast", "that is being asked for too often")
        record_audit(self, { at = now, name = name, actor = actor, code = outcome.code })
        return outcome
    end

    if not operation_id and not command.read_only then
        -- Two honest commands in the same city millisecond are separate
        -- operations. Timestamp-based fallbacks in handlers cannot tell them
        -- apart, especially immediately after loading a saved clock.
        repeat
            self._sequence = self._sequence + 1
            operation_id = "server-command:" .. self._sequence
        until not (self.services.ledger and self.services.ledger.seen[operation_id])
            and not self._completed[operation_id]
    end

    -- Events are collected here and published only if the handler succeeds.
    local pending = {}
    local context
    context = {
        actor = actor,
        -- The platform identity of whoever is asking, established by the
        -- adapter from the server side. A client never supplies this: the
        -- whole point is that it is the one fact in the request that cannot
        -- be forged.
        account = meta.account,
        now = now,
        source = meta.source,
        operation_id = operation_id,
        services = self.services,
        commands = self,
        --- Announce something that happened. Held until the handler returns.
        emit = function(event_name, payload)
            assert(self.events, ("command %s emitted %s with no event bus attached"):format(name, tostring(event_name)))
            pending[#pending + 1] = self.events:build(event_name, payload)
            return true
        end,
        ok = function(value) return Outcome.ok(value) end,
        refuse = function(code, message, details) return Outcome.refused(code, message, details) end,
    }

    -- authorise may answer true, an Outcome, or false plus a code; pcall hands
    -- back every return value, so the code is not lost on the way out.
    local ran, allowed, reason = pcall(command.authorise or ALWAYS, context, clean)
    if not ran then
        local message = ("%s could not decide whether to allow this: %s"):format(name, tostring(allowed))
        self._errors = self._errors + 1
        if self._on_error then self._on_error(message, name, actor) end
        record_audit(self, { at = now, name = name, actor = actor, code = "failed", detail = message })
        return Outcome.failed(message)
    end
    if allowed ~= true then
        local outcome
        if Outcome.is(allowed) then
            outcome = allowed
        else
            local code = type(allowed) == "string" and allowed
                or (type(reason) == "string" and reason)
                or "not_allowed"
            outcome = Outcome.refused(code, type(reason) == "string" and reason or nil)
        end
        record_audit(self, { at = now, name = name, actor = actor, code = outcome.code })
        return outcome
    end

    local succeeded, handled = pcall(command.handler, context, clean)
    if not succeeded then
        local message = ("%s failed: %s"):format(name, tostring(handled))
        self._errors = self._errors + 1
        if self._on_error then self._on_error(message, name, actor) end
        record_audit(self, { at = now, name = name, actor = actor, code = "failed", detail = message })
        -- Nothing announced, nothing remembered: a retry must be free to work.
        return Outcome.failed(message)
    end

    local outcome = handled
    if outcome == nil then
        outcome = Outcome.ok()
    elseif not Outcome.is(outcome) then
        outcome = Outcome.failed(("%s returned a %s instead of an outcome"):format(name, type(outcome)))
        self._errors = self._errors + 1
        if self._on_error then self._on_error(outcome.message, name, actor) end
        record_audit(self, { at = now, name = name, actor = actor, code = outcome.code })
        return outcome
    end

    if outcome.ok then
        outcome.events = pending
        if client_receipt then
            outcome.details = outcome.details or {}
            outcome.details.first_seen = now
            self:_remember(operation_id, outcome, request, now)
        end
        for _, event in ipairs(pending) do
            self.events:publish(event)
        end
    end

    record_audit(self, {
        at = now, name = name, actor = actor, code = outcome.code,
        operation_id = operation_id, events = #(outcome.events or {}),
    })
    return outcome
end

--- The recent history of what was asked for and what came back. The first
--- thing to read when a player says something went wrong.
function Commands:audit(limit)
    local out = {}
    local from = limit and math.max(1, #self._audit - limit + 1) or 1
    for index = from, #self._audit do out[#out + 1] = self._audit[index] end
    return out
end

--- Let go of receipts past their day, and of the oldest past the count.
function Commands:_trim(now)
    local q = self._receipts
    -- Bounded by what the queue holds, not `while true`: a loop on the server
    -- thread that cannot be shown to end is one Nyr's release check refuses.
    for _ = q.head, q.tail do
        local id = oldest(q)
        if id == nil then break end
        local at = self._completed_at[id]
        if at == nil then
            pop(q)
        elseif self._receipt_count > RECEIPTS_KEPT or at < now - RECEIPT_KEEP_MS then
            pop(q)
            self._completed[id], self._completed_at[id] = nil, nil
            self._receipt_count = self._receipt_count - 1
            -- The cached answer goes with it, so a request sent again with the
            -- same token and different arguments is not handed the old answer
            -- as a duplicate.
            if self._applied[id] ~= nil then
                self._applied[id] = nil
                self._answer_count = self._answer_count - 1
            end
        else
            break
        end
    end
end

function Commands:_remember(operation_id, outcome, request, now)
    if self._applied[operation_id] == nil then
        push(self._answers, operation_id)
        self._answer_count = self._answer_count + 1
    end
    self._applied[operation_id] = outcome
    local answers = self._answers
    for _ = answers.head, answers.tail do
        if self._answer_count <= ANSWERS_KEPT then break end
        local id = oldest(answers)
        pop(answers)
        if id ~= nil and self._applied[id] ~= nil then
            self._applied[id] = nil
            self._answer_count = self._answer_count - 1
        end
    end

    if self._completed[operation_id] == nil then
        push(self._receipts, operation_id)
        self._receipt_count = self._receipt_count + 1
    end
    self._completed[operation_id] = request
    self._completed_at[operation_id] = now
    self:_trim(now)
end

--- How many answers are cached right now.
function Commands:answers_kept() return self._answer_count end

--- Keep successful request receipts with the same snapshot as their effects.
--- Responses stay in memory; a restored receipt refuses execution after restart.
function Commands:serialize()
    self:_trim(self._clock())
    local completed, completed_at = {}, {}
    for id, request in pairs(self._completed) do
        completed[id] = request
        completed_at[id] = self._completed_at[id]
    end
    return { completed = completed, completed_at = completed_at, sequence = self._sequence }
end

--- Discard a cached response without making its completed effect executable again.
function Commands:forget(operation_id)
    local had = self._applied[operation_id] ~= nil
    if had then
        self._applied[operation_id] = nil
        self._answer_count = self._answer_count - 1
    end
    return had
end

function Commands:restore(record)
    if type(record) ~= "table" or type(record.completed) ~= "table" then
        return false, "command receipts must contain a completed map"
    end
    local sequence = record.sequence or 0
    if math.type(sequence) ~= "integer" or sequence < 0 then
        return false, "invalid command sequence"
    end
    local ages = record.completed_at
    if ages ~= nil and type(ages) ~= "table" then
        return false, "command receipt ages must be a map"
    end
    local now = self._clock()
    local completed, completed_at, order = {}, {}, {}
    for id, request in pairs(record.completed) do
        if type(id) ~= "string" or id == "" or #id > 256 or type(request) ~= "string" or request == "" then
            return false, "invalid command receipt"
        end
        -- A save from before receipts had ages is read as receipts made now:
        -- kept for a day from here, never let go early.
        local at = ages and ages[id]
        if at == nil then at = now end
        if math.type(at) ~= "integer" or at < 0 then
            return false, "invalid command receipt age"
        end
        completed[id], completed_at[id] = request, at
        order[#order + 1] = id
    end
    table.sort(order, function(a, b)
        if completed_at[a] ~= completed_at[b] then return completed_at[a] < completed_at[b] end
        return a < b
    end)
    self._completed, self._completed_at = completed, completed_at
    self._receipts, self._receipt_count = queue(), #order
    for _, id in ipairs(order) do push(self._receipts, id) end
    self._applied, self._answers, self._answer_count = {}, queue(), 0
    self._sequence = sequence
    self:_trim(now)
    return true
end

return Commands
