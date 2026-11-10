// The board as the skills use it (skills/pronto-sprint-plan, pronto-issue, pronto-bug): each verb one
// step of the flow, its rule decided in flow.js, so a session never moves an issue by hand.
// Sprints run in an endless loop (flow.js loopOf): the current one, and the next that idle lanes
// already pull from; a sprint ends when all its issues merge.
//   board.ts status <repo> [--json]                     the loop: the current and next sprints' issues by state, the slots busy, what is designed
//   board.ts start <repo> <KEY>                         Implementing, if its lane (engineer or SRE) has a slot (a P0 always)
//   board.ts pull <repo> [--lane engineer|SRE]          start the lane's next Ready issue: the current sprint's, else the next sprint's
//   board.ts move <repo> <KEY> <State> [--why <text>]   Refine, Ready, Backlog (out of its sprint) or Cancelled (the others are the hooks')
//   board.ts file <repo> --title <t> --app <app> [--bug] [--priority P0..P3] [--flag <f>] [--body <text>]
//   board.ts close <repo> [<n>] [--json]                a finished sprint's report (the last finished by default)
//   board.ts next <repo> [--theme <t>] <KEY...>          plan into the next sprint (made when absent), in Refine; refuses past a lane's capacity
import { flagsOf } from "../intents/shell.ts";
import { bugPlace, capacity, dayOf, laneOf, loopOf, mayPlan, mayStart, priorityOf, pullNext, sprintName, sprintNumber } from "./flow.js";
import { esc, type Issue, Plane } from "./plane.ts";
import { boardOf, devflowOf, type DevFlow } from "./spec.ts";

const [verb, repoArg, ...rest] = Deno.args;
const repo = repoArg ? await Deno.realPath(repoArg) : "";
const flow = repo ? await devflowOf(repo) : null;
if (!verb || !flow) {
  console.error(flow === null && repo ? `${repo} has no devflow/devflow.cue` : "usage: board.ts status|start|pull|move|file|close|next <repo> ...");
  Deno.exit(2);
}
const b = await boardOf(flow);
if (!b) {
  console.error("no board token: PLANE_TOKEN, or Secret Manager's (bin/pronto connect plane says how)");
  Deno.exit(2);
}
const { plane, project } = b as { plane: Plane; project: string };
const id = flow.plane.project.identifier;
const key = (i: Issue) => `${id}-${i.sequence_id}`;

const states = await plane.states(project);
const stateId = (n: string) => states.find((s) => s.name === n)?.id ?? (() => { throw new Error(`no state ${n}: run bin/pronto connect plane`); })();
const stateName = (sid: string) => states.find((s) => s.id === sid)?.name ?? "?";
const groupOf = (sid: string) => states.find((s) => s.id === sid)?.group ?? "";
const say = async (i: Issue, html: string) => void (await plane.comment(project, i.id, html));

/** The lanes that build: an engineer's slots and an SRE's (devFlow.team), and which an issue takes. */
const slots = { engineer: flow.team.engineers, SRE: flow.team.sre } as Record<string, number>;
const cap = capacity(flow.team, flow.sprint.perPerson) as Record<string, number>;
const modulesOf = await plane.modulesByIssue(project);
const lane = (i: Issue) => laneOf(modulesOf.get(i.id) ?? [], flow.infra);

/** The sprints on the board (cycles named `Sprint <n>...`), each with its issues, and where the loop
 * stands: the current sprint, the next, the finished, and the number a new one takes. */
async function sprints() {
  const cycles = (await plane.cycles(project)).flatMap((c) => {
    const n = sprintNumber(c.name);
    return n == null ? [] : [{ n, cycle: c }];
  });
  const all = await Promise.all(cycles.map(async (s) => ({ ...s, issues: await plane.cycleIssues(project, s.cycle.id) })));
  const loop = loopOf(all.map((s) => ({ n: s.n, groups: s.issues.map((i) => groupOf(i.state)) })));
  const byN = (n: number | null) => (n == null ? null : all.find((s) => s.n === n) ?? null);
  return { loop, all, current: byN(loop.current), next: byN(loop.next), byN };
}
type Sprint = NonNullable<Awaited<ReturnType<typeof sprints>>["current"]>;
/** The sprint numbered `n`, made (named with `theme`) when absent. */
async function sprintCycle(n: number, theme: string) {
  const s = await sprints();
  const found = s.byN(n);
  if (found) return found.cycle;
  const day = dayOf(new Date(), flow!.sprint.timeZone);
  return await plane.createCycle(project, sprintName(n, theme), day, day, (await plane.me()).id);
}
const titleOf = (s: Sprint | null) => (s ? s.cycle.name : "none");

