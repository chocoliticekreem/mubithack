# Night Shift x Mubit — Hackathon Brief

Overnight hackathon in London built around Mubit. 42 hours, ~500 builders.

## Logistics

- **Dates:** Fri 23 Oct – Sun 25 Oct 2026. Doors open Fri 17:00.
- **Venue:** WeWork, 9th floor, 30 Churchill Pl, Canary Wharf Estate, London E14 5RE.
  Elizabeth line, Jubilee line and DLR all stop at Canary Wharf.
- **Clocks go back** Sun 02:00 → 01:00 (extra hour).
- **Teams:** 1–4 people. 18+, in person only. At least one member must be at Sunday's demos to win.
- **Food:** all meals, snacks, caffeine covered for all 42 hours.
- **Bring:** laptop, charger, photo ID, toiletries, sleeping bag/pillow if staying overnight.
- **Discord:** read `#night-shift-info`. Max (the event AI) handles teams, check-ins, submissions, questions.
  - `/team create <name> <public GitHub repo>` → private team channels + join code. Repo URL is
    captured here.
  - teammates `/team join <code>`, then everyone `/team accept` (event rules + data notice)
  - Talk to Max by DM or in the team's `#max` channel (no @ needed). Max can't read the team `#chat`.

## Schedule

| When | What |
|---|---|
| Fri 17:00 | Doors open, check-in |
| Fri 18:00 | Kickoff: Mubit walkthrough, tracks, rules |
| Fri 19:00 | Dinner, team matching |
| Fri 19:30 | Hacking starts |
| Sat all day | Meals + office hours with the Mubit team |
| **Sat by 12:00** | **Check-in 1** (`/checkin`) |
| **Sat 12:00–18:00** | **Check-in 2** (`/checkin`) |
| Sat 20:00 | Submissions open (`/submit`) |
| Sat 24:00 | Target: submit by midnight |
| Sun 02:00 | Clocks go back to 01:00 |
| **Sun 05:00** | **Code freeze: hard deadline for code and submissions** |
| Sun 08:00 | Breakfast |
| Sun 10:30 | Judging round 1 (expo) |
| Sun 12:30 | Finalist demos on stage |
| Sun 13:30 | Awards |
| Sun 14:00 | Close |

## The brief

Mubit sits between your app and its model calls. It generates lightweight model updates (adapter
fine-tunes) from your calls and feedback, so the calls you already make become task-adapted open
models. Base models stay fixed; updates are built for fast refresh. Integration = one base URL change
plus a Mubit API key.

**Build a product that routes its LLM calls through Mubit and turns your corrections into model
updates for a recurring task.**

### Tracks (top 3 prizes judged across all tracks)

1. **Recurring tasks** — a task your product runs again and again (extraction, triage, support
   replies, review, routing). Show corrections becoming model updates.
2. **Own your intelligence layer** — move a closed-model workload onto a task-adapted open model.
   Show quality, cost and latency side by side.
3. **Fast refresh** — a workload that keeps changing (new data, customers, domains). Show model
   updates keeping pace.

### Judging (equal weight)

- **Use of Mubit** — show a correction turning into a model update in the demo.
- **Usefulness** — a real recurring task someone would want handled.
- **Technical execution** — it works and holds up under questions.
- **Demo** — clear, live, under the time limit.

### Rules

- All project code written during the event, from Fri 19:30. OSS libraries and your own tooling
  are fine.
- **Every project must route its LLM calls through Mubit.**
- You own what you build.

> Deadline conflict: the original Luma page said code freeze Sun 10:00. Max's Discord rules (posted
> 21 Oct) say **Sun 05:00**. Plan for 05:00.

### Check-ins

Two, both Saturday, via `/checkin`: first by 12:00, second 12:00–18:00. Tell Max what shipped,
what's next, blockers; Max replies with feedback in `#max`. A missed check-in can be made late
until the code freeze.

### Submission

- `/submit` gives the team's upload page once submissions open (Sat 20:00). Aim for midnight.
- Uploads only: **demo video (MP4 or MOV, max 3 min)** + **PDF deck**. No YouTube links.
- Resubmit any time before the freeze; latest submission counts. After 05:00 counts only if an
  organizer accepts it.

## Prizes

- 1st $15,000 · 2nd $10,000 · 3rd $5,000 (cash)
- $35,000 in OpenAI and other AI credits
- $1.5M in Mubit credits for accepted hackers
- +$10K in added prizes announced launch day
- Winners get a direct interview with Mubit's co-founders. Mubit is hiring and will invite people
  met at Night Shift to interview.

## Side Quest 1: Model Card

Upload your Claude Code / Codex session logs; Mubit emails back a model card — the model your data
would train, plus the patterns you repeat that should become a model or skill.

1. Find logs (JSONL): Claude Code `~/.claude/projects/`, Codex `~/.codex/sessions/`.
2. In Discord: `/upload your@email.com`, then upload the files.
3. Post the card on X (tag @MubitLabs) and LinkedIn (tag Mubit).
4. Drop both post links in `#modelcards`.

Judged by Max. Registered hackers only, one entry per person. API keys/secrets are redacted before
processing and not stored.

Prizes: Nintendo Switch 2 · $100 Mubit inference credits · $25 Mubit inference credits.

**Bonus:** route Claude Code or Codex through Mubit (set base URL to Mubit's, use your Mubit key)
and every request shows up in the Mubit console.

## Mubit launches (launch night)

- **Banyan Sapling** — first Banyan-family model. Open-weight research model that verifies claims
  against policies and evidence, and recognises when there isn't enough information to decide.
  https://huggingface.co/MubitLabs/banyan-sapling
- **Latte Bench** — benchmark using simulated latte art: can a model learn from feedback and improve
  each attempt? https://github.com/MubitLabs/latte-bench
