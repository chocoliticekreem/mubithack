# 06 — Player data: profiles, XP, leaderboards

The game's "database" is Roblox DataStoreService. One versioned profile per player is held by
`DataService`, the only writer. Its pure logic lives in `Lib/Data/ProfileSchema` and is
spec-tested in `game/tests/data.spec.luau`. `LeaderboardService` shows weekly and all-time boards
on a physical board in the station lobby, and `ProfileController` draws the level and XP bar in the
lobby plus "+XP" popups.

| File | Side | Role |
|---|---|---|
| `ServerScriptService/Lib/Data/ProfileSchema.luau` | pure | schema, migrations, level curve, mission bookkeeping, session-lock decisions |
| `ServerScriptService/Services/DataService.luau` | server | load/lock/save, autosave, BindToClose, API, mission + rescue hooks |
| `ServerScriptService/Services/LeaderboardService.luau` | server | OrderedDataStores + the lobby SurfaceGui board |
| `StarterPlayerScripts/Controllers/ProfileController.luau` | client | lobby level badge + XP bar, "+XP" and LEVEL UP popups |
| `ReplicatedStorage/Config/DataConfig.luau` | both | every number: store names, timings, XP rewards, blame weights, cosmetics, board placement |
| `game/tests/data.spec.luau` | CI | 18 specs over ProfileSchema |

## Profile (schema v7)

```
version, xp (lifetime), level (derived from xp, stored for readers)
missions[missionId] = { played, won, bestStars, bestSeconds }    -- MissionCatalog ids
missionsPlayed, missionsWon, firesOut
rescued = { Civilian, Dog, Cat, Panda }                          -- from RescueService.Rescued
awards[awardId] = times earned
blamePoints                                                      -- see "Blame points"
cosmetics = { owned[id] = true, equipped = { helmet, hose } }    -- ids from DataConfig.Cosmetics
settings = { cameraShake, sensitivity, musicVolume, sfxVolume, showXpPopups, ... }  -- whitelisted
gear = { unlocked[id] = true, loadout = { id }, equipped = { hand, back, face } }  -- v3: GearService; equipped (ids, "" = empty) = the station LOCKER loadout, restored on spawn / rejoin (filled by reconcile, no version bump); loadout = legacy rack picks, unused
guides = { seen[missionId] = true }                              -- v4: first-time mission guide done (MissionGuideService)
donations = { robux, count, receipts = { PurchaseId } }         -- v5: Robux donated (MonetizationService; last 50 receipts)
pass = { season, xp, free = { tier }, premium = { tier }, equipped = { slot = id }, legacy, curve? }  -- v6: battle pass (BattlePassService)
gifts = { passes = { [key] = { by = UserId, at = unix } } }  -- v7: owner-gifted pass entitlements (AdminService :giftpass)
updates = { lastSeen, prompted, likeAsks }                       -- v8: WHAT'S NEW panel (UpdateLogService); likeAsks: SocialAskService
achievements = { stats = { name = n }, unlocked = { id = unix }, sites = { SiteId = true } }  -- v8, no bump: AchievementService
weekly = { week, rescues, blamePoints, missions }                -- reset when the week changes
meta = { created, lastSeen, sessions }
```

The value saved in the DataStore is an envelope, `{ data = Profile, lock = { jobId, expires } }`.

