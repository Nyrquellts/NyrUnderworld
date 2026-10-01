--- One asset, one owner. The register has to make duplication impossible
--- rather than unlikely.
local modname = ...
local lu = require("luaunit")
local Id = require("domain.id")
local Ownership = require("domain.ownership")

local CAR = Id.from_parts("veh", 1757500000000, 0, 1)
local BIKE = Id.from_parts("veh", 1757500000000, 1, 2)
local ALICE = Id.from_parts("chr", 1757400000000, 0, 3)
local BOB = Id.from_parts("chr", 1757400000000, 1, 4)
local CARLA = Id.from_parts("chr", 1757400000000, 2, 5)

TestOwnership = {}

function TestOwnership:setUp()
    self.tick = 1757500000000
    self.register = Ownership.new({ clock = function()
        self.tick = self.tick + 1
        return self.tick
    end })
    self.register:claim("mint-car", CAR, ALICE)
end

function TestOwnership:test_a_claimed_asset_has_exactly_one_owner()
    lu.assertEquals(self.register:owner_of(CAR), ALICE)
    lu.assertEquals(self.register:assets_of(ALICE), { CAR })
    lu.assertEquals(self.register:assets_of(BOB), {})
    lu.assertEquals(self.register:count(), 1)
end

function TestOwnership:test_an_owned_asset_cannot_be_claimed_again()
    local ok, err = self.register:claim("mint-car-again", CAR, BOB)
    lu.assertFalse(ok)
    lu.assertStrContains(err, "already owned")
    lu.assertEquals(self.register:owner_of(CAR), ALICE)
end

function TestOwnership:test_a_transfer_moves_it_and_moves_the_index()
    lu.assertTrue(self.register:transfer("sale-1", CAR, ALICE, BOB))
    lu.assertEquals(self.register:owner_of(CAR), BOB)
    lu.assertEquals(self.register:assets_of(BOB), { CAR })
    lu.assertEquals(self.register:assets_of(ALICE), {})   -- and the old owner lost it
    lu.assertTrue(self.register:verify())
end

function TestOwnership:test_two_transfers_of_one_car_cannot_both_win()
    -- The duplication bug, staged: two clients each believe Alice holds the
    -- car and each try to take it in the same tick.
    local first = self.register:transfer("sale-a", CAR, ALICE, BOB)
    local second, err = self.register:transfer("sale-b", CAR, ALICE, CARLA)
    lu.assertTrue(first)
    lu.assertFalse(second)
    lu.assertStrContains(err, "is owned by")
    -- exactly one owner, and the loser got nothing
    lu.assertEquals(self.register:owner_of(CAR), BOB)
    lu.assertEquals(self.register:assets_of(CARLA), {})
    lu.assertEquals(self.register:count(), 1)
    lu.assertTrue(self.register:verify())
end

function TestOwnership:test_a_stale_belief_about_the_owner_is_refused()
    self.register:transfer("sale-1", CAR, ALICE, BOB)
    local ok, err = self.register:transfer("sale-2", CAR, ALICE, CARLA)
    lu.assertFalse(ok)
    lu.assertStrContains(err, BOB)
    lu.assertEquals(self.register:owner_of(CAR), BOB)
end

function TestOwnership:test_transferring_to_the_current_owner_is_refused()
    local ok, err = self.register:transfer("noop", CAR, ALICE, ALICE)
    lu.assertFalse(ok)
    lu.assertStrContains(err, "already belongs")
end

function TestOwnership:test_an_unowned_asset_cannot_be_transferred()
    local ok, err = self.register:transfer("ghost", BIKE, ALICE, BOB)
    lu.assertFalse(ok)
    lu.assertStrContains(err, "no owner")
    lu.assertNil(self.register:owner_of(BIKE))
end

