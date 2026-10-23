--!strict
-- PopupLogic: pure admission rules for ClientLib/WorldPopup (world text) and HudController (screen toasts).
-- No Roblox APIs (spec-tested in game/tests/popup.spec.luau).
--
--   PopupLogic.mode(v: any): "Normal" | "Minimal" | "Off"     -- 0/1/2, or the string, any case
--   PopupLogic.allowed(mode, mine: boolean): boolean            -- Minimal = only popups you are part of
--   PopupLogic.new(cfg: Cfg): State
--   PopupLogic.admit(s, now, key, text, mode?, mine?): Decision
--     key = subject ("screen" for toasts). Drops: mode/Minimal, same key+text within dedupe seconds.
--     Otherwise admits a new entry, evicting (oldest first) so the subject has < perSubject and the
--     total < cap. Decision.evict lists entry ids the caller must remove right away.
--   PopupLogic.release(s, id)                                   -- entry finished (faded out)
--   PopupLogic.count(s): number

local PopupLogic = {}

export type Mode = "Normal" | "Minimal" | "Off"
export type Cfg = { cap: number, perSubject: number, dedupeSeconds: number, lifeSeconds: number }
export type Entry = { id: number, key: string, text: string, t: number }
export type State = { cfg: Cfg, active: { Entry }, recent: { [string]: number }, nextId: number }
export type Decision = { show: boolean, id: number, evict: { number }, reason: string? }

local MODES: { Mode } = { "Normal", "Minimal", "Off" }

function PopupLogic.mode(v: any): Mode
	if type(v) == "number" then
		return MODES[math.clamp(math.floor(v), 0, 2) + 1]
	elseif type(v) == "string" then
		local l = string.lower(v)
		for _, m in MODES do
			if string.lower(m) == l then
				return m
			end
		end
	end
	return "Normal"
end

function PopupLogic.index(mode: Mode): number
	return if mode == "Minimal" then 1 elseif mode == "Off" then 2 else 0
end

function PopupLogic.allowed(mode: Mode, mine: boolean): boolean
	if mode == "Off" then
		return false
	elseif mode == "Minimal" then
		return mine
	end
	return true
end

function PopupLogic.new(cfg: Cfg): State
	return { cfg = cfg, active = {}, recent = {}, nextId = 0 }
end

local function prune(s: State, now: number)
	local life = s.cfg.lifeSeconds + 0.5 -- safety net if a release never arrives
	for i = #s.active, 1, -1 do
		if now - s.active[i].t > life then
			table.remove(s.active, i)
		end
	end
	for k, t in s.recent do
		if now - t >= s.cfg.dedupeSeconds then
			s.recent[k] = nil
		end
	end
end

local function removeId(s: State, id: number): boolean
	for i, e in s.active do
		if e.id == id then
			table.remove(s.active, i)
			return true
		end
	end
	return false
end

function PopupLogic.admit(s: State, now: number, key: string, text: string, mode: Mode?, mine: boolean?): Decision
	prune(s, now)
	if not PopupLogic.allowed(mode or "Normal", mine == true) then
		return { show = false, id = 0, evict = {}, reason = "mode" }
	end
	local dk = key .. "\0" .. text
	local last = s.recent[dk]
	if last and now - last < s.cfg.dedupeSeconds then
		return { show = false, id = 0, evict = {}, reason = "dupe" }
	end
	s.recent[dk] = now
	local evict = {}
	-- per subject: active is in admission order, so the first match is the oldest
	local same = 0
	for _, e in s.active do
		if e.key == key then
			same += 1
		end
	end
	while same >= math.max(1, s.cfg.perSubject) do
		for _, e in s.active do
			if e.key == key then
				table.insert(evict, e.id)
				removeId(s, e.id)
				break
			end
		end
		same -= 1
	end
	while #s.active >= math.max(1, s.cfg.cap) do
		table.insert(evict, s.active[1].id)
		table.remove(s.active, 1)
	end
	s.nextId += 1
	table.insert(s.active, { id = s.nextId, key = key, text = text, t = now })
	return { show = true, id = s.nextId, evict = evict }
end

function PopupLogic.release(s: State, id: number)
	removeId(s, id)
end

function PopupLogic.count(s: State): number
	return #s.active
end

return PopupLogic
