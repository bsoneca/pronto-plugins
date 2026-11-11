// The dev flow's hooks: what GitHub, release-cron and pronto-flags tell the board.
//   hook.ts pr <repo> [--warn]                    a pull_request event (GITHUB_EVENT_PATH): its issue to Review, Merged, back to Implementing;
//                                                 a merge that added flags off where released files "Flip <flag> on in <app>" for each
//   hook.ts released <repo> <app> <commit>        release-cron confirmed <commit>: the app's Merged issues it holds go Live; and each flag on
//                                                 for everyone 7 days or more gets "Remove flag <flag> from <app>" in the Backlog, unless one
//                                                 is on the board already: aged from its Done flip issue (a title naming it, alone or with
//                                                 others), else from <commit>'s history of flags.json (release-cron runs it every release: no scheduler)
//   hook.ts removals <repo> <app> [<commit>]      only the removal issues, by hand, as released at <commit> (HEAD by default)
//   hook.ts flipped <repo> <app> <flag...>        pronto-flags turned the flags on for everyone: their issues and flip issues are Done
//   hook.ts rolledback <repo> <app> <flag...>     a flip was rolled back: their Done issues go back to Live
// Only `pr` can fail (an issue key missing, rule 3). The others say what they did and exit 0 whatever
// happens: a release or a flip never fails for the board.
import { cmd } from "../intents/shell.ts";
import { esc, type Issue } from "./board/board.ts";
import { addedFlags, doneAt, flagNote, flagOf, flipIssueMove, flipIssueOf, flipTitle, keyOf, missingKey, moveFor, nameOf, prEvent, REMOVE_AFTER_DAYS, onSince, removalsDue, removeTitle, roleOf } from "./flow.js";
import { boardOf, devflowOf, type DevFlow } from "./spec.ts";

type Conn = NonNullable<Awaited<ReturnType<typeof boardOf>>>;

async function stateIds(b: Conn) {
  const states = await b.board.states(b.project);
  const byName = new Map(states.map((s) => [s.name, s.id]));
  const byId = new Map(states.map((s) => [s.id, s.name]));
  return { id: (n: string) => byName.get(n) ?? "", name: (id: string) => byId.get(id) ?? "" };
}

/** Moves an issue for an event, with a comment saying why; what it did, as a line. */
async function move(b: Conn, issue: Issue, event: string, why: string, flow: DevFlow, modules?: string[]): Promise<string> {
  const s = await stateIds(b);
  const from = s.name(issue.state);
  // Where it ends: its flag's flip, or without a flag its release or merge (flow.js doneAt).
  const mods = modules ?? (await b.board.modulesByIssue(b.project)).get(issue.id) ?? [];
  // The rules reason in roles; the board knows the repository's names for its states.
  const role = moveFor(event, roleOf(flow.roles, from), doneAt(flagOf(issue.description_html), mods, flow.infra));
  const to = role ? nameOf(flow.roles, role) : null;
  const key = `#${issue.sequence_id}`;
  if (!to) return `${key} stays ${from} (${event})`;
  await b.board.moveIssue(b.project, issue.id, s.id(to));
  await b.board.comment(b.project, issue.id, `<p>${esc(from)} → ${esc(to)}: ${esc(why)}</p>`);
  return `${key} ${from} → ${to}`;
}

async function pr(warn: boolean, flow: DevFlow) {
  const ev = JSON.parse(await Deno.readTextFile(Deno.env.get("GITHUB_EVENT_PATH") ?? ""));
  const p = ev.pull_request;
  const labels: string[] = (p.labels ?? []).map((l: { name: string }) => l.name);
  const key = keyOf(flow.board.project.identifier, p.title, p.head?.ref);
  if (!key) {
    const m = missingKey(labels, flow.chore, warn, flow.board.project.identifier);
    console.log(m.say);
    Deno.exit(m.ok ? 0 : 1);
  }
  const event = prEvent(ev.action, !!p.merged);
  const b = await boardOf(flow).catch((e) => (console.log(`devflow: ${(e as Error).message}`), null));
  if (!b) {
    console.log(`${key}: the board is not reachable yet (no PLANE_TOKEN, or no project): not told`);
    Deno.exit(warn ? 0 : 1);
  }
  // Filing flip issues never fails the pull request's check: what went wrong is said, as the other hooks say it.
  if (event === "merged") await fileFlips(p, ev.repository?.full_name ?? "", b, flow).catch((e) => console.log(`devflow: WARNING: no flip issues filed: ${(e as Error).message.split("\n")[0]}`));
  const issue = await b.board.issue(key).catch(() => null);
  if (!issue) {
    console.log(`${key} is not on the board`);
    Deno.exit(warn ? 0 : 1);
  }
  if (!(await b.board.links(b.project, issue.id)).some((l) => l.url === p.html_url)) {
    await b.board.link(b.project, issue.id, p.html_url, `#${p.number} ${p.title}`);
  }
  console.log(event ? await move(b, issue, event, `pull request #${p.number} ${event}`, flow) : `${key}: nothing to do for ${ev.action}`);
}

