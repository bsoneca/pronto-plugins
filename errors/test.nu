# The errors host's generate step, its stand-in and its reporter's parsing:
# `./saytw --script tools.nu nu errors/test.nu`.
# Patches the door beside the other hosts' blocks, writes a program's `errors.out`, runs the
# stand-in and takes a report through it, and holds the schema to its rules by specs that break them.
use errors.nu

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"errors/test.nu: ($what)"} }
	print $"ok  ($what)"
}

# Whether `cue vet` refuses a spec written beside the schema.
def refused [spec: string] {
	let dir = mktemp --directory
	cp errors/schema.cue $dir
	$spec | save $"($dir)/spec.cue"
	let out = do { cd $dir; ^cue vet -c . } | complete
	rm --recursive $dir
	$out.exit_code != 0
}

def main [] {
	let plugin = $env.PWD
	let dir = mktemp --directory
	cd $dir
	mkdir docker
	"(app) {\n  # pronto-analytics:begin — the tracker's two addresses, to Umami\n  handle /a/e {\n  }\n  # pronto-analytics:end\n  # The auth service, unstripped.\n  # Its comment is its own.\n  handle /auth/* {\n    reverse_proxy auth:9999\n  }\n}\n" | save docker/Caddyfile

	errors route /e https://errors.example.com
	let caddy = open --raw docker/Caddyfile
	let stamp = ls docker/Caddyfile | get modified.0
	errors route /e https://errors.example.com
	check "a second patch leaves the door untouched" ((ls docker/Caddyfile | get modified.0) == $stamp)
	check "a second patch changes nothing" ((open --raw docker/Caddyfile) == $caddy)
	check "only a POST to a project's envelope goes on" (($caddy | str contains "    method POST\n    path_regexp ^/e/api/[0-9]+/envelope/$\n") and not ($caddy | str contains "handle /e/api/*"))
	check "the stand-in's read is a host launch's alone" ($caddy | str contains "    method GET\n    path /e/api/events\n    host localhost 127.0.0.1\n")
	check "the door caps a report's size" ($caddy | str contains "    request_body {\n      max_size 64KB\n    }")
	check "the prefix is stripped" ($caddy | str contains "    uri strip_prefix /e\n")
	check "a request for localhost reaches the stand-in the host door rewrites" (($caddy | str contains "@local host localhost 127.0.0.1") and ($caddy | str contains "reverse_proxy @local {$PRONTO_UPSTREAM_ERRORS:errors:8700}"))
	check "any other request reaches GlitchTip's address" ($caddy | str contains "      reverse_proxy https://errors.example.com {")
	check "the proxy sends the upstream's own Host" ($caddy | str contains "header_up Host {upstream_hostport}")
	let upstreams = 3
	for header in ["Cookie" "Authorization" "Referer" "X-Forwarded-For"] {
		check $"neither upstream is sent ($header)" (($caddy | split row $"header_up -($header)" | length) == ($upstreams + 1))
	}
	check "the route lands above the auth route's comment" (($caddy | str index-of "pronto-errors:end") < ($caddy | str index-of "# The auth service"))
	check "another host's block is not nested in ours" (($caddy | str index-of "pronto-analytics:end") < ($caddy | str index-of "pronto-errors:begin"))

	errors route /x https://e2.example.com
	let moved = open --raw docker/Caddyfile
	check "a changed address replaces the route" (($moved | str contains "path_regexp ^/x/api/[0-9]+/envelope/$") and not ($moved | str contains "^/e/api/") and not ($moved | str contains "errors.example.com"))

	{"errors.loader.json": {project: 1, key: "921d1ab3ed184f91867663937ab0002f", prefix: "/e", flag: "error_tracking"}} | to json | errors write
	check "the reporter's settings are its module's" ((open --raw shell/hatches/errors/config.js) | str contains 'export default {"project":1,"key":"921d1ab3ed184f91867663937ab0002f","prefix":"/e","flag":"error_tracking"};')
	check "a file with no place is refused" (try { {"errors.other.json": {}} | to json | errors write; false } catch { true })

	"(app) {\n}\n" | save --force docker/Caddyfile
	check "a door with no auth route refuses" (try { errors route /e https://errors.example.com; false } catch { true })

	# The stand-in takes an envelope as the reporter writes it, and says what it holds.
	cp $"($plugin)/errors/standin.ts" standin.ts
	let port = 18700 + (random int 0..999)
	let server = job spawn { with-env {ERRORS_PORT: ($port | into string)} { ^deno run --no-config --allow-net --allow-env standin.ts } | complete | ignore }
	sleep 2sec
	let base = $"http://127.0.0.1:($port)"
	let envelope = ([{event_id: "e1", sent_at: "2026-11-10T00:00:00Z"} {type: "event"} {event_id: "e1", level: "error", release: "r1", request: {url: "https://x/p"}}] | each {|l| $l | to json --raw } | str join "\n")
	let got = http post --allow-errors --full --content-type "text/plain" $"($base)/api/1/envelope/?sentry_key=abc&sentry_version=7" $envelope
	check "the stand-in answers an envelope 200 with its id" ($got.status == 200 and ($got.body.id == "e1"))
	check "the stand-in keeps the event" ((http get $"($base)/events" | get release) == ["r1"])
	check "the stand-in says them through the door's address too" ((http get $"($base)/api/events" | length) == 1)
	check "the stand-in refuses a report with no key" ((http post --allow-errors --full --content-type "text/plain" $"($base)/api/1/envelope/" $envelope).status == 401)
	check "the stand-in refuses what is no envelope" ((http post --allow-errors --full --content-type "text/plain" $"($base)/api/1/envelope/?sentry_key=abc" "nope").status == 400)
	job kill $server

	# The reporter's stack parsing, Chrome's and Firefox's and Safari's formats.
	mkdir shell
	cp $"($plugin)/errors/errors.js" shell/errors.js
	"export default {};\n" | save shell/config.js
	let script = "import { frames } from './shell/errors.js'; const chrome = frames('Error: boom\\n    at inner (https://h/a.js?x=1#y:10:5)\\n    at async outer (https://h/b.js:20:7)\\n    at https://h/c.js:3:1'); const gecko = frames('inner@https://h/a.js:10:5\\nouter@https://h/b.js:20:7\\n@https://h/c.js:3:1\\nnative@[native code]'); console.log(JSON.stringify({chrome, gecko}));"
	$script | save parse.js
	let parsed = ^deno run --no-config --allow-read parse.js | from json
	check "Chrome's stack is read, the oldest call first, without a query or a hash" ($parsed.chrome == [{function: "?", filename: "https://h/c.js", lineno: 3, colno: 1} {function: "outer", filename: "https://h/b.js", lineno: 20, colno: 7} {function: "inner", filename: "https://h/a.js", lineno: 10, colno: 5}])
	check "Firefox's and Safari's stack is read" ($parsed.gecko == [{function: "?", filename: "https://h/c.js", lineno: 3, colno: 1} {function: "outer", filename: "https://h/b.js", lineno: 20, colno: 7} {function: "inner", filename: "https://h/a.js", lineno: 10, colno: 5}])

	cd -
	rm --recursive $dir

	# The schema's rules, each by a spec that breaks it.
	check "a key is 32 hex digits" (refused "package errors\nx: #Errors & {project: 1, key: \"abc\"}\n")
	check "a project is not negative" (refused "package errors\nx: #Errors & {project: -1}\n")
	check "an upstream is https" (refused "package errors\nx: #Errors & {upstream: \"http://errors.example.com\"}\n")
	check "the prefix is a path" (refused "package errors\nx: #Errors & {prefix: \"e\"}\n")
	check "a spec of a project and a key is fine" (not (refused "package errors\nx: #Errors & {project: 1, key: \"921d1ab3ed184f91867663937ab0002f\", upstream: \"https://errors.bonkchess.com\"}\n"))
}
