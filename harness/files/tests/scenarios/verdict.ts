// The verdict of one scenarios run, as data: tests/scenarios.ts writes it to the file SCENARIOS_VERDICT names (when set),
// and whoever runs it (a rehearsal's passes) reads it back from here, never from the human summary line, whose wording is
// free to change. A file that is missing or does not have this shape is no verdict.
export type Verdict = {
  passed: number; // scenarios this run ran and passed
  cached: number; // scenarios skipped because the same tree already passed them
  byOtherLane: number; // scenarios of its selection another lane of a shared queue ran
  skipped: number; // scenarios not run for want of what they need
  failed: number; // scenarios this run ran and failed
};

const keys: (keyof Verdict)[] = ["passed", "cached", "byOtherLane", "skipped", "failed"];

export const parseVerdict = (text: string): Verdict => {
  const v = JSON.parse(text);
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new Error("a verdict is a JSON object");
  for (const k of keys) {
    if (!Number.isInteger(v[k]) || v[k] < 0) throw new Error(`verdict.${k} is not a count: ${JSON.stringify(v[k])}`);
  }
  return Object.fromEntries(keys.map((k) => [k, v[k]])) as Verdict;
};

export const writeVerdict = (path: string, v: Verdict) => Deno.writeTextFileSync(path, JSON.stringify(v) + "\n");

// Throws when the file is missing, unreadable or malformed.
export const readVerdict = async (path: string): Promise<Verdict> => parseVerdict(await Deno.readTextFile(path));
