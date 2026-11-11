// GitHub Projects (v2), the board of kind github-projects: the adapter of the Board interface
// (board/board.ts) over GitHub's GraphQL API for the project and its fields, and its REST API for
// the repository's issues, labels and comments. The mapping (board/github.js) says how a project's
// fields hold the flow's states, priorities, apps and sprints. One token, a GitHub token with the
// `project` and `repo` scopes.
import type { Board, Comment, Cycle, Issue, Member, Named, NewIssue, State } from "./board/board.ts";
import { askAgain } from "./flow.js";
import { colorOf, cycleOf, FIELDS, issueOf, iterationsWith, linkComment, linksOf, optionsWith, PRIORITIES, stateOf } from "./board/github.js";

const API = "https://api.github.com";

// deno-lint-ignore no-explicit-any
type Json = any;
type Option = { id: string; name: string; color?: string; description?: string };
type Iteration = { id: string; title: string; startDate: string; duration: number };
type Field = { id: string; name: string; dataType: string; options?: Option[]; multiSelectOptions?: Option[]; configuration?: { duration: number; iterations: Iteration[]; completedIterations: Iteration[] } };

const FIELD_VALUES = `fieldValues(first: 30) { nodes {
  ... on ProjectV2ItemFieldSingleSelectValue { optionId name field { ... on ProjectV2FieldCommon { name } } }
  ... on ProjectV2ItemFieldMultiSelectValue { options { id name } field { ... on ProjectV2FieldCommon { name } } }
  ... on ProjectV2ItemFieldIterationValue { iterationId title field { ... on ProjectV2FieldCommon { name } } }
} }`;
const ISSUE = `... on Issue { id number title body repository { nameWithOwner } labels(first: 50) { nodes { id: name } } }`;

export class GitHubProjects implements Board {
  private projectId: string | null = null;
  private fieldCache: Field[] | null = null;

  /**
   * `owner` holds the project (a user or an organization), titled `title`, its issues in `repository`
   * (owner/name); `identifier` is the key its issues carry (PRONTO-123 is the repository's #123).
   */
  constructor(readonly owner: string, readonly repository: string, readonly title: string, readonly identifier: string, private readonly token: string) {}

