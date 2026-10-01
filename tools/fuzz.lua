--- A city played by nobody in particular, checked after every step.
--
-- Every defect this project has shipped passed the full suite, because a spec
-- walks the path its author thought of. This walks the paths nobody thought of:
-- four accounts making people, buying, working, robbing, texting, arresting,
-- restarting the server, and waiting days, in an order chosen by a seed. After
-- every step it asks what must never be false:
--
--   the books sum to nothing              money was neither made nor lost
--   world:verify, inventory, record       ownership, stock and the record agree
--   no command answered `failed`          a failure is a bug report
--   no handler, task or event errored     the error channel stays empty
--   a query changed nothing               read_only means it
--   a replayed request changed nothing    one operation id, one effect
--   the answer survives the wire          what a client receives, not the object
--   every screen draws from that answer   the view builders take the real shape
--   a restart keeps every cent and owner  save, read back, save again: the same
--
-- It builds its city with `adapter/city.lua`, the same code the server builds
-- its city with, from the shipped config.lua, and it asks through
-- `Bridge.meta_for` and the client allowlist, so what it drives is what a
-- client can reach.
--
--   lua tools/fuzz.lua --seed 7 --steps 5000
--   lua tools/fuzz.lua --seeds 1-50 --steps 2000
--
-- A finding prints the seed, the step and the last actions before it; the same
-- seed replays the same city.

local City = require("adapter.city")
local Settings = require("support.settings")
local MemoryStore = require("persistence.memory_store")
local Bridge = require("adapter.bridge")
local PlayerCommands = require("adapter.commands")
local Json = require("support.json")
local Money = require("domain.money")
local Characters = require("systems.characters")
local InventorySystem = require("systems.inventory")
local Vehicles = require("systems.vehicles")
local NuiState = require("adapter.nui_state")

local Fuzz = {}

local TRAIL = 40

-- ------------------------------------------------------------------ chance

