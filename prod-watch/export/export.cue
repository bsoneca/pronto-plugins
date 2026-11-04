// One app's prod-watch files, by tag: `cue export ./prod-watch/export -t package=<pkg> -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/prod-watch:prodwatch"

_package: string @tag(package)

files: (prodwatch.#Host & {package: _package}).files
