// The dev flow's rules (devflow/dev-flow.md), pure: which issue a pull request is, where an event
// moves an issue, an issue's flag, the agent cap. The hooks (hook.ts) and the intent (connect.ts)
// do the talking to the board; what they decide is decided here, and tested as CUE cases
// (tests/unit/devflow.cue). The rules reason in roles (backlog, refine, ready, implementing,
// review, merged, live, done, cancelled), never in a repository's names for its states: a caller
// maps a state's name to its role with roleOf and a role back to its name with nameOf, through
// the repository's `roles` (schema.cue).

/** The issue a pull request is for: the first `<ID>-<n>` in its title, else its branch (written
 * `<id>-<n>/<slug>`, lower case), as `<ID>-<n>`; null when neither names one. */
export function keyOf(identifier, ...texts) {
  const re = new RegExp(`(?:^|[^A-Za-z0-9])(${identifier})-(\\d+)(?![A-Za-z0-9])`, "i");
  for (const t of texts) {
    const m = re.exec(t ?? "");
    if (m) return `${identifier}-${Number(m[2])}`;
  }
  return null;
}

const order = ["backlog", "refine", "ready", "implementing", "review", "merged", "live", "done"];
const rank = (r) => order.indexOf(r);

/** The role a state plays in the repository's `roles` (role to the state's name), or null when
 * it plays none. */
export function roleOf(roles, name) {
  return Object.keys(roles ?? {}).find((r) => roles[r] === name) ?? null;
}

/** The name the repository gives a role's state. */
export function nameOf(roles, role) {
  const n = roles?.[role];
  if (!n) throw new Error(`no such role: ${role}`);
  return n;
}

/** Where an event moves an issue in role `state`, as a role, or null to leave it. `done` is when the issue ends (doneAt):
 * "flip" (its flag is on for everyone), "release" (released) or "merge" (merged); it only matters for
 * `merged` and `released`. An issue never moves back past
 * where it is, but for the two ways back the flow names: a pull request closed unmerged (back to
 * Implementing) and a flip rolled back (back to Live). A cancelled issue is never moved. */
export function moveFor(event, state, done = "flip") {
  if (state === "cancelled" || rank(state) < 0) return null;
  const forward = (to) => (rank(state) < rank(to) ? to : null);
  switch (event) {
    case "opened":
    case "reopened":
    case "ready_for_review":
      return forward("review");
    case "merged":
      return forward(done === "merge" ? "done" : "merged");
    case "closed":
      return state === "review" ? "implementing" : null;
    case "released":
      if (done === "release") return state === "merged" || state === "live" ? "done" : null;
      return state === "merged" ? "live" : null;
    // A flip that reached everyone. An app released outside release-cron never says "released", so
    // Merged goes straight to Done.
    case "flipped":
      return state === "merged" || state === "live" ? "done" : null;
    case "rolledback":
      return state === "done" ? "live" : null;
    default:
      throw new Error(`no such event: ${event}`);
  }
}

/** The flag an issue names, on its own `Flag: <name>` line, in its description (HTML or text);
 * null when it names none. */
export function flagOf(description) {
  const text = String(description ?? "").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|h[1-6])>/gi, "\n").replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ");
  const m = /^\s*Flag:\s*`?([A-Za-z0-9_.-]+)`?\s*$/m.exec(text);
  return m ? m[1] : null;
}

/** When an issue is Done. With a flag: when the flag is on for everyone ("flip"). Without one: an infra
 * issue or a plugins issue (its modules among `infra` and `plugins`: nothing a player sees, nothing
 * released by release-cron) when it merges ("merge"); any other (a bug fix) when it is released
 * ("release"). */
export function doneAt(flag, modules, infra, plugins = ["plugins"]) {
  if (flag) return "flip";
  const own = [...(infra ?? []), ...plugins];
  return (modules ?? []).some((m) => own.includes(m)) ? "merge" : "release";
}

/** Whose slot an issue takes: an SRE's when one of its modules is an infra module, else an
 * engineer's. */
export function laneOf(modules, infra) {
  return (modules ?? []).some((m) => (infra ?? []).includes(m)) ? "SRE" : "engineer";
}

/** Whether an issue may start (move to Implementing): its lane has `slots`, the lane's issues already
 * Implementing take one each, and an urgent one (P0, `urgent` in the board's own word) starts
 * regardless. */
export function mayStart(busy, slots, priority, lane, urgent = "urgent") {
  if (priority === urgent) return { ok: true, why: "P0: starts past the slots" };
  if (slots === 0) return { ok: false, why: `the team has no ${lane}` };
  return busy < slots
    ? { ok: true, why: `${lane} slot ${busy + 1} of ${slots}` }
    : { ok: false, why: `all ${slots} ${lane} slots are busy` };
}

