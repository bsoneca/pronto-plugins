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
