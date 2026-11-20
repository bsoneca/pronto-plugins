package unit

// pronto-ads: Google's rewarded ads in an ad document of their own (PRONTO-1044). The page's adapter
// (ads/app/ads.js) is run on a fake frame and a clock a case advances, the document's service
// (ads/app/server.ts) on the document the app's CUE makes of a publisher, and the generate step's Caddyfile splice
// (ads/app/ads.nu) on a stand-in door. Nothing calls Google or the network. The page tells the frame
// {type: "pronto-ads", v: 1, op: "break" | "show", id, name}; the frame tells the page {type, v, id,
// event, breakStatus?} (ads/README.md).

// A frame's events, as the adapter reads them: the ready the bridge sends once Google's library is up, and the
// break's own.
let _ready = {frame: {event: "ready", id: null}}
let _start = {frame: {event: "beforeReward"}}

cases: "an ad viewed to its end is viewed, and the sound is given back": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start, {frame: {event: "beforeAd"}}, {frame: {event: "adViewed"}}, {frame: {event: "afterAd"}}, {frame: {event: "done", breakStatus: "viewed"}}]}]},
		{keep: "r", holds: {result: "viewed", audio: ["start", "end"], pending: false}, why: "beforeReward, beforeAd, adViewed, afterAd, done: the player watched it"},
		{get: "hidden", expect: true, why: "the frame leaves the page again"},
	]
}
cases: "an ad dismissed before its end is dismissed": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start, {frame: {event: "beforeAd"}}, {frame: {event: "adDismissed"}}, {frame: {event: "afterAd"}}, {frame: {event: "done", breakStatus: "dismissed"}}]}]},
		{keep: "r", holds: {result: "dismissed", audio: ["start", "end"]}},
	]
}
cases: "what Google recorded of the ad wins over the break's status": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start, {frame: {event: "adViewed"}}, {frame: {event: "done", breakStatus: "dismissed"}}]}]},
		{get: "result", expect: "viewed"},
	]
}
cases: "a break that ends with any other status is none": {
	suite: "ads"
	steps: [
		{call: "ads.endedBy", args: [["notReady", "timeout", "error", "noAdPreloaded", "frequencyCapped", "ignored", "other", "invalid", ""]]},
		{keep: "r", expect: ["none", "none", "none", "none", "none", "none", "none", "none", "none"], why: "no ad, a failure of Google's, or no word: none, never a reward"},
	]
}
cases: "a break whose done says viewed, and nothing before, is viewed": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, {frame: {event: "done", breakStatus: "viewed"}}]}]},
		{keep: "r", holds: {result: "viewed", ops: ["break"]}},
	]
}
cases: "an event of an ad that never started, bar its end, changes nothing": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, {frame: {event: "adViewed"}}, {frame: {event: "beforeAd"}}, {mark: "after"}, {tick: 15}]}]},
		{keep: "r", holds: {marks: {after: {pending: true}}, result: "none", audio: [], ops: ["break"]}, why: "no beforeReward: no show, no mute, and the wait ends it"},
	]
}

