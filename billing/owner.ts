// An app author's side of payouts: a secret only they hold, whose hash the
// app publishes (billing.owner in the app's billing_spec.cue), and setting up
// payouts with it, from their own terminal so it is never in a link.
//   deno run billing/owner.ts new                          # the secret, and its hash
//   deno run billing/owner.ts onboard <broker> <origin> <email> [country]   # PRONTO_BILLING_OWNER holds the secret
// The email is where Stripe reaches the author about payouts; country, where they are paid.
import { randomToken } from "./shared.ts";
import { ownerOf } from "./broker/core.ts";

const [cmd, broker, tenant, email, country] = Deno.args;
if (cmd === "new") {
  const secret = randomToken(32);
  console.log(`PRONTO_BILLING_OWNER=${secret}   # keep it: payouts are set up with it`);
  console.log(`owner: "${await ownerOf(secret)}"   # the app's billing_spec.cue publishes this`);
} else if (cmd === "onboard" && broker && tenant && email) {
  const owner = Deno.env.get("PRONTO_BILLING_OWNER");
  if (!owner) throw new Error("PRONTO_BILLING_OWNER holds the secret `new` printed");
  const res = await fetch(`${broker.replace(/\/$/, "")}/onboard`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ tenant, owner, email, ...(country ? { country } : {}) }),
  });
  const out = await res.json();
  if (!res.ok) throw new Error(`the broker answered ${res.status}: ${out.error}`);
  console.log(`Set up payouts for ${tenant} at Stripe:\n${out.url}`);
} else {
  console.error("usage: owner.ts new | owner.ts onboard <broker> <origin> <email> [country]");
  Deno.exit(2);
}
