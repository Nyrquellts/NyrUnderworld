# NYR Underworld

**The city remembers.**

## Install

The download holds one folder, `nyr_underworld`. That folder -- the one with
`fxmanifest.lua` directly inside it -- goes in your server's `resources/`. If your
unzip tool put it inside another folder named after the zip, move the inner one.

```
ensure nyr_underworld
```

Keep the name in lower case. On FiveM for GTAV Enhanced a folder with a capital
letter in its name cannot save, so the resource refuses to start and says why
rather than open a city it cannot keep. OneSync has to be on.

A city, life and crime expansion for FiveM, built as one persistent simulation
rather than a pile of unrelated scripts. What you did last week is still true
this week: the bar you bought, the money you moved, the people you crossed, the
car that changed hands three times before the police found it.

Everything that decides anything runs on the server. The client sends requests
and draws what it is told.

---

## Where it is

Foundation and the first systems, working and tested. Money, books, identity,
ownership, persistence, commands, events, city time, scheduled work, items and
inventory, the record and standing, legal work and payroll, property and rent,
vehicles and car theft, police and arrest, banking, shops and robbery, health
and death, gangs and territory, the phone and the police terminal, fencing and
chop shops, staff with an audit trail, and a FiveM adapter that boots all of it
inside a resource on a real FXServer, with a client that reaches every command.

The promise is already mechanical rather than marketing. A crime nobody saw
leaves no heat and a full record: nobody is looking for you, and the evidence is
sitting there with your name on it. Wait out the heat and you are no longer
hunted, and still the person who did it, and a detective who looks you up can
still see all of it.

```
980 specs, all passing, in a few seconds
```

The gameplay systems on top of it are the work ahead. See [STATUS.md](STATUS.md)
for exactly what works, what does not yet, and what is blocked.

## Running the tests

No game, no server, no database. The whole simulation runs under a plain Lua
interpreter, so a week of city life takes milliseconds.

```bash
tools\spec.cmd
```

Needs Lua 5.4 and luaunit. Both are already installed on this machine; the
paths are at the top of `tools/spec.cmd`.

## Running it on a server

The repository is the resource. A FiveM resource is named by its folder, not by
the `name` line in the manifest, so clone or copy it into `resources/` as
`nyr_underworld` and start that.

```
ensure nyr_underworld
```

**All lower case.** On FiveM for GTAV Enhanced a resource whose folder name
has a capital letter in it cannot write a file: `SaveResourceFile` answers no and
the server prints nothing. So a folder cloned or unzipped as `NyrUnderworld`
used to start, let people play, and keep none of it. Measured with the same
files under four names, each run past its first save:

```
                    legacy 35245    enhanced 139
NyrUnderworld          saves        every save fails
Nyr_Underworld         saves        every save fails
nyrunderworld          saves        saves
nyr_underworld         saves        saves
```

It no longer gets that far. Before anything is built, the resource writes
`data/_can_write.json` and reads it back, and if that fails it does not start:

```
NYR UNDERWORLD did not start: nothing can be written to NyrUnderworld/data, so nothing anybody did would be kept

  The folder is named NyrUnderworld, with a capital letter. On FiveM for GTAV Enhanced a
  resource named that way cannot write a file at all (measured on server build 139).

  Rename the folder to nyr_underworld, change server.cfg to `ensure nyr_underworld`,
  and restart the server. If it still does not start after that,
  nyr_underworld/data has to exist before the server starts: SaveResourceFile does not
  create folders. If it is there, something is stopping the server writing to it.
```

The write is tried rather than the name judged, so a legacy server, which keeps
the city under all four names, is not refused for any of them. `nyr_underworld`
is still the name to give it on both, because it is the name addons ask for.

Then from the server console:

```
nyr summary     the state of the city
nyr verify      check the invariants on the live server
nyr errors      everything that has gone wrong
nyr audit       what was asked for and what came back
nyr store       where the city is kept, and whether it is keeping up
nyr save        write it down now
```

Requires a FiveM server licence key in `server.cfg` as `sv_licenseKey`, which
both servers demand even on loopback, and even in LAN mode.

## Making it your city

