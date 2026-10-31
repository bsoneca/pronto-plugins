# firebase

Releases a pronto app to Firebase Hosting. Hosting only, the CLI pinned through mise, nothing global.

## What it adds

- `sayt release@firebase`: builds pronto's pages bundle, assembles the Hosting site with the files the app's host-DOM hatches need, runs sayt's version ceremony and deploys.
- Plain `sayt release`: deploys an expiring preview channel, with no version.
- Files in the app: `.say.json` (rules `firebase` and `firebase-preview`), `.config/mise/conf.d/firebase.toml`, `firebase/site.nu`, `firebase.json` and `.goreleaser.yaml` (both written once), and with `ciProvider` and `ciAccount` a `.github/workflows/firebase.yml` that deploys on a tag.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-firebase . <firebase-project-id> [site=…] [channel=…] [expires=7d] [ciProvider=… ciAccount=…]
./saytw --script tools.nu mise trust .config/mise/conf.d/firebase.toml
./saytw --script tools.nu mise lock
./saytw release@firebase --snapshot
```

`bin/pronto-firebase` exports [`host.cue`](host.cue)'s files (see [`export/`](export)) and writes them. The [`pronto-firebase` skill](../skills/pronto-firebase/SKILL.md) covers releasing and its limits. Config: the Firebase project id, and optionally the site, channel and expiry.

## Tests

[`tests.cue`](tests.cue) checks the exported files with `cue vet`.

```sh
./saytw --script tools.nu cue vet -c ./firebase
./saytw --script tools.nu cue vet -c -t app=check -t project=check-project ./firebase/export
```
