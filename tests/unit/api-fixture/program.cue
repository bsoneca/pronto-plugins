// A stand-in app for pronto-api's generator (tests/unit/api.cue): two entities, as program.cue
// holds them, and nothing else the generator reads. Its own package, never a real app's.
package fixture

code: state: entities: {
	Note: {
		table: "note"
		access: {scope: "public", write: true}
		fields: [
			{ordinal: 1, name: "id", type: "uuid", pk: true},
			{ordinal: 2, name: "owner_id", type: "uuid"},
			{ordinal: 3, name: "body", type: "string"},
			{ordinal: 4, name: "stars", type: "int32"},
			{ordinal: 5, name: "created", type: "timestamp"},
		]
	}
	Tag: {
		table: "tag"
		access: {scope: "public"}
		fields: [
			{ordinal: 1, name: "id", type: "uuid", pk: true},
			{ordinal: 2, name: "label", type: "string"},
			{ordinal: 3, name: "old", type: "string", retired: true},
		]
	}
	NoteTag: {
		table: "note_tag"
		access: {scope: "public"}
		fields: [
			{ordinal: 1, name: "id", type: "uuid", pk: true},
			{ordinal: 2, name: "note_id", type: "uuid"},
			{ordinal: 3, name: "label", type: "string"},
		]
	}
	// A two-seat counter machine's surface tables (pronto's mecha-surface parts), as Bonk Chess's
	// match has them: tests/unit/apigen.js gives them a stub machine on PGlite.
	CounterSeat: {table: "counter_seat", access: {scope: "public"}, fields: [
		{ordinal: 1, name: "id", type: "string", pk: true},
		{ordinal: 2, name: "instance_id", type: "uuid"},
		{ordinal: 3, name: "actor", type: "uuid"},
		{ordinal: 4, name: "seat", type: "string"},
		{ordinal: 5, name: "revision", type: "int64"},
		{ordinal: 6, name: "phase", type: "string"},
		{ordinal: 7, name: "view", type: "json"},
	]}
	CounterCommand: {table: "counter_command", access: {scope: "public", write: true}, fields: [
		{ordinal: 1, name: "id", type: "string", pk: true},
		{ordinal: 2, name: "instance_id", type: "uuid"},
		{ordinal: 3, name: "actor", type: "uuid"},
		{ordinal: 4, name: "request", type: "json"},
		{ordinal: 5, name: "revision", type: "int64"},
		{ordinal: 6, name: "outcome", type: "string"},
		{ordinal: 7, name: "reason", type: "string"},
	]}
	CounterOpen: {table: "counter_open", access: {scope: "public", write: true}, fields: [
		{ordinal: 1, name: "id", type: "string", pk: true},
		{ordinal: 2, name: "instance_id", type: "uuid"},
		{ordinal: 3, name: "actor", type: "uuid"},
		{ordinal: 4, name: "kind", type: "string"},
		{ordinal: 5, name: "input", type: "json"},
		{ordinal: 6, name: "outcome", type: "string"},
		{ordinal: 7, name: "reason", type: "string"},
	]}
	CounterPublic: {table: "counter_public", access: {scope: "public"}, fields: [
		{ordinal: 1, name: "id", type: "uuid", pk: true},
		{ordinal: 2, name: "total", type: "int32"},
	]}
}

// The counter machine as program.cue's state.mecha.reducers holds it: only the setup the API
// reads (its version, its events' tiers, its ports).
code: state: mecha: reducers: counter: machine: setup: {
	version: 3
	types: events: {
		add: {tier: "omnishell", payload: {n: "int"}}
		finish: {tier: "omnishell", payload: {}}
		tick: {tier: "mecha", payload: {}}
	}
	ports: {
		admission: {name: "counter_create", id: "instance_id"}
		join: {seats: ["b"], event: "start"}
	}
}
