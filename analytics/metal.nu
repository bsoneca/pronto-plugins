# The operator's analytics on a cluster the operator runs (pronto's envs.Metal: k3s on a node reached
# over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway), beside
# pronto's infra/gcp Cloud Run services of the same names:
#   bin/pronto-analytics metal --ssh bruno@node --grafana-domain G --umami-domain U --project P \
#     --dashboards [bonk-chess/business=apps/…/analytics.business.dashboard.json …] --users '{"a@b.c": "Admin"}'
#
# Grafana reads the cluster's VictoriaMetrics (which scrapes each app's exporter and collectors) and
# keeps its own state in a database of its own; Umami keeps visits in another. Both databases are one
# CloudNativePG cluster in the namespace, their logins generated in-cluster (External Secrets'
# Password generator), never a file. What must stay what it was on Cloud Run is read with the
# operator's gcloud from the project's Secret Manager and piped into a Secret, never written to a
# file: Grafana's secret key (it decrypts what Grafana kept), its Google sign-in client, and Umami's
# app secret (its sessions).

const postgres = "ghcr.io/cloudnative-pg/postgresql:18.1-standard-trixie@sha256:ec0c0d60f9462b49f4c6f2403fd680ac43a063fc793f5d570a21a3cea8e627b5"
const grafana_image = "grafana/grafana:11.2.0@sha256:408afb9726de5122b00a2576763a8a57a3c86d5b0eff5305bc994ceb3eb96c3f"
const umami_image = "ghcr.io/umami-software/umami@sha256:e69d1a7932e9dab0fc523edc7be1f3a53f3c261f57856fc2167ae74a8fc022e8"
const victoria = "http://vmsingle.observability.svc.cluster.local:8428"
# The addresses no public service has: what Grafana never needs to reach on 443.
const private = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]

# A Grafana dashboard ConfigMap's name, from its app and its name.
def dash-map [app: string, name: string]: nothing -> string { $"grafana-dashboards-($app)-($name)" }

# Grafana's role for each account named, and none for anyone else (role_attribute_strict refuses).
export def role-path [users: record]: nothing -> string {
	$users | columns | sort | each {|e| $"\(email=='($e)' && '($users | get $e)'\)" } | str join " || "
}

