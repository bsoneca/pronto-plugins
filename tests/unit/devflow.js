// A fake Plane for the suggestion inbox's cases (tests/unit/devflow_inbox.cue, namespace `inbox`): an
// in-memory Board built from a JSON seed that logs each write, so a case can say what a run wrote
// and that a second run wrote nothing. The code under test is devflow/suggestions.ts, on this Board.
import { approve, inboxSteps, inboxStatus, show, suggestionLines } from '../../devflow/suggestions.ts';
import * as run from '../../intents/run.ts';

const GROUPS = { Backlog: 'backlog', Todo: 'unstarted', 'In Progress': 'started', Done: 'completed', Cancelled: 'cancelled' };
const SPEC = [
  { name: 'Backlog', group: 'backlog', color: '#a3a3a3', means: 'a' },
  { name: 'Refine', group: 'unstarted', color: '#60a5fa', means: 'b' },
  { name: 'Ready', group: 'unstarted', color: '#3b82f6', means: 'c' },
  { name: 'Cancelled', group: 'cancelled', color: '#ef4444', means: 'd' },
];

/** The flow a repository with an inbox exports (only what the inbox's code reads). */
function flowOf(seed) {
  const flow = {
    board: { kind: seed.kind ?? 'plane', host: 'plane.example.com', workspace: 'acme', project: { name: 'acme', identifier: 'ACME' } },
    timeZone: 'America/Sao_Paulo',
    roles: { backlog: 'Backlog', refine: 'Refine', ready: 'Ready', cancelled: 'Cancelled' },
    states: SPEC,
  };
  if (seed.suggestions !== false) {
    flow.suggestions = {
      project: 'SUGEST', name: 'Suggestions', from: seed.from ?? ['aprende'], staleDays: 14, label: 'suggestion',
      states: [
        { name: 'Suggested', group: 'backlog', color: '#a3a3a3', means: 'x' },
        { name: 'Refine', group: 'unstarted', color: '#60a5fa', means: 'y' },
        { name: 'Cancelled', group: 'cancelled', color: '#ef4444', means: 'z' },
      ],
    };
  }
  return flow;
}

/** An in-memory Board of the seed: `inboxMade` (default true) makes the inbox project with its three
 * states (else it is absent, or with Plane's own five when `connect` makes it); `items` the inbox's
 * issues `{seq, state, title, html, created}`; `issues` the board's `{seq, name, state, module}`;
 * `modules` its modules; `failOnce` a write method that throws its first call (`issues` instead: the
 * inbox's list of issues, failing as Plane's 500 does, with a body); `failAfter` a method whose first
 * call does its work, writes included, then throws, as a lost answer does. Writes are logged. */
