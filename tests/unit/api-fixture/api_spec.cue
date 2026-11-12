package fixture

api: {
	entities: notes: {
		table: "note"
		fields: {owner: "owner_id", body: "body", stars: "stars"}
		create_time: "created"
		methods: ["get", "list", "create", "update", "delete"]
	}
	entities: tags: {table: "tag", fields: {label: "label"}, methods: ["get", "list"]}
	entities: noteTags: {
		table:  "note_tag"
		view:   "note_tag"
		parent: {collection: "notes", field: "note_id"}
		fields: {label: "label"}
		methods: ["get", "list"]
	}
}
