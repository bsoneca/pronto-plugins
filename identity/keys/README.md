# The keys service

An account's API keys and the door's account check, for an app on a mecha whose auth service has neither (mecha 0.32 serves no `/auth/keys*` and no `/auth/door`; PRONTO-740). It matches the fork's auth service route for route (its README, "API keys"), signs with the stack's secret and reads `mecha_auth.api_key` in place, so no key moves.

Files: [`keys.ts`](keys.ts) (handlers over a `Db`), [`main.ts`](main.ts) (Postgres, the server), [`keys_test.ts`](keys_test.ts) (PGlite).

## Routes

Paths carry their `/auth` prefix, as the auth service's do.

| Route | Answer |
|---|---|
| `GET /auth/door` | Always 204. `X-Pronto-Account` carries the `sub` of a live `app_user` session (HS256 of the stack secret, `exp` ahead), else nothing. For Caddy's `forward_auth`; the door strips a client's own header first. Answers with keys off too. |
| `POST /auth/keys {label, scopes}` | 201 `{id, key, label, scopes, created_at}`; `key` (`pk_live_…`) is shown once, the table keeps its SHA-256. Scopes: `read`, `write`, `machines:<name>`. At most 5 live keys an account (409; a revoke frees one). |
| `GET /auth/keys` | `{keys: [{id, label, scopes, created_at, last_used}]}`, never a key or hash. |
| `DELETE /auth/keys/<id>` | 204; another's key, a revoked one or a non-UUID is 404. Never gated. |
| `POST /auth/key {key}` | `{token, expires_in: 900}`: a user token of the key's owner with `kid`, `scp`, `guest: false` and `iss: "mecha:stack"`. An unknown, revoked or malformed key is the same 401. |

Make, list and revoke take an account's own session: no token or a bad one is 401; a guest (`guest: true`, or `acr: "0"` as 0.32 says it) is 403 `guest`; a key's token is 403 `key token`; an upgraded one (`operation_kind`, `operation_id`, `amr` or `idp`) is 403 `upgraded token`. With `AUTH_API_KEYS` off every key route is 404.

Differences from the fork, each a tightening: the token header must say HS256; guests are read by `acr` as well; the key's token carries `iss`; an exchange's `last_used` and the hook are one transaction, so a hook that throws leaves no use and issues no token; the table is made by the service when keys are on and it is absent.

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

Run it beside the stack, declared as billing's service is (`billing/app/billing_plugin.cue`): a target `keys` with `expose: http: {port: 8702, env: "KEYS_PORT"}`, `deno run --no-config --allow-net --allow-env identity/keys/main.ts` (copy `identity/keys/*.ts` and `identity/broker/vendor/postgres.js` beside the app), `after: migrate: "completed"`, and `PRONTO_UPSTREAM_KEYS: {peer: "keys", port: "http"}` on the door's entrypoint. In the door's Caddyfile:

- Point `/ofrep/`'s `forward_auth` at `{$PRONTO_UPSTREAM_KEYS:keys:8702}` (`uri /auth/door`), not at auth.
- Route `/auth/keys*` and `/auth/key` to it, one path to a `handle`, before `/auth/*` (Caddy sorts a `handle`'s single path longest first; a named matcher of several paths is not sorted).

## Known limit

0.32's tenancy floor does not read a key token's `scp`, so a `read` key is not held to reading through `/crud`. Keep keys behind the gate (the flag off) until the floor enforces `scp`.

Test: `deno test --no-config --allow-net --allow-read --allow-write --allow-env identity/keys`.
