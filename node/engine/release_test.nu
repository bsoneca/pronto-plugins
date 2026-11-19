#!/usr/bin/env nu
# Run with: nu node/engine/release_test.nu   (needs `cue` and the CUE registry, and `PRONTO_RUNTIME` or
# mise's github:bonisoft3/pronto@1.6.0: the six helpers imported from upstream run for real)
#
# The release flow (release.nu) over fakes of kubectl, sops, ssh, nc, curl, docker (with buildx) and crane on
# the PATH: kubectl keeps a cluster's state in files and logs every call and the objects it was given, docker
# logs its calls and answers a build's metadata file. Nothing here reaches a cluster, a registry or a project.

const engine_dir = path self .

use std/assert
use tunnel.nu
use rollback.nu
use release.nu [run-hooks decrypt-secrets preflight release-app check-operators dry-run require-tools check-ownership]
use render.nu
use runtime.nu
use registry.nu
use push.nu

# The newest validated module (runtime.nu) the fixture renders with, and the runtime an app that pins it runs
# (its distribution config's tool version; contract_test.nu holds that).
const pin = "1.7.0"
const runtime_pin = "1.6.0"
const release_nu = (path self release.nu)

# The runtime upstream pronto 1.6.0 is installed as.
def runtime-dir []: nothing -> string {
	if ($env.PRONTO_RUNTIME? | is-not-empty) { $env.PRONTO_RUNTIME } else { ^mise where $"github:bonisoft3/pronto@($runtime_pin)" | str trim }
}

# A scratch world: the fake tools, their state, and the fixture app with the engine's schema written
# into it as the engine writes it into an app.
def sandbox []: nothing -> record {
	let d = (mktemp -d -t node-test.XXXXXX | str trim)
	for p in [bin state state/revision aprende] { mkdir ($d | path join $p) }
	^cp -R ($engine_dir | path join fixtures aprende/.) ($d | path join aprende)
	# the build's context is the app as git sees it
	do { cd ($d | path join aprende); ^git init -q . } | ignore
	let mod = ($d | path join aprende cue.mod module.cue)
	open $mod | str replace -r 'pronto@v1": v: "[^"]+"' $'pronto@v1": v: "v($pin)"' | save -f $mod
	mkdir ($d | path join aprende node schema)
	cp ($engine_dir | path join schema node.cue) ($d | path join aprende node schema node.cue)
	cp ($engine_dir | path join fixtures fake-kubectl) ($d | path join bin kubectl)
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
case "$*" in
  "-d "*) cat "$d/sops.yaml" ;;
  *) echo "sops: unexpected $*" >&2; exit 1 ;;
esac
'# | str trim --left | save -f ($d | path join bin sops)
	# nc answers once the fake ssh has started.
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
[ -f "$d/ssh_started" ]
'# | str trim --left | save -f ($d | path join bin nc)
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
echo "$*" >> "$d/ssh.log"
if [ -f "$d/ssh_denied" ]; then echo "user@node: Permission denied (publickey)." >&2; exit 255; fi
echo $$ > "$d/ssh.pid"
touch "$d/ssh_started"
exec sleep 60
'# | str trim --left | save -f ($d | path join bin ssh)
	# docker: compose config, and buildx as a remote builder would answer. A bake writes its metadata file (a
	# digest per target, the hash of its name) and keeps the tree it ran in, the compose it read and its builder.
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
echo "$*" >> "$d/docker.log"
case "$*" in
  *"compose"*"config --format json"*) cat "$d/compose.json" ;;
  *"compose"*"config"*) echo "services: {}" ;;
  "buildx version") echo "github.com/docker/buildx v0 fake" ;;
  "buildx create "*) echo "$DOCKER_CONFIG" > "$d/docker_config" ;;
  "buildx inspect "*) if [ -f "$d/platform_arm" ]; then echo "Platforms:        linux/arm64"; else echo "Platforms:        linux/amd64, linux/amd64/v2, linux/386"; fi ;;
  "buildx rm "*) ;;
  "buildx bake "*)
    pwd > "$d/bake_pwd"
    cat > "$d/bake_compose"
    find . -type f | sort > "$d/bake_tree"
    if [ -f "$d/bake_fail" ]; then { echo "ERROR: failed to solve"; cat "$d/bake_fail"; } >&2; exit 1; fi
    meta=""; targets=""; skip=0
    for a in "$@"; do
      if [ $skip = 1 ]; then skip=0; [ "$prev" = --metadata-file ] && meta="$a"; continue; fi
      case "$a" in
        buildx|bake) ;;
        -f|--builder|--metadata-file|--set) skip=1; prev="$a" ;;
        -*) ;;
        *) targets="$targets $a" ;;
      esac
    done
    printf '{' > "$meta"; sep=""
    for t in $targets; do
      printf '%s"%s":{"containerimage.digest":"sha256:%s"}' "$sep" "$t" "$(printf %s "$t" | shasum -a 256 | cut -d' ' -f1)" >> "$meta"; sep=","
    done
    printf '}' >> "$meta" ;;
esac
'# | str trim --left | save -f ($d | path join bin docker)
	# crane reads the database image's config from the node's registry
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
echo "$*" >> "$d/crane.log"
if [ -f "$d/crane_nopg" ]; then echo '{"config":{"Env":["PATH=/bin"]}}'; else echo '{"config":{"Env":["PATH=/bin","PG_MAJOR=17"]}}'; fi
'# | str trim --left | save -f ($d | path join bin crane)
	# curl: the registry answers 200 through the tunnel, unless it is down
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
if [ -f "$d/registry_dead" ]; then printf 000; exit 7; fi
printf 200
'# | str trim --left | save -f ($d | path join bin curl)
	# tools the preflight wants on the PATH: they are not run here
	"#!/bin/sh\nexit 0\n" | save -f ($d | path join bin docker-buildx)
	for t in [kubectl sops nc ssh docker crane curl docker-buildx] { ^chmod +x ($d | path join bin $t) }
	let compose = {services: {
		database: {}, crud: {}, electric: {}, caddy: {}
		auth: {environment: {OIDC_PROVIDERS: "google"}}
		migrate: {environment: {DATABASE_URL: "postgres://x", REQUIRED_TABLES: "a,b"}}
	}}
	$compose | to json | save -f ($d | path join compose.json)
	{dir: $d, app: ($d | path join aprende), state: ($d | path join state)}
}

# The environment a run has: the fakes first on the PATH, the fakes' state, upstream's runtime.
def --wrapped in-world [w: record, ...rest]: nothing -> record {
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), SOPS_AGE_KEY: "AGE-SECRET-KEY-FAKE"} {
		do { cd $w.app; ^$nu.current-exe --no-config-file ...$rest } | complete
	}
}

# What the fake kubectl was asked, one line a call, objects expanded to kind/name.
def calls [w: record]: nothing -> list<string> {
	let f = ($w.state | path join calls.jsonl)
	if not ($f | path exists) { return [] }
	open --raw $f | lines | each {|l| $l | from json } | each {|c|
		let objs = ($c.objects | each {|o| $"($o.kind)/($o.name)" })
		$"($c.args | str join ' ')(if ($objs | is-not-empty) { ' <- ' + ($objs | str join ',') } else { '' })"
	}
}

