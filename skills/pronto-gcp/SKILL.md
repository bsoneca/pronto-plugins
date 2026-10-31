---
name: pronto-gcp
description: "Release a pronto app to Google Cloud Run, or refresh that setup: `sayt release@gcp` builds the app's door image for linux/amd64 without local certificates, checks it answers on :8080, versions it, pushes it to Artifact Registry and deploys it by digest, scaling to zero; plain `sayt release` deploys a preview service. gcloud pinned through mise. Use when the user wants a pronto app deployed on Google Cloud / Cloud Run."
---

# pronto-gcp

The Cloud Run host is a plugin beside pronto, not a pronto target: pronto
0.14.0 admits `gcp` in `meta.targets` and builds no rule for it (its
PENDING.md). The app holds the host's generated files. It releases the image
`sayt launch` runs as the door — Caddy serving the terminal, the screens and
every hatch's files — so what Cloud Run serves is what was launched locally.

## Scope

A door alone: an app whose entities are all `tab` or `device` and that has no
`capabilities.auth`. `gcp image` refuses any other app, naming its server rows,
before building anything: those need Cloud SQL, PostgREST, auth and Electric as
services beside the door (pronto's design: Cloud Run and Cloud SQL), which this
host does not build yet.

## What the app gets

| Path | Owner |
| --- | --- |
| `.say.json` | merged: the `release` rules `gcp` (`@gcp`) and `gcp-preview` (`@preview`, sayt's default) |
| `.config/mise/conf.d/gcp.toml` | regenerated: gcloud, and the Python 3.12 its installer needs on macOS |
| `gcp/gcp.nu` | regenerated: `gcp image` and `gcp deploy` |
| `.goreleaser.yaml` | seeded once: the shim sayt's release ceremony runs |

## Adding it

From a bootstrapped pronto app whose four verbs are green:

```sh
${CLAUDE_PLUGIN_ROOT}/bin/pronto-gcp . <project> [region=…] [service=…] [repository=pronto] [origin=https://…] [maxScale=3] [memory=512Mi]
./saytw --script tools.nu mise trust .config/mise/conf.d/gcp.toml
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw --script tools.nu mise lock
```

The project must exist with billing on. The user signs in themselves, in a
terminal of their own (`./saytw --script tools.nu mise exec -- gcloud auth
login`): never take or type their credentials.

## Releasing

- `gcp image <app>` (both rules' first step) builds the door from bayt's own
  definition (`.bayt/compose.caddy.yaml`: Dockerfile, stage, every additional
  context) for linux/amd64, streaming the context without `.certs`, then runs it
  and requires `/health` and `/` on :8080 and no `/certs/localhost-key.pem`.
- `gcp deploy` enables Cloud Run and Artifact Registry, creates the repository
  once, pushes with a short-lived token (no credential helper is written into
  Docker's config), writes `dist/gcp/<service>.yaml` and applies it with
  `gcloud run services replace`: the image by digest, minScale 0, the door's
  environment, a startup probe on `/health`, then `allUsers` as invoker.
- The door is told `ORIGIN`, the service's `https://<service>-<number>.<region>.run.app`
  unless `origin=` names a custom domain, and a random `ELECTRIC_SECRET` (its
  Caddyfile does not parse without one; a door-only app has no Electric). A
  variable the door reads that the host does not know refuses.
- `release@gcp` runs sayt's ceremony between image and deploy, so it needs a
  git repository; `--snapshot` builds and checks only.

Deploying creates billable resources in the user's project: confirm with them
before the first `release`, and say which project and region.

## Done

`gcp image` prints that the image answers on :8080, linux/amd64, with no
localhost key; after a deploy, the printed run.app URL answers `/health`.
