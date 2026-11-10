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
}
