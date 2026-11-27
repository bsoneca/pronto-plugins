#!/usr/bin/env nu
# Run with: nu node/engine/admission_test.nu                      (needs `cue`; the rules, each read off the schema)
#           nu node/engine/admission_test.nu --kind <context>    (also asks a cluster, see below)
#
# schema/node.cue #TenantAdmission: the cluster's admission policies for a tenant's namespaces (PRONTO-1941, step 2 of PRONTO-1929). They are generated from
# the definitions tenant.nu's check-objects reads, so the first half holds, for each rule, that the policy carries it and that it carries what the schema says
# (change a list of the schema and the policy moves with it). The second half, with `--kind <kube context>` of a cluster the caller made (kind, the
# CRDs of CloudNativePG 1.30 installed: `kubectl apply --server-side -f cnpg-1.30.1.yaml`), applies the policies with a Deny binding and asks the API server, as a
# server-side dry run, whether each object is refused (by which policy) or admitted: a bad object per rule, and the good ones the engine renders. The dry run writes
# nothing; the policies, the namespaces and the service accounts it makes are the caller's cluster's to delete.

const engine_dir = path self .
const label = "studio.bsoneca.com/tenant"
const policy_prefix = "studio-tenant"

use std/assert

def main [--kind: string = ""] {
	print "Running tenant admission tests...\n"
	test_no_policy_is_named_as_one_of_studios_own
	test_every_policy_matches_tenant_namespaces_only
	test_the_images_are_the_namespaces_own
	test_the_accounts_are_the_engines_reserved_ones_and_the_databases
	test_classes_user_namespaces_and_sidecar_annotations
	test_volumes_are_an_allow_list
	test_cnpg_labels_escalation_capabilities_and_metadata
	test_services_and_secrets
	test_a_cluster_is_held_to_the_engines_allow_list
	test_the_parameters_are_the_engines_bounds
	test_the_roles_and_services_of_a_cluster
	test_who_is_not_judged_and_what_the_bindings_do
	if $kind != "" { test_the_api_server $kind }
	print "\nAll tenant admission tests passed."
}

def --wrapped cue-in [...args: string]: nothing -> record {
	do { cd ($engine_dir | path join schema); ^cue ...$args } | complete
}

def schema [expr: string]: nothing -> any {
	let r = (cue-in export --out json -e $expr node.cue)
	assert equal $r.exit_code 0 $r.stderr
	$r.stdout | from json
}

# The policies of the schema as a studio's apps would apply them, by name.
def policies [extra: string = ""]: nothing -> record {
	let objects = (schema $"\(#TenantAdmission & {label: \"($label)\", name: \"($policy_prefix)\"($extra)}).objects")
	$objects | where kind == "ValidatingAdmissionPolicy" | reduce --fold {} {|p, acc| $acc | insert ($p.metadata.name | str replace $"($policy_prefix)-engine-" "") $p }
}

# The expressions of a policy's validations whose message says `says`.
def rules [policy: string, says: string]: nothing -> list<string> {
	(policies | get $policy).spec.validations | where {|v| $v.message | str contains $says } | get expression
}

def one-rule [policy: string, says: string]: nothing -> string {
	let r = (rules $policy $says)
	assert equal ($r | length) 1 $"($policy) has ($r | length) rules saying ($says)"
	$r | first
}

def test_no_policy_is_named_as_one_of_studios_own [] {
	print "test no generated policy or binding is named as one of Studio's own enforced ones (studio-provisioner, studio-tenant-hosts, studio-tenant-secrets): applying them would overwrite those..."
	let objects = (schema $"\(#TenantAdmission & {label: \"($label)\", name: \"($policy_prefix)\"}).objects")
	let studios = [studio-provisioner studio-tenant-hosts studio-tenant-secrets]
	for o in $objects {
		assert ($o.metadata.name not-in $studios) $"($o.kind) ($o.metadata.name) is Studio's"
		assert ($o.metadata.name | str starts-with $"($policy_prefix)-engine-") $o.metadata.name
	}
	assert equal ($objects | where kind == "ValidatingAdmissionPolicy" | length) 6
}

