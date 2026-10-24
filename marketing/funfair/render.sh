#!/bin/sh
# Render Funfair Frenzy listing assets and ads into out/.
#   sh render.sh                 # everything
#   sh render.sh icon thumb-01   # just these composition ids
# icon is PNG; thumb-* are written as JPG q92 only, so each stays well under Roblox's 3 MB cap;
# vid-* are silent H.264 MP4s (we have no licensed track).
set -e
cd "$(dirname "$0")"
mkdir -p out
[ -d node_modules ] || npm ci --no-audit --no-fund
npx remotion bundle src/index.ts --out-dir .remotion/bundle --log=error >/dev/null
IDS="$*"
[ -z "$IDS" ] && IDS=$(npx remotion compositions .remotion/bundle --quiet 2>/dev/null | tr ' ' '\n' | grep -v '^$')
for id in $IDS; do
  case "$id" in
    vid-*) npx remotion render .remotion/bundle "$id" "out/$id.mp4" --codec=h264 --crf=20 --muted --log=error ;;
    *) npx remotion still .remotion/bundle "$id" "out/$id.png" --log=error
       case "$id" in thumb-*) sips -s format jpeg -s formatOptions 92 "out/$id.png" --out "out/$id.jpg" >/dev/null && rm "out/$id.png" ;; esac ;;
  esac
  echo "rendered $id"
done
