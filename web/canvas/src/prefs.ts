import { rpc } from './api';

// Per-user interface settings live in the database (docs/user-prefs.md), not
// in the browser. They are read once before the Canvas draws; a change is
// saved at once and, if the save fails, simply lasts until the page is closed.
let cache: Record<string, string> = {};

export async function loadPrefs(): Promise<void> {
  try {
    const r = await rpc<{ prefs: Record<string, string> }>('me.prefs_get');
    cache = r.prefs || {};
  } catch {
    cache = {};
  }
}

export const pref = (key: string): string | undefined => cache[key];

export function setPref(key: string, value: string | null) {
  if (value === null) delete cache[key];
  else cache[key] = value;
  rpc('me.prefs_set', { prefs: { [key]: value } }).catch(() => {});
}
