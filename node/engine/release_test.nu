#!/usr/bin/env nu
# Run with: nu node/engine/release_test.nu   (needs `cue` and the CUE registry, and `PRONTO_RUNTIME` or
# mise's github:bonisoft3/pronto@1.18.0: the seven helpers imported from upstream run for real)
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
const pin = "1.18.1"
const runtime_pin = "1.18.0"
const release_nu = (path self release.nu)

# The runtime upstream pronto 1.18.0 is installed as.
def runtime-dir []: nothing -> string {
	if ($env.PRONTO_RUNTIME? | is-not-empty) { $env.PRONTO_RUNTIME } else { ^mise where $"github:bonisoft3/pronto@($runtime_pin)" | str trim }
}

# A scratch world: the fake tools, their state, and the fixture app with the engine's schema written
# into it as the engine writes it into an app.
def sandbox [--fixture: string = "aprende"]: nothing -> record {
	let d = (mktemp -d -t node-test.XXXXXX | str trim)
	for p in [bin state state/revision $fixture] { mkdir ($d | path join $p) }
	^cp -R ($engine_dir | path join fixtures $"($fixture)/.") ($d | path join $fixture)
	# the build's context is the app as git sees it
	do { cd ($d | path join $fixture); ^git init -q . } | ignore
	let mod = ($d | path join $fixture cue.mod module.cue)
	open $mod | str replace -r 'pronto@v1": v: "[^"]+"' $'pronto@v1": v: "v($pin)"' | save -f $mod
	mkdir ($d | path join $fixture node schema)
	cp ($engine_dir | path join schema node.cue) ($d | path join $fixture node schema node.cue)
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
[ -f "$d/ssh_started" ] || [ -f "$d/state/portforward.pid" ]
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
  *"compose"*"config --format json"*) env > "$d/compose_env"; [ -z "$DOCKER_CONFIG" ] || readlink "$DOCKER_CONFIG/cli-plugins/docker-compose" >> "$d/compose_plugins"; cat "$d/compose.json" ;;
  *"compose"*"config"*) env > "$d/staged_compose_env"; echo "services: {}" ;;
  "buildx version") echo "github.com/docker/buildx v0 fake" ;;
  "buildx create "*) echo "$DOCKER_CONFIG" > "$d/docker_config" ;;
  "buildx inspect "*) if [ -f "$d/platform_arm" ]; then echo "Platforms:        linux/arm64"; else echo "Platforms:        linux/amd64, linux/amd64/v2, linux/386"; fi ;;
  "buildx rm "*) ;;
  "buildx bake "*)
    pwd > "$d/bake_pwd"
    env > "$d/bake_env"
    cat > "$d/bake_compose"
    find . -type f | sort > "$d/bake_tree"
    if [ -f "$d/bake_fail" ]; then { echo "ERROR: failed to solve"; cat "$d/bake_fail"; } >&2; exit 1; fi
    meta=""; targets=""; skip=0
    for a in "$@"; do
      if [ $skip = 1 ]; then
        skip=0
        [ "$prev" = --metadata-file ] && meta="$a"
        # a tenant's bake writes each target as an OCI archive (--set <t>.output=type=oci,dest=<file>) and pushes nothing
        case "$prev$a" in --set*.output=type=oci,dest=*) tar -cf "${a#*dest=}" -T /dev/null ;; esac
        continue
      fi
      case "$a" in
        buildx|bake) ;;
        -f|--builder|--metadata-file|--set) skip=1; prev="$a" ;;
        -*) ;;
        *) targets="$targets $a" ;;
      esac
    done
    [ -n "$meta" ] || exit 0
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
# `crane push <layout> <ref>`: the pinned reference it answers, the digest the hash of the reference
case "$1" in
  push) for a; do ref="$a"; done; printf '%s@sha256:%s\n' "${ref%:*}" "$(printf %s "$ref" | shasum -a 256 | cut -d' ' -f1)"; exit 0 ;;
esac
if [ -f "$d/crane_nopg" ]; then echo '{"config":{"Env":["PATH=/bin"]}}'; else echo '{"config":{"Env":["PATH=/bin","PG_MAJOR=17"]}}'; fi
'# | str trim --left | save -f ($d | path join bin crane)
	# curl: the registry answers 200 through the tunnel, unless it is down
	r#'
#!/bin/sh
d="$(dirname "$0")/.."
case "$*" in
  *"/v1.0"*)
    out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    echo "$*" >> "$d/door_curl.log"
    if [ -f "$d/host_unreachable" ]; then printf 000; exit 6; fi
    if [ -f "$d/probe_502" ]; then echo "bad gateway" > "$out"; printf 502; exit 0; fi
    if [ -f "$d/probe_timeout" ]; then printf 000; exit 28; fi
    case "$*" in
      *"/CRUD/v1.0/metadata"*) if [ -f "$d/upper_open" ]; then echo '{"id":"caddy","runtimeVersion":"1.16.21","components":[]}' > "$out"; printf 200; exit 0; fi ;;
      *"/Img/v1.0-alpha1/metadata"*) if [ -f "$d/upper_img_proxied" ]; then echo 'upstream' > "$out"; printf 403; exit 0; fi ;;
    esac
    case "$*" in
      *"/img/v1.0/metadata"*) if [ -f "$d/img_500" ]; then echo 'ERR_DIRECT_INVOKE failed to resolve address' > "$out"; printf 500; exit 0; fi ;;
      *"/blobs/v1.0-alpha1/metadata"*) if [ -f "$d/blobs_alpha_proxied" ]; then echo 'upstream' > "$out"; printf 403; exit 0; fi ;;
    esac
    case "$*" in
      *"/crud/v1.0/metadata"*) if [ -f "$d/metadata_open" ]; then echo '{"id":"caddy","runtimeVersion":"1.16.21","components":[]}' > "$out"; printf 200; exit 0; fi ;;
      *"/invoke/"*) if [ -f "$d/invoke_by_path" ]; then echo ok > "$out"; printf 200; exit 0; fi ;;
      *"/img/v1.0/metadata"*) if [ -f "$d/img_open" ]; then echo '{"id":"imgproxy","runtimeVersion":"1.16.21"}' > "$out"; printf 200; exit 0; fi ;;
    esac
    case "$*" in
      *"--path-as-is"*) echo "$*" >> "$d/path_as_is.log"; if [ -f "$d/dotdot_open" ]; then echo '{"id":"caddy","runtimeVersion":"1.16.21"}' > "$out"; printf 200; exit 0; fi ;;
    esac
    case "$*" in
      *"/crud/"*) if [ -f "$d/crud_guard" ]; then : > "$out"; printf 404; exit 0; fi; echo '{"code":"PGRST125","message":"Invalid path specified in request URL"}' > "$out"; printf 404; exit 0 ;;
    esac
    echo "404 page not found" > "$out"; printf 404; exit 0 ;;
esac
if [ -f "$d/registry_dead" ]; then printf 000; exit 7; fi
case "$*" in
  *"/blobs/sha256:"*)
    echo "$*" >> "$d/blob_curl.log"
    # What `-w "\n%{http_code} %{size_download}"` makes: a line with the status and the bytes that came. blob_500 / blob_404 /
    # blob_200 / blob_timeout (curl exit 28): every blob answers so. blob_cutoff: 206 with no body, curl exit 18, as distribution
    # <= 3.1.2 answers for a layer its cache lists and the collector deleted; blob_404_once: the same until the registry is restarted.
    # blob_416: the layer (by its digest) answers 416, the answer for an empty blob. A ranged GET otherwise answers 206 and one byte.
    cut() { echo "curl: (18) transfer closed with outstanding read data remaining" >&2; printf '\n206 0'; exit 18; }
    if [ -f "$d/blob_500" ]; then printf '\n500 0'; exit 0; fi
    if [ -f "$d/blob_404" ]; then printf '\n404 0'; exit 0; fi
    if [ -f "$d/blob_200" ]; then printf '\n200 100'; exit 0; fi
    if [ -f "$d/blob_timeout" ]; then echo "curl: (28) Operation timed out" >&2; exit 28; fi
    if [ -f "$d/blob_cutoff" ]; then cut; fi
    if [ -f "$d/blob_404_once" ] && [ ! -f "$d/state/registry_restarted" ]; then cut; fi
    if [ -f "$d/blob_416" ]; then case "$*" in *"blobs/sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"*) printf '\n416 0'; exit 0 ;; esac; fi
    printf '\n206 1'; exit 0 ;;
  *"/manifests/sha256:"*)
    echo "$*" >> "$d/manifest_curl.log"
    # the body, then a line with the status: what `-w "\n%{http_code}"` makes. manifest_500, manifest_cutoff (curl exit 18),
    # manifest_404 (always), manifest_404_for (a repo's name: always, for it only), manifest_404_once (until the registry is restarted)
    if [ -f "$d/manifest_cutoff" ]; then echo "curl: (18) transfer closed with outstanding read data remaining" >&2; exit 18; fi
    if [ -f "$d/manifest_500" ]; then printf '\n500'; exit 0; fi
    if [ -f "$d/manifest_404" ]; then printf '\n404'; exit 0; fi
    if [ -f "$d/manifest_404_for" ]; then case "$*" in *"/v2/$(cat "$d/manifest_404_for")/"*) printf '\n404'; exit 0 ;; esac; fi
    if [ -f "$d/manifest_404_once" ] && [ ! -f "$d/state/registry_restarted" ]; then printf '\n404'; exit 0; fi
    if [ -f "$d/manifest_index" ]; then case "$*" in *"manifests/sha256:1111111111111111111111111111111111111111111111111111111111111111") printf '{"manifests":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}\n200'; exit 0 ;; esac; fi
    layer_size=20; [ -f "$d/zero_layer" ] && layer_size=0
    printf '{"config":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":10},"layers":[{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","size":%s}]}\n200' "$layer_size"; exit 0 ;;
esac
printf 200
'# | str trim --left | save -f ($d | path join bin curl)
	# deno registers the OIDC clients (register.ts: it answers the settings it was given, as for a provider whose client id is
	# not "origin") and signs the service token; it is not run for real here, and every call is logged
	"#!/bin/sh\necho \"$*\" >> \"$(dirname \"$0\")/../deno.log\"\ncase \"$*\" in *register.ts*) cat ;; *) cat >/dev/null; echo fake.service.token ;; esac\n" | save -f ($d | path join bin deno)
	# tools the preflight wants on the PATH: they are not run here
	"#!/bin/sh\nexit 0\n" | save -f ($d | path join bin docker-buildx)
	for t in [kubectl sops nc ssh docker crane curl docker-buildx deno] { ^chmod +x ($d | path join bin $t) }
	let compose = {services: {
		database: {}, crud: {}, electric: {}, caddy: {}
		auth: {environment: {OIDC_PROVIDERS: "google"}}
		migrate: {environment: {DATABASE_URL: "postgres://x", REQUIRED_TABLES: "a,b"}}
	}}
	$compose | to json | save -f ($d | path join compose.json)
	{dir: $d, app: ($d | path join $fixture), state: ($d | path join state)}
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
	calls $w | where {|c| ($c | split row " " | first) in [apply delete annotate rollout] and not ($c | str contains "--dry-run") and not ($c | str contains "rollout status") and not ($c | str contains "registry-lease-") and not ($c | str contains "registry-gc-lock") }
}

def script [w: record, body: string]: nothing -> string {
	$"use ($engine_dir | path join release.nu) *; use ($engine_dir | path join render.nu); use ($engine_dir | path join runtime.nu); ($body)"
}

# The release's inputs, as main reads them.
def inputs [w: record, --preview: string = ""]: nothing -> string {
	$"let app_info = \(runtime resolve-app '($w.app)'\); let node = \(render node-config $app_info.cue_path '($preview)'\); let meta = \(render app-meta $app_info.cue_path '($preview)'\); let compose = \(render compose-config $app_info.dir\); let facts = \(render facts $app_info.dir\); let fwd = {api: 1, buildkit: 2, registry: 3};"
}

def pushed-json [...extra: string]: nothing -> string {
	let digest = "sha256:" + ("a" | fill -c "a" -w 64)
	let svcs = [database crud electric auth caddy migrate] | append $extra
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
	test_a_database_of_standbys_is_waited_for_whole
	test_services_are_built_seeded_rolled_out_and_checked_for_their_sidecar
	test_a_service_secret_must_be_in_the_sops_file_or_the_namespace
	test_a_seed_file_stays_in_the_app_and_one_configmap_has_one_file
	test_a_failed_read_is_never_taken_for_absent
	test_serving_prints_the_recorded_commit
	test_a_failed_deployment_read_is_neither_unchanged_nor_changed
	test_a_namespace_the_release_did_not_label_is_not_its_to_touch
	test_rollback_goes_through_every_deployment
	test_barman_and_gateway_api_versions_are_checked
	test_sops_keeps_secrets_alone_and_no_backup_credentials_for_a_preview
	test_a_release_builds_on_the_nodes_buildkitd_and_pushes_to_its_registry
	test_the_build_context_is_the_tree_git_sees
	test_the_door_image_is_built_only_with_the_dapr_guard
	test_untracked_secret_looking_files_are_not_staged
	test_build_include_stages_the_ignored_files_it_names
	test_check_build_pushes_under_check_and_writes_nothing_to_the_cluster
	test_build_alone_is_refused
	test_a_failed_bake_leaves_no_builder_and_no_scratch_folder
	test_a_pushed_digest_the_registry_lost_restarts_it_and_pushes_again
	test_a_digest_still_lost_after_the_restart_fails_before_the_rollout
	test_a_layer_the_registry_lost_under_a_manifest_that_answers_is_found
	test_a_blob_still_cut_off_after_the_restart_fails_the_release
	test_a_blob_that_answers_200_or_416_for_an_empty_one_is_served
	test_an_open_upload_or_a_held_lock_blocks_the_registry_restart
	test_an_answer_that_is_not_a_404_fails_the_release_with_no_restart
	test_another_releases_lease_blocks_the_registry_restart
	test_only_the_image_that_is_missing_is_named
	test_an_index_is_followed_to_its_children_and_their_blobs
	test_the_buildx_nearest_the_front_of_the_path_wins
	test_a_broken_session_names_the_buildx_that_broke_it
	test_preflight_refuses_a_builder_or_a_registry_that_is_not_there
	test_the_registry_prune_reads_what_the_cluster_names
	test_a_failed_read_stops_the_prune_before_it_deletes_anything
	test_a_live_image_that_cannot_be_checked_stops_the_prune
	test_the_collection_waits_for_releases_in_flight
	test_a_stale_lock_is_taken_over_against_its_resource_version
	test_prune_runs_only_the_maintenance
	test_a_renewal_that_fails_after_the_push_applies_nothing
	test_a_lease_that_stays_does_not_turn_a_live_release_into_a_failure
	test_the_door_must_not_answer_the_dapr_api
	test_a_deferred_prune_exits_four
	test_only_a_confirmed_absence_is_created
	test_the_lock_is_released_against_what_was_read_and_its_failure_is_told
	test_verification_is_invalidated_before_a_release_changes_what_serves
	test_a_failed_provider_export_stops_the_release
	test_a_scan_that_fails_aborts_the_collection_and_a_deferred_one_is_pending
	test_a_file_name_with_a_newline_is_one_name
	test_a_failed_lease_renewal_is_a_warning_and_the_record_starts_unknown
	test_the_apps_compose_plugin_is_the_one_that_renders
	test_the_record_is_the_commit_built_and_serving_agrees
	test_serving_leaves_no_kubeconfig
	test_a_template_accepted_before_its_revision_moves_is_rolled_back
	test_the_registry_restarts_after_its_collection_when_it_caches_blobs
	test_the_prune_outcome_is_recorded_in_the_release_configmap
	test_a_database_image_without_pg_major_is_an_explicit_error
	test_adopt_applies_server_side_and_forced
	test_schema_from_copies_the_live_schema_once_and_reads_only
	test_schema_from_is_refused_where_it_cannot_be_read
	test_database_base
	test_the_clusters_spec_does_not_move_with_the_databases_files
	test_oidc_clients_are_registered_by_a_runtime_that_has_it_and_never_by_an_older_one
	test_a_tenant_release_runs_as_its_publisher_alone
	test_a_tenant_builds_only_on_the_tenants_buildkitd
	test_a_tenant_release_is_refused_before_anything_is_written
	test_a_tenant_namespace_and_push_rights_are_asked_before_anything_is_built
	test_a_tenant_check_writes_nothing
	test_a_lost_tenant_image_fails_without_a_restart
	test_the_tenant_door_check_runs_as_the_pusher
	test_a_tenants_own_nodemanifests_cannot_write_what_its_publisher_may_not
	test_a_tenants_edited_schema_copy_is_refused
	test_a_tenants_build_include_stays_under_the_app
	test_a_tenants_namespace_is_a_studio_one
	test_a_tenants_issuers_are_the_engines_list
	test_the_tenant_door_check_in_the_pod_dials_the_service_and_forwards_to_nothing
	test_a_tenants_compose_files_name_nothing_outside_the_app
	test_a_tenants_staged_build_paths_are_the_staged_copys
	test_a_tenants_dry_run_with_no_build_needs_the_publisher_kubeconfig_alone
	test_a_tenants_retirement_is_the_engines_to_decide
	test_a_tenants_objects_hand_their_life_to_no_one_and_hold_no_reserved_name
	test_a_tenants_secret_and_seed_names_are_resource_names_never_options
	test_a_tenants_own_vendored_engine_does_not_copy_the_schema_onto_itself
	test_a_tenants_schema_that_is_not_a_regular_file_is_refused_unread
	test_a_tenants_seed_is_a_file_git_tracks
	test_a_tenants_build_targets_are_names_and_buildx_may_be_dockers_own
	test_a_tenants_env_link_is_refused_and_never_opened
	test_a_tenants_push_rights_are_only_what_its_path_uses
	test_a_tenants_origin_and_preview_are_the_operators
	test_a_tenants_containers_say_allow_privilege_escalation_false
	test_a_tenants_compose_and_bake_see_only_an_allowlisted_environment
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
	assert ("delete deployment aprende-crud -n aprende --ignore-not-found" in (calls $w)) "a Deployment the failed release created is deleted, not left rolling out"
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

def test_a_database_of_standbys_is_waited_for_whole [] {
	print "test a release of a database with standbys waits for every instance, and fails when one is missing..."
	let w = (sandbox)
	"\nNode: database: instances: 3\n" | save --append ($w.app | path join release.cue)
	"2" | save -f ($w.state | path join cluster_instances_ready)
	"reg/aprende-database:17@sha256:old" | save -f ($w.state | path join previous_image)
	let body = (with-node $w "upsert waits.standbys 1" $"release-app $app_info $node $meta $compose $facts [] (pushed-json)")
	let short = (in-world $w -c (script $w $body))
	assert ($short.exit_code != 0)
	assert (has $short.stderr "has 2 of its 3 instances ready on") $short.stderr
	assert (has $short.stderr "the database image stays") $short.stderr
	assert equal (calls $w | where {|c| $c | str starts-with "patch cluster.postgresql.cnpg.io" } | length) 0 "a slow standby does not put the old image back"
	rm -f ($w.state | path join previous_image)
	rm -f ($w.state | path join calls.jsonl)
	rm -f ($w.state | path join cluster_instances_ready)
	let whole = (in-world $w -c (script $w (with-node $w "upsert waits.primary 1" $"release-app $app_info $node $meta $compose $facts [] (pushed-json)")))
	assert equal $whole.exit_code 0 $"($whole.stdout)($whole.stderr)"
	assert (has $whole.stdout "the 3 instances of aprende-db") $whole.stdout
	rm -rf $w.dir
}

# An aprende whose Node declares two services and the blob plane: flagd (a seeded ConfigMap mounted, a clock) and a notifier
# (a Secret it reads).
def with-services [w: record] {
	r#'
Node: services: {flagd: {port: 8693, files: "/etc/flags-live": "aprende-flags", seed: "aprende-flags": "flags/flags.json", clock: {}, metrics: port: 9599}, notifier: {port: 8698, secrets: VAPID_PRIVATE_KEY: "notify-vapid"}}
Node: blobs: {bucket: "b-blobs", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "b@p.iam.gserviceaccount.com"}
Node: metricsExport: {project: "my-project", provider: "projects/1/locations/global/workloadIdentityPools/p/providers/q", serviceAccount: "m@p.iam.gserviceaccount.com"}
'# | save --append ($w.app | path join release.cue)
	mkdir ($w.app | path join flags)
	'{"flags": {}}' | save -f ($w.app | path join flags flags.json)
	mkdir ($w.state | path join secrets)
	"" | save -f ($w.state | path join secrets notify-vapid)
}

def test_services_are_built_seeded_rolled_out_and_checked_for_their_sidecar [] {
	print "test a release builds its services' images, seeds a missing ConfigMap once, signs the token, and waits for each Deployment and its sidecar..."
	let w = (sandbox)
	with-services $w
	let extra = [flagd notifier rclone-s3 imgproxy]
	# the images: the services' and the blob plane's, once each, beside upstream's
	let built = (in-world $w -c (script $w $"(inputs $w) render build-services $compose false \(render own-images $node\) | to json --raw"))
	assert equal $built.exit_code 0 $built.stderr
	assert equal ($built.stdout | str trim | from json | sort) ([database crud electric auth caddy migrate flagd notifier rclone-s3 imgproxy] | sort)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json ...$extra)"))
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let log = (calls $w)
	let at = {|pat| $log | enumerate | where {|e| $e.item =~ $pat } | get index }
	# the seed: a create of the ConfigMap, once, before the objects that mount it
	assert equal (do $at "^create -f - <- ConfigMap/aprende-flags$" | length) 1 "the ConfigMap is made once"
	assert ((do $at "^create -f - <- ConfigMap/aprende-flags$" | first) < (do $at "^apply -f - <-.*Deployment/aprende-flagd" | first)) "the seed comes before the Deployments"
	assert (has $r.stdout "seeding the ConfigMap aprende-flags from flags/flags.json")
	# the service token, then every service's rollout and the sidecar check
	assert ((do $at "Secret/aprende-service-token" | length) > 0) "the service token was applied"
	for d in [aprende-flagd aprende-notifier aprende-rclone-s3 aprende-imgproxy aprende-metrics-export] {
		assert ($log | any {|c| $c | str contains $"rollout status deployment/($d) " }) $"($d) was waited for"
	}
	assert ($log | any {|c| $c | str contains "app.kubernetes.io/component in (crud,electric,auth,caddy,flagd,notifier,rclone-s3,imgproxy)" }) ($log | str join "\n")
	assert ($log | any {|c| ($c | str contains "apply -f - <-") and ($c | str contains "CronJob/aprende-flagd-clock") }) "the clock is applied"
	# a ConfigMap that is there is never written over
	rm -f ($w.state | path join calls.jsonl)
	mkdir ($w.state | path join cm)
	'{"metadata": {"name": "aprende-flags"}, "data": {"flags.json": "live"}}' | save -f ($w.state | path join cm aprende-flags)
	let again = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json ...$extra)"))
	assert equal $again.exit_code 0 $"($again.stdout)\n($again.stderr)"
	assert equal (calls $w | where {|c| $c == "create -f - <- ConfigMap/aprende-flags" } | length) 0 "a ConfigMap that exists is left alone"
	rm -rf $w.dir
}

