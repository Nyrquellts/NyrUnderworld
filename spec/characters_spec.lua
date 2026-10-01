--- The account is the identity that cannot be forged, and one account plays
--- one person at a time.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Money = require("domain.money")
local Characters = require("systems.characters")
local FileStore = require("persistence.file_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

TestCharacters = {}

function TestCharacters:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system({ limit = 2, opening = 50000 }))
    self.people = self.world:repository(Characters.Character)
end

function TestCharacters:tearDown()
    self.world:deactivate()
end

function TestCharacters:make(account, first, last)
    return self.world:dispatch("character.create",
        { first_name = first or "Jane", last_name = last or "Doe" }, { account = account })
end

function TestCharacters:test_a_new_person_exists_and_has_an_opening_balance()
    local heard = {}
    self.world:on("character.created", function(payload) heard[#heard + 1] = payload end, { label = "spec" })
    local outcome = self:make(ALICE, "Jane", "Doe")
    lu.assertTrue(outcome:succeeded())

    local jane = assert(self.people:load(outcome.value))
    lu.assertEquals(Characters.full_name(jane), "Jane Doe")
    lu.assertEquals(jane:get("account"), ALICE)
    lu.assertEquals(jane.state, "offline")
    lu.assertEquals(jane:get("born"), 8 * Clock.MS_PER_HOUR)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(jane.id)), Money.of(500))
    -- the money came from somewhere nameable, so the books still sum to nothing
    lu.assertEquals(self.world.ledger:balance("external:mint"), Money.of(500):negate())
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    lu.assertEquals(heard[1].name, "Jane Doe")
    lu.assertTrue(self.world:verify())
end

function TestCharacters:test_a_request_with_no_server_identity_is_refused()
    -- The adapter fills the account in from the server side. A request that
    -- reaches here without one is not a player; it is a bug or a probe.
    local outcome = self.world:dispatch("character.create", { first_name = "Jane", last_name = "Doe" })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "no_account")
    lu.assertEquals(self.people:count(), 0)
end

function TestCharacters:test_an_account_the_client_made_up_is_not_accepted()
    for _, bad in ipairs({ "Alice", "license:", ":abc", "license:a b", string.rep("x", 70), "LICENSE:abc" }) do
        lu.assertFalse(Characters.is_account(bad), ("%q should not be an account"):format(bad))
        lu.assertEquals(self.world:dispatch("character.create",
            { first_name = "Jane", last_name = "Doe" }, { account = bad }).code, "no_account")
    end
end

function TestCharacters:test_names_are_narrow_on_purpose()
    for _, bad in ipairs({ "J", "Jane123", "Jane\nDoe", "Jane\tDoe", "Jane ", " Jane", "Jane-",
                           "<script>", "Jane;DROP", string.rep("a", 30), "" }) do
        local outcome = self.world:dispatch("character.create",
            { first_name = bad, last_name = "Doe" }, { account = ALICE })
        lu.assertTrue(outcome:was_refused(), ("%q should not be a first name"):format(bad))
        lu.assertEquals(outcome.code, "bad_args")
    end
    -- and the ones a person actually has do work
    lu.assertTrue(self:make(ALICE, "Mary Anne", "O'Hara"):succeeded())
end

function TestCharacters:test_an_account_is_capped()
    lu.assertTrue(self:make(ALICE, "Jane", "Doe"):succeeded())
    lu.assertTrue(self:make(ALICE, "John", "Doe"):succeeded())
    local third = self:make(ALICE, "Jack", "Doe")
    lu.assertTrue(third:was_refused())
    lu.assertEquals(third.code, "too_many_characters")
    -- somebody else is unaffected
    lu.assertTrue(self:make(BOB, "Bill", "Roe"):succeeded())
end

function TestCharacters:test_selecting_makes_them_active_and_binds_the_session()
    local jane = self:make(ALICE, "Jane", "Doe").value
    local outcome = self.world:dispatch("character.select", { character = jane }, { account = ALICE })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(self.people:load(jane).state, "active")
    lu.assertEquals(self.world.services.sessions:character_of(ALICE), jane)
    lu.assertEquals(self.world.services.sessions:account_of(jane), ALICE)
    lu.assertEquals(self.world.services.sessions:count(), 1)
