// The Android terminal's compiler (android/template/terminal/compile.js, css.js): a page of HTML
// and CSS on linkedom comes out as a DivKit card, and what has no peer on Android is listed.
// A page is built by android.render(body, css, {width, scheme, base}); its root view is `root`,
// the views of the page `items`, the form variables `vars`, the unsupported `whats`.
package unit

cases: {
	"what is hidden, closed or inert is not drawn": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<p>shown</p><p hidden>a</p><p style="display:none">b</p><p class="gone">c</p><p style="visibility:hidden">d</p>
			<template><p>t</p></template><script>x</script><style>p{}</style>
			<dialog><p>dlg</p></dialog><dialog open><p>open dlg</p></dialog>
			<div popover><p>pop</p></div><div popover data-popover-open><p>pop open</p></div>
			<input type="hidden" name="h" value="1">
			<details><summary>sum</summary><p>inner</p></details>
			<details open><summary>sum2</summary><p>inner2</p></details>
			"""#, ".gone { display: none }"]},
		{keep: "page"},
		{get: "root"},
		{call: "android.texts", args: ["$"]},
		{value: "$", expect: ["shown", "open dlg", "pop open", "▸ sum", "▾ sum2", "inner2"], why: "hidden, display:none by cascade, visibility:hidden, template, script, style, closed dialog and popover, a closed details' body: none drawn; a hidden input has no variable"},
		{use: "page"},
		{get: "vars", expect: {}},
	]}

	"specificity, order, !important and the style attribute decide the colour": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<p class="a">1</p><p class="a" id="x">2</p><p class="a b">3</p><p class="a" style="color:#666666">4</p><p class="a b" style="color:#777777 !important">5</p><p>6</p>
			"""#, #"""
			p { color: #111111; }
			p.a { color: #222222; }
			#x { color: #333333; }
			p.b { color: #444444 !important; }
			.b { color: #555555; }
			"""#]},
		{get: "items"},
		{map: {get: "text_color"}},
		{value: "$", expect: ["#FF222222", "#FF333333", "#FF444444", "#FF666666", "#FF777777", "#FF111111"]},
	]}

	"layers rank by first appearance and unlayered rules beat any layer": {suite: "android", steps: [
		{call: "android.render", args: [#"<p>a</p><p class="u">b</p>"#, #"""
			@layer base, theme;
			@layer theme { p { color: #0000ff; } }
			@layer base { p { color: #ff0000; font-size: 20px; } }
			p.u { font-size: 30px; }
			"""#]},
		{get: "items"},
		{pick: ["0.text_color", "0.font_size", "1.font_size"], expect: ["#FF0000FF", 20, 30]},
		{call: "android.render", args: [#"<p>a</p>"#, #"""
			@layer theme { p { color: #0000ff; } }
			@layer base { p { color: #ff0000; } }
			"""#]},
		{get: "items.0.text_color", expect: "#FFFF0000", why: "the layer met last wins when no order was declared"},
	]}

	"media queries read the width and the scheme; supports applies": {suite: "android", steps: [
		{call: "android.render", args: [#"<p>a</p>"#, #"""
			@media (min-width: 500px) { p { background: #00ff00; } }
			@media (max-width: 500px) { p { border: 1px solid #000000; } }
			@media (prefers-color-scheme: dark) { p { color: #abcdef; } }
			@media (prefers-reduced-motion: reduce) { p { color: #123456; } }
			@media (400px <= width <= 450px) and (hover: none) { p { margin-top: 7px; } }
			@supports (display: grid) { p { margin-bottom: 3px; } }
			"""#, {}]},
		{get: "items.0"},
		{value: "$", holds: {border: {stroke: {color: "#FF000000", width: 1}}, margins: {top: 7, bottom: 3}}},
		{pick: ["background", "text_color"], expect: [null, "#FF000000"], why: "min-width 500 is false at 411; the scheme is light; reduced motion is not asked for"},
		{call: "android.render", args: [#"<p>a</p>"#, "@media (min-width: 500px) { p { background: #00ff00; } } @media (prefers-color-scheme: dark) { p { color: #abcdef; } }", {width: 600, scheme: "dark"}]},
		{get: "items.0"},
		{value: "$", holds: {background: [{type: "solid", color: "#FF00FF00"}], text_color: "#FFABCDEF"}},
	]}

	"custom properties inherit, take a fallback, and an unknown one drops the declaration": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="card"><p class="inner">hi</p></div><p class="x">x</p>"#, #"""
			:root { --brand: #112233; --pad: 4px; }
			.card { --pad: 12px; padding: var(--pad); color: var(--brand); border-radius: var(--r, 6px); }
			.card .inner { padding: calc(var(--pad) * 2); margin-top: var(--missing, 3px); }
			.x { padding: var(--nope); margin: 5px; }
			"""#]},
		{keep: "page"},
		{get: "items.0"},
		{value: "$", holds: {paddings: {top: 12, left: 12}, border: {corner_radius: 6}, items: [{text: "hi", text_color: "#FF112233", paddings: {top: 24}, margins: {top: 3}}]}},
		{use: "page"},
		{get: "items.1"},
		{value: "$", holds: {margins: {top: 5}}},
		{pick: ["paddings"], expect: [null], why: "padding: var(--nope) is invalid at computed-value time, so it is unset"},
	]}

	"nesting, :is, :where and the source order among equal specificities": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="a"><p class="b">b</p><p class="c">c</p></div><p class="z">z</p>"#, #"""
			.a { color: #111111; & .b { color: #222222; } .c { color: #333333; } &:hover { color: #999999; } @media (min-width: 300px) { background: #010203; } }
			p.z:where(.z) { color: #aaaaaa; }
			p:where(.z) { color: #bbbbbb; }
			"""#]},
		{keep: "page"},
		{get: "items.0"},
		{value: "$", holds: {background: [{color: "#FF010203"}], items: [{text_color: "#FF222222"}, {text_color: "#FF333333"}]}},
		{use: "page"},
		{get: "items.1.text_color", expect: "#FFAAAAAA", why: "p.z:where(.z) weighs (0,1,1), p:where(.z) (0,0,1)"},
	]}

	"colours of every form the apps write come out as #AARRGGBB": {suite: "android", steps: [
		{call: "android.colour", args: ["#fff"], expect: "#FFFFFFFF"},
		{call: "android.colour", args: ["#11223344"], expect: "#44112233"},
		{call: "android.colour", args: ["rgb(0 0 0 / 50%)"], expect: "#80000000"},
		{call: "android.colour", args: ["rgba(255, 0, 0, .5)"], expect: "#80FF0000"},
		{call: "android.colour", args: ["hsl(120 100% 50%)"], expect: "#FF00FF00"},
		{call: "android.colour", args: ["hsl(220 3% 15% / 3%)"], expect: "#08252627"},
		{call: "android.colour", args: ["oklch(1 0 0)"], expect: "#FFFFFFFF"},
		{call: "android.colour", args: ["oklch(0 0 0)"], expect: "#FF000000"},
		{call: "android.colour", args: ["oklch(0.628 0.2577 29.23)"], expect: "#FFFF0000", why: "sRGB red in oklch"},
		{call: "android.colour", args: ["oklch(0.452 0.313 264.05)"], expect: "#FF0000FF", why: "sRGB blue in oklch"},
		{call: "android.colour", args: ["oklab(0.5 0 0)"], expect: "#FF636363"},
		{call: "android.colour", args: ["color-mix(in srgb, #ff0000 50%, #0000ff)"], expect: "#FF800080"},
		{call: "android.colour", args: ["color-mix(in oklab, white, black)"], expect: "#FF636363"},
		{call: "android.colour", args: ["color-mix(in srgb, #ff0000 25%, transparent)"], expect: "#40FF0000", why: "percentages short of 100 scale the alpha"},
		{call: "android.colour", args: ["transparent"], expect: "#00000000"},
		{call: "android.colour", args: ["red"], expect: "#FFFF0000"},
		{call: "android.colour", args: ["currentColor"], expect: "#FF336699"},
		{call: "android.colour", args: ["light-dark(#ffffff, #000000)", false], expect: "#FFFFFFFF"},
		{call: "android.colour", args: ["light-dark(#ffffff, #000000)", true], expect: "#FF000000"},
		{call: "android.colour", args: ["no-such-colour"], expect: null},
	]}

	"lengths in dp: rem, calc, min, max, clamp, viewport and percentage": {suite: "android", steps: [
		{call: "android.dp", args: ["1rem"], expect: 16},
		{call: "android.dp", args: ["-0.5rem"], expect: -8},
		{call: "android.dp", args: ["calc(1rem + 8px)"], expect: 24},
		{call: "android.dp", args: ["calc(100% - 2rem)"], expect: 168, why: "the basis is 200"},
		{call: "android.dp", args: ["calc(2 * 3px)"], expect: 6},
		{call: "android.dp", args: ["calc(10px / 4)"], expect: 2.5},
		{call: "android.dp", args: ["clamp(1rem, 2rem, 3rem)"], expect: 32},
		{call: "android.dp", args: ["clamp(1rem, 0px, 3rem)"], expect: 16},
		{call: "android.dp", args: ["min(10px, 2rem)"], expect: 10},
		{call: "android.dp", args: ["max(10px, 2rem)"], expect: 32},
		{call: "android.dp", args: ["12pt"], expect: 16},
		{call: "android.dp", args: ["0"], expect: 0},
		{call: "android.dp", args: ["5"], expect: null, why: "a bare number is no length"},
		{call: "android.dp", args: ["calc(1px + 2)"], expect: null},
		{call: "android.dp", args: ["100vw"], expect: 411},
		{call: "android.dp", args: ["10vh"], expect: null, why: "the card knows no viewport height"},
	]}

	"inline runs become one text with ranges where the style differs; whitespace collapses as HTML's": {suite: "android", steps: [
		{call: "android.render", args: [#"<p>Hello <b>big</b>   <i>world</i> and <a href="/x">link</a>!</p>"#, "b { font-size: 20px } a { color: #0000ff; text-decoration: none }"]},
		{get: "items.0"},
		{keep: "text"},
		{value: "$", holds: {type: "text", text: "Hello big world and link!"}},
		{pick: ["ranges.0.start", "ranges.0.end", "ranges.0.font_size", "ranges.0.font_weight", "ranges.1.start", "ranges.1.end", "ranges.1.text_color", "ranges.length"], expect: [6, 9, 20, "bold", 20, 24, "#FF0000FF", 2], why: "the <i> differs in nothing Android draws, so it has no range of its own"},
		{use: "text"},
		{get: "ranges.1.actions.0.url", matches: "^pronto://tap/e[0-9]+$", why: "a link among words is a range that taps"},
	]}

	"line breaks, text-transform and surrounding whitespace": {suite: "android", steps: [
		{call: "android.render", args: ["<h4 style=\"text-transform: uppercase\">  a   b <br> c  </h4>", ""]},
		{get: "items.0.text", expect: "A B\nC"},
		{call: "android.render", args: ["<pre>x  y\nz</pre>", ""]},
		{get: "items.0", holds: {text: "x  y\nz", font_family: "monospace"}, why: "a pre keeps its spaces and lines"},
	]}

	"form fields become input views with a variable holding the current value": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<label for="n">Name</label><input id="n" type="text" value="Ana" placeholder="Your name" maxlength="20">
			<input type="email"><input type="password" value="s3"><input type="number"><input type="tel"><input type="url" inputmode="url">
			<textarea rows="4">line</textarea><select><option value="a">A</option><option value="b" selected>B</option></select>
			"""#, ""]},
		{keep: "page"},
		{get: "card.variables"},
		{map: {get: "value"}},
		{value: "$", expect: ["Ana", "", "s3", "", "", "", "line", "b"]},
		{use: "page"},
		{get: "root"},
		{call: "android.findAll", args: ["$", {type: "input"}]},
		{map: {get: "keyboard_type"}},
		{value: "$", expect: ["single_line_text", "email", "password", "number", "phone", "uri", "multi_line_text"]},
		{use: "page"},
		{get: "root"},
		{call: "android.find", args: ["$", {type: "input", hint_text: "Your name"}]},
		{value: "$", holds: {max_length: 20, accessibility: {description: "Name", type: "edit_text"}}},
		{get: "text_variable", matches: "^v_e[0-9]+$"},
		{use: "page"},
		{get: "root"},
		{call: "android.find", args: ["$", {type: "select"}]},
		{value: "$", holds: {options: [{value: "a", text: "A"}, {value: "b", text: "B"}]}},
		{get: "value_variable", matches: "^v_e[0-9]+$"},
	]}

	"a field's variable is named v_ and the id of its view, and every variable is a field's": {suite: "android", steps: [
		{call: "android.render", args: [#"<input name="a" value="1"><select><option>x</option></select><textarea>t</textarea>"#, ""]},
		{call: "android.variablesNamedByIds", args: ["$"], expect: true},
	]}

	"taps: buttons, links, routes, handlers; none when disabled; long press for a context menu": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<button>Go</button><button disabled>No</button><p><a href="/x">Link</a></p><p><a>Plain</a></p><div data-route="/y">Route</div>
			<div data-on-click="x" data-on-contextmenu="menu">Press</div><p>idle</p><button type="submit" aria-disabled="true">Off</button>
			"""#, ""]},
		{get: "root"},
		{call: "android.taps", args: ["$"]},
		{value: "$", expect: [
			{text: "Go", tap: true, long: false}, {text: "No", tap: false, long: false}, {text: "Link", tap: true, long: false}, {text: "Plain", tap: false, long: false},
			{text: "Route", tap: true, long: false}, {text: "Press", tap: true, long: true}, {text: "idle", tap: false, long: false}, {text: "Off", tap: false, long: false},
		]},
	]}

	"checkboxes and radios draw as marks that tap and say whether they are checked": {suite: "android", steps: [
		{call: "android.render", args: [#"<label><input type="checkbox" checked> Remember</label><input type="radio"><input type="checkbox" disabled>"#, ""]},
		{get: "root"},
		{call: "android.findAll", args: ["$", {accessibility: {type: "checkbox"}}]},
		{map: {get: "accessibility.is_checked"}},
		{value: "$", expect: [true, false]},
		{call: "android.render", args: [#"<input type="radio" checked><input type="checkbox">"#, ""]},
		{get: "items.0"},
		{value: "$", holds: {accessibility: {type: "radio", is_checked: true}, border: {corner_radius: 10}}},
		{get: "actions.0.url", matches: "^pronto://tap/e[0-9]+$"},
	]}

	"ids are stable across compiles and name the element": {suite: "android", steps: [
		{call: "android.twice", args: [#"<div><p>t</p><input name="q"></div><button>b</button>"#, ""]},
		{value: "$", holds: {kept: true, newOne: 1, sameInput: true, unknown: null, elementTag: "BUTTON"}},
		{keep: "ids"},
		{get: "count", expect: 5, why: "body, div, p, input and button"},
		{use: "ids"},
		{get: "inputId", matches: "^e[0-9]+$"},
		{call: "android.repeats", args: [#"<div class="x"><p>t</p><input name="q" value="v"></div>"#, ".x { padding: 4px }"], expect: true, why: "the same page is the same card"},
	]}

	"a grid of equal tracks becomes a grid view with its gaps as margins": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="g"><div>1</div><div>2</div><div>3</div><div>4</div><div>5</div></div>"#, ".g { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px }"]},
		{get: "items.0"},
		{value: "$", holds: {type: "grid", column_count: 2}},
		{pick: ["items.0.margins", "items.1.margins", "items.2.margins", "items.3.margins", "items.4.margins", "items.length"], expect: [{right: 10, bottom: 10}, {bottom: 10}, {right: 10, bottom: 10}, {bottom: 10}, {right: 10}, 5]},
	]}

	"repeat(auto-fit, minmax(x, 1fr)) is as many columns as the width holds": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="g"><p>1</p><p>2</p><p>3</p><p>4</p></div>"#, ".g { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 16px }", {width: 411}]},
		{get: "items.0.column_count", expect: 3, why: "floor((411 + 16) / (120 + 16))"},
		{call: "android.render", args: [#"<div class="g"><p>1</p><p>2</p></div>"#, ".g { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 14rem), 1fr)); gap: 1rem }", {width: 300}]},
		{get: "items.0.type", expect: "container", why: "14rem = 224 and 300 holds one column: a vertical container, not a grid"},
	]}

	"a single-column grid is a vertical container spaced by the row gap; justify-self places a child": {suite: "android", steps: [
		{call: "android.render", args: [#"<form class="f"><label>Name <input></label><button>Go</button></form>"#, ".f { display: grid; gap: 12px } .f label { display: grid; gap: 4px } .f button { justify-self: start; min-height: 2.75rem }"]},
		{get: "items.0"},
		{value: "$", holds: {type: "container", orientation: "vertical", item_spacing: 12, items: [{orientation: "vertical", item_spacing: 4}, {type: "text", text: "Go", alignment_horizontal: "left", width: {type: "wrap_content"}, height: {type: "wrap_content", min_size: {value: 48}}}]}, why: "min-height 2.75rem is the content box: 44 and the button's padding and border"},
	]}

	"flex rows and columns: direction, gap, justify, align, grow, wrap": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<div class="r"><span>a</span><span>b</span></div>
			<div class="c"><p>x</p><p class="f">y</p></div>
			<div class="g"><p>1</p><p class="grow">2</p></div>
			<div class="w"><i>1</i><i>2</i></div>
			"""#, #"""
			.r { display: flex; gap: 8px; justify-content: center; align-items: center }
			.c { display: flex; flex-direction: column; gap: 4px } .c .f { flex: 1 }
			.g { display: flex } .g .grow { flex-grow: 2 }
			.w { display: flex; flex-wrap: wrap; gap: 8px 4px }
			"""#]},
		{keep: "page"},
		{get: "items.0"},
		{value: "$", holds: {orientation: "horizontal", item_spacing: 8, content_alignment_horizontal: "center", items: [{alignment_vertical: "center", width: {type: "wrap_content"}}, {alignment_vertical: "center"}]}},
		{use: "page"},
		{get: "items.1"},
		{value: "$", holds: {orientation: "vertical", item_spacing: 4, items: [{width: {type: "match_parent"}}, {height: {type: "match_parent", weight: 1}}]}},
		{use: "page"},
		{get: "items.2"},
		{value: "$", holds: {orientation: "horizontal", items: [{width: {type: "wrap_content"}}, {width: {type: "match_parent", weight: 2}}]}},
		{use: "page"},
		{get: "items.3"},
		{value: "$", holds: {layout_mode: "wrap", item_spacing: 4, line_spacing: 8}},
	]}

	"an auto margin in a flex row stands for the free space": {suite: "android", steps: [
		{call: "android.render", args: [#"<nav class="n"><a href="/">Home</a><span class="me">me</span></nav>"#, ".n { display: flex; align-items: center } .n .me { margin-inline-start: auto }"]},
		{get: "items.0.items"},
		{keep: "row"},
		{map: {get: "type"}, expect: ["text", "container", "text"]},
		{use: "row"},
		{get: "1.width", expect: {type: "match_parent", weight: 1}},
	]}

	"sizes: fixed, border-box, max-width with auto margins, min-height, percentages": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="a">a</div><div class="b">b</div><div class="m">m</div><div class="h">h</div><div class="p">p</div>"#, #"""
			.a { width: 100px; height: 40px; padding: 10px }
			.b { width: 100px; height: 40px; padding: 10px; box-sizing: border-box }
			.m { max-width: 20rem; margin-inline: auto }
			.h { min-height: 3rem }
			.p { width: 50% }
			"""#]},
		{get: "items"},
		{pick: ["0.width.value", "0.height.value", "1.width.value", "1.height.value", "2.width.value", "2.alignment_horizontal", "3.height.min_size.value", "3.width.type", "4.width.value"], expect: [120, 60, 100, 40, 320, "center", 48, "match_parent", 198], why: "content-box adds the padding; max-width on a stretching block with auto margins is fixed and centred; 50% is of the 395 the body's 8px margins leave"},
		{call: "android.render", args: [#"<div class="m">m</div>"#, ".m { max-width: 20rem; margin-inline: auto }", {width: 300}]},
		{get: "items.0.width.type", expect: "match_parent", why: "the screen is narrower than the max-width"},
	]}

	"block siblings' vertical margins collapse to the larger": {suite: "android", steps: [
		{call: "android.render", args: [#"<h3 style="margin:0 0 20px">t</h3><p style="margin:10px 0 0">p</p><p style="margin:5px 0 0">q</p>"#, ""]},
		{get: "items"},
		{pick: ["0.margins.bottom", "1.margins", "2.margins.top"], expect: [20, null, 5]},
	]}

	"paint: gradient, border, radii, shadow, opacity, clipping": {suite: "android", steps: [
		{call: "android.render", args: [#"<div class="p">x</div><div class="q">y</div>"#, #"""
			.p { background: linear-gradient(to right, #ff0000, #0000ff); border: 2px solid #00ff00; border-radius: 8px 4px;
			     box-shadow: 0 2px 6px rgba(0, 0, 0, .25); opacity: .5; overflow: hidden; padding: 4px }
			.q { background: linear-gradient(to bottom, #fff 0%, #000 100%); border-radius: 50% }
			"""#]},
		{get: "items.0"},
		{value: "$", holds: {
			background: [{type: "gradient", angle: 0, colors: ["#FFFF0000", "#FF0000FF"]}],
			border: {stroke: {color: "#FF00FF00", width: 2}, corners_radius: {"top-left": 8, "top-right": 4, "bottom-right": 8, "bottom-left": 4}, has_shadow: true, shadow: {alpha: 0.25, blur: 6, color: "#000000", offset: {x: 0, y: 2}}},
			alpha: 0.5, clip_to_bounds: true, paddings: {top: 6, left: 6},
		}},
		{call: "android.render", args: [#"<div class="q">y</div>"#, ".q { background: linear-gradient(to bottom, #fff 0%, #000 100%); border-radius: 50% }"]},
		{get: "items.0"},
		{value: "$", holds: {background: [{type: "gradient", angle: 270, color_map: [{color: "#FFFFFFFF", position: 0}, {color: "#FF000000", position: 1}]}], border: {corner_radius: 999}}},
	]}

	"a border on top or bottom alone is a separator beside the view": {suite: "android", steps: [
		{call: "android.render", args: [#"<nav class="n">Menu</nav><p>after</p>"#, ".n { border-bottom: 2px solid #336699; margin-bottom: 8px }"]},
		{get: "items.0"},
		{value: "$", holds: {type: "container", margins: {bottom: 8}, items: [{type: "text", text: "Menu", width: {type: "match_parent"}}, {type: "separator", delimiter_style: {color: "#FF336699"}, height: {type: "fixed", value: 2}}]}},
	]}

	"a border on one side or the left alone has no peer and is reported": {suite: "android", steps: [
		{call: "android.render", args: [#"<p class="l">x</p>"#, ".l { border-left: 3px solid #336699; padding: 2px }"]},
		{keep: "page"},
		{pick: ["items.0.border", "items.0.paddings"], expect: [null, {top: 2, right: 2, bottom: 2, left: 2}]},
		{use: "page"},
		{call: "android.reported", args: ["$"], expect: ["border on some sides only | p.l"]},
	]}

	"typography: font shorthand, weight, line height, letter spacing, text-align, nowrap": {suite: "android", steps: [
		{call: "android.render", args: [#"<p class="t">Hi</p><p class="u">there</p>"#, #"""
			.t { font: italic 700 1.25rem/1.6 monospace; letter-spacing: .1em; text-align: center; text-decoration: underline }
			.u { white-space: nowrap; text-align: right }
			"""#]},
		{keep: "page"},
		{get: "items.0"},
		{value: "$", holds: {font_size: 20, font_weight: "bold", font_weight_value: 700, line_height: 32, letter_spacing: 2, font_family: "monospace", text_alignment_horizontal: "center", underline: "single"}},
		{use: "page"},
		{get: "items.1"},
		{value: "$", holds: {max_lines: 1, text_alignment_horizontal: "right"}},
		{use: "page"},
	]}

	"an inline-flex button is a text view centred in a box": {suite: "android", steps: [
		{call: "android.render", args: [#"<button class="btn">OK</button>"#, ".btn { display: inline-flex; align-items: center; justify-content: center; min-height: 44px; padding: 0 16px; background: #123456; color: #fff; border-radius: 22px; border: 0 }"]},
		{get: "items.0"},
		{value: "$", holds: {
			type: "text", text: "OK", text_alignment_vertical: "center", text_alignment_horizontal: "center", text_color: "#FFFFFFFF",
			height: {type: "wrap_content", min_size: {value: 44}}, paddings: {left: 16, right: 16}, border: {corner_radius: 22},
			background: [{type: "solid", color: "#FF123456"}], accessibility: {type: "button"},
		}},
	]}

	"images resolve against the base and speak their alt; headings and labels reach accessibility": {suite: "android", steps: [
		{call: "android.render", args: [#"<img src="pic.png" alt="A picture"><img src="/abs/x.png" alt=""><h2 aria-label="Title!">T</h2><p aria-hidden="true">no</p><div role="heading">R</div>"#, "", {base: "https://app.test/shell/home/"}]},
		{get: "items"},
		{pick: ["0.image_url", "0.accessibility.description", "0.accessibility.type", "1.image_url", "1.accessibility.mode", "2.accessibility.description", "2.accessibility.type", "3.accessibility.mode", "4.accessibility.type"], expect: [
			"https://app.test/shell/home/pic.png", "A picture", "image", "https://app.test/abs/x.png", "exclude", "Title!", "header", "exclude", "header",
		]},
	]}

	"an hr is a separator; list items carry their markers": {suite: "android", steps: [
		{call: "android.render", args: [#"<ul><li>One</li><li>Two</li></ul><ol><li>A</li><li>B</li></ol><hr>"#, ""]},
		{keep: "page"},
		{get: "root"},
		{call: "android.texts", args: ["$"], expect: ["• One", "• Two", "1. A", "2. B"]},
		{use: "page"},
		{get: "root"},
		{call: "android.types", args: ["$"]},
		{call: "android.count", args: ["$", "separator"], expect: 1},
	]}

	"::before and ::after with a string content are text; other content is reported": {suite: "android", steps: [
		{call: "android.render", args: [#"<p class="q">hi</p><p class="k">k</p>"#, #"""
			.q::before { content: "\201C" } .q::after { content: "\201D" }
			.k::after { content: counter(n) }
			"""#]},
		{keep: "page"},
		{get: "items.0.text", expect: "“hi”"},
		{use: "page"},
		{call: "android.reported", args: ["$"], expect: ["content: counter(n) | p.k::after"]},
	]}

	"what has no peer is reported once, with its selector, and never dropped silently": {suite: "android", steps: [
		{call: "android.render", args: [#"""
			<svg width="10" height="10"></svg>
			<p class="a" style="position:fixed;transform:rotate(1deg)">x</p><p class="a" style="transform:rotate(2deg)">y</p>
			<div style="font-family:Georgia, serif">z</div><em>e</em><nav class="s" style="overflow-x:auto">n</nav><canvas></canvas>
			"""#, #"""
			@import url("more.css");
			@container (min-width: 10px) { p { color: red } }
			p.a::first-line { color: red }
			p:not-a-real-pseudo(1) { color: red }
			@font-face { font-family: X; src: url(x.woff) }
			@keyframes spin { to { opacity: 0 } }
			a:hover, button:focus-visible, li:active { color: red }
			"""#]},
		{call: "android.reported", args: ["$"], expect: [
			"@import | url(\"more.css\")", "@container | (min-width: 10px)", "pseudo-element ::first-line | p.a::first-line", "selector not understood | p:not-a-real-pseudo(1)",
			"inline svg | svg", "position: fixed | p.a", "transform | p.a", "font-family: georgia | div", "font-style: italic | em", "overflow: auto (no inner scrolling) | nav.s", "canvas | canvas",
		]},
	]}

	"interaction states are silent non-matches and :not(:hover) matches": {suite: "android", steps: [
		{call: "android.render", args: [#"<a href="/x">l</a><p>p</p>"#, #"""
			a:hover { color: #ff0000 } button:focus-visible { outline: 2px solid red } a:active { color: #00ff00 }
			p:not(:hover) { color: #123456 } p:hover { color: #ff0000 }
			"""#]},
		{keep: "page"},
		{get: "items.1.text_color", expect: "#FF123456"},
		{use: "page"},
		{call: "android.reported", args: ["$"], expect: [], why: ":hover, :focus-visible and :active are never matched, and say nothing"},
	]}

	"the scheme: light-dark() follows color-scheme, and a subtree can force one": {suite: "android", steps: [
		{call: "android.render", args: [#"<p>a</p><div class="f"><p>b</p></div>"#, #"""
			:root { color-scheme: light dark; --fg: light-dark(#111111, #eeeeee) }
			body { color: var(--fg); background: light-dark(#ffffff, #000000) }
			.f { color-scheme: dark; color: var(--fg) }
			"""#, {scheme: "dark"}]},
		{keep: "dark"},
		{get: "root.background.0.color", expect: "#FF000000"},
		{use: "dark"},
		{get: "items.0.text_color", expect: "#FFEEEEEE"},
		{call: "android.render", args: [#"<p>a</p><div class="f"><p>b</p></div>"#, #"""
			:root { color-scheme: light dark; --fg: light-dark(#111111, #eeeeee) }
			body { color: var(--fg); background: light-dark(#ffffff, #000000) }
			.f { color-scheme: dark; color: var(--fg) }
			"""#, {scheme: "light"}]},
		{keep: "light"},
		{get: "items.0.text_color", expect: "#FF111111"},
		{use: "light"},
		{get: "items.1.items.0.text_color", expect: "#FFEEEEEE", why: "a dark subtree in a light page"},
		{call: "android.render", args: [#"<p>a</p>"#, "body { color: light-dark(#111111, #eeeeee) }", {scheme: "dark"}]},
		{get: "items.0.text_color", expect: "#FF111111", why: "without color-scheme the page is light, and light-dark() takes its first"},
	]}

	"the root has the background of html, else of body": {suite: "android", steps: [
		{call: "android.render", args: ["<p>a</p>", "html { background: #abcdef }"]},
		{get: "root.background", expect: [{type: "solid", color: "#FFABCDEF"}]},
		{call: "android.render", args: ["<p>a</p>", "body { background: #123456 }"]},
		{keep: "page"},
		{get: "root.background", expect: [{type: "solid", color: "#FF123456"}]},
		{use: "page"},
		{pick: ["body.background"], expect: [null], why: "body's background went to the canvas"},
		{call: "android.render", args: ["<p>a</p>", "html { background: #abcdef } body { background: #123456; margin: 8px }"]},
		{keep: "both"},
		{get: "body.background", expect: [{type: "solid", color: "#FF123456"}]},
		{use: "both"},
		{get: "body.margins", expect: {top: 8, right: 8, bottom: 8, left: 8}},
		{call: "android.render", args: ["<p>a</p>", ""]},
		{get: "root.background", expect: [{type: "solid", color: "#FFFFFFFF"}]},
	]}

	"the guestbook's home screen comes out as a heading, a form card and the wall's entry cards": {suite: "android", steps: [
		{call: "android.guestbook", args: []},
		{keep: "page"},
		{get: "root"},
		{call: "android.texts", args: ["$"]},
		{value: "$", expect: ["Guestbook", "Leave a name and a few words. Everyone who opens this page reads them.", "Your name", "Your note", "Sign the guestbook", "The wall", "Ana Nov 5", "Hello from Recife", "Bruno Nov 4", "First!"], why: "the hidden error line and the item template draw nothing"},
		{use: "page"},
		{get: "root"},
		{call: "android.find", args: ["$", {text: "Guestbook"}]},
		{value: "$", holds: {accessibility: {type: "header"}, font_weight: "bold"}},
		{use: "page"},
		{get: "root"},
		{call: "android.findAll", args: ["$", {type: "input"}]},
		{value: "$", holds: [{keyboard_type: "single_line_text", max_length: 40, accessibility: {description: "Your name"}}, {keyboard_type: "multi_line_text", max_length: 280, accessibility: {description: "Your note"}}]},
		{use: "page"},
		{get: "root"},
		{call: "android.find", args: ["$", {text: "Sign the guestbook"}]},
		{keep: "button"},
		{value: "$", holds: {accessibility: {type: "button"}}, why: "the primary button"},
		{use: "button"},
		{get: "actions.0.url", matches: "^pronto://tap/e[0-9]+$"},
		{use: "page"},
		{get: "card.variables"},
		{map: {get: "name"}},
		{get: "length", expect: 2, why: "the name and the note"},
		{use: "page"},
		{get: "root"},
		{call: "android.findAll", args: ["$", {type: "container", border: {stroke: {width: 1}}}]},
		{get: "length", expect: 4, why: "the form card, the wall, and the two entries"},
		{use: "page"},
		{call: "android.reported", args: ["$"], expect: [], why: "nothing the home screen uses lacks a peer"},
		{call: "android.guestbook", args: [{scheme: "dark"}]},
		{keep: "dark"},
		{get: "root.background", expect: [{type: "solid", color: "#FF15130F"}], why: "the shell's --neutral, dark"},
		{use: "dark"},
		{get: "root"},
		{call: "android.find", args: ["$", {text: "Guestbook"}]},
		{get: "text_color", expect: "#FFF5F0E6"},
	]}

	"a 400-rule sheet over a 200-element screen compiles in under 100 ms": {suite: "android", steps: [
		{call: "android.perf", args: [400, 200]},
		{keep: "run"},
		{get: "under", expect: true, why: "QuickJS is about 50 times slower than V8 and this runs on every DOM change"},
		{use: "run"},
		{get: "rules", expect: 401, why: "400 rules and the root's custom properties"},
		{use: "run"},
		{get: "elements", expect: 201, why: "a main, and 50 sections of a div, a span and a p"},
		{use: "run"},
		{get: "drawn", near: {value: 160, within: 10}, why: "the screen was drawn, not skipped"},
	]}
}
