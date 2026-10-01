--- Rank is given by somebody who already holds it, and ground is taken with
--- the same compare-and-swap that stops two people buying one flat.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Items = require("domain.items")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local InventorySystem = require("systems.inventory")
local Property = require("systems.property")
local Shops = require("systems.shops")
local Gangs = require("systems.gangs")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"
local CARLA = "license:cccc3333"
local DAN = "license:dddd4444"

local function catalogue()
    local items = Items.catalogue()
    items:define("water", { label = "Bottle of Water", weight = 500, stack = 12, category = "consumable" })
    return items
end

local function build(world, gang_opts)
    world:install(Characters.system({ opening = 0 }))
    world:install(Memory.system())
    world:install(InventorySystem.system({ items = catalogue() }))
    world:install(Property.system())
    world:install(Shops.system())
    world:install(Gangs.system(gang_opts))
    return world
end

TestGangs = {}

function TestGangs:setUp()
    self.world = build(World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR }))
    self.boss = self:person("Jane", "Doe", ALICE)
    self.hand = self:person("John", "Roe", BOB)
    self.kid = self:person("Mary", "Poe", CARLA)
    self.rival = self:person("Paul", "Vane", DAN)
    for _, who in ipairs({ self.boss, self.hand, self.kid, self.rival }) do
        self.world.ledger:transfer("stake-" .. who, "external:mint",
            Characters.wallet(who), Money.of(1000))
    end

    self.crew = self.world.services.gangs.found("The Ballas", "BAL", self.boss)
    self.other = self.world.services.gangs.found("Families", "FAM", self.rival)
    self.block = self.world.services.gangs.draw("Grove Street",
        { x = 1.0, y = 2.0, z = 3.0, radius = 80.0 })

    self.at = {}
    self.world.services.proximity = function(actor, target) return self.at[actor] == target end
    self.gangs = self.world.services.gangs
end

function TestGangs:person(first, last, account)
    local id = self.world:dispatch("character.create",
        { first_name = first, last_name = last }, { account = account }).value
    self.world:dispatch("character.select", { character = id }, { account = account })
    return id
end

function TestGangs:tearDown()
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    local ok, problems = self.world:verify()
    lu.assertTrue(ok, table.concat(problems, "; "))
    self.world:deactivate()
end

function TestGangs:ask(name, args, actor, account)
    return self.world:dispatch(name, args, { actor = actor or self.boss, account = account or ALICE })
end

function TestGangs:recruit(who, account)
    self:ask("gang.invite", { target = who })
    return self:ask("gang.join", { crew = self.crew.id }, who, account)
end

function TestGangs:test_a_founder_is_the_boss_and_has_a_floor_under_their_standing()
    lu.assertEquals(self.gangs.rank_of(self.crew, self.boss), Gangs.BOSS)
    lu.assertEquals(self.gangs.crew_of(self.boss).id, self.crew.id)
    -- being in a crew is a floor, so it does not drift back to stranger
    lu.assertEquals(self.world.services.standing:floor(self.boss, Gangs.party(self.crew.id)), 50)
    self.world.clock:skip(Clock.MS_PER_HOUR * 100)
    lu.assertEquals(self.world.services.standing:score(self.boss, Gangs.party(self.crew.id)), 50)
end

function TestGangs:test_joining_needs_an_invitation()
    -- Without this, joining is a command that puts anybody in anything.
    local outcome = self:ask("gang.join", { crew = self.crew.id }, self.hand, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_invited")
    lu.assertNil(self.gangs.crew_of(self.hand))

    lu.assertTrue(self:recruit(self.hand, BOB):succeeded())
    lu.assertEquals(self.gangs.rank_of(self.gangs.crew_of(self.hand), self.hand), Gangs.MEMBER)
    lu.assertEquals(self.world.services.standing:floor(self.hand, Gangs.party(self.crew.id)), 50)
end

function TestGangs:test_an_invitation_goes_cold()
    self:ask("gang.invite", { target = self.hand })
    self.world.clock:skip(6 * Clock.MS_PER_MINUTE)
    local outcome = self:ask("gang.join", { crew = self.crew.id }, self.hand, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "invitation_lapsed")
end

function TestGangs:test_only_rank_invites()
    self:recruit(self.hand, BOB)
    local outcome = self:ask("gang.invite", { target = self.kid }, self.hand, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "outranked")
end

function TestGangs:test_you_cannot_be_in_two_crews()
    self:recruit(self.hand, BOB)
    self.world:dispatch("gang.invite", { target = self.hand },
        { actor = self.rival, account = DAN })
    local outcome = self.world:dispatch("gang.join", { crew = self.other.id },
        { actor = self.hand, account = BOB })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "already_in_a_crew")
