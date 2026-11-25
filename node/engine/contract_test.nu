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
use runtime.nu [validated_pins]

# The newest pin the engine says it is validated against (runtime.nu): the module version this test holds.
def pronto-pin []: nothing -> string { $validated_pins | last }

# The runtime an app that pins the module `pronto-pin` runs: the tool version that module's distribution
# config names (an app's mise pins that, which lags the module by a release), or PRONTO_RUNTIME.
def runtime-dir []: nothing -> string {
	let d = if ($env.PRONTO_RUNTIME? | is-not-empty) { $env.PRONTO_RUNTIME } else {
		let module = (^mise where $"github:bonisoft3/pronto@(pronto-pin)" | str trim)
		let tool = (open --raw ($module | path join distribution config.cue) | parse --regex '#Version:\s+"(?<v>[^"]+)"' | get v.0)
		^mise where $"github:bonisoft3/pronto@($tool)" | str trim
	}
	assert ($d | path basename | $in in $validated_pins) $"the runtime is ($d), which is not in validated_pins"
	$d
}

# The fixture apps: what an app of each shape builds and runs. Studio's has the render service, flagd and the builder
# (a jailed pod with a Google identity, its own egress and a workspace).
def fixture-apps []: nothing -> list<record> {
	[
		{name: "aprende", services: [database crud electric caddy auth migrate], build: [database crud electric auth caddy migrate]}
		{name: "brawl-chess", package: "brawlchess", tuned: {scaled: true, plane: true, clocks: [ticker], logins: [analytics_reader], parameters: [max_connections], resources: [electric caddy crud], replicas: [crud auth caddy render], own: [billing analyst flagd perf-collector journeys-collector ticker standin notifier exporter], images: [billing analyst flagd perf-collector journeys-collector ticker standin notifier exporter rclone-s3 imgproxy], secrets: [notify-vapid-private-key]}, services: [database crud electric caddy auth migrate render], build: [database crud electric auth caddy migrate render]}
		{name: "studio", tuned: {backed: true, logins: [], parameters: [], resources: [electric], replicas: [], own: [flagd builder], images: [flagd builder], secrets: [studio-play studio-auth-secrets studio-llm-chatgpt studio-backup-s3]}, services: [database crud electric caddy auth migrate render flagd builder], build: [database crud electric auth caddy migrate render]}
	]
}

# The engine's own steps and patches, which upstream has no counterpart of.
const own_kinds = [ObjectStore ScheduledBackup ResourceQuota LimitRange]

