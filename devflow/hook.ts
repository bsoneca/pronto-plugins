// The dev flow's hooks: what GitHub, release-cron and pronto-flags tell the board.
//   hook.ts pr <repo> [--warn]                    a pull_request event (GITHUB_EVENT_PATH): its issue to Review, Merged, back to Implementing
//   hook.ts released <repo> <app> <commit>        release-cron confirmed <commit>: the app's Merged issues it holds go Live
//   hook.ts flipped <repo> <app> <flag...>        pronto-flags turned the flags on for everyone: their issues are Done
//   hook.ts rolledback <repo> <app> <flag...>     a flip was rolled back: their Done issues go back to Live
// Only `pr` can fail (an issue key missing, rule 3). The others say what they did and exit 0 whatever
// happens: a release or a flip never fails for the board.
import { cmd } from "../intents/shell.ts";
import { esc, type Issue } from "./board/board.ts";
import { doneAt, flagOf, keyOf, missingKey, moveFor, nameOf, prEvent, roleOf } from "./flow.js";
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

async function flip(event: "flipped" | "rolledback", app: string, flags: string[], b: Conn, flow: DevFlow) {
  const from = event === "flipped" ? [flow.roles.merged, flow.roles.live] : [flow.roles.done];
  for (const { issue, modules } of await inStates(b, from)) {
    const flag = flagOf(issue.description_html);
    if (!flag || !flags.includes(flag) || !forApp(modules, app)) continue;
    console.log(await move(b, issue, event, event === "flipped" ? `${flag} is on for everyone in ${app}` : `${flag}'s flip in ${app} was rolled back`, flow, modules));
  }
}

if (import.meta.main) {
  const [verb, repoArg, ...rest] = Deno.args;
  const repo = repoArg ? await Deno.realPath(repoArg) : "";
  const flow = repo ? await devflowOf(repo) : null;
  if (!verb || !repo) {
    console.error("usage: hook.ts pr|released|flipped|rolledback <repo> ...");
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