function TestOwnership:test_the_same_operation_applied_twice_moves_it_once()
    lu.assertTrue(self.register:transfer("sale-1", CAR, ALICE, BOB))
    local ok, _, info = self.register:transfer("sale-1", CAR, ALICE, BOB)
    lu.assertTrue(ok)
    lu.assertTrue(info.duplicate)
    lu.assertEquals(self.register:owner_of(CAR), BOB)
    lu.assertEquals(#self.register:chain(CAR), 2)   -- claim, then one transfer
end

function TestOwnership:test_one_operation_id_cannot_mean_two_different_moves()
    self.register:transfer("sale-1", CAR, ALICE, BOB)
    lu.assertErrorMsgContains("already applied", function()
        return self.register:transfer("sale-1", CAR, BOB, CARLA)
    end)
end

function TestOwnership:test_a_refusal_is_not_remembered()
    -- A refused change moved nothing, so its operation id is still free. It
    -- was kept, and the same id with other arguments raised "already applied"
    -- where it should have been answered.
    lu.assertFalse(self.register:transfer("sale-1", CAR, BOB, CARLA))       -- Alice holds it
    lu.assertTrue(self.register:transfer("sale-1", CAR, ALICE, BOB))
    lu.assertFalse(self.register:release("scrap", CAR, ALICE))              -- Bob holds it now
    lu.assertTrue(self.register:release("scrap", CAR, BOB))
    lu.assertNil(self.register:owner_of(CAR))
    lu.assertTrue(self.register:verify())
end

function TestOwnership:test_a_refusal_tried_again_once_it_would_work_does_the_work()
    lu.assertFalse(self.register:claim("mint", CAR, BOB))                   -- already owned
    lu.assertTrue(self.register:release("scrap", CAR, ALICE))
    local ok, _, info = self.register:claim("mint", CAR, BOB)
    lu.assertTrue(ok)
    lu.assertNil(info, "a retry was answered as a duplicate of a refusal")
    lu.assertEquals(self.register:owner_of(CAR), BOB)
end

function TestOwnership:test_only_the_most_recent_changes_are_remembered()
    -- In memory only, never written down, so a restart already forgets them;
    -- kept without end they grew with every change the city ever made.
    local register = Ownership.new({ applied_limit = 2 })
    lu.assertTrue(register:claim("c1", CAR, ALICE))
    lu.assertTrue(register:transfer("t1", CAR, ALICE, BOB))
    lu.assertTrue(register:transfer("t2", CAR, BOB, CARLA))
    local ok, _, info = register:transfer("t2", CAR, BOB, CARLA)
    lu.assertTrue(ok)
    lu.assertTrue(info ~= nil and info.duplicate, "the newest change was forgotten")

    -- The oldest is a new request again, and answered as one.
    local again, why, first = register:claim("c1", CAR, ALICE)
    lu.assertFalse(again)
    lu.assertNil(first, "the oldest change was still remembered")
    lu.assertStrContains(why, "already owned")
    local remembered = 0
    for _ in pairs(register._applied) do remembered = remembered + 1 end
    lu.assertEquals(remembered, 2)
    lu.assertEquals(#register:chain(CAR), 3)
    lu.assertTrue(register:verify())
end

function TestOwnership:test_release_gives_it_back_to_nobody()
    lu.assertTrue(self.register:release("scrapped", CAR, ALICE))
    lu.assertNil(self.register:owner_of(CAR))
    lu.assertEquals(self.register:assets_of(ALICE), {})
    lu.assertEquals(self.register:count(), 0)
    -- and it is gone, so it cannot be handed on
    local ok = self.register:transfer("too-late", CAR, ALICE, BOB)
    lu.assertFalse(ok)
    lu.assertTrue(self.register:verify())
end

function TestOwnership:test_the_chain_of_custody_reads_as_a_timeline()
    self.register:transfer("sale-1", CAR, ALICE, BOB, { price = 25000, venue = "docks" })
    self.register:transfer("sale-2", CAR, BOB, CARLA)
    local chain = self.register:chain(CAR)
    lu.assertEquals(#chain, 3)
    lu.assertEquals(chain[1].action, "claim")
    lu.assertEquals(chain[1].to, ALICE)
    lu.assertEquals(chain[2].from, ALICE)
    lu.assertEquals(chain[2].to, BOB)
    lu.assertEquals(chain[2].meta.venue, "docks")
    lu.assertEquals(chain[3].to, CARLA)
    lu.assertTrue(chain[1].at < chain[2].at and chain[2].at < chain[3].at)
end

function TestOwnership:test_named_principals_can_hold_things_too()
    -- the impound lot is not an entity, but it holds cars
    lu.assertTrue(self.register:transfer("impound-1", CAR, ALICE, "state:impound"))
    lu.assertEquals(self.register:owner_of(CAR), "state:impound")
    lu.assertEquals(self.register:assets_of("state:impound"), { CAR })
end

function TestOwnership:test_nonsense_parties_are_refused_loudly()
    lu.assertError(function() return self.register:claim("x", "not-an-id", ALICE) end)
    lu.assertError(function() return self.register:claim("x", BIKE, "Bob") end)
    lu.assertError(function() return self.register:claim("", BIKE, ALICE) end)
    lu.assertError(function() return self.register:claim(nil, BIKE, ALICE) end)
end

function TestOwnership:test_the_register_survives_a_restart()
    self.register:claim("mint-bike", BIKE, BOB)
    self.register:transfer("sale-1", CAR, ALICE, BOB, { price = 25000 })
    local restored = Ownership.deserialize(self.register:serialize())
    lu.assertEquals(restored:owner_of(CAR), BOB)
    lu.assertEquals(restored:owner_of(BIKE), BOB)
    lu.assertEquals(restored:assets_of(BOB), self.register:assets_of(BOB))
    lu.assertEquals(#restored:chain(CAR), 2)
    lu.assertEquals(restored:chain(CAR)[2].meta.price, 25000)
    lu.assertTrue(restored:verify())
end

function TestOwnership:test_verify_notices_a_broken_index()
    -- reach past the methods on purpose: this is what a bug would look like
    self.register._owner[BIKE] = BOB
    local ok, problems = self.register:verify()
    lu.assertFalse(ok)
    lu.assertEquals(#problems, 1)
    lu.assertStrContains(problems[1], "missing from the index")
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
