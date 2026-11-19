#!/usr/bin/env nu
# Run with: nu node/engine/contract_test.nu   (needs `cue` and the CUE registry, git, python3, and a
# pronto runtime at the pin: PRONTO_RUNTIME, or mise's github:bonisoft3/pronto@<pronto_pin>)
#
# The contract with upstream pronto at the version the apps pin (`pronto_pin`): what the engine takes
# from it is its CUE (#BuildManifests, #Environment) and six helpers of its nushell, and it follows
# upstream's release for the rest. This holds, against upstream's own `main -e gke` run over fakes
# (docker, kubectl, and a cue that records the data it is handed), that the engine
#   1. does not change upstream's objects but as it says (the declared patches and additions),
#   2. hands the CUE the same release data,
#   3. applies in the same order, except the steps it documents as its own.
# And that upstream's own k8s/release_test.nu passes at the pin. A new pin is validated by moving
# `pronto_pin` in a pull request here; any failure is fixed in the engine before an app moves its pin.

const engine_dir = path self .
const release_nu = (path self release.nu)

use std/assert

const pronto_pin = "1.5.1"

def runtime-dir []: nothing -> string {
	let d = if ($env.PRONTO_RUNTIME? | is-not-empty) { $env.PRONTO_RUNTIME } else { ^mise where $"github:bonisoft3/pronto@($pronto_pin)" | str trim }
	assert equal ($d | path basename) $pronto_pin $"the runtime is ($d), the contract is written for ($pronto_pin)"
	$d
}

# The engine's own steps and patches, which upstream has no counterpart of.
const own_kinds = [ObjectStore ScheduledBackup ResourceQuota LimitRange]

# A scratch world: the fixture app, a git repository (upstream's bake asks for its top), the fakes.
def sandbox []: nothing -> record {
	let d = (mktemp -d -t node-contract.XXXXXX | str trim)
	for p in [bin state aprende rec] { mkdir ($d | path join $p) }
	let app = ($d | path join aprende)
	^cp -R ($engine_dir | path join fixtures aprende/.) $app
	mkdir ($app | path join node schema)
	cp ($engine_dir | path join schema node.cue) ($app | path join node schema node.cue)
	do { cd $app; ^git init -q . } | ignore
	cp ($engine_dir | path join fixtures fake-kubectl) ($d | path join bin kubectl)
	let services = [database crud electric caddy auth migrate]
	$services | str join "\n" | save -f ($d | path join services.txt)
	({services: ($services | each {|s| [$s (match $s {
		"auth" => {environment: {OIDC_PROVIDERS: "google"}}
		"migrate" => {environment: {DATABASE_URL: "postgres://x", REQUIRED_TABLES: "a,b"}}
		_ => {}
	})] } | into record)} | to json | save -f ($d | path join compose.json))
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
echo "$*" >> "$d/docker.log"
case "$*" in
  "compose --profile * config --format json") cat "$d/compose.json" ;;
  "compose --profile * config --services") cat "$d/services.txt" ;;
  "compose --profile * config") echo "services: {}" ;;
  "buildx bake -f - --print "*)
    printf '{"target":{'; sep=""
    for a in "$@"; do case "$a" in -f|-|bake|buildx|--print) ;; *) printf '%s"%s":{"tags":["%s:latest"]}' "$sep" "$a" "$a"; sep="," ;; esac; done
    printf '}}\n' ;;
  "image inspect --format {{json .Config.Env}} "*) echo '["PATH=/bin","PG_MAJOR=17"]' ;;
  "image inspect --format {{json .RepoDigests}} "*)
    for a; do last="$a"; done
    repo="${last%:*}"
    echo "[\"$repo@sha256:$(printf %s "$repo" | shasum -a 256 | cut -d' ' -f1)\"]" ;;