# The calls that change the cluster, as verb and what: no reads, no dry runs.
def writes [w: record]: nothing -> list<string> {
	calls $w | where {|c| ($c | split row " " | first) in [apply delete annotate rollout] and not ($c | str contains "--dry-run") and not ($c | str contains "rollout status") }
}

def script [w: record, body: string]: nothing -> string {
	$"use ($engine_dir | path join release.nu) *; use ($engine_dir | path join render.nu); use ($engine_dir | path join runtime.nu); ($body)"
}

# The release's inputs, as main reads them.
def inputs [w: record, --preview: string = ""]: nothing -> string {
	$"let app_info = \(runtime resolve-app '($w.app)'\); let node = \(render node-config $app_info.cue_path '($preview)'\); let meta = \(render app-meta $app_info.cue_path '($preview)'\); let compose = \(render compose-config $app_info.dir\); let facts = \(render facts $app_info.dir\); let fwd = {api: 1, buildkit: 2, registry: 3};"
}

def pushed-json []: nothing -> string {
	let digest = "sha256:" + ("a" | fill -c "a" -w 64)
	let svcs = [database crud electric auth caddy migrate]
	($svcs | each {|s| [$s {tag: (if $s == "database" { "17" } else { "release" }), digest: $digest}] } | into record) | to nuon
}

def main [] {
	print "Running node release tests...\n"
	test_check_makes_no_write
	test_check_on_a_missing_namespace_asks_in_default
	test_release_steps_in_order
	test_a_failed_rollout_undoes_only_the_changed_deployments
	test_a_new_deployment_has_nothing_to_undo
	test_a_failed_job_stops_before_the_deployments
	test_a_rejected_dry_run_writes_nothing_of_the_release
	test_operators_that_differ_are_refused_before_any_write
	test_backups_need_their_secret
	test_sops_secrets_go_to_the_namespace_of_the_preview
	test_hooks_run_in_the_app_with_the_release_named
	test_delete_refuses_the_release_namespace
	test_tunnel_is_opened_once_and_closed_on_a_failure
	test_each_release_has_its_own_tunnel_port_and_kubeconfig
	test_ssh_that_is_not_user_at_host_never_runs
	test_a_refused_login_fails_with_ssh_message_and_is_not_asked_again
	test_refusals
	test_retire_is_deleted_as_kind_dot_group
	test_dry_run_leaves_jobs_an_earlier_release_left_alone
	test_check_and_delete_cannot_be_given_together
	test_preflight_refuses_a_pin_nobody_validated
	test_preflight_needs_its_tools
	test_a_database_that_never_comes_up_gets_its_old_image_back
	test_a_failed_read_is_never_taken_for_absent
	test_serving_prints_the_recorded_commit
	test_a_failed_deployment_read_is_neither_unchanged_nor_changed
	test_a_namespace_the_release_did_not_label_is_not_its_to_touch
	test_rollback_goes_through_every_deployment
	test_barman_and_gateway_api_versions_are_checked
	test_sops_keeps_secrets_alone_and_no_backup_credentials_for_a_preview
	test_a_release_builds_on_the_nodes_buildkitd_and_pushes_to_its_registry
	test_the_build_context_is_the_tree_git_sees
	test_untracked_secret_looking_files_are_not_staged
	test_build_include_stages_the_ignored_files_it_names
	test_check_build_pushes_under_check_and_writes_nothing_to_the_cluster
	test_build_alone_is_refused
	test_a_failed_bake_leaves_no_builder_and_no_scratch_folder
	test_the_buildx_nearest_the_front_of_the_path_wins
	test_a_broken_session_names_the_buildx_that_broke_it
	test_preflight_refuses_a_builder_or_a_registry_that_is_not_there
	test_the_registry_prune_reads_what_the_cluster_names
	test_a_failed_read_stops_the_prune_before_it_deletes_anything
	test_the_registry_restarts_after_its_collection_when_it_caches_blobs
	test_the_prune_outcome_is_recorded_in_the_release_configmap
	test_a_database_image_without_pg_major_is_an_explicit_error
	print "\nAll node release tests passed."
}

def test_check_makes_no_write [] {
	print "test --check renders over placeholder digests and writes nothing, builds nothing..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --check)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert equal (writes $w) []
	let all = (calls $w)
	assert ($all | any {|c| $c | str contains "apply --dry-run=server" }) "the objects were asked of the server"
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "no image was built"
	assert (has $r.stdout "check passed")
	rm -rf $w.dir
}

def test_check_on_a_missing_namespace_asks_in_default [] {
	print "test --check on a namespace that does not exist yet asks the objects in default, the Namespace as it is..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --check)
	assert equal $r.exit_code 0 $r.stderr
	assert (has $r.stdout "does not exist yet")
	let last = (open --raw ($w.state | path join last_objects.json) | from json)
	assert (($last | where kind != Namespace | all {|o| $o.metadata.namespace == "default" }))
	rm -rf $w.dir
}

def test_release_steps_in_order [] {
	print "test a release applies the namespace, secrets, objects, jobs, roles, deployments and records, in upstream's order..."
	let w = (sandbox)
	"apiVersion: v1\nkind: Secret\nmetadata:\n  name: aprende-secrets\ndata:\n  K: dg==\n" | save -f ($w.dir | path join sops.yaml)
	"" | save -f ($w.app | path join secrets.metal.enc.yaml)
	let r = (in-world $w -c (script $w $"(inputs $w) let secrets = \(preflight $app_info $node $fwd\); release-app $app_info $node $meta $compose $facts $secrets (pushed-json)"))
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let log = (writes $w)
	let kinds = ($log | each {|c| $c | split row " " | first })
	# the first writes: the Namespace, then the SOPS Secret, then every object but Deployments and Jobs
	assert ($log.0 | str starts-with "apply -f - <- Namespace/aprende") $log.0
	assert ($log.1 | str starts-with "apply --server-side --force-conflicts --field-manager=pronto-sops") $log.1
	assert (has $log.1 "Secret/aprende-secrets")
	assert ($log.2 | str starts-with "apply -f -")
	assert (not ($log.2 | str contains "Deployment/")) "no Deployment before the jobs"
	assert (not ($log.2 | str contains "Job/"))
	# jobs in jobOrder, each replacing the last release's
	let job_lines = ($log | enumerate | where {|e| $e.item =~ "(delete job|Job/)" })
	assert equal ($job_lines | get item | each {|l| $l | str replace -r "^.*(aprende-[a-z]+).*$" "$1" }) [aprende-initdb aprende-initdb aprende-migrate aprende-migrate]
	let at = {|pat| $log | enumerate | where {|e| $e.item =~ $pat } | get index | first }
	let annotate = (do $at "annotate cluster.postgresql.cnpg.io/aprende-db")
	let deployments = (do $at "Deployment/aprende-crud")
	assert (($job_lines | last | get index) < $annotate) "jobs before the roles"
	assert ($annotate < $deployments) "roles before the deployments"
	assert (($log | last) | str starts-with "apply -f - <- ConfigMap/pronto-release") ($log | last)
	assert ((calls $w) | any {|c| $c | str contains "rollout status deployment/aprende-crud" })
	assert (has $r.stdout "[SUCCESS] Released aprende")
	# the echo hook ran after the jobs: its output is in the log
	assert (has $r.stdout "restate")
	rm -rf $w.dir
}

