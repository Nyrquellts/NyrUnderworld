--- Whether the file store can write at all, asked before the city opens.
---
--- On the Enhanced server every save failed for a resource whose folder name
--- had a capital letter in it, and the city opened anyway: people could play,
--- and a minute later the console filled with one failure per collection per
--- save while nothing was kept. Measured with the same files under four names,
--- each run past its first save:
---
---                         legacy 35245    enhanced 139
---     NyrUnderworld          saves        every save fails
---     Nyr_Underworld         saves        every save fails
---     nyrunderworld          saves        saves
---     nyr_underworld         saves        saves
---
--- The servers below are fakes of exactly that and nothing more. A fake that
--- refused more than the real one would pass a check that refuses too much,
--- which on a legacy server is a city that will not start for no reason.
---
--- What this file cannot show is that a boot asks the question. A boot does:
--- see the LEDGER section this came in with.
local modname = ...
local lu = require("luaunit")
local ResourceStore = require("adapter.resource_store")
local MemoryStore = require("persistence.memory_store")

local THE_FOUR = { "NyrUnderworld", "Nyr_Underworld", "nyrunderworld", "nyr_underworld" }

--- The resource's files as the resource sees them, and which writes the server
--- turns down. Installed over the two natives the store calls.
---
--- A write that works answers the number 1, not `true`, on both servers; one
--- that does not answers `false`. Both measured. A fake that answered `true`
--- would pass a check written as `== true`, which fails on every real server.
local function serve(refuses)
    local disk = {}
    _G.LoadResourceFile = function(_, path) return disk[path] end
    _G.SaveResourceFile = function(resource, path, text)
        if refuses(resource, path) then return false end
        disk[path] = text
        return 1
    end
    return disk
end

--- Measured with a probe resource under NyrProbe and nyr_probe. Enhanced 139
--- turns down SaveResourceFile under the folder's own spelling when it has a
--- capital, and takes the lower-cased spelling into the same folder, while every
--- other resource call there takes either. Legacy 35245 takes the exact spelling
--- and only that. The store asks under its own name, which is all this models.
local function enhanced_139(resource) return resource:find("%u") ~= nil end
local function legacy_35245() return false end
local function no_data_folder(_, path) return path:find("^data/") ~= nil end

local function store(name) return ResourceStore.new({ resource = name, folder = "data" }) end

local function read(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

--- Whether an ignore file names a path, with `*` as anything and a leading `/`
--- meaning the top of the repository.
local function ignores(file, path)
    for line in (read(file) or ""):gmatch("[^\r\n]+") do
        local pattern = line:match("^%s*(.-)%s*$"):gsub("^/", "")
        if pattern ~= "" and pattern:sub(1, 1) ~= "#" then
            local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
            if path:match(lua) then return true end
        end
    end
    return false
end

TestResourceStoreWritable = {}

function TestResourceStoreWritable:setUp()
    self.natives = { load = _G.LoadResourceFile, save = _G.SaveResourceFile }
end

function TestResourceStoreWritable:tearDown()
    _G.LoadResourceFile, _G.SaveResourceFile = self.natives.load, self.natives.save
end

function TestResourceStoreWritable:test_the_four_names_on_the_enhanced_server()
    serve(enhanced_139)
    local answers = {}
    for _, name in ipairs(THE_FOUR) do answers[name] = store(name):writable() end
    lu.assertEquals(answers, {
        NyrUnderworld = false, Nyr_Underworld = false,
        nyrunderworld = true, nyr_underworld = true,
    })
end

function TestResourceStoreWritable:test_the_same_names_on_the_legacy_server_are_not_refused()
    -- The same names save there, so a refusal here would be a city that will not
    -- start on a server where nothing is wrong. Nothing about a name is refused
    -- before the write has been tried.
    serve(legacy_35245)
    for _, name in ipairs(THE_FOUR) do
        lu.assertTrue(store(name):writable(), name)
    end
end

function TestResourceStoreWritable:test_a_capital_letter_is_named_and_so_is_the_name_to_use()
    serve(enhanced_139)
    local ok, why, remedy = store("NyrUnderworld"):writable()
    lu.assertFalse(ok)
    lu.assertStrContains(why, "NyrUnderworld/data")
    local said = table.concat(remedy, "\n")
    lu.assertStrContains(said, "capital letter")
    lu.assertStrContains(said, "ensure nyr_underworld")
end

function TestResourceStoreWritable:test_a_missing_folder_is_not_blamed_on_the_name()
    serve(no_data_folder)
    local ok, why, remedy = store("nyr_underworld"):writable()
    lu.assertFalse(ok)
    lu.assertStrContains(why, "nyr_underworld/data")
    local said = table.concat(remedy, "\n")
    lu.assertStrContains(said, "has to exist")
    lu.assertNotStrContains(said, "capital")
    lu.assertNotStrContains(said, "Rename")
end

function TestResourceStoreWritable:test_a_write_that_answers_yes_and_is_not_there_is_not_a_write()
    -- A server that says yes and keeps nothing where this store reads it back.
    _G.SaveResourceFile = function() return 1 end
    _G.LoadResourceFile = function() return nil end
    lu.assertFalse(store("nyr_underworld"):writable())
end

function TestResourceStoreWritable:test_what_an_earlier_boot_left_does_not_pass_for_a_write()
    serve(legacy_35245)
    lu.assertTrue(store("nyr_underworld"):writable())
    -- The next boot, on a server that now answers yes and writes nothing. The
    -- file from the boot before is still there to be read back.
    _G.SaveResourceFile = function() return 1 end
    lu.assertFalse(store("nyr_underworld"):writable())
end

function TestResourceStoreWritable:test_the_check_touches_no_collection_and_never_ships()
    local disk = serve(legacy_35245)
    lu.assertTrue(store("nyr_underworld"):writable())

    local written = {}
    for path in pairs(disk) do written[#written + 1] = path end
    local check = "data/" .. ResourceStore.CHECK_FILE
    lu.assertEquals(written, { check })

    -- No collection can be called this, so none is ever read from it or written
    -- over it.
    lu.assertFalse(MemoryStore.is_collection((ResourceStore.CHECK_FILE:gsub("%.json$", ""))))

    -- It is left in every city that has booted. Git and a release leave it where
    -- they leave the city's own files.
    lu.assertTrue(ignores(".gitignore", check), ".gitignore does not cover " .. check)
    lu.assertTrue(ignores(".nyrignore", check), ".nyrignore does not hold back " .. check)
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
