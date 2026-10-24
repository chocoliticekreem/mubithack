--!strict
-- MonetizationRules (ids, ownership, idempotent ProcessReceipt) + ProfileSchema v5 donations.
local Spec = require("./Spec")
local Rules = require("../ServerScriptService/Lib/Monetization/MonetizationRules")
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local NOW = 1_792_800_000

local PRODUCTS = {
	{ id = 111, robux = 10 },
	{ id = 222, robux = 50 },
	{ id = 0, robux = 100 }, -- not configured yet
}

-- A fake world: a ledger table, one profile, and switches to make each step fail.
local function world(opts: { [string]: any }?)
	local o = opts or {}
	local w: any = {
		ledger = {},
		profile = if o.absent then nil else Schema.default(NOW),
		saves = 0,
		puts = 0,
	}
	w.ctx = {
		ledgerHas = function(id: string): (boolean, boolean)
			if o.ledgerDown then
				return false, false
			end
			return true, w.ledger[id] ~= nil
		end,
		grant = function(id: string, robux: number): Rules.GrantResult
			if not w.profile then
				return "absent"
			end
			return if Schema.addDonation(w.profile, id, robux) then "applied" else "duplicate"
		end,
		save = function(): boolean
			w.saves += 1
			return not o.saveFails
		end,
		ledgerPut = function(id: string, rec: any): boolean
			w.puts += 1
			if o.putFails then
				return false
			end
			w.ledger[id] = rec
			return true
		end,
	}
	return w
end

local function receipt(purchaseId: string, productId: number): any
	return { PurchaseId = purchaseId, ProductId = productId, PlayerId = 7, CurrencySpent = 10 }
end

Spec.test("passId: 0 for unset, unknown or bad ids", function()
	local passes = { UnlimitedFoam = 0, PremiumPass = 555, Bad = -3, Frac = 1.5 }
	Spec.eq(Rules.passId(passes, "UnlimitedFoam"), 0)
	Spec.eq(Rules.passId(passes, "PremiumPass"), 555)
	Spec.eq(Rules.passId(passes, "Nope"), 0)
	Spec.eq(Rules.passId(passes, "Bad"), 0)
	Spec.eq(Rules.passId(passes, "Frac"), 0)
	Spec.eq(Rules.passId(nil, "PremiumPass"), 0)
end)

Spec.test("passKey maps a real id back, never id 0", function()
	local passes = { UnlimitedFoam = 0, PremiumPass = 555 }
	Spec.eq(Rules.passKey(passes, 555), "PremiumPass")
	Spec.eq(Rules.passKey(passes, 0), nil)
	Spec.eq(Rules.passKey(passes, 999), nil)
end)

Spec.test("product: only configured ids match", function()
	Spec.eq((Rules.product(PRODUCTS, 222) :: any).robux, 50)
	Spec.eq(Rules.product(PRODUCTS, 0), nil)
	Spec.eq(Rules.product(PRODUCTS, 333), nil)
	Spec.eq((Rules.donation(PRODUCTS, 100) :: any).id, 0, "unconfigured button keeps id 0")
	Spec.eq(Rules.donation(PRODUCTS, 77), nil)
end)

Spec.test("owns: cache, or the debug flag in Studio only", function()
	Spec.eq(Rules.owns(true, nil, false), true)
	Spec.eq(Rules.owns(nil, true, true), true)
	Spec.eq(Rules.owns(nil, true, false), false, "debug flag ignored on live servers")
	Spec.eq(Rules.owns(false, false, true), false)
end)

Spec.test("first receipt grants, records and saves", function()
	local w = world()
	local d, why = Rules.process(receipt("p1", 111), PRODUCTS, w.ctx)
	Spec.eq(d, "Granted")
	Spec.eq(why, "applied")
	Spec.eq(w.profile.donations.robux, 10)
	Spec.eq(w.profile.donations.count, 1)
	Spec.eq(w.saves, 1)
	Spec.truthy(w.ledger.p1, "ledger has p1")
end)

