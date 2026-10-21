import { useEffect, useMemo, useState } from 'react';
import { rpc, type SessionDetail, type SessionRow } from './api';
import type { RunMark } from './graph';
import { timeAgo } from './ui';

export interface FlowOverlay {
  marks: Map<string, RunMark>;
  /** "fromAgentId>toAgentId" for every hand-off shown so far. */
  handoffs: Set<string>;
}

type Event = { at: string; taskId: string; agentId: string; agent: string; kind: 'start' | 'done' | 'failed' | 'waiting'; from?: string; text: string };

const LIVE = new Set(['queued', 'running', 'waiting_human', 'waiting_children']);
const short = (v: unknown, n = 180) => {
  const s = typeof v === 'string' ? v : JSON.stringify(v);
  return s.length > n ? `${s.slice(0, n)}…` : s;
};

function eventsOf(d: SessionDetail): Event[] {
  const byTask = new Map(d.tasks.map((t) => [t.task_id, t]));
  const ev: Event[] = [];
  for (const t of d.tasks) {
    const parent = t.parent_task_id ? byTask.get(t.parent_task_id) : undefined;
    const firstLog = d.logs.find((l) => l.task_id === t.task_id && (l.role === 'user' || l.role === 'operator'));
    ev.push({
      at: t.created_at,
      taskId: t.task_id,
      agentId: t.agent_id,
      agent: t.agent,
      kind: 'start',
      from: parent?.agent_id,
      text: parent ? `${parent.agent} → ${t.agent}${firstLog ? `: ${short(firstLog.content, 120)}` : ''}` : `Started: ${short(firstLog?.content ?? d.session.goal, 120)}`,
    });
    if (t.status === 'completed' || t.status === 'failed')
      ev.push({
        at: t.updated_at,
        taskId: t.task_id,
        agentId: t.agent_id,
        agent: t.agent,
        kind: t.status === 'completed' ? 'done' : 'failed',
        text: t.status === 'failed' ? `Failed${t.error ? `: ${short(t.error, 120)}` : ''}` : `Finished after ${t.step_count} steps`,
      });
    else if (t.status.startsWith('waiting'))
      ev.push({ at: t.updated_at, taskId: t.task_id, agentId: t.agent_id, agent: t.agent, kind: 'waiting', text: t.status.replace('_', ' ') });
  }
  return ev.sort((a, b) => a.at.localeCompare(b.at));
}

function overlayAt(events: Event[], upto: number): FlowOverlay {
  const marks = new Map<string, RunMark>();
  const handoffs = new Set<string>();
  for (const e of events.slice(0, upto + 1)) {
    if (e.kind === 'start') {
      marks.set(e.agentId, 'running');
      if (e.from && e.from !== e.agentId) handoffs.add(`${e.from}>${e.agentId}`);
    } else if (e.kind === 'waiting') marks.set(e.agentId, 'running');
    else marks.set(e.agentId, e.kind);
  }
  return { marks, handoffs };
}

