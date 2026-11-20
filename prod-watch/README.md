# prod-watch: what production logged that may be a bug

Reads Cloud Logging for an app's Cloud Run services, and, for an app that releases to a node
(release@k8s), the logs of its pods in the node's VictoriaLogs, groups what may be a bug by
fingerprint and says what is new since it last looked. An agent runs it on a loop ([the pronto-prod-watch
skill](../skills/pronto-prod-watch/SKILL.md)), triages each new fingerprint (a bug to fix in a pull
request, or noise with a reason) and checks after a release that the fingerprint stopped. It only
reads: `gcloud logging read` with the caller's credentials, and on the node `kubectl get` and one
read query to VictoriaLogs, over ssh.

## What it adds

- `prod-watch/prod-watch.ts`, the driver (Deno), and `prod-watch/watch.js`, its rules, pure and held
  by the cases in [`tests/unit/fingerprint.cue`, `noise.cue` and `triage.cue`](../tests/unit). Both regenerated.
- `prod_watch_plugin.cue`: `#Watch` and `#Noise` in the app's package, holding `prodWatch` to them,
  with the lifecycle windows and the noise every app shares. Regenerated.
- `prod_watch.cue`, seeded once, then the app's own: the other services it answers for and its own noise.

## Turn it on for an app

```sh
bin/pronto-prod-watch apps/<app>      # from a pronto-plugins clone
```

Then edit the seeded `prod_watch.cue` (other services, the app's own noise), run the driver once
from the app's folder (below), and start the loop with the pronto-prod-watch skill. The app needs a
`release.cue` with `GCP` (project, service, and its `sidecars`), or a `prodWatch.node` (below), or both.

## Run it

From the app's folder, with `cue`, `deno` and `gcloud` on `PATH` (an app's mise has the first two):

```sh
deno run -A prod-watch/prod-watch.ts brawl-chess              # since the last run (3 days on the first)
deno run -A prod-watch/prod-watch.ts brawl-chess --since 6h   # a window, the ledger and cursor untouched
deno run -A prod-watch/prod-watch.ts brawl-chess --json       # the same, as JSON
deno run -A prod-watch/prod-watch.ts brawl-chess ls open      # the ledger, by status
deno run -A prod-watch/prod-watch.ts brawl-chess mark 31db50 fixed --pr 501
deno run -A prod-watch/prod-watch.ts brawl-chess mark c254d4 noise --reason "..."
```

A report lists, in full, each fingerprint that is **new**, **regressed** (marked fixed and seen
again after the mark) or **rising** (open, 5 times or more this run and over twice its rate so far),
with its count, first and last seen, revisions and up to three samples; then the open ones a line
each; then how much was noise. A fingerprint is a prefix of the sha1 of the service and container,
the message's title with what varies taken out (timestamps, ids, addresses, query values, numbers)
and the app's own frame of a stack (`watch.js`). The header says how the app's fixes reach
production (`released`): `release-cron` when the app has a `release_cron.cue`, else `by hand`.

## What it reads

- **Which services**: the app's `release.cue` (`GCP`): its `service`, and `<service>-<name>` for each
  sidecar that runs `apart`; plus the `services` of its `prodWatch`.
- **Which entries** (Cloud Logging): a warning or worse, a 5xx, or a line with no severity that says it failed
  (error, panic, exception, traceback, fatal, refused, failed); never a request answered below 500.
  Also Cloud Run's start and shutdown lines, which open an instance's windows (below) and are
  never reported themselves.
