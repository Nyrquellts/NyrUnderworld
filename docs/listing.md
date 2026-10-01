# NYR Underworld — listing

*The city remembers.*

**$49 USD · one-time purchase · the servers you administer · updates for 0.1.x**

A machine-readable version of everything below is in [`offer.json`](offer.json).
Where the two disagree, `offer.json` is the one that was checked.

---

## What it is

One connected FiveM framework for characters, money, property, work, crime —
and a city that remembers what happened in it. Install one resource and start
building your city.

**15 integrated systems · 8 interface screens · 68 commands · readable Lua ·
MySQL optional**

| | |
|---|---|
| **Framework** | **Standalone Core.** Underworld owns its simulation and does not require ESX or QBCore. |
| **Dependencies** | **None required.** oxmysql or mysql-async only if you want MySQL. |
| **Source** | **Fully readable.** No escrow, no obfuscation, no encrypted files, no phone-home. |
| **Licence** | Yours to modify, on the servers you administer. No cap on players, uptime or revenue. |

---

## Price

**$49 USD, one time.** Not a subscription. Not per-server beyond the servers you
administer.

It is priced against what is actually on sale, not against a feeling:

| Product | Price | Scope the seller advertises |
|---|---:|---|
| Wasabi Multicharacter | $39.99 | QB/ESX/QBOX bridges, appearance, spawn |
| Wasabi Advanced Police Job (unlocked) | $124.99 | props, radar, CCTV, garage, integrations |
| Resolve Jobs Creator | £8.00 | ESX job/rank/salary editor |
| Numen Delivery Jobs | 79.95 PLN | delivery progression, framework support |

*Prices observed 11 September 2026. Do not infer sales volume or quality from a
store page, this one included.*

Underworld has no framework bridges and four of its systems are chat commands,
so it does not get to charge like a turnkey product. $120 is not defensible on
current evidence. At $49, after Tebex's 15% and the published PayPal example
(2.49% + $0.40), the seller nets about **$40.03 an order — eight orders to clear
$300**. $49 over $59 is for easier first sales from a new seller with no reviews.

**Money is not immediate.** Tebex settles in about fourteen days by default,
PayPal withdrawal adds one to two working days, and a new payout method carries a
five-day hold. Tebex must also approve a new project before it accepts payments
at all; Test Mode can validate delivery while that is pending.

---

## What you get

- **54 files of readable Lua**, 61 files in the package
- **Eight interface screens** — characters, pockets, phone, shop counter, property
  stash, around you, bank counter, job board — found from map blips, ground
  markers and press-E prompts
- **68 commands** across 15 systems
- **`config.lua`** — items, jobs, addresses, banks, shops and prices, turf,
  fences. Checked in full before the server will start; a misspelled key is
  refused rather than ignored.
- **A MySQL layer** that speaks to the driver you already run
- **`LICENSE`** and **`audit-accepted.json`**, which names what a resource
  checker will flag and why

**Eight things have screens, and gangs, police, fencing and vehicles are
documented chat commands.** Tell your players that; `/nyrhelp` lists them.

---

## The systems

| System | Commands | |
|---|---:|---|
| Characters | 5 | Three people to an account, one played at a time |
| The record | 1 | What happened, written whether or not anybody saw it |
| Inventory | 4 | Slots and grams; reach is a grant the server issues and expires |
| Work | 4 | A job board of who is hiring; abandoning a shift costs |
| Property | 5 | Addresses with doors, prices, rent, arrears and seizure |
| Vehicles | 6 | One car one owner; keys, boots, hotwiring as a recorded crime |
| Police | 4 | Commissioned from the console, never claimed by a client |
| Banking | 5 | Branches are places with doors; deposits, transfers, statements |
| Shops | 4 | A till with a float; a shop with no money cannot buy from you |
| Fencing | 3 | Pays less than a shop would, and chops cars |
| Gangs | 9 | Crews with ranks and a shared account; blocks they can hold |
| Health | 3 | Down, bleeding out, revived or respawned — the server decides |
| Phone | 5 | Numbers not names; the city keeps what was said |
| Admin | 6 | Three ranks, granted from the console, capped, fully audited |
| Overview | 4 | Where everything is, what is in reach, what you carry |

### The mechanic it is named after

The city keeps two things apart. **The record** is what happened — written
whether or not anybody saw it, never edited, never expiring. **Standing** is what
the city currently thinks, and it cools.

So a crime with no witnesses gives you no heat and a complete record. Nobody is
looking for you, and the evidence is sitting there with your name on it. Wait out
the heat and you are no longer hunted, and still the person who did it.