Everything a server owner is meant to change is in `config.lua` at the root of
the resource, and nothing that is a rule is. Items, jobs, addresses, banks,
shops and their prices, the blocks a crew can hold, who buys stolen goods.

```lua
shops = {
    {
        name = "Rob's Liquor",
        at = "Rob's Liquor, Grove Street",
        prices = {
            water   = { buy = 250,  sell = 100 },
            scrap   = { sell = 900 },   -- taken in, never sold
        },
        restock = { water = 60 },
        float = 50000,
    },
},
```

Money is whole cents everywhere: `250` is $2.50, and there are no decimals in
the file at all, because a decimal in a price is the one mistake that quietly
costs somebody money.

**The whole file is checked before any of it is built,** and a config with a
problem in it does not start a city. Four mistakes cost one restart, not four:

```
NYR UNDERWORLD did not start: config.lua has 6 problems

  fences[1].at: "Cypress Flats Scrapyrd" is not the address of anything in `places`
  items[2]: wieght is not an expected field
  shops[1].prices.wtaer: names an item that is not in `items`
  turfz: is not a section. The sections are: city, items, employers, places, banks, shops, turfs, fences

  Nothing was built. Fix these and restart the resource.
```

A misspelled key is refused rather than ignored, which is the rule that matters
most: a setting that is quietly dropped looks exactly like a setting that
works.

Adding to the config adds to the city. Entries are matched by name, so a shop
added and a server restarted is a new shop -- and everything already in the
city keeps its stock, its till and its owner. Restarting never reverts a city
to its seed.

## Where the city is kept

Nothing is required. Out of the box the city is JSON files inside the resource,
which needs no database, no dependency and no setup, and is the right answer
for a dev box and a small server.

For a real one, put it in the MySQL the server already has:

```
set nyr_store database
```

That is the whole configuration. The table is created on the first boot.

```
set nyr_store_driver oxmysql    name one, instead of taking whichever is up
set nyr_store_table  nyr_store  name the table
```

**No database library ships with this resource, and none ever will.** It speaks
to the one already installed -- `oxmysql`, or `mysql-async` for an older server
-- because two copies of a MySQL library on one server is two connection pools
fighting over the same database. If neither is running, the resource says so
and names what it looked for.

One table holds everything:

