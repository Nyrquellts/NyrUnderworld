--- The config an owner typed, and every way they will get it wrong.
--
-- A config error is the first failure a paying server owner meets, and the one
-- they cannot debug by reading the code. So every case here is a real mistake
-- rather than a hypothetical one: a misspelled key, a price on an item that
-- does not exist, a shop in a building nobody built, two things called the
-- same name, a decimal where cents go.
--
-- The two rules being defended:
--   nothing here throws -- a typo is not a stack trace
--   nothing here is repaired -- a bad config does not start a working city
local modname = ...
local lu = require("luaunit")
local Settings = require("support.settings")

local function said(problems, fragment)
    for _, problem in ipairs(problems) do
        if problem:find(fragment, 1, true) then return problem end
    end
    return nil
end

--- The smallest config that is not empty: one item, one address, one shop that
--- trades the item at the address. Everything below breaks one thing in it.
local function a_city(changes)
    local city = {
        items = { { id = "water", label = "Water", weight = 500, stack = 12, category = "consumable" } },
        places = { { address = "Grove Street Corner", kind = "shop", x = 1.0, y = 2.0, z = 3.0 } },
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { water = { buy = 250, sell = 100 } }, float = 5000 } },
    }
    for key, value in pairs(changes or {}) do city[key] = value end
    return city
end

-- --------------------------------------------------------------- the easy road

TestSettingsDefaults = {}

function TestSettingsDefaults:test_no_config_at_all_is_a_city_with_nothing_in_it_and_no_complaint()
    -- An owner who deletes the file gets defaults and a running server, not an
    -- error. There is nothing in the city, which is a choice they can see.
    local settings, problems = Settings.read(nil)
    lu.assertEquals(problems, {})
    lu.assertEquals(settings.city.rate, 60)
    lu.assertEquals(settings.items, {})
    lu.assertEquals(settings.shops, {})
end

function TestSettingsDefaults:test_the_timings_have_defaults_and_an_owner_may_change_them()
    local settings = Settings.read({ city = { rate = 120 } })
    lu.assertEquals(settings.city.rate, 120)
    lu.assertEquals(settings.city.tick_ms, 1000)      -- untouched, still default
    lu.assertEquals(settings.city.save_ms, 60000)
    lu.assertEquals(settings.city.witness_range, 25.0)
end

function TestSettingsDefaults:test_an_item_gets_the_defaults_that_make_it_an_ordinary_thing()
    local settings = Settings.read({ items = { { id = "rock", label = "Rock" } } })
    local rock = settings.items[1]
    lu.assertEquals(rock.weight, 0)
    lu.assertEquals(rock.stack, 1)
    lu.assertEquals(rock.category, "misc")
    lu.assertTrue(rock.droppable)
    lu.assertTrue(rock.sellable)
    lu.assertFalse(rock.illegal)
    lu.assertFalse(rock.unique)
end

function TestSettingsDefaults:test_the_shipped_config_is_a_city_with_no_problems_in_it()
    -- The file that ships is the first thing an owner reads and the example
    -- they copy. If it does not pass its own checker, nothing else here means
    -- anything.
    local ok, raw = pcall(dofile, "config.lua")
    lu.assertTrue(ok, "config.lua should load: " .. tostring(raw))
    local settings, problems = Settings.read(raw)
    lu.assertEquals(problems, {})
    lu.assertTrue(#settings.items > 0)
    lu.assertTrue(#settings.shops > 0)
end

-- ------------------------------------------------------------ typos and shapes

TestSettingsTypos = {}

function TestSettingsTypos:test_a_section_that_is_not_a_section_is_named_with_the_ones_that_are()
    local _, problems = Settings.read({ shopps = {} })
    local complaint = said(problems, "shopps")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "is not a section")
    -- Told what the sections are, so the fix does not need the source.
    lu.assertStrContains(complaint, "shops")
end

function TestSettingsTypos:test_a_misspelled_field_is_refused_rather_than_ignored()
    -- The worst config failure: everything looks fine and the setting does
    -- nothing. `wieght` is a real typo somebody will make.
    local _, problems = Settings.read({ items = { { id = "rock", label = "Rock", wieght = 500 } } })
    lu.assertNotNil(said(problems, "items[1]"))
    lu.assertNotNil(said(problems, "wieght"))
end

function TestSettingsTypos:test_a_section_written_as_one_entry_instead_of_a_list_says_so()
    -- Forgetting the outer braces is the most common shape mistake there is.
    local _, problems = Settings.read({ items = { id = "rock", label = "Rock" } })
    local complaint = said(problems, "items:")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "list of entries")
end

