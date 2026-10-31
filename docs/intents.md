# Intents: "connect Stripe", "deploy to GCP", one command each

Status: designed, 2026-10-29; the first intent, `connect stripe`, is being built
(`billing/connect.ts`).

Studio need not be a second Claude Code. What a person building an app asks for most is plumbing:
take payments, put it online, read its data in BigQuery. Each of those took a day of steps the first
time (an app's Stripe: a broker, a key, a webhook, an owner secret, onboarding, a budget, flags),
and nearly every step that went wrong was one nobody had written down as code. An **intent** is that
plumbing as a program: one command, run until it is done and proven, stopping only where a person
must act.

## What an intent is

One value per intent, the same shape for every one:

| part | what it is | where it lives |
|---|---|---|
| **spec** | what the app wants: its plans, its target, its dataset | the app's CUE (`billing_spec.cue`, `release.cue`, …), vetted like the rest |
| **steps** | each a `check` (done, to do, or waiting on a person) and an idempotent `apply` | the plugin's `connect.ts`, in the order they depend on each other |
| **gates** | the steps only a person can take, each a single link or answer | the steps that answer `gate`, with what to do and how to resume |
| **verify** | the proof it works: a page answering, a purchase going through, a row read | the intent's last step, which never reports done on "no error" alone |

`plan` runs every `check` and changes nothing: what is done, what is next, what waits on a person.
`connect` runs them in order, applying each step that is to do and checking it again after, until a
step waits on a person or every step is done. Run again, it starts where it stopped: a step done is
checked, not repeated, so a failure part way costs only a rerun.

## Gates: what a person must do, and nothing else

A gate is a step a program may not or cannot take: the law asks a person (Stripe's identity and bank
details), a provider asks for consent (OAuth), or it spends money. Everything else is the program's.

The way to keep gates few is the one pronto's plugins take twice: **a broker, or OAuth, instead of
a key.** Every key a person pastes is a step that can go wrong; the billing broker means an app's
author never holds a Stripe key, only one onboarding link, and the identity broker means an app never
holds Google's. An intent that needs a third party's account looks for that shape first.

| intent | its gates | the rest, the program's |
|---|---|---|
| `connect stripe` | the plan's price, if not given; Stripe's onboarding (identity, bank) once, through the broker's link | billing installed, the owner's secret made and kept in Secret Manager, its hash published, the broker named in the release, payouts checked, the live document verified |
| `deploy gcp` | a billing account, for a project of the person's own (none in Studio's shared project) | release target, project setup, database, secrets each the app's alone, the deploy, its address answering |
| `connect bigquery` | consent to the person's data (OAuth), or none for a dataset the operator keeps | dataset and grants in the infra state (OpenTofu), the app's reader, a row read back |

## Where it runs

- **From a terminal or Claude Code**: `bin/pronto plan|connect <intent> <app-dir> [flags]`,
  and a skill per intent that runs it.
- **In Studio**: a turn's Claude Code has the same plugin (`pronto-studio`) and runs the intent with
  `--studio`, on the app's own files alone; what needs the cloud is Studio's own code's, at the
  release the author presses (`connect stripe` below).
- The steps' decisions are pure functions with tests; what they touch (files, Secret Manager, the
  broker, gcloud) is passed in, so each intent is tested against stand-ins before it touches anything.

## `release`

```
bin/pronto release my-app          # its checks, its release, and what it sells through
bin/pronto plan release my-app     # what is done, what is next, changing nothing
```

The app's name and nothing else (`intents/release.ts`). Where it goes is its `release.cue`'s:
Cloud Run (`GCP`) or a Kubernetes cluster (`App`), and an app with neither is given a release
target on Cloud Run in the project it is told (`--project`, which has no default), as `deploy gcp`
writes it. It takes `deploy gcp`'s steps (its release rule, its
plan rendered as the dry run, `./saytw lint` and `test`), then releases with the app's own
`release@<target>`, and checks it answers where its release says (Cloud Run's address, the cluster
gateway's host). An app in a project shared with other apps (`--shared`, as Pronto Studio names
its own) is released from that host, so there it stops at a gate.

An app that sells through pronto-billing has its broker named in its release before it goes out
(the one `release.cue` names, else `--broker`),
and once it is out its plans published, its payouts set up at Stripe (the onboarding link the gate,
Stripe reaching the author at their git email) and the broker answering: `connect stripe`'s live
steps, with nothing to say. One that sells but is not set up yet is `connect stripe`'s first.

## `connect stripe`

Run it from a pronto-plugins checkout, on an app's folder:

```
bin/pronto plan stripe apps/my-app                    # what is done, what is next
bin/pronto connect stripe apps/my-app --plan pro --name "My App Pro" --usd 499 --brl 1990
bin/pronto connect stripe apps/my-app --origin https://my-app.example --email me@example.com
```

