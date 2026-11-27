// The alerts watch (PRONTO-2182): Cloud Monitoring's incidents of each of the flow's `alerts.projects` are read, flow.js
// alertClass says which alert policy is down (outage), opens and closes over and over (flapping) or has been open for days
// (stale), and each of those is filed on the board once, a bug naming the file to change. A run that cannot read a project
// says so (`unavailable`), never that all is well. What `pronto-devflow alerts` prints and exits by is in board.ts.
import { cmd } from "../intents/shell.ts";
import { type Board } from "./board/board.ts";
import { alertClass, alertFilings, alertOf, alertSource, alertTitle, askAgain } from "./flow.js";
import { cacheDir, keptKeys, locked } from "./flags.ts";
import { contextOf, file as fileIssue } from "./queue.ts";
import type { DevFlow } from "./spec.ts";

/** An incident as alertClass reads it: nothing but the policy's name, display name and user labels, and the incident's state and times. */
export interface Incident { policy: string; display: string; labels: Record<string, string>; state: string; openTime: string; closeTime?: string }
type Fetch = (url: string, init: { headers: Record<string, string>; signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;
type Alert = { state?: string; openTime?: string; closeTime?: string; policy?: { name?: string; displayName?: string; userLabels?: Record<string, string> } };

const PAGES = 20;
const HOURS = 48;

/** The incidents of `project` opened in the last 48 hours or open now, a page of 100 at a time (at most 20 pages: a read cut short
 * throws, since a partial read says nothing is wrong that it may not have seen). A GET that fails is asked again as flow.js askAgain
 * says, then throws naming the status; the token is sent and never named. */
export async function incidents(project: string, token: string, fetcher: Fetch = fetch as unknown as Fetch, now = new Date(), sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms + Math.random() * 1000))): Promise<Incident[]> {
  const since = new Date(now.getTime() - HOURS * 3600000).toISOString().replace(/\.\d+Z$/, "Z");
  const out: Incident[] = [];
  let next = "";
  for (let page = 0; page < PAGES; page++) {
    const q = new URLSearchParams({ pageSize: "100", filter: `open_time>="${since}" OR state="OPEN"` });
    if (next) q.set("pageToken", next);
    const url = `https://monitoring.googleapis.com/v3/projects/${project}/alerts?${q}`;
    let body: { alerts?: Alert[]; nextPageToken?: string } | null = null;
    for (let attempt = 0; body === null; attempt++) {
      let failure: number | "timeout" | "network" = "network";
      let why = "";
      try {
        const r = await fetcher(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30000) });
        if (r.ok) {
          body = (await r.json()) as { alerts?: Alert[]; nextPageToken?: string };
          break;
        }
        failure = r.status;
        const e = (await r.json().catch(() => null)) as { error?: { message?: string } } | null;
        why = (e?.error?.message ?? "").split("\n")[0].slice(0, 120);
      } catch (e) {
        failure = (e as Error).name === "TimeoutError" ? "timeout" : "network";
      }
      const wait = askAgain("GET", failure, attempt);
      if (wait === null) throw new Error(`monitoring alerts of ${project}: ${failure}${why ? ` ${why}` : ""}`);
      await sleep(wait);
    }
    for (const a of body.alerts ?? []) {
      if (!a.policy?.name || !a.state || !a.openTime) continue;
      out.push({ policy: a.policy.name, display: a.policy.displayName ?? a.policy.name, labels: a.policy.userLabels ?? {}, state: a.state, openTime: a.openTime, ...(a.closeTime ? { closeTime: a.closeTime } : {}) });
    }
    next = body.nextPageToken ?? "";
    if (!next) return out;
  }
  throw new Error(`monitoring alerts of ${project}: more than ${PAGES} pages, the read is cut short`);
}

