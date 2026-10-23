import type { ReactNode } from 'react';
import type { Agent, CanvasState, GrantOptions, GrantType, Provider } from './api';
import type { DialogSpec } from './ui';

/** How to reverse one change, pushed onto the board's undo list. */
export interface Undo {
  label: string;
  run: () => Promise<unknown>;
}

// What the panels around the board share. Every change goes through act():
// it runs the RPCs, reports a failure, re-reads the database (skipped for a
// pure layout change the board already shows), and records
// the undo step the change returned (if it has one).
export interface Board {
  agents: Agent[];
  state: CanvasState;
  providers: Provider[];
  options: GrantOptions;
  act: (label: string, fn: () => Promise<Undo | void>, opts?: { layoutOnly?: boolean }) => Promise<boolean>;
  grant: (agent: Agent, type: Exclude<GrantType, 'agent'>, ref: string) => Promise<boolean>;
  ask: (spec: DialogSpec) => Promise<Record<string, string> | null>;
  confirm: (title: string, body: ReactNode, submit?: string, danger?: boolean) => Promise<boolean>;
  toast: (text: string, bad?: boolean) => void;
  select: (nodeId: string | null) => void;
  openSession: (sessionId: string) => void;
}

export const groupOf = (state: CanvasState, agentId: string) =>
  state.members.find((m) => m.agent_id === agentId)?.group_id || null;

export function agentByName(agents: Agent[], name: string) {
  const n = name.toLowerCase();
  return agents.find((a) => a.name.toLowerCase() === n);
}
