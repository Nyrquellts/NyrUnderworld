# What is actually playable

Read from the code, not run. Every claim below names where to check it.

The question this answers is the one that matters before anybody is asked to
play this: **for each thing the city can do, can a player find it, reach it, see
it, do it, and understand what happened?** A command handler existing is not one
of those five.

## The one fact underneath most of it — fixed

**This section described the state before `adapter/world.lua` existed.** It is
kept because the shape of the defect is worth remembering, and because half of
what it describes is still true.

What was true: there were **no blips, no world markers, no help prompts and no
interaction key** anywhere in the resource. Nothing in the world told a player
that anything was there, and the only way to find a shop was to already be
standing within a few metres of it and press F5 — which nothing told them to do
either.

What is true now: `me.map` says where the things a player can use are, and
`adapter/world.lua` puts a blip on each one, a marker on the ground when you are
within twenty-five metres, and a **press E** prompt within three. E opens the
counter at a shop, the bank screen at a branch, and the Around you screen at a
door that is for sale.

**Until 5412685 no player saw any of it.** The client asked for the map once, on
spawn (it asks again after a purchase and every couple of minutes since
2026-09-15), which comes before the character picker, and `me.map` refused anybody who
was not yet playing somebody. The client drew nothing and never asked again,
while every check that asked the server itself saw a full map. Fixed on the
server and measured there -- `not_playing` on the build before, `ok` after, on a
real Enhanced server. **The client half is measured now too**: on 2026-09-13 a
real FiveM client connected to rc.6 on the Enhanced server reported a mark for
each of the six places `me.map` names, and the press-E prompt standing at Rob's
Liquor and at Pillbox Hill Branch (journey-1789288733-16dc046f).

What is still true: **a blip and a prompt only appear where something is behind
them.** Jobs have neither, because an employer has no location; F6 opens the
board instead.

Six keys (`adapter/commands.lua`, `Commands.PRESSED`, plus E at a marker):

    F2  who you are today      F3  what you are carrying
    F4  your phone             F5  what is around you
    F6  who is hiring
    E   at a marker: the counter, the bank, or the door

## Capability by capability

The drawn interface can ask for nineteen things (`adapter/nui_state.lua`,
`ACTIONS`): characters, inventory, phone, shop, property, the bank counter and
work. That is the whole list. Everything else is a chat command.

| capability | discovery | presentation | verdict |
|---|---|---|---|
| characters | picker opens on spawn, and F2 | picker screen | **playable** |
| pockets | F3 | pockets screen | **playable** |
| phone | F4 | phone screen | **playable** |
| shops | blip, marker, E | shop screen | **playable** |
| property | blip while for sale, marker, E | row with price and Buy | **playable** |
| stash | through a property you own | stash screen | **playable once owned** |
| banking | blip, marker, E at a branch | bank screen | **playable** |
| jobs | F6, and `/nyrjobs` | job board screen | **playable** |
| gangs | chat only | none | **not playable** |
| police | chat only | none | **not playable** |
| fencing | chat only | none | **not playable** |
| vehicles | chat only | none | **not playable** |

### The bank button that cannot work — fixed, and it was not only banks

`me.nearby` listed every place with a **Go in** that calls `property.enter`. A
branch is held by the council and nobody lives in it, so that call is refused
every time, for everybody, forever — and the same was true of both shop
premises. On a seeded city **four of the seven rows carried a button that could
not work**.

A row now says what it offers, and the page draws that and nothing else. The
distinction is between two different refusals:

    a flat somebody else owns    refused because of who is asking today, and
                                 the same door opens the day they buy it — so
                                 it is still offered and the server still decides
    a bank branch                refused because it is not a door anybody is
                                 ever let through — so it is not offered

`Property.premises` already knew which kinds those are, and already had tests.
The server sends `enterable`, the view turns it into an `offers` list, and
`spec/nui_spec.lua` holds the general rule from both ends: nothing is offered
that the page cannot ask for, and a row with something to offer offers it.

### The bank and the job board drew as bare text — fixed

The two newest screens were never added to the stylesheet rule that puts a
screen over the game with a background behind it (`adapter/nui/style.css`), so
they would have drawn as loose text over the world. Nothing had checked what the
page draws. Found by baking the real page for the listing, fixed in 2705278, and
held by `TestScreensArePanels` in `spec/nui_spec.lua`, which fails for any screen
in `index.html` that the stylesheet does not make a panel.

Measured in a browser, over views built by the real systems: every screen draws
as a panel. **In the game's own browser it is unmeasured**, like everything else
drawn, until somebody connects.

## Against the twelve journeys

