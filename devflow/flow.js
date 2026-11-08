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

/** Where an event moves an issue in `state`, or null to leave it. An issue never moves back past
 * where it is, but for the two ways back the flow names: a pull request closed unmerged (back to
 * Implementing) and a flip rolled back (back to Live). A cancelled issue is never moved. */
export function moveFor(event, state) {
  if (state === "Cancelled" || rank(state) < 0) return null;
  const forward = (to) => (rank(state) < rank(to) ? to : null);
  switch (event) {
    case "opened":
    case "reopened":
    case "ready_for_review":
      return forward("Review");
    case "merged":
      return forward("Merged");
    case "closed":
      return state === "Review" ? "Implementing" : null;
    case "released":
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

/** P0..P3 as Plane's priority, and back. */
const plane = { P0: "urgent", P1: "high", P2: "medium", P3: "low" };
export function priorityOf(p) {
  const v = plane[String(p).toUpperCase()];
  if (!v) throw new Error(`a priority is P0, P1, P2 or P3, not ${p}`);
  return v;
}

/** Where a new bug goes by its priority (rule 6): P0 starts now, P1 joins today's sprint, P2 and P3
 * wait in the Backlog. */
export function bugPlace(p) {
  const v = priorityOf(p);
  return v === "urgent" ? { state: "Implementing", sprint: true } : v === "high" ? { state: "Refine", sprint: true } : { state: "Backlog", sprint: false };
}

/** The sprint a moment falls in: each day's sprint ends at `ends` in `timeZone`, so a moment after
 * the end belongs to the next day's. Its name is its date, as Plane's cycle is named. */
export function sprintOf(at, ends, timeZone) {
  const local = (d) => new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d).reduce((o, p) => ({ ...o, [p.type]: p.value }), {});
  const t = local(new Date(at));
  let day = `${t.year}-${t.month}-${t.day}`;
  if (`${t.hour}:${t.minute}` >= ends) day = nextDay(day);
  return day;
}

/** The day after a YYYY-MM-DD day. */
export function nextDay(day) {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
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
