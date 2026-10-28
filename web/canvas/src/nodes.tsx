import { createContext, useContext } from 'react';
import { Handle, NodeResizer, Position, type NodeProps, type Node } from '@xyflow/react';
import type { AgentNodeData, FrameNodeData, GroupNodeData } from './graph';
import { useT } from './i18n';
import { modelName } from './labels';

export const KIND_LABEL = { team: 'Team', division: 'Division', project: 'Project' } as const;

/**
 * What the board is doing right now that the nodes draw: a finished resize
 * to report back, and the node something is being dragged onto, with the
 * sentence saying what dropping there will do.
 */
export const BoardEvents = createContext<{ onGroupResized: (nodeId: string) => void; dropTarget: string | null; dropText: string | null }>({
  onGroupResized: () => {},
  dropTarget: null,
  dropText: null,
});

const RUN_LABEL = { running: 'Working', done: 'Done', failed: 'Failed', idle: '' } as const;

// A card says three things at a glance: who it is, whether it can work, and
// how much it does. Everything else is one click away in the panel.
export function AgentNode({ id, data, selected }: NodeProps<Node<AgentNodeData>>) {
  const t = useT();
  const { dropTarget, dropText } = useContext(BoardEvents);
  const a = data.agent;
  const model = modelName(a.llm_config);
  const own = a.permissions.filter((p) => p.type !== 'agent').length;
  const state = a.is_system ? 'system' : !model ? 'needs' : !a.is_active ? 'off' : 'ready';
  const status =
    state === 'system' ? t('System agent') : state === 'off' ? t('Inactive') : state === 'needs' ? t('Needs a model') : `${t('Ready')} · ${model}`;
  const cls = [
    'agent-node',
    `st-${state}`,
    selected && 'is-selected',
    a.is_system && 'is-system',
    dropTarget === id && 'is-drop-target',
    data.run && `run-${data.run}`,
    data.connect && `cn-${data.connect}`,
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <div className={cls} data-agent={a.name}>
      <Handle type="target" position={Position.Top} isConnectable={data.connect === 'valid'} />
      {dropTarget === id && dropText && <span className="cn-badge">{dropText}</span>}
      {data.connect === 'valid' && <span className="cn-badge">{t('Drop here')}</span>}
      {data.connect === 'already' && <span className="cn-badge muted">{t('Already hands work here')}</span>}
      {data.connect === 'source' && <span className="cn-badge src">{t('From here')}</span>}
      <div className="an-head">
        <span className="an-avatar" aria-hidden>
          {a.name.slice(0, 1).toUpperCase()}
        </span>
        <div className="an-title">
          <b title={a.name}>{a.name}</b>
          <small className={`an-status s-${state}`}>{status}</small>
        </div>
        {data.run && data.run !== 'idle' && <span className={`run-badge r-${data.run}`}>{t(RUN_LABEL[data.run])}</span>}
      </div>
      <div className="an-foot">
        <span>
          {own === 1 ? t('1 ability') : own ? t('{n} abilities', { n: own }) : t('No abilities yet')}
          {data.inherited.length > 0 && <span className="inh"> {t('+{n} inherited', { n: data.inherited.length })}</span>}
        </span>
        {data.delegatesTo > 0 && <span>{t('leads {n}', { n: data.delegatesTo })}</span>}
      </div>
      {!a.is_system ? (
        <Handle type="source" position={Position.Bottom} isConnectable className="delegate-handle" title={t('Drag onto another agent to hand it work')}>
          <span aria-hidden>+</span>
        </Handle>
      ) : (
        <Handle type="source" position={Position.Bottom} isConnectable={false} />
      )}
    </div>
  );
}

export function GroupNode({ id, data, selected }: NodeProps<Node<GroupNodeData>>) {
  const t = useT();
  const { onGroupResized, dropTarget, dropText } = useContext(BoardEvents);
  const g = data.group;
  return (
    <div className={`group-node k-${g.kind}${selected ? ' is-selected' : ''}${dropTarget === id ? ' is-drop-target' : ''}`} data-group={g.name}>
      <NodeResizer isVisible={selected} minWidth={260} minHeight={150} onResizeEnd={() => onGroupResized(id)} />
      <div className="gn-head">
        <b>{g.name}</b>
        <small>{t(KIND_LABEL[g.kind])}</small>
        <small className="count">{data.count}</small>
      </div>
      {data.also.length > 0 && (
        <div className="gn-also" title={t('Also in this team')}>
          {data.also.map((n) => (
            <span key={n}>{n}</span>
          ))}
        </div>
      )}
      {dropTarget === id && dropText && <span className="gn-drop">{dropText}</span>}
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
