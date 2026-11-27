// The rules of pronto-alerts (README.md), pure: a Cloud Monitoring incident, as a Pub/Sub message carries
// it, becomes one line of the inbox; what the inbox keeps of it, which of its lines are the same
// notification redelivered, whether it goes to the phone, and the launchd job that reads it. The driver
// (subscriber.ts) is the only part that touches the network and the disk; the cases in
// tests/unit/alerts.cue hold these.

// What an incident keeps. resource, metric and the condition's filter are never read, so a label a
// service put in one (an address, an id of a customer) never reaches the inbox, the log or a phone.
const KEPT = ["id", "state", "policy", "display", "severity", "app", "owner", "opened", "closed", "url"];

const iso = (s) => {
  const n = Number(s);
  return Number.isFinite(n) && n > 0 ? new Date(n * 1000).toISOString().replace(/\.\d{3}Z$/, "Z") : null;
};

// A message (what :pull returns: {messageId, data: base64 of the incident's JSON}) as an inbox entry,
// or null for one that is not a Cloud Monitoring incident (a poison message: the driver acks it and
// says so, since a redelivery would never make it one). `app` is the subscription's own app, used
// when the policy has no `app` label.
export const entryOf = (message, app) => {
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(message?.data ?? ""), (c) => c.charCodeAt(0))));
  } catch {
    return null;
  }
  const i = body?.incident;
  if (!i || typeof i !== "object" || !i.incident_id || !["open", "closed"].includes(String(i.state).toLowerCase())) return null;
  const labels = i.policy_user_labels && typeof i.policy_user_labels === "object" ? i.policy_user_labels : {};
  const policy = String(i.policy_name ?? "");
  const entry = {
    id: String(i.incident_id),
    state: String(i.state).toLowerCase(),
    policy,
    display: String(i.condition_name || i.condition?.displayName || policy),
    severity: String(i.severity || "WARNING").toUpperCase(),
    app: String(labels.app ?? app ?? ""),
    owner: labels.owner === undefined ? null : String(labels.owner),
    opened: iso(i.started_at),
    closed: iso(i.ended_at),
    url: String(i.url ?? ""),
  };
  return Object.fromEntries(KEPT.map((k) => [k, entry[k]]));
};

// One notification: an incident's state change. Pub/Sub delivers at least once, so the inbox may hold
// a line twice; the readers drop the second.
export const keyOf = (entry) => `${entry.id}:${entry.state}`;
export const isDuplicate = (seen, entry) => seen.includes(keyOf(entry));
// The entries of an inbox in order, each notification once.
export const unique = (entries) => {
  const seen = new Set();
  return entries.filter((e) => !seen.has(keyOf(e)) && seen.add(keyOf(e)));
};
// An inbox's text as entries: a line that is not JSON (a write the machine lost half of) is skipped.
export const parseInbox = (text) => unique(text.split("\n").flatMap((l) => {
  try {
    return l.trim() ? [JSON.parse(l)] : [];
  } catch {
    return [];
  }
}));
export const lineOf = (entry) => JSON.stringify(entry) + "\n";

// Whether the entry goes to the phone: its severity is one the app sends (alerts_spec.cue's `push`).
export const pushes = (entry, push) => push.includes(entry.severity);

// The request that tells the phone: the display name and the state, nothing else of the incident. The
// bearer token, when the topic wants one, is the driver's, never here.
export const ntfyRequest = (entry, ntfy, token) => ({
  url: `${ntfy.url.replace(/\/+$/, "")}/${ntfy.topic}`,
  method: "POST",
  headers: { Priority: entry.state === "open" ? "urgent" : "default", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  body: `${entry.display}: ${entry.state}`,
});

// A file of the inbox folder that has been rotated: `<app>.<yyyy-mm-dd>.jsonl`; the day's own is `<app>.jsonl`.
export const rotatedName = (app, day) => `${app}.${day}.jsonl`;
// The rotated files to delete: older than `keep` days before `today` (yyyy-mm-dd).
export const expired = (names, today, keep = 7) => {
  const limit = new Date(today + "T00:00:00Z").getTime() - keep * 86400000;
  return names.filter((n) => {
    const m = /^.+\.(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(n);
    return m && new Date(m[1] + "T00:00:00Z").getTime() <= limit;
  });
};

// The request that pulls, and the one that acknowledges.
export const pullRequest = (api, sub, max = 50) => ({ url: `${api}/v1/${sub}:pull`, body: { maxMessages: max } });
export const ackRequest = (api, sub, ackIds) => ({ url: `${api}/v1/${sub}:acknowledge`, body: { ackIds } });
export const subscriptionPath = (project, subscription) => `projects/${project}/subscriptions/${subscription}`;

// The launchd job (a LaunchAgent's plist): `program` with `args`, always running (KeepAlive: it long-polls
// and launchd restarts it after any exit), its output appended to `log`, with the variables in `env`.
export const plist = ({ label, program, args, log, env }) => {
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const str = (s) => `<string>${esc(s)}</string>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>${str(label)}
	<key>ProgramArguments</key>
	<array>${[program, ...args].map(str).join("")}</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>30</integer>
	<key>EnvironmentVariables</key>
	<dict>${Object.entries(env).map(([k, v]) => `<key>${esc(k)}</key>${str(v)}`).join("")}</dict>
	<key>StandardOutPath</key>${str(log)}
	<key>StandardErrorPath</key>${str(log)}
	<key>ProcessType</key><string>Background</string>
</dict>
</plist>
`;
};
