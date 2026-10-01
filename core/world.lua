--- One city, with everything in it wired together.
--
-- A world owns the clock, the books, the register of who owns what, the event
-- bus, the command door, the scheduler and the store. A system asks the world
-- for what it needs and adds its own commands, events and scheduled work. No
-- system reaches around the world for a global, and nothing here knows FiveM
-- exists, so an entire city can be booted, driven for a simulated week and
-- inspected inside a test in a few milliseconds.
--
-- The layering the project is built on:
--
--   interface  ->  commands  ->  simulation  ->  state  ->  events  ->  adapters
--
-- Everything to the left of `state` is in this file or reachable from it.
-- Everything to the right of `events` is somebody else, and is replaceable.

local Clock = require("core.clock")
local Commands = require("core.commands")
local Outcome = require("core.outcome")
local Events = require("core.events")
local Scheduler = require("core.scheduler")
local Entity = require("domain.entity")
local Ledger = require("domain.ledger")
local Ownership = require("domain.ownership")
local Schema = require("domain.schema")
local MemoryStore = require("persistence.memory_store")
local Repository = require("persistence.repository")

local World = {}
World.__index = World

local WORLD_COLLECTION = "world"

local UNREAD = "the city has not been read yet, so nothing was written down: " ..
    "until it has, this is an empty city, and writing it would put that over the real one"

--- opts.store     where state persists; memory if not given
--- opts.clock     a Clock; one is made if not given
--- opts.rate      city milliseconds per real millisecond, when making a clock
--- opts.on_error  called with (message, source) for everything that breaks
--- opts.activate  false to leave entity timestamps on the real clock
--- opts.require_load
---                true for a world that stands for a city already in its store:
---                nothing is written down, dispatched or ticked until `load` has run
function World.new(opts)
    opts = opts or {}
    local world = setmetatable({
        store = opts.store or MemoryStore.new(),
        clock = opts.clock or Clock.new({ rate = opts.rate, start_at = opts.start_at }),
        _repositories = {},
        _systems = {},
        _system_order = {},
        _persisted = {},
        _persist_order = {},
        _errors = {},
        _notices = {},
        _error_limit = opts.error_limit or 256,
        _on_error = opts.on_error,
        _on_notice = opts.on_notice,
        _restore_entity_clock = nil,
        _require_load = opts.require_load == true,
        _loaded = false,
        -- The pace the owner asked for, if they asked. Kept apart from the clock
        -- because loading replaces the clock with the saved one.
        _configured_rate = opts.rate,
    }, World)

    local function report(message, source)
        world._errors[#world._errors + 1] = { at = world.clock:now(), message = tostring(message),
                                              source = tostring(source or "world") }
        while #world._errors > world._error_limit do table.remove(world._errors, 1) end
        if world._on_error then world._on_error(message, source) end
    end
    world._report = report

    -- Something healthy worth saying. Kept out of the error list so that list
    -- stays worth reading.
    local function note(message, source)
        world._notices[#world._notices + 1] = { at = world.clock:now(), message = tostring(message),
                                                source = tostring(source or "world") }
        while #world._notices > world._error_limit do table.remove(world._notices, 1) end
        if world._on_notice then world._on_notice(message, source) end
    end
    world._note = note

    local city_now = function() return world.clock:now() end

    world.events = Events.new({
        clock = city_now,
        on_error = function(message, event, label) report(message, "event:" .. tostring(label)) end,
    })
    world.scheduler = Scheduler.new({
        clock = world.clock,
        on_error = function(message, label) report(message, "task:" .. tostring(label)) end,
        on_notice = function(message, label) note(message, "task:" .. tostring(label)) end,
    })
    world.ledger = Ledger.new({ history_limit = opts.ledger_history_limit })
    world.ownership = Ownership.new({ clock = city_now })

    -- What every command handler is handed. A handler reaches the city through
    -- this and through nothing else.
    world.services = {
        world = world,
        clock = world.clock,
        ledger = world.ledger,
        ownership = world.ownership,
        events = world.events,
        repository = function(entity_type) return world:repository(entity_type) end,
    }

    world.commands = Commands.new({
        events = world.events,
        clock = city_now,
        -- Rate limits count real time. Counted in city time, a "minute" at the
        -- shipped rate of 60 was one real second, and every limit let through
        -- sixty times what it declared. Real time is what the clock has been
        -- driven by, so a paused city still counts minutes and a spec that
        -- ticks the world moves the windows the way a server does.
        rate_clock = function() return world.clock:real_elapsed() end,
        services = world.services,
        on_error = function(message, name) report(message, "command:" .. tostring(name)) end,
    })

    if opts.activate ~= false then world:activate() end
    return world
end

