import { useCallback, useEffect, useRef, useState } from 'react';
import { rpc, RpcError, type ChatHistory } from './api';
import { useT } from './i18n';

// The same 1:1 conversation the dashboard's Chat page has with this agent
// (chat.send / chat.history, one continuing session per user and agent), so
// a message sent here shows up there and the other way round.
export function Chat({ agentId, agentName, note }: { agentId: string; agentName: string; note?: string }) {
  const t = useT();
  const [history, setHistory] = useState<ChatHistory | null>(null);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const list = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    try {
      setHistory(await rpc<ChatHistory>('chat.history', { agent_id: agentId }));
      setError(null);
    } catch (e) {
      setError(e instanceof RpcError ? e.code : String(e));
    }
  }, [agentId]);

  // The web listener allows 120 requests a minute per address, shared with
  // any dashboard tab, so poll quickly only while a reply is outstanding.
  const last = history?.messages[history.messages.length - 1];
  const waiting = (last?.role === 'user' || last?.role === 'operator') && Date.now() - new Date(last.created_at).getTime() < 5 * 60_000;
  useEffect(() => {
    setHistory(null);
    load();
  }, [load]);
  useEffect(() => {
    const t = setInterval(() => document.visibilityState === 'visible' && load(), waiting ? 3000 : 30000);
    return () => clearInterval(t);
  }, [load, waiting]);

  const count = history?.messages.length || 0;
  useEffect(() => {
    list.current?.scrollTo({ top: list.current.scrollHeight });
  }, [count]);

  const send = async () => {
    const m = text.trim();
    if (!m || busy) return;
    setBusy(true);
    try {
      await rpc('chat.send', { agent_id: agentId, message: m });
      setText('');
      await load();
    } catch (e) {
      setError(e instanceof RpcError ? e.code : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="chat">
      {note && <p className="muted small">{note}</p>}
      <div className="chat-tools">
        <button
          type="button"
          className="btn ghost"
          onClick={async () => {
            if (!window.confirm(t('Start a new chat? The earlier one stays under Activity.'))) return;
            try {
              await rpc('chat.new', { agent_id: agentId });
              setHistory(null);
              await load();
            } catch (e) {
              setError(e instanceof RpcError ? e.code : String(e));
            }
          }}
        >
          {t('New chat')}
        </button>
      </div>
      <div className="msgs" ref={list} aria-live="polite">
        {history?.messages.map((m, i) => (
          <div key={i} className={`msg ${m.role === 'assistant' ? 'them' : 'me'}`}>
            {m.role === 'assistant' && <span className="who">{agentName}</span>}
            {m.content}
          </div>
        ))}
        {history && !count && <p className="muted small">{t('No messages yet.')}</p>}
        {waiting && <div className="msg them typing">{t('{name} is working…', { name: agentName })}</div>}
      </div>
      {error && (
        <p className="error-text small">
          {/not logged in/i.test(error) ? t('Chat is tied to an account: sign in on the dashboard in this tab to talk to agents.') : error}
        </p>
      )}
      <form
        className="composer"
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        <input
          aria-label={t('Message {name}', { name: agentName })}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={t('Message {name}', { name: agentName })}
          autoComplete="off"
        />
        <button type="submit" className="btn primary" disabled={busy || !text.trim()}>
          {t('Send')}
        </button>
      </form>
    </div>
  );
}
