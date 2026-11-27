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
# It refuses, before writing, when the kubelet's config cannot be read (a wrong KUBECTL, missing rights or a node-name
# mismatch would otherwise cost two restarts at every run: it is read first, and nothing is restarted unread), when
# another file under /etc/rancher/k3s/config.yaml{,.d}, the k3s unit (systemctl cat k3s) or its environment files holds
# kubelet-arg (it would replace or be replaced by ours), when another apply holds the node's lock, and when the node's
# disks or inodes are already past the new eviction line (a restart into eviction). The lock is a directory beside the
# file holding the node's boot id; the apply touches it on every poll and before each restart, and it is taken over when
# the node has rebooted since, or when untouched for twice the longest gap between touches. The thresholds bound the damage
# when a disk fills; what prevents it is the cleanup of docker-gc.sh. Worst case an apply restarts k3s twice: once for the
# new file and once for a rollback (an unreadable kubelet costs none).
#
# `cue` must be on the PATH: the values are vetted against #Kubelet before anything else runs.
#
# Needs ssh to the node, whose sudo asks no password, and kubectl on the node: KUBECTL, expanded there by the login
# shell (it names the kubeconfig; this module has no default for a node's own). Every call has a deadline; the ssh is
# never retried (a failed login gets the Mac banned by the node's CrowdSec). --check changes nothing and exits 1 on
# drift. --root puts every path under it (for the tests).

use host.nu [sh must]

const here = path self | path dirname

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
	'^image-gc-high-threshold=[1-9][0-9]?$'
	'^image-gc-low-threshold=[1-9][0-9]?$'
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
	# 255 is ssh's own failure, not a kubelet that is still starting: it stops the run instead of opening more logins.
	if $r.exit_code == 255 { error make {msg: $"k3s-kubelet: ssh failed, stopping: ($r.stderr | str trim)"} }
	if $r.exit_code != 0 { return {state: "unreadable", said: $"the request failed: ($r.stderr | str trim)"} }
	let parsed = (try { $r.stdout | from json } catch { null })
	let cfg = (if $parsed == null { null } else { $parsed | get -o kubeletconfig })
	if ($cfg | describe --detailed).type != "record" { return {state: "unreadable", said: ($r.stdout | str trim | default "no answer")} }
	# A kubeletconfig without the fields that are compared (an empty one, a partial one) says nothing about the args: unreadable,
	# never "differs" (which allows a restart) and never an answer that passes the rollback's check.
	let missing = ($want | columns | where {|c| ($cfg | get -o $c) == null })
	if not ($missing | is-empty) { return {state: "unreadable", said: $"the answer lacks ($missing | str join ', ')"} }
	let got = ($want | columns | each {|c| {($c): ($cfg | get -o $c)}} | into record)
	{state: (if $got == $want { "match" } else { "differs" }), said: ($got | to json --raw)}
}

# The lock's mtime is its heartbeat: touched on every poll and before each restart, so a live apply is never taken over.
def beat [node: string, lock: string] {
	if $lock == "" { return }
	let r = (sh $node $"touch '($lock)'")
	# 255 is ssh's own failure: it stops the run (a failed login is never retried, a ban cuts the operator off), the lock is left to expire.
	if $r.exit_code == 255 { error make {msg: $"k3s-kubelet: ssh failed, stopping: ($r.stderr | str trim)"} }
	# Any other failure of the touch is a lock that is not being kept alive (a read-only filesystem, a lock taken away): stop.
	if $r.exit_code != 0 { error make {msg: $"k3s-kubelet: the lock heartbeat failed \(touch exited ($r.exit_code)\), stopping: ($r.stderr | str trim)"} }
}

# Reads until it is not unreadable, up to $polls times.
def read-settled [node: string, want: record, polls: int, pause: duration, lock: string]: nothing -> record {
	mut r = {state: "unreadable", said: "no answer"}
	for _ in 1..$polls {
		beat $node $lock
		$r = (read-configz $node $want)
		if $r.state != "unreadable" { break }
		sleep $pause
	}
	$r
}

