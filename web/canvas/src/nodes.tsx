import { createContext, useContext } from 'react';
import { Handle, NodeResizer, Position, type NodeProps, type Node } from '@xyflow/react';
import type { AgentNodeData, FrameNodeData, GroupNodeData } from './graph';
import type { GrantType, LlmConfig } from './api';

export const SKILL_LABEL: Record<GrantType, string> = {
  view: 'Views',
  function: 'Functions',
  procedure: 'Procedures',
  http_host: 'HTTP hosts',
  agent: 'Delegates',
};

export const KIND_LABEL = { team: 'Team', division: 'Division', project: 'Project' } as const;

export function modelLabel(cfg: LlmConfig | null): string | null {
  if (!cfg || !cfg.model) return null;
  return cfg.provider ? `${cfg.provider} · ${cfg.model}` : cfg.model;
}

/** Lets a group box report a finished resize back to the board. */
export const BoardEvents = createContext<{ onGroupResized: (nodeId: string) => void; dropTarget: string | null }>({
  onGroupResized: () => {},
  dropTarget: null,
});

const RUN_LABEL = { running: 'Working', done: 'Done', failed: 'Failed', idle: '' } as const;

export function AgentNode({ id, data, selected }: NodeProps<Node<AgentNodeData>>) {
  const { dropTarget } = useContext(BoardEvents);
  const a = data.agent;
  const model = modelLabel(a.llm_config);
  const counts = new Map<GrantType, number>();
  for (const p of a.permissions) if (p.type !== 'agent') counts.set(p.type, (counts.get(p.type) || 0) + 1);
  const state = !a.is_active ? 'inactive' : !model ? 'draft' : 'ready';
  const cls = [
    'agent-node',
    selected && 'is-selected',
    a.is_system && 'is-system',
    !a.is_active && 'is-inactive',
    dropTarget === id && 'is-drop-target',
    data.run && `run-${data.run}`,
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <div className={cls} data-agent={a.name}>
      <Handle type="target" position={Position.Top} isConnectable />
      <div className="an-head">
        <span className="an-avatar">{a.name.slice(0, 1).toUpperCase()}</span>
        <div className="an-title">
          <b title={a.name}>{a.name}</b>
          <small>{a.is_system ? 'System agent' : !a.is_active ? 'Inactive' : model ? 'Ready' : 'Draft · no model yet'}</small>
        </div>
        {data.run && data.run !== 'idle' ? (
          <span className={`run-badge r-${data.run}`}>{RUN_LABEL[data.run]}</span>
        ) : (
          <span className={`an-state s-${state}`} title={state} />
        )}
      </div>
      <div className="an-model">{model || 'No model'}</div>
      <div className="an-chips">
        {[...counts].map(([t, n]) => (
          <span className="chip" key={t}>
            {SKILL_LABEL[t]} {n}
          </span>
        ))}
        {counts.size === 0 && <span className="chip chip-empty">No skills</span>}
      </div>
      <div className="an-foot">
        <span>{a.allow_task_model ? 'model per task' : a.is_system ? a.autonomy_level.replace('_', ' ') : ''}</span>
        <span>
          {data.below ? `${data.below} below` : ''}
          {data.below && data.delegatesTo ? ' · ' : ''}
          {data.delegatesTo ? `delegates to ${data.delegatesTo}` : ''}
        </span>
      </div>
      <Handle type="source" position={Position.Bottom} isConnectable={!a.is_system} title="Drag to an agent this one may delegate to" />
    </div>
  );
}

export function GroupNode({ id, data, selected }: NodeProps<Node<GroupNodeData>>) {
  const { onGroupResized, dropTarget } = useContext(BoardEvents);
  const g = data.group;
  return (
    <div className={`group-node k-${g.kind}${selected ? ' is-selected' : ''}${dropTarget === id ? ' is-drop-target' : ''}`} data-group={g.name}>
      <NodeResizer isVisible={selected} minWidth={240} minHeight={140} onResizeEnd={() => onGroupResized(id)} />
      <div className="gn-head">
        <span className="gn-kind">{KIND_LABEL[g.kind]}</span>
        <b>{g.name}</b>
        <small>{data.count}</small>
      </div>
    </div>
  );
}

export function FrameNode({ data }: NodeProps<Node<FrameNodeData>>) {
  return (
    <div className="frame-node">
      <div className="fn-head">
        <b>{data.label}</b>
        <small>{data.count}</small>
      </div>
    </div>
  );
}

export const nodeTypes = { agent: AgentNode, group: GroupNode, frame: FrameNode };