cases: "the page tells the frame to show the ad only once the frame covers the page": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start]}]},
		{keep: "r", holds: {ops: ["break", "show"], expandedAt: [false, true], pending: true}, why: "break goes to a frame that is off screen; show goes to one that is the whole viewport"},
		{get: "targets", expect: ["https://ads.bonkchess.com"], why: "to the ad origin, never *"},
	]
}
cases: "a break asked before the bridge is ready goes when it is": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [{mark: "before"}, {tick: 2}, _ready, {mark: "after"}]}]},
		{keep: "r", holds: {marks: {before: {ops: []}, after: {ops: ["break"]}}}},
	]
}
cases: "an ad that does not start within the wait is none, and a late event is ignored": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, {tick: 14}, {mark: "waiting"}, {tick: 2}, {mark: "waited"}, _start, {frame: {event: "done", breakStatus: "viewed"}}]}]},
		{keep: "r", holds: {marks: {waiting: {pending: true}, waited: {pending: false}}, result: "none", ops: ["break"], hidden: true}, why: "none at 15 s; the start that comes after finds no break in flight, and no show goes out"},
	]
}
cases: "the wait is the caller's": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{opts: {wait: 3}, script: [_ready, {tick: 2.9}, {mark: "waiting"}, {tick: 0.2}]}]},
		{keep: "r", holds: {marks: {waiting: {pending: true}}, result: "none"}},
	]
}
cases: "the wait ends when the ad starts: an ad that plays for a long time is still viewed": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, {tick: 1}, _start, {tick: 40}, {mark: "playing"}, {frame: {event: "adViewed"}}, {frame: {event: "done", breakStatus: "viewed"}}]}]},
		{keep: "r", holds: {marks: {playing: {pending: true}}, result: "viewed"}, why: "past 15 s, a done at 41 s still counts"},
	]
}
cases: "an ad that started and never ends is none after 180 seconds, with the sound back": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start, {frame: {event: "beforeAd"}}, {tick: 179}, {mark: "playing"}, {tick: 2}, {frame: {event: "done", breakStatus: "viewed"}}]}]},
		{keep: "r", holds: {marks: {playing: {pending: true}}, result: "none", audio: ["start", "end"], hidden: true}, why: "a done that comes at 181 s is late"},
	]
}
cases: "a break with a name that is none of the contract's is refused": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{opts: {name: "other"}, script: [_ready]}]},
		{keep: "r", holds: {error: "rewarded: name is one of purse, review", result: null, ops: []}},
	]
}
cases: "a review's break goes to the same frame as a purse's": {
	suite: "ads"
	steps: [
		{call: "ads.play", args: [{script: [_ready, _start, {frame: {event: "beforeAd"}}], opts: {name: "review"}}]},
		{get: "targets", expect: ["https://ads.bonkchess.com"], why: "a review's break goes the same way"},
	]
}

// A message that is none of the contract's is dropped, whatever it would have done: the origin, the
// source, the type, the version, the break, the event and the status are each held, and Google's own
// messages to the page pass through the same frame.
cases: "a message in the contract is taken, as the control of those that are not": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{}]},
		{keep: "r", holds: {after: {pending: false, ops: ["break", "show"]}, final: "viewed"}},
	]
}
cases: "a message from another origin is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{as: {origin: "https://evil.example"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message from the ad origin's lookalike is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{as: {origin: "https://ads.bonkchess.com.evil.example"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message from a window that is not the frame is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{as: {source: "other"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message of another type is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {type: "ad"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message of another version is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {v: 2}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message for a break that is not in flight is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {id: "b0"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message with no break is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {id: null}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "an event that is not in the contract is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {event: "adSkipped"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a status that is no short string is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{frame: {breakStatus: 7}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
		{call: "ads.dropped", args: [{frame: {breakStatus: "viewedviewedviewedviewedviewedviewed"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}, why: "viewed, but of more than 32 characters"},
	]
}
cases: "Google's own message to the page is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{data: {googMsgType: "register_iframe_window_action", id: "b1"}}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}
cases: "a message that is no object is dropped": {
	suite: "ads"
	steps: [
		{call: "ads.dropped", args: [{data: "viewed"}]},
		{keep: "r", holds: {after: {pending: true, ops: ["break"]}, final: "none"}},
	]
}

