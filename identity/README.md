# identity

Social sign-in beside the passkey, with no client, secret or cloud console of an app's own.

## What it adds

Two halves:

- **The identity broker** ([`broker/`](broker)), run once by the framework's operator: an OpenID Connect provider in front of the social providers (Google first) and, where the operator configures it, a phone number texted a code.
- **The app side**, configuration alone: `identity_signin.cue` names the providers (`auth.providers`) and puts the broker in each one's place (`auth.provider.<name>`). No code of this plugin runs in the app.

Each app is its own tenant, never merged with another. The subject the broker vouches for is pairwise, so a person is a stranger to every other app. Only what the tenant asks for arrives: `profile` adds the person's name and picture, `email` an e-mail address the provider says it verified; the installer's `scope=` (default `openid profile`) says which. It needs a pronto with `auth.providers`, a mecha whose auth service signs in by OpenID Connect, and an omnishell that draws a provider's way in.

### An app that moves address

A subject is derived from the tenant's origin, so an app served from a new address would see every person as new, with an empty account. The operator keeps them by giving the new origin a sector, the origin its subjects were made under (OpenID's `sector_identifier`): `BROKER_SECTORS=https://new.example=https://old.example`, comma separated, which `metal.nu` sets with `--sectors`. Both sides are bare https origins; a tenant is named once and a sector is never itself mapped. A malformed list stops the broker at start. The old address stays its own sector, so both addresses answer the same subjects while the app moves.

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

