#!/usr/bin/env nu
# The node's kubelet args (README.md, "The node host"), set from a node's #Host kubelet values:
#
#   nu node/host/kubelet.nu apply <host.json> [--check] [--node user@host]
#
# <host.json> is the node's #Host exported (`cue export -e host --out json`). It writes them to
# /etc/rancher/k3s/config.yaml.d/max-pods.yaml, the file max-pods already had (a second file with a plain
# kubelet-arg: would replace the list, not add to it), restarts k3s only when that changed, and checks what the
# running kubelet reports (configz). A k3s restart leaves running containers in place: its unit's KillMode is
# process, so only k3s itself is stopped. Run it with no release running. Safe to run again.
#
# Never leaves the only node with a file its kubelet did not take:
# - the file is written whole beside itself (not .yaml, so k3s does not read it), checked by its sha256, then renamed
#   over the live one: a full disk or a dropped ssh leaves the live file as it was;
# - a pending marker (holding "had" or "none": whether a previous file existed) and a backup of the previous file are
#   made before the rename and removed only once the kubelet is known good: a check passed, or the previous file is back,
#   k3s restarted and the kubelet answers. A run that finds the marker (an earlier run stopped before its check) is
#   the earlier run's to finish, and rolls back from the same backup;
# - only a configz that was read and differs restarts k3s: an unreadable one (the request failed, or answered nothing,
#   or not a kubelet config) is retried, then the run stops without restarting.
#
# Needs ssh to the node, whose sudo asks no password, and kubectl on the node (KUBECTL, expanded there, defaults to
# the operator's kubeconfig). Every call has a deadline; the ssh is never retried (a failed login gets the Mac banned by
# the node's CrowdSec). --check changes nothing and exits 1 on drift. --root puts every path under it (for the tests).

use host.nu [sh must]

const file = "/etc/rancher/k3s/config.yaml.d/max-pods.yaml"

# A bad value stops the only node's kubelet, so each arg must be one of these, whole.
const allowed = [
	'^max-pods=[1-9][0-9]{1,3}$'
	'^eviction-hard=memory\.available<[1-9][0-9]{1,3}Mi,nodefs\.available<[1-9][0-9]?%,nodefs\.inodesFree<[1-9][0-9]?%,imagefs\.available<[1-9][0-9]?%,imagefs\.inodesFree<[1-9][0-9]?%$'
	'^eviction-minimum-reclaim=nodefs\.available=[1-9][0-9]?Gi,imagefs\.available=[1-9][0-9]?Gi$'
	'^image-gc-high-threshold=[1-9][0-9]$'
	'^image-gc-low-threshold=[1-9][0-9]$'
	'^container-log-max-size=[1-9][0-9]{0,3}(Ki|Mi)$'
	'^container-log-max-files=[0-9]+$'
]

# The kubelet's args, one key=value each, from the #Host kubelet values.
export def kubelet-args [k: record]: nothing -> list<string> {
	let h = $k.evictionHard
	let r = $k.evictionMinimumReclaim
	[
		$"max-pods=($k.maxPods)"
		$"eviction-hard=memory.available<($h.memory),nodefs.available<($h.nodefs)%,nodefs.inodesFree<($h.nodefsInodes)%,imagefs.available<($h.imagefs)%,imagefs.inodesFree<($h.imagefsInodes)%"
		$"eviction-minimum-reclaim=nodefs.available=($r.nodefs),imagefs.available=($r.imagefs)"
		$"image-gc-high-threshold=($k.imageGC.high)"
		$"image-gc-low-threshold=($k.imageGC.low)"
		$"container-log-max-size=($k.containerLogMaxSize)"
		$"container-log-max-files=($k.containerLogMaxFiles)"
	]
}

