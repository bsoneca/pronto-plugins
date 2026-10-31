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
  fetcher?: typeof fetch;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function service(s: Settings) {
  const fetcher = s.fetcher ?? fetch;
  const origin = s.origin.replace(/\/$/, "");
  const issuer = s.broker.replace(/\/$/, "");
  const brokerAt = (s.brokerInternal || s.broker).replace(/\/$/, "");
  const crud = s.crud.replace(/\/$/, "");
  const keys = brokerKeys(brokerAt, fetcher);
  const plans = Object.keys((JSON.parse(s.document) as { plans: Record<string, unknown> }).plans);

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
    if (!res.ok) throw new Error(`billing_grant answered ${res.status}: ${await res.text()}`);
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
    if (!res.ok) throw new Error(`flag billing_grants answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
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
    if (!res.ok) throw new Error(`billing_entitle answered ${res.status}: ${await res.text()}`);
    await res.body?.cancel();
    return new Response(null, { status: 204 });
  }

  async function toBroker(path: string, args: Record<string, unknown>): Promise<Response> {
    const res = await fetcher(`${brokerAt}${path}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ tenant: origin, ...args }),
      signal: AbortSignal.timeout(20_000),
    });
    return json(res.status, await res.json());
  }

  async function manageOf(account: string): Promise<string | null> {
    const res = await asService("billing_manage", { account });
    if (!res.ok) throw new Error(`billing_manage answered ${res.status}`);
    return await res.json();
  }

  async function args(req: Request): Promise<Record<string, unknown>> {
    const text = await readCapped(req.body, 4096, req.headers.get("content-length"));
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
      if (req.method === "POST" && (path === "/billing/checkout" || path === "/billing/portal" || path === "/billing/resync")) {
        const account = await reader(req);
        if (account instanceof Response) return account;
        const a = await args(req);
        const plan = typeof a.plan === "string" && plans.includes(a.plan) ? a.plan : plans[0];
        if (path === "/billing/checkout") {
          return await toBroker("/checkout", { account, plan, currency: a.currency, locale: a.locale, return: a.return });
        }
        const manage = await manageOf(account);
        if (!manage) return json(404, { error: "no subscription" });
        if (path === "/billing/portal") return await toBroker("/portal", { account, manage, return: a.return });
        // What the broker holds now, for a page that waited on a push.
        const res = await toBroker("/resync", { account, manage, plan });
        if (!res.ok) return res;
        return await entitle((await res.json()).token);
      }
      if (req.method === "GET" && path === "/billing/health") return json(200, { ok: true });
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
    flags: Deno.env.get("BILLING_FLAGS") || undefined,
  });
  Deno.serve({ port: Number(Deno.env.get("BILLING_PORT") ?? 8688) }, billing);
  // Until the gateway serves billing_grant, as it does once it has reloaded its schema; with
  // flags, every minute after, so a push reaches the database with no deploy.
  for (let wait = 1; ; ) {
    try {
      await billing.grant();
      if (!Deno.env.get("BILLING_FLAGS")) break;
      wait = 60;
    } catch (e) {
      console.error(`billing: grants not written: ${(e as Error).message}`);
      wait = Math.min(wait * 2, 60);
    }
    await new Promise((r) => setTimeout(r, wait * 1000));
  }
}
