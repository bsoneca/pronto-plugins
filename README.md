# pronto-plugins

Host plugins for [pronto](https://github.com/bonisoft3/pronto) terminals
beyond the browser, and beside them, on unmodified pronto. Why and how they are shaped:
[a native terminal](docs/native-terminal.md).

## Plugins

The plugins that run a service beside the app on a host launch (journeys, perf, analytics, flags,
billing, identity's local broker) are written for pronto 1.1 or later (pronto-fork 1.1.4's host launch, mecha 0.22): a launch hands
each exposed port out itself and names the peers by `{peer, port}` in an entrypoint's env, a form pronto
0.24 does not read (it ran such services as `code.meta.hostPeers`, which these plugins no longer write). An
app on 0.24 keeps the copy it has until it moves to 1.1; one that reinstalls (`bin/pronto-journeys <app>`,
`-perf`, `-analytics`, `-flags`, `-billing`, `-identity`) must be on pronto 1.1 first, and `bin/pronto connect stripe`
refuses an app that is not.

- [ads](ads/README.md): rewarded ads a player chooses to watch.
- [analytics](analytics/README.md): business numbers (users, paying users, games, funnels) and visits, read not alerted.
- [android](android/README.md): a native Android host, no WebView.
- [billing](billing/README.md): paid plans through a shared Stripe broker.
- [errors](errors/README.md): what the pages throw, reported to a self-hosted GlitchTip (Sentry protocol): the node's server, the page's reporter, the door's route.
- [firebase](firebase/README.md): release to Firebase Hosting.
- [flags](flags/README.md): feature flags on OpenFeature and flagd.
- [gcp](gcp/README.md): release to Cloud Run.
- [identity](identity/README.md): social sign-in through a shared broker.
- [infra](infra/README.md): a Google Cloud state kept in CUE, applied by OpenTofu.
- [devflow](devflow/README.md): a repository's dev flow on a self-hosted Plane board: `bin/pronto connect plane`, the hooks that move issues, and the skills pronto-sprint-plan, pronto-issue, pronto-bug and pronto-design.
- [intents](intents/README.md): one-command plumbing behind `bin/pronto`.
- [journeys](journeys/README.md): user-journey SLOs from the terminal's telemetry.
- [migrations](migrations/README.md): a live database carried forward by migrations made from pronto's emitted schema: columns paired by their proto field number (a rename, retype or drop refused), pgroll operations for what the replay of the schema never alters.
- [modular-design](modular-design/README.md): an app's design split into modules, each exported alone, so a change rebuilds only its module.
- [perf](perf/README.md): frame, interaction and paint timings on readers' devices.
- [prod-watch](prod-watch/README.md): what production logged that may be a bug, triaged by an agent on a loop.
- [probe](probe/README.md): a journey run against the released app every few seconds, and an alert naming the flag write just before it broke.
- [release-cron](release-cron/README.md): an app released to production on a schedule, from main, by launchd.
- [runners](runners/README.md): GitHub Actions runners on your own cluster, an ARC scale set per repository sharing one BuildKit.
- [unity](unity/README.md): an app's opt-in to pronto-csharp's Unity host, and its `./saytw unity@local` check.

## One evaluation for the plugins' generate rules

`cue export .` costs seconds whatever it exports, because it evaluates the whole program. The
plugins whose generate rule reads a value of the program (journeys, perf, flags, ads, and
analytics' door route) say `exports of <name>` through `pronto/exports.nu`, which each of their
installers writes from one source, [`common/exports.nu`](common/exports.nu). The first such rule
evaluates every export the app's installed plugins name in one `cue export` and keeps the result in
sayt's per-run directory (`SAYT_LOG_DIR`), under a key of the files the evaluation reads; the others
read their slice. A rule that finds the tree changed since (journeys' derive writes a `.cue` file
before its own export), or no run directory, or a batch that does not evaluate, runs its own export as
it did before. An app takes the change by running each installer again (`bin/pronto-journeys <app>`,
`-perf`, `-flags`, `-ads`, `-analytics`) and committing `pronto/*.cue` and `pronto/exports.nu`.
`nu common/test.nu` counts the evaluations.

## pronto-intents

Say what you want for an app, and it is done: "release my-app", "connect stripe to
my-shop", "what's left before my-app can sell?". The skill
(`skills/pronto-intents`) runs pronto's intents (`bin/pronto`, docs/intents.md), which check
every step, apply what is the program's, and stop only where a person must act: a price to
choose, Stripe's form to fill.

Once, set it up with `setup.sh` (run it again any time): it reads the marketplace from
this checkout, installs or updates pronto's plugin, and allows `pronto release`, `plan`,
`connect` and `deploy` in your user settings, so a sentence runs with no prompt. Claude Code
lets only you grant that, never a plugin, so it is yours to run. Then start a new session.

## pronto-android

Adds a native Android app to a pronto app: no WebView, the program's own
handlers run under SES in QuickJS, screens drawn by DivKit, the toolchain
pinned through mise, and sayt verbs that answer `@android`.

The host adds the three bridges [a native terminal](docs/native-terminal.md)
names as unbuilt, for an app whose `device` tables hold secrets:

- **Storage.** The program's `device` tables (shell.json's `local`) live in
  SQLite, each row AES-GCM sealed with its `(table, id)` as associated data.
  [`host.js`](android/template/app/src/main/assets/host.js) keeps the rows a
  screen reads and refuses, through `commit`, what the browser's store
  refuses: shell.json's required fields, bounds, patterns and enums.
- **Keystore.** The rows' data key is wrapped by an Android Keystore key that
  answers one strong-biometric prompt per use. The app opens locked, unlocks
  once, and locks again when it leaves the screen. Enrolling a new biometric
  destroys the key, and with it the vault.
- **Autofill.** An `AutofillService` offers one locked entry. Choosing it
  unlocks and runs the handler the app's `autofill.json` names, headless and
  caged, over the vault and a probe `{kind, target}`; the logins it names
  become datasets. A web domain counts only from a known browser.
  An app's probe also states the asking app's signing-certificate digests
  (current signer, then its rotation history), and the screen reads an
  installed app's through `__signers(package)`. An app login is pinned to its
  certificate when added, or on its first fill if its app was absent;
  `autofill.json`'s `signer` and `signers` name the columns.

### As a Claude Code plugin

```sh
claude plugin marketplace add bsoneca/pronto-plugins
claude plugin install pronto-studio@bsoneca-pronto-plugins
```

The [`pronto-android` skill](skills/pronto-android/SKILL.md) adds or refreshes
the host in a pronto app and writes its phone screens.

### By hand

From a bootstrapped pronto app whose four verbs are green:

```sh
<this repo>/bin/pronto-android .
./saytw --script tools.nu mise trust .config/mise/conf.d/android.toml
./saytw --script tools.nu mise lock
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw setup@android
./saytw launch@android
```

`bin/pronto-android` exports [`android/host.cue`](android/host.cue)'s files
for the app, with this repo's pinned CUE, and writes them:

| Path in the app | |
| --- | --- |
| `.say.json` | `setup`, `build`, `test`, `launch` rules, each answering `@android`; sayt merges it with pronto's `.say.yaml` |
| `.config/mise/conf.d/android.toml` | Temurin JDK, the SDK's cmdline-tools, Gradle |
| `android/` | the Gradle project from [`android/template`](android/template), its package `dev.pronto.<name>` |
| `android/app/src/main/assets/screen.js` | written once, then the app's own |
| `android/app/src/main/assets/autofill.json` | written once, then the app's own: the fill handler, the tables it reads, and the vault's columns |

`bin/pronto-android <app-dir> [name] [label]` takes a third argument, the name
the launcher, the unlock prompt and the autofill picker show.

### Example

[`examples/hello-android`](examples/hello-android) is a pronto counter that runs
in the browser and on a phone from one program; its
[journal](examples/hello-android/journal/index.html) shows both.

## pronto-firebase

Releases a pronto app to Firebase Hosting: `sayt release@firebase` builds
pronto's pages bundle, assembles the Hosting site with the files the app's
host-DOM hatches need beside it, runs sayt's version ceremony and deploys;
plain `sayt release` deploys an expiring preview channel, with no version.
Hosting only, the CLI pinned through mise, nothing global.

```sh
<this repo>/bin/pronto-firebase . <firebase-project-id> [site=…] [channel=…] [expires=7d] [ciProvider=… ciAccount=…]
./saytw --script tools.nu mise trust .config/mise/conf.d/firebase.toml
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw --script tools.nu mise lock
./saytw release@firebase --snapshot
```

`bin/pronto-firebase` exports [`firebase/host.cue`](firebase/host.cue)'s
files for the app and writes them:

| Path in the app | |
| --- | --- |
| `.say.json` | the `release` rules `firebase` and `firebase-preview`, merged beside any other host's |
| `.config/mise/conf.d/firebase.toml` | Node and `npm:firebase-tools` |
| `firebase/site.nu` | assembles `dist/firebase` from the bundle and the hatches' files |
| `firebase.json` | written once, then the app's: Hosting only |
| `.goreleaser.yaml` | written once: the shim sayt's ceremony runs |
| `.github/workflows/firebase.yml` | with `ciProvider` and `ciAccount`: the tag deploys, keyless |

The [`pronto-firebase` skill](skills/pronto-firebase/SKILL.md) covers releasing
and its limits.

## pronto-gcp

Releases a pronto app's door to Google Cloud Run: `sayt release@gcp` builds the
door image `sayt launch` runs, for Cloud Run's linux/amd64 and without the
developer's certificates, starts it and checks it answers on :8080, runs sayt's
version ceremony, pushes it to Artifact Registry and moves the service to it by
digest, scaling to zero and public. Plain `sayt release` deploys the same image
to `<service>-preview`, with no version. pronto 0.14.0 admits `gcp` in
`meta.targets` and builds no rule for it; this host is that rule for an app
whose rows the browser keeps. An app with server rows or auth is refused: it
needs Cloud SQL and the services beside the door, which this host does not
build yet.

```sh
<this repo>/bin/pronto-gcp . <gcp-project-id> [region=us-central1] [service=…] [repository=pronto] [origin=https://…] [maxScale=3] [memory=512Mi]
./saytw --script tools.nu mise trust .config/mise/conf.d/gcp.toml
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw --script tools.nu mise lock
./saytw --script tools.nu mise exec -- gcloud auth login   # in a terminal of your own
./saytw release            # the preview service
./saytw release@gcp        # a version
```

| Path in the app | |
| --- | --- |
| `.say.json` | the `release` rules `gcp` and `gcp-preview`, merged beside any other host's |
| `.config/mise/conf.d/gcp.toml` | gcloud, on a pinned Python (macOS's is too old for its installer) |
| `gcp/gcp.nu` | builds and checks the image, deploys it |
| `.goreleaser.yaml` | written once: the shim sayt's ceremony runs |

The [`pronto-gcp` skill](skills/pronto-gcp/SKILL.md) covers releasing and its
limits.

## pronto-infra

Keeps an operator's Google Cloud state in CUE (projects, IAM, service accounts, repositories,
buckets, secrets, Cloud Run jobs and services) and applies it with OpenTofu, as the operator's
own `gcloud` login: `verify@infra` plans and changes nothing, `release@infra` applies the plan
it kept. The schema and the OpenTofu export live here; the state itself is the operator's.
[`infra/README.md`](infra/README.md) sets it up.

## pronto-journeys

Monitors a pronto app's critical user journeys against SLOs, the way an APM's
user-journey monitoring does, from the terminal's own telemetry: a journey is
an ordered list of the gestures a reader makes on its screens, and from one
spec the host derives the collector that assembles runs, the vmalert rules
that burn their error budget, and a Grafana dashboard. It works on the
released terminal: a host-DOM hatch on every screen reports each gesture and
the outcome the screen's `data-state` shows for it.

```sh
<this repo>/bin/pronto-journeys . [endpoint=/telemetry]
./saytw generate        # derives each screen's gestures into journeys_gestures.cue
# write the journeys into journeys_spec.cue, declare the two hatches in ir.html
./saytw generate && ./saytw lint
./saytw launch@journeys # the collector, and a local dashboard to watch it in
```

`launch@journeys` prints three addresses: the app, a Grafana with the
generated dashboard, and vmalert's alerts. VictoriaMetrics, vmalert and
Grafana run on the app's network as their own compose project
(`journeys/dashboard.compose.yaml`); `./saytw --script tools.nu nu -c 'use
journeys/journeys.nu; journeys down'` stops them and the collector.

`bin/pronto-journeys` exports [`journeys/host.cue`](journeys/host.cue)'s files
for the app and writes them:

| Path in the app | |
| --- | --- |
| `pronto/journeys.cue` | a seat beside `pronto/config.cue`'s: promtool and Vector pinned, and a `generate` rule after pronto's writer |
| `journeys_plugin.cue` | the schema, in the program's package |
| `journeys_hatch.cue` | the reporter, a `host-dom` hatch on every screen, and the collector, a `container` hatch and its cluster target: Vector with the run assembly baked in, and on a host launch a host peer the door reaches (`journeys collect`) |
| `shell/hatches/journeys/telemetry.js` | the reporter: gestures, their outcomes and the screens' states, posted to the endpoint |
| `journeys/journeys.nu` | the generate step: derives gestures, gives the door its route to the collector, writes `observability/` |
| `.say.json` | the `launch` rule `journeys`, answering `@journeys` |
| `journeys/dashboard.compose.yaml` | the local dashboard: VictoriaMetrics, vmalert and Grafana fed the generated rules and dashboard |
| `journeys_spec.cue` | written once, then the app's: the journeys and their SLOs |
| `journeys_gestures.cue` | written once, then regenerated from the screens' markup |

A moment that names no gesture refuses at `cue vet`. The `journeys-telemetry`
and `journeys-collector` hatches each owe the app's `ir.html` a
`data-kind="hatch"` element. `observability/`
holds the collector's config, the alerts (multi-window burn rates, 2% of the
budget in 1 h, 5% in 6 h, 10% in 3 d, and a no-data alert per journey after
its `quiet`, an hour by default) as vmalert rules and as Cloud Monitoring
policies (`journeys.alerts.json`), and the dashboard, a row per journey: success
rate, error budget left, burn rate, moment latency and its budget, runs by
outcome and failed moments. Every expression reads the collector's own series,
with no recording rule between, so the rules and the dashboard read the same in
the local VictoriaMetrics and in Google Cloud Managed Service for Prometheus.

