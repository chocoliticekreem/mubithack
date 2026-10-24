# Roblox AI tools: market map

Source: **[O]** RoCode's comparison page, https://www.rocode.app/roblox-ai-plugin-alternatives (title "Best AI Tools for Roblox Studio (2026): 23 Options Compared", "Updated 23 October 2026", "RoCode publishes this page and is one of the tools in it"). Raw text: `teardowns/rocode/pages/roblox-ai-plugin-alternatives.txt`. Fetched 2026-10-24. The task brief said 19; the live page now lists 23 options. Every row below is RoCode's claim about a competitor (vendor-written, so biased), and is marked **[O]** for "observed on that page". Nilo is not on the page and was added from our own teardown.

## By where it runs

### Inside Studio: third-party agents (direct Forge competitors)
| Tool | Connects via | One-line differentiator | Price/free |
|---|---|---|---|
| **RoCode** | Own plugin + web chat (WebSocket relay) | Free daily credits, undo point per batch, compile check, 30 s playtest + test robot, edit-mode look check, UI kits, themed islands | 1 credit/day free; $9.99–$29.99/mo |
| **Ropilot** | Desktop app (Win/mac/Linux) installs a plugin | Playtests with simulated input + screenshots; **Blender-driven 3D models and animations**; can use your ChatGPT or Claude plan | Starter credits or 500 actions/mo BYO-plan; Plus $20/mo, packs from $8 |
| **Forge / ForgeBlox** (forgeblox.app, **not us**) | Windows Bridge → Studio's built-in MCP server | Playtests and shows a screenshot before "done"; price multiplier shown per message; prepaid credits that never renew | Trial credits; packs from $10 (1¢/credit), membership $19/$49 |
| **RoGenie** | Plugin in plugins folder, 6-digit pairing | Widest tool list (59 tools), 60+ models + BYO keys; plays as a real player with screenshots and **profiles performance**; Windows companion for meshes/materials/textures | 250K tokens/5 h, 2M/mo free; $5–$99/mo |
| **Craftly** | Creator Store plugin | Reads the place first, lints scripts, scans for common Roblox mistakes, **one-click undo of a whole build** | 40 credits once; Pro $14.99, Ultra $29.99 |
| **Kiwari** | Desktop app (macOS only for now) | **Approve each change**, plans first, **parallel subagents**, playtests, generates meshes and textures | Lite free on a basic model; Pro $19.99/mo |
| **RoAgent** | Windows app + bundled plugin | Runs on your Claude or ChatGPT subscription; billed per action (1 tool call; a feature ≈ 80) | 250 actions/mo free; $10/$35/$75 |
| **HyperDevs** | Windows app (open beta) | BYO Gemini/Claude/OpenAI/z.ai key or **local Ollama**, free and unlimited on its side | Hyper 30 model free daily tier |
| **Picoo** | Not covered | Fixed monthly credits, no free tier | Pro $19/mo ($12 yearly), 200 credits |
| **Rebirth** | Studio plugin | Simplest unit: 1 credit = 1 prompt | 5 free; $8.99/$15.99/$29.99 |
| **Ropanion** | Creator Store plugin | Free built-in models for prototyping/learning; listing says **not being updated** | Free |
| **RoAI** (roai.studio) | Web "Live Game Editor" + plugin | **Approve a plan with a credit estimate before building**; Light/Standard/Deep runs (~20/70/300 credits) | Chat and plans free; builds from £12/mo |
| **RoAssistant** (roassistant.me) | Plugin + web app with Explorer view | Inserts Toolbox models; one-off packs, no subscription; sign-in was **switched off** on 10–11 Oct 2026 | From $4.99 / 850 credits |
| **RoStudio** (rostud.io) | Web app + plugin that **syncs scripts, hierarchy and properties to its servers** | **Templates** (M1 combat, run system); planning mode on paid plans | 5 credits/day free; $7.99/$19.99 |
| **Lemonade** (lemonade.gg) | Roblox sign-in, prompt on its site, free plugin, two-way sync | Starts a game from a prompt (farm, pet, survival); no public prices | Paid tier, no refunds |
| **SuperbulletAI** | Desktop app (Win/mac) + **Rojo project on disk** | File-first: Rojo syncs into Studio; imports existing places | 1M tokens/mo free; Pro $20/11M tokens |

### Built into or through Roblox's own tooling
| Tool | One-line differentiator |
|---|---|
| **Roblox Assistant** (built in) | Free, edits scripts and objects, runs Luau, playtests, simulates input, inserts Creator Store assets, generates meshes, materials and procedural models (50 per 24 h), Planning Mode, screen-capture subagent, BYO Anthropic/OpenAI/Gemini key |
| **Studio MCP server + your client** | Claude Code / Cursor / Codex CLI / Gemini CLI / Antigravity / VS Code drive Roblox's own tools, including playtests and input simulation; you pay the client |
| **BloxBot** | Free MIT desktop app (Win/mac/Linux) connecting your own model (ChatGPT sign-in, API key, local) to Studio MCP, no plugin |
| **ZeroScript** | Free GPL browser extension + local Bridge driving Studio MCP from a free AI web chat (DeepSeek); warns about cookie-stealing copycats |

### Outside Studio: generators
| Tool | One-line differentiator |
|---|---|
| **Obby** (obby.fun) | Browser preview, exports a `.rbxlx`; obbies, tycoons, pet sims; free tier; poor fit for existing places |
| **Roblox Build** (mobile app) | Roblox's own 2D/2.5D game maker in the Build tab, free daily prompts, one-tap publish after a safety check, ages 9+, rolling out from NZ; editing in Studio removes Build status |
| **Chatbots** (ChatGPT, Claude, Copilot) | Good at explaining code; cannot see your place |

### Not on RoCode's page
| Tool | One-line differentiator |
|---|---|
| **Nilo** (nilo.io) | Browser 3D engine plus AI asset pipeline (text/sketch/image → mesh, rig, text/video → animation, UGC), multiplayer worlds, World Agent with GDD and frustration reports; exports .fbx/.glb/.rbxmx or pushes through Open Cloud. See `nilo.md`. |
| **[W]** Roqer, Stud, RobloxAIBuilder, ForgeGUI | Surfaced in web search (open-source Roqer on ChatGPT/Claude subs; Stud MCP connector; DevForum plugins), e.g. https://devforum.roblox.com/t/robloxaibuilder-plugin-ai-assistant-coding-copilot-building/4528734 |

## What the map says (Inferred)

- **[I]** The crowded middle is "a chat agent edits your open place", with 16+ vendors. The differentiators have collapsed to playtest depth (errors only, then robot, then screenshots), platform, and pricing unit. Nobody listed runs **multi-agent AI player swarms**, **autopilot until ready**, or **learning from corrections**. Those three are Forge's open lane.
- **[I]** Roblox Assistant plus Studio MCP is free and already playtests, simulates input and generates meshes. Any Forge feature that is just "edit Studio from chat" is commoditised. Lead with the loop (testers → gaps → fixes → Mubit updates), not the editor.
- **[I]** Patterns worth stealing that keep recurring across vendors: **approve a plan with a cost estimate first** (RoAI, Kiwari), **one-click whole-build undo** (Craftly, RoCode), **templates or kits** (RoStudio, RoCode), **performance profiling in playtests** (RoGenie).
- **[O]** There is a naming conflict: "Forge" is already a Roblox Studio agent (forgeblox.app, renamed ForgeBlox Oct 2026), and RoCode ranks a "RoCode vs Forge" page for it.
