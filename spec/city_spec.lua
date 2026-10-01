--- The city a server builds, built here.
---
--- `adapter/server.lua` cannot be loaded by this suite, so what it decides is
--- decided in `adapter/city.lua` and held here: which systems a real city runs,
--- and what a restart adds from config.lua without touching what a played city
--- already has.
local modname = ...
local lu = require("luaunit")
local City = require("adapter.city")
local Settings = require("support.settings")
local MemoryStore = require("persistence.memory_store")
local Money = require("domain.money")

local function shipped_settings()
    local settings, problems = Settings.read(require("config"))
    lu.assertEquals(problems, {}, "the shipped config.lua must read clean")
    return settings
end

local function open(store, settings)
    local world = City.build(settings, { store = store })
    local loaded, problems = world:load()
    lu.assertTrue(loaded, table.concat(problems or {}, "; "))
    return world
end

local function read(path)
    local handle = assert(io.open(path, "r"))
    local text = handle:read("a")
    handle:close()
    return text
end

TestCity = {}

function TestCity:test_a_city_runs_every_system_the_server_names()
    local world = City.build(shipped_settings(), { store = MemoryStore.new() })
    lu.assertEquals(world:systems(), {
        "characters", "memory", "inventory", "work", "property", "vehicles",
        "police", "banking", "shops", "health", "gangs", "phone", "fencing",
        "admin", "overview",
    })
end

function TestCity:test_a_first_boot_adds_everything_config_names()
    local settings = shipped_settings()
    local world = open(MemoryStore.new(), settings)
    local said = {}
    local report = City.seed(world, settings, function(line) said[#said + 1] = line end)

    lu.assertEquals(world.services.property.places:count(), #settings.places + #settings.banks)
    lu.assertEquals(world.services.shops.shops:count(), #settings.shops)
    lu.assertEquals(world.services.gangs.turfs:count(), #settings.turfs)
    lu.assertEquals(world.services.fencing.fences:count(), #settings.fences)
    lu.assertTrue(#report.added > 0)
    lu.assertStrContains(said[1], "added from config.lua: ")
    lu.assertStrContains(City.describe(world), ("%d addresses"):format(#settings.places + #settings.banks))

    local ok, problems = world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    lu.assertEquals(world.ledger:total(), Money.zero)
end

function TestCity:test_seeding_a_city_that_has_it_all_adds_nothing()
    local settings = shipped_settings()
    local world = open(MemoryStore.new(), settings)
    City.seed(world, settings)
    local said = {}
    local report = City.seed(world, settings, function(line) said[#said + 1] = line end)
    lu.assertEquals(report.added, {})
    lu.assertEquals(said, {})
end

function TestCity:test_a_restart_keeps_the_city_it_read_rather_than_the_seed()
    local settings = shipped_settings()
    local store = MemoryStore.new()
    local first = open(store, settings)
    City.seed(first, settings)
    local shop = first.services.shops.shops:where(function() return true end)[1]
    local Shops = require("systems.shops")
    local till_before = first.services.shops.till_of(shop)
    first.ledger:transfer("spec-till", "external:mint", Shops.counter(shop.id), Money.of(1234))
    lu.assertTrue(first:save())

    local second = open(store, settings)
    local report = City.seed(second, settings)
    lu.assertEquals(report.added, {})
    lu.assertEquals(second.services.shops.till_of(second.services.shops.shops:load(shop.id)),
        till_before:add(Money.of(1234)))
    lu.assertEquals(second.services.shops.shops:count(), #settings.shops)
end

function TestCity:test_the_server_builds_its_city_here_and_nowhere_else()
    -- The point of this file is that there is one list. A server that went back
    -- to installing systems itself would be a second one again.
    local server = read("adapter/server.lua")
    lu.assertNil(server:find(":install(", 1, true), "adapter/server.lua installs a system itself")
    lu.assertNil(server:find("World.new(", 1, true), "adapter/server.lua builds its own world")
    lu.assertNotNil(server:find("City.build(", 1, true))
    lu.assertNotNil(server:find("City.seed(", 1, true))
end

if modname == nil then
    os.exit(lu.LuaUnit.run())
end
