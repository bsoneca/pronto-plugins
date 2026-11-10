# The operator's error tracking on a cluster the operator runs (pronto's envs.Metal: k3s on a node
# reached over SSH, its traffic arriving through the node's Cloudflare Tunnel to Envoy Gateway):
#   bin/pronto-errors metal --ssh bruno@node --domain errors.example.com --projects bonk-chess,…
#
# GlitchTip (AGPL, the Sentry protocol): what a page throws is grouped into issues, counted per
# release and searchable, read at --domain. One process serves the web, ingests and runs its tasks,
# its queue and cache in its own Postgres (VALKEY_URL empty): no Redis, about half a GiB. The
# database is a CloudNativePG cluster in the namespace; every secret (its login, Django's key, the
# owner's password) is generated in-cluster by External Secrets' Password generator, never a file
# and never an argument. Sign-up and new organizations are off: the one account is the owner's,
# `owner@<domain>`, whose password is read from the Secret `owner` (README.md says how).
#
# Pages never reach --domain: an app's door routes its own /e/ to GlitchTip's ingest in the cluster,
# so a page's connect-src stays 'self' (README.md).

const postgres = "ghcr.io/cloudnative-pg/postgresql:18.1-standard-trixie@sha256:ec0c0d60f9462b49f4c6f2403fd680ac43a063fc793f5d570a21a3cea8e627b5"
const glitchtip_image = "docker.io/glitchtip/glitchtip:7.0.0@sha256:c245745b4179667da3aebd73fb8d4f1fd918f7d68ba07d1fd73ea688933b6e01"
# The image's own user (app, 5000), named by number so runAsNonRoot can be checked.
const uid = 5000
const org = "pronto"

