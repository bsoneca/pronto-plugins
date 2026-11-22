// Facebook sign-in (PRONTO-449): the broker's third provider, beside Google and the phone. A person is sent
// to Meta's dialog by a plain redirect (no script, no popup: the in-app browsers of Facebook and Instagram,
// where most of the traffic comes from, follow it as any browser does), comes back with a code, and the
// broker exchanges it, asks Graph who they are, and forgets the access token. The tenant learns a pairwise
// subject made from the app-scoped id, the name and picture when it asked for them, and never an e-mail:
// Meta does not say an address is verified, and public_profile needs no App Review.
//
// The code leg is protected with PKCE: the verifier waits in the store under the leg's own id (the leg is
// signed, not encrypted, so it cannot ride in it) and goes to Meta with the code. A broker with no
// FACEBOOK_APP_ID does not offer Facebook at all; a half-set one does not start. The facts (Graph's
// version, the endpoints, the permission, the flag, the limits) are facebook.cue's, exported to
// facebook_spec.json.
import spec from "./facebook_spec.json" with { type: "json" };
import { Refused } from "../oidc.ts";
import type { KeySource } from "../oidc.ts";
import type { Provider } from "./main.ts";
import { tenantAdmitted } from "./phone.ts";

export const FACEBOOK = spec;

/** The settings a deployment gives the broker: the app's id and secret (Meta's console), and the tenants that may offer it. */
export interface FacebookConfig {
  appId: string;
  secret: string;
  tenants: string[];
  /** Meta's endpoints, which a test's stand-in or a staging proxy replaces. */
  dialog: string;
  token: string;
  me: string;
}

/** Facebook's settings, or null where the operator configured none. A half-set configuration is an error, not a missing provider. */
export function facebookConfig(env: (k: string) => string | undefined): FacebookConfig | null {
  const appId = env("FACEBOOK_APP_ID") ?? "", secret = env("FACEBOOK_APP_SECRET") ?? "";
  const tenants = (env("FACEBOOK_TENANTS") ?? "").split(",").map((t) => t.trim()).filter((t) => t !== "");
  if (appId === "" && secret === "" && tenants.length === 0) return null;
  if (!/^[0-9]{5,20}$/.test(appId)) throw new Error("FACEBOOK_APP_ID is Meta's app id, digits only (the public one)");
  if (secret === "") throw new Error("FACEBOOK_APP_ID needs FACEBOOK_APP_SECRET: the broker keeps the secret, the airlock does not hold it");
  if (!/^[0-9a-f]{32}$/.test(secret) && env("FACEBOOK_TEST_ENDPOINTS") !== "1") throw new Error("FACEBOOK_APP_SECRET is not an app secret (32 hex characters)");
  if (tenants.length === 0) throw new Error("FACEBOOK_APP_ID needs FACEBOOK_TENANTS: Meta's consent dialog shows one app name, so the operator lists the tenants that may offer it");
  return {
    appId, secret, tenants,
    dialog: endpoint(env, "FACEBOOK_DIALOG_URL", spec.dialog),
    token: endpoint(env, "FACEBOOK_TOKEN_URL", spec.token),
    me: endpoint(env, "FACEBOOK_ME_URL", spec.me),
  };
}

/** One of Meta's endpoints: the spec's, or the operator's override, which is https unless FACEBOOK_TEST_ENDPOINTS=1 (a test's stand-in): the secret and the people's tokens never go over plain http by a forgotten staging value. */
function endpoint(env: (k: string) => string | undefined, name: string, spec: string): string {
  const v = env(name);
  if (!v) return spec;
  if (!v.startsWith("https://") && env("FACEBOOK_TEST_ENDPOINTS") !== "1") throw new Error(`${name} is not https: the app secret and people's tokens would go in the clear`);
  console.warn(`broker: ${name} overrides Meta's endpoint with ${new URL(v).origin}`);
  return v;
}

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** The proof Meta asks of a server call that carries an access token: HMAC-SHA256 of the token under the app secret, in hex. */
export async function appSecretProof(token: string, secret: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(token)));
}

/** A key source for a provider that signs nothing the broker reads: Facebook's answer is read from Graph, never from a token. */
const noKeys: KeySource = () => Promise.reject(new Refused("facebook has no signing keys"));

/**
 * Who Facebook says the person is: the exchange's access token is read once, Graph's /me answers with the
 * app-scoped id (and the name and picture when asked), and the token goes no further. A Facebook that
 * does not answer, or answers without an id, refuses the sign-in.
 */
export async function claimsFrom(
  cfg: FacebookConfig, exchanged: Response, wantProfile: boolean, fetcher: typeof fetch = fetch,
): Promise<Record<string, unknown> & { sub: string }> {
  const answer = await exchanged.json().catch(() => null) as { access_token?: unknown } | null;
  const access = answer?.access_token;
  if (typeof access !== "string" || access === "") throw new Refused("facebook's exchange gave no access token");
  const fields = [...spec.fields.base, ...(wantProfile ? spec.fields.profile : [])].join(",");
  const to = new URL(cfg.me);
  // The token goes in a header, not the URL: a failed request's error names its URL, and the log must never hold a person's token.
  to.search = new URLSearchParams({ fields, appsecret_proof: await appSecretProof(access, cfg.secret) }).toString();
  let res: Response;
  try {
    res = await fetcher(to, { headers: { authorization: `Bearer ${access}` }, signal: AbortSignal.timeout(spec.limits.me_ms), redirect: "error" });
  } catch (e) {
    throw new Refused(`facebook's /me did not answer (${e instanceof Error ? e.name : "error"})`);
  }
  if (!res.ok) {
    await res.body?.cancel();
    throw new Refused(`facebook's /me answered ${res.status}`);
  }
  const me = await res.json().catch(() => null) as { id?: unknown; name?: unknown; picture?: { data?: { url?: unknown } } } | null;
  if (typeof me?.id !== "string" || !/^[0-9]{1,30}$/.test(me.id)) throw new Refused("facebook's /me gave no app-scoped id");
  const picture = me.picture?.data?.url;
  return {
    sub: me.id,
    ...(wantProfile && typeof me.name === "string" ? { name: me.name } : {}),
    ...(wantProfile && typeof picture === "string" ? { picture } : {}),
  };
}

/** The broker's Facebook provider for these settings (main.ts shapes the leg, and asks `flag` of the tenant when a sign-in begins). */
export function facebook(cfg: FacebookConfig, fetcher: typeof fetch = fetch): Provider {
  return {
    name: "facebook",
    label: spec.label,
    authUrl: cfg.dialog,
    tokenUrl: cfg.token,
    issuers: [],
    keys: noKeys,
    clientId: cfg.appId,
    clientSecret: cfg.secret,
    refusesWebviews: spec.refusesWebviews,
    admits: (tenant) => tenantAdmitted(cfg.tenants, tenant),
    flag: spec.flag,
    pkce: spec.pkce,
    scope: spec.permissions.join(" "),
    claims: (exchanged, ctx) => claimsFrom(cfg, exchanged, ctx.profile, fetcher),
  };
}
