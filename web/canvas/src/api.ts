// Same transport as web/index.html's api()/rpc(): one POST to
// /api/v1/rpc, the X-Allgres-Client header the CSRF check requires, and the
// dashboard token and login session read from this tab's sessionStorage.
// The canvas holds no state of its own; every value it draws comes back
// from dashboard_rpc, and every change goes through it (sql/canvas.sql).

export class RpcError extends Error {
  constructor(public code: string) {
    super(code);
  }
}

function read(key: string): string {
  try {
    return sessionStorage.getItem(key) || '';
  } catch {
    return '';
  }
}

export async function rpc<T>(action: string, body: Record<string, unknown> = {}): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'X-Allgres-Client': 'canvas',
  };
  const token = read('allgres_token');
  if (token) headers.Authorization = `Bearer ${token}`;
  const session = read('allgres_session_token');
  if (session) headers['X-Allgres-Session'] = session;
  const r = await fetch('/api/v1/rpc', {
    method: 'POST',
    headers,
    body: JSON.stringify({
      action,
      operator_name: read('allgres_operator'),
      session_token: session,
      ...body,
    }),
  });
  if (r.status === 401) throw new RpcError('unauthorized');
  const j = await r.json();
  if (j.ok === false) throw new RpcError(String(j.error || 'request failed'));
  return j as T;
}

export interface Me {
  logged_in: boolean;
  username?: string;
  role?: string;
}

export type GrantType = 'view' | 'function' | 'agent' | 'http_host' | 'procedure';

export interface Permission {
  type: GrantType;
  ref: string;
}

export interface LlmConfig {
  provider?: string;
  model?: string;
  temperature?: number;
  max_tokens?: number;
}

export interface Agent {
  agent_id: string;
  name: string;
  is_active: boolean;
  is_system: boolean;
  parent_agent_id: string | null;
  parent_name: string | null;
  autonomy_level: string;
  allow_task_model: boolean;
  system_prompt: string | null;
  max_steps: number;
  max_retries: number;
  max_concurrent_tasks: number;
  max_turn_seconds: number | null;
  max_delegation_depth: number;
  max_session_tasks: number;
  generation: number;
  llm_config: LlmConfig | null;
  execution_rules: unknown[];
  permissions: Permission[];
  updated_at: string;
}

export type GroupKind = 'team' | 'division' | 'project';

export interface Group {
  group_id: string;
  name: string;
  kind: GroupKind;
  parent_group_id: string | null;
}

export interface StoredPosition {
  kind: 'agent' | 'group';
  id: string;
  x: number;
  y: number;
  width?: number;
  height?: number;
}

export interface TemplateInfo {
  template_id: string;
  name: string;
  agents: number;
  groups: number;
}

export interface CanvasState {
  groups: Group[];
  members: { agent_id: string; group_id: string }[];
  positions: StoredPosition[];
  templates: TemplateInfo[];
}

export interface Provider {
  name: string;
  kind: string;
  available_models: string[] | null;
}

export interface FunctionEntry {
  name: string;
  kind: string;
  description?: string;
  grantable: boolean;
  hint?: string;
}

export interface GrantOptions {
  views: string[];
  /** What a direct `function` grant may name. */
  functions: string[];
  procedures: string[];
  /** Every Function, including fixed-URL http_get and MCP ones that run only through a procedure. */
  function_catalog?: FunctionEntry[];
}

export interface TaskRow {
  task_id: string;
  session_id: string;
  parent_task_id: string | null;
  agent_id: string;
  agent: string;
  status: string;
  step_count: number;
  goal: string;
  error: string | null;
  created_at: string;
  updated_at: string;
}

export interface SessionRow {
  session_id: string;
  agent_id: string;
  agent: string;
  goal: string;
  status: string;
  final_answer: string | null;
  started_at: string;
  completed_at: string | null;
}

export interface SessionDetail {
  session: SessionRow;
  tasks: {
    task_id: string;
    parent_task_id: string | null;
    agent_id: string;
    agent: string;
    delegation_depth: number;
    status: string;
    step_count: number;
    error: string | null;
    created_at: string;
    updated_at: string;
  }[];
  logs: { log_id: string; task_id: string; step_number: number; role: string; content: unknown; created_at: string }[];
}

export interface ChatHistory {
  session_id: string | null;
  status: string | null;
  messages: { role: string; content: string; created_at: string }[];
}

export interface GrantResult {
  applied: boolean;
  missing?: { agent_id: string; name: string; is_system: boolean }[];
  also_granted?: { agent_id: string; name: string }[];
}