**Migrations.** `ProfileSchema.migrate(raw, now)` runs `MIGRATIONS[v]` (v → v+1) until the profile
is at `Version`, then runs `reconcile`, which fills missing keys, fixes wrong types and drops unknown
settings. A save from a **newer** schema is refused, and the player gets a temporary profile, so an
old server never overwrites it. To bump the schema, add `MIGRATIONS[Version]`, increment `Version`,
add a spec, and never edit an old migration. v1 was the draft shape: `petsRescued` was a single
number, cosmetics were a flat list, and there were no settings or weekly counters. v3 added `gear`.
v4 added `guides.seen`; the v3 -> v4 migration marks every mission you've already played as seen, so
veterans get the one-line tip instead of the full first-time guide.
v5 added `donations` (all-time R$ donated through developer products). Its `receipts` list keeps
ProcessReceipt idempotent even when the global purchase ledger write fails.
v6 added `pass`: the battle pass moved from its own `BattlePass_S1` store into the profile (session
lock, one save). BattlePassService imports the old store once per player in live games (`legacy`),
resets the pass when `season` changes, and keeps claims idempotent through
`ReplicatedStorage/Lib/BattlePass/PassRules` (specs: `game/tests/battlepass.spec.luau`).
`pass.curve` (added inside v6, no bump: a missing value means curve 1) names the XP curve the xp was
earned under. The pass grew from 20 tiers x 100 XP (curve 1) to 100 tiers on `BattlePassConfig.XpCurve`
(curve 2, the first 20 tiers unchanged). On profile load BattlePassService runs `PassRules.migrateCurve`
once: same tier, same fraction to the next one, so nobody loses a tier; claims are stored by tier number
and tiers 1-20 keep their rewards, so claimed rewards never move. Legacy store xp is curve-1 xp too.
v7 added `gifts.passes`: an owner's `:giftpass` (AdminService) stores an in-game entitlement that
MonetizationService treats exactly like owning the pass (`Pass_<Key>`, plus `PassGifted_<Key>` so the
store says GIFTED). It is not a Roblox game pass. Specs: `game/tests/admin.spec.luau`.
v8 added `updates`: `lastSeen` is the newest `Config/UpdateLog` version the player closed the WHAT'S
NEW panel for, `prompted` the version they were last offered the update-notification opt-in on
(UpdateLogService). Everyone migrates to "" so the newest update shows once.
`updates.likeAsks` (added inside v8, no bump: a missing value reads as 0) counts how often the "Having fun? 👍"
card was shown (SocialAskService; capped at 3 ever by `Lib/Social/AskRules`).
`achievements` (also inside v8, no bump: a missing table reads as empty) holds the achievement counters
(`Config/AchievementConfig.Stats`), the unlock time per achievement id and the SiteIds worked (EXPLORER).
AchievementService owns it; old profiles are seeded once from `missionsPlayed`, `firesOut`, `rescued` and the level.

## Session locking and saving

- **Load:** `UpdateAsync` runs `tryLock`. If the lock is free, ours, or expired, the server takes it
  (expires = now + `LockTtlSeconds`) and migrates. If another server holds an unexpired lock, the
  callback returns nil (no write) and the load retries with backoff (`RetryBaseSeconds · 2^n`, capped
  at `RetryMaxSeconds`) up to `LoadAttempts` times. If every attempt fails, the player plays on an
  unsaved profile with a toast, or is kicked when `KickOnLoadFail` is set.
- **Autosave** every `AutosaveSeconds` (60) refreshes the lock. **PlayerRemoving** and
  **BindToClose** save and release it. BindToClose waits up to `BindToCloseSeconds`.
- If a save finds that another server holds the lock, the session is marked lost and never writes
  again, which stops a stale server from overwriting newer data.
- Before each request, the server waits up to `BudgetWaitSeconds` for
  `GetRequestBudgetForRequestType(UpdateAsync)` (LeaderboardService does the same for
  SetIncrementSortedAsync and GetSortedAsync). Failed requests retry with backoff.
- `UpdateAsync` passes `{ userId }` so the key is tagged for GDPR erasure.

**Studio:** `DataConfig.UseMemoryInStudio = true` (the default) uses an in-memory store with the same
UpdateAsync contract. Profiles survive a rejoin within one playtest only. With it set to false the
real DataStore is probed, and you must enable **Game Settings → Security → Enable Studio Access to
API Services**. If access is off, the service warns and falls back to memory. Live servers always
use the real DataStore and fall back to memory (with a warning) only if `GetDataStore` itself fails.

## API (server, through `services.DataService`, nil-guarded)

