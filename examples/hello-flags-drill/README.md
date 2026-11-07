# hello-flags-drill: break a flag, see the alert, roll it back

A tiny shop (`server.ts`: `/`, `/cart`, `/checkout`) whose checkout a flag can break, so the whole
loop runs on this machine and touches no cloud: pronto-flags writes the flag to a local store
(`.flags-live/`, `flagsLive: {dir}` in `flags_spec.cue`), flagd serves it, the server reads it, and
[pronto-probe](../../probe/README.md) runs the customer's journey against the server and says what
changed just before it broke.

- Flag `drill_break_checkout` (off): on, `/checkout` answers `500 checkout broken by drill`.
- Probe `checkout` (`probes_spec.cue`): `GET /`, `POST /cart`, `POST /checkout` expecting 200 and
  "order", every 5 s, alerting at the second failure.
- The installed plugin files (`flags_plugin.cue`, `probes_plugin.cue`, `probe/`, `pronto/`, `flags/`)
  come from `bin/pronto-flags examples/hello-flags-drill` and `bin/pronto-probe examples/hello-flags-drill`.

## The drill

All of it, unattended, with a timeline in BRT: `examples/hello-flags-drill/drill.sh`. The write-up of the
first run is [docs/flag-rollback-drill.md](../../docs/flag-rollback-drill.md). By hand, as the responder:

From a pronto-plugins clone, in five terminals (or background the first three). `FLAGD` is the
binary the flags plugin pins: `$(mise where http:flagd)/flagd`.

```sh
app=examples/hello-flags-drill
mkdir -p $app/.flags-live

# 1. flagd on the store's live file: OFREP on 8016 (--port is its gRPC port, not used here)
"$FLAGD" start --uri file:$PWD/$app/.flags-live/flags.json --port 8013 --ofrep-port 8016

# 2. the shop, asking flagd on every checkout
(cd $app && PORT=8787 FLAGD_URL=http://127.0.0.1:8016 deno run -A server.ts)

# 3. the probe
bin/pronto-probe run $app          # or: deno run -A probe/probe.ts $app

# 4. the bad release: flip the flag on (edit flags_spec.cue: default: true), then
bin/pronto-flags push $app

# 5. the probe prints ALERT with the push as the suspect and the command that undoes it
bin/pronto-flags rollback $app <the version it names>
# the probe prints RESOLVED with how long the checkout was down
```

flagd needs `flags.json` to exist before it starts: the first `bin/pronto-flags push $app` writes
it (an empty `{"flags":{}}` does until then). To see the probe without pronto-flags, edit
`.flags-live/flags.json` by hand (set the `default` variant of `drill_break_checkout` to `true`): flagd's file watch picks it up in a second, `/checkout` answers 500, the probe fails.

`PROBE_NOTIFY=0` keeps the macOS notification quiet. Every request the server answers is a JSON
line on its stdout, with the flag value it read (`drill_break_checkout`), so the line before the
first 500 shows what the server saw.
