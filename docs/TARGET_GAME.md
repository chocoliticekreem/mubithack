# Target game: "Flame and Blame" (Roblox version)

Reference: the Flame and Blame trailer, https://x.com/NotPaloIntel/status/2111464750341308909 (70 s,
a mix of in-game cinematics and gameplay). This is the game Forge should build from one idea and
then keep improving.

## What the trailer shows (frame by frame, every ~3 s)

1. A desert road at dusk with an RV, then a school hallway where an NPC pulls the **fire alarm**.
2. The fire station's red alarm light, then **two firefighters (helmets 01 and 02) gearing up** at
   their lockers. It's first person, with big gloves and hose coils on the bench.
3. A rush out the door, then a **burning apartment block at night**: two firefighters hold a
   **rescue trampoline** while a fire truck (No. 67) is parked behind them.
4. A cat drooling in a window (a pet to rescue), then a jungle and bamboo scene.
5. A living room on fire. The player waters a flower with a **watering can** while the room burns
   (a joke "wrong tool" moment).
6. An **axe breaking down a door**, then a **knocked-out civilian revived with an oxygen tank** on
   the lawn.
7. A **burnt, soot-covered NPC** in a charred room, then a rainbow-coloured character.
8. **Slapping** a dazed farmer awake by a haystack, then a **walkie-talkie** in a burning forest.
9. A dog and a guy in a pool float in a burning bedroom (rescue targets).
10. A teammate **electrocuted on a wet floor** by a fuse box (friendly-fire chaos).
11. A **fire tornado** over a field next to the truck, then crawling through smoke and burning
    grass, then a **detonator** on a dam, which is blown up so a **tidal wave** puts out a whole
    burning city.
12. Ending: the crew in the back of the truck with a **rescued panda** and a dog in a flooded town.
    Title card: **FLAME AND BLAME**.

Store copy: co-op for up to 4 players. Drive the truck and fight fires. Rescue a panda in the middle
of the chaos. **Blame your friends.**

## The core of it (what makes it fun)

- **Co-op chaos:** 1–4 players, first person, physics-y and funny.
- **Every mission is the same loop:** an alarm goes off, you **drive the truck** to the call,
  **put out fires**, **rescue people and pets**, and get back.
- **Tools:** hose (water tank), axe (doors), oxygen tank (revive), trampoline (people jumping from
  windows), extinguisher, and silly items like a watering can.
- **Hazards that hurt teammates:** water plus electricity, explosions, fire tornadoes. Funny
  failure is half the game.
- **Blame:** after a mission, a results screen hands out funny awards for who caused the most
  damage, who electrocuted whom, and who saved the panda.
- **Look:** chunky low-poly, big googly eyes, warm sunset colours, and characters numbered on their
  helmets.

## Roblox scope (what Forge builds first)

Keep it to blocky parts built from code. No meshes are needed for v1.

| v1 (must work in a solo Studio playtest) | v2 (later iterations) |
|---|---|
| Fire station spawn, alarm, a mission timer | Drivable truck (VehicleSeat) |
| A town block of 3–5 houses; random fires that spread between parts | Trampoline catch, oxygen revive |
| Hose tool: a water tank that refills at the truck or a hydrant, spraying puts out fire | Wet floor + fuse box electrocution |
| NPC civilians and pets (dog, cat, panda) to carry back to the truck | Fire tornado event, dam + tidal wave finale |
| Axe tool breaks locked doors | 4-player squad roles, numbered helmets |
| End-of-round results with "Blame" awards (fires put out, rescues, damage caused) | Cosmetics, upgrades |

ForgeTelemetry counters to track in playtests: `fires_extinguished`, `fires_spread`, `rescued`,
`doors_broken`, `water_used`, `rounds_completed`.

## Seed prompt for Forge

```bash
forge new "Flame and Blame: co-op chaotic firefighters. Alarm rings at the fire station, run to a \
small town block where houses catch fire and fire spreads part to part. Hose tool with a water tank \
that refills at a hydrant puts fires out; axe tool breaks locked doors; carry trapped civilians and \
pets (dog, cat, panda) back to the fire truck. 3-minute rounds, then a results screen with funny \
Blame awards (most fires put out, most damage, panda saver). Chunky low-poly, built from parts." \
--iterations 3
```
