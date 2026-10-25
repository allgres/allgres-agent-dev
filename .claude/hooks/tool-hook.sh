#!/bin/bash
# PreToolUse wrapper: runs a token-saving tool's hook when that tool is
# installed and lets the call through untouched when it is not.
#   tool-hook.sh rtk                -> rtk hook claude
#   tool-hook.sh graphify search    -> graphify hook-guard search
#   tool-hook.sh graphify read      -> graphify hook-guard read
export PATH="$HOME/.local/bin:$PATH"
tool="$1"
shift
command -v "$tool" >/dev/null 2>&1 || exit 0
case "$tool" in
  rtk) exec rtk hook claude ;;
  graphify) exec graphify hook-guard "$@" ;;
esac
