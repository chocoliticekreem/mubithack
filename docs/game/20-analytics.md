# 20 · Analytics: every event, stored

Roblox's Creator Dashboard (AnalyticsService funnels and custom events) is still fed exactly as before,
but it lags 1–2 days, caps names at 100 and fields at 3, and can't be queried freely. In-memory
`ForgeTelemetry` counters die with the server. So all analytics now go through **one server service,
`TrackService`**, which records every event to a durable store you can query.

## Architecture

```
 systems (signals / attrs)      FunnelService (Roblox funnels + custom events, unchanged)
          │                                  │ analytics() helper: + TrackService:Mirror(...)
          ▼                                  ▼
 ┌──────────────────────────── TrackService (ServerScriptService/Services) ────────────────────────────┐
 │ record(player?, name, props) → sanitize (Lib/Analytics/Schema) → add context                        │
 │   ├─ DailyAggregate  counts per event × device × UTC day → DataStore (always, live servers)         │
 │   ├─ Roblox          LogCustomEvent for the few Schema.Roblox events (per-server token bucket)      │
 │   └─ PostHogSink     memory buffer → POST /batch/ (≤100 events / 10 s, retry + backoff)              │
 │                          └─ undeliverable batches → MemoryStore queue → any server re-sends         │
 └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
          ▲  Analytics/Client remote (validated, rate-limited)
 AnalyticsController (client): popups opened/closed, client errors, sampled fps / ping
```

| File | Role |
|---|---|
| `game/ServerScriptService/Services/TrackService.luau` | the API, every watcher, session / mission state, loops, BindToClose |
| `game/ServerScriptService/Lib/Analytics/AnalyticsConfig.luau` | server-only knobs (no keys) |
| `game/ServerScriptService/Lib/Analytics/PostHogSink.luau` | batching, HTTP, retry, MemoryStore spill, dry run |
| `game/ServerScriptService/Lib/Analytics/DailyAggregate.luau` | daily counts in a DataStore |
| `game/ReplicatedStorage/Lib/Analytics/Schema.luau` | pure rules (spec: `game/tests/analytics.spec.luau`) |
| `game/StarterPlayerScripts/Controllers/AnalyticsController.luau` | client reports |

Other systems changed by one guarded call each: `FunnelService` (its single AnalyticsService helper mirrors
every call) and `MonetizationService` (ProcessReceipt reports a granted developer product). Everything else
is observed from signals and attributes that already exist, so no other system needs to know about analytics.

### API (server)

```lua
local Track = services.TrackService                 -- inside a service (nil-guard it)
Track:Event(player, "my_event", { key = "value", n = 3 })   -- player event
Track:Server("my_server_event", { ... })                    -- server event
```

Rules: `name` is snake_case `^[%a][%w_]*$` (≤ 48 chars); props are flat strings (≤ 200 chars),
numbers and booleans (≤ 40 keys). Never put a player name, chat or anything typed by a player in a prop.
Add a new name to `Schema.Events` and to the table below. Only add it to `Schema.Roblox` if it must be in
the Creator Dashboard (Roblox allows 100 custom event names per game; we use about 47).

### Limits respected

| Limit | How |
|---|---|
| Roblox: 100 custom event names, 3 custom fields, 8,000 field combinations | only `Schema.Roblox` events are forwarded (9 names), fields are constant sets; spec checks the total stays ≤ 80 |
| Roblox AnalyticsService throughput | token bucket, 120 + 20 × players per minute per server, shared with FunnelService's calls |
| HttpService: 500 requests / min / server | ≤ 1 POST per second (normally 1 per 10 s) |
| DataStore: 1 write / 6 s per key | aggregate keys are sharded (16) by JobId, written every 5 min |
| MemoryStore queue item ≤ 32 KB, memory quota | spill chunks ≤ 30 KB, expire after 6 h, add failures drop (counted) |
| Memory per server | 3,000 events buffered at most; overflow drops the newest (counter `analytics_dropped`) |

## Record shape (PostHog)

```json
{ "event": "mission_end", "timestamp": "2026-10-26T18:04:11Z", "uuid": "…",
  "properties": { "distinct_id": "123456789", "session_id": "GUID per join", "server_id": "<JobId>",
    "place_version": 412, "device": "Phone", "locale": "en-us", "schema": 1, "studio": false,
    "$lib": "forge-roblox", "…event props…": "…" } }
```

* `distinct_id` is the Roblox UserId (not PII under Roblox's rules; set `HashUserIds = true` in
  AnalyticsConfig to send a salted FNV hash instead). Server events use `server:<JobId>` and don't create
  persons. `uuid` makes PostHog drop a retried duplicate.
