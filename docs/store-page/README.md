# The listing page, and the rig that made it

Everything here was in a session scratch directory until that was cleaned. It is
in the repository now because the listing is a thing that gets rebuilt, and a
build whose inputs live in a temp folder is a build that happens once.

Staging holds `docs/` back, so none of this reaches a buyer's server.

## The page

    python build_listing.py        -> run/listing.html

`listing.src.html` is the page with three slots the build fills:
`__NYR_CSS__`, `__NYR_SCREENS__` and `__NYR_KEYART__`.

The eight interface frames are not screenshots and not a video. They are the
resource's own markup and its own stylesheet, written into the page as complete
inline documents at build time, so they render before a line of script runs. A
frame that needs a script to show anything shows a black rectangle wherever
scripts do not run, and those frames are the proof the page rests on.

Script only upgrades them: it swaps in the 1280-wide render scaled down, and
walks the hero through the tour.

The store URL is one constant at the top of the page's script.

## Where the screens came from

`baked_screens.json` holds each screen's rendered markup. To re-bake after
changing the interface:

1. `make_views.lua` builds a real `World`, installs all fifteen systems, seeds
   the city from `config.lua`, makes three people, gives one a night's worth of
   things, sends five texts through `phone.send`, buys a flat through
   `property.buy` and walks in through `property.enter`, opens a bank account
   for Dmitri and pays in through `bank.deposit` — then calls the same
   `NuiState` builders the server calls. Output: `views.json`. Dmitri banks,
   not Vic or Rosa, because their wallets are figures the page quotes.

       lua docs/store-page/make_views.lua > docs/store-page/views.json

2. `bake_screens.py` serves `adapter/nui` — the real `index.html`, `style.css`
   and `app.js`, off disk, unmodified — and prints a snippet. Open the address
   it prints, run the snippet in that page's console, and it posts each
   screen's `outerHTML` back to be written into `baked_screens.json`.

       python docs/store-page/bake_screens.py

   It refuses a screen that drew almost nothing, because a blank frame is
   markup too and would go into the page as an empty rectangle.

   The snippet turns every empty `{}` in `views.json` into `[]` before posting.
   `support/json.lua` cannot tell an empty list from an empty map and writes
   `{}`; FiveM's own `json.encode` writes `[]` (measured on the enhanced
   server's `/state`), and that is what the page gets in the game. Baked as
   `{}`, Around you threw on the first row with nothing to offer.

   Look at the frames after building. Drawing the real page is how the bank
   counter and the job board were found with no panel style at all.

There used to be a third step: a hand-assembled harness under `run/shots/` with
its own pasted copy of `app.js`. A second copy of the code that draws the
product is a copy that goes out of step with it, which is how the listing came
to be advertising a screen the product no longer had. The bake now runs the
real page or it does not run.

Vic Ortega has $2,180.50 on that page because he started with $500, was minted
$4,180.50, and the flat cost $2,500 through the ledger. Dmitri's $390.00 at
Pillbox Hill is $450.00 paid in and $60.00 taken out. None of it is invented.

`keyart.jpg` is the key-art illustration, resized for embedding.

## The recording rig

Used for the 0.1.0-rc.6 demonstration on 2026-09-13. The one step it needs is a
person connecting a client, and then keeping the game in front.

The bridge, the camera, the server and the waits are one module,
`docs/rig/rig.py` (its README says what else it does: the hunt, the watch, the
records). What is here is only the order of a take:

    film.py                 the loop on video: arrive, bank, work, shop, pockets.
                            `film.py shop` films the counter from a floor point
                            found off camera; `film.py walkin` walks in by a
                            route walked out first.
    beats.py                the loop as stills and a short loop: arrive, become
                            somebody, walk up to a counter, see the job board,
                            earn a door's price a shift at a time, buy it.
    capture_session.ps1     stage the shipping file set into
                            %LOCALAPPDATA%\NyrUnderworld\capture3 and write its
                            server.cfg for 127.0.0.1:30132. `data` is excluded
                            from the mirror -- without that, /MIR destroys the
                            played city on every restage. Move `data` out of the
                            session first for a take on a fresh city.
    capture-server.cmd      the launch, invoked the way tools/devserver.cmd
                            invokes it, because that is the call known to
                            satisfy the licence handshake. Run it where its
                            console is read, or it freezes at the first save.

Both scripts take `--port`; without it they find a lingering
`rig.py hunt --linger` first and the capture stage's port second, so the
port is never typed twice. A take, in order:

    powershell -File capture_session.ps1          stage
    capture-server.cmd                            serve 30132; FiveM Localhost Port 30132
    python beats.py --earn                        the shifts, ~6 min, no camera
    python beats.py                               the beats, ~1 min, game in front
    python film.py                                the loop on video, game in front

Or one command for the server: `python docs/rig/rig.py hunt --wait-client 600
--linger 1800` stages, boots, walks everything with the connected body, and
stays up while the log is watched -- the takes run against it.

The camera takes whatever is in front on the main screen. A take on 2026-09-13
recorded the desktop of somebody who had tabbed out to read a message, which is
why the shifts are run first, without it.

`server.cfg` is written without a byte-order mark. Written with one, which
`Set-Content -Encoding UTF8` does under Windows PowerShell 5.1, cfx-server read
`endpoint_add_tcp` as an unknown command and served the default 30120, where no
client set to 30132 could find it.

The client is driven through the dev bridge's `/act` route, which walks the
body, presses E, opens a screen or moves the ped. Every screen is opened by the
same function its key binding calls, so what is recorded is what a player sees.

**The blocker:** nothing makes the FiveM client connect from a command line.
`cfx://connect`, `+connect` warm and cold, the shell handler and the in-game
console (`connect` and `disconnect` are both refused) all fail. What decides the
address is FiveM Settings > Interface > **Localhost Port**, and a person has to
set it.

## The database check

    python sql_against_real.py     (needs a MariaDB on 127.0.0.1:3307)

`emit_sql.lua` drives the real store and writes down the exact statements and
parameters it produced; `sql_against_real.py` replays them against a real server
with real server-side binding (`PREPARE` / `EXECUTE ... USING`).

Until this ran, every statement had only ever been executed by a fake driver
written to match the store's own SQL — which proves the two agree, not that the
SQL is valid. Four things were in question and all four would have been silent
in production: `ON DUPLICATE KEY UPDATE ... VALUES(payload)` on MariaDB, the
`utf8mb4_bin` key column, the 190-character limit, and integers surviving JSON.
All four pass.

Start a server for it with the vendored copy:

    mariadb-install-db.exe --datadir=<dir>
    mariadbd.exe --datadir=<dir> --port=3307 --bind-address=127.0.0.1 --skip-grant-tables
