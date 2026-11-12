// Sign-in in an in-app browser (PRONTO-448). An ad lands players in Instagram's, Facebook's,
// Messenger's or TikTok's own browser. Sign-in is a same-tab redirect throughout, never a popup, so
// it goes on there, except at a provider that refuses webviews (Google's 403 disallowed_useragent).
// There the broker's page offers the reader's own browser instead: an intent:// link on Android, the
// link to copy on iOS.
package unit

_ua: {
	instagramIos:     "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 357.0.0.25.101 (iPhone15,2; iOS 18_1; en_US; en; scale=3.00; 1179x2556; 662331578)"
	instagramAndroid: "Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.6668.100 Mobile Safari/537.36 Instagram 352.0.0.38.100 Android (34/14; 480dpi; 1080x2340; samsung; SM-S918B; dm3q; qcom; pt_BR; 650293128)"
	facebookIos:      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.37.108;FBBV/634164551;FBDV/iPhone14,5;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBID/phone;FBLC/pt_BR;FBOP/5]"
	facebookAndroid:  "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/128.0.6613.127 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/479.0.0.48.81;]"
	messengerIos:     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/458.0.0.38.108;FBBV/600000000;FBDV/iPhone13,2;FBMD/iPhone;FBSN/iOS;FBSV/17.4;FBSS/3;FBCR/;FBID/phone;FBLC/en_US;FBOP/5]"
	tiktokAndroid:    "Mozilla/5.0 (Linux; Android 12; SM-A525F Build/SP1A.210812.016; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.193 Mobile Safari/537.36 trill_340005 JsSdk/1.0 NetType/WIFI Channel/googleplay AppName/musical_ly app_version/34.0.5 ByteLocale/pt-BR ByteFullLocale/pt-BR Region/BR BytedanceWebview/d8a21c6"
	otherAndroidWv:   "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A.240305.019; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/122.0.6261.105 Mobile Safari/537.36"
	safariIos:        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
	chromeIos:        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 Mobile/15E148 Safari/604.1"
	chromeAndroid:    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.6723.102 Mobile Safari/537.36"
	chromeDesktop:    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
}

cases: {
	"an in-app browser is known by its user agent, and a browser of its own is none": {suite: "identity", steps: [
		{call: "idcore.webviewOf", args: [_ua.instagramIos], expect: {app: "instagram", os: "ios"}},
		{call: "idcore.webviewOf", args: [_ua.instagramAndroid], expect: {app: "instagram", os: "android"}},
		{call: "idcore.webviewOf", args: [_ua.facebookIos], expect: {app: "facebook", os: "ios"}},
		{call: "idcore.webviewOf", args: [_ua.facebookAndroid], expect: {app: "facebook", os: "android"}},
		{call: "idcore.webviewOf", args: [_ua.messengerIos], expect: {app: "messenger", os: "ios"}, why: "FBAN/MessengerForiOS, before Facebook's own FBAN"},
		{call: "idcore.webviewOf", args: [_ua.tiktokAndroid], expect: {app: "tiktok", os: "android"}},
		{call: "idcore.webviewOf", args: [_ua.otherAndroidWv], expect: {app: "webview", os: "android"}, why: "any other Android webview says wv"},
		{call: "idcore.webviewOf", args: [_ua.safariIos], expect: null},
		{call: "idcore.webviewOf", args: [_ua.chromeIos], expect: null, why: "Chrome on iOS is WebKit, and a browser"},
		{call: "idcore.webviewOf", args: [_ua.chromeAndroid], expect: null},
		{call: "idcore.webviewOf", args: [_ua.chromeDesktop], expect: null},
		{call: "idcore.webviewOf", args: [""], expect: null, why: "no user agent: a browser, as before"},
	]}
	"a provider that refuses webviews sends a webview to the reader's own browser; any other stays a redirect": {suite: "identity", steps: [
		{call: "idcore.signInFlow", args: [_ua.instagramIos, {refusesWebviews: true}], expect: "open-in-browser"},
		{call: "idcore.signInFlow", args: [_ua.tiktokAndroid, {refusesWebviews: true}], expect: "open-in-browser"},
		{call: "idcore.signInFlow", args: [_ua.safariIos, {refusesWebviews: true}], expect: "redirect"},
		{call: "idcore.signInFlow", args: [_ua.chromeAndroid, {refusesWebviews: true}], expect: "redirect"},
		{call: "idcore.signInFlow", args: [_ua.instagramIos, {}], expect: "redirect", why: "the phone's page works in a webview"},
	]}
	"the reader's own browser starts the same sign-in at the tenant, and Android's link opens it there": {suite: "identity", steps: [
		{call: "idcore.startOf", args: ["https://bonkchess.com", "google"], expect: "https://bonkchess.com/auth/oidc/google/start?return=%2F"},
		{call: "idcore.intentOf", args: ["https://bonkchess.com/auth/oidc/google/start?return=%2F"], expect: "intent://bonkchess.com/auth/oidc/google/start?return=%2F#Intent;scheme=https;action=android.intent.action.VIEW;S.browser_fallback_url=https%3A%2F%2Fbonkchess.com%2Fauth%2Foidc%2Fgoogle%2Fstart%3Freturn%3D%252F;end"},
	]}
	"Google in Instagram's browser: the broker's page offers the reader's own browser, never a popup": {suite: "identity", steps: [
		{call: "identity.webviewSignIn", args: [_ua.instagramAndroid]}, {keep: "android"},
		{get: "step", expect: "open-in-browser"},
		{use: "android"}, {get: "link", matches: "^intent://app\\.example\\.com/auth/oidc/google/start\\?return=%2F#Intent;scheme=https;"},
		{use: "android"}, {get: "popup", expect: false},
		{call: "identity.webviewSignIn", args: [_ua.instagramIos]}, {keep: "ios"},
		{get: "step", expect: "open-in-browser"},
		{use: "ios"}, {get: "link", expect: "https://app.example.com/auth/oidc/google/start?return=%2F", why: "the link to copy into Safari"},
	]}
	"a webview signs in through the same-tab redirect where the provider admits it, and comes back to the tenant signed in": {suite: "identity", steps: [
		{call: "identity.webviewSignIn", args: [_ua.instagramIos, false]}, {keep: "out"},
		{get: "step", expect: "continue"},
		{use: "out"}, {get: "back", expect: "https://app.example.com/auth/oidc/google/callback", why: "the tenant's callback, which returns to the page the reader left"},
		{use: "out"}, {get: "state", expect: "S1", why: "the tenant's own state, kept"},
		{use: "out"}, {get: "signedIn", expect: true},
		{use: "out"}, {get: "popup", expect: false},
	]}
	"Safari goes on to Google as before": {suite: "identity", steps: [
		{call: "identity.webviewSignIn", args: [_ua.safariIos]}, {keep: "out"},
		{get: "step", expect: "continue"},
		{use: "out"}, {get: "signedIn", expect: true},
	]}
}
