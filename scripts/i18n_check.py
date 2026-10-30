#!/usr/bin/env python3
"""Check translation packs against the English source (docs/i18n.md).

  scripts/i18n_check.py            report every language: coverage, missing, unknown keys
  scripts/i18n_check.py --write    also store each pack's coverage in its meta
  scripts/i18n_check.py ko --missing   list the English strings ko still lacks

Exit status is 1 when a pack is broken (not valid JSON, no meta.code, a value
that is not a string). Missing translations are not an error: they fall back
to English on screen.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "web" / "i18n"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv):
    write = "--write" in argv
    show_missing = "--missing" in argv
    only = [a for a in argv if not a.startswith("--")]
    en = load(ROOT / "en.json")
    source = en.get("sections", {})
    total = sum(len(m) for m in source.values())
    bad = 0
    for path in sorted(ROOT.glob("*.json")):
        if path.name == "en.json" or (only and path.stem not in only):
            continue
        try:
            pack = load(path)
            code = pack["meta"]["code"]
        except Exception as e:  # noqa: BLE001
            print(f"{path.name}: BROKEN ({e})")
            bad += 1
            continue
        if code != path.stem:
            print(f"{path.name}: meta.code is {code!r}, expected {path.stem!r}")
            bad += 1
        done, missing, unknown = 0, [], []
        for sec, items in pack.get("sections", {}).items():
            for k, v in items.items():
                if not isinstance(v, str):
                    print(f"{path.name}: {sec}/{k}: value is not a string")
                    bad += 1
                elif k in source.get(sec, {}):
                    done += 1
                else:
                    unknown.append(f"{sec}/{k}")
        for sec, items in source.items():
            have = pack.get("sections", {}).get(sec, {})
            missing += [(sec, k) for k in items if k not in have]
        pct = round(100 * done / total) if total else 100
        print(f"{code} ({pack['meta'].get('native', '')}): {pct}% — {done}/{total} translated, {len(missing)} missing, {len(unknown)} not in en.json")
        by = {}
        for sec, _ in missing:
            by[sec] = by.get(sec, 0) + 1
        for sec, n in sorted(by.items()):
            print(f"    {sec}: {n} missing")
        if show_missing:
            for sec, k in missing:
                print(f"    [{sec}] {k}")
        for u in unknown[:20]:
            print(f"    unknown key: {u}")
        if write:
            pack["meta"]["coverage"] = pct
            path.write_text(json.dumps(pack, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
