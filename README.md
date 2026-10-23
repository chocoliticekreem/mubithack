# Forge

Give it a game idea. It builds a Roblox game, playtests it in Roblox Studio, reads what broke, fixes
it, and gets better at it every run.

Every LLM call goes through [Mubit](https://mubit.ai). Each of Forge's roles (designer, coder, fixer,
critic, reflector) has one fixed system prompt, so Mubit sees each role as a recurring **task** and
trains an adapter for it. Corrections, whether from Studio errors, the critic or you, are sent back
as new calls in the same task. That is how a correction turns into a model update.

```
idea → designer → spec → coder → Luau files → compile check → fixer
     → sync into Studio (MCP) → playtest → ForgeProbe report + console + screenshot
     → critic → fixer → reflector (lessons) → next iteration
```

## Setup

```bash
uv venv && uv pip install -e ".[dev]"
cp .env.example .env        # put your mbt_ key in MUBIT_API_KEY
brew install luau           # luau-compile for syntax checks
.venv/bin/forge doctor
```

In Roblox Studio, open a place and turn on **Assistant → ⋯ → Manage MCP Servers → Enable Studio as
MCP server**. Forge starts Studio's built-in `StudioMCP` itself.

## Use

```bash
forge new "co-op lava floor escape where you carry friends" --iterations 3
forge run lava-escape --iterations 2         # keep improving
forge correct lava-escape ServerScriptService/Round.server.luau "rounds never end when everyone dies"
forge status
forge new "..." --no-studio                  # compile-only loop, no Studio needed
```

Then open the [Mubit console](https://app.mubit.ai/console/). **Tasks** shows each role collecting
examples and training. **Requests** lets you rate calls Good/Bad. **Try models** compares the adapter
with the base model side by side.

## Layout

- `forge/`: the agent (Python). Contracts are in `docs/ARCHITECTURE.md`.
- `game/`: the base Roblox runtime that goes into every generated game (ForgeProbe, ForgeTelemetry,
  and the sync tools).
- `runs/<game>/`: generated games, specs, iterations and call logs (gitignored).
- `docs/research/`: Mubit and Roblox Studio MCP research.
- `docs/TEAM.md`: how 3 devs work in parallel (lanes, branches, PRs).
