# 21 · Retention: reasons to come back tomorrow

Date: 2026-10-28. Live data (7 days): Day-1 retention **1–2 %** (genre median 7.6 %), D7 0 %, payer
conversion 0 %, average playtime 5–7 min. Players mostly kids, mostly on phones.

Four pieces, all honest (Roblox policy, kid audience): no fake timers, no paid randomness, the real price
on every BUY, notifications only to players who opted in.

| Piece | Files | What the player sees |
|---|---|---|
| Remind-me opt-in | `Controllers/RetentionController`, `Services/RetentionService`, `Lib/Retention/RetentionRules`, `Config/RetentionConfig.Notify` | after a finished call, back at the station: **🔔 REMIND ME TOMORROW?** "We'll ping you when your DAY 2 CHEST 🎁 (+35 XP) is ready!" **YES, REMIND ME!** / **NOT NOW**. YES opens Roblox's own opt-in prompt |
| Next-day notification | `Services/RetentionService` (MemoryStore queue + Open Cloud) | "Your Day 2 chest is ready! 🎁" on their phone the next day (only if they opted in, 13+) |
| Come-back reasons | `ClientLib/ComeBack`, `ResultsController` (small), `RetentionController`, `ResultsFlowService` (attrs) | results: **⭐ NEXT: NEW HELMET AT LEVEL 3!** (32 px, was 24) + a **TOMORROW 🎁 +35 XP 🔥1 / DAY 2 CHEST** card bottom-right on calls without a chest; lobby: the same card top-left with the next unlock |
| ROOKIE PACK | `Services/RookiePackService`, `OfferService`, `MonetizationService` (receipt), `ClientLib/OfferCard`, `Config/RetentionConfig.RookiePack`, `BattlePassConfig` (2 rewards), `PassRules` (`extra`) | once, on the results of call 2: **ROOKIE PACK!** 2x XP 30 min + helmet + truck paint, **BUY R$ 49** / No thanks |

Screenshots (session scratchpad, not in git): `scratchpad/tycoon-shots/retention/` — `results-comeback.png`,
`results-rookie-pack.png`, `lobby-remind-ask.png`, `lobby-comeback-card.png` (750x381 phone-sized viewport,
touch UI forced).

## 1. The remind-me opt-in

* **When:** the first time the player is back at the station after a finished call (`InstanceId` goes from a
  run to ""), `Notify.AskDelay` (5 s) later; for returning players who said NOT NOW, 60 s after joining.
