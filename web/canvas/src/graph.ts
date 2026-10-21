import type { Edge, Node } from '@xyflow/react';
import type { Agent } from './api';

export const NODE_W = 220;
export const NODE_H = 118;
const GAP_X = 36;
const GAP_Y = 84;
const FRAME_PAD = 28;
const FRAME_HEAD = 34;
const CLUSTER_GAP = 120;

export type AgentNodeData = { agent: Agent; children: number; delegatesTo: number };
export type FrameNodeData = { label: string; count: number };

// Layout is derived on every load, never stored: the database has no canvas
// positions yet (docs/canvas.md, "Not yet"). Each agent sits under its
// parent_agent_id; everything without a visible parent is a root. System
// agents are laid out as their own cluster so the conversation agents an
// operator works with read first, the same fold the Agents page applies.
export function buildGraph(agents: Agent[], opts: { showSystem: boolean; showInactive: boolean }) {
  const visible = agents.filter((a) => (opts.showInactive || a.is_active) && (opts.showSystem || !a.is_system));
  const byId = new Map(visible.map((a) => [a.agent_id, a]));
  const byName = new Map(visible.map((a) => [a.name, a]));
  const kids = new Map<string, Agent[]>();
  for (const a of visible) {
    if (a.parent_agent_id && byId.has(a.parent_agent_id)) {
      const list = kids.get(a.parent_agent_id) || [];
      list.push(a);
      kids.set(a.parent_agent_id, list);
    }
  }
  const delegations = visible.flatMap((a) =>
    a.permissions
      .filter((p) => p.type === 'agent' && byName.has(p.ref))
      .map((p) => ({ from: a, to: byName.get(p.ref)! })),
  );

  const pos = new Map<string, { x: number; y: number }>();
  const width = (a: Agent): number => {
    const c = kids.get(a.agent_id) || [];
    if (!c.length) return NODE_W;
    return Math.max(NODE_W, c.reduce((s, k) => s + width(k), 0) + GAP_X * (c.length - 1));
  };
  let placed: Agent[] = [];
  const place = (a: Agent, left: number, depth: number) => {
    placed.push(a);
    const w = width(a);
    pos.set(a.agent_id, { x: left + (w - NODE_W) / 2, y: depth * (NODE_H + GAP_Y) });
    let x = left;
    for (const k of kids.get(a.agent_id) || []) {
      place(k, x, depth + 1);
      x += width(k) + GAP_X;
    }
  };
  const roots = (system: boolean) =>
    visible.filter((a) => a.is_system === system && !(a.parent_agent_id && byId.has(a.parent_agent_id)));

  const nodes: Node[] = [];
  let cursor = 0;
  const cluster = (list: Agent[], frame: string | null) => {
    if (!list.length) return;
    const start = cursor;
    placed = [];
    for (const r of list) {
      place(r, cursor, 0);
      cursor += width(r) + GAP_X;
    }
    if (frame) {
      const members = placed;
      const ys = members.map((a) => pos.get(a.agent_id)!.y);
      const maxY = Math.max(...ys) + NODE_H;
      nodes.push({
        id: 'frame:system',
        type: 'frame',
        position: { x: start - FRAME_PAD, y: -FRAME_PAD - FRAME_HEAD },
        data: { label: frame, count: members.length } satisfies FrameNodeData,
        style: { width: cursor - GAP_X - start + FRAME_PAD * 2, height: maxY + FRAME_PAD * 2 + FRAME_HEAD },
        draggable: false,
        selectable: false,
        zIndex: -1,
      });
    }
    cursor += CLUSTER_GAP;
  };
  cluster(roots(false), null);
  if (opts.showSystem) cluster(roots(true), 'System agents');

  for (const a of visible) {
    nodes.push({
      id: a.agent_id,
      type: 'agent',
      position: pos.get(a.agent_id) || { x: 0, y: 0 },
      data: {
        agent: a,
        children: (kids.get(a.agent_id) || []).length,
        delegatesTo: delegations.filter((d) => d.from === a).length,
      } satisfies AgentNodeData,
    });
  }

  const parentKeys = new Set<string>();
  const edges: Edge[] = [];
  for (const a of visible) {
    if (a.parent_agent_id && byId.has(a.parent_agent_id)) {
      const key = `${a.parent_agent_id}>${a.agent_id}`;
      parentKeys.add(key);
      edges.push({ id: `parent:${key}`, source: a.parent_agent_id, target: a.agent_id, type: 'smoothstep', className: 'edge-parent' });
    }
  }
  for (const d of delegations) {
    const key = `${d.from.agent_id}>${d.to.agent_id}`;
    if (parentKeys.has(key)) {
      const e = edges.find((x) => x.id === `parent:${key}`)!;
      e.className = 'edge-parent edge-delegates';
      e.label = 'delegates';
      continue;
    }
    edges.push({ id: `delegate:${key}`, source: d.from.agent_id, target: d.to.agent_id, className: 'edge-delegate', label: 'delegates' });
  }
  return { nodes, edges, count: visible.length };
}
