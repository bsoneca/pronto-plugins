# api

pronto-api (design: [`docs/pronto-api.md`](../docs/pronto-api.md)): an app's entities exported as
a REST/JSON API that is PostgREST over typed views, with no service and no translation code. Nothing
installs it yet: the installer and guestbook come with PRONTO-325, machines with PRONTO-314.

## The generator (PRONTO-324)

[`generate.ts`](generate.ts) turns an app's `api_spec.cue` and `program.cue` into its API, through
[`app/api_plugin.cue`](app/api_plugin.cue)'s `#Api` schema and `apiContract`. The spec names each
exported resource by its collection, the table it reads, its public fields and its methods; types,
the key and whether the entity may be written come from the program, so a spec naming a field the
entity lacks (a dropped column), a write its access forbids, or a machine fails generate, saying
which.

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
cast and not granted, and the key is not granted for `UPDATE`, so writing either is `42501`.

The door builds every PostgREST query itself from the route: `GET /api/v1/notes/{id}` becomes
`GET /note?name=eq.notes/{id}` with the singular `Accept`, a List
`?order=name.asc&name=gt.{after}&limit={page_size}` (1 to 200, else 50), `PATCH` with `If-Match`
adds `etag=eq.…`. The client's query, `Prefer` and profile headers never reach PostgREST; an id or
cursor that could start a filter, and every path not generated, is `404`.

[`lint.ts`](lint.ts) keeps every app's name, and the wire formats this plugin no longer is, out of
`api/`. The words are the cases' data (`tests/unit/api_generate.cue`).

Its cases are `tests/unit/api_generate.cue`, on the stand-in app `tests/unit/api-fixture/`: the views
on PGlite as two users, the door in caddy in front of a stand-in PostgREST, the contract check and
the lint. They need cue and caddy, on PATH or as `CUE` and `CADDY`.

```sh
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- api
```
