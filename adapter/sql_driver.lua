--- The two functions the database store needs, over whatever MySQL resource
--- this server already runs.
--
-- NYR Underworld ships no database library and never will. Every FiveM server
-- that wants a database already has one installed, and shipping a second copy
-- of it is how two resources end up fighting over a connection pool. So this
-- looks for the one that is there and speaks to it.
--
-- Supported, in the order they are preferred:
--
--   oxmysql      what nearly every current server runs
--   mysql-async  older, still common on long-lived servers
--
-- Anything else: the store is not started, the owner is told which resources
-- were looked for, and the server keeps running on files. A city that saves to
-- disk is a working city; a city that thinks it saved and did not is not.
--
-- What is and is not proved here
-- ------------------------------
-- Everything in this file except one call per driver is exercised by
-- spec/sql_driver_spec.lua against a fake `exports` table: which resource is
-- chosen, what happens when none is there, how an error becomes `nil, why`,
-- how a nil row count becomes a success. The one line per driver that actually
-- reaches the database cannot be proved without a database, so it is one line,
-- it is named here, and `nyr store check` runs it against the real thing on
-- the owner's server as the first thing they do:
--
--   oxmysql      exports.oxmysql:query_async / :execute_async
--   mysql-async  exports['mysql-async']:mysql_sync_fetch_all / :mysql_sync_execute
--
-- Both are the blocking form, which is what lets the synchronous store
-- contract sit on an asynchronous library. Blocking here means yielding the
-- calling coroutine, not the server, and it is why a flush runs on its own
-- thread rather than inside an event handler.

local SqlDriver = {}

--- Each entry: the resource name, and how to build the two functions from its
--- export. Kept as data so adding a driver is a table entry and a spec, not a
--- new branch in the middle of a function.
local DRIVERS = {
    {
        name = "oxmysql",
        build = function(export)
            return {
                query = function(sql, params)
                    local ok, rows = pcall(function()
                        return export:query_async(sql, params or {})
                    end)
                    if not ok then return nil, tostring(rows) end
                    if type(rows) ~= "table" then
                        return nil, ("oxmysql answered with %s, not rows"):format(type(rows))
                    end
                    return rows
                end,
                execute = function(sql, params)
                    local ok, affected = pcall(function()
                        return export:execute_async(sql, params or {})
                    end)
                    if not ok then return nil, tostring(affected) end
                    -- The pcall is the error signal, not the return value. DDL
                    -- answers with nothing on some versions, and reading that
                    -- as a failure would make every boot report a broken table
                    -- it had just created.
                    return tonumber(affected) or 0
                end,
                -- Several statements committed as one, in one call. oxmysql
                -- 2.14.1 takes `{ query, values }` rows, begins, runs each,
                -- commits, and rolls back on any failure, answering true or
                -- false (src/database/rawTransaction.ts, read in the vendored
                -- source). One call matters beyond atomicity: the database has
                -- every row before this resource waits for the answer, so a
                -- stop that never resumes the wait still lands the checkpoint.
                transaction = function(statements)
                    local queries = {}
                    for index, statement in ipairs(statements) do
                        queries[index] = { query = statement.sql, values = statement.params or {} }
                    end
                    local ok, committed = pcall(function()
                        return export:transaction_async(queries)
                    end)
                    if not ok then return nil, tostring(committed) end
                    if committed ~= true then
                        return nil, "the database rolled the checkpoint back; oxmysql printed why on the console"
                    end
                    return true
                end,
            }
        end,
    },
    {
        name = "mysql-async",
        build = function(export)
            return {
                query = function(sql, params)
                    local ok, rows = pcall(function()
                        return export:mysql_sync_fetch_all(sql, params or {})
                    end)
                    if not ok then return nil, tostring(rows) end
                    if type(rows) ~= "table" then
                        return nil, ("mysql-async answered with %s, not rows"):format(type(rows))
                    end
                    return rows
                end,
                execute = function(sql, params)
                    local ok, affected = pcall(function()
                        return export:mysql_sync_execute(sql, params or {})
                    end)
                    if not ok then return nil, tostring(affected) end
                    return tonumber(affected) or 0
                end,
            }
        end,
    },
}

SqlDriver.SUPPORTED = (function()
    local names = {}
    for _, driver in ipairs(DRIVERS) do names[#names + 1] = driver.name end
    return names
end)()

--- env.state(resource)   -> the resource's state string; GetResourceState
--- env.export(resource)  -> that resource's export table; exports[resource]
--- Injected so the choosing can be tested without a server under it.
local function environment(env)
    env = env or {}
    return {
        state = env.state or function(name)
            return GetResourceState and GetResourceState(name) or "missing"
        end,
        export = env.export or function(name)
            return exports[name]
        end,
    }
end

--- Find a driver and build it.
---
--- `prefer` names one resource and refuses the rest, for an owner running two
--- and wanting to say which. "auto", or nothing, takes the first that is up.
---
--- Returns driver, name on success and nil, why on failure. `why` names what
--- was looked for, because "no database" with no list is a support ticket.
function SqlDriver.find(prefer, env)
    env = environment(env)
    -- Written as an if, not as `cond and nil or prefer`. That idiom cannot
    -- produce nil: `true and nil` is nil, and `nil or prefer` is prefer, so
    -- "auto" survived and was then refused as an unknown driver. A boot found
    -- it; the spec below is what stops it coming back.
    if prefer == nil or prefer == "" or prefer == "auto" then
        prefer = nil
    end

    if prefer then
        local known = false
        for _, driver in ipairs(DRIVERS) do
            if driver.name == prefer then known = true end
        end
        if not known then
            return nil, ("%s is not a database resource this knows; it speaks to %s")
                :format(prefer, table.concat(SqlDriver.SUPPORTED, " and "))
        end
    end

    local looked = {}
    for _, driver in ipairs(DRIVERS) do
        if prefer == nil or prefer == driver.name then
            local state = env.state(driver.name)
            looked[#looked + 1] = ("%s (%s)"):format(driver.name, tostring(state))
            if state == "started" then
                local export = env.export(driver.name)
                if type(export) == "table" or type(export) == "userdata" then
                    return driver.build(export), driver.name
                end
                looked[#looked] = ("%s (started, but its exports are not there)")
                    :format(driver.name)
            end
        end
    end

    return nil, ("no database resource is running. Looked for: %s")
        :format(table.concat(looked, ", "))
end

--- Prove the connection rather than assume it. Runs the cheapest statement
--- there is and reports what came back, so an owner learns at boot instead of
--- when the first player tries to save.
function SqlDriver.check(driver)
    local rows, err = driver.query("SELECT 1 AS ok", {})
    if rows == nil then return false, tostring(err) end
    if type(rows) ~= "table" or #rows == 0 then
        return false, "the database answered, but with no rows; check the user's permissions"
    end
    return true
end

return SqlDriver
