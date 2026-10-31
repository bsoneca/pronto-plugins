# The generate step against a fixture app: `./saytw --script tools.nu nu
# perf/test.nu`. Patches the door twice and writes a program's `perf.out`,
# asserting what each run leaves behind.
use perf.nu

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"perf/test.nu: ($what)"} }
	print $"ok  ($what)"
}

def main [] {
	let dir = mktemp --directory
	cd $dir
	mkdir docker
	"(app) {\n  # The auth service, unstripped.\n  # Its comment is its own.\n  handle /auth/* {\n    reverse_proxy auth:9999\n  }\n}\n" | save docker/Caddyfile

	perf route "/p"
	let caddy = open --raw docker/Caddyfile
	let stamp = ls docker/Caddyfile | get modified.0
	perf route "/p"
	check "a second patch leaves the door untouched" ((ls docker/Caddyfile | get modified.0) == $stamp)
	check "a second patch changes nothing" ((open --raw docker/Caddyfile) == $caddy)
	check "the door caps a batch's size" ($caddy | str contains "    request_body {\n      max_size 32KB\n    }")
	check "the route reaches the collector's own path" (($caddy | str contains "handle /p {") and ($caddy | str contains "    rewrite * /perf"))
	check "the collector is a peer the host can rewrite" ($caddy | str contains "{$PRONTO_UPSTREAM_PERF_COLLECTOR:perf-collector:8687}")
	check "the route lands above the auth route's comment" (($caddy | str index-of "pronto-perf:end") < ($caddy | str index-of "# The auth service"))

	perf route "/v2/p"
	let moved = open --raw docker/Caddyfile
	check "a changed endpoint replaces the route" (($moved | str contains "handle /v2/p {") and not ($moved | str contains "handle /p {"))

	{"perf.rules.yaml": {groups: []}, "perf.dashboard.json": {uid: "pronto-perf"}, "perf.reporter.json": {sample: 0.5, buckets: {frame: [0.01]}}} | to json | perf write
	check "the rules are YAML in observability/" ((open --raw observability/perf.rules.yaml | from yaml) == {groups: []})
	check "the dashboard is JSON in observability/" ((open observability/perf.dashboard.json).uid == "pronto-perf")
	let config = open --raw shell/hatches/perf/config.js
	check "the reporter's settings are its module" ($config | str contains 'export default {"sample":0.5,"buckets":{"frame":[0.01]}};')
	check "the reporter's settings are not in observability/" (not ("observability/perf.reporter.json" | path exists))

	"(app) {\n}\n" | save --force docker/Caddyfile
	check "a door with no auth route refuses" (try { perf route "/p"; false } catch { true })

	cd -
	rm --recursive $dir
}
