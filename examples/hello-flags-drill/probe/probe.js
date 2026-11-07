// pronto-probe's rules, pure (no IO): what a run's result does to the probe's state, which flag
// writes are suspects of a failure, and the durations the schema names. probe.ts is the driver.
// Cases: tests/unit/probe.cue.

// "15s", "5m", "250ms", "2h" in milliseconds.
export function parseDuration(text) {
  const m = /^(\d+)(ms|s|m|h)$/.exec(String(text));
  if (!m) throw new Error(`duration ${text}: like 250ms, 15s, 5m or 2h`);
  return Number(m[1]) * { ms: 1, s: 1000, m: 60000, h: 3600000 }[m[2]];
}

// The state before any run.
export const initial = () => ({ status: "ok", failures: 0, firstFailureAt: null, alertedAt: null });

// One run's result ({ok}) on the state at `now` (ISO text): the next state and the events it
// raises. opts.after is the consecutive failures that alert. A failure is `failing` until that
// many, then `alerting` (one probe.alert, not one per run); the first success after an alert
// raises probe.resolved with downFor in ms from the first failure, and a success before one
// quietly forgets the blip.
export function step(state, result, now, opts = {}) {
  const after = opts.after ?? 2;
  const s = state ?? initial();
  if (result.ok) {
    if (s.status === "alerting") {
      return { state: initial(), events: [{ event: "probe.resolved", at: now, firstFailureAt: s.firstFailureAt, failures: s.failures, downFor: Date.parse(now) - Date.parse(s.firstFailureAt) }] };
    }
    return { state: initial(), events: [] };
  }
  const failures = s.failures + 1;
  const firstFailureAt = s.firstFailureAt ?? now;
  if (s.status === "alerting") return { state: { ...s, failures }, events: [] };
  if (failures >= after) {
    return {
      state: { status: "alerting", failures, firstFailureAt, alertedAt: now },
      events: [{ event: "probe.alert", at: now, firstFailureAt, failures }],
    };
  }
  return { state: { status: "failing", failures, firstFailureAt, alertedAt: null }, events: [] };
}

// The flag writes of the journal (its lines, as text or parsed) in [firstFailureAt - windowMs,
// firstFailureAt] that changed a flag, newest first, each with the command that undoes it.
// A flip's final write replaces its own canary (stage "testers"): its undo goes back past the canary, to the
// version the flip started from.
export function suspects(journalLines, firstFailureAt, windowMs) {
  const end = Date.parse(firstFailureAt);
  const all = journalLines.map((l) => (typeof l === "string" ? parse(l) : l)).filter((w) => w && w.event === "flags.write");
  const byVersion = new Map(all.map((w) => [w.version, w]));
  const before = (w) => {
    let from = w.from;
    for (let c = byVersion.get(from); c && c.stage === "testers"; c = byVersion.get(from)) from = c.from;
    return from;
  };
  return all
    .filter((w) => w.flag && Date.parse(w.at) <= end && Date.parse(w.at) >= end - windowMs)
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
    .map((w) => {
      const to = before(w);
      return {
        at: w.at, flag: w.flag, version: w.version, from: to, who: w.who, commit: w.commit, changes: w.changes,
        rollback: to === "0" ? "" : `pronto-flags rollback <app-dir> ${to}`,
      };
    });
}

function parse(line) {
  try { return JSON.parse(line); } catch { return null; }
}
