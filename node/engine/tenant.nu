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

# The app's copy of the schema (`node/schema/node.cue`, which its release.cue imports) must be the engine's own, byte for byte: a copy the
# game's author edited would load refusals of its own choosing.
export def check-engine-copy [app_dir: string] {
	let own = ($engine_dir | path join schema node.cue)
	let theirs = ($app_dir | path join node schema node.cue)
	if not ($theirs | path exists) { error make {msg: $"($theirs) is missing: a tenant's release imports the engine's schema from the app's node/schema"} }
	if (open --raw $own) != (open --raw $theirs) {
		error make {msg: $"the app's node/schema/node.cue is not the engine's own copy \(($own)\): a tenant's release trusts no schema its author could have edited"}
	}
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

# What the engine's CUE refuses, checked again in nushell over the objects the game's own release.cue rendered (its `nodeManifests` is
# the author's, so the schema's `violations` are only as good as the schema it loaded): every object is a kind the publisher writes, in
# the tenant's namespace; a Service is a ClusterIP with no externalIPs; a pod's service account is not the publisher's, its images are
# the tenant's own path of the registry, and it asks for no user namespace, host namespace, privilege, unmasked /proc or unconfined
# seccomp or AppArmor. Said before anything is applied or asked of the server.
export def check-objects [objects: list, node: record, kinds: list<string>] {
	let ns = $node.namespace
	let prefix = $"127.0.0.1:5000/($ns)/"
	let problems = ($objects | each {|o|
		let id = $"($o.kind? | default '?')/($o.metadata?.name? | default '?')"
		mut why = []
		if $"($o.apiVersion? | default '')/($o.kind? | default '')" not-in $kinds { $why = ($why | append $"($id) is not a kind a tenant's publisher writes") }
		if ($o.metadata?.namespace? | default "") != $ns { $why = ($why | append $"($id) is in namespace ($o.metadata?.namespace? | default 'none'), not ($ns)") }
		# A token a Secret of this type carries is a service account's (the publisher's included): never written by a tenant's release.
		if ($o.kind? | default "") == "Secret" and ($o.type? | default "") == "kubernetes.io/service-account-token" {
			$why = ($why | append $"($id) is a service account token")
		}
		if ($o.kind? | default "") == "Service" {
			if ($o.spec?.type? | default "ClusterIP") != "ClusterIP" { $why = ($why | append $"($id) is a ($o.spec.type) Service: a tenant's Service is a ClusterIP") }
			if ($o.spec?.externalIPs? | default [] | is-not-empty) { $why = ($why | append $"($id) names externalIPs") }
		}
		if ($o.kind? | default "") == "Cluster" {
			let image = ($o.spec?.imageName? | default "")
			if not ($image | str starts-with $prefix) { $why = ($why | append $"($id) runs ($image), not an image under ($prefix)") }
			# a Service the operator makes for the database must stay inside the cluster: a LoadBalancer or NodePort one would publish it
			let outward = ($o.spec?.managed?.services?.additional? | default [] | where {|a| ($a.serviceTemplate?.spec?.type? | default "ClusterIP") != "ClusterIP" or ($a.serviceTemplate?.spec?.externalIPs? | default [] | is-not-empty) })
			if ($outward | is-not-empty) { $why = ($why | append $"($id) has a managed Service that is not a ClusterIP, or names externalIPs") }
		}
		let spec = (if ($o.kind? | default "") in [Deployment Job] { $o.spec?.template?.spec? } else { null })
		if $spec != null {
			# `serviceAccount` is the deprecated spelling of `serviceAccountName`, and either may carry the account
			for account in [($spec.serviceAccountName? | default "") ($spec.serviceAccount? | default "")] {
				if $account in $forbidden_accounts { $why = ($why | append $"($id) runs as the service account ($account)") }
			}
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
				if not ($image | str starts-with $prefix) { $why = ($why | append $"($id) container ($c.name? | default '?') runs ($image), not an image under ($prefix)") }
				if ($c.securityContext?.procMount? | default "Default") != "Default" { $why = ($why | append $"($id) container ($c.name? | default '?') sets procMount ($c.securityContext.procMount)") }
				if ($c.securityContext?.privileged? | default false) == true { $why = ($why | append $"($id) container ($c.name? | default '?') is privileged") }
				if ($c.securityContext?.allowPrivilegeEscalation? | default false) == true { $why = ($why | append $"($id) container ($c.name? | default '?') allows privilege escalation") }
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

# What the push identity must be allowed, asked before anything is built: the registry pod's port-forward, the registry's lease, and the Envoy
# Gateway data plane's port-forward and reads (the door check).
export def check-push-rights [node: record, push_kubeconfig: string] {
	with-push $push_kubeconfig {
		let registry = $node.build.registry.namespace
		# Off the cluster (a kubeconfig is given) the door check forwards to the gateway's pod; in the builder pod it dials the Service's
		# ClusterIP, so the pod's account needs no port-forward in the gateway's namespace.
		let forward = ($push_kubeconfig | is-not-empty)
		for ask in ([
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n $registry], where: $registry}
			{verb: "create leases.coordination.k8s.io", args: [create leases.coordination.k8s.io -n $registry], where: $registry}
			{verb: "get services", args: [get services -n envoy-gateway-system], where: "envoy-gateway-system"}
		] | append (if $forward { [{verb: "create pods/portforward", args: [create pods --subresource=portforward -n envoy-gateway-system], where: "envoy-gateway-system"}] } else { [] })) {
			if not (can-i ...$ask.args) { error make {msg: $"the push identity may not ($ask.verb) in ($ask.where): it needs the Role studio-builder-push \(services/buildkit-tenants\)"} }
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
