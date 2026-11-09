// One app's migrations files, by tag: `cue export ./migrations/export -t package=<pkg> -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/migrations"

_package: string @tag(package)

files: (migrations.#Host & {package: _package}).files
