# Sunbeam Park Obby

Run 100 stages through 10 candy-bright amusement-park rides to the castle, and dress up in silly costumes along the way.

Built by MuMake from one prompt in the Roblox Studio plugin, in the final demo run on 2026-10-25 (run `i-want-a-100-stage-obby`). The build took about 6 minutes; MuMake then ran 4 improvement rounds and the run was stopped during round 5 for the demo.

## State at hand-off

- 10 zones of 10 stages (100 in total), 0 game errors.
- Critic score 6/10 in all 4 rounds. 5 acceptance checks were never exercised by the playtests: costume_buy, costume_equip, gift_ready, gift_claimed and achievement_unlocked. In Studio, buying and wearing a costume works; the gift and achievements were never played.
- In Studio: kill parts kill, ride gates and the next zone's entrance work, and the finish line at stage 100 fires. QA bots reached the next checkpoint in most zones; some fell on spinners and lava, which is expected on late stages.

See `docs/research/2026-10-25-mumake-reflection.md` for why the score sat at 6 and the next fixes.

## Files

- `game/`: the Studio game, same layout as `game/` at the repo root (`ServerScriptService`, `ReplicatedStorage`, `StarterPlayerScripts`).
  - `ReplicatedStorage/Kit/*` and `ReplicatedStorage/GameAssets.luau` are prebuilt kit modules (ObbyKit, WorldKit, ParkObby, Cosmetics, MusicPlayer, ObbyThemes).
  - `ReplicatedStorage/Levels/Zone01-10.luau` are the level designer's courses.
  - `ReplicatedStorage/Config.luau` is rendered from the spec.
  - `ServerScriptService/ParkExtras.luau` and `StarterPlayerScripts/GiftHud.client.luau` are the coder's game-specific scripts (gift balloon, extras).
  - `ForgeProbe`, `ForgeTest`, `ForgeTestAgent` and `ForgeTelemetry` are the test harness. They are not part of the game; keep or drop them.
- `spec.json`: the director's design (title, zones, acceptance criteria, modules).
- `screenshots/round-1.png`, `screenshots/round-4.png`: Studio screenshots after rounds 1 and 4.

## Open it in Studio

```bash
python3 game/tools/make_place.py --root games/sunbeam-park-obby/game --out place/sunbeam-park-obby.rbxlx
```

Or sync it into an open place: `.venv/bin/forge sync --root games/sunbeam-park-obby/game --studio <window>`.
