#!/bin/sh
# Close an agent Studio window by its place file name, e.g. scripts/close-agent-studio.sh Forge-agents-2
# Leaves the main shared place alone. Agent places are throwaway, so this force-quits.
name="$1"; [ -z "$name" ] && { echo "usage: $0 <place-name>" >&2; exit 1; }
pids=$(ps -axo pid,args | grep "localPlaceFile .*place/$name.rbxlx" | grep -v grep | awk '{print $1}')
[ -z "$pids" ] && { echo "no Studio window for $name"; exit 0; }
for p in $pids; do kill -TERM "$p"; done; sleep 3
for p in $pids; do kill -0 "$p" 2>/dev/null && kill -9 "$p"; done
echo "closed $name"
