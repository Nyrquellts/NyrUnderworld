# Architecture

Every piece here exists because of a specific way this kind of server goes
wrong. This document names the failure before the design, because a design
without its failure is just a preference.

---

## The shape

```
interface  ->  commands  ->  simulation  ->  state  ->  events  ->  adapters
```

Read left to right for a request, right to left for a consequence.

A player presses something. The **interface** sends a named request. The
**command** layer checks it against a declaration and refuses anything that does
not fit. The **simulation** applies the rules. **State** changes. A domain
**event** says what happened. **Adapters** react: a notification, a database
write, a blip on a map.

Nothing skips a step. In particular, nothing reaches state without passing a
command, which is why the command layer can be the whole defence against a
lying client rather than one of several places that must each remember.

Everything left of `adapters` is pure Lua with no FiveM natives, no globals and
no side effects. That is not tidiness. It is what lets a whole city boot inside
a test, run seven simulated days and be asserted on, in a tenth of a second,
with no game installed.

---

## domain — the rules

### money.lua

**The failure:** a double cannot hold `0.1 + 0.2`. An economy built on floats
loses fractions of a cent on every operation, and those fractions compound into
balances nobody can explain and a total that drifts away from the sum of its
parts.

**The design:** money is an integer count of minor units. There is no float
anywhere near it, and constructing one from a fraction is refused. Every
operation that could produce a fraction names where the remainder goes:
`percent` returns the cut and what is left, `split` hands the odd unit to
somebody rather than dropping it. The spec adds a cent ten thousand times and
asserts the result is exactly one hundred, because a float would not be.

### ledger.lua

**The failure:** balances stored as a number on a player row. Two code paths
both add to it, one of them retries, and money exists that was never earned. Or
one path subtracts and the matching addition throws, and money is gone. Neither
leaves a trace, and by the time anyone notices, the economy is months into
being wrong.

**The design:** double-entry. Money is never added to an account; it is moved
between accounts, and every posting's entries sum to zero. The sum of every
balance in the world is therefore always zero, which is a single assertion an
admin can run on a live server to know the books are sound.

Money that genuinely enters or leaves the simulation crosses a named `external:`
account. A starting balance is not a number appearing; it is a posting from
`external:mint`, and the mint goes negative by exactly that much. Creation is
auditable because creation is a line.

Postings are idempotent by operation id. A retried command, a replayed event, a
duplicated packet: one posting.

The posting window is bounded, with an archive hook, because a server running
for months cannot hold every line in memory. Balances are never trimmed, and a
stored set of balances that does not sum to zero is refused at load rather than
loaded, because loading it would put money into the world from nowhere.

### id.lua

**The failure:** integer ids from a counter collide across shards and say
nothing on their own. A UUID in a log tells you nothing about what it named.

**The design:** `veh_0m4k2p8q10003x7f2ka`. The kind is in the id, so a stray id
in a support ticket says what it was. The rest is base36 at fixed widths:
milliseconds, then a per-millisecond sequence, then randomness. Fixed widths
mean text order is time order, so an index on the column is a timeline and a
sorted list of ids reads as history.

Kinds are checked, not assumed. A vehicle id handed to something expecting a
property id is refused, because that is how one system's bug becomes another
system's stolen asset.

### entity.lua

**The failure:** an entity built from a client payload with a loop that copies
every key. A field the server never meant to expose gets set, and nobody
notices until somebody has been flying for a week.

**The design:** every kind declares its fields. Unknown fields are refused, not
ignored. States are a declared graph rather than a string, so `impounded ->
spawned` is impossible by construction rather than by an if-statement somebody
forgets to write at the second call site.

Every entity carries its own provenance, capped, with a count of what was
dropped. Serialisation produces a plain table a database will take, with money
as integer minor units. A record from an older schema is migrated through a
declared function or refused; it is never half-read.

### ownership.lua

**The failure:** the duplication bug, which every server in this genre gets at
least once. Two requests arrive in the same tick, both read that Alice owns the
car, both write a new owner. One car, two owners, or one car that is now two.

**The design:** a transfer states who it believes the current owner is. If that
belief is stale the transfer is refused and nothing moves. Compare-and-swap, in
the register rather than in the caller. The second of two racing transfers names
an owner who no longer holds it, and loses.

The register keeps the chain of custody as well as the current answer, because
"who had this before it was sold to me" is a question police work, insurance and
an admin investigating a dupe all need answered.

### schema.lua

**The failure:** two implementations of "is this value acceptable" — one for
entities, one for command arguments. They drift, and the one that drifts is the
one somebody is pushing against.

**The design:** one implementation, used by both.

---

## core — the machinery

### outcome.lua

**The failure:** a boolean return. Being short of cash and a broken handler both
come back as `false`, so they are logged at the same volume and shown to the
player the same way. The log fills with normal behaviour and the real bug is
invisible in it.

