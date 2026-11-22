// prod-watch's cursor runs (prod-watch/prod-watch.ts) on a fake log: each run reads the entries after the cursor (strictly, as Cloud Logging does)
// up to `to`, cut at `cap` entries as the driver cuts a read at its limit, settles them with the cursor it started from, and writes the cursor as
// JSON; the next run starts from that. `counts` is how many times each entry was counted over all the runs.
import { countedOf, cursorOf, settleRun, timeAfter } from '../../prod-watch/watch.js';

export function reads({ entries, runs, lag = 300000, first = '2026-11-19T00:00:00.000Z' }) {
  let cursor = null;
  const counts = {}, committed = [];
  for (const r of runs) {
    const from = cursor?.at ?? first;
    let got = entries.filter((e) => timeAfter(e.ts, from) && !timeAfter(e.ts, r.to)).sort((a, b) => (timeAfter(a.ts, b.ts) ? 1 : -1));
    let reached = r.to;
    if (r.cap && got.length > r.cap - 1) {
      // cut at the limit: the entries of the last timestamp may go on past it, so they are left for the next run whole
      got = got.slice(0, r.cap);
      const last = got[got.length - 1].ts;
      got = got.filter((e) => timeAfter(last, e.ts));
      reached = got[got.length - 1].ts;
    }
    const wire = got.map((e) => ({ timestamp: e.ts, resource: { type: 'cloud_run_revision' } }));
    const settled = settleRun({ entries: wire, hashes: got.map((e) => e.h), counted: countedOf(cursor), reached, to: r.to, lag, cursor: cursor?.at });
    for (let i = 0; i < settled.entries.length; i++) {
      const h = got[wire.indexOf(settled.entries[i])].h;
      counts[h] = (counts[h] ?? 0) + 1;
    }
    cursor = JSON.parse(JSON.stringify(cursorOf(settled)));
    committed.push(cursor.at);
  }
  return { counts, committed };
}

// The older watcher's reader: `seen` into a Set, looked up by string hash.
export const baseSees = (cursor, hash) => new Set(cursor.seen).has(hash);
