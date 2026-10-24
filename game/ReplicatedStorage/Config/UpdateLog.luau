--!strict
-- UpdateLog [owner: UpdateLog]. The in-game "WHAT'S NEW" list (Controllers/UpdateLogController draws it,
-- Services/UpdateLogService remembers who has seen what in the profile: updates.lastSeen).
--
-- HOW TO ADD AN UPDATE: put a new table at the TOP of Entries (newest first). That's all: every player
-- whose profile hasn't seen that `version` gets the panel once on their next join, and the old newest
-- entry moves under "Older updates" by itself.
--   version  unique id, "YYYY.MM.DD" (add ".2" for a second update the same day). Never reuse one.
--   date     what kids read, e.g. "Oct 24, 2026"
--   title    short and loud, e.g. "Big Update!"
--   items    short kid-friendly lines, each starting with ONE emoji. Aim for under ~50 characters.
--
--   UpdateLog.Entries                 -- { Entry }, newest first
--   UpdateLog.latest(): Entry?        -- Entries[1]
--   UpdateLog.find(version): Entry?
--   UpdateLog.isKnown(version): boolean
--   UpdateLog.unseen(lastSeen): boolean   -- true when the newest version isn't the one you last saw
export type Entry = { version: string, date: string, title: string, items: { string } }

local UpdateLog = {}

UpdateLog.Entries = {
	{
		version = "2026.10.24",
		date = "Oct 24, 2026",
		title = "Big Update!",
		items = {
			"🔥 Easier tutorial: just spray the fire!",
			"💦 A real SPRAY button + better aiming on phones and iPads",
			"🚒 Start your first call sitting right in the truck",
			"🟩 Get people OUTSIDE and they're safe (look for the green zone!)",
			"🐼 The panda is a one-penguin carry now",
			"📱 Phone buttons that fit every phone",
			"🗺️ A new map every server: seasons, weather and night!",
			"🏫 Schools, homes, shops, diners, the club, Sky Tower and the warehouse are all furnished",
			"🤫 Calmer pop-ups",
			"👆 Tap things to use them",
			"🚚 Trucks don't spin when you hop in",
			"🧹 The fire station tidies itself",
			"🛒 New store art",
		},
	},
} :: { Entry }

function UpdateLog.latest(): Entry?
	return UpdateLog.Entries[1]
end

function UpdateLog.find(version: string): Entry?
	for _, e in UpdateLog.Entries do
		if e.version == version then
			return e
		end
	end
	return nil
end

function UpdateLog.isKnown(version: any): boolean
	return type(version) == "string" and UpdateLog.find(version) ~= nil
end

function UpdateLog.unseen(lastSeen: any): boolean
	local newest = UpdateLog.latest()
	return newest ~= nil and lastSeen ~= newest.version
end

return UpdateLog
