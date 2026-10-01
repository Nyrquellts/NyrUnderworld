--- Booting the city on a server.
--
-- Everything above this file is the simulation and knows nothing about FiveM.
-- Everything in this file is FiveM and knows nothing about the rules. That is
-- the seam the whole project is built around: the day this runs on a different
-- framework, or a different game, only this file changes.

local Clock = require("core.clock")
local Id = require("domain.id")
local Characters = require("systems.characters")
local Admin = require("systems.admin")
local City = require("adapter.city")
local Console = require("adapter.console")
local PlayerCommands = require("adapter.commands")
local Addons = require("adapter.addons")

-- What an addon is told when it asks what it is talking to. Read from the
-- manifest rather than written twice.
local RESOURCE_VERSION = GetResourceMetadata
    and GetResourceMetadata(GetCurrentResourceName(), "version", 0) or "unknown"
local ResourceStore = require("adapter.resource_store")
local DatabaseStore = require("persistence.database_store")
local SqlDriver = require("adapter.sql_driver")
local Settings = require("support.settings")
local Bridge = require("adapter.bridge")
local DevBridge = require("adapter.devbridge")
local Drain = require("adapter.drain")
local StorageGuard = require("adapter.storage_guard")

local RESOURCE = GetCurrentResourceName()
local storage_guard = StorageGuard.new(function()
    return { path = GetResourcePath(RESOURCE), configuration = LoadResourceFile(RESOURCE, "config.lua"),
        store = GetConvar("nyr_store", "file"), driver = GetConvar("nyr_store_driver", "auto"),
        table = GetConvar("nyr_store_table", DatabaseStore.DEFAULT_TABLE) }
end)
local database_resource
AddEventHandler("onResourceStop", function(name)
    if database_resource and name == database_resource then storage_guard:invalidate() end
end)

local function say(message)
    print(("[nyr] %s"):format(message))
    -- Kept where it can be read over HTTP as well as printed, so finding out
    -- what the server said does not mean tailing a console.
    DevBridge.remember(message)
end

-- ------------------------------------------------------------------ config
--
-- The city an owner typed. Everything they are meant to change is in
-- config.lua, everything that is a rule is not, and the whole file is checked
-- before any of it is built -- so four mistakes cost one restart rather than
-- four, and a half-configured city never starts at all.

local function read_config()
    local loaded, raw = pcall(require, "config")
    if not loaded then
        return nil, { "config.lua could not be read: " .. tostring(raw) }
    end
    local settings, problems = Settings.read(raw)
    if #problems > 0 then return nil, problems end
    return settings
end