end

function TestGangs:test_nobody_gives_themselves_rank()
    self:recruit(self.hand, BOB)
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })
    -- an officer cannot make themselves boss
    local outcome = self:ask("gang.promote", { target = self.hand, rank = Gangs.BOSS }, self.hand, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_yourself")
end

function TestGangs:test_rank_is_never_given_to_or_above_the_giver()
    -- Without this, one officer promoting another to boss hands the crew away.
    self:recruit(self.hand, BOB)
    self:recruit(self.kid, CARLA)
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })

    local outcome = self:ask("gang.promote", { target = self.kid, rank = Gangs.OFFICER }, self.hand, BOB)
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "outranked")
    lu.assertEquals(self.gangs.rank_of(self.gangs.crew_of(self.kid), self.kid), Gangs.MEMBER)
    -- the boss can, because the boss outranks what is being given
    lu.assertTrue(self:ask("gang.promote", { target = self.kid, rank = Gangs.OFFICER }):succeeded())
end

function TestGangs:test_throwing_somebody_out_takes_the_floor_with_it()
    self:recruit(self.hand, BOB)
    lu.assertTrue(self:ask("gang.kick", { target = self.hand }):succeeded())
    lu.assertNil(self.gangs.crew_of(self.hand))
    -- standing earned inside a crew starts decaying the moment you are outside
    lu.assertEquals(self.world.services.standing:floor(self.hand, Gangs.party(self.crew.id)), 0)
    self.world.clock:skip(Clock.MS_PER_HOUR * 20)
    lu.assertEquals(self.world.services.standing:score(self.hand, Gangs.party(self.crew.id)), 0)
end

function TestGangs:test_you_cannot_throw_out_somebody_who_outranks_you()
    self:recruit(self.hand, BOB)
    self:recruit(self.kid, CARLA)
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })
    lu.assertEquals(self:ask("gang.kick", { target = self.boss }, self.hand, BOB).code, "outranked")
    lu.assertEquals(self:ask("gang.kick", { target = self.kid }, self.kid, CARLA).code, "outranked")
    lu.assertNotNil(self.gangs.crew_of(self.boss))
end

function TestGangs:test_a_boss_hands_it_over_before_leaving()
    self:recruit(self.hand, BOB)
    local outcome = self:ask("gang.leave", {})
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "hand_it_over")
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })
    -- still not enough: the boss is still the boss
    lu.assertEquals(self:ask("gang.leave", {}).code, "hand_it_over")
end

function TestGangs:test_a_boss_can_hand_the_crew_over_and_then_go()
    -- A boss was told to make somebody else boss before leaving, and nothing
    -- could: rank is never given at or above the giver, and nobody is above a
    -- boss. A boss who stopped playing left a crew nobody could run. Handing
    -- it over is a swap in one save, so a crew never has two bosses or none.
    self:recruit(self.hand, BOB)
    self:recruit(self.kid, CARLA)
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })
    -- an officer still cannot make anybody boss
    lu.assertEquals(self:ask("gang.promote", { target = self.kid, rank = Gangs.BOSS }, self.hand, BOB).code,
        "outranked")

    lu.assertTrue(self:ask("gang.promote", { target = self.kid, rank = Gangs.BOSS }):succeeded())
    local roster = self.gangs.crews:load(self.crew.id):get("roster")
    lu.assertEquals(roster[self.kid], Gangs.BOSS)
    lu.assertEquals(roster[self.boss], Gangs.OFFICER)
    lu.assertEquals(roster[self.hand], Gangs.OFFICER)
    local bosses = 0
    for _, rank in pairs(roster) do
        if rank == Gangs.BOSS then bosses = bosses + 1 end
    end
    lu.assertEquals(bosses, 1)

    lu.assertTrue(self:ask("gang.leave", {}):succeeded())
    lu.assertEquals(self.gangs.crews:load(self.crew.id).state, "active")
    lu.assertEquals(self.gangs.crew_of(self.kid).id, self.crew.id)
    -- and the new boss runs it
    lu.assertTrue(self:ask("gang.kick", { target = self.hand }, self.kid, CARLA):succeeded())
