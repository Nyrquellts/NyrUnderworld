--- A boot-scoped storage identity. Changes latch closed, even if reverted.
--- The identity is compared in memory; no paths, configuration or secrets are logged.
local Guard = {}
Guard.__index = Guard
local function identity(read)
    local ok, value = pcall(read)
    if not ok or type(value) ~= "table" then return nil end
    local copy = {}
    for key, item in pairs(value) do
        if type(key) ~= "string" or type(item) ~= "string" then return nil end
        copy[key] = item
    end
    if not copy.path or copy.path == "" or not copy.configuration then return nil end
    return copy
end
function Guard.new(read)
    local first = identity(read)
    return setmetatable({ read = read, first = first, blocked = first == nil }, Guard)
end
function Guard:invalidate() self.blocked = true end
function Guard:check()
    if self.blocked then return false, "storage identity changed or unavailable; restart after investigation" end
    local current = identity(self.read)
    if not current then self.blocked = true
    else
        for key, value in pairs(self.first) do if current[key] ~= value then self.blocked = true end end
        for key, value in pairs(current) do if self.first[key] ~= value then self.blocked = true end end
    end
    if self.blocked then return false, "storage identity changed or unavailable; restart after investigation" end
    return true
end
function Guard:driver(original)
    local wrapped = {}
    for key, value in pairs(original) do wrapped[key] = value end
    for _, name in ipairs({ "query", "execute", "transaction" }) do
        local operation = original[name]
        if operation then
            wrapped[name] = function(...)
                local ok, why = self:check()
                if not ok then return nil, why end
                local result = table.pack(operation(...)) -- may yield in the real SQL driver
                ok, why = self:check()
                if not ok then return nil, "database outcome UNKNOWN after storage identity change" end
                return table.unpack(result, 1, result.n)
            end
        end
    end
    return wrapped
end
return Guard
