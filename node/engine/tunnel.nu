# tunnel.nu: the way to the node's API. The node's k3s answers on its own 127.0.0.1; the Mac reaches
# it through an ssh tunnel of the release's own: a free local port, to the node's 127.0.0.1:<api.remotePort>,
# opened here with its pid recorded and closed on every way out, and a kubeconfig of the release's own
# that points at it. Nothing is shared with another release running at once (a second release closing
# a shared tunnel under the first was the failure this avoids), and a port that answers only counts
# while the ssh process that opened it lives. One login, as the user the app names, in BatchMode and
# never asked again: a failed login gets the Mac banned by the node's CrowdSec for hours, so a refusal
# fails the release with ssh's own message.

# Whether anything answers on the local port.
export def answers [port: int]: nothing -> bool {
	(^nc -z 127.0.0.1 $port | complete).exit_code == 0
}

# A local port nothing listens on now.
export def free-port []: nothing -> int {
	^python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])' | str trim | into int
}

def alive [pid: int]: nothing -> bool { (^kill -0 $pid | complete).exit_code == 0 }

# Opens the tunnel and answers its pid and the file ssh's messages go to.
def open-tunnel [api: record, port: int]: nothing -> record {
	if not ($api.ssh =~ '^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*$') { error make {msg: $"api.ssh is ($api.ssh): it must be user@host"} }
	let log = (mktemp -t node-tunnel.XXXXXX | str trim)
	let forward = $"($port):127.0.0.1:($api.remotePort)"
	let r = (^sh -c $"ssh -N -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L '($forward)' '($api.ssh)' >'($log)' 2>&1 & echo $!" | complete)
	if $r.exit_code != 0 { error make {msg: $"ssh did not start: ($r.stderr | str trim)"} }
	{pid: ($r.stdout | str trim | into int), log: $log}
}

# Waits for the tunnel to answer while its ssh lives; fails with ssh's message when it died instead.
def wait-open [api: record, port: int, t: record, --seconds: int = 20] {
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let up = (alive $t.pid)
		if $up and (answers $port) { return }
		if not $up { error make {msg: $"the ssh tunnel to ($api.ssh) closed: (open --raw $t.log | str trim)"} }
		if (date now) > $deadline { error make {msg: $"the ssh tunnel to ($api.ssh) did not answer on 127.0.0.1:($port) in ($seconds) s: (open --raw $t.log | str trim)"} }
		sleep 250ms
	}
}

def close-tunnel [t: record] {
	^kill $t.pid | complete | ignore
	rm -f $t.log
}

# `body` run with its own tunnel, given the local port: `{|port| ... }`.
export def with-tunnel [api: record, body: closure]: nothing -> any {
	let port = (free-port)
	let t = (open-tunnel $api $port)
	try {
		wait-open $api $port $t
		do $body $port
	} finally {
		close-tunnel $t
	}
}

# A kubeconfig of this release's own: the node's context, flattened, its server the release's tunnel.
export def kubeconfig [context: string, port: int]: nothing -> string {
	let r = (^kubectl config view --minify --flatten --context $context | complete)
	if $r.exit_code != 0 { error make {msg: $"kubectl config view --context ($context): ($r.stderr | str trim)"} }
	let file = (mktemp -t kubeconfig.XXXXXX | str trim)
	^chmod 600 $file
	$r.stdout | from yaml | update clusters {|c| $c.clusters | each {|x| $x | upsert cluster.server $"https://127.0.0.1:($port)" } } | to yaml | save -f $file
	$file
}
