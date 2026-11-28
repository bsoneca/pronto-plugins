#!/usr/bin/env nu
# The host files of a pronto node (README.md, "The node host"), rendered from a node's #Host values, and
# applied to the node or only checked against it:
#
#   nu node/host/host.nu render <host.json>                        # the files as JSON: path, mode, text
#   nu node/host/host.nu apply <host.json> [--check] [--node user@host]
#
# <host.json> is the node's #Host exported (`cue export -e host --out json`). Without --node it works on this
# machine (as the node itself would), with it over ssh and sudo: each read, write and systemctl call is an ssh login of
# its own (BatchMode, with a connect timeout), none retried, because a failed login gets the Mac banned by the node's
# CrowdSec. --check changes nothing and exits 1 on any drift.
# --root <dir> puts every path under it (for the tests; then the owner compared is the user's alone, as a group may come
# from the folder). Needs `cue` on the PATH, which vets the values against #Host before anything is written.

const here = path self | path dirname

const gc_script = "/usr/local/lib/pronto/docker-gc.sh"
const gc_env = "/etc/pronto/docker-gc.env"
const gc_service = "/etc/systemd/system/pronto-docker-gc.service"
const gc_timer = "/etc/systemd/system/pronto-docker-gc.timer"
const gc_unit = "pronto-docker-gc.timer"

const heal_script = "/usr/local/lib/pronto/dapr-heal.sh"
const heal_env = "/etc/pronto/dapr-heal.env"
const heal_service = "/etc/systemd/system/pronto-dapr-heal.service"
const heal_timer = "/etc/systemd/system/pronto-dapr-heal.timer"
const heal_unit = "pronto-dapr-heal.timer"
const heal_service_unit = "pronto-dapr-heal.service"

const critical_note = "not set by apply"

const watch_script = "/usr/local/lib/pronto/disk-watch.sh"
const watch_env = "/etc/pronto/disk-watch.env"
const watch_service = "/etc/systemd/system/pronto-disk-watch.service"
const watch_timer = "/etc/systemd/system/pronto-disk-watch.timer"
const watch_unit = "pronto-disk-watch.timer"
const watch_service_unit = "pronto-disk-watch.service"

# The command each supported launcher runs as: fixed, absolute, root's (a value of the host JSON is never a path).
def heal-kubectl [launcher: string]: nothing -> string {
	match $launcher {
		"k3s kubectl" => "/usr/local/bin/k3s kubectl"
		"kubectl" => "/usr/local/bin/kubectl"
		_ => { error make {msg: $"node-host: daprHeal.kubectl ($launcher) is not a supported launcher"} }
	}
}

# The timers a host holds: the cleanup's always, the Dapr sidecar's when #Host says daprHeal.
def timers [host: record]: nothing -> list<string> {
	[$gc_unit] ++ (if ($host.daprHeal? != null) { [$heal_unit] } else { [] }) ++ (if ($host.diskWatch? != null) { [$watch_unit] } else { [] })
}

# One text file's body, ending in one newline.
def lines [text: string]: nothing -> string { ($text | str trim --right --char "\n") + "\n" }

