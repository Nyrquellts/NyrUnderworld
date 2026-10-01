--- The city an owner typed, checked before any of it is built.
--
-- Everything a server owner is expected to change lives in `config.lua` at the
-- root of the resource: the items, the jobs, the addresses, the shops and what
-- they charge, the blocks a crew can hold, who buys stolen goods. None of it is
-- in a Lua file anyone has to read code to edit, and none of it is a rule --
-- the rules are in `domain/` and an owner cannot reach them from here.
--
-- Why this file is not in `adapter/`
-- ----------------------------------
-- Because then it could only be tested with a server under it, and a config
-- error is the failure a paying owner meets first. This is plain Lua over plain
-- tables, and `spec/settings_spec.lua` attacks it the way an owner will: a
-- misspelled key, a price on an item that does not exist, a shop in a building
-- that was never built, two things with the same name, a number where a string
-- goes.
--
-- Every problem, not the first one
-- --------------------------------
-- `Schema.validate` stops at the first bad field, which is right for a client
-- request and wrong here: an owner who has made four mistakes should be told
-- about four mistakes, with the path to each, rather than finding them one
-- server restart at a time. So this collects.
--
-- Refusing, not repairing
-- -----------------------
-- A config with any problem in it does not start a city. Dropping the bad
-- entries and carrying on would give an owner a server that runs with their
-- shop missing and nothing obviously wrong, and they would notice in a week.
-- An unknown key is a problem too, for the same reason a misspelled key that
-- is quietly ignored is the worst kind: everything looks fine and the setting
-- does nothing.

local Schema = require("domain.schema")
local Items = require("domain.items")

local Settings = {}

local SECTIONS = { "city", "items", "employers", "places", "banks", "shops", "turfs", "fences" }

-- ------------------------------------------------------------------ the shape

local CITY = {
    -- City milliseconds per real millisecond. 60 makes a real minute a city
    -- hour, so a full day passes in twenty-four real minutes.
    rate = { type = "integer", default = 60, min = 1, max = 3600 },
    -- Real milliseconds between ticks. Nothing in the simulation is
    -- frame-accurate; everything that is belongs on the client.
    tick_ms = { type = "integer", default = 1000, min = 100, max = 60000 },
    -- How often the city is written down. A minute of lost play is survivable;
    -- an hour is not, and writing every change spends the frame budget on the
    -- database.
    save_ms = { type = "integer", default = 60000, min = 5000, max = 3600000 },
    -- How far away somebody can be and still have seen it happen, in metres.
    witness_range = { type = "number", default = 25.0, min = 1.0, max = 500.0 },
}

local ITEM = {
    id = { type = "string", required = true, check = function(v)
        if not Items.is_id(v) then return false, "an item id is lowercase letters, digits and underscores" end
        return true
    end },
    label = { type = "string", required = true, max = 64 },
    weight = { type = "integer", default = 0, min = 0 },
    stack = { type = "integer", default = 1, min = 1, max = 1000 },
    unique = { type = "boolean", default = false },
    category = { type = "string", default = "misc", enum = {
        "consumable", "tool", "weapon", "material", "document", "valuable", "clothing", "misc" } },
    droppable = { type = "boolean", default = true },
    sellable = { type = "boolean", default = true },
    illegal = { type = "boolean", default = false },
}

local EMPLOYER = {
    name = { type = "string", required = true, max = 64 },
    external = { type = "boolean", default = true },
    offers = { type = "table", default = {} },
}

local PLACE = {
    address = { type = "string", required = true, max = 64 },
    kind = { type = "string", default = "apartment", enum = {
        "apartment", "house", "garage", "lockup", "office", "bank", "shop" } },
    price = { type = "integer", default = 0, min = 0 },
    rent = { type = "integer", default = 0, min = 0 },
    x = { type = "number", default = 0.0 },
    y = { type = "number", default = 0.0 },
    z = { type = "number", default = 0.0 },
    radius = { type = "number", default = 4.0, min = 0.5, max = 500.0 },
}

local BANK = {
    name = { type = "string", required = true, max = 64 },
    x = { type = "number", default = 0.0 },
    y = { type = "number", default = 0.0 },
    z = { type = "number", default = 0.0 },
    radius = { type = "number", default = 6.0, min = 0.5, max = 500.0 },
}

local SHOP = {
    name = { type = "string", required = true, max = 64 },
    -- The address of a place in `places`. Named rather than given an id,
    -- because ids are made at boot and an owner has no way to know one.
    at = { type = "string", required = true, max = 64 },
    prices = { type = "table", required = true },
    restock = { type = "table", default = {} },
    float = { type = "integer", default = 0, min = 0 },
}

