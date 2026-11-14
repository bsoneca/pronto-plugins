// The harness host: the test files every pronto app holds the same (README.md). They are written
// into the app byte for byte as files/ holds them, with no header, so an app's copy, another app's
// and this one compare with cmp. The scenarios' runner, its schema, selector and helpers only go to an
// app that runs scenarios.
@extern(embed)

package harness

_slot:       _ @embed(file="files/tests/slot.ts", type=text)
_unit:       _ @embed(file="files/tests/unit.ts", type=text)
_select:     _ @embed(file="files/tests/unit/select.js", type=text)
_schema:     _ @embed(file="files/tests/unit/schema.cue", type=text)
_browser:    _ @embed(file="files/tests/browser.ts", type=text)
_lint:       _ @embed(file="files/tests/lint.ts", type=text)
_scenarios:  _ @embed(file="files/tests/scenarios/select.ts", type=text)
_runner:     _ @embed(file="files/tests/scenarios.ts", type=text)
_scenSchema: _ @embed(file="files/tests/scenarios/schema.cue", type=text)
_early:      _ @embed(file="files/tests/scenarios/early.ts", type=text)
_slow:       _ @embed(file="files/tests/slow.ts", type=text)

#Host: H={
	// Whether the app runs scenarios (tests/scenarios.ts): only then does it get their runner, schema,
	// selector and helpers.
	scenarios: *false | bool

	files: {
		"tests/slot.ts": {seed: false, text: _slot}
		"tests/unit.ts": {seed: false, text: _unit}
		"tests/unit/select.js": {seed: false, text: _select}
		"tests/unit/schema.cue": {seed: false, text: _schema}
		"tests/browser.ts": {seed: false, text: _browser}
		"tests/lint.ts": {seed: false, text: _lint}
		if H.scenarios {
			"tests/scenarios.ts": {seed: false, text: _runner}
			"tests/scenarios/schema.cue": {seed: false, text: _scenSchema}
			"tests/scenarios/select.ts": {seed: false, text: _scenarios}
			"tests/scenarios/early.ts": {seed: false, text: _early}
			"tests/slow.ts": {seed: false, text: _slow}
		}
	}
}
