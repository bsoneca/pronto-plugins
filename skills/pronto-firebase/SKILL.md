---
name: pronto-firebase
description: "Release a pronto app to Firebase Hosting, or refresh that setup: `sayt release@firebase` builds pronto's pages bundle, assembles the Hosting site with the files its host-DOM hatches need, versions and deploys it; plain `sayt release` deploys an expiring preview channel. Hosting only, the Firebase CLI pinned through mise. Use when the user wants a pronto app deployed on Firebase."
---

# pronto-firebase

The Firebase host is a plugin beside pronto, not a pronto target: pronto
0.14.0 admits no `firebase` in `meta.targets`, so the app targets none (or
others) and holds the host's generated files. It releases the same document
pronto's `pages` target bundles.

## What the app gets

| Path | Owner |
| --- | --- |
| `.say.json` | merged: the `release` rules `firebase` (`@firebase`) and `firebase-preview` (`@preview`, sayt's default); other hosts' rules in the file are kept |
| `.config/mise/conf.d/firebase.toml` | regenerated: Node and `npm:firebase-tools`, pinned |
| `firebase/site.nu` | regenerated: assembles `dist/firebase` |
| `firebase.json` | seeded once, then the app's: Hosting only, `dist/firebase`, every address to `index.html`. The app adds the `headers` and `redirects` its own documents need |
| `.goreleaser.yaml` | seeded once: the shim sayt's release ceremony runs |
| `.github/workflows/firebase.yml` | regenerated, only with a CI identity |

`dist/firebase` is the bundle as `index.html` plus, at their own paths, every
file a host-DOM hatch declares in `capabilities.hatches[*].files`, read from
the program at each release: the page imports a hatch's module by URL, and a
hatch may navigate to or frame a document of its own, none of which the
bundle carries.

## Adding it

From a bootstrapped pronto app whose four verbs are green, with the plugin's
own toolchain installed once (`./saytw --script tools.nu mise install` in
`${CLAUDE_PLUGIN_ROOT}`):

```sh
${CLAUDE_PLUGIN_ROOT}/bin/pronto-firebase . <firebase-project-id> [site=…] [channel=…] [expires=7d] [ciProvider=… ciAccount=…]
./saytw --script tools.nu mise trust .config/mise/conf.d/firebase.toml
./saytw --script tools.nu nu -c 'with-env {MISE_LOCKED: "0"} { ^mise install }'
./saytw --script tools.nu mise lock
./saytw release@firebase --snapshot
```

If the app targets `pages` only to be released here, drop it from
`meta.targets` first and run `generate`: pages emits a GitHub Pages workflow
that a pushed tag would trigger. Re-run `bin/pronto-firebase` with the same
arguments to refresh; the seeded files are kept.

## Releasing

```sh
./saytw release                      # preview channel, expiring URL; no version, no tag
./saytw release@firebase --snapshot  # build and assemble only
./saytw release@firebase             # version, tag, deploy, push the tag
```

Without a CI identity the live release deploys from this machine, as its
`firebase login`. With `ciProvider` (a Workload Identity provider trusting the
repository) and `ciAccount` (a service account with Firebase Hosting Admin),
the release only pushes the tag and `.github/workflows/firebase.yml` deploys
what the tag holds, keyless.

Every deploy is `--only hosting`: Firestore, Storage, Auth and their rules are
the app's data and are never deployed by this host. An app guarding that
should check `firebase.json`'s keys and every `firebase deploy` in
`.say.json` and the workflow.

## Done

The four web verbs exit 0, `release@firebase --snapshot` exits 0 with the
expected files in `dist/firebase`, and the site, served with
`./saytw --script tools.nu mise exec -- firebase emulators:start --only hosting`,
is walked as a person would. A live or preview deploy publishes: ask first.

## Limits

- An app whose streams or computations write live tables needs pronto's
  derived rows in the bundle, which these rules do not run yet.
- Pronto's `pages` refusals (a vendored unit, a shared entity, a validation)
  are not checked here; the bundler meets them as errors.
- A preview channel's `*.web.app` address is not an authorized Firebase Auth
  domain by default: add it to sign in on a preview.
