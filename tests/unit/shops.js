// The intents' cases' stand-ins (tests/unit/*.cue): a pronto app in a folder of its own, its
// sayt verbs, Secret Manager as a map, and the broker, the origin and Cloud Run answering as the
// operator's would. A shop is a handle the cases keep ("$shop") and pass back; a run of an intent
// is what each step came to: {names, states, notes, finished}.
import { ownerOf } from '../../billing/broker/core.ts';
import { secretName, steps as stripeSteps } from '../../billing/connect.ts';
import { steps as deploySteps } from '../../gcp/deploy.ts';
import { steps as releaseSteps } from '../../intents/release.ts';
import { connect, finished, plan } from '../../intents/run.ts';

const install = new URL('../../billing/install.ts', import.meta.url).pathname;
const read = (p) => Deno.readTextFile(p).catch(() => null);
const cuesOf = async (dir) => {
  const out = [];
  for await (const e of Deno.readDir(dir)) if (e.name.endsWith('.cue')) out.push(await Deno.readTextFile(`${dir}/${e.name}`));
  return out;
};
const ran = async (all, mode) => {
  const out = mode === 'plan' ? await plan(all) : await connect(all);
  return { names: out.map((o) => o.step), states: out.map((o) => o.state), notes: out.map((o) => o.note), finished: finished(out, all) };
};

/** An app that keeps orders (its migration 03_orders), for connect stripe; `extra` more program. */
export async function stripe(extra = '') {
  const dir = await Deno.makeTempDir({ prefix: 'connect-stripe-' });
  await Deno.writeTextFile(`${dir}/program.cue`, `package shop\n\ncode: state: migrations: "03_orders": operations: []\n${extra}`);
  const secrets = new Map();
  const web = { published: false, onboarded: false, asked: [], account: false };
  let generated = false;
  const h = { dir, secrets, web };
  // The origin publishes the spec's owner once released; the broker opens onboarding and says when
  // Stripe is done, and answers its keys.
  const answer = async (url, init) => {
    if (url === 'https://shop.example/.well-known/pronto-billing.json') {
      const owner = /^\s*owner:\s*"([^"]*)"/m.exec((await read(`${dir}/billing_spec.cue`)) ?? '')?.[1];
      return web.published ? Response.json({ owner, plans: {} }) : new Response('', { status: 404 });
    }
    if (url.startsWith('https://broker.example/onboarded')) return new Response(web.onboarded ? '<h1>Payouts for shop.example are set up</h1>' : "<h1>aren't set up yet</h1>");
    // Stripe's account is made with the author's email, once; a link to it needs none after.
    if (url === 'https://broker.example/onboard') {
      const asked = JSON.parse(String(init?.body));
      web.asked.push(asked);
      if (!web.account && !asked.email) return Response.json({ error: 'email required: where Stripe reaches the author about payouts' }, { status: 400 });
      web.account = true;
      return Response.json({ url: 'https://connect.stripe.com/setup/e/acct_1/xyz' });
    }
    if (url === 'https://broker.example/jwks') return Response.json({ keys: [{ kid: 'k' }] });
    return new Response('', { status: 404 });
  };
  h.d = {
    dir,
    app: 'shop',
    read,
    write: (p, t) => Deno.writeTextFile(p, t),
    cues: () => cuesOf(dir),
    install: async () => {
      const r = await new Deno.Command(Deno.execPath(), { args: ['run', '--no-config', '--allow-read', '--allow-write', install, dir], stdout: 'null', stderr: 'piped' }).output();
      if (!r.success) throw new Error(new TextDecoder().decode(r.stderr));
    },
    // Lints only once generated.
    saytw: (verb) => {
      if (verb === 'generate') generated = true;
      return Promise.resolve({ ok: verb === 'generate' || generated, out: '' });
    },
    secrets: { get: (n) => Promise.resolve(secrets.get(n) ?? null), put: (n, v) => Promise.resolve(void secrets.set(n, v)) },
    fetch: (input, init) => answer(String(input), init),
  };
  return h;
}

/** connect stripe on the shop, or with mode "plan" its plan. */
export const connectStripe = (h, options, mode = 'connect') => ran(stripeSteps(h.d, options), mode);
/** pronto-billing's installer run on the shop, as an author would have. */
export const installed = async (h) => (await h.d.install(), h);
/** The secret kept for the shop's author, and its hash. */
export const kept = (h) => h.secrets.get(secretName('shop')) ?? null;
export const keptOwner = async (h) => await ownerOf(kept(h));
/** The origin and the broker as the author's release and Stripe leave them. */
export const answers = (h, w) => (Object.assign(h.web, w), h);
/** What the broker was asked to onboard. */
export const asked = (h) => h.web.asked;
/** The pronto the shop's cue.mod pins. */
export const pinned = async (h, v) => {
  await Deno.mkdir(`${h.dir}/cue.mod`, { recursive: true });
  await Deno.writeTextFile(`${h.dir}/cue.mod/module.cue`, `deps: {\n\t"github.com/bonisoft3/pronto@v0": {\n\t\tv: "v${v}"\n\t}\n}\n`);
  return h;
};