// Which ads play, and what the page makes for them.
cases: "ads are Google's only on the app's own origin, and test ads only on request": {
	suite: "ads"
	steps: [
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "https://ads.bonkchess.com", origin: "https://bonkchess.com", search: ""}]},
		{keep: "r", expect: "google"},
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "https://ads.bonkchess.com", origin: "https://bonkchess.com", search: "?ads=google-test"}]},
		{keep: "r", expect: "google-test"},
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "https://ads.bonkchess.com", origin: "https://bonkchess.com", search: "?ads=google"}]},
		{keep: "r", expect: "google", why: "any other value asks nothing"},
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "https://ads.bonkchess.com", origin: "https://preview.bonkchess.com", search: ""}]},
		{keep: "r", expect: "stand-in", why: "a preview, ci or a machine of the developer's keeps the stand-in"},
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "https://ads.bonkchess.com", origin: "https://preview.bonkchess.com", search: "?ads=google-test"}]},
		{keep: "r", expect: "stand-in", why: "test ads are not asked for off the app's origin: the door admits only production's ad origin"},
		{call: "ads.mode", args: [{site: "", frame: "", origin: "https://bonkchess.com", search: ""}]},
		{keep: "r", expect: "stand-in", why: "an app that names no publisher has no origins"},
		{call: "ads.mode", args: [{site: "https://bonkchess.com", frame: "", origin: "https://bonkchess.com", search: ""}]},
		{keep: "r", expect: "stand-in"},
	]
}
cases: "the ad document's address asks for test ads only in the test mode": {
	suite: "ads"
	steps: [
		{call: "ads.frameUrl", args: ["https://ads.bonkchess.com", false]},
		{keep: "r", expect: "https://ads.bonkchess.com/break"},
		{call: "ads.frameUrl", args: ["https://ads.bonkchess.com", true]},
		{keep: "r", expect: "https://ads.bonkchess.com/break?test=on"},
	]
}
cases: "prepare makes the frame once, hidden, in a sandbox that cannot navigate the page": {
	suite: "ads"
	steps: [
		{call: "ads.prepared", args: [{}]},
		{keep: "r", holds: {created: ["iframe"], listeners: 1, src: "https://ads.bonkchess.com/break", title: "Ad", hidden: true}, why: "called twice, made once; live ads on the app's origin"},
		{get: "attrs.allow", expect: "autoplay"},
		{use: "r"},
		{get: "attrs.sandbox", matches: "^allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox$", why: "no allow-top-navigation"},
	]
}
cases: "prepare asks for test ads on the app's origin with ?ads=google-test": {
	suite: "ads"
	steps: [
		{call: "ads.prepared", args: [{search: "?ads=google-test"}]},
		{get: "src", expect: "https://ads.bonkchess.com/break?test=on"},
	]
}
cases: "prepare makes nothing off the app's origin": {
	suite: "ads"
	steps: [
		{call: "ads.prepared", args: [{origin: "https://preview.bonkchess.com", search: "?ads=google-test"}]},
		{keep: "r", holds: {created: [], listeners: 0, src: null}},
	]
}
cases: "off the app's origin the ad is the stand-in, unchanged, and Google is not asked": {
	suite: "ads"
	steps: [
		{call: "ads.standIn", args: [{opts: {seconds: 2}, clicks: [{press: "close"}]}]},
		{keep: "r", holds: {dialog: "stand-in", opened: true, result: "dismissed", created: [], posted: 0, removed: true}, why: "closed before its end: dismissed; no frame, no message"},
		{call: "ads.standIn", args: [{opts: {seconds: 2}, clicks: [{after: 2}, {press: "reward"}]}]},
		{keep: "r", holds: {result: "viewed", created: []}, why: "played to its end, rewarded at a press"},
		{call: "ads.standIn", args: [{opts: {seconds: 2}, origin: "https://bonkchess.com", site: "", frame: ""}]},
		{keep: "r", holds: {dialog: "stand-in", created: []}, why: "on the app's origin, but no ad document named"},
	]
}
cases: "a stand-in the caller gave a wait to is none when it runs out, and brackets the sound": {
	suite: "ads"
	steps: [
		{call: "ads.standIn", args: [{opts: {seconds: 30, wait: 3}, clicks: [{after: 3}]}]},
		{keep: "r", holds: {result: "none", audio: ["start", "end"], removed: true}},
		{call: "ads.standIn", args: [{opts: {seconds: 30}, clicks: [{after: 60}]}]},
		{keep: "r", holds: {result: null, audio: ["start"]}, why: "no wait given, none taken: as before"},
	]
}
cases: "the page's module has no Google in it": {
	suite: "ads"
	steps: [
		{call: "ads.shellIsClean"},
		{keep: "r", expect: {google: false, script: false, trustedTypes: false, evalLike: false}, why: "no Google host, no script element, no Trusted Types policy"},
		{call: "ads.play", args: [{script: [_ready, _start]}]},
		{get: "created", expect: ["iframe"], why: "a page that plays a Google ad makes a frame and nothing else"},
	]
}

