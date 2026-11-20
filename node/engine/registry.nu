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
export def prune [registry: string, build: record, own: string = ""]: nothing -> string {
	# Everything below happens under the collector's lock, and with no other release in flight: the cluster is read after
	# the lock is held, so the protection of a rollback image is computed from what the cluster names now, and a release
	# that protects a newer digest cannot interleave with this one's deletion of keep tags.
	with-lock $build {
		let others = (leases $build | where {|l| $l.name != $own })
		if ($others | is-not-empty) {
			print $"node: (stamp) the node's registry has releases in flight \(($others | get name | str join ', ')\): its maintenance waits for the next release"
			"releases are in flight"
		} else {
			protect-live-images $registry $build
			collect-locked $build $build.registry.namespace $"deploy/($build.registry.deployment)"
		}
	}
}

# The cluster's images tagged keep-<digest>, and the keep tags of digests nothing names any more deleted. Under the lock.
def protect-live-images [registry: string, build: record] {
	let kinds = ["pods" "replicasets" "deployments" "statefulsets" "daemonsets" "jobs" "cronjobs" "clusters.postgresql.cnpg.io"]
	# A kind whose CRD is not on the node names no image; any other failure of a read stops the prune, since
	# an image its objects name would look unused and be collected.
	# (a `for`, not `each`: nushell reports an error raised inside an `each` closure as "Eval block failed" once a `try` catches it)
	mut parts = []
	for k in $kinds {
		let r = (^kubectl get $k -A -o json | complete)
		if $r.exit_code == 0 { $parts = ($parts | append $r.stdout) } else if not ($r.stderr =~ "the server doesn't have a resource type") {
			error make {msg: $"kubectl get ($k) -A failed, so the prune stops before it deletes anything: ($r.stderr | str trim)"}
		}
	}
	let objects = ($parts | str join "\n")
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
export def collect [build: record, own: string = ""]: nothing -> string {
	let ns = $build.registry.namespace
	let target = $"deploy/($build.registry.deployment)"
	with-lock $build {
		let others = (leases $build | where {|l| $l.name != $own })
		if ($others | is-not-empty) {
			print $"node: (stamp) the node's registry has releases in flight \(($others | get name | str join ', ')\): its garbage collection waits for the next release"
			"releases are in flight"
		} else {
			collect-locked $build $ns $target
		}
	}
}

# `body` run under the collector's lock: only one collector at a time, and (the body checks) only while no other release
# holds a lease: the collector takes the lock first and then looks for leases, a release takes its lease first and then
# looks for the lock, so one of them always sees the other. Answers the body's result, or "another release is collecting"
# when the lock is held. A failure of the lock's release is never hidden: it joins the body's error, or, when the body
# succeeded, fails the call saying the work was done.
def with-lock [build: record, body: closure]: nothing -> string {
	let holder = (lock-take $build)
	if ($holder | is-empty) {
		print $"node: (stamp) another release is collecting the node's registry: its maintenance waits for the next release"
		return "another release is collecting"
	}
	let outcome = (try { {ok: (do $body)} } catch {|e| {err: $e.msg} })
	let released = (try { lock-release $build $holder; null } catch {|e| $e.msg })
	if ($outcome | get -o err) != null {
		let why = ($outcome | get err)
		let msg = if $released != null { $"($why); the lock was not released either: ($released)" } else { $why }
		error make {msg: $msg}
	}
	if $released != null { error make {msg: $"the maintenance ran \(($outcome.ok | default 'done')\), but the lock was not released: ($released)"} }
	$outcome.ok
}

# Leases and the lock are coordination.k8s.io Leases of the registry's namespace: the holder's name in
# `spec.holderIdentity`, its last renewal in `spec.renewTime` (written by the engine's clock; every engine runs on the same
# Mac, so one clock), which is what a lease's or the lock's age is read from, and the API server's `resourceVersion`, which a
# takeover of a stale lock is made against.

def micro-now []: nothing -> string { date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S%.6fZ" }

def lease-object [name: string, ns: string, holder: string, labelled: bool]: nothing -> record {
	{
		apiVersion: "coordination.k8s.io/v1", kind: "Lease"
		metadata: ({name: $name, namespace: $ns} | merge (if $labelled { {labels: {($lease_label): "true"}} } else { {} }))
		spec: {holderIdentity: $holder, leaseDurationSeconds: $hold_seconds, renewTime: (micro-now)}
	}
}

# Seconds since a Lease was last renewed (its creation when it never was).
def lease-age [item: record]: nothing -> int {
	let at = ($item | get -o spec.renewTime | default ($item | get -o metadata.creationTimestamp | default ""))
	if ($at | is-empty) { return $hold_seconds }
	((date now) - ($at | into datetime)) | into int | $in / 1_000_000_000 | into int
}

# The registry's namespace's leases that are releases', with their age: {name, age}, the stale ones left out.
def leases [build: record]: nothing -> list<record<name: string, age: int>> {
	let ns = $build.registry.namespace
	let r = (kubectl-out get leases -n $ns -l $lease_label -o json | from json)
	$r.items | each {|l| {name: $l.metadata.name, age: (lease-age $l)} } | where age < $hold_seconds
}

# A Lease by name, or null when it does not exist (a failed read is an error).
def lease-get [ns: string, name: string]: nothing -> any {
	let r = (kubectl-out get lease $name -n $ns --ignore-not-found -o json)
	if ($r | str trim | is-empty) { null } else { $r | from json }
}

def kubectl-stdin [verb: string, object: record]: nothing -> record {
	$object | to json | ^kubectl $verb -f - | complete
}

# The collector's lock, as its holder's identity (a new one each call): "" when another's fresh one is held. A stale one is
# replaced against the resourceVersion read, so a lock renewed or taken over in between wins and this call gets "".
def lock-take [build: record]: nothing -> any {
	let ns = $build.registry.namespace
	let holder = $"collector-(random chars --length 8 | str lowercase)"
	let made = (kubectl-stdin create (lease-object $lock_name $ns $holder false))
	if $made.exit_code == 0 { return $holder }
	if not ($made.stderr =~ "AlreadyExists") { error make {msg: $"taking the registry's collection lock failed: ($made.stderr | str trim)"} }
	let held = (lease-get $ns $lock_name)
	if $held == null { return (lock-take $build) }
	if (lease-age $held) < $hold_seconds { return "" }
	let mine = (lease-object $lock_name $ns $holder false | upsert metadata.resourceVersion $held.metadata.resourceVersion)
	let swapped = (kubectl-stdin replace $mine)
	if $swapped.exit_code == 0 { return $holder }
	if $swapped.stderr =~ "Conflict" { return "" }
	error make {msg: $"taking over the registry's stale collection lock failed: ($swapped.stderr | str trim)"}
}

# The lock released, only when it is still this collector's, and deleted against the uid and resourceVersion just read: a
# lock taken over between the read and the delete is another collector's now, and the delete is refused (409), not done.
# A failed read, and any other failed delete, are errors: a lock left behind blocks the next collection for an hour.
def lock-release [build: record, holder: string] {
	let ns = $build.registry.namespace
	let held = (lease-get $ns $lock_name)
	if $held == null or ($held | get -o spec.holderIdentity) != $holder { return }
	let options = {kind: "DeleteOptions", apiVersion: "v1", preconditions: {uid: $held.metadata.uid, resourceVersion: $held.metadata.resourceVersion}}
	let path = $"/apis/coordination.k8s.io/v1/namespaces/($ns)/leases/($lock_name)"
	let r = ($options | to json | ^kubectl delete --raw $path -f - | complete)
	if $r.exit_code != 0 and ($r.stderr =~ "Conflict") { print -e $"node: (stamp) warning: the collection lock changed hands before this collector deleted it: left to its new holder" }
	if $r.exit_code != 0 and not ($r.stderr =~ "Conflict|NotFound") { error make {msg: $"deleting the registry's collection lock failed: ($r.stderr | str trim)"} }
}

# A release's lease on the registry, taken before it pushes: its own Lease (labelled in the one call that makes it), then a
# look for the collector's lock, waited out (a collection is minutes) and else a failure, since a push under a collection
# could lose its layers.
export def lease-acquire [build: record, app: string, namespace: string, --wait: int = 180]: nothing -> string {
	let ns = $build.registry.namespace
	let name = $"registry-lease-($namespace)-(random chars --length 6 | str lowercase)"
	let made = (kubectl-stdin create (lease-object $name $ns $name true))
	if $made.exit_code != 0 { error make {msg: $"taking the registry lease ($name) failed: ($made.stderr | str trim)"} }
	mut waited = 0
	loop {
		let lock = (try { lease-get $ns $lock_name } catch {|e| lease-release $build $name; error make {msg: $e.msg} })
		if $lock == null or (lease-age $lock) >= $hold_seconds { break }
		if $waited >= $wait {
			lease-release $build $name
			error make {msg: $"the node's registry is being collected and still was after ($wait) s: retry the release"}
		}
		sleep 5sec
		$waited += 5
	}
	$name
}

# The lease renewed: after the push and after each long phase, so a release that outlives the hour is not taken for dead.
export def lease-renew [build: record, name: string] {
	kubectl-out patch lease $name -n $build.registry.namespace --type merge -p ({spec: {renewTime: (micro-now)}} | to json --raw) | ignore
}

# The release's own lease deleted, by name.
export def lease-release [build: record, name: string] {
	kubectl-out delete lease $name -n $build.registry.namespace --ignore-not-found | ignore
}

# The collection itself, under the lock and with no other lease.
def collect-locked [build: record, ns: string, target: string]: nothing -> string {
	# `find` itself is checked (no pipe to hide its exit): a scan that fails stops the collection, it does not read as no upload.
	# A registry that has never been pushed to has no repositories directory: nothing to collect.
	let repos = "/var/lib/registry/docker/registry/v2/repositories"
	let has_repos = (^kubectl exec -n $ns $target -- find $repos -maxdepth 0 -print -quit | complete)
	if $has_repos.exit_code != 0 {
		if ($has_repos.stderr =~ "No such file or directory") {
			print $"node: (stamp) the node's registry has no repositories yet: nothing to collect"
			return ""
		}
		error make {msg: $"looking for the registry's repositories failed: ($has_repos.stderr | str trim)"}
	}
	let uploads = (kubectl-out exec -n $ns $target -- find $repos -mindepth 1 -maxdepth 4 -path "*/_uploads/*" -print -quit | str trim)
	if ($uploads | is-not-empty) {
		let why = "an upload is open (a push outside the leases, or a dead one)"
		print $"node: (stamp) the node's registry: ($why): its garbage collection waits for the next release"
		return $why
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
	""
}
