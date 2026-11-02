# unity

An app's opt-in to [pronto-csharp](https://github.com/bsoneca/pronto-csharp)'s Unity host: one
declaration, `unity_surface.cue`, written by `bin/pronto-unity` from [host.cue](host.cue), and the
same as `unity/unity.json` for the host. The host reads only what it names. How to add it:
[the skill](../skills/pronto-unity/SKILL.md). Cases: `cue vet -c ./unity`.

On Android, `links=<host,…>` with `fingerprints=<sha256,…>` (the certificates that sign the player) makes
https links of those hosts open the player rather than the browser: the declaration adds
`code: meta: wellKnown: "assetlinks.json"` so the door serves the Digital Asset Links, and the host's Android
build writes the verified intent filter from `unity.json`'s `android`. A sign-in comes back to the app this
way, with the door's handoff code in the link's fragment.

A hatch can be bound: `unity/hatches/<name>/binding.cue` (schema `#HatchBinding` in [host.cue](host.cue)) names the
app's own JavaScript module and what it may read, submit and click; `bin/pronto-unity` writes it as `binding.json`
and maps the hatch to it in `hatches`. See [the skill](../skills/pronto-unity/SKILL.md) and the
[contract](https://github.com/bsoneca/pronto-csharp/blob/main/docs/pronto-unity-hatch-contract.md).

## `./saytw unity`

Opting in also gives the app a `unity` verb (sayt has none; `.say.json` declares it in `say.self.verbs`, beside the keys of other hosts):

```sh
./saytw unity@local     # or ./saytw unity
```

It stages the app from its folder into [pronto-csharp](https://github.com/bsoneca/pronto-csharp)'s released host, runs the unit
cases of the suites the declaration runs there, then the scenarios, and exits non-zero when any case or scenario fails. A scenario
that needs the app's stack (`cluster: true`) is skipped, as the host does, unless `PRONTO_DOOR_<APP>` (the app name upper-cased,
`-` as `_`) names its door; a drag needs a drawn surface and is reported skipped. No Unity Editor is needed. The host is a mise tool,
`github:bsoneca/pronto-csharp`, pinned in `.config/mise/conf.d/unity.toml`; the repository is private, so mise needs `GITHUB_TOKEN`
(or `MISE_GITHUB_TOKEN`) to fetch it. An app's `mise.lock` (when it locks) needs the tool's entry: `mise lock`. The verb's rule is
`unity.local` in [host.cue](host.cue); sayt's builtin for a custom verb (`true`) is switched off so it does not stop it.
