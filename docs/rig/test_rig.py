"""The rig's own tests: the record, the stage, the storm, and the bridge over a fake server.

    python docs/rig/test_rig.py

Stdlib only, like the rig. The bridge is tested against a small HTTP server in
a thread that answers the routes the real one answers, in the shapes it
answers them, so a change to how the rig reads an answer is caught here and
not on a Saturday with a person waiting at a keyboard.
"""
from __future__ import annotations

import http.server
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rig  # noqa: E402


# ------------------------------------------------------------- a fake bridge


class FakeCity:
    """What the fake server answers, changed by a test between requests."""

    def __init__(self) -> None:
        self.open = True
        self.lines: list[dict] = []
        self.seq = 0
        self.oldest = 1
        self.players: list[dict] = []
        self.verify = {"ok": True, "problems": [], "checked": ["world"], "missing": []}
        self.summary = {"accounts": 1, "errors": 0, "entities": {"chr": 1}, "owned": 0}
        self.commands = {"commands": [], "allowed": []}
        self.answers: dict[str, dict] = {}
        self.asked: list[str] = []

    def remember(self, said: str) -> None:
        self.seq += 1
        self.lines.append({"n": self.seq, "at": "00:00:00", "said": said})


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    city: FakeCity

    def log_message(self, *_args) -> None:
        pass

    def send(self, code: int, body) -> None:
        text = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(text)))
        self.end_headers()
        self.wfile.write(text)

    def do_GET(self) -> None:  # noqa: N802
        city = self.city
        city.asked.append(self.path)
        route, _, query = self.path.partition("?")
        route = route.removeprefix("/nyr_underworld")
        args = dict(urllib.parse.parse_qsl(query, keep_blank_values=True))
        if route in ("/state", "/"):
            self.send(200, {"open": city.open, "players": city.players, "seq": city.seq,
                            "log": city.lines[-40:], "summary": city.summary})
        elif route == "/log":
            since = args.get("since")
            if since is None:
                self.send(200, {"seq": city.seq, "log": city.lines[-40:]})
            elif not since.lstrip("-").isdigit() or int(since) < 0:
                self.send(400, {"ok": False, "why": f"since={since} is not a line number"})
            else:
                wanted = int(since)
                kept = [line for line in city.lines if line["n"] >= city.oldest]
                dropped = max(0, city.oldest - (wanted + 1)) if kept else 0
                self.send(200, {"since": wanted, "seq": city.seq, "dropped": dropped,
                                "log": [line for line in kept if line["n"] > wanted]})
        elif route == "/verify":
            if not city.open:
                self.send(503, {"ok": False, "code": "not_open"})
            else:
                self.send(200, dict(city.verify, summary=city.summary))
        elif route == "/errors":
            self.send(200, {"errors": [], "notices": [], "audit": []})
        elif route == "/commands":
            self.send(200, city.commands)
        elif route == "/do":
            p = args.get("p", "1")
            if not p.isdigit() or int(p) <= 0:
                self.send(400, {"ok": False, "why": f"p={p} is not a player id"})
                return
            if "c" not in args:
                self.send(400, {"ok": False, "why": "no command"})
                return
            if not city.open:
                self.send(200, {"ok": False, "code": "not_open"})
                return
            answer = city.answers.get(args["c"], {"ok": True, "code": "ok", "value": {"ran": args["c"]}})
            if isinstance(answer, list):
                # A sequence of answers: each request takes the next, the last
                # one stays.
                answer = answer.pop(0) if len(answer) > 1 else answer[0]
            self.send(200, answer)
        elif route == "/act":
            if args.get("show") == "nope":
                self.send(400, {"ok": False, "why": "no screen called nope"})
            else:
                self.send(200, {"ok": True, "to": 1, "sent": args})
        elif route == "/boom":
            self.send(500, {"ok": False, "code": "bridge_failed", "why": "it threw"})
        else:
            self.send(404, {"ok": False, "why": "try /state"})


class FakeServer:
    def __init__(self) -> None:
        self.city = FakeCity()
        handler = type("BoundHandler", (Handler,), {"city": self.city})
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


# ----------------------------------------------------------------- the tests


