"""The loop the listing promises, driven and recorded as stills and a short loop.

Arrive, become somebody, earn, buy a place. Every step goes through the same
command bus a player's key press uses; the screens are opened by the same
functions the key bindings call. Nothing is staged -- the money that buys the
flat is earned a shift at a time through the ledger, because the alternative is
minting it, and a demo of a city where money appears is a demo of nothing.

    python beats.py            run the whole thing
    python beats.py --earn     earn the door's price first, with no camera
    python beats.py --check    just say whether a player is connected
    python beats.py --port N   against a server on another port

The camera takes whatever is in front on the main screen, so the game has to be
in front for every beat -- and on 2026-09-13 a take recorded the desktop of the
person who had tabbed out to read a message. The beats themselves take about a
minute; the shifts between them take six. So `--earn` first, while nobody needs
to look at anything, and then the whole thing: `earn_until` finds the money
already there and the camera is needed for one minute, not seven.

The bridge, the camera and the waits are `docs/rig/rig.py`; this file is the
order of the beats and where they stand.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rig"))
from rig import Bridge, Camera, become, default_port, earn_until, save_loop, say, wallet  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "run" / "footage"

# Where things are, taken from config.lua rather than typed again.
#
# `flat` is Alta Street and not Integrity Way, which is the only entry here
# that is not simply its config coordinates. Integrity Way, Apt 28 sits at
# z=89: that is the real GTA interior, and a player put there falls to the
# street. Measured -- asked for -47, -589, 89 and landed at -44, -589, 56,
# which is 33 metres below a door with a radius of four, so `me.nearby` was
# right to say nothing was in reach. Alta Street is at ground level and a
# player who is sent there is standing at the door.
PLACES = {
    "legion":   (241.0, 220.0, 106.0, 160.0),
    "liquor":   (-47.0, -1757.0, 29.0, 50.0),
    "flat":     (-269.0, -955.0, 31.0, 90.0),
    "integrity": (-47.0, -589.0, 89.0, 210.0),
    "scrapyard": (1180.0, -1250.0, 35.0, 100.0),
    "pillbox":  (149.0, -1040.0, 29.0, 330.0),
}


def at(bridge: Bridge, place: str, settle: float = 1.6) -> None:
    x, y, z, h = PLACES[place]
    bridge.act(x=x, y=y, z=z, h=h)
    time.sleep(settle)


def wait_for_player(bridge: Bridge, seconds: float = 420) -> dict:
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        who = bridge.watching()
        if who and who.get("spawned"):
            return who
        time.sleep(5)
    raise SystemExit("no player connected in time")


def the_door_with_a_price(bridge: Bridge):
    """The address and the price, read off the screen rather than typed here."""
    for row in ((bridge.do("me.nearby").get("value") or {}).get("places") or []):
        if row.get("for_sale"):
            say(f"    {row['address']} is for sale at {row['price']}")
            return row["place"], row["price"]
    return None, None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--earn", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--port", type=int, default=None)
    args = parser.parse_args()
    bridge = Bridge(args.port or default_port())

    if args.check:
        print(bridge.state())
        return 0

    if args.earn:
        wait_for_player(bridge)
        become(bridge, "Vic", "Ortega")
        at(bridge, "flat")
        place, price = the_door_with_a_price(bridge)
        if place is not None:
            earn_until(bridge, price)
        say(f"wallet {wallet(bridge)}; now put the game in front and run beats.py")
        return 0

    who = wait_for_player(bridge)
    say(f"player {who.get('id')} spawned at {who.get('pos')}")
    OUT.mkdir(parents=True, exist_ok=True)
    cam = Camera()
    frames: list = []

    def beat(name: str, caption: str, seconds: float = 2.2) -> None:
        say(f"  -- {name}: {caption}")
        shot = cam.clip(seconds)
        frames.extend(shot)
        if shot:
            shot[len(shot) // 2].save(OUT / f"beat-{name}.png", optimize=True)

    beat("01-arrive", "standing in the city")
    bridge.act(show="picker")
    time.sleep(1.2)
    beat("02-picker", "who are you today")
    become(bridge, "Vic", "Ortega")
    time.sleep(1.0)
    bridge.act(show="close")

    at(bridge, "liquor")
    bridge.act(show="nearby")
    time.sleep(1.2)
    beat("03-nearby", "what is close enough to walk up to")
    for counter in (bridge.do("me.nearby").get("value") or {}).get("shops") or []:
        bridge.do("shop.list", shop=counter["shop"])
        break
    bridge.act(show="close")
    time.sleep(0.4)

    bridge.act(show="pockets")
    time.sleep(1.2)
    beat("04-pockets", "what you are carrying")
    bridge.act(show="close")

    at(bridge, "flat")
    place, price = the_door_with_a_price(bridge)
    if place is None:
        say("    nothing here is for sale")
    else:
        bridge.act(show="nearby")
        time.sleep(1.2)
        beat("05-address", "a door with a price on it")
        bridge.act(show="close")
        bridge.act(show="jobs")
        time.sleep(1.2)
        beat("06-board", "who is hiring, and for what")
        bridge.act(show="close")
        earn_until(bridge, price)
        bridge.act(show="picker")
        time.sleep(1.0)
        beat("07-paid", "earned, a shift at a time")
        bridge.act(show="close")
        if bridge.do("property.buy", place=place).get("ok"):
            bridge.act(show="nearby")
            time.sleep(1.2)
            beat("08-yours", "the same door, an hour later")
            bridge.act(show="close")

    save_loop(frames, OUT / "underworld-loop.webp")
    cam.close()
    say(f"footage in {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
