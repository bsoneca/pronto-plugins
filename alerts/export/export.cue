// One app's pronto-alerts files, by tag: `cue export ./alerts/export -t package=<pkg> -t app=<app> -t project=<id>
// -e files --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/alerts:alerts"

_package: string        @tag(package)
_app:     string        @tag(app)
_project: string        @tag(project)
_cases:   bool | *false @tag(cases,type=bool)

files: (alerts.#Host & {package: _package, app: _app, project: _project, cases: _cases}).files
