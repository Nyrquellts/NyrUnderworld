--- Build a real city, play a little, and dump what the interface would be
--- given to draw. No invented data: every view below comes out of the same
--- view builders the server calls, over the same systems, from the shipped
--- config.
local json = require("support.json")
local Clock = require("core.clock")
local World = require("core.world")
local Items = require("domain.items")
local Settings = require("support.settings")
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
local NuiState = require("adapter.nui_state")

local settings = assert(Settings.read(dofile("config.lua")))

local items = Items.catalogue()
for _, item in ipairs(settings.items) do
    local id = item.id
    item.id = nil
    items:define(id, item)
    item.id = id
end

local world = World.new({ rate = 60, start_at = 21 * Clock.MS_PER_HOUR + 14 * Clock.MS_PER_MINUTE })
for _, system in ipairs({
    Characters.system(), Memory.system(), InventorySystem.system({ items = items }),
    Work.system(), Property.system(), Vehicles.system(), Police.system(),
    Banking.system(), Shops.system(), Health.system(), Gangs.system(),
    Phone.system(), Fencing.system(), Admin.system(), Overview.system(),
}) do world:install(system) end

-- The city from config.lua, built the way the server builds it.
for _, employer in ipairs(settings.employers) do
    world.services.work.employ(employer.name, { external = employer.external, offers = employer.offers })
end
local by_address = {}
for _, place in ipairs(settings.places) do
    by_address[place.address] = world.services.property.build(place.address, {
        kind = place.kind, price = place.price, rent = place.rent,
        x = place.x, y = place.y, z = place.z, radius = place.radius })
end
for _, bank in ipairs(settings.banks) do
    by_address[bank.name] = world.services.banking.branch(bank.name,
        { x = bank.x, y = bank.y, z = bank.z, radius = bank.radius })
end
for _, shop in ipairs(settings.shops) do
    world.services.shops.open(shop.name, by_address[shop.at].id,
        { prices = shop.prices, restock = shop.restock, float = shop.float })
end
for _, turf in ipairs(settings.turfs) do
    world.services.gangs.draw(turf.name, { x = turf.x, y = turf.y, z = turf.z, radius = turf.radius })
end
for _, fence in ipairs(settings.fences) do
    world.services.fencing.open(fence.name, by_address[fence.at].id,
        { pays = fence.pays, chops = fence.chops })
end

-- Two people on one account, which is what the picker is for.
local ACCOUNT = "license:5f2c9a41e77b"
local OTHER = "license:aa10bb20cc30"

local function make(account, first, last)
    local made = world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account })
    assert(made.ok, tostring(made.message))
    return made.value
end

local vic = make(ACCOUNT, "Vic", "Ortega")
local rosa = make(ACCOUNT, "Rosa", "Lindqvist")
local dmitri = make(OTHER, "Dmitri", "Volkov")

world:dispatch("character.select", { character = vic }, { account = ACCOUNT })
world:dispatch("character.select", { character = dmitri }, { account = OTHER })

-- Give them a night's worth of things, through the inventory service the
-- systems use, so weights and stacks are the real ones.
local inventory = world.services.inventory
local pockets = InventorySystem.pockets(vic)
local function carry(item, count)
    inventory:spawn("seed:pockets:" .. item, pockets, item, count)
end
for _, row in ipairs({
    { "water", 4 }, { "burger", 2 }, { "bandage", 3 }, { "lockpick", 2 },
    { "scrap", 11 }, { "watch", 2 },
}) do
    local ok, why = pcall(carry, row[1], row[2])
    if not ok then io.stderr:write(("could not carry %s: %s\n"):format(row[1], tostring(why))) end
end

local Money = require("domain.money")
world.ledger:transfer("seed-vic", "external:mint", Characters.wallet(vic), Money.of(4180, 50))
world.ledger:transfer("seed-rosa", "external:mint", Characters.wallet(rosa), Money.of(312, 20))
world.ledger:transfer("seed-dmitri", "external:mint", Characters.wallet(dmitri), Money.of(90, 00))

-- A few texts, sent through the phone system.
local vic_number = nil
local rosa_number = nil
do
    local mine = world:dispatch("phone.number", {}, { account = ACCOUNT, actor = vic })
    vic_number = mine.ok and mine.value and (mine.value.number or mine.value) or nil
    local theirs = world:dispatch("phone.number", {}, { account = OTHER, actor = dmitri })
    rosa_number = theirs.ok and theirs.value and (theirs.value.number or theirs.value) or nil
end

