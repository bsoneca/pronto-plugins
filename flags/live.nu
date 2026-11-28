# The released app's live flags: one object in a versioned Cloud Storage bucket,
# which the app's flagd reads (FLAGD_SOURCES, release.cue) and polls, so a flag
# changes with a push and never a deploy. The app's flagsLive (flags_spec.cue)
# names the bucket and its project; its flags are flagd.document, exported from
# the app's CUE as generate writes flags/flags.json. Every push is a version of
# the object, kept: the history, and what a rollback restores.
# Where flagsLive says `dir` instead of a bucket, the same store is a local directory (see
# "The store"): a drill or a laptop, with no gcloud.
#   bin/pronto-flags setup <app-dir>               # the bucket, its readers, the first push
#   bin/pronto-flags push <app-dir> [--flip a,b|a=<value>] [--sync a,b] [--drop a,b]
#                                                  # the flags as flags_spec.cue says them now, merged over the live ones (see `keep-live`): --flip X (X=true) or --flip X=<value>
#                                                  # sets a flag live and needs its cases; --sync X writes the spec's whole reach (accounts too); the flip is then recorded
#                                                  # into flags_spec.cue by a pull request this tool opens (see `record-back`)
#                                                  # a push that names a flag writes that flag alone (the rest of live as it is); more than one needs --several "<why>" (PRONTO-1755, PRONTO-415)
#                                                  # --stages 5,25,100 (one --flip flag) goes through flagd's fractional on targetingKey, a version per stage: its cases, --dwell (10min), then on
#   bin/pronto-flags record <app-dir>              # the live flags into the spec, by hand: what a flip does after its write
#   bin/pronto-flags drift <app-dir>               # what the spec says differently from live; exit 1 when it differs
#   bin/pronto-flags released <app-dir>            # records which flags the release being served reads (released.json beside the live object)
#   bin/pronto-flags cases <app-dir> [flag]        # the cases a flip of each flag (or the one) runs
#   bin/pronto-flags history <app-dir> [--json]    # every version, newest first
#   bin/pronto-flags rollback <app-dir> [version]  # the version before the live one, or the one named
#   bin/pronto-flags show <app-dir>                # what a push would write, and where: nothing written
# Each runs as the operator's own gcloud login.
# Every write (setup, push, rollback) prints its target first and takes --expect <url> (or PRONTO_FLAGS_EXPECT):
# a target that differs is refused with nothing written. With PRONTO_FLAGS_DRY_RUN set a write shows what it
# would write and stops, as --dry-run does; a write reached anyway is refused where it happens. Each write is also appended to a journal (see `journal`).
# A push that changes who a flag is on for (its default or its accounts) runs that flag's cases first, and only --flip or --sync names such a flag (see `push`).

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
	let at = ($at | upsert site ($at.url? | default null))
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

