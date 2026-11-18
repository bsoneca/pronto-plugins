# Leaving the forks (PRONTO-742)

Goal: every app pins bonisoft3 releases of bayt, sayt, pronto, mecha and omnishell, and
bsoneca/pronto-fork, mecha-fork and omnishell-fork are archived. bayt and sayt are already
upstream releases. This is the phase 0 inventory (PRONTO-743), measured 2026-11-18 against
upstream's latest: pronto v1.5.1, mecha v0.26.0, omnishell v0.25.2.

Bins: **A** upstream has it (drop) · **B** goes upstream (the owner opens the PR) ·
**C** ours (moves to pronto-plugins or the app, through an upstream hook) · **D** owner decides ·
**X** fork machinery (drop with the fork).

## Where each fork stands

| Fork | Live | Base | Own commits | Changes | A | B | C | D | X |
|---|---|---|---|---|---|---|---|---|---|
| omnishell | 0.25.0-fork.2 (`fbba6b9`) | v0.25.0 | 61 | 31 | 8 | 17 | 2 | 4 | 0 |
| mecha | 0.25.1-host.2 (`30c374c`) | v0.25.1 | 71 | 26 | 3 | 11 | 1 | 11 | 0 |
| pronto | v1.4.1-gcp.2 (`70da285`) | v1.4.1 | 445 | 61 | 8 | 29 | 11 | 6 | 4 |

Counts are rows (logical changes); a mixed row counts in its first-named bin. Pronto rows marked
"verify" were judged from greps, not from running v1.5.1.

## Rules until the forks are gone

1. No fork-only patch: a carried change has its upstream issue or plugin the same day.
2. Upstream PRs are the owner's; each shows a gain measured on upstream's latest release.
3. The fork's own commit count is measured weekly and only goes down.

## Order

1. **Drop A.** Rebase each fork line onto upstream's latest. mecha merges v0.26.0 with two
   conflict hunks (`PGRST_DB_PRE_REQUEST`, `app_pre_request`); the RisingWave rewrite of
   compute does not touch fork code.
2. **Owner decisions (D)**, below: they decide whether the largest rows are B or C.
3. **omnishell** (PRONTO-744), then **mecha** (PRONTO-745), then **pronto** by area
   (PRONTO-746): B rows go to the owner as small upstream PRs; C rows move behind a named hook.
4. **Cut over app by app** (PRONTO-748): an app pins upstream once every row it uses is A or
   released upstream. Prontoweeper is not the trivial canary it looked like: it pins
   billing, Android and Unity surfaces and auth in `shell.yaml`; check those rows first.
5. **Archive** the three forks and their publish workflows (PRONTO-750).

## Decisions for the owner

- **write.ts** (pronto row 54): a pronto-plugins plugin, or one tiny fork kept for it?
- **Sign-in**: edge sign-in, per-app broker ports, `identity/bearer.ts`, `issuer.cue`, the
  `capabilities.auth.*` extras (pronto D rows) and mecha's handoff codes, Android passkeys,
  `/auth/door`, guest upgrade, API keys, airlock doors (mecha D rows, all B-shaped). Offer
  upstream, or wait for upstream's Ory decision?
- **Studio auth**: `/auth/upgrade` and the play token need an upstream token-verifier hook (C)
  or go upstream (B)?
- **Roles managed outside mecha**: v0.26.0's docs say externally managed roles are
  unsupported. Drop ours, or argue for it upstream?
- **omnishell**: kept/adopted guest, `money` text format, read-outage retention, seed `{href}`.
- **The metal environment** (pronto k8s): upstream or plugin?
- **Our open upstream PRs now redundant**: pronto #11 and #17 (fixed in v1.4.5), #12 (= upstream
  #2447), #18 (= upstream #2444). Close them?

## What blocks a direct pin today

- **omnishell v0.25.2**: the two C hooks (phone sign-in provider list from the app, cookies the
  renderer carries from the door), the four D rows, and B rows apps rely on (#5 token renewal,
  `/ready`, `firstPaint`, lazy statechart and hatch code that keeps aprende under budget).
- **mecha v0.26.0**: API keys, app schemas and `apiSchemas`, the auth surfaces, airlock doors and
  the host launch; roles managed outside contradicts upstream's policy.
- **pronto v1.5.1**: fields it lacks (`capabilities.auth.*`, `meta.schema`/`#Tenancy`,
  `meta.firstLoad`, money, `access.anon`, `database.smartShutdown`) fail CUE in any app using
  them; release@gcp's staged go-live, local gate and rehearsal must be in pronto-plugins
  `gcp/engine` first (PRONTO-494); `idioms/` and `cue.mod` regenerate for bayt 0.73 and cue 0.18.


---

## Inventory: omnishell

live fbba6b96 (omnishell 0.25.0-fork.2) | base v0.25.0 | upstream latest v0.25.2 (79469c2e) | 61 non-merge commits since v0.25.0 | diff vs v0.25.2: 73 files, +3393 -503

Bins: A upstream has it (drop) | B goes upstream (PR) | C ours (move out, hook named) | D owner decides.
Upstream PRs by us (bonisoft3/omnishell): #1 feat/auth-oidc CLOSED (landed in monorepo, v0.14.0); #3 perf/upstream CLOSED (ported to monorepo, trash#2264); #4 pronto-638/upstream-screen-outage OPEN (preload half shipped in v0.25.1 b3794fa8; outage half "deliberately deferred while Omnishell is being rewritten"); #5 upstream/render-token-renewal-r1 OPEN.

