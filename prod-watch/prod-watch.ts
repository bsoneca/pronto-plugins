// prod-watch: what an app's Cloud Run services (and, when it releases to a node, its pods) logged that
// may be a bug, since the last run. Read-only: `gcloud logging read` with the caller's credentials,
// and, for the node's pods, VictoriaLogs and `kubectl get` over ssh. pronto-plugins' prod-watch/README.md
// says more. Run from the app's folder, where it is written:
//   deno run -A prod-watch/prod-watch.ts <app>                 report since the cursor (3 days on a first run)
//   deno run -A prod-watch/prod-watch.ts <app> --since 6h      report a window, the ledger and cursor left alone
//   deno run -A prod-watch/prod-watch.ts <app> --json          the report as JSON
//   deno run -A prod-watch/prod-watch.ts <app> ls [status]     the ledger
//   deno run -A prod-watch/prod-watch.ts <app> mark <fp> open|watching|noise|fixed [--reason why] [--pr N]
// `cue` from PATH or $CUE. The state (cursor.json, ledger.json) is <the repository's root>/.omc/prod-watch/<app>/,
// runtime state no commit carries.
import { brt, group, logEntries, logsQuery, mark, podsOf, releasedOf, render, restartRange, restartWindows, triage, unitOf } from "./watch.js";

// The app's folder: the one this script was written into (prod-watch/ is beside its files).
const appDir = Deno.realPathSync(new URL("../", import.meta.url).pathname);
const cue = Deno.env.get("CUE") ?? "cue";
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
const root = decode(new Deno.Command("git", { args: ["rev-parse", "--show-toplevel"], cwd: appDir, stdout: "piped" }).outputSync().stdout).trim() + "/";