end

function TestGangs:test_the_last_one_out_disbands_it()
    lu.assertTrue(self:ask("gang.leave", {}):succeeded())
    lu.assertEquals(self.world.services.gangs.crews:load(self.crew.id).state, "disbanded")
    lu.assertNil(self.gangs.crew_of(self.boss))
end

--- A shop on a block the Ballas hold, with a thousand in its till.
function TestGangs:shop_on_ballas_ground()
    local place = self.world.services.property.build("Corner Shop", { kind = "shop" })
    local shop = self.world.services.shops.open("Corner Shop", place.id,
        { prices = { water = { buy = 250, sell = 100 } }, float = 100000 })
    local ground = self.gangs.draw("Corner", { places = { place.id } })
    self.at[self.boss] = ground.id
    self:ask("gang.claim", { turf = ground.id })
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    lu.assertTrue(self:ask("gang.claim", { turf = ground.id }):succeeded())
    return shop, ground
end

function TestGangs:test_the_last_one_out_takes_the_pot_and_lets_go_of_the_ground()
    -- A crew disbanded with money in the pot and a block under it kept both:
    -- a pot no command could ever reach, and a cut of every till on the block
    -- paid into it every day for good.
    local shop, ground = self:shop_on_ballas_ground()
    self:ask("gang.deposit", { amount = 50000 })
    lu.assertTrue(self:ask("gang.leave", {}):succeeded())
    lu.assertEquals(self.gangs.crews:load(self.crew.id).state, "disbanded")

    -- the pot went to the one who could have taken it out a moment before,
    -- and it is on the record like any other withdrawal
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.zero)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.boss)), Money.of(1000))
    local took = self.world.services.recall(self.boss, { kind = "gang.withdrew" })
    lu.assertEquals(#took, 1)
    lu.assertEquals(took[1].meta.amount, 50000)

    -- the block is nobody's, and nobody takes a cut of that till
    lu.assertEquals(self.gangs.holder_of(ground.id), "state:council")
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.shops.till_of(shop), Money.of(1000))
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.zero)

    -- and another crew can take it from there
    self.at[self.rival] = ground.id
    self:ask("gang.claim", { turf = ground.id }, self.rival, DAN)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    lu.assertTrue(self:ask("gang.claim", { turf = ground.id }, self.rival, DAN):succeeded())
    lu.assertEquals(self.gangs.holder_of(ground.id), Gangs.party(self.other.id))
end

function TestGangs:test_a_crew_that_is_gone_takes_no_tribute()
    -- A city saved before a disbanded crew let go of its ground still has it
    -- holding blocks. Tribute is for a crew that still exists.
    local shop = self:shop_on_ballas_ground()
    local crew = self.gangs.crews:load(self.crew.id)
    crew:transition("disbanded", { reason = "saved before crews let go of their ground" })
    self.gangs.crews:save(crew)
    for _ = 1, 24 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.shops.till_of(shop), Money.of(1000))
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.zero)
end

