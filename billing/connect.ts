// `connect stripe` (docs/intents.md): a pronto app takes payments through a billing broker its
// operator runs, its author holding no Stripe key. Each step is checked, applied where it is the program's,
// and a gate where only a person can act; what it touches is passed in (Deps), so it is tested
// against stand-ins. With an --origin, it goes on to the live steps once the app is released there.
import { ownerOf } from "./broker/core.ts";
import { randomToken } from "./shared.ts";
import type { Step } from "../intents/run.ts";
import { releasedTo } from "../gcp/deploy.ts";

export { releasedTo };

export interface Deps {
  /** The app's folder, and its name (the folder's). */
  dir: string;
  app: string;
  read(path: string): Promise<string | null>;
  write(path: string, text: string): Promise<void>;
  /** The app's own CUE sources, which name its migrations. */
  cues(): Promise<string[]>;
  /** pronto-billing's installer over the app (install.ts). */
  install(): Promise<void>;
  /** A sayt verb in the app's folder: whether it passed, and the end of what it said. */
  saytw(verb: string): Promise<{ ok: boolean; out: string }>;
  /** Secret Manager, or a stand-in: a value is never printed, only stored and read back. */
  secrets: { get(name: string): Promise<string | null>; put(name: string, value: string): Promise<void> };
  fetch: typeof fetch;
}

export interface Options {
  /** What to sell, when the spec sells nothing yet. */
  plan?: { id: string; name: string; usd: number; brl?: number; interval?: "month" | "year" };
  /** The app's live origin: the live steps run only with it. */
  origin?: string;
  /** The billing broker to name in release.cue where it names none yet: one its operator runs
   * (bin/pronto-billing-broker release, docs/stripe.md). There is no default. */
  broker?: string;
  /** Where Stripe reaches the author about payouts, and the country they are paid in. */
  email?: string;
  country?: string;
  /** In a builder turn: the payout secret is left to the builder's release, which holds Secret Manager
   * and a turn does not (a hosted builder). */
  studio?: boolean;
  /** Which side of a release this run is, for a release made by something else (the builder): what must
   * go out with it (the secret, the broker), or what is checked once it is out (needs origin). */
  release?: "before" | "after";
}

export const secretName = (app: string) => `pronto-billing-owner-${app}`;
const SPEC = "billing_spec.cue";

/** The owner's hash billing_spec.cue publishes, "" where it names none. */
export const specOwner = (spec: string) => /^\s*owner:\s*"([^"]*)"/m.exec(spec)?.[1] ?? "";
export const withOwner = (spec: string, hash: string) => spec.replace(/^(\s*owner:\s*)"[^"]*"/m, `$1"${hash}"`);
/** Whether the spec sells nothing yet: `plans: {}`. */
export const sellsNothing = (spec: string) => /^\s*plans:\s*\{\s*\}/m.test(spec);
/** The spec selling one plan, in minor units: {usd: 499} is US$4.99. */
export function withPlan(spec: string, p: NonNullable<Options["plan"]>): string {
  const prices = [`usd: ${p.usd}`, ...(p.brl ? [`brl: ${p.brl}`] : [])].join(", ");
  return spec.replace(/^(\s*)plans:\s*\{\s*\}/m, `$1plans: ${p.id}: {\n$1\tname:     ${JSON.stringify(p.name)}\n$1\tinterval: "${p.interval ?? "month"}"\n$1\tprices: {${prices}}\n$1}`);
}

/** Migration names after the app's own (pgroll refuses one named before the last it applied):
 * the next number past the highest an app's migrations start with, for billing and its grants. */