esac
'# | str trim --left | save -f ($d | path join bin docker)
	# A cue that keeps the JSON it is handed (the release data) and runs the real one.
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
n=$(( $(cat "$d/rec/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/rec/n"
mkdir -p "$d/rec/$n"
for a; do case "$a" in *.json) [ -f "$a" ] && cp "$a" "$d/rec/$n/" ;; esac; done
echo "$*" > "$d/rec/$n/args"
exec "$REAL_CUE" "$@"
'# | str trim --left | save -f ($d | path join bin cue)
	for t in [kubectl docker cue] { ^chmod +x ($d | path join bin $t) }
	"" | save -f ($d | path join tunnel_open)
	{dir: $d, app: $app, state: ($d | path join state)}
}

def --wrapped in-world [w: record, ...rest]: nothing -> record {
	let real = (which cue | get 0.path)
	let path = ([($w.dir | path join bin) ($real | path dirname)] | append $env.PATH)
	with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), REAL_CUE: $real} {
		do { cd $w.app; ^$nu.current-exe --no-config-file ...$rest } | complete
	}
}

# A record with its keys sorted, as deep as it goes: JSON that compares as data.
def canon []: any -> any {
	let v = $in
	match ($v | describe | split row "<" | first) {
		"record" => ($v | transpose k x | sort-by k | each {|e| [$e.k ($e.x | canon)] } | into record)
		"list" | "table" => ($v | each {|x| $x | canon })
		_ => $v
	}
}

# What upstream or the engine wrote to the cluster, as the order a release makes it in: each object
# applied, each Job replaced, the cluster annotated, each rollout waited on. The Namespace, applied
# first by the engine and with the rest by upstream, and the engine's record, are the engine's own;
# upstream's cleanup of an earlier airlock (the engine refuses the airlock) is upstream's.
def writes [w: record]: nothing -> list<string> {
	let f = ($w.state | path join calls.jsonl)
	open --raw $f | lines | each {|l| $l | from json } | each {|c|
		let a = $c.args
		match ($a | first) {
			"apply" => (if ($a | any {|x| $x | str starts-with "--dry-run" }) { [] } else { $c.objects | each {|o| $"apply ($o.kind)/($o.name)" } })
			"delete" => (if $a.1 == "job" and not ($a.2 | str ends-with "-airlock-upgrade") { [$"delete job/($a.2)"] } else { [] })
			"annotate" => [$"annotate ($a.1)"]
			"rollout" => (if $a.1 == "status" { [$"rollout ($a.2)"] } else { [] })
			_ => []
		}
	} | flatten | where {|l| not ($l starts-with "apply Namespace/") and $l != "apply ConfigMap/pronto-release" }
}

def main [] {
	print $"Running node contract tests against upstream pronto ($pronto_pin)...\n"
	test_upstreams_own_release_test_passes
	test_objects_change_only_as_declared
	test_data_and_order_match_upstreams_main
	print "\nAll node contract tests passed."
}

def test_upstreams_own_release_test_passes [] {
	print "test upstream's own k8s/release_test.nu passes at the pin..."
	let r = (do { cd (runtime-dir | path join k8s); ^$nu.current-exe --no-config-file release_test.nu } | complete)
	assert equal $r.exit_code 0 $"($r.stdout | lines | last 15 | str join (char nl))\n($r.stderr)"
}

# The engine's objects, with its declared patches undone and its additions dropped, are upstream's.
def undeclared []: list -> list {
	$in
		| where {|o| $o.kind not-in $own_kinds and not ($o.kind == "NetworkPolicy" and ($o.metadata.name | str ends-with "-tenant-egress")) }
		| each {|o|
			match $o.kind {
				"Namespace" => ($o | update metadata.labels {|x| $x.metadata.labels | reject -o "pronto.dev/release" "pronto.dev/preview" } | if ($in.metadata.labels | is-empty) { $in | reject metadata.labels } else { $in })
				"Cluster" => ($o | reject -o spec.plugins)
				_ => $o
			}
		}
}

