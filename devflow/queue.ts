// The board's Ready queue (PRONTO-658), the verbs' logic behind board.ts so a unit case can run it on a
// fake Board (tests/unit/devflow_queue.cue): the flow's `queue.order` says how Ready is pulled, "ready"
// first in, first out by when each issue became Ready (flow.js readySince, from the board's state moves),
// "filed" by when each was filed, a design's children at their umbrella's place (PRONTO-1538); a bug at
// a priority of `queue.jump` (P1 or P0) jumps it, and each lane (engineer, SRE, architect) pulls the
// first of its own. There are no sprints. board.ts parses the
// arguments, prints and exits; the rules are flow.js's.
import { type Board, esc, type Issue, type State } from "./board/board.ts";
import { featureOf, ageOf, bugPlace, dayOf, claimText, claimWinner, filedPlace, jumps, laneOf, mayStart, mergedByDay, nameOf, priorityOf, pullOrder, readySince, roleOf, staleOf, stuckLine, stuckOf, waitsRelease } from "./flow.js";
import type { DevFlow, Role } from "./spec.ts";
import { inboxStatus, suggestionLines } from "./suggestions.ts";

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
  /** The id of the feature label, when the board has it. */
  featureLabel: string | null;
  /** The engineer slots only feature issues take: the flow's, as many as the engineers at most, none while the board has no feature label. */
  reserved: number;
  /** The id of the label of a flip issue waiting for a release (flow.waitLabel), when the board has it. */
  waitLabel: string | null;
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
  const featureLabel = labels.find((l) => l.name === flow.featureLabel)?.id ?? null;
  return {
    flow,
    project,
    states,
    slots: { engineer: flow.team.engineers, SRE: flow.team.sre, architect: flow.team.architect },
    priorities: Object.fromEntries(Object.entries(flow.priorities).map(([p, v]) => [p, v.plane])),
    bugLabel: labels.find((l) => l.name.toLowerCase() === "bug")?.id ?? null,
    featureLabel,
    // At least one slot always takes any issue: a small team never reserves all of them for features.
    reserved: featureLabel ? Math.max(0, Math.min(flow.team.featureEngineers, flow.team.engineers - 1)) : 0,
    waitLabel: labels.find((l) => l.name === flow.waitLabel)?.id ?? null,
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
  /** A feature issue: it may take a slot reserved for features. */
  feature: boolean;
  key: string;
  name: string;
  sequence: number;
  lane: string;
  /** When it became Ready (ISO), or null when the board cannot say. */
  readyAt: string | null;
  /** What order "filed" sorts by (ISO): its creation, or its umbrella's with `queue.childrenAtUmbrella`; null when the board cannot say. */
  filedAt: string | null;
  /** The number it sorts at in "filed" order: its umbrella's, or its own. */
  umbrella: number;
  /** The short age in Ready: "3h", "2d". */
  age: string;
  jump: boolean;
  /** The board's P0: it starts past the slots (flow.js mayStart). */
  urgent: boolean;
  /** "P1" or "P0" of a jumping bug, else null. */
  priority: string | null;
  starving: boolean;
}

/** The Ready issues in the order they are pulled (`queue.order`): a jumping bug (P0's first), then the oldest in Ready, or the oldest filed.
 * `lane` keeps one lane's alone, before any activity is read. A Ready issue the board cannot date (no
 * move into Ready and no creation time) is an error, never a silent place in the queue. */