| # | change | commits | files/area | bin | evidence | next step |
|---|---|---|---|---|---|---|
| 1 | Phone as a sign-in provider (chrome_signin_phone) | 63359a42 | chrome.js, terminal.cue (providers), check-i18n.ts | C | v0.25.2 offers only google; needs pronto-identity broker/phone.ts | Hook: terminal provider list and chrome_signin_<provider> text supplied by the app/program, not hardcoded in terminal.cue; app adds "phone" |
| 2 | Frame wake: region wakes on next frame or message | 811c1771 | data-sync.js | A | v0.25.2 data-sync.js:107 uses requestAnimationFrame(run) | Drop |
| 3 | Motion slots answered when the pass places rows | 4d3a2f3d | screen.js | A | v0.25.2 screen.js has answer()/getAnimations at placement (l.1348-1379) | Drop |
| 4 | Re-placed list moves only out-of-order rows | f736bf39 | screen.js | A | v0.25.2 screen.js:1384, 4355 "longest run already in order" | Drop |
| 5 | Wake regions a small fold moved in the event's task | 42192ac4 | screen.js | A | v0.25.2 PROMPT_FOLD_MS=4 with flushNotifications (l.1908, 3106) | Drop |
| 6 | Bind a stamped row by its template's plan | 4fc54cb7, f0fe310c | screen.js, test harness | A | v0.25.2 bindingPlan() (l.1661, 3747); PR #3 closed as ported | Drop |
| 7 | Served row of another kind is stamped fresh (kind by tags + static classes) | cfa0015a, 5c8de84a | screen.js sameKind | B | absent at v0.25.2 (live-only sameKind) | Upstream PR with a multi-template adoption test |
| 8 | Submit/event wakes: draw a form write in submit's task; wake after last listener; non-bubbling wakes at once | 8b7ec2ae, 7089efb5, b1309176, 5dd6b3f4 | screen.js afterDispatch, test/submit-wake.test.ts, fake store | B | v0.25.2 flushes only in handler fold (l.3106), no afterDispatch | Upstream PR with measured gain (A/B on v0.25.2) |
| 9 | RowCtx class, shared empty nested map, attributes read by name | cc9abf24, ead341e7 | screen.js | B | live-only (stat +338 lines in screen.js) | Upstream PR with benchmark numbers; may fold into 8 |
| 10 | Skip per-row validation judge when no validation names the table | 06f34452 | data-sync.js | B | v0.25.2 validates every row (l.2196-2254) | Upstream PR, numbers (create 10k allocation) |
| 11 | Reduce runs take turns; form submitted before wiring is held then made | afc84650, e8015e37 | screen.js, playwright early-submit/early-flush/recovery | B | live-only (inLane, heldSubmits) | Upstream PR with the pw tests |
| 12 | Seed table as a file beside the config ({href}) | ab0d7dba | data-sync.js, seed-smoke.js | D | absent at v0.25.2; tied to our page bundle; config-shape change upstream is rewriting | Owner: propose upstream or generate seeds inline in the app |
| 13 | Fake store refuses a value its column type cannot hold | 7dffdd45 | test/data-sync-fake.ts | B | live-only test helper | Ride with 25 |
| 14 | check-visual SLOW throttle (CPU x4, 300 ms/request) | 661c95e4 | check-visual.ts, src/lint/playwright/slow.ts | B | absent at v0.25.2; meaning copied from apps' tests/slow.ts | Upstream PR; name the env var in README |
| 15 | Public screen of an auth.required app shown with a guest session | 83726509 | shell.js, fragment.js opensToVisitors | B | v0.25.2 has route access "public" but no opensToVisitors | Upstream PR |
| 16 | surface.firstPaint (critical CSS, first markup, one inline script, sha256 in CSP; documents drop it) | cdf4d786, 98cac5e1, 72f764e5, 44a1da5b, 168b557d, 8411d4ee, 4e6de2b3 | terminal.cue, shell.html, document.js withoutFirstPaint | B | absent at v0.25.2; commit says generic, no-op if undeclared | Upstream PR for the mechanism; the Bonk CSS/script stays in the app |
| 17 | Renderer renews a refused guest token instead of exiting | f38e8321, b333dfc6, 4ccc9793 | server/render.ts, data-sync.js, render-server tests | B | upstream PR #5 OPEN; absent at v0.25.2 (watchRefusals none) | Owner follows PR #5 |
| 18 | Renderer serves /ready (synced + door answers in 2 s) | 390d537c | server/ready.ts, render.ts | B | absent at v0.25.2 | Upstream PR; our k8s probe uses it, so keep until merged |
| 19 | Renderer keeps the door's Electric cookie (sticky pod) | df68ec84 | server/render.ts | C | no cookie handling at v0.25.2; infra-specific (our Electric pods) | Hook: render.ts option/env naming cookies to carry from door responses (default none) |
| 20 | Renderer binds loopback on SAYT_PLATFORM local too; plane.yml + devflow.cue | 8c7fe473 | server/render.ts; .github/workflows/plane.yml, devflow/ | B (render.ts), C (plane/devflow) | v0.25.2 binds loopback only for "host" | Tiny upstream PR; plane.yml/devflow are fork repo glue, vanish with the fork |
| 21 | render-server test within() clears its timer | 98bd2826 | test/render-server.test.ts | B | live-only | Ride with 17 |
| 22 | node_modules never committed | 6543df6b | .gitignore | A | upstream never tracked it; fork artifact | Drop |
| 23 | Lazy statechart/hatch/render/machine kits (bundle budget), session-posture.js, machine-shape.js | 30596025, c691fcb7, 2ceb7978, debb8467 (+jessie/fragment/cortex-navigation splits) | shell.js, screen.js, jessie.js, terminal.cue, import-closure test | B | v0.25.2 imports all statically (aprende over 300000 B budget without it) | Upstream PR with gzip numbers; biggest merge-conflict source |
| 24 | Guest kept across visits, refreshed, handed to auth on provider sign-in (flag-gated: auth.keepGuest, auth.adoptGuest via /ofrep) | 6ab69680, 576a42e4, bd2ed226, c725acb1, 5e767aac, cae4b1a5 | shell.js, kept-guest/adopt-guest tests | D | absent at v0.25.2; needs mecha-fork#27/#28 endpoints and OFREP flag gating (ours) | Owner: generic keep-guest upstream with a boolean, flag gate as app-side hook |
| 25 | A create whose key is another's row is refused, not reported saved | b32fc1f6 | data-sync.js createLanded | B | v0.25.2 only comments on ignore-duplicates (l.2390), no check | Upstream PR |
| 26 | Program display name titles documents (appTitle, shell.json title) | 9effe639 | chrome.js, shell.js, terminal.cue | B | absent at v0.25.2 | Upstream PR |
| 27 | Closed store read fails callers, not the process | 82301372 | fragment.js, store tests | B | live-only | Upstream PR (small) |
| 28 | data-text-format="money" (runtime, per-row currencyField) | 89570bd9, 0a8ffa37 | screen.js, lint.ts, terminal.cue, money tests | D | v0.25.2 test/money-format.test.ts says "without built-in money special-casing", yet lint.ts still checks money | Owner: ask upstream whether money returns; else format in app |
| 29 | Preload hrefs drop the door's sidecar path | 3d94493e | preloads.js, document.js, render.ts | A | v0.25.1 b3794fa8 (preloadBase) does the same | Drop; our preloadPrefix replaced by upstream shape |
| 30 | Read outage does not fail settle (TransientRead); render fails on outage | 5a0c2383, 2965526a, c70491d3 | screen.js, fragment.js, data-sync.js | D | upstream PR #4 OPEN, outage half deferred by upstream | Owner: wait for upstream rewrite or carry in the app's shell |
| 31 | Boot service-worker registration catch, then reverted | c785be05, 6ebeab0c, 85d8fd8a, a4bec81b, 701798fb | boot, package.json | A | net zero in live (reverted by a4bec81b, 701798fb) | Drop |

