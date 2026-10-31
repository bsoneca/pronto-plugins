# billing

Paid plans for a pronto app, with no Stripe account, key or dashboard of the app's own.

## What it adds

Two halves:

- **The billing broker** ([`broker/`](broker)), run once by the framework's operator in front of the one Stripe platform account. It signs entitlements (ES256 JWTs) and pushes them to each app.
- **The app side**: the plans the app sells, a `Subscription` table only the database writes, and a small service ([`service.ts`](service.ts)) beside the door. The service takes the broker's entitlements into the table and sends an account to Checkout or to Stripe's portal. The paid feature's gate is the app's own, read from that table.

Each app is its own tenant, named by its origin. Its author is paid out through a Stripe connected account. The wire protocol and payouts are in [docs/stripe.md](../docs/stripe.md) and [docs/billing-payouts.md](../docs/billing-payouts.md).

## Use

Say it in a sentence through the [`pronto-intents` skill](../skills/pronto-intents/SKILL.md), or run the intent:

```sh
<this repo>/bin/pronto connect stripe <app-dir>
```

By hand, from a pronto app:

```sh
deno run billing/owner.ts new                    # the author's secret, and its hash
<this repo>/bin/pronto-billing <app-dir> <hash>  # writes billing_plugin.cue and the rest
# say what the app sells in billing_spec.cue
./saytw generate && ./saytw lint
```

The operator runs the broker with `bin/pronto-billing-broker` (`keygen`, `webhook`, `release`). Without `STRIPE_SECRET_KEY` on a localhost issuer, a stand-in for Stripe takes payments. Config: the plans, the owner's hash and the broker's address in `billing_spec.cue`; the broker's env file. The files written and the endpoints are in the [root README](../README.md#pronto-billing).

## Tests

Deno tests next to the code: [`service_test.ts`](service_test.ts), [`install_test.ts`](install_test.ts) and [`broker/`](broker) (`core_test.ts`, `broker_test.ts`).

```sh
deno lint --no-config billing && deno test --no-config --allow-net --allow-read --allow-write --allow-run billing
```
