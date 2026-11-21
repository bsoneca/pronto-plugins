// Whether a scenario's step runs here, asked in this order: its place first (`on`: a step for production
// alone, or for a stack at hand alone), then a value an earlier step kept (`ifKept`), then its flags
// (`unless`, `flag`), so a step for another place never asks the door anything on its behalf: a
// production flip's run sends no OFREP request for a local step. `flagOn` is the run's own question
// to the door. `flip` is the flag a flip tests (FLAG, with FLAGS_TESTER): its steps run, and the
// runner checks it for the tester itself. At hand is a stack on this machine: a deployed preview is neither
// (PRONTO-873: a database step there would fail the run).
export type Place = "production" | "local" | "deployed";
export type Gated = { on?: "production" | "local"; ifKept?: string; unless?: string; flag?: string };
export type Here = { place: Place; kept: (name: string) => string | undefined; flip?: string };
export type Gate = { run: boolean; flip?: boolean; onHere?: string; off?: string };

export async function stepGate(st: Gated, here: Here, flagOn: (flag: string) => Promise<boolean>): Promise<Gate> {
  if (st.on === "production" && here.place !== "production") return { run: false };
  if (st.on === "local" && here.place !== "local") return { run: false };
  if (st.ifKept && ["", "undefined", "null"].includes(here.kept(st.ifKept) ?? "")) return { run: false };
  // A step for the app as it is with a flag off (`unless`): skipped where the flag is on, as the flag's own steps are where it is off.
  if (st.unless !== undefined && await flagOn(st.unless)) return { run: false, onHere: st.unless };
  if (here.flip !== undefined && st.flag !== undefined && st.flag === here.flip) return { run: true, flip: true };
  if (st.flag !== undefined && !(await flagOn(st.flag))) return { run: false, off: st.flag };
  return { run: true };
}
