# Releases the billing broker to a cluster the operator runs (pronto's envs.Metal: k3s on a node
# reached over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway),
# beside release.nu's Cloud Run, in the shape identity/metal.nu gives the identity broker:
#   bin/pronto-billing-broker metal --ssh bruno@node --domain D --secrets F (or --project P) [--fee N] [--sandbox-tenants RE]
#
# The broker imports nothing from outside its own files, so no image is built: the pinned Deno image
# runs shared.ts and broker/*.ts from a ConfigMap. It keeps nothing but its secrets: with --secrets,
# the Secret's manifest in a SOPS file (common/sops.nu, PRONTO-155); else read with the operator's
# gcloud from the project's Secret Manager, as Cloud Run's release keeps them. Either way they are
# piped into a Secret on the node, never written to a file: the same signing key, so the entitlements it
# signs verify as Cloud Run's did, and the same webhook secret, so Stripe's one webhook
# (https://<domain>/stripe) is accepted by whichever of the two the name points at. An
# entitlement's `ver` is its clock: one replica, replaced (Recreate) rather than overlapped.

const here = path self .
use ../common/sops.nu
const deno = "denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e"
const port = 8080
# The airlock beside the broker (--airlock, PRONTO-135): mecha-fork's airlock with its door
# (mecha-fork#26, published as mecha 0.22.0-host.3 by pronto-fork's prerelease-mecha), mecha's daprd,
# and mecha's database image, which stages the ledger's initdb steps.
const airlock_image = "ghcr.io/bsoneca/mecha-airlock:0.22.0-host.3@sha256:3e41f77dd45922b5a0f38d21a1c69f21d751debf6f2ee717daa11b77c8f210f0"
const mesh_image = "bonitao/mecha-mesh:0.22.0@sha256:8d39aa3543560232c52330152ba70a4d2c973b76d0ac97899d677704bc0e09a4"
const ledger_image = "bonitao/mecha-database:0.22.0@sha256:ed58b6be6cd69658fbb4e6daff1f91b8923b333f364905c4dacdec2974a05d82"
const door_port = 9998
# The keys the airlock holds instead of the broker, by the door each is the credential of.
const door_keys = [
	{door: "stripe", var: "STRIPE_SECRET_KEY"}
	{door: "stripe-sandbox", var: "STRIPE_SANDBOX_SECRET_KEY"}
]
# A ConfigMap's keys hold dots, which a cell path would split: look each up whole.
def at [key: string]: record -> string { transpose k v | where k == $key | get v.0 }
# The broker's files as the image sees them under /app/billing, each a ConfigMap key.
const files = [
	{key: "shared.ts", from: "shared.ts", path: "shared.ts"}
	{key: "main.ts", from: "broker/main.ts", path: "broker/main.ts"}
	{key: "core.ts", from: "broker/core.ts", path: "broker/core.ts"}
	{key: "stripe.ts", from: "broker/stripe.ts", path: "broker/stripe.ts"}
	{key: "fake.ts", from: "broker/fake.ts", path: "broker/fake.ts"}
]
# Each variable the Secret `<name>` holds, and the Secret Manager secret it is read from (<service>-<suffix>).
const live_secrets = [
	{var: "BROKER_SECRET", suffix: "secret"}
	{var: "BILLING_SIGNING_KEY", suffix: "signing-key"}
	{var: "STRIPE_SECRET_KEY", suffix: "stripe-key"}
	{var: "STRIPE_WEBHOOK_SECRET", suffix: "webhook-secret"}
]
const sandbox_secrets = [
	{var: "STRIPE_SANDBOX_SECRET_KEY", suffix: "sandbox-stripe-key"}
	{var: "STRIPE_SANDBOX_WEBHOOK_SECRET", suffix: "sandbox-webhook-secret"}
]