function TestGangs:test_the_roster_reads_top_down()
    self:recruit(self.hand, BOB)
    self:recruit(self.kid, CARLA)
    self:ask("gang.promote", { target = self.hand, rank = Gangs.OFFICER })
    local outcome = self:ask("gang.roster", {})
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(outcome.value.name, "The Ballas")
    lu.assertEquals(outcome.value.tag, "BAL")
    lu.assertEquals(#outcome.value.members, 3)
    lu.assertEquals(outcome.value.members[1].title, "boss")
    lu.assertEquals(outcome.value.members[2].title, "officer")
    lu.assertEquals(outcome.value.members[3].title, "member")
    lu.assertEquals(self:ask("gang.roster", {}, self.kid, CARLA).value.your_rank, Gangs.MEMBER)
end

-- ------------------------------------------------------------- the treasury

function TestGangs:test_the_treasury_is_a_ledger_account_like_every_other()
    self:recruit(self.hand, BOB)
    lu.assertTrue(self:ask("gang.deposit", { amount = 40000 }, self.hand, BOB):succeeded())
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.of(400))
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(self.hand)), Money.of(600))

    -- a member puts in, an officer takes out
    lu.assertEquals(self:ask("gang.withdraw", { amount = 10000 }, self.hand, BOB).code, "outranked")
    lu.assertTrue(self:ask("gang.withdraw", { amount = 10000 }):succeeded())
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.of(300))
end

function TestGangs:test_a_crew_cannot_spend_what_it_does_not_have()
    self:ask("gang.deposit", { amount = 10000 })
    local outcome = self:ask("gang.withdraw", { amount = 50000 })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "treasury_short")
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.of(100))
    lu.assertFalse(self.gangs.treasury_of(self.crew):is_negative())
end

function TestGangs:test_the_same_withdrawal_twice_takes_it_once()
    self:ask("gang.deposit", { amount = 50000 })
    local first = self.world:dispatch("gang.withdraw", { amount = 20000 },
        { actor = self.boss, account = ALICE, operation_id = "pull-1" })
    local second = self.world:dispatch("gang.withdraw", { amount = 20000 },
        { actor = self.boss, account = ALICE, operation_id = "pull-1" })
    lu.assertTrue(first:succeeded())
    lu.assertTrue(second.details.duplicate)
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.of(300))
end

function TestGangs:test_who_took_what_out_of_the_pot_is_remembered()
    self:ask("gang.deposit", { amount = 50000 })
    self:ask("gang.withdraw", { amount = 20000 })
    local history = self.world.services.recall(self.boss, { kind = "gang.withdrew" })
    lu.assertEquals(#history, 1)
    lu.assertEquals(history[1].meta.amount, 20000)
    lu.assertEquals(history[1].meta.crew, self.crew.id)
end

function TestGangs:test_two_withdrawals_in_one_server_tick_are_both_remembered()
    -- A withdrawal's line was named by crew, person and city millisecond, and
    -- every command between two server ticks shares one. The second of two in
    -- a tick took the money and left no line: a hundred on the record, and the
    -- rest of the pot gone without one.
    self:ask("gang.deposit", { amount = 50000 })
    lu.assertTrue(self:ask("gang.withdraw", { amount = 100 }):succeeded())
    lu.assertTrue(self:ask("gang.withdraw", { amount = 49900 }):succeeded())
    local history = self.world.services.recall(self.boss, { kind = "gang.withdrew" })
    lu.assertEquals(#history, 2)
    lu.assertEquals(history[1].meta.amount, 49900)
    lu.assertEquals(history[2].meta.amount, 100)
end

function TestGangs:test_leaving_and_coming_back_is_remembered_each_time()
    -- Joining was written down under the crew and the person with no time at
    -- all, so coming back was the same join forever; leaving had the city
    -- millisecond, so two in one tick were one.
    for _ = 1, 2 do
        lu.assertTrue(self:recruit(self.hand, BOB):succeeded())
        lu.assertTrue(self:ask("gang.leave", {}, self.hand, BOB):succeeded())
    end
    lu.assertEquals(#self.world.services.recall(self.hand, { kind = "gang.joined" }), 2)
    lu.assertEquals(#self.world.services.recall(self.hand, { kind = "gang.left" }), 2)
end

function TestGangs:test_nobody_outside_a_crew_touches_its_money()
    lu.assertEquals(self:ask("gang.deposit", { amount = 100 }, self.kid, CARLA).code, "no_crew")
    lu.assertEquals(self:ask("gang.withdraw", { amount = 100 }, self.kid, CARLA).code, "no_crew")
    lu.assertEquals(self:ask("gang.roster", {}, self.kid, CARLA).code, "no_crew")
end

-- ------------------------------------------------------------------- turf

function TestGangs:claim(actor, account)
    local first = self:ask("gang.claim", { turf = self.block.id }, actor, account)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    return first, self:ask("gang.claim", { turf = self.block.id }, actor, account)
end

function TestGangs:test_taking_a_block_takes_time_and_then_holds()
    self.at[self.boss] = self.block.id
    local started, finished = self:claim()
    lu.assertEquals(started.code, "working")
    lu.assertEquals(started.details.seconds, 120)
    lu.assertTrue(finished:succeeded())
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.crew.id))
    lu.assertEquals(#self.world.services.recall(self.boss, { kind = "gang.claimed" }), 1)
end

function TestGangs:test_two_crews_finishing_at_once_do_not_both_get_it()
    -- Two calls in a row are not a race: the second one reads the new holder
    -- and takes it over legitimately, which is what test_a_block_can_change
    -- _hands covers. The race is one crew finishing between another crew
    -- reading who holds the block and writing that it now holds it, so it is
    -- staged here rather than hoped for.
    self.at[self.boss] = self.block.id
    self.at[self.rival] = self.block.id
    self:ask("gang.claim", { turf = self.block.id })
    self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)

    local original = self.world.ownership.claim
    self.world.ownership.claim = function(register, operation, asset, party, meta)
        register.claim = original
        -- The Ballas get there first, in the gap.
        original(register, "faster", asset, Gangs.party(self.crew.id), {})
        return original(register, operation, asset, party, meta)
    end

    local loser = self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN)
    lu.assertTrue(loser:was_refused())
    lu.assertEquals(loser.code, "taken_already")
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.crew.id))
    lu.assertTrue(self.world.ownership:verify())
