# release.nu: release@k8s for a pronto app on the Contabo node (README.md, "The node release engine").
# It replaces upstream's k8s/release.nu `main` for the node's existing k3s: the images are built in
# Cloud Build (build.nu) and pulled by the node from Artifact Registry, the manifests are upstream's own
# (#BuildManifests) patched by the app's Node (schema/node.cue), and the order is upstream's, with the
# engine's extra steps marked below. It runs on the Mac, never on the node; kubectl reaches the node
# over an ssh tunnel (tunnel.nu).
#
#   nu node/release.nu [--app <dir>] [--preview <name>] [--check] [--delete]
#
# The steps (design section 3), each a function below:
#   0  the app, the tunnel, a kubeconfig pinned to the node's context
#   1  preflight: the operators' versions, CRDs, GatewayClass; refusals (airlock, TRUSTED_JWKS, a folder
#      that is not the app's name, a preview in the release's namespace)
#   2  build: Cloud Build, an unchanged service not rebuilt                       (none with --check)
#   3  release data, and CUE's render
#   4  the Namespace; a server dry run of the rest, which stops the release on a rejection
#   5  SOPS secrets, the OIDC secret                                                              (engine)
#   6  every object but the Deployments and Jobs
#   8  wait for the database's primary on its image
#   9  the Jobs, by jobOrder
#  10  hooks.afterJobs                                                                            (engine)
#  11  the database's roles reconciled, the service token
#  12  the Deployments (crud always rolls), their rollouts
#  13  the Dapr sidecar of every pod
#  14  retire                                                                                     (engine)
#  15  the ConfigMap pronto-release                                                               (engine)
# A failure at or after step 6 puts back the Deployments it changed (rollback.nu). `--check` is steps
# 0 to 4 with every write replaced by a server dry run.

use runtime.nu
use render.nu
use tunnel.nu
use rollback.nu
use build.nu [push-images stamp]

# The operators the preflight reads: where each runs and the image tag that states its version.
const operator_pods = [
	{operator: dapr, namespace: dapr-system, deployment: dapr-operator}
	{operator: cnpg, namespace: cnpg-system, deployment: cnpg-controller-manager}
	{operator: externalSecrets, namespace: external-secrets, deployment: external-secrets}
	{operator: envoyGateway, namespace: envoy-gateway-system, deployment: envoy-gateway}
]

# The CRDs an app's render needs, as upstream's release checks them for GKE (and the backups' store).
const crds = [clusters.postgresql.cnpg.io externalsecrets.external-secrets.io configurations.dapr.io gateways.gateway.networking.k8s.io backendtrafficpolicies.gateway.envoyproxy.io]

# kubectl, failing with its own message; what it prints is printed.
def --wrapped kubectl-ok [...args: string]: any -> nothing {
	let input = $in
	let r = ($input | ^kubectl ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl ($args | first 3 | str join ' '): ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-not-empty) { print ($r.stdout | str trim --right) }
}

