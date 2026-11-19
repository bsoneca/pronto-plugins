# tunnel.nu: the way to the node's API. The node's k3s answers on its own 127.0.0.1; the Mac reaches
# it through one ssh tunnel (127.0.0.1:<api.port> -> the node's 127.0.0.1:<api.remotePort>), opened
# here when nothing answers on the port, with its pid recorded and closed on every way out. One login,
# as the user the app names, in BatchMode and never asked again: a failed login gets the Mac banned
# by the node's CrowdSec for hours, so a refusal fails the release with ssh's own message.

# Whether anything answers on the local port.
export def answers [port: int]: nothing -> bool {
	(^nc -z 127.0.0.1 $port | complete).exit_code == 0
}

# Opens the tunnel and answers its pid and the file ssh's messages go to.
def open-tunnel [api: record]: nothing -> record {
	let log = (mktemp -t node-tunnel.XXXXXX | str trim)
	let forward = $"($api.port):127.0.0.1:($api.remotePort)"
	let r = (^sh -c $"ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L '($forward)' '($api.ssh)' >'($log)' 2>&1 & echo $!" | complete)
	if $r.exit_code != 0 { error make {msg: $"ssh did not start: ($r.stderr | str trim)"} }
	{pid: ($r.stdout | str trim | into int), log: $log}
}

# Waits for the tunnel to answer; fails with ssh's message when it died instead.
def wait-open [api: record, t: record, --seconds: int = 20] {
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		if (answers $api.port) { return }
		if (^kill -0 $t.pid | complete).exit_code != 0 {
			error make {msg: $"the ssh tunnel to ($api.ssh) closed: (open --raw $t.log | str trim)"}
		}
		if (date now) > $deadline { error make {msg: $"the ssh tunnel to ($api.ssh) did not answer on 127.0.0.1:($api.port) in ($seconds) s: (open --raw $t.log | str trim)"} }
		sleep 250ms
	}
}

def close-tunnel [t: record] {
	^kill $t.pid | complete | ignore
	rm -f $t.log
}

# `body` run with the API reachable: over a tunnel already open (not ours to close), or one opened here.
export def with-tunnel [api: record, body: closure]: nothing -> any {
	if (answers $api.port) { return (do $body) }
	let t = (open-tunnel $api)
	try {
		wait-open $api $t
		do $body
	} finally {
		close-tunnel $t
	}
}