def test_every_policy_matches_tenant_namespaces_only [] {
	print "test every policy matches a namespace with the tenant label and no other..."
	let all = (policies)
	assert equal ($all | columns | sort) [clusters objects pods secrets services templates]
	for name in ($all | columns) {
		let sel = ($all | get $name).spec.matchConstraints.namespaceSelector.matchExpressions
		assert equal $sel [{key: $label, operator: "Exists"}] $name
	}
	let kinds = (schema '#PublisherKinds')
	let matched = ($all.objects.spec.matchConstraints.resourceRules | each {|r| $"($r.apiGroups.0)/($r.resources.0)" })
	assert equal ($matched | length) ($kinds | length) "the objects policy has one rule for each kind a publisher writes (#PublisherResources)"
	let pods = $all.pods.spec.matchConstraints.resourceRules.0.resources
	assert equal $pods [pods pods/ephemeralcontainers] "a pod's ephemeral containers are an update of their own subresource"
	assert equal $all.templates.spec.matchConstraints.resourceRules.0.resources [deployments replicasets statefulsets]
}

def test_the_images_are_the_namespaces_own [] {
	print "test every container (init and ephemeral too) runs an image from its own namespace's path of the registry, the slash after the namespace included..."
	for policy in [pods templates] {
		let rule = (one-rule $policy "images from its own namespace's path")
		assert ($rule | str contains "'127.0.0.1:5000/' + request.namespace + '/'") $rule
		let images = ((policies | get $policy).spec.variables | where name == images | get expression | first)
		for list in [containers initContainers ephemeralContainers] { assert ($images | str contains $"variables.spec.($list)") $"($policy): ($list)" }
	}
	let other = (policies ', registry: "registry.example:5000"')
	assert ((($other.pods.spec.validations | first).expression) | str contains "'registry.example:5000/'") "the registry is a parameter"
}

def test_the_accounts_are_the_engines_reserved_ones_and_the_databases [] {
	print "test a pod never runs as an account of #TenantForbiddenAccounts, nor as a database's own (<cluster>-db), by either field..."
	for policy in [pods templates] {
		let rule = (one-rule $policy "never run as the publisher's")
		for a in (schema '#TenantForbiddenAccounts') { assert ($rule | str contains $"'($a)'") $"($policy): ($a)" }
		assert ($rule | str contains "a.endsWith('-db')") $rule
		let accounts = ((policies | get $policy).spec.variables | where name == accounts | get expression | first)
		assert (($accounts | str contains "serviceAccountName") and ($accounts | str contains "variables.spec.serviceAccount]")) $"($policy): both fields: ($accounts)"
	}
}

def test_classes_user_namespaces_and_sidecar_annotations [] {
	print "test a pod sets no runtime class, no priority class, no user namespace and none of Dapr's sidecar annotations..."
	for policy in [pods templates] {
		let rule = (one-rule $policy "no runtime class")
		for f in [runtimeClassName priorityClassName hostUsers] { assert ($rule | str contains $f) $f }
		let notes = ((policies | get $policy).spec.variables | where name == sidecarNotes | get expression | first)
		for p in (schema '#TenantRefusedAnnotationPrefixes') { assert ($notes | str contains $"k.startsWith\('($p)'\)") $p }
		assert ((one-rule $policy "leave Dapr's sidecar") == "size(variables.sidecarNotes) == 0")
	}
}

def test_volumes_are_an_allow_list [] {
	print "test a pod's volumes are an allow-disjunction of #TenantVolumeTypes: a source it does not name, now or in a later Kubernetes, is refused..."
	for policy in [pods templates] {
		let rule = (one-rule $policy "mount only")
		let types = (schema '#TenantVolumeTypes')
		assert equal ($rule | parse --regex 'has\(v\.(?<t>[a-zA-Z]+)\)' | get t) $types $rule
		assert (not ($rule | str contains "hostPath")) $rule
		assert ($rule | str starts-with "!has(variables.spec.volumes) || variables.spec.volumes.all(v, has(") $rule
	}
}

def test_cnpg_labels_escalation_capabilities_and_metadata [] {
	print "test a pod carries no cnpg.io/ label, says allowPrivilegeEscalation false on every container, adds no capability and leaves ownerReferences and finalizers (its template's too) to the engine..."
	for policy in [pods templates] {
		let labels = ((policies | get $policy).spec.variables | where name == refusedLabels | get expression | first)
		for p in (schema '#TenantRefusedLabelPrefixes') { assert ($labels | str contains $"k.startsWith\('($p)'\)") $p }
		assert ((one-rule $policy "no cnpg.io/ label") == "size(variables.refusedLabels) == 0")
		let escalation = (one-rule $policy "allowPrivilegeEscalation: false")
		for list in [containers initContainers ephemeralContainers] { assert ($escalation | str contains $"variables.spec.($list)") $"($policy): ($list)" }
		assert ($escalation | str contains "c.securityContext.allowPrivilegeEscalation == false") $escalation
		assert ((one-rule $policy "add no capabilities") == "variables.containerCaps.all(a, size(a) == 0)")
		let caps = ((policies | get $policy).spec.variables | where name == containerCaps | get expression | first)
		for list in [containers initContainers ephemeralContainers] { assert ($caps | str contains $"variables.spec.($list)") $"($policy): ($list)" }
		let meta = (one-rule $policy "leave ownerReferences and finalizers")
		for f in (schema '#TenantRefusedMetadata') { assert ($meta | str contains $"object.metadata.($f)") $f }
	}
	let template = (one-rule templates "leave ownerReferences and finalizers")
	for f in (schema '#TenantRefusedMetadata') { assert ($template | str contains $"object.spec.template.metadata.($f)") $"the template's ($f)" }
	let objects = ((policies).objects.spec.validations | first | get expression)
	for f in (schema '#TenantRefusedMetadata') { assert ($objects | str contains $"!has\(object.metadata.($f)\)") $f }
}