* **Gate:** `ClientLib/PopupGate` kind `notify` (modal, allowed in a new player's first session). Never
  during onboarding (dropped until `FirstCallDone`), one auto pop-up at a time, `Gap` (8 s) apart.
  `PopupGateRules.NewbieCap` went **1 → 2**: a new player's first session may show the remind-me ask *and*
  the like-ask (still never both at once). With D1 at 1–2 %, the ask that brings them back tomorrow has to
  happen in the first session.
* **Rules** (`RetentionRules.shouldAsk`, spec `game/tests/retention.spec.luau`): only if
  `ExperienceNotificationService:CanPromptOptInAsync()` is true (Roblox says no for under-13s, players who
  already opted in, and ineligible accounts), at most `MaxAsks` (2) ever, once a session, never after an
  accepted answer.
* **The answer:** Roblox never tells a game whether the player accepted. After `OptInPromptClosed`, the
  client asks `CanPromptOptInAsync` again: *can't prompt any more* = accepted (`RetentionRules.optInAnswer`).
  Saved in the profile (`retention.notify = { asks, answer, at }`, ProfileSchema v8, no bump).

## 2. Sending the notification: dashboard setup (do this once)

The game code is ready and **off** until step 4. Nothing secret is in git.

1. **Notification string.** Creator Dashboard → *Station 67* → **Engagement → Notifications** →
   **Create a Notification String**. Name: `daily_chest`. Text (≤ 99 chars), e.g.
   `Your Day {day} chest is ready! 🎁 Come put out some fires!` — `{day}` is the parameter the game sends
   (`parameters.day.string_value`). Save, then **copy the string's Asset ID** (a UUID).
2. **Open Cloud API key.** Creator Dashboard → **Open Cloud → API Keys → Create API Key**. Name
   `station67-notifications`. Access permissions: add API system **user-notification** → experience
   *Station 67* → operation **`user.user-notification:write`**. Security: accepted IP addresses `0.0.0.0/0`
   (Roblox game servers have no fixed IP). Save and copy the key (you see it once).
3. **Secret.** Creator Dashboard → *Station 67* → **Secrets** (Configure → Secrets) → **Create Secret**.
   Name **`OpenCloudNotify`** (must match `RetentionConfig.Notify.SecretName`), value = the API key,
   domain `apis.roblox.com`. The server reads it with `HttpService:GetSecret("OpenCloudNotify")`; a Secret can
   only be used in request headers / URLs, which is exactly how the game uses it (`x-api-key`).
4. **Turn it on.** Put the Asset ID from step 1 in
   `game/ReplicatedStorage/Config/RetentionConfig.luau` → `Notify.MessageId = "<uuid>"`, PR, publish.
5. **Game Settings → Security → Allow HTTP Requests: on** (already on for analytics).
6. **Check:** after a player who opted in leaves, the server log says
   `[RetentionService] <name>: queued day N chest for <unix> (in 20 h)`; the next day the counters
   `notify_sent` / `notify_send_failed` move (analytics `server_counters`). A missing secret logs
   `no secret "OpenCloudNotify" …` once per server.

How it is sent: when an opted-in player leaves, `{ due, day }` goes into the MemoryStore sorted map
`RetentionNotify_v1` (key = UserId, sort key = due). `due` = at least `MinHoursAfterLeave` (20) h after they left
**and** not before the next UTC day (the daily chest resets at 00:00 UTC). Every live server sweeps due
entries every 5 min (25 at a time), claims each (`UpdateAsync`), POSTs
`https://apis.roblox.com/cloud/v2/users/<userId>/notifications` with
`{ source.universe, payload { message_id, type "MOMENT", parameters.day }, join_experience.launch_data
"daily_chest", analytics_data.category "DailyChest" }` and removes it. Rejoining removes the entry. Entries
expire after `QueueDays` (3).

Limits to know: Roblox delivers to opted-in users only, **13+ for these personalised moments** (under-13s only
get experience-update notifications), at most **one notification per user per experience per day**, and the
experience needs 100+ visits. The queue only drains while at least one live server runs; at our traffic that is
nearly always, but an empty game sends nothing until the next server starts.

## 3. Come-back reasons on screen

* Server: `ResultsFlowService` now also writes Player attrs `DailyNextWhen` ("today" | "tomorrow"),
  `DailyNextDay`, `DailyNextXp`, `DailyNextCosmetic`, `DailyStreakNow` from `RetentionRules.chestPreview`
  (pure, spec'd) whenever the profile loads or a chest opens.
* `ClientLib/ComeBack` turns them into text and a card: `unlock()` (moved out of ResultsController: nearest level
  unlock, else the pass's next free tier), `chest()`, `streak()`, `card()`.
* Results: the NEXT line is 32 design px (≈ 14 px on a 667x375 phone; it was 24 → 11 px). On a call where the
  daily chest was already opened today, the chest's corner shows the TOMORROW card instead (text 26–44 px). On the
  first call of the day the chest card itself now says `TOMORROW: +35 XP`.
* Lobby: `RetentionController` puts the card in HudLayout's `Left` stack at x 143 (right of the chip column), only
  at the station and only after the first call.

## 4. ROOKIE PACK (R$ 49 developer product)

* **What you get** (fixed, no randomness): 2x mission XP for 30 minutes of **play** time (counts down only while
  in the game), the **Rookie Star Helmet** and **Rookie Blue Truck Paint** (BattlePassConfig rewards
  `helmet_rookie`, `paint_rookie`, owned through the pass's new `extra` set, equipped at once, kept across
  seasons).
* **When it is offered:** `OfferService`, results screen, once ever (`MaxShows` 1), on the player's 2nd finished
  call (lifetime `missionsPlayed >= AfterCalls`), in place of a pass offer, under the same `MaxPerSession` /
  `MinGapSeconds` caps; never on a rookie call, never before `FirstCallDone`. If the caps block it on call 2, the
  next results screen can show it. Card: ClientLib/OfferCard (name/icon/colour come with the offer).
* **ProductId = 0** (until the dashboard step below): never offered, never prompted, receipts never match.
* **Purchase:** `MonetizationService`'s ProcessReceipt (still the only one) routes the product to
  `RookiePackService:Apply`: idempotent per PurchaseId (global ledger + `retention.rookie.receipts`), sets
  `bought`, adds 1800 s of boost, grants + equips the cosmetics, toast. The XP bonus rides on
  `DataService.MissionRecorded` (same XP again, reason "Rookie Pack 2x XP").

**Dashboard setup:** Creator Dashboard → *Station 67* → **Monetization → Developer Products → Create**.
Name `ROOKIE PACK 🎒`, description and icon from `marketing/passes/rookie-pack.json` and
`marketing/passes/out/rookie-pack.png` (512x512, re-render: `python3 marketing/passes/render_rookie_pack.py`),
price **49**. Copy the product **ID** into `RetentionConfig.RookiePack.ProductId`, PR, publish.

## 5. Telemetry

| Event / counter | Where | Meaning |
|---|---|---|
| `NotifyAsk` (field shown / yes / no) | RetentionService | the remind-me card shown, YES, NOT NOW |
| `NotifyPrompted` / `NotifyAccepted` (field `retention`) | RetentionService | Roblox's prompt opened / opted in (proxy) |
| counters `notify_ask_*`, `notify_optin_accepted/declined`, `notify_queued`, `notify_sent`, `notify_send_failed` | RetentionService | |
| `ReturnGap` (value days; F1 device, F2 first / same_day / next_day / d2_6 / d7plus, F3 install age d0 / d1 / d2_6 / d7plus) | RetentionService, every join | **D1 proxy: `F2 = next_day` and `F3 = d1`**, from profile `retention.lastJoinDay` (UTC day) |
| counters `return_<bucket>` | RetentionService | |
| `OfferShown` / `OfferClicked` / `OfferDeclined` (field `RookiePack_results`) | OfferService | ROOKIE PACK shown / BUY / No thanks |
| `RookiePackBought` (value R$; field offer / other) | RookiePackService | bought (offer = within 10 min of its BUY) |
| counters `rookie_pack_prompted`, `rookie_pack_bought`, `rookie_pack_bonus_xp` | RookiePackService | |
| `purchase` (key `rookie_pack`) | TrackService.Receipt | the granted product |

All new FunnelService names are in `Lib/Onboarding/Funnel.Events` (the analytics spec keeps the total ≤ 80).

## Verified

In a local place (`scratchpad/Retention.rbxlx`, 750x381 viewport, touch forced), Studio play, ForgeProbe
**0 errors**:

* first call (tutorial skipped with the FirstFire DevHooks), call ended `allOut`: daily chest day 1 → attrs
  `DailyNextWhen=tomorrow DailyNextDay=2 DailyNextXp=35 DailyStreakNow=1`; results showed the bigger NEXT line and
  the TOMORROW card (`results-comeback.png`).
* back at the station: PopupGate log `show notify`, the REMIND ME card opened (`lobby-remind-ask.png`; Studio's
  `CanPromptOptInAsync` answered true); `yes` + `closed(false)` → profile `notify.answer = "accepted"`, asks 1;
  `_queue` → "sending off (Notify.MessageId empty)" (correct until the dashboard step); `_payload` = the JSON above.
* ROOKIE PACK receipt through the real ProcessReceipt flow (`MonetizationService._fakeRookieReceipt`, stand-in
  product id 1), twice with the same PurchaseId: applied once (`receipts ["rk-1"]`), `boostLeft 1800`, pass
  `equipped helmet_rookie / paint_rookie`, the truck turned blue (`lobby-comeback-card.png`); the next call's XP
  got `rookie_pack_bonus_xp` on top; no donation recorded.
* ROOKIE PACK card on the results (`OfferService._offer(p, "results", "rookie")`, `results-rookie-pack.png`).
* `return_first 1` on a fresh profile.

Code-only (can't be done in Studio): Roblox's real opt-in prompt and its answer, the Open Cloud send (needs the
secret + a published place), the real developer-product prompt (needs the product id), the multi-day return.

## Next

* The rookie items aren't listed in the battle pass panel (it lists tiers); if a player unequips them they can't
  re-equip yet. Add an "EXTRAS" row there.
* Use `Player:GetJoinData().LaunchData == "daily_chest"` to log notification-driven joins.
