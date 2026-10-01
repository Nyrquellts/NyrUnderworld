"""One rig for NYR Underworld: the bridge, a server, a camera, and the hunt.

This used to be four scripts that each carried their own copy of the same
thing -- a way to talk to the dev bridge, a way to start a server, a way to
wait for a body -- and each copy had drifted a little from the others. One had
the port typed wrong. One opened a new connection per request and locked the
player's own client out of the server. One read the console and three did not.
The lessons each one learned stayed in that one file.

So: one module. Everything here is stdlib; the camera and the encoder are
imported only when something is recorded, and the toolkit's journey and
scenario oracles only when something is walked, so the rig runs on a machine
with neither.

    python rig.py hunt                 stage, boot, walk, storm, restart, verify, record
    python rig.py watch --port 30120   sit on a running server and write down what goes wrong
    python rig.py compare --before A --after B
                                       one connection, two walks, a restart in between
    python rig.py check <record.json>  is this record intact, and about this tree
    python rig.py share <record.json>  the lines another Nyr needs to find and check it

What the hunt is for
--------------------
Around ten defects have been found in this resource. Almost none by a test.
Each passed the whole suite and looked exactly like the version that worked;
each was found by running the real thing and reading the result. The hunt runs
the real thing -- the shipping file set, on the real server -- and reads every
result there is to read:

    every line the server prints, drained by number so none scroll away
    every consistency check the city has, after every command that changed it
    everything a client says threw, numbered so a repeat is not the same line
    every command, handed exactly the shapes it declares it does not accept
    the city before and after a restart, because "it saved" is a claim

What it writes is a record another Nyr can check without trusting the one who
wrote it: every staged file's hash, the commit and what was dirty, the whole
log, every finding, and a digest over all of it. `check` recomputes the digest
and says whether the tree it describes is the tree in front of you.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import math
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

RIG_VERSION = "1"
SCHEMA = "nyr.rig-record/v1"
NAME = "nyr_underworld"

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / "run" / "rig"
VENDOR = Path(os.environ.get("NYR_VENDOR_BIN", r"C:\Dev\NyrsBBDevKit\vendor\bin"))
TOOLKIT = Path(os.environ.get("NYRBB_SRC", "C:/Dev/worktrees/fivem/src"))

# What does not ship, read the way the release stage reads it. `data/` is not
# here: its README ships, and its saves are held back by .nyrignore -- so a
# staged copy always starts on a fresh city.
DEV_DIRS = ("spec", "tools", "playtest", "research", "docs", "node_modules", "run",
            "cache", "dist")
TOOL_DIRS = (".git", ".github", ".vscode", ".vs", ".idea", ".history", ".claude",
             ".codex", ".cursor")
DEV_FILES = (".gitignore", ".gitattributes", ".luarc.json", ".editorconfig",
             "LEDGER.md", ".nyrignore")
DEV_SUFFIXES = (".bak", ".tmp", ".log", ".pyc", ".orig", ".rej")

# The kept-alive connection is dropped by the server after a few idle seconds,
# and a request sent down a dead one may or may not have run. Replaced before
# use once it has sat this long -- the toolkit's driver measured the same.
KEEPALIVE_IDLE_S = 2.5

_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_KEY = re.compile(r"\bcfxk_[A-Za-z0-9_]{6,}")


def say(line: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {line}", flush=True)


#: Where the lines a record is shared by go. `print`, except in the rig's own
#: tests, which have no one to hand a record to.
tell = print


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


_IDENTIFIER = re.compile(r"^(license2?|steam|discord|fivem|xbl|live|ip):(.+)$")
_IDENTIFIER_IN_TEXT = re.compile(r"\b(license2?|steam|discord|fivem|xbl|live):([0-9A-Za-z]{8,})")


def scrub(text: str, *secrets_known: str) -> str:
    """A console with the licence key, the session's password and every
    platform identifier taken out.

    The key both by value and by shape: a key that was never handed in -- one
    a server printed from its own convar -- is still a key. Identifiers
    because a record is about the city, not about who was connected to it.
    """
    for secret in secrets_known:
        if secret:
            text = text.replace(secret, "<secret>")
    text = _IDENTIFIER_IN_TEXT.sub(r"\1:<redacted>", text)
    return _ANSI.sub("", _KEY.sub("<licence key>", text))


def redacted(value: Any) -> Any:
    """The same value with platform identifiers reduced to their kind and a short hash.

    A connected player's licence, Steam or Discord identifier reaches the
    record through /state and through every journey step's client snapshot.
    Another Nyr needs to tell player 1 from player 4; nobody needs who they are.
    """
    if isinstance(value, dict):
        return {k: redacted(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redacted(v) for v in value]
    if isinstance(value, str):
        found = _IDENTIFIER.match(value)
        if found:
            return f"{found.group(1)}:{hashlib.sha256(found.group(2).encode('utf-8')).hexdigest()[:12]}"
    return value


def default_port(fallback: int = 30132) -> int:
    """The port of the server most likely to be up: a lingering hunt, else the capture stage.

    Typed again in a second file, a port was 30130 against a server staged on
    30132, and the rig talked to nothing at the one moment somebody was
    sitting at a keyboard waiting for it.
    """
    session = RUN / "session.json"
    try:
        port = int(json.loads(session.read_text(encoding="utf-8")).get("port"))
        with socket.create_connection(("127.0.0.1", port), timeout=1.0):
            return port
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    cfg = Path(os.environ.get("LOCALAPPDATA", "")) / "NyrUnderworld" / "capture3" / "server.cfg"
    try:
        found = re.search(r"endpoint_add_tcp\s+\"[^\"]*:(\d+)\"", cfg.read_text(encoding="utf-8"))
        if found:
            return int(found.group(1))
    except OSError:
        pass
    return fallback


# ------------------------------------------------------------------ the bridge


class BridgeSilent(OSError):
    """The bridge gave no answer at all, which is not the same as a refusal."""


class Bridge:
    """The resource's dev bridge, over one kept-alive connection.

    One, because the server refuses every connection from an address that
    opens them quickly -- the player's own client included -- and says nothing
    about it. Measured on cfx-server 139: twenty-five in under a second was
    enough. One kept-alive connection answered four hundred.

    The methods the toolkit's oracles call are here under the names they call
    them by, so a journey or a scenario can be walked through this object
    without a second connection being opened beside it.
    """

    def __init__(self, port: int, resource: str = NAME) -> None:
        self.port, self.resource = port, resource
        self.base = f"http://127.0.0.1:{port}/{resource}"
        self._conn: http.client.HTTPConnection | None = None
        self._used = 0.0
        self.connections = 0
        self.target = 1
        self.city_open: bool | None = None
        self.last_status: int | None = None
        # The log, drained by number: every line since the first drain, and how
        # many were lost to a drain that came too late.
        self.seq = 0
        self.lines: list[dict[str, Any]] = []
        self.dropped = 0
        # Called after every /do with (command, args, answer), so the hunt can
        # verify the city after each command without every caller knowing.
        self.after_do: list[Callable[[str, dict[str, Any], dict[str, Any]], None]] = []
        self.requests = 0

    # -- the wire

    def _drop(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            except OSError:
                pass
        self._conn = None

    def close(self) -> None:
        self._drop()

    def _get(self, path: str, timeout: float = 8.0, retries: int = 0) -> Any:
        """One request. Reads may be retried; a command is sent once."""
        last: Exception | None = None
        for attempt in range(retries + 1):
            if self._conn is not None and time.monotonic() - self._used > KEEPALIVE_IDLE_S:
                self._drop()
            if self._conn is None:
                self._conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
                self.connections += 1
            else:
                self._conn.timeout = timeout
                if self._conn.sock is not None:
                    self._conn.sock.settimeout(timeout)
            try:
                self.requests += 1
                self._conn.request("GET", f"/{self.resource}{path}")
                response = self._conn.getresponse()
                body = response.read()
            except (OSError, http.client.HTTPException) as error:
                self._drop()
                last = error
                if attempt < retries:
                    time.sleep(0.5 * (attempt + 1))
                    continue
                raise BridgeSilent(f"the bridge did not answer {path[:80]}: {error!r}") from error
            finally:
                self._used = time.monotonic()
            if response.will_close:
                self._drop()
            self.last_status = response.status
            text = body.decode("utf-8", "replace")
            try:
                return json.loads(text) if text else {}
            except json.JSONDecodeError:
                # The server answered, with something that is not the bridge's
                # -- the HTTP layer refusing a request line it will not take,
                # mostly. That is an answer, and its status says which kind.
                return {"ok": False, "code": "not_json", "status": response.status, "text": text[:200]}
        raise BridgeSilent(f"the bridge did not answer {path[:80]}: {last!r}")

    # -- reads

    def state(self) -> dict[str, Any]:
        return self._get("/state", retries=2)

    def ready(self, seconds: float, alive: Callable[[], bool] | None = None) -> bool:
        """Wait for the bridge to answer and for the city behind it to be open.

        Not for the port, and not for the bridge: it answers a second before
        the city has been read, and a command sent in that second acts on a
        city that is not there. `open` is the field that says, and only `True`
        is a yes.
        """
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if alive is not None and not alive():
                return False
            try:
                said = self._get("/state", timeout=3.0)
            except BridgeSilent:
                time.sleep(1.0)
                continue
            opened = said.get("open") if isinstance(said, dict) else None
            self.city_open = opened if isinstance(opened, bool) else None
            if opened is True:
                return True
            time.sleep(0.5)
        return False

    def watching(self) -> dict[str, Any]:
        """What the client being driven says about itself, or nothing."""
        try:
            people = [p for p in (self.state().get("players") or []) if isinstance(p, dict)]
        except BridgeSilent:
            return {}
        reporting = [p for p in people if p.get("reporting")]
        driven = [p for p in reporting if p.get("id") == self.target]
        chosen = driven or reporting or people
        return chosen[0] if chosen else {}

    player = watching

    def has_client(self) -> bool:
        return bool(self.watching().get("reporting"))

    def has_body(self) -> bool:
        who = self.watching()
        return bool(who.get("reporting")) and who.get("spawned") is True

    def adopt(self) -> int:
        who = self.watching()
        found = who.get("id")
        if who.get("reporting") and isinstance(found, int) and not isinstance(found, bool) and found > 0:
            self.target = found
        return self.target

    def await_body(self, seconds: float, every: float = 2.0) -> bool:
        deadline = time.monotonic() + seconds
        while not self.has_body():
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            time.sleep(min(every, left))
        return True

    def drain(self) -> list[dict[str, Any]]:
        """Every log line since the last drain, kept, and the loss counted."""
        page = self._get(f"/log?since={self.seq}", retries=2)
        fresh = [line for line in (page.get("log") or []) if isinstance(line, dict)]
        self.lines.extend(fresh)
        self.seq = int(page.get("seq") or self.seq)
        self.dropped += int(page.get("dropped") or 0)
        return fresh

    def verify(self) -> dict[str, Any]:
        return self._get("/verify", retries=2)

    def errors(self, limit: int = 50) -> dict[str, Any]:
        return self._get(f"/errors?limit={limit}", retries=2)

    def commands(self) -> dict[str, Any]:
        return self._get("/commands", retries=2)

    # -- acts

    def do(self, command: str, args: dict[str, Any] | None = None,
           player: int | None = None, **more: Any) -> dict[str, Any]:
        """Run a command as a player, once, and hand back exactly what was answered."""
        given = dict(args or {}, **more)
        query = urllib.parse.urlencode({"p": str(self.target if player is None else player),
                                        "c": command, "a": json.dumps(given)})
        answer = self._get(f"/do?{query}")
        if not isinstance(answer, dict):
            answer = {"ok": False, "why": f"the bridge answered /do with {type(answer).__name__}"}
        for hook in self.after_do:
            hook(command, given, answer)
        return answer

    def raw(self, path: str) -> dict[str, Any]:
        """A path exactly as written, for sending the bridge what it does not expect."""
        answer = self._get(path, timeout=8.0)
        return answer if isinstance(answer, dict) else {"_answer": answer}

    def act(self, **what: Any) -> dict[str, Any]:
        query = urllib.parse.urlencode({"p": str(self.target), **{k: str(v) for k, v in what.items()}})
        answer = self._get(f"/act?{query}")
        if isinstance(answer, dict) and answer.get("ok"):
            return answer
        if isinstance(answer, dict) and answer.get("why"):
            return {"ok": False, "why": answer["why"]}
        return {"ok": False, "why": f"the bridge refused /act with {self.last_status}"}


# -------------------------------------------------- what a body is doing


def position(who: dict[str, Any]) -> tuple[float, float, float] | None:
    try:
        x, y, z = (float(part) for part in str(who.get("pos")).split(","))
        return x, y, z
    except (TypeError, ValueError):
        return None


def wait_for(bridge: Bridge, holds: Callable[[dict[str, Any]], Any], seconds: float,
             every: float = 1.5) -> dict[str, Any] | None:
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        who = bridge.watching()
        if who and holds(who):
            return who
        time.sleep(every)
    return None


def prompt_says(text: str) -> Callable[[dict[str, Any]], bool]:
    return lambda who: text in str(who.get("prompt") or "")


def showing(screen: str) -> Callable[[dict[str, Any]], bool]:
    return lambda who: bool(who.get("nui")) and str(who.get("showing") or "").startswith(screen)


def walk(bridge: Bridge, to: tuple[float, float, float], seconds: float, *, pace: str = "walk",
         arrive_m: float = 2.0, until_prompt: str | None = None, nudge_after: float = 12.0) -> bool:
    """Walk the body there by the game's own route finding, and say whether it arrived.

    Arrival is either standing within `arrive_m` of the point or, when
    `until_prompt` is given, the press-E prompt for that place being up --
    which is the only arrival that matters for a counter. A body that has
    stood still for `nudge_after` seconds is asked to walk again: a delivery
    truck knocked one down mid-run on 2026-09-13, and the walk had ended.
    """
    x, y, z = to
    bridge.act(wx=x, wy=y, wz=z, pace=pace)
    last, still_since = None, time.monotonic()
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        who = bridge.watching()
        if until_prompt is not None and prompt_says(until_prompt)(who):
            return True
        here = position(who)
        if until_prompt is None and here and math.dist(here[:2], (x, y)) <= arrive_m:
            return True
        if here and last and math.dist(here[:2], last[:2]) < 0.5:
            if time.monotonic() - still_since > nudge_after:
                say("  the walk has stopped short; asking the game to walk it again")
                bridge.act(wx=x, wy=y, wz=z, pace=pace)
                still_since = time.monotonic()
        else:
            still_since = time.monotonic()
        last = here
        time.sleep(1.5)
    return False


def stand_where_prompt(bridge: Bridge, candidates: list[tuple[float, float, float]], prompt: str,
                       floor: tuple[float, float] = (27.0, 30.5), settle: float = 3.0):
    """The first of `candidates` where the prompt is up and the body has not dropped.

    A move to a counter's own point stood the body on the counter, and the
    game's ground search chose the pavement twenty metres away. Floor points
    inside are tried in turn, off camera, and the one that works is kept.
    """
    for x, y, z in candidates:
        bridge.act(x=x, y=y, z=z)
        time.sleep(settle)
        who = bridge.watching()
        here = position(who)
        say(f"  tried {x}, {y}, {z}: now at {who.get('pos')}, prompt {who.get('prompt')!r}")
        if here and floor[0] < here[2] < floor[1] and prompt in str(who.get("prompt") or ""):
            return (x, y, z)
    return None


def become(bridge: Bridge, first: str, last: str) -> str | None:
    """Be somebody, whether or not this account is already playing one."""
    bridge.do("character.release")
    listed = bridge.do("character.list").get("value") or {}
    for row in listed.get("characters") or []:
        if row.get("name") == f"{first} {last}":
            bridge.do("character.select", character=row["character"])
            return row["character"]
    made = bridge.do("character.create", first_name=first, last_name=last).get("value")
    character = made.get("character") if isinstance(made, dict) else made
    if character:
        bridge.do("character.select", character=character)
    return character


def wallet(bridge: Bridge) -> int:
    return int((bridge.do("me.status").get("value") or {}).get("wallet") or 0)


def earn_until(bridge: Bridge, price: int, ceiling: float = 900.0) -> None:
    """Work shifts until `price` is affordable, through the board a player uses."""
    until = time.monotonic() + ceiling
    while wallet(bridge) < price and time.monotonic() < until:
        picked = None
        for employer in (bridge.do("work.list").get("value") or {}).get("employers", []):
            if not employer.get("hiring"):
                continue
            for job in employer.get("jobs", []):
                if job.get("ready_in", 0) == 0:
                    picked = (employer["employer"], job["job"], employer["name"], job["label"])
                    break
            if picked:
                break
        if not picked:
            say("    nobody is hiring anybody who is not cooling down; waiting")
            time.sleep(5)
            continue
        employer_id, job_id, employer_name, job_label = picked
        started = bridge.do("work.start", employer=employer_id, job=job_id)
        if not started.get("ok"):
            time.sleep(2)
            continue
        minutes = (started.get("value") or {}).get("minutes") or 1
        say(f"    on a shift: {job_label} for {employer_name} ({minutes} minutes)")
        time.sleep(max(1.0, min(60.0, float(minutes))))
        while time.monotonic() < until:
            done = bridge.do("work.finish")
            if done.get("ok"):
                say(f"      paid; wallet now {wallet(bridge)}")
                break
            if done.get("code") != "not_done":
                say(f"      the shift ended badly: {done.get('code')}")
                break
            time.sleep(2)


# ---------------------------------------------------------------- the camera


class Recorder:
    """The main screen, at 30 frames a second, into an H.264 file."""

    def __init__(self, path: Path, fps: int = 30) -> None:
        import dxcam  # only when something is filmed
        self.path = path
        self.cam = dxcam.create(output_color="BGRA")
        frame = None
        for _ in range(60):
            frame = self.cam.grab()
            if frame is not None:
                break
            time.sleep(0.05)
        if frame is None:
            raise SystemExit("the screen gave no frame")
        height, width = frame.shape[:2]
        ffmpeg = self.ffmpeg()
        encoder = ["-c:v", "h264_nvenc", "-preset", "p5", "-cq", "21"]
        if b"h264_nvenc" not in subprocess.run([ffmpeg, "-hide_banner", "-encoders"],
                                               capture_output=True).stdout:
            encoder = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
        self.proc = subprocess.Popen(
            [ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra",
             "-s", f"{width}x{height}", "-r", str(fps), "-i", "-",
             "-vf", "scale=1920:-2", *encoder, "-pix_fmt", "yuv420p", str(path)],
            stdin=subprocess.PIPE)
        self.latest = frame
        self.started = time.time()
        self.running = True
        self.cam.start(target_fps=fps, video_mode=True)
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    @staticmethod
    def ffmpeg() -> str:
        found = shutil.which("ffmpeg")
        if found:
            return found
        for candidate in sorted(Path(os.environ.get("LOCALAPPDATA", "")).glob(
                "Microsoft/WinGet/Packages/Gyan.FFmpeg_*/ffmpeg-*/bin/ffmpeg.exe")):
            return str(candidate)
        raise SystemExit("no ffmpeg on PATH or under WinGet")

    def _pump(self) -> None:
        while self.running:
            frame = self.cam.get_latest_frame()
            if frame is None:
                continue
            self.latest = frame
            try:
                self.proc.stdin.write(frame.tobytes())
            except (BrokenPipeError, OSError):
                break

    def at(self) -> float:
        return round(time.time() - self.started, 2)

    def still(self, path: Path) -> None:
        from PIL import Image
        image = Image.fromarray(self.latest[:, :, [2, 1, 0]])
        image.resize((1920, round(image.height * 1920 / image.width)), Image.LANCZOS).save(path)

    def stop(self) -> None:
        self.running = False
        self.thread.join(timeout=5)
        self.cam.stop()
        self.proc.stdin.close()
        self.proc.wait(timeout=300)


class Camera:
    """The screen as frames, for a still or a short loop."""

    def __init__(self) -> None:
        import dxcam
        self.cam = dxcam.create(output_color="BGRA")

    def shot(self, width: int = 1280):
        from PIL import Image
        frame = None
        for _ in range(12):
            frame = self.cam.grab()
            if frame is not None:
                break
            time.sleep(0.05)
        if frame is None:
            raise SystemExit("the screen gave no frame")
        image = Image.fromarray(frame[:, :, [2, 1, 0]])
        if image.width > width:
            image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
        return image

    def clip(self, seconds: float, fps: int = 8, width: int = 1280) -> list:
        frames, step, until = [], 1.0 / fps, time.time() + seconds
        while time.time() < until:
            frames.append(self.shot(width))
            time.sleep(max(0.0, step - 0.02))
        return frames

    def close(self) -> None:
        del self.cam


def save_loop(frames: list, path: Path, ms: int = 125) -> None:
    if frames:
        frames[0].save(path, save_all=True, append_images=frames[1:], duration=ms, loop=0,
                       quality=72, method=4)


# ---------------------------------------------------------------- the server


def licence_key() -> str:
    """The key, from this window's environment or the user's. Never printed."""
    found = os.environ.get("FIVEM_LICENSE_KEY", "").strip()
    if not found and sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                found = str(winreg.QueryValueEx(key, "FIVEM_LICENSE_KEY")[0]).strip()
        except OSError:
            found = ""
    if not found:
        raise SystemExit("FIVEM_LICENSE_KEY is not set: both servers refuse to start without one")
    return found


def server_exe(flavour: str) -> tuple[Path, Path | None]:
    """The server binary for a flavour, and the citizen dir legacy needs beside it."""
    if flavour == "enhanced":
        for folder in sorted(VENDOR.glob("cfx-server-*")):
            exe = folder / "cfx-server.exe"
            if exe.is_file():
                return exe, None
        raise SystemExit(f"no enhanced server (cfx-server-*/cfx-server.exe) under {VENDOR}")
    if flavour == "legacy":
        for folder in sorted(VENDOR.glob("fivem-server-*")):
            exe = folder / "FXServer.exe"
            if exe.is_file():
                return exe, folder / "citizen"
        raise SystemExit(f"no legacy server (fivem-server-*/FXServer.exe) under {VENDOR}")
    raise SystemExit(f"a server is legacy or enhanced, not {flavour!r}")


def free_port(preferred: int, span: int = 40) -> int:
    for port in range(preferred, preferred + span):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise SystemExit(f"no free port between {preferred} and {preferred + span}")


def config_text(port: int, password: str) -> str:
    return "\n".join([
        "# Written per session by docs/rig/rig.py. Disposable; never edit in place.",
        f'endpoint_add_tcp "127.0.0.1:{port}"',
        f'endpoint_add_udp "127.0.0.1:{port}"',
        "sv_maxclients 2",
        'sv_hostname "nyr-rig"',
        "sv_scriptHookAllowed 0",
        'sv_master1 ""',
        "sv_lan 1",
        f'rcon_password "{password}"',
        f"ensure {NAME}",
    ]) + "\n"


class Session:
    """One disposable server on loopback, its console read as it runs.

    Read as it runs, because a pipe nobody reads fills at the first save and a
    server blocked writing its console answers nothing. The licence key goes on
    the command line and never into a file; the rcon password is random per
    session; both are taken out of the console before it is written down.
    """

    def __init__(self, root: Path, port: int, flavour: str) -> None:
        self.root, self.port, self.flavour = root, port, flavour
        self.password = secrets.token_hex(16)
        self.key = licence_key()
        self.lines: list[str] = []
        self.proc: subprocess.Popen | None = None
        self.exe, self.citizen = server_exe(flavour)
        # The Enhanced server prints no version line at all, so the build is
        # taken from the vendored folder's name and replaced by what the
        # console says on a server that says it.
        self.build: str | None = self.exe.parent.name.rsplit("-", 1)[-1] or None

    def launch(self) -> None:
        (self.root / "server.cfg").write_text(config_text(self.port, self.password), encoding="utf-8")
        command = [str(self.exe)]
        if self.citizen is not None:
            command += ["+set", "citizen_dir", str(self.citizen)]
        # The rcon password on the command line as well as in the config: the
        # legacy server answered every rcon command from a config that set it
        # with "The server must set rcon_password", and a restart that never
        # happened read as one that did.
        command += ["+set", "onesync", "on", "+set", "sv_licenseKey", self.key,
                    "+set", "rcon_password", self.password, "+exec", "server.cfg"]
        self.proc = subprocess.Popen(command, cwd=str(self.root), stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                     errors="replace")
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        for line in self.proc.stdout:
            self.lines.append(line)
            if self.build is None:
                found = re.search(r"server version\s+([^\s]+)|FXServer[^\n]*?v?(\d+\.\d+\.\d+\.\d+)", line)
                if found:
                    self.build = found.group(1) or found.group(2)

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def rcon(self, command: str) -> str:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(5)
            sock.sendto(b"\xff\xff\xff\xffrcon " + self.password.encode() + b" " + command.encode(),
                        ("127.0.0.1", self.port))
            try:
                return sock.recvfrom(8192)[0][4:].decode("utf-8", "replace").strip()
            except OSError as error:
                return f"no reply: {error!r}"

    @staticmethod
    def rcon_refused(reply: str) -> bool:
        """Whether rcon did not do what it was asked, whatever it printed."""
        low = reply.lower()
        return (low.startswith("no reply") or "must set rcon_password" in low
                or "invalid password" in low or "bad rconpassword" in low)

    def restart_resource(self, bridge: "Bridge | None" = None, wait_s: float = 4.0,
                         fresh: Path | None = None) -> dict[str, Any]:
        """Stop the resource, refresh, start it again, and say what actually happened.

        With `fresh`, the resource's saved city under that folder is cleared
        between the stop and the start, so what starts is a city nobody has
        played: the scenarios and the journeys each assume one, and run on the
        same account.

        `stopped` is read back, not assumed: rcon that was refused, and a
        bridge that kept answering `open` after the stop, each mean the
        resource never stopped -- and a wipe under a running city is written
        straight back by its next save. That happened.
        """
        said: dict[str, Any] = {"stop": self.rcon(f"stop {NAME}")}
        said["stopped"] = not self.rcon_refused(said["stop"])
        if bridge is not None and said["stopped"]:
            # The bridge answering `open` two seconds after a stop is a stop
            # that did not happen, whatever rcon printed.
            deadline = time.monotonic() + wait_s
            still_open = True
            while time.monotonic() < deadline and still_open:
                try:
                    still_open = bridge.state().get("open") is True
                except BridgeSilent:
                    still_open = False
                if still_open:
                    time.sleep(0.5)
            said["stopped"] = not still_open
            bridge.close()
        else:
            time.sleep(wait_s)
        if not said["stopped"]:
            said["why"] = "the resource did not stop, so nothing was cleared or restarted"
            return said
        if fresh is not None:
            for stale in (fresh / "data").glob("*.json*"):
                stale.unlink()
            said["cleared"] = "data/*.json*"
        said["refresh"] = self.rcon("refresh")
        time.sleep(1)
        said["start"] = self.rcon(f"start {NAME}")
        said["started"] = not self.rcon_refused(said["start"])
        return said

    def console(self) -> str:
        return scrub("".join(self.lines), self.key, self.password)

    def stop(self) -> Path:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        path = self.root / "console.log"
        path.write_text(self.console(), encoding="utf-8")
        return path


# ---------------------------------------------------------------- the stage


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ignored_patterns(source: Path) -> list[str]:
    path = source / ".nyrignore"
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def ships(relative: str, patterns: list[str]) -> bool:
    """Whether a path inside the resource reaches a buyer, by the stage's rules."""
    parts = relative.split("/")
    if any(part in TOOL_DIRS for part in parts):
        return False
    if parts[0] in DEV_DIRS:
        return False
    if parts[-1] in DEV_FILES:
        return False
    if Path(parts[-1]).suffix.lower() in DEV_SUFFIXES:
        return False
    for pattern in patterns:
        if re.fullmatch(pattern.replace(".", r"\.").replace("*", ".*"), relative):
            return False
    return True


