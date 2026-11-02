// The phone as a provider: Identity Platform's phone sign-in (Firebase Authentication) behind the
// same code flow every other provider speaks, served by the broker itself under /phone, as the
// stand-in for Google is under /fake/google. The broker's own legs (/authorize or Hydra's login,
// the provider's callback, the pairwise subject) are unchanged: to them this is one more provider,
// whose authorize page asks for a number, has Firebase text it a code, and takes the ID token
// Firebase gives back once the code is typed; whose token endpoint answers an ID token of its own,
// signed with a key minted at start, its subject the Firebase user's (one per phone number).
//
// What a tenant learns is what it learns from Google with scope openid: a pairwise subject. The
// number goes no further than this page and Firebase: it is in no claim, no log and no code.
//
// Firebase texts no one the operator did not admit. Identity Platform's beforeSendSms blocking
// function is the project's one gate for every SMS, whoever asks; it belongs to whoever the
// operator registered it for, which keeps the caps (per phone, device, network, with a resend
// wait). The page asks that gate's owner for a code first (PHONE_ADMIT, from the reader's own
// browser, so the caps count the reader's network), then has Firebase send it. Only the tenants
// the operator lists (PHONE_TENANTS) may offer the phone: each SMS is the operator's cost.
//
// Locally (PHONE_EMULATOR, a localhost broker only) the page signs in against the Firebase Auth
// emulator, which sends no SMS and whose tokens are unsigned.
import { base64url, fromBase64url, jwksSource, type KeySource, randomToken, Refused, verifyIdToken } from "../oidc.ts";
import { esc, json, type Provider } from "./main.ts";

const enc = new TextEncoder();

/** Firebase's signing keys for its ID tokens, and the issuer prefix a project's tokens carry. */
export const FIREBASE_JWKS = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
export const FIREBASE_ISSUER = "https://securetoken.google.com/";
/** The Firebase JS SDK the page imports from gstatic, as the operator's phone page pins it. */
export const SDK = "13.1.0";
/** A Brazilian mobile, in E.164: +55, a two-digit area code, a 9 and eight digits. */
export const BRAZIL_MOBILE = "^\\+55[1-9][1-9]9[0-9]{8}$";

export interface PhoneConfig {
  /** The Firebase project whose Identity Platform sends the codes (the emulator's demo- project locally). */
  project: string;
  apiKey: string;
  authDomain: string;
  appId: string;
  sdk: string;
  /** The tenants that may offer the phone: origins, a `*` standing for a port. */
  tenants: string[];
  /** Where the page asks for a code before Firebase sends one: the beforeSendSms gate's owner. */
  admit: string;
  /** The Firebase Auth emulator's host:port, on a localhost broker only. */
  emulator: string | null;
  resendSeconds: number;
  /** The numbers the page accepts (E.164), Brazil's mobiles unless said otherwise. */
  pattern: string;
}

