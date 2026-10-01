-- Drive the real store and write down exactly what it sent, so the same
-- statements can be replayed against a real server.
local json = require("support.json")
local DatabaseStore = require("persistence.database_store")
local FakeSql = require("spec.fake_sql")

local driver = FakeSql.new()
local store = DatabaseStore.new({ driver = driver })
assert(store:ensure_schema())

store:put("world", "clock", { day = 7, ms = 61860000 })
store:put("chr", "chr_0001", { name = "Vic Ortega", wallet = 218050, slots = 30 })
store:put("chr", "chr_0002", { name = "Rosa Lindqvist", wallet = 81220 })
store:flush()

store:put("chr", "chr_0001", { name = "Vic Ortega", wallet = 168050, slots = 30 })
store:delete("chr", "chr_0002")
store:flush()

store:collections()

local out = {}
for _, s in ipairs(driver.statements) do
    out[#out + 1] = { sql = s.sql, params = s.params, kind = s.kind }
end
io.write(json.encode(out, { indent = true }))