# The values must be what #Host allows: they are written into a script's settings and a unit file, so a hand-edited
# json must not carry a quote or a newline into them. Only the section this module sets is vetted (a repository's host
# holds others of its own); the schema is the one beside this file.
export def vet [host: record] {
	let f = (mktemp --tmpdir node-host-vet-XXXXXX.json)
	$host.dockerGC | to json | save --force --raw $f
	let r = (try { do { ^cue vet -c ($here | path join schema host.cue) $f -d '#DockerGC' } | complete } catch {
		rm -f $f
		error make {msg: "node-host: cue is required (it vets the values against #Host) and could not be run"}
	})
	rm -f $f
	if $r.exit_code != 0 { error make {msg: $"node-host: the host's dockerGC is not what #Host allows: ($r.stderr | str trim)"} }
	if ($host.daprHeal? != null) {
		let h = (mktemp --tmpdir node-host-vet-XXXXXX.json)
		$host.daprHeal | to json | save --force --raw $h
		let v = (try { do { ^cue vet -c ($here | path join schema host.cue) $h -d '#DaprHeal' } | complete } catch {
			rm -f $h
			error make {msg: "node-host: cue is required (it vets the values against #Host) and could not be run"}
		})
		rm -f $h
		if $v.exit_code != 0 { error make {msg: $"node-host: the host's daprHeal is not what #Host allows: ($v.stderr | str trim)"} }
	}
	# The alarm must ring before the kubelet evicts: #Host holds that across the two sections, so both are vetted whole when both are set.
	if ($host.kubelet? != null) and ($host.diskWatch? != null) {
		let both = (mktemp --tmpdir node-host-vet-XXXXXX.json)
		{dockerGC: $host.dockerGC, kubelet: $host.kubelet, diskWatch: $host.diskWatch} | to json | save --force --raw $both
		let b = (try { do { ^cue vet -c ($here | path join schema host.cue) $both -d '#Host' } | complete } catch {
			rm -f $both
			error make {msg: "node-host: cue is required (it vets the values against #Host) and could not be run"}
		})
		rm -f $both
		if $b.exit_code != 0 { error make {msg: $"node-host: the host's kubelet and diskWatch are not what #Host allows together: ($b.stderr | str trim)"} }
	}
	for sec in [[key def]; ["diskWatch" "#DiskWatch"] ["critical" "#Critical"]] {
		let v = ($host | get --optional $sec.key)
		if $v == null { continue }
		let f = (mktemp --tmpdir node-host-vet-XXXXXX.json)
		$v | to json | save --force --raw $f
		let r = (try { do { ^cue vet -c ($here | path join schema host.cue) $f -d $sec.def } | complete } catch {
			rm -f $f
			error make {msg: "node-host: cue is required (it vets the values against #Host) and could not be run"}
		})
		rm -f $f
		if $r.exit_code != 0 { error make {msg: $"node-host: the host's ($sec.key) is not what #Host allows: ($r.stderr | str trim)"} }
	}
	# The pattern is run by bash on the node (docker-gc.sh): an invalid ERE is status 2 there, which the cleanup loop would
	# read as "no tag matches" and keep every image. It is checked here by the operator's bash, not the node's (the node's
	# script checks it again before its loop and fails the unit); the two differ only in the regex library's version.
	let ere = (do { ^bash -c '[[ "" =~ $1 ]]; [ $? -ne 2 ]' _ $host.dockerGC.refPattern } | complete)
	if $ere.exit_code != 0 { error make {msg: $"node-host: the host's dockerGC refPattern is not a valid bash ERE: ($host.dockerGC.refPattern)"} }
}

