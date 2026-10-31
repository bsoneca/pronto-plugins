// The unit cases as data, run by tests/unit.ts under the `test` verb: each a list of steps on one
// running value, as the online scenarios are steps on a page (tests/scenarios/schema.cue). A
// step calls a function of the app's modules or of probes.js, reads a field of the value, or
// checks it; a case passes when every check does. Strings "$" (the value now) and "$name" (one a
// step kept, "$name.path" a field of it) stand for values in a call's arguments, at any depth.
package unit

// Which `test` check runs the case (program.cue): the app names its suites in suites.cue.
#Suite: string

cases: [Name=string]: #Case

#Case: {
	suite: #Suite
	steps: [#Step, ...#Step]
}

// A dotted path into the value: "state.white_ms", "0.san", "length".
#Path: string | int

#Step: {
	// Checks on the value after the step's own action, any of them.
	expect?: _
	near?: {value: number, within: number | *0.05}
	// Only what it names: an object's fields named, a list's elements one by one, the rest exactly.
	holds?: _
	// The value, as text, matching a regular expression.
	matches?: string
	// Why, when the check is not plain from the case's name.
	why?: string
	#Act
}

#Act: {call!: string, args?: [...], throws?: string} | // ns.fn of the registry (tests/unit.ts), awaited; or throwing, its message matching
	{get!: #Path} | // a field of the value
	{pick!: [...#Path]} | // fields of the value, as a list
	{filter!: #Path} | // the elements of the value whose field is set
	{map!: #Act} | // each element of the value through the act, "$" being the element
	{keep!: string} | // the value kept under a name, "$name" after
	{use!: string} | // a kept value made the value
	{value!: _} | // a literal made the value
	close({}) // a check of the value as it is
