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
    out.push(e);
  }
  return out;
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
// The phase an entry falls in, start or shutdown, or "": from two seconds before its instance's
// marker to its seconds after.
export function phaseOf(entry, windows, lifecycle) {
  const at = Date.parse(entry.timestamp);
  const mine = windows?.[entry.labels?.instanceId] ?? {};
  for (const [phase, times] of Object.entries(mine)) {
    const within = (lifecycle?.[phase]?.within ?? 0) * 1000;
    if (times.some((t) => at >= Date.parse(t) - 2000 && at - Date.parse(t) <= within)) return phase;
  }
  return "";
}
// Whether an entry is a lifecycle marker and no more, read for the windows and reported never: one at
// WARNING or above (a container killed by signal 11) is reported too.
const RANK = { DEFAULT: 0, DEBUG: 100, INFO: 200, NOTICE: 300, WARNING: 400, ERROR: 500, CRITICAL: 600, ALERT: 700, EMERGENCY: 800 };
export const isMarker = (entry, lifecycle) => (RANK[entry.severity ?? "DEFAULT"] ?? 0) < RANK.WARNING &&
  Object.values(lifecycle ?? {}).some((l) => new RegExp(l.marker).test(clean(messageOf(entry))));

// The noise rule an entry meets, by service, container, message and phase (schema.cue's #Noise), or null.
export function noiseOf(entry, rules, phase = "") {
  const text = clean(messageOf(entry));
  for (const [name, r] of Object.entries(rules ?? {})) {
    if (r.during && !r.during.includes(phase)) continue;
    if (r.service && !new RegExp(`^(?:${r.service})$`).test(entry.resource?.labels?.service_name ?? "")) continue;
    if (r.container && !new RegExp(`^(?:${r.container})$`).test(entry.labels?.container_name ?? "")) continue;
    if (new RegExp(r.match, "m").test(text)) return name;
  }
  return null;
}

// The entries as groups, one a fingerprint (the same line noise in its window and not outside it
// makes two): how many, when first and last, on which revisions, and
// up to three redacted samples, the first, the last and one between.
export function group(entries, rules, lifecycle = {}) {
  const groups = {};
  const windows = windowsOf(entries, lifecycle);
  for (const e of stitch(entries)) {
    if (isMarker(e, lifecycle)) continue;
    const noise = noiseOf(e, rules, phaseOf(e, windows, lifecycle));
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
    report.push({ ...g, verdict, status: entry.status, reason: entry.reason ?? "", pr: entry.pr ?? null });
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