Steps, in order (`billing/connect.ts`):

1. **pronto**: billing's service is one of the program's host peers (`code.meta.hostPeers`), which
   pronto runs beside its own renderer from 0.24.1-gcp.26 on: an app on an older pronto is stopped
   before anything is touched, with what to update.
2. **installed**: pronto-billing's files in the app (`install.ts`), its migrations numbered after
   the app's own.
3. **owner**: the author's payout secret, made once and kept in Secret Manager
   (`pronto-billing-owner-<app>`) in `--project`, else in `release.cue`'s `billingSecretsProject`
   (for a release on a cluster, which names no project), else in the project its GCP release names,
   never printed; its hash is `billing.owner` in `billing_spec.cue`. With neither, it waits to be
   told one.
   An app whose spec names an owner whose secret is not there waits on its author to put it.
4. **plan**: something to sell, `billing.plans`: from `--plan <id> --name <name> --usd <cents>`,
   else a gate asking for it.
5. **ir.html**: the design document describes the `Subscription` entity, with the type id generate
   minted it, and the `billing` hatch, as pronto's facts and identity lints ask.
6. **generated**: the app generated and linted with it.
7. **broker**: where the app is released, the billing service reaches a billing broker, one its
   operator runs ([stripe.md](stripe.md#running-it)): the one `release.cue` names, else `--broker`.
   There is no default: a release naming none waits to be told one. A sidecar on Cloud Run (`GCP.sidecars`),
   a service of the app's own on a Kubernetes cluster (`App.services`, pronto 0.24.1-gcp.26).
8. **published**: the origin publishes the owner's hash at `/.well-known/pronto-billing.json`.
9. **payouts**: the broker says the origin's payouts are set up; else the gate is Stripe's onboarding
   link, made with the secret from Secret Manager, and the step waits until Stripe says it is done.
10. **verified**: the broker answers with its signing keys.

Steps 7 to 10 need the app's live origin (`--origin`), so they wait on its first release. Without it
the intent stops after step 6, with the app ready to sell in test mode on a developer's machine
(launch@local runs a broker whose Stripe is a stand-in). `--secrets-file <path>` keeps the secret in
a file instead of Secret Manager, for a trial.

In Pronto Studio, a host that releases apps itself, the same steps are split across a turn and a release:

- **In a turn**, `pronto connect stripe . --studio --plan … --name "…" --usd …` takes steps 1, 2, 4,
  5 and 6, the app's own files, which is all a turn may touch: it holds no Secret Manager.
- **Before a release** Studio makes, `--before-release` takes steps 3 and 7 in a checkout of main, the
  secret kept in the project Studio names (`--project`), the broker it names (`--broker`), then
  generated; what changed lands on main as its own pull
  request, so the release's tag holds it.
- **After it**, `--after-release --origin <where it went live>` takes steps 8 to 10. Studio's
  conversation gives the author a link of Studio's own (`/builder/payouts/<app>`), which asks the
  broker for a new Stripe link each time it is opened, so it never expires.

`--json` prints the outcomes as one JSON array, which is how Studio reads them.

## `deploy gcp`

```
bin/pronto plan gcp apps/my-app                       # what is done, what is next
bin/pronto deploy gcp apps/my-app                     # every step but the release
bin/pronto deploy gcp apps/my-app --release true      # and the release
```

Steps, in order (`gcp/deploy.ts`):

1. **server**: the app keeps rows on a server, or signs people in; a web app goes to pages instead.
2. **target**: `release.cue` names Cloud Run (`gcp/release_target.ts`), in `--project`, a Google
   Cloud project of the person's own, which has no default (without it, a gate), and `--region`
   (default `us-central1`); `gcp` among the program's targets. An author's `release.cue` naming no
   GCP release is theirs: a gate.
3. **generated**: the app's `.say.yaml` has its release@gcp rule.
4. **plan**: release@gcp's plan renders (`cue export -e gcpRelease.plan`): the dry run, before
   anything is made. In a shared project (`--shared`), only a pronto that keeps each app's secrets
   its own.
5. **checks**: `./saytw lint` and `./saytw test` pass.
6. **released**: with `--release true`, `./saytw release@gcp`, without the warm preview in the
   shared project (as Pronto Studio releases there); without it, a gate once every check passes.
7. **answers**: the service's address answers.

An app in a shared project is released from the host that shares it, never from a developer's
machine: there, `deploy gcp` without `--release` is the local dry run.

## Next

- How an app's author is paid, the operator or a third party: [billing-payouts.md](billing-payouts.md).

- `connect stripe`'s verify buys the plan in test mode against the stand-in (`launch@local`), as
  an app's own browser test can.
- Studio's release runs `deploy gcp` from its workspace's clone, instead of its own steps, and the
  per-person limit becomes a step of it.
- Studio shows intents as commands.
