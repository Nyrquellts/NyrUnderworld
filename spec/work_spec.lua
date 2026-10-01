--- The payout is never taken from a completion report. This spec spends most
--- of its time trying to get paid the wrong way.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local Work = require("systems.work")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local MINUTE = Clock.MS_PER_MINUTE

local function build(world)
    world:install(Characters.system())
    world:install(Memory.system())
    world:install(Work.system())
    return world
end

TestWork = {}

function TestWork:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.company = self.world.services.work.employ("Postal OP",
        { external = true, offers = { "delivery", "refuse" } })
    self.bar = self.world.services.work.employ("Tequi-la-la",
        { external = false, offers = { "bartender" } })
    self.world.ledger:transfer("float", "external:mint", "emp:" .. self.bar.id, Money.of(500))
end

function TestWork:tearDown()
    self.world:deactivate()
end

function TestWork:ask(name, args, actor, account, operation_id)
    return self.world:dispatch(name, args,
        { actor = actor or self.jane, account = account or ALICE, operation_id = operation_id })
end

-- --------------------------------------------------------- finding a job

function TestWork:test_a_player_can_find_out_who_is_hiring()
    -- `work.start` takes an employer id and nothing in the city gave a player
    -- one: an employer is external, so it has no address and `me.nearby` can
    -- never name it. Earning worked and could not be reached in ordinary play.
    local out = self:ask("work.list", {})
    lu.assertTrue(out:succeeded())
    lu.assertEquals(#out.value.employers, 2)

    local postal
    for _, row in ipairs(out.value.employers) do
        if row.name == "Postal OP" then postal = row end
    end
    lu.assertNotNil(postal, "the employer that hires is not in the list")
    lu.assertTrue(postal.hiring)
    lu.assertEquals(#postal.jobs, 2)
    lu.assertEquals(postal.jobs[1].job, "delivery")
    lu.assertEquals(postal.jobs[1].pay, 12000)
    lu.assertEquals(postal.jobs[1].minutes, 12)

    -- And the id it hands over is one that clocking on accepts, for the job it
    -- said was on offer.
    lu.assertTrue(self:ask("work.start",
        { employer = postal.employer, job = postal.jobs[1].job }):succeeded())
end

function TestWork:test_the_wait_is_a_number_to_draw_and_not_a_rule()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    self:ask("work.finish", {})

    local out = self:ask("work.list", {})
    local postal
    for _, row in ipairs(out.value.employers) do
        if row.name == "Postal OP" then postal = row end
    end
    local delivery, refuse
    for _, job in ipairs(postal.jobs) do
        if job.job == "delivery" then delivery = job end
        if job.job == "refuse" then refuse = job end
    end
    -- Just clocked off, so delivery is still cooling down and refuse is not.
    lu.assertTrue(delivery.ready_in > 0, "a job just finished says it is ready")
    lu.assertEquals(refuse.ready_in, 0)
    -- The number is drawn. What refuses is work.start.
    lu.assertEquals(self:ask("work.start",
        { employer = self.company.id, job = "delivery" }).code, "too_soon")
    lu.assertTrue(self:ask("work.start",
        { employer = self.company.id, job = "refuse" }):succeeded())
end

function TestWork:test_the_list_says_what_you_are_already_on()
    lu.assertNil(self:ask("work.list", {}).value.working)
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertEquals(self:ask("work.list", {}).value.working, "delivery")
end

function TestWork:test_reading_the_job_board_leaves_nothing_behind()
    -- The board is a read and was not declared one. Every look at it with a
    -- client's token became a receipt written into every save and an answer
    -- held in memory for the life of the server, and a token sent twice was
    -- handed the first answer again however much had changed since.
    for index = 1, 20 do
        lu.assertTrue(self:ask("work.list", {}, nil, nil, "board-" .. index):succeeded())
    end
    lu.assertNil(next(self.world.commands:serialize().completed))

    lu.assertNil(self:ask("work.list", {}, nil, nil, "board").value.working)
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertEquals(self:ask("work.list", {}, nil, nil, "board").value.working, "delivery")
end

function TestWork:test_an_employer_that_stopped_hiring_says_so()
    -- Still in the list, the same way a shut shop is. Being left out of the
    -- answer and being closed are different things and a player can tell.
    local employers = self.world:repository(Work.Employer)
    local shut = employers:load(self.company.id)
    shut:transition("closed", { reason = "spec" })
    employers:save(shut)

    local out = self:ask("work.list", {})
    lu.assertEquals(#out.value.employers, 2)
    for _, row in ipairs(out.value.employers) do
        if row.name == "Postal OP" then lu.assertFalse(row.hiring) end
    end
    lu.assertEquals(self:ask("work.start",
        { employer = self.company.id, job = "delivery" }).code, "not_hiring")
end

function TestWork:test_nobody_reads_the_job_board_for_somebody_else()
    -- No argument naming anybody, so there is no way to ask this about another
    -- person's cooldowns.
    lu.assertNil(self:ask("work.list", { character = self.john }).value)
    lu.assertEquals(self:ask("work.list", { character = self.john }).code, "bad_args")
end

function TestWork:test_clocking_on_opens_a_shift()
    local outcome = self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.minutes, 12)
    local shift = self.world.services.work.open_shift_of(self.jane)
    lu.assertNotNil(shift)
    lu.assertEquals(shift:get("job"), "delivery")
    lu.assertEquals(shift:get("started"), 8 * Clock.MS_PER_HOUR)
end

function TestWork:test_a_client_cannot_say_what_the_job_pays()
    -- There is no payout argument to validate, because there is no payout
    -- argument. A client that invents one is refused before a handler runs.
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    local lying = self:ask("work.finish", { paid = 99999999 })
    lu.assertTrue(lying:was_refused())
    lu.assertEquals(lying.code, "bad_args")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))

    -- and the honest call pays exactly what the server says the job is worth
    local honest = self:ask("work.finish", {})
    lu.assertTrue(honest:succeeded())
    lu.assertEquals(honest.value.paid, 12000)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(620))