# Every object error tracking is on a metal cluster, as YAML documents.
export def manifests [
	--domain: string
	--namespace: string = "errors"
]: nothing -> string {
	let ns = $namespace
	let part = {"app.kubernetes.io/part-of": "pronto-errors"}
	let meta = {|name: string| {name: $name, namespace: $ns, labels: ($part | merge {"app.kubernetes.io/name": $name})} }
	let sel = {|name: string| {"app.kubernetes.io/name": $name} }
	let db = "errors-db"
	# A secret generated once in the namespace, never rotated under running pods, and its Secret's
	# data templated from it.
	let generated = {|name: string, data: record, password: record = {}|
		[
			{apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", metadata: (do $meta $"($name)-password"), spec: ({length: 40, digits: 8, symbols: 0, noUpper: false, allowRepeat: true} | merge $password)}
			{
				apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: (do $meta $name)
				spec: {
					refreshInterval: "0"
					target: {name: $name, creationPolicy: "Owner", template: {data: $data}}
					dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $"($name)-password"}}}]
				}
			}
		]
	}
	let secrets = [
		# The database login CloudNativePG reads (basic-auth), with the URL GlitchTip reads beside it.
		...(do $generated "glitchtip-db" {username: "glitchtip", password: "{{ .password }}", url: $"postgres://glitchtip:{{ .password }}@($db)-rw.($ns).svc:5432/glitchtip?sslmode=disable"})
		...(do $generated "glitchtip" {SECRET_KEY: "{{ .password }}"})
		...(do $generated "owner" {email: $"owner@($domain)", password: "{{ .password }}"})
		# The token a release sends its source maps with (errors/sourcemaps.ts): the owner's API token,
		# made by `provision` from this file, to upload and nothing else. GlitchTip keeps 64 characters.
		...(do $generated "upload" {token: "{{ .password }}"} {length: 64, digits: 24, noUpper: true})
	] | each {|o| if $o.metadata.name == "glitchtip-db" and $o.kind == "ExternalSecret" { $o | upsert spec.target.template.type "kubernetes.io/basic-auth" } else { $o } }
	let cluster = {
		apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster", metadata: (do $meta $db)
		spec: {
			instances: 1
			imageName: $postgres
			storage: {size: "5Gi"}
			smartShutdownTimeout: 15
			stopDelay: 120
			bootstrap: {initdb: {database: "glitchtip", owner: "glitchtip", secret: {name: "glitchtip-db"}}}
		}
	}
	let secure = {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
	let glitchtip = {
		apiVersion: "apps/v1", kind: "Deployment", metadata: (do $meta "glitchtip")
		spec: {
			replicas: 1
			strategy: {type: "Recreate"}
			selector: {matchLabels: (do $sel "glitchtip")}
			template: {
				metadata: {labels: ($part | merge (do $sel "glitchtip"))}
				spec: {
					automountServiceAccountToken: false
					enableServiceLinks: false
					securityContext: {runAsNonRoot: true, runAsUser: $uid, runAsGroup: $uid, fsGroup: $uid, seccompProfile: {type: "RuntimeDefault"}}
					containers: [{
						name: "glitchtip"
						image: $glitchtip_image
						ports: [{name: "http", containerPort: 8000}]
						env: (([
							[GLITCHTIP_DOMAIN $"https://($domain)"]
							[CSRF_TRUSTED_ORIGINS $"https://($domain)"]
							[ALLOWED_HOSTS "*"]
							# Its queue, cache and sessions in Postgres: no Valkey.
							[VALKEY_URL ""]
							[ENABLE_USER_REGISTRATION "false"]
							[ENABLE_ORGANIZATION_CREATION "false"]
							# It sends no mail: the owner reads the console.
							[EMAIL_URL "consolemail://"]
							[DEFAULT_FROM_EMAIL $"errors@($domain)"]
							[GLITCHTIP_MAX_EVENT_LIFE_DAYS "30"]
							[MEDIA_ROOT "/code/uploads/"]
						] | each {|p| {name: $p.0, value: $p.1} }) ++ [
							{name: "DATABASE_URL", valueFrom: {secretKeyRef: {name: "glitchtip-db", key: "url"}}}
							{name: "SECRET_KEY", valueFrom: {secretKeyRef: {name: "glitchtip", key: "SECRET_KEY"}}}
						])
						securityContext: $secure
						resources: {requests: {cpu: "50m", memory: "384Mi"}, limits: {memory: "1Gi"}}
						startupProbe: {tcpSocket: {port: 8000}, periodSeconds: 3, failureThreshold: 100}
						readinessProbe: {tcpSocket: {port: 8000}, periodSeconds: 10}
						volumeMounts: [
							{name: "uploads", mountPath: "/code/uploads"}
							{name: "tmp", mountPath: "/tmp"}
							# The owner's sign-in, read by `provision` alone.
							{name: "owner", mountPath: "/etc/glitchtip-owner", readOnly: true}
							# The source maps' upload token, read by `provision` alone.
							{name: "upload", mountPath: "/etc/glitchtip-upload", readOnly: true}
						]
					}]
					volumes: [
						{name: "uploads", persistentVolumeClaim: {claimName: "glitchtip-uploads"}}
						{name: "tmp", emptyDir: {}}
						{name: "owner", secret: {secretName: "owner", defaultMode: 288}}
						{name: "upload", secret: {secretName: "upload", defaultMode: 288}}
					]
				}
			}
		}
	}
	# Uploads (source maps, later) outlive a pod.
	let uploads = {apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: (do $meta "glitchtip-uploads"), spec: {accessModes: ["ReadWriteOnce"], storageClassName: "local-path", resources: {requests: {storage: "2Gi"}}}}
	let routes = [
		{apiVersion: "v1", kind: "Service", metadata: (do $meta "glitchtip"), spec: {selector: (do $sel "glitchtip"), ports: [{name: "http", port: 8000, targetPort: 8000}]}}
		# Behind the node's tunnel: Cloudflare holds the certificate, Envoy routes by host.
		{apiVersion: "gateway.networking.k8s.io/v1", kind: "Gateway", metadata: (do $meta "glitchtip"), spec: {gatewayClassName: "eg", listeners: [{name: "http", protocol: "HTTP", port: 80, hostname: $domain, allowedRoutes: {namespaces: {from: "Same"}}}]}}
		{apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute", metadata: (do $meta "glitchtip"), spec: {parentRefs: [{name: "glitchtip"}], hostnames: [$domain], rules: [{matches: [{path: {type: "PathPrefix", value: "/"}}], backendRefs: [{name: "glitchtip", port: 8000}]}]}}
	]
	let dns = {ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}
	let policies = [
		# GlitchTip: heard by the gateway (the owner) and by the apps' doors (their /e/); reaches its
		# database alone.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: (do $meta "glitchtip")
			spec: {
				podSelector: {matchLabels: (do $sel "glitchtip")}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{ports: [{protocol: "TCP", port: 8000}]}]
				egress: [$dns {to: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432}]}]
			}
		}
		# The database: GlitchTip, the operator, and its own instances.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: (do $meta $db)
			spec: {
				podSelector: {matchLabels: {"cnpg.io/cluster": $db}}
				policyTypes: ["Ingress"]
				ingress: [
					{from: [{podSelector: {matchLabels: (do $sel "glitchtip")}}], ports: [{protocol: "TCP", port: 5432}]}
					{from: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
					{from: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "cnpg-system"}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
				]
			}
		}
	]
	[{apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: $part}} ...$secrets $cluster $uploads $glitchtip ...$routes ...$policies]
	| each { to yaml } | str join "---\n"
}

