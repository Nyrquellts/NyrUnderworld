# Selling it

The landing page is an artifact; this is the text for the places that only take
text — a Cfx.re forum post, a Tebex description, a Discord pin. Written to be
scanned, because that is how these are read.

Draft copy for review, for 0.1.0-rc.6 at $49. Checkout is not live. The staged
copy boots and passes its scripted playtest on both server builds, and a real
FiveM client on the Enhanced server has walked both player journeys with every
check passing. See docs/offer.json for the evidence behind every claim before
publishing any version of this text.

---

## The short one — for a Discord line or a store subtitle

> **NYR Underworld** — a city, life and crime RP framework for FiveM.
> Characters, work, possessions and consequences in one standalone simulation.
> The city remembers what you did even when nobody saw you do it.

---

## The forum post

**NYR UNDERWORLD — the city remembers**

A city, life and crime roleplay resource for FiveM. Characters, work, property,
vehicles, banking, shops, gangs, a phone, and police who can look you up.

**Built for standalone servers.** File storage needs no external RP framework
or database resource. Install the resource, enable OneSync and configure your
authenticated FiveM server. Framework migration and integration are separate work.

**What you get**

* Connected systems with server-side command validation
* Eight screens: character picker, inventory grid, phone, shop counter, stash,
  around you, bank counter, job board -- found from map blips, a marker on the
  ground and a press-E prompt at the places that open them
* An owner configuration file — items, jobs, addresses, shops and
  their prices, turf, fences
* Files out of the box; optional MySQL adapters awaiting a real backend check
* Boots and plays its scripted scenarios on both FiveM server builds, Legacy and
  Enhanced, and a connected client on Enhanced has been shown a shop on the map,
  stood at its press-E prompt, opened Around you and the job board with their
  keys, and found work and a bank
* Readable Lua throughout. No obfuscation, no escrow, no encrypted files.

**The mechanic it is named after**

The city keeps two things apart. *The record* is what happened — written whether
or not anybody saw it, never edited, never expired. *Standing* is what the city
currently thinks, and it cools.

So a crime with no witnesses gives you no heat and a complete record. Nobody is
looking for you, and the evidence is sitting there with your name on it. Wait
out the heat and you are no longer hunted, and still the person who did it.
Someone can find that out next month and act on it.

**Built assuming the client is lying**

* Every rule about money, ownership, crime and consequence is server-side.
* Refusals are shown as readable messages. Authorization is enforced by server
  rules; hiding an error code or changing a screen does not provide security.
* The client can reach exactly the commands on an allowlist. A command added
  tomorrow is unreachable until somebody says so.
* Money is whole cents, never a float, and every movement is a double-entry
  posting whose total is checked. Replay and restart regressions cover repeated
  requests, and malformed saves stop the city instead of silently replacing it.
* One asset, one owner. Two transfers racing for one car: the second is refused.

**Tested**

980 tests pass using plain Lua and simulated stores. These tests cover the
simulation rules; they do not prove native gameplay or a real SQL integration.
The release gate checks the staged copy for its manifest, licence file,
credential patterns and source findings, then requires that copy to boot and
pass its playtest, and it passes on both server builds. A real FiveM client
connected to the Enhanced server has walked a new player's first steps -- the
map, the prompts, the screens -- with every check made; many players on one
server has not been tried. A source audit is not a guarantee.

**What it does not do**

Said here rather than found later.

* No EMS role, dispatch or hospital. Health has downing, bleeding out, revival.
* No licences or courts. A sentence is a fine.
* No streamed assets — no custom vehicles, clothing, MLOs or maps.
* No drag-and-drop in the inventory. The grid is click, count, act.
* No graphical HUD. `/nyrhud` shows a one-line text status; anything more is
  yours to draw from `me.status`.

**Requires**

A FiveM server with a licence key (both server builds demand one, even on
loopback). OneSync on. The resource folder named in lower case, `nyr_underworld`:
on FiveM for GTAV Enhanced a folder with a capital letter in its name cannot save
a file, so the resource refuses to start rather than open a city it cannot keep.
Optionally `oxmysql` or `mysql-async` if you want MySQL instead of files — no
database library ships with this and none ever will.

---

## What to answer when they ask

Keep these short. Every one is true and checkable.

**"Is it ESX or QBCore?"**
Neither. It is its own framework and it needs neither installed. If you are
already running one, this is not a resource to add to it — it is a different
server.

**"Does it use a database?"**
Optional adapters for `oxmysql` and `mysql-async` are included. The store's own
statements were run through oxmysql against MariaDB on an earlier build; this
build's store has changed since and has not been run against a real database.
Out of the box the city is stored as JSON inside the resource. Follow the backup and recovery
instructions; file collections are not a single crash-atomic transaction.

**"Is it escrowed?"**
No. Every line is readable Lua. You can change anything, and the config file
exists so that most changes do not mean touching code.

**"How many players?"**
A collection is read once at boot and served from memory after that, so a
player's request never waits on the database, and only rows that actually
changed are written, batched. It has not been load-tested with hundreds of real
players — say that, and do not invent a number.

**"Can I add my own shops/items/jobs?"**
`config.lua`. The whole file is checked before anything is built, so a typo is
six lines of "here is what is wrong and where", not a broken server.

**"Updates?"**
Say what is actually true at the time. Do not promise a roadmap you have not
built.
