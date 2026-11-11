// The board the dev flow talks to, as an interface: what board.ts, hook.ts, connect.ts and mcp.ts
// use of it, and nothing of any one board's API. An adapter implements it (plane.ts is Plane's);
// spec.ts's boardOf picks the adapter by the repository's `board.kind`. A board with other words
// (GitHub Projects' items, statuses and iterations) maps them to these: a project holds states, a
// state a group, an issue a state and a priority, a cycle (a sprint) issues, a module (an app)
// issues.

export interface Named { id: string; name: string }
export interface State extends Named { group: string; color: string }
export interface Issue {
  id: string;
  name: string;
  sequence_id: number;
  state: string;
  priority: string;
  description_html?: string;
  module_ids?: string[];
  labels?: string[];
  project?: string;
}
export interface Cycle extends Named { start_date: string | null; end_date: string | null }
export interface Member { id: string; display_name?: string; email?: string }
/** What an issue is made with: its title, a description in HTML, a priority in the board's own word, a state's id and labels' ids. */
export interface NewIssue { name: string; description_html: string; priority: string; state: string; labels: string[] }

export interface Board {
  /** The signed-in member: whoever the token is. */
  me(): Promise<Member>;
  /** The project's members. */
  members(project: string): Promise<Member[]>;

  projects(): Promise<(Named & { identifier: string })[]>;
  createProject(name: string, identifier: string): Promise<Named>;
  /** Turns on what the flow needs of a project: cycles (sprints) and modules (apps). */
  enableFeatures(project: string): Promise<void>;

  states(project: string): Promise<State[]>;
  createState(project: string, s: { name: string; group: string; color: string; description?: string }): Promise<unknown>;
  updateState(project: string, id: string, fields: Record<string, unknown>): Promise<unknown>;
  /** The state new issues start in. */
  setDefaultState(project: string, id: string): Promise<unknown>;

  labels(project: string): Promise<Named[]>;
  createLabel(project: string, name: string, color: string): Promise<Named>;

  modules(project: string): Promise<Named[]>;
  createModule(project: string, name: string, description: string): Promise<Named>;
  addToModule(project: string, module: string, issues: string[]): Promise<unknown>;
  /** Each issue's modules, by name. */
  modulesByIssue(project: string): Promise<Map<string, string[]>>;

  cycles(project: string): Promise<Cycle[]>;
  createCycle(project: string, name: string, start: string, end: string, owner: string): Promise<Cycle>;
  cycleIssues(project: string, cycle: string): Promise<Issue[]>;
  addToCycle(project: string, cycle: string, issues: string[]): Promise<unknown>;
  removeFromCycle(project: string, cycle: string, issue: string): Promise<unknown>;
  /** Moves a cycle's end (a board whose cycles never close, as GitHub's iterations, has none). */
  setCycleEnd?(project: string, cycle: string, end: string): Promise<unknown>;

  issues(project: string): Promise<Issue[]>;
  /** An issue by its key, PRONTO-123. */
  issue(key: string): Promise<Issue>;
  createIssue(project: string, fields: NewIssue): Promise<Issue>;
  /** Moves an issue to a state, by the state's id. */
  moveIssue(project: string, id: string, state: string): Promise<Issue>;
  /** Replaces an issue's description (HTML). */
  describe(project: string, id: string, html: string): Promise<Issue>;
  comment(project: string, id: string, html: string): Promise<unknown>;
  links(project: string, id: string): Promise<{ url: string }[]>;
  link(project: string, id: string, url: string, title: string): Promise<unknown>;
}

/** HTML-escaped text, for a comment. */
export const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