def shipping_hashes(source: Path) -> dict[str, str]:
    """Every file that would be staged, with its hash, without copying anything."""
    patterns = ignored_patterns(source)
    out = {}
    for path in sorted(source.rglob("*")):
        if path.is_file():
            relative = path.relative_to(source).as_posix()
            if ships(relative, patterns):
                out[relative] = sha256_of(path)
    return out


def staged_digest(files: dict[str, str]) -> str:
    lines = "\n".join(f"{name} {files[name]}" for name in sorted(files))
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def stage(source: Path, dest: Path) -> dict[str, str]:
    """Copy what ships into `dest`, on a fresh city, and hand back every file's hash."""
    if dest.exists():
        shutil.rmtree(dest)
    patterns = ignored_patterns(source)
    hashes = {}
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(source).as_posix()
        if not ships(relative, patterns):
            continue
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        hashes[relative] = sha256_of(target)
    (dest / "data").mkdir(exist_ok=True)
    return hashes


def git_identity(source: Path) -> dict[str, Any]:
    def git(*args: str) -> str:
        try:
            return subprocess.run(["git", "-C", str(source), *args], capture_output=True, text=True,
                                  timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            return ""
    # Each status line is two status letters, a space, the path -- and the
    # first letter of the first line is a space for a file only modified, so
    # the output is split before anything is stripped.
    dirty = [line[3:] for line in git("status", "--porcelain", "--untracked-files=no").splitlines()
             if len(line) > 3]
    return {"commit": git("rev-parse", "HEAD").strip() or None,
            "branch": git("rev-parse", "--abbrev-ref", "HEAD").strip() or None, "dirty": dirty}


# ---------------------------------------------------------------- the record


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest_of(record: dict[str, Any]) -> str:
    body = {k: v for k, v in record.items() if k != "digest"}
    return hashlib.sha256(canonical(body)).hexdigest()


def seal(record: dict[str, Any]) -> dict[str, Any]:
    record["digest"] = digest_of(record)
    return record


def latest_record(folder: Path) -> Path | None:
    found = sorted(folder.glob("*.json")) if folder.is_dir() else []
    return found[-1] if found else None


def check_record(path: Path, source: Path | None = None) -> dict[str, Any]:
    """Whether a record is intact, and whether it describes the tree in `source`."""
    out: dict[str, Any] = {"record": str(path), "intact": False, "about_this_tree": None,
                           "console_intact": None, "previous_found": None, "problems": []}
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        out["problems"].append(f"unreadable: {error}")
        return out
    if record.get("schema") != SCHEMA:
        out["problems"].append(f"schema is {record.get('schema')!r}, not {SCHEMA}")
    claimed = record.get("digest")
    actual = digest_of(record)
    out["intact"] = claimed == actual
    if not out["intact"]:
        out["problems"].append(f"digest {str(claimed)[:12]} does not match the content {actual[:12]}: "
                               "something in this record was changed after it was written")
    out["digest"] = actual
    out["verdict"] = record.get("verdict")
    out["findings"] = len(record.get("findings") or [])
    console = record.get("console") or {}
    console_path = path.parent / str(console.get("file") or "")
    if console.get("file"):
        if console_path.is_file():
            out["console_intact"] = sha256_of(console_path) == console.get("sha256")
            if not out["console_intact"]:
                out["problems"].append("console.log beside the record is not the one it was written with")
        else:
            out["console_intact"] = None
            out["problems"].append(f"console.log is not beside the record ({console_path.name})")
    previous = record.get("previous")
    if previous:
        chain = latest_record_with(path.parent, previous)
        out["previous_found"] = chain is not None
        if chain is None:
            out["problems"].append(f"the previous record {previous[:12]} is not in {path.parent}")
    out["notes"] = []
    if source is not None:
        resource = record.get("resource") or {}
        if not resource.get("staged_files"):
            # A watch on a server the rig did not stage describes no tree, and
            # that is not a fault in the record; it is a thing it cannot say.
            out["notes"].append("this record describes no tree (a watch on a server the rig did not "
                                "stage), so it cannot be matched to one")
            return out
        here = staged_digest(shipping_hashes(source))
        out["about_this_tree"] = here == resource.get("staged_digest")
        if not out["about_this_tree"]:
            files = resource.get("staged_files") or {}
            current = shipping_hashes(source)
            changed = sorted(name for name in set(files) | set(current) if files.get(name) != current.get(name))
            out["changed_files"] = changed[:40]
            out["problems"].append(f"this record is about a different tree: {len(changed)} file(s) differ")
    return out


def latest_record_with(folder: Path, digest: str) -> Path | None:
    for candidate in sorted(folder.glob("*.json")):
        try:
            if json.loads(candidate.read_text(encoding="utf-8")).get("digest") == digest:
                return candidate
        except (OSError, json.JSONDecodeError, AttributeError):
            continue
    return None


def share_lines(path: Path) -> list[str]:
    """What another Nyr needs: where the record is, its digest, what it is about."""
    record = json.loads(path.read_text(encoding="utf-8"))
    resource = record.get("resource") or {}
    server = record.get("server") or {}
    staged = (f"staged sha256:{resource['staged_digest']}" if resource.get("staged_digest")
              else "not staged by the rig (a watch on a running server)")
    lines = [
        f"{path.as_posix()} @ sha256:{record.get('digest')}",
        f"resource {resource.get('commit') or 'no commit'} {staged}"
        + (" (dirty: " + ", ".join(resource.get("dirty") or []) + ")" if resource.get("dirty") else ""),
        f"server {server.get('flavour') or 'of unknown flavour'} on 127.0.0.1:{server.get('port')}"
        f", client {'connected' if (record.get('client') or {}).get('connected') else 'none'}",
        f"verdict {record.get('verdict')}: {len(record.get('findings') or [])} finding(s), "
        f"{len(record.get('log') or [])} log line(s), {record.get('requests')} request(s)",
        f"check it with: python docs/rig/rig.py check {path.as_posix()}",
    ]
    return lines


# -------------------------------------------------------------- the findings

#: What in a server line is trouble, and what kind. Matched against the line
#: the resource printed, without its `[nyr] ` prefix.
TROUBLE = (
    ("save_failed", re.compile(r"^(save|shutdown save): ")),
    ("load_failed", re.compile(r"^load: |the city remains closed")),
    ("did_not_start", re.compile(r"did not start")),
    ("tick_failed", re.compile(r"^(tick|health watch|damage): ")),
    ("world_error", re.compile(r"^error \(")),
    ("bridge_threw", re.compile(r"^dev bridge: .* threw: ")),
    ("bridge_broke", re.compile(r"broke the bridge")),
    ("handler_failed", re.compile(r" failed for .*: ")),
    ("no_address", re.compile(r" has no address: ")),
)


def trouble_in(line: str) -> str | None:
    for kind, pattern in TROUBLE:
        if pattern.search(line):
            return kind
    return None


SEVERITY = {
    "server_died": "critical", "bridge_silent": "critical", "did_not_open": "critical",
    "save_failed": "high", "load_failed": "high", "did_not_start": "high", "tick_failed": "high",
    "world_error": "high", "bridge_threw": "high", "bridge_broke": "high", "handler_failed": "high",
    "bridge_failed": "high", "books_off": "high", "restart_lost": "high", "no_address": "medium",
    "scenario_failed": "high", "journey_failed": "high", "client_error": "medium",
    "accepted_negative": "medium", "accepted_huge": "low", "unmade": "info", "log_dropped": "low",
}


class Hunt:
    """A session's findings, gathered as they happen and written down at the end."""

    def __init__(self, bridge: Bridge) -> None:
        self.bridge = bridge
        self.findings: list[dict[str, Any]] = []
        self.phases: list[dict[str, Any]] = []
        self.phase = "start"
        self.seen_client_errors: set[str] = set()
        self.last_verify: dict[str, Any] | None = None
        self.books_reported: set[str] = set()

    def find(self, kind: str, detail: str, **evidence: Any) -> dict[str, Any]:
        finding = {"n": len(self.findings) + 1, "kind": kind, "severity": SEVERITY.get(kind, "medium"),
                   "phase": self.phase, "at": now_iso(), "detail": detail}
        if evidence:
            finding["evidence"] = evidence
        self.findings.append(finding)
        say(f"  ! {finding['severity']} {kind}: {detail[:160]}")
        return finding

    def drain(self) -> None:
        try:
            fresh = self.bridge.drain()
        except BridgeSilent as error:
            self.find("bridge_silent", str(error))
            return
        for line in fresh:
            said = str(line.get("said") or "")
            kind = trouble_in(said)
            if kind == "bridge_threw" and any(
                    f["kind"] == "bridge_failed" and f.get("evidence", {}).get("why")
                    and str(f["evidence"]["why"]) in said for f in self.findings):
                # The route that threw already answered 500 with the same
                # words, and that answer is already a finding. Once is enough.
                continue
            if kind:
                self.find(kind, said[:300], log_line=line.get("n"))
        if self.bridge.dropped and "log_dropped" not in {f["kind"] for f in self.findings}:
            self.find("log_dropped", f"{self.bridge.dropped} log line(s) scrolled out before they were read")

    def verify(self, after: str = "") -> dict[str, Any] | None:
        try:
            verdict = self.bridge.verify()
        except BridgeSilent as error:
            self.find("bridge_silent", str(error))
            return None
        self.last_verify = verdict
        if verdict.get("code") == "not_open":
            # The city was shut when asked -- mid-restart, mostly. Not clean:
            # nothing was checked.
            self.find("unmade", f"the books could not be checked after {after or 'that'}: the city was not open")
            return verdict
        if verdict.get("ok") is not True:
            if not (verdict.get("problems") or verdict.get("missing")):
                key = "verify said no without a problem list"
                if key not in self.books_reported:
                    self.books_reported.add(key)
                    self.find("books_off", key, answer={k: verdict.get(k) for k in ("ok", "code", "why")})
            for problem in verdict.get("problems") or []:
                key = f"{problem.get('where')}: {problem.get('problem')}"
                if key not in self.books_reported:
                    self.books_reported.add(key)
                    self.find("books_off", key + (f" (after {after})" if after else ""),
                              after=after or None)
        if verdict.get("missing"):
            key = "missing: " + ",".join(verdict["missing"])
            if key not in self.books_reported:
                self.books_reported.add(key)
                self.find("books_off", f"the city has no verifier for {', '.join(verdict['missing'])}")
        return verdict

    def read_client(self) -> None:
        for who in self.bridge.state().get("players") or []:
            for line in (who.get("errors") or []) if isinstance(who, dict) else []:
                if line not in self.seen_client_errors:
                    self.seen_client_errors.add(line)
                    self.find("client_error", str(line)[:300], player=who.get("id"))

    def begin(self, name: str) -> dict[str, Any]:
        self.phase = name
        entry = {"phase": name, "began": now_iso(), "_t": time.monotonic()}
        self.phases.append(entry)
        say(f"-- {name}")
        return entry

    def end(self, verdict: str, **detail: Any) -> None:
        entry = self.phases[-1]
        entry["seconds"] = round(time.monotonic() - entry.pop("_t"), 1)
        entry["verdict"] = verdict
        entry.update(detail)
        say(f"   {entry['phase']}: {verdict} in {entry['seconds']}s")


# ---------------------------------------------------------------- the storm

#: Junk by declared type. Each is a thing a client, a save file or a native
#: has actually handed a FiveM resource; none is a request.
JUNK: dict[str, list[Any]] = {
    "integer": ["12", 1.5, -1, 0, 2 ** 53, 2 ** 63, 1e308, True, None, [], {}, ""],
    "number": ["12", -1e308, True, None, [], {}, ""],
    # Two long strings: cfx-server closes the connection on a request line of a
    # few kilobytes, so the longer one tests the HTTP layer and the shorter one
    # reaches the schema.
    "string": [5, True, "", "x" * 1500, "x" * 4096, "\u0000", "\u202e", "🐍", "'; DROP TABLE nyr_store; --", "{{",
               None, [], {}],
    "id": ["abc", "", "_", 5, {}, [], None, "x" * 300],
    "boolean": ["true", 1, 0, "yes", None, [], {}],
    "money": [-1, 1e308, "10", {}, None, True],
    "table": ["x", 5, True, None, {"a": {"b": {"c": {"d": {"e": 1}}}}}],
}


def plausible(arg: dict[str, Any]) -> Any:
    """A value that looks like what the argument declares, so the junk beside it is what is tested."""
    kind = arg.get("type")
    if arg.get("enum"):
        return arg["enum"][0]
    if kind == "integer":
        return 1
    if kind == "number" or kind == "money":
        return 1
    if kind == "string":
        return "Jane"
    if kind == "boolean":
        return True
    if kind == "id":
        return f"{arg.get('kind') or 'chr'}_0000000000"
    if kind == "table":
        return {}
    return None


def storm_requests(commands: dict[str, Any], player: int = 1) -> list[dict[str, Any]]:
    """Every junk request the storm sends, as {label, path} or {label, command, args}.

    `player` is the id the well-formed half of a request names; the requests
    whose whole point is a junk id keep their own.
    """
    p = str(int(player))
    out: list[dict[str, Any]] = []
    for command in commands.get("commands") or []:
        name = command.get("name")
        args = [a for a in (command.get("args") or []) if isinstance(a, dict)]
        base = {a["name"]: plausible(a) for a in args}
        out.append({"label": f"{name} with nothing", "command": name, "args": {}})
        out.append({"label": f"{name} with an undeclared key", "command": name,
                    "args": dict(base, not_a_field=1)})
        for arg in args:
            field = arg["name"]
            if arg.get("required"):
                missing = dict(base)
                missing.pop(field, None)
                out.append({"label": f"{name} without {field}", "command": name, "args": missing})
            for junk in JUNK.get(arg.get("type") or "", []):
                out.append({"label": f"{name} with {field}={json.dumps(junk)[:40]}", "command": name,
                            "args": dict(base, **{field: junk}), "field": field, "junk": junk})
            if arg.get("type") == "id" and arg.get("kind"):
                other = "zzz" if arg["kind"] != "zzz" else "chr"
                out.append({"label": f"{name} with {field} of the wrong kind", "command": name,
                            "args": dict(base, **{field: f"{other}_0000000000"}), "field": field})
            if arg.get("enum"):
                out.append({"label": f"{name} with {field} outside its enum", "command": name,
                            "args": dict(base, **{field: "not_one_of_them"}), "field": field})
    # What a URL can carry that no client should.
    out += [
        {"label": "unknown command", "command": "no.such", "args": {}},
        {"label": "a command name of 5000 characters", "command": "x" * 5000, "args": {}},
        {"label": "a command name that is a path", "command": "../../etc", "args": {}},
        {"label": "a command name in another script", "command": "мe.status", "args": {}},
        {"label": "p=abc", "path": "/do?p=abc&c=me.status&a=%7B%7D"},
        {"label": "p=-1", "path": "/do?p=-1&c=me.status&a=%7B%7D"},
        {"label": "p=0", "path": "/do?p=0&c=me.status&a=%7B%7D"},
        {"label": "p=99999", "path": "/do?p=99999&c=me.status&a=%7B%7D"},
        {"label": "no command", "path": f"/do?p={p}"},
        {"label": "a= that is not JSON", "path": f"/do?p={p}&c=me.status&a=%7B%7B%7B"},
        {"label": "a= that is a number", "path": f"/do?p={p}&c=me.status&a=5"},
        {"label": "a= with an infinity", "path": f"/do?p={p}&c=bank.deposit&a=" + urllib.parse.quote('{"amount":1e999,"branch":"prp_0"}')},
        {"label": "a= nested 200 deep", "path": f"/do?p={p}&c=me.status&a=" + urllib.parse.quote("[" * 200 + "]" * 200)},
        {"label": "a= of 64 KB", "path": f"/do?p={p}&c=me.status&a=" + urllib.parse.quote(json.dumps({"x": "y" * 65536}))},
        {"label": "a broken percent escape", "path": f"/do?p={p}&c=me.status&a=%zz"},
        {"label": "a route nobody has", "path": "/nonsense"},
        {"label": "log since junk", "path": "/log?since=abc"},
        {"label": "log since negative", "path": "/log?since=-5"},
        {"label": "errors with a junk limit", "path": "/errors?limit=abc"},
        {"label": "errors with a huge limit", "path": "/errors?limit=99999999999999999999"},
        {"label": "act with a screen nobody has", "path": f"/act?p={p}&show=nope"},
        {"label": "act with an infinite coordinate", "path": f"/act?p={p}&x=1e999&y=1&z=1"},
        {"label": "act with p=-1", "path": "/act?p=-1&show=pockets"},
        {"label": "act with a query of 16 KB", "path": f"/act?p={p}&show=pockets&pad=" + "a" * 16384},
        {"label": "act with nothing", "path": "/act"},
    ]
    return out


def brief(said: dict[str, Any]) -> dict[str, Any]:
    """What rcon said, short enough for a phase line."""
    return {k: (v[:80] if isinstance(v, str) else v) for k, v in said.items()}


def people_of(bridge: Bridge, seconds: float = 75.0) -> list[str]:
    """The names on the account being driven, waited for past a rate limit.

    Read straight after the storm, which had just asked `character.list`
    forty times, the answer was `too_fast`, the names were nobody, and the
    restart was blamed for the three people who were there all along.
    """
    deadline = time.monotonic() + seconds
    while True:
        answer = bridge.do("character.list", {})
        if answer.get("ok") or answer.get("code") != "too_fast" or time.monotonic() >= deadline:
            return sorted(str(r.get("name")) for r in ((answer.get("value") or {}).get("characters") or [])
                          if isinstance(r, dict))
        time.sleep(2)


def absent_player(bridge: Bridge) -> int:
    """A player id nobody connected holds, so the storm acts as nobody's account.

    Sent as player 1 with a client connected as 1, a command with no arguments
    -- character.release, work.abandon, gang.leave, police.duty -- is not junk
    at all, and would have run as that player. The bridge answers an id nobody
    holds as the account nobody is connected as.
    """
    try:
        ids = [p.get("id") for p in (bridge.state().get("players") or []) if isinstance(p, dict)]
    except BridgeSilent:
        ids = []
    return max([i for i in ids if isinstance(i, int) and not isinstance(i, bool)], default=0) + 1000


def storm(hunt: Hunt, bridge: Bridge, alive: Callable[[], bool]) -> dict[str, Any]:
    """Send every junk request, and write down every answer that is not a refusal.

    A refusal is the right answer: a 400 from the bridge or `ok: false` with a
    code from the city. A 500, a `failed`, silence, or a server that is no
    longer running is a finding. So is a mutating command that said `ok` to a
    negative amount or a four-thousand-character name, because the storm cannot
    know that was wrong, and a person should look.

    Everything is sent as a player id nobody holds, so nothing here runs as a
    connected player, and only what the bridge refuses goes near a client.
    """
    try:
        listed = bridge.commands()
    except BridgeSilent as error:
        hunt.find("bridge_silent", str(error))
        return {"sent": 0}
    nobody = absent_player(bridge)
    requests = storm_requests(listed, player=nobody)
    sent = refused = accepted = closed = 0
    for request in requests:
        if not alive():
            hunt.find("server_died", f"the server stopped during the storm, after: {request['label']}")
            break
        try:
            if "path" in request:
                answer = bridge.raw(request["path"])
            else:
                answer = bridge.do(request["command"], request["args"], player=nobody)
        except BridgeSilent as error:
            # cfx-server closes the connection on a request line it will not
            # read, a few kilobytes long, and says nothing. If the bridge is
            # still there to answer the next request, that was the HTTP layer
            # refusing, not the bridge going silent -- and the difference is
            # the difference between a note and a critical finding.
            bridge.close()
            try:
                bridge.state()
            except BridgeSilent:
                hunt.find("bridge_silent", f"{request['label']}: {error}", request=request["label"])
                break
            closed += 1
            sent += 1
            continue
        sent += 1
        status = bridge.last_status or 0
        if status >= 500 or (isinstance(answer, dict) and answer.get("code") == "bridge_failed"):
            why = (answer.get("why") or answer.get("text")) if isinstance(answer, dict) else str(answer)
            hunt.find("bridge_failed", f"{request['label']}: {status} {why}",
                      request=request["label"], status=status, why=why)
        elif isinstance(answer, dict) and answer.get("code") == "failed":
            hunt.find("handler_failed", f"{request['label']}: {answer.get('message')}",
                      request=request["label"], command=request.get("command"))
        elif isinstance(answer, dict) and answer.get("ok") is True and "junk" in request:
            accepted += 1
            junk, field = request["junk"], request["field"]
            if isinstance(junk, (int, float)) and not isinstance(junk, bool) and junk < 0:
                hunt.find("accepted_negative", f"{request['label']} was accepted", request=request["label"])
            elif isinstance(junk, str) and len(junk) >= 1024:
                hunt.find("accepted_huge", f"{request['label']} was accepted", request=request["label"])
        else:
            refused += 1
    # The same command, fast, forty times: the rate limit is what should answer.
    fast = 0
    for _ in range(40):
        try:
            answer = bridge.do("character.list", {}, player=nobody)
        except BridgeSilent as error:
            hunt.find("bridge_silent", f"forty character.list in a row: {error}")
            break
        sent += 1
        if answer.get("code") == "failed":
            hunt.find("handler_failed", f"character.list under repetition: {answer.get('message')}")
        if answer.get("code") == "too_fast":
            fast += 1
    return {"sent": sent, "refused": refused, "accepted": accepted, "closed": closed,
            "declared": len(requests), "rate_limited": fast, "as_player": nobody}


# ------------------------------------------------------------------ toolkit


def toolkit():
    """The journey and scenario oracles, when the lane is there; nothing invented when it is not."""
    if str(TOOLKIT) not in sys.path:
        sys.path.insert(0, str(TOOLKIT))
    try:
        from nyrbb import fivem_journey as fj  # type: ignore
        from nyrbb import fivem_play as fp  # type: ignore
    except Exception as error:  # noqa: BLE001 -- any import trouble means no oracle
        return None, f"the toolkit's oracles are not importable from {TOOLKIT}: {error!r}"
    return (fp, fj), None


# ---------------------------------------------------------------------- hunt


def hunt(args: argparse.Namespace) -> int:
    source = Path(args.source).resolve()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    root = Path(args.out).resolve() / f"hunt-{stamp}-{args.server}"
    root.mkdir(parents=True, exist_ok=False)
    port = free_port(args.port)
    identity = git_identity(source)
    if not identity.get("commit") and args.commit:
        # An export has no repository. The caller says which commit it is
        # from, and the record says that it was the caller who said so.
        identity = {"commit": args.commit, "branch": None, "dirty": [], "commit_said_by": "the caller"}
    say(f"hunt on {source.name} at {(identity.get('commit') or 'no commit')[:9]}; "
        f"{args.server} server on 127.0.0.1:{port}; everything under {root}")

    resource_dir = root / "resources" / NAME
    hashes = stage(source, resource_dir)
    say(f"staged {len(hashes)} file(s) as {NAME}")

    session = Session(root, port, args.server)
    bridge = Bridge(port)
    hunt = Hunt(bridge)
    record: dict[str, Any] = {
        "schema": SCHEMA, "made_at": now_iso(), "rig": {"version": RIG_VERSION, "sha256": sha256_of(Path(__file__))},
        "by": os.environ.get("NYR_CLIENT") or "unlabelled",
        "resource": {"name": NAME, "source": str(source), **identity,
                     "staged_files": hashes, "staged_digest": staged_digest(hashes)},
        "server": {"flavour": args.server, "port": port, "exe": str(session.exe)},
        "client": {"connected": False, "id": None, "waited_s": None},
        "session": str(root),
    }
    # Where the server is, for a take run against a lingering hunt: under the
    # hunt's own folder, and where `default_port` looks. Taken away at the end.
    session_line = json.dumps({"port": port, "root": str(root), "server": args.server}, indent=2)
    (root / "session.json").write_text(session_line, encoding="utf-8")
    RUN.mkdir(parents=True, exist_ok=True)
    (RUN / "session.json").write_text(session_line, encoding="utf-8")
    previous = latest_record(Path(args.out).resolve())

    def verify_after(command: str, given: dict[str, Any], answer: dict[str, Any]) -> None:
        if answer.get("ok") is True:
            hunt.verify(after=command)

    try:
        hunt.begin("boot")
        session.launch()
        if not bridge.ready(args.seconds, session.alive):
            hunt.find("did_not_open", f"the city did not open within {args.seconds}s"
                      + ("" if session.alive() else "; the server exited"))
            try:
                record["errors_at_end"] = bridge.errors()
            except BridgeSilent:
                pass
            hunt.end("failed")
            return finish(record, hunt, session, bridge, root, previous, args)
        hunt.drain()
        hunt.end("open", build=session.build, connections=bridge.connections)

        if args.wait_client > 0:
            hunt.begin("client")
            say(f"waiting up to {args.wait_client:.0f}s for a client: FiveM > Settings > Interface > "
                f"Localhost Port {port}, then connect to localhost; hands off from spawn")
            began = time.monotonic()
            if bridge.await_body(args.wait_client):
                waited = round(time.monotonic() - began, 1)
                bridge.adopt()
                record["client"] = {"connected": True, "id": bridge.target, "waited_s": waited}
                time.sleep(5)
                hunt.end("connected", id=bridge.target, waited_s=waited)
            else:
                hunt.end("nobody came")
        hunt.read_client()

        oracles, why = toolkit()
        bridge.after_do.append(verify_after)
        hunt.begin("scenarios")
        if oracles is None:
            hunt.find("unmade", f"scenarios not walked: {why}")
            hunt.end("unmade", why=why)
        else:
            fp, fj = oracles
            walked = []
            for scenario in fp.scenarios(source):
                outcome = fp.run_scenario(bridge, scenario)
                walked.append(outcome)
                if not outcome.get("passed"):
                    hunt.find("scenario_failed", f"{outcome.get('scenario')} stopped at step {outcome.get('stopped_at')}",
                              scenario=outcome.get("scenario"), step=outcome.get("stopped_at"))
                hunt.drain()
                hunt.read_client()
            record["scenarios"] = walked
            hunt.end("walked", passed=sum(1 for w in walked if w.get("passed")), of=len(walked))

            # The journeys assume a city nobody has played, as the scenarios
            # did, and both make people on the same account: run second on the
            # same city, every journey hit "you already have 3 people" at its
            # second step. So the city is cleared between them.
            hunt.begin("fresh city")
            said = session.restart_resource(bridge, fresh=resource_dir)
            if not said["stopped"]:
                hunt.find("unmade", f"the resource could not be restarted for a fresh city: {said['stop'][:120]}",
                          rcon=said)
                hunt.end("unmade", rcon=said)
                return finish(record, hunt, session, bridge, root, previous, args)
            if not bridge.ready(args.seconds, session.alive):
                hunt.find("did_not_open", "the city did not open on a fresh save after the scenarios", rcon=said)
                hunt.end("failed", rcon=said)
                return finish(record, hunt, session, bridge, root, previous, args)
            if record["client"]["connected"]:
                bridge.await_body(120)
                bridge.adopt()
                time.sleep(5)
            hunt.drain()
            hunt.end("open", rcon=brief(said))

            hunt.begin("journeys")
            journeys = []
            for plan in fj.journeys(source):
                outcome = fj.run_journey(bridge, plan)
                journeys.append(outcome)
                if not outcome.get("passed"):
                    hunt.find("journey_failed", f"{outcome.get('journey')} hit a wall at step {outcome.get('failed_at')}",
                              journey=outcome.get("journey"), step=outcome.get("failed_at"))
                if outcome.get("unmade"):
                    hunt.find("unmade", f"{outcome.get('journey')}: {outcome['unmade']} check(s) need a client",
                              journey=outcome.get("journey"))
                hunt.drain()
                hunt.read_client()
            record["journeys"] = journeys
            hunt.end("walked", complete=sum(1 for j in journeys if j.get("passed") and not j.get("unmade")),
                     of=len(journeys), unmade=sum(j.get("unmade", 0) for j in journeys))
        bridge.after_do.remove(verify_after)

        if not args.no_storm:
            hunt.begin("storm")
            before = (bridge.state().get("summary") or {}).get("errors")
            stormed = storm(hunt, bridge, session.alive)
            after = (bridge.state().get("summary") or {}).get("errors")
            hunt.drain()
            hunt.verify(after="the storm")
            hunt.read_client()
            record["storm"] = dict(stormed, errors_before=before, errors_after=after)
            if isinstance(before, int) and isinstance(after, int) and after > before:
                hunt.find("world_error", f"the city recorded {after - before} error(s) during the storm; /errors has them",
                          errors=bridge.errors(after - before).get("errors"))
            hunt.end("weathered" if session.alive() else "killed", **stormed)

        if not args.no_restart:
            hunt.begin("restart")
            summary_before = bridge.state().get("summary") or {}
            people_before = people_of(bridge)
            said = session.restart_resource(bridge)
            if not said["stopped"]:
                hunt.find("unmade", f"the resource could not be restarted: {said['stop'][:120]}", rcon=said)
                hunt.end("unmade", rcon=said)
            elif not bridge.ready(args.seconds, session.alive):
                hunt.find("did_not_open", "the city did not open again after the restart", rcon=said)
                hunt.end("failed", rcon=said)
            else:
                if record["client"]["connected"]:
                    bridge.await_body(120)
                    bridge.adopt()
                summary_after = bridge.state().get("summary") or {}
                people_after = people_of(bridge)
                for key in ("entities", "accounts", "owned"):
                    if summary_before.get(key) != summary_after.get(key):
                        hunt.find("restart_lost", f"{key} changed across the restart: {summary_before.get(key)} -> {summary_after.get(key)}",
                                  before=summary_before.get(key), after=summary_after.get(key))
                if people_before != people_after:
                    hunt.find("restart_lost", f"the account's people changed across the restart: {people_before} -> {people_after}")
                hunt.drain()
                hunt.verify(after="the restart")
                record["restart"] = {"rcon": said, "summary_before": summary_before, "summary_after": summary_after}
                hunt.end("survived", rcon=brief(said))

        if args.linger > 0:
            hunt.begin("linger")
            say(f"the server stays up for up to {args.linger:.0f}s (create {root / 'stop'} to end it sooner)")
            end = time.monotonic() + args.linger
            # Two seconds, inside the keep-alive idle: at three the connection
            # was replaced on every lap, twenty new ones a minute for the whole
            # linger, on a server measured to lock an address out for less.
            while time.monotonic() < end and not (root / "stop").exists() and session.alive():
                time.sleep(2)
                hunt.drain()
                hunt.read_client()
            hunt.verify(after="lingering")
            hunt.end("done")
        return finish(record, hunt, session, bridge, root, previous, args)
    except KeyboardInterrupt:
        hunt.find("unmade", "the hunt was interrupted from the keyboard")
        return finish(record, hunt, session, bridge, root, previous, args)


def finish(record: dict[str, Any], hunt: Hunt, session: Session | None, bridge: Bridge, root: Path,
           previous: Path | None, args: argparse.Namespace) -> int:
    hunt.phase = "settle"
    try:
        hunt.drain()
        record["errors_at_end"] = bridge.errors(64)
        hunt.read_client()
        record["verify_at_end"] = hunt.verify(after="everything")
        record["state_at_end"] = bridge.state()
    except BridgeSilent as error:
        if session is not None and not session.alive():
            hunt.find("server_died", "the server was not running at the end")
        else:
            hunt.find("bridge_silent", str(error))
    bridge.close()
    console_path = session.stop() if session is not None else None
    if session is not None and session.build:
        record["server"]["build"] = session.build
    try:
        pointer = RUN / "session.json"
        if pointer.is_file() and json.loads(pointer.read_text(encoding="utf-8")).get("root") == str(root):
            pointer.unlink()
    except (OSError, ValueError):
        pass
    record["log"] = bridge.lines
    record["log_dropped"] = bridge.dropped
    record["requests"] = bridge.requests
    record["bridge_connections"] = bridge.connections
    record["phases"] = [{k: v for k, v in p.items() if not k.startswith("_")} for p in hunt.phases]
    record["findings"] = hunt.findings
    if console_path is not None:
        record["console"] = {"file": console_path.name, "sha256": sha256_of(console_path),
                             "lines": len(session.lines)}
    severities = {f["severity"] for f in hunt.findings}
    if "critical" in severities:
        record["verdict"] = "broken"
    elif severities & {"high", "medium", "low"}:
        record["verdict"] = "findings"
    elif "info" in severities:
        record["verdict"] = "unmade"
    else:
        record["verdict"] = "clean"
    record["previous"] = None
    if previous is not None:
        try:
            record["previous"] = json.loads(previous.read_text(encoding="utf-8")).get("digest")
        except (OSError, json.JSONDecodeError, AttributeError):
            record["previous"] = None
    record["finished_at"] = now_iso()
    for key, value in redacted(record).items():
        record[key] = value
    seal(record)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{root.name}.json"
    path.write_text(json.dumps(record, indent=1, ensure_ascii=False), encoding="utf-8")
    if console_path is not None:
        shutil.copy2(console_path, out / f"{root.name}.console.log")
        record["console"]["file"] = f"{root.name}.console.log"
        seal(record)
        path.write_text(json.dumps(record, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"verdict {record['verdict']}: {len(hunt.findings)} finding(s); record {path}")
    for finding in hunt.findings:
        say(f"  {finding['n']:>3} {finding['severity']:<8} {finding['kind']:<16} {finding['detail'][:120]}")
    tell()
    for line in share_lines(path):
        tell("  " + line)
    return 0 if record["verdict"] in ("clean", "unmade") else 1


# --------------------------------------------------------------------- watch


def watch(args: argparse.Namespace) -> int:
    """Sit on a server somebody else started and write down what goes wrong."""
    bridge = Bridge(args.port)
    hunt = Hunt(bridge)
    source = Path(args.source).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    record: dict[str, Any] = {
        "schema": SCHEMA, "made_at": now_iso(), "rig": {"version": RIG_VERSION, "sha256": sha256_of(Path(__file__))},
        "by": os.environ.get("NYR_CLIENT") or "unlabelled",
        "resource": {"name": NAME, "source": str(source), **git_identity(source),
                     "staged_files": {}, "staged_digest": None,
                     "note": "watched on a server the rig did not stage; the tree hash is not known"},
        "server": {"flavour": None, "port": args.port}, "client": {"connected": False, "id": None},
        "session": f"watch-{stamp}",
    }
    hunt.begin("watch")
    if not bridge.ready(30):
        say(f"no open city answers on 127.0.0.1:{args.port}")
        return 2
    say(f"watching 127.0.0.1:{args.port}; every server line, every client error, the books every "
        f"{args.every:.0f}s; Ctrl-C to write the record")
    end = time.monotonic() + args.seconds if args.seconds > 0 else float("inf")
    last_verify = 0.0
    try:
        while time.monotonic() < end:
            hunt.drain()
            hunt.read_client()
            if bridge.has_client():
                record["client"] = {"connected": True, "id": bridge.adopt()}
            if time.monotonic() - last_verify >= args.every:
                hunt.verify(after="play")
                last_verify = time.monotonic()
            time.sleep(2)
    except KeyboardInterrupt:
        pass
    except BridgeSilent as error:
        hunt.find("bridge_silent", str(error))
    hunt.end("done")
    root = out / f"watch-{stamp}"
    root.mkdir(exist_ok=True)
    return finish(record, hunt, None, bridge, root, latest_record(out), args)


# ------------------------------------------------------------------- compare


def compare(args: argparse.Namespace) -> int:
    """One connection, two walks: the city as committed, then with the fix."""
    oracles, why = toolkit()
    if oracles is None:
        say(why)
        return 2
    fp, fj = oracles
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=False)
    (root / "resources").mkdir()
    before, after = Path(args.before).resolve(), Path(args.after).resolve()
    resource_dir = root / "resources" / NAME
    port = free_port(args.port)
    stage(before, resource_dir)
    session = Session(root, port, args.server)
    session.launch()
    bridge = Bridge(port)
    evidence: dict[str, Any] = {"rehearsal": args.rehearse, "port": port}

    def walk_all(source: Path, label: str, waited) -> dict[str, Any]:
        walked = [fj.run_journey(bridge, plan) for plan in fj.journeys(source)]
        out = {"schema": fj.JOURNEY_SCHEMA, "resource": NAME, "session": f"{root.name}/{label}",
               "root": str(root), "port": port, "server": args.server,
               "client_connected": bridge.has_client(), "client_id": bridge.target if bridge.has_client() else None,
               "waited_for_client_s": waited, "bridge_connections": bridge.connections, "unreachable": None,
               "journeys": walked, "walked": len(walked),
               "journeys_passed": sum(1 for j in walked if j["passed"]),
               "checks_unmade": sum(j["unmade"] for j in walked),
               "complete": bool(walked) and all(j["passed"] and j["unmade"] == 0 for j in walked),
               "seconds": 0.0, "source": str(source),
               "note": "Walked by docs/rig/rig.py compare with fivem_journey.run_journey."}
        (root / f"walk-{label}.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
        (root / f"walk-{label}.txt").write_text(fj.render(out), encoding="utf-8")
        return out

    def map_as_nobody() -> dict[str, Any]:
        bridge.do("character.release", {})
        return bridge.do("me.map", {})

    try:
        if not bridge.ready(args.seconds, session.alive):
            say("the bridge never answered; stopping")
            return 1
        say(f"server up on 127.0.0.1:{port} with the build as committed")
        waited = None
        if not args.rehearse:
            say(f"waiting up to {args.wait:.0f}s for a client: Localhost Port {port}, then connect to localhost")
            began = time.monotonic()
            if not bridge.await_body(args.wait):
                say("no client came; stopping")
                return 2
            waited = round(time.monotonic() - began, 1)
            bridge.adopt()
            say(f"client {bridge.target} has a body after {waited}s; walking the build as committed")
            time.sleep(5)
        evidence["before_map_as_nobody"] = {k: map_as_nobody().get(k) for k in ("ok", "code")}
        a = walk_all(before, "before", waited)
        say(fj.render(a).splitlines()[0])

        say("stopping the resource, clearing its city, putting the fix in, starting it again")
        evidence["rcon_stop"] = session.rcon(f"stop {NAME}")
        if session.rcon_refused(evidence["rcon_stop"]):
            say(f"rcon refused the stop, so the fix cannot be put in under this client: {evidence['rcon_stop'][:120]}")
            return 3
        time.sleep(4)
        stage(after, resource_dir)
        evidence["rcon_refresh"] = session.rcon("refresh")
        time.sleep(1)
        evidence["rcon_start"] = session.rcon(f"start {NAME}")
        time.sleep(3)
        if not bridge.ready(args.seconds, session.alive):
            say("the bridge did not come back after the restart; stopping")
            return 3
        if not args.rehearse:
            if not bridge.await_body(180):
                say("the client did not report a body after the restart; walking anyway")
            bridge.adopt()
            time.sleep(5)
        evidence["after_map_as_nobody"] = {k: map_as_nobody().get(k) for k in ("ok", "code")}
        b = walk_all(after, "after", waited)
        say(fj.render(b).splitlines()[0])
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        say("evidence: " + json.dumps(evidence))
        if not args.rehearse and args.linger > 0:
            say(f"walks done; the server stays up for up to {args.linger:.0f}s (create {root / 'stop'} to end it sooner)")
            end = time.monotonic() + args.linger
            while time.monotonic() < end and not (root / "stop").exists() and bridge.has_client():
                time.sleep(2)
        return 0
    finally:
        bridge.close()
        session.stop()
        say(f"server stopped; everything is under {root}")


# ----------------------------------------------------------------------- cli


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="what", required=True)

    h = sub.add_parser("hunt", help="stage, boot, walk, storm, restart, verify, and write the record")
    h.add_argument("--source", default=str(ROOT))
    h.add_argument("--commit", default=None, help="the commit an exported --source came from")
    h.add_argument("--server", choices=("enhanced", "legacy"), default="enhanced")
    h.add_argument("--port", type=int, default=30134)
    h.add_argument("--seconds", type=float, default=150.0, help="how long the city gets to open")
    h.add_argument("--wait-client", type=float, default=0.0, help="hold the server for a client this long")
    h.add_argument("--linger", type=float, default=0.0, help="stay up afterwards, watching")
    h.add_argument("--no-storm", action="store_true")
    h.add_argument("--no-restart", action="store_true")
    h.add_argument("--out", default=str(RUN))
    h.set_defaults(run=hunt)

    w = sub.add_parser("watch", help="sit on a running server and write down what goes wrong")
    w.add_argument("--port", type=int, required=True)
    w.add_argument("--seconds", type=float, default=0.0, help="0 is until Ctrl-C")
    w.add_argument("--every", type=float, default=10.0, help="seconds between checks of the books")
    w.add_argument("--source", default=str(ROOT))
    w.add_argument("--out", default=str(RUN))
    w.set_defaults(run=watch)

    c = sub.add_parser("compare", help="one connection, two walks, the fix put in between")
    c.add_argument("--root", required=True)
    c.add_argument("--before", required=True)
    c.add_argument("--after", required=True)
    c.add_argument("--server", choices=("enhanced", "legacy"), default="enhanced")
    c.add_argument("--port", type=int, default=30134)
    c.add_argument("--seconds", type=float, default=150.0)
    c.add_argument("--wait", type=float, default=600.0)
    c.add_argument("--linger", type=float, default=900.0)
    c.add_argument("--rehearse", action="store_true")
    c.set_defaults(run=compare)

    k = sub.add_parser("check", help="is this record intact, and about the tree in front of you")
    k.add_argument("record")
    k.add_argument("--source", default=str(ROOT))
    k.add_argument("--no-tree", action="store_true", help="do not compare against a source tree")

    def run_check(a: argparse.Namespace) -> int:
        result = check_record(Path(a.record), None if a.no_tree else Path(a.source))
        for key in ("record", "digest", "verdict", "findings", "intact", "console_intact", "previous_found",
                    "about_this_tree"):
            if result.get(key) is not None:
                print(f"  {key:<16} {result[key]}")
        for problem in result["problems"]:
            print(f"  ! {problem}")
        for note in result.get("notes") or []:
            print(f"  - {note}")
        for name in result.get("changed_files") or []:
            print(f"      differs: {name}")
        fine = result["intact"] and not result["problems"]
        print("  " + ("this record can be trusted as written" if fine else "do not act on this record as it stands"))
        return 0 if fine else 1
    k.set_defaults(run=run_check)

    s = sub.add_parser("share", help="the lines another Nyr needs to find and check a record")
    s.add_argument("record", nargs="?")
    s.add_argument("--out", default=str(RUN))

    def run_share(a: argparse.Namespace) -> int:
        path = Path(a.record) if a.record else latest_record(Path(a.out))
        if path is None:
            print("no record to share")
            return 1
        for line in share_lines(path):
            print(line)
        return 0
    s.set_defaults(run=run_share)

    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
