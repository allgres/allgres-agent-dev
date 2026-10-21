import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';

export type Field =
  | { name: string; label: string; type: 'text'; value?: string; required?: boolean; placeholder?: string; list?: string[] }
  | { name: string; label: string; type: 'textarea'; value?: string; required?: boolean; placeholder?: string }
  | { name: string; label: string; type: 'select'; value?: string; options: [string, string][] }
  | { name: string; label: string; type: 'checkbox'; value?: string; hint?: string };

export interface DialogSpec {
  title: string;
  body?: ReactNode;
  fields?: Field[];
  submit: string;
  danger?: boolean;
  cancel?: string;
}

type Open = DialogSpec & { resolve: (v: Record<string, string> | null) => void };

// One modal at a time, awaited like window.prompt/confirm but styled and
// accessible (focus moves in, Escape cancels, Enter submits).
export function useDialog() {
  const [open, setOpen] = useState<Open | null>(null);
  const ask = useCallback(
    (spec: DialogSpec) => new Promise<Record<string, string> | null>((resolve) => setOpen({ ...spec, resolve })),
    [],
  );
  const confirm = useCallback(
    async (title: string, body: ReactNode, submit = 'Continue', danger = false) =>
      (await ask({ title, body, submit, danger })) !== null,
    [ask],
  );
  const close = (v: Record<string, string> | null) => {
    open?.resolve(v);
    setOpen(null);
  };
  const element = open ? <Dialog spec={open} onClose={close} /> : null;
  return { ask, confirm, element };
}

function Dialog({ spec, onClose }: { spec: DialogSpec; onClose: (v: Record<string, string> | null) => void }) {
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries((spec.fields || []).map((f) => [f.name, f.value ?? (f.type === 'select' ? f.options[0]?.[0] ?? '' : '')])),
  );
  const first = useRef<HTMLElement | null>(null);
  useEffect(() => {
    first.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  const missing = (spec.fields || []).some((f) => 'required' in f && f.required && !values[f.name]?.trim());
  const set = (k: string, v: string) => setValues((x) => ({ ...x, [k]: v }));
  return (
    <div className="modal-back" onMouseDown={(e) => e.target === e.currentTarget && onClose(null)}>
      <form
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label={spec.title}
        onSubmit={(e) => {
          e.preventDefault();
          if (!missing) onClose(values);
        }}
      >
        <h3>{spec.title}</h3>
        {spec.body && <div className="modal-body">{spec.body}</div>}
        {(spec.fields || []).map((f, i) => {
          const ref = i === 0 ? (el: HTMLElement | null) => (first.current = el) : undefined;
          const id = `dlg-${f.name}`;
          if (f.type === 'checkbox')
            return (
              <label className="check" key={f.name}>
                <input id={id} ref={ref} type="checkbox" checked={values[f.name] === 'true'} onChange={(e) => set(f.name, String(e.target.checked))} />
                <span>
                  {f.label}
                  {f.hint && <small className="muted"> {f.hint}</small>}
                </span>
              </label>
            );
          return (
            <div className="field" key={f.name}>
              <label htmlFor={id}>{f.label}</label>
              {f.type === 'textarea' ? (
                <textarea id={id} ref={ref} rows={4} value={values[f.name]} placeholder={f.placeholder} onChange={(e) => set(f.name, e.target.value)} />
              ) : f.type === 'select' ? (
                <select id={id} ref={ref} value={values[f.name]} onChange={(e) => set(f.name, e.target.value)}>
                  {f.options.map(([v, l]) => (
                    <option key={v} value={v}>
                      {l}
                    </option>
                  ))}
                </select>
              ) : (
                <>
                  <input
                    id={id}
                    ref={ref}
                    value={values[f.name]}
                    placeholder={f.placeholder}
                    autoComplete="off"
                    list={f.list ? `${id}-list` : undefined}
                    onChange={(e) => set(f.name, e.target.value)}
                  />
                  {f.list && (
                    <datalist id={`${id}-list`}>
                      {f.list.map((v) => (
                        <option key={v} value={v} />
                      ))}
                    </datalist>
                  )}
                </>
              )}
            </div>
          );
        })}
        <div className="modal-actions">
          <button type="button" className="btn" onClick={() => onClose(null)}>
            {spec.cancel || 'Cancel'}
          </button>
          <button type="submit" className={`btn ${spec.danger ? 'danger' : 'primary'}`} disabled={missing} ref={spec.fields?.length ? undefined : (el) => (first.current = el)}>
            {spec.submit}
          </button>
        </div>
      </form>
    </div>
  );
}

export function useToast() {
  const [msg, setMsg] = useState<{ text: string; bad: boolean; id: number } | null>(null);
  useEffect(() => {
    if (!msg) return;
    const t = setTimeout(() => setMsg(null), msg.bad ? 6000 : 2600);
    return () => clearTimeout(t);
  }, [msg]);
  const toast = useCallback((text: string, bad = false) => setMsg({ text, bad, id: Date.now() }), []);
  const element = msg ? (
    <div className={`toast${msg.bad ? ' bad' : ''}`} role="status" key={msg.id}>
      {msg.text}
    </div>
  ) : null;
  return { toast, element };
}

export function timeAgo(iso: string): string {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return new Date(iso).toLocaleDateString();
}