/** A file of the repository at a commit, through GitHub's API (the hook's checkout has only devflow/):
 * null when it is not there. */
async function fileAt(repo: string, path: string, ref: string): Promise<string | null> {
  const r = await cmd("gh", ["api", "-H", "Accept: application/vnd.github.raw", `repos/${repo}/contents/${path}?ref=${ref}`]);
  if (r.ok) return r.out;
  if (/HTTP 404/.test(r.err)) return null;
  throw new Error(`gh api ${path}@${ref.slice(0, 8)}: ${r.err.trim().split("\n")[0]}`);
}

/** Every flag a merged pull request added that is off where its app is released gets a flip issue in
 * the Backlog (PRONTO-265: "When there are flags to be flipped, create a new issue."): "Flip <flag> on
 * in <app>", in the app's module, with the flag's note, its Flag line and the pull request linked. A
 * flip issue already on the board for that flag and app, in any state, is reused. */
async function fileFlips(p: { number: number; html_url: string; title: string; base: { sha: string }; merge_commit_sha: string }, repo: string, b: Conn, flow: DevFlow) {
  const files = await cmd("gh", ["api", "--paginate", `repos/${repo}/pulls/${p.number}/files`, "-q", ".[].filename"]);
  if (!files.ok) throw new Error(`gh api pulls/${p.number}/files: ${files.err.trim().split("\n")[0]}`);
  const apps = [...new Set(files.out.split("\n").map((f) => /^apps\/([^/]+)\/flags\/flags\.json$/.exec(f.trim())?.[1]).filter((a): a is string => !!a))];
  if (!apps.length) return;
  const s = await stateIds(b);
  const modules = await b.board.modulesByIssue(b.project);
  const issues = (await b.board.issues(b.project)).map((i) => ({ ...i, modules: modules.get(i.id) ?? [] }));
  const mods = await b.board.modules(b.project);
  for (const app of apps) {
    const path = `apps/${app}/flags/flags.json`;
    const base = await fileAt(repo, path, p.base.sha);
    const head = await fileAt(repo, path, p.merge_commit_sha);
    const added = addedFlags(base ? JSON.parse(base) : null, head ? JSON.parse(head) : null);
    if (!added.length) continue;
    const spec = (await fileAt(repo, `apps/${app}/flags_spec.cue`, p.merge_commit_sha)) ?? "";
    for (const flag of added) {
      const had = flipIssueOf(issues, flag, app);
      if (had) {
        if (!(await b.board.links(b.project, had.id)).some((l) => l.url === p.html_url)) await b.board.link(b.project, had.id, p.html_url, `#${p.number} ${p.title}`);
        console.log(`${flag}: #${had.sequence_id} is its flip issue already`);
        continue;
      }
      const note = flagNote(spec, flag) ?? `(no note for ${flag} in apps/${app}/flags_spec.cue)`;
      const body = `<p>Flag \`${esc(flag)}\` merged off where ${esc(app)} is released, in #${p.number} ${esc(p.title)}. What it does: ${esc(note)}</p>` +
        `<p>Done when: \`pronto-flags push\` turned it on for everyone and its production cases passed; or the owner says it stays off and the flag is retired. A flip changes what players see, so it waits for the owner's go.</p>` +
        `<p>Flag: ${esc(flag)}</p>`;
      const made = await b.board.createIssue(b.project, { name: flipTitle(flag, app), description_html: body, priority: "none", state: s.id(nameOf(flow.roles, "backlog")), labels: [] });
      const mod = mods.find((m) => m.name === app);
      if (mod) await b.board.addToModule(b.project, mod.id, [made.id]);
      await b.board.link(b.project, made.id, p.html_url, `#${p.number} ${p.title}`);
      issues.push({ ...made, modules: mod ? [app] : [] });
      console.log(`${flag}: filed #${made.sequence_id} ${flipTitle(flag, app)}`);
    }
  }
}

