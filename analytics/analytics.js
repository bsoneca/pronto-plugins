// pronto-analytics' loader: a host-DOM hatch on every screen that adds Umami's tracker to the
// page, once. Written by pronto-analytics; regenerated, do not edit.
//
// The tracker is a classic script, which the page's Trusted Types policy refuses to take from a
// string: its address passes through the terminal's own script-URL policy, which admits this
// origin alone, so the tracker is the door's (/a/s.js), never another host's, and its reports go
// back to the door (script-src and connect-src stay 'self'). Umami keeps no cookie. A browser that
// asks not to be tracked (Global Privacy Control, Do Not Track) loads nothing, and the tracker is
// told not to track on the same signal, and to drop the address's query.

import config from "./config.js";
import { scriptURL } from "/omnishell/interpreter/script-url.js";

const optedOut = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1";
let added = false;
let last = null;

// A pageview for the screen the reader is on, once for each address (its path alone: the query
// and the hash may hold a token or an ad's parameters). The terminal moves between screens by the
// Navigation API, which Umami's own watch of the History API does not see, so the pageviews are
// sent from here (data-auto-pageview is off) when the script has loaded and on each navigation.
const view = () => {
	const url = location.pathname;
	if (url === last || typeof globalThis.umami?.track !== "function") return;
	const from = last;
	last = url;
	globalThis.umami.track((props) => ({ ...props, url, referrer: from === null ? props.referrer : location.origin + from }));
};

const follow = () => {
	if (globalThis.navigation) {
		navigation.addEventListener("navigatesuccess", view);
		return;
	}
	for (const name of ["pushState", "replaceState"]) {
		const original = history[name];
		history[name] = function (...args) {
			const result = original.apply(this, args);
			queueMicrotask(view);
			return result;
		};
	}
	addEventListener("popstate", view);
};

// A host-DOM hatch is mounted on each screen and must answer with its cleanup. The tracker is the
// page's, not the screen's: it is added once and stays, so there is nothing to undo.
const nothing = () => {};

export default function mount() {
	if (added || optedOut || !config.website) return nothing;
	added = true;
	const tag = document.createElement("script");
	tag.defer = true;
	tag.src = scriptURL(config.script);
	tag.dataset.websiteId = config.website;
	// Its reports go to the page's own origin, at the address Umami was configured to take them at,
	// not to one derived from the tracker's path.
	tag.dataset.hostUrl = location.origin;
	tag.dataset.autoPageview = "false";
	tag.dataset.doNotTrack = "true";
	tag.dataset.excludeSearch = "true";
	tag.dataset.excludeHash = "true";
	tag.addEventListener("load", () => {
		view();
		follow();
	});
	document.head.append(tag);
	return nothing;
}
