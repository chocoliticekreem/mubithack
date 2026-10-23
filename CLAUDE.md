# mubithack

Mode: hackathon

Night Shift x Mubit hackathon project. Event brief, schedule, tracks, judging and side quests:
`docs/nightshift.md`.

Hard constraints:
- Every LLM call routes through Mubit (base URL + Mubit key).
- Code freeze Sun 25 Oct 10:00. Demo must show a correction turning into a model update.

Project: **Forge** — idea → Luau → Roblox Studio (StudioMCP) playtest → fix loop; roles are Mubit tasks.
- Contracts: `docs/ARCHITECTURE.md` (keep signatures in sync when changing modules).
- System prompts in `forge/prompts/*.md` must stay free of per-call text (Mubit groups tasks by exact system prompt; editing one resets that task's example count — avoid edits after training starts).
- Run tests: `.venv/bin/python -m pytest -q`. Syntax-check Luau: `python3 game/tools/sync.py check --root game`.
- Commit nested work here; never keep game code only in a worktree (intofire lost its code that way).
