// The suggestion inbox (PRONTO-544, devflow/dev-flow.md "Suggestions"): what status says of it, the
// `approve` verb and the connect steps that make it, all behind the Board interface so a test runs
// them on a fake (tests/unit/devflow.js). The rules are flow.js's. A suggestion's text is a
// stranger's: it reaches output only as excerptOf's one inert, capped, labelled line, and never
// reaches a PRONTO issue.
import type { Step } from "../intents/run.ts";
import { type Board, esc } from "./board/board.ts";
import { dayOf, excerptOf, staleOf, submitterOf, suggestionOf, suggestionTitle } from "./flow.js";
import type { DevFlow } from "./spec.ts";

type Inbox = NonNullable<DevFlow["suggestions"]>;

/** The inbox the flow names, on a board that can hold it (Plane's). */
function inboxOf(flow: DevFlow): Inbox {
  if (!flow.suggestions) throw new Error("this repository's devflow.cue names no suggestions inbox");
  if (flow.board.kind !== "plane") throw new Error("suggestions need a plane board");
  return flow.suggestions;
}

/** The inbox's state named for a group: Suggested (backlog), Refine (unstarted), Cancelled (cancelled). */
const stateOf = (sug: Inbox, group: string) => sug.states.find((s) => s.group === group)!.name;

const DAY = 86400000;

export interface Waiting { key: string; app: string; submitter: string; date: string; days: number; stale: boolean; excerpt: string; cut: boolean; untrusted: true }
export interface Approved { key: string; app: string }
export interface SuggestionStatus { project: string; missing: boolean; waiting: Waiting[]; approved: Approved[] }

/** What status says of the inbox: the items waiting on the owner (Suggested, oldest first) and those
 * he approved (Refine) that no issue of the board is titled for yet; null when the flow has no inbox.
 * `inbox` is the inbox project's id, absent when `connect plane` has not made it; `names` are the
 * board's issues' titles. */
export async function suggestionStatus(board: Board, flow: DevFlow, inbox: string | undefined, names: string[], now: Date): Promise<SuggestionStatus | null> {
  if (!flow.suggestions) return null;
  const sug = inboxOf(flow);
  if (!inbox) return { project: sug.project, missing: true, waiting: [], approved: [] };
  const [states, issues] = await Promise.all([board.states(inbox), board.issues(inbox, false)]);
  const at = (state: string) => states.find((s) => s.id === state)?.name;
  const keyOf = (n: number) => `${sug.project}-${n}`;
  const filed = new Set(names.flatMap((n) => suggestionOf(n, sug.project)?.key ?? []));
  const waiting = issues.filter((i) => at(i.state) === stateOf(sug, "backlog"))
    .sort((a, b) => Date.parse(a.created_at ?? "") - Date.parse(b.created_at ?? "") || a.sequence_id - b.sequence_id)
    .map((i): Waiting => {
      const who = submitterOf(i.name, sug.from);
      const { text, cut } = excerptOf(i.description_html);
      const made = Date.parse(i.created_at ?? "");
      return {
        key: keyOf(i.sequence_id),
        app: who.app,
        submitter: who.submitter,
        date: Number.isFinite(made) ? dayOf(made, flow.sprint.timeZone) : "unknown",
        days: Number.isFinite(made) ? Math.max(0, Math.floor((now.getTime() - made) / DAY)) : 0,
        stale: staleOf(i.created_at, now, sug.staleDays),
        excerpt: text,
        cut,
        untrusted: true,
      };
    });
  const approved = issues.filter((i) => at(i.state) === stateOf(sug, "unstarted") && !filed.has(keyOf(i.sequence_id)))
    .sort((a, b) => a.sequence_id - b.sequence_id)
    .map((i): Approved => ({ key: keyOf(i.sequence_id), app: submitterOf(i.name, sug.from).app }));
  return { project: sug.project, missing: false, waiting, approved };
}

/** The lines status prints for the inbox, after all its others. */
export function suggestionLines(s: SuggestionStatus, flow: DevFlow): string[] {
  const sug = flow.suggestions!;
  if (s.missing) return [`Suggestions: no inbox ${s.project} on the board yet: run bin/pronto connect plane`];
  return [
    `Suggestions waiting on the owner: ${s.waiting.length}`,
    ...s.waiting.map((w) => `  ${w.key}, ${w.app}, ${w.submitter}, ${w.date}${w.stale ? `, over ${sug.staleDays} days` : ""}, untrusted text: "${w.excerpt}${w.cut ? "…" : ""}"`),
    `Approved, to file: ${s.approved.length}${s.approved.length ? ` (${s.approved.map((a) => a.key).join(", ")})` : ""}`,
  ];
}

/** `approve`: files an inbox item the owner moved to Refine as an issue of the board, in Backlog, in
 * its app's module, labelled, its body a link to the item and none of its text; comments the issue's
 * key on the item. Run again it writes nothing; it finds its own issue by title, so a run that died
 * between the two writes is finished by the next. `{ok, message}`: not ok writes nothing. */
