// Plane's REST API (https://developers.plane.so/api-reference), the few calls the dev flow makes: the
// project, its states, labels, modules and cycles, and an issue's state, comments and links. One
// token, X-API-Key; the token is a member's, made once in Plane's profile settings. The adapter of
// the Board interface (board/board.ts) for kind plane.
import type { Board, Cycle, Issue, Member, Named, NewIssue, State } from "./board/board.ts";

export class Plane implements Board {
  constructor(readonly origin: string, readonly workspace: string, private readonly token: string) {}

  // deno-lint-ignore no-explicit-any
  private async call(method: string, path: string, body?: unknown): Promise<any> {
    const url = path.startsWith("http") ? path : `${this.origin}/api/v1${path}`;
    for (let attempt = 0; ; attempt++) {
      const r = await fetch(url, {
        method,
        headers: { "X-API-Key": this.token, "Content-Type": "application/json", Accept: "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      // Plane limits a token's calls a minute (env.api_key_rate_limit): wait and ask again.
      if (r.status === 429 && attempt < 5) {
        await new Promise((ok) => setTimeout(ok, 2000 * (attempt + 1)));
        continue;
      }
      const text = await r.text();
      if (!r.ok) throw new Error(`plane ${method} ${path}: ${r.status} ${text.slice(0, 300)}`);
      return text ? JSON.parse(text) : null;
    }
  }

  /** Every page of a list. */
  private async all<T>(path: string): Promise<T[]> {
    const out: T[] = [];
    let cursor = "";
    for (;;) {
      const sep = path.includes("?") ? "&" : "?";
      const page = await this.call("GET", `${path}${sep}per_page=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
      if (Array.isArray(page)) return page as T[];
      out.push(...(page.results ?? []));
      if (!page.next_page_results || !page.next_cursor) return out;
      cursor = page.next_cursor;
    }
  }

  private ws = () => `/workspaces/${this.workspace}`;
  private p = (project: string) => `${this.ws()}/projects/${project}`;

  me = () => this.call("GET", "/users/me/") as Promise<Member>;
  members = (project: string) => this.all<Member>(`${this.p(project)}/members/`);
  projects = () => this.all<Named & { identifier: string }>(`${this.ws()}/projects/`);
  createProject = (name: string, identifier: string) => this.call("POST", `${this.ws()}/projects/`, { name, identifier, network: 0 }) as Promise<Named>;
  enableFeatures = async (project: string) => void (await this.call("PATCH", `${this.p(project)}/`, { cycle_view: true, module_view: true }));

  states = (project: string) => this.all<State>(`${this.p(project)}/states/`);
  createState = (project: string, s: { name: string; group: string; color: string; description?: string }) => this.call("POST", `${this.p(project)}/states/`, s);
  updateState = (project: string, id: string, fields: Record<string, unknown>) => this.call("PATCH", `${this.p(project)}/states/${id}/`, fields);
  setDefaultState = (project: string, id: string) => this.updateState(project, id, { default: true });

  labels = (project: string) => this.all<Named>(`${this.p(project)}/labels/`);
  createLabel = (project: string, name: string, color: string) => this.call("POST", `${this.p(project)}/labels/`, { name, color }) as Promise<Named>;

  modules = (project: string) => this.all<Named>(`${this.p(project)}/modules/`);
  createModule = (project: string, name: string, description: string) => this.call("POST", `${this.p(project)}/modules/`, { name, description }) as Promise<Named>;
  addToModule = (project: string, module: string, issues: string[]) => this.call("POST", `${this.p(project)}/modules/${module}/module-issues/`, { issues });
  private moduleIssues = (project: string, module: string) => this.all<Issue>(`${this.p(project)}/modules/${module}/module-issues/`);
  /** Each issue's modules, by name: read from the modules, since an issue's own fields may not say. */
  async modulesByIssue(project: string): Promise<Map<string, string[]>> {
    const by = new Map<string, string[]>();
    for (const m of await this.modules(project)) {
      for (const i of await this.moduleIssues(project, m.id)) by.set(i.id, [...(by.get(i.id) ?? []), m.name]);
    }
    return by;
  }

  cycles = (project: string) => this.all<Cycle>(`${this.p(project)}/cycles/`);
  createCycle = (project: string, name: string, start: string, end: string, owner: string) =>
    this.call("POST", `${this.p(project)}/cycles/`, { name, start_date: start, end_date: end, project_id: project, owned_by: owner }) as Promise<Cycle>;
  cycleIssues = (project: string, cycle: string) => this.all<Issue>(`${this.p(project)}/cycles/${cycle}/cycle-issues/`);
  removeFromCycle = (project: string, cycle: string, issue: string) => this.call("DELETE", `${this.p(project)}/cycles/${cycle}/cycle-issues/${issue}/`);
  addToCycle = (project: string, cycle: string, issues: string[]) => this.call("POST", `${this.p(project)}/cycles/${cycle}/cycle-issues/`, { issues });

  issues = (project: string) => this.all<Issue>(`${this.p(project)}/issues/`);
  /** An issue by its key, PRONTO-123. */
  issue = (key: string) => this.call("GET", `${this.ws()}/issues/${key}/`) as Promise<Issue>;
  createIssue = (project: string, fields: NewIssue) => this.call("POST", `${this.p(project)}/issues/`, fields) as Promise<Issue>;
  private updateIssue = (project: string, id: string, fields: Record<string, unknown>) => this.call("PATCH", `${this.p(project)}/issues/${id}/`, fields) as Promise<Issue>;
  moveIssue = (project: string, id: string, state: string) => this.updateIssue(project, id, { state });
  describe = (project: string, id: string, html: string) => this.updateIssue(project, id, { description_html: html });
  comment = (project: string, id: string, html: string) => this.call("POST", `${this.p(project)}/issues/${id}/comments/`, { comment_html: html });
  links = (project: string, id: string) => this.all<{ url: string }>(`${this.p(project)}/issues/${id}/links/`);
  link = (project: string, id: string, url: string, title: string) => this.call("POST", `${this.p(project)}/issues/${id}/links/`, { url, title });
}