```sql
CREATE TABLE `nyr_store` (
  `collection` VARCHAR(48)  NOT NULL,
  `store_key`  VARCHAR(190) NOT NULL COLLATE utf8mb4_bin,
  `payload`    LONGTEXT     NOT NULL,
  `updated_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`collection`, `store_key`)
) ENGINE=InnoDB;
```

A collection is read once at boot and served from memory after that, so a
player's request never waits on the database. Only the rows that actually
changed are written, batched two hundred to a statement, on the save tick.

Two behaviours worth knowing before you run it:

- **It will not start without the database you asked for.** `nyr_store
  database` with nothing to talk to refuses to open the city and prints what it
  looked for. It does not quietly fall back to files, because an owner reading
  an empty MySQL table while their players' work goes to disk finds out a week
  later.
- **A database that goes away is not a city that is empty.** A read that fails
  refuses every request touching it until the database answers again. The
  alternative is a player looking like somebody with no character, making a new
  one over the top of the one they have, and that being written down.

## Both versions of the game

This runs on GTA V Legacy and on GTA V Enhanced, and that is a property of what
it is rather than a feature that was added.

- **The simulation contains no game natives at all.** Everything that decides
  anything is pure Lua and is tested under a plain interpreter. There is no
  version-specific code to be version-specific about.
- **There are no streamed assets.** No models, no textures, no map data, no
  audio. Asset format changes are the main reason resources need converting for
  Enhanced, and there is nothing here to convert.
- **The manifest declares both tokens, and that was measured.** FiveM for GTA V
  Enhanced is served by a *different program*, not a newer build of the same
  one: `cfx-server.exe` (build 139), downloaded separately from the
  `FXServer.exe` everyone has been running for years (build 35245). They
  disagree about the `games` list, so the resource was booted on both with
  nothing else changed:

  | `games { … }` | legacy 35245 | enhanced 139 |
  |---|---|---|
  | `gta5` | starts | starts |
  | `gta5enhanced` | refused | starts |
  | `gta5`, `gta5enhanced` | **starts** | **starts** |
  | `rdr3` | refused | refused |
  | `nyr_not_a_game` | refused | refused |

  The last two rows are the control, and without them the first three prove
  nothing: a list nobody checks accepts everything. With them the gate is known
  to be real, and `Resource is not compatible with the current game` is what
  refusal looks like. So `gta5enhanced` is a token the Enhanced server genuinely
  recognises — an earlier version of this file called it invented on the
  strength of it appearing in no Legacy binary, which was true and was the wrong
  place to look. Legacy does not know it, but a `games` list is satisfied by any
  one member, so Legacy is satisfied by `gta5` and ignores the rest. Declaring
  both says what the resource supports instead of relying on Enhanced continuing
  to answer to `gta5`.
- **None of the listed Enhanced breaking changes applies.** The city stores
  nothing in the key-value database, registers no remote commands, is not a
  resource builder, and needs neither of the new config variables. There is no
  `stream/` folder to rename to `stream_enhanced/` either.
- **The few natives the adapter uses are long-standing ones**, and the one
  version assumption that was in the code is gone: the damage watcher read a
  ped's health against a hardcoded 100 to 200 range, which is a convention of
  one version rather than a fact. It asks the ped for its own maximum now and
  works out a percentage, so it does not care what the scale is.

**How this was verified.** The resource was deployed unchanged to both servers
on loopback and watched come up. On both it started, seeded a fresh city, and
reported the same six opening lines:

    [nyr] hired the first two employers
    [nyr] put the first two addresses and two branches on the map
    [nyr] opened the first shop
    [nyr] drew the first two blocks
    [nyr] somebody who asks no questions is in Cypress Flats
    [nyr] the city is at day 0 monday 08:00 with 0 people, 6 addresses

The whole table is kept as a test rather than a claim. It re-runs against
whatever servers are vendored, and if a future build changes a row it fails and
names which one.

**What a boot is and is not.** A resource that starts is a resource that
loaded. It is not a resource that works, and nothing above is a substitute for
playing it.

**One thing both servers agree on and the documentation does not.** `sv_lan
true` is documented to skip the licence check, and the convar's own description
inside the Enhanced binary repeats that. Neither server honours it: with
`sv_lan true` and no key, both refuse — Legacy with *This server does not have
a license key specified*, Enhanced with *A valid license check is required to
run this server. No sv_licenseKey specified.* You need a key to run this
locally, on either one. That is a Cfx discrepancy and not something a resource
can work around.

## The screen

The picker opens by itself when you join without a character, and on **F2** or
`/nyrpicker` after that. It lists who you can play, what each of them is
carrying, which one you are being, and a form to make somebody new. Retiring
somebody asks twice, because it is the one thing here that cannot be undone.

It is three files — `index.html`, `style.css`, `app.js` — with no web fonts, no
images and no CDN, because a NUI page loads off the player's own disk with no
network behind it.

**The part worth knowing about if you are installing this.** A NUI page is a
browser inside the game, on the player's machine, with developer tools in it.
Anyone can POST to `https://<resource>/<callback>` with any payload. So the page
gets the same treatment as any other untrusted caller:

- Exactly three actions exist — `create`, `select`, `retire` — one callback is
  registered per action and none for anything else.
- A field an action does not declare is refused, not ignored.
- **The page is never told why something was refused**, only what line to print.
  It cannot act on a code it is never given.

All of that is plain Lua in `adapter/nui_state.lua` and is covered by the spec
suite, including a check that the page's own count of how many people it may
have is a number to display and never permission to grant: the form stays
available when you are full, and being full is `character.create` saying so.

## The other screens

**F3 — pockets.** A grid, because that is how somebody looks for a thing they
own: by shape and position, not by reading a list. It shows slots used, weight
against capacity, and a bar. Pick a thing and you can drop some of it or use
it. The bar is a proportion drawn, never a rule: whether one more thing fits is
answered by the server refusing to put it there.

