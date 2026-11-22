package identity

import "list"

// The phone sign-in's numbers, written once (PRONTO-607): the broker's code lifetime, tries, resend wait, channels, countries and the
// caps its gate holds. `cue export ./identity -e phone --out json` writes identity/broker/phone_spec.json, which the broker reads
// (broker/otp.ts, broker/phone.ts); ci fails when the committed file differs from the export, and a unit case holds the two together.
// Behaviour (the codes, the page, the gate's calls) stays code.
//
//   cue export ./identity -e phone --out json > identity/broker/phone_spec.json
phone: #Phone & {
	// How long a code is good, in seconds.
	ttl_s: 300
	// Wrong tries before the code is dead, the right one included.
	tries: 5
	// Seconds before a number is sent a code again (PHONE_RESEND_SECONDS overrides it).
	resend_s: 60
	// How a code leaves, in the order the broker tries: the first send is WhatsApp, and after the resend wait the person may choose SMS.
	// A channel with no sender configured is skipped (a deployment with only an SMS provider sends by SMS alone).
	channels: ["whatsapp", "sms"]
	// The countries a number may belong to (ISO 3166-1 alpha-2). A number of any other country is refused with the same answer as any
	// other refused number. The first is the country a number typed without one belongs to.
	countries: ["BR"]
	// What the gate that admits each send holds (broker/phone.ts asks it; the gate itself is a later change): sends per number and per
	// network per hour, sends in all per day, and the spend in cents a day.
	caps: {
		per_phone_hour: 6
		per_ip_hour:    20
		global_day:     1000
		budget_cents:   5000
	}
	// The calling code of each country that may be listed.
	dial: {BR: "55"}
}

#Phone: {
	ttl_s:    int & >0
	tries:    int & >0
	resend_s: int & >0
	channels: [...("whatsapp" | "sms")] & list.MinItems(1)
	countries: [...string & =~"^[A-Z]{2}$"] & list.MinItems(1)
	caps: {
		per_phone_hour: int & >0
		per_ip_hour:    int & >0
		global_day:     int & >0
		budget_cents:   int & >=0
	}
	dial: {[string]: string & =~"^[0-9]{1,3}$"}
	// Every listed country has its calling code.
	for c in countries {dial: "\(c)": string}
}
