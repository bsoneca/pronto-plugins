# tenant.nu: what a tenant's release (`release.nu --tenant <namespace> --host <host>`) needs beyond the operator's. A tenant's release has two
# actors: the namespace's publisher (the KUBECONFIG it is given: rights in the namespace alone, no tunnel, no operator) and the push
# identity (`--push-kubeconfig`, or the pod's own account), which alone may reach the node's registry pod and the Envoy Gateway
# data plane. The checks here are the ones the operator's release makes with cluster-wide reads, made with the rights a publisher has.
# It imports nothing of the release (release.nu imports it).

use tunnel.nu
use build.nu [stamp]

# The engine's own folder: its schema is the one a tenant's release trusts, never the app's copy of it.
const engine_dir = path self .

# A tenant's namespace, as Studio's provisioner names it.
export def check-tenant-name [tenant: string] {
	if not ($tenant =~ '^studio-[a-z0-9-]{1,55}$') {
		error make {msg: $"a tenant's namespace is studio-<owner>-<app>-<hash>: ($tenant) is not"}
	}
}

# The kinds a tenant's publisher may write, read from the engine's own schema (`#PublisherKinds`, the one list the CUE also uses).
export def publisher-kinds []: nothing -> list<string> {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#PublisherKinds' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #PublisherKinds: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The issuers a tenant's release may register clients at, read from the engine's own schema (`#TenantIssuers`), never the app's copy.
export def tenant-issuers []: nothing -> list<string> {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#TenantIssuers' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #TenantIssuers: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# One of the engine's own schema definitions, as data.
def schema-export [expr: string]: nothing -> any {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e $expr node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export ($expr): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# A name the tenant's Node gives kubectl (a Secret a service reads, a ConfigMap it seeds) is a Kubernetes resource name, never an option:
# one that starts with a dash would be parsed as a flag (a `--kubeconfig` can name a credential plugin kubectl runs). Said before the first
# kubectl call that carries one.
export def check-names [node: record] {
	let names = ($node.services? | default {} | values | each {|s| ($s.secrets? | default {} | values) | append ($s.seed? | default {} | columns) } | flatten | uniq)
	let bad = ($names | where {|n| not (($n | into string) =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') })
	if ($bad | is-not-empty) { error make {msg: $"Node.services name ($bad | length) Secret or seed name\(s\) that are not Kubernetes resource names \(lowercase letters, digits, '-' and '.', starting and ending with a letter or digit\): ($bad | each {|n| $n | into string | str substring 0..40 | to nuon } | str join ', ')"} }
}

# A ConfigMap a service seeds is a ConfigMap the release writes: never one of the objects the provisioner or the engine owns (`#TenantReserved`).
export def check-seeds [seeds: list] {
	let reserved = (schema-export '#TenantReserved' | where kind == ConfigMap | get name)
	let bad = ($seeds | where {|s| $s.name in $reserved } | get name)
	if ($bad | is-not-empty) { error make {msg: $"Node.services seed the ConfigMap ($bad | str join ', '), which the provisioner or the engine owns"} }
}

# What a release may retire (kind to the kubectl resource it deletes, as kind.group), read from the engine's own schema (`#RetireKinds`).
export def retire-kinds []: nothing -> record {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#RetireKinds' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #RetireKinds: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# What a tenant's release deletes after it rolled out, decided here in trusted code and never taken from the Node it exported (a release.cue
# may export a Node of its own that skips the schema's `retire`): each entry's kind must be one of `kinds` (the engine's allowlist, which holds no
# Cluster, volume claim, Secret or ExternalSecret), the resource kubectl is told is the allowlist's own for that kind, the name a plain name
# (never an option, a list or a selector), and neither the release's own record nor an object this release writes. It is always deleted in
# the tenant's namespace, `-n` of the caller. Refused before any write. Answers `{resource, name}` for each.
export def check-retire [node: record, kinds: record, objects: list]: nothing -> list {
	# what the release writes: its rendered objects and the ConfigMaps its services seed (applied apart from them, then mounted)
	let seeded = ($node.services? | default {} | values | each {|s| $s.seed? | default {} | columns } | flatten | each {|n| $"ConfigMap/($n)" })
	let written = ($objects | each {|o| $"($o.kind)/($o.metadata.name)" } | append $seeded)
	let exported = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#TenantNoRetire' node.cue } | complete)
	if $exported.exit_code != 0 { error make {msg: $"the engine's schema does not export #TenantNoRetire: ($exported.stderr | str trim)"} }
	let never = ($exported.stdout | from json)
	let reserved = (schema-export '#TenantReserved')
	let planned = ($node.retire? | default [])
	let problems = ($planned | each {|r|
		let kind = ($r.kind? | default "")
		let name = ($r.name? | default "")
		let id = $"($kind)/($name)"
		if ($kinds | get -o $kind) == null {
			$"retire names ($id): a tenant's release may retire only ($kinds | columns | str join ', ')"
		} else if not ($name =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') {
			$"retire names ($id): not a plain resource name"
		} else if $kind in $never {
			$"retire names ($id), which a tenant's release never retires \(the provisioner's publisher account, a NetworkPolicy and a CronJob are not its to delete\)"
		} else if $id in $written {
			$"retire names ($id), which this release writes"
		} else if ($reserved | any {|x| $x.kind == $kind and $x.name == $name }) {
			$"retire names ($id), an object the provisioner or the engine owns"
		}
	} | compact)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's retirement is refused: ($problems | str join '; ')"} }
	$planned | each {|r| {resource: ($kinds | get $r.kind), name: $r.name} }
}

# Every issuer a tenant's auth names must be exactly one of `issuers` (the engine's list): the release fetches the issuer's discovery
# document and POSTs a registration to it from Studio's builder pod, so an issuer the game picked is a request the pod makes for it (SSRF).
# `settings` is the OIDC settings the auth provider environment made and `environment` the compose auth service's own; a key ending in
# `_ISSUER` or `_INTERNAL` is an issuer. Refused before any fetch, naming the key: not https, with credentials or a port, a literal IP, or
# an origin not on the list. The error never carries the value (a URL may hold credentials, a path or a query). No auth service, or no
# issuer, passes.
export def check-issuers [settings: record, environment: record, issuers: list<string>] {
	let named = ([$settings $environment] | each {|r| $r | transpose key value } | flatten
		| where {|e| ($e.key =~ '(_ISSUER|_INTERNAL)$') and (($e.value | into string) | is-not-empty) }
		| each {|e| {key: $e.key, value: ($e.value | into string)} } | uniq)
	let problems = ($named | each {|e|
		let url = $e.value
		let authority = ($url | str replace -r '^https://' '' | split row -r '[/?#]' | first)
		if not ($url | str starts-with "https://") {
			$"($e.key) is refused: an issuer is an https origin"
		} else if ($authority | str contains "@") {
			$"($e.key) is refused: an issuer carries no credentials"
		} else if ($authority | str starts-with "[") {
			$"($e.key) is refused: an issuer is a name, never an IP address"
		} else if ($authority | str contains ":") {
			$"($e.key) is refused: an issuer names no port"
		} else if ($authority =~ '^[0-9.]+$') or ($authority =~ '^0[xX][0-9a-fA-F.]+$') {
			$"($e.key) is refused: an issuer is a name, never an IP address"
		} else if $url not-in $issuers {
			$"($e.key) is refused: it is not an issuer a tenant may use \(the engine allows ($issuers | str join ', ')\)"
		}
	} | compact)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's issuers are refused: ($problems | str join '; ')"} }
}

# The app's copy of the schema (`node/schema/node.cue`, which its release.cue imports) is made the engine's own, byte for byte: a copy the
# game's author edited would load refusals of its own choosing. It must be a regular file, the only one in its folder; the engine's copy
# replaces whatever it said.
export def check-engine-copy [app_dir: string] {
	let own = ($engine_dir | path join schema node.cue)
	let theirs = ($app_dir | path join node schema node.cue)
	let dir = ($theirs | path dirname)
	# `node` and `node/schema` are real folders of the app, never links (a link would lead the replacement into another checkout)
	let node_dir = ($app_dir | path join node)
	for step in [{in: $app_dir, name: "node", label: "node"} {in: $node_dir, name: "schema", label: "node/schema"}] {
		let found = if ($step.in | path type) == "dir" { ls -a $step.in | where {|e| ($e.name | path basename) == $step.name } } else { [] }
		if ($found | is-not-empty) and $found.0.type != "dir" { error make {msg: $"the app's ($step.label) is a ($found.0.type), not a folder: a tenant's release follows no link to its schema"} }
	}
	let entry = if ($dir | path type) == "dir" { ls -a $dir | where {|e| ($e.name | path basename) == "node.cue" } } else { [] }
	if ($entry | is-empty) { error make {msg: $"($theirs) is missing: a tenant's release imports the engine's schema from the app's node/schema"} }
	# only a regular file of the engine's own size is opened: a link, a FIFO (which would wait for a writer) or a device is refused unread
	if ($entry.0.type != "file") { error make {msg: $"the app's node/schema/node.cue is a ($entry.0.type), not a regular file: a tenant's release trusts no schema its author could have edited"} }
	# the folder holds that file alone: anything else would be loaded with the schema's package
	let others = (ls -a $dir | get name | each {|n| $n | path basename } | where {|n| $n != "node.cue" })
	if ($others | is-not-empty) { error make {msg: $"the app's node/schema holds ($others | str join ', ') beside node.cue: a tenant's release trusts no schema folder its author could have added to"} }
	# …and the engine's own copy is put over it, so nothing the author wrote is ever read (a comparison would leave a window between check and
	# use): written beside it and renamed over it, never into the entry itself. An app that runs its own vendored engine holds the one file
	# (same real path): nothing to put over it.
	if ($own | path expand) == ($theirs | path expand) { return }
	let fresh = ($dir | path join $".node.cue.(random uuid)")
	cp $own $fresh
	mv -f $fresh $theirs
}

def as-list [v: any]: nothing -> list {
	# a list of mappings describes as a table
	if $v == null { [] } else if (($v | describe) =~ '^(list|table)') { $v } else { [$v] }
}

# Why a path a compose file names may not be read (null when it may): `docker compose config` reads env_file, label_file, extends files and
# secrets' and configs' files with the release process's own rights, so a tenant's compose file may name only files inside its own folder,
# spelled as plain paths (no variable, no URL), as they resolve after links.
def compose-path-problem [root: string, value: any, what: string]: nothing -> any {
	if $value == null { return null }
	let p = (if ($value | describe | str starts-with "record") { $value.path? | default "" } else { $value | into string })
	if ($p | is-empty) { return null }
	if ($p | str contains '$') { return $"($what) names ($p), a path with a variable in it: a tenant's compose file names plain paths" }
	if ($p =~ '^[A-Za-z][A-Za-z0-9+.-]*:') { return $"($what) names ($p), which is not a path inside the app's own folder" }
	let full = ($root | path join $p | path expand)
	if $full == $root or ($full | str starts-with $"($root)/") { null } else { $"($what) names ($p), which is outside the app's own folder" }
}

# A tenant's compose files are checked before anything resolves them (the release's own `docker compose config` would read what they name with
# its own rights, and a value read from a file outside the app could reach a Job's environment): nothing they name may be outside the app's
# folder, no `include` is allowed, ssh forwarding is refused, and the project's `.env` names no COMPOSE_ variable (which can add compose files).
# Studio flattens its games' compose projects in a jail before the engine runs; this holds for any other caller.
export def check-compose-sources [app_dir: string] {
	let root = ($app_dir | path expand)
	let named = (ls -a $root | where {|e| let n = ($e.name | path basename); $n == ".env" or $n =~ '^(docker-)?compose([.-][A-Za-z0-9_.-]*)?\.ya?ml$' })
	# compose follows a link (and reads a folder's files as it likes): only a regular file is read here, so anything else with the name is refused
	mut problems = ($named | where type != file | each {|e| $"($e.name | path basename) is a ($e.type), not a regular file: compose would follow it to what this check does not read" })
	let files = ($named | where type == file | get name | where {|f| ($f | path basename) != ".env" })
	let env_file = ($root | path join .env)
	# only a regular file is opened: a `.env` that is a link was refused above and is never read
	if ($named | any {|e| ($e.name | path basename) == ".env" and $e.type == file }) {
		let names = (open --raw $env_file | lines | where {|l| ($l | str trim) =~ '^(export\s+)?COMPOSE_' })
		if ($names | is-not-empty) { $problems = ($problems | append ".env names a COMPOSE_ variable, which can add compose files from anywhere") }
	}
	for f in $files {
		let name = ($f | path basename)
		let parsed = (try { {ok: true, doc: (open --raw $f | from yaml)} } catch { {ok: false, doc: null} })
		let doc = $parsed.doc
		# a file with nothing in it (comments alone) names nothing
		if $parsed.ok and ($doc == null) { continue }
		if not $parsed.ok or not ($doc | describe | str starts-with "record") { $problems = ($problems | append $"($name) cannot be read as a YAML mapping"); continue }
		if ($doc | get -o include) != null { $problems = ($problems | append $"($name) has include, which pulls in files the engine does not read first") }
		for kind in [secrets configs] {
			for e in (($doc | get -o $kind | default {}) | transpose k v) {
				let bad = (compose-path-problem $root ($e.v | get -o file) $"($name) ($kind).($e.k).file")
				if $bad != null { $problems = ($problems | append $bad) }
			}
		}
		for s in (($doc | get -o services | default {}) | transpose k v) {
			let at = $"($name) services.($s.k)"
			for key in [env_file label_file] {
				for item in (as-list ($s.v | get -o $key)) {
					let bad = (compose-path-problem $root $item $"($at).($key)")
					if $bad != null { $problems = ($problems | append $bad) }
				}
			}
			let extends = ($s.v | get -o extends)
			# extends within the same file is allowed; one that names a file pulls in a file this check does not read, as include does
			if $extends != null and ($extends | describe | str starts-with "record") and (($extends | get -o file) != null) {
				$problems = ($problems | append $"($at).extends.file names another file, which this check does not read: extends within the same file is allowed")
			}
			let build = ($s.v | get -o build)
			if $build != null {
				let rec = if ($build | describe | str starts-with "record") { $build } else { {context: $build} }
				let ctx = ($rec | get -o context | default ".")
				let bad = (compose-path-problem $root $ctx $"($at).build.context")
				if $bad != null { $problems = ($problems | append $bad) }
				let df = ($rec | get -o dockerfile)
				if $df != null {
					let bad = (compose-path-problem $root ($root | path join $ctx $df) $"($at).build.dockerfile")
					if $bad != null { $problems = ($problems | append $bad) }
				}
				let extra = ($rec | get -o additional_contexts | default {})
				let pairs = if ($extra | describe | str starts-with "record") { $extra | transpose k v | each {|p| $p.v } } else { as-list $extra | each {|l| $l | into string | split row -n 2 "=" | last } }
				for v in $pairs {
					if ($v | into string) =~ '^(docker-image|service|target):' { continue }
					let bad = (compose-path-problem $root $v $"($at).build.additional_contexts")
					if $bad != null { $problems = ($problems | append $bad) }
				}
				if (as-list ($rec | get -o ssh) | is-not-empty) { $problems = ($problems | append $"($at).build.ssh forwards the release's ssh agent into a build") }
			}
		}
	}
	if ($problems | is-not-empty) { error make {msg: $"a tenant's compose project is refused before it is resolved: ($problems | str join '; ')"} }
}

# What the engine's own constants say a tenant's release is: the tenants' sandboxed buildkitd and the node's registry as the push reaches it.
export def check-pins [node: record] {
	let buildkit = ($node.tenant?.buildkit? | default "")
	if not ($buildkit =~ '^tcp://buildkitd\.pronto-buildkit-tenants\.svc(\.cluster\.local)?:1234$') {
		error make {msg: $"a tenant's build is the tenants' buildkitd \(tcp://buildkitd.pronto-buildkit-tenants.svc:1234\), not ($buildkit)"}
	}
	let r = $node.build.registry
	if $r.host != "127.0.0.1:5000" or $r.port != 5000 or $r.namespace != "pronto-registry" {
		error make {msg: $"a tenant's registry is the node's \(127.0.0.1:5000, pronto-registry), not ($r.host) \(($r.namespace)\)"}
	}
}

# The service accounts a tenant's pods never run as: the publisher's and the builder's own.
const forbidden_accounts = [publisher studio-builder studio-rc-builder studio-provisioner]

# The volume types a tenant's pod may mount: nothing of the node's (hostPath, and not an nfs, iscsi or csi volume that reaches another
# system), nothing that carries a token but the pod's own (projected, which the API server scopes to its service account).
const volume_types = [configMap secret emptyDir projected persistentVolumeClaim downwardAPI]

# Every container of a tenant's Deployment or Job (init and ephemeral included) that leaves allowPrivilegeEscalation unset is made to say
# false, in trusted code, before `check-objects` and any apply; one that says true stays true, and `check-objects` refuses it.
export def harden-objects [objects: list]: nothing -> list {
	let boxed = {|spec|
		["containers" "initContainers" "ephemeralContainers"] | reduce --fold $spec {|key, acc|
			if ($acc | get -o $key) == null { $acc } else {
				$acc | update $key ($acc | get $key | each {|c|
					if ($c.securityContext?.allowPrivilegeEscalation? | default null) == null { $c | upsert securityContext ($c.securityContext? | default {} | upsert allowPrivilegeEscalation false) } else { $c }
				})
			}
		}
	}
	$objects | each {|o|
		match ($o.kind? | default "") {
			"Deployment" | "Job" => { if ($o.spec?.template?.spec? | default null) == null { $o } else { $o | update spec.template.spec (do $boxed $o.spec.template.spec) } }
			_ => $o
		}
	}
}

# What the engine's CUE refuses, checked again in nushell over the objects the game's own release.cue rendered (its `nodeManifests` is
# the author's, so the schema's `violations` are only as good as the schema it loaded): every object is a kind the publisher writes, in
# the tenant's namespace; a Service is a ClusterIP with no externalIPs; a pod's service account is not the publisher's, its images are
# the tenant's own path of the registry, and it asks for no user namespace, host namespace, privilege, unmasked /proc or unconfined
# seccomp or AppArmor. Said before anything is applied or asked of the server.
export def check-objects [objects: list, node: record, kinds: list<string>] {
	let ns = $node.namespace
	let prefix = $"127.0.0.1:5000/($ns)/"
	let refused_metadata = (schema-export '#TenantRefusedMetadata')
	let reserved = (schema-export '#TenantReserved')
	# the database operator names a Cluster's service account after the Cluster, and a Cluster is named as its author likes: every Cluster's
	# name is an account no pod of the release runs as (and the release's own is `<release>-db`, nothing else)
	let clusters = ($objects | where {|o| ($o.kind? | default "") == "Cluster" } | each {|o| $o.metadata?.name? | default "" })
	let problems = ($objects | each {|o|
		let id = $"($o.kind? | default '?')/($o.metadata?.name? | default '?')"
		mut why = []
		# a name kubectl is handed (rollback reads the Deployments' revisions by it) is a resource name, never an option
		if not (($o.metadata?.name? | default "" | into string) =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') { $why = ($why | append $"($id) is not named as a Kubernetes resource is") }
		# …on the object, and on the metadata a controller copies onto the objects it makes: a pod template's (a ReplicaSet and a Job copy
		# finalizers onto every pod, which then never finish terminating), a CronJob's, an ExternalSecret's target template
		for at in [[metadata] [spec template metadata] [spec jobTemplate spec template metadata] [spec target template metadata]] {
			for field in $refused_metadata {
				if ($o | get -o ($at | into cell-path) | default {} | get -o $field) != null { $why = ($why | append $"($id) sets ($at | append $field | str join '.'), which a tenant's release leaves to the engine") }
			}
		}
		# an ExternalSecret that writes its target from a manifest of its own could set what the template cannot
		if ($o.kind? | default "") == "ExternalSecret" and ($o.spec?.target?.manifest? | default null) != null { $why = ($why | append $"($id) sets spec.target.manifest, which a tenant's release leaves to the operator's store") }
		if ($reserved | any {|r| $r.kind == ($o.kind? | default "") and $r.name == ($o.metadata?.name? | default "") }) { $why = ($why | append $"($id) is an object the provisioner or the engine owns") }
		if $"($o.apiVersion? | default '')/($o.kind? | default '')" not-in $kinds { $why = ($why | append $"($id) is not a kind a tenant's publisher writes") }
		if ($o.metadata?.namespace? | default "") != $ns { $why = ($why | append $"($id) is in namespace ($o.metadata?.namespace? | default 'none'), not ($ns)") }
		# A token a Secret of this type carries is a service account's (the publisher's included): never written by a tenant's release.
		if ($o.kind? | default "") == "Secret" and ($o.type? | default "") == "kubernetes.io/service-account-token" {
			$why = ($why | append $"($id) is a service account token")
		}
		# …nor one the operators make for it: an ExternalSecret's target template is the Secret the controller writes, whose type and annotations the
		# admission policy (which reads the ExternalSecret's sources alone) never sees. A Secret that names a service account in an annotation is the
		# token controller's to fill, of any type.
		let template = ($o.spec?.target?.template? | default {})
		let given = ($o.metadata?.annotations? | default {} | columns) | append ($template.metadata?.annotations? | default {} | columns)
		if ($o.kind? | default "") == "ExternalSecret" and (($template.type? | default "") == "kubernetes.io/service-account-token") {
			$why = ($why | append $"($id) targets a service account token Secret")
		}
		if ($o.kind? | default "") in [Secret ExternalSecret] and ($given | any {|k| $k | str starts-with "kubernetes.io/service-account." }) {
			$why = ($why | append $"($id) names a service account in a kubernetes.io/service-account.* annotation: the token controller would fill it")
		}
		if ($o.kind? | default "") == "Service" {
			if ($o.spec?.type? | default "ClusterIP") != "ClusterIP" { $why = ($why | append $"($id) is a ($o.spec.type) Service: a tenant's Service is a ClusterIP") }
			if ($o.spec?.externalIPs? | default [] | is-not-empty) { $why = ($why | append $"($id) names externalIPs") }
		}
		if ($o.kind? | default "") == "Cluster" {
			if ($node.name? | default "" | is-not-empty) and ($o.metadata?.name? | default "") != $"($node.name)-db" { $why = ($why | append $"($id) is not named ($node.name)-db: a tenant's database is the release's own") }
			let image = ($o.spec?.imageName? | default "")
			if not ($image | str starts-with $prefix) { $why = ($why | append $"($id) runs ($image), not an image under ($prefix)") } else if not ($image =~ '@sha256:[0-9a-f]{64}$') { $why = ($why | append $"($id) runs ($image), which is pinned by tag alone: a tenant's image carries its sha256 digest") }
			# a Service the operator makes for the database must stay inside the cluster: a LoadBalancer or NodePort one would publish it
			let outward = ($o.spec?.managed?.services?.additional? | default [] | where {|a| ($a.serviceTemplate?.spec?.type? | default "ClusterIP") != "ClusterIP" or ($a.serviceTemplate?.spec?.externalIPs? | default [] | is-not-empty) })
			if ($outward | is-not-empty) { $why = ($why | append $"($id) has a managed Service that is not a ClusterIP, or names externalIPs") }
		}
		let spec = (if ($o.kind? | default "") in [Deployment Job] { $o.spec?.template?.spec? } else { null })
		if $spec != null {
			# `serviceAccount` is the deprecated spelling of `serviceAccountName`, and either may carry the account
			for account in [($spec.serviceAccountName? | default "") ($spec.serviceAccount? | default "")] {
				if $account in $forbidden_accounts { $why = ($why | append $"($id) runs as the service account ($account)") }
				# the database operator names the cluster's account `<cluster>-db` and binds it to what the database needs, which a tenant's workload never is
				if ($account | str ends-with "-db") or ($account != "" and $account in $clusters) { $why = ($why | append $"($id) runs as the service account ($account), which a database's cluster owns") }
			}
			# …nor a pod the operator would take for one of the cluster's (it selects its pods, and its policies admit them, by the labels it keeps
			# under its own prefix)
			if ($o.spec?.template?.metadata?.labels? | default {} | columns | any {|k| $k | str starts-with "cnpg.io/" }) { $why = ($why | append $"($id) carries a label under cnpg.io/, which marks a database's own pods") }
			# no runtime class (a sandbox or a host runtime of the node's) and no priority class (a tenant must not pre-empt the node's own pods)
			if ($spec.runtimeClassName? | default "" | is-not-empty) { $why = ($why | append $"($id) sets runtimeClassName ($spec.runtimeClassName)") }
			if ($spec.priorityClassName? | default "" | is-not-empty) { $why = ($why | append $"($id) sets priorityClassName ($spec.priorityClassName)") }
			if ($spec.hostUsers? | default true) == false { $why = ($why | append $"($id) sets hostUsers: false") }
			for key in [hostNetwork hostPID hostIPC] { if ($spec | get -o $key | default false) == true { $why = ($why | append $"($id) sets ($key)") } }
			for v in ($spec.volumes? | default []) {
				let kinds = ($v | columns | where {|c| $c != "name" })
				let other = ($kinds | where {|k| $k not-in $volume_types })
				if ($other | is-not-empty) { $why = ($why | append $"($id) mounts the volume ($v.name? | default '?') of type ($other | str join ', '), which a tenant's pod may not") }
			}
			if ($spec.securityContext?.seccompProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) runs with an Unconfined seccomp profile") }
			if ($spec.securityContext?.appArmorProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) runs with an Unconfined AppArmor profile") }
			let notes = ($o.spec?.template?.metadata?.annotations? | default {})
			# Dapr's sidecar is the platform's: its image, resources and ports are not a tenant's to choose
			let sidecar = ($notes | columns | where {|k| $k | str starts-with "dapr.io/sidecar-" })
			if ($sidecar | is-not-empty) { $why = ($why | append $"($id) sets the Dapr sidecar annotation\(s\) ($sidecar | str join ', ')") }
			if ($notes | transpose k v | any {|a| ($a.k | str starts-with "container.apparmor.security.beta.kubernetes.io/") and (($a.v | into string | str lowercase) == "unconfined") }) { $why = ($why | append $"($id) runs with an unconfined AppArmor profile") }
			let containers = (($spec.containers? | default []) | append ($spec.initContainers? | default []) | append ($spec.ephemeralContainers? | default []))
			for c in $containers {
				let image = ($c.image? | default "")
				if not ($image | str starts-with $prefix) { $why = ($why | append $"($id) container ($c.name? | default '?') runs ($image), not an image under ($prefix)") } else if not ($image =~ '@sha256:[0-9a-f]{64}$') { $why = ($why | append $"($id) container ($c.name? | default '?') runs ($image), which is pinned by tag alone: a tenant's image carries its sha256 digest") }
				if ($c.securityContext?.procMount? | default "Default") != "Default" { $why = ($why | append $"($id) container ($c.name? | default '?') sets procMount ($c.securityContext.procMount)") }
				if ($c.securityContext?.privileged? | default false) == true { $why = ($why | append $"($id) container ($c.name? | default '?') is privileged") }
				# Absent is not false: the API server lets a container escalate unless it says it may not. `harden-objects` says so before this runs.
				let escalation = ($c.securityContext?.allowPrivilegeEscalation? | default null)
				if $escalation == true { $why = ($why | append $"($id) container ($c.name? | default '?') allows privilege escalation") } else if $escalation != false { $why = ($why | append $"($id) container ($c.name? | default '?') does not set allowPrivilegeEscalation: false") }
				if ($c.securityContext?.capabilities?.add? | default [] | is-not-empty) { $why = ($why | append $"($id) container ($c.name? | default '?') adds capabilities") }
				if ($c.ports? | default [] | any {|p| ($p | get -o hostPort | default null) != null }) { $why = ($why | append $"($id) container ($c.name? | default '?') sets a hostPort") }
				if ($c.securityContext?.seccompProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) container ($c.name? | default '?') runs with an Unconfined seccomp profile") }
				if ($c.securityContext?.appArmorProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) container ($c.name? | default '?') runs with an Unconfined AppArmor profile") }
			}
		}
		$why
	} | flatten)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's render is refused: ($problems | str join '; ')"} }
}
# `body` run as the push identity: kubectl with the kubeconfig file given, or, with none, with the pod's own account (the pod's
# service account, so KUBECONFIG is hidden and the environment must say this is a pod).
export def with-push [push_kubeconfig: string, body: closure]: nothing -> any {
	if ($push_kubeconfig | is-not-empty) {
		if not ($push_kubeconfig | path exists) { error make {msg: $"--push-kubeconfig names ($push_kubeconfig), which does not exist"} }
		with-env {KUBECONFIG: $push_kubeconfig} { do $body }
	} else {
		if ($env.KUBERNETES_SERVICE_HOST? | is-empty) { error make {msg: "a tenant's push runs as the builder pod's own account when --push-kubeconfig is empty: this is not a pod (KUBERNETES_SERVICE_HOST is unset)"} }
		do { hide-env -i KUBECONFIG; do $body }
	}
}

# The app's release.cue must have bound the tags the engine passes into Node.tenant: the namespace and host it released into are the
# ones the operator named, never ones the game's own file chose.
export def check-binding [node: record, tenant: string, host: string] {
	let bound = ($node.tenant? | default {})
	if ($bound.namespace? | default "") != $tenant or ($bound.host? | default "") != $host or $node.namespace != $tenant or $node.host != $host {
		error make {msg: $"the app's release.cue does not bind the tags tenant and tenantHost into Node.tenant \(Node.tenant.namespace is ($bound.namespace? | default 'unset'), --tenant is ($tenant); Node.tenant.host is ($bound.host? | default 'unset'), --host is ($host)\)"}
	}
	# The release registers OIDC clients at the origin and skips the door's probes for a preview with no host: both are the operator's host alone.
	if ($node.preview? | default "" | is-not-empty) { error make {msg: "a tenant's release is never a preview: Node.preview must be empty"} }
	if ($node.origin? | default "") != $"https://($host)" { error make {msg: $"a tenant's origin is https://($host), the operator's host, not the Node's ($node.origin? | default 'unset')"} }
}

# What a tenant's release never does, said before anything is built or written: it decrypts no SOPS file with the cluster's key (the
# operator's), and it runs no hook (the release.cue's own commands would run with its publisher's and its pusher's credentials).
export def tenant-refusals [app_dir: string, node: record] {
	let sops = ($node.secrets? | default "secrets.metal.enc.yaml")
	if ($app_dir | path join $sops | path exists) {
		error make {msg: $"a tenant's release decrypts no secrets with the cluster's key: ($sops) is the operator's"}
	}
	if ($node.hooks.afterJobs | is-not-empty) {
		error make {msg: "a tenant's release runs no hooks: hooks.afterJobs would run the release.cue's commands with its publisher's and its pusher's credentials"}
	}
}

# `kubectl auth can-i`'s word: yes or no, never a failure of the question itself.
def --wrapped can-i [...args: string]: nothing -> bool {
	let r = (^kubectl auth can-i ...$args | complete)
	if $r.exit_code != 0 and ($r.stdout | str trim) != "no" { error make {msg: $"kubectl auth can-i ($args | str join ' '): ($r.stderr | str trim)"} }
	($r.stdout | str trim) == "yes"
}

# The namespace is the provisioner's and the KUBECONFIG its publisher's, though a publisher cannot read a namespace: the rights to release in
# it are asked, an operator's (it may create namespaces) is refused, and the namespace's own record (the ConfigMap pronto-release) must
# be absent or say this app, which only a tenant's release writes: one app per tenant namespace.
export def check-namespace [node: record] {
	let ns = $node.namespace
	if not (can-i create deployments.apps -n $ns) { error make {msg: $"this KUBECONFIG may not release into ($ns): a tenant's release runs as the namespace's publisher"} }
	if (can-i create namespaces) { error make {msg: "this KUBECONFIG may create namespaces, so it is an operator's: release without --tenant"} }
	let r = (^kubectl get configmap pronto-release -n $ns --ignore-not-found -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"reading the record of ($ns) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return }
	let app = ($r.stdout | from json | get -o data.app | default "")
	if ($app | is-empty) { error make {msg: $"namespace ($ns) holds an operator's release (pronto-release names no tenant app): not a tenant's to change"} }
	if $app != $node.name { error make {msg: $"namespace ($ns) records the release of ($app): one app per tenant namespace"} }
}

# What the push identity must be allowed, asked before anything is built, and only what the chosen path uses: the registry pod's port-forward
# and the registry's lease (a path that builds, the only one that asks at all) and, with `--door` (a live release: a check never checks the
# door), the Envoy Gateway's Service reads and, off the cluster, its data plane's port-forward.
export def check-push-rights [node: record, push_kubeconfig: string, --door] {
	# A live release run in the builder pod (no push kubeconfig) checks the door by dialling the gateway's Service from the pod, which the
	# pod's NetworkPolicy must admit: a builder says so with PRONTO_BUILDER_GATEWAY_EGRESS=1, set only where its policy reaches the gateway's
	# data plane. Without it the rollout would run and the door check time out after it, so it is refused before anything is built or written.
	if $door and ($push_kubeconfig | is-empty) and (($env.PRONTO_BUILDER_GATEWAY_EGRESS? | default "") != "1") {
		error make {msg: "this builder pod does not declare that its network policy reaches the Envoy Gateway (PRONTO_BUILDER_GATEWAY_EGRESS=1), so a live tenant release's door check could not run after the rollout: release from a builder whose policy does, or with --push-kubeconfig"}
	}
	with-push $push_kubeconfig {
		let registry = $node.build.registry.namespace
		# Off the cluster (a kubeconfig is given) the door check forwards to the gateway's pod; in the builder pod it dials the Service's
		# ClusterIP, so the pod's account needs no port-forward in the gateway's namespace.
		let forward = ($door and ($push_kubeconfig | is-not-empty))
		let push_role = "studio-builder-push"
		let gateway_role = "studio-builder-gateway"
		for ask in ([
			# the registry's pod is found by label and forwarded to
			{verb: "get pods", args: [get pods -n $registry], where: $registry, role: $push_role}
			{verb: "list pods", args: [list pods -n $registry], where: $registry, role: $push_role}
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n $registry], where: $registry, role: $push_role}
			{verb: "create leases.coordination.k8s.io", args: [create leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			# the lease is acquired (create), read (get), renewed (patch) and released (delete); listing and replacing leases are the collector's alone
			{verb: "get leases.coordination.k8s.io", args: [get leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			{verb: "patch leases.coordination.k8s.io", args: [patch leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			{verb: "delete leases.coordination.k8s.io", args: [delete leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
		] | append (if $door { [
			# the door check lists the gateway's Services by label, and reads each
			{verb: "get services", args: [get services -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "list services", args: [list services -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
		] } else { [] }) | append (if $forward { [
			# forwarding to a Service finds a pod behind it, then forwards to that pod
			{verb: "get pods", args: [get pods -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "list pods", args: [list pods -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
		] } else { [] })) {
			if not (can-i ...$ask.args) { error make {msg: $"the push identity may not ($ask.verb) in ($ask.where): it needs the Role ($ask.role) \(services/buildkit-tenants\)"} }
		}
	}
}

# Waits until the port-forward `pid` answers on `port`; fails with kubectl's message when it died or never did.
def wait-forward [pid: int, port: int, log: string, --seconds: int = 30] {
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let up = ((^kill -0 $pid | complete).exit_code == 0)
		if $up and (tunnel answers $port) { return }
		if not $up { error make {msg: $"the registry's kubectl port-forward closed: (open --raw $log | str trim)"} }
		if (date now) > $deadline { error make {msg: $"the registry's kubectl port-forward did not answer on 127.0.0.1:($port) in ($seconds) s: (open --raw $log | str trim)"} }
		sleep 250ms
	}
}

# `body` run with a port-forward, as the push identity, to the node's registry pod: `{|port| ... }`, the local port. The forward goes on
# every exit path.
export def with-registry-forward [push_kubeconfig: string, body: closure]: nothing -> any {
	with-push $push_kubeconfig {
		let pods = (^kubectl get pods -n pronto-registry -l app=registry -o json | complete)
		if $pods.exit_code != 0 { error make {msg: $"reading the node's registry pod failed: ($pods.stderr | str trim)"} }
		let running = ($pods.stdout | from json | get items | where {|p| ($p.status?.phase? | default "Running") == "Running" })
		if ($running | is-empty) { error make {msg: "the node's registry has no pod to push to"} }
		let pod = {stdout: ($running | first | get metadata.name), stderr: "", exit_code: 0}
		let local = (tunnel free-ports 1 | first)
		let log = (mktemp -t registry-forward.XXXXXX | str trim)
		let started = (^sh -c $"kubectl port-forward -n pronto-registry 'pod/($pod.stdout | str trim)' '($local):5000' >'($log)' 2>&1 & echo $!" | complete)
		if $started.exit_code != 0 { rm -f $log; error make {msg: $"kubectl port-forward did not start: ($started.stderr | str trim)"} }
		let pid = ($started.stdout | str trim | into int)
		let out = (try {
			wait-forward $pid $local $log
			{ok: (do $body $local)}
		} catch {|e|
			^kill $pid | complete | ignore
			rm -f $log
			error make {msg: $e.msg}
		})
		^kill $pid | complete | ignore
		rm -f $log
		$out.ok
	}
}
