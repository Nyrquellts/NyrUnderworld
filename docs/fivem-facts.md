# OneSync cannot be set from server.cfg

OneSync is an internal convar: setting it in `server.cfg` is answered with "cannot be changed" and does not take, and a resource whose manifest declares `/onesync` is then skipped with no error (`found 4, started 0`). Set it on the server's command line. Measured on FXServer 35245 for NYR Underworld (LEDGER.md lines 146-150).

# sv_lan does not skip the licence key check on either FiveM server

With `sv_lan true`, FXServer 35245 still looked up a bogus key from `server.cfg` and rejected it across six measured cases, and the Enhanced server with no key answered "A valid license check is required to run this server. No sv_licenseKey specified." LAN mode changes identity checks for players, not the server's own licence. Measured for NYR Underworld (LEDGER.md lines 154-168, commit affadb3).

# FiveM for GTA V Enhanced is a separate server program, cfx-server build 139

The Enhanced server is `cfx-server.exe`, not a newer `FXServer.exe`: it has no `citizen` directory (`system_resources` stands in), refuses to start without SSE3 and POPCNT, and expects `stream_enhanced/` where legacy expects `stream/`. Test a resource on both programs. Measured for NYR Underworld (LEDGER.md lines 176-180).

# The games list in fxmanifest is a real gate that differs between the two servers

`games { 'gta5' }` starts a resource on both legacy 35245 and Enhanced 139, `games { 'gta5enhanced' }` alone starts only on Enhanced, and both servers refuse `rdr3` and an invented token with "Resource is not compatible with the current game". Declaring `{ 'gta5', 'gta5enhanced' }` starts on both. Measured for NYR Underworld (LEDGER.md lines 192-198).

# info.json identifies which FiveM server is answering, with no client

`/info.json` on legacy answers `server: FXServer-master SERVER v1.0.0.35245 win32`, `gamename: gta5`, `sv_enforceGameBuild: 3258`; on Enhanced it answers `server: FXServer-early-access b139 win32`, `gamename: gta5enhanced` with no enforced build; both report `onesync: true`. It can answer while resources are still starting, so poll until a resource is listed rather than reading once. Measured for NYR Underworld (LEDGER.md lines 225-246).

# netPort reads 0 at script load on the Enhanced server

`GetConvarInt("netPort")` read 30150 on Enhanced and 30151 on legacy when asked inside a thread after the resource started, but 0 on Enhanced when asked at script load; legacy answered the real port both times. Read the port on a thread, and never print a URL built from 0. Measured for NYR Underworld (LEDGER.md lines 754-768).

# On the Enhanced server a resource folder with a capital letter cannot save files

With the resource folder named `NyrUnderworld` or `Nyr_Underworld`, every `SaveResourceFile` failed on cfx-server 139 (112 failures, 0 files over 90 seconds), while `nyrunderworld` and `nyr_underworld` saved cleanly and legacy saved under all four names. On Enhanced only the lower-cased spelling saves while `LoadResourceFile` and `GetResourcePath` accept either; on legacy only the exact spelling works. Ship and stage resources under an all-lowercase folder name. Measured for NYR Underworld (LEDGER.md lines 2175-2198).

# SaveResourceFile returns 1, creates no folders, and reads back at once

A successful `SaveResourceFile` returns the number `1`, not `true`, on both servers, and the file reads back immediately. It does not create directories: a resource shipped without its `data/` folder failed every save, returning false with no reason. Treat any truthy result as success and create folders in the shipped archive. Measured for NYR Underworld (LEDGER.md lines 142-145, 2199-2201).

# A restarted resource does not send a newly added file to a connected client

After adding a new client script, `restart` alone left an already-connected client without it; `refresh` followed by `restart` delivered it with no reconnect. FiveM's client Lua also has no `require`, so a script that falls back to `require` throws before anything else in it runs. Measured for NYR Underworld (LEDGER.md lines 1076-1083).

# A FiveM join handshake is plain HTTP and can be read without a game client

