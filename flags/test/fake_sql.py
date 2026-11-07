"""A stand-in for the SQL command an app's armiesLive names (psql, in the app), keeping the army_catalog
table and its log in a JSON file (FAKE_SQL_STATE) and answering the statements flags/live.nu's armies
kind runs, as the database's functions answer them (Bonk Chess: spec/army_catalog.cue): army_catalog_set
bumps a row's version unless nothing changed and refuses a stale expectation, army_catalog_drop removes a
row, and each change is logged. The statement is on stdin."""
import json, os, re, sys

STATE = os.environ["FAKE_SQL_STATE"]
state = json.load(open(STATE)) if os.path.exists(STATE) else {"rows": {}, "log": []}
save = lambda: json.dump(state, open(STATE, "w"), indent=1)
sql = sys.stdin.read().strip()
clock = len(state["log"]) + 1


def key(army, aud):
    return army + ("/testers" if aud == "testers" else "")


def expect_ok(k, expect):
    have = state["rows"].get(k, {}).get("version", 0)
    if expect != "NULL" and int(expect) != have:
        print(f"ERROR: army_catalog: 412 {k} is at version {have}, not {expect}", file=sys.stderr)
        sys.exit(1)
    return have


m = re.match(r"SELECT player_record\.army_catalog_set\('([^']*)', '((?:[^']|'')*)'::jsonb, '([a-z]+)', (\d+), (NULL|\d+)\);$", sql)
if m:
    army, body, aud, runner, expect = m.groups()
    body = json.loads(body.replace("''", "'"))
    if os.environ.get("FAKE_SQL_REFUSE") == army:
        print(f"ERROR: army_catalog: the entry does not describe {army}", file=sys.stderr)
        sys.exit(1)
    k = key(army, aud)
    have = expect_ok(k, expect)
    row = state["rows"].get(k)
    if row and row["entry"] == body and row["min_runner"] == int(runner):
        print(row["version"])
        sys.exit(0)
    v = have + 1
    state["rows"][k] = {"id": k, "army": army, "audience": aud, "version": v, "min_runner": int(runner), "entry": body}
    state["log"].append({"at": f"t{clock:04d}", "who": "operator", "key": k, "version": v, "min_runner": int(runner), "entry": body})
    save()
    print(v)
    sys.exit(0)

m = re.match(r"SELECT player_record\.army_catalog_drop\('([^']*)', '([a-z]+)', (NULL|\d+)\);$", sql)
if m:
    army, aud, expect = m.groups()
    k = key(army, aud)
    have = expect_ok(k, expect)
    if k not in state["rows"]:
        print(0)
        sys.exit(0)
    del state["rows"][k]
    state["log"].append({"at": f"t{clock:04d}", "who": "operator", "key": k, "version": have + 1, "min_runner": None, "entry": None})
    save()
    print(have + 1)
    sys.exit(0)

if "FROM public.army_catalog" in sql:
    for k in sorted(state["rows"]):
        print(json.dumps(state["rows"][k]))
    sys.exit(0)

if "FROM player_record.army_catalog_log" in sql:
    for r in reversed(state["log"]):
        print(json.dumps(r))
    sys.exit(0)

print(f"fake sql: no stand-in for: {sql}", file=sys.stderr)
sys.exit(2)