async function status() {
  const all = await plane.issues(project);
  const { loop, current, next } = await sprints();
  const inOpen = new Set([...(current?.issues ?? []), ...(next?.issues ?? [])].map((i) => i.id));
  const now = (sp: Sprint | null) => sp ? all.filter((i) => sp.issues.some((j) => j.id === i.id)) : [];
  const cur = now(current), nxt = now(next);
  const busy = all.filter((i) => stateName(i.state) === "Implementing");
  const byState = (is: Issue[]) => Object.fromEntries(flow!.states.map((s) => [s.name, is.filter((i) => stateName(i.state) === s.name).map((i) => `${key(i)} ${i.name}`)]).filter(([, v]) => v.length));
  // What a lane still has to start in the current sprint (Ready or Refine): none, and the lane pulls
  // from the next sprint; no next sprint, and the lead plans it now (skills/pronto-sprint-plan).
  const toStart = (is: Issue[], l: string) => is.filter((i) => lane(i) === l && ["Ready", "Refine"].includes(stateName(i.state))).length;
  const dry = Object.keys(slots).filter((l) => slots[l] > 0 && toStart(cur, l) === 0);
  const planning = next ? nxt : current ? [] : cur;
  const out = {
    current: titleOf(current),
    next: titleOf(next),
    finished: loop.finished.length ? `Sprint ${Math.max(...loop.finished)}` : "none",
    slots: Object.fromEntries(Object.entries(slots).map(([l, of]) => [l, { of, on: busy.filter((i) => lane(i) === l).map(key) }])),
    // The sprint being planned (the next) against capacity, by lane (a cancelled issue is not planned).
    capacity: Object.fromEntries(Object.keys(slots).map((l) => [l, { planned: planning.filter((i) => lane(i) === l && stateName(i.state) !== "Cancelled").length, of: cap[l] }])),
    // The Ready issues each lane pulls, in the order it pulls them: the current sprint's, then the next's.
    ready: Object.fromEntries(Object.keys(slots).map((l) => [l, [...cur, ...nxt].filter((i) => lane(i) === l && stateName(i.state) === "Ready").map((i) => `${key(i)} ${i.name}`)])),
    // The lanes with nothing left to start in the current sprint: they work the next one.
    dry,
    // Plan the next sprint now: a lane ran dry and there is no next sprint to pull from.
    plan: !next && (dry.length > 0 || !current),
    issues: { current: byState(cur), next: byState(nxt) },
    // The product managers' work: issues designed (Ready) that no open sprint holds yet.
    designed: all.filter((i) => stateName(i.state) === "Ready" && !inOpen.has(i.id)).map((i) => `${key(i)} ${i.name}`),
    backlog: all.filter((i) => stateName(i.state) === "Backlog").length,
  };
  if (rest.includes("--json")) return console.log(JSON.stringify(out, null, 2));
  const lanes = Object.entries(out.slots).map(([l, s]) => `${s.on.length} of ${s.of} ${l} slots busy${s.on.length ? ` (${s.on.join(", ")})` : ""}`);
  console.log(`current ${out.current}; next ${out.next}; last finished ${out.finished}`);
  console.log(lanes.join(", "));
  console.log(`planning ${next ? out.next : current ? "a new next sprint" : "a new sprint"}: ${Object.entries(out.capacity).map(([l, c]) => `${c.planned} of ${c.of} ${l}`).join(", ")} (${flow!.sprint.perPerson} per person)`);
  for (const [l, is] of Object.entries(out.ready)) console.log(`  ready to pull, ${l}: ${is.length ? is.join("; ") : "none"}`);
  if (dry.length) console.log(`  nothing left to start in the current sprint: ${dry.join(", ")}`);
  for (const [which, by] of Object.entries(out.issues)) for (const [s, is] of Object.entries(by)) console.log(`  ${which}, ${s}: ${(is as string[]).join("; ")}`);
  console.log(`designed for a coming sprint: ${out.designed.length ? out.designed.join("; ") : "none"}`);
  console.log(`backlog: ${out.backlog}`);
  if (out.plan) console.log("plan the next sprint now (pronto-sprint-plan)");
}