# Every object the broker is on a metal cluster, as YAML documents. `sources` holds each file's text by
# its key; `settings` the broker's plain env; `secrets` the variables its Secret `<name>` holds.
export def manifests [
	--domain: string
	--sources: record
	--settings: list<record> = []
	--secrets: list<string> = []
	--namespace: string = "billing"
	--name: string = "billing-broker"
	--airlock # Stripe through the airlock's door: the airlock holds the Stripe keys, the broker none
]: nothing -> string {
	let labels = {"app.kubernetes.io/name": $name, "app.kubernetes.io/part-of": "pronto-billing"}
	let lock = $"($name)-airlock"
	let lock_labels = {"app.kubernetes.io/name": $lock, "app.kubernetes.io/part-of": "pronto-billing"}
	# Through the door, the broker's env names no Stripe key, and the airlock's names those it holds.
	let held = if $airlock { $door_keys | where {|k| $k.var in $secrets } } else { [] }
	let secrets = ($secrets | where {|v| $v not-in ($held | get var) })
	let settings = ($settings ++ (if $airlock { [{name: "STRIPE_DOOR", value: $"http://($lock):($door_port)"}] } else { [] }))
	let meta = {namespace: $namespace, labels: $labels}
	# A change to a file is a new pod: the files' digest is the template's.
	let digest = ($files | each {|f| $sources | at $f.key } | str join "\n" | hash sha256 | str substring 0..15)
	# The addresses no public service has: what the broker never needs to reach.
	let private = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]
	[
		{apiVersion: "v1", kind: "Namespace", metadata: {name: $namespace, labels: $labels}}
		{apiVersion: "v1", kind: "ConfigMap", metadata: ($meta | insert name $"($name)-files"), data: ($files | reduce -f {} {|f, acc| $acc | merge {($f.key): ($sources | at $f.key)} })}
		{
			apiVersion: "apps/v1", kind: "Deployment", metadata: ($meta | insert name $name)
			spec: {
				replicas: 1
				# An entitlement's `ver` is the broker's clock: never two at once.
				strategy: {type: "Recreate"}
				selector: {matchLabels: $labels}
				template: {
					metadata: {labels: $labels, annotations: {"pronto.dev/files": $digest}}
					spec: {
						automountServiceAccountToken: false
						securityContext: {runAsNonRoot: true, runAsUser: 1993, runAsGroup: 1993, seccompProfile: {type: "RuntimeDefault"}}
						containers: [{
							name: "broker"
							image: $deno
							args: ["run" "--allow-net" "--allow-env" "--allow-read=/app" "--allow-write=/deno-dir" "/app/billing/broker/main.ts"]
							ports: [{name: "http", containerPort: $port}]
							env: ([
								{name: "PORT", value: ($port | into string)}
								{name: "DENO_DIR", value: "/deno-dir"}
								{name: "BROKER_ISSUER", value: $"https://($domain)"}
							] ++ $settings ++ ($secrets | each {|v| {name: $v, valueFrom: {secretKeyRef: {name: $name, key: $v}}} }))
							securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
							resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {memory: "256Mi"}}
							startupProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 1, failureThreshold: 60}
							readinessProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 10}
							livenessProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 20, failureThreshold: 3}
							volumeMounts: [
								{name: "files", mountPath: "/app/billing", readOnly: true}
								{name: "deno-dir", mountPath: "/deno-dir"}
								{name: "tmp", mountPath: "/tmp"}
							]
						}]
						volumes: [
							{name: "files", configMap: {name: $"($name)-files", items: ($files | each {|f| {key: $f.key, path: $f.path} })}}
							{name: "deno-dir", emptyDir: {}}
							{name: "tmp", emptyDir: {}}
						]
					}
				}
			}
		}
		{apiVersion: "v1", kind: "Service", metadata: ($meta | insert name $name), spec: {selector: $labels, ports: [{name: "http", port: $port, targetPort: $port}]}}
		# Behind the node's tunnel: Cloudflare holds the certificate, Envoy routes by host.
		{
			apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: ($meta | insert name $name)
			spec: {gatewayClassName: "eg", listeners: [{name: "http", protocol: "HTTP", port: 80, hostname: $domain, allowedRoutes: {namespaces: {from: "Same"}}}]}
		}
		{
			apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute", metadata: ($meta | insert name $name)
			spec: {
				parentRefs: [{name: $name}]
				hostnames: [$domain]
				rules: [{matches: [{path: {type: "PathPrefix", value: "/"}}], backendRefs: [{name: $name, port: $port}]}]
			}
		}
		# Nothing in or out but what it serves and what it asks: requests on its port, DNS, and HTTPS to
		# public addresses (Stripe, and each app's origin it pushes entitlements to). PRONTO-135's airlock
		# takes the HTTPS over later.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($meta | insert name $name)
			spec: {
				podSelector: {matchLabels: $labels}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{ports: [{protocol: "TCP", port: $port}]}]
				egress: ([
					{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				] ++ (if $airlock { [{to: [{podSelector: {matchLabels: $lock_labels}}], ports: [{protocol: "TCP", port: $door_port}]}] } else { [] }))
			}
		}
	] ++ (if $airlock { airlock-objects $namespace $lock $lock_labels $labels $name ($held | get door) ($held | get var) } else { [] })
	| each { to yaml } | str join "---\n"
}