def test_a_service_secret_must_be_in_the_sops_file_or_the_namespace [] {
	print "test a Secret a service reads that is neither in the SOPS file nor in the namespace refuses the release before any write, and a seed with no file is refused..."
	let w = (sandbox)
	with-services $w
	rm -f ($w.state | path join secrets notify-vapid)
	let r = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node $fwd"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "Node.services read the Secret notify-vapid, which is neither in the SOPS file nor in aprende") $r.stderr
	assert equal (writes $w) []
	"" | save -f ($w.state | path join secrets notify-vapid)
	let ok = (in-world $w -c (script $w $"(inputs $w) preflight $app_info $node $fwd | ignore"))
	assert equal $ok.exit_code 0 $ok.stderr
	rm -f ($w.app | path join flags flags.json)
	let seed = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json flagd notifier rclone-s3 imgproxy)"))
	assert ($seed.exit_code != 0)
	assert (has $seed.stderr "seeds the ConfigMap aprende-flags from flags/flags.json, which is not in") $seed.stderr
	assert equal (writes $w | where {|c| $c | str contains "Deployment/" } | length) 0 "nothing rolled"
	rm -rf $w.dir
}

def test_a_seed_file_stays_in_the_app_and_one_configmap_has_one_file [] {
	print "test a seed file that resolves outside the app, or two files for one ConfigMap, are refused..."
	let w = (sandbox)
	mkdir ($w.app | path join flags)
	'{}' | save -f ($w.app | path join flags a.json)
	'{}' | save -f ($w.app | path join flags b.json)
	^ln -sf /etc/hosts ($w.app | path join flags link.json)
	let ask = {|seeds| in-world $w -c (script $w $"seed-files '($w.app)' {services: ($seeds)} | length") }
	let ok = (do $ask '{x: {seed: {cm: "flags/a.json"}}, y: {seed: {cm: "flags/a.json"}}}')
	assert equal ($ok.stdout | str trim) "1" $"($ok.stdout)($ok.stderr)"
	let link = (do $ask '{x: {seed: {cm: "flags/link.json"}}}')
	assert (has $link.stderr "resolves outside") $link.stderr
	let clash = (do $ask '{x: {seed: {cm: "flags/a.json"}}, y: {seed: {cm: "flags/b.json"}}}')
	assert (has $clash.stderr "seed the ConfigMap cm from more than one file") $clash.stderr
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
	assert equal (writes $w) [] "a failed read applies nothing at all, not even the namespace"
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
# A release that went through: exit 0, or 3 where only its registry maintenance failed (the sandbox's registry answers nothing).
def released [r: record]: nothing -> bool {
	$r.exit_code == 0 or ($r.exit_code == 3 and ($r.stderr | str contains "MAINTENANCE FAILED"))
}

def forwarded [w: record]: nothing -> record {
	let p = (open --raw ($w.dir | path join ssh.log) | lines | first | parse --regex '-L (?<p>[0-9]+):' | get p)
	{api: $p.0, buildkit: $p.1, registry: $p.2}
}

def test_a_release_builds_on_the_nodes_buildkitd_and_pushes_to_its_registry [] {
	print "test a release builds through a remote builder on the tunnel's buildkitd port, tags the node registry's names, reads the database's major, and a failed prune ends it with status 3, the release live..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app)
	assert (released $r)
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
	# no listener behind the registry's forward: the prune fails, the release is live all the same, and the command says so
	# with its own status (3), after the tunnel is closed
	assert equal $r.exit_code 3 $r.stderr
	assert (has $r.stderr "MAINTENANCE FAILED: the node's registry was not pruned") $r.stderr
	assert (not ((open --raw ($w.dir | path join ssh.log) | str contains "-L 5000:")))
	# a preview is tagged for itself
	let p = (in-world $w $release_nu --app $w.app --preview rc)
	assert (released $p) $"($p.stdout)\n($p.stderr)"
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

def test_the_door_image_is_built_only_with_the_dapr_guard [] {
	print "test a build refuses a docker/Caddyfile without the doorguard block, naming the plugin, and accepts one with it..."
	let w = (sandbox)
	mkdir ($w.app | path join docker)
	"(app) {\n  handle /img/* {\n    respond 200\n  }\n}\n" | save -f ($w.app | path join docker Caddyfile)
	let bad = (in-world $w $release_nu --app $w.app --check --build)
	assert ($bad.exit_code != 0) "a Caddyfile without the guard fails the build"
	assert (has $bad.stderr "lacks the Dapr guard") $bad.stderr
	assert (has $bad.stderr "doorguard") $bad.stderr
	"(app) {\n  # PRONTO-1307: no public prefix reaches a Dapr API path of its sidecar\n  @daprapi path_regexp daprapi (?i)^/(crud|img|blobs|electric)/v1\\.0(-alpha1)?(/|$)\n  handle @daprapi {\n    respond 404\n  }\n  handle /img/* {\n    respond 200\n  }\n}\n" | save -f ($w.app | path join docker Caddyfile)
	let ok = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $ok.exit_code 0 $"($ok.stdout)\n($ok.stderr)"
	# PRONTO-916: a guard whose pattern is case-sensitive is the bypass: the build refuses it, naming the refresh
	"(app) {\n  # PRONTO-1307: no public prefix reaches a Dapr API path of its sidecar\n  @daprapi path_regexp daprapi ^/(crud|img|blobs|electric)/v1\\.0(-alpha1)?(/|$)\n  handle @daprapi {\n    respond 404\n  }\n  handle /img/* {\n    respond 200\n  }\n}\n" | save -f ($w.app | path join docker Caddyfile)
	let stale = (in-world $w $release_nu --app $w.app --check --build)
	assert ($stale.exit_code != 0) "a case-sensitive guard fails the build"
	assert (has $stale.stderr "case-sensitive") $stale.stderr
	assert (has $stale.stderr "doorguard") $stale.stderr
	rm -rf ($w.app | path join docker)
	let none = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $none.exit_code 0 "an app with no Caddyfile is not asked for a guard"
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

def bakes [w: record]: nothing -> int {
	docker-calls $w | where {|l| $l | str starts-with "buildx bake" } | length
}

# The fake curl's log, one entry per call: the status format `-w "\n%{http_code}"` holds a newline, so a call spans two lines.
def curl-log [w: record, file: string]: nothing -> list<string> {
	open --raw ($w.dir | path join $file) | str replace -a "\n" " " | split row "-sS" | each {|e| $e | str trim } | where {|e| $e != "" }
}

def restarts [w: record]: nothing -> int {
	calls $w | where {|c| $c | str starts-with "rollout restart -n pronto-registry deploy/registry" } | length
}

def test_a_pushed_digest_the_registry_lost_restarts_it_and_pushes_again [] {
	print "test a digest the registry does not serve after the push restarts the registry, bakes once more, and the release goes on; each manifest is asked as a pull asks..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join manifest_404_once)
	let r = (in-world $w $release_nu --app $w.app)
	assert (released $r) $"($r.stdout)\n($r.stderr)"
	assert (has $r.stderr "a stale blob cache") $r.stderr
	assert equal (bakes $w) 2 "baked again"
	assert equal (restarts $w) 1 "restarted once"
	assert (has $r.stdout "[SUCCESS] Released aprende")
	# the manifest's URL and Accept header, and the time it is given
	let fwd = (forwarded $w)
	let asked = (curl-log $w manifest_curl.log)
	assert ($asked | all {|l| $l =~ $"http://127.0.0.1:($fwd.registry)/v2/aprende-[a-z]+/manifests/sha256:[0-9a-f]{64}$" }) ($asked | str join "\n")
	let accept = "-H Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"
	assert ($asked | all {|l| (has $l $accept) and (has $l "--max-time 15") }) ($asked | str join "\n")
	rm -rf $w.dir
}

def test_a_digest_still_lost_after_the_restart_fails_before_the_rollout [] {
	print "test a digest still missing after the restart and the second bake fails the release before anything is applied, and the lease goes..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join manifest_404)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "registry lost ") $r.stderr
	assert (has $r.stderr "still does not serve them after a restart and a second push") $r.stderr
	assert equal (bakes $w) 2
	assert equal (restarts $w) 1
	assert equal (writes $w) ["rollout restart -n pronto-registry deploy/registry"] "only the registry was touched, nothing applied"
	assert (calls $w | any {|c| $c | str starts-with "delete lease registry-lease-aprende-" }) "the lease was deleted"
	rm -rf $w.dir
}

def test_a_layer_the_registry_lost_under_a_manifest_that_answers_is_found [] {
	print "test a layer that answers 206 with no body (curl 18) under a manifest that answers 200 restarts the registry and bakes again, and a blob is asked its first byte..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join blob_404_once)
	let r = (in-world $w $release_nu --app $w.app)
	assert (released $r) $"($r.stdout)\n($r.stderr)"
	assert (has $r.stderr "a stale blob cache") $r.stderr
	assert (has $r.stderr $"@sha256:('d' | fill -c 'd' -w 64)") "the layer is named"
	assert equal (bakes $w) 2
	assert equal (restarts $w) 1
	let blobs = (curl-log $w blob_curl.log)
	assert ($blobs | all {|l| (has $l "-r 0-0") and (has $l "--max-time 15") and ($l =~ '/v2/aprende-[a-z]+/blobs/sha256:[0-9a-f]{64}$') }) ($blobs | str join "\n")
	rm -rf $w.dir
}

def test_a_blob_still_cut_off_after_the_restart_fails_the_release [] {
	print "test a blob that is still cut off after the restart and the second bake fails the release naming it, with one restart..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join blob_cutoff)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "still does not serve them after a restart and a second push") $r.stderr
	assert (has $r.stderr $"@sha256:('d' | fill -c 'd' -w 64)") $r.stderr
	assert equal (bakes $w) 2
	assert equal (restarts $w) 1
	rm -rf $w.dir
}

def test_a_blob_that_answers_200_or_416_for_an_empty_one_is_served [] {
	print "test a blob that answers 200 (a registry that ignores the range) is served, and 416 is the answer of an empty blob only..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join blob_200)
	let r = (in-world $w $release_nu --app $w.app)
	assert (released $r) $"($r.stdout)\n($r.stderr)"
	assert equal (restarts $w) 0
	assert equal (bakes $w) 1
	rm -rf $w.dir
	# an empty layer (size 0 in the manifest) answers 416
	let z = (sandbox)
	"" | save -f ($z.dir | path join zero_layer)
	"" | save -f ($z.dir | path join blob_416)
	let r2 = (in-world $z $release_nu --app $z.app)
	assert (released $r2) $"($r2.stdout)\n($r2.stderr)"
	assert equal (restarts $z) 0
	rm -rf $z.dir
}

def test_an_open_upload_or_a_held_lock_blocks_the_registry_restart [] {
	print "test a restart is refused while an upload is open (a push with no lease) or another collector holds the lock..."
	let w = (sandbox)
	"/var/lib/registry/docker/registry/v2/repositories/x/_uploads/u" | save -f ($w.state | path join uploads)
	"" | save -f ($w.dir | path join manifest_404_once)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "an upload is open (a push outside the leases), and a restart would cut it") $r.stderr
	assert equal (restarts $w) 0
	assert equal (bakes $w) 1
	rm -rf $w.dir
	# another collector holds the lock: the restart waits for nobody and is refused
	let l = (sandbox)
	seed-lease $l registry-gc-lock collector-other 5
	let build = "{registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}"
	let c = (in-world $l -c $"use ($engine_dir | path join registry.nu); registry restart-alone ($build) ''")
	assert equal $c.exit_code 0 $"($c.stdout)($c.stderr)"
	assert (has $c.stdout "another release is collecting") $c.stdout
	assert equal (restarts $l) 0
	assert (($l.state | path join lease registry-gc-lock) | path exists) "the other collector's lock is left alone"
	rm -rf $l.dir
}

def test_an_answer_that_is_not_a_404_fails_the_release_with_no_restart [] {
	print "test a 500, a cut-off manifest, a 500 or a timeout on a blob, and a 416 for a blob that is not empty fail the release at once: nothing is restarted, nothing baked again..."
	for marker in [manifest_500 manifest_cutoff blob_500 blob_timeout blob_416] {
		let w = (sandbox)
		"" | save -f ($w.dir | path join $marker)
		let r = (in-world $w $release_nu --app $w.app)
		assert ($r.exit_code != 0) $marker
		let said = match $marker { "manifest_cutoff" => "(curl exit 18)", "blob_timeout" => "(curl exit 28)", "blob_416" => "answered 416 for", _ => "answered 500 for" }
		assert (has $r.stderr $said) $"($marker): ($r.stderr)"
		assert equal (bakes $w) 1 $marker
		assert equal (restarts $w) 0 $marker
		assert (calls $w | any {|c| $c | str starts-with "delete lease registry-lease-aprende-" }) $"($marker): the lease was deleted"
		rm -rf $w.dir
	}
}

def test_another_releases_lease_blocks_the_registry_restart [] {
	print "test a restart is not made while another release holds a lease: the release fails naming it, and bakes once..."
	let w = (sandbox)
	seed-lease $w registry-lease-studio-other other-release 5 --labelled
	"" | save -f ($w.dir | path join manifest_404_once)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "other releases are in flight (registry-lease-studio-other)") $r.stderr
	assert equal (restarts $w) 0 "no restart under another's push"
	assert equal (bakes $w) 1
	assert (not (($w.state | path join lease registry-gc-lock) | path exists)) "the lock is released"
	assert (($w.state | path join lease registry-lease-studio-other) | path exists) "the other's lease is untouched"
	rm -rf $w.dir
}

def test_only_the_image_that_is_missing_is_named [] {
	print "test one missing image among several is the only one named, and a cache that is off is not restarted for..."
	let w = (sandbox)
	"aprende-crud" | save -f ($w.dir | path join manifest_404_for)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0)
	assert (has $r.stderr "aprende-crud@sha256:") $r.stderr
	assert (not (has $r.stderr "aprende-auth@")) $r.stderr
	assert (not (has $r.stderr "aprende-caddy@")) $r.stderr
	assert equal (restarts $w) 1
	rm -rf $w.dir
	# the cache disabled: a restart would change nothing, so there is none
	let off = (sandbox)
	'[{"name":"REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR","value":"disabled"}]' | save -f ($off.state | path join registry_env)
	"" | save -f ($off.dir | path join manifest_404)
	let r2 = (in-world $off $release_nu --app $off.app)
	assert ($r2.exit_code != 0)
	assert (has $r2.stderr "its blob descriptor cache is disabled, so a restart would not bring the images back") $r2.stderr
	assert equal (restarts $off) 0
	assert equal (bakes $off) 1
	rm -rf $off.dir
}

