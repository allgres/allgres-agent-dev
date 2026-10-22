import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent } from 'react';
import {
  Background,
  MarkerType,
  ReactFlow,
  ReactFlowProvider,
  useNodesInitialized,
  useNodesState,
  useReactFlow,
  useViewport,
  type Connection,
  type Edge,
  type Node,
} from '@xyflow/react';
import { AddMenu, DRAG_MIME, type AddItem } from './AddMenu';
import { rpc, RpcError, type Agent, type CanvasState, type GrantOptions, type GrantResult, type Provider, type StoredPosition } from './api';
import { agentByName, groupOf, type Board, type Undo } from './board';
import { Chat } from './Chat';
import { FlowPanel, type FlowOverlay } from './FlowPanel';
import { buildGraph, groupIdOf, groupNodeId, isGroupNode, LINE, NODE_H, NODE_W, type ConnectMark, type RunMark } from './graph';
import { LangProvider, useLang, useT, type T } from './i18n';
import { AgentInspector, GroupInspector } from './Inspector';
import { abilityLabel } from './labels';
import { BoardEvents, nodeTypes } from './nodes';
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

function explain(t: T, e: unknown): { title: string; body: string } {
  const code = e instanceof RpcError ? e.code : String(e);
  if (code === 'unauthorized')
    return { title: t('Dashboard token required'), body: t('Open the dashboard in this tab, enter the dashboard token, then come back to Canvas.') };
  if (/not logged in/i.test(code)) return { title: t('Sign in first'), body: t('Sign in on the dashboard in this tab, then open Canvas from the menu.') };
  if (/admin/i.test(code)) return { title: t('Admins only'), body: t('Canvas shows and changes every agent and its grants, so it needs an admin account.') };
  return { title: t('Canvas could not load'), body: code };
}

const message = (e: unknown) => (e instanceof RpcError ? e.code : e instanceof Error ? e.message : String(e));
const inputFocused = () => {
  const el = document.activeElement;
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || (el as HTMLElement).isContentEditable);
};
const delegates = (from: Agent, to: Agent) => from.permissions.some((p) => p.type === 'agent' && p.ref.toLowerCase() === to.name.toLowerCase());