/** The phone's settings from the broker's environment, or null when PHONE_PROJECT is not set. */
export function phoneConfig(env: (k: string) => string | undefined, issuer: string): PhoneConfig | null {
  const project = env("PHONE_PROJECT");
  if (!project) return null;
  const need = (k: string) => {
    const v = env(k);
    if (!v) throw new Error(`${k} is required with PHONE_PROJECT`);
    return v;
  };
  const emulator = env("PHONE_EMULATOR") || null;
  if (emulator !== null) {
    if (new URL(issuer).hostname !== "localhost") throw new Error(`PHONE_EMULATOR is for a localhost broker, not ${issuer}`);
    if (!/^[A-Za-z0-9.-]+:[0-9]+$/.test(emulator)) throw new Error("PHONE_EMULATOR is host:port");
  }
  const admit = need("PHONE_ADMIT");
  if (!/^https?:\/\//.test(admit)) throw new Error("PHONE_ADMIT is an http(s) URL");
  const tenants = need("PHONE_TENANTS").split(",").map((t) => t.trim()).filter((t) => t !== "");
  const resendSeconds = Number(env("PHONE_RESEND_SECONDS") || "60");
  if (!Number.isInteger(resendSeconds) || resendSeconds <= 0) throw new Error("PHONE_RESEND_SECONDS is a whole number of seconds");
  return {
    project,
    apiKey: emulator ? env("PHONE_API_KEY") || "emulator" : need("PHONE_API_KEY"),
    authDomain: env("PHONE_AUTH_DOMAIN") || `${project}.firebaseapp.com`,
    appId: emulator ? env("PHONE_APP_ID") || "emulator" : need("PHONE_APP_ID"),
    sdk: env("PHONE_SDK") || SDK,
    tenants,
    admit,
    emulator,
    resendSeconds,
    pattern: env("PHONE_PATTERN") || BRAZIL_MOBILE,
  };
}

/** Whether a tenant is one the operator lets offer the phone: exact, or with `*` for a port. */
export function tenantAdmitted(tenants: readonly string[], tenant: string): boolean {
  return tenants.some((t) => new RegExp("^" + t.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[0-9]+") + "$").test(tenant));
}

/** The page's words, by language: Portuguese for a reader whose browser asks for it first, else English. */
export const STRINGS = {
  en: {
    title: "Sign in with your phone",
    intro: "Type your mobile number. We'll text you a 6-digit code to sign in to",
    number: "Mobile number with area code",
    send: "Text me a code",
    sms_said: "We'll send a 6-digit code by SMS to the number below. The SMS costs you nothing.",
    sent_to: "Code sent to",
    code: "6-digit code",
    confirm: "Sign in",
    resend: "Text a new code",
    resend_in: "You can ask for a new code in {s} s",
    wrong_number: "Type a Brazilian mobile with its area code, such as (11) 91234-5678.",
    wrong_code: "That code is wrong. Check it and try again.",
    expired: "That code has expired. Ask for a new one.",
    cooldown: "A code was just sent. Wait a minute before asking for another.",
    too_many: "Too many codes were asked for this number or network. Try again later.",
    region: "Only Brazilian mobile numbers can sign in this way.",
    down: "The SMS sign-in isn't available right now. Try again in a few minutes, or go back and continue with Google.",
    change: "Use another number",
    back: "Back to the app",
    footer: "Only the app learns that it's you, and it can't tell you apart in any other app. It never learns your number from this sign-in.",
  },
  "pt-BR": {
    title: "Entrar com celular",
    intro: "Digite seu celular. Vamos enviar um código de 6 dígitos por SMS para você entrar em",
    number: "Celular com DDD",
    send: "Enviar código por SMS",
    sms_said: "Vamos enviar um código de 6 dígitos por SMS para o número abaixo. Receber o SMS não tem custo para você.",
    sent_to: "Código enviado para",
    code: "Código de 6 dígitos",
    confirm: "Entrar",
    resend: "Enviar novo código",
    resend_in: "Você pode pedir um novo código em {s} s",
    wrong_number: "Digite um celular do Brasil com DDD, como (11) 91234-5678.",
    wrong_code: "Código errado. Confira e tente de novo.",
    expired: "Esse código expirou. Peça um novo.",
    cooldown: "Acabamos de enviar um código. Espere um minuto para pedir outro.",
    too_many: "Pedimos códigos demais para este número ou rede. Tente mais tarde.",
    region: "Só celulares do Brasil podem entrar assim.",
    down: "O acesso por SMS não está disponível agora. Tente de novo em alguns minutos, ou volte e continue com o Google.",
    change: "Usar outro número",
    back: "Voltar ao app",
    footer: "Só o app fica sabendo que é você, e ele não consegue te reconhecer em nenhum outro app. Ele não recebe seu número por este acesso.",
  },
} as const;
export type Lang = keyof typeof STRINGS;

/** The page's language from the reader's Accept-Language: the first of ours it names. */
export function langOf(accept: string | null): Lang {
  for (const part of (accept ?? "").split(",")) {
    const tag = part.split(";")[0].trim().toLowerCase();
    if (tag.startsWith("pt")) return "pt-BR";
    if (tag.startsWith("en")) return "en";
  }
  return "en";
}

/** The page's content security policy: Firebase's SDK and reCAPTCHA, the gate, and the emulator locally. */
export function pageCsp(cfg: PhoneConfig): string {
  const admit = new URL(cfg.admit).origin;
  const emulator = cfg.emulator ? ` http://${cfg.emulator}` : "";
  return [
    "default-src 'none'",
    "script-src 'self' https://www.gstatic.com https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/",
    `frame-src https://www.google.com/recaptcha/ https://recaptcha.google.com/recaptcha/ https://${cfg.authDomain}`,
    `connect-src 'self' ${admit} https://identitytoolkit.googleapis.com https://securetoken.googleapis.com https://www.google.com/recaptcha/${emulator}`,
    "img-src https://www.gstatic.com data:",
    "style-src 'unsafe-inline'",
    "form-action 'none'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
  ].join("; ");
}

/** What is wrong with a Firebase ID token's claims for a phone sign-in: "" for none. */
export function firebaseProblem(claims: Record<string, unknown>, cfg: PhoneConfig, nowS: number, since: number): string {
  const skew = 60;
  const fb = claims.firebase as { sign_in_provider?: unknown } | undefined;
  if (claims.iss !== FIREBASE_ISSUER + cfg.project || claims.aud !== cfg.project) return "issuer";
  if (typeof claims.sub !== "string" || claims.sub === "" || claims.sub.length > 128) return "subject";
  if (typeof claims.exp !== "number" || claims.exp <= nowS - skew) return "expired";
  if (fb?.sign_in_provider !== "phone") return "not a phone sign-in";
  // Signed in on this page, during this visit: not a token kept from before.
  if (typeof claims.auth_time !== "number" || claims.auth_time < since - skew || claims.auth_time > nowS + skew) return "auth_time";
  if (typeof claims.phone_number !== "string" || !new RegExp(cfg.pattern).test(claims.phone_number)) return "region";
  return "";
}

const html = (body: string, csp: string, status = 200) =>
  new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": csp, "cache-control": "no-store", "referrer-policy": "no-referrer" } });

export async function phoneUpstream(issuer: string, cfg: PhoneConfig, opts: { keys?: KeySource; now?: () => number } = {}): Promise<{
  provider: Provider;
  handle: (req: Request, url: URL) => Promise<Response> | null;
}> {
  const root = issuer.replace(/\/$/, "");
  const base = `${root}/phone`;
  const callback = `${root}/callback/phone`;
  const ISSUER = base, CLIENT = "phone", SECRET = randomToken(24);
  const now = opts.now ?? Date.now;
  const firebaseKeys = opts.keys ?? jwksSource(FIREBASE_JWKS);
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "phone-1" };
  const asked = new Map<string, { nonce: string; state: string; since: number; expires: number }>();
  const codes = new Map<string, { nonce: string; sub: string; expires: number }>();
  const live = <T extends { expires: number }>(m: Map<string, T>, k: string | null, take: boolean) => {
    const v = k === null ? undefined : m.get(k);
    if (k !== null && take) m.delete(k);
    return v && v.expires > now() ? v : undefined;
  };
  const sweep = () => {
    for (const m of [asked, codes] as Map<string, { expires: number }>[]) for (const [k, v] of m) if (v.expires <= now()) m.delete(k);
  };
  const csp = pageCsp(cfg);

  function authorize(req: Request, url: URL): Response {
    const q = url.searchParams;
    if (q.get("client_id") !== CLIENT || q.get("redirect_uri") !== callback || !q.get("state") || !q.get("nonce")) {
      return html(`<!doctype html><title>Sign-in refused</title><p>This sign-in can't continue. Go back to the app and start again.</p>`, csp, 400);
    }
    sweep();
    const id = randomToken(16);
    asked.set(id, { nonce: q.get("nonce")!, state: q.get("state")!, since: Math.floor(now() / 1000), expires: now() + 900_000 });
    const lang = langOf(req.headers.get("accept-language"));
    const s = STRINGS[lang];
    const cancel = `${callback}?${new URLSearchParams({ error: "access_denied", state: q.get("state")! })}`;
    const config = {
      id, admit: cfg.admit, project: cfg.project, apiKey: cfg.apiKey, authDomain: cfg.authDomain, appId: cfg.appId, sdk: cfg.sdk,
      emulator: cfg.emulator ? `http://${cfg.emulator}` : null, resendSeconds: cfg.resendSeconds, pattern: cfg.pattern, strings: s,
    };
    // The config rides in a data block the CSP does not run; </ is escaped so it cannot end it.
    const data = JSON.stringify(config).replace(/</g, "\\u003c");
    return html(`<!doctype html>
<html lang="${lang}">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">
<title>${esc(s.title)}</title>
<style>${STYLE}</style></head>
<body><main>
<h1>${esc(s.title)}</h1>
<p class="notice" id="phone-notice" role="alert" hidden></p>
<form id="phone-ask" novalidate>
  <label for="phone-number">${esc(s.number)}</label>
  <div class="tel"><span aria-hidden="true">+55</span><input id="phone-number" name="phone" type="tel" inputmode="numeric" autocomplete="tel-national" placeholder="(11) 91234-5678" maxlength="16" required></div>
  <p class="sms-said">${esc(s.sms_said)}</p>
  <button type="submit" class="primary" id="phone-send">${esc(s.send)}</button>
</form>
<form id="phone-check" novalidate hidden>
  <p>${esc(s.sent_to)} <strong class="e164" data-e164></strong></p>
  <label for="phone-code">${esc(s.code)}</label>
  <input id="phone-code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" required>
  <p class="notice wrong-code" role="alert" hidden></p>
  <button type="submit" class="primary" id="phone-confirm">${esc(s.confirm)}</button>
  <button type="button" id="phone-resend" disabled></button>
  <button type="button" class="link" id="phone-change">${esc(s.change)}</button>
</form>
<div id="recaptcha"></div>
<p><a class="back" id="phone-back" href="${esc(cancel)}">${esc(s.back)}</a></p>
<p><small>${esc(s.footer)}</small></p>
</main>
<script type="application/json" id="phone-config">${data}</script>
<script type="module" src="${esc(`${base}/page.js`)}"></script>
</body></html>
`, csp);
  }

  async function verifyFirebase(token: string, since: number): Promise<Record<string, unknown> & { sub: string }> {
    let claims: Record<string, unknown> & { sub: string };
    if (cfg.emulator) {
      // The emulator's token is unsigned (alg none): only a localhost broker ever takes one (phoneConfig).
      const parts = token.split(".");
      let header: { alg?: string };
      try {
        header = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0])));
        claims = JSON.parse(new TextDecoder().decode(fromBase64url(parts[1])));
      } catch {
        throw new Refused("firebase token malformed");
      }
      if (parts.length !== 3 || header.alg !== "none") throw new Refused("firebase token not the emulator's");
    } else {
      claims = await verifyIdToken(token, { alg: "RS256", issuers: [FIREBASE_ISSUER + cfg.project], audience: cfg.project, nonce: null, keys: firebaseKeys });
    }
    const problem = firebaseProblem(claims, cfg, Math.floor(now() / 1000), since);
    if (problem) throw new Refused(`firebase token ${problem}`);
    return claims;
  }

  // The page's word: the visit it is, and the ID token Firebase gave it. It answers where to go:
  // the broker's callback with a code, or a refusal the page shows.
  async function approve(req: Request): Promise<Response> {
    if ((req.headers.get("content-type") ?? "").split(";")[0] !== "application/json") return json(415, { error: "json" });
    const text = await req.text();
    if (text.length > 8192) return json(413, { error: "too large" });
    let body: { id?: unknown; token?: unknown };
    try {
      body = JSON.parse(text);
    } catch {
      return json(400, { error: "body" });
    }
    const a = live(asked, typeof body.id === "string" ? body.id : null, false);
    if (!a || typeof body.token !== "string") return json(400, { error: "expired" });
    let claims;
    try {
      claims = await verifyFirebase(body.token, a.since);
    } catch (e) {
      if (!(e instanceof Refused)) throw e;
      // Why, on the broker's log; never the number or the token.
      console.error(`broker: phone sign-in refused: ${e.message}`);
      return json(400, { error: e.message.endsWith("region") ? "region" : "refused" });
    }
    asked.delete(body.id as string);
    const code = randomToken(16);
    codes.set(code, { nonce: a.nonce, sub: claims.sub, expires: now() + 60_000 });
    const to = new URL(callback);
    to.searchParams.set("code", code);
    to.searchParams.set("state", a.state);
    return json(200, { to: to.toString() });
  }

  async function token(f: URLSearchParams): Promise<Response> {
    const c = live(codes, f.get("code"), true);
    if (!c || f.get("client_id") !== CLIENT || f.get("client_secret") !== SECRET || f.get("redirect_uri") !== callback) {
      return json(400, { error: "invalid_grant" });
    }
    const t = Math.floor(now() / 1000);
    const head = base64url(enc.encode(JSON.stringify({ alg: "RS256", kid: jwk.kid })));
    const body = base64url(enc.encode(JSON.stringify({ iss: ISSUER, aud: CLIENT, sub: c.sub, nonce: c.nonce, iat: t, exp: t + 300 })));
    const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${head}.${body}`)));
    return json(200, { id_token: `${head}.${body}.${base64url(sig)}`, token_type: "Bearer", expires_in: 300 });
  }

  return {
    provider: {
      name: "phone", label: "your phone", authUrl: `${base}/auth`, tokenUrl: `${base}/token`, issuers: [ISSUER],
      keys: (kid) => Promise.resolve(kid === jwk.kid ? jwk : undefined), clientId: CLIENT, clientSecret: SECRET,
      admits: (tenant) => tenantAdmitted(cfg.tenants, tenant),
      exchange: token,
    },
    handle(req, url) {
      if (req.method === "GET" && url.pathname === "/phone/auth") return Promise.resolve(authorize(req, url));
      if (req.method === "GET" && url.pathname === "/phone/page.js") {
        return Promise.resolve(new Response(SCRIPT, { headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-cache" } }));
      }
      if (req.method === "POST" && url.pathname === "/phone/approve") return approve(req);
      if (req.method === "POST" && url.pathname === "/phone/token") return req.text().then((t) => token(new URLSearchParams(t)));
      return null;
    },
  };
}

// 390 px first: one column, 16 px type (a phone does not zoom a field), targets of at least 48 px.
const STYLE = `:root{color-scheme:light dark;--ink:#1d1b20;--muted:#5a4d6e;--line:#c9c9d3;--accent:#1f4f9e;--danger:#a3331f;--bg:#fafaf7;--field:#fff}
@media (prefers-color-scheme:dark){:root{--ink:#ece7ef;--muted:#b8adc6;--line:#4a4552;--accent:#8fb3ff;--danger:#f0a06b;--bg:#141316;--field:#1e1c21}}
*{box-sizing:border-box}body{margin:0;min-height:100vh;font:16px/1.5 system-ui,sans-serif;background:var(--bg);color:var(--ink)}
main{max-width:28rem;margin:0 auto;padding:24px 16px;display:grid;gap:16px}h1{margin:0;font-size:1.5rem;line-height:1.2}p{margin:0}
[hidden]{display:none!important}form{display:grid;gap:12px}label{color:var(--muted)}
.tel{display:flex;align-items:center;gap:8px;border:1px solid var(--line);border-radius:8px;background:var(--field);padding:0 12px}
.tel span{font-weight:600}.tel input{border:0;padding-left:0}
input{width:100%;min-height:48px;padding:8px 12px;font:inherit;font-size:1.25rem;color:var(--ink);background:var(--field);border:1px solid var(--line);border-radius:8px}
#phone-code{letter-spacing:.3em}
button{min-height:48px;padding:8px 16px;font:inherit;border-radius:8px;border:1px solid var(--line);background:var(--field);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
@media (prefers-color-scheme:dark){button.primary{color:#0d1b33}}
button.link{border:0;background:none;color:var(--accent);text-decoration:underline;min-height:44px}
button:disabled{opacity:.55;cursor:default}button:focus-visible,input:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
.notice{color:var(--danger);font-weight:600}.e164{font-weight:700;letter-spacing:.02em}a{color:var(--accent)}small{color:var(--muted)}`;

// The page's script: plain ES modules from gstatic, no framework. It reads its config from the data
// block, asks the gate for a code, has Firebase send it, and hands the broker the ID token Firebase
// gives back. Nothing is kept: Firebase's persistence is in memory, and it signs out once it has the
// token.
const SCRIPT = `const $ = (s) => document.querySelector(s);
const config = JSON.parse($('#phone-config').textContent);
const t = config.strings;
const pattern = new RegExp(config.pattern);
const notice = (text) => { const el = $('#phone-notice'); el.textContent = text; el.hidden = !text; };

// The national number as typed, kept to its digits and drawn as (11) 91234-5678.
const digitsOf = (v) => v.replace(/\\D/g, '').replace(/^55(?=\\d{11})/, '').slice(0, 11);
const masked = (d) => d.length <= 2 ? (d ? '(' + d : '') : d.length <= 7 ? '(' + d.slice(0, 2) + ') ' + d.slice(2) : '(' + d.slice(0, 2) + ') ' + d.slice(2, 7) + '-' + d.slice(7);
const field = $('#phone-number');
field.addEventListener('input', () => { field.value = masked(digitsOf(field.value)); });

let firebase, auth, verifier, sent = null, e164 = '', timer = 0;
async function start() {
  const base = 'https://www.gstatic.com/firebasejs/' + config.sdk + '/';
  const [{ initializeApp }, a] = await Promise.all([import(base + 'firebase-app.js'), import(base + 'firebase-auth.js')]);
  auth = a;
  const app = initializeApp({ apiKey: config.apiKey, authDomain: config.authDomain, projectId: config.project, appId: config.appId });
  firebase = auth.getAuth(app);
  await auth.setPersistence(firebase, auth.inMemoryPersistence);
  if (config.emulator) {
    auth.connectAuthEmulator(firebase, config.emulator, { disableWarnings: true });
    // The emulator needs no reCAPTCHA: the verifier is the SDK's own test double.
    firebase.settings.appVerificationDisabledForTesting = true;
  }
}
// A fresh invisible reCAPTCHA for each code asked for: one is spent by each send.
function freshVerifier() {
  if (verifier) { try { verifier.clear(); } catch {} }
  const box = document.createElement('div');
  $('#recaptcha').replaceChildren(box);
  verifier = new auth.RecaptchaVerifier(firebase, box, { size: 'invisible' });
}

// The resend button counts down the gate's wait, then offers a new code.
function countdown(seconds) {
  clearInterval(timer);
  const b = $('#phone-resend');
  let left = seconds;
  const draw = () => { b.disabled = left > 0; b.textContent = left > 0 ? t.resend_in.replace('{s}', left) : t.resend; };
  draw();
  timer = setInterval(() => { left -= 1; draw(); if (left <= 0) clearInterval(timer); }, 1000);
}

// The gate's word on a code for this number ('' to go), then Firebase sends it.
async function ask() {
  let said;
  try {
    const res = await fetch(config.admit, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ phone: e164 }), credentials: 'omit' });
    if (!res.ok) throw new Error('admit ' + res.status);
    said = (await res.json()).notice ?? '';
  } catch (e) {
    console.warn('phone: the gate did not answer: ' + (e && e.message));
    return t.down;
  }
  if (said === 'phone-cooldown') return t.cooldown;
  if (said === 'phone-cap') return t.too_many;
  if (said === 'phone-region') return t.region;
  if (said !== '') return t.down;
  try {
    freshVerifier();
    sent = await auth.signInWithPhoneNumber(firebase, e164, verifier);
  } catch (e) {
    const code = (e && e.code) || '';
    console.warn('phone: no code sent: ' + code);
    return code === 'auth/too-many-requests' || code === 'auth/quota-exceeded' ? t.too_many : code === 'auth/invalid-phone-number' ? t.wrong_number : t.down;
  }
  return '';
}

$('#phone-ask').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const d = digitsOf(field.value);
  e164 = '+55' + d;
  if (!pattern.test(e164)) { notice(t.wrong_number); field.focus(); return; }
  const send = $('#phone-send');
  send.disabled = true;
  notice('');
  const problem = await ask();
  send.disabled = false;
  if (problem) { notice(problem); return; }
  $('[data-e164]').textContent = e164;
  $('#phone-ask').hidden = true;
  $('#phone-check').hidden = false;
  countdown(config.resendSeconds);
  $('#phone-code').focus();
});

$('#phone-resend').addEventListener('click', async () => {
  const b = $('#phone-resend');
  b.disabled = true;
  $('.wrong-code').hidden = true;
  notice('');
  const problem = await ask();
  if (problem) { notice(problem); b.disabled = false; return; }
  countdown(config.resendSeconds);
});

$('#phone-change').addEventListener('click', () => {
  clearInterval(timer);
  sent = null;
  notice('');
  $('.wrong-code').hidden = true;
  $('#phone-check').hidden = true;
  $('#phone-ask').hidden = false;
  field.focus();
});

$('#phone-check').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const wrong = $('.wrong-code');
  const confirm = $('#phone-confirm');
  wrong.hidden = true;
  const code = $('#phone-code').value.replace(/\\D/g, '');
  if (!/^[0-9]{6}$/.test(code)) { wrong.textContent = t.wrong_code; wrong.hidden = false; return; }
  confirm.disabled = true;
  let token;
  try {
    const credential = await sent.confirm(code);
    token = await credential.user.getIdToken();
    await auth.signOut(firebase);
  } catch (e) {
    const c = (e && e.code) || '';
    wrong.textContent = c === 'auth/code-expired' ? t.expired : c === 'auth/too-many-requests' ? t.too_many : t.wrong_code;
    wrong.hidden = false;
    confirm.disabled = false;
    return;
  }
  try {
    const res = await fetch(location.pathname.replace(/\\/auth$/, '/approve'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: config.id, token }) });
    const out = await res.json();
    if (res.ok && out.to) { location.replace(out.to); return; }
    notice(out.error === 'region' ? t.region : t.down);
  } catch {
    notice(t.down);
  }
  confirm.disabled = false;
});

try {
  await start();
} catch (e) {
  // The SDK did not load (a network that blocks gstatic, an outage): said in words, the way back kept.
  console.warn('phone: Firebase did not start: ' + (e && e.message));
  notice(t.down);
  $('#phone-ask').hidden = true;
}
`;