def test_an_index_is_followed_to_its_children_and_their_blobs [] {
	print "test an image index is followed to its child manifests, whose config and layers are each asked..."
	let w = (sandbox)
	"" | save -f ($w.dir | path join manifest_index)
	let idx = $"sha256:('1' | fill -c '1' -w 64)"
	let body = $"use ($engine_dir | path join registry.nu); registry lost-images '127.0.0.1:5000' [{repo: 'aprende-crud', digest: '($idx)'}] | to nuon"
	let r = (in-world $w -c $body)
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	assert equal ($r.stdout | str trim) "[]"
	let asked = (curl-log $w manifest_curl.log)
	assert equal ($asked | length) 2 "the index, then its child"
	assert (has $asked.1 $"manifests/sha256:('2' | fill -c '2' -w 64)") $asked.1
	let blobs = (curl-log $w blob_curl.log)
	assert equal ($blobs | length) 2 "the child's config and its layer"
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

# A registry that answers every HEAD with `status`, for as long as `body` runs: {port, pid} to it.
def with-registry [w: record, status: int, body: closure]: nothing -> any {
	let script = ($w.dir | path join registry.py)
	r#'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(@STATUS@); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open('@DIR@/port', 'w').write(str(s.server_address[1]))
s.serve_forever()
'# | str replace '@STATUS@' ($status | into string) | str replace '@DIR@' $w.dir | save -f $script
	^sh -c $"python3 ($script) & echo $! > ($w.dir)/pid"
	mut tries = 0
	while not ($w.dir | path join port | path exists) and $tries < 50 { sleep 100ms; $tries += 1 }
	let pid = (open --raw ($w.dir | path join pid) | str trim)
	try {
		let r = (do $body (open --raw ($w.dir | path join port) | str trim))
		^kill $pid
		$r
	} catch {|e|
		^kill $pid
		error make {msg: $e.msg}
	}
}

def test_a_live_image_that_cannot_be_checked_stops_the_prune [] {
	print "test a registry that answers 503 for an image the cluster names stops the prune before any delete or collection..."
	let w = (sandbox)
	let digest = ("sha256:" + (0..63 | each {"a"} | str join))
	$"127.0.0.1:5000/aprende-crud:release@($digest)" | save -f ($w.state | path join inuse)
	let r = (with-registry $w 503 {|port|
		let body = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}; registry prune '127.0.0.1:($port)' $build"
		in-world $w -c $body
	})
	assert ($r.exit_code != 0)
	assert (has $r.stderr "the registry answered 503 for the live image aprende-crud") $r.stderr
	assert (not ((calls $w) | any {|c| $c | str starts-with "exec" })) "no collection"
	assert (not (($w.state | path join lease registry-gc-lock) | path exists)) "and the lock it took is released"
	# a 404: the registry does not hold it, nothing to protect: the prune goes on to the collection
	let r404 = (with-registry $w 404 {|port|
		let body = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}; registry prune '127.0.0.1:($port)' $build"
		in-world $w -c $body
	})
	assert (not (has $r404.stderr "the registry answered")) $r404.stderr
	rm -rf $w.dir
}

