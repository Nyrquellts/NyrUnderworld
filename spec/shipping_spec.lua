--- What reaches a buyer from the top of this repository.
---
--- The release stage ships every file it does not recognise as development.
--- Directories are easy to recognise; a file dropped at the top is not. A prompt
--- for the next agent session was committed there, the stage went from 61 files
--- to 62, and the only sign was a number nobody compares: the zip a buyer
--- downloads carried internal process notes and this machine's paths.
---
--- So the top of the repository is held to a rule rather than a count. A file
--- there either ships on purpose, and is named in `SHIPS` below, or is held back
--- by `.nyrignore`. Anything else fails here, before a release does it quietly.
local modname = ...
local lu = require("luaunit")

--- What a server loads and a buyer reads, at the top. Nothing else ships there.
local SHIPS = {
    ["fxmanifest.lua"] = true,
    ["config.lua"] = true,
    ["LICENSE"] = true,
    ["README.md"] = true,
    ["audit-accepted.json"] = true,
}

local function read(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("a")
    handle:close()
    return text
end

--- The patterns `.nyrignore` holds back, read the way the stage reads them.
local function held_back()
    local patterns = {}
    for line in (read(".nyrignore") or ""):gmatch("[^\r\n]+") do
        local pattern = line:match("^%s*(.-)%s*$")
        if pattern ~= "" and pattern:sub(1, 1) ~= "#" then
            patterns[#patterns + 1] = pattern
        end
    end
    return patterns
end

--- Whether a name matches a pattern: `*` is anything, everything else literal,
--- and the whole name has to match -- the same rule the stage applies.
local function matches(name, pattern)
    local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
    return name:match(lua) ~= nil
end

local function is_held(name, patterns)
    for _, pattern in ipairs(patterns) do
        if matches(name, pattern) then return true end
    end
    return false
end

--- The names that would ship without anybody having decided they should.
local function strays(names, patterns)
    local out = {}
    for _, name in ipairs(names) do
        if not SHIPS[name] and not is_held(name, patterns) then
            out[#out + 1] = name
        end
    end
    return out
end

--- Every file at the top of the repository, asked of the filesystem.
local function top_files()
    for _, command in ipairs({ 'dir /b /a-d 2>nul', 'ls -1Ap 2>/dev/null' }) do
        local pipe = io.popen(command)
        if pipe then
            local names = {}
            for line in pipe:lines() do
                local name = line:gsub("\r$", "")
                if name ~= "" and name:sub(-1) ~= "/" then names[#names + 1] = name end
            end
            pipe:close()
            if #names > 0 then
                table.sort(names)
                return names
            end
        end
    end
    return {}
end

--- The two scripts that copy this resource into a local server, to play on and
--- to record from. Both hold files back by name, with lists kept by hand, and
--- those fell behind the stage with nothing failing: robocopy's /XD skips
--- directories only, so a worktree's .git file was copied, and NEXT_SESSION.md
--- and .nyrignore were added to the repository after the lists were written.
local COPIES = { "tools/devserver.cmd", "docs/store-page/capture_session.ps1" }

--- The names a script's robocopy call gives after `switch`, "/XD" or "/XF".
local function robocopy_names(text, switch)
    -- One call over several lines: cmd continues with ^, PowerShell with `.
    local joined = ("\n" .. text):gsub("[%^`][ \t]*\r?\n", " ")
    local call = joined:match("\n[ \t]*robocopy%s[^\r\n]*")
    local names, taking = {}, false
    for word in (call or ""):gmatch("%S+") do
        if word:match("^[>|]") then break end
        if word:sub(1, 1) == "/" then
            taking = word:upper() == switch
        elseif taking then
            names[#names + 1] = (word:gsub('^"(.*)"$', "%1"))
        end
    end
    return names
end

--- Whether robocopy holds a name back: `*` and `?` are wildcards, and case does
--- not count on Windows.
local function robocopy_holds(patterns, name)
    for _, pattern in ipairs(patterns) do
        local lua = pattern:lower():gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
        lua = lua:gsub("%*", ".*"):gsub("%?", ".")
        if name:lower():match("^" .. lua .. "$") then return true end
    end
    return false
end

--- What a copy with these /XF names gets wrong at the top: a file the stage
--- holds back that it copies, or one the stage ships that it leaves out.
local function copy_disagreements(names, held)
    local out = {}
    for _, name in ipairs(names) do
        local excluded = robocopy_holds(held, name)
        if excluded and SHIPS[name] then
            out[#out + 1] = "leaves out " .. name
        elseif not excluded and not SHIPS[name] then
            out[#out + 1] = "copies " .. name
        end
    end
    return out
end

TestShipping = {}

function TestShipping:test_the_listing_itself_can_see_the_top_of_the_repository()
    -- A rule checked against an empty list holds for everything, which is how
    -- a check comes to pass while looking at nothing.
    local names = {}
    for _, name in ipairs(top_files()) do names[name] = true end
    lu.assertTrue(names["fxmanifest.lua"], "the listing did not see the manifest")
    lu.assertTrue(names["README.md"], "the listing did not see the readme")
end

function TestShipping:test_a_file_nobody_decided_about_is_caught()
    -- On a clean tree there is nothing to catch, so the live check below would
    -- pass with the rule switched off. This is the rule, against a stray.
    lu.assertEquals(strays({ "fxmanifest.lua", "LEDGER.md", "NOTES.md", "LICENSE" },
                           { "LEDGER.md" }), { "NOTES.md" })
end

function TestShipping:test_nothing_at_the_top_ships_by_accident()
    lu.assertEquals(strays(top_files(), held_back()), {},
        "these would go into the zip a buyer downloads: name them in .nyrignore, "
        .. "or in SHIPS here if a buyer is meant to have them")
end

function TestShipping:test_what_a_buyer_needs_is_not_held_back()
    local patterns = held_back()
    for name in pairs(SHIPS) do
        lu.assertFalse(is_held(name, patterns), name .. " is held back and a buyer needs it")
    end
end

function TestShipping:test_the_status_page_does_not_ship()
    lu.assertTrue(is_held("STATUS.md", held_back()))
end

function TestShipping:test_the_git_file_of_a_worktree_does_not_ship()
    -- The live check above sees `.git` only in a git worktree, where it is a
    -- file. In the main checkout it is a directory, the listing skips it, and
    -- the live check passes there with `.git` gone from .nyrignore.
    lu.assertTrue(is_held(".git", held_back()))
end

function TestShipping:test_patterns_match_whole_names_the_way_the_stage_does()
    lu.assertTrue(matches("NEXT_SESSION.md", "NEXT_SESSION.md"))
    lu.assertTrue(matches("notes-1.md", "notes-*.md"))
    -- A dot is a dot, not any character, and a pattern is the whole name.
    lu.assertFalse(matches("LEDGERxmd", "LEDGER.md"))
    lu.assertFalse(matches("OLD_LEDGER.md", "LEDGER.md"))
    lu.assertFalse(matches("LEDGER.md.txt", "LEDGER.md"))
end

function TestShipping:test_the_local_server_copies_hold_back_the_files_the_stage_does()
    local names = top_files()
    for _, script in ipairs(COPIES) do
        local held = robocopy_names(read(script) or "", "/XF")
        lu.assertEquals(copy_disagreements(names, held), {},
            script .. " stages the top of the resource unlike a release: fix its /XF")
    end
end

function TestShipping:test_the_copies_hold_back_dot_git_as_a_directory_and_as_a_file()
    -- A directory in the main checkout and a file in a worktree. The rule above
    -- sees only the one it runs in, so both are asked for by name.
    for _, script in ipairs(COPIES) do
        local text = read(script) or ""
        lu.assertTrue(robocopy_holds(robocopy_names(text, "/XD"), ".git"),
            script .. " copies a checkout's .git directory")
        lu.assertTrue(robocopy_holds(robocopy_names(text, "/XF"), ".git"),
            script .. " copies a worktree's .git file")
    end
end

--- The names inside a Python tuple assigned to `name`, one line or several.
local function python_tuple(text, name)
    local block = text:match("\n" .. name .. "%s*=%s*(%b())")
    local names = {}
    for entry in (block or ""):gmatch('"([^"]+)"') do names[#names + 1] = entry end
    return names
end

function TestShipping:test_the_rig_holds_back_every_directory_the_local_server_does()
    -- docs/rig/rig.py stages the resource for a hunt the way the release
    -- stage does, from its own lists. A directory devserver.cmd holds back
    -- that the rig copies is a hunt run on files a buyer never gets. `data`
    -- is the exception: devserver skips it to protect a played city, the rig
    -- stages a fresh one and ships data/README.md as the release does.
    local rig = read("docs/rig/rig.py")
    lu.assertNotNil(rig, "docs/rig/rig.py is not where this spec expects it")
    local held = {}
    for _, list in ipairs({ "DEV_DIRS", "TOOL_DIRS" }) do
        for _, name in ipairs(python_tuple(rig, list)) do held[name] = true end
    end
    lu.assertTrue(held["spec"] and held[".git"], "could not read the rig's lists")
    local missing = {}
    for _, name in ipairs(robocopy_names(read("tools/devserver.cmd") or "", "/XD")) do
        if name ~= "data" and not held[name] then missing[#missing + 1] = name end
    end
    lu.assertEquals(missing, {}, "tools/devserver.cmd holds these back and docs/rig/rig.py stages them")
end

function TestShipping:test_a_python_tuple_is_read_across_lines()
    local text = '\nDEV_DIRS = ("spec", "tools",\n            "run")\nTOOL_DIRS = (".git",)\n'
    lu.assertEquals(python_tuple(text, "DEV_DIRS"), { "spec", "tools", "run" })
    lu.assertEquals(python_tuple(text, "TOOL_DIRS"), { ".git" })
    lu.assertEquals(python_tuple(text, "NOPE"), {})
end

function TestShipping:test_a_copy_that_disagrees_with_the_stage_is_caught()
    -- On a clean tree the rule has nothing to catch. This is the rule, against
    -- both mistakes, read out of both kinds of script.
    local cmd = 'robocopy "%ROOT%" "%DEST%" ^\n    /MIR /R:1 ^\n    /XD .git spec ^\n'
        .. '    /XF LEDGER.md fxmanifest.lua >nul\n'
    local ps1 = 'robocopy $Root "$Session\\x" /MIR `\n    /XD .git data `\n'
        .. '    /XF .git "NEXT_SESSION.md" | Out-Null\n'
    lu.assertEquals(robocopy_names(cmd, "/XD"), { ".git", "spec" })
    lu.assertEquals(robocopy_names(ps1, "/XF"), { ".git", "NEXT_SESSION.md" })
    local top = { ".git", "fxmanifest.lua", "LEDGER.md", "LICENSE" }
    lu.assertEquals(copy_disagreements(top, robocopy_names(cmd, "/XF")),
                    { "copies .git", "leaves out fxmanifest.lua" })
    -- robocopy's names, not the stage's: wildcards, and case does not count.
    lu.assertTrue(robocopy_holds({ "*.cfg" }, "server.cfg"))
    lu.assertTrue(robocopy_holds({ "LEDGER.md" }, "ledger.MD"))
    lu.assertFalse(robocopy_holds({ "LEDGER.md" }, "LEDGERxmd"))
    lu.assertFalse(robocopy_holds({ "LEDGER.md" }, "OLD_LEDGER.md"))
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
