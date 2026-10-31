// pronto-identity's installer (bin/pronto-identity): the front's image a local launch's broker
// runs is the operator's own, with no default, so an app that names none is refused before
// anything is written, saying what to name.
package unit

cases: {
	"a local broker with no front's image named is refused, and nothing is written": {suite: "identity", steps: [
		{call: "identity.installed"}, {keep: "out"},
		{get: "exit", expect: 2},
		{use: "out"}, {get: "said", matches: "frontImage=<registry>/pronto-identity:<version>@sha256:"},
		{use: "out"}, {get: "files", expect: ["program.cue"], why: "nothing written"},
	]}
	"the local broker named outright is refused alike: it is the default, and still needs its image": {suite: "identity", steps: [
		{call: "identity.installed", args: [["broker=http://localhost:28443"]]}, {keep: "out"},
		{get: "exit", expect: 2},
		{use: "out"}, {get: "said", matches: "there is no default"},
	]}
}