Spec.test("same PurchaseId twice counts once (ledger)", function()
	local w = world()
	Rules.process(receipt("p1", 222), PRODUCTS, w.ctx)
	local d, why = Rules.process(receipt("p1", 222), PRODUCTS, w.ctx)
	Spec.eq(d, "Granted")
	Spec.eq(why, "duplicate")
	Spec.eq(w.profile.donations.robux, 50)
	Spec.eq(w.saves, 1, "no second save")
end)

Spec.test("ledger write failed: the profile receipt still dedupes the retry", function()
	local w = world({ putFails = true })
	Spec.eq((Rules.process(receipt("p9", 111), PRODUCTS, w.ctx)), "Granted")
	local d, why = Rules.process(receipt("p9", 111), PRODUCTS, w.ctx)
	Spec.eq(d, "Granted")
	Spec.eq(why, "duplicate")
	Spec.eq(w.profile.donations.robux, 10)
end)

Spec.test("save failure -> NotProcessedYet; the retry is not double-counted", function()
	local w = world({ saveFails = true })
	local d, why = Rules.process(receipt("p2", 111), PRODUCTS, w.ctx)
	Spec.eq(d, "NotProcessedYet")
	Spec.eq(why, "save failed")
	local d2 = Rules.process(receipt("p2", 111), PRODUCTS, w.ctx)
	Spec.eq(d2, "Granted")
	Spec.eq(w.profile.donations.robux, 10)
end)

Spec.test("player absent / ledger down / unknown product -> NotProcessedYet, nothing granted", function()
	local w = world({ absent = true })
	Spec.eq((Rules.process(receipt("a", 111), PRODUCTS, w.ctx)), "NotProcessedYet")
	Spec.eq(w.puts, 0)
	local w2 = world({ ledgerDown = true })
	Spec.eq((Rules.process(receipt("b", 111), PRODUCTS, w2.ctx)), "NotProcessedYet")
	Spec.eq(w2.profile.donations.robux, 0)
	local w3 = world()
	Spec.eq((Rules.process(receipt("c", 0), PRODUCTS, w3.ctx)), "NotProcessedYet")
	Spec.eq((Rules.process(receipt("", 111), PRODUCTS, w3.ctx)), "NotProcessedYet")
	Spec.eq((Rules.process(nil, PRODUCTS, w3.ctx)), "NotProcessedYet")
	Spec.eq(w3.profile.donations.robux, 0)
end)

Spec.test("profile v5: donations default, v4 migrates, receipts capped", function()
	Spec.eq(Schema.Version >= 5, true) -- v6: battle pass
	local p = Schema.default(NOW)
	Spec.eq(p.donations.robux, 0)
	local m = Schema.migrate({ version = 4, xp = 120, guides = { seen = {} } }, NOW) :: any
	Spec.eq(m.version, Schema.Version)
	Spec.eq(m.donations.robux, 0)
	Spec.eq(#m.donations.receipts, 0)
	for i = 1, Schema.MaxReceipts + 5 do
		Spec.eq(Schema.addDonation(p, `r{i}`, 10), true)
	end
	Spec.eq(#p.donations.receipts, Schema.MaxReceipts)
	Spec.eq(p.donations.robux, (Schema.MaxReceipts + 5) * 10)
	Spec.eq(Schema.addDonation(p, `r{Schema.MaxReceipts + 5}`, 10), false, "newest receipt is a duplicate")
	Spec.eq(Schema.addDonation(p, "", 10), false)
	Spec.eq(Schema.addDonation(p, "zero", 0), false)
	local broken = Schema.migrate({ version = 5, donations = { robux = -4, count = "x", receipts = { "ok", 3 } } }, NOW) :: any
	Spec.eq(broken.donations.robux, 0)
	Spec.eq(broken.donations.count, 0)
	Spec.eq(#broken.donations.receipts, 1)
end)

return Spec.finish()