`/info.json` (identity, resources, convars), `/dynamic.json` (fill level) and `/players.json` (who is on) all answer over a plain socket, so a tool can learn what a server is running and whether anyone is connected without GTA V installed. Measured for NYR Underworld (LEDGER.md lines 218-223).

# cfx-server 139 locks out an address that opens connections too fast

From 127.0.0.1, a new connection per request was refused after 25 in 0.68 s, one new connection per second was refused after 33, one every two seconds succeeded 40 of 40, and one kept-alive connection answered 400 of 400 over 45 s; the server answered again within 10 s of the refusals stopping. The lockout also refuses the game client's own join from that address. Keep one connection. Measured for NYR Underworld (LEDGER.md lines 1751-1757).

# cfx-server 139 closes a connection silently on a request line of a few kilobytes

In a storm of 1,219 requests, the Enhanced server closed the TCP connection with no response on 27 whose request line reached a few kilobytes, while legacy closed none of them and took 232 connections with no lockout. A client that reads a closed connection as a dead server stops early; reconnect and ask again. A 64 KB query is answered with an HTML 414 page, not JSON. Measured for NYR Underworld (LEDGER.md lines 2686-2690).

# SetHttpHandler answers from the moment the script loads, and an error leaves the request hanging

A resource's HTTP handler starts answering before any of that resource's startup threads run, so a route can be hit before the resource has read its own state. A Lua error thrown inside the handler left the request unanswered on Enhanced, which looks exactly like a dead server; wrap every route in `pcall` and answer 500 with what threw. Measured for NYR Underworld (LEDGER.md lines 1851-1852, 2669-2685).

# The legacy server ignored rcon_password set only in server.cfg

On FXServer 35245 every rcon command answered "The server must set rcon_password" until the same password was also passed on the server's command line; a stop sent over rcon that way never happened, and a tool that did not read the answer back reported a restart that did not occur. Pass the password on the command line and read the effect back. Measured for NYR Underworld (LEDGER.md lines 2691-2694).

# GetPlayerIdentifierByType throws for a player id nobody holds on the Enhanced server

Asked about a player id that is not connected, `GetPlayerIdentifierByType` on cfx-server 139 throws "Expected an numeric client id as a argument" instead of returning nil, so a handler that asks about an arbitrary id dies unanswered. Check the id against `GetPlayers()` before asking any identifier native. Measured for NYR Underworld (LEDGER.md lines 2679-2682).

# FiveM natives encode booleans both ways, and IsEntityVisible answers 1

Some natives return real `true` and `false`, others `0` and `1`, with nothing at the call site to say which; `IsEntityVisible` on a player's own ped returned `1`, so a check written as `== true` read a visible ped as invisible. `GetNumberOfPedDrawableVariations` always returns a number, never nil. Normalise native answers before comparing. Measured with a native probe for NYR Underworld (LEDGER.md lines 1259-1285).

# A ped placed above ground that has not streamed in falls through the map