**The design:** three answers. `ok`, `refused` with a code the interface can
switch on and a sentence a person can read, and `failed`, which is a bug report
and the only one that belongs in an error channel.

### events.lua

**The failure:** the simulation calls a notification function directly. The
notification resource errors, and the bank never records the transfer.

**The design:** the simulation says what happened and goes back to work. Every
handler runs inside a pcall; one failing is reported and the rest still run.
Payloads must be data a log can hold, checked at emit rather than discovered
when the save runs. A chain of events that leads back to itself is cut at a
depth limit and reported with the chain named, instead of overflowing the stack
on a live server.

### commands.lua

**The failure:** a net event handler that takes a payout amount from the client.
This is the single most common way these servers are robbed.

**The design:** a command declares what it accepts before it accepts anything.
Arguments are validated against the declaration, a clean table holding only
declared fields is built, and only that reaches the handler. Undeclared fields
are an error.

Events a handler emits are held until it succeeds. A command that fails half way
announces nothing, so no listener acts on something that did not happen.

One operation id runs once, and only a success is remembered: nothing applied
when it failed, so a retry must be free to work. A handler that mutates does it
through primitives that take the same operation id, which is why the ledger and
the ownership register both take one.

There is per-actor rate limiting and an audit trail of what was asked for and
what came back, which is the first thing to read when a player reports that
something went wrong.

### clock.lua

**The failure:** gameplay reading `os.time()`. Rent cannot be tested without
waiting a day, heat decay cannot be tested at all, and a server whose clock is
the wall clock cannot be sped up to find the bug.

**The design:** the city has its own time, driven from outside by however much
real time has passed. It can be paused, wound forward, run at any rate. The
fraction of a millisecond it is owed is carried rather than dropped, because a
clock that loses a sliver sixty times a second drifts by minutes an hour, and
players see that as rent arriving late.

### scheduler.lua

**The failure:** a pile of hand-rolled timers. Rent charged twice on one day and
never on another, and a broken task filling the log sixty times a minute until
somebody notices.

**The design:** tasks in city time, run in a reproducible order, each inside a
pcall. A task that keeps failing is stopped and said so once. Coming back from a
long freeze runs a capped number of catch-up passes and reports how many were
skipped, rather than running a backlog of hundreds.

### world.lua

**The failure:** systems reaching for globals. Two repositories over one
collection, each holding its own copy of the same vehicle; two clocks
disagreeing; a test that cannot isolate anything because everything is shared
process state.

**The design:** one object holds the clock, the books, the register, the bus,
the command door, the scheduler and the store. A system installs against it and
reaches nothing else. Asking twice for a repository gives the same one.

`verify()` asserts the invariants on a live server: the books sum to nothing,
the ownership index agrees with itself, every entity still validates. None of
those should ever be false, which is exactly why they are worth asking.

---

## persistence

### The store contract

A dumb key-value box for plain tables, knowing nothing about entities or money.
Three implementations keep it: memory for specs, JSON files for development,
and files through `LoadResourceFile`/`SaveResourceFile` inside a resource. A
database adapter keeps the same contract, and gameplay code does not change when
it arrives.

Records go in and come out deep-copied. A caller holding what it stored cannot
reach back in and change it.

### Crash safety

**The failure:** the process dies mid-write. The file on disk is half a JSON
document, the loader cannot parse it, and the server starts with an empty city
on top of it.

**The design:** write the new content somewhere else first, verify it, only then
move the current version aside, only then put the new one in place. The old file
is never removed before the new one exists. A corrupt or missing main file falls
back to the backup and *says so*; a collection that cannot be recovered at all
starts empty and says that too. Losing a city quietly is the worst outcome
available here.

### repository.lua

**The failure:** two in-memory objects for one entity. Both look correct on
their own; one gets saved and the other's changes vanish. Far harder to see than
two rows.

**The design:** an identity map. Loading an id twice gives the same table, and
saving a second object that claims a live id is refused. Validation happens at
save, where the stack still names whatever put the bad value in, rather than at
load three restarts later. Loading everything reports what would not load
instead of skipping it, because a boot that quietly drops three vehicles is
worse than one that names them.

### support/json.lua

**The failure:** most Lua JSON decoders return every number as a float. A
balance of 2,500,000 minor units comes back as `2500000.0` and fails its own
validation on load.

**The design:** an integer literal decodes as an integer and a float stays a
float. Object keys are sorted, so two saves can be diffed, and a diff is how you
find out what a bug wrote. NaN, infinity, cycles and colliding keys are refused
rather than losing data quietly. Every parser loop is bounded by the length of
the input rather than written as `while true`, because the input is untrusted
and an unbounded parser loop takes the server thread with it.

---

## systems — the gameplay

A system is a table with a name, an install function and the names of the
systems it needs. It asks the world for repositories and services, adds
commands, listens for events, schedules work, and says how to write down any
state of its own. It reaches nothing else. A system naming a requirement it
does not have is refused at boot rather than half-working in play.