/** An app that keeps rows on a server, for deploy and release; `program` its program.cue. */
export async function deploy(program = 'package shop\n\ncode: meta: {\n\ttargets: []\n}\ncode: state: entities: Order: {durability: "server"}\n') {
  const dir = await Deno.makeTempDir({ prefix: 'deploy-' });
  await Deno.writeTextFile(`${dir}/program.cue`, program);
  const h = { dir, ran: [], live: new Map(), fails: new Set(), isolated: true };
  h.d = {
    dir,
    app: 'shop',
    read,
    write: (p, t) => Deno.writeTextFile(p, t),
    cues: () => cuesOf(dir),
    // Generate gives a release rule where the program lists gcp among its targets; a release puts
    // the service at its address.
    saytw: async (verb, env) => {
      h.ran.push(env?.SAY_RELEASE_ARGS_NO_GATE ? `${verb} (no gate)` : verb);
      if (h.fails.has(verb)) return { ok: false, out: `${verb}: 1 error` };
      if (verb === 'generate' && (await cuesOf(dir)).some((c) => /targets:\s*\[[^\]]*"gcp"/.test(c))) {
        await Deno.writeTextFile(`${dir}/.say.yaml`, 'say:\n  release:\n    rulemap:\n      gcp:\n        platform: gcp\n');
      }
      if (verb === 'release@gcp') h.live.set('shop', 'https://shop-1.us-central1.run.app');
      if (verb === 'release@k8s') h.live.set('shop', 'https://shop-1.example');
      return { ok: true, out: '' };
    },
    plan: async (target) => {
      const rel = await read(`${dir}/release.cue`);
      if (target === 'k8s') return rel?.includes('App:') ? { plan: { target, service: 'shop', origin: 'https://shop-1.example' } } : { error: 'reference "App" not found' };
      const project = rel && /project:\s*"([^"]+)"/.exec(rel)?.[1];
      if (!project) return { error: 'reference "GCP" not found' };
      return { plan: { target, project, region: 'us-central1', service: 'shop', ...(h.isolated ? { readSecrets: ['shop-crud-db-uri'] } : {}) } };
    },
    address: (p) => Promise.resolve(h.live.get(p.service) ?? null),
    fetch: (input) => Promise.resolve(new Response('', { status: h.live.has(new URL(String(input)).hostname.split('-')[0]) ? 200 : 404 })),
  };
  return h;
}

/** deploy on the shop, or with mode "plan" its plan. */
export const deployed = (h, options, mode = 'connect') => ran(deploySteps(h.d, options), mode);
/** The sayt verbs the shop ran, in order. */
export const verbs = (h) => h.ran;
/** A verb that fails from now on. */
export const failing = (h, verb) => (h.fails.add(verb), h);
/** A pronto that grants an app's secrets on the whole project (its plan names no readSecrets). */
export const unisolated = (h) => ((h.isolated = false), h);

/** A file of the shop's, null where there is none; written, the shop. */
export const file = (h, name) => read(`${h.dir}/${name}`);
export const written = async (h, name, text) => (await Deno.writeTextFile(`${h.dir}/${name}`, text), h);

/** The steps `release` takes, by name: an app that sells nothing (null), or one out at `origin`
 * (null before its first release) that sells. They are named, never run. */
export const releaseNames = (billing, origin = null) =>
  releaseSteps({}, { project: 'p', region: 'r' }, billing ? { d: {}, o: { broker: 'https://broker.example' }, origin } : null).map((s) => s.name);

/** The runner over steps that cannot be written as data: one that applies and is still to do, and
 * one whose check throws, each followed by a step that is done. */
export async function stubborn() {
  let after = false;
  const all = [
    { name: 'stubborn', check: () => Promise.resolve({ todo: 'never' }), apply: () => Promise.resolve() },
    { name: 'after', check: () => Promise.resolve(((after = true), { done: true })) },
  ];
  return { ...(await ran(all, 'connect')), after };
}
export const throwing = (mode) =>
  ran([{ name: 'unreachable', check: () => Promise.reject(new Error('gcloud: no login')) }, { name: 'after', check: () => Promise.resolve({ done: true }) }], mode);
