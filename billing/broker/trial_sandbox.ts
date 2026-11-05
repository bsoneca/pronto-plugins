// What the stand-in (fake.ts) claims of Stripe's free trials, checked against Stripe's sandbox
// with test clocks. The operator runs it by hand, with a test key; nothing else in this
// repository talks to Stripe, so this is what keeps the stand-in honest:
//
//   STRIPE_SECRET_KEY=sk_test_... deno run --allow-net --allow-env billing/broker/trial_sandbox.ts [acct_...]
//
// It refuses any key that is not a test key. It runs a trial to a paid subscription (a card that
// pays), to a failed first charge (a card that is declined, which must read as the broker's rule
// 4 reads it), and to a cancel at the period's end (which must end uncharged); and it opens, and
// does not complete, a Checkout session with the very parameters the broker sends for a trial.
// With a connected account's id, the session pays that account as the broker's does. Everything
// it makes is deleted or closed after, and each result is printed.
import { checkoutSession, firstChargeFailed, type Subscription } from "./core.ts";
import { stripe } from "./stripe.ts";

const key = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
if (!/^[sr]k_test_/.test(key)) throw new Error("STRIPE_SECRET_KEY is a test key: sk_test_ or rk_test_");
const destination = Deno.args[0];
const s = stripe({ key });

const HOUR = 3600, DAY = 86_400;
let failed = 0;
const result = (name: string, ok: boolean, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
};

const clocks: string[] = [], customers: string[] = [], sessions: string[] = [], prices: string[] = [];
const now = Math.floor(Date.now() / 1000);
const tag = `trial-sandbox ${now}`;

const price = await s<{ id: string }>("POST", "/v1/prices", {
  currency: "usd", unit_amount: 500, recurring: { interval: "month" }, product_data: { name: tag },
});
prices.push(price.id);

// A trial of three days, begun on a test clock, whose customer holds `card`.
async function begin(card: string) {
  const clock = await s<{ id: string }>("POST", "/v1/test_helpers/test_clocks", { frozen_time: now, name: tag });
  clocks.push(clock.id);
  const customer = await s<{ id: string }>("POST", "/v1/customers", { test_clock: clock.id, metadata: { tag } });
  customers.push(customer.id);
  await s("POST", `/v1/payment_methods/${card}/attach`, { customer: customer.id });
  await s("POST", `/v1/customers/${customer.id}`, { invoice_settings: { default_payment_method: card } });
  const trialEnd = now + 3 * DAY;
  const sub = await s<Subscription>("POST", "/v1/subscriptions", {
    customer: customer.id, items: [{ price: price.id }], trial_end: trialEnd,
    trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
    metadata: { tenant: "https://sandbox.example", account: "ana", plan: "plus", trial: "1", trial_amount: "500", trial_currency: "usd" },
  });
  return { clock: clock.id, customer: customer.id, sub, trialEnd };
}

