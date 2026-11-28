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

/** Whose slot an issue takes: an architect's when one of its modules is a design module, an SRE's
 * when one is an infra module, else an engineer's. */
export function laneOf(modules, infra, design = []) {
  if ((modules ?? []).some((m) => design.includes(m))) return "architect";
  return (modules ?? []).some((m) => (infra ?? []).includes(m)) ? "SRE" : "engineer";
}

/** Whether an issue carries the feature label (`labelId`, the board's id for it, null when the board has none). */
export function featureOf(labels, labelId) {
  return !!labelId && (labels ?? []).includes(labelId);
}

/** Whether an issue may start (move to Implementing): its lane has `slots`, the lane's issues already
 * Implementing take one each, and an urgent one (P0, `urgent` in the board's own word) starts
 * regardless. `split`, for the engineer lane, is `{reserved, featureBusy, feature}`: `reserved` of the
 * slots take only feature issues, `featureBusy` of the busy ones are features, and `feature` says whether
 * this issue is one. A feature takes any free slot; another issue only one of the slots left open to it. */
/** @param {{reserved: number, featureBusy: number, feature: boolean} | null} [split] */
export function mayStart(busy, slots, priority, lane, urgent = "urgent", split = null) {
  if (priority === urgent) return { ok: true, why: "P0: starts past the slots" };
  if (slots === 0) return { ok: false, why: `the team has no ${lane}` };
  if (busy >= slots) return { ok: false, why: `all ${slots} ${lane} slots are busy` };
  if (split && split.reserved > 0 && !split.feature) {
    const open = slots - Math.min(split.reserved, slots);
    if (busy - split.featureBusy >= open) return { ok: false, reserved: true, why: `the ${open} ${lane} slots open to any issue are busy; ${slots - open} are kept for feature issues` };
  }
  return { ok: true, why: `${lane} slot ${busy + 1} of ${slots}` };
}

/** P0..P3 as the board's priority, in `priorities` (P to the board's word; Plane's by default). */
/** @type {Record<string, string>} */
const plane = { P0: "urgent", P1: "high", P2: "medium", P3: "low" };
export function priorityOf(p, priorities = plane) {
  const v = priorities[String(p).toUpperCase()];
  if (!v) throw new Error(`a priority is P0, P1, P2 or P3, not ${p}`);
  return v;
}

/** Where a new bug goes by its priority (rule 6), as a role: P0 starts now, P1 is refined at once and
 * jumps the queue once Ready, P2 and P3 wait in the Backlog until the lead refines them. */
export function bugPlace(p, priorities = plane) {
  priorityOf(p, priorities);
  const n = String(p).toUpperCase();
  return n === "P0" ? { role: "implementing" } : n === "P1" ? { role: "refine" } : { role: "backlog" };
}

/** When an issue became Ready (PRONTO-658): the latest of its moves into the Ready state, the stay it
 * is in now (a bounced issue queues again from its last entry), else `fallback` (made in Ready: its
 * creation). `moves` are `{to, at}`, `to` a state's id. */
export function readySince(moves, readyId, fallback) {
  const at = (moves ?? []).filter((m) => m.to === readyId && Number.isFinite(Date.parse(m.at))).map((m) => Date.parse(m.at));
  return at.length ? new Date(Math.max(...at)).toISOString() : fallback ?? null;
}

/** Whether a Ready issue jumps the queue: a bug (its label) at P0 or P1. `urgent` is the board's words
 * for P0 and P1. A P1 feature waits its turn like any other. */
export function jumps(priority, bug, urgent = ["urgent", "high"]) {
  return !!bug && urgent.includes(priority);
}

/** The order a lane pulls its Ready issues, by the flow's `queue.order` (devflow/schema.cue): the jumping bugs first
 * (a P0's before a P1's), then, in order "ready" (PRONTO-658, the default), first in, first out by when each became
 * Ready, or, in order "filed" (PRONTO-1538), by when each was filed (`filedAt`, and `umbrella`, the number of the
 * issue it is a child of, before its own number), then by number. `issues` are `{key, sequence, jump, p0, readyAt,
 * filedAt, umbrella}`; one with no time for the order comes last of its kind. */
export function pullOrder(issues, order = "ready") {
  const at = (i) => (order === "filed" ? i.filedAt : i.readyAt);
  const t = (i) => (Number.isFinite(Date.parse(at(i) ?? "")) ? Date.parse(at(i)) : Infinity);
  const u = (i) => (order === "filed" ? i.umbrella ?? i.sequence : 0);
  return [...issues].sort((a, b) => Number(!!b.jump && !!b.p0) - Number(!!a.jump && !!a.p0) || Number(!!b.jump) - Number(!!a.jump) || (t(a) < t(b) ? -1 : t(a) > t(b) ? 1 : 0) || u(a) - u(b) || a.sequence - b.sequence);
}