export async function readyQueue(board: Board, ctx: Ctx, all: Issue[], now: Date, lane?: string, cache?: ReadCache): Promise<Queued[]> {
  if (!ctx.lanes) throw new Error("readyQueue needs a context read with its lanes (contextOf(..., true))");
  // The lane "feature" is the engineer lane's feature issues alone (the session of a slot reserved for them).
  const ready = all.filter((i) => ctx.roleAt(i.state) === "ready" && (!lane || (lane === "feature" ? ctx.laneOf(i) === "engineer" && featureOf(i.labels, ctx.featureLabel) : ctx.laneOf(i) === lane)));
  const readyId = ctx.roleId("ready");
  const q = ctx.flow.queue;
  const urgent = (q.jump ?? ["P0", "P1"]).map((p) => ctx.priorities[p]);
  const pName = (word: string) => Object.entries(ctx.priorities).find(([, w]) => w === word)?.[0] ?? null;
  const queued = await pool(ready, 8, async (i): Promise<Queued> => {
    // One activity read an issue, kept while the issue is unchanged (`updated_at`): a warm status reads none.
    const k = i.updated_at ? `ready:${i.id}@${i.updated_at}` : null;
    let readyAt = k ? cache?.get(k) ?? null : null;
    if (!readyAt) {
      const moves = board.stateMoves ? await board.stateMoves(ctx.project, i.id) : [];
      readyAt = readySince(moves, readyId, i.created_at ?? null);
      if (readyAt && k) cache?.set(k, readyAt);
    }
    if (!readyAt) throw new Error(`${ctx.key(i)} is Ready but the board gives neither a move into Ready nor a creation time`);
    const bug = !!ctx.bugLabel && (i.labels ?? []).includes(ctx.bugLabel);
    const jump = jumps(i.priority, bug, urgent);
    const place = filedPlace(i, all, q.order === "filed" && !!q.childrenAtUmbrella);
    if (q.order === "filed" && !place.filedAt) throw new Error(`${ctx.key(i)} is Ready but the board gives no creation time to file it by`);
    return {
      ...place,
      key: ctx.key(i), name: i.name, sequence: i.sequence_id, lane: ctx.laneOf(i), feature: featureOf(i.labels, ctx.featureLabel), readyAt, age: ageOf(readyAt, now), jump, urgent: i.priority === ctx.priorities.P0,
      priority: jump ? pName(i.priority) : null, starving: readyAt ? staleOf(readyAt, now, ctx.flow.queue.starvingDays) : false,
    };
  });
  return pullOrder(queued.map((x) => ({ ...x, p0: x.jump && x.urgent })), q.order ?? "ready") as Queued[];
}

/** Whether an Implementing issue waits for a release and so holds no slot (flow.js waitsRelease). */
export const waits = (ctx: Ctx, i: Issue) => waitsRelease(ctx.roleAt(i.state), i.name, i.labels, ctx.waitLabel);

/** `reserved`: it waits only because the free slots are kept for feature issues. */
export interface Outcome { outcome: "started" | "lost" | "waits"; message: string; reserved?: boolean }

/** Starts an issue: Implementing, if its lane has a slot. From a pull (`claim`), only while the issue
 * is still Ready, and only for the pull whose claim came first (flow.js claimWinner): a pull that lost
 * answers "lost" and leaves the issue to the other (PRONTO-341). `now` and `nonce` are injected: the
 * claim compares comments' times against the clock. */
