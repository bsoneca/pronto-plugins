// The phone's one-time codes when the broker issues and checks them itself (PHONE_OTP=broker),
// and the sender that texts them. The code is six digits from the platform's random source, kept
// only as a keyed hash bound to the visit and the number, alive five minutes, dead after five wrong
// tries, and a number is texted again no sooner than the resend wait. In memory: the broker runs
// as one replica, and a code it forgets on restart is one the reader asks for again.
//
// Neither the number nor the code is ever logged here.
import { base64url } from "../oidc.ts";

const enc = new TextEncoder();

export const CODE_TTL_MS = 300_000;
export const MAX_TRIES = 5;

/** How an SMS leaves: one small function per provider, chosen by PHONE_SMS. */
export interface SmsSender {
  send(e164: string, text: string): Promise<void>;
}

/** The stand-in for a local broker: sends nothing, keeps the last code texted to each number. */
export class Standin implements SmsSender {
  #last = new Map<string, string>();
  send(e164: string, text: string): Promise<void> {
    const code = /\b[0-9]{6}\b/.exec(text)?.[0];
    if (code) this.#last.set(e164, code);
    return Promise.resolve();
  }
  last(e164: string): string | undefined {
    return this.#last.get(e164);
  }
}

/**
 * The real senders, by PHONE_SMS name. Adding one is one entry: a function that reads its key from
 * the environment (a missing key throws, so the broker refuses to start) and returns a sender.
 * None is registered yet: the operator has not chosen a provider.
 *
 *   zenvia: (env) => { const key = need(env, "ZENVIA_TOKEN"); return { send: async (to, text) => { ... } }; },
 */
export const SMS_PROVIDERS: Record<string, (env: (k: string) => string | undefined) => SmsSender> = {};

/** The sender PHONE_SMS names for a broker at `issuer`, or why not. */
export function smsSender(name: string, env: (k: string) => string | undefined, issuer: string): SmsSender {
  if (name === "standin") {
    if (new URL(issuer).hostname !== "localhost") throw new Error(`PHONE_SMS=standin is for a localhost broker, not ${issuer}`);
    return new Standin();
  }
  const make = Object.hasOwn(SMS_PROVIDERS, name) ? SMS_PROVIDERS[name] : undefined;
  if (!make) throw new Error(`PHONE_SMS=${name} is not a sender this broker has (${["standin", ...Object.keys(SMS_PROVIDERS)].join(", ")})`);
  return make(env);
}

/** A six-digit code with no modulo bias: bytes at or above the largest multiple of 10 are redrawn. */
export function randomCode(): string {
  let out = "";
  const buf = new Uint8Array(16);
  while (out.length < 6) {
    crypto.getRandomValues(buf);
    for (const b of buf) if (b < 250 && out.length < 6) out += b % 10;
  }
  return out;
}

function same(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

export type Checked = "ok" | "wrong" | "expired" | "dead";

export class Otp {
  #key = crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  #codes = new Map<string, { phone: string; salt: Uint8Array; hash: Uint8Array; expires: number; tries: number }>();
  #next = new Map<string, number>();
  constructor(readonly resendSeconds: number, readonly now: () => number = Date.now) {}

  async #hash(salt: Uint8Array, id: string, phone: string, code: string): Promise<Uint8Array> {
    const data = enc.encode(`${base64url(salt)}\u0000${id}\u0000${phone}\u0000${code}`);
    return new Uint8Array(await crypto.subtle.sign("HMAC", await this.#key, data));
  }

  #sweep() {
    const t = this.now();
    for (const [k, v] of this.#codes) if (v.expires <= t) this.#codes.delete(k);
    for (const [k, v] of this.#next) if (v <= t) this.#next.delete(k);
  }

  /** Seconds before `phone` may be texted again, 0 for now. */
  wait(phone: string): number {
    this.#sweep();
    return Math.max(0, Math.ceil(((this.#next.get(phone) ?? 0) - this.now()) / 1000));
  }

  /** A new code for this visit and number (replacing any earlier one), or the wait left. */
  async issue(id: string, phone: string): Promise<{ code: string } | { wait: number }> {
    const wait = this.wait(phone);
    if (wait > 0) return { wait };
    const code = randomCode();
    const salt = crypto.getRandomValues(new Uint8Array(16));
    this.#codes.set(id, { phone, salt, hash: await this.#hash(salt, id, phone, code), expires: this.now() + CODE_TTL_MS, tries: 0 });
    this.#next.set(phone, this.now() + this.resendSeconds * 1000);
    return { code };
  }

  /** A code that was never sent: forget it and the wait it started. */
  revoke(id: string) {
    const c = this.#codes.get(id);
    if (!c) return;
    this.#codes.delete(id);
    this.#next.delete(c.phone);
  }

  /** The visit's code checked: spent when right, dead after MAX_TRIES wrong ones. */
  async check(id: string, code: string): Promise<{ result: Checked; phone?: string }> {
    const c = this.#codes.get(id);
    if (!c) return { result: "expired" };
    if (c.expires <= this.now()) {
      this.#codes.delete(id);
      return { result: "expired" };
    }
    const ok = same(await this.#hash(c.salt, id, c.phone, code), c.hash);
    if (this.#codes.get(id) !== c) return { result: "expired" };
    if (ok) {
      this.#codes.delete(id);
      return { result: "ok", phone: c.phone };
    }
    c.tries++;
    if (c.tries >= MAX_TRIES) {
      this.#codes.delete(id);
      return { result: "dead" };
    }
    return { result: "wrong" };
  }
}

/** The subject of a phone number under the broker's secret: stable across restarts, one per number. */
export async function phoneSubject(secret: string, e164: string): Promise<string> {
  const root = await crypto.subtle.importKey("raw", enc.encode(secret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info: enc.encode("pronto-identity phone subject v1") }, root, 256);
  const key = await crypto.subtle.importKey("raw", bits, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(e164))));
}
