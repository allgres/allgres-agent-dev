import { useEffect, useRef, useState, type DragEvent } from 'react';
import { rpc } from './api';
import type { Board } from './board';
import { useT } from './i18n';

export const DRAG_MIME = 'application/x-allgres-canvas';

export type AddItem = { kind: 'agent' } | { kind: 'group' } | { kind: 'example' } | { kind: 'template'; id: string; name: string };

const start = (item: AddItem) => (e: DragEvent) => {
  e.dataTransfer.setData(DRAG_MIME, JSON.stringify(item));
  e.dataTransfer.effectAllowed = 'copy';
};

// One entry point for everything that can be added, instead of a permanent
// palette competing with the board. Every row can be clicked (it lands in
// the middle of the view, or in the selected team) or dragged to a spot.
export function AddMenu({ board, onUse }: { board: Board; onUse: (item: AddItem) => void }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => !root.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', away);
    document.addEventListener('keydown', esc);
    return () => {
      document.removeEventListener('mousedown', away);
      document.removeEventListener('keydown', esc);
    };
  }, [open]);
  const pick = (item: AddItem) => {
    setOpen(false);
    onUse(item);
  };
  const Row = ({ item, icon, title, sub }: { item: AddItem; icon: string; title: string; sub: string }) => (
    <button type="button" role="menuitem" className="add-row" draggable onDragStart={start(item)} onDragEnd={() => setOpen(false)} onClick={() => pick(item)} title={t('Drag onto the board, or click')}>
      <span className="add-icon" aria-hidden>
        {icon}
      </span>
      <span className="add-text">
        <b>{title}</b>
        <small>{sub}</small>
      </span>
    </button>
  );
  return (
    <div className="add-menu" ref={root}>
      <button type="button" className="btn primary add-btn" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <span aria-hidden>＋</span> {t('Add')}
      </button>
      {open && (
        <div className="add-pop" role="menu" aria-label={t('Add to the board')}>
          {Row({ item: { kind: 'agent' }, icon: '◉', title: t('New agent'), sub: t('Someone who does one kind of work') })}
          {Row({ item: { kind: 'group' }, icon: '▢', title: t('New team'), sub: t('A box to keep agents together') })}
          {Row({ item: { kind: 'example' }, icon: '✦', title: t('Example team'), sub: t('A lead with two members, ready to edit') })}
          {board.state.templates.length > 0 && <div className="add-sep">{t('Saved teams')}</div>}
          {board.state.templates.map((tp) => (
            <div className="add-saved" key={tp.template_id}>
              {Row({ item: { kind: 'template', id: tp.template_id, name: tp.name }, icon: '⧉', title: tp.name, sub: t('{n} agents', { n: tp.agents }) })}
              <button
                type="button"
                className="icon-btn"
                aria-label={t('Delete saved team {name}', { name: tp.name })}
                onClick={async () => {
                  setOpen(false);
                  if (await board.confirm(t('Delete “{name}”?', { name: tp.name }), <p>{t('Only the saved team is removed; agents created from it stay.')}</p>, t('Delete'), true))
                    board.act(t('Deleted {name}', { name: tp.name }), async () => void (await rpc('canvas.templates.delete', { template_id: tp.template_id })));
                }}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