# kubectl's JSON answer.
def --wrapped kubectl-json [...args: string]: nothing -> any {
	let r = (^kubectl ...$args -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl ($args | first 3 | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# Objects as one List, which `kubectl apply -f -` takes.
def as-list [objects: list]: nothing -> string {
	{apiVersion: "v1", kind: "List", items: $objects} | to json
}

def of-kind [objects: list, kind: string]: nothing -> list { $objects | where kind == $kind }

# --- 1. preflight ---

# The image tag that states an operator's version, `v` dropped.
def image-version [image: string]: nothing -> string {
	$image | split row "@" | first | split row ":" | last | str replace -r "^v" ""
}

# The operators running on the node must be the versions the schema was written for (#Operators):
# a mismatch refuses before any write. Reads only.
export def check-operators [node: record] {
	let wrong = ($operator_pods | each {|o|
		let want = ($node.operators | get $o.operator)
		let d = (kubectl-json get deployment $o.deployment -n $o.namespace)
		let have = (image-version ($d.spec.template.spec.containers | first | get image))
		if $have != $want { $"($o.operator): the node runs ($have), the engine's schema is written for ($want)" }
	} | compact)
	if ($wrong | is-not-empty) { error make {msg: $"operator versions differ from #Operators:\n($wrong | str join "\n")\nbumping one is a change of the engine's pin: node/engine/schema/node.cue"} }
	kubectl-ok get crd ...$crds -o name
	if ($node.backups? | default null) != null { kubectl-ok get crd objectstores.barmancloud.cnpg.io -o name }
	let gc = (kubectl-json get gatewayclass $node.environment.gatewayClassName)
	let accepted = ($gc.status?.conditions? | default [] | any {|c| $c.type == "Accepted" and $c.status == "True" })
	if not $accepted { error make {msg: $"GatewayClass ($node.environment.gatewayClassName) is not Accepted"} }
}

# Why this release refuses before anything is built or written.
export def refuse [app_info: record, node: record, meta: record, compose: record, has_render: bool] {
	if $node.name != $app_info.name { error make {msg: $"the app's folder is ($app_info.name), but its Node is named ($node.name)"} }
	if $meta.name != $node.name { error make {msg: $"App.name is ($meta.name), but Node.name is ($node.name)"} }
	if $meta.namespace != $node.namespace { error make {msg: $"App.namespace is ($meta.namespace), but Node.namespace is ($node.namespace): set it to Node.namespace"} }
	if $meta.type != "pronto" { error make {msg: $"Only Pronto applications are supported for k8s release: ($app_info.name)"} }
	if ($node.preview | is-not-empty) and $node.namespace == $node.name { error make {msg: $"the preview ($node.preview) would release into the production namespace ($node.name)"} }
	let refused = (render refusals $compose)
	if ($refused | is-not-empty) { error make {msg: $"($app_info.cue_path): ($refused | str join '; ')"} }
	# The caddy image proxies its SSR routes to `render` whenever the app builds one.
	let compose_render = ("render" in ($compose.services | columns))
	if $compose_render != $has_render {
		error make {msg: $"($app_info.cue_path): render.enabled is ($has_render) but the app's compose project (if $compose_render { 'defines' } else { 'lacks' }) a render service"}
	}
}

# --- 5. secrets ---

# The age key SOPS decrypts with: the environment's, else the Mac's Keychain.
def age-key []: nothing -> string {
	if ($env.SOPS_AGE_KEY? | is-not-empty) { return $env.SOPS_AGE_KEY }
	let key = (do { ^security find-generic-password -s pronto-sops-age -w } | complete)
	if $key.exit_code != 0 { error make {msg: "no Keychain item pronto-sops-age on this Mac (and no SOPS_AGE_KEY): the node's secrets cannot be decrypted"} }
	$key.stdout | str trim
}

# The SOPS file's Secrets, in memory, each in `namespace` (a preview's is not production's).
export def decrypt-secrets [file: string, namespace: string]: nothing -> list {
	let r = (with-env {SOPS_AGE_KEY: (age-key)} { ^sops -d $file | complete })
	if $r.exit_code != 0 { error make {msg: $"sops -d ($file): ($r.stderr | str trim)"} }
	$r.stdout | split row --regex '(?m)^---\s*$' | where {|d| $d | str trim | is-not-empty }
		| each {|d| $d | from yaml | upsert metadata.namespace $namespace }
}

# The file the app's secrets are in, or null.
def secrets-file [app_dir: string, node: record]: nothing -> any {
	let f = ($app_dir | path join ($node.secrets? | default "secrets.metal.enc.yaml"))
	if ($f | path exists) { $f } else if ($node.secrets? | is-not-empty) { error make {msg: $"Node.secrets names ($node.secrets), which is not in ($app_dir)"} } else { null }
}

# Applies the Secrets server-side as pronto-sops, so one made by hand before is taken over.
def apply-secrets [secrets: list] {
	if ($secrets | is-empty) { return }
	print $"node: (stamp) applying ($secrets | length) secret\(s\) from SOPS"
	as-list $secrets | kubectl-ok apply --server-side --force-conflicts --field-manager=pronto-sops -f -
}

# `<name>-oidc`, as upstream's auth-provider-secret.
def oidc-secret [name: string, namespace: string, values: record]: nothing -> record {
	{
		apiVersion: "v1", kind: "Secret"
		metadata: {name: $"($name)-oidc", namespace: $namespace}
		type: "Opaque"
		data: ($values | items {|key, value| [$key ($value | into string | encode base64)] } | into record)
	}
}

# --- helpers of the flow ---

# The kubeconfig of the node's context, flattened, so every kubectl below is the node's whatever the current one.
def pin-kubeconfig [context: string]: nothing -> string {
	let kubeconfig = (mktemp -t kubeconfig.XXXXXX | str trim)
	let r = (^kubectl config view --minify --flatten --context $context | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl config view --context ($context): ($r.stderr | str trim)"} }
	$r.stdout | save -f $kubeconfig
	$kubeconfig
}

# The Namespace's objects and the rest, from the render.
def namespace-split [objects: list]: nothing -> record {
	{namespace: (of-kind $objects Namespace), rest: ($objects | where kind != Namespace)}
}

# A server dry run of the objects, which stops the release on a rejection. Where the namespace does not
# exist yet (a first release), they are asked in `default`: admission reads the objects, not where they go.
export def dry-run [objects: list, namespace: string] {
	let there = ((^kubectl get namespace $namespace | complete).exit_code == 0)
	let items = if $there { $objects } else { $objects | each {|o| if $o.kind == "Namespace" { $o } else { $o | upsert metadata.namespace "default" } } }
	if not $there { print $"node: (stamp) namespace ($namespace) does not exist yet: the server dry run asks the objects in default" }
	as-list $items | kubectl-ok apply --dry-run=server -f -
}

# Waits for the database's primary to run the image the release names and be ready: the cluster's
# status names a new image as soon as it starts rolling onto it, and Ready stays true through the restart.
def wait-primary [app: string, namespace: string, image: string, seconds: int] {
	print $"node: (stamp) waiting for CloudNativePG cluster ($app)-db in ($namespace) on ($image)"
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let primary = (kubectl-json get pods -n $namespace -l $"cnpg.io/cluster=($app)-db,cnpg.io/instanceRole=primary" | get items
			| where {|p| $p.metadata.deletionTimestamp? == null and ($p.spec.containers | where name == "postgres" | first | get image) == $image and ($p.status.conditions? | default [] | any {|c| $c.type == "Ready" and $c.status == "True" }) })
		if ($primary | is-not-empty) { return }
		if (date now) > $deadline { error make {msg: $"cluster/($app)-db has no ready primary on ($image)"} }
		sleep 3sec
	}
}

# The commands of hooks.afterJobs, in the app's folder, told where the release is.
export def run-hooks [hooks: list, app_dir: string, context: string, namespace: string, app: string] {
	for h in $hooks {
		print $"node: (stamp) hook: ($h | str join ' ')"
		let r = (with-env {NODE_CONTEXT: $context, NODE_NAMESPACE: $namespace, NODE_APP: $app} { do { cd $app_dir; ^$h.0 ...($h | skip 1) } | complete })
		if ($r.stdout | str trim | is-not-empty) { print ($r.stdout | str trim --right) }
		if $r.exit_code != 0 { error make {msg: $"hook ($h | str join ' ') failed: ($r.stderr | str trim)"} }
	}
}

# The database's roles, reconciled by CloudNativePG: crud logs in as authenticator, whose memberships
# name the schema's token roles, which the Jobs create. An attempt made before they stood gave up and
# is made again only when the Cluster changes, so the release changes it.
def wait-roles [app: string, namespace: string, seconds: int] {
	let cluster = $"cluster.postgresql.cnpg.io/($app)-db"
	kubectl-ok annotate $cluster -n $namespace --overwrite $"pronto.dev/roles-restated=(date now | into int)"
	print $"node: (stamp) waiting for ($cluster) to reconcile its managed roles"
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let roles = (kubectl-json get $cluster -n $namespace | get status.managedRolesStatus? | default {})
		if (runtime roles-reconciled $roles) { return }
		if (date now) > $deadline { error make {msg: $"($cluster) has not reconciled its managed roles: ($roles | to nuon)"} }
		sleep 3sec
	}
}

# The service role's token, for the runtime services that read one: signed with the stack's own secret.
def apply-service-token [app: string, namespace: string] {
	kubectl-ok wait --for=condition=Ready $"externalSecret/($app)-auth-secrets" -n $namespace --timeout=120s
	let secret = (kubectl-json get secret $"($app)-auth-secrets" -n $namespace | get data.PGRST_JWT_SECRET | decode base64 | decode)
	let token = ($secret | ^deno run --no-config (runtime dir | path join k8s service-token.ts) | str trim)
	{apiVersion: "v1", kind: "Secret", metadata: {name: $"($app)-service-token", namespace: $namespace}, data: {SERVICE_JWT: ($token | encode base64)}}
		| to json | kubectl-ok apply --server-side --field-manager=pronto-runtime -f -
}

# Every pod of the release's components runs with its Dapr sidecar: one the injector let through bare is a failed release.
def check-daprd [app: string, namespace: string, components: list<string>] {
	let bare = (kubectl-json get pods -n $namespace -l $"app.kubernetes.io/name=($app),app.kubernetes.io/component in \(($components | str join ',')\)" --field-selector=status.phase=Running | get items
		| where {|p| $p.metadata.deletionTimestamp? == null and not ($p.spec.containers.name | any {|c| $c == "daprd" }) }
		| get metadata.name)
	if ($bare | is-not-empty) { error make {msg: $"Pods running without their Dapr sidecar: ($bare | str join ', ')"} }
}

# The record of what runs: release-cron's `serving` reads `sha` from it.
export def record-release [app_dir: string, node: record, pushed: record] {
	let git_root = (do { cd $app_dir; ^git rev-parse --show-toplevel } | complete)
	let sha = (do { cd $app_dir; ^git rev-parse HEAD } | complete | if $in.exit_code == 0 { $in.stdout | str trim } else { "" })
	let pin = if $git_root.exit_code == 0 { $git_root.stdout | str trim | path join .github node-engine.pin } else { "" }
	let engine = if ($pin | is-not-empty) and ($pin | path exists) { open --raw $pin | str trim } else { "" }
	let images = ($pushed | items {|svc, p| [$svc $"($p.tag)@($p.digest)"] } | into record)
	{
		apiVersion: "v1", kind: "ConfigMap"
		metadata: {name: "pronto-release", namespace: $node.namespace}
		data: {sha: $sha, pin: (runtime version), enginePin: $engine, images: ($images | to json --raw), at: (date now | format date "%Y-%m-%dT%H:%M:%S%z")}
	} | to json | kubectl-ok apply -f -
}

# --- the release ---

# Builds the images in Cloud Build and answers what was pushed by service: {tag, digest}, the database's tag being its Postgres major.
def build-images [app_info: record, node: record, compose: record, services: list<string>]: nothing -> record {
	let plan = ({project: $node.registry.project, registry: $node.environment.registry} | merge (if ($node.preview | is-empty) { {} } else { {preview: $node.preview} }))
	let text = (do { cd ($app_info.dir | path expand); ^docker compose --profile "*" config } | complete)
	if $text.exit_code != 0 { error make {msg: $"docker compose config failed in ($app_info.dir): ($text.stderr | str trim)"} }
	let override = (runtime release-tree $text.stdout)
	let pushed = (push-images $app_info.dir $plan $app_info.name $services --override $override)
	$pushed | items {|svc, p|
		let tag = if $svc == "database" { render database-tag $"($node.environment.registry)/($app_info.name)-($svc)" $p.digest } else { $p.tag }
		[$svc {tag: $tag, digest: $p.digest}]
	} | into record
}

# Everything that is read before anything is built or written: the operators, the SOPS file, the
# backups' credentials. Answers the file's Secrets, decrypted, for the release to apply.
export def preflight [app_info: record, node: record]: nothing -> list {
	check-operators $node
	let secrets_file = (secrets-file $app_info.dir $node)
	let secrets = if $secrets_file == null { [] } else { decrypt-secrets $secrets_file $node.namespace }
	let backups_on = (($node.backups? | default null) != null and ($node.preview | is-empty))
	if $backups_on and ($secrets | where {|s| $s.kind == "Secret" and $s.metadata.name == $node.backups.credentials } | is-empty) {
		let live = ((^kubectl get secret $node.backups.credentials -n $node.namespace | complete).exit_code == 0)
		if not $live { error make {msg: $"Node.backups reads the Secret ($node.backups.credentials), which is neither in the SOPS file nor in ($node.namespace)"} }
	}
	$secrets
}

# The release itself, with the node reachable and the kubeconfig pinned, over what `preflight`
# answered and what was pushed (by service: {tag, digest}; placeholders for a check).
export def release-app [app_info: record, node: record, meta: record, compose: record, facts: record, secrets: list, pushed: record, --check] {
	let app = $app_info.name
	let ns = $node.namespace
	# 3. data and render
	let data = (render release-data $app_info.dir $compose $facts $pushed)
	let objects = (render objects $app_info.cue_path $data $node.preview)
	let parts = (namespace-split $objects)
	let stray = ($objects | where kind == Job | get metadata.name | where {|n| $n not-in ($node.jobOrder | each {|j| $"($app)-($j)" }) })
	if ($stray | is-not-empty) { error make {msg: $"Jobs ($stray | str join ', ') are not in jobOrder"} }
	# 4. the namespace, and the server's word on the rest
	if $check {
		print $"node: (stamp) check: server dry run of ($objects | length) objects in ($ns)"
		dry-run $objects $ns
		print $"node: (stamp) check passed: nothing was written"
		return
	}
	as-list $parts.namespace | kubectl-ok apply -f -
	dry-run $parts.rest $ns
	# 5. secrets
	apply-secrets $secrets
	let oidc = (render oidc-secrets $compose $app_info.dir)
	if ($oidc | is-not-empty) {
		oidc-secret $app $ns $oidc | to json | kubectl-ok apply --server-side --field-manager=pronto-oidc -f -
	}
	# 6. everything but the Deployments and Jobs, after the Deployments' revisions are recorded
	let deployments = (of-kind $objects Deployment)
	let jobs = (of-kind $objects Job)
	let before = (rollback revisions ($deployments | get metadata.name) $ns)
	try {
		print $"node: (stamp) applying manifests for ($app)"
		as-list ($objects | where {|o| $o.kind not-in [Deployment Job Namespace] }) | kubectl-ok apply -f -
		# 8. the database, on its image
		let db_image = (of-kind $objects Cluster | first | get spec.imageName)
		wait-primary $app $ns $db_image $node.waits.primary
		# 9. the schema Jobs, in jobOrder
		for j in $node.jobOrder {
			let job = ($jobs | where {|o| $o.metadata.name == $"($app)-($j)" })
			if ($job | is-not-empty) { runtime run-job ($job | first | to json) $"($app)-($j)" $ns --timeout-s $node.waits.job }
		}
		# 10. hooks
		run-hooks $node.hooks.afterJobs $app_info.dir $node.context $ns $app
		# 11. roles, the service token
		wait-roles $app $ns $node.waits.primary
		let runtime_services = (runtime runtime-services $compose)
		if ($runtime_services | values | any {|r| $r.serviceToken }) { apply-service-token $app $ns }
		# 12. the Deployments: crud rolls after the schema Jobs even with an unchanged image
		let rolled = ($deployments | each {|d| if $d.metadata.name == $"($app)-crud" { runtime fresh-schema-runtime ($d | to json) | from yaml } else { $d } })
		as-list $rolled | kubectl-ok apply -f -
		let runtime_names = ($runtime_services | columns)
		for name in $runtime_names {
			kubectl-ok rollout status $"deployment/($app)-($name)" -n $ns $"--timeout=($node.waits.rollout * 5)s"
		}
		let components = ["crud" "electric" "auth" "caddy"] | append ($runtime_names | where {|s| $s in ["ticker" "rclone-s3" "imgproxy"] }) | append (if $meta.render.enabled { ["render"] } else { [] })
		for d in ($components | each {|c| $"deployment/($app)-($c)" }) {
			print $"node: (stamp) waiting for ($d) rollout"
			kubectl-ok rollout status $d -n $ns $"--timeout=($node.waits.rollout)s"
		}
		# 13. the mesh is intrinsic: a pod without its sidecar is a failed release
		check-daprd $app $ns $components
	} catch {|e|
		print -e $"node: (stamp) the release failed: ($e.msg)"
		let back = (try { rollback undo $before $ns } catch {|r| print -e $"node: rollback failed: ($r.msg)"; [] })
		error make {msg: ($e.msg + (if ($back | is-not-empty) { $"; rolled back ($back | str join ', ')" } else { "" }))}
	}
	# 14. retire what an earlier release left
	for r in $node.retire {
		kubectl-ok delete $r.kind $r.name -n $ns --ignore-not-found
	}
	# 15. record
	record-release $app_info.dir $node $pushed
	print $"\n[SUCCESS] Released ($app) to ($node.context): https://($node.host)/"
}

# Releases the app in the folder (or `--app`), to production or `--preview <name>`.
def main [
	--app: string              # the app's directory, or its name in the monorepo
	--preview: string = ""     # the preview's name: its own namespace beside the release's
	--check                    # steps 0 to 4 only, every write a server dry run, nothing built
	--delete                   # delete the preview's namespace (a preview only)
	--schema-from: string = "" # the preview copy of a database (not in this engine yet)
] {
	$env.GCP_T0 = (date now)
	if ($schema_from | is-not-empty) { error make {msg: "--schema-from is not in this engine yet: a preview starts with an empty database"} }
	let app_info = (runtime resolve-app $app)
	let node = (render node-config $app_info.cue_path $preview)
	if $delete {
		if ($preview | is-empty) or $node.namespace == $node.name { error make {msg: $"--delete removes a preview's namespace; ($node.namespace) is the release's"} }
	}
	let compose = if $delete { {services: {}} } else { render compose-config $app_info.dir }
	let meta = (render app-meta $app_info.cue_path $preview)
	if not $delete { refuse $app_info $node $meta $compose $meta.render.enabled }
	let facts = if $delete { {} } else { render facts $app_info.dir }
	tunnel with-tunnel $node.api {||
		let kubeconfig = (pin-kubeconfig $node.context)
		try {
			with-env {KUBECONFIG: $kubeconfig} {
				if $delete {
					print $"node: (stamp) deleting namespace ($node.namespace)"
					kubectl-ok delete namespace $node.namespace --ignore-not-found --wait=true
				} else {
					let secrets = (preflight $app_info $node)
					let services = (render build-services $compose $meta.render.enabled)
					# 2. build, or placeholders for a check
					let pushed = if $check {
						render placeholder-pushed $services (if ($node.preview | is-empty) { "release" } else { $node.preview })
					} else {
						print $"node: (stamp) building ($services | str join ', ') for ($app_info.name)"
						build-images $app_info $node $compose $services
					}
					release-app $app_info $node $meta $compose $facts $secrets $pushed --check=$check
				}
			}
		} finally {
			rm -f $kubeconfig
		}
	}
}
