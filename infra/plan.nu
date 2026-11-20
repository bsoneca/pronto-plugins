# The saved-plan lifecycle every infra target shares (gcp's verbs in say.cue.txt, pronto's cloudflare): verify makes a
# plan, checks it and keeps it as <dir>/plan-<sha256>.tfplan; release applies the one whose digest the operator names.
#   use plan.nu *
#   saved-plan make --tofu {|a| ^tofu -chdir=tofu ...$a | complete } --creds {|| {TOKEN: ...}}
#   saved-plan apply $env.INFRA_PLAN_SHA256 --tofu {|a| ... }
# The file names (scratch-*.tfplan, plan-*.tfplan, plan-*.tfplan.claim-*) all match host.cue's tofu/*.tfplan*.

# The plan's resource changes, or an error when the plan can't be read or lists them as no list.
export def plan-changes []: record -> list {
	let j = $in
	if ($j | get -o format_version) == null { error make {msg: 'the plan could not be read'} }
	let rc = ($j | get -o resource_changes | default [])
	if ($rc | describe) !~ '^(list|table)' { error make {msg: 'the plan lists its changes as no list'} }
	$rc
}

# Refuses a plan that deletes anything `spare` doesn't excuse: dropping a resource from the state is no reason to
# delete it from the provider. INFRA_ALLOW_DESTROY=1, for that run alone, says it is.
export def guard-deletes [rc: list, spare: closure] {
	let gone = ($rc | where {|c| ('delete' in $c.change.actions) and not (do $spare $c) } | get address)
	if ($gone | is-not-empty) and ($env.INFRA_ALLOW_DESTROY? != '1') {
		error make {msg: $"the plan deletes ($gone | str join ', '): set INFRA_ALLOW_DESTROY=1 to allow it"}
	}
}

def rm-quiet [f: string] { rm --force $f }

# The operator's gcloud access token, for the state bucket (and gcp's provider): a gcloud that fails stops the verb with
# its own words, never hands tofu an empty token that could fall back to another identity. Never printed.
export def gcloud-token []: nothing -> string {
	let t = (do { ^gcloud auth print-access-token } | complete)
	if $t.exit_code != 0 or ($t.stdout | str trim | is-empty) { error make {msg: $"gcloud auth print-access-token failed \(exit ($t.exit_code)\): ($t.stderr | str trim)"} }
	$t.stdout | str trim
}

# Plans, reads and checks a plan, then keeps it as <dir>/plan-<sha256>.tfplan (mode 600) and prints the digest to release
# with. Only this run's own scratch file is ever removed: a plan another run kept is never touched.
#   --tofu    {|args: list<string>| ...}  runs tofu with -chdir=<dir> applied; returns what `complete` returns
#   --creds   {|| record}                 the credentials, set around plan and show alone
#   --check   {|rc: list| }               a provider's own refusal (an error), after the plan is read
#   --spare   {|c| bool}                  a delete that is no deletion (see guard-deletes)
export def "saved-plan make" [--tofu: closure, --creds: closure, --check: closure, --spare: closure, --dir: string = "tofu"] {
	let scratch = $"scratch-(random uuid).tfplan"
	let path = ($dir | path join $scratch)
	# A plan can hold secret values: the folder is the operator's alone before tofu writes one into it.
	^chmod 700 $dir
	let cred = if $creds == null { {} } else { do $creds }
	let spare_c = if $spare == null { {|c| false } } else { $spare }
	let r = (with-env $cred { do $tofu ["plan" "-input=false" "-detailed-exitcode" $"-out=($scratch)"] })
	print $r.stdout
	# 0 (no change) and 2 (changes) are the only plans; any other status is a failure, whatever file it left.
	if $r.exit_code not-in [0 2] { rm-quiet $path; error make {msg: $"tofu plan exited ($r.exit_code): ($r.stderr)"} }
	try {
		let s = (with-env $cred { do $tofu ["show" "-json" $scratch] })
		if $s.exit_code != 0 { error make {msg: $"tofu show exited ($s.exit_code): ($s.stderr)"} }
		let rc = ($s.stdout | from json | plan-changes)
		if $check != null { do $check $rc }
		guard-deletes $rc $spare_c
	} catch {|e| rm-quiet $path; error make {msg: $e.msg} }
	# Hashed while the path is still this run's own: another run may keep a plan, never replace this file.
	let sha = (open --raw $path | hash sha256)
	^chmod 600 $path
	mv --force $path ($dir | path join $"plan-($sha).tfplan")
	print $"plan sha256 ($sha): release with INFRA_PLAN_SHA256=($sha)"
	if $r.exit_code == 2 { error make {msg: "the live state differs from the plan's source: read the plan, then release with INFRA_PLAN_SHA256"} }
	{sha: $sha, changed: ($r.exit_code == 2)}
}

# Applies the kept plan whose digest was named, and only that one. It is first claimed by a rename to a path of this run's
# own (so a second release finds none, and a verify beside it can't swap the file), then hashed again: other bytes are
# removed. It is read and checked under --creds; a refusal before the apply (a check, a delete, a credential that can't
# be read) gives the plan back under its name, so the operator can release it again once that is fixed. The apply's
# credentials (--apply-creds, default --creds) are read last, once the plan has passed. After the apply, the claimed
# file is removed whatever tofu said.
export def "saved-plan apply" [sha: string, --tofu: closure, --creds: closure, --apply-creds: closure, --check: closure, --spare: closure, --dir: string = "tofu"] {
	if $sha !~ '^[0-9a-f]{64}$' { error make {msg: "set INFRA_PLAN_SHA256 to the digest verify@infra printed for the plan you read"} }
	let name = $"plan-($sha).tfplan"
	let kept = ($dir | path join $name)
	let claim = $"($name).claim-(random uuid)"
	let path = ($dir | path join $claim)
	try { mv $kept $path } catch { error make {msg: $"no plan ($sha): run verify@infra and read it"} }
	if (open --raw $path | hash sha256) != $sha {
		rm-quiet $path
		error make {msg: "the kept plan is not the one whose digest was given: run verify@infra again and read it"}
	}
	let spare_c = if $spare == null { {|c| false } } else { $spare }
	let acred = try {
		let cred = if $creds == null { {} } else { do $creds }
		let s = (with-env $cred { do $tofu ["show" "-json" $claim] })
		if $s.exit_code != 0 { error make {msg: $"tofu show exited ($s.exit_code): ($s.stderr)"} }
		let rc = ($s.stdout | from json | plan-changes)
		if $check != null { do $check $rc }
		guard-deletes $rc $spare_c
		if $apply_creds == null { $cred } else { do $apply_creds }
	} catch {|e|
		# Given back only where no file holds the name now; a claim is unique, so nothing else can.
		if ($kept | path exists) { rm-quiet $path } else { mv $path $kept }
		error make {msg: $"($e.msg) \(plan ($sha) is kept: release it again once this is fixed\)"}
	}
	try {
		let a = (with-env $acred { do $tofu ["apply" "-input=false" $claim] })
		print $a.stdout
		if $a.exit_code != 0 { error make {msg: $"tofu apply exited ($a.exit_code): ($a.stderr)"} }
	} catch {|e| rm-quiet $path; error make {msg: $e.msg} }
	rm-quiet $path
}
