# The airlock beside an operator's broker (--airlock, PRONTO-135, PRONTO-268): shared by
# billing/metal.nu (Stripe's door), identity/metal.nu (Google's token door) and airlock/metal.nu (an
# app's doors from its own spec: Studio's model doors, PRONTO-271), so the pod, its ledger and the wall
# around it are written once.

# The airlock beside the broker (--airlock, PRONTO-135): mecha-fork's airlock with its door
# (mecha-fork#26, its sinkKey, mecha-fork#30, and a door's own timeoutMs and hidden headers,
# mecha-fork#34: mecha 0.22.0-host.8 by pronto-fork's prerelease-mecha), mecha's daprd,
# and mecha's database image, which stages the ledger's initdb steps.
const airlock_image = "ghcr.io/bsoneca/mecha-airlock:0.22.0-host.8@sha256:02822aa37edf22081740fc0935fe9f41df93ba9146030c8ca31f0814876acbb0"
const mesh_image = "bonitao/mecha-mesh:0.22.0@sha256:8d39aa3543560232c52330152ba70a4d2c973b76d0ac97899d677704bc0e09a4"
const ledger_image = "bonitao/mecha-database:0.22.0@sha256:ed58b6be6cd69658fbb4e6daff1f91b8923b333f364905c4dacdec2974a05d82"
export const door_port = 9998

# The airlock beside the broker: one pod of the airlock, its daprd and its ledger's Postgres, which
# only the broker reaches, on the door's port. Each door, {door, var, base, scheme, headers}, is a
# credential's: the airlock reads it from the broker's Secret (`var`), adds it to every call as the
# Authorization header's `scheme` value, and calls `base`; the broker's pod names none of them. Every
# call is a row of the ledger (mecha's services/airlock/README.md, "A door").
# A door may also say: no `var`, holding no credential (its caller's hidden header is the sink's key);
# `secret` {name, key}, the Secret its credential is read from where it is not the
# caller's own; `timeoutMs`, how long its sink may take (a model's answer: minutes), which the door and
# the daprd's resiliency policy both wait; `headers` entries {name, hidden: true}, passed to the sink
# and frozen in the ledger only as their sha256; and `egress`, the NetworkPolicy rules that reach a sink
# inside the cluster, in place of HTTPS to public addresses. `from` is who reaches the door: the
# caller's pod labels (in this namespace), or a list of NetworkPolicy peers (callers elsewhere).
export def airlock-objects [namespace: string, name: string, labels: record, from: any, caller: string, held: list<record>]: nothing -> list<record> {
	let doors = ($held | get door)
	let meta = {namespace: $namespace, labels: $labels}
	let peers = (if ($from | describe | str starts-with "record") { [{podSelector: {matchLabels: $from}}] } else { $from })
	# Each credential's Secret and key: the caller's own Secret, by the variable's name, unless named.
	# A door with no `var` holds no credential: its caller's own header (hidden) is the sink's key.
	let refs = ($held | where {|d| ($d.var? | is-not-empty) } | each {|d| {var: $d.var, ref: ($d.secret? | default {name: $caller, key: $d.var})} } | uniq-by var)
	let manifest = {
		effects: {}
		doors: ($held | reduce -f {} {|d, acc| $acc | insert $d.door ({idempotent: true}
			| merge (if ($d.var? | is-empty) { {} } else { {credential: {header: "Authorization", scheme: $d.scheme, secret: $d.var}} })
			| merge {headers: $d.headers, callers: [$caller]}
			| merge (if ($d.timeoutMs? | is-empty) { {} } else { {timeoutMs: $d.timeoutMs} }))})
	}
	# A door that waits longer than daprd's default waits there too.
	let timed = ($held | where {|d| ($d.timeoutMs? | is-not-empty) })
	# The daprd's wall and breaker, as mecha's cluster writes them for its effects (cluster.cue's
	# #AirlockWall and #AirlockResiliency), and one HTTPEndpoint per door.
	let wall = {
		apiVersion: "dapr.io/v1alpha1", kind: "Component", metadata: {name: "wall"}
		spec: {type: "middleware.http.routerchecker", version: "v1", metadata: [{name: "rule", value: $"^/v1[.]0/\(healthz\(/outbound\)?|invoke/\(($doors | str join '|')\)/method/.*\)$"}]}
	}
	let resiliency = {
		apiVersion: "dapr.io/v1alpha1", kind: "Resiliency", metadata: {name: "airlock"}
		spec: {
			policies: ({circuitBreakers: {sink: {maxRequests: 1, interval: "60s", timeout: "30s", trip: "consecutiveFailures >= 10"}}}
				| merge (if ($timed | is-empty) { {} } else { {timeouts: ($timed | reduce -f {} {|d, acc| $acc | insert $d.door $"($d.timeoutMs // 1000)s" })} }))
			targets: {apps: ($held | reduce -f {} {|d, acc| $acc | insert $d.door ({circuitBreaker: "sink"} | merge (if ($d.timeoutMs? | is-empty) { {} } else { {timeout: $d.door} })) })}
		}
	}
	let endpoints = ($held | each {|d| {key: $"($d.door).yaml", value: ({apiVersion: "dapr.io/v1alpha1", kind: "HTTPEndpoint", metadata: {name: $d.door}, spec: {baseUrl: $d.base}} | to yaml)} })
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
								] ++ ($refs | each {|r| {name: $r.var, valueFrom: {secretKeyRef: $r.ref}} }))
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
		# The door's port from its callers alone; out, DNS and HTTPS to public addresses (the sinks), or
		# each in-cluster sink's own way where its doors all name one.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($meta | insert name $name)
			spec: {
				podSelector: {matchLabels: $labels}
				policyTypes: ["Ingress" "Egress"]
				ingress: [{from: $peers, ports: [{protocol: "TCP", port: $door_port}]}]
				egress: ([{ports: [{protocol: "UDP", port: 53} {protocol: "TCP", port: 53}]}]
					++ (if ($held | any {|d| ($d.egress? | is-empty) }) { [{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $private}}], ports: [{protocol: "TCP", port: 443}]}] } else { [] })
					++ ($held | each {|d| $d.egress? | default [] } | flatten | uniq))
			}
		}
	]
}
