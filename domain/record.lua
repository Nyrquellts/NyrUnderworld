--- What the city saw. The product promise, as a data structure.
--
-- Every other system has a current answer: what you own, what you are
-- carrying, what you are worth. This one has the past, and the past does not
-- change. A record is written once and never edited and never deleted. Heat
-- cools, reputation recovers, a warrant is served and closed, and the record
-- of what happened is still there underneath all of it.
--
-- That is the difference between a server where you can wait out a mistake and
-- a server where you have a history. A player who robbed the same shop three
-- times last month should be able to be told so, by name, with dates, by a
-- detective who looked it up.
--
-- Two things are kept separate on purpose:
--
--   What happened. The record. Written whether or not anybody saw it, because
--   physical evidence exists without witnesses.
--
--   Who saw it. The witnesses on the record. A crime nobody saw still leaves a
--   record, and that record is what makes it findable later by someone who
--   investigates rather than someone who was standing there.
--
-- Append-only means the in-memory window is bounded and older records go to an
-- archive hook, the same way the ledger handles its postings. The city does not
-- forget them; the server stops holding all of them in RAM.

local Id = require("domain.id")
local Schema = require("domain.schema")

local Record = {}
Record.__index = Record

-- crime.robbery, trade.sold, police.arrest, social.insulted
local KIND_PATTERN = "^%l[%l%d_]*%.[%l%d_]+$"
local SUBJECT_MAX = 96
local DEFAULT_LIMIT = 4000

function Record.is_kind(value)
    return type(value) == "string" and #value <= 48 and value:match(KIND_PATTERN) ~= nil
end

function Record.is_subject(value)
    return type(value) == "string" and value ~= "" and #value <= SUBJECT_MAX
        and value:match("^[%w_%-%.:]+$") ~= nil
end

local function require_subject(value, what)
    if not Record.is_subject(value) then
        error(("%s must be an id or a namespaced name; got %s"):format(what, tostring(value)), 3)
    end
    return value
end

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deep_copy(item) end
    return out
end

--- opts.clock       function returning integer city milliseconds
--- opts.limit       how many records stay in memory, besides any that are held
--- opts.on_archive  called with the records leaving the window
function Record.new(opts)
    opts = opts or {}
    return setmetatable({
        _entries = {},
        _by_subject = {},      -- subject -> array of entries, oldest first
        _written = {},         -- operation id -> record id
        _limit = opts.limit or DEFAULT_LIMIT,
        _on_archive = opts.on_archive,
        _holds = {},           -- what readers still depend on; see Record:hold
        _front = 1,            -- entries before this one are held
        _held_of = {},         -- subject -> the held entries about them, oldest first
        _archived = 0,
        _sequence = 0,
        _clock = opts.clock or function() return math.floor(os.time()) * 1000 end,
    }, Record)
end

