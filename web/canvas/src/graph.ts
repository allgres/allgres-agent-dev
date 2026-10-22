import type { Edge, Node } from '@xyflow/react';
import type { Agent, CanvasState, Group, StoredPosition } from './api';

export const NODE_W = 220;
export const NODE_H = 118;
const GAP_X = 36;
const GAP_Y = 84;
const PAD = 24;
const HEAD = 36;
const CLUSTER_GAP = 120;
const EMPTY_GROUP = { w: 320, h: 180 };

export type RunMark = 'running' | 'done' | 'failed' | 'idle';
export type AgentNodeData = { agent: Agent; below: number; delegatesTo: number; run?: RunMark };
export type GroupNodeData = { group: Group; count: number; depth: number };
export type FrameNodeData = { label: string; count: number };

type XY = { x: number; y: number };
type Size = { w: number; h: number };

export interface Graph {
  nodes: Node[];
  edges: Edge[];
  count: number;
  /** Absolute top-left of every node, for saving and hit-testing. */
  abs: Map<string, XY>;
}

export const groupNodeId = (id: string) => `group:${id}`;
export const isGroupNode = (id: string) => id.startsWith('group:');
export const groupIdOf = (nodeId: string) => nodeId.slice('group:'.length);

// Who sits under whom when nothing has been placed by hand yet. A system
// agent's parent is parent_agent_id, the inheritance edge the database
// already has. An ordinary agent's is the first agent (by name) that may
// delegate to it, so a lead lands above the workers it hands work to;
// cycles fall back to whichever agent the walk reaches first.
function treeOf(list: Agent[], all: Agent[]) {
  const inList = new Set(list.map((a) => a.agent_id));
  const byName = new Map(all.map((a) => [a.name.toLowerCase(), a]));
  const parentOf = new Map<string, string>();
  for (const a of list) {
    if (a.is_system) {
      if (a.parent_agent_id && inList.has(a.parent_agent_id)) parentOf.set(a.agent_id, a.parent_agent_id);
    }
  }
  const delegators = new Map<string, string[]>();
  for (const a of [...list].sort((x, y) => x.name.localeCompare(y.name))) {
    if (a.is_system) continue;
    for (const p of a.permissions) {
      const t = p.type === 'agent' ? byName.get(p.ref.toLowerCase()) : undefined;
      if (t && !t.is_system && inList.has(t.agent_id) && t.agent_id !== a.agent_id) {
        delegators.set(t.agent_id, [...(delegators.get(t.agent_id) || []), a.agent_id]);
      }
    }
  }
  const kids = new Map<string, Agent[]>();
  const placed = new Set<string>();
  const roots: Agent[] = [];
  const attach = (a: Agent) => {
    placed.add(a.agent_id);
    for (const b of list) {
      if (placed.has(b.agent_id)) continue;
      const parent = b.is_system ? parentOf.get(b.agent_id) : (delegators.get(b.agent_id) || [])[0];
      if (parent === a.agent_id) {
        kids.set(a.agent_id, [...(kids.get(a.agent_id) || []), b]);
        attach(b);
      }
    }
  };
  const hasParent = (b: Agent) => (b.is_system ? parentOf.has(b.agent_id) : (delegators.get(b.agent_id) || []).length > 0);
  for (const a of list) if (!hasParent(a)) (roots.push(a), attach(a));
  for (const a of list) if (!placed.has(a.agent_id)) (roots.push(a), attach(a));
  return { roots, kids };
}

