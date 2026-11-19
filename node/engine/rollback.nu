# rollback.nu: the way back of a release that fails after it began to change what runs. Before the
# release applies a Deployment it records each one's revision; on a failure at or after that, or a
# failed verify, `rollout undo` puts back only the Deployments the release changed. The database is
# not rolled back (migrations go forward), nor a seed that was restated.

# A Deployment's revision, 0 where it does not exist yet.
export def revision [name: string, namespace: string]: nothing -> int {
	let r = (^kubectl get deployment $name -n $namespace -o json | complete)
	if $r.exit_code != 0 { return 0 }
	($r.stdout | from json | get metadata.annotations."deployment.kubernetes.io/revision"? | default "0" | into int)
}

# Each of the namespace's Deployments with its revision now: {name, revision}.
export def revisions [names: list<string>, namespace: string]: nothing -> table<name: string, revision: int> {
	$names | each {|n| {name: $n, revision: (revision $n $namespace)} }
}

# The Deployments whose revision moved since `before`, and existed before (a new one has none to go back to).
export def changed [before: table, namespace: string]: nothing -> list<string> {
	$before | where revision > 0 | where {|b| (revision $b.name $namespace) != $b.revision } | get name
}

# Puts back each Deployment the release changed; answers their names.
export def undo [before: table, namespace: string]: nothing -> list<string> {
	let names = (changed $before $namespace)
	for n in $names {
		print $"node: rolling back deployment/($n) in ($namespace)"
		^kubectl rollout undo $"deployment/($n)" -n $namespace
		^kubectl rollout status $"deployment/($n)" -n $namespace --timeout=180s
	}
	$names
}
