// `deploy gcp` from a terminal (docs/intents.md), through bin/pronto:
//   bin/pronto plan|deploy gcp <app-dir> [--project <id>] [--region <region>] [--release true]
//     [--shared <project>]
// A new release target names --project, a Google Cloud project of yours, which has no default,
// and --region (default us-central1). --shared names a project shared with other apps, where a
// release goes out from the host that releases them (Pronto Studio) alone. Without --release true
// every step but the release is taken, and it stops there; the release runs with your own gcloud
// login.
import { resolve } from "jsr:@std/path@1.1.2";
import { connect, finished, line, plan, waitingOn } from "../intents/run.ts";
import { flagsOf } from "../intents/shell.ts";
import { steps } from "./deploy.ts";
import { deployDeps } from "./deploy_deps.ts";

const [mode, intent, dirArg, ...rest] = Deno.args;
if (!["plan", "connect", "deploy"].includes(mode) || intent !== "gcp" || !dirArg) {
  console.error("usage: pronto plan|deploy gcp <app-dir> [--project <id>] [--region <region>] [--release true] [--shared <project>]");
  Deno.exit(2);
}
const flags = flagsOf(rest);
const dir = resolve(dirArg);

const deps = deployDeps(dir);

const all = steps(deps, { project: flags.project, region: flags.region ?? "us-central1", release: flags.release === "true", shared: flags.shared });
if (mode === "plan") {
  for (const o of await plan(all)) console.log(line(o));
} else {
  const out = await connect(all, (o) => console.log(line(o)));
  console.log(finished(out, all) ? `\n${deps.app} is online: ${out.at(-1)!.note}` : waitingOn(out));
}
