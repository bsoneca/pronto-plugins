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

export default function mount() {
	if (added || optedOut || !config.website) return;
	added = true;
	const tag = document.createElement("script");
	tag.defer = true;
	tag.src = scriptURL(config.script);
	tag.dataset.websiteId = config.website;
	// Its reports go to the page's own origin, at the address Umami was configured to take them at,
	// not to one derived from the tracker's path.
	tag.dataset.hostUrl = location.origin;
	tag.dataset.doNotTrack = "true";
	tag.dataset.excludeSearch = "true";
	tag.dataset.excludeHash = "true";
	document.head.append(tag);
}