def test_services_and_secrets [] {
	print "test a Service is a ClusterIP with no externalIPs and a Secret is no service account's token..."
	assert equal (one-rule services "is a ClusterIP") "!has(object.spec.type) || object.spec.type == 'ClusterIP'"
	assert ((one-rule services "externalIPs") | str contains "size(object.spec.externalIPs) == 0")
	assert ((one-rule secrets "no service account token") | str contains "kubernetes.io/service-account-token")
	assert ((one-rule secrets "kubernetes.io/service-account.*") | str contains "k.startsWith('kubernetes.io/service-account.')")
}

def test_a_cluster_is_held_to_the_engines_allow_list [] {
	print "test a Cluster is named <app>-db, runs exactly an approved image by digest from its own namespace, sets only the fields of #TenantClusterSpec (and the server's defaults), no superuser, no inheritedMetadata or priorityClassName..."
	assert ((one-rule clusters "is named <app>-db") | str contains "endsWith('-db')")
	let image = (one-rule clusters "approved database base")
	for a in (schema '#TenantDatabaseImages') { assert ($image | str contains $"-database-base:($a.major)@($a.digest)") $image }
	assert ($image | str contains "'127.0.0.1:5000/' + request.namespace + '/' + variables.base") $image
	let spec = (schema '#TenantClusterSpec')
	let defaults = (schema '#TenantClusterDefaults')
	let keys = (one-rule clusters "sets only the fields the engine renders")
	for k in ($spec.keys | append $defaults.keys) { assert ($keys | str contains $"'($k)'") $"key ($k)" }
	for k in [inheritedMetadata priorityClassName superuserSecret imageCatalogRef plugins env envFrom projectedVolumeTemplate serviceAccountTemplate import recovery externalClusters] {
		assert (not ($keys | str contains $"'($k)'")) $"the key ($k) is refused"
	}
	assert ((one-rule clusters "no inheritedMetadata") | str contains "!has(variables.spec.inheritedMetadata) && !has(variables.spec.priorityClassName)")
	for k in ($spec.postgresql | append $defaults.postgresql) { assert ((one-rule clusters "only postgresql.parameters") | str contains $"'($k)'") $k }
	for k in $spec.bootstrap { assert ((one-rule clusters "bootstraps with initdb") | str contains $"'($k)'") $k }
	for k in ($spec.initdb | append $defaults.initdb) { assert ((one-rule clusters "initdb sets no SQL") | str contains $"'($k)'") $k }
	assert equal (one-rule clusters "enableSuperuserAccess: false") "has(variables.spec.enableSuperuserAccess) && variables.spec.enableSuperuserAccess == false"
	assert equal (one-rule clusters "no superuserSecret") "!has(variables.spec.superuserSecret)"
	assert ((one-rule clusters "uid and gid") | str contains $"variables.spec.postgresUID == ($spec.uid)")
}

def test_the_parameters_are_the_engines_bounds [] {
	print "test every Postgres parameter of #TenantParameters has its bound, and a name it does not list is refused..."
	let allowed = (schema '#TenantParameters')
	let names = (one-rule clusters "only the Postgres parameters")
	for p in ($allowed | columns) {
		assert ($names | str contains $"'($p)'") $"($p) is listed"
		let bound = (rules clusters $"parameter ($p) to its bound")
		assert equal ($bound | length) 1 $"($p) has one bound"
		let rule = $allowed | get $p
		let e = $bound | first
		if $rule.kind == "mem" { assert ($e | str contains $"int\(variables.params['($p)'].replace\(' ', ''\)\) * ($rule | get -o base | default 1)") $"($p): a bare number is in the setting's own unit" }
		match $rule.kind {
			"enum" => { for v in $rule.values { assert ($e | str contains $"'($v)'") $"($p): ($v)" } }
			_ => { assert ($e | str contains $"<= ($rule.max)") $"($p) max"; assert ($e | str contains $">= ($rule.min)") $"($p) min" }
		}
	}
	for forbidden in [archive_command restore_command ssl_passphrase_command shared_preload_libraries session_preload_libraries data_directory hba_file unix_socket_directories] {
		assert (not ($names | str contains $"'($forbidden)'")) $forbidden
	}
	assert equal (rules clusters "to its bound" | length) ($allowed | columns | length)
}