def test_a_failed_rollout_undoes_only_the_changed_deployments [] {
	print "test a failed rollout puts back the Deployments the release changed, not the unchanged one..."
	let w = (sandbox)
	for n in [crud electric auth caddy] { "3" | save -f ($w.state | path join revision $"aprende-($n)") }
	"aprende-caddy" | save -f ($w.state | path join unchanged)
	"aprende-electric" | save -f ($w.state | path join rollout_fail)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "exceeded its progress deadline") $r.stderr
	assert (has $r.stderr "rolled back aprende-crud, aprende-electric, aprende-auth") $r.stderr
	let undone = (calls $w | where {|c| $c | str starts-with "rollout undo" })
	assert equal $undone ["rollout undo deployment/aprende-crud -n aprende --to-revision=3" "rollout undo deployment/aprende-electric -n aprende --to-revision=3" "rollout undo deployment/aprende-auth -n aprende --to-revision=3"]
	assert (not ((calls $w) | any {|c| $c | str contains "ConfigMap/pronto-release" })) "a failed release records nothing"
	rm -rf $w.dir
}

def test_a_new_deployment_has_nothing_to_undo [] {
	print "test a first release that fails has no earlier revision to go back to..."
	let w = (sandbox)
	"aprende-crud" | save -f ($w.state | path join rollout_fail)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	assert equal (calls $w | where {|c| $c | str starts-with "rollout undo" }) []
	rm -rf $w.dir
}

def test_a_failed_job_stops_before_the_deployments [] {
	print "test a Job that fails stops the release before any Deployment is applied..."
	let w = (sandbox)
	"" | save -f ($w.state | path join job_fail)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "did not complete") $r.stderr
	assert (not ((writes $w) | any {|c| $c | str contains "Deployment/" })) "no Deployment was applied"
	rm -rf $w.dir
}

def test_a_rejected_dry_run_writes_nothing_of_the_release [] {
	print "test the server's refusal of an object stops the release after the Namespace and before the rest..."
	let w = (sandbox)
	"Cluster" | save -f ($w.state | path join reject)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "admission webhook denied") $r.stderr
	assert equal (writes $w | length) 1
	rm -rf $w.dir
}

def test_operators_that_differ_are_refused_before_any_write [] {
	print "test a node whose Dapr is not the version the schema was written for refuses the release..."
	let w = (sandbox)
	{"dapr-operator": "docker.io/daprio/operator:1.14.4"} | to json | save -f ($w.state | path join operators.json)
	let r = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node $fwd"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "dapr: the node runs 1.14.4, the engine's schema is written for 1.16.21") $r.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_backups_need_their_secret [] {
	print "test backups without their credentials' Secret refuse the release before any write..."
	let w = (sandbox)
	let body = (inputs $w) + " let node = ($node | upsert backups {credentials: 'aprende-backup-s3', bucket: 'b', path: 'p'}); preflight $app_info $node $fwd"
	let r = (in-world $w -c (script $w $body))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "aprende-backup-s3, which is neither in the SOPS file nor in aprende") $r.stderr
	# present in the namespace: passes
	mkdir ($w.state | path join secrets)
	"" | save -f ($w.state | path join secrets aprende-backup-s3)
	let ok = (in-world $w -c (script $w $body))
	assert equal $ok.exit_code 0 $ok.stderr
	rm -rf $w.dir
}

def test_sops_secrets_go_to_the_namespace_of_the_preview [] {
	print "test the SOPS Secrets are decrypted in memory and put in the preview's namespace..."
	let w = (sandbox)
	"apiVersion: v1\nkind: Secret\nmetadata:\n  name: a\n  namespace: aprende\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: b\n" | save -f ($w.dir | path join sops.yaml)
	let r = (in-world $w -c $"use ($engine_dir | path join release.nu) [decrypt-secrets]; decrypt-secrets 'x.enc.yaml' aprende-rc | get metadata.namespace | to json --raw")
	assert equal $r.exit_code 0 $r.stderr
	assert equal ($r.stdout | str trim) '["aprende-rc","aprende-rc"]'
	rm -rf $w.dir
}

def test_hooks_run_in_the_app_with_the_release_named [] {
	print "test hooks.afterJobs run in the app's folder, told the context, the namespace and the app..."
	let d = (mktemp -d -t node-hook.XXXXXX | str trim)
	run-hooks [["sh" "-c" "echo $NODE_CONTEXT $NODE_NAMESPACE $NODE_APP $(pwd -P | xargs basename) > out"]] $d contabo2 aprende-rc aprende
	assert equal (open --raw ($d | path join out) | str trim) $"contabo2 aprende-rc aprende ($d | path expand | path basename)"
	let failed = (try { run-hooks [["sh" "-c" "echo boom >&2; exit 3"]] $d c n a; "no" } catch {|e| $e.msg })
	assert (has $failed "boom") $failed
	rm -rf $d
}

def test_delete_refuses_the_release_namespace [] {
	print "test --delete refuses production's namespace, and without a preview..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --delete)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "--delete removes a preview's namespace; aprende is the release's") $r.stderr
	assert equal (writes $w) []
	let ok = (in-world $w $release_nu --app $w.app --delete --preview rc)
	assert equal $ok.exit_code 0 $"($ok.stdout)($ok.stderr)"
	assert equal (writes $w) ["delete namespace aprende-rc --ignore-not-found --wait=true"]
	rm -rf $w.dir
}

# Whether `text` holds `needle`, nushell's error rendering having wrapped its lines.
def has [text: string, needle: string]: nothing -> bool {
	let flat = {|t| $t | str replace -a -r '[|\s]+' '' }
	(do $flat $text) | str contains (do $flat $needle)
}

# What the tunnel tests give it: api.ssh and the node-side ports of the build's forwards.
const api = {ssh: "deploy@node.example", remotePort: 6443}
const build = {buildkit: {port: 1234}, registry: {port: 5000}}

def alive [pid: int]: nothing -> bool { (^kill -0 $pid | complete).exit_code == 0 }

