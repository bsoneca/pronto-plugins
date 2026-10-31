package __PACKAGE__

// The app's AdSense publisher (pronto-ads), as AdSense names it: pub- and sixteen
// digits, or "" for none. Named, the door answers /ads.txt with the publisher's
// line, which AdSense reads to know the site is theirs.
adsense: publisher: *"" | =~"^pub-[0-9]{16}$"
