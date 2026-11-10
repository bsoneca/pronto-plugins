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
// PHONE_OTP=broker moves the codes off Google: the broker issues and checks them itself (otp.ts) and
// sends the SMS through the sender PHONE_SMS names, after the gate PHONE_SMS_GATE admits (the broker
// signs a JWT with the key it mints at start, published at /phone/jwks). The page then loads no
// Firebase SDK, no gstatic and no reCAPTCHA. The default, firebase, is the way described above.
//
// Locally (PHONE_EMULATOR, a localhost broker only) the page signs in against the Firebase Auth
// emulator, which sends no SMS and whose tokens are unsigned.
import { base64url, fromBase64url, jwksSource, type KeySource, randomToken, Refused, verifyIdToken } from "../oidc.ts";
import { esc, json } from "./core.ts";
import type { Provider } from "./main.ts";
import { Otp, phoneSubject, type SmsSender, smsSender, Standin } from "./otp.ts";

const enc = new TextEncoder();

/** Firebase's signing keys for its ID tokens, and the issuer prefix a project's tokens carry. */
export const FIREBASE_JWKS = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
export const FIREBASE_ISSUER = "https://securetoken.google.com/";
/** The Firebase JS SDK the page imports from gstatic, as the operator's phone page pins it. */
export const SDK = "13.1.0";
/** A Brazilian mobile, in E.164: +55, a two-digit area code, a 9 and eight digits. */
export const BRAZIL_MOBILE = "^\\+55[1-9][1-9]9[0-9]{8}$";

export interface PhoneConfig {
  /** Who issues and checks the codes: Firebase (the default) or the broker itself. */
  otp: "firebase" | "broker";
  /** Broker mode: the sender's name (PHONE_SMS), the sender, and the gate asked before each SMS. */
  sms: string | null;
  sender: SmsSender | null;
  smsGate: string | null;
  /** The Firebase project whose Identity Platform sends the codes (the emulator's demo- project locally). */
  project: string;
  apiKey: string;
  authDomain: string;
  appId: string;
  sdk: string;
  /** The tenants that may offer the phone: origins, a `*` standing for a port. */
  tenants: string[];
  /** Broker mode: the tenants that may learn a proven number (the prove step); none, the capability is off. */
  proveTenants: string[];
  /** Where the page asks for a code before Firebase sends one: the beforeSendSms gate's owner. */
  admit: string;
  /** The Firebase Auth emulator's host:port, on a localhost broker only. */
  emulator: string | null;
  resendSeconds: number;
  /** The numbers the page accepts (E.164), Brazil's mobiles unless said otherwise. */
  pattern: string;
}

/** The settings only Firebase mode takes: a broker mode that names one is a mixed-up deployment. */
const FIREBASE_ONLY = ["PHONE_PROJECT", "PHONE_API_KEY", "PHONE_APP_ID", "PHONE_AUTH_DOMAIN", "PHONE_SDK", "PHONE_EMULATOR"];

