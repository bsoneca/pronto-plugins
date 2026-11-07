// The roots this machine's local stack is served under, by name: Caddy's local authority (the
// door at https://localhost) and mkcert's, where there is one. A debug build trusts them
// (bundle.ts), and so does the scenario runner's stand-in browser (scenarios.ts). Never a release.

/** Each root's PEM by name; a root this machine does not have is left out. */
export async function localRoots(): Promise<Record<string, string>> {
  const home = Deno.env.get("HOME") ?? "";
  const caddyData = Deno.env.get("XDG_DATA_HOME")
    ? `${Deno.env.get("XDG_DATA_HOME")}/caddy`
    : Deno.build.os === "darwin" ? `${home}/Library/Application Support/Caddy` : `${home}/.local/share/caddy`;
  let caroot = "";
  try {
    caroot = new TextDecoder().decode((await new Deno.Command("mkcert", { args: ["-CAROOT"], stdout: "piped", stderr: "null" }).output()).stdout).trim();
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
  const paths: Record<string, string> = { local_caddy: `${caddyData}/pki/authorities/local/root.crt`, local_ca: caroot ? `${caroot}/rootCA.pem` : "" };
  const roots: Record<string, string> = {};
  for (const [name, path] of Object.entries(paths)) {
    const pem = path ? await Deno.readTextFile(path).catch(() => "") : "";
    if (pem) roots[name] = pem;
  }
  return roots;
}