end

function TestGangs:test_two_crews_on_one_block_in_one_millisecond_do_not_collide()
    -- Both operation ids carry the crew. Without that they are the same string,
    -- and the ownership register throws rather than refusing, because one id
    -- cannot mean two different moves. The loser would get a server error
    -- instead of being told somebody was faster.
    self.at[self.boss] = self.block.id
    self.at[self.rival] = self.block.id
    self:ask("gang.claim", { turf = self.block.id })
    self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)

    local first = self:ask("gang.claim", { turf = self.block.id })
    local second = self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN)
    lu.assertTrue(first:succeeded())
    -- Same city millisecond, and neither call is a failure.
    lu.assertFalse(first:is_failure())
    lu.assertFalse(second:is_failure(), tostring(second.message))
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.other.id))
    lu.assertTrue(self.world.ownership:verify())
end

function TestGangs:test_a_block_taken_back_in_the_same_tick_is_not_a_server_error()
    -- With the crew and the millisecond in the id, a block taken by one crew,
    -- taken off them by another and taken back by a second member of the
    -- first, all in one server tick, built the first id again for a different
    -- move, and the register threw.
    self:recruit(self.hand, BOB)
    for _, who in ipairs({ self.boss, self.rival, self.hand }) do self.at[who] = self.block.id end
    self:ask("gang.claim", { turf = self.block.id })
    self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN)
    self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)

    lu.assertTrue(self:ask("gang.claim", { turf = self.block.id }):succeeded())
    lu.assertTrue(self:ask("gang.claim", { turf = self.block.id }, self.rival, DAN):succeeded())
    local back = self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB)
    lu.assertFalse(back:is_failure(), tostring(back.message))
    lu.assertTrue(back:succeeded())
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.crew.id))
    lu.assertEquals(#self.world.services.record:search({ kind = "gang.claimed" }), 3)
    lu.assertEquals(#self.world.ownership:chain(self.block.id), 3)
    lu.assertTrue(self.world.ownership:verify())
end

function TestGangs:test_a_block_can_change_hands()
    self.at[self.boss] = self.block.id
    self.at[self.rival] = self.block.id
    self:claim()
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.crew.id))
    local _, taken = self:claim(self.rival, DAN)
    lu.assertTrue(taken:succeeded())
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.other.id))
    -- and the chain of custody says who had it before
    local chain = self.world.ownership:chain(self.block.id)
    lu.assertEquals(#chain, 2)
    lu.assertEquals(chain[2].from, Gangs.party(self.crew.id))
end

function TestGangs:test_you_have_to_be_standing_on_it()
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }).code, "too_far")
    self.world.services.proximity = nil
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }).code, "no_proximity")
end

