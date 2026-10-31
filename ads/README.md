# ads

Rewarded ads for a pronto app: an ad a player chooses to watch for something the app gives in return, never one that interrupts them.

## What it adds

- `ads/ads.js` (or the path you name): a page module exporting `rewarded()`. It resolves `"viewed"` when the ad played to its end, `"dismissed"` when it was closed before, and `"none"` when there is no ad to show.
- A generate step that gives the door `/ads.txt` again after pronto's writer, carrying the AdSense publisher's line.
- `ads_spec.cue`, written once and then the app's: `adsense: publisher: "pub-…"`, or `""` for none.

For now the ad is a stand-in that plays at a press. Google's ads take its place once the app names a publisher and the door's policy admits Google's scripts and frames. The page alone knows an ad was watched, so whatever a reward gives away, the app's database bounds.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-ads . [<module-path>]   # ads/ads.js unless named
# name the publisher in ads_spec.cue
./saytw generate && ./saytw lint
```

The installer is [`install.ts`](install.ts); the app's files come from [`app/`](app). It refuses a directory that is no pronto app, and a path out of the app. There is no skill for this plugin. The [root README](../README.md#pronto-ads) has the rest.

## Tests

[`install_test.ts`](install_test.ts) runs the installer on a temporary app: the module, the generate step and the spec are written, again over an edit, and the spec only once.

```sh
deno lint --no-config ads && deno test --no-config --allow-read --allow-write --allow-run ads
```
