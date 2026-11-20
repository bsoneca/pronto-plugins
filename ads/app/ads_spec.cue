package __PACKAGE__

// The app's AdSense publisher (pronto-ads), as AdSense names it: pub- and sixteen
// digits, or "" for none. Named, the door answers /ads.txt with the publisher's
// line, which AdSense reads to know the site is theirs.
adsense: publisher: *"" | =~"^pub-[0-9]{16}$"
// The origin real ads play at (the app's own, https, no path), and the origin of the ad
// document that plays them (a name of its own, a service the release routes straight to, never
// the door): both required once a publisher is named, and none while it is not. On any other
// origin (a preview, ci, a developer's machine) every ad is the stand-in.
adsense: site:  *"" | =~"^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$"
adsense: frame: *"" | =~"^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$"
