// `connect stripe` from a terminal (docs/intents.md), through bin/pronto:
//   bin/pronto plan|connect stripe <app-dir> [--plan <id> --name <name> --usd <cents> [--brl <centavos>]
//     [--interval month|year]] [--origin https://…] [--broker https://…] [--email <address>]
//     [--country BR] [--project <secrets-project>] [--secrets-file <path>]
//     [--studio | --before-release | --after-release] [--json]
// --secrets-file keeps the secret in a file instead, for a trial on a developer's machine.
// A host that releases apps itself (a hosted builder) runs it in three places: in a turn with --studio,
// the app's own files alone, its payout secret left to the release; before a release it makes with
// --before-release (the secret, the broker); after it, with --after-release and the origin, for
// Stripe's link. --json prints the outcomes as one JSON array, for a program to read.
// Nothing has a default. The broker is the one release.cue names, else --broker: one you run
// (bin/pronto-billing-broker release, docs/stripe.md). The author's secret is kept in Secret Manager
// in --project, else release.cue's billingSecretsProject, else the project its GCP release names, with your own gcloud login, and
// never printed; or in --secrets-file.
import { resolve } from "jsr:@std/path@1.1.2";
import { connect, finished, line, plan, waitingOn } from "../intents/run.ts";
import { flagsOf } from "../intents/shell.ts";
import { type Options, secretsProject, steps } from "./connect.ts";
import { stripeDeps } from "./connect_deps.ts";

const [mode, intent, dirArg, ...rest] = Deno.args;
if (!["plan", "connect"].includes(mode) || intent !== "stripe" || !dirArg) {
  console.error("usage: pronto plan|connect stripe <app-dir> [--plan <id> --name <name> --usd <cents>] [--origin <url>] [--email <address>]");
  Deno.exit(2);
}
const flags = flagsOf(rest);
const dir = resolve(dirArg);

const release = await Deno.readTextFile(`${dir}/release.cue`).catch(() => "");
const project = flags.project ?? secretsProject(release) ?? undefined;
const deps = stripeDeps(dir, { project, secretsFile: flags["secrets-file"] });

const n = (k: string) => (flags[k] === undefined ? undefined : Number(flags[k]));
const options: Options = {
  ...(flags.broker ? { broker: flags.broker } : {}),
  ...(flags.origin ? { origin: flags.origin } : {}),
  ...(flags.email ? { email: flags.email } : {}),
  ...(flags.country ? { country: flags.country } : {}),
  ...(flags.studio ? { studio: true } : {}),
  ...(flags["before-release"] ? { release: "before" as const } : flags["after-release"] ? { release: "after" as const } : {}),
  ...(flags.plan ? { plan: { id: flags.plan, name: flags.name ?? flags.plan, usd: n("usd") ?? 499, ...(n("brl") ? { brl: n("brl") } : {}), interval: (flags.interval as "month" | "year") ?? "month" } } : {}),
};
const all = steps(deps, options);
if (flags.json) {
  console.log(JSON.stringify(mode === "plan" ? await plan(all) : await connect(all)));
} else if (mode === "plan") {
  for (const o of await plan(all)) console.log(line(o));
} else {
  const out = await connect(all, (o) => console.log(line(o)));
  const done = options.studio ? " in the app: the builder sets its payouts up once it is released" : options.origin ? "" : " for test mode: with --origin, the live steps run once the app is released";
  console.log(finished(out, all) ? `\nStripe is connected${done}.` : waitingOn(out));
}
