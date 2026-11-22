// The board as the skills use it (skills/pronto-sprint-plan, pronto-issue, pronto-bug): each verb one
// step of the flow, its rule decided in flow.js and its queue logic in queue.ts, so a session never
// moves an issue by hand. There are no sprints (PRONTO-658): Ready is a queue, pulled in the flow's queue.order (ready: first in first out; filed: oldest filed first),
// and a bug at a queue.jump priority (P1 or P0) jumps it.
//   board.ts status <repo> [--json]                     the slots busy, what is stuck, each lane's Ready queue with ages, what starves, merges by day (from each issue's completed_at; today's from its history), the open issues by state
//   board.ts start <repo> <KEY>                         Implementing, if its lane (engineer, SRE or architect) has a slot (a P0 always)
//   board.ts pull <repo> [--lane engineer|SRE|architect|feature]  start the lane's first issue in the Ready queue (feature: an engineer's feature issue alone; the engineer lane's reserved slots take only those)
//   board.ts move <repo> <KEY> <State> [--why <text>]   Refine, Ready, Backlog or Cancelled, by the repository's name for the state or its role (the others are the hooks')
//   board.ts file <repo> --title <t> --app <app> [--bug] [--priority P0..P3] [--flag <f>] [--body <text>]
//   board.ts wait <repo> <KEY> --pr <url>               the issue's fix merged under another issue's pull request: a flip issue in Implementing waits for the release holding it (PRONTO-666); any other moves as that merge would have moved it (Merged, or Done for infra, design and plugins), and the release or flip hook finishes it (PRONTO-1050). Neither holds a slot.
//   board.ts approve <repo> <INBOX-n>                    an inbox item the owner moved to Refine, filed as an issue in the Backlog (a link to it, none of its text)
//   board.ts suggestion <repo> <INBOX-n>                 the text of an item in Refine (and only Refine), as one quoted, untrusted line: the designer's one way to read it
//   board.ts prs <repo>                                 the open pull requests nobody is driving (`forgotten PRs:`, devflow/prs.ts), each repository of the flow's prs.repos; exit 1 when there are any, for the hourly scheduled check. Needs no board token. `status` prints the same line.
//   board.ts flags <repo> [--new] [--notes]             the flags merged to main and not on for everyone in production (`pending flags:`, devflow/flags.ts): the apps of the flow's flagsRepo at origin/main, minus the flags the owner holds (flagsHeld), and `; drift:` for a flag live true that the spec says off; exit 1 when there are any, for the hourly scheduled check. --new lists only those not reported before; --notes adds each one's note. `status` prints the same line.
//   board.ts next, close                                 gone with the sprints: they print what replaced them and exit 2
import { cmd, flagsOf } from "../intents/shell.ts";
import { esc } from "./board/board.ts";
import { doneAt, flagOf, flipOf, keyOf, nameOf, roleOf, waitPlan } from "./flow.js";
import { move as hookMove } from "./hook.ts";
import { contextOf, file as fileIssue, pull as pullIssue, type ReadCache, start as startIssue, status } from "./queue.ts";
import { boardOf, devflowOf, type Role } from "./spec.ts";
import { watchFlags } from "./flags.ts";
import { watchPrs } from "./prs.ts";
import { approve, show } from "./suggestions.ts";