export async function approve(board: Board, flow: DevFlow, project: string, inbox: string | undefined, key: string): Promise<{ ok: boolean; message: string }> {
  const sug = inboxOf(flow);
  const refuse = (message: string) => ({ ok: false, message });
  if (!new RegExp(`^${sug.project}-[1-9][0-9]*$`).test(key)) return refuse(`${key} is not an item of the inbox ${sug.project} (${sug.project}-<n>)`);
  if (!inbox) return refuse(`no inbox ${sug.project} on the board yet: run bin/pronto connect plane`);
  const item = await board.issue(key);
  if (item.project !== inbox) return refuse(`${key} is not in the inbox ${sug.project}`);
  const state = (await board.states(inbox)).find((s) => s.id === item.state)?.name ?? "?";
  if (state !== stateOf(sug, "unstarted")) return refuse(`${key} is in ${state}: the owner approves a suggestion by moving it to ${stateOf(sug, "unstarted")}`);
  const { app } = submitterOf(item.name, sug.from);
  if (app === "unknown") return refuse(`${key} names no app that may file here (${sug.from.join(", ")})`);
  const mod = (await board.modules(project)).find((m) => m.name === app);
  if (!mod) return refuse(`the board has no module ${app}`);
  const id = flow.board.project.identifier;
  const title = suggestionTitle(app, key);
  let wrote = false;
  let made = (await board.issues(project, true)).find((i) => suggestionOf(i.name, sug.project)?.key === key);
  if (!made) {
    const backlog = (await board.states(project)).find((s) => s.name === flow.roles.backlog);
    if (!backlog) throw new Error(`no state ${flow.roles.backlog}: run bin/pronto connect plane`);
    const label = (await board.labels(project)).find((l) => l.name === sug.label) ?? await board.createLabel(project, sug.label, "#a3a3a3");
    const url = `https://${flow.board.host}/${flow.board.workspace}/browse/${key}/`;
    made = await board.createIssue(project, { name: title, description_html: `<p>Suggestion: <a href="${esc(url)}">${esc(key)}</a></p>`, priority: "none", state: backlog.id, labels: [label.id] });
    await board.addToModule(project, mod.id, [made.id]);
    wrote = true;
  } else if (!(await board.modulesByIssue(project)).get(made.id)?.includes(app)) {
    await board.addToModule(project, mod.id, [made.id]);
    wrote = true;
  }
  const filedAs = `${id}-${made.sequence_id}`;
  if (!(await board.comments(inbox, item.id)).some((c) => c.html.includes(`Filed as ${id}-`))) {
    await board.comment(inbox, item.id, `<p>Filed as ${esc(filedAs)}</p>`);
    wrote = true;
  }
  return { ok: true, message: wrote ? `${key} filed as ${filedAs}` : `${key} already filed as ${filedAs}` };
}

/** `connect plane`'s steps for the inbox, each a check then its apply, as connect.ts's own: the
 * project, its three states and its label. A second run checks all three done and writes nothing. */
export function inboxSteps(flow: DevFlow, need: () => Promise<Board>): Step[] {
  if (!flow.suggestions) return [];
  const gate = (why: string) => ({ gate: why });
  if (flow.board.kind !== "plane") return [{ name: `inbox ${flow.suggestions.project}`, check: () => Promise.resolve(gate("suggestions need a plane board")) }];
  const sug = flow.suggestions;
  const project = async (p: Board) => (await p.projects()).find((x) => x.identifier === sug.project);
  return [
    {
      name: `inbox project ${sug.project}`,
      check: async () => ((await project(await need())) ? { done: true as const, note: "" } : { todo: `create ${sug.name}` }),
      apply: async () => void (await (await need()).createProject(sug.name, sug.project)),
    },
    {
      name: "the inbox's states",
      check: async () => {
        const p = await need();
        const inbox = await project(p);
        if (!inbox) return { todo: "make the inbox first" };
        const have = await p.states(inbox.id);
        const bad = sug.states.filter((s) => have.find((h) => h.name === s.name)?.group !== s.group).map((s) => s.name);
        const first = have.find((h) => h.name === stateOf(sug, "backlog"));
        if (!bad.length && first && !first.default) bad.push(`${first.name} as the default`);
        return bad.length ? { todo: bad.join(", ") } : { done: true as const, note: sug.states.map((s) => s.name).join(", ") };
      },
      apply: async () => {
        const p = await need();
        const pid = (await project(p))!.id;
        const have = await p.states(pid);
        for (const s of sug.states) {
          const at = have.find((h) => h.name === s.name);
          if (!at) await p.createState(pid, { name: s.name, group: s.group, color: s.color, description: s.means });
          else if (at.group !== s.group) await p.updateState(pid, at.id, { group: s.group, color: s.color });
        }
        const first = (await p.states(pid)).find((h) => h.name === stateOf(sug, "backlog"));
        if (first && !first.default) await p.setDefaultState(pid, first.id);
      },
    },
    {
      name: `label ${sug.label} in the inbox`,
      check: async () => {
        const p = await need();
        const inbox = await project(p);
        if (!inbox) return { todo: "make the inbox first" };
        return (await p.labels(inbox.id)).some((l) => l.name === sug.label) ? { done: true as const, note: "" } : { todo: "create it" };
      },
      apply: async () => {
        const p = await need();
        await p.createLabel((await project(p))!.id, sug.label, "#a3a3a3");
      },
    },
  ];
}