// The ad document and its policy, as the app's CUE makes them and its service answers them.
cases: "the ad document's policy holds the document to one inline script and Google's paths": {
	suite: "ads"
	steps: [
		{call: "ads.page"},
		{call: "ads.posture", args: ["$"]},
		{keep: "r", holds: {
			names: ["default-src", "base-uri", "object-src", "form-action", "script-src", "frame-src", "connect-src", "img-src", "style-src", "frame-ancestors"]
			defaultSrc: ["'none'"]
			scriptSources: 3
			hashMatches: true
			scripts: 1
			inlineScripts: 1
			scriptPathScoped: true
			scriptUnsafe: false
			sandbox: false
			trustedTypes: false
			httpsOnly: true
		}, why: "the hash is that of the one inline script, measured here; the two others are paths; nothing unsafe, no sandbox, no Trusted Types"},
		{get: "frameAncestors", expect: ["https://bonkchess.com"], why: "the game's own origin alone may frame it"},
	]
}
cases: "frame-ancestors is the site the spec names": {
	suite: "ads"
	steps: [
		{call: "ads.page"},
		{keep: "page"},
		{call: "ads.posture", args: ["$page"]},
		{get: "frameAncestors.0", expect: "$page.site"},
	]
}
cases: "no Google host that serves scripts under any path of its own is a script source": {
	suite: "ads"
	steps: [
		{call: "ads.auditReal", args: [{deny: ["www.google.com", "googleadservices.com", "doubleclick.net", "googleapis.com", "gstatic.com"]}]},
		{keep: "r", expect: {denied: [], wholeHost: []}, why: "the real policy: none of the hosts with JSONP or a script host-wide, and no source a whole host"},
		{call: "ads.auditReal", args: [{deny: ["www.google.com", "googleadservices.com", "doubleclick.net", "googleapis.com", "gstatic.com"], extra: "https://www.google.com"}]},
		{get: "denied", expect: ["https://www.google.com"], why: "the check fails when www.google.com is a script source"},
		{call: "ads.auditReal", args: [{deny: ["www.google.com", "googleadservices.com", "doubleclick.net", "googleapis.com", "gstatic.com"], extra: "https://*.doubleclick.net"}]},
		{get: "denied", expect: ["https://*.doubleclick.net"], why: "or any name under doubleclick.net"},
		{call: "ads.auditReal", args: [{deny: ["www.google.com", "googleadservices.com", "doubleclick.net", "googleapis.com", "gstatic.com"], extra: "https://googleads.g.doubleclick.net/pagead/"}]},
		{get: "denied", expect: ["https://googleads.g.doubleclick.net/pagead/"], why: "a path does not make it right"},
		{call: "ads.auditReal", args: [{deny: ["googleapis.com"], extra: "https://pagead2.googlesyndication.com"}]},
		{get: "wholeHost", expect: ["https://pagead2.googlesyndication.com"], why: "and the check says a source with no path"},
	]
}
cases: "the service answers /break with the document and its policy": {
	suite: "ads"
	steps: [
		{call: "ads.page"},
		{keep: "page"},
		{call: "ads.served", args: [{path: "/break"}]},
		{keep: "r", holds: {
			status: 200
			headers: {
				"content-security-policy": "$page.csp"
				"content-type":            "text/html; charset=utf-8"
				"x-content-type-options":  "nosniff"
				"cache-control":           "no-cache"
			}
			body: "$page.document"
		}},
		{call: "ads.served", args: [{path: "/break?test=on"}]},
		{get: "status", expect: 200, why: "the query is the bridge's, not the service's"},
		{call: "ads.served", args: [{path: "/break", method: "HEAD"}]},
		{keep: "r", holds: {status: 200, headers: {"content-security-policy": "$page.csp"}, body: ""}},
		{call: "ads.served", args: [{path: "/break"}]},
		{get: "headers.x-frame-options", matches: "^undefined$", why: "no X-Frame-Options, which could name no other origin: the policy's frame-ancestors governs"},
		{call: "ads.served", args: [{path: "/break", method: "POST"}]},
		{keep: "r", holds: {status: 405, headers: {"content-security-policy": "default-src 'none'"}}},
	]
}
cases: "every other path is a 404 that loads nothing": {
	suite: "ads"
	steps: [
		{call: "ads.served", args: [{path: "/"}]},
		{keep: "r", holds: {status: 404, headers: {"content-security-policy": "default-src 'none'"}}},
		{call: "ads.served", args: [{path: "/break/"}]},
		{get: "status", expect: 404},
		{call: "ads.served", args: [{path: "/break.html"}]},
		{get: "status", expect: 404},
		{call: "ads.served", args: [{path: "//break"}]},
		{get: "status", expect: 404},
		{call: "ads.served", args: [{path: "/ads.txt"}]},
		{keep: "r", holds: {status: 404, headers: {"content-security-policy": "default-src 'none'"}}},
		{call: "ads.served", args: [{path: "/Break"}]},
		{get: "status", expect: 404},
		{call: "ads.served", args: [{path: "/break.json"}]},
		{get: "body", expect: "not found", why: "the generated file is not served"},
	]
}
cases: "the service is healthy at /health": {
	suite: "ads"
	steps: [
		{call: "ads.served", args: [{path: "/health"}]},
		{keep: "r", holds: {status: 200, body: "ok", headers: {"content-security-policy": "default-src 'none'"}}},
	]
}