# The file's text; errors on an arg that is not one of the allowed shapes.
export def kubelet-config [k: record]: nothing -> string {
	let args = (kubelet-args $k)
	for a in $args {
		if not ($allowed | any {|re| $a =~ $re }) { error make {msg: $"k3s-kubelet: not an arg this script sets: ($a)"} }
	}
	"# node/host/kubelet.nu, from the node's #Host kubelet values. The one file with kubelet-arg.\nkubelet-arg:\n" + ($args | each {|a| $"  - \"($a)\"\n"} | str join "")
}

# What the running kubelet reports when it was started with these (configz' kubeletconfig).
export def want-configz [k: record]: nothing -> record {
	let h = $k.evictionHard
	{
		maxPods: $k.maxPods
		evictionHard: {
			"memory.available": $h.memory
			"nodefs.available": $"($h.nodefs)%"
			"nodefs.inodesFree": $"($h.nodefsInodes)%"
			"imagefs.available": $"($h.imagefs)%"
			"imagefs.inodesFree": $"($h.imagefsInodes)%"
		}
		evictionMinimumReclaim: {"nodefs.available": $k.evictionMinimumReclaim.nodefs, "imagefs.available": $k.evictionMinimumReclaim.imagefs}
		imageGCHighThresholdPercent: $k.imageGC.high
		imageGCLowThresholdPercent: $k.imageGC.low
		containerLogMaxSize: $k.containerLogMaxSize
		containerLogMaxFiles: $k.containerLogMaxFiles
	}
}

# The kubelet's config as it reports it: {state: "match" | "differs" | "unreadable", said}. Unreadable is a failed
# request, an empty answer, or one that is not a kubelet config; none of them is a kubelet that took the args.
def read-configz [node: string, want: record]: nothing -> record {
	let kubectl = ($env.KUBECTL? | default 'KUBECONFIG=$HOME/.cache/contabo2.kubeconfig kubectl')
	let get = $"($kubectl) get --request-timeout=10s"
	let r = (sh $node $"($get) --raw /api/v1/nodes/$\(($get) node -o jsonpath='{.items[0].metadata.name}'\)/proxy/configz" --plain)
	if $r.exit_code != 0 { return {state: "unreadable", said: $"the request failed: ($r.stderr | str trim)"} }
	let parsed = (try { $r.stdout | from json } catch { null })
	let cfg = (if $parsed == null { null } else { $parsed | get -o kubeletconfig })
	if ($cfg | describe | str starts-with "record") == false { return {state: "unreadable", said: ($r.stdout | str trim | default "no answer")} }
	let got = ($want | columns | each {|c| {($c): ($cfg | get -o $c)}} | into record)
	{state: (if $got == $want { "match" } else { "differs" }), said: ($got | to json --raw)}
}

# Reads until it is not unreadable, up to $polls times.
def read-settled [node: string, want: record, polls: int, pause: duration]: nothing -> record {
	mut r = {state: "unreadable", said: "no answer"}
	for _ in 1..$polls {
		$r = (read-configz $node $want)
		if $r.state != "unreadable" { break }
		sleep $pause
	}
	$r
}