local settings, config_problems = read_config()
if not settings then
    say("-------------------------------------------------------------")
    say("NYR UNDERWORLD did not start: config.lua has " ..
        (#config_problems == 1 and "a problem" or (#config_problems .. " problems")))
    say("")
    for _, problem in ipairs(config_problems) do say("  " .. problem) end
    say("")
    say("  Nothing was built. Fix these and restart the resource.")
    say("-------------------------------------------------------------")
    return
end

-- Real milliseconds between ticks. A second is plenty: nothing in the
-- simulation is frame-accurate, and everything that is belongs on the client.
local TICK_MS = settings.city.tick_ms
-- How often the city is written down. A minute of lost play is survivable; an
-- hour is not, and writing every change would spend the frame budget on disk.
local SAVE_MS = settings.city.save_ms

-- ------------------------------------------------------------------- world

--- Where the city is kept.
--
-- `nyr_store file` is the default and needs nothing installed: JSON under this
-- resource, which is right for a dev box and fine for a small server.
--
-- `nyr_store database` puts it in the MySQL this server already runs. Nothing
-- ships to talk to that -- it borrows oxmysql or mysql-async, whichever is up.
--
-- If the database is asked for and cannot be reached, this does NOT quietly
-- fall back to files. Two half-written copies of a city is worse than one that
-- refuses to start, and an owner who thinks their database is live while their
-- players' work goes to disk finds out a week later.
--
-- Building the store and using it are two steps, and they are apart on purpose.
-- A database driver's blocking call yields the calling coroutine, and a
-- resource's main chunk is not one -- so construction happens here and every
-- statement happens on the thread below.
local function build_store()
    local want = (GetConvar("nyr_store", "file")):lower()
    if want ~= "database" and want ~= "db" and want ~= "mysql" then
        local files = ResourceStore.new({
            folder = "data",
            guard = function() return storage_guard:check() end,
            on_notice = function(message) say("store: " .. message) end,
        })
        -- Asked here, before anything is built on it, rather than found out at
        -- the first save a minute after people are let in. On the Enhanced
        -- server a folder name with a capital letter in it was a city that
        -- opened and kept nothing; see ResourceStore:writable.
        local writes, why, remedy = files:writable()
        if not writes then return nil, nil, why, nil, remedy end
        return files, "files under " .. RESOURCE .. "/data"
    end

    local driver, why = SqlDriver.find(GetConvar("nyr_store_driver", "auto"))
    if not driver then
        return nil, nil, ("nyr_store is database, but %s"):format(why)
    end

    database_resource = why -- the actual selected driver, including auto selection
    driver = storage_guard:driver(driver)

    local database = DatabaseStore.new({
        driver = driver,
        table = GetConvar("nyr_store_table", DatabaseStore.DEFAULT_TABLE),
        on_notice = function(message) say("store: " .. message) end,
    })
    return database, ("the `%s` table"):format(database:table_name()), nil, driver
end

--- Everything that reaches the database. Runs on a thread. Returns ok, why.
local function open_store(database, driver)
    if not driver then return true end   -- the file store is already open

    local reachable, refused = SqlDriver.check(driver)
    if not reachable then return false, ("the database refused: %s"):format(refused) end

    local made, trouble = database:ensure_schema()
    if not made then return false, trouble end

    -- Read back what is already there, so a database that answers but cannot be
    -- read is found now rather than at the first character select. The list
    -- comes from the database itself; a list kept here would drift the first
    -- time a system stored something new. `world` is named as well because a
    -- fresh install has nothing yet, and reading it is what proves this user
    -- can SELECT from the table and not only create it.
    database:declare("world")
    for _, collection in ipairs(database:collections()) do database:declare(collection) end
    local read, failures = database:preload()
    if not read then
        return false, ("the city could not be read: %s"):format(table.concat(failures, "; "))
    end
    return true
end

-- What an owner can change about where the city is kept, which is the answer
-- to most refusals and not to one a convar cannot fix.
local STORE_CONVARS = {
    "set nyr_store file            keep the city in JSON, no database needed",
    "set nyr_store database        keep it in MySQL (needs oxmysql or mysql-async)",
    "set nyr_store_driver oxmysql  name one, instead of taking whichever is up",
    "set nyr_store_table nyr_store name the table",
}

local function refuse_to_start(trouble, remedy)
    -- Loud, once, in the words an owner can act on. The resource stays up so
    -- the message is readable in the console rather than scrolling past a
    -- restart loop, and the city stays shut until the cause is fixed.
    say("-------------------------------------------------------------")
    say("NYR UNDERWORLD did not start: " .. tostring(trouble))
    say("")
    for _, line in ipairs(remedy or STORE_CONVARS) do say("  " .. line) end
    say("-------------------------------------------------------------")
end

local store, where, build_trouble, sql, remedy = build_store()
if not store then
    refuse_to_start(build_trouble, remedy)
    return
end

-- The city is shut until it has been read. Everything a player can ask for
-- goes through the bridge, and the bridge refuses while this is false.
local city_open = false
local storage_noticed = false
local function is_open()
    if not storage_guard:check() then
        city_open = false
        if not storage_noticed then
            storage_noticed = true
            say("storage identity changed or unavailable; city closed, pending durability UNKNOWN")
        end
    end
    return city_open
end
local transport_epoch = ("%x-%x-%x"):format(os.time(), GetGameTimer(), math.random(0, 0x7fffffff))

-- Which systems a city runs, in what order, is decided in `adapter/city.lua`,
-- where the spec suite and the fuzzer build the same world this one is.
local world, items = City.build(settings, {
    store = store,
    on_error = function(message, source) say(("error (%s): %s"):format(tostring(source), tostring(message))) end,
    on_notice = function(message, source) say(("note (%s): %s"):format(tostring(source), tostring(message))) end,
})

local drain = Drain.new({ now = GetGameTimer, busy = function() return world:is_saving() end,
    close_input = function() city_open = false end,
    finish = function()
        local valid, why = storage_guard:check()
        if not valid then return false, { why } end
        return world:close()
    end, spawn = CreateThread })
local function begin_drain()
    if not is_open() then return drain:report() end
    if drain:begin() then
        CreateThread(function()
            repeat
                drain:poll()
                if drain.status ~= "WAITING" and drain.status ~= "SAVING" then break end
                Wait(25)
            until false
            say("restart drain: " .. drain.status .. (drain.error and ("; " .. tostring(drain.error)) or ""))
        end)
    end
    return drain:report()
end
exports("drain", begin_drain)
exports("drainStatus", function() return drain:report() end)

-- --------------------------------------------------------------- proximity
--
-- Whether somebody is actually standing where they say they are. This is the
-- one question the simulation cannot answer on its own and must not guess at,
-- so it asks, and refuses if nothing answers. The answer comes from the
-- server's own copy of where the ped is, never from the client.

local function coords_of(character_id)
    local sessions = world.services.sessions
    local account = sessions and sessions:account_of(character_id)
    if not account then return nil end
    for _, player in ipairs(GetPlayers()) do
        if Bridge.account_of(player) == account then
            local ped = GetPlayerPed(player)
            if ped and ped ~= 0 then return GetEntityCoords(ped) end
            return nil
        end
    end
    return nil
end

-- A target is anything with a position: an address or a car. The simulation
-- passes an id and gets a yes or a no; it never learns what a coordinate is.
local function position_of(target_id)
    local kind = Id.kind_of(target_id)
    if kind == "prp" then
        local place = world.services.property.places:load(target_id)
        if place then
            return place:get("x"), place:get("y"), place:get("z"), place:get("radius")
        end
    elseif kind == "veh" then
        local car = world.services.vehicles.cars:load(target_id)
        if car then return car:get("x"), car:get("y"), car:get("z"), 5.0 end
    elseif kind == "trf" then
        local turf = world.services.gangs.turfs:load(target_id)
        if turf then
            return turf:get("x"), turf:get("y"), turf:get("z"), turf:get("radius")
        end
    elseif kind == "chr" then
        -- A person is where their ped is, which is how an arrest checks that
        -- the officer is actually standing next to them.
        local there = coords_of(target_id)
        if there then return there.x, there.y, there.z, 6.0 end
    end
    return nil
end

world.services.proximity = function(actor, target_id)
    local x, y, z, radius = position_of(target_id)
    if not x then return false end
    local here = coords_of(actor)
    if not here then return false end
    local dx, dy, dz = here.x - x, here.y - y, here.z - z
    return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

--- Who was close enough to see something. Server-side, from the server copy of
--- where everybody is, so the person doing it never gets a say.
local WITNESS_RANGE = settings.city.witness_range

world.services.witnesses = function(actor)
    local here = coords_of(actor)
    if not here then return {} end
    local sessions = world.services.sessions
    local seen = {}
    for _, player in ipairs(GetPlayers()) do
        local account = Bridge.account_of(player)
        local character = account and sessions and sessions:character_of(account)
        if character and character ~= actor then
            local ped = GetPlayerPed(player)
            if ped and ped ~= 0 then
                local there = GetEntityCoords(ped)
                local dx, dy, dz = there.x - here.x, there.y - here.y, there.z - here.z
                if (dx * dx + dy * dy + dz * dz) <= (WITNESS_RANGE * WITNESS_RANGE) then
                    seen[#seen + 1] = character
                end
            end
        end
    end
    return seen
end

-- ----------------------------------------------------------------- loading

local function read_the_city()
    local loaded, problems = world:load()
    if not loaded then
        for _, problem in ipairs(problems) do say("load: " .. problem) end
        say("the city remains closed; restore the save and restart this resource")
        return
    end
    -- What config.lua names and the city does not have yet. Decided in
    -- `adapter/city.lua`; restarting never reverts a city to its seed.
    City.seed(world, settings, say)
    say(City.describe(world))
    city_open = storage_guard:check() == true
    if not city_open then say("storage identity changed during startup; city remains closed") end
end

-- ------------------------------------------------------------------ bridge

-- A LAN server answers questions about itself over HTTP, so building this
-- does not mean reading a console to find out what is on somebody's screen.
-- A public server installs none of it.
--
-- Behind the same gate as the client bridge below. `/do` runs a command the
-- way a player would, so until the city is open it is told what a player is
-- told; installed without it, a journey made a character in a city that had
-- not been read yet and was failed for what it found there.
DevBridge.install(world, Characters, {
    ready = is_open,
    on_log = function(line) say(line) end,
})

Bridge.attach(world, {
    epoch = transport_epoch,
    ready = is_open,
    -- The list itself is in `adapter/commands.lua`, beside the names a player
    -- can type and press, because a spec can load that file and cannot load
    -- either of the two that put commands in a player's reach.
    allow = PlayerCommands.ALLOWED,
    on_log = function(line) say(line) end,
})

-- ------------------------------------------------------------------ addons
--
-- The two surfaces another resource on this server uses. Everything with a
-- decision in it is in `adapter/addons.lua`, which the spec suite loads; what
-- is here is the three natives and the wiring.
--
-- An addon is server-side Lua the owner installed, so it is as trusted as the
-- server and there is no allowlist between it and the city. What there is
-- instead is a line in the log for every call, naming the resource that made
-- it, because "which addon did that" is the question an owner actually has.

exports("version", function()
    return Addons.about(GetCurrentResourceName(), RESOURCE_VERSION)
end)

exports("ask", function(command, args, meta)
    local from = GetInvokingResource and GetInvokingResource() or nil
    -- On a refusal the second return is the reason and there is no third. On a
    -- request it is the arguments. Named for the good case and checked before
    -- either is read, rather than one name that means two things.
    local name, shaped, context = Addons.request(command, args, meta, from)
    if not name then
        local why = shaped
        say(why)
        return { ok = false, code = "bad_request", message = why }
    end
    if not is_open() then
        return { ok = false, code = "not_open",
                 message = "The city is still opening. Try again in a moment." }
    end
    -- Who is acting is looked up, not taken. The same rule, and the same
    -- lookup, that decides it for a player pressing a key.
    local sessions = world.services.sessions
    Addons.acting(context, sessions and function(account)
        return sessions:character_of(account)
    end or nil)

    local outcome = world:dispatch(name, shaped, context)
    say(("%s for %s: %s"):format(name, context.source, outcome.code))
    return outcome:summary()
end)

-- Every event, as it happens, to whoever is listening. A watcher rather than a
-- subscription per name: an addon written today has to be able to hear an event
-- added tomorrow, and a list of names here would be a list that goes stale.
world.events:watch(function(event)
    TriggerEvent("nyr:event", event.name, Addons.payload(event.payload))
end, { label = "addons" })

-- ------------------------------------------------------------------ damage
--
-- The simulation refuses to take damage from a command, so it has to come from
-- somewhere the server can see for itself. This reads the health of each
-- connected ped from the server's own copy and reports the drop.
--
-- What it deliberately does not do is name an attacker. FiveM will tell a
-- server who shot whom through weaponDamageEvent, but that event is the
-- client's account of what it just did, and a client that can report damage it
-- dealt can report damage it did not deal. Unattributed damage produces a
-- health change and no crime record, which is the direction that fails safe:
-- nobody is accused of anything on a client's say-so. Attribution belongs
-- behind a corroborating check and is not here yet.

local HEALTH_TICK_MS = 1000
local watched = {}          -- character -> the health we last saw

local function watch_health()
    if not is_open() then return end
    local sessions = world.services.sessions
    if not sessions then return end
    local seen = {}
    for _, player in ipairs(GetPlayers()) do
        local account = Bridge.account_of(player)
        local character = account and sessions:character_of(account)
        if character then
            seen[character] = true
            local ped = GetPlayerPed(player)
            if ped and ped ~= 0 then
                -- Read as a percentage of whatever this ped's range actually
                -- is, so the simulation never learns what a game health value
                -- is and this code does not care which version of the game is
                -- underneath it. The 100..200 range is a convention of one
                -- version, not a fact, and hardcoding it is how a damage
                -- watcher silently misreads on the other.
                local raw = GetEntityHealth(ped)
                local ceiling = GetEntityMaxHealth and GetEntityMaxHealth(ped) or 0
                if not ceiling or ceiling <= 0 then ceiling = 200 end
                local floor = ceiling > 100 and 100 or 0
                local span = ceiling - floor
                if span <= 0 then span = 1 end
                local now = math.floor(((raw - floor) / span) * 100)
                if now < 0 then now = 0 elseif now > 100 then now = 100 end
                local before = watched[character]
                if before == nil then
                    watched[character] = now
                elseif now < before then
                    local lost = before - now
                    watched[character] = now
                    local ok, err = pcall(function()
                        return world.services.health.harm(
                            ("ped:%s:%d"):format(character, GetGameTimer()),
                            character, lost, { cause = "injury" })
                    end)
                    if not ok then say("damage: " .. tostring(err)) end
                elseif now > before then
                    watched[character] = now
                end
            end
        end
    end
    for character in pairs(watched) do
        if not seen[character] then watched[character] = nil end
    end
end

-- Opening the city touches the store, and a database driver's blocking call
-- yields the calling coroutine -- which a resource's main chunk is not. So it
-- happens here, on a thread, after everything above has been registered. Until
-- it finishes the bridge refuses every request, so a player who connects during
-- the second it takes is told to wait rather than handed a city that has not
-- been read yet and allowed to make a character on top of one that exists.
CreateThread(function()
    local opened, trouble = open_store(store, sql)
    if not opened then
        refuse_to_start(trouble)
        return
    end
    say("the city is kept in " .. where)
    read_the_city()
end)

CreateThread(function()
    while true do
        Wait(HEALTH_TICK_MS)
        local ok, err = pcall(watch_health)
        if not ok then say("health watch: " .. tostring(err)) end
    end
end)

-- -------------------------------------------------------------------- loop

-- The city tick. It moves time and runs what fell due; nothing else in the
-- simulation runs on a timer.
CreateThread(function()
    local last = GetGameTimer()
    while true do
        Wait(TICK_MS)
        local now = GetGameTimer()
        local elapsed = now - last
        last = now
        if is_open() then
            local ok, err = pcall(function() return world:tick(elapsed) end)
            if not ok then say("tick: " .. tostring(err)) end
        end
    end
end)

-- The save tick, separate so a slow write never delays city time.
--
-- It waits for the city to open. The world refuses to be written down before
-- it has been read in any case; asking first is what keeps that refusal from
-- being printed every minute a city stays shut, scrolling the message that says
-- why off the console.
CreateThread(function()
    while true do
        Wait(SAVE_MS)
        if is_open() then
            local saved, failures = world:save()
            if not saved then
                for _, failure in ipairs(failures) do say("save: " .. failure) end
            end
        end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    if not storage_guard:check() then
        city_open = false
        say("shutdown durability UNKNOWN after storage identity change; no write attempted")
        return
    end
    if drain.status ~= "IDLE" then
        local result = drain:report()
        say("shutdown after drain: " .. result.status)
        if not result.safe_to_stop then say("durability UNKNOWN; no overlapping shutdown write attempted") end
        return
    end
    if not city_open then
        say("the city never opened; shutdown left the saved city untouched")
        return
    end
    city_open = false
    local note = Console.shutdown_note(sql ~= nil, store.commits_whole ~= nil and store:commits_whole())
    if note then say(note) end
    local saved, failures = world:close()
    if saved then
        say("the city was written down at " .. world.clock:describe())
    else
        for _, failure in ipairs(failures) do say("shutdown save: " .. failure) end
    end
end)

-- ---------------------------------------------------------------- console

-- Server console only. Draining closes these administrative write paths too.
RegisterCommand("nyr", function(source, args)
    if source ~= 0 then return end
    local what = args[1] or "summary"
    if what == "drain" then
        local result = begin_drain()
        say("restart drain: " .. result.status)
        return
    end
    if not is_open() and (what == "commission" or what == "found" or what == "staff" and args[2]) then
        say("the city is closed; no administrative write accepted")
        return
    end
    if what == "summary" then
        local summary = world:summary()
        say(("%s | systems: %s | accounts: %d | owned: %d | tasks: %d | errors: %d"):format(
            summary.at, table.concat(summary.systems, ", "),
            summary.accounts, summary.owned, summary.pending_tasks, summary.errors))
        for kind, count in pairs(summary.entities) do say(("  %s: %d"):format(kind, count)) end
    elseif what == "verify" then
        local ok, found = world:verify()
        local stock, stock_problems = world.services.inventory:verify()
        local book, book_problems = world.services.record:verify()
        if ok and stock and book then
            say("everything checks out")
        else
            for _, list in ipairs({ found, stock_problems, book_problems }) do
                for _, problem in ipairs(list) do say("  " .. problem) end
            end
        end
    elseif what == "errors" then
        for _, entry in ipairs(world:errors(20)) do
            say(("  %s [%s] %s"):format(world.clock:describe(entry.at), entry.source, entry.message))
        end
    elseif what == "notices" then
        for _, entry in ipairs(world:notices(20)) do
            say(("  %s [%s] %s"):format(world.clock:describe(entry.at), entry.source, entry.message))
        end
    elseif what == "audit" then
        for _, entry in ipairs(world:audit(20)) do
            say(("  %s %s %s -> %s"):format(world.clock:describe(entry.at),
                tostring(entry.actor), entry.name, entry.code))
        end
    elseif what == "commission" then
        -- The one write on the console, and it is here rather than in a
        -- command because a commission must never come from a client.
        local who = args[2]
        if not who then
            say("nyr commission <character id> [off]")
        else
            local granted = args[3] ~= "off"
            world.services.police.commission(who, granted)
            say((granted and "commissioned " or "stood down ") .. who)
        end
    elseif what == "found" then
        -- Founding a crew is a console action for the same reason a commission
        -- is: which factions exist is the city's business, not a client's.
        local name, tag, founder = args[2], args[3], args[4]
        if not (name and tag and founder) then
            say("nyr found <name> <TAG> <character id>")
        else
            local ok, made = pcall(world.services.gangs.found, name, tag, founder)
            say(ok and ("founded " .. name .. " as " .. made.id) or ("could not: " .. tostring(made)))
        end
    elseif what == "staff" then
        local who = args[2]
        if not who then
            for _, row in ipairs(world.services.admin.staff()) do
                say(("  %-26s %s"):format(row.character, row.title))
            end
            say("nyr staff <character id> <1 moderator | 2 admin | 3 owner | 0 none>")
        else
            local level, usage = Console.staff_level(args[3])
            if level == nil then
                say(usage)
            else
                local granted = world.services.admin.grant(who, level ~= 0 and level or nil)
                if granted == 0 then
                    say("stood down " .. who)
                else
                    say(("%s is now %s"):format(who, Admin.LEVEL_NAMES[granted]))
                end
            end
        end
    elseif what == "turf" then
        for _, turf in ipairs(world.services.gangs.turfs:where(function() return true end)) do
            say(("  %-20s %s"):format(turf:get("name"), world.services.gangs.holder_of(turf.id)))
        end
    elseif what == "wanted" then
        for _, row in ipairs(world.services.standing:ranked("police", { limit = 20, min_magnitude = 1 })) do
            say(("  %s  heat %d"):format(row.subject, -row.score))
        end
    elseif what == "save" then
        if not is_open() then say("the city is not open; nothing was saved"); return end
        local saved, failures = world:save()
        say(saved and "written down" or table.concat(failures, "; "))
    elseif what == "store" then
        -- Where the city is kept, and whether it is keeping up. An owner
        -- watching `waiting` climb knows their database is behind before a
        -- player does.
        say(("kept in %s | %s"):format(where, city_open and "open" or "still opening"))
        if sql then
            local reachable, refused = SqlDriver.check(sql)
            say("  the database " .. (reachable and "answers" or ("refused: " .. tostring(refused))))
            say(("  waiting to be written: %d"):format(store:pending()))
            say("  a save goes down " .. (store:commits_whole() and "as one transaction"
                or "a statement at a time (this driver has no transaction the store can use)"))
            say(("  collections: %s"):format(table.concat(store:collections(), ", ")))
        end
        for _, message in ipairs(store.notices and store:notices() or {}) do
            say("  " .. message)
        end
    else
        say("nyr summary | verify | errors | notices | audit | wanted | turf | staff | commission | found | save | store | drain")
    end
end, true)

_G.NyrUnderworld = {
    world = world,
    clock = Clock,
    items = items,
}
