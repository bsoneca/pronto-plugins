// The board's Ready queue (PRONTO-658), the verbs' logic behind board.ts so a unit case can run it on a
// fake Board (tests/unit/devflow_queue.cue): Ready is first in, first out by when each issue became
// Ready (flow.js readySince, from the board's state moves), a bug at P1 or P0 jumps it, and each lane
// (engineer, SRE, architect) pulls the first of its own. There are no sprints. board.ts parses the
// arguments, prints and exits; the rules are flow.js's.
import { type Board, esc, type Issue, type State } from "./board/board.ts";
import { ageOf, bugPlace, claimText, claimWinner, jumps, laneOf, mayStart, mergedByDay, nameOf, priorityOf, pullOrder, readySince, roleOf, staleOf } from "./flow.js";
import type { DevFlow, Role } from "./spec.ts";

const DAY = 86400000;

/** `fn` over `items`, at most `n` at a time: Plane limits a token to 300 calls a minute, and an activity
 * is one call an issue. */
async function pool<T, R>(items: T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    for (let i = next++; i < items.length; i = next++) out[i] = await fn(items[i]);
  }));
  return out;
}

/** What the verbs read of the board once: its states and the flow's words for them, each issue's
 * modules (for its lane) and the bug label's id. */
export interface Ctx {
  flow: DevFlow;
  project: string;
  states: State[];
  slots: Record<string, number>;
  priorities: Record<string, string>;
  bugLabel: string | null;
  /** Whether the modules and labels were read (a lane and a bug label need them). */
  lanes: boolean;
  stateId(name: string): string;
  roleId(role: Role): string;
  stateName(id: string): string;
  roleAt(id: string): Role | null;
  laneOf(i: Issue): string;
  key(i: Issue): string;
}

/** The context for a verb. `lanes: false` (file) skips the modules and the labels, the slowest reads (PRONTO-341). */
export async function contextOf(board: Board, flow: DevFlow, project: string, lanes = true): Promise<Ctx> {
  const [states, modulesOf, labels] = await Promise.all([
    board.states(project),
    lanes ? board.modulesByIssue(project) : Promise.resolve(new Map<string, string[]>()),
    lanes ? board.labels(project) : Promise.resolve([]),
  ]);
  const stateName = (id: string) => states.find((s) => s.id === id)?.name ?? "?";
  const stateId = (n: string) => states.find((s) => s.name === n)?.id ?? (() => { throw new Error(`no state ${n}: run bin/pronto connect plane`); })();
  return {
    flow,
    project,
    states,
    slots: { engineer: flow.team.engineers, SRE: flow.team.sre, architect: flow.team.architect },
    priorities: Object.fromEntries(Object.entries(flow.priorities).map(([p, v]) => [p, v.plane])),
    bugLabel: labels.find((l) => l.name.toLowerCase() === "bug")?.id ?? null,
    lanes,
    stateId,
    roleId: (r) => stateId(nameOf(flow.roles, r)),
    stateName,
    roleAt: (id) => roleOf(flow.roles, stateName(id)) as Role | null,
    laneOf: (i) => laneOf(modulesOf.get(i.id) ?? [], flow.infra, flow.design),
    key: (i) => `${flow.board.project.identifier}-${i.sequence_id}`,
  };
}

export interface Queued {
  key: string;
  name: string;
  sequence: number;
  lane: string;
  /** When it became Ready (ISO), or null when the board cannot say. */
  readyAt: string | null;
  /** The short age in Ready: "3h", "2d". */
  age: string;
  jump: boolean;
  /** The board's P0: it starts past the slots (flow.js mayStart). */
  urgent: boolean;
  /** "P1" or "P0" of a jumping bug, else null. */
  priority: string | null;
  starving: boolean;
}

/** The Ready issues in the order they are pulled: a jumping bug (P0's first), then the oldest in Ready.
 * `lane` keeps one lane's alone, before any activity is read. A Ready issue the board cannot date (no
 * move into Ready and no creation time) is an error, never a silent place in the queue. */
