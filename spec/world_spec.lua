--- A whole city, booted, driven for a simulated week and restarted, with no
--- game attached and in a few milliseconds.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Entity = require("domain.entity")
local Id = require("domain.id")
local MemoryStore = require("persistence.memory_store")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"

local Business = Entity.define("biz", {
    fields = {
        name = { type = "string", required = true, max = 48 },
        rent = { type = "money", required = true },
        till = { type = "money", default = Money.zero },
    },
    states = { open = { "shut", "seized" }, shut = { "open" }, seized = { "open" } },
    initial = "open",
})

--- A small system, written the way every later one will be: it asks the world
--- for what it needs, adds commands, listens for events and schedules work.
local Rent = {
    name = "rent",
    install = function(world)
        local businesses = world:repository(Business)

        world:define("business.open", {
            summary = "put a business on the map",
            args = {
                name = { type = "string", required = true, max = 48 },
                rent = { type = "integer", required = true, min = 0 },
                float = { type = "integer", default = 0, min = 0 },
            },
            handler = function(ctx, args)
                local business, why = businesses:create({
                    name = args.name,
                    rent = Money.from_minor(args.rent),
                    till = Money.from_minor(args.float),
                })
                if not business then return ctx.refuse("bad_business", why) end
                if args.float > 0 then
                    ctx.services.ledger:transfer(
                        "float:" .. business.id, "external:mint", "biz:" .. business.id,
                        Money.from_minor(args.float), { reason = "opening float" })
                end
                ctx.services.ownership:claim("open:" .. business.id, business.id, ctx.actor)
                ctx.emit("business.opened", { business = business.id, name = args.name })
                return ctx.ok(business.id)
            end,
        })

        world:define("business.sell", {
            summary = "hand a business to somebody else",
            args = { business = { type = "id", kind = "biz", required = true },
                     buyer = { type = "id", kind = "chr", required = true },
                     price = { type = "integer", required = true, min = 0 } },
            handler = function(ctx, args)
                local seller = ctx.services.ownership:owner_of(args.business)
                if seller ~= ctx.actor then
                    return ctx.refuse("not_yours", "You do not own that.")
                end
                local paid, why = ctx.services.ledger:transfer(
                    ctx.operation_id or ("sale:" .. args.business),
                    "chr:" .. args.buyer, "chr:" .. seller, Money.from_minor(args.price),
                    { reason = "business sale" })
                if not paid then return ctx.refuse("cannot_afford", why) end
                local moved, move_why = ctx.services.ownership:transfer(
                    "sell:" .. args.business .. ":" .. tostring(ctx.operation_id),
                    args.business, seller, args.buyer, { price = args.price })
                if not moved then return ctx.refuse("cannot_transfer", move_why) end
                ctx.emit("business.sold", { business = args.business, from = seller, to = args.buyer })
                return ctx.ok()
            end,
        })

        -- Rent comes out of every open business, every city day, at nine.
        world:daily(9, 0, function()
            for _, business in ipairs(businesses:where(function(b) return b.state == "open" end)) do
                local account = "biz:" .. business.id
                local ok = world.ledger:transfer(
                    ("rent:%s:%d"):format(business.id, world.clock:now()),
                    account, "external:landlord", business:get("rent"), { reason = "rent" })
                if not ok then
                    business:transition("seized", { reason = "unpaid rent" })
                    world.events:emit("business.seized", { business = business.id })
                end
            end
        end, "rent")
    end,
}

local OWNER = Id.from_parts("chr", 1757400000000, 0, 1)
local BUYER = Id.from_parts("chr", 1757400000000, 1, 2)

TestWorld = {}

function TestWorld:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Rent)
    self.businesses = self.world:repository(Business)
end

function TestWorld:tearDown()
    self.world:deactivate()
end

function TestWorld:test_a_world_comes_up_with_everything_wired()
    lu.assertEquals(self.world:systems(), { "rent" })
    lu.assertTrue(self.world:has("rent"))
    lu.assertEquals(self.world.commands:names(), { "business.open", "business.sell" })
    lu.assertEquals(self.world.clock:describe(), "day 0 monday 08:00")
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
end

