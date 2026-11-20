// What prod-watch does with Cloud Logging entries once read (prod-watch.ts reads them): each
// entry's message, its fingerprint (the message with ids, numbers and addresses taken out, and the
// first frame of the app's own code), the groups those make, which are noise by a rule
// (prod-watch/schema.cue), and what a run reports against the ledger of known fingerprints. Pure functions,
// held by the cases in tests/unit/*.cue; prod-watch/README.md says how it is used.
import { createHash } from "node:crypto";

// Colour codes, kept or with their escape lost ("[0m").
// deno-lint-ignore no-control-regex -- the escape is what a colour code starts with
const ANSI = /\u001b?\[[0-9;]*m/g;
// A timestamp at the start of a line: 2026-11-01T06:36:58.936Z, 2026/11/01 06:36:58, 06:36:58.936.
const STAMP = /^(\d{4}[-/]\d\d[-/]\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?Z?|\d\d:\d\d:\d\d(?:\.\d+)?)\s*/;
const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
const JWT = /\beyJ[\w-]+\.[\w-]+\.[\w-]+/g;
const BEARER = /\b(Bearer|Basic)\s+[\w.~+/=-]+/gi;
// key=value, key: value and "key":"value" where the key names a secret or a person.
const SECRET_KEY = "token|secret|password|passwd|api[_-]?key|apikey|authorization|cookie|session|signature|sig|code|refresh|access_token|id_token";
const PERSON_KEY = "name|display_name|displayname|nickname|nick|username|user_name|player|email|phone|phone_number";
const KEYED = new RegExp(`("?\\b(?:${SECRET_KEY}|${PERSON_KEY})"?\\s*[:=]\\s*)((?:Bearer|Basic)\\s+[^\\s&,;)}]+|"[^"]*"|[^\\s&,;)}]+)`, "gi");
const IPV4 = /\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/g;
// IPv6, bracketed with a port or bare: hex groups and colons, three groups at least, with a "::" or
// a hex letter (so never a time of day).
const IPV6_LIKE = /\[?\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){2,7}\b\]?(?::\d+)?/gi;
// A phone number: a + or a run of digits with separators, ten digits or more.
const PHONE = /\+\d[\d\s().-]{8,}\d|\b\d{2,4}[\s.-]\d{3,5}[\s.-]\d{4}\b/g;
// A long token: hex or base64 of 24 characters and more, with a digit and a letter in it (so never
// a name_like_this).
const TOKEN = /\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{24,}={0,2}/g;
const HEX = /\b(?:0x)?[0-9a-f]*\d[0-9a-f]*[a-f][0-9a-f]*\b|\b(?:0x)?[0-9a-f]*[a-f][0-9a-f]*\d[0-9a-f]*\b/gi;
// A query's value, up to the next parameter, a space, a quote, a bracket, or a colon a space follows.
const QUERY_VALUE = /([?&][\w.[\]-]+)=[^&\s)"']*?(?=[&\s)"']|:\s|:$|$)/g;
const NUMBER = /\d+/g;

