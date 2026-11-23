// What the lessons suite's cases call (tests/unit/lessons.cue): a toy adapter whose board is the string of the tokens
// applied, courses built from the shape of lessons/schema.cue, and probes of the engine's complaint sequence and of the
// schema's refusals (`cue vet` on a changed copy of lessons/example.cue).
import { createLesson, fnv1a, pick } from "../../lessons/app/lessons.js";

const root = new URL("../../", import.meta.url).pathname;
const line = (text) => ({ en: text });

/** The toy adapter: a board is the applied tokens joined by spaces; a gesture is its own token; every gesture is legal. */
export const adapter = { start: () => "", legal: () => true, token: (g) => g, apply: (b, t) => (b ? `${b} ${t}` : t), render() {} };


/** A course of one part (player 0) and one chapter: `plies` (the script's length, never its moves), `shown`, own wrong lines by ply, a pool of n complaints. */
export function course(n, plies = 5, shown = 0, wrong = {}, id = "crs") {
  const steps = {};
  for (const [ply, texts] of Object.entries(wrong)) steps[ply] = { wrong: texts.map(line) };
  const chapter = { id: "ch", plies, shown, claim: "x", steps };
  const part = { id: "p", player: 0, complaints: Array.from({ length: n }, (_, i) => line(`c${i}`)), chapters: [chapter] };
  return { id, parts: [part] };
}

const SCRIPT = ["a1", "b1", "a2", "b2", "a3"];

/**
 * The database's judgement as lessons.sql makes it, for the script `moves` (the player moves the plies of parity `player`),
 * `own` wrong lines per ply: `row()` is the row as lessons.view returns it (`played` the plies up to the step), `move(step,
 * token)` a promise of the row after a move. `at` is a row to stand at instead of the chapter's start. With `gate`, a move
 * waits for `gate.release()` before it answers.
 */
export function fakeServer(moves = SCRIPT, shown = 0, own = {}, at, gate) {
  const player = 0;
  const advance = (p) => {
    while (p < moves.length && p % 2 !== player) p++;
    return p;
  };
  let r = at ?? { step: advance(shown), wrongs: 0, step_wrongs: 0, pool_said: 0 };
  const row = () => ({ ...r, over: r.step >= moves.length, played: moves.slice(0, r.step) });
  return {
    row,
    async move(step, token) {
      await gate?.promise;
      if (step !== r.step || r.step >= moves.length) return row();
      if (token === moves[step]) r = { ...r, step: advance(step + 1), step_wrongs: 0 };
      else r = { ...r, wrongs: r.wrongs + 1, step_wrongs: r.step_wrongs + 1, pool_said: r.pool_said + (r.step_wrongs + 1 > (own[step]?.length ?? 0) ? 1 : 0) };
      return row();
    },
  };
}

/** A lesson on the toy course, and the server it asks (on `moves`, resumed at the row `state` when given). */
export function lesson(n, moves = SCRIPT, shown = 0, wrong, id, state, gate) {
  const c = course(n, moves.length, shown, wrong, id);
  const server = fakeServer(moves, shown, wrong ?? {}, state, gate);
  const l = createLesson({ course: c, part: c.parts[0], chapter: c.parts[0].chapters[0], adapter, server, state: server.row() });
  return { l, server };
}

/** Play gestures in order; the state, the board and the kinds of the results. */
export async function run(n, moves, shown, gestures, wrong) {
  const { l } = lesson(n, moves, shown, wrong);
  const kinds = [];
  for (const g of gestures) kinds.push((await l.play(g)).kind);
  return { state: l.state(), board: l.board(), kinds };
}

/** Wrong moves at the first step, one by one: the lines said, in order, the board shown after the last, and ours after. */
export async function wrongs(n, count, wrong) {
  const { l } = lesson(n, undefined, 0, wrong);
  const said = [];
  let tried;
  for (let i = 0; i < count; i++) {
    const r = await l.play("zz");
    said.push(r.line.en);
    tried = r.tried;
  }
  return { said, tried, board: l.board(), state: l.state() };
}

/** The pool's complaints for pool picks 0..count-1 on the toy course, as text. */
export function sequence(n, count) {
  const c = course(n);
  const part = c.parts[0];
  return Array.from({ length: count }, (_, i) => pick(c, part, part.chapters[0], 0, 1, i).line.en);
}