class TestRecord(unittest.TestCase):
    def test_a_sealed_record_is_intact_and_a_changed_one_is_not(self):
        record = rig.seal({"schema": rig.SCHEMA, "findings": [{"n": 1, "detail": "boom"}], "verdict": "findings"})
        self.assertEqual(record["digest"], rig.digest_of(record))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "one.json"
            path.write_text(json.dumps(record), encoding="utf-8")
            self.assertTrue(rig.check_record(path)["intact"])
            # One character of one finding, changed after the fact.
            tampered = json.loads(path.read_text(encoding="utf-8"))
            tampered["findings"][0]["detail"] = "fine"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            result = rig.check_record(path)
            self.assertFalse(result["intact"])
            self.assertTrue(any("changed after it was written" in p for p in result["problems"]))
            # And so is a verdict quietly upgraded.
            tampered = json.loads(path.read_text(encoding="utf-8"))
            tampered["findings"][0]["detail"] = "boom"
            tampered["verdict"] = "clean"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            self.assertFalse(rig.check_record(path)["intact"])

    def test_the_digest_does_not_depend_on_key_order_or_whitespace(self):
        a = rig.digest_of({"b": 1, "a": [1, 2], "c": {"y": 1, "x": 2}})
        b = rig.digest_of({"c": {"x": 2, "y": 1}, "a": [1, 2], "b": 1})
        self.assertEqual(a, b)
        self.assertNotEqual(a, rig.digest_of({"b": 1, "a": [2, 1], "c": {"y": 1, "x": 2}}))

    def test_a_record_knows_which_tree_it_is_about(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "src"
            (source / "adapter").mkdir(parents=True)
            (source / "fxmanifest.lua").write_text("fx_version 'cerulean'\n", encoding="utf-8")
            (source / "adapter" / "server.lua").write_text("return 1\n", encoding="utf-8")
            files = rig.shipping_hashes(source)
            record = rig.seal({"schema": rig.SCHEMA, "resource": {"staged_files": files,
                                                                    "staged_digest": rig.staged_digest(files)}})
            path = Path(folder) / "r.json"
            path.write_text(json.dumps(record), encoding="utf-8")
            self.assertTrue(rig.check_record(path, source)["about_this_tree"])
            (source / "adapter" / "server.lua").write_text("return 2\n", encoding="utf-8")
            result = rig.check_record(path, source)
            self.assertFalse(result["about_this_tree"])
            self.assertEqual(result["changed_files"], ["adapter/server.lua"])

    def test_the_chain_names_a_previous_record_that_is_there(self):
        with tempfile.TemporaryDirectory() as folder:
            first = rig.seal({"schema": rig.SCHEMA, "n": 1})
            (Path(folder) / "a.json").write_text(json.dumps(first), encoding="utf-8")
            second = rig.seal({"schema": rig.SCHEMA, "n": 2, "previous": first["digest"]})
            path = Path(folder) / "b.json"
            path.write_text(json.dumps(second), encoding="utf-8")
            self.assertTrue(rig.check_record(path)["previous_found"])
            (Path(folder) / "a.json").unlink()
            result = rig.check_record(path)
            self.assertFalse(result["previous_found"])
            self.assertTrue(any("previous record" in p for p in result["problems"]))

    def test_share_lines_carry_the_digest_and_how_to_check(self):
        with tempfile.TemporaryDirectory() as folder:
            record = rig.seal({"schema": rig.SCHEMA, "resource": {"commit": "abc", "staged_digest": "def", "dirty": ["x"]},
                               "server": {"flavour": "enhanced", "port": 1}, "client": {}, "verdict": "clean",
                               "findings": [], "log": [], "requests": 3})
            path = Path(folder) / "r.json"
            path.write_text(json.dumps(record), encoding="utf-8")
            lines = rig.share_lines(path)
            self.assertIn(record["digest"], lines[0])
            self.assertIn("dirty: x", lines[1])
            self.assertTrue(lines[-1].startswith("check it with:"))


class TestStage(unittest.TestCase):
    def test_what_ships_is_what_the_release_stage_ships(self):
        held = ["NEXT_SESSION.md", "data/*.json", "data/*.json.*", "*.cfg"]
        for name in ("adapter/server.lua", "fxmanifest.lua", "data/README.md", "adapter/nui/app.js", "LICENSE"):
            self.assertTrue(rig.ships(name, held), name)
        for name in (".git/HEAD", "spec/x_spec.lua", "tools/spec.cmd", "docs/rig/rig.py", "LEDGER.md",
                     "NEXT_SESSION.md", "data/city.json", "data/city.json.bak", "server.cfg", "run/x",
                     ".claude/worktrees/x/adapter/server.lua", "adapter/old.bak", ".nyrignore", "playtest/a.json"):
            self.assertFalse(rig.ships(name, held), name)

    def test_staging_copies_only_what_ships_on_a_fresh_city(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "NyrUnderworld"
            for name in ("fxmanifest.lua", "adapter/server.lua", "spec/x_spec.lua", "LEDGER.md",
                         "data/README.md", "data/city.json", ".git/HEAD", "docs/rig/rig.py"):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name, encoding="utf-8")
            (source / ".nyrignore").write_text("LEDGER.md\ndata/*.json\n", encoding="utf-8")
            dest = Path(folder) / "resources" / rig.NAME
            hashes = rig.stage(source, dest)
            self.assertEqual(sorted(hashes), ["adapter/server.lua", "data/README.md", "fxmanifest.lua"])
            self.assertTrue((dest / "data").is_dir())
            self.assertFalse((dest / "data" / "city.json").exists())
            self.assertEqual(hashes, rig.shipping_hashes(source))
            self.assertEqual(rig.staged_digest(hashes), rig.staged_digest(dict(reversed(list(hashes.items())))))

    def test_the_dev_directories_are_the_toolkits(self):
        # The lists the release stage holds back, kept here so the rig stages
        # what a buyer gets. spec/shipping_spec.lua checks them against the
        # local server scripts too.
        for name in ("spec", "tools", "playtest", "docs", "run"):
            self.assertIn(name, rig.DEV_DIRS)
        for name in (".git", ".claude", ".codex"):
            self.assertIn(name, rig.TOOL_DIRS)
        self.assertNotIn("data", rig.DEV_DIRS)


class TestConsole(unittest.TestCase):
    def test_secrets_are_taken_out_by_value_and_by_shape(self):
        text = "\x1b[32mkey cfxk_abcdefghijklmnop set\x1b[0m rcon deadbeef99 ok cfxk_zzzzzzzzzz\n"
        out = rig.scrub(text, "cfxk_abcdefghijklmnop", "deadbeef99")
        self.assertNotIn("cfxk_", out)
        self.assertNotIn("deadbeef99", out)
        self.assertNotIn("\x1b", out)
        self.assertIn("<secret>", out)
        self.assertIn("<licence key>", out)

    def test_the_server_config_binds_loopback_and_never_holds_the_key(self):
        text = rig.config_text(30199, "pw123")
        self.assertIn('endpoint_add_tcp "127.0.0.1:30199"', text)
        self.assertIn("sv_lan 1", text)
        self.assertIn('rcon_password "pw123"', text)
        self.assertIn(f"ensure {rig.NAME}", text)
        self.assertNotIn("sv_licenseKey", text)


class TestTrouble(unittest.TestCase):
    def test_lines_that_are_trouble_are_named_and_the_rest_are_not(self):
        cases = {
            "save: city.json could not be written": "save_failed",
            "shutdown save: x": "save_failed",
            "load: clock.json is not JSON": "load_failed",
            "the city remains closed; restore the save and restart this resource": "load_failed",
            "NYR UNDERWORLD did not start: config.lua has a problem": "did_not_start",
            "tick: attempt to index a nil value": "tick_failed",
            "health watch: boom": "tick_failed",
            "damage: boom": "tick_failed",
            "error (command:bank.deposit): bank.deposit failed: nil": "world_error",
            "dev bridge: /commands threw: the command bus is gone": "bridge_threw",
            "request from 1 broke the bridge: x": "bridge_broke",
            "shop.buy failed for license:abc: attempt to call nil": "handler_failed",
            "Rob's Liquor has no address: Strawberry is not in the city": "no_address",
        }
        for line, kind in cases.items():
            self.assertEqual(rig.trouble_in(line), kind, line)
        for line in ("the city is at day 0 monday 08:00 with 3 people, 6 addresses",
                     "added from config.lua: 2 shops, 3 employers",
                     "character.create for dev:local: ok",
                     "the city is kept in files under nyr_underworld/data",
                     "1 asked for me.map before the city was open",
                     "note (task:restock): caught up 3 restocks",
                     "the dev bridge was asked for /do?c=me.map before the city was open"):
            self.assertIsNone(rig.trouble_in(line), line)


class TestStorm(unittest.TestCase):
    LISTING = {"commands": [
        {"name": "bank.deposit", "summary": "", "args": [
            {"name": "amount", "type": "integer", "required": True},
            {"name": "branch", "type": "id", "kind": "prp", "required": True}]},
        {"name": "shop.buy", "summary": "", "args": [
            {"name": "item", "type": "string", "required": True, "enum": ["water", "bread"]}]},
    ], "allowed": ["bank.deposit"]}

    def test_every_declared_argument_gets_the_junk_its_type_deserves(self):
        requests = rig.storm_requests(self.LISTING)
        labels = [r["label"] for r in requests]
        self.assertIn("bank.deposit with nothing", labels)
        self.assertIn("bank.deposit without amount", labels)
        self.assertIn("bank.deposit without branch", labels)
        self.assertIn("bank.deposit with an undeclared key", labels)
        self.assertIn("bank.deposit with branch of the wrong kind", labels)
        self.assertIn("shop.buy with item outside its enum", labels)
        self.assertTrue(any(r["label"].startswith("bank.deposit with amount=-1") for r in requests))
        self.assertTrue(any(r["label"].startswith('shop.buy with item="xxxx') for r in requests))
        # The junk is beside plausible values, so what is tested is the junk.
        wrong = next(r for r in requests if r["label"] == "bank.deposit with branch of the wrong kind")
        self.assertEqual(wrong["args"]["amount"], 1)
        self.assertTrue(wrong["args"]["branch"].startswith("zzz_"))
        # And the URL-level junk is always there.
        self.assertIn("a= nested 200 deep", labels)
        self.assertIn("p=abc", labels)
        for request in requests:
            self.assertTrue("path" in request or ("command" in request and "args" in request), request)

    def test_the_storm_writes_down_a_failed_handler_and_a_broken_route_and_nothing_else(self):
        server = FakeServer()
        try:
            city = server.city
            city.commands = self.LISTING
            city.answers["bank.deposit"] = {"ok": False, "code": "failed", "message": "attempt to index nil"}
            city.answers["shop.buy"] = {"ok": False, "code": "bad_args", "message": "no"}
            bridge = rig.Bridge(server.port)
            hunt = rig.Hunt(bridge)
            hunt.begin("storm")
            result = rig.storm(hunt, bridge, lambda: True)
            kinds = [f["kind"] for f in hunt.findings]
            self.assertIn("handler_failed", kinds)
            self.assertNotIn("bridge_silent", kinds)
            self.assertNotIn("bridge_failed", kinds)
            self.assertGreater(result["sent"], 40)
            self.assertEqual(result["sent"], result["refused"] + result["accepted"] + result["closed"] + 40
                             + sum(1 for f in hunt.findings if f["kind"] in ("handler_failed", "bridge_failed")))
            # One kept-alive connection for the whole storm, plus the one after
            # the 414 that Python's HTTP server closes the connection on.
            self.assertLessEqual(bridge.connections, 2)
        finally:
            bridge.close()
            server.close()

    def test_an_accepted_negative_amount_is_something_a_person_should_see(self):
        server = FakeServer()
        try:
            server.city.commands = self.LISTING
            bridge = rig.Bridge(server.port)
            hunt = rig.Hunt(bridge)
            hunt.begin("storm")
            rig.storm(hunt, bridge, lambda: True)
            kinds = {f["kind"] for f in hunt.findings}
            self.assertIn("accepted_negative", kinds)
            self.assertIn("accepted_huge", kinds)
        finally:
            bridge.close()
            server.close()


class TestBridge(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()
        self.city = self.server.city
        self.bridge = rig.Bridge(self.server.port)

    def tearDown(self):
        self.bridge.close()
        self.server.close()

    def test_ready_waits_for_the_city_to_be_open_not_for_the_bridge_to_answer(self):
        self.city.open = False
        began = threading.Timer(0.6, lambda: setattr(self.city, "open", True))
        began.start()
        self.assertTrue(self.bridge.ready(5))
        self.assertGreater(len([p for p in self.city.asked if "/state" in p]), 1)
        self.assertIs(self.bridge.city_open, True)

    def test_ready_gives_up_when_nothing_answers(self):
        silent = rig.Bridge(1)
        self.assertFalse(silent.ready(1.5))
        with self.assertRaises(rig.BridgeSilent):
            silent.state()

    def test_the_log_is_drained_by_number_and_loss_is_counted(self):
        for said in ("one", "two", "three"):
            self.city.remember(said)
        self.assertEqual([l["said"] for l in self.bridge.drain()], ["one", "two", "three"])
        self.assertEqual(self.bridge.seq, 3)
        self.assertEqual(self.bridge.drain(), [])
        self.city.remember("four")
        self.assertEqual([l["said"] for l in self.bridge.drain()], ["four"])
        self.assertEqual([l["said"] for l in self.bridge.lines], ["one", "two", "three", "four"])
        # The server forgot lines 5 and 6 before the next drain.
        self.city.remember("five")
        self.city.remember("six")
        self.city.remember("seven")
        self.city.oldest = 7
        self.assertEqual([l["said"] for l in self.bridge.drain()], ["seven"])
        self.assertEqual(self.bridge.dropped, 2)

    def test_one_connection_answers_many_requests(self):
        for _ in range(60):
            self.bridge.state()
        self.assertEqual(self.bridge.connections, 1)
        self.assertEqual(self.bridge.requests, 60)

    def test_a_command_is_answered_as_sent_and_hooks_see_it(self):
        seen = []
        self.bridge.after_do.append(lambda c, a, ans: seen.append((c, a, ans.get("ok"))))
        answer = self.bridge.do("character.create", first_name="Jane", last_name="Doe")
        self.assertTrue(answer["ok"])
        self.assertEqual(seen, [("character.create", {"first_name": "Jane", "last_name": "Doe"}, True)])
        # The toolkit's calling shape works too.
        self.assertTrue(self.bridge.do("me.status", {}, 1)["ok"])
        asked = [p for p in self.city.asked if "/do" in p][-1]
        self.assertIn("p=1", asked)

    def test_a_refusal_is_an_answer_with_its_status_kept(self):
        answer = self.bridge.raw("/do?p=abc&c=me.status")
        self.assertEqual(self.bridge.last_status, 400)
        self.assertFalse(answer["ok"])
        self.assertEqual(self.bridge.act(show="nope"), {"ok": False, "why": "no screen called nope"})
        self.assertTrue(self.bridge.act(show="pockets")["ok"])
        self.bridge.raw("/boom")
        self.assertEqual(self.bridge.last_status, 500)

    def test_the_client_being_driven_is_the_one_read(self):
        self.city.players = [{"id": 1, "reporting": False}, {"id": 3, "reporting": True, "spawned": True}]
        self.assertTrue(self.bridge.has_client())
        self.assertEqual(self.bridge.adopt(), 3)
        self.assertTrue(self.bridge.has_body())
        self.assertEqual(self.bridge.watching()["id"], 3)
        self.city.players = []
        self.assertFalse(self.bridge.has_client())
        self.assertEqual(self.bridge.watching(), {})


class TestHunt(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()
        self.city = self.server.city
        self.bridge = rig.Bridge(self.server.port)
        self.hunt = rig.Hunt(self.bridge)
        self.hunt.begin("test")

    def tearDown(self):
        self.bridge.close()
        self.server.close()

    def test_trouble_in_the_log_becomes_a_finding_once(self):
        self.city.remember("the city is at day 0")
        self.city.remember("save: could not write city.json")
        self.hunt.drain()
        self.hunt.drain()
        self.assertEqual([f["kind"] for f in self.hunt.findings], ["save_failed"])
        self.assertEqual(self.hunt.findings[0]["evidence"]["log_line"], 2)
        self.assertEqual(self.hunt.findings[0]["severity"], "high")

    def test_the_books_off_is_a_finding_said_once_per_problem(self):
        self.city.verify = {"ok": False, "problems": [{"where": "world", "problem": "the books are off by $1.00"}],
                            "checked": ["world"], "missing": ["standing"]}
        self.hunt.verify(after="shop.buy")
        self.hunt.verify(after="shop.sell")
        kinds = [(f["kind"], f["detail"]) for f in self.hunt.findings]
        self.assertEqual(len(kinds), 2)
        self.assertIn("the books are off by $1.00 (after shop.buy)", kinds[0][1])
        self.assertIn("no verifier for standing", kinds[1][1])

    def test_a_client_error_is_a_finding_once(self):
        self.city.players = [{"id": 1, "reporting": True, "errors": ["#1 dev:act: no screen called x"]}]
        self.hunt.read_client()
        self.hunt.read_client()
        self.assertEqual([f["kind"] for f in self.hunt.findings], ["client_error"])
        self.city.players[0]["errors"].append("#2 dev:report: boom")
        self.hunt.read_client()
        self.assertEqual(len(self.hunt.findings), 2)

    def test_finish_writes_a_sealed_record_whose_verdict_follows_the_findings(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            args = type("Args", (), {"out": str(out)})()

            def run(findings) -> dict:
                bridge = rig.Bridge(self.server.port)
                hunt = rig.Hunt(bridge)
                hunt.begin("test")
                for kind, detail in findings:
                    hunt.find(kind, detail)
                record = {"schema": rig.SCHEMA, "resource": {}, "server": {}, "client": {}}
                root = out / f"hunt-{len(list(out.glob('*.json')))}"
                root.mkdir()
                code = rig.finish(record, hunt, None, bridge, root, rig.latest_record(out), args)
                path = out / f"{root.name}.json"
                loaded = json.loads(path.read_text(encoding="utf-8"))
                self.assertTrue(rig.check_record(path)["intact"])
                loaded["_code"] = code
                return loaded

            clean = run([])
            self.assertEqual(clean["verdict"], "clean")
            self.assertEqual(clean["_code"], 0)
            self.assertIsNone(clean["previous"])
            unmade = run([("unmade", "no client")])
            self.assertEqual(unmade["verdict"], "unmade")
            self.assertEqual(unmade["previous"], clean["digest"])
            found = run([("books_off", "off by a dollar")])
            self.assertEqual(found["verdict"], "findings")
            self.assertEqual(found["_code"], 1)
            broken = run([("server_died", "gone")])
            self.assertEqual(broken["verdict"], "broken")
            self.assertEqual(broken["previous"], found["digest"])
            self.assertIn("phases", broken)
            self.assertNotIn("_t", broken["phases"][0])


class TestHoles(unittest.TestCase):
    """What was built and never run, and what was claimed and did not hold."""

    def setUp(self):
        self.server = FakeServer()
        self.city = self.server.city
        self.bridge = rig.Bridge(self.server.port)

    def tearDown(self):
        self.bridge.close()
        self.server.close()

    def test_the_storm_acts_as_nobody_who_is_connected(self):
        # With a client connected as 1, `character.release` with no arguments
        # is not junk: sent as player 1 it releases that player's character.
        self.city.players = [{"id": 1, "reporting": True, "spawned": True}, {"id": 4, "reporting": False}]
        self.city.commands = {"commands": [{"name": "character.release", "summary": "", "args": []}], "allowed": []}
        hunt = rig.Hunt(self.bridge)
        hunt.begin("storm")
        result = rig.storm(hunt, self.bridge, lambda: True)
        self.assertEqual(result["as_player"], 1004)
        sent = [p for p in self.city.asked if "/do" in p or "/act" in p]
        self.assertTrue(sent)
        for path in sent:
            args = dict(urllib.parse.parse_qsl(path.partition("?")[2], keep_blank_values=True))
            self.assertNotIn(args.get("p"), ("1", "4"), path)
        # The requests whose point is a junk id keep it.
        self.assertTrue(any("p=-1" in p for p in sent))
        self.assertTrue(any("p=abc" in p for p in sent))

    def test_people_of_waits_out_a_rate_limit(self):
        self.city.answers["character.list"] = [
            {"ok": False, "code": "too_fast"}, {"ok": False, "code": "too_fast"},
            {"ok": True, "code": "ok", "value": {"characters": [{"name": "Jane Doe"}, {"name": "Ada"}]}}]
        began = time.monotonic()
        self.assertEqual(rig.people_of(self.bridge), ["Ada", "Jane Doe"])
        self.assertGreater(time.monotonic() - began, 3.5)
        # And it reads the account being driven, not player 1.
        self.bridge.target = 7
        self.city.answers["character.list"] = {"ok": True, "code": "ok", "value": {"characters": []}}
        rig.people_of(self.bridge)
        self.assertIn("p=7", self.city.asked[-1])

    def test_the_books_unchecked_is_unmade_not_clean(self):
        self.city.open = False
        hunt = rig.Hunt(self.bridge)
        hunt.begin("restart")
        hunt.verify(after="the restart")
        self.assertEqual([f["kind"] for f in hunt.findings], ["unmade"])
        self.city.open = True
        self.city.verify = {"ok": False, "problems": [], "checked": [], "missing": []}
        hunt.verify(after="play")
        self.assertEqual(hunt.findings[-1]["kind"], "books_off")
        self.assertIn("without a problem list", hunt.findings[-1]["detail"])

    def test_rcon_refused_knows_every_way_rcon_says_no(self):
        for reply in ("print The server must set rcon_password to be able to use this command.",
                      "print Invalid password.", "no reply: timeout", "print Bad rconpassword."):
            self.assertTrue(rig.Session.rcon_refused(reply), reply)
        for reply in ("print\n stop nyr_underworld", "print [nyr] the city was written down at day 0"):
            self.assertFalse(rig.Session.rcon_refused(reply), reply)

    def test_default_port_finds_a_lingering_hunt_and_forgets_a_finished_one(self):
        import socket
        with tempfile.TemporaryDirectory() as folder:
            saved_run, saved_local = rig.RUN, os.environ.get("LOCALAPPDATA")
            rig.RUN = Path(folder) / "rig"
            rig.RUN.mkdir()
            os.environ["LOCALAPPDATA"] = folder   # no capture stage here either
            listener = socket.socket()
            try:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                port = listener.getsockname()[1]
                (rig.RUN / "session.json").write_text(json.dumps({"port": port, "root": "x"}), encoding="utf-8")
                self.assertEqual(rig.default_port(1), port)
                listener.close()
                # The server is gone: the pointer is stale, and the fallback answers.
                self.assertEqual(rig.default_port(1), 1)
            finally:
                listener.close()
                rig.RUN = saved_run
                if saved_local is None:
                    os.environ.pop("LOCALAPPDATA", None)
                else:
                    os.environ["LOCALAPPDATA"] = saved_local

    def test_who_was_connected_does_not_reach_the_record_or_the_console(self):
        value = {"players": [{"id": 1, "account": "license:0123456789abcdef0123456789abcdef01234567"},
                             {"id": 2, "account": "dev:127.0.0.1"}],
                 "steps": [{"client": {"account": "steam:110000112345678"}}], "pos": "1, 2, 3"}
        out = rig.redacted(value)
        self.assertTrue(out["players"][0]["account"].startswith("license:"))
        self.assertNotIn("0123456789abcdef", out["players"][0]["account"])
        self.assertEqual(len(out["players"][0]["account"]), len("license:") + 12)
        self.assertEqual(out["players"][1]["account"], "dev:127.0.0.1")
        self.assertNotIn("110000112345678", json.dumps(out))
        self.assertEqual(out["pos"], "1, 2, 3")
        # The same identifier, twice, redacts to the same short hash: player 1
        # can still be followed through a record.
        self.assertEqual(rig.redacted("license:abcdefabcdef"), rig.redacted("license:abcdefabcdef"))
        console = "[nyr] license:0123456789abcdef0123456789abcdef01234567 asked for me.map\n"
        self.assertNotIn("0123456789abcdef", rig.scrub(console))
        self.assertIn("license:<redacted>", rig.scrub(console))

    def test_a_record_that_describes_no_tree_says_so_without_failing(self):
        with tempfile.TemporaryDirectory() as folder:
            record = rig.seal({"schema": rig.SCHEMA, "resource": {"staged_files": {}, "staged_digest": None}})
            path = Path(folder) / "watch.json"
            path.write_text(json.dumps(record), encoding="utf-8")
            result = rig.check_record(path, Path(folder))
            self.assertTrue(result["intact"])
            self.assertIsNone(result["about_this_tree"])
            self.assertEqual(result["problems"], [])
            self.assertTrue(any("describes no tree" in n for n in result["notes"]))


if __name__ == "__main__":
    os.chdir(Path(__file__).resolve().parents[2])
    # What the rig says while a test drives it is for a person watching a real
    # hunt. Here it was eighty lines on every suite run -- "! high books_off"
    # among them, from a test proving the rig reports exactly that -- which a
    # reader skims for real failures and an agent pays for in tokens. Kept when
    # asked for; a failing test still prints its own traceback either way.
    if os.environ.get("NYR_RIG_VERBOSE") != "1":
        rig.say = lambda line: None
        rig.tell = lambda *parts: None
    unittest.main(verbosity=1)
