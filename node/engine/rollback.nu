# rollback.nu: the way back of a release that fails after it began to change what runs. Before the
# release applies a Deployment it records each one's revision; on a failure at or after that, or a
# failed verify, `rollout undo` puts back only the Deployments the release changed. The database is
# not rolled back (migrations go forward), nor a seed that was restated.

# A Deployment's revision: 0 only where it is confirmed absent (a successful, empty answer), so a failed read
# (timeout, denied) is an error and never a revision.
export def revision [name: string, namespace: string]: nothing -> int {
	let r = (^kubectl get deployment $name -n $namespace --ignore-not-found -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"reading deployment/($name) in ($namespace) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return 0 }
	($r.stdout | from json | get metadata.annotations."deployment.kubernetes.io/revision"? | default "0" | into int)
}

# Each of the namespace's Deployments with its revision now: {name, revision}.
export def revisions [names: list<string>, namespace: string]: nothing -> table<name: string, revision: int> {
	$names | each {|n| {name: $n, revision: (revision $n $namespace)} }
}

# The Deployments whose revision moved since `before`, and existed before (a new one has none to go back to):
# {changed: [{name, revision}], failed: [{name, why}]}, a Deployment whose revision cannot be read being a failure,
# not unchanged and not changed.
export def changed [before: table, namespace: string]: nothing -> record {
	let rows = ($before | where revision > 0 | each {|b|
		try {
			let now = (revision $b.name $namespace)
			{name: $b.name, revision: $b.revision, moved: ($now != $b.revision), why: ""}
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
	{undone: ($results | where ok | get name), failed: ($results | where not ok | select name why | append $c.failed)}
}