def test_tunnel_is_opened_once_and_closed_on_a_failure [] {
	print "test the ssh tunnel opens once, in BatchMode, and is closed when the body fails..."
	let w = (sandbox)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let msg = (with-env {PATH: $path} {
		try { tunnel with-tunnel $api $build {|fwd| error make {msg: "the release failed"} }; "no error" } catch {|e| $e.msg }
	})
	assert equal $msg "the release failed"
	let log = (open --raw ($w.dir | path join ssh.log) | lines)
	assert equal ($log | length) 1
	assert (has $log.0 "-N -o BatchMode=yes")
	assert (has $log.0 "-o ExitOnForwardFailure=yes")
	assert (has $log.0 "-o IdentitiesOnly=yes -o ConnectTimeout=10")
	assert ($log.0 =~ '-L [0-9]+:127.0.0.1:6443 -L [0-9]+:127.0.0.1:1234 -L [0-9]+:127.0.0.1:5000 deploy@node.example')
	assert (not ($log.0 | str contains "-L 26444:")) "never a port another release may hold"
	let ports = ($log.0 | parse --regex '-L (?<p>[0-9]+):' | get p)
	assert equal ($ports | length) 3 "the API, the buildkitd and the registry"
	assert equal ($ports | uniq | length) 3 "three ports of their own"
	assert (not ("5000" in $ports)) "never local port 5000: macOS's AirPlay receiver holds it"
	let pid = (open --raw ($w.dir | path join ssh.pid) | str trim | into int)
	sleep 300ms
	assert (not (alive $pid)) "the tunnel is closed"
	rm -rf $w.dir
}

def test_each_release_has_its_own_tunnel_port_and_kubeconfig [] {
	print "test a tunnel already open is not shared: each release has its own port and kubeconfig, and the port only counts while its ssh lives..."
	let w = (sandbox)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let got = (with-env {PATH: $path, FAKE_DIR: $w.state} {
		let one = (tunnel with-tunnel $api $build {|fwd| {port: $fwd.api, cfg: (open --raw (tunnel kubeconfig contabo2 $fwd.api))} })
		rm -f ($w.dir | path join ssh_started)
		let two = (tunnel with-tunnel $api $build {|fwd| {port: $fwd.api} })
		{one: $one, two: $two}
	})
	assert ($got.one.cfg | str contains $"https://127.0.0.1:($got.one.port)") "the kubeconfig points at the release's tunnel"
	assert ($got.one.port != 26444)
	assert equal (open --raw ($w.dir | path join ssh.log) | lines | length) 2
	rm -rf $w.dir
}

def test_ssh_that_is_not_user_at_host_never_runs [] {
	print "test an api.ssh that is an option or a bare host never reaches ssh..."
	let w = (sandbox)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	for bad in ["-oProxyCommand=x@y" "node.example"] {
		let msg = (with-env {PATH: $path} { try { tunnel with-tunnel {ssh: $bad, remotePort: 6443} $build {|fwd| "in" }; "no error" } catch {|e| $e.msg } })
		assert (has $msg "it must be user@host") $msg
	}
	assert (not ($w.dir | path join ssh.log | path exists)) "ssh was not started"
	rm -rf $w.dir
}

def test_a_refused_login_fails_with_ssh_message_and_is_not_asked_again [] {
	print "test a refused ssh login fails the release with ssh's message after one try..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join ssh_denied)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let msg = (with-env {PATH: $path} {
		try { tunnel with-tunnel $api $build {|fwd| "in" }; "no error" } catch {|e| $e.msg }
	})
	assert (has $msg "Permission denied (publickey)") $msg
	assert equal (open --raw ($w.dir | path join ssh.log) | lines | length) 1
	rm -rf $w.dir
}

def test_refusals [] {
	print "test a release refuses what it does not do yet or what would hurt, before anything is built..."
	let w = (sandbox)
	let r = (in-world $w -c (script $w $"(inputs $w) refuse $app_info $node $meta {services: {airlock: {}}} false"))
	assert (has $r.stderr "runs the airlock") $r.stderr
	let r2 = (in-world $w -c (script $w $"(inputs $w) refuse $app_info \($node | upsert name 'other'\) $meta $compose false"))
	assert (has $r2.stderr "the app's folder is aprende, but its Node is named other") $r2.stderr
	let r3 = (in-world $w -c (script $w $"(inputs $w) refuse $app_info $node $meta $compose true"))
	assert (has $r3.stderr "render.enabled is true but the app's compose project lacks a render service") $r3.stderr
	let r4 = (in-world $w -c (script $w $"(inputs $w) refuse $app_info \($node | upsert preview 'x'\) $meta $compose false"))
	assert (has $r4.stderr "the preview x would release into the production namespace aprende") $r4.stderr
	rm -rf $w.dir
}

def with-node [w: record, change: string, then: string]: nothing -> string {
	$"(inputs $w) let node = \($node | ($change)\); ($then)"
}

def test_retire_is_deleted_as_kind_dot_group [] {
	print "test retire deletes by kind.group, so no alias can name another resource..."
	let w = (sandbox)
	let body = (with-node $w "upsert retire [{kind: Deployment, name: old, resource: deployment.apps}]" $"release-app $app_info $node $meta $compose $facts [] (pushed-json)")
	let r = (in-world $w -c (script $w $body))
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	assert ((calls $w) | any {|c| $c == "delete deployment.apps old -n aprende --ignore-not-found" })
	rm -rf $w.dir
}

def test_dry_run_leaves_jobs_an_earlier_release_left_alone [] {
	print "test the server dry run does not apply a Job over the earlier release's (immutable template), it creates it under another name..."
	let w = (sandbox)
	"aprende-initdb aprende-migrate" | save -f ($w.state | path join existing_jobs)
	let r = (in-world $w $release_nu --app $w.app --check)
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	let log = (calls $w)
	assert ($log | any {|c| $c =~ "^create --dry-run=server -f - <- Job/aprende-initdb-dryrun,Job/aprende-migrate-dryrun$" }) ($log | str join "\n")
	assert (not ($log | any {|c| $c =~ "apply --dry-run=server.*Job/" })) "no Job was applied in place"
	assert equal (writes $w) []
	# and the release itself goes through
	let r2 = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $r2.exit_code 0 $"($r2.stdout)($r2.stderr)"
	rm -rf $w.dir
}