function TestSettingsTypos:test_a_missing_name_is_named_with_its_position()
    local _, problems = Settings.read({ employers = { { external = true } } })
    local complaint = said(problems, "employers[1]")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "name is required")
end

function TestSettingsTypos:test_a_category_that_does_not_exist_lists_the_ones_that_do()
    local _, problems = Settings.read({
        items = { { id = "rock", label = "Rock", category = "rocks" } } })
    local complaint = said(problems, "items[1]")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "consumable")
end

function TestSettingsTypos:test_an_item_id_with_a_capital_in_it_is_refused()
    local _, problems = Settings.read({ items = { { id = "Water", label = "Water" } } })
    lu.assertNotNil(said(problems, "lowercase"))
end

function TestSettingsTypos:test_nothing_throws_however_wrong_the_config_is()
    for _, nonsense in ipairs({
        { items = 42 },
        { items = { 42 } },
        { city = "fast" },
        { shops = { { name = "x", at = "y", prices = "cheap" } } },
        { places = { { address = {} } } },
        { employers = { { name = "x", offers = "delivery" } } },
    }) do
        local ok, _, problems = pcall(Settings.read, nonsense)
        lu.assertTrue(ok, "Settings.read should not throw")
    end
    -- And a config that is not even a table.
    local _, problems = Settings.read("not a table")
    lu.assertNotNil(said(problems, "should return a table"))
end

-- ------------------------------------------------------ things that disagree

TestSettingsAgreement = {}

function TestSettingsAgreement:test_a_price_on_an_item_that_does_not_exist_is_caught()
    -- `wtaer` is a shop that silently sells nothing, and looks perfect.
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { wtaer = { buy = 250 } } } },
    }))
    local complaint = said(problems, "shops[1].prices.wtaer")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "not in `items`")
end

function TestSettingsAgreement:test_a_shop_at_an_address_nobody_built_is_caught()
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Groove Street Corner",
                    prices = { water = { buy = 250 } } } },
    }))
    local complaint = said(problems, "shops[1].at")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "not the address of anything")
end

function TestSettingsAgreement:test_a_fence_paying_for_something_that_does_not_exist_is_caught()
    local _, problems = Settings.read(a_city({
        fences = { { name = "Nobody's", at = "Grove Street Corner", pays = { gold = 4000 } } },
    }))
    lu.assertNotNil(said(problems, "fences[1].pays.gold"))
end

--- The corner shop sells water for 250; a fence at the same corner pays this.
local function fence_paying(water, shop_prices)
    local changes = { fences = { { name = "Nobody's", at = "Grove Street Corner", pays = { water = water } } } }
    if shop_prices then
        changes.shops = { { name = "The Corner", at = "Grove Street Corner", prices = shop_prices } }
    end
    return select(2, Settings.read(a_city(changes)))
end

function TestSettingsAgreement:test_a_fence_that_pays_what_a_shop_charges_is_a_money_printer()
    -- A shop that pays more than it charges is refused when it opens. A fence
    -- pays out of the underworld and has no till, so the same printer through a
    -- fence was never looked for: buy water at 250, fence it at 300, repeat.
    local complaint = said(fence_paying(300), "fences[1].pays.water")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "The Corner")
    lu.assertStrContains(complaint, "money printer")
    -- the same money back is no margin for the fence to take
    lu.assertNotNil(said(fence_paying(250), "fences[1].pays.water"))
    -- and less than the shop charges is a fence doing its job
    lu.assertEquals(fence_paying(249), {})
end

function TestSettingsAgreement:test_a_fence_may_pay_more_than_a_shop_that_only_buys_it()
    -- A shop that buys water and sells none is not a place to buy it cheap.
    lu.assertEquals(fence_paying(5000, { water = { sell = 100 } }), {})
end

function TestSettingsAgreement:test_a_price_written_as_pounds_and_pence_is_caught()
    -- 2.50 is the mistake that costs real money: it would be two cents and a
    -- half, and the half does not exist.
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { water = { buy = 2.50 } } } },
    }))
    local complaint = said(problems, "shops[1].prices.water.buy")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "whole number of cents")
end

function TestSettingsAgreement:test_a_price_that_is_neither_buy_nor_sell_is_caught()
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { water = { cost = 250 } } } },
    }))
    lu.assertNotNil(said(problems, "shops[1].prices.water.cost"))
end

function TestSettingsAgreement:test_an_item_in_a_shop_with_no_price_at_all_is_caught()
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { water = {} } } },
    }))
    lu.assertNotNil(said(problems, "neither a `buy` nor a `sell`"))
end