const report = (a, n) => ({
  count: a.length,
  cyclesComplete: Array.from({ length: Math.floor(a.length / n) }, (_, c) => new Set(a.slice(c * n, (c + 1) * n)).size).every((size) => size === n),
  noneTwiceInARow: a.every((x, i) => i === 0 || x !== a[i - 1]),
});

/** The pool's sequence over `wraps` wraps: each cycle holds every line once and none repeats in a row. */
export function sequenceReport(n, wraps) {
  return report(sequence(n, n * wraps), n);
}

/**
 * The pool's lines said by a real lesson in which wrong moves at plies with their own lines mix with wrong moves at
 * plies without, for the course seed `seed`: each step gets 1 to 4 wrong moves. Only the pool's lines (c0..) count.
 */
export async function mixedReport(n, wraps, seed) {
  const moves = Array.from({ length: 2 * (wraps * n + 2) }, (_, i) => `${i % 2 ? "b" : "a"}${i}`);
  const own = { 0: ["o0", "o0b"], 4: ["o4"], 10: ["o10", "o10b", "o10c"], 14: ["o14"] };
  const { l } = lesson(n, moves, 0, own, `crs${seed}`);
  const said = [];
  for (let k = 0; !l.state().done; k++) {
    for (let w = 0; w < 1 + ((k + seed) % 4); w++) said.push((await l.play("zz")).line.en);
    await l.play(moves[l.state().step]);
  }
  const pool = said.filter((x) => x.startsWith("c"));
  return { ...report(pool.slice(0, wraps * n), n), enough: pool.length >= wraps * n, usedOwn: said.some((x) => x.startsWith("o")) };
}

/** A lesson resumed at the server's row (step, counters; `played` is what the server says), then one wrong move at that step. */
export async function resume(initial) {
  const { l } = lesson(8, undefined, 0, undefined, undefined, initial);
  const before = { state: l.state(), board: l.board() };
  return { ...before, line: (await l.play("zz")).line.en, after: l.state() };
}

/** A stale page: the server went on to `step` (another tab played), then this page reconciles to its row, or plays a move. */
export async function stale(serverMoves, gesture) {
  const { l, server } = lesson(8);
  for (const [step, token] of serverMoves) await server.move(step, token);
  const before = { state: l.state(), board: l.board() };
  if (gesture === undefined) return { before, out: l.reconcile(server.row()), state: l.state(), board: l.board() };
  const r = await l.play(gesture);
  return { before, kind: r.kind, state: l.state(), board: l.board() };
}

/** A move in flight: the lesson's answers to a second gesture while the first waits, and its state once the first is answered. */
export async function inflight() {
  let release;
  const gate = { promise: new Promise((r) => (release = r)) };
  const { l } = lesson(8, undefined, 0, undefined, undefined, undefined, gate);
  const first = l.play("a1");
  const during = { busy: l.busy(), second: (await l.play("a2")).kind, board: l.board() };
  release();
  const answered = await first;
  return { during, first: answered.kind, replies: answered.replies, after: { busy: l.busy(), state: l.state(), board: l.board() } };
}

/** A reconcile that lands while a move is out (a row of another tab at step 4): the move's answer is shown as the server's row, not applied on the reconciled board. */
export async function reconcileDuring() {
  let release;
  const gate = { promise: new Promise((r) => (release = r)) };
  const { l } = lesson(8, undefined, 0, undefined, undefined, undefined, gate);
  const first = l.play("a1");
  l.reconcile({ step: 4, wrongs: 0, step_wrongs: 0, pool_said: 0, over: false, played: SCRIPT.slice(0, 4) });
  const during = { state: l.state(), board: l.board() };
  release();
  const answered = await first;
  return { during, kind: answered.kind, state: l.state(), board: l.board() };
}

/** A failed call: the error's text, and that the lesson is as it was and not busy. */
export async function failed() {
  const c = course(8);
  const server = { move: () => Promise.reject(new Error("offline")) };
  const l = createLesson({ course: c, part: c.parts[0], chapter: c.parts[0].chapters[0], adapter, server, state: fakeServer().row() });
  const before = { state: l.state(), board: l.board() };
  let error;
  try {
    await l.play("a1");
  } catch (e) {
    error = e.message;
  }
  return { error, busy: l.busy(), same: JSON.stringify(before) === JSON.stringify({ state: l.state(), board: l.board() }) };
}

export { fnv1a };