In production (pronto's `release@gcp`), the app's `release.cue` runs the
collector as a sidecar apart with its metrics port
(`sidecars: "journeys-collector": {port: 8686, metrics: port: 9598, apart: {}}`),
which Managed Prometheus scrapes. pronto-infra's `alertPolicies` turns
`journeys.alerts.json` into PromQL alerting policies sent to a notification
channel, and the dashboard JSON loads into a Grafana whose Prometheus data
source is Managed Prometheus's query frontend (a `runServices` sidecar).

On unmodified pronto the generate step re-applies the door's route in
`docker/Caddyfile`, which pronto's writer regenerates without it. The door
refuses a batch past 64 KB (413); the collector drops a session's events past
`journeys.limit` (600 a minute by default) and counts them as
`journey_telemetry_throttled_total` — the door's stock Caddy has no rate
limiter, so the rate is the collector's. A gesture's
outcome is read from the state the terminal shows next — `success`, the
server's `validation-error`, `network-error` — and a handler that leaves the
screen out of `network-error` is ok, so the reporter never needs the terminal
changed. A pages-only release has no door and no collector, which the no-data
alert says.

### Example

[`examples/hello-journeys`](examples/hello-journeys) is pronto's idioms app
with two journeys on it, the host added as any app would add it; its
[journal](examples/hello-journeys/journal/index.html) shows a run measured
through the door.

## pronto-perf

Measures how a pronto app runs on its readers' devices, games first: frame
times, long animation frames, interactions (INP's measure), the largest paint,
layout shift, and WebGL contexts lost, by screen, GPU family and browser. A
host-DOM hatch on every screen measures whatever draws the page, so a game needs
no code; one that wants to add what only it knows — draw calls, GPU time, its
quality tier — dispatches it on its screen once a frame:

```js
screen.dispatchEvent(new CustomEvent("pronto:perf", { detail: { drawCalls, gpuMs, tier } }));
```

```sh
<this repo>/bin/pronto-perf . [endpoint=/perf]
./saytw --script tools.nu cue cmd generate ./pronto   # the seat: promtool, Vector, the generate rule
./saytw --script tools.nu mise lock
# declare the two hatches in ir.html (and a decision), list screens with hatches of their own
./saytw generate && ./saytw lint
./saytw launch@local    # the collector runs beside the door
./saytw --script tools.nu nu -c 'use perf/perf.nu; perf report'   # what it has counted
```

The reporter buckets in the browser and posts every 30 seconds and when the
page hides: a few hundred bytes, never a frame each. What leaves the page is
counts and the device's kind — a GPU family, a browser, an OS, mobile or
desktop — never the renderer string, an address or anything typed; a browser
sending Global Privacy Control or Do Not Track reports nothing, and `sample`
reports a share of sessions. `?perf=overlay` draws the same numbers on the
page, sent or not.

| Path in the app | |
| --- | --- |
| `pronto/perf.cue` | a seat beside `pronto/config.cue`'s: promtool and Vector pinned, and a `generate` rule after pronto's writer |
| `perf_plugin.cue` | the schema (`#Perf`), in the program's package |
| `perf_hatch.cue` | the reporter, a `host-dom` hatch on every screen, and the collector, a `container` hatch and its cluster target (Vector; on a host launch, the same Vector through mise), a peer of the door |
| `shell/hatches/perf/perf.js` | the reporter |
| `shell/hatches/perf/config.js` | regenerated: the sample and each histogram's boundaries, the collector's own |
| `perf/perf.nu` | the generate step (the door's route, `observability/`, the reporter's settings), the host collector, and `perf report` |
| `perf_spec.cue` | written once, then the app's: `perf: #Perf & {…}` — the SLOs, the sample, the owner |

`observability/` holds the collector's config and its Vector unit tests (run by
`lint`), the rules — the share of frames under a budget (95% under 50 ms by
default), of interactions under one (75% under 200 ms), and of sessions that
lose no WebGL context (99.5%), each burning as the workbook's three windows,
plus a no-data alert — and the dashboard (uid `pronto-perf`). Every report is
validated by the collector field by field: a label is one of its few values or
`other`, a count is bounded, and a malformed report is dropped.

The door refuses a batch past 32 KB; the collector drops a session's reports
past `perf.limit` (120 a minute) and counts them as
`perf_reports_throttled_total`. A release with no collector behind the door
answers the reporter's first post with an error, and the tab stops posting.
On a host launch the collector's `http` and `metrics` ports are ones the launch hands out
(`expose: http: {port: 8687, env: "PERF_HTTP_PORT"}`), so stacks side by side never share one, and
the door reaches the collector by its peer address:
`cluster: surface: targets: caddy: entrypoint: env: PRONTO_UPSTREAM_PERF_COLLECTOR: {peer: "perf-collector", port: "http"}`.
Every host adds its own `PRONTO_UPSTREAM_<NAME>` to that one record, so hosts join, and an app whose
program renders on request adds its peer's beside them. Containers keep their names and ports
(`perf-collector:8687`).


## pronto-modular-design

Starts a modular app, or refreshes one: an app's design (its CUE spec) split into modules, small packages each exported on its own
and joined by a small one, so an edit to a lesson, a question or a level re-evaluates its module and the join, not the whole spec.
Worth it only when the design's own `cue export` is the cost; the skill says how to measure that first (aprende: 8 evaluations of
about 20 CPU-s and 9 GB each, now one module and a join, about 12 CPU-s and 1.2 GB; Bonk Chess: its spec costs 0.45 CPU-s, so it was
not split).

