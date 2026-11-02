# pronto/exports.nu against a fixture app: `./saytw --script tools.nu nu common/test.nu`, with the
# pinned cue on the PATH. Counts the cue evaluations each `exports of` costs, with the PATH's mise
# a script that counts the `cue` it is asked to run.

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"common/test.nu: ($what)"} }
	print $"ok  ($what)"
}

def main [] {
	let here = ($env.PWD | path join common exports.nu)
	let app = (mktemp --directory)
	let run = (mktemp --directory)
	let count = ($run | path join count)
	"" | save $count
	"#!/bin/sh\necho x >> \"$COUNT\"\nshift 2\nexec \"$@\"\n" | save ($run | path join mise)
	chmod +x ($run | path join mise)
	mkdir ($app | path join cue.mod) ($app | path join pronto)
	"module: \"example.com/t@v0\"\nlanguage: version: \"v0.16.1\"\n" | save ($app | path join cue.mod module.cue)
	let program = {|n: int| $"package t\n\njourneys: out: {n: ($n)}\nadsense: publisher: \"pub-1\"\n" }
	do $program 1 | save ($app | path join a.cue)
	"package prontoproject\n" | save ($app | path join pronto journeys.cue)
	"package prontoproject\n" | save ($app | path join pronto ads.cue)
	^git -C $app init -q
	let evals = {|| open $count | lines | length }
	let get = {|name: string, logs: any|
		with-env {SAYT_MISE_BIN: ($run | path join mise), COUNT: $count, SAYT_LOG_DIR: $logs} {
			cd $app
			^$nu.current-exe -c $"use ($here); exports of ($name)" | from json
		}
	}

	let journeys = (do $get journeys $run)
	check "a rule gets its export" ($journeys == {n: 1})
	check "the first rule evaluates once" ((do $evals) == 1)
	let ads = (do $get adsense $run)
	check "another plugin's export comes from the same evaluation" ($ads == {publisher: "pub-1"} and (do $evals) == 1)

	do $program 2 | save --force ($app | path join a.cue)
	let changed = (do $get adsense $run)
	check "a changed file is evaluated again" ($changed == {publisher: "pub-1"} and (do $evals) == 2)
	check "and its result is the changed program's" ((do $get journeys $run) == {n: 2} and (do $evals) == 2)

	let other = (do $get journeys (mktemp --directory))
	check "another run evaluates for itself" ($other == {n: 2} and (do $evals) == 3)
	let unnamed = (do $get journeys "")
	check "with no run directory the process that runs the rules stands for it" ($unnamed == {n: 2} and (do $evals) == 4)
	check "and a second rule of that run reads the first's evaluation" ((do $get adsense "") == {publisher: "pub-1"} and (do $evals) == 4)

	"package prontoproject\n" | save ($app | path join pronto flags.cue)
	let dir2 = (mktemp --directory)
	let fell = (do $get journeys $dir2)
	check "a batch that does not evaluate falls back to the rule's own export" ($fell == {n: 2} and (do $evals) == 6)
	check "and is not tried again in the run" ((do $get adsense $dir2) == {publisher: "pub-1"} and (do $evals) == 7)
}