- **A node's pods** (`prodWatch.node`, for an app released with release@k8s): see [A node's logs](#a-nodes-logs).
- **Browser errors**: the journeys collector writes each page error as an `ERROR` line
  (`frontend TypeError: ...`, with its top frame, screen and revision; journeys/README.md), so they
  are read, fingerprinted and triaged like any server line, under the collector's container.
- **A traceback written a line an entry** (Python's logging to stdout, as pronto-llm does) is put
  back into one entry before it is grouped.

## A node's logs

An app on the operator's node (release@k8s on k3s) has no Cloud Run service, and `kubectl logs` loses
a pod's lines when a release replaces it and rotates them as they grow. The node's Vector DaemonSet
ships every pod's lines to VictoriaLogs (namespace `logs`, Service `victoria-logs`, 30 days), which is
what is read. In the app's `prod_watch.cue`:

```cue
prodWatch: node: {
	host:       "user@203.0.113.7"           // the node, user@host
	kubeconfig: "$HOME/.kube/config"         // the cluster's kubeconfig on the node
	namespace:  "brawl-chess"                // release@k8s's namespace: the app's folder name
	// containers: ["auth", "crud"]          // only these containers; none named, all
	// deployments: ["brawl-chess-auth"]     // only these Deployments' pods; none named, all
	// logs: {namespace, service, port}: the node's VictoriaLogs, with defaults
}
```

Each pass, over `ssh <host>` (batch mode, the kubeconfig exported from the node's own file):

1. `kubectl get pods -n <namespace> -o json`, for each container's image and when it started.
2. `kubectl -n logs get svc victoria-logs`, for the Service's ClusterIP, then `curl` on the node to
   `/select/logsql/query` with the query on stdin (nothing is made in the cluster, no port-forward).
   The query is LogsQL: the namespace's stream (Vector sets `namespace`, `pod`, `container`, `level`
   on each line) between the last pass and now, the lines at warning or worse or that say they
   failed, and the indented lines that go on a stack, with only the fields prod-watch reads (the
   other `json.*` fields of an access log, headers and cookies among them, are never fetched).

Nothing else runs on the node: the only kubectl verb is `get`, the query is a read, and the words
that reach the remote shell are the schema's, each held to letters, digits and a few signs.

The lines become entries as Cloud Logging's are: the **service** is the pod's Deployment, the
**revision** its ReplicaSet's hash (the template's: a release changes it), the **instance** the pod.
An access log line (Caddy's, with `json.status` and `json.request.uri`) is a request as Cloud Run's `httpRequest` is: named by its status, method and path, never its query, and never reported below 500. A JSON line's `json.error` goes beside its message and its `json.stack_trace` is its stack; a Python
traceback, JS frames, Java causes and Go goroutines are put into one entry. A container that started
after the last pass opens its pod's start window, as Cloud Run's "Starting new instance" does, so the
shared noise rules held to `during: ["start"]` work. A pass reads 50000 lines of each source at most; when one stops there the window ends at the earliest
cutoff, for both sources, and the next pass goes on. A line VictoriaLogs returns that is not JSON fails the pass, the ledger and the
cursor untouched. CloudNativePG's records (`record.error_severity`, `record.message`) are read by the database's own severity.

The header's **released** says how fixes reach production; for a node it adds the last release
release-cron's log holds (`~/.cache/pronto/release-cron/<app>/release-cron.log`, "release 28838831 at
13/11 08:00 BRT"), else the images the pods run (their tag, or for `latest` the digest's first twelve
characters). A fingerprint whose **last** is after that time and whose revisions are the running ones
(`--json`'s `node.images` has each container's image) is still there after the release.

### A node's deliberate restart of a unit

When the operator restarts the node's k3s on purpose, every client of the Kubernetes API says so for the
seconds it is down. An app names the unit in `prod_watch.cue` (`node.restart`, `#Restart` in
[`schema.cue`](schema.cue)) and holds the rules that are only that to `during: ["restart"]`:

```cue
prodWatch: node: restart: unit: "k3s"            // as `journalctl -u` names it
```

The rest is derived from the unit and may be overridden (the values below are the defaults, `k3s` standing for the unit,
quoted with `regexp.QuoteMeta`):

```cue
stop:  "systemd\\[1\\]: Stopping k3s\\.service"      // JavaScript regular expressions on systemd's own lines
start: "systemd\\[1\\]: Started k3s\\.service"
crash: "k3s\\.service: (Main process exited|Failed with result|Scheduled restart job)"
lead: 5      // seconds before the stop line the window opens
tail: 120    // seconds after the start line it closes
down: 300    // the longest a stop may stay down
```

Each pass reads, over the node's ssh and read-only, `sudo -n journalctl -u <unit> _PID=1` (the unit's lines of
systemd itself) and `systemctl show <unit> -p LoadState -p ActiveEnterTimestamp -p NRestarts` (journal lines as `-o short-iso-precise`; a unit whose `LoadState` is not `loaded` stops the run). A window is
`[stop - lead, start + tail]` for a stop line followed within `down` seconds by a start: the first start line of
the journal after the stop, and only when none follows it the ActiveEnterTimestamp of the **last** stop (whole
seconds, so beside a precise line it would end the tail early; an earlier stop with no start line gets no window, and
the timestamp pairs only when it is **strictly after** the stop, to the millisecond: one within the stop's own second
may be an earlier activation). A journal line that matches the stop, start or crash pattern and whose time does not
parse **fails the run** before triage or any write. It is **no window**, and the same entries alert, when:

- a crash line is in it, or `NRestarts` rose since the last pass (`k3s.json` in the state folder), or is unread. The
  guard is for a crash systemd restarted that the `crash` pattern misses: any rise since the last pass drops all of
  this pass's windows. While a restart is held (below) `k3s.json` keeps the old counter, so the pass that reads the
  held entries again still sees the rise (`restartBaseline`); with no counter saved yet, the held pass saves the
  first one it reads;
- it overlaps an interval a rise voided. A pass that sees `NRestarts` rise keeps the windows it rejected in `k3s.json`
  (`{"nRestarts": n, "voided": [{"from", "to"}]}`, `restartVoids`), because the next pass compares equal counters and
  would accept them when its log read was cut by a row limit or the overlap gets late lines. A pass rejects every
  window overlapping a voided interval and drops one once the cursor it commits is past its end. A `k3s.json` of
  `{"nRestarts": n}` alone has none; a `voided` that is there and is not a list of `{from, to}` that parse (or a
  `k3s.json` that is no object) **fails the run** before triage or any write (`k3sState`), and duplicates collapse
  (`k3sNext` decides what a pass writes);
- its end (`start + tail`) is past what the journal read reached: an incomplete window may hold a crash not read yet;
- the entry is not the node's. The window applies only to entries read from the node (VictoriaLogs), never to
  a Cloud Run service the app also watches.