```sh
<this repo>/bin/pronto-modular-design .
./saytw --script tools.nu cue cmd generate ./pronto   # the seat: the generate rule
./saytw generate && ./saytw lint && ./saytw test
```

| Path in the app | |
| --- | --- |
| `pronto/modular_design.cue` | a seat beside `pronto/config.cue`'s: a `generate` rule (`nu modules/build.nu`), before pronto's writer, which evaluates a program that reads the exports |
| `modular_design_plugin.cue` | the schema (`#ModularDesign`, whose check is the lint, in `test`), in the program's package |
| `modules/modules_plugin.cue` | `#Modules`, in package `modules` |
| `modules/build.nu` | the build step: each module exported in `needs` order, the export written beside every module that reads it (`deps/`) and for the join |
| `modules/lint.ts` | fails when a module imports another module's CUE (the schema excepted), two modules own overlapping paths, or `needs` has a cycle |
| `modular_design_spec.cue` | written once: opts the lint into the program's checks |
| `modules/modules.cue`, `modules/schema/`, `modules/example/`, `join/` | written once, in an app with no `modules/modules.cue`: the app's own from then on |

[`modular-design/README.md`](modular-design/README.md) has the rules; the
[`pronto-modular-design` skill](skills/pronto-modular-design/SKILL.md) the measuring, the split and the pitfalls.