// A Python traceback a service wrote a line an entry (pronto-llm's), put back into one entry: from
// its "Traceback" line, the lines after it of the same instance within two seconds, up to and with
// the exception's own line, and on through a chained traceback ("During handling ...").
const CHAIN = /^(During handling of the above exception|The above exception was the direct cause)/;
export function stitch(entries) {
  const out = [];
  const open = new Map();
  // The text entry of each instance's container a continuation goes on.
  const more = new Map();
  const where = (e) => `${e.resource?.labels?.service_name}|${e.resource?.labels?.revision_name}|${e.labels?.instanceId ?? ""}|${e.labels?.container_name ?? ""}`;
  for (const e of entries) {
    const line = typeof e.textPayload === "string" ? clean(e.textPayload) : null;
    const w = where(e);
    const t = open.get(w);
    const near = t && Math.abs(Date.parse(e.timestamp) - Date.parse(t.last)) <= 2000;
    if (line !== null && t && near && !e.httpRequest) {
      if (t.ended && !(CHAIN.test(line) || /^Traceback \(most recent call last\)/.test(line) || line === "")) { open.delete(w); }
      else {
        t.entry.textPayload += `\n${e.textPayload}`;
        t.last = e.timestamp;
        // The exception's own line: not indented, not a frame, not a marker; a chain goes on after it.
        if (/^\S/.test(e.textPayload) && !/^(File "|Traceback|During handling|The above exception)/.test(line)) t.ended = true;
        else if (CHAIN.test(line) || /^Traceback/.test(line)) t.ended = false;
        continue;
      }
    }
    if (line !== null && /^Traceback \(most recent call last\)/.test(line)) {
      const entry = { ...e, textPayload: e.textPayload };
      open.set(w, { entry, last: e.timestamp, ended: false });
      out.push(entry);
      continue;
    }
    // A line that goes on the one before (CONTINUES) joins it: JS frames, a Java cause, a Go goroutine.
    const p = more.get(w);
    if (line !== null && p && !e.httpRequest && Math.abs(Date.parse(e.timestamp) - Date.parse(p.last)) <= 2000 && CONTINUES.test(e.textPayload)) {
      p.entry.textPayload += `\n${e.textPayload}`;
      p.last = e.timestamp;
      continue;
    }
    if (line !== null && !e.httpRequest) {
      const entry = { ...e };
      more.set(w, { entry, last: e.timestamp });
      out.push(entry);
      continue;
    }
    out.push(e);
  }
  return out;
}

// --- A node's logs (prodWatch.node): what VictoriaLogs holds of an app's pods, as entries. ---

// What Cloud Run's log filter calls a line that may be a bug when it carries no severity.
const ERRORISH = /(error|panic|exception|traceback|fatal|refused|failed)/i;
// A line's level: a name (pino's and zap's "warn", logrus's "warning") or pino's number.
const LEVELS = { trace: "DEBUG", debug: "DEBUG", info: "INFO", notice: "NOTICE", warn: "WARNING", warning: "WARNING", err: "ERROR", error: "ERROR", crit: "CRITICAL", critical: "CRITICAL", fatal: "CRITICAL", panic: "CRITICAL", alert: "ALERT", emerg: "EMERGENCY" };
const PINO = { 10: "DEBUG", 20: "DEBUG", 30: "INFO", 40: "WARNING", 50: "ERROR", 60: "CRITICAL" };
const PG = { DEBUG: "DEBUG", LOG: "INFO", INFO: "INFO", NOTICE: "NOTICE", WARNING: "WARNING", ERROR: "ERROR", FATAL: "CRITICAL", PANIC: "EMERGENCY" };
// Vector writes pino's numbers as strings ("50").
const levelOf = (l) => (/^\d+$/.test(String(l)) ? PINO[Number(l)] : LEVELS[String(l ?? "").toLowerCase()]) ?? "DEFAULT";
// A plain line's severity when it says so ("level=warn", "[error]", "ERROR: ..."), else DEFAULT.
function severityOf(text) {
  const m = text.match(/(?:\blevel=|\[|^)\s*"?(warn(?:ing)?|error|fatal|critical|panic)\b/i);
  return m ? LEVELS[m[1].toLowerCase()] : "DEFAULT";
}
// A line that goes on the one before: indented (a frame, a source line), a cause, a Go goroutine.
export const CONTINUES = /^(\s+\S|Caused by:|goroutine \d+ \[|\.\.\. \d+ more)/;

// The image a container runs, as the revision a report names: its tag, or for `latest` (release@k8s
// pushes that) the first twelve hexadecimal characters of its digest.
export function revisionOf(image = "", imageID = "") {
  const tag = image.replace(/@.*$/, "").match(/:([^:/]+)$/)?.[1];
  if (tag && tag !== "latest" && !/^[0-9a-f]{64}$/.test(tag)) return tag;
  return (imageID || image).match(/sha256:([0-9a-f]{12})/)?.[1] ?? "";
}

// A Deployment's pod is <deployment>-<hash>-<id>, the hash its ReplicaSet's (the revision of its
// template): the Deployment and the hash, or the name itself for any other pod.
export function ownerOf(pod) {
  const m = String(pod).match(/^(.+)-([a-z0-9]{6,10})-[a-z0-9]{5}$/);
  return m ? { deployment: m[1], hash: m[2] } : { deployment: String(pod), hash: "" };
}

// The containers of the named Deployments' pods now (`kubectl get pods -o json`; none named, every
// Deployment's): each with the image's revision and when it started.
export function podsOf(podList, deployments = []) {
  const out = [];
  for (const p of podList?.items ?? []) {
    const rs = (p.metadata?.ownerReferences ?? []).find((o) => o.kind === "ReplicaSet")?.name ?? "";
    const o = ownerOf(`${rs}-xxxxx`);
    if (!o.hash || (deployments.length && !deployments.includes(o.deployment))) continue;
    for (const c of p.status?.containerStatuses ?? []) {
      out.push({ pod: p.metadata.name, deployment: o.deployment, hash: o.hash, container: c.name, revision: revisionOf(c.image, c.imageID), startedAt: c.state?.running?.startedAt ?? "" });
    }
  }
  return out;
}

// The entries VictoriaLogs' NDJSON (or its objects, a list) holds (/select/logsql/query, one object a line with _time, _msg, pod,
// container, level and a JSON line's json.error and json.stack_trace): the service the pod's
// Deployment, the revision its ReplicaSet's hash, the instance the pod. A line is a text entry, or,
// when it carries json.* fields, a jsonPayload; its level is the entry's severity. A stack
// (Python's traceback, JS's frames, Java's causes, Go's goroutines) is put into one entry. Only
// what may be a bug, as Cloud Run's filter reads it (prod-watch.ts): a warning or worse, a line that
// says it failed, or a lifecycle marker. `starts` (podsOf) gives each container's start after
// `from` the "Starting new instance" marker that opens its pod's start window.
/** @param {string | object[]} ndjson @param {{from?: string, lifecycle?: Record<string, any>, starts?: {pod: string, container: string, startedAt: string}[]}} [opts] */
export function logEntries(ndjson, { from = "", lifecycle = {}, starts = [] } = {}) {
  const records = [];
  for (const l of Array.isArray(ndjson) ? ndjson : String(ndjson).split("\n")) {
    let r = l;
    if (typeof l === "string") {
      if (!l.trim()) continue;
      try { r = JSON.parse(l); } catch (e) { throw new Error(`VictoriaLogs: a line that is not JSON (${e.message}): ${l.slice(0, 200)}`); }
    }
    if (!r || typeof r._time !== "string" || typeof r.pod !== "string") throw new Error(`VictoriaLogs: a record with no _time or pod: ${JSON.stringify(r).slice(0, 200)}`);
    records.push({ ...r, _time: r._time.replace(/(\.\d{3})\d*Z$/, "$1Z").replace(/(\d\d:\d\d:\d\d)Z$/, "$1.000Z") });
  }
  records.sort((a, b) => (a._time < b._time ? -1 : a._time > b._time ? 1 : 0));
  const where = (timestamp, pod, container) => {
    const o = ownerOf(pod);
    return { timestamp, resource: { labels: { service_name: o.deployment, revision_name: o.hash } }, labels: { container_name: container, instanceId: pod } };
  };
  const entries = [];
  for (const r of records) {
    const body = String(r._msg ?? "").replace(/\r$/, "");
    if (!body.trim()) continue;
    const base = where(r._time, r.pod, r.container);
    const level = levelOf(r.level);
    // CloudNativePG's line is {"msg": "record", "record": {"error_severity", "message", ...}} at level
    // info: the database's severity and message are the record's.
    if (r["json.record.message"]) {
      entries.push({ ...base, severity: PG[String(r["json.record.error_severity"]).toUpperCase()] ?? level, textPayload: r["json.record.message"] });
      continue;
    }
    // An access log line (Caddy's) is a request, as Cloud Run's httpRequest is: named by its status,
    // method and path, never its query, and never reported answered below 500.
    const status = Number(r["json.status"]);
    if (status && r["json.request.uri"]) {
      if (status < 500) continue;
      entries.push({ ...base, severity: level, httpRequest: { status, requestMethod: r["json.request.method"] ?? "", requestUrl: r["json.request.uri"] } });
      continue;
    }
    if (r["json.msg"] || r["json.error"] || r["json.err"] || r["json.stack_trace"] || r["json.stack"]) {
      const why = r["json.error"] ?? r["json.err"];
      entries.push({ ...base, severity: level, jsonPayload: { message: why ? `${body}: ${why}` : body, stack_trace: r["json.stack_trace"] ?? r["json.stack"] ?? "" } });
    } else {
      const said = severityOf(body);
      entries.push({ ...base, severity: RANK[level] >= RANK.WARNING || said === "DEFAULT" ? level : said, textPayload: body });
    }
  }
  // Text lines that go on one another are one entry (stitch), then only what may be a bug is kept.
  const out = stitch(entries).filter((e) => {
    if (e.httpRequest || RANK[e.severity] >= RANK.WARNING) return true;
    const t = clean(messageOf(e));
    // A line that says it failed, as text or as the message of a JSON line (a request is named by its status, not its words).
    if (ERRORISH.test(t)) return true;
    return Object.values(lifecycle).some((l) => new RegExp(l.marker).test(t));
  });
  for (const c of starts) {
    if (c.startedAt && c.startedAt > from) out.push({ ...where(c.startedAt, c.pod, c.container), severity: "INFO", textPayload: "Starting new instance. Reason: container started" });
  }
  return out;
}

// What a LogsQL query asks for an app's pods since the last pass (prod-watch.ts sends it on stdin,
// with start and end as parameters): the namespace's lines, of the named containers and Deployments,
// that may be a bug or go on a stack, as logEntries reads them; nothing else leaves the node. Each
// name is a plain word, as the schema holds it.
/** @param {{namespace: string, containers?: string[], deployments?: string[]}} node
 *  @param {Record<string, {marker: string}>} [lifecycle] the markers of prodWatch.lifecycle, each a line to read */
export function logsQuery({ namespace, containers = [], deployments = [] }, lifecycle = {}) {
  const word = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/;
  for (const w of [namespace, ...containers, ...deployments]) if (!word.test(w)) throw new Error(`${JSON.stringify(w)}: not a plain name`);
  const markers = Object.values(lifecycle).map((l) => {
    if (l.marker.includes("`")) throw new Error(`${l.marker}: a lifecycle marker with a backtick`);
    return ` OR _msg:~\`${l.marker}\``;
  }).join("");
  const lines = `(level:~\`(?i)^(warn|warning|error|err|fatal|critical|crit|panic|alert|emerg|40|50|60)$\` OR json.record.error_severity:~\`^(WARNING|ERROR|FATAL|PANIC)$\` OR json.status:>=500 OR _msg:~\`(?i)(error|panic|exception|traceback|fatal|refused|failed|SIGTERM|Container terminated)\` OR _msg:~\`${CONTINUES.source}\`${markers})`;
  return [
    `{namespace="${namespace}"}`,
    ...(containers.length ? [`container:in(${containers.map((c) => `"${c}"`).join(",")})`] : []),
    ...(deployments.length ? [`pod:~\`^(${deployments.map((d) => d.replace(/\./g, "\\.")).join("|")})-[a-z0-9]+-[a-z0-9]+$\``] : []),
    lines,
    "| fields _time,_msg,pod,container,level,json.error,json.err,json.stack_trace,json.stack,json.msg,json.status,json.request.method,json.request.uri,json.record.error_severity,json.record.message",
    "| sort by (_time)",
  ].join(" ");
}

// The last release release-cron's log says (release-cron.log: "<time> <app> released <sha8> <sha>: ..."):
// its commit and when, or null.
export function releasedOf(log, app) {
  const re = new RegExp(`^(\\S+) ${app.replace(/[^\w-]/g, "\\$&")} released ([0-9a-f]{8}) ([0-9a-f]{40})\\b`);
  let found = null;
  for (const l of String(log).split("\n")) {
    const m = l.match(re);
    if (m) found = { at: m[1], short: m[2], sha: m[3] };
  }
  return found;
}

// A time in Brasília, "13/11 08:00 BRT".
export function brt(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-GB", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.day}/${p.month} ${p.hour}:${p.minute} BRT`;
}

// The text of an entry: its text, its JSON's message, or for a request its status, method and path.
export function messageOf(entry) {
  if (entry.httpRequest) {
    const r = entry.httpRequest;
    let path = r.requestUrl ?? "";
    try { path = new URL(path).pathname; } catch { path = path.replace(/\?.*/, ""); }
    return `HTTP ${r.status} ${r.requestMethod ?? ""} ${path}`.trim();
  }
  if (typeof entry.textPayload === "string") return entry.textPayload;
  const j = entry.jsonPayload ?? {};
  const m = j.message ?? j.msg ?? j.error ?? j.err;
  if (typeof m === "string") return [m, j.stack_trace ?? j.stack ?? ""].filter(Boolean).join("\n");
  return JSON.stringify(j);
}

// The message as written, its colour codes, leading timestamp and trailing whitespace off.
export function clean(text) {
  return String(text).replace(ANSI, "").split("\n").map((l) => l.replace(STAMP, "").trimEnd()).join("\n").trim();
}

// A line with everything that varies from one occurrence to the next taken out.
export function normalize(line) {
  return clean(line)
    // A collector's line: "warn\tsource\tmessage\t{fields}": the fields vary, the rest says what.
    .replace(/\t\{.*$/s, "")
    .replace(/\t/g, " ")
    .replace(/pid=<[\d.]+>/g, "pid=<…>")
    .replace(/request_id=\S+/g, "request_id=<…>")
    .replace(UUID, "<uuid>")
    .replace(EMAIL, "<email>")
    .replace(JWT, "<jwt>")
    .replace(IPV4, "<ip>")
    .replace(IPV6_LIKE, (m) => (/::|[a-f]/i.test(m) ? "<ip>" : m))
    .replace(QUERY_VALUE, "$1=…")
    .replace(HEX, (m) => (m.length >= 6 ? "<hex>" : m))
    .replace(NUMBER, "N")
    .replace(/\s+/g, " ")
    .trim();
}

// What the message says went wrong: a traceback's last line, else its first line.
export function titleOf(text) {
  // A collector's fields after its message ("\t{...}") vary and say nothing of what.
  const lines = clean(text).replace(/\t\{.*$/gm, "").split("\n").map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return "";
  if (/^Traceback \(most recent call last\)/.test(lines[0])) {
    const last = [...lines].reverse().find((l) => !/^(File "|\^+$|~+)/.test(l) && !/^During handling|^The above exception/.test(l));
    return last ?? lines[0];
  }
  return lines[0];
}

// The frames of a stack: Python's `File "path", line N, in fn` and JS's `at fn (path:line:col)`.
export function framesOf(text) {
  const out = [];
  for (const l of clean(text).split("\n")) {
    let m = l.match(/File "([^"]+)", line \d+, in (\S+)/);
    if (m) { out.push({ file: m[1], fn: m[2] }); continue; }
    m = l.match(/^\s*at (?:(?:async )?([^\s(]+) \()?((?:file|ext|node|https?):[^\s)]+?|\/[^\s)]+?)(?::\d+){1,2}\)?\s*$/);
    if (m) out.push({ file: m[2], fn: m[1] ?? "<anonymous>" });
  }
  return out;
}

// The frame of the app's own code nearest to where it failed: Python's innermost frame outside its
// dependencies, JS's outermost-first frame outside them; else the innermost frame at all.
const DEPENDENCY = /site-packages|dist-packages|node_modules|\/\.venv\/|^ext:|^node:|\/lib\/python\d/;
export function frameOf(text) {
  const frames = framesOf(text);
  if (!frames.length) return "";
  const python = /Traceback \(most recent call last\)/.test(text);
  const ordered = python ? [...frames].reverse() : frames;
  const f = ordered.find((x) => !DEPENDENCY.test(x.file)) ?? ordered[0];
  // The path from the dependency's root, else its last two parts: the same code wherever it is built.
  const file = f.file.replace(/^.*\/(?:site-packages|dist-packages|node_modules)\//, "").split("/").slice(-2).join("/");
  return `${file}:${f.fn}`;
}

// What groups entries: service, container, the normalized title and the app's frame.
export function keyOf(entry) {
  const text = messageOf(entry);
  const where = `${entry.resource?.labels?.service_name ?? "?"}/${entry.labels?.container_name ?? "-"}`;
  return `${where}|${normalize(titleOf(text))}|${frameOf(text)}`;
}
export const fingerprint = (key) => createHash("sha1").update(key).digest("hex").slice(0, 10);

// A sample fit for a pull request: every secret, address, id and personal detail replaced.
export function redact(text, max = 600) {
  const s = clean(text)
    .replace(KEYED, (_, k) => `${k}<redacted>`)
    .replace(JWT, "<jwt>")
    .replace(BEARER, "$1 <redacted>")
    .replace(EMAIL, "<email>")
    .replace(UUID, "<uuid>")
    .replace(IPV4, "<ip>")
    .replace(IPV6_LIKE, (m) => (/::|[a-f]/i.test(m) ? "<ip>" : m))
    .replace(PHONE, "<phone>")
    .replace(TOKEN, "<token>");
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

// When each instance started and began to stop: Cloud Run's markers (prodWatch.lifecycle) by
// instance, each phase a list of times.
export function windowsOf(entries, lifecycle) {
  const w = {};
  for (const e of entries) {
    const id = e.labels?.instanceId;
    if (!id) continue;
    const text = clean(messageOf(e));
    for (const [phase, l] of Object.entries(lifecycle ?? {})) {
      if (new RegExp(l.marker).test(text)) ((w[id] ??= {})[phase] ??= []).push(e.timestamp);
    }
  }
  return w;
}
// The phases an entry falls in, any of start and shutdown (from two seconds before its instance's marker to its
// seconds after; the two can overlap when an instance is stopped as it starts), or none: a list.
export function phasesOf(entry, windows, lifecycle) {
  const at = Date.parse(entry.timestamp);
  const mine = windows?.[entry.labels?.instanceId] ?? {};
  return Object.entries(mine).filter(([phase, times]) => {
    const within = (lifecycle?.[phase]?.within ?? 0) * 1000;
    return times.some((t) => at >= Date.parse(t) - 2000 && at - Date.parse(t) <= within);
  }).map(([phase]) => phase);
}
// The node's deliberate k3s restarts (prodWatch.node.restart), from what systemd says of the unit: its
// journal's lines (journalctl -u <unit> _PID=1 --utc -o short-iso-precise) and `systemctl show` (TZ=UTC) for its
// ActiveEnterTimestamp and NRestarts. A window is [stop - lead, start + tail] for a stop line followed within
// `down` seconds by a start (a journal line, or the ActiveEnterTimestamp). A crash line in it, or NRestarts
// above what the last run saw (`restarts.was`), and it is no window: the same entries alert. `until` is the
// journal's observation cutoff (what was read, never later than now): a window whose end is past it may still
// hold a crash that was not read, so it is no window either (restartPending says which of those are only unfinished).
// A `since` run (a historical report) gets none: the voids that rejected a window were dropped once the cursor passed
// them, so the report could not tell a window the counter had rejected; its entries are classified without the restart
// phase and alert, as an unexplained outage would.
/** @param {{journal?: string, activeEnter?: string | null, restarts?: {was: number | null, now: number | null} | null, until?: string | number | null, voided?: {from: string, to: string}[], since?: boolean}} input
 *  @param {{stop: string, start: string, crash: string, lead: number, tail: number, down: number}} cfg */
export function restartWindows({ journal = "", activeEnter = null, restarts = null, until = null, voided = [], since = false }, cfg) {
  if (since || !cfg || !restarts || restarts.now == null || (restarts.was != null && restarts.now > restarts.was)) return [];
  const { crashes } = journalTimes(journal, activeEnter, cfg);
  return completeWindows({ journal, activeEnter, until }, cfg)
    .filter((w) => !crashes.some((c) => c >= Date.parse(w.from) && c <= Date.parse(w.to)))
    .filter((w) => !overlaps(w, voided));
}
// Every stop paired with a start and read to the end of its tail (`until`), whatever a crash line or NRestarts say:
// the windows a rise of NRestarts rejects (restartVoids).
/** @param {{journal?: string, activeEnter?: string | null, until?: string | number | null}} input
 *  @param {{stop: string, start: string, crash: string, lead: number, tail: number, down: number}} cfg */
export function completeWindows({ journal = "", activeEnter = null, until = null }, cfg) {
  const cutoff = until == null ? NaN : typeof until === "number" ? until : Date.parse(until);
  if (!cfg || Number.isNaN(cutoff)) return [];
  const { pairs } = journalTimes(journal, activeEnter, cfg);
  const out = [];
  for (const { stop, start } of pairs) {
    if (start === undefined || start - stop > cfg.down * 1000) continue;
    const from = stop - cfg.lead * 1000, to = start + cfg.tail * 1000;
    if (to > cutoff) continue;
    out.push({ from: new Date(from).toISOString(), to: new Date(to).toISOString() });
  }
  return out;
}
const overlaps = (w, intervals) => (intervals ?? []).some((v) => Date.parse(w.from) <= Date.parse(v.to) && Date.parse(v.from) <= Date.parse(w.to));
// The intervals k3s.json keeps beside the counter (`voided`): those of the last run that the cursor has not passed,
// and, when NRestarts rose, the windows this run's rise rejected (`windows`, completeWindows). A later run compares
// equal counters, so without them it would accept a window whose entries this run did not read (a row limit cut the
// read, or a late line reached the overlap) as deliberate. One is dropped once the cursor (`committed`, the time the
// next run reads from, which already lies the lag behind) is past its end: nothing of it is read again.
// `restarts` is {was, now}; a k3s.json written before has no `voided`, which is none. One that is there and is no list of
// {from, to} that parse is an error (checkVoided): reading it as none would accept a window it rejected.
const checkVoided = (voided) => {
  if (!Array.isArray(voided) || voided.some((v) => !v || typeof v !== "object" || typeof v.from !== "string" || typeof v.to !== "string" || Number.isNaN(Date.parse(v.from)) || Number.isNaN(Date.parse(v.to)))) {
    throw new Error(`k3s.json's voided is not a list of {from, to} times: ${JSON.stringify(voided)?.slice(0, 200)}`);
  }
  return voided;
};
// What k3s.json holds, checked: {nRestarts, voided}. A missing nRestarts is none, else it is a non-negative integer. Only a missing `voided` is none; one that is there must be a
// list of {from, to} that parse, or the run fails (the driver calls it before it reads anything else).
/** @param {any} json */
export function k3sState(json) {
  if (!json || typeof json !== "object" || Array.isArray(json)) throw new Error(`k3s.json is no object: ${JSON.stringify(json)?.slice(0, 200)}`);
  const n = json.nRestarts ?? null;
  if (n !== null && !(Number.isInteger(n) && n >= 0)) throw new Error(`k3s.json's nRestarts is not a non-negative integer: ${JSON.stringify(n)?.slice(0, 200)}`);
  return { nRestarts: n, voided: "voided" in json ? checkVoided(json.voided) : [] };
}
// The hold a cursor run keeps for what a restart not yet logged can still reach: a stop line may reach the journal
// after the run's cutoff, and its lead (seconds) reaches back before it, so the node's entries from `until` - lead
// are left to the next run too. The node's entries are read up to `to` and the journal to `until`: the hold starts at the
// earlier of the two (`to` omitted: `until`), so no entry newer than the cutoff minus lead is released when `to` lies past
// the cutoff. Merged with restartPending's hold: the earlier of the two.
/** @param {{hold?: {from: string} | null, until: string | number, to?: string | number | null, lead: number}} input */
export function leadHold({ hold = null, until, to = null, lead }) {
  const ms = (t) => (typeof t === "number" ? t : Date.parse(t));
  const at = Math.min(ms(until), to == null ? Infinity : ms(to)) - lead * 1000;
  return hold && Date.parse(hold.from) <= at ? hold : { from: new Date(at).toISOString() };
}
/** @param {{voided?: {from: string, to: string}[], windows?: {from: string, to: string}[], restarts?: {was: number | null, now: number | null} | null, committed: string}} input */
export function restartVoids({ voided = [], windows = [], restarts = null, committed }) {
  checkVoided(voided);
  const rose = !!restarts && restarts.was != null && restarts.now != null && restarts.now > restarts.was;
  const passed = Date.parse(committed);
  const seen = new Set();
  return [...voided, ...(rose ? windows : [])].filter((v) => {
    if (Date.parse(v.to) < passed) return false;
    const key = `${v.from}|${v.to}`;
    return seen.has(key) ? false : (seen.add(key), true);
  });
}
// What a pass writes to k3s.json (`was` the counter it read, `now` the unit's, `hold` restartPending's, `voided` what
// k3s.json held, `candidates` completeWindows, `committed` the cursor): the counter restartBaseline gives (the old one
// when there is none to write but voids remain) and the voids restartVoids keeps, or null when there is nothing to write.
/** @param {{was?: number | null, now?: number | null, hold?: {from: string} | null, voided?: {from: string, to: string}[], candidates?: {from: string, to: string}[], committed: string}} input */
export function k3sNext({ was = null, now = null, hold = null, voided = [], candidates = [], committed }) {
  const next = restartBaseline({ was, now, hold });
  const voids = restartVoids({ voided, windows: candidates, restarts: { was, now }, committed });
  if (next === null && !voids.length) return null;
  return { nRestarts: next ?? was, ...(voids.length ? { voided: voids } : {}) };
}
// What NRestarts the next run compares with: this run's, unless a restart is pending (restartPending): the run
// that meets a rise while it holds its entries back must leave the old counter, or the next run, which reads
// those entries again, would find no rise and judge the window deliberate. A reset (systemd zeroes NRestarts on a
// deliberate restart) lowers it: keeping the old, higher counter would hide a later crash. With no old counter the
// first readable one is saved, or the next run, which finds the same restart, would have none to compare with. Null:
// nothing to write.
/** @param {{was?: number | null, now?: number | null, hold?: {from: string} | null}} input */
export const restartBaseline = ({ was = null, now = null, hold = null }) => (hold ? (was != null && now != null ? Math.min(was, now) : was ?? now) : now);
// A time (ISO, Z) as whole seconds and its fraction padded to nanoseconds, so sources of any precision compare exactly.
const instant = (s) => {
  const m = /^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z$/.exec(s);
  return m ? [Date.parse(`${m[1]}Z`), (m[2] ?? "").padEnd(9, "0")] : [Date.parse(s), "000000000"];
};
// Whether time a is strictly after time b, to the nanosecond.
export const timeAfter = (a, b) => { const [x, fx] = instant(a), [y, fy] = instant(b); return x !== y ? x > y : fx > fy; };
// What a cursor run counts and commits (prod-watch.ts). `hashes` is each entry's hash (a list, in the entries' order), `counted` the
// hashes the last cursor holds (`seen`), `reached` where the sources were read to (`to`, or earlier when a limit
// cut one short), `lag` ms. A cursor run holds back the node's entries from `hold.from` (restartPending): not
// counted, the cursor stops there, and their hashes stay out of `seen` unless an earlier run already counted
// them. A `since` run (a window only looked at) holds nothing back and counts what it reads. The cursor is
// `reached` as the source wrote it (any precision) unless the lag or a hold gives an earlier time, in ms.
/** @param {{entries: any[], hashes: string[], hold?: {from: string} | null, since?: boolean, counted?: Iterable<string>, reached: string, to: string, lag: number}} input */
export function settleRun({ entries, hashes, hold = null, since = false, counted = [], reached, to, lag }) {
  const known = new Set(counted);
  const kept = new Map(entries.map((e, i) => [e, hashes[i]]));
  const held = hold && !since ? Date.parse(hold.from) : null;
  let rest = entries;
  if (held !== null) {
    rest = rest.filter((e) => {
      if (!(e.source === "node" && Date.parse(e.timestamp) >= held)) return true;
      if (!known.has(kept.get(e))) kept.delete(e);
      return false;
    });
  }
  if (!since) rest = rest.filter((e) => !known.has(kept.get(e)));
  const boundary = reached === to ? new Date(Date.parse(reached) - lag).toISOString() : reached;
  const committed = held !== null && held <= Date.parse(boundary) ? hold.from : boundary;
  // In ms: a node's timestamps are cut to ms and the next read starts inclusive at the cursor, so the cursor's own ms is read again.
  const seen = [...kept].filter(([e]) => Date.parse(e.timestamp) >= Date.parse(committed)).map(([, h]) => h);
  return { entries: rest, committed, seen };
}
// What an entry is hashed as (prod-watch.ts's cursor keeps the hashes of what it counted): the entry as its source
// gave it, without the `source` tag the driver adds, so a cursor written before the tag still matches.
export const hashInput = (entry) => JSON.stringify({ ...entry, source: undefined });
// The journal's stop and crash times (ms; a line's first word is its ISO time, with microseconds, trimmed to
// milliseconds) and each stop paired with its start, in the order journalctl printed the lines, never by re-sorting
// the parsed times (two lines in one millisecond would swap). A stop line opens a pending stop (a second stop before
// any start replaces it: the first has no start of its own); a start line completes the pending stop, if there is
// one, and clears it, so each start completes at most one stop and a start with no pending stop pairs with nothing.
// Only the last stop left pending at the end has a second source for its start: the ActiveEnterTimestamp (whole
// seconds: next to a precise line it would end a window early), when it is strictly after that stop (in ms): within
// the stop's own second it may be an earlier activation, and no window is better than a false one. A line that matches a
// pattern and has no time that parses is an error, not a line to skip: the evidence of a crash may be in it.
// The one pairing restartWindows, completeWindows and restartPending share.
function journalTimes(journal, activeEnter, cfg) {
  const at = (l) => {
    const t = Date.parse(l.split(" ")[0].replace(/(\.\d{3})\d+/, "$1"));
    if (Number.isNaN(t)) throw new Error(`a journal line has no time that parses: ${l.slice(0, 200)}`);
    return t;
  };
  const [stopRe, startRe, crashRe] = [cfg.stop, cfg.start, cfg.crash].map((re) => new RegExp(re));
  const enter = activeEnter ? Date.parse(activeEnter) : NaN;
  const pairs = [], crashes = [];
  let pending = null;
  for (const l of journal.split("\n")) {
    const stop = stopRe.test(l), start = startRe.test(l), crash = crashRe.test(l);
    if (stop && start) throw new Error(`a journal line matches both the stop and the start pattern: ${l.slice(0, 200)}`);
    if (!stop && !start && !crash) continue;
    const t = at(l);
    if (crash) crashes.push(t);
    if (stop) pending = t;
    // A start before its stop (the node's clock stepped back) completes nothing: the stop stays pending.
    else if (start && pending !== null && t >= pending) { pairs.push({ stop: pending, start: t }); pending = null; }
  }
  if (pending !== null) pairs.push({ stop: pending, start: enter > pending ? enter : undefined });
  return { crashes, pairs };
}
// A restart not finished at the cutoff: a stop with no start yet but still within `down` of the cutoff (the start
// may come), or a start whose window's end (start + tail) is past it (a crash may still be written). The run that
// meets one holds its cursor and leaves the entries from `from` (the earliest such stop - lead, ISO) out of its
// count, so the next run reads them again, when the window is complete or is none. Null when none is unfinished.
// The NRestarts guard does not apply: a run that drops its windows still must not count what it cannot yet judge.
/** @param {{journal?: string, activeEnter?: string | null, until?: string | number | null}} input
 *  @param {{stop: string, start: string, crash: string, lead: number, tail: number, down: number}} cfg */
export function restartPending({ journal = "", activeEnter = null, until = null }, cfg) {
  const cutoff = until == null ? NaN : typeof until === "number" ? until : Date.parse(until);
  if (!cfg || Number.isNaN(cutoff)) return null;
  const { pairs } = journalTimes(journal, activeEnter, cfg);
  let first = null;
  for (const { stop, start } of pairs) {
    const unfinished = start === undefined ? cutoff - stop <= cfg.down * 1000 : start - stop <= cfg.down * 1000 && start + cfg.tail * 1000 > cutoff;
    if (unfinished && (first === null || stop < first)) first = stop;
  }
  return first === null ? null : { from: new Date(first - cfg.lead * 1000).toISOString() };
}
// The cutoff the node printed after its `systemctl show` ("CUTOFF=<epoch seconds>", prod-watch.ts): a whole second the
// node's clock had reached, read at or after the NRestarts, in ms. A missing, repeated or bad value is an error: a cutoff
// guessed from another clock could place the journal's end before a crash the counter counted.
/** @param {string} text */
export function cutoffOf(text) {
  const found = [...String(text).matchAll(/^CUTOFF=(.*)$/gm)].map((m) => m[1]);
  if (found.length !== 1 || !/^\d{1,15}$/.test(found[0]) || Number(found[0]) <= 0) throw new Error(`the node printed no CUTOFF=<epoch seconds> (one line, a positive whole number): ${JSON.stringify(String(text).slice(0, 200))}`);
  return Number(found[0]) * 1000;
}
// The journal to read for a report over [from, to] (ISO times), up to `now` (ms, required: the cutoff cutoffOf read from
// the node, floored to the whole second as the journal's --until is): a window is [stop - lead, start + tail]
// with start - stop <= down, so every stop whose window can touch an entry of the report lies in
// [from - (tail + down), to + lead], and its crash evidence in [from - (tail + down + lead), to + lead + down + tail],
// cut at now (the journal holds nothing later).
export function restartRange(from, to, cfg, now) {
  if (typeof now !== "number" || !Number.isFinite(now)) throw new Error(`restartRange needs the cutoff, a finite number of ms: ${JSON.stringify(now)}`);
  const ms = (s) => s * 1000;
  const whole = Math.floor(now / 1000) * 1000;
  return {
    since: new Date(Date.parse(from) - ms(cfg.tail + cfg.down + cfg.lead)).toISOString(),
    until: new Date(Math.min(whole, Date.parse(to) + ms(cfg.lead + cfg.down + cfg.tail))).toISOString(),
  };
}
// `systemctl show <unit> -p LoadState -p ActiveEnterTimestamp -p NRestarts` (TZ=UTC): whether the unit is
// loaded (a unit that is not has no journal to trust), when it last became active, and how many times it
// restarted by itself (null unless the line is a whole number: counterOf is the strict read).
export function unitOf(text) {
  const at = text.match(/^ActiveEnterTimestamp=\S+ (\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) UTC$/m);
  const n = text.match(/^NRestarts=(\d+)$/m);
  const load = text.match(/^LoadState=(\S+)/m);
  return { loadState: load ? load[1] : null, activeEnter: at ? `${at[1]}T${at[2]}Z` : null, nRestarts: n ? Number(n[1]) : null };
}
// The NRestarts of a loaded unit: a complete non-negative integer, or an error. A counter that is missing, empty, or
// not whole ("abc", "-1", "1.5") cannot be compared with the last run's, so the run fails before triage or any write.
/** @param {string} text */
export function counterOf(text) {
  const m = String(text).match(/^NRestarts=(.*)$/m);
  if (!m || !/^\d+$/.test(m[1])) throw new Error(`the unit's NRestarts is not a non-negative integer: ${JSON.stringify(m ? m[1] : null)}`);
  return Number(m[1]);
}
const inRestart = (entry, windows) => {
  const at = Date.parse(entry.timestamp);
  return (windows ?? []).some((w) => at >= Date.parse(w.from) && at <= Date.parse(w.to));
};

// Whether an entry is a lifecycle marker and no more, read for the windows and reported never: one at
// WARNING or above (a container killed by signal 11) is reported too.
const RANK = { DEFAULT: 0, DEBUG: 100, INFO: 200, NOTICE: 300, WARNING: 400, ERROR: 500, CRITICAL: 600, ALERT: 700, EMERGENCY: 800 };
export const isMarker = (entry, lifecycle) => (RANK[entry.severity ?? "DEFAULT"] ?? 0) < RANK.WARNING &&
  Object.values(lifecycle ?? {}).some((l) => new RegExp(l.marker).test(clean(messageOf(entry))));

// The noise rule an entry meets, by service, container, message and phases (schema.cue's #Noise), or null.
// `phases` are all that apply to it (a pod's start or shutdown and a node's restart can hold at once, a
// phase's name or a list of them); a rule held to `during` meets it when any of its phases applies.
export function noiseOf(entry, rules, phases = []) {
  const text = clean(messageOf(entry));
  const applies = [].concat(phases).filter(Boolean);
  for (const [name, r] of Object.entries(rules ?? {})) {
    if (r.during && !r.during.some((p) => applies.includes(p))) continue;
    if (r.service && !new RegExp(`^(?:${r.service})$`).test(entry.resource?.labels?.service_name ?? "")) continue;
    if (r.container && !new RegExp(`^(?:${r.container})$`).test(entry.labels?.container_name ?? "")) continue;
    if (new RegExp(r.match, "m").test(text)) return name;
  }
  return null;
}

// The entries as groups, one a fingerprint (the same line noise in its window and not outside it
// makes two): how many, when first and last, on which revisions, and
// up to three redacted samples, the first, the last and one between.
// `restart` are the node's deliberate-restart windows (restartWindows); they apply to the entries read from the
// node (`source: "node"`), never to a Cloud Run service's. The instances' windows are built from `context`, every
// entry the run read, not only `entries`, those to count: a shutdown marker counted by an earlier run is not in
// them, and the line it explains may be.
export function group(entries, rules, lifecycle = {}, restart = [], context = entries) {
  const groups = {};
  const windows = windowsOf(context, lifecycle);
  for (const e of stitch(entries)) {
    if (isMarker(e, lifecycle)) continue;
    const phases = [...phasesOf(e, windows, lifecycle), ...(e.source === "node" && inRestart(e, restart) ? ["restart"] : [])];
    const noise = noiseOf(e, rules, phases);
    const key = keyOf(e) + (noise ? `|noise ${noise}` : "");
    const fp = fingerprint(key);
    const at = e.timestamp ?? e.receiveTimestamp ?? "";
    const g = groups[fp] ??= {
      fp, key,
      service: e.resource?.labels?.service_name ?? "?",
      container: e.labels?.container_name ?? "-",
      title: redact(titleOf(messageOf(e)), 200),
      frame: frameOf(messageOf(e)),
      noise,
      count: 0, first: at, last: at, revisions: [], samples: [],
    };
    g.count++;
    if (at && at < g.first) g.first = at;
    if (at && at > g.last) g.last = at;
    const rev = e.resource?.labels?.revision_name;
    if (rev && !g.revisions.includes(rev)) g.revisions.push(rev);
    const sample = { at, revision: rev ?? "", text: redact(messageOf(e)) };
    if (g.samples.length < 2) g.samples.push(sample);
    else if (g.samples.length === 2) g.samples.splice(1, 0, sample);
    else g.samples[2] = sample;
  }
  for (const g of Object.values(groups)) g.revisions.sort();
  return groups;
}

const hours = (a, b) => Math.max(1, (Date.parse(b) - Date.parse(a)) / 3_600_000);

// A run's groups against the ledger: each group's verdict, and the ledger after it.
//   new        never seen before, and no noise rule meets it
//   regressed  marked fixed, and seen again after it was
//   rising     open or watching, at least 5 this run and more than twice its rate so far an hour
//   open       open or watching, as before
//   noise      a noise rule meets it (by name), or the ledger says it is noise (with why)
// The ledger keeps per fingerprint its title, where, status, why or PR, first and last seen, the
// count, the last revisions and samples; a run never changes a status but new → open and a
// regression's fixed → open.
export function triage(groups, ledger, now) {
  const next = structuredClone(ledger ?? {});
  const report = [];
  for (const g of Object.values(groups)) {
    const was = next[g.fp];
    let verdict;
    if (g.noise) verdict = "noise";
    else if (!was) verdict = "new";
    else if (was.status === "noise") verdict = "noise";
    else if (was.status === "fixed" && g.last > (was.fixedAt ?? "")) verdict = "regressed";
    else if (was.status === "fixed") verdict = "fixed";
    else {
      const rate = was.count / hours(was.first, was.last);
      const runRate = g.count / hours(g.first, now ?? g.last);
      verdict = g.count >= 5 && runRate > 2 * rate ? "rising" : "open";
    }
    const entry = next[g.fp] ?? { title: g.title, service: g.service, container: g.container, frame: g.frame, status: "open", first: g.first, count: 0 };
    if (g.noise) { entry.status = "noise"; entry.reason = `rule ${g.noise}`; }
    if (verdict === "regressed") { entry.status = "open"; entry.reason = `regressed after ${entry.pr ? `PR #${entry.pr}` : "its fix"}`; }
    entry.count += g.count;
    if (!entry.first || g.first < entry.first) entry.first = g.first;
    if (!entry.last || g.last > entry.last) entry.last = g.last;
    entry.revisions = [...new Set([...(entry.revisions ?? []), ...g.revisions])].sort().slice(-5);
    entry.samples = g.samples;
    next[g.fp] = entry;
    // The grouping key is the line before it is redacted: it makes the fingerprint and goes no further.
    const { key: _key, ...shown } = g;
    report.push({ ...shown, verdict, status: entry.status, reason: entry.reason ?? "", pr: entry.pr ?? null });
  }
  const order = { new: 0, regressed: 1, rising: 2, open: 3, fixed: 4, noise: 5 };
  report.sort((a, b) => order[a.verdict] - order[b.verdict] || b.count - a.count);
  return { report, ledger: next };
}

// A ledger entry's status changed by hand (`prod-watch.ts <app> mark`).
/** @param {Record<string, any>} ledger @param {string} fp @param {string} status
 *  @param {{reason?: string, pr?: number | null, at?: string}} [opts] */
export function mark(ledger, fp, status, { reason = "", pr = null, at = "" } = {}) {
  const found = Object.keys(ledger).filter((k) => k.startsWith(fp));
  if (found.length !== 1) throw new Error(found.length ? `${fp} names ${found.length} fingerprints` : `no fingerprint ${fp}`);
  if (!["open", "watching", "noise", "fixed"].includes(status)) throw new Error(`status ${status}: open, watching, noise or fixed`);
  if (status === "noise" && !reason) throw new Error("noise says why");
  const e = { ...ledger[found[0]], status, reason };
  if (pr) e.pr = pr; else delete e.pr;
  if (status === "fixed") e.fixedAt = at; else delete e.fixedAt;
  return { ...ledger, [found[0]]: e };
}

// The report as text: the new, regressed and rising in full, the open on a line each, the rest counted.
export function render(report, { app = "", from = "", to = "" } = {}) {
  const out = [`prod-watch ${app} ${from} → ${to}: ${report.length} fingerprints, ${report.reduce((n, r) => n + r.count, 0)} entries`];
  const by = (v) => report.filter((r) => r.verdict === v);
  for (const v of ["new", "regressed", "rising"]) {
    for (const r of by(v)) {
      out.push(`\n${v.toUpperCase()} ${r.fp} ×${r.count} ${r.service}/${r.container}  ${r.title}`);
      if (r.frame) out.push(`  at ${r.frame}`);
      out.push(`  first ${r.first}  last ${r.last}  revisions ${r.revisions.join(" ")}`);
      for (const s of r.samples) out.push(`  | ${s.at} ${s.revision}\n  | ${s.text.split("\n").slice(0, 12).join("\n  | ")}`);
    }
  }
  const open = by("open");
  if (open.length) out.push(`\nopen:`, ...open.map((r) => `  ${r.fp} ×${r.count} ${r.service}/${r.container}  ${r.title}${r.pr ? ` (PR #${r.pr})` : ""}`));
  const fixed = by("fixed");
  if (fixed.length) out.push(`\nfixed, seen before their fix: ${fixed.map((r) => `${r.fp} ×${r.count}`).join(", ")}`);
  const noise = by("noise");
  if (noise.length) out.push(`\nnoise: ${noise.reduce((n, r) => n + r.count, 0)} entries in ${noise.length} fingerprints (${[...new Set(noise.map((r) => r.reason))].join("; ")})`);
  return out.join("\n");
}
