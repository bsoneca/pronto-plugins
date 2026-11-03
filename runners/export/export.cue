// One setup's plan, by tag: `cue export ./runners/export -t setup=<name> -e plan --out json`, what
// runners.ts applies.
package export

import "github.com/bsoneca/pronto-plugins/runners"

_setup: string @tag(setup)

plan: runners.plans[_setup]