function Canvas() {
  const t = useT();
  const { lang, setLang } = useLang();
  const [gate, setGate] = useState<Gate>({ kind: 'loading' });
  const [agents, setAgents] = useState<Agent[]>([]);
  const [state, setState] = useState<CanvasState>(EMPTY_STATE);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [options, setOptions] = useState<GrantOptions>(NO_OPTIONS);
  const [showSystem, setShowSystemRaw] = useState(() => remembered('allgres_canvas_system', false));
  const [showInactive, setShowInactive] = useState(true);
  const [view, setView] = useState<'org' | 'flow'>('org');
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [overlay, setOverlay] = useState<FlowOverlay | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [drop, setDrop] = useState<{ target: string; text: string } | null>(null);
  const [moreOpen, setMoreOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(() => !remembered('allgres_canvas_help_seen', false));
  const [chatOpen, setChatOpen] = useState(false);
  const [undoCount, setUndoCount] = useState(0);
  const undos = useRef<Undo[]>([]);
  const flow = useReactFlow();
  const { zoom } = useViewport();
  const { ask, confirm, element: dialog } = useDialog();
  const { toast, element: toastEl } = useToast();
  const setShowSystem = (v: boolean) => (remember('allgres_canvas_system', v), setShowSystemRaw(v));

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
    document.documentElement.lang = lang;
    (async () => {
      try {
        await reload();
        await loadOptions();
        setGate({ kind: 'ready' });
      } catch (e) {
        setGate({ kind: 'blocked', ...explain(t, e) });
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
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
      toast(t('Undid: {what}', { what: u.label }));
    } catch (e) {
      toast(t('Could not undo {what}: {why}', { what: u.label, why: message(e) }), true);
    }
    await reload().catch(() => {});
  }, [reload, toast, t]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === 'z' && !inputFocused()) {
        e.preventDefault();
        undo();
      }
      if (e.key === 'Escape' && !inputFocused()) {
        setMoreOpen(false);
        setSelected([]);
        flowSetSelected(null);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [undo]);

  // canvas.grant reports the ceiling gap instead of failing; turn that into
  // a question, then grant to everyone above in one transaction.
  const grantWithCeiling = useCallback<Board['grant']>(
    async (agent, type, ref) => {
      const what = abilityLabel(t, type, ref);
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
        pushUndo({ label: what, run: revokeAll([agent]) });
        toast(t('{name} can now {what}', { name: agent.name, what }));
        await reload();
        return true;
      }
      const missing = r.missing || [];
      if (missing.some((m) => m.is_system)) {
        await confirm(
          t('Cannot add this here'),
          <p>{t('{names} hand work to {name} and lack {what}, but system agents are changed only from SQL.', { names: missing.filter((m) => m.is_system).map((m) => m.name).join(', '), name: agent.name, what })}</p>,
          t('Got it'),
        );
        return false;
      }
      const yes = await confirm(
        t('Also give it to the agents above?'),
        <>
          <p>{t('An agent can only use what every agent that hands it work can use too. These agents hand work to {name} and lack {what}:', { name: agent.name, what })}</p>
          <ul>
            {missing.map((m) => (
              <li key={m.agent_id}>{m.name}</li>
            ))}
          </ul>
        </>,
        t('Give to all {n}', { n: missing.length + 1 }),
      );
      if (!yes) return false;
      return act(t('{name} can now {what}', { name: agent.name, what }), async () => {
        const x = await rpc<GrantResult>('canvas.grant', { agent_id: agent.agent_id, type, ref, include_superiors: true });
        return { label: what, run: revokeAll([agent, ...(x.also_granted || [])]) };
      });
    },
    [act, confirm, reload, toast, t],
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
    for (const a of agents) m.set(a.agent_id, a.agent_id === from.agent_id ? 'source' : a.is_system ? 'invalid' : delegates(from, a) ? 'already' : 'valid');
    return m;
  }, [agents, connectFrom]);
  const graph = useMemo(
    () => buildGraph(agents, state, { showSystem, showInactive, run: runMarks, connect: connectMarks, t }),
    [agents, state, showSystem, showInactive, runMarks, connectMarks, t],
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
        label: n > 1 ? `${t(LINE.handoff.label)} ×${n}` : t(LINE.handoff.label),
        markerEnd: { type: MarkerType.ArrowClosed, color: LINE.handoff.color, width: 18, height: 18 },
        zIndex: 5,
      });
    }
    return out;
  }, [graph, view, overlay, t]);

  const fitted = useRef(false);
  const measured = useNodesInitialized();
  useEffect(() => {
    if (measured && !fitted.current) {
      fitted.current = true;
      setTimeout(() => flow.fitView({ padding: 0.2, duration: 200, maxZoom: 1 }), 60);
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
  const agentAt = (p: XY, skip?: string): Agent | null => {
    for (const a of agents) {
      if (a.agent_id === skip) continue;
      const q = absOf(a.agent_id);
      if (!q) continue;
      const s = sizeOf(a.agent_id);
      if (p.x >= q.x && p.x <= q.x + s.w && p.y >= q.y && p.y <= q.y + s.h) return a;
    }
    return null;
  };
  const descendants = (nodeId: string): string[] => nodes.filter((n) => n.parentId === nodeId).flatMap((n) => [n.id, ...descendants(n.id)]);
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
      for (const it of items) next.set(key(it), { ...next.get(key(it)), ...(it as StoredPosition) });
      return { ...st, positions: [...next.values()] };
    });
  const restorePositions = (ids: string[]) => {
    const prev = ids.filter((id) => graph.abs.has(id)).map((id) => posItem(id, graph.abs.get(id)!));
    return () => rpc('canvas.layout.save', { items: prev });
  };
  // Never on or against another card (measured size plus a gap), nor, for a
  // new box, on another box: step right until the spot is free. The group it
  // goes into, and the groups around that one, may of course contain it.
  const freeSpot = (x0: number, y: number, w: number, h: number, boxes: boolean, inside: string | null, skip?: string) => {
    const rects: { x: number; y: number; w: number; h: number }[] = [];
    for (const a of agents) {
      if (a.agent_id === skip) continue;
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

  // ------------------------------------------------- "put it under" (drop)
  // Dropping one agent's card on another's is how a manager thinks about a
  // team: "this one works under that one". It draws the line (the upper agent
  // may hand work to the lower), moves it into the upper one's team, and sets
  // it just below. One undo step reverses all three.
  const putUnder = (child: Agent, parent: Agent) => {
    const before = { group: groupOf(state, child.agent_id), pos: graph.abs.get(child.agent_id) };
    const team = groupOf(state, parent.agent_id);
    const p = absOf(parent.agent_id) || { x: 0, y: 0 };
    const spot = freeSpot(p.x, p.y + sizeOf(parent.agent_id).h + 70, NODE_W, NODE_H, false, team, child.agent_id);
    const added = !delegates(parent, child);
    const label = t('{child} now works under {parent}', { child: child.name, parent: parent.name });
    act(label, async () => {
      if (added) await rpc('canvas.delegation.add', { from_agent_id: parent.agent_id, to_agent_id: child.agent_id });
      if (team !== before.group) await rpc('canvas.groups.set_member', { agent_id: child.agent_id, group_id: team });
      await rpc('canvas.layout.save', { items: [{ kind: 'agent', id: child.agent_id, ...spot }] });
      return {
        label,
        run: async () => {
          if (added) await rpc('canvas.delegation.remove', { from_agent_id: parent.agent_id, to_agent_id: child.agent_id });
          if (team !== before.group) await rpc('canvas.groups.set_member', { agent_id: child.agent_id, group_id: before.group });
          if (before.pos) await rpc('canvas.layout.save', { items: [{ kind: 'agent', id: child.agent_id, x: Math.round(before.pos.x), y: Math.round(before.pos.y) }] });
        },
      };
    });
  };

  const dropOnAgent = (node: Node): Agent | null => {
    if (isGroupNode(node.id)) return null;
    const me = agents.find((a) => a.agent_id === node.id);
    if (!me || me.is_system) return null;
    const p = absOf(node.id);
    if (!p) return null;
    const s = sizeOf(node.id);
    const target = agentAt({ x: p.x + s.w / 2, y: p.y + s.h / 2 }, node.id);
    return target && !target.is_system ? target : null;
  };

  // ---------------------------------------------------------------- moves
  const onNodeDragStop = useCallback(
    (_: unknown, node: Node, dragged: Node[]) => {
      setDrop(null);
      if (dragged.length === 1) {
        const parent = dropOnAgent(node);
        const me = agents.find((a) => a.agent_id === node.id);
        if (parent && me) return putUnder(me, parent);
      }
      const ids = dragged.filter((n) => n.type === 'agent' || n.type === 'group').map((n) => n.id);
      const moved = ids.filter((id) => {
        const a = absOf(id);
        const b = graph.abs.get(id);
        return a && b && (Math.abs(a.x - b.x) > 1 || Math.abs(a.y - b.y) > 1);
      });
      if (!moved.length) return;
      const all = [...new Set(moved.flatMap((id) => [id, ...descendants(id)]))].filter((id) => !id.startsWith('frame:'));
      const draggedGroups = moved.filter(isGroupNode).map(groupIdOf);
      const changes: { run: () => Promise<unknown>; back: () => Promise<unknown>; label: string }[] = [];
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
            label: target ? t('Moved into {team}', { team: state.groups.find((x) => x.group_id === target)?.name || '' }) : t('Moved out of the team'),
            run: () => rpc('canvas.groups.update', target ? { group_id: gid, parent_group_id: target } : { group_id: gid, clear_parent: true }),
            back: () => rpc('canvas.groups.update', g.parent_group_id ? { group_id: gid, parent_group_id: g.parent_group_id } : { group_id: gid, clear_parent: true }),
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
            label: target ? t('Moved into {team}', { team: state.groups.find((x) => x.group_id === target)?.name || '' }) : t('Moved out of the team'),
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
      const label = changes.length === 1 ? changes[0].label : t('Moved');
      act(
        label,
        async () => {
          await rpc('canvas.layout.save', { items });
          for (const c of changes) await c.run();
          // The board already shows where things were dropped; only a group
          // change needs the database read back.
          if (!changes.length) applyPositions(items);
          return {
            label,
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
    [graph, state, agents, nodes, act, t],
  );

  const onNodeDrag = useCallback(
    (_: unknown, node: Node, dragged: Node[]) => {
      if (dragged.length === 1) {
        const parent = dropOnAgent(node);
        const me = agents.find((a) => a.agent_id === node.id);
        if (parent && me) {
          setDrop({ target: parent.agent_id, text: t('Drop to put {child} under {parent}', { child: me.name, parent: parent.name }) });
          return;
        }
      }
      const p = absOf(node.id);
      if (!p) return;
      const s = sizeOf(node.id);
      const g = isGroupNode(node.id) ? groupAt({ x: p.x + s.w / 2, y: p.y + 18 }, [groupIdOf(node.id)]) : groupAt({ x: p.x + s.w / 2, y: p.y + s.h / 2 });
      setDrop(g ? { target: groupNodeId(g), text: t('Moved into {team}', { team: state.groups.find((x) => x.group_id === g)?.name || '' }) } : null);
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [state, nodes, agents, t],
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
        t('Resized'),
        async () => {
          await rpc('canvas.layout.save', { items });
          applyPositions(items);
          return { label: t('Resized'), run: () => rpc('canvas.layout.save', { items: prev }) };
        },
        { layoutOnly: true },
      );
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [graph, nodes, act, t],
  );

  // ---------------------------------------------------------------- lines
  const onConnect = useCallback(
    (c: Connection) => {
      const from = agents.find((a) => a.agent_id === c.source);
      const to = agents.find((a) => a.agent_id === c.target);
      if (!from || !to || from.agent_id === to.agent_id) return;
      if (to.is_system) return toast(t('System agents run the platform itself and do not take work from the board.'), true);
      if (delegates(from, to)) return toast(t('{from} already hands work to {to}', { from: from.name, to: to.name }));
      const label = t('{from} can now hand work to {to}', { from: from.name, to: to.name });
      act(label, async () => {
        await rpc('canvas.delegation.add', { from_agent_id: from.agent_id, to_agent_id: to.agent_id });
        return { label, run: () => rpc('canvas.delegation.remove', { from_agent_id: from.agent_id, to_agent_id: to.agent_id }) };
      });
    },
    [agents, act, toast, t],
  );

  const onEdgeClick = useCallback(
    async (_: unknown, e: Edge) => {
      const d = e.data as { kind?: string; from?: string; to?: string; removable?: boolean } | undefined;
      if (d?.kind !== 'delegate') return;
      const from = agents.find((a) => a.agent_id === d.from);
      const to = agents.find((a) => a.agent_id === d.to);
      if (!from || !to) return;
      if (!d.removable) return toast(t('System agents are changed only from SQL.'), true);
      if (!(await confirm(t('Stop handing work?'), <p>{t('{from} will no longer be able to hand work to {to}.', { from: from.name, to: to.name })}</p>, t('Disconnect'), true))) return;
      const label = t('{from} no longer hands work to {to}', { from: from.name, to: to.name });
      act(label, async () => {
        await rpc('canvas.delegation.remove', { from_agent_id: from.agent_id, to_agent_id: to.agent_id });
        return { label, run: () => rpc('canvas.delegation.add', { from_agent_id: from.agent_id, to_agent_id: to.agent_id }) };
      });
    },
    [agents, act, confirm, toast, t],
  );

  // --------------------------------------------------------------- adding
  const createAgent = async (p: XY, groupId: string | null) => {
    const v = await ask({
      title: t('New agent'),
      body: <p>{t('You can add a model later; until then it is saved turned off.')}</p>,
      fields: [
        { name: 'name', label: t('Name'), type: 'text', required: true, placeholder: t('e.g. researcher') },
        { name: 'prompt', label: t('What it does'), type: 'textarea', placeholder: t('Describe its job in plain words, the way you would brief a colleague.') },
        {
          name: 'model',
          label: t('Model'),
          type: 'select',
          options: [['', t('No model')], ...providers.flatMap((x) => (x.available_models || []).map((m) => [`${x.name}::${m}`, `${m} · ${x.name}`] as [string, string]))],
          value: providers[0]?.available_models?.[0] ? `${providers[0].name}::${providers[0].available_models[0]}` : '',
        },
      ],
      submit: t('Create'),
    });
    if (!v) return;
    const [provider, model] = v.model ? v.model.split('::') : ['', ''];
    const name = v.name.trim();
    let created: string | null = null;
    const ok = await act(model ? t('Created {name}', { name }) : t('Created {name}, turned off until it has a model', { name }), async () => {
      const r = await rpc<{ agent_id: string }>('agents.create', {
        name,
        system_prompt: v.prompt,
        llm_config: model ? { provider, model } : undefined,
        is_active: !!model,
      });
      await rpc('canvas.layout.save', { items: [{ kind: 'agent', id: r.agent_id, ...freeSpot(p.x - NODE_W / 2, p.y - 30, NODE_W, NODE_H, false, groupId) }] });
      if (groupId) await rpc('canvas.groups.set_member', { agent_id: r.agent_id, group_id: groupId });
      created = r.agent_id;
      return { label: t('Created {name}', { name }), run: () => rpc('agents.update', { agent_id: r.agent_id, is_active: false }) };
    });
    if (ok && created) select(created);
  };

  const createGroup = async (p: XY, parent: string | null, members: string[] = [], rect?: { x: number; y: number; w: number; h: number }) => {
    const v = await ask({
      title: members.length ? t('Make a team') : t('New team'),
      fields: [
        { name: 'name', label: t('Team name'), type: 'text', required: true, placeholder: t('e.g. Research team') },
        { name: 'kind', label: t('Kind'), type: 'select', options: [['team', t('Team')], ['division', t('Division')], ['project', t('Project')]] },
      ],
      submit: t('Create'),
    });
    if (!v) return;
    const before = members.map((id) => [id, groupOf(state, id)] as const);
    const label = t('Created {name}', { name: v.name.trim() });
    await act(label, async () => {
      const r = await rpc<{ group_id: string }>('canvas.groups.create', {
        name: v.name.trim(),
        kind: v.kind,
        parent_group_id: parent,
        position: rect ? { x: rect.x, y: rect.y, width: rect.w, height: rect.h } : { ...freeSpot(p.x - 180, p.y - 30, 360, 220, true, parent), width: 360, height: 220 },
        agent_ids: members,
      });
      return {
        label,
        run: async () => {
          // Deleting a box moves its agents up to its parent, which is where
          // they were unless they came from several different groups.
          for (const [id, g] of before) if (g !== parent) await rpc('canvas.groups.set_member', { agent_id: id, group_id: g });
          await rpc('canvas.groups.delete', { group_id: r.group_id });
        },
      };
    });
    setSelected([]);
  };

  // A starting point instead of a blank page: a lead and two members in a
  // team, the lead able to hand work to both. All drafts, turned off, so
  // nothing runs until the user gives them a model.
  const createExample = async (p: XY) => {
    const free = (base: string) => {
      let n = base;
      for (let i = 2; agents.some((a) => a.name.toLowerCase() === n.toLowerCase()); i++) n = `${base}_${i}`;
      return n;
    };
    const names = [free('team_lead'), free('researcher'), free('writer')];
    const prompts = [
      t('Plans the work, splits it into tasks, and hands them to the researcher and the writer.'),
      t('Finds and checks sources, then reports what it found.'),
      t('Turns the findings into a clear, short write-up.'),
    ];
    await act(t('Created an example team. Rename the agents and give them a model to start.'), async () => {
      const ids: string[] = [];
      for (let i = 0; i < 3; i++) ids.push((await rpc<{ agent_id: string }>('agents.create', { name: names[i], system_prompt: prompts[i], is_active: false })).agent_id);
      const box = freeSpot(p.x - 300, p.y - 140, 600, 330, true, null);
      const g = await rpc<{ group_id: string }>('canvas.groups.create', { name: t('Example team'), kind: 'team', position: { ...box, width: 600, height: 330 }, agent_ids: ids });
      await rpc('canvas.delegation.add', { from_agent_id: ids[0], to_agent_id: ids[1] });
      await rpc('canvas.delegation.add', { from_agent_id: ids[0], to_agent_id: ids[2] });
      await rpc('canvas.layout.save', {
        items: [
          { kind: 'agent', id: ids[0], x: box.x + 190, y: box.y + 56 },
          { kind: 'agent', id: ids[1], x: box.x + 40, y: box.y + 210 },
          { kind: 'agent', id: ids[2], x: box.x + 340, y: box.y + 210 },
        ],
      });
      return {
        label: t('Example team'),
        run: async () => {
          await rpc('canvas.groups.delete', { group_id: g.group_id });
          for (const id of ids) await rpc('agents.update', { agent_id: id, is_active: false });
        },
      };
    });
    setTimeout(() => flow.fitView({ padding: 0.25, duration: 300, maxZoom: 1 }), 80);
  };

  const placeTemplate = async (id: string, name: string, p: XY, parent: string | null) => {
    await act(t('Placed {name}', { name }), async () => {
      await rpc('canvas.templates.instantiate', { template_id: id, x: Math.round(p.x), y: Math.round(p.y), parent_group_id: parent });
    });
  };

  const viewportCentre = (): XY => {
    const el = document.querySelector('.flow')?.getBoundingClientRect();
    return flow.screenToFlowPosition({ x: (el?.left || 0) + (el?.width || 800) / 2, y: (el?.top || 0) + (el?.height || 600) / 2 });
  };

  const use = (item: AddItem, p: XY, team: string | null) => {
    if (item.kind === 'agent') return createAgent(p, team);
    if (item.kind === 'group') return createGroup(p, team);
    if (item.kind === 'example') return createExample(p);
    return placeTemplate(item.id, item.name, p, team);
  };

  // Clicked rather than dragged: into the selected team (or the selected
  // agent's team), else the middle of the view.
  const onAddClick = (item: AddItem) => {
    const one = selected.length === 1 ? selected[0] : null;
    const team = one ? (isGroupNode(one) ? groupIdOf(one) : groupOf(state, one)) : null;
    if (team && item.kind !== 'example') {
      const a = absOf(groupNodeId(team));
      const s = sizeOf(groupNodeId(team));
      if (a) return use(item, { x: a.x + s.w / 2, y: a.y + s.h / 2 }, team);
    }
    use(item, viewportCentre(), null);
  };

  const onDragOver = (e: DragEvent) => {
    if (!e.dataTransfer.types.includes(DRAG_MIME)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
    const g = groupAt(flow.screenToFlowPosition({ x: e.clientX, y: e.clientY }));
    setDrop(g ? { target: groupNodeId(g), text: t('Moved into {team}', { team: state.groups.find((x) => x.group_id === g)?.name || '' }) } : null);
  };
  const onDrop = (e: DragEvent) => {
    setDrop(null);
    let item: AddItem | null = null;
    try {
      item = JSON.parse(e.dataTransfer.getData(DRAG_MIME));
    } catch {
      return;
    }
    if (!item) return;
    e.preventDefault();
    const p = flow.screenToFlowPosition({ x: e.clientX, y: e.clientY });
    use(item, p, item.kind === 'example' ? null : groupAt(p));
  };

  // Tidy up: the layout the board would draw if nothing had been placed by
  // hand (each agent under the one that hands it work, boxes sized to fit),
  // written back as positions in one save. Undo restores the previous ones.
  const arrange = () => {
    setMoreOpen(false);
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
      t('Tidied up'),
      async () => {
        await rpc('canvas.layout.save', { items });
        applyPositions(items);
        setTimeout(() => flow.fitView({ padding: 0.2, duration: 300, maxZoom: 1 }), 50);
        return { label: t('Tidy up layout'), run: () => rpc('canvas.layout.save', { items: prev }) };
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
  const empty = agents.filter((a) => !a.is_system && a.name !== 'general').length === 0 && state.groups.length === 0;
  const closeHelp = () => (remember('allgres_canvas_help_seen', true), setHelpOpen(false));

  return (
    <div className="app">
      <header className="bar">
        <a className="brand" href="/">
          Allgres
        </a>
        <a className="btn ghost back" href="/">
          {t('← Dashboard')}
        </a>
        {gate.kind === 'ready' && (
          <>
            <div className="seg" role="group" aria-label={t('Canvas')}>
              <button type="button" className={view === 'org' ? 'on' : ''} aria-pressed={view === 'org'} onClick={() => setView('org')}>
                {t('Organization')}
              </button>
              <button type="button" className={view === 'flow' ? 'on' : ''} aria-pressed={view === 'flow'} onClick={() => setView('flow')}>
                {t('Flow')}
              </button>
            </div>
            <span className="spacer" />
            <button type="button" className="icon-tool" disabled={!undoCount} onClick={undo} title={`${t('Undo')} (⌘Z)`} aria-label={t('Undo')}>
              ↶
            </button>
            <div className="zoom" role="group">
              <button type="button" className="icon-tool" onClick={() => flow.zoomOut({ duration: 150 })} aria-label={t('Zoom out')}>
                −
              </button>
              <button type="button" className="icon-tool num" onClick={() => flow.fitView({ padding: 0.2, duration: 250, maxZoom: 1 })} title={t('Fit to screen')}>
                {Math.round(zoom * 100)}%
              </button>
              <button type="button" className="icon-tool" onClick={() => flow.zoomIn({ duration: 150 })} aria-label={t('Zoom in')}>
                +
              </button>
            </div>
            <div className="seg lang" role="group" aria-label={t('Language')}>
              <button type="button" className={lang === 'ko' ? 'on' : ''} aria-pressed={lang === 'ko'} onClick={() => setLang('ko')}>
                한
              </button>
              <button type="button" className={lang === 'en' ? 'on' : ''} aria-pressed={lang === 'en'} onClick={() => setLang('en')}>
                EN
              </button>
            </div>
            <div className="more">
              <button type="button" className="icon-tool" aria-haspopup="menu" aria-expanded={moreOpen} aria-label={t('More')} onClick={() => setMoreOpen((v) => !v)}>
                ⋯
              </button>
              {moreOpen && (
                <div className="more-pop" role="menu">
                  <label className="check">
                    <input id="showSystem" type="checkbox" checked={showSystem} onChange={(e) => setShowSystem(e.target.checked)} />
                    <span>{t('Show system agents')}</span>
                  </label>
                  <label className="check">
                    <input id="showInactive" type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
                    <span>{t('Show inactive agents')}</span>
                  </label>
                  <hr />
                  <button type="button" role="menuitem" onClick={arrange}>
                    {t('Tidy up layout')}
                  </button>
                  <button type="button" role="menuitem" onClick={() => (setMoreOpen(false), setHelpOpen(true))}>
                    {t('How to read the board')}
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setMoreOpen(false);
                      Promise.all([reload(), loadOptions()]).then(() => toast(t('Refreshed'))).catch((e) => toast(message(e), true));
                    }}
                  >
                    {t('Refresh')}
                  </button>
                </div>
              )}
            </div>
          </>
        )}
      </header>
      <main className="stage">
        {gate.kind === 'loading' && <div className="notice">{t('Loading agents…')}</div>}
        {gate.kind === 'blocked' && (
          <div className="notice">
            <b>{gate.title}</b>
            <p>{gate.body}</p>
            <a className="btn primary" href="/">
              {t('Open dashboard')}
            </a>
          </div>
        )}
        {gate.kind === 'ready' && (
          <BoardEvents.Provider value={{ onGroupResized, dropTarget: drop?.target || null, dropText: drop?.text || null }}>
            <div className="flow" onDragOver={onDragOver} onDrop={onDrop} onDragLeave={() => setDrop(null)}>
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
                <Background gap={24} size={1} />
              </ReactFlow>
              {view === 'org' && <AddMenu board={board} onUse={onAddClick} />}
              {empty && view === 'org' && (
                <div className="empty-card" role="region" aria-label={t('Build your first team')}>
                  <div className="empty-art" aria-hidden>
                    <span />
                    <span />
                    <span />
                  </div>
                  <h2>{t('Build your first team')}</h2>
                  <p>{t('Add agents, then drop one onto another to decide who hands work to whom.')}</p>
                  <div className="row-center">
                    <button type="button" className="btn primary" onClick={() => onAddClick({ kind: 'agent' })}>
                      {t('Add an agent')}
                    </button>
                    <button type="button" className="btn" onClick={() => onAddClick({ kind: 'example' })}>
                      {t('Start from an example')}
                    </button>
                  </div>
                </div>
              )}
              {connectFrom && (
                <div className="hint-banner" role="status">
                  {t('Drop on an agent: {name} will be able to hand work to it. Release anywhere else to cancel.', { name: agents.find((a) => a.agent_id === connectFrom)?.name || '' })}
                </div>
              )}
              {groupable > 1 && view === 'org' && (
                <div className="selection-bar" role="toolbar">
                  <span>{t('{n} selected', { n: groupable })}</span>
                  <button type="button" className="btn primary" onClick={groupSelected}>
                    {t('Make a team')}
                  </button>
                  <button type="button" className="btn ghost" onClick={() => (setSelected([]), flowSetSelected(null))}>
                    {t('Clear selection')}
                  </button>
                </div>
              )}
              {helpOpen && <Help view={view} showSystem={showSystem} onClose={closeHelp} />}
              {!helpOpen && (
                <button type="button" className="help-btn" onClick={() => setHelpOpen(true)} aria-label={t('Help')} title={t('How to read the board')}>
                  ?
                </button>
              )}
              {general && general.is_active && (
                <div className={`ask${chatOpen ? ' open' : ''}`}>
                  {chatOpen ? (
                    <section aria-label={t('Ask General')}>
                      <header>
                        <b>General</b>
                        <span className="spacer" />
                        <button type="button" className="icon-btn" onClick={() => setChatOpen(false)} aria-label={t('Hide')}>
                          ×
                        </button>
                      </header>
                      <Chat agentId={general.agent_id} agentName="General" />
                    </section>
                  ) : (
                    <button type="button" className="ask-btn" onClick={() => setChatOpen(true)}>
                      💬 {t('Ask General')}
                    </button>
                  )}
                </div>
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

// What every mark on the board means, in plain words. Shown once on the
// first visit, then behind the ? button.
function Help({ view, showSystem, onClose }: { view: 'org' | 'flow'; showSystem: boolean; onClose: () => void }) {
  const t = useT();
  const rows: [string, string, string][] =
    view === 'flow'
      ? [
          ['lg-active', 'Handed work', 'A really gave B a task in recent work; ×N is how often.'],
          ['lg-delegate dim', 'Hands work to', 'Lines that were not used fade out.'],
        ]
      : [
          ['lg-delegate', 'Hands work to', 'A can give B a task. Drag one card onto another to set this up; click the line to remove it.'],
          ...(showSystem ? ([['lg-parent', 'Inherits', "The lower system agent gets the upper one's abilities and base instructions."]] as [string, string, string][]) : []),
          ['lg-box', 'Team', 'A box that keeps agents together. It grants nothing by itself.'],
        ];
  return (
    <aside className="help" aria-label={t('How to read the board')}>
      <h3>{t('How to read the board')}</h3>
      <dl>
        {rows.map(([cls, title, body]) => (
          <div className="help-row" key={title}>
            <dt>
              <i className={cls} />
            </dt>
            <dd>
              <b>{t(title)}</b>
              <span>{t(body)}</span>
            </dd>
          </div>
        ))}
      </dl>
      <div className="row-end">
        <button type="button" className="btn primary" onClick={onClose}>
          {t('Got it')}
        </button>
      </div>
    </aside>
  );
}

export function App() {
  return (
    <LangProvider>
      <ReactFlowProvider>
        <Canvas />
      </ReactFlowProvider>
    </LangProvider>
  );
}
