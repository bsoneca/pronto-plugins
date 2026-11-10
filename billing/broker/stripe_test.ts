// The broker's Stripe client through the airlock's door (PRONTO-135), with the door faked: what it
// sends, that every call carries a key, what a retry keeps, and how Stripe's answers come back.

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { askedDoor, forAccount, STRIPE_V2_VERSION, STRIPE_VERSION, stripe, StripeError, switched, type Stripe } from "./stripe.ts";

type Sent = { url: string; body: Record<string, unknown> };
function door(answers: { status: number; body: unknown }[]): { sent: Sent[]; fetcher: typeof fetch } {
  const sent: Sent[] = [];
  return {
    sent,
    fetcher: (url, init) => {
      sent.push({ url: String(url), body: JSON.parse(String(init!.body)) });
      const a = answers.shift()!;
      return Promise.resolve(Response.json(a.body, { status: a.status }));
    },
  };
}

Deno.test("a /v1 POST goes through the door form-encoded, keyed, with its API version and no Stripe key", async () => {
  const { sent, fetcher } = door([{ status: 200, body: { status: 200, body: { id: "cs_1" }, replayed: false } }]);
  const s = stripe({ door: "http://airlock:9998/door/stripe", fetcher });
  assertEquals(await s("POST", "/v1/checkout/sessions", { mode: "subscription", line_items: [{ price: "p", quantity: 1 }] }, "checkout acct_1"), { id: "cs_1" });
  assertEquals(sent[0].url, "http://airlock:9998/door/stripe");
  const b = sent[0].body;
  assertEquals(b.method, "POST");
  assertEquals(b.path, "/v1/checkout/sessions");
  assertEquals(b.contentType, "application/x-www-form-urlencoded");
  assertEquals(b.body, "mode=subscription&line_items%5B0%5D%5Bprice%5D=p&line_items%5B0%5D%5Bquantity%5D=1");
  assertEquals(b.headers, { "Stripe-Version": STRIPE_VERSION });
  // The broker's own key, hashed into one the door takes: the same key every time.
  assertEquals(/^key-[0-9a-f]{64}$/.test(String(b.key)), true);
  assertEquals(JSON.stringify(b).includes("sk_"), false);
});

Deno.test("a /v2 POST sends JSON, a GET its query in the path, and a call with no key gets one of its own", async () => {
  const ok = { status: 200, body: { status: 200, body: {}, replayed: false } };
  const { sent, fetcher } = door([ok, ok, ok]);
  const s = stripe({ door: "http://airlock:9998/door/stripe", fetcher });
  await s("POST", "/v2/core/accounts", { display_name: "A" });
  await s("GET", "/v1/customers/search", { query: "metadata['a']:'b'" });
  await s("GET", "/v1/account");
  assertEquals([sent[0].body.contentType, sent[0].body.body, sent[0].body.headers], ["application/json", { display_name: "A" }, { "Stripe-Version": STRIPE_V2_VERSION }]);
  assertEquals(sent[1].body.path, "/v1/customers/search?query=metadata%5B%27a%27%5D%3A%27b%27");
  assertEquals(sent[2].body.path, "/v1/account");
  for (const c of sent) assertEquals(/^call-[0-9a-f-]{36}$/.test(String(c.body.key)), true);
  assertEquals(new Set(sent.map((c) => c.body.key)).size, 3);
});

Deno.test("a call the door could not answer is made again with the same key", async () => {
  const { sent, fetcher } = door([
    { status: 502, body: { error: "the sink answered 503" } },
    { status: 200, body: { status: 200, body: { id: "sub_1" }, replayed: false } },
  ]);
  const s = stripe({ door: "http://airlock:9998/door/stripe", fetcher });
  assertEquals(await s("POST", "/v1/subscriptions/sub_1", { metadata: { a: "1" } }), { id: "sub_1" });
  assertEquals(sent.length, 2);
  assertEquals(sent[0].body.key, sent[1].body.key);
});

