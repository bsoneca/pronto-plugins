// A release target for an app that needs a server (gcp/deploy.ts): whether it needs one, the
// release.cue for release@gcp in a Google Cloud project, the program with `gcp` among its targets,
// and whether a release.cue releases into a project shared with other apps.

/** A Google Cloud project and region to release to. */
export interface Cloud {
  project: string;
  region: string;
}

/** Whether a program needs a server: an entity kept on one (server or live), or sign-in. */
export function needsCloud(program: string): boolean {
  return /durability:\s*"(server|live)"/.test(program) || /^\s*auth:\s*\{/m.test(program);
}

/** The release.cue for such an app: release@gcp into `cloud`, named after the app (a name Cloud SQL
 * and Cloud Run both take), in the program's own package. */
export function releaseCue(program: string, app: string, cloud: Cloud): string {
  const pkg = /^package\s+([a-z_][a-z0-9_]*)\s*$/m.exec(program)?.[1];
  if (!pkg) throw new Error(`${app}'s program.cue names no package.`);
  const name = app.slice(0, 30).replace(/-+$/, "");
  return `// Where ${app} runs: release@gcp, its own Cloud Run service and Cloud SQL database in
// ${cloud.project} (written by pronto deploy gcp; pronto's docs/release-targets.md#gcp).
package ${pkg}

import "github.com/bonisoft3/pronto/gcp/schema"

GCP: schema.#Release & {
	name:    "${name}"
	project: "${cloud.project}"
	region:  "${cloud.region}"
}

gcpRelease: schema.#Build & {release: GCP}

// Drawn in the browser: release@gcp runs no render service yet (pronto PENDING.md#release-targets).
code: surface: screens: [string]: ssr: "spa"
`;
}

/** The program with `target` among its meta.targets, from which pronto emits a release@<target>
 * rule (pronto's docs/release-targets.md): its targets list edited, keeping the others, or null
 * where the program names none, so release.cue says them. Unchanged where it is there already. */
export function withTarget(program: string, target: string): string | null {
  const m = /^(\s*targets:\s*)\[([^\]\n]*)\]/m.exec(program);
  if (!m) return null;
  const listed = m[2].split(",").map((t) => t.trim()).filter(Boolean);
  if (listed.includes(`"${target}"`)) return program;
  const next = [...listed, `"${target}"`].join(", ");
  return program.slice(0, m.index) + `${m[1]}[${next}]` + program.slice(m.index + m[0].length);
}

/** Whether release.cue releases into the project shared with other apps, where a release goes out
 * without the warm preview it otherwise tests first (a preview kept warm would be a second
 * database for every app). */
export function inShared(releaseCueText: string, shared: Cloud | null): boolean {
  return !!shared && new RegExp(`project:\\s*"${shared.project}"`).test(releaseCueText);
}
