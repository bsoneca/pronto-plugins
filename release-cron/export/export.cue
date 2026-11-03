// One app's release-cron files, by tag: `cue export ./release-cron/export -t package=<pkg> -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/release-cron:releasecron"

_package: string @tag(package)

files: (releasecron.#Host & {package: _package}).files
