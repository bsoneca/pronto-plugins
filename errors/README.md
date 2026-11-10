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
and each `--projects` name gets a project. The run prints each project's id and public key, which
a page sends:

```sh
bin/pronto-errors metal --ssh bruno@13.140.186.223 --domain errors.bonkchess.com --projects bonk-chess
```

The domain is a proxied CNAME onto the node's tunnel (pronto's `infra/gcp/outside.cue` lists it).
To sign in, copy the owner's password without printing it:

```sh
ssh bruno@13.140.186.223 'KUBECONFIG=$HOME/.cache/contabo2.kubeconfig kubectl get secret owner -n errors -o jsonpath={.data.password} | base64 -d' | pbcopy
```

## What a page sends

A page reports to its own origin, never to GlitchTip's domain: the app's door routes
`/e/api/<project>/envelope/` to GlitchTip's ingest in the cluster, so `connect-src` stays `'self'`.
An event carries the error, its stack, the page's path (no query, no hash), the release, and nothing
about the person: no user, no cookie, no IP (the door drops them).
