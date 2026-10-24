# mubithack: Forge

Mode: hackathon

Night Shift x Mubit hackathon. The event brief, schedule and judging criteria are in `docs/nightshift.md`.

**What we're making:** a Roblox co-op firefighting game, "Flame and Blame" (`docs/TARGET_GAME.md`,
with the full breakdown in `docs/game/`). It's built by **Forge**, our agent that goes from idea →
Luau → Roblox Studio playtest → fix → better, with every LLM call going through Mubit. Each Forge
role is a Mubit task, and corrections become model updates.

## Hard constraints
- Every LLM call goes through Mubit (base URL + `MUBIT_API_KEY`). No direct provider calls.
- Submit by **Sat midnight**: an MP4/MOV demo of 3 minutes or less, plus a PDF deck. **Hard code freeze is Sun 25 Oct 05:00.**
  Check-ins are Sat by 12:00 and between 12:00 and 18:00. The demo must show a correction turning into a model update.

## Map
| Path | What it is |
|---|---|
| `forge/` | the agent (Python). Contracts are in `docs/ARCHITECTURE.md` |
| `forge/prompts/*.md` | fixed system prompts, one Mubit task each |
| `game/` | Roblox game code (`.luau`), synced into Studio |
| `game/tools/` | `sync.py` (check/serve/pull) and `make_place.py` |
| `runs/<slug>/` | games Forge generated (gitignored) |
| `docs/game/` | game design breakdown: systems, art, tech architecture, market, missions, 3D |
| `docs/research/` | Mubit and Roblox Studio MCP facts |
| `docs/TEAM.md` | how 3 devs work in parallel: lanes, branches, PRs |

## Commands
```bash
.venv/bin/forge doctor                 # key, luau, StudioMCP, connected Studio
.venv/bin/forge place --open           # build + open place/Forge.rbxlx
.venv/bin/forge watch --studio Forge   # auto-sync game/ into Studio on save
.venv/bin/forge new "<idea>" -n 3      # Forge builds a game
.venv/bin/forge correct <slug> <file> "<what's wrong>"
.venv/bin/python -m pytest -q          # tests
python3 game/tools/sync.py check --root game   # Luau syntax check
```

## How to work here
- **Game production policy:** read `docs/GAME_PRODUCTION_GUIDE.md` before planning, building, testing or improving a game. Apply its relevant genre/capability checks, priority bands and evidence rules. Every game-production AI task must use Mubit; supply changing guidance in user context, never by editing frozen prompts.
- **Any Luau or Studio work:** use the `roblox-studio-dev` skill (`.claude/skills/`). Edit files,
  not Studio. Playtest over MCP yourself, and always stop the playtest when you're done.
- **Stay in your lane** (`docs/TEAM.md`): one file per system. Change shared contracts
  (`docs/ARCHITECTURE.md`, `docs/game/03-tech-architecture.md`) only in their own small PR.
- **Git:** short branch → PR → squash-merge once CI is green. Rebase on `main` before pushing. Never force-push `main`.
  Commit often: intofire lost all its code in an unpushed worktree.
- **Don't edit `forge/prompts/*.md` once Mubit training has started.** Mubit groups calls into tasks
  by exact system prompt, so an edit resets that task. Put anything that changes per call in the user
  message.
- **Keep reference material out of git:** `docs/reference/` and `docs/vendor/` are local only.
- When you change a signature, update `docs/ARCHITECTURE.md` in the same commit.