def test_check_and_delete_cannot_be_given_together [] {
	print "test --check --delete is refused and writes nothing..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --check --delete --preview rc)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "--check and --delete cannot be given together") $r.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_preflight_refuses_a_pin_nobody_validated [] {
	print "test a pronto runtime outside validated_pins is refused in the preflight..."
	let w = (sandbox)
	let r = (in-world $w -c (script $w $"(inputs $w) $env.PRONTO_RUNTIME = '($w.dir)/9.9.9'; preflight $app_info $node $fwd --check"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "the pronto runtime is 9.9.9; this engine is validated against 1.5.0, 1.5.1, 1.6.0, 1.7.0") $r.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_preflight_needs_its_tools [] {
	print "test a tool missing from the PATH fails the preflight, naming it..."
	let msg = (try { require-tools ["sh" "no-such-tool-xyz"]; "no error" } catch {|e| $e.msg })
	assert (has $msg "missing on the PATH: no-such-tool-xyz") $msg
	let w = (sandbox)
	# a check needs no crane
	let ok = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node $fwd --check"))
	assert equal $ok.exit_code 0 $ok.stderr
	rm -rf $w.dir
}

def test_a_database_that_never_comes_up_gets_its_old_image_back [] {
	print "test a database that does not come up on the new image is put back on the old one..."
	let w = (sandbox)
	"reg/aprende-database:17@sha256:old" | save -f ($w.state | path join previous_image)
	"" | save -f ($w.state | path join noprimary)
	let body = (with-node $w "upsert waits.primary 1" $"release-app $app_info $node $meta $compose $facts [] (pushed-json)")
	let r = (in-world $w -c (script $w $body))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "has no ready primary on")
	let patch = (calls $w | where {|c| $c | str starts-with "patch cluster.postgresql.cnpg.io/aprende-db" })
	assert equal ($patch | length) 1
	assert (has $patch.0 "imageName") 
	assert (has $patch.0 "reg/aprende-database:17@sha256:old")
	rm -rf $w.dir
}

def test_a_failed_read_is_never_taken_for_absent [] {
	print "test a failed read of the namespace, the database or a Deployment aborts, and only an absent one is absent..."
	let w = (sandbox)
	# the namespace: absent passes, a failed read refuses before any delete
	let absent = (in-world $w -c (script $w $"(inputs $w) check-ownership aprende $node"))
	assert equal $absent.exit_code 0 $absent.stderr
	"" | save -f ($w.state | path join read_fail_namespace)
	let del = (in-world $w $release_nu --app $w.app --delete --preview rc)
	assert ($del.exit_code != 0)
	assert (has $del.stderr "reading namespace aprende-rc failed, so its owner is unknown") $del.stderr
	assert equal (writes $w) []
	rm -f ($w.state | path join read_fail_namespace)
	# the database: a failed read stops the release before the Deployments
	"" | save -f ($w.state | path join read_fail_cluster)
	let c = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($c.exit_code != 0)
	assert (has $c.stderr "reading the database cluster aprende-db failed") $c.stderr
	assert (not ((writes $w) | any {|x| $x | str contains "Deployment/" })) "no Deployment was applied"
	rm -f ($w.state | path join read_fail_cluster)
	# a refused recovery patch is told with the startup error
	rm -f ($w.state | path join calls.jsonl)
	"reg/aprende-database:17@sha256:old" | save -f ($w.state | path join previous_image)
	"" | save -f ($w.state | path join noprimary)
	"" | save -f ($w.state | path join patch_fail)
	let body = (with-node $w "upsert waits.primary 1" $"release-app $app_info $node $meta $compose $facts [] (pushed-json)")
	let p = (in-world $w -c (script $w $body))
	assert ($p.exit_code != 0)
	assert (has $p.stderr "has no ready primary on") $p.stderr
	assert (has $p.stderr "putting back the database image reg/aprende-database:17@sha256:old failed") $p.stderr
	rm -rf $w.dir
}

def test_serving_prints_the_recorded_commit [] {
	print "test --serving prints the recorded commit (empty when none), writes nothing, and a failed read fails..."
	let w = (sandbox)
	let none = (in-world $w $release_nu --app $w.app --serving)
	assert equal $none.exit_code 0 $none.stderr
	assert (has $none.stdout "serving ") $none.stdout
	"abc123def" | save -f ($w.state | path join serving_sha)
	let r = (in-world $w $release_nu --app $w.app --serving)
	assert equal $r.exit_code 0 $r.stderr
	assert (has $r.stdout "serving abc123def") $r.stdout
	assert equal (writes $w) []
	let both = (in-world $w $release_nu --app $w.app --serving --check)
	assert ($both.exit_code != 0) "--serving goes with no other flag"
	"" | save -f ($w.state | path join read_fail_cluster)
	let bad = (in-world $w $release_nu --app $w.app --serving)
	assert ($bad.exit_code != 0) "a failed read fails"
	rm -rf $w.dir
}

def test_a_failed_deployment_read_is_neither_unchanged_nor_changed [] {
	print "test a Deployment whose revision cannot be read is a rollback failure, one that is absent has revision 0..."
	let w = (sandbox)
	let r0 = (in-world $w -c (script $w $"use ($engine_dir | path join rollback.nu); rollback revision aprende-crud aprende"))
	assert (has $r0.stdout "0") $r0.stdout
	"3" | save -f ($w.state | path join revision aprende-electric)
	"3" | save -f ($w.state | path join revision aprende-crud)
	"aprende-crud" | save -f ($w.state | path join read_fail_deployment)
	let e = (in-world $w -c (script $w $"use ($engine_dir | path join rollback.nu); rollback revision aprende-crud aprende"))
	assert ($e.exit_code != 0) "a failed read is an error, not revision 0"
	let u = (in-world $w -c (script $w $"use ($engine_dir | path join rollback.nu); rollback undo [{name: aprende-crud, revision: 3}, {name: aprende-electric, revision: 3}] aprende | to json --raw"))
	assert equal $u.exit_code 0 $u.stderr
	assert (has $u.stdout '"failed":[{"name":"aprende-crud"') $u.stdout
	assert equal (calls $w | where {|c| $c | str starts-with "rollout undo" }) [] "nothing was undone: electric is unchanged, crud could not be read"
	rm -rf $w.dir
}

def test_a_namespace_the_release_did_not_label_is_not_its_to_touch [] {
	print "test an existing namespace without the release's label is refused (and never deleted), --adopt takes it for a release..."
	let w = (sandbox)
	mkdir ($w.state | path join namespaces)
	"{}" | save -f ($w.state | path join namespaces aprende-rc)
	"{}" | save -f ($w.state | path join namespaces aprende)
	let del = (in-world $w $release_nu --app $w.app --delete --preview rc)
	assert ($del.exit_code != 0)
	assert (has $del.stderr "namespace aprende-rc exists but is not labelled pronto.dev/release=aprende and pronto.dev/preview=rc") $del.stderr
	assert equal (writes $w) []
	let refused = (in-world $w -c (script $w $"(inputs $w) check-ownership aprende $node"))
	assert ($refused.exit_code != 0)
	assert (has $refused.stderr "--adopt takes it")
	let adopted = (in-world $w -c (script $w $"(inputs $w) check-ownership aprende $node --adopt"))
	assert equal $adopted.exit_code 0 $adopted.stderr
	let adopted_delete = (in-world $w -c (script $w $"(inputs $w) check-ownership aprende \($node | upsert preview rc\) --adopt --delete"))
	assert ($adopted_delete.exit_code != 0) "--adopt never takes a namespace to delete it"
	# labelled, and the preview's name right: passes
	{"pronto.dev/release": "aprende", "pronto.dev/preview": "rc"} | to json | save -f ($w.state | path join namespaces aprende-rc)
	let ok = (in-world $w $release_nu --app $w.app --delete --preview rc)
	assert equal $ok.exit_code 0 $"($ok.stdout)($ok.stderr)"
	assert equal (writes $w) ["delete namespace aprende-rc --ignore-not-found --wait=true"]
	rm -rf $w.dir
}

def test_rollback_goes_through_every_deployment [] {
	print "test a Deployment that cannot be put back does not stop the others, and every failure is told..."
	let w = (sandbox)
	for n in [crud electric auth caddy] { "3" | save -f ($w.state | path join revision $"aprende-($n)") }
	"aprende-crud" | save -f ($w.state | path join undo_fail)
	"aprende-electric" | save -f ($w.state | path join rollout_fail)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	let undone = (calls $w | where {|c| $c | str starts-with "rollout undo" })
	assert equal ($undone | length) 4 "every Deployment was tried"
	assert (has $r.stderr "rolled back aprende-electric, aprende-auth, aprende-caddy") $r.stderr
	assert (has $r.stderr "could not roll back aprende-crud: error: no rollout history found") $r.stderr
	rm -rf $w.dir
}

def test_barman_and_gateway_api_versions_are_checked [] {
	print "test the barman-cloud plugin's and the Gateway API's versions are held to #Operators..."
	let w = (sandbox)
	{"barman-cloud": "ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.14.0"} | to json | save -f ($w.state | path join operators.json)
	let r = (in-world $w -c (script $w $"(inputs $w) check-operators $node"))
	assert (has $r.stderr "barmanCloud: the node runs 0.14.0, the engine's schema is written for 0.15.1") $r.stderr
	rm -f ($w.state | path join operators.json)
	"v1.1.0" | save -f ($w.state | path join gateway_api)
	let g = (in-world $w -c (script $w $"(inputs $w) check-operators $node"))
	assert (has $g.stderr "the node's Gateway API CRDs are 1.1.0, the engine's schema is written for 1.2.1") $g.stderr
	rm -rf $w.dir
}

def test_sops_keeps_secrets_alone_and_no_backup_credentials_for_a_preview [] {
	print "test only Secrets of the SOPS file are applied, and a preview gets no backup credentials..."
	let w = (sandbox)
	"apiVersion: v1\nkind: Secret\nmetadata:\n  name: keep\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: notasecret\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: aprende-backup-s3\n" | save -f ($w.dir | path join sops.yaml)
	"" | save -f ($w.app | path join secrets.metal.enc.yaml)
	let body = (inputs $w --preview rc) + " let node = ($node | upsert backups {credentials: 'aprende-backup-s3', bucket: 'b', path: 'p'}); preflight $app_info $node $fwd --check | each {|s| $s.metadata.name + '@' + $s.metadata.namespace } | to json --raw"
	let r = (in-world $w -c (script $w $body))
	assert equal $r.exit_code 0 $r.stderr
	assert equal ($r.stdout | str trim) '["keep@aprende-rc"]'
	rm -rf $w.dir
}

# The docker calls of a world, one line each.
def docker-calls [w: record]: nothing -> list<string> {
	let f = ($w.dir | path join docker.log)
	if ($f | path exists) { open --raw $f | lines } else { [] }
}

# The local ports ssh was asked to forward: api, buildkit, registry.
def forwarded [w: record]: nothing -> record {
	let p = (open --raw ($w.dir | path join ssh.log) | lines | first | parse --regex '-L (?<p>[0-9]+):' | get p)
	{api: $p.0, buildkit: $p.1, registry: $p.2}
}

def test_a_release_builds_on_the_nodes_buildkitd_and_pushes_to_its_registry [] {
	print "test a release builds through a remote builder on the tunnel's buildkitd port, tags the node registry's names, reads the database's major, and a failed prune is only a warning..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let fwd = (forwarded $w)
	let docker = (docker-calls $w)
	let create = ($docker | where {|l| $l | str starts-with "buildx create" })
	assert equal ($create | length) 2 "one builder for the preflight, one for the build"
	assert ($create | all {|l| $l =~ $"^buildx create --name node-[a-z0-9]{6} --driver remote tcp://127.0.0.1:($fwd.buildkit)$" }) ($create | str join "\n")
	let bake = ($docker | where {|l| $l | str starts-with "buildx bake" })
	assert equal ($bake | length) 1
	assert (has $bake.0 "--push --provenance=false")
	assert (has $bake.0 "--set *.platform=linux/amd64")
	assert ($bake.0 =~ '--builder node-[a-z0-9]{6} ')
	assert ($bake.0 =~ '--allow=fs.read=\S+/app')
	for svc in [database crud electric auth caddy migrate] {
		assert (has $bake.0 $"--set ($svc).tags=127.0.0.1:5000/aprende-($svc):release") $"($svc) is tagged as the node names it"
	}
	assert (not ($bake.0 | str contains "cache-from")) "the buildkitd's own cache, not the registry's"
	# the database's tag is its PG_MAJOR, read from the registry through the tunnel
	let crane = (open --raw ($w.dir | path join crane.log) | lines)
	assert ($crane.0 =~ $"^config --insecure 127.0.0.1:($fwd.registry)/aprende-database@sha256:[0-9a-f]{64}$") $crane.0
	assert ((open --raw ($w.state | path join cluster_image) | str trim) =~ '^127.0.0.1:5000/aprende-database:17@sha256:[0-9a-f]{64}$')
	# the builders are gone
	assert equal ($docker | where {|l| $l | str starts-with "buildx rm node-" } | length) 2
	assert (not ((open --raw ($w.dir | path join docker_config) | str trim) | path exists)) "the release's docker config is gone"
	assert (has $r.stdout "[SUCCESS] Released aprende")
	# no listener behind the registry's forward: the prune fails, and the release is live all the same
	assert (has $r.stderr "warning: the node's registry was not pruned") $r.stderr
	assert (not ((open --raw ($w.dir | path join ssh.log) | str contains "-L 5000:")))
	# a preview is tagged for itself
	let p = (in-world $w $release_nu --app $w.app --preview rc)
	assert equal $p.exit_code 0 $"($p.stdout)\n($p.stderr)"
	let pbake = (docker-calls $w | where {|l| $l | str starts-with "buildx bake" } | last)
	assert (has $pbake "--set crud.tags=127.0.0.1:5000/aprende-crud:rc")
	rm -rf $w.dir
}

def test_the_build_context_is_the_tree_git_sees [] {
	print "test the build context is the app as git sees it: no ignored file, no .certs/..."
	let w = (sandbox)
	"ignored.txt\n" | save -f ($w.app | path join .gitignore)
	"x" | save -f ($w.app | path join ignored.txt)
	"x" | save -f ($w.app | path join kept.txt)
	mkdir ($w.app | path join .certs)
	"KEY" | save -f ($w.app | path join .certs key.pem)
	let r = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let tree = (open --raw ($w.dir | path join bake_tree) | lines)
	assert ("./kept.txt" in $tree) ($tree | str join "\n")
	assert ("./.gitignore" in $tree)
	assert (not ("./ignored.txt" in $tree)) "an ignored file is not uploaded"
	assert (not ($tree | any {|f| $f | str starts-with "./.certs/" })) "no certificate pair"
	assert ((open --raw ($w.dir | path join bake_pwd) | str trim) | str ends-with "/app") "bake runs in the staged tree"
	rm -rf $w.dir
}

def test_check_build_pushes_under_check_and_writes_nothing_to_the_cluster [] {
	print "test --check --build builds under the tag check, dry-runs with the real digests and writes nothing to the cluster..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let bake = (docker-calls $w | where {|l| $l | str starts-with "buildx bake" })
	assert equal ($bake | length) 1
	assert (has $bake.0 "--set crud.tags=127.0.0.1:5000/aprende-crud:check")
	assert equal (writes $w) []
	assert (has $r.stdout "check passed")
	let last = (open --raw ($w.state | path join all_objects.jsonl))
	assert ($last =~ 'aprende-crud:check@sha256:[0-9a-f]{64}') "the dry run names the pushed digest"
	assert (not ($last | str contains "0000000000000000")) "no placeholder digest"
	assert (not ((open --raw ($w.dir | path join ssh.log)) | str contains "garbage")) "nothing is pruned by a check"
	assert (not ((calls $w) | any {|c| $c | str starts-with "exec" })) "a check never runs the registry's garbage collector"
	rm -rf $w.dir
}

def test_build_alone_is_refused [] {
	print "test --build without --check is refused before the tunnel opens..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app --build)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "--build only goes with --check: a release always builds") $r.stderr
	assert (not ($w.dir | path join ssh.log | path exists)) "ssh was not started"
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_a_failed_bake_leaves_no_builder_and_no_scratch_folder [] {
	print "test a bake that fails removes its builder and its scratch folder and writes nothing to the cluster..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join bake_fail)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "failed to solve") $r.stderr
	assert equal (writes $w) []
	let docker = (docker-calls $w)
	assert equal ($docker | where {|l| $l | str starts-with "buildx rm node-" } | length) 2 "both builders removed"
	let work = (open --raw ($w.dir | path join bake_pwd) | str trim | path dirname)
	assert (not ($work | path exists)) "the scratch folder is gone"
	assert (not ((open --raw ($w.dir | path join docker_config) | str trim) | path exists)) "the docker config is gone"
	rm -rf $w.dir
}

def test_the_buildx_nearest_the_front_of_the_path_wins [] {
	print "test the pinned buildx (the first folder on the PATH) is taken over a Homebrew one named docker-buildx..."
	let brew = "/opt/homebrew/bin/docker-buildx"
	let pinned = "/m/installs/aqua-docker-buildx/0.33.0/docker-cli-plugin-docker-buildx"
	assert equal (push nearest-on-path [$brew $pinned] ["/m/installs/aqua-docker-buildx/0.33.0" "/opt/homebrew/bin"]) $pinned
	assert equal (push nearest-on-path [$brew $pinned] ["/opt/homebrew/bin" "/m/installs/aqua-docker-buildx/0.33.0"]) $brew
	assert equal (push nearest-on-path [$brew] ["/usr/bin"]) $brew "off the PATH still answers"
}

def test_a_broken_session_names_the_buildx_that_broke_it [] {
	print "test a bake whose session broke says why, and one that failed otherwise does not..."
	let w = (sandbox)
	"received prior goaway: code: PROTOCOL_ERROR\n" | save -f ($w.dir | path join bake_fail)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "header values and a buildx built with Go 1.27 caps them at 500") $r.stderr
	assert (has $r.stderr "docker-buildx") $r.stderr
	rm -rf $w.dir
	let w = (sandbox)
	"#7 0.4 getaddrinfo ENOTFOUND jsr.io\n#7 ERROR: process did not complete successfully: exit code: 255\n" | save -f ($w.dir | path join bake_fail)
	let r = (in-world $w $release_nu --app $w.app)
	assert (not (has $r.stderr "caps them at 500")) $r.stderr
	assert (has $r.stderr "the failed step, #7") $r.stderr
	assert (has $r.stderr "getaddrinfo ENOTFOUND jsr.io") $r.stderr
	rm -rf $w.dir
}

def test_preflight_refuses_a_builder_or_a_registry_that_is_not_there [] {
	print "test a builder or a registry that is down, silent, or builds for another platform refuses before anything is built..."
	let cases = [
		{file: "buildkit_down", dir: state, says: "the node's builder is not running: deployment buildkitd in pronto-buildkit has no available replica"}
		{file: "registry_down", dir: state, says: "the node's registry is not running: deployment registry in pronto-registry has no available replica"}
		{file: "registry_dead", dir: dir, says: "the node's registry does not answer through the tunnel on 127.0.0.1:3/v2/"}
		{file: "platform_arm", dir: dir, says: "the node's buildkitd builds for linux/arm64, not linux/amd64"}
	]
	for c in $cases {
		let w = (sandbox)
		"" | save -f ($w | get $c.dir | path join $c.file)
		let r = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node $fwd --check"))
		assert ($r.exit_code != 0) $c.file
		assert (has $r.stderr $c.says) $"($c.file): ($r.stderr)"
		assert equal (writes $w) []
		assert (not ((docker-calls $w) | any {|l| $l | str starts-with "buildx bake" })) "nothing was built"
		rm -rf $w.dir
	}
}

def test_the_registry_prune_reads_what_the_cluster_names [] {
	print "test the prune keeps the node registry's digests the cluster names, as the node names the registry..."
	let a = ("sha256:" + ("a" | fill -c "a" -w 64))
	let text = $"{\"image\":\"127.0.0.1:5000/aprende-crud:release@($a)\"}\n{\"image\":\"127.0.0.1:5000/aprende-crud:release@($a)\"}\n{\"image\":\"docker.io/library/nginx:1@($a)\"}\n{\"image\":\"127.0.0.1:5001/other:1@($a)\"}"
	assert equal (registry in-use $text "127.0.0.1:5000") [{repo: "aprende-crud", digest: $a}]
	assert equal (registry in-use $text "127.0.0.1:5001") [{repo: "other", digest: $a}]
	assert equal (registry keep-tag $a) "keep-aaaaaaaaaaaaaaaa"
}

def test_a_failed_read_stops_the_prune_before_it_deletes_anything [] {
	print "test a kubectl get that fails stops the prune before any delete or exec, and only a missing CRD is skipped..."
	let w = (sandbox)
	"" | save -f ($w.state | path join get_fail_pods)
	let body = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}; registry prune '127.0.0.1:1' $build"
	let r = (in-world $w -c $body)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "kubectl get pods -A failed, so the prune stops before it deletes anything") $r.stderr
	assert (not ((calls $w) | any {|c| $c | str starts-with "exec" })) "no exec"
	rm -f ($w.state | path join get_fail_pods)
	# a CRD that is not there is skipped: the prune goes on, and stops later, at the registry nothing listens to
	"" | save -f ($w.state | path join missing_clusters.postgresql.cnpg.io)
	let r2 = (in-world $w -c $body)
	assert ($r2.exit_code != 0)
	assert (not (has $r2.stderr "kubectl get")) $r2.stderr
	assert (not ((calls $w) | any {|c| $c | str starts-with "exec" })) "no exec before the registry answered"
	rm -rf $w.dir
}

