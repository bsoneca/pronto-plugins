# The app's modules (modules/modules.cue), each exported on its own, in the order of their `needs`, through the cue on
# PATH (the cue wrapper keeps what a passing export printed, keyed by the files it reads: an unchanged module is printed
# again without evaluating, and its export stays byte-identical, so the keys of what reads it stay the same too).
# A module's checks are hidden fields of what it exports, so exporting it is vetting it. Independent modules run side by
# side. An export is written where the package that joins them reads it (`join`) and next to each module that needs it
# (modules/<name>/deps/<dep>.json: cue refuses an @embed of a parent folder). Run from the app's folder, before anything
# evaluates the package that joins the modules.
# Written by pronto-modular-design (modular-design/build.nu in pronto-plugins): regenerated, do not edit.

def export-one [name: string, all: record] {
	let m = ($all | get $name)
	let args = (if ($m.expr? | is-empty) { [] } else { ["-e" $m.expr] })
	let r = (^cue export $"./modules/($name)" ...$args --out json | complete)
	if $r.exit_code != 0 { error make {msg: $"module ($name): ($r.stderr)"} }
	let readers = ($all | columns | where {|c| $name in (($all | get $c).needs) })
	let dests = ($readers | each {|c| $"modules/($c)/deps/($name).json" } | append (if ($m.join? | is-empty) { [] } else { [$m.join] }))
	for d in $dests {
		mkdir ($d | path dirname)
		$r.stdout | save --force $d
	}
}

export def main [] {
	let r = (^cue export ./modules --out json | complete)
	if $r.exit_code != 0 { error make {msg: $"modules/modules.cue: ($r.stderr)"} }
	let all = ($r.stdout | from json | get modules)
	mut done = ["schema"]
	mut left = ($all | columns | where {|n| $n != "schema" })
	while ($left | is-not-empty) {
		let level = ($left | where {|n| ($all | get $n).needs | all {|d| $d in $done } })
		if ($level | is-empty) { error make {msg: $"modules: a cycle among ($left | str join ', ')"} }
		$level | par-each {|n| export-one $n $all } | ignore
		$done = ($done | append $level)
		$left = ($left | where {|n| $n not-in $level })
	}
}
