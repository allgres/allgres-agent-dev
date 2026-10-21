// Same transport as web/index.html's api()/rpc(): one POST to
// /api/v1/rpc, the X-Allgres-Client header the CSRF check requires, and the
// dashboard token and login session read from this tab's sessionStorage.
// The canvas holds no state of its own; every value it draws comes back
// from dashboard_rpc.

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

export interface Permission {
  type: 'view' | 'function' | 'agent' | 'http_host' | 'procedure';
  ref: string;
}

export interface Agent {
  agent_id: string;
  name: string;
  is_active: boolean;
  is_system: boolean;
  parent_agent_id: string | null;
  parent_name: string | null;
  autonomy_level: string;
  system_prompt: string | null;
  max_steps: number;
  max_retries: number;
  max_concurrent_tasks: number;
  max_turn_seconds: number | null;
  max_delegation_depth: number;
  max_session_tasks: number;
  generation: number;
  llm_config: { provider?: string; model?: string; temperature?: number; max_tokens?: number } | null;
  execution_rules: unknown[];
  permissions: Permission[];
  updated_at: string;
}
