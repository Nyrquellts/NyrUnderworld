--- The city an owner configured, assembled the way the server assembles it.
--
-- This used to live in `adapter/server.lua`, which only FXServer can load. So
-- which systems a real city has, in what order, and what a restart adds from
-- config.lua were decisions no spec could reach -- and anything that wanted a
-- world like the real one (a spec, the fuzzer, a rehearsal) had to copy the
-- list and hope it stayed in step. This file knows no natives: the server
-- hands it a store and somewhere to print, and so does everything else.

local World = require("core.world")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Work = require("systems.work")
local Property = require("systems.property")
local Vehicles = require("systems.vehicles")
local Police = require("systems.police")
local Banking = require("systems.banking")
local Shops = require("systems.shops")
local Health = require("systems.health")
local Gangs = require("systems.gangs")
local Phone = require("systems.phone")
local Fencing = require("systems.fencing")
local Admin = require("systems.admin")
local Overview = require("systems.overview")

local City = {}

--- The item catalogue config.lua describes.
function City.catalogue(settings)
    local items = Items.catalogue()
    for _, item in ipairs(settings.items) do
        local id = item.id
        item.id = nil
        items:define(id, item)
        item.id = id
    end
    return items
end

--- Every system a real city runs, in the order it installs them.
function City.systems(items)
    return {
        Characters.system(),
        Memory.system(),
        InventorySystem.system({ items = items }),
        Work.system(),
        Property.system(),
        Vehicles.system(),
        Police.system(),
        Banking.system(),
        Shops.system(),
        Health.system(),
        Gangs.system(),
        Phone.system(),
        Fencing.system(),
        Admin.system(),
        Overview.system(),
    }
end

--- A world with every system installed and nothing read yet.
---
--- opts.store      where the city is kept
--- opts.on_error   called with (message, source)
--- opts.on_notice  called with (message, source)
---
--- Returns the world and the item catalogue.
function City.build(settings, opts)
    opts = opts or {}
    local items = City.catalogue(settings)
    local world = World.new({
        store = opts.store,
        rate = settings.city.rate,
        -- This world stands for the city already in the store, so it writes
        -- nothing down until it has read it. Built without this, a server that
        -- refused to start emptied the ledger and the ownership register one
        -- save tick later.
        require_load = true,
        on_error = opts.on_error,
        -- Healthy things that are worth saying once. Kept out of the error
        -- channel so that channel stays worth reading: a server that prints a
        -- catch-up notice as an error teaches its owner to ignore errors.
        on_notice = opts.on_notice,
    })
    for _, system in ipairs(City.systems(items)) do world:install(system) end
    return world, items
end

local function first(repository, field, value)
    local found = repository:where(function(entity) return entity:get(field) == value end)
    return found[1]
end

--- What config.lua names and the city does not have yet, added to a world that
--- has already been read.
---
--- Keyed by name, not by "is the city empty". The difference is the whole
--- point of having a config: an owner who adds a shop and restarts gets a
--- shop, rather than nothing, because the city was not empty. Anything already
--- there is left exactly as it is -- its stock, its till, whoever owns it -- so
--- restarting never reverts a city to its seed.
---
--- `say` is handed every line worth an owner reading. Returns what was done:
--- { added = { "2 employers", ... }, delisted = n, moved = n }.
function City.seed(world, settings, say)
    say = say or function() end
    local added = {}

    local function count(what, n)
        if n > 0 then added[#added + 1] = ("%d %s"):format(n, what) end
    end

    local employers = world:repository(Work.Employer)
    local hired = 0
    for _, employer in ipairs(settings.employers) do
        if not first(employers, "name", employer.name) then
            world.services.work.employ(employer.name,
                { external = employer.external, offers = employer.offers })
            hired = hired + 1
        end
    end
    count("employers", hired)

    local places = world.services.property.places
    local built, delisted, moved = 0, 0, 0
    for _, place in ipairs(settings.places) do
        local standing = first(places, "address", place.address)
        if not standing then
            world.services.property.build(place.address, {
                kind = place.kind, price = place.price, rent = place.rent,
                x = place.x, y = place.y, z = place.z, radius = place.radius })
            built = built + 1
        else
            -- Two things a city that has already been played can be wrong
            -- about, both decided in `systems/property` where a spec reaches
            -- every branch. What is left here is the write.
            local elsewhere = Property.misplaced(standing, place)
            if elsewhere then
                standing:patch(elsewhere)
                places:save(standing)
                moved = moved + 1
            end
            if Property.left_on_the_market(standing,
                world.services.property.holder(standing.id)) then
                standing:patch({ for_sale = false })
                places:save(standing)
                delisted = delisted + 1
            end
        end
    end
    count("addresses", built)

    -- A bank is a place with a door, so it is a place: same entity, same
    -- coordinates, same proximity service as every other door in the city.
    local opened = 0
    for _, bank in ipairs(settings.banks) do
        if not first(places, "address", bank.name) then
            world.services.banking.branch(bank.name,
                { x = bank.x, y = bank.y, z = bank.z, radius = bank.radius })
            opened = opened + 1
        end
    end
    count("branches", opened)

    local shops = world.services.shops.shops
    local counters = 0
    for _, shop in ipairs(settings.shops) do
        if not first(shops, "name", shop.name) then
            local at = first(places, "address", shop.at)
            if at then
                world.services.shops.open(shop.name, at.id, {
                    prices = shop.prices, restock = shop.restock, float = shop.float })
                counters = counters + 1
            else
                -- The config checker refuses this, so reaching it means the
                -- address was removed from a city that already had the shop.
                say(("%s has no address: %s is not in the city"):format(shop.name, shop.at))
            end
        end
    end
    count("shops", counters)

    local turfs = world.services.gangs.turfs
    local drawn = 0
    for _, turf in ipairs(settings.turfs) do
        if not first(turfs, "name", turf.name) then
            world.services.gangs.draw(turf.name,
                { x = turf.x, y = turf.y, z = turf.z, radius = turf.radius })
            drawn = drawn + 1
        end
    end
    count("blocks", drawn)

    local fences = world.services.fencing.fences
    local quiet = 0
    for _, fence in ipairs(settings.fences) do
        if not first(fences, "name", fence.name) then
            local at = first(places, "address", fence.at)
            if at then
                world.services.fencing.open(fence.name, at.id,
                    { pays = fence.pays, chops = fence.chops })
                quiet = quiet + 1
            else
                say(("%s has no address: %s is not in the city"):format(fence.name, fence.at))
            end
        end
    end
    count("fences", quiet)

    if #added > 0 then say("added from config.lua: " .. table.concat(added, ", ")) end
    -- Its own line, not an item in the list above. Putting it there printed
    -- "added from config.lua: 2 premises taken off the market", which says the
    -- opposite of what happened, and a line that reads as authoritative and is
    -- wrong is the most expensive thing this file can print.
    if delisted > 0 then
        say(("%d premises taken off the market: a business's front door is not housing")
            :format(delisted))
    end
    if moved > 0 then
        say(("%d address(es) moved to where config.lua says they are"):format(moved))
    end

    return { added = added, delisted = delisted, moved = moved }
end

--- The line a server prints once the city is open.
function City.describe(world)
    return ("the city is at %s with %d people, %d addresses"):format(
        world.clock:describe(),
        world:repository(Characters.Character):count(),
        world.services.property.places:count())
end

return City
