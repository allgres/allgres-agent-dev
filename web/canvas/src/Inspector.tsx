import { useEffect, useMemo, useState } from 'react';
import { rpc, type Agent, type Group, type GroupKind, type Permission, type TaskRow } from './api';
import { agentByName, groupOf, type Board } from './board';
import { Chat } from './Chat';
import { groupNodeId, inheritedSkills } from './graph';
import { KIND_LABEL, SKILL_LABEL, modelLabel } from './nodes';
import { timeAgo } from './ui';

type Tab = 'settings' | 'chat' | 'skills' | 'history';
const TABS: [Tab, string][] = [
  ['settings', 'Settings'],
  ['chat', 'Chat'],
  ['skills', 'Skills'],
  ['history', 'History'],
];
const ORDER: Permission['type'][] = ['view', 'function', 'procedure', 'http_host', 'agent'];
const GRANTABLE = ['view', 'function', 'procedure', 'http_host'] as const;

export function AgentInspector({ board, agent, onClose }: { board: Board; agent: Agent; onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('settings');
  return (
    <aside className="inspector" aria-label={`${agent.name} details`}>
      <header className="in-head">
        <span className={`an-avatar${agent.is_system ? ' sys' : ''}`}>{agent.name.slice(0, 1).toUpperCase()}</span>
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
      <div className="tabs" role="tablist">
        {TABS.map(([k, l]) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
            {l}
          </button>
        ))}
      </div>
      <div className="in-body">
        {tab === 'settings' && <Settings board={board} agent={agent} key={agent.agent_id + agent.generation + agent.updated_at} />}
        {tab === 'chat' &&
          (agent.is_active ? (
            <Chat agentId={agent.agent_id} agentName={agent.name} note={`Goes to ${agent.name} directly, the same conversation as the dashboard's Chat page.`} />
          ) : (
            <p className="muted">Activate this agent (Settings) to talk to it.</p>
          ))}
        {tab === 'skills' && <Skills board={board} agent={agent} />}
        {tab === 'history' && <History board={board} agent={agent} />}
      </div>
    </aside>
  );
}

function Hierarchy({ board, agent }: { board: Board; agent: Agent }) {
  const gid = groupOf(board.state, agent.agent_id);
  const group = board.state.groups.find((g) => g.group_id === gid);
  const delegatesTo = agent.permissions.filter((p) => p.type === 'agent').map((p) => p.ref);
  const delegatedBy = board.agents.filter((a) => a.permissions.some((p) => p.type === 'agent' && p.ref.toLowerCase() === agent.name.toLowerCase()));
  const chain: string[] = [];
  for (let up = board.agents.find((a) => a.agent_id === agent.parent_agent_id); up && !chain.includes(up.name); up = board.agents.find((a) => a.agent_id === up!.parent_agent_id))
    chain.push(up.name);
  return (
    <section>
      <h4>Hierarchy</h4>
      <dl className="kv">
        {agent.is_system && (
          <>
            <dt>Inherits from</dt>
            <dd>{chain.length ? chain.join(' ← ') : 'Nothing (top of the chain)'}</dd>
          </>
        )}
        {!agent.is_system && (
          <>
            <dt>Group</dt>
            <dd>
              {group ? (
                <button type="button" className="link" onClick={() => board.select(groupNodeId(group.group_id))}>
                  {group.name}
                </button>
              ) : (
                'None'
              )}
            </dd>
          </>
        )}
        <dt>Can delegate to</dt>
        <dd>{delegatesTo.length ? delegatesTo.join(', ') : 'Nobody'}</dd>
        <dt>Gets work from</dt>
        <dd>{delegatedBy.length ? delegatedBy.map((c) => c.name).join(', ') : 'Nobody'}</dd>
      </dl>
    </section>
  );
}

type Form = {
  system_prompt: string;
  provider: string;
  model: string;
  temperature: string;
  max_steps: string;
  max_retries: string;
  max_concurrent_tasks: string;
  max_turn_seconds: string;
  max_delegation_depth: string;
  max_session_tasks: string;
  is_active: boolean;
  allow_task_model: boolean;
};