### characters

**The failure:** trusting a client to say who it is. Every "is this yours"
question downstream then rests on a claim.

**The design:** the account comes from the server identifier of the connection.
One account plays one person at a time, checked in both directions, because two
live copies of one person is how one wallet gets spent twice. Somebody who was
active when the server stopped is put back offline on load, or they would be
unselectable forever with the session that held them long gone.

### memory

**The failure:** consequence that is either permanent or instant. Permanent and
nobody plays twice; instant and there is no consequence.

**The design:** two things kept apart. The record is what happened, written
whether or not anybody saw it, never edited, never expiring. Standing is what
the city currently thinks, and it drifts back toward nothing. Heat cools; the
record does not.

The mechanic falls out of keeping them apart. A crime with no witnesses raises
no heat and leaves a full record: nobody is looking for you, and the evidence is
sitting there with your name on it.

### inventory

The conservation law for things, matching the one the ledger keeps for money.
The system on top answers the other half: which containers somebody may touch.
That cannot come from the client, because "I am standing next to the trunk" is a
claim a cheat can make about any trunk in the city. Reach is a grant the server
issues and expires.

### work

**The failure:** letting the client say what a job paid, because the client
already knows and the server would have to look it up. This is the single most
common way these servers are robbed.

**The design:** `work.finish` declares no arguments at all. There is nothing to
put a number into.

### property and vehicles

Where the earlier promises meet. Who holds it is the ownership register, so two
buyers in one tick cannot both win. What it costs is the ledger. When rent falls
due is the scheduler. What happened to it is the record.

Being at the door is asked of a proximity service and refused when none is
installed, because failing closed is the only acceptable default for a lock.

Taking a car that is not yours is a crime, not a refusal. Refusing it makes
theft impossible and the city poorer; treating it as a crime means it works, it
costs something, and the city writes it down. Who saw it is decided by the
server, because a command that took a witness list would let the thief declare
that nobody saw them.

### banking

**The failure:** a bank account stored as a second number, alongside the
wallet. Now there are two places money lives, two code paths that add to a
balance, and a statement kept separately that can disagree with both.

**The design:** an account is the same ledger with a different account name.
There is no second place money can live and no path that adds rather than
moves, so everything the ledger already promises is true of banking for free. A
statement is read straight off the ledger history, which is why it cannot
disagree with the balance.

A transfer goes by a printed account number rather than a character id: a
number is a thing a person can read out, and a character id is an internal
identifier a client should never need to know and should never be trusted to
supply. The number is looked up before a single unit moves, so a typo costs
nothing.

A transfer command is also the fastest way to launder a duplication bug, since
it turns money that should not exist into money in somebody else's account in
one hop. Every case in the spec ends by asserting the books still sum to
nothing, including the cases that fail.

### police

The mirror of the work rule, pointed the other way: the officer never says what
the charge is. An arrest names a person; the server reads the record, works out
what they are wanted for, and looks up what it costs.

What somebody is wanted for is derived, not stored: the crimes on their record,
that somebody saw, since their last arrest. Nothing has to be kept in step, and
an arrest closes the lot by being written down after them.

---

## adapter — the only files that know FiveM exists

### The seam

Everything above the adapter is the simulation and knows nothing about FiveM.
Everything in the adapter is FiveM and knows nothing about the rules. The day
this runs on a different framework, or a different game, only these files
change.

### loader.lua

A FiveM resource has one shared namespace and no module system. Every file in
the manifest executes into the same globals, in order. That is workable for a
script and unworkable for a simulation of fifty modules that each need to be
testable alone.

So the manifest lists two entry points and the loader supplies `require` over
them, reading modules out of the resource on demand. The modules are ordinary
Lua with ordinary returns, which is why they run unchanged under a plain
interpreter. The module name is validated as a dotted identifier before it
becomes a path, so nothing can be talked into reaching outside the resource.

### bridge.lua — where an untrusted client meets the simulation

Everything a client sends is a suggestion. The bridge establishes four things
the client does not get a say in:

1. **Which commands exist for clients at all.** An allowlist, not a deny list. A
   command added tomorrow is unreachable from a client until somebody puts it on
   the list deliberately.
2. **Who is asking.** The account comes from the server identifier of the socket
   the message arrived on, never from the payload.
3. **Who they are being.** The acting character is whatever the session says
   they selected. A client naming a character id has it ignored.
4. **Which operation this is.** A client-supplied idempotency token is
   namespaced by account before use. Without that, one player could send a token
   and have another player's later request swallowed as a duplicate of it.

What goes back is the outcome summary and nothing else. A failure carries no
detail, because a stack trace is for the server log and not for whoever is
poking at the server.

---

## What this buys

A city that can be booted, driven for a simulated week, restarted from disk and
asserted on, in a test, in milliseconds, with no game installed. That is the
difference between finding a rent bug in a spec and finding it on a live server
on a Saturday night.
