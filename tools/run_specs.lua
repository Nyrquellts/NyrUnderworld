--- Every spec, one command, one exit code, one count.
--
-- luaunit rather than busted: busted's luasystem dependency needs a C
-- compiler this machine does not have, and a test framework that cannot be
-- installed is not a test framework. luaunit is pure Lua and installs clean.
--
--   tools\spec.cmd
--
-- Each spec is `require`d, not spawned. Requiring registers its Test* globals
-- with luaunit and skips the spec's own runner, so the whole domain reports as
-- a single pass/fail. Every spec stays runnable on its own for a tight loop.

local lu = require("luaunit")

-- The restart specs write real files under run/spec. spec.cmd makes the folder;
-- run straight from a shell without it, twenty-six of them failed on a folder
-- that did not exist rather than on anything they test.
local keep = io.open("run/spec/.keep", "a")
if keep then
    keep:close()
else
    os.execute('mkdir "run\\spec" 2>nul')
    os.execute("mkdir -p run/spec 2>/dev/null")
end

local specs = {
    "spec.money_spec",
    "spec.json_spec",
    "spec.settings_spec",
    "spec.ledger_spec",
    "spec.id_spec",
    "spec.entity_spec",
    "spec.ownership_spec",
    "spec.inventory_spec",
    "spec.memory_spec",
    "spec.standing_decay_spec",
    "spec.store_spec",
    "spec.resource_store_spec",
    "spec.database_store_spec",
    "spec.sql_driver_spec",
    "spec.repository_spec",
    "spec.events_spec",
    "spec.commands_spec",
    "spec.clock_spec",
    "spec.scheduler_spec",
    "spec.world_spec",
    "spec.characters_spec",
    "spec.bridge_spec",
    "spec.devbridge_spec",
    "spec.inventory_system_spec",
    "spec.memory_system_spec",
    "spec.work_spec",
    "spec.property_spec",
    "spec.vehicles_spec",
    "spec.police_spec",
    "spec.banking_spec",
    "spec.shops_spec",
    "spec.health_spec",
    "spec.gangs_spec",
    "spec.phone_spec",
    "spec.fencing_spec",
    "spec.admin_spec",
    "spec.client_state_spec",
    "spec.readiness_spec",
    "spec.drain_spec",
    "spec.storage_guard_spec",
    "spec.server_resilience_spec",
    "spec.nui_spec",
    "spec.player_commands_spec",
    "spec.addons_spec",
    "spec.shipping_spec",
    "spec.dev_bridge_spec",
    "spec.spawn_spec",
    "spec.city_spec",
    "spec.console_spec",
    "spec.fuzz_spec",
    -- Last, and it checks this list: a spec file that is not named here is
    -- never run, and the only sign is a test count that did not go up.
    "spec.suite_spec",
}

for _, spec in ipairs(specs) do
    require(spec)
end

os.exit(lu.LuaUnit.run(table.unpack(arg)))