**F4 — the phone.** Who has been in touch on the left, the conversation on the
right, oldest at the top because that is how a conversation reads. Your own
messages sit on your side. There is no "from" field to fill in: the sending
number is the one the server wrote on your character, and a message that
appears to come from somebody else is not a cosmetic bug, it is a way to get a
person killed by their own crew.

**F5 — around you.** What is within reach and what it costs: a flat on the
market says its price and offers Buy, a home offers Go in and the server decides
at the door whether you are let in, and a bank branch or a shopfront offers
neither, because nobody is ever let through those.

**F6 — the job board.** Who is hiring, what a shift pays and how long it runs,
and how long until you may take it again. Work has no address, so it opens on a
key rather than at a door. Whether you may take a shift is the server refusing.

**E, at a place.** Shops, bank branches and doors for sale are marked on the map
and with a marker on the ground; within three metres a prompt says what E does.
At a shop it opens the counter, at a branch the bank, at a door for sale the
Around you screen. A place with nothing behind the key gets no prompt.

All of them are drawn from the same three files as the picker, and all keep the
same rule: the page holds what it was told, is never given a refusal code, and
can ask for exactly nineteen things (`ACTIONS` in `adapter/nui_state.lua`) and
nothing else.

Gangs, police, fencing and vehicles are chat commands. `/nyrhelp` lists every
command, and `/nyrhud` toggles a one-line status display.

Money a player types, in chat or on a screen, is in dollars: `/nyrsend <number>
500 rent` sends $500.00 and `/nyrdeposit <branch> 12.50` pays in $12.50, and the
reply says what moved. Only `config.lua` is written in whole cents.

### Every name this resource claims

A FiveM server is one shared namespace: two resources registering the same
command name means one of them silently does not run, and which one depends on
load order. Nothing announces it.

**Every name this resource takes is in `adapter/commands.lua`** -- the chat
commands, the five keys, and the two it registers on its own -- as one readable
list. If a command of yours stops working after installing this, look there
first. A static conflict checker will not find them, and it is honest about why:
they are registered in a loop over that table rather than one call per name, so
the names exist at run time and a tool reading the source sees a loop. That is
also why there is one list rather than two, and why a spec fails if any name in
it is claimed twice.

The screen keys are `nyrpicker`, `nyrpockets`, `nyrphone`, `nyrnearby` and
`nyrboard`, bound to F2 to F6. Those are the ones most likely to collide with something of yours,
because they are commands as well as keys.

## Writing an addon against this

Two surfaces, and they are the two that already exist inside: ask it something,
and be told when something happens.

```lua
-- What am I talking to
local about = exports['nyr_underworld']:version()
-- { resource = "nyr_underworld", version = "0.1.0-rc.6", events = "nyr:event", ask = "..." }

-- Ask it something, on the same bus a player's key press uses
local outcome = exports['nyr_underworld']:ask('character.list', {}, { account = source_licence })
if outcome.ok then
  for _, row in ipairs(outcome.value.characters) do print(row.name) end
end

-- Be told when something happens
AddEventHandler('nyr:event', function(name, payload)
  if name == 'property.bought' then
    print(('%s bought %s for %d'):format(payload.buyer, payload.place, payload.price))
  end
end)
```

`ask` answers the same shape a client gets: `ok`, `code`, `message`, `value` and
the names of the events it raised. A refusal is a refusal, not an error — check
`ok` and show `message`.

The context you may set is `account` and `operation_id`, and nothing else.
Anything else is refused rather than ignored, so a misunderstanding is something
you find out about.

Two of them you cannot set, and they are the two that matter.

**`source`** is stamped with the resource that called, which the server asks
FiveM for and you do not choose, so an owner reading the log can see which addon
did what.

**`actor`** — who is acting — is looked up from the account you named, exactly
the way it is for a player pressing a key. You say *which account*; the city
decides who that is. This is the rule everything else rests on, because
ownership, money and the criminal record all attach to whoever acted, and an
addon that could name its own actor would be able to act as anybody whose id it
had just read out of `character.list`. An account playing nobody acts as nobody,
and the command refuses `not_playing` — the same refusal a player gets.