function TestGangs:test_you_cannot_take_what_you_already_hold()
    self.at[self.boss] = self.block.id
    self:claim()
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }).code, "already_yours")
end

function TestGangs:test_starting_on_one_block_does_not_finish_another()
    local second = self.gangs.draw("Vespucci Beach")
    self.at[self.boss] = self.block.id
    self:ask("gang.claim", { turf = self.block.id })
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    self.at[self.boss] = second.id
    lu.assertEquals(self:ask("gang.claim", { turf = second.id }).code, "working")
    lu.assertEquals(self.gangs.holder_of(second.id), "state:council")
end

function TestGangs:test_a_claim_started_for_one_crew_does_not_finish_for_its_rival()
    -- A claim was kept by person, not by crew, and leaving did not end it.
    -- Somebody could start taking a block for one crew, walk out, join its
    -- rival and take the block for them on the first press.
    self:recruit(self.hand, BOB)
    self.at[self.hand] = self.block.id
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB).code, "working")
    lu.assertTrue(self:ask("gang.leave", {}, self.hand, BOB):succeeded())
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    self.world:dispatch("gang.invite", { target = self.hand }, { actor = self.rival, account = DAN })
    lu.assertTrue(self:ask("gang.join", { crew = self.other.id }, self.hand, BOB):succeeded())
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB).code, "working")
    lu.assertEquals(self.gangs.holder_of(self.block.id), "state:council")
end

function TestGangs:test_leaving_or_being_thrown_out_ends_a_claim()
    -- Walking out of a crew is walking off the job. Kept, a claim begun before
    -- leaving finished on the first press after coming back.
    self:recruit(self.hand, BOB)
    self.at[self.hand] = self.block.id
    self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB)
    lu.assertTrue(self:ask("gang.leave", {}, self.hand, BOB):succeeded())
    lu.assertTrue(self:recruit(self.hand, BOB):succeeded())
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB).code, "working")

    lu.assertTrue(self:ask("gang.kick", { target = self.hand }):succeeded())
    lu.assertTrue(self:recruit(self.hand, BOB):succeeded())
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB).code, "working")
    lu.assertEquals(self.gangs.holder_of(self.block.id), "state:council")
end

function TestGangs:test_a_claim_is_for_the_crew_it_was_started_for()
    -- However somebody comes to be in another crew -- here, put straight into
    -- its roster -- what they began for the first is not finished for the
    -- second.
    self:recruit(self.hand, BOB)
    self.at[self.hand] = self.block.id
    self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB)
    local ballas, families = self.gangs.crews:load(self.crew.id), self.gangs.crews:load(self.other.id)
    local roster = {}
    for who, rank in pairs(ballas:get("roster")) do
        if who ~= self.hand then roster[who] = rank end
    end
    ballas:set("roster", roster)
    self.gangs.crews:save(ballas)
    roster = { [self.hand] = Gangs.MEMBER }
    for who, rank in pairs(families:get("roster")) do roster[who] = rank end
    families:set("roster", roster)
    self.gangs.crews:save(families)
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.hand, BOB).code, "working")
    lu.assertEquals(self.gangs.holder_of(self.block.id), "state:council")
end

function TestGangs:test_a_claim_nobody_came_back_to_finish_goes_cold()
    -- An attempt was kept for good, so a block begun on hours ago was taken on
    -- one press. Ready for as long again as it took and not finished, it has
    -- been walked away from, and holding it starts over.
    self.at[self.boss] = self.block.id
    self:ask("gang.claim", { turf = self.block.id })
    self.world.clock:skip(4 * Clock.MS_PER_MINUTE)
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }).code, "working")
    lu.assertEquals(self.gangs.holder_of(self.block.id), "state:council")
    -- and one finished inside that still takes it
    self.world.clock:skip(3 * Clock.MS_PER_MINUTE)
    lu.assertTrue(self:ask("gang.claim", { turf = self.block.id }):succeeded())