// Tree layout of one set of agents, relative to (0, 0).
function layoutTree(list: Agent[], all: Agent[]): { pos: Map<string, XY>; size: Size; kids: Map<string, Agent[]> } {
  const { roots, kids } = treeOf(list, all);
  const pos = new Map<string, XY>();
  const width = (a: Agent): number => {
    const c = kids.get(a.agent_id) || [];
    if (!c.length) return NODE_W;
    return Math.max(NODE_W, c.reduce((s, k) => s + width(k), 0) + GAP_X * (c.length - 1));
  };
  let maxDepth = -1;
  const place = (a: Agent, left: number, depth: number) => {
    maxDepth = Math.max(maxDepth, depth);
    pos.set(a.agent_id, { x: left + (width(a) - NODE_W) / 2, y: depth * (NODE_H + GAP_Y) });
    let x = left;
    for (const k of kids.get(a.agent_id) || []) {
      place(k, x, depth + 1);
      x += width(k) + GAP_X;
    }
  };
  let cursor = 0;
  for (const r of roots) {
    place(r, cursor, 0);
    cursor += width(r) + GAP_X;
  }
  const size = list.length ? { w: cursor - GAP_X, h: (maxDepth + 1) * (NODE_H + GAP_Y) - GAP_Y } : { w: 0, h: 0 };
  return { pos, size, kids };
}

