--- The mechanic the product is named after: a crime nobody saw leaves no heat
--- and a full record. Wait out the heat and you are still the person who did it.
local modname = ...
local lu = require("luaunit")
local Clock = require("core.clock")
local World = require("core.world")
local Characters = require("systems.characters")
local Memory = require("systems.memory")
local FileStore = require("persistence.file_store")
local MemoryStore = require("persistence.memory_store")

local ROOT = "run/spec"
local ALICE = "license:aaaa1111"
local BOB = "license:bbbb2222"

TestMemorySystem = {}

function TestMemorySystem:setUp()
    self.world = World.new({ rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
    self.world:install(Characters.system())
    self.world:install(Memory.system())
    self.jane = self.world:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    self.world:dispatch("character.select", { character = self.jane }, { account = ALICE })
    self.john = self.world:dispatch("character.create",
        { first_name = "John", last_name = "Roe" }, { account = BOB }).value
    self.remember = self.world.services.remember
end

function TestMemorySystem:tearDown()
    self.world:deactivate()
end

function TestMemorySystem:test_a_crime_with_a_witness_makes_you_wanted()
    local heard
    self.world:on("city.remembered", function(payload) heard = payload end, { label = "spec" })
    local written, changes = self.remember("rob-1", {
        subject = self.jane, kind = "crime.robbery", weight = 40,
        place = "shop:rob24", witnesses = { self.john },
    })
    lu.assertEquals(written.kind, "crime.robbery")
    lu.assertEquals(self.world.services.heat(self.jane), 40)
    lu.assertEquals(#changes, 2)                     -- police, and the place itself
    lu.assertTrue(heard.witnessed)
    lu.assertEquals(heard.subject, self.jane)
end

function TestMemorySystem:test_a_crime_nobody_saw_leaves_no_heat_and_a_full_record()
    -- The mechanic. Nobody is looking for you, and the evidence is sitting
    -- there with your name on it.
    local written = self.remember("burg-1", {
        subject = self.jane, kind = "crime.burglary", weight = 30, place = "house:12",
    })
    lu.assertEquals(self.world.services.heat(self.jane), 0)
    lu.assertEquals(written.witnesses, {})
    local found = self.world.services.recall(self.jane)
    lu.assertEquals(#found, 1)
    lu.assertEquals(found[1].kind, "crime.burglary")
    lu.assertEquals(found[1].place, "house:12")
end

function TestMemorySystem:test_heat_cools_and_the_record_does_not()
    self.remember("rob-1", { subject = self.jane, kind = "crime.robbery",
                             witnesses = { self.john }, place = "shop:rob24" })
    lu.assertEquals(self.world.services.heat(self.jane), 40)

    -- eight city hours later
    for _ = 1, 8 do self.world:tick(Clock.MS_PER_HOUR) end
    lu.assertEquals(self.world.services.heat(self.jane), 0)

    -- and a detective can still pull it up, with the date on it
    local found = self.world.services.recall(self.jane, { prefix = "crime." })
    lu.assertEquals(#found, 1)
    lu.assertEquals(found[1].kind, "crime.robbery")
    lu.assertEquals(found[1].place, "shop:rob24")
end

function TestMemorySystem:test_the_same_crime_reported_twice_costs_you_once()
    self.remember("rob-1", { subject = self.jane, kind = "crime.robbery", witnesses = { self.john } })
    local _, changes, duplicate = self.remember("rob-1", {
        subject = self.jane, kind = "crime.robbery", witnesses = { self.john } })
    lu.assertTrue(duplicate)
    lu.assertEquals(changes, {})
    lu.assertEquals(self.world.services.heat(self.jane), 40)
    lu.assertEquals(self.world.services.record:count(), 1)
end

function TestMemorySystem:test_doing_it_repeatedly_stacks_and_the_place_remembers_too()
    self.remember("r1", { subject = self.jane, kind = "crime.robbery",
                          witnesses = { self.john }, place = "shop:rob24" })
    self.remember("r2", { subject = self.jane, kind = "crime.robbery",
                          witnesses = { self.john }, place = "shop:rob24" })
    lu.assertEquals(self.world.services.heat(self.jane), 80)
    -- the shop itself thinks less of her, whether or not anyone saw
    lu.assertEquals(self.world.services.standing:score(self.jane, "place:shop:rob24"), -30)
    -- three robberies at that shop, all hers, is a question with an answer
    lu.assertEquals(self.world.services.record:tally(self.jane,
        { kind = "crime.robbery", place = "shop:rob24" }), 2)
end

function TestMemorySystem:test_being_arrested_clears_what_they_were_looking_for()
    self.remember("r1", { subject = self.jane, kind = "crime.murder", witnesses = { self.john } })
    lu.assertEquals(self.world.services.heat(self.jane), 120)
    self.remember("a1", { subject = self.jane, kind = "police.arrest", weight = 100 })
    lu.assertEquals(self.world.services.heat(self.jane), 0)
    -- and both are on the record for good
    lu.assertEquals(#self.world.services.recall(self.jane), 2)
    lu.assertEquals(self.world.services.recall(self.jane)[1].kind, "police.arrest")
end

function TestMemorySystem:test_a_consequence_can_depend_on_who_it_was_with()
    self.remember("t1", { subject = self.jane, kind = "trade.cheated",
                          meta = { with = "gang:ballas" } })
    lu.assertEquals(self.world.services.standing:score(self.jane, "gang:ballas"), -30)
    self.remember("t2", { subject = self.john, kind = "trade.honoured",
                          meta = { with = "gang:ballas" } })
    lu.assertEquals(self.world.services.standing:score(self.john, "gang:ballas"), 5)
end

function TestMemorySystem:test_a_record_with_no_consequence_declared_is_still_kept()
    local written = self.remember("s1", { subject = self.jane, kind = "social.argued", weight = 2 })
    lu.assertEquals(written.kind, "social.argued")
    lu.assertEquals(#self.world.services.recall(self.jane), 1)
    lu.assertEquals(#self.world.services.standing:parties(self.jane), 0)
end

function TestMemorySystem:test_a_server_can_add_its_own_consequences()
    local other = World.new({ rate = 1, activate = false })
    other:install(Characters.system())
    other:install(Memory.system({ also = {
        ["crime.arson"] = { { party = "police", points = -90, requires_witness = true },
                            { party = "insurer:pacific", points = -200 } },
    } }))
    other.services.remember("f1", { subject = "chr_0000000000000000009",
                                    kind = "crime.arson", witnesses = { "chr_0000000000000000008" } })
    lu.assertEquals(other.services.heat("chr_0000000000000000009"), 90)
    lu.assertEquals(other.services.standing:score("chr_0000000000000000009", "insurer:pacific"), -200)
    -- and the defaults are still there
    lu.assertNotNil(Memory.DEFAULT_CONSEQUENCES["crime.robbery"])
end

function TestMemorySystem:test_the_police_board_reads_worst_first()
    self.remember("r1", { subject = self.jane, kind = "crime.murder", witnesses = { self.john } })
    self.remember("r2", { subject = self.john, kind = "crime.assault", witnesses = { self.jane } })
    local wanted = self.world.services.standing:ranked("police")
    lu.assertEquals(#wanted, 2)
    lu.assertEquals(wanted[1].subject, self.jane)
    lu.assertEquals(wanted[1].score, -120)
end

function TestMemorySystem:test_you_can_look_up_what_the_city_has_on_you()
    self.remember("r1", { subject = self.jane, kind = "crime.robbery",
                          witnesses = { self.john }, place = "shop:rob24" })
    self.remember("r2", { subject = self.jane, kind = "trade.honoured", meta = { with = "gang:ballas" } })
    local outcome = self.world:dispatch("record.mine", {}, { account = ALICE, actor = self.jane })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.records, 2)
    lu.assertEquals(outcome.value.records[1].kind, "trade.honoured")
    lu.assertTrue(outcome.value.records[2].witnessed)
    lu.assertEquals(outcome.value.heat, 40)
    -- narrowing works, and so does asking as nobody
    lu.assertEquals(#self.world:dispatch("record.mine", { kind = "crime.robbery" },
        { account = ALICE, actor = self.jane }).value.records, 1)
    lu.assertEquals(self.world:dispatch("record.mine", {}, { account = ALICE }).code, "not_playing")
end

function TestMemorySystem:test_your_record_is_what_you_did_not_what_was_done_to_you()
    -- A line is findable from every side of it, and record.mine read every
    -- side as the player's own: a murder victim was shown "crime.murder", and
    -- anybody the police or staff pulled up could read that they had been.
    self.remember("m1", { subject = self.john, kind = "crime.murder", weight = 80,
                          involved = { self.jane }, witnesses = { "chr_0000000000000000009" } })
    self.remember("l1", { subject = self.john, kind = "police.lookup", involved = { self.jane } })
    self.remember("a1", { subject = "chr_0000000000000000008", kind = "admin.acted",
                          involved = { self.jane }, meta = { action = "look" } })
    self.remember("s1", { subject = self.jane, kind = "social.argued", weight = 2 })
    local outcome = self.world:dispatch("record.mine", {}, { account = ALICE, actor = self.jane })
    lu.assertTrue(outcome:succeeded())
    lu.assertEquals(#outcome.value.records, 1)
    lu.assertEquals(outcome.value.records[1].kind, "social.argued")
    -- and whoever did those things still reads them as theirs
    local his = self.world:dispatch("record.mine", {}, { account = BOB, actor = self.john })
    lu.assertEquals(#his.value.records, 2)
    lu.assertEquals(his.value.records[1].kind, "police.lookup")
    lu.assertEquals(his.value.records[2].kind, "crime.murder")
end

function TestMemorySystem:test_what_leaves_the_window_is_written_down_not_dropped()
    -- The record is never edited and never expires. It keeps a window in
    -- memory, and what left the window was handed to nobody: gone from the
    -- city and from the save, the oldest first, whatever it was.
    local store = MemoryStore.new()
    local JANE = "chr_0000000000000000009"
    local function city()
        local world = World.new({ store = store, rate = 1, start_at = 8 * Clock.MS_PER_HOUR })
        world:install(Memory.system({ limit = 3, archive_page = 2 }))
        return world
    end
    local function paged()
        local weights = {}
        for _, key in ipairs(store:keys(Memory.archive_collection(1))) do
            for _, line in ipairs(store:get(Memory.archive_collection(1), key).lines) do
                weights[#weights + 1] = line.weight
            end
        end
        table.sort(weights)
        return weights
    end

    local first = city()
    for weight = 1, 6 do
        first.services.remember("w" .. weight, { subject = JANE, kind = "social.argued", weight = weight })
    end
    lu.assertEquals(first.services.record:count(), 3)
    lu.assertEquals(paged(), { 1, 2 })              -- a page, and one line waiting for the next
    lu.assertTrue(first:save())
    first:deactivate()

    local again = city()
    local ok, problems = again:load()
    lu.assertTrue(ok, table.concat(problems or {}, "; "))
    for weight = 7, 8 do
        again.services.remember("w" .. weight, { subject = JANE, kind = "social.argued", weight = weight })
    end
    lu.assertTrue(again:save())
    -- the line that was waiting when the server stopped is on the page now
    lu.assertEquals(paged(), { 1, 2, 3, 4 })
    local everywhere = {}
    for _, line in ipairs(again.services.recall(JANE)) do everywhere[#everywhere + 1] = line.weight end
    for _, line in ipairs(store:get("world", "memory").archive.pending) do
        everywhere[#everywhere + 1] = line.weight
    end
    for _, weight in ipairs(paged()) do everywhere[#everywhere + 1] = weight end
    table.sort(everywhere)
    lu.assertEquals(everywhere, { 1, 2, 3, 4, 5, 6, 7, 8 })
    again:deactivate()
end

local function archived_weights(store, volume)
    local weights = {}
    for _, key in ipairs(store:keys(Memory.archive_collection(volume))) do
        for _, line in ipairs(store:get(Memory.archive_collection(volume), key).lines) do
            weights[#weights + 1] = line.weight
        end
    end
    table.sort(weights)
    return weights
end

function TestMemorySystem:test_the_archive_is_kept_in_volumes_so_no_one_of_them_grows_forever()
    -- A file store rewrites a whole collection to change one key, and reads a
    -- whole collection back to add one. One collection for all of history
    -- would be the entire record, rewritten every time a page was added.
    local store = MemoryStore.new()
    local world = World.new({ store = store, rate = 1 })
    world:install(Memory.system({ limit = 1, archive_page = 1 }))
    for weight = 1, 23 do
        world.services.remember("w" .. weight, { subject = "chr_0000000000000000009",
                                                 kind = "social.argued", weight = weight })
    end
    lu.assertEquals(#archived_weights(store, 1), 20)
    lu.assertEquals(archived_weights(store, 2), { 21, 22 })
    world:deactivate()
end

function TestMemorySystem:test_a_city_not_read_yet_cannot_write_over_the_archive()
    -- A world that stands for a city in the store writes nothing until it has
    -- read it. The archive goes straight to the store, so a page is named by
    -- its first line rather than by a count a city that has not been read yet
    -- would start again from.
    local store = MemoryStore.new()
    local JANE = "chr_0000000000000000009"
    local first = World.new({ store = store, rate = 1 })
    first:install(Memory.system({ limit = 1, archive_page = 1 }))
    first.services.remember("a", { subject = JANE, kind = "social.argued", weight = 1 })
    first.services.remember("b", { subject = JANE, kind = "social.argued", weight = 2 })
    lu.assertTrue(first:save())
    first:deactivate()

    local second = World.new({ store = store, rate = 1, require_load = true })
    second:install(Memory.system({ limit = 1, archive_page = 1 }))
    second.services.remember("x", { subject = JANE, kind = "social.argued", weight = 9 })
    second.services.remember("y", { subject = JANE, kind = "social.argued", weight = 10 })
    local ok, problems = second:load()
    lu.assertTrue(ok, table.concat(problems or {}, "; "))
    lu.assertEquals(archived_weights(store, 1)[1], 1)
    second:deactivate()
end

function TestMemorySystem:test_reading_the_record_back_starts_over_on_what_is_held()
    -- Which lines are held is worked out from the lines in memory, so a record
    -- read back from the store starts that over. Marks kept for lines that are
    -- no longer the ones in memory would hold a line nothing depends on.
    local store = MemoryStore.new()
    local JANE, NOISE = "chr_0000000000000000009", "chr_0000000000000000008"
    local world = World.new({ store = store, rate = 1 })
    world:install(Memory.system({ limit = 2 }))
    local open = true
    world.services.record:hold(function(entry) return open and entry.kind == "crime.murder" end,
        { "police.arrest" })
    world.services.remember("m", { subject = JANE, kind = "crime.murder", weight = 80 })
    for weight = 1, 3 do
        world.services.remember("s" .. weight, { subject = NOISE, kind = "social.argued", weight = weight })
    end
    lu.assertTrue(world:save())
    lu.assertTrue(world:load())
    open = false
    world.services.remember("a", { subject = JANE, kind = "police.arrest", weight = 10 })
    lu.assertEquals(#world.services.recall(JANE, { kind = "crime.murder" }), 0)
    world:deactivate()
end

function TestMemorySystem:test_a_stored_archive_that_is_not_one_is_refused()
    local store = MemoryStore.new()
    local world = World.new({ store = store, rate = 1 })
    world:install(Memory.system())
    store:put("world", "memory", { archive = { pages = "lots", pending = {} } })
    local ok, problems = world:load()
    lu.assertFalse(ok)
    lu.assertStrContains(table.concat(problems, "; "), "archive")
    world:deactivate()
end

function TestMemorySystem:test_you_cannot_look_up_somebody_else()
    -- The command reads the acting character and nothing else, so there is no
    -- argument a client could put a stranger id into.
    local described = self.world.commands:describe("record.mine")
    for _, field in ipairs(described.args) do
        lu.assertNotEquals(field.name, "character")
        lu.assertNotEquals(field.name, "subject")
    end
end

function TestMemorySystem:test_a_malformed_record_is_a_bug_and_is_loud()
    lu.assertError(function() return self.remember("x", { subject = self.jane, kind = "robbery" }) end)
    lu.assertError(function() return self.remember("", { subject = self.jane, kind = "crime.robbery" }) end)
end

TestMemoryRestart = {}

function TestMemoryRestart:setUp()
    for _, name in ipairs({ "world", "chr" }) do
        for _, suffix in ipairs({ ".json", ".json.bak", ".json.tmp" }) do
            os.remove(("%s/%s%s"):format(ROOT, name, suffix))
        end
    end
end

function TestMemoryRestart:tearDown()
    if self.world then self.world:deactivate() end
end

function TestMemoryRestart:test_the_city_still_remembers_after_a_restart()
    local first = World.new({ store = FileStore.new({ root = ROOT }), rate = 1,
                              start_at = 8 * Clock.MS_PER_HOUR })
    first:install(Characters.system())
    first:install(Memory.system())
    local jane = first:dispatch("character.create",
        { first_name = "Jane", last_name = "Doe" }, { account = ALICE }).value
    first.services.remember("r1", { subject = jane, kind = "crime.robbery", weight = 40,
                                    place = "shop:rob24", witnesses = { "chr_0000000000000000009" } })
    first.services.remember("r2", { subject = jane, kind = "crime.burglary", weight = 30 })
    lu.assertEquals(first.services.heat(jane), 40)
    first.clock:skip(Clock.MS_PER_HOUR * 2)
    lu.assertTrue(first:close())

    self.world = World.new({ store = FileStore.new({ root = ROOT }) })
    self.world:install(Characters.system())
    self.world:install(Memory.system())
    local ok, problems = self.world:load()
    lu.assertTrue(ok, table.concat(problems, "; "))

    -- the heat carried on cooling from where it was, not from the restart
    lu.assertEquals(self.world.services.heat(jane), 30)
    -- and the record is exactly as it was
    local found = self.world.services.recall(jane)
    lu.assertEquals(#found, 2)
    lu.assertEquals(found[2].place, "shop:rob24")
    lu.assertEquals(found[1].kind, "crime.burglary")
    lu.assertEquals(self.world.services.record:tally(jane, { prefix = "crime." }), 2)
    lu.assertTrue(self.world.services.record:verify())
    -- and a crime already recorded is not recorded again
    local _, _, duplicate = self.world.services.remember("r1",
        { subject = jane, kind = "crime.robbery" })
    lu.assertTrue(duplicate)
    lu.assertEquals(self.world.services.record:count(), 2)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