def test_the_registry_restarts_after_its_collection_when_it_caches_blobs [] {
	print "test the registry is restarted after garbage collection while it caches blob descriptors, and not when it does not or an upload is open..."
	let w = (sandbox)
	let body = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}; registry collect $build"
	let r = (in-world $w -c $body)
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	let log = (calls $w)
	let at = {|pat| $log | enumerate | where {|e| $e.item =~ $pat } | get index }
	assert ((do $at "garbage-collect" | first) < (do $at "rollout restart -n pronto-registry deploy/registry" | first)) "collected, then restarted"
	assert ((do $at "rollout restart" | first) < (do $at "rollout status -n pronto-registry deploy/registry" | first)) "and waited for"
	assert (has $r.stdout "inmemory blob cache")
	# the cache disabled by the deployment's env: no restart
	rm -f ($w.state | path join calls.jsonl)
	'[{"name":"REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR","value":"disabled"}]' | save -f ($w.state | path join registry_env)
	let off = (in-world $w -c $body)
	assert equal $off.exit_code 0 $"($off.stdout)($off.stderr)"
	assert ((calls $w) | any {|c| $c | str contains "garbage-collect" })
	assert (not ((calls $w) | any {|c| $c | str starts-with "rollout" })) "no restart without a cache"
	# an open upload: nothing is collected, nothing restarted
	rm -f ($w.state | path join calls.jsonl) ($w.state | path join registry_env)
	"/var/lib/registry/docker/registry/v2/repositories/x/_uploads/u" | save -f ($w.state | path join uploads)
	let busy = (in-world $w -c $body)
	assert equal $busy.exit_code 0 $"($busy.stdout)($busy.stderr)"
	assert (not ((calls $w) | any {|c| ($c | str contains "garbage-collect") or ($c | str starts-with "rollout") })) "an open upload stops the collection"
	rm -rf $w.dir
}