# The airlock beside the broker: one pod of the airlock, its daprd and its ledger's Postgres, which
# only the broker reaches, on the door's port. Each door is a Stripe key's: the airlock reads the key
# from the broker's Secret and adds it to every call; the broker's pod names none of them. Every call
# is a row of the ledger (mecha's services/airlock/README.md, "A door").
def airlock-objects [namespace: string, name: string, labels: record, caller_labels: record, caller: string, doors: list<string>, vars: list<string>]: nothing -> list<record> {
	let meta = {namespace: $namespace, labels: $labels}
	let manifest = {
		effects: {}
		doors: ($doors | zip $vars | reduce -f {} {|d, acc| $acc | insert $d.0 {
			idempotent: true
			credential: {header: "Authorization", scheme: "Bearer", secret: $d.1}
			headers: ["Stripe-Version"]
			callers: [$caller]
		}})
	}
	# The daprd's wall and breaker, as mecha's cluster writes them for its effects (cluster.cue's
	# #AirlockWall and #AirlockResiliency), and one HTTPEndpoint per door.
	let wall = {
		apiVersion: "dapr.io/v1alpha1", kind: "Component", metadata: {name: "wall"}
		spec: {type: "middleware.http.routerchecker", version: "v1", metadata: [{name: "rule", value: $"^/v1[.]0/\(healthz\(/outbound\)?|invoke/\(($doors | str join '|')\)/method/.*\)$"}]}
	}
	let resiliency = {
		apiVersion: "dapr.io/v1alpha1", kind: "Resiliency", metadata: {name: "airlock"}
		spec: {
			policies: {circuitBreakers: {sink: {maxRequests: 1, interval: "60s", timeout: "30s", trip: "consecutiveFailures >= 10"}}}
			targets: {apps: ($doors | reduce -f {} {|d, acc| $acc | insert $d {circuitBreaker: "sink"} })}
		}
	}
	let endpoints = ($doors | each {|d| {key: $"($d).yaml", value: ({apiVersion: "dapr.io/v1alpha1", kind: "HTTPEndpoint", metadata: {name: $d}, spec: {baseUrl: "https://api.stripe.com"}} | to yaml)} })
	let components = ([{key: "wall.yaml", value: ($wall | to yaml)} {key: "resiliency.yaml", value: ($resiliency | to yaml)}] ++ $endpoints | reduce -f {} {|c, acc| $acc | insert $c.key $c.value })
	let digest = ([($manifest | to json) ($components | to json)] | str join "\n" | hash sha256 | str substring 0..15)
	let private = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]
	let restricted = {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
	[
		{apiVersion: "v1", kind: "ConfigMap", metadata: ($meta | insert name $"($name)-effects"), data: {"effects.json": ($manifest | to json)}}
		{apiVersion: "v1", kind: "ConfigMap", metadata: ($meta | insert name $"($name)-dapr"), data: $components}
		# The ledger outlives the pod: the record of every call made outside.
		{apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: ($meta | insert name $"($name)-ledger"), spec: {accessModes: ["ReadWriteOnce"], resources: {requests: {storage: "1Gi"}}}}
		{
			apiVersion: "apps/v1", kind: "Deployment", metadata: ($meta | insert name $name)
			spec: {
				replicas: 1
				strategy: {type: "Recreate"}
				selector: {matchLabels: $labels}
				template: {
					metadata: {labels: $labels, annotations: {"pronto.dev/config": $digest}}
					spec: {
						automountServiceAccountToken: false
						securityContext: {seccompProfile: {type: "RuntimeDefault"}}
						initContainers: [
							# mecha's own steps: Graphile's schema, then the ledger (with the ticker's schedule table it
							# seeds); and the airlock daprd's configuration, from the airlock's image.
							{
								name: "steps", image: $ledger_image, securityContext: $restricted
								command: ["sh" "-c" "cp /usr/share/mecha/initdb/011_graphile_worker.sql /usr/share/mecha/initdb/012_airlock.sql /initdb/"]
								volumeMounts: [{name: "initdb", mountPath: "/initdb"}]
							}
							{
								name: "config", image: $airlock_image, securityContext: $restricted
								command: ["sh" "-c" "cp /app/airlock/dapr.yaml /dapr-config/config.yaml"]
								volumeMounts: [{name: "dapr-config", mountPath: "/dapr-config"}]
							}
						]
						containers: [
							{
								name: "ledger", image: $ledger_image
								args: ["postgres" "-c" "listen_addresses=127.0.0.1" "-c" "shared_buffers=32MB" "-c" "max_connections=20"]
								env: [
									{name: "POSTGRES_USER", value: "airlock"} {name: "POSTGRES_DB", value: "airlock"}
									# Only this pod's own loopback reaches it.
									{name: "POSTGRES_HOST_AUTH_METHOD", value: "trust"}
									{name: "PGDATA", value: "/var/lib/postgresql/data/pgdata"}
								]
								resources: {requests: {cpu: "20m", memory: "64Mi"}, limits: {memory: "256Mi"}}
								readinessProbe: {exec: {command: ["pg_isready" "-h" "127.0.0.1" "-U" "airlock"]}, periodSeconds: 5}
								volumeMounts: [{name: "ledger", mountPath: "/var/lib/postgresql/data"} {name: "initdb", mountPath: "/docker-entrypoint-initdb.d", readOnly: true}]
							}
							{
								name: "mesh", image: $mesh_image, securityContext: $restricted
								command: ["/daprd"]
								args: ["--app-id" "airlock" "--dapr-listen-addresses" "127.0.0.1" "--resources-path" "/dapr/airlock" "--config" "/dapr-config/config.yaml" "--dapr-http-port" "3500" "--metrics-port" "0" "--profile-port" "0" "--log-level" "info"]
								resources: {requests: {cpu: "20m", memory: "48Mi"}, limits: {memory: "192Mi"}}
								volumeMounts: [{name: "dapr", mountPath: "/dapr/airlock", readOnly: true} {name: "dapr-config", mountPath: "/dapr-config", readOnly: true}]
							}
							{
								name: "airlock", image: $airlock_image, securityContext: $restricted
								workingDir: "/app/airlock"
								args: ["run" "--frozen" "--unstable-worker-options" "--allow-net=127.0.0.1:5432,127.0.0.1:3500,0.0.0.0:9997,0.0.0.0:9998" "--allow-read" "--allow-env" "--allow-sys" "main.ts"]
								ports: [{name: "door", containerPort: $door_port}]
								env: ([
									{name: "DATABASE_URL", value: "postgres://airlock@127.0.0.1:5432/airlock"}
									{name: "MESH_URL", value: "http://127.0.0.1:3500"}
									{name: "AIRLOCK_DIR", value: "/airlock"}
								] ++ ($vars | each {|v| {name: $v, valueFrom: {secretKeyRef: {name: $caller, key: $v}}} }))
								resources: {requests: {cpu: "20m", memory: "96Mi"}, limits: {memory: "384Mi"}}
								startupProbe: {httpGet: {path: "/healthz", port: 9997}, periodSeconds: 2, failureThreshold: 90}
								readinessProbe: {tcpSocket: {port: $door_port}, periodSeconds: 10}
								volumeMounts: [{name: "effects", mountPath: "/airlock", readOnly: true}]
							}
						]
						volumes: [
							{name: "ledger", persistentVolumeClaim: {claimName: $"($name)-ledger"}}
							{name: "initdb", emptyDir: {}}
							{name: "dapr-config", emptyDir: {}}
							{name: "dapr", configMap: {name: $"($name)-dapr"}}
							{name: "effects", configMap: {name: $"($name)-effects"}}
						]
					}
				}
			}
		}
		{apiVersion: "v1", kind: "Service", metadata: ($meta | insert name $name), spec: {selector: $labels, ports: [{name: "door", port: $door_port, targetPort: $door_port}]}}
		# The door's port from the broker alone; out, DNS and HTTPS to public addresses (Stripe).
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($meta | insert name $name)
			spec: {
				podSelector: {matchLabels: $labels}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{from: [{podSelector: {matchLabels: $caller_labels}}], ports: [{protocol: "TCP", port: $door_port}]}]
				egress: [
					{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				]
			}
		}
	]
}

