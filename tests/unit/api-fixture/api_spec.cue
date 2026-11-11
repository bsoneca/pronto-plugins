package fixture

api: {
	package: "fixture"
	entities: note: {table: "note", read: {filter: ["owner_id"]}, write: ["create", "delete"]}
	entities: tag: {table: "tag", read: {}}
}