def test_the_prune_outcome_is_recorded_in_the_release_configmap [] {
	print "test a prune that fails is a warning recorded as prune_error, one that works as pruned..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let patch = (calls $w | where {|c| $c | str starts-with "patch configmap pronto-release -n aprende --type merge" })
	assert equal ($patch | length) 1
	assert (has $patch.0 '"pruned":"false"') $patch.0
	assert (has $patch.0 '"prune_error":"') $patch.0
	assert (not (has $patch.0 '"prune_error":""')) "the error is told"
	assert ((calls $w | enumerate | where {|e| $e.item =~ "ConfigMap/pronto-release" } | get index | first) < (calls $w | enumerate | where {|e| $e.item =~ "^patch configmap pronto-release" } | get index | first)) "after the release's record"
	# a prune that worked
	rm -f ($w.state | path join calls.jsonl)
	let ok = (in-world $w -c $"use ($engine_dir | path join release.nu) [record-prune]; record-prune {namespace: aprende} null")
	assert equal $ok.exit_code 0 $ok.stderr
	let p = (calls $w | first)
	assert (has $p '"pruned":"true"') $p
	assert (has $p '"prune_error":""') $p
	rm -rf $w.dir
}

def test_untracked_secret_looking_files_are_not_staged [] {
	print "test an untracked file that looks like a secret is not in the build context, a tracked one or a SOPS file is..."
	let w = (sandbox)
	for f in [".env" ".env.local" "x.dec.yaml" "secrets.yaml" "secrets.metal.yaml" "k.pem" "id.key" "sub/tls.key"] {
		mkdir ($w.app | path join $f | path dirname)
		"S" | save -f ($w.app | path join $f)
	}
	for f in ["secrets.other.enc.yaml" "kept.txt" "keyboard.txt" "envelope.txt"] { "x" | save -f ($w.app | path join $f) }
	# tracked files are reviewed: kept whatever their name
	".env.sample" | save -f ($w.app | path join .env.sample)
	do { cd $w.app; ^git add -f .env.sample } | ignore
	let r = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let tree = (open --raw ($w.dir | path join bake_tree) | lines)
	for f in ["./secrets.other.enc.yaml" "./kept.txt" "./keyboard.txt" "./envelope.txt" "./.env.sample"] { assert ($f in $tree) $"($f) is staged: ($tree | str join ' ')" }
	for f in ["./.env" "./.env.local" "./x.dec.yaml" "./secrets.yaml" "./secrets.metal.yaml" "./k.pem" "./id.key" "./sub/tls.key"] { assert (not ($f in $tree)) $"($f) is not staged" }
	assert (has $r.stdout "untracked and secret-looking")
	rm -rf $w.dir
}

