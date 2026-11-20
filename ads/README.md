# ads

Rewarded ads for a pronto app: an ad a player chooses to watch for something the app gives in return, never one that interrupts them.

## What it adds

- `ads/ads.js` (or the path you name): a page module exporting `rewarded()` and `prepare()`. `rewarded({wait, name, onStart, onEnd})` resolves `"viewed"` when the ad played to its end, `"dismissed"` when it was closed before, and `"none"` when there is no ad to show. An unexpected failure rejects, after the failed ad is cleared away so the next ask starts again; Google's no-fill and network failures are `"none"`.
  Its header names the pronto-plugins commit it was generated from (the last to touch the template), so a diff of an app shows generator output and not a hand edit.
- `ads_site.js` beside it: the app's origin and the ad document's, written by generate from the spec (both empty while no publisher is named).
- A generate step (`ads/ads.nu`, run by `pronto/ads.cue` after pronto's writer) that gives the door `/ads.txt` again with the publisher's line, appends `frame-ancestors 'self'` to the door's policy and adds `X-Frame-Options: SAMEORIGIN` (a `<meta>` cannot carry `frame-ancestors`), and writes `ads/break.json` and `ads_site.js`. With no publisher it adds nothing and removes its earlier additions.
- `ads_plugin.cue`, regenerated, in the app's package: the ad document, its bridge script, the policy that holds it with the bridge's sha256, the shell's frame source (core's `resources`, `frame-src` of the ad origin and nothing more) and the `ads` service's cluster target, all only once a publisher is named.
- `ads/server.ts`, regenerated: the `ads` service. A pure `handle(Request)`: `GET`/`HEAD /break` answers the ad document with its policy, `/health` answers 200, every other path is a 404 with `default-src 'none'`.
- `ads_spec.cue`, written once and then the app's: `adsense: publisher: "pub-…"` (or `""`), and `site` (the origin the app is served from, https) and `frame` (the origin of the ad document), both required once a publisher is named.

## How an ad plays

Google's scripts never load in the app's page. They load in the ad document, which the `ads` service answers at an origin of its own (`adsense.frame`: a name the release routes straight to the service, never the door), under a policy of its own, and the page frames it. That origin is the only isolation there is: it is a sibling name of the app's, so the app's session cookies must be host-only (no `Domain`, as pronto's `__Host-` cookies are) and the legacy unprefixed one off.

| Where | Ads |
| --- | --- |
| no publisher, or any origin but `adsense.site` (a preview, ci, a developer's machine) | the stand-in, a dialog that plays at a press |
| `adsense.site` | Google's, live |
| `adsense.site` with `?ads=google-test` | Google's test ads (`?test=on` on the frame), which pay nothing |

`prepare()` makes the frame (hidden, off screen, in a sandbox without `allow-top-navigation`); the app calls it once its flag allows ads, and nothing is asked of Google before. `rewarded()` makes it too if it has not been.

The page and the ad document talk by `postMessage`, version 1. Each message is `{type: "pronto-ads", v: 1, ...}`; the page addresses the ad origin and the frame addresses `adsense.site`, never `*`, and each takes a message only from the other's origin and window.

| From | Message | When |
| --- | --- | --- |
| page | `{op: "break", id, name}` | starts an ad break; `name` is `"purse"` or `"review"` |
| page | `{op: "show", id}` | once the page has made the frame cover the viewport |
| frame | `{id: null, event: "ready"}` | Google's library is up |
| frame | `{id, event, breakStatus?}` | `event` is `beforeReward`, `beforeAd`, `afterAd`, `adViewed`, `adDismissed` or `done`; `breakStatus` is Google's, at most 32 characters |

The page drops everything else, Google's own messages to it included. `beforeReward` makes the page expand the frame and then send `show`; `beforeAd` and `afterAd` call `onStart` and `onEnd` (the game mutes its sound). `done` settles the ad: what `adViewed` or `adDismissed` recorded, else `breakStatus` `viewed` or `dismissed`, else `"none"`. `wait` (15 s) bounds only the time before the ad starts; once it has, Google's API has 180 s; a late event is ignored.

The ad document's policy is the one list of what Google's ads load (`_adsGoogle`, `_adsPolicy` in `ads_plugin.cue`): `script-src` is the bridge's hash and two path-scoped sources, never a whole Google host (`www.google.com`, `googleadservices.com`, `*.doubleclick.net`, `googleapis.com` and `gstatic.com` have script endpoints and must never be one); no `sandbox`, no `unsafe-eval`, no Trusted Types; `frame-ancestors` is `adsense.site`. The page's own policy only gains `frame-src` of the ad origin.

The stand-in is as it was. Where a caller gives it a `wait` it closes an unfinished ad as `"none"` when it runs out, and it calls `onStart` and `onEnd`.

Only the page sees an ad: Google's ads for the web tell no server one was watched, so what a reward gives away the app's database bounds.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-ads . [<module-path>]   # ads/ads.js unless named
# name the publisher in ads_spec.cue
./saytw generate && ./saytw lint
```

The ad service is a cluster target (`ads_plugin.cue`) the release must route: `services: ads: {port: 8700, host: <the ad origin's name>}` in the app's `release.cue`, and a DNS record for that name. The installer is [`install.ts`](install.ts); the app's files come from [`app/`](app). It refuses a directory that is no pronto app, and a path out of the app. There is no skill for this plugin. The [root README](../README.md#pronto-ads) has the rest.

## Tests

[`install_test.ts`](install_test.ts) runs the installer on a temporary app: the module, the generate step, the CUE, the service and the spec are written, again over an edit, and the spec and `ads_site.js` only once.

```sh
deno lint --no-config ads && deno test --no-config --allow-read --allow-write --allow-run ads
```

The adapter, the service, the policy and the splice are cases in [`tests/unit/ads.cue`](../tests/unit/ads.cue) (suite `ads`, [`ads.js`](../tests/unit/ads.js)): the adapter on a fake frame and clock, the service on the document the app's CUE makes, the splice by running `ads.nu` on a stand-in door. Nothing calls Google.

```sh
UNIT_ALL=1 deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- ads
```
