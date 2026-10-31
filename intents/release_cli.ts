// `release` from a terminal (docs/intents.md), through bin/pronto:
//   bin/pronto release <app> [--email <address>] [--country BR]   the app's name (apps/<app>) or its folder
//     [--project <id>] [--broker https://…] [--shared <project>]
//   bin/pronto plan release <app>     what is done, what is next, changing nothing
// Where it goes is its release.cue's, where it answers is its release's, and where Stripe reaches
// its author is the author's git email, or --email where git has none. Nothing has a default: an
// app with no release.cue is told its project (--project), one that sells its broker where its
// release.cue names none (--broker), and the author's secret is kept in --project, else in the
// project its release names. --shared names a project shared with other apps (a hosted builder's).
import { join, resolve } from "jsr:@std/path@1.1.2";
import { secretsProject, steps as stripeSteps } from "../billing/connect.ts";
import { stripeDeps } from "../billing/connect_deps.ts";
import { releasedTo } from "../gcp/deploy.ts";
import { deployDeps } from "../gcp/deploy_deps.ts";
import { type Billing, steps } from "./release.ts";
import { connect, finished, line, plan, waitingOn } from "./run.ts";
import { cmd, flagsOf } from "./shell.ts";

const [mode, arg, ...rest] = Deno.args;
const flags = flagsOf(rest);
if (!["plan", "release"].includes(mode) || !arg) {
  console.error("usage: pronto release <app>   (or: pronto plan release <app>)");
  Deno.exit(2);
}
// An app's name is its folder under the repository's apps/.
async function appDir(a: string): Promise<string> {
  if (await Deno.stat(resolve(a)).then((s) => s.isDirectory, () => false)) return resolve(a);
  const top = await cmd("git", ["rev-parse", "--show-toplevel"]);
  const root = top.ok ? top.out.trim() : resolve(new URL("../..", import.meta.url).pathname);
  const dir = join(root, "apps", a);
  if (!(await Deno.stat(dir).then((s) => s.isDirectory, () => false))) throw new Error(`no app ${a}: no folder ${dir}`);
  return dir;
}
const dir = await appDir(arg);
const d = deployDeps(dir);

// Where it sells, when it does: its address the release's (a cluster's gateway, Cloud Run's).
async function billing(): Promise<Billing | null> {
  if ((await d.read(join(dir, "billing_plugin.cue"))) === null) return null;
  const to = releasedTo((await d.read(join(dir, "release.cue"))) ?? "");
  const planned = to ? await d.plan(to).catch(() => null) : null;
  const origin = planned && "plan" in planned ? (planned.plan.origin ?? await d.address(planned.plan)) : null;
  const email = flags.email ?? (await cmd("git", ["config", "user.email"], { cwd: dir })).out.trim();
  const country = flags.country ? { country: flags.country } : {};
  const project = flags.project ?? secretsProject((await d.read(join(dir, "release.cue"))) ?? "") ?? undefined;
  const broker = flags.broker ? { broker: flags.broker } : {};
  return { d: stripeDeps(dir, { project }), o: { ...broker, ...(email ? { email } : {}), ...country }, origin };
}
const b = await billing();
// An app that sells but has not been set up to (no plan, no secret) is connect stripe's first.
if (b) {
  // Its own generate and lint aside: the release's checks run them.
  const local = await plan(stripeSteps(b.d, b.o).filter((s) => s.name !== "generated and linted"));
  const first = local.find((s) => s.state !== "done");
  if (first) {
    console.log(line(first));
    console.log(`\n${d.app} sells through pronto-billing, which is not set up yet: pronto connect stripe ${d.app} first.`);
    Deno.exit(1);
  }
}

const all = steps(d, { project: flags.project, region: flags.region ?? "us-central1", shared: flags.shared }, b);
if (mode === "plan") {
  for (const o of await plan(all)) console.log(line(o));
} else {
  const out = await connect(all, (o) => console.log(line(o)));
  const done = finished(out, all);
  const pending = b && !b.origin ? `\nIt sells through pronto-billing: run pronto release ${d.app} again, now that it is out, to set its payouts up.` : "";
  console.log(done ? `\n${d.app} is out.${pending}` : waitingOn(out));
}
