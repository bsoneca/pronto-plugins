# The released app's live flags: one object in a versioned Cloud Storage bucket,
# which the app's flagd reads (FLAGD_SOURCES, release.cue) and polls, so a flag
# changes with a push and never a deploy. The app's flagsLive (flags_spec.cue)
# names the bucket and its project; its flags are flagd.document, exported from
# the app's CUE as generate writes flags/flags.json. Every push is a version of
# the object, kept: the history, and what a rollback restores.
# Where flagsLive says `dir` instead of a bucket, the same store is a local directory (see
# "The store"): a drill or a laptop, with no gcloud.
#   bin/pronto-flags setup <app-dir>               # the bucket, its readers, the first push
#   bin/pronto-flags push <app-dir>                # the flags as flags_spec.cue says them now, once their cases pass
#   bin/pronto-flags cases <app-dir> [flag]        # the cases a flip of each flag (or the one) runs
#   bin/pronto-flags history <app-dir> [--json]    # every version, newest first
#   bin/pronto-flags rollback <app-dir> [version]  # the version before the live one, or the one named
#   bin/pronto-flags show <app-dir>                # what a push would write, and where: nothing written
# Each runs as the operator's own gcloud login.
# Every write (setup, push, rollback) prints its target first and takes --expect <url> (or PRONTO_FLAGS_EXPECT):
# a target that differs is refused with nothing written. With PRONTO_FLAGS_DRY_RUN set a write shows what it
# would write and stops, as --dry-run does; a write reached anyway is refused where it happens. Each write is also appended to a journal (see `journal`).
# A push that changes a flag's default value runs that flag's cases first (see `push`).

# A dry run (--dry-run, or PRONTO_FLAGS_DRY_RUN) writes nothing, enforced where each write happens, not only
# at the top of a command: the gcloud call (only the reads below go through), the ssh mirror and the directory
# store each refuse under it. So a dry run reaching a write by any path fails instead of writing (2026-11-07: a
# "dry run" that stood gcloud in through SAYT_MISE_BIN, which ./saytw replaced, wrote the live bucket).
def dry []: nothing -> bool { not (($env.PRONTO_FLAGS_DRY_RUN? | default "") in ["" "0"]) }
def refuse-write [what: string] {
	if (dry) { error make {msg: $"flags: dry run: refused a write \(($what)\); nothing was written"} }
}
const gcloud_reads = [["config" "get-value"] ["storage" "objects" "describe"] ["storage" "cat"] ["storage" "ls"] ["storage" "buckets" "describe"]]

# gcloud on the Python pinned beside it, never on the virtualenv it shares with every other gcloud
# on the machine (~/.config/gcloud/virtenv): another gcloud rebuilds that on its own Python, and a
# Python this gcloud predates crashes it (3.14: "module 'ssl' has no attribute 'PROTOCOL_TLSv1'").
export def --wrapped run-gcloud [...args] {
	let input = $in
	if (dry) and not ($gcloud_reads | any {|r| ($args | take ($r | length)) == $r }) { refuse-write $"gcloud ($args | take 3 | str join ' ')" }
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
	let at = ($at | upsert site ($at.url? | default null) | upsert testers ($at.testers? | default []) | upsert runAs ($at.runAs? | default null) | upsert alert ($at.alert? | default null))
	if ($at.dir? | default null) != null {
		if ($at.bucket? | default null) != null { error make {msg: $"($app)'s flagsLive names both a bucket and a dir: say one"} }
		let dir = if ($at.dir | str starts-with "/") { $at.dir | path expand } else { $app | path expand | path join $at.dir | path expand }
		return ($at | upsert dir $dir | upsert url $"file://($dir)/flags.json")
	}
	if ($at.bucket? | default null) == null or ($at.project? | default null) == null { error make {msg: $"($app)'s flagsLive names no bucket and project, nor a dir"} }
	$at | upsert url $"gs://($at.bucket)/($at.object)"
}

# ---- The store: the live flags and every version of them, in a bucket or in a directory ----
# A bucket is a versioned Cloud Storage object. A directory (flagsLive.dir) keeps the same things as files:
# the live document at <dir>/flags.json, written whole by a rename so that a flagd watching the file never
# reads half of one, and each version beside it, <dir>/versions/<generation>.json with its
# <generation>.meta.json (the generation, when it was written, when a newer one replaced it, and what the
# write kept: who, commit, stage, flag, cases, note). Generations are increasing integers, 0 where there is
# no object yet. A write names the generation it read and is refused when it is no longer the live one.

def is-dir [at: record]: nothing -> bool { ($at.dir? | default null) != null }

