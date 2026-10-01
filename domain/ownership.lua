--- Who owns what, and how it changed hands.
--
-- One asset has one owner. Not zero-or-many, not "usually one": exactly one or
-- none, enforced by the structure rather than by the caller remembering to
-- check. Duplication of an asset is the crime players will try hardest to
-- commit, and every duplication bug in this genre reduces to two writes that
-- each believed they held the thing.
--
-- So a transfer states who it believes the current owner is, and the register
-- refuses if that belief is stale. That single rule kills the race: two
-- transfers of one car, arriving from two clients in the same tick, cannot
-- both succeed, because the second one names an owner who no longer holds it.
--
-- The register keeps the chain of custody as well as the current answer,
-- because "who had this before it was sold to me" is a question police work,
-- insurance, and an admin investigating a dupe all need answered.
--
-- Pure Lua. It stores strings, it does not spawn anything. What an owned asset
-- actually is lives in its own entity.

local Id = require("domain.id")

local Ownership = {}
Ownership.__index = Ownership

--- A party is anything that can hold an asset: an entity by its id, or a
--- named principal for the parts of the world that are not entities, written
--- the same way the ledger writes its accounts.
---
---   chr_0m4k2p8q10003x7f2ka   a character
---   state:impound             the impound lot
---   gang:ballas               a gang treasury
local PRINCIPAL_PATTERN = "^%l[%l%d]*:[%w_%-%.:]+$"

function Ownership.is_party(value)
    if type(value) ~= "string" then return false end
    if Id.is_valid(value) then return true end
    return value:match(PRINCIPAL_PATTERN) ~= nil
end

local function require_party(value, what)
    if not Ownership.is_party(value) then
        error(("%s must be an id or a namespaced principal, got %s"):format(what, tostring(value)), 3)
    end
    return value
end

local function require_operation(operation_id)
    if type(operation_id) ~= "string" or operation_id == "" then
        error("every ownership change needs a non-empty operation id", 3)
    end
    return operation_id
end

local default_clock = function() return math.floor(os.time()) * 1000 end
local APPLIED_LIMIT = 5000            -- the changes whose operation ids are remembered

--- opts.clock          function returning integer milliseconds
--- opts.applied_limit  how many of the latest changes keep their operation ids
function Ownership.new(opts)
    opts = opts or {}
    return setmetatable({
        _owner = {},      -- asset id  -> owner
        _held = {},       -- owner     -> set of asset ids
        _chain = {},      -- asset id  -> array of custody entries
        _applied = {},    -- operation -> the change it made; successes only
        _applied_order = {},    -- those ids, oldest first, from _applied_first to _applied_last
        _applied_first = 1,
        _applied_last = 0,
        _applied_limit = opts.applied_limit or APPLIED_LIMIT,
        _clock = opts.clock or default_clock,
    }, Ownership)
end

-- --------------------------------------------------------------- questions

function Ownership:owner_of(asset)
    return self._owner[asset]
end

function Ownership:is_owned_by(asset, party)
    return self._owner[asset] ~= nil and self._owner[asset] == party
end

