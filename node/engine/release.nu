# release.nu: release@k8s for a pronto app on the Contabo node (README.md, "The node release engine").
# It replaces upstream's k8s/release.nu `main` for the node's existing k3s: the images are built on the
# node's own buildkitd and pushed to the node's registry (push.nu), which is where the node pulls them
# from (127.0.0.1:5000), the manifests are upstream's own
# (#BuildManifests) patched by the app's Node (schema/node.cue), and the order is upstream's, with the
# engine's extra steps marked below. It runs on the Mac, never on the node; kubectl reaches the node
# over an ssh tunnel (tunnel.nu).
#
#   nu node/release.nu [--app <dir>] [--preview <name>] [--check [--build]] [--delete]
#
# The steps (design section 3), each a function below:
#   0  the app, the tunnel, a kubeconfig pinned to the node's context
#   1  preflight: the operators' versions, CRDs, GatewayClass; refusals (airlock, TRUSTED_JWKS, a folder
#      that is not the app's name, a preview in the release's namespace)
#   2  build: the node's buildkitd, pushed to the node's registry                 (none with --check)
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
#  16  prune: the node registry's garbage collection, a warning when it fails                     (engine)
# A failure at or after step 6 puts back the Deployments it changed (rollback.nu). `--check` is steps
# 0 to 4 with every write replaced by a server dry run; `--check --build` also builds and pushes under
# the tag `check` (registry writes only, never the cluster).

use runtime.nu
use runtime.nu [validated_pins]
use render.nu
use tunnel.nu
use rollback.nu
use build.nu [stamp]
use push.nu
use registry.nu

