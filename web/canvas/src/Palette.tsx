import { useState, type DragEvent } from 'react';
import { rpc } from './api';
import type { Board } from './board';

export const DRAG_MIME = 'application/x-allgres-canvas';

export type PaletteItem =
  | { kind: 'agent' }
  | { kind: 'group' }
  | { kind: 'skill'; type: 'view' | 'function' | 'procedure' | 'http_host'; ref: string }
  | { kind: 'template'; id: string; name: string };

const start = (item: PaletteItem) => (e: DragEvent) => {
  e.dataTransfer.setData(DRAG_MIME, JSON.stringify(item));
  e.dataTransfer.effectAllowed = 'copy';
};

type ItemProps = { item: PaletteItem; icon: string; title: string; sub: string; className?: string; onUse: (item: PaletteItem) => void };

function Item({ item, icon, title, sub, className = '', onUse }: ItemProps) {
  return (
    <button type="button" className={`pal-item ${className}`} draggable onDragStart={start(item)} onClick={() => onUse(item)} title="Drag onto the board, or click">
      <span className="pal-icon" aria-hidden>
        {icon}
      </span>
      <span className="pal-text">
        <b>{title}</b>
        <small>{sub}</small>
      </span>
    </button>
  );
}

// Clicking an item does what dropping it does, at the centre of the view or
// on the selected agent, so the palette also works without a mouse.
export function Palette({ board, onUse, open }: { board: Board; onUse: (item: PaletteItem) => void; open: boolean }) {
  const [filter, setFilter] = useState('');
  const skills: PaletteItem[] = [
    ...board.options.functions.map((ref) => ({ kind: 'skill', type: 'function', ref }) as const),
    ...board.options.procedures.map((ref) => ({ kind: 'skill', type: 'procedure', ref }) as const),
    ...board.options.views.map((ref) => ({ kind: 'skill', type: 'view', ref }) as const),
  ].filter((s) => !filter || (s.kind === 'skill' && s.ref.toLowerCase().includes(filter.toLowerCase())));
  return (
    <nav className={`palette${open ? ' open' : ''}`} aria-label="Blocks">
      <h4>Blocks</h4>
      <Item onUse={onUse} item={{ kind: 'agent' }} icon="A" title="Agent" sub="Created where you drop it" />
      <Item onUse={onUse} item={{ kind: 'group' }} icon="▢" title="Group box" sub="Team, division, project" />
      <h4>Skills</h4>
      <input className="pal-filter" aria-label="Filter skills" placeholder="Filter" value={filter} onChange={(e) => setFilter(e.target.value)} />
      <div className="pal-scroll">
        {skills.map((s) =>
          s.kind === 'skill' ? <Item onUse={onUse} key={`${s.type}:${s.ref}`} item={s} icon={s.type === 'view' ? 'V' : s.type === 'procedure' ? 'P' : 'ƒ'} title={s.ref} sub={s.type} className="skill" /> : null,
        )}
        <Item onUse={onUse} item={{ kind: 'skill', type: 'http_host', ref: '' }} icon="⇄" title="HTTP host…" sub="Name a host when dropped" className="skill" />
      </div>
      <h4>Saved configurations</h4>
      {board.state.templates.length === 0 && <p className="muted small">Select a group and choose “Save as configuration”.</p>}
      {board.state.templates.map((t) => (
        <div className="pal-row" key={t.template_id}>
          <Item onUse={onUse} item={{ kind: 'template', id: t.template_id, name: t.name }} icon="⧉" title={t.name} sub={`${t.agents} agents · ${t.groups} groups`} />
          <button
            type="button"
            className="icon-btn"
            aria-label={`Delete saved configuration ${t.name}`}
            onClick={async () => {
              if (await board.confirm(`Delete “${t.name}”?`, <p>Only the saved configuration is removed; agents created from it stay.</p>, 'Delete', true))
                board.act(`Deleted ${t.name}`, async () => void (await rpc('canvas.templates.delete', { template_id: t.template_id })));
            }}
          >
            ×
          </button>
        </div>
      ))}
      <p className="pal-help muted small">
        Drag a node to move it or put it in a group · drag from an agent's bottom dot to another agent to let it delegate · click a line to remove
        it · Shift+click to select several · ⌘/Ctrl+Z undoes
      </p>
    </nav>
  );
}
