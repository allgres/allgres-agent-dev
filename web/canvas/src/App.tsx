import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent } from 'react';
import {
  Background,
  MiniMap,
  ReactFlow,
  ReactFlowProvider,
  useNodesInitialized,
  useNodesState,
  MarkerType,
  useReactFlow,
  useViewport,
  type Connection,
  type Edge,
  type Node,
} from '@xyflow/react';
import { rpc, RpcError, type Agent, type CanvasState, type GrantOptions, type GrantResult, type Provider, type StoredPosition } from './api';
import { agentByName, groupOf, type Board, type Undo } from './board';
import { Chat } from './Chat';
import { FlowPanel, type FlowOverlay } from './FlowPanel';
import { buildGraph, groupIdOf, groupNodeId, isGroupNode, LINE, NODE_H, NODE_W, type ConnectMark, type RunMark } from './graph';
import { AgentInspector, GroupInspector } from './Inspector';
import { BoardEvents, nodeTypes } from './nodes';
import { DRAG_MIME, Palette, type PaletteItem } from './Palette';
import { useDialog, useToast } from './ui';

type Gate = { kind: 'loading' } | { kind: 'blocked'; title: string; body: string } | { kind: 'ready' };
type XY = { x: number; y: number };

const EMPTY_STATE: CanvasState = { groups: [], members: [], positions: [], templates: [] };
const NO_OPTIONS: GrantOptions = { views: [], functions: [], procedures: [] };

function theme(): 'dark' | 'light' {
  try {
    return localStorage.getItem('allgres_theme') === 'light' ? 'light' : 'dark';
  } catch {
    return 'dark';
  }
}

function remembered(key: string, fallback: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : v === '1';
  } catch {
    return fallback;
  }
}

function remember(key: string, v: boolean) {
  try {
    localStorage.setItem(key, v ? '1' : '0');
  } catch {
    /* storage blocked: the setting lasts until reload */
  }
}

function explain(e: unknown): { title: string; body: string } {
  const code = e instanceof RpcError ? e.code : String(e);
  if (code === 'unauthorized')
    return { title: 'Dashboard token required', body: 'Open the dashboard in this tab, enter the dashboard token, then come back to Canvas.' };
  if (/not logged in/i.test(code)) return { title: 'Sign in first', body: 'Sign in on the dashboard in this tab, then open Canvas from the menu.' };
  if (/admin/i.test(code)) return { title: 'Admins only', body: 'Canvas shows and changes every agent and its grants, so it needs an admin account.' };
  return { title: 'Canvas could not load', body: code };
}

const message = (e: unknown) => (e instanceof RpcError ? e.code : e instanceof Error ? e.message : String(e));
const inputFocused = () => {
  const el = document.activeElement;
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || (el as HTMLElement).isContentEditable);
};