async function start(k: string) {
  const issue = await plane.issue(k);
  const l = lane(issue);
  const busy = (await plane.issues(project)).filter((i) => stateName(i.state) === "Implementing" && lane(i) === l).length;
  const may = mayStart(busy, slots[l], issue.priority, l);
  if (!may.ok) {
    console.log(`${k} waits: ${may.why}`);
    Deno.exit(1);
  }
  const from = stateName(issue.state);
  await plane.updateIssue(project, issue.id, { state: stateId("Implementing") });
  await say(issue, `<p>${esc(from)} → Implementing: ${esc(may.why)}</p>`);
  console.log(`${k} ${from} → Implementing (${may.why})`);
}

/** The lane's next Ready issue, started: the current sprint's, else the next sprint's (an engineer is
 * never idle: with nothing left in the current sprint it starts the next). What a session does when
 * its pull request opens (review holds no slot), or when it finishes an issue. */
async function pull(l: string) {
  if (!(l in slots)) throw new Error(`a lane is engineer or SRE, not ${l}`);
  const { current, next } = await sprints();
  const all = await plane.issues(project);
  for (const sp of [current, next]) {
    if (!sp) continue;
    const ids = new Set(sp.issues.map((i) => i.id));
    const ready = all.filter((i) => ids.has(i.id) && stateName(i.state) === "Ready" && lane(i) === l);
    const pick = pullNext(ready.map((i) => ({ key: key(i), sequence: i.sequence_id, priority: i.priority })));
    if (pick) {
      console.log(`from ${sp.cycle.name}`);
      return await start(pick.key);
    }
  }
  console.log(`nothing Ready for ${l} in ${titleOf(current)} or ${titleOf(next)}${next ? "" : ": no next sprint yet, the lead plans it now"}`);
}

async function move(k: string, to: string, why: string) {
  if (!["Refine", "Ready", "Cancelled", "Backlog"].includes(to)) throw new Error(`${to} is the hooks' to set (a pull request, a release, a flip)`);
  const issue = await plane.issue(k);
  const from = stateName(issue.state);
  await plane.updateIssue(project, issue.id, { state: stateId(to) });
  // Back to the Backlog is out of its sprint (parked: it waits on the owner), so the sprint can end.
  if (to === "Backlog") {
    const { current, next } = await sprints();
    for (const sp of [current, next]) if (sp?.issues.some((i) => i.id === issue.id)) await plane.removeFromCycle(project, sp.cycle.id, issue.id);
  }
  await say(issue, `<p>${esc(from)} → ${esc(to)}${why ? `: ${esc(why)}` : ""}</p>`);
  console.log(`${k} ${from} → ${to}`);
}

async function file() {
  const f = flagsOf(rest);
  if (!f.title || !f.app) throw new Error("file needs --title and --app (an app under apps/, or plugins)");
  const bug = f.bug === "true";
  const priority = f.priority ? priorityOf(f.priority) : bug ? "medium" : "none";
  const place = bug ? bugPlace(f.priority ?? "P2") : { state: "Backlog", sprint: false };
  const body = [f.body ? `<p>${esc(f.body).replace(/\n/g, "<br>")}</p>` : "", f.flag ? `<p>Flag: ${esc(f.flag)}</p>` : ""].join("");
  const labels = bug ? [await labelId("bug", "#ef4444")] : [];
  const made = await plane.createIssue(project, { name: f.title, description_html: body || "<p></p>", priority, state: stateId(place.state), labels });
  const mod = (await plane.modules(project)).find((m) => m.name === f.app);
  if (mod) await plane.addToModule(project, mod.id, [made.id]);
  // A P0 or P1 joins the current sprint; with none open, it starts one.
  let into = "";
  if (place.sprint) {
    const { loop, current } = await sprints();
    const cycle = current ? current.cycle : await sprintCycle(loop.number, "");
    await plane.addToCycle(project, cycle.id, [made.id]);
    into = cycle.name;
  }
  console.log(`${key(made)} filed in ${place.state}${into ? `, in ${into}` : ""}${mod ? `, module ${f.app}` : ` (no module ${f.app})`}`);
}