Or on a cluster the operator runs (pronto's `envs.Metal`: k3s on a node reached over SSH, behind its Cloudflare Tunnel), with [`metal.nu`](metal.nu):

```sh
<this repo>/bin/pronto-identity-broker metal --ssh <user>@<node> --project <gcp project> --domain id.example.com --google-client-id <id> [--phone-…]
```

It runs the broker's files on the pinned Deno image from a ConfigMap (no image to build), three replicas in namespace `identity` (a rolling update keeps three answering, a PodDisruptionBudget of two, spread over the nodes where there are several), with a Postgres of its own (`identity-broker-db`, a CloudNativePG cluster whose login is generated in the cluster; the broker reaches it by `DATABASE_URL`), routed by its host through the node's gateway, let out only to DNS, public HTTPS and its database. What it keeps between requests (its one-time codes, the phone's visits, wrong-guess counts and resend waits, and the keys it signs with) is in that database ([`broker/store.ts`](broker/store.ts), PRONTO-371), so any replica can answer any request; the ID-token key and the phone's key (kid: the key's RFC 7638 thumbprint) are made once and shared. Without `DATABASE_URL` (Cloud Run's release, a local broker, the tests) the store is the process's memory and the broker runs as one instance. The tables are created by the broker at start, idempotently. The database's client is postgres.js 3.4.7, vendored as one file ([`common/vendor/`](../common/vendor), linked at `broker/vendor/postgres.js` and shared with the billing broker; `bundle.sh` makes it), so the pod fetches nothing at start. The door probe's spacing stays per replica. Its two secrets are read from the project's Secret Manager with the operator's gcloud and piped into the Secret `identity-broker`, never a file. It ends by asking the broker, through the gateway, for its issuer; pointing the domain at the tunnel is the operator's step.

The env file is never committed. It holds `BROKER_ISSUER`, `BROKER_SECRET` and each provider's client, such as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. `bin/pronto-identity-hydra` runs the broker on Ory Hydra on the operator's machine instead. The app side is [`host.cue`](host.cue) and [`export/`](export). The [`pronto-identity` skill](../skills/pronto-identity/SKILL.md) covers both halves.

## The phone

A broker whose operator turns the phone on also offers `phone`: the person types a mobile number, is texted a code, and the broker vouches for a pairwise subject derived from that number, as it does for Google's. No claim carries the number. The page is the broker's own ([`broker/phone.ts`](broker/phone.ts), under `/phone`), served behind the same code flow as any provider, so `/authorize`, Hydra's login and the callback are unchanged. Two modes, chosen by `PHONE_OTP`:

- `PHONE_TENANTS` (both modes): the origins that may offer it (`*` for a port). Any other tenant asking for `phone` gets `unauthorized_client`: each sign-in is an SMS the operator pays for.
- `PHONE_ADMIT` (both modes): where the page asks for a code before anything is sent, from the reader's browser. It is the app's own rate limit (per phone, device and network), so the caps count the reader's network.
- `PHONE_RESEND_SECONDS` (default 60) and `PHONE_PATTERN` (E.164 numbers accepted, Brazil's mobiles by default).

### `PHONE_OTP=firebase` (the default)

Identity Platform texts the code and the broker takes the Firebase ID token. Nothing changes unless the operator sets `PHONE_OTP=broker`.

- `PHONE_PROJECT`, `PHONE_API_KEY`, `PHONE_APP_ID` (and `PHONE_AUTH_DOMAIN`, default `<project>.firebaseapp.com`): the Firebase Web app's public config. The key must admit the broker's origin as a referrer, and Identity Platform must list it as an authorized domain.
- `PHONE_ADMIT` is also the owner of the project's `beforeSendSms` blocking function, which lets an SMS go only against a code it admitted; the broker adds no SMS path of its own.
- `PHONE_EMULATOR` (`host:port`, a localhost broker only): the Firebase Auth emulator, which sends no SMS and signs unsigned tokens, for a local launch's scenarios.

The subject is derived from the Firebase user, one per number.

### `PHONE_OTP=broker`

The broker issues and checks the codes itself ([`broker/otp.ts`](broker/otp.ts)) and sends the SMS through a pluggable sender. The page loads no Firebase SDK, no gstatic and no reCAPTCHA, and its content security policy names only the broker and the `PHONE_ADMIT` origin. The Firebase settings (`PHONE_PROJECT`, `PHONE_API_KEY`, `PHONE_APP_ID`, `PHONE_AUTH_DOMAIN`, `PHONE_SDK`, `PHONE_EMULATOR`) are refused in this mode, and `PHONE_SMS` and `PHONE_SMS_GATE` in the other, so a mixed-up deployment fails at start.

- The code: six digits from the platform's random source, kept only as a keyed hash bound to the visit and the number, good five minutes, dead after five wrong tries, one per number every `PHONE_RESEND_SECONDS`. In the broker's store (above), so the counts and the wait hold across replicas; neither the number nor the code is logged.
- `PHONE_SMS` (required): the sender. `standin` is for a localhost broker only: it sends nothing, and a local scenario reads the last code for a number from `GET /phone/fake/codes?phone=<e164>`, which answers `{"code": "123456"}` (404 if none), as scenarios read the Firebase emulator's verification codes. A real provider is one entry in `SMS_PROVIDERS` in `otp.ts`: a function that reads its key from the environment and returns `{ send(e164, text) }`. None is registered yet.
- `PHONE_SMS_GATE` (required): the SMS gate, below.
- The subject: HMAC-SHA-256 of the E.164 number under a key HKDF-derived from `BROKER_SECRET`, base64url: stable across restarts, one per number, then the broker's usual pairwise derivation per tenant. Firebase-mode users have different subjects (their Firebase uids): moving a deployment from `firebase` to `broker` signs existing phone users in as new people unless the app maps them.

#### The SMS gate contract

Before each SMS the broker POSTs to `PHONE_SMS_GATE` with `content-type: application/jwt` and the JWT itself as the body, signed RS256 by the key the broker mints at start and publishes at `<issuer>/phone/jwks` (header `kid`; the key changes on a restart, so fetch the set by `kid` and refetch on an unknown one). Claims:

```json
{ "iss": "<broker issuer>", "aud": "<PHONE_SMS_GATE>", "event": "sms", "phone_number": "+5511912345678", "iat": 1700000000, "exp": 1700000060, "jti": "<unique>" }
```

The endpoint verifies the signature against the issuer's jwks, `iss`, `aud` (its own URL), `event` and `exp`, consumes one admission for the number (it may count `jti` once), and answers:

- any `2xx` (body `{}`): send the SMS;
- `403` or `429`: refused, nothing is sent and the page says too many codes were asked for;
- anything else, a timeout (8 s) or no answer: nothing is sent and the page says the SMS sign-in is down. The gate fails closed.

The broker checks the resend wait first, so a number inside it costs the gate nothing.

#### The prove step (`PHONE_PROVE_TENANTS`)

Sign-in never tells a tenant the number. Some apps must know it (a rental's fraud checks), so broker mode has a second capability the operator grants per tenant: `PHONE_PROVE_TENANTS`, origins in `PHONE_TENANTS`' syntax (`*` for a port). Empty or unset, it is off and its routes answer 404. Only listed tenants ever receive a number; a `return` whose origin is not listed is refused by the page, which never redirects there.

The app sends the customer to `<issuer>/phone/prove` with a fragment (never sent to a server): `#phone=<E.164>&state=<s>&return=<url>`. The page cleans its address at once, has the reader confirm the number with a code (the same gate, resend wait and code rules as sign-in; its visit lasts ten minutes) and returns to `return` with `#id_token=<jwt>&state=<s>`, or `#error=cancelled&state=<s>` if the reader goes back. The token is RS256, signed by the key at `<issuer>/phone/jwks` (header `kid`), with:

```json
{ "iss": "<issuer>", "aud": "<return's origin>", "sub": "<the number's HMAC subject>", "phone_number": "+5511912345678", "auth_time": 1700000000, "iat": 1700000000, "exp": 1700000300, "amr": ["sms"], "event": "phone_proof" }
```

The app checks the signature, `iss`, `aud` (its own origin), `exp`, `event` and `state`, then reads `phone_number`. `--phone-prove-tenants` sets it in `release.nu` and `metal.nu`.

`release.nu` and `metal.nu` take `--phone-project`, `--phone-api-key`, `--phone-app-id`, `--phone-admit` and `--phone-tenants` for Firebase mode, and `--phone-otp broker --phone-sms <name> --phone-sms-gate <url>` (with `--phone-admit` and `--phone-tenants`) for broker mode. An app offers it with `providers=google,phone`.

## Google's token exchange through an airlock door (`signin_door`)

On a metal cluster, `metal --airlock` puts mecha's airlock beside the broker (the same pod, ledger and wall as billing's Stripe door: [`common/airlock.nu`](../common/airlock.nu)) and sends Google's token exchange through its door `google`: the broker posts the exchange to `http://identity-broker-airlock:9998/door/google` with the code's own key (`code-<sha256 of the code>`, so one sign-in is one ledger row however often it is made again) and no client secret; the airlock adds the client's credential as `Authorization: Basic` (Google's token endpoint takes `client_secret_basic`), records the call in its ledger, and answers Google's status and body. Only the broker reaches the door's port (NetworkPolicy). The client is the broker's own, and an app's sign-in is the same either way.

- The credential is `GOOGLE_CLIENT_BASIC` in the broker's Secret: base64 of `<client id>:<client secret>`. With `--project`, `metal` makes it from the two; with `--secrets`, the SOPS file holds it beside `GOOGLE_CLIENT_SECRET`.
- `--airlock` alone: the broker holds no `GOOGLE_CLIENT_SECRET` and every exchange goes through the door (`GOOGLE_DOOR`). `GOOGLE_DOOR` with a secret and no `GOOGLE_DOOR_ASKED`, and `GOOGLE_DOOR_ASKED` without both, stop the broker at start.
- `--airlock --door-asked --door-tenants <origins>` (while the flag moves it): the broker keeps its secret and sets `GOOGLE_DOOR_ASKED=1` and `GOOGLE_DOOR_TENANTS` (PHONE_TENANTS' syntax). Only those tenants are asked: every other app on the broker goes straight to Google, unasked, so an app without `signin_door` keeps signing in. When a listed tenant's sign-in begins, the broker asks the tenant's own flagd for the flag `signin_door` (`POST <tenant>/ofrep/v1/evaluate/flags/signin_door`, the tenant as the targeting key; `GOOGLE_DOOR_FLAG` names another flag), seals the answer in the round trip, and exchanges through the door when it is on, straight to Google as before when it is off. A flag that cannot be asked, or that the tenant has not published, is no answer: the sign-in stops with a 503, never picks a way (as billing's door flag); list a tenant in `--door-tenants` only once its push has published the flag. Once it is on for everyone, deploy without `--door-asked`: the broker then holds no Google secret.
- The door probe (`POST <broker>/probe/door`, body `{"tenant": "<origin>"}`, `Authorization: Bearer <the tenant's session token>`) proves the door for one session before its flag reaches everyone. A sign-in asks the flag for no account (the broker knows none when it begins), so a flag on for a flip's testers alone never sends a real sign-in through the door. The probe asks the tenant's flag with the caller's session, at the tenant's door, which names the account from it. Where the flag is on for that session, the probe exchanges a code no one was given through the door. It answers 200 `{door: "credential"}` when Google says `invalid_grant` (the client authenticated, so the airlock added the credential), and 502 `{door: "refused"}` with Google's error otherwise (`invalid_client`: no credential). It answers 409 when the flag is off for the session, 404 for a tenant `--door-tenants` does not list, and 429 within 5 s of the last probe for the tenant. Read-only: the code is refused and no one signs in; each probe is one row in the airlock's ledger. An app's `production` scenario for `signin_door` calls it as its signed-in tester.
- An app declares the flag in its `flags_spec.cue` (`flags: signin_door: {note: "...", default: false, local: true}`) and must route `/ofrep/` to its flagd from its origin, as its door does.

## Tests

- [`tests.cue`](tests.cue): the exported declaration, checked with `cue vet`.
- The phone's cases: [`tests/unit/phone.cue`](../tests/unit/phone.cue) (suite `identity`).
- Deno tests: [`oidc_test.ts`](oidc_test.ts), [`broker/`](broker) (`core_test.ts`, `broker_test.ts`) and [`hydra/`](hydra).

```sh
./saytw --script tools.nu cue vet -c ./identity
./saytw --script tools.nu cue vet -c -t package=check -t broker=https://id.example.com ./identity/export
deno test --no-config --allow-net --allow-read --allow-env identity/oidc_test.ts identity/broker
```