export function FlowPanel({
  sessionId,
  onSession,
  onOverlay,
  onSelectAgent,
}: {
  sessionId: string | null;
  onSession: (id: string | null) => void;
  onOverlay: (o: FlowOverlay | null) => void;
  onSelectAgent: (agentId: string) => void;
}) {
  const [sessions, setSessions] = useState<SessionRow[] | null>(null);
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [step, setStep] = useState<number | null>(null); // null = live (everything)
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    rpc<{ sessions: SessionRow[] }>('sessions.list', { limit: 40 })
      .then((r) => setSessions(r.sessions))
      .catch((e) => setError(String(e.message || e)));
  }, [sessionId]);

  useEffect(() => {
    setDetail(null);
    setStep(null);
    setPlaying(false);
    if (!sessionId) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    // Re-read only while some task in the session is still moving.
    const load = () =>
      rpc<SessionDetail>('sessions.get', { session_id: sessionId })
        .then((d) => {
          if (!live) return;
          setDetail(d);
          setError(null);
          if (d.tasks.some((t) => LIVE.has(t.status))) timer = setTimeout(load, 4000);
        })
        .catch((e) => live && setError(String(e.message || e)));
    load();
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [sessionId]);

  const events = useMemo(() => (detail ? eventsOf(detail) : []), [detail]);
  const at = step === null ? events.length - 1 : step;

  useEffect(() => {
    onOverlay(detail ? overlayAt(events, at) : null);
  }, [detail, events, at, onOverlay]);
  useEffect(() => () => onOverlay(null), [onOverlay]);

  useEffect(() => {
    if (!playing) return;
    if (at >= events.length - 1) {
      setPlaying(false);
      return;
    }
    const t = setTimeout(() => setStep(at + 1), 900);
    return () => clearTimeout(t);
  }, [playing, at, events.length]);

  if (!sessionId)
    return (
      <aside className="inspector flow-panel" aria-label="Flow">
        <header className="in-head">
          <div className="in-title">
            <b>Flow</b>
            <small>Pick a session to see how work moved between agents</small>
          </div>
        </header>
        <div className="in-body">
          {error && <p className="error-text small">{error}</p>}
          {sessions === null && !error && <p className="muted">Loading…</p>}
          {sessions?.length === 0 && <p className="muted">No sessions yet. Give an agent a task from its History tab, or chat with General below.</p>}
          <ul className="task-list">
            {sessions?.map((s) => (
              <li key={s.session_id}>
                <button type="button" onClick={() => onSession(s.session_id)}>
                  <span className={`status s-${s.status}`}>{s.status}</span>
                  <span className="goal">
                    <b>{s.agent}</b> · {s.goal}
                  </span>
                  <small className="muted">{timeAgo(s.started_at)}</small>
                </button>
              </li>
            ))}
          </ul>
        </div>
      </aside>
    );

  const running = detail?.tasks.some((t) => LIVE.has(t.status));
  return (
    <aside className="inspector flow-panel" aria-label="Flow">
      <header className="in-head">
        <div className="in-title">
          <b>{detail?.session.goal || 'Session'}</b>
          <small>
            {detail ? `${detail.session.agent} · ${detail.tasks.length} tasks · ${running ? 'in progress' : detail.session.status}` : 'Loading…'}
          </small>
        </div>
        <button type="button" className="icon-btn" onClick={() => onSession(null)} aria-label="Back to sessions">
          ←
        </button>
      </header>
      <div className="replay">
        <button type="button" className="btn" disabled={!events.length} onClick={() => (setStep(0), setPlaying(true))}>
          ▶ Replay
        </button>
        <button type="button" className="btn" disabled={at <= 0} onClick={() => (setPlaying(false), setStep(Math.max(0, at - 1)))} aria-label="Previous step">
          ‹
        </button>
        <button
          type="button"
          className="btn"
          disabled={at >= events.length - 1}
          onClick={() => (setPlaying(false), setStep(Math.min(events.length - 1, at + 1)))}
          aria-label="Next step"
        >
          ›
        </button>
        <button type="button" className="btn ghost" disabled={step === null} onClick={() => (setPlaying(false), setStep(null))}>
          Live
        </button>
        <span className="muted small">{events.length ? `${at + 1} / ${events.length}` : ''}</span>
      </div>
      <div className="in-body">
        {error && <p className="error-text small">{error}</p>}
        <ol className="timeline">
          {events.map((e, i) => (
            <li key={`${e.taskId}:${e.kind}`} className={`ev k-${e.kind}${i === at ? ' now' : ''}${i > at ? ' later' : ''}`}>
              <button type="button" onClick={() => (setPlaying(false), setStep(i), onSelectAgent(e.agentId))}>
                <span className="ev-who">{e.agent}</span>
                <span className="ev-text">{e.text}</span>
                <small className="muted">{new Date(e.at).toLocaleTimeString()}</small>
              </button>
            </li>
          ))}
        </ol>
        {detail?.session.final_answer && (
          <section>
            <h4>Answer</h4>
            <pre className="prompt">{detail.session.final_answer}</pre>
          </section>
        )}
      </div>
    </aside>
  );
}