Remaining diff vs v0.25.2 not from fork commits: v0.25.1/.2 changes live lacks (seal key read once per write in data-sync.js, preloadBase, secret-form test); version, mise.lock and toolchain bumps.

### Summary
Bins over 31 groups: A 8, B 17 (one B/C split in row 20), C 2 (rows 1, 19), D 4 (rows 12, 24, 28, 30).
Pinning v0.25.2 directly loses what apps need today: C hooks (phone provider list, Electric cookie), D features (guest keep/adopt, money format, read-outage retention, seed href), and B items the apps rely on (token renewal PR #5, /ready, firstPaint, lazy kits for aprende's size budget).
Blockers in order: upstream PR #5 and the B batch, then owner calls on D rows and the two extension points, then pin.

---

## Inventory: mecha

live = 30c374c (tag `live`, 0.25.1-host.2) | base = upstream v0.25.1 | upstream latest = v0.26.0 (v0.25.2 is inside it) | 71 non-merge commits v0.25.1..live | `git diff v0.26.0 live --stat`: 149 files, +10894 -6791 (about 2/3 is upstream's Feldera to RisingWave rewrite of services/compute, which live does not have, plus spikes/; the fork's own delta over v0.25.1 is 85 files, +5938 -363).

Trial merge `git merge-tree live v0.26.0`: only 2 conflict hunks. (a) cluster.cue PGRST_DB_PRE_REQUEST: fork's `meta.schema.floor` vs upstream's new PGRST_APP_SETTINGS_TOKEN_ROLES. (b) rls.sql `app_pre_request` DECLARE: fork's `writes` (API-key scope gate) vs upstream's `declared` token roles. services/compute is untouched by the fork (only a loopback-bind line in main.ts), so the RisingWave rewrite does not conflict.

Method notes: commits are grouped by feature (follow-ups folded in). 377bc19/747c52c ("review fixes for the v0.25.0 merge") are mixed fixes to the doors, auth, handoff, OIDC and bayt.cue rows below; they travel with those rows. 35f8ed1 and 41706a2/e1e4f9d also committed node_modules (1243 files): drop that noise whatever the bin.

| # | change | commits | files / area | bin | evidence | next step |
|---|---|---|---|---|---|---|
| 1 | Multi-check database guards in machine.cue | a180bc2 | machine.cue | A | `git diff v0.26.0 live -- machine.cue` is empty; v0.26.0 machine.cue:133-135 has `checks`. Our PR #2 closed ("pronto half is pronto#6"). | Drop. |
| 2 | Edge machine steps run `read committed` | 05b4ad9 | mecha-edge/src/object.ts | A | v0.25.1 object.ts:133 already has `SET default_transaction_isolation TO 'read committed'`. | Drop. |
| 3 | Verified e-mail in identity_link; identity_link and webauthn_credential closed to app roles; auth tables migrated under an advisory lock | 35f8ed1, a681d22, 94e579a | auth/oidc.ts, main.ts, schema.ts, edge cluster.ts | A | v0.26.0 has `email text` (schema.ts:33), `email_verified` check (oidc.ts:220), `sealAuthTables`/`prepareAuthTables` and `pg_advisory_xact_lock` (main.ts:109, :668); edge `mecha_auth.identity_link ... email` (cluster.ts:163). | Drop (they came in through the v0.25.0 merge). |
| 4 | Sign in through any lowercase-named provider, issuer from the environment; the edge object serves providers too; stack issuer on service claims | ed8b2be, c2e85fd, 268e458, f7c8c00, 96b1ab7 | cluster.cue (`signIn`), mecha-edge/src/cluster.ts, object.ts, edge tests | B | Upstream deliberately narrowed to Google: v0.26.0 cluster.cue:644 `[!="google"]~(K,_): error("signIn.\(K): field not allowed")`. PR #1 (generic OIDC) was integrated in v0.14 then restricted. | Upstream PR "signIn: any provider name" with the edge half, argued by Studio/other-IdP use. If refused, becomes D. |
| 5 | Discovery retries a provider that is still starting (5xx, 429, dropped connection) | 1a9ef30 | auth/oidc.ts | B | No retry in v0.26.0 oidc.ts (grep `5xx\|retry` empty). Found by a real 20 s Cloud Run cold start. | Small upstream PR with test. |
| 6 | `__Host-` session and state cookies over https, with legacy-cookie transition | 07e5330 | auth/main.ts, oidc.ts | B | `__Host-` absent from v0.26.0; useful to any multi-site mecha. | Upstream PR (needs #4 or can go first). |
| 7 | System-browser sign-in for native apps via one-time handoff code bound to the app's secret, spent in the database, rides the fragment | 9019d1b, 6696167, 145c4bc | auth/oidc.ts, main.ts, schema.ts, README | D (fits B) | "handoff" not in v0.26.0 auth. Generic OAuth-for-native pattern, but a new public auth surface; upstream auth owner should agree the design. | Owner decides, then PR; fold in oidc-handoff tokens naming the stack issuer. |
| 8 | Android passkeys: auth admits the app's signing certificates (`WEBAUTHN_ANDROID_ORIGINS`, `capabilities.android`) | 044f7c9, 6c4a751 | auth/origins.ts, main.ts, cluster.cue | D (fits B) | Not in v0.26.0 (0 hits). Generic WebAuthn feature, no bsoneca names. | Owner decides, then PR. |
| 9 | `/auth/door`: 2xx with the verified session's account, for the door's forward_auth | 01dd0bd | auth/main.ts, mecha-browser/cluster.ts, edge cluster.ts, docs/browser.md | D (fits B) | Not in v0.26.0. Generic with mecha's door; the consumer is pronto's door. | Owner decides; PR with the door contract documented. |
| 10 | Guest can be adopted by Google sign-in; guest trades its token for a new one (`/auth/guest/refresh`) | 78950ae, e1e4f9d, 41706a2 | auth/main.ts, oidc.ts | D (fits B) | Neither in v0.26.0 (`guest/refresh` 0 hits). Guest mint exists upstream (main.ts:467-482). Studio/Bonk-driven but generic. | Owner decides; PR after #4. |
| 11 | `POST /auth/upgrade`: a session re-issued, scoped to one operation, minting nothing that outlives it | 947d8b6, b807339 | auth/main.ts | D (fits C) | Not upstream. Built for Studio's upgrade-an-operation flow; unclear anyone else needs it. | Owner decides: keep in pronto-plugins if it can sit on a token-issuer hook. |
| 12 | API keys in auth (create, list, revoke, exchange for a 15-minute token); `/crud` honours `kid`/`scp` scopes in `app_pre_request`; per-request gate (`AUTH_API_KEYS_GATE`) and `keyExchanged` hook; key and handoff tables follow app schemas | e90c1d6, 9e70e6d, 0f37c11, e4c3849 (6fc6bce, in #14) | auth/*, rls.sql/rls_test.sql, rls/README, cluster.cue | D (fits B) | Not upstream (`AUTH_API_KEYS`, `keyExchanged` 0 hits). The two hooks are already extension points. Touches the one rls.sql hunk that conflicts with upstream's new `declared` token roles. | Owner decides; if B, rebase onto v0.26.0's token_roles first. |
| 13 | Studio play token: auth verifies it, `AUTH_GUESTS=off` refuses guests, handle rule, never takes a native account (409) | 873a32c, 3d32cf5, aec78c1, 71e33d4 | auth/studio.ts (+655-line test), main.ts, oidc.ts | D (fits C) | Studio-specific by name and by file. Needs a generic hook: an `AUTH_EXTERNAL_TOKEN` verifier module (verify -> {sub, handle, claims}) that pronto-plugins supplies. | Owner decides; design the hook upstream, move studio.ts to pronto-plugins. |
| 14 | App schemas: tables in a schema of their own (default public); lists schema for #Tenancy; auth, API-key and handoff tables, Electric stand-in, door and shapes follow it; `capabilities.apiSchemas` for PostgREST | 3308b57, 72b1a16, c288f7f, 6fc6bce, cd617f0, a1dbd77, 7f39412, 2a450ce, 94d8881 | cluster.cue, rls.sql, migrate.*, auth, electric/main.ts, proxy/Caddyfile, mecha-browser/shapes.ts, docs/schema.md | B | Upstream PR #4 OPEN (2026-11-17) covers the database core (334 add); the follow-ups (auth, electric, proxy, shapes, apiSchemas) are not yet proposed. Not in v0.26.0 (`apiSchemas` 0 hits). Conflict point: cluster.cue PGRST_DB_PRE_REQUEST hunk. | Get #4 merged; then one PR per follow-up, each rebased on v0.26.0. |
| 15 | Drop `mecha.rls_audit` before CREATE (changed row type over a built DB) | 94865ce | rls.sql | B | Upstream PR #5 OPEN (2026-11-18). v0.26.0 rls.sql lacks the DROP and uses the old `polroles = '{0}'`. | Wait for #5. |
| 16 | Roles migration works against roles managed outside mecha | 5690fe8 | 001_roles.sql, role_passwords.sh, cluster.cue, docs/deployment.md | D | PR #3 closed by us "in favour of declarative approach pronto#20". Upstream then added roles.cue external-role validation (#2429) and reverted it (#2434); v0.26.0 docs/deployment.md says "Externally managed roles and shared ownership are unsupported". Direct conflict with upstream policy. | Owner decides: pin v0.26.0 and keep roles inside the framework, or carry this one patch until pronto#20 lands. |
| 17 | imgproxy hardening: presets only, WebP, max 1024 px, fetch from the store alone (and the pictures a Google sign-in links) | fbebe73, 592809e, 4afd731 | cluster.cue, docs/capabilities.md | B | v0.26.0 cluster.cue has no `IMGPROXY_ONLY_PRESETS`, `ALLOWED_SOURCES`, `PRESETS`, `MAX_RESULT_DIMENSION`. Generic open-resizer hardening. | Upstream PR. |
| 18 | Electric: no CREATE PUBLICATION when tables are published by hand | 1d1a29c | electric/patch.exs, README | B | v0.26.0 patch.exs has no `try_creating_publication?`. | Upstream PR. |
| 19 | Electric stop waits 2 s, not about 19 s | 85f66ce | cluster.cue | B | Measured: integrate@local 35 s to 18-22 s. Not upstream. Part of the host stack ordering, so rides with #22 if that is refused. | Upstream PR (with #22 or alone). |
| 20 | cdc-events stream bound (`maxLenApprox` 100000 on redis-streams) | a7f51b7 | mesh/dapr/components/redis-streams.yaml, docs/change-capture.md | B | v0.26.0 has no `maxLen`. Redis has no persistence or maxmemory, so the stream otherwise fills the host. | Upstream PR. |
| 21 | Database published on host loopback only (5432) | 6f2957a | cluster.cue | B | v0.26.0 cluster.cue publishes 5432 on every interface. | Upstream PR. |
| 22 | airlock: undici 7.30.2 (cheerio's 7.30.0 had 4 high advisories) | 22f3fc8 | airlock/deno.json, lock | B | v0.26.0 deno.json has no undici pin. Upstream may already be moving; check at PR time. | Upstream PR (or take a later upstream bump). |
| 23 | Airlock doors: synchronous call that needs its answer now (door.ts, `DOOR_PORT` 9998, `timeoutMs`, ledger holds hashed headers, caller may name the sink's Idempotency-Key) | 8979062, c9db9fe, b19ddb9 | airlock/door.ts, main.ts, reentry.ts, handler.ts, README, cluster.cue allow-net | D (fits B) | `parseDoors` absent from v0.26.0. New airlock surface; v0.26.0 itself reworked airlock (read cache, sealed values, k8s bridges) so the PR must be redone on it. | Owner decides; PR rebased on v0.26.0 airlock. |
| 24 | Host launch: every service as a host process under process-compose (database initdb, PLV8 built or fetched, electric build, migrate, crud, auth, ticker as host processes, caddy host door, loopback binds, role-passwords step name) | 8a706d5, 0953593, 56aa491, d5ea171, ad06413, 5cdf89e, 8ae1031, 67a8cb4, 9626757 | services/*/host.sh, plv8.sh, prebuilt.*, proxy/host.ts, toolchain/tools.cue, cluster.cue `hostPrepare`/`toolStatics` | D (fits B) | v0.26.0 has no services/*/host.* and no plv8.sh; upstream's "host tier" lives in bayt (`SAYT_PLATFORM=host` branches only in airlock, activepieces, tsbifrost). Large (the biggest generic piece) and ties to the host-tier design upstream owns. | Owner decides with upstream; split into PRs per service. |
| 25 | Host launch: blob plane and imgproxy stand-in (preset-enforcing) | 834a825, 8eeac4f | imgproxy/host.ts (+test), cluster.cue, Taskfile | D (fits B) | `services/imgproxy/host.ts` absent from v0.26.0 (v0.26.0 has an inline deno stand-in in cluster.cue:1602 that does not enforce presets). Rides with #24 and #17. | Follows #24. |
| 26 | Door extension points: `meta.hostPeers` (renderer behind the door, via bayt when it is a target), `meta.doorEnvironment`, `docs/proxy.md` "Several sites" | e0ddeae, 816c2c1, 9f2ce9e, 6235304, 4776125 | cluster.cue, cluster_test.ts, host_peer_process_compose_check.cue, docs/proxy.md | C | Contract names pronto's door (SITES_MODE, SITES, BRAND_DIRS, PRONTO_UPSTREAM_*). The hooks are generic; the content is ours. | Keep the two hooks (meta.hostPeers, meta.doorEnvironment) as the extension points; move docs and door env to pronto-plugins. If upstream refuses the hooks, ship via a cluster overlay. |

### Summary
Bins by change (26 rows): A drop 3 rows (5 commits); B upstream PR 11 rows (#4-6, 14, 15, 17-22; PRs #4 and #5 already open for #14's core and #15); C ours 1 row (#26, 5 commits); D owner decides 11 rows (#7-13, 16, 23-25; most fit B, #11 and #13 fit C). Our closed PRs: #1 (integrated), #2 (integrated), #3 (replaced by pronto#20).
Blocks pinning upstream v0.26.0 directly: nothing builds on it until we either upstream or re-home #12-14 (API keys, schemas) and #7-10, #13, #23-25 (auth surfaces, host launch), because pronto and Studio call them; merge itself is easy (2 conflict hunks: PGRST_DB_PRE_REQUEST in cluster.cue, `app_pre_request` DECLARE in rls.sql), and RisingWave replacing Feldera in compute needs no fork work.
Order: (1) take v0.26.0 plus the fork as a merge now (cheap, drops A); (2) land PRs #4 and #5, then #14 follow-ups and the small B set; (3) owner rulings on #16 (external roles vs upstream's "unsupported"), #13/#11 (Studio hooks), then #7-10, #12, #23-25.

---

## Inventory: pronto

Live = `70da285` (tag `live`, v1.4.1-gcp.2). Base = upstream v1.4.1 (`6101c74`). Upstream latest = v1.5.1 (`b7f1ca6`, 23 non-merge commits since v1.4.1). Fork: 445 non-merge commits since v1.4.1. `git diff v1.5.1 live`: 270 files, +21715/-5421.

Read the diffstat with care: the diff to v1.5.1 also shows upstream's own v1.4.2..v1.5.1 changes (RisingWave for Feldera, `airlock.cue` removal, `role-removal.ts`, etc.) as reversed, because live lacks them. Those are not fork changes.

Bins: A upstream has it, B goes upstream, C ours (bsoneca/pronto-plugins or the app), D owner decides, X drop (fork machinery). "verify" = judged from greps and PR text, not from running code at v1.5.1; confirm before relying on it.

Our upstream PRs (bonisoft3/pronto, author us): #1,#2,#3,#4,#5,#6,#7,#9,#14,#15 closed; #8,#10,#11,#12,#13,#16,#17,#18,#19,#20 open. Of the closed: #2,#3,#5 integrated upstream (v0.15.2/v0.16.0); #4 superseded; #14 closed for #20's declarative model; #15 closed as "already covered", with the extras deferred; #1, #6, #7, #9 closed with no readable comment. Of the open ones: #11 and #17 were answered by upstream's own fixes (v1.4.5), #18 equals upstream b0b33a3 (#2444), #12 equals upstream #2447.

### .github/, CI, fork machinery

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 1 | Fork publish workflows: prerelease-mecha/-omnishell/-gcp, prebuilt-mecha, prerelease.sh, prerelease*.env, mecha/omnishell-snapshot.py, fork-lock.py, bootstrap/fork.lock, MECHA_V/OMNISHELL_V pins | 286c4fe f89742c 9fce774 48e1b26 c459079 | X | exist only to publish forked mecha/omnishell/pronto; upstream has only cd.yml | delete when no app pins a fork version (PRONTO-740); keep until mecha/omnishell rows below are resolved |
| 2 | ci.yml, monorepo.sh/env, ci-tests.txt, ci-monorepo-tests.txt, ci-not-run.txt, actionlint | 97185e7? 97e350a 0386002 1bd81a6 9706048 | X | CI for the fork line only | drop with the fork; app repos keep their own ci |
| 3 | plane.yml + devflow/devflow.cue (board hook) | d77dd4d 243558b | C | PRONTO-479: "plane calls pronto-plugins' board workflow" | already in pronto-plugins; delete from fork |
| 4 | `cue` wrapper, cue-budget/slot.ts+vetted.ts, one id per evaluation, memory-weighted cue | a0dd3fc d3b6347 d94e8c9 ace623e 899c954 ca8b491 98642d7 | C | AGENTS.md: pronto-plugins `machine` already puts the wrapper first on PATH | confirm `machine/` has the last 3 commits (899c954, ca8b491, 98642d7, PRONTO-736), then drop from fork |
| 5 | generate lock: one generate at a time in a checkout; derive's `exclusive`; docker/Caddyfile written whole | cf2e780 6739dea c111cc9 1a65696 | B | parallel generates corrupt the tree on any machine; v1.5.1 has no generate-lock.sh | small upstream PR; needs owner of write.ts decision (row 54) since it touches write.ts/derive.ts |
| 6 | bayt 0.66.1->0.68.2 pins, cue.mod, distribution, bootstrap lock/claude settings/fork-aware bootstrap | f5265ae 31474bc 9c88ce8 58a57c8 fd564f4 | X | v1.5.1 already pins bayt 0.73.0, mecha 0.26.0 | drop; the Claude-settings bootstrap (bootstrap/claude.cue, 58a57c8, 8bc236b) is C if we still want it, to pronto-plugins |

### bundle/ and edge

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 7 | Pages bundle size: prose.ts, page-core.ts, seeds/lazy chunks as files, a file whose text another holds rides once, no comments in first load, `meta.firstLoad` budget | d9de798 5187f43 ee5181d 3b9f2ef b33e674 | B | v1.5.1 has none of prose.ts/page-core.ts/firstLoad; generic to any pages app | upstream PR (big: +~600 lines bundle/); split in 2: file split, then budget |
| 8 | PGlite files beside the page, host-DOM hatch files in a pages release | f9f21b8 da5daa1 | B | generic pages release behaviour | bundle into row 7's PR or a sibling |
| 9 | Door serves SPA shell when renderer is down/limiting (429/502/503/504), GET+HEAD whole | 8d83d93 74b26f7 4fcf9df | B | open upstream PR #16, no reply; v1.5.1 Caddyfile has no such fallback | owner follows up on #16; rebase onto v1.5.1 |
| 10 | Door: gltf compression, `no-transform` on released pages | 5f16fa1 7b503c9 | B | generic Caddy behaviour, absent upstream | small PR with row 9 (same Caddyfile) |
| 11 | Door answers several sites (origin, client, brand files); `surface.fronts` sites; caddy-blocks/keepBlocks | 80aeead 164a89c cf2e780 | B | v1.5.1 has no caddy-blocks.ts/sites variable; used by Studio but generic | upstream PR; touches write.ts (row 54) |
| 12 | Door reads the client address through cluster proxies; strips forwarded chain; Electric shape requests pinned by cookie/IP over a headless Service | aefa648 837f772 f03e082 fc69e6d 096e7c4 | B | only useful with Electric replicas (rows 37, 42); upstream has replicas but no placement | upstream with HA PR (row 29); else C |
| 13 | Pages build: missing file 404 / route 200, program names its export, noindex for non-pages, play-screen head, shell.json social title, `access: public` screen behind sign-in | d5287dd f99955b e695ed3 1476ba9 ae53d9d | B | generic pages/screens behaviour; docs/screens.md changes follow | small PRs by theme (SEO, screens access) |
| 14 | Container hatch: route through the door (#1), form to another site, CSP host-source wildcard | 1e076b9 bcca656 | A/B | #1 closed; `route` is in v1.5.1 schema.cue (101 hits); form handoff and CSP wildcard not found upstream | A for route; B for the other two (tiny); verify route semantics equal |
| 15 | Effect handler bundles: import program modules, scoped bundle, reserved-locals exports (effect-bundle.ts) | 9366398 6d9d0eb f6a03e3 | B | new file, absent in v1.5.1; upstream isolate-uses landed (#2415) so check overlap first | verify against #2415, then upstream |
| 16 | Edge (release@cloudflare): provider sign-in at the Worker, PGlite from Cloud Build, no release through a local broker | 391ebe8 dc17d67 | D | auth at the edge depends on the Ory/sign-in direction; edge-signin.ts, edge-pglite.ts new | owner decides together with row 20 |

### identity/ and auth

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 17 | Sign-in providers the compiler builds (#2); identity/ on Ory Hydra (#5); release@gcp auth settings | 85860e0 05c6206 | A | PRs #2, #5 closed "integrated upstream (v0.15.2/v0.16.0)"; #4 superseded | drop |
| 18 | Each app's local broker on its own ports (over upstream's issuer design) | 47ae28f 9a642bf 0c41f9a | D | identity/broker/main.ts, front.ts; upstream may move to Ory | owner: port-per-app is needed for parallel local stacks; ask upstream how Ory changes the broker |
| 19 | identity/bearer.ts + identity/issuer.cue (`#Issuer`: another issuer's token exchanged for a session) | 2164fb2 | D | new files, +~600 lines with tests; Studio-shaped | owner: B if generic to any pronto user, else C into Studio |
| 20 | `capabilities.auth.*` extras: android passkeys, apiKeys/apiKeysGate, keyExchanged, keepGuest, adoptGuest; provider by any word; handoff codes; `auth.keepGuest` | 4c19f41 d91a409 424887d 9604d20 7747a56 403ea67 | D | all need mecha-fork patches (host.9..host.13, omnishell fork.8/.10/.11); not in upstream mecha 0.26.0 | owner: these are mecha PRs first (upstream bonisoft3/mecha), pronto side follows; or app-level C |
| 21 | Roles migration changes a role only where it lacks what it sets (#14), ADMIN authenticator kept granted | ea2a56c 97185e7 | B | #14 closed for the declarative model #20 (row 52) | do not send as-is; fold into #20's external-provisioning mode |

### gcp/ (release@gcp)

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 22 | Cloud Run beside Cloud SQL (#3); sidecars, IAP, alwaysOn, Cloud Build, imgproxy, ticker/Cloud Scheduler, electric sizing, tier/flags patch, multi-platform QEMU | 2d38c9b f1b2391? 606650f 0d..., 4662a81, ac19d97 | A | PRs #3, #7 integrated; v1.5.1 gcp.cue/release.nu has sidecars, apart, iap, alwaysOn, ticker, sqlTier patch (upstream #2449 equals 4662a81) | drop |
| 23 | Schema job: pgroll inferred migrations off (`TRUE`), 30 min limit, one job builds schema and carries it forward; built DB catches up (new columns, own migrations, 010_machines replay, one transaction) | 819399c dfae421 c0bb4d6 057ceeb 5c68915 | B | open PR #10 (13 commits); v1.5.1 lacks the TRUE spelling fix and 010 replay | rebase #10 on v1.5.1, resend; first commit is a 40-line standalone |
| 24 | Release lock (one release per app) in project bucket; gcloud reads retried, IAM waits for new accounts | 3896b84 e8a71c5 6758fe4 27b33b8 | B | #10 commits 2-3; v1.5.1 has no lock for releases | with #10 |
| 25 | Go-live behind a tagged candidate, rollback if it does not answer; wait until Cloud Run passes bearer tokens; allUsers only where missing; sidecars rolled after public poll | af74502 a681a14 0e24fb1 e48f702 c3c3c12 | B | no `rollback`/`go-live` in v1.5.1 release.nu; #10 | with #10; note staged variant (row 26) is a different design |
| 26 | Staged release: production staged while gate tests, `--rollback`, local gate replaces rc preview, pass ledger, local-gate-key.nu, concurrent go-live, rc forced by `--rc` | d04bbed a5ee77b a4408... 3d9fea7 ef49690 | C | docs/decisions staged-release, local-gate-replaces-rc; depends on integrate@local and AGENTS.md's gate; moves with `gcp/engine` (PRONTO-494) | confirm gcp/engine already carries these; D for whether upstream wants a trimmed "staged" B later |
| 27 | Rehearsal in a Cloud Run job, verify@gcp drivers (32 vCPU, logs, screenshots), new-feature excuse classifier | aadd132 4c91... 07a5368 f5818dc 63342be | C | our release-on-stable-features policy (AGENTS.md); verify.nu +282 | gcp/engine |
| 28 | Release record (JSONL), check-secrets (every project a release touches), image-key reuse and build-key caches, src- tags | 6bc5be5 f4c4b19 43aaf1e 3670039 cf223ba | C | our operations (cache dir, our secret layout); b-grade parts (reuse keys) entangled with row 26 | gcp/engine; B for build-key reuse only if owner wants (gcp/build.nu +312) |
| 29 | Sidecar apart: cpu, maxScale/minScale, probe path, secrets by name, no PORT/K_*, memory | 9659a0d aac4998 d33b552 2b9f4e5 f29320d | B | gcp.cue maxScale 2 vs 12 hits; fields absent in v1.5.1 | upstream, with #10 or separate |
| 30 | Previews in own project, stop-to-zero, delete if cannot stop, tag clearing best effort | 381eb36 7720885 72c2c31 d22eed8 | C | tied to our rc flow | gcp/engine |
| 31 | Blobs on GCP (gate refuses S3 headers, imgproxy presets) | ac3d7dc caa3a34 6b9bfba 948f5df | A (verify) | v1.5.1 gcp release.nu has imgproxy; the header gate lives in mecha-fork host.3/5 | verify gate in mecha 0.26.0 |
| 32 | Multiplayer hybrids: steps read committed, lease actor index, SQL guards with reasons, machines' code in built DB each release (#6) | 13ceeef b9e624a daa28bd aca9a46 3699169 | A/B (verify) | #6 closed without comment; `read committed` appears 6x in v1.5.1; rest unconfirmed | diff mecha-machine tests v1.5.1 vs live; B whatever is missing |

### k8s/ (smartShutdown, crud probes, airlock walls, node, tenants)

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 33 | Airlock + daprd as two walled pods; env_file/secret-passing refusals; Cloud DNS; in-cluster sinks over http | 33a107a 2c69d9e a87142c 1dd38b6 604e39f f1b2391 | A | #15 closed: main already deploys them as isolated pods (upstream #2411); extras "deferred" | drop the pods; residual extras (refusals, existing-secret refs) B with e2e only if wanted |
| 34 | First-effect upgrade: Graphile Worker and airlock steps brought to a built DB; machines' interpreters replayed in app schemas | 0d845d9 f7d203b | B | upstream said first-effect upgrade is open ("leaves step to the operator") | upstream PR with e2e test, if prontoweeper has no effects, low priority |
| 35 | crud Ready/Live on PostgREST `/live`, `/ready` only gates start; crud serves compose's schemas (`PGRST_DB_SCHEMA`) | 120440 1fffb38 4c336e9 8146845 30a0078 | A | v1.5.1 k8s.cue: liveness+readiness `/live`, startupProbe `/ready` (upstream #2447); PR #12 open but now redundant | close #12; the `PGRST_DB_SCHEMA` part goes with row 50 |
| 36 | `database.smartShutdown` (fast shutdown when standbys exist), bounded primary stop 120/300 s, release waits past it | 87eb34a 0620336 1d20484 | B | not in v1.5.1 (0 hits); PRONTO-715 | upstream PR, small (~40 lines) |
| 37 | HA: replicas per workload, PDBs, spread, Dapr control plane HA, DB HA settings, edge/operators n+1, release fails if below n-1, readiness probes for app services | 33b945c 6eefd44 365..(dac4988) 49e... c8983df | B | v1.5.1 replicas 5 vs 13 hits, 0 PDB; generic k8s | upstream PR, large; split schema vs release.nu |
| 38 | CNPG backups: barman-cloud plugin, S3 or Cloud Storage with workload identity, all replicas hot | 18a0b4a 9161181 5f744f6 d02b90e | B | 0 hits for barman in v1.5.1 k8s | upstream PR |
| 39 | Observability: vmalert, per-pod scrape naming pod, metrics export to Managed Prometheus, Jaeger sizing, honor_timestamps false, VM volume | d7bed98 3bcf9c9 c2aa80f 834004b f2d15b4 482c549 512e191 | B | k8s/observability +58 lines; metricsExport absent upstream | upstream PR(s); GMP export is GCP-flavoured, could be C |
| 40 | Services on k8s: own host, own DB login, clock CronJob, jail/act-as, ConfigMap files, exporter port, sidecars, secrets, no service links, resources per container | 985fed2 dc23df9 1d04b06 11a6386 515c9a0 0539cd4 864f3fb | B | runtime.cue/k8s.cue +1590; v1.5.1 has services.clock once, none of the rest | upstream in 3-4 PRs by feature |
| 41 | Dapr: install 1.16.21; no mesh-call timeout (dapr#10371); scheduler off on one node then reverted | 07cbc64 89233e8 b4c1d3a f68724b 1956dc9 | B | net effect of b4c1d3a/f68724b is nil | upstream (version bump + timeout) |
| 42 | Electric on k8s: temporary slot per replica, pool of 8, WAL cap per slot | b8498c6 f03f2e1 | B | needed for replicas; not upstream | with row 37 |
| 43 | Render: startupProbe 150 s, readiness httpGet `/ready`, path is the app's to say, restarts after door rolls | a0c4ea2 56b40c5 c6c8644 8794e11 | B (verify) | upstream #2432 "HTTP 200 probes for owned health endpoints" may overlap | compare with #2432 first |
| 44 | Metal env (k3s via tunnel), node registry + prune, build.by buildkit/node, SOPS+age secrets, local TLS preview | 28af02b 20320f5 145b255 f9ee698 d37e6ce | D | `k8s/envs/metal.cue` new; operator-specific bits but a generic "bare metal" env | owner: B for env+buildkit as extension point `#Environment`, C for SOPS layout (ours) |
| 45 | Tenant/preview releases: `--tenant`, `--host`, `--preview`, `--schema-from`, `--delete`, tenant-images via sandboxed buildkitd | 54e8209 d302800 2167c47 c8df8be 4e3a329 | C | Studio-per-person-repos model; 67 `tenant` hits in release.nu, 0 upstream | pronto-plugins; needs an extension point: release steps hook in k8s/release.nu (does not exist; propose `release.cue` hooks) |
| 46 | Primary runs DB base image, switchover to synced standby, crane pinned+checked, cnpg controller sizing, postgres container resources | 5315c1d f6a03e3? f6c1254 07a9bb0 e90d86c 373ef9b 340b7e7 | C | node-ops lessons (PRONTO-537/591/618), gcp.5x tags | gcp/engine/k8s engine; B for containerResources.postgres |
| 47 | initdb replay of 010_machines + app migrations on k8s; schema job after DB answers; CNPG roles reconcile | 12515ca 0e4e36e 7e51f9f a7f5445 | B | mirrors rows 23 on k8s; #11 (NOTIFY pgrst) answered upstream by v1.4.5 restart | with row 23 |
| 48 | PRONTO_IMAGE_REGISTRY, INTEGRATE_LOCAL_SECRETS=skip, seed-fill flags DISABLED | cd5c5b3 374d6d0 2202a36 | C | our pins/flags service | plugins |

### emit, schema, generators (testdata/emit)

| # | change | key commits | bin | evidence | next step |
|---|---|---|---|---|---|
| 49 | RLS enabled in the migration that creates the table (#18) | 2a1bede | A | upstream b0b33a3 (#2444), v1.5.1 emit.cue line 400 | close #18, drop |
| 50 | An app's database schemas, default public (schema-names.ts, write.ts, 005 renames, PGRST_DB_SCHEMA) | f8f6d0d 35e4c37 4a39d7a | B | open PR #13; depends on mecha `#Tenancy` (mecha-fork host.14); v1.5.1 has 2 `schemas` hits only | blocked on upstream mecha PR (bonisoft3/mecha#4); then #13 |
| 51 | `access.anon`: public entity read without token; withdrawn policy dropped on replay | 03ca694 17fe922 cb1e728 | B | open #19, no upstream reply | stay open |
| 52 | Access model as one CUE value `E._access`, rendered into 001/002/008; external-provisioning mode next | (#20) | B | open #20; #14 closed in its favour | stay open |
| 53 | Table order (tableOrder, 128 bound), 005 ordering, check-sql forgiving unique column add, money fields, machine columns, indexing, `#policySql` refuses what the schema refuses | a80e6a3 5857a0c 74e97db 309b09e e4a251d 587e939 | B | testdata/emit table-order.cue, money.cue, indexing.cue new; none in v1.5.1 | upstream PRs by theme; money touches omnishell fork.16 (data-text-format) |
| 54 | write.ts: mint through app import, cue read exclusive, targetsSorted, ir.md writer (ir-md.ts), caddy-block keep, bayt.json targets by name | b1af75d 71af74... 01e5052 b8560bf 7ed2b46 | D | known D (write.ts never goes upstream); +62/-22 lines | owner: plugin vs tiny fork; list which hooks write.ts needs |
| 55 | Emit perf: chart column one map (#9), derive reads fixed names, program reads together | e3ca20b f321d02 c111cc9 | A (verify) | #9 closed 2026-10-31 (memory blow-up fix, 72G->1.5G); fork commits remain so confirm in v1.5.1 | check emit at v1.5.1 for the single column map |
| 56 | DesignCss and `colorScheme` pin; type-sql PostgREST 14.18; plv8->pljs move; meta.plv8; hybrid SES path | 84aeead da2e40c d9a6113 0f40760 ce8c46c | B | `#DesignCss` has 2 hits upstream, colorScheme only in live | small PRs; verify DesignCss delta |
| 57 | Local stack tier: host launch under process-compose, integrate@local stamp/slot/upgrade-from-released, local-drivers.ts, render host origin | 80dc401 c12f005 e043e38 9c3cf27 1b27463 | C (A for host launch, verify; see mecha row 24) | AGENTS.md calls `integrate@host` "upstream's name" for the host tier; our stamp/slot/upgrade parts are the harness's | harness/plugins; confirm host tier exists in v1.5.1 (1 hit `MISE_ENV=host`) |
| 58 | idioms/.bayt: CI/Caddy/process-compose graph files regenerated | (generated) | follow code | 14 files, 251 ins; most of the diff is upstream's Feldera change reversed | regenerate on the v1.5.1 base; no hand work |

### docs/ and docs/decisions

| # | change | bin | next step |
|---|---|---|---|
| 59 | release-targets.md (550 lines), staged-release, local-gate-replaces-rc, release-concurrency decisions | C (follow rows 24-28) | move with gcp/engine |
| 60 | docs for B rows (identity, access, screens, container-bridges, pipelines, isolate-hatches, k8s README) | same bin as code | ship in each upstream PR |
| 61 | Doc edits that only rename fork/upstream links and archive notes | X | drop |

### forks/

Fork machinery is rows 1-2, 6.

---

### Summary

Counts of rows per bin (61 rows; a mixed row counts in its first-named bin; rows 58-60 follow the code they document): A 8 (17, 22, 31?, 33, 35, 49, 14a, 55?), B 29, C 11, D 6 (16, 18, 19, 20, 44, 54), X 4 (1, 2, 6, 61). In commit terms, roughly: 150 C/engine, 120 B, 70 A or X, 40 D, 65 not yet assigned.

Verify items: 14, 15, 31, 32, 43, 55, 56 (judged from greps, not run at v1.5.1).

Five largest B items:
1. k8s HA + Electric replicas + backups (rows 37-39, 42): about 1000 lines of `k8s/schema/k8s.cue` and `release.nu`; nothing upstream.
2. k8s service extras (row 40): host, database login, clock, jail, ConfigMap files, sidecars; roughly +1500 across `runtime.cue`/`k8s.cue`.
3. release@gcp safer releases (rows 23-25, 29, PR #10): lock, rollback, schema job fix; open since early November, rebase on v1.5.1.
4. Pages bundle size work (rows 7-8): prose.ts, page-core.ts, firstLoad budget.
5. App database schemas (row 50, #13) with access model (row 52, #20) and anon (row 51, #19): three open PRs, #13 blocked on a mecha PR.

What blocks prontoweeper pinning upstream v1.5.1 directly (inferred; prontoweeper's `release.cue` not read):
- Any use of `capabilities.auth.*` extras, `meta.schema`/`#Tenancy`, `meta.firstLoad`, money fields, `access.anon`, or `database.smartShutdown`: these fields do not exist in v1.5.1 and CUE refuses unknown fields.
- The pinned mecha/omnishell are forks (`0.25.1-host.2`, `0.25.0-fork.2`); upstream is mecha 0.26.0. Its host launch, auth image and schemas support come from those; need a mecha-fork-vs-0.26.0 diff before pinning.
- release@gcp as used by the app (staged go-live, local gate, rehearsal, release record) is in the fork's `gcp/`, not upstream's; it must come from pronto-plugins `gcp/engine` (PRONTO-494) first.
- bayt 0.73.0 and cue 0.18 module bumps: our `idioms/` and `cue.mod` need regenerating.
- Lowest-effort start: an app that uses only core pronto (no auth extras, no schemas, no k8s) and releases through `gcp/engine` should run on v1.5.1; find it by grepping the app for the fields above.
