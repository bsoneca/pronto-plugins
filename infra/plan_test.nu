# The saved-plan lifecycle (plan.nu) against a stub tofu: no OpenTofu, no cloud. `nu infra/plan_test.nu`; infra/test.nu runs it.
# The stub's plan writes the fixture to the file it was told, show reads it back, apply logs which plan it applied.

use plan.nu *

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"infra/plan_test.nu: ($what)"} }
	print $"ok  ($what)"
}

# Whether the closure fails with an error whose message holds the text.
def refuses [run: closure, text: string] {
	try { do $run; false } catch {|e| $e.msg | str contains $text }
}

def change [address: string, actions: list<string>, --type: string = "t", --policy: string = ""] {
	{address: $address, type: $type, change: {actions: $actions, before: {deletion_policy: $policy}}}
}

# A tofu that plans with `code`, writing the fixture (marked, so two plans differ) to the file asked for.
def stub [dir: string, mark: string, --code: int = 0, --changes: list = []] {
	{|a|
		if $a.0 == "plan" {
			let out = ($a | where {|x| $x | str starts-with "-out="} | first | str replace "-out=" "")
			{format_version: "1.2", mark: $mark, resource_changes: $changes} | to json | save --force ($dir | path join $out)
			{exit_code: $code, stdout: "planned", stderr: $"plan failed ($code)"}
		} else if $a.0 == "show" {
			{exit_code: 0, stdout: (open --raw ($dir | path join $a.2)), stderr: ""}
		} else {
			$"(open --raw ($dir | path join $a.2) | from json | get mark)\n" | save --append ($dir | path join applied.log)
			{exit_code: 0, stdout: "applied", stderr: ""}
		}
	}
}

def files [dir: string] { glob ($dir | path join "*") | path basename | sort }
def applied [dir: string] { if ($dir | path join applied.log | path exists) { open --raw ($dir | path join applied.log) | str trim | lines } else { [] } }
def fresh [] { mktemp --directory }
def plans [dir: string] { files $dir | where {|f| $f | str starts-with "plan-"} }

