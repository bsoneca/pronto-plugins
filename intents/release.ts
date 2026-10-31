// `release` (docs/intents.md): an app goes online where its release.cue says, and everything it is
// connected to comes with it: its checks and its release (gcp/deploy.ts), and, where it sells
// through pronto-billing, the broker named before it goes out and its payouts checked once it is out
// (billing/connect.ts liveSteps). One command, its app's name and nothing else.
import { liveSteps, type Deps as StripeDeps, type Options as StripeOptions } from "../billing/connect.ts";
import { type Deps, type Options, steps as deploySteps } from "../gcp/deploy.ts";
import type { Step } from "./run.ts";

/** Where the app sells, when it does: pronto-billing's deps and options, and the address it is
 * out at (null before its first release, when only what goes out with it can be done). */
export interface Billing {
  d: StripeDeps;
  o: StripeOptions;
  origin: string | null;
}

export function steps(d: Deps, o: Options, billing: Billing | null): Step[] {
  const all = deploySteps(d, { ...o, release: true });
  if (!billing) return all;
  const at = all.findIndex((s) => s.name === "released");
  const live = liveSteps(billing.d, { ...billing.o, origin: billing.origin ?? "" });
  return [...all.slice(0, at), ...live.before, ...all.slice(at), ...(billing.origin ? live.after : [])];
}
