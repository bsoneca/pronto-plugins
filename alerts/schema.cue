// What pronto-alerts (README.md) reads of an app: the app's opt-in, in its own alerts_spec.cue. The
// subscriber's file (observability/alerts.subscriber.json) and the policy that watches the subscriber
// are exported from it, so the names Pub/Sub, the infra state and the driver use are written once, here.
// bin/pronto-alerts writes this file into the app's own package (alerts_plugin.cue).
package alerts

// An app opts in with `alerts: {...}` in its own package (alerts_spec.cue).
alerts?: #Alerts

#Alerts: A={
	// The app's name: its inbox is <app>.jsonl, and a policy's `app` label, when it has none, is this.
	app!: =~"^[a-z][a-z0-9-]*$"
	// The Google Cloud project whose Cloud Monitoring incidents are read.
	project!: #AlertsProject
	// The Pub/Sub topic Monitoring publishes the incidents to, and the pull subscription the driver reads.
	// Pub/Sub names: a letter first, no "goog" prefix.
	topic:        *"alerts-\(app)" | #AlertsPubsubName
	subscription: *"\(topic)-inbox" | #AlertsPubsubName
	// The Cloud Monitoring notification channel's name.
	channel: *app | string & !=""
	// How long a pulled message waits for its acknowledge before Pub/Sub sends it again, and how long
	// an unacknowledged one is kept (the infra plugin's alertSubscribers read both from the file).
	ackDeadlineSeconds:       *60 | int & >=10 & <=600
	messageRetentionDuration: *"604800s" | =~"^[0-9]+s$"
	// The severities that go to the phone (ntfy); the others are only in the inbox.
	push: *["CRITICAL"] | [...("CRITICAL" | "ERROR" | "WARNING" | "INFO")]
	// The phone's topic. Its token, when it has one, is in the Keychain (pronto-ntfy-token) or
	// ALERTS_NTFY_TOKEN, never here.
	ntfy?: {url: =~"^https://[^/ ]+$", topic: =~"^[A-Za-z0-9_-]{1,64}$"}
	// How long the subscription may hold an unread message before the operator is mailed (seconds).
	lagSeconds: *600 | int & >0

	// observability/alerts.subscriber.json: what the infra plugin and the driver read.
	subscriber: {
		app:                      A.app
		project:                  A.project
		topic:                    A.topic
		subscription:             A.subscription
		channel:                  A.channel
		ackDeadlineSeconds:       A.ackDeadlineSeconds
		messageRetentionDuration: A.messageRetentionDuration
		push:                     A.push
		if A.ntfy != _|_ {ntfy: A.ntfy}
	}

	// observability/alerts.policies.json: the policy that fires when the subscriber stops reading, in the
	// shape the infra plugin's alertPolicies read. The state sends it to the operator's email channel
	// only (`toSubscribers: false`): an alert about the inbox cannot travel through the inbox.
	policies: [{
		name:          "alerts-subscriber-lag"
		displayName:   "Alerts: \(A.app) inbox is not being read"
		expr:          "pubsub_googleapis_com:subscription_oldest_unacked_message_age{monitored_resource=\"pubsub_subscription\",subscription_id=\"\(A.subscription)\"} > \(A.lagSeconds)"
		duration:      "60s"
		severity:      "warning"
		documentation: "The oldest unacknowledged alert of \(A.app) is more than \(A.lagSeconds) seconds old: the subscriber (launchd dev.pronto.alerts-inbox on the Mac) is not reading. Check `launchctl print gui/$(id -u)/dev.pronto.alerts-inbox` and its log in ~/Library/Logs/pronto/."
		labels: {app: A.app, owner: "alerts"}
	}]
}

#AlertsProject:    =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
#AlertsPubsubName: =~"^[A-Za-z][A-Za-z0-9._~+%-]{2,254}$" & !~"^goog"
