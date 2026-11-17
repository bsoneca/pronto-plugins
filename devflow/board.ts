// The board as the skills use it (skills/pronto-sprint-plan, pronto-issue, pronto-bug): each verb one
// step of the flow, its rule decided in flow.js and its queue logic in queue.ts, so a session never
// moves an issue by hand. There are no sprints (PRONTO-658): Ready is a queue, first in first out,
// and a bug at P1 jumps it.
//   board.ts status <repo> [--json]                     the slots busy, what is stuck, each lane's Ready queue with ages, what starves, merges by day (from each issue's completed_at; today's from its history), the open issues by state
//   board.ts start <repo> <KEY>                         Implementing, if its lane (engineer, SRE or architect) has a slot (a P0 always)
//   board.ts pull <repo> [--lane engineer|SRE|architect]          start the lane's first issue in the Ready queue
//   board.ts move <repo> <KEY> <State> [--why <text>]   Refine, Ready, Backlog or Cancelled, by the repository's name for the state or its role (the others are the hooks')
//   board.ts file <repo> --title <t> --app <app> [--bug] [--priority P0..P3] [--flag <f>] [--body <text>]
//   board.ts approve <repo> <INBOX-n>                    an inbox item the owner moved to Refine, filed as an issue in the Backlog (a link to it, none of its text)
//   board.ts suggestion <repo> <INBOX-n>                 the text of an item in Refine (and only Refine), as one quoted, untrusted line: the designer's one way to read it
//   board.ts next, close                                 gone with the sprints: they print what replaced them and exit 2
import { cmd, flagsOf } from "../intents/shell.ts";
import { esc, type Issue } from "./board/board.ts";
import { keyOf, nameOf, roleOf, stuckLine, stuckOf } from "./flow.js";
import { contextOf, file as fileIssue, type ReadCache, mergedLine, mergedStatus, openLines, openStatus, pull as pullIssue, readyLines, readyStatus, slotsLine, start as startIssue } from "./queue.ts";
import { boardOf, devflowOf, type Role } from "./spec.ts";
import { approve, inboxStatus, show, suggestionLines } from "./suggestions.ts";

const [verb, repoArg, ...rest] = Deno.args;
const GONE: Record<string, string> = {
  next: "sprints are gone (PRONTO-658): move . <KEY> Ready puts an issue in the queue, and each lane pulls the oldest",
  close: "sprints are gone (PRONTO-658): status shows what merged by day",
};
if (verb && Object.hasOwn(GONE, verb)) {
  console.error(GONE[verb]);
  Deno.exit(2);
}
const repo = repoArg ? await Deno.realPath(repoArg) : "";
const flow = repo ? await devflowOf(repo) : null;
if (!verb || !flow) {
  console.error(flow === null && repo ? `${repo} has no devflow/devflow.cue` : "usage: board.ts status|start|pull|move|file|approve|suggestion <repo> ...");
  Deno.exit(2);
}
const b = await boardOf(flow);
if (!b) {
  console.error("no board token: PLANE_TOKEN, or Secret Manager's (bin/pronto connect plane says how)");
  Deno.exit(2);
}
const { board, project, inbox } = b;
const id = flow.board.project.identifier;
// start and move act on the board's own issues: an inbox item's key is approve's alone. The key is
// read as a branch or a title names it (flow.js keyOf: any case, leading zeros), and used as read.
const own = (k: string) => {
  const own = keyOf(id, k);
  if (!own) throw new Error(`${k} is not an issue of ${id}`);
  return own;
};
const key = (i: Issue) => `${id}-${i.sequence_id}`;