  private async rest(method: string, path: string, body?: unknown): Promise<Json> {
    for (let attempt = 0; ; attempt++) {
      // As Plane's (plane.ts call): each call waits 30 s at most, and flow.js askAgain says which
      // failures are asked again (PRONTO-341).
      let failure: number | "timeout" | "network";
      let text = "";
      let after = 0;
      try {
        const r = await fetch(`${API}${path}`, {
          method,
          headers: { Authorization: `Bearer ${this.token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json" },
          body: body === undefined ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(Number(Deno.env.get("PLANE_TIMEOUT_MS") ?? "") || 30_000),
        });
        text = await r.text();
        if (r.ok) return text ? JSON.parse(text) : null;
        // A secondary rate limit (a 403 with retry-after) never ran, as a 429.
        after = Number(r.headers.get("retry-after") ?? 0) * 1000;
        failure = r.status === 403 && after ? 429 : r.status;
      } catch (e) {
        failure = e instanceof DOMException && (e.name === "TimeoutError" || e.name === "AbortError") ? "timeout" : "network";
        text = String(e);
      }
      const wait = askAgain(method, failure, attempt);
      if (wait === null) throw new Error(`github ${method} ${path}: ${failure} ${text.slice(0, 300)}`);
      await new Promise((ok) => setTimeout(ok, Math.max(wait, after)));
    }
  }

  private async gql(query: string, variables: Record<string, unknown> = {}): Promise<Json> {
    const r = await this.rest("POST", "/graphql", { query, variables });
    if (r.errors?.length) throw new Error(`github graphql: ${r.errors.map((e: { message: string }) => e.message).join("; ")}`);
    return r.data;
  }

  /** Every page of a REST list. */
  private async restAll(path: string): Promise<Json[]> {
    const out: Json[] = [];
    for (let page = 1; ; page++) {
      const sep = path.includes("?") ? "&" : "?";
      const got = await this.rest("GET", `${path}${sep}per_page=100&page=${page}`);
      out.push(...got);
      if (got.length < 100) return out;
    }
  }

  private repo = () => `/repos/${this.repository}`;

  /** The project's node id, found by its title among the owner's projects. */
  private async project(): Promise<string> {
    if (this.projectId) return this.projectId;
    const p = (await this.projects())[0];
    if (!p) throw new Error(`no project ${this.title} of ${this.owner}: run bin/pronto connect plane`);
    return (this.projectId = p.id);
  }

  private async fields(fresh = false): Promise<Field[]> {
    if (this.fieldCache && !fresh) return this.fieldCache;
    const d = await this.gql(
      `query($p: ID!) { node(id: $p) { ... on ProjectV2 { fields(first: 50) { nodes {
        ... on ProjectV2FieldCommon { id name dataType }
        ... on ProjectV2SingleSelectField { options { id name color description } }
        ... on ProjectV2MultiSelectField { multiSelectOptions { id name color description } }
        ... on ProjectV2IterationField { configuration { duration iterations { id title startDate duration } completedIterations { id title startDate duration } } }
      } } } } }`,
      { p: await this.project() },
    );
    return (this.fieldCache = d.node.fields.nodes);
  }

  private async field(name: string): Promise<Field> {
    const f = (await this.fields()).find((x) => x.name === name);
    if (!f) throw new Error(`the project ${this.title} has no ${name} field: run bin/pronto connect plane`);
    return f;
  }

  private async updateField(fieldId: string, input: Record<string, unknown>) {
    await this.gql(`mutation($i: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $i) { clientMutationId } }`, { i: { fieldId, ...input } });
    this.fieldCache = null;
  }

  private async setValue(item: string, field: string, value: Record<string, unknown>) {
    await this.gql(`mutation($i: UpdateProjectV2ItemFieldValueInput!) { updateProjectV2ItemFieldValue(input: $i) { clientMutationId } }`, {
      i: { projectId: await this.project(), itemId: item, fieldId: (await this.field(field)).id, value },
    });
  }

  /** Every item of the project that is an issue of the board's repository. */
  private async items(): Promise<ReturnType<typeof issueOf>[]> {
    const out: ReturnType<typeof issueOf>[] = [];
    let after: string | null = null;
    for (;;) {
      const d: Json = await this.gql(
        `query($p: ID!, $after: String) { node(id: $p) { ... on ProjectV2 { items(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor } nodes { id content { ${ISSUE} } ${FIELD_VALUES} } } } } }`,
        { p: await this.project(), after },
      );
      const page = d.node.items;
      for (const it of page.nodes) if (it.content?.repository?.nameWithOwner === this.repository) out.push(issueOf(it));
      if (!page.pageInfo.hasNextPage) return out;
      after = page.pageInfo.endCursor;
    }
  }

  /** The project item of an issue (by its node id), added to the project when it is not in it yet. */
  private async itemOf(issueId: string): Promise<string> {
    const d = await this.gql(`query($i: ID!) { node(id: $i) { ... on Issue { projectItems(first: 50) { nodes { id project { id } } } } } }`, { i: issueId });
    const p = await this.project();
    const found = (d.node?.projectItems?.nodes ?? []).find((n: Json) => n.project.id === p);
    if (found) return found.id;
    const a = await this.gql(`mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: { projectId: $p, contentId: $c }) { item { id } } }`, { p, c: issueId });
    return a.addProjectV2ItemById.item.id;
  }

  private async numberOf(issueId: string): Promise<number> {
    const d = await this.gql(`query($i: ID!) { node(id: $i) { ... on Issue { number } } }`, { i: issueId });
    return d.node.number;
  }

  /** An issue with its project item's values, by its number. */
  private async byNumber(n: number): Promise<Issue> {
    const [owner, name] = this.repository.split("/");
    const d = await this.gql(
      `query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { issue(number: $n) { ${ISSUE.replace("... on Issue ", "")} projectItems(first: 50) { nodes { id project { id } ${FIELD_VALUES} } } } } }`,
      { o: owner, r: name, n },
    );
    const issue = d.repository.issue;
    if (!issue) throw new Error(`${this.identifier}-${n}: no issue #${n} in ${this.repository}`);
    const p = await this.project();
    const item = issue.projectItems.nodes.find((x: Json) => x.project.id === p) ?? { id: await this.itemOf(issue.id), fieldValues: { nodes: [] } };
    return issueOf({ ...item, content: issue }) as unknown as Issue;
  }

  async me(): Promise<Member> {
    const d = await this.gql(`{ viewer { id login } }`);
    return { id: d.viewer.id, display_name: d.viewer.login };
  }
  members = async (_project: string): Promise<Member[]> => (await this.restAll(`${this.repo()}/collaborators`)).map((u) => ({ id: u.node_id, display_name: u.login }));