end

function TestWork:test_the_command_declares_no_way_to_name_a_payout()
    local described = self.world.commands:describe("work.finish")
    lu.assertEquals(described.args, {})
end

function TestWork:test_you_cannot_be_paid_before_the_work_is_done()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(11 * MINUTE)
    local early = self:ask("work.finish", {})
    lu.assertTrue(early:was_refused())
    lu.assertEquals(early.code, "not_done")
    lu.assertEquals(early.details.minutes, 2)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))
    -- and the shift is still open, not lost
    lu.assertNotNil(self.world.services.work.open_shift_of(self.jane))
end

function TestWork:test_finishing_a_shift_that_was_never_started_pays_nothing()
    local outcome = self:ask("work.finish", {})
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_working")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))
end

function TestWork:test_one_shift_is_paid_once()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    lu.assertTrue(self:ask("work.finish", {}):succeeded())
    local again = self:ask("work.finish", {})
    lu.assertTrue(again:was_refused())
    lu.assertEquals(again.code, "not_working")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(620))
end

function TestWork:test_the_same_request_arriving_twice_pays_once()
    self:ask("work.start", { employer = self.company.id, job = "delivery" }, nil, nil, "start-1")
    self.world.clock:skip(12 * MINUTE)
    local first = self:ask("work.finish", {}, nil, nil, "finish-1")
    local second = self:ask("work.finish", {}, nil, nil, "finish-1")
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(620))
end

function TestWork:test_you_cannot_work_two_shifts_at_once()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    local second = self:ask("work.start", { employer = self.company.id, job = "refuse" })
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "already_working")
end

function TestWork:test_two_people_can_work_at_once_without_touching_each_other()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertTrue(self:ask("work.start", { employer = self.company.id, job = "delivery" },
        self.john, BOB):succeeded())
    self.world.clock:skip(12 * MINUTE)
    lu.assertTrue(self:ask("work.finish", {}):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(620))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(500))
    lu.assertTrue(self:ask("work.finish", {}, self.john, BOB):succeeded())
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.john)), Money.of(620))
end

