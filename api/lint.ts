// pronto-api's own lint: the plugin is the same for every app, so nothing under api/ may name one.
// An app's name, or a table or event only an app has, means app-specific code crept into the
// plugin; what an app exports comes from its api_spec.cue, its program.cue and the contract
// generated from them. The README (prose that may cite an app) is not read.
// The words (apps' names, and tables and events only an app has) are the plugin's test data, not
// code here, which would name them: tests/unit/api_generate.cue holds them, and its case runs this
// over api/ in the api suite.

/** Each file under `dir` naming an app's word: its path from `dir`, and the word. */
export async function named(dir: string, words: string[]): Promise<{ file: string; word: string }[]> {
  const found: { file: string; word: string }[] = [];
  const re = new RegExp(`(?<![a-z0-9])(${words.join("|")})(?![a-z0-9])`, "i");
  async function walk(at: string, rel: string) {
    for await (const e of Deno.readDir(at)) {
      const path = `${at}/${e.name}`, r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory) {
        await walk(path, r);
      } else if (e.isFile && r !== "README.md") {
        const m = re.exec(await Deno.readTextFile(path));
        if (m) found.push({ file: r, word: m[1].toLowerCase() });
      }
    }
  }
  await walk(dir.replace(/\/$/, ""), "");
  return found.sort((a, b) => a.file.localeCompare(b.file));
}
