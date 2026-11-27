package alerts

import "strings"

_t: #Host & {package: "myapp", app: "my-app", project: "my-project-1"}

// An opt-in writes the driver, its rules and the schema, and seeds the app's own alerts_spec.cue.
written: [for p, f in _t.files if !f.seed {p}] & ["alerts/subscriber.ts", "alerts/inbox.js", "alerts_plugin.cue"]
seeded: [for p, f in _t.files if f.seed {p}] & ["alerts_spec.cue"]

// The schema joins the app's package; the seed names the app and its project and never a secret.
inPackage:   strings.Contains(_t.files["alerts_plugin.cue"].text, "\npackage myapp\n") & true
holdsAlerts: strings.Contains(_t.files["alerts_plugin.cue"].text, "\nalerts?: #Alerts\n") & true
seedPackage: strings.HasPrefix(_t.files["alerts_spec.cue"].text, "package myapp\n") & true
seedNames:   strings.Contains(_t.files["alerts_spec.cue"].text, "app:     \"my-app\"") & strings.Contains(_t.files["alerts_spec.cue"].text, "project: \"my-project-1\"") & true
seedNoToken: strings.Contains(strings.ToLower(_t.files["alerts_spec.cue"].text), "token:") & false

// The defaults, from the app and the project alone: the topic, its subscription and the channel are named for the app,
// the ack deadline is a minute, an unread message is kept a week and only CRITICAL reaches the phone.
_a: #Alerts & {app: "my-app", project: "my-project-1"}
defaults: _a.subscriber & {
	app:                      "my-app"
	project:                  "my-project-1"
	topic:                    "alerts-my-app"
	subscription:             "alerts-my-app-inbox"
	channel:                  "my-app"
	ackDeadlineSeconds:       60
	messageRetentionDuration: "604800s"
	push: ["CRITICAL"]
}
noPhoneByDefault: [for k, _ in _a.subscriber if k == "ntfy" {k}] & []

// The phone's topic is in the subscriber's file, so the driver knows it, and has no token field.
_n: #Alerts & {app: "my-app", project: "my-project-1", ntfy: {url: "https://ntfy.example.com", topic: "my-app-alerts"}}
phone: _n.subscriber.ntfy & {url: "https://ntfy.example.com", topic: "my-app-alerts"}
phoneNoToken: [for k, _ in _n.subscriber.ntfy if k == "token" {k}] & []

// The policy that watches the subscriber reads the subscription's own lag, and carries no label but the app's and its owner.
_p: _a.policies[0]
lagPolicy: _p & {name: "alerts-subscriber-lag", severity: "warning", duration: "60s", labels: {app: "my-app", owner: "alerts"}}
lagOnSubscription: strings.Contains(_p.expr, "subscription_id=\"alerts-my-app-inbox\"") & strings.HasSuffix(_p.expr, "> 600") & true

// Refused: a name Pub/Sub refuses, a phone over plain http, a severity that is not Cloud Monitoring's, an app with a space.
_ok: {app: "my-app", project: "my-project-1"}
googTopicRefused: _ok & {topic: "goog-alerts"} & matchN(0, [#Alerts])
plainHttpRefused: _ok & {ntfy: {url: "http://ntfy.example.com", topic: "t"}} & matchN(0, [#Alerts])
badSeverityRefused: _ok & {push: ["PAGE"]} & matchN(0, [#Alerts])
badAppRefused: {app: "my app", project: "my-project-1"} & matchN(0, [#Alerts])
shortAckRefused: _ok & {ackDeadlineSeconds: 5} & matchN(0, [#Alerts])
