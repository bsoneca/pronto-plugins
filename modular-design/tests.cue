package modulardesign

import (
	"list"
	"strings"
)

_h: #Host & {package: "demo", module: "demo.example/app"}
_kept: #Host & {package: "demo", module: "demo.example/app", fresh: false}

// What the plugin regenerates, and what the app owns once.
regenerated: [for p, f in _h.files if !f.seed {p}] & [
	"pronto/modular_design.cue",
	"modular_design_plugin.cue",
	"modules/modules_plugin.cue",
	"modules/build.nu",
	"modules/lint.ts",
]
seeded: list.SortStrings([for p, f in _h.files if f.seed {p}]) & [
	"join/join.cue",
	"modular_design_spec.cue",
	"modules/example/example.cue",
	"modules/modules.cue",
	"modules/schema/schema.cue",
]

// An app that has modules already keeps them: only the opt-in is seeded.
keptOnlyOptIn: list.SortStrings([for p, f in _kept.files if f.seed {p}]) & ["modular_design_spec.cue"]

// The generate rule runs before pronto's writer, so the exports exist when the program is evaluated.
beforeWriter: _h._generate.priority & <1

// The example module imports the app's own schema module, by the app's module path.
exampleImports: strings.Contains(_h.files["modules/example/example.cue"].text, "import schema \"demo.example/app/modules/schema\"") & true
