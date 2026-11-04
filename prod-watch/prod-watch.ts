// prod-watch: what an app's Cloud Run services logged that may be a bug, since the last run.
// Read-only: `gcloud logging read` with the caller's credentials. pronto-plugins' prod-watch/README.md
// says more. Run from the app's folder, where it is written:
//   deno run -A prod-watch/prod-watch.ts <app>                 report since the cursor (3 days on a first run)
//   deno run -A prod-watch/prod-watch.ts <app> --since 6h      report a window, the ledger and cursor left alone
//   deno run -A prod-watch/prod-watch.ts <app> --json          the report as JSON
//   deno run -A prod-watch/prod-watch.ts <app> ls [status]     the ledger
//   deno run -A prod-watch/prod-watch.ts <app> mark <fp> open|watching|noise|fixed [--reason why] [--pr N]
// `cue` from PATH or $CUE. The state (cursor.json, ledger.json) is <the repository's root>/.omc/prod-watch/<app>/,
// runtime state no commit carries.
import { group, mark, render, triage } from "./watch.js";

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

// The app's release, its opt-in and the noise, read from CUE in one export: the app's package with
// its own registry (its .mise.toml's CUE_REGISTRY). prodWatch comes from prod_watch_plugin.cue held
// to #Watch, with the shared noise and the lifecycle windows in it.
function cueOut(cmd: string[], cwd: string, env: Record<string, string> = {}) {
  const o = new Deno.Command(cue, { args: cmd, cwd, env, stdout: "piped", stderr: "piped" }).outputSync();
  if (!o.success) throw new Error(`cue ${cmd.join(" ")} (in ${cwd}):\n${decode(o.stderr)}`);
  return decode(o.stdout);
}
const registry = (() => { try { return Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1]; } catch { return undefined; } })();
const { gcp, watch } = JSON.parse(cueOut(["export", ".", "-e", "{gcp: GCP, watch: prodWatch}", "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {}));
const rules = watch.noise ?? {};
const lifecycle = watch.lifecycle;
// How its fixes reach production: release-cron when the app has one, else by hand.
const released = (() => { try { Deno.statSync(`${appDir}/release_cron.cue`); return "release-cron"; } catch { return "by hand"; } })();
const apart = Object.entries(gcp.sidecars ?? {}).filter(([, s]) => (s as { apart?: unknown }).apart).map(([n]) => `${gcp.service}-${n}`);
const services: string[] = [...new Set([gcp.service, ...apart, ...(watch.services ?? [])])];

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
const o = new Deno.Command("gcloud", {
  args: ["logging", "read", filter, `--project=${gcp.project}`, "--order=asc", `--limit=${limit}`, "--format=json"],
  stdout: "piped", stderr: "piped",
}).outputSync();
if (!o.success) throw new Error(`gcloud logging read:\n${decode(o.stderr)}`);
const entries = JSON.parse(decode(o.stdout) || "[]");
// When the limit cut the window short, the next run starts where this one stopped.
const reached = entries.length >= limit ? entries[entries.length - 1].timestamp : to;

const { report, ledger: next } = triage(group(entries, rules, lifecycle), ledger, reached);
if (json) console.log(JSON.stringify({ app, project: gcp.project, released, services, from, to: reached, report }, null, 1));
else console.log(`services ${services.join(", ")} (${gcp.project}), released: ${released}\n` + render(report, { app, from, to: reached }));
// A window asked for is only looked at: the ledger and the cursor move with the cursor's runs alone.
if (!since) {
  write("ledger.json", next);
  write("cursor.json", { at: reached });
}
