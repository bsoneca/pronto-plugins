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
	test_a_rerun_with_the_marker_and_a_dead_kubelet_rolls_back
	test_the_marker_is_found_by_its_existence_and_read_only_to_roll_back
	test_without_the_marker_nothing_is_rolled_back
	test_a_short_write_that_exits_zero_is_caught_by_the_checksum
	test_a_flaky_first_read_is_retried_before_anything_is_restarted
	test_one_apply_at_a_time_and_no_second_kubelet_arg
	test_a_disk_already_past_the_eviction_line_is_not_restarted_into
	test_the_restart_is_under_a_timeout_and_the_lock_is_released_on_an_error
	test_the_use_of_the_image_disk_and_the_inodes_count
	test_other_places_that_set_kubelet_arg_refuse
	test_a_lock_from_before_a_reboot_is_taken_over_and_an_ssh_failure_is_not_a_held_lock
	test_values_are_vetted_before_anything_runs
	test_memory_already_under_the_eviction_margin_refuses
	test_the_lock_is_touched_at_every_poll_and_restart
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

const ok_values = '{maxPods: 250, evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}'

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
	assert (not (cue-ok $"($ok_values), maxPods: 254}")) "a pod limit past the node's address range"
	assert (not (cue-ok '{evictionHard: {memory: "100Mi", nodefs: 5, nodefsInodes: 5, imagefs: 5, imagefsInodes: 5}, evictionMinimumReclaim: {nodefs: "2Gi", imagefs: "4Gi"}, imageGC: {high: 80, low: 70}}')) "no pod limit said: a default would write k3s's 110 over the node's 250"
	assert (not (cue-ok $"($ok_values | str replace 'high: 80' 'high: 91')}")) "image GC high within 5 points of the eviction line"
	assert (cue-ok $"($ok_values | str replace 'high: 80' 'high: 90')}") "image GC high at 95 minus the eviction percent"
}