## pronto-identity

Social sign-in beside the passkey, with no client, secret or cloud console of
an app's own. Two halves:

- **The identity broker** (`identity/broker/`), run once by the framework's
  operator: an OpenID Connect provider in front of the social providers
  (Google first), whose clients the operator registers once.
- **The app side**, configuration alone: the program names the providers
  (`auth.providers`) and puts the broker in each one's place
  (`auth.provider.<name>`), so mecha's own auth service signs in through it
  and the terminal draws the way in. No code of this plugin runs in an app.

Each application is its own tenant, and tenants are never merged. Its client
id is its origin (a public client proving its code with PKCE), its one
redirect per provider that origin's `/auth/oidc/<provider>/callback` (mecha's),
exact, and the subject the
broker vouches for is pairwise: a keyed hash of tenant, provider and the
provider's subject, so a person is a stranger to every other app. Codes are
single-use and redeemable only by the tenant and redirect they were issued
to; an ID token's audience is that tenant alone. Only that subject is kept,
and a provider's person is an account of its own, never a promoted guest.

It needs a pronto with `auth.providers` and `auth.provider`, a mecha whose
auth service signs in by OpenID Connect, and an omnishell that draws a
provider's way in (the `feat/auth-oidc` forks).

```sh
<this repo>/bin/pronto-identity . frontImage=<registry>/pronto-identity:<version>@sha256:<digest> [providers=<a,b>]
# or, signing in through a broker elsewhere, with no frontImage: broker=https://… [brokerInternal=<url>]
./saytw generate && ./saytw lint
```

| Path in the app | |
| --- | --- |
| `identity_signin.cue` | the providers, and the broker as each one's issuer: the auth service's defaults, which a deployment's `OIDC_<NAME>_*` overrides; no secret |

It also removes what earlier versions wrote (the wrapper, its image and hatch,
`identity/broker.env`) while each still carries its generated header.

The operator runs the broker once:

```sh
<this repo>/bin/pronto-identity-broker [env-file]   # default ~/.config/pronto-identity/broker.env
```

