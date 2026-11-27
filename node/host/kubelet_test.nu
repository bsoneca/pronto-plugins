#!/usr/bin/env nu
# Run with: nu node/host/kubelet_test.nu
#
# kubelet.nu against a fake node: ssh runs the remote command here, with sudo, tee, systemctl and kubectl stood in
# and the node's files in a temp root. The stand-in k3s "restarts" by taking the live file as what the kubelet runs,
# and the stand-in kubectl answers configz for what it runs. Nothing here touches a node.

use std/assert
use kubelet.nu [apply-kubelet kubelet-args kubelet-config want-configz]

const here = path self | path dirname
const live_path = "/etc/rancher/k3s/config.yaml.d/max-pods.yaml"

def main [] {
	print "Running node kubelet tests...\n"
	test_the_args_and_config_hold_the_full_eviction_map_and_the_log_limits
	test_cue_refuses_a_map_missing_a_threshold_and_a_gc_that_does_not_come_first
	test_a_kubelet_that_takes_the_file_is_the_control
	test_a_full_disk_leaves_the_live_file_as_it_was
	test_a_kubelet_that_does_not_take_the_file_gets_the_previous_one_back
	test_no_previous_file_means_no_file_after_a_rollback
	test_an_unreadable_config_is_never_a_kubelet_that_took_the_file
	test_a_rollback_whose_restart_fails_keeps_the_marker
	test_a_rerun_after_an_interrupted_apply_rolls_back_from_the_first_backup
	test_a_rerun_restarts_only_on_a_config_it_read_and_that_differs
	test_check_changes_nothing
	test_every_call_has_a_deadline
	print "\nAll node kubelet tests passed."
}

def valid []: nothing -> record {
	{
		maxPods: 250
		evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}
		evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}
		imageGC: {high: 80, low: 70}
		containerLogMaxSize: "10Mi"
		containerLogMaxFiles: 5
	}
}

def test_the_args_and_config_hold_the_full_eviction_map_and_the_log_limits [] {
	print "test the args hold every eviction threshold (a partial map drops the kubelet's defaults) and the log limits..."
	assert equal (kubelet-args (valid)) [
		"max-pods=250"
		"eviction-hard=memory.available<100Mi,nodefs.available<5%,nodefs.inodesFree<5%,imagefs.available<5%,imagefs.inodesFree<5%"
		"eviction-minimum-reclaim=nodefs.available=2Gi,imagefs.available=4Gi"
		"image-gc-high-threshold=80"
		"image-gc-low-threshold=70"
		"container-log-max-size=10Mi"
		"container-log-max-files=5"
	]
	let text = (kubelet-config (valid))
	assert str contains $text "kubelet-arg:\n  - \"max-pods=250\"\n  - \"eviction-hard=memory.available<100Mi,nodefs.available<5%,nodefs.inodesFree<5%,imagefs.available<5%,imagefs.inodesFree<5%\"\n"
	assert equal (want-configz (valid)).evictionHard {"memory.available": "100Mi", "nodefs.available": "5%", "nodefs.inodesFree": "5%", "imagefs.available": "5%", "imagefs.inodesFree": "5%"}
	# An arg that is not one of the shapes the script sets never reaches the node's only kubelet.
	let bad = (try { kubelet-config ((valid) | update containerLogMaxSize "10Mi,evil=1") ; "none" } catch {|e| $e.msg })
	assert str contains $bad "not an arg this script sets"
}

# Whether #Host with these kubelet values is accepted by cue (the values unified with the valid ones).
def cue-ok [values: string]: nothing -> bool {
	let f = (mktemp --tmpdir node-kubelet-XXXXXX.cue)
	$"package schema\nhost: #Host & {kubelet: ($values)}\n" | save --force --raw $f
	let r = (do { ^cue export ($here | path join schema host.cue) $f -e host --out json } | complete)
	rm -f $f
	$r.exit_code == 0
}

const ok_values = '{evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}'

def test_cue_refuses_a_map_missing_a_threshold_and_a_gc_that_does_not_come_first [] {
	print "test #Host refuses a map missing memory or inodes, and image GC or log limits that cannot work..."
	assert (cue-ok $"($ok_values)}") "the control"
	assert (not (cue-ok '{evictionHard: {nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}}')) "no memory.available"
	assert (not (cue-ok '{evictionHard: {memory: "100Mi", nodefs: 5, imagefs: 5, imagefsInodes: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}}')) "no nodefs.inodesFree"
	assert (not (cue-ok '{evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}}')) "no imagefs.inodesFree"
	assert (not (cue-ok '{evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}, imageGC: {high: 80, low: 70}}')) "no minimum reclaim"
	assert (not (cue-ok $"($ok_values | str replace 'high: 80' 'high: 95')}")) "image GC high past the eviction line"
	assert (not (cue-ok $"($ok_values | str replace 'low: 70' 'low: 80')}")) "low at high"
	assert (not (cue-ok $"($ok_values | str replace 'nodefs: 5, nodefsInodes' 'nodefs: 30, nodefsInodes')}")) "evicting at 30% free"
	assert (not (cue-ok $"($ok_values), containerLogMaxFiles: 1}")) "one log file"
	assert (not (cue-ok $"($ok_values), containerLogMaxSize: \"10 Mi\"}")) "a size with a space"
	assert (not (cue-ok $"($ok_values), maxPods: 5}")) "a pod limit under the floor"
}