/** The phone's settings from the broker's environment, or null when neither PHONE_PROJECT nor PHONE_OTP is set. */
export function phoneConfig(env: (k: string) => string | undefined, issuer: string): PhoneConfig | null {
  const otp = env("PHONE_OTP") || "firebase";
  if (otp !== "firebase" && otp !== "broker") throw new Error("PHONE_OTP is firebase or broker");
  const project = env("PHONE_PROJECT");
  if (otp === "firebase" && !project) return null;
  const need = (k: string) => {
    const v = env(k);
    if (!v) throw new Error(`${k} is required with ${otp === "broker" ? "PHONE_OTP=broker" : "PHONE_PROJECT"}`);
    return v;
  };
  if (otp === "firebase") {
    for (const k of ["PHONE_SMS", "PHONE_SMS_GATE", "PHONE_PROVE_TENANTS"]) if (env(k)) throw new Error(`${k} is for PHONE_OTP=broker`);
  } else {
    for (const k of FIREBASE_ONLY) if (env(k)) throw new Error(`${k} is for PHONE_OTP=firebase, not broker`);
  }
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
  let sms: string | null = null, sender: SmsSender | null = null, smsGate: string | null = null;
  if (otp === "broker") {
    sms = need("PHONE_SMS");
    smsGate = need("PHONE_SMS_GATE");
    if (!/^https?:\/\//.test(smsGate)) throw new Error("PHONE_SMS_GATE is an http(s) URL");
    sender = smsSender(sms, env, issuer);
  }
  return {
    otp,
    sms,
    sender,
    smsGate,
    project: project ?? "",
    apiKey: otp === "broker" ? "" : emulator ? env("PHONE_API_KEY") || "emulator" : need("PHONE_API_KEY"),
    authDomain: otp === "broker" ? "" : env("PHONE_AUTH_DOMAIN") || `${project}.firebaseapp.com`,
    appId: otp === "broker" ? "" : emulator ? env("PHONE_APP_ID") || "emulator" : need("PHONE_APP_ID"),
    sdk: env("PHONE_SDK") || SDK,
    tenants,
    proveTenants: (env("PHONE_PROVE_TENANTS") ?? "").split(",").map((t) => t.trim()).filter((t) => t !== ""),
    admit,
    emulator,
    resendSeconds,
    pattern: env("PHONE_PATTERN") || BRAZIL_MOBILE,
  };
}

/** Whether a tenant is one the operator lets offer the phone: exact, or with `*` for a port. */
export function tenantAdmitted(tenants: readonly string[], tenant: string): boolean {
  return tenants.some((t) => new RegExp(tenantPattern(t)).test(tenant));
}

/** The regular expression a tenant entry stands for. */
const tenantPattern = (t: string) => "^" + t.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[0-9]+") + "$";

/** The page's words, by language: Portuguese for a reader whose browser asks for it first, else English. */
export const STRINGS = {
  en: {
    title: "Sign in with your phone",
    intro: "Type your mobile number. We'll text you a 6-digit code to sign in to",
    number: "Mobile number with area code",
    send: "Text me a code",
    sms_said: "We'll send a 6-digit code by SMS to this number. The SMS costs you nothing.",
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
    prove_refused: "This app can't ask to confirm a number here. Go back and start again.",
    prove_title: "Confirm your phone",
    prove_intro: "We'll text a 6-digit code to confirm this number to",
    sms: "{host}: your sign-in code is {code}",
  },
  "pt-BR": {
    title: "Entrar com celular",
    intro: "Digite seu celular. Vamos enviar um código de 6 dígitos por SMS para você entrar em",
    number: "Celular com DDD",
    send: "Enviar código por SMS",
    sms_said: "Vamos enviar um código de 6 dígitos por SMS para este número. Receber o SMS não tem custo para você.",
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
    prove_refused: "Este app não pode pedir a confirmação de um número aqui. Volte e comece de novo.",
    prove_title: "Confirmar seu celular",
    prove_intro: "Vamos enviar um código de 6 dígitos por SMS para confirmar este número para",
    sms: "{host}: seu código para entrar é {code}",
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
  // Broker mode loads nothing of Google's: the page and the broker, and the admit gate.
  if (cfg.otp === "broker") {
    return [
      "default-src 'none'", "script-src 'self'", `connect-src 'self' ${admit}`, "style-src 'unsafe-inline'",
      "form-action 'none'", "frame-ancestors 'none'", "base-uri 'none'",
    ].join("; ");
  }
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

// The page's referrer is its origin alone, never its address (which holds no secret, but the visit's
// id): Firebase's API key admits the broker's origin as a referrer, and a request with none is refused.
const html = (body: string, csp: string, status = 200) =>
  new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": csp, "cache-control": "no-store", "referrer-policy": "strict-origin" } });

/** What a gate answers makes of a send: the status, as the page's words. */
export const gateVerdict = (status: number): "go" | "too_many" | "down" => status >= 200 && status < 300 ? "go" : status === 403 || status === 429 ? "too_many" : "down";

// `secret` (BROKER_SECRET) derives the broker mode's subjects; `fetcher` is the gate's transport.
export async function phoneUpstream(issuer: string, cfg: PhoneConfig, opts: { keys?: KeySource; now?: () => number; secret?: string; fetcher?: typeof fetch } = {}): Promise<{
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
  const asked = new Map<string, { nonce: string; state: string; since: number; expires: number; lang: Lang }>();
  const brokerMode = cfg.otp === "broker";
  if (brokerMode && (opts.secret ?? "").length < 32) throw new Error("PHONE_OTP=broker needs BROKER_SECRET to derive subjects");
  const otp = new Otp(cfg.resendSeconds, now);
  const proving = new Map<string, { origin: string; expires: number }>();
  const proveCsp = "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'";
  const fetcher = opts.fetcher ?? fetch;
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
    const lang = langOf(req.headers.get("accept-language"));
    asked.set(id, { nonce: q.get("nonce")!, state: q.get("state")!, since: Math.floor(now() / 1000), expires: now() + 900_000, lang });
    const s = STRINGS[lang];
    const cancel = `${callback}?${new URLSearchParams({ error: "access_denied", state: q.get("state")! })}`;
    const config = brokerMode
      ? { id, mode: "broker", admit: cfg.admit, resendSeconds: cfg.resendSeconds, pattern: cfg.pattern, strings: s }
      : {
        id, admit: cfg.admit, project: cfg.project, apiKey: cfg.apiKey, authDomain: cfg.authDomain, appId: cfg.appId, sdk: cfg.sdk,
        emulator: cfg.emulator ? `http://${cfg.emulator}` : null, resendSeconds: cfg.resendSeconds, pattern: cfg.pattern, strings: s,
      };
    // The config rides in a data block the CSP does not run; </ is escaped so it cannot end it.
    const data = JSON.stringify(config).replace(/</g, "\\u003c");
    return html(`<!doctype html>
<html lang="${lang}">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="strict-origin">
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
${brokerMode ? "" : `<div id="recaptcha"></div>\n`}<p><a class="back" id="phone-back" href="${esc(cancel)}">${esc(s.back)}</a></p>
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

  /** The page's JSON body, or the answer that refuses it. */
  async function jsonBody(req: Request): Promise<Record<string, unknown> | Response> {
    if ((req.headers.get("content-type") ?? "").split(";")[0] !== "application/json") return json(415, { error: "json" });
    const text = await req.text();
    if (text.length > 8192) return json(413, { error: "too large" });
    try {
      const body = JSON.parse(text);
      return body && typeof body === "object" && !Array.isArray(body) ? body : json(400, { error: "body" });
    } catch {
      return json(400, { error: "body" });
    }
  }

  // Broker mode: a code for `visit` and `phone`. The wait is checked first (a refused number costs the
  // gate nothing), then the gate admits the SMS, then the code is made and sent.
  async function deliver(visit: string, phone: string, lang: Lang): Promise<Response> {
    if (otp.wait(phone) > 0) return json(429, { error: "cooldown" });
    const verdict = await gate(phone);
    if (verdict !== "go") return json(verdict === "too_many" ? 429 : 503, { error: verdict });
    const made = await otp.issue(visit, phone);
    if ("wait" in made) return json(429, { error: "cooldown" });
    try {
      await cfg.sender!.send(phone, STRINGS[lang].sms.replace("{host}", new URL(issuer).host).replace("{code}", made.code));
    } catch (e) {
      otp.revoke(visit);
      // The sender's failure, never the number or the code.
      console.error(`broker: phone SMS not sent: ${e instanceof Error ? e.name : "error"}`);
      return json(503, { error: "down" });
    }
    return json(200, {});
  }

  async function send(req: Request): Promise<Response> {
    const body = await jsonBody(req);
    if (body instanceof Response) return body;
    const a = live(asked, typeof body.id === "string" ? body.id : null, false);
    if (!a) return json(400, { error: "expired" });
    const phone = body.phone;
    if (typeof phone !== "string" || !new RegExp(cfg.pattern).test(phone)) return json(400, { error: "region" });
    return deliver(body.id as string, phone, a.lang);
  }

  const codeError = (result: string) => json(400, { error: result === "dead" ? "too_many" : result === "wrong" ? "wrong_code" : "expired" });

  // The prove step: a tenant the operator listed (PHONE_PROVE_TENANTS) learns the number, which the
  // reader confirms with a code. Each ask is a visit of its own, kept ten minutes.
  async function proveSend(req: Request): Promise<Response> {
    const body = await jsonBody(req);
    if (body instanceof Response) return body;
    const origin = body.return_origin;
    if (typeof origin !== "string" || !tenantAdmitted(cfg.proveTenants, origin)) return json(403, { error: "tenant" });
    const phone = body.phone;
    if (typeof phone !== "string" || !new RegExp(cfg.pattern).test(phone)) return json(400, { error: "region" });
    for (const [k, v] of proving) if (v.expires <= now()) proving.delete(k);
    const visit = randomToken(16);
    const res = await deliver(visit, phone, langOf(req.headers.get("accept-language")));
    if (!res.ok) return res;
    proving.set(visit, { origin, expires: now() + 600_000 });
    return json(200, { visit });
  }

  async function proveCheck(req: Request): Promise<Response> {
    const body = await jsonBody(req);
    if (body instanceof Response) return body;
    const v = live(proving, typeof body.visit === "string" ? body.visit : null, false);
    if (!v || typeof body.code !== "string") return json(400, { error: "expired" });
    const checked = await otp.check(body.visit as string, body.code);
    if (checked.result === "dead" || checked.result === "ok") proving.delete(body.visit as string);
    if (checked.result !== "ok") return codeError(checked.result);
    const t = Math.floor(now() / 1000);
    const id_token = await signJwt({
      iss: root, aud: v.origin, sub: await phoneSubject(opts.secret!, checked.phone!), phone_number: checked.phone, auth_time: t, iat: t, exp: t + 300, amr: ["sms"], event: "phone_proof",
    });
    return json(200, { id_token });
  }

  async function signJwt(claims: Record<string, unknown>): Promise<string> {
    const head = base64url(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT", kid: jwk.kid })));
    const body = base64url(enc.encode(JSON.stringify(claims)));
    const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${head}.${body}`)));
    return `${head}.${body}.${base64url(sig)}`;
  }

  function provePage(req: Request): Response {
    const lang = langOf(req.headers.get("accept-language"));
    const s = STRINGS[lang];
    const config = { resendSeconds: cfg.resendSeconds, pattern: cfg.pattern, tenants: cfg.proveTenants.map(tenantPattern), strings: s };
    const data = JSON.stringify(config).replace(/</g, "\\u003c");
    return html(`<!doctype html>
<html lang="${lang}">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">
<title>${esc(s.prove_title)}</title>
<style>${STYLE}</style></head>
<body><main>
<h1>${esc(s.prove_title)}</h1>
<p class="notice" id="phone-notice" role="alert" hidden></p>
<form id="phone-ask" novalidate>
  <p>${esc(s.prove_intro)} <strong class="e164" data-e164></strong></p>
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
</form>
<p><button type="button" class="link" id="phone-back">${esc(s.back)}</button></p>
</main>
<script type="application/json" id="phone-config">${data}</script>
<script type="module" src="${esc(`${base}/prove.js`)}"></script>
</body></html>
`, proveCsp);
  }

  // The gate (PHONE_SMS_GATE) is asked before each SMS with a JWT signed by the phone key (/phone/jwks):
  // no answer in time, or any but a 2xx, is no SMS.
  async function gate(phone: string): Promise<"go" | "too_many" | "down"> {
    const t = Math.floor(now() / 1000);
    const jwt = await signJwt({ iss: root, aud: cfg.smsGate, event: "sms", phone_number: phone, iat: t, exp: t + 60, jti: randomToken(16) });
    try {
      const res = await fetcher(cfg.smsGate!, {
        method: "POST", headers: { "content-type": "application/jwt" }, body: jwt, signal: AbortSignal.timeout(8000),
      });
      await res.body?.cancel();
      const verdict = gateVerdict(res.status);
      if (verdict !== "go") console.error(`broker: phone SMS gate answered ${res.status}`);
      return verdict;
    } catch {
      console.error("broker: phone SMS gate did not answer");
      return "down";
    }
  }

  // The page's word: the visit it is, and the ID token Firebase gave it (broker mode: the code the
  // reader typed). It answers where to go: the broker's callback with a code, or a refusal the page shows.
  async function approve(req: Request): Promise<Response> {
    const body = await jsonBody(req);
    if (body instanceof Response) return body;
    const a = live(asked, typeof body.id === "string" ? body.id : null, false);
    let sub: string;
    if (brokerMode) {
      if (!a || typeof body.code !== "string") return json(400, { error: "expired" });
      const checked = await otp.check(body.id as string, body.code);
      if (checked.result !== "ok") return codeError(checked.result);
      // Firebase-mode users had Firebase's uid as their subject: they get different ones here (a migration, not solved here).
      sub = await phoneSubject(opts.secret!, checked.phone!);
    } else {
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
      sub = claims.sub;
    }
    asked.delete(body.id as string);
    const code = randomToken(16);
    codes.set(code, { nonce: a.nonce, sub, expires: now() + 60_000 });
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
        return Promise.resolve(new Response(brokerMode ? BROKER_SCRIPT : SCRIPT, { headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-cache" } }));
      }
      if (req.method === "POST" && url.pathname === "/phone/approve") return approve(req);
      if (brokerMode && req.method === "POST" && url.pathname === "/phone/send") return send(req);
      if (brokerMode && cfg.proveTenants.length > 0) {
        if (req.method === "GET" && url.pathname === "/phone/prove") return Promise.resolve(provePage(req));
        if (req.method === "GET" && url.pathname === "/phone/prove.js") return Promise.resolve(new Response(PROVE_SCRIPT, { headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-cache" } }));
        if (req.method === "POST" && url.pathname === "/phone/prove/send") return proveSend(req);
        if (req.method === "POST" && url.pathname === "/phone/prove/check") return proveCheck(req);
      }
      if (brokerMode && req.method === "GET" && url.pathname === "/phone/jwks") return Promise.resolve(json(200, { keys: [{ ...jwk, alg: "RS256", use: "sig" }] }));
      // A local scenario reads the code the stand-in "sent", as it reads the Firebase emulator's.
      if (cfg.sender instanceof Standin && req.method === "GET" && url.pathname === "/phone/fake/codes") {
        const phone = (url.searchParams.get("phone") ?? "").replace(/^ /, "+");
        const code = cfg.sender.last(phone);
        return Promise.resolve(code ? json(200, { code }) : json(404, { error: "no code" }));
      }
      if (req.method === "POST" && url.pathname === "/phone/token") return req.text().then((t) => token(new URLSearchParams(t)));
      return null;
    },
  };
}

// One send of the code, by `send` (Firebase's signInWithPhoneNumber on a fresh verifier), as the page
// runs it (SCRIPT embeds this function's source). A failure is logged with Firebase's code and its
// message, which a code-less error (a dropped request) carries alone. Against the emulator only, a
// failed send is tried once more: a loaded developer's machine drops one now and then (bsoneca/ume's
// gates, 2026-11-02). Against Firebase itself a tap sends one SMS at most, so the SMS limits stay
// the operator's.
export async function sendCode<T>(send: () => Promise<T>, emulator: boolean, warn: (line: string) => void): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await send();
    } catch (e) {
      const err = (e ?? {}) as { code?: string; message?: string };
      warn("phone: no code sent (try " + attempt + "): " + [err.code, err.message].filter(Boolean).join(" "));
      if (!emulator || attempt >= 2) throw e;
    }
  }
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

// The parts of the page's script both modes share: the number field, and the resend countdown.
const COMMON_TOP = `const $ = (s) => document.querySelector(s);
const config = JSON.parse($('#phone-config').textContent);
const t = config.strings;
const pattern = new RegExp(config.pattern);
const notice = (text) => { const el = $('#phone-notice'); el.textContent = text; el.hidden = !text; };

// The national number as typed, kept to its digits and drawn as (11) 91234-5678.
const digitsOf = (v) => v.replace(/\\D/g, '').replace(/^55(?=\\d{11})/, '').slice(0, 11);
const masked = (d) => d.length <= 2 ? (d ? '(' + d : '') : d.length <= 7 ? '(' + d.slice(0, 2) + ') ' + d.slice(2) : '(' + d.slice(0, 2) + ') ' + d.slice(2, 7) + '-' + d.slice(7);
const field = $('#phone-number');
field.addEventListener('input', () => { field.value = masked(digitsOf(field.value)); });

`;
const COMMON_COUNTDOWN = `// The resend button counts down the gate's wait, then offers a new code.
function countdown(seconds) {
  clearInterval(timer);
  const b = $('#phone-resend');
  let left = seconds;
  const draw = () => { b.disabled = left > 0; b.textContent = left > 0 ? t.resend_in.replace('{s}', left) : t.resend; };
  draw();
  timer = setInterval(() => { left -= 1; draw(); if (left <= 0) clearInterval(timer); }, 1000);
}

`;

// The page's script: plain ES modules from gstatic, no framework. It reads its config from the data
// block, asks the gate for a code, has Firebase send it, and hands the broker the ID token Firebase
// gives back. Nothing is kept: Firebase's persistence is in memory, and it signs out once it has the
// token.
const SCRIPT = `${sendCode.toString()}
${COMMON_TOP}let firebase, auth, verifier, sent = null, e164 = '', timer = 0;
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

${COMMON_COUNTDOWN}// The gate's word on a code for this number ('' to go), then Firebase sends it.
async function ask() {
  // The SDK is loaded once the page starts; a tap before it has waits for it rather than failing on
  // an SDK not there yet (bsoneca/ume's phone-signin under load: "reading 'RecaptchaVerifier'" of undefined).
  try { await started; } catch { return t.down; }
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
    sent = await sendCode(() => { freshVerifier(); return auth.signInWithPhoneNumber(firebase, e164, verifier); }, !!config.emulator, (line) => console.warn(line));
  } catch (e) {
    const code = (e && e.code) || '';
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

const started = start();
try {
  await started;
} catch (e) {
  // The SDK did not load (a network that blocks gstatic, an outage): said in words, the way back kept.
  console.warn('phone: Firebase did not start: ' + (e && e.message));
  notice(t.down);
  $('#phone-ask').hidden = true;
}
`;

// The page's script in broker mode: no SDK, no reCAPTCHA. The gate's owner is asked for a code first
// (unchanged), then the broker is asked to send it, and the code typed is the broker's to check.
const BROKER_SCRIPT = `${COMMON_TOP}let e164 = '', timer = 0;
${COMMON_COUNTDOWN}
// The gate's word on a code for this number ('' to go), then the broker sends it.
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
    const res = await fetch(location.pathname.replace(/\\/auth$/, '/send'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: config.id, phone: e164 }) });
    if (res.ok) return '';
    const error = (await res.json()).error;
    return error === 'cooldown' ? t.cooldown : error === 'too_many' ? t.too_many : error === 'region' ? t.wrong_number : t.down;
  } catch {
    return t.down;
  }
}

$('#phone-ask').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  e164 = '+55' + digitsOf(field.value);
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
  try {
    const res = await fetch(location.pathname.replace(/\\/auth$/, '/approve'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: config.id, code }) });
    const out = await res.json();
    if (res.ok && out.to) { location.replace(out.to); return; }
    wrong.textContent = out.error === 'expired' ? t.expired : out.error === 'too_many' ? t.too_many : t.wrong_code;
    wrong.hidden = false;
  } catch {
    notice(t.down);
  }
  confirm.disabled = false;
});
`;

// The prove page's script: the app's fragment (#phone=<E.164>&state=<s>&return=<url>) is read and
// the address cleaned at once; the page leaves only for a return the operator listed, with
// #id_token=...&state=... or #error=...&state=....
const PROVE_SCRIPT = `const $ = (s) => document.querySelector(s);
const config = JSON.parse($('#phone-config').textContent);
const t = config.strings;
const notice = (text) => { const el = $('#phone-notice'); el.textContent = text; el.hidden = !text; };
let timer = 0;
${COMMON_COUNTDOWN}
// The fragment is the app's word, read once and gone from the address.
const frag = new URLSearchParams(location.hash.slice(1));
history.replaceState(null, '', location.pathname);
const phone = frag.get('phone') || '';
const state = frag.get('state') || '';
let ret = null;
try {
  const u = new URL(frag.get('return') || '');
  if (config.tenants.some((p) => new RegExp(p).test(u.origin))) ret = u;
} catch {}
const leave = (params) => {
  if (!ret) return;
  const u = new URL(ret);
  u.hash = new URLSearchParams({ ...params, state }).toString();
  location.replace(u.toString());
};
let visit = '';
const failure = (error) => error === 'cooldown' ? t.cooldown : error === 'too_many' ? t.too_many : error === 'region' ? t.wrong_number : error === 'tenant' ? t.prove_refused : t.down;

document.querySelectorAll('[data-e164]').forEach((el) => { el.textContent = phone; });
if (!ret || !new RegExp(config.pattern).test(phone)) {
  // Never a redirect to a return that is not listed: the page says so and stays.
  notice(ret ? t.wrong_number : t.prove_refused);
  $('#phone-ask').hidden = true;
  $('#phone-back').hidden = !ret;
}

async function ask() {
  try {
    const res = await fetch(location.pathname + '/send', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ phone, return_origin: ret.origin }) });
    const out = await res.json();
    if (res.ok) { visit = out.visit; return ''; }
    return failure(out.error);
  } catch {
    return t.down;
  }
}

$('#phone-ask').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const send = $('#phone-send');
  send.disabled = true;
  notice('');
  const problem = await ask();
  send.disabled = false;
  if (problem) { notice(problem); return; }
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

$('#phone-check').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const wrong = $('.wrong-code');
  const confirm = $('#phone-confirm');
  wrong.hidden = true;
  const code = $('#phone-code').value.replace(/\\D/g, '');
  if (!/^[0-9]{6}$/.test(code)) { wrong.textContent = t.wrong_code; wrong.hidden = false; return; }
  confirm.disabled = true;
  try {
    const res = await fetch(location.pathname + '/check', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ visit, code }) });
    const out = await res.json();
    if (res.ok && out.id_token) { leave({ id_token: out.id_token }); return; }
    wrong.textContent = out.error === 'expired' ? t.expired : out.error === 'too_many' ? t.too_many : t.wrong_code;
    wrong.hidden = false;
  } catch {
    notice(t.down);
  }
  confirm.disabled = false;
});

$('#phone-back').addEventListener('click', () => leave({ error: 'cancelled' }));
`;