The env file, never committed, holds `BROKER_ISSUER`, `BROKER_SECRET` (it
derives every pairwise subject) and each provider's client, such as
`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Google's client has one
redirect URI, the broker's `<issuer>/callback/google`, never an app's. The
[`pronto-identity` skill](skills/pronto-identity/SKILL.md) covers both halves.

## pronto-billing

Paid plans for pronto apps, with no Stripe account, key or dashboard of an
app's own. One command sets it all up, stopping only where its author must act
(`bin/pronto connect stripe <app-dir>`, docs/intents.md).

Two halves, as pronto-identity's:

- **The billing broker** (`billing/broker/`), run once by the framework's
  operator in front of the one Stripe platform account the operator holds.
- **The app side**: the plans the app sells, a `Subscription` table only the
  database writes, and a small service beside the door that takes the
  broker's entitlements into it and sends an account to pay or to manage what
  it pays for. A paid feature's gate is the app's own, in its database, read
  from that table.

Each application is its own tenant, named by its origin as pronto-identity
names it, and its author is paid out through a Stripe connected account
(Express), the platform keeping `BILLING_FEE_PERCENT`. The broker keeps nothing
of its own: tenants, accounts and plans ride Stripe's metadata, and a tenant's
plans are read from its origin. Payouts are set up only with a secret the
author alone holds, whose hash the origin publishes: neither a stranger racing
the author through Stripe's onboarding nor a copy of another origin's document
attaches a bank account to it.

| | |
| --- | --- |
| `<origin>/.well-known/pronto-billing.json` | the app's: `{owner, plans: {<id>: {name, interval, prices: {usd: 499, brl: 1990}}}}`, prices in minor units, the first the default |
| `POST /onboard {tenant, owner, email, country?}` | the author, with the secret (`billing/owner.ts onboard`): Stripe's onboarding for the origin's payouts |
| `POST /checkout {tenant, account, plan, currency?, locale?, return?}` | a Stripe Checkout for one of the tenant's accounts; `return` a path on the origin. Anyone may ask; any other checkout the account left open is closed first |
| `POST /trial/offer {tenant, account, ticket, currency?}`, `POST /trial/checkout {tenant, account, ticket, locale?, return?}` | an opt-in free trial ([docs/stripe.md](docs/stripe.md#free-trial)): only on a single-use `ticket` the tenant minted, which the broker takes back from `<origin>/billing/trial/consent`. A broker without them answers 404 and no trial is offered |
| `POST /portal {tenant, account, manage, return?}` | Stripe's portal for that account, with the token its tenant was given |
| `POST /resync {tenant, account, plan, manage}` | the account's entitlement read again, for a tenant that missed a push |
| `POST <origin>/billing/events` | the broker's push: an ES256 JWT (`application/jwt`) whose audience is the tenant, `{sub, plan, status: active\|lapsed, through, manage, ver, trial?}`, checked by [`billing/entitlement.ts`](billing/entitlement.ts) against `/jwks` |

A changed subscription is read again from Stripe, all of the account's
subscriptions to the plan together, and pushed to the tenant, again if Stripe
changed while it was on its way; the webhook is answered only once the tenant
takes it, so Stripe's retries redeliver what a tenant missed, and a tenant
that refuses one is told no more of it. A plan whose price changes is sold at a
new Stripe price; a subscription keeps the one it was sold at. The broker runs
as one instance: an entitlement's `ver` is its clock.

### The operator

```sh
<this repo>/bin/pronto-billing-broker keygen    # BILLING_SIGNING_KEY=…, into the env file
<this repo>/bin/pronto-billing-broker webhook   # STRIPE_WEBHOOK_SECRET=…, once per platform account
<this repo>/bin/pronto-billing-broker [env-file] # default ~/.config/pronto-billing/broker.env
```

Without `STRIPE_SECRET_KEY`, on a localhost issuer, a stand-in for Stripe
takes payments at `/fake/stripe`: payouts set up at a press (or already, for
the origins `BILLING_FAKE_TENANTS` names), a checkout that pays, and a portal
that cancels, renews or fails the next payment. It listens on 127.0.0.1 and
refuses to run with a real signing key.

Or on Cloud Run, the broker at its own domain:

```sh
read -rs S; printf '%s' "$S" | gcloud secrets create billing-broker-stripe-key --project P --data-file=-
<this repo>/bin/pronto-billing-broker release --project P --domain billing.example.com [--fee N]
```

The platform account's key is the operator's to store, never passed through
the release; the release makes the rest once (`BROKER_SECRET`,
`BILLING_SIGNING_KEY`) and registers Stripe's webhook for
`https://<domain>/stripe`, keeping its secret beside them. After the key
changes, from a test key to a live one say, `--webhook` registers it again
for the new key. The broker runs as one instance, at most: an entitlement's
`ver` is its clock. The domain is mapped to the service; its DNS records are
the operator's to add.

### An app

```sh
deno run <this repo>/billing/owner.ts new                    # the author's secret, and its hash
<this repo>/bin/pronto-billing <app-dir> <hash>  # writes the files below
# say what the app sells in billing_spec.cue, and gate the paid feature
./saytw generate && ./saytw lint
PRONTO_BILLING_OWNER=<secret> deno run --allow-net --allow-env <this repo>/billing/owner.ts onboard <broker> <origin> <email>
```

