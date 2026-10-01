--- The city remembers. Standing fades; the record underneath it does not.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local Record = require("domain.record")
local Standing = require("domain.standing")

local ALICE = "chr_0000000000000000001"
local BOB = "chr_0000000000000000002"
local CARLA = "chr_0000000000000000003"

TestRecord = {}

function TestRecord:setUp()
    self.tick = 1757500000000
    self.book = Record.new({ clock = function()
        self.tick = self.tick + 1000
        return self.tick
    end })
end

function TestRecord:test_something_that_happened_is_written_down()
    local written = self.book:write("r1", {
        subject = ALICE, kind = "crime.robbery", weight = 40,
        place = "shop:rob24", witnesses = { BOB },
        meta = { taken = 45000 },
    })
    lu.assertStrContains(written.id, "rec_")
    lu.assertEquals(written.kind, "crime.robbery")
    lu.assertEquals(written.weight, 40)
    lu.assertEquals(written.witnesses, { BOB })
    lu.assertEquals(written.meta.taken, 45000)
    lu.assertEquals(self.book:count(), 1)
    lu.assertTrue(self.book:verify())
end

function TestRecord:test_the_same_thing_reported_twice_is_written_once()
    local first = self.book:write("r1", { subject = ALICE, kind = "crime.robbery" })
    local second, duplicate = self.book:write("r1", { subject = ALICE, kind = "crime.robbery" })
    lu.assertTrue(duplicate)
    lu.assertEquals(second.id, first.id)
    lu.assertEquals(self.book:count(), 1)
end