# The files, other than ours, under the k3s config that set kubelet-arg.
def other-kubelet-arg [node: string, root: string, live: string]: nothing -> list<string> {
	let base = $root + $dir
	let envs = [$"($root)/etc/systemd/system/k3s.service.env" $"($root)/etc/default/k3s" $"($root)/etc/sysconfig/k3s"] | each {|f| $"'($f)'"} | str join " "
	# An absent file is skipped; a file that exists and cannot be read (grep's status 2), or a unit systemctl cannot print, is an
	# error, never a clean result. The text of this script holds no parenthesised word nu would run on this machine.
	let scan = $"for f in '($base)/config.yaml' '($base)/config.yaml.d/'*.yaml '($base)/config.yaml.d/'*.yml ($envs); do [ -e \"$f\" ] || continue; [ \"$f\" != '($live)' ] || continue; grep -q 'kubelet-arg' \"$f\"; r=$?; [ $r -le 1 ] || { echo \"cannot read $f\" >&2; exit 2; }; [ $r -ne 0 ] || echo \"$f\"; done; u=$\(systemctl cat k3s 2>&1\) || { echo \"cannot read the k3s unit: $u\" >&2; exit 3; }; printf '%s\\n' \"$u\" | grep -q 'kubelet-arg' && echo 'the k3s unit'; true"
	let out = (must (sh $node $scan) "looking for other kubelet-arg")
	$out | lines | where {|l| $l != ""}
}

# Percent used of the filesystem a path is on.
def disk-used [node: string, path: string, --inodes]: nothing -> int {
	let flag = if $inodes { "-Pi" } else { "-P" }
	let out = (must (sh $node $"df ($flag) '($path)' 2>/dev/null | awk 'NR==2 {gsub\(\"%\", \"\", $5\); print $5}'") $"reading the use of ($path)" | str trim)
	if $out == "" { error make {msg: $"k3s-kubelet: cannot read the use of ($path)"} }
	$out | into int
}

# A restart into eviction is refused: the disks are already past the line the kubelet would evict at, and it would take
# pods on its first pass. Past the image GC line only warns (the kubelet collects images, which is what is wanted).
def preflight [node: string, k: record, root: string]: nothing -> bool {
	let h = $k.evictionHard
	# Memory too: a restart on a node already under twice the memory threshold would evict at once (the kubelet's own memory
	# eviction is part of what this sets). MemAvailable is in kB.
	let avail_mi = (must (sh $node $"awk '/^MemAvailable:/ {print int\($2 / 1024\)}' '($root)/proc/meminfo'") "reading MemAvailable" | str trim)
	if $avail_mi == "" { error make {msg: "k3s-kubelet: cannot read MemAvailable"} }
	let mem_thr = ($h.memory | str replace "Mi" "" | into int)
	if ($avail_mi | into int) < (2 * $mem_thr) {
		print --stderr $"k3s-kubelet: the node has ($avail_mi)Mi of memory available, under twice the new memory eviction threshold \(($h.memory)\): free memory first, nothing changed"
		return false
	}
	let n = (disk-used $node $nodefs_dir)
	let i = (disk-used $node $imagefs_dir)
	let ni = (disk-used $node $nodefs_dir --inodes)
	let ii = (disk-used $node $imagefs_dir --inodes)
	let evict_n = (100 - $h.nodefs)
	let evict_i = (100 - $h.imagefs)
	let evict_ni = (100 - $h.nodefsInodes)
	let evict_ii = (100 - $h.imagefsInodes)
	if $n >= $evict_n or $i >= $evict_i or $ni >= $evict_ni or $ii >= $evict_ii {
		print --stderr $"k3s-kubelet: the disks are already past the new eviction line \(nodefs ($n)% used, imagefs ($i)%, inodes ($ni)% and ($ii)%; it evicts at ($evict_n)%, ($evict_i)%, ($evict_ni)% and ($evict_ii)%\): free space first, docker-gc.sh; nothing changed"
		return false
	}
	if $n > $k.imageGC.high or $i > $k.imageGC.high {
		print --stderr $"k3s-kubelet: warning: the disks are past the image GC line \(($k.imageGC.high)%\) [nodefs ($n)%, imagefs ($i)%]: the kubelet collects images at once"
	}
	true
}

# The values must be what #Kubelet allows, before anything runs: they become the kubelet's args on the only node.
def vet-kubelet [k: record] {
	let f = (mktemp --tmpdir node-kubelet-vet-XXXXXX.json)
	$k | to json | save --force --raw $f
	let r = (try { do { ^cue vet -c ($here | path join schema host.cue) $f -d '#Kubelet' } | complete } catch {
		rm -f $f
		error make {msg: "k3s-kubelet: cue is required (it vets the values against #Kubelet) and could not be run"}
	})
	rm -f $f
	if $r.exit_code != 0 { error make {msg: $"k3s-kubelet: the host's kubelet values are not what #Kubelet allows: ($r.stderr | str trim)"} }
}

