# registry.nu: the node registry's garbage collection, the last step of a release (`prune`). Each release's
# push leaves the one before it untagged, so without it the node's disk only grows. Ported from pronto's
# fork (k8s/release.nu, prune-node-registry), the one mechanism the node's registry has had; it is
# reached through the release's tunnel, and a failure of it is a warning, never a failed release (the
# release is live by then).

use build.nu [stamp]

const lock_name = "registry-gc-lock"
const lease_label = "pronto.dev/registry-lease"
# How long a lease or the lock holds before it is taken for a dead release's: far past any release.
const hold_seconds = 3600

const accept = "application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"

# The registry's images the cluster still names, by digest: every image of a pod, a ReplicaSet a rollback
# returns to, a workload's template or a database's imageName, read out of their JSON. `host` is the
# registry as the node names it (build.registry.host).
export def in-use [objects: string, host: string]: nothing -> list<record<repo: string, digest: string>> {
	let escaped = ($host | str replace -a '.' '\.')
	$objects
	| parse --regex ($escaped + '/(?<repo>[a-z0-9._/-]+)(?::[A-Za-z0-9._-]+)?@(?<digest>sha256:[0-9a-f]{64})')
	| select repo digest
	| uniq
}

# The tag that holds a digest the cluster names through a prune.
export def keep-tag [digest: string]: nothing -> string {
	$"keep-($digest | str replace 'sha256:' '' | str substring 0..15)"
}

# `digest` in `repo` tagged `tag` too: its manifest put again under the tag.
def tag-digest [registry: string, repo: string, digest: string, tag: string] {
	let got = (http get --raw --full --headers {Accept: $accept} $"http://($registry)/v2/($repo)/manifests/($digest)")
	let type = ($got.headers.response | where name == "content-type" | get value.0)
	http put --content-type $type $"http://($registry)/v2/($repo)/manifests/($tag)" $got.body | ignore
}

