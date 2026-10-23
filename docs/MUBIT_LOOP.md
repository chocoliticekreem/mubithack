# The Mubit loop: how Forge finds anomalies and gets better at it

Goal: make Mubit the part of Forge that can't be removed. Forge builds a game, testers play it,
anomalies are found, fixed and **verified**, and every verified outcome becomes training data for a
Mubit task. The game gets better within a run, and the models get better across runs.

This builds on what exists: Forge roles (`forge/prompts/`: designer, coder, fixer, critic,
reflector), mubit-tester roles (`mubit-tester/prompts/`: player, judge, explorer), the ForgeTest
harness (`docs/TESTER.md`), `playtest_correct`, `suggest_fix`, scenarios and live `config` tuning.
Facts about Mubit come from `docs/research/mubit.md`.

## 1. What Mubit actually gives us today

| Works (documented) | Not available yet (ask at office hours) |
|---|---|
| Records every call. **Task** = exact system prompt + tools + output format + model | No feedback, correction or outcome API. Only Good/Bad on a call in the console's Requests page |
| Trains an **adapter** per task after 25 kept examples; each version is tested against the frontier model's answers | No way to call an adapter by model ID from our code; only console **Try models** |
| Sessions (`metadata.session_id`) split test cases; we use one per game | Training time and our daily training cap aren't documented |
| Console: task goes Collecting → Training → Testing → Passed; Try models side by side | mubit.ai "verified results" / "calibrates every call at runtime" are the memory SDK, whose routes return 404 today |

Consequences:
- A correction only teaches Mubit if it is a **new recorded call in the same task** (same system
  prompt), with the better answer as the reply.
- The proof of learning for judges lives in the **console**, plus our own before/after numbers.

## 2. The loop

```
  build (designer → coder → fixer)                       ┌──────── fast learning (minutes) ────────┐
        │                                                │ reflector updates runs/lessons.md and the │
        ▼                                                │ anomaly playbook, passed in the next      │
  playtest round: AI players (player/explorer) + real    │ user message                              │
  testers, ForgeTest event log + counters + ForgeProbe   └───────────────────────────────────────────┘
        │
        ▼
  detect: judge (one session's bugs) + auditor (patterns across sessions: economy, balance,
          conflicts) + tester triage (real players' text reports)
        │
        ▼
  fix: critic → fixer (suggest_fix), resync into Studio
        │
        ▼
  verify: rerun the same scenario/goal; verifier compares before vs after
        │      ├─ fixed            → the detection and fix calls were right (rate Good)
        │      ├─ not fixed        → fixer retries; the original call is rated Bad
        │      └─ new regression   → becomes a new anomaly
        ▼
  corrections land as new calls in the same Mubit task ──▶ slow learning (hours): adapters train
        │
        ▼
  stop when the quality bar is met (section 5), then real players
```

## 3. Roles as Mubit tasks

Existing roles keep their prompts. Three new roles fill the gaps. **Each new prompt is final before
its first call**: editing a prompt starts a new task and resets the example count to zero.

| Role | Status | Input (user message) | Output |
|---|---|---|---|
| player, explorer | exists (mubit-tester) | observation, goal, recent actions | one action + suspected bug |
| judge | exists | one session's trace, probe errors, counters | `{goal_met, summary, bugs[]}` |
| critic, fixer | exist | bug + involved files | patch |
| reflector | exists | iteration summary + lessons | updated lessons |
| **auditor** | new | counters and events over several sessions: water used vs fires out, fires spread vs extinguished, rescues per round, round lengths, tool use per player, and (later) currency in/out | `{anomalies: [{kind, system, severity, evidence, expected, observed}]}` |
| **verifier** | new | the anomaly + before and after evidence from the same scenario | `{verdict: fixed \| not_fixed \| regression, evidence}` |
| **triage** | new | a real tester's free-text report + the events around that moment | the auditor's anomaly format, linked to evidence |