/** Where an issue sorts in "filed" order: when it was filed and the number it sorts at. With `inherit`
 * (`queue.childrenAtUmbrella`), a child takes its umbrella's creation time and number, found by the id
 * its `parent` names among `all` (`{id, sequence_id, created_at, parent}`); one level only, so a cycle
 * of parents ends at once. A parent the board did not list leaves the child at its own. */
export function filedPlace(issue, all, inherit) {
  const up = inherit && issue.parent ? (all ?? []).find((x) => x.id === issue.parent && x.id !== issue.id) : null;
  return up ? { filedAt: up.created_at ?? issue.created_at ?? null, umbrella: up.sequence_id } : { filedAt: issue.created_at ?? null, umbrella: issue.sequence_id };
}

/** What merged and when, by day: `times` are ISO moments an issue merged. `today` and `week` count the
 * moments on the day of `now` and in the `days` before it, `byDay` each day with its count, newest
 * first, days in `timeZone`. */
export function mergedByDay(times, now, timeZone, days = 7) {
  const n = now instanceof Date ? now.getTime() : Date.parse(now);
  const within = (times ?? []).map((t) => Date.parse(t)).filter((t) => Number.isFinite(t) && t <= n && n - t < days * DAY);
  const counts = new Map();
  for (const t of within) {
    const d = dayOf(t, timeZone);
    counts.set(d, (counts.get(d) ?? 0) + 1);
  }
  const byDay = [...counts].sort((a, b) => (a[0] < b[0] ? 1 : -1)).map(([day, count]) => ({ day, count }));
  return { today: counts.get(dayOf(n, timeZone)) ?? 0, week: within.length, byDay };
}

/** The day a moment falls on in `timeZone`, YYYY-MM-DD. */
export function dayOf(at, timeZone) {
  const t = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(at)).reduce((o, p) => ({ ...o, [p.type]: p.value }), {});
  return `${t.year}-${t.month}-${t.day}`;
}

const DAY = 86400000;

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

/** The flags a merge added that are off where the app is released: those of the app's generated
 * flagd file (flags/flags.json) at the merge, `head`, not at its base, whose default variant is false.
 * `base` is null when the file is new. The flags to flip on later (PRONTO-265). */
export function addedFlags(base, head) {
  const before = new Set(Object.keys(base?.flags ?? {}));
  return Object.entries(head?.flags ?? {})
    .filter(([name, f]) => !before.has(name) && f?.variants?.[f.defaultVariant] === false)
    .map(([name]) => name)
    .sort();
}

/** A flag's note in an app's flags_spec.cue (`flags: <flag>: {` or `<flag>: {` inside `flags: {`),
 * its multi-line string dedented to one paragraph; null when the flag or its note is not there. */
