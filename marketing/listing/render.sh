#!/bin/sh
# Render every Roblox listing asset into out/. Usage: sh render.sh [--no-video]
set -e
cd "$(dirname "$0")"
mkdir -p out
for id in icon thumb-1-keyart thumb-2-blame thumb-3-squads thumb-4-drive thumb-5-burn thumb-6-golden-axe; do
  npx remotion still src/index.ts "$id" "out/$id.png" --log=error
done
if [ "$1" != "--no-video" ]; then
  npx remotion render src/index.ts trailer out/trailer.mp4 --codec=h264 --crf=20 --log=error
fi
ls -la out