  /** The owner's project titled as the board's, as the one project the board has. */
  async projects(): Promise<(Named & { identifier: string })[]> {
    const d = await this.gql(`query($o: String!) { repositoryOwner(login: $o) { ... on ProjectV2Owner { projectsV2(first: 100) { nodes { id title closed } } } } }`, { o: this.owner });
    return (d.repositoryOwner?.projectsV2?.nodes ?? []).filter((p: Json) => p.title === this.title && !p.closed).map((p: Json) => ({ id: p.id, name: p.title, identifier: this.identifier }));
  }

  async createProject(name: string, _identifier: string): Promise<Named> {
    const [owner, repo] = this.repository.split("/");
    const d = await this.gql(`query($l: String!, $o: String!, $r: String!) { repositoryOwner(login: $l) { id } repository(owner: $o, name: $r) { id } }`, { l: this.owner, o: owner, r: repo });
    const c = await this.gql(`mutation($i: CreateProjectV2Input!) { createProjectV2(input: $i) { projectV2 { id title } } }`, { i: { ownerId: d.repositoryOwner.id, title: name, repositoryId: d.repository.id } });
    this.projectId = c.createProjectV2.projectV2.id;
    return { id: c.createProjectV2.projectV2.id, name };
  }

  /** The fields the flow keeps beside Status: Priority, Module and Sprint. */
  async enableFeatures(project: string): Promise<void> {
    const have = new Set((await this.fields(true)).map((f) => f.name));
    const make = (i: Record<string, unknown>) => this.gql(`mutation($i: CreateProjectV2FieldInput!) { createProjectV2Field(input: $i) { clientMutationId } }`, { i: { projectId: project, ...i } });
    if (!have.has(FIELDS.priority)) await make({ name: FIELDS.priority, dataType: "SINGLE_SELECT", singleSelectOptions: PRIORITIES.map((p) => ({ name: p, color: "GRAY", description: "" })) });
    if (!have.has(FIELDS.module)) await make({ name: FIELDS.module, dataType: "MULTI_SELECT", multiSelectOptions: [{ name: "plugins", color: "GRAY", description: "" }] });
    if (!have.has(FIELDS.sprint)) await make({ name: FIELDS.sprint, dataType: "ITERATION", iterationConfiguration: { startDate: new Date().toISOString().slice(0, 10), duration: 1, iterations: [] } });
    this.fieldCache = null;
  }

  states = async (_project: string): Promise<State[]> => ((await this.field(FIELDS.status)).options ?? []).map(stateOf) as State[];
  async createState(_project: string, s: { name: string; group: string; color: string; description?: string }) {
    const f = await this.field(FIELDS.status);
    await this.updateField(f.id, { singleSelectOptions: optionsWith(f.options ?? [], { add: s }) });
  }
  async updateState(_project: string, id: string, fields: Record<string, unknown>) {
    const f = await this.field(FIELDS.status);
    await this.updateField(f.id, { singleSelectOptions: optionsWith(f.options ?? [], { change: { id, fields } }) });
  }
  async setDefaultState(_project: string, id: string) {
    const f = await this.field(FIELDS.status);
    await this.updateField(f.id, { singleSelectOptions: optionsWith(f.options ?? [], { defaultId: id }) });
  }

