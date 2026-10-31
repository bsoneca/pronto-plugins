# intents

The runner behind `bin/pronto`: plumbing as a program. One command, run until it is done and proven, stopping only where a person must act. Run again, it goes on from where it stopped.

## What it adds

No files in an app. It is the TypeScript that drives the other plugins' steps:

- [`run.ts`](run.ts): runs an intent's steps in order. Each step is checked as done, to do (the program applies it) or waiting on a person. `plan` changes nothing.
- [`release.ts`](release.ts), [`release_cli.ts`](release_cli.ts): the `release` intent.
- [`shell.ts`](shell.ts): the commands the steps run.
- The `connect stripe` and `deploy gcp` intents live with their plugins, in [`billing/connect_cli.ts`](../billing/connect_cli.ts) and [`gcp/deploy_cli.ts`](../gcp/deploy_cli.ts).

The design is in [docs/intents.md](../docs/intents.md).

## Use

Say it in plain words and the [`pronto-intents` skill](../skills/pronto-intents/SKILL.md) runs it: "release my-app", "connect stripe to my-app", "what's left before my-app can sell?". Or run the command; an app is its name under `apps/` or its folder:

```sh
<this repo>/bin/pronto release <app>
<this repo>/bin/pronto connect stripe <app> [flags]
<this repo>/bin/pronto deploy gcp <app> [flags]
<this repo>/bin/pronto plan release|stripe|gcp <app> [flags]
```

[`setup.sh`](../setup.sh) installs the plugin and allows these commands in your user settings.

## Tests

The suites `stripe`, `deploy`, `release` and `runner` are CUE cases under [`tests/unit/`](../tests/unit), run by [`tests/unit.ts`](../tests/unit.ts).
