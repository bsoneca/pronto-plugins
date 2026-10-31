// One app's journeys host files, by tag: `cue export ./journeys/export
// -t package=<pkg> [-t endpoint=…] -e files --out json`, each
// path from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/journeys"

_package:  string @tag(package)
_endpoint: *"/telemetry" | string @tag(endpoint)

files: (journeys.#Host & {
	package:  _package
	endpoint: _endpoint
}).files
