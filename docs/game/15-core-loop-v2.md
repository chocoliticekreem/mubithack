# 15. Core loop v2: tighter, more compulsive, mobile first

Status: design note. Items marked **SHIPPED** are in `main` (PRs #237, #239, #241, #242). Items marked
**PROPOSAL** are new systems that are waiting for review and are not built.

## The loop

```
CALL  ->  DRIVE  ->  SPRAY  ->  RESCUE  ->  REWARD  ->  UPGRADE  ->  NEXT CALL
 2 s      10-20 s    30-60 s    30-60 s     5 s         5-30 s       1 tap
```

A rookie's first call should run about 2 minutes from tap to reward, and every later call 3-4 minutes.
The proven part (about 80%) is what kids already know from big Roblox games. The fresh part (about 20%)
is ours: co-op chaos, penguins, the Blame Board and map variety.

| Beat | Copy this | What we do | Status |
|---|---|---|---|
| Call | Natural Disaster Survival round start | Rookies get the nearest site, and NEXT CALL! on the results starts the next one in one tap. The radio keeps offering calls in free roam. | SHIPPED (#237, #241) |
| Drive | Jailbreak / Brookhaven vehicle | Instant in / out, GPS turn card, "HIT THE SIREN!" card. Truck-only buttons on phones. | SHIPPED (#242); PROPOSAL: a GPS ribbon on the road and an ETA chip |
| Spray | simulator "click the thing" | `[T]` at the truck = hose (endless water), then a guide arrow on the nearest fire. | SHIPPED (#239); PROPOSAL P5 fire beacon |
| Rescue | Brookhaven carry / Piggy items | Carry them outside (indoors) or to the truck (outdoors). Yeet = Blame. | SHIPPED (#217, copy #239) |
| Reward | Pet Simulator pop-ups | XP, battle pass XP, stars, Blame cards. Next: **coins**. | Partly SHIPPED; PROPOSAL P1 |
| Upgrade | Cut Grass / Pet Sim upgrade board with **Buy 1 / Max** | Hose power, truck speed, gear slots. | PROPOSAL P1 |
| Next call | Doors / TDS "play again" | NEXT CALL! and a NEXT UNLOCK teaser on the results screen. | SHIPPED (#241) |

## A clear reward and progression every call (PROPOSAL P1)

**Coins (new currency).** Every call pays out on the results screen: fires out x 2, rescues x 10, stars
x 15, and +25% for a squad of 2 or more. Rookie calls pay a fixed 50, so the first upgrade is affordable
after call 1. XP and levels stay as they are (gear unlocks, battle pass).

**Upgrades board.** A big board in the station by the LOCKER, plus a tab in the STORE so phones can open
it anywhere. Three rows to start, each with a level, the next effect, its cost, and two buttons,
**BUY 1** and **MAX** (Tizyz: Build or Get Robbed added MAX after kids spammed BUY 1, copying Cut Grass):

| Upgrade | Effect per level | Levels | Cost curve |
|---|---|---|---|
| Hose Power | +8% water put on fires (ToolConfig spray litres) | 20 | 25 x 1.25^n |
| Truck Speed | +4% MaxSpeed (VehicleConfig) | 10 | 40 x 1.3^n |
| Heat Shield | +6% heat resistance (HeatService) | 10 | 40 x 1.3^n |

Server-authoritative. Numbers come from a new `UpgradeConfig`, state lives in the profile (`upgrades`),
and the buy is a rate-limited remote. A pure `Lib/Upgrades/UpgradeMath` (cost, MAX affordable) gets a
spec. Files: `UpgradeService`, `UpgradeController`, `UpgradeConfig`, `ProfileSchema.upgrades`. No paid
coins at first (keep it fair). Later a 2x coins game pass.

Why: right now XP is the only reward and there is nothing to spend between calls, so "one more call"
has no pull. A visible number going up after every call, plus a cheap thing to buy, is the most proven
retention loop on Roblox.

## Daily goals (PROPOSAL P2)

Three goals a day, shown as one chip under the top bar and on the results screen:
"Put out 15 fires", "Rescue 3 pets", "Finish 3 calls". Each pays coins, and all three pay a gold chest
(a cosmetic or a coin pile). Reset at 00:00 UTC. Copy Pet Simulator 99 / Bee Swarm quests: a short
list, a progress bar, and a claim button that pops. On NEXT CALL! the screen shows "2 more calls for
today's chest".

## Session-two hook (PROPOSAL P3)

- **Streak chest:** come back tomorrow for day 2 (coins plus a helmet colour). Day 7 is a truck skin.
  The tease shows on the first session's last results screen and in the What's New panel.
- **"Ladder Truck at Level 3":** the NEXT UNLOCK teaser (shipped) already names the next gear. Add one
  vehicle unlock early (the ladder truck at Level 3) so the goal is a *new truck*, the strongest
  firefighter fantasy reward.
- **Favourite / notify prompt** after the first 3-star call (the What's New flow already asks once).

## The 20% that makes us different

- **Co-op chaos:** shared trucks, one hose per truck, carrying and yeeting people, panda pairs. Keep it
  readable: every chaos mechanic must already be explained by the Blame card it produces.
- **Penguins:** the firefighter penguin is our brand (thumbnails, avatars). Put penguin rescues and
  penguin cosmetics in the daily goals and the battle pass.
- **Blame Board:** the results' Blame cards are the viral screenshot. Add a weekly server board
  ("Most blamed this week") in the station (`LeaderboardService` exists).
- **Map variety:** zoo, dam, forest, farm and school calls come after the rookie calls (rookies get
  house fires only, #241). Unlock-gate the special maps by level so each level-up brings a new place.

## Mobile-first HUD (target layout, 844x390)

```
[LV ===XP===] [PASS] [STORE] [DISPATCH]                [minimap]
[ 2 fires left · 1 inside ]           (one objective chip)
                       [one guide card, one line]

                    (world: ONE big arrow)

[HELP]                [HAND][SWAP][CARRY]          [ACTION] [SPRAY]
```

Rules, from Grow a Garden's HUD and Tizyz's "death by a thousand cuts":
- At most **3 thumb buttons** in any state: on foot SPRAY plus one context button (DROP or THROW when
  carrying); in a truck OUT, SIREN and HONK (shipped #242); during the tutorial SPRAY only (shipped #242).
- **One instruction at a time:** guide card or toast, never both. One countdown (shipped #242).
- **One world arrow** to the single next thing, not three stacked markers (R / F / !).
- Modals (results, store, locker) always sit above the thumb buttons (results fixed, #241).
- No full-screen colour washes on phones (calm effects by default).