const formOf = (a: Agent): Form => ({
  system_prompt: a.system_prompt || '',
  provider: a.llm_config?.provider || '',
  model: a.llm_config?.model || '',
  temperature: a.llm_config?.temperature === undefined ? '' : String(a.llm_config.temperature),
  max_steps: String(a.max_steps),
  max_retries: String(a.max_retries),
  max_concurrent_tasks: String(a.max_concurrent_tasks),
  max_turn_seconds: a.max_turn_seconds === null ? '' : String(a.max_turn_seconds),
  max_delegation_depth: String(a.max_delegation_depth),
  max_session_tasks: String(a.max_session_tasks),
  is_active: a.is_active,
  allow_task_model: a.allow_task_model,
});

// agents.update body for a form, the same keys the Agents page sends.
function updateBody(agentId: string, f: Form) {
  const llm: Record<string, unknown> = { provider: f.provider, model: f.model.trim() };
  if (f.temperature.trim() !== '') llm.temperature = Number(f.temperature);
  return {
    agent_id: agentId,
    system_prompt: f.system_prompt,
    llm_config: llm,
    max_steps: Number(f.max_steps),
    max_retries: Number(f.max_retries),
    max_concurrent_tasks: Number(f.max_concurrent_tasks),
    max_turn_seconds: f.max_turn_seconds.trim() === '' ? null : Number(f.max_turn_seconds),
    max_delegation_depth: Number(f.max_delegation_depth),
    max_session_tasks: Number(f.max_session_tasks),
    is_active: f.is_active,
  };
}

const LIMITS: [keyof Form, string, string][] = [
  ['max_steps', 'Max steps', 'Steps per task'],
  ['max_retries', 'Max retries', ''],
  ['max_concurrent_tasks', 'Concurrent tasks', ''],
  ['max_turn_seconds', 'Turn seconds', 'Blank = no cap'],
  ['max_delegation_depth', 'Delegation depth', ''],
  ['max_session_tasks', 'Tasks per session', ''],
];

