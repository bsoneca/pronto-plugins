# Every plan the suite builds, exported whole and validated by OpenTofu: `./saytw --script tools.nu
# nu infra/test.nu` from this repository's root. tests.cue holds fields of each plan and passes
# for a plan that cannot be exported; this exports each in a folder of its own (with the file a
# secret reads beside it), then runs `tofu init -backend=false` and `tofu validate`, and fails on
# any error. The example is one of them.

def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"infra/test.nu: ($what)"} }
	print $"ok  ($what)"
}

# The plans of tests.cue and the example, each as the cue expression that exports it.
const plans = [
	[./infra _plan.tofu]
	[./infra _new.tofu]
	[./infra _svc.tofu]
	[./infra _draft.tofu]
	[./infra _binding.tofu]
	[./infra _order.tofu]
	[./infra _named.tofu]
	[./infra _two.tofu]
	[./examples/infra plan.tofu]
]

def main [] {
	let root = pwd
	let work = mktemp --directory
	let tofu = ["exec" "opentofu@1.13.2" "--" "tofu"]
	for p in $plans {
		let name = $"($p.0)/($p.1)" | str replace --all --regex '[^a-zA-Z0-9]+' "_"
		let dir = $work | path join $name
		mkdir ($dir | path join config) ($dir | path join tofu)
		"x" | save ($dir | path join config token.txt)
		let exported = ^cue export $p.0 -e $p.1 --out json | complete
		check $"($p.0) ($p.1) exports whole" ($exported.exit_code == 0)
		$exported.stdout | save ($dir | path join tofu main.tf.json)
		# From the folder, so that mise reads no config of this repository.
		cd $dir
		let init = ^mise ...$tofu -chdir=tofu init -backend=false -input=false | complete
		check $"($p.0) ($p.1) inits" ($init.exit_code == 0)
		let valid = ^mise ...$tofu -chdir=tofu validate -no-color | complete
		if $valid.exit_code != 0 { print $valid.stdout }
		check $"($p.0) ($p.1) validates" ($valid.exit_code == 0)
		cd $root
	}
	rm --recursive --force $work
}
