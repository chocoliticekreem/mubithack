#!/bin/sh
# Render the 10 badge icons (marketing/ads/src/Badges.tsx) into marketing/badges/out/<achievement_id>.png.
# The list (ids, names, descriptions) is badges.json; the game maps ids to badge asset ids in
# game/ReplicatedStorage/Config/AchievementConfig.luau (BadgeIds).
#   sh marketing/badges/render.sh
set -e
cd "$(dirname "$0")/../ads"
[ -d node_modules ] || npm ci --no-audit --no-fund
npx remotion bundle src/index.ts --out-dir .remotion/bundle --log=error >/dev/null
for id in first_call first_rescue save_panda fires_100 cat_tree night_hero speed_run combo_master yeet level_25; do
  comp="badge-$(echo "$id" | tr '_' '-')"
  npx remotion still .remotion/bundle "$comp" "../badges/out/$id.png" --log=error
  echo "rendered $id"
done