# A Lease as the API server holds it, seeded into the fake's state: renewed `ago` seconds ago by `holder`.
def seed-lease [w: record, name: string, holder: string, ago: int, --labelled] {
	mkdir ($w.state | path join lease)
	let at = ((date now) - ($ago * 1sec) | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S.%6fZ")
	{
		apiVersion: "coordination.k8s.io/v1", kind: "Lease"
		metadata: ({name: $name, namespace: "pronto-registry", creationTimestamp: ((date now) - ($ago * 1sec) | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"), resourceVersion: "7", uid: "00000000-0000-0000-0000-000000000007"} | merge (if $labelled { {labels: {"pronto.dev/registry-lease": "true"}} } else { {} }))
		spec: {holderIdentity: $holder, leaseDurationSeconds: 3600, renewTime: $at}
	} | to json | save -f ($w.state | path join lease $name)
}

def test_the_collection_waits_for_releases_in_flight [] {
	print "test the collection is skipped while another release holds a lease or the collector's lock, runs with only its own, and a release waits out no lock..."
	let w = (sandbox)
	let build = "{registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}}"
	let use = $"use ($engine_dir | path join registry.nu); let build = ($build);"
	# a release's lease is a labelled Lease, taken in one call before the push
	let a = (in-world $w -c $"($use) registry lease-acquire $build aprende aprende")
	assert equal $a.exit_code 0 $a.stderr
	let a_name = ($a.stdout | str trim)
	assert ($a_name starts-with "registry-lease-aprende-") $a_name
	assert equal (calls $w | where {|c| $c | str starts-with "create" } | length) 1 "one call makes the lease, labelled"
	let b = (in-world $w -c $"($use) registry lease-acquire $build studio studio")
	let b_name = ($b.stdout | str trim)
	# a collection by the first: the second's lease is in flight (read from the Lease the server holds), nothing is collected
	let c = (in-world $w -c $"($use) registry collect $build '($a_name)'")
	assert equal $c.exit_code 0 $c.stderr
	assert (has $c.stdout "releases in flight") $c.stdout
	assert (not ((calls $w) | any {|x| $x | str contains "garbage-collect" })) "no collection under another release's lease"
	assert (not (($w.state | path join lease registry-gc-lock) | path exists)) "the lock is released"
	# the second ends: only the first's own lease is left, and the collection runs
	in-world $w -c $"($use) registry lease-release $build '($b_name)'" | ignore
	let d = (in-world $w -c $"($use) registry collect $build '($a_name)'")
	assert equal $d.exit_code 0 $"($d.stdout)($d.stderr)"
	assert ((calls $w) | any {|x| $x | str contains "garbage-collect" }) "collected with only its own lease"
	assert (($w.state | path join lease $a_name) | path exists) "its own lease is left to its release"
	# a fresh lock held by another collector: skipped and left alone; a lease waits (here, not at all) and refuses
	seed-lease $w registry-gc-lock collector-other 5
	rm -f ($w.state | path join calls.jsonl)
	let e = (in-world $w -c $"($use) registry collect $build ''")
	assert equal $e.exit_code 0 $e.stderr
	assert (has $e.stdout "another release is collecting") $e.stdout
	assert (not ((calls $w) | any {|x| $x | str contains "garbage-collect" })) "a held lock stops the collection"
	assert ((open --raw ($w.state | path join lease registry-gc-lock) | from json | get spec.holderIdentity) == "collector-other") "another's lock is not deleted"
	let f = (in-world $w -c $"($use) registry lease-acquire $build aprende aprende --wait 0")
	assert ($f.exit_code != 0) "a release does not push under a collection"
	assert (has $f.stderr "is being collected") $f.stderr
	assert equal (ls ($w.state | path join lease) | length) 2 "the lock and the first lease are left: the refused lease was taken back"
	rm -rf $w.dir
}

def test_a_stale_lock_is_taken_over_against_its_resource_version [] {
	print "test a stale collector lock is replaced against the resourceVersion read, a conflict leaves it, and a lease is renewed in place..."
	let w = (sandbox)
	let use = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}};"
	seed-lease $w registry-gc-lock collector-dead 7200
	let r = (in-world $w -c $"($use) registry collect $build ''")
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	let replace = (calls $w | where {|c| $c | str starts-with "replace -f -" })
	assert equal ($replace | length) 1 "the stale lock is replaced"
	assert ((calls $w) | any {|x| $x | str contains "garbage-collect" }) "and the collection runs"
	assert (not (($w.state | path join lease registry-gc-lock) | path exists)) "its own lock is released"
	# a conflict: someone else renewed it between the read and the replace
	seed-lease $w registry-gc-lock collector-dead 7200
	"" | save -f ($w.state | path join lease_conflict)
	rm -f ($w.state | path join calls.jsonl)
	let c = (in-world $w -c $"($use) registry collect $build ''")
	assert equal $c.exit_code 0 $c.stderr
	assert (has $c.stdout "another release is collecting") $c.stdout
	assert (not ((calls $w) | any {|x| $x | str contains "garbage-collect" })) "a lost takeover collects nothing"
	assert ((open --raw ($w.state | path join lease registry-gc-lock) | from json | get spec.holderIdentity) == "collector-dead") "and deletes nothing of another's"
	rm -f ($w.state | path join lease_conflict)
	# a lease renewed in place
	seed-lease $w registry-lease-aprende-x registry-lease-aprende-x 600 --labelled
	let before = (open --raw ($w.state | path join lease registry-lease-aprende-x) | from json | get spec.renewTime)
	let n = (in-world $w -c $"($use) registry lease-renew $build registry-lease-aprende-x")
	assert equal $n.exit_code 0 $n.stderr
	let after = (open --raw ($w.state | path join lease registry-lease-aprende-x) | from json | get spec.renewTime)
	assert ($after > $before) "the renewal moved its renewTime"
	rm -rf $w.dir
}

def test_prune_runs_only_the_maintenance [] {
	print "test --prune records the maintenance outcome and releases nothing, and goes with no other flag..."
	let w = (sandbox)
	let bad = (in-world $w $release_nu --app $w.app --prune --check)
	assert ($bad.exit_code != 0)
	let r = (in-world $w $release_nu --app $w.app --prune)
	assert ($r.exit_code != 0) "no registry answers behind the forward: the maintenance fails, and says so"
	assert (has $r.stderr "the registry maintenance failed") $r.stderr
	assert (not ((writes $w) | any {|x| $x | str contains "Deployment/" })) "nothing was released"
	assert ((calls $w) | any {|c| $c | str starts-with "patch configmap pronto-release" }) "the outcome is recorded"
	rm -rf $w.dir
}

def test_the_apps_compose_plugin_is_the_one_that_renders [] {
	print "test the compose plugin the app's mise pins (first on the PATH) is linked into the config docker renders with..."
	let w = (sandbox)
	"#!/bin/sh\nexit 0\n" | save -f ($w.dir | path join bin docker-cli-plugin-docker-compose)
	^chmod +x ($w.dir | path join bin docker-cli-plugin-docker-compose)
	let r = (in-world $w -c (script $w ((inputs $w) + " let c = (render compose-config $app_info.dir); print ($c.services | columns | length)")))
	assert equal $r.exit_code 0 $r.stderr
	assert ((open --raw ($w.dir | path join compose_plugins) | str trim | path basename) == "docker-cli-plugin-docker-compose") "the pinned plugin is linked as docker-compose"
	assert ((open --raw ($w.dir | path join compose_plugins) | str trim) | str contains ($w.dir | path basename)) "and it is the sandbox's, first on the PATH"
	rm -rf $w.dir
}

def test_a_failed_lease_renewal_is_a_warning_and_the_record_starts_unknown [] {
	print "test a lease renewal that fails before the push stops the release and after it is a warning, and the record starts with maintenance unknown..."
	let w = (sandbox)
	"" | save -f ($w.state | path join lease_patch_fail)
	# before the push nothing is live: a renewal that fails stops the release, and nothing is built or applied
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0) "a lease that cannot be renewed before the push stops the release"
	assert (has $r.stderr "kubectl patch lease") $"($r.stdout)($r.stderr)"
	assert (not ((calls $w) | any {|c| $c | str contains "Deployment/" })) "nothing was applied"
	assert (not ((docker-calls $w) | any {|c| $c | str starts-with "buildx bake" })) "and nothing was built"
	# after the release is applied it is a warning: the third renewal fails, and the release is live all the same
	rm -rf $w.dir
	let w = (sandbox)
	"3" | save -f ($w.state | path join lease_patch_fail_from)
	let late = (in-world $w $release_nu --app $w.app)
	assert (released $late) $"($late.stdout)($late.stderr)"
	assert (has $late.stderr "warning: the registry lease") $late.stderr
	assert (has $late.stdout "[SUCCESS] Released aprende") $late.stdout
	# a record written by a release says nothing of the maintenance until the prune has been recorded
	rm -rf $w.dir
	let v = (sandbox)
	let rec = (in-world $v -c (script $v $"(inputs $v) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $rec.exit_code 0 $"($rec.stdout)($rec.stderr)"
	let data = (open --raw ($v.state | path join cm pronto-release) | from json | get data)
	assert equal $data.pruned "" "pruned starts empty"
	assert equal $data.prune_error "" "and so does prune_error"
	let s = (in-world $v $release_nu --app $v.app --serving)
	assert (has $s.stdout "maintenance unknown") $s.stdout
	rm -rf $v.dir
}

def test_a_scan_that_fails_aborts_the_collection_and_a_deferred_one_is_pending [] {
	print "test a failed upload scan aborts the collection, and a deferred collection is recorded pending, not pruned..."
	let w = (sandbox)
	let use = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}};"
	"" | save -f ($w.state | path join find_fail)
	let r = (in-world $w -c $"($use) registry collect $build ''")
	assert ($r.exit_code != 0) "a scan that fails stops the collection"
	assert (not ((calls $w) | any {|c| $c | str contains "garbage-collect" })) "and collects nothing"
	assert (not (($w.state | path join lease registry-gc-lock) | path exists)) "its lock is released all the same"
	rm -f ($w.state | path join find_fail)
	# a deferred collection: the record says pending, and --serving says so
	let body = $"use ($engine_dir | path join release.nu) [record-prune]; record-prune {namespace: aprende} null 'releases are in flight'"
	let p = (in-world $w -c $body)
	assert equal $p.exit_code 0 $p.stderr
	let patch = (calls $w | where {|c| $c | str starts-with "patch configmap pronto-release" } | first)
	assert (has $patch '"pruned":"pending"') $patch
	assert (has $patch "collection deferred: releases are in flight") $patch
	let s = (in-world $w $release_nu --app $w.app --serving)
	assert (has $s.stdout "maintenance pending") $s.stdout
	rm -rf $w.dir
}

def test_a_file_name_with_a_newline_is_one_name [] {
	print "test a file name with a newline in it is staged as one file..."
	let w = (sandbox)
	"x" | save -f ($w.app | path join "two\nlines.txt")
	let r = (in-world $w $release_nu --app $w.app --check --build)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert ((open --raw ($w.dir | path join bake_tree)) | str contains "two") "it is in the build context"
	rm -rf $w.dir
}

def seed-record [w: record, data: record] {
	mkdir ($w.state | path join cm)
	{metadata: {name: "pronto-release", labels: {}, annotations: {}, resourceVersion: "50"}, data: $data} | to json | save -f ($w.state | path join cm pronto-release)
}

def test_verification_is_invalidated_before_a_release_changes_what_serves [] {
	print "test a release empties the verified record before its first write, tolerates no record, and --verified is compare-and-set..."
	let w = (sandbox)
	seed-record $w {sha: "oldsha", verified: "oldsha", pruned: "true", prune_error: ""}
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $r.exit_code 0 $"($r.stdout)($r.stderr)"
	let log = (calls $w)
	let at = {|pat| $log | enumerate | where {|e| $e.item =~ $pat } | get index }
	let first_change = ($log | enumerate | where {|e| ($e.item | str starts-with "apply ") and not ($e.item | str contains "--dry-run") and not ($e.item | str contains "Namespace/") } | get index | first)
	assert ((do $at "^patch configmap pronto-release" | first) < $first_change) "the record is invalidated before the first write that changes what serves (after the server's dry run)"
	assert ((do $at "^patch configmap pronto-release" | first) > (do $at "--dry-run=server" | first)) "and after the server accepted the render"
	# a first release has no record: NotFound is not a failure
	rm -f ($w.state | path join cm pronto-release)
	"" | save -f ($w.state | path join strict_cm)
	let first = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $first.exit_code 0 $"($first.stdout)($first.stderr)"
	rm -f ($w.state | path join strict_cm)
	# --verified writes only against the version it read
	seed-record $w {sha: "abc", verified: "", pruned: "true", prune_error: ""}
	"" | save -f ($w.state | path join cm_race)
	let lost = (in-world $w $release_nu --app $w.app --verified abc)
	assert ($lost.exit_code != 0) "a record that changed since it was read is a conflict"
	assert (has $lost.stderr "Conflict") $lost.stderr
	rm -f ($w.state | path join cm_race)
	# a record rewritten once meanwhile (the maintenance's outcome, say) is read again and marked
	"" | save -f ($w.state | path join cm_race_once)
	let again = (in-world $w $release_nu --app $w.app --verified abc)
	assert equal $again.exit_code 0 $"($again.stdout)($again.stderr)"
	assert (has $again.stderr "trying again") $again.stderr
	let won = (in-world $w $release_nu --app $w.app --verified abc)
	assert equal $won.exit_code 0 $"($won.stdout)($won.stderr)"
	rm -rf $w.dir
}

def test_a_failed_provider_export_stops_the_release [] {
	print "test an app whose auth providers do not export stops the release instead of releasing without them..."
	let w = (sandbox)
	rm -f ($w.app | path join code.cue)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	assert (has $r.stderr "auth providers of") $r.stderr
	rm -rf $w.dir
}

def test_the_lock_is_released_against_what_was_read_and_its_failure_is_told [] {
	print "test the collector's lock is deleted against the uid and version read, a refused delete is told, an empty registry has nothing to collect, and a prune reads the cluster only under the lock..."
	let w = (sandbox)
	let use = $"use ($engine_dir | path join registry.nu); let build = {registry: {host: '127.0.0.1:5000', namespace: 'pronto-registry', deployment: 'registry'}};"
	# the lock taken over between this collector's read and its delete: the delete is refused (409), and nothing of another's is deleted
	"" | save -f ($w.state | path join lock_taken_over)
	let a = (in-world $w -c $"($use) registry collect $build ''")
	assert equal $a.exit_code 0 $"($a.stdout)($a.stderr)"
	assert ((calls $w) | any {|c| $c | str starts-with "delete --raw" }) "the delete names its preconditions"
	assert (($w.state | path join lease registry-gc-lock) | path exists) "a lock that changed hands is left"
	rm -f ($w.state | path join lease registry-gc-lock) ($w.state | path join lock_taken_over)
	# a refused delete of the lock is told, with the work as done
	"" | save -f ($w.state | path join lock_delete_fail)
	let b = (in-world $w -c $"($use) registry collect $build ''")
	assert ($b.exit_code != 0)
	assert (has $b.stderr "the maintenance ran") $b.stderr
	rm -f ($w.state | path join lease registry-gc-lock) ($w.state | path join lock_delete_fail)
	# a registry never pushed to
	rm -f ($w.state | path join calls.jsonl)
	"" | save -f ($w.state | path join no_repositories)
	let c = (in-world $w -c $"($use) registry collect $build ''")
	assert equal $c.exit_code 0 $"($c.stdout)($c.stderr)"
	assert (has $c.stdout "nothing to collect") $c.stdout
	assert (not ((calls $w) | any {|x| $x | str contains "garbage-collect" })) "nothing is collected"
	rm -f ($w.state | path join no_repositories)
	# a prune with another release in flight reads nothing of the cluster and keeps its hands off the keep tags
	seed-lease $w registry-lease-studio-x registry-lease-studio-x 5 --labelled
	rm -f ($w.state | path join calls.jsonl)
	let d = (in-world $w -c ($use + " print (registry prune '127.0.0.1:1' $build 'registry-lease-aprende-y')"))
	assert equal $d.exit_code 0 $"($d.stdout)($d.stderr)"
	assert (has $d.stdout "releases are in flight") $d.stdout
	assert (not ((calls $w) | any {|x| $x | str starts-with "get pods -A" })) "the cluster is not read outside the lock and the leases' quiet"
	rm -rf $w.dir
}

def test_only_a_confirmed_absence_is_created [] {
	print "test rollback deletes a Deployment recorded absent (revision 0, generation 0), and leaves one that existed awaiting its first revision..."
	let w = (sandbox)
	"1" | save -f ($w.state | path join revision aprende-crud)
	"1" | save -f ($w.state | path join revision aprende-electric)
	let use = $"use ($engine_dir | path join rollback.nu);"
	let r = (in-world $w -c ($use + " rollback undo [{name: aprende-crud, revision: 0, generation: 1}, {name: aprende-electric, revision: 0, generation: 0}] aprende | to json --raw"))
	assert equal $r.exit_code 0 $r.stderr
	let deletes = (calls $w | where {|c| $c | str starts-with "delete deployment" })
	assert equal $deletes ["delete deployment aprende-electric -n aprende --ignore-not-found"] "only the one recorded absent is deleted"
	assert (has $r.stdout "existed without a revision; left as the release applied it") "the one that existed without a revision is said, not deleted"
	assert (has $r.stdout "aprende-crud") $r.stdout
	rm -rf $w.dir
}

def test_a_deferred_prune_exits_four [] {
	print "test --prune that is deferred (a release's lease is held) records pending and exits 4, not a failure..."
	let w = (sandbox)
	seed-lease $w registry-lease-studio-x registry-lease-studio-x 5 --labelled
	seed-record $w {sha: "abc", verified: "abc", pruned: "false", prune_error: "x"}
	# a registry that answers, so the prune reaches the lease check rather than failing on the network
	let r = (with-registry $w 200 {|port| in-world $w $release_nu --app $w.app --prune })
	assert equal $r.exit_code 4 $"($r.stdout)\n($r.stderr)"
	assert (has $r.stderr "deferred, not done") $r.stderr
	let patch = (calls $w | where {|c| ($c | str starts-with "patch configmap pronto-release") and ($c | str contains "pruned") } | last)
	assert (has $patch '"pruned":"pending"') $patch
	rm -rf $w.dir
}

def test_the_door_must_not_answer_the_dapr_api [] {
	print "test a release fails when the door answers the Dapr sidecar's metadata, passes on PostgREST's 404, and fails on a curl failure, a timeout or a 502..."
	let w = (sandbox)
	let ok = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $ok.exit_code 0 $"($ok.stdout)($ok.stderr)"
	# the door's own Dapr configuration is applied before the Deployment that names it, or its sidecar starts on a missing one
	let log = (calls $w)
	let guard_at = ($log | enumerate | where {|e| ($e.item =~ "^apply .*Configuration/aprende-caddy-invoke-only") and not ($e.item | str contains "--dry-run") } | get index)
	let caddy_at = ($log | enumerate | where {|e| ($e.item =~ "^apply .*Deployment/aprende-caddy") and not ($e.item | str contains "--dry-run") } | get index)
	assert (($guard_at | length) > 0 and ($caddy_at | length) > 0) $"both are applied: ($log | str join '; ')"
	assert (($guard_at | first) < ($caddy_at | first)) "the guard Configuration comes before the caddy Deployment"
	# the probes dial the node's ingress through a port-forward to the Gateway's Envoy Service, plain HTTP, the public Host
	let door_log = ($w.dir | path join door_curl.log | open --raw | lines)
	assert (($door_log | length) == 14) $"fourteen probes, the three upper-case spellings among them: ($door_log | length)"
	assert ($door_log | all {|l| ($l | str contains "http://127.0.0.1:") and ($l | str contains "-H Host: ")}) ($door_log | str join "\n")
	assert (not ($door_log | any {|l| $l | str contains "https://" })) "no probe uses https or DNS"
	assert (calls $w | any {|c| $c | str starts-with "get service -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=aprende-gateway,gateway.envoyproxy.io/owning-gateway-namespace=aprende" }) "the Service is found by the Gateway's owning labels"
	assert (open --raw ($w.state | path join portforward.args) | str contains "port-forward -n envoy-gateway-system service/envoy-aprende-gateway") "the forward goes to that Service"
	assert (not ($w.state | path join portforward.pid | path exists)) "the port-forward is killed: no pid file is left"
	# a curl failure, a timeout and a 502 each fail the release, naming the probe, and the forward is killed all the same
	for fail in [host_unreachable probe_timeout probe_502] {
		"" | save -f ($w.dir | path join $fail)
		let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
		assert ($r.exit_code != 0) $"($fail) fails the release"
		assert (has $r.stderr "so the door cannot be certified") $"($fail): ($r.stderr)"
		assert (not ($w.state | path join portforward.pid | path exists)) $"($fail): the port-forward is killed"
		rm -f ($w.dir | path join $fail)
	}
	# on the node the Gateways of every app are merged into one Service of the GatewayClass: the door check falls back to it
	"" | save -f ($w.state | path join shared_gateway)
	rm -f ($w.state | path join calls.jsonl)
	let shared = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $shared.exit_code 0 $"($shared.stdout)($shared.stderr)"
	assert (open --raw ($w.state | path join portforward.args) | str contains "port-forward -n envoy-gateway-system service/pronto-gateway") "the forward goes to the GatewayClass's shared Service"
	assert (calls $w | any {|c| $c | str starts-with "get service -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gatewayclass=eg" }) "found by the GatewayClass label"
	rm -f ($w.state | path join shared_gateway)
	# the doorguard answers /crud's Dapr paths with its own empty 404 before PostgREST sees them: that passes too
	"" | save -f ($w.dir | path join crud_guard)
	rm -f ($w.state | path join calls.jsonl)
	let guarded = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert equal $guarded.exit_code 0 $"the doorguard's own 404 passes the /crud probes: ($guarded.stdout)($guarded.stderr)"
	rm -f ($w.dir | path join crud_guard)
	# a forward that cannot start, or a Gateway with no data-plane Service, fails too
	for fail in [port_forward_fail no_gateway_service] {
		"" | save -f ($w.state | path join $fail)
		let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
		assert ($r.exit_code != 0) $"($fail) fails the release"
		rm -f ($w.state | path join $fail)
		assert (not ($w.state | path join portforward.pid | path exists)) $"($fail): no pid file is left"
	}
	# a preview with no public host of its own is skipped: nothing is looked up, nothing forwarded
	rm -f ($w.state | path join calls.jsonl)
	let skipped = (in-world $w -c (script $w $"(inputs $w) check-door \($node | upsert preview 'nohost' | upsert hosts {production: 'x.example.com'}\) 'app-gateway'"))
	assert equal $skipped.exit_code 0 $"($skipped.stdout)($skipped.stderr)"
	assert (not ((calls $w) | any {|c| ($c | str starts-with "port-forward") or ($c | str starts-with "get service") })) "a preview without a host asks for nothing"
	"" | save -f ($w.dir | path join metadata_open)
	rm -f ($w.state | path join calls.jsonl)
	let open = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($open.exit_code != 0) "the sidecar's metadata fails the release"
	assert (has $open.stderr "the door reaches the Dapr API") $open.stderr
	assert ((calls $w) | any {|c| $c | str starts-with "rollout undo" }) "and the Deployments of this run are rolled back"
	assert (has $ok.stdout "the door's Dapr API is closed") $ok.stdout
	# the probes also send the paths that would reach a service or the sidecar through the prefix, two of them as is
	assert (($w.dir | path join path_as_is.log | open --raw | lines | length) >= 2) "the `..` probes are sent with --path-as-is"
	# PRONTO-1307: a Dapr API path under /img or /blobs is the door's own 404; a 5xx from Dapr, or any proxied answer, fails
	assert (($w.dir | path join door_curl.log | open --raw | lines | where {|l| $l | str contains "/img/v1.0-alpha1/metadata" } | length) >= 1) "the -alpha1 probes are asked"
	assert (($w.dir | path join door_curl.log | open --raw | lines | where {|l| $l | str contains "/blobs/v1.0-alpha1/metadata" } | length) >= 1) "the blobs -alpha1 probe is asked"
	# PRONTO-916: the upper-case spellings are asked too, and must be the door's own 404
	for upper in ["/CRUD/v1.0/metadata" "/Img/v1.0-alpha1/metadata" "/BLOBS/v1.0/metadata"] {
		assert (($w.dir | path join door_curl.log | open --raw | lines | where {|l| $l | str contains $upper } | length) >= 1) $"the ($upper) probe is asked"
	}
	for case in [[file text]; [img_500 "answered 500"] [blobs_alpha_proxied "not the door's own 404"] [upper_img_proxied "not the door's own 404"]] {
		rm -f ($w.dir | path join metadata_open)
		"" | save -f ($w.dir | path join $case.file)
		let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
		assert ($r.exit_code != 0) $"($case.file) fails the release"
		assert (has $r.stderr $case.text) $"($case.file): ($r.stderr)"
		rm -f ($w.dir | path join $case.file)
	}
	# each other leak fails the release too, naming the path
	for leak in [[file path]; [invoke_by_path "/crud/v1.0/invoke/caddy/method/health"] [dotdot_open "/crud/x/../v1.0/invoke/caddy/method/health"] [img_open "/img/v1.0/metadata"] [upper_open "/CRUD/v1.0/metadata"]] {
		rm -f ($w.dir | path join metadata_open)
		"" | save -f ($w.dir | path join $leak.file)
		let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
		assert ($r.exit_code != 0) $"($leak.file) fails the release"
		assert (has $r.stderr "the door reaches the Dapr API") $"($leak.file): ($r.stderr)"
		rm -f ($w.dir | path join $leak.file)
	}
	rm -rf $w.dir
}

def test_a_lease_that_stays_does_not_turn_a_live_release_into_a_failure [] {
	print "test a lease that cannot be deleted after a successful release is status 3, recorded; after a failed one both are told..."
	let w = (sandbox)
	"" | save -f ($w.state | path join lease_delete_fail)
	let r = (in-world $w $release_nu --app $w.app)
	assert equal $r.exit_code 3 $"a live release is not a plain failure: ($r.stdout)\n($r.stderr)"
	assert (has $r.stdout "[SUCCESS] Released aprende") $r.stdout
	assert (has $r.stderr "was not released") $r.stderr
	let patch = (calls $w | where {|c| ($c | str starts-with "patch configmap pronto-release") and ($c | str contains "not released") })
	assert ($patch | is-not-empty) "recorded in prune_error"
	# a release that failed, and a lease that stayed: both messages
	rm -rf $w.dir
	let v = (sandbox)
	"" | save -f ($v.state | path join lease_delete_fail)
	"" | save -f ($v.state | path join job_fail)
	let f = (in-world $v $release_nu --app $v.app)
	assert equal $f.exit_code 1 $"($f.stdout)\n($f.stderr)"
	assert (has $f.stderr "did not complete") $f.stderr
	assert (has $f.stderr "was not released either") $f.stderr
	rm -rf $v.dir
}

def test_a_renewal_that_fails_after_the_push_applies_nothing [] {
	print "test the second strict renewal (after the push) failing, retried, stops the release with nothing applied..."
	let w = (sandbox)
	"2" | save -f ($w.state | path join lease_patch_fail_from)
	let r = (in-world $w $release_nu --app $w.app)
	assert ($r.exit_code != 0) "the release stops"
	assert (has $r.stderr "kubectl patch lease") $r.stderr
	assert (has $r.stderr "trying again") $"it was retried: ($r.stderr)"
	assert equal ((calls $w) | where {|c| $c | str starts-with "patch lease" } | length) 4 "the first renewal, then three attempts of the second"
	assert ((docker-calls $w) | any {|c| $c | str starts-with "buildx bake" }) "the images were pushed"
	assert (not ((calls $w) | any {|c| $c | str contains "Deployment/" })) "and nothing was applied"
	# a NotFound is not retried: the lease is gone
	rm -rf $w.dir
	let v = (sandbox)
	"2" | save -f ($v.state | path join lease_patch_notfound_from)
	let nf = (in-world $v $release_nu --app $v.app)
	assert ($nf.exit_code != 0) "the release stops"
	assert (has $nf.stderr "NotFound") $nf.stderr
	assert (not (has $nf.stderr "trying again")) $"no retry after NotFound: ($nf.stderr)"
	assert equal ((calls $v) | where {|c| $c | str starts-with "patch lease" } | length) 2 "one patch per renewal, no retry"
	assert (not ((calls $v) | any {|c| $c | str contains "Deployment/" })) "and nothing was applied"
	rm -rf $v.dir
	# one blip of the second renewal: retried, and the release goes through
	let o = (sandbox)
	"2" | save -f ($o.state | path join lease_patch_fail_once)
	let ok = (in-world $o $release_nu --app $o.app)
	assert (released $ok) $"($ok.stdout)\n($ok.stderr)"
	assert (has $ok.stdout "[SUCCESS] Released aprende") $ok.stdout
	assert (has $ok.stderr "trying again") $ok.stderr
	rm -rf $o.dir
}

def git-commit-all [dir: string] {
	do { cd $dir; ^git add -A; ^git -c user.name=t -c user.email=t@t commit -q -m x } | complete | ignore
}

def test_the_record_is_the_commit_built_and_serving_agrees [] {
	print "test a dirty tree records no commit, a clean one records HEAD and --serving prints it, and --verified marks it..."
	let w = (sandbox)
	git-commit-all $w.app
	let head = (do { cd $w.app; ^git rev-parse HEAD } | str trim)
	# dirty: a file under the app that HEAD does not hold
	"x" | save -f ($w.app | path join dirty.txt)
	let dirty = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($dirty.exit_code == 0) $dirty.stderr
	let none = (in-world $w $release_nu --app $w.app --serving)
	assert (has $none.stdout "serving  verified  maintenance unknown") $none.stdout
	# clean
	rm -f ($w.app | path join dirty.txt)
	rm -f ($w.state | path join calls.jsonl)
	let clean = (in-world $w $release_nu --app $w.app)
	assert (released $clean) $"($clean.stdout)($clean.stderr)"
	let s = (in-world $w $release_nu --app $w.app --serving)
	assert (has $s.stdout $"serving ($head) verified  maintenance failed") $s.stdout
	# the app's cd marks the public checks passed for it
	let wrong = (in-world $w $release_nu --app $w.app --verified deadbeef)
	assert ($wrong.exit_code != 0) "a commit the node does not serve is not marked verified"
	assert (has $wrong.stderr "the node now serves") $wrong.stderr
	let v = (in-world $w $release_nu --app $w.app --verified $head)
	assert equal $v.exit_code 0 $v.stderr
	let after = (in-world $w $release_nu --app $w.app --serving)
	assert (has $after.stdout $"serving ($head) verified ($head) maintenance failed") $after.stdout
	# nothing recorded: nothing to verify
	rm -f ($w.state | path join cm pronto-release)
	let nothing = (in-world $w $release_nu --app $w.app --verified $head)
	assert ($nothing.exit_code != 0) "no record, no verification"
	rm -rf $w.dir
}

def test_serving_leaves_no_kubeconfig [] {
	print "test --serving and --verified remove the kubeconfig they made..."
	let w = (sandbox)
	let tmp = ($w.dir | path join tmp)
	mkdir $tmp
	with-env {TMPDIR: $tmp} {
		let r = (in-world $w $release_nu --app $w.app --serving)
		assert equal $r.exit_code 0 $r.stderr
		let v = (in-world $w $release_nu --app $w.app --verified abc)
		assert ($v.exit_code != 0)
	}
	assert equal (ls $tmp | where name =~ "kubeconfig" | length) 0 "no kubeconfig is left behind"
	rm -rf $w.dir
}

def test_a_template_accepted_before_its_revision_moves_is_rolled_back [] {
	print "test a Deployment whose template was accepted but whose revision has not moved yet is still rolled back, to its recorded revision..."
	let w = (sandbox)
	for n in [crud electric auth caddy] { "3" | save -f ($w.state | path join revision $"aprende-($n)") }
	"aprende-crud" | save -f ($w.state | path join revision_lag)
	"aprende-electric" | save -f ($w.state | path join rollout_fail)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json)"))
	assert ($r.exit_code != 0)
	let undone = (calls $w | where {|c| $c | str starts-with "rollout undo" })
	assert ("rollout undo deployment/aprende-crud -n aprende --to-revision=3" in $undone) $"the lagging Deployment is undone: ($undone | str join '; ')"
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
	print "test a prune that fails is recorded as prune_error and ends the command with status 3, one that works as pruned..."
	let w = (sandbox)
	let r = (in-world $w $release_nu --app $w.app)
	assert (released $r)
	let patch = (calls $w | where {|c| ($c | str starts-with "patch configmap pronto-release -n aprende --type merge") and ($c | str contains "pruned") })
	assert equal ($patch | length) 1
	assert (has $patch.0 '"pruned":"false"') $patch.0
	assert (has $patch.0 '"prune_error":"') $patch.0
	assert (not (has $patch.0 '"prune_error":""')) "the error is told"
	assert ((calls $w | enumerate | where {|e| $e.item =~ "ConfigMap/pronto-release" } | get index | first) < (calls $w | enumerate | where {|e| $e.item =~ "^patch configmap pronto-release.*pruned" } | get index | first)) "after the release's record"
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

# The psql and pg_dump calls the fake kubectl saw, in order.
def db-calls [w: record]: nothing -> list<record> {
	let f = ($w.state | path join db.log)
	if not ($f | path exists) { return [] }
	open --raw $f | lines | each {|l| $l | from json }
}

def test_adopt_applies_server_side_and_forced [] {
	print "test --adopt applies every object server-side with force, as pronto-release, and a release without it does not..."
	let w = (sandbox)
	mkdir ($w.state | path join namespaces)
	"{}" | save -f ($w.state | path join namespaces aprende)
	let r = (in-world $w -c (script $w $"(inputs $w) release-app $app_info $node $meta $compose $facts [] (pushed-json) --adopt"))
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	# a Job is run, not adopted (the runtime's own apply), and the release's record is the engine's own ConfigMap
	let applies = (writes $w | where {|c| ($c | str starts-with "apply ") and not ($c | str contains "<- Job/") and not ($c | str contains "ConfigMap/pronto-release") })
	assert ($applies | is-not-empty)
	for a in $applies {
		assert ($a | str starts-with "apply --server-side --force-conflicts --field-manager=pronto-release -f -") $"an apply without the adopt flags: ($a)"
	}
	# the namespace first, then the objects, then the Deployments: three applies, all adopted
	assert equal ($applies | length) 3 ($applies | str join "\n")
	# the server's dry run is asked the same kind of apply
	assert ((calls $w) | any {|c| $c | str starts-with "apply --dry-run=server --server-side --force-conflicts --field-manager=pronto-release -f -" })
	assert (not ((calls $w) | any {|c| $c | str starts-with "apply --dry-run=server -f -" }))
	# --check --adopt: nothing is written, the dry run is the adopting one
	let w2 = (sandbox)
	let c = (in-world $w2 $release_nu --app $w2.app --check --adopt)
	assert equal $c.exit_code 0 $"($c.stdout)\n($c.stderr)"
	assert equal (writes $w2) []
	assert ((calls $w2) | any {|l| $l | str starts-with "apply --dry-run=server --server-side --force-conflicts" })
	rm -rf $w.dir
	rm -rf $w2.dir
}

def test_schema_from_copies_the_live_schema_once_and_reads_only [] {
	print "test --schema-from copies the live schema (roles, schema, pgroll rows) into the preview in one transaction before the Jobs, and a second release copies nothing..."
	let w = (sandbox)
	mkdir ($w.state | path join namespaces)
	"{}" | save -f ($w.state | path join namespaces aprende)
	let run = {|| in-world $w -c (script $w $"(inputs $w --preview rc) release-app $app_info $node $meta $compose $facts [] (pushed-json) --schema-from aprende") }
	let r = (do $run)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let db = (db-calls $w)
	# the live namespace is only read: pg_dump, and psql reading roles and the pgroll schema's name, never a transaction of writes
	let live = ($db | where ns == "aprende")
	assert ($live | is-not-empty)
	assert ($live | all {|c| not ($c.cmd | str contains "--single-transaction") })
	assert ($live | where {|c| $c.cmd | str starts-with "psql " } | all {|c| $c.read_only }) "every psql on the live database is a read-only session"
	assert ($live | where {|c| $c.cmd | str starts-with "pg_dump " } | all {|c| $c.cmd | str contains "--lock-wait-timeout=10s" }) "a dump never waits long for a lock live holds"
	assert ($live | any {|c| ($c.cmd | str contains "pg_dump") and ($c.cmd | str contains "--schema-only") and ($c.cmd | str contains "--no-publications") })
	assert ($live | any {|c| ($c.cmd | str contains "pg_dump") and ($c.cmd | str contains "--data-only") and ($c.cmd | str contains "--schema=pgroll") })
	# the preview gets one transaction holding the roles, the schema and the pgroll rows
	let into = ($db | where ns == "aprende-rc" | where {|c| $c.cmd | str contains "--single-transaction" })
	assert equal ($into | length) 1 ($db | to json)
	assert ($into.0.cmd | str contains "ON_ERROR_STOP=1")
	assert ($into.0.stdin | str contains "CREATE ROLE analytics_reader")
	assert ($into.0.stdin | str contains "CREATE TABLE public.game")
	assert ($into.0.stdin | str contains "pgroll.migrations")
	assert ($into.0.stdin | str contains "ALTER DATABASE \"app\" SET pronto.schema_from = 'aprende';") "the transaction marks the database it filled"
	# nothing was written in the live namespace, and the copy is recorded on the preview's Cluster
	assert (not ((writes $w) | any {|c| $c | str contains "-n aprende " }))
	assert ((writes $w) | any {|c| $c == "annotate cluster.postgresql.cnpg.io/aprende-db -n aprende-rc --overwrite pronto.dev/schema-from=aprende" })
	# in order: the copy is before the first Job, the Jobs migrate on top of it
	let log = (calls $w)
	let copied = ($log | enumerate | where {|e| $e.item | str contains "--single-transaction" } | get index | first)
	let first_job = ($log | enumerate | where {|e| $e.item =~ "Job/aprende-" and not ($e.item | str contains "dry-run") } | get index | first)
	assert ($copied < $first_job) "the schema is copied before the schema Jobs"
	# a second release of the same preview: the Cluster says it was copied, nothing is dumped or applied
	let before = ($db | length)
	let again = (do $run)
	assert equal $again.exit_code 0 $"($again.stdout)\n($again.stderr)"
	assert equal (db-calls $w | length) $before "a copied preview is not copied again"
	assert (has $again.stdout "already in aprende-rc")
	rm -rf $w.dir
}

def test_schema_from_is_refused_where_it_cannot_be_read [] {
	print "test --schema-from is refused without --preview, with --delete, for the preview's own namespace, a missing or preview namespace, a missing Cluster, a database that already has tables, and a failed dump copies nothing..."
	let w = (sandbox)
	mkdir ($w.state | path join namespaces)
	"{}" | save -f ($w.state | path join namespaces aprende)
	let no_preview = (in-world $w $release_nu --app $w.app --schema-from aprende)
	assert ($no_preview.exit_code != 0)
	assert (has $no_preview.stderr "needs --preview") $no_preview.stderr
	let with_delete = (in-world $w $release_nu --app $w.app --preview rc --delete --schema-from aprende)
	assert ($with_delete.exit_code != 0)
	assert (has $with_delete.stderr "not --delete") $with_delete.stderr
	assert equal (writes $w) []
	let check = {|from| in-world $w -c (script $w $"(inputs $w --preview rc) check-schema-source aprende $node ($from)") }
	let own = (do $check aprende-rc)
	assert ($own.exit_code != 0)
	assert (has $own.stderr "the preview's own namespace") $own.stderr
	let missing = (do $check nowhere)
	assert ($missing.exit_code != 0)
	assert (has $missing.stderr "does not exist") $missing.stderr
	{"pronto.dev/release": "aprende", "pronto.dev/preview": "other"} | to json | save -f ($w.state | path join namespaces aprende-other)
	let other = (do $check aprende-other)
	assert ($other.exit_code != 0)
	assert (has $other.stderr "a preview's namespace") $other.stderr
	mkdir ($w.state | path join no_cluster)
	"" | save -f ($w.state | path join no_cluster aprende)
	let nocluster = (do $check aprende)
	assert ($nocluster.exit_code != 0)
	assert (has $nocluster.stderr "no database cluster aprende-db") $nocluster.stderr
	rm -f ($w.state | path join no_cluster aprende)
	let fine = (do $check aprende)
	assert equal $fine.exit_code 0 $fine.stderr
	# a preview whose database has tables the release did not copy: refused, nothing written to it
	mkdir ($w.state | path join db_tables)
	"3" | save -f ($w.state | path join db_tables aprende-rc)
	let tables = (in-world $w -c (script $w $"(inputs $w --preview rc) copy-schema aprende aprende aprende-rc"))
	assert ($tables.exit_code != 0)
	assert (has $tables.stderr "already has 3 tables") $tables.stderr
	assert (not (db-calls $w | any {|c| $c.cmd | str contains "--single-transaction" }))
	# a copy that committed, marking the database, and whose annotate failed: recorded again, not copied again, not refused
	mkdir ($w.state | path join db_marked)
	"aprende" | save -f ($w.state | path join db_marked aprende-rc)
	let marked = (in-world $w -c (script $w $"(inputs $w --preview rc) copy-schema aprende aprende aprende-rc"))
	assert equal $marked.exit_code 0 $"($marked.stdout)\n($marked.stderr)"
	assert (not (db-calls $w | any {|c| $c.cmd | str contains "--single-transaction" }))
	assert ((writes $w) | any {|c| $c == "annotate cluster.postgresql.cnpg.io/aprende-db -n aprende-rc --overwrite pronto.dev/schema-from=aprende" })
	rm -f ($w.state | path join schema_from aprende-rc)
	rm -f ($w.state | path join calls.jsonl)
	# live migrations that moved while the schema was read: nothing is copied
	"0" | save -f ($w.state | path join db_tables aprende-rc)
	"3 def" | save -f ($w.state | path join pgroll_mark_after)
	let moved = (in-world $w -c (script $w $"(inputs $w --preview rc) copy-schema aprende aprende aprende-rc"))
	assert ($moved.exit_code != 0)
	assert (has $moved.stderr "changed while its schema was being read") $moved.stderr
	assert (not (db-calls $w | any {|c| $c.cmd | str contains "--single-transaction" }))
	rm -f ($w.state | path join pgroll_mark_after)
	rm -f ($w.state | path join pgroll_mark_seen)
	# a dump that fails copies nothing and records nothing
	"0" | save -f ($w.state | path join db_tables aprende-rc)
	"" | save -f ($w.state | path join db_fail)
	let failed = (in-world $w -c (script $w $"(inputs $w --preview rc) copy-schema aprende aprende aprende-rc"))
	assert ($failed.exit_code != 0)
	assert (not (db-calls $w | any {|c| $c.cmd | str contains "--single-transaction" }))
	assert (not ((calls $w) | any {|c| $c | str contains "pronto.dev/schema-from" }))
	rm -rf $w.dir
}

def test_database_base [] {
	print "test the primary runs the database's base image only where the stage copies files onto a pinned base..."
	let base = $"bonitao/mecha-database:0.22.0@sha256:('a' | fill --character a --width 64)"
	let dir = (mktemp -d -t node-dbbase.XXXXXX | str trim)
	let stage = "FROM libraries_mecha-database-image AS database
ARG BAYT_DIR
WORKDIR /monorepo/${BAYT_DIR}
COPY services/database/migrations/000_extensions.sql services/database/migrations/680_flags.sql \\
  services/database/migrations/685_army.sql /docker-entrypoint-initdb.d/
COPY --from=libraries_mecha-database-image /usr/share/mecha/initdb/899_role_passwords.sh /docker-entrypoint-initdb.d/899_role_passwords.sh
ENTRYPOINT [\"docker-entrypoint.sh\",\"postgres\",\"-c\",\"wal_level=logical\"]
HEALTHCHECK --interval=1s CMD [\"pg_isready\"]
"
	let tail = "\nFROM busybox:musl AS database_ctxs\nRUN touch /x\n"
	let compose = {|ctx| {services: {database: {build: {context: $dir, dockerfile: "Dockerfile.database", target: "database", additional_contexts: {libraries_mecha-database-image: $ctx}}}}} | to yaml }
	let with = {|text, ctx| $"($text)($tail)" | save -f ($dir | path join Dockerfile.database); do $compose $ctx | render database-base }
	# A stage that only copies files onto the base: the base is the primary's, whatever it copies.
	assert equal (do $with $stage $"docker-image://($base)") {ref: $base, name: "libraries_mecha-database-image"}
	# Anything that could add an extension the full image has and the base lacks keeps the primary on the full image.
	assert ((do $with $"($stage)RUN apt-get install -y postgresql-16-pgvector\n" $"docker-image://($base)") | is-empty) "a RUN"
	assert ((do $with $"($stage)ADD https://example.com/ext.so /usr/lib/\n" $"docker-image://($base)") | is-empty) "an ADD"
	assert ((do $with $"($stage)COPY --from=database_ctxs /x /x\n" $"docker-image://($base)") | is-empty) "a copy from another stage"
	assert ((do $with $stage "docker-image://bonitao/mecha-database:0.22.0") | is-empty) "a base not pinned by digest"
	assert ((do $with $"($stage)COPY ext/vector.so /usr/lib/postgresql/17/lib/\n" $"docker-image://($base)") | is-empty) "a file into postgres's own folders"
	assert ((do $with $"($stage)ENV LD_LIBRARY_PATH=/opt/lib\n" $"docker-image://($base)") | is-empty) "an ENV"
	rm -rf $dir
}

def test_the_clusters_spec_does_not_move_with_the_databases_files [] {
	print "test the Cluster's rendered spec is the same for any release of the database's files, and still moves with a real database change..."
	let w = (sandbox)
	let pushed = {|db: string, base: any| (["database" "crud" "electric" "auth" "caddy" "migrate"] | each {|s| [$s {tag: (if $s == "database" { "17" } else { "release" }), digest: ("sha256:" + ($db | fill -c $db -w 64))}] } | into record) | if ($base | is-empty) { $in } else { $in | insert "database-base" {tag: "17", digest: ("sha256:" + ($base | fill -c $base -w 64))} } }
	let render = {|p| let r = (in-world $w -c (script $w $"(inputs $w) render objects $app_info.cue_path \(render release-data $app_info.dir $compose $facts ($p | to nuon) ''\) '' | to json --raw")); assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"; $r.stdout | from json }
	let cluster = {|objs| $objs | where kind == Cluster | first }
	let job = {|objs| $objs | where kind == Job and metadata.name == "aprende-initdb" | first | get spec.template.spec.containers.0.image }
	let one = (do $render (do $pushed "a" "c"))
	let two = (do $render (do $pushed "b" "c"))
	# two releases of the app, whose database files differ: the full image's digest moves, the Cluster does not
	assert equal (do $cluster $one) (do $cluster $two) "the Cluster's spec differs between two releases of the database's files"
	assert ((do $cluster $one | get spec.imageName) | str contains $"aprende-database-base:17@sha256:('c' | fill -c c -w 64)") (do $cluster $one | get spec.imageName)
	assert ((do $job $one) != (do $job $two)) "the schema Job must run the full image of its own release"
	# a moved base is a real database change: the Cluster moves
	let moved = (do $render (do $pushed "a" "d"))
	assert ((do $cluster $moved | get spec.imageName) != (do $cluster $one | get spec.imageName)) "a moved base must change the Cluster"
	# no base (a stage that adds something): the Cluster runs the full image, as upstream renders it
	let full = (do $render (do $pushed "a" null))
	assert ((do $cluster $full | get spec.imageName) | str contains $"aprende-database:17@sha256:('a' | fill -c a -w 64)") (do $cluster $full | get spec.imageName)
	rm -rf $w.dir
}

def test_oidc_clients_are_registered_by_a_runtime_that_has_it_and_never_by_an_older_one [] {
	print "test register-clients runs under runtime 1.15 and is skipped under 1.14, and an empty origin registers nowhere..."
	let w = (sandbox)
	let data = {|runtime: string, origin: string|
		let r = (with-env {PATH: ([($w.dir | path join bin)] | append $env.PATH), FAKE_DIR: $w.state, PRONTO_RUNTIME: $runtime} {
			do { cd $w.app; ^$nu.current-exe --no-config-file -c (script $w $"(inputs $w) render release-data $app_info.dir $compose $facts (pushed-json) '($origin)' | to json --raw") } | complete
		})
		assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
		$r.stdout | from json
	}
	let log = ($w.dir | path join deno.log)
	let registered = {|| if ($log | path exists) { open --raw $log | lines | where {|l| $l | str contains "register.ts" } } else { [] } }
	# an empty origin (a check): nothing is registered
	do $data (runtime-dir) ""
	assert equal (do $registered) [] "an empty origin must not register"
	# runtime 1.15: register.ts runs with the origin
	let on = (do $data (runtime-dir) "https://aprende.example.test")
	assert equal (do $registered | length) 1 "runtime 1.15 registers once"
	assert ((do $registered | first) | str contains "https://aprende.example.test") "the origin is passed to register.ts"
	# a runtime named 1.14.0 has no register-clients: the same data, no call
	let old = ($w.dir | path join "1.14.0")
	^ln -s (runtime-dir) $old
	let off = (do $data $old "https://aprende.example.test")
	assert equal (do $registered | length) 1 "runtime 1.14 must not register"
	assert equal $off $on "the data is the same without registration, for a provider that registers nothing"
	rm -rf $w.dir
}

# --- a tenant's release (PRONTO-740 S2; tenant.nu) ---

const tenant_ns = "studio-owner-game-1a2b3c4d"
const tenant_host = "game-game.example.com"

# A world for a tenant's release: the game fixture, and the two kubeconfigs of its two actors (files the fake kubectl names its callers by).
def tenant-world []: nothing -> record {
	let w = (sandbox --fixture game)
	for f in [publisher.kubeconfig push.kubeconfig] { "" | save -f ($w.dir | path join $f) }
	$w | insert publisher ($w.dir | path join publisher.kubeconfig) | insert pusher ($w.dir | path join push.kubeconfig)
}

# `release.nu --tenant`, as the namespace's publisher (the KUBECONFIG it is given), with `rest` after the tenant's own flags.
def --wrapped tenant-release [w: record, ...rest]: nothing -> record {
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), SOPS_AGE_KEY: "AGE-SECRET-KEY-FAKE", KUBECONFIG: $w.publisher} {
		do { cd $w.app; ^$nu.current-exe --no-config-file $release_nu --app $w.app --tenant $tenant_ns --host $tenant_host --push-kubeconfig $w.pusher ...$rest } | complete
	}
}

# What the fake kubectl was asked by one caller (a kubeconfig's file name), one line a call as `calls` writes them.
def calls-by [w: record, who: string]: nothing -> list<string> {
	let f = ($w.state | path join calls.jsonl)
	if not ($f | path exists) { return [] }
	open --raw $f | lines | each {|l| $l | from json } | where as == $who | each {|c| $c.args | str join ' ' }
}

# Every object the release applied or created, as kind/name/namespace.
def written-objects [w: record]: nothing -> list<string> {
	let f = ($w.state | path join all_objects.jsonl)
	if not ($f | path exists) { return [] }
	open --raw $f | lines | each {|l| $l | from json } | flatten | each {|o| $"($o.kind)/($o.metadata.name)/($o.metadata.namespace? | default '')" } | uniq
}

def test_a_tenant_release_runs_as_its_publisher_alone [] {
	print "test a tenant's release runs as its publisher: no tunnel, no namespace read, no Namespace or policy written, nothing outside its namespace, no exec, no prune..."
	let w = (tenant-world)
	let r = (tenant-release $w)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert (not ($w.dir | path join ssh.log | path exists)) "no ssh tunnel was opened"
	let mine = (calls-by $w publisher.kubeconfig)
	assert ($mine | is-not-empty) "the publisher released"
	# nothing the publisher asked is cluster-wide or outside its namespace
	let outside = ($mine | where {|c| not ($c | str starts-with "auth can-i") and not ($c | str contains $"-n ($tenant_ns)") and not ($c | str contains "-f -") })
	assert equal $outside [] $"a call outside the namespace: ($outside | str join '; ')"
	for banned in ["get namespace" "get nodes" "get crd" "get gatewayclass" "dapr-system" "cnpg-system" "-A" "exec" "garbage-collect"] {
		assert (not ($mine | any {|c| $c | str contains $banned })) $"the publisher asked for ($banned)"
	}
	let objects = (written-objects $w)
	assert equal ($objects | where {|o| $o =~ '^(Namespace|NetworkPolicy|ResourceQuota|LimitRange|CronJob|ScheduledBackup|ObjectStore)/' }) [] "kinds a publisher may not write"
	# but the registry's lease, which the push identity takes in the registry's own namespace
	assert equal ($objects | where {|o| not ($o | str ends-with $"/($tenant_ns)") and not ($o | str starts-with "Lease/") }) [] "every object but the registry's lease is in the tenant's namespace"
	# the record names the app, which the next release of the namespace checks
	let record = (open --raw ($w.state | path join cm pronto-release) | from json)
	assert equal $record.data.app "game"
	# the push identity asked only of the registry's and the gateway's namespaces
	let theirs = (calls-by $w push.kubeconfig)
	assert ($theirs | is-not-empty) "the push identity pushed and checked the door"
	let wrong = ($theirs | where {|c| not ($c | str contains "-n pronto-registry") and not ($c | str contains "-n envoy-gateway-system") and not ($c | str starts-with "auth can-i") and not ($c | str starts-with "create -f -") and not ($c | str starts-with "replace -f -") })
	assert equal $wrong [] $"the push identity asked outside the registry and the gateway: ($wrong | str join '; ')"
	rm -rf $w.dir
}

def test_a_tenant_builds_only_on_the_tenants_buildkitd [] {
	print "test a tenant's images are built on the tenants' buildkitd as OCI archives, never pushed by it, and pushed by the push identity under the tenant's path..."
	let w = (tenant-world)
	let r = (tenant-release $w)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let docker = (open --raw ($w.dir | path join docker.log))
	assert ($docker | str contains "driver remote tcp://buildkitd.pronto-buildkit-tenants.svc:1234") $docker
	assert (not ($docker | str contains "tcp://127.0.0.1")) "never the operator's buildkitd"
	let bake = ($docker | lines | where {|l| $l | str starts-with "buildx bake" } | first)
	assert ($bake | str contains "output=type=oci,dest=") $bake
	assert (not ($bake | str contains "--push")) "the sandboxed buildkitd pushes nothing"
	assert ($bake | str contains "fs.write=") "its archives are written where the engine said"
	let crane = (open --raw ($w.dir | path join crane.log))
	assert ($crane =~ $"push --insecure \\S+ 127\\.0\\.0\\.1:\\d+/($tenant_ns)/game-crud:release") $crane
	let images = (open --raw ($w.state | path join all_objects.jsonl) | lines | each {|l| $l | from json } | flatten | where kind == Deployment | each {|d| $d.spec.template.spec.containers | get image } | flatten | uniq)
	assert ($images | all {|i| $i | str starts-with $"127.0.0.1:5000/($tenant_ns)/game-" }) $"the images: ($images | str join ', ')"
	rm -rf $w.dir
}

def test_a_tenant_release_is_refused_before_anything_is_written [] {
	print "test a tenant's release that names no KUBECONFIG, no host, a preview, a deletion, an adoption, a SOPS file or a hook is refused, with nothing built or written..."
	let w = (tenant-world)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let ask = {|...flags| with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), KUBECONFIG: $w.publisher} { do { cd $w.app; ^$nu.current-exe --no-config-file $release_nu --app $w.app ...$flags } | complete } }
	let cases = [
		{flags: [--tenant $tenant_ns], says: "--tenant needs --host"}
		{flags: [--host $tenant_host], says: "--host and --push-kubeconfig are a tenant's"}
		{flags: [--tenant $tenant_ns --host $tenant_host --preview rc], says: "never a preview, a deletion or a schema copy"}
		{flags: [--tenant $tenant_ns --host $tenant_host --delete], says: "never a preview, a deletion or a schema copy"}
		{flags: [--tenant $tenant_ns --host $tenant_host --adopt], says: "--adopt is not a tenant's"}
		{flags: [--tenant $tenant_ns --host $tenant_host --serving], says: "are the operator's: not with --tenant"}
	]
	for c in $cases {
		let r = (do $ask ...$c.flags)
		assert ($r.exit_code != 0) $"($c.flags | str join ' ') was not refused"
		assert (has $r.stderr $c.says) $"($c.flags | str join ' '): ($r.stderr)"
	}
	# no KUBECONFIG is given: refused
	let none = (with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir)} { do { cd $w.app; ^$nu.current-exe --no-config-file $release_nu --app $w.app --tenant $tenant_ns --host $tenant_host } | complete })
	assert ($none.exit_code != 0) "no KUBECONFIG was not refused"
	assert (has $none.stderr "runs with the KUBECONFIG it is given") $none.stderr
	# a SOPS file is the operator's
	"" | save -f ($w.app | path join secrets.metal.enc.yaml)
	let sops = (tenant-release $w)
	assert ($sops.exit_code != 0) "a SOPS file was not refused"
	assert (has $sops.stderr "decrypts no secrets with the cluster's key") $sops.stderr
	rm -f ($w.app | path join secrets.metal.enc.yaml)
	# a hook runs the release.cue's commands with its credentials
	open ($w.app | path join release.cue) | str replace 'hosts: production:' "hooks: afterJobs: [[\"echo\", \"x\"]]\n\thosts: production:" | save -f ($w.app | path join release.cue)
	let hook = (tenant-release $w)
	assert ($hook.exit_code != 0) "a hook was not refused"
	assert (has $hook.stderr "a tenant's release runs no hooks") $hook.stderr
	assert equal (writes $w) []
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "nothing was built"
	rm -rf $w.dir
}

