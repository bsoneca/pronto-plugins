package drill

// Where the drill's server listens, and the journey of a customer buying: the run fails at the
// first step that does not answer as said.
probeTarget: url: "http://127.0.0.1:8787"
probes: {
	checkout: {
		note:  "A customer opens the shop, fills the cart and checks out."
		every: "5s"
		journey: [
			{name: "home", path: "/"},
			{name: "cart", method: "POST", path: "/cart", body: {item: "tea"}},
			{name: "checkout", method: "POST", path: "/checkout", expect: contains: "order"},
		]
	}
}
