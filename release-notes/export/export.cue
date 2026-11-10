// One app's release-notes files: `cue export ./release-notes/export -t package=<pkg> -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/release-notes:releasenotes"

_package: string @tag(package)

files: (releasenotes.#Host & {package: _package}).files
