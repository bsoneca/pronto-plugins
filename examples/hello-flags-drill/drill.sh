#!/bin/sh
# The flag rollback drill, end to end, on this machine alone (README.md says each step):
# flagd on the local store, the shop, the probe; the bad flip with pronto-flags push; the alert naming it;
# pronto-flags rollback to the version the alert names; the probe green again. Every write names its target
# with --expect, so nothing but this example's .flags-live/ can be written.
#   examples/hello-flags-drill/drill.sh            from a pronto-plugins clone
# FLAGD: the flagd binary (default: the one mise installed for the flags plugin). Logs go to $DRILL_LOGS
# (default: a new temp dir), which the drill prints.
set -eu
here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd)
app=$here
logs=${DRILL_LOGS:-$(mktemp -d)}
FLAGD=${FLAGD:-$(ls -d "$HOME"/.local/share/mise/installs/http-flagd/*/flagd 2>/dev/null | tail -n 1)}
target="file://$app/.flags-live/flags.json"
export PRONTO_FLAGS_JOURNAL="$logs/flags-journal.jsonl" PROBE_NOTIFY=0
stamp() { TZ=America/Sao_Paulo date "+%H:%M:%S BRT"; }
say() { echo "drill $(stamp): $*" | tee -a "$logs/timeline.txt"; }
wait_for() { n=0; until grep -q "$1" "$2"; do n=$((n + 1)); [ $n -lt 120 ] || { say "gave up waiting for $1"; exit 1; }; sleep 1; done; }
pids=""
# The probe runs under wrappers (saytw, mise): its deno and the shop's are stopped by their paths, which are this app's.
cleanup() { [ -z "$pids" ] || kill $pids 2>/dev/null || true; pkill -f "probe/probe.ts $app" 2>/dev/null || true; pkill -f "$app/server.ts" 2>/dev/null || true; cp "$app/flags_spec.cue.drill" "$app/flags_spec.cue" 2>/dev/null && rm -f "$app/flags_spec.cue.drill"; }
trap cleanup EXIT INT TERM

for port in 8013 8016 8787; do
	! lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 || { echo "drill: port $port is taken: stop what listens there first" >&2; exit 1; }
done
cp "$app/flags_spec.cue" "$app/flags_spec.cue.drill"
rm -rf "$app/.flags-live"
"$root/bin/pronto-flags" setup "$app" --expect "$target" > "$logs/setup.log" 2>&1
"$FLAGD" start --uri "file:$app/.flags-live/flags.json" --port 8013 --ofrep-port 8016 > "$logs/flagd.log" 2>&1 &
pids="$pids $!"
(cd "$app" && PORT=8787 FLAGD_URL=http://127.0.0.1:8016 exec deno run -A "$app/server.ts") > "$logs/server.log" 2>&1 &
pids="$pids $!"
sleep 3
"$root/bin/pronto-probe" run "$app" > "$logs/probe.log" 2>&1 &
pids="$pids $!"
wait_for '"ok":true' "$logs/probe.log"
say "probe green"

sed 's/default: false/default: true/' "$app/flags_spec.cue.drill" > "$app/flags_spec.cue"
"$root/bin/pronto-flags" push "$app" --expect "$target" --untested "drill: the bad flip" > "$logs/flip.log" 2>&1
say "flip pushed: $(grep -o '"version":"[0-9]*"' "$logs/flip.log" | head -n 1)"
wait_for '"ok":false' "$logs/probe.log"
say "first failure"
wait_for 'probe.alert' "$logs/probe.log"
say "ALERT fired"
undo=$(grep -o 'undo: pronto-flags rollback [^ ]* [0-9]*' "$logs/probe.log" | head -n 1 | awk '{print $NF}')
[ -n "$undo" ] || { say "the alert named no flag write"; exit 1; }
say "diagnosis: the alert names the flip; history:"
"$root/bin/pronto-flags" history "$app" --json > "$logs/history.json" 2>&1
cp "$app/flags_spec.cue.drill" "$app/flags_spec.cue"
"$root/bin/pronto-flags" rollback "$app" "$undo" --expect "$target" > "$logs/rollback.log" 2>&1
say "rolled back to $undo"
wait_for 'RESOLVED' "$logs/probe.log"
say "$(grep RESOLVED "$logs/probe.log")"
echo "drill: logs in $logs"