The journal is read from `from - (tail + down + lead)` to `min(now, to + lead + down + tail)` for a report over
`[from, to]` (`restartRange` in `watch.js`, with the cutoff as its `now`), so every stop whose window can touch an entry, and the crash
evidence across that window, is read. A `journalctl` or `systemctl show` that fails stops the run with its
stderr before the ledger, the cursor or `k3s.json` is written, so the next pass reads the window again.

A restart that is **not finished** at the cutoff (a stop with no start yet but within `down` of it, or a start
whose `start + tail` is past it) is held, not judged (`restartPending` in `watch.js`): the pass leaves the
node's entries from `stop - lead` on out of its report and its counts, commits its cursor no later than that point
and keeps their hashes out of `seen` (those an earlier pass already counted stay in it), so the next pass reads them
again with the window complete (or none). The hold applies to cursor runs alone: a `--since` report holds nothing
back, and shows the node's entries as they are, a window only if complete. A cursor run also holds the node's entries
from the cutoff minus `lead` (`leadHold`, merged with that hold: the earlier of the two), when `node.restart` is
set: a stop line may reach the journal after the pass read it, and its window reaches back `lead` before it. The
cursor is the source's own boundary, verbatim, when a read limit cut the pass short; only the lag or a hold gives an earlier one, in milliseconds
(`settleRun`).

The `NRestarts` read comes first, then the cutoff, in one node command: `systemctl show`, then a wait on the node until
its own clock passes the next whole second, then `CUTOFF=<epoch seconds>`. `cutoffOf` parses it (one line, a positive whole
number, or the run fails) and the cutoff, in ms, is the journal's `--until`, the windows' `until` (`restartRange`'s `now`,
a required finite number: it never defaults to the clock) and the lead hold's. It is a second the node has reached, at or
after the counter read: a crash the counter counted has its stop line before the cutoff, so none raises the counter while
its lines wait for the next pass against an equal counter; a crash between the read and the cutoff shows in the journal
without the counter, and the next pass's rise rejects its window. The Mac's clock is not used, so a Mac clock ahead of the
node's cannot put the cutoff in the node's future. The node's entries are read up to `to`: the lead hold starts at
`min(to, cutoff) - lead` (`leadHold`'s `to`), so with `to` past the cutoff nothing newer than the cutoff minus `lead` is
released.

A loaded unit's `NRestarts` must be a complete non-negative integer (`counterOf`): missing, empty, `abc`, `-1` or `1.5`
fails the run before triage or any write. A unit that is not loaded fails it already.

A `k3s.json` whose `nRestarts` is there and is not a non-negative integer fails the run like a bad `voided`. A throw
from either check keeps failing every pass until the bad line leaves the range read or the operator mends `k3s.json`.

The start and shutdown windows of a pod are built from every entry a pass read, the ones an earlier pass counted too
(`group`'s `context`), and only the new entries are classified and counted: a SIGTERM marker seen last pass still
opens the window of a late line this pass. A marker older than the overlap (the lag) is no longer read, so it cannot explain a line that arrives more than the lag late.

`during` takes every phase that applies: an entry can be in its pod's `start` and `shutdown` windows (a pod stopped as
it starts) and in a `restart` window at once, and a rule held to any one of them meets it (`phasesOf`).

## Noise is a design fact

A noise rule says, in CUE, a line that is not a bug and why; a case proves it on the line it was
written for and on the line it must leave alone ([`tests/unit/noise.cue`](../tests/unit/noise.cue)).
The rules every app shares, for what pronto's release runs beside every app (Electric, the Cloud SQL
proxy, the Managed Prometheus collector), come with [`schema.cue`](schema.cue) in `prodWatch.noise`;
an app's own go beside them in its `prod_watch.cue`.

A rule may be held to an instance's **start** or **shutdown** window, or to the node's deliberate **restart**
(`during`; the last above), as `prodWatch.lifecycle` defines the first two: a container calling PostgREST before it listens, or after it stopped on SIGTERM, is how
an instance starts and stops; the same line an hour into its life is a bug.

A fingerprint judged noise one at a time, with no rule (a one-off), is marked in the ledger with its reason.

## State

The cursor (`cursor.json`, the time the last run reached) and the ledger (`ledger.json`, each
fingerprint's status: open, watching, noise with why, fixed with its PR and when) are in
`<the repository's root>/.omc/prod-watch/<app>/`, runtime state no commit carries. A watching agent
also keeps its `log.md` there, a line a pass.

Samples are redacted before they are printed (`redact` in `watch.js`): emails, phone numbers,
addresses, uuids, bearer tokens, JWTs, long tokens, and the values of keys that name a secret or a
person. Even so, a pull request quotes a sample only as far as it needs to.

## Tests

The fingerprinting, redaction, noise rules and triage are cases in `tests/unit/*.cue` (suites
`fingerprint`, `noise` and `triage`), run as every suite is:

```sh
for s in fingerprint noise triage; do deno test --allow-read --allow-env --allow-run tests/unit.ts -- $s; done
```