local TURF = {
    name = { type = "string", required = true, max = 64 },
    x = { type = "number", default = 0.0 },
    y = { type = "number", default = 0.0 },
    z = { type = "number", default = 0.0 },
    radius = { type = "number", default = 90.0, min = 1.0, max = 2000.0 },
}

local FENCE = {
    name = { type = "string", required = true, max = 64 },
    at = { type = "string", required = true, max = 64 },
    pays = { type = "table", required = true },
    chops = { type = "boolean", default = false },
}

local ENTRY_FIELDS = {
    items = ITEM, employers = EMPLOYER, places = PLACE,
    banks = BANK, shops = SHOP, turfs = TURF, fences = FENCE,
}

Settings.SECTIONS = SECTIONS
Settings.ENTRY_FIELDS = ENTRY_FIELDS
Settings.CITY_FIELDS = CITY

-- ------------------------------------------------------------------ checking

local function note(problems, path, message)
    problems[#problems + 1] = ("%s: %s"):format(path, message)
end

local function is_list(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count == #value
end

--- Prices and payouts are tables keyed by item id, and both are where a typo
--- hides best: `wtaer = { buy = 250 }` is a shop that quietly sells nothing.
local function check_item_map(problems, path, map, known, shape)
    if type(map) ~= "table" then
        note(problems, path, "should be a table keyed by item id")
        return
    end
    for id, value in pairs(map) do
        local where = ("%s.%s"):format(path, tostring(id))
        if not Items.is_id(id) then
            note(problems, where, "is not an item id")
        elseif not known[id] then
            note(problems, where, "names an item that is not in `items`")
        elseif shape == "money" then
            if math.type(value) ~= "integer" or value < 0 then
                note(problems, where, "should be a whole number of cents, zero or more")
            end
        elseif type(value) ~= "table" then
            note(problems, where, "should be a table with `buy`, `sell`, or both")
        else
            local saw = false
            for key, amount in pairs(value) do
                if key ~= "buy" and key ~= "sell" then
                    note(problems, ("%s.%s"):format(where, tostring(key)),
                         "is not a price; a price is `buy` or `sell`")
                elseif math.type(amount) ~= "integer" or amount < 0 then
                    note(problems, ("%s.%s"):format(where, key),
                         "should be a whole number of cents, zero or more")
                else
                    saw = true
                end
            end
            if not saw then
                note(problems, where, "has neither a `buy` nor a `sell` price, so nothing can happen here")
            end
        end
    end
end

local function check_entries(problems, section, raw, fields)
    local clean = {}
    if raw == nil then return clean end
    if not is_list(raw) then
        note(problems, section, "should be a list of entries, written as { { ... }, { ... } }")
        return clean
    end
    for index, entry in ipairs(raw) do
        local path = ("%s[%d]"):format(section, index)
        if type(entry) ~= "table" then
            note(problems, path, "should be a table")
        else
            local checked, why = Schema.validate(fields, entry)
            if not checked then
                note(problems, path, tostring(why))
            else
                clean[#clean + 1] = checked
            end
        end
    end
    return clean
end

--- Two things that answer to one name is the bug an owner cannot see: the
--- second silently replaces the first, or the first wins and the second does
--- nothing, and which one depends on code they cannot read.
local function check_unique(problems, section, entries, key)
    local seen = {}
    for index, entry in ipairs(entries) do
        local value = entry[key]
        if value ~= nil then
            if seen[value] then
                note(problems, ("%s[%d].%s"):format(section, index, key),
                     ("%q is already used by %s[%d]"):format(tostring(value), section, seen[value]))
            else
                seen[value] = index
            end
        end
    end
    return seen
end

--- Read a config.
---
--- Returns settings, problems. `problems` is empty when the config is good;
--- when it is not, `settings` is whatever could be read and must not be used.
--- Nothing here throws: an owner's typo is not a stack trace.
function Settings.read(raw)
    local problems = {}
    if raw == nil then raw = {} end
    if type(raw) ~= "table" then
        note(problems, "config", "should return a table")
        return {}, problems
    end

    local declared = {}
    for _, name in ipairs(SECTIONS) do declared[name] = true end
    for name in pairs(raw) do
        if not declared[name] then
            note(problems, tostring(name),
                 ("is not a section. The sections are: %s"):format(table.concat(SECTIONS, ", ")))
        end
    end

    local settings = {}

    local city, why = Schema.validate(CITY, raw.city)
    if not city then
        note(problems, "city", tostring(why))
        settings.city = Schema.validate(CITY, {})
    else
        settings.city = city
    end

    for _, section in ipairs({ "items", "employers", "places", "banks", "shops", "turfs", "fences" }) do
        settings[section] = check_entries(problems, section, raw[section], ENTRY_FIELDS[section])
    end

    local items = check_unique(problems, "items", settings.items, "id")
    check_unique(problems, "employers", settings.employers, "name")
    local addresses = check_unique(problems, "places", settings.places, "address")
    -- A branch is a place whose address is the bank's name -- same entity, same
    -- door, same proximity check -- so the two share one namespace, and a bank
    -- called the same thing as an address is two doors answering to one name.
    for index, bank in ipairs(settings.banks) do
        if addresses[bank.name] then
            note(problems, ("banks[%d].name"):format(index),
                 ("%q is already the address of places[%d]; a branch is a place")
                     :format(tostring(bank.name), addresses[bank.name]))
        else
            addresses[bank.name] = index
        end
    end
    check_unique(problems, "banks", settings.banks, "name")
    check_unique(problems, "shops", settings.shops, "name")
    check_unique(problems, "turfs", settings.turfs, "name")
    check_unique(problems, "fences", settings.fences, "name")

    -- An item that cannot be picked up and cannot be sold is a definition with
    -- no way to reach it. Worth saying, because it is almost always a typo in
    -- `unique` or `stack` rather than an intention.
    for index, item in ipairs(settings.items) do
        if item.unique and item.stack > 1 then
            note(problems, ("items[%d]"):format(index),
                 "cannot be unique and stack at the same time; a unique thing has a stack of 1")
        end
    end

    for index, employer in ipairs(settings.employers) do
        if not is_list(employer.offers) then
            note(problems, ("employers[%d].offers"):format(index),
                 "should be a list of job names, written as { \"delivery\" }")
        else
            for offer_index, offer in ipairs(employer.offers) do
                if type(offer) ~= "string" or offer == "" then
                    note(problems, ("employers[%d].offers[%d]"):format(index, offer_index),
                         "should be a job name")
                end
            end
        end
        -- Refused until something can fund one. An employer that is not
        -- external pays wages from its own account, so every shift there ended
        -- with it unable to pay, held up any other work until it expired
        -- unpaid, and the job board said it was hiring the whole time.
        if employer.external == false then
            note(problems, ("employers[%d].external"):format(index),
                 "cannot be false yet: such an employer pays wages from its own account, and nothing in the city can put money into one, so nobody who works there would be paid")
        end
    end

    for index, shop in ipairs(settings.shops) do
        local path = ("shops[%d]"):format(index)
        if shop.at and not addresses[shop.at] then
            note(problems, path .. ".at",
                 ("%q is not the address of anything in `places`"):format(tostring(shop.at)))
        end
        check_item_map(problems, path .. ".prices", shop.prices, items, "price")
        check_item_map(problems, path .. ".restock", shop.restock, items, "money")
        if type(shop.prices) == "table" and next(shop.prices) == nil then
            note(problems, path .. ".prices", "is empty, so the shop has nothing to trade")
        end
    end

    for index, fence in ipairs(settings.fences) do
        local path = ("fences[%d]"):format(index)
        if fence.at and not addresses[fence.at] then
            note(problems, path .. ".at",
                 ("%q is not the address of anything in `places`"):format(tostring(fence.at)))
        end
        check_item_map(problems, path .. ".pays", fence.pays, items, "money")
    end

    -- A shop that pays more than it charges is refused when it opens, as a
    -- money printer. A fence pays out of the underworld and has no till, so the
    -- same printer through a fence was never looked for: buy water at a shop for
    -- 250, fence it for 300, and go round again. Paying the same is no margin
    -- either, so a fence has to pay less than any shop charges for the thing.
    for index, fence in ipairs(settings.fences) do
        if type(fence.pays) == "table" then
            for item, pays in pairs(fence.pays) do
                for _, shop in ipairs(settings.shops) do
                    local price, charges = nil, nil
                    if type(shop.prices) == "table" then price = shop.prices[item] end
                    if type(price) == "table" then charges = price.buy end
                    if math.type(pays) == "integer" and math.type(charges) == "integer" and pays >= charges then
                        note(problems, ("fences[%d].pays.%s"):format(index, tostring(item)),
                             ("pays %d and %s sells it for %d, which is a money printer: buy it there and fence it here")
                                 :format(pays, tostring(shop.name), charges))
                    end
                end
            end
        end
    end

    table.sort(problems)
    return settings, problems
end

return Settings
