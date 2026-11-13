package harness

import "strings"

_plain: #Host
_scen:  #Host & {scenarios: true}

// Every app gets the six files; one that runs scenarios gets their selector too.
plain: [for p, _ in _plain.files {p}] & ["tests/slot.ts", "tests/unit.ts", "tests/unit/select.js", "tests/unit/schema.cue", "tests/browser.ts", "tests/lint.ts"]
withScenarios: [for p, _ in _scen.files {p}] & ["tests/slot.ts", "tests/unit.ts", "tests/unit/select.js", "tests/unit/schema.cue", "tests/browser.ts", "tests/lint.ts", "tests/scenarios/select.ts"]

// Each is regenerated, never seeded: an app never makes them its own.
neverSeeded: [for _, f in _scen.files if f.seed {f}] & []

// Written as files/ holds them: no header in front.
noHeader: strings.HasPrefix(_plain.files["tests/unit.ts"].text, "// The unit cases") & true