# Runs apply-kubelet against a fake node. `start`: the node's files before the run ({live, pending, prev, running}, each
# text or null). `mode`: ok (the kubelet runs the live file after a restart), stuck (it keeps running the old file),
# noapi (kubectl fails), empty (kubectl answers nothing, exit 0), fulldisk (tee fails halfway), stuckfail (stuck, and the second
# k3s restart fails). Returns what the run did.
def scenario [mode: string, start: record, --check, --df: int = 40, --df-img: int = -2, --dfi: int = 10, --other: string = "", --dropin: string = "", --unit: string = "", --stale: string = "", --mem: int = 4096, --locked]: nothing -> record {
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
	if $other != "" { $other | save --raw ($root | path join etc rancher k3s config.yaml) }
	mkdir ($root | path join proc)
	$"MemTotal: 8000000 kB\nMemAvailable: ($mem * 1024) kB\n" | save --raw ($root | path join proc meminfo)
	if $locked { mkdir $"($live).lock" }
	if $stale != "" { mkdir $"($live).lock"; $"($stale) 2026-01-01T00:00:00Z\n" | save --raw $"($live).lock/owner" }
	if $dropin != "" { $dropin | save --raw ($root | path join etc rancher k3s config.yaml.d 20-other.yaml) }
	if $unit != "" { $unit | save --raw ($dir | path join unitcat) }
	let shim = {|name, body| $"#!/usr/bin/env bash\n($body)\n" | save --raw ($dir | path join bin $name); chmod 755 ($dir | path join bin $name) }
	do $shim ssh 'd=$(dirname "$0")/..; while [ "$1" = -o ]; do echo "$2" >>"$d/ssh.opts"; shift 2; done; shift; if [ "$MODE" = ssh255 ]; then case "$1" in *owner*) echo "ssh: connect timed out" >&2; exit 255;; esac; fi; exec bash -c "$1"'
	do $shim sudo 'exec "$@"'
	do $shim sha256sum 'exec shasum -a 256 "$@"'
	do $shim systemctl 'd=$(dirname "$0")/..; echo "$*" >>"$d/systemctl.log"; case "$1" in cat) cat "$d/unitcat" 2>/dev/null; exit 0;; esac; n=$(grep -c "^restart" "$d/systemctl.log"); if [ "$MODE" = stuckfail ] && [ "$n" -ge 2 ]; then exit 1; fi; [ -e "$KUBELET_LIVE" ] && cp "$KUBELET_LIVE" "$d/running"; true'
	do $shim tee 'if [ "$MODE" = fulldisk ]; then head -c 12 >"$1"; exit 1; fi; if [ "$MODE" = shorttee ]; then head -c 12 >"$1"; exit 0; fi; exec /usr/bin/tee "$@"'
	do $shim touch 'd=$(dirname "$0")/..; echo "$*" >>"$d/touch.log"; exec /usr/bin/touch "$@"'
	do $shim mkdir 'd=$(dirname "$0")/..; if [ "$MODE" = nomkdir ] && [ "$1" = -p ]; then echo "mkdir: Permission denied" >&2; exit 1; fi; exec /bin/mkdir "$@"'
	do $shim timeout 'd=$(dirname "$0")/..; echo "$*" >>"$d/timeout.log"; shift; exec "$@"'
	do $shim df '[ "$DF_PCT" = -1 ] && exit 0; case "$*" in *-Pi*) p=$DFI_PCT;; *containerd*) p=$DF_IMG_PCT;; *) p=$DF_PCT;; esac; echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 100 $p 100 ${p}% /"'
	do $shim kubectl 'd=$(dirname "$0")/..; echo "$*" >>"$d/kubectl.log"; case "$*" in *--raw*) n=$(cat "$d/kcount" 2>/dev/null || echo 0); if [ "$MODE" = flaky ] && [ "$n" -lt 1 ]; then echo $((n+1)) >"$d/kcount"; exit 1; fi; case "$MODE" in noapi) exit 1;; empty) exit 0;; esac; if [ "$MODE" != stuck ] && [ "$MODE" != stuckfail ] && [ -e "$d/running" ] && cmp -s "$d/running" "$d/desired.yaml"; then cat "$d/configz.new"; else cat "$d/configz.old"; fi;; *) echo node1;; esac'
	"" | save --raw ($dir | path join systemctl.log)
	let img = if $df_img == -2 { $df } else { $df_img }
	# An error out of apply-kubelet (the lock is released first) is code 99 with its message.
	let r = (with-env {PATH: $"($dir | path join bin):($env.PATH | str join ':')", KUBECTL: ($dir | path join bin kubectl), MODE: $mode, KUBELET_LIVE: $live, DF_PCT: $df, DF_IMG_PCT: $img, DFI_PCT: $dfi} {
		try { apply-kubelet $k --check=$check --node fake --root $root --polls 2 --pause 0sec } catch {|e| {code: 99, msg: $e.msg} }
	})
	let read = {|f| if ($f | path exists) { open --raw $f } else { null } }
	let trim = {|t| if $t == null { null } else { $t | str trim } }
	let out = {
		code: $r.code
		msg: ($r | get -o msg | default "")
		live: (do $read $live)
		pending: (do $trim (do $read $"($live).pending"))
		prev: (do $read $"($live).prev")
		leftover: (($"($live).new" | path exists))
		lock: ($"($live).lock" | path exists)
		restarts: (open --raw ($dir | path join systemctl.log) | lines | where {|l| $l starts-with "restart"} | length)
		timeouts: (do $read ($dir | path join timeout.log) | default "")
		touches: ((do $read ($dir | path join touch.log) | default "") | lines | where {|l| $l != ""} | length)
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
	print "test a configz that cannot be read (failed request, empty answer) costs no restart when the file differs: read first, nothing changed..."
	for mode in [noapi empty] {
		let r = (scenario $mode {live: "old: file\n"})
		assert equal [$r.code $r.live $r.restarts $r.pending $r.prev $r.leftover] [1 "old: file\n" 0 null null false] $mode
		assert str contains $r.kubectl "--raw"
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

def test_a_rerun_with_the_marker_and_a_dead_kubelet_rolls_back [] {
	print "test a rerun that finds the marker with k3s down (configz unreadable) rolls back instead of returning..."
	let r = (scenario noapi {live: (desired), pending: "had\n", prev: "good: file\n"})
	assert equal [$r.code $r.live $r.restarts] [1 "good: file\n" 1]
	# The kubelet still does not answer after the rollback: nothing is settled, the marker and backup stay.
	assert equal [$r.pending $r.prev] ["had" "good: file\n"]
	let none = (scenario empty {live: (desired), pending: "none\n"})
	assert equal [$none.code $none.live $none.restarts $none.pending] [1 null 1 "none"]
}

def test_the_marker_is_found_by_its_existence_and_read_only_to_roll_back [] {
	print "test an empty or unknown marker still counts as pending, and a rollback it cannot read stops with everything kept..."
	for text in ["" "weird\n"] {
		let r = (scenario stuck {live: (desired), pending: $text, prev: "good: file\n"})
		assert equal [$r.code $r.live $r.prev $r.restarts] [1 (desired) "good: file\n" 0] $"marker ($text | to json)"
		assert equal ($r.pending == null) false $"the marker is kept ($text | to json)"
	}
}

def test_without_the_marker_nothing_is_rolled_back [] {
	print "test with the same file and no marker the run only restarts, and never rolls back (the marker is what says an apply was ours)..."
	let r = (scenario stuck {live: (desired), prev: "good: file\n"})
	assert equal [$r.code $r.live $r.prev $r.restarts] [1 (desired) "good: file\n" 1]
}

def test_a_short_write_that_exits_zero_is_caught_by_the_checksum [] {
	print "test a tee that writes short and exits 0 is caught by the sha256: the live file stays, nothing left behind..."
	let r = (scenario shorttee {live: "old: file\n"})
	assert equal [$r.code $r.live $r.leftover $r.pending $r.prev $r.restarts] [1 "old: file\n" false null null 0]
}

def test_a_flaky_first_read_is_retried_before_anything_is_restarted [] {
	print "test a first configz read that fails is retried, and only the second read, which differs, restarts k3s..."
	let r = (scenario flaky {live: (desired), running: "old: running\n"})
	assert equal [$r.code $r.restarts] [0 1]
}

def test_one_apply_at_a_time_and_no_second_kubelet_arg [] {
	print "test a held lock refuses, another file with kubelet-arg refuses, and a finished apply leaves no lock..."
	let held = (scenario ok {live: "old: file\n"} --locked)
	assert equal [$held.code $held.live $held.restarts $held.lock] [1 "old: file\n" 0 true]
	let other = (scenario ok {live: "old: file\n"} --other "kubelet-arg:\n  - \"x=1\"\n")
	assert equal [$other.code $other.live $other.restarts] [1 "old: file\n" 0]
	let done = (scenario ok {live: "old: file\n"})
	assert equal [$done.code $done.lock] [0 false]
	let failed = (scenario stuck {live: "old: file\n"})
	assert equal $failed.lock false
}

def test_a_disk_already_past_the_eviction_line_is_not_restarted_into [] {
	print "test a disk past the new eviction line refuses before any write, and past only the image GC line goes on..."
	let full = (scenario ok {live: "old: file\n"} --df 96)
	assert equal [$full.code $full.live $full.restarts $full.pending] [1 "old: file\n" 0 null]
	let gc = (scenario ok {live: "old: file\n"} --df 85)
	assert equal [$gc.code $gc.live $gc.restarts] [0 (desired) 1]
}

def test_the_restart_is_under_a_timeout_and_the_lock_is_released_on_an_error [] {
	print "test k3s is restarted under timeout 180, and an error out of an apply (a disk it cannot read) still releases the lock..."
	let r = (scenario ok {live: "old: file\n"})
	assert str contains $r.timeouts "180 systemctl restart k3s"
	let broken = (scenario ok {live: "old: file\n"} --df -1)
	assert equal [$broken.code $broken.lock $broken.live $broken.restarts] [99 false "old: file\n" 0]
	assert str contains $broken.msg "cannot read the use of"
}

def test_the_use_of_the_image_disk_and_the_inodes_count [] {
	print "test the image filesystem alone past the eviction line refuses, and so do the inodes..."
	let img = (scenario ok {live: "old: file\n"} --df 40 --df-img 96)
	assert equal [$img.code $img.live $img.restarts] [1 "old: file\n" 0]
	let ino = (scenario ok {live: "old: file\n"} --dfi 96)
	assert equal [$ino.code $ino.live $ino.restarts] [1 "old: file\n" 0]
}

def test_other_places_that_set_kubelet_arg_refuse [] {
	print "test a second drop-in in config.yaml.d, and the k3s unit itself, refuse..."
	let dropin = (scenario ok {live: "old: file\n"} --dropin "kubelet-arg:\n  - \"y=2\"\n")
	assert equal [$dropin.code $dropin.live $dropin.restarts] [1 "old: file\n" 0]
	let unit = (scenario ok {live: "old: file\n"} --unit "ExecStart=/usr/local/bin/k3s server --kubelet-arg=x=1\n")
	assert equal [$unit.code $unit.live $unit.restarts] [1 "old: file\n" 0]
}

def test_a_lock_from_before_a_reboot_is_taken_over_and_an_ssh_failure_is_not_a_held_lock [] {
	print "test a lock holding another boot id is taken over, and a lost ssh is reported as one, not as a held lock..."
	let stale = (scenario ok {live: "old: file\n"} --stale "some-other-boot-id")
	assert equal [$stale.code $stale.live $stale.lock] [0 (desired) false]
	let lost = (scenario ssh255 {live: "old: file\n"})
	assert equal $lost.code 99
	assert str contains $lost.msg "ssh failed"
}

def test_values_are_vetted_before_anything_runs [] {
	print "test apply-kubelet vets the values against #Kubelet first: a bad one errors before a single call..."
	let bad = ((valid) | update maxPods 5)
	let msg = (with-env {KUBECTL: "x"} { try { apply-kubelet $bad --node fake --root /nonexistent; "accepted" } catch {|e| $e.msg } })
	assert str contains $msg "not what #Kubelet allows"
}

def test_memory_already_under_the_eviction_margin_refuses [] {
	print "test a node with under twice the memory threshold available is not restarted into eviction..."
	let low = (scenario ok {live: "old: file\n"} --mem 150)
	assert equal [$low.code $low.live $low.restarts] [1 "old: file\n" 0]
	let ok = (scenario ok {live: "old: file\n"} --mem 200)
	assert equal [$ok.code $ok.restarts] [0 1]
}

def test_the_lock_is_touched_at_every_poll_and_restart [] {
	print "test the lock is touched before every read and restart (its heartbeat), and an unusable config directory is told apart from a held lock..."
	let r = (scenario ok {live: "old: file\n"})
	# A read before the write, the restart, and a read after it.
	assert (($r.touches) >= 3) $"touches ($r.touches)"
	let nodir = (scenario nomkdir {live: "old: file\n"})
	assert equal $nodir.code 99
	assert str contains $nodir.msg "cannot create"
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
	# The target node's own configz by hostname, never the first node listed.
	assert (not ($r.kubectl | str contains "get --request-timeout=10s node")) "no node listing"
	assert str contains $r.kubectl $"/api/v1/nodes/((^hostname | str trim))/proxy/configz"
}
