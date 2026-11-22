// A stand-in for Facebook on a developer's machine (PRONTO-449), where the operator's Meta app and its secret are not: the front serves it
// under /fake/facebook, and it signs in whichever test person the reader picks. It speaks just enough of Meta's code flow for the front's
// own leg (the dialog, the token endpoint that checks the secret and the PKCE verifier, Graph's /me that checks the app-secret proof), as the
// broker's facebook.ts reads them, and nothing outside a localhost broker ever reaches it (front.ts refuses it on any other issuer).
import { randomToken, sha256url } from "../oidc.ts";
import { esc, json, page, type Provider } from "../broker/main.ts";
import { appSecretProof, facebook } from "../broker/facebook.ts";
import { FRESH, PEOPLE } from "./fake.ts";

const CLIENT = "100000000000001";
const SECRET = "fa".repeat(16);

/** A Facebook-shaped id for a test person: digits only, as Graph's are, the same for the same person. */
const idOf = (who: string) => `9${[...who].reduce((n, c) => (n * 31 + c.charCodeAt(0)) % 1_000_000_007, 7)}`.padEnd(15, "0");

export function fakeFacebook(issuer: string, fetcher: typeof fetch = fetch): { provider: Provider; handle: (req: Request, url: URL) => Promise<Response> | null } {
  const base = `${issuer.replace(/\/$/, "")}/fake/facebook`;
  const asked = new Map<string, { state: string; redirect: string; challenge: string; expires: number }>();
  const codes = new Map<string, { who: string; redirect: string; challenge: string; expires: number }>();
  const tokens = new Map<string, { who: string; expires: number }>();
  const live = <T extends { expires: number }>(m: Map<string, T>, k: string | null) => {
    const v = k === null ? undefined : m.get(k);
    if (k !== null) m.delete(k);
    return v && v.expires > Date.now() ? v : undefined;
  };
  const peek = <T extends { expires: number }>(m: Map<string, T>, k: string | null) => {
    const v = k === null ? undefined : m.get(k);
    return v && v.expires > Date.now() ? v : undefined;
  };

  function dialog(url: URL): Response {
    const q = url.searchParams;
    if (q.get("client_id") !== CLIENT || !q.get("redirect_uri") || !q.get("state") || !q.get("code_challenge") || q.get("code_challenge_method") !== "S256") {
      return page("Test sign-in refused", `<h1>This test sign-in can't continue</h1>`, 400);
    }
    const id = randomToken(16);
    asked.set(id, { state: q.get("state")!, redirect: q.get("redirect_uri")!, challenge: q.get("code_challenge")!, expires: Date.now() + 600_000 });
    const links = PEOPLE.map((who) => `<p><a class="go" href="${esc(`${base}/approve?id=${id}&who=${who}`)}">Continue as ${esc(who)}</a></p>`).join("\n");
    return page("Test sign-in", `<h1>Test sign-in</h1>
<p>This is not Facebook: the broker on this machine has no Meta app, so it signs in a test person instead.</p>
${links}`);
  }

  function approve(url: URL): Response {
    const a = live(asked, url.searchParams.get("id"));
    const who = url.searchParams.get("who") ?? "";
    if (!a || !(PEOPLE.includes(who) || FRESH.test(who))) return page("Test sign-in expired", `<h1>This test sign-in expired</h1><p>Go back to the app and start again.</p>`, 400);
    const code = randomToken(16);
    codes.set(code, { who, redirect: a.redirect, challenge: a.challenge, expires: Date.now() + 60_000 });
    const to = new URL(a.redirect);
    to.searchParams.set("code", code);
    to.searchParams.set("state", a.state);
    return new Response(null, { status: 302, headers: { location: to.toString(), "cache-control": "no-store" } });
  }

  async function token(req: Request): Promise<Response> {
    const f = new URLSearchParams(await req.text());
    const c = live(codes, f.get("code"));
    const verifier = f.get("code_verifier");
    if (!c || f.get("client_id") !== CLIENT || f.get("client_secret") !== SECRET || f.get("redirect_uri") !== c.redirect || !verifier || (await sha256url(verifier)) !== c.challenge) {
      return json(400, { error: { message: "invalid_grant" } });
    }
    const access = `AT-${randomToken(16)}`;
    tokens.set(access, { who: c.who, expires: Date.now() + 60_000 });
    return json(200, { access_token: access, token_type: "bearer", expires_in: 60 });
  }

  async function me(req: Request, url: URL): Promise<Response> {
    const access = req.headers.get("authorization")?.match(/^Bearer (AT-[A-Za-z0-9_-]+)$/)?.[1] ?? null;
    const t = peek(tokens, access);
    if (!t || url.searchParams.get("appsecret_proof") !== (await appSecretProof(access!, SECRET))) return json(403, { error: { code: 190 } });
    const asks = (url.searchParams.get("fields") ?? "").split(",");
    return json(200, {
      id: idOf(t.who),
      ...(asks.includes("name") ? { name: `Test ${t.who}` } : {}),
      ...(asks.some((x) => x.startsWith("picture")) ? { picture: { data: { url: `https://platform-lookaside.fbsbx.com/fake-${t.who}.jpg` } } } : {}),
    });
  }

  // The settings Meta's endpoints are replaced with: this stand-in's, under the issuer.
  const cfg = {
    appId: CLIENT, secret: SECRET, tenants: ["*"], dialog: `${base}/dialog`, token: `${base}/token`, me: `${base}/me`,
  };
  const provider = facebook(cfg, fetcher);
  return {
    // Any tenant of the local broker may offer it: the operator's list is for the one Meta app, which there is none of here.
    provider: { ...provider, admits: () => true },
    handle(req, url) {
      if (req.method === "GET" && url.pathname === "/fake/facebook/dialog") return Promise.resolve(dialog(url));
      if (req.method === "GET" && url.pathname === "/fake/facebook/approve") return Promise.resolve(approve(url));
      if (req.method === "POST" && url.pathname === "/fake/facebook/token") return token(req);
      if (req.method === "GET" && url.pathname === "/fake/facebook/me") return me(req, url);
      return null;
    },
  };
}