def test_the_roles_and_services_of_a_cluster [] {
	print "test a managed role is no superuser, creates no roles and joins none of #TenantRefusedRoles, and a managed Service is a ClusterIP with no externalIPs..."
	let roles = (one-rule clusters "are members of no reserved role")
	for r in (schema '#TenantRefusedRoles') { assert ($roles | str contains $"'($r)'") $r }
	for p in (schema '#TenantRefusedRolePrefixes') { assert ($roles | str contains $"x.startsWith\('($p)'\)") $"membership prefix ($p)" }
	let named = (one-rule clusters "is named no reserved role")
	for r in (schema '#TenantRefusedRoles') { assert ($named | str contains $"'($r)'") $"name ($r)" }
	for p in (schema '#TenantRefusedRolePrefixes') { assert ($named | str contains $"r.name.startsWith\('($p)'\)") $"name prefix ($p)" }
	let owner = (one-rule clusters "database owner")
	for p in (schema '#TenantRefusedRolePrefixes') { assert ($owner | str contains $"startsWith\('($p)'\)") $"owner prefix ($p)" }
	assert ($owner | str contains "variables.owner") $owner
	let database = (one-rule clusters "is named no reserved database")
	for d in (schema '#TenantRefusedDatabases') { assert ($database | str contains $"'($d)'") $d }
	let effective = ((policies).clusters.spec.variables | where name == owner | get expression | first)
	assert ($effective | str contains ": variables.database") "the owner defaults to the database's name"
	let storage = (one-rule clusters "size and class of its storage")
	for k in (schema '#TenantStorageKeys') { assert ($storage | str contains $"'($k)'") $k }
	let stop = (one-rule clusters "seconds to stop")
	assert ($stop | str contains $"<= (schema '#TenantMaxStopSeconds')") $stop
	for k in [stopDelay smartShutdownTimeout] { assert ($stop | str contains $"variables.spec.($k)") $k }
	assert ($roles | str contains "r.superuser == true") $roles
	assert ($roles | str contains "r.createrole == true") $roles
	let services = (one-rule clusters "publishes its Services inside the cluster")
	assert ($services | str contains "externalIPs") $services
	assert ($services | str contains "'ClusterIP'") $services
}

