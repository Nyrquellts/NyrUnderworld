--- A module loader, so the same files run in a test and on a server.
--
-- A FiveM resource has one shared namespace and no module system: every file
-- listed in the manifest is executed into the same globals, in order. That is
-- workable for a script and unworkable for a simulation with fifty modules
-- that need to be testable on their own.
--
-- So the resource lists two entry points and this loader supplies `require`
-- over them, reading each module out of the resource on demand. The modules
-- themselves are ordinary Lua with ordinary returns, which is why they run
-- unchanged under a plain interpreter in the spec suite.
--
-- On the `load` call below: the source it compiles comes from this resource
-- and from nowhere else. LoadResourceFile reads from the resource directory on
-- the server disk; the name is turned into a path and the path is never taken
-- from a player, a database or the network. A static check will flag dynamic
-- code here, and it should; this is the one place in the project that has any,
-- and it is a module loader.

local resource = GetCurrentResourceName()
local cache = {}
local loading = {}

local function module_path(name)
    if type(name) ~= "string" or name == "" then
        error("require takes a module name like domain.money", 3)
    end
    -- No leading dots, no parent segments, no slashes: a module name is a
    -- dotted identifier path and nothing else, so nothing can be talked into
    -- reaching outside the resource.
    --
    -- Checked segment by segment rather than with one pattern. Lua patterns
    -- are not regular expressions: a quantifier cannot be applied to a group,
    -- so `^[%a_][%w_]*(%.?[%w_]*)*$` does not mean what it looks like it
    -- means, and it rejected every dotted name including core.world. That is
    -- invisible in a spec, because the loader only ever runs inside FiveM;
    -- it took a boot to find.
    if name:find("%.%.") or name:sub(1, 1) == "." or name:sub(-1) == "." then
        error(("%s is not a module name"):format(name), 3)
    end
    for segment in name:gmatch("[^%.]+") do
        if not segment:match("^[%a_][%w_]*$") then
            error(("%s is not a module name"):format(name), 3)
        end
    end
    return (name:gsub("%.", "/")) .. ".lua"
end

function require(name)
    local cached = cache[name]
    if cached ~= nil then return cached end
    if loading[name] then
        error(("%s requires itself, directly or through something it requires"):format(name), 2)
    end

    local path = module_path(name)
    local source = LoadResourceFile(resource, path)
    if not source then
        error(("module %s is not in this resource (looked for %s)"):format(name, path), 2)
    end

    local chunk, why = load(source, ("@@%s/%s"):format(resource, path), "t")
    if not chunk then
        error(("module %s will not compile: %s"):format(name, tostring(why)), 2)
    end

    loading[name] = true
    local ok, value = pcall(chunk, name)
    loading[name] = nil
    if not ok then
        error(("module %s failed while loading: %s"):format(name, tostring(value)), 2)
    end
    if value == nil then value = true end
    cache[name] = value
    return value
end

--- What has been loaded, for a console command and for a boot report.
function nyr_loaded_modules()
    local names = {}
    for name in pairs(cache) do names[#names + 1] = name end
    table.sort(names)
    return names
end
