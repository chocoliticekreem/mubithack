#!/usr/bin/env bash
# Runs every pure-Luau spec under game/tests with the `luau` CLI. Exit 1 if any spec fails.
#   bash game/tests/run.sh
set -u
cd "$(dirname "$0")"
status=0
shopt -s nullglob
specs=(*.spec.luau)
if [ ${#specs[@]} -eq 0 ]; then
  echo "no specs found"
  exit 1
fi
for f in "${specs[@]}"; do
  echo "== game/tests/$f"
  luau "$f" || status=1
done
exit $status
