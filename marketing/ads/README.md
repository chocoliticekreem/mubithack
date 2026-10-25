# STATION 67 ads

Roblox ad creatives and the experience icon, made with Remotion from our own cartoon art and real
in-game screenshots (`public/shots/`). The research behind them, with Roblox specs and Advertising
Standards, is in [RESEARCH.md](RESEARCH.md).

## Specs we follow
- **Sponsored experience ads:** 1920×1080 (16:9) JPG, each well under the 3 MB cap. Up to 10 per
  campaign, and Roblox rotates between them.
- **Icon:** 512×512 PNG, checked at 100 px and 150 px.
- **Headline:** 2–4 words, at least 12% of the image height, in cream or yellow with a thick ink
  outline. Text stays inside x 150–1770 and y 90–860, because the player count covers the bottom strip.
- **Every frame:** fire, a penguin firefighter in a red helmet, and one focal action.
- **Honest copy only:** no Robux, no prices, no fake buttons, no "#1" or "free". Every hook is a real
  mission or feature.

## Files (`out/`)
| File | Hook | What it shows |
|---|---|---|
| `icon-final.png` | (icon, live pick) | Variant e with the title: STATION over a huge 67, over the hose-vs-house scene |
| `icon-final-oneline.png` | (icon) | Same, with "STATION 67" on one line (weaker at 100 px) |
| `icon-v2.png` | (icon) | Penguin blasting a hose into a burning house (= `icon-v2-a`) |
| `icon-v2-b.png` | (icon) | Penguin carrying a rescued cat out of the flames |
| `icon-v2-c.png` | (icon) | Fire-lit close-up of a penguin's face, with the hose jet |
| `icon-v2-d.png` | (icon) | Fire truck with a penguin on top, spraying |
| `icon-v2-e.png` | (icon) | `a` plus one word: FIRE! |
| `ad-01-save-them-all.jpg` | SAVE THEM ALL? | Curiosity question: penguin hosing a real in-game burning house |
| `ad-02-who-started-the-fire.jpg` | WHO STARTED THE FIRE? | The blame mechanic: smug and panicked penguins pointing at each other |
| `ad-03-save-the-cat.jpg` | SAVE THE CAT! | The "Cat up a tree" mission: scared cat in a tree, penguin with a hose |
| `ad-04-8-player-squad.jpg` | 8 PLAYER FIRE SQUAD | Number hook: 8 penguin faces in front of a real truck and fire |
| `ad-05-bring-the-water.jpg` | BRING THE WATER! | A big penguin face lit by the fire, with a water jet into a burning house |
| `ad-06-ka-boom.jpg` | KA-BOOM! | The "Pump Panic" gas leak: tanker flung by the blast, pump, penguin flying (in-game gas station screenshot behind) |
| `ad-07-backdraft.jpg` | BACKDRAFT! | Fireball blasting a door off its hinges, sooty penguin blown back |
| `ad-09-fire-chief.jpg` | BECOME FIRE CHIEF | Battle pass tier 20: the Fire Chief title is free and the white-and-gold helmet is on the premium track |
| `ad-08-rooftop-rescue.jpg` | ROOFTOP RESCUE! | The Sky Tower mission: ladder truck, burning tower, penguin stranded on the roof |
| `vid-15s-16x9.mp4` | 15 s video | SAVE THEM ALL? → SAVE THE CAT! → KA-BOOM! → WHO STARTED THE FIRE? → 8 PLAYER FIRE SQUAD → STATION 67 end card |
| `vid-06s-16x9.mp4` | 6 s bumper | SAVE THEM ALL? → KA-BOOM! → end card |

The videos are 1920×1080 H.264 at 30 fps (9 MB and 4 MB). Roblox video ads are 16:9; third-party specs
say 15–30 s and up to 100 MB. 6 s only fits rewarded video (6–30 s). We made no vertical cut, because
Roblox documents no 9:16 placement.

**Screenshots:** ads 01, 02, 03, 04, 05 and 07 use real in-game shots behind the cartoon art, and 06
uses an in-game shot of the gas station. New Studio captures of the gas tanker blast and the Sky Tower
came out flat, with no visible fire and a marker beam in frame, so we left them out.

## Wave 2: core-fantasy hooks (`out/`)
Our first campaign got a 1% CTR. Wave 2 follows the Roblox ads playbook: sell the core fantasy at a
3rd-grade reading level (verb + noun, "Be a ___", or an implied challenge), one big hook of 2–4 words,
one focal action, fire in every frame, and our penguins. Layouts and colours vary so the rotation can find
the winners. Each was checked at 400 px wide. Sources: `src/Ads2.tsx` and `src/Thumbs.tsx`.