export async function start(board: Board, ctx: Ctx, k: string, opts: { claim?: boolean; now: () => Date; nonce?: string }): Promise<Outcome> {
  const claim = opts.claim ?? false;
  const [issue, all] = await Promise.all([board.issue(k), board.issues(ctx.project, true)]);
  if (claim && ctx.roleAt(issue.state) !== "ready") return { outcome: "lost", message: `${k} is no longer Ready (${ctx.stateName(issue.state)}): another pull took it` };
  const l = ctx.laneOf(issue);
  const busy = all.filter((i) => ctx.roleAt(i.state) === "implementing" && !waits(ctx, i) && ctx.laneOf(i) === l).length;
  const featureBusy = all.filter((i) => ctx.roleAt(i.state) === "implementing" && !waits(ctx, i) && ctx.laneOf(i) === l && featureOf(i.labels, ctx.featureLabel)).length;
  const split = l === "engineer" ? { reserved: ctx.reserved, featureBusy, feature: featureOf(issue.labels, ctx.featureLabel) } : null;
  const may = mayStart(busy, ctx.slots[l], issue.priority, l, ctx.priorities.P0, split);
  if (!may.ok) return { outcome: "waits", message: `${k} waits: ${may.why}`, reserved: !!may.reserved };
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
  if (!(lane in ctx.slots) && lane !== "feature") throw new Error(`a lane is engineer, SRE, architect or feature, not ${lane}`);
  const queue = await readyQueue(board, ctx, await board.issues(ctx.project, true), opts.now(), lane);
  const lines: string[] = [];
  let full = false;
  let kept = false;
  for (const q of queue) {
    // Once the lane is full only a P0 may go on: it starts past the slots (flow.js mayStart).
    if ((full || (kept && !q.feature)) && !q.urgent) continue;
    const r = await start(board, ctx, q.key, { claim: true, ...opts });
    lines.push(r.message);
    if (r.outcome === "started") return { outcome: "started", lines };
    // A full lane stops it; one that only kept its reserved slots for features goes on to the next issue, a feature may fit.
    if (r.outcome === "waits" && r.reserved) { kept = true; continue; }
    if (r.outcome === "waits") full = true;
  }
  if (full || kept) return { outcome: "waits", lines };
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

export type ReadyStatus = {
  queue: Record<string, { key: string; title: string; age: string; readyAt: string | null; jump: boolean; priority: string | null; starving: boolean }[]>;
  starving: { key: string; age: string }[];
};
export type OpenStatus = { slots: Record<string, { of: number; on: string[] }>; featureLanes: { of: number; on: string[] }; waiting: { key: string; age: string }[]; issues: Record<string, string[]>; backlog: number };
export type Merged = {
  today: number;
  week: number;
  byDay: { day: string; count: number }[];
};
export type QueueStatus = ReadyStatus & OpenStatus & { merged: Merged };

/** What a history read answered, kept across runs: an issue's Ready time and merge time do not change
 * while its `updated_at` (Ready) or `completed_at` (merge) do not. */
export interface ReadCache {
  get(key: string): string | undefined;
  set(key: string, at: string): void;
  /** Writes what changed, keeping only the answers of the issues in `live` (their ids). */
  save(live: Set<string>): void;
}

/** When an issue merged: its first move into a completed state after its last move out of one (an
 * issue sent back and merged again merged at the second). The board's `completed_at` is not it: Plane
 * rewrites it when the issue is later made Done, moving a merge to the day of its flip. One read an
 * issue. Without moves, `completed_at`. */
async function mergedAt(board: Board, ctx: Ctx, i: Issue): Promise<string | null> {
  const completed = new Set(ctx.states.filter((s) => s.group === "completed").map((s) => s.id));
  const moves = board.stateMoves ? (await board.stateMoves(ctx.project, i.id)).map((m) => ({ ...m, t: Date.parse(m.at) })).filter((m) => Number.isFinite(m.t)).sort((a, b) => a.t - b.t) : [];
  const lastOut = moves.map((m, n) => (completed.has(m.to) ? -1 : n)).reduce((a, b) => Math.max(a, b), -1);
  const first = moves.slice(lastOut + 1).find((m) => completed.has(m.to));
  return first ? new Date(first.t).toISOString() : i.completed_at ?? null;
}

/** Merges within `queue.mergedDays`, by the day each issue merged, from the issues' `completed_at`
 * alone, which costs no call: it is the issue list's own field. It is the merge time for a Merged
 * issue, and for a Live or Done one it may be later (Plane rewrites it when the issue is released or
 * flipped), so a day before today may hold a release or a flip's issues, counted a day or days late.
 * Today is exact: a Live or Done issue completed today has its history read (one call each, few, and
 * once, in `cache`), since today's number is the one read. A read that fails fails the phase: a Plane
 * error is never hidden. */
export async function mergedStatus(board: Board, ctx: Ctx, all: Issue[], now: Date, opts: { cache?: ReadCache } = {}): Promise<Merged> {
  const days = ctx.flow.queue.mergedDays;
  const tz = ctx.flow.timeZone;
  const today = dayOf(now.getTime(), tz);
  const recent = all.filter((i) => ["merged", "live", "done"].includes(ctx.roleAt(i.state) ?? "") && (i.completed_at ? now.getTime() - Date.parse(i.completed_at) < days * DAY : false));
  const times = await pool(recent, 8, async (i): Promise<string | null> => {
    if (ctx.roleAt(i.state) === "merged") return i.completed_at ?? null;
    // An answer kept is used on any day, so a day once counted exactly stays so; the history is read on a miss for today alone.
    const k = `merged:${i.id}@${i.completed_at}`;
    const have = opts.cache?.get(k);
    if (have) return have;
    if (dayOf(Date.parse(i.completed_at!), tz) !== today) return i.completed_at ?? null;
    const at = await mergedAt(board, ctx, i);
    if (at) opts.cache?.set(k, at);
    return at;
  });
  return mergedByDay(times.filter((t): t is string => !!t), now, tz, days);
}

/** The Ready queue per lane and what starves. */
export async function readyStatus(board: Board, ctx: Ctx, all: Issue[], now: Date, cache?: ReadCache): Promise<ReadyStatus> {
  const queued = await readyQueue(board, ctx, all, now, undefined, cache);
  return {
    queue: Object.fromEntries([...Object.keys(ctx.slots), ...(ctx.reserved ? ["feature"] : [])].map((l) => [l, queued.filter((q) => (l === "feature" ? q.lane === "engineer" && q.feature : q.lane === l)).map((q) => ({ key: q.key, title: q.name, age: q.age, readyAt: q.readyAt, jump: q.jump, priority: q.priority, starving: q.starving }))])),
    starving: queued.filter((q) => q.starving).map((q) => ({ key: q.key, age: q.age })),
  };
}

/** The slots, the open issues by state and the Backlog's size: no board call. */
export function openStatus(ctx: Ctx, all: Issue[], now: Date = new Date()): OpenStatus {
  const busy = all.filter((i) => ctx.roleAt(i.state) === "implementing" && !waits(ctx, i));
  const byState = (roles: Role[]) => Object.fromEntries(ctx.flow.states
    .filter((s) => roles.includes(roleOf(ctx.flow.roles, s.name) as Role))
    .map((s) => [s.name, all.filter((i) => ctx.stateName(i.state) === s.name).map((i) => `${ctx.key(i)} ${i.name}`)])
    .filter(([, v]) => (v as string[]).length));
  return {
    slots: Object.fromEntries(Object.keys(ctx.slots).map((l) => [l, { of: ctx.slots[l], on: busy.filter((i) => ctx.laneOf(i) === l).map(ctx.key) }])),
    // The engineer slots kept for feature issues, and the feature issues in Implementing (in any engineer slot).
    featureLanes: { of: ctx.reserved, on: busy.filter((i) => ctx.laneOf(i) === "engineer" && featureOf(i.labels, ctx.featureLabel)).map(ctx.key) },
    waiting: all.filter((i) => waits(ctx, i)).map((i) => ({ key: ctx.key(i), age: ageOf(i.updated_at ?? "", now) })),
    issues: byState(["refine", "ready", "implementing", "review"]),
    backlog: all.filter((i) => ctx.roleAt(i.state) === "backlog").length,
  };
}

/** The slots line: `3 of 6 engineer slots busy (PRONTO-1, ...), 0 of 1 SRE slots busy, ...`. */
export const slotsLine = (s: OpenStatus) =>
  [
    ...Object.entries(s.slots).map(([l, v]) => `${v.on.length} of ${v.of} ${l} slots busy${v.on.length ? ` (${v.on.join(", ")})` : ""}`),
    ...(s.featureLanes.of ? [`feature lanes ${s.featureLanes.on.length} of ${s.featureLanes.of}${s.featureLanes.on.length ? ` (${s.featureLanes.on.join(", ")})` : ""}`] : []),
  ].join(", ");

/** The flip issues waiting for a release: `waiting for release: PRONTO-238 3d, PRONTO-228 3d`; none when none wait. */
export const waitingLine = (s: OpenStatus) => (s.waiting.length ? [`waiting for release: ${s.waiting.map((w) => `${w.key} ${w.age}`).join(", ")}`] : []);

/** Each lane's queue and what starves, easy to grep. */
export function readyLines(s: ReadyStatus, flow: DevFlow): string[] {
  const out: string[] = [];
  for (const [l, is] of Object.entries(s.queue)) {
    out.push(`  ready to pull, ${l}: ${is.length ? is.map((i) => `${i.key} ${i.title} (${i.jump ? `${i.priority} bug, ` : ""}${i.age})`).join("; ") : "none"}`);
  }
  if (s.starving.length) out.push(`starving: ${s.starving.map((q) => `${q.key} Ready ${q.age} (over ${flow.queue.starvingDays}d)`).join("; ")}`);
  return out;
}

export const mergedLine = (m: Merged, flow: DevFlow) =>
  `merged: ${m.today} today, ${m.week} in ${flow.queue.mergedDays} days${m.byDay.length ? ` (${m.byDay.map((d) => `${d.day} ${d.count}`).join(", ")})` : ""}; days before today by completed_at`;

export function openLines(s: OpenStatus, flow: DevFlow): string[] {
  const out: string[] = [];
  for (const [state, is] of Object.entries(s.issues)) if (state !== nameOf(flow.roles, "ready")) out.push(`  open, ${state}: ${is.join("; ")}`);
  out.push(`backlog: ${s.backlog}`);
  return out;
}

/** What status asks of its caller: the git and gh probes (a pull request's ci and auto-merge from its
 * address, null when it is not open or cannot be read; the newest commit on a branch naming a key), the
 * inbox's project, the clock, the cache kept between runs and where lines go. */
export interface StatusIO {
  now: () => Date;
  cache: ReadCache;
  inbox?: string;
  pr: (url: string) => Promise<{ ci: "pass" | "fail" | "pending"; auto: boolean } | null>;
  lastCommit: (key: string) => Promise<string | null>;
  print: (line: string) => void;
}

type Phase<T> = { ok: true; value: T } | { ok: false; error: string };

/** The whole status, the one function the verb prints. Lines go to `io.print` as each phase finishes,
 * in this order: the slots, each lane's queue, what starves, what is stuck, merges by day, the open
 * issues, the Backlog, the inbox. A phase that fails prints `<phase>: unavailable (<error>)`, counts in
 * `failures` and never keeps the others from running: a Plane error is never hidden. `json` is the same
 * data, a failed phase's part being `{unavailable}`. */
export async function status(board: Board, flow: DevFlow, project: string, io: StatusIO) {
  let failures = 0;
  const phase = async <T>(name: string, run: () => Promise<T>): Promise<Phase<T>> => {
    try {
      return { ok: true, value: await run() };
    } catch (e) {
      failures++;
      return { ok: false, error: `${name}: unavailable (${(e as Error).message})` };
    }
  };
  const bad = (r: { ok: false; error: string }) => ({ unavailable: r.error });
  const [all, ctx] = await Promise.all([board.issues(project, true), contextOf(board, flow, project)]);
  const now = io.now();
  const live = new Set(all.map((i) => i.id));
  const open = openStatus(ctx, all, now);
  io.print(slotsLine(open));
  for (const l of waitingLine(open)) io.print(l);
  const ready = await phase("ready to pull", () => readyStatus(board, ctx, all, now, io.cache));
  io.cache.save(live);
  for (const l of ready.ok ? readyLines(ready.value, flow) : [ready.error]) io.print(l);
  // Issues holding a slot (Implementing, or in Review) that no work is moving (flow.js stuckOf). A
  // board that cannot list an issue's links fails the phase: it is not "no pull request".
  // A flip waiting for its release holds no slot and no work moves it: it is not stuck.
  const held = all.filter((i) => ["implementing", "review"].includes(ctx.roleAt(i.state) ?? "") && !waits(ctx, i));
  const stuck = await phase("stuck", async () => (await Promise.all(held.map(async (i) => {
    let pr = null;
    for (const l of await board.links(project, i.id)) {
      if (!/\/pull\/\d+/.test(l.url)) continue;
      pr = await io.pr(l.url);
      if (pr) break;
    }
    const k = ctx.key(i);
    return stuckOf({ key: k, state: ctx.stateName(i.state), since: i.updated_at ?? "", pr, commit: pr ? null : await io.lastCommit(k) }, now, flow.stuckHours);
  }))).filter((s) => s !== null));
  for (const l of stuck.ok ? stuck.value.map(stuckLine) : [stuck.error]) io.print(l);
  const merged = await phase("merged", () => mergedStatus(board, ctx, all, now, { cache: io.cache }));
  io.cache.save(live);
  io.print(merged.ok ? mergedLine(merged.value, flow) : merged.error);
  for (const l of openLines(open, flow)) io.print(l);
  // The inbox's lines come last, so the lines above are what they were without one.
  const suggestions = await inboxStatus(board, flow, io.inbox, all.map((i) => i.name), now);
  if (suggestions) for (const l of suggestionLines(suggestions, flow)) io.print(l);
  return {
    failures,
    json: {
      slots: open.slots,
      featureLanes: open.featureLanes,
      waiting: open.waiting,
      queue: ready.ok ? ready.value.queue : bad(ready),
      starving: ready.ok ? ready.value.starving : bad(ready),
      merged: merged.ok ? merged.value : bad(merged),
      issues: open.issues,
      backlog: open.backlog,
      stuck: stuck.ok ? stuck.value : bad(stuck),
      ...(suggestions ? { suggestions } : {}),
    },
  };
}
