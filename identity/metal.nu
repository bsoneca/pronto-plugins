# Releases the identity broker to a cluster the operator runs (pronto's envs.Metal: k3s on a node
# reached over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway),
# beside release.nu's Cloud Run:
#   bin/pronto-identity-broker metal --ssh bruno@node --domain D --google-client-id C --secrets F (or --project P) [--airlock [--door-asked --door-tenants T]]
#
# The broker imports nothing from outside its own files, so no image is built: the pinned Deno image
# runs oidc.ts, broker/*.ts and the one vendored Postgres client from a ConfigMap. What it keeps between
# requests (its one-time codes, the phone's visits and counts, its signing keys) is in a Postgres of its
# own, `<name>-db` (a CloudNativePG cluster, its login generated in the cluster as errors/metal.nu's is),
# which the broker reaches by DATABASE_URL; any replica answers any request (broker/store.ts, PRONTO-371).
# Its other kept state is BROKER_SECRET: with --secrets, the Secret's manifest in a SOPS file
# (common/sops.nu, PRONTO-155); else read with the operator's gcloud from the project's Secret Manager,
# as Cloud Run's release keeps it. Either way it is piped into a Secret on the node, never written to a
# file: the same value, so the subjects it vouches for and the codes it signs stay the same across the move.

const here = path self .
use ../common/sops.nu
use ../common/airlock.nu [airlock-objects door_port]
use ../common/broker_db.nu
const deno = "denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e"
const port = 8080
# The broker's replicas. One until the scaling change (PRONTO-371): with the store, the rollout below
# could overlap them, so a Recreate is no longer needed for the codes' sake.
const replicas = 1
# The credential the airlock holds instead of the broker (--airlock, PRONTO-268): Google's token
# endpoint takes the client's id and secret as client_secret_basic, which the airlock adds as the
# Authorization header, `Basic <GOOGLE_CLIENT_BASIC>`: base64 of `<client id>:<client secret>`.
const door_keys = [
	{door: "google", var: "GOOGLE_CLIENT_BASIC", base: "https://oauth2.googleapis.com", scheme: "Basic", headers: []}
]
# The broker's files as the image sees them under /app, each a ConfigMap key.
# A ConfigMap's keys hold dots, which a cell path would split: look each up whole.
def at [key: string]: record -> string { transpose k v | where k == $key | get v.0 }
const files = [
	{key: "oidc.ts", from: "oidc.ts", path: "oidc.ts"}
	{key: "main.ts", from: "broker/main.ts", path: "broker/main.ts"}
	{key: "core.ts", from: "broker/core.ts", path: "broker/core.ts"}
	{key: "phone.ts", from: "broker/phone.ts", path: "broker/phone.ts"}
	{key: "otp.ts", from: "broker/otp.ts", path: "broker/otp.ts"}
	{key: "door.ts", from: "broker/door.ts", path: "broker/door.ts"}
	{key: "store.ts", from: "broker/store.ts", path: "broker/store.ts"}
	{key: "postgres.js", from: "broker/vendor/postgres.js", path: "broker/vendor/postgres.js"}
]