--- Everything a party holds, in a stable order so a UI does not reshuffle and
--- a spec can assert on it.
function Ownership:assets_of(party)
    local held = self._held[party]
    if not held then return {} end
    local out = {}
    for asset in pairs(held) do out[#out + 1] = asset end
    table.sort(out)
    return out
end

--- The chain of custody, oldest first.
function Ownership:chain(asset)
    local entries = self._chain[asset]
    if not entries then return {} end
    local out = {}
    for index, entry in ipairs(entries) do
        out[index] = {
            at = entry.at,
            operation_id = entry.operation_id,
            action = entry.action,
            from = entry.from,
            to = entry.to,
            meta = entry.meta,
        }
    end
    return out
end

function Ownership:assets()
    local out = {}
    for asset in pairs(self._owner) do out[#out + 1] = asset end
    table.sort(out)
    return out
end

function Ownership:count()
    local n = 0
    for _ in pairs(self._owner) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------- changing

--- Remember a change that was made, so the same operation id makes it once.
---
--- Only a change that was made. A refusal moved nothing, so its id is still
--- free: refusals were kept, and the same id sent again with other arguments
--- raised "already applied" where it should have been answered, which the
--- command door reports as a server failure. core/commands.lua keeps only
--- successes for the same reason.
---
--- And not for ever. These live in memory and are never written down, so a
--- restart already forgets every one; what stops a client's retry across time
--- is the receipt the command door saves, and the ledger's. What these hold
--- together is one id doing one thing within a run, and the most recent
--- thousands of changes cover that many times over, where keeping them all
--- grew with every change the city ever made.
local function remember(self, operation_id, signature)
    if self._applied[operation_id] == nil then
        self._applied_last = self._applied_last + 1
        self._applied_order[self._applied_last] = operation_id
    end
    self._applied[operation_id] = { signature = signature }
    while self._applied_last - self._applied_first + 1 > self._applied_limit do
        local oldest = self._applied_order[self._applied_first]
        self._applied_order[self._applied_first] = nil
        self._applied_first = self._applied_first + 1
        self._applied[oldest] = nil
    end
end

-- A repeated operation id must be the same operation. Same id with different
-- arguments is either a bug in id generation or a client trying to have one
-- approval move two things, and both deserve to be loud.
local function replay(self, operation_id, signature)
    local previous = self._applied[operation_id]
    if not previous then return nil end
    if previous.signature ~= signature then
        error(("operation %s was already applied to %s; it cannot also mean %s")
            :format(operation_id, previous.signature, signature), 3)
    end
    return previous
end

local function record(self, asset, entry)
    local entries = self._chain[asset]
    if not entries then
        entries = {}
        self._chain[asset] = entries
    end
    entries[#entries + 1] = entry
end

local function set_owner(self, asset, party)
    local current = self._owner[asset]
    if current and self._held[current] then
        self._held[current][asset] = nil
        if next(self._held[current]) == nil then self._held[current] = nil end
    end
    self._owner[asset] = party
    if party then
        local held = self._held[party]
        if not held then
            held = {}
            self._held[party] = held
        end
        held[asset] = true
    end
end

--- First ownership of a thing that has none. Minting an asset into the world.
function Ownership:claim(operation_id, asset, party, meta)
    require_operation(operation_id)
    require_party(asset, "asset")
    require_party(party, "owner")
    local signature = ("claim:%s:%s"):format(asset, party)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    local current = self._owner[asset]
    if current then
        return false, ("%s is already owned by %s"):format(asset, current)
    end
    local now = self._clock()
    set_owner(self, asset, party)
    record(self, asset, { at = now, operation_id = operation_id, action = "claim", from = nil, to = party, meta = meta })
    remember(self, operation_id, signature)
    return true
end

--- Hand an asset from one party to another. `from` is the caller statement of
--- who holds it now; if that is wrong the transfer is refused and nothing
--- moves. This is the compare-and-swap that makes concurrent transfers safe.
function Ownership:transfer(operation_id, asset, from, to, meta)
    require_operation(operation_id)
    require_party(asset, "asset")
    require_party(from, "from")
    require_party(to, "to")
    local signature = ("transfer:%s:%s:%s"):format(asset, from, to)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    local current = self._owner[asset]
    if current == nil then
        return false, ("%s has no owner, so it cannot be transferred"):format(asset)
    end
    if current ~= from then
        return false, ("%s is owned by %s, not %s"):format(asset, current, from)
    end
    if to == from then
        return false, ("%s already belongs to %s"):format(asset, from)
    end

    local now = self._clock()
    set_owner(self, asset, to)
    record(self, asset, { at = now, operation_id = operation_id, action = "transfer", from = from, to = to, meta = meta })
    remember(self, operation_id, signature)
    return true
end

--- Let go of an asset without giving it to anybody: destroyed, despawned,
--- written off. The asset keeps its chain so the write-off is auditable.
function Ownership:release(operation_id, asset, from, meta)
    require_operation(operation_id)
    require_party(asset, "asset")
    require_party(from, "from")
    local signature = ("release:%s:%s"):format(asset, from)
    local previous = replay(self, operation_id, signature)
    if previous then return true, nil, { duplicate = true } end

    local current = self._owner[asset]
    if current ~= from then
        local err = current == nil
            and ("%s has no owner"):format(asset)
            or ("%s is owned by %s, not %s"):format(asset, current, from)
        return false, err
    end
    local now = self._clock()
    set_owner(self, asset, nil)
    record(self, asset, { at = now, operation_id = operation_id, action = "release", from = from, to = nil, meta = meta })
    remember(self, operation_id, signature)
    return true
end

-- ------------------------------------------------------------------- audit

--- Prove the register still means what it claims. An admin command and a spec
--- both want this: the forward map and the reverse index must agree exactly,
--- and no asset may appear under two owners.
function Ownership:verify()
    local problems = {}
    for asset, party in pairs(self._owner) do
        local held = self._held[party]
        if not (held and held[asset]) then
            problems[#problems + 1] = ("%s is owned by %s but missing from the index"):format(asset, party)
        end
    end
    for party, held in pairs(self._held) do
        if next(held) == nil then
            problems[#problems + 1] = ("%s has an empty holdings entry"):format(party)
        end
        for asset in pairs(held) do
            if self._owner[asset] ~= party then
                problems[#problems + 1] =
                    ("%s is indexed under %s but owned by %s"):format(asset, party, tostring(self._owner[asset]))
            end
        end
    end
    table.sort(problems)
    return #problems == 0, problems
end

--- A plain table for persistence. The chain travels with it; losing custody
--- history across a restart would make the city forget, which is the one
--- thing it is not allowed to do.
function Ownership:serialize()
    local owner, chain = {}, {}
    for asset, party in pairs(self._owner) do owner[asset] = party end
    for asset in pairs(self._chain) do chain[asset] = self:chain(asset) end
    return { owner = owner, chain = chain }
end

function Ownership.deserialize(record_table, opts)
    local register = Ownership.new(opts)
    for asset, party in pairs((record_table or {}).owner or {}) do
        require_party(asset, "asset")
        require_party(party, "owner")
        set_owner(register, asset, party)
    end
    for asset, entries in pairs((record_table or {}).chain or {}) do
        register._chain[asset] = {}
        for index, entry in ipairs(entries) do register._chain[asset][index] = entry end
    end
    return register
end

return Ownership
