// One app's node release engine files: `cue export ./node/engine/export -e files --out json`, each
// path from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/node/engine"

files: (engine.#Host & {}).files
