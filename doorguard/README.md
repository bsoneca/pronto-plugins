# doorguard

No public prefix of an app's door reaches a Dapr API path of the door's sidecar (PRONTO-1307).
The door's `/crud`, `/img`, `/blobs` and `/electric` handlers strip their prefix and proxy the rest
to daprd with a `dapr-app-id`, so `/img/v1.0/metadata` is a method of an app that may not run
(a 500 from Dapr). The guard answers 404 for `/<prefix>/v1.0…` and `/<prefix>/v1.0-alpha1…` first.

## Adopting it

```sh
bin/pronto-doorguard <app-dir>   # writes pronto/doorguard.cue and doorguard/guard.ts
```

Then run the app's `generate` and commit the Caddyfile. The step (`doorguard-route`, priority 5,
after pronto's writer and the API's route) splices a `# doorguard:begin` … `# doorguard:end` block
before the first top-level `handle` of docker/Caddyfile (and the comments above it). It is
idempotent and fails where the Caddyfile has no such `handle`.

The node release (`node/engine/push.nu`) refuses to build an app whose docker/Caddyfile lacks the
block, naming this plugin; the door check then asks `/img` and `/blobs` (and `-alpha1`) and fails
on anything but 404.

Test: `deno test --no-config --allow-read --allow-write doorguard/guard_test.ts`.