# The broker's files from this checkout, by their ConfigMap keys.
export def sources []: nothing -> record {
	$files | reduce -f {} {|f, acc| $acc | merge {($f.key): (open --raw $"($here)/($f.from)")} }
}

# gcloud on the Python pinned beside it (release.nu says why).
def gc-secret [name: string, project: string]: nothing -> string {
	let r = (with-env {CLOUDSDK_PYTHON: python3.12, CLOUDSDK_PYTHON_SITEPACKAGES: "0"} { ^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet secrets versions access latest --secret $name --project $project | complete })
	if $r.exit_code != 0 { error make {msg: $"gcloud secrets versions access ($name): ($r.stderr | str trim)"} }
	let v = ($r.stdout | str trim --right --char "\n")
	if ($v | is-empty) or ($v | str contains "\n") { error make {msg: $"($name) is empty or spans lines, which an env file cannot hold"} }
	$v
}

export def main [
	--ssh: string                  # The node, as the app's envs.Metal names it: bruno@13.140.186.223
	--kubeconfig: string = "$HOME/.cache/contabo2.kubeconfig" # On the node
	--domain: string               # Where the broker answers, its issuer: billing.example.com
	--project: string = ""         # The Google Cloud project whose Secret Manager holds the broker's secrets
	--secrets: string = ""         # Or the SOPS file holding the Secret <service>, in a pronto checkout (its services/billing-broker/secrets.metal.enc.yaml)
	--fee: int = 0                 # The share of each payment the platform keeps, in percent
	--sandbox-tenants: string = "" # As release.nu: the tenants that buy through Stripe's sandbox
	--namespace: string = "billing"
	--service: string = "billing-broker" # The secrets' names in Secret Manager are <service>-<suffix>, as release.nu stores them
	--airlock # Stripe through the airlock's door beside the broker, which then holds no Stripe key (PRONTO-135)
] {
	if ([$ssh $domain] | any { is-empty }) { error make {msg: "--ssh and --domain are both required"} }
	if ($project | is-empty) == ($secrets | is-empty) { error make {msg: "name where the secrets are: --secrets <file>, or --project <Secret Manager's project>"} }
	if not ($fee >= 0 and $fee < 100) { error make {msg: "--fee is a percentage under 100"} }
	let sandbox = ($sandbox_tenants | is-not-empty)
	let keys = ($live_secrets ++ (if $sandbox { $sandbox_secrets } else { [] }))
	let settings = ([{name: "BILLING_FEE_PERCENT", value: ($fee | into string)}] ++ (if $sandbox { [{name: "BILLING_SANDBOX_TENANTS", value: $sandbox_tenants}] } else { [] }))
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	let yaml = (manifests --domain $domain --sources (sources) --settings $settings --secrets ($keys | get var) --namespace $namespace --name $service --airlock=$airlock)
	# The namespace first, so the Secret has somewhere to go before the pod that reads it.
	$"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ($namespace)\n" | do $remote $"($kubectl) apply -f -" | print
	# The secrets through ssh's stdin alone: never a file, never an argument.
	if ($secrets | is-not-empty) {
		sops decrypt $secrets | sops secret-manifests $service $namespace ($keys | get var) | do $remote (sops apply-command $kubectl $namespace) | print
	} else {
		let secret_env = ($keys | each {|s| $"($s.var)=(gc-secret $"($service)-($s.suffix)" $project)" } | str join "\n")
		$"($secret_env)\n" | do $remote $"($kubectl) create secret generic ($service) -n ($namespace) --from-env-file=/dev/stdin --dry-run=client -o yaml | ($kubectl) apply -f -" | print
	}
	$yaml | do $remote $"($kubectl) apply -f -" | print
	if $airlock {
		do $remote $"($kubectl) rollout restart deployment/($service)-airlock -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service)-airlock -n ($namespace) --timeout=300s" | print
	}
	do $remote $"($kubectl) rollout restart deployment/($service) -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service) -n ($namespace) --timeout=120s" | print
	# Through the gateway as the tunnel reaches it, by host: the broker answers, signing with the key
	# the domain's current broker publishes.
	let gateway = (do $remote $"($kubectl) get svc -n envoy-gateway-system pronto-gateway -o jsonpath='{.spec.clusterIP}'" | str trim)
	let health = (do $remote $"curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' -H 'Host: ($domain)' http://($gateway)/health" | str trim)
	if $health != "200" { error make {msg: $"the broker behind the gateway answered ($health) on /health"} }
	let node_keys = (do $remote $"curl -fsS --max-time 10 -H 'Host: ($domain)' http://($gateway)/jwks" | from json | get keys.kid)
	let live_keys = (http get $"https://($domain)/jwks" | get keys.kid)
	if $node_keys != $live_keys { error make {msg: $"the node's broker signs with ($node_keys | str join ','), https://($domain) with ($live_keys | str join ',')"} }
	print $"billing: the broker answers on the node for ($domain) behind the gateway, signing with ($node_keys | str join ','); point ($domain) at the tunnel to serve it"
}