end

function TestGangs:test_a_cut_of_what_is_made_on_your_ground()
    local place = self.world.services.property.build("Corner Shop", { kind = "shop" })
    local shop = self.world.services.shops.open("Corner Shop", place.id,
        { prices = { water = { buy = 250, sell = 100 } }, float = 100000 })
    local ground = self.gangs.draw("Corner", { places = { place.id } })
    self.at[self.boss] = ground.id
    self:ask("gang.claim", { turf = ground.id })
    self.world.clock:skip(2 * Clock.MS_PER_MINUTE)
    self:ask("gang.claim", { turf = ground.id })
    lu.assertEquals(self.gangs.holder_of(ground.id), Gangs.party(self.crew.id))

    -- Past four in the morning, the next day, and before the six o'clock delivery.
    local hours = 0
    while self.world.clock:calendar().hour ~= 5 and hours < 48 do
        self.world:tick(Clock.MS_PER_HOUR)
        hours = hours + 1
    end
    lu.assertTrue(self.gangs.treasury_of(self.crew):is_positive())
    lu.assertEquals(self.gangs.treasury_of(self.crew), Money.of(100))     -- a tenth of a thousand
    lu.assertEquals(self.world.services.shops.till_of(shop), Money.of(900))

    -- At six the supplier floats the till back up to this shop's own float, as
    -- it does for a robbed till. Until the shop kept its float, every till was
    -- floated to five hundred whatever it was opened with, so a till of nine
    -- hundred was left where tribute put it -- which this test was reading.
    for _ = 1, 2 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.shops.till_of(shop), Money.of(1000))
end

function TestGangs:test_nobody_outside_a_crew_takes_ground()
    self.at[self.kid] = self.block.id
    lu.assertEquals(self:ask("gang.claim", { turf = self.block.id }, self.kid, CARLA).code, "no_crew")
end

function TestGangs:test_the_system_needs_what_it_says_it_needs()
    local bare = World.new({ activate = false })
    lu.assertError(function() return bare:install(Gangs.system()) end)
    lu.assertError(function() return Gangs.system({ tribute_percent = 100 }) end)
end

-- -------------------------------------------------------------- real time

--- The pace config.lua ships: sixty city milliseconds to a real one, and a
--- server tick every real second. Everything above runs at a rate of one, where
--- a real millisecond and a city millisecond are the same number.
TestGangsPace = {}

function TestGangsPace:setUp()
    self.world = build(World.new({ rate = 60, start_at = 8 * Clock.MS_PER_HOUR }))
    self.boss = TestGangs.person(self, "Jane", "Doe", ALICE)
    self.hand = TestGangs.person(self, "John", "Roe", BOB)
    self.kid = TestGangs.person(self, "Mary", "Poe", CARLA)
    self.gangs = self.world.services.gangs
    self.crew = self.gangs.found("The Ballas", "BAL", self.boss)
    self.block = self.gangs.draw("Grove Street")
    self.world.services.proximity = function() return true end
end

function TestGangsPace:tearDown()
    TestGangs.tearDown(self)
end

function TestGangsPace:seconds(count)
    for _ = 1, count do self.world:tick(1000) end
end

function TestGangsPace:test_an_invitation_stands_for_real_minutes()
    -- Five city minutes is five real seconds at the shipped pace: an invitation
    -- had gone cold before anybody could type the command to take it up.
    local B = { actor = self.boss, account = ALICE }
    self.world:dispatch("gang.invite", { target = self.hand }, B)
    self:seconds(60)
    lu.assertTrue(self.world:dispatch("gang.join", { crew = self.crew.id },
        { actor = self.hand, account = BOB }):succeeded())
    -- and five real minutes is still when it goes cold
    self.world:dispatch("gang.invite", { target = self.kid }, B)
    self:seconds(300)
    lu.assertEquals(self.world:dispatch("gang.join", { crew = self.crew.id },
        { actor = self.kid, account = CARLA }).code, "invitation_lapsed")
