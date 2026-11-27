# release.nu: release@k8s for a pronto app on the Contabo node (README.md, "The node release engine").
# It replaces upstream's k8s/release.nu `main` for the node's existing k3s: the images are built on the
# node's own buildkitd and pushed to the node's registry (push.nu), which is where the node pulls them
# from (127.0.0.1:5000), the manifests are upstream's own
# (#BuildManifests) patched by the app's Node (schema/node.cue), and the order is upstream's, with the
# engine's extra steps marked below. It runs on the Mac, never on the node; kubectl reaches the node
# over an ssh tunnel (tunnel.nu).
#
#   nu node/release.nu [--app <dir>] [--preview <name>] [--check [--build]] [--delete]
#   nu node/release.nu --tenant <namespace> --host <host> [--push-kubeconfig <file>] [--check [--build]]   a tenant's release (tenant.nu)
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
use tenant.nu

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

# The objects applied. With `adopt` server-side and forced, as pronto-release, so the release takes the fields of an
# object another manager (the old fork's engine, a hand's apply) set; without it a plain client-side apply.
def apply-objects [objects: list, --adopt] {
	if $adopt {
		as-list $objects | kubectl-ok apply --server-side --force-conflicts --field-manager=pronto-release -f -
	} else {
		as-list $objects | kubectl-ok apply -f -
	}
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
export def dry-run [objects: list, namespace: string, --adopt, --tenant] {
	# Absent is a successful, empty answer; a failed read (denied, API down) stops here, it is not "asked in default". A tenant's
	# publisher cannot read a namespace: its namespace is its provisioner's, and exists.
	let ns_read = if $tenant { {exit_code: 0, stdout: $namespace, stderr: ""} } else { ^kubectl get namespace $namespace --ignore-not-found -o name | complete }
	if $ns_read.exit_code != 0 { error make {msg: $"reading namespace ($namespace) failed, so the server dry run cannot tell where to ask: ($ns_read.stderr | str trim)"} }
	let there = ($ns_read.stdout | str trim | is-not-empty)
	let items = if $there { $objects } else { $objects | each {|o| if $o.kind == "Namespace" { $o } else { $o | upsert metadata.namespace "default" } } }
	if not $there { print $"node: (stamp) namespace ($namespace) does not exist yet: the server dry run asks the objects in default" }
	# A Job a release left holds its template immutably: the new one is asked under a name of its own, created, not applied.
	let jobs = ($items | where kind == Job | each {|j| $j | upsert metadata.name $"($j.metadata.name)-dryrun" })
	if $adopt {
		as-list ($items | where kind != Job) | kubectl-ok apply --dry-run=server --server-side --force-conflicts --field-manager=pronto-release -f -
	} else {
		as-list ($items | where kind != Job) | kubectl-ok apply --dry-run=server -f -
	}
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

# With standbys: every instance ready on the image, in a wait of its own after the primary's. The primary is up and
# serving by now, so a slow standby (a volume being cloned) is no reason to put the old image back: it only stops the release.
def wait-standbys [app: string, namespace: string, image: string, instances: int, seconds: int] {
	print $"node: (stamp) waiting for the ($instances) instances of ($app)-db in ($namespace) on ($image)"
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let ready = (kubectl-json get pods -n $namespace -l $"cnpg.io/cluster=($app)-db,cnpg.io/podRole=instance" | get items
			| where {|p| $p.metadata.deletionTimestamp? == null and ($p.spec.containers | where name == "postgres" | first | get image) == $image and ($p.status.conditions? | default [] | any {|c| $c.type == "Ready" and $c.status == "True" }) })
		if ($ready | length) >= $instances { return }
		if (date now) > $deadline { error make {msg: $"cluster/($app)-db has ($ready | length) of its ($instances) instances ready on ($image) after ($seconds) s; the primary is up, so the database image stays"} }
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

# The door is public and dials its own Dapr sidecar, with `dapr-app-id` set on every route (Dapr takes the target from that
# header before it reads a `/v1.0/invoke/<id>/` path, so the path never picks a service). Its `/crud/v1.0/metadata` must be
# PostgREST's answer (a 404, `PGRST125`), never the sidecar's metadata (a 200 JSON body with `"runtimeVersion"`), and no Dapr API
# path may reach the sidecar or another service: explicit invocation of the door's own service (`/crud/v1.0/invoke/caddy/method/health`,
# which would answer `ok`), the same path spelled with encoded dots and slashes, a `..` out of the prefix (sent as is), and the
# other prefixes that strip and pass the rest on (`/img`, `/blobs`), also spelled in upper case (the door's matchers ignore case). Every `/crud` probe must answer PostgREST's 404; the others
# fail on a 200 with the sidecar's metadata or a service's bare `ok`. A curl failure, a timeout or any 5xx fails the release
# (inconclusive is a failure). Nothing here depends on DNS: the probes dial the Envoy Gateway data-plane Service of the release's
# Gateway through a `kubectl port-forward` and plain HTTP with the public `Host` (the way the node's cloudflared dials it; the
# Gateway has no HTTPS listener). A preview with no public host of its own has nothing to ask.
export def door-probes [] {
	[
		{path: "/crud/v1.0/metadata", as_is: false, strict: true}
		{path: "/crud/v1.0/invoke/caddy/method/health", as_is: false, strict: true}
		{path: "/crud/v1.0/invoke/auth/method/auth/health", as_is: false, strict: true}
		{path: "/crud/v1.0/%2e/invoke/caddy/method/health", as_is: false, strict: false}
		{path: "/crud/v1.0%2Finvoke%2Fcaddy%2Fmethod%2Fhealth", as_is: false, strict: false}
		{path: "/crud/x/../v1.0/invoke/caddy/method/health", as_is: true, strict: false}
		{path: "/crud/%2e%2e/v1.0/metadata", as_is: true, strict: false}
		{path: "/img/v1.0/metadata", as_is: false, strict: false, guard: true}
		{path: "/img/v1.0-alpha1/metadata", as_is: false, strict: false, guard: true}
		{path: "/blobs/v1.0/metadata", as_is: false, strict: false, guard: true}
		{path: "/blobs/v1.0-alpha1/metadata", as_is: false, strict: false, guard: true}
		# Caddy's path matchers ignore case, so the upper-case spellings must meet the guard too (PRONTO-916): a case-sensitive guard
		# lets `/CRUD/v1.0/metadata` through to the sidecar as `/v1.0/metadata`. Each must be the door's own 404.
		{path: "/CRUD/v1.0/metadata", as_is: false, strict: true, guard: true}
		{path: "/Img/v1.0-alpha1/metadata", as_is: false, strict: false, guard: true}
		{path: "/BLOBS/v1.0/metadata", as_is: false, strict: false, guard: true}
	]
}

# Waits until the port-forward `pid` answers on `port`; fails with kubectl's message when it died or never did.
def wait-forward [pid: int, port: int, log: string, --seconds: int = 30] {
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let up = ((^kill -0 $pid | complete).exit_code == 0)
		if $up and (tunnel answers $port) { return }
		if not $up { error make {msg: $"the door check's kubectl port-forward closed: (open --raw $log | str trim)"} }
		if (date now) > $deadline { error make {msg: $"the door check's kubectl port-forward did not answer on 127.0.0.1:($port) in ($seconds) s: (open --raw $log | str trim)"} }
		sleep 250ms
	}
}

# The probes, each through `http://127.0.0.1:<port>` with the public Host; the first that fails ends the check.
def run-door-probes [node: record, port: int, --address: string = "127.0.0.1"]: nothing -> int {
	let file = (mktemp -t door.XXXXXX | str trim)
	mut asked = 0
	try {
		for probe in (door-probes) {
			let url = $"http://($address):($port)($probe.path)"
			let args = (if $probe.as_is { ["--path-as-is"] } else { [] })
			let r = (^curl -s -m 20 ...$args -H $"Host: ($node.host)" -o $file -w "%{http_code}" $url | complete)
			if $r.exit_code != 0 { error make {msg: $"the door check could not ask ($probe.path) of ($node.host): curl exit ($r.exit_code), so the door cannot be certified"} }
			let body = (try { open --raw $file } catch { "" })
			let status = ($r.stdout | str trim)
			# /img and /blobs are the door's routes to imgproxy and the blob store, which an app may not run: there Caddy answers a 5xx for the
			# upstream that is absent, which reaches neither the sidecar nor a service (the leak check below still runs on any answer).
			let lenient = ($probe.lenient? | default false)
			if ($status =~ '^5\d\d$' and not $lenient) or $status !~ '^\d{3}$' { error make {msg: $"the door check could not ask ($probe.path) of ($node.host): it answered ($status), so the door cannot be certified"} }
			if $status == "200" and (($body =~ '"runtimeVersion"') or ($body =~ '"appConnectionProperties"') or (($body | str trim) == "ok")) {
				error make {msg: $"the door reaches the Dapr API: ($node.host)($probe.path) answered 200 with ($body | str substring 0..200); the caddy Dapr configuration did not take"}
			}
			# The plain spellings answer 404: the doorguard's own (an empty body; it matches first and covers /crud too) or PostgREST's
			# (PGRST125) where an older door has no guard. Never the sidecar's or a service's answer, which the 200 check above refuses.
			# The normalized ones are cleaned by Caddy before they route (a redirect to the clean path, or the file server): they only
			# must not reach the sidecar or a service.
			if $probe.strict and $status != "404" {
				error make {msg: $"the door's ($probe.path) answered ($status), not a 404 \(the doorguard's, or PostgREST's PGRST125\): ($body | str substring 0..200)"}
			}
			# A Dapr API path under /img or /blobs is the door's own 404 (doorguard): never a proxied answer, whatever the app runs.
			if ($probe.guard? | default false) and $status != "404" {
				error make {msg: $"the door's ($probe.path) answered ($status), not the door's own 404: the doorguard block is missing from its Caddyfile"}
			}
			$asked = $asked + 1
		}
	} catch {|e|
		rm -f $file
		error make {msg: $e.msg}
	}
	rm -f $file
	$asked
}

export def check-door [node: record, gateway: string, --direct] {
	if ($node.preview | is-not-empty) and (($node.hosts | get -o $node.preview | default "") | is-empty) { return }
	# The Gateway's own data-plane Service where Envoy Gateway makes one per Gateway; on the node the Gateways of every app are
	# merged into the one Service of the GatewayClass (`pronto-gateway`, owning-gatewayclass=eg), which then serves this host.
	let own = $"gateway.envoyproxy.io/owning-gateway-name=($gateway),gateway.envoyproxy.io/owning-gateway-namespace=($node.namespace)"
	let shared = $"gateway.envoyproxy.io/owning-gatewayclass=($node.environment.gatewayClassName)"
	let by_gateway = (kubectl-json get service -n envoy-gateway-system -l $own | get items)
	let selector = (if ($by_gateway | is-empty) { $shared } else { $own })
	let services = (if ($by_gateway | is-empty) { kubectl-json get service -n envoy-gateway-system -l $shared | get items } else { $by_gateway })
	if ($services | is-empty) { error make {msg: $"the door check found no Envoy Gateway Service for Gateway ($gateway) in ($node.namespace) \(envoy-gateway-system, ($selector)\), so the door cannot be certified"} }
	let service = ($services | first)
	let remote = ($service.spec.ports | first | get port)
	# In the builder pod (--direct) the Service's ClusterIP is dialled as it is: no port-forward, so no right to forward into the gateway's namespace.
	if $direct {
		let ip = ($service.spec.clusterIP? | default "")
		if not ($ip =~ '^[0-9.]+$') { error make {msg: $"the door check found no ClusterIP on the Envoy Gateway Service ($service.metadata.name): it cannot be dialled from the pod"} }
		let asked = (run-door-probes $node $remote --address $ip)
		print $"node: (stamp) the door's Dapr API is closed: ($asked) probes under /crud, /img and /blobs answer no sidecar and no service"
		return
	}
	let local = (tunnel free-ports 1 | first)
	let log = (mktemp -t door-forward.XXXXXX | str trim)
	let started = (^sh -c $"kubectl port-forward -n envoy-gateway-system 'service/($service.metadata.name)' '($local):($remote)' >'($log)' 2>&1 & echo $!" | complete)
	if $started.exit_code != 0 { rm -f $log; error make {msg: $"kubectl port-forward did not start: ($started.stderr | str trim)"} }
	let pid = ($started.stdout | str trim | into int)
	let asked = (try {
		wait-forward $pid $local $log
		run-door-probes $node $local
	} catch {|e|
		^kill $pid | complete | ignore
		rm -f $log
		error make {msg: $e.msg}
	})
	^kill $pid | complete | ignore
	rm -f $log
	print $"node: (stamp) the door's Dapr API is closed: ($asked) probes under /crud, /img and /blobs answer no sidecar and no service"
}

# The record of what runs: `sha` (what `--serving` prints, empty for a tree that was not a commit), and `verified`, empty
# until the app's cd has checked the public site for it (`--verified`).
export def record-release [app_dir: string, node: record, pushed: record, --tenant] {
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
		# a tenant's release says which app it is (`app`): the namespace's one app, which the next release of it checks (tenant.nu check-namespace)
		data: ({sha: $sha, verified: "", pruned: "", prune_error: "", pin: (runtime version), enginePin: $engine, images: ($images | to json --raw), at: (date now | format date "%Y-%m-%dT%H:%M:%S%z")} | merge (if $tenant { {app: $node.name} } else { {} }))
	} | to json | kubectl-ok apply -f -
}

# `verified` emptied in the namespace's record before a release changes what serves; an absent record needs none.
def invalidate-verified [ns: string] {
	let r = (^kubectl patch configmap pronto-release -n $ns --type merge -p '{"data":{"verified":""}}' | complete)
	if $r.exit_code != 0 and not ($r.stderr =~ "NotFound") { error make {msg: $"invalidating the verified record of ($ns) failed: ($r.stderr | str trim)"} }
}

# The registry lease renewed. Before the push (and until the images are pushed) a failure stops the release, as nothing is live; after
# the release is applied a failure is a warning, never a failure of a release that is live (the
# lease's hour is the margin, and the next renewal tries again).
def renew-lease [node: record, lease: string, --before-live] {
	if $lease == "" { return }
	if $before_live {
		# Nothing is live yet: a lease that cannot be renewed would let a collector take this release for dead mid-push, so it stops
		# here. A blip of the API is not the lease's end: three attempts, a second and two apart, and none after a NotFound (the
		# lease is gone: a retry cannot bring it back).
		mut last = ""
		for attempt in 1..3 {
			let r = (try { registry lease-renew $node.build $lease; null } catch {|e| $e.msg | default "unknown error" })
			if $r == null { return }
			$last = $r
			if ($r =~ "NotFound") or $attempt == 3 { break }
			print -e $"node: (stamp) the registry lease ($lease) was not renewed \(attempt ($attempt) of 3\), trying again: ($r)"
			sleep ($attempt * 1sec)
		}
		error make {msg: $last}
	}
	try { registry lease-renew $node.build $lease } catch {|e| print -e $"node: (stamp) warning: the registry lease ($lease) was not renewed: ($e.msg)" }
}

# What the prune did, in the release's ConfigMap: `pruned` "true", "false" or "pending" (the collection was deferred, to be retried), and `prune_error` (empty on success).
export def record-prune [node: record, failure: any, pending: string = ""] {
	let data = if $failure != null { {pruned: "false", prune_error: ($failure | into string | str substring 0..499)} } else if ($pending | is-not-empty) { {pruned: "pending", prune_error: $"collection deferred: ($pending)" } } else { {pruned: "true", prune_error: ""} }
	kubectl-ok patch configmap pronto-release -n $node.namespace --type merge -p ({data: $data} | to json --raw)
}

# --- the release ---

# Builds the images on the node's buildkitd and answers what was pushed by service: {tag, digest}, the
# database's tag being its Postgres major. The tag is `release`, a preview's name, or `check`.
def build-images [app_info: record, node: record, fwd: record, services: list<string>, tag: string, lease: string]: nothing -> record {
	push images $app_info.dir $node $fwd $services $tag $lease
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

# `--schema-from <namespace>` reads the live database there: a namespace that is not the preview's own and not another
# preview, holding the app's database cluster with a primary. Read-only. (Bonk's production namespace never carried the
# release's label, so the label is not asked.) Answers the cluster.
export def check-schema-source [app: string, node: record, from: string] {
	if $from == $node.namespace { error make {msg: $"--schema-from ($from) is the preview's own namespace: name the live one"} }
	let ns = (^kubectl get namespace $from --ignore-not-found -o json | complete)
	if $ns.exit_code != 0 { error make {msg: $"reading namespace ($from) failed, so the schema to copy is unknown: ($ns.stderr | str trim)"} }
	if ($ns.stdout | str trim | is-empty) { error make {msg: $"--schema-from names the namespace ($from), which does not exist"} }
	let preview_of = ($ns.stdout | from json | get metadata.labels? | default {} | get -o "pronto.dev/preview")
	if $preview_of != null { error make {msg: $"--schema-from names ($from), a preview's namespace: name the live one"} }
	let cluster = (^kubectl get $"cluster.postgresql.cnpg.io/($app)-db" -n $from --ignore-not-found -o json | complete)
	if $cluster.exit_code != 0 { error make {msg: $"reading the database cluster ($app)-db in ($from) failed: ($cluster.stderr | str trim)"} }
	if ($cluster.stdout | str trim | is-empty) { error make {msg: $"--schema-from names ($from), which has no database cluster ($app)-db"} }
	let primary = ($cluster.stdout | from json | get -o status.currentPrimary | default "")
	if ($primary | is-empty) { error make {msg: $"the database cluster ($app)-db in ($from) names no primary to read the schema from"} }
}

# psql or pg_dump in a database pod's postgres container, `$in` on its stdin; its output, or an error naming the call.
def --wrapped db-exec [namespace: string, pod: string, ...args: string]: any -> string {
	let input = $in
	let r = ($input | ^kubectl exec -i -n $namespace $pod -c postgres -- ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"($args | first 1 | str join ' ') in ($pod) failed: ($r.stderr | str trim)"} }
	$r.stdout
}

# The roles the live database has beyond CloudNativePG's own, as SQL: each created where absent (no password: the
# managed ones get theirs from the operator) with the attributes that change what a policy or grant does, and their
# memberships (in predefined roles too). A role CloudNativePG creates at the same moment is the same as one that was there.
const live_roles_sql = "WITH r AS (SELECT oid, rolname, rolcanlogin, rolinherit, rolbypassrls FROM pg_roles WHERE rolname !~ '^pg_' AND rolname !~ '^cnpg_' AND rolname NOT IN ('postgres', 'streaming_replica')) SELECT format('DO $x$ BEGIN CREATE ROLE %I %s %s %s; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $x$;', rolname, CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END, CASE WHEN rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END, CASE WHEN rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END) FROM r UNION ALL SELECT format('GRANT %I TO %I%s;', g.rolname, m.rolname, CASE WHEN a.admin_option THEN ' WITH ADMIN OPTION' ELSE '' END) FROM pg_auth_members a JOIN pg_roles g ON g.oid = a.roleid AND g.rolname !~ '^cnpg_' AND g.rolname <> 'streaming_replica' JOIN r m ON m.oid = a.member"

# What a read of the live database runs as: a session that cannot write, whatever the SQL says.
const read_only = ["env" "PGOPTIONS=-c default_transaction_read_only=on"]

# The `pgroll` schema's rows as a mark (how many, and what they say): equal before and after the dumps, or the live schema
# moved between them and the two copies would disagree.
const pgroll_mark_sql = "SELECT count(*) || ' ' || md5(coalesce(string_agg(m::text, ',' ORDER BY m::text), '')) FROM pgroll.migrations m"

# The preview database starts as the live one's schema without its rows: its roles, a `pg_dump --schema-only` (owners and
# privileges kept, so row-level security and grants behave as they do live; no publications, which Electric makes for itself)
# and the rows of the `pgroll` schema (so the release's migrate applies only what is new on a schema that already has the
# rest). Read-only on the live namespace (a read-only session, a lock wait of ten seconds so a live migration is never held
# up behind a dump). All of it is read before anything is written, and written in one transaction, so a cut-off copy leaves
# nothing; the transaction also marks the database (`pronto.schema_from`), and the Cluster is annotated after it. A release
# that finds either copies nothing: an annotate that failed after the commit is made again, not refused as a foreign database.
export def copy-schema [app: string, from: string, ns: string] {
	let cluster = $"cluster.postgresql.cnpg.io/($app)-db"
	let target = (kubectl-json get $cluster -n $ns)
	if (($target | get -o metadata.annotations | default {} | get -o "pronto.dev/schema-from") == $from) {
		print $"node: (stamp) the schema of ($from) is already in ($ns)"
		return
	}
	let source = (kubectl-json get $cluster -n $from)
	let live_db = ($source | get -o spec.bootstrap.initdb.database | default "app")
	let live_pod = $source.status.currentPrimary
	let pod = ($target | get -o status.currentPrimary | default $"($app)-db-1")
	let db = ($target | get -o spec.bootstrap.initdb.database | default $live_db)
	let tables = ("SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE'" | db-exec $ns $pod psql -U postgres -d $db -XAtq -f - | str trim | into int)
	if $tables > 0 {
		let marked = ("SELECT coalesce(current_setting('pronto.schema_from', true), '')" | db-exec $ns $pod psql -U postgres -d $db -XAtq -f - | str trim)
		if $marked != $from { error make {msg: $"the database of ($ns) already has ($tables) tables and was not copied from ($from): delete the preview \(--delete\) and release it again"} }
		print $"node: (stamp) the schema of ($from) was copied into ($ns) by a release that did not record it on the Cluster: recording it"
		kubectl-ok annotate $cluster -n $ns --overwrite $"pronto.dev/schema-from=($from)"
		return
	}
	print $"node: (stamp) copying the schema of ($from)/($live_pod) into ($ns)/($pod)"
	let has_pgroll = ("SELECT 1 FROM pg_namespace WHERE nspname = 'pgroll'" | db-exec $from $live_pod ...$read_only psql -U postgres -d $live_db -XAtq -f - | str trim | is-not-empty)
	let mark = if $has_pgroll { $pgroll_mark_sql | db-exec $from $live_pod ...$read_only psql -U postgres -d $live_db -XAtq -f - | str trim } else { "" }
	let roles = ($live_roles_sql | db-exec $from $live_pod ...$read_only psql -U postgres -d $live_db -XAtq -f -)
	let schema = (null | db-exec $from $live_pod pg_dump -U postgres -d $live_db --lock-wait-timeout=10s --schema-only --no-publications --no-subscriptions)
	let pgroll = if $has_pgroll { null | db-exec $from $live_pod pg_dump -U postgres -d $live_db --lock-wait-timeout=10s --data-only --schema=pgroll } else { "" }
	if $has_pgroll and ($pgroll_mark_sql | db-exec $from $live_pod ...$read_only psql -U postgres -d $live_db -XAtq -f - | str trim) != $mark {
		error make {msg: $"the migrations of ($from) changed while its schema was being read: nothing was copied, release again"}
	}
	let marking = $"ALTER DATABASE \"($db)\" SET pronto.schema_from = '($from)';"
	[$roles $schema $pgroll $marking] | str join "\n" | db-exec $ns $pod psql -U postgres -d $db -Xq --single-transaction -v ON_ERROR_STOP=1 -f - | ignore
	kubectl-ok annotate $cluster -n $ns --overwrite $"pronto.dev/schema-from=($from)"
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
export def preflight [app_info: record, node: record, fwd: record, --check, --adopt, --build, --schema-from: string = ""]: nothing -> list {
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
	if ($schema_from | is-not-empty) { check-schema-source $app_info.name $node $schema_from }
	let backups_on = (($node.backups? | default null) != null and ($node.preview | is-empty))
	let skip = if ($node.backups? | default null) != null and not $backups_on { [$node.backups.credentials] } else { [] }
	let secrets = if $secrets_file == null { [] } else { decrypt-secrets $secrets_file $node.namespace --without $skip }
	if $backups_on and ($secrets | where {|s| $s.metadata.name == $node.backups.credentials } | is-empty) {
		let live = ((^kubectl get secret $node.backups.credentials -n $node.namespace | complete).exit_code == 0)
		if not $live { error make {msg: $"Node.backups reads the Secret ($node.backups.credentials), which is neither in the SOPS file nor in ($node.namespace)"} }
	}
	# the files the services seed, before anything is built or written
	seed-files $app_info.dir $node | ignore
	# the Secrets the services read: in the SOPS file or already in the namespace
	for name in ($node.services? | default {} | values | each {|s| $s.secrets? | default {} | values } | flatten | uniq) {
		if ($secrets | where {|s| $s.metadata.name == $name } | is-empty) {
			let live = ((^kubectl get secret $name -n $node.namespace | complete).exit_code == 0)
			if not $live { error make {msg: $"Node.services read the Secret ($name), which is neither in the SOPS file nor in ($node.namespace)"} }
		}
	}
	$secrets
}

# The files the services' `seed` names, by ConfigMap: each in the app's folder (a link out of it is refused) and present, and
# one ConfigMap seeded from one file only.
export def seed-files [app_dir: string, node: record]: nothing -> list {
	let root = ($app_dir | path expand)
	let seeds = ($node.services? | default {} | items {|n, s| $s.seed? | default {} | transpose name path | insert service $n } | flatten)
	let clash = ($seeds | group-by name | items {|name, g| {name: $name, paths: ($g | get path | uniq)} } | where {|g| ($g.paths | length) > 1 })
	if ($clash | is-not-empty) { error make {msg: $"Node.services seed the ConfigMap ($clash.0.name) from more than one file: ($clash.0.paths | str join ', ')"} }
	$seeds | uniq-by name | each {|s|
		let file = ($root | path join $s.path | path expand)
		if not ($file | path exists) { error make {msg: $"Node.services seeds the ConfigMap ($s.name) from ($s.path), which is not in ($app_dir): generate the app first"} }
		if not ($file | str starts-with $"($root)/") { error make {msg: $"Node.services seeds the ConfigMap ($s.name) from ($s.path), which resolves outside ($app_dir)"} }
		{name: $s.name, path: $s.path, file: $file}
	}
}

# The ConfigMaps a service's `seed` names, made from the app's file (its key the file's name) where the namespace has none:
# once, on the release that finds it missing. One that exists is never written over, whoever made it (a push owns it after).
export def seed-configmaps [app_dir: string, node: record] {
	for s in (seed-files $app_dir $node) {
		let there = (^kubectl get configmap $s.name -n $node.namespace --ignore-not-found -o name | complete)
		if $there.exit_code != 0 { error make {msg: $"reading the ConfigMap ($s.name) failed, so whether to seed it is unknown: ($there.stderr | str trim)"} }
		if ($there.stdout | str trim | is-not-empty) { continue }
		print $"node: (stamp) seeding the ConfigMap ($s.name) from ($s.path)"
		{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $s.name, namespace: $node.namespace}, data: {($s.file | path basename): (open --raw $s.file)}} | to json | kubectl-ok create -f -
	}
}

# The release itself, with the node reachable and the kubeconfig pinned, over what `preflight`
# answered and what was pushed (by service: {tag, digest}; placeholders for a check).
export def release-app [app_info: record, node: record, meta: record, compose: record, facts: record, secrets: list, pushed: record, --check, --adopt, --schema-from: string = "", --tenant, --push-kubeconfig: string = ""] {
	let app = $app_info.name
	let ns = $node.namespace
	let tenant_ns = (if $tenant { $node.namespace } else { "" })
	let tenant_host = (if $tenant { $node.host } else { "" })
	# 3. data and render
	# A tenant's issuers are the engine's list alone, said before release-data registers a client at any of them.
	if $tenant { check-tenant-issuers $app_info.dir $compose }
	# A tenant's clients are registered at the operator's host (--host, which the binding checked against the Node), never at an origin the Node names.
	let origin = if $check { '' } else if $tenant { $"https://($node.host)" } else { $node.origin }
	let data = (render release-data $app_info.dir $compose $facts $pushed $origin)
	let objects = (render objects $app_info.cue_path $data $node.preview --tenant $tenant_ns --host $tenant_host)
	# The game's own release.cue rendered these: what its publisher may write is checked again here, whatever schema it loaded. A container that
	# leaves allowPrivilegeEscalation unset is made to say false first, and what it will retire is the engine's to decide, before any write.
	let objects = if $tenant { tenant harden-objects $objects } else { $objects }
	if $tenant { tenant check-objects $objects $node (tenant publisher-kinds) }
	let retire = if $tenant { tenant check-retire $node (tenant retire-kinds) $objects } else { $node.retire }
	let parts = (namespace-split $objects)
	let stray = ($objects | where kind == Job | get metadata.name | where {|n| $n not-in ($node.jobOrder | each {|j| $"($app)-($j)" }) })
	if ($stray | is-not-empty) { error make {msg: $"Jobs ($stray | str join ', ') are not in jobOrder"} }
	# 4. the namespace, and the server's word on the rest
	if $check {
		print $"node: (stamp) check: server dry run of ($objects | length) objects in ($ns)"
		dry-run $objects $ns --adopt=$adopt --tenant=$tenant
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
	# A tenant's render has no Namespace: its provisioner made it.
	if ($parts.namespace | is-not-empty) { apply-objects $parts.namespace --adopt=$adopt }
	dry-run $parts.rest $ns --adopt=$adopt --tenant=$tenant
	# What serves is about to change (the server accepted the render): the record of the public site's verification, which cd
	# trusts, is invalidated before the first write that can change it, so a release that fails halfway can never leave an old
	# commit marked verified over new images. A first release has no record.
	invalidate-verified $ns
	# 5. secrets
	apply-secrets $secrets
	let oidc = (render oidc-secrets $compose $app_info.dir)
	if ($oidc | is-not-empty) {
		oidc-secret $app $ns $oidc | to json | kubectl-ok apply --server-side --field-manager=pronto-oidc -f -
	}
	seed-configmaps $app_info.dir $node
	# 6. everything but the Deployments and Jobs, after the Deployments' revisions are recorded
	try {
		print $"node: (stamp) applying manifests for ($app)"
		apply-objects ($objects | where {|o| $o.kind not-in [Deployment Job Namespace] }) --adopt=$adopt
		# 8. the database, on its image
		let db_image = (of-kind $objects Cluster | first | get spec.imageName)
		let db_instances = (of-kind $objects Cluster | first | get spec.instances? | default 1)
		try { wait-primary $app $ns $db_image $node.waits.primary } catch {|e|
			if $previous_image != null {
				print -e $"node: (stamp) the database did not come up on the new image: putting back ($previous_image)"
				let put = (^kubectl patch $"cluster.postgresql.cnpg.io/($app)-db" -n $ns --type merge -p ({spec: {imageName: $previous_image}} | to json --raw) | complete)
				if $put.exit_code != 0 { error make {msg: $"($e.msg); putting back the database image ($previous_image) failed: ($put.stderr | str trim)"} }
			}
			error make {msg: $e.msg}
		}
		if $db_instances > 1 { wait-standbys $app $ns $db_image $db_instances $node.waits.standbys }
		if ($schema_from | is-not-empty) { copy-schema $app $schema_from $ns }
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
		let own = (render own-images $node)
		if ($runtime_services | values | any {|r| $r.serviceToken }) or (($node.services? | default {} | columns) | is-not-empty) { apply-service-token $app $ns }
		# 12. the Deployments: crud rolls after the schema Jobs even with an unchanged image
		let rolled = ($deployments | each {|d| if $d.metadata.name == $"($app)-crud" { runtime fresh-schema-runtime ($d | to json) | from yaml } else { $d } })
		apply-objects $rolled --adopt=$adopt
		let runtime_names = ($runtime_services | columns)
		for name in $runtime_names {
			kubectl-ok rollout status $"deployment/($app)-($name)" -n $ns $"--timeout=($node.waits.rollout * 5)s"
		}
		let components = ["crud" "electric" "auth" "caddy"] | append ($runtime_names | where {|s| $s in ["ticker" "rclone-s3" "imgproxy"] }) | append (if $meta.render.enabled { ["render"] } else { [] }) | append $own | uniq
		# the metrics export has no sidecar: its rollout alone
		for d in ($components | each {|c| $"deployment/($app)-($c)" } | append (if ($node.metricsExport? | default null) != null { [$"deployment/($app)-metrics-export"] } else { [] })) {
			print $"node: (stamp) waiting for ($d) rollout"
			kubectl-ok rollout status $d -n $ns $"--timeout=($node.waits.rollout)s"
		}
		# 13. the mesh is intrinsic: a pod without its sidecar is a failed release
		check-daprd $app $ns $components
		# 13b. the public door must not answer the Dapr sidecar's own API
		let gateways = (of-kind $objects Gateway)
		if ($gateways | is-empty) { error make {msg: "the render has no Gateway, so the door cannot be checked"} }
		# The door check reaches the Envoy Gateway data plane: a tenant's publisher may not, the push identity may.
		if $tenant {
			tenant with-push $push_kubeconfig { check-door $node ($gateways | first | get metadata.name) --direct=($push_kubeconfig | is-empty) }
		} else {
			check-door $node ($gateways | first | get metadata.name)
		}
	} catch {|e|
		print -e $"node: (stamp) the release failed: ($e.msg)"
		let back = (try { rollback undo $before $ns } catch {|r| {undone: [], failed: [{name: "(all)", why: $r.msg}]} })
		error make {msg: ($e.msg + (if ($back.undone | is-not-empty) { $"; rolled back ($back.undone | str join ', ')" } else { "" }) + (if ($back.failed | is-not-empty) { $"; could not roll back ($back.failed | each {|f| $'($f.name): ($f.why)' } | str join '; ')" } else { "" }))}
	}
	# 14. retire what an earlier release left
	for r in $retire {
		kubectl-ok delete $r.resource $r.name -n $ns --ignore-not-found
	}
	# 15. record
	record-release $app_info.dir $node $pushed --tenant=$tenant
	print $"\n[SUCCESS] Released ($app) to ($node.context): https://($node.host)/"
}

# --- a tenant's release (PRONTO-740 S2; tenant.nu) ---

# What a tenant's release reads before anything is built or written, as its publisher and its pusher: the pin, the tools, who the
# KUBECONFIG is and whose the namespace is, the push identity's rights, the tenants' buildkitd (it answers and builds for the
# platform), the files the services seed, and the Secrets they read (in the namespace already: a tenant's release decrypts none).
def tenant-preflight [app_info: record, node: record, push_kubeconfig: string, --check, --build] {
	let pin = (runtime version)
	if $pin not-in $validated_pins {
		error make {msg: $"the pronto runtime is ($pin); this engine is validated against ($validated_pins | str join ', '), see node/engine/contract_test.nu: move the pin there first"}
	}
	let building = ((not $check) or $build)
	require-tools (["kubectl"] | append (if $building { ["docker" "crane" "tar"] } else { [] }))
	tenant check-namespace $node
	if $building {
		tenant check-push-rights $node $push_kubeconfig --door=(not $check)
		let work = (mktemp -d -t node-preflight.XXXXXX | str trim)
		try {
			let have = (push with-remote-builder $work $node.tenant.buildkit {|builder| push platforms $builder })
			if $node.environment.platform not-in $have { error make {msg: $"the tenants' buildkitd builds for ($have | str join ', '), not ($node.environment.platform)"} }
		} finally {
			rm -rf $work
		}
	}
	let seeds = (seed-files $app_info.dir $node)
	tenant check-seeds $seeds
	check-tracked-seeds $app_info.dir $seeds
	for name in ($node.services? | default {} | values | each {|s| $s.secrets? | default {} | values } | flatten | uniq) {
		let live = ((^kubectl get secret $name -n $node.namespace | complete).exit_code == 0)
		if not $live { error make {msg: $"Node.services read the Secret ($name), which is not in ($node.namespace): a tenant's release decrypts none, so its provisioner puts it there"} }
	}
}

# A tenant's seed is copied into a ConfigMap by this process from the checkout, where an ignored or untracked file is whatever the machine
# holds (a `.certs/` private key, a `.env`, a key). So a seed source is a regular file git tracks (`git ls-files --error-unmatch`, run in the
# checkout with the engine's cleared environment), whatever the ignore rules say; the path checks of `seed-files` stand.
export def check-tracked-seeds [app_dir: string, seeds: list] {
	let root = ($app_dir | path expand)
	let git = (which git | first | get path)
	for s in $seeds {
		let rel = ($s.file | path expand | path relative-to $root)
		if ($s.file | path type) != "file" { error make {msg: $"Node.services seeds the ConfigMap ($s.name) from ($s.path), which is not a regular file"} }
		let tracked = (do { cd $root; ^env -i ...(render tenant-env) $git ls-files --error-unmatch -- $rel } | complete)
		if $tracked.exit_code != 0 { error make {msg: $"Node.services seeds the ConfigMap ($s.name) from ($s.path), which is not a file git tracks: a seed is never an ignored or untracked file"} }
	}
}

# Every issuer the tenant's auth names (the auth provider environment's OIDC settings and the compose auth service's own) is on the engine's list.
def check-tenant-issuers [dir: string, compose: record] {
	let environment = ($compose.services.auth?.environment? | default {})
	let provided = (runtime auth-provider-environment $environment (render release-providers $dir))
	tenant check-issuers $provided.oidc $environment (tenant tenant-issuers)
}

# A tenant's release: the app released into the namespace its provisioner made, at the one host it was given, with the KUBECONFIG it is
# given (the namespace's publisher: rights in it alone), no ssh tunnel and no operator's step. The images are built on the tenants'
# sandboxed buildkitd and pushed as the push identity (push.nu tenant-images); the registry's lease, held while it pushes, is the push
# identity's too, and so is the door check. Nothing is pruned or collected, and nothing is written outside the namespace.
def release-tenant [app_info: record, tenant: string, host: string, push_kubeconfig: string, --check, --build] {
	tenant check-tenant-name $tenant
	tenant check-engine-copy $app_info.dir
	let node = (try { render node-config $app_info.cue_path "" --tenant $tenant --host $host } catch {|e|
		if ($e.msg =~ 'no tag for') { error make {msg: "the app's release.cue declares no @tag(tenant) and @tag(tenantHost): a tenant's release.cue binds them into Node.tenant"} }
		error make {msg: $e.msg}
	})
	tenant check-binding $node $tenant $host
	tenant check-pins $node
	tenant check-names $node
	let meta = (render app-meta $app_info.cue_path "" --tenant $tenant --host $host)
	# Before anything resolves the tenant's compose files: `docker compose config` reads what they name with this process's rights.
	tenant check-compose-sources $app_info.dir
	let compose = (render compose-config $app_info.dir --tenant)
	check-tenant-issuers $app_info.dir $compose
	refuse $app_info $node $meta $compose $meta.render.enabled
	tenant tenant-refusals $app_info.dir $node
	let facts = (render facts $app_info.dir)
	tenant-preflight $app_info $node $push_kubeconfig --check=$check --build=$build
	let services = (render build-services $compose $meta.render.enabled (render own-images $node))
	let building = ((not $check) or $build)
	# The registry's lease, as the push identity: no other release collects the registry's garbage under this release's pushes.
	let lease = if $building { tenant with-push $push_kubeconfig { registry lease-acquire $node.build $node.name $node.namespace } } else { "" }
	let body_failure = (try {
		# A dry run with no build holds no lease: no push identity is asked for.
		if $lease != "" { tenant with-push $push_kubeconfig { renew-lease $node $lease --before-live } }
		let pushed = if $check and not $build {
			render placeholder-pushed $services "release"
		} else {
			print $"node: (stamp) building ($services | str join ', ') for ($app_info.name) on the tenants' buildkitd"
			push tenant-images $app_info.dir $node $services (if $check { "check" } else { "release" }) $push_kubeconfig
		}
		if $lease != "" { tenant with-push $push_kubeconfig { renew-lease $node $lease --before-live } }
		release-app $app_info $node $meta $compose $facts [] $pushed --check=$check --tenant --push-kubeconfig $push_kubeconfig
		if $lease != "" { tenant with-push $push_kubeconfig { renew-lease $node $lease } }
		null
	} catch {|e| $e.msg })
	let lease_failure = if $lease != "" { try { tenant with-push $push_kubeconfig { registry lease-release $node.build $lease }; null } catch {|e| $e.msg } } else { null }
	if $body_failure != null {
		error make {msg: (if $lease_failure != null { $"($body_failure); the registry lease ($lease) was not released either: ($lease_failure)" } else { $body_failure })}
	}
	# The rollout is done and the lease is not released: the release says so as a failure (the stale lease holds the registry's collection until it expires).
	if $lease_failure != null { error make {msg: $"the release completed, but the registry lease ($lease) was not released: ($lease_failure)"} }
}

# Releases the app in the folder (or `--app`), to production or `--preview <name>`.
def main [
	--app: string              # the app's directory, or its name in the monorepo
	--preview: string = ""     # the preview's name: its own namespace beside the release's
	--check                    # steps 0 to 4 only, every write a server dry run, nothing built (unless --build)
	--build                    # with --check: build and push the images under the tag `check`, then dry-run with their digests
	--delete                   # delete the preview's namespace (a preview only)
	--serving                  # print `serving <sha>`: the commit the release recorded in the namespace (empty when none); writes nothing
	--prune                    # only the registry maintenance: prune and collect, and record the outcome (a release's retry); releases nothing. Exit 4: deferred (recorded pending), not a failure
	--verified: string = ""    # the commit cd's public checks passed for: recorded as verified when it is the one the node serves, refused when not (`--serving` then prints it as verified)
	--adopt                    # take an existing namespace the release did not label (its Namespace object labels it)
	--schema-from: string = "" # a preview's database starts as the schema (no rows) of the live namespace's database, read from its primary
	--tenant: string = ""      # a tenant's release (tenant.nu): into this namespace, which its provisioner made, as its publisher: the KUBECONFIG given, no ssh tunnel, no operator's step
	--host: string = ""        # with --tenant: the one address the namespace was given
	--push-kubeconfig: string = "" # with --tenant: who pushes the images and checks the door (the registry pod's and the gateway's port-forwards), never the publisher; empty, the pod's own account
] {
	$env.GCP_T0 = (date now)
	if ($tenant | is-not-empty) or ($host | is-not-empty) or ($push_kubeconfig | is-not-empty) {
		if ($tenant | is-empty) { error make {msg: "--host and --push-kubeconfig are a tenant's: name its namespace with --tenant"} }
		if ($host | is-empty) { error make {msg: "--tenant needs --host, the one address its namespace was given"} }
		if ($preview | is-not-empty) or $delete or ($schema_from | is-not-empty) { error make {msg: "a tenant's release is never a preview, a deletion or a schema copy: --tenant goes without --preview, --delete and --schema-from"} }
		if $adopt { error make {msg: "a tenant's namespace is its provisioner's: --adopt is not a tenant's"} }
		if $serving or ($verified | is-not-empty) or $prune { error make {msg: "--serving, --verified and --prune are the operator's: not with --tenant"} }
		if ($env.KUBECONFIG? | default "" | is-empty) or not ($env.KUBECONFIG | path exists) { error make {msg: "a tenant's release runs with the KUBECONFIG it is given: none is set (or the file is missing)"} }
	}
	let verifying = ($verified | is-not-empty)
	if ([$serving $verifying $prune] | where {|f| $f } | length) > 1 or (([$serving $verifying $prune] | any {|f| $f }) and ($check or $build or $delete or $adopt)) { error make {msg: "--serving, --verified and --prune go with no other flag, and one at a time"} }
	if $check and $delete { error make {msg: "--check and --delete cannot be given together: a check writes nothing, a delete is a write"} }
	if $build and not $check { error make {msg: "--build only goes with --check: a release always builds"} }
	if ($schema_from | is-not-empty) {
		if ($preview | is-empty) { error make {msg: "--schema-from copies a database's schema into a preview: it needs --preview"} }
		if $delete or $serving or $verifying or $prune { error make {msg: "--schema-from goes with a release of a preview, not --delete, --serving, --verified or --prune"} }
	}
	let app_info = (runtime resolve-app $app)
	if ($tenant | is-not-empty) {
		release-tenant $app_info $tenant $host $push_kubeconfig --check=$check --build=$build
		return
	}
	let node = (render node-config $app_info.cue_path $preview)
	if $delete {
		if ($preview | is-empty) or $node.namespace == $node.name { error make {msg: $"--delete removes a preview's namespace; ($node.namespace) is the release's"} }
	}
	if $serving {
		# What cd asks before it releases: what the node's namespace records (an absent record, or namespace, is empty):
		# `serving <sha> verified <sha> maintenance <ok|failed|pending|unknown>`.
		tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					let r = (^kubectl get configmap pronto-release -n $node.namespace --ignore-not-found -o json | complete)
					if $r.exit_code != 0 { error make {msg: $"reading the recorded release of ($node.namespace) failed: ($r.stderr | str trim)"} }
					let data = if ($r.stdout | str trim | is-empty) { {} } else { $r.stdout | from json | get -o data | default {} }
					let maintenance = match ($data | get -o pruned | default "") { "true" => "ok", "false" => "failed", "pending" => "pending", _ => "unknown" }
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
		# Exit 0: done. Exit 4: deferred (another release or collector is at the registry), recorded `pending`, to be retried
		# by the next run, not a failure. Any other failure is an error.
		let pending = (tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					mut deferred = ""
					let failure = (try { $deferred = (registry prune $"127.0.0.1:($fwd.registry)" $node.build ""); null } catch {|e| $e.msg })
					record-prune $node $failure $deferred
					if $failure != null { error make {msg: $"the registry maintenance failed: ($failure)"} }
					if ($deferred | is-empty) { print $"node: (stamp) the node's registry maintenance passed" }
					$deferred
				}
			} finally {
				rm -f $kubeconfig
			}
		})
		if ($pending | is-not-empty) {
			print -e $"node: (stamp) the registry maintenance was deferred, not done \(($pending)\); recorded pending, the next run retries it"
			exit 4
		}
		return
	}
	if $verifying {
		# cd's word that the public site passed its checks for `verified`: recorded when the node serves exactly that commit, as a
		# compare-and-set on the record's resourceVersion. A conflict (the record was rewritten, by the maintenance's outcome or
		# a release) is retried while the record still names the commit; one that names another is refused.
		tunnel with-tunnel $node.api $node.build {|fwd|
			let kubeconfig = (tunnel kubeconfig $node.context $fwd.api)
			try {
				with-env {KUBECONFIG: $kubeconfig} {
					mut done = false
					mut attempt = 0
					while not $done {
						$attempt += 1
						let r = (^kubectl get configmap pronto-release -n $node.namespace --ignore-not-found -o json | complete)
						if $r.exit_code != 0 { error make {msg: $"reading the recorded release of ($node.namespace) failed: ($r.stderr | str trim)"} }
						let record = if ($r.stdout | str trim | is-empty) { {} } else { $r.stdout | from json }
						let sha = ($record | get -o data.sha | default "")
						let version = ($record | get -o metadata.resourceVersion | default "")
						if ($sha | is-empty) { error make {msg: $"($node.namespace) records no commit to mark verified (a release of a dirty tree records none)"} }
						# cd's checks were of the commit it names: a release since then (another run's) is not what they saw.
						if $sha != $verified { error make {msg: $"the node now serves ($sha), not ($verified) which the checks passed for: it is not marked verified"} }
						let p = (^kubectl patch configmap pronto-release -n $node.namespace --type merge -p ({metadata: {resourceVersion: $version}, data: {verified: $verified}} | to json --raw) | complete)
						if $p.exit_code == 0 { $done = true } else if ($p.stderr =~ "Conflict") and $attempt < 4 { print -e $"node: (stamp) the record changed while it was being marked; trying again" } else {
							error make {msg: $"marking ($verified) verified failed: ($p.stderr | str trim)"}
						}
					}
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
					let secrets = (preflight $app_info $node $fwd --check=$check --adopt=$adopt --build=$build --schema-from $schema_from)
					let services = (render build-services $compose $meta.render.enabled (render own-images $node))
					# The registry's lease (a release, and a check that builds: both push): held while this release pushes and until it ends, so
					# no other release collects the registry's garbage under its pushes (registry.nu).
					let lease = if (not $check) or $build { registry lease-acquire $node.build $node.name $node.namespace } else { "" }
					mut maintenance = ""
					let body_failure = (try {
						# 2. build, or placeholders for a check
						renew-lease $node $lease --before-live
						let preview_tag = if ($node.preview | is-empty) { "release" } else { $node.preview }
						let pushed = if $check and not $build {
							render placeholder-pushed $services $preview_tag
						} else {
							print $"node: (stamp) building ($services | str join ', ') for ($app_info.name) on the node's buildkitd"
							build-images $app_info $node $fwd $services (if $check { "check" } else { $preview_tag }) $lease
						}
						# the lease renewed after the push, and again after the long phases that follow
						renew-lease $node $lease --before-live
						release-app $app_info $node $meta $compose $facts $secrets $pushed --check=$check --adopt=$adopt --schema-from $schema_from
						renew-lease $node $lease
						# 16. prune: the release is live, so a failure here does not undo it; it is recorded beside the release
						# (`--serving` reports it) and ends the command with a distinct status once the tunnel is closed
						if not $check {
							mut pending = ""
							let failure = (try { $pending = (registry prune $"127.0.0.1:($fwd.registry)" $node.build $lease); null } catch {|e|
								print -e $"node: (stamp) MAINTENANCE FAILED: the node's registry was not pruned, the release is live: ($e.msg)"
								$e.msg
							})
							let unrecorded = (try { record-prune $node $failure $pending; null } catch {|e| $e.msg })
							if $unrecorded != null { error make {msg: $"the release is live, but the prune's outcome could not be recorded: ($unrecorded)"} }
							$maintenance = ($failure | default "")
						}
						null
					} catch {|e| $e.msg })
					# The lease goes whatever happened, and its release is checked (one left behind blocks the next collection for an
					# hour) without turning a live release into a plain failure: a body that succeeded and a lease that stayed is
					# "released, maintenance failed" (status 3, recorded); a body that failed and a lease that stayed say both.
					let lease_failure = if $lease != "" { try { registry lease-release $node.build $lease; null } catch {|e| $e.msg } } else { null }
					if $body_failure != null {
						error make {msg: (if $lease_failure != null { $"($body_failure); the registry lease ($lease) was not released either: ($lease_failure)" } else { $body_failure })}
					}
					if $lease_failure != null {
						let why = $"the registry lease ($lease) was not released: ($lease_failure)"
						$maintenance = (if ($maintenance | is-not-empty) { $"($maintenance); ($why)" } else { $why })
						try { record-prune $node $maintenance } catch {|e| print -e $"node: (stamp) warning: that could not be recorded either: ($e.msg)" }
					}
					if ($maintenance | is-empty) { null } else { $maintenance }
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