def test_who_is_not_judged_and_what_the_bindings_do [] {
	print "test the kube-system controllers that make pods are named one by one, the operator is a parameter and a Cluster's request that changes no spec is not judged again, and the bindings carry the actions asked..."
	let all = (policies ', operators: ["system:serviceaccount:cnpg-system:cnpg-manager"]')
	for p in [pods templates objects services secrets] {
		let conditions = ($all | get $p).spec.matchConditions
		assert equal ($conditions | get name) [not-a-controller not-the-operator]
		assert ($conditions.0.expression | str contains "system:serviceaccount:kube-system:replicaset-controller") $p
		assert (not ($conditions.0.expression | str contains "kube-system:*")) "no wildcard of kube-system"
		assert ($conditions.1.expression | str contains "system:serviceaccount:cnpg-system:cnpg-manager") $p
	}
	let c = ($all.clusters.spec.matchConditions)
	assert equal ($c | get name) [not-a-controller not-the-operator spec-or-annotations-change]
	assert ($c.2.expression | str contains "object.spec != oldObject.spec") $c.2.expression
	assert ($c.2.expression | str contains "object.metadata.annotations") "an annotation-only update is judged"
	let notes = (one-rule clusters "carries no cnpg.io/ annotation")
	for p in (schema '#TenantRefusedClusterAnnotationPrefixes') { assert ($notes | str contains $"k.startsWith\('($p)'\)") $p }
	let bindings = (schema '(#TenantAdmission & {label: "x/y"}).objects' | where kind == "ValidatingAdmissionPolicyBinding")
	assert equal ($bindings | length) 6
	for b in $bindings { assert equal $b.spec.validationActions [Warn Audit] }
	let deny = (schema '(#TenantAdmission & {label: "x/y", actions: ["Deny", "Audit"]}).objects' | where kind == "ValidatingAdmissionPolicyBinding")
	for b in $deny { assert equal $b.spec.validationActions [Deny Audit] }
	assert equal ((policies).pods.spec.failurePolicy) "Fail"
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
# The API server's own answers (--kind).

const tenant_ns = "studio-admission-case"
const plain_ns = "admission-case-plain"
const base = "127.0.0.1:5000/studio-admission-case/app-database-base:18@sha256:5d6f9f38a065c1c001656b4e667f875145a3179c92af0bd07f6f414c75788598"

def --wrapped kubectl-in [context: string, input: string, ...args: string]: nothing -> record {
	$input | ^kubectl --context $context ...$args | complete
}

# Each case: what it is, the object, and whether the policies refuse it ("" admitted, else the policy that says so).
def cases [ns: string]: nothing -> list {
	let own = $"127.0.0.1:5000/($ns)/app:1"
	let safe = {allowPrivilegeEscalation: false}
	let pod = {|spec| {apiVersion: v1, kind: Pod, metadata: {name: p, namespace: $ns}, spec: ({containers: [{name: c, image: $own, securityContext: $safe}]} | merge $spec)} }
	let podmeta = {|meta| {apiVersion: v1, kind: Pod, metadata: ({name: p, namespace: $ns} | merge $meta), spec: {containers: [{name: c, image: $own, securityContext: $safe}]}} }
	let deploy = {|spec| {apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: $ns}, spec: {selector: {matchLabels: {a: d}}, template: {metadata: {labels: {a: d}}, spec: ({containers: [{name: c, image: $own, securityContext: $safe}]} | merge $spec)}}} }
	let deploymeta = {|meta| {apiVersion: apps/v1, kind: Deployment, metadata: {name: d, namespace: $ns}, spec: {selector: {matchLabels: {a: d}}, template: {metadata: ({labels: {a: d}} | merge $meta), spec: {containers: [{name: c, image: $own, securityContext: $safe}]}}}} }
	let job = {|meta| {apiVersion: batch/v1, kind: Job, metadata: {name: j, namespace: $ns}, spec: {template: {metadata: $meta, spec: {restartPolicy: Never, containers: [{name: c, image: $own, securityContext: $safe}]}}}} }
	let service = {|spec| {apiVersion: v1, kind: Service, metadata: {name: s, namespace: $ns}, spec: ({selector: {a: d}, ports: [{port: 80}]} | merge $spec)} }
	let cluster = {|spec| {apiVersion: postgresql.cnpg.io/v1, kind: Cluster, metadata: {name: app-db, namespace: $ns}, spec: ({instances: 1, imageName: $base, enableSuperuserAccess: false, postgresUID: 999, postgresGID: 999, storage: {size: 1Gi}, bootstrap: {initdb: {database: app, owner: app}}, postgresql: {parameters: {max_connections: "100", shared_buffers: "256MB", statement_timeout: "30s", wal_level: logical, random_page_cost: "1.1"}}} | merge $spec)} }
	let policy = "ValidatingAdmissionPolicy"
	[
		[what obj says];
		["a pod of the namespace's own image" (do $pod {}) ""]
		["a pod of an image outside the registry's path" (do $pod {containers: [{name: c, image: "busybox:1.37", securityContext: $safe}]}) pods]
		["a pod of another namespace's image" (do $pod {containers: [{name: c, image: "127.0.0.1:5000/studio-other/app:1", securityContext: $safe}]}) pods]
		["a pod of the image of a namespace named as its own begins" (do $pod {containers: [{name: c, image: $"127.0.0.1:5000/($ns)-b/app:1", securityContext: $safe}]}) pods]
		["a pod with an init container from outside" (do $pod {initContainers: [{name: i, image: "busybox:1.37", securityContext: $safe}]}) pods]
		["a pod that runs as the publisher's account" (do $pod {serviceAccountName: publisher}) pods]
		["a pod that runs as the publisher's account by its deprecated field" (do $pod {serviceAccount: publisher}) pods]
		["a pod that runs as the builder's account" (do $pod {serviceAccountName: studio-builder}) pods]
		["a pod that runs as a database's own account" (do $pod {serviceAccountName: app-db}) pods]
		["a pod with a cnpg.io/cluster label" (do $podmeta {labels: {"cnpg.io/cluster": app-db}}) pods]
		["a pod with a finalizer" (do $podmeta {finalizers: ["example.com/hold"]}) pods]
		["a pod with an ownerReference" (do $podmeta {ownerReferences: [{apiVersion: v1, kind: ServiceAccount, name: publisher, uid: "00000000-0000-0000-0000-000000000001"}]}) pods]
		["a pod that leaves allowPrivilegeEscalation unset" (do $pod {containers: [{name: c, image: $"127.0.0.1:5000/($ns)/app:1"}]}) pods]
		["a pod that sets allowPrivilegeEscalation true" (do $pod {containers: [{name: c, image: $"127.0.0.1:5000/($ns)/app:1", securityContext: {allowPrivilegeEscalation: true}}]}) pods]
		["a pod that adds a capability" (do $pod {containers: [{name: c, image: $"127.0.0.1:5000/($ns)/app:1", securityContext: {allowPrivilegeEscalation: false, capabilities: {add: [NET_BIND_SERVICE]}}}]}) pods]
		["a deployment of the namespace's own image and the safe volumes" (do $deploy {volumes: [{name: e, emptyDir: {}} {name: m, configMap: {name: x}}]}) ""]
		["a deployment of an image outside the registry's path" (do $deploy {containers: [{name: c, image: "ghcr.io/x/y:1", securityContext: $safe}]}) templates]
		["a deployment that runs as the publisher's account" (do $deploy {serviceAccountName: publisher}) templates]
		["a deployment that runs as a database's own account" (do $deploy {serviceAccountName: app-db}) templates]
		["a deployment with a runtimeClassName" (do $deploy {runtimeClassName: gvisor}) templates]
		["a deployment with a priorityClassName" (do $deploy {priorityClassName: system-cluster-critical}) templates]
		["a deployment with hostUsers false" (do $deploy {hostUsers: false}) templates]
		["a deployment with a Dapr sidecar annotation" (do $deploymeta {annotations: {"dapr.io/sidecar-image": "ghcr.io/x/daprd:1"}}) templates]
		["a deployment with a hostPath volume" (do $deploy {volumes: [{name: h, hostPath: {path: "/"}}]}) templates]
		["a deployment with an nfs volume" (do $deploy {volumes: [{name: n, nfs: {server: "10.0.0.1", path: "/"}}]}) templates]
		["a deployment with a generic ephemeral volume, a source the allow-list does not name" (do $deploy {volumes: [{name: g, ephemeral: {volumeClaimTemplate: {spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}}}}]}) templates]
		["a deployment whose pods carry a cnpg.io label" (do $deploymeta {labels: {"cnpg.io/cluster": app-db}}) templates]
		["a deployment whose pods carry a finalizer" (do $deploymeta {finalizers: ["example.com/hold"]}) templates]
		["a deployment that leaves allowPrivilegeEscalation unset" (do $deploy {containers: [{name: c, image: $own}]}) templates]
		["a deployment that adds a capability" (do $deploy {containers: [{name: c, image: $own, securityContext: {allowPrivilegeEscalation: false, capabilities: {add: [SYS_ADMIN]}}}]}) templates]
		["a job whose pods carry a finalizer" (do $job {finalizers: ["example.com/hold"]}) templates]
		["a job of the namespace's own image" (do $job {}) ""]
		["a ConfigMap with a finalizer" {apiVersion: v1, kind: ConfigMap, metadata: {name: x, namespace: $ns, finalizers: ["example.com/hold"]}} objects]
		["a ConfigMap" {apiVersion: v1, kind: ConfigMap, metadata: {name: x, namespace: $ns}} ""]
		["a ClusterIP Service" (do $service {}) ""]
		["a NodePort Service" (do $service {type: NodePort}) services]
		["a LoadBalancer Service" (do $service {type: LoadBalancer}) services]
		["a Service with externalIPs" (do $service {externalIPs: ["10.0.0.9"]}) services]
		["an ExternalName Service" {apiVersion: v1, kind: Service, metadata: {name: s, namespace: $ns}, spec: {type: ExternalName, externalName: "example.com"}} services]
		["a service account token Secret" {apiVersion: v1, kind: Secret, type: "kubernetes.io/service-account-token", metadata: {name: t, namespace: $ns, annotations: {"kubernetes.io/service-account.name": default}}} secrets]
		["an Opaque Secret that names a service account in an annotation" {apiVersion: v1, kind: Secret, metadata: {name: t, namespace: $ns, annotations: {"kubernetes.io/service-account.name": default}}} secrets]
		["a Cluster as the engine renders it" (do $cluster {}) ""]
		["a Cluster that runs an image by tag alone" (do $cluster {imageName: $"127.0.0.1:5000/($ns)/app-database-base:18"}) clusters]
		["a Cluster that runs another namespace's approved image" (do $cluster {imageName: ($base | str replace $ns studio-other)}) clusters]
		["a Cluster that runs an image outside the registry" (do $cluster {imageName: "ghcr.io/cloudnative-pg/postgresql:18"}) clusters]
		["a Cluster not named <app>-db" ((do $cluster {}) | update metadata.name app) clusters]
		["a Cluster with superuser access" (do $cluster {enableSuperuserAccess: true}) clusters]
		["a Cluster that leaves superuser access to its default" ((do $cluster {}) | update spec {|c| $c.spec | reject enableSuperuserAccess }) clusters]
		["a Cluster with a superuserSecret" (do $cluster {superuserSecret: {name: x}}) clusters]
		["a Cluster with inheritedMetadata" (do $cluster {inheritedMetadata: {labels: {a: b}}}) clusters]
		["a Cluster with a priorityClassName" (do $cluster {priorityClassName: system-cluster-critical}) clusters]
		["a Cluster with an imageCatalogRef" (do $cluster {imageCatalogRef: {apiGroup: postgresql.cnpg.io, kind: ImageCatalog, name: x, major: 18}}) clusters]
		["a Cluster with a postgresql.extensions image" (do $cluster {postgresql: {extensions: [{name: x, image: {reference: evil}}]}}) clusters]
		["a Cluster with SQL of its own in initdb" (do $cluster {bootstrap: {initdb: {database: app, owner: app, postInitSQL: ["select 1"]}}}) clusters]
		["a Cluster that runs the database as uid 26" (do $cluster {postgresUID: 26, postgresGID: 26}) clusters]
		["a Cluster with an archive_command" (do $cluster {postgresql: {parameters: {archive_command: "sh -c evil"}}}) clusters]
		["a Cluster with a shared_preload_libraries" (do $cluster {postgresql: {parameters: {shared_preload_libraries: evil}}}) clusters]
		["a Cluster with more connections than the bound" (do $cluster {postgresql: {parameters: {max_connections: "5000"}}}) clusters]
		["a Cluster with more shared_buffers than the bound" (do $cluster {postgresql: {parameters: {shared_buffers: "9TB"}}}) clusters]
		["a Cluster with a timeout beyond the bound" (do $cluster {postgresql: {parameters: {statement_timeout: "2d"}}}) clusters]
		["a Cluster with a parameter that is no number" (do $cluster {postgresql: {parameters: {max_connections: "many"}}}) clusters]
		["a Cluster with fsync off" (do $cluster {postgresql: {parameters: {fsync: "off"}}}) clusters]
		["a Cluster with a managed superuser role" (do $cluster {managed: {roles: [{name: r, login: true, superuser: true}]}}) clusters]
		["a Cluster with a managed role that creates roles" (do $cluster {managed: {roles: [{name: r, login: true, createrole: true}]}}) clusters]
		["a Cluster with a managed role in pg_execute_server_program" (do $cluster {managed: {roles: [{name: r, login: true, inRoles: [pg_execute_server_program]}]}}) clusters]
		["a Cluster whose owner is a pg_ role" (do $cluster {bootstrap: {initdb: {database: app, owner: pg_monitor}}}) clusters]
		["a Cluster with a cnpg.io/podPatch annotation" ((do $cluster {}) | update metadata {|c| $c.metadata | insert annotations {"cnpg.io/podPatch": "[]"}}) clusters]
		["a Cluster with a cnpg.io/validation annotation" ((do $cluster {}) | update metadata {|c| $c.metadata | insert annotations {"cnpg.io/validation": "disabled"}}) clusters]
		["a Cluster with a cnpg.io/reconcilePodSpec annotation" ((do $cluster {}) | update metadata {|c| $c.metadata | insert annotations {"cnpg.io/reconcilePodSpec": "disabled"}}) clusters]
		["a Cluster whose database is postgres, and so its owner" (do $cluster {bootstrap: {initdb: {database: postgres}}}) clusters]
		["a Cluster with shared_buffers written with a space before its unit" (do $cluster {postgresql: {parameters: {shared_buffers: "256 MB"}}}) ""]
		["a Cluster with a managed role named cnpg_x" (do $cluster {managed: {roles: [{name: cnpg_x, login: true}]}}) clusters]
		["a Cluster with a managed role named postgres" (do $cluster {managed: {roles: [{name: postgres, login: true}]}}) clusters]
		["a Cluster with a managed role in a pg_ role" (do $cluster {managed: {roles: [{name: r, login: true, inRoles: [pg_monitor]}]}}) clusters]
		["a Cluster with a pvcTemplate of its own" (do $cluster {storage: {size: 1Gi, pvcTemplate: {accessModes: [ReadWriteOnce]}}}) clusters]
		["a Cluster that waits a day to stop" (do $cluster {stopDelay: 86400}) clusters]
		["a Cluster with shared_buffers past the bound in its own unit (8 kB blocks)" (do $cluster {postgresql: {parameters: {shared_buffers: "1048577"}}}) clusters]
		["a Cluster with shared_buffers at the bound in its own unit" (do $cluster {postgresql: {parameters: {shared_buffers: "524288"}}}) ""]
		["a Cluster with a managed role that is a plain login" (do $cluster {managed: {roles: [{name: r, login: true}]}}) ""]
		["a Cluster with a LoadBalancer Service of its own" (do $cluster {managed: {services: {additional: [{selectorType: rw, serviceTemplate: {metadata: {name: lb}, spec: {type: LoadBalancer}}}]}}}) clusters]
	]
}