const args = [...Deno.args];
const flag = (name: string) => {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const json = args.includes("--json") && !!args.splice(args.indexOf("--json"), 1);
const since = flag("--since");
const reason = flag("--reason") ?? "";
const pr = flag("--pr");
const [app, verb = "report", ...rest] = args;
if (!app) throw new Error("name the app: prod-watch.ts <app> (the app's folder, with a prodWatch)");

const state = `${root}.omc/prod-watch/${app}`;
Deno.mkdirSync(state, { recursive: true });
// Only a file that is not there yet is the initial value: one that cannot be read or parsed stops the run,
// since a report would overwrite it with an empty one and lose each fingerprint's status.
const read = (f: string, d: unknown) => {
  try { return JSON.parse(Deno.readTextFileSync(`${state}/${f}`)); } catch (e) { if (e instanceof Deno.errors.NotFound) return d; throw new Error(`${state}/${f} is unreadable, mend or remove it: ${e}`); }
};
const write = (f: string, v: unknown) => Deno.writeTextFileSync(`${state}/${f}`, JSON.stringify(v, null, 1) + "\n");
const ledger = read("ledger.json", {});

if (verb === "mark") {
  const [fp, status] = rest;
  write("ledger.json", mark(ledger, fp, status, { reason, pr: pr ? Number(pr) : null, at: new Date().toISOString() }));
  console.log(`${fp}: ${status}${reason ? ` (${reason})` : ""}${pr ? ` PR #${pr}` : ""}`);
  Deno.exit(0);
}
if (verb === "ls") {
  const want = rest[0];
  for (const [fp, e] of Object.entries(ledger) as [string, Record<string, unknown>][]) {
    if (!want || e.status === want) console.log(`${fp} ${e.status} ×${e.count} ${e.service}/${e.container} ${e.title}${e.reason ? ` — ${e.reason}` : ""}${e.pr ? ` PR #${e.pr}` : ""}`);
  }
  Deno.exit(0);
}

type Restart = { unit: string; stop: string; start: string; crash: string; lead: number; tail: number; down: number };
type Node = { restart?: Restart; host: string; kubeconfig: string; namespace: string; containers: string[]; deployments: string[]; logs: { namespace: string; service: string; port: number } };
// The app's release, its opt-in and the noise, read from CUE in one export: the app's package with
// its own registry (its .mise.toml's CUE_REGISTRY). prodWatch comes from prod_watch_plugin.cue held
// to #Watch, with the shared noise and the lifecycle windows in it.
function cueOut(cmd: string[], cwd: string, env: Record<string, string> = {}) {
  const o = new Deno.Command(cue, { args: cmd, cwd, env, stdout: "piped", stderr: "piped" }).outputSync();
  if (!o.success) throw new Error(`cue ${cmd.join(" ")} (in ${cwd}):\n${decode(o.stderr)}`);
  return decode(o.stdout);
}
// Only a file that is not there is an answer (no .mise.toml: no registry; no release.cue: no GCP; no
// release_cron.cue: released by hand); any other failure to read one stops the run.
const absent = (e: unknown) => { if (!(e instanceof Deno.errors.NotFound)) throw e; };
const registry = (() => { try { return Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1]; } catch (e) { absent(e); return undefined; } })();
// GCP only when release.cue declares it: an app that releases elsewhere (Bonk Chess on its node, PRONTO-205)
// watches the Cloud Run services its prodWatch names, in its prodWatch.project.
const declared = (() => { try { return /^GCP:/m.test(Deno.readTextFileSync(`${appDir}/release.cue`)); } catch (e) { absent(e); return false; } })();
const { gcp, watch } = JSON.parse(cueOut(["export", ".", "-e", declared ? "{gcp: GCP, watch: prodWatch}" : "{watch: prodWatch}", "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {}));
const node: Node | undefined = watch.node;
const project: string = watch.project ?? gcp?.project ?? "";
const rules = watch.noise ?? {};
const lifecycle = watch.lifecycle;
// How its fixes reach production: release-cron when the app has one, else by hand.
const released = (() => { try { Deno.statSync(`${appDir}/release_cron.cue`); return "release-cron"; } catch (e) { absent(e); return "by hand"; } })();
const apart = gcp ? Object.entries(gcp.sidecars ?? {}).filter(([, s]) => (s as { apart?: unknown }).apart).map(([n]) => `${gcp.service}-${n}`) : [];
const services: string[] = [...new Set([...(gcp ? [gcp.service] : []), ...apart, ...(watch.services ?? [])])];
if (!services.length && !node) throw new Error(`${appDir}: nothing to watch: release.cue declares no GCP and prodWatch names no services and no node`);
if (services.length && !project) throw new Error(`${appDir}: no project to watch: release.cue declares no GCP and prodWatch names no project`);

// The window: from the cursor (or --since), to now.
const cursor = read("cursor.json", null);
const ago = (s: string) => {
  const m = s.match(/^(\d+)([mhd])$/);
  if (!m) throw new Error(`--since ${s}: like 30m, 6h or 3d`);
  return new Date(Date.now() - Number(m[1]) * { m: 60e3, h: 3600e3, d: 86400e3 }[m[2] as "m" | "h" | "d"]).toISOString();
};
const from = since ? ago(since) : cursor?.at ?? ago("3d");
const to = new Date().toISOString();
// What may be a bug: a warning or worse, a 5xx, or a line written to stderr unlabelled that says it
// failed; never a request answered below 500. And Cloud Run's start and shutdown lines, which open
// an instance's windows (prodWatch.lifecycle).
const filter = [
  `resource.type="cloud_run_revision"`,
  `resource.labels.service_name=(${services.map((s) => JSON.stringify(s)).join(" OR ")})`,
  `timestamp>"${from}"`, `timestamp<="${to}"`,
  `(severity>=WARNING OR httpRequest.status>=500 OR textPayload=~"(?i)(error|panic|exception|traceback|fatal|refused|failed)" OR textPayload=~"(^Starting new instance|^Shutting down|SIGTERM)")`,
  `(NOT httpRequest:* OR httpRequest.status>=500)`,
].join(" AND ");
const limit = 50000;
let entries: { timestamp: string; [k: string]: unknown }[] = [];
// When the limit cut the window short, the next run starts where this one stopped.
let reached = to;
if (services.length) {
  const o = new Deno.Command("gcloud", {
    args: ["logging", "read", filter, `--project=${project}`, "--order=asc", `--limit=${limit}`, "--format=json"],
    stdout: "piped", stderr: "piped",
  }).outputSync();
  if (!o.success) throw new Error(`gcloud logging read:\n${decode(o.stderr)}`);
  entries = JSON.parse(decode(o.stdout) || "[]");
  if (entries.length >= limit) {
    // Cut at the limit: the entries of the last timestamp may go on past it, and the next query reads
    // strictly after the cursor, so they are left for it whole: the cursor is the timestamp before.
    const last = entries[entries.length - 1].timestamp;
    entries = entries.filter((e) => e.timestamp < last);
    if (!entries.length) throw new Error(`${limit} entries share the timestamp ${last}: narrow the window (--since) to read them`);
    reached = entries[entries.length - 1].timestamp;
  }
}

// The node's pods (prodWatch.node): their lines in VictoriaLogs, which the node's Vector fills and
// which keeps them past the pod's life. Over ssh, read-only: `kubectl get` finds the Service's address
// and the pods, and curl on the node asks LogsQL's query API (a read) with the query on stdin; no
// kubectl verb but get, no cluster object made. The only words that reach the remote shell are the
// schema's, each held to letters, digits and a few signs.
async function onNode(n: Node, script: string, stdin = ""): Promise<{ ok: boolean; out: string; err: string }> {
  const p = new Deno.Command("ssh", {
    args: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", n.host, `export KUBECONFIG=${n.kubeconfig}; ${script}`],
    stdin: "piped", stdout: "piped", stderr: "piped",
  }).spawn();
  const w = p.stdin.getWriter();
  await w.write(new TextEncoder().encode(stdin));
  await w.close();
  const o = await p.output();
  return { ok: o.success, out: decode(o.stdout), err: decode(o.stderr) };
}
// A deliberate k3s restart (prodWatch.node.restart) is what the node's systemd journal says it was, read-only:
// `sudo -n journalctl` (the journal is not the login user's to read) for the unit's lines of systemd itself, and
// `systemctl show` for its ActiveEnterTimestamp and NRestarts, which the last run's is compared with. The journal
// is read as far as the schema's lead, down and tail say a window touching the report can reach (restartRange),
// and a window is taken only as far as that read (until). A read that fails stops the run before anything is
// written, so the next run reads the window again. The unit is the schema's, held to letters and signs.
let restartWins: { from: string; to: string }[] = [];
let restartNow: number | null = null;
if (node?.restart) {
  const r = node.restart;
  const day = (iso: string) => iso.slice(0, 19).replace("T", " ") + " UTC";
  const range = restartRange(from, to, r);
  const j = await onNode(node, `sudo -n journalctl -u ${r.unit} _PID=1 --utc -o short-iso --no-pager -q --since '${day(range.since)}' --until '${day(range.until)}'`);
  const u = await onNode(node, `TZ=UTC systemctl show ${r.unit} -p ActiveEnterTimestamp -p NRestarts`);
  if (!j.ok || !u.ok) throw new Error(`the node's ${r.unit} restarts were not read (${(j.err || u.err).trim().slice(0, 300) || "no message"}): the ledger and the cursor are where they were`);
  const unit = unitOf(u.out);
  restartNow = unit.nRestarts;
  const was = read("k3s.json", {}).nRestarts ?? null;
  restartWins = restartWindows({ journal: j.out, activeEnter: unit.activeEnter, restarts: { was, now: unit.nRestarts }, until: range.until }, r);
}
const sources: { release?: { at: string; short: string; sha: string } | null; images: Record<string, string>; pods: number } = { images: {}, pods: 0 };
if (node) {
  const n: Node = node;
  const pods = await onNode(n, `kubectl get pods -n ${n.namespace} -o json`);
  if (!pods.ok) throw new Error(`kubectl get pods -n ${n.namespace} on ${n.host}:\n${pods.err}`);
  const starts = podsOf(JSON.parse(pods.out), n.deployments);
  sources.pods = new Set(starts.map((c) => c.pod)).size;
  for (const c of starts) sources.images[`${c.deployment}/${c.container}`] = c.revision;
  const l = n.logs;
  // The window in slices of 4 hours, each its own query: VictoriaLogs (512Mi on the node) cut one long
  // window's response off mid-stream ("chunk hex-length char not a hex digit"), so a day's cursor never read.
  const slice = 4 * 3600e3;
  const got = { ok: true, out: "", err: "" };
  for (let t = Date.parse(from), left = limit; t < Date.parse(to) && left > 0; t += slice) {
    const end = new Date(Math.min(t + slice, Date.parse(to))).toISOString();
    const r = await onNode(
      n,
      `ip=$(kubectl -n ${l.namespace} get svc ${l.service} -o jsonpath='{.spec.clusterIP}') && curl -sS --fail --max-time 300 "http://$ip:${l.port}/select/logsql/query" --data-urlencode query@- --data-urlencode start=${new Date(t).toISOString()} --data-urlencode end=${end} --data-urlencode limit=${left}`,
      logsQuery(n, lifecycle),
    );
    if (!r.ok) { got.ok = false; got.err = r.err; break; }
    got.out += r.out;
    left -= r.out.split("\n").filter(Boolean).length;
  }
  // A slice that failed stops the run before it reads anything or writes a cursor, so the next run reads that window again.
  if (!got.ok) throw new Error(`the node's logs were not read (${got.err.trim().slice(0, 300) || "no message"}): the cursor is where it was`);
  // A cut at the limit: the next run starts where this one stopped, at the latest timestamp read (VictoriaLogs'
  // start is inclusive), so the rows of that timestamp, which may go on past the cut, are left for it whole.
  let rows = got.out.split("\n").filter(Boolean);
  if (rows.length >= limit) {
    const cut = rows.map((r) => JSON.parse(r)._time as string).reduce((a, b) => (Date.parse(b) > Date.parse(a) ? b : a));
    rows = rows.filter((r) => Date.parse(JSON.parse(r)._time) < Date.parse(cut));
    if (!rows.length) throw new Error(`${limit} rows share the timestamp ${cut}: narrow the window (--since) to read them`);
    if (Date.parse(cut) < Date.parse(reached)) reached = cut;
  }
  const lines = logEntries(rows.join("\n"), { from, lifecycle, starts });
  // What the node's entries are, kept through the merge: a restart window is the node's, never a Cloud Run service's.
  entries.push(...lines.map((l: Record<string, unknown>) => ({ ...l, source: "node" })) as typeof entries);
  entries.sort((a, b) => (Date.parse(a.timestamp) - Date.parse(b.timestamp)));
  // What is serving: the last release of release-cron's log, else the images the pods run.
  // No log is the one thing to go without (an app release-cron does not release); any other failure to read it fails the run.
  try { sources.release = releasedOf(Deno.readTextFileSync(`${Deno.env.get("HOME")}/.cache/pronto/release-cron/${app}/release-cron.log`), app); } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
    sources.release = null;
  }
}

// Each source read up to its own limit: the window ends at the earliest cutoff, for both, and what lies
// past it is the next run's.
entries = entries.filter((e) => Date.parse(e.timestamp) <= Date.parse(reached));
// A line can reach its source after the run that asked for its window (Vector's buffer, Cloud Logging's
// ingestion) with a timestamp before the cursor. So a run that read to now commits its cursor a lag behind
// it, and the next one reads that overlap again: the entries it already counted, kept by hash in the cursor,
// are not counted twice.
const lag = 5 * 60e3;
// The hash is of the entry as the source gave it, without the `source` tag, so a cursor's hashes stay valid.
const hashOf = async (e: unknown) => [...new Uint8Array(await crypto.subtle.digest("SHA-1", new TextEncoder().encode(JSON.stringify({ ...(e as object), source: undefined }))))].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
const hashes = new Map<unknown, string>();
for (const e of entries) hashes.set(e, await hashOf(e));
if (!since) {
  const counted = new Set<string>(cursor?.seen ?? []);
  entries = entries.filter((e) => !counted.has(hashes.get(e)!));
}
const committed = reached === to ? new Date(Date.parse(reached) - lag).toISOString() : reached;
const { report, ledger: next } = triage(group(entries, rules, lifecycle, restartWins), ledger, reached);
const where = [
  ...(services.length ? [`services ${services.join(", ")} (${project})`] : []),
  ...(node ? [`node ${node.namespace} on ${node.host} (${sources.pods} pods)`] : []),
].join("; ");
const serving = !node ? "" : sources.release ? `, release ${sources.release.short} at ${brt(sources.release.at)}` : `, no release-cron log or release of ${app} in it: serving ${Object.keys(sources.images).length} containers' images (--json)`;
if (json) console.log(JSON.stringify({ app, project, released, services, node: node ? { ...node, ...sources } : undefined, from, to: reached, report }, null, 1));
else console.log(`${where}, released: ${released}${serving}\n` + render(report, { app, from, to: reached }));
// A window asked for is only looked at: the ledger and the cursor move with the cursor's runs alone.
if (!since) {
  write("ledger.json", next);
  // The overlap is read again, so what it holds is what the next run must not count again.
  const seen = [...hashes].filter(([e]) => Date.parse((e as { timestamp: string }).timestamp) > Date.parse(committed)).map(([, h]) => h);
  write("cursor.json", { at: committed, seen });
  if (restartNow !== null) write("k3s.json", { nRestarts: restartNow });
}
