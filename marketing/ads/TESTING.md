# Testing plan: icons and sponsored ads (one page)

**Where we are:** sponsored ads run at about **1% CTR** across 19 live creatives. Our target is **3%**,
and the stretch goal is **5%**.

**Playbook** (Tizyz, `docs/research/marketing/`):
- Sell the core fantasy ("Be a firefighter") in 2–4 words a 3rd grader can read.
- Run 10–20 creatives at about $16/day for at least 3 days.
- Expect stats to lag about 3 days.
- Ship updates while the ads run.

## 1. Icons: one change at a time, 7 days each
- **Candidates:** the baseline `icon-final` and six new icons: `icon-v3-face`, `-truck`, `-word`, `-spray`,
  `-rescue` and `-night`.
- **Test order:**
  1. icon-v3-face
  2. icon-v3-truck
  3. icon-v3-word
  4. the next best of spray, rescue and night
- **How to run it:**
  - If Creator Hub lets the experience hold several active icons or Home images and personalise them,
    add the baseline plus 2 new icons. Leave them alone for **7 days** while the personalisation learns.
  - If only one icon can be active, swap it by hand **once every 7 days**.
  - Use full weeks so weekday/weekend swings cancel out. Don't change the title or thumbnails in the
    same week, or you won't know what moved the number.
- **Metric:** Analytics → Acquisition, Home **impressions → plays (QPTR)**, compared with the baseline week.
- **Keep or roll back:** keep the new icon if it beats the baseline by **15% or more** relative.
  Otherwise roll back.

## 2. Sponsored ads: cut by CTR after 3 days
1. Run each campaign at the playbook's minimum, about **$16/day** in ad credits (daily budget), for **3 days**.
   Use the recommended settings and all ages. Each campaign holds up to 10 creatives, and Roblox spreads
   impressions across them.
2. On day 4, wait until a creative has **at least ~5,000 impressions**, then:
   - **Below 1.5% CTR: cut it.**
   - **1.5–3%: keep it** for 3 more days.
   - **Above 3%: winner.** Make 2 more creatives with the same angle (same hook, new art) and add them in
     place of the cuts.
3. Always keep 10–20 creatives live. Refill from the bench at the bottom of the ranking.
4. Ship a game update the same day the stats arrive. Ads only buy the click. Retention earns Home traffic.

## 3. When to stop ads
In **Acquisition → Impressions (last 7 days)**, compare **Home recommendation impressions** with
**Sponsored ad impressions**. **Stop the ads once Home impressions are higher.** Before that, keep them
running. It usually takes about a week of ads before Home impressions show up at all.

## 4. Starting rank: all 29 creatives by expected CTR
This is a ranking **before** we have per-creative data, judged on:
- one big subject
- a face showing emotion
- 1–4 easy words
- bright fire against a dark or blue background
- the core fantasy or a challenge

Replace it with real CTR on day 4. ★ marks the 10 new ones. "Live" means currently running.

| # | Creative | Hook | Why |
|---|---|---|---|
| 1 | ★ ad-32-aaah-fire | AAAH! FIRE! | A giant screaming face fills the frame. Two words. Max contrast |
| 2 | ★ ad-29-save-the-puppy | SAVE THE PUPPY! | A scared, cute pet, warm fire against blue. A clear fantasy |
| 3 | ad-19-spray-it (live) | SPRAY IT! | A huge face plus one action, on blue |
| 4 | ★ ad-30-your-own-fire-truck | YOUR OWN FIRE TRUCK! | Owning a truck is a strong kid fantasy. Bold head-on shape |
| 5 | ad-10-be-a-firefighter (live) | BE A FIREFIGHTER! | The exact core fantasy, a bright sky |
| 6 | ★ ad-33-help | HELP! | One word and a plea. *Policy risk, see below* |
| 7 | ★ ad-25-oops-wrong-house | OOPS! WRONG HOUSE! | Comedy you get in one look |
| 8 | ad-05-bring-the-water (live) | BRING THE WATER! | A big face, fire behind |
| 9 | ad-03-save-the-cat (live) | SAVE THE CAT! | A pet rescue |
| 10 | ad-16-save-the-panda (live) | SAVE THE PANDA! | A pet rescue, and green stands out |
| 11 | ★ ad-31-night-fire | NIGHT FIRE! | Glowing fire at night is high contrast |
| 12 | ★ ad-26-whos-inside | WHO'S INSIDE? | Mystery: glowing eyes in a dark window |
| 13 | ad-02-who-started-the-fire (live) | WHO STARTED THE FIRE? | Funny blame, two faces |
| 14 | ★ ad-24-play-with-friends | PLAY WITH FRIENDS! | Social, co-op |
| 15 | ★ ad-28-beat-the-clock | BEAT THE CLOCK! | A challenge, a big clock |
| 16 | ad-17-stop-the-fire (live) | STOP THE FIRE! | A clean split, a little generic |
| 17 | ad-13-drive-the-fire-truck (live) | DRIVE THE FIRE TRUCK! | A good fantasy with a small face |
| 18 | ad-12-save-the-kids (live) | SAVE THE KIDS! | Emotion, but the kids are small |
| 19 | ad-06-ka-boom (live) | KA-BOOM! | Spectacle without a face |
| 20 | ad-11-put-out-the-fire (live) | PUT OUT THE FIRE! | Muddy photo background |
| 21 | ad-01-save-them-all (live) | SAVE THEM ALL? | Muddy photo, small subject |
| 22 | ad-21-can-you-save-them (live) | CAN YOU SAVE THEM? | The window faces are tiny |
| 23 | ★ ad-27-new-dispatch-radio | NEW! DISPATCH RADIO! | A feature, not a fantasy. Better for players coming back |
| 24 | ad-23-fire-squad (live) | FIRE SQUAD! | Four equal faces split the focus |
| 25 | ad-07-backdraft (live) | BACKDRAFT! | Above a 3rd-grade reading level |
| 26 | ad-20-rescue-everyone (live) | RESCUE EVERYONE! | Busy, four subjects |
| 27 | ad-08-rooftop-rescue (live) | ROOFTOP RESCUE! | Small subjects, low contrast |
| 28 | ad-04-8-player-squad (live) | 8 PLAYER FIRE SQUAD | Eight tiny faces, busy |
| 29 | ad-09-fire-chief (live) | BECOME FIRE CHIEF | A reward, not a fantasy. Close to the "status" rule |

**Cut now, before the data:** ad-09, ad-04, ad-08, ad-20 and ad-07. Swap in the top 5 new ones:
ad-32, ad-29, ad-30, ad-25 and ad-31.

**Suggested campaigns of 10:**
- **A:** 32, 29, 19, 30, 10, 33, 25, 05, 03, 16
- **B:** 31, 26, 02, 24, 28, 17, 13, 12, 06, 27
- **Bench:** the rest, ready to refill.

**Policy watch:**
- **ad-33 (HELP!):** a cartoon chick in a burning window. Advertising Standards say not to show people in
  unsafe situations to under-18s. If moderation rejects it, run ad-26 (same idea, no visible kid) in its
  place.
- **ad-12 and ad-21:** the same risk applies.
