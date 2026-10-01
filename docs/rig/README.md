# The rig

One module, `rig.py`, and the scripts that order its parts into a take. Staging
holds `docs/` back, so none of this reaches a buyer's server. It is stdlib
Python; the camera and the encoder are imported only when something is filmed,
and the toolkit's journey and scenario oracles only when something is walked.

    python docs/rig/rig.py hunt                   stage, boot, walk, storm, restart, verify, record
    python docs/rig/rig.py watch --port 30120     sit on a running server and write down what goes wrong
    python docs/rig/rig.py compare --before A --after B --root <new folder>
    python docs/rig/rig.py check run/rig/<record>.json
    python docs/rig/rig.py share                  the lines another Nyr needs to find and check the latest record
    python docs/rig/test_rig.py                   its own tests (tools\spec.cmd runs them too)

Everything through a server needs `FIVEM_LICENSE_KEY` in this window's or the
user's environment. It goes on the server's command line, never into a file,
and is taken out of every console before it is written down.

## The hunt

Around ten defects have been found in this resource, almost none by a test.
Each passed the whole suite and looked exactly like the version that worked;
each was found by running the real thing and reading the result. The hunt runs
the real thing -- the shipping file set, staged as `nyr_underworld` on a fresh
city, on the real server -- and reads every result there is to read:

| phase     | what it does                                                                    | what it writes down                          |
|-----------|---------------------------------------------------------------------------------|----------------------------------------------|
| boot      | starts the server, waits for `/state` to say `open`                             | `did_not_open`, with `/errors` and the console |
| client    | with `--wait-client N`, holds the server for a person to connect                | who connected, how long it took              |
| scenarios | every `playtest/*.json` through the toolkit's own runner                        | `scenario_failed`                            |
| journeys  | every `playtest/journeys/*.json` through the toolkit's own oracle               | `journey_failed`; `unmade` for checks needing a client |
| storm     | every command, handed exactly the shapes it declares it does not accept         | `handler_failed`, `bridge_failed`, `accepted_negative`, `accepted_huge` |
| restart   | `stop`, `refresh`, `start` over rcon; the city before and after, compared       | `restart_lost`                               |
| settle    | the whole log, `/errors`, `/verify`, `/state`, the console                      | everything above that only shows at the end  |

After every command that answered `ok` during the walks, and after the storm
and the restart, `/verify` runs every consistency check the city has: the
books balance, the ownership register agrees with itself, every entity
validates, the stock, the record, the standing. A problem is `books_off`,
named with the command it followed. A line the server printed that is trouble
-- a save that failed, a tick that threw, a handler that broke -- is a finding
whatever the step it happened under said, because the log is drained by number
(`/log?since=`) and nothing scrolls past unread. Everything a client says
threw is `client_error`, numbered so a repeat is not the same line twice.

The storm runs as a player id nobody holds, which the bridge answers as the
account nobody is connected as: nothing in it runs as a connected player, and
only what the bridge refuses goes near a client. It never moves a body.

A hunt with nobody connected takes about two minutes on the Enhanced server and
answers everything a machine can answer; the journeys' checks that need a body
are reported unmade, never passed.

## The record

`run/rig/hunt-<stamp>-<server>.json`, beside its console. It carries the
commit and what was dirty, every staged file's hash and a digest over them,
the server, every phase, every finding with its evidence, the whole log, the
final `/errors` and `/verify`, and a `digest` over all of that. `previous` is
the digest of the record before it in the same folder, so a run that vanished
from the sequence is visible.

    python docs/rig/rig.py check run/rig/hunt-20260913-114529-enhanced.json

recomputes the digest, checks the console beside it is the one it was written
with, looks for the previous record, and stages the tree in front of you the
same way to say whether the record is about it -- naming the files that
differ when it is not. A record that fails any of that is not acted on.

To hand a finding to another Nyr, `share` prints the path, the digest, the
tree it is about and the check command. Those lines go into a handoff as
evidence; the record itself stays where it is. Nothing here uploads anything.

## What a person does, once

FiveM > Settings > Interface > **Localhost Port**, set to the port the session
prints, then connect to the **localhost** entry. Hands off while it walks.
Nothing on a command line connects a FiveM client: `cfx://connect`, `+connect`
warm and cold, the shell handler and the in-game console were each tried and
each refused.

`hunt --wait-client 600 --linger 900` holds the server for a connection, walks
everything with the body, and stays up afterwards while the log is watched.
`docs/store-page/film.py` and `beats.py` drive and record a take against
whichever server is up; `default_port()` finds a lingering hunt first.

## What this rig learned by running, kept here

**Name the copy `nyr_underworld`.** On the Enhanced server a resource whose
folder name has a capital letter in it cannot write a file. The resource now
refuses to start on a folder it cannot write to; the rig always stages under
the lower-case name.

**One connection to the bridge, not one per request.** Twenty-five new
connections in under a second, or one a second for half a minute, and
cfx-server 139 refuses every connection from the address -- the game client's
join included -- silently. One kept-alive connection answered four hundred
requests. A connection idle past 2.5 s is replaced before use, not after a
request has been sent down it.

**Read the server's console while it runs.** A pipe nobody reads fills at the
first save, and a server blocked writing its console answers nothing.

**Wait for `open`, not for an answer.** The bridge answers a second before the
city is read; `/do` and `/act` refuse with `not_open` until it is, and the rig
waits for `/state` to say `open` is `true` -- including after a restart.

**rcon, not stdin.** `restart` written to the server's piped stdin sat
unprocessed until something else woke the console; rcon restarted the resource
and replied every time. The password is random per session.

**A request line the HTTP layer will not take is answered in HTML.** Sixty-four
kilobytes of query gets a 414 page, not JSON. That is a refusal, and the rig
counts it as one rather than as a bridge that went silent.

**A walk stops short at a wall and a truck knocks a body down.** A body still
for twelve seconds is asked to walk again; a counter is reached by a floor
point inside, found once off camera (`stand_where_prompt`), or by a route
walked out and back (`film.py walkin`).