# Applies the kubelet's args, or with --check only says. Returns {code: 0 | 1}: 1 on drift (--check) or a kubelet that
# did not take them.
export def apply-kubelet [k: record, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec]: nothing -> record {
	let config = (kubelet-config $k)
	let want = (want-configz $k)
	let live = $root + $file
	let prev = $"($live).prev"
	let pending = $"($live).pending"
	let tmp = $"($live).new"
	let current = (must (sh $node $"if [ -e '($live)' ]; then cat '($live)'; fi") "reading the file")
	let marker = (must (sh $node $"if [ -e '($pending)' ]; then cat '($pending)'; fi") "reading the marker" | str trim)
	# A run that wrote the file and stopped before it was checked is finished, and rolled back if need be, by the next.
	mut changed = ($marker != "")
	let restart = {||
		let r = (sh $node "systemctl restart k3s")
		if $r.exit_code != 0 { print --stderr $"k3s-kubelet: the restart failed: ($r.stderr | str trim)" }
		print "k3s restarted"
		$r.exit_code == 0
	}

	if $current == $config {
		print $"($live) is as #Host says"
		if $check {
			if $marker != "" { print $"($pending): an earlier apply was not checked"; return {code: 1} }
			return {code: 0}
		}
		let r = (read-settled $node $want $polls $pause)
		if $r.state == "unreadable" {
			print --stderr $"k3s-kubelet: the kubelet's config could not be read: ($r.said); nothing restarted"
			return {code: 1}
		}
		if $r.state == "differs" {
			print "the kubelet does not run with it yet"
			do $restart | ignore
		}
	} else {
		print $"($live) differs"
		if $check { return {code: 1} }
		$changed = true
		let sum = ($config | hash sha256)
		# The marker and backup are made first, and only when no earlier run left them (its backup is the good one); a
		# run that fails before the rename removes what it made.
		let install = $"made=0; mkdir -p '($live | path dirname)' && { test -e '($pending)' || { rm -f '($prev)' && made=1 && k=none && { ! test -e '($live)' || { cp -p '($live)' '($prev)' && k=had; }; } && echo $k >'($pending)'; }; } && rm -f '($tmp)' && { tee '($tmp)' >/dev/null && [ \"$\(sha256sum '($tmp)' | cut -d' ' -f1\)\" = ($sum) ] && mv -f '($tmp)' '($live)'; } || { rm -f '($tmp)'; [ \"$made\" != 1 ] || rm -f '($pending)' '($prev)'; exit 1; }"
		let w = (sh $node $install $config)
		if $w.exit_code != 0 {
			print --stderr $"k3s-kubelet: writing the file failed, the live file is as it was: ($w.stderr | str trim)"
			return {code: 1}
		}
		do $restart | ignore
	}

	# Also when the file did not change: an earlier restart may have failed. The API answers again within a minute of a restart.
	mut last = {state: "unreadable", said: "no answer"}
	for _ in 1..$polls {
		$last = (read-configz $node $want)
		if $last.state == "match" {
			print "the kubelet runs with #Host's args"
			if $changed { sh $node $"rm -f '($pending)' '($prev)' '($tmp)'" | ignore }
			return {code: 0}
		}
		sleep $pause
	}
	print --stderr $"k3s-kubelet: the kubelet does not report #Host's args: ($last.said)"
	if not $changed { return {code: 1} }

	# The only node: a config this run (or an earlier unchecked one) wrote and the kubelet did not take is put back, by a
	# copy beside it and a rename, with the backup kept until the kubelet is known to answer.
	let back = (sh $node $"if [ \"$\(cat '($pending)'\)\" = had ]; then cp -p '($prev)' '($tmp)' && mv -f '($tmp)' '($live)'; else rm -f '($live)'; fi")
	if $back.exit_code != 0 {
		print --stderr $"k3s-kubelet: the previous file could not be put back: ($back.stderr | str trim); ($pending) is kept"
		return {code: 1}
	}
	let restarted = (do $restart)
	if $restarted {
		let r = (read-settled $node $want $polls $pause)
		if $r.state != "unreadable" {
			sh $node $"rm -f '($pending)' '($prev)' '($tmp)'" | ignore
			print --stderr "k3s-kubelet: put the previous file back and restarted k3s"
			return {code: 1}
		}
	}
	print --stderr $"k3s-kubelet: the previous file is back but k3s did not restart or the kubelet does not answer; ($pending) and ($prev) are kept: apply again once k3s is up"
	{code: 1}
}

def "main apply" [host: path, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec] {
	let k = (open $host | get -o kubelet)
	if $k == null { error make {msg: "k3s-kubelet: the host holds no kubelet values"} }
	let r = (apply-kubelet $k --check=$check --node $node --root $root --polls $polls --pause $pause)
	exit $r.code
}

def main [] {
	print "usage: kubelet.nu apply <host.json> [--check] [--node user@host]"
	exit 2
}
