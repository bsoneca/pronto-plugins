// Whether a scenario's step runs here, asked in this order: its place first (`on`: a step for production
// alone, or for a stack at hand alone), then a value an earlier step kept (`ifKept`), then its flags
// (`unless`, `flag`, `with`), so a step for another place never asks the door anything on its behalf: a
// production flip's run sends no OFREP request for a local step. `flagOn` is the run's own question
// to the door. `flip` is the flag a flip tests (FLAG, with FLAGS_TESTER): its steps run, and the
// runner checks it for the tester itself. At hand is a stack on this machine: a deployed preview is neither
// (PRONTO-873: a database step there would fail the run).
export type Place = "production" | "local" | "deployed";
export type Gated = { on?: "production" | "local"; ifKept?: string; unless?: string; flag?: string; with?: string };
export type Here = { place: Place; kept: (name: string) => string | undefined; flip?: string };
export type Gate = { run: boolean; flip?: boolean; onHere?: string; off?: string; also?: string };

// `with` is a second flag the step needs on beside `flag` (PRONTO-1688: a flow that two flags both make possible, such as
// a trial's return, which needs the trial and its return flag): skipped where it is off, and asked after `flag`, so a flip's
// own flag still decides first. A flip tests `flag` alone: `with` is asked of the door as it is, never forced on.
// A step skipped for `with` names `flag` too (`also`), so a push of `flag` whose steps all sat behind a `with` that is off
// reads as vacuous (flags/live.nu), never as a pass.

export async function stepGate(st: Gated, here: Here, flagOn: (flag: string) => Promise<boolean>): Promise<Gate> {
  if (st.on === "production" && here.place !== "production") return { run: false };
  if (st.on === "local" && here.place !== "local") return { run: false };
  if (st.ifKept && ["", "undefined", "null"].includes(here.kept(st.ifKept) ?? "")) return { run: false };
  // A step for the app as it is with a flag off (`unless`): skipped where the flag is on, as the flag's own steps are where it is off.
  if (st.unless !== undefined && await flagOn(st.unless)) return { run: false, onHere: st.unless };
  const flipping = here.flip !== undefined && st.flag !== undefined && st.flag === here.flip;
  if (!flipping && st.flag !== undefined && !(await flagOn(st.flag))) return { run: false, off: st.flag };
  if (st.with !== undefined && !(await flagOn(st.with))) return { run: false, off: st.with, also: st.flag };
  return flipping ? { run: true, flip: true } : { run: true };
}

// What a read-only production page may send (PRONTO-419): `pass` a read, and a flag's anonymous evaluation (schema.cue's
// #OfrepEvaluation: a POST to the door's own /ofrep/v1/evaluate/flags/<name>); `refuse` a write to the app's own /auth/ or /crud/, aborted
// and failing the run, since a page that needs one to show its feature is no read; `abort` any other write (a beacon: analytics, errors, a
// third party), aborted and ignored.
export type Sent = "pass" | "abort" | "refuse";
export function sentOf(method: string, own: boolean, pathname: string): Sent {
  if (["GET", "HEAD", "OPTIONS"].includes(method)) return "pass";
  if (method === "POST" && own && /^\/ofrep\/v1\/evaluate\/flags\/[A-Za-z0-9_-]+$/.test(pathname)) return "pass";
  return own && /^\/(auth|crud)\//.test(pathname) ? "refuse" : "abort";
}

// The address an `open` step takes the browser to: a path of the app or a web address, never another scheme, and on
// production only the app's own origin, so a scenario cannot point the runner's browser at a local file or another site
// (Codex security P1 on bsoneca/pronto#1722).
export function openHref(to: string, base: string, production: boolean): string {
  const href = new URL(to, base);
  if (href.protocol !== "http:" && href.protocol !== "https:") throw new Error(`open: ${to} is not an http(s) address`);
  if (production && href.origin !== new URL(base).origin) throw new Error(`open: ${to} is not on the app's origin, the only one a production scenario may open`);
  return href.href;
}
