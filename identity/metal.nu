# Releases the identity broker to a cluster the operator runs (pronto's envs.Metal: k3s on a node
# reached over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway),
# beside release.nu's Cloud Run:
#   bin/pronto-identity-broker metal --ssh bruno@node --domain D --google-client-id C --project P
#
# The broker imports nothing from outside its own files, so no image is built: the pinned Deno image
# runs oidc.ts and broker/*.ts from a ConfigMap. Its one-time codes live in memory, so one replica,
# replaced (Recreate) rather than overlapped. Its only kept state is BROKER_SECRET, read with the
# operator's gcloud from the project's Secret Manager, as Cloud Run's release keeps it, and piped
# into a Secret on the node, never written to a file: the same value, so the subjects it vouches for
# and the codes it signs stay the same across the move.

const here = path self .
const deno = "denoland/deno:distroless-2.5.0@sha256:5c4530d4babe37ded3566803e9498e2b5d643b915cce701d8b7b82f87a86629e"
const port = 8080
# The broker's files as the image sees them under /app, each a ConfigMap key.
# A ConfigMap's keys hold dots, which a cell path would split: look each up whole.
def at [key: string]: record -> string { transpose k v | where k == $key | get v.0 }
const files = [
	{key: "oidc.ts", from: "oidc.ts", path: "oidc.ts"}
	{key: "main.ts", from: "broker/main.ts", path: "broker/main.ts"}
	{key: "core.ts", from: "broker/core.ts", path: "broker/core.ts"}
	{key: "phone.ts", from: "broker/phone.ts", path: "broker/phone.ts"}
]

# Every object the broker is on a metal cluster, as YAML documents. `sources` holds each file's text by
# its key; `settings` the broker's plain env (its secrets come from the Secret `<name>`).
export def manifests [
	--domain: string
	--sources: record
	--settings: list<record> = []
	--namespace: string = "identity"
	--name: string = "identity-broker"
]: nothing -> string {
	let labels = {"app.kubernetes.io/name": $name, "app.kubernetes.io/part-of": "pronto-identity"}
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
				# A code minted by the old pod is unknown to the new one: never two at once.
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
								{name: "BROKER_SECRET", valueFrom: {secretKeyRef: {name: $name, key: "BROKER_SECRET"}}}
								{name: "GOOGLE_CLIENT_SECRET", valueFrom: {secretKeyRef: {name: $name, key: "GOOGLE_CLIENT_SECRET"}}}
							] ++ $settings)
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
				egress: [
					{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				]
			}
		}
	] | each { to yaml } | str join "---\n"
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
	--project: string              # The Google Cloud project whose Secret Manager holds the broker's secrets
	--phone-project: string = ""   # As release.nu: the Firebase project that texts the phone's codes; none, no phone
	--phone-api-key: string = ""
	--phone-app-id: string = ""
	--phone-admit: string = ""
	--phone-tenants: string = ""
	--namespace: string = "identity"
	--service: string = "identity-broker" # The secrets' names in Secret Manager are <service>-secret and <service>-google-client-secret
] {
	if ([$ssh $domain $google_client_id $project] | any { is-empty }) { error make {msg: "--ssh, --domain, --google-client-id and --project are all required"} }
	let phone = if ($phone_project | is-empty) { [] } else {
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
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	let yaml = (manifests --domain $domain --sources (sources) --settings ([{name: "GOOGLE_CLIENT_ID", value: $google_client_id}] ++ $phone) --namespace $namespace --name $service)
	# The namespace first, so the Secret has somewhere to go before the pod that reads it.
	$"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ($namespace)\n" | do $remote $"($kubectl) apply -f -" | print
	# The secrets through ssh's stdin alone: never a file, never an argument.
	let secret_env = $"BROKER_SECRET=(gc-secret $"($service)-secret" $project)\nGOOGLE_CLIENT_SECRET=(gc-secret $"($service)-google-client-secret" $project)\n"
	$secret_env | do $remote $"($kubectl) create secret generic ($service) -n ($namespace) --from-env-file=/dev/stdin --dry-run=client -o yaml | ($kubectl) apply -f -" | print
	$yaml | do $remote $"($kubectl) apply -f -" | print
	do $remote $"($kubectl) rollout restart deployment/($service) -n ($namespace) >/dev/null && ($kubectl) rollout status deployment/($service) -n ($namespace) --timeout=120s" | print
	# Through the gateway as the tunnel reaches it, by host: the broker answers, under its own issuer.
	let gateway = (do $remote $"($kubectl) get svc -n envoy-gateway-system pronto-gateway -o jsonpath='{.spec.clusterIP}'" | str trim)
	let discovery = (do $remote $"curl -fsS --max-time 10 -H 'Host: ($domain)' http://($gateway)/.well-known/openid-configuration" | from json)
	if $discovery.issuer != $"https://($domain)" { error make {msg: $"the broker behind the gateway names issuer ($discovery.issuer), not https://($domain)"} }
	print $"identity: the broker answers on the node for ($domain) behind the gateway; point ($domain) at the tunnel to serve it"
}
