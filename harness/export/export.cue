// One app's harness files, by tag: `cue export ./harness/export -t scenarios=true|false -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/harness"

_scenarios: *"false" | "true" @tag(scenarios)

files: (harness.#Host & {scenarios: _scenarios == "true"}).files
