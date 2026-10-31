package hello_journeys

// The journeys this app promises: each an ordered list of
// `screen.gesture` moments — a handler by its module, a form by its
// id, else its action and entity (journeys_gestures.cue lists them) —
// with an availability target and optionally a latency one.
//
//	spec: checkout: {
//		owner:   "payments"
//		moments: ["cart.view", "cart.pay"]
//		slo: {availability: 99.9, latency: {percent: 95, under: "3s"}}
//	}
journeys: #Journeys & {gestures: _journeyGestures, spec: {
	"first-task": {owner: "fixture", moments: ["todo.create-todo"], slo: {availability: 99.5, latency: {percent: 95, under: "300ms"}}}
	"play": {owner: "fixture", moments: ["counter.count", "grid.press"], slo: availability: 99.9}
}}

loop: surface: checks: journeys.checks