// What the spec makes of a publisher, and of none.
cases: "an app that names no publisher makes no ad document, no frame source and no service": {
	suite: "ads"
	steps: [
		{call: "ads.bare"},
		{keep: "r", holds: {resources: null, targets: null}},
		{get: "adsense", expect: {publisher: "", site: "", frame: ""}},
	]
}
cases: "an app that names a publisher gets the frame source of the ad origin and a service": {
	suite: "ads"
	steps: [
		{call: "ads.named"},
		{get: "resources", expect: {adsFrame: {kind: "frame", source: "https://ads.bonkchess.com", note: "the ad document, which Google's ads play in (pronto-ads): its own origin, so no Google script runs in the game's"}}, why: "core's resources: the one more frame-src of the game's policy, nothing else of it"},
		{call: "ads.named"},
		{get: "targets", expect: ["ads"]},
		{call: "ads.named"},
		{get: "target.srcs.globs", expect: ["ads/server.ts", "ads/break.json"]},
		{call: "ads.named"},
		{get: "target.expose.http", expect: {port: 8700, env: "ADS_PORT"}},
	]
}
cases: "a publisher without the origins its ads play at is refused": {
	suite: "ads"
	steps: [
		{call: "ads.refused", args: [{site: "", frame: "https://ads.bonkchess.com"}]},
		{keep: "r", expect: "refused"},
		{call: "ads.refused", args: [{site: "https://bonkchess.com", frame: ""}]},
		{keep: "r", expect: "refused"},
		{call: "ads.refused", args: [{site: "http://bonkchess.com", frame: "https://ads.bonkchess.com"}]},
		{keep: "r", expect: "refused", why: "an origin is https"},
	]
}

