// integrate@android's emulator starter's pure rules (android/template/terminal/emulator.ts): which console
// port it takes, the AVD's name and the emulator's arguments.
package unit

cases: {
	"the emulator takes the first even console port from 5554 that nothing uses": {suite: "android", steps: [
		{call: "androidEmulator.emulatorPort", args: [[]], expect: 5554},
		{call: "androidEmulator.emulatorPort", args: [[5554, 5555]], expect: 5556, why: "the console and adb ports of the first are taken"},
		{call: "androidEmulator.emulatorPort", args: [[5555]], expect: 5556, why: "a device on the adb port of 5554 takes that pair"},
	]}
	"the AVD is named by its port, so two emulators never share a disk": {suite: "android", steps: [
		{call: "androidEmulator.avdName", args: [5556], expect: "pronto-5556"},
	]}
	"the emulator starts headless, saves no snapshot and listens on its port": {suite: "android", steps: [
		{call: "androidEmulator.emulatorArgs", args: ["pronto-5556", 5556], matches: "-avd,pronto-5556,-port,5556,"},
		{call: "androidEmulator.emulatorArgs", args: ["pronto-5556", 5556], matches: "-no-window"},
		{call: "androidEmulator.emulatorArgs", args: ["pronto-5556", 5556], matches: "-no-snapshot-save"},
	]}
}
