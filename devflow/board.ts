// The board as the skills use it (skills/pronto-sprint-plan, pronto-issue, pronto-bug): each verb one
// step of the flow, its rule decided in flow.js, so a session never moves an issue by hand.
//   board.ts status <repo> [--json]                     today's sprint: its issues by state, the slots busy, what is designed
//   board.ts start <repo> <KEY>                         Implementing, if its lane (engineer or SRE) has a slot (a P0 always)
//   board.ts pull <repo> [--lane engineer|SRE]          start the next Ready issue of the sprint for that lane (engineer by default)
//   board.ts move <repo> <KEY> <State> [--why <text>]   Refine, Ready or Cancelled (the others are the hooks')
//   board.ts file <repo> --title <t> --app <app> [--bug] [--priority P0..P3] [--flag <f>] [--body <text>]
//   board.ts close <repo> [--json]                      the sprint that ended: what merged, went live, is done, slipped
//   board.ts next <repo> <KEY...>                        the next sprint, with these issues in Refine; refuses past a lane's capacity
import { flagsOf } from "../intents/shell.ts";
import { bugPlace, capacity, laneOf, mayPlan, mayStart, nextDay, priorityOf, pullNext, sprintOf } from "./flow.js";
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

/** The cycle for a day, made when absent. */
async function cycleOf(day: string, make: boolean) {
  const found = (await plane.cycles(project)).find((c) => c.name === day);
  if (found || !make) return found ?? null;
  return await plane.createCycle(project, day, day, day, (await plane.me()).id);
}
const today = () => sprintOf(new Date(), flow!.sprint.ends, flow!.sprint.timeZone);
/** The sprint that ended last: the one before today's. */
const yesterday = () => {
  const d = new Date(`${today()}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
};

async function status() {
  const all = await plane.issues(project);
  const day = today();
  const cycle = await cycleOf(day, false);
  const inCycle = cycle ? new Set((await plane.cycleIssues(project, cycle.id)).map((i) => i.id)) : new Set<string>();
  const sprint = all.filter((i) => inCycle.has(i.id));
  const busy = all.filter((i) => stateName(i.state) === "Implementing");
  const out = {
    sprint: day,
    ends: `${flow!.sprint.ends} ${flow!.sprint.timeZone}`,
    slots: Object.fromEntries(Object.entries(slots).map(([l, of]) => [l, { of, on: busy.filter((i) => lane(i) === l).map(key) }])),
    // Planned against capacity, by lane (a cancelled issue is not planned), and the Ready issues
    // waiting for their lane to pull them.
    capacity: Object.fromEntries(Object.keys(slots).map((l) => [l, { planned: sprint.filter((i) => lane(i) === l && stateName(i.state) !== "Cancelled").length, of: cap[l] }])),
    ready: Object.fromEntries(Object.keys(slots).map((l) => [l, sprint.filter((i) => lane(i) === l && stateName(i.state) === "Ready").map((i) => `${key(i)} ${i.name}`)])),
    issues: Object.fromEntries(flow!.states.map((s) => [s.name, sprint.filter((i) => stateName(i.state) === s.name).map((i) => `${key(i)} ${i.name}`)]).filter(([, v]) => v.length)),
    // The product managers' work: issues designed (Ready) that no sprint holds yet.
    designed: all.filter((i) => stateName(i.state) === "Ready" && !inCycle.has(i.id)).map((i) => `${key(i)} ${i.name}`),
    backlog: all.filter((i) => stateName(i.state) === "Backlog").length,
  };
  if (rest.includes("--json")) return console.log(JSON.stringify(out, null, 2));
  const lanes = Object.entries(out.slots).map(([l, s]) => `${s.on.length} of ${s.of} ${l} slots busy${s.on.length ? ` (${s.on.join(", ")})` : ""}`);
  console.log(`sprint ${out.sprint} (ends ${out.ends}): ${lanes.join(", ")}`);
  console.log(`planned: ${Object.entries(out.capacity).map(([l, c]) => `${c.planned} of ${c.of} ${l}`).join(", ")} (${flow!.sprint.perPerson} per person)`);
  for (const [l, is] of Object.entries(out.ready)) console.log(`  ready to pull, ${l}: ${is.length ? is.join("; ") : "none"}`);
  for (const [s, is] of Object.entries(out.issues)) console.log(`  ${s}: ${(is as string[]).join("; ")}`);
  console.log(`designed for a later sprint: ${out.designed.length ? out.designed.join("; ") : "none"}`);
  console.log(`backlog: ${out.backlog}`);
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

/** The next Ready issue of the sprint for a lane, started: what a session does when its pull
 * request opens (review holds no slot), or when it finishes an issue. */
async function pull(l: string) {
  if (!(l in slots)) throw new Error(`a lane is engineer or SRE, not ${l}`);
  const cycle = await cycleOf(today(), false);
  const inSprint = cycle ? new Set((await plane.cycleIssues(project, cycle.id)).map((i) => i.id)) : new Set<string>();
  const ready = (await plane.issues(project)).filter((i) => inSprint.has(i.id) && stateName(i.state) === "Ready" && lane(i) === l);
  const pick = pullNext(ready.map((i) => ({ key: key(i), sequence: i.sequence_id, priority: i.priority })));
  if (!pick) {
    console.log(`nothing Ready in sprint ${today()} for ${l}`);
    return;
  }
  await start(pick.key);
}

async function move(k: string, to: string, why: string) {
  if (!["Refine", "Ready", "Cancelled", "Backlog"].includes(to)) throw new Error(`${to} is the hooks' to set (a pull request, a release, a flip)`);
  const issue = await plane.issue(k);
  const from = stateName(issue.state);
  await plane.updateIssue(project, issue.id, { state: stateId(to) });
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
  if (place.sprint) await plane.addToCycle(project, (await cycleOf(today(), true))!.id, [made.id]);
  console.log(`${key(made)} filed in ${place.state}${place.sprint ? `, in sprint ${today()}` : ""}${mod ? `, module ${f.app}` : ` (no module ${f.app})`}`);
}

async function labelId(name: string, color: string) {
  const l = (await plane.labels(project)).find((x) => x.name === name);
  return l ? l.id : (await plane.createLabel(project, name, color)).id;
}

async function close() {
  const day = yesterday();
  const cycle = await cycleOf(day, false);
  if (!cycle) return console.log(`no sprint ${day} to close`);
  const issues = await plane.cycleIssues(project, cycle.id);
  const by = (n: string) => issues.filter((i) => stateName(i.state) === n).map((i) => `${key(i)} ${i.name}`);
  const slipped = issues.filter((i) => !["completed", "cancelled"].includes(groupOf(i.state)));
  for (const i of slipped) {
    const from = stateName(i.state);
    // Work in progress keeps its state (a session is on it), and so does a designed one (Ready),
    // which waits for a later planning; one still being refined goes back to the Backlog.
    if (from === "Refine") await plane.updateIssue(project, i.id, { state: stateId("Backlog") });
    await plane.removeFromCycle(project, cycle.id, i.id);
    await say(i, `<p>Sprint ${esc(day)} ended with it ${esc(from)}: out of the sprint${from === "Refine" ? ", back to the Backlog" : ""}.</p>`);
  }
  const report = { sprint: day, merged: by("Merged"), live: by("Live"), done: by("Done"), slipped: slipped.map((i) => `${key(i)} ${i.name} (${stateName(i.state)})`) };
  if (rest.includes("--json")) return console.log(JSON.stringify(report, null, 2));
  console.log(`sprint ${day}: ${report.merged.length + report.live.length + report.done.length} of ${issues.length} merged`);
  for (const [k, v] of Object.entries(report)) if (Array.isArray(v) && v.length) console.log(`  ${k}: ${v.join("; ")}`);
}

async function next(keys: string[]) {
  const day = today();
  // Capacity first, so a refused plan changes nothing: the sprint's issues already planned, by
  // lane, plus the new ones, against perPerson for each engineer and SRE.
  const present = await cycleOf(day, false);
  const held = present ? await plane.cycleIssues(project, present.id) : [];
  const heldIds = new Set(held.map((i) => i.id));
  const fresh = (await Promise.all(keys.map((k) => plane.issue(k)))).filter((i, n, all) => !heldIds.has(i.id) && all.findIndex((j) => j.id === i.id) === n);
  const refused: string[] = [];
  for (const l of Object.keys(slots)) {
    const planned = held.filter((i) => lane(i) === l && stateName(i.state) !== "Cancelled").length;
    const may = mayPlan(planned, cap[l], fresh.filter((i) => lane(i) === l).length, l);
    if (!may.ok) refused.push(may.why);
  }
  if (refused.length) {
    console.log(`sprint ${day} is over capacity (${flow!.sprint.perPerson} per person): ${refused.join("; ")}`);
    Deno.exit(1);
  }
  const cycle = (await cycleOf(day, true))!;
  const ids: string[] = [];
  for (const k of keys) {
    const i = await plane.issue(k);
    ids.push(i.id);
    if (stateName(i.state) === "Backlog") await plane.updateIssue(project, i.id, { state: stateId("Refine") });
  }
  if (ids.length) await plane.addToCycle(project, cycle.id, ids);
  console.log(`sprint ${day} (ends ${flow!.sprint.ends}, then ${nextDay(day)}'s): ${keys.join(", ") || "no issues"}`);
}

switch (verb) {
  case "status": await status(); break;
  case "start": await start(rest[0]); break;
  case "pull": await pull(flagsOf(rest).lane ?? "engineer"); break;
  case "move": await move(rest[0], rest[1], flagsOf(rest.slice(2)).why ?? ""); break;
  case "file": await file(); break;
  case "close": await close(); break;
  case "next": await next(rest); break;
  default: console.error(`no verb ${verb}`); Deno.exit(2);
}
