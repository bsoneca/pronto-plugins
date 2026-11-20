# rollback.nu: the way back of a release that fails after it began to change what runs. Before the
# release applies a Deployment it records each one's revision; on a failure at or after that, or a
# failed verify, `rollout undo` puts back only the Deployments the release changed. The database is
# not rolled back (migrations go forward), nor a seed that was restated.

# A Deployment's state: {revision, generation}, both 0 only where it is confirmed absent (a successful, empty answer), so a
# failed read (timeout, denied) is an error and never a state. The generation moves as soon as the API server accepts a
# new template; the revision annotation follows when the controller has made its ReplicaSet.
export def state [name: string, namespace: string]: nothing -> record<revision: int, generation: int> {
	let r = (^kubectl get deployment $name -n $namespace --ignore-not-found -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"reading deployment/($name) in ($namespace) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return {revision: 0, generation: 0} }
	let d = ($r.stdout | from json)
	{
		revision: ($d | get metadata.annotations."deployment.kubernetes.io/revision"? | default "0" | into int)
		generation: ($d | get metadata.generation? | default 0 | into int)
	}
}

export def revision [name: string, namespace: string]: nothing -> int { (state $name $namespace).revision }

# Each of the namespace's Deployments with its state now: {name, revision, generation}.
export def revisions [names: list<string>, namespace: string]: nothing -> table<name: string, revision: int, generation: int> {
	$names | each {|n| {name: $n} | merge (state $n $namespace) }
}

# The Deployments the release changed since `before`, and existed before (a new one has none to go back to): its revision
# moved, or its generation did (a template accepted whose rollout the controller has not begun):
# {changed: [{name, revision}], failed: [{name, why}]}, a Deployment whose state cannot be read being a failure, not
# unchanged and not changed.
export def changed [before: table, namespace: string]: nothing -> record {
	let rows = ($before | where revision > 0 | each {|b|
		try {
			let now = (state $b.name $namespace)
			let was_gen = ($b | get -o generation | default $now.generation)
			{name: $b.name, revision: $b.revision, moved: (($now.revision != $b.revision) or ($now.generation != $was_gen)), why: ""}
		} catch {|e| {name: $b.name, revision: $b.revision, moved: false, why: $e.msg} }
	})
	{changed: ($rows | where moved | select name revision), failed: ($rows | where why != "" | select name why)}
}

# Puts back each Deployment the release changed, every one even when one fails; answers
# {undone, failed}, the failures with their messages.
export def undo [before: table, namespace: string]: nothing -> record {
	let c = (changed $before $namespace)
	let results = ($c.changed | each {|d|
		print $"node: rolling back deployment/($d.name) in ($namespace) to revision ($d.revision)"
		let u = (^kubectl rollout undo $"deployment/($d.name)" -n $namespace $"--to-revision=($d.revision)" | complete)
		let s = if $u.exit_code == 0 { ^kubectl rollout status $"deployment/($d.name)" -n $namespace --timeout=180s | complete } else { $u }
		{name: $d.name, ok: ($s.exit_code == 0), why: ($s.stderr | str trim)}
	})
	# A Deployment this release created is not rolled back to anything: it is deleted, or the failed release's new template keeps
	# running. Only a confirmed absence before the apply (revision 0 and generation 0, which `state` answers for a successful,
	# empty read alone) counts as created: one that existed and awaited its first revision (generation above 0) is left.
	let created = ($before | where {|b| $b.revision == 0 and $b.generation == 0 } | each {|b|
		try {
			let now = (state $b.name $namespace)
			if $now.revision == 0 and $now.generation == 0 { {name: $b.name, ok: true, why: "", deleted: false} } else {
				print $"node: deleting deployment/($b.name) in ($namespace), which this release created"
				let d = (^kubectl delete deployment $b.name -n $namespace --ignore-not-found | complete)
				{name: $b.name, ok: ($d.exit_code == 0), why: ($d.stderr | str trim), deleted: true}
			}
		} catch {|e| {name: $b.name, ok: false, why: $e.msg, deleted: false} }
	})
	{
		undone: (($results | where ok | get name) | append ($created | where {|r| $r.ok and $r.deleted } | get name))
		failed: (($results | where not ok | select name why) | append ($created | where not ok | select name why) | append $c.failed)
	}
}
