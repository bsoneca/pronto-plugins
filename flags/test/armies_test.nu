# pronto-armies (flags/live.nu: the armies kind of the push) against a stand-in for the app's SQL command
# (fake_sql.py, which keeps army_catalog and its log in a JSON file and answers army_catalog_set and
# army_catalog_drop as the database's functions do) on an app whose CUE is real: `show` writes nothing; a push to the
# stack at hand writes everyone at once and only what changed; a push to production is refused with no cases
# (nothing written), writes everyone's rows at once, then runs the flag's production cases that sign in as no one
# (PRONTO-284: no testers' stage); a failing case writes back what was there; a dry run
# writes nothing; a rollback writes an earlier entry again as the newest.
#   ./saytw --script tools.nu nu flags/test/armies_test.nu

const here = path self .
let real = $env.SAYT_MISE_BIN
let dir = (mktemp -d)
let state = $"($dir)/sql.json"
let app = $"($dir)/shop"
mkdir $app
"package shop\n" | save $"($app)/program.cue"
'[tools]
"github:cue-lang/cue" = "0.16.1"
' | save $"($app)/.mise.toml"
^$real trust -q $"($app)/.mise.toml"

def sparta [label: string] { {id: "sparta", name: "army_sparta", icon: "shield", label: $label, like: "heroes"} }
def spec [label: string, live: bool] {
	let sql = $"FAKE_SQL_STATE=($state) python3 ($here)/fake_sql.py"
	let livepart = if $live { $"live: \"($sql)\"" } else { "" }
	$"package shop
armiesLive: {
	flag: \"army_catalog_live\"
	rows: [{army: \"sparta\", audience: \"everyone\", min_runner: 1, entry: {id: \"sparta\", name: \"army_sparta\", icon: \"shield\", label: \"($label)\", like: \"heroes\"}}]
	local: \"($sql)\"
	($livepart)
}
flagsLive: {project: \"shop-prod\", bucket: \"shop-prod-flags\", url: \"https://shop.example\"}
flagsCases: live: \"echo live $FLAG $ONLY $APP_URL ${FLAGS_TESTER:-} >> ran.log; test ! -f fail-live\"
" | save -f $"($app)/flags_spec.cue"
}
def livex [args: list<string>, extra: record = {}] {
	with-env ({SAYT_MISE_BIN: $"($here)/fake_mise.sh", REAL_MISE: $real, FAKE_SQL_STATE: $state, FAKE_GCLOUD_STATE: $"($dir)/gcloud.json", PRONTO_FLAGS_JOURNAL: $"($dir)/journal.jsonl"} | merge $extra) {
		^$nu.current-exe $"($here)/../live.nu" ...$args | complete
	}
}
def --wrapped armies [...args] {
	let r = (livex [armies ...$args])
	if $r.exit_code != 0 { error make {msg: $"live.nu armies ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}
def held [] { if ($state | path exists) { open $state } else { {rows: {}, log: []} } }
def ran [] { if ($"($app)/ran.log" | path exists) { open --raw $"($app)/ran.log" | lines } else { [] } }
def check [ok: bool, what: string] { if not $ok { error make {msg: $"failed: ($what)"} }; print $"ok: ($what)" }

spec "Sparta" false
let shown = (armies show $app --local)
check (($shown | str contains "sparta") and ($shown | str contains "absent")) "show: what a push would write"
check (($state | path exists) == false) "show writes nothing"

# At hand: written for everyone at once, only what changed.
armies push $app --local | ignore
check ((held).rows.sparta.version == 1 and (held).rows.sparta.audience == "everyone" and (held).rows.sparta.entry.label == "Sparta") "local push: the army, for everyone, version 1"
check ((held).rows | columns | where {|c| $c | str contains "/testers" } | is-empty) "local push: no testers' stage at hand"
let again = (armies push $app --local)
check (($again | str contains "nothing written") and (held).log.0 != null and ((held).log | length) == 1) "local push again: nothing changed, nothing written"
spec "Spartans" false
armies push $app --local | ignore
check ((held).rows.sparta.version == 2 and (held).rows.sparta.entry.label == "Spartans" and ((held).log | length) == 2) "local push: a changed entry is the next version"
check (open --raw $"($dir)/journal.jsonl" | lines | last | from json | get event | $in == "armies.write") "the push is journalled as the flags' are"

# Production: no command for it, or no cases: refused, nothing written.
let n = ((held).log | length)
let nolive = (livex [armies push $app])
check ($nolive.exit_code != 0 and ($nolive.stderr | str contains "names no live command") and ((held).log | length) == $n) "no live command: refused"
spec "Spartans of Pronto" true
let nocases = (livex [armies push $app])
check ($nocases.exit_code != 0 and ($nocases.stderr | str contains "has no cases") and ((held).log | length) == $n) "no cases: refused, nothing written"
mkdir $"($app)/tests/scenarios"
'package scenarios
scenarios: lobby: {flags: ["army_catalog_live"], steps: [{by: "tess", flag: "army_catalog_live", open: "/"}]}
' | save -f $"($app)/tests/scenarios/armies.cue"
let v0 = (held).rows.sparta.version
let noprod = (livex [armies push $app])
check ($noprod.exit_code == 0 and (ran | is-empty) and (held).rows.sparta.version == $v0 + 1) "no production scenario: written for everyone, no case run"
spec "Spartans" true
livex [armies push $app] | ignore
spec "Spartans of Pronto" true
'package scenarios
scenarios: lobby: {flags: ["army_catalog_live"], production: true, steps: [{by: "tess", flag: "army_catalog_live", open: "/"}]}
scenarios: mine: {flags: ["army_catalog_live"], production: true, steps: [{by: "tess", signIn: true}]}
' | save -f $"($app)/tests/scenarios/armies.cue"

# The live stage: everyone's row at once, then the production cases that sign in as no one; no testers' row.
let v = (held).rows.sparta.version
let ok = (livex [armies push $app])
check ($ok.exit_code == 0 and ($ok.stderr | str contains "not run")) "live push: a case that signs in is listed, not run"
check ((ran) == ["live army_catalog_live lobby https://shop.example"]) "live push: only the production cases that sign in as no one ran"
check ((held).rows.sparta.version == $v + 1 and (held).rows.sparta.entry.label == "Spartans of Pronto") "live push: everyone's row is the new entry"
check (not ((held).log | any {|r| $r.key == "sparta/testers" })) "live push: no testers' row was ever written"
check (open --raw $"($dir)/journal.jsonl" | lines | last | from json | get cases | $in == "passed") "live push: the journal says the cases passed"

# A case that fails: what was there is written again.
spec "Spartans of the North" true
touch $"($app)/fail-live"
let before = (held).rows.sparta
let bad = (livex [armies push $app])
check ($bad.exit_code != 0 and ($bad.stderr | str contains "rolled back") and ($bad.stderr | str contains "production cases failed")) "a failing case: the push fails"
check ((held).rows.sparta.entry.label == $before.entry.label and ("sparta/testers" in (held).rows) == false) "a failing case: the entry is as it was"
check (open --raw $"($dir)/journal.jsonl" | lines | last | from json | get stage | $in == "rolled-back") "a failing case: the journal says rolled back"
rm $"($app)/fail-live"

# An army the database refuses: rolled back as well.
let refused = (livex [armies push $app] {FAKE_SQL_REFUSE: "sparta"})
check ($refused.exit_code != 0 and ((held).rows.sparta.entry.label == $before.entry.label)) "a refused entry: nothing changes"

# A dry run writes nothing, however it is reached.
let m = ((held).log | length)
let dry = (livex [armies push $app --dry-run])
check ($dry.exit_code == 0 and ((held).log | length) == $m) "--dry-run: nothing written"
let dryl = (livex [armies push $app --local --dry-run])
check ($dryl.exit_code == 0 and ((held).log | length) == $m) "--dry-run at hand: nothing written"
let wrong = (livex [armies push $app --local --expect "armies:local:somewhere else"])
check ($wrong.exit_code != 0 and ((held).log | length) == $m) "--expect: another target is refused"

# History and rollback.
let hist = (armies history $app --local --json | from json)
check (($hist | length) == ((held).log | length) and $hist.0.version >= $hist.1.version) "history: every write, newest first"
let live_v = (held).rows.sparta.version
let want = ((held).log | where {|r| $r.key == "sparta" and $r.entry != null and $r.version != $live_v } | sort-by version --reverse | first | get entry.label)
armies rollback $app sparta --local | ignore
check ((held).rows.sparta.entry.label == $want and (held).rows.sparta.version > $live_v) "rollback: the version before the live one, written again"
let none = (livex [armies rollback $app sparta 999 --local])
check ($none.exit_code != 0 and ($none.stderr | str contains "no earlier version")) "rollback to a version that isn't there is refused"
