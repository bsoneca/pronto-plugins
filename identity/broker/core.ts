// What the identity broker decides, apart from its network: which tenant a
// request is for, the one redirect that tenant may receive, the subject a
// person has in that tenant, and the single-use codes that carry a sign-in
// back. One operator runs the broker; every application is its own tenant.
//
// A tenant is an application's origin, which is also its OAuth client id: a
// public client, proving its code with PKCE, holding no secret and needing no
// registration. Tenants are never merged. A person's subject is a keyed hash
// of the tenant, the provider and the provider's subject, so two applications
// see unrelated subjects for one person, and an application's redirect is its
// own origin's callback for the provider it asks for, exact, never shared or
// wildcarded: the one mecha's auth service signs in at.
import { base64url, sha256url } from "../oidc.ts";
import { MemoryStore, type Store } from "./store.ts";


/**
 * The tenant a client id names, or null: an https origin, bare (no path,
 * query, fragment or credentials), its host lowercase. http is refused, even
 * on localhost: the dev door is https.
 */
export function tenantOf(clientId: unknown): string | null {
  if (typeof clientId !== "string" || clientId.length > 255) return null;
  let url: URL;
  try {
    url = new URL(clientId);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.username || url.password) return null;
  return url.origin === clientId ? url.origin : null;
}

/** The one redirect a tenant may receive for a provider: mecha's auth
 * service's callback for the provider of that name. */
export const callbackOf = (tenant: string, provider: string) => `${tenant}/auth/oidc/${provider}/callback`;

const enc = new TextEncoder();

