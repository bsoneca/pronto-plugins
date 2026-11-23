// pronto-lessons' step engine: pure, no DOM, no network (lessons/README.md). A lesson is one chapter of a course's
// part played on an opaque board that the app's adapter owns:
//
//   adapter = { start(), legal(board, gesture), token(gesture), apply(board, token), render(board) }
//
// `start()` is the board before any ply; `legal` says whether a gesture may be tried at all; `token(gesture)` is the
// move's token (what the chapter's `moves` hold, compared as strings); `apply` returns the board after a token,
// never changing the one it was given (so a take-back is keeping the old one); `render` draws a board.
//
// State: { step, wrongs, step_wrongs, done }. `step` is the ply the next move is expected at (an index of
// chapter.moves); `wrongs` counts every wrong move of the chapter, `step_wrongs` those at this step. The server row
// holds the same three numbers, so the complaint a wrong move gets survives a reload.

const enc = new TextEncoder();

/** FNV-1a, 32 bits, of the text's UTF-8 bytes: h = 2166136261; per byte h = ((h ^ b) * 16777619) mod 2^32. */
export function fnv1a(text) {
  let h = 0x811c9dc5;
  for (const b of enc.encode(text)) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return h;
}

/** mulberry32: a small deterministic PRNG, a function of a 32-bit seed giving floats in [0, 1). */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Cycle c's own shuffle: Fisher-Yates of 0..n-1 by mulberry32 seeded with seed XOR (c * 0x9e3779b1) mod 2^32.
function shuffle(seed, n, cycle) {
  const rand = mulberry32((seed ^ Math.imul(cycle, 0x9e3779b1)) >>> 0);
  const p = Array.from({ length: n }, (_, i) => i);
  for (let i = n - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [p[i], p[j]] = [p[j], p[i]];
  }
  return p;
}

/**
 * The permutation of 0..n-1 that the pool's picks of cycle `cycle` follow (pool picks 0..n-1 are cycle 0, n..2n-1
 * cycle 1, ...). Each cycle is its own shuffle, so no line repeats until all n were said. The boundary is fixed so that
 * none is said twice in a row across a wrap: when cycle c's first would equal cycle c-1's (already fixed) last, its
 * first two places are swapped (the second differs from the first, so the new first differs from that last). For
 * n >= 3 only the first two places ever change, so a cycle's last is the shuffle's own; for n = 2 the swap moves the
 * last too, which the next cycle's check then reads (it always compares with the fixed cycle before it).
 * Deterministic: seed, n and cycle alone decide.
 */
export function permutation(seed, n, cycle = 0) {
  let p = shuffle(seed, n, 0);
  for (let c = 1; c <= cycle; c++) {
    const last = p[n - 1];
    p = shuffle(seed, n, c);
    if (n > 1 && p[0] === last) [p[0], p[1]] = [p[1], p[0]];
  }
  return p;
}

/**
 * The teacher's line for a wrong move: {line, pool}, `line` a #Line (one text per locale), `pool` whether it came from
 * the part's pool (the caller then counts it in `pool_said`). `step` is the ply, `stepWrongs` the wrong moves at this
 * ply counting this one (>= 1), `poolSaid` the pool lines said before this one in the chapter.
 * While the ply has its own `wrong` lines they come in order (the k-th wrong move at the ply says the k-th); then the
 * pool: pool[perm[poolSaid mod N]], perm = permutation(fnv1a(`${course.id}/${chapter.id}`), N, floor(poolSaid / N)).
 * Own lines do not advance `poolSaid`, so the pool's picks are consecutive whatever mixes in: none repeats until all N
 * were said, and none twice in a row, across wraps too.
 */