Deno.test("Stripe's refusal comes back as the StripeError it was, and the door's own as an airlock one", async () => {
  const declined = { status: 200, body: { status: 402, body: { error: { code: "card_declined", message: "declined" } }, replayed: true } };
  const s1 = stripe({ door: "http://airlock:9998/door/stripe", fetcher: door([declined]).fetcher });
  const e = await assertRejects(() => s1("POST", "/v1/charges", {}), StripeError, "declined");
  assertEquals([e.status, e.code], [402, "card_declined"]);
  const s2 = stripe({ door: "http://airlock:9998/door/stripe", fetcher: door([{ status: 400, body: { error: "key already names another request" } }]).fetcher });
  const e2 = await assertRejects(() => s2("POST", "/v1/charges", {}, "k"), StripeError, "another request");
  assertEquals([e2.status, e2.code], [400, "airlock"]);
});

// While it moves (PRONTO-218): the tenant says `door` for its reader (its flag stripe_door, which its
// billing service reads with the reader's own session), and each call goes that way.
const via = (name: string, seen: string[]): Stripe => (method, path) => {
  seen.push(`${name} ${method} ${path}`);
  return Promise.resolve({} as never);
};
const post = (body: string, length = String(body.length)) =>
  new Request("https://b/trial/offer", { method: "POST", headers: { "content-type": "application/json", "content-length": length }, body });

Deno.test("a request that asks for the door sends its calls through it; one that does not, straight to Stripe", async () => {
  const seen: string[] = [];
  const s = switched({ direct: via("direct", seen), door: via("door", seen), on: askedDoor });
  const routes: string[] = [];
  const handler = forAccount(async (req: Request) => {
    await s("GET", `/v1/customers/${(await req.json()).account}`);
    routes.push(await s.route!());
    return new Response("ok");
  });
  await handler(post(JSON.stringify({ account: "tess", door: true })));
  await handler(post(JSON.stringify({ account: "ana", door: false })));
  await handler(post(JSON.stringify({ account: "bo" })));
  await handler(post(JSON.stringify({ account: "cy", door: "yes" })));
  assertEquals(seen, ["door GET /v1/customers/tess", "direct GET /v1/customers/ana", "direct GET /v1/customers/bo", "direct GET /v1/customers/cy"]);
  assertEquals(routes, ["door", "direct", "direct", "direct"]);
  await s("POST", "/v1/webhook_endpoints");
  assertEquals(seen.at(-1), "direct POST /v1/webhook_endpoints", "what no request asks goes straight, as before");
  assertEquals(await stripe({ key: "k" }).route!(), "direct");
  assertEquals(await stripe({ door: "http://d" }).route!(), "door");
});

Deno.test("a body too large or of no declared length asks for nothing", async () => {
  const seen: string[] = [];
  const s = switched({ direct: via("direct", seen), door: via("door", seen), on: askedDoor });
  const handler = forAccount(async () => {
    await s("GET", "/v1/prices");
    return new Response("ok");
  });
  await handler(post(JSON.stringify({ account: "tess", door: true, pad: "x".repeat(5000) })));
  await handler(new Request("https://b/checkout", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ door: true }) }));
  await handler(post(JSON.stringify({ door: true })));
  assertEquals(seen, ["direct GET /v1/prices", "door GET /v1/prices", "door GET /v1/prices"], "an undeclared length is read like a declared one");
});

Deno.test("a large body is never copied, and Stripe's webhook is never read for a caller", async () => {
  const seen: string[] = [];
  const s = switched({ direct: via("direct", seen), door: via("door", seen), on: askedDoor });
  const handler = forAccount(async (req: Request) => {
    await req.text();
    await s("GET", "/v1/prices");
    return new Response("ok");
  });
  const big = JSON.stringify({ door: true, pad: "x".repeat(300_000) });
  const res = await handler(post(big));
  assertEquals(await res.text(), "ok", "the handler reads it all; nothing waits on a cancelled copy");
  const hook = JSON.stringify({ door: true });
  await handler(new Request("https://b/stripe", { method: "POST", headers: { "content-type": "application/json" }, body: hook }));
  assertEquals(seen, ["direct GET /v1/prices", "direct GET /v1/prices"]);
});

Deno.test("the direct way sends the broker's own idempotency key, as before the door", async () => {
  const keys: (string | undefined)[] = [];
  const direct: Stripe = (_m, _p, _q, k) => (keys.push(k), Promise.resolve({} as never));
  const s = switched({ direct, door: via("door", []), on: askedDoor });
  await s("POST", "/v1/customers", {}, "customer t ana");
  assertEquals(keys, ["customer t ana"]);
});