// The generate step, on a door of a stand-in's: what it adds to the Caddyfile, and the files it writes.
cases: "with no publisher the step leaves the Caddyfile as it was, and the page with no origins": {
	suite: "ads"
	steps: [
		{call: "ads.caddyfile", args: ["plain"]},
		{keep: "plain"},
		{call: "ads.route", args: [[{caddy: "plain", publisher: false}]]},
		{keep: "r", holds: [{exit: 0, caddy: "$plain", brk: null}], why: "byte for byte: no frame-ancestors, no X-Frame-Options, no /ads.txt"},
	]
}
cases: "the step names no origin to a page that names no publisher": {
	suite: "ads"
	steps: [
		{call: "ads.route", args: [[{caddy: "plain", publisher: false}]]},
		{get: "0.site"},
		{call: "ads.siteOf", args: ["$"]},
		{keep: "r", expect: {site: "", frame: ""}},
	]
}
cases: "with a publisher the step adds frame-ancestors 'self' and X-Frame-Options, and nothing else of the policy": {
	suite: "ads"
	steps: [
		{call: "ads.route", args: [[{caddy: "plain", publisher: true}]]},
		{get: "0.caddy"},
		{call: "ads.against", args: ["$"]},
		{keep: "r", expect: {removed: ["  header @terminal Content-Security-Policy \"default-src 'self'; script-src 'self'; frame-src 'self'\""], policyIsOriginalPlusFrameAncestors: true, frameAncestors: 1, xFrameOptions: 1, adsTxt: true}, why: "the policy line is the old one and `; frame-ancestors 'self'`; the docs policy keeps its own"},
	]
}
cases: "the step writes the ad document, and the origins to the page's module folder": {
	suite: "ads"
	steps: [
		{call: "ads.route", args: [[{caddy: "plain", publisher: true}]]},
		{keep: "run"},
		{get: "0.exit", expect: 0},
		{use: "run"},
		{get: "0.site"},
		{call: "ads.siteOf", args: ["$"]},
		{keep: "r", expect: {site: "https://bonkchess.com", frame: "https://ads.bonkchess.com"}},
		{use: "run"},
		{get: "0.brk", matches: "\"csp\": \"default-src 'none'; "},
		{use: "run"},
		{get: "0.brk", matches: "<script>\\(function"},
	]
}
cases: "the step again changes nothing, and with no publisher again takes its addition out": {
	suite: "ads"
	steps: [
		{call: "ads.caddyfile", args: ["plain"]},
		{keep: "plain"},
		{call: "ads.route", args: [[{caddy: "plain", publisher: true}, {publisher: true}, {publisher: false}]]},
		{keep: "run"},
		{get: "0.exit", expect: 0},
		{use: "run"},
		{get: "1.caddy", expect: "$run.0.caddy", why: "a second run adds nothing: no second frame-ancestors, no second X-Frame-Options"},
		{use: "run"},
		{get: "1.brk", expect: "$run.0.brk"},
		{use: "run"},
		{get: "2.caddy", expect: "$plain", why: "the app drops its publisher: the door is as pronto wrote it"},
		{use: "run"},
		{get: "2.brk", matches: "^null$", why: "and the ad document is gone"},
	]
}
cases: "the step fails where it cannot place the policy once, or pronto has done it": {
	suite: "ads"
	steps: [
		{call: "ads.route", args: [[{caddy: "twice", publisher: true}]]},
		{keep: "r", holds: [{failed: true, complained: true}], why: "two policy lines: which?"},
		{call: "ads.route", args: [[{caddy: "ancestors", publisher: true}]]},
		{keep: "r", holds: [{failed: true, complained: true}], why: "the door's policy already says who may frame it: pronto's, and the splice is to go"},
		{get: "0.caddy", matches: "frame-ancestors 'none'\""},
	]
}
