# Status

NYR Underworld 0.1.0-rc.6 — a release candidate for FiveM. This page separates
what has been **measured** from what has **not**. Nothing here is a guess: each
line is either backed by a run, or listed as open.

## Works (verified)

| Area | Result |
|---|---|
| Rule suite | **1,287 specs, 0 failures**, plain Lua 5.4, no game or server required |
| Tooling tests | **32 tests, 0 failures** (recording rig and release tooling) |
| Fuzz | Seeded random cities run in the suite; conservation of money and items holds |
| Server boot | Staged resource boots on a real FXServer, **legacy and Enhanced** builds |
| Scripted playtest | Passes through the resource's own command bus on both builds |
| Connected client | On the Enhanced server, a real client walked both player journeys: map marks, press-E prompts at a shop and a bank, F5 and F6 screens |
| Spawn | A joining player stays on the ground |
| Persistence | Saves safely across restarts; an unwritable folder refuses to start rather than lose the city |
| Database store | Emitted SQL replayed against MariaDB 12.3.3 on loopback |
| Dependencies | None third-party; the MySQL store calls an `oxmysql` the owner already runs |

### Systems

Characters, items and inventory, the record and standing, legal work and
payroll, property and rent, vehicles and car theft, police and arrest, banking,
shops and robbery, health and death, gangs and territory, phone and police
terminal, fencing and chop shops, and staff tools with an audit trail — 15
systems, 68 commands, all on the server; the client requests and draws.

## Does not work yet / not proven

| Item | State |
|---|---|
| Emergency services (role, dispatch, hospital as a place) | Not started |
| Licences and courts (driving, firearms, non-fine sentences) | Not started |
| Buttons on screens (Buy, Take it, Pay in) and E pressed at a marker | The commands behind them are proven; the presses were not driven by a journey |
| Hunt run against a live client | 14 checks need a connected client and are **unmeasured** (not failed) |
| Many concurrent players | Not measured |
| Sustained load on a production MySQL | Not measured |
| Merged database store against a real MariaDB/MySQL server | Earlier transport check predates it; not re-run |
| Store listing and checkout | Not live: storefront review and a verified test-mode checkout are outstanding |

## Reproduce

```
tools\spec.cmd                                   # run from PowerShell
lua tools/fuzz.lua --seeds 1-8 --steps 1200
```

Licence: see [LICENSE](LICENSE). Install and configuration: see
[README.md](README.md).