function Settings({ board, agent }: { board: Board; agent: Agent }) {
  const before = useMemo(() => formOf(agent), [agent]);
  const [f, setF] = useState<Form>(before);
  const set = <K extends keyof Form>(k: K, v: Form[K]) => setF((x) => ({ ...x, [k]: v }));
  const dirty = JSON.stringify(f) !== JSON.stringify(before);
  const providers = board.providers.map((p) => p.name);
  if (before.provider && !providers.includes(before.provider)) providers.unshift(before.provider);
  const models = board.providers.find((p) => p.name === f.provider)?.available_models || [];

  if (agent.is_system) {
    return (
      <>
        <Hierarchy board={board} agent={agent} />
        <section>
          <h4>Model</h4>
          <p>{modelLabel(agent.llm_config) || <span className="muted">No model</span>}</p>
        </section>
        <section>
          <h4>Autonomy</h4>
          <select
            aria-label="Autonomy"
            value={agent.autonomy_level}
            onChange={(e) => {
              const prev = agent.autonomy_level;
              const next = e.target.value;
              board.act(`Autonomy set to ${next.replace('_', ' ')}`, async () => {
                await rpc('agents.set_autonomy', { agent_id: agent.agent_id, autonomy_level: next });
                return { label: 'autonomy change', run: () => rpc('agents.set_autonomy', { agent_id: agent.agent_id, autonomy_level: prev }) };
              });
            }}
          >
            <option value="admin_approval">Admin approval</option>
            <option value="self_approve">Self approve</option>
            <option value="auto">Auto</option>
          </select>
          <p className="muted small">System agents' identity, prompt, and grants are changed only from SQL; autonomy is the one dial here.</p>
        </section>
        {agent.system_prompt && (
          <section>
            <h4>System prompt</h4>
            <pre className="prompt">{agent.system_prompt}</pre>
          </section>
        )}
      </>
    );
  }

  const save = async () => {
    if (f.is_active && (!f.provider || !f.model.trim())) {
      board.toast('Choose a provider and model before activating, or leave the agent inactive.', true);
      return;
    }
    const prev = before;
    await board.act(`Saved ${agent.name}`, async () => {
      await rpc('agents.update', updateBody(agent.agent_id, f));
      if (f.allow_task_model !== prev.allow_task_model)
        await rpc('agents.set_task_model', { agent_id: agent.agent_id, allowed: f.allow_task_model });
      return {
        label: `settings of ${agent.name}`,
        run: async () => {
          await rpc('agents.update', updateBody(agent.agent_id, prev));
          if (f.allow_task_model !== prev.allow_task_model)
            await rpc('agents.set_task_model', { agent_id: agent.agent_id, allowed: prev.allow_task_model });
        },
      };
    });
  };

  return (
    <>
      <Hierarchy board={board} agent={agent} />
      <section>
        <h4>Model</h4>
        <div className="grid2">
          <div className="field">
            <label htmlFor="fProvider">Provider</label>
            <select id="fProvider" value={f.provider} onChange={(e) => set('provider', e.target.value)}>
              <option value="">None</option>
              {providers.map((p) => (
                <option key={p} value={p}>
                  {p}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="fModel">Model</label>
            <input id="fModel" value={f.model} list="fModelList" onChange={(e) => set('model', e.target.value)} autoComplete="off" />
            <datalist id="fModelList">
              {models.map((m) => (
                <option key={m} value={m} />
              ))}
            </datalist>
          </div>
        </div>
        <div className="field">
          <label htmlFor="fTemp">Temperature</label>
          <input id="fTemp" inputMode="decimal" value={f.temperature} placeholder="Provider default" onChange={(e) => set('temperature', e.target.value)} />
        </div>
        <label className="check">
          <input id="fPerTask" type="checkbox" checked={f.allow_task_model} onChange={(e) => set('allow_task_model', e.target.checked)} />
          <span>
            Allow a model per task
            <small className="muted"> A task started from History may name its own model; that one task then runs on it instead of this default.</small>
          </span>
        </label>
        {!board.providers.length && <p className="muted small">No chat provider is enabled yet. Add one in Settings on the dashboard.</p>}
      </section>
      <section>
        <h4>System prompt</h4>
        <textarea aria-label="System prompt" className="prompt-edit" rows={6} value={f.system_prompt} onChange={(e) => set('system_prompt', e.target.value)} />
      </section>
      <section>
        <h4>Limits</h4>
        <div className="grid2">
          {LIMITS.map(([k, l, hint]) => (
            <div className="field" key={k}>
              <label htmlFor={`f-${k}`}>{l}</label>
              <input
                id={`f-${k}`}
                inputMode="numeric"
                value={f[k] as string}
                placeholder={hint}
                onChange={(e) => set(k, e.target.value as never)}
              />
            </div>
          ))}
        </div>
      </section>
      <section>
        <label className="check">
          <input id="fActive" type="checkbox" checked={f.is_active} onChange={(e) => set('is_active', e.target.checked)} />
          <span>
            Active
            <small className="muted"> Inactive agents take no tasks and are hidden unless Inactive is checked.</small>
          </span>
        </label>
      </section>
      <div className="sticky-actions">
        <button type="button" className="btn" disabled={!dirty} onClick={() => setF(before)}>
          Reset
        </button>
        <button type="button" className="btn primary" disabled={!dirty} onClick={save} id="saveAgent">
          Save
        </button>
      </div>
    </>
  );
}

function Skills({ board, agent }: { board: Board; agent: Agent }) {
  const [type, setType] = useState<(typeof GRANTABLE)[number]>('function');
  const [ref, setRef] = useState('');
  const choices = type === 'view' ? board.options.views : type === 'function' ? board.options.functions : type === 'procedure' ? board.options.procedures : [];
  const grouped = ORDER.map((t) => [t, agent.permissions.filter((p) => p.type === t)] as const).filter(([, l]) => l.length);
  const inherited = inheritedSkills(agent, board.agents);
  const locked = agent.is_system;

  const revoke = (p: Permission) => {
    if (p.type === 'agent') {
      const to = agentByName(board.agents, p.ref);
      return board.act(`${agent.name} no longer delegates to ${p.ref}`, async () => {
        if (to) await rpc('canvas.delegation.remove', { from_agent_id: agent.agent_id, to_agent_id: to.agent_id });
        else await rpc('permissions.revoke', { agent_id: agent.agent_id, type: 'agent', ref: p.ref });
        return { label: 'delegation removal', run: () => rpc('permissions.grant', { agent_id: agent.agent_id, type: 'agent', ref: p.ref }) };
      });
    }
    const holders = board.agents.filter(
      (a) => a.agent_id !== agent.agent_id && a.permissions.some((x) => x.type === p.type && x.ref.toLowerCase() === p.ref.toLowerCase()),
    );
    return board.act(`Removed ${p.ref} from ${agent.name}`, async () => {
      await rpc('permissions.revoke', { agent_id: agent.agent_id, type: p.type, ref: p.ref });
      if (holders.length) board.toast(`Removed. ${holders.map((h) => h.name).join(', ')} still hold ${p.ref}.`);
      return { label: `removal of ${p.ref}`, run: () => rpc('permissions.grant', { agent_id: agent.agent_id, type: p.type, ref: p.ref }) };
    });
  };

  return (
    <>
      <section>
        <h4>Skills</h4>
        {grouped.length || inherited.length ? (
          grouped.map(([t, list]) => (
            <div className="grant-group" key={t}>
              <div className="muted small">{SKILL_LABEL[t]}</div>
              {list.map((p) => (
                <div className="skill-row" key={p.ref}>
                  <span className="mono">{p.ref}</span>
                  {!locked && (
                    <button type="button" className="icon-btn" aria-label={`Remove ${p.ref}`} title="Remove" onClick={() => revoke(p)}>
                      ×
                    </button>
                  )}
                </div>
              ))}
            </div>
          ))
        ) : (
          <p className="muted">No skills. This agent can only answer from its prompt and memory.</p>
        )}
        {inherited.length > 0 && (
          <div className="grant-group">
            <div className="muted small">Inherited (from the agents it inherits from; change them there, in SQL)</div>
            {inherited.map((p) => (
              <div className="skill-row inherited" key={`${p.type}:${p.ref}`}>
                <span className="mono">{p.ref}</span>
                <small className="muted">
                  {SKILL_LABEL[p.type as Permission['type']]} · from {p.from}
                </small>
              </div>
            ))}
          </div>
        )}
        {agent.execution_rules.length > 0 && <p className="muted small">{agent.execution_rules.length} execution rules apply.</p>}
      </section>
      {!locked && (
        <section>
          <h4>Add a skill</h4>
          <form
            className="add-skill"
            onSubmit={async (e) => {
              e.preventDefault();
              if (ref.trim() && (await board.grant(agent, type, ref.trim()))) setRef('');
            }}
          >
            <select aria-label="Skill type" value={type} onChange={(e) => (setType(e.target.value as typeof type), setRef(''))}>
              {GRANTABLE.map((t) => (
                <option key={t} value={t}>
                  {SKILL_LABEL[t]}
                </option>
              ))}
            </select>
            {type === 'http_host' ? (
              <input aria-label="Host name" value={ref} placeholder="api.example.com" onChange={(e) => setRef(e.target.value)} />
            ) : (
              <select aria-label="Skill" value={ref} onChange={(e) => setRef(e.target.value)}>
                <option value="">Choose…</option>
                {choices.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            )}
            <button type="submit" className="btn" disabled={!ref.trim()}>
              Add
            </button>
          </form>
          <p className="muted small">
            You can also drag a skill from the palette onto the agent. An agent may hold a skill only if every agent that can delegate to it holds it
            too; Canvas offers to grant those as well.
          </p>
        </section>
      )}
    </>
  );
}

function History({ board, agent }: { board: Board; agent: Agent }) {
  const [tasks, setTasks] = useState<TaskRow[] | null>(null);
  const [goal, setGoal] = useState('');
  const [provider, setProvider] = useState('');
  const [model, setModel] = useState('');
  useEffect(() => {
    let live = true;
    const load = () =>
      rpc<{ tasks: TaskRow[] }>('tasks.list', { limit: 500 })
        .then((r) => live && setTasks(r.tasks.filter((t) => t.agent_id === agent.agent_id)))
        .catch(() => live && setTasks([]));
    load();
    const t = setInterval(() => document.visibilityState === 'visible' && load(), 20000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [agent.agent_id]);
  const models = board.providers.find((p) => p.name === provider)?.available_models || [];

  const run = async () => {
    let started: string | null = null;
    const ok = await board.act(`Task started on ${agent.name}`, async () => {
      const r = await rpc<{ session_id: string }>('canvas.run', {
        agent_id: agent.agent_id,
        goal: goal.trim(),
        ...(agent.allow_task_model && model.trim() ? { provider, model: model.trim() } : {}),
      });
      started = r.session_id;
    });
    if (ok) {
      setGoal('');
      if (started) board.openSession(started);
    }
  };

  return (
    <>
      {agent.is_active && (
        <section>
          <h4>Give a task</h4>
          <textarea aria-label="Task" rows={3} value={goal} placeholder={`What should ${agent.name} do?`} onChange={(e) => setGoal(e.target.value)} />
          {agent.allow_task_model && (
            <div className="grid2">
              <select aria-label="Provider for this task" value={provider} onChange={(e) => setProvider(e.target.value)}>
                <option value="">Provider (agent default)</option>
                {board.providers.map((p) => (
                  <option key={p.name} value={p.name}>
                    {p.name}
                  </option>
                ))}
              </select>
              <input aria-label="Model for this task" list="taskModelList" value={model} placeholder="Model (agent default)" onChange={(e) => setModel(e.target.value)} />
              <datalist id="taskModelList">
                {models.map((m) => (
                  <option key={m} value={m} />
                ))}
              </datalist>
            </div>
          )}
          <div className="row-end">
            <button type="button" className="btn primary" disabled={!goal.trim()} onClick={run}>
              Start task
            </button>
          </div>
        </section>
      )}
      <section>
        <h4>Recent tasks</h4>
        {tasks === null && <p className="muted">Loading…</p>}
        {tasks?.length === 0 && <p className="muted">No tasks yet.</p>}
        <ul className="task-list">
          {tasks?.slice(0, 40).map((t) => (
            <li key={t.task_id}>
              <button type="button" onClick={() => board.openSession(t.session_id)}>
                <span className={`status s-${t.status}`}>{t.status.replace('_', ' ')}</span>
                <span className="goal">{t.parent_task_id ? '↳ ' : ''}{t.goal}</span>
                <small className="muted">{timeAgo(t.updated_at)}</small>
              </button>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}

export function GroupInspector({ board, group, onClose }: { board: Board; group: Group; onClose: () => void }) {
  const [name, setName] = useState(group.name);
  useEffect(() => setName(group.name), [group.name]);
  const members = board.agents.filter((a) => groupOf(board.state, a.agent_id) === group.group_id);
  const within = (gid: string | null): boolean => {
    for (let g = gid; g; g = board.state.groups.find((x) => x.group_id === g)?.parent_group_id || null) if (g === group.group_id) return true;
    return false;
  };
  const others = board.state.groups.filter((g) => !within(g.group_id));
  const children = board.state.groups.filter((g) => g.parent_group_id === group.group_id);

  const update = (label: string, body: Record<string, unknown>, back: Record<string, unknown>) =>
    board.act(label, async () => {
      await rpc('canvas.groups.update', { group_id: group.group_id, ...body });
      return { label, run: () => rpc('canvas.groups.update', { group_id: group.group_id, ...back }) };
    });

  return (
    <aside className="inspector" aria-label={`${group.name} details`}>
      <header className="in-head">
        <span className="an-avatar grp">▢</span>
        <div className="in-title">
          <b>{group.name}</b>
          <small>
            {KIND_LABEL[group.kind]} · {members.length} agents{children.length ? ` · ${children.length} groups inside` : ''}
          </small>
        </div>
        <button type="button" className="icon-btn" onClick={onClose} aria-label="Close details">
          ×
        </button>
      </header>
      <div className="in-body">
        <section>
          <form
            className="field"
            onSubmit={(e) => {
              e.preventDefault();
              if (name.trim() && name.trim() !== group.name) update(`Renamed to ${name.trim()}`, { name: name.trim() }, { name: group.name });
            }}
          >
            <label htmlFor="gName">Name</label>
            <div className="inline">
              <input id="gName" value={name} onChange={(e) => setName(e.target.value)} />
              <button type="submit" className="btn" disabled={!name.trim() || name.trim() === group.name}>
                Rename
              </button>
            </div>
          </form>
          <div className="grid2">
            <div className="field">
              <label htmlFor="gKind">Kind</label>
              <select
                id="gKind"
                value={group.kind}
                onChange={(e) => update(`${group.name} is now a ${e.target.value}`, { kind: e.target.value as GroupKind }, { kind: group.kind })}
              >
                {Object.entries(KIND_LABEL).map(([k, l]) => (
                  <option key={k} value={k}>
                    {l}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="gParent">Inside</label>
              <select
                id="gParent"
                value={group.parent_group_id || ''}
                onChange={(e) =>
                  update(
                    'Moved group',
                    e.target.value ? { parent_group_id: e.target.value } : { clear_parent: true },
                    group.parent_group_id ? { parent_group_id: group.parent_group_id } : { clear_parent: true },
                  )
                }
              >
                <option value="">Top level</option>
                {others.map((g) => (
                  <option key={g.group_id} value={g.group_id}>
                    {g.name}
                  </option>
                ))}
              </select>
            </div>
          </div>
        </section>
        <section>
          <h4>Agents</h4>
          {members.length ? (
            members.map((a) => (
              <div className="skill-row" key={a.agent_id}>
                <button type="button" className="link" onClick={() => board.select(a.agent_id)}>
                  {a.name}
                </button>
                <button
                  type="button"
                  className="icon-btn"
                  aria-label={`Take ${a.name} out of ${group.name}`}
                  title="Take out of group"
                  onClick={() =>
                    board.act(`${a.name} left ${group.name}`, async () => {
                      await rpc('canvas.groups.set_member', { agent_id: a.agent_id, group_id: null });
                      return { label: 'leaving the group', run: () => rpc('canvas.groups.set_member', { agent_id: a.agent_id, group_id: group.group_id }) };
                    })
                  }
                >
                  ×
                </button>
              </div>
            ))
          ) : (
            <p className="muted">Drag agents into the box, or drop an Agent block on it.</p>
          )}
        </section>
        <section className="stack">
          <button
            type="button"
            className="btn"
            disabled={!members.length && !children.length}
            onClick={async () => {
              const v = await board.ask({
                title: 'Save as configuration',
                body: <p>Saves this group, the groups inside it, its agents' settings and skills, and the delegation lines between them. Drop it from the palette to create a copy with new agents.</p>,
                fields: [{ name: 'name', label: 'Name', type: 'text', value: group.name, required: true }],
                submit: 'Save',
              });
              if (v) await board.act(`Saved configuration ${v.name}`, async () => void (await rpc('canvas.templates.save', { name: v.name.trim(), group_id: group.group_id })));
            }}
          >
            Save as configuration
          </button>
          <button
            type="button"
            className="btn"
            disabled={!others.length}
            onClick={async () => {
              const v = await board.ask({
                title: `Merge ${group.name} into…`,
                body: <p>Its agents and groups move into the target and this box is removed. Delegation lines stay as they are. This is recorded in the audit log and cannot be undone from Canvas.</p>,
                fields: [{ name: 'target', label: 'Into', type: 'select', options: others.map((g) => [g.group_id, g.name]) }],
                submit: 'Merge',
                danger: true,
              });
              if (v)
                await board.act(`Merged ${group.name}`, async () => {
                  await rpc('canvas.groups.merge', { source_group_id: group.group_id, target_group_id: v.target });
                  board.select(groupNodeId(v.target));
                });
            }}
          >
            Merge into another group…
          </button>
          <button
            type="button"
            className="btn danger-outline"
            onClick={async () => {
              if (
                await board.confirm(
                  `Delete ${group.name}?`,
                  <p>The box goes away; its {members.length} agents and any groups inside move up a level. No agent is deleted.</p>,
                  'Delete group',
                  true,
                )
              )
                await board.act(`Deleted ${group.name}`, async () => {
                  await rpc('canvas.groups.delete', { group_id: group.group_id });
                  onClose();
                });
            }}
          >
            Delete group
          </button>
        </section>
      </div>
    </aside>
  );
}