end

function TestGangsPace:test_taking_a_block_takes_real_minutes()
    -- Two city minutes is two real seconds at the shipped pace, so "Hold it"
    -- was over before anybody had read it, and the wait it gave in seconds was
    -- sixty times the one it kept.
    local B = { actor = self.boss, account = ALICE }
    local first = self.world:dispatch("gang.claim", { turf = self.block.id }, B)
    lu.assertEquals(first.code, "working")
    lu.assertEquals(first.details.seconds, 120)
    self:seconds(60)
    local halfway = self.world:dispatch("gang.claim", { turf = self.block.id }, B)
    lu.assertEquals(halfway.code, "working")
    lu.assertEquals(halfway.details.seconds, 61)
    self:seconds(60)
    lu.assertTrue(self.world:dispatch("gang.claim", { turf = self.block.id }, B):succeeded())
    lu.assertEquals(self.gangs.holder_of(self.block.id), Gangs.party(self.crew.id))
end

function TestGangsPace:test_however_slowly_the_city_runs_an_invitation_is_there_when_given()
    -- Real time turned into city time is rounded up. Rounded down, at a pace
    -- where five real minutes is less than a city millisecond, an invitation
    -- has gone cold at the moment it is made.
    local slow = build(World.new({ rate = 0.000001, start_at = 8 * Clock.MS_PER_HOUR }))
    local boss = TestGangs.person({ world = slow }, "Paul", "Vane", ALICE)
    local hand = TestGangs.person({ world = slow }, "Rick", "Lowe", BOB)
    local crew = slow.services.gangs.found("Families", "FAM", boss)
    slow:dispatch("gang.invite", { target = hand }, { actor = boss, account = ALICE })
    local joined = slow:dispatch("gang.join", { crew = crew.id }, { actor = hand, account = BOB })
    slow:deactivate()
    lu.assertTrue(joined:succeeded(), tostring(joined.code))
end

TestGangsRestart = {}

function TestGangsRestart:setUp()
    for _, name in ipairs({ "world", "chr", "gng", "trf", "prp", "shp" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestGangsRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestGangsRestart:test_a_crew_its_money_and_its_ground_survive_but_an_invitation_does_not()
    local first = build(World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                                    start_at = 8 * Clock.MS_PER_HOUR }))
    local boss = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first:dispatch("character.select", { character = boss }, { account = ALICE })
    local hand = first:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    first.ledger:transfer("stake", "external:mint", Characters.wallet(boss), Money.of(1000))
    local crew = first.services.gangs.found("The Ballas", "BAL", boss)
    local block = first.services.gangs.draw("Grove Street")
    first.services.proximity = function() return true end
    first:dispatch("gang.deposit", { amount = 30000 }, { actor = boss, account = ALICE })
    first:dispatch("gang.claim", { turf = block.id }, { actor = boss, account = ALICE })
    first.clock:skip(2 * Clock.MS_PER_MINUTE)
    first:dispatch("gang.claim", { turf = block.id }, { actor = boss, account = ALICE })
    first:dispatch("gang.invite", { target = hand }, { actor = boss, account = ALICE })
    lu.assertTrue(first:close())

    self.world = build(World.new({ store = FileStore.new({ root = ROOT }) }))
    self.world.services.proximity = function() return true end
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    local gangs = self.world.services.gangs
    lu.assertEquals(gangs.crew_of(boss).id, crew.id)
    lu.assertEquals(gangs.rank_of(gangs.crew_of(boss), boss), Gangs.BOSS)
    lu.assertEquals(gangs.treasury_of(gangs.crews:load(crew.id)), Money.of(300))
    lu.assertEquals(gangs.holder_of(block.id), Gangs.party(crew.id))
    lu.assertEquals(self.world.services.standing:floor(boss, Gangs.party(crew.id)), 50)

    -- an invitation from before the restart is not an invitation
    self.world:dispatch("character.select", { character = hand }, { account = BOB })
    lu.assertEquals(self.world:dispatch("gang.join", { crew = crew.id },
        { actor = hand, account = BOB }).code, "not_invited")
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