def test_a_tenant_namespace_and_push_rights_are_asked_before_anything_is_built [] {
	print "test a tenant's release refuses an operator's kubeconfig, a publisher that may not release into the namespace, a namespace another app holds, one an operator holds, and a push identity without its Role..."
	for row in [
		{setup: "operator", says: "may create namespaces, so it is an operator's"}
		{setup: "no-release-right", says: "may not release into"}
		{setup: "other-app", says: "records the release of other: one app per tenant namespace"}
		{setup: "operator-record", says: "holds an operator's release"}
		{setup: "no-lease-right", says: "the push identity may not create leases.coordination.k8s.io in pronto-registry: it needs the Role studio-builder-push"}
		{setup: "no-forward-right", says: "the push identity may not create pods/portforward in pronto-registry"}
		{setup: "no-lease-patch", says: "the push identity may not patch leases.coordination.k8s.io in pronto-registry"}
	] {
		let w = (tenant-world)
		match $row.setup {
			"operator" => { "" | save -f ($w.state | path join auth_operator) }
			"no-release-right" => { "create deployments.apps" | save -f ($w.state | path join auth_deny) }
			"other-app" => { mkdir ($w.state | path join cm); {metadata: {name: "pronto-release"}, data: {app: "other"}} | to json | save -f ($w.state | path join cm pronto-release) }
			"operator-record" => { mkdir ($w.state | path join cm); {metadata: {name: "pronto-release"}, data: {sha: "abc"}} | to json | save -f ($w.state | path join cm pronto-release) }
			"no-lease-right" => { "create leases.coordination.k8s.io" | save -f ($w.state | path join auth_deny) }
			"no-lease-patch" => { "patch leases.coordination.k8s.io" | save -f ($w.state | path join auth_deny) }
			"no-forward-right" => { "create pods --subresource=portforward -n pronto-registry" | save -f ($w.state | path join auth_deny) }
		}
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"($row.setup) was not refused"
		assert (has $r.stderr $row.says) $"($row.setup): ($r.stderr)"
		assert equal (writes $w) [] $row.setup
		assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) $"($row.setup): something was built"
		rm -rf $w.dir
	}
}

