# errors

What an app's pages throw, for its operator: uncaught errors, unhandled rejections and failed
loads, grouped into issues, counted per release and searchable, as Sentry does, self-hosted.

## Why GlitchTip

[GlitchTip](https://glitchtip.com) (AGPL) speaks the Sentry protocol, so any Sentry SDK or a small
reporter of our own sends to it. It is one process (web, ingest and tasks) with its queue in its own
Postgres, about 120 MiB at rest (PRONTO-187, measured on the Contabo node). Weighed against it:

- **Self-hosted Sentry** needs 16 GiB or more, plus Kafka, ClickHouse, Redis and Snuba.
- **Highlight.io** needs ClickHouse, Kafka and Redis, and its open-source edition is in maintenance.
- **Errors as log lines in VictoriaLogs** have no grouping, no issue states and no source maps.

## On a metal cluster

`bin/pronto-errors metal` ([`metal.nu`](metal.nu)) runs GlitchTip in namespace `errors` behind the
node's tunnel, with its database (CloudNativePG) beside it. Every secret is generated in-cluster.
Sign-up and new organizations are off. The one account is `owner@<domain>`, in organization `pronto`,
and each project named gets one. The run prints each project's id and public key, which a page sends.

The app names its server once, in its `errors_spec.cue`, and the run reads it from there with the
app's project (`slug`):

```cue
errors: #Errors & {
	server: {ssh: "user@203.0.113.7", kubeconfig: "$HOME/.kube/config", domain: "errors.example.com"}
	slug:   "my-app"
}
```

```sh
bin/pronto-errors metal ../my-repo/apps/my-app
```

Flags still do it by hand, and win over the app's spec:
`bin/pronto-errors metal --ssh user@203.0.113.7 --kubeconfig '$HOME/.kube/config' --domain errors.example.com --projects my-app`.

The server also gives the door's `upstream` (`https://<domain>`) and the command that reads the
source maps' upload token from the node; either can still be written by hand. The domain is a proxied
CNAME onto the node's tunnel. To sign in, copy the owner's password without printing it:

```sh
ssh user@203.0.113.7 'KUBECONFIG=$HOME/.kube/config kubectl get secret owner -n errors -o jsonpath={.data.password} | base64 -d' | pbcopy
```

## Installing it in an app

`bin/pronto-errors <app-dir>` writes the reporter, the door's route, the stand-in and a seeded
`errors_spec.cue`. Write the server and the slug, run `metal`, then write the `project` and `key` it
printed, and the acceptance ids the scenarios hold (`scenarios.accepts`). From then on the app's
generate writes `tests/scenarios/errors_plugin.cue`: `error_tracking`, a thrown error reaching the
stand-in through the door on a host launch, and `error_tracking_tester`, a `production` check that signs in
as a tester (`scenarios.tester` names the actor); a flip lists it and does not run it (PRONTO-284).

## What a page sends

A page reports to its own origin, never to GlitchTip's domain: the app's door routes
`/e/api/<project>/envelope/` to GlitchTip's ingest, so `connect-src` stays `'self'`. The reporter
(`shell/hatches/errors/errors.js`, a host-DOM hatch on every screen) is ours, about 150 lines and
no SDK, so it needs no script from another host and runs under the page's Trusted Types.

It reports:

- an uncaught error (`error` event), with its type, message and stack frames (filename, function,
  line and column, read from `error.stack` in Chrome's or Firefox's and Safari's format);
- an unhandled promise rejection;
- a script, link or image that failed to load (the window's capture phase sees the element's `error`).

Each is one Sentry envelope, a `POST` with `fetch` (`keepalive`, no credentials) to
`/e/api/<project>/envelope/?sentry_key=<key>&sentry_version=7`. An event carries `platform:
"javascript"`, `level: "error"`, `environment: "production"`, the `release`, the exception, and
`request.url`: the page's origin and path, never its query or its hash (nor, in a frame, a script
address's). The release is a digest of the page's own entry map (`#pronto-assets`, which names every
file the page loads by content address), so it changes with each release and with nothing else; a
page served without one says `unknown`.

It sends no user, no cookie, no breadcrumb and nothing a reader typed. The door drops the `Cookie`,
`Authorization` and `Referer` headers and every header that carries the sender's address
(`X-Forwarded-For`, `X-Real-Ip`, `Forwarded`, `Cf-Connecting-Ip`), so GlitchTip never holds a player's IP,
and caps a body at 64KB.

At most one report of each message, and twenty events a page load. It reports only while the
pronto-flags flag `error_tracking` is true, asked over OFREP at `/ofrep/` on the same origin; what is
thrown before the flag answers is held, then sent or dropped.

## Source maps

An error in GlitchTip shows its original file, function and line, not the minified bundle's. Each
bundle carries a debug ID (a UUID from its own SHA-256), appended by the app's build
(`deno run -A errors/sourcemaps.ts inject`, the bundles `sourcemaps.files` lists), so no line of it
moves. On load the bundle records its ID under its own stack (Sentry's `_sentryDebugIds`), and the
reporter sends, with each event, the IDs of the bundles its frames run through (`debug_meta`).

The maps are never served or committed. After each release, release-cron's step runs
`errors/sourcemaps.ts upload` in the tree released: it builds the bundles again with hidden maps
(`sourcemaps.build`, into the folder `ERRORS_MAPS_OUT` names), refuses unless each is byte-identical to
the committed one, and sends the maps with sentry-cli as a debug-ID artifact bundle to the project
`slug` of organization `org`. It signs with the token the Secret `upload` holds, which `metal` makes and
gives the owner's API token (upload scopes only); `sourcemaps.token` is the command that prints it:

```cue
errors: #Errors & {
	project: 1, key: "…", upstream: "https://errors.example.com", slug: "shop"
	sourcemaps: {
		files: ["shell/hatches/game/game.js"]
		build: "cd src && vite build" // writes $ERRORS_MAPS_OUT/shell/hatches/game/game.js and .map
		token: "ssh node 'kubectl get secret upload -n errors -o jsonpath={.data.token} | base64 -d'"
	}
}
```

## Use

From a pronto app, once GlitchTip runs (above) and has a project for it:

```sh
<this repo>/bin/pronto-errors .
# write the project and its public key (the run of `metal` printed them) in errors_spec.cue:
#   errors: #Errors & {project: 1, key: "<32 hex digits>", upstream: "https://errors.example.com"}
# add the flag `error_tracking` to flags_spec.cue (default: false where released, local: true at hand)
# list the screens that name their own hatches among _errorsOwnHatches and give each `errors`
./saytw generate && ./saytw lint
```

Until the project and the key are written the reporter does nothing. `generate` writes the reporter's
settings (`shell/hatches/errors/config.js`) and the door's route (`# pronto-errors:begin … :end`
in `docker/Caddyfile`). The key is public by design (every page sends it): it goes in the spec, not in
a secret.

On a host launch the door sends the reports to a stand-in for GlitchTip (`errors/standin.ts`, the
`errors` target), which keeps them in memory: `GET /events` says them as a JSON array, and through the
door `GET /e/api/events`, so a scenario can read what a page reported. Turn the flag on
(`pronto-flags push`) when the project exists; the flag's cases are the app's scenarios that name it.

## Tests

- [`tests.cue`](tests.cue): the spec's output, the reporter's guarantees and the host's files, checked with `cue vet`.
- [`test.nu`](test.nu): the door's route, the generate step, the stand-in (run with deno) and the reporter's stack parsing.

```sh
./saytw --script tools.nu cue vet -c ./errors
./saytw --script tools.nu cue vet -c -t package=check ./errors/export
./saytw --script tools.nu nu errors/test.nu
```
