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
import { brt, group, logEntries, logsQuery, mark, podsOf, releasedOf, render, triage } from "./watch.js";

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
const read = (f: string, d: unknown) => { try { return JSON.parse(Deno.readTextFileSync(`${state}/${f}`)); } catch { return d; } };
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

type Node = { host: string; kubeconfig: string; namespace: string; containers: string[]; deployments: string[]; logs: { namespace: string; service: string; port: number } };
// The app's release, its opt-in and the noise, read from CUE in one export: the app's package with
// its own registry (its .mise.toml's CUE_REGISTRY). prodWatch comes from prod_watch_plugin.cue held
// to #Watch, with the shared noise and the lifecycle windows in it.
function cueOut(cmd: string[], cwd: string, env: Record<string, string> = {}) {
  const o = new Deno.Command(cue, { args: cmd, cwd, env, stdout: "piped", stderr: "piped" }).outputSync();
  if (!o.success) throw new Error(`cue ${cmd.join(" ")} (in ${cwd}):\n${decode(o.stderr)}`);
  return decode(o.stdout);
}
const registry = (() => { try { return Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1]; } catch { return undefined; } })();
// GCP only when release.cue declares it: an app that releases elsewhere (Bonk Chess on its node, PRONTO-205)
// watches the Cloud Run services its prodWatch names, in its prodWatch.project.
const declared = (() => { try { return /^GCP:/m.test(Deno.readTextFileSync(`${appDir}/release.cue`)); } catch { return false; } })();
const { gcp, watch } = JSON.parse(cueOut(["export", ".", "-e", declared ? "{gcp: GCP, watch: prodWatch}" : "{watch: prodWatch}", "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {}));
const node: Node | undefined = watch.node;
const project: string = watch.project ?? gcp?.project ?? "";
const rules = watch.noise ?? {};
const lifecycle = watch.lifecycle;
// How its fixes reach production: release-cron when the app has one, else by hand.
const released = (() => { try { Deno.statSync(`${appDir}/release_cron.cue`); return "release-cron"; } catch { return "by hand"; } })();
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
  if (entries.length >= limit) reached = entries[entries.length - 1].timestamp;
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
const sources: { release?: { at: string; short: string; sha: string } | null; images: Record<string, string>; pods: number } = { images: {}, pods: 0 };
if (node) {
  const n: Node = node;
  const pods = await onNode(n, `kubectl get pods -n ${n.namespace} -o json`);
  if (!pods.ok) throw new Error(`kubectl get pods -n ${n.namespace} on ${n.host}:\n${pods.err}`);
  const starts = podsOf(JSON.parse(pods.out), n.deployments);
  sources.pods = new Set(starts.map((c) => c.pod)).size;
  for (const c of starts) sources.images[`${c.deployment}/${c.container}`] = c.revision;
  const l = n.logs;
  const got = await onNode(
    n,
    `ip=$(kubectl -n ${l.namespace} get svc ${l.service} -o jsonpath='{.spec.clusterIP}') && curl -sS --fail --max-time 300 "http://$ip:${l.port}/select/logsql/query" --data-urlencode query@- --data-urlencode start=${from} --data-urlencode end=${to} --data-urlencode limit=${limit}`,
    logsQuery(n),
  );
  if (!got.ok) throw new Error(`VictoriaLogs ${l.namespace}/${l.service} on ${n.host}:\n${got.err}`);
  const lines = logEntries(got.out, { from, lifecycle, starts });
  // A cut at the limit: the next run starts where this one stopped.
  const rows = got.out.split("\n").filter(Boolean);
  if (rows.length >= limit) reached = JSON.parse(rows[rows.length - 1])._time;
  entries.push(...lines.filter((e) => e.timestamp <= reached));
  entries.sort((a, b) => (a.timestamp < b.timestamp ? -1 : a.timestamp > b.timestamp ? 1 : 0));
  // What is serving: the last release of release-cron's log, else the images the pods run.
  try { sources.release = releasedOf(Deno.readTextFileSync(`${Deno.env.get("HOME")}/.cache/pronto/release-cron/${app}/release-cron.log`), app); } catch { sources.release = null; }
}

const { report, ledger: next } = triage(group(entries, rules, lifecycle), ledger, reached);
const where = [
  ...(services.length ? [`services ${services.join(", ")} (${project})`] : []),
  ...(node ? [`node ${node.namespace} on ${node.host} (${sources.pods} pods)`] : []),
].join("; ");
const serving = !node ? "" : sources.release ? `, release ${sources.release.short} at ${brt(sources.release.at)}` : `, serving ${Object.keys(sources.images).length} containers' images (--json)`;
if (json) console.log(JSON.stringify({ app, project, released, services, node: node ? { ...node, ...sources } : undefined, from, to: reached, report }, null, 1));
else console.log(`${where}, released: ${released}${serving}\n` + render(report, { app, from, to: reached }));
// A window asked for is only looked at: the ledger and the cursor move with the cursor's runs alone.
if (!since) {
  write("ledger.json", next);
  write("cursor.json", { at: reached });
}
