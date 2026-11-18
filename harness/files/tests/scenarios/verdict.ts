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
