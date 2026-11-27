# alerts: an app's Cloud Monitoring incidents, in an inbox on this Mac

Cloud Monitoring opens an incident when one of an app's policies fires and closes it when it stops.
Until now an incident reached only the operator's email. This plugin makes the incident a message on
a Pub/Sub topic, which a subscriber on the Mac reads (a pull subscription, so nothing listens on the
internet) into a file the lead tails; a CRITICAL one is also sent to the phone (ntfy).

## What it adds

- `alerts/subscriber.ts`, the driver (Deno), and `alerts/inbox.js`, its rules, pure and held by the
  cases in [`tests/unit/alerts.cue`](../tests/unit/alerts.cue) (the driver runs there against a fake
  pull endpoint and a fake phone). Both regenerated.
- `alerts_plugin.cue`: `#Alerts` in the app's package, holding `alerts` to it. Regenerated.
- `alerts_spec.cue`, seeded once, then the app's own: its name, its project, which severities reach
  the phone, and the phone's topic.
- `observability/alerts.subscriber.json` and `observability/alerts.policies.json`, exported from the
  spec each time the installer runs (do not edit): the first is what the infra plugin's
  `alertSubscribers` read (topic, subscription, ack deadline 60 s, retention 7 days, channel) and
  the driver reads (project, subscription, severities, phone); the second is the policy that mails
  the operator when the oldest unread alert is more than 10 minutes old.

## Its tests, and its generation

The installer also writes, once the app's unit runner is wired for them, the cases that hold the rules and the driver (`tests/unit/alerts.cue`, and
`tests/unit/alerts_run.js`, which runs `alerts/subscriber.ts` against a fake Pub/Sub endpoint), and the
generate rule that writes `observability/alerts.*.json` from the spec (`pronto/alerts.cue`, with
`pronto/exports.nu`, which evaluates the program once for every plugin). The app wires its own unit runner
once: the suite `alerts` in `tests/unit/suites.cue`, `import * as alerts from '../../alerts/inbox.js'` and
`import * as alertsrun from './alerts_run.js'` in `tests/unit/registry.js` (both namespaces), and a `test`
check that runs `tests/unit.ts -- alerts`; then run `bin/pronto-alerts` again. Until the suite is in the app's `#Suite` and the
registry imports both, the installer writes no cases and says so (a suite the schema does not name fails every unit run of the app). A change to `alerts_spec.cue` is then one `generate` away from
the files the infra state and the subscriber read.

## Turn it on for an app

```sh
bin/pronto-alerts apps/<app> project=<gcp-project-id>    # from a pronto-plugins clone
```

Then, in the infra state of the project (`alertSubscribers`, `topics` and `notificationChannels`
adopted, `pubsub.googleapis.com` in `apis`), name the file and the member that may pull, and send the
policy file to the operator's own email channel only, so an alert about the inbox never has to
travel through the inbox:

```cue
alertSubscribers: "<app>": {file: "../../apps/<app>/observability/alerts.subscriber.json", subscribers: {"user:<you>": true}}
alertPolicies: "<app>-alerts": {file: "../../apps/<app>/observability/alerts.policies.json", channels: ["<email channel>"], toSubscribers: false}
```

`release@infra` makes the topic, the subscription and the channel, and sends every alert policy and
uptime check of the project to the channel.

## The inbox

One job on the Mac reads every app's subscription:

```sh
bin/pronto-alerts job install apps/<app> apps/<other>   # launchd dev.pronto.alerts-inbox, KeepAlive, log ~/Library/Logs/pronto/alerts-inbox.log
bin/pronto-alerts job uninstall
bin/pronto-alerts job run apps/<app>                    # the same in the foreground
```

The job runs the apps' alerts from a worktree of its own at `origin/main` (`~/.cache/pronto/alerts/wt`,
made as release-cron makes its own), never from a checkout a person or a session works in, with a fixed
PATH, only the permissions the driver uses (Pub/Sub's host and the phone's, the inbox folder, and
`/usr/bin/security` and gcloud by their absolute paths). The apps must be on `origin/main` before it is
installed; install again after a merge to move it to the new main.

It long-polls `:pull` (50 messages at most). For each message it writes one line to
`~/.cache/pronto/alerts/<app>.jsonl` and flushes it to disk, and only then acknowledges it, so a crash
redelivers and never loses. A line is
`{id, state, policy, display, severity, app, owner, opened, closed, url}`: never the incident's
resource, metric or condition query, whose labels may hold anything. A message that is no incident
is acknowledged and dropped. The inbox rotates daily (`<app>.<day>.jsonl`) and keeps seven days; a day's
file that is already there is appended to, never replaced. Tail it with `tail -F` (capital F): the
rotation renames the file, and `tail -f` would keep reading the old one.

The push comes after the acknowledge, so a crash between the two loses only the push: the line is in the
inbox, and the phone is not told. A write is whole or an error (a short write goes on from where it stopped), and an inbox
that ends in a cut-off line gets a newline before the next record, so the fragment is a line of its own and never the front of
an incident the readers would then lose.

Pub/Sub delivers at least once, so a line may be there twice: the readers keep one per `id:state`
(`inbox.js`'s `unique` and `parseInbox`). Each app has its own `~/.cache/pronto/alerts/<app>.heartbeat`, rewritten
only after Pub/Sub has answered a pull 2xx (a refused or unreachable pull leaves it as it was); a reader trusts that
app's inbox while it is fresh and asks the incidents API otherwise.

The phone is told only `<display name>: <state>`, for the severities in `push` (CRITICAL by default).
Its bearer token, if the topic wants one, is `ALERTS_NTFY_TOKEN` or the login Keychain's
`pronto-ntfy-token`; it is never written to a file. The access token is `gcloud auth print-access-token`
of the `pronto` configuration, fetched again on a 401 and held in memory only.

## Not here yet

The same subscriber on the node, which needs a workload identity there.
