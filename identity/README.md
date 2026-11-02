# identity

Social sign-in beside the passkey, with no client, secret or cloud console of an app's own.

## What it adds

Two halves:

- **The identity broker** ([`broker/`](broker)), run once by the framework's operator: an OpenID Connect provider in front of the social providers (Google first) and, where the operator configures it, a phone number texted a code.
- **The app side**, configuration alone: `identity_signin.cue` names the providers (`auth.providers`) and puts the broker in each one's place (`auth.provider.<name>`). No code of this plugin runs in the app.

Each app is its own tenant, never merged with another. The subject the broker vouches for is pairwise, so a person is a stranger to every other app. Only what the tenant asks for arrives: `profile` adds the person's name and picture, `email` an e-mail address the provider says it verified; the installer's `scope=` (default `openid profile`) says which. It needs a pronto with `auth.providers`, a mecha whose auth service signs in by OpenID Connect, and an omnishell that draws a provider's way in.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-identity . frontImage=<registry>/pronto-identity:<version>@sha256:<digest> [providers=<a,b>] [scope=openid,profile,email]
./saytw generate && ./saytw lint
```

`frontImage` is required for a local launch, which runs the broker from the front's image. It has no default: publish your own with [`publish.sh`](publish.sh), which prints it. A refresh keeps the one the app already runs. An app that signs in through a broker elsewhere needs none, and names it instead: `broker=https://… [brokerInternal=<url>]`.

The operator runs the broker once:

```sh
<this repo>/bin/pronto-identity-broker [env-file]   # default ~/.config/pronto-identity/broker.env
```

The env file is never committed. It holds `BROKER_ISSUER`, `BROKER_SECRET` and each provider's client, such as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. `bin/pronto-identity-hydra` runs the broker on Ory Hydra on the operator's machine instead. The app side is [`host.cue`](host.cue) and [`export/`](export). The [`pronto-identity` skill](../skills/pronto-identity/SKILL.md) covers both halves.

## The phone

A broker whose operator names a Firebase project (`PHONE_PROJECT`) also offers `phone`: the person types a mobile number, Identity Platform texts a code, and the broker vouches for a pairwise subject derived from the Firebase user, as it does for Google's. No claim carries the number. The page is the broker's own ([`broker/phone.ts`](broker/phone.ts), under `/phone`), served behind the same code flow as any provider, so `/authorize`, Hydra's login and the callback are unchanged.

- `PHONE_PROJECT`, `PHONE_API_KEY`, `PHONE_APP_ID` (and `PHONE_AUTH_DOMAIN`, default `<project>.firebaseapp.com`): the Firebase Web app's public config. The key must admit the broker's origin as a referrer, and Identity Platform must list it as an authorized domain.
- `PHONE_ADMIT`: where the page asks for a code before Firebase sends one, from the reader's browser. It is the owner of the project's `beforeSendSms` blocking function, which lets an SMS go only against a code it admitted under its caps; the broker adds no SMS path of its own.
- `PHONE_TENANTS`: the origins that may offer it (`*` for a port). Any other tenant asking for `phone` gets `unauthorized_client`: each sign-in is an SMS the operator pays for.
- `PHONE_EMULATOR` (`host:port`, a localhost broker only): the Firebase Auth emulator, which sends no SMS and signs unsigned tokens, for a local launch's scenarios.

An app offers it with `providers=google,phone`. `release.nu` takes `--phone-project`, `--phone-api-key`, `--phone-app-id`, `--phone-admit` and `--phone-tenants`.

## Tests

- [`tests.cue`](tests.cue): the exported declaration, checked with `cue vet`.
- The phone's cases: [`tests/unit/phone.cue`](../tests/unit/phone.cue) (suite `identity`).
- Deno tests: [`oidc_test.ts`](oidc_test.ts), [`broker/`](broker) (`core_test.ts`, `broker_test.ts`) and [`hydra/`](hydra).

```sh
./saytw --script tools.nu cue vet -c ./identity
./saytw --script tools.nu cue vet -c -t package=check -t broker=https://id.example.com ./identity/export
deno test --no-config --allow-net identity/oidc_test.ts identity/broker
```
