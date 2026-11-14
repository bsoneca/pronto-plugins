// A slow browser, as the release gate's is: its drivers drive a Cloud Run preview from Cloud
// Build, where a page boots and answers seconds later than at hand, and a race the fast local
// runs never lose is lost there. SLOW=1 slows every page the runners open: its CPU 4 times, and
// each request by 300 ms on a 10 Mbit/s line; SLOW=<cpu>,<latency ms> names its own. Unset, the
// pages run as fast as they can, as the gate's own runs do. Read by tests/scenarios.ts and
// tests/premium.ts; run so by tests/rehearse.nu.
//
// Why 4. The gate's drivers run on one E2_HIGHCPU_32 build machine, together, at the scenarios'
// own parallel (deployedParallel, tests/scenarios/schema.cue), against a Cloud Run preview over a real line, every page unthrottled (pronto's
// gcp/verify.nu): any slowing here is harsher than that, and what it must do is move the races,
// not break the browser. Chrome 1228 headless on macOS, though, wedges a throttled renderer now
// and then: its main thread blocked on a kernel rwlock for good (sampled, 11+ minutes), its CDP
// unanswered, no frame running; no page's race, and on a different scenario each pass. Measured
// over full passes: CPU 1 never, CPU 4 one pass in four (a page that never booted), CPU 6 three
// in four. So the rate is 4, each scenario watches its pages (tests/scenarios.ts: one that does
// not answer for a minute is a wedge, and the scenario is run again, twice at most, and said so),
// and a throttled page also spins about a core of the laptop to keep its slowness, which
// rates above 4 only make worse; so a page is throttled only while a step drives it (slowCpu).

import type { CDPSession } from "npm:playwright@1.61.1";

// A pull request's gate slows only the scenarios that measure a race (`slow: true` in their CUE,
// tests/scenarios/schema.cue), as the release rehearsal slows every one, so a race that only a slow line
// loses shows before the merge; the others run as fast as they can, since a throttled page spins about a
// core of the laptop and a gate runs more of them as the game grows. The local gate (integrate@local with
// INTEGRATE_LOCAL_DRIVERS=all) with SLOW unset is `gate`: SLOW=1 for those scenarios, and SLOW=0 turns that
// off. SLOW named (the rehearsal's, or by hand) slows every scenario. The final gate, SCENARIOS_ALL=1,
// runs every scenario unslowed. Premium is not slowed here.
export const gate = Deno.env.get("SLOW") === undefined && Deno.env.get("INTEGRATE_LOCAL_DRIVERS") === "all" && !Deno.env.get("SCENARIOS_ALL")
  && Deno.mainModule.endsWith("/tests/scenarios.ts");
if (gate) { Deno.env.set("SLOW", "1"); Deno.env.set("SLOW_GATE", "1"); } // the key of a scenario's record says so: a gate's green run of an unthrottled scenario is not a slowed one
const asked = Deno.env.get("SLOW") ?? "";
const [cpu, latency] = asked === "" || asked === "0" ? [0, 0]
  : asked === "1" ? [4, 300]
  : asked.split(",").map(Number);
if (asked !== "" && !(cpu >= 1 && latency >= 0)) throw new Error(`SLOW is 1 or <cpu>,<latency ms>, not ${asked}`);

export const slow = cpu ? `a CPU ${cpu} times slower and ${latency} ms on every request` : "";

// The page behind `cdp` slowed as SLOW asks, or left as it is. Chrome's network emulation holds
// back HTTP, not a WebSocket's frames: the shell's stream is slowed by the CPU alone.
// `cpuNow` false leaves the CPU for `slowCpu` to slow while a step drives the page.
export async function slowDown(cdp: CDPSession, cpuNow = true, on = true) {
  if (!cpu || !on) return;
  if (cpuNow) await cdp.send("Emulation.setCPUThrottlingRate", { rate: cpu });
  await cdp.send("Network.enable");
  await cdp.send("Network.emulateNetworkConditions", { offline: false, latency, downloadThroughput: 1_250_000, uploadThroughput: 1_250_000 });
}

// The CPU slowing on, while a step drives the page, or off, while the page sits and waits: a
// throttled page busy-waits its main thread, so an idle one burns 0.83 core of the laptop
// (measured, headless shell 1228) and an unthrottled idle one 0.01. The slowness is kept for every
// moment a step exercises the page, which is where a slow phone loses a race.
export async function slowCpu(cdp: CDPSession, on: boolean, slowed = true) {
  if (!cpu || !slowed) return;
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: on ? cpu : 1 });
}