* `device`: Phone | Tablet | PC | Console | Unknown (OnboardingService's Device attr) or `server`.
* `session_start` also sets person properties (`$set`: device, locale, last_place_version;
  `$set_once`: first_device, first_place_version).

## Event schema

### Recorded by TrackService

| Event | Props | When |
|---|---|---|
| `server_start` | private_server, max_players, posthog (sink mode) | server boot |
| `server_heartbeat` | players, uptime_s, server_fps, heartbeat_ms, mem_mb, runs, events_total, buffered, dropped, errors_repeat | every 60 s |
| `server_counters` | every ForgeTelemetry counter that moved (name → delta), e.g. `moment_*`, `monetization_prompts`, `twist_rolled_cat` | every 300 s and on close |
| `server_close` | uptime_s, events_total, dropped | BindToClose |
| `session_start` | is_new, cohort (New / Returning / Unknown), locale, account_age_days, premium, referred, teleported, players_in_server, private_server | device + Onboarded known, or 15 s after join |
| `session_end` | seconds, minutes, is_new, cohort, missions, in_call, call_seconds, **last_screen**, **onboarding_step** ("n Name" of OnboardingV3), mission_step, spray_seconds, fires_out, bp_xp, level, hand, events | PlayerRemoving (= every quit) |
| `funnel_step` | funnel (Onboarding / OnboardingV3 / Mission), funnel_session, step, step_name, field1 (device), reason, rbx | every Roblox funnel step FunnelService logs |
| `mission_dispatch` | run, mission_id, squad_size, call_number, twist | InstanceId set |
| `mission_in_truck` | run, role (driver / passenger), seconds | first truck seat on the call |
| `mission_arrive` | run, mission_id, seconds, rode_truck, twist | the run's RoundState → Active |
| `mission_first_fire_out` | run, mission_id, seconds, seconds_on_scene | first fire you put out on the call |
| `mission_rescue` | run, kind, in_call | RescueService.Delivered |
| `mission_end` | run, mission_id, location, reason (time / allOut / forced), success, stars, seconds, arrival_seconds, fires_out_team, rescued_team, trapped, lost, burning_at_end, integrity, squad_size, rookie, rookie_win, new_record, twist, my_fires_out, my_rescues, my_spray_seconds, rode_truck | MissionService.MissionEnded |
| `mission_return` | run, mission_id, seconds, ended, abandoned | InstanceId back to "" |
| `tool_equip` | item (or "none"), prev, action (grab / swap / stow), in_call | InvHand changed (hose grab, swap, put away) |
| `purchase` | kind (pass / product), id, key, purchased, price, in_call, screen | pass prompt closed (bought or not); product granted |
| `bp_tier_up` | tier, premium | BattlePassService.TierUp |
| `bp_claim` | claimed, waiting | PassClaimable went down |
| `achievement` | id, xp | AchievementService.Unlocked |
| `level_up` | level | DataService.LevelUp |
| `player_downed` | cause, by_player, run | SquadService.Downed |
| `player_revived` | how, by_player | SquadService.Revived |
| `ui_open` | screen, in_call | a popup / panel opened (client watcher, `Schema.Screens`) |
| `ui_close` | screen, seconds, in_call | it closed (= shown → dismissed) |
| `perf` | fps, fps_low, fps_bucket, ping_ms, ping_bucket, server_ping_ms, mem_mb, quality, in_call, screen | every 120 s, 25 % of sessions |
| `error` | side (server / client), message, script, trace (player names scrubbed) | ScriptContext.Error; server ≤ 20 distinct / min, client ≤ 15 / session, deduplicated |

`Schema.Screens` (what `ui_open.screen` / `last_screen` can be): Achievements, BattlePassGui, DailyChest,
DispatchGui, GearLocker, GraphicsSettingsUI, OfferGui, Results, SocialAsk, StoreGui, TwistGui, UpdateLog,
ColdOpen, Onboarding, LobbyUI, FanfareGui, or `world`. A screen counts as open when its ScreenGui shows a
visible, opaque panel covering ≥ 10 % of the viewport (checked every second).

### Mirrored Roblox events

Every `LogCustomEvent` FunnelService makes is stored under **the same name** (so it matches the Creator
Dashboard), with `value`, `rbx = true` and the custom fields under readable names (`Schema.FieldLabels`):
FirstSpraySeconds, SessionMinutes, OnboardingQuitStep, TutorialSkipped, FirstCallDeclined,
ColdOpenSkipped, OnboardingV3QuitStep, UpdateLogShown, NotifyPrompted / Accepted, FavoritePrompted /
Accepted, **OfferShown / Clicked / Declined / Purchased, PassPurchased, LikeAskShown / Closed,
InviteAskShown / Prompted / Sent, TwistRolled / Completed, CallTime, PadWaitSeconds,
PadLeftBeforeLaunch, ResultsChoice, DailyChestOpened, DriveStart / Arrive / Quit, TruckReset,
TruckStuck, UnstuckApplied, NotifyAsk, ReturnGap (the Day-1 return proxy), RookiePackBought** (definitions:
`ReplicatedStorage/Lib/Onboarding/Funnel.luau`; retention ones: `docs/game/21-retention.md`).

### Forwarded to Roblox (Creator Dashboard → Analytics → Custom events)

SessionStart (device, cohort), MissionEnd (value seconds; device, reason, stars), ToolEquip (device, item),
PurchaseDone (value R$; device, kind, key), BattlePassTierUp (value tier; device), AchievementUnlocked
(device, id), UiOpen (device, screen), PerfSample (value fps; device, fps bucket, ping bucket),
ScriptError (device, side).

## Turning on PostHog

Without a key, a live server records aggregates and Roblox events only; the PostHog sink is off and
buffers nothing. In Studio it runs a **dry run** (prints each batch as `[Analytics] dry-run batch …`).

1. PostHog → Project settings → copy the **Project API key** (`phc_…`; it is write-only, the same token
   posthog-js ships in web pages). Note US or EU cloud.
2. Studio, the published place → Game Settings → Security → **Allow HTTP Requests: on** → Save.
3. Give the server the key, one of:
   * **Studio**: Explorer → ServerStorage → Properties → Attributes → `+` → name `PostHogKey`, type
     string, value `phc_…`. EU project: also `PostHogHost` = `https://eu.i.posthog.com`. Publish.
     ServerStorage never replicates to clients.
   * **No republish**: Studio command bar in the published place (API access to DataStores on):
     `game:GetService("DataStoreService"):GetDataStore("ForgeAnalyticsConfig"):SetAsync("posthog_key", "phc_…")`.
     Running servers pick it up within 5 minutes.
4. Check: the server log prints `[Analytics] PostHog sink: live -> https://us.i.posthog.com`; PostHog →
   Activity shows `server_start` / `session_start` within a minute.

Never commit the key. Why not the Creator Dashboard Secrets store? A Roblox `Secret` can only be placed
in a request's Url or headers, and PostHog's `/batch/` endpoint only accepts the token inside the JSON
body (checked: `?api_key=`, `?token=` and `Authorization: Bearer` are all rejected with 400).

Volume knobs (AnalyticsConfig): `SampleRate` (share of sessions sent to PostHog; aggregates still count
everyone), `PerfSampleRate` / `PerfSeconds`, `HeartbeatSeconds`, `CountersSeconds`. A typical session
sends ~40–80 events per hour, mostly `ui_*`, `tool_equip`, `funnel_step` and mission events.

## Querying

**PostHog** (SQL editor / insights), e.g. where new players quit:

```sql
select properties.onboarding_step as step, properties.last_screen as screen, count() as quits
from events
where event = 'session_end' and properties.is_new = true and timestamp > now() - interval 1 day
group by step, screen order by quits desc
```

Mission drop-off by device: funnel insight `mission_dispatch → mission_in_truck → mission_arrive →
mission_end → mission_return`, breakdown `device`. Offer conversion: `OfferShown → OfferClicked →
OfferPurchased`, breakdown `offer`. Errors: `error`, breakdown `message`.

**Daily aggregates** (no PostHog needed): DataStore `ForgeAnalyticsDaily_v1`, keys `<YYYY-MM-DD>/s0` …
`/s15`, each `{ v = 1, counts = { ["<event>|<device>"] = n } }`. Studio command bar (published place):

```lua
local ds = game:GetService("DataStoreService"):GetDataStore("ForgeAnalyticsDaily_v1")
local total = {}
for s = 0, 15 do
	local v = ds:GetAsync("2026-10-26/s" .. s)
	for k, n in (v and v.counts) or {} do total[k] = (total[k] or 0) + n end
end
for k, n in total do print(k, n) end
```

Or Open Cloud: `GET /datastores/v1/universes/{universeId}/standard-datastores/datastore/entries/entry?datastoreName=ForgeAnalyticsDaily_v1&entryKey=2026-10-26/s0`.

## Testing

* `game/tests/analytics.spec.luau` (pure rules).
* Studio: `ServerStorage.DevHook:Invoke("TrackService", "_recent", 30)` (last records), `"_state"`
  (sink mode, buffer, aggregate totals, sessions), `"_flush"` (send / print a batch now), `"_payloads"`
  (last batch bodies, key redacted), `"_rekey"` (re-read the key).
