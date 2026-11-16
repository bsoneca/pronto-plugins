// The roots this machine's local stack is served under, by name: Caddy's local authority (the
// door at https://localhost) and mkcert's, where there is one, and the root the stack in the working folder made for itself (.certs). A debug build trusts them
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
  // A stack made on a host with no mkcert root of its own issues one in its folder (.certs, the launch task's CAROOT) and signs its door with it.
  await stackPair();
  const paths: Record<string, string> = {
    local_caddy: `${caddyData}/pki/authorities/local/root.crt`,
    local_ca: caroot ? `${caroot}/rootCA.pem` : "",
    local_stack: ".certs/rootCA.pem",
  };
  const roots: Record<string, string> = {};
  for (const [name, path] of Object.entries(paths)) {
    const pem = path ? await Deno.readTextFile(path).catch(() => "") : "";
    if (pem) roots[name] = pem;
  }
  return roots;
}

/**
 * The pair a stack's door is signed with where the host has no mkcert root of its own: the launch task issues it into the app's
 * .certs (its own CAROOT) when it is not there, and the slot's copy of the app links to that folder. The apk is built before the
 * stack starts, so the pair is issued here, the launch task's own command, and the stack then finds it and signs with it.
 */
async function stackPair(): Promise<void> {
  const have = async (f: string) => await Deno.stat(`.certs/${f}`).then(() => true, () => false);
  if ((await have("localhost.pem")) && (await have("localhost-key.pem")) && (await have("rootCA.pem"))) return;
  await Deno.mkdir(".certs", { recursive: true });
  try {
    const caroot = await Deno.realPath(".certs");
    await new Deno.Command("mkcert", {
      args: ["-cert-file", ".certs/localhost.pem", "-key-file", ".certs/localhost-key.pem", "localhost", "caddy", "127.0.0.1", "::1"],
      env: { CAROOT: caroot },
      stdout: "null",
      stderr: "null",
    }).output();
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
}