export async function readyQueue(board: Board, ctx: Ctx, all: Issue[], now: Date, lane?: string): Promise<Queued[]> {
  if (!ctx.lanes) throw new Error("readyQueue needs a context read with its lanes (contextOf(..., true))");
  const ready = all.filter((i) => ctx.roleAt(i.state) === "ready" && (!lane || ctx.laneOf(i) === lane));
  const readyId = ctx.roleId("ready");
  const urgent = [ctx.priorities.P0, ctx.priorities.P1];
  const pName = (word: string) => Object.entries(ctx.priorities).find(([, w]) => w === word)?.[0] ?? null;
  const queued = await pool(ready, 8, async (i): Promise<Queued> => {
    const moves = board.stateMoves ? await board.stateMoves(ctx.project, i.id) : [];
    const readyAt = readySince(moves, readyId, i.created_at ?? null);
    if (!readyAt) throw new Error(`${ctx.key(i)} is Ready but the board gives neither a move into Ready nor a creation time`);
    const bug = !!ctx.bugLabel && (i.labels ?? []).includes(ctx.bugLabel);
    const jump = jumps(i.priority, bug, urgent);
    return {
      key: ctx.key(i), name: i.name, sequence: i.sequence_id, lane: ctx.laneOf(i), readyAt, age: ageOf(readyAt, now), jump, urgent: i.priority === ctx.priorities.P0,
      priority: jump ? pName(i.priority) : null, starving: readyAt ? staleOf(readyAt, now, ctx.flow.queue.starvingDays) : false,
    };
  });
  return pullOrder(queued.map((q) => ({ ...q, p0: q.jump && q.urgent }))) as Queued[];
}

export interface Outcome { outcome: "started" | "lost" | "waits"; message: string }

/** Starts an issue: Implementing, if its lane has a slot. From a pull (`claim`), only while the issue
 * is still Ready, and only for the pull whose claim came first (flow.js claimWinner): a pull that lost
 * answers "lost" and leaves the issue to the other (PRONTO-341). `now` and `nonce` are injected: the
 * claim compares comments' times against the clock. */
export async function start(board: Board, ctx: Ctx, k: string, opts: { claim?: boolean; now: () => Date; nonce?: string }): Promise<Outcome> {
  const claim = opts.claim ?? false;
  const [issue, all] = await Promise.all([board.issue(k), board.issues(ctx.project, true)]);
  if (claim && ctx.roleAt(issue.state) !== "ready") return { outcome: "lost", message: `${k} is no longer Ready (${ctx.stateName(issue.state)}): another pull took it` };
  const l = ctx.laneOf(issue);
  const busy = all.filter((i) => ctx.roleAt(i.state) === "implementing" && ctx.laneOf(i) === l).length;
  const may = mayStart(busy, ctx.slots[l], issue.priority, l, ctx.priorities.P0);
  if (!may.ok) return { outcome: "waits", message: `${k} waits: ${may.why}` };
  const from = ctx.stateName(issue.state);
  const implementing = nameOf(ctx.flow.roles, "implementing");
  const nonce = opts.nonce ?? crypto.randomUUID();
  await board.moveIssue(ctx.project, issue.id, ctx.stateId(implementing));
  await board.comment(ctx.project, issue.id, `<p>${esc(from)} → ${esc(implementing)}: ${esc(may.why)}${claim ? ` (${claimText(nonce)})` : ""}</p>`);
  if (claim) {
    const first = claimWinner(await board.comments(ctx.project, issue.id), opts.now().toISOString());
    if (first !== nonce) return { outcome: "lost", message: `${k} was pulled by another session at the same moment, which keeps it` };
  }
  return { outcome: "started", message: `${k} ${from} → ${implementing} (${may.why})` };
}

