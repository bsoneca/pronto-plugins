# Stripe: paid plans through pronto-billing

A pronto app sells plans through Stripe without holding a Stripe account, key or dashboard of
its own. One **billing broker**, run by the operator, sits in front of the one Stripe platform
account. Each app is a tenant of it, and its author is paid out through a Stripe connected
account (Express), the platform keeping `BILLING_FEE_PERCENT`.

The code is the `pronto-billing` plugin (`billing/`, described in
[README.md](../README.md#pronto-billing)). There is no shared broker and no default one: whoever
sells runs their own ([Running it](#running-it)) and names it in the app's `release.cue`.

## The parts

```
 page ──/billing/*──► billing service (sidecar, in the app) ──► billing broker ──► Stripe
                           │  ▲                                     │
                           │  └──── POST /billing/events (ES256 JWT) ┘
                           ▼
                 Postgres: subscription table, written only through billing_entitle
                           ▲
                 a paid feature's gate reads it, in the database
```

| Part | Where | What it does |
| --- | --- | --- |
| Billing broker | `billing/broker/` (`main.ts`, `core.ts`, `stripe.ts`, `fake.ts`); one per operator | Talks to Stripe: onboarding, Checkout, the customer portal, webhooks. Keeps no database: tenants, accounts and plans ride Stripe's metadata |
| Billing service | `billing/service.ts`, copied into the app's `billing/`; runs beside the door | Sends an account to Checkout or the portal, and takes the broker's entitlements into the database. Holds no secret |
| `Subscription` table and migration | `billing_plugin.cue` in the app (`billing_01`, named by the app, e.g. `16_billing`) | One row per account and plan. Sessions cannot write it; only `billing_entitle`, called as the service, can |
| Plans | `billing_spec.cue` in the app; served at `<origin>/.well-known/pronto-billing.json` | What the app sells, its prices in minor units, and the hash of the owner's secret |
| The gate | the app's own migration | A paid feature checks the session's `subscription` row in SQL: `active` and `through > now()` |

## How a purchase flows

1. The page asks the service for a checkout. The service calls the broker's
   `POST /checkout {tenant, account, plan, currency?, locale?, return?}`.
2. The broker reads the tenant's plans from its origin's `/.well-known/pronto-billing.json`,
   closes any checkout the account left open, and returns a Stripe Checkout URL.
3. The account pays on Stripe.
4. Stripe's webhook reaches the broker at `/stripe`. The broker reads the account's
   subscriptions to the plan again from Stripe and pushes an entitlement to the tenant:
   `POST <origin>/billing/events`, an ES256 JWT with audience the tenant and
   `{sub, plan, status: active|lapsed, through, manage, ver}`.
5. The service checks the JWT against the broker's `/jwks` (`billing/entitlement.ts`) and calls
   `billing_entitle`, which writes the `subscription` row. `ver` orders pushes, so an older one
   never overwrites a newer one.
6. The broker answers Stripe's webhook only once the tenant has taken the push, so Stripe's
   retries redeliver what a tenant missed.

Managing or cancelling goes through `POST /portal {tenant, account, manage, return?}`, with the
`manage` token the tenant was given. `POST /resync` reads an account's entitlement again for a
tenant that missed a push.

A plan whose price changes is sold at a new Stripe price; existing subscriptions keep theirs.
The broker runs as a single instance, since `ver` is its clock.

## Security model

- **Secrets stay with the operator.** The Stripe key, the webhook secret, the broker's signing
  key and `BROKER_SECRET` live only with the broker (on Cloud Run, in Secret Manager). Apps hold
  none.
- **The database is the gate.** No page can grant a plan: sessions' writes to
  `subscription` are refused by a trigger, and a feature's check runs in SQL under the session's
  identity, and raises the app's own refusal without an active row. Only the service writes it, through two functions: `billing_entitle`, with an
  entitlement the broker signed, and `billing_grant`, with the author's grants.
- **Grants are the author's, and public.** `billing.grants` in `billing_spec.cue` gives an
  account a plan free through a day. With pronto-flags it is the flag `billing_grants`, which
  `pronto-flags push` changes with no deploy and the service reads every minute; like any flag,
  anyone can read it at `/ofrep/`. A grant's row has `ver` 0, so a payment always outranks it.
- **Payouts need the author's secret.** `billing_spec.cue` publishes only the hash of the owner's
  secret. Onboarding (`billing/owner.ts onboard`) needs the secret itself, so neither a stranger
  racing the author through Stripe's onboarding nor a copied `pronto-billing.json` attaches a
  bank account to an origin.

## Running it

### On a developer's machine

`launch@local` and `integrate@local` run the broker beside the app. Without
`STRIPE_SECRET_KEY`, on a localhost issuer, it uses a stand-in for Stripe at `/fake/stripe`:
payouts set up at a press, a checkout that pays, and a portal that cancels, renews or fails the
next payment. The stand-in listens on 127.0.0.1 only and refuses to run with a real signing key.

An app's own browser test can use it end to end: an account is offered the plan, subscribes,
uses the paid feature, cancels, and is refused it by the database.

### The operator's broker

```sh
bin/pronto-billing-broker keygen      # BILLING_SIGNING_KEY, into the env file
bin/pronto-billing-broker webhook     # STRIPE_WEBHOOK_SECRET, once per platform account
bin/pronto-billing-broker [env-file]  # run it (default ~/.config/pronto-billing/broker.env)
```

Or on Cloud Run, at its own domain. The Stripe key is stored by the operator first and never
passed through the release:

```sh
read -rs S; printf '%s' "$S" | gcloud secrets create billing-broker-stripe-key --project P --data-file=-
bin/pronto-billing-broker release --project P --domain billing.example.com [--fee N]
```

The release creates `BROKER_SECRET` and `BILLING_SIGNING_KEY` and registers Stripe's webhook for
`https://<domain>/stripe`. After switching from a test key to a live one, `--webhook` registers
it again. The domain's DNS records are the operator's to add.

### Adding billing to an app

```sh
deno run billing/owner.ts new                # the author's secret, and its hash
bin/pronto-billing <app-dir> <hash>           # writes the app's files
# say what the app sells in billing_spec.cue, and gate the paid feature in a migration
./saytw generate && ./saytw lint
PRONTO_BILLING_OWNER=<secret> deno run --allow-net --allow-env billing/owner.ts onboard <broker> <origin> <email>
```

A gcp release runs the service as a sidecar (`sidecars: billing: {port: 8688}` in
`release.cue`) and points it at the operator's broker with `BILLING_BROKER` and
`BILLING_BROKER_INTERNAL`; `connect stripe` writes them from `--broker`, once.

### The broker's Stripe key

A restricted key will do: customers, products, prices, Checkout, the portal and webhooks to
write; subscriptions and accounts to read. Account Links, and Recipient and Merchant
Configuration (Accounts v2), go to Write to onboard an author: without Merchant and Recipient
Configuration at Write, every checkout fails with a 403 on an `rconf_` object.