def test_a_tenant_check_writes_nothing [] {
	print "test a tenant's --check dry-runs the objects and writes nothing, and --check --build pushes under the tag check and still writes nothing to the namespace..."
	let w = (tenant-world)
	let r = (tenant-release $w --check)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert equal (writes $w) []
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "a check builds nothing"
	assert (has $r.stdout "check passed")
	let b = (tenant-release $w --check --build)
	assert equal $b.exit_code 0 $"($b.stdout)\n($b.stderr)"
	assert equal (writes $w) []
	assert ((open --raw ($w.dir | path join crane.log)) =~ $"/($tenant_ns)/game-crud:check") "the images were pushed under the tag check"
	rm -rf $w.dir
}

def test_a_lost_tenant_image_fails_without_a_restart [] {
	print "test an image the registry lost after a tenant's push fails the release, which never restarts the registry..."
	let w = (tenant-world)
	"" | save -f ($w.dir | path join manifest_404)
	let r = (tenant-release $w)
	assert ($r.exit_code != 0) "a lost image was not refused"
	assert (has $r.stderr "cannot restart the registry") $r.stderr
	assert (not (calls $w | any {|c| $c | str contains "rollout restart" })) "the registry was not restarted"
	assert equal (writes $w) [] "nothing was rolled out"
	rm -rf $w.dir
}

def test_the_tenant_door_check_runs_as_the_pusher [] {
	print "test a tenant's door check runs as the push identity, through a port-forward to the gateway, and a leaking door fails and rolls back the release..."
	let w = (tenant-world)
	let r = (tenant-release $w)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let theirs = (calls-by $w push.kubeconfig)
	assert ($theirs | any {|c| $c | str contains "get service -n envoy-gateway-system" }) "the push identity found the gateway's Service"
	assert ($theirs | any {|c| $c | str starts-with "port-forward -n envoy-gateway-system" }) "and forwarded to it"
	assert (not (calls-by $w publisher.kubeconfig | any {|c| $c | str contains "envoy-gateway-system" })) "the publisher never reached the gateway's namespace"
	rm -rf $w.dir
	let leak = (tenant-world)
	"" | save -f ($leak.dir | path join metadata_open)
	let l = (tenant-release $leak)
	assert ($l.exit_code != 0) "a door that reaches the Dapr API was not refused"
	assert (has $l.stderr "the door reaches the Dapr API") $l.stderr
	assert (has $l.stderr "rolled back") $l.stderr
	rm -rf $leak.dir
}

# --- what a tenant's own release.cue cannot get past (the nushell checks over what it rendered) ---

# The game's release.cue with its own `nodeManifests`: the author's list, not the engine's render.
def own-manifests [w: record, objects: string] {
	let cue = ($w.app | path join release.cue)
	let text = (open --raw $cue)
	let at = ($text | str index-of "nodeManifests:")
	$"(($text | str substring 0..<$at))nodeManifests: ($objects)\n" | save -f $cue
}