function boardOf(seed) {
  const log = [];
  let failing = seed.failOnce;
  let lost = seed.failAfter;
  let n = 0;
  const id = (p) => `${p}-${++n}`;
  const projects = [{ id: 'p-acme', name: 'acme', identifier: 'ACME' }];
  const states = { 'p-acme': SPEC.map((s) => ({ id: `s-acme-${s.name}`, name: s.name, group: s.group, color: s.color })) };
  const labels = { 'p-acme': [], 'p-sugest': [] };
  const modules = (seed.modules ?? ['aprende']).map((m) => ({ id: `m-${m}`, name: m }));
  const modIssues = {};
  const comments = {};
  const issues = { 'p-acme': [], 'p-sugest': [] };
  const addInbox = (withStates) => {
    projects.push({ id: 'p-sugest', name: 'Suggestions', identifier: 'SUGEST' });
    const names = withStates ? ['Suggested', 'Refine', 'Cancelled'] : Object.keys(GROUPS);
    states['p-sugest'] = names.map((name) => ({ id: `s-sugest-${name}`, name, group: GROUPS[name] ?? { Suggested: 'backlog', Refine: 'unstarted' }[name], color: '#000000', default: name === (withStates ? 'Suggested' : 'Backlog') }));
  };
  if (seed.inboxMade !== false) addInbox(true);
  for (const i of seed.issues ?? []) {
    issues['p-acme'].push({ id: `i-acme-${i.seq}`, name: i.name, sequence_id: i.seq, state: `s-acme-${i.state ?? 'Backlog'}`, priority: 'none', project: 'p-acme' });
    if (i.module) (modIssues[i.module] ??= []).push(`i-acme-${i.seq}`);
  }
  for (const i of seed.items ?? []) {
    issues['p-sugest'].push({ id: `i-sugest-${i.seq}`, name: i.title, sequence_id: i.seq, state: `s-sugest-${i.state ?? 'Suggested'}`, priority: 'none', description_html: i.html, created_at: i.created, project: 'p-sugest' });
    comments[`i-sugest-${i.seq}`] = (i.comments ?? []).map((html) => ({ html, at: i.created }));
  }
  const write = (what, ...rest) => {
    if (failing === what) { failing = null; throw new Error(`${what} failed once`); }
    log.push([what, ...rest].join(' '));
  };
  const light = (i, full) => (full ? { ...i } : { id: i.id, name: i.name, sequence_id: i.sequence_id, state: i.state, priority: i.priority });
  const byId = (p) => projects.find((x) => x.id === p);
  const sync = {
    projects: () => projects.map((p) => ({ ...p })),
    createProject: (name, identifier) => { write('createProject', identifier); addInbox(false); return { id: 'p-sugest', name }; },
    enableFeatures: () => {},
    states: (p) => (states[p] ?? []).map((s) => ({ ...s })),
    createState: (p, s) => { write('createState', s.name); states[p].push({ id: id('s'), name: s.name, group: s.group, color: s.color }); },
    updateState: (p, sid, f) => { write('updateState', sid); Object.assign(states[p].find((s) => s.id === sid), f); },
    setDefaultState: (p, sid) => { write('setDefaultState', states[p].find((s) => s.id === sid).name); for (const s of states[p]) s.default = s.id === sid; },
    labels: (p) => (labels[p] ?? []).map((l) => ({ ...l })),
    createLabel: (p, name) => { write('createLabel', name); const l = { id: id('l'), name }; labels[p].push(l); return l; },
    modules: () => modules.map((m) => ({ ...m })),
    addToModule: (_p, m, ids) => { write('addToModule', modules.find((x) => x.id === m).name); (modIssues[modules.find((x) => x.id === m).name] ??= []).push(...ids); },
    modulesByIssue: () => {
      const by = new Map();
      for (const [m, ids] of Object.entries(modIssues)) for (const i of ids) by.set(i, [...(by.get(i) ?? []), m]);
      return by;
    },
    issues: (p, l = false) => {
      if (p === 'p-sugest' && failing === 'issues') { failing = null; throw new Error('plane GET /workspaces/acme/projects/p-sugest/issues/?per_page=100: 500 {"secret":"the body"}'); }
      return (issues[p] ?? []).map((i) => light(i, !l));
    },
    issue: (key) => {
      for (const p of projects) {
        const hit = (issues[p.id] ?? []).find((i) => `${p.identifier}-${i.sequence_id}` === key);
        if (hit) return { ...hit };
      }
      throw new Error(`plane GET /workspaces/acme/issues/${key}/: 404 {"detail":"Not found."}`);
    },
    createIssue: (p, f) => {
      write('createIssue', f.name);
      const made = { id: id('i'), name: f.name, sequence_id: issues[p].length + 100, state: f.state, priority: f.priority, description_html: f.description_html, labels: f.labels, project: p };
      issues[p].push(made);
      return { ...made };
    },
    comment: (_p, iid, html) => { write('comment', iid); (comments[iid] ??= []).push({ html, at: '2026-11-16T00:00:00Z' }); },
    comments: (_p, iid) => (comments[iid] ?? []).map((c) => ({ ...c })),
  };
  // Each call answers as a board's does: late, and a failure as a rejection.
  const board = Object.fromEntries(Object.entries(sync).map(([k, f]) => [k, (...a) => Promise.resolve().then(() => {
    const r = f(...a);
    if (lost === k) { lost = null; throw new Error(`${k} answer lost`); }
    return r;
  })]));
  const take = () => log.splice(0, log.length);
  return { board, take, projects, states, issues, comments, modIssues, labels, byId, inboxId: () => projects.find((p) => p.identifier === 'SUGEST')?.id };
}

/** The inbox's status as `status` prints it: the JSON and its lines (null when the flow has no inbox). */
export async function status(seed, now) {
  const f = boardOf(seed);
  const flow = flowOf(seed);
  const names = (await f.board.issues('p-acme', true)).map((i) => i.name);
  const s = await inboxStatus(f.board, flow, f.inboxId(), names, new Date(now));
  return s && { ...s, lines: suggestionLines(s, flow) };
}

/** `suggestion`'s read of an item: what `show` answers. */
export async function shown(seed, key) {
  const f = boardOf(seed);
  return await show(f.board, flowOf(seed), f.inboxId(), key);
}

/** `approve` run `runs` times on the seed's board: each run's message (or the error it threw), its
 * writes, and, after the last, the issues of the board it made and the item's comments. */
export async function approveRuns(seed, key, runs = 1) {
  const f = boardOf(seed);
  const flow = flowOf(seed);
  const out = [];
  for (let r = 0; r < runs; r++) {
    let said;
    try {
      const a = await approve(f.board, flow, 'p-acme', f.inboxId(), key);
      said = { ok: a.ok, message: a.message };
    } catch (e) {
      said = { ok: false, message: `threw: ${e.message}` };
    }
    out.push({ ...said, writes: f.take() });
  }
  const item = await f.board.issue(key).catch(() => null);
  return {
    runs: out,
    filed: f.issues['p-acme'].filter((i) => i.sequence_id >= 100).map((i) => ({ name: i.name, body: i.description_html, labels: i.labels, state: i.state, priority: i.priority, modules: Object.entries(f.modIssues).filter(([, ids]) => ids.includes(i.id)).map(([m]) => m) })),
    comments: item ? (f.comments[item.id] ?? []).map((c) => c.html) : [],
  };
}

/** The inbox's connect steps run `runs` times: each run's outcomes (step: state) and writes. */
export async function connectRuns(seed, runs = 1) {
  const f = boardOf(seed);
  const flow = flowOf(seed);
  const steps = inboxSteps(flow, () => Promise.resolve(f.board));
  const out = [];
  for (let r = 0; r < runs; r++) {
    const o = await run.connect(steps);
    out.push({ states: Object.fromEntries(o.map((x) => [x.step, x.state])), writes: f.take() });
  }
  return { runs: out, projects: f.projects.map((p) => p.identifier), states: (f.states['p-sugest'] ?? []).map((s) => `${s.name}${s.default ? '*' : ''}`) };
}
