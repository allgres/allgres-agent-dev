import { Handle, Position, type NodeProps, type Node } from '@xyflow/react';
import type { AgentNodeData, FrameNodeData } from './graph';
import type { Permission } from './api';

export const SKILL_LABEL: Record<Permission['type'], string> = {
  view: 'Views',
  function: 'Functions',
  procedure: 'Procedures',
  http_host: 'HTTP hosts',
  agent: 'Delegates',
};

export function modelLabel(cfg: AgentNodeData['agent']['llm_config']): string | null {
  if (!cfg || !cfg.model) return null;
  return cfg.provider ? `${cfg.provider} · ${cfg.model}` : cfg.model;
}

export function AgentNode({ data, selected }: NodeProps<Node<AgentNodeData>>) {
  const a = data.agent;
  const model = modelLabel(a.llm_config);
  const counts = new Map<Permission['type'], number>();
  for (const p of a.permissions) if (p.type !== 'agent') counts.set(p.type, (counts.get(p.type) || 0) + 1);
  const state = !a.is_active ? 'inactive' : !model ? 'draft' : 'ready';
  return (
    <div className={`agent-node${selected ? ' is-selected' : ''}${a.is_system ? ' is-system' : ''}${a.is_active ? '' : ' is-inactive'}`}>
      <Handle type="target" position={Position.Top} isConnectable={false} />
      <div className="an-head">
        <span className="an-avatar">{a.name.slice(0, 1).toUpperCase()}</span>
        <div className="an-title">
          <b title={a.name}>{a.name}</b>
          <small>{a.is_system ? 'System agent' : a.parent_name ? `Under ${a.parent_name}` : 'Top level'}</small>
        </div>
        <span className={`an-state s-${state}`} title={state} />
      </div>
      <div className="an-model">{model || 'No model yet (draft)'}</div>
      <div className="an-chips">
        {[...counts].map(([t, n]) => (
          <span className="chip" key={t}>
            {SKILL_LABEL[t]} {n}
          </span>
        ))}
        {counts.size === 0 && <span className="chip chip-empty">No grants</span>}
      </div>
      <div className="an-foot">
        <span>{a.autonomy_level.replace('_', ' ')}</span>
        <span>
          {data.children ? `${data.children} below` : ''}
          {data.children && data.delegatesTo ? ' · ' : ''}
          {data.delegatesTo ? `delegates to ${data.delegatesTo}` : ''}
        </span>
      </div>
      <Handle type="source" position={Position.Bottom} isConnectable={false} />
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

export const nodeTypes = { agent: AgentNode, frame: FrameNode };