# The files the host holds, from its #Host values: [{path, mode, text}], in the order they are written: the settings
# before the script that reads them, so a run that stops between the two leaves a pair the old script (which ignores
# the settings) and the new one both work with.
export def render [host: record]: nothing -> list<record> {
	vet $host
	let gc = $host.dockerGC
	let head = "# pronto-plugins node/host (docker cleanup): Docker's disk kept bounded."
	let gc_files = [
		{path: $gc_env, mode: "644", text: (lines ([
			"# pronto-plugins node/host (docker cleanup): what docker-gc.sh reads, from the node's #Host dockerGC."
			$"PATTERN='($gc.refPattern)'"
			$"MIN_AGE_HOURS=($gc.minAgeHours)"
			$"BUILD_CACHE_GB=($gc.buildCacheGB)"
			$"CAP_GB=($gc.capGB)"
		] | str join "\n"))}
		{path: $gc_script, mode: "755", text: (lines (open --raw ($here | path join docker-gc.sh)))}
		{path: $gc_service, mode: "644", text: (lines ([
			$head "[Unit]" "Description=Remove the node's old Docker images and build cache" "After=docker.service" ""
			"[Service]" "Type=oneshot" $"ExecStart=/bin/bash ($gc_script)" "Nice=19" "IOSchedulingClass=idle"
		] | str join "\n"))}
		{path: $gc_timer, mode: "644", text: (lines ([
			$head "[Unit]" "Description=Run pronto-docker-gc.service" ""
			"[Timer]" $"OnCalendar=($gc.onCalendar)" "Persistent=true" "" "[Install]" "WantedBy=timers.target"
		] | str join "\n"))}
	]
	let watch_files = if ($host.diskWatch? == null) { [] } else {
		let w = $host.diskWatch
		let watch_head = "# pronto-plugins node/host (disk watch): a filesystem filling is posted to the operator's channel."
		[
			# 600: the URL is the channel's key.
			{path: $watch_env, mode: "600", text: (lines ([
				"# pronto-plugins node/host (disk watch): what disk-watch.sh reads, from the node's #Host diskWatch."
				$"MOUNTS='($w.mounts | str join ' ')'"
				$"THRESHOLD_PERCENT=($w.thresholdPercent)"
				$"RENOTIFY_MINUTES=($w.renotifyMinutes)"
				$"NOTIFY_URL='($w.notifyUrl)'"
			] | str join "\n"))}
			{path: $watch_script, mode: "755", text: (lines (open --raw ($here | path join disk-watch.sh)))}
			{path: $watch_service, mode: "644", text: (lines ([
				$watch_head "[Unit]" "Description=Post to the operator when a filesystem of the node is filling" "After=local-fs.target network-online.target" "Wants=network-online.target" ""
				# Not root: it reads df and posts. The settings come from the manager (EnvironmentFile is read as root), the marks live in StateDirectory.
				"[Service]" "Type=oneshot" $"EnvironmentFile=($watch_env)" $"ExecStart=/bin/bash ($watch_script)" "Nice=19" "TimeoutStartSec=120"
				"DynamicUser=yes" "StateDirectory=pronto/disk-watch" "NoNewPrivileges=yes" "ProtectSystem=strict" "ProtectHome=yes" "PrivateTmp=yes" "PrivateDevices=yes"
				"CapabilityBoundingSet=" "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" "ProtectKernelTunables=yes" "ProtectControlGroups=yes"
			] | str join "\n"))}
			{path: $watch_timer, mode: "644", text: (lines ([
				$watch_head "[Unit]" "Description=Run pronto-disk-watch.service" ""
				"[Timer]" $"OnCalendar=($w.onCalendar)" "" "[Install]" "WantedBy=timers.target"
			] | str join "\n"))}
		]
	}
	if ($host.daprHeal? == null) { return ($gc_files ++ $watch_files) }
	let heal = $host.daprHeal
	let heal_head = "# pronto-plugins node/host (Dapr sidecar): a pod that asks for one and runs none is rolled."
	$gc_files ++ [
		{path: $heal_env, mode: "644", text: (lines ([
			"# pronto-plugins node/host (Dapr sidecar): what dapr-heal.sh reads, from the node's #Host daprHeal."
			$"KUBECTL='(heal-kubectl $heal.kubectl)'"
			$"NAMESPACES='($heal.namespaces | str join ' ')'"
			$"GRACE_SECONDS=($heal.graceSeconds)"
			$"COOLDOWN_MINUTES=($heal.cooldownMinutes)"
		] | str join "\n"))}
		{path: $heal_script, mode: "755", text: (lines (open --raw ($here | path join dapr-heal.sh)))}
		{path: $heal_service, mode: "644", text: (lines ([
			$heal_head "[Unit]" "Description=Roll the workloads whose pods run no Dapr sidecar" "After=k3s.service" ""
			"[Service]" "Type=oneshot" $"ExecStart=/bin/bash ($heal_script)" "Nice=19"
		] | str join "\n"))}
		{path: $heal_timer, mode: "644", text: (lines ([
			$heal_head "[Unit]" "Description=Run pronto-dapr-heal.service" ""
			"[Timer]" $"OnCalendar=($heal.onCalendar)" "Persistent=true" "" "[Install]" "WantedBy=timers.target"
		] | str join "\n"))}
	] ++ $watch_files
}

# Runs a shell script on the node (ssh, as root through sudo unless --plain) or here. $stdin, when given, is its
# standard input. The script reaches the node's shell single-quoted, so the login shell expands nothing in it.
export def sh [node: string, script: string, stdin?: string, --plain]: nothing -> record {
	if $node == "" {
		if $stdin == null { return (do { ^bash -c $script } | complete) }
		return ($stdin | do { ^bash -c $script } | complete)
	}
	let quoted = ($script | str replace --all "'" "'\\''")
	let remote = if $plain { $script } else { $"sudo bash -c '($quoted)'" }
	let opts = [-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2]
	if $stdin == null { do { ^ssh ...$opts $node $remote } | complete } else { $stdin | do { ^ssh ...$opts $node $remote } | complete }
}

