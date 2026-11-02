// The files every plugin that exports a value of the program writes into the app, from one source
// (exports.nu): pronto/exports.nu, which evaluates the program once for all their generate rules.
@extern(embed)
package common

exportsNu: _ @embed(file="exports.nu", type=text)