Why the auditor matters: the judge looks at one session. Economy, balance and system conflicts
only show up across sessions (for example "fires always win after minute 2", "one player never gets
water", "the axe and the fire both destroy the same door"). That is the recurring task Mubit is best
at: a narrow, repeated extraction over structured data, called on every round.

Volume check: one round of 4 AI players × 20 steps is ~80 player calls, 1 judge, 1 auditor, a few
critic/fixer/verifier calls. The narrow roles (auditor, verifier, triage) reach 25 kept examples in
roughly 25 rounds; planted faults (section 4) make each round produce real examples.

## 4. Planted faults: making improvement measurable

Like Latte Bench, we score the system against known answers. A **fault** is a change we know is
wrong, planted mostly through ForgeTest's live `config` and `set_attr` (no code change needed):

| Fault | How it is planted | What should catch it |
|---|---|---|
| Hydrant never refills | `config ToolConfig RefillRate 0` | auditor: water used, never refilled |
| Fire never spreads | `config FireConfig SpreadChance 0` | auditor: fires_spread = 0 every round |
| Fire spreads too fast to win | `config FireConfig SpreadChance 1` | auditor: rounds never end with fires out |
| Locked door can't break | `set_attr` door `Health` very high | judge/explorer: axe used, door intact |
| Rescue never counts | `config RescueConfig DropoffRadius 0` | judge: carried to truck, `rescued` stays 0 |
| Two systems fight | a scenario where hose water and fire both edit `FireLevel` on one part | auditor: FireLevel oscillates |

Per cycle we record, in `runs/<slug>/scores.json`:
- **detected**: planted faults found / planted
- **false alarms**: anomalies with no matching fault and rejected by the verifier
- **fixed and verified**: faults the verifier marks fixed
- **cycles to bar**: cycles until the quality bar is met

That gives a chart that rises across cycles (fast learning) and across adapter versions (slow
learning), and turns "it got better" into a number.

Key names in the table are placeholders: use the real keys from each system's `*Config.luau`
once lanes G1–G3 have them.

## 5. When to stop: the quality bar

A game passes when, over the last 3 rounds:
- ForgeProbe `errors == []`
- every v1 goal in `docs/TARGET_GAME.md` is `goal_met: true` at least once
- the auditor reports no `high` anomalies
- every planted fault in this game is fixed and verified

Then real players play. Their reports go through triage into the same loop.

## 6. How corrections reach Mubit

| Signal | What we do | Lands in task |
|---|---|---|
| Verifier says **fixed** | rate the original detection call and the fixer call Good in Requests | auditor/judge, fixer |
| Verifier says **not fixed** | rate the fixer call Bad; the fixer retries with the verifier's evidence | fixer |
| Planted fault **missed** | re-send the auditor call with the fault's evidence in the input; that reply is the correction | auditor |
| **False alarm** | rate Bad; re-send with the verifier's evidence | auditor |
| AI player made a bad move | `playtest_correct(run_id, step, note)` (exists) | player |
| Real tester report | triage call; if the auditor missed it, re-send the auditor call with the report | triage, auditor |

Every call keeps its `x-middleware-request-id` in `runs/<slug>/calls.jsonl` so it can be found and
rated in the console.

Unless Mubit ships a feedback API, Good/Bad ratings are manual clicks. Rate in batches after each
cycle, and record each rating next to its request id so `scores.json` and the console agree.

## 7. Demo (3 minutes)

1. A simple game with 5 planted faults. Cycle 1: the auditor and judge find 2 of 5.
2. Fix → verify → corrections, with the Mubit console's Requests page showing them landing.
3. Cycle 3: 5 of 5 found and fixed. The `scores.json` chart is on screen.
4. Console: the auditor task is **Passed**. Try models side by side, adapter vs frontier: quality,
   cost, latency (the "own your intelligence layer" track).
5. Flame and Blame with real players: a tester's report goes through triage into the same loop.

Record steps 1–4 ahead of time. Only run live what is reliable.

## 8. Order of work

1. **Office hours (tonight):** feedback/outcome API? adapter serving by API or header? training
   time? our daily training cap and adapter-start limit? If an adapter can be served, Forge switches
   the auditor to it mid-run. That is the strongest "Mubit is indispensable" story.
2. **Lane A:** write and freeze the auditor, verifier and triage prompts. Add them to
   `docs/ARCHITECTURE.md` in the same PR.
3. **Lane B:** cross-session telemetry for the auditor (aggregate ForgeTest `events` and `counters`
   per round into `runs/<slug>/rounds/<n>.json`).
4. **Faults:** a `faults.json` per game and a `forge faults plant|clear` command that uses ForgeTest
   `config`/`set_attr`.
5. **Scoring:** `scores.json` per cycle, and a chart for the demo.
6. **Start generating auditor calls by Saturday morning**, so the first adapter trains before the
   12:00 check-in. Training resets daily at 00:00 UTC.