At Integrity Way, Apt 28, a ped spawned at z 89 (the interior's real height, with nothing opening the interior) landed about 33 m lower at z 56; z 40 at the same x and y landed at 38 and z 120 on a roof at 106. On three connected joins a fresh player fell to z 30, 1, 2 and -57 before spawn waited for ground collision. Hold the ped frozen until collision has loaded. Measured for NYR Underworld (LEDGER.md lines 992-994, 1174-1176, 2460-2519, commit a9fd79c).

# GetSafeCoordForPed can choose pavement well away from the point asked for

Asked for a safe coordinate near a shop counter with flag 16, `GetSafeCoordForPed` returned open pavement about twenty metres away rather than the shop floor. A route to a floor point walked out and back in reached the counter where the safe-coordinate answer did not. Measured for NYR Underworld (LEDGER.md lines 2624-2626).

# FiveM keeps one handler per command name and says so only on the client console

Registering the same command name from two client files kept one handler and printed "Command nyrpockets is already registered." on every client start; which one survived depended on manifest order. Keep command names in one list a test can check for duplicates. Measured for NYR Underworld across 68 client-registered names (LEDGER.md lines 1041-1049).

# chat:addMessage goes nowhere on a server without a chat resource

`chat:addMessage` is the chat resource's event, so on a server running no chat resource nothing listens and every reply sent that way is dropped silently. A resource whose feedback depends on chat looks broken with no error; give it a surface of its own. Measured for NYR Underworld (LEDGER.md lines 1066-1069, 1136-1138).

# FiveM's json.encode writes an empty table as []

On a live Enhanced server, FiveM's own `json.encode` wrote empty Lua tables as `[]` (`"players":[]`, `"log":[]`), so a NUI page receives an empty list, never `{}`, and code such as `(row.offers || []).includes` must expect an array. Measured for NYR Underworld (LEDGER.md lines 2412-2417).

# The NUI page's charset declaration is enough in the game's browser

The in-game NUI browser rendered a middle dot correctly from the page's own UTF-8 declaration; the same markup pasted into a host page with no head mis-rendered it as "Â·". A preview outside the game must declare the charset itself. Measured for NYR Underworld (LEDGER.md lines 1226-1235).

# oxmysql 2.14.1 returns result tables from execute_async and throws on bad SQL

On cfx-server 139 with oxmysql 2.14.1 built from source and MariaDB 12.3.3, `execute_async` on an INSERT returned a table like `{affectedRows=1, insertId=1}`, on a DELETE that matched nothing `{affectedRows=0}`, and on a SELECT the rows; `query_async` on an empty SELECT returned `{}`; `update_async`, `insert_async` and `scalar_async` returned numbers; bad SQL threw rather than returning nil. Wrap calls in `pcall` and read counts out of the table. Measured for NYR Underworld (LEDGER.md lines 676-684).

# oxmysql from source needs a build and its node_modules moved out

The vendored oxmysql source checkout ships no `fxmanifest.lua` (`build.js` generates it), needs `npm install --legacy-peer-deps` and then `node build.js`, and bundles `node_modules` into `dist/build.js`; left inside the resource folder, `node_modules` makes the server scan about 28,000 files at boot. Measured for NYR Underworld (LEDGER.md lines 732-737).

# CREATE TABLE IF NOT EXISTS needs the CREATE privilege even when the table exists

A database user with SELECT and INSERT but not CREATE was refused at boot by `CREATE TABLE IF NOT EXISTS` on a table that already existed, measured on MariaDB 12.3.3 through oxmysql. Grant CREATE, or check for the table another way, and say which in the refusal. Measured for NYR Underworld (LEDGER.md lines 2027-2034, 2079-2082).

# oxmysql waits quietly for a database that is not there

oxmysql 2.14.1 retries its connection pool every 30 seconds, and a query issued before a pool exists waits rather than failing, so a resource started before MariaDB prints no refusal; with MariaDB down the city simply waited across four failed connection attempts with nothing on the console. Check the connection with a timeout of your own and say what is being waited for. Measured for NYR Underworld (LEDGER.md lines 2053-2056, 2314-2316).

# A stopped resource never hears back from an awaited database call

A shutdown save issued from `onResourceStop` sent its first statement to oxmysql, and the resource was gone before any answer returned, so the rest of the write never happened: FiveM does not resume a stopped resource's coroutine. Hand the whole checkpoint over in one call before the first wait, as one transaction. Measured for NYR Underworld (LEDGER.md lines 2085-2088).

# The Enhanced FiveM client opens cfx:// links, and no command line connects it

The Enhanced client registers the `cfx://` scheme (not `fivem://`), and the legacy client refuses to run without a legacy GTA V install. Against a real running server, `cfx://connect`, `+connect` warm and cold, the shell handler and the in-game console each failed to connect; what worked was Settings, Interface, Localhost Port set to the server's port, then the localhost entry. Measured for NYR Underworld (LEDGER.md lines 254-267, 1519-1522).

# playerJoining does not fire for a client that stayed connected across a resource restart

After `restart` of a resource, clients that never disconnected did not raise `playerJoining`, so a server that armed a client-side feature only on that event left those clients deaf; arming everybody from the server at restart also failed because the client handler registers later. The client asking the server when its own script starts, retried a few times, worked. Measured for NYR Underworld (LEDGER.md lines 971-988).
