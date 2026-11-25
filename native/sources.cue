// The JS every native host ships or runs, one file each, embedded here so android/ and ios/ read the same text: SES as
// the phones load it, the passkey bridge's two forms (the terminal's browser.js imports it, a host's battery runs it) and the
// battery's runner. Moving one of them changes both hosts' files, which their goldens then say.
@extern(embed)

package native

sources: {
	ses:      _ @embed(file="ses.umd.min.js", type=text)
	passkeys: _ @embed(file="passkeys.js", type=text)
	battery:  _ @embed(file="battery.js", type=text)
}