| File | Hook | Look |
|---|---|---|
| `ad-10-be-a-firefighter.jpg` | BE A FIREFIGHTER! | Cartoon, blue sky: penguin hosing a burning house |
| `ad-11-put-out-the-fire.jpg` | PUT OUT THE FIRE! | Real house-fire shot, water jet into big flames |
| `ad-12-save-the-kids.jpg` | SAVE THE KIDS! | Purple/orange: burning school, kid chicks in the windows |
| `ad-13-drive-the-fire-truck.jpg` | DRIVE THE FIRE TRUCK! | Purple night, speed lines, penguin in the cab |
| `ad-14-house-on-fire.jpg` | HOUSE ON FIRE! | Real truck-fire shot (blurred), giant cartoon house fire |
| `ad-15-answer-the-call.jpg` | ANSWER THE CALL! | Teal: the dispatch radio buzzing, house fire behind |
| `ad-16-save-the-panda.jpg` | SAVE THE PANDA! | Green zoo/bamboo: scared panda, penguin hosing the fire |
| `ad-17-stop-the-fire.jpg` | STOP THE FIRE! | Split: wall of fire vs blue, water pushing it back |
| `ad-18-fire-truck-race.jpg` | FIRE TRUCK RACE! | Yellow burst: two trucks racing to a fire |
| `ad-19-spray-it.jpg` | SPRAY IT! | Blue: huge penguin face, huge jet into fire |
| `ad-20-rescue-everyone.jpg` | RESCUE EVERYONE! | Real house-fire shot: panda, chick and cat led out |
| `ad-21-can-you-save-them.jpg` | CAN YOU SAVE THEM? | Pink dusk: burning tower, faces in the windows |
| `ad-22-giant-fire.jpg` | GIANT FIRE! | Scale: tiny penguin vs a wall of flame |
| `ad-23-fire-squad.jpg` | FIRE SQUAD! | Real station shot: four penguin friends, fire below |

"BIGGEST FIRE EVER" became **GIANT FIRE!** because Roblox's thumbnail rules ban superlative claims.
"ANSWER 911" became **ANSWER THE CALL!** because the game calls it dispatch, not 911.

### Experience-page thumbnails
| File | Hook | Shows |
|---|---|---|
| `thumb-01-be-a-firefighter.jpg` | BE A FIREFIGHTER! | Real penguin close-up at the station, cartoon hero, fire |
| `thumb-02-trucks-and-dispatch.jpg` | A TRUCK FOR EVERYONE! | Real station bays with four trucks, the radio and "NEW CALLS!" |
| `thumb-03-school-rescue.jpg` | SCHOOL RESCUE! | The real furnished classroom, a chick and a hose |
| `thumb-04-8-player-squad.jpg` | 8 PLAYER SQUAD! | Real squad lined up at Station 67 |
| `thumb-05-new-map.jpg` | NEW MAP! | Four real map shots: SNOW, FOG, SUNSET, NIGHT |

New in-game crops in `public/shots/`: `map-winter/fog/dusk/night.jpg` (the same street under different
map variants) and `school-class*.jpg` (the furnished classroom), cut from Studio captures with the HUD removed.

## Wave 3: icon A/B set and new angles (`out/`)
Our goal is to move a 1% CTR to 3–5%. Each creative has one bold subject and a sticker rim (a thick white outline
plus an ink outline), with bright fire against blue or night. Text is 1–4 words, or none.
`TESTING.md` ranks all 29 creatives and explains how to rotate and cut them.
`COPY.md` has the text for the Roblox fields. Sources: `src/Icons3.tsx`, `src/Ads3.tsx`, `src/kit3.tsx`
(head-on truck, puppy, stopwatch, moon and stars).

| File | Hook | Look |
|---|---|---|
| `icon-v3-face.png` | (none) | Giant brave penguin face in the red 67 helmet, on blue, fire below |
| `icon-v3-spray.png` | (none) | Penguin blasting a wall of fire, on deep blue |
| `icon-v3-truck.png` | (none) | Head-on fire truck, penguin driver, sirens on a yellow burst |
| `icon-v3-word.png` | BE A FIRE FIGHTER! | Three huge words over flames |
| `icon-v3-rescue.png` | (none) | Penguin carrying a happy kid chick out of the fire |
| `icon-v3-night.png` | (none) | Night sky, moon, burning house, a glowing cyan hose jet |
| `ad-24-play-with-friends.jpg` | PLAY WITH FRIENDS! | Two penguins, two jets, one fire |
| `ad-25-oops-wrong-house.jpg` | OOPS! WRONG HOUSE! | A proud penguin soaking the calm blue house while the one next door burns |
| `ad-26-whos-inside.jpg` | WHO'S INSIDE? | Glowing eyes in a dark burning window |
| `ad-27-new-dispatch-radio.jpg` | NEW! DISPATCH RADIO! | A giant buzzing radio on pink |
| `ad-28-beat-the-clock.jpg` | BEAT THE CLOCK! | A stopwatch on fire, a panicking penguin |
| `ad-29-save-the-puppy.jpg` | SAVE THE PUPPY! | A giant scared puppy between two fires, on blue |
| `ad-30-your-own-fire-truck.jpg` | YOUR OWN FIRE TRUCK! | A head-on truck with a penguin driver |
| `ad-31-night-fire.jpg` | NIGHT FIRE! | Navy sky, moon, a glowing jet into a house fire |
| `ad-32-aaah-fire.jpg` | AAAH! FIRE! | Bold variant: a giant screaming penguin face |
| `ad-33-help.jpg` | HELP! | Bold variant: a kid chick in a burning window, with a speech bubble |

Some brief lines changed because the game can't back them up:
- "60 SECONDS TO SAVE THEM" became **BEAT THE CLOCK!**, because on-scene timers run for minutes.
- "ONLY 1% SAVE EVERYONE" became **WHO'S INSIDE?**, because we have no such stat.

## Re-render
```bash
cd marketing/ads
sh render.sh                          # everything
sh render.sh ad-01-save-them-all      # one composition
npx remotion studio src/index.ts      # live preview
```
Sources: `src/Ads.tsx` (ads), `src/Icons.tsx` (icons), `src/kit.tsx` (penguin, hose, jet, house, truck,
cat, embers), and `src/art.tsx` / `src/theme.ts` (copied from `marketing/listing`).