---

## Will it work on your server

| | |
|---|---|
| Fresh server | **Yes** — the intended case |
| Existing ESX | **No** — no bridge included or verified |
| Existing QBCore | **No** — no bridge included or verified |
| Existing QBOX | **No** — no bridge included or verified |
| Map / vehicle / clothing packs | **Yes** — streamed assets do not touch gameplay rules |
| GTA V Legacy | **Yes** — declared and booted |
| GTA V Enhanced | **Yes** — declared and booted |
| OneSync | **Required**, and declared in the manifest |
| txAdmin | **Yes** — it is an ordinary resource |

**Said plainly:** this is what you run *instead of* ESX or QBCore. If you have
two years of ESX data and players, this is not the purchase for you.

---

## Installing it

1. Put the folder in `resources/` as `nyr_underworld`, in lower case: on FiveM
   for GTAV Enhanced a folder with a capital letter cannot save, and the resource
   refuses to start rather than open a city it cannot keep
2. Add `ensure nyr_underworld` to `server.cfg`
3. Start the server

Nothing has to start before it. For MySQL instead of files: `set nyr_store
database`. The table is created on the first boot.

---

## Persistence

Out of the box the city is JSON inside the resource — no database, no setup. A
corrupt file falls back to its backup and says so.

**If a collection cannot be read at all** — a corrupt file whose backup is also
gone, or a database that has gone away — every request touching it is refused
until it can be read again, and **nothing is written over it**. Same rule in both
stores. If unreadable looked like empty, the character system would find nobody,
make a fresh character over the top of somebody's, and the next save would write
it down over the last good copy.

A refusal is reported every save tick and never takes the save loop down: a city
running with nothing writing it down is the one outcome worse than a refusal.

---

## Evidence

**980 automated tests** pass in a few seconds with no game and no server,
because the rules are plain Lua that knows nothing about FiveM.

Before a build is allowed to ship, a gate checks the manifest, the licence file,
scans for anything credential-shaped, runs a static check and a backdoor audit —
then **boots the staged copy on a real server**, on both the Legacy and Enhanced
builds, and runs that copy's own
playtest against it. A file list can be argued with; a resource that will not
start cannot.

**The SQL has been run against a real database.** MariaDB 12.3.3 on loopback,
with the statements the store actually emits, captured from a real run and
replayed with server-side parameter binding. It confirms the schema is accepted
as written, that `ON DUPLICATE KEY UPDATE ... VALUES(payload)` works on MariaDB
(the MySQL-8-only alias form was deliberately avoided), that the key column is
genuinely case-sensitive so two ids differing only in case stay two records,
that an over-length key is refused rather than truncated, and that whole cents
survive the round trip as integers.

**A real client has played it.** A FiveM client connected to the Enhanced
server walked both of a new player's journeys with every check made and passed:
the map marks and the press-E prompts drawn, Around you and the job board
brought up by their keys, a shop and a bank branch reached. The loop the city is sold on was then
recorded on the build that ships: arrive, become somebody, stand at a counter,
read a door's price, earn it across twenty-six work shifts, buy the door.

**What is not proved, plainly:** many concurrent players on one box, a month
against a production MySQL, and this build's database store against a real
MariaDB (the oxmysql transport was verified inside a running server before the
2026-09-13 merge). Those are not claimed.

---

## Not cleared for sale yet

| Outstanding | Owner |
|---|---|
| Tebex project review and approval | external, timing cannot be promised |
| Verified checkout and delivery in Test Mode | the seller |

---

## What it does not do

- **No emergency services.** Health has downing, bleeding out and revival; the
  EMS role, dispatch and a hospital as a place are not built.
- **No licences or courts.** A sentence is a fine.
- **No streamed assets.** The map is Los Santos as it ships.
- **No drag-and-drop inventory.** The grid is click, count, act.
- **No HUD overlay.** `me.status` answers with everything a HUD needs; drawing
  one is not included.
- **Not load-tested with hundreds of live players.** The persistence is built for
  it and has not been proved at that scale. That claim is not made.

---

NYR Underworld is an independent FiveM resource. It is **not affiliated with,
approved, sponsored or endorsed by** Rockstar Games, Cfx.re or Take-Two
Interactive. GTA V and FiveM are the property of their respective owners, and
neither a copy of the game nor server hosting is included in this purchase.

The key art is promotional illustration. The interface screens on the web listing
are the resource's own code drawn with data built by its own systems — neither is
in-game footage. The in-game footage was recorded separately, on this build, with
a real client connected.
