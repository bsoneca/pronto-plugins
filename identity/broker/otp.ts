// The phone's one-time codes when the broker issues and checks them itself (PHONE_OTP=broker),
// and the sender that texts them. The code is six digits from the platform's random source, kept
// only as a keyed hash bound to the visit and the number, alive five minutes, dead after five wrong
// tries, and a number is texted again no sooner than the resend wait. All of it is in the store
// (store.ts), so the replica that sent a code need not be the one that checks it, and the counts and
// the wait hold across replicas.
//
// Neither the number nor the code is ever logged here, and the number is never kept as it is: the rows hold keyed hashes of it.
import { base64url, fromBase64url } from "../oidc.ts";
import { MemoryStore, sharedSecret, type Store } from "./store.ts";
import spec from "./phone_spec.json" with { type: "json" };

const enc = new TextEncoder();

/** The phone sign-in's numbers, written once in identity/phone.cue and exported to phone_spec.json (PRONTO-607). */
export const PHONE_SPEC = spec as {
  ttl_s: number; tries: number; resend_s: number; channels: Channel[]; countries: string[];
  caps: { per_phone_hour: number; per_ip_hour: number; global_day: number; budget_cents: number }; dial: Record<string, string>;
};
export const CODE_TTL_MS = PHONE_SPEC.ttl_s * 1000;
export const MAX_TRIES = PHONE_SPEC.tries;

/** How a code leaves. */
export type Channel = "whatsapp" | "sms";
/** What a sender is given to say: the code, the page's language and the broker's host. */
export type Message = { code: string; lang: string; host: string };
/** A way a code leaves, per channel: `send` delivers it to the number (a message in the sender's own words). */
export interface OtpSender {
  channel: Channel;
  send(e164: string, m: Message): Promise<void>;
}

/** How an SMS leaves, for the providers registered by name (SMS_PROVIDERS): one small function per provider, chosen by PHONE_SMS. */
export interface SmsSender {
  send(e164: string, text: string): Promise<void>;
}

/** The stand-in for a local broker: sends nothing, keeps the last code and the channel it went by for each number, for either channel. */
export class Standin {
  #last = new Map<string, { code: string; channel: Channel }>();
  /** The sender of one channel, over this stand-in's record. */
  as(channel: Channel): OtpSender {
    return { channel, send: (e164, m) => { this.#last.set(e164, { code: m.code, channel }); return Promise.resolve(); } };
  }
  last(e164: string): { code: string; channel: Channel } | undefined {
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

/**
 * The senders PHONE_SMS names for a broker at `issuer`, or why not: the stand-in serves every channel; a registered SMS provider serves
 * SMS (its text is `text`, the page's words for a message), and WhatsApp has none until a provider for it is registered.
 */
export function otpSenders(name: string, env: (k: string) => string | undefined, issuer: string, text: (m: Message) => string):
  { senders: Partial<Record<Channel, OtpSender>>; standin: Standin | null } {
  if (name === "standin") {
    if (new URL(issuer).hostname !== "localhost") throw new Error(`PHONE_SMS=standin is for a localhost broker, not ${issuer}`);
    const standin = new Standin();
    return { senders: { whatsapp: standin.as("whatsapp"), sms: standin.as("sms") }, standin };
  }
  const make = Object.hasOwn(SMS_PROVIDERS, name) ? SMS_PROVIDERS[name] : undefined;
  if (!make) throw new Error(`PHONE_SMS=${name} is not a sender this broker has (${["standin", ...Object.keys(SMS_PROVIDERS)].join(", ")})`);
  const sms = make(env);
  return { senders: { sms: { channel: "sms", send: (to, m) => sms.send(to, text(m)) } }, standin: null };
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
  #key: Promise<CryptoKey>;
  constructor(readonly resendSeconds: number, readonly store: Store = new MemoryStore()) {
    // The hash's key is the store's, so a code one replica made is checked by another.
    this.#key = sharedSecret(store, "otp-hmac", 32).then((k) => crypto.subtle.importKey("raw", fromBase64url(k), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]));
  }

  async #hash(salt: Uint8Array, id: string, phone: string, code: string): Promise<Uint8Array> {
    const data = enc.encode(`${base64url(salt)}\u0000${id}\u0000${phone}\u0000${code}`);
    return new Uint8Array(await crypto.subtle.sign("HMAC", await this.#key, data));
  }

  /** The number as the store keeps it: a keyed hash, so no row holds the number itself (the same number, the same key, on every replica). */
  async #who(phone: string): Promise<string> {
    return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", await this.#key, enc.encode(`phone\u0000${phone}`))));
  }

  /** Seconds before `phone` may be texted again, 0 for now. */
  async wait(phone: string): Promise<number> {
    return Math.ceil(await this.store.left("otp-next", await this.#who(phone)) / 1000);
  }

  /** A new code for this visit and number (replacing any earlier one), or the wait left. */
  async issue(id: string, phone: string): Promise<{ code: string } | { wait: number }> {
    // Claimed in one step: of two replicas asked at once for one number, one texts and the other waits.
    const who = await this.#who(phone);
    if (!await this.store.claim("otp-next", who, this.resendSeconds * 1000)) return { wait: Math.max(1, await this.wait(phone)) };
    const code = randomCode();
    const salt = crypto.getRandomValues(new Uint8Array(16));
    // The row holds the number's keyed hash and the code's, bound to the visit and the number: never the number.
    await this.store.put("otp", id, { who, salt: base64url(salt), hash: base64url(await this.#hash(salt, id, phone, code)) }, CODE_TTL_MS);
    return { code };
  }

  /** A code that was never sent: forget it and the wait it started. */
  async revoke(id: string, phone: string) {
    const c = await this.store.take<Held>("otp", id);
    if (c) await this.store.del("otp-next", c.who);
    else await this.store.del("otp-next", await this.#who(phone));
  }

  /**
   * The visit's code checked against the number it was sent to (the caller says which: the row keeps only a hash of it): spent when right,
   * dead after MAX_TRIES wrong ones. A number other than the one the code was made for is a wrong code, as any other wrong guess.
   */
  async check(id: string, phone: string, code: string): Promise<{ result: Checked }> {
    const c = await this.store.get<Held>("otp", id);
    if (!c) return { result: "expired" };
    const ok = same(await this.#hash(fromBase64url(c.salt), id, phone, code), fromBase64url(c.hash));
    if (ok) {
      // Taken, not deleted: of two replicas checking the right code at once, one is told ok.
      return await this.store.take("otp", id) ? { result: "ok" } : { result: "expired" };
    }
    const tries = await this.store.bump("otp", id);
    if (tries === undefined) return { result: "expired" };
    if (tries >= MAX_TRIES) {
      await this.store.del("otp", id);
      return { result: "dead" };
    }
    return { result: "wrong" };
  }
}

type Held = { who: string; salt: string; hash: string };

/** The subject of a phone number under the broker's secret: stable across restarts, one per number. */
export async function phoneSubject(secret: string, e164: string): Promise<string> {
  const root = await crypto.subtle.importKey("raw", enc.encode(secret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info: enc.encode("pronto-identity phone subject v1") }, root, 256);
  const key = await crypto.subtle.importKey("raw", bits, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(e164))));
}
