---
name: building-games-with-forge
description: Use when the user wants a new Roblox game made from an idea ("make me a co-op lava escape", "build a tycoon with Forge"), especially when they will be away while it builds.
---

# Building a game with Forge from an idea

## Overview
`build_game` designs, codes and playtests in Roblox Studio as a background job (5-15 min), with
every LLM call through Mubit. "Built" is not "done": a game is finished when `done(slug)` says
READY. Building into the wrong Studio window overwrites someone's place, so the window choice
comes first.

## Steps
1. `setup()`. Follow every ✗ it lists (it can save the key, install luau and open a place). Build
   only once it says **ready**.
2. **Pick the window.** `doctor()` lists Studio windows. Pass `studio="<your local place name>"`
   to every build tool. Never use a name with `placeId` (a shared Team Create place). With no
   local place, run `setup(open_place=True)`.
3. **Sharpen the idea** into one line: genre, the core loop, what players do together, and how a
   round ends. For example: "co-op lava escape: lava rises every 20 s, players boost each other up
   ledges, the round ends when all reach the top or fall".
4. `build_game(idea, iterations=2, studio=...)`. It follows the job for about 4 minutes,
   streaming the phase, steps and critic score.
5. Still running? Call `job(id, wait_seconds=300)` again. Read the summary line every time.
   **failed** means: read the tail, fix the cause (setup, Studio), start again.
6. **Finished:** `games()` gives the slug and score, then `done(slug)`. If the user wants it
   "done" (or is away), carry on with the improving-games-until-done skill. Otherwise report.
7. **See it work:** mubit-tester `test_feature("<core loop in one sentence>", game=slug)`.

## Report format
```
Built <title> (`<slug>`) in <min> min, job <id>: critic <score>/10
done(slug): READY | not ready: <missing parts>
Played: test_feature <verdict> (test <id>), screenshot <path>
Next: <what improve_game / you should do>
```
Report only what tools printed. If the job is still running when you have to answer, say so and
give the job id.

**Deadline** ("back in 20 min"): build first. Spend what's left on improving-games-until-done
rounds. At the deadline, report the state honestly with the job id, even if it isn't READY.

## Common mistakes
| Mistake | Fix |
|---|---|
| Building without `studio=` | It goes to the first connected window, maybe the shared place |
| Polling `job(id)` with no wait | `job(id, wait_seconds=300)` streams and saves calls |
| "Done" right after the build | Done means `done(slug)` READY |
| Telling the user "open Studio and press Play" as proof | `test_feature` is the proof |
