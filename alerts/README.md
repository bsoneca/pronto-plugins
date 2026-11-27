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

It long-polls `:pull` (50 messages at most). For each message it writes one line to
`~/.cache/pronto/alerts/<app>.jsonl` and flushes it to disk, and only then acknowledges it, so a crash
redelivers and never loses. A line is
`{id, state, policy, display, severity, app, owner, opened, closed, url}`: never the incident's
resource, metric or condition query, whose labels may hold anything. A message that is no incident
is acknowledged and dropped. The inbox rotates daily (`<app>.<day>.jsonl`) and keeps seven days.

Pub/Sub delivers at least once, so a line may be there twice: the readers keep one per `id:state`
(`inbox.js`'s `unique` and `parseInbox`). Every pull rewrites `~/.cache/pronto/alerts/heartbeat`; a reader
trusts the inbox while it is fresh and asks the incidents API otherwise.

The phone is told only `<display name>: <state>`, for the severities in `push` (CRITICAL by default).
Its bearer token, if the topic wants one, is `ALERTS_NTFY_TOKEN` or the login Keychain's
`pronto-ntfy-token`; it is never written to a file. The access token is `gcloud auth print-access-token`
of the `pronto` configuration, fetched again on a 401 and held in memory only.

## Not here yet

The same subscriber on the node, which needs a workload identity there.