/** The lane's first Ready issue in the queue, started; one another session took meanwhile is passed
 * over for the next. A lane with no free slot stops there: its next issue would wait the same. */
export async function pull(board: Board, ctx: Ctx, lane: string, opts: { now: () => Date; nonce?: string }): Promise<{ outcome: "started" | "waits" | "empty"; lines: string[] }> {
  if (!(lane in ctx.slots)) throw new Error(`a lane is engineer, SRE or architect, not ${lane}`);
  const queue = await readyQueue(board, ctx, await board.issues(ctx.project, true), opts.now(), lane);
  const lines: string[] = [];
  let full = false;
  for (const q of queue) {
    // Once the lane is full only a P0 may go on: it starts past the slots (flow.js mayStart).
    if (full && !q.urgent) continue;
    const r = await start(board, ctx, q.key, { claim: true, ...opts });
    lines.push(r.message);
    if (r.outcome === "started") return { outcome: "started", lines };
    if (r.outcome === "waits") full = true;
  }
  if (full) return { outcome: "waits", lines };
  lines.push(`nothing Ready for ${lane}`);
  return { outcome: "empty", lines };
}

/** Files an issue: a bug (the `bug` label) at its priority's place (flow.js bugPlace), else in the
 * Backlog, in its app's module. It joins no cycle: there are none. */
export async function file(board: Board, ctx: Ctx, f: { title: string; app: string; bug?: boolean; priority?: string; flag?: string; body?: string }) {
  const priority = f.priority ? priorityOf(f.priority, ctx.priorities) : f.bug ? ctx.priorities.P2 : "none";
  const place = f.bug ? bugPlace(f.priority ?? "P2", ctx.priorities) : { role: "backlog" };
  const body = [f.body ? `<p>${esc(f.body).replace(/\n/g, "<br>")}</p>` : "", f.flag ? `<p>Flag: ${esc(f.flag)}</p>` : ""].join("");
  let labels: string[] = [];
  if (f.bug) {
    const have = (await board.labels(ctx.project)).find((x) => x.name === "bug");
    labels = [have ? have.id : (await board.createLabel(ctx.project, "bug", "#ef4444")).id];
  }
  const made = await board.createIssue(ctx.project, { name: f.title, description_html: body || "<p></p>", priority, state: ctx.roleId(place.role as Role), labels });
  const mod = (await board.modules(ctx.project)).find((m) => m.name === f.app);
  if (mod) await board.addToModule(ctx.project, mod.id, [made.id]);
  return { key: ctx.key(made), state: nameOf(ctx.flow.roles, place.role as Role), module: mod ? f.app : null };
}

export interface QueueStatus {
  slots: Record<string, { of: number; on: string[] }>;
  queue: Record<string, { key: string; title: string; age: string; readyAt: string | null; jump: boolean; priority: string | null; starving: boolean }[]>;
  starving: { key: string; age: string }[];
  merged: { today: number; week: number; byDay: { day: string; count: number }[] };
  issues: Record<string, string[]>;
  backlog: number;
}

/** When an issue merged: its first move into a completed state after its last move out of one (an
 * issue sent back and merged again merged at the second). The board's `completed_at` is not it: Plane
 * rewrites it when the issue is later made Done, moving a merge to the day of its flip. One read an
 * issue, so only for those whose `completed_at` is within the window. Without moves, `completed_at`. */
async function mergedAt(board: Board, ctx: Ctx, i: Issue): Promise<string | null> {
  const completed = new Set(ctx.states.filter((s) => s.group === "completed").map((s) => s.id));
  const moves = board.stateMoves ? (await board.stateMoves(ctx.project, i.id)).map((m) => ({ ...m, t: Date.parse(m.at) })).filter((m) => Number.isFinite(m.t)).sort((a, b) => a.t - b.t) : [];
  const lastOut = moves.map((m, n) => (completed.has(m.to) ? -1 : n)).reduce((a, b) => Math.max(a, b), -1);
  const first = moves.slice(lastOut + 1).find((m) => completed.has(m.to));
  return first ? new Date(first.t).toISOString() : i.completed_at ?? null;
}

