# Releases the billing broker to a cluster the operator runs (pronto's envs.Metal: k3s on a node
# reached over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway),
# beside release.nu's Cloud Run, in the shape identity/metal.nu gives the identity broker:
#   bin/pronto-billing-broker metal --ssh bruno@node --domain D --secrets F (or --project P) [--fee N] [--sandbox-tenants RE] [--door-asked]
#
# The broker imports nothing from outside its own files, so no image is built: the pinned Deno image
# runs shared.ts and broker/*.ts from a ConfigMap. It keeps nothing but its secrets: with --secrets,
# the Secret's manifest in a SOPS file (common/sops.nu, PRONTO-155); else read with the operator's
# gcloud from the project's Secret Manager, as Cloud Run's release keeps them. Either way they are
# piped into a Secret on the node, never written to a file: the same signing key, so the entitlements it
# signs verify as Cloud Run's did, and the same webhook secret, so Stripe's one webhook
# (https://<domain>/stripe) is accepted by whichever of the two the name points at. An
# entitlement's `ver` is its clock: one replica, replaced (Recreate) rather than overlapped.
#
# Stripe only through the airlock's door (PRONTO-270): the airlock beside the broker is always made, and
# holds the Stripe keys the secrets hold, a door each; the broker holds none (but while --door-asked
# moves it, PRONTO-218). Secrets with no Stripe key give a broker with no door, which only serves
# the stand-in on a localhost issuer.

const here = path self .
use ../common/sops.nu
use ../common/airlock.nu [airlock-objects door_port]
const deno = "denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e"
const port = 8080
# The keys the airlock holds instead of the broker, by the door each is the credential of.
const door_keys = [
	{door: "stripe", var: "STRIPE_SECRET_KEY", base: "https://api.stripe.com", scheme: "Bearer", headers: ["Stripe-Version"]}
	{door: "stripe-sandbox", var: "STRIPE_SANDBOX_SECRET_KEY", base: "https://api.stripe.com", scheme: "Bearer", headers: ["Stripe-Version"]}
]
# A ConfigMap's keys hold dots, which a cell path would split: look each up whole.
def at [key: string]: record -> string { transpose k v | where k == $key | get v.0 }
# The broker's files as the image sees them under /app/billing, each a ConfigMap key.
const files = [
	{key: "shared.ts", from: "shared.ts", path: "shared.ts"}
	{key: "main.ts", from: "broker/main.ts", path: "broker/main.ts"}
	{key: "core.ts", from: "broker/core.ts", path: "broker/core.ts"}
	{key: "stripe.ts", from: "broker/stripe.ts", path: "broker/stripe.ts"}
	{key: "door.ts", from: "broker/door.ts", path: "broker/door.ts"}
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
	--door-asked # While it moves (PRONTO-218): each call through the door when its tenant asks (its flag), the broker keeping its keys
]: nothing -> string {
	let labels = {"app.kubernetes.io/name": $name, "app.kubernetes.io/part-of": "pronto-billing"}
	let lock = $"($name)-airlock"
	let lock_labels = {"app.kubernetes.io/name": $lock, "app.kubernetes.io/part-of": "pronto-billing"}
	# Through the door, the broker's env names no Stripe key, and the airlock's names those it holds.
	let held = ($door_keys | where {|k| $k.var in $secrets })
	let doors = ($held | is-not-empty)
	if $door_asked and not $doors { error make {msg: "--door-asked moves the broker between its Stripe key and the door: the secrets hold no Stripe key"} }
	# While the flag moves it, the broker keeps its keys beside the door; after, the airlock alone holds them.
	let secrets = if $door_asked { $secrets } else { $secrets | where {|v| $v not-in ($held | get var) } }
	let settings = ($settings ++ (if $doors { [{name: "STRIPE_DOOR", value: $"http://($lock):($door_port)"}] } else { [] })
		++ (if $door_asked { [{name: "STRIPE_DOOR_ASKED", value: "1"}] } else { [] }))
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
		# public addresses (each app's origin it pushes entitlements to), and the airlock's door, the
		# broker's one way to Stripe (PRONTO-270; PRONTO-220 guards against any other).
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($meta | insert name $name)
			spec: {
				podSelector: {matchLabels: $labels}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{ports: [{protocol: "TCP", port: $port}]}]
				egress: ([
					{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				] ++ [{to: [{podSelector: {matchLabels: $lock_labels}}], ports: [{protocol: "TCP", port: $door_port}]}])
			}
		}
	] ++ (airlock-objects $namespace $lock $lock_labels $labels $name $held)
	| each { to yaml } | str join "---\n"
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
	--door-asked # Each call through the door when its tenant asks (the app's flag, told by its billing service); the broker keeps its keys until a deploy without it (PRONTO-218)
] {
	if ([$ssh $domain] | any { is-empty }) { error make {msg: "--ssh and --domain are both required"} }
	if ($project | is-empty) == ($secrets | is-empty) { error make {msg: "name where the secrets are: --secrets <file>, or --project <Secret Manager's project>"} }
	if not ($fee >= 0 and $fee < 100) { error make {msg: "--fee is a percentage under 100"} }
	let sandbox = ($sandbox_tenants | is-not-empty)
	let keys = ($live_secrets ++ (if $sandbox { $sandbox_secrets } else { [] }))
	let settings = ([{name: "BILLING_FEE_PERCENT", value: ($fee | into string)}] ++ (if $sandbox { [{name: "BILLING_SANDBOX_TENANTS", value: $sandbox_tenants}] } else { [] }))
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	let yaml = (manifests --domain $domain --sources (sources) --settings $settings --secrets ($keys | get var) --namespace $namespace --name $service --door-asked=$door_asked)
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
	do $remote $"($kubectl) rollout restart deployment/($service)-airlock -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service)-airlock -n ($namespace) --timeout=300s" | print
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