| Path in the app | |
| --- | --- |
| `billing_plugin.cue` | the schema, the `Subscription` entity, the `billing_01` migration (`billing_entitle`, `billing_manage` and `billing_me`, a trigger refusing sessions' writes), the free trial's (`_billingTrialMigration`: `billing.trial` and its functions), the `billing` container hatch and its target, and on a developer's machine the broker with its stand-in |
| `pronto/billing.cue`, `billing/billing.nu` | the generate step giving the door `/billing/*` and `/.well-known/pronto-billing.json` again after pronto's writer |
| `billing/` | the service and the broker, run from the app's own files |
| `billing_spec.cue` | written once, then the app's: the broker, the owner's hash, the plans, the grants, and the `Subscription` type id mint stamps |

An author gives accounts a plan free in the spec, each through the end of a
day in UTC: `grants: "<account>": {analysis: "2027-01-31"}`, refused by
`cue vet` for a plan the app does not sell, a day that is no day or an account
that is no uuid. The billing service hands the whole set to `billing_grant`.
In an app with pronto-flags, the grants are the flag `billing_grants` too
(`_billingFlags`: flagd's address at hand, `"origin"` in a release, which reads
it through the app's own door), and the service reads that flag every minute: a
new grant, a moved day or one taken out reaches the database within a minute of
`pronto-flags push`, with no deploy, and a flagd that can't be reached takes no
grant away. Without pronto-flags, the service takes the set as it starts, so a
release brings it. A grant past its day is no plan, either way. A flag is read
by anyone who asks the door for it, so the grants are public too. A grant's row is the broker's
`subscription` row with `ver` 0, so the gate and the pages read it as they read
a payment, and a payment always outranks it: a grant takes no row the broker
holds while it is paid through.

The service holds no secret: an entitlement is checked against the broker's
keys, a reader is who the REST gateway says their session is
(`billing_me`), and the database is written as the service through the
gateway. A paid feature's gate reads `subscription` in the app's own
migration: whether the session's account holds the plan, `active` and
`through` after now.

A gcp release runs the service as a sidecar with its compose environment
(`sidecars: billing: {port: 8688}` in `release.cue`), and names the
operator's broker there in place of the one on a developer's machine:
`env: {BILLING_BROKER: "https://billing.example.com", BILLING_BROKER_INTERNAL: …}`,
which needs a pronto whose release lets `release.cue`'s keys win over
compose's (bsoneca/pronto-fork#21).

## pronto-airlock

An app's own airlock on a metal cluster (pronto's `envs.Metal`): mecha's airlock with its doors,
for calls an app's service makes outside that must be answered now, recorded once and billed once
(mecha's `services/airlock/README.md`, "A door"). The objects are `common/airlock.nu`'s, the ones the
billing and identity brokers' `--airlock` use; the doors come from the app's spec, written in its CUE
and exported:

```sh
cue export <app> -e modelAirlock --out json > /abs/spec.json   # Studio's: apps/studio/release.cue
<this repo>/bin/pronto-airlock metal --spec /abs/spec.json [--ssh U@H] [--kubeconfig K]
```

Each door is `{door, base, var?, scheme?, secret?: {name, key}, headers, timeoutMs?, egress?}`: its
sink, the credential the airlock adds as `Authorization` (read into `var` from a Secret already on the
node, never written here), the headers a caller may set (`{name, hidden: true}` reaches the sink and
is frozen in the ledger only as its sha256), how long the sink may take (whole seconds, at most ten
minutes, given to daprd's resiliency policy as well), and, for a sink inside the cluster, the egress
rules that reach it in place of public HTTPS. `from` is who may reach the door's port. The release
refuses a credential whose Secret is not there, then checks from inside the pod that each door
answers.

## pronto-flags

Feature flags for pronto apps, on [OpenFeature](https://openfeature.dev), the
CNCF's vendor-neutral flag API, and [flagd](https://flagd.dev), its flag
daemon (both Apache-2.0). An app says its flags in CUE; generate turns them
into flagd's flag definitions; flagd runs beside the door, as a container or a
Cloud Run sidecar, and answers OpenFeature's remote evaluation protocol (OFREP)
at `/ofrep/` on the app's own origin, which the terminal's `connect-src 'self'`
allows. Where the app is released, flagd reads them live from one object in a
versioned Cloud Storage bucket, its own `gcs` sync, polled every few seconds:
a flag changes with `pronto-flags push`, never a deploy, and every push is a
version of the object, which `pronto-flags rollback` restores. No database, no
admin UI and no third party. The flags are baked into flagd's image too, and
serve wherever there is no live object: a developer's launch, CI.

```cue
// flags_spec.cue, the app's own
flags: premium: {
	note:    "Premium, off where released until billing runs there."
	default: false // wherever the app is released
	local:   true  // wherever the door is reached at hand: a developer's launch, CI
}
```

`local` is the door's word, not the page's: the door tells flagd which host a
request reached (`localhost`, `127.0.0.1`, or compose's `caddy`, as CI's checks
reach it), over any header a page sent, and a flag's targeting picks `local`
there. A flag without `local` has one value everywhere.

`accounts` names the accounts that read `local` wherever the app runs, by the
`sub` of their session's token. The door, not the page, says which account a
request is from: it asks the auth service's `/auth/door`, which always answers
2xx, and gives flagd the verified session's `sub` as OpenFeature's
`targetingKey` (flagd's `--context-from-header`), over any a page sent in the
request's body or headers. A request with no session, or a bad token, is no
account. So a flag opens a feature to an account and never guards one: what an
account may do stays the database's.

```cue
flags: premium: {default: false, local: true, accounts: ["<an account's id>"]}
flagsLive: {project: "my-project", bucket: "my-project-flags"}
```

### Live flags

```sh
<this repo>/bin/pronto-flags setup <app-dir>               # once: the bucket, its readers, the first push
<this repo>/bin/pronto-flags push <app-dir>                # the flags as flags_spec.cue says them now, once a changed flag's cases pass
<this repo>/bin/pronto-flags cases <app-dir> [flag]        # the cases a flip runs (below)
<this repo>/bin/pronto-flags history <app-dir>             # every version, newest first: when, by whom, from which commit
<this repo>/bin/pronto-flags rollback <app-dir> [version]  # the version before the live one, or the one named
<this repo>/bin/pronto-flags show <app-dir>                # what a push would write, and where: nothing written
```

Each runs as the operator's own gcloud login. `setup` makes `flagsLive`'s
bucket private and versioned, keeping the last 50 versions, and lets the
release's run account and its previews' read it, since flagd reads it as the
service it runs in. `push` writes over only the version it read, so two pushes
never silently undo each other, and a rollback is itself a new version. The
release hands flagd the object, once `setup` has made it, since flagd stops at
start on a source it cannot read: in `release.cue`,
`sidecars: flagd: {port: 8693, cpu: 80, apart: {}, env: FLAGD_SOURCES: "<…>"}`,
spelled out as `cue export -e flagsLive.sources` prints it, since a release
reads `release.cue` alone; `GCP: sidecars: flagd: env: FLAGD_SOURCES: flagsLive.sources`
in `flags_spec.cue` makes lint fail if the two part. A page reads a change on
its next load.

### A flip runs its cases

The design, and why it has this shape: [docs/flag-flips.md](docs/flag-flips.md).

A flag's value can break what it turns on, and a push runs no release check. So
a push that changes a flag's default value, or adds a flag, runs that flag's
cases before the flag is on for everyone, and `rollback` stays the fast way out
(it runs no cases):

```cue
flagsLive: {url: "https://shop.example"}
flagsCases: {
	live: "deno run -A tests/flip.ts"  // on production; env FLAG, ONLY, APP_URL
}
```

A flag's cases are the scenarios (`tests/scenarios/*.cue`) and unit cases
(`tests/unit/*.cue`) that name it in `flags: ["<flag>"]`, or in a step's `flag`;
`pronto-flags cases <app-dir> [flag]` lists them. A flip runs nothing at hand: it
builds and launches no stack, since the pull request's gate already ran every case
with the flag on (at hand every flag reads its `local` value). No tester account is
needed (the owner, 2026-11-11: "drop the requirement of testers for flag flips",
PRONTO-284). `pronto-flags push <app-dir>`:

1. reads the live object and finds the flags whose default value moves; a flag
   with no cases is refused, or pushed with `--untested "<why>"`, loudly;
2. refuses, with nothing written, a flip whose flag has `production` scenarios
   while the app lacks `flagsLive.url` or `flagsCases.live`;
3. writes the flags as the spec says them, for everyone, in one version
   (`stage=all`); with no `production` case to run it stops there
   (`cases=none on production`, or `untested`);
4. otherwise waits until OFREP at `flagsLive.url` answers the new value (every
   2 s, 90 s at most), runs `flagsCases.live` against production with the flag's
   `production` scenarios that need no tester (no `signIn` step), and writes
   `cases=passed`; a failure, or an OFREP that never answers, writes the version
   read before the push again as the newest, prints the report and exits non-zero.

A `production` scenario that signs in is listed and not run: a flip has no tester to
sign in as. `--no-canary "<why>"` (pronto-plugins#184) is still accepted and does
what every push does now; its reason is kept in the journal.
`pronto-flags history` shows each version's stage, flag, cases verdict and reason.

What runs on production is held narrow. Only scenarios marked `production: true`
run there, and the scenario schema allows one actor, no sign-up, no payment step
(`pay`), no other player and no move, table or game, and only GET requests. The
runner refuses a scenario that isn't marked `production` against the host
`flagsLive.url` names.

### pronto-armies: the second object kind of the push

An app whose page reads its armies from the database (Bonk Chess: the `army_catalog` shape,
behind the flag `army_catalog_live`) publishes them with the same push, one kind over. Nothing
is a second mechanism: the stages, the cases and the roll back are the flip's above; only the
store differs. The rows are written by the database's own `SECURITY DEFINER` functions
(`player_record.army_catalog_set` and `army_catalog_drop`) through a command the app names, so
no app role can write a catalog.

```sh
<this repo>/bin/pronto-armies push <app-dir> [--local] [--untested "<why>"]
<this repo>/bin/pronto-armies show|history <app-dir> [--local]
<this repo>/bin/pronto-armies rollback <app-dir> <army> [version] [--local]
```

In the app's spec: `armiesLive: {flag, rows, local, live}`. `rows` are the armies to publish,
exported from the app's CUE (which refuses an unknown reskin, beat, asset or rig before anything
is written); `local` and `live` are the commands that run SQL (on stdin; rows printed unaligned)
in the stack at hand and in the released database; `flag` names the flag whose cases are the
catalog's (`flags: ["<flag>"]`, `production: true`), and `flagsLive.url` the address. A push
of rows that are new or differ:

1. needs cases, as a flip does (`--untested "<why>"` goes on with a warning), and, when the flag
   has `production` scenarios, `flagsLive.url` and `flagsCases.live`;
2. writes each changed army for everyone (and drops a testers' row an older push left);
3. runs the flag's `production` scenarios that need no tester against production, which wait for
   the army to reach the page through the shape; a failure writes back what was there (the entry
   it had, or no row) and fails the push.

`--local` writes everyone at once with no cases. Every write
prints `armies: target …`, takes `--expect <target>` and `--dry-run`, and is appended to the same
journal as the flags' (`event: armies.write`). `history` lists every write of every row (the
database keeps them); `rollback` writes an earlier entry again for everyone, as the newest.
[`flags/test/armies_test.nu`](flags/test/armies_test.nu) runs these against a stand-in for the SQL
command ([`fake_sql.py`](flags/test/fake_sql.py)).

### An app

```sh
<this repo>/bin/pronto-flags <app-dir>   # writes the files below
# say the app's flags in flags_spec.cue
./saytw generate && ./saytw lint
```

| Path in the app | |
| --- | --- |
| `flags_plugin.cue` | the schema, flagd's definitions (`flagd.document`), the `flagd` container hatch and its target: flagd's image with the flags baked in, or `flagd` from mise on a host launch |
| `pronto/flags.cue`, `flags/flags.nu` | flagd pinned for mise (`http:flagd`), and the generate step writing `flags/flags.json` and giving the door `/ofrep/*` again after pronto's writer |
| `flags_spec.cue` | written once, then the app's: its flags |

A page reads them with OpenFeature's web SDK and its OFREP provider
(`@openfeature/web-sdk`, `@openfeature/ofrep-web-provider`), the provider's
`baseUrl` the page's own origin. A flag the door cannot answer reads its
default, so a feature behind one is off until flagd says otherwise.

A gcp release carries flagd as a sidecar: in `release.cue`,
`sidecars: flagd: {port: 8693, cpu: 80}`, with the live source above. flagd holds ports
8693 (OFREP, the door's), 8694 (evaluation), 8695 (management) and 8696
(sync), clear of pronto-perf's 8687, pronto-billing's 8688 and 8689, which an app may hold
for a service of its own.

## pronto-ads

Rewarded ads: an ad a player chooses to watch for something the app gives in
return, never one that interrupts them. The page calls `rewarded()` from the
module the installer writes, which resolves `"viewed"` once the ad played to its
end, `"dismissed"` when it was closed before, and `"none"` with no ad to show.

```sh
<this repo>/bin/pronto-ads <app-dir> [<module-path>]   # ads/ads.js unless named
# name the AdSense publisher in ads_spec.cue: adsense: publisher: "pub-…"
./saytw generate && ./saytw lint
```

| Path in the app | |
| --- | --- |
| `ads/ads.js`, or the path named | the page's module: `rewarded()` |
| `pronto/ads.cue`, `ads/ads.nu` | the generate step giving the door `/ads.txt` again after pronto's writer, the publisher's line, which AdSense reads to verify the site |
| `ads_spec.cue` | written once, then the app's: its publisher, `""` for none |

The ad is always a stand-in that plays at a press, as billing's stand-in Stripe
pays at one. Real ads are not implemented: naming an AdSense publisher only
writes its line in `/ads.txt`, and `rewarded()` still shows the stand-in.
Google's ads for the web tell no server an ad was watched, so the page alone
knows: whatever a reward gives away, the app's database bounds (one a day an
account, say, in the app's own migration).

## Hosts share `.say.json`

sayt reads one `.say.json` beside pronto's `.say.yaml`, so every host marks it
`merge`: [`bin/write.nu`](bin/write.nu) merges a host's rules into the file,
its own lists replaced whole and other hosts' rules kept.

## Checks

```sh
./saytw --script tools.nu cue vet -c ./android
./saytw --script tools.nu cue vet -c -t app=check ./android/export
./saytw --script tools.nu cue vet -c ./firebase
./saytw --script tools.nu cue vet -c -t app=check -t project=check-project ./firebase/export
./saytw --script tools.nu cue vet -c ./gcp
./saytw --script tools.nu cue vet -c -t app=check -t project=check-project ./gcp/export
./saytw --script tools.nu cue vet -c ./infra
./saytw --script tools.nu cue vet -c ./examples/infra
./saytw --script tools.nu cue vet -c -t module=example.com/infra@v0 -t bucket=my-org-infra-tfstate -t project=check-project ./infra/export
./saytw --script tools.nu nu infra/test.nu
./saytw --script tools.nu cue vet -c ./journeys
./saytw --script tools.nu cue vet -c -t package=check ./journeys/export
./saytw --script tools.nu nu journeys/test.nu
./saytw --script tools.nu cue vet -c ./perf
./saytw --script tools.nu cue vet -c -t package=check ./perf/export
./saytw --script tools.nu nu perf/test.nu
./saytw --script tools.nu cue vet -c ./modular-design
./saytw --script tools.nu cue vet -c -t package=check -t module=check ./modular-design/export
./saytw --script tools.nu nu modular-design/test.nu
./saytw --script tools.nu cue vet -c ./migrations
./saytw --script tools.nu cue vet -c -t package=check ./migrations/export
./saytw --script tools.nu nu migrations/test.nu  # cue and deno on PATH
./saytw --script tools.nu nu flags/test/live_test.nu
./saytw --script tools.nu cue vet -c ./identity
./saytw --script tools.nu cue vet -c -t package=check -t broker=https://id.example.com ./identity/export
deno test --no-config --allow-net identity/oidc_test.ts identity/broker
deno lint --no-config billing && deno test --no-config --allow-net --allow-read --allow-write --allow-run billing
deno lint --no-config flags && FLAGD=$(mise where http:flagd)/flagd deno test --no-config --allow-read --allow-write --allow-run --allow-env --allow-net flags  # cue on PATH
deno lint --no-config ads && deno test --no-config --allow-read --allow-write --allow-run ads
deno test --allow-read --allow-env android/test/host_test.ts
```

`test@android` in an app runs the template's JVM tests: which requests are a
site, which an app, and which fields take the username and the password.

## CI trust

[`ci.yml`](.github/workflows/ci.yml) runs on `pull_request` only, holds no secrets, and has a
read-only token (`permissions: contents: read`, no persisted checkout credentials). Everything it
runs is pinned by digest, except the items listed below:

- the actions it uses are pinned by commit, and sayt is installed by the repository's own
  [`install-sayt`](.github/actions/install-sayt/action.yml) rather than by its third-party action;
- the binaries it downloads are checked against sha256 values written in the workflow: sayt, the
  mise its launcher runs, sayt's distribution (through a tool stub that carries the checksum), Deno,
  and flagd (the version the flags plugin pins); the nu and cue the launcher installs carry
  checksums in their own stubs and lockfiles;
- the Android job installs only the JDK, the Android SDK and Gradle, against the example's
  lockfile (`examples/hello-android/.config/mise/mise.lock`), not the example's other tools;
- the pull request's own code runs the checks, so a change to the workflow or to what it runs is
  reviewed like any other.

Still not pinned by digest, and why:

- **Android SDK packages**: mise installs the SDK's command-line tools from Google, whose download
  has no published checksum for mise to lock, and `sdkmanager` then fetches platform packages
  that Google's own manifest verifies.
- **Gradle plugins and Maven dependencies** (the Android Gradle plugin, Kotlin, JUnit): they have
  version coordinates, but the example has no `gradle/verification-metadata.xml`, so Gradle does
  not check their checksums.
- **The `vfox:mise-plugins/vfox-android-sdk` installer plugin** itself, which mise fetches with no
  commit or digest pin.
- **What the sayt v0.44.1 release itself carries**: its launcher's tool stubs (nu, cue) and what
  those fetch are as trustworthy as that release, whose binary and distribution are pinned above.
- **GitHub-hosted runner images** (`ubuntu-24.04`) and the `jq`, `curl` and `unzip` they carry.