function TestWork:test_a_cooldown_stops_the_same_job_being_farmed()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    self:ask("work.finish", {})
    local again = self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertTrue(again:was_refused())
    lu.assertEquals(again.code, "too_soon")
    -- another job is free straight away
    lu.assertTrue(self:ask("work.start", { employer = self.company.id, job = "refuse" }):succeeded())
    self:ask("work.abandon", {})
    -- and the cooldown runs out
    self.world.clock:skip(5 * MINUTE)
    lu.assertTrue(self:ask("work.start", { employer = self.company.id, job = "delivery" }):succeeded())
end

function TestWork:test_an_employer_who_cannot_pay_does_not_pay()
    -- The bar holds five hundred; a bartender shift is a hundred and fifty.
    for index = 1, 3 do
        self:ask("work.start", { employer = self.bar.id, job = "bartender" })
        self.world.clock:skip(20 * MINUTE)
        lu.assertTrue(self:ask("work.finish", {}):succeeded())
        self.world.clock:skip(10 * MINUTE)
    end
    lu.assertEquals(self.world.ledger:balance("emp:" .. self.bar.id), Money.of(50))

    self:ask("work.start", { employer = self.bar.id, job = "bartender" })
    self.world.clock:skip(20 * MINUTE)
    local broke = self:ask("work.finish", {})
    lu.assertTrue(broke:was_refused())
    lu.assertEquals(broke.code, "employer_broke")
    -- the bar did not go negative, and the shift is still there to be claimed
    lu.assertEquals(self.world.ledger:balance("emp:" .. self.bar.id), Money.of(50))
    lu.assertNotNil(self.world.services.work.open_shift_of(self.jane))
    lu.assertTrue(self.world:verify())

    -- fund it and the work is not lost
    self.world.ledger:transfer("topup", "external:mint", "emp:" .. self.bar.id, Money.of(200))
    lu.assertTrue(self:ask("work.finish", {}):succeeded())
end

function TestWork:test_an_outside_employer_brings_money_into_the_world_on_the_record()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    self:ask("work.finish", {})
    lu.assertEquals(self.world.ledger:balance("external:payroll"), Money.of(120):negate())
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

function TestWork:test_an_employer_that_does_not_hire_for_it_is_refused()
    lu.assertEquals(self:ask("work.start", { employer = self.company.id, job = "bartender" }).code,
        "not_offered")
    lu.assertEquals(self:ask("work.start", { employer = self.company.id, job = "astronaut" }).code,
        "no_such_job")
    lu.assertEquals(self:ask("work.start", { employer = "emp_000000000000000000a", job = "delivery" }).code,
        "no_such_employer")
    lu.assertEquals(self:ask("work.start", { employer = self.jane, job = "delivery" }).code, "bad_args")
end

function TestWork:test_an_employer_that_shut_takes_nobody_on()
    self.company:transition("closed", { reason = "for the night" })
    self.world:repository(Work.Employer):save(self.company)
    lu.assertEquals(self:ask("work.start", { employer = self.company.id, job = "delivery" }).code,
        "not_hiring")
end

function TestWork:test_walking_off_pays_nothing_and_frees_you_up()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    lu.assertTrue(self:ask("work.abandon", {}):succeeded())
    lu.assertNil(self.world.services.work.open_shift_of(self.jane))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))
    -- no cooldown, because nothing was completed
    lu.assertTrue(self:ask("work.start", { employer = self.company.id, job = "delivery" }):succeeded())
end

