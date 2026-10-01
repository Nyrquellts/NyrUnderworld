"""Assemble the listing page.

The screens in it are the interface of the resource itself. They are
pre-rendered -- baked once out of the real app.js in a browser, against the real
view data from a city that was actually played -- and each frame is written into
the page as a complete inline document.

Two decisions worth the words:

  Pre-rendered, not drawn live in each frame. A frame that runs a script to show
  anything shows a black rectangle wherever scripts do not run, and these frames
  are the proof the page is built on.

  Inlined as `srcdoc`, not composed by JavaScript. Same reason, one step
  further: the screens are there when the HTML is parsed, before a line of
  script has run. Script only upgrades them -- it scales the 1280-wide render
  down crisply and walks the hero through the tour. Without it every screen
  still renders, laid out for the width it is given.

To re-bake after changing the interface: run bake_screens.py, which serves the
real adapter/nui and writes baked_screens.json from what a browser actually
draws. It used to say to use a harness under run/ with its own copy of app.js,
and a second copy of the drawing code is a copy that drifts from the product.
"""
import base64
import html
import json
import pathlib
import re

# Every input is beside this file, in the repository. It used to be a session
# temp directory, which meant the page that sells this could only be rebuilt
# from a folder Windows is entitled to delete without asking -- and, worse,
# that editing the source in the repository changed nothing, because the build
# was reading a different copy and quietly succeeding.
S = pathlib.Path(__file__).resolve().parent
OUT = S.parents[1] / "run" / "listing.html"
nui = S.parents[1] / "adapter" / "nui"

css = (nui / "style.css").read_text(encoding="utf-8")
# No game behind it here, so the ground it composites over is painted flat.
css += "\nhtml,body{background:#080706;}\n[hidden]{display:none!important;}\n"

screens = json.loads((S / "baked_screens.json").read_text(encoding="utf-8"))

TITLES = {
    "picker": "Character picker", "pockets": "Inventory", "phone": "Phone",
    "shop": "Shop counter", "stash": "Property stash", "nearby": "What is nearby",
    "bank": "Bank counter", "jobs": "Job board",
}


def document(name):
    return ('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><style>'
            + css + '</style></head><body>' + screens[name] + '</body></html>')


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def ascii_safe(markup):
    """Every character above ASCII as a numeric entity.

    What this builds is a fragment -- it has no `<head>`, because it is pasted
    into somebody else's listing editor -- so there is nowhere to declare a
    character set and the host decides. A browser with no declaration falls
    back to windows-1252, where the two bytes of a UTF-8 `.` become two
    characters. The listing read `APARTMENT A. FOR SALE` on the page that sells
    the product, from one middle dot in a screen drawn months after this file
    was written.

    An entity is the same in every encoding, which is the point.
    """
    return markup.encode("ascii", "xmlcharrefreplace").decode("ascii")


src = (S / "listing.src.html").read_text(encoding="utf-8")
assert "__NYR_CSS__" in src and "__NYR_SCREENS__" in src, "the page needs both slots"

# Every empty frame gets its whole document written into it, so the screens are
# in the page before any script runs.
filled = 0


def fill(match):
    global filled
    name = match.group("name")
    if name not in screens:
        raise SystemExit("no baked screen called " + name)
    filled += 1
    return (match.group("open")
            + '<iframe title="' + html.escape(TITLES.get(name, name))
            + '" scrolling="no" tabindex="-1" aria-hidden="true" srcdoc="'
            + ascii_safe(html.escape(document(name), quote=True)) + '"></iframe></div>')


out = re.sub(r'(?P<open><div class="screen-frame[^"]*"[^>]*data-screen="(?P<name>[a-z]+)"[^>]*>)\s*</div>',
             fill, src)
assert filled, "no frames were filled -- has the markup changed?"

out = out.replace("__NYR_CSS__", b64(css)).replace("__NYR_SCREENS__", b64(json.dumps(screens)))
out = out.replace("__NYR_KEYART__", (S / "keyart.b64").read_text(encoding="utf-8").strip())
# The whole page, not only the frames. Anything above ASCII that reaches here
# is a character whose appearance depends on a setting this fragment cannot
# make, so it is a defect however it arrived.
stray = sorted({c for c in out if ord(c) > 127})
assert not stray, ("the page is a fragment with no charset to declare, so these "
                   "would render as whatever the host guesses: " + repr(stray))

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(out, encoding="utf-8")
print(f"page {len(out):,} bytes ({len(out)/1024:.0f} KB) | {filled} frames inlined | css {len(css):,}")
