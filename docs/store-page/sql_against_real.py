"""Run the store's own SQL against a real MariaDB.

Until now every statement this store emits has only ever been executed by a fake
driver I wrote to match my own SQL. That proves the store and the fake agree. It
does not prove the SQL is valid, or that MariaDB behaves the way the fake does.

So: drive the real Lua store, capture the exact statements and parameters it
produced, and replay them against a real server with real server-side binding
(PREPARE / EXECUTE ... USING), then check the answers.

Four things are actually in question, and all four would be silent in production:

  ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)
      The row-alias form is MySQL 8.0.20+. MariaDB does not take it. I chose the
      deprecated VALUES() form on that reasoning and never tested it.
  store_key VARCHAR(190) COLLATE utf8mb4_bin
      The default collation is case-insensitive and would merge two records
      whose ids differ only in case.
  the 190 character limit
      A longer key truncates on a permissive server and two records become one.
  integers through JSON
      Money is whole cents. A round trip that returns 1250.0 has lost the point.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import os
BIN = Path(os.environ.get("MARIADB_BIN", "mariadb"))
SCRATCH = Path(__file__).parent
PORT = "3307"


def sql(script: str, database: str | None = None) -> str:
    args = [str(BIN), "--protocol=TCP", "-h", "127.0.0.1", "-P", PORT, "-u", "root", "--batch", "--raw"]
    if database:
        args += [database]
    done = subprocess.run(args, input=script, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if done.returncode != 0:
        raise SystemExit(f"mariadb refused:\n{done.stderr.strip()}\n--- script ---\n{script}")
    if done.stderr.strip():
        print("   note:", done.stderr.strip().splitlines()[0])
    return done.stdout


def quote(value) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def run_bound(statement: str, params: list, database: str) -> str:
    """Execute with real server-side parameter binding, the way a driver does."""
    lines = ["SET @s = " + quote(statement) + ";", "PREPARE st FROM @s;"]
    names = []
    for index, value in enumerate(params):
        name = f"@p{index}"
        names.append(name)
        lines.append(f"SET {name} = {quote(value)};")
    using = (" USING " + ", ".join(names)) if names else ""
    lines.append(f"EXECUTE st{using};")
    lines.append("DEALLOCATE PREPARE st;")
    return sql("\n".join(lines), database)


def main():
    statements = json.loads((SCRATCH / "emitted_sql.json").read_text(encoding="utf-8"))
    print(f"replaying {len(statements)} statements the Lua store actually emitted\n")

    sql("DROP DATABASE IF EXISTS nyr_live; CREATE DATABASE nyr_live;")

    kinds = {}
    for entry in statements:
        text = entry["sql"]
        verb = text.strip().split()[0].upper()
        kinds[verb] = kinds.get(verb, 0) + 1
        out = run_bound(text, entry["params"], "nyr_live")
        head = " ".join(text.split())[:76]
        print(f"  ok  {head}")
        if out.strip() and verb == "SELECT":
            rows = [r for r in out.strip().splitlines()[1:]]
            print(f"      -> {len(rows)} row(s)")

    print("\n" + "=" * 68)
    print("what the real server says about the four things in question")
    print("=" * 68)

    schema = sql("SHOW FULL COLUMNS FROM nyr_store;", "nyr_live")
    for line in schema.strip().splitlines()[1:]:
        cell = line.split("\t")
        print(f"  {cell[0]:<12} {cell[1]:<14} collation={cell[2]}")

    print("\n  case sensitivity of the key column")
    run_bound("INSERT INTO `nyr_store` (`collection`, `store_key`, `payload`) VALUES (?, ?, ?) "
              "ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)",
              ["case", "Bob", '{"who":"upper"}'], "nyr_live")
    run_bound("INSERT INTO `nyr_store` (`collection`, `store_key`, `payload`) VALUES (?, ?, ?) "
              "ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)",
              ["case", "bob", '{"who":"lower"}'], "nyr_live")
    got = sql("SELECT store_key, payload FROM nyr_store WHERE collection='case' ORDER BY store_key;",
              "nyr_live")
    rows = got.strip().splitlines()[1:]
    print(f"    Bob and bob stored as {len(rows)} row(s): {rows}")
    print("    " + ("PASS - two rows, the collation is binary" if len(rows) == 2
                    else "FAIL - they merged; the collation is not binary"))

    print("\n  ON DUPLICATE KEY UPDATE actually updates")
    run_bound("INSERT INTO `nyr_store` (`collection`, `store_key`, `payload`) VALUES (?, ?, ?) "
              "ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)",
              ["case", "Bob", '{"who":"upper","v":2}'], "nyr_live")
    got = sql("SELECT payload FROM nyr_store WHERE collection='case' AND store_key='Bob';", "nyr_live")
    value = got.strip().splitlines()[1]
    print(f"    second write of the same key -> {value}")
    print("    " + ("PASS - VALUES(payload) works on MariaDB" if '"v":2' in value
                    else "FAIL - the row did not update"))

    print("\n  a key longer than the column")
    long_key = "k" * 191
    try:
        run_bound("INSERT INTO `nyr_store` (`collection`, `store_key`, `payload`) VALUES (?, ?, ?)",
                  ["case", long_key, "{}"], "nyr_live")
        kept = sql(f"SELECT CHAR_LENGTH(store_key) FROM nyr_store WHERE collection='case' "
                   f"AND store_key LIKE 'kkk%';", "nyr_live").strip().splitlines()[1:]
        print(f"    191 characters went in and came back as {kept}")
        print("    NOTE - the server truncated rather than refusing, which is why the")
        print("           store refuses a long key at the put instead of relying on this")
    except SystemExit as refused:
        print("    PASS - the server refused it outright")
        print("   ", str(refused).splitlines()[1][:90])

    print("\n  integers through the payload")
    run_bound("INSERT INTO `nyr_store` (`collection`, `store_key`, `payload`) VALUES (?, ?, ?)",
              ["money", "vic", '{"wallet":218050,"name":"Vic Ortega"}'], "nyr_live")
    got = sql("SELECT payload FROM nyr_store WHERE collection='money' AND store_key='vic';", "nyr_live")
    payload = got.strip().splitlines()[1]
    decoded = json.loads(payload)
    print(f"    stored {payload}")
    print(f"    wallet reads back as {decoded['wallet']!r} ({type(decoded['wallet']).__name__})")
    print("    " + ("PASS - still a whole number of cents" if decoded["wallet"] == 218050
                    and isinstance(decoded["wallet"], int) else "FAIL - it is not an integer"))

    print("\nstatements replayed by verb:", kinds)


if __name__ == "__main__":
    main()
