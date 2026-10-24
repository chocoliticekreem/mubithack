--!strict
-- MonetizationRules [owner: Monetization]. PURE: id lookups, ownership and the idempotent
-- ProcessReceipt flow. No Roblox APIs, so `luau game/tests/monetization.spec.luau` runs it in CI.
-- MonetizationService wraps it with MarketplaceService + DataStores.
--
--   MonetizationRules.passId(gamePasses, key): number          -- 0 = not configured / unknown key
--   MonetizationRules.passKey(gamePasses, passId): string?     -- configured key for a real id
--   MonetizationRules.product(products, productId): Product?   -- only configured (id > 0) products
--   MonetizationRules.donation(products, robux): Product?      -- a donation button by its amount
--   MonetizationRules.owns(cached, debugFlag, isStudio): boolean
--   MonetizationRules.process(receipt, products, ctx): (Decision, string)
--     Decision = "Granted" | "NotProcessedYet". ctx (all injected, so tests use fakes):
--       ledgerHas(purchaseId) -> (ok, has)       -- global "already granted" ledger read
--       grant(purchaseId, robux) -> GrantResult   -- "applied" | "duplicate" | "absent" (player gone /
--                                                    profile not loaded); must itself be idempotent
--       save() -> boolean                          -- persist the profile the grant changed
--       ledgerPut(purchaseId, record) -> boolean   -- best effort; the profile's receipts back it up
--     The reason string is "applied" only when this call actually counted the donation.

export type Product = { id: number, robux: number }
export type Decision = "Granted" | "NotProcessedYet"
export type GrantResult = "applied" | "duplicate" | "absent"
export type Ctx = {
	ledgerHas: (purchaseId: string) -> (boolean, boolean),
	grant: (purchaseId: string, robux: number) -> GrantResult,
	save: () -> boolean,
	ledgerPut: (purchaseId: string, record: { [string]: any }) -> boolean,
}

local MonetizationRules = {}

local function validId(v: any): number
	if type(v) == "number" and v == v and v > 0 and v % 1 == 0 then
		return v
	end
	return 0
end

function MonetizationRules.passId(gamePasses: any, key: any): number
	if type(gamePasses) ~= "table" or type(key) ~= "string" then
		return 0
	end
	return validId(gamePasses[key])
end

function MonetizationRules.passKey(gamePasses: any, passId: any): string?
	local id = validId(passId)
	if id == 0 or type(gamePasses) ~= "table" then
		return nil
	end
	for key, v in gamePasses do
		if type(key) == "string" and validId(v) == id then
			return key
		end
	end
	return nil
end

function MonetizationRules.product(products: any, productId: any): Product?
	local id = validId(productId)
	if id == 0 or type(products) ~= "table" then
		return nil
	end
	for _, p in products do
		if type(p) == "table" and validId(p.id) == id and type(p.robux) == "number" and p.robux > 0 then
			return { id = id, robux = math.floor(p.robux) }
		end
	end
	return nil
end

function MonetizationRules.donation(products: any, robux: any): Product?
	if type(products) ~= "table" or type(robux) ~= "number" then
		return nil
	end
	for _, p in products do
		if type(p) == "table" and p.robux == robux then
			return { id = validId(p.id), robux = math.floor(robux) }
		end
	end
	return nil
end

-- cached = the UserOwnsGamePassAsync / purchase result; the debug flag only counts in Studio.
function MonetizationRules.owns(cached: any, debugFlag: any, isStudio: boolean): boolean
	return cached == true or (isStudio and debugFlag == true)
end

function MonetizationRules.process(receipt: any, products: any, ctx: Ctx): (Decision, string)
	if type(receipt) ~= "table" then
		return "NotProcessedYet", "bad receipt"
	end
	local purchaseId = if receipt.PurchaseId ~= nil then tostring(receipt.PurchaseId) else ""
	if purchaseId == "" then
		return "NotProcessedYet", "no PurchaseId"
	end
	local product = MonetizationRules.product(products, receipt.ProductId)
	if not product then
		return "NotProcessedYet", "unknown product " .. tostring(receipt.ProductId)
	end
	local ok, has = ctx.ledgerHas(purchaseId)
	if not ok then
		return "NotProcessedYet", "ledger read failed"
	end
	if has then
		return "Granted", "duplicate"
	end
	local result = ctx.grant(purchaseId, product.robux)
	if result == "absent" then
		return "NotProcessedYet", "player not ready"
	end
	if result == "applied" and not ctx.save() then
		-- the live profile already holds the receipt, so a retry on this server is a "duplicate"
		return "NotProcessedYet", "save failed"
	end
	ctx.ledgerPut(purchaseId, {
		userId = receipt.PlayerId,
		productId = product.id,
		robux = product.robux,
	})
	return "Granted", result
end

return MonetizationRules