| # | journey | state |
|---|---|---|
| 1 | spawn, create/select a character | **works** — driven end to end; until a9fd79c the body then fell through the map on all three connected joins, and after it stayed on the ground |
| 2 | discover and reach a configured shop | **works, connected** — the client drew its mark; at the counter `me.nearby` names it |
| 3 | see an in-world interaction/prompt | **works, connected** — "press E" drawn at Rob's Liquor and at Pillbox Hill Branch |
| 4 | open the shop screen | works, once inside the radius; E at the counter opened it in a connected game once, pressed by a person rather than by a journey |
| 5 | see item name and price | works |
| 6 | buy an item, money and inventory exactly once | command proven; never driven through the screen |
| 7 | discover a property | server names it while for sale; the client drew a mark for every place `me.map` names, the flats among them |
| 8 | buy it through the intended UI | works (the Buy button); there is no rent |
| 9 | open its stash, store and retrieve | path exists; never driven end to end |
| 10 | start a job without chat | **works, connected** — F6 brings up the board; Take it is a button no journey presses |
| 11 | banking through its intended screen | the prompt at a branch is measured connected; **E opening the bank screen is not** — no journey can press E |
| 12 | reconnect and verify persistence | works — proven against files and MySQL |

None remain blocked on missing work.

1. ~~No in-world discovery surface~~ — fixed by `adapter/world.lua`.
2. ~~No screen for banking or jobs~~ — fixed by the bank and job board screens.

The fourteen checks that needed a connected client have been made. On
2026-09-13 a real FiveM client joined rc.6 on the Enhanced server and both
journeys completed with nothing failed and nothing unmade: the marks the client
drew, the prompt at a counter and at a branch, F5 and F6 pressed and read back,
standing at the door. The first walk of that session failed one step because a
person was pressing keys during it -- E at the counter opened the shop a second
after the walk closed Around you -- and the walk run again hands-off passed.

What no journey drives yet: E itself, so the bank screen opened from a branch;
and the buttons on a screen -- Buy, Take it, Pay in. The commands behind them
are proven; the presses are not.

What no journey could have seen: where the body goes after spawning, because
every journey moves it to a counter straight away. On all three joins that day
it fell through the map -- z 30, then 1, 2, and -57 -- and it took a recording's
first frame to show it. Fixed in a9fd79c and measured on a fourth join: the
lowest point over 45 seconds was the ground.

Until this week no connected walk could have happened at all: the journey began
seconds after its server answered, it opened a connection per request until the
server refused the address, and its server froze on a console nobody read. Each
is fixed in the toolkit lane and measured.

The remaining chat-only systems -- gangs, police, fencing, vehicles -- are
outside the twelve core journeys and are still chat-only. They are honest gaps
rather than broken paths.

## What Nyr Playtest should assert

The seven checks, as a scenario declares them per capability:

    discovery      something in the world names it without being told where
    reachability   a player can get to it and the server agrees they are there
    presentation   the screen or prompt actually appears
    action         the intended interaction completes
    feedback       the player is told what happened, in a channel they can see
    state          the authoritative state is right
    persistence    it survives a reconnect

The rule worth promoting to Nyr Core, stated once:

> Simulation existence does not imply player reachability. Every player-facing
> feature must declare and verify a discovery method, a world interaction, a
> presentation surface, and success feedback.

And the corollary this repository learned the expensive way, four times:

> The only thing that ever hands a player an id is the discovery path. If that
> path cannot name a thing, the thing is unreachable no matter how correct it
> is — and nothing fails, so nothing is logged.

## What already exists to build on

Reuse, not rebuild:

    nyrbb fivem play           scenario runner, JSON steps, save/save_from,
                               stops at the first failure
    nyrbb fivem boot --keep    a real FXServer with the staged copy
    /state                     observer: clock, players, position, spawned,
                               visible, model, which screen is up, recent log
    /act?run=<command>         driver: run any command this resource registers
    /act?show=<screen>         driver: open a screen
    /act?x=&y=&z=&h=           driver: put the body somewhere
    /do?c=<command>            the command bus directly, bypassing the client
    /log?since=N /errors       every line the server printed, drained by number;
                               what the city recorded as errors and audit
    /verify /commands          every consistency check the city has; every
                               command and what it declares
    docs/rig/rig.py            one rig: the bridge over one connection, the
                               server, the camera, the hunt that runs all of
                               the above and writes a checkable record

What is missing is not infrastructure. It is the four checks a command-bus
scenario cannot make — discovery, reachability, presentation, feedback — and a
way to say a journey failed *at the integration boundary* rather than at a step.

---

*First written from the source alone, and every claim of that kind names its
file. Where a claim has since been measured it says so and says how; where it
has not, it says unmeasured.*