/** The board's issues in these states, with what the dev flow reads of each. */
async function inStates(b: Conn, names: string[]) {
  const s = await stateIds(b);
  const want = new Set(names.map(s.id));
  const modules = await b.board.modulesByIssue(b.project);
  return (await b.board.issues(b.project)).filter((i) => want.has(i.state)).map((i) => ({ issue: i, modules: modules.get(i.id) ?? [] }));
}

/** Whether an issue is the app's: it is in the app's module, or in none. */
const forApp = (modules: string[], app: string) => modules.length === 0 || modules.includes(app);

async function released(repo: string, app: string, commit: string, b: Conn, flow: DevFlow) {
  for (const { issue, modules } of await inStates(b, [flow.roles.merged, flow.roles.live])) {
    if (modules.length === 0 || !modules.includes(app)) continue;
    // Live waits only for a release that finishes it: a flagless bug fix (a flagged one waits for its flip).
    if (issue.state !== (await stateIds(b)).id(flow.roles.merged) && doneAt(flagOf(issue.description_html), modules, flow.infra) !== "release") continue;
    // The pull request that merged it: its merge commit is in what was released, or it waits.
    const prs = (await b.board.links(b.project, issue.id)).map((l) => l.url).filter((u) => /\/pull\/\d+$/.test(u));
    let held = false;
    for (const url of prs) {
      const v = await cmd("gh", ["pr", "view", url, "--json", "mergeCommit", "-q", ".mergeCommit.oid"]);
      const sha = v.out.trim();
      if (v.ok && sha && (await cmd("git", ["merge-base", "--is-ancestor", sha, commit], { cwd: repo })).ok) held = true;
    }
    if (held) console.log(await move(b, issue, "released", `${app} released ${commit.slice(0, 8)}`, flow, modules));
  }
}

/** The app's flags.json at each commit that changed it along `commit`'s first-parent history in the
 * checkout `repo`, newest first, `{at, flags}` (flow.js onSince): none when it is not a checkout. */
async function flagVersions(repo: string, app: string, commit: string) {
  const path = `apps/${app}/flags/flags.json`;
  const log = await cmd("git", ["log", "--first-parent", "--format=%H %cI", commit, "--", path], { cwd: repo });
  if (!log.ok) throw new Error(`git log ${path}: ${log.err.trim().split("\n")[0]}`);
  const versions: { at: string; flags: unknown }[] = [];
  for (const line of log.out.trim().split("\n").filter(Boolean)) {
    const [sha, at] = line.split(" ");
    const file = await cmd("git", ["show", `${sha}:${path}`], { cwd: repo });
    // A version that deleted the file ends the history: nothing was on across it.
    if (!file.ok) break;
    versions.push({ at, flags: JSON.parse(file.out) });
  }
  return versions;
}

/** A flag on for everyone for 7 days gets one Backlog issue, "Remove flag <flag> from <app>", in the app's module:
 * done means the flag and its off-path code are deleted from the app and shipped through release-cron. A flag
 * with a Done flip issue (its title names it, alone or with others) counts from the board's completion time
 * (updated_at when it has none) and links the flip issue; one on by default with no Done flip issue counts from
 * the released history of the app's flags.json (`commit` in the checkout `repo`). A removal issue already on the
 * board, in any state, is reused, so a run files only what is missing. `now` is injected. */
