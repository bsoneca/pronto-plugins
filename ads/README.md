# ads

Rewarded ads for a pronto app: an ad a player chooses to watch for something the app gives in return, never one that interrupts them.

## What it adds

- `ads/ads.js` (or the path you name): a page module exporting `rewarded()`. It resolves `"viewed"` when the ad played to its end, `"dismissed"` when it was closed before, and `"none"` when there is no ad to show. `prepare()` loads Google's script ahead, where the page knows an ad may soon be offered.
- `ads_spec.js` beside it: the publisher the module reads, rewritten by every generate.
- A generate step that gives the door `/ads.txt` again after pronto's writer, carrying the AdSense publisher's line, and writes `ads_spec.js`.
- `ads_spec.cue`, written once and then the app's: `adsense: publisher: "pub-…"`, or `""` for none.

With a publisher named, `rewarded()` is Google's rewarded ad: the [Ad Placement API](https://developers.google.com/ad-placement) (H5 Games Ads) behind `adBreak({type: 'reward'})`, which the player's own press asked for, so `beforeReward` shows it at once. `adViewed` is `"viewed"`, `adDismissed` `"dismissed"`, and every other `breakStatus` (`notReady`, `timeout`, `noAdPreloaded`, `frequencyCapped`, `error`, `other`) is `"none"`, as is a script refused (an ad blocker, a door that does not admit Google) or silent for ten seconds. On `localhost` the script carries `data-adbreak-test="on"`, Google's test ads. The script loads at the first `rewarded()` or `prepare()`, never at import, so a page that never offers an ad (a subscriber's) never loads Google. With no publisher, `rewarded()` is a stand-in that plays at a press.

The page alone knows an ad was watched, so whatever a reward gives away, the app's database bounds.

H5 Games Ads is its own AdSense product: the publisher's account must be enrolled in it, and the site added and approved, before Google fills a rewarded break; until then every break is `"none"`.

## The door

Google's ads run in the page, so the door's Content-Security-Policy must admit them. The module inserts its script under a Trusted Types policy named `pronto-ads`, and Google's script loads more of itself and draws in frames. What a page with Google's rewarded test ad reached (Chrome, November 2026); a filled live ad draws its creative from more of Google's hosts, `https://tpc.googlesyndication.com` and `https://*.safeframe.googlesyndication.com` among them, so a policy admits each directive's hosts by wildcard:

| Directive | Seen with the test ad |
| --- | --- |
| `script-src` | `https://pagead2.googlesyndication.com`, `https://ep2.adtrafficquality.google` |
| `frame-src` | `https://googleads.g.doubleclick.net`, `https://ep2.adtrafficquality.google`, `https://www.google.com` |
| `connect-src` | `https://pagead2.googlesyndication.com`, `https://ep1.adtrafficquality.google` |
| `img-src` | `https://pagead2.googlesyndication.com`, `https://ep1.adtrafficquality.google`, `https://ep2.adtrafficquality.google` |
| `trusted-types` | `pronto-ads`, and whatever policies Google's script creates |

pronto's door does not admit these yet: a pronto app's `script-src` and `trusted-types` are the terminal's, and `capabilities.resources` names one origin each, with no wildcard. Under that door `rewarded()` resolves `"none"` with no request to Google.

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-ads . [<module-path>]   # ads/ads.js unless named
# name the publisher in ads_spec.cue
./saytw generate && ./saytw lint
```

The installer is [`install.ts`](install.ts); the app's files come from [`app/`](app). It refuses a directory that is no pronto app, and a path out of the app. There is no skill for this plugin. The [root README](../README.md#pronto-ads) has the rest.

## Tests

[`install_test.ts`](install_test.ts) runs the installer on a temporary app: the module and the generate step are written, again over an edit, and the app's spec and the module's only once.

```sh
deno lint --no-config ads && deno test --no-config --allow-read --allow-write --allow-run ads
```