export function buildGraph(
  agents: Agent[],
  state: CanvasState,
  opts: { showSystem: boolean; showInactive: boolean; run?: Map<string, RunMark> },
): Graph {
  const visible = agents.filter((a) => (opts.showInactive || a.is_active) && (opts.showSystem || !a.is_system));
  const byId = new Map(visible.map((a) => [a.agent_id, a]));
  const byName = new Map(agents.map((a) => [a.name.toLowerCase(), a]));
  const stored = new Map<string, StoredPosition>(state.positions.map((p) => [`${p.kind}:${p.id}`, p]));
  const groups = new Map(state.groups.map((g) => [g.group_id, g]));
  const memberOf = new Map<string, string>();
  for (const m of state.members) if (groups.has(m.group_id) && byId.has(m.agent_id)) memberOf.set(m.agent_id, m.group_id);
  const childGroups = (parent: string | null) =>
    state.groups.filter((g) => (g.parent_group_id && groups.has(g.parent_group_id) ? g.parent_group_id : null) === parent);
  const membersOf = (gid: string) => visible.filter((a) => memberOf.get(a.agent_id) === gid);

  // 1. Automatic layout, bottom-up: each group's own agents as a tree, its
  // nested groups in a row underneath, and the box sized to fit.
  const autoRel = new Map<string, XY>(); // node id -> position relative to its container
  const autoSize = new Map<string, Size>();
  const below = new Map<string, number>();
  const treeParent = new Map<string, string>();
  const noteKids = (kids: Map<string, Agent[]>) => {
    for (const [id, k] of kids) {
      below.set(id, k.length);
      for (const c of k) treeParent.set(c.agent_id, id);
    }
  };
  const autoGroup = (g: Group): Size => {
    const t = layoutTree(membersOf(g.group_id), agents);
    for (const [id, p] of t.pos) autoRel.set(id, { x: p.x + PAD, y: p.y + HEAD + PAD });
    noteKids(t.kids);
    let w = t.size.w;
    let y = HEAD + PAD + (t.size.h ? t.size.h + GAP_Y : 0);
    let x = PAD;
    let rowH = 0;
    for (const c of childGroups(g.group_id)) {
      const s = autoGroup(c);
      autoRel.set(groupNodeId(c.group_id), { x, y });
      x += s.w + GAP_X;
      rowH = Math.max(rowH, s.h);
    }
    w = Math.max(w + PAD * 2, x - GAP_X + PAD, EMPTY_GROUP.w);
    const h = Math.max(y + rowH + PAD, EMPTY_GROUP.h);
    const size = { w, h };
    autoSize.set(groupNodeId(g.group_id), size);
    return size;
  };

  // Top level: ungrouped conversation agents, then top-level groups, then
  // the system agents' frame (the same fold the Agents page applies).
  const ungrouped = visible.filter((a) => !a.is_system && !memberOf.has(a.agent_id));
  const top = layoutTree(ungrouped, agents);
  for (const [id, p] of top.pos) autoRel.set(id, p);
  noteKids(top.kids);
  let cursor = top.size.w ? top.size.w + CLUSTER_GAP : 0;
  for (const g of childGroups(null)) {
    const s = autoGroup(g);
    autoRel.set(groupNodeId(g.group_id), { x: cursor, y: -HEAD - PAD });
    cursor += s.w + CLUSTER_GAP;
  }

  // 2. Resolve absolute positions top-down; a stored position wins, and a
  // box grows to cover anything placed inside it.
  const abs = new Map<string, XY>();
  const size = new Map<string, Size>();
  const nodes: Node[] = [];
  // Cards already placed in each container (hand-placed ones first), so an
  // automatically laid out agent never lands on another card and hides its
  // connection dots. The clash distance is just under the tree layout's own
  // spacing, so cards the layout put side by side never push each other.
  const taken = new Map<string, XY[]>();
  const clashes = (key: string, p: XY) =>
    (taken.get(key) || []).some((q) => Math.abs(q.x - p.x) < NODE_W + GAP_X && Math.abs(q.y - p.y) < NODE_H + GAP_Y / 2);
  const placedFirst = (list: Agent[]) =>
    [...list].sort((x, y) => Number(!stored.has(`agent:${x.agent_id}`)) - Number(!stored.has(`agent:${y.agent_id}`)));
  // inside: the top-left corner a card may not cross in its box (past the
  // border and the title), so nothing drawn in a box straddles its edge.
  const agentNode = (a: Agent, parentNode: string | undefined, parentAbs: XY, inside?: XY) => {
    const s = stored.get(`agent:${a.agent_id}`);
    const rel = autoRel.get(a.agent_id) || { x: 0, y: 0 };
    let p = s ? { x: s.x, y: s.y } : { x: parentAbs.x + rel.x, y: parentAbs.y + rel.y };
    // Not placed by hand: follow the nearest tree ancestor that was, so a
    // worker stays under the lead wherever the lead was dragged.
    if (!s) {
      for (let up = treeParent.get(a.agent_id); up; up = treeParent.get(up)) {
        const us = stored.get(`agent:${up}`);
        const ur = autoRel.get(up);
        if (us && ur) {
          p = { x: p.x + us.x - (parentAbs.x + ur.x), y: p.y + us.y - (parentAbs.y + ur.y) };
          break;
        }
      }
      if (!a.is_system) while (clashes(parentNode || '', p)) p = { x: p.x + NODE_W + GAP_X, y: p.y };
    }
    if (inside) p = { x: Math.max(p.x, inside.x), y: Math.max(p.y, inside.y) };
    if (!a.is_system) taken.set(parentNode || '', [...(taken.get(parentNode || '') || []), p]);
    abs.set(a.agent_id, p);
    nodes.push({
      id: a.agent_id,
      type: 'agent',
      position: { x: p.x - parentAbs.x, y: p.y - parentAbs.y },
      parentId: parentNode,
      draggable: !a.is_system,
      data: {
        agent: a,
        below: below.get(a.agent_id) || 0,
        delegatesTo: a.permissions.filter((x) => x.type === 'agent' && byId.has(byName.get(x.ref.toLowerCase())?.agent_id || '')).length,
        run: opts.run?.get(a.agent_id),
      } satisfies AgentNodeData,
    });
    return p;
  };
  const groupNode = (g: Group, parentNode: string | undefined, parentAbs: XY, depth: number, inside?: XY) => {
    const id = groupNodeId(g.group_id);
    const s = stored.get(`group:${g.group_id}`);
    const rel = autoRel.get(id) || { x: 0, y: 0 };
    let p = s ? { x: s.x, y: s.y } : { x: parentAbs.x + rel.x, y: parentAbs.y + rel.y };
    if (inside) p = { x: Math.max(p.x, inside.x), y: Math.max(p.y, inside.y) };
    const within = { x: p.x + PAD, y: p.y + HEAD + 8 };
    abs.set(id, p);
    const index = nodes.length;
    nodes.push({ id, type: 'group', position: { x: p.x - parentAbs.x, y: p.y - parentAbs.y }, parentId: parentNode, data: {} });
    let maxX = 0;
    let maxY = 0;
    for (const a of placedFirst(membersOf(g.group_id))) {
      const q = agentNode(a, id, p, within);
      maxX = Math.max(maxX, q.x - p.x + NODE_W + PAD);
      maxY = Math.max(maxY, q.y - p.y + NODE_H + PAD);
    }
    for (const c of childGroups(g.group_id)) {
      const q = groupNode(c, id, p, depth + 1, within);
      const cs = size.get(groupNodeId(c.group_id))!;
      maxX = Math.max(maxX, q.x - p.x + cs.w + PAD);
      maxY = Math.max(maxY, q.y - p.y + cs.h + PAD);
    }
    const auto = autoSize.get(id) || EMPTY_GROUP;
    const w = Math.max(s?.width ?? auto.w, maxX);
    const h = Math.max(s?.height ?? auto.h, maxY);
    size.set(id, { w, h });
    nodes[index] = {
      ...nodes[index],
      style: { width: w, height: h },
      width: w,
      height: h,
      zIndex: depth - 10,
      data: { group: g, count: membersOf(g.group_id).length, depth } satisfies GroupNodeData,
    };
    return p;
  };

  const origin = { x: 0, y: 0 };
  for (const a of placedFirst(ungrouped)) agentNode(a, undefined, origin);
  for (const g of childGroups(null)) groupNode(g, undefined, origin, 0);

  if (opts.showSystem) {
    const system = visible.filter((a) => a.is_system);
    if (system.length) {
      const t = layoutTree(system, agents);
      noteKids(t.kids);
      // Right of everything else, wherever it was dragged, so nothing ever
      // sits on or inside the frame.
      let right = cursor - CLUSTER_GAP;
      for (const n of nodes) {
        if (n.parentId) continue;
        const q = abs.get(n.id);
        if (q) right = Math.max(right, q.x + (n.type === 'group' ? Number(n.width) : NODE_W));
      }
      const fx = Math.max(cursor, right + CLUSTER_GAP);
      const fy = -HEAD - PAD;
      nodes.push({
        id: 'frame:system',
        type: 'frame',
        position: { x: fx, y: fy },
        data: { label: 'System agents', count: system.length } satisfies FrameNodeData,
        style: { width: t.size.w + PAD * 2, height: t.size.h + HEAD + PAD * 2 },
        draggable: false,
        selectable: false,
        zIndex: -20,
      });
      for (const a of system) {
        const p = t.pos.get(a.agent_id)!;
        autoRel.set(a.agent_id, { x: fx + PAD + p.x, y: fy + HEAD + PAD + p.y });
        // System agents are never moved by hand, so a stale stored
        // position cannot pull one out of its frame.
        stored.delete(`agent:${a.agent_id}`);
        agentNode(a, undefined, origin);
      }
    }
  }

  // 3. Lines. Parent (system inheritance) solid; "may delegate to" dashed.
  const edges: Edge[] = [];
  const parentKeys = new Set<string>();
  for (const a of visible) {
    if (a.parent_agent_id && byId.has(a.parent_agent_id)) {
      const key = `${a.parent_agent_id}>${a.agent_id}`;
      parentKeys.add(key);
      edges.push({
        id: `parent:${key}`,
        source: a.parent_agent_id,
        target: a.agent_id,
        type: 'smoothstep',
        className: 'edge-parent',
        data: { kind: 'parent' },
      });
    }
  }
  for (const a of visible) {
    for (const p of a.permissions) {
      if (p.type !== 'agent') continue;
      const t = byName.get(p.ref.toLowerCase());
      if (!t || !byId.has(t.agent_id) || t.agent_id === a.agent_id) continue;
      const key = `${a.agent_id}>${t.agent_id}`;
      const removable = !a.is_system;
      if (parentKeys.has(key)) {
        const e = edges.find((x) => x.id === `parent:${key}`)!;
        e.className = 'edge-parent edge-delegates';
        e.label = 'delegates';
        continue;
      }
      edges.push({
        id: `delegate:${key}`,
        source: a.agent_id,
        target: t.agent_id,
        className: `edge-delegate${removable ? ' is-removable' : ''}`,
        label: 'delegates',
        interactionWidth: 18,
        data: { kind: 'delegate', from: a.agent_id, to: t.agent_id, removable },
      });
    }
  }
  return { nodes, edges, count: visible.length, abs };
}
