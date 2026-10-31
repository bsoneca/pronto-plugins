# The billing host's generate step, run by the rule pronto/billing.cue adds,
# after pronto's writer. Written by pronto-billing; regenerated, do not edit.

const begin = "  # pronto-billing:begin — the plans, the broker's entitlements and paying, to the billing service"
const end = "  # pronto-billing:end"

# A file rewritten only when its text changes, so a generate that changes
# nothing leaves every watch and build cache where it was.
def save-changed [path: path] {
	let text = $in
	if not ($path | path exists) or (open --raw $path) != $text {
		mkdir ($path | path dirname)
		$text | save --force --raw $path
	}
}

# The door's routes to the billing service, which pronto's writer regenerates
# without them. An earlier run's go first.
export def route [] {
	let proxy = [
		"    reverse_proxy {$PRONTO_UPSTREAM_BILLING:billing:8688} {"
		"      header_up dapr-app-id billing"
		"      header_up Host {upstream_hostport}"
		"    }"
	]
	let route = [
		$begin
		"  handle /.well-known/pronto-billing.json {"
		...$proxy
		"  }"
		"  handle /billing/* {"
		# An entitlement is a token of a kilobyte; a request to pay, less.
		"    request_body {"
		"      max_size 16KB"
		"    }"
		...$proxy
		"  }"
		$end
	]
	let all = open --raw docker/Caddyfile | lines
	let from = $all | enumerate | where item == $begin | get index.0?
	let to = $all | enumerate | where item == $end | get index.0?
	let lines = if $from == null or $to == null { $all } else { [...($all | first $from) ...($all | skip ($to + 1))] }
	# Into the (app) snippet every listener imports, before its first route and
	# the comment that route carries.
	let at = $lines | enumerate | where {|l| $l.item | str starts-with "  handle /auth/*"} | get index.0?
	if $at == null { error make {msg: "docker/Caddyfile has no `handle /auth/*` to place the billing routes before"} }
	# Another host's block ends with its end marker, which is no comment of this route's.
	let start = $at - ($lines | first $at | reverse | take while {|l| ($l | str starts-with "  #") and not ($l | str ends-with ":end")} | length)
	[...($lines | first $start) ...$route ...($lines | skip $start)] | str join "\n" | $"($in)\n" | save-changed docker/Caddyfile
}