# Every object the analytics are on a metal cluster, as YAML documents. `dashboards` holds each
# dashboard's text by app and name ({app, name, text}).
export def manifests [
	--grafana-domain: string
	--umami-domain: string
	--users: record
	--dashboards: list<record> = []
	--namespace: string = "analytics"
]: nothing -> string {
	let ns = $namespace
	let part = {"app.kubernetes.io/part-of": "pronto-analytics"}
	let meta = {|name: string| {name: $name, namespace: $ns, labels: ($part | merge {"app.kubernetes.io/name": $name})} }
	let sel = {|name: string| {"app.kubernetes.io/name": $name} }
	let db = "analytics-db"
	let logins = [grafana umami]
	# A login's password, generated once in the namespace; its Secret is what CloudNativePG reads
	# (basic-auth), with the URL Umami reads beside it.
	let secrets = $logins | each {|l|
		[
			{apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", metadata: (do $meta $"($l)-db-password"), spec: {length: 32, digits: 8, symbols: 0, noUpper: false, allowRepeat: true}}
			{
				apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: (do $meta $"($l)-db")
				spec: {
					# A generated secret never rotates under running pods.
					refreshInterval: "0"
					target: {name: $"($l)-db", creationPolicy: "Owner", template: {type: "kubernetes.io/basic-auth", data: {username: $l, password: "{{ .password }}", url: $"postgresql://($l):{{ .password }}@($db)-rw.($ns).svc:5432/($l)?sslmode=disable"}}}
					dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $"($l)-db-password"}}}]
				}
			}
		]
	} | flatten
	let cluster = {
		apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster", metadata: (do $meta $db)
		spec: {
			instances: 1
			imageName: $postgres
			storage: {size: "2Gi"}
			# As the apps' databases: a stop is bounded, not CloudNativePG's half an hour.
			smartShutdownTimeout: 15
			stopDelay: 120
			bootstrap: {initdb: {database: "grafana", owner: "grafana", secret: {name: "grafana-db"}}}
			managed: {roles: ($logins | each {|l| {name: $l, ensure: "present", login: true, passwordSecret: {name: $"($l)-db"}} })}
		}
	}
	let databases = [{apiVersion: "postgresql.cnpg.io/v1", kind: "Database", metadata: (do $meta "umami"), spec: {name: "umami", owner: "umami", cluster: {name: $db}}}]
	let datasources = {
		apiVersion: 1
		datasources: [{name: "VictoriaMetrics", uid: "victoriametrics", type: "prometheus", access: "proxy", url: $victoria, isDefault: true, editable: false, jsonData: {httpMethod: "POST", timeInterval: "30s"}}]
	}
	let apps = $dashboards | get app | uniq
	let providers = {
		apiVersion: 1
		providers: ($apps | each {|a| {name: $a, folder: ($dashboards | where app == $a | first | get folder), type: "file", disableDeletion: true, allowUiUpdates: false, updateIntervalSeconds: 60, options: {path: $"/dashboards/($a)"}} })
	}
	let config = [
		{apiVersion: "v1", kind: "ConfigMap", metadata: (do $meta "grafana-provisioning"), data: {"datasources.yaml": ($datasources | to yaml), "dashboards.yaml": ($providers | to yaml)}}
		...($dashboards | each {|d| {apiVersion: "v1", kind: "ConfigMap", metadata: (do $meta (dash-map $d.app $d.name)), data: {$"($d.name).json": $d.text}} })
	]
	# A change to a dashboard or the provisioning is a new pod: their digest is the template's.
	let digest = ($config | to json | hash sha256 | str substring 0..15)
	let secure = {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
	let grafana = {
		apiVersion: "apps/v1", kind: "Deployment", metadata: (do $meta "grafana")
		spec: {
			replicas: 1
			strategy: {type: "Recreate"}
			selector: {matchLabels: (do $sel "grafana")}
			template: {
				metadata: {labels: ($part | merge (do $sel "grafana")), annotations: {"pronto.dev/config": $digest}}
				spec: {
					automountServiceAccountToken: false
					securityContext: {runAsNonRoot: true, runAsUser: 472, runAsGroup: 472, fsGroup: 472, seccompProfile: {type: "RuntimeDefault"}}
					containers: [{
						name: "grafana"
						image: $grafana_image
						ports: [{name: "http", containerPort: 3000}]
						env: (([
							[GF_SERVER_ROOT_URL $"https://($grafana_domain)"]
							[GF_DATABASE_TYPE postgres]
							[GF_DATABASE_HOST $"($db)-rw.($ns).svc:5432"]
							[GF_DATABASE_NAME grafana]
							[GF_DATABASE_USER grafana]
							[GF_DATABASE_SSL_MODE disable]
							[GF_AUTH_ANONYMOUS_ENABLED "false"]
							[GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION "true"]
							[GF_AUTH_BASIC_ENABLED "false"]
							[GF_AUTH_DISABLE_LOGIN_FORM "true"]
							[GF_USERS_ALLOW_SIGN_UP "false"]
							[GF_AUTH_GOOGLE_ENABLED "true"]
							[GF_AUTH_GOOGLE_ALLOW_SIGN_UP "true"]
							[GF_AUTH_GOOGLE_SCOPES "openid email profile"]
							[GF_AUTH_GOOGLE_USE_PKCE "true"]
							[GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_PATH (role-path $users)]
							[GF_AUTH_GOOGLE_ROLE_ATTRIBUTE_STRICT "true"]
							[GF_ANALYTICS_REPORTING_ENABLED "false"]
							[GF_ANALYTICS_CHECK_FOR_UPDATES "false"]
							[GF_LOG_MODE console]
						] | each {|p| {name: $p.0, value: $p.1} }) ++ [
							{name: "GF_DATABASE_PASSWORD", valueFrom: {secretKeyRef: {name: "grafana-db", key: "password"}}}
							{name: "GF_SECURITY_SECRET_KEY", valueFrom: {secretKeyRef: {name: "grafana", key: "GF_SECURITY_SECRET_KEY"}}}
							{name: "GF_AUTH_GOOGLE_CLIENT_ID", valueFrom: {secretKeyRef: {name: "grafana", key: "GF_AUTH_GOOGLE_CLIENT_ID"}}}
							{name: "GF_AUTH_GOOGLE_CLIENT_SECRET", valueFrom: {secretKeyRef: {name: "grafana", key: "GF_AUTH_GOOGLE_CLIENT_SECRET"}}}
						])
						securityContext: ($secure | merge {readOnlyRootFilesystem: true})
						resources: {requests: {cpu: "50m", memory: "128Mi"}, limits: {memory: "512Mi"}}
						startupProbe: {httpGet: {path: "/api/health", port: 3000}, periodSeconds: 2, failureThreshold: 90}
						readinessProbe: {httpGet: {path: "/api/health", port: 3000}, periodSeconds: 10}
						volumeMounts: ([
							{name: "data", mountPath: "/var/lib/grafana"}
							{name: "tmp", mountPath: "/tmp"}
							{name: "provisioning", mountPath: "/etc/grafana/provisioning/datasources/datasources.yaml", subPath: "datasources.yaml", readOnly: true}
							{name: "provisioning", mountPath: "/etc/grafana/provisioning/dashboards/dashboards.yaml", subPath: "dashboards.yaml", readOnly: true}
						] ++ ($dashboards | each {|d| {name: (dash-map $d.app $d.name), mountPath: $"/dashboards/($d.app)/($d.name).json", subPath: $"($d.name).json", readOnly: true} }))
					}]
					volumes: ([
						{name: "data", emptyDir: {}}
						{name: "tmp", emptyDir: {}}
						{name: "provisioning", configMap: {name: "grafana-provisioning"}}
					] ++ ($dashboards | each {|d| {name: (dash-map $d.app $d.name), configMap: {name: (dash-map $d.app $d.name)}} }))
				}
			}
		}
	}
	let umami = {
		apiVersion: "apps/v1", kind: "Deployment", metadata: (do $meta "umami")
		spec: {
			replicas: 1
			strategy: {type: "Recreate"}
			selector: {matchLabels: (do $sel "umami")}
			template: {
				metadata: {labels: ($part | merge (do $sel "umami"))}
				spec: {
					automountServiceAccountToken: false
					securityContext: {runAsNonRoot: true, runAsUser: 1001, runAsGroup: 1001, seccompProfile: {type: "RuntimeDefault"}}
					containers: [{
						name: "umami"
						image: $umami_image
						ports: [{name: "http", containerPort: 3000}]
						# The tracker's and its collector's addresses, which the apps' doors proxy.
						env: [
							{name: "TRACKER_SCRIPT_NAME", value: "/a/s.js"}
							{name: "COLLECT_API_ENDPOINT", value: "/a/e"}
							{name: "DISABLE_TELEMETRY", value: "1"}
							{name: "DISABLE_UPDATES", value: "1"}
							{name: "HOSTNAME", value: "0.0.0.0"}
							{name: "DATABASE_URL", valueFrom: {secretKeyRef: {name: "umami-db", key: "url"}}}
							{name: "APP_SECRET", valueFrom: {secretKeyRef: {name: "umami", key: "APP_SECRET"}}}
						]
						securityContext: $secure
						resources: {requests: {cpu: "50m", memory: "192Mi"}, limits: {memory: "768Mi"}}
						startupProbe: {httpGet: {path: "/api/heartbeat", port: 3000}, periodSeconds: 2, failureThreshold: 90}
						readinessProbe: {httpGet: {path: "/api/heartbeat", port: 3000}, periodSeconds: 10}
					}]
				}
			}
		}
	}
	let served = [[name domain]; [grafana $grafana_domain] [umami $umami_domain]]
	let routes = $served | each {|s|
		[
			{apiVersion: "v1", kind: "Service", metadata: (do $meta $s.name), spec: {selector: (do $sel $s.name), ports: [{name: "http", port: 3000, targetPort: 3000}]}}
			# Behind the node's tunnel: Cloudflare holds the certificate, Envoy routes by host.
			{apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: (do $meta $s.name), spec: {gatewayClassName: "eg", listeners: [{name: "http", protocol: "HTTP", port: 80, hostname: $s.domain, allowedRoutes: {namespaces: {from: "Same"}}}]}}
			{apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute", metadata: (do $meta $s.name), spec: {parentRefs: [{name: $s.name}], hostnames: [$s.domain], rules: [{matches: [{path: {type: "PathPrefix", value: "/"}}], backendRefs: [{name: $s.name, port: 3000}]}]}}
		]
	} | flatten
	let dns = {ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
	let to_db = {to: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432}]}
	let policies = [
		# Grafana: its database, the cluster's metrics, and Google's sign-in on public 443.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: (do $meta "grafana")
			spec: {
				podSelector: {matchLabels: (do $sel "grafana")}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{ports: [{protocol: "TCP", port: 3000}]}]
				egress: [
					$dns
					$to_db
					{to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "observability"}}}], ports: [{protocol: "TCP", port: 8428}]}
					{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}
				]
			}
		}
		# Umami: its database, nothing else.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: (do $meta "umami")
			spec: {podSelector: {matchLabels: (do $sel "umami")}, policyTypes: ["Ingress" "Egress"], ingress: [{ports: [{protocol: "TCP", port: 3000}]}], egress: [$dns $to_db]}
		}
		# The database: its two clients, the operator, and its own instances.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: (do $meta $db)
			spec: {
				podSelector: {matchLabels: {"cnpg.io/cluster": $db}}
				policyTypes: ["Ingress"]
				ingress: [
					{from: [{podSelector: {matchExpressions: [{key: "app.kubernetes.io/name", operator: "In", values: ["grafana" "umami"]}]}}], ports: [{protocol: "TCP", port: 5432}]}
					{from: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
					{from: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "cnpg-system"}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
				]
			}
		}
	]
	[{apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: $part}} ...$secrets $cluster ...$databases ...$config $grafana $umami ...$routes ...$policies]
	| each { to yaml } | str join "---\n"
}