# The operators the preflight reads: where each runs and the image tag that states its version.
const operator_pods = [
	{operator: dapr, namespace: dapr-system, deployment: dapr-operator}
	{operator: cnpg, namespace: cnpg-system, deployment: cnpg-controller-manager}
	{operator: externalSecrets, namespace: external-secrets, deployment: external-secrets}
	{operator: envoyGateway, namespace: envoy-gateway-system, deployment: envoy-gateway}
	{operator: barmanCloud, namespace: cnpg-system, deployment: barman-cloud}
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
	let bundle = (kubectl-json get crd gateways.gateway.networking.k8s.io | get metadata.annotations."gateway.networking.k8s.io/bundle-version"? | default "" | str replace -r "^v" "")
	if $bundle != $node.operators.gatewayAPI { error make {msg: $"the node's Gateway API CRDs are ($bundle), the engine's schema is written for ($node.operators.gatewayAPI)"} }
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
export def decrypt-secrets [file: string, namespace: string, --without: list<string> = []]: nothing -> list {
	let r = (with-env {SOPS_AGE_KEY: (age-key)} { ^sops -d $file | complete })
	if $r.exit_code != 0 { error make {msg: $"sops -d ($file): ($r.stderr | str trim)"} }
	$r.stdout | split row --regex '(?m)^---\s*$' | where {|d| $d | str trim | is-not-empty }
		| each {|d| $d | from yaml }
		| where {|d| $d.kind? == "Secret" and ($d.metadata.name not-in $without) }
		| each {|d| $d | upsert metadata.namespace $namespace }
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
	# A Job a release left holds its template immutably: the new one is asked under a name of its own, created, not applied.
	let jobs = ($items | where kind == Job | each {|j| $j | upsert metadata.name $"($j.metadata.name)-dryrun" })
	as-list ($items | where kind != Job) | kubectl-ok apply --dry-run=server -f -
	if ($jobs | is-not-empty) { as-list $jobs | kubectl-ok create --dry-run=server -f - }
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

# The record of what runs: `sha` (what `--serving` prints, empty for a tree that was not a commit), and `verified`, empty
# until the app's cd has checked the public site for it (`--verified`).
export def record-release [app_dir: string, node: record, pushed: record] {
	let git_root = (do { cd $app_dir; ^git rev-parse --show-toplevel } | complete)
	# The commit is recorded only for a tree that is that commit: a dirty one (modified or untracked files under the app) was
	# not built from HEAD, and its record would make cd skip a release of what HEAD is.
	let dirty = (do { cd $app_dir; ^git status --porcelain -- . } | complete | if $in.exit_code == 0 { $in.stdout | str trim | is-not-empty } else { true })
	let sha = if $dirty { "" } else { do { cd $app_dir; ^git rev-parse HEAD } | complete | if $in.exit_code == 0 { $in.stdout | str trim } else { "" } }
	let pin = if $git_root.exit_code == 0 { $git_root.stdout | str trim | path join .github node-engine.pin } else { "" }
	let engine = if ($pin | is-not-empty) and ($pin | path exists) { open --raw $pin | str trim } else { "" }
	let images = ($pushed | items {|svc, p| [$svc $"($p.tag)@($p.digest)"] } | into record)
	{
		apiVersion: "v1", kind: "ConfigMap"
		metadata: {name: "pronto-release", namespace: $node.namespace}
		data: {sha: $sha, verified: "", pin: (runtime version), enginePin: $engine, images: ($images | to json --raw), at: (date now | format date "%Y-%m-%dT%H:%M:%S%z")}
	} | to json | kubectl-ok apply -f -
}

# What the prune did, in the release's ConfigMap: `pruned` "true" or "false", and `prune_error` (empty on success).
export def record-prune [node: record, failure: any] {
	let data = if $failure == null { {pruned: "true", prune_error: ""} } else { {pruned: "false", prune_error: ($failure | into string | str substring 0..499)} }
	kubectl-ok patch configmap pronto-release -n $node.namespace --type merge -p ({data: $data} | to json --raw)
}

# --- the release ---

# Builds the images on the node's buildkitd and answers what was pushed by service: {tag, digest}, the
# database's tag being its Postgres major. The tag is `release`, a preview's name, or `check`.
def build-images [app_info: record, node: record, fwd: record, services: list<string>, tag: string]: nothing -> record {
	push images $app_info.dir $node $fwd $services $tag
}

# The tools a release runs, which an app pins in its mise (kubectl, sops, crane, docker, buildx): a missing
# one fails here, before anything is built, not halfway.
export def require-tools [tools: list<string>] {
	let missing = ($tools | where {|t| which $t | is-empty })
	if ($missing | is-not-empty) { error make {msg: $"missing on the PATH: ($missing | str join ', '): the app's mise pins them, see node/README.md"} }
}

# A namespace that exists is the release's own only if it says so: `pronto.dev/release=<app>`, and the
# preview's name for a preview. An unlabelled one (made by hand, or by another tool) is refused for
# --delete always, and for a release unless `adopt` says the release may take it (its Namespace object
# then labels it).
export def check-ownership [app: string, node: record, --adopt, --delete] {
	# Absent is a successful, empty answer; a failed read (timeout, denied, API down) is never taken for absent,
	# since the write that follows would then change or delete a namespace whose owner was not looked at.
	let r = (^kubectl get namespace $node.namespace --ignore-not-found -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"reading namespace ($node.namespace) failed, so its owner is unknown: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return }
	let labels = ($r.stdout | from json | get metadata.labels? | default {})
	let owned = (($labels | get -o "pronto.dev/release") == $app) and (($node.preview | is-empty) or (($labels | get -o "pronto.dev/preview") == $node.preview))
	if $owned { return }
	if $adopt and not $delete { print $"node: (stamp) adopting namespace ($node.namespace): the release labels it"; return }
	error make {msg: $"namespace ($node.namespace) exists but is not labelled pronto.dev/release=($app)(if ($node.preview | is-not-empty) { $' and pronto.dev/preview=($node.preview)' } else { '' }): it is not this release's to (if $delete { 'delete' } else { 'change; --adopt takes it' })"}
}

# Whether the node has pulled from the registry's host before: an image of it among its nodes'. A read
# cannot prove a pull works (that is the first rollout, which the database's old image survives), so a
# node that never pulled from it is said, not refused.
def check-registry-pull [node: record] {
	let host = ($node.environment.registry | split row "/" | first)
	let images = (kubectl-json get nodes | get items | each {|n| $n.status?.images? | default [] | get names | flatten } | flatten)
	if not ($images | any {|i| $i | str starts-with $"($host)/" }) {
		print $"node: (stamp) no node has pulled from ($host) yet: its k3s registries.yaml must carry it, or the first rollout waits on ImagePullBackOff"
	}
}

# What a build needs from the node, read before anything is built: the operator's buildkitd and the registry
# run, the registry answers through the tunnel (the way the build's push is read back), and the buildkitd
# answers and builds for the environment's platform. Writes nothing. The services themselves are pronto's
# (services/buildkit, services/registry): a release never creates or changes them.
export def check-node-build [node: record, fwd: record] {
	for s in [
		{what: "builder", ns: $node.build.buildkit.namespace, name: $node.build.buildkit.deployment}
		{what: "registry", ns: $node.build.registry.namespace, name: $node.build.registry.deployment}
	] {
		let d = (^kubectl get deployment $s.name -n $s.ns -o json | complete)
		let ready = if $d.exit_code == 0 { $d.stdout | from json | get status?.availableReplicas? | default 0 } else { 0 }
		if $ready < 1 { error make {msg: $"the node's ($s.what) is not running: deployment ($s.name) in ($s.ns) has no available replica: its manifests are pronto's services/buildkit and services/registry"} }
	}
	let code = (^curl -s -o /dev/null -w "%{http_code}" --max-time 10 $"http://127.0.0.1:($fwd.registry)/v2/" | complete)
	let status = ($code.stdout | str trim)
	if $status != "200" { error make {msg: $"the node's registry does not answer through the tunnel on 127.0.0.1:($fwd.registry)/v2/ \(HTTP $status\)"} }
	let work = (mktemp -d -t node-preflight.XXXXXX | str trim)
	try {
		let have = (push with-builder $work $fwd {|builder| push platforms $builder })
		if $node.environment.platform not-in $have { error make {msg: $"the node's buildkitd builds for ($have | str join ', '), not ($node.environment.platform)"} }
	} finally {
		rm -rf $work
	}
}

# Everything that is read before anything is built or written: the pin, the tools, the operators, the node's builder and registry, who owns
# the namespace, the SOPS file, the backups' credentials. Answers the file's Secrets, decrypted, for the
# release to apply (a preview's without the backups' credentials).
export def preflight [app_info: record, node: record, fwd: record, --check, --adopt, --build]: nothing -> list {
	let pin = (runtime version)
	if $pin not-in $validated_pins {
		error make {msg: $"the pronto runtime is ($pin); this engine is validated against ($validated_pins | str join ', '), see node/engine/contract_test.nu: move the pin there first"}
	}
	let secrets_file = (secrets-file $app_info.dir $node)
	require-tools (["kubectl" "docker"] | append (if $secrets_file != null { ["sops"] } else { [] }) | append (if $check and not $build { [] } else { ["crane"] }))
	check-operators $node
	check-registry-pull $node
	check-node-build $node $fwd
	check-ownership $app_info.name $node --adopt=$adopt
	let backups_on = (($node.backups? | default null) != null and ($node.preview | is-empty))
	let skip = if ($node.backups? | default null) != null and not $backups_on { [$node.backups.credentials] } else { [] }
	let secrets = if $secrets_file == null { [] } else { decrypt-secrets $secrets_file $node.namespace --without $skip }
	if $backups_on and ($secrets | where {|s| $s.metadata.name == $node.backups.credentials } | is-empty) {
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
	# What the release must know before it writes anything: the database's image (the way back if the new one never
	# serves) and each Deployment's revision. A read that fails stops it here, with nothing written.
	let deployments = (of-kind $objects Deployment)
	let jobs = (of-kind $objects Job)
	# Only a confirmed absence (an empty, successful answer) means no database to put back: a failed read stops the
	# release before it changes anything.
	let cluster_read = (^kubectl get $"cluster.postgresql.cnpg.io/($app)-db" -n $ns --ignore-not-found -o json | complete)
	if $cluster_read.exit_code != 0 { error make {msg: $"reading the database cluster ($app)-db failed, so its image to put back is unknown: ($cluster_read.stderr | str trim)"} }
	let previous_image = if ($cluster_read.stdout | str trim | is-empty) { null } else { $cluster_read.stdout | from json | get -o spec.imageName }
	let before = (rollback revisions ($deployments | get metadata.name) $ns)
	as-list $parts.namespace | kubectl-ok apply -f -
	dry-run $parts.rest $ns
	# 5. secrets
	apply-secrets $secrets
	let oidc = (render oidc-secrets $compose $app_info.dir)
	if ($oidc | is-not-empty) {
		oidc-secret $app $ns $oidc | to json | kubectl-ok apply --server-side --field-manager=pronto-oidc -f -
	}
	# 6. everything but the Deployments and Jobs, after the Deployments' revisions are recorded
	try {
		print $"node: (stamp) applying manifests for ($app)"
		as-list ($objects | where {|o| $o.kind not-in [Deployment Job Namespace] }) | kubectl-ok apply -f -
		# 8. the database, on its image
		let db_image = (of-kind $objects Cluster | first | get spec.imageName)
		try { wait-primary $app $ns $db_image $node.waits.primary } catch {|e|
			if $previous_image != null {
				print -e $"node: (stamp) the database did not come up on the new image: putting back ($previous_image)"
				let put = (^kubectl patch $"cluster.postgresql.cnpg.io/($app)-db" -n $ns --type merge -p ({spec: {imageName: $previous_image}} | to json --raw) | complete)
				if $put.exit_code != 0 { error make {msg: $"($e.msg); putting back the database image ($previous_image) failed: ($put.stderr | str trim)"} }
			}
			error make {msg: $e.msg}
		}
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
		let back = (try { rollback undo $before $ns } catch {|r| {undone: [], failed: [{name: "(all)", why: $r.msg}]} })
		error make {msg: ($e.msg + (if ($back.undone | is-not-empty) { $"; rolled back ($back.undone | str join ', ')" } else { "" }) + (if ($back.failed | is-not-empty) { $"; could not roll back ($back.failed | each {|f| $'($f.name): ($f.why)' } | str join '; ')" } else { "" }))}
	}
	# 14. retire what an earlier release left
	for r in $node.retire {
		kubectl-ok delete $r.resource $r.name -n $ns --ignore-not-found
	}
	# 15. record
	record-release $app_info.dir $node $pushed
	print $"\n[SUCCESS] Released ($app) to ($node.context): https://($node.host)/"
}

# Releases the app in the folder (or `--app`), to production or `--preview <name>`.
def main [
	--app: string              # the app's directory, or its name in the monorepo
	--preview: string = ""     # the preview's name: its own namespace beside the release's
	--check                    # steps 0 to 4 only, every write a server dry run, nothing built (unless --build)
	--build                    # with --check: build and push the images under the tag `check`, then dry-run with their digests
	--delete                   # delete the preview's namespace (a preview only)
	--serving                  # print `serving <sha>`: the commit the release recorded in the namespace (empty when none); writes nothing
	--prune                    # only the registry maintenance: prune and collect, and record the outcome (a release's retry); releases nothing
	--verified: string = ""    # the commit cd's public checks passed for: recorded as verified when it is the one the node serves, refused when not (`--serving` then prints it as verified)
	--adopt                    # take an existing namespace the release did not label (its Namespace object labels it)
	--schema-from: string = "" # the preview copy of a database (not in this engine yet)
] {
	$env.GCP_T0 = (date now)
	let verifying = ($verified | is-not-empty)
	if ([$serving $verifying $prune] | where {|f| $f } | length) > 1 or (([$serving $verifying $prune] | any {|f| $f }) and ($check or $build or $delete or $adopt)) { error make {msg: "--serving, --verified and --prune go with no other flag, and one at a time"} }
	if $check and $delete { error make {msg: "--check and --delete cannot be given together: a check writes nothing, a delete is a write"} }
	if $build and not $check { error make {msg: "--build only goes with --check: a release always builds"} }
	if ($schema_from | is-not-empty) { error make {msg: "--schema-from is not in this engine yet: a preview starts with an empty database"} }
	let app_info = (runtime resolve-app $app)
	let node = (render node-config $app_info.cue_path $preview)
	if $delete {
		if ($preview | is-empty) or $node.namespace == $node.name { error make {msg: $"--delete removes a preview's namespace; ($node.namespace) is the release's"} }
	}
	if $serving {
		# What cd asks before it releases: what the node's namespace records (an absent record, or namespace, is empty):
		# `serving <sha> verified <sha> maintenance <ok|failed|unknown>`.
		tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					let r = (^kubectl get configmap pronto-release -n $node.namespace --ignore-not-found -o json | complete)
					if $r.exit_code != 0 { error make {msg: $"reading the recorded release of ($node.namespace) failed: ($r.stderr | str trim)"} }
					let data = if ($r.stdout | str trim | is-empty) { {} } else { $r.stdout | from json | get -o data | default {} }
					let maintenance = match ($data | get -o pruned | default "") { "true" => "ok", "false" => "failed", _ => "unknown" }
					print $"serving (($data | get -o sha | default '') | str trim) verified (($data | get -o verified | default '') | str trim) maintenance ($maintenance)"
				}
			} finally {
				rm -f $kubeconfig
			}
		}
		return
	}
	if $prune {
		# The registry maintenance of a release that was live when its own failed: the same prune and collection, outcome recorded.
		tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					let failure = (try { registry prune $"127.0.0.1:($fwd.registry)" $node.build ""; null } catch {|e| $e.msg })
					record-prune $node $failure
					if $failure != null { error make {msg: $"the registry maintenance failed: ($failure)"} }
					print $"node: (stamp) the node's registry maintenance passed"
				}
			} finally {
				rm -f $kubeconfig
			}
		}
		return
	}
	if $verifying {
		# cd's word that the public site passed its checks for what is recorded: `verified` becomes `sha`.
		tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					let r = (^kubectl get configmap pronto-release -n $node.namespace --ignore-not-found -o json | complete)
					if $r.exit_code != 0 { error make {msg: $"reading the recorded release of ($node.namespace) failed: ($r.stderr | str trim)"} }
					let sha = if ($r.stdout | str trim | is-empty) { "" } else { $r.stdout | from json | get -o data.sha | default "" }
					if ($sha | is-empty) { error make {msg: $"($node.namespace) records no commit to mark verified (a release of a dirty tree records none)"} }
					# cd's checks were of the commit it names: a release since then (another run's) is not what they saw.
					if $sha != $verified { error make {msg: $"the node now serves ($sha), not ($verified) which the checks passed for: it is not marked verified"} }
					kubectl-ok patch configmap pronto-release -n $node.namespace --type merge -p ({data: {verified: $verified}} | to json --raw)
					print $"verified ($verified)"
				}
			} finally {
				rm -f $kubeconfig
			}
		}
		return
	}
	let compose = if $delete { {services: {}} } else { render compose-config $app_info.dir }
	let meta = (render app-meta $app_info.cue_path $preview)
	if not $delete { refuse $app_info $node $meta $compose $meta.render.enabled }
	let facts = if $delete { {} } else { render facts $app_info.dir }
	let maintenance_failure = (tunnel with-tunnel $node.api $node.build {|fwd|
		let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
		try {
			with-env {KUBECONFIG: $kubeconfig} {
				if $delete {
					check-ownership $app_info.name $node --delete
					print $"node: (stamp) deleting namespace ($node.namespace)"
					kubectl-ok delete namespace $node.namespace --ignore-not-found --wait=true
				} else {
					let secrets = (preflight $app_info $node $fwd --check=$check --adopt=$adopt --build=$build)
					let services = (render build-services $compose $meta.render.enabled)
					# The registry's lease (a release, and a check that builds: both push): held while this release pushes and until it ends, so
					# no other release collects the registry's garbage under its pushes (registry.nu).
					let lease = if (not $check) or $build { registry lease-acquire $node.build $node.name $node.namespace } else { "" }
					try {
						# 2. build, or placeholders for a check
						let preview_tag = if ($node.preview | is-empty) { "release" } else { $node.preview }
						let pushed = if $check and not $build {
							render placeholder-pushed $services $preview_tag
						} else {
							print $"node: (stamp) building ($services | str join ', ') for ($app_info.name) on the node's buildkitd"
							build-images $app_info $node $fwd $services (if $check { "check" } else { $preview_tag })
						}
						# the lease renewed after the push, and again after the long phases that follow
						if $lease != "" { registry lease-renew $node.build $lease }
						release-app $app_info $node $meta $compose $facts $secrets $pushed --check=$check
						if $lease != "" { registry lease-renew $node.build $lease }
						# 16. prune: the release is live, so a failure here does not undo it; it is recorded beside the release
						# (`--serving` reports it) and ends the command with a distinct status once the tunnel is closed
						if not $check {
							let failure = (try { registry prune $"127.0.0.1:($fwd.registry)" $node.build $lease; null } catch {|e|
								print -e $"node: (stamp) MAINTENANCE FAILED: the node's registry was not pruned, the release is live: ($e.msg)"
								$e.msg
							})
							let unrecorded = (try { record-prune $node $failure; null } catch {|e| $e.msg })
							if $unrecorded != null { error make {msg: $"the release is live, but the prune's outcome could not be recorded: ($unrecorded)"} }
							$failure
						}
					} finally {
						if $lease != "" { try { registry lease-release $node.build $lease } catch {|e| print -e $"node: (stamp) warning: the registry lease ($lease) was not released: ($e.msg)" } }
					}
				}
			}
		} finally {
			rm -f $kubeconfig
		}
	})
	if $maintenance_failure != null {
		print -e $"node: (stamp) released, but the registry maintenance failed, which pronto-release records and --serving reports: ($maintenance_failure)"
		exit 3
	}
}