# The Django shell program that makes the owner, the organization and a project per app (each
# once), and prints each project's DSN key as JSON lines: {project, id, key}. The key is public (a
# page sends it); the owner's sign-in is read from the pod's mounted Secret, never passed. The
# owner's API token for the releases' source maps is the Secret `upload`'s, made once, its scopes
# only what sentry-cli's upload asks.
export def provision [projects: list<string>]: nothing -> string {
	let names = $projects | to json --raw
	$"
import json
from apps.users.models import User
from apps.organizations_ext.models import Organization, OrganizationUserRole
from apps.projects.models import Project, ProjectKey
from apps.api_tokens.models import APIToken
email, password = [open\(f'/etc/glitchtip-owner/{k}'\).read\(\).strip\(\) for k in \('email', 'password'\)]
user = User.objects.filter\(email=email\).first\(\)
if user is None:
    user = User.objects.create_superuser\(email=email, password=password\)
elif not user.check_password\(password\):
    user.set_password\(password\); user.save\(\)
org, _ = Organization.objects.get_or_create\(slug='($org)', defaults={'name': '($org)'}\)
if not org.organization_users.filter\(user=user\).exists\(\):
    org.add_user\(user, role=OrganizationUserRole.OWNER\)
upload = open\('/etc/glitchtip-upload/token'\).read\(\).strip\(\)
token = APIToken.objects.filter\(token=upload\).first\(\) or APIToken.objects.create\(user=user, token=upload, label='release source maps'\)
token.add_permissions\(['org:read', 'project:read', 'project:write', 'project:releases']\)
for name in json.loads\('($names)'\):
    project, _ = Project.objects.get_or_create\(organization=org, slug=name, defaults={'name': name, 'platform': 'javascript-browser'}\)
    key = ProjectKey.objects.filter\(project=project\).first\(\) or ProjectKey.objects.create\(project=project\)
    print\(json.dumps\({'project': name, 'id': project.id, 'key': key.public_key.hex}\)\)
"
}

export def main [
	--ssh: string                  # The node, as an app's envs.Metal names it: bruno@13.140.186.223
	--kubeconfig: string = "$HOME/.cache/contabo2.kubeconfig" # On the node
	--domain: string               # GlitchTip's console: errors.example.com
	--projects: string = ""       # Each app's project, comma-separated: bonk-chess,…
	--namespace: string = "errors"
] {
	if ([$ssh $domain] | any { is-empty }) { error make {msg: "--ssh and --domain are required"} }
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	manifests --domain $domain --namespace $namespace | do $remote $"($kubectl) apply --server-side --force-conflicts -f -" | print
	do $remote $"($kubectl) wait --for=condition=Ready cluster.postgresql.cnpg.io/errors-db -n ($namespace) --timeout=300s && ($kubectl) rollout status deployment/glitchtip -n ($namespace) --timeout=600s" | print
	# The owner and the projects, by the Django shell in the running pod, which reads the owner's
	# sign-in from its mounted Secret.
	let program = (provision ($projects | split row "," | str trim | where {|p| $p != ""}))
	let keys = ($program | do $remote $"($kubectl) exec -i -n ($namespace) deploy/glitchtip -- ./manage.py shell" | lines | where {|l| $l starts-with "{" } | each { from json })
	# Through the gateway as the tunnel reaches it, by host: the console answers.
	let gateway = (do $remote $"($kubectl) get svc -n envoy-gateway-system pronto-gateway -o jsonpath='{.spec.clusterIP}'" | str trim)
	do $remote $"curl -fsS --max-time 10 -o /dev/null -w '%{http_code}\\n' -H 'Host: ($domain)' http://($gateway)/" | print
	print ($keys | table)
	print $"errors: GlitchTip answers at https://($domain); each app's spec takes its project's id and key"
}
