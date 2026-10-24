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
			"🚒 Everyone gets a fire truck! Anyone can drive any truck, and the last driver owns it",
			"📻 New DISPATCH radio: calls come in while you drive. ACCEPT from anywhere, plus little bin fires",
			"🚨 Your first call starts right in the truck",
			"🏠 A BACK TO STATION button",
			"🚪 Hop in and out of trucks instantly: no doors, no spinning!",
			"🅿️ Open fire station: drive out of the bays any way you like",
			"🔒 One big LOCKER with a picture menu, and your gear saves",
			"💦 A real SPRAY button + better aiming on phones and iPads",
			"📱 Phone buttons that fit every phone, and tap things to use them",
			"🟩 Get people OUTSIDE and they're safe (look for the green zone!)",
			"🐼 The panda is a one-penguin carry now",
			"🗺️ A new map every server: seasons, weather and night!",
			"🏫 Furnished schools, homes, shops, diners, the zoo, the dam, the club, Sky Tower and the warehouse",
			"🎁 Gift fanfare when someone gets a pass",
			"😂 Silly admin powers (for admins)",
			"🤫 Calmer pop-ups",
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
