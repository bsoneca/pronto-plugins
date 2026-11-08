// Modular design: an app's design split into modules, small CUE packages each exported on its own and joined by
// a package of the app's. From this the plugin derives the checks the app's `test` runs: modules/lint.ts refuses a
// module that imports another module's CUE (the schema excepted), two modules that own overlapping paths, and a
// `needs` cycle.
//
// This file is written into the app's own package (modular_design_plugin.cue), so every name here is prefixed: it
// sits beside the program's.
package modulardesign

#ModularDesign: {
	// The program's own checks, unified as `loop: surface: checks: modularDesign.checks`.
	checks: {
		"modules": {
			verb: "test"
			cmds: ["deno run --allow-read --allow-run --allow-env modules/lint.ts"]
			note: "no module imports another module's CUE (the schema excepted), no two modules own overlapping paths, and `needs` has no cycle"
		}
	}
}
