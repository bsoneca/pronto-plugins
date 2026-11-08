// `connect plane` from a terminal (docs/intents.md), through bin/pronto:
//   bin/pronto plan|connect plane <repo>
// <repo> is a repository with a devflow/devflow.cue (bsoneca/pronto's): its board set up, from Plane on
// its node to today's sprint. Run again, it goes on from the step it stopped at.
import { resolve } from "jsr:@std/path@1.1.2";
import { connect, finished, line, plan, waitingOn } from "../intents/run.ts";
import { steps } from "./connect.ts";
import { devflowOf } from "./spec.ts";

const [mode, intent, dirArg] = Deno.args;
if (!["plan", "connect"].includes(mode) || intent !== "plane" || !dirArg) {
  console.error("usage: pronto plan|connect plane <repo>");
  Deno.exit(2);
}
const repo = resolve(dirArg);
const flow = await devflowOf(repo);
if (!flow) {
  console.error(`pronto: ${repo} has no devflow/devflow.cue (the dev flow's spec: plugins' devflow/README.md)`);
  Deno.exit(2);
}
const all = steps(repo, flow);
if (mode === "plan") {
  for (const o of await plan(all)) console.log(line(o));
} else {
  const out = await connect(all, (o) => console.log(line(o)));
  console.log(finished(out, all) ? `\nThe board is ready: https://${flow.plane.host}/${flow.plane.workspace}/` : waitingOn(out));
}
