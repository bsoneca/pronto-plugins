// pronto-api's generator (api/generate.ts, PRONTO-324): from a stand-in app's api_spec.cue and
// program.cue (tests/unit/api-fixture/, three entities), the api_v1 views run on PGlite as the
// fixture's users, the door's routes in caddy in front of a stand-in PostgREST, the contract held
// to its release, and the lint that keeps every app's names, and the dropped gRPC words, out of
// the plugin.
package unit

import "list"

// Words that belong to an app, which nothing under api/ may name: the apps' names in pronto, and
// Bonk Chess's tables and events the design names (docs/pronto-api.md).
_apiAppWords: [
	"aprende", "birosca", "bonk", "brawl", "battlechess", "chess", "giselle", "guestbook", "mamaco", "openfoodfacts",
	"prontokeep", "prontoweeper", "reclaim", "solitaire", "starfall", "studio", "ume", "rental",
	"player_card", "player_game", "offer_draw", "accept_draw", "decline_draw", "resign",
]

// What the plugin no longer is (PRONTO-374): nothing under api/ speaks of it.
_apiWireWords: ["proto", "protobuf", "buf", "grpc", "connect", "descriptor"]

_ada: "0b0b0b0b-0000-4000-8000-00000000000a"
_bob: "0b0b0b0b-0000-4000-8000-00000000000b"
_n1:  "0b0b0b0b-0000-4000-8000-0000000000a1"
_n2:  "0b0b0b0b-0000-4000-8000-0000000000a2"

