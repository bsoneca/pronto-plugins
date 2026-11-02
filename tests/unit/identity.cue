// pronto-identity's installer (bin/pronto-identity): the front's image a local launch's broker
// runs is the operator's own, with no default, so an app that names none is refused before
// anything is written, saying what to name.
package unit

cases: {
	"a local broker with no front's image named is refused, and nothing is written": {suite: "identity", steps: [
		{call: "identity.installed"}, {keep: "out"},
		{get: "exit", expect: 2},
		{use: "out"}, {get: "said", matches: "frontImage=<registry>/pronto-identity:<version>@sha256:"},
		{use: "out"}, {get: "files", expect: ["program.cue"], why: "nothing written"},
	]}
	"the local broker named outright is refused alike: it is the default, and still needs its image": {suite: "identity", steps: [
		{call: "identity.installed", args: [["broker=http://localhost:28443"]]}, {keep: "out"},
		{get: "exit", expect: 2},
		{use: "out"}, {get: "said", matches: "there is no default"},
	]}
}

// The brokers release a person's e-mail only to a tenant that asked for `email`, and only an address
// Google says it verified: the production broker (broker/main.ts), the local one on Hydra
// (hydra/front.ts), and the stand-in for Google a developer's machine signs in with (hydra/fake.ts).
// A tenant asking `openid` or `openid profile` learns what it learned before.
_google: {name: "Ana Souza", picture: "https://lh3.googleusercontent.com/a/ana=s96-c", email: " ana@example.com ", email_verified: true}
cases: {
	"a tenant asking for email learns the verified address, and Google is asked for it": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid profile email", _google]}, {keep: "out"},
		{get: "asked", expect: "openid profile email"},
		{use: "out"}, {get: "learned", expect: {name: "Ana Souza", picture: "https://lh3.googleusercontent.com/a/ana=s96-c", email: "ana@example.com", email_verified: true}, why: "trimmed, and said verified"},
		{use: "out"}, {get: "says", matches: "It also learns your name and e-mail address\\."},
		{use: "out"}, {get: "scopes", expect: ["openid", "profile", "email"]},
	]}
	"an address Google did not verify is never released": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid email", {email: "ana@example.com", email_verified: false}]},
		{get: "learned", expect: {}},
	]}
	"an address Google sends without saying it verified it is never released": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid email", {email: "ana@example.com", email_verified: "true"}]},
		{get: "learned", expect: {}, why: "only the boolean true counts"},
	]}
	"an address that is not one is never released": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid email", {email: "not an address", email_verified: true}]},
		{get: "learned", expect: {}},
	]}
	"a tenant asking openid alone learns no more than before, and Google is asked for no more": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid", _google]}, {keep: "out"},
		{get: "asked", expect: "openid"},
		{use: "out"}, {get: "learned", expect: {}},
		{use: "out"}, {get: "says", matches: "any other app\\.$", why: "the page names nothing more"},
	]}
	"a tenant asking openid profile learns the name and picture, never the e-mail": {suite: "identity", steps: [
		{call: "identity.brokered", args: ["openid profile", _google]}, {keep: "out"},
		{get: "asked", expect: "openid profile"},
		{use: "out"}, {get: "learned", expect: {name: "Ana Souza", picture: "https://lh3.googleusercontent.com/a/ana=s96-c"}},
		{use: "out"}, {get: "says", matches: "any other app\\.$"},
	]}
	"the local broker on Hydra grants email to a tenant that asked, with the verified address": {suite: "identity", steps: [
		{call: "identity.hydraBrokered", args: ["openid profile email", _google]}, {keep: "out"},
		{get: "asked", expect: "openid profile email"},
		{use: "out"}, {get: "granted", expect: ["openid", "profile", "email"]},
		{use: "out"}, {get: "learned", expect: {name: "Ana Souza", picture: "https://lh3.googleusercontent.com/a/ana=s96-c", email: "ana@example.com", email_verified: true}},
		{use: "out"}, {get: "registered", expect: "openid profile email", why: "a tenant's client may ask for it"},
	]}
	"the local broker never grants an address Google did not verify": {suite: "identity", steps: [
		{call: "identity.hydraBrokered", args: ["openid email", {email: "ana@example.com", email_verified: false}]},
		{get: "learned", expect: {}},
	]}
	"the local broker gives a tenant asking openid profile what it gave before": {suite: "identity", steps: [
		{call: "identity.hydraBrokered", args: ["openid profile", _google]}, {keep: "out"},
		{get: "asked", expect: "openid profile"},
		{use: "out"}, {get: "granted", expect: ["openid", "profile"]},
		{use: "out"}, {get: "learned", expect: {name: "Ana Souza", picture: "https://lh3.googleusercontent.com/a/ana=s96-c"}},
	]}
	"the local broker gives a tenant asking openid alone a subject and nothing else": {suite: "identity", steps: [
		{call: "identity.hydraBrokered", args: ["openid", _google]}, {keep: "out"},
		{get: "asked", expect: "openid"},
		{use: "out"}, {get: "granted", expect: ["openid"]},
		{use: "out"}, {get: "learned", expect: {}},
	]}
	"the stand-in for Google answers email with a test address it says it verified": {suite: "identity", steps: [
		{call: "identity.fakeAnswers", args: ["openid profile email", "tester-2"], expect: {name: "Test tester-2", picture: "https://lh3.googleusercontent.com/a/fake-tester-2=s96-c", email: "tester-2@example.com", email_verified: true}},
	]}
	"the stand-in for Google answers no address unless asked": {suite: "identity", steps: [
		{call: "identity.fakeAnswers", args: ["openid profile"], expect: {name: "Test tester", picture: "https://lh3.googleusercontent.com/a/fake-tester=s96-c"}},
	]}
	"the installer writes the scope an app names, and keeps it on a refresh": {suite: "identity", steps: [
		{call: "identity.installed", args: [["broker=https://id.example.com", "scope=openid,profile,email"]]}, {keep: "out"},
		{get: "exit", expect: 0},
		{use: "out"}, {get: "scope", expect: "openid profile email"},
		{use: "out"}, {get: "signin"}, {keep: "signin"},
		{call: "identity.installed", args: [["broker=https://id.example.com"], "$signin"]},
		{get: "scope", expect: "openid profile email", why: "a refresh names no scope"},
	]}
	"the installer asks openid profile when the app names no scope": {suite: "identity", steps: [
		{call: "identity.installed", args: [["broker=https://id.example.com"]]},
		{get: "scope", expect: "openid profile"},
	]}
	"the installer refuses a scope the broker does not offer": {suite: "identity", steps: [
		{call: "identity.installed", args: [["broker=https://id.example.com", "scope=openid,phone"]]},
		{get: "exit", expect: 1, why: "cue export refuses it, before anything is written"},
	]}
}
cases: {
	"the stand-in for Google signs in a fresh test person a scenario names, never listing them": {suite: "identity", steps: [
		{call: "identity.fakeSignsIn", args: ["openid profile email", "tester-run-7f3a"]}, {keep: "out"},
		{get: "status", expect: 302},
		{use: "out"}, {get: "listed", expect: ["tester", "tester-2"]},
		{use: "out"}, {get: "learned", expect: {name: "Test tester-run-7f3a", picture: "https://lh3.googleusercontent.com/a/fake-tester-run-7f3a=s96-c", email: "tester-run-7f3a@example.com", email_verified: true}},
	]}
	"the stand-in for Google refuses a person outside the test people": {suite: "identity", steps: [
		{call: "identity.fakeSignsIn", args: ["openid profile email", "alice"]}, {keep: "out"},
		{get: "status", expect: 400},
		{use: "out"}, {get: "learned", expect: {}},
	]}
	"the stand-in for Google refuses a test person's name it would not mint": {suite: "identity", steps: [
		{call: "identity.fakeSignsIn", args: ["openid", "tester-Bad_Name"]},
		{get: "status", expect: 400},
	]}
}
