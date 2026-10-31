# How an app's author is paid

How the money from a sale in a pronto app reaches the app's author, whoever they are: the
operator, or a third party building on pronto. This describes pronto-billing as it is
(`billing/broker/main.ts`).

## Who is who

- **The buyer**: someone using the app, buying one of its plans (its Pro plan, say).
- **The author**: whoever made the app and set it up to sell (`connect stripe`,
  [intents.md](intents.md)). They need no Stripe account beforehand, and the app holds no Stripe key.
- **The operator**: whoever runs the billing broker (their own, at a domain of theirs) and holds its one
  Stripe platform account. Every app selling through it is a tenant, named by its origin.

## Once: the author's payout account

1. `connect stripe` (or `release`, for an app that sells) asks the broker for the author's
   onboarding link, proving with the author's secret that they own the app's origin.
2. The broker has Stripe make a **connected account** for the author, under the operator's
   platform: an Express account that receives payouts (`/v2/core/accounts`).
3. The author opens the link and fills in Stripe's form: an email and phone, their identity, and
   the bank account to be paid in. The form is the sign-up; there is no account to have before.
4. From then on the broker sells for the app, and the author can see their balance and payouts
   at https://connect.stripe.com/express_login.

## Each sale

1. The buyer presses buy in the app. Its billing service asks the broker for a checkout, and the
   broker opens Stripe Checkout for the plan.
2. The buyer pays in Checkout. The payment is a **destination charge**: made on the operator's
   platform account, and passed on by Stripe to the author's connected account
   (`transfer_data.destination`).
3. The operator keeps its share of each payment first, if the broker is released with one
   (`application_fee_percent`, release.nu `--fee`, 0% by default). The rest goes to the author.
4. A subscription renews each month or year, and each renewal is passed on the same way.
5. The broker tells the app the buyer holds the plan, and the app's paid features open
   (its `Subscription` table).

## Getting the money

Stripe pays the author's balance out to the bank they gave in the form, on Stripe's own payout
schedule for their country: the broker sets none. The author sees each payment, transfer and
payout in their Express dashboard, and Stripe sends them its notices at the email they gave.

## Who pays what

- **Stripe's processing fee** is paid by the operator's platform account: the author receives
  the payment less the operator's share, not less Stripe's fee.
- **Refunds and disputes** are the platform account's: its connected accounts are set up so the
  platform answers for what they owe (`losses_collector: "application"`).
- **The buyer's statement** names the operator's platform account, which made the charge.

## Who can be paid

An adult, in a country where Stripe pays out to connected accounts; Stripe checks their identity
in the form. An author in the operator's own country gets an account that can also take card
payments; one abroad gets an account that receives the transfers only, which is all a payout
needs.
