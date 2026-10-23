#!/bin/sh
# Start the mubit-tester MCP server (stdio). stdout is the MCP channel; log only to stderr.
# Finds a mubithack checkout with a venv: $FORGE_PROJECT_DIR, then the repo this plugin lives in
# (local install), then the current directory and its parents. Falls back to uvx from GitHub.
here="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
for d in "$FORGE_PROJECT_DIR" "$here" "$PWD" "$(dirname "$PWD")" "$(dirname "$(dirname "$PWD")")"; do
  if [ -n "$d" ] && [ -x "$d/.venv/bin/mubit-tester" ]; then
    cd "$d" && exec "$d/.venv/bin/mubit-tester"
  fi
done
if command -v uvx >/dev/null 2>&1; then
  echo "mubit-tester: no local venv found; running from GitHub with uvx" >&2
  export FORGE_PROJECT_DIR="${FORGE_PROJECT_DIR:-$PWD}"
  exec uvx --from "git+https://github.com/chocoliticekreem/mubithack" mubit-tester
fi
echo "mubit-tester: no venv found. In your mubithack clone run: uv venv && uv pip install -e '.[dev]'" >&2
exit 1
