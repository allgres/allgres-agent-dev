import { useEffect, useMemo, useState } from 'react';
import { rpc, type Agent, type Group, type GroupKind, type Permission, type TaskRow } from './api';
import { agentByName, groupOf, type Board } from './board';
import { Chat } from './Chat';
import { groupNodeId, inheritedSkills } from './graph';
import { useT, type T } from './i18n';
import { abilityGroup, abilityLabel, modelName, statusLabel } from './labels';
import { KIND_LABEL } from './nodes';
import { jobOf, withJob } from './prompt';
import { timeAgo } from './ui';

type Tab = 'overview' | 'chat' | 'activity';

// agents.update merges whatever keys it is given into the agent's policy, so
// every change here sends only the fields it touches, and its undo sends the
// same fields with their previous values.
type Patch = Record<string, unknown>;
function change(board: Board, agent: Agent, label: string, patch: Patch, back: Patch) {
  return board.act(label, async () => {
    await rpc('agents.update', { agent_id: agent.agent_id, ...patch });
    return { label, run: () => rpc('agents.update', { agent_id: agent.agent_id, ...back }) };
  });
}

const delegatesTo = (from: Agent, to: Agent) => from.permissions.some((p) => p.type === 'agent' && p.ref.toLowerCase() === to.name.toLowerCase());

export function AgentInspector({ board, agent, onClose }: { board: Board; agent: Agent; onClose: () => void }) {
  const t = useT();
  const [tab, setTab] = useState<Tab>('overview');
  const model = modelName(agent.llm_config);
  const toggle = () => {
    if (!agent.is_active && !model) {
      board.toast(t('Choose a model before turning this agent on.'), true);
      return;
    }
    const on = !agent.is_active;
    change(board, agent, t(on ? '{name} is on' : '{name} is off', { name: agent.name }), { is_active: on }, { is_active: !on });
  };
  return (
    <aside className="inspector" aria-label={agent.name}>
      <header className="in-head">
        <span className={`an-avatar big${agent.is_system ? ' sys' : ''}`} aria-hidden>
          {agent.name.slice(0, 1).toUpperCase()}
        </span>
        <div className="in-title">
          <b>{agent.name}</b>
          <small>{agent.is_system ? t('System agent') : !model ? t('Needs a model') : !agent.is_active ? t('Turned off: it takes no work.') : `${t('Ready')} · ${model}`}</small>
        </div>
        {!agent.is_system && (
          <button type="button" role="switch" aria-checked={agent.is_active} className={`switch${agent.is_active ? ' on' : ''}`} onClick={toggle} title={t(agent.is_active ? 'Turn off' : 'Turn on')}>
            <span />
            <em>{t(agent.is_active ? 'On' : 'Off')}</em>
          </button>
        )}
        <button type="button" className="icon-btn" onClick={onClose} aria-label={t('Close details')}>
          ×
        </button>
      </header>
      <div className="tabs" role="tablist">
        {(['overview', 'chat', 'activity'] as Tab[]).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
            {t(k === 'overview' ? 'Overview' : k === 'chat' ? 'Chat' : 'Activity')}
          </button>
        ))}
      </div>
      <div className="in-body">
        {tab === 'overview' && (agent.is_system ? <SystemOverview board={board} agent={agent} /> : <Overview board={board} agent={agent} key={agent.agent_id + agent.updated_at} />)}
        {tab === 'chat' &&
          (agent.is_active ? (
            <Chat agentId={agent.agent_id} agentName={agent.name} note={t('Goes straight to {name}: the same conversation as the dashboard’s Chat page.', { name: agent.name })} />
          ) : (
            <p className="muted">{t('Turn this agent on to talk to it.')}</p>
          ))}
        {tab === 'activity' && <Activity board={board} agent={agent} />}
      </div>
    </aside>
  );
}

