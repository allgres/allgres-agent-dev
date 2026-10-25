#!/bin/bash
# Installs the token-saving dev tools for Claude Code cloud sessions:
#   rtk      - condenses Bash command output (Apache-2.0 "oss" edition)
#   graphify - code knowledge graph, so exploration reads less raw source
# Local machines are left alone; install the tools yourself there if wanted.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

RTK_VERSION="v1.0.1"
GRAPHIFY_VERSION="0.9.95"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

install_rtk() {
  if command -v rtk >/dev/null 2>&1 && [ "$(rtk --version 2>/dev/null)" = "rtk ${RTK_VERSION#v}" ]; then
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) echo "rtk: unsupported architecture $(uname -m), skipping" >&2; return 0 ;;
  esac
  local asset="rtk-oss-${arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$base/$asset" -o "$tmp/$asset"
  curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt"
  (cd "$tmp" && grep " ${asset}\$" checksums.txt | sha256sum -c --quiet -)
  tar -xzf "$tmp/$asset" -C "$tmp"
  install -m 0755 "$(find "$tmp" -type f -name rtk | head -n 1)" "$BIN_DIR/rtk"
  rm -rf "$tmp"
}

install_graphify() {
  if command -v graphify >/dev/null 2>&1 && [ "$(graphify --version 2>/dev/null)" = "graphify ${GRAPHIFY_VERSION}" ]; then
    return 0
  fi
  # The sql extra adds the tree-sitter grammar; without it sql/*.sql is skipped.
  uv tool install --force "graphifyy[sql]==${GRAPHIFY_VERSION}" >/dev/null
}

# rtk otherwise warns that its global hook is missing; the project hook covers it.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export RTK_SUPPRESS_HOOK_WARNING=1' >> "$CLAUDE_ENV_FILE"
fi

# A failed download must not block the session; the hooks no-op without the tools.
install_rtk || echo "rtk install failed; Bash output will not be condensed" >&2
install_graphify || echo "graphify install failed; no code graph this session" >&2

# Build the code graph (AST only, no LLM calls, a few seconds).
if command -v graphify >/dev/null 2>&1; then
  (cd "$CLAUDE_PROJECT_DIR" && graphify update . >/dev/null 2>&1) \
    || echo "graphify update failed; no code graph this session" >&2
fi