# kubectl's stdout, failing with its own message.
def --wrapped kubectl-out [...args: string]: nothing -> string {
	let r = (^kubectl ...$args | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl ($args | first 3 | str join ' '): ($r.stderr | str trim)"} }
	$r.stdout
}

# The registry, cut to what is tagged: every digest the cluster names is tagged keep-<digest> first, a
# keep- tag whose digest nothing names any more is deleted, and the registry's garbage collector then
# deletes every untagged manifest and every blob none of the rest reference. `registry` is the
# registry as this release reaches it (127.0.0.1:<fwd.registry>). Garbage collection deletes the blobs
# of a push still in flight, so it is skipped while an upload is open: the next release collects.
export def prune [registry: string, build: record, own: string = ""] {
	let ns = $build.registry.namespace
	let target = $"deploy/($build.registry.deployment)"
	let kinds = ["pods" "replicasets" "deployments" "statefulsets" "daemonsets" "jobs" "cronjobs" "clusters.postgresql.cnpg.io"]
	# A kind whose CRD is not on the node names no image; any other failure of a read stops the prune, since
	# an image its objects name would look unused and be collected.
	let objects = ($kinds | each {|k|
		let r = (^kubectl get $k -A -o json | complete)
		if $r.exit_code == 0 { $r.stdout } else if ($r.stderr =~ "the server doesn't have a resource type") { "" } else {
			error make {msg: $"kubectl get ($k) -A failed, so the prune stops before it deletes anything: ($r.stderr | str trim)"}
		}
	} | str join "\n")
	let used = (in-use $objects $build.registry.host)
	for it in $used {
		# 200: protect it. 404: the registry does not hold it, so there is nothing to protect. Any other answer (a 503) means
		# a live image was not confirmed protected, and nothing is deleted.
		let there = (http head --full --allow-errors --headers {Accept: $accept} $"http://($registry)/v2/($it.repo)/manifests/($it.digest)" | get status)
		if $there == 200 { tag-digest $registry $it.repo $it.digest (keep-tag $it.digest) } else if $there != 404 {
			error make {msg: $"the registry answered ($there) for the live image ($it.repo)@($it.digest), so the prune stops before it deletes anything"}
		}
	}
	let catalog = (http get $"http://($registry)/v2/_catalog?n=1000" | get repositories)
	for repo in $catalog {
		let tags = (http get $"http://($registry)/v2/($repo)/tags/list" | get tags? | default [])
		let kept = ($used | where repo == $repo | each {|it| keep-tag $it.digest })
		for t in ($tags | where {|t| ($t starts-with "keep-") and not ($t in $kept) }) {
			http delete $"http://($registry)/v2/($repo)/manifests/($t)" | ignore
		}
	}
	collect $build $own
}

# The blob descriptor cache the registry serves with (storage.cache.blobdescriptor): the deployment's env
# override, else the config the image runs on. `none` when it is disabled. Reads only.
export def blob-cache [build: record]: nothing -> string {
	let ns = $build.registry.namespace
	let target = $"deploy/($build.registry.deployment)"
	let vars = (kubectl-out get deployment $build.registry.deployment -n $ns -o json | from json | get spec.template.spec.containers.0.env? | default [])
	let set = ($vars | where name == "REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR" | get -o value.0)
	if ($set | is-not-empty) { return $set }
	let config = (kubectl-out exec -n $ns $target -- cat /etc/distribution/config.yml)
	$config | parse --regex '(?m)^\s*blobdescriptor:\s*(?<v>\S+)' | get -o v.0 | default "none"
}

# Garbage collection of the registry, then its restart when it caches blob descriptors: the cache keeps
# answering "this layer exists" for a blob the collector deleted, and a push that reuses it would then
# point at nothing. It runs under the collector's lock and only while no other release holds a lease (a
# release's lease spans its push), so a collection never meets a release's layers uploaded and not yet
# published; a push outside the leases (an open upload) is still checked for.
export def collect [build: record, own: string = ""] {
	let ns = $build.registry.namespace
	let target = $"deploy/($build.registry.deployment)"
	# Only one collector at a time, and only while no other release holds a lease (one is held from before a release's push
	# until it ends): the collector takes the lock first and then looks for leases, a release takes its lease first and then
	# looks for the lock, so one of them always sees the other.
	if not (lock-take $build) {
		print $"node: (stamp) another release is collecting the node's registry: its garbage collection waits for the next release"
		return
	}
	try {
		let others = (leases $build | where {|l| $l.name != $own })
		if ($others | is-not-empty) {
			print $"node: (stamp) the node's registry has releases in flight \(($others | get name | str join ', ')\): its garbage collection waits for the next release"
			return
		}
		collect-locked $build $ns $target
	} finally {
		do { ^kubectl delete configmap $lock_name -n $ns --ignore-not-found | complete } | ignore
	}
}

def epoch []: nothing -> int { (date now | format date "%s" | into int) }

# The configmaps of the registry's namespace that are releases' leases, with their age: {name, age}.
def leases [build: record]: nothing -> list<record<name: string, age: int>> {
	let ns = $build.registry.namespace
	let r = (kubectl-out get configmap -n $ns -l $lease_label -o json | from json)
	$r.items | each {|c| {name: $c.metadata.name, age: ((epoch) - ($c.metadata.annotations?.at? | default "0" | into int))} } | where age < $hold_seconds
}

# The collector's lock: true when this release took it; false when another's fresh one is held (a stale one is taken over).
def lock-take [build: record]: nothing -> bool {
	let ns = $build.registry.namespace
	let make = {|| ^kubectl create configmap $lock_name -n $ns $"--from-literal=at=(epoch)" | complete }
	let r = (do $make)
	if $r.exit_code == 0 { return true }
	if not ($r.stderr =~ "AlreadyExists") { error make {msg: $"taking the registry's collection lock failed: ($r.stderr | str trim)"} }
	let held = (kubectl-out get configmap $lock_name -n $ns --ignore-not-found -o json)
	let at = if ($held | str trim | is-empty) { 0 } else { $held | from json | get -o data.at | default "0" | into int }
	if ((epoch) - $at) < $hold_seconds { return false }
	kubectl-out delete configmap $lock_name -n $ns --ignore-not-found | ignore
	let again = (do $make)
	$again.exit_code == 0
}

# A release's lease on the registry, taken before it pushes: its own configmap, then a look for the collector's lock,
# waited out (a collection is minutes) and else a failure, since a push under a collection could lose its layers.
export def lease-acquire [build: record, app: string, namespace: string, --wait: int = 180]: nothing -> string {
	let ns = $build.registry.namespace
	let name = $"registry-lease-($namespace)-(random chars --length 6 | str lowercase)"
	kubectl-out create configmap $name -n $ns $"--from-literal=at=(epoch)" $"--from-literal=app=($app)" | ignore
	kubectl-out label configmap $name -n $ns $"($lease_label)=true" | ignore
	mut waited = 0
	loop {
		let held = (kubectl-out get configmap $lock_name -n $ns --ignore-not-found -o json)
		let at = if ($held | str trim | is-empty) { null } else { $held | from json | get -o data.at | default "0" | into int }
		if $at == null or ((epoch) - $at) >= $hold_seconds { break }
		if $waited >= $wait {
			lease-release $build $name
			error make {msg: $"the node's registry is being collected and still was after ($wait) s: retry the release"}
		}
		sleep 5sec
		$waited += 5
	}
	$name
}

export def lease-release [build: record, name: string] {
	kubectl-out delete configmap $name -n $build.registry.namespace --ignore-not-found | ignore
}

# The collection itself, under the lock and with no other lease.
def collect-locked [build: record, ns: string, target: string] {
	let uploads = (kubectl-out exec -n $ns $target -- sh -c "find /var/lib/registry/docker/registry/v2/repositories -path '*/_uploads/*' -mindepth 1 -maxdepth 4 | head -1" | str trim)
	if ($uploads | is-not-empty) {
		print $"node: (stamp) the node's registry has an upload open \(a push outside the leases, or a dead one\): its garbage collection waits for the next release"
		return
	}
	let before = (kubectl-out exec -n $ns $target -- du -sh /var/lib/registry | split row "\t" | first)
	let gc = (do { ^kubectl exec -n $ns $target -- registry garbage-collect --delete-untagged /etc/distribution/config.yml } | complete)
	if $gc.exit_code != 0 { error make {msg: $"the node's registry garbage collection failed: ($gc.stderr | lines | last 5 | str join (char nl))"} }
	let after = (kubectl-out exec -n $ns $target -- du -sh /var/lib/registry | split row "\t" | first)
	print $"node: (stamp) the node's registry: ($before) before its garbage collection, ($after) after"
	let cache = (blob-cache $build)
	if $cache != "none" and $cache != "disabled" {
		kubectl-out rollout restart -n $ns $target | ignore
		kubectl-out rollout status -n $ns $target --timeout=120s | ignore
		print $"node: (stamp) the node's registry restarted, so its ($cache) blob cache holds no collected layer"
	}
}
