// An intent's runner (docs/intents.md): its steps in order, each checked; `plan` changes nothing,
// `connect` applies each step that is to do and checks it again, until a step waits on a person or
// every step is done. Run again, it starts where it stopped: a done step is checked, never redone.

/** What a step's check says: done, to do (the program's to apply), or waiting on a person. */
export type State = { done: true; note?: string } | { todo: string } | { gate: string };

export interface Step {
  name: string;
  check(): Promise<State>;
  /** Makes the step done. Absent for a step only a person can take. */
  apply?(): Promise<void>;
}

/** What one step came to. */
export interface Outcome {
  step: string;
  state: "done" | "applied" | "todo" | "gate" | "failed";
  note: string;
}

/** A step's check, a check that throws being a state of its own: failed, with why. */
async function checked(s: Step): Promise<State | { failed: string }> {
  try {
    return await s.check();
  } catch (e) {
    return { failed: (e as Error).message };
  }
}

/** Each step's state, changing nothing. */
export async function plan(steps: readonly Step[]): Promise<Outcome[]> {
  const out: Outcome[] = [];
  for (const s of steps) {
    const st = await checked(s);
    out.push("done" in st ? { step: s.name, state: "done", note: st.note ?? "" } : "todo" in st ? { step: s.name, state: "todo", note: st.todo } : "gate" in st ? { step: s.name, state: "gate", note: st.gate } : { step: s.name, state: "failed", note: st.failed });
  }
  return out;
}

/** The steps applied in order until one waits on a person, fails, or all are done. */
export async function connect(steps: readonly Step[], say: (o: Outcome) => void = () => {}): Promise<Outcome[]> {
  const out: Outcome[] = [];
  const tell = (o: Outcome) => (out.push(o), say(o), o);
  for (const s of steps) {
    const st = await checked(s);
    if ("failed" in st) { tell({ step: s.name, state: "failed", note: st.failed }); break; }
    if ("done" in st) { tell({ step: s.name, state: "done", note: st.note ?? "" }); continue; }
    if ("gate" in st) { tell({ step: s.name, state: "gate", note: st.gate }); break; }
    if (!s.apply) { tell({ step: s.name, state: "gate", note: st.todo }); break; }
    try {
      await s.apply();
    } catch (e) {
      tell({ step: s.name, state: "failed", note: (e as Error).message });
      break;
    }
    // Applied is not done until the check says so: a step that applied and is still to do failed.
    const after = await checked(s);
    if ("done" in after) { tell({ step: s.name, state: "applied", note: after.note ?? st.todo }); continue; }
    tell({ step: s.name, state: "gate" in after ? "gate" : "failed", note: "gate" in after ? after.gate : "failed" in after ? after.failed : `still to do after applying: ${after.todo}` });
    break;
  }
  return out;
}

/** Whether a run came to the end: every step done or applied. */
export const finished = (out: readonly Outcome[], steps: readonly Step[]) =>
  out.length === steps.length && out.every((o) => o.state === "done" || o.state === "applied");

/** What a run that stopped waits on, as its last words: the link to open, alone on its line,
 * where the step waiting on a person names one. */
export function waitingOn(out: readonly Outcome[]): string {
  const last = out.at(-1);
  const url = last?.state === "gate" ? /https:\/\/\S+/.exec(last.note)?.[0] : undefined;
  return url ? `\n${last!.step}: open this, then run the same command again.\n\n  ${url}\n` : "\nRun the same command again once the step above is done: it goes on from there.";
}

/** One line an outcome, as a terminal or the builder's conversation shows it. */
export function line(o: Outcome): string {
  const mark = { done: "✓", applied: "✓", todo: "·", gate: "→", failed: "✗" }[o.state];
  const verb = { done: "", applied: " (done now)", todo: "", gate: " — waiting on you", failed: " — failed" }[o.state];
  return `${mark} ${o.step}${verb}${o.note ? `: ${o.note}` : ""}`;
}