function Overview({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const model = modelName(agent.llm_config);
  return (
    <>
      {!model && (
        <div className="callout warn">
          <b>{t('This agent cannot work yet.')}</b> {t('Choose a model below and turn it on.')}
        </div>
      )}
      <Instructions board={board} agent={agent} />
      <ModelPicker board={board} agent={agent} />
      <TeamSection board={board} agent={agent} />
      <Abilities board={board} agent={agent} />
      <AdvancedSection board={board} agent={agent} />
    </>
  );
}

function Instructions({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  // Usually only the job is shown and edited; the reply protocol in front of
  // it stays as is (prompt.ts). A prompt written whole by hand is shown whole.
  const job = jobOf(agent.system_prompt);
  const raw = job === null;
  const before = raw ? agent.system_prompt || '' : job;
  const [text, setText] = useState(before);
  const dirty = text !== before && (raw ? text.trim() !== '' : true);
  const stored = (v: string) => (raw ? v : withJob(v));
  return (
    <section>
      <h4>{t('What it does')}</h4>
      <textarea
        aria-label={t('What it does')}
        className="prompt-edit"
        rows={5}
        value={text}
        placeholder={t('Describe its job in plain words, the way you would brief a colleague.')}
        onChange={(e) => setText(e.target.value)}
      />
      {raw && <p className="muted small">{t('Written by hand, including how it replies. Change it with care.')}</p>}
      {dirty && (
        <div className="row-end">
          <button type="button" className="btn ghost" onClick={() => setText(before)}>
            {t('Reset')}
          </button>
          <button
            type="button"
            className="btn primary"
            onClick={() => change(board, agent, t('Saved {name}', { name: agent.name }), { system_prompt: stored(text) }, { system_prompt: agent.system_prompt || '' })}
          >
            {t('Save')}
          </button>
        </div>
      )}
    </section>
  );
}

function ModelPicker({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const cur = { provider: agent.llm_config?.provider || '', model: agent.llm_config?.model || '' };
  const choices = board.providers.flatMap((p) => (p.available_models || []).map((m) => ({ provider: p.name, model: m })));
  const curKey = cur.model ? `${cur.provider}::${cur.model}` : '';
  const known = choices.some((c) => `${c.provider}::${c.model}` === curKey);
  const [other, setOther] = useState(!!cur.model && !known);
  const [prov, setProv] = useState(cur.provider || board.providers[0]?.name || '');
  const [name, setName] = useState(known ? '' : cur.model);
  const set = (provider: string, model: string) =>
    change(board, agent, model ? t('Model set to {model}', { model }) : t('No model'), { llm_config: { provider, model } }, { llm_config: cur });
  return (
    <section>
      <h4>{t('Model')}</h4>
      {board.providers.length === 0 ? (
        <p className="muted small">{t('No AI provider is set up yet. Add one under Settings on the dashboard.')}</p>
      ) : (
        <>
          <select
            aria-label={t('Model')}
            value={other ? '__other' : curKey}
            onChange={(e) => {
              const v = e.target.value;
              if (v === '__other') return setOther(true);
              setOther(false);
              if (!v) return set('', '');
              const [p, m] = v.split('::');
              set(p, m);
            }}
          >
            <option value="">{t('No model')}</option>
            {board.providers.map((p) => (
              <optgroup key={p.name} label={p.name}>
                {(p.available_models || []).map((m) => (
                  <option key={m} value={`${p.name}::${m}`}>
                    {m}
                  </option>
                ))}
              </optgroup>
            ))}
            {!known && cur.model && <option value={curKey}>{cur.model}</option>}
            <option value="__other">{t('Other model…')}</option>
          </select>
          {other && (
            <div className="inline gap">
              <select aria-label="Provider" value={prov} onChange={(e) => setProv(e.target.value)}>
                {board.providers.map((p) => (
                  <option key={p.name} value={p.name}>
                    {p.name}
                  </option>
                ))}
              </select>
              <input aria-label={t('Model name')} placeholder={t('Model name')} value={name} onChange={(e) => setName(e.target.value)} />
              <button type="button" className="btn primary" disabled={!name.trim() || !prov} onClick={() => set(prov, name.trim())}>
                {t('Save')}
              </button>
            </div>
          )}
        </>
      )}
    </section>
  );
}

function AgentChips({ list, onRemove, t }: { list: Agent[]; onRemove: (a: Agent) => void; t: T }) {
  if (!list.length) return <p className="muted small">{t('Nobody yet')}</p>;
  return (
    <div className="chips">
      {list.map((a) => (
        <span className="chip agent-chip" key={a.agent_id}>
          {a.name}
          <button type="button" aria-label={t('Remove {name}', { name: a.name })} onClick={() => onRemove(a)}>
            ×
          </button>
        </span>
      ))}
    </div>
  );
}

function AgentAdder({ options, label, onAdd }: { options: Agent[]; label: string; onAdd: (a: Agent) => void }) {
  if (!options.length) return null;
  return (
    <select
      className="adder"
      aria-label={label}
      value=""
      onChange={(e) => {
        const a = options.find((x) => x.agent_id === e.target.value);
        if (a) onAdd(a);
      }}
    >
      <option value="">＋ {label}</option>
      {options.map((a) => (
        <option key={a.agent_id} value={a.agent_id}>
          {a.name}
        </option>
      ))}
    </select>
  );
}

function TeamSection({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const others = board.agents.filter((a) => a.agent_id !== agent.agent_id && !a.is_system);
  const from = board.agents.filter((a) => delegatesTo(a, agent));
  const to = board.agents.filter((a) => delegatesTo(agent, a));
  const gid = groupOf(board.state, agent.agent_id);
  const link = (a: Agent, b: Agent) =>
    board.act(t('{from} can now hand work to {to}', { from: a.name, to: b.name }), async () => {
      await rpc('canvas.delegation.add', { from_agent_id: a.agent_id, to_agent_id: b.agent_id });
      return { label: t('{from} can now hand work to {to}', { from: a.name, to: b.name }), run: () => rpc('canvas.delegation.remove', { from_agent_id: a.agent_id, to_agent_id: b.agent_id }) };
    });
  const unlink = (a: Agent, b: Agent) =>
    board.act(t('{from} no longer hands work to {to}', { from: a.name, to: b.name }), async () => {
      await rpc('canvas.delegation.remove', { from_agent_id: a.agent_id, to_agent_id: b.agent_id });
      return { label: t('{from} no longer hands work to {to}', { from: a.name, to: b.name }), run: () => rpc('canvas.delegation.add', { from_agent_id: a.agent_id, to_agent_id: b.agent_id }) };
    });
  return (
    <section>
      <h4>{t('Team')}</h4>
      <div className="field">
        <label htmlFor="inTeam">{t('In team')}</label>
        <select
          id="inTeam"
          value={gid || ''}
          onChange={(e) => {
            const next = e.target.value || null;
            const team = board.state.groups.find((g) => g.group_id === next)?.name;
            board.act(next ? t('Moved to {team}', { team: team || '' }) : t('Left the team'), async () => {
              await rpc('canvas.groups.set_member', { agent_id: agent.agent_id, group_id: next });
              return { label: t('In team'), run: () => rpc('canvas.groups.set_member', { agent_id: agent.agent_id, group_id: gid }) };
            });
          }}
        >
          <option value="">{t('No team')}</option>
          {board.state.groups.map((g) => (
            <option key={g.group_id} value={g.group_id}>
              {g.name}
            </option>
          ))}
        </select>
      </div>
      {(board.state.secondary || []).some((m) => m.agent_id === agent.agent_id) && (
        <div className="field">
          <label>{t('Also in this team')}</label>
          <div className="chips">
            {(board.state.secondary || [])
              .filter((m) => m.agent_id === agent.agent_id)
              .map((m) => (
                <span className="chip is-secondary" key={m.group_id}>
                  {board.state.groups.find((g) => g.group_id === m.group_id)?.name}
                </span>
              ))}
          </div>
        </div>
      )}
      <div className="field">
        <label>{t('Takes work from')}</label>
        <AgentChips list={from} t={t} onRemove={(a) => (a.is_system ? board.toast(t('System agents are changed only from SQL.'), true) : unlink(a, agent))} />
        <AgentAdder options={others.filter((a) => !delegatesTo(a, agent))} label={t('Add who hands it work')} onAdd={(a) => link(a, agent)} />
      </div>
      <div className="field">
        <label>{t('Hands work to')}</label>
        <AgentChips list={to} t={t} onRemove={(a) => unlink(agent, a)} />
        <AgentAdder options={others.filter((a) => !delegatesTo(agent, a))} label={t('Add who it hands work to')} onAdd={(a) => link(agent, a)} />
      </div>
    </section>
  );
}

function Abilities({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const own = agent.permissions.filter((p) => p.type !== 'agent');
  const inherited = inheritedSkills(agent, board.agents);
  const have = new Set(own.map((p) => `${p.type}:${p.ref.toLowerCase()}`));
  const catalog: { type: 'view' | 'function' | 'procedure'; ref: string }[] = [
    ...board.options.functions.map((ref) => ({ type: 'function' as const, ref })),
    ...board.options.procedures.map((ref) => ({ type: 'procedure' as const, ref })),
    ...board.options.views.map((ref) => ({ type: 'view' as const, ref })),
  ].filter((c) => !have.has(`${c.type}:${c.ref.toLowerCase()}`));
  const groups = [...new Set(catalog.map((c) => abilityGroup(t, c.type)))];
  const remove = (p: Permission) => {
    const what = abilityLabel(t, p.type, p.ref);
    board.act(t('Removed {what}', { what }), async () => {
      await rpc('permissions.revoke', { agent_id: agent.agent_id, type: p.type, ref: p.ref });
      return { label: t('Removed {what}', { what }), run: () => rpc('permissions.grant', { agent_id: agent.agent_id, type: p.type, ref: p.ref }) };
    });
  };
  const add = async (v: string) => {
    if (v === '__host') {
      const r = await board.ask({
        title: t('Let {name} reach a website', { name: agent.name }),
        fields: [{ name: 'host', label: t('Website address'), type: 'text', required: true, placeholder: 'api.example.com' }],
        submit: t('Allow'),
      });
      if (r) board.grant(agent, 'http_host', r.host.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, ''));
      return;
    }
    const [type, ...rest] = v.split(':');
    board.grant(agent, type as 'view' | 'function' | 'procedure', rest.join(':'));
  };
  return (
    <section>
      <h4>{t('Abilities')}</h4>
      {own.length === 0 && inherited.length === 0 && <p className="muted small">{t('It answers only from its instructions and memory.')}</p>}
      <ul className="abilities">
        {own.map((p) => (
          <li key={`${p.type}:${p.ref}`} title={p.ref}>
            <span>{abilityLabel(t, p.type, p.ref)}</span>
            <button type="button" className="icon-btn" aria-label={t('Remove {name}', { name: abilityLabel(t, p.type, p.ref) })} onClick={() => remove(p)}>
              ×
            </button>
          </li>
        ))}
        {inherited.map((p) => (
          <li key={`i:${p.type}:${p.ref}`} className="inherited" title={p.ref}>
            <span>{abilityLabel(t, p.type, p.ref)}</span>
            <small>{t('Inherited from {from}', { from: p.from })}</small>
          </li>
        ))}
      </ul>
      <select className="adder" aria-label={t('Add an ability')} value="" onChange={(e) => e.target.value && add(e.target.value)}>
        <option value="">＋ {t('Add an ability')}</option>
        {groups.map((g) => (
          <optgroup key={g} label={g}>
            {catalog
              .filter((c) => abilityGroup(t, c.type) === g)
              .map((c) => (
                <option key={`${c.type}:${c.ref}`} value={`${c.type}:${c.ref}`}>
                  {abilityLabel(t, c.type, c.ref)}
                </option>
              ))}
            {g === t('Web') && <option value="__host">{t('Website…')}</option>}
          </optgroup>
        ))}
        {!groups.includes(t('Web')) && <option value="__host">{t('Website…')}</option>}
      </select>
    </section>
  );
}

const LIMITS: [string, string, string?][] = [
  ['max_steps', 'Max steps per task'],
  ['max_retries', 'Retries'],
  ['max_concurrent_tasks', 'Tasks at once'],
  ['max_turn_seconds', 'Time limit per turn (seconds)', 'No limit'],
  ['max_delegation_depth', 'How deep it may delegate'],
  ['max_session_tasks', 'Tasks per session'],
];

function AdvancedSection({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const before = useMemo(
    () => ({
      temperature: agent.llm_config?.temperature === undefined ? '' : String(agent.llm_config.temperature),
      max_steps: String(agent.max_steps),
      max_retries: String(agent.max_retries),
      max_concurrent_tasks: String(agent.max_concurrent_tasks),
      max_turn_seconds: agent.max_turn_seconds === null ? '' : String(agent.max_turn_seconds),
      max_delegation_depth: String(agent.max_delegation_depth),
      max_session_tasks: String(agent.max_session_tasks),
      allow_task_model: agent.allow_task_model,
    }),
    [agent],
  );
  const [f, setF] = useState(before);
  const dirty = JSON.stringify(f) !== JSON.stringify(before);
  const body = (v: typeof before): Patch => ({
    llm_config: v.temperature.trim() === '' ? {} : { temperature: Number(v.temperature) },
    max_steps: Number(v.max_steps),
    max_retries: Number(v.max_retries),
    max_concurrent_tasks: Number(v.max_concurrent_tasks),
    max_turn_seconds: v.max_turn_seconds.trim() === '' ? null : Number(v.max_turn_seconds),
    max_delegation_depth: Number(v.max_delegation_depth),
    max_session_tasks: Number(v.max_session_tasks),
  });
  const save = () =>
    board.act(t('Saved {name}', { name: agent.name }), async () => {
      await rpc('agents.update', { agent_id: agent.agent_id, ...body(f) });
      if (f.allow_task_model !== before.allow_task_model) await rpc('agents.set_task_model', { agent_id: agent.agent_id, allowed: f.allow_task_model });
      return {
        label: t('Advanced'),
        run: async () => {
          await rpc('agents.update', { agent_id: agent.agent_id, ...body(before) });
          if (f.allow_task_model !== before.allow_task_model) await rpc('agents.set_task_model', { agent_id: agent.agent_id, allowed: before.allow_task_model });
        },
      };
    });
  return (
    <details className="advanced">
      <summary>{t('Advanced')}</summary>
      <div className="grid2">
        <div className="field">
          <label htmlFor="fTemp">{t('Creativity')}</label>
          <input id="fTemp" inputMode="decimal" value={f.temperature} placeholder={t('Model default')} onChange={(e) => setF({ ...f, temperature: e.target.value })} />
        </div>
        {LIMITS.map(([k, l, ph]) => (
          <div className="field" key={k}>
            <label htmlFor={`f-${k}`}>{t(l)}</label>
            <input id={`f-${k}`} inputMode="numeric" value={f[k as keyof typeof f] as string} placeholder={ph ? t(ph) : undefined} onChange={(e) => setF({ ...f, [k]: e.target.value })} />
          </div>
        ))}
      </div>
      <label className="check">
        <input id="fPerTask" type="checkbox" checked={f.allow_task_model} onChange={(e) => setF({ ...f, allow_task_model: e.target.checked })} />
        <span>
          {t('Let a task choose its own model')}
          <small className="muted"> {t('When you give it a task under Activity, you may pick a different model for that one task.')}</small>
        </span>
      </label>
      {dirty && (
        <div className="row-end">
          <button type="button" className="btn ghost" onClick={() => setF(before)}>
            {t('Reset')}
          </button>
          <button type="button" className="btn primary" id="saveAgent" onClick={save}>
            {t('Save')}
          </button>
        </div>
      )}
    </details>
  );
}

function SystemOverview({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const chain: string[] = [];
  for (let up = board.agents.find((a) => a.agent_id === agent.parent_agent_id); up && !chain.includes(up.name); up = board.agents.find((a) => a.agent_id === up!.parent_agent_id))
    chain.push(up.name);
  const own = agent.permissions.filter((p) => p.type !== 'agent');
  const inherited = inheritedSkills(agent, board.agents);
  return (
    <>
      <p className="muted small">{t("System agents' instructions and abilities are changed only from SQL; autonomy is the one setting here.")}</p>
      <section>
        <h4>{t('Autonomy')}</h4>
        <select
          aria-label={t('Autonomy')}
          value={agent.autonomy_level}
          onChange={(e) => {
            const prev = agent.autonomy_level;
            const next = e.target.value;
            board.act(t('Autonomy'), async () => {
              await rpc('agents.set_autonomy', { agent_id: agent.agent_id, autonomy_level: next });
              return { label: t('Autonomy'), run: () => rpc('agents.set_autonomy', { agent_id: agent.agent_id, autonomy_level: prev }) };
            });
          }}
        >
          <option value="admin_approval">{t('Ask an admin first')}</option>
          <option value="self_approve">{t('Decide, escalate when unsure')}</option>
          <option value="auto">{t('Act on its own')}</option>
        </select>
      </section>
      <section>
        <h4>{t('Team')}</h4>
        <dl className="kv">
          <dt>{t('Inherits from')}</dt>
          <dd>{chain.length ? chain.join(' ← ') : '—'}</dd>
          <dt>{t('Model')}</dt>
          <dd>{modelName(agent.llm_config) || t('No model')}</dd>
        </dl>
      </section>
      <section>
        <h4>{t('Abilities')}</h4>
        <ul className="abilities">
          {own.map((p) => (
            <li key={`${p.type}:${p.ref}`} title={p.ref}>
              <span>{abilityLabel(t, p.type, p.ref)}</span>
            </li>
          ))}
          {inherited.map((p) => (
            <li key={`i:${p.type}:${p.ref}`} className="inherited" title={p.ref}>
              <span>{abilityLabel(t, p.type, p.ref)}</span>
              <small>{t('Inherited from {from}', { from: p.from })}</small>
            </li>
          ))}
        </ul>
      </section>
      {agent.system_prompt && (
        <section>
          <h4>{t('Instructions')}</h4>
          <pre className="prompt">{agent.system_prompt}</pre>
        </section>
      )}
    </>
  );
}

function Activity({ board, agent }: { board: Board; agent: Agent }) {
  const t = useT();
  const [tasks, setTasks] = useState<TaskRow[] | null>(null);
  const [goal, setGoal] = useState('');
  const [pick, setPick] = useState('');
  useEffect(() => {
    let live = true;
    const load = () =>
      rpc<{ tasks: TaskRow[] }>('tasks.list', { limit: 500 })
        .then((r) => live && setTasks(r.tasks.filter((x) => x.agent_id === agent.agent_id)))
        .catch(() => live && setTasks([]));
    load();
    const timer = setInterval(() => document.visibilityState === 'visible' && load(), 20000);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [agent.agent_id]);
  const run = async () => {
    let started: string | null = null;
    const [provider, model] = pick ? pick.split('::') : ['', ''];
    const ok = await board.act(t('Task started on {name}', { name: agent.name }), async () => {
      const r = await rpc<{ session_id: string }>('canvas.run', { agent_id: agent.agent_id, goal: goal.trim(), ...(model ? { provider, model } : {}) });
      started = r.session_id;
    });
    if (ok) {
      setGoal('');
      try {
        localStorage.setItem('allgres_canvas_ran', '1');
      } catch {
        /* storage blocked: the getting-started step just stays open */
      }
      if (started) board.openSession(started);
    }
  };
  return (
    <>
      {agent.is_active && (
        <section>
          <h4>{t('Give it a task')}</h4>
          <textarea aria-label={t('Give it a task')} rows={3} value={goal} placeholder={t('What should {name} do?', { name: agent.name })} onChange={(e) => setGoal(e.target.value)} />
          {agent.allow_task_model && (
            <select aria-label={t('Model for this task (optional)')} value={pick} onChange={(e) => setPick(e.target.value)}>
              <option value="">{t("Agent's model")}</option>
              {board.providers.map((p) => (
                <optgroup key={p.name} label={p.name}>
                  {(p.available_models || []).map((m) => (
                    <option key={m} value={`${p.name}::${m}`}>
                      {m}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          )}
          <div className="row-end">
            <button type="button" className="btn primary" disabled={!goal.trim()} onClick={run}>
              {t('Start')}
            </button>
          </div>
        </section>
      )}
      <section>
        <h4>{t('Recent work')}</h4>
        {tasks === null && <p className="muted">{t('Loading…')}</p>}
        {tasks?.length === 0 && <p className="muted">{t('Nothing yet.')}</p>}
        <ul className="task-list">
          {tasks?.slice(0, 40).map((x) => (
            <li key={x.task_id}>
              <button type="button" onClick={() => board.openSession(x.session_id)}>
                <span className={`status s-${x.status}`}>{statusLabel(t, x.status)}</span>
                <span className="goal">
                  {x.parent_task_id ? '↳ ' : ''}
                  {x.goal}
                </span>
                <small className="muted">{timeAgo(t, x.updated_at)}</small>
              </button>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}

export function GroupInspector({ board, group, onClose }: { board: Board; group: Group; onClose: () => void }) {
  const t = useT();
  const [name, setName] = useState(group.name);
  useEffect(() => setName(group.name), [group.name]);
  const members = board.agents.filter((a) => groupOf(board.state, a.agent_id) === group.group_id);
  const alsoHere = board.agents.filter((a) => (board.state.secondary || []).some((m) => m.agent_id === a.agent_id && m.group_id === group.group_id));
  const within = (gid: string | null): boolean => {
    for (let g = gid; g; g = board.state.groups.find((x) => x.group_id === g)?.parent_group_id || null) if (g === group.group_id) return true;
    return false;
  };
  const others = board.state.groups.filter((g) => !within(g.group_id));
  const update = (label: string, body: Record<string, unknown>, back: Record<string, unknown>) =>
    board.act(label, async () => {
      await rpc('canvas.groups.update', { group_id: group.group_id, ...body });
      return { label, run: () => rpc('canvas.groups.update', { group_id: group.group_id, ...back }) };
    });
  return (
    <aside className="inspector" aria-label={group.name}>
      <header className="in-head">
        <span className="an-avatar big grp" aria-hidden>
          ▢
        </span>
        <div className="in-title">
          <b>{group.name}</b>
          <small>
            {t(KIND_LABEL[group.kind])} · {members.length === 1 ? t('1 agent') : t('{n} agents', { n: members.length })}
          </small>
        </div>
        <button type="button" className="icon-btn" onClick={onClose} aria-label={t('Close details')}>
          ×
        </button>
      </header>
      <div className="in-body">
        <section>
          <form
            className="field"
            onSubmit={(e) => {
              e.preventDefault();
              if (name.trim() && name.trim() !== group.name) update(t('Renamed to {name}', { name: name.trim() }), { name: name.trim() }, { name: group.name });
            }}
          >
            <label htmlFor="gName">{t('Team name')}</label>
            <div className="inline gap">
              <input id="gName" value={name} onChange={(e) => setName(e.target.value)} />
              {name.trim() && name.trim() !== group.name && (
                <button type="submit" className="btn primary">
                  {t('Rename')}
                </button>
              )}
            </div>
          </form>
          <div className="grid2">
            <div className="field">
              <label htmlFor="gKind">{t('Kind')}</label>
              <select id="gKind" value={group.kind} onChange={(e) => update(t(KIND_LABEL[e.target.value as GroupKind]), { kind: e.target.value }, { kind: group.kind })}>
                {Object.entries(KIND_LABEL).map(([k, l]) => (
                  <option key={k} value={k}>
                    {t(l)}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="gParent">{t('Inside')}</label>
              <select
                id="gParent"
                value={group.parent_group_id || ''}
                onChange={(e) =>
                  update(
                    t('Moved'),
                    e.target.value ? { parent_group_id: e.target.value } : { clear_parent: true },
                    group.parent_group_id ? { parent_group_id: group.parent_group_id } : { clear_parent: true },
                  )
                }
              >
                <option value="">{t('Top level')}</option>
                {others.map((g) => (
                  <option key={g.group_id} value={g.group_id}>
                    {g.name}
                  </option>
                ))}
              </select>
            </div>
          </div>
        </section>
        {alsoHere.length > 0 && (
          <section>
            <h4>{t('Also in this team')}</h4>
            <div className="chips">
              {alsoHere.map((a) => (
                <span className="chip agent-chip is-secondary" key={a.agent_id}>
                  <button type="button" className="link" onClick={() => board.select(a.agent_id)}>
                    {a.name}
                  </button>
                </span>
              ))}
            </div>
            <p className="muted small">{t('Their first team sets what they may do. Change this on the Teams page.')}</p>
          </section>
        )}
        <section>
          <h4>{t('Members')}</h4>
          {members.length ? (
            <div className="chips">
              {members.map((a) => (
                <span className="chip agent-chip" key={a.agent_id}>
                  <button type="button" className="link" onClick={() => board.select(a.agent_id)}>
                    {a.name}
                  </button>
                  <button
                    type="button"
                    aria-label={t('Take {name} out of {team}', { name: a.name, team: group.name })}
                    onClick={() =>
                      board.act(t('{name} left {team}', { name: a.name, team: group.name }), async () => {
                        await rpc('canvas.groups.set_member', { agent_id: a.agent_id, group_id: null });
                        return { label: t('{name} left {team}', { name: a.name, team: group.name }), run: () => rpc('canvas.groups.set_member', { agent_id: a.agent_id, group_id: group.group_id }) };
                      })
                    }
                  >
                    ×
                  </button>
                </span>
              ))}
            </div>
          ) : (
            <p className="muted small">{t('Drag agents into the box, or add one with “Add”.')}</p>
          )}
        </section>
        <section className="stack">
          <button
            type="button"
            className="btn"
            disabled={!members.length}
            onClick={async () => {
              const v = await board.ask({
                title: t('Save as a reusable team'),
                body: <p>{t('Saves the agents in this box, their instructions and abilities, and who hands work to whom. Add it again later from “Add”.')}</p>,
                fields: [{ name: 'name', label: t('Name'), type: 'text', value: group.name, required: true }],
                submit: t('Save'),
              });
              if (v) await board.act(t('Saved {name}', { name: v.name.trim() }), async () => void (await rpc('canvas.templates.save', { name: v.name.trim(), group_id: group.group_id })));
            }}
          >
            {t('Save as a reusable team')}
          </button>
          <button
            type="button"
            className="btn"
            disabled={!others.length}
            onClick={async () => {
              const v = await board.ask({
                title: t('Merge {name} into…', { name: group.name }),
                body: <p>{t('Its agents and teams move into the other one and this box goes away. Who hands work to whom stays as it is.')}</p>,
                fields: [{ name: 'target', label: t('Into'), type: 'select', options: others.map((g) => [g.group_id, g.name]) }],
                submit: t('Merge'),
                danger: true,
              });
              if (v)
                await board.act(t('Merged {name}', { name: group.name }), async () => {
                  await rpc('canvas.groups.merge', { source_group_id: group.group_id, target_group_id: v.target });
                  board.select(groupNodeId(v.target));
                });
            }}
          >
            {t('Merge into another team…')}
          </button>
          <button
            type="button"
            className="btn danger-outline"
            onClick={async () => {
              if (await board.confirm(t('Delete {name}?', { name: group.name }), <p>{t('The box goes away; its agents stay on the board.')}</p>, t('Delete team'), true))
                await board.act(t('Deleted {name}', { name: group.name }), async () => {
                  await rpc('canvas.groups.delete', { group_id: group.group_id });
                  onClose();
                });
            }}
          >
            {t('Delete team')}
          </button>
        </section>
      </div>
    </aside>
  );
}

export { agentByName };