export function migrationNames(cues: readonly string[]): { billing: string; grants: string } {
  let top = 0;
  for (const c of cues) for (const m of c.matchAll(/migrations:\s*"(\d+)_[a-z0-9_]+"/g)) top = Math.max(top, Number(m[1]));
  if (top === 0) return { billing: "billing_01", grants: "billing_02" };
  const pad = (n: number) => String(n).padStart(2, "0");
  return { billing: `${pad(top + 1)}_billing`, grants: `${pad(top + 2)}_billing_grants` };
}
export function withMigrations(spec: string, names: { billing: string; grants: string }): string {
  return spec
    .replace(/^(_billingMigration:\s*)"[^"]*"/m, `$1"${names.billing}"`)
    .replace(/^(_billingGrantsMigration:\s*)"[^"]*"/m, `$1"${names.grants}"`);
}

/** Whether an app's design document (ir.html) describes billing's entity and hatch, which pronto's
 * facts lint asks of every entity and hatch the program has. */
export const describesBilling = (ir: string, typeId: string | null) =>
  /<section id="billing" data-kind="hatch"/.test(ir) &&
  new RegExp(`<section id="Subscription" data-kind="entity"[^>]*${typeId ? `data-type-id="${typeId}"` : ""}`).test(ir);
/** The type id pronto's mint gave Subscription, wherever the app's program holds it. */
export const subscriptionId = (cues: string[]) => cues.map((c) => /Subscription:\s*\{\s*id:\s*"(0x[0-9a-f]+)"/.exec(c)?.[1]).find(Boolean) ?? null;
/** The design document with billing's two sections, before its last closing </main> or </body>;
 * generate fills in the entity's card from the program. */
export function withBillingSections(ir: string, typeId: string | null): string {
  const sections = `
  <section id="Subscription" data-kind="entity" data-durability="live"${typeId ? ` data-type-id="${typeId}"` : ""}>
    <h3>Subscription</h3>
    <p>Each plan an account holds, and until when: the billing broker's word, which only the database
    writes (pronto-billing's migration); the account reads its own, and a paid feature's gate reads it.</p>
  </section>
  <section id="billing" data-kind="hatch">
    <h3>billing — the billing service (container, pronto-billing)</h3>
    <p>Beside the door, behind <code>/billing/*</code> and <code>/.well-known/pronto-billing.json</code>:
    publishes the plans and the hash of the author's payout secret, takes the operator's billing broker's
    signed entitlements into <code>Subscription</code>, and sends a signed-in account to Stripe to
    subscribe or to manage its subscription. It holds no secret. Added by <code>connect stripe</code>.</p>
  </section>
`;
  const at = ir.lastIndexOf("</main>") >= 0 ? ir.lastIndexOf("</main>") : ir.lastIndexOf("</body>");
  return at >= 0 ? ir.slice(0, at) + sections + ir.slice(at) : ir + sections;
}

/** Subscription's type id where mint stamped it in pronto-billing's own file (billing_plugin.cue,
 * which a reinstall rewrites), moved to billing_spec.cue, the app's: [plugin, spec] as they become,
 * or null where the plugin's file holds none. */
export function withIdInSpec(plugin: string, spec: string): [string, string] | null {
  const m = /(\tSubscription: \{\n)\t\tid: "(0x[0-9a-f]+)"\n/.exec(plugin);
  if (!m) return null;
  const moved = spec.replace(/(\tSubscription: \{\n)(\s*\})/, `$1\t\tid: "${m[2]}"\n$2`);
  if (moved === spec) throw new Error("billing_spec.cue has no Subscription block to keep the type id in");
  return [plugin.replace(m[0], m[1]), moved];
}

/** The release's billing service named the operator's broker, where release.cue has a GCP release. */
export const namesBroker = (release: string) => /BILLING_BROKER:\s*"https:\/\//.test(release);
/** The broker release.cue tells the billing service, null where it names none. */
export const brokerNamed = (release: string) => /BILLING_BROKER:\s*"(https:\/\/[^"]+)"/.exec(release)?.[1] ?? null;
/** Where release.cue keeps the author's payout secret: its `billingSecretsProject`, said for a
 * release that is not on Cloud Run (a cluster's), else the project its GCP release names; null
 * where it names neither, and there is no default. */