# Every object the broker is on a metal cluster, as YAML documents. `sources` holds each file's text by
# its key; `settings` the broker's plain env (its secrets come from the Secret `<name>`).
export def manifests [
	--domain: string
	--sources: record
	--settings: list<record> = []
	--namespace: string = "identity"
	--name: string = "identity-broker"
	--database-only # Only the namespace and the broker's database, which a release brings up before the broker is replaced
	--airlock # Google's token exchange through the airlock's door: the airlock holds the client's credential, the broker no secret
	--door-asked # With --airlock, while it moves (PRONTO-268): each exchange through the door when its tenant asks (its flag signin_door), the broker keeping its secret
	--door-tenants: string = "" # With --door-asked: the tenants whose flag is asked, PHONE_TENANTS' syntax; every other tenant goes straight to Google, unasked
]: nothing -> string {
	let labels = {"app.kubernetes.io/name": $name, "app.kubernetes.io/part-of": "pronto-identity"}
	let lock = $"($name)-airlock"
	let lock_labels = {"app.kubernetes.io/name": $lock, "app.kubernetes.io/part-of": "pronto-identity"}
	if $door_asked and not $airlock { error make {msg: "--door-asked moves the broker to the airlock's door: it needs --airlock"} }
	# Only the tenants listed are asked: an app on the broker with no signin_door (or no /ofrep/) would fail every sign-in.
	if $door_asked and ($door_tenants | is-empty) { error make {msg: "--door-asked needs --door-tenants: the tenants whose flag signin_door is asked"} }
	if ($door_tenants | is-not-empty) and not $door_asked { error make {msg: "--door-tenants is for --door-asked"} }
	# Through the door the broker's env names no client secret, and the airlock's names the credential it holds.
	# While the flag moves it, the broker keeps its secret beside the door; after, the airlock alone holds it.
	let secret_vars = if $airlock and not $door_asked { [BROKER_SECRET] } else { [BROKER_SECRET GOOGLE_CLIENT_SECRET] }
	let settings = ($settings ++ (if $airlock { [{name: "GOOGLE_DOOR", value: $"http://($lock):($door_port)"}] } else { [] })
		++ (if $door_asked { [{name: "GOOGLE_DOOR_ASKED", value: "1"} {name: "GOOGLE_DOOR_TENANTS", value: $door_tenants}] } else { [] }))
	let meta = {namespace: $namespace, labels: $labels}
	# The broker's database (common/broker_db.nu).
	let db = $"($name)-db"
	let database = (broker_db objects $namespace $db "pronto-identity" "identity" $labels)
	if $database_only { return ([{apiVersion: "v1", kind: "Namespace", metadata: {name: $namespace, labels: $labels}}] ++ $database | each { to yaml } | str join "---\n") }
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
				replicas: $replicas
				# Once, a code minted by the old pod was unknown to the new one, so never two at once. The store
				# (DATABASE_URL) keeps them now and the reason is gone; the strategy changes with the scaling.
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
							args: ["run" "--allow-net" "--allow-env" "--allow-read=/app" "--allow-write=/deno-dir" "/app/broker/main.ts"]
							ports: [{name: "http", containerPort: $port}]
							env: ([
								{name: "PORT", value: ($port | into string)}
								{name: "DENO_DIR", value: "/deno-dir"}
								{name: "BROKER_ISSUER", value: $"https://($domain)"}
							] ++ ($secret_vars | each {|v| {name: $v, valueFrom: {secretKeyRef: {name: $name, key: $v}}} })
								++ [(broker_db url-env $db)] ++ $settings)
							securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
							resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {memory: "256Mi"}}
							startupProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 1, failureThreshold: 60}
							readinessProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 10}
							livenessProbe: {httpGet: {path: "/health", port: $port}, periodSeconds: 20, failureThreshold: 3}
							volumeMounts: [
								{name: "files", mountPath: "/app", readOnly: true}
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
		# public addresses (Google's OpenID Connect and keys, Identity Platform), as an app's auth has it
		# (<app>-auth-oidc-egress).
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($meta | insert name $name)
			spec: {
				podSelector: {matchLabels: $labels}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{ports: [{protocol: "TCP", port: $port}]}]
				egress: ([
					{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
					(broker_db egress $db)
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				] ++ (if $airlock { [{to: [{podSelector: {matchLabels: $lock_labels}}], ports: [{protocol: "TCP", port: $door_port}]}] } else { [] }))
			}
		}
	] ++ $database ++ (if $airlock { airlock-objects $namespace $lock $lock_labels $labels $name $door_keys } else { [] })
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
	$r.stdout
}

