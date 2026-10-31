---
name: pronto-intents
description: "Do what the user names in plain words for a pronto app, end to end: \"release my-app\", \"connect stripe to my-shop\", \"deploy my-app to gcp\", \"what's left before my-app can sell?\". Runs pronto's intents (bin/pronto release|connect stripe|deploy gcp, docs/intents.md), which check every step, apply what is the program's, and stop only where a person must act. Use whenever the user asks to release, deploy, ship, publish or put online an app, or to connect it to Stripe or take payments, or asks what such a step still needs."
---

# pronto-intents

The user says what they want in a sentence; this runs it. They never type a command, never
see a flag, and are asked only what only they can answer.

## What a sentence runs

The app is its name, a folder under the repository's `apps/`; in a repository that is one app
(as pronto's bootstrap starts one), it is `.`. `pronto` is this plugin's
`bin/pronto`, on the PATH while the plugin is enabled: run it bare, as one command, from the
repository the app is in (`pronto release my-app`, never chained or wrapped in a `cd`).
It runs without a prompt once the user has allowed it in their own settings, which a plugin
cannot: pronto-plugins' `setup.sh` does it, theirs to run. Until they have, say that in one line the
first time a command asks.

| The user says | Run |
| --- | --- |
| release / deploy / ship / put online `<app>` | `pronto release <app>` |
| what's left to release `<app>`, is `<app>` ready | `pronto plan release <app>` |
| connect stripe to `<app>`, let `<app>` take payments, sell `<thing>` in `<app>` | `pronto connect stripe <app>` |
| deploy `<app>` to Google Cloud / Cloud Run, the first time | `pronto deploy gcp <app>` |

`release` finds where the app goes (its `release.cue`: Cloud Run or a Kubernetes cluster),
runs its checks, releases it, checks it answers, and, where it sells through
pronto-billing, carries on to its payouts. Run it as asked: it is the user's sentence, and
the release is what they asked for.

## Going on until it is done

Each line the command prints is a step: `✓` done, `→` waiting on a person, `✗` failed. The
command stops at the first `→` or `✗`; run again, it goes on from there. So:

- **`→` a question only the user can answer** (what to sell and for how much; an email):
  ask it in one plain sentence, then run the same intent again with the answer as its flag
  (`--plan pro --name "Minesweeper Pro" --usd 299 --brl 990`; prices are in cents).
- **`→` something only the user can do** (Stripe's form at a link, signing in somewhere):
  give them the link and what to do there in one line, and run the intent again once they
  say it is done.
- **`→` something the program can fix** (its pronto too old, a check failing): fix it as
  any change to the app is fixed (AGENTS.md: tests, `integrate@local`, a pull request), then
  run the intent again.
- **`✗` failed**: read what it says, fix the cause, and run again. Never paste the user
  a command to run instead.

Tell the user what happened in a sentence or two, in their words: where the app is now, what
it sells, what is left. Not the step list.

## In a hosted builder

A builder turn (the folder is one app, `.`, and nothing outside it may be touched) runs only the
app's half of `connect stripe`, with `--studio`, one command and no quotes but the plan's name:

`pronto connect stripe . --studio --plan pro --name "Minesweeper Pro" --usd 299 --brl 990`

Ask what to sell first if they have not said. Once it ends, tell them that pressing Release puts
it online and gives them, in this conversation, the link to Stripe's form for their payouts.
`release`, `deploy gcp` and anything without `--studio` are the builder's to do, never a turn's.

## Never

- An app in the builder's shared project is released from the builder: `release` stops there, and so
  does this. Say so; do not work around it.
- The author's payout secret is never printed, asked for, or pasted: the intent keeps it in
  Secret Manager itself.
- Nothing is released that its own `plan` says fails.
