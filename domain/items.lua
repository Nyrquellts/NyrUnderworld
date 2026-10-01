--- What things are, as opposed to which ones exist.
--
-- A catalogue is the list of kinds of thing: what a bottle of water weighs,
-- how many fit in a stack, whether a passport can be dropped. It holds no
-- instances and no counts. The inventory holds those.
--
-- Deliberately an object rather than a global registry. Two servers, or a spec
-- and the server it is testing, can hold different catalogues without one
-- reaching into the other, and a catalogue can be swapped for a fixture
-- without unloading anything.
--
-- Weight is whole grams, for the same reason money is whole minor units: a
-- carry limit compared against an accumulating float eventually lets somebody
-- carry one more thing than the rule says, and only sometimes.

local Items = {}

local Catalogue = {}
Catalogue.__index = Catalogue

local ID_PATTERN = "^%l[%l%d_]*$"
local ID_MAX = 32
local CATEGORIES = {
    consumable = true, tool = true, weapon = true, material = true,
    document = true, valuable = true, clothing = true, misc = true,
}

Items.CATEGORIES = CATEGORIES
Items.ID_PATTERN = ID_PATTERN

function Items.is_id(value)
    return type(value) == "string" and #value <= ID_MAX and value:match(ID_PATTERN) ~= nil
end

function Items.catalogue()
    return setmetatable({ _items = {}, _order = {} }, Catalogue)
end

--- Declare a kind of thing.
---
---   label      what a person sees
---   weight     whole grams, zero or more
---   stack      how many fit in one slot; 1 means it never stacks
---   unique     every one is its own thing, with an id and its own notes on it
---              (a weapon with a serial, a passport with a name)
---   category   one of Items.CATEGORIES
---   droppable  may be left on the ground; true unless said otherwise
---   sellable   may be sold to a shop; true unless said otherwise
---   illegal    possession is an offence, which police and courts read later
function Catalogue:define(id, spec)
    assert(Items.is_id(id), ("an item id is lowercase letters, digits and underscores; got %s")
        :format(tostring(id)))
    assert(not self._items[id], ("item %s is already defined"):format(id))
    assert(type(spec) == "table", ("item %s needs a definition"):format(id))
    assert(type(spec.label) == "string" and spec.label ~= "", ("item %s needs a label"):format(id))
    local weight = spec.weight or 0
    assert(math.type(weight) == "integer" and weight >= 0,
        ("item %s needs a weight in whole grams"):format(id))
    local stack = spec.stack or 1
    assert(math.type(stack) == "integer" and stack >= 1,
        ("item %s needs a stack size of at least one"):format(id))
    local unique = spec.unique == true
    assert(not (unique and stack > 1),
        ("item %s cannot be unique and stack at the same time"):format(id))
    local category = spec.category or "misc"
    assert(CATEGORIES[category], ("item %s has unknown category %s"):format(id, tostring(category)))

    local item = {
        id = id,
        label = spec.label,
        weight = weight,
        stack = stack,
        unique = unique,
        category = category,
        droppable = spec.droppable ~= false,
        sellable = spec.sellable ~= false,
        illegal = spec.illegal == true,
        description = spec.description,
    }
    self._items[id] = item
    self._order[#self._order + 1] = id
    return item
end

function Catalogue:get(id) return self._items[id] end

function Catalogue:has(id) return self._items[id] ~= nil end

--- Throws rather than returning nil. Every caller inside the simulation is
--- naming an item it declared itself, so a miss is a typo in the server, not
--- something a player did.
function Catalogue:require(id)
    local item = self._items[id]
    if not item then error(("there is no item called %s"):format(tostring(id)), 2) end
    return item
end

function Catalogue:weight(id) return self:require(id).weight end
function Catalogue:stack_size(id) return self:require(id).stack end
function Catalogue:is_unique(id) return self:require(id).unique end

function Catalogue:ids()
    local out = {}
    for _, id in ipairs(self._order) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Catalogue:count()
    return #self._order
end

--- Everything in a category, sorted. What a shop stock list and a crafting
--- menu both ask for.
function Catalogue:in_category(category)
    local out = {}
    for _, id in ipairs(self:ids()) do
        if self._items[id].category == category then out[#out + 1] = id end
    end
    return out
end

--- A plain table, for sending the catalogue to a client once at join rather
--- than answering the same question all evening.
function Catalogue:serialize()
    local out = {}
    for id, item in pairs(self._items) do
        out[id] = {
            label = item.label, weight = item.weight, stack = item.stack,
            unique = item.unique, category = item.category,
            droppable = item.droppable, sellable = item.sellable,
            illegal = item.illegal, description = item.description,
        }
    end
    return out
end

Items.Catalogue = Catalogue

return Items