cases: {
	"each exported entity is a typed view in api_v1 with name, its public fields and etag, granted to app_user only": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.files", args: ["$app"]}, {keep: "f"},
		{get: "sql", matches: #"CREATE OR REPLACE VIEW "api_v1"\."note" WITH \(security_invoker = true\) AS\n  SELECT \('notes/' \|\| t\."id"::text\) AS "name",\n         md5\(row\(t\."id", t\."body", t\."owner_id", t\."stars", t\."created"\)::text\) AS "etag",\n         t\."id" AS "id",\n         t\."body" AS "body",\n         t\."owner_id" AS "owner",\n         t\."stars" AS "stars",\n         t\."created" AS "create_time"\n  FROM public\."note" t;\nREVOKE ALL ON "api_v1"\."note" FROM PUBLIC, anon;\nGRANT SELECT, INSERT \("id", "body", "owner", "stars"\), UPDATE \("body", "owner", "stars"\), DELETE ON "api_v1"\."note" TO app_user;\nALTER VIEW "api_v1"\."note" ALTER COLUMN "create_time" SET DEFAULT now\(\);"#},
		{use: "f"}, {get: "sql", matches: #"GRANT SELECT ON "api_v1"\."tag" TO app_user;"#, why: "a read-only resource grants no write"},
		{use: "f"}, {get: "sql", matches: #"\('notes/' \|\| t\."note_id"::text\) AS "parent""#, why: "a nested resource is named under its parent"},
		{call: "apigen.db", args: ["$app"]}, {keep: "db"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT name, label FROM api_v1.tag ORDER BY name"], expect: [
			{name: "tags/0b0b0b0b-0000-4000-8000-0000000000f1", label: "red"},
			{name: "tags/0b0b0b0b-0000-4000-8000-0000000000f2", label: "blue"},
		]},
		{call: "apigen.as", args: ["$db", _ada, "SELECT * FROM api_v1.tag WHERE old IS NULL"], throws: "42703", why: "a retired field is not in the view"},
		{call: "apigen.as", args: ["$db", "anon", "SELECT 1 FROM api_v1.tag"], throws: "42501", why: "anon has nothing in api_v1, though it may read the table"},
	]}
	"Create, Get, List, Update and Delete go through the view as the caller, and RLS shows a user only their own rows": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.db", args: ["$app"]}, {keep: "db"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, body, stars) VALUES ($1, 'first', 3) RETURNING name, owner, stars", [_n1]], expect: [{name: "notes/" + _n1, owner: _ada, stars: 3}], why: "Create with the client's id, the owner from the caller"},
		{call: "apigen.as", args: ["$db", _bob, "INSERT INTO api_v1.note (id, body) VALUES ($1, 'bob''s') RETURNING name", [_n2]], expect: [{name: "notes/" + _n2}]},
		{call: "apigen.as", args: ["$db", _ada, "SELECT name, body FROM api_v1.note WHERE name = $1", ["notes/" + _n1]], expect: [{name: "notes/" + _n1, body: "first"}], why: "Get by name"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT name FROM api_v1.note WHERE name > '' ORDER BY name LIMIT 50"], expect: [{name: "notes/" + _n1}], why: "List: ada's notes, not bob's"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT name FROM api_v1.note WHERE name = $1", ["notes/" + _n2]], expect: [], why: "bob's note by name is no row (PostgREST's 406), never says which"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT etag FROM api_v1.note WHERE name = $1", ["notes/" + _n1]]}, {get: "0.etag"}, {keep: "e"},
		{call: "apigen.as", args: ["$db", _ada, "UPDATE api_v1.note SET body = 'edited' WHERE name = $1 AND etag = 'stale' RETURNING body", ["notes/" + _n1]], expect: [], why: "a stale If-Match matches no row"},
		{call: "apigen.as", args: ["$db", _ada, "UPDATE api_v1.note SET body = 'edited' WHERE name = $1 AND etag = $2 RETURNING body, etag <> $2 AS changed", ["notes/" + _n1, "$e"]], expect: [{body: "edited", changed: true}], why: "the current etag matches, and the write changes it"},
		{call: "apigen.as", args: ["$db", _ada, "UPDATE api_v1.note SET body = 'again' WHERE name = $1 AND etag = $2 RETURNING body", ["notes/" + _n1, "$e"]], expect: [], why: "the etag read before the write is stale after it"},
		{call: "apigen.as", args: ["$db", _ada, "UPDATE api_v1.note SET body = 'mine now' WHERE name = $1 RETURNING body", ["notes/" + _n2]], expect: [], why: "bob's row is not ada's to write"},
		{call: "apigen.as", args: ["$db", _ada, "DELETE FROM api_v1.note WHERE name = $1 RETURNING name", ["notes/" + _n1]], expect: [{name: "notes/" + _n1}]},
		{call: "apigen.as", args: ["$db", _bob, "SELECT count(*)::int AS n FROM api_v1.note"], expect: [{n: 1}]},
	]}
	"a write the table forbids is refused as the caller: RLS 42501, a CEL check 23514, a read-only field or the key 42501": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.db", args: ["$app"]}, {keep: "db"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, owner, body) VALUES ($1, $2, 'as bob')", [_n1, _bob]], throws: "42501", why: "RLS's WITH CHECK: ada cannot write a note as bob"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, stars) VALUES ($1, 9)", [_n1]], throws: "23514"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, create_time) VALUES ($1, now())", [_n1]], throws: "42501", why: "a stamp is not granted"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id) VALUES ($1)", [_n1]]},
		{call: "apigen.as", args: ["$db", _ada, "UPDATE api_v1.note SET id = $1 WHERE name = $2", [_n2, "notes/" + _n1]], throws: "42501", why: "the key is not updated"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.tag (id, label) VALUES ($1, 'x')", [_n1]], throws: "42501", why: "tags export no Create"},
	]}
	"the door rewrites each route onto its view and drops the client's query grammar, Prefer and profile": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.door", args: ["$app"]}, {keep: "d"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes/abc?select=*,secret&or=(a.eq.1)", {Prefer: "count=exact", "Accept-Profile": "public"}], holds: {status: 200, seen: {method: "GET", path: "/note", query: "?name=eq.notes/abc", accept_profile: "api_v1", content_profile: null, prefer: null, accept: "application/vnd.pgrst.object+json"}}},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes?page_size=20&after=notes/abc&select=body"], holds: {status: 200, seen: {path: "/note", query: "?order=name.asc&name=gt.notes%2Fabc&limit=20", accept: "application/json"}}},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes?page_size=999"], holds: {status: 200, seen: {query: "?order=name.asc&name=gt.&limit=50"}}, why: "a page_size out of 1 to 200 is the default"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes?after=x%26select%3Dbody"], holds: {status: 404, seen: null}, why: "a cursor that is not a name never reaches PostgREST"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes/n_1/noteTags?page_size=5"], holds: {status: 200, seen: {path: "/note_tag", query: "?order=name.asc&name=gt.&parent=eq.notes/n_1&limit=5"}}, why: "a child list filters on its parent, so an id's _ is no wildcard"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes/n1/noteTags/t1", {Range: "0-0", "Range-Unit": "items"}], holds: {status: 200, seen: {path: "/note_tag", query: "?name=eq.notes/n1/noteTags/t1", range: null}}},
		{call: "apigen.call", args: ["$d", "POST", "/api/v1/notes/n1/noteTags"], holds: {status: 404, seen: null}, why: "a nested resource exports no Create yet"},
		{call: "apigen.call", args: ["$d", "POST", "/api/v1/notes?columns=owner", {Prefer: "resolution=merge-duplicates", "Content-Type": "text/csv"}], holds: {status: 200, seen: {method: "POST", path: "/note", query: "", content_profile: "api_v1", accept_profile: "api_v1", prefer: "return=representation", content_type: "application/json"}}},
		{call: "apigen.call", args: ["$d", "PATCH", "/api/v1/notes/abc", {"If-Match": "\"0123456789abcdef0123456789abcdef\""}], holds: {status: 200, seen: {method: "PATCH", query: "?name=eq.notes/abc&etag=eq.0123456789abcdef0123456789abcdef", prefer: "return=representation"}}},
		{call: "apigen.call", args: ["$d", "PATCH", "/api/v1/notes/abc"], holds: {status: 200, seen: {query: "?name=eq.notes/abc"}}},
		{call: "apigen.call", args: ["$d", "PATCH", "/api/v1/notes/abc", {"If-Match": "x&select=body"}], holds: {status: 404, seen: null}},
		{call: "apigen.call", args: ["$d", "DELETE", "/api/v1/notes/abc"], holds: {status: 200, seen: {method: "DELETE", query: "?name=eq.notes/abc", prefer: "return=minimal"}}},
		{call: "apigen.call", args: ["$d", "DELETE", "/api/v1/tags/x"], holds: {status: 404, seen: null}, why: "tags export no Delete"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/note?id=eq.x"], holds: {status: 404, seen: null}, why: "a view by its own name is not a route"},
		{call: "apigen.call", args: ["$d", "GET", "/api/v1/notes/a%26b"], holds: {status: 404, seen: null}, why: "an id that could start a filter is no route"},
		{call: "apigen.stopped", args: ["$d"]},
	]}
	"the contract lists every resource, field, type and route, and openapi.json documents the routes": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]}, {keep: "out"},
		{get: "contract.routes", expect: [
			{method: "GET", path: "/api/v1/notes"},
			{method: "POST", path: "/api/v1/notes"},
			{method: "DELETE", path: "/api/v1/notes/{note}"},
			{method: "GET", path: "/api/v1/notes/{note}"},
			{method: "PATCH", path: "/api/v1/notes/{note}"},
			{method: "GET", path: "/api/v1/notes/{note}/noteTags"},
			{method: "GET", path: "/api/v1/notes/{note}/noteTags/{note_tag}"},
			{method: "GET", path: "/api/v1/tags"},
			{method: "GET", path: "/api/v1/tags/{tag}"},
		]},
		{use: "out"}, {get: "contract.resources.2", expect: {collection: "tags", fields: [{name: "name", type: "string", writable: false}, {name: "etag", type: "string", writable: false}, {name: "id", type: "uuid", writable: true}, {name: "label", type: "string", writable: true}], methods: ["get", "list"]}},
		{call: "apigen.files", args: ["$app"]}, {get: "openapi", matches: #""/api/v1/notes/\{note\}": \{"#},
	]}
	"removing or retyping a released field fails the check; adding one does not, and its view replays over the release's": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.db", args: ["$app"]}, {keep: "db"},
		{call: "apigen.release", args: ["$app"]},
		{call: "apigen.checked", args: ["$app"], expect: []},
		{call: "apigen.edit", args: ["$app", "api_spec.cue", "fields: {label: \"label\"}, methods", "fields: {label: \"label\", color: \"old\"}, methods"]},
		{call: "apigen.edit", args: ["$app", "program.cue", "name: \"old\", type: \"string\", retired: true", "name: \"old\", type: \"string\""]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.checked", args: ["$app"], expect: [], why: "a new field is additive"},
		{call: "apigen.files", args: ["$app"]}, {get: "sql", matches: #"t\."created" AS "create_time"\n  FROM public\."note" t;"#, why: "a released view keeps its columns' order"},
		{call: "apigen.files", args: ["$app"]}, {get: "sql", matches: #"t\."label" AS "label",\n         t\."old" AS "color"\n  FROM public\."tag" t;"#, why: "a new column goes last"},
		{call: "apigen.replayed", args: ["$db", "$app"], expect: "replayed", why: "CREATE OR REPLACE VIEW takes a column added at the end"},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 4, name: \"stars\", type: \"int32\"}", "{ordinal: 4, name: \"stars\", type: \"string\"}"]},
		{call: "apigen.edit", args: ["$app", "api_spec.cue", "methods: [\"get\", \"list\", \"create\", \"update\", \"delete\"]", "methods: [\"get\", \"list\", \"create\", \"update\"]"]},
		{call: "apigen.edit", args: ["$app", "api_spec.cue", "fields: {label: \"label\", color: \"old\"}, methods", "fields: {color: \"old\"}, methods"]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.checked", args: ["$app"], expect: [
			"notes: method delete removed",
			"notes.stars retyped: released as int32, now string",
			"tags.label removed",
			"route DELETE /api/v1/notes/{note} removed",
		]},
	]}
	"a dropped column the spec names, a write the entity's access forbids, or a machine fails generate": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.edit", args: ["$app", "program.cue", "{ordinal: 2, name: \"owner_id\", type: \"uuid\"},\n", ""]},
		{call: "apigen.generated", args: ["$app"], throws: "api: note has no field owner_id, which the spec's notes.owner names"},
		{call: "apigen.app"}, {keep: "other"},
		{call: "apigen.edit", args: ["$other", "api_spec.cue", "fields: {label: \"label\"}, methods: [\"get\", \"list\"]", "fields: {label: \"label\"}, methods: [\"get\", \"create\"]"]},
		{call: "apigen.generated", args: ["$other"], throws: "api: tag's access forbids writes, which the spec's tags exports"},
		{call: "apigen.app"}, {keep: "third"},
		{call: "apigen.edit", args: ["$third", "api_spec.cue", "api: {", "api: {\n\tmachines: games: {}"]},
		{call: "apigen.generated", args: ["$third"], throws: "api: machines are exported with PRONTO-314"},
		{call: "apigen.app"}, {keep: "fourth"},
		{call: "apigen.edit", args: ["$fourth", "api_spec.cue", "fields: {label: \"label\"}\n\t\tmethods: [\"get\", \"list\"]", "fields: {label: \"label\"}\n\t\tmethods: [\"get\", \"create\"]"]},
		{call: "apigen.generated", args: ["$fourth"], throws: "api: noteTags is nested; its Create and Update come with the parent from the path"},
		{call: "apigen.app"}, {keep: "fifth"},
		{call: "apigen.edit", args: ["$fifth", "api_spec.cue", "fields: {owner: \"owner_id\"", "fields: {etag: \"owner_id\""]},
		{call: "apigen.generated", args: ["$fifth"], throws: "etag"},
	]}
	"the spec's flag gates every view per account: off, a view is empty and refuses a write; the keys and PostgREST follow": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.edit", args: ["$app", "api_spec.cue", "api: {", "api: {\n\tflag: \"api_export\""]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.files", args: ["$app"]}, {get: "sql", matches: #"WITH \(security_invoker = true, check_option = local\) AS[\s\S]*FROM public\."note" t\n  WHERE api_private\.api_on\(public\.auth_uid\(\)\);"#},
		{call: "apigen.db", args: ["$app"]}, {keep: "db"},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, body) VALUES ($1, 'off')", [_n1]], throws: "44000", why: "off for ada: the view's check option refuses her write"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT count(*)::int AS n FROM api_v1.tag"], expect: [{n: 0}], why: "off, every view is empty to her"},
		{call: "apigen.flagOn", args: ["$db", _ada]},
		{call: "apigen.as", args: ["$db", _ada, "INSERT INTO api_v1.note (id, body) VALUES ($1, 'on') RETURNING name, create_time IS NOT NULL AS stamped", [_n1]], expect: [{name: "notes/" + _n1, stamped: true}], why: "on, she writes, and the view stamps create_time (the table has no default)"},
		{call: "apigen.as", args: ["$db", _ada, "SELECT count(*)::int AS n FROM api_v1.tag"], expect: [{n: 2}]},
		{call: "apigen.as", args: ["$db", _bob, "SELECT count(*)::int AS n FROM api_v1.tag"], expect: [{n: 0}], why: "per account: still off for bob"},
		{call: "apigen.as", args: ["$db", _bob, "SELECT pronto_flags.flag_on('api_export', $1) AS on", [_ada]], throws: "42501", why: "the gate reads the flags as their owner; the caller cannot"},
		{call: "apigen.exported", args: ["$app", "code.capabilities.auth.apiKeysGate"], expect: "api_private.api_on", why: "the auth service asks the same gate for keys"},
		{call: "apigen.exported", args: ["$app", "cluster.capabilities.apiSchemas"], expect: ["api_v1"], why: "PostgREST serves api_v1 after public"},
		{call: "apigen.edit", args: ["$app", "api_spec.cue", "api: {", "api: {\n\tentities: categories: {table: \"tag\", fields: {label: \"label\"}, methods: [\"get\"]}"]},
		{call: "apigen.generated", args: ["$app"]},
		{call: "apigen.files", args: ["$app"]}, {get: "sql", matches: #"VIEW "api_v1"\."category" "#, why: "a collection in -ies is a view in -y"},
	]}
	"generate's route puts the API's block before /auth, after the other plugins' blocks, once however often it runs": {suite: "api", steps: [
		{call: "apigen.app"}, {keep: "app"},
		{call: "apigen.caddyRouted", args: ["$app"]}, {keep: "c"},
		{get: "once", matches: #"  # flags:end\n  # pronto-api:begin[^\n]*\n  request_header -Accept-Profile\n  request_header -Content-Profile\n  handle /api/v1/\* \{\n    route \{[\s\S]*\n  \}\n  # pronto-api:end\n  # The auth service\.\n  handle /auth/\*"#},
		{call: "apigen.caddyRouted", args: ["$app"]}, {get: "twice", matches: #"^(?:(?!pronto-api:begin)[\s\S])*pronto-api:begin(?:(?!pronto-api:begin)[\s\S])*$"#, why: "a second route replaces its block, never adds one"},
	]}
	"pronto-api installs its plugin, generator and rules, and seeds the spec once": {suite: "api", steps: [
		{call: "apigen.installed"}, {keep: "i"},
		{get: "first", expect: ["pronto-api: wrote api_plugin.cue", "pronto-api: wrote pronto/api.cue", "pronto-api: wrote api/generate.ts", "pronto-api: wrote api_spec.cue"]},
		{call: "apigen.installed", holds: {again: [], spec: "package fixture\n\napi: entities: {}\n", plugin: "package fixture", generator: "// copied by pronto-api from api/generate.ts — do not edit"}, why: "a second install writes nothing; the app's spec is its own"},
		{call: "apigen.installed"}, {get: "rules", matches: #""api-generate": \{"priority":0,[\s\S]*"api-route": \{"priority":4,"#},
	]}
	"nothing under api/ names an app or the dropped wire formats, and a name planted there is caught": {suite: "api", steps: [
		{call: "apigen.linted", args: [list.Concat([_apiAppWords, _apiWireWords])], expect: []},
		{call: "apigen.linted", args: [_apiAppWords, "player_card"], expect: [{file: "planted.ts", word: "player_card"}]},
		{call: "apigen.linted", args: [_apiWireWords, "grpc"], expect: [{file: "planted.ts", word: "grpc"}]},
	]}
}