# Applies the kubelet's args, or with --check only says. Returns {code: 0 | 1}: 1 on drift (--check), a refusal, or a
# kubelet that did not take them. One apply at a time on a node.
export def apply-kubelet [k: record, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec]: nothing -> record {
	if ($env.KUBECTL? | default "") == "" { error make {msg: "k3s-kubelet: set KUBECTL to the kubectl the node's shell runs, with its kubeconfig (expanded on the node)"} }
	vet-kubelet $k
	let config = (kubelet-config $k)
	if $check { return (apply-locked $k $config "" --check --node $node --root $root --polls $polls --pause $pause) }
	let lock = $"($root)($file).lock"
	# Taken over when the node rebooted since (its boot id is in the lock), or when untouched for twice the longest gap between
	# touches: a restart (180 s) and a read (about 25 s) and a pause. Never under 10 minutes.
	let gap = (180 + 25 + ($pause / 1sec))
	let takeover = ([10 (($gap * 2 / 60) | math ceil)] | math max)
	let boot = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
	let acquire = $"mkdir -p '($root)($dir)/config.yaml.d' || exit 3; if ! mkdir '($lock)' 2>/dev/null; then b=$\(cut -d' ' -f1 '($lock)/owner' 2>/dev/null\); cur=($boot); if { [ -n \"$b\" ] && [ \"$b\" != \"$cur\" ]; } || [ -n \"$\(find '($lock)' -maxdepth 0 -mmin +($takeover) 2>/dev/null\)\" ]; then mv '($lock)' '($lock).old.'$$ 2>/dev/null && mkdir '($lock)' || exit 1; rm -rf '($lock).old.'$$; else exit 1; fi; fi; echo \"($boot) $\(date -u +%FT%TZ\)\" >'($lock)/owner'"
	let got = (sh $node $acquire)
	if $got.exit_code == 255 { error make {msg: $"k3s-kubelet: ssh failed, nothing changed: ($got.stderr | str trim)"} }
	if $got.exit_code == 3 { error make {msg: $"k3s-kubelet: cannot create ($root)($dir)/config.yaml.d on the node, nothing changed: ($got.stderr | str trim)"} }
	if $got.exit_code != 0 {
		print --stderr $"k3s-kubelet: another apply holds ($lock) \(taken over after a reboot, or ($takeover) minutes untouched\): nothing changed"
		return {code: 1}
	}
	let r = (try { apply-locked $k $config $lock --node $node --root $root --polls $polls --pause $pause } catch {|e|
		# Both are said: what stopped the run, and, when the lock could not be released either, that, with its path.
		# After a failed login no second one is made to release the lock (a failed login is never retried): it expires.
		if ($e.msg | str starts-with "k3s-kubelet: ssh failed") { error make {msg: $"($e.msg); the lock ($lock) is left to expire"} }
		let rel = (sh $node $"rm -rf '($lock)'")
		let also = if $rel.exit_code != 0 { $"; releasing the lock ($lock) also failed \(exit ($rel.exit_code)\): ($rel.stderr | str trim)" } else { "" }
		error make {msg: $"($e.msg)($also)"}
	})
	must (sh $node $"rm -rf '($lock)'") $"releasing the lock ($lock)" | ignore
	$r
}

