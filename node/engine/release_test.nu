#!/usr/bin/env nu
# Run with: nu node/engine/release_test.nu   (needs `cue` and the CUE registry, and `PRONTO_RUNTIME` or
# mise's github:bonisoft3/pronto@1.5.1: the six helpers imported from upstream run for real)
#
# The release flow (release.nu) over fakes of kubectl, sops, ssh, nc and docker on the PATH: kubectl
# keeps a cluster's state in files and logs every call and the objects it was given. Nothing here
# reaches a cluster, a registry or a project.

const engine_dir = path self .

use std/assert
use tunnel.nu
use rollback.nu
use release.nu [run-hooks decrypt-secrets preflight release-app check-operators dry-run require-tools check-ownership]
use render.nu
use runtime.nu

const pin = "1.5.1"
const release_nu = (path self release.nu)

# The runtime upstream pronto 1.5.1 is installed as.
def runtime-dir []: nothing -> string {
	if ($env.PRONTO_RUNTIME? | is-not-empty) { $env.PRONTO_RUNTIME } else { ^mise where $"github:bonisoft3/pronto@($pin)" | str trim }
}

# A scratch world: the fake tools, their state, and the fixture app with the engine's schema written
# into it as the engine writes it into an app.
def sandbox []: nothing -> record {
	let d = (mktemp -d -t node-test.XXXXXX | str trim)
	for p in [bin state aprende] { mkdir ($d | path join $p) }
	^cp -R ($engine_dir | path join fixtures aprende/.) ($d | path join aprende)
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
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
echo "$*" >> "$d/docker.log"
case "$*" in
  *"compose"*"config --format json"*) cat "$d/compose.json" ;;
  *"compose"*"config"*) echo "services: {}" ;;
esac
'# | str trim --left | save -f ($d | path join bin docker)
	# tools the preflight wants on the PATH: they are not run here
	for t in [crane gcloud] { "#!/bin/sh\nexit 0\n" | save -f ($d | path join bin $t) }
	for t in [kubectl sops nc ssh docker crane gcloud] { ^chmod +x ($d | path join bin $t) }
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
	$"let app_info = \(runtime resolve-app '($w.app)'\); let node = \(render node-config $app_info.cue_path '($preview)'\); let meta = \(render app-meta $app_info.cue_path '($preview)'\); let compose = \(render compose-config $app_info.dir\); let facts = \(render facts $app_info.dir\);"
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
	test_a_namespace_the_release_did_not_label_is_not_its_to_touch
	test_rollback_goes_through_every_deployment
	test_barman_and_gateway_api_versions_are_checked
	test_sops_keeps_secrets_alone_and_no_backup_credentials_for_a_preview
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
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx")) "no image was built"
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
	let r = (in-world $w -c (script $w $"(inputs $w) let secrets = \(preflight $app_info $node\); release-app $app_info $node $meta $compose $facts $secrets (pushed-json)"))
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
	assert equal $undone ["rollout undo deployment/aprende-crud -n aprende" "rollout undo deployment/aprende-electric -n aprende" "rollout undo deployment/aprende-auth -n aprende"]
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
	let r = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "dapr: the node runs 1.14.4, the engine's schema is written for 1.16.21") $r.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_backups_need_their_secret [] {
	print "test backups without their credentials' Secret refuse the release before any write..."
	let w = (sandbox)
	let body = (inputs $w) + " let node = ($node | upsert backups {credentials: 'aprende-backup-s3', bucket: 'b', path: 'p'}); preflight $app_info $node"
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

def alive [pid: int]: nothing -> bool { (^kill -0 $pid | complete).exit_code == 0 }

def test_tunnel_is_opened_once_and_closed_on_a_failure [] {
	print "test the ssh tunnel opens once, in BatchMode, and is closed when the body fails..."
	let w = (sandbox)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let msg = (with-env {PATH: $path} {
		try { tunnel with-tunnel {ssh: "deploy@node.example", remotePort: 6443} {|port| error make {msg: "the release failed"} }; "no error" } catch {|e| $e.msg }
	})
	assert equal $msg "the release failed"
	let log = (open --raw ($w.dir | path join ssh.log) | lines)
	assert equal ($log | length) 1
	assert (has $log.0 "-N -o BatchMode=yes")
	assert (has $log.0 "-o ExitOnForwardFailure=yes")
	assert (has $log.0 "-o IdentitiesOnly=yes -o ConnectTimeout=10")
	assert ($log.0 =~ '-L [0-9]+:127.0.0.1:6443 deploy@node.example')
	assert (not ($log.0 | str contains "-L 26444:")) "never a port another release may hold"
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
		let one = (tunnel with-tunnel {ssh: "deploy@node.example", remotePort: 6443} {|port| {port: $port, cfg: (open --raw (tunnel kubeconfig contabo2 $port))} })
		rm -f ($w.dir | path join ssh_started)
		let two = (tunnel with-tunnel {ssh: "deploy@node.example", remotePort: 6443} {|port| {port: $port} })
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
		let msg = (with-env {PATH: $path} { try { tunnel with-tunnel {ssh: $bad, remotePort: 6443} {|port| "in" }; "no error" } catch {|e| $e.msg } })
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
		try { tunnel with-tunnel {ssh: "deploy@node.example", remotePort: 6443} {|port| "in" }; "no error" } catch {|e| $e.msg }
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
	let r = (in-world $w -c (script $w $"(inputs $w) $env.PRONTO_RUNTIME = '($w.dir)/9.9.9'; preflight $app_info $node --check"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "the pronto runtime is 9.9.9; this engine is validated against 1.5.1") $r.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_preflight_needs_its_tools [] {
	print "test a tool missing from the PATH fails the preflight, naming it..."
	let msg = (try { require-tools ["sh" "no-such-tool-xyz"]; "no error" } catch {|e| $e.msg })
	assert (has $msg "missing on the PATH: no-such-tool-xyz") $msg
	let w = (sandbox)
	# a check needs neither crane nor gcloud
	let ok = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node --check"))
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
	let body = (inputs $w --preview rc) + " let node = ($node | upsert backups {credentials: 'aprende-backup-s3', bucket: 'b', path: 'p'}); preflight $app_info $node --check | each {|s| $s.metadata.name + '@' + $s.metadata.namespace } | to json --raw"
	let r = (in-world $w -c (script $w $body))
	assert equal $r.exit_code 0 $r.stderr
	assert equal ($r.stdout | str trim) '["keep@aprende-rc"]'
	rm -rf $w.dir
}