const [verb, repoArg, ...rest] = Deno.args;
const GONE: Record<string, string> = {
  next: "sprints are gone (PRONTO-658): move . <KEY> Ready puts an issue in the queue, and each lane pulls the first of the queue (queue.order: the oldest in Ready, or the oldest filed)",
  close: "sprints are gone (PRONTO-658): status shows what merged by day",
};
if (verb && Object.hasOwn(GONE, verb)) {
  console.error(GONE[verb]);
  Deno.exit(2);
}
const repo = repoArg ? await Deno.realPath(repoArg) : "";
const flow = repo ? await devflowOf(repo) : null;
if (!verb || !flow) {
  console.error(flow === null && repo ? `${repo} has no devflow/devflow.cue` : "usage: board.ts status|prs|flags|start|pull|move|file|wait|approve|suggestion <repo> ...");
  Deno.exit(2);
}
if (verb === "prs") {
  try {
    const w = await watchPrs(flow, new Date());
    console.log(w.line);
    if (w.list.length) Deno.exit(1);
    Deno.exit(0);
  } catch (e) {
    console.log(`forgotten PRs: unavailable (${(e as Error).message})`);
    Deno.exit(1);
  }
}
if (verb === "flags") {
  try {
    const f = flagsOf(rest);
    const w = await watchFlags(flow, new Date(), f.new === "true");
    console.log(w.line);
    if (f.notes === "true") for (const p of w.list) console.log(`  ${p.app}/${p.flag}: ${p.note || "(no note)"}`);
    Deno.exit(w.list.length || w.drift.length ? 1 : 0);
  } catch (e) {
    console.log(`pending flags: unavailable (${(e as Error).message})`);
    Deno.exit(1);
  }
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

/** A pull request's ci and auto-merge, or null when it is not open or gh cannot read it. */
async function openPr(url: string): Promise<{ ci: "pass" | "fail" | "pending"; auto: boolean } | null> {
  const r = await cmd("gh", ["pr", "view", url, "--json", "state,autoMergeRequest,statusCheckRollup"]);
  if (!r.ok) return null;
  const p = JSON.parse(r.out) as { state: string; autoMergeRequest: unknown; statusCheckRollup: { conclusion?: string; status?: string }[] };
  if (p.state !== "OPEN") return null;
  const cs = p.statusCheckRollup ?? [];
  const failed = cs.some((c) => ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"].includes(c.conclusion ?? ""));
  const pending = cs.some((c) => c.status !== "COMPLETED");
  return { ci: failed ? "fail" : pending ? "pending" : "pass", auto: !!p.autoMergeRequest };
}

/** The Ready and merge times status has read, kept between runs (queue.ts): one small JSON file, read
 * only if it is a plain object of times, written whole to a temporary file and renamed. */
function readCache(): ReadCache {
  const dir = `${Deno.env.get("XDG_CACHE_HOME") ?? `${Deno.env.get("HOME") ?? "."}/.cache`}/pronto-devflow`;
  const file = `${dir}/reads-${flow!.board.workspace}-${id}.json`;
  const kept = new Map<string, string>();
  try {
    const read = JSON.parse(Deno.readTextFileSync(file));
    if (read && typeof read === "object" && !Array.isArray(read)) {
      for (const [k, v] of Object.entries(read)) if (typeof v === "string" && Number.isFinite(Date.parse(v))) kept.set(k, v);
    }
  } catch { /* no cache yet, or an unreadable one: read afresh */ }
  let dirty = false;
  return {
    get: (k) => kept.get(k),
    set: (k, v) => void (dirty = true, kept.set(k, v)),
    save(live) {
      // Keys are `<kind>:<issue id>@<time>`: an answer of an issue no longer listed goes.
      for (const k of [...kept.keys()]) if (!live.has(k.slice(k.indexOf(":") + 1, k.lastIndexOf("@")))) (dirty = true, kept.delete(k));
      if (!dirty) return;
      const tmp = `${file}.${Deno.pid}.tmp`;
      try {
        Deno.mkdirSync(dir, { recursive: true });
        Deno.writeTextFileSync(tmp, JSON.stringify(Object.fromEntries(kept)));
        Deno.renameSync(tmp, file);
        dirty = false;
      } catch { /* a cache that cannot be written costs the next run its reads */ }
    },
  };
}

async function statusVerb() {
  const json = rest.includes("--json");
  const r = await status(board, flow!, project, {
    now: () => new Date(),
    cache: readCache(),
    inbox,
    pr: openPr,
    lastCommit,
    print: (l) => { if (!json) console.log(l); },
  });
  // The pull requests nobody drives come after the board's lines; a gh error is shown, never taken for none.
  let prs: unknown;
  let failures = r.failures;
  try {
    const w = await watchPrs(flow!, new Date());
    prs = w.list;
    if (!json) console.log(w.line);
  } catch (e) {
    failures++;
    prs = { unavailable: (e as Error).message };
    if (!json) console.log(`forgotten PRs: unavailable (${(e as Error).message})`);
  }
  // The flags merged and not yet flipped come after them, the same way.
  let pending: unknown;
  try {
    const w = await watchFlags(flow!, new Date());
    pending = { pending: w.list, drift: w.drift };
    if (!json) console.log(w.line);
  } catch (e) {
    failures++;
    pending = { unavailable: (e as Error).message };
    if (!json) console.log(`pending flags: unavailable (${(e as Error).message})`);
  }
  if (json) console.log(JSON.stringify({ ...r.json, forgottenPrs: prs, pendingFlags: pending }, null, 2));
  if (failures) Deno.exit(1);
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

/** An issue whose fix merged under another issue's pull request (flow.js waitPlan): an Implementing flip issue
 * waits for the release holding it (the merged pull request linked, the wait label put on, made on first use,
 * and a comment saying what it waits for); any other moves as its own merge would have, and the hooks finish it. */
async function wait(k: string, url: string) {
  k = own(k);
  if (!/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+$/.test(url)) throw new Error("wait needs --pr <the fix's pull request address>");
  const issue = await board.issue(k);
  const states = await board.states(project);
  const role = roleOf(flow!.roles, states.find((s) => s.id === issue.state)?.name ?? "");
  const mine = await cmd("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], { cwd: repo });
  if (!mine.ok || !url.startsWith(`https://github.com/${mine.out.trim()}/pull/`)) throw new Error(`${url} is not a pull request of the repository this board serves`);
  const pr = await cmd("gh", ["pr", "view", url, "--json", "state"]);
  if (!pr.ok) throw new Error(`gh pr view ${url}: ${pr.err.trim().split("\n")[0]}`);
  const n = `#${/\d+$/.exec(url)![0]}`;
  const links = (await board.links(project, issue.id)).map((l) => l.url).filter((u) => /\/pull\/\d+$/.test(u));
  const open = (await Promise.all(links.map(openPr))).some((p) => p !== null);
  const mods = (await board.modulesByIssue(project)).get(issue.id) ?? [];
  const done = doneAt(flagOf(issue.description_html), mods, [...flow!.infra, ...flow!.design]);
  const plan = waitPlan({ key: n, role, flip: flipOf(issue.name) !== null, merged: JSON.parse(pr.out).state === "MERGED", openPr: open, done, modules: mods });
  if (plan.refused) throw new Error(`${k} does not wait: ${plan.refused}`);
  if (plan.wait && !board.setLabels) throw new Error("this board cannot set an issue's labels");
  if (!links.includes(url)) await board.link(project, issue.id, url, n);
  if (plan.wait) {
    if (!board.setLabels) throw new Error("this board cannot set an issue's labels");
    const have = (await board.labels(project)).find((l) => l.name === flow!.waitLabel);
    const label = have ?? await board.createLabel(project, flow!.waitLabel, "#f59e0b");
    await board.setLabels(project, issue.id, [...new Set([...(issue.labels ?? []), label.id])]);
    await board.comment(project, issue.id, `<p>waits for the release holding ${esc(n)}</p>`);
    console.log(`${k} waits for the release holding ${n}: it holds no slot until then`);
    return;
  }
  console.log(await hookMove({ board, project }, issue, "merged", `${n} merged its fix under another issue (wait --pr)`, flow!, mods));
  if (plan.to === "done") return;
  // A flagged issue goes Done on its flag's next flip; one whose flag is already on for everyone gets no new flip event.
  console.log(done === "flip"
    ? `${k} holds no slot; its flag's flip finishes it (if the flag is on for everyone already: hook.ts flipped <repo> <app> <flag>)`
    : `${k} holds no slot; its app's next release finishes it`);
}

switch (verb) {
  case "status": await statusVerb(); break;
  case "start": await start(rest[0]); break;
  case "pull": await pull(flagsOf(rest).lane ?? "engineer"); break;
  case "move": await move(rest[0], rest[1], flagsOf(rest.slice(2)).why ?? ""); break;
  case "file": await file(); break;
  case "wait": await wait(rest[0], flagsOf(rest.slice(1)).pr ?? ""); break;
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