export const secretsProject = (release: string) =>
  /^billingSecretsProject:\s*"([^"]+)"/m.exec(release)?.[1] ?? /^GCP:[^\n]*\{[^}]*?\bproject:\s*"([^"]+)"/m.exec(release)?.[1] ?? null;
/** release.cue with the billing service told the broker: a sidecar on Cloud Run, a service of the
 * app's own on Kubernetes (pronto's App.services). */
export function withBroker(release: string, broker: string): string {
  const env = `\tenv: {\n\t\tBILLING_BROKER:          "${broker}"\n\t\tBILLING_BROKER_INTERNAL: "${broker}"\n\t}\n`;
  const service = releasedTo(release) === "k8s" ? `App: services: billing: {\n\tport: 8688\n${env}}` : `GCP: sidecars: billing: {\n\tport: 8688\n\tcpu:  100\n${env}}`;
  return release + `\n// The billing service sells through the operator's broker (connect stripe, docs/intents.md).\n${service}\n`;
}

/** The pronto an app's cue.mod pins, as "0.24.1-gcp.26"; null where it names none. */
export const prontoPin = (moduleCue: string) => /"github\.com\/bonisoft3\/pronto@v0":\s*\{\s*v:\s*"v([^"]+)"/.exec(moduleCue)?.[1] ?? null;
/** Whether a pronto runs a program's host peers beside its own renderer (code.meta.hostPeers),
 * which billing's service is: 0.24.1-gcp.26 on, or a later release. */
export function takesHostPeers(pin: string): boolean {
  const [base, pre] = pin.split("-", 2);
  const [a, b, c] = base.split(".").map(Number);
  const past = a > 0 || b > 24 || (b === 24 && c > 1);
  if (past) return true;
  if (b < 24 || (b === 24 && c < 1)) return false;
  // 0.24.1 itself: a release past every prerelease; of the prereleases, gcp.26 and later.
  if (pre === undefined) return true;
  const gcp = /^gcp\.(\d+)/.exec(pre);
  return !!gcp && Number(gcp[1]) >= 26;
}

export function steps(d: Deps, o: Options): Step[] {
  // A turn's run is the app's files alone: never a side of a release, which holds the secret.
  if (o.studio && o.release) throw new Error("--studio runs on the app's own files: a release's side is the builder's own to run");
  const spec = () => d.read(`${d.dir}/${SPEC}`);
  const local: Step[] = [
    {
      // Billing's service is one of the program's host peers (code.meta.hostPeers), which a pronto
      // before 0.24.1-gcp.26 does not take: the app could not generate. Known before anything is
      // touched, not halfway through generate.
      name: "a pronto that runs billing's service",
      check: async () => {
        const pin = prontoPin((await d.read(`${d.dir}/cue.mod/module.cue`)) ?? "");
        if (pin === null || takesHostPeers(pin)) return { done: true, note: pin ?? "" };
        return { gate: `this app's pronto is ${pin}, which cannot run billing's service beside its own: update it to 0.24.1-gcp.26 or later (its .mise.toml and cue.mod/module.cue), generate, then run this again` };
      },
    },
    {
      name: "pronto-billing installed",
      check: async () => (await d.read(`${d.dir}/billing_plugin.cue`)) !== null ? { done: true } : { todo: "its schema, migration and service are not in the app" },
      apply: async () => {
        await d.install();
        // Its migrations named after the app's own, which the installer cannot know.
        const s = await spec();
        if (s !== null) await d.write(`${d.dir}/${SPEC}`, withMigrations(s, migrationNames(await d.cues())));
      },
    },
    {
      name: "the author's payout secret",
      check: async () => {
        const s = await spec() ?? "";
        const held = await d.secrets.get(secretName(d.app));
        const published = specOwner(s);
        if (held && published === await ownerOf(held)) return { done: true, note: `kept in ${secretName(d.app)}, its hash published` };
        if (!held && published) {
          return { gate: `${SPEC} names an owner whose secret is not in Secret Manager: its author puts it there, never pasted anywhere else: read -rs S && printf %s "$S" | gcloud secrets create ${secretName(d.app)} --data-file=- ; unset S` };
        }
        return { todo: held ? "its hash is not the one published" : "no secret yet" };
      },
      apply: async () => {
        let held = await d.secrets.get(secretName(d.app));
        if (!held) {
          held = randomToken(32);
          await d.secrets.put(secretName(d.app), held);
        }
        await d.write(`${d.dir}/${SPEC}`, withOwner(await spec() ?? "", await ownerOf(held)));
      },
    },
    {
      name: "something to sell",
      check: async () => {
        const s = await spec();
        if (s === null) return { todo: "once pronto-billing is installed" };
        if (!sellsNothing(s)) return { done: true };
        return o.plan ? { todo: `the plan ${o.plan.id}` } : { gate: "say what to sell: --plan <id> --name <name> --usd <cents> [--brl <centavos>] [--interval month|year]" };
      },
      apply: async () => await d.write(`${d.dir}/${SPEC}`, withPlan(await spec() ?? "", o.plan!)),
    },
    {
      name: "ir.html describes billing",
      check: async () => {
        const ir = await d.read(`${d.dir}/ir.html`);
        if (ir === null) return { done: true };
        return describesBilling(ir, subscriptionId(await d.cues())) ? { done: true, note: "its Subscription entity and billing hatch" } : { todo: "its design document has no Subscription entity or billing hatch" };
      },
      apply: async () => {
        // The entity's type id is minted by generate: a new install has none until it runs.
        if (!subscriptionId(await d.cues())) await d.saytw("generate");
        const ir = (await d.read(`${d.dir}/ir.html`) ?? "").replace(/\n\s*<section id="Subscription" data-kind="entity"[\s\S]*?<\/section>\n\s*<section id="billing" data-kind="hatch"[\s\S]*?<\/section>\n/, "\n");
        await d.write(`${d.dir}/ir.html`, withBillingSections(ir, subscriptionId(await d.cues())));
      },
    },
    {
      // Mint stamps the first file that declares the entity, pronto-billing's: the id is the app's.
      name: "Subscription's identity kept in billing_spec.cue",
      check: async () => {
        const plugin = await d.read(`${d.dir}/billing_plugin.cue`);
        return plugin !== null && withIdInSpec(plugin, (await spec()) ?? "") !== null ? { todo: "its type id is in billing_plugin.cue, which a reinstall rewrites" } : { done: true };
      },
      apply: async () => {
        const [plugin, moved] = withIdInSpec((await d.read(`${d.dir}/billing_plugin.cue`)) ?? "", (await spec()) ?? "")!;
        await d.write(`${d.dir}/billing_plugin.cue`, plugin);
        await d.write(`${d.dir}/${SPEC}`, moved);
      },
    },
    {
      name: "generated and linted",
      check: async () => {
        const r = await d.saytw("lint");
        return r.ok ? { done: true } : { todo: "the app does not lint yet" };
      },
      apply: async () => {
        const g = await d.saytw("generate");
        if (!g.ok) throw new Error(`generate failed: ${g.out}`);
      },
    },
  ];
  const secret = (s: Step) => s.name === "the author's payout secret";
  const linted = (s: Step) => s.name === "generated and linted";
  if (o.release === "before") {
    // Generated and linted last, once the release names the broker.
    const before = liveSteps(d, { ...o, origin: o.origin ?? "" }).before;
    return [...local.filter((s) => !linted(s)), ...before, ...local.filter(linted)];
  }
  if (o.release === "after") {
    if (!o.origin) throw new Error("what is checked once released needs the origin it is out at");
    return liveSteps(d, { ...o, origin: o.origin }).after;
  }
  if (o.studio) return local.filter((s) => !secret(s));
  if (!o.origin) return local;
  const live = liveSteps(d, { ...o, origin: o.origin });
  return [...local, ...live.before, ...live.after];
}

/** The live steps, for an app released at `origin`: what its release must say before it goes out
 * (the broker), and what is checked of it once out (its plans published, its payouts set up, the
 * broker answering). `pronto release` runs them on each side of its release. */
export function liveSteps(d: Deps, o: Options & { origin: string }): { before: Step[]; after: Step[] } {
  const spec = () => d.read(`${d.dir}/${SPEC}`);
  let link = "";
  let noEmail = false;
  const origin = o.origin.replace(/\/$/, "");
  // The broker the release names, else the one given to name there: there is no default.
  const brokerAt = async () => (brokerNamed((await d.read(`${d.dir}/release.cue`)) ?? "") ?? o.broker ?? "").replace(/\/$/, "");
  const NO_BROKER = "name the billing broker the app sells through, one you run (bin/pronto-billing-broker release, docs/stripe.md): --broker https://…";
  const live: Step[] = [
    {
      name: "the release names the broker",
      check: async () => {
        const r = await d.read(`${d.dir}/release.cue`);
        if (r === null || releasedTo(r) === null) return { gate: "the app has no release to sell from yet (Cloud Run or a Kubernetes cluster): deploy it first" };
        if (namesBroker(r)) return { done: true };
        return o.broker ? { todo: `its billing service is not told ${await brokerAt()}` } : { gate: NO_BROKER };
      },
      apply: async () => await d.write(`${d.dir}/release.cue`, withBroker(await d.read(`${d.dir}/release.cue`) ?? "", await brokerAt())),
    },
    {
      name: "the origin publishes its plans",
      check: async () => {
        const res = await d.fetch(`${origin}/.well-known/pronto-billing.json`).catch(() => null);
        const doc = res?.ok ? await res.json().catch(() => null) : (await res?.body?.cancel(), null);
        if (doc?.owner && doc.owner === specOwner(await spec() ?? "")) return { done: true };
        return { gate: `${origin} does not publish this owner yet: release the app (its billing service serves /.well-known/pronto-billing.json), then run this again` };
      },
    },
    {
      name: "payouts set up at Stripe",
      check: async () => {
        const broker = await brokerAt();
        if (!broker) return { gate: NO_BROKER };
        const res = await d.fetch(`${broker}/onboarded?tenant=${encodeURIComponent(origin)}`).catch(() => null);
        const page = res ? await res.text() : "";
        if (/are set up/.test(page)) return { done: true };
        if (link) return { gate: `open ${link} and finish Stripe's form (your identity and bank account), then run this again` };
        // Stripe's account needs an email only as the broker makes it: one made already takes a
        // link with none, so the link is asked for first and the email only where it says so.
        if (noEmail) return { gate: "say where Stripe reaches you about payouts: --email <address> [--country BR]" };
        return { todo: "payouts not set up at Stripe yet" };
      },
      apply: async () => {
        const secret = await d.secrets.get(secretName(d.app));
        if (!secret) throw new Error(`${secretName(d.app)} is not in Secret Manager`);
        const res = await d.fetch(`${await brokerAt()}/onboard`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ tenant: origin, owner: secret, email: o.email, ...(o.country ? { country: o.country } : {}) }),
        });
        const out = await res.json().catch(() => ({}));
        if (res.status === 400 && /email required/.test(out.error ?? "")) return void (noEmail = true);
        if (!res.ok) throw new Error(`the broker answered ${res.status}: ${out.error ?? ""}`);
        link = out.url;
      },
    },
    {
      name: "verified",
      check: async () => {
        const broker = await brokerAt();
        if (!broker) return { gate: NO_BROKER };
        const jwks = await d.fetch(`${broker}/jwks`).catch(() => null);
        const keys = jwks?.ok ? (await jwks.json()).keys ?? [] : [];
        return keys.length ? { done: true, note: `${origin} sells through ${broker}, its payouts set up` } : { todo: `${broker}/jwks answers no keys` };
      },
    },
  ];
  return { before: live.slice(0, 1), after: live.slice(1) };
}
