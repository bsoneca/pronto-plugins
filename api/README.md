# api

pronto-api (design: [`docs/pronto-api.md`](../docs/pronto-api.md)): an app's entities exported as
a REST/JSON API that is PostgREST over typed views, with no service and no translation code.

## Installing it (PRONTO-325)

```sh
bin/pronto-api <app-dir>         # adds or refreshes the plugin; the app's api_spec.cue is seeded once
bin/pronto-api check <app-dir>   # the contract against the last release's, additive only
```

It writes `api_plugin.cue` (the schema and the contract; it also sets the cluster's
`capabilities.apiSchemas`, so PostgREST serves `api_v1` after `public`, and the auth service's
`apiKeysGate` to the flag's gate unless the app names its own), `pronto/api.cue` (two generate
rules: `api-generate` before pronto's writer, `api-route` after it) and `api/generate.ts`, a copy
of the generator they run. The app then:

- lists `{name: "<NNN>_api_v1.sql", src: "api/v1/api_v1.sql"}` among its `rawMigrations`, after
  its flags' SQL (the gate calls `pronto_flags.flag_on_strict`, which fails closed on a broken rule);
- declares the spec's flag (`api_export`, default `false`, local `true`) in `flags_spec.cue`.

The door carries the block always (Caddy's file is baked at generate time, so nothing could mount
it per flag); the flag is decided per request, in the database. With `api.flag` set, every view
reads `WHERE api_private.api_on(auth_uid())` with a local check option: off for an account, the
API is empty to it (a `Get` is `406`) and refuses its writes (`44000`, PostgREST's `403`), and the
auth service makes, lists and exchanges none of its keys. `pronto-flags push` turns it on, per
account or for everyone, with no deploy. The block also strips `Accept-Profile` and
`Content-Profile` from every request, so `/crud` stays on `public`.

## The generator (PRONTO-324)

[`generate.ts`](generate.ts) turns an app's `api_spec.cue` and `program.cue` into its API, through
[`app/api_plugin.cue`](app/api_plugin.cue)'s `#Api` schema and `apiContract`. The spec names each
exported resource by its collection, the table it reads, its public fields and its methods; types,
the key and whether the entity may be written come from the program, so a spec naming a field the
entity lacks (a dropped column), a write its access forbids, or a machine's server-only event
fails generate, saying which.

```cue
api: entities: notes: {
	table:       "note"
	fields:      {owner: "owner_id", body: "body", stars: "stars"} // public name: program field
	create_time: "created"                                         // read-only stamps
	methods: ["get", "list", "create", "update", "delete"]
}
api: entities: noteTags: {table: "note_tag", parent: {collection: "notes", field: "note_id"}, fields: {label: "label"}, methods: ["get", "list"]}
```

It writes:

| File | What |
| --- | --- |
| `api/v1/api_v1.sql` | schema `api_v1`: per resource a `security_invoker` view (`name`, the key as `id` unless a field names it, the public fields, the stamps, `etag`), `SELECT` and the exported writes granted to `app_user` column by column, nothing to `PUBLIC` or `anon`. Replayed by every release; `CREATE OR REPLACE VIEW` refuses a dropped, renamed or retyped column |
| `api_door.cue` | `apiDoor`: the routes, the Caddyfile block (`handle /api/v1/*`) that rewrites each onto its view, and the headers the `/crud` block strips (`Accept-Profile`, `Content-Profile`) |
| `api/v1/openapi.json` | OpenAPI 3.1 for the routes, PostgREST's error body |
| `api/v1/contract.json` | every resource, field, type and route, sorted |

`generate.ts check <app>` holds `contract.json` to `api/v1/released.json`, the last release's: a
resource, method, route or field removed, or a field retyped, fails it; an addition does not.

A view's columns keep the order of the last release (`released.json`) and new ones go last, since
`CREATE OR REPLACE VIEW` only adds columns at the end. `etag` hashes the public fields only. A nested
resource has a `parent` column (`notes/{note}`), which its List filters on; its Create and Update
(the parent taken from the path) are not built yet, and a spec exporting them fails generate.

Views stay auto-updatable: a public field is a plain column reference, so Postgres maps a write
back onto the table, and the table's RLS and CHECK constraints judge it as the caller. A stamp is
not granted (a Create sets it to `now()`, the view's default, so the table needs none), and the key
is not granted for `UPDATE`, so writing either is `42501`.

The door builds every PostgREST query itself from the route: `GET /api/v1/notes/{id}` becomes
`GET /note?name=eq.notes/{id}` with the singular `Accept`, a List
`?order=name.asc&name=gt.{after}&limit={page_size}` (1 to 200, else 50), `PATCH` with `If-Match`
adds `etag=eq.…`. The client's query, `Prefer` and profile headers never reach PostgREST; an id or
cursor that could start a filter, and every path not generated, is `404`.

## Machines (PRONTO-314, v1)

```cue
api: machines: counters: {
	machine: "counter"              // program.cue's state.mecha.reducers.counter
	events: ["add", "finish"]       // POST /api/v1/counters/{counter}:add; each tier omnishell
	opens: ["create", "join"]       // POST /api/v1/counters?counter_id={uuid}, POST {counter}:join
	public: {total: "total"}        // GET /api/v1/counters, over counter_public
}
```

A machine is exported over its surface tables (`<machine>_seat`, `_command`, `_open`, `_public`)
and runs exactly as it does for the browser. Per machine, `api_v1.sql` has:

| View | What |
| --- | --- |
| `<view>` | `Get`: the caller's seat (`name`, `etag` = the revision, `seat`, `phase`, `view`) |
| `<view>_public` | `List`, over the public table |
| `<view>_command` | an event: an INSTEAD OF INSERT trigger (`api_private.<view>_command`) takes `payload`, `etag` and `request_id`, inserts the machine's command (`{room}/{etag}/{seat}/{event}/{request_id}`), reads back what the machine's AFTER trigger stamped and answers `outcome`, `reason` and the next `etag` |
| `<view>_open` | Create and `:join`, the same way over the open table (`{room}/{kind}/{request_id}`) |

The room's name and the event come from the door, in `X-Api-Name` and `X-Api-Event` (stripped from
every request first). A retry with the same `request_id` and body is the stored row; another body
is `PT409 idempotency_conflict`. A rejection raises and rolls back, so nothing is stored:
`stale_revision` is `PT409`, any other reason `P0001` with the reason in `DETAIL`. No seat, or an
event the spec does not export, is `PT404`. The cases run a stand-in counter machine on PGlite
(`tests/unit/apigen.js`), since a real machine's step function is plv8. A plain insert answering
in one call (PRONTO-392) and the `machines:{name}` scope with guest refusal (PRONTO-393) come later.

[`lint.ts`](lint.ts) keeps every app's name, and the wire formats this plugin no longer is, out of
`api/`. The words are the cases' data (`tests/unit/api_generate.cue`).

Its cases are `tests/unit/api_generate.cue`, on the stand-in app `tests/unit/api-fixture/`: the views
on PGlite as two users, the door in caddy in front of a stand-in PostgREST, the contract check and
the lint. They need cue and caddy, on PATH or as `CUE` and `CADDY`.

```sh
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- api
```
