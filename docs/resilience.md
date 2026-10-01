# Headless resilience candidate

This candidate combines a Windows x64 crash-interceptor library with Lua transport
and storage guards. It is an isolated source candidate. Nothing was deployed,
injected into FXServer, or started in a game. Enhanced and legacy gameplay remain
**UNKNOWN**. The Lua adapters are engine/transport glue; the current NYR-Lang
runtime cannot express asynchronous native callbacks, SEH hooks or SQL waits.
Gameplay rules remain in the existing city systems.

## Native host contract

Build with the installed MSVC x64 toolchain and existing MinHook 1.3.4 source:

```powershell
python native/headless/build.py --minhook <existing-minhook-1.3.4-source>
python native/headless/build.py --minhook <existing-minhook-1.3.4-source> --fault-injection
python native/headless/test/run_tests.py
python native/headless/test/collect_evidence.py
```

The generated `native/headless/out/nyr_headless.dll` exports
`NyrHeadlessInitialize(absolute_local_report_directory, timeout_ms)` and
`NyrHeadlessExitCode()`. A host explicitly loads it and calls initialization
**outside DllMain**, before worker activity. Initialization is process-local,
one-shot after success, and returns a Win32 error on rejected setup. The directory
must already exist and timeout must be 100–10,000 ms. UNC/drive-relative paths
are rejected. No game plugin loader, injection mechanism, server supervisor or
automatic restart is installed by this candidate.
If hook activation partially fails, initialization terminates its own host with
the same nonzero code. It cannot safely return with an unknown subset of hooks
still active. A separate test-only DLL injects this failure after activation.

It hooks `SetErrorMode`, `SetUnhandledExceptionFilter`, `MessageBoxW` and
`MessageBoxA`. Subsequent error-mode calls retain fail-critical, no-GP-fault-box
and no-open-file-box bits. Replacing the top-level exception filter is refused.
**Every** MessageBoxA/W call becomes a fatal diagnostic; this is an explicit
headless-host policy, so the library is unsuitable for an interactive client.
The DLL is pinned until process exit; no unsafe unload API is provided.

Report handles, context storage, events and a dedicated dump thread are prepared
at initialization. An unhandled exception preserves the crashing thread's
exception/context, requests `MiniDumpNormal`, emits `nyr.headless-crash/1` JSON,
flushes, then terminates its own process with `0xE04E5952`. Dialog text and captions
are not logged. Dump writing is **best effort**: failure/deadlock cannot delay
termination beyond the configured wait. A blocked writer may leave empty or
partial files. Normal exits currently leave empty preallocated report files.
No database operation or recovery write runs inside the crash path.

The policy covers those APIs after successful initialization. It does not promise
to intercept fast-fail, forced termination, arbitrary third-party dialogs,
thread-specific error modes, debugger handling, heap/loader corruption or all
stack-overflow cases. Microsoft recommends an external dump process where
possible; its documented fallback is a dedicated dump thread, and its loader
deadlock caveat is why this implementation bounds the wait.
[MiniDumpWriteDump](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump),
[SetErrorMode](https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-seterrormode).

MinHook is used unmodified from the already available 1.3.4 tree. Its BSD-style
license and the bundled HDE notices are reproduced in
`native/headless/MINHOOK-LICENSE.txt`. Raw test `.dmp` files remain local in ignored
`out/owned-crash-*` directories and must not be included in a source/report bundle.

## Client readiness and relocation

`adapter/readiness.lua` holds at most 64 requests for 15 seconds. Client
`NyrAsk` snapshots arguments and opens a reply slot only when dispatching. Two
consecutive 100-ms samples must observe a network session, an existing ped,
collision around that ped, no loading screen, and no active player switch.
A server boot epoch must also have arrived. Bootstrap hello/report events are
exempt because they establish readiness and carry no city mutation.

This is a concrete local-collision predicate, not a claim that all streamed
assets or every world chunk exist. The native only answers for its entity:
[HasCollisionLoadedAroundEntity](https://github.com/citizenfx/natives/blob/master/ENTITY/HasCollisionLoadedAroundEntity.md).
No gameplay timing or frame cost was measured in this task.

Spawn and development relocation suspend dispatch. A relocation owns a lease;
another operation cannot release it. Development moves await collision up to
20 seconds, then subsequent screen/command/walk/press actions wait for fresh
readiness samples. Two attempted simultaneous body relocations are refused or
queued through the gate, rather than allowed to release each other's gate.
Readiness loss, body replacement, server epoch change or resource stop cancels
stale callbacks. An already dispatched request is reported **outcome_unknown**;
it may have committed on the server, so it is never automatically replayed.
Late replies cannot revive the old callback. The server rejects requests carrying
an old/missing epoch before dispatch. Epochs correlate boots; they are not an
authentication boundary or a replacement for server validation/receipts.

## Restart and storage identity

The server freezes a storage identity from `GetResourcePath`, selected
`nyr_store`, `nyr_store_driver`, `nyr_store_table` convars and the exact loaded
`config.lua` text. It compares these in memory without recording the contents.
A changed/unavailable identity or selected database-resource stop latches the
guard closed, even if the value later reverts. It never follows a resource moved
mid-run and then silently calls that a successful save. File writes check before
each replacement; yielding database calls check before and after the call.
The absolute path returned by the engine is checked directly; filesystem junction
retargeting below an unchanged path and database endpoint changes hidden behind a
still-running provider are outside this observable identity.

For a planned restart, use the server console `nyr drain`, or the server-side
`exports.nyr_underworld:drain()` followed by `:drainStatus()`. The call immediately
closes network/dev-bridge/addon/admin inputs, health observations and city ticks.
It waits for an in-flight save, then saves one final snapshot. Only
`{ status = "DRAINED", safe_to_stop = true }` acknowledges the checkpoint.
`WAITING`, `SAVING`, `FAILED` and `UNKNOWN` never do. The default deadline is
30 seconds; timeout leaves the city closed and never starts an overlapping write.
The caller must wait for DRAINED before stopping or relocating the resource.
There is intentionally no automatic stop, move, restart or reopen operation.

An unplanned `onResourceStop` keeps the existing best-effort save path, but does
not start an overlapping save after a drain. A crash, forced stop, timeout or
storage change can leave the last transaction's outcome unknown. An SQL transaction
already accepted by its provider cannot safely be cancelled or rolled back here.
File storage still uses per-collection backup/readback; it is not made globally
transactional by this change. Direct trusted access to the diagnostic
`_G.NyrUnderworld.world` bypasses adapter gates and is not a supported write API.

## Evidence

The gate found zero high findings; the remaining medium findings are existing
per-frame HUD/marker loops and the review finding is the existing module loader.
Tests simulate engine facts and yielding SQL, so they establish adapter control
flow and persistence boundaries, not production gameplay or a live database's
durability.