/** The queue per lane, what starves, the slots, merges by day and the open issues by state. */
export async function queueStatus(board: Board, ctx: Ctx, all: Issue[], now: Date): Promise<QueueStatus> {
  const queued = await readyQueue(board, ctx, all, now);
  const lanes = Object.keys(ctx.slots);
  const busy = all.filter((i) => ctx.roleAt(i.state) === "implementing");
  const byState = (roles: Role[]) => Object.fromEntries(ctx.flow.states
    .filter((s) => roles.includes(roleOf(ctx.flow.roles, s.name) as Role))
    .map((s) => [s.name, all.filter((i) => ctx.stateName(i.state) === s.name).map((i) => `${ctx.key(i)} ${i.name}`)])
    .filter(([, v]) => (v as string[]).length));
  // Merges within `queue.mergedDays`: an issue whose completed_at is older cannot have merged within them.
  const days = ctx.flow.queue.mergedDays;
  const doneRoles = ["merged", "live", "done"];
  const recent = all.filter((i) => doneRoles.includes(ctx.roleAt(i.state) ?? "") && (i.completed_at ? now.getTime() - Date.parse(i.completed_at) < days * DAY : false));
  const times = (await pool(recent, 8, (i) => mergedAt(board, ctx, i))).filter((t): t is string => !!t);
  return {
    slots: Object.fromEntries(lanes.map((l) => [l, { of: ctx.slots[l], on: busy.filter((i) => ctx.laneOf(i) === l).map(ctx.key) }])),
    queue: Object.fromEntries(lanes.map((l) => [l, queued.filter((q) => q.lane === l).map((q) => ({ key: q.key, title: q.name, age: q.age, readyAt: q.readyAt, jump: q.jump, priority: q.priority, starving: q.starving }))])),
    starving: queued.filter((q) => q.starving).map((q) => ({ key: q.key, age: q.age })),
    merged: mergedByDay(times, now, ctx.flow.timeZone, days),
    issues: byState(["refine", "ready", "implementing", "review"]),
    backlog: all.filter((i) => ctx.roleAt(i.state) === "backlog").length,
  };
}

/** The slots line: `3 of 6 engineer slots busy (PRONTO-1, ...), 0 of 1 SRE slots busy, ...`. */
export const slotsLine = (s: QueueStatus) =>
  Object.entries(s.slots).map(([l, v]) => `${v.on.length} of ${v.of} ${l} slots busy${v.on.length ? ` (${v.on.join(", ")})` : ""}`).join(", ");

/** The lines `status` prints after the slots and the stuck issues, each easy to grep. */
export function queueLines(s: QueueStatus, flow: DevFlow): string[] {
  const out: string[] = [];
  for (const [l, is] of Object.entries(s.queue)) {
    out.push(`  ready to pull, ${l}: ${is.length ? is.map((i) => `${i.key} ${i.title} (${i.jump ? `${i.priority} bug, ` : ""}${i.age})`).join("; ") : "none"}`);
  }
  if (s.starving.length) out.push(`starving: ${s.starving.map((q) => `${q.key} Ready ${q.age} (over ${flow.queue.starvingDays}d)`).join("; ")}`);
  out.push(`merged: ${s.merged.today} today, ${s.merged.week} in ${flow.queue.mergedDays} days${s.merged.byDay.length ? ` (${s.merged.byDay.map((d) => `${d.day} ${d.count}`).join(", ")})` : ""}`);
  for (const [state, is] of Object.entries(s.issues)) if (state !== nameOf(flow.roles, "ready")) out.push(`  open, ${state}: ${is.join("; ")}`);
  out.push(`backlog: ${s.backlog}`);
  return out;
}
