#!/usr/bin/env nu
# The node's kubelet args (README.md, "The node host"), set from a node's #Host kubelet values:
#
#   KUBECTL='KUBECONFIG=... kubectl' nu node/host/kubelet.nu apply <host.json> [--check] [--node user@host]
#
# <host.json> is the node's #Host exported (`cue export -e host --out json`). It writes them to
# /etc/rancher/k3s/config.yaml.d/max-pods.yaml, the file max-pods already had (a second file with a plain
# kubelet-arg: would replace the list, not add to it), restarts k3s only when that changed, and checks what the
# running kubelet reports (configz). A k3s restart leaves running containers in place: its unit's KillMode is
# process, so only k3s itself is stopped. Run it with no release running. Safe to run again.
#
# Never leaves the only node with a file its kubelet did not take:
# - the file is written whole beside itself (not .yaml, so k3s does not read it), checked by its sha256, then renamed
#   over the live one: a full disk, a short write or a dropped ssh leaves the live file as it was;
# - a pending marker (holding "had" or "none": whether a previous file existed) and a backup of the previous file are
#   made before the rename and removed only once the kubelet is known good: a check passed, or the previous file is back,
#   k3s restarted and the kubelet answers. A run that finds the marker (an earlier run stopped before its check, or k3s
#   is down after a crash) is the earlier run's to finish: it waits for the kubelet and, if it does not take the file,
#   rolls back from the same backup. The marker's existence is what says so; a value other than had or none stops the
#   rollback with the marker kept;
# - only a configz that was read and differs restarts k3s: an unreadable one (the request failed, or answered nothing,
#   or not a kubelet config) is retried, then the run stops without restarting.
#
# It refuses, before writing, when another file under /etc/rancher/k3s/config.yaml{,.d} holds kubelet-arg (it would
# replace or be replaced by ours), when another apply holds the node's lock (a directory beside the file, taken over
# after 30 minutes), and when the node's disks are already past the new eviction line (a restart into eviction). The
# thresholds bound the damage when a disk fills; what prevents it is the cleanup of docker-gc.sh.
#
# Needs ssh to the node, whose sudo asks no password, and kubectl on the node: KUBECTL, expanded there by the login
# shell (it names the kubeconfig; this module has no default for a node's own). Every call has a deadline; the ssh is
# never retried (a failed login gets the Mac banned by the node's CrowdSec). --check changes nothing and exits 1 on
# drift. --root puts every path under it (for the tests).

use host.nu [sh must]

const dir = "/etc/rancher/k3s"
const file = "/etc/rancher/k3s/config.yaml.d/max-pods.yaml"
# The kubelet's own and the runtime's image filesystems, whose use the thresholds are about.
const nodefs_dir = "/var/lib/kubelet"
const imagefs_dir = "/var/lib/rancher/k3s/agent/containerd"

