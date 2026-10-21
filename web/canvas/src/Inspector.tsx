import type { Agent, Permission } from './api';
import { SKILL_LABEL, modelLabel } from './nodes';

const ORDER: Permission['type'][] = ['agent', 'view', 'function', 'procedure', 'http_host'];

// Hands off to the existing Agents page for edits. The dashboard keeps its
// last page under localStorage `allgres_ui_page` (savedUi in web/index.html).
function openAgentsPage() {
  try {
    localStorage.setItem('allgres_ui_page', 'Agents');
  } catch {
    /* storage blocked: the dashboard opens on its default page instead */
  }
  location.href = '/';
}

export function Inspector({ agent, all, onClose }: { agent: Agent; all: Agent[]; onClose: () => void }) {
  const model = modelLabel(agent.llm_config);
  const children = all.filter((a) => a.parent_agent_id === agent.agent_id);
  const delegatedBy = all.filter((a) => a.permissions.some((p) => p.type === 'agent' && p.ref === agent.name));
  const grouped = ORDER.map((t) => [t, agent.permissions.filter((p) => p.type === t)] as const).filter(([, l]) => l.length);
  const limits: [string, number | null][] = [
    ['Max steps', agent.max_steps],
    ['Max retries', agent.max_retries],
    ['Concurrent tasks', agent.max_concurrent_tasks],
    ['Turn seconds', agent.max_turn_seconds],
    ['Delegation depth', agent.max_delegation_depth],
    ['Tasks per session', agent.max_session_tasks],
  ];
  return (
    <aside className="inspector" aria-label={`${agent.name} details`}>
      <header className="in-head">
        <span className="an-avatar">{agent.name.slice(0, 1).toUpperCase()}</span>
        <div className="in-title">
          <b>{agent.name}</b>
          <small>
            {agent.is_system ? 'System agent' : 'Agent'} · policy generation {agent.generation}
            {agent.is_active ? '' : ' · inactive'}
          </small>
        </div>
        <button type="button" className="icon-btn" onClick={onClose} aria-label="Close details">
          ×
        </button>
      </header>
      <div className="in-body">
        <section>
          <h4>Model</h4>
          {model ? (
            <dl className="kv">
              <dt>Provider</dt>
              <dd>{agent.llm_config?.provider || '—'}</dd>
              <dt>Model</dt>
              <dd className="mono">{agent.llm_config?.model}</dd>
              {agent.llm_config?.temperature !== undefined && (
                <>
                  <dt>Temperature</dt>
                  <dd>{agent.llm_config.temperature}</dd>
                </>
              )}
            </dl>
          ) : (
            <p className="muted">No model yet. Choose a provider and model on the Agents page to activate this agent.</p>
          )}
        </section>
        <section>
          <h4>Hierarchy</h4>
          <dl className="kv">
            <dt>Parent</dt>
            <dd>{agent.parent_name || 'None (top level)'}</dd>
            <dt>Below</dt>
            <dd>{children.length ? children.map((c) => c.name).join(', ') : 'None'}</dd>
            <dt>Delegated from</dt>
            <dd>{delegatedBy.length ? delegatedBy.map((c) => c.name).join(', ') : 'None'}</dd>
            <dt>Autonomy</dt>
            <dd>{agent.autonomy_level.replace('_', ' ')}</dd>
          </dl>
        </section>
        <section>
          <h4>Grants</h4>
          {grouped.length ? (
            grouped.map(([t, list]) => (
              <div className="grant-group" key={t}>
                <div className="muted small">{SKILL_LABEL[t]}</div>
                <ul>
                  {list.map((p) => (
                    <li className="mono" key={p.ref}>
                      {p.ref}
                    </li>
                  ))}
                </ul>
              </div>
            ))
          ) : (
            <p className="muted">No grants. This agent can only answer from its prompt and memory.</p>
          )}
          {agent.execution_rules.length > 0 && <p className="muted small">{agent.execution_rules.length} execution rules apply.</p>}
        </section>
        <section>
          <h4>Limits</h4>
          <dl className="kv">
            {limits.map(([k, v]) => (
              <div className="kv-row" key={k}>
                <dt>{k}</dt>
                <dd className="num">{v ?? 'No cap'}</dd>
              </div>
            ))}
          </dl>
        </section>
        {agent.system_prompt && (
          <section>
            <h4>System prompt</h4>
            <pre className="prompt">{agent.system_prompt}</pre>
          </section>
        )}
      </div>
      <footer className="in-foot">
        <button type="button" className="btn" onClick={openAgentsPage}>
          Edit on Agents page
        </button>
      </footer>
    </aside>
  );
}
