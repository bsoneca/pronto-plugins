// The dev flow's rules (bsoneca/pronto's docs/dev-flow.md), pure: which issue a pull request is, where
// an event moves an issue, an issue's flag, the agent cap. The hooks (hook.ts) and the intent
// (connect.ts) do the talking to Plane; what they decide is decided here, and tested as CUE cases
// (tests/unit/devflow.cue).

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

const order = ["Backlog", "Refine", "Ready", "Implementing", "Review", "Merged", "Live", "Done"];
const rank = (s) => order.indexOf(s);

/** Where an event moves an issue in `state`, or null to leave it. `done` is when the issue ends (doneAt):
 * "flip" (its flag is on for everyone), "release" (released) or "merge" (merged); it only matters for
 * `merged` and `released`. An issue never moves back past
 * where it is, but for the two ways back the flow names: a pull request closed unmerged (back to
 * Implementing) and a flip rolled back (back to Live). A cancelled issue is never moved. */
export function moveFor(event, state, done = "flip") {
  if (state === "Cancelled" || rank(state) < 0) return null;
  const forward = (to) => (rank(state) < rank(to) ? to : null);
  switch (event) {
    case "opened":
    case "reopened":
    case "ready_for_review":
      return forward("Review");
    case "merged":
      return forward(done === "merge" ? "Done" : "Merged");
    case "closed":
      return state === "Review" ? "Implementing" : null;
    case "released":
      if (done === "release") return state === "Merged" || state === "Live" ? "Done" : null;
      return state === "Merged" ? "Live" : null;
    // A flip that reached everyone. An app released outside release-cron never says "released", so
    // Merged goes straight to Done.
    case "flipped":
      return state === "Merged" || state === "Live" ? "Done" : null;
    case "rolledback":
      return state === "Done" ? "Live" : null;
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
 * Implementing take one each, and an urgent one (P0) starts regardless. */
export function mayStart(busy, slots, priority, lane) {
  if (priority === "urgent") return { ok: true, why: "P0: starts past the slots" };
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
 * (Plane's urgent, high, medium, low, none), then the oldest. `issues` are `{key, sequence, priority}`. */
export function pullNext(issues) {
  const rank = { urgent: 0, high: 1, medium: 2, low: 3, none: 4 };
  const sorted = [...issues].sort((a, b) => (rank[a.priority] ?? 4) - (rank[b.priority] ?? 4) || a.sequence - b.sequence);
  return sorted[0] ?? null;
}

/** P0..P3 as Plane's priority, and back. */
const plane = { P0: "urgent", P1: "high", P2: "medium", P3: "low" };
export function priorityOf(p) {
  const v = plane[String(p).toUpperCase()];
  if (!v) throw new Error(`a priority is P0, P1, P2 or P3, not ${p}`);
  return v;
}

/** Where a new bug goes by its priority (rule 6): P0 starts now, P1 joins the current sprint, P2 and
 * P3 wait in the Backlog for a coming sprint. */
export function bugPlace(p) {
  const v = priorityOf(p);
  return v === "urgent" ? { state: "Implementing", sprint: true } : v === "high" ? { state: "Refine", sprint: true } : { state: "Backlog", sprint: false };
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