end

function TestCharacters:test_you_cannot_play_somebody_elses_person()
    -- The whole reason the account comes from the server: a client naming
    -- another player id gets nothing.
    local jane = self:make(ALICE, "Jane", "Doe").value
    local theft = self.world:dispatch("character.select", { character = jane }, { account = BOB })
    lu.assertTrue(theft:was_refused())
    lu.assertEquals(theft.code, "not_yours")
    lu.assertEquals(self.people:load(jane).state, "offline")
    lu.assertNil(self.world.services.sessions:character_of(BOB))
end

function TestCharacters:test_one_account_plays_one_person_at_a_time()
    local jane = self:make(ALICE, "Jane", "Doe").value
    local john = self:make(ALICE, "John", "Doe").value
    lu.assertTrue(self.world:dispatch("character.select", { character = jane }, { account = ALICE }):succeeded())
    local second = self.world:dispatch("character.select", { character = john }, { account = ALICE })
    lu.assertTrue(second:was_refused())
    lu.assertEquals(second.code, "already_playing")
    lu.assertEquals(self.people:load(john).state, "offline")
    -- releasing first is the way through
    lu.assertTrue(self.world:dispatch("character.release", {}, { account = ALICE }):succeeded())
    lu.assertTrue(self.world:dispatch("character.select", { character = john }, { account = ALICE }):succeeded())
    lu.assertEquals(self.people:load(jane).state, "offline")
end

function TestCharacters:test_being_told_you_are_playing_already_names_nobody()
    -- A refusal is drawn on the player's screen, which is often on a stream,
    -- and this one was the session's own reason: "license:... is already
    -- playing chr_...".
    local jane = self:make(ALICE, "Jane", "Doe").value
    local john = self:make(ALICE, "John", "Doe").value
    self.world:dispatch("character.select", { character = jane }, { account = ALICE })
    local playing = self.world:dispatch("character.select", { character = john }, { account = ALICE })
    lu.assertEquals(playing.code, "already_playing")
    -- and the other way round: the person is held by another session
    self.world:dispatch("character.release", {}, { account = ALICE })
    self.world.services.sessions:bind(BOB, john)
    local held = self.world:dispatch("character.select", { character = john }, { account = ALICE })
    lu.assertEquals(held.code, "already_playing")
    for _, outcome in ipairs({ playing, held }) do
        lu.assertTrue(#outcome.message > 0)
        lu.assertNil(outcome.message:find("license:", 1, true), outcome.message)
        lu.assertNil(outcome.message:find("chr_", 1, true), outcome.message)
    end
    lu.assertNotEquals(playing.message, held.message)
end

function TestCharacters:test_selecting_the_same_person_twice_is_not_an_error()
    local jane = self:make(ALICE, "Jane", "Doe").value
    self.world:dispatch("character.select", { character = jane }, { account = ALICE })
    lu.assertTrue(self.world:dispatch("character.select", { character = jane }, { account = ALICE }):succeeded())
    lu.assertEquals(self.world.services.sessions:count(), 1)
end

function TestCharacters:test_releasing_when_not_playing_is_refused_not_a_crash()
    local outcome = self.world:dispatch("character.release", {}, { account = ALICE })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "not_playing")
    lu.assertFalse(outcome:is_failure())
end

function TestCharacters:test_a_person_who_does_not_exist_cannot_be_selected()
    local outcome = self.world:dispatch("character.select",
        { character = "chr_000000000000000000a" }, { account = ALICE })
    lu.assertEquals(outcome.code, "no_such_character")
    lu.assertEquals(self.world:dispatch("character.select",
        { character = "not-an-id" }, { account = ALICE }).code, "bad_args")
end

