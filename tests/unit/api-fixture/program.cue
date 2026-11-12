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
}
