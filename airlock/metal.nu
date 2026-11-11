# An airlock of an app's own on a metal cluster (pronto's envs.Metal), from the app's spec: its doors,
# their sinks and credentials, and who may call them (PRONTO-271: Studio's model doors, beside the LLM
# gateways). The objects are common/airlock.nu's, as the billing and identity brokers' airlocks are;
# only where they come from differs: a spec the app writes in CUE and exports, never written by hand.
#   bin/pronto-airlock metal --spec <file.json> [--ssh bruno@node] [--kubeconfig K]
#
# The spec (JSON):
#   {namespace, name, caller, from: [NetworkPolicy peers], partOf?,
#    doors: [{door, base, var?, scheme?, secret?: {name, key}, headers: [name | {name, hidden: true}],
#             timeoutMs?, sink?: {pod: {labels}, port}}]}
# A door whose sink is a pod in the airlock's namespace says so (`sink`): the airlock is let out to that
# pod's port alone, not to public HTTPS, and a NetworkPolicy of the airlock's own lets it into the pod
# (policies add up, so the sink's own is left as it is).
# Each credential is read from a Secret already on the node (`secret`), which this never writes: the
# service that owns the key (its metal.nu) put it there. The pod, its ledger and its wall are
# common/airlock.nu's airlock-objects; its door answers on 9998 to the `from` peers alone.

use ../common/airlock.nu [airlock-objects door_port]

const label = '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'

# The spec, checked: what a release would otherwise only find on the node.
export def check [spec: record]: nothing -> record {
	let bad = {|why: string| error make {msg: $"airlock spec: ($why)"} }
	for k in [namespace name caller] {
		if not (($spec | get -o $k | describe) == "string" and ($spec | get $k) =~ $label) { do $bad $"($k) is not a DNS label" }
	}
	let listed = {|v| ($v | describe) =~ '^(list|table)' }
	if not (do $listed $spec.from?) or ($spec.from | is-empty) { do $bad "from names no caller: a door no one may reach is no door" }
	if not (do $listed $spec.doors?) or ($spec.doors | is-empty) { do $bad "doors is empty" }
	if ($spec.doors | get door | uniq | length) != ($spec.doors | length) { do $bad "two doors share a name" }
	for d in $spec.doors {
		if not ($d.door =~ $label) { do $bad $"door ($d.door) is not a DNS label" }
		if not ($d.base =~ '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$') { do $bad $"door ($d.door): base is a scheme and a host, no path" }
		if ($d.var? | is-not-empty) and not ($d.var =~ '^[A-Z][A-Z0-9_]*$') { do $bad $"door ($d.door): var is an environment variable's name" }
		if ($d.var? | is-not-empty) and ($d.secret? | is-empty) { do $bad $"door ($d.door): name the Secret its credential is read from" }
		if ($d.var? | is-empty) and ($d.secret? | is-not-empty) { do $bad $"door ($d.door): a Secret with no var to read it into" }
		if ($d.sink? | is-not-empty) and not (($d.sink.pod? | describe) =~ '^record' and ($d.sink.pod | is-not-empty) and ($d.sink.port? | describe) == "int") {
			do $bad $"door ($d.door): sink is {pod: <its labels>, port}"
		}
		if ($d.timeoutMs? | is-not-empty) and not (($d.timeoutMs | describe) == "int" and $d.timeoutMs > 0 and $d.timeoutMs <= 600000 and $d.timeoutMs mod 1000 == 0) {
			do $bad $"door ($d.door): timeoutMs is whole seconds, at most 600000"
		}
	}
	$spec
}

# Every object the airlock is, as YAML documents.
export def manifests [spec: record]: nothing -> string {
	let s = (check $spec)
	let labels = {"app.kubernetes.io/name": $s.name, "app.kubernetes.io/part-of": ($s.partOf? | default $s.name)}
	let way = {|d| {to: [{podSelector: {matchLabels: $d.sink.pod}}], ports: [{protocol: "TCP", port: $d.sink.port}]} }
	let held = ($s.doors | each {|d|
		$d | reject -o sink | merge {headers: ($d.headers? | default []), scheme: ($d.scheme? | default "Bearer")}
		| merge (if ($d.sink? | is-empty) { {} } else { {egress: [(do $way $d)]} })
	})
	# Into each in-cluster sink from the airlock alone, on the sink's port.
	let admit = ($s.doors | where {|d| ($d.sink? | is-not-empty) } | each {|d| {
		apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy"
		metadata: {namespace: $s.namespace, labels: $labels, name: $"($s.name)-to-($d.door)"}
		spec: {
			podSelector: {matchLabels: $d.sink.pod}
			policyTypes: ["Ingress"]
			ingress: [{from: [{podSelector: {matchLabels: $labels}}], ports: [{protocol: "TCP", port: $d.sink.port}]}]
		}
	}})
	airlock-objects $s.namespace $s.name $labels $s.from $s.caller $held | append $admit | each { to yaml } | str join "---\n"
}

export def main [
	--spec: string                 # The app's airlock spec, exported from its CUE (JSON)
	--ssh: string = "bruno@13.140.186.223" # The node
	--kubeconfig: string = "$HOME/.cache/contabo2.kubeconfig" # On the node
] {
	if ($spec | is-empty) { error make {msg: "--spec <file.json> is required"} }
	let s = (open --raw $spec | from json | check $in)
	let kubectl = $"env KUBECONFIG=($kubeconfig) kubectl"
	let remote = {|cmd: string| $in | ^ssh -o BatchMode=yes $ssh $cmd }
	let ns = $s.namespace
	# The credentials' Secrets are their owners' to write: refuse before anything is applied.
	for r in ($s.doors | where {|d| ($d.secret? | is-not-empty) } | get secret | uniq) {
		let has = (do $remote $"($kubectl) get secret ($r.name) -n ($ns) -o jsonpath='{.data.($r.key)}' | wc -c" | str trim | into int)
		if $has == 0 { error make {msg: $"no key ($r.key) in the Secret ($r.name) in ($ns): release the service that owns it first"} }
	}
	manifests $s | do $remote $"($kubectl) apply -f -" | print
	do $remote $"($kubectl) rollout restart deployment/($s.name) -n ($ns) >/dev/null && ($kubectl) rollout status deployment/($s.name) -n ($ns) --timeout=300s" | print
	# From inside its pod: each door is there (a request it refuses is a 400, with no call and no row),
	# and a door it does not have is a 404.
	let ask = {|door: string|
		$"const r = await fetch\('http://127.0.0.1:($door_port)/door/($door)', {method: 'POST', body: '{}'}\); console.log\(r.status\);" | do $remote $"($kubectl) exec -i -n ($ns) deploy/($s.name) -c airlock -- deno run -A -" | str trim
	}
	for d in $s.doors {
		let st = (do $ask $d.door)
		if $st != "400" { error make {msg: $"door ($d.door) answered ($st) to a request it should refuse, not 400"} }
	}
	let none = (do $ask "no-such-door")
	if $none != "404" { error make {msg: $"a door the airlock lacks answered ($none), not 404"} }
	print $"airlock: ($s.name) answers in ($ns) on ($door_port), doors ($s.doors | get door | str join ', ')"
}