```lua
DataService:GetProfile(player): Profile?                 -- the live table: read it, mutate only via Update
DataService:WaitForProfile(player, timeout?): Profile?
DataService:Update(player, fn: (Profile) -> ()): boolean
DataService:AddXp(player, amount, reason?): number       -- XP actually given
DataService:RecordMission(player, missionId, results: Types.ResultsPayload): MissionSummary?
DataService:Equip(player, slot: "helmet" | "hose", id): boolean
DataService:IsPersistent(): boolean
DataService.ProfileLoaded(player) / .XpGained(player, amount, reason) / .LevelUp(player, level)
DataService.MissionRecorded(player, missionId, summary) / .StatsChanged(player)
```

All signals use the pure `Shared/Signal`, never BindableEvents, so listeners see the live profile
and never a stale copy (the intofire bug).

**Hooks.** `MissionService.MissionEnded(instanceId, results)` records every player in
`results.stats` who is still in the server. The mission id comes from `results.missionId`, then
`GetMission(instanceId).missionId`, then `locationId`. `MissionService.RoundEnded(results)` does the
same for v1's single auto-round (payloads that have no `instanceId`). Each payload table is recorded
once. `RescueService.Rescued(player, _, kind)` adds to `rescued[kind]` and the weekly rescue count.

**Remotes** (namespace `Data`): `XpGained` S→C owner `(amount, reason, level, levelsGained)`;
`Equip` C→S `(slot, id)` 2/s; `Setting` C→S `(key, value)` 4/s, where the value is checked against
the `ProfileSchema.Settings` whitelist and clamped.

**Player attributes** (names in `DataConfig.Attr`; proposed for `Shared/Names`): `Level`,
`XpIntoLevel`, `XpForNext`, `XpTotal`, `HelmetCosmetic`, `HoseCosmetic`, `ProfileReady`. Other lanes
can read the cosmetic ids and look up colours in `DataConfig.Cosmetics`, for example for the hose
water colour or the helmet tint.

## XP, wins, blame points

- XP per mission (`DataConfig.Xp`): 25 for playing, +50 for a win, +20 per star, +15 per rescue,
  +40 per panda, +2 per fire put out, +10 per award, capped at 400.
- A mission counts as **won** when `stars >= WinStars` (2) and `reason ~= "forced"`. Best time is
  recorded only for wins.
- Level curve: going from level L to L+1 costs `100 + 50·(L−1)` XP, up to a maximum level of 99.
  Cosmetics unlock automatically at their `level`.
- **Blame points** (the funny leaderboard): `firesStarted·3 + downedOthers·5 + teammateSprayed·1`,
  plus 10 for each blame award (`Award.blame == true`) the player received.

## Leaderboards

Each leaderboard is an OrderedDataStore keyed by UserId, `<StorePrefix><stat>_all` and
`<StorePrefix><stat>_w<weekId>`, for the stats `rescues`, `blamePoints` and `missions`.
`weekId = floor((unix − 4 days) / 1 week)`, so weeks start Monday 00:00 UTC.

Scores are snapshotted on `StatsChanged`, `ProfileLoaded` and PlayerRemoving. Every
`RefreshSeconds` (120) the pending scores are flushed and the top `TopN` are read again. The board is
a SurfaceGui in the Station locker room, facing the spawn pads, and switches between THIS WEEK and
ALL TIME every `CycleSeconds`. It is parented into the Station location, so it is rebuilt whenever
`LocationBuilt("Station")` fires. In memory mode the boards are in memory too.

## Verifying

```bash
bash game/tests/run.sh                         # data.spec.luau: 18 specs
python3 game/tools/sync.py check --root game
```

During a playtest (Server datamodel):
`DevHook:Invoke("DataService", "_selftest")`, `("DataService", "_record", player, "house_fire", 3)`
(the client should show "+XP" and the bar should move), `("DataService", "_dump", player)`, and
`("LeaderboardService", "_refresh")`.
