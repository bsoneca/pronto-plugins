# The program's exports, one evaluation for every plugin's generate rule. Written by each plugin
# whose rule reads a value of the program (pronto/exports.nu); regenerated, do not edit.
#
# `cue export .` costs seconds whatever it exports, because it evaluates the whole program,
# and a rule per plugin used to pay it each. A rule now says `exports of <name>`: the first one
# evaluates every export the app's installed plugins name, in one `cue export`, and keeps the
# result for the rest of this sayt run (.task/pronto-exports/<run>.json, a run being the process that
# runs the rules) under a key of the files the evaluation reads. A rule that finds no result for the
# tree as it stands (a file changed since, as journeys' derive does), or whose run cannot be told,
# evaluates its own export, as it did before; so does one whose batch did not evaluate, which then
# fails on its own terms.

# What a plugin's rule reads: the name it asks by, the expression of the program, and the rule
# file in pronto/ that says the plugin is installed.
const exports = [
	{name: "journeys", expr: "journeys.out", rule: "journeys"}
	{name: "perf", expr: "perf.out", rule: "perf"}
	{name: "flagd", expr: "flagd.document", rule: "flags"}
	{name: "adsense", expr: "adsense", rule: "ads"}
	{name: "umami", expr: "analytics.umami", rule: "analytics"}
]

# Every file the evaluation reads: the program's CUE, and what it embeds (bayt.json, DESIGN.md,
# messages/*.json). The rules' own outputs (observability/, the door, flags/) are none of them.
def tree-key []: nothing -> string {
	let files = (glob **/*.cue --exclude [**/node_modules/** **/.task/** **/.git/** **/.omc/** **/.claude/**]
		| append (["bayt.json" "DESIGN.md" "mise.lock"] | each {|f| $env.PWD | path join $f })
		| append (glob messages/*.json)
		| where {|f| ($f | path type) == "file" }
		| sort)
	let hashes = ($files | str join (char nl) | ^git hash-object --stdin-paths | lines)
	$files | zip $hashes | each {|p| $"($p.0) ($p.1)" } | str join (char nl) | hash sha256
}

# The run the rules belong to: sayt's log directory where it has one, else the process that started
# this rule (every rule of a verb is a child of the one running them) and when it started, so a
# later run that is given the same number is another. Empty where neither can be read.
def run-id []: nothing -> string {
	let log = ($env.SAYT_LOG_DIR? | default "")
	if ($log | is-not-empty) { return ($log | hash sha256 | str substring 0..15) }
	let parent = (do { ^ps -o ppid= -p $nu.pid } | complete)
	if $parent.exit_code != 0 { return "" }
	let ppid = ($parent.stdout | str trim)
	if ($ppid | is-empty) { return "" }
	let started = (do { ^ps -o lstart= -p $ppid } | complete)
	if $started.exit_code != 0 or ($started.stdout | str trim | is-empty) { return "" }
	$"($ppid) ($started.stdout | str trim)" | hash sha256 | str substring 0..15
}

# The exports of the plugins this app has installed.
def wanted []: nothing -> list<record<name: string, expr: string, rule: string>> {
	$exports | where {|e| ("pronto" | path join $"($e.rule).cue" | path exists) }
}

# The app's pinned cue, as sayt's run-mise runs it.
def cue-export [expr: string]: nothing -> record {
	let mise = ($env.SAYT_MISE_BIN? | default "mise")
	do { ^$mise exec -- cue export . -e $expr --out json } | complete
}

def one [expr: string]: nothing -> string {
	let r = (cue-export $expr)
	if $r.exit_code != 0 {
		print -e $r.stderr
		error make {msg: $"cue export . -e ($expr) failed"}
	}
	$r.stdout
}

# The export `name` names, as `cue export . -e <expr> --out json` prints it.
export def of [name: string]: nothing -> string {
	let mine = ($exports | where name == $name | first)
	let run = (run-id)
	let batch = (wanted)
	let names = ($batch | each {|e| $e.name })
	let batched = ($name in $names)
	if ($run | is-empty) or not $batched { return (one $mine.expr) }
	let dir = (".task" | path join pronto-exports)
	let cache = ($dir | path join $"($run).json")
	let key = (tree-key)
	let held = if ($cache | path exists) { try { open $cache } catch { null } } else { null }
	if $held != null and $held.key == $key {
		if $held.failed { return (one $mine.expr) }
		return ($held.values | get $"export-($name)" | to json)
	}
	# A label of its own: a plain `journeys: journeys.out` would read the field it defines.
	let expr = ("{" + ($batch | each {|e| $"\"export-($e.name)\": ($e.expr)" } | str join ", ") + "}")
	let r = (cue-export $expr)
	let kept = if $r.exit_code == 0 { {key: $key, failed: false, values: ($r.stdout | from json)} } else { {key: $key, failed: true, values: {}} }
	mkdir $dir
	# What earlier runs left.
	glob $"($dir)/*.json" | where {|f| (ls $f | get 0.modified) < ((date now) - 1hr) } | each {|f| rm $f } | ignore
	$kept | to json | save --force $"($cache).tmp"
	mv --force $"($cache).tmp" $cache
	if $kept.failed { return (one $mine.expr) }
	$kept.values | get $"export-($name)" | to json
}
