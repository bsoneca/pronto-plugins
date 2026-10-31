// Adds or refreshes pronto-billing in a pronto app (bin/pronto-billing):
//   install.ts <app-dir> [owner-hash]
// Regenerated every time, each marked as this host's: the program's schema,
// table, migration and services (billing_plugin.cue), the door's routes
// (pronto/billing.cue, billing/billing.nu), and the code the billing service
// and a local broker run (billing/). Written once, then the app's own: what it
// sells (billing_spec.cue), owned by the author's payout secret.
const here = new URL(".", import.meta.url).pathname;
const [appArg, owner] = Deno.args;
if (!appArg) throw new Error("usage: install.ts <app-dir> [owner-hash]");
const app = appArg.replace(/\/$/, "");
const program = await Deno.readTextFile(`${app}/program.cue`);
const pkg = /^package\s+([a-z][a-z0-9_]*)\s*$/m.exec(program)?.[1];
if (!pkg) throw new Error(`${app}/program.cue names no package`);

async function write(path: string, text: string, seed = false) {
  const to = `${app}/${path}`;
  const held = await Deno.readTextFile(to).catch(() => null);
  if (held !== null && (seed || held === text)) return;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-billing: wrote ${path}`);
}
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`)).replaceAll("__PACKAGE__", pkg);

await write("billing_plugin.cue", await template("billing_plugin.cue"));
await write("pronto/billing.cue", await template("pronto_billing.cue"));
await write("billing/billing.nu", await template("billing.nu"));
for (const f of ["service.ts", "entitlement.ts", "shared.ts", "broker/core.ts", "broker/main.ts", "broker/stripe.ts", "broker/fake.ts"]) {
  await write(`billing/${f}`, await Deno.readTextFile(`${here}${f}`));
}
if (!owner && !(await Deno.stat(`${app}/billing_spec.cue`).catch(() => null))) {
  console.log("pronto-billing: no owner given; run `deno run billing/owner.ts new` and put its hash in billing_spec.cue");
}
await write("billing_spec.cue", (await template("billing_spec.cue")).replace("__OWNER__", owner ?? ""), true);
