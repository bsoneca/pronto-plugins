# The keys service

An account's API keys and the door's account check, for an app on a mecha whose auth service has neither (mecha 0.32 serves no `/auth/keys*` and no `/auth/door`; PRONTO-740). It matches the fork's auth service route for route (its README, "API keys"), signs with the stack's secret and reads `mecha_auth.api_key` in place, so no key moves.

Files: [`keys.ts`](keys.ts) (handlers over a `Db`), [`main.ts`](main.ts) (Postgres, the server), [`route.ts`](route.ts) (the door's routes), [`install.ts`](install.ts) and [`app/`](app) (what an app gets), [`keys_test.ts`](keys_test.ts) (PGlite) and [`route_test.ts`](route_test.ts).

## Routes

Paths carry their `/auth` prefix, as the auth service's do.

| Route | Answer |
|---|---|
| `GET /auth/door` | Always 204. `X-Pronto-Account` carries the `sub` of a live `app_user` session (HS256 of the stack secret, `exp` ahead), else nothing. For Caddy's `forward_auth`; the door strips a client's own header first. Answers with keys off too. |
| `POST /auth/keys {label, scopes}` | 201 `{id, key, label, scopes, created_at}`; `key` (`pk_live_…`) is shown once, the table keeps its SHA-256. Scopes: `read`, `write`, `machines:<name>`. At most 5 live keys an account (409; a revoke frees one). |
| `GET /auth/keys` | `{keys: [{id, label, scopes, created_at, last_used}]}`, never a key or hash. |
| `DELETE /auth/keys/<id>` | 204; another's key, a revoked one or a non-UUID is 404. Never gated. |
| `GET /auth/keyguard` | 403 `key token` for a key's token, else 204. For the door's `forward_auth` before 0.32's other `/auth/*` paths (see Adopting it). |
| `POST /auth/key {key}` | `{token, expires_in: 900}`: a user token of the key's owner with `kid`, `scp`, `guest: false` and `iss: "mecha:stack"`. An unknown, revoked or malformed key is the same 401. |

Make, list and revoke take an account's own session: no token or a bad one is 401; a guest (`guest: true`, or `acr: "0"` as 0.32 says it) is 403 `guest`; a key's token is 403 `key token`; an upgraded one (`operation_kind` or `operation_id`; not `amr`, which every 0.32 passkey session carries) is 403 `upgraded token`. With `AUTH_API_KEYS` off every key route is 404.

Differences from the fork, each a tightening: the token header must say HS256; guests are read by `acr` as well; the key's token carries `iss`; an exchange's `last_used` and the hook are one transaction, so a hook that throws leaves no use and issues no token; a key revoked while it is exchanged gets no token; bodies are held to 4 KB; answers carry `cache-control: no-store`; the table is made by the service when keys are on and it is absent (never replaced where it exists).

## Environment

| Variable | |
|---|---|
| `PGRST_JWT_SECRET` | the stack's HS256 secret, the auth service's own (required). Not crud's, which becomes a JWKS where `issuers` is on. |
| `DATABASE_URL` | Postgres as the database owner (required). 0.32's auth revokes every other grant on `mecha_auth` each time it starts, so no lesser role can read the table. |
| `AUTH_API_KEYS` | `true` turns the key routes on; unset or `false`, 404. Any other value stops the service. |
| `AUTH_API_KEYS_GATE` | `schema.name(owner uuid) returns boolean`, asked for the caller on make and list and for the key's owner on exchange; false is 404. |
| `AUTH_KEY_EXCHANGED_HOOK` | `schema.name(owner uuid) returns void`, called on every exchange after the gate, before the token. |
| `MECHA_DB_SCHEMA`, `MECHA_SCHEMA` | where `app_user` and `rls_exempt` are (`public`, `mecha`). |
| `AUTH_STATEMENT_TIMEOUT_MS` | optional statement bound. |
| `KEYS_PORT` (or `PORT`), `SAYT_PLATFORM` | the port (default 8702); `local` or `host` binds 127.0.0.1. |

It keeps no secret of its own: the signing secret and `DATABASE_URL` are the stack's.

## Adopting it

```sh
<this repo>/bin/pronto-keys <app-dir>   # then the app's generate, and commit what it writes
```

It writes, regenerated each time: `keys_plugin.cue` (the `keys` target on 8702 beside the stack, the door's `PRONTO_UPSTREAM_KEYS`), `pronto/keys.cue` (the generate step `keys-route`, priority 6, after pronto's writer), `keys/` (the service and `route.ts`, which the step runs). The step splices one block into `docker/Caddyfile`, taken out and put back on every run: `# keys-routes:begin` … `# keys-routes:end`, the first lines of the app's own top-level `handle /auth/*`, ahead of its `reverse_proxy` to auth:

- `forward_auth … { uri /auth/keyguard }`, which answers 403 for a key's token and 204 for anything else: 0.32's auth takes a key's token as a session and its rename answers a new session without `kid`, so without the guard a key could make keys of its own that outlive it. It runs ahead of the nested `handle` and of the handle's `reverse_proxy` (forward_auth runs first), so it covers every `/auth/*` path that handle takes.
- a nested `handle` of `/auth/keys*` and `/auth/key` to the service; the other `/auth/*` paths fall through to the auth service.

Everything is inside that one handle, never a top-level route of its own (not a `handle`, not a `forward_auth @matcher`): Caddy sorts those by path with a comparison that is not transitive, in each site block the app is imported into, so one more reorders the app's other handles (Bonk Chess: the reading-more handles, `/armies` in es answered English and `/puzzle/today` 404). The test adapts a door in its three site blocks with and without the block (`CADDY`) and requires every block's route sequence unchanged. An app without a top-level `handle /auth/*` is refused. The first version's top-level `# keys:begin` … `# keys:end` guard is taken out where an app still has it.

The app sets, in its own CUE beside them: `keysGate: "schema.name"` (AUTH_API_KEYS_GATE), `keysHook: "schema.name"` (AUTH_KEY_EXCHANGED_HOOK) and `keysDb` (the database a launch at hand is made in, by default the package's name).

With the plugin installed, pronto-flags' route (`flags/app/flags.nu`) sends `/ofrep/`'s `forward_auth` to `{$PRONTO_UPSTREAM_KEYS:keys:8702}` `/auth/door` in place of the auth service, with no Dapr header; the keys plugin's `pronto/keys.cue` is what it looks for.

The door depends on the service: with it down every `/auth/*` answers 502. A release needs it as a sidecar beside the door (`PRONTO_UPSTREAM_KEYS`, and `DATABASE_URL` as the auth service's `AUTH_DATABASE_URL` and `PGRST_JWT_SECRET` as secrets), which this plugin does not write.

## Known limit

0.32's tenancy floor does not read a key token's `scp`, so a `read` key is not held to reading through `/crud`. Keep keys behind the gate (the flag off) until the floor enforces `scp`.

Test: `deno test --no-config --allow-net --allow-read --allow-write --allow-env --allow-run identity/keys` and `./saytw --script tools.nu nu flags/test/route_test.nu`.
