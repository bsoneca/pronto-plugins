// pronto-api's generator (api/generate.ts, PRONTO-313): from a stand-in app's api_spec.cue and
// program.cue (tests/unit/api-fixture/, two entities), the .proto, the routes, the descriptor set
// the service loads, and the append-only fields.lock.cue; buf breaking against the release; and
// the lint that keeps every app's names out of the plugin.
package unit

// Words that belong to an app, which nothing under api/ may name: the apps' names in pronto, and
// Bonk Chess's tables and events the design names (docs/pronto-api.md).
_apiAppWords: [
	"aprende", "birosca", "bonk", "brawl", "battlechess", "chess", "giselle", "guestbook", "mamaco", "openfoodfacts",
	"prontokeep", "prontoweeper", "reclaim", "solitaire", "starfall", "studio", "ume", "rental",
	"player_card", "player_game", "offer_draw", "accept_draw", "decline_draw", "resign",
]

cases: {
	"a two-entity spec generates its services, messages and REST routes, and the service serves them": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]}, {keep: "out"},
		{get: "routes", expect: [
			{method: "GET", path: "/api/v1/notes/{id}", rpc: "fixture.v1.NoteService/GetNote"},
			{method: "GET", path: "/api/v1/notes", rpc: "fixture.v1.NoteService/ListNotes"},
			{method: "POST", path: "/api/v1/notes", rpc: "fixture.v1.NoteService/CreateNote"},
			{method: "DELETE", path: "/api/v1/notes/{id}", rpc: "fixture.v1.NoteService/DeleteNote"},
			{method: "GET", path: "/api/v1/tags/{id}", rpc: "fixture.v1.TagService/GetTag"},
			{method: "GET", path: "/api/v1/tags", rpc: "fixture.v1.TagService/ListTags"},
		]},
		{use: "out"}, {get: "proto", matches: #"package fixture\.v1;"#},
		{use: "out"}, {get: "proto", matches: #"rpc CreateNote\(CreateNoteRequest\) returns \(Note\) \{\n    option \(google\.api\.http\) = \{ post: "/api/v1/notes" body: "\*" \};"#},
		{use: "out"}, {get: "proto", matches: #"message Note \{\n  string id = 1;\n  string owner_id = 2;\n  string body = 3;\n  int32 stars = 4;\n  google\.protobuf\.Timestamp created = 5;\n\}"#, why: "field types from program.cue, numbers from the lock"},
		{use: "out"}, {get: "proto", matches: #"message ListNotesRequest \{\n  string owner_id = 1;\n\}"#, why: "List filters by the spec's read.filter"},
		{use: "out"}, {get: "proto", matches: #"message Tag \{\n  string id = 1;\n  string label = 2;\n\}"#, why: "a retired field is not exported"},
		{call: "apigen.served", args: ["$app"], expect: "served", why: "the descriptor set and routes load in api/service.ts as generated"},
	]}
	"a new field takes a number above every one its message had; a removed field's number is never given again": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 4, name: \"stars\", type: \"int32\"},\n", ""]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 5, name: \"created\"", "{ordinal: 6, name: \"pinned\", type: \"bool\"},\n\t\t\t{ordinal: 5, name: \"created\""]},
		{call: "apigen.generated", args: ["$app"]},
		{get: "lock", holds: {
			fields: Note: {id: 1, owner_id: 2, body: 3, pinned: 6, created: 5}
			retired: Note: {stars: 4}
		}},
	]}
	"a reused field number in fields.lock.cue fails generate": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.edit", args: ["$app", "api/v1/fields.lock.cue", "\"body\": 3", "\"body\": 2"]},
		{call: "apigen.generated", args: ["$app"], throws: "field number 2 reused in Note"},
	]}
	"a field renumbered after its release fails generate": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.release", args: ["$app"]},
		{call: "apigen.edit", args: ["$app", "api/v1/fields.lock.cue", "\"body\": 3", "\"body\": 9"]},
		{call: "apigen.generated", args: ["$app"], throws: "Note.body renumbered: released as 3, fields.lock.cue says 9"},
	]}
	"removing a released field fails buf breaking; an added one does not": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.release", args: ["$app"]},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 5, name: \"created\"", "{ordinal: 6, name: \"pinned\", type: \"bool\"},\n\t\t\t{ordinal: 5, name: \"created\""]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.breaking", args: ["$app"]}, {get: "ok", expect: true},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 4, name: \"stars\", type: \"int32\"},\n", ""]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.breaking", args: ["$app"]}, {keep: "b"},
		{get: "ok", expect: false},
		{use: "b"}, {get: "out", matches: #"Previously present field "4" with name "stars" on message "Note" was deleted"#},
	]}
	"a dropped column an export needs, or a write the entity's access forbids, fails generate": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 2, name: \"owner_id\", type: \"uuid\"},\n", ""]},
		{call: "apigen.generated", args: ["$app"], throws: "api: note has no field owner_id, which the spec's read.filter names"},
		{call: "apigen.app"}, {keep: "other"},
		{call: "apigen.edit", args: ["$other", "api_spec.cue", "{table: \"tag\", read: {}}", "{table: \"tag\", read: {}, write: [\"create\"]}"]},
		{call: "apigen.generated", args: ["$other"], throws: "api: tag's access forbids writes, which the spec exports"},
	]}
	"nothing under api/ names an app, and a name planted there is caught": {suite: "api", steps: [
		{call: "apigen.linted", args: [_apiAppWords], expect: []},
		{call: "apigen.linted", args: [_apiAppWords, "player_card"], expect: [{file: "planted.ts", word: "player_card"}]},
	]}
}