/** What a sprint may commit to, by lane: `perPerson` issues for each engineer and each SRE. */
export function capacity(team, perPerson) {
  return { engineer: (team?.engineers ?? 0) * perPerson, SRE: (team?.sre ?? 0) * perPerson };
}

/** Whether a lane may plan `add` more issues when `planned` are in the sprint already, of `cap`. */
export function mayPlan(planned, cap, add, lane) {
  if (add <= 0) return { ok: true, why: `${lane}: nothing to add` };
  if (cap === 0) return { ok: false, why: `the team has no ${lane}` };
  const room = Math.max(0, cap - planned);
  return add <= room
    ? { ok: true, why: `${lane}: ${planned + add} of ${cap} planned` }
    : { ok: false, why: `${lane}: ${planned} of ${cap} planned, ${add} more is ${add - room} over` };
}

/** The next Ready issue a lane pulls: the sprint's Ready issues of that lane, most urgent first
 * (`order`: the board's priorities from P0 down, then none), then the oldest. `issues` are
 * `{key, sequence, priority}`. */
export function pullNext(issues, order = ["urgent", "high", "medium", "low", "none"]) {
  const rank = (p) => (order.includes(p) ? order.indexOf(p) : order.length);
  const sorted = [...issues].sort((a, b) => rank(a.priority) - rank(b.priority) || a.sequence - b.sequence);
  return sorted[0] ?? null;
}

/** P0..P3 as the board's priority, in `priorities` (P to the board's word; Plane's by default). */
/** @type {Record<string, string>} */
const plane = { P0: "urgent", P1: "high", P2: "medium", P3: "low" };
export function priorityOf(p, priorities = plane) {
  const v = priorities[String(p).toUpperCase()];
  if (!v) throw new Error(`a priority is P0, P1, P2 or P3, not ${p}`);
  return v;
}

/** Where a new bug goes by its priority (rule 6), as a role: P0 starts now, P1 joins the current
 * sprint, P2 and P3 wait in the Backlog for a coming sprint. */
export function bugPlace(p, priorities = plane) {
  priorityOf(p, priorities);
  const n = String(p).toUpperCase();
  return n === "P0" ? { role: "implementing", sprint: true } : n === "P1" ? { role: "refine", sprint: true } : { role: "backlog", sprint: false };
}

/** A sprint is a Plane cycle named `Sprint <n>: <theme>`. Its number, or null for another cycle. */
export function sprintNumber(name) {
  const m = /^Sprint (\d+)(?::|$)/.exec(name ?? "");
  return m ? Number(m[1]) : null;
}

/** A sprint's cycle name: its number and, when there is one, its theme. */
export function sprintName(n, theme) {
  return theme ? `Sprint ${n}: ${theme}` : `Sprint ${n}`;
}

/** Where the endless loop stands (the owner, 2026-11-10: "the eternal loop sprint"). `sprints` are
 * `{n, groups}`, `groups` the Plane state group of each issue in it. A sprint is finished when it has
 * issues and each is completed (merged or past) or cancelled: it ends when its work is done, not at
 * an hour. The current sprint is the oldest one still open, the next the one after it; there are at
 * most these two, and a sprint planned now goes into the next (made when absent, numbered after the
 * last). A sprint with no issues is neither open nor finished. */
export function loopOf(sprints) {
  const sorted = [...sprints].sort((a, b) => a.n - b.n);
  const done = (g) => g === "completed" || g === "cancelled";
  const open = sorted.filter((s) => s.groups.length && !s.groups.every(done)).map((s) => s.n);
  const finished = sorted.filter((s) => s.groups.length && s.groups.every(done)).map((s) => s.n);
  const number = sorted.length ? sorted[sorted.length - 1].n + 1 : 1;
  return { current: open[0] ?? null, next: open[1] ?? null, finished, number, plansInto: open[1] ?? number };
}

/** The day a moment falls on in `timeZone`, YYYY-MM-DD: a cycle's dates. */
export function dayOf(at, timeZone) {
  const t = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(at)).reduce((o, p) => ({ ...o, [p.type]: p.value }), {});
  return `${t.year}-${t.month}-${t.day}`;
}

/** What a pull request event from GitHub is to the flow: merged is a closed event that merged. */
export function prEvent(action, merged) {
  if (action === "closed") return merged ? "merged" : "closed";
  return ["opened", "reopened", "ready_for_review"].includes(action) ? action : null;
}

/** What to do about a pull request without an issue key: a chore passes, anything else fails
 * the check (rule 3: no work reaches main without an issue), or only warns while `warn`. */
export function missingKey(labels, chore, warn, identifier) {
  if (labels.includes(chore)) return { ok: true, say: `labelled ${chore}: no issue needed` };
  const say = `this pull request names no issue: put its key (${identifier}-123) in the title, or label it ${chore}`;
  return { ok: warn, say: warn ? `warning: ${say}` : say };
}