local function pick(list)
    if #list == 0 then return nil end
    return list[math.random(#list)]
end

local function chance(p) return math.random() < p end

local function weighted(table_of_weights)
    local total = 0
    for _, row in ipairs(table_of_weights) do total = total + row[2] end
    local roll = math.random() * total
    for _, row in ipairs(table_of_weights) do
        roll = roll - row[2]
        if roll <= 0 then return row[1] end
    end
    return table_of_weights[#table_of_weights][1]
end

-- -------------------------------------------------------------------- wire

--- What a client actually receives: no metatables, no functions, no cycles.
--- FiveM's msgpack drops a metatable and keeps the fields, so a Money arrives
--- as a plain table, and a view that called a method on it fails on a client
--- while passing every spec that handed it the object.
local function wire(value, seen)
    local kind = type(value)
    if kind ~= "table" then
        if kind == "function" or kind == "userdata" or kind == "thread" then
            error(("a %s cannot cross the wire"):format(kind))
        end
        return value
    end
    seen = seen or {}
    if seen[value] then error("a cycle cannot cross the wire") end
    seen[value] = true
    local out = {}
    for key, item in pairs(value) do
        local key_kind = type(key)
        if key_kind ~= "string" and math.type(key) ~= "integer" then
            error(("a %s key cannot cross the wire"):format(key_kind))
        end
        out[key] = wire(item, seen)
    end
    seen[value] = nil
    return out
end

-- ----------------------------------------------------------------- digests

local function all(repository)
    return repository:where(function() return true end)
end

--- Everything a save would write, as one string. Two equal digests are two
--- equal cities as far as a restart can tell.
local function digest(world)
    local parts = {}
    for _, repository in ipairs(world:repositories()) do
        for _, entity in ipairs(all(repository)) do
            parts[#parts + 1] = repository.kind .. ":" .. entity.id .. "=" .. Json.encode(entity:serialize())
        end
    end
    parts[#parts + 1] = "ledger=" .. Json.encode(world.ledger:serialize())
    parts[#parts + 1] = "ownership=" .. Json.encode(world.ownership:serialize())
    for _, name in ipairs(world._persist_order) do
        local ok, record = pcall(world._persisted[name].save)
        parts[#parts + 1] = name .. "=" .. (ok and Json.encode(record) or ("<" .. tostring(record) .. ">"))
    end
    table.sort(parts)
    return table.concat(parts, "\n")
end

--- Where two decoded records first disagree, as paths.
local function paths_apart(a, b, path, out)
    if #out >= 6 then return end
    if type(a) ~= "table" or type(b) ~= "table" then
        if a ~= b then
            out[#out + 1] = ("%s: %s -> %s"):format(path, Json.encode(a):sub(1, 60), Json.encode(b):sub(1, 60))
        end
        return
    end
    local keys, seen = {}, {}
    for key in pairs(a) do if not seen[key] then seen[key] = true; keys[#keys + 1] = key end end
    for key in pairs(b) do if not seen[key] then seen[key] = true; keys[#keys + 1] = key end end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    for _, key in ipairs(keys) do
        paths_apart(a[key], b[key], path .. "." .. tostring(key), out)
    end
end

--- What two digests disagree on, so a finding says what changed.
local function difference(before, after)
    local left, right = {}, {}
    for line in before:gmatch("[^\n]+") do
        local name, body = line:match("^([^=]+)=(.*)$")
        if name then left[name] = body end
    end
    for line in after:gmatch("[^\n]+") do
        local name, body = line:match("^([^=]+)=(.*)$")
        if name then right[name] = body end
    end
    local out = {}
    local names, seen = {}, {}
    for name in pairs(left) do seen[name] = true; names[#names + 1] = name end
    for name in pairs(right) do if not seen[name] then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        if left[name] ~= right[name] then
            if left[name] == nil then
                out[#out + 1] = "+ " .. name
            elseif right[name] == nil then
                out[#out + 1] = "- " .. name
            else
                local ok_a, a = pcall(Json.decode, left[name])
                local ok_b, b = pcall(Json.decode, right[name])
                if ok_a and ok_b then
                    paths_apart(a, b, name, out)
                else
                    out[#out + 1] = "~ " .. name
                end
            end
        end
        if #out >= 6 then break end
    end
    return table.concat(out, " | ")
end

--- Money and who holds what: the part of a city a restart must never change.
local function holdings(world)
    local parts = {}
    for _, account in ipairs(world.ledger:accounts()) do
        parts[#parts + 1] = account .. "=" .. tostring(world.ledger:balance(account):to_minor())
    end
    parts[#parts + 1] = "ownership=" .. Json.encode(world.ownership:serialize())
    table.sort(parts)
    return table.concat(parts, "\n")
end

-- ------------------------------------------------------------------- views

--- The screens a client draws from each answer, as `adapter/nui.lua` draws them.
local VIEWS = {
    ["character.list"] = NuiState.picker,
    ["me.pockets"] = NuiState.pockets,
    ["phone.inbox"] = NuiState.inbox,
    ["phone.thread"] = NuiState.thread,
    ["shop.list"] = NuiState.shop,
    ["me.nearby"] = NuiState.nearby,
    ["bank.statement"] = NuiState.bank,
    ["work.list"] = NuiState.jobs,
    ["inventory.look"] = function(value) return NuiState.stash(nil, value, {}) end,
}

-- ------------------------------------------------------------------ values

local NAMES = { "Jane", "John", "Ana", "Li", "Mo", "Zoe", "O'Neil", "Anne-Marie", "Van Dyke" }
local JUNK_STRINGS = { "", " ", "x", "nope", "<b>hi</b>", "\0", string.rep("z", 300), "chr_0", "license:aaaa" }
local INTEGERS = { 0, 1, 2, 3, 5, 10, 12, 25, 99, 100, 250, 400, 900, 1000, 1200, 5000, 25000,
    50000, 100000, 250000, 1000000, 100000000, -1, math.maxinteger }

--- Refusals that keep something on purpose, each for a reason worth writing
--- down. Anything not here that leaves a mark is a finding.
local REFUSALS_THAT_REMEMBER = {
    -- Hotwiring is two presses a minute apart. The first starts the clock and
    -- answers "Give it a minute"; the clock is one row per person, replaced
    -- when they move on to another car, so it cannot grow.
    ["vehicle.hotwire:working"] = true,
}

local function in_range(spec, value)
    if spec.min and value < spec.min then return false end
    if spec.max and value > spec.max then return false end
    return true
end

-- ------------------------------------------------------------------ a city

local function new_city(store, settings)
    local world = City.build(settings, { store = store })
    local loaded, problems = world:load()
    if not loaded then return nil, table.concat(problems, "; ") end
    City.seed(world, settings)
    return world
end

--- opts.seed        which city (default 1)
--- opts.steps       how many actions (default 1000)
--- opts.accounts    how many players (default 4)
--- opts.on_finding  called with each finding as it is made
function Fuzz.run(opts)
    opts = opts or {}
    local seed = opts.seed or 1
    local steps = opts.steps or 1000
    math.randomseed(seed)

    local settings, problems = Settings.read(require("config"))
    assert(#problems == 0, "config.lua does not read clean: " .. table.concat(problems, "; "))

    local store = MemoryStore.new()
    local world = assert(new_city(store, settings))

    local report = {
        seed = seed, steps = 0, commands = 0, codes = {}, findings = {}, by_command = {},
        restarts = 0, replays = 0, views = 0, queries = 0,
    }
    local seen_findings = {}
    local trail = {}

    local accounts = {}
    for index = 1, opts.accounts or 4 do accounts[index] = ("license:fuzz%04d"):format(index) end

    local allowed = {}
    for _, name in ipairs(PlayerCommands.ALLOWED) do allowed[#allowed + 1] = name end
    table.sort(allowed)

    -- Where each person is standing, as the server's proximity service would
    -- answer it, and who saw the last thing that happened.
    local near = {}
    local watching = {}
    local tokens = {}        -- account -> tokens it has used
    local plates = 0
    local crews_founded = 0

    local function install_senses(city)
        city.services.proximity = function(actor, target)
            local here = near[actor]
            return here ~= nil and here[target] == true
        end
        city.services.witnesses = function(actor)
            local out = {}
            for _, character in ipairs(watching) do
                if character ~= actor then out[#out + 1] = character end
            end
            return out
        end
    end
    install_senses(world)

    local function note(line)
        trail[#trail + 1] = line
        if #trail > TRAIL then table.remove(trail, 1) end
    end

    local function finding(kind, key, message)
        local id = kind .. "|" .. key
        if seen_findings[id] then
            seen_findings[id].count = seen_findings[id].count + 1
            return
        end
        local copy = {}
        for index, line in ipairs(trail) do copy[index] = line end
        local entry = { kind = kind, key = key, message = message, seed = seed,
            step = report.steps, trail = copy, count = 1 }
        seen_findings[id] = entry
        report.findings[#report.findings + 1] = entry
        if opts.on_finding then opts.on_finding(entry) end
    end

    -- ----------------------------------------------------------- the pools

    local function pools()
        local s = world.services
        local p = { chr = {}, prp = {}, shp = {}, fnc = {}, trf = {}, gng = {}, veh = {}, emp = {},
            numbers = {}, phones = {}, containers = {}, jobs = {}, items = {}, active = {},
            banks = {}, homes = {} }
        for _, person in ipairs(all(world:repository(Characters.Character))) do
            p.chr[#p.chr + 1] = person.id
            p.containers[#p.containers + 1] = InventorySystem.pockets(person.id)
            local number = s.phone.number_of(person.id)
            if number then p.phones[#p.phones + 1] = number end
        end
        for _, place in ipairs(all(s.property.places)) do
            p.prp[#p.prp + 1] = place.id
            p.containers[#p.containers + 1] = s.property.stash(place.id)
            if place:get("kind") == "bank" then
                p.banks[#p.banks + 1] = place.id
            elseif place:get("kind") ~= "shop" then
                p.homes[#p.homes + 1] = place.id
            end
        end
        for _, shop in ipairs(all(s.shops.shops)) do p.shp[#p.shp + 1] = shop.id end
        for _, fence in ipairs(all(s.fencing.fences)) do p.fnc[#p.fnc + 1] = fence.id end
        for _, turf in ipairs(all(s.gangs.turfs)) do p.trf[#p.trf + 1] = turf.id end
        for _, crew in ipairs(all(s.gangs.crews)) do p.gng[#p.gng + 1] = crew.id end
        for _, car in ipairs(all(s.vehicles.cars)) do
            p.veh[#p.veh + 1] = car.id
            p.containers[#p.containers + 1] = Vehicles.boot(car.id)
        end
        for _, employer in ipairs(all(world:repository(require("systems.work").Employer))) do
            p.emp[#p.emp + 1] = employer.id
        end
        for _, account in ipairs(all(s.banking.accounts)) do
            p.numbers[#p.numbers + 1] = account:get("number")
        end
        for _, employer in ipairs(settings.employers) do
            for _, offer in ipairs(employer.offers) do p.jobs[#p.jobs + 1] = offer end
        end
        for _, item in ipairs(settings.items) do p.items[#p.items + 1] = item.id end
        for _, account in ipairs(accounts) do
            local character = s.sessions:character_of(account)
            if character then p.active[#p.active + 1] = character end
        end
        table.sort(p.numbers)
        table.sort(p.phones)
        return p
    end

    local function value_for(field, spec, p, name)
        local kind = spec.type
        if kind == "id" then
            local pool = p[spec.kind] or {}
            -- The id a player would actually be handed for this field, most of
            -- the time; any id of the right kind, or none, the rest.
            if field == "branch" and chance(0.85) then
                pool = p.banks
            elseif field == "place" and chance(0.7) then
                pool = p.homes
            elseif (field == "target" or field == "suspect" or field == "holder") and chance(0.7) then
                pool = p.active
            end
            if #pool > 0 and chance(0.93) then return pick(pool) end
            return pick({ "chr_000000000000000000a", "prp_0", "nope", 5 })
        elseif kind == "integer" then
            if chance(0.85) then
                for _ = 1, 8 do
                    local value = pick(INTEGERS)
                    if in_range(spec, value) then return value end
                end
                return spec.min or 1
            end
            return pick(INTEGERS)
        elseif kind == "boolean" then
            return chance(0.5)
        elseif kind == "string" then
            if field == "first_name" or field == "last_name" then return pick(NAMES) end
            if field == "item" then return chance(0.9) and pick(p.items) or pick(JUNK_STRINGS) end
            if field == "job" then return chance(0.9) and pick(p.jobs) or pick(JUNK_STRINGS) end
            if field == "from" or field == "to" and name == "inventory.move" or field == "container" then
                return chance(0.9) and pick(p.containers) or pick(JUNK_STRINGS)
            end
            if name == "bank.transfer" and field == "to" then
                return chance(0.9) and pick(p.numbers) or pick(JUNK_STRINGS)
            end
            if field == "to" or field == "with" or field == "number" then
                return chance(0.9) and pick(p.phones) or pick(JUNK_STRINGS)
            end
            if spec.enum then return pick(spec.enum) end
            local text = pick({ "rent", "for the car", "hello there", "meet at the docks", "ok" })
            return chance(0.95) and text or pick(JUNK_STRINGS)
        end
        return nil
    end

    local function args_for(name, p)
        local declared = world.commands._defined[name].args
        local fields = {}
        for field in pairs(declared) do fields[#fields + 1] = field end
        table.sort(fields)
        local args = {}
        for _, field in ipairs(fields) do
            local spec = declared[field]
            if spec.required or chance(0.6) then
                args[field] = value_for(field, spec, p, name)
            end
        end
        return args
    end

    --- Stand the actor where the command is aimed, most of the time.
    local function walk_to(actor, args)
        if not actor then return end
        local here = {}
        for _, target in pairs(args) do
            if type(target) == "string" then
                here[target] = true
                local kind = target:sub(1, 3)
                if kind == "shp" then
                    local shop = world.services.shops.shops:load(target)
                    if shop then here[shop:get("place")] = true end
                elseif kind == "fnc" then
                    local fence = world.services.fencing.fences:load(target)
                    if fence then here[fence:get("place")] = true end
                end
            end
        end
        near[actor] = here
    end

    -- ----------------------------------------------------------- the checks

    local function check_city(label)
        local total = world.ledger:total()
        if not total:is_zero() then
            finding("books", label, ("the books are off by %s after %s"):format(tostring(total), label))
        end
        local ok, found = world:verify()
        if not ok then finding("verify", label .. ":" .. tostring(found[1]), table.concat(found, "; ")) end
        local stock, stock_problems = world.services.inventory:verify()
        if not stock then
            finding("inventory", label .. ":" .. tostring(stock_problems[1]), table.concat(stock_problems, "; "))
        end
        local book, book_problems = world.services.record:verify()
        if not book then
            finding("record", label .. ":" .. tostring(book_problems[1]), table.concat(book_problems, "; "))
        end
    end

    local errors_seen = #world:errors()
    local function check_errors(label)
        local errors = world:errors()
        for index = errors_seen + 1, #errors do
            local entry = errors[index]
            local shape = tostring(entry.message):gsub("chr_%w+", "chr_*"):gsub("%d+", "N")
            finding("error", tostring(entry.source) .. ":" .. shape:sub(1, 120),
                ("%s [%s] %s"):format(label, tostring(entry.source), tostring(entry.message)))
        end
        errors_seen = #errors
    end

    local function check_answer(name, outcome)
        local ok, crossed = pcall(function() return wire(outcome:summary()) end)
        if not ok then
            finding("wire", name, ("%s answered something a client cannot receive: %s"):format(name, tostring(crossed)))
            return
        end
        local encoded, why = pcall(Json.encode, crossed)
        if not encoded then
            finding("json", name, ("%s answered something JSON refuses: %s"):format(name, tostring(why)))
        end
        local view = VIEWS[name]
        if view and crossed.ok and crossed.value ~= nil then
            report.views = report.views + 1
            local drew, err = pcall(view, crossed.value)
            if not drew then
                finding("view", name, ("the screen for %s could not draw its own answer: %s"):format(name, tostring(err)))
            end
        end
    end

    -- ---------------------------------------------------------- the actions

    local grants = 0

    --- After a refusal, sometimes do what a player (or the console) would do to
    --- get past it. Without this most commands never answer anything but their
    --- first refusal, and a run of thousands of steps tests a dozen lines.
    local function assist(account, actor, code, p)
        if not actor then return end
        local s = world.services
        local meta = { account = account, actor = actor, source = "fuzz-assist" }
        note(("assist %s for %s"):format(code, actor))
        local ok, err = pcall(function()
            if code == "not_staff" then
                s.admin.grant(actor, 3)
            elseif code == "not_an_officer" or code == "not_on_duty" then
                s.police.commission(actor, true)
                world:dispatch("police.duty", { on = true }, meta)
            elseif code == "no_crew" then
                if not s.gangs.crew_of(actor) and crews_founded < 8 then
                    crews_founded = crews_founded + 1
                    s.gangs.found(("Crew %d"):format(crews_founded), ("C%d"):format(crews_founded), actor)
                end
            elseif code == "no_account" then
                local branch = pick(p.banks)
                if branch then
                    near[actor] = { [branch] = true }
                    world:dispatch("bank.open", { branch = branch }, meta)
                end
            elseif code == "cannot_afford" or code == "short" or code == "insufficient_funds" then
                grants = grants + 1
                world.ledger:transfer(("fuzz-grant:%d:%d"):format(seed, grants), "external:mint",
                    Characters.wallet(actor), Money.of(pick({ 50, 500, 5000 })))
            elseif code == "no_key" or code == "not_yours_to_chop" then
                plates = plates + 1
                s.vehicles.register(actor, { model = "sultan", plate = ("FA%04d"):format(plates % 10000) })
            elseif code == "not_carrying" or code == "no_tools" or code == "no_kit"
                or code == "not_wanted" then
                s.admin.grant(actor, 3)
                world:dispatch("admin.item", { character = actor, item = pick(p.items),
                    count = pick({ 1, 2, 5 }), reason = "fuzz stock" }, meta)
            elseif code == "not_working" then
                world:dispatch("work.start", { employer = pick(p.emp), job = pick(p.jobs) }, meta)
            elseif code == "no_phone" then
                world:dispatch("phone.number", {}, meta)
            end
        end)
        if not ok then
            finding("assist", code .. ":" .. tostring(err):gsub("chr_%w+", "chr_*"):sub(1, 100),
                ("helping past %s threw: %s"):format(code, tostring(err)))
        end
    end

    local function do_command(p)
        local account = pick(accounts)
        local actor = world.services.sessions:character_of(account)
        local name

        -- Somebody who is nobody yet mostly makes or picks somebody.
        if not actor and chance(0.7) then
            name = chance(0.5) and "character.create" or "character.select"
            if name == "character.select" then
                local mine = {}
                for _, person in ipairs(all(world:repository(Characters.Character))) do
                    if person:get("account") == account then mine[#mine + 1] = person.id end
                end
                if #mine == 0 then name = "character.create" end
            end
        else
            name = pick(allowed)
        end

        local args = args_for(name, p)
        if name == "character.select" and chance(0.8) then
            local mine = {}
            for _, person in ipairs(all(world:repository(Characters.Character))) do
                if person:get("account") == account then mine[#mine + 1] = person.id end
            end
            if #mine > 0 then args.character = pick(mine) end
        end
        -- A buyer sends the price the door showed them, almost always; a random
        -- one is a price that changed, which the sale refuses, and a fuzzer
        -- that mostly sends those never gets a sale through to test.
        if name == "property.buy" and args.place and chance(0.85) then
            local place = world.services.property.places:load(args.place)
            if place then args.price = place:get("price") end
        end
        if chance(0.02) then args.nonsense = 1 end
        if actor and chance(0.7) then walk_to(actor, args) end

        local token
        local used = tokens[account]
        if not used then used = {}; tokens[account] = used end
        local roll = math.random()
        if roll < 0.3 then
            token = ("t%d"):format(math.random(1, 1e9))
            used[#used + 1] = token
        elseif roll < 0.38 and #used > 0 then
            token = pick(used)
        end

        local read_only = world.commands._defined[name].read_only
        local before = digest(world)
        local meta = Bridge.meta_for(account, actor, token, 1)
        note(("%s %s as %s token=%s args=%s"):format(name, read_only and "(query)" or "",
            tostring(actor or account), tostring(token), Json.encode(wire(args))))

        local outcome = world:dispatch(name, args, meta)
        report.commands = report.commands + 1
        report.codes[outcome.code or "?"] = (report.codes[outcome.code or "?"] or 0) + 1
        local row = report.by_command[name] or { total = 0, ok = 0, codes = {} }
        row.total = row.total + 1
        if outcome:succeeded() then row.ok = row.ok + 1 end
        row.codes[tostring(outcome.code)] = (row.codes[tostring(outcome.code)] or 0) + 1
        report.by_command[name] = row
        note("  -> " .. tostring(outcome))

        if outcome:is_failure() then
            local shape = tostring(outcome.message):gsub("chr_%w+", "chr_*"):gsub("[%w]+_%w%w%w%w%w%w%w%w+", "ID")
            finding("failed", name .. ":" .. shape:sub(1, 120), tostring(outcome.message))
        end
        check_answer(name, outcome)

        if read_only then
            report.queries = report.queries + 1
            local after = digest(world)
            if after ~= before then
                finding("query_wrote", name, ("%s is declared read_only and changed the city: %s")
                    :format(name, difference(before, after)))
            end
        elseif outcome:was_refused() then
            -- A refusal is an answer, not an effect. A refused command that
            -- leaves something behind is a way to write to the city without
            -- being allowed to.
            local after = digest(world)
            if after ~= before and not REFUSALS_THAT_REMEMBER[name .. ":" .. tostring(outcome.code)] then
                finding("refusal_wrote", name .. ":" .. tostring(outcome.code),
                    ("%s was refused (%s) and changed the city: %s")
                    :format(name, tostring(outcome.code), difference(before, after)))
            end
        elseif outcome:succeeded() and token and chance(0.5) then
            -- The same request again, as a retry or a double click sends it.
            report.replays = report.replays + 1
            local was = digest(world)
            local again = world:dispatch(name, args, Bridge.meta_for(account, actor, token, 1))
            note("  replay -> " .. tostring(again))
            if not (again.details and again.details.duplicate) and not again:was_refused() then
                finding("replay", name, ("%s ran twice for one operation id: %s"):format(name, tostring(again)))
            end
            local now = digest(world)
            if now ~= was then
                finding("replay_wrote", name, ("replaying %s changed the city: %s")
                    :format(name, difference(was, now)))
            end
        end

        if outcome:was_refused() and chance(0.6) then
            assist(account, actor, outcome.code, p)
        end
    end

    local function do_move(p)
        local person = pick(p.active)
        if not person then return end
        local targets = {}
        for _ = 1, math.random(1, 3) do
            local pool = pick({ p.prp, p.shp, p.fnc, p.trf, p.veh, p.chr })
            local target = pool and pick(pool)
            if target then targets[target] = true end
        end
        near[person] = targets
        note("move " .. person)
    end

    local function do_watch(p)
        watching = {}
        if chance(0.5) then
            for _ = 1, math.random(1, 2) do
                local person = pick(p.active)
                if person then watching[#watching + 1] = person end
            end
        end
    end

    local function do_console(p)
        local person = pick(p.chr)
        if not person then return end
        local s = world.services
        local what = weighted({ { "staff", 3 }, { "commission", 3 }, { "car", 4 }, { "crew", 1 }, { "hurt", 4 } })
        note(("console %s %s"):format(what, person))
        local ok, err = pcall(function()
            if what == "staff" then
                s.admin.grant(person, pick({ 1, 2, 3, 0 }))
            elseif what == "commission" then
                s.police.commission(person, chance(0.8))
            elseif what == "car" then
                plates = plates + 1
                s.vehicles.register(person, { model = "sultan", plate = ("FZ%04d"):format(plates % 10000) })
            elseif what == "crew" then
                if not s.gangs.crew_of(person) and crews_founded < 6 then
                    crews_founded = crews_founded + 1
                    s.gangs.found(("Crew %d"):format(crews_founded), ("C%d"):format(crews_founded), person)
                end
            elseif what == "hurt" then
                s.health.harm(("fuzz-hurt:%d:%d"):format(seed, report.steps), person,
                    pick({ 5, 20, 60, 100, 250 }), { cause = "injury" })
            end
        end)
        if not ok then
            finding("console", what .. ":" .. tostring(err):gsub("chr_%w+", "chr_*"):sub(1, 100),
                ("console %s threw: %s"):format(what, tostring(err)))
        end
    end

    local function do_drop()
        local account = pick(accounts)
        if world.services.sessions:character_of(account) then
            note("dropped " .. account)
            local outcome = world:dispatch("character.release", {}, { account = account, source = "dropped" })
            if not outcome:succeeded() then
                finding("drop", tostring(outcome.code), ("a player who left could not be released: %s"):format(tostring(outcome)))
            end
        end
    end

    local function do_restart()
        note("restart")
        local money_before = holdings(world)
        local saved, failures = world:save()
        if not saved then
            finding("save", tostring(failures[1]):sub(1, 100), "the city could not be written down: " .. table.concat(failures, "; "))
            return
        end
        local reopened, why = new_city(store, settings)
        if not reopened then
            finding("load", tostring(why):sub(1, 100), "the city could not be read back: " .. tostring(why))
            return
        end
        report.restarts = report.restarts + 1
        if holdings(reopened) ~= money_before then
            finding("restart_money", "holdings", "a restart changed who holds money or things")
        end
        -- A restart repairs what only made sense while running; a second one
        -- has nothing left to repair.
        local once = digest(reopened)
        local saved_again = reopened:save()
        local twice_city = saved_again and new_city(store, settings)
        if not twice_city then
            finding("save", "second", "the city read back could not be written down again")
        elseif digest(twice_city) ~= once then
            finding("restart_drift", "fixpoint", "a second restart changed the city again: "
                .. difference(once, digest(twice_city)))
        end
        world = twice_city or reopened
        install_senses(world)
        near, watching = {}, {}
        errors_seen = #world:errors()
        for _, account in ipairs(accounts) do
            if world.services.sessions:character_of(account) then
                finding("restart_session", "bound", "somebody was still playing after a restart")
            end
        end
    end

    -- ------------------------------------------------------------- the loop

    for step = 1, steps do
        report.steps = step
        local p = pools()
        local action = weighted({
            { "command", 80 }, { "move", 8 }, { "watch", 3 }, { "console", 4 },
            { "drop", 2 }, { "wait", 2 }, { "restart", 1 },
        })
        if action == "command" then
            do_command(p)
        elseif action == "move" then
            do_move(p)
        elseif action == "watch" then
            do_watch(p)
        elseif action == "console" then
            do_console(p)
        elseif action == "drop" then
            do_drop()
        elseif action == "wait" then
            local real_ms = pick({ 60000, 600000, 1440000, 2880000 })
            note(("wait %d real ms"):format(real_ms))
            world:tick(real_ms)
        elseif action == "restart" then
            do_restart()
        end
        -- Time passes between everything, as it does on a server: a second or
        -- so of real time, a minute or so of city time.
        world:tick(math.random(100, 1500))
        check_city(action)
        check_errors(action)
    end

    return report
end

--- The report as lines a person reads.
function Fuzz.describe(report)
    local lines = {}
    lines[#lines + 1] = ("seed %d: %d steps, %d commands, %d queries, %d replays, %d views drawn, %d restarts, %d findings")
        :format(report.seed, report.steps, report.commands, report.queries, report.replays,
            report.views, report.restarts, #report.findings)
    for _, entry in ipairs(report.findings) do
        lines[#lines + 1] = ("  [%s] step %d (x%d): %s"):format(entry.kind, entry.step, entry.count, entry.message)
    end
    return lines
end

--- Which commands the run reached, and how often each got further than a
--- refusal. A command that never once answered ok was never tested past its
--- first check, whatever the step count says.
function Fuzz.coverage(report)
    local names = {}
    for name in pairs(report.by_command) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        return report.by_command[a].ok < report.by_command[b].ok
            or (report.by_command[a].ok == report.by_command[b].ok and a < b)
    end)
    local lines = {}
    for _, name in ipairs(names) do
        local row = report.by_command[name]
        local codes = {}
        for code, count in pairs(row.codes) do codes[#codes + 1] = ("%s %d"):format(code, count) end
        table.sort(codes)
        lines[#lines + 1] = ("  %-20s ok %4d of %4d   %s"):format(name, row.ok, row.total, table.concat(codes, ", "))
    end
    return lines
end

-- ----------------------------------------------------------------- command

local function main(argv)
    local seeds, steps, verbose, coverage = { 1 }, 1000, false, false
    local index = 1
    while index <= #argv do
        local flag = argv[index]
        if flag == "--seed" then
            seeds = { tonumber(argv[index + 1]) }
            index = index + 1
        elseif flag == "--seeds" then
            local from, to = argv[index + 1]:match("^(%d+)%-(%d+)$")
            seeds = {}
            for seed = tonumber(from), tonumber(to) do seeds[#seeds + 1] = seed end
            index = index + 1
        elseif flag == "--steps" then
            steps = tonumber(argv[index + 1])
            index = index + 1
        elseif flag == "--trail" then
            verbose = true
        elseif flag == "--coverage" then
            coverage = true
        end
        index = index + 1
    end
    local found = 0
    for _, seed in ipairs(seeds) do
        local report = Fuzz.run({ seed = seed, steps = steps })
        for _, line in ipairs(Fuzz.describe(report)) do print(line) end
        if coverage then
            for _, line in ipairs(Fuzz.coverage(report)) do print(line) end
        end
        if verbose then
            for _, entry in ipairs(report.findings) do
                print(("--- trail before [%s] at step %d"):format(entry.kind, entry.step))
                for _, line in ipairs(entry.trail) do print("    " .. line) end
            end
        end
        found = found + #report.findings
    end
    return found == 0 and 0 or 1
end

-- Required, the first vararg is this module's name; run, it is the first flag.
if (...) ~= "tools.fuzz" then
    os.exit(main(arg))
end

return Fuzz
