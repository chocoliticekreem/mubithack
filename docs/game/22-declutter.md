# 22. HUD declutter + HIDE UI

Date: 2026-10-28. Feedback on a live PC screenshot: "holy so much ui jesus, also have a button to hide ui".
At the station a returning player saw about 28 HUD pieces at once: top bar, a big TODAY chest card with a
NEXT unlock line, a 6-chip column (PASS / NEWS / INVITE / TROPHIES / HELP / ADMIN), a big centred 911 card
with ACCEPT / DECLINE / NO CALLS, another squad's 1:26 call timer, an "R 28m" rescue arrow, a HEAT gauge, a
squad list of everyone in the lobby and a round HELI button sitting on it.

## What changed

| Piece | Now | Code |
|---|---|---|
| 👁 HIDE UI | A small eye in the Roblox top-bar row, right after Roblox's buttons (the level box moves over). Toggles the whole game HUD. While hidden only a small see-through 👁 stays. Movement stays (Roblox's stick and jump; our touch buttons while seated in the truck or heli). Never hidden: results, cold open, modal menus (STORE, LOCKER, big map, REMIND ME), screen effects. A menu opening by its key brings the HUD back. Lasts the session (Player attr `HudHidden`) | `Controllers/HideUiController`, `ClientLib/HudGate.setHidden`, `HudRevealController` (holds each HUD gui's `Enabled`), `Config/HudConfig` |
| Chip column | One **☰ MENU** chip on the left edge's middle, with a red dot when a chip inside has a badge. It opens a grid panel (2 columns, then 3 from 5 chips) with PASS, NEWS, INVITE, TROPHIES, HELP, ADMIN and HELI. When only one chip is available (a new player's HELP) it shows alone. Keys [P] [H] [;] [U] work as before | `ClientLib/ChipMenu` (`HudLayout.add("Chips")` lands there), `Lib/HudRules` |
| TODAY chest card | A pill, `🎁 DAY 3: +75 XP` (or `🎁 TOMORROW: +35 XP`), top-left, station only. New content opens the full card for 5 s (`HudConfig.PillSeconds`). Tap the pill to open it, tap the card to fold it. The NEXT unlock line left the HUD: the PASS panel's Next line and the results screen show it | `RetentionController` |
| 911 card | Small, top-right under the minimap. One line (`TRASH FIRE · 70 m`, yellow edge for a small job) plus ACCEPT, DECLINE and `...`, which opens the DISPATCH list with CALLS ON / OFF. NO CALLS left the card. It no longer sits in the top-centre stack, so it can't overlap the timer | `DispatchController` |
| Call timer, markers, heat, "on a call" busy | Only on your own call. In the lobby, Workspace's RoundState / RoundEndsAt are a summary of somebody else's run | `HudController` (`HudRules.timerShown`) |
| Squad strip | One 28-unit line per player (badge, name, status). Shows only on a call with 2 or more players. The lobby is not a squad | `HudController` (`HudRules.squadShown`) |
| HELI | A 🚁 HELI chip in the ☰ menu instead of a round button on the squad strip | `HeliController` |
| (bug) | `HudLayout`'s celebration queue called `popupGate` before it was declared, so every card ended with an error | `HudLayout` |

## Controls

| Device | Hide / show the HUD | Menu |
|---|---|---|
| PC | **F1** (also **`**). The 👁 shows a small F1 tag | click ☰ MENU, or the chip keys [P] [H] [;] [U] |
| Touch | tap 👁 (top left) | tap ☰ MENU, tap outside to close |
| Gamepad | D-pad left (HUD buttons; when hidden it lands on 👁), A | D-pad left reaches ☰; when it opens, the cursor is on the first chip and B closes it |

HELP lists both (`EVERYWHERE ELSE`). `PromptConfig` notes F1 / ` as taken.

## Checked

In a local place (`scratchpad/Declutter.rbxlx`, Studio iPhone emulator, 750x381 viewport), with a returning
player (level 13, pass tier 52, day 3 chest), Workspace round Active (another squad) and a dispatch offer:

| | Before | After |
|---|---|---|
| Phone (touch), HUD pieces drawn | 28 | 18 (incl. the onboarding card and its arrow, which skip-in-Studio leaves up) |
| Hidden (👁) | n/a | 1 (the 👁) |

- F1 and ` toggle it (keyboard input via MCP). Gamepad: D-pad left lands on DISPATCH normally and on 👁 when
  hidden. Opening ☰ puts the cursor on PASS, and B closes it. A tap on 👁 runs the same toggle as the
  `HideUiTest` hook. Studio MCP mouse clicks can't reach the top-bar row (STORE fails the same way), so the
  actual tap is code only.
- On a call (InstanceId set): the timer shows and the squad strip stays hidden solo. ForgeProbe: 0 errors.
- Not checked at 1920x1080: Studio was locked to the phone emulator. Everything is laid out in UiKit's
  1280x720 design units, so a PC screen scales the same layout up. Not checked on a real phone or console.