function TestWork:test_a_shift_left_open_forever_is_swept_up()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    local expired = {}
    self.world:on("work.expired", function(payload) expired[#expired + 1] = payload end, { label = "spec" })
    for _ = 1, 3 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(#expired, 1)
    lu.assertNil(self.world.services.work.open_shift_of(self.jane))
    -- and the person is free to work again rather than blocked forever
    lu.assertTrue(self:ask("work.start", { employer = self.company.id, job = "refuse" }):succeeded())
end

function TestWork:test_a_finished_shift_goes_on_the_record()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.clock:skip(12 * MINUTE)
    self:ask("work.finish", {})
    local history = self.world.services.recall(self.jane, { kind = "work.shift" })
    lu.assertEquals(#history, 1)
    lu.assertEquals(history[1].meta.job, "delivery")
    lu.assertEquals(history[1].meta.paid, 12000)
    lu.assertEquals(history[1].meta.employer, "Postal OP")
    -- and it is findable from the employer side too
    lu.assertEquals(#self.world.services.recall(self.company.id), 1)
end

function TestWork:test_nobody_can_work_without_being_somebody()
    lu.assertEquals(self.world:dispatch("work.start",
        { employer = self.company.id, job = "delivery" }, { account = ALICE }).code, "not_playing")
    lu.assertEquals(self.world:dispatch("work.finish", {}, { account = ALICE }).code, "not_playing")
end

function TestWork:test_a_job_withdrawn_mid_shift_pays_nothing_rather_than_a_remembered_number()
    self:ask("work.start", { employer = self.company.id, job = "delivery" })
    self.world.services.work.jobs.delivery = nil
    self.world.clock:skip(12 * MINUTE)
    local outcome = self:ask("work.finish", {})
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "job_withdrawn")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.jane)), Money.of(500))
    lu.assertNil(self.world.services.work.open_shift_of(self.jane))
end

function TestWork:test_a_nonsense_job_table_is_caught_at_load()
    lu.assertError(function() return Work.system({ jobs = { Delivery = { label = "x", pay = 1, duration = 1 } } }) end)
    lu.assertError(function() return Work.system({ jobs = { d = { label = "x", pay = 1.5, duration = 1 } } }) end)
    lu.assertError(function() return Work.system({ jobs = { d = { label = "x", pay = -1, duration = 1 } } }) end)
    lu.assertError(function() return Work.system({ jobs = { d = { label = "x", pay = 1, duration = 0 } } }) end)
    lu.assertError(function() return Work.system({ jobs = { d = { pay = 1, duration = 1 } } }) end)
end

function TestWork:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Work.system()) end)
    bare:install(Characters.system())
    lu.assertError(function() return bare:install(Work.system()) end)
end

TestWorkRestart = {}

function TestWorkRestart:setUp()
    for _, name in ipairs({ "world", "chr", "emp", "shf" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestWorkRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestWorkRestart:test_a_shift_in_progress_is_still_in_progress_after_a_restart()
    -- A disconnect two minutes from the end must not cost somebody the shift.
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local company = first.services.work.employ("Postal OP", { external = true, offers = { "delivery" } })
    first:dispatch("work.start", { employer = company.id, job = "delivery" },
        { actor = jane, account = ALICE })
    first.clock:skip(10 * MINUTE)
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local shift = self.world.services.work.open_shift_of(jane)
    lu.assertNotNil(shift)
    lu.assertEquals(shift:get("job"), "delivery")
    -- two minutes short, exactly as it was
    lu.assertEquals(self.world:dispatch("work.finish", {}, { actor = jane, account = ALICE }).code, "not_done")
    self.world.clock:skip(2 * MINUTE)
    local paid = self.world:dispatch("work.finish", {}, { actor = jane, account = ALICE })
    lu.assertTrue(paid:succeeded())
    lu.assertEquals(paid.value.paid, 12000)
    lu.assertTrue(self.world:verify())
end

function TestWorkRestart:test_a_cooldown_survives_a_restart()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    local company = first.services.work.employ("Postal OP", { external = true, offers = { "delivery" } })
    first:dispatch("work.start", { employer = company.id, job = "delivery" },
        { actor = jane, account = ALICE })
    first.clock:skip(12 * MINUTE)
    first:dispatch("work.finish", {}, { actor = jane, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    lu.assertTrue(self.world:load())
    -- restarting the server is not a way to clear a cooldown
    lu.assertEquals(self.world:dispatch("work.start", { employer = company.id, job = "delivery" },
        { actor = jane, account = ALICE }).code, "too_soon")
    self.world.clock:skip(5 * MINUTE)
    lu.assertTrue(self.world:dispatch("work.start", { employer = company.id, job = "delivery" },
        { actor = jane, account = ALICE }):succeeded())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
