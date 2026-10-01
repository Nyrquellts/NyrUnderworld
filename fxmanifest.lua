fx_version 'cerulean'

-- Both versions, and this line was measured rather than reasoned about.
--
-- FiveM for GTAV Enhanced is served by a different program, not a newer build
-- of the same one: `cfx-server.exe` (build 139), distributed separately from
-- the `FXServer.exe` everyone has been running for years (build 35245). They
-- disagree about this list, so it was tested on both, with the resource
-- otherwise untouched:
--
--                                  legacy 35245   enhanced 139
--     games { 'gta5' }                 starts        starts
--     games { 'gta5enhanced' }        refused        starts
--     games { 'gta5', 'gta5enhanced'}  starts        starts
--     games { 'rdr3' }                refused       refused
--     games { 'nyr_not_a_game' }      refused       refused
--
-- The last two rows are the control. Without them the first three prove
-- nothing, because a list nobody checks accepts everything; with them the gate
-- is known to be real, and "Resource is not compatible with the current game"
-- is what refusal looks like.
--
-- So `gta5enhanced` is a token the Enhanced server genuinely recognises -- an
-- earlier version of this comment called it invented, on the strength of it
-- appearing nowhere in the legacy binaries, which was true and was the wrong
-- place to look. Legacy does not know it, but a `games` list is satisfied by
-- any one member, so legacy is satisfied by `gta5` and ignores the rest.
--
-- Declaring both is therefore the honest declaration: it says what the resource
-- supports instead of relying on Enhanced continuing to answer to `gta5`, and
-- it is the row measured to start on both.
--
-- What actually makes this resource run on both is that it asks almost nothing
-- of the game. The simulation is pure Lua with no natives in it at all, there
-- are no streamed assets, no models, no textures and no map data, and the few
-- natives the adapter does use are long-standing ones. None of the breaking
-- changes Cfx lists for Enhanced touches it: it stores nothing in the key-value
-- database, registers no remote commands and is not a resource builder. There
-- is no `stream/` folder to rename to `stream_enhanced/` either.
--
-- See the compatibility section of README.md for what was checked and how.
games { 'gta5', 'gta5enhanced' }

name 'nyr_underworld'
author 'Nyr'
description 'The city remembers.'
version '0.1.0-rc.6'

lua54 'yes'

-- The simulation is server-only, and that is a security decision rather than a
-- structural one. Every rule about money, ownership, crime and consequence
-- lives on the server, where a client cannot reach it. The client sends
-- requests and draws what it is told.
--
-- Only the two entry points are listed. Everything else is pulled in by
-- adapter/loader.lua, which reads modules out of this resource on demand, so
-- the same files run under a plain Lua interpreter in the test suite and
-- inside FXServer without a build step or a second copy.
server_scripts {
    'adapter/loader.lua',
    'adapter/server.lua',
}

-- Order matters and there is no module system to enforce it: client scripts
-- share one namespace rather than importing each other, so each file here must
-- come after whatever defines what it uses. `client_state` defines
-- NyrClientState, which `nui_state` reads at load time; `client` defines
-- NyrAsk, which `nui` calls.
client_scripts {
    'adapter/readiness.lua',
    'adapter/client_state.lua',
    'adapter/nui_state.lua',
    -- Before both of the files that register commands, because it is the list
    -- they both read their names out of.
    'adapter/commands.lua',
    'adapter/client.lua',
    'adapter/nui.lua',
    -- After `nui`, because pressing a key at a marker opens one of its screens.
    'adapter/world.lua',
    'adapter/spawn.lua',
    'adapter/devclient.lua',
}

-- The drawn interface. A NUI page is a browser inside the game, loading off
-- the player's own disk with no network behind it, so there are no web fonts,
-- no external images and no CDN: three files, with original inline SVG icons.
ui_page 'adapter/nui/index.html'

files {
    'adapter/nui/index.html',
    'adapter/nui/style.css',
    'adapter/nui/app.js',
}

dependencies {
    '/server:7290',
    '/onesync',
}
