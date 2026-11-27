#!/usr/bin/env nu
# The host files of a pronto node (README.md, "The node host"), rendered from a node's #Host values, and
# applied to the node or only checked against it:
#
#   nu node/host/host.nu render <host.json>                        # the files as JSON: path, mode, text
#   nu node/host/host.nu apply <host.json> [--check] [--node user@host]
#
# <host.json> is the node's #Host exported (`cue export -e host --out json`). Without --node it works on this
# machine (as the node itself would), with it over one ssh each way and sudo, never retried: a failed login
# gets the Mac banned by the node's CrowdSec. --check changes nothing and exits 1 on any drift.
# --root <dir> puts every path under it (for the tests).

const here = path self | path dirname

const gc_script = "/usr/local/lib/pronto/docker-gc.sh"
const gc_env = "/etc/pronto/docker-gc.env"
const gc_service = "/etc/systemd/system/pronto-docker-gc.service"
const gc_timer = "/etc/systemd/system/pronto-docker-gc.timer"
const gc_unit = "pronto-docker-gc.timer"

# One text file's body, ending in one newline.
def lines [text: string]: nothing -> string { ($text | str trim --right --char "\n") + "\n" }

# The files the host holds, from its #Host values: [{path, mode, text}].
export def render [host: record]: nothing -> list<record> {
	let gc = $host.dockerGC
	let head = "# pronto-plugins node/host (docker cleanup): Docker's disk kept bounded."
	[
		{path: $gc_script, mode: "755", text: (lines (open --raw ($here | path join docker-gc.sh)))}
		{path: $gc_env, mode: "644", text: (lines ([
			"# pronto-plugins node/host (docker cleanup): what docker-gc.sh reads, from the node's #Host dockerGC."
			$"PATTERN='($gc.refPattern)'"
			$"MIN_AGE_HOURS=($gc.minAgeHours)"
			$"BUILD_CACHE_GB=($gc.buildCacheGB)"
			$"CAP_GB=($gc.capGB)"
		] | str join "\n"))}
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

# Runs a shell script on the node (ssh, sudo for root) or here. $stdin, when given, is its standard input.
def sh [node: string, script: string, stdin?: string]: nothing -> record {
	let run = if $node == "" {
		if $stdin == null { do { ^bash -c $script } | complete } else { $stdin | do { ^bash -c $script } | complete }
	} else {
		let remote = $"sudo bash -c ($script | to json)"
		if $stdin == null { do { ^ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $node $remote } | complete } else { $stdin | do { ^ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $node $remote } | complete }
	}
	$run
}

def must [r: record, what: string]: nothing -> string {
	if $r.exit_code != 0 { error make {msg: $"node-host: ($what) failed: ($r.stderr | str trim)"} }
	$r.stdout
}

# Sets what drifted, or with $check only says; returns the drift said.
export def apply [host: record, --check, --node: string = "", --root: string = ""]: nothing -> list<string> {
	mut drift = []
	mut changed = false
	for f in (render $host) {
		let path = $root + $f.path
		# Absent reads as empty; a failed ssh or sudo is an error, never "absent".
		let now = (must (sh $node $"if [ -e '($path)' ]; then cat '($path)'; fi") $"reading ($path)")
		if $now == $f.text { continue }
		$drift = ($drift | append $"($path) differs")
		print $"drift: ($path) differs"
		if not $check {
			# Whole beside the file, then renamed over it: a full disk leaves the old file.
			let dir = ($path | path dirname)
			let tmp = $"($path).new"
			must (sh $node $"mkdir -p '($dir)' && cat > '($tmp)' && chmod ($f.mode) '($tmp)' && mv -f '($tmp)' '($path)' || { rm -f '($tmp)'; exit 1; }" $f.text) $"writing ($path)" | ignore
			print $"wrote ($path)"
			$changed = true
		}
	}
	if $changed { must (sh $node "systemctl daemon-reload") "systemctl daemon-reload" | ignore }
	# The timer starts at boot and is running now, and its job's last run did not fail (setting the timer
	# again does not clear that: the operator reads journalctl -u).
	let service = ($gc_unit | str replace ".timer" ".service")
	if (sh $node $"systemctl is-failed --quiet ($service)").exit_code == 0 {
		$drift = ($drift | append $"($service) failed its last run")
		print $"drift: ($service) failed its last run"
	}
	let on = ((sh $node $"systemctl is-enabled --quiet ($gc_unit) && systemctl is-active --quiet ($gc_unit)").exit_code == 0)
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

def "main apply" [host: path, --check, --node: string = "", --root: string = ""] {
	let drift = (apply (open $host) --check=$check --node $node --root $root)
	if ($drift | is-empty) { print "node-host: as #Host says"; return }
	if $check { exit 1 }
	print "node-host: set as #Host says"
}

def main [] {
	print "usage: host.nu render <host.json> | apply <host.json> [--check] [--node user@host]"
	exit 2
}