/** The key a pairwise subject is derived under, from the operator's secret. */
export function pairwiseKey(secret: string): Promise<CryptoKey> {
  if (secret.length < 32) throw new Error("the pairwise secret is at least 32 characters");
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

/**
 * The operator's sectors (BROKER_SECTORS): an application that moved address keeps the subjects it
 * had, so its new origin is mapped to the one its people's subjects were made under, as OpenID's
 * sector_identifier names the host a pairwise subject is computed for. Written
 * "https://new.example=https://old.example", comma separated; both sides bare https origins, a
 * tenant named once, and no sector that is itself mapped (a chain would hide the one in force).
 */
export function sectorsOf(text: string | undefined): Map<string, string> {
  const sectors = new Map<string, string>();
  for (const entry of (text ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    const [from, to, ...rest] = entry.split("=");
    const tenant = tenantOf(from?.trim()), sector = tenantOf(to?.trim());
    if (rest.length > 0 || !tenant || !sector) throw new Error(`BROKER_SECTORS: "${entry}" is not https://tenant=https://sector`);
    if (tenant === sector) throw new Error(`BROKER_SECTORS: ${tenant} is mapped to itself`);
    if (sectors.has(tenant)) throw new Error(`BROKER_SECTORS: ${tenant} is mapped twice`);
    sectors.set(tenant, sector);
  }
  for (const [tenant, sector] of sectors) {
    if (sectors.has(sector)) throw new Error(`BROKER_SECTORS: ${tenant} is mapped to ${sector}, which is mapped in turn`);
  }
  return sectors;
}

/** The origin a tenant's subjects are made under: its sector, else itself. */
export const sectorOf = (sectors: ReadonlyMap<string, string>, tenant: string) => sectors.get(tenant) ?? tenant;

/** A person's subject in one tenant: unrelated across tenants and providers. */
export async function pairwiseSubject(key: CryptoKey, tenant: string, provider: string, providerSub: string): Promise<string> {
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${tenant}\u0000${provider}\u0000${providerSub}`));
  return base64url(new Uint8Array(mac));
}

/** A tenant's sign-in request, as /authorize accepts it. */
export interface AuthRequest {
  tenant: string;
  redirectUri: string;
  provider: string;
  state: string;
  nonce: string;
  challenge: string;
  /** Whether the tenant asked for the person's name and picture (`profile`). */
  profile: boolean;
  /** Whether the tenant asked for the person's verified e-mail address (`email`). */
  email: boolean;
}

/**
 * The request /authorize is asked for, or why not. `redirect` says whether
 * the error may be sent to the redirect: only once the client id and the
 * redirect are known to belong together, and never otherwise.
 */
export function parseAuthorize(q: URLSearchParams, providers: readonly string[]):
  | { ok: true; request: AuthRequest }
  | { ok: false; error: string; redirect: string | null } {
  const tenant = tenantOf(q.get("client_id"));
  if (!tenant) return { ok: false, error: "client_id is not an https origin", redirect: null };
  // The redirect is the provider's, so a provider the broker does not offer
  // names none it could trust.
  const provider = q.get("provider") ?? "";
  if (!providers.includes(provider)) return { ok: false, error: `provider is not one of ${providers.join(", ")}`, redirect: null };
  const redirect = callbackOf(tenant, provider);
  if (q.get("redirect_uri") !== redirect) return { ok: false, error: `redirect_uri is not ${redirect}`, redirect: null };
  const state = q.get("state") ?? "";
  const fail = (error: string) => ({ ok: false as const, error, redirect });
  if (state === "" || state.length > 1024) return { ok: false, error: "state required", redirect: null };
  if (q.get("response_type") !== "code") return fail("unsupported_response_type");
  const scopes = (q.get("scope") ?? "").split(" ");
  if (!scopes.includes("openid")) return fail("invalid_scope");
  if (q.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43}$/.test(q.get("code_challenge") ?? "")) return fail("invalid_request");
  const nonce = q.get("nonce") ?? "";
  if (nonce === "" || nonce.length > 256) return fail("invalid_request");
  return { ok: true, request: { tenant, redirectUri: redirect, provider, state, nonce, challenge: q.get("code_challenge")!, profile: scopes.includes("profile"), email: scopes.includes("email") } };
}

export const pkceMatches = async (verifier: unknown, challenge: string) =>
  typeof verifier === "string" && /^[A-Za-z0-9._~-]{43,128}$/.test(verifier) && (await sha256url(verifier)) === challenge;

/** What a code carries from the provider's callback to the tenant's /token. */
export interface Grant {
  tenant: string;
  redirectUri: string;
  challenge: string;
  nonce: string;
  sub: string;
  provider: string;
  /** The provider's name and picture for the person, where the tenant asked for them. */
  name?: string;
  picture?: string;
  /** The provider's verified e-mail for the person, where the tenant asked for it. */
  email?: string;
}

/** The scope the broker asks the provider for: `openid`, and `profile` and
 * `email` only where the tenant asked for them. */
export const providerScope = (asked: { profile?: boolean; email?: boolean }) =>
  ["openid", ...(asked.profile ? ["profile"] : []), ...(asked.email ? ["email"] : [])].join(" ");

/**
 * What a tenant that asked for `email` is told of the person, from the
 * provider's verified claims: the address, only where the provider says it
 * verified it (`email_verified` true), of a plain shape and at most 254
 * characters; else nothing.
 */
export function emailOf(claims: Record<string, unknown>): { email?: string } {
  if (claims.email_verified !== true || typeof claims.email !== "string") return {};
  const email = claims.email.trim();
  return email.length <= 254 && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? { email } : {};
}

/** The sentence the broker's page adds for a tenant that asked for the
 * person's e-mail: what else it learns. None for any other tenant. */
export const learnsMore = (asked: { profile?: boolean; email?: boolean }) =>
  asked.email ? `It also learns your ${asked.profile ? "name and " : ""}e-mail address.` : "";

/**
 * What a tenant that asked for `profile` is told of the person, from the
 * provider's verified claims: a name, and a picture only at an https address.
 */
export function profileOf(claims: Record<string, unknown>): { name?: string; picture?: string } {
  const name = typeof claims.name === "string" && claims.name.trim() !== "" ? claims.name.trim().slice(0, 120) : undefined;
  const picture = typeof claims.picture === "string" && claims.picture.startsWith("https://") && claims.picture.length <= 2048 ? claims.picture : undefined;
  return { ...(name ? { name } : {}), ...(picture ? { picture } : {}) };
}

/**
 * Single-use, short-lived codes, kept in the store so the replica that mints a code need not be the one
 * that redeems it: `take` deletes as it reads, so a code is redeemed once across all of them.
 */
export class Codes {
  constructor(readonly store: Store = new MemoryStore(), readonly ttlMs = 60_000) {}
  async issue(grant: Grant, code = crypto.randomUUID()): Promise<string> {
    await this.store.put("code", code, grant, this.ttlMs);
    return code;
  }
  async take(code: unknown): Promise<Grant | null> {
    if (typeof code !== "string") return null;
    return (await this.store.take<Grant>("code", code)) ?? null;
  }
}

/**
 * The grant a /token request redeems, or why not: the code taken once, for
 * the tenant and redirect it was issued to, proven by the PKCE verifier.
 */
export async function redeem(codes: Codes, form: URLSearchParams):
  Promise<{ ok: true; grant: Grant } | { ok: false; error: string }> {
  if (form.get("grant_type") !== "authorization_code") return { ok: false, error: "unsupported_grant_type" };
  const grant = await codes.take(form.get("code"));
  if (!grant) return { ok: false, error: "invalid_grant" };
  if (form.get("client_id") !== grant.tenant || form.get("redirect_uri") !== grant.redirectUri) return { ok: false, error: "invalid_grant" };
  if (!(await pkceMatches(form.get("code_verifier"), grant.challenge))) return { ok: false, error: "invalid_grant" };
  return { ok: true, grant };
}

/** The ID token a tenant receives: its audience is the tenant alone. */
export function idTokenClaims(p: { issuer: string; grant: Grant; now?: number }): Record<string, unknown> {
  const now = p.now ?? Math.floor(Date.now() / 1000);
  return {
    iss: p.issuer,
    aud: p.grant.tenant,
    azp: p.grant.tenant,
    sub: p.grant.sub,
    nonce: p.grant.nonce,
    idp: p.grant.provider,
    ...(p.grant.name ? { name: p.grant.name } : {}),
    ...(p.grant.picture ? { picture: p.grant.picture } : {}),
    ...(p.grant.email ? { email: p.grant.email, email_verified: true } : {}),
    iat: now,
    exp: now + 300,
  };
}

// A page's text, escaped; and a JSON answer no cache keeps. Here, apart from the network, so the
// phone (phone.ts) shares them with main.ts without importing main.ts.
export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

// In-app browsers (PRONTO-448). An app's ad lands its players in Instagram's, Facebook's, Messenger's,
// TikTok's or Line's own browser, a webview. Sign-in here is a same-tab redirect throughout (the
// terminal's provider link, the auth service, this page, the provider and back), never a popup, so
// it works in a webview, except at a provider that refuses webviews outright: Google answers
// "403 disallowed_useragent". There this page offers the reader's own browser instead, where the
// same sign-in starts again, and the app's passkey and e-mail stay where they were.

/** The in-app browser a user agent names, or null for a browser of its own. */
export function webviewOf(ua: string | null | undefined): { app: string; os: "android" | "ios" | "other" } | null {
  const s = ua ?? "";
  const os = /Android/.test(s) ? "android" : /iPhone|iPad|iPod/.test(s) ? "ios" : "other";
  const named: [RegExp, string][] = [
    [/\bInstagram\b/, "instagram"],
    [/FBAN\/Messenger|\bMessengerForiOS\b|\bOrca-Android\b|\bMessengerLite/, "messenger"],
    [/\bFBAN\/|\bFBAV\/|\bFB_IAB\//, "facebook"],
    [/\bmusical_ly\b|\bTikTok\b|\bBytedanceWebview\b|\bByteLocale\b/, "tiktok"],
    [/\bLine\/\d/, "line"],
  ];
  for (const [re, app] of named) if (re.test(s)) return { app, os };
  // Any other Android webview says `wv` in its platform; an iOS one is WebKit without Safari's
  // token (Chrome, Firefox and Edge on iOS name themselves, and are browsers).
  if (os === "android" && /;\s*wv\)/.test(s)) return { app: "webview", os };
  if (os === "ios" && /AppleWebKit/.test(s) && !/Safari\/|CriOS|FxiOS|EdgiOS|OPiOS/.test(s)) return { app: "webview", os };
  return null;
}

/** How a sign-in with `provider` goes on for this user agent: "redirect" (the provider's own
 * pages, same tab), or "open-in-browser" where the provider refuses this webview. */
export const signInFlow = (ua: string | null | undefined, provider: { refusesWebviews?: boolean }) =>
  provider.refusesWebviews && webviewOf(ua) ? "open-in-browser" : "redirect";

/** Where the reader's own browser starts the same sign-in: the tenant's auth service's start for the
 * provider (mecha's, beside callbackOf's callback), back at the app's front page. */
export const startOf = (tenant: string, provider: string) => `${tenant}/auth/oidc/${provider}/start?return=%2F`;

/** An Android link that opens `url` in the reader's default browser, out of the webview; a browser
 * that cannot follow it goes to `url` itself. */
export function intentOf(url: string): string {
  const u = new URL(url);
  return `intent://${u.host}${u.pathname}${u.search}#Intent;scheme=${u.protocol.replace(":", "")};action=android.intent.action.VIEW;S.browser_fallback_url=${encodeURIComponent(url)};end`;
}

const APP_NAMES: Record<string, string> = { instagram: "Instagram", facebook: "Facebook", messenger: "Messenger", tiktok: "TikTok", line: "LINE" };

/** The page's body where the provider refuses the webview: open the sign-in in the reader's own
 * browser (Android: one tap; iOS: the in-app browser's menu, or the link copied). No script: the
 * page's CSP allows none. */
export function openInBrowserBody(p: { host: string; label: string; url: string; webview: { app: string; os: string } }): string {
  const inApp = APP_NAMES[p.webview.app] ? `${APP_NAMES[p.webview.app]}'s browser` : "this app's browser";
  const how = p.webview.os === "android"
    ? `<p><a class="go" data-open-in-browser href="${esc(intentOf(p.url))}">Open in your browser</a></p>`
    : `<p>Tap <b>•••</b> (or the share button) and choose <b>Open in browser</b>${p.webview.os === "ios" ? " (Safari)" : ""}. Or copy this link into your browser:</p>
<p><input data-open-in-browser readonly value="${esc(p.url)}" aria-label="Sign-in link" style="width:100%;font:inherit;padding:.5rem"></p>`;
  return `<h1>Open <span class="origin">${esc(p.host)}</span> in your browser</h1>
<p>${esc(p.label)} doesn't allow signing in inside ${esc(inApp)}. Sign in from your phone's own browser instead.</p>
${how}
<p><small>Or go back and sign in another way the app offers here, such as a passkey.</small></p>`;
}
