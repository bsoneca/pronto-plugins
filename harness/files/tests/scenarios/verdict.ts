// The verdict of one scenarios run, as data: tests/scenarios.ts writes it to the file SCENARIOS_VERDICT names (when set),
// and whoever runs it (a rehearsal's passes) reads it back from here, never from the human summary line, whose wording is
// free to change. A file that is missing or does not have this shape is no verdict.
export type Verdict = {
  passed: number; // scenarios this run ran and passed
  cached: number; // scenarios skipped because the same tree already passed them
  byOtherLane: number; // scenarios of its selection another lane of a shared queue ran
  skipped: number; // scenarios not run for want of what they need
  failed: number; // scenarios this run ran and failed
  failedIds: string[]; // their ids (a step that failed or a page that threw), so a caller judges each one
};

const keys: (keyof Verdict)[] = ["passed", "cached", "byOtherLane", "skipped", "failed"];

export const parseVerdict = (text: string): Verdict => {
  const v = JSON.parse(text);
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new Error("a verdict is a JSON object");
  for (const k of keys) {
    if (!Number.isInteger(v[k]) || v[k] < 0) throw new Error(`verdict.${k} is not a count: ${JSON.stringify(v[k])}`);
  }
  if (!Array.isArray(v.failedIds) || v.failedIds.length !== v.failed || !v.failedIds.every((x: unknown) => typeof x === "string")) throw new Error(`verdict.failedIds is not the ${v.failed} failed ids: ${JSON.stringify(v.failedIds)}`);
  return { ...Object.fromEntries(keys.map((k) => [k, v[k]])), failedIds: v.failedIds } as Verdict;
};

export const writeVerdict = (path: string, v: Verdict) => Deno.writeTextFileSync(path, JSON.stringify(v) + "\n");

// Throws when the file is missing, unreadable or malformed.
export const readVerdict = async (path: string): Promise<Verdict> => parseVerdict(await Deno.readTextFile(path));

// How one close ended (a context's, the browser's): finished, rejected by Playwright (its first line kept) or still pending after the wait. The
// three are kept apart: a rejected close is a failure the runner reports, not a close that finished, and a timeout is not a rejection.
export type Closing = { state: "closed" } | { state: "rejected"; error: string } | { state: "timeout" };

export const closing = async (p: Promise<unknown>, ms: number): Promise<Closing> => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<Closing>((r) => { timer = setTimeout(() => r({ state: "timeout" }), ms); });
  // Both outcomes of `p` are handled here, so a close that settles after the wait is no unhandled rejection.
  const done = p.then((): Closing => ({ state: "closed" }), (e): Closing => ({ state: "rejected", error: String((e as Error)?.message ?? e).split("\n")[0] }));
  try { return await Promise.race([done, late]); } finally { clearTimeout(timer); }
};

// What the run reports and records once every scenario has run and the browser has been closed: the failed ids, and the green ones the selector
// records. One set serves the verdict, the summary and the record, so they cannot disagree. A browser that did not close cleanly (rejected, or
// still open after the wait) fails every scenario that ran: nothing is recorded green from it, and the old green records of all of them are
// invalidated (the selector deletes only the ids it is told failed). A scenario whose page threw counts as failed; any page error records no green.
export const settleRun = (o: { ran: string[]; failed: string[]; pageErrorIds: string[]; pageErrors: string[]; browser: Closing }) => {
  const failedAll = new Set([...o.failed, ...o.pageErrorIds.filter((id) => o.ran.includes(id))]);
  if (o.browser.state !== "closed") for (const id of o.ran) failedAll.add(id);
  const green = o.browser.state !== "closed" || o.pageErrors.length ? [] : o.ran.filter((id) => !failedAll.has(id));
  return { failedAll, green };
};
