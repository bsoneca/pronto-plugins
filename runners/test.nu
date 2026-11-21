# The runners schema's refusals, each by a setup that breaks a rule: `./saytw --script tools.nu nu runners/test.nu`.
# What a setup renders is runners/tests.cue's (cue vet); what it must not be is here, since a CUE
# file cannot say that another fails.

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"runners/test.nu: ($what)"} }
	print $"ok  ($what)"
}

# Whether `cue vet` refuses a setup written beside the schema and the plan.
def refused [setup: string] {
	let dir = mktemp --directory
	cp runners/schema.cue runners/host.cue $dir
	$"package runners\n\nsetups: x: {github: owner: \"acme\"\n($setup)\n}\nplans: [string]: {home: \"/home/x\", user: \"x\"}\n" | save $"($dir)/x.cue"
	let out = do { cd $dir; ^cue vet -c . } | complete
	rm --recursive $dir
	$out.exit_code != 0
}

def main [] {
	check "a cluster's BuildKit emulates amd64 to say emulate" (refused "cluster: context: \"k\"\namd64: \"emulate\"\nscaleSets: s: repo: \"r\"")
	check "a Colima VM never emulates" (refused "cluster: colima: {}\namd64: \"emulate\"\nscaleSets: s: repo: \"r\"")
	check "a host has no BuildKit to emulate with" (refused "cluster: host: {}\namd64: \"emulate\"\nhostRunners: h: repo: \"r\"")
	check "amd64 is cloud-build, emulate or none" (refused "cluster: host: {}\namd64: \"qemu\"\nhostRunners: h: repo: \"r\"")
	check "a Mac's runner is arm64" (refused "cluster: host: arch: \"x64\"\nhostRunners: h: repo: \"r\"")
	check "a Mac's runner is a launchd agent" (refused "cluster: host: {}\nhostService: \"systemd\"\nhostRunners: h: repo: \"r\"")
	check "a Linux runner is a systemd unit" (refused "cluster: host: os: \"linux\"\nhostService: \"launchd\"\nhostRunners: h: repo: \"r\"")
	check "a cluster that emulates amd64 may say so" (not (refused "cluster: context: \"k\"\namd64: \"emulate\"\nbuildkit: emulate: [\"linux/amd64\"]\nscaleSets: s: repo: \"r\""))
	check "a Linux host on arm64 is fine" (not (refused "cluster: host: os: \"linux\"\nhostRunners: h: repo: \"r\""))

	# Accounts: a runner of an account that is not a `pr` account has no policy to run without.
	let gh = "versions: gh: \"osx-arm64\": {url: \"https://example.invalid/gh.zip\", sha256: \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", member: \"gh\", binary: \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}\n"
	let acc = $"cluster: host: {}\naccounts: {pr: role: \"pr\", tr: role: \"trusted\"}\n($gh)"
	let ok = "{workflow: \".github/workflows/a.yml\", events: [\"push\"]}"
	check "a trusted account's runner without admits fails closed" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\"}")
	check "a trusted account's runner with an empty admits fails closed" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: []}")
	check "a trusted account's runner with admits is fine" (not (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: [($ok)]}"))
	check "a pr account's runner is fine without admits" (not (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"pr\"}"))
	check "a pr account's runner takes no admits" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"pr\", admits: [($ok)]}")
	check "a runner's account is one the setup names" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"ghost\"}")
	check "a runner that is the applier's own may admit workflows, and stays an agent" (not (refused $"($acc)hostRunners: h: {repo: \"r\", admits: [($ok)]}"))
	check "a runner that is the applier's own takes no daemon environment" (refused $"($acc)hostRunners: h: {repo: \"r\", env: A: \"b\"}")
	check "a trusted account's runner of an organization has no repository its workflow refs could name" (refused $"($acc)github: kind: \"org\"\nhostRunners: h: {user: \"tr\", admits: [($ok)]}")
	check "a trusted account's runner of an organization with a repository is fine" (not (refused $"($acc)github: kind: \"org\"\nhostRunners: h: {repo: \"r\", user: \"tr\", admits: [($ok)]}"))
	check "the applier's own runner of an organization that admits workflows needs a repository too" (refused $"($acc)github: kind: \"org\"\nhostRunners: h: {admits: [($ok)]}")
	check "an admitted workflow name has no space or shell metacharacter" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: [{workflow: \".github/workflows/a b.yml\", events: [\"push\"]}]}")
	check "an admitted workflow name has no $ or ;" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: [{workflow: \".github/workflows/a$x;rm.yml\", events: [\"push\"]}]}")
	check "an admitted workflow is a file of .github/workflows" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: [{workflow: \"scripts/a.yml\", events: [\"push\"]}]}")
	check "an admitted ref carries no shell metacharacters" (refused $"($acc)hostRunners: h: {repo: \"r\", user: \"tr\", admits: [{workflow: \".github/workflows/a.yml\", ref: \"x\\\"; rm\", events: [\"push\"]}]}")
	check "a Linux unit has no account" (refused "cluster: host: os: \"linux\"\naccounts: tr: role: \"trusted\"\nhostRunners: h: repo: \"r\"")
	check "a trusted account's runner needs the gh it puts on its PATH pinned" (refused "cluster: host: {}\naccounts: tr: role: \"trusted\"\nhostRunners: h: {repo: \"r\", user: \"tr\", admits: [{workflow: \".github/workflows/a.yml\", events: [\"push\"]}]}")
	check "an existing account is an owner, trusted with nothing" (refused $"($acc)accounts: me: {role: \"trusted\", existing: true}")
	check "an owner account is one already on the machine" (refused $"($acc)accounts: me: role: \"owner\", existing: false")
	check "an owner account, existing, is fine" (not (refused $"($acc)accounts: me: {role: \"owner\", existing: true}\nhostRunners: h: {repo: \"r\"}"))
	check "no runner runs as an owner account" (refused $"($acc)accounts: me: {role: \"owner\", existing: true}\nhostRunners: h: {repo: \"r\", user: \"me\"}")
	check "a created account's group is its own" (refused $"($acc)accounts: other: {role: \"pr\", group: \"staff\"}")
}