async function labelId(name: string, color: string) {
  const l = (await plane.labels(project)).find((x) => x.name === name);
  return l ? l.id : (await plane.createLabel(project, name, color)).id;
}

/** A finished sprint's report: what merged, went Live, is Done, was cancelled. The last finished by
 * default. A sprint is finished when all its issues are; nothing slips, so there is nothing to move. */
async function close(n?: number) {
  const { loop, byN } = await sprints();
  const which = n ?? (loop.finished.length ? Math.max(...loop.finished) : null);
  const sp = byN(which);
  if (!sp) return console.log(which == null ? "no sprint has finished" : `no Sprint ${which}`);
  if (!loop.finished.includes(sp.n)) return console.log(`${sp.cycle.name} is still open`);
  const by = (st: string) => sp.issues.filter((i) => stateName(i.state) === st).map((i) => `${key(i)} ${i.name}`);
  const report = { sprint: sp.cycle.name, merged: by("Merged"), live: by("Live"), done: by("Done"), cancelled: by("Cancelled") };
  if (rest.includes("--json")) return console.log(JSON.stringify(report, null, 2));
  console.log(`${sp.cycle.name}: ${report.merged.length + report.live.length + report.done.length} of ${sp.issues.length} merged`);
  for (const [k, v] of Object.entries(report)) if (Array.isArray(v) && v.length) console.log(`  ${k}: ${v.join("; ")}`);
}

/** Plan issues into the next sprint, made (named for `theme`) when absent: the sprint the idle lanes
 * pull from. With no sprint open at all, the new one is the current. In Refine from the Backlog. */
async function next(theme: string, keys: string[]) {
  const { loop, byN } = await sprints();
  const n = loop.plansInto;
  const held = byN(n)?.issues ?? [];
  // Capacity first, so a refused plan changes nothing: the sprint's issues already planned, by
  // lane, plus the new ones, against perPerson for each engineer and SRE.
  const heldIds = new Set(held.map((i) => i.id));
  const fresh = (await Promise.all(keys.map((k) => plane.issue(k)))).filter((i, x, all) => !heldIds.has(i.id) && all.findIndex((j) => j.id === i.id) === x);
  const refused: string[] = [];
  for (const l of Object.keys(slots)) {
    const planned = held.filter((i) => lane(i) === l && stateName(i.state) !== "Cancelled").length;
    const may = mayPlan(planned, cap[l], fresh.filter((i) => lane(i) === l).length, l);
    if (!may.ok) refused.push(may.why);
  }
  if (refused.length) {
    console.log(`Sprint ${n} is over capacity (${flow!.sprint.perPerson} per person): ${refused.join("; ")}`);
    Deno.exit(1);
  }
  if (!fresh.length) return console.log(`nothing new for Sprint ${n}`);
  const cycle = await sprintCycle(n, theme);
  for (const i of fresh) if (stateName(i.state) === "Backlog") await plane.updateIssue(project, i.id, { state: stateId("Refine") });
  await plane.addToCycle(project, cycle.id, fresh.map((i) => i.id));
  console.log(`${cycle.name} (${n === loop.current || loop.current == null ? "current" : `next, after Sprint ${loop.current}`}): ${fresh.map(key).join(", ")}`);
}

switch (verb) {
  case "status": await status(); break;
  case "start": await start(rest[0]); break;
  case "pull": await pull(flagsOf(rest).lane ?? "engineer"); break;
  case "move": await move(rest[0], rest[1], flagsOf(rest.slice(2)).why ?? ""); break;
  case "file": await file(); break;
  case "close": await close(rest[0] && /^\d+$/.test(rest[0]) ? Number(rest[0]) : undefined); break;
  case "next": {
    const t = rest.indexOf("--theme");
    const theme = t >= 0 ? rest[t + 1] ?? "" : "";
    await next(theme, rest.filter((_, x) => t < 0 || (x !== t && x !== t + 1)));
    break;
  }
  default: console.error(`no verb ${verb}`); Deno.exit(2);
}
