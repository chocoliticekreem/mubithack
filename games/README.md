# Games

One folder per game. The system that builds and improves them (`forge/`, `mubit-tester/`,
`forge-plugin/`) is shared by every game; nothing in it is specific to one game.

```
games/
  <slug>/
    README.md    what it is, how it plays, its modules, how it was built
    spec.json    pitch, core loop, modules, acceptance checks, playtest settings
    game/        the game's Luau (ServerScriptService/, ReplicatedStorage/, StarterPlayerScripts/)
runs/<slug>/     working copy: versions (forge versions/rollback), iterations, fix cycles, traces (local)
evidence/<slug>/ committed record of the agent's work (forge archive)
```

| Game | Where | Made by |
|---|---|---|
| Flame and Blame | [`flame-and-blame/`](flame-and-blame/README.md), code still in `game/` | the team, plus agent-built features |
| Sunbeam Park Obby | [`sunbeam-park-obby/`](sunbeam-park-obby/README.md) | MuMake, from one prompt |
| Agent-built games | `games/<slug>/` via `forge promote-game <slug>` | Forge, from one idea |

## Lifecycle of an agent-built game

```bash
forge new "<idea>" --iterations 2                 # designer, coder, playtests, critic, fixer -> runs/<slug>/
forge fix <slug> --cycles 3                       # AI testers, auditor, investigator, fixer, verifier
forge feature <slug> "<request>" --polish 3       # add features, feature-scoped polish
forge promote-game <slug>                         # -> games/<slug>/ (commit it on a branch, open a PR)
forge place --root games/<slug>/game --out place/<slug>.rbxlx --open   # play or publish it
```

Flame and Blame keeps living in `game/` for now, so nobody's open branch breaks. It moves to
`games/flame-and-blame/game/` when the team picks a quiet moment.