if vic_number and rosa_number then
    for _, line in ipairs({
        { OTHER, dmitri, rosa_number, vic_number, "you still holding the watches" },
        { ACCOUNT, vic, vic_number, rosa_number, "two. nobody's is paying 40 each" },
        { OTHER, dmitri, rosa_number, vic_number, "cypress flats. after the shift ends" },
        { ACCOUNT, vic, vic_number, rosa_number, "ill be there" },
        { OTHER, dmitri, rosa_number, vic_number, "dont bring the car" },
    }) do
        local sent = world:dispatch("phone.send", { to = line[4], body = line[5] },
            { account = line[1], actor = line[2] })
        if not sent.ok then io.stderr:write("phone: " .. tostring(sent.message) .. "\n") end
        world:tick(90000)
    end
end

-- --------------------------------------------------------------- the views

local function ask(name, args, actor, account)
    local outcome = world:dispatch(name, args or {}, { account = account or ACCOUNT, actor = actor or vic })
    if not outcome.ok then
        io.stderr:write(("%s refused: %s %s\n"):format(name, tostring(outcome.code), tostring(outcome.message)))
        return nil
    end
    return outcome.value
end

-- The one answer that comes from outside the simulation. On a server this
-- reads the server's own copy of where the ped is; here Vic is standing at
-- whatever is being looked at.
world.services.proximity = function() return true end

-- Vic buys the flat and walks in, because reach into a stash is a grant the
-- server issues at the door and expires -- not a fact about standing near it.
-- Both go through the commands a player uses, so the money moves through the
-- ledger the way it really does.
local home = by_address["Integrity Way, Apt 28"]
local bought = world:dispatch("property.buy", { place = home.id },
    { account = ACCOUNT, actor = vic, operation_id = "seed:buy-home" })
if not bought.ok then io.stderr:write("property.buy refused: " .. tostring(bought.message)) end
local entered = world:dispatch("property.enter", { place = home.id }, { account = ACCOUNT, actor = vic })
if not entered.ok then io.stderr:write("property.enter refused: " .. tostring(entered.message)) end

-- Dmitri banks at Pillbox Hill: an account opened at the branch, money paid in
-- and some taken out, through the commands a player uses so the lines on the
-- statement are real postings. Dmitri, not Vic or Rosa, because their wallets
-- are figures the listing already quotes and a deposit would change them.
local pillbox = by_address["Pillbox Hill Branch"]
for _, step in ipairs({
    { "bank.open", { branch = pillbox.id }, "seed:dmitri:open" },
    { "bank.deposit", { branch = pillbox.id, amount = 45000 }, "seed:dmitri:deposit" },
    { "bank.withdraw", { branch = pillbox.id, amount = 6000 }, "seed:dmitri:withdraw" },
}) do
    -- No city time between these: Vic's reach into his stash, granted at the
    -- door above, expires, and a tick here drew the stash screen refused.
    local done = world:dispatch(step[1], step[2], { account = OTHER, actor = dmitri, operation_id = step[3] })
    if not done.ok then io.stderr:write(("%s refused: %s\n"):format(step[1], tostring(done.message))) end
end

local views = {}

views.picker = NuiState.picker(ask("character.list", {}, nil, ACCOUNT))
local carried = ask("me.pockets")
views.pockets = NuiState.pockets(carried)

local inbox = ask("phone.inbox")
views.inbox = NuiState.inbox(inbox)
if rosa_number then
    views.thread = NuiState.thread(ask("phone.thread", { with = rosa_number }))
end

local shop_id = nil
for _, shop in ipairs(world.services.shops.shops:where(function() return true end)) do
    shop_id = shop.id
end
views.shop = NuiState.shop(ask("shop.list", { shop = shop_id }))

views.nearby = NuiState.nearby(ask("me.nearby"))

views.bank = NuiState.bank(ask("bank.statement", {}, dmitri, OTHER))
-- The page carries the branch it is standing at on every button it draws.
views.bank_branch = pillbox.id

views.jobs = NuiState.jobs(ask("work.list"))

local stash_container = Property.stash and Property.stash(home.id) or nil
if stash_container then
    inventory:spawn("seed:stash:scrap", stash_container, "scrap", 9)
    inventory:spawn("seed:stash:water", stash_container, "water", 6)
    inventory:spawn("seed:stash:watch", stash_container, "watch", 1)
end
local put_down = stash_container and ask("inventory.look", { container = stash_container }) or nil
views.stash = NuiState.stash(carried, put_down, {
    pockets = carried and carried.container or nil,
    stash = stash_container,
    address = home:get("address"),
})

io.write(json.encode(views, { indent = true }))