export def main [
	--ssh: string                  # The node, as the app's envs.Metal names it: bruno@13.140.186.223
	--kubeconfig: string = "$HOME/.cache/contabo2.kubeconfig" # On the node
	--domain: string               # Where the broker answers, its issuer: id.example.com
	--google-client-id: string     # The operator's Google client, registered for https://<domain>/callback/google
	--project: string = ""         # The Google Cloud project whose Secret Manager holds the broker's secrets
	--secrets: string = ""         # Or the SOPS file holding the Secret <service>, in a pronto checkout (its services/identity-broker/secrets.metal.enc.yaml)
	--phone-project: string = ""   # As release.nu: the Firebase project that texts the phone's codes; none, no phone
	--phone-api-key: string = ""
	--phone-app-id: string = ""
	--phone-admit: string = ""
	--phone-tenants: string = ""
	--phone-otp: string = "firebase" # As release.nu: firebase, or broker (then --phone-sms and --phone-sms-gate)
	--phone-sms: string = ""
	--phone-sms-gate: string = ""
	--phone-prove-tenants: string = "" # With --phone-otp broker: the origins that may learn a proven number (the prove step); none, off
	--sectors: string = ""         # Apps that moved address, each keeping its people's subjects: https://new=https://old, comma separated (broker/core.ts sectorsOf); none, every app is its own sector
	--namespace: string = "identity"
	--service: string = "identity-broker" # The secrets' names in Secret Manager are <service>-secret and <service>-google-client-secret
	--airlock # Google's token exchange through the airlock's door beside the broker, which then holds no client secret (PRONTO-268); its Secret also holds GOOGLE_CLIENT_BASIC
	--door-asked # With --airlock: each exchange through the door when its tenant asks (the app's flag signin_door); the broker keeps its secret until a deploy without it
	--door-tenants: string = "" # With --door-asked: the tenants whose flag is asked (comma separated, `*` for a port); the others go straight to Google
] {
	if ([$ssh $domain $google_client_id] | any { is-empty }) { error make {msg: "--ssh, --domain and --google-client-id are all required"} }
	if ($project | is-empty) == ($secrets | is-empty) { error make {msg: "name where the secrets are: --secrets <file>, or --project <Secret Manager's project>"} }
	let phone = if $phone_otp == "broker" {
		if ([$phone_sms $phone_sms_gate $phone_admit $phone_tenants] | any { is-empty }) {
			error make {msg: "--phone-otp broker needs --phone-sms, --phone-sms-gate, --phone-admit and --phone-tenants"}
		}
		if ($phone_project | is-not-empty) { error make {msg: "--phone-project is for --phone-otp firebase"} }
		[
			{name: "PHONE_OTP", value: "broker"}
			{name: "PHONE_SMS", value: $phone_sms}
			{name: "PHONE_SMS_GATE", value: $phone_sms_gate}
			{name: "PHONE_ADMIT", value: $phone_admit}
			{name: "PHONE_TENANTS", value: $phone_tenants}
		] ++ (if ($phone_prove_tenants | is-empty) { [] } else { [{name: "PHONE_PROVE_TENANTS", value: $phone_prove_tenants}] })
	} else if $phone_otp != "firebase" {
		error make {msg: "--phone-otp is firebase or broker"}
	} else if ($phone_project | is-empty) { [] } else {
		if ([$phone_api_key $phone_app_id $phone_admit $phone_tenants] | any { is-empty }) {
			error make {msg: "--phone-project needs --phone-api-key, --phone-app-id, --phone-admit and --phone-tenants"}
		}
		[
			{name: "PHONE_PROJECT", value: $phone_project}
			{name: "PHONE_API_KEY", value: $phone_api_key}
			{name: "PHONE_APP_ID", value: $phone_app_id}
			{name: "PHONE_ADMIT", value: $phone_admit}
			{name: "PHONE_TENANTS", value: $phone_tenants}
		]
	}
	let keys = ([BROKER_SECRET GOOGLE_CLIENT_SECRET] ++ (if $airlock { [GOOGLE_CLIENT_BASIC] } else { [] }))
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	# A malformed list stops the broker at start, so the rollout below fails rather than serve new subjects.
	let sector = if ($sectors | is-empty) { [] } else { [{name: "BROKER_SECTORS", value: $sectors}] }
	let yaml = (manifests --domain $domain --sources (sources) --settings ([{name: "GOOGLE_CLIENT_ID", value: $google_client_id}] ++ $phone ++ $sector) --namespace $namespace --name $service --airlock=$airlock --door-asked=$door_asked --door-tenants=$door_tenants)
	# The namespace first, so the Secret has somewhere to go before the pod that reads it.
	$"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ($namespace)\n" | do $remote $"($kubectl) apply -f -" | print
	# The secrets through ssh's stdin alone: never a file, never an argument.
	if ($secrets | is-not-empty) {
		sops decrypt $secrets | sops secret-manifests $service $namespace $keys | do $remote (sops apply-command $kubectl $namespace) | print
	} else {
		let client_secret = (gc-secret $"($service)-google-client-secret" $project)
		# The credential the airlock adds, made here from the client's id and secret, never stored.
		let pair = $"($google_client_id):($client_secret | str trim --right --char (char nl))"
		let basic = if $airlock { $"GOOGLE_CLIENT_BASIC=($pair | encode base64)\n" } else { "" }
		let secret_env = $"BROKER_SECRET=(gc-secret $"($service)-secret" $project)\nGOOGLE_CLIENT_SECRET=($client_secret)\n($basic)"
		$secret_env | do $remote $"($kubectl) create secret generic ($service) -n ($namespace) --from-env-file=/dev/stdin --dry-run=client -o yaml | ($kubectl) apply -f -" | print
	}
	# The broker's database first, and its wait: the broker is replaced only once what it keeps is there to read
	# (its login's Secret is made in the cluster, then the cluster starts).
	manifests --database-only --domain $domain --sources (sources) --namespace $namespace --name $service | do $remote $"($kubectl) apply -f -" | print
	do $remote $"($kubectl) wait --for=condition=Ready cluster.postgresql.cnpg.io/($service)-db -n ($namespace) --timeout=300s" | print
	$yaml | do $remote $"($kubectl) apply -f -" | print
	if $airlock {
		do $remote $"($kubectl) rollout restart deployment/($service)-airlock -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service)-airlock -n ($namespace) --timeout=300s" | print
	}
	do $remote $"($kubectl) rollout restart deployment/($service) -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service) -n ($namespace) --timeout=120s" | print
	# Through the gateway as the tunnel reaches it, by host: the broker answers, under its own issuer.
	let gateway = (do $remote $"($kubectl) get svc -n envoy-gateway-system pronto-gateway -o jsonpath='{.spec.clusterIP}'" | str trim)
	let discovery = (do $remote $"curl -fsS --max-time 10 -H 'Host: ($domain)' http://($gateway)/.well-known/openid-configuration" | from json)
	if $discovery.issuer != $"https://($domain)" { error make {msg: $"the broker behind the gateway names issuer ($discovery.issuer), not https://($domain)"} }
	print $"identity: the broker answers on the node for ($domain) behind the gateway; point ($domain) at the tunnel to serve it"
}