def test_build_include_stages_the_ignored_files_it_names [] {
	print "test build.include stages the ignored generated files it names, and a missing or secret-looking one fails before the build..."
	let w = (sandbox)
	mkdir ($w.app | path join gen)
	"gen/\n" | save -f ($w.app | path join .gitignore)
	"{}" | save -f ($w.app | path join gen index.json)
	"{}" | save -f ($w.app | path join gen other.json)
	let cue = ($w.app | path join release.cue)
	let base = (open --raw $cue)
	# ignored: not staged without the include
	let plain = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $plain.exit_code 0 $"($plain.stdout)\n($plain.stderr)"
	assert (not ("./gen/index.json" in (open --raw ($w.dir | path join bake_tree) | lines))) "an ignored file is not staged by itself"
	# named: staged, and only it
	$"($base)\nNode: build: include: [\"gen/index.json\"]\n" | save -f $cue
	let r = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let tree = (open --raw ($w.dir | path join bake_tree) | lines)
	assert ("./gen/index.json" in $tree) $"the named file is staged: ($tree | str join ' ')"
	assert (not ("./gen/other.json" in $tree)) "a file it does not name is not"
	# missing: says so, builds nothing
	rm -f ($w.dir | path join bake_tree)
	$"($base)\nNode: build: include: [\"gen/gone.json\"]\n" | save -f $cue
	let m = (in-world $w $release_nu --app $w.app --check --build)
	assert ($m.exit_code != 0) "a missing file fails"
	assert (has $m.stderr "build.include names gen/gone.json, which is not a file") $m.stderr
	assert (not (($w.dir | path join bake_tree) | path exists)) "nothing was built"
	# secret-looking: refused
	"S" | save -f ($w.app | path join gen secrets.yaml)
	$"($base)\nNode: build: include: [\"gen/secrets.yaml\"]\n" | save -f $cue
	let k = (in-world $w $release_nu --app $w.app --check --build)
	assert ($k.exit_code != 0) "a secret-looking file fails"
	assert (has $k.stderr "looks like a secret") $k.stderr
	# not a path inside the app
	$"($base)\nNode: build: include: [\"../x\"]\n" | save -f $cue
	let o = (in-world $w $release_nu --app $w.app --check --build)
	assert ($o.exit_code != 0) "an escaping path fails the schema"
	rm -rf $w.dir
}

def test_a_database_image_without_pg_major_is_an_explicit_error [] {
	print "test a database image whose config has no PG_MAJOR fails with a message saying so..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join crane_nopg)
	let digest = ("sha256:" + ("a" | fill -c "a" -w 64))
	let r = (in-world $w -c $"use ($engine_dir | path join render.nu); render database-tag '127.0.0.1:1' aprende-database ($digest)")
	assert ($r.exit_code != 0)
	assert (has $r.stderr "has no PG_MAJOR in its environment") $r.stderr
	rm -rf $w.dir
}
