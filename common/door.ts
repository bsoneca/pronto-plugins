// A call through mecha's airlock door (PRONTO-135, PRONTO-268), shared by the billing broker's Stripe
// client and the identity broker's Google token exchange. The airlock holds the credential and adds
// it, records every call in its ledger under its key, and answers the sink's status and body
// (mecha's services/airlock/README.md, "A door"). It imports nothing, so each broker runs it from
// its own directory (broker/door.ts, a link to this file).

/** What a caller POSTs to `/door/<name>`: the path as the sink takes it, a body in JSON or, under
 * another `contentType`, a string sent as it is, and only the headers the door declares. */
export interface DoorRequest {
  key: string;
  /** The key the sink gets as its own Idempotency-Key, when the caller also sends it another way. */
  sinkKey?: string;
  method: string;
  path: string;
  body?: unknown;
  contentType?: string;
  headers?: Record<string, string>;
}

/** The door could not answer: its own refusal (4xx), or no outcome after every try (502). */
export class DoorError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** How often a call the door could not answer (502: the sink answered 5xx, or nothing) is made again,
 * with the same key, which the door's ledger and the sink's idempotency make safe. */
const DOOR_TRIES = 3;

const enc = new TextEncoder();
export const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

/** A key the door takes (A-Z a-z 0-9 . _ : -, at most 200) for `of`: its SHA-256, so the same text
 * is the same call and two texts stay two. */
export async function doorKey(prefix: string, of: string): Promise<string> {
  return `${prefix}-${hex(await crypto.subtle.digest("SHA-256", enc.encode(of)))}`;
}

/** One call through `door` (its URL, `http://airlock:9998/door/stripe`), made again while the door
 * answers 502. Returns the sink's `{status, body}`; a door that answers anything but 200 throws. */
export async function throughDoor(door: string, request: DoorRequest, fetcher: typeof fetch = fetch): Promise<{ status: number; body: unknown; replayed?: boolean }> {
  for (let i = 1;; i++) {
    const res = await fetcher(door, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(request) });
    const answer = await res.json();
    if (res.status === 502 && i < DOOR_TRIES) {
      await new Promise((r) => setTimeout(r, 250 * 2 ** i));
      continue;
    }
    if (res.status !== 200) throw new DoorError(res.status, `airlock door: ${res.status} ${answer?.error ?? ""}`.trim());
    return answer;
  }
}