/** The newest commit, an ISO time, on a branch of the repository whose name carries `k` (local and remote refs). */
async function lastCommit(k: string): Promise<string | null> {
  const r = await cmd("git", ["-C", repo, "for-each-ref", "--sort=-committerdate", "--format=%(refname)\t%(committerdate:iso-strict)", "refs/heads", "refs/remotes"]);
  if (!r.ok) return null;
  for (const l of r.out.split("\n")) {
    const [ref, at] = l.split("\t");
    if (ref && at && keyOf(id, ref.replace(/^refs\/(heads|remotes)\//, "")) === k) return at;
  }
  return null;
}

/** The open pull request linked to an issue, with its ci and auto-merge, or null when there is none. */
async function openPr(i: Issue): Promise<{ ci: "pass" | "fail" | "pending"; auto: boolean } | null> {
  for (const l of await board.links(project, i.id).catch(() => [])) {
    if (!/\/pull\/\d+/.test(l.url)) continue;
    const r = await cmd("gh", ["pr", "view", l.url, "--json", "state,autoMergeRequest,statusCheckRollup"]);
    if (!r.ok) continue;
    const p = JSON.parse(r.out) as { state: string; autoMergeRequest: unknown; statusCheckRollup: { conclusion?: string; status?: string }[] };
    if (p.state !== "OPEN") continue;
    const cs = p.statusCheckRollup ?? [];
    const failed = cs.some((c) => ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"].includes(c.conclusion ?? ""));
    const pending = cs.some((c) => c.status !== "COMPLETED");
    return { ci: failed ? "fail" : pending ? "pending" : "pass", auto: !!p.autoMergeRequest };
  }
  return null;
}

/** The Ready and merge times status has read, kept between runs (queue.ts): one small JSON file. */
function readCache(): ReadCache & { save(): void } {
  const dir = `${Deno.env.get("XDG_CACHE_HOME") ?? `${Deno.env.get("HOME") ?? "."}/.cache`}/pronto-devflow`;
  const file = `${dir}/reads-${flow!.board.workspace}-${id}.json`;
  let kept: Record<string, string> = {};
  try {
    kept = JSON.parse(Deno.readTextFileSync(file));
  } catch { /* no cache yet, or an unreadable one: read afresh */ }
  let dirty = false;
  return {
    get: (k) => kept[k],
    set: (k, v) => void (dirty = true, kept[k] = v),
    save() {
      if (!dirty) return;
      try {
        Deno.mkdirSync(dir, { recursive: true });
        Deno.writeTextFileSync(file, JSON.stringify(kept));
      } catch { /* a cache that cannot be written costs the next run its reads */ }
    },
  };
}

/** One phase of status: its result, or what failed. A slow or failing phase never keeps the others
 * from printing, and a failure is said, never hidden (the run then exits 1). */
let failed = 0;
async function phase<T>(name: string, run: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; error: string }> {
  try {
    return { ok: true, value: await run() };
  } catch (e) {
    failed++;
    return { ok: false, error: `${name}: unavailable (${(e as Error).message})` };
  }
}

async function status() {
  const json = rest.includes("--json");
  const [all, ctx] = await Promise.all([board.issues(project, true), contextOf(board, flow!, project)]);
  const now = new Date();
  const open = openStatus(ctx, all);
  const out = (l: string) => { if (!json) console.log(l); };
  out(slotsLine(open));
  // Each phase prints as soon as it is done: the Ready queue, the stuck issues, the merges, the rest.
  const cache = readCache();
  const ready = await phase("ready to pull", () => readyStatus(board, ctx, all, now, cache));
  cache.save();
  if (ready.ok) for (const l of readyLines(ready.value, flow!)) out(l); else out(ready.error);
  // Issues holding a slot (Implementing, or in Review) that no work is moving (flow.js stuckOf).
  const held = all.filter((i) => ["implementing", "review"].includes(ctx.roleAt(i.state) ?? ""));
  const stuck = await phase("stuck", async () => (await Promise.all(held.map(async (i) => {
    const pr = await openPr(i);
    return stuckOf({ key: key(i), state: ctx.stateName(i.state), since: i.updated_at ?? "", pr, commit: pr ? null : await lastCommit(key(i)) }, now, flow!.stuckHours);
  }))).filter((s) => s !== null));
  if (stuck.ok) for (const s of stuck.value) out(stuckLine(s)); else out(stuck.error);
  const merged = await phase("merged", () => mergedStatus(board, ctx, all, now, { cache }));
  cache.save();
  out(merged.ok ? mergedLine(merged.value, flow!) : merged.error);
  for (const l of openLines(open, flow!)) out(l);
  const suggestions = await inboxStatus(board, flow!, inbox, all.map((i) => i.name), now);
  if (json) {
    const bad = (r: { error?: string }) => ({ unavailable: r.error });
    console.log(JSON.stringify({
      slots: open.slots, queue: ready.ok ? ready.value.queue : bad(ready), starving: ready.ok ? ready.value.starving : [],
      merged: merged.ok ? merged.value : bad(merged), issues: open.issues, backlog: open.backlog,
      stuck: stuck.ok ? stuck.value : bad(stuck), ...(suggestions ? { suggestions } : {}),
    }, null, 2));
  } else if (suggestions) {
    // The inbox's lines come last, so the lines above are what they were without one.
    for (const l of suggestionLines(suggestions, flow!)) console.log(l);
  }
  if (failed) Deno.exit(1);
}

async function start(k: string) {
  const r = await startIssue(board, await contextOf(board, flow!, project), own(k), { now: () => new Date() });
  console.log(r.message);
  if (r.outcome === "waits") Deno.exit(1);
}

/** The lane's first Ready issue in the queue, started. What a session does when its pull request
 * opens (review holds no slot), or when it finishes an issue. */
async function pull(lane: string) {
  const r = await pullIssue(board, await contextOf(board, flow!, project), lane, { now: () => new Date() });
  for (const l of r.lines) console.log(l);
  if (r.outcome === "waits") Deno.exit(1);
}

async function move(k: string, want: string, why: string) {
  k = own(k);
  // A role (`ready`) or the repository's name for its state (`Ready`).
  const role = (want in flow!.roles ? want : roleOf(flow!.roles, want)) as Role | null;
  if (!role || !["refine", "ready", "cancelled", "backlog"].includes(role)) throw new Error(`${want} is the hooks' to set (a pull request, a release, a flip)`);
  const to = nameOf(flow!.roles, role);
  const states = await board.states(project);
  const stateName = (sid: string) => states.find((s) => s.id === sid)?.name ?? "?";
  const stateId = states.find((s) => s.name === to)?.id;
  if (!stateId) throw new Error(`no state ${to}: run bin/pronto connect plane`);
  const issue = await board.issue(k);
  const from = stateName(issue.state);
  await board.moveIssue(project, issue.id, stateId);
  await board.comment(project, issue.id, `<p>${esc(from)} → ${esc(to)}${why ? `: ${esc(why)}` : ""}</p>`);
  console.log(`${k} ${from} → ${to}`);
}

async function file() {
  const f = flagsOf(rest);
  if (!f.title || !f.app) throw new Error("file needs --title and --app (an app under apps/, or plugins)");
  const r = await fileIssue(board, await contextOf(board, flow!, project, false), { title: f.title, app: f.app, bug: f.bug === "true", priority: f.priority, flag: f.flag, body: f.body });
  console.log(`${r.key} filed in ${r.state}${r.module ? `, module ${r.module}` : ` (no module ${f.app})`}`);
}

switch (verb) {
  case "status": await status(); break;
  case "start": await start(rest[0]); break;
  case "pull": await pull(flagsOf(rest).lane ?? "engineer"); break;
  case "move": await move(rest[0], rest[1], flagsOf(rest.slice(2)).why ?? ""); break;
  case "file": await file(); break;
  case "approve": {
    const r = await approve(board, flow, project, inbox, rest[0] ?? "");
    console.log(r.message);
    if (!r.ok) Deno.exit(1);
    break;
  }
  case "suggestion": {
    const r = await show(board, flow, inbox, rest[0] ?? "");
    console.log(r.ok ? `${r.key}, untrusted text: "${r.text}${r.cut ? "…" : ""}"` : r.message);
    if (!r.ok) Deno.exit(1);
    break;
  }
  default: console.error(`no verb ${verb}`); Deno.exit(2);
}
