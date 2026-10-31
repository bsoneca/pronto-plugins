# identity

Social sign-in beside the passkey, with no client, secret or cloud console of an app's own.

## What it adds

Two halves:

- **The identity broker** ([`broker/`](broker)), run once by the framework's operator: an OpenID Connect provider in front of the social providers (Google first).
- **The app side**, configuration alone: `identity_signin.cue` names the providers (`auth.providers`) and puts the broker in each one's place (`auth.provider.<name>`). No code of this plugin runs in the app.

Each app is its own tenant, never merged with another. The subject the broker vouches for is pairwise, so a person is a stranger to every other app. It needs a pronto with `auth.providers`, a mecha whose auth service signs in by OpenID Connect, and an omnishell that draws a provider's way in.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-identity . [broker=<url>] [brokerInternal=<url>] [providers=<a,b>]
./saytw generate && ./saytw lint
```

The operator runs the broker once:

```sh
<this repo>/bin/pronto-identity-broker [env-file]   # default ~/.config/pronto-identity/broker.env
```

The env file is never committed. It holds `BROKER_ISSUER`, `BROKER_SECRET` and each provider's client, such as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. `bin/pronto-identity-hydra` runs the broker on Ory Hydra on the operator's machine instead. The app side is [`host.cue`](host.cue) and [`export/`](export). The [`pronto-identity` skill](../skills/pronto-identity/SKILL.md) covers both halves.

## Tests

- [`tests.cue`](tests.cue): the exported declaration, checked with `cue vet`.
- Deno tests: [`oidc_test.ts`](oidc_test.ts), [`broker/`](broker) (`core_test.ts`, `broker_test.ts`) and [`hydra/`](hydra).

```sh
./saytw --script tools.nu cue vet -c ./identity
./saytw --script tools.nu cue vet -c -t package=check ./identity/export
deno test --no-config --allow-net identity/oidc_test.ts identity/broker
```