function TestWorld:test_a_command_changes_the_city_and_says_so()
    local heard = {}
    self.world:on("business.opened", function(payload) heard[#heard + 1] = payload end, { label = "spec" })
    local outcome = self.world:dispatch("business.open",
        { name = "Tequi-la-la", rent = 50000, float = 200000 }, { actor = OWNER })
    lu.assertTrue(outcome:succeeded())

    local business = assert(self.businesses:load(outcome.value))
    lu.assertEquals(business:get("name"), "Tequi-la-la")
    lu.assertEquals(business:get("till"), Money.of(2000))
    lu.assertEquals(business.created_at, 8 * Clock.MS_PER_HOUR)   -- stamped in city time
    lu.assertEquals(self.world.ownership:owner_of(business.id), OWNER)
    lu.assertEquals(self.world.ledger:balance("biz:" .. business.id), Money.of(2000))
    lu.assertEquals(#heard, 1)
    lu.assertEquals(heard[1].name, "Tequi-la-la")
    lu.assertTrue(self.world:verify())
end

function TestWorld:test_the_books_and_the_register_move_together()
    local club = self.world:dispatch("business.open",
        { name = "Vanilla Unicorn", rent = 10000, float = 0 }, { actor = OWNER }).value
    self.world.ledger:transfer("stake", "external:mint", "chr:" .. BUYER, Money.of(5000))

    local sale = self.world:dispatch("business.sell",
        { business = club, buyer = BUYER, price = 300000 },
        { actor = OWNER, operation_id = "sale-1" })
    lu.assertTrue(sale:succeeded())
    lu.assertEquals(self.world.ownership:owner_of(club), BUYER)
    lu.assertEquals(self.world.ledger:balance("chr:" .. BUYER), Money.of(2000))
    lu.assertEquals(self.world.ledger:balance("chr:" .. OWNER), Money.of(3000))
    lu.assertTrue(self.world:verify())

    -- the same sale arriving twice does not sell it twice
    local repeated = self.world:dispatch("business.sell",
        { business = club, buyer = BUYER, price = 300000 },
        { actor = OWNER, operation_id = "sale-1" })
    lu.assertTrue(repeated.details.duplicate)
    lu.assertEquals(self.world.ledger:balance("chr:" .. BUYER), Money.of(2000))
end

function TestWorld:test_a_buyer_who_cannot_pay_gets_nothing()
    local club = self.world:dispatch("business.open",
        { name = "Bahama Mamas", rent = 10000 }, { actor = OWNER }).value
    local sale = self.world:dispatch("business.sell",
        { business = club, buyer = BUYER, price = 300000 }, { actor = OWNER, operation_id = "sale-2" })
    lu.assertTrue(sale:was_refused())
    lu.assertEquals(sale.code, "cannot_afford")
    lu.assertEquals(self.world.ownership:owner_of(club), OWNER)   -- and it did not move
    lu.assertTrue(self.world:verify())
end

function TestWorld:test_somebody_else_cannot_sell_your_bar()
    local club = self.world:dispatch("business.open",
        { name = "Yellow Jack", rent = 10000 }, { actor = OWNER }).value
    local theft = self.world:dispatch("business.sell",
        { business = club, buyer = BUYER, price = 0 }, { actor = BUYER, operation_id = "theft-1" })
    lu.assertTrue(theft:was_refused())
    lu.assertEquals(theft.code, "not_yours")
    lu.assertEquals(self.world.ownership:owner_of(club), OWNER)
end

function TestWorld:test_a_week_of_city_life_runs_in_a_moment()
    local club = self.world:dispatch("business.open",
        { name = "Tequi-la-la", rent = 50000, float = 1000000 }, { actor = OWNER }).value
    local seized = 0
    self.world:on("business.seized", function() seized = seized + 1 end, { label = "spec" })

    -- seven city days, an hour of real time at a time
    for _ = 1, 7 * 24 do
        self.world:tick(Clock.MS_PER_HOUR)
    end

    lu.assertEquals(self.world.clock:describe(), "day 7 monday 08:00")
    -- rent ran on each of the seven mornings at nine: 7 x 500 out of 10,000
    lu.assertEquals(self.world.ledger:balance("biz:" .. club), Money.of(6500))
    lu.assertEquals(self.world.ledger:balance("external:landlord"), Money.of(3500))
    -- money left the city rather than evaporating: the mint is down what it
    -- issued, the landlord holds what was collected, and it all still sums to
    -- nothing
    lu.assertEquals(self.world.ledger:balance("external:mint"), Money.of(10000):negate())
    lu.assertEquals(seized, 0)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(#self.world:errors(), 0)
    lu.assertTrue(self.world:verify())
end

function TestWorld:test_a_business_that_runs_dry_is_seized_rather_than_going_negative()
    local club = self.world:dispatch("business.open",
        { name = "Hen House", rent = 50000, float = 120000 }, { actor = OWNER }).value
    local seized = {}
    self.world:on("business.seized", function(payload) seized[#seized + 1] = payload.business end,
        { label = "spec" })

    for _ = 1, 5 * 24 do self.world:tick(Clock.MS_PER_HOUR) end

    lu.assertEquals(seized, { club })
    lu.assertEquals(self.businesses:load(club).state, "seized")
    -- the till never went below nothing, which is the invariant that matters
    lu.assertEquals(self.world.ledger:balance("biz:" .. club), Money.of(200))
    lu.assertTrue(self.world.ledger:balance("biz:" .. club) >= Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestWorld:test_a_broken_listener_does_not_stop_the_city()
    self.world:on("business.opened", function() error("the phone app is broken") end, { label = "phone" })
    local outcome = self.world:dispatch("business.open", { name = "Pitchers", rent = 1000 }, { actor = OWNER })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#self.world:errors(), 1)
    lu.assertStrContains(self.world:errors()[1].source, "phone")
    lu.assertTrue(self.world:verify())
end

function TestWorld:test_the_same_repository_comes_back_every_time()
    lu.assertIs(self.world:repository(Business), self.businesses)
end

function TestWorld:test_a_system_that_needs_something_missing_is_refused_at_boot()
    lu.assertError(function()
        return self.world:install({ name = "payroll", requires = { "banking" }, install = function() end })
    end)
    lu.assertError(function() return self.world:install(Rent) end)      -- already installed
    lu.assertError(function() return self.world:install({ name = "x" }) end)
    -- and a system that throws while installing leaves no trace
    lu.assertError(function()
        return self.world:install({ name = "broken", install = function() error("nope") end })
    end)
    lu.assertFalse(self.world:has("broken"))
    lu.assertEquals(self.world:systems(), { "rent" })
end

function TestWorld:test_the_summary_reads_as_the_state_of_the_city()
    self.world:dispatch("business.open", { name = "Tequi-la-la", rent = 50000, float = 100 }, { actor = OWNER })
    local summary = self.world:summary()
    lu.assertEquals(summary.entities.biz, 1)
    lu.assertEquals(summary.systems, { "rent" })
    lu.assertEquals(summary.owned, 1)
    lu.assertEquals(summary.errors, 0)
    lu.assertStrContains(summary.at, "monday")
end

-- ------------------------------------------------- and the city, restarted

TestWorldRestart = {}

function TestWorldRestart:setUp()
    for _, name in ipairs({ "world", "biz" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestWorldRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestWorldRestart:test_the_city_remembers_across_a_restart()
    local first = World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                              start_at = 8 * Clock.MS_PER_HOUR })
    first:install(Rent)
    local club = first:dispatch("business.open",
        { name = "Tequi-la-la", rent = 50000, float = 1000000 }, { actor = OWNER }).value
    for _ = 1, 3 * 24 do first:tick(Clock.MS_PER_HOUR) end
    local at_shutdown = first.clock:now()
    local till_at_shutdown = first.ledger:balance("biz:" .. club)
    lu.assertTrue(first:close())

    -- a whole new process, same files
    self.world = World.new({ store = FileStore.new({ root = ROOT }) })
    self.world:install(Rent)
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    lu.assertEquals(self.world.clock:now(), at_shutdown)
    lu.assertEquals(self.world.clock:describe(), "day 3 thursday 08:00")
    lu.assertEquals(self.world.ledger:balance("biz:" .. club), till_at_shutdown)
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(self.world.ownership:owner_of(club), OWNER)

    local business = assert(self.world:repository(Business):load(club))
    lu.assertEquals(business:get("name"), "Tequi-la-la")
    lu.assertEquals(business.state, "open")
    lu.assertTrue(self.world:verify())

    -- and it carries on from where it left off
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.ledger:balance("biz:" .. club), till_at_shutdown:sub(Money.of(500)))
end

function TestWorldRestart:test_a_corrupt_ledger_is_reported_rather_than_loaded()
    local store = MemoryStore.new()
    store:put("world", "ledger", { balances = { ["chr:a"] = 100 } })    -- does not sum to zero
    self.world = World.new({ store = store })
    local ok, problems = self.world:load()
    lu.assertFalse(ok)
    lu.assertStrContains(problems[1], "corrupt")
    lu.assertEquals(self.world.ledger:total(), Money.zero)   -- left at its own empty default
end

TestWorldReleaseSafety = {}

function TestWorldReleaseSafety:tearDown()
    if self.world then self.world:deactivate() end
end

function TestWorldReleaseSafety:test_a_server_world_cannot_overwrite_a_city_it_never_loaded()
    local store = MemoryStore.new()
    local first = World.new({ store = store, activate = false })
    first.ledger:transfer("saved-money", "external:mint", "chr:saved", Money.of(500))
    lu.assertTrue(first:save())
    local saved_ledger = store:get("world", "ledger")
    self.world = World.new({ store = store, require_load = true, rate = 1 })
    lu.assertFalse(self.world:save())
    lu.assertEquals(store:get("world", "ledger"), saved_ledger)
    lu.assertEquals(self.world:tick(1000).city_ms, 0)
    lu.assertEquals(self.world:dispatch("missing.command", {}).code, "city_unavailable")
    lu.assertFalse(self.world:close())
    lu.assertEquals(store:get("world", "ledger"), saved_ledger)
    lu.assertTrue(self.world:load())
    lu.assertEquals(self.world.ledger:balance("chr:saved"), Money.of(500))
    lu.assertTrue(self.world:save())
end

function TestWorldReleaseSafety:test_a_new_server_city_opens_only_after_its_empty_store_is_read()
    self.world = World.new({ store = MemoryStore.new(), require_load = true, rate = 1 })
    lu.assertFalse(self.world:save())
    lu.assertTrue(self.world:load())
    lu.assertTrue(self.world:save())
    lu.assertEquals(self.world:tick(1000).city_ms, 1000)
end

function TestWorldReleaseSafety:test_saved_payment_cannot_buy_property_after_restart()
    local Characters = require("systems.characters")
    local store = MemoryStore.new()
    local function build()
        local world = World.new({ store = store, rate = 1 })
        self.world = world
        world:install(Characters.system())
        world:install(require("systems.memory").system())
        world:install(require("systems.inventory").system())
        world:install(require("systems.property").system())
        world:install(require("systems.banking").system())
        world.services.proximity = function() return true end
        return world
    end
    local world = build()
    local account = "license:receipt_test"
    local character = world:dispatch("character.create", { first_name = "Jane", last_name = "Doe" },
        { account = account }).value
    local meta = { actor = character, account = account, operation_id = "receipt_test/one" }
    local bank = world.services.banking.branch("Bank", { x = 0.0, y = 0.0, z = 0.0, radius = 6.0 })
    local house = world.services.property.build("House", { price = 250000, rent = 0 })
    lu.assertTrue(world:dispatch("bank.open", { branch = bank.id }, { actor = character, account = account }).ok)
    lu.assertTrue(world:dispatch("bank.deposit", { branch = bank.id, amount = 250 }, meta).ok)
    lu.assertTrue(world:save())
    world:deactivate()
    world = build()
    lu.assertTrue(world:load())
    lu.assertEquals(world:dispatch("bank.deposit", { branch = bank.id, amount = 250 }, meta).code, "already_completed")
    lu.assertEquals(world:dispatch("property.buy", { place = house.id }, meta).code, "operation_conflict")
    lu.assertEquals(world.ledger:balance(Characters.wallet(character)):to_minor(), 49750)
    lu.assertNotEquals(world.services.property.holder(house.id), character)
    lu.assertTrue(world:verify())
end

function TestWorldReleaseSafety:test_a_failed_load_blocks_commands_ticks_and_overwriting_the_save()
    local store = MemoryStore.new()
    store:put("world", "ledger", { balances = { broken = 10 } })
    self.world = World.new({ store = store, rate = 1 })
    local announced = 0
    self.world:on("world.loaded", function() announced = announced + 1 end)
    self.world:define("test.mutate", { handler = function() error("must not run") end })
    lu.assertFalse(self.world:load())
    lu.assertEquals(announced, 0)
    lu.assertEquals(self.world:dispatch("test.mutate", {}).code, "city_unavailable")
    local at = self.world.clock:now()
    self.world:tick(1000)
    lu.assertEquals(self.world.clock:now(), at)
    lu.assertFalse(self.world:save())
    lu.assertEquals(store:get("world", "ledger"), { balances = { broken = 10 } })
end

function TestWorldReleaseSafety:test_a_store_read_error_is_a_closed_city_not_an_empty_one()
    local store = MemoryStore.new()
    store.get = function() error("unreadable save") end
    self.world = World.new({ store = store })
    local ok, problems = self.world:load()
    lu.assertFalse(ok)
    lu.assertStrContains(problems[1], "unreadable save")
    lu.assertFalse(self.world:save())
end

function TestWorldReleaseSafety:test_existing_people_without_world_books_do_not_become_a_new_city()
    local Characters = require("systems.characters")
    self.world = World.new()
    self.world:install(Characters.system())
    lu.assertTrue(self.world:dispatch("character.create", { first_name = "Jane", last_name = "Doe" },
        { account = "license:partial" }).ok)
    lu.assertTrue(self.world:save())
    local store = self.world.store
    for _, key in ipairs(store:keys("world")) do store:delete("world", key) end
    self.world:deactivate()
    self.world = World.new({ store = store })
    self.world:install(Characters.system())
    lu.assertFalse(self.world:load())
    lu.assertFalse(self.world:save())
end

function TestWorld:test_a_failed_checkpoint_does_not_flush_a_serialized_subset()
    local opened = self.world:dispatch("business.open",
        { name = "Checkpoint", rent = 1000, float = 1000 }, { actor = OWNER })
    lu.assertTrue(opened.ok)
    local flushes, broken = 0, false
    self.world.store.flush = function() flushes = flushes + 1; return true end
    self.world:persist_with("checkpoint_test", {
        save = function() if broken then error("bad serializer") end; return { n = 1 } end,
        load = function() return true end,
    })
    lu.assertTrue(self.world:save())
    local saved_ledger = self.world.store:get("world", "ledger")
    local saved_business = self.world.store:get("biz", opened.value)
    self.businesses:load(opened.value):set("name", "Changed after checkpoint")
    self.world.ledger:transfer("checkpoint-change", "external:mint", "biz:" .. opened.value, Money.of(10))
    broken = true
    lu.assertFalse(self.world:save())
    lu.assertEquals(flushes, 1)
    lu.assertEquals(self.world.store:get("world", "ledger"), saved_ledger)
    lu.assertEquals(self.world.store:get("biz", opened.value), saved_business)
    broken = false
    lu.assertTrue(self.world:save())
    lu.assertEquals(flushes, 2)
    lu.assertNotEquals(self.world.store:get("world", "ledger"), saved_ledger)
    lu.assertNotEquals(self.world.store:get("biz", opened.value), saved_business)
end

function TestWorld:test_what_passes_validation_is_what_a_save_can_write()
    -- A table field holding keys 1 and "1", or nested past the encoder's
    -- limit, passed validation and failed to encode at flush -- after other
    -- collections had already been written. Measured: a refund reached disk
    -- from a save that answered false, beside a stash from the save before.
    local Schema = require("domain.schema")
    local colliding = { [1] = "a", ["1"] = "b" }
    local ok, why = Schema.check_plain(colliding, "notes")
    lu.assertFalse(ok, "a table two of whose keys write as one passed")
    lu.assertStrContains(why, "notes")
    local deep = {}
    local cursor = deep
    for _ = 1, 70 do cursor.next = {}; cursor = cursor.next end
    lu.assertFalse((Schema.check_plain(deep, "deep")), "nesting the encoder refuses passed")
    lu.assertTrue((Schema.check_plain({ a = { b = { 1, 2, 3 } }, [2] = "x" }, "fine")))
end

function TestWorld:test_a_record_a_save_cannot_write_stops_the_save_before_anything_is_written()
    local opened = self.world:dispatch("business.open",
        { name = "Checkpoint", rent = 1000, float = 1000 }, { actor = OWNER })
    lu.assertTrue(opened.ok)
    lu.assertTrue(self.world:save())
    local saved_ledger = self.world.store:get("world", "ledger")
    local puts = 0
    local put = self.world.store.put
    self.world.store.put = function(store, ...) puts = puts + 1; return put(store, ...) end
    self.world:persist_with("colliding", {
        save = function() return { [1] = "a", ["1"] = "b" } end,
        load = function() return true end,
    })
    self.world.ledger:transfer("after-checkpoint", "external:mint", "biz:" .. opened.value, Money.of(10))
    local saved, failures = self.world:save()
    lu.assertFalse(saved)
    lu.assertStrContains(table.concat(failures, "; "), "colliding")
    lu.assertEquals(puts, 0, "a save that could not be written wrote part of itself")
    lu.assertEquals(self.world.store:get("world", "ledger"), saved_ledger)
end

function TestWorldReleaseSafety:test_an_overlapping_save_cannot_replace_the_checkpoint_in_flight()
    self.world = World.new()
    local store = self.world.store
    store.flush = function() coroutine.yield("awaiting backend"); return true end
    local pending = coroutine.create(function() return self.world:save() end)
    local ran, waiting = coroutine.resume(pending)
    lu.assertTrue(ran)
    lu.assertEquals(waiting, "awaiting backend")
    local checkpoint = store:get("world", "ledger")
    self.world.ledger:transfer("later-command", "external:mint", "chr:later", Money.of(10))
    local ran_second, saved = pcall(self.world.save, self.world)
    lu.assertTrue(ran_second)
    lu.assertFalse(saved)
    lu.assertEquals(store:get("world", "ledger"), checkpoint)
    local completed, ok = coroutine.resume(pending)
    lu.assertTrue(completed)
    lu.assertTrue(ok)
    store.flush = function() return true end
    lu.assertTrue(self.world:save())
    lu.assertNotEquals(store:get("world", "ledger"), checkpoint)
end

function TestWorldReleaseSafety:test_a_store_write_exception_is_reported_and_can_be_retried()
    local store = MemoryStore.new()
    self.world = World.new({ store = store })
    local put = store.put
    store.put = function() error("store cannot accept writes") end
    local ran, saved, failures = pcall(self.world.save, self.world)
    lu.assertTrue(ran)
    lu.assertFalse(saved)
    lu.assertStrContains(failures[1], "store cannot accept writes")
    store.put = put
    lu.assertTrue(self.world:save())
end

function TestWorldReleaseSafety:test_ledger_history_policy_and_archive_callback_survive_restore()
    local store = MemoryStore.new()
    local first = World.new({ store = store, activate = false })
    for n = 1, 3 do first.ledger:transfer("payment" .. n, "external:mint", "chr:a", Money.of(1)) end
    lu.assertTrue(first:save())
    self.world = World.new({ store = store, ledger_history_limit = 2 })
    local archived = 0
    local on_archive = function(rows) archived = archived + #rows end
    self.world.ledger.on_archive = on_archive
    lu.assertTrue(self.world:load())
    lu.assertEquals(self.world.ledger.history_limit, 2)
    lu.assertIs(self.world.ledger.on_archive, on_archive)
    self.world.ledger:transfer("next-payment", "external:mint", "chr:a", Money.of(1))
    lu.assertTrue(archived > 0)
    lu.assertEquals(#self.world.ledger.postings, 2)
end

function TestWorldReleaseSafety:test_repaired_state_requires_a_fresh_world_after_a_failed_load()
    local store = MemoryStore.new()
    local first = World.new({ store = store, activate = false })
    lu.assertTrue(first:save())
    local ledger = store:get("world", "ledger")
    store:put("world", "ledger", { broken = true })
    self.world = World.new({ store = store })
    lu.assertFalse(self.world:load())
    store:put("world", "ledger", ledger)
    lu.assertFalse(self.world:load())
    lu.assertFalse(self.world:save())
    self.world:deactivate()
    self.world = World.new({ store = store, require_load = true })
    lu.assertTrue(self.world:load())
    lu.assertTrue(self.world:save())
end

-- A refusal must not end the save coroutine.
local RefusingStore = {}
RefusingStore.__index = RefusingStore
local function refusing(over)
    return setmetatable({ _real = MemoryStore.new(), _over = over }, RefusingStore)
end
for _, name in ipairs({ "get", "put", "delete", "keys", "each", "count" }) do
    RefusingStore[name] = function(self, collection, ...)
        if collection == self._over then
            error(("the %s collection could not be read; refusing to treat it as empty"):format(collection), 2)
        end
        return self._real[name](self._real, collection, ...)
    end
end
function RefusingStore:collections() return self._real:collections() end
function RefusingStore:flush() return self._real:flush() end

TestWorldAgainstARefusingStore = {}
function TestWorldAgainstARefusingStore:test_saving_reports_the_refusal_and_does_not_throw()
    local world = World.new({ store = refusing("world"), activate = false })
    local ok, failures = world:save()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(failures, " | "), "refusing to treat it as empty")
end
function TestWorldAgainstARefusingStore:test_the_save_can_be_called_again_and_again()
    local store = refusing("world")
    local world = World.new({ store = store, activate = false })
    lu.assertFalse(world:load())
    for _ = 1, 5 do lu.assertFalse(world:save()) end
    lu.assertNil(store._real:get("world", "ledger"))
end
function TestWorldAgainstARefusingStore:test_loading_reports_the_refusal_and_does_not_throw()
    local world = World.new({ store = refusing("world"), activate = false })
    local loaded, problems = world:load()
    lu.assertFalse(loaded)
    lu.assertStrContains(table.concat(problems, " | "), "refusing")
end

function TestWorldAgainstARefusingStore:test_a_refusal_over_one_collection_leaves_the_others_alone()
    local world = World.new({ store = refusing("nothing_real") })
    lu.assertTrue(world:save())
end

-- ------------------------------------------ a city that has not been read

--- A server's world stands for a city already in its store, and until it has
--- read that city it holds the empty one every world starts as. A save that
--- comes first -- the store refused at boot, or the database was still coming
--- up when the save tick fired -- must not write that down.
---
--- The real database store over the spec's SQL, because the defect is in how
--- that store behaves: it reads a collection on first touch and then keeps what
--- it is handed, so saving an unread world loads the real rows and replaces
--- them. A store politer than that passes every test here with the guard gone.
local FakeSql = require("spec.fake_sql")
local DatabaseStore = require("persistence.database_store")

local function world_rows(sql)
    local out = {}
    for key, text in pairs(sql.rows.world or {}) do out[key] = text end
    return out
end

TestAWorldNotYetRead = {}

function TestAWorldNotYetRead:setUp()
    self.made = {}
    -- What a previous run wrote down: a business with a till and an owner, and
    -- six hours on the clock with a day's rent paid out of it.
    self.sql = FakeSql.new()
    local first = self:world()
    assert(first.store:ensure_schema())
    assert(first:load())
    self.club = first:dispatch("business.open",
        { name = "Tequi-la-la", rent = 50000, float = 1000000 }, { actor = OWNER }).value
    for _ = 1, 6 do first:tick(Clock.MS_PER_HOUR) end
    self.till = first.ledger:balance("biz:" .. self.club)
    assert(first:close())
    self.written = world_rows(self.sql)
    -- Not an empty city, or "nothing changed" below would be true of nothing.
    lu.assertStrContains(self.written.ledger, "biz:" .. self.club)
    lu.assertStrContains(self.written.ownership, self.club)
end

function TestAWorldNotYetRead:tearDown()
    for _, world in ipairs(self.made) do world:deactivate() end
end

--- The next process's world over the same database, built the way server.lua
--- builds it.
function TestAWorldNotYetRead:world()
    local world = World.new({ store = DatabaseStore.new({ driver = self.sql }), rate = 1,
                              start_at = 8 * Clock.MS_PER_HOUR, require_load = true })
    world:install(Rent)
    self.made[#self.made + 1] = world
    return world
end

function TestAWorldNotYetRead:test_a_save_before_the_city_is_read_writes_nothing_over_it()
    local world = self:world()
    local statements = self.sql:statement_count()
    local saved, failures = world:save()
    lu.assertFalse(saved)
    lu.assertStrContains(table.concat(failures, " | "), "has not been read")
    -- Not one statement. The refusal has to come before the store is touched,
    -- because touching it is what loads the rows it would then replace.
    lu.assertEquals(self.sql:statement_count(), statements)
    lu.assertEquals(world_rows(self.sql), self.written)
end

function TestAWorldNotYetRead:test_stopping_before_the_city_is_read_writes_nothing_either()
    -- A server stopped while its city is still opening closes the world.
    local world = self:world()
    local statements = self.sql:statement_count()
    local closed, failures = world:close()
    lu.assertFalse(closed)
    lu.assertStrContains(table.concat(failures, " | "), "has not been read")
    lu.assertEquals(self.sql:statement_count(), statements)
    lu.assertEquals(world_rows(self.sql), self.written)
end

function TestAWorldNotYetRead:test_once_it_has_been_read_it_is_written_down_again()
    local world = self:world()
    lu.assertTrue(world:load())
    lu.assertEquals(world.ledger:balance("biz:" .. self.club), self.till)
    local statements = self.sql:statement_count()
    lu.assertTrue(world:save())
    lu.assertTrue(self.sql:statement_count() > statements, "a city that had been read was not written down")
    -- And what went down is the city that was read, byte for byte, because the
    -- encoder sorts its keys. No tick in between: rent that falls due is a change
    -- of its own, and this is about the read, not about the day.
    lu.assertEquals(world_rows(self.sql), self.written)
end

-- ------------------------------------------ the pace is the owner's to choose

TestWorldPace = {}

function TestWorldPace:test_a_restart_keeps_the_city_time_and_takes_the_pace_the_owner_set()
    -- The saved clock came back whole, rate included: an owner who changed
    -- config.lua from 60 to 120 and restarted still had a city at 60, and
    -- nothing said so.
    local store = MemoryStore.new()
    local first = World.new({ store = store, rate = 60 })
    first:tick(90000)
    local saved_at = first.clock:now()
    lu.assertTrue(first:save())

    local second = World.new({ store = store, rate = 120 })
    lu.assertTrue(second:load())
    lu.assertEquals(second.clock:now(), saved_at, "the city's time did not survive the restart")
    lu.assertEquals(second.clock:rate(), 120, "the pace config.lua sets was ignored")

    -- A world built without saying a pace keeps the one it saved with.
    local third = World.new({ store = store })
    lu.assertTrue(third:load())
    lu.assertEquals(third.clock:rate(), 60)
end

-- ------------------------------------------------ a limit is per real minute

TestWorldRateLimits = {}

function TestWorldRateLimits:setUp()
    -- The shipped pace: sixty city milliseconds to every real one.
    self.world = World.new({ rate = 60 })
    self.world:define("shop.shout", { rate = { per_minute = 3 }, handler = function() end })
end

function TestWorldRateLimits:shout()
    return self.world:dispatch("shop.shout", {}, { actor = "chr_a", account = "license:a" }).code
end

function TestWorldRateLimits:test_a_limit_counts_real_time_not_city_time()
    -- Counted in city time, a "minute" at rate 60 was one real second: every
    -- limit let through sixty times what it said, and 1,200 deposits a real
    -- minute reached a handler declared at twenty.
    for _ = 1, 3 do lu.assertEquals(self:shout(), "ok") end
    lu.assertEquals(self:shout(), "too_fast")
    -- One real second is a whole city minute, and it is still one real second.
    self.world:tick(1000)
    lu.assertEquals(self:shout(), "too_fast", "a real second emptied a per-minute window")
    self.world:tick(30000)
    lu.assertEquals(self:shout(), "too_fast")
    self.world:tick(30000)
    lu.assertEquals(self:shout(), "ok", "a real minute later the window should have moved")
end

function TestWorldRateLimits:test_a_paused_city_still_counts_real_minutes()
    self.world.clock:pause()
    for _ = 1, 3 do self:shout() end
    lu.assertEquals(self:shout(), "too_fast")
    self.world:tick(61000)
    lu.assertEquals(self:shout(), "ok", "a paused clock froze every window shut")
end

TestTheServersWorld = {}

function TestTheServersWorld:test_the_server_builds_a_world_that_waits_to_be_read()
    -- Built without `require_load` a world writes itself down from the moment
    -- the resource starts, read or not, and every test above still passes.
    -- `server.lua` cannot be loaded here, so this used to read its text for the
    -- option. The server builds its world with `adapter/city.lua` now
    -- (spec/city_spec.lua holds that it does), and that can be loaded -- so the
    -- world is asked, rather than a file read for a line.
    local City = require("adapter.city")
    local Settings = require("support.settings")
    local settings = Settings.read(require("config"))
    local store = MemoryStore.new()
    local world = City.build(settings, { store = store })

    local saved = world:save()
    lu.assertFalse(saved, "a city that has not been read wrote itself down")
    lu.assertEquals(store:collections(), {})
    lu.assertEquals(world:dispatch("character.list", {}, { account = "license:aaaa1111" }).code,
        "city_unavailable")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