# A scratch world: the fixture app, a git repository (upstream's bake asks for its top), the fakes.
def sandbox [fx: record]: nothing -> record {
	let d = (mktemp -d -t node-contract.XXXXXX | str trim)
	for p in [bin state $fx.name rec] { mkdir ($d | path join $p) }
	let app = ($d | path join $fx.name)
	^cp -R ($engine_dir | path join fixtures $"($fx.name)/.") $app
	# the fixture renders with the upstream schema of the pin under test
	let mod = ($app | path join cue.mod module.cue)
	open $mod | str replace -r 'pronto@v1": v: "[^"]+"' $'pronto@v1": v: "v(pronto-pin)"' | save -f $mod
	mkdir ($app | path join node schema)
	cp ($engine_dir | path join schema node.cue) ($app | path join node schema node.cue)
	do { cd $app; ^git init -q . } | ignore
	cp ($engine_dir | path join fixtures fake-kubectl) ($d | path join bin kubectl)
	# the Secrets the fixture's services read are in the namespace
	mkdir ($d | path join state secrets)
	for n in ($fx.tuned?.secrets? | default []) { "" | save -f ($d | path join state secrets $n) }
	let services = $fx.services
	$services | str join "\n" | save -f ($d | path join services.txt)
	({services: ($services | each {|s| [$s (match $s {
		"auth" => {environment: {OIDC_PROVIDERS: "google"}}
		"migrate" => {environment: {DATABASE_URL: "postgres://x", REQUIRED_TABLES: "a,b"}}
		"ticker" => {environment: {SERVICE_JWT: "x", TICK: "1"}}
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
  "buildx version") echo "github.com/docker/buildx v0 fake" ;;
  "buildx create "*|"buildx rm "*) ;;
  "buildx inspect "*) echo "Platforms: linux/amd64, linux/386" ;;
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
	# deno signs the service token (service-token.ts) and registers the OIDC clients (register.ts, which answers the settings it was
	# given, as it does for a provider whose client id is not "origin"); both releases ask it, and it is not run for real here
	"#!/bin/sh\ncase \"$*\" in *register.ts*) cat ;; *) cat >/dev/null; echo fake.service.token ;; esac\n" | save -f ($d | path join bin deno)
	# the registry answers 200 through the tunnel, which the preflight reads with curl
	# and the door check's probes (a path of the Dapr API) answer the door's own 404; nc finds the port-forward up
	"#!/bin/sh\ncase \"$*\" in *\"/v1.0\"*) printf 404 ;; *) echo 200 ;; esac\n" | save -f ($d | path join bin curl)
	for t in [crane docker-buildx sops nc] { "#!/bin/sh\nexit 0\n" | save -f ($d | path join bin $t) }
	for t in [kubectl docker cue deno crane docker-buildx sops curl nc] { ^chmod +x ($d | path join bin $t) }
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
# first by the engine and with the rest by upstream, the engine's record, and the generator and Secret of a database login
# (the brawl-chess fixture's analytics_reader) and a database's backups (the ObjectStore and the nightly ScheduledBackup) are the engine's own;
# upstream's cleanup of an earlier airlock (the engine refuses the airlock) is upstream's.
def writes [w: record, logins: list<string> = [], own: list<string> = [], app: string = ""]: nothing -> list<string> {
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
	} | flatten | where {|l| not ($l starts-with "apply Namespace/") and $l != "apply ConfigMap/pronto-release" and not ($l =~ '^apply (ObjectStore|ScheduledBackup)/') and not ($l =~ '^apply Configuration/.*-caddy-invoke-only$') and not ($logins | any {|g| let d = ($g | str replace -a "_" "-"); $l =~ $"^apply \(Password|ExternalSecret\)/.*-($d)-\(password|db\)$" }) and not (own-write $l $own $app) }
}

# A write of the engine's own services: an object or a rollout of one of the app's services, the blob plane or the metrics
# export (named `<app>-<name>` or by the bare name of its Service), and the service token their pods read.
def own-write [line: string, own: list<string>, app: string]: nothing -> bool {
	if ($own | is-empty) { return false }
	let name = ($line | split row "/" | last | str replace -r $"^($app)-" "")
	$name in ($own | each {|s| [$s $"($s)-clock" $"($s)-database-egress" $"($s)-egress"] } | flatten | append [blobs rclone-s3 imgproxy metrics-export services-netpol service-token])
}

# The paths of a value with what is at each, one line a leaf: two values' difference is the lines of one only.
def leaves [prefix: string = ""]: any -> list<string> {
	let v = $in
	match ($v | describe | split row "<" | first) {
		"record" => ($v | items {|k, x| $x | leaves $"($prefix).($k)" } | flatten)
		"list" | "table" => ($v | enumerate | each {|e| $e.item | leaves $"($prefix)[($e.index)]" } | flatten)
		_ => [$"($prefix) = ($v | to json --raw)"]
	}
}

def differences [a: any, b: any]: nothing -> string {
	let la = ($a | leaves)
	let lb = ($b | leaves)
	$"only in the engine: ($la | where {|l| $l not-in $lb } | str join '; ')\nonly in upstream: ($lb | where {|l| $l not-in $la } | str join '; ')"
}

def main [] {
	print $"Running node contract tests against upstream pronto (pronto-pin)...\n"
	test_upstreams_own_release_test_passes
	test_the_pin_is_validated
	for fx in (fixture-apps) {
		test_objects_change_only_as_declared $fx
		test_data_and_order_match_upstreams_main $fx
	}
	# --adopt changes how the objects are applied (server-side, forced), never which or in what order
	test_data_and_order_match_upstreams_main (fixture-apps | first) --adopt
	print "\nAll node contract tests passed."
}

def test_the_pin_is_validated [] {
	print "test the runtime under test is one the engine's preflight accepts..."
	assert ((runtime-dir | path basename) in $validated_pins)
	# The engine renders with the module's schema and runs the runtime's helpers: the two releases carry the
	# same nushell, or the helpers this test runs are not the ones the module's apps get.
	if ($env.PRONTO_RUNTIME? | is-empty) {
		let module = (^mise where $"github:bonisoft3/pronto@(pronto-pin)" | str trim)
		for f in [k8s/release.nu release-schema.nu] {
			assert equal (open --raw ($module | path join $f)) (open --raw (runtime-dir | path join $f)) $"($f) differs between the module (pronto-pin) and its runtime (runtime-dir | path basename)"
		}
	}
}

def test_upstreams_own_release_test_passes [] {
	print "test upstream's own k8s/release_test.nu passes at the pin..."
	let r = (do { cd (runtime-dir | path join k8s); ^$nu.current-exe --no-config-file release_test.nu } | complete)
	assert equal $r.exit_code 0 $"($r.stdout | lines | last 15 | str join (char nl))\n($r.stderr)"
}

# The door's Deployment as upstream renders it: the engine's patch, `dapr.io/config` pointed at the door's own Configuration, undone
# only where the value is the engine's (anything else upstream wrote there is left as it is).
def restore-shared-dapr [o: record]: nothing -> record {
	let name = ($o.metadata.name | str replace -r '-caddy$' '')
	if ($o | get -o spec.template.metadata.annotations."dapr.io/config") == $"($name)-caddy-invoke-only" {
		let u = ($o | update spec.template.metadata.annotations."dapr.io/config" $"($name)-dapr-config")
		if ($u.spec.template.metadata.annotations | columns | is-empty) { $u | reject spec.template.metadata.annotations } else { $u }
	} else { $o }
}

# The initdb Job's script as upstream renders it: the engine's wait for the database to take a connection (node.cue's
# #TuneInitdb), undone only where the script begins with it.
def restore-initdb-wait [o: record]: nothing -> record {
	let wait = "for i in $(seq 30); do PGCONNECT_TIMEOUT=2 psql -XtAc 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done\n"
	$o | update spec.template.spec.containers {|x|
		$x.spec.template.spec.containers | each {|c|
			if ($c | get -o command | default [] | length) == 3 and ($c.command.1 == "-c") and ($c.command.2 | str starts-with $wait) {
				$c | update command [$c.command.0 "-c" ($c.command.2 | str substring ($wait | str length)..)]
			} else { $c }
		}
	}
}

# The engine's objects, with its declared patches undone and its additions dropped, are upstream's.
def undeclared []: list -> list {
	$in
		| where {|o| $o.kind not-in $own_kinds and not ($o.kind == "NetworkPolicy" and ($o.metadata.name | str ends-with "-tenant-egress")) and not ($o.kind == "Configuration" and ($o.metadata.name | str ends-with "-caddy-invoke-only")) }
		| each {|o|
			match $o.kind {
				"Namespace" => ($o | update metadata.labels {|x| $x.metadata.labels | reject -o "pronto.dev/release" "pronto.dev/preview" } | if ($in.metadata.labels | is-empty) { $in | reject metadata.labels } else { $in })
				"Cluster" => ($o | reject -o spec.plugins)
				# the door's own Dapr configuration is the engine's (declared patch): upstream points it at the shared one
				"Deployment" if ($o.metadata.name | str ends-with "-caddy") => (restore-shared-dapr $o)
				# the initdb Job waits for the database (declared patch): upstream's script runs at once
				"Job" if ($o.metadata.name | str ends-with "-initdb") => (restore-initdb-wait $o)
				_ => $o
			}
		}
}

# What a fixture's tunings (node.cue's #Tune) changed, and only that, taken out of both sides of a comparison: the
# replicas of the Deployments it scales, the resources of the containers it names, the Cluster's instances, volume size,
# synchronous replication, stop and update settings, the parameters it names (and the WAL cap the volume gives), the roles
# of its logins, and the generator and Secret of each login. Everything else of upstream's must come through as it is.
# An app that sets none is compared whole.
def without-tunings [app: string, t: record]: list -> list {
	let dashed = ($t.logins | each {|l| $l | str replace -a "_" "-" })
	let params = ($t.parameters | append max_slot_wal_keep_size)
	let own = ($t.own? | default [])
	$in
		| where {|o| not ($o.kind in [Password ExternalSecret] and ($dashed | any {|d| $o.metadata.name ends-with $"($app)-($d)-password" or $o.metadata.name ends-with $"($app)-($d)-db" })) }
		| where {|o| not (own-write $"($o.kind)/($o.metadata.name)" $own $app) }
		| each {|o|
			match $o.kind {
				"Deployment" => {
					let scaled = ($o.metadata.name | str replace $"($app)-" "") in $t.replicas
					let d = (if $scaled { $o | reject -o spec.replicas } else { $o })
					$d | update spec.template.spec.containers {|x| $x.spec.template.spec.containers | each {|c| if $c.name in $t.resources { $c | reject -o resources } else { $c } } }
				}
				"Cluster" => {
					let c = ($o | reject -o spec.instances spec.storage.size spec.postgresql.synchronous spec.primaryUpdateStrategy spec.primaryUpdateMethod spec.replicationSlots spec.enablePDB spec.smartShutdownTimeout spec.stopDelay spec.resources)
					let c = ($c | update spec.postgresql.parameters {|x| $x.spec.postgresql.parameters | reject -o ...$params })
					$c | update spec.managed.roles {|x| $x.spec.managed.roles | where {|r| $r.name not-in $t.logins } }
				}
				_ => $o
			}
		}
}

# The images a release would have pushed, as a CUE file: the engine refuses an image that is not pinned by digest.
def pushed-cue [fx: record]: nothing -> string {
	let digest = ("a" | fill -c "a" -w 64)
	$"package ($fx.package? | default $fx.name)\nApp: image: pushed: {\n" + ($fx.build | append ($fx.tuned?.images? | default []) | each {|s| $"\t\"($s)\": {tag: \"latest\", digest: \"sha256:($digest)\"}\n" } | str join "") + "}\n"
}

def test_objects_change_only_as_declared [fx: record] {
	print $"test ($fx.name): the engine's objects are upstream's, but for its declared patches and additions..."
	for variant in [
		""
		# a fixture that states its own database.backup is not given a second one
		(if ($fx.tuned?.backed? | default false) { "Node: {tenant: {egress: [{ports: [{port: 443}]}]}}\n" } else { "Node: {backups: {bucket: \"b\", path: \"p\"}, tenant: {egress: [{ports: [{port: 443}]}]}}\n" })
		"Node: {preview: \"rc\"}\n"
	] {
		let w = (sandbox $fx)
		pushed-cue $fx | save -f ($w.app | path join pushed.cue)
		if ($variant | is-not-empty) { $"package ($fx.package? | default $fx.name)\n($variant)" | save -f ($w.app | path join variant.cue) }
		let tags = if ($variant | str contains "preview") { [-t preview=rc] } else { [] }
		let r = (in-world $w -c $"cd '($w.app)'; ^cue export -e '{engine: nodeManifests, upstream: upstreamObjects}' --out json ...($tags | to nuon) . | print")
		# the export wants the hosts the variant names: the preview has its own
		assert equal $r.exit_code 0 $"($variant)\n($r.stderr)"
		let both = ($r.stdout | from json)
		let tuned = ($fx.tuned? | default false)
		let engine = ($both.engine | undeclared)
		let upstream = $both.upstream
		let mine = (if $tuned != false { $engine | without-tunings $fx.name $tuned } else { $engine })
		let theirs = (if $tuned != false { $upstream | without-tunings $fx.name $tuned } else { $upstream })
		assert equal ($mine | canon | to json) ($theirs | canon | to json) $"variant ($variant | str trim): (differences $mine $theirs)"
		if $tuned != false and ($tuned.scaled? | default false) {
			# the tunings themselves: the numbers the fixture's release.cue names, in production and in the preview
			let crud = ($both.engine | where {|o| $o.kind == "Deployment" and $o.metadata.name == $"($fx.name)-crud" } | first)
			let db = ($both.engine | where kind == Cluster | first)
			assert equal $crud.spec.replicas (if ($variant | str contains "preview") { 2 } else { 3 }) "crud's replicas"
			assert equal $db.spec.instances 3 "the database's instances"
			let up_db = ($upstream | where kind == Cluster | first)
			assert equal ($db.spec.managed.roles | get name) (($up_db.spec.managed.roles | get name) | append $tuned.logins) "upstream's roles come through, the logins are added"
			assert equal ($db.spec.postgresql.parameters | reject -o ...$tuned.parameters max_slot_wal_keep_size) ($up_db.spec.postgresql.parameters | reject -o ...$tuned.parameters max_slot_wal_keep_size) "upstream's parameters come through but the ones named"
			assert equal ($db.spec.postgresql.parameters.max_connections) "200" "the app's parameter wins"
			assert equal ($engine | where kind == Deployment | where {|o| $o.metadata.name == $"($fx.name)-electric" } | first | get spec.replicas) 1 "Electric stays at one"
		}
		# the app's own services, the blob plane and the metrics export: each a Deployment, in the mesh with the shared Configuration
		let svcs = (if $tuned != false { $tuned.own? | default [] } else { [] })
		if ($svcs | is-not-empty) {
			let deployments = ($both.engine | where kind == Deployment)
			for s in ($svcs | append (if ($tuned.plane? | default false) { [rclone-s3 imgproxy metrics-export] } else { [] })) {
				assert (($deployments | where {|o| $o.metadata.name == $"($fx.name)-($s)" } | length) == 1) $"the service ($s) is one Deployment"
			}
			let first_service = ($deployments | where {|o| $o.metadata.name == $"($fx.name)-($svcs | first)" } | first)
			assert equal ($first_service.spec.template.metadata.annotations | get "dapr.io/config") $"($fx.name)-dapr-config"
			assert equal ($both.engine | where kind == CronJob | get metadata.name) ($tuned.clocks? | default [] | each {|c| $"($fx.name)-($c)-clock" })
			if "ticker" in $svcs {
				assert equal ($deployments | where {|o| $o.metadata.name == $"($fx.name)-ticker" } | first | get spec.strategy.type) "Recreate"
			}
		}
		# the door's Dapr configuration: its own, invocation alone allowed; every other Deployment keeps the shared one
		let own = ($both.engine | where {|o| $o.kind == "Configuration" and ($o.metadata.name | str ends-with "-caddy-invoke-only") })
		assert equal ($own | length) 1 "one Configuration for the door"
		assert equal ($own.0.spec.api.allowed | each {|a| $"($a.name) ($a.version) ($a.protocol)" }) ["invoke v1.0 http" "invoke v1.0 grpc"]
		let caddy = ($both.engine | where {|o| $o.kind == "Deployment" and ($o.metadata.name | str ends-with "-caddy") })
		assert equal ($caddy | length) 1 "the door's Deployment"
		assert equal ($caddy.0.spec.template.metadata.annotations | get "dapr.io/config") $own.0.metadata.name
		let others = ($both.engine | where {|o| $o.kind == "Deployment" and not ($o.metadata.name | str ends-with "-caddy") } | each {|o| $o.spec.template.metadata.annotations | get -o "dapr.io/config" } | uniq)
		assert (not ($own.0.metadata.name in $others)) "crud, auth and the rest keep the shared configuration"
		if ($variant | str contains "tenant") {
			let added = ($both.engine | where kind in $own_kinds | get kind | sort)
			assert equal $added [LimitRange ObjectStore ResourceQuota ScheduledBackup]
		}
		rm -rf $w.dir
	}
}

def test_data_and_order_match_upstreams_main [fx: record, --adopt] {
	print $"test ($fx.name): the engine's release data and kubectl order are those of upstream's `main -e gke`(if $adopt { ' with --adopt' } else { '' })..."
	# Upstream's main, over the fakes.
	let up = (sandbox $fx)
	let r = (in-world $up ((runtime-dir) | path join k8s release.nu) --app $up.app -e gke)
	assert equal $r.exit_code 0 $"($r.stdout | lines | last 20 | str join (char nl))\n($r.stderr)"
	# The data it handed CUE last: the roles and the pushed images, two JSON files of one call.
	let calls = (ls ($up.dir | path join rec) | where type == dir | get name | sort-by {|n| $n | path basename | into int })
	let last = ($calls | where {|c| (ls $c | where name =~ '\.json$' | length) >= 2 } | last)
	let upstream_data = (ls $last | where name =~ '\.json$' | get name | each {|f| open $f } | reduce {|it, acc| $acc | merge deep $it })
	# The engine, over a second world, with the digests the fake docker gave (a hash of the repository).
	let en = (sandbox $fx)
	let registry = "127.0.0.1:5000"
	let pushed = ($fx.build | append ($fx.tuned?.images? | default []) | each {|s|
		[$s {tag: (if $s == "database" { "17" } else { "latest" }), digest: $"sha256:(($"($registry)/($fx.name)-($s)") | hash sha256)"}]
	} | into record)
	let script = $"use ($engine_dir | path join render.nu); use ($engine_dir | path join runtime.nu); use ($release_nu) [release-app]; let app_info = \(runtime resolve-app '($en.app)'\); let node = \(render node-config $app_info.cue_path ''\); let meta = \(render app-meta $app_info.cue_path ''\); let compose = \(render compose-config $app_info.dir\); let facts = \(render facts $app_info.dir\); let pushed = ($pushed | to nuon); use ($release_nu) [preflight]; let fwd = {api: 1, buildkit: 2, registry: 3}; preflight $app_info $node $fwd --check | ignore; render release-data $app_info.dir $compose $facts $pushed 'https://contract.example.test' | save -f ($en.dir | path join data.json); release-app $app_info $node $meta $compose $facts [] $pushed (if $adopt { '--adopt' } else { '' })"
	let e = (in-world $en -c $script)
	assert equal $e.exit_code 0 $"($e.stdout | lines | last 20 | str join (char nl))\n($e.stderr)"
	# 2. data
	# the images of the engine's own services are not upstream's to push: the rest of the data is compared
	let mine = (open ($en.dir | path join data.json) | update App.image.pushed {|d| $d.App.image.pushed | reject -o ...($fx.tuned?.images? | default []) })
	assert equal ($mine | canon | to json) ($upstream_data | canon | to json) (differences $mine $upstream_data)
	# 3. order, but for the engine's own Namespace and record
	let want = (writes $up)
	let got = (writes $en ($fx.tuned?.logins? | default []) ($fx.tuned?.own? | default []) $fx.name)
	assert (($want | length) > 10) "upstream applied something"
	# what the engine adds for its own services is written: the token, and each Deployment rolled out
	let svcs = ($fx.tuned?.own? | default [])
	if ($svcs | is-not-empty) {
		let all = (writes $en ($fx.tuned.logins) [] $fx.name)
		assert ($"apply Secret/($fx.name)-service-token" in $all) "the service token is applied"
		for s in ($svcs | append (if ($fx.tuned.plane? | default false) { [rclone-s3 imgproxy metrics-export] } else { [] })) {
			assert ($"rollout deployment/($fx.name)-($s)" in $all) $"($s) is rolled out"
		}
	}
	print $"  ($want | length) writes and ((open ($en.dir | path join data.json) | columns | length)) data fields compared"
	assert equal $got $want
	rm -rf $up.dir $en.dir
}