# Runs apply-kubelet against a fake node. `start`: the node's files before the run ({live, pending, prev, running}, each
# text or null). `mode`: ok (the kubelet runs the live file after a restart), stuck (it keeps running the old file),
# noapi (kubectl fails), empty (kubectl answers nothing, exit 0), fulldisk (tee fails halfway), stuckfail (stuck, and the second
# k3s restart fails). Returns what the run did.
def scenario [mode: string, start: record, --check]: nothing -> record {
	let dir = (mktemp --directory --tmpdir node-kubelet-XXXXXX)
	let root = ($dir | path join root)
	let live = $root + $live_path
	mkdir ($live | path dirname)
	mkdir ($dir | path join bin)
	let k = (valid)
	(kubelet-config $k) | save --raw ($dir | path join desired.yaml)
	{kubeletconfig: (want-configz $k)} | to json | save --raw ($dir | path join configz.new)
	{kubeletconfig: ((want-configz $k) | update maxPods 110)} | to json | save --raw ($dir | path join configz.old)
	for f in [[live $live] [pending $"($live).pending"] [prev $"($live).prev"]] {
		let text = ($start | get -o $f.0)
		if $text != null { $text | save --raw $f.1 }
	}
	if ($start | get -o running) != null { $start.running | save --raw ($dir | path join running) }
	let shim = {|name, body| $"#!/usr/bin/env bash\n($body)\n" | save --raw ($dir | path join bin $name); chmod 755 ($dir | path join bin $name) }
	do $shim ssh 'd=$(dirname "$0")/..; while [ "$1" = -o ]; do echo "$2" >>"$d/ssh.opts"; shift 2; done; shift; exec bash -c "$1"'
	do $shim sudo 'exec "$@"'
	do $shim sha256sum 'exec shasum -a 256 "$@"'
	do $shim systemctl 'd=$(dirname "$0")/..; echo "$*" >>"$d/systemctl.log"; n=$(wc -l <"$d/systemctl.log"); if [ "$MODE" = stuckfail ] && [ "$n" -ge 2 ]; then exit 1; fi; [ -e "$KUBELET_LIVE" ] && cp "$KUBELET_LIVE" "$d/running"; true'
	do $shim tee 'if [ "$MODE" = fulldisk ]; then head -c 12 >"$1"; exit 1; fi; exec /usr/bin/tee "$@"'
	do $shim kubectl 'd=$(dirname "$0")/..; echo "$*" >>"$d/kubectl.log"; case "$*" in *--raw*) case "$MODE" in noapi) exit 1;; empty) exit 0;; esac; if [ "$MODE" != stuck ] && [ "$MODE" != stuckfail ] && [ -e "$d/running" ] && cmp -s "$d/running" "$d/desired.yaml"; then cat "$d/configz.new"; else cat "$d/configz.old"; fi;; *) echo node1;; esac'
	"" | save --raw ($dir | path join systemctl.log)
	let r = (with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')", KUBECTL: ($dir | path join bin kubectl), MODE: $mode, KUBELET_LIVE: $live} {
		apply-kubelet $k --check=$check --node fake --root $root --polls 2 --pause 0sec
	})
	let read = {|f| if ($f | path exists) { open --raw $f } else { null } }
	let trim = {|t| if $t == null { null } else { $t | str trim } }
	let out = {
		code: $r.code
		live: (do $read $live)
		pending: (do $trim (do $read $"($live).pending"))
		prev: (do $read $"($live).prev")
		leftover: (($"($live).new" | path exists))
		restarts: (open --raw ($dir | path join systemctl.log) | lines | where {|l| $l != ""} | length)
		ssh_opts: (do $read ($dir | path join ssh.opts) | default "")
		kubectl: (do $read ($dir | path join kubectl.log) | default "")
	}
	rm -rf $dir
	$out
}

def desired []: nothing -> string { kubelet-config (valid) }

def test_a_kubelet_that_takes_the_file_is_the_control [] {
	print "test a changed file is installed, k3s restarted once, the kubelet reports the args, nothing left behind..."
	let r = (scenario ok {live: "old: file\n"})
	assert equal $r.code 0
	assert equal $r.live (desired)
	assert equal $r.restarts 1
	assert equal $r.pending null
	assert equal $r.prev null
	assert equal $r.leftover false
}

def test_a_full_disk_leaves_the_live_file_as_it_was [] {
	print "test a write that fails halfway leaves the live file, no .new, no marker, no restart..."
	let r = (scenario fulldisk {live: "old: file\n"})
	assert equal [$r.code $r.live $r.leftover $r.pending $r.prev $r.restarts] [1 "old: file\n" false null null 0]
	let none = (scenario fulldisk {})
	assert equal [$none.code $none.live $none.leftover $none.pending $none.prev $none.restarts] [1 null false null null 0]
}

