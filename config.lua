--- Your city.
--
-- Everything a server owner is meant to change is here, and nothing that is a
-- rule is. Edit this file, restart the resource, and the city is yours: your
-- items, your jobs, your addresses, your prices, your blocks.
--
-- The whole file is checked before any of it is built. If something is wrong
-- the server does not start a half-configured city -- it prints every problem
-- with the path to each, so four mistakes cost one restart rather than four.
--
-- Money is always whole cents, everywhere, with no exceptions: 250 is $2.50.
-- A decimal in a price is the one mistake that would quietly cost somebody
-- money, so there are no decimals anywhere in this file.
--
-- Only what is already in the city on a first boot is here. These are seeds: a
-- city that has already been played keeps what it has, and adding an entry
-- adds it at the next start without touching anything that exists.

return {

    -- ---------------------------------------------------------------- time

    city = {
        rate = 60,              -- city milliseconds per real millisecond; 60 makes a day 24 real minutes
        tick_ms = 1000,         -- real milliseconds between ticks
        save_ms = 60000,        -- how often the city is written down
        witness_range = 25.0,   -- how close somebody must be to have seen it, in metres
    },

    -- --------------------------------------------------------------- items
    --
    -- category  consumable, tool, weapon, material, document, valuable,
    --           clothing, misc
    -- weight    whole grams
    -- stack     how many fit in one slot; 1 never stacks
    -- unique    every one is its own thing, with its own id and its own notes
    --           (a weapon with a serial, a passport with a name)
    -- illegal   possession is an offence, which police and courts read later

    items = {
        { id = "water",    label = "Bottle of Water", weight = 500,  stack = 12, category = "consumable" },
        { id = "burger",   label = "Burger",          weight = 250,  stack = 6,  category = "consumable" },
        { id = "bandage",  label = "Bandage",         weight = 100,  stack = 10, category = "consumable" },
        { id = "phone",    label = "Phone",           weight = 200,  unique = true, category = "tool" },
        { id = "lockpick", label = "Lockpick",        weight = 150,  stack = 4,  category = "tool",
          illegal = true },
        { id = "scrap",    label = "Scrap Metal",     weight = 2000, stack = 20, category = "material" },
        { id = "watch",    label = "Gold Watch",      weight = 200,  stack = 5,  category = "valuable",
          illegal = true },
        { id = "passport", label = "Passport",        weight = 30,   unique = true, category = "document",
          droppable = false, sellable = false },
    },

    -- ------------------------------------------------------------- the work
    --
    -- `external` means the employer is part of the world rather than something
    -- a player founded, and pays its wages from outside the city. It must be
    -- true for now: nothing in the city can fund a player-run employer yet, so
    -- `external = false` is refused at start rather than hiring people it can
    -- never pay. `offers` names the kinds of shift they hand out.

    employers = {
        { name = "Postal OP",     external = true, offers = { "delivery" } },
        { name = "Sanitation LS", external = true, offers = { "refuse" } },
    },

    -- ------------------------------------------------------------ addresses
    --
    -- Every door in the city is a place, including the ones that are shops and
    -- banks: same entity, same coordinates, same proximity check. `radius` is
    -- how close somebody stands to be at it.

    places = {
        -- z is 38 and not 89. 89 is where the flat is in the game's own world,
        -- up inside the Integrity Way interior, and on a server with nothing
        -- that opens that interior a player cannot get there: put at 89 they
        -- fall to the street, and `me.nearby` is then correctly certain that
        -- nothing is within four metres of a door fifty-one metres up. So the
        -- address sits at the entrance, where somebody can stand. Measured,
        -- not guessed -- asked for 40 at this x and y, landed at 38.
        --
        -- A server that does open the interior should put this back to 89.
        { address = "Integrity Way, Apt 28", kind = "apartment", price = 250000, rent = 5000,
          x = -47.0, y = -589.0, z = 38.0, radius = 4.0 },
        { address = "Alta Street, Apt 57", kind = "apartment", price = 320000, rent = 6500,
          x = -269.0, y = -955.0, z = 31.0, radius = 4.0 },
        { address = "Rob's Liquor, Grove Street", kind = "shop", price = 0, rent = 0,
          x = -47.0, y = -1757.0, z = 29.0, radius = 6.0 },
        { address = "Cypress Flats Scrapyard", kind = "shop", price = 0, rent = 0,
          x = 1180.0, y = -1250.0, z = 35.0, radius = 25.0 },
    },

    -- ---------------------------------------------------------------- banks

    banks = {
        { name = "Pillbox Hill Branch", x = 149.0, y = -1040.0, z = 29.0, radius = 6.0 },
        { name = "Legion Square Branch", x = 241.0, y = 220.0,   z = 106.0, radius = 6.0 },
    },

    -- ---------------------------------------------------------------- shops
    --
    -- `at` is the address of a place above. `buy` is what a person pays to
    -- take one; `sell` is what the shop pays to take one in. An item with only
    -- a `sell` is bought by the shop and never stocked. `restock` is how many
    -- of each come back on a delivery, and `float` is the cash the till starts
    -- with -- a shop with no float cannot buy anything from anybody.

    shops = {
        {
            name = "Rob's Liquor",
            at = "Rob's Liquor, Grove Street",
            prices = {
                water   = { buy = 250,  sell = 100 },
                burger  = { buy = 400,  sell = 150 },
                bandage = { buy = 1200, sell = 400 },
                scrap   = { sell = 900 },   -- taken in, never sold: a corner shop buys scrap
            },
            restock = { water = 60, burger = 40, bandage = 25 },
            float = 50000,
        },
    },

    -- ---------------------------------------------------------------- turf
    --
    -- A block a crew can hold. `radius` is in metres, and these are large on
    -- purpose: turf is a neighbourhood, not a doorway.

    turfs = {
        { name = "Grove Street",    x = 90.0,    y = -1930.0, z = 21.0, radius = 90.0 },
        { name = "Vespucci Beach",  x = -1200.0, y = -1560.0, z = 4.0,  radius = 120.0 },
    },

    -- --------------------------------------------------------------- fences
    --
    -- Somebody who asks no questions. `pays` is what they hand over per item,
    -- in cents, and it is deliberately less than a shop would pay for the
    -- same thing if the shop would take it at all. `chops` means they take
    -- vehicles too.

    fences = {
        {
            name = "Nobody's",
            at = "Cypress Flats Scrapyard",
            pays = { watch = 4000, scrap = 300 },
            chops = true,
        },
    },
}
