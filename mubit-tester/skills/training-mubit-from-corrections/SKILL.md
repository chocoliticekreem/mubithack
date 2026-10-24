---
name: training-mubit-from-corrections
description: Use when an AI playtester, Forge role (fixer, auditor, critic, triage) or AI player made a wrong call and the user wants Mubit to learn from it ("make it learn", "correct the AI", "this should be a training example"), or when preparing the demo's correction → model update moment.
---

# Turning a correction into a Mubit training example

## Overview
Mubit groups calls into a **task** by their exact system prompt. A correction is a *new call in the
same task* whose user message has the human's note added. That call is the training example. Each
task trains an adapter after **25 kept examples**, and the user's Good/Bad rating in the console
decides which calls are kept. A correction counts only once it is (1) in the right task, (2)
specific, and (3) rated Good.

## Pick the route
| What was wrong | Tool | Task it lands in |
|---|---|---|
| An AI player's action at a step of a playtest | `playtest_correct(run_id, step, note, player)` (mubit-tester) | `player` (or `explorer`) |
| A QA protocol (`qa_test`) judgement | `playtest_correct(run_id, step, note)`: step 0 = the plan, n = step n's verdict, -1 = the visual review | `test_planner` / `step_judge` / `visual_judge` |
| Code a Forge game wrote | `correct(slug, path, note)` (forge) | `fixer` |
| The auditor missed something a human saw | `tester_report(slug, text, run_ids)` (forge) | `triage` + `auditor` |

Never edit `forge/prompts/*.md` or `mubit-tester/prompts/*.md` to "teach" it. That starts a new
task and throws away its examples.

## Steps (AI player)
1. `report(run_id)`. Find the step and player and read what it saw and did. If the run, step or
   player doesn't match what the user described, stop and say so. Don't correct the wrong call.
2. Write the note in three parts: **saw** (from the step's observation), **should have done**
   (one concrete action with its target), **because** (the rule it broke). For example:
   *"Couch2 was burning 6 studs ahead and you held water 80. You should have used the hose
   aimed at Couch2 instead of walking to the truck, because a fire in range with water beats
   repositioning."* A one-line "should have sprayed" teaches almost nothing.
3. `playtest_correct(run_id, step, note, player)`. Check that **After** is now the right action.
   If it isn't, sharpen the note and correct again.
4. Copy the **Mubit request id** from the result.

## Steps (Forge code)
1. `read_file(slug, path)`. Name the wrong lines and the behaviour you want.
2. `correct(slug, path, note)`, then `job(id, wait_seconds=300)`. The log ends with the request id.
3. Prove it in play: `test_feature(...)` on that behaviour.

## Always finish with
```
Correction recorded: <task> task (the result names it), request <id>
Before: <old action/code>   After: <new>
To make it a training example: Mubit console → Requests → <id> → Rate Good
(this task trains its adapter at 25 kept examples; the console shows the count).
```
Ratings are a manual click: say so. Don't claim the model "learned" or was "updated" until the
console shows a new adapter version.

## Common mistakes
| Mistake | Fix |
|---|---|
| A vague note ("should have sprayed") | saw / should / because, with targets |
| Not checking the run first | `report(run_id)` before correcting |
| Saying "Mubit learned it" | It's one example. It trains at 25 kept, and only after rating Good |
| Editing a prompt file to fix behaviour | Corrections go in calls, never in prompt files |
| Leaving out the request id | The user needs it to rate the call |