There is **no command allowlist** for addons, because an addon is server-side Lua
the owner installed: the allowlist exists for clients, which are not, and an
addon held to a client's reach could not do what addons are for. That is not a
hole. Every command that needs privilege checks the *actor* rather than the
caller — `admin.give` refuses `not_staff` unless the character acting has the
level — so an addon reaches exactly as far as the person it is acting for, and
no further.

Every domain event is forwarded as it happens, including ones added after your
addon was written: it is a watcher on the bus rather than a list of names. What
crosses is plain data — money arrives as a whole number of minor units, the same
as everywhere else, because the alternative is an addon reading an internal
shape that will change.

The events are named `system.verb` in the past tense: `character.created`,
`property.bought`, `work.finished`, `gang.deposited`. `/nyrhelp` and
`adapter/commands.lua` between them list everything you can ask for.

## What an audit of this resource will say

Run it through a resource checker before you install it. You should do that
with every resource, and this one is no exception. Two things will come up, and
both are deliberate:

- **`load` in `adapter/loader.lua`.** A FiveM resource has one shared namespace
  and no module system. This supplies `require` by reading modules out of this
  resource on demand, which is what lets the same files run in the test suite
  and on a server with no build step. The source it compiles comes from
  `LoadResourceFile` on this resource and from nowhere else; the module name is
  validated as a dotted identifier, so nothing can be talked into reaching
  outside the directory. There is no HTTP in this project at all.

- **`SaveResourceFile` in `adapter/resource_store.lua`.** That is the city being
  written to `data/*.json`. It is the only thing in the project that writes
  files.

- **An every-frame loop in `adapter/client.lua`.** Drawing has to happen every
  frame, and a checker reading the source statically sees a `while true` with a
  `Wait(0)` in it and cannot know that the wait is conditional. It is: with the
  display switched off, or before the first answer has arrived, the loop idles
  at two ticks a second and only takes a slice of the frame while there is
  actually something on screen. The finding is correct to appear and the code
  is right as it stands.

What a reader should look for in any resource is a combination the author never
mentioned, and a host they cannot explain. This is the mention.

## Layout

```
config.lua     your city: items, jobs, addresses, shops, prices, turf.
domain/        the rules. Pure Lua, no FiveM, no globals, no side effects.
core/          the machinery: outcomes, events, commands, clock, scheduler, world.
persistence/   stores and the typed repository over them.
systems/       gameplay, one system per file, installed into a world.
adapter/       the only files that know FiveM exists.
support/       small utilities with no dependencies of their own.
adapter/nui/   the drawn interface: three files, no fonts, no images, no CDN.
spec/          luaunit specs. Every rule above is tested here without a game.
tools/         the spec runner, and two scripts that start a server and join it.
```

## The layering

```
interface  ->  commands  ->  simulation  ->  state  ->  events  ->  adapters
```

Requests come in through a command, which validates them against a declaration
before a handler sees them. The simulation owns the truth. What happened goes
out as an event. Adapters react. Nothing skips a step, and nothing to the left
of `adapters` knows what game this is.

[docs/architecture.md](docs/architecture.md) has the reasoning behind each
piece, and the failures each one exists to prevent.

## The rules that hold it up

- **Money is a whole count of minor units, never a float.** Doubles lose money
  silently, and every split and percentage names where its remainder goes.
- **Money moves, it never appears.** Every posting sums to zero. Money entering
  or leaving the world crosses a named external account, so creation is an
  auditable line rather than a number growing.
- **One asset, one owner.** Transfers state who they believe holds it and are
  refused if that belief is stale, so two clients racing for one car cannot
  both win.
- **The account comes from the server.** A connecting player gives FXServer a
  platform identifier; that is the one fact in a request that cannot be forged,
  and every question of "is this yours" is answered against it.
- **Undeclared input is refused, not ignored.** Every command declares what it
  accepts. An extra field is an error, because ignoring one is how a client
  sets something the server never meant to expose.
- **One operation runs once.** A retried request, a double click, a replayed
  packet: one effect.
- **A refusal is not a failure.** Being short of cash is a normal answer. A
  broken handler is a bug report. They never look alike, in a log or to a
  player.

## Built with

[Nyr](https://github.com/) — the modding toolkit this project is developed
against. Its FiveM lane supplies the resource checker, the risk audit, the
conflict map and the bounded server harness used on this code.