def test_objects_change_only_as_declared [] {
	print "test the engine's objects are upstream's, but for its declared patches and additions..."
	for variant in [
		""
		"Node: {backups: {bucket: \"b\", path: \"p\"}, tenant: {egress: [{ports: [{port: 443}]}]}}\n"
		"Node: {preview: \"rc\"}\n"
	] {
		let w = (sandbox)
		if ($variant | is-not-empty) { $"package aprende\n($variant)" | save -f ($w.app | path join variant.cue) }
		let tags = if ($variant | str contains "preview") { [-t preview=rc] } else { [] }
		let r = (in-world $w -c $"cd '($w.app)'; ^cue export -e '{engine: nodeManifests, upstream: upstreamObjects}' --out json ...($tags | to nuon) . | print")
		# the export wants the hosts the variant names: the preview has its own
		assert equal $r.exit_code 0 $"($variant)\n($r.stderr)"
		let both = ($r.stdout | from json)
		assert equal ($both.engine | undeclared | canon | to json) ($both.upstream | canon | to json) $"variant ($variant | str trim)"
		if ($variant | str contains "backups") {
			let added = ($both.engine | where kind in $own_kinds | get kind | sort)
			assert equal $added [LimitRange ObjectStore ResourceQuota ScheduledBackup]
		}
		rm -rf $w.dir
	}
}

def test_data_and_order_match_upstreams_main [] {
	print "test the engine's release data and kubectl order are those of upstream's `main -e gke`..."
	# Upstream's main, over the fakes.
	let up = (sandbox)
	let r = (in-world $up ((runtime-dir) | path join k8s release.nu) --app $up.app -e gke)
	assert equal $r.exit_code 0 $"($r.stdout | lines | last 20 | str join (char nl))\n($r.stderr)"
	# The data it handed CUE last: the roles and the pushed images, two JSON files of one call.
	let calls = (ls ($up.dir | path join rec) | where type == dir | get name | sort-by {|n| $n | path basename | into int })
	let last = ($calls | where {|c| (ls $c | where name =~ '\.json$' | length) >= 2 } | last)
	let upstream_data = (ls $last | where name =~ '\.json$' | get name | each {|f| open $f } | reduce {|it, acc| $acc | merge deep $it })
	# The engine, over a second world, with the digests the fake docker gave (a hash of the repository).
	let en = (sandbox)
	let registry = "europe-west3-docker.pkg.dev/brawl-chess/node-images"
	let pushed = ([database crud electric auth caddy migrate] | each {|s|
		[$s {tag: (if $s == "database" { "17" } else { "latest" }), digest: $"sha256:(($"($registry)/aprende-($s)") | hash sha256)"}]
	} | into record)
	let script = $"use ($engine_dir | path join render.nu); use ($engine_dir | path join runtime.nu); use ($release_nu) [release-app]; let app_info = \(runtime resolve-app '($en.app)'\); let node = \(render node-config $app_info.cue_path ''\); let meta = \(render app-meta $app_info.cue_path ''\); let compose = \(render compose-config $app_info.dir\); let facts = \(render facts $app_info.dir\); let pushed = ($pushed | to nuon); render release-data $app_info.dir $compose $facts $pushed | save -f ($en.dir | path join data.json); release-app $app_info $node $meta $compose $facts [] $pushed"
	let e = (in-world $en -c $script)
	assert equal $e.exit_code 0 $"($e.stdout | lines | last 20 | str join (char nl))\n($e.stderr)"
	# 2. data
	assert equal ((open ($en.dir | path join data.json)) | canon | to json) ($upstream_data | canon | to json)
	# 3. order, but for the engine's own Namespace and record
	let want = (writes $up)
	let got = (writes $en)
	assert (($want | length) > 10) "upstream applied something"
	print $"  ($want | length) writes and ((open ($en.dir | path join data.json) | columns | length)) data fields compared"
	assert equal $got $want
	rm -rf $up.dir $en.dir
}
