#!/bin/sh
# Start the mubit-tester MCP server (stdio) from this repo's venv, whatever the caller's cwd.
# Used by .mcp.json so it works in every teammate's clone. stdout is the MCP channel.
cd "$(dirname "$0")/../.." || exit 1
if [ ! -x .venv/bin/mubit-tester ]; then
  echo "mubit-tester: .venv/bin/mubit-tester missing; run: uv venv && uv pip install -e '.[dev]'" >&2
  exit 1
fi
exec .venv/bin/mubit-tester
