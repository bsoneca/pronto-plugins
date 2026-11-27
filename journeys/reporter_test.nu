# The reporter's error handling, run as a page runs it (reporter_check.js): `./saytw --script tools.nu nu
# journeys/reporter_test.nu`, which needs deno.
def main [] {
	cd ($env.FILE_PWD)
	^deno run --no-config --allow-read --allow-write --allow-env reporter_check.js
}
