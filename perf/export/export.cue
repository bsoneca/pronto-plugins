// One app's perf host files, by tag: `cue export ./perf/export
// -t package=<pkg> [-t endpoint=…] -e files --out json`, each
// path from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/perf"

_package:  string @tag(package)
_endpoint: *"/perf" | string @tag(endpoint)

files: (perf.#Host & {
	package:  _package
	endpoint: _endpoint
}).files