# The dashboards named `app/name=path` (folder: the app's title, `--titles`), read from disk.
export def dashboards [specs: list<string>, titles: record]: nothing -> list<record> {
	$specs | each {|s|
		let p = $s | parse "{app}/{name}={path}" | first
		{app: $p.app, name: $p.name, folder: ($titles | get -o $p.app | default $p.app), text: (open --raw $p.path)}
	}
}

# gcloud on the Python pinned beside it (identity's release.nu says why).
def gc-secret [name: string, project: string]: nothing -> string {
	let r = (with-env {CLOUDSDK_PYTHON: python3.12, CLOUDSDK_PYTHON_SITEPACKAGES: "0"} { ^$env.SAYT_MISE_BIN exec gcloud@589.0.0 python@3.12.11 -- gcloud --quiet secrets versions access latest --secret $name --project $project | complete })
	if $r.exit_code != 0 { error make {msg: $"gcloud secrets versions access ($name): ($r.stderr | str trim)"} }
	$r.stdout
}

export def main [
	--ssh: string                  # The node, as an app's envs.Metal names it: bruno@13.140.186.223
	--kubeconfig: string = "$HOME/.cache/contabo2.kubeconfig" # On the node
	--grafana-domain: string       # Grafana's address: metrics.example.com
	--umami-domain: string         # Umami's console and the doors' upstream: umami.example.com
	--project: string              # The Google Cloud project whose Secret Manager holds what Cloud Run's had
	--users: string                # Grafana's accounts, JSON: {"a@b.c": "Admin"}
	--dashboards: list<string> = [] # app/name=path of each dashboard
	--titles: string = "{}"        # JSON: each app's folder title, {"bonk-chess": "Bonk Chess"}
	--namespace: string = "analytics"
] {
	if ([$ssh $grafana_domain $umami_domain $project $users] | any { is-empty }) { error make {msg: "--ssh, --grafana-domain, --umami-domain, --project and --users are all required"} }
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	let yaml = (manifests --grafana-domain $grafana_domain --umami-domain $umami_domain --users ($users | from json) --dashboards (dashboards $dashboards ($titles | from json)) --namespace $namespace)
	$"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ($namespace)\n" | do $remote $"($kubectl) apply -f -" | print
	# What Cloud Run's kept, through ssh's stdin alone: never a file, never an argument.
	let grafana_env = $"GF_SECURITY_SECRET_KEY=(gc-secret grafana-secret-key $project)\nGF_AUTH_GOOGLE_CLIENT_ID=(gc-secret grafana-google-client-id $project)\nGF_AUTH_GOOGLE_CLIENT_SECRET=(gc-secret grafana-google-client-secret $project)\n"
	$grafana_env | do $remote $"($kubectl) create secret generic grafana -n ($namespace) --from-env-file=/dev/stdin --dry-run=client -o yaml | ($kubectl) apply -f -" | print
	$"APP_SECRET=(gc-secret umami-app-secret $project)\n" | do $remote $"($kubectl) create secret generic umami -n ($namespace) --from-env-file=/dev/stdin --dry-run=client -o yaml | ($kubectl) apply -f -" | print
	$yaml | do $remote $"($kubectl) apply --server-side --force-conflicts -f -" | print
	do $remote $"($kubectl) wait --for=condition=Ready cluster.postgresql.cnpg.io/analytics-db -n ($namespace) --timeout=300s && ($kubectl) rollout status deployment/grafana -n ($namespace) --timeout=300s && ($kubectl) rollout status deployment/umami -n ($namespace) --timeout=300s" | print
	# Through the gateway as the tunnel reaches it, by host: each answers.
	let gateway = (do $remote $"($kubectl) get svc -n envoy-gateway-system pronto-gateway -o jsonpath='{.spec.clusterIP}'" | str trim)
	for c in [[$grafana_domain "/api/health"] [$umami_domain "/api/heartbeat"]] {
		do $remote $"curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' -H 'Host: ($c.0)' http://($gateway)($c.1)" | print
	}
	print $"analytics: Grafana and Umami answer on the node behind the gateway; copy their data, then point ($grafana_domain) and ($umami_domain) at the tunnel"
}