# The record of what the served release reads: released.json beside the live object (`pronto-flags released`),
# {commit, at, flags: [names]}. null where there is none or it cannot be read: then every live flag counts as read.
def record-url [at: record]: nothing -> string {
	if (is-dir $at) { $at.dir | path join released.json } else { $at.url | str replace -r '/[^/]*$' '/released.json' }
}
def record-read [at: record]: nothing -> any {
	try {
		let text = if (is-dir $at) {
			let f = (record-url $at)
			if not ($f | path exists) { return null }
			open --raw $f
		} else {
			let r = (run-gcloud storage cat (record-url $at))
			if $r.exit_code != 0 { return null }
			$r.stdout
		}
		let rec = ($text | from json)
		if ($rec.flags? | describe | str starts-with "list") { $rec } else { null }
	} catch { null }
}
def record-put [at: record, rec: record] {
	refuse-write $"the release record at (record-url $at)"
	let text = ($rec | to json --indent 2)
	if (is-dir $at) {
		let tmp = ($at.dir | path join ".released.json.tmp")
		$text | save -f $tmp
		mv -f $tmp (record-url $at)
		return
	}
	let file = (mktemp -t --suffix .json)
	$text | save -f $file
	gc storage cp $file (record-url $at) --content-type application/json --cache-control no-store | ignore
	rm $file
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

const flags_dir = path self .

# A push from a checkout older than the one the app's repo pins can drop flags the release still reads (PRONTO-680).
# The repo pins a commit of this plugin in .github/flags.pin (40 hex characters); a write from a checkout that does
# not contain it is refused, before anything is read or written. No pin file: no check.
def pin-guard [app: path] {
	let top = (do { ^git -C $app rev-parse --show-toplevel } | complete)
	if $top.exit_code != 0 { return }
	let repo = ($top.stdout | str trim)
	let file = ($repo | path join .github flags.pin)
	if not ($file | path exists) { return }
	let pin = (open --raw $file | str trim)
	if not ($pin =~ '^[0-9a-f]{40}$') { error make {msg: $"flags: ($file) must hold one commit, 40 hex characters"} }
	let root = ($flags_dir | path join .. | path expand)
	let s = ($pin | str substring 0..<9)
	let head = (do { ^git -C $root rev-parse --short HEAD } | complete)
	let refuse = {|why: string|
		let h = if $head.exit_code == 0 { $head.stdout | str trim } else { "no HEAD" }
		error make {msg: $"flags: this pronto-flags \(($root) at ($h)\) cannot write for ($repo): ($why). ($repo)/.github/flags.pin pins ($s), and a push from a checkout without it can turn off flags the release still reads \(PRONTO-680\). Run the repo's pinned entry point \(in pronto: tools/flags/pronto-flags\), or bring this checkout to ($s)."}
	}
	if $head.exit_code != 0 { do $refuse $"($root) is not a git checkout" }
	mut r = (do { ^git -C $root merge-base --is-ancestor $pin HEAD } | complete)
	mut fetched = ""
	if $r.exit_code == 128 {
		# Unknown here. A full clone has nothing more to fetch; a shallow one lacks history below its boundary.
		let shallow = (do { ^git -C $root rev-parse --is-shallow-repository } | complete | get stdout | str trim)
		if $shallow == "true" {
			let f = (with-env {GIT_TERMINAL_PROMPT: "0"} { do { ^git -C $root fetch -q --unshallow origin } | complete })
			$fetched = ($f.stderr | str trim)
			$r = (do { ^git -C $root merge-base --is-ancestor $pin HEAD } | complete)
			if $r.exit_code == 128 { do $refuse $"the pinned commit ($s) is unknown here and at origin: ($fetched)" }
		} else {
			do $refuse $"the pinned commit ($s) is unknown here \(a full clone: fetch origin first\)"
		}
	}
	if $r.exit_code == 1 { do $refuse $"this checkout does not contain the pinned commit ($s) \(older, or on a branch without it\)" }
	if $r.exit_code != 0 { do $refuse $"git could not compare this checkout with ($s): ($r.stderr | str trim)" }
}

# Who pushed, and from which commit: kept on each version, which history shows. A directory store
# needs no gcloud: the account where one is installed, else the login name.
def provenance [app: path, at: record] {
	# PRONTO_FLAGS_WHO names who asks where the process's own login is no one (Studio's builder: `studio:<user id>`).
	let named = ($env.PRONTO_FLAGS_WHO? | default "" | str trim)
	let who = if $named != "" { $named } else if (is-dir $at) {
		let a = if (which gcloud | is-empty) { "" } else { do { ^gcloud config get-value account } | complete | get stdout | str trim }
		if $a == "" { $env.USER? | default (^whoami | str trim) } else { $a }
	} else { gc config get-value account | str trim }
	let commit = (do { cd $app; ^git rev-parse --short HEAD } | complete | get stdout | str trim)
	# Any of the app's CUE: a flag's value may come from another spec (pronto-billing's grants, say).
	let dirty = (do { cd $app; ^git status --porcelain -- '*.cue' } | complete | get stdout | str trim)
	# The pronto-flags checkout that writes: which version of this plugin wrote the version (PRONTO-718).
	let proot = ($flags_dir | path join .. | path expand)
	let pc = (do { ^git -C $proot rev-parse --short HEAD } | complete | get stdout | str trim)
	let pdirty = (do { ^git -C $proot status --porcelain --untracked-files=no } | complete | get stdout | str trim)
	let plugin = ($pc + (if ($pdirty | is-empty) { "" } else { "+edits" }))
	{who: $who, commit: ($commit + (if ($dirty | is-empty) { "" } else { "+edits" })), plugin: $plugin}
}

# Whether a mirror holds a credential (a kubeconfig file): then no command the app supplies may run beside it unjailed.
def has-kubeconfig [at: record]: nothing -> bool {
	($at.mirrors? | default [] | any {|m| ($m.kubeconfig? | default null) != null })
}

# PRONTO_FLAGS_CASES_WRAP, as a flip's case command is prefixed with it; "" where unset. A wrap ending in a shell separator
# would leave the case command outside it, and a kubeconfig mirror takes no flip without one.
def cases-wrap [at: record]: nothing -> string {
	let wrap = ($env.PRONTO_FLAGS_CASES_WRAP? | default "" | str trim)
	if $wrap == "" and (has-kubeconfig $at) {
		error make {msg: "flags: a kubeconfig mirror holds a credential, so a flip's case command must run jailed: set PRONTO_FLAGS_CASES_WRAP; nothing was written"}
	}
	if $wrap =~ '[;&|]$' { error make {msg: $"flags: PRONTO_FLAGS_CASES_WRAP ends in a shell separator \(($wrap)\), which would run the case command outside it; nothing was written"} }
	$wrap
}

# The flags written where else a flagd reads them (flagsLive.mirrors): a release@k8s node's ConfigMap,
# which its flagd mounts (release.cue's services.flagd.files), applied over ssh as the node's kubectl, or, where
# the mirror names a `kubeconfig` file instead of `ssh`, by a kubectl here on that file's identity.
# Each write of the live object is written there too: a push, its restore, a rollback.
# A mirror that fails warns and the push goes on (a staging node), unless it is required (production).
def mirror [at: record, text: string] {
	for m in ($at.mirrors? | default []) {
		let key = ($m.key? | default "flags.json")
		let cm = ({apiVersion: v1, kind: ConfigMap, metadata: {name: $m.configMap, namespace: $m.namespace}, data: {$key: $text}} | to json)
		let via_kubeconfig = (($m.kubeconfig? | default null) != null)
		let target = if $via_kubeconfig { $m.kubeconfig } else { $m.ssh }
		refuse-write $"the mirror at ($target)"
		# A kubeconfig mirror applies from here, as that file's identity (Studio's builder, with a short-lived token
		# bound to the app's namespace); an ssh one applies on the node.
		let r = if $via_kubeconfig {
			# The binary is the operator's (PRONTO_FLAGS_KUBECTL), never the app's: it is handed the credential.
			let kubectl = ($env.PRONTO_FLAGS_KUBECTL? | default "kubectl")
			$cm | ^$kubectl --kubeconfig $m.kubeconfig apply -f - | complete
		} else {
			$cm | ^ssh -o BatchMode=yes -o ConnectTimeout=20 $m.ssh $"($m.kubectl? | default 'sudo k3s kubectl') apply -f -" | complete
		}
		let where = $"($target)'s ($m.namespace)/($m.configMap)"
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
	if (has-kubeconfig $at) { error make {msg: "flags: flagsLive.database runs the app's command beside a kubeconfig mirror's credential, unjailed: refused; nothing was written"} }
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

# What a push writes over the live flags `old`: the spec's `doc`, with the live entry kept where a flag is not the
# push's to change (PRONTO-680: a push wrote main's spec whole, so a flag retired from main vanished from production
# while the release serving it still read it, and a default changed on main landed unasked; PRONTO-1191: so did
# accounts added to a live flag, and a new flag with an accounts rule):
#   - live, absent from the spec: kept while the release reads it (`reads`, the names in released.json; null: there
#     is no record, so every live flag counts as read), dropped once the record does not name it, or when `drop` names it;
#   - in both, its reach differing (default, accounts or targeting: `reach`): kept whole unless `flip` names it, but
#     with the spec's metadata (the flag set it is served in: `client`), since metadata is no part of its reach;
#   - new to the live object, and not fully off: written off (its default false, its accounts and canary gone, the
#     at-hand branch kept) unless `flip` names it, and an error where it is not a bool, which has no off form.
#     flagd layers the live object over the release's baked flags.json, so a flag left out would serve the baked rule.
# `flip` turns flags on or sets them: "X" is X=true, "X=<value>" a bool, string or number checked against the kind of the
# spec's default. The value comes from the command line and the spec supplies the flag's shape (local, hosts, accounts):
# the entry is the spec's with its default set (`set-default`). `sync` names flags whose whole reach is written as the
# spec says it (default, accounts, targeting: PRONTO-1191), as --flip did before it took a value.
# A push that names a flag (a `flip`, a `sync` or a `drop`) writes that flag and nothing else (PRONTO-1755: it once wrote the spec's
# metadata on every other flag and every new flag off, and the journal called them all flips): it starts from the LIVE
# flags, the flags it names take the spec's entry, every other live entry stays verbatim (metadata too), a flag new to the
# live object is left out (flagd serves the release's baked entry, as it does today), a retired one stays unless `drop`
# names it. What it leaves is `left` ({flag, kind}: metadata, definition or new; reach and retired are `kept`). A push that
# names none is the reconcile, as above.
# {doc, kept: [{flag, why}], written_off: [{flag, why}], dropped: [{flag, why}], left: [{flag, kind}]}.
export def keep-live [old: record, doc: record, reads: any, flip: list<string>, drop: list<string>, sync: list<string> = []]: nothing -> record {
	let live = ($old.flags? | default {})
	let spec = $doc.flags
	let sets = (flip-values $flip $spec $live)
	let flip = ($sets | get flag | append $sync | uniq)
	let owned_only = ($flip | is-not-empty) or ($drop | is-not-empty)
	let named = ($drop | where {|f| $f in ($spec | columns) })
	if ($named | is-not-empty) { error make {msg: $"flags: --drop ($named | str join ', ') is in the spec: to turn it off say --flip <flag>=false \(a spec flag stays; --drop is for a live flag the spec no longer names\)"} }
	let nowhere = ($drop | where {|f| $f not-in ($spec | columns) and $f not-in ($live | columns) })
	if ($nowhere | is-not-empty) { error make {msg: $"flags: --drop ($nowhere | str join ', ') is neither live nor in the spec; nothing was written"} }
	let gone = ($live | columns | where {|f| $f not-in ($spec | columns) })
	let verdicts = ($gone | each {|f|
		if $f in $drop { {flag: $f, keep: false, why: "forced by --drop"} } else if $owned_only { {flag: $f, keep: true, why: "retired from the spec: a push that names a flag leaves it, a plain push drops it once the release stops reading it"} } else if $reads == null { {flag: $f, keep: true, why: "no released.json, so the release is taken to read it"} } else if $f in $reads.flags { {flag: $f, keep: true, why: "retired from the spec, waits for a release that stops reading it"} } else { {flag: $f, keep: false, why: "the release no longer reads it"} }
	})
	let held = ($spec | columns | where {|f| $f in ($live | columns) and $f not-in $flip and (reach ($live | get $f)) != (reach ($spec | get $f)) })
	let fresh = ($spec | columns | where {|f| $f not-in ($live | columns) and $f not-in $flip and not (fully-off ($spec | get $f)) })
	let nonbool = if $owned_only { [] } else { $fresh | where {|f| (default-of ($spec | get $f) | describe) != "bool" } }
	if ($nonbool | is-not-empty) { error make {msg: $"flags: ($nonbool | str join ', ') is new and not off: name it in --flip with its value \(--flip <flag>=<value>\); nothing was written"} }
	let written_off = if $owned_only { [] } else { $fresh | each {|f|
		let r = (reach ($spec | get $f))
		let who = if ($r.accounts | is-not-empty) { "accounts" } else if $r.value != false { "everyone" } else { "its targeting" }
		{flag: $f, why: $"new and on for ($who): written off; --flip or --sync turns it on"}
	} }
	let kept = ($held | each {|f| {flag: $f, why: "its reach in the spec differs from live (default, accounts or targeting) and no --flip or --sync names it"} } | append ($verdicts | where keep | select flag why))
	let flags = if $owned_only {
		let mine = ($flip | where {|f| $f not-in ($sets | get flag) } | each {|f| {$f: ($spec | get $f)} } | into record)
		($verdicts | where {|v| not $v.keep } | get flag | reduce --fold $live {|f, acc| $acc | reject -o $f })
		| merge $mine
		| merge ($sets | each {|s| {($s.flag): (set-default ($spec | get $s.flag) $s.value)} } | into record)
	} else {
		$spec
		| merge ($held | each {|f| {$f: (with-spec-metadata ($live | get $f) ($spec | get $f))} } | into record)
		| merge ($fresh | each {|f| {$f: (off-form ($spec | get $f))} } | into record)
		| merge ($verdicts | where keep | each {|v| {($v.flag): ($live | get $v.flag)} } | into record)
		| merge ($sets | each {|s| {($s.flag): (set-default ($spec | get $s.flag) $s.value)} } | into record)
	}
	let left = if $owned_only { drift-kinds $live $spec | where {|r| $r.flag not-in $flip and $r.kind in [metadata definition new] } } else { [] }
	{doc: ($doc | upsert flags $flags), kept: $kept, written_off: $written_off, dropped: ($verdicts | where {|v| not $v.keep } | select flag why), left: $left}
}

# What differs between the live flags and the spec's, flag by flag: {flag, kind}. `reach` (default, accounts or targeting),
# `metadata` (the flag set it is served in, and nothing else), `definition` (state, variants, anything else), `new` (the spec
# holds it, live does not), `retired` (live holds it, the spec does not). A flip leaves all of these as they are; `drift` lists them.
export def drift-kinds [live: record, spec: record]: nothing -> list<record> {
	let in_spec = ($spec | columns | each {|f|
		let l = ($live | get -o $f)
		let s = ($spec | get $f)
		if $l == null { {flag: $f, kind: new} } else if $l == $s { null } else if (reach $l) != (reach $s) { {flag: $f, kind: reach} } else if ($l | reject -o metadata) == ($s | reject -o metadata) { {flag: $f, kind: metadata} } else { {flag: $f, kind: definition} }
	} | compact)
	$in_spec | append ($live | columns | where {|f| $f not-in ($spec | columns) } | each {|f| {flag: $f, kind: retired} })
}

# A live entry kept whole, but with the metadata the spec says (the spec's, or none): flagd namespaces flags by
# flagSetId across its sources, so a baked entry with metadata layered over a live one without it would make the
# client selector read the baked value instead of the live one (PRONTO-1518). Metadata is not reach: a change to it
# alone is a definition change (`defs-between`), which asks for no flip cases.
def with-spec-metadata [live: record, spec: record]: nothing -> record {
	let m = ($spec | get -o metadata)
	if $m == null { $live | reject -o metadata } else { $live | upsert metadata $m }
}

# An older version's flags text with the metadata the spec says now, flag by flag (a flag the spec does not name keeps its own): what a
# restore or a rollback writes, so that the door's flag-set selector never meets entries a restored document lacks the mark on (PRONTO-1518).
# Only the metadata is the spec's: values, targeting and every other field are the old version's.
export def with-current-metadata [old: record, spec: record]: nothing -> record {
	let fl = ($old.flags? | default {})
	let now = ($spec.flags? | default {})
	$old | upsert flags ($fl | columns | reduce --fold $fl {|f, acc|
		if $f in ($now | columns) { $acc | upsert $f (with-spec-metadata ($fl | get $f) ($now | get $f)) } else { $acc }
	})
}

# An older version's text, so rewritten, for the app whose spec is `app`.
def current-metadata-text [text: string, app: path]: nothing -> string {
	with-current-metadata ($text | from json) (cue-of $app flagd.document) | to json
}

# The entry of a flag with its default set to `value`: the spec's own, every other field as it is.
def set-default [def: record, value: any]: nothing -> record {
	$def | upsert variants ($def.variants? | default {} | upsert default $value) | upsert defaultVariant "default"
}

# What --flip names: [{flag, value}], the value read as the kind of the flag's default in the spec. A bare name is
# true, and only a bool can be bare; and where the spec says false while live says true a bare name is refused, for
# it would either undo the flip or leave the spec behind it. A flag the spec lacks is left for the caller to refuse.
def flip-values [flip: list<string>, spec: record, live: record]: nothing -> list<record> {
	$flip | each {|e|
		let at = ($e | str index-of "=")
		let flag = if $at < 0 { $e } else { $e | str substring 0..<$at }
		let raw = if $at < 0 { null } else { $e | str substring ($at + 1).. }
		let def = ($spec | get -o $flag)
		let kind = (default-of $def | describe)
		let bad = {|why| error make {msg: $"flags: --flip ($e): ($why); nothing was written"} }
		if $def == null {
			{flag: $flag, value: null}
		} else if $raw == null {
			if $kind != "bool" { do $bad $"($flag) is a ($kind), so say --flip ($flag)=<value>" }
			if (default-of $def) == false and (default-of ($live | get -o $flag)) == true { do $bad $"the spec says ($flag) false and live says true: say ($flag)=true or ($flag)=false" }
			{flag: $flag, value: true}
		} else {
			let value = match $kind {
				"bool" => { if $raw in ["true" "false"] { $raw == "true" } else { do $bad $"($flag) is a bool: true or false" } }
				"string" => { $raw }
				"int" | "float" => { try { if $raw =~ '^-?\d+$' { $raw | into int } else { $raw | into float } } catch { do $bad $"($flag) is a number" } }
				_ => { do $bad $"($flag) has a ($kind) default, which --flip cannot set" }
			}
			{flag: $flag, value: $value}
		}
	} | where {|s| $s.value != null }
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
	# The flags named: those whose default moved, and those whose reach changed otherwise (targeting, state): a
	# rollout widened to everyone breaks things without its default moving. A definition change that leaves who the
	# flag is on for as it was (its metadata, say) is no flip: it is `defs` (PRONTO-1755).
	let defs = if $old == null { [] } else { defs-between $old ($text | from json) }
	let reached = ($defs | where {|f| (reach ($old.flags | get $f)) != (reach (($text | from json).flags | get $f)) })
	let names = if $old == null { "" } else { ($changes | each {|c| $c.flag }) | append $reached | uniq | str join "+" }
	let meta = if $derive_flag and ($meta.flag? | default "" | is-empty) and $names != "" { $meta | upsert flag $names } else { $meta }
	let p = (provenance $app $at)
	let gen = (store-put $at $text ({pushed-by: $p.who, commit: $p.commit, plugin: $p.plugin} | merge $meta) $from)
	mirror $at $text
	database $at $app $text
	let line = {
		at: (now-utc), event: "flags.write", app: ($app | path expand | path basename), target: $at.url, version: $gen, from: $from
		stage: ($meta.stage? | default ""), flag: (if $names != "" { $names } else { $meta.flag? | default "" }), who: $p.who, commit: $p.commit, plugin: $p.plugin
		defs: ($defs | where {|f| $f not-in $reached } | str join "+")
		cases: ($meta.cases? | default ""), note: ($meta.note? | default ""), changes: $changes
		kept: ($meta.kept? | default ""), dropped: ($meta.dropped? | default ""), reading: ($meta.reading? | default "")
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
	print $"flags: ($at.url) is version ($now) \(was ($from)\); every flagd reads it within `flagsLive.syncSec` \(180 s\), and a page on its next load"
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

# What a flag's entry decides in production: its state, default value, and who else it is on for. The generated
# at-hand branch (flags_plugin.cue: the hosts, read as `local`) is no part of it but its hosts; accounts are the
# targetingKey branch, whose value is the `local` variant; `other` is any targeting that is none of those (null
# where there is none). `split` is the percent of players a staged push (`--stages`) has the flag on for: the weight of the
# first variant of a `fractional` branch after the generated ones (flagd's, bucketed by targetingKey), null where there is none.
# Null for a flag that is not there.
def reach [def: any]: nothing -> any {
	if $def == null { return null }
	let rule = ($def.targeting? | default null)
	let branches = if ($rule | describe | str starts-with "record") { $rule | get -o if } else { null }
	let is_test = {|t, v| ($t | describe | str starts-with "record") and (($t | get -o in | default [] | get -o 0 | default {} | get -o var) == $v) and (($t | get -o in | default [] | get -o 1 | describe | str starts-with "list")) }
	mut hosts = []
	mut accounts = []
	mut i = 0
	mut other: any = null
	mut split: any = null
	# Only a staged push's own shape counts as a split ([["on", w], ["off", 100 - w]]); any other fractional rule is `other`.
	let frac = {|t|
		let f = if ($t | describe | str starts-with "record") { $t | get -o fractional } else { null }
		if ($f | describe | str starts-with "list") and ($f | length) == 2 and ($f | all {|v| ($v | describe | str starts-with "list") and ($v | length) == 2 }) and ($f.0.0 == "on") and ($f.1.0 == "off") and (($f.0.1 | describe) == "int") and ($f.1.1 == (100 - $f.0.1)) { $f } else { null }
	}
	if ($branches | describe | str starts-with "list") {
		if (do $is_test ($branches | get -o 0) host) and ($branches | get -o 1) == "local" { $hosts = ($branches | get 0 | get in | get 1); $i = 2 }
		if (do $is_test ($branches | get -o $i) targetingKey) and ($branches | get -o ($i + 1)) == "local" { $accounts = ($branches | get $i | get in | get 1); $i = $i + 2 }
		let rest = ($branches | skip $i)
		if ($rest | length) == 1 and (do $frac ($rest | first)) != null { $split = (do $frac ($rest | first) | get -o 0.1) } else if $rest != ["default"] { $other = $rule }
	} else if (do $frac $rule) != null {
		$split = (do $frac $rule | get -o 0.1)
	} else if ($rule | describe | str starts-with "record") and ($rule | is-not-empty) {
		$other = $rule
	}
	{
		state: ($def.state? | default null)
		value: (default-of $def)
		hosts: ($hosts | sort)
		accounts: ($accounts | sort)
		accountValue: (if ($accounts | is-empty) { null } else { $def.variants? | default {} | get -o local })
		other: $other
		split: $split
	}
}

# A flag that is on for no one: its default false, no accounts, no other targeting.
def fully-off [def: any]: nothing -> bool {
	let r = (reach $def)
	$r != null and $r.value == false and ($r.accounts | is-empty) and $r.other == null and $r.split == null
}

# A new flag's entry written off: default false, the at-hand `local` variant and host branch kept, its accounts,
# canary variants and the rest gone.
def off-form [def: record]: nothing -> record {
	let r = (reach $def)
	let local = ($def.variants? | default {} | get -o local)
	let variants = if $local == null { {default: false} } else { {default: false, local: $local} }
	let base = ($def | reject -o targeting | upsert variants $variants | upsert defaultVariant "default")
	if ($r.hosts | is-empty) { $base } else { $base | insert targeting {"if": [{"in": [{"var": "host"}, $r.hosts]}, "local", "default"]} }
}

# The flags a push writes, as a table: each flag's values and the accounts it names. A flag's default is the
# value its default variant holds: a canary's is `old`, with no `default` variant for a flag new to the live
# object (2026-11-08 18:02 BRT, trial_banner: the push failed past its testers write, PRONTO-43).
def summary [doc: record] {
	$doc.flags | transpose flag def | each {|f| {flag: $f.flag, default: (default-of $f.def), local: ($f.def.variants.local? | default "—"), accounts: (accounts-of $f.def | str join ", ")}}
}

# The live flags a push would write over, and what it would keep of them: the spec merged over the live object
# (`keep-live`). Said as it goes; the live version it read comes back with the merge. A store with nothing live yet
# has nothing to keep.
def merge-live [at: record, app: path, doc: record, flip: list<string>, drop: list<string>, sync: list<string> = []]: nothing -> record {
	let before = (generation $at)
	let old = if $before == "0" { {flags: {}} } else { store-cat $at | from json }
	let flipped = ($flip | each {|e| $e | split row "=" | first })
	let unknown = ($flipped | where {|f| $f not-in ($doc.flags | columns) })
	if ($unknown | is-not-empty) { error make {msg: $"flags: --flip ($unknown | str join ', ') is not in the spec; nothing was written"} }
	let unsynced = ($sync | where {|f| $f not-in ($doc.flags | columns) })
	if ($unsynced | is-not-empty) { error make {msg: $"flags: --sync ($unsynced | str join ', ') is not in the spec; nothing was written"} }
	let rec = (record-read $at)
	let gone = ($old.flags? | default {} | columns | where {|f| $f not-in ($doc.flags | columns) })
	if $rec == null and ($gone | is-not-empty) { print -e $"flags: WARNING: no release record at (record-url $at) \(`pronto-flags released`\): every live flag counts as read by the release" }
	if $rec != null { print $"flags: the release record names ($rec.flags | length) flags, from commit ($rec.commit? | default '?') at ($rec.at? | default '?')" }
	let m = (keep-live $old $doc ($rec) $flip $drop $sync)
	for k in $m.kept { print -e $"flags: WARNING: ($k.flag) kept as live: ($k.why)" }
	for w in $m.written_off { print -e $"flags: WARNING: ($w.flag) is ($w.why)" }
	for d in $m.dropped { print -e $"flags: ($d.flag) dropped from the live flags: ($d.why)" }
	for l in $m.left { print $"flags: drift left as live \(not this push's\): ($l.flag): ($l.kind)" }
	if ($m.left | is-not-empty) { print "flags: `pronto-flags drift <app-dir>` lists it; a push that names no flag reconciles it" }
	$m | insert before $before | insert old $old
}

# What a push's version keeps of the merge, beside its stage: the flags it left as live, and those it dropped.
def merge-meta [m: record]: nothing -> record {
	let kept = ($m.kept | append $m.written_off | get flag | str join "+")
	let dropped = ($m.dropped | get flag | str join "+")
	{} | if $kept != "" { insert kept $kept } else { $in } | if $dropped != "" { insert dropped $dropped } else { $in }
}

export def show [app: path, --flip: list<string> = [], --drop: list<string> = [], --sync: list<string> = []] {
	let at = (live $app)
	print $"flags: a push writes ($at.url) in ($at.project? | default 'a local directory'):"
	let doc = (cue-of $app flagd.document)
	let merged = try { (merge-live $at $app $doc $flip $drop $sync).doc } catch {|e|
		if ($e.msg | str contains "--flip") or ($e.msg | str contains "--drop") or ($e.msg | str contains "--sync") { error make {msg: $e.msg} }
		print -e $"flags: WARNING: the live flags were not read, so this is the spec alone: ($e.msg | lines | first)"
		$doc
	}
	summary $merged | print
}

# The flags as the spec says them, written with no cases: the first push of `setup`.
def push-plain [app: path] {
	# Through keep-live as every push is: a new flag that is on is written off, a non-bool one refused (PRONTO-1191).
	let m = (keep-live {flags: {}} (cue-of $app flagd.document) null [] [])
	for w in $m.written_off { print -e $"flags: WARNING: ($w.flag) is ($w.why)" }
	write-flags (live $app) $m.doc $app --meta ({stage: all, note: "first push"} | merge (merge-meta $m)) | ignore
}

# ---- A flip runs its flag's cases (flags_plugin.cue: flagsCases) ----

# An expression of the CUE package in one of the app's folders (tests/scenarios, tests/unit); null where
# the app has no such folder or the expression is not there.
def cue-dir [app: path, dir: string, expr: string] {
	if not ($app | path join $dir | path exists) { return null }
	let r = (do { cd $app; ^$env.SAYT_MISE_BIN exec -- cue export $"./($dir)" -e $expr --out json } | complete)
	if $r.exit_code != 0 {
		# Only the expression itself missing means the folder has none. An "undefined field" inside a value is a failure to evaluate:
		# read as "none" it made every flag of an app whose spec needs `generate` (aprende's spec/dados/spec.json, gitignored) look
		# case-less (PRONTO-89).
		if ($r.stderr | str contains $"reference \"($expr)\" not found") { return null }
		if ($r.stderr | str contains "@embed: open") { error make {msg: $"cue export ./($dir) -e ($expr) in ($app) reads a file the app's generate writes: run `./saytw generate` in ($app) first \(($r.stderr | lines | where {|l| $l | str contains '@embed' } | first | str trim)\)"} }
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

# The flags a push changes: new ones that are not fully off, and those whose reach moves (default, accounts or
# targeting). A flag new to the live object and fully off changes nothing: absent already reads as off, so it has
# no flip to test.
def changed-flags [old: record, doc: record]: nothing -> list<string> {
	$doc.flags | transpose f def | where {|r|
		let was = ($old.flags | get -o $r.f)
		if $was == null { not (fully-off $r.def) } else { (reach $was) != (reach $r.def) }
	} | each {|r| $r.f }
}

# A flag's cases: the scenarios (tests/scenarios/*.cue) that name it in `flags` or a step's `flag`,
# which of them are marked `production`, and the unit cases (tests/unit/*.cue) that name it.
def cases-of [app: path, flag: string] {
	let scen = (entries (cue-dir $app tests/scenarios scenarios) | where {|e|
		let named = ($e.v.flags? | default []) | append ($e.v.steps? | default [] | each {|st| [($st.flag? | default null), ($st.with? | default null)] } | flatten | compact)
		$flag in $named
	})
	let unit = (entries (cue-dir $app tests/unit cases) | where {|e| $flag in ($e.v.flags? | default []) })
	let prod = ($scen | where {|e| ($e.v.production? | default false) == true })
	# A production scenario that signs in (a `signIn` step) needs a tester's account, which a flip no longer has
	# (PRONTO-284): it is listed, not run.
	let signs = {|e| $e.v.steps? | default [] | any {|st| ($st.signIn? | default false) == true } }
	{flag: $flag, scenarios: ($scen | each {|e| $e.id }), production: ($prod | where {|e| not (do $signs $e) } | each {|e| $e.id }), signedIn: ($prod | where {|e| do $signs $e } | each {|e| $e.id }), unit: ($unit | each {|e| $e.id })}
}
def has-cases [c: record]: nothing -> bool { ($c.scenarios | is-not-empty) or ($c.unit | is-not-empty) }

export def cases [app: path, flag?: string] {
	let names = if $flag != null { [$flag] } else { cue-of $app flagd.document | get flags | columns }
	$names | each {|f| cases-of $app $f }
}

# The app's command, run with sh in its folder with the env given; ok and what it printed.
def run-cases [app: path, cmd: string, vars: record, --wrap: string = ""] {
	# This tool runs under the plugins tree's saytw, which exports its SAYT_VERSION. The app's own ./saytw
	# must read its own pin: with ours it starts the wrong sayt, which refuses the app's pin.
	# PRONTO_FLAGS_CASES_WRAP prefixes the app's case command (a sandbox: Studio's builder runs it in its jail, with
	# no credential in reach): `sh -c '<wrap> sh -c "$1"' sh <cmd>`, so the wrap may quote. Only a flip's own cases
	# are wrapped (--wrap, from `cases-wrap`), never the generate of a record (which a kubeconfig mirror skips).
	let r = if $wrap == "" {
		(do { cd $app; with-env $vars { ^env -u SAYT_VERSION sh -c $cmd } } | complete)
	} else {
		(do { cd $app; with-env $vars { ^env -u SAYT_VERSION sh -c $"($wrap) sh -c \"\$1\"" sh $cmd } } | complete)
	}
	{ok: ($r.exit_code == 0), out: ($r.stdout + $r.stderr | str trim), stdout: ($r.stdout | str trim)}
}

# What OFREP answers for a flag and a targetingKey (none: no context), one value per flagd that answers (null where one doesn't).
# Where the flags are mirrored to a node over ssh (flagsLive.mirrors), each flagd pod is asked itself, from the node, at its
# endpoint's address (the mirror's `flagd` Service, default "flagd", port `ofrepPort`, default 8693): the Service picks a pod at
# random and each pod's ConfigMap mount catches up on its own (kubelet's sync, a minute or two), so one pod's new answer says
# nothing of the others (2026-11-23, capture_fights). The app's door names the account from a verified session alone and drops a
# body's targetingKey (pronto-plugins#113), so the site's /ofrep/ answers every request as no account (PRONTO-257), and a node's
# flagd answers before a cache could. A client flag (`site`) is asked at the site's /ofrep/ too, the address the cases use.
# Elsewhere, the site's /ofrep/. FLAGS_OFREP_CMD stands in for the request in tests: an sh command printing the reply, a line of
# JSON for each flagd, given OFREP_URL, FLAG and TARGETING_KEY.
def ofrep-all [at: record, flag: string, key: any, client: bool]: nothing -> list<any> {
	let cmd = ($env.FLAGS_OFREP_CMD? | default "")
	let ctx = if $key == null { {} } else { {targetingKey: $key} }
	let values = {|out: string| let v = ($out | lines | where {|l| ($l | str trim) != "" } | each {|l| {v: (try { $l | from json | get -o value } catch { null })} } | get v); if ($v | is-empty) { [null] } else { $v } }
	# A kubeconfig mirror has no node to ask from (its identity has no pods/portforward): the site's /ofrep/ answers.
	let m = ($at.mirrors? | default [] | where {|x| ($x.ssh? | default null) != null } | get -o 0)
	let site = {||
		try { [(http post --content-type application/json --max-time 10sec $"($at.site)/ofrep/v1/evaluate/flags/($flag)" {context: $ctx}).value?] } catch { [null] }
	}
	try {
		if $cmd != "" {
			do $values (with-env {OFREP_URL: $at.site, FLAG: $flag, TARGETING_KEY: ($key | default "")} { ^sh -c $cmd })
		} else if $m != null {
			let kubectl = ($m.kubectl? | default 'sudo k3s kubectl')
			let svc = ($m.flagd? | default "flagd")
			let port = ($m.ofrepPort? | default 8693)
			let body = ({context: $ctx} | to json -r)
			let remote = $"for ip in $\(($kubectl) -n ($m.namespace) get endpoints ($svc) -o jsonpath='{.subsets[*].addresses[*].ip}'\); do curl -sS -m 10 -X POST -H content-type:application/json -d '($body)' http://$ip:($port)/ofrep/v1/evaluate/flags/($flag) || printf '{}'; echo; done"
			let pods = (do $values (^ssh -o BatchMode=yes -o ConnectTimeout=20 $m.ssh $remote))
			if $client and ($at.site? | default "" | is-not-empty) { $pods | append (do $site) } else { $pods }
		} else {
			do $site
		}
	} catch { [null] }
}

# The flags a write moves, as {flag, new, client}: those of `new` whose default value differs from `old`'s. A flag dropped, or one
# whose reach moves with no default moving (accounts, a fractional stage), reads the same for everyone and is no word to wait for.
def want-of [old: record, new: record]: nothing -> list<record> {
	changes-between $old $new | where {|c| $c.flag in ($new.flags | columns) and $c.to != null } | each {|c|
		{flag: $c.flag, new: $c.to, client: (($new.flags | get $c.flag | get -o metadata.flagSetId) == "client")}
	}
}

# How long a write may take to reach every flagd, in seconds: FLAGS_WAIT_SEC, else the app's flagsLive.syncSec. A node's flagd
# reads a ConfigMap its pod mounts, which kubelet refreshes every minute and a cache holds up to another, plus flagd's own 5 s
# poll of the file's stat: 180 covers it. The wait for pickup, and a staged push's settle, give up there.
def sync-sec [at: record]: nothing -> float {
	$env.FLAGS_WAIT_SEC? | default ($at.syncSec? | default 180) | into float
}

# Waits until every flagd answers each flag's written value for everyone (no context), polling every FLAGS_POLL_SEC (2), and
# fails with a named error where `sync-sec` passes first. Where the site's /ofrep/ is all there is to ask (no mirror, no stand-in),
# a flag it does not serve (not `client`) is not waited for: PRONTO-1518.
export def await-live [at: record, want: list<record>] {
	let poll = ($env.FLAGS_POLL_SEC? | default 2 | into float)
	let limit = (sync-sec $at)
	let by_door = (($at.mirrors? | default [] | where {|x| ($x.ssh? | default null) != null } | is-empty) and (($env.FLAGS_OFREP_CMD? | default "") == ""))
	if $by_door and ($at.site? | default "" | is-empty) { print "flags: no site to ask and no node: the new value is not waited for"; return }
	let hidden = if $by_door { $want | where {|w| not $w.client } } else { [] }
	if ($hidden | is-not-empty) { print $"flags: ($hidden | get flag | str join ', ') is not a client flag: the site's /ofrep/ does not serve it, so its new value is not waited for there" }
	let want = ($want | where {|w| $w not-in $hidden })
	let start = (date now)
	mut pending = $want
	loop {
		$pending = ($want | where {|w| not (ofrep-all $at $w.flag null $w.client | all {|v| $v == $w.new }) })
		if ($pending | is-empty) { return }
		if ((date now) - $start) >= ($limit * 1sec) { break }
		sleep ($poll * 1sec)
	}
	error make {msg: $"flagd did not pick up ($pending | each {|w| $'($w.flag)=($w.new | to json -r)' } | str join ', ') within (($limit | math round))s"}
}

# Why a green run of a flag's production cases proved nothing, or "" when it showed the flag at work. The runner
# (apps' tests/scenarios.ts) prints one verdict per scenario: `✓ <id> (<n>s): <accepts>`, and where it skipped
# steps behind a flag that is off at the door, `; steps behind <flag>, ... skipped, off here`. A run that prints
# no verdict ran nothing (cached, or every scenario skipped); one whose verdict says the flipped flag's steps
# were skipped saw the flag off, so the door never served the new value. A runner that prints
# `; <n> steps run, <m> skipped` counts them: none run is nothing shown.
# `flag` "" skips the skipped-flag check (the verdict and step-count checks stay).
def vacuous [out: string, flag: string]: nothing -> string {
	let verdicts = ($out | lines | where {|l| $l | str starts-with "✓ " })
	if ($verdicts | is-empty) { return "the runner printed no passed scenario, so no step ran" }
	for l in $verdicts {
		let id = ($l | str replace -r '^✓ (\S+).*$' '$1')
		let off = ($l | parse -r 'steps behind (?<fl>.+?) skipped, off here' | get -o 0.fl | default "" | split row "," | each {|f| $f | str trim })
		if $flag != "" and $flag in $off { return $"($id) skipped its steps behind ($flag): the site still evaluates it off" }
		let n = ($l | parse -r '(?<run>\d+) steps run, (?<skip>\d+) skipped' | get -o 0)
		if $n != null and ($n.run | into int) == 0 { return $"($id) ran no step \(($n.skip) skipped\)" }
	}
	""
}

# The version a push read, written again as the newest after a failed live stage.
def restore [at: record, app: path, to: string, now: string, names: string, why: string] {
	# The text read before the flip, byte for byte: it is seconds old, so it needs no metadata of the spec's (PRONTO-1755).
	let again = (commit $at $app (store-version $at $to) {stage: rolled-back, flag: $names, cases: failed, note: ($why | str substring 0..<500)} $now)
	print -e $"flags: ($at.url) is version ($to)'s flags again, as version ($again)"
	# The restore is confirmed live, as the write was: until every flagd says the old value, the flag is still on for some.
	try { await-live $at (want-of (store-version $at $now | from json) (store-version $at $to | from json)) } catch {|e| print -e $"flags: ERROR: version ($again) holds version ($to)'s flags but a flagd does not say so yet: ($e.msg); check the flagd pods" }
}

# After a write that has no cases to run (or before a watch opens): every flagd must say its new value, else the version read before
# is written again from `written`, the generation just written, and the push fails. A flag no flagd reads is no flip to leave on.
def live-or-restore [at: record, app: path, old: record, doc: record, before: string, written: string, names: string] {
	try { await-live $at (want-of $old $doc) } catch {|e|
		try { restore $at $app $before $written $names $e.msg } catch {|r| print -e $"flags: WARNING: could not restore version ($before): ($r.msg); `pronto-flags rollback` does" }
		error make {msg: $"rolled back to version ($before): ($e.msg)"}
	}
}

# ---- The watch (PRONTO-413): guardrails sampled over a window after a flip, a breach written back ----

# "30m" as a duration.
def to-dur [s: string]: nothing -> duration {
	let n = ($s | str substring 0..<-1 | into int)
	match ($s | str substring (-1)..) { "s" => ($n * 1sec), "m" => ($n * 1min), _ => ($n * 1hr) }
}

# The watch a push holds after a flip: null where the app names no guardrail. --watch (`over`) says the window;
# FLAGS_WATCH_SEC, FLAGS_WATCH_MAX_SEC and FLAGS_WATCH_SAMPLE_SEC stand in for the spec's in tests.
def guard-of [at: record, over: any]: nothing -> any {
	let list = ($at.guardrails? | default [])
	if ($list | is-empty) { return null }
	if $over != null and not ($over =~ '^[1-9][0-9]*[smh]$') { error make {msg: $"flags: --watch ($over): say a window like 10m, 90s or 1h; nothing was written"} }
	let secs = {|name, spec| let e = ($env | get -o $name | default ""); if $e != "" { ($e | into float) * 1sec } else { to-dur $spec } }
	let window = if $over != null { to-dur $over } else { do $secs FLAGS_WATCH_SEC ($at.watch? | default "30m") }
	let max = (do $secs FLAGS_WATCH_MAX_SEC ($at.watchMax? | default "2h"))
	{list: $list, watch: $window, max: ([$max $window] | math max), sample: (do $secs FLAGS_WATCH_SAMPLE_SEC ($at.sample? | default "5m")), min: ($at.minSessions? | default 50)}
}

# A reader's word for the window so far, and the same hours a day before: its last line of output, as JSON.
# A reader that fails, or prints no value, is an error: a flip nobody can see is no flip to leave on.
def read-guard [app: path, g: record, flag: string, stage: string, from: datetime, to: datetime, wrap: string]: nothing -> record {
	let iso = {|d: datetime| $d | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ" }
	let vars = {FLAG: $flag, STAGE: $stage, GUARDRAIL: $g.name, WINDOW_START: (do $iso $from), WINDOW_END: (do $iso $to), BASELINE_START: (do $iso ($from - 1day)), BASELINE_END: (do $iso ($to - 1day))}
	let r = (run-cases $app $g.cmd $vars --wrap $wrap)
	if not $r.ok { error make {msg: $"the reader of ($g.name) failed: ($r.out | lines | last 2 | str join ' / ' | str substring 0..<300)"} }
	let j = (try { $r.stdout | lines | last | from json } catch { null })
	if ($j | describe | str starts-with "record") == false or ($j | get -o value | describe) not-in ["int" "float"] { error make {msg: $"the reader of ($g.name) printed no {\"value\": n} last line"} }
	if $g.kind != "probe" and ($j | get -o baseline | describe) not-in ["int" "float"] { error make {msg: $"the reader of ($g.name) printed no baseline: a reading with nothing to compare to proves nothing \(0 is a baseline\)"} }
	if $g.kind != "probe" and ($j | get -o sessions | describe) not-in ["int" "float"] { error make {msg: $"the reader of ($g.name) printed no sessions: a window with no count of its traffic proves nothing"} }
	$j
}

# One reading against its guardrail: breach (text, or "") and the sessions it rests on (null for a probe).
def judge [g: record, r: record]: nothing -> record {
	let v = $r.value
	let b = ($r.baseline? | default 0)
	let breach = match $g.kind {
		"errors" => (if $v > $b * $g.maxRatio and ($v - $b) > $g.floor { $"($g.name): ($v) errors against ($b) the day before \(more than ($g.maxRatio)x and ($g.floor) over\)" } else { "" })
		"probe" => (if $v > 0 { $"($g.name): ($v) probe journeys failed" } else { "" })
		_ => (if $b > 0 and $v < $b * $g.minRatio and ($b - $v) > $g.floor { $"($g.name): ($v) against ($b) the day before \(under ($g.minRatio)x and ($g.floor) below\)" } else { "" })
	}
	{breach: $breach, sessions: (if $g.kind == "probe" { null } else { $r.sessions }), text: $"($g.name)=($v)/($b)"}
}

# Before any write: each reader is run once over no time, and a missing or failing one refuses the push.
def guard-check [app: path, guard: any, wrap: string] {
	if $guard == null { return }
	let now = (date now)
	for g in $guard.list {
		try { read-guard $app $g "-" "check" $now $now $wrap | ignore } catch {|e| error make {msg: $"flags: ($e.msg); a guardrail whose reader cannot be run is refused, never read as no breach; nothing was written"} }
	}
}

# Watches a flip: samples every guardrail each `sample` until `watch` has passed with enough sessions. `breach` on the
# first breach (its reading the reason); `inconclusive` when `max` passes with too few sessions; else `pass`. A reader that fails
# is a breach too. The readings come back as one line, for the version and the journal.
def watch-window [app: path, guard: any, flag: string, stage: string, wrap: string]: nothing -> any {
	let start = (date now)
	mut text = ""
	loop {
		sleep $guard.sample
		let now = (date now)
		let read = ($guard.list | each {|g| try { judge $g (read-guard $app $g $flag $stage $start $now $wrap) } catch {|e| {breach: $e.msg, sessions: null, text: $"($g.name)=unreadable"} } })
		$text = $"watch ($stage) ($now - $start | format duration sec): ($read.text | str join ' ')"
		let breaches = ($read | where breach != "" | get breach)
		if ($breaches | is-not-empty) { return {verdict: breach, text: $"($text); ($breaches | str join '; ')"} }
		let thin = ($read | where {|x| $x.sessions != null and $x.sessions < $guard.min })
		if ($now - $start) >= $guard.watch and ($thin | is-empty) { return {verdict: pass, text: $text} }
		if ($now - $start) >= $guard.max { return {verdict: inconclusive, text: $"($text); fewer than ($guard.min) sessions in ($guard.max): too little to say"} }
	}
}

# The production check (PRONTO-439, the owner, 2026-11-12: "When you implement new features, always implement with the
# production check verification"). Asked only of a flag whose value moves from off to on: a bool default that was false
# (or is new to the live object) and is now true. A data flag (a string or a number), a flag already on whose accounts or
# targeting change, and a flag turned off are never asked. Such a flip needs a `production` scenario naming the flag that
# needs no sign-in (a signed-in one is listed, not run), or the owner's words in the flag's `liveWaived`. --untested
# answers for cases alone and never stands in for this: the production check is what a flip is for, and a waiver is the
# owner's to give, not the operator's flag to type. Refuses with nothing written; else the waiver notes for the journal.
# A dry run calls it too, so it never reports a push the real run refuses.
def production-check [app: path, old: record, doc: record, changed: list<string>]: nothing -> list<string> {
	let asked = ($changed | where {|f|
		let now = ($doc.flags | get $f)
		(default-of $now) == true and (default-of ($old.flags | get -o $f)) != true and not (fully-off $now)
	} | each {|f| cases-of $app $f } | where {|c| $c.production | is-empty })
	if ($asked | is-empty) { return [] }
	let spec_flags = (cue-of $app flags | default {})
	let waivers = ($asked | each {|c| {flag: $c.flag, why: ($spec_flags | get -o $c.flag | default {} | get -o liveWaived | default "")} })
	let unchecked = ($waivers | where why == "" | get flag)
	if ($unchecked | is-not-empty) {
		error make {msg: $"a push turns on ($unchecked | str join ', '), which goes from off to on with no production check: a feature ships with a live, anonymous, read-only check of itself. Either add a scenario with `production: true` naming the flag in `flags` \(tests/scenarios/*.cue; skills/pronto-issue/SKILL.md, step 2; flags/README.md\), or set `liveWaived` in the flag's spec to the owner's words waiving it, copied from the owner and never written by an agent: in flags_spec.cue, or in the source it is generated from \(an app whose flags_spec.cue is generated, like aprende's from spec/flags.cue, carries it there\). --untested does not waive it. Nothing written."}
	}
	$waivers | each {|w| $"live check waived for ($w.flag): ($w.why)" }
}

# Changes the live flags, for everyone at once, in one version (the owner, 2026-11-11: "drop the requirement of
# testers for flag flips"; PRONTO-284). A flip builds and launches no stack: the pull request's gate ran the flag's
# cases at hand, every flag being on there.
#   0. a flag that goes on needs a `production` scenario naming it, or the owner's `liveWaived` in the spec (PRONTO-439), --untested or not;
#   1. a flag whose reach changes (default, accounts or targeting) or that is new and not off needs cases (`cases`: scenarios or unit cases that name
#      it); with none the push is refused, or goes on with --untested "<why>";
#   2. the flags as the spec says them are written (stage=all);
#   3. where a changed flag has `production` scenarios that need no tester (no `signIn` step), the push waits until
#      OFREP says the new value, runs them against production (flagsCases.live, APP_URL=flagsLive.url), and a
#      failure writes the version read before 2 again, and the push fails. So does a green run that showed nothing
#      (`vacuous`: no scenario verdict, or the flag's own steps skipped as off at the door). A production scenario that signs in
#      needs a tester's account, which a flip no longer has: it is listed and not run.
# A flag turned fully off (default false, no accounts) runs no cases: it returns to the path before it, and its cases test it on.
export def push [app: path, --untested: string, --no-canary: string, --expect: string, --flip: list<string> = [], --drop: list<string> = [], --sync: list<string> = [], --stages: list<int> = [], --dwell: duration = 10min, --keyed: string, --watch: string, --several: string] {
	pin-guard $app
	let at = (live $app)
	if $watch != null and (($at.guardrails? | default []) | is-empty) { error make {msg: "flags: --watch: the app names no flagsLive.guardrails to watch; nothing was written"} }
	let stuck = (unfinished-watch $at)
	if $stuck != null { error make {msg: $"flags: version ($stuck.generation) is an unfinished watch \(its process died, or another push's watch is still running): `pronto-flags watch --resume <app-dir>` takes it up, `pronto-flags rollback <app-dir> ($stuck.metadata | get -o before | default '<version before the push>')` goes back; nothing was written"} }
	if (target-guard $at $expect) {
		show $app --flip $flip --drop $drop --sync $sync
		# A staged push is checked as the real one is (its refusals), writing nothing.
		# The production check is asked of a dry run too.
		let dm = (merge-live $at $app (cue-of $app flagd.document) $flip $drop $sync)
		push-guard $dm.old $dm.doc $flip $sync $drop ($dm.dropped | get flag) $several
		production-check $app $dm.old $dm.doc (changed-flags $dm.old $dm.doc) | ignore
		# The watch's refusals too: a bad --watch, or a reader that cannot be run.
		let dg = (guard-of $at $watch)
		if $dg != null { guard-check $app $dg (cases-wrap $at) }
		if ($stages | is-not-empty) {
			let st = (staged-checks $stages $flip $sync (changed-flags $dm.old $dm.doc) $dm.doc $dm.old $keyed)
			print $"flags: dry run: ($st.flag) would go to ($stages | each {|s| $'($s)%' } | str join ', '), by targetingKey, from ($st.oldv)"
		}
		print "flags: dry run: nothing written"
		return
	}
	let spec = (cue-of $app flagd.document)
	# The spec merged over the live flags: what is not this push's to change stays as it is live (see `keep-live`).
	let m = (merge-live $at $app $spec $flip $drop $sync)
	let doc = $m.doc
	let before = $m.before
	let old = $m.old
	let kept = (merge-meta $m)
	# The flags this push writes on purpose: the only ones it records back into the spec.
	let owned = ($flip | each {|e| $e | split row "=" | first } | append $sync | uniq)
	push-guard $old $doc $flip $sync $drop ($m.dropped | get flag) $several
	let changed = (changed-flags $old $doc)
	let staged = if ($stages | is-not-empty) { staged-checks $stages $flip $sync $changed $doc $old $keyed } else { null }
	if ($changed | is-empty) {
		let v = (write-flags $at $doc $app --meta ({stage: all} | merge $kept) --from $before)
		if ($flip | is-not-empty) { record-back $at $app $v "none" $owned | ignore }
		return
	}
	# --no-canary was the way past the testers' stage (pronto-plugins#184); every push is that way now.
	if $no_canary != null { print -e "flags: --no-canary is every push's way now (PRONTO-284); its reason is kept in the journal" }
	# A flag turned fully off (its default false, no accounts) returns to the path the app ran before it went on; its
	# cases test it on (2026-11-08, card_chess: the user's "Rollback card game"). No cases run.
	let off = ($changed | where {|f| fully-off ($doc.flags | get $f) })
	if ($off | is-not-empty) { print -e $"flags: ($off | str join ', ') turned off: no cases run \(they test the flag on\)" }
	let all = ($changed | where {|f| $f not-in $off } | each {|f| cases-of $app $f })
	let bare = ($all | where {|c| not (has-cases $c) } | each {|c| $c.flag })
	if ($bare | is-not-empty) and $untested == null {
		error make {msg: $"a push changes ($bare | str join ', '), which has no cases: name the flag in a scenario's `flags` \(tests/scenarios/*.cue\) or a unit case's \(tests/unit/*.cue\); `pronto-flags cases` lists them; or push with --untested \"<why>\""}
	}
	let live = ($all | where {|c| $c.production | is-not-empty })
	let waived = (production-check $app $old $doc $changed)
	let cmds = (cue-of $app flagsCases | default {})
	if ($live | is-not-empty) and (($at.site | default "" | is-empty) or ($cmds.live? | default "" | is-empty)) {
		error make {msg: $"($live | get flag | str join ', ') has production cases: say flagsLive.url and flagsCases.live, which run them on production after the flip"}
	}
	for c in ($all | where {|c| $c.signedIn | is-not-empty }) {
		print -e $"flags: ($c.flag): not run, they sign in as a tester a flip no longer has: ($c.signedIn | str join ', ')"
	}
	let names = ($changed | str join "+")
	# The board hears of default moves only: accounts added to a flag are no flip an issue is done by.
	let moved = (changes-between $old $doc | where {|c| $c.flag in ($doc.flags | columns) and $c.flag not-in ($m.dropped | get flag) })
	let notes = ([(if $several != null { $"several: ($several)" }) (if $untested != null { $"untested: ($untested)" }) (if $no_canary != null { $"no canary: ($no_canary)" }) (if ($off | is-not-empty) { $"turned off: ($off | str join ', ')" }) (if ($waived | is-not-empty) { $waived | str join "; " })] | compact | str join "; ")
	if $untested != null and ($bare | is-not-empty) { print -e $"flags: WARNING: ($bare | str join ', ') pushed with NO CASES: ($untested)" }
	let guard = if ($all | is-empty) { null } else { guard-of $at $watch }
	if $guard != null { guard-check $app $guard (cases-wrap $at) }
	let cases_none = if ($bare | is-not-empty) { "untested" } else { "none on production" }
	if $staged != null {
		let verdict = if ($live | is-empty) { $cases_none } else { "passed" }
		let v = (staged-live $at $app $doc $staged $live $cmds $before $stages $dwell ({flag: $names, note: $notes} | merge $kept) $cases_none $guard)
		tell-board $at $app $moved
		record-back $at $app $v $verdict $owned | ignore
		return
	}
	if ($live | is-empty) {
		let cases = $cases_none
		let meta = ({stage: all, flag: $names, cases: $cases, note: $notes} | merge $kept)
		# A watched flip's first version is already `watching`: no version of it reads finished before its verdict.
		# Written, then live on every flagd: a flag with no cases to run is still waited for, and a flip that is not live in time fails the push.
		let v = if $guard == null { let w = (write-flags $at $doc $app --meta $meta --from $before); live-or-restore $at $app $old $doc $before $w $names; $w } else { watch-flip $at $app $doc $names $before $before $meta $guard (cases-wrap $at) $cases }
		tell-board $at $app $moved
		if ($flip | is-not-empty) { record-back $at $app $v $cases $owned | ignore }
		return
	}
	# Not `try ... finally`: nu runs what follows it and raises the error only at the end, so a failed flip
	# told the board its flags were on for everyone (PRONTO-15 Done at 18:02 BRT, 2026-11-08; PRONTO-43).
	let v = (flip-live $at $app $doc $live $cmds $before ({stage: all, flag: $names, note: $notes} | merge $kept) --guard $guard)
	tell-board $at $app $moved
	if ($flip | is-not-empty) { record-back $at $app $v "passed" $owned | ignore }
}

# The flags whose entry differs between the live flags `old` and the document `doc` a push would write: a push that names
# a flag or drops one (`whole`) compares whole entries, metadata included; a plain push, which writes the spec's definitions on purpose,
# compares reach. A new flag written fully off moves nothing.
def entries-moved [old: record, doc: record, whole: bool]: nothing -> list<string> {
	let a = ($old.flags? | default {})
	let b = ($doc.flags? | default {})
	($a | columns) | append ($b | columns) | uniq | where {|f|
		let x = ($a | get -o $f)
		let y = ($b | get -o $f)
		if $y == null { true } else if $x == null { not (fully-off $y) } else if $whole { $x != $y } else { (reach $x) != (reach $y) }
	}
}

# Before anything is written (PRONTO-1755, PRONTO-415): a push moves only the flags it names (--flip, --sync) or drops
# (--drop, or the release record), whatever keep-live builds, and a push that moves more than one flag says why (--several).
export def push-guard [old: record, doc: record, flip: list<string>, sync: list<string>, drop: list<string>, dropped: list<string>, several: any] {
	let owned = ($flip | each {|e| $e | split row "=" | first } | append $sync | uniq)
	let stray = (entries-moved $old $doc (($owned | is-not-empty) or ($drop | is-not-empty)) | where {|f| $f not-in $owned and $f not-in $dropped })
	if ($stray | is-not-empty) { error make {msg: $"flags: a push moves ($stray | str join ', ') that no --flip or --sync names: nothing written"} }
	let moving = if ($owned | is-empty) { [] } else { changed-flags $old $doc }
	if ($moving | length) > 1 and $several == null { error make {msg: $"flags: this push moves ($moving | length) flags \(($moving | str join ', ')\): flip one at a time, or say --several \"<why>\"; nothing was written"} }
}

# What a staged push (`--stages`) checks before it writes anything, and the flag it stages with the value it reads now.
# One flag, named by a single --flip, whose value moves (a flag turned off needs no stages), read by readers that all carry
# a targetingKey: flagd's fractional buckets by it and, with none, answers the default variant. A `client` flag is read by pages,
# some of which have no session and so no key; --keyed "<why>" says they all do.
def staged-checks [stages: list<int>, flip: list<string>, sync: list<string>, changed: list<string>, doc: record, old: record, keyed: any]: nothing -> record {
	let bad = {|why| error make {msg: $"flags: --stages: ($why); nothing was written"} }
	if ($stages | any {|s| $s < 1 or $s > 100 }) or ($stages | sort | uniq) != $stages or ($stages | last) != 100 { do $bad "say the percentages rising and ending at 100, e.g. 5,25,100" }
	if ($flip | length) != 1 or ($sync | is-not-empty) { do $bad "it stages one flag, named by a single --flip (no --sync)" }
	let flag = ($flip | first | split row "=" | first)
	if $changed != [$flag] { do $bad $"it would change ($changed | str join ', '); a staged push changes the one flag it names" }
	let new = ($doc.flags | get $flag)
	if (fully-off $new) { do $bad $"($flag) is turned off, which needs no stages" }
	let was = ($old.flags | get -o $flag)
	let newv = (default-of $new)
	let oldv = if $was != null { default-of $was } else if ($newv | describe) == "bool" { false } else { null }
	if $oldv == null { do $bad $"($flag) is new and not a bool, so it has no off value to stage from" }
	if $oldv == $newv { do $bad $"($flag) is already ($newv) live: only its accounts or targeting would move" }
	if ($new | get -o metadata.flagSetId) == "client" and $keyed == null {
		do $bad $"($flag) is a client flag, read by pages: one with no session sends no targetingKey, and a fractional rule answers it the default. Say --keyed \"<why every reader has a key>\" if they all do"
	}
	{flag: $flag, oldv: $oldv}
}

# A flag's entry at a stage: the generated at-hand and accounts branches as they were, then flagd's fractional on
# targetingKey, `on` (the new value) for w percent of players and `off` (the value before) for the rest. A reader with no
# targetingKey, and the default variant, read the value before.
def stage-def [new: record, oldv: any, w: int]: nothing -> record {
	let r = (reach $new)
	let local = ($new.variants? | default {} | get -o local)
	let base = {default: $oldv, on: (default-of $new), off: $oldv}
	let variants = if $local == null { $base } else { $base | insert local $local }
	mut branches = []
	if ($r.hosts | is-not-empty) { $branches = ($branches | append [{"in": [{"var": "host"}, $r.hosts]}, "local"]) }
	if ($r.accounts | is-not-empty) { $branches = ($branches | append [{"in": [{"var": "targetingKey"}, $r.accounts]}, "local"]) }
	let split = {fractional: [["on", $w], ["off", (100 - $w)]]}
	let rule = if ($branches | is-empty) { $split } else { {"if": ($branches | append $split)} }
	$new | upsert variants $variants | upsert defaultVariant "default" | upsert targeting $rule
}

# The staged live push: each stage below 100 is a version of its own (`stage` 5%), then its settle (FLAGS_STAGE_SETTLE_SEC, the
# sync bound: a cohort reads the same for everyone with no key, so no answer shows the stage live), the flag's production cases as the players outside the cohort, who read the
# value before, and the dwell; the last stage is the flip (`flip-live`: everyone, OFREP's word, the cases). Where a stage's
# cases fail, or anything else does, the version read before the first stage is written again, not the previous stage's.
# Guardrails that watch the dwell (PRONTO-413) plug in after a stage's cases.
def staged-live [at: record, app: path, doc: record, st: record, live: list<record>, cmds: record, before: string, stages: list<int>, dwell: duration, meta: record, none: string, guard: any] {
	let wrap = (cases-wrap $at)
	let settle = ($env.FLAGS_STAGE_SETTLE_SEC? | default (sync-sec $at) | into float)
	# Each write is over the generation the one before returned (the first, over the one read before the push), so a write
	# another operator makes during a dwell (a rollback, a kill switch) fails ours instead of being overwritten.
	mut last = $before
	mut last_doc = $doc
	mut fail = ""
	for w in ($stages | where {|s| $s < 100 }) {
		let from = $last
		let staged = ($doc | upsert flags ($doc.flags | upsert $st.flag (stage-def ($doc.flags | get $st.flag) $st.oldv $w)))
		let wrote = (try { {gen: (write-flags $at $staged $app --meta ($meta | upsert stage $"($w)%" | upsert cases (if $guard == null { "staged" } else { "watching" }) | upsert before $before) --from $from)} } catch {|e| {err: ($e.msg | lines | first)} })
		if ($wrote | get -o err) != null { $fail = $wrote.err; break }
		$last = $wrote.gen
		$last_doc = $staged
		print $"flags: ($st.flag) is on for ($w)% of players, by targetingKey; settling ($settle)s"
		let held = (try {
			sleep ($settle * 1sec)
			for c in $live {
				print $"flags: ($c.flag) at ($w)%: running its production cases \(($c.production | str join ', ')\)"
				let r = (run-cases $app $cmds.live {FLAG: $c.flag, ONLY: ($c.production | str join ","), APP_URL: $at.site} --wrap $wrap)
				if not $r.ok { error make {msg: $"($c.flag)'s production cases failed at ($w)%:\n($r.out)"} }
				let empty = (vacuous $r.out "")
				if $empty != "" { error make {msg: $"($c.flag)'s production cases showed nothing at ($w)%: ($empty)"} }
			}
			print $"flags: ($st.flag) dwells ($dwell) at ($w)%"
			sleep $dwell
			""
		} catch {|e| $e.msg })
		if $held != "" { $fail = $held; break }
		# The guardrails over the stage: a breach restores, too little traffic stops here with the stage left on.
		if $guard != null {
			let r = (watch-window $app $guard $st.flag $"($w)%" $wrap)
			print $"flags: ($r.text)"
			if $r.verdict == "breach" { $fail = $"guardrail breach: ($r.text)"; break }
			if $r.verdict == "inconclusive" { $fail = $"watch-inconclusive: ($r.text)"; break }
		}
	}
	let last_gen = $last
	let restore_all = {|why|
		try { restore $at $app $before $last_gen $st.flag ($why | lines | first) } catch {|r| print -e $"flags: WARNING: could not restore version ($before): ($r.msg); `pronto-flags rollback` does" }
		error make {msg: $"rolled back to version ($before): ($why)"}
	}
	if ($fail | str starts-with "watch-inconclusive") {
		write-flags $at $last_doc $app --meta ($meta | upsert stage watch-inconclusive | upsert cases inconclusive | upsert reading ($fail | str replace "watch-inconclusive: " "") | upsert before $before) --from $last | ignore
		error make {msg: $"($fail); the flag is left at its last stage, for the release engineer to decide: `pronto-flags rollback <app-dir> ($before)` turns it back, or push again with a longer --watch"}
	}
	if $fail != "" { do $restore_all $fail }
	let meta = ($meta | upsert stage all)
	# The last stage is the flip. flip-live rolls itself back from its own write on; a failure of its first write, or of the
	# write with no cases to run, leaves live at the last stage, so it is restored here.
	try {
		if ($live | is-empty) {
			let v = (write-flags $at $doc $app --meta ($meta | upsert cases $none) --from $last_gen)
			live-or-restore $at $app $last_doc $doc $before $v $st.flag
			if $guard == null { $v } else { watch-flip $at $app $doc $st.flag $before $v ($meta | upsert cases $none) $guard $wrap $none }
		} else { flip-live $at $app $doc $live $cmds $before $meta --from $last_gen --guard $guard }
	} catch {|e|
		if ($e.msg | str starts-with "rolled back to version") or ($e.msg | str starts-with "watch-inconclusive") { error make {msg: $e.msg} }
		do $restore_all $e.msg
	}
}

# The dev flow's board, where the app's repository keeps one (its devflow/devflow.cue; devflow/README.md): the
# issues whose flag went on for everyone are Done, those whose flag went off are Live again. Never fails the push.
def tell-board [at: record, app: path, moved: list<record>] {
	if (is-dir $at) { return }
	let on = ($moved | where {|c| $c.to != false } | get flag)
	let off = ($moved | where {|c| $c.to == false } | get flag)
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

# After a flip's cases (or a flip with none): the version is written `cases: watching` first, so a watch that dies shows in
# `history` and refuses the next push; then the guardrails are watched. A breach writes the version before the push again, with the
# reading as its reason (`restore`), and fails the push; too little traffic by `watchMax` writes `watch-inconclusive`, leaves the flag
# on and fails the push, never green; a pass writes the final version (`final`) with the readings. The generation returned is the last.
def watch-flip [at: record, app: path, doc: record, names: string, before: string, from: string, meta: record, guard: record, wrap: string, final: string] {
	let w = (write-flags $at $doc $app --meta ($meta | upsert cases watching | upsert before $before | upsert final $final) --from $from)
	# Live on every flagd before the window opens: readings of a flag some pods still read off would pass it unseen.
	live-or-restore $at $app (store-version $at $before | from json) $doc $before $w $names
	let r = (watch-window $app $guard $names ($meta.stage? | default all) $wrap)
	print $"flags: ($r.text)"
	match $r.verdict {
		"pass" => { write-flags $at $doc $app --meta ($meta | upsert cases $final | upsert reading $r.text) --from $w }
		"breach" => {
			try { restore $at $app $before $w $names $"guardrail breach: ($r.text)" } catch {|e| print -e $"flags: WARNING: could not restore version ($before): ($e.msg); `pronto-flags rollback` does" }
			error make {msg: $"rolled back to version ($before): guardrail breach: ($r.text)"}
		}
		_ => {
			write-flags $at $doc $app --meta ($meta | upsert stage watch-inconclusive | upsert cases inconclusive | upsert reading $r.text | upsert before $before) --from $w | ignore
			error make {msg: $"watch-inconclusive: ($r.text); the flag is left on, for the release engineer to decide: `pronto-flags rollback <app-dir> ($before)` turns it back, or push again with a longer --watch"}
		}
	}
}

# The live version, when its watch never finished: written `watching` and never followed by a verdict.
def unfinished-watch [at: record]: nothing -> any {
	let cur = (try { store-versions $at | where {|v| $v.timeDeleted == null } | get -o 0 } catch { null })
	if $cur != null and (($cur.metadata | get -o cases | default "") == "watching") { $cur } else { null }
}

# Takes up a watch that died: the whole window again over the live version, which a breach writes the version before it back from.
export def watch-resume [app: path, --expect: string] {
	pin-guard $app
	let at = (live $app)
	if (target-guard $at $expect) { print "flags: dry run: nothing written"; return }
	let guard = (guard-of $at null)
	if $guard == null { error make {msg: "flags: the app names no flagsLive.guardrails: nothing to watch"} }
	let cur = (unfinished-watch $at)
	if $cur == null { error make {msg: "flags: the live version is no unfinished watch: nothing to resume"} }
	let m = $cur.metadata
	if (($m | get -o stage | default "") | str ends-with "%") { error make {msg: $"flags: the unfinished watch is a stage of a staged push \((($m | get -o stage))\): it is not resumed; `pronto-flags rollback <app-dir> (($m | get -o before | default '<version before the push>'))` goes back"} }
	let prev = ($m | get -o before)
	if $prev == null { error make {msg: "flags: the unfinished watch names no version before the push to go back to: `pronto-flags rollback` with a version"} }
	guard-check $app $guard (cases-wrap $at)
	let doc = (store-version $at $cur.generation | from json)
	watch-flip $at $app $doc ($m | get -o flag | default "") $prev $cur.generation ({stage: ($m | get -o stage | default all), flag: ($m | get -o flag | default ""), note: "watch resumed"}) $guard (cases-wrap $at) ($m | get -o final | default passed) | ignore
	print -e "flags: the resumed watch passed; the board was not told and the spec was not recorded back from the original push: tell it and flip the spec by hand"
}

# The live stage: the flags written for everyone, OFREP's word, then the production cases that need no tester, as
# no one in particular. Whatever fails after the write, an error or a crash of the cases' command, writes the
# version read before it again.
def flip-live [at: record, app: path, doc: record, live: list<record>, cmds: record, before: string, meta: record, --from: string = "", --guard: any = null] {
	let on = ($live | get flag)
	let wrap = (cases-wrap $at)
	let v = (write-flags $at $doc $app --meta ($meta | insert cases running) --from (if $from == "" { $before } else { $from }))
	print $"flags: ($on | str join ', ') is on for everyone; waiting for every flagd to say so"
	let ran = (try {
		# Every flagd, and the site's /ofrep/ for a client flag, must say the new value before a case reads it: a pod that
		# has not caught up would answer a case with the old one and roll a correct flip back (2026-11-23, capture_fights).
		await-live $at (want-of (store-version $at $before | from json) $doc)
		for c in $live {
			print $"flags: ($c.flag): running its production cases \(($c.production | str join ', ')\)"
			let r = (run-cases $app $cmds.live {FLAG: $c.flag, ONLY: ($c.production | str join ","), APP_URL: $at.site} --wrap $wrap)
			if not $r.ok { error make {msg: $"($c.flag)'s production cases failed:\n($r.out)"} }
			# The skipped-flag check is for a flag now on for everyone: with accounts only, or turned off, the runner
			# legitimately skips the steps behind it.
			let on_for_all = ((default-of ($doc.flags | get $c.flag)) == true)
			let empty = (vacuous $r.out (if $on_for_all { $c.flag } else { "" }))
			if $empty != "" { error make {msg: $"($c.flag)'s production cases showed nothing: ($empty)"} }
		}
		$v
	} catch {|e|
		try { restore $at $app $before $v ($on | str join "+") ($e.msg | lines | first) } catch {|r| print -e $"flags: WARNING: could not restore version ($before): ($r.msg); `pronto-flags rollback` does" }
		error make {msg: $"rolled back to version ($before): ($e.msg)"}
	})
	if $guard == null { write-flags $at $doc $app --meta ($meta | insert cases passed) --from $ran } else { watch-flip $at $app $doc ($on | str join "+") $before $ran $meta $guard $wrap passed }
}

# Every version of the object, newest first: when it was written, when a newer one replaced it, and what
# its write kept. --changes adds, to each, the flags whose default value it moved against the version before
# it (null where either cannot be read); it reads every version, so history asks for it only as JSON.
export def history [app: path, --changes] {
	let at = (live $app)
	let rows = (store-versions $at
	| each {|o| {version: $o.generation, at: $o.timeCreated, live: ($o.timeDeleted? == null), by: ($o.metadata?.pushed-by? | default ""), commit: ($o.metadata?.commit? | default ""), plugin: ($o.metadata?.plugin? | default ""), stage: ($o.metadata?.stage? | default ""), flag: ($o.metadata?.flag? | default ""), cases: ($o.metadata?.cases? | default ""), note: ($o.metadata?.note? | default "")}}
	| sort-by {|v| $v.version | into int } --reverse)
	if not $changes { return $rows }
	let docs = ($rows | reverse | each {|r| try { store-version $at $r.version | from json } catch { null } })
	$rows | reverse | enumerate | each {|e|
		let cur = ($docs | get $e.index)
		let prev = if $e.index == 0 { {flags: {}} } else { $docs | get ($e.index - 1) }
		$e.item | insert changes (if $cur == null or $prev == null { null } else { changes-between $prev $cur })
	} | reverse
}

# Records which flags the release being served reads: the names in the tree's flags/flags.json (the file the flagd
# image bakes), with the commit and the time, as released.json beside the live object. Run from the tree released
# (release-cron, once production serves it); a tree with CUE edits is refused, since it is no commit's.
export def released [app: path, --expect: string] {
	pin-guard $app
	let at = (live $app)
	target-guard $at $expect | ignore
	refuse-write $"the release record at (record-url $at)"
	# The tree's commit, and no edit to what the record is made of: the spec's CUE and flags/flags.json, as git tracks them (an
	# untracked leftover does not block it).
	let commit = (do { cd $app; ^git rev-parse --short HEAD } | complete)
	if $commit.exit_code != 0 or ($commit.stdout | str trim | is-empty) { error make {msg: $"flags: ($app) is not in a git tree: the release record names the commit released"} }
	let dirty = (do { cd $app; ^git status --porcelain --untracked-files=no -- '*.cue' flags/flags.json } | complete | get stdout | str trim)
	if ($dirty | is-not-empty) { error make {msg: $"flags: ($app) has CUE or flags.json edits: the release record is written from a clean released tree"} }
	let p = {commit: ($commit.stdout | str trim)}
	let file = ($app | path expand | path join flags flags.json)
	let names = if ($file | path exists) { open --raw $file | from json | get flags | columns } else { cue-of $app flagd.document | get flags | columns }
	record-put $at {commit: $p.commit, at: (now-utc), flags: $names}
	print $"flags: (record-url $at) names ($names | length) flags, from commit ($p.commit)"
}

# The version before the live one, or the one named, written again as the newest:
# a rollback is itself a version, which a rollback undoes.
export def rollback [app: path, version?: string, --expect: string] {
	pin-guard $app
	let at = (live $app)
	if (target-guard $at $expect) { show $app; print "flags: dry run: nothing written"; return }
	let all = (history $app)
	let live = ($all | where live | get version.0? | default "")
	let to = if $version != null { $version } else { $all | where version != $live | get version.0? }
	if $to == null or ($all | where version == $to | is-empty) { error make {msg: $"no version ($to) of ($at.url) to roll back to: `pronto-flags history` lists them"} }
	let before = if $live == "" { {flags: {}} } else { store-version $at $live | from json }
	let target = (store-version $at $to | from json)
	let again = (commit $at $app (current-metadata-text (store-version $at $to) $app) {stage: rollback, note: $"rolled back from ($live) to ($to)"} $live --derive-flag)
	print $"flags: ($at.url) is ($to)'s flags again, as version ($again)"
	# The flags a rollback turned off are rolled back for the board: their Done issues are Live again.
	tell-board $at $app (changes-between $before $target | where {|c| $c.to == false })
	record-back $at $app $again "rollback" (changes-between $before $target | get flag) | ignore
	# Confirmed live last: the rollback stands whether or not a flagd has caught up, and a wait that fails is the exit.
	print "flags: waiting for every flagd to say so"
	await-live $at (want-of $before $target)
}

# ---- Recording a flip in the spec (PRONTO-1191's sequel: a flip needs no spec PR) ----
# A flip changes production first. What is live is the truth and flags_spec.cue its record, so once the final write
# of a push or a rollback stands, the flags where the spec and the live object both hold a different default are
# written into the spec through a pull request this tool opens itself (`record-back`). A record that cannot be made
# is said loudly and noted in the journal and never fails the push, and a failed or closed record pull request never
# reverts live. `pronto-flags drift` says what the spec still lacks.

# What a record may write: of the flags `want` ({flag, value}: the version a push wrote, the flags it owns), those the
# spec holds with another default: {flag, live (the value to write), spec}.
def record-diffs [want: list<record>, spec: record]: nothing -> list<record> {
	let b = ($spec.flags? | default {})
	$want | where {|w| $w.flag in ($b | columns) } | each {|w| {flag: $w.flag, live: $w.value, spec: (default-of ($b | get $w.flag))} } | where {|d| $d.live != $d.spec }
}

# The values of the version a push (or rollback) wrote, for the flags it owns, kept only where live still holds them.
# {want: [{flag, value}], moved: [flags live no longer agrees on]}. `owned` null: every flag of the version.
def record-want [at: record, version: string, owned: any]: nothing -> record {
	let wdoc = (store-version $at $version | from json)
	let now = (store-cat $at | from json)
	let names = if $owned == null { $wdoc.flags? | default {} | columns } else { $owned | where {|f| $f in ($wdoc.flags? | default {} | columns) } }
	let rows = ($names | each {|f| {flag: $f, value: (default-of ($wdoc.flags | get $f)), live: (default-of ($now.flags? | default {} | get -o $f))} } | where {|r| $r.value != null })
	{want: ($rows | where {|r| $r.value == $r.live } | select flag value), moved: ($rows | where {|r| $r.value != $r.live } | get flag)}
}

# The text of a flag's block in flags_spec.cue with the literal of its depth-1 `default:` replaced by `value`, and
# nothing else touched. The block opens at `flags: <name>: {` in column 0, or at `<name>: {` inside a column-0 `flags: {` block, and ends at its matching `}`. Refused, with
# the text unchanged, where the block is not there exactly once, or the default is not there exactly once at depth 1,
# or is no literal (a reference, an expression): the tool does not guess what such a default means.
# A name as a regular expression's literal.
def re-escape [name: string]: nothing -> string { $name | str replace -a -r '([.\-+*?()\[\]{}|^$\\])' '\$1' }

export def splice-default [text: string, flag: string, value: any]: nothing -> string {
	let lines = ($text | split row "\n")
	let esc = (re-escape $flag)
	let tops = ($lines | enumerate | where {|l| $l.item =~ $'^flags:\s+"?($esc)"?:\s*\{' } | get index)
	# The nested shape: `<name>: {` inside a column-0 `flags: {` block, which ends at the next column-0 `}`.
	mut nested = []
	mut inside = false
	for l in ($lines | enumerate) {
		if $inside {
			if $l.item =~ '^\}' { $inside = false } else if $l.item =~ $'^\s+"?($esc)"?:\s*\{' { $nested = ($nested | append $l.index) }
		} else if $l.item =~ '^flags:\s*\{\s*(//.*)?$' { $inside = true }
	}
	let opens = ($tops | append $nested)
	if ($opens | length) != 1 { error make {msg: $"flags: record: ($flag) has ($opens | length) blocks opening `flags: ($flag): \{` in column 0 or `($flag): \{` inside `flags: \{`, not one"} }
	let rendered = match ($value | describe) {
		"bool" => { if $value { "true" } else { "false" } }
		"string" => { $value | to json }
		"int" | "float" => { $value | into string }
		_ => { error make {msg: $"flags: record: ($flag)'s value is a ($value | describe), which is no literal to write"} }
	}
	mut depth = 0
	mut closed = false
	mut hits = []
	mut i = $opens.0
	while $i < ($lines | length) and not $closed {
		let cs = ($lines | get $i | split chars)
		mut j = 0
		mut instr = false
		while $j < ($cs | length) {
			let c = ($cs | get $j)
			if $instr {
				if $c == "\\" { $j = $j + 1 } else if $c == "\"" { $instr = false }
			} else if $c == "\"" {
				$instr = true
			} else if $c == "/" and ($cs | get -o ($j + 1)) == "/" {
				break
			} else if $c == "{" {
				$depth = $depth + 1
			} else if $c == "}" {
				$depth = $depth - 1
				if $depth == 0 { $closed = true; break }
			} else if $depth == 1 and $c == "d" and (($cs | skip $j | take 8 | str join) == "default:") {
				let before = ($cs | take $j | str join | str trim --right)
				let at_start = ($before == "" or ($before | str ends-with "{") or ($before | str ends-with ","))
				let glued = ($j > 0 and (($cs | get ($j - 1)) =~ '[A-Za-z0-9_$#]'))
				if $at_start and not $glued {
					let rest = ($cs | skip ($j + 8) | str join)
					let m = ($rest | parse -r '^(?<sp>\s*)(?<lit>true|false|-?\d+(?:\.\d+)?|"(?:\\.|[^"\\])*")(?<tail>\s*(?:,.*|//.*|\}.*|$))')
					if ($m | is-empty) { $hits = ($hits | append {line: $i, lit: null}) } else {
						let from = ($j + 8 + ($m.0.sp | str length --grapheme-clusters))
						$hits = ($hits | append {line: $i, lit: $m.0.lit, from: $from, to: ($from + ($m.0.lit | str length --grapheme-clusters))})
					}
				}
			}
			$j = $j + 1
		}
		$i = $i + 1
	}
	if not $closed { error make {msg: $"flags: record: ($flag)'s block is never closed"} }
	if ($hits | length) != 1 { error make {msg: $"flags: record: ($flag) has ($hits | length) depth-1 `default:` fields in its block, not one"} }
	let h = ($hits | first)
	if $h.lit == null { error make {msg: $"flags: record: ($flag)'s default is no literal \(a reference or an expression\): it is not rewritten"} }
	let cs = ($lines | get $h.line | split chars)
	let edited = (($cs | take $h.from | str join) + $rendered + ($cs | skip $h.to | str join))
	$lines | update $h.line $edited | str join "\n"
}

def --wrapped git-in [dir: string, ...args] {
	with-env {GIT_TERMINAL_PROMPT: "0"} { ^git -C $dir ...$args | complete }
}
def git-must [r: record, what: string]: nothing -> string {
	if $r.exit_code != 0 { error make {msg: $"flags: record: ($what): ($r.stderr | str trim)"} }
	$r.stdout | str trim
}

# The branch a record is rebuilt on, one per app.
def record-branch [app: path]: nothing -> string { $"fix/flags-record-($app | path expand | path basename)" }

# The record pull request, as far as git and gh know it: {number, url, body} or null. The operator's gh, in the app's repo.
# Only a pull request from this repository by the current gh user counts: a fork's pull request of the same branch name is
# never edited, force-pushed over or closed.
def record-open-pr [repo: string, branch: string, --strict]: nothing -> any {
	let me = (do { cd $repo; ^gh api user --jq .login } | complete)
	if $me.exit_code != 0 { error make {msg: $"flags: record: gh api user: ($me.stderr | str trim)"} }
	let r = (do { cd $repo; ^gh pr list --head $branch --state open --json number,url,isCrossRepository,author,body } | complete)
	if $r.exit_code != 0 { error make {msg: $"flags: record: gh pr list: ($r.stderr | str trim)"} }
	let who = ($me.stdout | str trim)
	let same = ($r.stdout | from json | where {|p| not ($p.isCrossRepository? | default true) })
	# Another author's pull request on this branch is not ours to force-push over: with --strict it is refused.
	let others = ($same | where {|p| ($p.author?.login? | default "") != $who })
	if $strict and ($others | is-not-empty) { error make {msg: $"flags: record: ($branch) has an open pull request of another author \(($others | first | get url)\): refused, nothing was pushed"} }
	$same | where {|p| ($p.author?.login? | default "") == $who } | get -o 0
}

# The file the recorder edits, relative to the app's folder: flagsRecord.file (flags_plugin.cue), else flags_spec.cue.
# An app whose flags_spec.cue is generated names its source of truth there. Refused where it is absolute, leaves the
# app's folder, or is no file in the scratch tree.
def record-source [wapp: path, trust: record]: nothing -> string {
	let rec = (with-env $trust { cue-of $wapp flagsRecord })
	let src = if $rec == null { "flags_spec.cue" } else { $rec.file? | default "flags_spec.cue" }
	if ($src | str starts-with "/") or ($src | path split | any {|c| $c == ".." }) { error make {msg: $"flags: record: flagsRecord.file ($src) must be a path inside the app's folder"} }
	let there = ($wapp | path join $src | path expand)
	if not ($there | str starts-with $"($wapp | path expand)/") { error make {msg: $"flags: record: flagsRecord.file ($src) resolves outside the app's folder \(a symlink is followed\)"} }
	if ($there | path type) != "file" { error make {msg: $"flags: record: flagsRecord.file ($src) is no file in the app"} }
	$src
}

# The pull request itself, in a scratch worktree from a fresh origin/main (never the operator's checkout):
# splice each flag's default, accept only a change that moves nothing else in flagd.document, run the app's generate,
# touch nothing outside the app, and push the branch for the app. {record, flags, pr}.
def record-pr [at: record, app: path, version: string, cases: string, want: list<record>, ctx: record]: nothing -> record {
	let top = (git-must (git-in $app rev-parse --show-toplevel) "not in a git tree" | path expand)
	let prefix = (git-must (git-in $app rev-parse --show-prefix) "no prefix" | str trim --char "/")
	let branch = (record-branch $app)
	git-must (git-in $top fetch -q origin main) "git fetch origin main" | ignore
	# The physical path: macOS's temporary folder is under /var, a link to /private/var, and a generate that compares
	# `pwd` with a `path expand`ed file (hatch.nu's path relative-to) fails on the two spellings.
	let scratch = (mktemp -d -t flagsrec.XXXXXX | path expand)
	git-must (git-in $top worktree add -q --detach $scratch origin/main) "git worktree add" | ignore
	let done = try { record-work $at $app $version $cases $want $ctx $top $scratch $prefix $branch } catch {|e| {error: $e.msg} }
	git-in $top worktree remove --force $scratch | ignore
	rm -rf $scratch
	if $done.error? != null { error make {msg: $done.error} }
	$done
}

# The spec's flagd.document moves only at the flipped defaults, and the app still vets.
def record-verify [wapp: path, trust: record, spec: record, diffs: list<record>] {
	let after = (with-env $trust { cue-of $wapp flagd.document })
	let expected = ($diffs | reduce --fold $spec {|d, acc| $acc | upsert ([flags $d.flag variants default] | into cell-path) $d.live })
	if $after != $expected { error make {msg: $"flags: record: the spec's flagd.document changes at more than ($diffs | get flag | each {|f| $'flags.($f).variants.default' } | str join ', ') once the defaults are written: refused"} }
	let vet = (do { cd $wapp; with-env $trust { ^$env.SAYT_MISE_BIN exec -- cue vet . } } | complete)
	if $vet.exit_code != 0 { error make {msg: $"flags: record: cue vet fails after the defaults are written: ($vet.stderr | str trim)"} }
}

# The app's generate, in the scratch tree. For a declared source it is what writes flags_spec.cue from it.
def record-generate [wapp: path, trust: record] {
	let gen = ($env.PRONTO_FLAGS_GENERATE_CMD? | default "deno run -A tests/slot.ts --weight 1 -- ./saytw generate")
	if ($wapp | path join tests slot.ts | path exists) or ($env.PRONTO_FLAGS_GENERATE_CMD? | default "") != "" {
		# The app's generate may wait on the machine's slots: it gets PRONTO_FLAGS_GENERATE_TIMEOUT_SEC (600), then it is
		# stopped and the record fails, never the push.
		let limit = ($env.PRONTO_FLAGS_GENERATE_TIMEOUT_SEC? | default 600 | into int)
		# Its own session, killed whole on the limit or when it ends (python3, which behaves alike on macOS and Linux where
		# `sh`'s job control does not): a child the generate started goes with it, and none holds the output open.
		let watched = 'python3 -c "import os,sys,subprocess,signal
p=subprocess.Popen([\"sh\",\"-c\",os.environ[\"PRONTO_GEN\"]],start_new_session=True)
try:
    rc=p.wait(timeout=float(os.environ[\"PRONTO_GEN_LIMIT\"]))
except subprocess.TimeoutExpired:
    rc=124
try:
    os.killpg(p.pid,signal.SIGKILL)
except ProcessLookupError:
    pass
p.wait()
sys.exit(rc)"'
		let g = (run-cases $wapp $watched ($trust | merge {PRONTO_GEN: $gen, PRONTO_GEN_LIMIT: ($limit | into string)}))
		if not $g.ok { error make {msg: $"flags: record: generate failed or ran past its ($limit) s in the scratch tree: ($g.out)"} }
	} else { print -e $"flags: record: ($wapp) has no tests/slot.ts, so generate was not run" }
}

# The spec's flagd.document in the scratch tree. A fresh checkout lacks what the app's generate writes and its CUE embeds
# (a gitignored file: brawl-chess's join/analytics.json), so an evaluation that finds one missing is made after a generate.
def record-spec [wapp: path, trust: record]: nothing -> record {
	try { with-env $trust { cue-of $wapp flagd.document } } catch {|e|
		if not ($e.msg | str contains "@embed: open") { error make {msg: $e.msg} }
		record-generate $wapp $trust
		with-env $trust { cue-of $wapp flagd.document }
	}
}

def record-work [at: record, app: path, version: string, cases: string, want: list<record>, ctx: record, top: string, scratch: string, prefix: string, branch: string]: nothing -> record {
	let wapp = if $prefix == "" { $scratch } else { $scratch | path join $prefix }
	let trust = {MISE_TRUSTED_CONFIG_PATHS: $scratch}
	let spec = (record-spec $wapp $trust)
	let diffs = (record-diffs $want $spec)
	if ($diffs | is-empty) { return {record: "none", flags: "", pr: ""} }
	let src = (record-source $wapp $trust)
	let file = ($wapp | path join $src)
	mut text = (open --raw $file)
	for d in $diffs { $text = (splice-default $text $d.flag $d.live) }
	$text | save -f --raw $file
	let declared = ($src != "flags_spec.cue")
	if not $declared { record-verify $wapp $trust $spec $diffs }
	record-generate $wapp $trust
	if $declared { record-verify $wapp $trust $spec $diffs }
	let status = (git-in $scratch status --porcelain --untracked-files=all)
	if $status.exit_code != 0 { error make {msg: $"flags: record: git status: ($status.stderr | str trim)"} }
	let changed = ($status.stdout | lines | each {|l| $l | str substring 3.. })
	let allowed = {|p| $p | str starts-with (if $prefix == "" { "" } else { $"($prefix)/" }) }
	let strays = ($changed | where {|p| ($p | str starts-with ".github/") or not (do $allowed $p) })
	if ($strays | is-not-empty) { error make {msg: $"flags: record: the change touches ($strays | str join ', '), outside the app's own files: refused, no pull request opened"} }
	let title = $"($app | path expand | path basename): record live flag defaults"
	let body = ($"Writes what production serves into ($src), so the spec says it. No deploy, no change in behaviour: live already has these values.\n\n" + ($diffs | each {|d| $"- ($d.flag): ($d.spec) to ($d.live)" } | str join "\n") + $"\n\nRecords: ($diffs | each {|d| {($d.flag): $d.live} } | into record | to json -r)\n\nJournal: version ($version), flags ($diffs | get flag | str join '+'), values ($diffs | get live | each {|v| $v | to json -r } | str join ' '), cases ($cases).\n")
	git-must (git-in $scratch checkout -q -B $branch) "git checkout" | ignore
	git-must (git-in $scratch add -A -- (if $prefix == "" { "." } else { $prefix })) "git add" | ignore
	# A machine with no git identity (a CI runner, a fresh box) still commits: the tool's own, only when none is set.
	let ident = if ((git-in $scratch config user.name).stdout | str trim) == "" { ["-c", "user.name=pronto-flags", "-c", "user.email=pronto-flags@users.noreply.github.com"] } else { [] }
	git-must (git-in $scratch ...$ident commit -q -m $title -m $body) "git commit" | ignore
	# The lease is the branch as it was when this attempt began (`ctx`): a record that landed since fails the push with
	# "stale info", and record-back builds once more, over the fresh pull request.
	git-must (git-in $scratch push -q origin $"HEAD:refs/heads/($branch)" $"--force-with-lease=refs/heads/($branch):($ctx.remote)") "git push" | ignore
	let flags = ($diffs | get flag | str join "+")
	let arm = {|url: string|
		let a = (do { cd $scratch; ^gh pr merge $url --auto --squash } | complete)
		if $a.exit_code != 0 { print -e $"flags: WARNING: auto-merge was not armed on ($url): ($a.stderr | str trim)" }
	}
	let edit = {|pr: record|
		let e = (do { cd $scratch; ^gh pr edit $pr.number --body $body } | complete)
		if $e.exit_code != 0 { error make {msg: $"flags: record: gh pr edit: ($e.stderr | str trim)"} }
		do $arm $pr.url
		{record: "pr", flags: $flags, pr: $pr.url}
	}
	# A pull request closed or merged since it was listed is no pull request to edit.
	let open = if $ctx.open == null { null } else {
		let v = (do { cd $scratch; ^gh pr view $ctx.open.number --json state --jq .state } | complete)
		if $v.exit_code == 0 and ($v.stdout | str trim) == "OPEN" { $ctx.open } else { null }
	}
	if $open != null { return (do $edit $open) }
	let c = (do { cd $scratch; ^gh pr create --title $title --body $body --base main --head $branch } | complete)
	if $c.exit_code != 0 {
		# Another record opened it since the list: it is the one to edit.
		let again = if ($c.stderr | str contains "already exists") { record-open-pr $scratch $branch } else { null }
		if $again != null { return (do $edit $again) }
		error make {msg: $"flags: record: gh pr create: ($c.stderr | str trim)"}
	}
	let url = ($c.stdout | str trim | lines | last)
	do $arm $url
	{record: "pr", flags: $flags, pr: $url}
}

# What the attempt starts from, read once and together: the repository, the branch's head on origin (the lease) and the
# open record pull request with its Records: line.
def record-context [app: path]: nothing -> record {
	let top = (git-must (git-in $app rev-parse --show-toplevel) "not in a git tree" | path expand)
	let branch = (record-branch $app)
	let remote = (git-must (git-in $top ls-remote origin $"refs/heads/($branch)") "git ls-remote" | split row "\t" | first | default "")
	let open = (record-open-pr $top $branch --strict)
	# The carry is read from the branch head's own commit message (its Records: line), the object the lease is on; the pull
	# request only says whether there is one to edit. A branch that is there with no pull request of ours is ours only if
	# its head is a record commit of this tool: anything else is someone's work, and is not force-pushed over.
	let message = if $remote == "" { "" } else {
		git-must (git-in $top fetch -q origin $branch) "git fetch origin branch" | ignore
		git-must (git-in $top log -1 --format=%B $remote) "git log of the branch head"
	}
	if $remote != "" and $open == null and not (($message | lines | first | default "") | str ends-with ": record live flag defaults") {
		error make {msg: $"flags: record: ($branch) exists on origin and its head is not a record commit of this tool: refused, nothing was pushed"}
	}
	{remote: $remote, open: $open, message: (if $open == null { "" } else { $message })}
}

# The flags the open record pull request's branch head already changes against main (the `Records:` line of its commit message: flag to value), carried into
# the rebuilt branch for as long as live still holds their value: {keep: [{flag, value}], stale: [flags live has moved on from]}.
# `have` is what the push itself records, which wins.
def record-carry [at: record, message: string, have: list<record>]: nothing -> record {
	let line = ($message | lines | where {|l| $l | str starts-with "Records: " })
	if ($line | is-empty) { return {keep: [], stale: []} }
	# A line that is not ours to read carries nothing, and fails nothing.
	let parsed = try {
		let r = ($line | first | str substring 9.. | from json)
		if ($r | describe | str starts-with "record") and ($r | values | all {|v| ($v | describe) in ["bool" "string" "int" "float"] }) { $r } else { null }
	} catch { null }
	if $parsed == null { print -e "flags: WARNING: the open record pull request's branch head has a Records: line that is unparsable, so it carries nothing into the rebuilt branch"; return {keep: [], stale: []} }
	let recs = ($parsed | transpose flag value | where {|r| $r.flag not-in ($have | get flag) })
	let now = (store-cat $at | from json)
	let live = ($recs | each {|r| $r | insert live (default-of ($now.flags? | default {} | get -o $r.flag)) })
	{keep: ($live | where {|r| $r.value == $r.live } | select flag value), stale: ($live | where {|r| $r.value != $r.live } | get flag)}
}

# One attempt: what the version wrote for the flags it owns, read against live now, then the record itself.
def record-attempt [at: record, app: path, version: string, cases: string, owned: any, stand: string]: nothing -> record {
	let w = (record-want $at $version $owned)
	if ($w.moved | is-not-empty) { print -e $"flags: WARNING: live has moved on since version ($version): ($w.moved | str join ', ') no longer hold its value and are not recorded" }
	# The pull request already open keeps its flags that live still holds: a second flip does not unmake the first's record.
	let ctx = if $stand != "" { {remote: "", open: null, message: ""} } else { record-context $app }
	let carry = if $stand != "" { {keep: [], stale: []} } else { record-carry $at $ctx.message $w.want }
	let w = ($w | upsert want ($w.want | append $carry.keep))
	if ($w.want | is-empty) {
		return (if ($carry.stale | is-not-empty) { {record: "none", flags: "", pr: "", stale: $carry.stale} } else if ($w.moved | is-not-empty) { {record: "skipped", flags: "", pr: "", note: $"live moved on since version ($version): ($w.moved | str join '+')"} } else { {record: "none", flags: "", pr: ""} })
	}
	let r = if $stand != "" {
		let diffs = (record-diffs $w.want (cue-of $app flagd.document))
		for d in $diffs {
			let c = (do { ^$stand $d.flag ($d.live | to json -r) $version } | complete)
			if $c.exit_code != 0 { error make {msg: $"flags: record: ($stand) ($d.flag): ($c.stderr | str trim)"} }
		}
		{record: (if ($diffs | is-empty) { "none" } else { "stand-in" }), flags: ($diffs | get flag | str join "+"), pr: ""}
	} else { record-pr $at $app $version $cases $w.want $ctx }
	if ($carry.stale | is-not-empty) { print -e $"flags: record: the open record pull request's ($carry.stale | str join ', ') no longer hold their value live, and are dropped from it" }
	# Whatever the outcome, record-back knows which flags of the open pull request went stale: with nothing left to record it is closed.
	let r = ($r | upsert stale $carry.stale)
	if ($w.moved | is-not-empty) { $r | insert note $"live moved on since version ($version): ($w.moved | str join '+') not recorded" } else { $r }
}

# An open record pull request that names one of these flags is stale once there is nothing to record (a failed record is
# transient and leaves it open): closed with its branch, so a merge cannot write what is no longer live. Never fails the caller.
def record-close [app: path, owned: any, stale: list<string>]: nothing -> string {
	try {
		let top = (git-in $app rev-parse --show-toplevel)
		if $top.exit_code != 0 { return "" }
		let repo = ($top.stdout | str trim)
		let open = (record-open-pr $repo (record-branch $app))
		if $open == null { return "" }
		let named = ($owned == null) or ($stale | is-not-empty) or ($owned | any {|f| ($open.body? | default "") =~ ("(?m)^- " + (re-escape $f) + ":") })
		if not $named { return "" }
		let c = (do { cd $repo; ^gh pr close $open.number --delete-branch --comment "The flags this recorded no longer differ from the spec, or the record failed: closed by pronto-flags." } | complete)
		if $c.exit_code == 0 { print $"flags: closed the stale record pull request ($open.url)"; $open.url } else { print -e $"flags: WARNING: could not close ($open.url): ($c.stderr | str trim)"; "" }
	} catch { "" }
}

# After the final write of a push or a rollback: what that version wrote, for the flags the push owns (`owned`: its --flip
# and --sync names; for a rollback, the flags whose default moved; null for every flag of the version), into the spec. A
# flag the spec holds differently and the push did not write is `drift`'s, never recorded. Values come from the version
# written, and only where live still holds them (else record: skipped). Skipped under a dry run, and where
# PRONTO_FLAGS_RECORD says off. PRONTO_FLAGS_RECORD_BIN stands in for the pull request, in tests: it is run once
# per flag to record, as `<bin> <flag> <value as JSON> <version>`. Never fails the caller, whose write stands.
def record-back [at: record, app: path, version: string, cases: string, owned: any]: nothing -> any {
	if (dry) or ($env.PRONTO_FLAGS_RECORD? | default "") in ["0" "off"] { return null }
	if $owned != null and ($owned | is-empty) { return null }
	let stand = ($env.PRONTO_FLAGS_RECORD_BIN? | default "")
	if $stand == "" and (has-kubeconfig $at) { print -e "flags: record skipped: it runs the app's generate, which a kubeconfig mirror's credential must not sit beside"; return null }
	let base = {event: "flags.record", app: ($app | path expand | path basename), target: $at.url, version: $version, cases: $cases}
	let file = (journal-file $app)
	let note = {|rec: record|
		let line = ($base | upsert at (now-utc) | merge $rec | to json -r)
		try { mkdir ($file | path dirname); $"($line)\n" | save -a $file } catch {|e| print -e $"flags: WARNING: could not note the record in ($file): ($e.msg)" }
	}
	do $note {record: "pending", flags: ($owned | default [] | str join "+")}
	let r = try {
		# A lost lease means another record landed first: read live again and build once more.
		try { record-attempt $at $app $version $cases $owned $stand } catch {|e|
			if ($e.msg | str contains "stale info") { record-attempt $at $app $version $cases $owned $stand } else { error make {msg: $e.msg} }
		}
	} catch {|e|
		print -e $"flags: WARNING: version ($version) is live but was NOT recorded in flags_spec.cue \(`pronto-flags drift` says what is missing\): ($e.msg | lines | first)"
		{record: "failed", flags: "", pr: "", note: ($e.msg | lines | first)}
	}
	let closed = if $stand == "" and $r.record == "none" { record-close $app $owned ($r.stale? | default []) } else { "" }
	let r = ($r | merge (if $closed != "" { {closed: $closed} } else { {} }))
	do $note $r
	if $r.record == "pr" { print $"flags: recorded in the spec by ($r.pr)" } else if $r.record == "stand-in" { print $"flags: recorded ($r.flags)" }
	$r
}

# The live flags into the spec, by hand: what a flip does after its write. Without --version, the version live now and
# every flag it holds; --version names the version a flip wrote and --flags (comma-separated) the flags to record from it.
export def record [app: path, --expect: string, --version: string, --flags: list<string> = []] {
	pin-guard $app
	let at = (live $app)
	if (target-guard $at $expect) { print "flags: dry run: nothing written"; return }
	let r = (record-back $at $app ($version | default (generation $at)) "manual" (if ($flags | is-empty) { null } else { $flags }))
	# A record by hand that wrote nothing is a failure, never a quiet exit 0 after a warning.
	if $r == null { return }
	if $r.record in ["pr" "stand-in"] or ($r.closed? | default "") != "" { return }
	error make {msg: $"flags: record: nothing was recorded \(($r.record)(if ($r.note? | default "") != "" { ': ' + $r.note } else if ($r.stale? | default [] | is-not-empty) { ': stale ' + ($r.stale | str join ', ') } else { '' })\)"}
}

# What the spec says differently from what is live: for every flag both hold, its reach (default, accounts,
# targeting). Read-only; the number of differences, and the open record pull request where there is one.
export def drift [app: path]: nothing -> int {
	let at = (live $app)
	let liv = (store-cat $at | from json)
	let spec = (cue-of $app flagd.document)
	let both = ($spec.flags | columns | where {|f| $f in ($liv.flags | columns) })
	let rows = ($both | each {|f| {flag: $f, live: (reach ($liv.flags | get $f)), spec: (reach ($spec.flags | get $f))} } | where {|r| $r.live != $r.spec })
	# What a flip leaves alone (PRONTO-1755) is listed too, and exits nothing: a plain push (the reconcile) writes it.
	let others = (drift-kinds $liv.flags $spec.flags | where kind != reach)
	if ($others | is-not-empty) {
		print $"flags: ($others | length) flags differ in more than their reach, which a flip leaves as live and a push naming no flag writes:"
		$others | print
	}
	if ($rows | is-empty) { print $"flags: the spec says the reach of what ($at.url) holds"; return 0 }
	print $"flags: the spec differs from ($at.url) in ($rows | length) flags:"
	$rows | each {|r| {flag: $r.flag, live: ($r.live | select value accounts | to json -r), spec: ($r.spec | select value accounts | to json -r), moved: (if $r.live.value != $r.spec.value { "default" } else { "accounts or targeting" })} } | print
	let pr = try {
		let top = (git-in $app rev-parse --show-toplevel)
		if $top.exit_code == 0 and (git-in $app remote get-url origin).exit_code == 0 { record-open-pr ($top.stdout | str trim) (record-branch $app) } else { null }
	} catch { null }
	if $pr != null { print $"flags: an open record pull request: ($pr.url)" }
	$rows | length
}

# Once per app: the bucket, versioned and private, keeping the last 50 versions;
# the app's run and preview accounts as its readers, since flagd reads it as the
# service it runs in; and the first push, which flagd needs before a release
# names the object (flagd stops at start on a source it cannot read).
export def setup [app: path, --expect: string] {
	pin-guard $app
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
# written over the version it read), provenance and journal, everyone at once, then the flag's `production` cases that
# need no tester (cases-of, run-cases), and the version read written again on a failure. Only the store
# differs: the rows are written by the database's own SECURITY DEFINER functions (player_record.army_catalog_set and
# army_catalog_drop), through a command the app names, so no app role can write a catalog.
#   bin/pronto-armies push <app-dir> [--local] [--untested "<why>"]   # the app's armiesLive.rows, once their cases pass
#   bin/pronto-armies show <app-dir> [--local]                          # what a push would write, and where: nothing written
#   bin/pronto-armies history <app-dir> [--local]                       # every write of every row, newest first
#   bin/pronto-armies rollback <app-dir> <army> [version] [--local]     # the version before the live one, or the one named
# --local pushes to the stack at hand (armiesLive.local): everyone at once, no cases.

# The app's armiesLive with the address of its flagsLive.
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
		site: ($f.url? | default "")
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
	let line = {at: (now-utc), event: "armies.write", app: ($app | path expand | path basename), target: $at.target, stage: $stage, armies: ($armies | str join "+"), who: $p.who, commit: $p.commit, plugin: $p.plugin, cases: $cases, note: $note} | to json -r
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

# Publishes armiesLive.rows, for everyone at once (PRONTO-284, as the flags' push). A row that is new or differs is a
# flip of the catalog, and runs the flag's cases:
#   1. it needs cases (`cases`: the scenarios and unit cases that name the flag); with none the push is refused, or
#      goes on with --untested "<why>";
#   2. each changed army is written for its audience, and a testers' row an earlier push left is dropped;
#   3. where the flag has `production` scenarios that need no tester (no `signIn` step), flagsCases.live runs them
#      against production (they look for the army in the page the shape built, waiting for the shape to deliver it);
#      a failure writes what was there before, and the push fails.
# --local: the stack at hand (armiesLive.local), no cases.
export def armies-push [app: path, --local, --untested: string, --expect: string] {
	pin-guard $app
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
		error make {msg: $"a push of ($names | str join ', ') has no cases: name the flag ($at.flag) in a scenario's `flags` or a unit case's \(`pronto-flags cases` lists them\), or push with --untested \"<why>\""}
	}
	let cmds = (cue-of $app flagsCases | default {})
	if ($c.production | is-not-empty) and (($at.site | is-empty) or ($cmds.live? | default "" | is-empty)) {
		error make {msg: $"($at.flag) has production cases: say flagsLive.url and flagsCases.live, which run them on production after the push"}
	}
	if ($c.signedIn | is-not-empty) { print -e $"armies: ($at.flag): not run, they sign in as a tester a push no longer has: ($c.signedIn | str join ', ')" }
	let note = (if $untested != null { $"untested: ($untested)" } else { "" })
	if $untested != null and not (has-cases $c) { print -e $"armies: WARNING: ($names | str join ', ') pushed with NO CASES: ($untested)" }
	armies-live $app $at $have $changed $c $cmds $note
}

# The live stage. The state before it is kept, and written again by whatever fails after the first write.
def armies-live [app: path, at: record, have: list<record>, changed: list<record>, c: record, cmds: record, note: string] {
	let before = ($changed | each {|w| {army: $w.army, everyone: ($have | where id == $w.army | get -o 0), testers: ($have | where id == $"($w.army)/testers" | get -o 0)} })
	let names = ($changed | get army)
	let run = ($c.production | is-not-empty)
	let wrap = if $run { cases-wrap $at } else { "" }
	try {
		for w in $changed {
			let b = ($before | where army == $w.army | first)
			let v = (army-set $at $w $w.audience (row-version (if $w.audience == "testers" { $b.testers } else { $b.everyone })))
			print $"armies: ($w.army) is version ($v) for ($w.audience)"
			if $w.audience == "everyone" and $b.testers != null { army-drop $at $w.army "testers" null | ignore }
		}
		army-journal $app $at all $names (if $run { "running" } else if (has-cases $c) { "none on production" } else { "untested" }) $note
		if $run {
			print $"armies: ($names | str join ', ') is in everyone's page; running its production cases \(($c.production | str join ', ')\)"
			let r = (run-cases $app $cmds.live {FLAG: $at.flag, ONLY: ($c.production | str join ","), APP_URL: $at.site} --wrap $wrap)
			if not $r.ok { error make {msg: $"($at.flag)'s production cases failed:\n($r.out)"} }
			# A push of rows does not move the flag, so only the verdict checks apply.
			let empty = (vacuous $r.out "")
			if $empty != "" { error make {msg: $"($at.flag)'s production cases showed nothing: ($empty)"} }
			army-journal $app $at all $names passed $note
		}
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
	pin-guard $app
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

def main [] { print "usage: live.nu setup|push|released|history|rollback|show|cases|record|drift <app-dir> [version|flag]; live.nu armies push|show|history|rollback <app-dir>" }
def "main setup" [app: path, --expect: string, --dry-run] { with-env (dry-env $dry_run) { setup $app --expect $expect } }
def "main push" [app: path, --untested: string, --no-canary: string, --expect: string, --flip: string = "", --drop: string = "", --sync: string = "", --stages: string = "", --dwell: string = "10min", --keyed: string, --watch: string, --several: string, --dry-run] { with-env (dry-env $dry_run) { push $app --untested $untested --no-canary $no_canary --expect $expect --flip (flip-names $flip) --drop (names $drop) --sync (names $sync) --stages (names $stages | each {|s| $s | into int }) --dwell ($dwell | into duration) --keyed $keyed --watch $watch --several $several } }
def "main watch" [app: path, --resume, --expect: string, --dry-run] {
	if not $resume { error make {msg: "usage: live.nu watch <app-dir> --resume: takes up a watch that died"} }
	with-env (dry-env $dry_run) { watch-resume $app --expect $expect }
}
def "main released" [app: path, --expect: string, --dry-run] { with-env (dry-env $dry_run) { released $app --expect $expect } }
# --flip's entries: names split at commas, but `name=value` is one entry whose value may hold commas; one that mixes it
# with other names is refused, since it cannot be told from a value.
def flip-names [s: string]: nothing -> list<string> {
	if not ($s | str contains "=") { return (names $s) }
	let at = ($s | str index-of "=")
	let name = ($s | str substring 0..<$at)
	let value = ($s | str substring ($at + 1)..)
	if ($name | str contains ",") or ($value =~ ',\s*[A-Za-z0-9_.-]+=') { error make {msg: "flags: --flip takes one flag with a value; repeat the command for the next: nothing was written"} }
	[($s | str trim)]
}
def names [s: string]: nothing -> list<string> { $s | split row "," | each {|n| $n | str trim } | where {|n| $n != "" } }
def "main history" [app: path, --json] { if $json { history $app --changes | to json | print } else { history $app | table -e | print } }
def "main rollback" [app: path, version?: string, --expect: string, --dry-run] { with-env (dry-env $dry_run) { rollback $app $version --expect $expect } }
def dry-env [on: bool]: nothing -> record { if $on { {PRONTO_FLAGS_DRY_RUN: "1"} } else { {} } }
def "main show" [app: path, --flip: string = "", --drop: string = "", --sync: string = ""] { show $app --flip (flip-names $flip) --drop (names $drop) --sync (names $sync) }
def "main record" [app: path, --expect: string, --version: string, --flags: string = "", --dry-run] { with-env (dry-env $dry_run) { record $app --expect $expect --version $version --flags (names $flags) } }
def "main drift" [app: path] { if (drift $app) > 0 { exit 1 } }
def "main cases" [app: path, flag?: string] { cases $app $flag | table -e | print }