function TestRecord:test_a_crime_nobody_saw_is_still_written_down()
    -- Physical evidence exists without witnesses. This is what makes an
    -- investigation possible later rather than only an eyewitness.
    self.book:write("r1", { subject = ALICE, kind = "crime.burglary", weight = 30, place = "house:12" })
    local unseen = self.book:about(ALICE, { witnessed = false })
    lu.assertEquals(#unseen, 1)
    lu.assertEquals(unseen[1].witnesses, {})
    lu.assertEquals(#self.book:about(ALICE, { witnessed = true }), 0)
end

function TestRecord:test_everything_about_somebody_comes_back_newest_first()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", weight = 40 })
    self.book:write("r2", { subject = ALICE, kind = "trade.sold", weight = 5 })
    self.book:write("r3", { subject = ALICE, kind = "crime.robbery", weight = 60 })
    self.book:write("r4", { subject = BOB, kind = "crime.robbery", weight = 10 })

    local history = self.book:about(ALICE)
    lu.assertEquals(#history, 3)
    lu.assertEquals(history[1].weight, 60)      -- newest first
    lu.assertEquals(history[3].weight, 40)
    lu.assertEquals(#self.book:about(BOB), 1)
end

function TestRecord:test_a_detective_can_narrow_it_down()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", weight = 40, place = "shop:rob24" })
    self.book:write("r2", { subject = ALICE, kind = "crime.robbery", weight = 60, place = "shop:rob24" })
    self.book:write("r3", { subject = ALICE, kind = "crime.assault", weight = 20, place = "street:grove" })
    self.book:write("r4", { subject = ALICE, kind = "trade.sold", weight = 1 })

    -- three robberies at that shop this month, all yours
    lu.assertEquals(self.book:tally(ALICE, { kind = "crime.robbery", place = "shop:rob24" }), 2)
    lu.assertEquals(self.book:tally(ALICE, { prefix = "crime." }), 3)
    lu.assertEquals(self.book:tally(ALICE, { min_weight = 50 }), 1)
    lu.assertEquals(#self.book:about(ALICE, { limit = 2 }), 2)
end

function TestRecord:test_a_record_is_findable_from_every_side_of_it()
    self.book:write("r1", {
        subject = ALICE, kind = "crime.robbery", weight = 40,
        involved = { BOB }, witnesses = { CARLA },
    })
    lu.assertEquals(#self.book:about(ALICE), 1)
    lu.assertEquals(#self.book:about(BOB), 1)        -- the accomplice
    lu.assertEquals(#self.book:about(CARLA), 0)      -- a witness is not a subject
    -- but what a witness saw can be asked for
    lu.assertEquals(#self.book:search({ witness = CARLA }), 1)
    lu.assertEquals(self.book:subjects(), { ALICE, BOB })
end

function TestRecord:test_what_somebody_did_can_be_told_from_what_was_done_to_them()
    -- Findable from every side is right for a detective and wrong for a
    -- warrant: the person a robbery was done to did not rob anybody.
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", involved = { BOB } })
    self.book:write("r2", { subject = BOB, kind = "trade.sold" })
    lu.assertEquals(#self.book:about(BOB), 2)
    local own = self.book:about(BOB, { involved = false })
    lu.assertEquals(#own, 1)
    lu.assertEquals(own[1].kind, "trade.sold")
    local drawn_in = self.book:about(BOB, { involved = true })
    lu.assertEquals(#drawn_in, 1)
    lu.assertEquals(drawn_in[1].kind, "crime.robbery")
    lu.assertEquals(self.book:tally(ALICE, { involved = false }), 1)
    lu.assertEquals(self.book:tally(ALICE, { involved = true }), 0)
end

function TestRecord:test_searching_across_everybody_finds_a_pattern()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", place = "shop:rob24" })
    self.book:write("r2", { subject = BOB, kind = "crime.robbery", place = "shop:rob24" })
    self.book:write("r3", { subject = CARLA, kind = "crime.robbery", place = "shop:other" })
    local at_that_shop = self.book:search({ place = "shop:rob24" })
    lu.assertEquals(#at_that_shop, 2)
    lu.assertEquals(#self.book:search({ kind = "crime.robbery" }), 3)
    lu.assertEquals(#self.book:search({ subject = ALICE }), 1)
end

function TestRecord:test_time_narrows_it_too()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", at = 1000 })
    self.book:write("r2", { subject = ALICE, kind = "crime.robbery", at = 5000 })
    self.book:write("r3", { subject = ALICE, kind = "crime.robbery", at = 9000 })
    lu.assertEquals(self.book:tally(ALICE, { since = 5000 }), 2)
    lu.assertEquals(self.book:tally(ALICE, { until_at = 5000 }), 2)
    lu.assertEquals(self.book:tally(ALICE, { since = 2000, until_at = 8000 }), 1)
end

function TestRecord:test_a_record_cannot_be_edited_through_what_it_hands_back()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", weight = 40,
                            witnesses = { BOB }, meta = { taken = 45000 } })
    local pulled = self.book:about(ALICE)[1]
    pulled.weight = 0
    pulled.witnesses[1] = CARLA
    pulled.meta.taken = 0
    local again = self.book:about(ALICE)[1]
    lu.assertEquals(again.weight, 40)
    lu.assertEquals(again.witnesses, { BOB })
    lu.assertEquals(again.meta.taken, 45000)
end

function TestRecord:test_nonsense_is_refused_loudly()
    lu.assertError(function() return self.book:write("", { subject = ALICE, kind = "crime.robbery" }) end)
    lu.assertError(function() return self.book:write("r", { subject = ALICE, kind = "robbery" }) end)
    lu.assertError(function() return self.book:write("r", { subject = "", kind = "crime.robbery" }) end)
    lu.assertError(function() return self.book:write("r", { subject = ALICE, kind = "crime.robbery", weight = 200 }) end)
    lu.assertError(function() return self.book:write("r", { subject = ALICE, kind = "crime.robbery", weight = 1.5 }) end)
    lu.assertError(function()
        return self.book:write("r", { subject = ALICE, kind = "crime.robbery", meta = { f = function() end } })
    end)
    lu.assertError(function()
        return self.book:write("r", { subject = ALICE, kind = "crime.robbery", witnesses = { "" } })
    end)
end

function TestRecord:test_the_window_is_bounded_and_hands_over_what_leaves_it()
    local archived = {}
    local small = Record.new({ limit = 3, on_archive = function(removed)
        for _, entry in ipairs(removed) do archived[#archived + 1] = entry end
    end })
    for index = 1, 8 do
        small:write("r" .. index, { subject = ALICE, kind = "crime.robbery", weight = index, at = index })
    end
    lu.assertEquals(small:count(), 3)
    lu.assertEquals(small:archived_count(), 5)
    lu.assertEquals(#archived, 5)
    lu.assertEquals(archived[1].weight, 1)
    lu.assertEquals(#small:about(ALICE), 3)          -- the index shrank with it
    lu.assertTrue(small:verify())
end

function TestRecord:test_a_line_somebody_still_depends_on_outlasts_the_window()
    -- A window that drops its oldest line whatever it says lets anybody who
    -- can write lines push out the one that matters.
    local wanted = { [ALICE] = true, [CARLA] = true }
    local small = Record.new({ limit = 3 })
    small:hold(function(entry)
        return wanted[entry.subject] == true and entry.kind == "crime.murder"
    end, { "police.arrest" })
    small:write("m", { subject = ALICE, kind = "crime.murder", at = 1 })
    small:write("n", { subject = CARLA, kind = "crime.murder", at = 2 })
    for index = 1, 6 do
        small:write("s" .. index, { subject = BOB, kind = "social.argued", weight = index, at = index + 2 })
    end
    lu.assertEquals(#small:about(ALICE, { kind = "crime.murder" }), 1)
    -- what is held does not take the place of anything else, which still
    -- leaves oldest first
    lu.assertEquals(small:count(), 5)
    lu.assertEquals(small:archived_count(), 3)
    local rest = small:about(BOB)
    lu.assertEquals(#rest, 3)
    lu.assertEquals(rest[3].weight, 4)
    lu.assertTrue(small:verify())

    -- It is asked again when a line that can change the answer is written
    -- about whoever it is about, and not for anything else. Then it goes the
    -- way everything else does, and what is held about anybody else stays.
    wanted[ALICE] = false
    small:write("s7", { subject = BOB, kind = "social.argued", weight = 7, at = 9 })
    small:write("x", { subject = ALICE, kind = "social.argued", weight = 8, at = 10 })
    lu.assertEquals(#small:about(ALICE, { kind = "crime.murder" }), 1)
    small:write("a", { subject = ALICE, kind = "police.arrest", at = 11 })
    lu.assertEquals(#small:about(ALICE, { kind = "crime.murder" }), 0)
    lu.assertEquals(#small:about(CARLA, { kind = "crime.murder" }), 1)
    lu.assertEquals(small:count(), 4)
    lu.assertEquals(small:archived_count(), 7)
    lu.assertTrue(small:verify())
    lu.assertError(function() return small:hold(function() return true end, { "arrest" }) end)
end

function TestRecord:test_a_held_line_nobody_will_ask_again_is_reported()
    -- A line held and not listed as held is never asked again and stays for
    -- good; a line listed and not held is asked about for nothing.
    local small = Record.new({ limit = 1 })
    small:hold(function(entry) return entry.kind == "crime.murder" end, { "police.arrest" })
    small:write("m", { subject = ALICE, kind = "crime.murder", at = 1 })
    small:write("s1", { subject = BOB, kind = "social.argued", at = 2 })
    small:write("s2", { subject = BOB, kind = "social.argued", at = 3 })
    lu.assertTrue(small:verify())

    local listed = small._held_of
    small._held_of = {}
    local ok, problems = small:verify()
    lu.assertFalse(ok)
    lu.assertStrContains(problems[1], "not listed once as held")

    small._held_of = listed
    small._held_of[BOB] = { small._entries[#small._entries] }
    ok, problems = small:verify()
    lu.assertFalse(ok)
    lu.assertStrContains(problems[1], "is listed as held and is not")
end

function TestRecord:test_a_held_line_is_still_held_after_a_restart()
    local function hold_murders(book)
        return book:hold(function(entry) return entry.kind == "crime.murder" end)
    end
    local small = hold_murders(Record.new({ limit = 2 }))
    small:write("m", { subject = ALICE, kind = "crime.murder", at = 1 })
    for index = 1, 4 do
        small:write("s" .. index, { subject = BOB, kind = "social.argued", weight = index, at = index + 1 })
    end
    local restored = hold_murders(assert(Record.deserialize(small:serialize(), { limit = 2 })))
    for index = 5, 8 do
        restored:write("s" .. index, { subject = BOB, kind = "social.argued", weight = index, at = index + 1 })
    end
    lu.assertEquals(#restored:about(ALICE), 1)
    lu.assertEquals(restored:count(), 3)
    lu.assertEquals(restored:about(BOB)[2].weight, 7)
    lu.assertTrue(restored:verify())
    lu.assertError(function() return small:hold("not a function") end)
end

function TestRecord:test_the_book_survives_a_restart()
    self.book:write("r1", { subject = ALICE, kind = "crime.robbery", weight = 40,
                            place = "shop:rob24", witnesses = { BOB }, involved = { CARLA },
                            meta = { taken = 45000 } })
    self.book:write("r2", { subject = BOB, kind = "trade.sold" })
    local restored = assert(Record.deserialize(self.book:serialize()))
    lu.assertEquals(restored:count(), 2)
    lu.assertEquals(restored:about(ALICE)[1].meta.taken, 45000)
    lu.assertEquals(#restored:about(CARLA), 1)
    lu.assertEquals(#restored:search({ witness = BOB }), 1)
    lu.assertTrue(restored:verify())
    -- and a record written before the restart is still not written twice
    local _, duplicate = restored:write("r1", { subject = ALICE, kind = "crime.robbery" })
    lu.assertTrue(duplicate)
    lu.assertEquals(restored:count(), 2)
end

function TestRecord:test_a_stored_book_that_is_broken_is_refused()
    local record = self.book:serialize()
    record.entries[1] = { subject = ALICE, kind = "nonsense", at = 1 }
    lu.assertNil(Record.deserialize(record))
    lu.assertNil(Record.deserialize("not a book"))
end

TestStanding = {}

function TestStanding:setUp()
    self.now = 0
    self.standing = Standing.new({
        clock = function() return self.now end,
        period = Clock.MS_PER_HOUR,
        rate = 5,
    })
end

function TestStanding:test_standing_starts_at_nothing()
    lu.assertEquals(self.standing:score(ALICE, "police"), 0)
    lu.assertEquals(self.standing:heat(ALICE), 0)
    lu.assertEquals(self.standing:subjects(), {})
end

function TestStanding:test_doing_something_moves_it()
    self.standing:adjust("a1", ALICE, "police", -40, nil)
    lu.assertEquals(self.standing:score(ALICE, "police"), -40)
    lu.assertEquals(self.standing:heat(ALICE), 40)
    self.standing:adjust("a2", ALICE, "gang:ballas", 30)
    lu.assertEquals(self.standing:score(ALICE, "gang:ballas"), 30)
    lu.assertEquals(self.standing:heat(ALICE, "gang:ballas"), 0)   -- positive is not heat
end

function TestStanding:test_the_same_event_twice_moves_it_once()
    self.standing:adjust("a1", ALICE, "police", -40)
    local score, duplicate = self.standing:adjust("a1", ALICE, "police", -40)
    lu.assertTrue(duplicate)
    lu.assertEquals(score, -40)
    lu.assertEquals(self.standing:score(ALICE, "police"), -40)
end

function TestStanding:test_heat_cools_and_the_arithmetic_is_exact()
    self.standing:adjust("a1", ALICE, "police", -40)
    self.now = Clock.MS_PER_HOUR * 3
    lu.assertEquals(self.standing:score(ALICE, "police"), -25)     -- three hours at five
    self.now = Clock.MS_PER_HOUR * 8
    lu.assertEquals(self.standing:score(ALICE, "police"), 0)       -- and it stops at nothing
    lu.assertEquals(self.standing:heat(ALICE), 0)
end

function TestStanding:test_asking_often_gives_the_same_answer_as_asking_once()
    -- Decay computed from the last settled time in whole steps, so it cannot
    -- drift with how often anybody looks.
    local patient = Standing.new({ clock = function() return self.now end,
                                   period = Clock.MS_PER_HOUR, rate = 5 })
    local pestered = Standing.new({ clock = function() return self.now end,
                                    period = Clock.MS_PER_HOUR, rate = 5 })
    patient:adjust("a", ALICE, "police", -100)
    pestered:adjust("a", ALICE, "police", -100)
    for hour = 1, 10 do
        self.now = Clock.MS_PER_HOUR * hour
        pestered:score(ALICE, "police")
        pestered:score(ALICE, "police")
    end
    lu.assertEquals(patient:score(ALICE, "police"), pestered:score(ALICE, "police"))
    lu.assertEquals(patient:score(ALICE, "police"), -50)
end

function TestStanding:test_part_of_a_period_does_not_count_and_is_not_lost()
    self.standing:adjust("a1", ALICE, "police", -40)
    self.now = Clock.MS_PER_HOUR - 1
    lu.assertEquals(self.standing:score(ALICE, "police"), -40)     -- not yet
    self.now = Clock.MS_PER_HOUR
    lu.assertEquals(self.standing:score(ALICE, "police"), -35)
    -- the leftover millisecond was carried, not dropped
    self.now = Clock.MS_PER_HOUR * 2 - 1
    lu.assertEquals(self.standing:score(ALICE, "police"), -35)
    self.now = Clock.MS_PER_HOUR * 2
    lu.assertEquals(self.standing:score(ALICE, "police"), -30)
end

function TestStanding:test_doing_it_again_while_hot_stacks()
    self.standing:adjust("a1", ALICE, "police", -40)
    self.now = Clock.MS_PER_HOUR * 2
    self.standing:adjust("a2", ALICE, "police", -40)
    lu.assertEquals(self.standing:score(ALICE, "police"), -70)     -- decayed 10, then another 40
end

function TestStanding:test_a_score_cannot_run_away()
    for index = 1, 50 do
        self.standing:adjust("a" .. index, ALICE, "police", -100)
    end
    lu.assertEquals(self.standing:score(ALICE, "police"), -1000)
    for index = 51, 120 do
        self.standing:adjust("a" .. index, ALICE, "police", 100)
    end
    lu.assertEquals(self.standing:score(ALICE, "police"), 1000)
end

function TestStanding:test_some_standing_is_earned_and_does_not_drift_away()
    -- A made member of a gang does not decay back to stranger.
    self.standing:adjust("a1", ALICE, "gang:ballas", 60)
    self.standing:set_floor(ALICE, "gang:ballas", 50)
    self.now = Clock.MS_PER_HOUR * 100
    lu.assertEquals(self.standing:score(ALICE, "gang:ballas"), 50)
    lu.assertEquals(self.standing:floor(ALICE, "gang:ballas"), 50)
end

function TestStanding:test_different_parties_can_cool_at_different_speeds()
    local mixed = Standing.new({
        clock = function() return self.now end,
        period = Clock.MS_PER_HOUR, rate = 5,
        rates = { police = 2, ["gang:ballas"] = 0 },
    })
    mixed:adjust("a", ALICE, "police", -40)
    mixed:adjust("b", ALICE, "gang:ballas", 40)
    mixed:adjust("c", ALICE, "district:vespucci", -40)
    self.now = Clock.MS_PER_HOUR * 5
    lu.assertEquals(mixed:score(ALICE, "police"), -30)              -- slower
    lu.assertEquals(mixed:score(ALICE, "gang:ballas"), 40)          -- never
    lu.assertEquals(mixed:score(ALICE, "district:vespucci"), -15)   -- the default
end

function TestStanding:test_the_police_board_reads_worst_first()
    self.standing:adjust("a", ALICE, "police", -80)
    self.standing:adjust("b", BOB, "police", -20)
    self.standing:adjust("c", CARLA, "police", -400)
    self.standing:adjust("d", ALICE, "gang:ballas", -999)
    local wanted = self.standing:ranked("police")
    lu.assertEquals(#wanted, 3)
    lu.assertEquals(wanted[1].subject, CARLA)
    lu.assertEquals(wanted[1].score, -400)
    lu.assertEquals(wanted[3].subject, BOB)
    lu.assertEquals(#self.standing:ranked("police", { min_magnitude = 50 }), 2)
    lu.assertEquals(#self.standing:ranked("police", { limit = 1 }), 1)
end

function TestStanding:test_everything_that_has_an_opinion_about_you()
    self.standing:adjust("a", ALICE, "police", -80)
    self.standing:adjust("b", ALICE, "gang:ballas", 30)
    local parties = self.standing:parties(ALICE)
    lu.assertEquals(#parties, 2)
    lu.assertEquals(parties[1].party, "gang:ballas")
    lu.assertEquals(parties[2].party, "police")
    lu.assertEquals(parties[2].score, -80)
end

function TestStanding:test_settled_scores_that_reached_nothing_stop_being_held()
    self.standing:adjust("a", ALICE, "police", -10)
    self.standing:adjust("b", BOB, "gang:ballas", 100)
    self.now = Clock.MS_PER_HOUR * 3
    self.standing:settle_all()
    lu.assertEquals(self.standing:subjects(), { BOB })    -- Alice cooled off entirely
    lu.assertEquals(self.standing:score(ALICE, "police"), 0)
    lu.assertEquals(self.standing:score(BOB, "gang:ballas"), 85)
end

function TestStanding:test_nonsense_is_refused_loudly()
    lu.assertError(function() return self.standing:adjust("", ALICE, "police", -1) end)
    lu.assertError(function() return self.standing:adjust("a", "", "police", -1) end)
    lu.assertError(function() return self.standing:adjust("a", ALICE, "", -1) end)
    lu.assertError(function() return self.standing:adjust("a", ALICE, "police", 1.5) end)
    lu.assertError(function() return self.standing:set_floor(ALICE, "police", 1.5) end)
    lu.assertError(function() return Standing.new({ period = 0 }) end)
    lu.assertError(function() return Standing.new({ min = 10, max = 5 }) end)
end

function TestStanding:test_standing_survives_a_restart_with_its_decay_intact()
    self.standing:adjust("a", ALICE, "police", -100)
    self.standing:set_floor(BOB, "gang:ballas", 40)
    self.now = Clock.MS_PER_HOUR * 2

    local opts = { clock = function() return self.now end, period = Clock.MS_PER_HOUR, rate = 5 }
    local restored = assert(Standing.deserialize(self.standing:serialize(), opts))
    lu.assertEquals(restored:score(ALICE, "police"), -90)
    lu.assertEquals(restored:floor(BOB, "gang:ballas"), 40)
    -- and it carries on cooling from where it was, not from the restart
    self.now = Clock.MS_PER_HOUR * 12
    lu.assertEquals(restored:score(ALICE, "police"), -40)
    lu.assertTrue(restored:verify())
end

function TestStanding:test_a_stored_score_that_is_not_a_whole_number_is_refused()
    local record = self.standing:serialize()
    self.standing:adjust("a", ALICE, "police", -10)
    record = self.standing:serialize()
    record.scores[ALICE].police.score = 10.5
    lu.assertNil(Standing.deserialize(record))
    lu.assertNil(Standing.deserialize("not a record"))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