# A bad value stops the only node's kubelet, so each arg must be one of these, whole.
const allowed = [
	'^max-pods=[1-9][0-9]{2,3}$'
	'^eviction-hard=memory\.available<[1-9][0-9]{1,3}Mi,nodefs\.available<[1-9][0-9]?%,nodefs\.inodesFree<[1-9][0-9]?%,imagefs\.available<[1-9][0-9]?%,imagefs\.inodesFree<[1-9][0-9]?%$'
	'^eviction-minimum-reclaim=nodefs\.available=[1-9][0-9]?Gi,imagefs\.available=[1-9][0-9]?Gi$'
	'^image-gc-high-threshold=[1-9][0-9]$'
	'^image-gc-low-threshold=[1-9][0-9]$'
	'^container-log-max-size=[1-9][0-9]{0,3}(Ki|Mi)$'
	'^container-log-max-files=([2-9]|1[0-9]|20)$'
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
# request, an empty answer, or one that is not a kubelet config; none of them is a kubelet that took the args. It is
# the target node's own (by its hostname, which is k3s's node name unless it was set otherwise), never the first one listed.
def read-configz [node: string, want: record]: nothing -> record {
	let kubectl = $env.KUBECTL
	let r = (sh $node $"($kubectl) get --request-timeout=10s --raw /api/v1/nodes/$\(hostname\)/proxy/configz" --plain)
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

# The files, other than ours, under the k3s config that set kubelet-arg.
def other-kubelet-arg [node: string, root: string, live: string]: nothing -> list<string> {
	let base = $root + $dir
	let out = (must (sh $node $"grep -ls 'kubelet-arg' '($base)/config.yaml' '($base)/config.yaml.d/'*.yaml '($base)/config.yaml.d/'*.yml 2>/dev/null | grep -vxF '($live)'; true") "looking for other kubelet-arg")
	$out | lines | where {|l| $l != ""}
}

# Percent used of the filesystem a path is on.
def disk-used [node: string, path: string]: nothing -> int {
	let out = (must (sh $node $"df -P '($path)' 2>/dev/null | awk 'NR==2 {gsub\(\"%\", \"\", $5\); print $5}'") $"reading the use of ($path)" | str trim)
	if $out == "" { error make {msg: $"k3s-kubelet: cannot read the use of ($path)"} }
	$out | into int
}

# A restart into eviction is refused: the disks are already past the line the kubelet would evict at, and it would take
# pods on its first pass. Past the image GC line only warns (the kubelet collects images, which is what is wanted).
def preflight [node: string, k: record]: nothing -> bool {
	let h = $k.evictionHard
	let n = (disk-used $node $nodefs_dir)
	let i = (disk-used $node $imagefs_dir)
	let evict_n = (100 - $h.nodefs)
	let evict_i = (100 - $h.imagefs)
	if $n >= $evict_n or $i >= $evict_i {
		print --stderr $"k3s-kubelet: the disks are already past the new eviction line \(nodefs ($n)% used, imagefs ($i)%; it evicts at ($evict_n)% and ($evict_i)%\): free space first, docker-gc.sh; nothing changed"
		return false
	}
	if $n > $k.imageGC.high or $i > $k.imageGC.high {
		print --stderr $"k3s-kubelet: warning: the disks are past the image GC line \(($k.imageGC.high)%\) [nodefs ($n)%, imagefs ($i)%]: the kubelet collects images at once"
	}
	true
}

# Applies the kubelet's args, or with --check only says. Returns {code: 0 | 1}: 1 on drift (--check), a refusal, or a
# kubelet that did not take them. One apply at a time on a node.
export def apply-kubelet [k: record, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec]: nothing -> record {
	if ($env.KUBECTL? | default "") == "" { error make {msg: "k3s-kubelet: set KUBECTL to the kubectl the node's shell runs, with its kubeconfig (expanded on the node)"} }
	let config = (kubelet-config $k)
	if $check { return (apply-locked $k $config --check --node $node --root $root --polls $polls --pause $pause) }
	let lock = $"($root)($file).lock"
	let got = (sh $node $"mkdir -p '($root)($dir)/config.yaml.d' && { mkdir '($lock)' 2>/dev/null || { find '($lock)' -maxdepth 0 -mmin +30 | grep -q . && rm -rf '($lock)' && mkdir '($lock)'; }; }")
	if $got.exit_code != 0 {
		print --stderr $"k3s-kubelet: another apply holds ($lock) \(taken over after 30 minutes\): nothing changed"
		return {code: 1}
	}
	let r = (try { apply-locked $k $config --node $node --root $root --polls $polls --pause $pause } catch {|e|
		sh $node $"rmdir '($lock)'" | ignore
		error make {msg: $e.msg}
	})
	sh $node $"rmdir '($lock)'" | ignore
	$r
}

def apply-locked [k: record, config: string, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec]: nothing -> record {
	let want = (want-configz $k)
	let live = $root + $file
	let prev = $"($live).prev"
	let pending = $"($live).pending"
	let tmp = $"($live).new"
	let others = (other-kubelet-arg $node $root $live)
	if not ($others | is-empty) {
		print --stderr $"k3s-kubelet: another file sets kubelet-arg, which would replace or be replaced by ours: ($others | str join ', '): nothing changed"
		return {code: 1}
	}
	let current = (must (sh $node $"if [ -e '($live)' ]; then cat '($live)'; fi") "reading the file")
	# The marker's existence says an earlier apply was not checked; what it holds only says what the rollback does.
	let marked = ((must (sh $node $"if [ -e '($pending)' ]; then echo yes; fi") "reading the marker" | str trim) == "yes")
	mut changed = $marked
	let restart = {||
		let r = (sh $node "timeout 180 systemctl restart k3s")
		if $r.exit_code != 0 { print --stderr $"k3s-kubelet: the restart failed \(($r.exit_code)\): ($r.stderr | str trim)" } else { print "k3s restarted" }
		$r.exit_code == 0
	}

	if $current == $config {
		print $"($live) is as #Host says"
		if $check {
			if $marked { print $"($pending): an earlier apply was not checked"; return {code: 1} }
			return {code: 0}
		}
		# With the marker the earlier run's check is ours to finish, and a kubelet that is down (k3s crashed after the
		# rename) must reach the rollback below, so there is no early return then.
		if not $marked {
			let r = (read-settled $node $want $polls $pause)
			if $r.state == "unreadable" {
				print --stderr $"k3s-kubelet: the kubelet's config could not be read: ($r.said); nothing restarted"
				return {code: 1}
			}
			if $r.state == "differs" {
				print "the kubelet does not run with it yet"
				if not (preflight $node $k) { return {code: 1} }
				do $restart | ignore
			}
		}
	} else {
		print $"($live) differs"
		if $check { return {code: 1} }
		if not (preflight $node $k) { return {code: 1} }
		$changed = true
		let sum = ($config | hash sha256)
		# The marker and backup are made first, and only when no earlier run left them (its backup is the good one), and
		# synced; a run that fails before the rename removes what it made. The new file is synced before the rename.
		let install = $"made=0; mkdir -p '($live | path dirname)' && { test -e '($pending)' || { rm -f '($prev)' && made=1 && k=none && { ! test -e '($live)' || { cp -p '($live)' '($prev)' && k=had; }; } && echo $k >'($pending)' && sync; }; } && rm -f '($tmp)' && { tee '($tmp)' >/dev/null && sync && [ \"$\(sha256sum '($tmp)' | cut -d' ' -f1\)\" = ($sum) ] && mv -f '($tmp)' '($live)' && sync; } || { rm -f '($tmp)'; [ \"$made\" != 1 ] || rm -f '($pending)' '($prev)'; exit 1; }"
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
	# copy beside it and a rename, with the backup kept until the kubelet is known to answer. The marker says which; one
	# that says neither stops here, with everything kept.
	let back = (sh $node $"case \"$\(cat '($pending)' 2>/dev/null\)\" in had) cp -p '($prev)' '($tmp)' && sync && mv -f '($tmp)' '($live)' ;; none) rm -f '($live)' ;; *) echo 'the pending marker holds neither had nor none' >&2; exit 1 ;; esac")
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
	print "usage: KUBECTL=... kubelet.nu apply <host.json> [--check] [--node user@host]"
	exit 2
}
