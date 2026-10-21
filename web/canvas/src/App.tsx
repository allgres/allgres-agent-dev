import { useCallback, useEffect, useMemo, useState } from 'react';
import { Background, Controls, MiniMap, ReactFlow, ReactFlowProvider, useReactFlow, type Node } from '@xyflow/react';
import { rpc, RpcError, type Agent, type Me } from './api';
import { buildGraph } from './graph';
import { nodeTypes } from './nodes';
import { Inspector } from './Inspector';

type Gate = { kind: 'loading' } | { kind: 'blocked'; title: string; body: string } | { kind: 'ready'; me: Me };

function theme(): 'dark' | 'light' {
  try {
    return localStorage.getItem('allgres_theme') === 'light' ? 'light' : 'dark';
  } catch {
    return 'dark';
  }
}

function explain(e: unknown): { title: string; body: string } {
  const code = e instanceof RpcError ? e.code : String(e);
  if (code === 'unauthorized')
    return { title: 'Dashboard token required', body: 'Open the dashboard in this tab, enter the dashboard token, then come back to Canvas.' };
  if (/not logged in/i.test(code))
    return { title: 'Sign in first', body: 'Sign in on the dashboard in this tab, then open Canvas from the menu.' };
  if (/admin/i.test(code)) return { title: 'Admins only', body: 'Canvas shows every agent and its grants, so it needs an admin account.' };
  return { title: 'Canvas could not load', body: code };
}

function Canvas() {
  const [gate, setGate] = useState<Gate>({ kind: 'loading' });
  const [agents, setAgents] = useState<Agent[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [showSystem, setShowSystem] = useState(true);
  const [showInactive, setShowInactive] = useState(false);
  const [loadedAt, setLoadedAt] = useState<Date | null>(null);
  const [error, setError] = useState<string | null>(null);
  const flow = useReactFlow();

  const load = useCallback(async () => {
    try {
      const r = await rpc<{ agents: Agent[] }>('agents.list');
      setAgents(r.agents);
      setLoadedAt(new Date());
      setError(null);
    } catch (e) {
      setError(explain(e).body);
    }
  }, []);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme());
    (async () => {
      try {
        const me = await rpc<Me>('auth.me');
        const r = await rpc<{ agents: Agent[] }>('agents.list');
        setAgents(r.agents);
        setLoadedAt(new Date());
        setGate({ kind: 'ready', me });
      } catch (e) {
        setGate({ kind: 'blocked', ...explain(e) });
      }
    })();
  }, []);

  // Other operators, the dashboard, and agents themselves change this data,
  // so the canvas re-reads it whenever the tab comes back into view.
  useEffect(() => {
    const onFocus = () => document.visibilityState === 'visible' && gate.kind === 'ready' && load();
    document.addEventListener('visibilitychange', onFocus);
    return () => document.removeEventListener('visibilitychange', onFocus);
  }, [gate.kind, load]);

  const graph = useMemo(() => buildGraph(agents, { showSystem, showInactive }), [agents, showSystem, showInactive]);
  const nodes = useMemo(() => graph.nodes.map((n) => (n.id === selected ? { ...n, selected: true } : n)), [graph, selected]);

  useEffect(() => {
    if (gate.kind === 'ready') requestAnimationFrame(() => flow.fitView({ padding: 0.15, duration: 200 }));
  }, [gate.kind, showSystem, showInactive, flow]);

  const current = agents.find((a) => a.agent_id === selected) || null;
  const onNodeClick = useCallback((_: unknown, n: Node) => n.type === 'agent' && setSelected(n.id), []);

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
        <span className="spacer" />
        {gate.kind === 'ready' && (
          <>
            <span className="muted small">
              {graph.count} agents{loadedAt ? ` · read ${loadedAt.toLocaleTimeString()}` : ''}
            </span>
            <label className="toggle">
              <input id="showSystem" type="checkbox" checked={showSystem} onChange={(e) => setShowSystem(e.target.checked)} />
              System agents
            </label>
            <label className="toggle">
              <input id="showInactive" type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
              Inactive
            </label>
            <button type="button" className="btn" onClick={load}>
              Refresh
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
          <>
            <div className="flow">
              <ReactFlow
                nodes={nodes}
                edges={graph.edges}
                nodeTypes={nodeTypes}
                onNodeClick={onNodeClick}
                onPaneClick={() => setSelected(null)}
                nodesDraggable={false}
                nodesConnectable={false}
                elementsSelectable
                colorMode={theme()}
                minZoom={0.2}
                maxZoom={1.75}
                proOptions={{ hideAttribution: true }}
                fitView
              >
                <Background gap={22} size={1.2} />
                <Controls showInteractive={false} />
                <MiniMap pannable zoomable className="minimap" />
              </ReactFlow>
              {graph.count === 0 && (
                <div className="notice overlay">
                  <b>No agents to show</b>
                  <p>Create an agent on the Agents page, or turn on System agents above.</p>
                </div>
              )}
              <div className="legend" aria-label="Legend">
                <span>
                  <i className="lg-parent" /> parent
                </span>
                <span>
                  <i className="lg-delegate" /> may delegate to
                </span>
                <span className="muted">Read-only. Change agents on the Agents page.</span>
              </div>
              {error && <div className="error-banner">Refresh failed: {error}</div>}
            </div>
            {current && <Inspector agent={current} all={agents} onClose={() => setSelected(null)} />}
          </>
        )}
      </main>
    </div>
  );
}

export function App() {
  return (
    <ReactFlowProvider>
      <Canvas />
    </ReactFlowProvider>
  );
}