/** The reader's access token, from the gcloud the environment names (CLOUDSDK_ACTIVE_CONFIG_NAME). Never printed. */
export async function gcloudToken(): Promise<string> {
  const r = await cmd("gcloud", ["auth", "print-access-token"]).catch(() => ({ ok: false, out: "", err: "" }));
  if (!r.ok || !r.out.trim()) throw new Error("no access token: gcloud auth print-access-token failed");
  return r.out.trim();
}

export interface Filed { key: string | null; class: string; policy: string; app: string; cue: string | null; known?: boolean }
export interface AlertsRun { filed: Filed[]; known: Filed[]; unavailable: { project: string; reason: string }[]; dryRun: boolean }
export interface AlertsIO {
  fetch?: Fetch;
  token?: () => Promise<string>;
  /** Where the filed `class:policy` names are kept, and the lock that keeps two runs apart (the devflow cache, a lock directory). */
  state?: { read(): string[]; write(keys: string[]): void };
  lock?: <T>(fn: () => Promise<T>) => Promise<T>;
  sleep?: (ms: number) => Promise<void>;
}

const consoleLink = (policy: string) => {
  const m = /^projects\/([^/]+)\/alertPolicies\/([^/]+)$/.exec(policy);
  return m ? `https://console.cloud.google.com/monitoring/alerting/policies/${m[2]}?project=${m[1]}` : null;
};

