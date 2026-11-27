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
	# The pattern is run by bash on the node (docker-gc.sh): an invalid ERE is an error there (status 2), which the cleanup loop
	# would read as "no tag matches" and keep every image. Bash on this machine is the same engine's check.
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
	[
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
			must (sh $node $"mkdir -p '($dir)' && rm -f '($tmp)' && cat > '($tmp)' && chmod ($f.mode) '($tmp)' && mv -f '($tmp)' '($path)' || { rm -f '($tmp)'; exit 1; }" $f.text) $"writing ($path)" | ignore
			print $"wrote ($path)"
			$changed = true
		}
	}
	# systemd runs the units it last loaded: files that match on disk are not the units running. A run that stopped between
	# writing a unit and reloading leaves every file matching, so a pending reload is asked of systemd itself, for the
	# service and the timer, and is drift (--check) or is done (apply) whatever this run wrote.
	mut reload_pending = false
	for unit in [($gc_unit | str replace ".timer" ".service") $gc_unit] {
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
	# The timer starts at boot and is running now, and its job's last run did not fail (setting the timer
	# again does not clear that: the operator reads journalctl -u).
	let service = ($gc_unit | str replace ".timer" ".service")
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
	let state = (sh $node $"systemctl is-enabled --quiet ($gc_unit) && systemctl is-active --quiet ($gc_unit)")
	if $state.exit_code == 255 { error make {msg: $"node-host: asking whether ($gc_unit) runs: ($state.stderr | str trim)"} }
	let on = ($state.exit_code == 0)
	if not $on {
		$drift = ($drift | append $"($gc_unit) is not enabled and active")
		print $"drift: ($gc_unit) is not enabled and active"
		if not $check {
			must (sh $node $"systemctl enable --now ($gc_unit)") $"enabling ($gc_unit)" | ignore
			print $"enabled ($gc_unit)"
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
	# A failed job that still fails (after being run again when files were written) is not set right by writing: exit non-zero,
	# so the run is not read as clean. "set" is said only when something was written.
	if (failed-service $drift) {
		let wrote = ($drift | any {|d| not (($d | str ends-with "failed its last run") or ($d | str ends-with "its last run failed")) })
		print --stderr (if $wrote { "node-host: set, but the job's last run still fails: read journalctl -u pronto-docker-gc.service" } else { "node-host: nothing to write, but the job's last run failed: read journalctl -u pronto-docker-gc.service" })
		exit 1
	}
	print "node-host: set as #Host says"
}

def main [] {
	print "usage: host.nu render <host.json> | apply <host.json> [--check] [--node user@host]"
	exit 2
}
