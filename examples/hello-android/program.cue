// One counter, the first app on pronto's Android host: the browser runs it in
// omnishell, the phone runs the same handler from android/. See AGENTS.md at
// pronto's root for the rules this instantiates.
@extern(embed)

package hello_android

import pronto "github.com/bonisoft3/pronto"

_designMd:   _ @embed(file="DESIGN.md", type=text)
_catalogues: _ @embed(glob="messages/*.json")

code: pronto.#App & {
	state: entities: {
		// A seeded singleton, the row both hosts start from.
		Counter: {
			id: "0xa5ae24603b8b974f"
			table:      "counter"
			durability: "tab"
			fields: [
				{ordinal: 1, name: "id", type: "string", pk: true, cel: "this == 'counter'"},
				{ordinal: 2, name: "n", type: "int32", cel: "this >= -99 && this <= 99"},
			]
			seed: [{id: "counter", n: 0}]
		}
	}

	capabilities: {
		blobs: false
		hatches: {}
		vendored: {}
	}

	surface: {
		screens: {
			counter: {title: "Counter", route: "/", label: "nav_counter", states: ["populated"], paths: {count: {states: ["populated", "populated"], accepts: ["accept-count"]}}}
		}
		handlers: {}
		design: (pronto.#DesignMd & {text: _designMd}).design
		flows: {}
	}

	meta: {
		name:        "hello-android"
		description: "A counter that runs the same program in the browser and as a native Android app."
		ir: {sha256: "b52dc339e841ddac70eda00429f0c05c7390bedfd7c24cb4b78434131774458b"}
		targets: ["pages"]
		i18n: {
			default: "en"
			locales: "en": path: "en"
			catalogues: _catalogues
		}
		decisions: {"decision-escape-hatches": {}, "decision-android-host": {}}
		tests: {}
	}
}

cluster:  (pronto.#DefaultCluster & {"code": code, "local": terminal.surface.runtime != "", statics: terminal.surface.statics}).out
terminal: (pronto.#DefaultTerminal & {"code": code}).out
loop:     (pronto.#DefaultLoop & {"code": code, "cluster": cluster, "terminal": terminal}).out

loop: surface: checks: "unit": {
	verb: "test"
	cmds: ["deno test --allow-read tests/handlers.test.ts"]
	note: "each handler file is a value: evaluated, called with rows and an event, and its updates compared"
}

build: (pronto.#DefaultBuild & {"code": code, "loop": loop, "cluster": cluster, "terminal": terminal}).out
out:   pronto.#emit & {"code": code, "cluster": cluster, "terminal": terminal, "loop": loop, "build": build}