def test_a_kubelet_that_does_not_take_the_file_gets_the_previous_one_back [] {
	print "test a kubelet that keeps its old args gets the previous file back by a rename, and k3s restarts again..."
	let r = (scenario stuck {live: "old: file\n"})
	assert equal [$r.code $r.live $r.leftover $r.pending $r.prev $r.restarts] [1 "old: file\n" false null null 2]
}

def test_no_previous_file_means_no_file_after_a_rollback [] {
	print "test with no previous file the rollback removes the new one..."
	let r = (scenario stuck {})
	assert equal [$r.code $r.live $r.leftover $r.pending $r.prev $r.restarts] [1 null false null null 2]
}

def test_an_unreadable_config_is_never_a_kubelet_that_took_the_file [] {
	print "test a failed request, and an empty answer that exits 0, are not success: the file is put back..."
	for mode in [noapi empty] {
		let r = (scenario $mode {live: "old: file\n"})
		assert equal $r.code 1 $mode
		assert equal $r.live "old: file\n" $mode
		assert equal $r.restarts 2 $mode
		# The kubelet never answered after the rollback either: the marker and backup stay, for the next run.
		assert equal $r.pending "had" $mode
		assert equal $r.prev "old: file\n" $mode
	}
}

def test_a_rollback_whose_restart_fails_keeps_the_marker [] {
	print "test a rollback whose k3s restart fails is not settled: exit 1, the previous file back, the marker and backup kept..."
	let r = (scenario stuckfail {live: "old: file\n"})
	assert equal [$r.code $r.live $r.pending $r.prev $r.restarts] [1 "old: file\n" "had" "old: file\n" 2]
	let none = (scenario stuckfail {})
	assert equal [$none.code $none.live $none.pending $none.restarts] [1 null "none" 2]
}

def test_a_rerun_after_an_interrupted_apply_rolls_back_from_the_first_backup [] {
	print "test a rerun that finds the marker rolls back from the first backup, and does not overwrite it..."
	# An earlier run replaced the file (live is now a bad intermediate one) and stopped; its backup holds the good one.
	let r = (scenario stuck {live: "mid: file\n", pending: "had\n", prev: "good: file\n"})
	assert equal [$r.code $r.live $r.pending $r.prev] [1 "good: file\n" null null]
	# The file is already the desired one, the earlier run stopped before its check: the kubelet does not run it, so back it goes.
	let same = (scenario stuck {live: (desired), pending: "had\n", prev: "good: file\n"})
	assert equal [$same.code $same.live $same.pending $same.prev] [1 "good: file\n" null null]
	# And no previous file at the time: the file is removed.
	let none = (scenario stuck {live: (desired), pending: "none\n"})
	assert equal [$none.code $none.live $none.pending] [1 null null]
	# A kubelet that does run the file settles the marker.
	let ok = (scenario ok {live: (desired), pending: "had\n", prev: "good: file\n", running: (desired)})
	assert equal [$ok.code $ok.live $ok.pending $ok.prev $ok.restarts] [0 (desired) null null 0]
}

def test_a_rerun_restarts_only_on_a_config_it_read_and_that_differs [] {
	print "test with the file in place a rerun restarts k3s only for a config it read that differs..."
	let differs = (scenario ok {live: (desired), running: "old: running\n"})
	assert equal [$differs.code $differs.restarts] [0 1]
	let same = (scenario ok {live: (desired), running: (desired)})
	assert equal [$same.code $same.restarts] [0 0]
	for mode in [noapi empty] {
		let r = (scenario $mode {live: (desired), running: "old: running\n"})
		assert equal [$r.code $r.restarts $r.live] [1 0 (desired)] $"unreadable ($mode): no restart"
	}
}

def test_check_changes_nothing [] {
	print "test --check exits 1 on a difference or an unchecked apply, and writes and restarts nothing..."
	let differs = (scenario ok {live: "old: file\n"} --check)
	assert equal [$differs.code $differs.live $differs.restarts $differs.pending] [1 "old: file\n" 0 null]
	let same = (scenario ok {live: (desired)} --check)
	assert equal [$same.code $same.restarts] [0 0]
	let unchecked = (scenario ok {live: (desired), pending: "had\n", prev: "x\n"} --check)
	assert equal [$unchecked.code $unchecked.restarts $unchecked.pending] [1 0 "had"]
}

def test_every_call_has_a_deadline [] {
	print "test every ssh has a connect timeout and keepalives, and every kubectl a request timeout..."
	let r = (scenario ok {live: "old: file\n"})
	assert str contains $r.ssh_opts "ConnectTimeout=10"
	assert str contains $r.ssh_opts "ServerAliveInterval=5"
	assert str contains $r.ssh_opts "ServerAliveCountMax=2"
	assert str contains $r.ssh_opts "BatchMode=yes"
	for line in ($r.kubectl | lines | where {|l| $l != ""}) { assert str contains $line "--request-timeout=10s" $line }
}
