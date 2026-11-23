# The door's flags route (flags/app/flags.nu, `flags route`) on a Caddyfile: it asks the auth service for the session, and
# where the keys plugin is installed (pronto/keys.cue) it asks the keys service's /auth/door instead, with no Dapr header.
#   ./saytw --script tools.nu nu flags/test/route_test.nu

const here = path self .

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"flags/test/route_test.nu: ($what)"} }
	print $"ok  ($what)"
}

def routed [keys: bool]: nothing -> string {
	let app = (mktemp --directory)
	mkdir ($app | path join docker) ($app | path join pronto)
	"(app) {\n  # The auth service.\n  handle /auth/* {\n    respond 200\n  }\n}\n" | save ($app | path join docker Caddyfile)
	if $keys { "package prontoproject\n" | save ($app | path join pronto keys.cue) }
	let script = ($here | path join .. app flags.nu | path expand)
	cd $app
	^$nu.current-exe -c $"use ($script); flags route"
	open --raw ($app | path join docker Caddyfile)
}

def main [] {
	let plain = (routed false)
	check "the flags route asks the auth service" ($plain | str contains 'forward_auth {$PRONTO_UPSTREAM_AUTH:auth:9999} {')
	check "with its Dapr header" ($plain | str contains "header_up dapr-app-id auth")
	check "and no keys service" (not ($plain | str contains PRONTO_UPSTREAM_KEYS))

	let keyed = (routed true)
	check "with the keys plugin it asks the keys service's door" ($keyed | str contains 'forward_auth {$PRONTO_UPSTREAM_KEYS:keys:8702} {')
	check "at /auth/door" ($keyed | str contains "uri /auth/door")
	check "with no Dapr header for the auth service" (not ($keyed | str contains "dapr-app-id auth"))
	check "the auth service is not asked" (not ($keyed | str contains PRONTO_UPSTREAM_AUTH))
	check "flagd's own Dapr header stays" ($keyed | str contains "header_up dapr-app-id flagd")
	check "the route is still before /auth/*" (($keyed | str index-of "handle /ofrep/*") < ($keyed | str index-of "handle /auth/*"))
	check "and the account header is copied" ($keyed | str contains "copy_headers X-Pronto-Account")
}
