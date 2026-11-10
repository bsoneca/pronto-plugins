// pronto-billing's side of an app: a service beside the door that publishes
// what the app sells, takes the entitlements the operator's billing broker
// pushes into the app's database, and sends a signed-in account to pay or to
// manage what it pays for. It holds no secret: the broker's entitlements are
// checked against the broker's keys, a reader is who the REST gateway says
// the reader's own session is, and the database is written as the service
// through that gateway, by functions billing_spec's migration made.
import { brokerKeys, verifyEntitlement } from "./entitlement.ts";
import { readCapped, Refused } from "./shared.ts";

export interface Settings {
  /** The app's own origin: its tenant at the broker. */
  origin: string;
  /** The broker as readers reach it (its issuer), and as this service does. */
  broker: string;
  brokerInternal?: string;
  /** The REST gateway, and the service's token for it. */
  crud: string;
  serviceJwt: string;
  /** What /.well-known/pronto-billing.json publishes: the owner and the plans. */
  document: string;
  /** The author's grants, as billing_spec.cue declares them (billing_plugin.cue's #billingGrants). */
  grants?: string;
  /** Where the grants are read live, as the flag billing_grants: a flagd's OFREP, or `origin`
   * for the app's own door, which routes /ofrep/ to its flagd wherever it runs apart. */
  flags?: string;
  /** The flag that turns the free trial on, evaluated per account at `flags`; none, and a
   * document with a trial is all it takes. */
  trialFlag?: string;
  // The flag that sends this tenant's calls to Stripe through the operator's airlock (PRONTO-218):
  // asked for each request's own reader, its value told to the broker as `door`.
  doorFlag?: string;
  fetcher?: typeof fetch;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

/** A failed answer's body on one line: an HTML page by its <title>, else its text with the tags
 * stripped and the whitespace collapsed, at most `max` characters. */
export function brief(body: string, max = 120): string {
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(body)?.[1];
  const text = (title ?? body).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max - 3)}...` : text;
}

export function service(s: Settings) {
  const fetcher = s.fetcher ?? fetch;
  const origin = s.origin.replace(/\/$/, "");
  const issuer = s.broker.replace(/\/$/, "");
  const brokerAt = (s.brokerInternal || s.broker).replace(/\/$/, "");
  const crud = s.crud.replace(/\/$/, "");
  const keys = brokerKeys(brokerAt, fetcher);
  const doc = JSON.parse(s.document) as { plans: Record<string, unknown>; trial?: { plans: string[] } };
  const plans = Object.keys(doc.plans);

  async function rpc(fn: string, auth: string, args: Record<string, unknown> = {}): Promise<Response> {
    return await fetcher(`${crud}/rpc/${fn}`, {
      method: "POST", headers: { authorization: auth, "content-type": "application/json" }, body: JSON.stringify(args),
    });
  }
  const asService = (fn: string, args: Record<string, unknown>) => rpc(fn, `Bearer ${s.serviceJwt}`, args);

  // Who asks, as the gateway reads the reader's own session: an account, never a guest.
  async function reader(req: Request): Promise<string | Response> {
    const auth = req.headers.get("authorization");
    if (!auth?.startsWith("Bearer ")) return json(401, { error: "sign in" });
    const res = await rpc("billing_me", auth);
    if (!res.ok) {
      await res.body?.cancel();
      return json(401, { error: "sign in" });
    }
    const me = await res.json() as { account: string | null; guest: boolean };
    if (!me.account) return json(401, { error: "sign in" });
    if (me.guest) return json(403, { error: "save your games first" });
    return me.account;
  }

  // The author's grants, handed over whole: written, moved, or taken away. With
  // flags, the set is the flag billing_grants as flagd serves it now; without,
  // the one the release carried. A set already handed over is not sent again.
  let granted: string | null = null;
  async function grant(): Promise<void> {
    const set = s.flags ? await flagged() : s.grants ?? "[]";
    if (set === granted) return;
    const res = await asService("billing_grant", { grants: JSON.parse(set) });
    if (!res.ok) throw new Error(`billing_grant answered ${res.status}: ${brief(await res.text())}`);
    await res.body?.cancel();
    granted = set;
  }
  // The flag as OFREP evaluates it: a string holding the grants' JSON array. Any
  // other answer is an error, so a flagd that is down or a flag gone takes no grant away.
  async function flagged(): Promise<string> {
    const at = s.flags === "origin" ? origin : s.flags!.replace(/\/$/, "");
    const res = await fetcher(`${at}/ofrep/v1/evaluate/flags/billing_grants`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ context: {} }), signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) throw new Error(`flag billing_grants answered ${res.status}: ${brief(await res.text())}`);
    const { value } = await res.json() as { value?: unknown };
    if (typeof value !== "string" || !Array.isArray(JSON.parse(value))) throw new Error("flag billing_grants holds no list of grants");
    return value;
  }

  async function entitle(token: string): Promise<Response> {
    let e;
    try {
      e = await verifyEntitlement(token, { issuer, tenant: origin, keys });
    } catch (err) {
      if (err instanceof Refused) return json(400, { error: err.message });
      throw err;
    }
    const res = await asService("billing_entitle", {
      account: e.account, plan: e.plan, active: e.active, through: new Date(e.through * 1000).toISOString(), manage: e.manage, ver: e.ver,
    });
    if (!res.ok) throw new Error(`billing_entitle answered ${res.status}: ${brief(await res.text())}`);
    await res.body?.cancel();
    if (e.trial) {
      // Failing throws, so the broker is not answered and Stripe sends it again.
      const t = await asService("billing_trial_state", {
        account: e.account, state: e.trial.state, plan: e.plan, amount: e.trial.amount, currency: e.trial.currency,
        charges_at: new Date(e.trial.chargesAt * 1000).toISOString(), ver: e.ver,
      });
      if (!t.ok) throw new Error(`billing_trial_state answered ${t.status}: ${brief(await t.text())}`);
      await t.body?.cancel();
    }
    return new Response(null, { status: 204 });
  }

  // The free trial is off unless the document has one and its flag, if any, is true for this
  // account as flagd evaluates it now; a flag that cannot be asked is off, never on.
  async function trialOn(account: string): Promise<boolean> {
    if (!doc.trial) return false;
    if (!s.trialFlag) return true;
    if (!s.flags) return false;
    try {
      const at = s.flags === "origin" ? origin : s.flags.replace(/\/$/, "");
      const res = await fetcher(`${at}/ofrep/v1/evaluate/flags/${encodeURIComponent(s.trialFlag)}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ context: { targetingKey: account } }), signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) {
        await res.body?.cancel();
        return false;
      }
      return (await res.json() as { value?: unknown }).value === true;
    } catch {
      return false;
    }
  }

  // Whether the reader's calls to Stripe go through the airlock's door, as flagd evaluates the flag
  // for them now: asked with the reader's own session, which the door's OFREP route reads the account
  // from (and as the targetingKey, which flagd reached directly reads). Unset flag: no word, the
  // broker's own way. A flag that cannot be asked fails the request, never picks a way.
  async function doorOn(account: string, auth: string | null): Promise<boolean | undefined> {
    if (!s.doorFlag) return undefined;
    if (!s.flags) throw new Error("BILLING_DOOR_FLAG needs BILLING_FLAGS: where to ask it");
    const at = s.flags === "origin" ? origin : s.flags.replace(/\/$/, "");
    const res = await fetcher(`${at}/ofrep/v1/evaluate/flags/${encodeURIComponent(s.doorFlag)}`, {
      method: "POST", headers: { "content-type": "application/json", ...(auth ? { authorization: auth } : {}) },
      body: JSON.stringify({ context: { targetingKey: account } }), signal: AbortSignal.timeout(10_000),
    });
    const answer = res.ok ? await res.json() as { value?: unknown } : (await res.body?.cancel(), null);
    if (typeof answer?.value !== "boolean") throw new Error(`flag ${s.doorFlag}: flagd answered ${res.status}`);
    return answer.value;
  }

  async function trialStatus(account: string): Promise<{ state: string | null; holds: boolean } & Record<string, unknown>> {
    const res = await asService("billing_trial_status", { account });
    if (!res.ok) throw new Error(`billing_trial_status answered ${res.status}: ${brief(await res.text())}`);
    return await res.json();
  }

  // A ticket for the broker to ask this service about: what the account consented to, or nothing
  // for an offer. Refused by the database for an account whose trial is spent.
  async function trialTicket(account: string, c: Record<string, unknown> = {}): Promise<string> {
    const res = await asService("billing_trial_ask", {
      account, plan: c.plan ?? null, amount: c.amount ?? null, currency: c.currency ?? null, charges_at: c.charges_at ?? null, terms: c.terms ?? null,
    });
    if (!res.ok) throw new Error(`billing_trial_ask answered ${res.status}: ${brief(await res.text())}`);
    return await res.json();
  }

  async function trial(req: Request, path: string): Promise<Response> {
    if (path === "/billing/trial/consent") {
      // The broker's: the ticket is the proof, so there is no reader.
      const a = await args(req);
      if (typeof a.account !== "string" || typeof a.ticket !== "string" || !(await trialOn(a.account))) return json(404, { error: "not found" });
      const res = await asService("billing_trial_take", { account: a.account, ticket: a.ticket });
      if (!res.ok) throw new Error(`billing_trial_take answered ${res.status}: ${brief(await res.text())}`);
      const consent = await res.json();
      return consent ? json(200, consent) : json(404, { error: "not found" });
    }
    const account = await reader(req);
    if (account instanceof Response) return account;
    if (!(await trialOn(account))) return json(404, { error: "not found" });
    const a = await args(req, 8192);
    const held = await trialStatus(account);
    if (path === "/billing/trial") {
      const none = { ...held, eligible: false, offers: [] };
      if (held.holds || held.state) return json(200, none);
      const res = await toBroker("/trial/offer", { account, ticket: await trialTicket(account), currency: a.currency }, req.headers.get("authorization"));
      // A broker that does not know trials offers none.
      if (res.status === 404) return json(200, none);
      return res.ok ? json(200, { ...held, ...(await res.json()) }) : res;
    }
    if (a.consent !== true) return json(400, { error: "consent is required" });
    const plan = typeof a.plan === "string" && doc.trial!.plans.includes(a.plan) ? a.plan : null;
    if (!plan || !Number.isInteger(a.amount) || typeof a.currency !== "string" || typeof a.charges_at !== "string" || Number.isNaN(Date.parse(a.charges_at))) {
      return json(400, { error: "plan, amount, currency and charges_at required" });
    }
    if (typeof a.terms !== "string" || a.terms.trim() === "" || a.terms.length > 1000) return json(400, { error: "terms required, at most 1000 characters" });
    if (held.holds || held.state) return json(409, { error: held.holds ? "holds" : "used" });
    const ticket = await trialTicket(account, { plan, amount: a.amount, currency: a.currency, charges_at: a.charges_at, terms: a.terms });
    return await toBroker("/trial/checkout", { account, ticket, locale: a.locale, return: a.return }, req.headers.get("authorization"));
  }

  // `auth`: the reader's session, for a call made on the reader's behalf, which then says which way
  // its Stripe calls go (doorOn); a call with none (the broker's own consent check) says nothing.
  async function toBroker(path: string, args: Record<string, unknown>, auth?: string | null): Promise<Response> {
    const door = auth !== undefined && typeof args.account === "string" ? await doorOn(args.account, auth) : undefined;
    const res = await fetcher(`${brokerAt}${path}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ tenant: origin, ...args, ...(door === undefined ? {} : { door }) }),
      signal: AbortSignal.timeout(20_000),
    });
    return json(res.status, await res.json());
  }

  async function manageOf(account: string): Promise<string | null> {
    const res = await asService("billing_manage", { account });
    if (!res.ok) throw new Error(`billing_manage answered ${res.status}`);
    return await res.json();
  }

  async function args(req: Request, max = 4096): Promise<Record<string, unknown>> {
    const text = await readCapped(req.body, max, req.headers.get("content-length"));
    try {
      const v = JSON.parse(text || "{}");
      return typeof v === "object" && v !== null ? v : {};
    } catch {
      return {};
    }
  }

  const handler = async function handler(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    try {
      if (req.method === "GET" && path === "/.well-known/pronto-billing.json") {
        return new Response(s.document, { headers: { "content-type": "application/json", "cache-control": "max-age=300" } });
      }
      if (req.method === "POST" && path === "/billing/events") {
        const token = await readCapped(req.body, 8192, req.headers.get("content-length"));
        return token === null ? json(413, { error: "too large" }) : await entitle(token);
      }
      if (req.method === "POST" && (path === "/billing/trial" || path === "/billing/trial/checkout" || path === "/billing/trial/consent")) {
        return await trial(req, path);
      }
      if (req.method === "POST" && (path === "/billing/checkout" || path === "/billing/portal" || path === "/billing/resync")) {
        const account = await reader(req);
        if (account instanceof Response) return account;
        const a = await args(req);
        const plan = typeof a.plan === "string" && plans.includes(a.plan) ? a.plan : plans[0];
        if (path === "/billing/checkout") {
          return await toBroker("/checkout", { account, plan, currency: a.currency, locale: a.locale, return: a.return }, req.headers.get("authorization"));
        }
        const manage = await manageOf(account);
        if (!manage) return json(404, { error: "no subscription" });
        if (path === "/billing/portal") return await toBroker("/portal", { account, manage, return: a.return }, req.headers.get("authorization"));
        // What the broker holds now, for a page that waited on a push.
        const res = await toBroker("/resync", { account, manage, plan }, req.headers.get("authorization"));
        if (!res.ok) return res;
        return await entitle((await res.json()).token);
      }
      if (req.method === "GET" && path === "/billing/health") return json(200, { ok: true });
      // The reader's own account read at Stripe through the broker, nothing written: what a flag's live
      // check asks as the tester (PRONTO-218).
      if (req.method === "GET" && path === "/billing/probe") {
        const account = await reader(req);
        if (account instanceof Response) return account;
        return await toBroker("/probe", { account }, req.headers.get("authorization"));
      }
      return json(404, { error: "not found" });
    } catch (e) {
      console.error(`billing: ${(e as Error).message}`);
      return json(502, { error: "billing unavailable" });
    }
  };
  return Object.assign(handler, { grant });
}

if (import.meta.main) {
  const env = (k: string) => {
    const v = Deno.env.get(k);
    if (!v) throw new Error(`${k} is required`);
    return v;
  };
  const billing = service({
    origin: env("ORIGIN"), broker: env("BILLING_BROKER"), brokerInternal: Deno.env.get("BILLING_BROKER_INTERNAL"),
    crud: env("CRUD_URL"), serviceJwt: env("SERVICE_JWT"), document: env("BILLING_DOCUMENT"), grants: Deno.env.get("BILLING_GRANTS"),
    flags: Deno.env.get("BILLING_FLAGS") || undefined, trialFlag: Deno.env.get("BILLING_TRIAL_FLAG") || undefined,
    doorFlag: Deno.env.get("BILLING_DOOR_FLAG") || undefined,
  });
  Deno.serve({ port: Number(Deno.env.get("BILLING_PORT") ?? 8688) }, billing);
  // Until the gateway serves billing_grant, as it does once it has reloaded its schema; with
  // flags, every minute after, so a push reaches the database with no deploy.
  let served = false;
  for (let wait = 1; ; ) {
    try {
      await billing.grant();
      served = true;
      if (!Deno.env.get("BILLING_FLAGS")) break;
      wait = 60;
    } catch (e) {
      wait = Math.min(wait * 2, 60);
      // Before the first success it is the startup race (the door, the gateway not ready yet): a
      // warning that says it will retry. After one, it is real trouble.
      if (served) console.error(`billing: grants not written: ${(e as Error).message}`);
      else console.warn(`billing: grants not written yet, retrying in ${wait} s: ${(e as Error).message}`);
    }
    await new Promise((r) => setTimeout(r, wait * 1000));
  }
}
