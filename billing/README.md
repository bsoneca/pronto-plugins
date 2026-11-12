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
deno run <this repo>/billing/owner.ts new                    # the author's secret, and its hash
<this repo>/bin/pronto-billing <app-dir> <hash>  # writes billing_plugin.cue and the rest
# say what the app sells in billing_spec.cue
./saytw generate && ./saytw lint
```

An app may offer an opt-in free trial of some plans (`billing.trial` in `billing_spec.cue`, behind `_billingTrialFlag`): [docs/stripe.md](../docs/stripe.md#free-trial) says how it stays safe. Its tables and functions are the `_billingTrialMigration`, named by the app after the grants'.

The operator runs the broker with `bin/pronto-billing-broker` (`keygen`, `webhook`, `release`, `metal`). `metal` puts it on a cluster the operator runs (pronto's `envs.Metal`), in the shape [`identity/metal.nu`](../identity/metal.nu) gives the identity broker: [`metal.nu`](metal.nu) runs the broker's files on the pinned Deno image from a ConfigMap, one replica in namespace `billing` for now, routed by its host through the node's gateway, let out only to DNS, public HTTPS and the airlock's door. The airlock is always beside it (PRONTO-270): it holds the Stripe keys, a door each (`stripe`, `stripe-sandbox`), and the broker holds none and reaches Stripe only through it (but while `--door-asked` moves the node, PRONTO-218). Its secrets go from the project's Secret Manager into the Secret `billing-broker` through ssh, never a file, and it ends by checking that the node's broker signs with the key the domain's broker publishes. What it keeps between requests (the lock on an account while its Checkout opens, the entitlements' `ver`, its limits, the Stripe events it delivered, the tenants with no payouts account yet) is in a Postgres of its own, `billing-broker-db` (CloudNativePG, [`common/broker_db.nu`](../common/broker_db.nu), as the identity broker's), which the release brings up before it replaces the broker; [`broker/store.ts`](broker/store.ts) keeps the same in memory where there is no `DATABASE_URL`. Pointing the domain at the tunnel is the operator's step. Without `STRIPE_SECRET_KEY` on a localhost issuer, a stand-in for Stripe takes payments, reached through its own door at `STRIPE_DOOR` as the node's broker reaches Stripe through the airlock's. Config: the plans, the owner's hash and the broker's address in `billing_spec.cue`; the broker's env file. The files written and the endpoints are in the [root README](../README.md#pronto-billing).

## Tests

Deno tests next to the code: [`service_test.ts`](service_test.ts), [`install_test.ts`](install_test.ts) and [`broker/`](broker) (`core_test.ts`, `broker_test.ts`). [`broker/trial_sandbox.ts`](broker/trial_sandbox.ts) is not run by them: it checks the stand-in's trials against Stripe's sandbox, by an operator with a test key.

```sh
deno lint --no-config billing && deno test --no-config --allow-net --allow-read --allow-write --allow-run billing
```
