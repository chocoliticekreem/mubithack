---
title: "Why Forge's self-improvement doesn't compound yet, and the fix"
date: 2026-10-24
tags: [forge, autopilot, mubit, self-improvement, diagnosis]
---

# Self-improvement: diagnosis and fix plan

**The goal.** Agents spot anomalous behaviour in a game, the right ones get fixed, and each run teaches the
system something, so every following run needs fewer rounds and fewer calls and ends with a better game.
That compounding is the moat we pitch on top of Mubit.

**Where we are.** It doesn't compound yet. Not because the models are weak: the loop never gives them clean
evidence to learn from. This doc gives the evidence, the four causes, and five fixes in build order, each
with where it lands and how we know it's done.

Everything here is from the code on `main` at `b0fe263` + #150 and the run data under `runs/` on
2026-10-24. Nothing needs real players.

## 1. What the data shows

### 1.1 The autopilot has completed one real round, and kept nothing

`runs/funfair-frenzy-an-amusement-park-obby-2/autopilot/rounds.json`, round 1 (09:03):

| Step | Count |
|---|---|
| Evidence items | 60 |
| Statistical pre-filter hits | 3 |
| Anomalies from `anomaly_detector` | 6 |
| Gaps from `gap_finder` | 10 |
| Decisions | 12 |
| Jobs run | 4 (3 fix/feature + 1 compile check) |
| **Kept** | **0** |
| Rolled back | 3 |
| Cost | 97 calls, 22 minutes |
| Critic | 7.0 → 7.0 |
| Fun critic | 6.5 → 6.2 |

The runs under `.claude/worktrees/wf_e59d704a-991-4/runs/funfair-{broken,fixed}` (10:49, 11:00) have
identical numbers and job ids: they are copies of the same round, not new evidence. Round 2 started
(`rounds/2/` has observe → act) but never reached verify.

### 1.2 One noisy counter rolled back all three jobs

`rounds/1/verify.json`:

```
"verdict": "rolled_back",
"regressions": ["core counters stopped moving: jump_pad_used"],
"improvements": ["counters now moving: shop_nudge"]
```

- `jump_pad_used` was 2 in the baseline measurement and absent after.
- None of the 12 changed files touch jump pads (`Onboarding`, `FirstBuy`, `Shop`, `Zone10`, `Finale`,
  `HudController`, …).
- The gate's own docstring says this case is "often sampling noise (smoke-play bots land on different
  stages each run, so jump_pad_used can be 0 by chance)" (`forge/autopilot.py:344`).
- Because the jobs are gated as one batch, every job got the same verdict and the same reason
  (`learn.jsonl`: all three `rolled_back`, `why: core counters stopped moving: jump_pad_used`).

### 1.3 The detector was then told its findings were wrong

`autopilot/corrections.jsonl`:

```
{"role": "anomaly_detector", "kind": "outcome", "round": 2, "note": "3 earlier findings rolled back or failed"}
{"role": "gap_finder",       "kind": "outcome", "round": 2, "note": "3 gap jobs rolled back or failed"}
```

Round 2's detector and gap-finder calls carried those outcomes as feedback in the same Mubit task
(`forge/autopilot.py:711–730`). "Onboarding HUD stuck on step 1" was very likely a real bug. **The only
labelled examples the detector has teach it the wrong lesson.**

### 1.4 The roles that should learn most have almost no examples

Unique Mubit calls per role across all 35 local call logs (`runs/**/calls.jsonl`, deduplicated by request id):

| Role | Calls |
|---|---|
| investigator | 932 |
| player (AI testers) | 820 |
| fixer | 192 |
| coder | 118 |
| judge | 75 |
| patcher | 69 |
| reflector | 53 |
| critic | 50 |
| … | … |
| gap_finder | **4** |
| anomaly_detector | **2** |

Mubit trains a task automatically at **25 kept examples** (`docs/research/mubit.md` §4). At one detector
call per round, the detector needs ~25 rounds before its first adapter. It won't happen before the freeze
at this rate.

### 1.5 What a game learns stays in that game

- Outcomes go to `runs/<slug>/autopilot/learn.jsonl`, per game.
- The reproduce-first fix cycle (`forge/repro.py`) writes proven bugs as failing checks into
  `runs/<slug>/checks/`, also per game.
- The receiving end for sharing already exists: `forge/director.py:195` `install_genre_checks` copies
  `forge/genre_checks/<genre>/*.luau` into every new game. But that library is hand-written (9 obby
  checks) and nothing promotes a game's proven checks into it.

