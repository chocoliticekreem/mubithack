# Working on Forge with 3 devs in parallel

The goal is that three people build at full speed without conflicting. Each person owns one lane of
files, works on short-lived branches, and merges small PRs into `main` often. `main` must always
run.

## Lanes (who owns which files)

Write your name next to a lane. You can read and use any file, but only edit files outside your lane
in a small PR that says so in its title.

| Lane | Owner | Owns | Goal for the demo |
|---|---|---|---|
| **A — Brain (Mubit)** | _name_ | `forge/llm.py`, `forge/roles.py`, `forge/prompts/`, `forge/loop.py`, `forge/memory.py` | Good games from one idea; the correction → model update story; enough calls per task to train (25 kept examples per role) |
| **B — Studio (runtime)** | _name_ | `forge/studio.py`, `forge/sync.py`, `game/` (ForgeProbe, ForgeTelemetry, `tools/`), `scripts/` | Reliable sync and playtests, screenshots, simulated input, honest playtest reports |
| **C — Demo (product)** | _name_ | `forge/cli.py`, a demo UI (new `ui/`), `README.md`, `docs/` except ARCHITECTURE | A 3-minute live demo: idea → game → correction → Mubit console showing training |

Shared files changed by anyone, but **only in their own small PR**, merged first:
- `docs/ARCHITECTURE.md`: the contract between lanes. If you change a signature, update it here in
  the same PR and ping the lane that uses it.
- `pyproject.toml`: add dependencies in a separate PR so a lockstep merge isn't needed.

## Git flow

```bash
git switch main && git pull --rebase
git switch -c a/better-critic          # lane letter / short topic
# ...work, commit small...
.venv/bin/python -m pytest -q          # must pass
git push -u origin HEAD
gh pr create --fill                     # CI runs tests + Luau syntax check
gh pr merge --squash --delete-branch    # once CI is green (self-merge is fine in your lane)
```

Rules:
- **Branches live less than half a day.** Merge small, working steps. Rebase on `main` before
  pushing (`git pull --rebase origin main`).
- **Never push straight to `main` and never force-push `main`.** Squash-merge PRs.
- Commit messages: `area: what changed`, for example `studio: retry start_stop_play once`.
- Want to run two tasks at once yourself? Use a worktree per branch:
  `git worktree add ../mubithack-b2 -b b/screenshots`. **Commit and push from it before deleting
  it.** intofire lost all its code because a worktree was deleted with unpushed work.

## Things that cause conflicts, and how to avoid them

1. **System prompts (`forge/prompts/*.md`).** Mubit groups calls into a task by the exact system
   prompt, and editing a prompt resets that task's example count to zero. Lane A owns them. Once
   training has started (check the Mubit console → Tasks), freeze them. Put new guidance in the
   user message (e.g. lessons) instead.
2. **Model.** The model is part of the task too. Everyone uses the same `FORGE_MODEL` in `.env`,
   so all three devs' calls add up to the same tasks and reach 25 examples three times faster.
3. **Studio.** Each dev runs their own Studio on their own laptop with their own place:
   `python3 game/tools/make_place.py --out place/Forge.rbxlx` (gitignored). If two Studios are
   open on one machine, give each a different `FORGE_SYNC_PORT`.
4. **Generated games and logs** are in `runs/` (gitignored). To share a good game, copy it into
   `examples/<slug>/` in a PR.
5. **Secrets.** Each dev has their own `.env` (gitignored). Share the Mubit key over a private
   channel, never in the repo. All of us use the same Mubit workspace so training data pools.

## Setup for a new dev (5 minutes)

```bash
gh repo clone chocoliticekreem/mubithack && cd mubithack
uv venv && uv pip install -e ".[dev]"
brew install luau
cp .env.example .env          # paste the shared MUBIT_API_KEY
python3 game/tools/make_place.py --out place/Forge.rbxlx && open place/Forge.rbxlx
# Studio: Assistant → ⋯ → Manage MCP Servers → Enable Studio as MCP server
.venv/bin/forge doctor        # every line ✓
.venv/bin/forge watch --studio Forge   # leave running: every save syncs into Studio
.venv/bin/python -m pytest -q
```

## Claude Code setup (shared via git)

- `.claude/settings.json` turns on the **superpowers** and **mattpocock-skills** plugins (from the
  official marketplace, so Claude Code installs them when you trust the folder). It also
  pre-approves the Studio MCP and forge commands.
- `.mcp.json` registers Roblox Studio's built-in MCP (`Roblox_Studio`) for this project.
- `.claude/skills/roblox-studio-dev/` is our skill for editing and playtesting game code over MCP.
- `CLAUDE.md` holds the core rules. Personal overrides go in `.claude/settings.local.json`
  (gitignored).
- Superpowers flow for features: brainstorming → writing-plans → subagent-driven-development, with
  plans in `docs/superpowers/plans/`.

## The shared Roblox place

The game is published as **Firefighter Mubit** (placeId 130153199199668) with Team Create, so
friends can join and play. **Git is the source of truth, not the place.**

- **Develop in your own local place**: `forge place --open` builds `place/Forge.rbxlx`, then run
  `forge watch --studio Forge`. Never point `forge watch` at the shared place. It refuses unless you
  pass `--shared`, because two people pushing their own trees overwrite each other, and pruning
  deletes the other person's new scripts.
- **Update the shared place only from `main`**: after a PR merges, one person runs
  `git switch main && git pull && forge sync --studio Firefighter` with the shared place open in
  Studio. It's one-shot and doesn't prune. Add `--prune` only to clean out deleted files. Then
  publish in Studio (File → Publish to Roblox).
- **Don't edit scripts inside the shared place.** Edits made there aren't in git, and the next sync
  overwrites them.

## Auto-sync files → Studio

Leave `forge watch` running in a terminal while you work. Every time you save a `.luau` file under
`game/` it:
1. syntax-checks the files with `luau-compile`. If there's an error it prints it and doesn't push.
2. pushes changed files into the open Studio over the MCP. New files are created and deleted files
   are removed. This takes about 1 s.
3. never interrupts a playtest. Changes wait until you press Stop, then push.

`forge watch <slug>` does the same for a generated game in `runs/<slug>/game`.
`forge place --open` builds a fresh `place/Forge.rbxlx` from `game/` and opens it.

Alternative: Studio's built-in **Script Sync** (right-click ServerScriptService, ReplicatedStorage
and StarterPlayerScripts → Sync to → pick the `game/` folder; it can't be switched on from code).
It's two-way, so edits made inside Studio are written back to disk. Use either Script Sync or
`forge watch` for a given place, not both. Forge's own loop uses `forge watch`'s sync.

## Sync points

- **Every ~3 hours:** 5-minute standup. What merged, what's blocked, and whether the contract
  needs to change.
- **Sat 12:00:** check-in (Max, Discord). Demo path working end to end.
- **Sat 18:00:** feature freeze. Record the demo video (MP4/MOV, max 3 min) and make the PDF deck.
- **Sat midnight:** submission due (video + deck). **Sun 05:00: hard code freeze.**
