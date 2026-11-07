# The released app's live flags: one object in a versioned Cloud Storage bucket,
# which the app's flagd reads (FLAGD_SOURCES, release.cue) and polls, so a flag
# changes with a push and never a deploy. The app's flagsLive (flags_spec.cue)
# names the bucket and its project; its flags are flagd.document, exported from
# the app's CUE as generate writes flags/flags.json. Every push is a version of
# the object, kept: the history, and what a rollback restores.
#   bin/pronto-flags setup <app-dir>               # the bucket, its readers, the first push
#   bin/pronto-flags push <app-dir>                # the flags as flags_spec.cue says them now, once their cases pass
#   bin/pronto-flags cases <app-dir> [flag]        # the cases a flip of each flag (or the one) runs
#   bin/pronto-flags history <app-dir>             # every version, newest first
#   bin/pronto-flags rollback <app-dir> [version]  # the version before the live one, or the one named
#   bin/pronto-flags show <app-dir>                # what a push would write, and where: nothing written
# Each runs as the operator's own gcloud login.
# A push that changes a flag's default value runs that flag's cases first (see `push`).

# gcloud on the Python pinned beside it, never on the virtualenv it shares with every other gcloud
# on the machine (~/.config/gcloud/virtenv): another gcloud rebuilds that on its own Python, and a
# Python this gcloud predates crashes it (3.14: "module 'ssl' has no attribute 'PROTOCOL_TLSv1'").
def --wrapped run-gcloud [...args] {
	let input = $in
	$input | with-env {CLOUDSDK_PYTHON: python3.12, CLOUDSDK_PYTHON_SITEPACKAGES: "0"} { ^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet ...$args | complete }
}
def --wrapped gc [...args] {
	let input = $in
	let r = ($input | run-gcloud ...$args)
	if $r.exit_code != 0 { error make {msg: $"gcloud ($args | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}
def --wrapped exists [...args]: nothing -> bool {
	(run-gcloud ...$args).exit_code == 0
}

# An expression of the app's CUE, exported with the CUE its own mise pins; null where the app has none.
def cue-of [app: path, expr: string] {
	let r = (do { cd $app; ^$env.SAYT_MISE_BIN exec -- cue export . -e $expr --out json } | complete)
	if $r.exit_code != 0 {
		if ($r.stderr | str contains "not found") or ($r.stderr | str contains "undefined field") or ($r.stderr | str contains "optional field") { return null }
		error make {msg: $"cue export -e ($expr) in ($app): ($r.stderr | str trim)"}
	}
	$r.stdout | from json
}

def live [app: path] {
	let at = (cue-of $app flagsLive)
	if $at == null { error make {msg: $"($app)'s flags_spec.cue names no flagsLive: say `flagsLive: {project: \"…\", bucket: \"…\"}` there"} }
	# `url` is the object's; flagsLive.url, production's address, is `site`.
	$at | upsert site ($at.url? | default null) | upsert testers ($at.testers? | default []) | upsert runAs ($at.runAs? | default null) | upsert alert ($at.alert? | default null) | upsert url $"gs://($at.bucket)/($at.object)"
}

# The live object's generation, or 0 where there is none yet: a push writes only over the one it read.
def generation [url: string] {
	let r = (run-gcloud storage objects describe $url --format "value(generation)")
	if $r.exit_code == 0 { $r.stdout | str trim } else if ($r.stderr | str contains "404") or ($r.stderr | str contains "not found") or ($r.stderr | str contains "No URLs matched") { "0" } else {
		error make {msg: $"gcloud storage objects describe ($url): ($r.stderr | str trim)"}
	}
}

# Who pushed, and from which commit: kept on each version, which history shows.
def provenance [app: path] {
	let who = (gc config get-value account | str trim)
	let commit = (do { cd $app; ^git rev-parse --short HEAD } | complete | get stdout | str trim)
	# Any of the app's CUE: a flag's value may come from another spec (pronto-billing's grants, say).
	let dirty = (do { cd $app; ^git status --porcelain -- '*.cue' } | complete | get stdout | str trim)
	{who: $who, commit: ($commit + (if ($dirty | is-empty) { "" } else { "+edits" }))}
}

# The flags written where else a flagd reads them (flagsLive.mirrors): a release@k8s node's ConfigMap,
# which its flagd mounts (release.cue's services.flagd.files), applied over ssh as the node's kubectl.
# Each write of the live object is written there too: a push, its canary and restore, a rollback.
# A mirror that fails warns and the push goes on (a staging node), unless it is required (production).
def mirror [at: record, text: string] {
	for m in ($at.mirrors? | default []) {
		let key = ($m.key? | default "flags.json")
		let cm = ({apiVersion: v1, kind: ConfigMap, metadata: {name: $m.configMap, namespace: $m.namespace}, data: {$key: $text}} | to json)
		let r = ($cm | ^ssh -o BatchMode=yes -o ConnectTimeout=20 $m.ssh $"($m.kubectl? | default 'sudo k3s kubectl') apply -f -" | complete)
		let where = $"($m.ssh)'s ($m.namespace)/($m.configMap)"
		if $r.exit_code == 0 { print $"flags: mirrored to ($where)" } else if ($m.required? | default false) {
			error make {msg: $"flags: the mirror at ($where) failed: ($r.stderr | str trim)"}
		} else { print -e $"flags: WARNING: the mirror at ($where) failed, so it still serves its last flags: ($r.stderr | str trim)" }
	}
}

# --meta: more of what the version keeps (meta-of); --from: the generation the write is over, when
# an earlier step of the same push read it. The new generation is returned.
def write-flags [at: record, doc: record, app: path, --meta: string = "", --from: string = ""]: nothing -> string {
	if not ($doc.flags? | describe | str starts-with "record") { error make {msg: "flagd.document has no flags"} }
	let from = if $from == "" { generation $at.url } else { $from }
	let file = (mktemp -t --suffix .json)
	$doc | to json --indent 2 | save -f $file
	let p = (provenance $app)
	gc storage cp $file $at.url $"--if-generation-match=($from)" --content-type application/json --cache-control no-store $"--custom-metadata=pushed-by=($p.who),commit=($p.commit)($meta)" | ignore
	rm $file
	mirror $at ($doc | to json --indent 2)
	let now = (generation $at.url)
	print $"flags: ($at.url) is version ($now) \(was ($from)\); flagd reads it within seconds, and a page on its next load"
	summary $doc | print
	$now
}

# The accounts a flag names: its targeting's second test (flags_plugin.cue), where it has one.
# A flag local at hand alone has "default" there, and one with no local value no targeting.
def accounts-of [def: record]: nothing -> list<string> {
	let rule = ($def.targeting? | default null)
	if not ($rule | describe | str starts-with "record") { return [] }
	let branches = ($rule | get -o if)
	if not ($branches | describe | str starts-with "list") { return [] }
	let test = ($branches | get -o 2)
	if not ($test | describe | str starts-with "record") { return [] }
	let names = ($test | get -o in | get -o 1)
	if ($names | describe | str starts-with "list") { $names } else { [] }
}

# The flags a push writes, as a table: each flag's values and the accounts it names.
def summary [doc: record] {
	$doc.flags | transpose flag def | each {|f| {flag: $f.flag, default: $f.def.variants.default, local: ($f.def.variants.local? | default "—"), accounts: (accounts-of $f.def | str join ", ")}}
}

export def show [app: path] {
	let at = (live $app)
	print $"flags: a push writes ($at.url) in ($at.project):"
	summary (cue-of $app flagd.document) | print
}

# The flags as the spec says them, written with no cases: the first push of `setup`.
def push-plain [app: path] {
	write-flags (live $app) (cue-of $app flagd.document) $app | ignore
}

# ---- A flip runs its flag's cases (flags_plugin.cue: flagsCases, flagsLive.testers) ----

# An expression of the CUE package in one of the app's folders (tests/scenarios, tests/unit); null where
# the app has no such folder or the expression is not there.
def cue-dir [app: path, dir: string, expr: string] {
	if not ($app | path join $dir | path exists) { return null }
	let r = (do { cd $app; ^$env.SAYT_MISE_BIN exec -- cue export $"./($dir)" -e $expr --out json } | complete)
	if $r.exit_code != 0 {
		if ($r.stderr | str contains "undefined field") or ($r.stderr | str contains "not found") { return null }
		error make {msg: $"cue export ./($dir) -e ($expr) in ($app): ($r.stderr | str trim)"}
	}
	$r.stdout | from json
}

def entries [r: any]: nothing -> list<any> {
	if ($r == null) or ($r | is-empty) { [] } else { $r | transpose id v | each {|e| $e } }
}

# A flag's default value: the one its default variant holds; null where there is no such flag.
def default-of [def: any] {
	if $def == null { return null }
	$def.variants? | default {} | get -o ($def.defaultVariant? | default "default")
}

# The flags a push changes: new ones, and those whose default value moves. A flag new to the live
# object and off changes nothing: absent already reads as off, so it has no flip to test.
def changed-flags [old: record, doc: record]: nothing -> list<string> {
	$doc.flags | transpose f def | where {|r|
		let was = ($old.flags | get -o $r.f)
		let new = (default-of $r.def)
		if $was == null { $new != false } else { (default-of $was) != $new }
	} | each {|r| $r.f }
}

# A flag's cases: the scenarios (tests/scenarios/*.cue) that name it in `flags` or a step's `flag`,
# which of them are marked `production`, and the unit cases (tests/unit/*.cue) that name it.
def cases-of [app: path, flag: string] {
	let scen = (entries (cue-dir $app tests/scenarios scenarios) | where {|e|
		let named = ($e.v.flags? | default []) | append ($e.v.steps? | default [] | each {|st| $st.flag? | default null } | compact)
		$flag in $named
	})
	let unit = (entries (cue-dir $app tests/unit cases) | where {|e| $flag in ($e.v.flags? | default []) })
	{flag: $flag, scenarios: ($scen | each {|e| $e.id }), production: ($scen | where {|e| ($e.v.production? | default false) == true } | each {|e| $e.id }), unit: ($unit | each {|e| $e.id })}
}
def has-cases [c: record]: nothing -> bool { ($c.scenarios | is-not-empty) or ($c.unit | is-not-empty) }

export def cases [app: path, flag?: string] {
	let names = if $flag != null { [$flag] } else { cue-of $app flagd.document | get flags | columns }
	$names | each {|f| cases-of $app $f }
}

# What a version keeps beyond who and which commit: ",key=value" pairs, which gcloud splits at commas.
def meta-of [m: record]: nothing -> string {
	$m | items {|k, v| $",($k)=($v | into string | str replace -a -r '[,=\n]' ' ')" } | str join
}

# The app's command, run with sh in its folder with the env given; ok and what it printed.
def run-cases [app: path, cmd: string, vars: record] {
	# This tool runs under the plugins tree's saytw, which exports its SAYT_VERSION. The app's own ./saytw
	# must read its own pin: with ours it starts the wrong sayt, which refuses the app's pin.
	let r = (do { cd $app; with-env $vars { ^env -u SAYT_VERSION sh -c $cmd } } | complete)
	{ok: ($r.exit_code == 0), out: ($r.stdout + $r.stderr | str trim)}
}

# A flag's value at hand: its `local` variant where it has one, else its default.
def at-hand [def: record] {
	$def.variants? | default {} | get -o local | default (default-of $def)
}

# Whether the app's tree, as it stands, is one its gate vouches for, and how; null where none does:
# - "main": the app's files are main's (origin/main, with nothing changed, staged or new under the app),
#   which the merge gate keeps green, the trust the scenarios' own selection puts in main (an app's
#   tests/scenarios/select.ts: "the diff trusts main");
# - "ledger": the tree passed its gate on this machine, the ledger release@gcp reads (pronto's
#   gcp/local-gate-key.nu, under the pronto the app pins), stamped by integrate@local with every driver
#   and by a rehearsal.
# FLAGS_GATED_CMD stands in for it in tests: an sh command, run in the app's folder, printing main,
# ledger or nothing.
def gated [app: path]: nothing -> any {
	let cmd = ($env.FLAGS_GATED_CMD? | default "")
	if $cmd != "" { let w = (do { cd $app; ^sh -c $cmd } | complete | get stdout | str trim); return (if $w == "" { null } else { $w }) }
	# main's: HEAD is a commit of main's own line (a merge the gate let in; first parents, the last 2000),
	# and nothing under the app differs from it.
	let head = (do { cd $app; ^git rev-parse HEAD } | complete | get stdout | str trim)
	let line = (do { cd $app; ^git rev-list --first-parent -n 2000 origin/main } | complete)
	let loose = (do { cd $app; ^git status --porcelain --untracked-files=all -- . } | complete)
	if $head != "" and $line.exit_code == 0 and $head in ($line.stdout | lines) and $loose.exit_code == 0 and ($loose.stdout | str trim | is-empty) { return "main" }
	let rt = (do { cd $app; ^$env.SAYT_MISE_BIN where github:bonisoft3/pronto } | complete)
	if $rt.exit_code != 0 { return null }
	let script = ($rt.stdout | str trim | path join gcp local-gate-key.nu)
	if not ($script | path exists) { return null }
	let r = (do { cd $app; ^$env.SAYT_MISE_BIN exec -- nu $script passed . } | complete)
	if $r.exit_code == 0 and ($r.stdout | str trim) == "true" { "ledger" } else { null }
}

# The live document with each flag in `flags` at its old value for everyone and its new one for the
# testers: variants {old, new} beside the ones it had, and the testers' test first in its targeting.
def canary-doc [old: record, doc: record, flags: list<string>, testers: list<string>]: nothing -> record {
	$flags | reduce -f $old {|f, acc|
		let o = ($old.flags | get -o $f | default {})
		let new = (default-of ($doc.flags | get $f))
		# A flag the live object doesn't have yet reads as off, or as itself where it isn't a bool.
		let was = if ($o | is-empty) { if ($new | describe) == "bool" { false } else { $new } } else { default-of $o }
		let rest = if ($o.targeting? | describe | str starts-with "record") { $o.targeting } else { "old" }
		let def = {
			state: "ENABLED"
			variants: (($o.variants? | default {}) | merge {old: $was, new: $new})
			defaultVariant: ($o.defaultVariant? | default "old")
			targeting: {"if": [{"in": [{"var": "targetingKey"}, $testers]}, "new", $rest]}
		}
		$acc | upsert flags ($acc.flags | upsert $f $def)
	}
}

# What OFREP at `site` answers for a flag and a targetingKey (none: no context); null where it doesn't answer.
# FLAGS_OFREP_CMD stands in for the request in tests: an sh command printing the reply, given
# OFREP_URL, FLAG and TARGETING_KEY.
def ofrep-ask [site: string, flag: string, key: any] {
	let cmd = ($env.FLAGS_OFREP_CMD? | default "")
	try {
		if $cmd != "" {
			let r = (with-env {OFREP_URL: $site, FLAG: $flag, TARGETING_KEY: ($key | default "")} { ^sh -c $cmd } | from json)
			$r.value?
		} else {
			let ctx = if $key == null { {} } else { {targetingKey: $key} }
			(http post --content-type application/json --max-time 10sec $"($site)/ofrep/v1/evaluate/flags/($flag)" {context: $ctx}).value?
		}
	} catch { null }
}

# Waits until OFREP answers each flag's new value for the tester and its old one with no context: polls
# every FLAGS_POLL_SEC (2), gives up at FLAGS_WAIT_SEC (90). Whether it did.
def wait-ofrep [site: string, tester: string, want: list<record>]: nothing -> bool {
	let poll = ($env.FLAGS_POLL_SEC? | default 2 | into float)
	let limit = ($env.FLAGS_WAIT_SEC? | default 90 | into float)
	mut waited = 0.0
	loop {
		let ok = ($want | all {|w| (ofrep-ask $site $w.flag $tester) == $w.new and (ofrep-ask $site $w.flag null) == $w.old })
		if $ok { return true }
		if $waited >= $limit { return false }
		sleep ($poll * 1sec)
		$waited = $waited + $poll
	}
	false
}

# The version a push read, written again as the newest after a failed live stage.
def restore [at: record, app: path, to: string, now: string, names: string, why: string] {
	let p = (provenance $app)
	gc storage cp $"($at.url)#($to)" $at.url $"--if-generation-match=($now)" $"--custom-metadata=pushed-by=($p.who)(meta-of {stage: rolled-back, flag: $names, cases: failed, note: $why})" | ignore
	mirror $at (gc storage cat $at.url)
	print -e $"flags: ($at.url) is version ($to)'s flags again, as version (generation $at.url)"
}

# Changes the live flags. A flag whose default value changes (or that is new) goes through its cases:
#   1. it needs cases (`cases`); with none the push is refused, or goes on with --untested "<why>";
#   2. at hand, flagsCases.local runs them with the settings a release has; a failure stops, nothing written;
#   3. the flag is written on for flagsLive.testers alone, everyone else keeping the old value (stage=testers),
#      and the push waits until OFREP at flagsLive.url says so;
#   4. flagsCases.live runs the flag's `production` scenarios against production as the tester; a failure
#      writes the version read in 3 again, and the push fails;
#   5. the flags as the spec says them are written (stage=all, cases=passed).
# --skip-live "<why>" leaves out 3 and 4, for an app with no testers yet. Both reasons are kept on the version.
export def push [app: path, --untested: string, --skip-live: string] {
	let at = (live $app)
	let doc = (cue-of $app flagd.document)
	let before = (generation $at.url)
	let old = if $before == "0" { {flags: {}} } else { gc storage cat $at.url | from json }
	let changed = (changed-flags $old $doc)
	if ($changed | is-empty) {
		write-flags $at $doc $app --meta (meta-of {stage: all}) --from $before | ignore
		return
	}
	let all = ($changed | each {|f| cases-of $app $f })
	let bare = ($all | where {|c| not (has-cases $c) } | each {|c| $c.flag })
	let tested = ($all | where {|c| has-cases $c })
	if ($bare | is-not-empty) and $untested == null {
		error make {msg: $"a push changes ($bare | str join ', '), which has no cases: name the flag in a scenario's or a unit case's `flags` (tests/scenarios/*.cue, tests/unit/*.cue; `pronto-flags cases` lists them), or push with --untested \"<why>\""}
	}
	let cmds = (cue-of $app flagsCases | default {})
	let testers = $at.testers
	if ($tested | is-not-empty) {
		if ($cmds.local? | default "" | is-empty) { error make {msg: $"($app) names no flagsCases.local: the command that runs a flag's cases at hand"} }
		if $skip_live == null {
			if ($at.site | is-empty) or ($testers | is-empty) or ($cmds.live? | default "" | is-empty) {
				error make {msg: "a flip runs its cases on production as a tester: say flagsLive.url, flagsLive.testers and flagsCases.live, or push with --skip-live \"<why>\""}
			}
			if ($at.runAs? | default "" | is-empty) {
				error make {msg: "the tester's credential is the release identity's, not the operator's: say flagsLive.runAs (a service account the operator may impersonate), or push with --skip-live \"<why>\""}
			}
			let none = ($tested | where {|c| $c.production | is-empty } | each {|c| $c.flag })
			if ($none | is-not-empty) { error make {msg: $"($none | str join ', ') has no `production` scenario to run on production: mark one, or push with --skip-live \"<why>\""} }
		}
	}
	let names = ($changed | str join "+")
	let notes = ([(if $untested != null { $"untested: ($untested)" }), (if $skip_live != null { $"skip-live: ($skip_live)" })] | compact | str join "; ")
	if $untested != null and ($bare | is-not-empty) { print -e $"flags: WARNING: ($bare | str join ', ') pushed with NO CASES: ($untested)" }
	if $skip_live != null and ($tested | is-not-empty) { print -e $"flags: WARNING: ($tested | each {|c| $c.flag } | str join ', ') not tried on production: ($skip_live)" }

	# A flip builds no stack. Where a gate vouches for the tree (gated), and each flag reads at hand the value
	# it is flipped to, that gate ran the flag's cases with that value: they are not run again. Otherwise the
	# app's flagsCases.local runs them, against a stack already up or none (its contract: it builds none).
	let same = ($tested | all {|c| let d = ($doc.flags | get $c.flag); (at-hand $d) == (default-of $d) })
	let by = if ($tested | is-not-empty) and $same { gated $app } else { null }
	let passed = $by != null
	if $passed {
		let why = if $by == "main" { "the app's files are main's, which the merge gate keeps green" } else { "this tree passed its gate on this machine" }
		print $"flags: ($tested | each {|c| $c.flag } | str join ', '): ($why), with the new value at hand; its cases are not run again"
	} else {
		for c in ($tested) {
			print $"flags: ($c.flag): running its cases at hand \(($c.scenarios | length) scenarios, ($c.unit | length) unit cases\)"
			let r = (run-cases $app $cmds.local {FLAG: $c.flag, ONLY: ($c.scenarios | str join ","), UNIT_ONLY: ($c.unit | str join ","), SLOW: "1"})
			if not $r.ok { error make {msg: $"($c.flag)'s cases failed at hand; nothing was written:\n($r.out)"} }
		}
	}
	let verdict = if ($tested | is-empty) { "untested" } else if $skip_live != null { if $passed { "gated" } else { "local-only" } } else { "passed" }
	let notes = ([$notes (if $passed { $"at hand: the gate \(($by)\)" } else { "" })] | where {|n| $n != "" } | str join "; ")
	if $skip_live != null or ($tested | is-empty) {
		write-flags $at $doc $app --meta (meta-of {stage: all, flag: $names, cases: $verdict, note: $notes}) --from $before | ignore
		return
	}

	let on = ($tested | each {|c| $c.flag })
	let final = {stage: all, flag: $names, cases: $verdict, note: $notes}
	# The alert that fires on a tester's sign-in is snoozed for exactly the live stage, however it ends.
	let snooze = (snooze-start $at $on)
	try {
		flip-live $at $app $old $doc $on $tested $cmds $before $final
	} finally {
		snooze-end $at $snooze
	}
}

# Cloud Monitoring's snooze of flagsLive.alert, for the live stage of a flip: a name to end it by, or null where
# the app names no alert. The snooze ends on its own after two hours should the push never end it.
def snooze-start [at: record, flags: list<string>] {
	if ($at.alert? | default "" | is-empty) { return null }
	let from = (date now | date to-timezone utc)
	let name = (gc monitoring snoozes create --project $at.project --display-name $"pronto-flags flip: ($flags | str join ' ')" --criteria-policies $at.alert --start-time ($from | format date "%Y-%m-%dT%H:%M:%SZ") --end-time ($from + 2hr | format date "%Y-%m-%dT%H:%M:%SZ") --format "value(name)" | str trim)
	print $"flags: ($at.alert) is snoozed for the live stage \(($name)\)"
	$name
}
def snooze-end [at: record, name: any] {
	if $name == null { return }
	try {
		gc monitoring snoozes update $name --project $at.project --end-time (date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ") | ignore
		print $"flags: ($at.alert) is no longer snoozed"
	} catch {|e| print -e $"flags: WARNING: could not end the snooze ($name) of ($at.alert); it ends by itself within two hours: ($e.msg)" }
}

# The live stage: the canary (the flags on for the testers alone), OFREP's word, the production cases, then the
# final version. Whatever fails after the canary was written, an error or a crash of the cases' command, writes the
# version read before it again: the testers are named in no version that outlives the run.
def flip-live [at: record, app: path, old: record, doc: record, on: list<string>, tested: list<record>, cmds: record, before: string, final: record] {
	let testers = $at.testers
	let canary = (write-flags $at (canary-doc $old $doc $on $testers) $app --meta (meta-of {stage: testers, flag: ($on | str join "+"), cases: running}) --from $before)
	print $"flags: ($on | str join ', ') is on for ($testers | str join ', ') alone; waiting for ($at.site) to say so"
	try {
		let want = ($on | each {|f| {flag: $f, new: (default-of ($doc.flags | get $f)), old: (canary-doc $old $doc [$f] $testers | get flags | get $f | get variants.old)} })
		if not (wait-ofrep $at.site $testers.0 $want) {
			error make {msg: $"($at.site) did not answer the new value for ($testers.0) within the wait"}
		}
		for c in $tested {
			print $"flags: ($c.flag): running its production cases as ($testers.0) \(($c.production | str join ', ')\)"
			let r = (run-cases $app $cmds.live {FLAG: $c.flag, ONLY: ($c.production | str join ","), APP_URL: $at.site, FLAGS_TESTER: $testers.0, CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT: $at.runAs})
			if not $r.ok { error make {msg: $"($c.flag)'s production cases failed:\n($r.out)"} }
		}
		write-flags $at $doc $app --meta (meta-of $final) --from $canary | ignore
	} catch {|e|
		try { restore $at $app $before $canary ($on | str join "+") ($e.msg | lines | first) } catch {|r| print -e $"flags: WARNING: could not restore version ($before) over the canary: ($r.msg); `pronto-flags rollback` does" }
		error make {msg: $"rolled back to version ($before): ($e.msg)"}
	}
}

# Every version of the object, newest first: `gcloud storage ls -a --json` gives each
# its generation, when it was written, when a newer one replaced it, and what push kept on it.
export def history [app: path] {
	let at = (live $app)
	gc storage ls -a --json $at.url | from json | get metadata
	| each {|o| {version: $o.generation, at: $o.timeCreated, live: ($o.timeDeleted? == null), by: ($o.metadata?.pushed-by? | default ""), commit: ($o.metadata?.commit? | default ""), stage: ($o.metadata?.stage? | default ""), flag: ($o.metadata?.flag? | default ""), cases: ($o.metadata?.cases? | default ""), note: ($o.metadata?.note? | default "")}}
	| sort-by {|v| $v.version | into int } --reverse
}

# The version before the live one, or the one named, written again as the newest:
# a rollback is itself a version, which a rollback undoes.
export def rollback [app: path, version?: string] {
	let at = (live $app)
	let all = (history $app)
	let live = ($all | where live | get version.0? | default "")
	let to = if $version != null { $version } else { $all | where version != $live | get version.0? }
	if $to == null or ($all | where version == $to | is-empty) { error make {msg: $"no version ($to) of ($at.url) to roll back to: `pronto-flags history` lists them"} }
	gc storage cp $"($at.url)#($to)" $at.url $"--if-generation-match=($live)" | ignore
	mirror $at (gc storage cat $at.url)
	print $"flags: ($at.url) is ($to)'s flags again, as version (generation $at.url)"
}

# Once per app: the bucket, versioned and private, keeping the last 50 versions;
# the app's run and preview accounts as its readers, since flagd reads it as the
# service it runs in; and the first push, which flagd needs before a release
# names the object (flagd stops at start on a source it cannot read).
export def setup [app: path] {
	let at = (live $app)
	let bucket = $"gs://($at.bucket)"
	if not (exists storage buckets describe $bucket --project $at.project) {
		let region = (cue-of $app GCP.region | default "us-central1")
		gc storage buckets create $bucket --project $at.project --location $region --uniform-bucket-level-access --public-access-prevention | ignore
	}
	gc storage buckets update $bucket --versioning | ignore
	let rules = (mktemp -t --suffix .json)
	{rule: [{action: {type: "Delete"}, condition: {isLive: false, numNewerVersions: 50}}]} | to json | save -f $rules
	gc storage buckets update $bucket $"--lifecycle-file=($rules)" | ignore
	rm $rules
	let gcp = (cue-of $app GCP)
	let readers = if $gcp == null { [] } else {
		[$"($gcp.name)-run@($gcp.project).iam.gserviceaccount.com"]
		| append (if ($gcp.previewProject? | default "" | is-empty) { [] } else { [$"($gcp.name)-preview@($gcp.previewProject).iam.gserviceaccount.com"] })
	}
	for r in $readers {
		gc storage buckets add-iam-policy-binding $bucket --member $"serviceAccount:($r)" --role roles/storage.objectViewer | ignore
		print $"flags: ($r) reads ($bucket)"
	}
	if (generation $at.url) == "0" { push-plain $app } else { print $"flags: ($at.url) is there already; `pronto-flags push` changes it" }
}

def main [] { print "usage: live.nu setup|push|history|rollback|show|cases <app-dir> [version|flag]" }
def "main setup" [app: path] { setup $app }
def "main push" [app: path, --untested: string, --skip-live: string] { push $app --untested $untested --skip-live $skip_live }
def "main history" [app: path] { history $app | table -e | print }
def "main rollback" [app: path, version?: string] { rollback $app $version }
def "main show" [app: path] { show $app }
def "main cases" [app: path, flag?: string] { cases $app $flag | table -e | print }
