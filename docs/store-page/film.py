"""Film the loop a player lives, with nobody at the keyboard.

A person connects once -- FiveM > Settings > Interface > Localhost Port, set to
the port of the server that is up, then the localhost entry -- and leaves the
game in front on the main screen. Everything after that is this script: the
body walks by the game's own route finding, E is pressed through the function
the key calls, a button's command goes through the command bus, and the screen
it belongs to is redrawn from what the server now says. The screen is recorded
to run/video as it happens.

    python film.py                   the whole loop: arrive, bank, work, shop, pockets
    python film.py shop              the shop alone, from a floor point where the prompt is up
    python film.py walkin            walk into the shop on film, by a route walked once off camera
    python film.py <take> --port N   against a server on another port

It exists because on 2026-09-13 a person was asked to walk, press keys and type
amounts for a recording, twice, and asked why the rig could not do it. The
bridge, the walk, the camera and the waits are `docs/rig/rig.py`; this file
is only the order of the take.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rig"))
from rig import (Bridge, Recorder, become, default_port, position, prompt_says, say, showing,  # noqa: E402
                 stand_where_prompt, wait_for, walk)

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "run" / "video"

# From config.lua. The walk ends at the marker; E works within three metres.
BANK = (149.0, -1040.0, 29.0)
SHOP = (-47.0, -1757.0, 29.0)
# Where the cut to the shop lands, a street's width from its door; the game is
# asked for ground there rather than trusted with a height.
SHOP_APPROACH = (-58.0, -1750.0, 29.5)
SHOP_PROMPT = "Rob's Liquor"
# Floor points inside the shop, within the prompt's three metres of the counter.
# The counter's own point is not floor: a body put there stood on the counter,
# and the game's ground search chose the pavement twenty metres away.
SHOP_FLOOR = [(-46.0, -1754.5, 28.6), (-44.5, -1757.0, 28.6), (-48.5, -1754.0, 28.6),
              (-47.0, -1759.5, 28.6), (-49.5, -1757.5, 28.6), (-45.0, -1759.0, 28.6)]
SHOP_INSIDE = (-46.0, -1755.0, 29.0)
SHOP_OUTSIDE = (-54.0, -1737.0, 29.0)


def hold(seconds: float) -> None:
    time.sleep(seconds)


class Take:
    """A recording with named beats and a still for each."""

    def __init__(self, name: str) -> None:
        OUT.mkdir(parents=True, exist_ok=True)
        self.stamp = time.strftime("%Y%m%d-%H%M%S")
        self.name = name
        self.video = OUT / f"{name}-{self.stamp}.mp4"
        self.beats: list[dict] = []
        self.rec = Recorder(self.video)

    def beat(self, name: str, still: bool = True) -> None:
        self.beats.append({"beat": name, "at": self.rec.at()})
        say(f"-- {name} at {self.rec.at()}s")
        if still:
            self.rec.still(OUT / f"{self.name}-{self.stamp}-{name}.png")

    def stop(self, bridge: Bridge, **extra) -> None:
        self.rec.stop()
        (OUT / f"{self.name}-{self.stamp}.json").write_text(json.dumps(
            {"video": self.video.name, "beats": self.beats, "bridge_connections": bridge.connections, **extra},
            indent=2), encoding="utf-8")
        say(f"video {self.video} ({self.video.stat().st_size / 1e6:.1f} MB); beats written beside it; "
            f"{bridge.connections} bridge connection(s)")


def shop_and_pockets(bridge: Bridge, take: Take, shop: str | None, start: int) -> None:
    """The counter, a purchase, and the pockets after it; the beats every take ends on."""
    take.beat(f"{start:02d}-counter")
    if shop:
        bridge.do("shop.buy", shop=shop, item="water", count=1)
        bridge.act(press=1)
        hold(4.0)
        take.beat(f"{start + 1:02d}-bought")
    bridge.act(show="close")
    hold(2.0)
    bridge.act(show="pockets")
    wait_for(bridge, showing("pockets"), 10, every=1)
    hold(4.5)
    take.beat(f"{start + 2:02d}-pockets")
    bridge.act(show="close")
    hold(2.5)


def the_shop_id(bridge: Bridge) -> str | None:
    places = (bridge.do("me.map").get("value") or {}).get("places") or []
    return next((p.get("shop") for p in places if p.get("shop")), None)


def whole(bridge: Bridge) -> int:
    say("waiting for a player to spawn")
    if not wait_for(bridge, lambda who: who.get("spawned"), 1800, every=3):
        say("nobody spawned")
        return 1
    say("spawned; giving the ground and the picker time to arrive")
    hold(14)
    take = Take("underworld")
    try:
        hold(3.5)
        take.beat("01-picker")
        become(bridge, "Marcus", "Hale")
        bridge.act(show="picker")
        hold(3.5)
        take.beat("02-somebody")
        bridge.act(show="close")
        hold(4)
        take.beat("03-standing")

        places = (bridge.do("me.map").get("value") or {}).get("places") or []
        branch = next((p["place"] for p in places if p.get("kind") == "bank"
                       and p.get("name") == "Pillbox Hill Branch"), None)
        shop = next((p.get("shop") for p in places if p.get("shop")), None)

        take.beat("04-walk-to-bank", still=False)
        if not walk(bridge, BANK, 150, pace="run", until_prompt="Pillbox Hill Branch"):
            say("  did not reach the bank; standing the body at it")
            bridge.act(x=BANK[0], y=BANK[1], z=BANK[2], safe=1)
            wait_for(bridge, prompt_says("Pillbox Hill Branch"), 20)
        hold(2.5)
        take.beat("05-bank-prompt")
        bridge.act(press=1)
        wait_for(bridge, showing("bank"), 10, every=1)
        hold(3.5)
        take.beat("06-bank-no-account")
        if branch:
            bridge.do("bank.open", branch=branch)
            bridge.act(press=1)
            hold(3)
            take.beat("07-bank-open")
            bridge.do("bank.deposit", branch=branch, amount=20000)
            bridge.act(press=1)
            hold(4.5)
            take.beat("08-bank-paid-in")
        bridge.act(show="close")
        hold(2)

        bridge.act(show="jobs")
        wait_for(bridge, showing("jobs"), 10, every=1)
        hold(3.5)
        take.beat("09-job-board")
        for employer in (bridge.do("work.list").get("value") or {}).get("employers") or []:
            ready = [job for job in employer.get("jobs", []) if job.get("ready_in", 0) == 0]
            if employer.get("hiring") and ready:
                bridge.do("work.start", employer=employer["employer"], job=ready[0]["job"])
                break
        bridge.act(show="jobs")
        hold(4)
        take.beat("10-on-a-shift")
        bridge.act(show="close")
        hold(2)
        take.beat("11-cut", still=False)

        # The shop, a cut away: across the city is not worth three minutes of film.
        bridge.act(x=SHOP_APPROACH[0], y=SHOP_APPROACH[1], z=SHOP_APPROACH[2], safe=1)
        hold(4)
        take.beat("12-at-the-shop", still=False)
        if not walk(bridge, SHOP, 60, until_prompt=SHOP_PROMPT):
            say("  did not reach the counter; standing the body at it")
            bridge.act(x=SHOP[0], y=SHOP[1], z=SHOP[2], safe=1)
            wait_for(bridge, prompt_says(SHOP_PROMPT), 20)
        hold(2.5)
        take.beat("13-shop-prompt")
        bridge.act(press=1)
        wait_for(bridge, showing("shop"), 10, every=1)
        hold(3.5)
        shop_and_pockets(bridge, take, shop, 14)
        take.beat("17-end", still=False)
    finally:
        take.stop(bridge)
    return 0


def shop_only(bridge: Bridge) -> int:
    bridge.act(show="close")
    stood = stand_where_prompt(bridge, SHOP_FLOOR, SHOP_PROMPT)
    if not stood:
        say("no place on the floor had the prompt up")
        return 1
    say(f"standing at {stood}")
    hold(2.0)
    shop = the_shop_id(bridge)
    take = Take("shop")
    try:
        hold(3.0)
        take.beat("01-prompt")
        bridge.act(press=1)
        wait_for(bridge, showing("shop"), 10, every=1)
        hold(3.5)
        shop_and_pockets(bridge, take, shop, 2)
    finally:
        take.stop(bridge, stood=stood)
    return 0


def walk_in(bridge: Bridge) -> int:
    """Walk into the shop on film, by a route the game has already walked once."""
    bridge.act(show="close")
    here = position(bridge.watching())
    if not here or abs(here[0] - SHOP_INSIDE[0]) + abs(here[1] - SHOP_INSIDE[1]) > 3:
        bridge.act(x=SHOP_INSIDE[0], y=SHOP_INSIDE[1], z=SHOP_INSIDE[2])
        hold(3)
    say("walking out, off camera")
    if not walk(bridge, SHOP_OUTSIDE, 45, nudge_after=8):
        say(f"the walk out stopped at {bridge.watching().get('pos')}: no route to film")
        return 1
    say(f"out at {bridge.watching().get('pos')}; the route exists")
    hold(2)
    shop = the_shop_id(bridge)
    take = Take("walkin")
    try:
        hold(2.5)
        take.beat("01-outside")
        arrived = walk(bridge, SHOP_INSIDE, 45, arrive_m=1.5, nudge_after=8)
        take.beat("02-inside" if arrived else "02-stopped")
        if not wait_for(bridge, prompt_says(SHOP_PROMPT), 10, every=1):
            say("no prompt after the walk in")
            return 1
        hold(2.5)
        take.beat("03-prompt")
        bridge.act(press=1)
        wait_for(bridge, showing("shop"), 10, every=1)
        hold(3.5)
        shop_and_pockets(bridge, take, shop, 4)
    finally:
        take.stop(bridge)
    return 0


TAKES = {"whole": whole, "shop": shop_only, "walkin": walk_in}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("take", nargs="?", default="whole", choices=sorted(TAKES))
    parser.add_argument("--port", type=int, default=None)
    args = parser.parse_args()
    port = args.port or default_port()
    bridge = Bridge(port)
    if not bridge.ready(10):
        say(f"no open city answers on 127.0.0.1:{port}")
        return 2
    say(f"filming the {args.take} take against 127.0.0.1:{port}")
    try:
        return TAKES[args.take](bridge)
    finally:
        bridge.close()


if __name__ == "__main__":
    sys.exit(main())