function TestCharacters:test_retiring_puts_them_away_and_takes_their_money_out_of_the_world()
    local jane = self:make(ALICE, "Jane", "Doe").value
    local outcome = self.world:dispatch("character.retire", { character = jane }, { account = ALICE })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(self.people:load(jane).state, "retired")
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(jane)), Money.zero)
    lu.assertEquals(self.world.ledger:balance("external:estate"), Money.of(500))
    lu.assertEquals(self.world.ledger:total(), Money.zero)
    -- and the slot is free again
    lu.assertEquals(#Characters.of_account(self.world, ALICE), 0)
    lu.assertTrue(self:make(ALICE, "Jack", "Doe"):succeeded())
    lu.assertTrue(self.world:verify())
end

function TestCharacters:test_somebody_being_played_cannot_be_retired()
    local jane = self:make(ALICE, "Jane", "Doe").value
    self.world:dispatch("character.select", { character = jane }, { account = ALICE })
    local outcome = self.world:dispatch("character.retire", { character = jane }, { account = ALICE })
    lu.assertTrue(outcome:was_refused())
    lu.assertEquals(outcome.code, "still_playing")
    lu.assertEquals(self.people:load(jane).state, "active")
end

function TestCharacters:test_a_retired_person_cannot_be_played_again()
    local jane = self:make(ALICE, "Jane", "Doe").value
    self.world:dispatch("character.retire", { character = jane }, { account = ALICE })
    lu.assertEquals(self.world:dispatch("character.select",
        { character = jane }, { account = ALICE }).code, "retired")
end

function TestCharacters:test_listing_an_account_leaves_out_the_retired()
    local jane = self:make(ALICE, "Jane", "Doe").value
    self:make(ALICE, "John", "Doe")
    self:make(BOB, "Bill", "Roe")
    lu.assertEquals(#Characters.of_account(self.world, ALICE), 2)
    self.world:dispatch("character.retire", { character = jane }, { account = ALICE })
    local left = Characters.of_account(self.world, ALICE)
    lu.assertEquals(#left, 1)
    lu.assertEquals(left[1]:get("first_name"), "John")
    lu.assertEquals(#Characters.of_account(self.world, BOB), 1)
end

TestCharactersRestart = {}

function TestCharactersRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestCharactersRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestCharactersRestart:test_nobody_is_left_logged_in_across_a_restart()
    -- Left alone, a character who was active when the server stopped would be
    -- unselectable forever, with the session that held them long gone.
    local first = World.new({ store = FileStore.new({ root = ROOT }), rate = 1 })
    first:install(Characters.system())
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first:dispatch("character.select", { character = jane }, { account = ALICE })
    lu.assertEquals(first:repository(Characters.Character):load(jane).state, "active")
    lu.assertTrue(first:close())

    self.world = World.new({ store = FileStore.new({ root = ROOT }) })
    self.world:install(Characters.system())
    lu.assertTrue(self.world:load())

    local people = self.world:repository(Characters.Character)
    lu.assertEquals(people:load(jane).state, "offline")
    lu.assertEquals(self.world.services.sessions:count(), 0)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(jane)), Money.of(500))
    -- and they can be picked up again
    lu.assertTrue(self.world:dispatch("character.select", { character = jane }, { account = ALICE }):succeeded())
    lu.assertTrue(self.world:verify())
end

function TestCharacters:test_replacing_retired_people_does_not_replenish_allowances_after_restart()
    local first = self:make(ALICE).value
    local second = self:make(ALICE).value
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(second)), Money.of(500))
    lu.assertTrue(self.world:dispatch("character.retire", { character = first }, { account = ALICE }).ok)
    local replacement = self:make(ALICE)
    lu.assertTrue(replacement.ok)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(replacement.value)), Money.zero)
    lu.assertTrue(self.world:dispatch("character.retire", { character = second }, { account = ALICE }).ok)
    lu.assertTrue(self.world:save())
    local store = self.world.store
    self.world:deactivate()
    self.world = World.new({ store = store, rate = 1 })
    self.world:install(Characters.system({ limit = 2, opening = 50000 }))
    lu.assertTrue(self.world:load())
    local later = self:make(ALICE)
    lu.assertTrue(later.ok)
    lu.assertEquals(self.world.ledger:balance(Characters.wallet(later.value)), Money.zero)
    lu.assertEquals(self.world.ledger:balance("external:mint"), Money.of(-1000))
    lu.assertTrue(self.world:verify())
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
