"""Serve the real interface and take the eight screens out of it.

`baked_screens.json` holds each screen's rendered markup, and the listing writes
those straight into the page so every frame is there before a line of script has
run. They have to come from somewhere, and the somewhere used to be a
hand-assembled harness under `run/` with its own copy of `app.js` pasted into
it. A second copy of the code that draws the product is a copy that goes out of
step with the product, which is the same defect as a build reading a source
nobody is editing -- and that one has already cost this repository a day.

So this serves `adapter/nui` exactly as the game does: the real `index.html`,
the real `style.css`, the real `app.js`, off disk, unmodified. A browser opens
it, posts each view in `views.json` to the page the way the Lua side does, and
posts the resulting markup back here to be written.

    python bake_screens.py            serve, and wait to be baked into
    python bake_screens.py --port N   somewhere else

Then, in a browser at the address it prints, run the snippet it prints. The
browser is the part a script cannot honestly replace: what these frames are for
is proof that the page draws, and a renderer that is not a browser proves
nothing about a browser.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
NUI = HERE.parents[1] / "adapter" / "nui"
BAKED = HERE / "baked_screens.json"
VIEWS = HERE / "views.json"

# Which view in views.json each screen is drawn from. The phone is two reads
# the server answers separately and the page draws together, which is why it is
# the one that is not a straight lookup.
SCREENS = {
    "picker": lambda v: v["picker"],
    "pockets": lambda v: v["pockets"],
    "phone": lambda v: {"inbox": v["inbox"], "thread": v["thread"]},
    "shop": lambda v: v["shop"],
    "stash": lambda v: v["stash"],
    "nearby": lambda v: v["nearby"],
    "bank": lambda v: v["bank"],
    "jobs": lambda v: v["jobs"],
}


class Bake(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(NUI), **kwargs)

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith("/views.json"):
            body = VIEWS.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def do_POST(self):
        if not self.path.startswith("/bake"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length).decode("utf-8"))

        missing = sorted(set(SCREENS) - set(payload))
        if missing:
            self.send_error(400, "missing screens: " + ", ".join(missing))
            return
        empty = sorted(name for name, markup in payload.items() if len(markup or "") < 200)
        if empty:
            # A screen that drew nothing is markup too, and it would be written
            # into the page as a blank rectangle with nobody any the wiser.
            self.send_error(400, "these drew almost nothing: " + ", ".join(empty))
            return

        BAKED.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        note = f"wrote {BAKED.name}: " + ", ".join(
            f"{name} {len(payload[name]) // 1024}KB" for name in sorted(payload))
        print("  " + note)
        body = note.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


SNIPPET = """
(async () => {
  // views.json is written by support/json.lua, which cannot tell an empty list
  // from an empty map and writes both as {}. FiveM's json.encode writes an empty
  // table as [] -- measured on the enhanced server's /state, "players":[] -- so
  // that is what the page receives in the game. Baked as {}, Around you threw on
  // `offers.includes` and drew three of its seven rows.
  const asFiveM = v => Array.isArray(v) ? v.map(asFiveM)
    : (v && typeof v === 'object') ? (Object.keys(v).length === 0 ? []
      : Object.fromEntries(Object.entries(v).map(([k, x]) => [k, asFiveM(x)]))) : v;
  const V = asFiveM(await (await fetch('/views.json')).json());
  const plan = {
    picker: V.picker, pockets: V.pockets,
    phone: { inbox: V.inbox, thread: V.thread },
    shop: V.shop, stash: V.stash, nearby: V.nearby,
    bank: V.bank, jobs: V.jobs,
  };
  const out = {};
  for (const [name, view] of Object.entries(plan)) {
    // The bank screen names its branch on every button, so it is given one.
    window.postMessage({ type: name, view, ok: true, branch: V.bank_branch }, '*');
    await new Promise(r => setTimeout(r, 250));
    out[name] = document.getElementById(name).outerHTML;
  }
  return await (await fetch('/bake', { method: 'POST', body: JSON.stringify(out) })).text();
})()
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8732)
    args = parser.parse_args()

    if not VIEWS.exists():
        sys.exit(f"{VIEWS} is not there: run make_views.lua first")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Bake)
    print(f"serving {NUI} at http://127.0.0.1:{args.port}/index.html")
    print("run this in that page's console:")
    print(SNIPPET)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