// The schema's refusals: the example's JSON changed in one way, vetted as a #Course by the module's cue.
// Every key `from` of the object and its children renamed `to`: a locale spelt another way, in the course's list and in every line.
const rename = (o, from, to) => {
  if (Array.isArray(o)) o.forEach((v, i) => (typeof v === 'string' && v === from ? (o[i] = to) : rename(v, from, to)));
  else if (o && typeof o === 'object') for (const k of Object.keys(o)) {
    rename(o[k], from, to);
    if (k === from) { o[to] = o[k]; delete o[k]; }
  }
};

const mutations = {
  none: () => {},
  badLocale: (c) => rename(c, 'es', 'ES'),
  longLocale: (c) => rename(c, 'es', 'esp'),
  regionLocale: (c) => rename(c, 'es', 'es-MX'),
  dropTranslation: (c) => delete c.parts[0].chapters[0].intro["pt-BR"],
  extraLocale: (c) => (c.parts[0].chapters[0].outro.fr = "x"),
  shortPool: (c) => c.parts[0].complaints.pop() && c.parts[0].complaints.pop(),
  shownBeyondMoves: (c) => (c.parts[0].chapters[0].shown = 9),
  badPlayer: (c) => (c.parts[0].player = 2),
  emptyTranslation: (c) => (c.parts[0].chapters[0].intro.en = ""),
  identicalPool: (c) => c.parts[0].complaints.forEach((l) => (l.en = "same")),
  noPlayerPly: (c) => ((c.parts[0].chapters[0].moves = ["a1", "b1", "a2", "b2"]), (c.parts[0].chapters[0].shown = 3)),
  shownAtEnd: (c) => (c.parts[0].chapters[0].shown = 5),
  stepBeyondMoves: (c) => (c.parts[0].chapters[0].steps["6"] = { wrong: [c.parts[0].chapters[0].intro] }),
  stepZeroPadded: (c) => (c.parts[0].chapters[0].steps["00"] = { wrong: [c.parts[0].chapters[0].intro] }),
  stepOnOtherSide: (c) => (c.parts[0].chapters[0].steps["1"] = { wrong: [c.parts[0].chapters[0].intro] }),
  // PRONTO-1736: no line read before a ply names that ply's token (the example's player moves plies 0, 2 and 4: a1, a2, a3).
  introNamesFirst: (c) => (c.parts[0].chapters[0].intro.en = "Begin with a1."),
  introNamesLater: (c) => (c.parts[0].chapters[0].intro["pt-BR"] = "Depois jogue a3."),
  sayNamesNext: (c) => (c.parts[0].chapters[0].steps["2"].say.es = "Bien, ahora a3."),
  sayNamesOwnPly: (c) => (c.parts[0].chapters[0].steps["2"].say.en = "That was a2."),
  wrongNamesOwnPly: (c) => (c.parts[0].chapters[0].steps["2"].wrong[0].en = "Look at a2."),
  complaintNamesToken: (c) => (c.parts[0].complaints[3].en = "Not that, a3 (4)."),
  introNamesOtherSideToken: (c) => (c.parts[1].chapters[0].intro.en = "Defend with b2."),
  duplicateChapterAcrossParts: (c) => (c.parts[1].chapters[0].id = "one"),
  duplicateChapterWithinPart: (c) => c.parts[0].chapters.push({ ...c.parts[0].chapters[0] }),
};

/** Whether `cue vet -c` accepts the example changed by the named mutation, in a copy of the package in a temp dir. */
export function vets(name) {
  const cue = Deno.env.get("CUE") ?? "cue";
  const run = (args, cwd) => new Deno.Command(cue, { args, cwd, stdout: "piped", stderr: "piped" }).outputSync();
  const out = run(["export", "./lessons", "-e", "example", "--out", "json"], root);
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  const course = JSON.parse(new TextDecoder().decode(out.stdout));
  mutations[name](course);
  const dir = Deno.makeTempDirSync();
  try {
    Deno.mkdirSync(`${dir}/cue.mod`);
    Deno.copyFileSync(`${root}cue.mod/module.cue`, `${dir}/cue.mod/module.cue`);
    Deno.copyFileSync(`${root}lessons/schema.cue`, `${dir}/schema.cue`);
    Deno.writeTextFileSync(`${dir}/bad.cue`, `package lessons\nbad: #Course & ${JSON.stringify(course)}\n`);
    return run(["vet", "-c", "."], dir).success;
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
}