// Moves the clock on an hour at a time, as far as Stripe takes to invoice and charge, until `done`.
async function advance(t: { clock: string; sub: Subscription; trialEnd: number }, done: (sub: Subscription) => boolean): Promise<Subscription> {
  let at = t.trialEnd;
  for (let hour = 0; hour < 8; hour++) {
    at += HOUR;
    await s("POST", `/v1/test_helpers/test_clocks/${t.clock}/advance`, { frozen_time: at });
    for (let wait = 0; wait < 60; wait++) {
      const clock = await s<{ status: string }>("GET", `/v1/test_helpers/test_clocks/${t.clock}`);
      if (clock.status === "ready") break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    const sub = await s<Subscription>("GET", `/v1/subscriptions/${t.sub.id}`);
    if (done(sub)) return sub;
  }
  return await s<Subscription>("GET", `/v1/subscriptions/${t.sub.id}`);
}
const paidInvoices = async (customer: string) =>
  (await s<{ data: { amount_paid: number }[] }>("GET", "/v1/invoices", { customer, limit: 10 })).data.filter((i) => i.amount_paid > 0).length;

try {
  // A trial runs free until its end, and holds the plan: what the stand-in's trialing is.
  const paid = await begin("pm_card_visa");
  result("a trial begins trialing, to the day given", paid.sub.status === "trialing" && paid.sub.trial_end === paid.trialEnd, `${paid.sub.status}, trial_end ${paid.sub.trial_end}`);
  result("its period ends where its trial does", paid.sub.current_period_end === paid.trialEnd, String(paid.sub.current_period_end));
  result("and carries its metadata", paid.sub.metadata.trial === "1" && paid.sub.metadata.trial_amount === "500");
  result("nothing is charged before it ends", (await paidInvoices(paid.customer)) === 0);

  // Trial to paid: active, a new period beginning where the trial ended, one charge.
  const active = await advance(paid, (x) => x.status !== "trialing");
  result("a trial with a card becomes active", active.status === "active", active.status);
  result("its first paid period begins at the trial's end", active.current_period_start === paid.trialEnd, String(active.current_period_start));
  result("and is charged once", (await paidInvoices(paid.customer)) === 1);
  result("and is no failed first charge", !firstChargeFailed(active));

  // Trial to a declined first charge: past due, in the period the trial's end opened. This is
  // what the broker's rule 4 reads to cancel it at once.
  const decline = await begin("pm_card_chargeCustomerFail");
  const late = await advance(decline, (x) => x.status === "past_due" || x.status === "unpaid");
  result("a trial whose card is declined is past due", late.status === "past_due" || late.status === "unpaid", late.status);
  result("in the period its end opened", late.current_period_start === decline.trialEnd, String(late.current_period_start));
  result("the broker's rule 4 reads it as a failed first charge", firstChargeFailed(late));
  await s("POST", `/v1/subscriptions/${late.id}`, { metadata: { trial_failed: "1" } });
  await s("DELETE", `/v1/subscriptions/${late.id}`);
  const ended = await s<Subscription>("GET", `/v1/subscriptions/${late.id}`);
  result("cancelled at once, marked failed, nothing paid", ended.status === "canceled" && ended.metadata.trial_failed === "1" && (await paidInvoices(decline.customer)) === 0, ended.status);

  // Trial cancelled at the period's end, as the portal does: ends with the trial, never invoiced.
  const cancel = await begin("pm_card_visa");
  const marked = await s<Subscription>("POST", `/v1/subscriptions/${cancel.sub.id}`, { cancel_at_period_end: true });
  result("a trial set to cancel keeps trialing until its end", marked.status === "trialing" && marked.cancel_at_period_end === true, marked.status);
  const gone = await advance(cancel, (x) => x.status === "canceled");
  result("and is cancelled when it ends", gone.status === "canceled", gone.status);
  result("without a paid invoice", (await paidInvoices(cancel.customer)) === 0);

  // The Checkout session the broker opens for a trial, with the broker's own parameters.
  const buyer = await s<{ id: string }>("POST", "/v1/customers", { metadata: { tag } });
  customers.push(buyer.id);
  const metadata = { tenant: "https://sandbox.example", account: "ana", plan: "plus", trial: "1", trial_amount: "500", trial_currency: "usd" };
  const session = await s<{ id: string; url: string | null; payment_method_collection: string }>("POST", "/v1/checkout/sessions", checkoutSession({
    customer: buyer.id, account: "ana", locale: "en", price: price.id, back: "https://sandbox.example/back", metadata, currency: "usd",
    trialEnd: now + 90 * DAY, ...(destination ? { destination } : {}),
  }));
  sessions.push(session.id);
  result("Checkout takes the trial's parameters and collects a card", !!session.url && session.payment_method_collection === "always", session.payment_method_collection);
  const tooSoon = await s("POST", "/v1/checkout/sessions", checkoutSession({
    customer: buyer.id, account: "ana", locale: "en", price: price.id, back: "https://sandbox.example/back", metadata, trialEnd: now + HOUR,
  })).then(() => false, () => true);
  result("and refuses a trial under 48 hours, as the stand-in does", tooSoon);
} finally {
  // Deleting a clock deletes its customers and their subscriptions with it.
  for (const id of clocks) await s("DELETE", `/v1/test_helpers/test_clocks/${id}`).catch(() => {});
  for (const id of sessions) await s("POST", `/v1/checkout/sessions/${id}/expire`).catch(() => {});
  for (const id of customers) await s("DELETE", `/v1/customers/${id}`).catch(() => {});
  for (const id of prices) await s("POST", `/v1/prices/${id}`, { active: false }).catch(() => {});
}
console.log(failed === 0 ? "the stand-in's trials match Stripe's" : `${failed} result(s) differ: fix fake.ts`);
Deno.exit(failed === 0 ? 0 : 1);