export def must [r: record, what: string]: nothing -> string {
	if $r.exit_code != 0 { error make {msg: $"node-host: ($what) failed: ($r.stderr | str trim)"} }
	$r.stdout
}

# Sets what drifted, or with $check only says; returns the drift said.
export def apply [host: record, --check, --node: string = "", --root: string = ""]: nothing -> list<string> {
	mut drift = []
	mut changed = false
	# Who the files belong to: root on the node (sudo), whoever runs it for --root, as the tests do.
	let owner = (must (sh $node "echo $(id -un):$(id -gn)") "asking who the files belong to" | str trim)
	for f in (render $host) {
		let path = $root + $f.path
		# Absent reads as empty; a failed ssh or sudo is an error, never "absent". The mode and owner are the file's too: a
		# 0666 settings file, or one a user owns, is drift (the script sources it as root).
		let now = (must (sh $node $"if [ -e '($path)' ]; then cat '($path)'; fi") $"reading ($path)")
		let meta = (must (sh $node $"if [ -e '($path)' ]; then stat -c '%a %U:%G' '($path)' 2>/dev/null || stat -f '%Lp %Su:%Sg' '($path)'; fi") $"reading the mode of ($path)" | str trim)
		# Under --root (the tests) the group may come from the folder: the user alone is compared.
		let have = if $root == "" { $meta } else { $meta | split row ":" | first }
		let want = if $root == "" { $"($f.mode) ($owner)" } else { $"($f.mode) ($owner | split row ':' | first)" }
		if $now == $f.text and $have == $want { continue }
		let what = if $now == $f.text { $"has mode and owner ($meta), not ($f.mode) ($owner)" } else { "differs" }
		$drift = ($drift | append $"($path) ($what)")
		print $"drift: ($path) ($what)"
		if not $check {
			# Whole beside the file, then renamed over it: a full disk leaves the old file.
			let dir = ($path | path dirname)
			let tmp = $"($path).new"
			must (sh $node $"mkdir -p '($dir)' && rm -f '($tmp)' && \(umask 077 && cat > '($tmp)'\) && chmod ($f.mode) '($tmp)' && mv -f '($tmp)' '($path)' || { rm -f '($tmp)'; exit 1; }" $f.text) $"writing ($path)" | ignore
			print $"wrote ($path)"
			$changed = true
		}
	}
	# A host that no longer says daprHeal (or never did) holds none of its files: a repair timer left from when it did would go on rolling
	# workloads of namespaces nobody lists any more. It is drift; apply stops and disables it, removes the four files and (below) reloads systemd.
	# The same for diskWatch (its timer would go on posting to a channel nobody lists any more).
	for sec in [
		{key: "daprHeal", timer: $heal_timer, service: $heal_service, script: $heal_script, env: $heal_env, unit: $heal_unit, service_unit: $heal_service_unit}
		{key: "diskWatch", timer: $watch_timer, service: $watch_service, script: $watch_script, env: $watch_env, unit: $watch_unit, service_unit: $watch_service_unit}
	] {
	if ($host | get --optional $sec.key) == null {
		let left = ([$sec.timer $sec.service $sec.script $sec.env] | where {|f|
			let path = $root + $f
			(must (sh $node $"if [ -e '($path)' ]; then echo yes; fi") $"looking for ($path)" | str trim) == "yes"
		})
		if ($left | is-not-empty) {
			for f in $left {
				$drift = ($drift | append $"($root + $f) is installed but the host has no ($sec.key)")
				print $"drift: ($root + $f) is installed but the host has no ($sec.key)"
			}
			if not $check {
				# The timer is disabled and stopped and its service (a sweep that may be running) stopped; the files are removed only once systemd says
				# so: both inactive, the timer disabled or absent. A failed stop, or a state that cannot be read, is an error with the files kept, so the
				# next apply finds the drift again.
				let off = (sh $node $"systemctl disable --now ($sec.unit)")
				if $off.exit_code == 255 { error make {msg: $"node-host: disabling ($sec.unit): ($off.stderr | str trim)"} }
				let stop = (sh $node $"systemctl stop ($sec.service_unit)")
				if $stop.exit_code == 255 { error make {msg: $"node-host: stopping ($sec.service_unit): ($stop.stderr | str trim)"} }
				for unit in [$sec.unit $sec.service_unit] {
					let active = (sh $node $"systemctl is-active ($unit)")
					if $active.exit_code == 255 { error make {msg: $"node-host: asking whether ($unit) is active: ($active.stderr | str trim)"} }
					let a = ($active.stdout | str trim)
					if $a in ["active" "activating" "reloading" "deactivating"] { error make {msg: $"node-host: ($unit) is still ($a) after being stopped: its files are kept"} }
					if $a not-in ["inactive" "failed" "unknown"] { error make {msg: $"node-host: the state of ($unit) is unreadable \(($a), ($active.stderr | str trim)\): its files are kept"} }
				}
				let enabled = (sh $node $"systemctl is-enabled ($sec.unit)")
				if $enabled.exit_code == 255 { error make {msg: $"node-host: asking whether ($sec.unit) is enabled: ($enabled.stderr | str trim)"} }
				let e = ($enabled.stdout | str trim)
				# Absent is a fact about the file, not systemd's wording (newer versions say not-found): with the timer's file already gone, no state
				# or `not-found` is what a unit that is not loaded gives.
				let timer_there = ((must (sh $node $"if [ -e '($root + $sec.timer)' ]; then echo yes; fi") $"looking for ($root + $sec.timer)" | str trim) == "yes")
				let absent = (not $timer_there and $e in ["" "not-found"])
				if not ($absent or $e in ["disabled" "masked" "masked-runtime"]) { error make {msg: $"node-host: ($sec.unit) is not disabled \(($e), ($enabled.stderr | str trim)\): its files are kept"} }
				for f in $left { must (sh $node $"rm -f '($root + $f)'") $"removing ($root + $f)" | ignore; print $"removed ($root + $f)" }
				$changed = true
			}
		}
	}
	}
	# systemd runs the units it last loaded: files that match on disk are not the units running. A run that stopped between
	# writing a unit and reloading leaves every file matching, so a pending reload is asked of systemd itself, for the
	# service and the timer, and is drift (--check) or is done (apply) whatever this run wrote.
	mut reload_pending = false
	for unit in ((timers $host) | each {|t| [($t | str replace ".timer" ".service") $t] } | flatten) {
		let q = (sh $node $"systemctl show -p NeedDaemonReload --value ($unit)")
		if $q.exit_code != 0 { error make {msg: $"node-host: asking whether ($unit) needs a daemon-reload: ($q.stderr | str trim)"} }
		if ($q.stdout | str trim) == "yes" {
			$reload_pending = true
			if not $changed {
				$drift = ($drift | append $"($unit) needs a daemon-reload")
				print $"drift: ($unit) needs a daemon-reload"
			}
		}
	}
	if not $check and ($changed or $reload_pending) { must (sh $node "systemctl daemon-reload") "systemctl daemon-reload" | ignore; print "systemctl daemon-reload" }
	# Each timer starts at boot and is running now, and its job's last run did not fail (setting the timer
	# again does not clear that: the operator reads journalctl -u).
	for timer in (timers $host) {
		let service = ($timer | str replace ".timer" ".service")
		# 255 is ssh's own failure, not an answer: a login that failed must not read as "not failed" or "not enabled".
		let failed = (sh $node $"systemctl is-failed --quiet ($service)")
		if $failed.exit_code == 255 { error make {msg: $"node-host: asking whether ($service) failed: ($failed.stderr | str trim)"} }
		if $failed.exit_code == 0 {
			print $"drift: ($service) failed its last run"
			if $changed {
				# The files it failed on are set right: run it again (a oneshot, under a timeout) and ask again, so a repair is not
				# reported as a failure.
				print $"running ($service) again"
				let started = (sh $node $"timeout 600 systemctl start ($service)")
				if $started.exit_code == 255 { error make {msg: $"node-host: running ($service) again: ($started.stderr | str trim)"} }
				if $started.exit_code == 124 {
					# Still running after 600 s: not repaired, and not failed either; it is drift and the run exits 1.
					print $"($service) is still running after 600 s"
					$drift = ($drift | append $"($service) is still running after 600 s: its last run failed")
				} else {
					let again = (sh $node $"systemctl is-failed --quiet ($service)")
					if $again.exit_code == 255 { error make {msg: $"node-host: asking whether ($service) failed again: ($again.stderr | str trim)"} }
					# 0 from start and not failed any more: repaired. Anything else (start's own failure, or still failed) still fails.
					if $started.exit_code == 0 and $again.exit_code != 0 {
						print $"($service) ran again and did not fail"
						$drift = ($drift | append $"($service) failed its last run and was run again")
					} else {
						$drift = ($drift | append $"($service) failed its last run")
					}
				}
			} else {
				$drift = ($drift | append $"($service) failed its last run")
			}
		}
		let state = (sh $node $"systemctl is-enabled --quiet ($timer) && systemctl is-active --quiet ($timer)")
		if $state.exit_code == 255 { error make {msg: $"node-host: asking whether ($timer) runs: ($state.stderr | str trim)"} }
		let on = ($state.exit_code == 0)
		if not $on {
			$drift = ($drift | append $"($timer) is not enabled and active")
			print $"drift: ($timer) is not enabled and active"
			if not $check {
				must (sh $node $"systemctl enable --now ($timer)") $"enabling ($timer)" | ignore
				print $"enabled ($timer)"
			}
		}
	}
	# The workloads the host says must outlive an eviction run under a system-*-critical class. Only read: the class is set by each
	# workload's own manifest, so apply cannot repair this and says so. An unreadable cluster is an error, never "no drift".
	if ($host.critical? != null) {
		let kubectl = $root + (heal-kubectl $host.critical.kubectl)
		for w in $host.critical.workloads {
			let what = $"($w.namespace)/($w.kind | str lowercase)/($w.name)"
			let got = (must (sh $node $"($kubectl) get ($w.kind | str lowercase) ($w.name) -n ($w.namespace) --ignore-not-found --request-timeout=20s -o jsonpath='{.metadata.name}/{.spec.template.spec.priorityClassName}'") $"reading ($what)" | str trim)
			let class = if $got == "" { null } else { $got | split row "/" | skip 1 | str join "/" }
			let bad = if $class == null { "does not exist" } else if ($class =~ '^system-(cluster|node)-critical$') { "" } else { $"runs under priority class '($class)', not system-cluster-critical or system-node-critical" }
			if $bad != "" {
				$drift = ($drift | append $"($what) ($bad) \(#Host critical; ($critical_note)\)")
				print $"drift: ($what) ($bad) \(#Host critical; ($critical_note)\)"
			}
		}
	}
	$drift
}