export function pick(course, part, chapter, step, stepWrongs, poolSaid) {
  const own = chapter.steps?.[step]?.wrong ?? [];
  if (stepWrongs >= 1 && stepWrongs <= own.length) return { line: own[stepWrongs - 1], pool: false };
  const pool = part.complaints;
  const n = pool.length;
  const perm = permutation(fnv1a(`${course.id}/${chapter.id}`), n, Math.floor(poolSaid / n));
  return { line: pool[perm[poolSaid % n]], pool: true };
}

/**
 * A lesson on a chapter. `state`, when given, is a server row's {step, wrongs, step_wrongs, pool_said}: the lesson
 * resumes there (after a reload). `server`, when given, is told of every judged move, `server.move(step, token)`; what
 * it returns is ignored here (the page hands the server's state to `reconcile`).
 * Methods: `state()`, `board()`, `expected()` (the token the player must play now, null when done),
 * `play(gesture)`, `reconcile(serverState)`.
 */
export function createLesson({ course, part, chapter, adapter, server, state }) {
  const moves = chapter.moves;
  const mine = (ply) => ply % 2 === part.player;
  let board = adapter.start();
  let s = { step: 0, wrongs: 0, step_wrongs: 0, pool_said: 0, done: false };

  // The scripted plies: the other side's replies, until it is the player's turn or the script ends.
  const script = () => {
    const said = [];
    while (s.step < moves.length && !mine(s.step)) board = adapter.apply(board, moves[s.step++]), said.push(moves[s.step - 1]);
    s.done = s.step >= moves.length;
    return said;
  };
  // Put the lesson at the server's state: the board from the script's tokens up to the step (the first `shown` plies
  // play whoever the server says), then forward to the player's turn, as a fresh lesson does.
  const adopt = (sv) => {
    const step = Math.min(Math.max(Number.isInteger(sv.step) ? sv.step : 0, chapter.shown), moves.length);
    board = adapter.start();
    for (let i = 0; i < step; i++) board = adapter.apply(board, moves[i]);
    s = { step, wrongs: sv.wrongs ?? 0, step_wrongs: sv.step_wrongs ?? 0, pool_said: sv.pool_said ?? 0, done: false };
    script();
    adapter.render(board);
  };
  adopt(state ?? s);

  return {
    state: () => ({ ...s }),
    board: () => board,
    expected: () => (s.done ? null : moves[s.step]),

    /** Judge a gesture: {kind: 'done' | 'illegal'}, {kind: 'right', say, replies, done} or {kind: 'wrong', line, tried, board}. */
    play(gesture) {
      if (s.done) return { kind: "done" };
      if (!adapter.legal(board, gesture)) return { kind: "illegal" };
      const token = adapter.token(gesture);
      const ply = s.step;
      server?.move(ply, token);
      if (token === moves[ply]) {
        board = adapter.apply(board, token);
        s.step++;
        s.step_wrongs = 0;
        const replies = script();
        adapter.render(board);
        return { kind: "right", say: chapter.steps?.[ply]?.say ?? null, replies, done: s.done };
      }
      s.wrongs++;
      s.step_wrongs++;
      const { line, pool } = pick(course, part, chapter, ply, s.step_wrongs, s.pool_said);
      if (pool) s.pool_said++;
      // The take-back: the board after the wrong move is only shown (`tried`); ours is the one before it.
      const tried = adapter.apply(board, token);
      return { kind: "wrong", line, tried, board };
    },

    /**
     * The server's state wins. The same step: its wrongs, step_wrongs and pool_said are adopted, the board stays. A
     * different step: the step is bounded to the script and to the plies after `shown`, the board is rebuilt from the
     * script's own tokens (start, then apply, not the moves the player tried) and played forward to the player's turn;
     * nothing is judged or counted and no move is sent.
     */
    reconcile(sv) {
      if (sv.step === s.step) {
        s = { ...s, wrongs: sv.wrongs ?? s.wrongs, step_wrongs: sv.step_wrongs ?? s.step_wrongs, pool_said: sv.pool_said ?? s.pool_said };
      } else adopt(sv);
      return { ...s };
    },
  };
}