export function flagNote(cue, flag) {
  const text = String(cue ?? "");
  const at = new RegExp(`(?:^|[\\s{])${flag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:\\s*\\{`, "m").exec(text);
  if (!at) return null;
  const rest = text.slice(at.index + at[0].length);
  const m = /^\s*note:\s*"""\n([\s\S]*?)\n\s*"""/m.exec(rest);
  // The note is the flag's own: no other flag's block opens before it.
  if (!m || /^\s*(?:[A-Za-z0-9_]+:\s*)+\{/m.test(rest.slice(0, m.index))) return null;
  return m[1].split("\n").map((l) => l.trim()).filter(Boolean).join(" ");
}

/** A flip issue's title: what turning the flag on for everyone in the app is called on the board. */
export function flipTitle(flag, app) {
  return `Flip ${flag} on in ${app}`;
}

/** The flag a flip issue's title names ("Flip <flag> on in <app>"), or null for another issue. */
export function flipOf(title) {
  const m = /^Flip `?([A-Za-z0-9_.-]+)`? on in \S/.exec(String(title ?? "").trim());
  return m ? m[1] : null;
}

/** Whether an issue waits for a release (PRONTO-666): an Implementing flip issue with the wait label,
 * `waitId` the label's id on the board (null when the board has none). It holds no slot. */
export function waitsRelease(role, name, labels, waitId) {
  return role === "implementing" && flipOf(name) !== null && !!waitId && (labels ?? []).includes(waitId);
}

/** What `wait --pr` does with an issue whose fix merged under another issue's pull request (`key` its "#n"):
 * an Implementing flip issue waits for the release holding it ({wait: true}, PRONTO-666); any other issue
 * moves as its own merge would have ({to: <role>}, moveFor "merged", PRONTO-1050), so the release and flip
 * hooks finish it; else {refused: why}. `done` is doneAt's answer, `modules` the issue's. */
export function waitPlan({ key, role, flip, merged, openPr, done, modules }) {
  if (!merged) return { refused: `${key} is not merged` };
  if (openPr) return { refused: "it has an open pull request" };
  if (flip) return role === "implementing" ? { wait: true } : { refused: "only an Implementing flip waits" };
  if (done === "release" && !(modules ?? []).length) return { refused: "it is in no app's module, so no release would finish it" };
  const to = moveFor("merged", role, done);
  if (to) return { to };
  return { refused: role === "cancelled" ? "a cancelled issue is never moved" : rank(role) < 0 ? "its state plays no role in the flow" : `it is ${role} already` };
}

/** Whether a waiting issue's fix is released: `prs` are `{merged, held}` of its linked pull requests (held:
 * the released commit holds its merge). True when some merged and every merged one is held. */
export function fixReleased(prs) {
  // A pull request whose state could not be read (gh failed) may be a fix not yet released: wait.
  if ((prs ?? []).some((p) => p.read === false)) return false;
  const merged = (prs ?? []).filter((p) => p.merged);
  return merged.length > 0 && merged.every((p) => p.held);
}

/** An issue's labels without the wait label (`waitId`), every other label kept (bug, on-hold). */
export function unwaited(labels, waitId) {
  return (labels ?? []).filter((l) => l !== waitId);
}

/** The flip issue of an app's flag among `issues` (`{name, modules}`): titled for the flag, in the
 * app's module, whatever its state, so one filed by hand (PRONTO-225..264) is never filed twice;
 * null when there is none. */
export function flipIssueOf(issues, flag, app) {
  return (issues ?? []).find((i) => flipOf(i.name) === flag && (i.modules ?? []).includes(app)) ?? null;
}

/** Where a flip moves the flag's flip issue, as a role: Done from any open state (it waits in the
 * Backlog for the owner's go, not for a pull request); null when it is Done or cancelled already. */
export function flipIssueMove(state) {
  return state === "done" || state === "cancelled" || rank(state) < 0 ? null : "done";
}

/** How long a flag is on for everyone before its removal issue is filed, in days (the owner, 2026-11-11). */
export const REMOVE_AFTER_DAYS = 7;

/** A removal issue's title: the flag and its off-path code leave the app a week after its flip. */
export function removeTitle(flag, app) {
  return `Remove flag ${flag} from ${app}`;
}

/** The flag a removal issue's title names ("Remove flag <flag> from <app>"), or null for another issue. */
export function removeOf(title) {
  const m = /^Remove flag `?([A-Za-z0-9_.-]+)`? from \S/.exec(String(title ?? "").trim());
  return m ? m[1] : null;
}

/** The removal issue of an app's flag among `issues` (`{name, modules}`): titled for the flag, in the
 * app's module, whatever its state (Done and Cancelled too), so it is never filed twice; null when none. */
export function removeIssueOf(issues, flag, app) {
  return (issues ?? []).find((i) => removeOf(i.name) === flag && (i.modules ?? []).includes(app)) ?? null;
}

/** Whether a flag on for everyone since `since` (an ISO time) has been so for `days` by `now`, both
 * injected: a missing or unreadable time is never old enough. */
export function onForDays(since, now, days = REMOVE_AFTER_DAYS) {
  const t = Date.parse(since ?? "");
  const n = now instanceof Date ? now.getTime() : Date.parse(now ?? "");
  return Number.isFinite(t) && Number.isFinite(n) && n - t >= days * 86400000;
}

/** The flags a flip issue's title names: "Flip <flag> on in <app>", or several, as PRONTO-44 was filed by
 * hand ("Flip trial_banner and roman_army on for everyone where Bonk Chess is released"; commas too);
 * empty for another issue. */
export function flipFlagsOf(title) {
  const m = /^Flip (.+?) on (?:in|for) \S/.exec(String(title ?? "").trim());
  if (!m) return [];
  const names = m[1].split(/\s*,\s*(?:and\s+)?|\s+and\s+/).map((n) => n.replace(/^`|`$/g, ""));
  return names.every((n) => /^[A-Za-z0-9_.-]+$/.test(n)) ? names : [];
}

/** Since when each flag on by default in an app's flags.json has been so, from the file's versions along
 * the released history (`versions`: `{at, flags}`, newest first, `flags` the file's parsed JSON): the
 * time of the oldest version of the run of versions, back from the newest, in which it is on. A flag is on
 * when its default variant is the boolean true (billing_grants' object is no flag to remove). When the
 * history runs out still on, its oldest version's time: a lower bound, never too old. `{flag: at}`. */
export function onSince(versions) {
  const on = (file, flag) => {
    const f = file?.flags?.[flag];
    return f?.variants?.[f.defaultVariant] === true;
  };
  const [newest, ...older] = versions ?? [];
  const since = {};
  for (const flag of Object.keys(newest?.flags?.flags ?? {}).filter((f) => on(newest.flags, f))) {
    let at = newest.at;
    for (const v of older) {
      if (!on(v.flags, flag)) break;
      at = v.at;
    }
    since[flag] = at;
  }
  return since;
}

/** The removal issues to file for an app, `[{flag, flip}]` or `[{flag, since}]`, sorted by flag, once per flag,
 * none for a flag with a removal issue among `issues` (any state). A flag goes by its flip issue
 * (`{name, modules, state, doneAt}`, `state` a role, `doneAt` when it went Done: the board's completion time)
 * when one is Done, titled for it alone or with others: due once Done `days` ago by `now`. A flag with no
 * Done flip issue (on by a merge before flip issues, or its flip cancelled) goes by `on`, `{flag: since}` from
 * the released history (onSince): due once on `days`. */
export function removalsDue(issues, app, now, days = REMOVE_AFTER_DAYS, on = {}) {
  const due = new Map();
  const flipped = new Set();
  for (const i of issues ?? []) {
    if (i.state !== "done" || !(i.modules ?? []).includes(app)) continue;
    for (const flag of flipFlagsOf(i.name)) {
      flipped.add(flag);
      if (!onForDays(i.doneAt, now, days) || removeIssueOf(issues, flag, app) || due.has(flag)) continue;
      due.set(flag, { flag, flip: i });
    }
  }
  for (const [flag, since] of Object.entries(on ?? {})) {
    if (flipped.has(flag) || !onForDays(since, now, days) || removeIssueOf(issues, flag, app)) continue;
    due.set(flag, { flag, since });
  }
  return [...due.values()].sort((a, b) => (a.flag < b.flag ? -1 : a.flag > b.flag ? 1 : 0));
}

/** How long a board call waits before try `attempt + 1` (ms): 2 s doubling, at most 30 s. The caller
 * adds jitter, so processes that failed together do not ask again together (PRONTO-1707). */
export function backoff(attempt) {
  return Math.min(2000 * 2 ** attempt, 30_000);
}

/** Whether a board call that failed is asked again, and after how long (ms), or null to give up.
 * `failure` is the HTTP status, or "timeout" / "network" when no answer came. A 429 never ran, so
 * any call is asked again; a GET, PATCH, PUT or DELETE is the same call twice, so a timeout, a lost
 * connection or a 5xx asks again too; a POST that got no answer may have been made (a comment, an
 * issue), so it is not asked twice. `tries` calls in all (PRONTO-341: a call that never answered
 * held a verb for ever). */
export function askAgain(method, failure, attempt, tries = 4) {
  if (attempt + 1 >= tries) return null;
  const wait = backoff(attempt);
  if (failure === 429) return wait;
  const same = ["GET", "HEAD", "PATCH", "PUT", "DELETE"].includes(String(method).toUpperCase());
  if (!same) return null;
  if (failure === "timeout" || failure === "network" || (typeof failure === "number" && failure >= 500)) return wait;
  return null;
}

/** askAgain under a retry budget: `spent` retries already made by this process, `budget` the most it
 * may make in all. Once spent, every failure is final, so a Plane that stays down is reported, not
 * waited on for ever (PRONTO-1707: 35 processes each retrying kept Plane down). */
export function retryVerdict(method, failure, attempt, spent, budget) {
  if (spent >= budget) return null;
  return askAgain(method, failure, attempt);
}

/** Whether a failure says Plane is down, not that this call was wrong: 502, 503, 504 or no answer in time. */
export function tripsBreaker(failure) {
  return failure === 502 || failure === 503 || failure === 504 || failure === "timeout";
}

/** Whether the shared breaker is open: a failure that trips it wrote `untilMs`, and calls before it fail at once. */
export function breakerOpen(untilMs, nowMs) {
  return Number.isFinite(untilMs) && nowMs < untilMs;
}

/** A pull's claim on an issue, written in the comment that moves it: `claim <nonce>`. */
export function claimText(nonce) {
  return `claim ${nonce}`;
}

/** Which of two pulls racing for one issue keeps it (PRONTO-341: two sessions both moved PRONTO-298):
 * each moves the issue and comments its claim, then reads the comments; the claim made first, among
 * those of the last `windowS` seconds, wins, and the other pull leaves the issue to it and takes the
 * next. `comments` are `{html, at}` (an ISO time); null when no claim is there. Equal times go to
 * the smaller nonce, so both pulls agree. */
export function claimWinner(comments, now, windowS = 600) {
  const since = new Date(now).getTime() - windowS * 1000;
  const claims = comments.flatMap((c) => {
    const m = /\bclaim ([0-9a-z-]{8,})/i.exec(String(c.html ?? ""));
    const at = new Date(c.at).getTime();
    return m && at >= since ? [{ nonce: m[1], at }] : [];
  });
  claims.sort((a, b) => a.at - b.at || (a.nonce < b.nonce ? -1 : a.nonce > b.nonce ? 1 : 0));
  return claims[0]?.nonce ?? null;
}

/** How long an issue has held its state, as the short age a status line shows: "2d" from a day, else "5h". */
export function ageOf(since, now) {
  const ms = new Date(now).getTime() - Date.parse(since ?? "");
  if (!Number.isFinite(ms) || ms < 0) return "0h";
  return ms >= 86400000 ? `${Math.floor(ms / 86400000)}d` : `${Math.floor(ms / 3600000)}h`;
}

/** Why an issue holding a slot (Implementing or Review) is stuck, or null when it is not (2026-11-14: the
 * board said 5 of 6 slots busy for two days with every session ended). `facts`: `{key, state, since}`
 * (`state` the repository's name, `since` an ISO time the issue last changed), `pr` (its linked open pull
 * request, `{ci: "pass"|"fail"|"pending", auto: boolean}`, or null) and `commit` (the newest commit on a
 * branch naming its key, an ISO time, or null). With no open pull request it is stuck when it changed
 * `hours` ago or more and no commit is that recent; with one, when its ci failed or its auto-merge is not
 * armed. `{key, state, age, why}`. */
export function stuckOf(facts, now, hours = 6) {
  const { key, state, since, pr, commit } = facts;
  const quiet = (at) => !Number.isFinite(Date.parse(at ?? "")) || new Date(now).getTime() - Date.parse(at) >= hours * 3600000;
  const age = ageOf(since, now);
  let why = null;
  if (!pr) {
    if (quiet(since) && quiet(commit)) why = `no PR, ${commit ? `last commit ${ageOf(commit, now)} ago` : "no commits"}`;
  } else if (pr.ci === "fail") why = `PR ci failed`;
  else if (!pr.auto) why = `PR auto-merge not armed`;
  return why ? { key, state, age, why } : null;
}

/** The pull requests nobody is driving (the owner, 2026-11-22: PR 1647 sat two hours red with no session). `prs`:
 * open pull requests as `{repo, number, isDraft, commits: [{committedDate}], comments: [{createdAt}],
 * reviews: [{submittedAt}], checks: [{name, conclusion, completedAt}]}` (gh's `statusCheckRollup`, its `status` and
 * `conclusion` upper case). A draft is never listed. One is forgotten when (a) nothing happened on it in `hours`
 * (a commit, a comment, a review or a check completing), or (b) a check failed and no commit came after the
 * failure. `[{repo, number, age, why}]`, `age` since its last activity; `why` is `idle 2h`, `red: review (security)
 * 2h, no push since`, or both joined by `; `. A cancelled or skipped check is no failure. */
export function forgottenPrs(prs, now, hours = 1) {
  const t = (at) => Date.parse(at ?? "");
  const at = (list, field) => list.map((x) => t(x[field])).filter(Number.isFinite);
  const late = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"];
  const out = [];
  for (const p of prs) {
    if (p.isDraft) continue;
    const checks = p.checks ?? [];
    const commits = at(p.commits ?? [], "committedDate");
    const last = Math.max(...commits, ...at(p.comments ?? [], "createdAt"), ...at(p.reviews ?? [], "submittedAt"), ...at(checks, "completedAt"));
    const pushed = Math.max(...commits);
    const whys = [];
    const since = Number.isFinite(last) ? new Date(last).toISOString() : null;
    if (!since || new Date(now).getTime() - last >= hours * 3600000) whys.push(`idle ${since ? ageOf(since, now) : "?"}`);
    const red = checks.filter((c) => late.includes(c.conclusion) && Number.isFinite(t(c.completedAt)) && !(t(c.completedAt) < pushed));
    if (red.length) {
      const first = red.reduce((a, c) => (t(c.completedAt) < t(a.completedAt) ? c : a));
      whys.push(`red: ${red.map((c) => c.name).join(", ")} ${ageOf(first.completedAt, now)}, no push since`);
    }
    if (whys.length) out.push({ repo: p.repo, number: p.number, age: since ? ageOf(since, now) : "?", why: whys.join("; ") });
  }
  return out;
}

/** The line `status` and `prs` print: `forgotten PRs: repo#n (age) why | ...`, or `forgotten PRs: none`. */
export function forgottenLine(list) {
  return `forgotten PRs: ${list.length ? list.map((f) => `${f.repo}#${f.number} (${f.age}) ${f.why}`).join(" | ") : "none"}`;
}

/** The flags merged to main and not on for everyone in production (the owner, 2026-11-22: "A watcher for pending
 * flags"). `apps`: `[{app, flags: {name: {default, note?}}, live: {name: value}, added: {name: ISO time | null},
 * cases: {name: boolean|null}}]` (null: could not be read): each app's flags as main says them, the value OFREP answers for each (absent or null:
 * it answers none, as a flag that is not `client` does), when the commit that added each landed, and whether a
 * scenario or unit case names it. A flag is pending when its `default` is false and it is not live true. `held`:
 * `[{app, flag}]` the owner is holding (devFlow.flagsHeld), never listed. `[{app, flag, age, note, cases}]`, in the
 * order of `apps` and each app's flags by name; `age` since it was added (`?` when no commit says), `note` its first line. */
export function pendingFlags(apps, held, now) {
  const out = [];
  for (const a of apps) {
    for (const flag of Object.keys(a.flags).sort()) {
      const f = a.flags[flag];
      if (f.default !== false || a.live[flag] === true) continue;
      if (held.some((h) => h.app === a.app && h.flag === flag)) continue;
      const since = a.added[flag] ?? null;
      out.push({ app: a.app, flag, age: since ? ageOf(since, now) : "?", note: String(f.note ?? "").trim().split("\n")[0].trim(), cases: a.cases[flag] === null ? null : a.cases[flag] === true });
    }
  }
  return out;
}

/** The flags live true while main's spec says `default: false`: flipped, never recorded (`apps` as pendingFlags reads
 * them; held flags too, a hold is no excuse for a record that is wrong). Live keys that are no flag of the spec
 * (pronto-armies' rows) are never read. `[{app, flag}]`. */
export function driftFlags(apps) {
  const out = [];
  for (const a of apps) {
    for (const flag of Object.keys(a.flags).sort()) if (a.flags[flag].default === false && a.live[flag] === true) out.push({ app: a.app, flag });
  }
  return out;
}

/** The pending flags (or, with `kind` "drift", the drifts) a report has not made: those whose `kind:app/flag` is not among `seen`. A flag that was
 * pending and is now drift is a new report. */
export function newPending(list, seen, kind = "pending") {
  return list.filter((f) => !seen.includes(`${kind}:${f.app}/${f.flag}`));
}

/** The lines for apps whose flags could not be read, one each: `pending flags: <app> unavailable (<reason>)`. */
export function unavailableLines(list) {
  return list.map((u) => `pending flags: ${u.app} unavailable (${u.reason})`);
}

/** The line `status` and `flags` print: `pending flags: app/flag (age, cases: yes|no|?) | ...`, or `pending flags: none`
 * (`none new` for a report of the new ones alone, so it never reads as no flag pending), then, when `drift` has any,
 * `; drift: app/flag live=true spec=false | ...`. */
export function pendingLine(list, fresh = false, drift = []) {
  const d = drift.length ? `; drift: ${drift.map((f) => `${f.app}/${f.flag} live=true spec=false`).join(" | ")}` : "";
  return `pending flags: ${list.length ? list.map((f) => `${f.app}/${f.flag} (${f.age}, cases: ${f.cases === null ? "?" : f.cases ? "yes" : "no"})`).join(" | ") : fresh ? "none new" : "none"}${d}`;
}

/** The line status prints for a stuck issue. */
export function stuckLine(s) {
  return `stuck: ${s.key} ${s.state} ${s.age}, ${s.why}`;
}

// --- The suggestion inbox (PRONTO-544). A suggestion's text is a stranger's: it reaches output
// only through excerptOf, and never reaches a PRONTO issue. ---

const NAMED = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** A suggestion's description (HTML) as one line of inert text, `{text, cut}`: the input cut to 8000
 * characters first (the tag pattern is quadratic), tags dropped, entities decoded once (so `&amp;lt;`
 * stays text), terminal escapes (an OSC read to 256 characters at most) and control, format,
 * separator, private and surrogate characters turned to spaces, blank fillers, combining marks and
 * variation selectors removed, whitespace collapsed, mentions, addresses and runs of 8 or more digits
 * masked (`[email]`, `[number]`), the first `max` characters kept, links and bare domains defanged,
 * each markdown character (and the curly quotes and `&`) backslash-escaped, and the result capped at
 * twice `max` (400 by default) without splitting an escape. `cut` says any cap took something. */
export function excerptOf(html, max = 200) {
  const raw = String(html ?? "");
  let s = raw.slice(0, 8000).replace(/<[^>]*>/g, " ");
  s = s.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/gi, (_m, e) => {
    if (e[0] !== "#") return NAMED[e.toLowerCase()];
    const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
    return Number.isInteger(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : " ";
  });
  // deno-lint-ignore no-control-regex
  s = s.replace(/\x1b\][^\x07\x1b]{0,256}(?:\x07|\x1b\\)?/g, " ").replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, " ");
  s = s.replace(/[\u115f\u1160\u2800\u3164\uffa0\p{Mn}\p{Me}\ufe00-\ufe0f\u{e0100}-\u{e01ef}]/gu, "");
  s = s.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cs}]/gu, " ").replace(/\s+/g, " ").trim();
  s = s.replace(/@/g, "(at)").replace(/\S+\(at\)\S+/g, "[email]").replace(/\d(?:[ .-]?\d){7,}/g, "[number]");
  const chars = [...s];
  let cut = raw.length > 8000 || chars.length > max;
  s = chars.slice(0, max).join("").trimEnd();
  s = s.replace(/:\/\//g, "[:]//").replace(/www\./gi, "www[.]").replace(/(?<=\w)\.(?=\w)/g, "[.]");
  s = s.replace(/[\\"`*_~[\]<>#|\u201c\u201d\uff02&]/g, (c) => `\\${c}`);
  const room = max * 2;
  if (s.length > room) {
    let out = "";
    for (const u of s.match(/\\[\s\S]|[\s\S]/gu) ?? []) {
      if (out.length + u.length > room) break;
      out += u;
    }
    s = out.trimEnd();
    cut = true;
  }
  return { text: s, cut };
}

/** Who filed an inbox item, from its title `<app>: <submitter type>` (the filer's contract,
 * dev-flow.md): `{app, submitter}`, both "unknown" when the title does not match or the app is not
 * one of `from`. The raw title is never returned. */
export function submitterOf(title, from) {
  const m = /^([a-z0-9][a-z0-9-]{0,39}): ([a-z][a-z0-9-]{0,23})$/.exec(String(title ?? ""));
  return m && (from ?? []).includes(m[1]) ? { app: m[1], submitter: m[2] } : { app: "unknown", submitter: "unknown" };
}

/** Whether a suggestion made at `createdAt` is older than `days` days at `now` (both injected):
 * exactly `days` is not, a moment past it is. A missing or unreadable time is never stale. */
export function staleOf(createdAt, now, days = 14) {
  const t = Date.parse(createdAt ?? "");
  const n = now instanceof Date ? now.getTime() : Date.parse(now ?? "");
  return Number.isFinite(t) && Number.isFinite(n) && n - t > days * DAY;
}

/** The title of the issue an approved suggestion is filed as: the filed marker `approve` looks up. */
export function suggestionTitle(app, key) {
  return `${app} suggestion ${key}, approved by the owner`;
}

/** The inbox key and app a filed issue's title names, `{app, key}`, or null for another issue. */
export function suggestionOf(title, project) {
  const m = /^([a-z0-9][a-z0-9-]{0,39}) suggestion ([A-Z]{2,12}-[1-9][0-9]*), approved by the owner$/.exec(String(title ?? ""));
  return m && m[2].startsWith(`${project}-`) ? { app: m[1], key: m[2] } : null;
}

// The alerts watch (PRONTO-2182): Cloud Monitoring's incidents say which alert policy is down, flapping or left open,
// and each of those is a bug in the alert or in what it watches, filed on the board once (devflow/alerts.ts).

const DAY_MS = 24 * 3600000;
const ALERT_CLASSES = ["outage", "flapping", "stale"];
const EVENT_MS = 5 * 60000;

/** The board app an alert policy belongs to: its `app` label, else its `owner` label, each through the flow's `apps`
 * (alerts.apps); null when neither is mapped. */
export function alertApp(labels, apps = {}) {
  for (const k of ["app", "owner"]) {
    const v = labels?.[k];
    if (typeof v === "string" && Object.hasOwn(apps, v)) return apps[v];
  }
  return null;
}

/** What each alert policy is doing, from its incidents: `incidents` are `{policy, display, labels, state, openTime,
 * closeTime}` (the policy's resource name, which holds its project, its display name, its user labels, `OPEN` or
 * `CLOSED`, ISO times), the read of the last 48 hours and what is open now. `rules`: `{flapOpens, flapCloseMin,
 * staleHours, apps, ignore}`. One row a policy, in the order the policies first appear (a policy whose `app` or `owner`
 * label is in `rules.ignore`, default none, has no row): `{policy, display, app, class, opens, openSince}`. The class,
 * first that holds: `stale` (an incident open longer than `staleHours`), `outage` (an incident open now), `flapping`
 * (more than `flapOpens` events in the last 24 hours, or at least 2 incidents that closed within `flapCloseMin` minutes
 * of opening), else `ok`. An outage comes before flapping, so a policy that is down now is never filed as a flapping one
 * (and its flapping issue never hides the outage: an issue is matched by class). Incidents of one policy opened within
 * 5 minutes of each other are one event (several resources failing together). `opens` is the events in the last 24
 * hours; `openSince` the oldest open incident's open time, else the first open in the read, null when none is dated.
 * `app` is the board app (alertApp), null when its labels map to none. */
export function alertClass(incidents, now, rules) {
  const t = (at) => Date.parse(at ?? "");
  const at = new Date(now).getTime();
  const ignored = (labels) => ["app", "owner"].some((k) => (rules.ignore ?? []).includes(labels?.[k]));
  const by = new Map();
  for (const i of incidents) {
    if (ignored(i.labels)) continue;
    if (!by.has(i.policy)) by.set(i.policy, []);
    by.get(i.policy).push(i);
  }
  const rows = [];
  for (const [policy, list] of by) {
    const open = list.filter((i) => i.state === "OPEN");
    const opens = list.map((i) => t(i.openTime)).filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
    const events = opens.filter((n, k) => n >= at - DAY_MS && (k === 0 || n - opens[k - 1] > EVENT_MS)).length;
    const quick = list.filter((i) => Number.isFinite(t(i.closeTime)) && Number.isFinite(t(i.openTime)) && t(i.closeTime) - t(i.openTime) <= rules.flapCloseMin * 60000).length;
    const openAges = open.map((i) => t(i.openTime)).filter((n) => Number.isFinite(n));
    const oldest = openAges.length ? Math.min(...openAges) : null;
    let cls = "ok";
    if (oldest !== null && at - oldest > rules.staleHours * 3600000) cls = "stale";
    else if (open.length) cls = "outage";
    else if (events > rules.flapOpens || quick >= 2) cls = "flapping";
    const since = oldest ?? (opens.length ? opens[0] : null);
    const first = list[0];
    rows.push({ policy, display: first.display, app: alertApp(first.labels, rules.apps), class: cls, opens: events, openSince: since === null ? null : new Date(since).toISOString() });
  }
  return rows;
}

/** The project a policy's resource name (`projects/<p>/alertPolicies/<id>`) is in, null when it names none. */
export const alertProject = (policy) => /^projects\/([^/]+)\//.exec(String(policy))?.[1] ?? null;

/** The title of the issue for an alert: `Alert <class>: <display name> (<project>)`, the project last so that the same
 * display name in two projects is two issues (none when `project` is null). */
/** @param {string} cls @param {string} display @param {string | null} [project] */
export function alertTitle(cls, display, project = null) {
  return `Alert ${cls}: ${display}${project ? ` (${project})` : ""}`;
}

/** The class, policy display name and project an issue title names (alertTitle), null when it is no alert's; the project is null when the title has none. */
export function alertOf(title) {
  const m = new RegExp(`^Alert (${ALERT_CLASSES.join("|")}): (.+?)(?: \\(([a-z][a-z0-9-]*)\\))?$`).exec(String(title ?? ""));
  return m ? { class: m[1], display: m[2], project: m[3] ?? null } : null;
}

/** The issue among `issues` (`{name}`) that is about this row: the same class, display name and project (a title with no project matches any). */
export function alertIssueOf(issues, row) {
  const project = alertProject(row.policy);
  return issues.find((i) => {
    const a = alertOf(i.name);
    return a && a.class === row.class && a.display === row.display && (a.project === null || a.project === project);
  });
}

/** The rows to file: not `ok`, no open board issue already about the policy in that class (alertIssueOf: an issue of
 * another class, say a flapping one, never hides an outage; `issues` are the open ones), and `class:policy` not among
 * `seen` (filed before, whatever became of the issue; a policy's resource name holds its project). */
export function alertFilings(rows, issues, seen = []) {
  return rows.filter((r) => r.class !== "ok" && !alertIssueOf(issues, r) && !seen.includes(`${r.class}:${r.policy}`));
}

/** The source file of an alert policy: the `cue` of the `sources` entry (`{prefix, cue}`) whose prefix its display
 * name starts with, the longest one; null when none does (an entry with prefix "" matches every name). */
export function alertSource(display, sources) {
  let best = null;
  for (const s of sources ?? []) if (String(display).startsWith(s.prefix) && (best === null || s.prefix.length > best.prefix.length)) best = s;
  return best ? best.cue : null;
}