def now-utc []: nothing -> string { date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ" }

# Every version's record, oldest first: generation, timeCreated, timeDeleted (null while live), metadata.
def dir-versions [at: record]: nothing -> list<record> {
	let vdir = ($at.dir | path join versions)
	if not ($vdir | path exists) { return [] }
	glob $"($vdir)/*.meta.json" | each {|f| open --raw $f | from json } | sort-by {|v| $v.generation | into int }
}

# The live object's generation, or 0 where there is none yet: a push writes only over the one it read.
def generation [at: record] {
	if (is-dir $at) {
		return ("0" | append (dir-versions $at | where {|v| $v.timeDeleted? == null } | get generation) | last)
	}
	let r = (run-gcloud storage objects describe $at.url --format "value(generation)")
	if $r.exit_code == 0 { $r.stdout | str trim } else if ($r.stderr | str contains "404") or ($r.stderr | str contains "not found") or ($r.stderr | str contains "No URLs matched") { "0" } else {
		error make {msg: $"gcloud storage objects describe ($at.url): ($r.stderr | str trim)"}
	}
}

# The live document's text, or that of one version.
def store-cat [at: record]: nothing -> string {
	if (is-dir $at) { open --raw ($at.dir | path join flags.json) } else { gc storage cat $at.url }
}
def store-version [at: record, gen: string]: nothing -> string {
	if (is-dir $at) {
		let f = ($at.dir | path join versions $"($gen).json")
		if not ($f | path exists) { error make {msg: $"($at.url) has no version ($gen)"} }
		open --raw $f
	} else { gc storage cat $"($at.url)#($gen)" }
}

# Every version: generation, timeCreated, timeDeleted (null while live), metadata.
def store-versions [at: record]: nothing -> list<record> {
	if (is-dir $at) { return (dir-versions $at) }
	gc storage ls -a --json $at.url | from json | get metadata
	| each {|o| {generation: $o.generation, timeCreated: $o.timeCreated, timeDeleted: ($o.timeDeleted? | default null), metadata: ($o.metadata? | default {})} }
}

# What a version keeps, as gcloud's --custom-metadata takes it: key=value pairs split at commas.
def meta-str [m: record]: nothing -> string {
	$m | items {|k, v| $"($k)=($v | into string | str replace -a -r '[,=\n]' ' ')" } | str join ","
}

# Writes text as the new live version, over the generation `from` and no other, and returns the new generation.
export def store-put [at: record, text: string, meta: record, from: string]: nothing -> string {
	refuse-write $"the live flags at ($at.url)"
	if not (is-dir $at) {
		let file = (mktemp -t --suffix .json)
		$text | save -f $file
		gc storage cp $file $at.url $"--if-generation-match=($from)" --content-type application/json --cache-control no-store $"--custom-metadata=(meta-str $meta)" | ignore
		rm $file
		return (generation $at)
	}
	let now = (generation $at)
	if $from != $now { error make {msg: $"($at.url): 412 Precondition Failed: the live version is ($now), not ($from)"} }
	let known = (dir-versions $at | get generation | each {|g| $g | into int })
	let gen = ([((date now | into int) // 1000) (($known | append 0 | math max) + 1)] | math max | into string)
	let stamp = (now-utc)
	let vdir = ($at.dir | path join versions)
	mkdir $vdir
	$text | save -f ($vdir | path join $"($gen).json")
	{generation: $gen, timeCreated: $stamp, timeDeleted: null, metadata: $meta} | to json --indent 2 | save -f ($vdir | path join $"($gen).meta.json")
	if $now != "0" {
		let old = ($vdir | path join $"($now).meta.json")
		open --raw $old | from json | upsert timeDeleted $stamp | to json --indent 2 | save -f $old
	}
	let tmp = ($at.dir | path join $".flags.json.($gen).tmp")
	$text | save -f $tmp
	mv -f $tmp ($at.dir | path join flags.json)
	$gen
}

# Who pushed, and from which commit: kept on each version, which history shows. A directory store
# needs no gcloud: the account where one is installed, else the login name.
def provenance [app: path, at: record] {
	let who = if (is-dir $at) {
		let a = if (which gcloud | is-empty) { "" } else { do { ^gcloud config get-value account } | complete | get stdout | str trim }
		if $a == "" { $env.USER? | default (^whoami | str trim) } else { $a }
	} else { gc config get-value account | str trim }
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
		refuse-write $"the mirror at ($m.ssh)"
		let key = ($m.key? | default "flags.json")
		let cm = ({apiVersion: v1, kind: ConfigMap, metadata: {name: $m.configMap, namespace: $m.namespace}, data: {$key: $text}} | to json)
		let r = ($cm | ^ssh -o BatchMode=yes -o ConnectTimeout=20 $m.ssh $"($m.kubectl? | default 'sudo k3s kubectl') apply -f -" | complete)
		let where = $"($m.ssh)'s ($m.namespace)/($m.configMap)"
		if $r.exit_code == 0 { print $"flags: mirrored to ($where)" } else if ($m.required? | default false) {
			error make {msg: $"flags: the mirror at ($where) failed: ($r.stderr | str trim)"}
		} else { print -e $"flags: WARNING: the mirror at ($where) failed, so it still serves its last flags: ($r.stderr | str trim)" }
	}
}

# The flags written to the app's database too (flagsLive.database, a command that runs SQL on its stdin there),
# through pronto_flags.put() (flags_plugin.cue's flagd.sql), with the host the document is served at (flagsLive.url's),
# so the database's pronto_flags.flag_on() answers as flagd does. A write that fails there fails the push.
def database [at: record, app: path, text: string] {
	let cmd = ($at.database? | default "")
	if ($cmd | is-empty) { print "flags: no flagsLive.database, so no database holds these flags"; return }
	refuse-write $"the database through ($cmd)"
	let host = if ($at.site? | default "" | is-empty) { "" } else { $at.site | url parse | get host }
	let sql = $"SELECT pronto_flags.put\('(sq ($text | from json | to json -r))'::jsonb, '(sq $host)'\);\n"
	let r = (do { cd $app; $sql | ^sh -c $cmd } | complete)
	if $r.exit_code != 0 { error make {msg: $"flags: the database write through ($cmd) failed: ($r.stderr | str trim)"} }
	print $"flags: written to the database through ($cmd), host ($host)"
}

# The flags that differ between two documents, by their default value: {flag, from, to}. A flag the other
# document lacks reads as off where the one that has it is a bool (as the live object does), so a new flag
# that is off changes nothing.
def changes-between [old: record, new: record]: nothing -> list<record> {
	let a = ($old.flags? | default {})
	let b = ($new.flags? | default {})
	($a | columns) | append ($b | columns) | uniq | each {|f|
		let was = (default-of ($a | get -o $f))
		let now = (default-of ($b | get -o $f))
		let was = if $was == null and (($now | describe) == "bool") { false } else { $was }
		let now = if $now == null and (($was | describe) == "bool") { false } else { $now }
		{flag: $f, from: $was, to: $now}
	} | where {|c| $c.from != $c.to }
}

# The flags whose definition differs between two documents in anything but its default value.
def defs-between [old: record, new: record]: nothing -> list<string> {
	let a = ($old.flags? | default {})
	let b = ($new.flags? | default {})
	($a | columns) | append ($b | columns) | uniq | where {|f|
		let x = ($a | get -o $f)
		let y = ($b | get -o $f)
		$x != null and $y != null and (($x | reject -o variants) != ($y | reject -o variants) or ($x.variants? | default {} | reject -o default) != ($y.variants? | default {} | reject -o default))
	}
}

# Where a write is noted: one JSON line per write, in the operator's state (PRONTO_FLAGS_JOURNAL names the file).
export def journal-file [app: path]: nothing -> string {
	let named = ($env.PRONTO_FLAGS_JOURNAL? | default "")
	if $named != "" { return $named }
	let state = ($env.XDG_STATE_HOME? | default "")
	let root = if $state == "" { $env.HOME? | default $nu.home-dir | path join .local state } else { $state }
	$root | path join pronto-flags $"($app | path expand | path basename).jsonl"
}

# Every write of the live flags goes through here: it reads the version it replaces, writes the new text over
# that generation, mirrors it, and notes it in the journal (printed too). --derive-flag: the version's `flag`
# is the flags whose default moved, where its metadata names none (a rollback). The new generation is returned.
def commit [at: record, app: path, text: string, meta: record, from: string, --derive-flag]: nothing -> string {
	let old = if $from == "0" { {flags: {}} } else { try { store-version $at $from | from json } catch { null } }
	let changes = if $old == null { [] } else { changes-between $old ($text | from json) }
	# The flags named: those whose default moved, and those whose definition changed otherwise (targeting, variants,
	# state): a rollout widened to everyone breaks things without its default moving.
	let names = if $old == null { "" } else { ($changes | each {|c| $c.flag }) | append (defs-between $old ($text | from json)) | uniq | str join "+" }
	let meta = if $derive_flag and ($meta.flag? | default "" | is-empty) and $names != "" { $meta | upsert flag $names } else { $meta }
	let p = (provenance $app $at)
	let gen = (store-put $at $text ({pushed-by: $p.who, commit: $p.commit} | merge $meta) $from)
	mirror $at $text
	database $at $app $text
	let line = {
		at: (now-utc), event: "flags.write", app: ($app | path expand | path basename), target: $at.url, version: $gen, from: $from
		stage: ($meta.stage? | default ""), flag: (if $names != "" { $names } else { $meta.flag? | default "" }), who: $p.who, commit: $p.commit
		cases: ($meta.cases? | default ""), note: ($meta.note? | default ""), changes: $changes
	} | to json -r
	# The flags are written by now: a journal that cannot be written warns and never fails the write.
	let file = (journal-file $app)
	try { mkdir ($file | path dirname); $"($line)\n" | save -a $file } catch {|e| print -e $"flags: WARNING: could not note the write in ($file): ($e.msg)" }
	print $"flags: journal ($line)"
	$gen
}

# Before a write: the target is said, and refused when it is not the one the operator expected
# (--expect, else PRONTO_FLAGS_EXPECT). Whether the write is only a dry run (PRONTO_FLAGS_DRY_RUN) is returned.
def target-guard [at: record, expect: any]: nothing -> bool {
	print $"flags: target ($at.url)"
	let want = if $expect != null { $expect } else { $env.PRONTO_FLAGS_EXPECT? | default "" }
	if $want != "" and $want != $at.url { error make {msg: $"flags: the target is ($at.url), not the expected ($want); nothing was written"} }
	not (($env.PRONTO_FLAGS_DRY_RUN? | default "") in ["" "0"])
}

# --meta: more of what the version keeps; --from: the generation the write is over, when
# an earlier step of the same push read it. The new generation is returned.
def write-flags [at: record, doc: record, app: path, --meta: record = {}, --from: string = ""]: nothing -> string {
	if not ($doc.flags? | describe | str starts-with "record") { error make {msg: "flagd.document has no flags"} }
	let from = if $from == "" { generation $at } else { $from }
	let now = (commit $at $app ($doc | to json --indent 2) $meta $from)
	print $"flags: ($at.url) is version ($now) \(was ($from)\); flagd reads it within seconds, and a page on its next load"
	# Written: what is said of it never fails the push, whose caller holds the version to roll back from.
	try { summary $doc | print } catch {|e| print -e $"flags: WARNING: no summary of version ($now): ($e.msg | lines | first)" }
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

# The flags a push writes, as a table: each flag's values and the accounts it names. A flag's default is the
# value its default variant holds: a canary's is `old`, with no `default` variant for a flag new to the live
# object (2026-11-08 18:02 BRT, trial_banner: the push failed past its testers write, PRONTO-43).
def summary [doc: record] {
	$doc.flags | transpose flag def | each {|f| {flag: $f.flag, default: (default-of $f.def), local: ($f.def.variants.local? | default "—"), accounts: (accounts-of $f.def | str join ", ")}}
}

export def show [app: path] {
	let at = (live $app)
	print $"flags: a push writes ($at.url) in ($at.project? | default 'a local directory'):"
	summary (cue-of $app flagd.document) | print
}

# The flags as the spec says them, written with no cases: the first push of `setup`.
def push-plain [app: path] {
	write-flags (live $app) (cue-of $app flagd.document) $app --meta {stage: all, note: "first push"} | ignore
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

# The app's command, run with sh in its folder with the env given; ok and what it printed.
def run-cases [app: path, cmd: string, vars: record] {
	# This tool runs under the plugins tree's saytw, which exports its SAYT_VERSION. The app's own ./saytw
	# must read its own pin: with ours it starts the wrong sayt, which refuses the app's pin.
	let r = (do { cd $app; with-env $vars { ^env -u SAYT_VERSION sh -c $cmd } } | complete)
	{ok: ($r.exit_code == 0), out: ($r.stdout + $r.stderr | str trim)}
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
	let again = (commit $at $app (store-version $at $to) {stage: rolled-back, flag: $names, cases: failed, note: $why} $now)
	print -e $"flags: ($at.url) is version ($to)'s flags again, as version ($again)"
}

# Changes the live flags. A flag whose default value changes (or that is new) goes through its cases, on
# production as the tester (the user, 2026-11-07: "Test cases run against production to that user"; a flip
# builds and launches no stack, and runs nothing at hand: the pull request's gate ran the flag's cases with
# it on, every flag being on at hand):
#   1. it needs cases (`cases`); with none the push is refused, or goes on with --untested "<why>";
#   2. it needs what the live stage needs: flagsLive.url, testers and runAs, flagsCases.live, and a `production`
#      scenario of its own; with any missing the push is refused, nothing written;
#   3. the flag is written on for flagsLive.testers alone, everyone else keeping the old value (stage=testers),
#      and the push waits until OFREP at flagsLive.url says so;
#   4. flagsCases.live runs the flag's `production` scenarios against production as the tester; a failure
#      writes the version read in 3 again, and the push fails;
#   5. the flags as the spec says them are written (stage=all, cases=passed).
# A flag turned off (default now false) skips 1-4: it returns to the path before it, and its cases test it on.
export def push [app: path, --untested: string, --expect: string] {
	let at = (live $app)
	if (target-guard $at $expect) { show $app; print "flags: dry run: nothing written"; return }
	let doc = (cue-of $app flagd.document)
	let before = (generation $at)
	let old = if $before == "0" { {flags: {}} } else { store-cat $at | from json }
	let changed = (changed-flags $old $doc)
	if ($changed | is-empty) {
		write-flags $at $doc $app --meta {stage: all} --from $before | ignore
		return
	}
	# A flag turned off (its default now false) returns to the path the app ran before it went on; its
	# cases test it on, so they cannot pass on the tester with it off (2026-11-08, card_chess: the user's
	# "Rollback card game"). It goes to everyone with no cases, and the journal says so.
	let off = ($changed | where {|f| (default-of ($doc.flags | get $f)) == false })
	if ($off | is-not-empty) { print -e $"flags: ($off | str join ', ') turned off: no cases run \(they test the flag on\)" }
	let all = ($changed | where {|f| $f not-in $off } | each {|f| cases-of $app $f })
	let bare = ($all | where {|c| not (has-cases $c) } | each {|c| $c.flag })
	let tested = ($all | where {|c| has-cases $c })
	if ($bare | is-not-empty) and $untested == null {
		error make {msg: $"a push changes ($bare | str join ', '), which has no cases: name the flag in a scenario's `flags` and mark it `production` (tests/scenarios/*.cue; `pronto-flags cases` lists them), or push with --untested \"<why>\""}
	}
	let cmds = (cue-of $app flagsCases | default {})
	let testers = $at.testers
	if ($tested | is-not-empty) {
		if ($at.site | is-empty) or ($testers | is-empty) or ($cmds.live? | default "" | is-empty) {
			error make {msg: "a flip runs its cases on production as a tester: say flagsLive.url, flagsLive.testers and flagsCases.live (the tester is made once, by the operator: the app's tests/tester.ts)"}
		}
		if ($at.runAs? | default "" | is-empty) {
			error make {msg: "the tester's credential is the release identity's, not the operator's: say flagsLive.runAs (a service account the operator may impersonate)"}
		}
		let none = ($tested | where {|c| $c.production | is-empty } | each {|c| $c.flag })
		if ($none | is-not-empty) { error make {msg: $"($none | str join ', ') has no `production` scenario to run on production as the tester: mark one \(production: true, tests/scenarios/schema.cue\)"} }
	}
	let names = ($changed | str join "+")
	let notes = ([(if $untested != null { $"untested: ($untested)" }) (if ($off | is-not-empty) { $"turned off: ($off | str join ', ')" })] | compact | str join "; ")
	if $untested != null and ($bare | is-not-empty) { print -e $"flags: WARNING: ($bare | str join ', ') pushed with NO CASES: ($untested)" }
	if ($tested | is-empty) {
		write-flags $at $doc $app --meta {stage: all, flag: $names, cases: untested, note: $notes} --from $before | ignore
		tell-board $at $app ($changed | where {|f| $f not-in $off }) $off
		return
	}

	let on = ($tested | each {|c| $c.flag })
	let final = {stage: all, flag: $names, cases: passed, note: $notes}
	# The alert that fires on a tester's sign-in is snoozed for exactly the live stage, however it ends.
	let snooze = (snooze-start $at $on)
	# Not `try ... finally`: nu runs what follows it and raises the error only at the end, so a failed flip
	# told the board its flags were on for everyone (PRONTO-15 Done at 18:02 BRT, 2026-11-08; PRONTO-43).
	try {
		flip-live $at $app $old $doc $on $tested $cmds $before $final
	} catch {|e|
		snooze-end $at $snooze
		error make {msg: $e.msg}
	}
	snooze-end $at $snooze
	tell-board $at $app ($changed | where {|f| $f not-in $off }) $off
}

# The dev flow's board, where the app's repository keeps one (its devflow/devflow.cue; devflow/README.md): the
# issues whose flag went on for everyone are Done, those whose flag went off are Live again. Never fails the push.
const flags_dir = path self .
def tell-board [at: record, app: path, on: list<string>, off: list<string>] {
	if (is-dir $at) { return }
	try {
		let top = (do { ^git -C $app rev-parse --show-toplevel } | complete)
		if $top.exit_code != 0 { return }
		let repo = ($top.stdout | str trim)
		if not ($repo | path join devflow devflow.cue | path exists) { return }
		# PRONTO_DEVFLOW_BIN: a stand-in, in tests.
		let devflow = ($env.PRONTO_DEVFLOW_BIN? | default ($flags_dir | path join .. bin pronto-devflow))
		for told in [[verb, flags]; [flipped, $on], [rolledback, $off]] {
			if ($told.flags | is-empty) { continue }
			let r = (do { ^$devflow $told.verb $repo ($app | path basename) ...$told.flags } | complete)
			print -e $"flags: board: ($r.stdout + $r.stderr | str trim)"
		}
	} catch {|e| print -e $"flags: WARNING: the board was not told: ($e.msg | lines | first)" }
}

# Cloud Monitoring's snooze of flagsLive.alert, for the live stage of a flip: a name to end it by, or null where
# the app names no alert. The snooze ends on its own after two hours should the push never end it.
def snooze-start [at: record, flags: list<string>] {
	if ($at.alert? | default "" | is-empty) or (is-dir $at) { return null }
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
	let canary = (write-flags $at (canary-doc $old $doc $on $testers) $app --meta {stage: testers, flag: ($on | str join "+"), cases: running} --from $before)
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
		write-flags $at $doc $app --meta $final --from $canary | ignore
	} catch {|e|
		try { restore $at $app $before $canary ($on | str join "+") ($e.msg | lines | first) } catch {|r| print -e $"flags: WARNING: could not restore version ($before) over the canary: ($r.msg); `pronto-flags rollback` does" }
		error make {msg: $"rolled back to version ($before): ($e.msg)"}
	}
}

# Every version of the object, newest first: when it was written, when a newer one replaced it, and what
# its write kept. --changes adds, to each, the flags whose default value it moved against the version before
# it (null where either cannot be read); it reads every version, so history asks for it only as JSON.
export def history [app: path, --changes] {
	let at = (live $app)
	let rows = (store-versions $at
	| each {|o| {version: $o.generation, at: $o.timeCreated, live: ($o.timeDeleted? == null), by: ($o.metadata?.pushed-by? | default ""), commit: ($o.metadata?.commit? | default ""), stage: ($o.metadata?.stage? | default ""), flag: ($o.metadata?.flag? | default ""), cases: ($o.metadata?.cases? | default ""), note: ($o.metadata?.note? | default "")}}
	| sort-by {|v| $v.version | into int } --reverse)
	if not $changes { return $rows }
	let docs = ($rows | reverse | each {|r| try { store-version $at $r.version | from json } catch { null } })
	$rows | reverse | enumerate | each {|e|
		let cur = ($docs | get $e.index)
		let prev = if $e.index == 0 { {flags: {}} } else { $docs | get ($e.index - 1) }
		$e.item | insert changes (if $cur == null or $prev == null { null } else { changes-between $prev $cur })
	} | reverse
}

# The version before the live one, or the one named, written again as the newest:
# a rollback is itself a version, which a rollback undoes.
export def rollback [app: path, version?: string, --expect: string] {
	let at = (live $app)
	if (target-guard $at $expect) { show $app; print "flags: dry run: nothing written"; return }
	let all = (history $app)
	let live = ($all | where live | get version.0? | default "")
	let to = if $version != null { $version } else { $all | where version != $live | get version.0? }
	if $to == null or ($all | where version == $to | is-empty) { error make {msg: $"no version ($to) of ($at.url) to roll back to: `pronto-flags history` lists them"} }
	let before = if $live == "" { {flags: {}} } else { store-version $at $live | from json }
	let target = (store-version $at $to | from json)
	let again = (commit $at $app (store-version $at $to) {stage: rollback, note: $"rolled back from ($live) to ($to)"} $live --derive-flag)
	print $"flags: ($at.url) is ($to)'s flags again, as version ($again)"
	# The flags a rollback turned off are rolled back for the board: their Done issues are Live again.
	tell-board $at $app [] (changes-between $before $target | where {|c| $c.to == false } | each {|c| $c.flag })
}

# Once per app: the bucket, versioned and private, keeping the last 50 versions;
# the app's run and preview accounts as its readers, since flagd reads it as the
# service it runs in; and the first push, which flagd needs before a release
# names the object (flagd stops at start on a source it cannot read).
export def setup [app: path, --expect: string] {
	let at = (live $app)
	if (target-guard $at $expect) { show $app; print "flags: dry run: nothing written"; return }
	if (is-dir $at) {
		mkdir $at.dir
		if (generation $at) == "0" { push-plain $app } else { print $"flags: ($at.url) is there already; `pronto-flags push` changes it" }
		return
	}
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
	if (generation $at) == "0" { push-plain $app } else { print $"flags: ($at.url) is there already; `pronto-flags push` changes it" }
}

# ---- The second object kind: the catalog's armies (pronto-armies) ----
# An app's live armies (Bonk Chess: spec/army_catalog.cue) are rows of its database's `army_catalog` table, which
# the page reads as a shape, not an object in a bucket. They are published by the push above, one kind over: the
# same validate (the app's CUE exports the rows, refusing what it does not allow), optimistic write (a row is
# written over the version it read), provenance and journal, testers first, the flag's `production` cases run as the
# tester (cases-of, run-cases), then everyone, and the version read written again on a failure. Only the store
# differs: the rows are written by the database's own SECURITY DEFINER functions (player_record.army_catalog_set and
# army_catalog_drop), through a command the app names, so no app role can write a catalog.
#   bin/pronto-armies push <app-dir> [--local] [--untested "<why>"]   # the app's armiesLive.rows, once their cases pass
#   bin/pronto-armies show <app-dir> [--local]                          # what a push would write, and where: nothing written
#   bin/pronto-armies history <app-dir> [--local]                       # every write of every row, newest first
#   bin/pronto-armies rollback <app-dir> <army> [version] [--local]     # the version before the live one, or the one named
# --local pushes to the stack at hand (armiesLive.local): everyone at once, no cases, as nothing at hand has a tester.

# The app's armiesLive with the testers, address and runAs of its flagsLive.
def armies-at [app: path, local: bool] {
	let a = (cue-of $app armiesLive)
	if $a == null { error make {msg: $"($app)'s flags_spec.cue names no armiesLive: say `armiesLive: {flag: \"…\", rows: […], local: \"…\"}` there"} }
	let cmd = if $local { $a.local? | default "" } else { $a.live? | default "" }
	if ($cmd | is-empty) {
		let which = if $local { "local" } else { "live" }
		error make {msg: $"($app)'s armiesLive names no ($which) command, the way to run SQL \(on its stdin\) in the ($which) database"}
	}
	let f = (cue-of $app flagsLive | default {})
	{
		flag: $a.flag, rows: $a.rows, cmd: $cmd, local: $local
		target: $"armies:(if $local { 'local' } else { 'live' }):($cmd)"
		site: ($f.url? | default ""), testers: ($f.testers? | default []), runAs: ($f.runAs? | default null), alert: ($f.alert? | default null)
	}
}

# SQL run by the app's command; what it printed. Every write passes through here, so the dry run refuses it here.
def army-sql [at: record, sql: string, --write]: nothing -> string {
	if $write { refuse-write $"a write of the army catalog at ($at.target)" }
	let r = ($sql | ^sh -c $at.cmd | complete)
	if $r.exit_code != 0 { error make {msg: $"armies: ($at.cmd): ($r.stderr | str trim)"} }
	$r.stdout
}
def sq [s: string]: nothing -> string { $s | str replace -a "'" "''" }

# The catalog's rows now: id, army, audience, version, min_runner, entry.
def army-rows [at: record]: nothing -> list<record> {
	army-sql $at "SELECT json_build_object('id', id, 'army', army, 'audience', audience, 'version', version, 'min_runner', min_runner, 'entry', entry::jsonb)::text FROM public.army_catalog ORDER BY id;"
	| lines | where {|l| ($l | str trim) != "" } | each {|l| $l | from json }
}
def row-version [row: any]: nothing -> any { if $row == null { null } else { $row.version } }
def army-key [army: string, aud: string]: nothing -> string { if $aud == "testers" { $"($army)/testers" } else { $army } }
# A row is the same as another when its entry (key order aside) and runner are.
def army-same [have: any, want: record]: nothing -> bool {
	if $have == null { return false }
	($have.min_runner == $want.min_runner) and (($have.entry | to json -r | from json | sort) == ($want.entry | to json -r | from json | sort))
}
# The row `want` writes for `aud`, over the version `expect` (null: any); the new version.
def army-set [at: record, want: record, aud: string, expect: any]: nothing -> int {
	let ex = if $expect == null { "NULL" } else { $expect | into string }
	army-sql $at $"SELECT player_record.army_catalog_set\('(sq $want.army)', '(sq ($want.entry | to json -r))'::jsonb, '($aud)', ($want.min_runner), ($ex)\);" --write | str trim | into int
}
def army-drop [at: record, army: string, aud: string, expect: any]: nothing -> int {
	let ex = if $expect == null { "NULL" } else { $expect | into string }
	army-sql $at $"SELECT player_record.army_catalog_drop\('(sq $army)', '($aud)', ($ex)\);" --write | str trim | into int
}

# Every write is journalled as the flags' are (journal-file), one JSON line.
def army-journal [app: path, at: record, stage: string, armies: list<string>, cases: string, note: string] {
	let p = (provenance $app (if $at.local { {dir: "local"} } else { {} }))
	let line = {at: (now-utc), event: "armies.write", app: ($app | path expand | path basename), target: $at.target, stage: $stage, armies: ($armies | str join "+"), who: $p.who, commit: $p.commit, cases: $cases, note: $note} | to json -r
	let file = (journal-file $app)
	try { mkdir ($file | path dirname); $"($line)\n" | save -a $file } catch {|e| print -e $"armies: WARNING: could not note the write in ($file): ($e.msg)" }
	print $"armies: journal ($line)"
}

export def armies-show [app: path, --local] {
	let at = (armies-at $app $local)
	let have = (army-rows $at)
	print $"armies: a push writes to ($at.target):"
	$at.rows | each {|w|
		let now = ($have | where id == (army-key $w.army $w.audience) | get -o 0)
		{army: $w.army, audience: $w.audience, min_runner: $w.min_runner, like: ($w.entry.like? | default ""), now: (if $now == null { "absent" } else if (army-same $now $w) { $"same \(v($now.version))" } else { $"changes v($now.version)" })}
	} | print
}

# Publishes armiesLive.rows. A row that is new or differs is a flip of the catalog, and runs the flag's cases:
#   1. it needs cases (`cases`: the scenarios and unit cases that name the flag); with none the push is refused, or
#      goes on with --untested "<why>";
#   2. it needs what the live stage needs: flagsLive.url, testers and runAs, flagsCases.live, and a `production`
#      scenario of the flag's; with any missing it is refused, nothing written;
#   3. each changed army is written for the testers alone (audience testers), everyone else keeping what they had;
#   4. flagsCases.live runs the flag's `production` scenarios against production as the tester, which look for the
#      army in the page the shape built (their steps wait for the shape to deliver it); a failure writes what was
#      there before, and the push fails;
#   5. each is written for everyone and the testers' rows dropped.
# --local: the stack at hand (armiesLive.local), written for everyone at once, no cases.
export def armies-push [app: path, --local, --untested: string, --expect: string] {
	let at = (armies-at $app $local)
	if (target-guard {url: $at.target} $expect) { armies-show $app --local=$local; print "armies: dry run: nothing written"; return }
	let have = (army-rows $at)
	let changed = ($at.rows | where {|w| not (army-same ($have | where id == (army-key $w.army $w.audience) | get -o 0) $w) })
	if ($changed | is-empty) { print "armies: the catalog is as armiesLive.rows says already; nothing written"; return }
	let names = ($changed | get army)
	if $local {
		for w in $changed {
			let v = (army-set $at $w $w.audience (row-version ($have | where id == (army-key $w.army $w.audience) | get -o 0)))
			print $"armies: ($w.army) is version ($v) for ($w.audience)"
		}
		army-journal $app $at all $names none "at hand"
		return
	}
	let c = (cases-of $app $at.flag)
	if not (has-cases $c) and $untested == null {
		error make {msg: $"a push of ($names | str join ', ') has no cases: name the flag ($at.flag) in a scenario's `flags` and mark it `production` \(tests/scenarios/*.cue; `pronto-flags cases` lists them\), or push with --untested \"<why>\""}
	}
	let cmds = (cue-of $app flagsCases | default {})
	let note = (if $untested != null { $"untested: ($untested)" } else { "" })
	if (has-cases $c) {
		if ($at.site | is-empty) or ($at.testers | is-empty) or ($cmds.live? | default "" | is-empty) {
			error make {msg: "a push runs its cases on production as a tester: say flagsLive.url, flagsLive.testers and flagsCases.live (the tester is made once, by the operator: the app's tests/tester.ts)"}
		}
		if ($at.runAs? | default "" | is-empty) { error make {msg: "the tester's credential is the release identity's, not the operator's: say flagsLive.runAs"} }
		if ($c.production | is-empty) { error make {msg: $"($at.flag) has no `production` scenario to run on production as the tester: mark one \(production: true, tests/scenarios/schema.cue\)"} }
	}
	if $untested != null and not (has-cases $c) { print -e $"armies: WARNING: ($names | str join ', ') pushed with NO CASES: ($untested)" }
	let snooze = (if (has-cases $c) { snooze-start $at [$at.flag] } else { null })
	try { armies-live $app $at $have $changed $c $cmds $note } finally { snooze-end $at $snooze }
}

# The live stage. The state before it is kept, and written again by whatever fails after the first write.
def armies-live [app: path, at: record, have: list<record>, changed: list<record>, c: record, cmds: record, note: string] {
	let before = ($changed | each {|w| {army: $w.army, everyone: ($have | where id == $w.army | get -o 0), testers: ($have | where id == $"($w.army)/testers" | get -o 0)} })
	let names = ($changed | get army)
	let staged = ($changed | where audience == "everyone")
	try {
		for w in $changed {
			let aud = if $w.audience == "everyone" { "testers" } else { $w.audience }
			let b = ($before | where army == $w.army | first)
			let v = (army-set $at $w $aud (row-version (if $aud == "testers" { $b.testers } else { $b.everyone })))
			print $"armies: ($w.army) is version ($v) for ($aud)"
		}
		army-journal $app $at testers $names (if (has-cases $c) { "running" } else { "untested" }) $note
		if (has-cases $c) {
			print $"armies: ($names | str join ', ') is in the page of ($at.testers | str join ', ') alone; running its production cases as ($at.testers.0) \(($c.production | str join ', ')\)"
			let r = (run-cases $app $cmds.live {FLAG: $at.flag, ONLY: ($c.production | str join ","), APP_URL: $at.site, FLAGS_TESTER: $at.testers.0, CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT: $at.runAs})
			if not $r.ok { error make {msg: $"($at.flag)'s production cases failed:\n($r.out)"} }
		}
		for w in $staged {
			let v = (army-set $at $w "everyone" (row-version ($before | where army == $w.army | first | get everyone)))
			print $"armies: ($w.army) is version ($v) for everyone"
			army-drop $at $w.army "testers" null | ignore
		}
		army-journal $app $at all $names (if (has-cases $c) { "passed" } else { "untested" }) $note
	} catch {|e|
		# What was there before is written again: an army that had a row gets its entry back, one that had none loses the row.
		for b in $before {
			try {
				if $b.everyone != null { army-set $at {army: $b.army, entry: $b.everyone.entry, min_runner: $b.everyone.min_runner} "everyone" null | ignore } else { army-drop $at $b.army "everyone" null | ignore }
				if $b.testers != null { army-set $at {army: $b.army, entry: $b.testers.entry, min_runner: $b.testers.min_runner} "testers" null | ignore } else { army-drop $at $b.army "testers" null | ignore }
			} catch {|r| print -e $"armies: WARNING: could not restore ($b.army): ($r.msg); `pronto-armies rollback` does" }
		}
		army-journal $app $at rolled-back $names failed ($e.msg | lines | first)
		error make {msg: $"rolled back: ($e.msg)"}
	}
}

# Every write of the catalog's rows, newest first: when, by whom, which row, the version it made (an entry of null is a drop).
export def armies-history [app: path, --local] {
	let at = (armies-at $app $local)
	army-sql $at "SELECT json_build_object('at', at, 'who', who, 'key', key, 'version', version, 'min_runner', min_runner, 'entry', entry)::text FROM player_record.army_catalog_log ORDER BY at DESC, version DESC LIMIT 200;"
	| lines | where {|l| ($l | str trim) != "" } | each {|l| $l | from json }
}

# An army's earlier entry written again for everyone, as the newest version: the one before the live one, or `version`.
export def armies-rollback [app: path, army: string, version?: int, --local, --expect: string] {
	let at = (armies-at $app $local)
	if (target-guard {url: $at.target} $expect) { print "armies: dry run: nothing written"; return }
	let log = (armies-history $app --local=$local | where key == $army | where {|r| $r.entry != null })
	let live = (army-rows $at | where id == $army | get -o 0)
	let to = if $version != null { $log | where version == $version | get -o 0 } else { $log | where {|r| $live == null or $r.version != $live.version } | get -o 0 }
	if $to == null { error make {msg: $"no earlier version of ($army) to roll back to: `pronto-armies history` lists them"} }
	let v = (army-set $at {army: $army, entry: $to.entry, min_runner: $to.min_runner} "everyone" ($live | get -o version))
	print $"armies: ($army) is version ($to.version)'s entry again, as version ($v)"
	army-journal $app $at rollback [$army] none $"rolled back to ($to.version)"
}

def "main armies" [] { print "usage: live.nu armies push|show|history|rollback <app-dir> [army] [--local]" }
def "main armies push" [app: path, --local, --untested: string, --expect: string, --dry-run] { with-env (dry-env $dry_run) { armies-push $app --local=$local --untested $untested --expect $expect } }
def "main armies show" [app: path, --local] { armies-show $app --local=$local }
def "main armies history" [app: path, --local, --json] { let h = (armies-history $app --local=$local); if $json { $h | to json | print } else { $h | table -e | print } }
def "main armies rollback" [app: path, army: string, version?: int, --local, --expect: string, --dry-run] { with-env (dry-env $dry_run) { armies-rollback $app $army $version --local=$local --expect $expect } }

def main [] { print "usage: live.nu setup|push|history|rollback|show|cases <app-dir> [version|flag]; live.nu armies push|show|history|rollback <app-dir>" }
def "main setup" [app: path, --expect: string, --dry-run] { with-env (dry-env $dry_run) { setup $app --expect $expect } }
def "main push" [app: path, --untested: string, --expect: string, --dry-run] { with-env (dry-env $dry_run) { push $app --untested $untested --expect $expect } }
def "main history" [app: path, --json] { if $json { history $app --changes | to json | print } else { history $app | table -e | print } }
def "main rollback" [app: path, version?: string, --expect: string, --dry-run] { with-env (dry-env $dry_run) { rollback $app $version --expect $expect } }
def dry-env [on: bool]: nothing -> record { if $on { {PRONTO_FLAGS_DRY_RUN: "1"} } else { {} } }
def "main show" [app: path] { show $app }
def "main cases" [app: path, flag?: string] { cases $app $flag | table -e | print }
