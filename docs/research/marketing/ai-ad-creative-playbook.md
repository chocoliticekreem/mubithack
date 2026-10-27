# AI ad creative playbook: Roblox sponsored image ads (Be a Firefighter 🚒)

Researched 26 Oct 2026. This builds on `marketing/ads/RESEARCH.md` (specs and policy detail) and `marketing/ads/TESTING.md` (ranking and cut rules). Our data so far: "SAVE THE PANDA!" 2.0%, "PUT OUT THE FIRE!" 1.8%, cartoon "DRIVE THE FIRE TRUCK!" 1.5%, busy crowd "SAVE THE KIDS!" 0.3%. Overall CTR is about 1.1%.

## 1. Specs that matter

- **Home sponsored tile = 16:9 custom thumbnail.** Export 1920x1080 PNG/JPG under 3 MB. You can upload up to 10 per campaign. Off-ratio images get stretched ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager), [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)). The move from 1:1 to 16:9 raised play-through by up to 40% ([DevForum](https://devforum.roblox.com/t/leveling-up-ads-manager-with-new-features/3587640)).
- **Search placement uses the 1:1 game icon**, not our ad art. Home and Search are now one campaign ([DevForum, Nov 2025](https://devforum.roblox.com/t/ads-manager-updates-home-search-combined-new-benchmarks-and-sunsetting-the-classic-flow/4084863)), so the 512x512 icon is half the creative. Portal ads aren't in the new flow.
- **Render size:** most impressions are at about **150–300 px wide** on phones ([Vizzbees](https://vizzbees.com/blog/what-makes-a-high-ctr-thumbnail)). On a 300x169 px tile, 1 px is about 6.4 source px. Text 60 px tall in the 1920x1080 source shows at about 9 px, which can't be read.
- **Overlays:** the title sits under the tile, and the player count / metadata covers the **bottom** of the image. Keep the bottom 20% free of anything important ([16:9 thumbnails post](https://devforum.roblox.com/t/169-experience-thumbnails-are-coming-to-home-in-april-%E2%80%93-update-yours-now/2875237)).
- **Delivery:** creatives start out served evenly. The system then shifts impressions to the most engaging thumbnail for each group. You pay per **play**: a click, then the details page, then a join within 1 hour. Reports show impressions, clicks, CTR, plays and cost per play for each thumbnail ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager), [Bloxclips](https://www.bloxclips.com/articles/roblox-ads-manager-explained)).
- **Policy** ([Advertising Standards](https://en.help.roblox.com/hc/en-us/articles/13722260778260-Advertising-Standards), [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)):
  - No fake buttons, notifications, progress bars or anything else that "mimic[s] system functionality".
  - No claims ("BEST", "#1", "FREE", Robux, "50% off"). Text describes gameplay only.
  - For under-18 audiences, nobody shown in unsafe situations and no implied special skills or status. Firefighters wear helmets. **Animals in peril are safer than kids in peril.**
  - Nothing that isn't in the game, and no "artificial graphics enhancements beyond in-game visuals". Photoreal Gemini renders of a blocky game are a moderation **and** click→play risk.
  - English only. No URLs or QR codes.

## 2. Text rules ("massive" done right)

1. **2–3 words. 4 is the hard maximum.** It should be one verb + one noun a 7-year-old can say: SAVE THE PANDA. Each extra word shrinks the type.
2. **Size:** cap height **≥ 14% of image height per line** (font-size about 20–24% of height, which is 216–260 px on 1080). Text should run 75–90% of the image width. The whole text block takes ≤ 40% of the height. Today's `GeminiAds` uses 150–190 px font-size (14–18%). Go about 30% bigger. **A/B test "massive" (text block about 40% of height) against "big" (about 25%).** DevForum reviewers warn against making text *the* focus ([feedback thread](https://devforum.roblox.com/t/feedback-on-recent-ads/4513413)), so the subject still has to read.
3. **Font:** ultra-heavy rounded display face (Lilita/Luckiest Guy style), all caps. Use a dark outline of about 12–20% of font-size, plus a second coloured outline. Add a hard drop shadow offset down by about 6–8% of font-size. Our `Outline` kit already does this.
4. **Colour:** white or warm yellow fill (`fireCore`) on a dark ink stroke. Put the text over darkened sky or smoke (keep the gradient scrim). Never put yellow text over yellow fire.
5. **Placement:** top 45% of the frame, centred, 2 lines stacked. Keep everything out of the bottom 20% and away from the edges (≥ 5% margin). A slight −2° tilt is fine.
6. **Punctuation:** end on "!" for imperatives. "?" fits curiosity ("WHO'S INSIDE?"). Each line holds a whole phrase: "SAVE THE / PANDA!" is fine.
7. **Emoji:** none in the image. They render as small colour blobs and add no meaning. Keep 🚒 in the title.
8. Drop the second ribbon line ("PENGUIN FIREFIGHTERS") on the massive variant. It competes with the headline. The penguin already says it.

## 3. Image rules for AI generation

1. **One hero and one emotion.** At most 2 characters: rescuer + rescued. The 0.3% crowd scene against the 2.0% single panda is our own proof. A DevForum creator with 50 troops in frame got 0.2–0.4% ([thread](https://devforum.roblox.com/t/why-are-these-getting-such-a-low-ctr/4562817)).
2. **Close-up.** The hero's face takes ≥ 30% of frame height, with exaggerated emotion (scared rescued animal, determined or shocked penguin). Expressive faces lift thumbnail CTR by about 20–30% ([thumbnailtest](https://thumbnailtest.com/guides/face-in-youtube-thumbnail/)).
3. **A subject that contrasts with the fire.** The panda's black and white pops against orange. A penguin kid or a red truck in front of orange fire blends in. Put the hero's silhouette against the dark sky, blue water or smoke.
4. **Palette:** hot orange/yellow fire against cool blue/navy (water, night sky). Saturated, never muddy brown photo-grade ([Vizzbees](https://vizzbees.com/blog/how-to-make-a-roblox-thumbnail)).
5. **Motion:** freeze the peak moment (water hitting flame, a mid-run carry, a jump out of the door). Use a diagonal from bottom-left to top-right.
6. **Leave the top 40% as simple sky or smoke** for the headline. The hero sits in the lower-middle, between 20% and 80% of the height.
7. **Match the game.** Use real game screenshots or our penguin model renders as **reference images** (Gemini takes up to 5 character refs, [docs](https://ai.google.dev/gemini-api/docs/generate-content/image-generation)). Keep the red "67" helmet, the turnout coat and the chunky Roblox-like proportions. Expectation gaps raise CTR but kill click→play ([Playio](https://blog.playio.co/mobile-game-ad-ctr-benchmarks-2026)).
8. **The test:** shrink to 300x169. If you can't name the subject and read the words in one second, cut it.

**Prompt template** (Gemini has no negative-prompt field, so describe what you *want* ([guide](https://fuser.studio/articles/nano-banana-prompt-guide))):

> 16:9 cinematic 3D cartoon render in the style of the attached penguin firefighter reference (red helmet with gold "67" badge, black turnout coat with yellow reflective stripes, chunky toy-like proportions). Low camera angle, close-up: [HERO + ACTION + EMOTION], filling the lower-middle of the frame. Behind: [ONE fire setting], glowing orange flames, sparks. **The upper 40% of the image is clean dark night sky and soft smoke, empty and uncluttered, reserved for a headline.** Saturated orange fire against deep blue night, rim light on the hero. Plain surfaces with no signs, letters or writing anywhere. One subject only.

Generate 4 images, pick the cleanest top band, and overlay the text in Remotion. Never let Gemini draw the text (the "SC OOL" sign baked into `g-ad-02` shows why).

## 4. Testing playbook

- **Batch:** 10 creatives per campaign at $16+/day for ≥ 3 days. Stats lag about 3 days ([Tizyz, `owMnhg3fn_M.txt`](https://www.youtube.com/watch?v=owMnhg3fn_M)).
- **Each creative tests one variable** against the control (SAVE THE PANDA): a new hook, *or* the same hook with new art, *or* the same art with a new text size.
- **Read two numbers per thumbnail:**
  - **CTR** = clicks / impressions. It measures the hook.
  - **Click→play** = plays / clicks. It measures honesty and the match with the details page.
  - Then look at **cost per play**. A 3% CTR with 30% click→play loses to 2% CTR with 70%.
- **Kill:** after ≥ 3k impressions, cut any creative under 1.0% CTR, or with click→play under half the campaign average.
- **Scale:** at ≥ 2% CTR with healthy click→play, make 3 siblings (new art, tighter crop, different colour). Since the bandit starves losers, **launch new concepts in a fresh campaign** so they get fair impressions.
- **Close the loop:** make the experience page's first thumbnail match the best ad, so the click lands on the same promise. Stop ads once Home recommendation impressions pass sponsored impressions.

## 5. Ten concepts, in priority order

| # | Headline | Scene | Why |
|---|---|---|---|
| 1 | **SAVE THE PANDA!** (massive) | Same winner, closer: the panda's scared face plus the penguin's arms, 40% text block | It's the winner. This tests text size alone |
| 2 | **SAVE THE PUPPY!** | A scared golden puppy in the penguin's arms, burning house behind | Same proven pattern (cute animal, warm rescue), new animal |
| 3 | **PANDA IS TRAPPED!** | The panda waving from a burning window, the penguin's hose spraying up from the bottom-left | A panda sibling: curiosity plus the hero's hose |
| 4 | **PUT OUT THE FIRE!** | Over the shoulder: a fat blue water stream into an orange blaze, the penguin's determined face in profile | 1.8% runner-up. Blue against orange is the cleanest contrast |
| 5 | **AAAH! FIRE!** | The penguin's shocked face fills 50% of the frame, flames reflected in its eyes | The pure face-emotion test (it also works as an icon) |
| 6 | **DRIVE THE FIRE TRUCK!** | Low head-on shot of the red truck bursting toward camera, the penguin grinning at the wheel, against a blue dusk sky | 1.5% in cartoon. A 3D low angle with a blue background should lift it |
| 7 | **SAVE THE KITTY!** | A kitten on a burning roof edge, a ladder rising, the penguin reaching out | Another animal rescue. Height adds drama |
| 8 | **BE A FIREFIGHTER!** | Hero portrait: the penguin with its "67" helmet, the hose over its shoulder, the fire glowing behind | Tizyz's "core fantasy" line, said word for word |
| 9 | **WHO STARTED THE FIRE?** | Two penguins pointing at each other, soot on their faces, a small fire between them | Comedy plus co-op (our Blame system). Playful, nobody singled out |
| 10 | **NIGHT FIRE!** | A single glowing house on a navy night, a tiny truck light approaching, a big orange glow | Maximum contrast in a dark feed. Two words |

Avoid crowds, kids in peril (the policy risk and the 0.3% result), paid-only features like the helicopter pass as the main hook, and anything the game doesn't have.