export async function fileRemovals(repo: string, app: string, commit: string, b: Conn, flow: DevFlow, now = new Date()) {
  const s = await stateIds(b);
  const modules = await b.board.modulesByIssue(b.project);
  const issues = (await b.board.issues(b.project)).map((i) => {
    const t = i as Issue & { completed_at?: string | null; updated_at?: string | null };
    return { ...i, state: roleOf(flow.roles, s.name(i.state)) as string, modules: modules.get(i.id) ?? [], doneAt: t.completed_at ?? t.updated_at ?? "" };
  });
  // Without the history (no checkout), only the flip issues count: said, never failing the run.
  const on = onSince(await flagVersions(repo, app, commit).catch((e) => (console.log(`devflow: WARNING: no flags.json history, so only flip issues count: ${(e as Error).message}`), [])));
  const mod = (await b.board.modules(b.project)).find((m) => m.name === app);
  const { host, workspace, project } = flow.board;
  for (const due of removalsDue(issues, app, now, REMOVE_AFTER_DAYS, on)) {
    const { flag } = due;
    const key = "flip" in due ? `${project.identifier}-${due.flip.sequence_id}` : "";
    const since = "flip" in due
      ? `since its flip ${esc(key)} went Done (${esc(due.flip.doneAt)})`
      : `since ${esc(due.since)}, when apps/${esc(app)}/flags/flags.json turned it on by default (it has no Done flip issue)`;
    const body = `<p>Flag \`${esc(flag)}\` has been on for everyone in ${esc(app)} for ${REMOVE_AFTER_DAYS} days or more, ${since}.</p>` +
      `<p>Done when: the flag and its off-path code are deleted from ${esc(app)} (\`flags_spec.cue\`, \`flags/flags.json\`, the code, the scenarios) and that is shipped through release-cron.</p>` +
      `<p>Flag: ${esc(flag)}</p>`;
    const made = await b.board.createIssue(b.project, { name: removeTitle(flag, app), description_html: body, priority: "none", state: s.id(nameOf(flow.roles, "backlog")), labels: [] });
    if (mod) await b.board.addToModule(b.project, mod.id, [made.id]);
    if ("flip" in due) await b.board.link(b.project, made.id, `https://${host}/${workspace}/browse/${key}/`, `${key} ${due.flip.name}`);
    issues.push({ ...made, state: "backlog", modules: mod ? [app] : [], doneAt: "" });
    console.log(`${flag}: filed #${made.sequence_id} ${removeTitle(flag, app)} (${"flip" in due ? `flip ${key} Done ${due.flip.doneAt}` : `on since ${due.since}`})`);
  }
}

async function flip(event: "flipped" | "rolledback", app: string, flags: string[], b: Conn, flow: DevFlow) {
  const from = event === "flipped" ? [flow.roles.merged, flow.roles.live] : [flow.roles.done];
  for (const { issue, modules } of await inStates(b, from)) {
    const flag = flagOf(issue.description_html);
    if (!flag || !flags.includes(flag) || !forApp(modules, app)) continue;
    console.log(await move(b, issue, event, event === "flipped" ? `${flag} is on for everyone in ${app}` : `${flag}'s flip in ${app} was rolled back`, flow, modules));
  }
  if (event !== "flipped") return;
  // Each flag's flip issue (fileFlips, or filed by hand) is Done from wherever it waits.
  const s = await stateIds(b);
  const modules = await b.board.modulesByIssue(b.project);
  const issues = (await b.board.issues(b.project)).map((i) => ({ ...i, modules: modules.get(i.id) ?? [] }));
  for (const flag of flags) {
    const issue = flipIssueOf(issues, flag, app);
    if (!issue) continue;
    const from = s.name(issue.state);
    const role = flipIssueMove(roleOf(flow.roles, from));
    if (!role) { console.log(`#${issue.sequence_id} stays ${from} (flipped)`); continue; }
    const to = nameOf(flow.roles, role);
    await b.board.moveIssue(b.project, issue.id, s.id(to));
    await b.board.comment(b.project, issue.id, `<p>${esc(from)} → ${esc(to)}: ${esc(`${flag} is on for everyone in ${app}`)}</p>`);
    console.log(`#${issue.sequence_id} ${from} → ${to}`);
  }
}

if (import.meta.main) {
  const [verb, repoArg, ...rest] = Deno.args;
  const repo = repoArg ? await Deno.realPath(repoArg) : "";
  const flow = repo ? await devflowOf(repo) : null;
  if (!verb || !repo) {
    console.error("usage: hook.ts pr|released|removals|flipped|rolledback <repo> ...");
    Deno.exit(2);
  }
  if (!flow) {
    console.log(`devflow: ${repo} has no devflow/devflow.cue: nothing to tell`);
    Deno.exit(0);
  }
  if (verb === "pr") {
    await pr(rest.includes("--warn"), flow);
  } else {
    try {
      const b = await boardOf(flow);
      if (!b) {
        console.log("devflow: no board token (PLANE_TOKEN or Secret Manager): the board was not told");
      } else if (verb === "released") {
        await released(repo, rest[0], rest[1], b, flow);
        await fileRemovals(repo, rest[0], rest[1], b, flow);
      } else if (verb === "removals") {
        await fileRemovals(repo, rest[0], rest[1] ?? "HEAD", b, flow);
      } else if (verb === "flipped" || verb === "rolledback") {
        await flip(verb, rest[0], rest.slice(1), b, flow);
      } else {
        console.error(`devflow: no hook ${verb}`);
        Deno.exit(2);
      }
    } catch (e) {
      console.log(`devflow: WARNING: the board was not told: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}