local function index(self, subject, entry)
    local list = self._by_subject[subject]
    if not list then
        list = {}
        self._by_subject[subject] = list
    end
    list[#list + 1] = entry
end

local function unindex(self, subject, entry)
    local list = self._by_subject[subject]
    if not list then return end
    for position, candidate in ipairs(list) do
        if candidate == entry then
            table.remove(list, position)
            break
        end
    end
    if #list == 0 then self._by_subject[subject] = nil end
end

local function copy_entry(entry)
    return {
        id = entry.id, sequence = entry.sequence, at = entry.at,
        subject = entry.subject, kind = entry.kind, weight = entry.weight,
        place = entry.place,
        witnesses = deep_copy(entry.witnesses),
        involved = deep_copy(entry.involved),
        meta = entry.meta and deep_copy(entry.meta) or nil,
    }
end

local function held(self, entry)
    if #self._holds == 0 then return false end
    local copy = copy_entry(entry)
    for _, hold in ipairs(self._holds) do
        if hold.keeps(copy) == true then return true end
    end
    return false
end

local function changes_a_hold(self, kind)
    for _, hold in ipairs(self._holds) do
        if hold.changed_by[kind] then return true end
    end
    return false
end

local function let_go(self, position, removed)
    local line = table.remove(self._entries, position)
    unindex(self, line.subject, line)
    for _, subject in ipairs(line.involved) do unindex(self, subject, line) end
    removed[#removed + 1] = line
    self._archived = self._archived + 1
end

--- Write down that something happened.
---
---   subject    who or what it was about
---   kind       what it was, namespaced: crime.robbery, trade.sold
---   weight     how much it mattered, 0..100; used by whatever reads it
---   place      where, as a named location rather than coordinates
---   witnesses  who saw it. May be empty, and an empty list is meaningful:
---              it is a thing that happened with nobody watching.
---   involved   other subjects this is also about, so it is findable from
---              their side too
---   meta       anything else, as plain data
---
--- Idempotent by operation id, so an event delivered twice is written once.
function Record:write(operation_id, entry)
    if type(operation_id) ~= "string" or operation_id == "" then
        error("every record needs an operation id", 2)
    end
    if type(entry) ~= "table" then error("a record is a table", 2) end

    local existing = self._written[operation_id]
    if existing then return self:get(existing), true end

    require_subject(entry.subject, "subject")
    if not Record.is_kind(entry.kind) then
        error(("a record kind looks like crime.robbery; got %s"):format(tostring(entry.kind)), 2)
    end
    local weight = entry.weight or 0
    if math.type(weight) ~= "integer" or weight < 0 or weight > 100 then
        error(("a record weight is a whole number from 0 to 100; got %s"):format(tostring(weight)), 2)
    end
    if entry.place ~= nil then require_subject(entry.place, "place") end
    if entry.meta ~= nil then
        local ok, why = Schema.check_plain(entry.meta, "meta")
        if not ok then error("record meta " .. why, 2) end
    end

    local witnesses = {}
    for _, witness in ipairs(entry.witnesses or {}) do
        require_subject(witness, "witness")
        witnesses[#witnesses + 1] = witness
    end
    table.sort(witnesses)

    local involved = {}
    for _, subject in ipairs(entry.involved or {}) do
        require_subject(subject, "involved")
        involved[#involved + 1] = subject
    end
    table.sort(involved)

    local now = entry.at or self._clock()
    if math.type(now) ~= "integer" then error("a record happens at a whole millisecond", 2) end

    self._sequence = self._sequence + 1
    local written = {
        id = Id.new("rec", { now = now }),
        sequence = self._sequence,
        at = now,
        subject = entry.subject,
        kind = entry.kind,
        weight = weight,
        place = entry.place,
        witnesses = witnesses,
        involved = involved,
        meta = entry.meta and deep_copy(entry.meta) or nil,
    }

    self._entries[#self._entries + 1] = written
    index(self, written.subject, written)
    for _, subject in ipairs(involved) do
        if subject ~= written.subject then index(self, subject, written) end
    end
    self._written[operation_id] = written.id

    local removed = {}

    -- A line held about somebody is asked again when a line that can change
    -- the answer is written about them, and not on every write: asking every
    -- open warrant of a person again for each line about them cost a fifth of
    -- a second a line once they had a few hundred. A line let go here is older
    -- than everything else in the window, so it goes exactly where it would
    -- have gone had it never been held.
    local waiting = self._held_of[written.subject]
    if waiting and changes_a_hold(self, written.kind) then
        local still = {}
        for _, line in ipairs(waiting) do
            if held(self, line) then
                still[#still + 1] = line
            else
                for position = 1, self._front - 1 do
                    if self._entries[position] == line then
                        let_go(self, position, removed)
                        self._front = self._front - 1
                        break
                    end
                end
            end
        end
        if #still > 0 then
            self._held_of[written.subject] = still
        else
            self._held_of[written.subject] = nil
        end
    end

    -- The oldest lines leave first, except a line something still depends on.
    -- Leaving by age alone let anything that writes lines -- an officer
    -- searching as fast as allowed, or only a busy evening -- push a warrant
    -- out of the window, and a warrant nobody can read does not exist. A held
    -- line is asked once on its way out and then set aside, rather than asked
    -- again on every write for as long as it stays.
    while #self._entries - (self._front - 1) > self._limit and self._front <= #self._entries do
        local candidate = self._entries[self._front]
        if held(self, candidate) then
            local list = self._held_of[candidate.subject]
            if not list then
                list = {}
                self._held_of[candidate.subject] = list
            end
            list[#list + 1] = candidate
            self._front = self._front + 1
        else
            let_go(self, self._front, removed)
        end
    end
    if #removed > 0 and self._on_archive then self._on_archive(removed) end

    return written, false
end

--- Keep lines in memory past the window's limit while something depends on
--- them. `keeps` is handed a copy of a line as it is about to leave and answers
--- true to keep it. `changed_by` lists the kinds of line that can change that
--- answer: when one is written about somebody, the lines held about them are
--- asked again, and any nothing needs any more go. So `keeps` may depend only
--- on what the record holds about the line's own subject. What is held does
--- not count toward the limit.
function Record:hold(keeps, changed_by)
    assert(type(keeps) == "function", "a hold is a function of a line")
    local kinds = {}
    for _, kind in ipairs(changed_by or {}) do
        assert(Record.is_kind(kind), ("a hold is changed by kinds of line; got %s"):format(tostring(kind)))
        kinds[kind] = true
    end
    self._holds[#self._holds + 1] = { keeps = keeps, changed_by = kinds }
    return self
end

function Record:get(id)
    for _, entry in ipairs(self._entries) do
        if entry.id == id then return copy_entry(entry) end
    end
    return nil
end

-- ------------------------------------------------------------------ recall

local function matches(entry, opts)
    if opts.kind and entry.kind ~= opts.kind then return false end
    if opts.prefix and entry.kind:sub(1, #opts.prefix) ~= opts.prefix then return false end
    if opts.place and entry.place ~= opts.place then return false end
    if opts.since and entry.at < opts.since then return false end
    if opts.until_at and entry.at > opts.until_at then return false end
    if opts.min_weight and entry.weight < opts.min_weight then return false end
    if opts.witnessed ~= nil then
        local seen = #entry.witnesses > 0
        if seen ~= opts.witnessed then return false end
    end
    if opts.witness then
        local found = false
        for _, witness in ipairs(entry.witnesses) do
            if witness == opts.witness then found = true break end
        end
        if not found then return false end
    end
    return true
end

--- Everything the city has about somebody, newest first. This is what a
--- detective pulls up, and what a background check reads.
---
---   opts.kind / opts.prefix   narrow to crime.robbery, or to crime.
---   opts.since / opts.until_at
---   opts.min_weight
---   opts.witnessed            true for only what was seen, false for only
---                             what was not
---   opts.witness              only what this person saw
---   opts.involved             false for only what they were the subject of,
---                             true for only what they were drawn into. A
---                             murder is about its victim too, and a victim
---                             did not do it.
---   opts.limit
function Record:about(subject, opts)
    opts = opts or {}
    local list = self._by_subject[subject] or {}
    local out = {}
    for position = #list, 1, -1 do
        local entry = list[position]
        local drawn_in = entry.subject ~= subject
        if (opts.involved == nil or drawn_in == opts.involved) and matches(entry, opts) then
            out[#out + 1] = copy_entry(entry)
            if opts.limit and #out >= opts.limit then break end
        end
    end
    return out
end

--- Everything matching, across every subject, newest first. For a crime map
--- and for an admin looking at a pattern rather than a person.
function Record:search(opts)
    opts = opts or {}
    local out = {}
    for position = #self._entries, 1, -1 do
        local entry = self._entries[position]
        if (not opts.subject or entry.subject == opts.subject) and matches(entry, opts) then
            out[#out + 1] = copy_entry(entry)
            if opts.limit and #out >= opts.limit then break end
        end
    end
    return out
end

--- How many times this has happened to or by somebody. The number a detective
--- quotes back: three robberies at that shop this month, all yours.
function Record:tally(subject, opts)
    return #self:about(subject, opts)
end

--- Every subject the city holds anything about, sorted.
function Record:subjects()
    local out = {}
    for subject in pairs(self._by_subject) do out[#out + 1] = subject end
    table.sort(out)
    return out
end

function Record:count() return #self._entries end
function Record:archived_count() return self._archived end

-- ------------------------------------------------------------------- audit

--- The record is append-only, so the check is that nothing has been edited
--- underneath it: ids unique, order monotonic, indexes agreeing with content.
function Record:verify()
    local problems = {}
    local seen_ids, last_sequence = {}, 0
    for _, entry in ipairs(self._entries) do
        if seen_ids[entry.id] then
            problems[#problems + 1] = ("%s appears twice"):format(entry.id)
        end
        seen_ids[entry.id] = true
        if entry.sequence <= last_sequence then
            problems[#problems + 1] = ("%s is out of order at sequence %d"):format(entry.id, entry.sequence)
        end
        last_sequence = entry.sequence
        local indexed = false
        for _, candidate in ipairs(self._by_subject[entry.subject] or {}) do
            if candidate == entry then indexed = true break end
        end
        if not indexed then
            problems[#problems + 1] = ("%s is not findable from %s"):format(entry.id, entry.subject)
        end
    end
    for subject, list in pairs(self._by_subject) do
        if #list == 0 then
            problems[#problems + 1] = ("%s has an empty index entry"):format(subject)
        end
    end
    -- What is held is the front of the window, and every held line is listed
    -- once under whoever it is about. A line held and not listed is never
    -- asked again, and stays for good.
    local listed = {}
    for _, lines in pairs(self._held_of) do
        for _, line in ipairs(lines) do listed[line] = (listed[line] or 0) + 1 end
    end
    for position = 1, self._front - 1 do
        local line = self._entries[position]
        if not line or listed[line] ~= 1 then
            problems[#problems + 1] = ("the line held at %d is not listed once as held"):format(position)
        end
        if line then listed[line] = nil end
    end
    for line in pairs(listed) do
        problems[#problems + 1] = ("%s is listed as held and is not"):format(line.id)
    end
    table.sort(problems)
    return #problems == 0, problems
end

-- ------------------------------------------------------------ persistence

function Record:serialize()
    local entries = {}
    for index_, entry in ipairs(self._entries) do entries[index_] = copy_entry(entry) end
    local written = {}
    for operation_id, record_id in pairs(self._written) do written[operation_id] = record_id end
    return { entries = entries, written = written, sequence = self._sequence, archived = self._archived }
end

function Record.deserialize(record_table, opts)
    if type(record_table) ~= "table" then return nil, "a record book is a table" end
    local book = Record.new(opts)
    for position, entry in ipairs(record_table.entries or {}) do
        if not Record.is_subject(entry.subject) then
            return nil, ("entry %d has no subject"):format(position)
        end
        if not Record.is_kind(entry.kind) then
            return nil, ("entry %d is a %s, which is not a kind"):format(position, tostring(entry.kind))
        end
        if math.type(entry.at) ~= "integer" then
            return nil, ("entry %d did not happen at a whole millisecond"):format(position)
        end
        local rebuilt = {
            id = entry.id, sequence = entry.sequence or position, at = entry.at,
            subject = entry.subject, kind = entry.kind, weight = entry.weight or 0,
            place = entry.place,
            witnesses = deep_copy(entry.witnesses or {}),
            involved = deep_copy(entry.involved or {}),
            meta = entry.meta and deep_copy(entry.meta) or nil,
        }
        book._entries[position] = rebuilt
        index(book, rebuilt.subject, rebuilt)
        for _, subject in ipairs(rebuilt.involved) do
            if subject ~= rebuilt.subject then index(book, subject, rebuilt) end
        end
    end
    for operation_id, record_id in pairs(record_table.written or {}) do
        book._written[operation_id] = record_id
    end
    book._sequence = record_table.sequence or #book._entries
    book._archived = record_table.archived or 0
    local ok, problems = book:verify()
    if not ok then
        return nil, ("the stored record does not hold together: %s"):format(problems[1])
    end
    return book
end

return Record
