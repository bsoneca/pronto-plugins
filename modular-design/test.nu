# The installer, the build step and the lint against a fresh example app: `./saytw --script tools.nu nu
# modular-design/test.nu` from the repository's root (cue, nu and deno on the PATH). Installs into an app that has
# nothing, runs its generate step (modules/build.nu) and its lint (modules/lint.ts), reruns the installer, then refuses
# an overlap, a cross-module import and a cycle.
def check [what: string, ok: bool] {
	if not $ok { error make {msg: $"modular-design/test.nu: ($what)"} }
	print $"ok  ($what)"
}

# The lint's verdict on an app: its exit code and what it said.
def lint [app: path] {
	cd $app
	^deno run --allow-read --allow-run --allow-env modules/lint.ts | complete
}

def modules-cue [app: path, body: string] {
	$"package modules\n\nmodules: #Modules & {\n\tschema: {}\n($body)\n}\n" | save --force --raw ($app | path join modules/modules.cue)
}

def main [] {
	let root = ($env.CURRENT_FILE | path dirname | path dirname)
	let dir = (mktemp --directory | path expand)
	let app = ($dir | path join app)
	mkdir ($app | path join cue.mod)
	"package demo\n" | save --raw ($app | path join program.cue)
	"module: \"demo.example/app@v0\"\nlanguage: {\n\tversion: \"v0.16.1\"\n}\n" | save --raw ($app | path join cue.mod/module.cue)

	cd $root
	^sh bin/pronto-modular-design $app
	for f in ["pronto/modular_design.cue" "modular_design_plugin.cue" "modular_design_spec.cue" "modules/modules_plugin.cue" "modules/build.nu" "modules/lint.ts" "modules/modules.cue" "modules/schema/schema.cue" "modules/example/example.cue" "join/join.cue"] {
		check $"the installer writes ($f)" (($app | path join $f) | path exists)
	}
	let gitignore = (open --raw ($app | path join .gitignore))
	check "the exports are ignored: each module's deps/ and the join's file" (($gitignore | str contains "/modules/*/deps/") and ($gitignore | str contains "/join/example.json"))
	check "the generate rule runs before pronto's writer" ((open --raw ($app | path join pronto/modular_design.cue)) | str contains "\"priority\":-1")

	# Generate: the build step exports each module and writes the exports where they are read.
	cd $app
	^$nu.current-exe modules/build.nu
	check "generate writes the example's export for the join" (($app | path join join/example.json) | path exists)
	check "the join reads it" (((^cue export ./join --out json | from json).items | length) == 2)
	check "the lint passes on a fresh app" ((lint $app).exit_code == 0)

	# A rerun changes only what is missing or regenerated: the app's own files are kept.
	"// the app's own\n" | save --append --raw ($app | path join modules/modules.cue)
	"// the app's own\n" | save --append --raw ($app | path join modular_design_spec.cue)
	let mine = (open --raw ($app | path join modules/modules.cue))
	let gi = (open --raw ($app | path join .gitignore))
	cd $root
	^sh bin/pronto-modular-design $app
	check "a rerun keeps modules.cue" ((open --raw ($app | path join modules/modules.cue)) == $mine)
	check "a rerun keeps modular_design_spec.cue" ((open --raw ($app | path join modular_design_spec.cue)) | str ends-with "// the app's own\n")
	check "a rerun does not touch the schema module or the example" (not ((open --raw ($app | path join modules/schema/schema.cue)) | str contains "own"))
	check "a rerun leaves .gitignore as it was" ((open --raw ($app | path join .gitignore)) == $gi)

	# The lint refuses two modules that own overlapping paths.
	mkdir ($app | path join modules/other)
	"package other\n\nx: 1\n" | save --force --raw ($app | path join modules/other/other.cue)
	let example = "\texample: {needs: [\"schema\"], expr: \"out\", join: \"join/example.json\", owns: [\"items.example\"]}"
	modules-cue $app $"($example)\n\tother: {needs: [\"schema\"], owns: [\"items.example.x\"]}"
	let overlap = (lint $app)
	check "the lint refuses an overlap" (($overlap.exit_code != 0) and ($overlap.stderr | str contains "two modules never write the same field"))
	modules-cue $app $"($example)\n\tother: {needs: [\"schema\"], owns: [\"items.other\"]}"
	check "owning a sibling path is no overlap" ((lint $app).exit_code == 0)
	modules-cue $app $"($example)\n\tother: {needs: [\"schema\"], owns: [\"items.*\"]}"
	check "a wildcard overlaps the path it covers" ((lint $app).exit_code != 0)

	# The lint refuses a module that imports another module's CUE, and lets the schema be imported.
	modules-cue $app $"($example)\n\tother: {needs: [\"schema\"], owns: [\"items.other\"]}"
	"package other\n\nimport e \"demo.example/app/modules/example\"\n\nx: e.items\n" | save --force --raw ($app | path join modules/other/other.cue)
	let imp = (lint $app)
	check "the lint refuses a cross-module import" (($imp.exit_code != 0) and ($imp.stderr | str contains "imports the CUE of module example"))
	"package other\n\nimport s \"demo.example/app/modules/schema\"\n\nx: s.#Item & {id: \"a\", n: 1}\n" | save --force --raw ($app | path join modules/other/other.cue)
	check "importing the schema is allowed" ((lint $app).exit_code == 0)

	# And a `needs` cycle.
	modules-cue $app "\texample: {needs: [\"schema\", \"other\"], expr: \"out\", join: \"join/example.json\", owns: [\"items.example\"]}\n\tother: {needs: [\"example\"], owns: [\"items.other\"]}"
	let cycle = (lint $app)
	check "the lint refuses a needs cycle" (($cycle.exit_code != 0) and ($cycle.stderr | str contains "needs has a cycle"))
	check "the build refuses a needs cycle too" ((do { cd $app; ^$nu.current-exe modules/build.nu } | complete).exit_code != 0)
	rm -rf $dir
}
