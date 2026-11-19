# registry.nu: the node registry's garbage collection, the last step of a release (`prune`). Each release's
# push leaves the one before it untagged, so without it the node's disk only grows. Ported from pronto's
# fork (k8s/release.nu, prune-node-registry), the one mechanism the node's registry has had; it is
# reached through the release's tunnel, and a failure of it is a warning, never a failed release (the
# release is live by then).

use build.nu [stamp]

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
export def prune [registry: string, build: record] {
	let ns = $build.registry.namespace
	let target = $"deploy/($build.registry.deployment)"
	let kinds = ["pods" "replicasets" "deployments" "statefulsets" "daemonsets" "jobs" "cronjobs" "clusters.postgresql.cnpg.io"]
	let objects = ($kinds | each {|k| let r = (do { ^kubectl get $k -A -o json } | complete); if $r.exit_code == 0 { $r.stdout } else { "" } } | str join "\n")
	let used = (in-use $objects $build.registry.host)
	for it in $used {
		let there = (http head --full --allow-errors --headers {Accept: $accept} $"http://($registry)/v2/($it.repo)/manifests/($it.digest)" | get status)
		if $there == 200 { tag-digest $registry $it.repo $it.digest (keep-tag $it.digest) }
	}
	let catalog = (http get $"http://($registry)/v2/_catalog?n=1000" | get repositories)
	for repo in $catalog {
		let tags = (http get $"http://($registry)/v2/($repo)/tags/list" | get tags? | default [])
		let kept = ($used | where repo == $repo | each {|it| keep-tag $it.digest })
		for t in ($tags | where {|t| ($t starts-with "keep-") and not ($t in $kept) }) {
			http delete $"http://($registry)/v2/($repo)/manifests/($t)" | ignore
		}
	}
	let uploads = (kubectl-out exec -n $ns $target -- sh -c "find /var/lib/registry/docker/registry/v2/repositories -path '*/_uploads/*' -mindepth 1 -maxdepth 4 | head -1" | str trim)
	if ($uploads | is-not-empty) {
		print $"node: (stamp) the node's registry has an upload open (another release is pushing): its garbage collection waits for the next release"
		return
	}
	let before = (kubectl-out exec -n $ns $target -- du -sh /var/lib/registry | split row "\t" | first)
	let gc = (do { ^kubectl exec -n $ns $target -- registry garbage-collect --delete-untagged /etc/distribution/config.yml } | complete)
	if $gc.exit_code != 0 { error make {msg: $"the node's registry garbage collection failed: ($gc.stderr | lines | last 5 | str join (char nl))"} }
	let after = (kubectl-out exec -n $ns $target -- du -sh /var/lib/registry | split row "\t" | first)
	print $"node: (stamp) the node's registry: ($before) before its garbage collection, ($after) after"
}
