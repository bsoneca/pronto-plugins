---
name: pronto-identity
description: "Add social sign-in (Google, and the providers the identity broker offers) to a pronto app beside its passkey, or refresh it, with no client, secret or cloud console of the app's own: the app's auth service signs people in through the identity broker the framework's operator runs, each app its own tenant with its own users. Also how the operator runs that broker. Use when the user wants Google login, social login or \"Sign in with …\" on a pronto app, or to run the broker."
---

# pronto-identity

A plugin beside pronto, not part of it. Two halves:

- **The broker** (`identity/broker/`), run once by the framework's operator: an
  OpenID Connect provider in front of the social providers, whose clients the
  operator registers once. An app is never asked for any of it.
- **The app side**, configuration alone: the program names the providers and
  puts the broker in each one's place, so mecha's own auth service signs in
  through it and the terminal draws the way in.

It needs a pronto with `auth.providers` and `auth.provider` (with the mecha and
omnishell it pins); on one without them, `sayt generate` refuses
`identity_signin.cue` with `field not allowed`, and that is the answer.

## Tenants

Each application is its own tenant, and tenants are never merged:

- Its client id is its origin; it is a public client proving its code with
  PKCE, holding no secret, needing no registration.
- Its one redirect per provider is its origin's `/auth/oidc/<provider>/callback`
  (mecha's), exact. The broker
  refuses any other without redirecting, and an error goes to the redirect
  only once the redirect is known to be the tenant's.
- The subject the broker vouches for is pairwise: a keyed hash of tenant,
  provider and the provider's subject. One person is a stranger to every other
  app, and only what the tenant asked for arrives: `openid` alone gives the
  subject; `profile` adds the name and picture; `email` adds the e-mail address,
  and only one the provider says it verified (`email_verified` true), with
  `email_verified: true` beside it. The provider is asked only for what the
  tenant asked, and the broker's page names the e-mail when it was asked.
- A code is single-use and redeemable only by the tenant and redirect it was
  issued to; the ID token's audience is that tenant alone.

## What the app gets

| Path | Owner |
| --- | --- |
| `identity_signin.cue` | regenerated: `auth.providers`, and `auth.provider.<name>` putting the broker in each one's place, as defaults a deployment's `OIDC_<NAME>_*` overrides; no secret. With the default broker, also the local broker's two services (below) |

The writer also removes what earlier versions wrote (`identity_hatch.cue`,
`identity/auth/*`, `identity/broker.env`, `pronto/identity.cue`) while each
still carries its generated header, and names any the app has edited.

## The local broker

With the default broker (`http://localhost:<port>`, a port of the app's own, hashed
from its package, so two apps' launches never share one; Hydra's two ports move
by `IDENTITY_HYDRA_PUBLIC_PORT` and `IDENTITY_HYDRA_ADMIN_PORT` as every other port
of a launch), the app's own launch brings it up: `identity-hydra` (Ory Hydra, in memory) and `identity` (the front), two
services of its cluster from the front's image the app names (`frontImage`, the operator's
own: there is no default).

- `launch@local` runs each as a host process (`hydra/local.sh`, from the
  image's files, taken once per release into `~/.cache/pronto-identity`). With the
  operator's `~/.config/pronto-identity/broker.env` it signs in through Google;
  without it, through a stand-in that says it is not Google and signs in a test
  person (`tester`, `tester-2`, or any `tester-<a-z0-9->` a scenario names
  at `/fake/google/approve`, so each run may sign in someone new), with the name
  `Test <who>` and, asked for `email`, the verified address `<who>@example.com`.
- `launch` runs their images: Hydra's, and the front's (`frontImage`), the
  stand-in unless `GOOGLE_CLIENT_ID`
  and `GOOGLE_CLIENT_SECRET` are set.
- Its port is the operator's standalone broker's: run one or the other.

A release names the operator's broker instead (`OIDC_<NAME>_ISSUER` and
`_INTERNAL`), and an app given `broker=<url>` gets no local broker.

## Adding it to an app

From a pronto app whose auth plane is on (`capabilities.auth`) and whose four
verbs are green:

1. `${CLAUDE_PLUGIN_ROOT}/bin/pronto-identity . frontImage=<image>` (the front's image the
   operator published, below; a refresh keeps the one the app has), or `broker=<url>` for an
   operator's broker elsewhere, which needs no image; `providers=<a,b>` for more than Google;
   `scope=openid,profile,email` for what the app asks the broker for (default `openid profile`;
   a refresh keeps the app's).
2. Add a decision for the sign-in to `ir.html`, then re-pin `meta.ir.sha256`.
3. The terminal's strip offers each provider to a guest. An app that hides the
   strip presses its `.shell-provider[data-provider=<name>]` link from its own
   bar, as it presses the passkey.
4. `./saytw generate && ./saytw lint && ./saytw test && ./saytw integrate`.

Re-run `bin/pronto-identity` to refresh.

## Publishing the broker's runtime

`IMAGE=<registry>/pronto-identity identity/publish.sh <version>` publishes what ships
(`oidc.ts`, `broker/`, `hydra/`, committed) to the operator's own registry (there is no
default), and prints its digest. Re-run `bin/pronto-identity . frontImage=<image>:<version>@<digest>`
in each app. A new ghcr package is private: make it public once under its owner's packages.

## Running the broker (the operator, once)

1. Each provider's client, registered once by the operator: for Google, a "Web
   application" OAuth client whose only redirect URI is
   `<broker issuer>/callback/google` (`http://localhost:28443/callback/google`
   on the operator's machine). Never an app's own URL.
2. `~/.config/pronto-identity/broker.env`, mode 600, never committed:
   `BROKER_ISSUER`, `BROKER_SECRET` (32+ characters; it derives every pairwise
   subject, so rotating it gives every person a new subject in every app), and
   `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`. Ask the operator to fill the
   secrets in themselves.
3. `${CLAUDE_PLUGIN_ROOT}/bin/pronto-identity-broker` serves it on `PORT`
   (28443). It speaks plain HTTP; TLS is the platform's.

## The phone

`providers=google,phone` offers a phone number texted a code (Identity Platform)
beside Google, through the same broker: the subject is pairwise, and the app
never learns the number. The operator's broker must name a Firebase project, the
`beforeSendSms` gate's owner as `PHONE_ADMIT` and the app among `PHONE_TENANTS`
(identity/README.md, "The phone"). A local launch's broker signs in against the
Firebase Auth emulator: the app sets the `identity` service's `PHONE_PROJECT`,
`PHONE_EMULATOR`, `PHONE_ADMIT` and `PHONE_TENANTS` in a file of its own, as it
sets `PRONTO_IDENTITY_ENV`. The terminal labels the strip's link with the app's
`chrome_signin_phone` message.

## Limits

- Codes live in the broker's memory: it runs as one instance, and a code it
  forgets on restart is a sign-in the reader repeats.
- The ID-token key is minted at start; tenants fetch a key they do not know.
- Google's consent screen names the operator's client, not each app; the
  broker's own page names the app's origin before leaving for Google.
- One way in per account: a passkey or a provider, never both, and a provider
  never promotes a guest.