def main [] {
	hide-env --ignore-errors INFRA_ALLOW_DESTROY
	let del = [(change "g.a" ["delete"])]

	# The digest claim applies, and leaves nothing but the log.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	check "make keeps plan-<sha>.tfplan, returns the digest" ((plans $d) == [$"plan-($a.sha).tfplan"] and $a.sha =~ '^[0-9a-f]{64}$' and not $a.changed)
	check "the kept plan is mode 600" ((ls --long ($d | path join $"plan-($a.sha).tfplan") | get mode.0) == "rw-------")
	check "the kept plan is named for the hash of its bytes" ((open --raw ($d | path join $"plan-($a.sha).tfplan") | hash sha256) == $a.sha)
	saved-plan apply $a.sha --dir $d --tofu (stub $d A)
	check "the digest claim applies the plan and removes it" ((applied $d) == ["A"] and (plans $d | is-empty) and (files $d | where {|f| $f | str contains "claim"} | is-empty))

	# A tofu that says 2 publishes first, then fails.
	let d = fresh
	check "exit 2 errors after publishing" (refuses {|| saved-plan make --dir $d --tofu (stub $d A --code 2)} "the live state differs from the plan's source")
	check "exit 2 left the plan to release" ((plans $d | length) == 1)

	# A wrong digest is refused and leaves the file.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	check "a malformed digest is refused" (refuses {|| saved-plan apply "abc" --dir $d --tofu (stub $d A)} "INFRA_PLAN_SHA256")
	check "a wrong digest is refused: no plan" (refuses {|| saved-plan apply ("0" | fill -c 0 -w 64) --dir $d --tofu (stub $d A)} "no plan")
	check "a wrong digest leaves the file" ((plans $d) == [$"plan-($a.sha).tfplan"] and (applied $d | is-empty))

	# A stale release: make A, make B, apply A. B stays, with B's bytes.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	let b = (saved-plan make --dir $d --tofu (stub $d B))
	saved-plan apply $a.sha --dir $d --tofu (stub $d A)
	check "a stale release applies A" ((applied $d) == ["A"])
	check "a stale release leaves plan-B with B's bytes" ((plans $d) == [$"plan-($b.sha).tfplan"] and (open --raw ($d | path join $"plan-($b.sha).tfplan") | hash sha256) == $b.sha)

	# A double claim: the second finds no plan.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	saved-plan apply $a.sha --dir $d --tofu (stub $d A)
	check "a double claim fails with no plan" (refuses {|| saved-plan apply $a.sha --dir $d --tofu (stub $d A)} "no plan")
	check "a double claim applied once" ((applied $d) == ["A"])

	# Bytes swapped after publish: refused, and only the claimed file goes.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	let b = (saved-plan make --dir $d --tofu (stub $d B))
	"swapped" | save --force ($d | path join $"plan-($a.sha).tfplan")
	check "swapped bytes are refused" (refuses {|| saved-plan apply $a.sha --dir $d --tofu (stub $d A)} "not the one whose digest")
	check "swapped bytes remove only the claimed file" ((plans $d) == [$"plan-($b.sha).tfplan"] and (files $d | where {|f| $f | str contains "claim"} | is-empty) and (applied $d | is-empty))

	# Deletes: refused without INFRA_ALLOW_DESTROY=1, passed with it.
	let d = fresh
	check "a delete is refused" (refuses {|| saved-plan make --dir $d --tofu (stub $d A --changes $del)} "the plan deletes g.a")
	check "a refused delete publishes nothing and leaves no scratch" ((files $d) == [])
	let a = (with-env {INFRA_ALLOW_DESTROY: "1"} { saved-plan make --dir $d --tofu (stub $d A --changes $del) })
	check "INFRA_ALLOW_DESTROY=1 passes a delete" ((plans $d | length) == 1)
	check "INFRA_ALLOW_DESTROY=0 does not" (refuses {|| with-env {INFRA_ALLOW_DESTROY: "0"} { saved-plan make --dir $d --tofu (stub $d A --changes $del) } } "the plan deletes")
	check "a release re-checks the deletes" (refuses {|| saved-plan apply $a.sha --dir $d --tofu (stub $d A --changes $del)} "the plan deletes")
	check "a refused release removes its claim" ((plans $d | is-empty) and (files $d | where {|f| $f | str contains "claim"} | is-empty))

	# The ABANDON secret-version spare.
	let spare = {|c| $c.type == 'google_secret_manager_secret_version' and ($c.change.before?.deletion_policy? == 'ABANDON') }
	let d = fresh
	saved-plan make --dir $d --spare $spare --tofu (stub $d A --changes [(change "v.a" ["delete" "create"] --type google_secret_manager_secret_version --policy ABANDON)])
	check "the ABANDON secret-version delete passes" ((plans $d | length) == 1)
	let d = fresh
	check "the same delete without ABANDON is refused" (refuses {|| saved-plan make --dir $d --spare $spare --tofu (stub $d A --changes [(change "v.a" ["delete" "create"] --type google_secret_manager_secret_version --policy DELETE)])} "the plan deletes v.a")

	# A refusing --check publishes nothing and leaves no scratch file.
	let d = fresh
	check "a refusing check refuses" (refuses {|| saved-plan make --dir $d --check {|rc| error make {msg: "no thanks"} } --tofu (stub $d A)} "no thanks")
	check "a refusing check leaves no file" ((files $d) == [])

	# Any exit but 0 and 2 publishes nothing.
	for code in [1 3] {
		let d = fresh
		check $"tofu exit ($code) errors with its stderr" (refuses {|| saved-plan make --dir $d --tofu (stub $d A --code $code)} $"plan failed ($code)")
		check $"tofu exit ($code) publishes nothing" ((files $d) == [])
	}

	# Another run's plan is never removed by a failing one.
	let d = fresh
	let a = (saved-plan make --dir $d --tofu (stub $d A))
	try { saved-plan make --dir $d --tofu (stub $d B --code 1) }
	check "a failing make leaves another plan alone" ((plans $d) == [$"plan-($a.sha).tfplan"])

	# The credentials reach tofu, apply's own where given.
	let d = fresh
	let probe = {|a| $env.PROBE | save --append ($d | path join probe.log); (stub $d A) | do $in $a }
	let p = (saved-plan make --dir $d --creds {|| {PROBE: "plan;"} } --tofu $probe)
	saved-plan apply $p.sha --dir $d --creds {|| {PROBE: "show;"} } --apply-creds {|| {PROBE: "apply;"} } --tofu $probe
	check "plan, show and apply each get their credentials" ((open --raw ($d | path join probe.log)) == "plan;plan;show;apply;")

	print "infra/plan_test.nu: all passed"
}