def verdict [r: record]: nothing -> string {
	if $r.exit_code == 0 { "" } else if ($r.stderr =~ "ValidatingAdmissionPolicy '([a-z-]+)'") { $r.stderr | parse --regex "ValidatingAdmissionPolicy '(?<p>[a-z-]+)'" | get p | first | str replace $"($policy_prefix)-engine-" "" } else { $"other: ($r.stderr | str trim)" }
}

def test_the_api_server [context: string] {
	print $"test the API server of ($context) refuses each bad object by its policy and admits the good ones, a namespace without the tenant label is not judged, and a controller's pod is not either..."
	let crd = (^kubectl --context $context get crd clusters.postgresql.cnpg.io --ignore-not-found -o name | complete)
	let has_cnpg = ($crd.stdout | str trim | is-not-empty)
	if not $has_cnpg { print "  (no CloudNativePG CRD in the cluster: the Cluster cases are not asked)" }
	let objects = (schema $"\(#TenantAdmission & {label: \"($label)\", name: \"($policy_prefix)\", actions: [\"Deny\"]}).objects")
	let applied = (kubectl-in $context ({apiVersion: v1, kind: List, items: $objects} | to json) apply --server-side --force-conflicts --field-manager admission-test -f -)
	assert equal $applied.exit_code 0 $applied.stderr
	for ns in [[$tenant_ns true] [$plain_ns false]] {
		let meta = if $ns.1 { {name: $ns.0, labels: {($label): "true"}} } else { {name: $ns.0} }
		let made = (kubectl-in $context ({apiVersion: v1, kind: Namespace, metadata: $meta} | to json) apply -f -)
		assert equal $made.exit_code 0 $made.stderr
		for sa in [publisher studio-builder app-db] {
			let m = (kubectl-in $context ({apiVersion: v1, kind: ServiceAccount, metadata: {name: $sa, namespace: $ns.0}} | to json) apply -f -)
			assert equal $m.exit_code 0 $m.stderr
		}
	}
	# a policy and its binding take a moment to be served: ask for a refusal until it comes
	let probe = (cases $tenant_ns | where what == "a NodePort Service" | first)
	mut served = false
	for _ in 1..60 {
		if (verdict (kubectl-in $context ($probe.obj | to json) apply --dry-run=server -f -)) == "services" { $served = true; break }
		sleep 1sec
	}
	assert $served "the policies are served"
	for t in (^kubectl --context $context get validatingadmissionpolicy -o json | from json | get items | where {|p| $p.metadata.name | str starts-with $policy_prefix }) {
		let problems = ($t.status?.typeChecking?.expressionWarnings? | default [])
		assert equal $problems [] $"($t.metadata.name) type-checks: ($problems | to json)"
	}
	mut failed = []
	for c in (cases $tenant_ns) {
		if (not $has_cnpg) and ($c.obj.kind == Cluster) { continue }
		let got = (verdict (kubectl-in $context ($c.obj | to json) apply --dry-run=server -f -))
		if $got != $c.says { $failed = ($failed | append $"($c.what): wanted '($c.says)', got '($got)'") }
	}
	for c in (cases $plain_ns | where says != "") {
		if (not $has_cnpg) and ($c.obj.kind == Cluster) { continue }
		let got = (verdict (kubectl-in $context ($c.obj | to json) apply --dry-run=server -f -))
		if $got != "" { $failed = ($failed | append $"(plain namespace) ($c.what): admitted by no policy, got '($got)'") }
	}
	# a controller makes pods only from templates the policy judged: its request is not judged
	let bad = (cases $tenant_ns | where what == "a pod of an image outside the registry's path" | first)
	let r = ($bad.obj | to json | ^kubectl --context $context --as system:serviceaccount:kube-system:replicaset-controller apply --dry-run=server -f - | complete)
	if (verdict $r) != "" { $failed = ($failed | append $"a pod of the ReplicaSet controller was judged: ($r.stderr | str trim)") }
	assert equal $failed [] ($failed | str join "\n")
}
