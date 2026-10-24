# Flame and Blame

Co-op chaotic firefighting on Roblox: alarm at Station 67, drive truck 67 to a burning block, hose,
axe, rescue civilians and pets, Blame awards. Design: `docs/TARGET_GAME.md` and `docs/game/`.

## Where the code is

`game/` at the repo root (for now). It moves here, to `games/flame-and-blame/game/`, when the team
picks a quiet moment, so open branches don't break.

## Running the agents on it

```bash
forge seed flame-and-blame                     # runs/flame-and-blame/game <- game/ (versioned, v1)
forge fix flame-and-blame --edit-human-files --start-round --cycles 3      # find and fix bugs in play
forge seed flame-and-blame-feat --spec forge/seeds/flame-and-blame.json
forge feature flame-and-blame-feat "<feature>" --iterations 2 --polish 3   # add a feature
forge promote flame-and-blame-feat <path>      # copy one verified file back into game/ (then a PR)
```

Seed spec: `forge/seeds/flame-and-blame.json` (`"playtest": {"start_round": true}`, so playtests run
inside a mission). Planted faults for `forge improve`: `forge/faults/flame-and-blame.json`.

## Agent-built features in the game

| Feature | Files | Verified in play | PR |
|---|---|---|---|
| Flare-ups (fires reignite mid-mission) | `ServerScriptService/Services/FlareUpService.luau` | 7 to 8 flare-ups, 0 errors | #87 |
| Battle pass (XP from missions, tiers, free and premium tracks, claims, UI) | `BattlePassService.luau`, `BattlePassController.client.luau`, `Config/BattlePassConfig.luau` | XP 120, tier-ups 2, claims 2, 0 errors | #87 |

Record of how they were built: `evidence/flame-and-blame-feat/`.