def test_a_tenants_own_nodemanifests_cannot_write_what_its_publisher_may_not [] {
	print "test a tenant's own nodeManifests with a foreign image, a NodePort Service, the publisher's account, a user namespace, an unmasked /proc, an unconfined profile, another namespace or a kind its Role lacks is refused after the render and before anything is applied..."
	let ns = $tenant_ns
	let img = $"127.0.0.1:5000/($ns)/game-crud:release@sha256:(('a' | fill -c 'a' -w 64))"
	let deploy = {|pod: string, extra: string| $"{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: {($extra) containers: [{name: \"crud\", image: ($pod)}]}}" }
	let good = $"\"($img)\""
	let cases = [
		{why: "an image of another registry", says: "not an image under 127.0.0.1:5000/($ns)/", objects: $"[(do $deploy '"docker.io/library/nginx:1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' '')]"}
		{why: "an image of another tenant's path", says: "not an image under", objects: $"[(do $deploy '"127.0.0.1:5000/studio-other-game-0/game-crud:release@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' '')]"}
		{why: "a tenant's own image pinned by a tag alone", says: "which is pinned by tag alone: a tenant's image carries its sha256 digest", objects: $"[(do $deploy $'"127.0.0.1:5000/($ns)/game-crud:release"' '')]"}
		{why: "an init container's foreign image", says: "container wait runs", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: {initContainers: [{name: \"wait\", image: \"docker.io/x:1\"}], containers: [{name: \"crud\", image: ($good)}]}}]"}
		{why: "a NodePort Service", says: "is a NodePort Service", objects: $"[{apiVersion: \"v1\", kind: \"Service\", metadata: {name: \"crud\", namespace: \"($ns)\"}, spec: {type: \"NodePort\", ports: [{port: 80}]}}]"}
		{why: "a Service with externalIPs", says: "names externalIPs", objects: $"[{apiVersion: \"v1\", kind: \"Service\", metadata: {name: \"crud\", namespace: \"($ns)\"}, spec: {externalIPs: [\"1.2.3.4\"], ports: [{port: 80}]}}]"}
		{why: "the publisher's service account", says: "runs as the service account publisher", objects: $"[(do $deploy $good 'serviceAccountName: "publisher",')]"}
		{why: "a user namespace", says: "sets hostUsers: false", objects: $"[(do $deploy $good 'hostUsers: false,')]"}
		{why: "an unmasked /proc", says: "sets procMount Unmasked", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: containers: [{name: \"crud\", image: ($good), securityContext: procMount: \"Unmasked\"}]}]"}
		{why: "an unconfined seccomp profile", says: "Unconfined seccomp", objects: $"[(do $deploy $good 'securityContext: seccompProfile: type: "Unconfined",')]"}
		{why: "an unconfined AppArmor profile", says: "Unconfined AppArmor", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: containers: [{name: \"crud\", image: ($good), securityContext: appArmorProfile: type: \"Unconfined\"}]}]"}
		{why: "the deprecated serviceAccount field", says: "runs as the service account publisher", objects: $"[(do $deploy $good 'serviceAccount: "publisher",')]"}
		{why: "an ExternalSecret whose target is a service account token", says: "targets a service account token Secret", objects: $"[{apiVersion: \"external-secrets.io/v1beta1\", kind: \"ExternalSecret\", metadata: {name: \"t\", namespace: \"($ns)\"}, spec: {target: {name: \"t\", template: {type: \"kubernetes.io/service-account-token\"}}}}]"}
		{why: "an ExternalSecret whose target names a service account in an annotation", says: "names a service account in a kubernetes.io/service-account.* annotation", objects: $"[{apiVersion: \"external-secrets.io/v1beta1\", kind: \"ExternalSecret\", metadata: {name: \"t\", namespace: \"($ns)\"}, spec: {target: {name: \"t\", template: {metadata: annotations: {\"kubernetes.io/service-account.name\": \"publisher\"}}}}}]"}
		{why: "a Secret that names a service account in an annotation, of any type", says: "names a service account in a kubernetes.io/service-account.* annotation", objects: $"[{apiVersion: \"v1\", kind: \"Secret\", metadata: {name: \"t\", namespace: \"($ns)\", annotations: {\"kubernetes.io/service-account.name\": \"publisher\"}}, type: \"Opaque\"}]"}
		{why: "a service account token Secret", says: "is a service account token", objects: $"[{apiVersion: \"v1\", kind: \"Secret\", metadata: {name: \"t\", namespace: \"($ns)\"}, type: \"kubernetes.io/service-account-token\"}]"}
		{why: "added capabilities", says: "adds capabilities", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: containers: [{name: \"crud\", image: ($good), securityContext: capabilities: add: [\"NET_ADMIN\"]}]}]"}
		{why: "a hostPort", says: "sets a hostPort", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: containers: [{name: \"crud\", image: ($good), ports: [{containerPort: 80, hostPort: 80}]}]}]"}
		{why: "privilege escalation", says: "allows privilege escalation", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: spec: containers: [{name: \"crud\", image: ($good), securityContext: allowPrivilegeEscalation: true}]}]"}
		{why: "a managed Service of the database that names externalIPs", says: "has a managed Service that is not a ClusterIP, or names externalIPs", objects: $"[{apiVersion: \"postgresql.cnpg.io/v1\", kind: \"Cluster\", metadata: {name: \"game-db\", namespace: \"($ns)\"}, spec: {imageName: \"127.0.0.1:5000/($ns)/game-database:17@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", managed: services: additional: [{selectorType: \"rw\", serviceTemplate: {metadata: name: \"x\", spec: {type: \"ClusterIP\", externalIPs: [\"1.2.3.4\"]}}}]}}]"}
		{why: "a Dapr sidecar annotation", says: "sets the Dapr sidecar annotation", objects: $"[{apiVersion: \"apps/v1\", kind: \"Deployment\", metadata: {name: \"game-crud\", namespace: \"($ns)\"}, spec: template: {metadata: annotations: {\"dapr.io/sidecar-image\": \"evil/daprd\"}, spec: containers: [{name: \"crud\", image: ($good)}]}}]"}
		{why: "a runtimeClassName", says: "sets runtimeClassName", objects: $"[(do $deploy $good 'runtimeClassName: "gvisor",')]"}
		{why: "a priorityClassName", says: "sets priorityClassName", objects: $"[(do $deploy $good 'priorityClassName: "system-node-critical",')]"}
		{why: "an nfs volume", says: "of type nfs, which a tenant's pod may not", objects: $"[(do $deploy $good 'volumes: [{name: "v", nfs: {server: "1.2.3.4", path: "/"}}],')]"}
		{why: "a hostPath volume", says: "of type hostPath, which a tenant's pod may not", objects: $"[(do $deploy $good 'volumes: [{name: "v", hostPath: {path: "/"}}],')]"}
		{why: "a LoadBalancer managed service of the database", says: "has a managed Service that is not a ClusterIP", objects: $"[{apiVersion: \"postgresql.cnpg.io/v1\", kind: \"Cluster\", metadata: {name: \"game-db\", namespace: \"($ns)\"}, spec: {imageName: \"127.0.0.1:5000/($ns)/game-database:17@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", managed: services: additional: [{selectorType: \"rw\", serviceTemplate: {metadata: name: \"x\", spec: type: \"LoadBalancer\"}}]}}]"}
		{why: "another namespace", says: "is in namespace kube-system", objects: $"[{apiVersion: \"v1\", kind: \"ConfigMap\", metadata: {name: \"x\", namespace: \"kube-system\"}}]"}
		{why: "a kind the publisher's Role lacks", says: "is not a kind a tenant's publisher writes", objects: $"[{apiVersion: \"rbac.authorization.k8s.io/v1\", kind: \"RoleBinding\", metadata: {name: \"x\", namespace: \"($ns)\"}}]"}
	]
	for c in $cases {
		let w = (tenant-world)
		own-manifests $w $c.objects
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"($c.why): was not refused: ($r.stdout)"
		assert (has $r.stderr ($c.says | str replace '($ns)' $ns)) $"($c.why): ($r.stderr)"
		# before anything was applied or asked of the server
		assert equal (calls $w | where {|x| ($x | str starts-with "apply") or (($x | str starts-with "create -f") and not ($x | str contains "Lease/")) }) [] $"($c.why): the server was asked"
		assert equal (writes $w) [] $c.why
		rm -rf $w.dir
	}
}

def test_a_tenants_compose_files_name_nothing_outside_the_app [] {
	print "test a tenant's compose project that names a file outside the app (env_file, secrets, an include, ssh, a COMPOSE_ variable) is refused before docker compose resolves it..."
	let cases = [
		{why: "an env_file outside the app", yaml: "services:\n  crud:\n    image: x\n    env_file: ../../secrets.env\n", says: "services.crud.env_file names ../../secrets.env, which is outside the app's own folder"}
		{why: "an absolute env_file in a list", yaml: "services:\n  crud:\n    image: x\n    env_file: [{path: /etc/passwd}]\n", says: "which is outside the app's own folder"}
		{why: "an env_file with a variable", yaml: "services:\n  crud:\n    image: x\n    env_file: ${HOME}/x\n", says: "a path with a variable in it"}
		{why: "a secret's file outside the app", yaml: "secrets:\n  s:\n    file: ../k\nservices: {}\n", says: "secrets.s.file names ../k"}
		{why: "an include", yaml: "include: [other.yaml]\nservices: {}\n", says: "has include"}
		{why: "ssh forwarding into a build", yaml: "services:\n  crud:\n    build: {context: ., ssh: [default]}\n", says: "forwards the release's ssh agent"}
		{why: "an extends that names another file", yaml: "services:\n  crud:\n    image: x\n    extends: {file: base.yaml, service: b}\n", says: "services.crud.extends.file names another file"}
		{why: "an oci-layout additional context (a local directory)", yaml: "services:\n  crud:\n    build:\n      context: .\n      additional_contexts:\n        base: oci-layout:///etc/layout\n", says: "services.crud.build.additional_contexts names oci-layout:///etc/layout, which is not a path inside the app's own folder"}
		{why: "a build context that is a URL", yaml: "services:\n  crud:\n    build: https://example.com/x.git\n", says: "not a path inside the app's own folder"}
	]
	for c in $cases {
		let w = (tenant-world)
		$c.yaml | save -f ($w.app | path join compose.yaml)
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"($c.why): was not refused"
		assert (has $r.stderr "refused before it is resolved") $"($c.why): ($r.stderr)"
		assert (has $r.stderr $c.says) $"($c.why): ($r.stderr)"
		assert equal (writes $w) [] $c.why
		rm -rf $w.dir
	}
	let w = (tenant-world)
	"COMPOSE_FILE=/etc/other.yaml\n" | save -f ($w.app | path join .env)
	let r = (tenant-release $w)
	assert ($r.exit_code != 0) "a COMPOSE_ variable in .env was not refused"
	assert (has $r.stderr ".env names a COMPOSE_ variable") $r.stderr
	rm -rf $w.dir
	# a compose file or .env that is a link (compose follows it), and one that is a folder
	for name in ["compose.yaml" "compose.override.yaml" ".env"] {
		let w = (tenant-world)
		let target = ($w.dir | path join outside.yaml)
		"services: {}\n" | save -f $target
		rm -f ($w.app | path join $name)
		^ln -s $target ($w.app | path join $name)
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"a linked ($name) was not refused"
		assert (has $r.stderr $"($name) is a symlink, not a regular file") $"($name): ($r.stderr)"
		rm -rf $w.dir
	}
	# values that are null where a path would be (extends within the file, an environment or external secret, a configs content) name no file
	let w = (tenant-world)
	"services:\n  b:\n    image: x\n  a:\n    extends: {service: b}\nsecrets:\n  s1: {environment: SOME_VAR}\n  s2: {external: true}\nconfigs:\n  c: {content: hello}\n" | save -f ($w.app | path join compose.yaml)
	let ok = (^$nu.current-exe --no-config-file -c $"use ($engine_dir | path join tenant.nu); tenant check-compose-sources '($w.app)'" | complete)
	assert equal $ok.exit_code 0 $"a project that names no file was refused: ($ok.stderr)"
	rm -rf $w.dir
}

def test_a_tenants_staged_build_paths_are_the_staged_copys [] {
	print "test a project's paths inside the app's own folder are spelled under the staged copy bake may read, and nothing else is..."
	let text = "services:\n  a:\n    build:\n      context: /tmp/rel/apps/mines\n  b:\n    build:\n      context: /tmp/rel/apps/mines-other\n  c:\n    x: \"/tmp/rel/apps/mines/sub\"\n  d:\n    y: /tmp/elsewhere\n"
	let r = (^$nu.current-exe --no-config-file -c $"use ($engine_dir | path join push.nu); print \(push rebase-paths '($text)' /tmp/rel/apps/mines /tmp/w/app\)" | complete)
	assert equal $r.exit_code 0 $r.stderr
	assert (has $r.stdout "context: /tmp/w/app\n") $r.stdout
	assert (has $r.stdout "\"/tmp/w/app/sub\"") $r.stdout
	assert (has $r.stdout "context: /tmp/rel/apps/mines-other") "a folder that only starts with the app's name is not the app's"
	assert (has $r.stdout "y: /tmp/elsewhere") "a path outside the app is left as it is"
}

def test_a_tenants_dry_run_with_no_build_needs_the_publisher_kubeconfig_alone [] {
	print "test a tenant's --check without --build runs with the publisher's kubeconfig alone: no push identity is asked for, there is no lease to renew..."
	let w = (tenant-world)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let r = (with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), KUBECONFIG: $w.publisher} {
		do { cd $w.app; hide-env -i KUBERNETES_SERVICE_HOST; ^$nu.current-exe --no-config-file $release_nu --app $w.app --tenant $tenant_ns --host $tenant_host --check } | complete
	})
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_a_tenants_edited_schema_copy_is_refused [] {
	print "test a tenant's release whose node/schema/node.cue was edited has the engine's own copy put over it before its release.cue is read, and a schema folder with another file in it is refused..."
	let w = (tenant-world)
	let copy = ($w.app | path join node schema node.cue)
	let own = (open --raw ($engine_dir | path join schema node.cue))
	$"($own)\n// edited by the game's author\n" | save -f $copy
	let r = (tenant-release $w --check)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	assert equal (open --raw $copy) $own "the edited copy was read, not replaced"
	"package schema\n" | save -f ($w.app | path join node schema extra.cue)
	let extra = (tenant-release $w --check)
	assert ($extra.exit_code != 0) "another file in node/schema was not refused"
	assert (has $extra.stderr "holds extra.cue beside node.cue") $extra.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
}

def test_a_tenants_build_include_stays_under_the_app [] {
	print "test a build.include that is an absolute path, climbs out, or links out of the app is never staged, and a tenant stages regular files only..."
	let w = (sandbox --fixture game)
	let app = ($w.app | path expand)
	let outside = ($w.dir | path join outside.json)
	'{"secret": true}' | save -f $outside
	^ln -sf $outside ($app | path join link.json)
	mkdir ($app | path join gen)
	"{}" | save -f ($app | path join gen index.json)
	let ask = {|include: string, ...flags| in-world $w -c (script $w $"use ($engine_dir | path join push.nu); let work = \(mktemp -d | str trim\); push stage-context '($app)' $work \($work | path join dest\) ($include) ($flags | str join ' ')") }
	# an absolute path
	let abs = (do $ask '["/etc/hosts"]')
	assert ($abs.exit_code != 0) "an absolute include was not refused"
	assert (has $abs.stderr "which is not under the app's own folder") $abs.stderr
	# a link to a file outside the app, and a file whose folder is such a link
	^ln -sfn $w.dir ($app | path join gen2)
	for inc in ['["link.json"]' '["gen2/outside.json"]'] {
		let r = (do $ask $inc)
		assert ($r.exit_code != 0) $"($inc) was not refused"
		assert (has $r.stderr "which is not under the app's own folder") $r.stderr
	}
	# inside the app it stages; with --tenant a link inside the app is left out and a regular file stays
	let ok = (do $ask '["gen/index.json"]' "--tenant")
	assert equal $ok.exit_code 0 $"($ok.stdout)\n($ok.stderr)"
	# via the full release: the schema refuses an absolute include in the author's release.cue before the build
	let cue = ($app | path join release.cue)
	$"((open --raw $cue))\nNode: build: include: [\"/etc/hosts\"]\n" | save -f $cue
	"x" | save -f ($w.dir | path join publisher.kubeconfig)
	"x" | save -f ($w.dir | path join push.kubeconfig)
	let full = (with-env {PATH: ([($w.dir | path join bin)] | append $env.PATH), FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), KUBECONFIG: ($w.dir | path join publisher.kubeconfig)} {
		do { cd $app; ^$nu.current-exe --no-config-file $release_nu --app $app --tenant $tenant_ns --host $tenant_host --push-kubeconfig ($w.dir | path join push.kubeconfig) } | complete
	})
	assert ($full.exit_code != 0) "an absolute include in a tenant's release.cue was not refused"
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "nothing was built"
	rm -rf $w.dir
}

def test_a_tenants_namespace_is_a_studio_one [] {
	print "test a tenant's namespace that is not studio-<...> is refused before anything else..."
	let w = (tenant-world)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let r = (with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), KUBECONFIG: $w.publisher} {
		do { cd $w.app; ^$nu.current-exe --no-config-file $release_nu --app $w.app --tenant kube-system --host $tenant_host --push-kubeconfig $w.pusher } | complete
	})
	assert ($r.exit_code != 0) "a namespace outside studio- was not refused"
	assert (has $r.stderr "a tenant's namespace is studio-<owner>-<app>-<hash>") $r.stderr
	assert equal (calls $w) []
	rm -rf $w.dir
}

def test_a_tenants_issuers_are_the_engines_list [] {
	print "test a tenant's release whose auth names an issuer off the engine's list (http, a pod name, an IP, a port, credentials, a look-alike host, an _INTERNAL at a pod address) is refused naming the key, before anything is built, written or registered; the broker passes..."
	let w = (tenant-world)
	let compose_file = ($w.dir | path join compose.json)
	let base = (open $compose_file)
	let cases = [
		{env: {OIDC_GOOGLE_ISSUER: "http://flagd:8693"}, says: "OIDC_GOOGLE_ISSUER is refused: an issuer is an https origin"}
		{env: {OIDC_GOOGLE_ISSUER: "https://10.43.0.1"}, says: "OIDC_GOOGLE_ISSUER is refused: an issuer is a name, never an IP address"}
		{env: {OIDC_GOOGLE_ISSUER: "https://[::1]"}, says: "an issuer is a name, never an IP address"}
		{env: {OIDC_GOOGLE_ISSUER: "https://id.bonkchess.com:4000"}, says: "OIDC_GOOGLE_ISSUER is refused: an issuer names no port"}
		{env: {OIDC_GOOGLE_ISSUER: "https://user:hunter2@id.bonkchess.com"}, says: "OIDC_GOOGLE_ISSUER is refused: an issuer carries no credentials"}
		{env: {OIDC_GOOGLE_ISSUER: "https://id.bonkchess.com@flagd:8693"}, says: "an issuer carries no credentials"}
		{env: {OIDC_GOOGLE_ISSUER: "https://id.bonkchess.com.evil.example"}, says: "OIDC_GOOGLE_ISSUER is refused: it is not an issuer a tenant may use"}
		{env: {OIDC_GOOGLE_ISSUER: "https://id.bonkchess.com/evil?token=abc"}, says: "it is not an issuer a tenant may use"}
		{env: {BILLING_BROKER_INTERNAL: "https://10.43.0.7"}, says: "BILLING_BROKER_INTERNAL is refused: an issuer is a name, never an IP address"}
		{env: {BILLING_BROKER_INTERNAL: "https://pronto-llm.pronto-llm.svc"}, says: "BILLING_BROKER_INTERNAL is refused: it is not an issuer a tenant may use"}
	]
	for c in $cases {
		$base | upsert services.auth.environment ($base.services.auth.environment | merge $c.env) | to json | save -f $compose_file
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"($c.env | to nuon) was not refused"
		assert (has $r.stderr $c.says) $"($c.env | to nuon): ($r.stderr)"
		# the error names the setting and the reason, never what the setting held (credentials, a path, a query)
		for v in ($c.env | values) { assert (not (has $r.stderr $v)) $"the error repeats ($v): ($r.stderr)" }
		for part in [hunter2 token=abc flagd] { assert (not (has $r.stderr $part)) $"the error repeats ($part): ($r.stderr)" }
		assert equal (writes $w) []
		assert (not ($w.dir | path join deno.log | path exists)) "nothing was registered or fetched"
		assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "nothing was built"
	}
	# the engine's own list, and the broker on it
	let listed = (in-world $w -c (script $w $"use ($engine_dir | path join tenant.nu); tenant tenant-issuers | to json --raw"))
	assert equal $listed.exit_code 0 $listed.stderr
	assert equal ($listed.stdout | from json) ["https://id.bonkchess.com"]
	$base | upsert services.auth.environment ($base.services.auth.environment | merge {OIDC_GOOGLE_ISSUER: "https://id.bonkchess.com"}) | to json | save -f $compose_file
	let ok = (tenant-release $w --check)
	assert equal $ok.exit_code 0 $"($ok.stdout)\n($ok.stderr)"
	rm -rf $w.dir
}

def test_the_tenant_door_check_in_the_pod_dials_the_service_and_forwards_to_nothing [] {
	print "test a tenant's release run in the builder pod (no --push-kubeconfig) checks the door at the Service's ClusterIP, with no port-forward into the gateway's namespace..."
	let w = (tenant-world)
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let pod = {|extra: record| with-env ({PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), SOPS_AGE_KEY: "AGE-SECRET-KEY-FAKE", KUBECONFIG: $w.publisher, KUBERNETES_SERVICE_HOST: "10.43.0.1"} | merge $extra) {
		do { cd $w.app; ^$nu.current-exe --no-config-file $release_nu --app $w.app --tenant $tenant_ns --host $tenant_host } | complete
	} }
	# a builder whose network policy does not reach the gateway (the fork App's) is refused before anything is built or written
	let none = (do $pod {})
	assert ($none.exit_code != 0) "a builder without the gateway capability was not refused"
	assert (has $none.stderr "does not declare that its network policy reaches the Envoy Gateway") $none.stderr
	assert equal (writes $w) []
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx bake")) "something was built"
	let r = (do $pod {PRONTO_BUILDER_GATEWAY_EGRESS: "1"})
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let door = (open --raw ($w.dir | path join door_curl.log))
	assert ($door | str contains "http://10.43.0.9:80/crud/v1.0/metadata") $door
	assert (not (calls $w | any {|c| $c | str contains "port-forward -n envoy-gateway-system" })) "the door was forwarded to"
	rm -rf $w.dir
}

def test_a_tenants_retirement_is_the_engines_to_decide [] {
	print "test a tenant's retirement is validated in the engine before any write: only #RetireKinds, the resource kubectl is told is the allowlist's own, never the database, a volume claim, a Secret, the namespace's record or what the release writes..."
	let w = (tenant-world)
	let objects = '[{kind: Deployment, metadata: {name: game-crud}}]'
	let kinds = $"use ($engine_dir | path join tenant.nu); let kinds = \(tenant retire-kinds\); let node = {retire: [RETIRE], services: {crud: {seed: {game-seeded: \"flags/flags.json\"}}}}; tenant check-retire $node $kinds ($objects) | to json --raw"
	let ask = {|retire: string| in-world $w -c ($kinds | str replace 'RETIRE' $retire) }
	let refused = [
		{retire: '{kind: Cluster, name: game-db, resource: "cluster.postgresql.cnpg.io"}', says: "retire names Cluster/game-db: a tenant's release may retire only"}
		{retire: '{kind: PersistentVolumeClaim, name: data, resource: pvc}', says: "retire names PersistentVolumeClaim/data"}
		{retire: '{kind: Secret, name: game-auth-secrets, resource: secret}', says: "retire names Secret/game-auth-secrets"}
		{retire: '{kind: ExternalSecret, name: x, resource: externalsecret}', says: "retire names ExternalSecret/x"}
		{retire: '{kind: Namespace, name: studio-owner-game, resource: ns}', says: "retire names Namespace/"}
		{retire: '{kind: Service, name: "--all", resource: service}', says: "not a plain resource name"}
		{retire: '{kind: Service, name: "a,b", resource: service}', says: "not a plain resource name"}
		{retire: '{kind: CronJob, name: old, resource: cronjob.batch}', says: "which a tenant's release never retires"}
		{retire: '{kind: ServiceAccount, name: publisher, resource: serviceaccount}', says: "ServiceAccount/publisher, which a tenant's release never retires"}
		{retire: '{kind: ServiceAccount, name: other, resource: serviceaccount}', says: "which a tenant's release never retires"}
		{retire: '{kind: ConfigMap, name: pronto-release, resource: configmap}', says: "retire names ConfigMap/pronto-release, an object the provisioner or the engine owns"}
		{retire: '{kind: ConfigMap, name: kube-root-ca.crt, resource: configmap}', says: "retire names ConfigMap/kube-root-ca.crt, an object the provisioner or the engine owns"}
		{retire: '{kind: Deployment, name: game-crud, resource: deployment.apps}', says: "which this release writes"}
		{retire: '{kind: ConfigMap, name: game-seeded, resource: configmap}', says: "retire names ConfigMap/game-seeded, which this release writes"}
	]
	for c in $refused {
		let r = (do $ask $c.retire)
		assert ($r.exit_code != 0) $"($c.retire) was not refused"
		assert (has $r.stderr $c.says) $"($c.retire): ($r.stderr)"
	}
	# what passes is deleted as the engine's own kind.group, whatever resource the Node says
	let ok = (do $ask '{kind: Deployment, name: game-old, resource: "cluster.postgresql.cnpg.io"}')
	assert equal $ok.exit_code 0 $ok.stderr
	assert equal ($ok.stdout | from json) [{resource: "deployment.apps", name: "game-old"}]
	# end to end: a Node of its own that retires the database (a release.cue may export one that skips the schema's `retire`) deletes nothing
	let body = $"let app_info = \(runtime resolve-app '($w.app)'\); let node = \(render node-config $app_info.cue_path '' --tenant ($tenant_ns) --host ($tenant_host) | upsert retire [{kind: Cluster, name: game-db, resource: 'cluster.postgresql.cnpg.io'}]\); let meta = \(render app-meta $app_info.cue_path '' --tenant ($tenant_ns) --host ($tenant_host)\); let compose = \(render compose-config $app_info.dir --tenant\); let facts = \(render facts $app_info.dir\); release-app $app_info $node $meta $compose $facts [] (pushed-json) --tenant"
	let path = ([($w.dir | path join bin)] | append $env.PATH)
	let e2e = (with-env {PATH: $path, FAKE_DIR: $w.state, PRONTO_RUNTIME: (runtime-dir), SOPS_AGE_KEY: "AGE-SECRET-KEY-FAKE", KUBECONFIG: $w.publisher} { do { cd $w.app; ^$nu.current-exe --no-config-file -c (script $w $body) } | complete })
	assert ($e2e.exit_code != 0) $"a tenant's Node that retires the database was not refused: ($e2e.stdout)"
	assert (has $e2e.stderr "retire names Cluster/game-db") $e2e.stderr
	assert equal (writes $w) [] "refused before any write"
	rm -rf $w.dir
}

def test_a_tenants_objects_hand_their_life_to_no_one_and_hold_no_reserved_name [] {
	print "test a tenant's objects that set ownerReferences or finalizers, or are the publisher's account, the release's record or the root CA bundle (or seed a ConfigMap of those names), are refused..."
	let w = (tenant-world)
	let cases = [
		{obj: '{apiVersion: v1, kind: ConfigMap, metadata: {name: x, namespace: ns, ownerReferences: [{apiVersion: v1, kind: ServiceAccount, name: publisher, uid: "0"}]}}', says: "ConfigMap/x sets metadata.ownerReferences, which a tenant's release leaves to the engine"}
		{obj: '{apiVersion: v1, kind: ConfigMap, metadata: {name: x, namespace: ns, finalizers: [example.com/hold]}}', says: "ConfigMap/x sets metadata.finalizers"}
		{obj: '{apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: ns}, spec: {template: {metadata: {finalizers: [example.com/hold]}, spec: {containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Deployment/d sets spec.template.metadata.finalizers"}
		{obj: '{apiVersion: batch/v1, kind: CronJob, metadata: {name: j, namespace: ns}, spec: {jobTemplate: {spec: {template: {metadata: {finalizers: [example.com/hold]}}}}}}', says: "CronJob/j sets spec.jobTemplate.spec.template.metadata.finalizers"}
		{obj: '{apiVersion: external-secrets.io/v1, kind: ExternalSecret, metadata: {name: e, namespace: ns}, spec: {target: {template: {metadata: {finalizers: [example.com/hold]}}}}}', says: "ExternalSecret/e sets spec.target.template.metadata.finalizers"}
		{obj: '{apiVersion: external-secrets.io/v1, kind: ExternalSecret, metadata: {name: e, namespace: ns}, spec: {target: {manifest: {apiVersion: v1, kind: Secret}}}}', says: "ExternalSecret/e sets spec.target.manifest"}
		{obj: '{apiVersion: v1, kind: ConfigMap, metadata: {name: "--kubeconfig=/tmp/x", namespace: ns}}', says: "is not named as a Kubernetes resource is"}
		{obj: '{apiVersion: postgresql.cnpg.io/v1, kind: Cluster, metadata: {name: c, namespace: ns}, spec: {imageName: "127.0.0.1:5000/ns/db:17"}}', says: "Cluster/c runs 127.0.0.1:5000/ns/db:17, which is pinned by tag alone"}
		{obj: '{apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: ns}, spec: {template: {spec: {serviceAccountName: game-db, containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Deployment/d runs as the service account game-db, which a database's cluster owns"}
		{obj: '{apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: ns}, spec: {template: {metadata: {labels: {"cnpg.io/cluster": game-db}}, spec: {containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Deployment/d carries a label under cnpg.io/, which marks a database's own pods"}
		{obj: '{apiVersion: postgresql.cnpg.io/v1, kind: Cluster, metadata: {name: store, namespace: ns}, spec: {imageName: "127.0.0.1:5000/ns/db:17@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}', says: "Cluster/store is not named game-db: a tenant's database is the release's own"}
		{obj: '{apiVersion: postgresql.cnpg.io/v1, kind: Cluster, metadata: {name: store, namespace: ns}, spec: {imageName: "127.0.0.1:5000/ns/db:17@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}, {apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: ns}, spec: {template: {spec: {serviceAccountName: store, containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Deployment/d runs as the service account store, which a database's cluster owns"}
		{obj: '{apiVersion: batch/v1, kind: Job, metadata: {name: j, namespace: ns}, spec: {template: {spec: {serviceAccount: game-db, containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Job/j runs as the service account game-db, which a database's cluster owns"}
		{obj: '{apiVersion: batch/v1, kind: Job, metadata: {name: j, namespace: ns}, spec: {template: {metadata: {labels: {"cnpg.io/instanceRole": primary}}, spec: {containers: [{name: c, image: "127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", securityContext: {allowPrivilegeEscalation: false}}]}}}}', says: "Job/j carries a label under cnpg.io/, which marks a database's own pods"}
		{obj: '{apiVersion: v1, kind: ServiceAccount, metadata: {name: publisher, namespace: ns}}', says: "ServiceAccount/publisher is an object the provisioner or the engine owns"}
		{obj: '{apiVersion: v1, kind: ConfigMap, metadata: {name: pronto-release, namespace: ns}, immutable: true}', says: "ConfigMap/pronto-release is an object the provisioner or the engine owns"}
		{obj: '{apiVersion: v1, kind: ConfigMap, metadata: {name: kube-root-ca.crt, namespace: ns}}', says: "ConfigMap/kube-root-ca.crt is an object the provisioner or the engine owns"}
	]
	for c in $cases {
		let body = $"use ($engine_dir | path join tenant.nu); tenant check-objects [($c.obj)] {namespace: ns, name: game} [v1/ConfigMap v1/ServiceAccount apps/v1/Deployment batch/v1/Job batch/v1/CronJob external-secrets.io/v1/ExternalSecret postgresql.cnpg.io/v1/Cluster]"
		let r = (in-world $w -c $body)
		assert ($r.exit_code != 0) $"($c.obj) was not refused"
		assert (has $r.stderr $c.says) $"($c.obj): ($r.stderr)"
	}
	# a plain object of the same kinds passes
	let ok = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-objects [{apiVersion: v1, kind: ConfigMap, metadata: {name: x, namespace: ns}}] {namespace: ns} [v1/ConfigMap]")
	assert equal $ok.exit_code 0 $ok.stderr
	# a service's seed may not make the release's record
	let seed = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-seeds [{name: pronto-release, path: p, file: f}]")
	assert ($seed.exit_code != 0) "a seed named pronto-release was not refused"
	assert (has $seed.stderr "seed the ConfigMap pronto-release, which the provisioner or the engine owns") $seed.stderr
	rm -rf $w.dir
}

def test_a_tenants_secret_and_seed_names_are_resource_names_never_options [] {
	print "test a Secret or seed name in a tenant's Node that kubectl would parse as an option (a --kubeconfig names a credential plugin it runs) is refused before any kubectl call..."
	let w = (tenant-world)
	for node in ['{services: {a: {secrets: {K: "--kubeconfig=/tmp/x"}}}}' '{services: {a: {secrets: {K: "-n"}}}}' '{services: {a: {seed: {"--all": "f"}}}}' '{services: {a: {secrets: {K: "Upper"}}}}'] {
		let r = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-names ($node)")
		assert ($r.exit_code != 0) $"($node) was not refused"
		assert (has $r.stderr "not Kubernetes resource names") $"($node): ($r.stderr)"
	}
	let ok = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-names {services: {a: {secrets: {K: game-auth-secrets}, seed: {game-flags: f}}}}")
	assert equal $ok.exit_code 0 $ok.stderr
	rm -rf $w.dir
}

def test_a_tenants_own_vendored_engine_does_not_copy_the_schema_onto_itself [] {
	print "test an app that runs its own vendored engine (one real file) passes the schema check, and a node or node/schema folder that is a link is refused..."
	let w = (tenant-world)
	let vendored = ($w.dir | path join vendored)
	mkdir ($vendored | path join node)
	^cp -RL $"($engine_dir)/." ($vendored | path join node)
	let same = (in-world $w -c $"use ($vendored | path join node tenant.nu); tenant check-engine-copy '($vendored)'")
	assert equal $same.exit_code 0 $"($same.stdout)\n($same.stderr)"
	# a linked `node` leads the replacement into another checkout
	let other = ($w.dir | path join other)
	mkdir ($other | path join schema)
	^cp ($engine_dir | path join schema node.cue) ($other | path join schema node.cue)
	let app = ($w.app)
	^mv ($app | path join node) ($w.dir | path join node.moved)
	^ln -s $other ($app | path join node)
	let linked = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-engine-copy '($app)'")
	assert ($linked.exit_code != 0) "a linked node folder was not refused"
	assert (has $linked.stderr "the app's node is a symlink, not a folder") $linked.stderr
	rm -f ($app | path join node)
	^mv ($w.dir | path join node.moved) ($app | path join node)
	rm -rf ($app | path join node schema)
	^ln -s ($other | path join schema) ($app | path join node schema)
	let schema = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-engine-copy '($app)'")
	assert ($schema.exit_code != 0) "a linked node/schema folder was not refused"
	assert (has $schema.stderr "the app's node/schema is a symlink, not a folder") $schema.stderr
	rm -rf $w.dir
}

def test_a_tenants_schema_that_is_not_a_regular_file_is_refused_unread [] {
	print "test a tenant's node/schema/node.cue that is a FIFO or a link is refused as such, without being opened..."
	for kind in [fifo link] {
		let w = (tenant-world)
		let file = ($w.app | path join node schema node.cue)
		rm -f $file
		if $kind == "fifo" { ^mkfifo $file } else { ^ln -s ($engine_dir | path join schema node.cue) $file }
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"a ($kind) was not refused"
		assert (has $r.stderr "not a regular file") $"($kind): ($r.stderr)"
		rm -rf $w.dir
	}
}

def test_a_tenants_seed_is_a_file_git_tracks [] {
	print "test a tenant's seed source that git ignores (a .certs key) or does not track is refused, and a tracked regular file passes..."
	let w = (tenant-world)
	let app = $w.app
	mkdir ($app | path join .certs)
	mkdir ($app | path join data)
	"-----BEGIN PRIVATE KEY-----\n" | save -f ($app | path join .certs key.pem)
	".certs/\n" | save -f ($app | path join .gitignore)
	"{}\n" | save -f ($app | path join data untracked.json)
	"{}\n" | save -f ($app | path join data tracked.json)
	do { cd $app; ^git add .gitignore data/tracked.json; ^git -c user.name=t -c user.email=t@example.test commit -q -m seed } | complete | ignore
	let check = {|rel: string| in-world $w -c (script $w $"check-tracked-seeds '($app)' [{name: x, path: '($rel)', file: '($app | path join $rel)'}]") }
	for row in [{rel: ".certs/key.pem", why: "an ignored key"} {rel: "data/untracked.json", why: "an untracked file"}] {
		let r = (do $check $row.rel)
		assert ($r.exit_code != 0) $"($row.why) was not refused"
		assert (has $r.stderr "which is not a file git tracks") $"($row.why): ($r.stderr)"
	}
	let ok = (do $check "data/tracked.json")
	assert equal $ok.exit_code 0 $"($ok.stdout)\n($ok.stderr)"
	# a tracked file with content written over it is not what the commit holds
	"{\"changed\": true}\n" | save -f ($app | path join data tracked.json)
	let changed = (do $check "data/tracked.json")
	assert ($changed.exit_code != 0) "a modified tracked seed was not refused"
	assert (has $changed.stderr "which differs from the commit") $changed.stderr
	do { cd $app; ^git checkout -q -- data/tracked.json } | complete | ignore
	# a seed reached through a link: seed-files resolves it, so one inside the folder is judged as the file it names (here untracked, refused)
	# and one that leads out of the folder is refused
	^ln -s untracked.json ($app | path join data link-in.json)
	^ln -s /etc/hosts ($app | path join data link-out.json)
	let through = {|rel: string| in-world $w -c (script $w $"let seeds = \(seed-files '($app)' {services: {a: {seed: {x: '($rel)'}}}}\); check-tracked-seeds '($app)' $seeds") }
	let inside = (do $through "data/link-in.json")
	assert ($inside.exit_code != 0) "a link to an untracked file was not refused"
	assert (has $inside.stderr "which is not a file git tracks") $inside.stderr
	let outside = (do $through "data/link-out.json")
	assert ($outside.exit_code != 0) "a link out of the folder was not refused"
	assert (has $outside.stderr "resolves outside") $outside.stderr
	rm -rf $w.dir
}

def test_a_tenants_build_targets_are_names_and_buildx_may_be_dockers_own [] {
	print "test a tenant's build target that is not a service name never reaches buildx, and Docker's own buildx plugin is used when none is on the PATH..."
	let w = (tenant-world)
	let body = $"let app_info = \(runtime resolve-app '($w.app)'\); let node = \(render node-config $app_info.cue_path '' --tenant ($tenant_ns) --host ($tenant_host)\); use ($engine_dir | path join push.nu); push tenant-images $app_info.dir $node ['--help'] release ''"
	let r = (in-world $w -c (script $w $body))
	assert ($r.exit_code != 0) "an option-shaped target was not refused"
	assert (has $r.stderr "build targets are service names") $r.stderr
	assert (not ($w.dir | path join docker.log | path exists) or not (open --raw ($w.dir | path join docker.log) | str contains "buildx")) "buildx was run"
	# Docker's own plugin folder, with no buildx on the PATH
	let plugins = ($w.dir | path join plugins)
	mkdir $plugins
	"#!/bin/sh\nexit 0\n" | save -f ($plugins | path join docker-buildx)
	^chmod +x ($plugins | path join docker-buildx)
	let found = (with-env {PATH: ["/usr/bin" "/bin"], PRONTO_DOCKER_PLUGIN_DIRS: $plugins} { ^$nu.current-exe --no-config-file -c $"use ($engine_dir | path join push.nu); push buildx-binary" } | complete)
	assert equal $found.exit_code 0 $found.stderr
	assert equal ($found.stdout | str trim) ($plugins | path join docker-buildx)
	rm -rf $w.dir
}

def test_a_tenants_env_link_is_refused_and_never_opened [] {
	print "test a tenant's .env that is a link is refused as a link and its target is never read..."
	let w = (tenant-world)
	"COMPOSE_FILE=/etc/passwd\n" | save -f ($w.dir | path join target.env)
	^ln -s ($w.dir | path join target.env) ($w.app | path join .env)
	let r = (in-world $w -c $"use ($engine_dir | path join tenant.nu); tenant check-compose-sources '($w.app)'")
	assert ($r.exit_code != 0) "a linked .env was not refused"
	assert (has $r.stderr ".env is a symlink, not a regular file") $r.stderr
	assert (not (has $r.stderr "COMPOSE_")) $"the link's target was read: ($r.stderr)"
	rm -rf $w.dir
}

def test_a_tenants_push_rights_are_only_what_its_path_uses [] {
	print "test a tenant's check with --build asks for no Service read in the gateway's namespace (there is no door check), and a live release asks for it..."
	let w = (tenant-world)
	"get services -n envoy-gateway-system\nlist services -n envoy-gateway-system" | save -f ($w.state | path join auth_deny)
	let b = (tenant-release $w --check --build)
	assert equal $b.exit_code 0 $"($b.stdout)\n($b.stderr)"
	assert (not (calls-by $w push.kubeconfig | any {|c| $c | str contains "envoy-gateway-system" })) "a check asked of the gateway's namespace"
	let live = (tenant-release $w)
	assert ($live.exit_code != 0) "a live release without the Service reads was not refused"
	assert (has $live.stderr "the push identity may not get services in envoy-gateway-system") $live.stderr
	assert equal (writes $w) []
	rm -rf $w.dir
	# the registry's Leases: only create, get, patch and delete are asked (list and update are the collector's), so a Role without them passes
	let l = (tenant-world)
	"list leases.coordination.k8s.io\nupdate leases.coordination.k8s.io" | save -f ($l.state | path join auth_deny)
	let ok = (tenant-release $l)
	assert equal $ok.exit_code 0 $"($ok.stdout)\n($ok.stderr)"
	let asked = (calls-by $l push.kubeconfig | where {|c| ($c | str starts-with "auth can-i") and ($c | str contains "leases") })
	assert equal ($asked | each {|c| $c | split row " " | get 2 } | uniq | sort) [create delete get patch]
	rm -rf $l.dir
	# the gateway's port-forward is a live release's too
	let f = (tenant-world)
	"create pods --subresource=portforward -n envoy-gateway-system" | save -f ($f.state | path join auth_deny)
	let c = (tenant-release $f --check --build)
	assert equal $c.exit_code 0 $"($c.stdout)\n($c.stderr)"
	rm -rf $f.dir
	# forwarding to a Service finds a pod behind it: a live off-cluster release asks to read the gateway's pods, and a check does not; the
	# registry's pod is found by listing, which every path that builds asks
	for row in [
		{deny: "get pods -n envoy-gateway-system", args: [], says: "the push identity may not get pods in envoy-gateway-system: it needs the Role studio-builder-gateway", passes_check: true}
		{deny: "list pods -n pronto-registry", args: [--check --build], says: "the push identity may not list pods in pronto-registry: it needs the Role studio-builder-push", passes_check: false}
	] {
		let p = (tenant-world)
		$row.deny | save -f ($p.state | path join auth_deny)
		let live = (tenant-release $p ...$row.args)
		assert ($live.exit_code != 0) $"($row.deny) was not refused"
		assert (has $live.stderr $row.says) $live.stderr
		assert equal (writes $p) []
		if $row.passes_check {
			let ck = (tenant-release $p --check --build)
			assert equal $ck.exit_code 0 $"a check asked for the gateway's pods: ($ck.stdout)\n($ck.stderr)"
		}
		rm -rf $p.dir
	}
}

def test_a_tenants_origin_and_preview_are_the_operators [] {
	print "test a tenant's release whose Node names an origin of its own, or a preview, is refused before a client is registered or anything is written..."
	for row in [
		{edit: {|s| $s | str replace 'hosts: production: *"game.bsoneca.com"' "origin: \"https://evil.example\"\n\thosts: production: *\"game.bsoneca.com\"" }, says: "a tenant's origin is https://game-game.example.com, the operator's host, not the Node's https://evil.example"}
		{edit: {|s| $s | str replace 'preview: _preview' 'preview: "rc"' }, says: "a tenant's release is never a preview: Node.preview must be empty"}
	] {
		let w = (tenant-world)
		let file = ($w.app | path join release.cue)
		(open --raw $file | do $row.edit $in) | save -f $file
		let r = (tenant-release $w)
		assert ($r.exit_code != 0) $"($row.says) was not refused"
		assert (has $r.stderr $row.says) $r.stderr
		assert equal (writes $w) []
		assert (not ($w.dir | path join deno.log | path exists)) "no client was registered"
		rm -rf $w.dir
	}
}

def test_a_tenants_containers_say_allow_privilege_escalation_false [] {
	print "test a tenant's containers that leave allowPrivilegeEscalation unset are made to say false before they are applied, and one that says true is refused..."
	let w = (tenant-world)
	let r = (tenant-release $w)
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	let containers = (open --raw ($w.state | path join all_objects.jsonl) | lines | each {|l| $l | from json } | flatten | where kind in [Deployment Job] | each {|d| $d.spec.template.spec.containers | append ($d.spec.template.spec.initContainers? | default []) } | flatten)
	assert ($containers | is-not-empty) "the release applied no container"
	assert ($containers | all {|c| ($c.securityContext?.allowPrivilegeEscalation? | default null) == false }) $"a container left it unset: ($containers | to nuon)"
	# the validator: unset is refused, true is refused, false passes; the hardening sets the unset one and leaves a true one to be refused
	let body = $"use ($engine_dir | path join tenant.nu); let ns = 'ns'; let node = {namespace: $ns}; let mk = {|sc| {apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: $ns}, spec: {template: {spec: {containers: [{name: c, image: '127.0.0.1:5000/ns/x@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', securityContext: $sc}]}}}} }; let kinds = [apps/v1/Deployment]; let results = [{} {allowPrivilegeEscalation: true} {allowPrivilegeEscalation: false}] | each {|sc| let objs = [\(do $mk $sc\)]; let raw = \(try { tenant check-objects $objs $node $kinds; 'ok' } catch {|e| 'refused' }\); let hard = \(try { tenant check-objects \(tenant harden-objects $objs\) $node $kinds; 'ok' } catch {|e| 'refused' }\); {raw: $raw, hardened: $hard} }; $results | to json --raw"
	let v = (in-world $w -c $body)
	assert equal $v.exit_code 0 $v.stderr
	assert equal ($v.stdout | from json) [{raw: "refused", hardened: "ok"} {raw: "refused", hardened: "refused"} {raw: "ok", hardened: "ok"}]
	rm -rf $w.dir
}

def test_a_tenants_compose_and_bake_see_only_an_allowlisted_environment [] {
	print "test a tenant's compose resolution and bake run with an explicit environment allowlist: a credential in the caller's environment reaches neither, unless the caller lists it..."
	let w = (tenant-world)
	let r = (with-env {PRONTO_TEST_CREDENTIAL: "hunter2"} { tenant-release $w })
	assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
	for f in [compose_env staged_compose_env bake_env] {
		let seen = (open --raw ($w.dir | path join $f))
		assert (not ($seen | str contains "PRONTO_TEST_CREDENTIAL")) $"($f) saw the caller's credential"
		assert (not ($seen | str contains "SOPS_AGE_KEY")) $"($f) saw the caller's key"
		assert (not ($seen | str contains "KUBECONFIG")) $"($f) saw the caller's KUBECONFIG"
		assert ($seen | str contains "PATH=") $"($f) lost its PATH"
	}
	rm -rf $w.dir
	let listed = (tenant-world)
	let l = (with-env {PRONTO_TEST_CREDENTIAL: "hunter2", PRONTO_TENANT_ENV_ALLOW: "PRONTO_TEST_CREDENTIAL"} { tenant-release $listed })
	assert equal $l.exit_code 0 $"($l.stdout)\n($l.stderr)"
	assert ((open --raw ($listed.dir | path join compose_env)) | str contains "PRONTO_TEST_CREDENTIAL=hunter2") "a variable the caller lists is passed"
	rm -rf $listed.dir
}