  /** The repository's labels; a label's id is its name, as the REST API takes it. */
  labels = async (_project: string): Promise<Named[]> => (await this.restAll(`${this.repo()}/labels`)).map((l) => ({ id: l.name, name: l.name }));
  createLabel = async (_project: string, name: string, color: string): Promise<Named> => {
    await this.rest("POST", `${this.repo()}/labels`, { name, color: color.replace(/^#/, "") });
    return { id: name, name };
  };

  modules = async (_project: string): Promise<Named[]> => ((await this.field(FIELDS.module)).multiSelectOptions ?? []).map((o) => ({ id: o.id, name: o.name }));
  async createModule(_project: string, name: string, description: string): Promise<Named> {
    const f = await this.field(FIELDS.module);
    const keep = (f.multiSelectOptions ?? []).map((o) => ({ id: o.id, name: o.name, color: o.color ?? "GRAY", description: o.description ?? "" }));
    await this.updateField(f.id, { multiSelectOptions: [...keep, { name, color: colorOf("#a3a3a3"), description }] });
    return (await this.modules(_project)).find((m) => m.name === name)!;
  }
  async addToModule(project: string, module: string, issues: string[]) {
    const all = await this.items();
    const names = new Map((await this.modules(project)).map((m) => [m.name, m.id]));
    for (const id of issues) {
      const it = all.find((i) => i.id === id);
      const have = (it?.modules ?? []).map((n: string) => names.get(n)).filter(Boolean) as string[];
      await this.setValue(it?.item ?? (await this.itemOf(id)), FIELDS.module, { multiSelectOptionIds: [...new Set([...have, module])] });
    }
  }
  modulesByIssue = async (_project: string): Promise<Map<string, string[]>> => new Map((await this.items()).map((i) => [i.id, i.modules]));

  async cycles(_project: string): Promise<Cycle[]> {
    const c = (await this.field(FIELDS.sprint)).configuration;
    return [...(c?.completedIterations ?? []), ...(c?.iterations ?? [])].map(cycleOf);
  }
  async createCycle(_project: string, name: string, start: string, end: string, _owner: string): Promise<Cycle> {
    const f = await this.field(FIELDS.sprint);
    const c = f.configuration!;
    const all = [...c.completedIterations, ...c.iterations];
    const iterations: { startDate: string }[] = iterationsWith(all, { name, start, end });
    await this.updateField(f.id, { iterationConfiguration: { startDate: iterations.map((i) => i.startDate).sort()[0], duration: c.duration, iterations } });
    const made = (await this.cycles(_project)).filter((x) => x.name === name && x.start_date === start).pop();
    if (!made) throw new Error(`github: the sprint ${name} was not made`);
    return made;
  }
  cycleIssues = async (_project: string, cycle: string): Promise<Issue[]> => (await this.items()).filter((i) => i.cycle === cycle) as unknown as Issue[];
  async addToCycle(_project: string, cycle: string, issues: string[]) {
    for (const id of issues) await this.setValue(await this.itemOf(id), FIELDS.sprint, { iterationId: cycle });
  }
  async removeFromCycle(project: string, _cycle: string, issue: string) {
    await this.gql(`mutation($i: ClearProjectV2ItemFieldValueInput!) { clearProjectV2ItemFieldValue(input: $i) { clientMutationId } }`, {
      i: { projectId: project, itemId: await this.itemOf(issue), fieldId: (await this.field(FIELDS.sprint)).id },
    });
  }

  issues = async (_project: string): Promise<Issue[]> => (await this.items()) as unknown as Issue[];
  /** An issue by its key, PRONTO-123: the repository's #123. */
  async issue(key: string): Promise<Issue> {
    const m = new RegExp(`^${this.identifier}-(\\d+)$`, "i").exec(key.trim());
    if (!m) throw new Error(`${key} is not a ${this.identifier} key`);
    return await this.byNumber(Number(m[1]));
  }
  async createIssue(_project: string, f: NewIssue): Promise<Issue> {
    const made = await this.rest("POST", `${this.repo()}/issues`, { title: f.name, body: f.description_html, labels: f.labels });
    const item = await this.itemOf(made.node_id);
    // A new issue starts in the state asked, else the default one.
    const state = f.state || (await this.states(_project)).find((s) => (s as unknown as { default: boolean }).default)?.id;
    if (state) await this.setValue(item, FIELDS.status, { singleSelectOptionId: state });
    const p = ((await this.field(FIELDS.priority)).options ?? []).find((o) => o.name === f.priority);
    if (p) await this.setValue(item, FIELDS.priority, { singleSelectOptionId: p.id });
    return await this.byNumber(made.number);
  }
  async moveIssue(_project: string, id: string, state: string): Promise<Issue> {
    await this.setValue(await this.itemOf(id), FIELDS.status, { singleSelectOptionId: state });
    return await this.byNumber(await this.numberOf(id));
  }
  async describe(_project: string, id: string, html: string): Promise<Issue> {
    const n = await this.numberOf(id);
    await this.rest("PATCH", `${this.repo()}/issues/${n}`, { body: html });
    return await this.byNumber(n);
  }
  comment = async (_project: string, id: string, html: string) => await this.rest("POST", `${this.repo()}/issues/${await this.numberOf(id)}/comments`, { body: html });
  comments = async (_project: string, id: string): Promise<Comment[]> =>
    (await this.restAll(`${this.repo()}/issues/${await this.numberOf(id)}/comments`)).map((c) => ({ html: String(c.body ?? ""), at: String(c.created_at) }));
  links = async (_project: string, id: string) => linksOf(await this.restAll(`${this.repo()}/issues/${await this.numberOf(id)}/comments`));
  link = (project: string, id: string, url: string, title: string) => this.comment(project, id, linkComment(url, title));
}
