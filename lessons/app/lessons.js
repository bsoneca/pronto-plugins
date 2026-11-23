// pronto-lessons' step engine: pure, no DOM, no network (lessons/README.md). A lesson is one chapter of a course's
// part played on an opaque board that the app's adapter owns:
//
//   adapter = { start(), legal(board, gesture), token(gesture), apply(board, token), render(board) }
//
// `start()` is the board before any ply; `legal` says whether a gesture may be tried at all; `token(gesture)` is the
// move's token (an opaque string the server compares); `apply` returns the board after a token, never changing the one
// it was given (so a take-back is keeping the old one); `render` draws a board.
//
// The page holds no answer: the chapter it is given has `plies` (how many the script has) and `shown`, never the moves,
// and the server judges every move (`server.move(step, token)`, a promise of the row as lessons.view makes it). The row's
// `played` is the plies on the board so far, the player's and the other side's replies, up to its `step`.
//
// State: { step, wrongs, step_wrongs, pool_said, done }. `step` is the ply the next move is expected at (an index into
// the script); `wrongs` counts every wrong move of the chapter, `step_wrongs` those at this step. They are the row's, so
// the complaint a wrong move gets survives a reload.

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
 * A lesson on a chapter, resumed at `state`, a server row ({step, wrongs, step_wrongs, pool_said, over, played}, as
 * lesson_start and lesson_move return it). `server.move(step, token)` returns a promise of the row after the move.
 * Methods: `state()`, `board()`, `busy()`, `play(gesture)` (async), `reconcile(row)`.
 */
export function createLesson({ course, part, chapter, adapter, server, state }) {
  let board = adapter.start();
  let s = { step: 0, wrongs: 0, step_wrongs: 0, pool_said: 0, done: false };
  let inflight = false;

  // Put the lesson at the server's row: the board from the plies it says were played, the counters its own.
  const adopt = (row) => {
    board = adapter.start();
    for (const token of row.played ?? []) board = adapter.apply(board, token);
    s = { step: row.step ?? 0, wrongs: row.wrongs ?? 0, step_wrongs: row.step_wrongs ?? 0, pool_said: row.pool_said ?? 0, done: row.over === true };
    adapter.render(board);
  };
  adopt(state ?? {});

  return {
    state: () => ({ ...s }),
    board: () => board,
    busy: () => inflight,

    /**
     * Send a gesture to the server and show its answer: {kind: 'busy' | 'done' | 'illegal'} without asking it (a move in
     * flight makes the next one busy, a finished chapter is done), else {kind: 'right', say, replies, done},
     * {kind: 'wrong', line, tried, board} or {kind: 'stale'}. Right: the move and the replies from the row's `played`
     * are applied. Wrong: the board stays (`tried` is the one after the move, only to be shown), the counters are the
     * server's. Stale: the move was at another step than the server's, nothing is judged and the server's row is adopted.
     * A failed call throws, the lesson as it was.
     */
    async play(gesture) {
      if (inflight) return { kind: "busy" };
      if (s.done) return { kind: "done" };
      if (!adapter.legal(board, gesture)) return { kind: "illegal" };
      const token = adapter.token(gesture);
      const ply = s.step;
      inflight = true;
      let row;
      try {
        row = await server.move(ply, token);
      } finally {
        inflight = false;
      }
      const played = row.played ?? [];
      if (row.step > ply && played[ply] === token) {
        const replies = played.slice(ply + 1, row.step);
        board = adapter.apply(board, token);
        for (const reply of replies) board = adapter.apply(board, reply);
        s = { step: row.step, wrongs: row.wrongs, step_wrongs: row.step_wrongs, pool_said: row.pool_said, done: row.over === true };
        adapter.render(board);
        return { kind: "right", say: chapter.steps?.[ply]?.say ?? null, replies, done: s.done };
      }
      if (row.step !== ply) {
        adopt(row);
        return { kind: "stale" };
      }
      // Wrong: the server counted it, so the line comes from its counters (a pool line was said when step_wrongs went past the ply's own).
      const own = chapter.steps?.[ply]?.wrong?.length ?? 0;
      const pool = row.step_wrongs > own;
      const { line } = pick(course, part, chapter, ply, row.step_wrongs, row.pool_said - (pool ? 1 : 0));
      s = { ...s, wrongs: row.wrongs, step_wrongs: row.step_wrongs, pool_said: row.pool_said };
      // The take-back: the board after the wrong move is only shown (`tried`); ours is the one before it.
      return { kind: "wrong", line, tried: adapter.apply(board, token), board };
    },

    /** The server's row wins: the same step adopts its counters and keeps the board, another rebuilds the board from its `played`. */
    reconcile(row) {
      if (row.step === s.step) s = { ...s, wrongs: row.wrongs ?? s.wrongs, step_wrongs: row.step_wrongs ?? s.step_wrongs, pool_said: row.pool_said ?? s.pool_said, done: row.over === true };
      else adopt(row);
      return { ...s };
    },
  };
}
