import type { GrantType } from './api';
import type { T } from './i18n';

// Plain-language names for abilities. The stored refs are database names
// (allgres_public.v_my_tasks, http_get); a non-developer should read "Read:
// My tasks" or "Read web pages" instead, with the real name only in a tooltip.

const FUNCTIONS: Record<string, string> = {
  http_get: 'Read web pages',
  http_request: 'Call web services',
};

function humanize(ref: string) {
  const bare = ref.replace(/^allgres_public\./, '').replace(/^v_/, '');
  const words = bare.replace(/[_-]+/g, ' ').trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function abilityLabel(t: T, type: GrantType | string, ref: string) {
  if (type === 'function') return FUNCTIONS[ref] ? t(FUNCTIONS[ref]) : t('Use: {what}', { what: humanize(ref) });
  if (type === 'view') return t('Read: {what}', { what: humanize(ref) });
  if (type === 'procedure') return t('Run: {what}', { what: humanize(ref) });
  if (type === 'http_host') return t('Reach {host}', { host: ref });
  return ref;
}

/** Which heading an ability sits under in pickers. */
export function abilityGroup(t: T, type: GrantType | string) {
  if (type === 'function' || type === 'http_host') return t('Web');
  if (type === 'view') return t('Data');
  return t('Routines');
}

export function modelName(cfg: { provider?: string; model?: string } | null) {
  return cfg?.model || null;
}

const STATUS: Record<string, string> = {
  completed: 'Done',
  failed: 'Failed',
  running: 'Working',
  queued: 'Waiting to start',
  open: 'Working',
  waiting_human: 'Needs your approval',
  waiting_children: 'Waiting for others',
  cancelled: 'Cancelled',
};

/** A task or session status in plain words. */
export function statusLabel(t: T, status: string) {
  return STATUS[status] ? t(STATUS[status]) : status.replace(/_/g, ' ');
}
