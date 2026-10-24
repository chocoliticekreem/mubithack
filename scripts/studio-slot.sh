#!/bin/sh
# Studio slots: at most MAX agent Studio windows open at once (Roblox caps how many Studios run).
#   scripts/studio-slot.sh acquire Forge-agents-21   # blocks until a slot is free, prints the slot
#   scripts/studio-slot.sh release Forge-agents-21   # closes that Studio window and frees the slot
#   scripts/studio-slot.sh status
# A slot whose window is no longer running and that is older than 2 minutes is reclaimed.
MAX=${STUDIO_SLOTS:-4}
DIR=/tmp/forge-studio-slots
mkdir -p "$DIR"
cmd="$1"; name="$2"

running() { ps -axo args | grep -q "[l]ocalPlaceFile .*place/$1.rbxlx"; }

reclaim() {
	for s in "$DIR"/slot*; do
		[ -d "$s" ] || continue
		owner=$(cat "$s/owner" 2>/dev/null)
		if [ -n "$owner" ] && ! running "$owner" && [ -n "$(find "$s" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
			rm -rf "$s"
		fi
	done
}

case "$cmd" in
acquire)
	[ -z "$name" ] && { echo "usage: $0 acquire <place-name>" >&2; exit 1; }
	while true; do
		for s in "$DIR"/slot*; do
			[ -d "$s" ] && [ "$(cat "$s/owner" 2>/dev/null)" = "$name" ] && { echo "already holding $(basename "$s")"; exit 0; }
		done
		reclaim
		i=1
		while [ "$i" -le "$MAX" ]; do
			if mkdir "$DIR/slot$i" 2>/dev/null; then
				echo "$name" > "$DIR/slot$i/owner"
				echo "slot$i acquired for $name"
				exit 0
			fi
			i=$((i + 1))
		done
		echo "all $MAX Studio slots busy ($(cat "$DIR"/slot*/owner 2>/dev/null | tr '\n' ' ')); waiting..." >&2
		sleep 20
	done
	;;
release)
	[ -z "$name" ] && { echo "usage: $0 release <place-name>" >&2; exit 1; }
	sh "$(dirname "$0")/close-agent-studio.sh" "$name"
	for s in "$DIR"/slot*; do
		[ -d "$s" ] && [ "$(cat "$s/owner" 2>/dev/null)" = "$name" ] && rm -rf "$s" && echo "released $(basename "$s")"
	done
	;;
status)
	reclaim
	for s in "$DIR"/slot*; do [ -d "$s" ] && echo "$(basename "$s"): $(cat "$s/owner")"; done
	echo "max $MAX"
	;;
*) echo "usage: $0 acquire|release|status [place-name]" >&2; exit 1 ;;
esac