def "main render" [host: path] {
	render (open $host) | to json
}

# Whether the job's last run failed, which writing files does not clear (the operator reads journalctl -u).
export def failed-service [drift: list<string>]: nothing -> bool {
	$drift | any {|d| ($d | str ends-with "failed its last run") or ($d | str ends-with "its last run failed") }
}

def "main apply" [host: path, --check, --node: string = "", --root: string = ""] {
	let drift = (apply (open $host) --check=$check --node $node --root $root)
	if ($drift | is-empty) { print "node-host: as #Host says"; return }
	if $check { exit 1 }
	# A workload outside a system critical class is set by its own manifest, not by this: apply wrote what it could and says it is not clean.
	if ($drift | any {|d| $d | str ends-with $"($critical_note))" }) {
		print --stderr "node-host: a #Host critical workload is not at a system critical priority class: set it in the workload's own manifest"
		exit 1
	}
	# A failed job that still fails (after being run again when files were written) is not set right by writing: exit non-zero,
	# so the run is not read as clean. "set" is said only when something was written.
	if (failed-service $drift) {
		let wrote = ($drift | any {|d| not (($d | str ends-with "failed its last run") or ($d | str ends-with "its last run failed")) })
		print --stderr (if $wrote { "node-host: set, but the job's last run still fails: read journalctl -u on the failed job (pronto-docker-gc or pronto-dapr-heal)" } else { "node-host: nothing to write, but the job's last run failed: read journalctl -u on the failed job (pronto-docker-gc or pronto-dapr-heal)" })
		exit 1
	}
	print "node-host: set as #Host says"
}

def main [] {
	print "usage: host.nu render <host.json> | apply <host.json> [--check] [--node user@host]"
	exit 2
}
