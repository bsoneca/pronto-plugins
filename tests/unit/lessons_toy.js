// What the lessons suite's cases call (tests/unit/lessons.cue): a toy adapter whose board is the string of the tokens
// applied, courses built from the shape of lessons/schema.cue, and probes of the engine's complaint sequence and of the
// schema's refusals (`cue vet` on a changed copy of lessons/example.cue).
import { createLesson, fnv1a, pick } from "../../lessons/app/lessons.js";

const root = new URL("../../", import.meta.url).pathname;
const line = (text) => ({ en: text });

/** The toy adapter: a board is the applied tokens joined by spaces; a gesture is its own token; every gesture is legal. */
export const adapter = { start: () => "", legal: () => true, token: (g) => g, apply: (b, t) => (b ? `${b} ${t}` : t), render() {} };

/** A course of one part (player 0) and one chapter: `moves`, `shown`, own wrong lines by ply, a pool of n complaints. */
export function course(n, moves = ["a1", "b1", "a2", "b2", "a3"], shown = 0, wrong = {}, id = "crs") {
  const steps = {};
  for (const [ply, texts] of Object.entries(wrong)) steps[ply] = { wrong: texts.map(line) };
  const chapter = { id: "ch", moves, shown, claim: "x", steps };
  const part = { id: "p", player: 0, complaints: Array.from({ length: n }, (_, i) => line(`c${i}`)), chapters: [chapter] };
  return { id, parts: [part] };
}

/** A lesson on the toy course, resumed at `state` when given. */
export function lesson(n, moves, shown, wrong, id, state) {
  const c = course(n, moves, shown, wrong, id);
  return createLesson({ course: c, part: c.parts[0], chapter: c.parts[0].chapters[0], adapter, state });
}

/** Play gestures in order; the state, the board and the kinds of the results. */
export function run(n, moves, shown, gestures, wrong) {
  const l = lesson(n, moves, shown, wrong);
  const kinds = gestures.map((g) => l.play(g)).map((r) => r.kind);
  return { state: l.state(), board: l.board(), kinds };
}

/** Wrong moves at the first step, one by one: the lines said, in order, the board shown after the last, and ours after. */
export function wrongs(n, count, wrong) {
  const l = lesson(n, undefined, 0, wrong);
  const said = [];
  let tried;
  for (let i = 0; i < count; i++) {
    const r = l.play("zz");
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
export function mixedReport(n, wraps, seed) {
  const moves = Array.from({ length: 2 * (wraps * n + 2) }, (_, i) => `${i % 2 ? "b" : "a"}${i}`);
  const own = { 0: ["o0", "o0b"], 4: ["o4"], 10: ["o10", "o10b", "o10c"], 14: ["o14"] };
  const l = lesson(n, moves, 0, own, `crs${seed}`);
  const said = [];
  for (let k = 0; !l.state().done; k++) {
    for (let w = 0; w < 1 + ((k + seed) % 4); w++) said.push(l.play("zz").line.en);
    l.play(l.expected());
  }
  const pool = said.filter((x) => x.startsWith("c"));
  return { ...report(pool.slice(0, wraps * n), n), enough: pool.length >= wraps * n, usedOwn: said.some((x) => x.startsWith("o")) };
}

/** A stale step: the server's state against a lesson (`shown` plies shown) that played `played` right moves. */
export function reconcile(played, server, shown = 0) {
  const l = lesson(8, undefined, shown);
  played.forEach((g) => l.play(g));
  const before = l.board();
  const out = l.reconcile(server);
  return { out, state: l.state(), board: l.board(), boardBefore: before, expected: l.expected() };
}

/** A lesson resumed at a server row's state, as after a reload, then one wrong move. */
export function resume(initial) {
  const l = lesson(8, undefined, 0, undefined, undefined, initial);
  const before = { state: l.state(), board: l.board(), expected: l.expected() };
  return { ...before, line: l.play("zz").line.en, after: l.state() };
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
