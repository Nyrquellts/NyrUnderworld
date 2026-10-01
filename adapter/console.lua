--- What the server console's commands decide, where a spec can reach it.
--
-- `adapter/server.lua` registers `nyr ...` and cannot be loaded by the suite, so
-- anything in those handlers that is a decision rather than a native call lives
-- here.

local Console = {}

--- A staff level as an owner typed it: 0 to stand somebody down, 1 moderator,
--- 2 admin, 3 owner. Anything else is refused with the usage line.
---
--- `level ~= 0 and math.tointeger(level) or nil` turned every mistake into a
--- stand-down: `nyr staff <id> abc`, `1.5`, or a forgotten level quietly took an
--- admin's powers away and printed "stood down" as if that had been asked for.
function Console.staff_level(typed)
    local number = tonumber(typed)
    local level = number and math.tointeger(number)
    if level == nil or level < 0 or level > 3 then
        return nil, "nyr staff <character id> <1 moderator | 2 admin | 3 owner | 0 none>"
    end
    return level
end

--- What to say before a shutdown save that a stopped resource cannot hear the
--- answer to. Nil when there is nothing worth saying.
---
--- A database driver's call yields, and FiveM never resumes a coroutine of a
--- resource that has stopped: whatever is not handed over before the first wait
--- is not handed over at all.
function Console.shutdown_note(uses_database, commits_whole)
    if not uses_database then return nil end
    if commits_whole then
        return "handing the city to the database as one transaction; a stopped resource cannot hear the " ..
               "answer, so `nyr store` after the next start says whether it landed"
    end
    return "this database driver writes a statement at a time, and a stopping resource gets only the " ..
           "first one out: run `nyr save` and wait for \"written down\" before stopping"
end

return Console