--- Point entity timestamps at city time. One world is active at a time, which
--- is the normal case: a server runs one city.
function World:activate()
    if self._restore_entity_clock then return self end
    self._restore_entity_clock = Entity.set_clock(function() return self.clock:now() end)
    return self
end

function World:deactivate()
    if not self._restore_entity_clock then return self end
    Entity.set_clock(self._restore_entity_clock)
    self._restore_entity_clock = nil
    return self
end

--- Flush what is pending and put the entity clock back. Safe to call twice.
function World:close()
    local ok, failures = self:save()
    self:deactivate()
    return ok, failures
end

function World:is_saving() return self._saving == true end

-- -------------------------------------------------------------- the pieces

--- The one repository for a kind of thing. Asking twice gives the same one,
--- because two repositories over one collection would each hold their own copy
--- of the same entity, which is the duplication bug at a larger scale.
function World:repository(entity_type)
    assert(type(entity_type) == "table" and entity_type.kind, "a repository is asked for by entity type")
    local existing = self._repositories[entity_type.kind]
    if existing then
        assert(existing.type == entity_type,
            ("two different types both call themselves %s"):format(entity_type.kind))
        return existing
    end
    local repository = Repository.new(entity_type, self.store, {
        clock = function() return self.clock:now() end,
    })
    self._repositories[entity_type.kind] = repository
    self._repository_order = self._repository_order or {}
    self._repository_order[#self._repository_order + 1] = entity_type.kind
    return repository
end

function World:repositories()
    local out = {}
    for _, kind in ipairs(self._repository_order or {}) do out[#out + 1] = self._repositories[kind] end
    return out
end

function World:define(name, spec)
    self.commands:define(name, spec)
    return self
end

function World:dispatch(name, args, meta)
    if self._require_load and not self._loaded then
        return Outcome.refused("city_unavailable", "The city has not been loaded yet.")
    end
    if self._load_failure then
        return Outcome.refused("city_unavailable", "The saved city could not be loaded. Ask the server owner to restore it.")
    end
    return self.commands:dispatch(name, args, meta)
end

function World:on(event, handler, opts)
    return self.events:on(event, handler, opts)
end

function World:at(when, work, label) return self.scheduler:at(when, work, label) end
function World:after(delay, work, label) return self.scheduler:after(delay, work, label) end
function World:every(interval, work, label, opts) return self.scheduler:every(interval, work, label, opts) end

--- Daily, at a city hour. What rent, payroll and restocking all want.
function World:daily(hour, minute, work, label)
    local first = self.clock:next_at(hour, minute)
    return self.scheduler:every(Clock.MS_PER_DAY, work, label, { first = first })
end

-- ------------------------------------------------------------- the systems

--- Install a system: a table with a name and an install function. Systems are
--- the unit the project grows in, and one that names a requirement it does not
--- have is refused at boot rather than half-working in play.
function World:install(system)
    assert(type(system) == "table" and type(system.name) == "string" and system.name ~= "",
        "a system needs a name")
    assert(type(system.install) == "function", ("system %s needs an install function"):format(system.name))
    assert(not self._systems[system.name], ("system %s is already installed"):format(system.name))
    for _, needed in ipairs(system.requires or {}) do
        assert(self._systems[needed],
            ("system %s needs %s, which is not installed yet"):format(system.name, needed))
    end
    self._systems[system.name] = system
    self._system_order[#self._system_order + 1] = system.name
    local ok, err = pcall(system.install, self)
    if not ok then
        self._systems[system.name] = nil
        table.remove(self._system_order)
        error(("system %s failed to install: %s"):format(system.name, tostring(err)), 2)
    end
    return self
end

function World:has(name) return self._systems[name] ~= nil end

--- A system with state of its own says how to write it down and how to read it
--- back. The world does not know what an inventory is; it knows that something
--- called "inventory" has a record, and where that record lives.
---
---   hooks.save  function() -> a plain table
---   hooks.load  function(record) -> true, or false and a reason
function World:persist_with(name, hooks)
    assert(type(name) == "string" and name:match("^%l[%l%d_]*$"),
        ("a persisted name is lowercase letters, digits and underscores; got %s"):format(tostring(name)))
    assert(name ~= "clock" and name ~= "ledger" and name ~= "ownership" and name ~= "commands",
        ("%s is the name of something the world already keeps"):format(name))
    assert(not self._persisted[name], ("%s is already persisted"):format(name))
    assert(type(hooks) == "table" and type(hooks.save) == "function" and type(hooks.load) == "function",
        ("%s needs a save and a load"):format(name))
    self._persisted[name] = hooks
    self._persist_order[#self._persist_order + 1] = name
    return self
end

function World:persisted()
    local out = {}
    for _, name in ipairs(self._persist_order) do out[#out + 1] = name end
    return out
end

function World:systems()
    local out = {}
    for _, name in ipairs(self._system_order) do out[#out + 1] = name end
    return out
end

-- ---------------------------------------------------------------- the loop

--- One server tick: move city time, run what fell due. Everything else in the
--- city happens because a command was dispatched or an event was published.
function World:tick(real_ms)
    if self._load_failure or (self._require_load and not self._loaded) then
        return { city_ms = 0, at = self.clock:now(), tasks_ran = 0, failures = {}, notices = {} }
    end
    local before = self.clock:now()
    local ran, failures, notices = self.scheduler:tick(real_ms)
    return {
        city_ms = self.clock:now() - before,
        at = self.clock:now(),
        tasks_ran = ran,
        failures = failures,
        notices = notices or {},
    }
end

-- ------------------------------------------------------------- persistence

--- Write everything down. Returns ok and the list of what would not save.
local function write_world(self)
    local failures, pending = {}, {}
    local function stage(key, record)
        pending[#pending + 1] = { collection = WORLD_COLLECTION, key = key, record = record }
    end
    for _, repository in ipairs(self:repositories()) do
        local ok, writes, problems = repository:prepare_save()
        if not ok then
            for _, problem in ipairs(problems) do
                failures[#failures + 1] = ("%s: %s"):format(repository.kind, problem)
            end
        end
        for _, write in ipairs(writes) do pending[#pending + 1] = write end
    end

    stage("clock", self.clock:serialize())
    stage("ledger", self.ledger:serialize())
    stage("ownership", self.ownership:serialize())
    stage("commands", self.commands:serialize())

    for _, name in ipairs(self._persist_order) do
        local produced, record = pcall(self._persisted[name].save)
        if not produced then
            failures[#failures + 1] = ("%s could not be written down: %s"):format(name, tostring(record))
        elseif type(record) ~= "table" then
            failures[#failures + 1] = ("%s wrote down a %s instead of a record"):format(name, type(record))
        else
            stage(name, record)
        end
    end

    -- Every record is held to what a store can write before any of them is
    -- handed to it. A record a store cannot encode fails at flush, and by then
    -- the collections flushed ahead of it are on disk: a checkpoint that is
    -- half this save and half the last one.
    if #failures == 0 then
        for _, write in ipairs(pending) do
            local plain, why = Schema.check_plain(write.record, ("%s/%s"):format(write.collection, write.key))
            if not plain then failures[#failures + 1] = why end
        end
    end

    if #failures == 0 then
        -- Even write-through stores see no partial serialization. Applying the
        -- prepared records is not a backend transaction or power-loss guarantee.
        for _, write in ipairs(pending) do
            self.store:put(write.collection, write.key, write.record)
        end
        local ok, why = self.store:flush()
        if not ok then
            if type(why) == "table" then
                for _, message in ipairs(why) do failures[#failures + 1] = message end
            else
                failures[#failures + 1] = tostring(why or "store flush failed without a reason")
            end
        end
    end
    for _, message in ipairs(failures) do self._report(message, "save") end
    return #failures == 0, failures
end

--- Read everything back. Returns ok and the list of what could not be read;
--- anything unreadable is reported and left at its default rather than
--- silently replacing the city with an empty one.
local function read_world(self)
    local problems = {}

    local clock_record = self.store:get(WORLD_COLLECTION, "clock")
    if clock_record then
        local clock, why = Clock.deserialize(clock_record)
        if clock then
            -- The time is the save's; the pace is config.lua's. Taken whole, the
            -- saved clock brought its old rate back, and an owner who changed
            -- the pace and restarted had a city still running at the old one.
            if self._configured_rate ~= nil then clock:set_rate(self._configured_rate) end
            self.clock = clock
            self.services.clock = clock
            self.scheduler:set_clock(clock)
            self.scheduler:rebase()
        else
            problems[#problems + 1] = ("clock: %s"):format(tostring(why))
        end
    end

    local ledger_record = self.store:get(WORLD_COLLECTION, "ledger")
    if ledger_record then
        local ledger, why = Ledger.deserialize(ledger_record, {
            history_limit = self.ledger.history_limit, on_archive = self.ledger.on_archive,
        })
        if ledger then
            self.ledger = ledger
            self.services.ledger = ledger
        else
            problems[#problems + 1] = ("ledger: %s"):format(tostring(why))
        end
    end

    local command_record = self.store:get(WORLD_COLLECTION, "commands")
    if command_record then
        local ok, why = self.commands:restore(command_record)
        if not ok then problems[#problems + 1] = ("commands: %s"):format(tostring(why)) end
    end

    local ownership_record = self.store:get(WORLD_COLLECTION, "ownership")
    if ownership_record then
        local ok, register = pcall(Ownership.deserialize, ownership_record,
            { clock = function() return self.clock:now() end })
        if ok then
            self.ownership = register
            self.services.ownership = register
        else
            problems[#problems + 1] = ("ownership: %s"):format(tostring(register))
        end
    end

    for _, name in ipairs(self._persist_order) do
        local record = self.store:get(WORLD_COLLECTION, name)
        if record then
            local ran, ok, why = pcall(self._persisted[name].load, record)
            if not ran then
                problems[#problems + 1] = ("%s: %s"):format(name, tostring(ok))
            elseif ok == false then
                problems[#problems + 1] = ("%s: %s"):format(name, tostring(why))
            end
        end
    end

    for _, repository in ipairs(self:repositories()) do
        local entities, broken = repository:all()
        if #entities > 0 and not (clock_record and ledger_record and ownership_record) then
            problems[#problems + 1] = "saved entities exist without a complete world snapshot"
        end
        for _, message in ipairs(broken) do problems[#problems + 1] = message end
    end

    if (clock_record or ledger_record or ownership_record or command_record)
        and not (clock_record and ledger_record and ownership_record) then
        problems[#problems + 1] = "the saved world snapshot is incomplete"
    end

    for _, message in ipairs(problems) do self._report(message, "load") end

    -- Systems listen for this to repair anything that only makes sense while
    -- the server is running: a character who was active when it stopped is not
    -- active now, a job that was in progress is not in progress.
    if #problems == 0 then
        self.events:emit("world.loaded", { at = self.clock:now(), problems = 0 })
    end

    return #problems == 0, problems
end

function World:save()
    if self._load_failure then return false, self._load_failure end
    -- Before the store is touched at all. A database store reads a collection
    -- on first touch and then keeps what it is handed, so a world that was
    -- never read, saved, loads the real rows and writes its own empty clock,
    -- books and register over them. Measured: a server that printed "did not
    -- start" emptied the ledger and the ownership register one save tick later.
    if self._require_load and not self._loaded then return false, { UNREAD } end
    if self._saving then return false, { "a city save is already in progress" } end
    self._saving = true
    local ran, ok, failures = pcall(write_world, self)
    self._saving = false
    if not ran then
        local message = "city save failed: " .. tostring(ok)
        self._report(message, "save")
        return false, { message }
    end
    return ok, failures
end

function World:load()
    if self._load_failure then return false, self._load_failure end
    local ran, ok, problems = pcall(read_world, self)
    if not ran then
        problems = { "city load failed: " .. tostring(ok) }
        self._report(problems[1], "load")
        ok = false
    end
    if not ok then
        -- A partly decoded city must never run or overwrite the source save.
        -- Repair the files and construct a fresh world before reopening it.
        self._load_failure = problems
    else
        self._loaded = true
    end
    return ok, problems
end

-- ------------------------------------------------------------------ health

--- Everything that has gone wrong, newest last. The first thing an admin reads.
function World:errors(limit)
    local out = {}
    local from = limit and math.max(1, #self._errors - limit + 1) or 1
    for index = from, #self._errors do out[#out + 1] = self._errors[index] end
    return out
end

--- Things that happened and are fine. Separate from errors so that list stays
--- worth reading.
function World:notices(limit)
    local out = {}
    local from = limit and math.max(1, #self._notices - limit + 1) or 1
    for index = from, #self._notices do out[#out + 1] = self._notices[index] end
    return out
end

function World:audit(limit) return self.commands:audit(limit) end

--- A consistency check an admin command can run on a live server. None of
--- these should ever be false, which is exactly why they are worth asking.
function World:verify()
    local problems = {}
    if not self.ledger:total():is_zero() then
        problems[#problems + 1] = ("the books are off by %s"):format(tostring(self.ledger:total()))
    end
    local ok, ownership_problems = self.ownership:verify()
    if not ok then
        for _, problem in ipairs(ownership_problems) do problems[#problems + 1] = problem end
    end
    for _, repository in ipairs(self:repositories()) do
        for _, entity in ipairs(repository:where(function() return true end)) do
            local valid, why = entity:validate()
            if not valid then
                problems[#problems + 1] = ("%s: %s"):format(entity.id, tostring(why))
            end
        end
    end
    return #problems == 0, problems
end

--- A one-line state of the city, for a console command and for a test that
--- wants to assert the shape of things rather than every number.
function World:summary()
    local counts = {}
    for _, repository in ipairs(self:repositories()) do
        counts[repository.kind] = repository:count()
    end
    return {
        at = self.clock:describe(),
        systems = self:systems(),
        entities = counts,
        accounts = #self.ledger:accounts(),
        owned = self.ownership:count(),
        pending_tasks = self.scheduler:count(),
        errors = #self._errors,
    }
end

World.WORLD_COLLECTION = WORLD_COLLECTION

return World