function TestSettingsAgreement:test_a_shop_that_trades_nothing_is_caught()
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner", prices = {} } },
    }))
    lu.assertNotNil(said(problems, "nothing to trade"))
end

function TestSettingsAgreement:test_two_items_with_one_id_are_caught_and_both_are_named()
    local _, problems = Settings.read({
        items = { { id = "water", label = "Water" }, { id = "water", label = "Also Water" } } })
    local complaint = said(problems, "items[2].id")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "items[1]")
end

function TestSettingsAgreement:test_two_addresses_the_same_are_caught_because_a_shop_could_mean_either()
    local _, problems = Settings.read({
        places = { { address = "Grove Street" }, { address = "Grove Street" } } })
    lu.assertNotNil(said(problems, "places[2].address"))
end

function TestSettingsAgreement:test_a_unique_item_that_also_stacks_is_caught()
    local _, problems = Settings.read({
        items = { { id = "phone", label = "Phone", unique = true, stack = 6 } } })
    lu.assertNotNil(said(problems, "unique and stack"))
end

function TestSettingsAgreement:test_a_job_list_written_as_one_job_is_caught()
    local _, problems = Settings.read({
        employers = { { name = "Postal OP", offers = { delivery = true } } } })
    lu.assertNotNil(said(problems, "employers[1].offers"))
end

function TestSettingsAgreement:test_an_employer_nothing_can_pay_is_refused()
    -- An employer that is not external pays wages from its own account, and
    -- nothing in the city can put money into one. Every shift there ended with
    -- the employer unable to pay, held up any other work until it expired
    -- unpaid, and the board said it was hiring the whole time.
    local _, problems = Settings.read({
        employers = { { name = "Tequi-la-la", external = false, offers = { "bartender" } } } })
    local complaint = said(problems, "employers[1].external")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "nothing in the city can put money into")
    -- an outside employer is what there is, written out or left to the default
    lu.assertEquals(select(2, Settings.read({
        employers = { { name = "Postal OP", external = true, offers = { "delivery" } } } })), {})
    lu.assertEquals(select(2, Settings.read({
        employers = { { name = "Postal OP", offers = { "delivery" } } } })), {})
end

function TestSettingsAgreement:test_a_bank_named_after_an_address_is_caught()
    -- A branch is built as a place whose address is the bank's name, so these
    -- are one namespace however separate the two lists look.
    local _, problems = Settings.read({
        places = { { address = "Legion Square" } },
        banks = { { name = "Legion Square" } },
    })
    local complaint = said(problems, "banks[1].name")
    lu.assertNotNil(complaint)
    lu.assertStrContains(complaint, "places[1]")
end

function TestSettingsAgreement:test_a_shop_may_sit_at_a_bank_because_a_branch_is_a_place()
    local _, problems = Settings.read({
        items = { { id = "water", label = "Water" } },
        banks = { { name = "Pillbox Hill Branch" } },
        shops = { { name = "Lobby Kiosk", at = "Pillbox Hill Branch",
                    prices = { water = { buy = 250 } } } },
    })
    lu.assertEquals(problems, {})
end

-- --------------------------------------------------------- all of them at once

TestSettingsReporting = {}

function TestSettingsReporting:test_four_mistakes_cost_one_restart_not_four()
    local _, problems = Settings.read({
        items = { { id = "water", label = "Water" }, { id = "water", label = "Water" } },
        employers = { { external = true } },
        shops = { { name = "The Corner", at = "nowhere", prices = { fish = { buy = 1 } } } },
        srops = {},
    })
    lu.assertTrue(#problems >= 4,
        ("expected every problem at once, got %d: %s"):format(#problems, table.concat(problems, " | ")))
    lu.assertNotNil(said(problems, "items[2].id"))
    lu.assertNotNil(said(problems, "employers[1]"))
    lu.assertNotNil(said(problems, "shops[1].at"))
    lu.assertNotNil(said(problems, "srops"))
end

function TestSettingsReporting:test_the_problems_come_back_in_a_stable_order()
    local first = select(2, Settings.read({ items = { { id = "a" }, { id = "b" } } }))
    for _ = 1, 5 do
        lu.assertEquals(select(2, Settings.read({ items = { { id = "a" }, { id = "b" } } })), first)
    end
end

function TestSettingsReporting:test_every_problem_carries_the_path_to_what_is_wrong()
    local _, problems = Settings.read(a_city({
        shops = { { name = "The Corner", at = "Grove Street Corner",
                    prices = { water = { buy = -1 } } } },
    }))
    for _, problem in ipairs(problems) do
        lu.assertStrContains(problem, ": ", "a problem without a path is not actionable")
    end
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