function Canvas() {
  const [gate, setGate] = useState<Gate>({ kind: 'loading' });
  const [agents, setAgents] = useState<Agent[]>([]);
  const [state, setState] = useState<CanvasState>(EMPTY_STATE);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [options, setOptions] = useState<GrantOptions>(NO_OPTIONS);
  const [showSystem, setShowSystem] = useState(true);
  const [showInactive, setShowInactive] = useState(false);
  const [view, setView] = useState<'org' | 'flow'>('org');
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [overlay, setOverlay] = useState<FlowOverlay | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [dockOpen, setDockOpen] = useState(() => remembered('allgres_canvas_dock', window.innerWidth > 760));
  const [undoCount, setUndoCount] = useState(0);
  const undos = useRef<Undo[]>([]);
  const flow = useReactFlow();
  const { zoom } = useViewport();
  const { ask, confirm, element: dialog } = useDialog();
  const { toast, element: toastEl } = useToast();

  // One request: canvas.state carries agents.list's payload as well.
  const reload = useCallback(async () => {
    const s = await rpc<CanvasState & { agents: Agent[] }>('canvas.state');
    setAgents(s.agents);
    setState(s);
  }, []);

  const loadOptions = useCallback(async () => {
    // providers.available needs a signed-in account; without one the model
    // pickers simply list nothing.
    const [p, o] = await Promise.all([
      rpc<{ providers: Provider[] }>('providers.available').catch(() => ({ providers: [] })),
      rpc<GrantOptions>('permissions.options').catch(() => NO_OPTIONS),
    ]);
    setProviders(p.providers);
    setOptions({ views: o.views || [], functions: o.functions || [], procedures: o.procedures || [] });
  }, []);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme());
    (async () => {
      try {
        await reload();
        await loadOptions();
        setGate({ kind: 'ready' });
      } catch (e) {
        setGate({ kind: 'blocked', ...explain(e) });
      }
    })();
  }, [reload, loadOptions]);

  // Other operators, the dashboard, and agents themselves change this data,
  // so the board re-reads it whenever the tab comes back into view.
  useEffect(() => {
    const onFocus = () => document.visibilityState === 'visible' && gate.kind === 'ready' && reload().catch(() => {});
    document.addEventListener('visibilitychange', onFocus);
    return () => document.removeEventListener('visibilitychange', onFocus);
  }, [gate.kind, reload]);

  const pushUndo = (u: Undo) => {
    undos.current.push(u);
    if (undos.current.length > 50) undos.current.shift();
    setUndoCount(undos.current.length);
  };

  const act = useCallback<Board['act']>(
    async (label, fn, opts) => {
      try {
        const u = await fn();
        if (u) pushUndo(u);
        toast(label);
        if (!opts?.layoutOnly) await reload();
        return true;
      } catch (e) {
        toast(message(e), true);
        await reload().catch(() => {});
        return false;
      }
    },
    [reload, toast],
  );

  const undo = useCallback(async () => {
    const u = undos.current.pop();
    setUndoCount(undos.current.length);
    if (!u) return;
    try {
      await u.run();
      toast(`Undid ${u.label}`);
    } catch (e) {
      toast(`Could not undo ${u.label}: ${message(e)}`, true);
    }
    await reload().catch(() => {});
  }, [reload, toast]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === 'z' && !inputFocused()) {
        e.preventDefault();
        undo();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [undo]);

  // canvas.grant reports the ceiling gap instead of failing; turn that into
  // a question, then grant to everyone above in one transaction.
  const grantWithCeiling = useCallback<Board['grant']>(
    async (agent, type, ref) => {
      let r: GrantResult;
      try {
        r = await rpc<GrantResult>('canvas.grant', { agent_id: agent.agent_id, type, ref });
      } catch (e) {
        toast(message(e), true);
        return false;
      }
      const stored = type === 'http_host' ? ref.toLowerCase() : ref;
      const revokeAll = (list: { agent_id: string }[]) => async () => {
        for (const x of list) await rpc('permissions.revoke', { agent_id: x.agent_id, type, ref: stored });
      };
      if (r.applied) {
        pushUndo({ label: `grant of ${ref}`, run: revokeAll([agent]) });
        toast(`${agent.name} can now use ${ref}`);
        await reload();
        return true;
      }
      const missing = r.missing || [];
      if (missing.some((m) => m.is_system)) {
        await confirm(
          'Cannot grant this here',
          <p>
            {missing.filter((m) => m.is_system).map((m) => m.name).join(', ')} can delegate to {agent.name} and lacks {ref}, but system agents' grants are
            changed only from SQL.
          </p>,
          'OK',
        );
        return false;
      }
      const yes = await confirm(
        `Grant ${ref} above ${agent.name} too?`,
        <>
          <p>
            An agent may hold a skill only if every agent that can delegate to it holds it too. These agents are above {agent.name} and lack{' '}
            <code>{ref}</code>:
          </p>
          <ul>
            {missing.map((m) => (
              <li key={m.agent_id}>{m.name}</li>
            ))}
          </ul>
        </>,
        `Grant to all ${missing.length + 1}`,
      );
      if (!yes) return false;
      return act(`Granted ${ref} to ${agent.name} and ${missing.length} above`, async () => {
        const x = await rpc<GrantResult>('canvas.grant', { agent_id: agent.agent_id, type, ref, include_superiors: true });
        return { label: `grant of ${ref}`, run: revokeAll([agent, ...(x.also_granted || [])]) };
      });
    },
    [act, confirm, reload, toast],
  );

  const select = useCallback(
    (id: string | null) => {
      setSelected(id ? [id] : []);
      flowSetSelected(id);
      if (id) requestAnimationFrame(() => flow.fitView({ nodes: [{ id }], duration: 300, maxZoom: 1.1, padding: 0.6 }));
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [flow],
  );

  const openSession = useCallback((id: string) => {
    setView('flow');
    setSessionId(id);
  }, []);

  const board: Board = { agents, state, providers, options, act, grant: grantWithCeiling, ask, confirm, toast, select, openSession };

  // ---------------------------------------------------------------- graph
  const runMarks = useMemo(() => {
    if (view !== 'flow' || !overlay) return undefined;
    const m = new Map<string, RunMark>(agents.map((a) => [a.agent_id, 'idle' as RunMark]));
    for (const [k, v] of overlay.marks) m.set(k, v);
    return m;
  }, [view, overlay, agents]);
  // While a line is being drawn from an agent: which agents can take it.
  const [connectFrom, setConnectFrom] = useState<string | null>(null);
  const connectMarks = useMemo(() => {
    const from = agents.find((a) => a.agent_id === connectFrom);
    if (!from) return undefined;
    const m = new Map<string, ConnectMark>();
    for (const a of agents)
      m.set(
        a.agent_id,
        a.agent_id === from.agent_id
          ? 'source'
          : a.is_system
            ? 'invalid'
            : from.permissions.some((p) => p.type === 'agent' && p.ref.toLowerCase() === a.name.toLowerCase())
            ? 'already'
            : 'valid',
      );
    return m;
  }, [agents, connectFrom]);
  const graph = useMemo(
    () => buildGraph(agents, state, { showSystem, showInactive, run: runMarks, connect: connectMarks }),
    [agents, state, showSystem, showInactive, runMarks, connectMarks],
  );
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>([]);
  const selectedRef = useRef<string[]>([]);
  selectedRef.current = selected;
  useEffect(() => {
    const keep = new Set(selectedRef.current);
    setNodes(graph.nodes.map((n) => (keep.has(n.id) ? { ...n, selected: true } : n)));
  }, [graph, setNodes]);
  function flowSetSelected(id: string | null) {
    setNodes((ns) => ns.map((n) => (n.selected === (n.id === id) ? n : { ...n, selected: n.id === id })));
  }

  const edges = useMemo(() => {
    if (view !== 'flow' || !overlay) return graph.edges;
    // Flow: the permission lines fade, and every hand-off that actually
    // happened is drawn in green with how many times it did.
    const out: Edge[] = graph.edges.map((e) => ({ ...e, className: `${e.className} edge-dim`, label: undefined }));
    for (const [key, n] of overlay.handoffs) {
      const [source, target] = key.split('>');
      if (!graph.abs.has(source) || !graph.abs.has(target)) continue;
      out.push({
        id: `run:${key}`,
        source,
        target,
        className: 'edge-active',
        animated: true,
        label: n > 1 ? `${LINE.handoff.label} ×${n}` : LINE.handoff.label,
        markerEnd: { type: MarkerType.ArrowClosed, color: LINE.handoff.color, width: 18, height: 18 },
        zIndex: 5,
      });
    }
    return out;
  }, [graph, view, overlay]);

  const fitted = useRef(false);
  const measured = useNodesInitialized();
  useEffect(() => {
    if (measured && !fitted.current) {
      fitted.current = true;
      setTimeout(() => flow.fitView({ padding: 0.15, duration: 200 }), 60);
    }
  }, [measured, flow]);

  // ------------------------------------------------------------- geometry
  const absOf = (id: string): XY | null => {
    const n = flow.getInternalNode(id);
    return n ? { x: n.internals.positionAbsolute.x, y: n.internals.positionAbsolute.y } : null;
  };
  const sizeOf = (id: string) => {
    const n = flow.getInternalNode(id);
    return { w: n?.measured.width ?? n?.width ?? NODE_W, h: n?.measured.height ?? n?.height ?? NODE_H };
  };
  const groupDepth = (gid: string) => {
    let d = 0;
    for (let g = state.groups.find((x) => x.group_id === gid); g?.parent_group_id; g = state.groups.find((x) => x.group_id === g!.parent_group_id)) d++;
    return d;
  };
  const groupWithin = (gid: string | null, ancestor: string) => {
    for (let g = gid; g; g = state.groups.find((x) => x.group_id === g)?.parent_group_id || null) if (g === ancestor) return true;
    return false;
  };
  /** Deepest group box containing the point, skipping the given groups and anything inside them. */
  const groupAt = (p: XY, skip: string[] = []): string | null => {
    let best: string | null = null;
    let bestDepth = -1;
    for (const g of state.groups) {
      const id = groupNodeId(g.group_id);
      if (skip.some((s) => groupWithin(g.group_id, s))) continue;
      const a = absOf(id);
      if (!a) continue;
      const s = sizeOf(id);
      if (p.x >= a.x && p.x <= a.x + s.w && p.y >= a.y && p.y <= a.y + s.h) {
        const d = groupDepth(g.group_id);
        if (d > bestDepth) (best = g.group_id), (bestDepth = d);
      }
    }
    return best;
  };
  const agentAt = (p: XY): Agent | null => {
    for (const a of agents) {
      const q = absOf(a.agent_id);
      if (q && p.x >= q.x && p.x <= q.x + NODE_W && p.y >= q.y && p.y <= q.y + NODE_H) return a;
    }
    return null;
  };
  const descendants = (nodeId: string): string[] =>
    nodes.filter((n) => n.parentId === nodeId).flatMap((n) => [n.id, ...descendants(n.id)]);
  const posItem = (id: string, p: XY, size?: { w: number; h: number }) => ({
    kind: isGroupNode(id) ? 'group' : 'agent',
    id: isGroupNode(id) ? groupIdOf(id) : id,
    x: Math.round(p.x),
    y: Math.round(p.y),
    ...(size ? { width: Math.round(size.w), height: Math.round(size.h) } : {}),
  });
  /** Folds saved positions into local state without a round trip. */
  const applyPositions = (items: ReturnType<typeof posItem>[]) =>
    setState((st) => {
      const key = (p: { kind: string; id: string }) => `${p.kind}:${p.id}`;
      const next = new Map(st.positions.map((p) => [key(p), p]));
      for (const it of items) {
        const old = next.get(key(it));
        next.set(key(it), { ...old, ...(it as StoredPosition) });
      }
      return { ...st, positions: [...next.values()] };
    });
  const restorePositions = (ids: string[]) => {
    const prev = ids.filter((id) => graph.abs.has(id)).map((id) => posItem(id, graph.abs.get(id)!));
    return () => rpc('canvas.layout.save', { items: prev });
  };

  // ---------------------------------------------------------------- moves
  const onNodeDragStop = useCallback(
    (_: unknown, _node: Node, dragged: Node[]) => {
      setDropTarget(null);
      const ids = dragged.filter((n) => n.type === 'agent' || n.type === 'group').map((n) => n.id);
      const moved = ids.filter((id) => {
        const a = absOf(id);
        const b = graph.abs.get(id);
        return a && b && (Math.abs(a.x - b.x) > 1 || Math.abs(a.y - b.y) > 1);
      });
      if (!moved.length) return;
      const all = [...new Set(moved.flatMap((id) => [id, ...descendants(id)]))].filter((id) => !id.startsWith('frame:'));
      const draggedGroups = moved.filter(isGroupNode).map(groupIdOf);
      const changes: { label: string; run: () => Promise<unknown>; back: () => Promise<unknown> }[] = [];
      // Where each dropped node ends up: pulled fully inside the box it was
      // dropped into (past the left and top edges and the title), never left
      // straddling a border. Overhang to the right or below grows the box.
      const shift = new Map<string, XY>();
      const settleInto = (id: string, gid: string | null) => {
        if (!gid) return;
        const box = absOf(groupNodeId(gid));
        const p = absOf(id);
        if (!box || !p) return;
        const dx = Math.max(0, box.x + 24 - p.x);
        const dy = Math.max(0, box.y + 44 - p.y);
        if (dx || dy) shift.set(id, { x: dx, y: dy });
      };
      for (const id of moved) {
        const p = absOf(id)!;
        const s = sizeOf(id);
        const centre = { x: p.x + s.w / 2, y: p.y + (isGroupNode(id) ? 18 : s.h / 2) };
        if (isGroupNode(id)) {
          const gid = groupIdOf(id);
          const g = state.groups.find((x) => x.group_id === gid)!;
          // A moved box nests only if it was dragged alone into another one.
          const target = groupAt(centre, [gid, ...draggedGroups]);
          if (g.parent_group_id && draggedGroups.includes(g.parent_group_id)) continue;
          if (target === g.parent_group_id || (target && draggedGroups.length > 1)) {
            settleInto(id, g.parent_group_id);
            continue;
          }
          settleInto(id, target);
          changes.push({
            label: target ? 'nesting' : 'un-nesting',
            run: () => rpc('canvas.groups.update', target ? { group_id: gid, parent_group_id: target } : { group_id: gid, clear_parent: true }),
            back: () =>
              rpc(
                'canvas.groups.update',
                g.parent_group_id ? { group_id: gid, parent_group_id: g.parent_group_id } : { group_id: gid, clear_parent: true },
              ),
          });
        } else {
          const a = agents.find((x) => x.agent_id === id);
          if (!a || a.is_system) continue;
          const before = groupOf(state, id);
          if (before && draggedGroups.some((d) => groupWithin(before, d))) continue; // travelled with its box
          const target = groupAt(centre, draggedGroups);
          settleInto(id, target);
          if (target === before) continue;
          changes.push({
            label: 'group change',
            run: () => rpc('canvas.groups.set_member', { agent_id: id, group_id: target }),
            back: () => rpc('canvas.groups.set_member', { agent_id: id, group_id: before }),
          });
        }
      }
      // A box's contents travel with it when it is pulled inside another.
      const shiftOf = (id: string): XY => {
        if (shift.has(id)) return shift.get(id)!;
        const parent = nodes.find((n) => n.id === id)?.parentId;
        return parent && all.includes(parent) ? shiftOf(parent) : { x: 0, y: 0 };
      };
      const items = all.map((id) => {
        const p = absOf(id)!;
        const d = shiftOf(id);
        return posItem(id, { x: p.x + d.x, y: p.y + d.y });
      });
      const back = restorePositions(all);
      act(
        changes.length ? 'Moved into place' : 'Moved',
        async () => {
        await rpc('canvas.layout.save', { items });
        for (const c of changes) await c.run();
        // The board already shows where things were dropped; only a group
        // change needs the database read back.
        if (!changes.length) applyPositions(items);
        return {
          label: 'move',
          run: async () => {
            for (const c of [...changes].reverse()) await c.back();
            await back();
          },
        };
        },
        { layoutOnly: !changes.length },
      );
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [graph, state, agents, nodes, act],
  );

  const onNodeDrag = useCallback(
    (_: unknown, node: Node) => {
      const p = absOf(node.id);
      if (!p) return;
      const s = sizeOf(node.id);
      const g = isGroupNode(node.id)
        ? groupAt({ x: p.x + s.w / 2, y: p.y + 18 }, [groupIdOf(node.id)])
        : groupAt({ x: p.x + s.w / 2, y: p.y + s.h / 2 });
      setDropTarget(g ? groupNodeId(g) : null);
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [state, nodes],
  );

  const onGroupResized = useCallback(
    (nodeId: string) => {
      const ids = [nodeId, ...descendants(nodeId)];
      const items = ids.map((id) => posItem(id, absOf(id)!, isGroupNode(id) && id === nodeId ? sizeOf(id) : undefined));
      const g = graph.nodes.find((n) => n.id === nodeId);
      const prev = [
        posItem(nodeId, graph.abs.get(nodeId)!, { w: Number(g?.width), h: Number(g?.height) }),
        ...ids.slice(1).filter((id) => graph.abs.has(id)).map((id) => posItem(id, graph.abs.get(id)!)),
      ];
      act(
        'Resized',
        async () => {
          await rpc('canvas.layout.save', { items });
          applyPositions(items);
          return { label: 'resize', run: () => rpc('canvas.layout.save', { items: prev }) };
        },
        { layoutOnly: true },
      );
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [graph, nodes, act],
  );

  // ---------------------------------------------------------------- lines
  const onConnect = useCallback(
    (c: Connection) => {
      const from = agents.find((a) => a.agent_id === c.source);
      const to = agents.find((a) => a.agent_id === c.target);
      if (!from || !to || from.agent_id === to.agent_id) return;
      if (to.is_system) {
        toast('System agents run the platform itself and do not take delegated work.', true);
        return;
      }
      if (from.permissions.some((p) => p.type === 'agent' && p.ref.toLowerCase() === to.name.toLowerCase())) {
        toast(`${from.name} can already delegate to ${to.name}`);
        return;
      }
      act(`${from.name} can now delegate to ${to.name}`, async () => {
        await rpc('canvas.delegation.add', { from_agent_id: from.agent_id, to_agent_id: to.agent_id });
        return { label: 'new line', run: () => rpc('canvas.delegation.remove', { from_agent_id: from.agent_id, to_agent_id: to.agent_id }) };
      });
    },
    [agents, act, toast],
  );

  const onEdgeClick = useCallback(
    async (_: unknown, e: Edge) => {
      const d = e.data as { kind?: string; from?: string; to?: string; removable?: boolean } | undefined;
      if (d?.kind !== 'delegate') return;
      const from = agents.find((a) => a.agent_id === d.from);
      const to = agents.find((a) => a.agent_id === d.to);
      if (!from || !to) return;
      if (!d.removable) {
        toast('System agents’ grants are changed only from SQL.', true);
        return;
      }
      if (!(await confirm(`Remove this line?`, <p>{from.name} will no longer be able to delegate to {to.name}.</p>, 'Remove line', true))) return;
      act(`${from.name} no longer delegates to ${to.name}`, async () => {
        await rpc('canvas.delegation.remove', { from_agent_id: from.agent_id, to_agent_id: to.agent_id });
        return { label: 'line removal', run: () => rpc('canvas.delegation.add', { from_agent_id: from.agent_id, to_agent_id: to.agent_id }) };
      });
    },
    [agents, act, confirm, toast],
  );

  // ---------------------------------------------------------------- drops
  // Never on or against another card (measured size plus a gap, so its
  // connection dots stay reachable), nor, for a new box, on another box:
  // step right until the spot is free. The group it goes into, and the
  // groups around that one, are of course allowed to contain it.
  const freeSpot = (x0: number, y: number, w: number, h: number, boxes: boolean, inside: string | null) => {
    const rects: { x: number; y: number; w: number; h: number }[] = [];
    for (const a of agents) {
      const q = absOf(a.agent_id);
      if (q) rects.push({ ...q, ...sizeOf(a.agent_id) });
    }
    if (boxes)
      for (const g of state.groups) {
        if (inside && groupWithin(inside, g.group_id)) continue;
        const q = absOf(groupNodeId(g.group_id));
        if (q) rects.push({ ...q, ...sizeOf(groupNodeId(g.group_id)) });
      }
    const hit = (x: number) => rects.some((r) => x < r.x + r.w + 40 && r.x < x + w + 40 && y < r.y + r.h + 40 && r.y < y + h + 40);
    let x = x0;
    while (hit(x)) x += 40;
    return { x: Math.round(x), y: Math.round(y) };
  };

  const createAgent = async (p: XY, groupId: string | null) => {
    const v = await ask({
      title: 'New agent',
      fields: [
        { name: 'name', label: 'Name', type: 'text', required: true, placeholder: 'researcher' },
        { name: 'provider', label: 'Provider', type: 'select', options: [['', 'None yet (draft)'], ...providers.map((x) => [x.name, x.name] as [string, string])], value: providers[0]?.name || '' },
        { name: 'model', label: 'Model', type: 'text', list: providers.flatMap((x) => x.available_models || []), value: providers[0]?.available_models?.[0] || '' },
        { name: 'prompt', label: 'System prompt', type: 'textarea', placeholder: 'What this agent does and how' },
      ],
      submit: 'Create agent',
    });
    if (!v) return;
    const draft = !v.provider || !v.model.trim();
    let created: string | null = null;
    const ok = await act(draft ? `Created ${v.name.trim()} as a draft` : `Created ${v.name.trim()}`, async () => {
      const r = await rpc<{ agent_id: string }>('agents.create', {
        name: v.name.trim(),
        system_prompt: v.prompt,
        llm_config: draft ? undefined : { provider: v.provider, model: v.model.trim() },
        is_active: !draft,
      });
      const { x, y } = freeSpot(p.x - NODE_W / 2, p.y - 30, NODE_W, NODE_H, false, groupId);
      await rpc('canvas.layout.save', { items: [{ kind: 'agent', id: r.agent_id, x: Math.round(x), y: Math.round(y) }] });
      if (groupId) await rpc('canvas.groups.set_member', { agent_id: r.agent_id, group_id: groupId });
      if (draft) setShowInactive(true);
      created = r.agent_id;
      return { label: `creating ${v.name.trim()} (it is deactivated)`, run: () => rpc('agents.update', { agent_id: r.agent_id, is_active: false }) };
    });
    if (ok && created) select(created);
  };

  const createGroup = async (p: XY, parent: string | null, members: string[] = [], rect?: { x: number; y: number; w: number; h: number }) => {
    const v = await ask({
      title: members.length ? `Group ${members.length} agents` : 'New group',
      fields: [
        { name: 'name', label: 'Name', type: 'text', required: true, placeholder: 'Research team' },
        { name: 'kind', label: 'Kind', type: 'select', options: [['team', 'Team'], ['division', 'Division'], ['project', 'Project']] },
      ],
      submit: 'Create group',
    });
    if (!v) return;
    const before = members.map((id) => [id, groupOf(state, id)] as const);
    await act(`Created ${v.name.trim()}`, async () => {
      const r = await rpc<{ group_id: string }>('canvas.groups.create', {
        name: v.name.trim(),
        kind: v.kind,
        parent_group_id: parent,
        position: rect
          ? { x: rect.x, y: rect.y, width: rect.w, height: rect.h }
          : { ...freeSpot(p.x - 180, p.y - 30, 360, 220, true, parent), width: 360, height: 220 },
        agent_ids: members,
      });
      return {
        label: `creating ${v.name.trim()}`,
        run: async () => {
          // Deleting a box moves its agents up to its parent, which is where
          // they were unless they came from several different groups.
          for (const [id, g] of before) if (g !== parent) await rpc('canvas.groups.set_member', { agent_id: id, group_id: g });
          await rpc('canvas.groups.delete', { group_id: r.group_id });
        },
      };
    });
  };

  const placeTemplate = async (id: string, name: string, p: XY, parent: string | null) => {
    await act(`Placed ${name}. Each agent is new; deactivate them in Settings if this was a mistake.`, async () => {
      await rpc('canvas.templates.instantiate', { template_id: id, x: Math.round(p.x), y: Math.round(p.y), parent_group_id: parent });
    });
  };

  const use = async (item: PaletteItem, p: XY, targetAgent: Agent | null, targetGroup: string | null) => {
    setPaletteOpen(false);
    if (item.kind === 'agent') return createAgent(p, targetGroup);
    if (item.kind === 'group') return createGroup(p, targetGroup);
    if (item.kind === 'template') return placeTemplate(item.id, item.name, p, targetGroup);
    if (!targetAgent) {
      toast('Drop a skill on an agent, or select an agent first.', true);
      return;
    }
    if (targetAgent.is_system) {
      toast('System agents’ grants are changed only from SQL.', true);
      return;
    }
    let ref = item.ref;
    if (item.type === 'http_host') {
      const v = await ask({
        title: `HTTP host for ${targetAgent.name}`,
        fields: [{ name: 'host', label: 'Host name', type: 'text', required: true, placeholder: 'api.example.com' }],
        submit: 'Grant',
      });
      if (!v) return;
      ref = v.host.trim();
    }
    await grantWithCeiling(targetAgent, item.type, ref);
  };

  const viewportCentre = (): XY => {
    const el = document.querySelector('.flow')?.getBoundingClientRect();
    return flow.screenToFlowPosition({ x: (el?.left || 0) + (el?.width || 800) / 2, y: (el?.top || 0) + (el?.height || 600) / 2 });
  };

  const onPaletteClick = (item: PaletteItem) => {
    const one = selected.length === 1 ? selected[0] : null;
    const selAgent = one && !isGroupNode(one) ? agents.find((a) => a.agent_id === one) || null : null;
    const selGroup = one && isGroupNode(one) ? groupIdOf(one) : selAgent ? groupOf(state, selAgent.agent_id) : null;
    const c = viewportCentre();
    if (item.kind !== 'skill' && selGroup) {
      const a = absOf(groupNodeId(selGroup));
      const s = sizeOf(groupNodeId(selGroup));
      if (a) return use(item, { x: a.x + s.w / 2, y: a.y + s.h / 2 }, selAgent, selGroup);
    }
    use(item, c, selAgent, selGroup);
  };

  const parseDrag = (e: DragEvent): PaletteItem | null => {
    try {
      return JSON.parse(e.dataTransfer.getData(DRAG_MIME));
    } catch {
      return null;
    }
  };
  const onDragOver = (e: DragEvent) => {
    if (!e.dataTransfer.types.includes(DRAG_MIME)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
    const p = flow.screenToFlowPosition({ x: e.clientX, y: e.clientY });
    const a = agentAt(p);
    const g = groupAt(p);
    setDropTarget(a && !a.is_system ? a.agent_id : g ? groupNodeId(g) : null);
  };
  const onDrop = (e: DragEvent) => {
    const item = parseDrag(e);
    setDropTarget(null);
    if (!item) return;
    e.preventDefault();
    const p = flow.screenToFlowPosition({ x: e.clientX, y: e.clientY });
    use(item, p, agentAt(p), groupAt(p));
  };

  // Auto-arrange: the layout the board would draw if nothing had ever been
  // placed by hand (each agent under the agent that delegates to it, boxes
  // sized to fit), written back as positions in one save. Undo restores the
  // previous ones.
  const arrange = () => {
    const fresh = buildGraph(agents, { ...state, positions: [] }, { showSystem, showInactive });
    const items = fresh.nodes
      .filter((n) => (n.type === 'agent' && !(n.data as { agent: Agent }).agent.is_system) || n.type === 'group')
      .map((n) => posItem(n.id, fresh.abs.get(n.id)!, n.type === 'group' ? { w: Number(n.width), h: Number(n.height) } : undefined));
    if (!items.length) return;
    const prev = items
      .filter((it) => graph.abs.has(it.kind === 'group' ? groupNodeId(it.id) : it.id))
      .map((it) => {
        const id = it.kind === 'group' ? groupNodeId(it.id) : it.id;
        const n = graph.nodes.find((x) => x.id === id);
        return posItem(id, graph.abs.get(id)!, it.kind === 'group' ? { w: Number(n?.width), h: Number(n?.height) } : undefined);
      });
    act(
      'Arranged',
      async () => {
        await rpc('canvas.layout.save', { items });
        applyPositions(items);
        setTimeout(() => flow.fitView({ padding: 0.15, duration: 300 }), 50);
        return { label: 'arrange', run: () => rpc('canvas.layout.save', { items: prev }) };
      },
      { layoutOnly: true },
    );
  };

  const groupSelected = () => {
    const ids = selected.filter((id) => !isGroupNode(id) && agents.find((a) => a.agent_id === id && !a.is_system));
    if (!ids.length) return;
    const ps = ids.map((id) => absOf(id)!).filter(Boolean);
    const x = Math.min(...ps.map((p) => p.x)) - 24;
    const y = Math.min(...ps.map((p) => p.y)) - 60;
    const w = Math.max(...ps.map((p) => p.x)) + NODE_W + 24 - x;
    const h = Math.max(...ps.map((p) => p.y)) + NODE_H + 24 - y;
    const parents = new Set(ids.map((id) => groupOf(state, id)));
    createGroup({ x, y }, parents.size === 1 ? [...parents][0] : null, ids, { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) });
  };

  // --------------------------------------------------------------- render
  const one = selected.length === 1 ? selected[0] : null;
  const current = one && !isGroupNode(one) ? agents.find((a) => a.agent_id === one) || null : null;
  const currentGroup = one && isGroupNode(one) ? state.groups.find((g) => g.group_id === groupIdOf(one)) || null : null;
  const groupable = selected.filter((id) => !isGroupNode(id) && agents.some((a) => a.agent_id === id && !a.is_system)).length;
  const general = agentByName(agents, 'general');
  const empty = graph.count === 0 && state.groups.length === 0;

  return (
    <div className="app">
      <header className="bar">
        <a className="brand" href="/">
          Allgres
        </a>
        <span className="crumb">Canvas</span>
        <a className="btn ghost" href="/">
          ← Dashboard
        </a>
        {gate.kind === 'ready' && (
          <>
            <div className="seg" role="group" aria-label="View">
              <button type="button" className={view === 'org' ? 'on' : ''} aria-pressed={view === 'org'} onClick={() => setView('org')}>
                Organization
              </button>
              <button type="button" className={view === 'flow' ? 'on' : ''} aria-pressed={view === 'flow'} onClick={() => setView('flow')}>
                Flow
              </button>
            </div>
            <button type="button" className="btn" disabled={!groupable} onClick={groupSelected} title="Shift+click agents to select several">
              Group selected{groupable > 1 ? ` (${groupable})` : ''}
            </button>
            <button type="button" className="btn" onClick={arrange} title="Lay every agent out under the agent that delegates to it, boxes sized to fit">
              Arrange
            </button>
            <button type="button" className="btn" disabled={!undoCount} onClick={undo} title="⌘/Ctrl+Z">
              Undo
            </button>
            <span className="spacer" />
            <div className="zoom" role="group" aria-label="Zoom">
              <button type="button" className="btn" onClick={() => flow.zoomOut({ duration: 150 })} aria-label="Zoom out">
                −
              </button>
              <button type="button" className="btn ghost num" onClick={() => flow.zoomTo(1, { duration: 150 })} title="Reset to 100%">
                {Math.round(zoom * 100)}%
              </button>
              <button type="button" className="btn" onClick={() => flow.zoomIn({ duration: 150 })} aria-label="Zoom in">
                +
              </button>
              <button type="button" className="btn" onClick={() => flow.fitView({ padding: 0.15, duration: 250 })}>
                Fit
              </button>
            </div>
            <label className="toggle">
              <input id="showSystem" type="checkbox" checked={showSystem} onChange={(e) => setShowSystem(e.target.checked)} />
              System agents
            </label>
            <label className="toggle">
              <input id="showInactive" type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
              Inactive
            </label>
            <button type="button" className="btn" onClick={() => Promise.all([reload(), loadOptions()]).then(() => toast('Refreshed')).catch((e) => toast(message(e), true))}>
              Refresh
            </button>
            <button type="button" className="btn palette-toggle" aria-expanded={paletteOpen} onClick={() => setPaletteOpen((v) => !v)}>
              Blocks
            </button>
          </>
        )}
      </header>
      <main className="stage">
        {gate.kind === 'loading' && <div className="notice">Loading agents…</div>}
        {gate.kind === 'blocked' && (
          <div className="notice">
            <b>{gate.title}</b>
            <p>{gate.body}</p>
            <a className="btn primary" href="/">
              Open dashboard
            </a>
          </div>
        )}
        {gate.kind === 'ready' && (
          <BoardEvents.Provider value={{ onGroupResized, dropTarget }}>
            <Palette board={board} onUse={onPaletteClick} open={paletteOpen} />
            <div className="flow" onDragOver={onDragOver} onDrop={onDrop} onDragLeave={() => setDropTarget(null)}>
              <ReactFlow
                nodes={nodes}
                edges={edges}
                nodeTypes={nodeTypes}
                onNodesChange={onNodesChange}
                onSelectionChange={({ nodes: ns }) => {
                  const ids = ns.map((n) => n.id).filter((id) => !id.startsWith('frame:'));
                  setSelected((cur) => (cur.length === ids.length && cur.every((x, i) => x === ids[i]) ? cur : ids));
                }}
                onNodeDrag={onNodeDrag}
                onNodeDragStop={onNodeDragStop}
                onConnect={onConnect}
                onConnectStart={(_, p) => p.handleType === 'source' && p.nodeId && setConnectFrom(p.nodeId)}
                onConnectEnd={(e, cs) => {
                  // Released on a card rather than its dot: connect to that agent.
                  const from = connectFrom;
                  setConnectFrom(null);
                  if (!from || cs.isValid) return;
                  const pt = 'changedTouches' in e ? e.changedTouches[0] : (e as MouseEvent);
                  const to = agentAt(flow.screenToFlowPosition({ x: pt.clientX, y: pt.clientY }));
                  if (to && to.agent_id !== from) onConnect({ source: from, target: to.agent_id, sourceHandle: null, targetHandle: null });
                }}
                connectionRadius={36}
                connectionLineStyle={{ stroke: LINE.delegate.color, strokeWidth: 2.4, strokeDasharray: '6 5' }}
                onEdgeClick={onEdgeClick}
                isValidConnection={(c) => c.source !== c.target && !isGroupNode(c.source) && !isGroupNode(c.target)}
                deleteKeyCode={null}
                multiSelectionKeyCode={['Shift', 'Meta', 'Control']}
                selectionKeyCode={null}
                colorMode={theme()}
                minZoom={0.15}
                maxZoom={1.75}
                proOptions={{ hideAttribution: true }}
              >
                <Background gap={22} size={1.2} />
                <MiniMap pannable zoomable className="minimap" />
              </ReactFlow>
              {empty && (
                <div className="notice overlay">
                  <b>No agents yet</b>
                  <p>Drag an Agent block from the palette onto the board{general ? ', or ask General below to suggest a team' : ''}.</p>
                </div>
              )}
              {connectFrom && (
                <div className="connect-banner" role="status">
                  Drop on a highlighted agent: <b>{agents.find((a) => a.agent_id === connectFrom)?.name}</b> will be able to hand tasks to it. Release
                  anywhere else to cancel.
                </div>
              )}
              <Legend view={view} showSystem={showSystem} />
              {general && general.is_active && (
                <section className={`dock${dockOpen ? ' open' : ''}`} aria-label="Talk to General">
                  <header>
                    <span className="an-avatar">G</span>
                    <b>General</b>
                    <small className="muted">{modelShort(general)}</small>
                    <span className="spacer" />
                    <button
                      type="button"
                      className="btn ghost"
                      aria-expanded={dockOpen}
                      onClick={() => setDockOpen((v) => (remember('allgres_canvas_dock', !v), !v))}
                    >
                      {dockOpen ? 'Hide' : 'Talk to General'}
                    </button>
                  </header>
                  {dockOpen && <Chat agentId={general.agent_id} agentName="General" />}
                </section>
              )}
            </div>
            {view === 'flow' ? (
              <FlowPanel sessionId={sessionId} onSession={setSessionId} onOverlay={setOverlay} onSelectAgent={(id) => flowSetSelected(id)} />
            ) : current ? (
              <AgentInspector board={board} agent={current} onClose={() => select(null)} key={current.agent_id} />
            ) : currentGroup ? (
              <GroupInspector board={board} group={currentGroup} onClose={() => select(null)} key={currentGroup.group_id} />
            ) : null}
          </BoardEvents.Provider>
        )}
      </main>
      {dialog}
      {toastEl}
    </div>
  );
}

// What every mark on the board means, in plain words. Collapsible; the
// choice is remembered per browser.
function Legend({ view, showSystem }: { view: 'org' | 'flow'; showSystem: boolean }) {
  const [open, setOpen] = useState(() => remembered('allgres_canvas_legend', true));
  const toggle = () => setOpen((v) => (remember('allgres_canvas_legend', !v), !v));
  return (
    <aside className={`legend${open ? ' open' : ''}`} aria-label="How to read the board">
      <button type="button" className="legend-toggle" aria-expanded={open} onClick={toggle}>
        {open ? 'How to read the board ▾' : 'Legend ▸'}
      </button>
      {open && (
        <dl>
          {view === 'flow' ? (
            <>
              <dt>
                <i className="lg-active" />
              </dt>
              <dd>
                <b>Handed work</b> — A gave B a task (delegate) in recent sessions; ×N is how often. Pick a session on the right to replay one.
              </dd>
              <dt>
                <i className="lg-delegate dim" />
              </dt>
              <dd>Permission lines, faded: who <em>may</em> delegate, used or not.</dd>
            </>
          ) : (
            <>
              <dt>
                <i className="lg-delegate" />
              </dt>
              <dd>
                <b>Can delegate to</b> — A may hand tasks to B. Drag from an agent's <span className="kbd">+</span> to another agent to add one; click a
                line to remove it.
              </dd>
              {showSystem && (
                <>
                  <dt>
                    <i className="lg-parent" />
                  </dt>
                  <dd>
                    <b>Inherits</b> — the child gets the parent's skills and base prompt (system agents). Shown as “+N inherited” on the card.
                  </dd>
                </>
              )}
              <dt>
                <i className="lg-box" />
              </dt>
              <dd>
                <b>Group box</b> — a team or division. Only arranges agents; grants nothing.
              </dd>
            </>
          )}
        </dl>
      )}
    </aside>
  );
}

function modelShort(a: Agent) {
  return a.llm_config?.model || 'no model';
}

export function App() {
  return (
    <ReactFlowProvider>
      <Canvas />
    </ReactFlowProvider>
  );
}
