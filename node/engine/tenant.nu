# tenant.nu: what a tenant's release (`release.nu --tenant <namespace> --host <host>`) needs beyond the operator's. A tenant's release has two
# actors: the namespace's publisher (the KUBECONFIG it is given: rights in the namespace alone, no tunnel, no operator) and the push
# identity (`--push-kubeconfig`, or the pod's own account), which alone may reach the node's registry pod and the Envoy Gateway
# data plane. The checks here are the ones the operator's release makes with cluster-wide reads, made with the rights a publisher has.
# It imports nothing of the release (release.nu imports it).

use tunnel.nu
use build.nu [stamp]

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
		for ask in [
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n $registry], where: $registry}
			{verb: "create leases.coordination.k8s.io", args: [create leases.coordination.k8s.io -n $registry], where: $registry}
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n envoy-gateway-system], where: "envoy-gateway-system"}
			{verb: "get services", args: [get services -n envoy-gateway-system], where: "envoy-gateway-system"}
		] {
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
