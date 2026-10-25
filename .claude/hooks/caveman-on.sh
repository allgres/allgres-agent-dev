#!/bin/bash
# SessionStart: turns on the caveman skill (vendored from
# github.com/JuliusBrussee/caveman @ 1f951fb, MIT; see the LICENSE beside it) (terse replies) for every
# session, including after /clear and compaction. Say "stop caveman" or
# "normal mode" to turn it off for the rest of a session.
skill="$CLAUDE_PROJECT_DIR/.claude/skills/caveman/SKILL.md"
[ -f "$skill" ] || exit 0
python3 - "$skill" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "CAVEMAN MODE ACTIVE (mode: caveman). Follow these rules:\n\n" + body,
}}))
PY
