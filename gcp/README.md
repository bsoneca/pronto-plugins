# gcp

Releases a pronto app's door to Google Cloud Run.

## What it adds

- `sayt release@gcp`: builds the door image for Cloud Run's linux/amd64, checks it answers on :8080, runs sayt's version ceremony, pushes it to Artifact Registry and moves the service to it by digest, scaling to zero and public.
- Plain `sayt release`: deploys the same image to `<service>-preview`, with no version.
- Files in the app: `.say.json` (rules `gcp` and `gcp-preview`), `.config/mise/conf.d/gcp.toml`, `gcp/gcp.nu`, and `.goreleaser.yaml` (written once).

Only for an app whose rows the browser keeps. An app with server rows or auth is refused: it needs services beside the door that this host does not build yet.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-gcp . <gcp-project-id> [region=us-central1] [service=…] [repository=pronto] [origin=https://…] [maxScale=3] [memory=512Mi]
./saytw --script tools.nu mise trust .config/mise/conf.d/gcp.toml
./saytw --script tools.nu mise lock
./saytw release        # the preview service
./saytw release@gcp    # a version
```

Or in a sentence, through the [`pronto-intents` skill](../skills/pronto-intents/SKILL.md): `bin/pronto deploy gcp <app>` ([`deploy.ts`](deploy.ts)), which also covers apps with a server database. The [`pronto-gcp` skill](../skills/pronto-gcp/SKILL.md) covers releasing and its limits. `bin/pronto-gcp` exports [`host.cue`](host.cue)'s files (see [`export/`](export)). Config: the Google Cloud project id; `gcloud auth login` in a terminal of your own.

## Tests

[`tests.cue`](tests.cue) checks the exported files with `cue vet`.

```sh
./saytw --script tools.nu cue vet -c ./gcp
./saytw --script tools.nu cue vet -c -t app=check -t project=check-project ./gcp/export
```
