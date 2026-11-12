# A broker's own Postgres on a metal cluster (PRONTO-371), shared by identity/metal.nu and
# billing/metal.nu: what each broker keeps between requests lives there, so any replica answers any
# request (each broker's broker/store.ts). A CloudNativePG cluster `<db>`, its login generated once in
# the namespace as errors/metal.nu's is (never a file or an argument, never rotated under a running
# pod), with the URL the broker reads as DATABASE_URL beside it, and who may reach it.

# CloudNativePG's PostgreSQL image, as errors/metal.nu pins it.
export const postgres = "ghcr.io/cloudnative-pg/postgresql:18.1-standard-trixie@sha256:ec0c0d60f9462b49f4c6f2403fd680ac43a063fc793f5d570a21a3cea8e627b5"

# The database's objects: its generated password, the login Secret (with `url`), the cluster, and its
# NetworkPolicy (the broker, the operator and the cluster's own instances).
export def objects [
	namespace: string
	db: string            # The cluster's name, `<broker>-db`
	part_of: string       # The plugin, as the broker's labels name it: pronto-identity
	user: string          # The database and its owner
	broker_labels: record # The broker's pods, which alone of the namespace's reach it
]: nothing -> list<record> {
	let db_labels = {"app.kubernetes.io/name": $db, "app.kubernetes.io/part-of": $part_of}
	let db_meta = {namespace: $namespace, labels: $db_labels}
	[
		{apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", metadata: ($db_meta | insert name $"($db)-password"), spec: {length: 40, digits: 8, symbols: 0, noUpper: false, allowRepeat: true}}
		{
			apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: ($db_meta | insert name $db)
			spec: {
				refreshInterval: "0"
				# The login CloudNativePG reads (basic-auth), with the URL the broker reads beside it.
				target: {name: $db, creationPolicy: "Owner", template: {type: "kubernetes.io/basic-auth", data: {username: $user, password: "{{ .password }}", url: $"postgres://($user):{{ .password }}@($db)-rw.($namespace).svc:5432/($user)?sslmode=disable"}}}
				dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $"($db)-password"}}}]
			}
		}
		{
			apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster", metadata: ($db_meta | insert name $db)
			spec: {
				instances: 1
				imageName: $postgres
				storage: {size: "1Gi"}
				smartShutdownTimeout: 15
				stopDelay: 120
				bootstrap: {initdb: {database: $user, owner: $user, secret: {name: $db}}}
			}
		}
		# The database: the broker, the operator, and its own instances.
		{
			apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: ($db_meta | insert name $db)
			spec: {
				podSelector: {matchLabels: {"cnpg.io/cluster": $db}}
				policyTypes: ["Ingress"]
				ingress: [
					{from: [{podSelector: {matchLabels: $broker_labels}}], ports: [{protocol: "TCP", port: 5432}]}
					{from: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
					{from: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "cnpg-system"}}}], ports: [{protocol: "TCP", port: 5432} {protocol: "TCP", port: 8000}]}
				]
			}
		}
	]
}

# The broker's DATABASE_URL, from the login Secret.
export def url-env [db: string]: nothing -> record {
	{name: "DATABASE_URL", valueFrom: {secretKeyRef: {name: $db, key: "url"}}}
}

# The broker's way out to its database, for its NetworkPolicy's egress.
export def egress [db: string]: nothing -> record {
	{to: [{podSelector: {matchLabels: {"cnpg.io/cluster": $db}}}], ports: [{protocol: "TCP", port: 5432}]}
}