def apply-locked [k: record, config: string, lock: string, --check, --node: string = "", --root: string = "", --polls: int = 60, --pause: duration = 2sec]: nothing -> record {
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
	# What the marker holds: had or none (a file this run or an earlier one installed, and whether there was a previous one), or
	# rollback-had / rollback-none (a rollback that began: the previous file is being, or has been, put back).
	let phase = (if $marked { must (sh $node $"cat '($pending)'") "reading the marker" | str trim } else { "" })
	# Only these four are ours. Anything else (a marker a hand or a half-finished write left) stops the run before it installs or
	# restarts anything: the operator looks at it.
	if $marked and not ($phase in ["had" "none" "rollback-had" "rollback-none"]) {
		print --stderr $"k3s-kubelet: ($pending) holds ($phase | to json --raw), none of had, none, rollback-had, rollback-none: nothing changed; check it by hand"
		return {code: 1}
	}
	mut changed = $marked
	# What the kubelet reported before anything was written: when it already runs these args, a change to the file's text needs
	# no restart.
	mut before = ""
	# Settled: the marker goes last, after the backup and the scratch files, each synced, so a run that dies in between leaves
	# either the marker with its backup, or neither.
	let settle = $"rm -f '($prev)' '($tmp)' '($prev).tmp' '($pending).tmp' && sync && rm -f '($pending)' && sync"
	let restart = {||
		beat $node $lock
		let r = (sh $node "timeout 180 systemctl restart k3s")
		if $r.exit_code != 0 { print --stderr $"k3s-kubelet: the restart failed \(($r.exit_code)\): ($r.stderr | str trim)" } else { print "k3s restarted" }
		$r.exit_code == 0
	}

	# The only node: a config this run (or an earlier unchecked one) wrote and the kubelet did not take is put back, by a
	# copy beside it and a rename, with the backup kept until the kubelet is known to answer. The marker first records that the
	# rollback began (rollback-had or rollback-none, synced), so a run that finds it, because this one died after the restore and
	# before the restart, finishes the rollback and verifies the previous config before it installs anything. A marker that says
	# none of had, none or a rollback stops here, with everything kept.
	let rollback = {||
		let back = (sh $node $"case \"$\(cat '($pending)' 2>/dev/null\)\" in had|rollback-had) k=rollback-had ;; none|rollback-none) k=rollback-none ;; *) echo 'the pending marker holds none of had, none, rollback-had, rollback-none' >&2; exit 1 ;; esac; echo $k >'($pending).tmp' && sync && mv -f '($pending).tmp' '($pending)' && sync && case $k in rollback-had) cp -p '($prev)' '($tmp)' && sync && mv -f '($tmp)' '($live)' && sync ;; rollback-none) rm -f '($live)' && sync ;; esac")
		if $back.exit_code != 0 {
			print --stderr $"k3s-kubelet: the previous file could not be put back: ($back.stderr | str trim); ($pending) is kept"
			return {code: 1}
		}
		let restarted = (do $restart)
		if $restarted {
			let r = (read-settled $node $want $polls $pause $lock)
			if $r.state != "unreadable" {
				must (sh $node $settle) $"removing ($pending) and ($prev) after the rollback" | ignore
				print --stderr "k3s-kubelet: put the previous file back and restarted k3s"
				return {code: 1}
			}
		}
		print --stderr $"k3s-kubelet: the previous file is back but k3s did not restart or the kubelet does not answer; ($pending) and ($prev) are kept: apply again once k3s is up"
		{code: 1}
	}
	# An interrupted rollback is finished before anything else: no new install, no check of the config that was rejected.
	if $marked and not $check and ($phase | str starts-with "rollback") {
		print "an earlier rollback did not finish: finishing it"
		return (do $rollback)
	}

	if $current == $config {
		print $"($live) is as #Host says"
		if $check {
			if $marked { print $"($pending): an earlier apply was not checked"; return {code: 1} }
			# The file matching is not the kubelet running it: a file copied in without a restart passes only if configz agrees.
			let r = (read-settled $node $want $polls $pause "")
			if $r.state != "match" {
				print --stderr $"k3s-kubelet: the file is as #Host says, but the kubelet does not report #Host's args \(($r.state)\): ($r.said)"
				return {code: 1}
			}
			return {code: 0}
		}
		# With the marker the earlier run's check is ours to finish, and a kubelet that is down (k3s crashed after the
		# rename) must reach the rollback below, so there is no early return then.
		if not $marked {
			let r = (read-settled $node $want $polls $pause $lock)
			if $r.state == "unreadable" {
				print --stderr $"k3s-kubelet: the kubelet's config could not be read: ($r.said); nothing restarted"
				return {code: 1}
			}
			if $r.state == "differs" {
				print "the kubelet does not run with it yet"
				if not (preflight $node $k $root) { return {code: 1} }
				do $restart | ignore
			}
		} else {
			# An earlier apply installed the file and stopped: if it died before its restart, the kubelet still runs the old args
			# (readable, differing), and restarting it is that apply's next step. A kubelet that is down falls through to the wait and
			# the rollback below.
			let r = (read-settled $node $want $polls $pause $lock)
			if $r.state == "differs" {
				print "an earlier apply installed the file but the kubelet does not run it: restarting"
				if not (preflight $node $k $root) { return {code: 1} }
				do $restart | ignore
			}
		}
	} else {
		print $"($live) differs"
		if $check { return {code: 1} }
		# The kubelet's config is read before anything is written or restarted: a wrong KUBECTL, missing rights or a node-name
		# mismatch must cost no restart. (With the marker an earlier run's rollback is due, whatever it reads.)
		if not $marked {
			let r = (read-settled $node $want $polls $pause $lock)
			if $r.state == "unreadable" {
				print --stderr $"k3s-kubelet: the kubelet's config could not be read: ($r.said); nothing changed"
				return {code: 1}
			}
			$before = $r.state
		}
		let sum = ($config | hash sha256)
		if $before == "match" {
			# The kubelet already runs these args: only the file's text differs (a comment, an older spelling). It is replaced whole and
			# atomically, with no marker and no backup (nothing is restarted, so nothing can be rejected), and checked again.
			let plain = $"rm -f '($tmp)' && tee '($tmp)' >/dev/null && sync && [ \"$\(sha256sum '($tmp)' | cut -d' ' -f1\)\" = ($sum) ] && mv -f '($tmp)' '($live)' && sync || { rm -f '($tmp)'; exit 1; }"
			let w = (sh $node $plain $config)
			if $w.exit_code == 255 { error make {msg: $"k3s-kubelet: ssh failed while writing the file, stopping: ($w.stderr | str trim)"} }
			if $w.exit_code != 0 {
				print --stderr $"k3s-kubelet: writing the file failed, the live file is as it was: ($w.stderr | str trim)"
				return {code: 1}
			}
			let again = (read-settled $node $want $polls $pause $lock)
			if $again.state != "match" {
				print --stderr $"k3s-kubelet: the file is rewritten, but the kubelet no longer reports #Host's args \(($again.state)\): ($again.said)"
				return {code: 1}
			}
			print "the kubelet already runs #Host's args: the file is rewritten, nothing restarted"
			return {code: 0}
		}
		if not (preflight $node $k $root) { return {code: 1} }
		$changed = true
		# The backup and the marker are made first, each by a temporary file, synced, then renamed (so either is absent or whole,
		# never partial), the backup before the marker, and only when no earlier run left them (its backup is the good one); a run
		# that fails before the rename removes what it made. The new file is synced before the rename.
		# Before the rename any failure leaves the live file as it was and removes what this run made. Once the rename has
		# happened the new file is live: a failed sync then (exit 4) keeps the marker and the backup, and the run stops, for the
		# next one to verify or roll back.
		let install = $"made=0; undo\(\) { rm -f '($tmp)' '($prev).tmp' '($pending).tmp'; [ \"$made\" != 1 ] || rm -f '($pending)' '($prev)'; }; mkdir -p '($live | path dirname)' || exit 1; rm -f '($prev).tmp' '($pending).tmp'; if ! test -e '($pending)'; then rm -f '($prev)' && made=1 || { undo; exit 1; }; if test -e '($live)'; then cp -p '($live)' '($prev).tmp' && sync && mv -f '($prev).tmp' '($prev)' && k=had || { undo; exit 1; }; else k=none; fi; echo $k >'($pending).tmp' && sync && mv -f '($pending).tmp' '($pending)' && sync || { undo; exit 1; }; fi; rm -f '($tmp)' && tee '($tmp)' >/dev/null && sync && [ \"$\(sha256sum '($tmp)' | cut -d' ' -f1\)\" = ($sum) ] || { undo; exit 1; }; mv -f '($tmp)' '($live)' || { undo; exit 1; }; sync || { echo 'the new file is installed but sync failed' >&2; exit 4; }"
		let w = (sh $node $install $config)
		if $w.exit_code == 255 { error make {msg: $"k3s-kubelet: ssh failed while writing the file, stopping: ($w.stderr | str trim)"} }
		if $w.exit_code == 4 {
			print --stderr $"k3s-kubelet: the new file is installed but could not be synced: ($w.stderr | str trim); ($pending) and ($prev) are kept: apply again to verify it or roll it back"
			return {code: 1}
		}
		if $w.exit_code != 0 {
			print --stderr $"k3s-kubelet: writing the file failed, the live file is as it was: ($w.stderr | str trim)"
			return {code: 1}
		}
		do $restart | ignore
	}

	# Also when the file did not change: an earlier restart may have failed. The API answers again within a minute of a restart.
	mut last = {state: "unreadable", said: "no answer"}
	for _ in 1..$polls {
		beat $node $lock
		$last = (read-configz $node $want)
		if $last.state == "match" {
			print "the kubelet runs with #Host's args"
			if $changed { must (sh $node $settle) $"removing ($pending) and ($prev) \(the kubelet runs the file, but the marker stays: apply again\)" | ignore }
			return {code: 0}
		}
		sleep $pause
	}
	print --stderr $"k3s-kubelet: the kubelet does not report #Host's args: ($last.said)"
	if not $changed { return {code: 1} }

	return (do $rollback)
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
