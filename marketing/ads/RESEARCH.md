# Ad creative research: STATION 67, Flame and Blame

Researched 24 Oct 2026. Every factual claim links to its source. **[UNVERIFIED]** marks numbers that come
from a third party rather than Roblox. The reference images were pulled from the public Roblox thumbnail
API and the Steam CDN and looked at directly (not saved in the repo).

---

## 1. Roblox ad specs (2025-2026)

### What a game creator can buy
| Placement | Where it shows | Creative asset it uses | Who buys it |
|---|---|---|---|
| **Sponsored experience** | Home (Sponsored sort, and in tests inside Recommended For You) | A **16:9 thumbnail**. You can upload up to 10 per campaign; they're spread evenly across players ([Ads Manager docs](https://create.roblox.com/docs/production/promotion/ads-manager)) | Self-serve in Ads Manager |
| **Search ad** | Search results | The same campaign and thumbnails. "Your ad campaign is automatically shown on both the Home page and in search results" ([docs](https://create.roblox.com/docs/production/promotion/ads-manager)). Classic search ads let you bid on up to 10 keywords ([Gupta Media](https://www.guptamedia.com/insights/roblox-advertising)) | Self-serve |
| **Portal ad** | Inside publishers' games: an image above a door that teleports players to the advertised game | An image plus the door ([immersive ads](https://create.roblox.com/docs/production/monetization/immersive-ads)) | Classic Ads Manager flow only ([DevForum, Mar 2025](https://devforum.roblox.com/t/leveling-up-ads-manager-with-new-features/3587640)) |
| **Image billboard** | In 3D space inside publishers' games, not clickable | A static image. Its "aspect ratio... scales with the face of the block" ([immersive ads](https://create.roblox.com/docs/production/monetization/immersive-ads)) | Advertiser |
| **Video billboard and rewarded video** | Inside publishers' games | Video. Billboards run "up to 30 seconds", either click-to-play or autoplay with the sound off ([immersive ads](https://create.roblox.com/docs/production/monetization/immersive-ads)). Rewarded video is full screen and runs "6 to 30 seconds" ([rewarded video docs](https://create.roblox.com/docs/production/promotion/rewarded-video-ads)) | Mostly brands and programmatic buyers ([Roblox newsroom, Jan 2026](https://about.roblox.com/newsroom/2026/01/roblox-expands-advertising-platform)) |
| **Homepage Feature** | The main entry point. A brand video that turns into a 3D experience when clicked | Video | Closed beta, CPM-based ([newsroom](https://about.roblox.com/newsroom/2026/01/roblox-expands-advertising-platform)) |

**For us, the sponsored tile is the 16:9 Home thumbnail.** In March 2025 sponsored experiences moved from a
1:1 unit to 16:9, which "improv[ed] play through rate by up to 40%" ([DevForum](https://devforum.roblox.com/t/leveling-up-ads-manager-with-new-features/3587640)).
The **512x512 icon** is not the sponsored creative. It still appears in other Home sections ([icons docs](https://create.roblox.com/docs/production/publishing/experience-icons)).

### Image specs
- **Thumbnail and sponsored creative:** 16:9, **ideally 1920x1080**. Allowed formats are .jpg, .gif, .png, .tga and .bmp. Keep each file **under 3 MB** ([thumbnails docs](https://create.roblox.com/docs/production/publishing/thumbnails)). Images in any other ratio are "automatically resized" or "stretched to 16:9" ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager), [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)). **Always export at exactly 16:9.**
- **Icon:** square, **512x512**. It "scale[s] down to smaller sizes like 150x150", so check how it reads at that size ([icons docs](https://create.roblox.com/docs/production/publishing/experience-icons)).
- **Ads Manager image ads (general):** PNG or JPEG, 16:9, minimum width 500 px, **max 30 MB** ([Gupta Media](https://www.guptamedia.com/insights/roblox-advertising)) **[UNVERIFIED]**. Roblox's own pages give no cap. Use the 3 MB thumbnail limit as the safe target.
- **Counts:** up to 10 creatives per campaign ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager)). This was 5 at the March 2025 launch ([DevForum](https://devforum.roblox.com/t/leveling-up-ads-manager-with-new-features/3587640)). Each game page holds up to 10 thumbnails. Thumbnail personalization rotates 2 to 5 of them ([thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)).
- **Moderation:** every upload is moderated, "typically completed within 48 hours". Ads Manager also has an **AI generate** option that makes 3 variations from a text prompt ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager)).

### Video specs
- **Ads Manager video ads:** MP4 or MOV, **15 to 30 s**, **max 100 MB**, **16:9**, 720p to 1080p, minimum width 720 px. They can autoplay or be click-to-play, can be rewarded, and also serve on "Clip It" ([Gupta Media](https://www.guptamedia.com/insights/roblox-advertising)) **[UNVERIFIED: third party]**. Roblox's docs confirm a 30 s cap for billboard video and 6 to 30 s for rewarded video ([immersive ads](https://create.roblox.com/docs/production/monetization/immersive-ads), [rewarded](https://create.roblox.com/docs/production/promotion/rewarded-video-ads)). Nothing official mentions 9:16 or 1:1.
- **Video *thumbnails*** (game page and Home): 3 uploads a month. They don't play on Xbox, PlayStation or VR. They must be authentic gameplay. No voice-over, narration or music with lyrics; music from the Roblox catalog is fine. No real-life footage. No mechanics or UI the game doesn't actually have ([thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)).

### Safe zones and cropping
- Roblox says: "avoid placing any essential text or elements at the **bottom** of the thumbnail, as it may potentially be covered by metadata like the player count" ([thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)).
- Keep the important parts of the icon away from the corners so they don't get clipped. Make sure it reads at 150x150 ([Generalist Programmer](https://generalistprogrammer.com/tutorials/how-to-make-a-roblox-game-icon)). Roblox gives no exact rounded-corner radius **[UNVERIFIED]**.
- **Our working rule** (our own convention, not a Roblox spec): keep text and faces inside the central ~80% width by ~75% height, with nothing important in the bottom 20%.

### Content rules (Advertising Standards, updated 22 Oct 2026)
Source: [Advertising Standards](https://en.help.roblox.com/hc/en-us/articles/13722260778260-Advertising-Standards). New policy took effect 4 May 2026 ([DevForum](https://devforum.roblox.com/t/new-advertising-policies-standards/4527365)).
- **No deceptive or unrealistic claims**, "including offering free Robux to entice engagement."
- **No fake UI:** creatives "must not mimic system functionality or... replicate buttons, notifications, or options that are non-functional." That rules out fake Play buttons, red notification badges and fake progress bars.
- **Rules for under-18 audiences:** don't show people in unsafe situations. Where an activity "would normally require safety equipment... it must be depicted", so **our firefighters always wear their helmets**. Don't imply the product gives "status, or popularity". Don't directly urge kids to buy or ask their parents. Don't say "only" or "just" about a price.
- **No URLs, partial links or QR codes**, and nothing that sends players off Roblox. The only social platforms you may point to are YouTube, Twitch, Facebook, Instagram, Snapchat, Discord and X.
- **No bullying or ridicule:** no "singling out a user or group for ridicule". No profanity, including disguised spellings.
- **No real tragedies:** don't depict "specific real-world tragic events" or natural disasters. Fires must be fictional and cartoonish, never a real incident.
- **No extreme violence or gore. No promoting real-world explosives or fireworks**, and no "dangerous misuse of fireworks".
- **English only** for self-serve creatives. Other languages may be rejected.
- **No under-18 personalization:** "Ads may not be personalized for users under the age of 18."
- **Thumbnail text** (the rule that applies to our sponsored creatives): "Overlay text sparingly and only to describe gameplay... Do not include any text... that is an advertisement, promotion, or subjective claim, e.g. '50% off' or 'Free UGC!'" ([thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)). So **"#1 FIRE GAME" and "BEST CO-OP" are out.** Questions and gameplay statements are fine.
- **Originality:** campaigns for games whose metadata or place files "closely resemble existing games" may get "no ad spend and no conversions" ([Ads Manager](https://create.roblox.com/docs/production/promotion/ads-manager)).

---

## 2. What makes top Roblox thumbnails work

**Roblox's own guidance**
- Use **relevant, unique imagery** of what players will actually do, and express **theme and colour** ([thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails), [icons](https://create.roblox.com/docs/production/publishing/experience-icons)).
- **Thumbnail personalization** (Nov 2024) uses a multi-armed bandit across 2 to 5 active thumbnails. Average qualified play-through rate rose **+8.5%**, with some games reaching +50%. It works best above 1,000 DAU. Keep several thumbnails active, and refresh them with each major update ([DevForum](https://devforum.roblox.com/t/live-now-personalize-your-thumbnails-to-attract-more-users/3257233), [docs](https://create.roblox.com/docs/production/publishing/thumbnails)).

**Creator guidance on CTR:** use one focal point (a character mid-action, one object, one emotion). Use saturated, high-contrast colour, because "muted, realistic palettes disappear". Use a few big words or none. Shrink to 150x150 and simplify until it still reads ([Generalist Programmer](https://generalistprogrammer.com/tutorials/how-to-make-a-roblox-game-icon), [Vizzbees](https://vizzbees.com/blog/how-to-make-a-roblox-thumbnail)).

**What the current top games actually show** (live icons and thumbnails from the Roblox thumbnail API; player counts (CCU) from [games.roblox.com/v1/games](https://games.roblox.com/v1/games?universeIds=1686885941,10767634248), 24 Oct 2026; described rather than copied):
| Game | Pattern |
|---|---|
| Brookhaven (~625k CCU) | A character holding a pumpkin and winking, framed by open white doors like a window into the world. A red ribbon carries the logo, and the icon matches the thumbnail exactly. **Seasonal reskin + one face.** |
| Blox Fruits | Anime-style hero and boss clash, with an energy blast at the centre. Strong purple/blue against white light, logo bottom-right. **Action moment, rivalry.** |
| Dress to Impress | Icon is just an hourglass and "2 HOURS" in white on purple. The thumbnail is a glamorous character with "Halloween UPDATE". **Event countdown = curiosity and urgency.** |
| Grow a Garden | Icon is an hourglass with "12 HOURS". The thumbnail shows a huge rainbow number "$95,643,734,647" over an exploding yellow block burst. **Big number + countdown.** |
| Emergency Hamburg | A masked character escapes on a motorbike with a police car behind. Cinematic night lighting, version badge "V3.16" on the icon. **Chase moment, update tag.** |
| ER:LC | Police character with a K9 dog, or jet-ski chaos. Shield logo top-right. **Character plus companion, fun over realism.** |
| Firefighting Sim (~16k CCU) | **First-person nozzle** spraying water into a burning house with the fire truck beside it. A second thumbnail shows a ladder truck at a burning apartment block at sunset. Orange fire against blue water and red truck. The icon is the same first-person nozzle shot, with no text. |
| Firefighters! (~1.7k CCU) | Burning tower block, ladder truck, first-person hose. The icon is a close-up of a firefighter in a gas mask and helmet, with no text. |
| Fire Response: Kenterbury | The icon is the word "FIRE" with a flame for the letter I, over a UK fire engine. |

Takeaways: (1) icon and thumbnail share one character or motif; (2) a live event or countdown beats evergreen
art on the top games; (3) every firefighter game uses the same realistic burning building plus truck plus hose,
so **a goofy character face is open space for us.**

---

## 3. Steam firefighting store art (inspiration only, we do not copy)

> We study composition only. We do **not** reuse any of their art, logos, fonts, characters or text.

Looked at: header 460x215 and library 600x900 capsules (Steam CDN).
- **Firefighting Simulator: The Squad** ([store](https://store.steampowered.com/app/420560/)): a realistic crew walks away from the camera toward a ladder truck and a burning city block. A shield-style logo with a helmet sits top-left. Palette is yellow turnout gear, red truck, orange fire. **Feels heroic and team-like.**
- **Embr** ([store](https://store.steampowered.com/app/1062830/)): **the closest to our tone.** Cartoon firefighters with huge expressive faces burst diagonally out of a flame frame, with a hose spraying blue toward the viewer. A chunky rounded logo with a cheeky ember mascot. Fire is a stylised orange border around a deep purple/navy centre. **Shows comedy, chaos and co-op in one diagonal.**
- **Flashing Lights** ([store](https://store.steampowered.com/app/605740/)): just the logo. A shield with a red/blue lightbar, red flame on the left and shattered glass on the right. **A brand mark on a split-colour mood.**
- **Rescue HQ** ([store](https://store.steampowered.com/app/809720/)): an isometric cut-away base with a big blue siren logo. **"Look at all this stuff to manage."**
- **Firefighting Simulator: Ignite** ([store](https://store.steampowered.com/app/1669480/)): photoreal firefighters lit by the fire behind them. Thin, clean white logo with a firefighter silhouette. **Premium realism, low saturation.**

Patterns: logo in a top corner, hot orange against a cool blue or purple accent, one diagonal of action, and
character faces only in the comedic title (Embr).

---

## 4. Extracted patterns become our rules

1. **One focal point.** One penguin face *or* one dramatic event per creative. Never both at the same size.
2. **Big faces with exaggerated expressions.** Googly eyes as wide as they go, beak open in panic or a grin. This is our differentiator, since every competitor shows realistic or faceless firefighters. The face takes ≥30% of frame height.
3. **Colour.** Hot orange and yellow fire against a cool blue (water, night sky) or a purple background. Our red numbered helmet must stand out from the fire, so outline it or set it against blue. Saturated, never muddy.
4. **Text.** **≤5 words**, a heavy rounded font, white with a dark outline. Gameplay or questions only. No superlatives, Robux, "FREE", or prices.
5. **An action moment.** Freeze the peak frame: the explosion flash, the jump, water hitting fire.
6. **Diagonal composition** (the Embr and Blox Fruits pattern): action runs from bottom-left to top-right.
7. **Numbers and scale** (Grow a Garden): "8 PLAYERS", "15 MISSIONS", a helmet number "67". These are facts, so they're allowed.
8. **Curiosity and before/after.** A calm scene against chaos, or a cat in a tree with a bewildered penguin. Before/after is fine for fire, but never for bodies (that's banned).
9. **Seasonal or event reskins.** Swap thumbnails with each update and keep 3 to 5 active for personalization.
10. **Icon and thumbnail share a motif.** The icon is a penguin close-up in its red "67" helmet. The thumbnails reuse that penguin.
11. **Authentic.** Everything must exist in the game. Studio freecam shots are OK, painted-over fake features are not.
12. **Safe zones.** Nothing important in the bottom 20%, and keep the logo away from the edges.

### Pre-upload checklist
- [ ] 1920x1080 exactly (16:9), PNG/JPG, < 3 MB; icon 512x512
- [ ] Readable as a ~300 px wide tile *and* the icon reads at 150x150
- [ ] Single focal point; face ≥30% height or event dominates
- [ ] ≤5 words of text, no claims ("best", "#1"), no Robux/free/price, no "only/just"
- [ ] No fake buttons, badges, cursors, progress bars or system UI
- [ ] Nothing important in the bottom 20% or touching the edges
- [ ] Helmets on every firefighter, nobody shown in real danger, no gore
- [ ] No URL, QR code or off-platform reference, English only
- [ ] Shows real in-game content (mission, character or reward that exists)
- [ ] Doesn't reference a real fire, disaster or brand; no other games' art
- [ ] Part of a 3 to 5 variant set for personalization, each testing one hook

---

## 5. Hooks mapped to our game

| # | Hook (on-image text) | Visual | Pattern tested |
|---|---|---|---|
| 1 | **CAN YOU SAVE THEM ALL?** | Penguin in its "67" helmet looking up at a burning house with residents waving from windows | Curiosity question / challenge |
| 2 | **GAS STATION BOOM!** | A tanker exploding behind three penguins diving toward camera | Action peak, explosion spectacle |
| 3 | **YOUR FRIENDS WILL BLAME YOU** | Penguin squad all pointing at one soot-covered penguin | Social and co-op humour. *Risk: "ridicule" rule. Keep it obviously playful, and fall back to "WHO STARTED THE FIRE?"* |
| 4 | **ROOFTOP RESCUE** | Skyscraper roof, a ladder or helicopter edge, the city far below | Scale and height drama |
| 5 | *(no text)* | Extreme close-up: googly eyes, red "67" helmet, flames reflected | Pure face; also the icon test |
| 6 | **8 PLAYER CHAOS** | Eight penguins, tangled hoses, water everywhere | Number plus co-op mess |
| 7 | **BACKDRAFT!** | A door blowing open in a fireball, penguin flying backwards | Single-word shock and action |
| 8 | **SAVE THE CAT!** | Cat calmly on a branch, penguin stuck in the tree, ladder too short | Curiosity and comedy |
| 9 | **EARN THE CHIEF HELMET** | Gold Fire Chief helmet glowing on a pedestal, penguins reaching for it | Reward and progression. *Keep it "earn" (gameplay), never "buy". Don't imply status or popularity to under-18s.* |
| 10 | **15 MISSIONS** | A 3-panel split: house, skyscraper, tanker | Numbers / variety (before/after style split) |

First test set for personalization (3 to 5 active): #1 (question), #5 (face), #2 (action), #8 (comedy). This tests
the four main patterns against each other.
