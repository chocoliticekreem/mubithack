#!/bin/sh
# Start the forge MCP server (stdio). stdout is the MCP channel; log only to stderr.
# Finds a mubithack checkout: $FORGE_PROJECT_DIR, the repo this plugin lives in, the current
# directory and its parents, then the marketplace's own clone. If that checkout has no venv yet,
# it creates one with uv (first launch only).
here="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
market="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/mubithack"

is_checkout() {
  [ -n "$1" ] && [ -f "$1/pyproject.toml" ] && grep -q '^name = "forge"' "$1/pyproject.toml" 2>/dev/null
}

for d in "$FORGE_PROJECT_DIR" "$here" "$PWD" "$(dirname "$PWD")" "$market"; do
  if is_checkout "$d"; then
    if [ ! -x "$d/.venv/bin/forge" ]; then
      if ! command -v uv >/dev/null 2>&1; then
        echo "forge: $d has no .venv and uv is not installed. Install uv (https://docs.astral.sh/uv/) or run: cd $d && python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'" >&2
        exit 1
      fi
      echo "forge: first launch, creating $d/.venv (about a minute)" >&2
      (cd "$d" && uv venv -q && uv pip install -q -e ".[dev]") >&2 || { echo "forge: venv setup failed in $d" >&2; exit 1; }
    fi
    cd "$d" && exec "$d/.venv/bin/forge" server
  fi
done

echo "forge: no mubithack checkout found. Clone https://github.com/chocoliticekreem/mubithack and set the plugin's 'mubithack checkout' option to it (or open Claude Code inside it)." >&2
exit 1