So a bug found and fixed in one obby is found again, at full LLM cost, in the next obby.

## 2. The four causes

1. **Blame goes to the whole batch.** Jobs are applied together and gated together
   (`act` at `forge/autopilot.py:814`, `verify` at `:891`). One regression, or plain noise, marks every
   job as failed.
2. **Two questions get one answer.** "Was the anomaly real?" (the detector's job) and "did the fix work?"
   (the fixer's job) share one outcome. A failed or unlucky fix punishes the detector.
3. **Hard gates read noisy signals.** Counters from the AI swarm come from LLM players (the `player` role)
   choosing different actions each run. Comparing one run before with one run after makes a "regression"
   partly a coin flip. #150 adds one re-measurement for dead counters; it treats the symptom and has not run
   on a real round yet.
4. **Nothing compounds across games.** A confirmed anomaly is used once and forgotten.

## 3. The fix, in build order

Fixes A–C stop the loop from learning the wrong things. Until they land, every extra autopilot round adds
more wrong labels. D gives the detector enough examples to train. E is the part that makes each run cheaper.

### A. Gate only on deterministic signals — S/M

- **What:** split the evidence the gate reads into two kinds.
  - **Hard (can roll back):** compile errors, headless boot errors, new runtime errors in a like-for-like
    probe, checks that passed and now fail, physics flags, and counters from **scripted** smoke play run
    with a fixed seed and fixed stage assignments.
  - **Soft (journal and detector evidence only):** counters and findings from the LLM swarm and QA testers,
    critic and fun scores. A soft drop can ask for a confirming re-measure; it never rolls back alone.
- **Lands in:** `forge/autopilot.py` `gate()` (`:360`) and `measure()` (`:625`); `forge/smoke.py` (seed and
  stage assignment); `forge/evidence.py` (tag each counter with its source).
- **Done when:** replaying round 1's `measure-baseline.json` / `measure-after.json` through the new gate
  does not roll back on `jump_pad_used`, and a deliberately broken checkpoint script still rolls back.

### B. Per-job blame — M

- **What:** keep running the batch together (cheap when it passes). When the batch gate fails, re-apply
  each job alone on the baseline and gate it alone. Only jobs that fail on their own are rolled back and
  labelled `rolled_back`; jobs that pass alone are kept. If they only fail together, label the pair
  `conflict`, not each one as bad.
- **Cost:** extra measurements only on a failed batch. Use the focused checks plus scripted smoke play,
  not a full swarm.
- **Lands in:** `forge/autopilot.py` `verify()`; `forge/versions.py` for apply-one-on-baseline.
- **Done when:** a test round with one good job and one job that breaks a passing check keeps the good
  one, rolls back the bad one, and `learn.jsonl` has two different outcomes.

### C. Label the detector by reproduction, the fixer by the gate — M

- **What:** before an anomaly becomes a fix job, the existing reproducer (`forge/repro.py`, `reproducer`
  Mubit task) writes a check that must fail while the bug exists.
  - Check fails → the anomaly is **confirmed**: positive example for `anomaly_detector`. Fix job goes
    ahead and is judged by that check passing plus the saved suite.
  - Check passes, or can't be written → **not reproduced**: negative example for the detector, no fix
    job, nothing spent on fixing.
  - Fix result (kept / rolled back) labels the `fixer` only. It never reaches the detector.
- Gap-finder items that are "missing feature", not "broken behaviour", skip reproduction and are labelled
  by whether the feature job is kept.
- **Option to check with Mubit:** Banyan Sapling (`MubitLabs/banyan-sapling`, a LoRA of Qwen3-30B-A3B)
  is described as a model that verifies claims. It could be the confirm step for anomalies the reproducer
  can't turn into a check. Whether the gateway serves it is not verified; ask at office hours before
  building on it.
- **Lands in:** `forge/autopilot.py` `decide()` / `act()` / `learn()` (`:971`); reuse `forge/repro.py` as is.
- **Done when:** `learn.jsonl` records have separate `detector_label` (confirmed / not_reproduced) and
  `fix_label` (kept / rolled_back / conflict) fields, and `corrections.jsonl` never sends a fix outcome to
  `anomaly_detector`.

### D. One detector call per candidate, and backfill — M

- **What:**
  - Today the detector is one large call per round. Change it to one call per pre-filtered candidate:
    "here is this evidence cluster; is it anomalous, how severe, what's the likely cause, which ids
    prove it". The system prompt stays fixed (same Mubit task); the candidate goes in the user message.
    That's ~10–20 labelled examples per round instead of 1, so the 25-example threshold comes in 2–3
    rounds.
  - Backfill: replay the per-candidate detector over the evidence already on disk (35 call logs,
    playtest reports, tester reports, versions with known outcomes) and label the replies with fix C's
    rule where the outcome is known.
- **Cost:** more, smaller calls. Use the fast model tier for the per-candidate call; the merge and rank
  stay as they are.
- **Mubit note:** a changed call shape is a new task anyway (different user-message structure is fine,
  but if the output format changes, Mubit splits the task). Decide the output format once and freeze it.
- **Lands in:** `forge/autopilot.py` detect phase; a new `forge autopilot --backfill` path; a new prompt
  file only if the format changes (never edit the existing one).
- **Done when:** one round produces ≥10 labelled detector examples, and the Mubit console shows the
  detector task counting toward 25.

### E. Every confirmed anomaly becomes a genre check — M

- **What:** when a fix is kept, its reproducing check (already in `runs/<slug>/checks/<id>.luau`) is a
  candidate for the genre library. Promote it if it is written against kit APIs or tags rather than one
  game's file names, so it can run on any game of that genre.
- **Then:** `install_genre_checks` (`forge/director.py:195`) already copies the library into every new
  game, so the next obby runs that check from the start, for free, with no detector call. Over time the
  LLM detector only has to find **new kinds** of problems.
- **Smallest version:** `forge promote-check <slug> <check-id>` copies the check into
  `forge/genre_checks/<genre>/` after a headless run proves it passes on the fixed game and on one other
  game of the same genre (so it's not game-specific). Autopilot suggests candidates in its journal; a
  human or the gate approves.
- **Lands in:** new `forge/promote_check.py` (or in `forge/checks.py`), `forge/cli.py`,
  `forge/genre_checks/`.
- **Done when:** a check proven in one obby is installed and run in a freshly made obby with zero
  anomaly-detector calls spent on that bug.

## 4. How we prove it compounds

Run the same loop on three obbies made one after another (A, B, C), with fixes A–E in. Track per game:

| Metric | Source | What "working" looks like |
|---|---|---|
| Rounds to ready (`forge done` green) | `rounds.json` | Falls from A to C |
| Calls to ready | `state.json` budget | Falls from A to C |
| Kept rate (kept / jobs) | `learn.jsonl` | Rises above 0, stays steady or rises |
| Detector precision (confirmed / proposed) | `learn.jsonl` `detector_label` | Rises as the adapter trains |
| Genre checks installed at start | `runs/<slug>/checks/` | Grows from A to C |
| Bugs caught by a promoted check, not the LLM | checks results | Above 0 for B and C |

That table, filled with real numbers, is the moat slide: "the third game cost X% fewer calls than the
first, because the first one's bugs became checks and the detector was trained on what was real".

## 5. Order and size

| Order | Fix | Size | Why this order |
|---|---|---|---|
| 1 | A. Deterministic gate | S/M | Removes the noise that causes wrong rollbacks |
| 2 | B. Per-job blame | M | Stops one bad job sinking good ones |
| 3 | C. Reproduction labels the detector | M | Stops wrong labels reaching Mubit |
| 4 | D. Per-candidate calls + backfill | M | Gets the detector to 25 examples |
| 5 | E. Confirmed anomalies → genre checks | M | The part that makes each run cheaper |
| 6 | Three-obby run | — | Produces the evidence for the demo |

**Before A–C land, don't run more autopilot rounds on games we care about.** Each one adds wrong labels
to the detector and gap-finder tasks.

## 6. Constraints

- `forge/autopilot.py` is Arvin's lane (#139, #150): work on a branch and PR it.
- Don't edit `forge/prompts/*.md`. Per-call content goes in the user message; a new format gets a new
  prompt file.
- Update `docs/ARCHITECTURE.md` in the same commit as any signature change.
- Tests: extend the existing autopilot tests with the replay case in fix A and the two-job case in fix B.

## 7. Open questions

- Does the Mubit gateway serve Banyan Sapling, and can it be its own task for claim verification?
- Do Mubit's console Good/Bad ratings change which examples are kept? Not documented
  (`docs/research/mubit.md` §3).
- How long does training take once a task reaches 25? Not documented.
- Why did `forge ledger --json` print nothing on 2026-10-24? The per-role counts above come from the call
  logs instead.
