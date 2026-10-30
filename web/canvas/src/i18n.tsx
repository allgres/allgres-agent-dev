import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

// The Canvas shares the dashboard's translation packs (web/i18n/<code>.json,
// docs/i18n.md). The English sentence is the key, so a string without an entry
// still reads correctly, just in English. {name}-style placeholders are filled
// from the second argument. The language is chosen in the dashboard's Settings
// and kept in the browser; this module only reads it.
export type Lang = string;

const KEY = 'allgres_lang';

function stored(): Lang {
  try {
    const v = localStorage.getItem(KEY) || '';
    return /^[a-z]{2,3}(-[A-Za-z0-9]+)?$/.test(v) ? v : 'en';
  } catch {
    return 'en';
  }
}

type Pack = Record<string, string>;

async function loadPack(code: Lang): Promise<Pack> {
  if (code === 'en') return {};
  try {
    const r = await fetch(`/i18n/${encodeURIComponent(code)}.json`);
    if (!r.ok) return {};
    const j = await r.json();
    const out: Pack = {};
    // The Canvas's own section last, so it wins over the shared ones.
    const sections: Record<string, Pack> = j.sections || {};
    for (const [name, map] of Object.entries(sections)) if (name !== 'canvas') Object.assign(out, map);
    Object.assign(out, sections.canvas || {});
    return out;
  } catch {
    return {};
  }
}

const Ctx = createContext<{ lang: Lang; setLang: (l: Lang) => void; pack: Pack }>({ lang: 'en', setLang: () => {}, pack: {} });

export function LangProvider({ children }: { children: ReactNode }) {
  const [lang, set] = useState<Lang>(stored);
  const [pack, setPack] = useState<Pack>({});
  useEffect(() => {
    let live = true;
    loadPack(lang).then((p) => live && setPack(p));
    document.documentElement.lang = lang;
    return () => {
      live = false;
    };
  }, [lang]);
  // The dashboard tells an embedded Canvas which language to use.
  const setLang = useCallback((l: Lang) => set(l), []);
  const value = useMemo(() => ({ lang, setLang, pack }), [lang, setLang, pack]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export type T = (s: string, vars?: Record<string, string | number>) => string;

export function translate(pack: Pack, s: string, vars?: Record<string, string | number>) {
  let out = pack[s] ?? s;
  if (vars) for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(String(v));
  return out;
}

export function useT(): T {
  const { pack } = useContext(Ctx);
  return useCallback((s, vars) => translate(pack, s, vars), [pack]);
}

export const useLang = () => useContext(Ctx);
