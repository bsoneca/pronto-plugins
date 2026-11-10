// One setup's plan, by tag: `cue export ./runners/export -t setup=<name> -t home=$HOME -t user=$USER -e plan
// --out json`, what runners.ts applies. The home is the person's: a host runner's paths are under it.
package export

import "github.com/bsoneca/pronto-plugins/runners"

_setup: string                   @tag(setup)
_home:  *"/Users/check" | string @tag(home)
_user:  *"" | string             @tag(user)

plan: runners.#Plan & {setup: runners.setups[_setup], home: _home, user: _user}