/** The words of the bug: what the alert did, and where it is. A flapping or stale one is the alert's own bug. */
function bodyOf(r: { class: string; display: string; policy: string; opens: number; openSince: string | null }, cue: string | null, unmapped: string | null) {
  const lines = [`Alert policy: ${r.display}`, `Class: ${r.class}`, `Opens in the last 24 hours: ${r.opens}`, `First open: ${r.openSince ?? "unknown"}`];
  const link = consoleLink(r.policy);
  if (link) lines.push(`Console: ${link}`);
  if (r.class !== "outage") lines.push(`This is a bug in the alert: change ${cue ? `\`${cue}\`` : "the file that holds the policy"} (threshold, duration, absence window or auto-close), then release@infra.`);
  if (unmapped) lines.push(`Filed under plugins: ${unmapped} maps to no app in devflow/devflow.cue alerts.apps.`);
  return lines.join("\n");
}

/** Reads each project's incidents, files what is new and says what it filed, what was known already and what it could not read.
 * `board` is null only for a dry run with no board token: nothing is then known on the board, and nothing is filed. `fresh` is
 * `--new`: the caller prints only what was filed. With `dryRun` no issue is made and no state kept. */
export async function watchAlerts(flow: DevFlow, b: { board: Board; project: string } | null, now: Date, opts: { dryRun?: boolean; io?: AlertsIO } = {}): Promise<AlertsRun> {
  const rules = flow.alerts;
  if (!rules) throw new Error("devflow/devflow.cue has no alerts block");
  const io = opts.io ?? {};
  const dryRun = !!opts.dryRun;
  const id = `${flow.board.workspace}-${flow.board.project.identifier}`;
  const state = io.state ?? keptKeys(`${cacheDir()}/alerts-${id}.json`);
  const lock = io.lock ?? (<T>(fn: () => Promise<T>) => locked(id, fn, "alerts"));
  return await lock(async () => {
    const unavailable: AlertsRun["unavailable"] = [];
    const rows: ReturnType<typeof alertClass> = [];
    const labels = new Map<string, Record<string, string>>();
    let token: string | null = null;
    let tokenError = "";
    try {
      token = await (io.token ?? gcloudToken)();
    } catch (e) {
      tokenError = (e as Error).message;
    }
    for (const project of rules.projects) {
      try {
        if (!token) throw new Error(tokenError);
        const list = await incidents(project, token, io.fetch, now, io.sleep);
        for (const i of list) labels.set(i.policy, i.labels);
        rows.push(...alertClass(list, now, { flapOpens: rules.flapOpens, flapCloseMin: rules.flapCloseMin, staleHours: rules.staleHours, apps: rules.apps }));
      } catch (e) {
        unavailable.push({ project, reason: (e as Error).message });
      }
    }
    const id = flow.board.project.identifier;
    const keyOf = (i: { sequence_id: number }) => `${id}-${i.sequence_id}`;
    // The board's open issues, read again before each filing: a second run, or another verb, may have filed it meanwhile.
    const openIssues = async () => {
      if (!b) return [];
      const states = await b.board.states(b.project);
      const closed = new Set(states.filter((s) => s.group === "completed" || s.group === "cancelled").map((s) => s.id));
      return (await b.board.issues(b.project, true)).filter((i) => !closed.has(i.state));
    };
    const seen = state.read();
    const live = rows.filter((r) => r.class !== "ok");
    const issues = await openIssues();
    const known: Filed[] = [];
    const filed: Filed[] = [];
    const entry = (r: (typeof rows)[number], key: string | null): Filed => ({ key, class: r.class, policy: r.display, app: r.app ?? "plugins", cue: alertSource(r.display, rules.sources) });
    const fresh = new Set(alertFilings(live, issues, seen).map((r: { policy: string }) => r.policy));
    for (const r of live) {
      if (fresh.has(r.policy)) continue;
      const hit = issues.find((i) => alertOf(i.name)?.display === r.display);
      known.push({ ...entry(r, hit ? keyOf(hit) : null), known: true });
    }
    const kept = new Set(seen.filter((s) => unavailable.length > 0 || live.some((r) => s === `${r.class}:${r.policy}`)));
    let ctx: Awaited<ReturnType<typeof contextOf>> | null = null;
    for (const r of live.filter((x) => fresh.has(x.policy))) {
      const again = dryRun ? issues : await openIssues();
      if (alertFilings([r], again, [...kept]).length === 0) {
        const hit = again.find((i) => alertOf(i.name)?.display === r.display);
        known.push({ ...entry(r, hit ? keyOf(hit) : null), known: true });
        continue;
      }
      const cue = alertSource(r.display, rules.sources);
      if (dryRun || !b) {
        filed.push(entry(r, null));
        continue;
      }
      ctx ??= await contextOf(b.board, flow, b.project, false);
      const word = rules.priority[r.class as "outage" | "flapping" | "stale"];
      const p = Object.entries(ctx.priorities).find(([, w]) => w === word)?.[0];
      if (!p) throw new Error(`alerts.priority.${r.class} is ${word}, which is no priority of the board`);
      const lab = labels.get(r.policy) ?? {};
      const unmapped = r.app === null ? `its labels app=${lab.app ?? "(none)"} owner=${lab.owner ?? "(none)"}` : null;
      const made = await fileIssue(b.board, ctx, { title: alertTitle(r.class, r.display), app: r.app ?? "plugins", bug: true, priority: p, body: bodyOf(r, cue, unmapped) });
      kept.add(`${r.class}:${r.policy}`);
      state.write([...kept]);
      filed.push(entry(r, made.key));
    }
    if (!dryRun) state.write([...kept]);
    return { filed, known, unavailable, dryRun };
  });
}

/** What `alerts` prints: the count line, a line for each project it could not read, then one JSON line for each issue filed (and, unless `onlyNew`, each already known). */
export function alertLines(run: AlertsRun, onlyNew = false): string[] {
  const verb = run.dryRun ? "would file" : "filed";
  const lines = [`alerts: ${run.filed.length} ${verb}, ${run.known.length} known, ${run.unavailable.length} unavailable${run.dryRun ? " (dry run)" : ""}`];
  for (const u of run.unavailable) lines.push(`alerts: unavailable (${u.project}: ${u.reason})`);
  for (const f of run.filed) lines.push(JSON.stringify({ key: f.key, class: f.class, policy: f.policy, app: f.app, cue: f.cue }));
  if (!onlyNew) for (const f of run.known) lines.push(JSON.stringify({ key: f.key, class: f.class, policy: f.policy, app: f.app, cue: f.cue, known: true }));
  return lines;
}
