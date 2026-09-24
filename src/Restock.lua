------------------------------------------------------------------------
-- GuildBankLedger — Restock.lua
-- Pure restock math (target / stock / toBuy) plus the displayed item
-- universe and per-guild-local restock settings. No AceGUI, no Auctionator
-- (those land in the RestockView / search-flow milestones).
--
-- Target model (Option C): per-item guild target = max(layoutDemand, reserve).
-- Demand comes from display-tab templates; reserve from GetStockReserves
-- (dormant until a producer ships). toBuy = max(0, target - stock - pending), where
-- stock aggregates the latest scan across all tabs and pending is what has
-- been bought at the auction house and not yet seen in the bank (#209).
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- itemID from a link. Delegates to BankLayout's helper (loaded earlier) and
-- falls back to a regex so load-order surprises can't break stock counting.
local function extractItemID(itemLink)
    if GBL.BankLayout and GBL.BankLayout.ExtractItemID then
        return GBL.BankLayout.ExtractItemID(itemLink)
    end
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

------------------------------------------------------------------------
-- Pure functions (no guild state; operate on their arguments)
------------------------------------------------------------------------

--- Sum the layout's per-item demand over display tabs only.
-- demand(itemID) = sum of slots*perSlot for every display-tab entry.
-- @param layout table from GetBankLayout (or constructed); may be nil
-- @return table { [itemID] = count }
function GBL:_RestockLayoutDemand(layout)
    local demand = {}
    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return demand
    end
    for _, tab in pairs(layout.tabs) do
        if type(tab) == "table" and tab.mode == "display" then
            for itemID, row in pairs(tab.items or {}) do
                -- Coerce the key to a number: a layout received over sync may
                -- arrive string-keyed (AceSerializer numeric-key survival is
                -- unverified, per CLAUDE.md), and stock/reserves are number-keyed.
                local id = tonumber(itemID)
                if id and type(row) == "table" then
                    local n = (row.slots or 0) * (row.perSlot or 0)
                    demand[id] = (demand[id] or 0) + n
                end
            end
        end
    end
    return demand
end

--- Aggregate current stock across all tabs of a scan-results table.
-- @param scanResults table from GetLastScanResults (keyed by tab); may be nil
-- @return table { [itemID] = count }
function GBL:_RestockAggregateStock(scanResults)
    local stock = {}
    if type(scanResults) ~= "table" then
        return stock
    end
    for _, tabResult in pairs(scanResults) do
        if type(tabResult) == "table" and type(tabResult.slots) == "table" then
            for _, slot in pairs(tabResult.slots) do
                if type(slot) == "table" then
                    local id = extractItemID(slot.itemLink)
                    if id then
                        stock[id] = (stock[id] or 0) + (slot.count or 1)
                    end
                end
            end
        end
    end
    return stock
end

--- Per-item guild target: max(layout demand, reserve). Option C.
-- @param itemID number
-- @param demandMap table { [itemID] = count } (from _RestockLayoutDemand)
-- @param reserves table { [itemID] = count } (from GetStockReserves)
-- @return number target (>= 0)
function GBL:_RestockTarget(itemID, demandMap, reserves)
    local demand = (demandMap and demandMap[itemID]) or 0
    local reserve = (reserves and reserves[itemID]) or 0
    if demand > reserve then return demand end
    return reserve
end

--- How many to buy: max(0, target - stock).
-- @param itemID number
-- @param demandMap table
-- @param reserves table
-- @param stockMap table { [itemID] = count } (from _RestockAggregateStock)
-- @return number toBuy (>= 0)
function GBL:_restockComputeToBuy(itemID, demandMap, reserves, stockMap)
    local target = self:_RestockTarget(itemID, demandMap, reserves)
    local stock = (stockMap and stockMap[itemID]) or 0
    local toBuy = target - stock
    if toBuy < 0 then return 0 end
    return toBuy
end

------------------------------------------------------------------------
-- Per-guild-local restock settings (NOT synced; personal preferences).
-- Guild-wide targets ride the synced bankLayout + stockReserves instead.
------------------------------------------------------------------------

-- Guild-scoped restock store, backfilling missing fields. Returns nil when
-- there is no active guild yet. Mirrors BankLayout.lua getStore.
local function getStore(self)
    local guild = self:GetGuildData()
    if not guild then return nil end
    if not guild.restock then
        guild.restock = { items = {}, budget = 0, pending = {} }
    end
    local r = guild.restock
    if not r.items then r.items = {} end
    if r.budget == nil then r.budget = 0 end
    if not r.pending then r.pending = {} end
    return r
end

--- Return the live per-guild restock store (backfilled), or nil if no guild.
-- @return table|nil { items = {...}, budget = number, pending = {...} }
function GBL:GetRestockData()
    return getStore(self)
end

------------------------------------------------------------------------
-- Pending purchases (#209): bought at the auction house and not yet seen in
-- the bank. An auction-house purchase arrives by mail, so the bank scan
-- cannot see it until the buyer collects and deposits it, and a search in
-- that window offered the row again. pending[itemID] = { qty, unconfirmedQty,
-- buyer, buyers, at, unconfirmedAt } is per guild and persisted beside the
-- budget (the mail outlives a session), local to the account and not synced
-- (the mail is the buyer's). The two quantities are apart since #215: qty
-- is confirmed and unconfirmedQty is a confirm whose result never arrived,
-- so a late result can settle or reverse the second without touching the
-- first. Read them through _RestockPendingParts, which is also where the
-- unconfirmed flag is derived and where the pre-split shape is understood.
-- Cleared by the ledger's deposit records for the buyer
-- (_RestockOnRecordStored), never by the bank scan, which cannot tell the
-- buyer's deposit from another member's.
------------------------------------------------------------------------

-- A deposit record clears an entry when its timestamp is at or after the
-- purchase less this window. Ledger timestamps are hour-coarse
-- (ComputeAbsoluteTimestamp) in a rounding direction nobody has recorded, so
-- the window is one hour rather than zero: the cost is a same-item deposit
-- by the buyer up to two hours before the purchase, stored for the first
-- time after it, clearing the entry early, which the manual Clear answers.
local PENDING_WINDOW = 3600
GBL.RESTOCK_PENDING_WINDOW = PENDING_WINDOW

-- The buying character in the form the ledger writes record.player.
local function buyerName(self)
    return self:ResolvePlayerName(UnitName("player") or "Unknown")
end

--- One entry, two quantities (#215). `qty` is confirmed, meaning the client
-- saw the purchase result; `unconfirmedQty` is a confirm whose result it
-- never saw, so a late success can settle the second into the first and a
-- late failure can take it back out. **This is the one place either number
-- becomes a reading**, and the `unconfirmed` boolean the first cut stored is
-- derived here rather than kept beside them, because two stored copies of
-- one fact can disagree and nothing would say which was right.
-- An entry written before the split carries `qty` plus that boolean, which
-- reads as wholly unconfirmed; a plain one reads as wholly confirmed. The
-- mapping is written from what _RestockAddPending used to store, not from
-- any of the prose copies of the shape, which did not agree with each other.
-- @param entry table|nil
-- @return table { confirmed, unconfirmed, total, at, unconfirmedAt, isUnconfirmed }
function GBL:_RestockPendingParts(entry)
    if type(entry) ~= "table" then
        return { confirmed = 0, unconfirmed = 0, total = 0, isUnconfirmed = false }
    end
    local confirmed = tonumber(entry.qty) or 0
    local unconfirmed = tonumber(entry.unconfirmedQty)
    if not unconfirmed then
        -- Pre-split: the boolean covered the whole quantity.
        unconfirmed = entry.unconfirmed and confirmed or 0
        if entry.unconfirmed then confirmed = 0 end
    end
    if confirmed < 0 then confirmed = 0 end
    if unconfirmed < 0 then unconfirmed = 0 end
    -- Every field is coerced, the three times included: they are compared
    -- against a record timestamp and subtracted from GetServerTime(), so a
    -- missing one failed the deposit window open and a non-numeric one
    -- took out the whole tab render one frame later.
    local at = tonumber(entry.at)
    return {
        confirmed = confirmed,
        unconfirmed = unconfirmed,
        total = confirmed + unconfirmed,
        at = at,
        -- Each part carries the earliest purchase WITHIN ITSELF, which is
        -- what an age answers ("how long has this been owed"). `at` is the
        -- earliest of either and stays the deposit window anchor.
        confirmedAt = tonumber(entry.confirmedAt) or at,
        unconfirmedAt = tonumber(entry.unconfirmedAt) or at,
        isUnconfirmed = unconfirmed > 0,
    }
end

-- Find an entry whatever key shape wrote it, and re-key it by number so the
-- store heals itself (InitSync consolidates a stale knownPeers key the same
-- way). The universe has always tolerated a string key while both readers
-- indexed by number, so such an entry rendered with a Clear that did nothing
-- and could never be settled by a deposit.
local function takeEntry(self, pending, itemID)
    if type(pending) ~= "table" or not itemID then return nil end
    -- Most guilds have bought nothing, and this runs once per first-time
    -- stored deposit record, so the whole walk is skipped rather than
    -- paying tostring() per record across a full scan batch.
    if next(pending) == nil then return nil end
    local numeric = pending[itemID]
    local key = tostring(itemID)
    local stringed = key ~= itemID and pending[key] or nil
    -- Both shapes can coexist, and returning on the numeric one left the
    -- string copy unreachable for good: the universe folds both into one
    -- row, so its quantity went pairs-order nondeterministic and Clear
    -- removed only half of it. Merge, keeping the earlier purchase.
    if type(stringed) == "table" then
        pending[key] = nil
        if type(numeric) ~= "table" then
            pending[itemID] = stringed
            return stringed
        end
        local a = self:_RestockPendingParts(numeric)
        local b = self:_RestockPendingParts(stringed)
        numeric.qty = a.confirmed + b.confirmed
        numeric.unconfirmedQty = a.unconfirmed + b.unconfirmed
        numeric.unconfirmed = nil
        numeric.at = math.min(a.at or b.at or 0, b.at or a.at or 0)
        numeric.buyers = numeric.buyers or {}
        for who in pairs(stringed.buyers or {}) do numeric.buyers[who] = true end
        numeric.buyer = numeric.buyer or stringed.buyer
    elseif stringed ~= nil then
        pending[key] = nil
    end
    -- A corrupt SavedVariables value is not an entry: indexing it raised
    -- mid-purchase, which is the failure the buyer guard was added for.
    if type(numeric) ~= "table" then return nil end
    return numeric
end

-- Bring a pre-split entry onto the two-quantity shape in place, through the
-- one reading above, so every writer below can assume it.
local function normalizeEntry(self, entry)
    local p = self:_RestockPendingParts(entry)
    entry.qty = p.confirmed
    entry.unconfirmedQty = p.unconfirmed
    entry.unconfirmedAt = p.unconfirmed > 0 and p.unconfirmedAt or nil
    entry.unconfirmed = nil
    return entry
end

-- Move quantity between the two parts, or out of the entry altogether.
-- Returns false when there is no entry or nothing parked to move, which is
-- what tells a caller its eager park never landed.
local function movePending(self, itemID, qty, settle)
    itemID = tonumber(itemID)
    qty = tonumber(qty) or 0
    if not itemID or qty <= 0 then return false end
    local data = getStore(self)
    if not data then return false end
    local entry = takeEntry(self, data.pending, itemID)
    if not entry then return false end
    normalizeEntry(self, entry)
    if entry.unconfirmedQty <= 0 then return false end
    local moved = math.min(qty, entry.unconfirmedQty)
    entry.unconfirmedQty = entry.unconfirmedQty - moved
    if settle then entry.qty = entry.qty + moved end
    if entry.unconfirmedQty <= 0 then entry.unconfirmedAt = nil end
    local parts = self:_RestockPendingParts(entry)
    if parts.total <= 0 then
        data.pending[itemID] = nil
    end
    self:SystemInfo("Restock pending: it:%d x%d %s, %d in the mail",
        itemID, moved, settle and "confirmed by a late result" or "taken back",
        parts.total)
    return true
end

--- A late COMMODITY_PURCHASE_SUCCEEDED for a purchase parked when the step
-- timer gave up: move it to the confirmed part rather than adding a second
-- copy of the same quantity.
-- @param itemID number
-- @param qty number > 0
-- @return boolean settled
function GBL:_RestockSettlePending(itemID, qty)
    return movePending(self, itemID, qty, true)
end

--- A late COMMODITY_PURCHASE_FAILED: nothing was bought after all, so take
-- the parked quantity back out. An entry left at nothing is removed.
-- @param itemID number
-- @param qty number > 0
-- @return boolean reversed
function GBL:_RestockReversePending(itemID, qty)
    return movePending(self, itemID, qty, false)
end

--- Record a purchase as pending: create the entry or add to it. A second
-- purchase keeps the earlier `at` so the ledger window covers both, and an
-- unconfirmed quantity is settled by a late result or taken back out by a
-- late failure, and is not a flag that stays set until the entry clears. The store is per
-- account, so a second character buying the same item joins `buyers` and
-- its deposit settles the entry too; `buyer` stays the first, for the row.
-- @param itemID number
-- @param qty number > 0
-- @param flags table|nil { unconfirmed = true } for a confirm with no result
-- @return boolean recorded
-- @return string|nil why not: "nothing-to-record" (no item or no quantity,
--   so there is nothing a retry could ever write) or "no-store" (no guild
--   data read yet, which a later call can still succeed at). A caller
--   holding a record needs the difference: retrying the first forever is a
--   wedge, because the record blocks every buy while it stands (#215).
function GBL:_RestockAddPending(itemID, qty, flags)
    itemID = tonumber(itemID)
    qty = tonumber(qty) or 0
    if not itemID or qty <= 0 then return false, "nothing-to-record" end
    local data = getStore(self)
    if not data then return false, "no-store" end
    local unconfirmed = flags and flags.unconfirmed or nil
    local who = buyerName(self)
    local now = GetServerTime()
    local entry = takeEntry(self, data.pending, itemID)
    if entry then
        normalizeEntry(self, entry)
        -- The buyer key is guarded: an entry carrying none indexed the set
        -- with nil and raised "table index is nil" before the purchase was
        -- recorded, leaving the flow stuck in CONFIRMING.
        entry.buyer = entry.buyer or who
        entry.buyers = entry.buyers or { [entry.buyer] = true }
        entry.buyers[who] = true
        if unconfirmed then
            entry.unconfirmedQty = entry.unconfirmedQty + qty
            -- Its own stamp, kept at the earliest park WITHIN this part:
            -- `at` is the earliest of either part, so a park landing on an
            -- older confirmed entry would render that age for a purchase
            -- made seconds ago. It is deliberately not moved forward by a
            -- later park, because the age answers how long something has
            -- been owed.
            entry.unconfirmedAt = entry.unconfirmedAt or now
        else
            entry.qty = entry.qty + qty
            entry.confirmedAt = entry.confirmedAt or now
        end
    else
        entry = { qty = 0, unconfirmedQty = 0, buyer = who,
                  buyers = { [who] = true }, at = now }
        if unconfirmed then
            entry.unconfirmedQty = qty
            entry.unconfirmedAt = now
        else
            entry.qty = qty
            entry.confirmedAt = now
        end
        data.pending[itemID] = entry
    end
    self:SystemInfo("Restock pending: it:%d x%d added%s, %d in the mail",
        itemID, qty, unconfirmed and " (result unknown)" or "",
        self:_RestockPendingParts(entry).total)
    return true
end

--- Remove a pending entry by hand: a deposit from an alt, items that went
-- somewhere else, or an unconfirmed purchase the mail settled.
-- @param itemID number
-- @return boolean removed
function GBL:ClearRestockPending(itemID)
    itemID = tonumber(itemID)
    local data = getStore(self)
    if not itemID or not data then return false end
    local entry = takeEntry(self, data.pending, itemID)
    if not entry then return false end
    local total = self:_RestockPendingParts(entry).total
    data.pending[itemID] = nil
    self:SystemInfo("Restock pending: it:%d cleared by hand (x%d)", itemID, total)
    return true
end

--- A deposit record was stored for the first time (StoreBatchRecords for a
-- scan, StoreTx for a sync receive; both store a record once). A deposit of
-- a pending item by the buyer at or after the purchase window reduces the
-- entry by its count and removes it at zero. Reads the store on the guild
-- the record was stored for and creates nothing.
-- @param record table the stored transaction record
-- @param guildData table the guild it was stored in
-- @param opts table|nil { timestampRewritten = true } from StoreTx
-- @return boolean changed
function GBL:_RestockOnRecordStored(record, guildData, opts)
    if type(record) ~= "table" or record.type ~= "deposit" then return false end
    -- StoreTx replaces an invalid timestamp with now, in place, before this
    -- runs, so the record cannot be asked and the fact has to be handed in
    -- (#215). A sync-received copy of an old deposit with a corrupt or
    -- epoch-0 timestamp (#93) would otherwise read as now, pass the window,
    -- and clear an entry whose purchase is still in the mail. The entry
    -- stays and the player clears it by hand, which is the safe direction:
    -- a wrong keep costs one click, a wrong clear costs the gold again.
    if opts and opts.timestampRewritten then return false end
    local pending = guildData and guildData.restock and guildData.restock.pending
    if not pending then return false end
    local itemID = tonumber(record.itemID)
    local entry = takeEntry(self, pending, itemID)
    if not entry then return false end
    local buyers = entry.buyers
    if not ((buyers and buyers[record.player]) or record.player == entry.buyer) then return false end
    -- An entry with no usable purchase time cannot be windowed at all, and
    -- reading it as 0 made every deposit ever recorded look late enough.
    local anchor = self:_RestockPendingParts(entry).at
    if not anchor then return false end
    local dt = (record.timestamp or 0) - anchor
    if dt < -PENDING_WINDOW then return false end
    local count = tonumber(record.count) or 0
    if count <= 0 then return false end
    -- The offset is logged so a capture can say which way the ledger's hour
    -- rounding goes; a run of positive readings is the case for a zero window.
    -- The confirmed part drains first (#215): a real deposit is more likely
    -- to be the purchase whose result we saw, and draining the unconfirmed
    -- part first would drop the flag while goods are still owed. The shape
    -- is brought forward only here, past every guard: a refusal must leave
    -- the store as it found it, or a false return stops meaning that.
    normalizeEntry(self, entry)
    local take = count
    local fromConfirmed = math.min(take, entry.qty)
    entry.qty = entry.qty - fromConfirmed
    take = take - fromConfirmed
    if take > 0 then
        local fromUnconfirmed = math.min(take, entry.unconfirmedQty)
        entry.unconfirmedQty = entry.unconfirmedQty - fromUnconfirmed
    end
    if entry.unconfirmedQty <= 0 then entry.unconfirmedAt = nil end
    local left = self:_RestockPendingParts(entry).total
    if left <= 0 then
        pending[itemID] = nil
        self:SystemInfo("Restock pending: it:%d deposit x%d by %s, cleared (recorded %+ds after the purchase)",
            itemID, count, record.player, dt)
    else
        self:SystemInfo("Restock pending: it:%d deposit x%d by %s, %d left (recorded %+ds after the purchase)",
            itemID, count, record.player, left, dt)
    end
    return true
end

--- Age text for a pending entry: s, m, h, then d.
-- @param seconds number
-- @return string e.g. "2h ago"
function GBL:_RestockFormatAge(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 0 then seconds = 0 end
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

--- Get the per-item override row, or nil.
-- @param itemID number
-- @return table|nil { enabled?, maxPrice? }
function GBL:GetRestockItemOverride(itemID)
    local data = getStore(self)
    if not data then return nil end
    return data.items[itemID]
end

--- Set (or clear, when override is nil) the per-item override.
-- @param itemID number
-- @param override table|nil { enabled?, maxPrice? }
-- @return boolean ok, string|nil err
function GBL:SetRestockItemOverride(itemID, override)
    if type(itemID) ~= "number" then return false, "itemID must be numeric" end
    local data = getStore(self)
    if not data then return false, "no active guild" end
    data.items[itemID] = override
    return true, nil
end

-- How long one step may wait on the auction house (#199): for the price after
-- a start, for the result after a confirm, and for the throttle to report
-- ready before a deferred call. TSM's API_TIMEOUT is the same figure.
-- Exported so the spec fires the timers by delay, not by count.
local STEP_TIMEOUT = 5
GBL.RESTOCK_STEP_TIMEOUT = STEP_TIMEOUT

-- How long a quote waits for the Confirm click (#211) before the purchase is
-- dropped. A placeholder until a run has read what the server does with a
-- quote left unconfirmed for minutes (section 14 of the design, question 3);
-- the same one timer slot, armed at this delay in PRICED.
local PAUSE_TIMEOUT = 60
GBL.RESTOCK_PAUSE_TIMEOUT = PAUSE_TIMEOUT

-- Every reason a row is skipped under Buy next (st.skipped[i]), the code's
-- own list (#214): the row renders the prose below, the log keeps the code
-- (a capture is searched by it), and the chat lines keep their own wording
-- with the figures. Exported so the spec walks this list, not a copy of it.
local SKIP = {
    MAX_PRICE = "max price",
    BUDGET_THIS_BUY = "budget on this buy",
    CANNOT_AFFORD = "cannot afford",
    NO_PRICE_IN_TIME = format("no price within %ds", STEP_TIMEOUT),
    NO_USABLE_PRICE = "no usable price",
    CANNOT_AFFORD_AT_PRICE = "cannot afford at price",
    BUDGET_AT_PRICE = "budget at price",
    NO_PRICE_AVAILABLE = "no price available",
}
GBL._restockSkipReasons = SKIP

-- The two budget reasons: a budget change clears them (SetRestockBudget) and
-- they share the budget hint on the row. One set for both readers.
local SKIP_BUDGET = { [SKIP.BUDGET_THIS_BUY] = true, [SKIP.BUDGET_AT_PRICE] = true }

local BUDGET_TEXT = "over your budget (raise the budget to bring it back)"
local AFFORD_TEXT = "not enough gold"
local PRICE_TEXT = "no price from the auction house"
local RESTOCK_SKIP_TEXT = {
    [SKIP.MAX_PRICE] = "over your max price",
    [SKIP.CANNOT_AFFORD] = AFFORD_TEXT,
    [SKIP.NO_PRICE_IN_TIME] = PRICE_TEXT,
    [SKIP.NO_USABLE_PRICE] = PRICE_TEXT,
    [SKIP.CANNOT_AFFORD_AT_PRICE] = AFFORD_TEXT,
    [SKIP.NO_PRICE_AVAILABLE] = PRICE_TEXT,
}
for reason in pairs(SKIP_BUDGET) do RESTOCK_SKIP_TEXT[reason] = BUDGET_TEXT end

--- The prose for a skip reason, the one place a code becomes words (#214).
-- An unknown code comes back as itself, so a reason added ahead of its text
-- still shows something searchable on the row (the SortReasonText rule).
-- @param reason string|nil
-- @return string
function GBL:RestockSkipText(reason)
    if reason == nil then return "reason not recorded" end
    return RESTOCK_SKIP_TEXT[reason] or tostring(reason)
end

--- Per-run gold budget cap (0 = no cap).
-- @return number budget (>= 0)
function GBL:GetRestockBudget()
    local data = getStore(self)
    if not data then return 0 end
    return data.budget or 0
end

--- Set the per-run gold budget cap (clamped to >= 0). A change brings back
-- the rows the open search skipped for the budget (#199): a skip carries its
-- reason, and the budget ones are the only ones a new budget can answer.
-- @param n number
-- @return boolean ok, string|nil err
function GBL:SetRestockBudget(n)
    local data = getStore(self)
    if not data then return false, "no active guild" end
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    n = math.floor(n)
    local changed = (data.budget or 0) ~= n
    data.budget = n
    local st = self._restock
    if changed and st and type(st.skipped) == "table" then
        for i, reason in pairs(st.skipped) do
            if SKIP_BUDGET[reason] then
                st.skipped[i] = nil
            end
        end
    end
    return true, nil
end

--- Whether a purchase pauses on its quoted total for a Confirm click (#211).
-- A per-profile setting, on by default: the quote is the only point at which
-- the real cost is known before the gold moves.
-- @return boolean
function GBL:IsRestockConfirmAtPrice()
    local p = self.db and self.db.profile and self.db.profile.restock
    if p == nil or p.confirmAtPrice == nil then return true end
    return p.confirmAtPrice and true or false
end

--- Set the confirm-at-price pause.
-- @param on boolean
function GBL:SetRestockConfirmAtPrice(on)
    if not (self.db and self.db.profile) then return end
    self.db.profile.restock = self.db.profile.restock or {}
    self.db.profile.restock.confirmAtPrice = on and true or false
end

------------------------------------------------------------------------
-- Displayed item universe
------------------------------------------------------------------------

--- Build the ordered, decorated list of items to show on the Restock tab.
-- The list is driven by the bank layout: every display-tab item, grouped under
-- its tab, plus any reserve-only items (target > 0 with no layout demand) under
-- a Reserves group. Reserves have no producer until v0.35, so today this is
-- exactly the layout items. Deduped by itemID; each row is a NEW table.
--
-- Keys are coerced to numbers throughout because a synced layout may arrive
-- string-keyed (AceSerializer numeric-key survival is unverified, per CLAUDE.md)
-- while stock comes back number-keyed via _RestockAggregateStock.
--
-- opts (all optional, default to the live getters so tests can inject):
--   layout, reserves, scanResults, data
-- @return table array of rows, grouped/ordered:
--   { itemID, tabIndex?, group, enabled, maxPrice?, target, stock, toBuy,
--     pending, pendingAt?, pendingUnconfirmed?, scanned }
function GBL:_RestockBuildItemUniverse(opts)
    opts = opts or {}
    local layout = opts.layout or self:GetBankLayout()
    local reserves = opts.reserves or self:GetStockReserves()
    local scanResults = opts.scanResults or self:GetLastScanResults()
    local data = opts.data or self:GetRestockData() or {}
    local overrides = data.items or {}

    local demand = self:_RestockLayoutDemand(layout)
    local stock = self:_RestockAggregateStock(scanResults)
    -- Before a scan every row says so (#214, #43): the view reads bank ?
    -- and no shortfall off this flag. toBuy is left alone, since the
    -- no-scan precondition already keeps an unscanned bank out of the buy
    -- list.
    local scanned = scanResults ~= nil

    -- Reserves keyed by number (see the key-coercion note above).
    local reserveByID = {}
    if type(reserves) == "table" then
        for itemID, n in pairs(reserves) do
            local id = tonumber(itemID)
            if id then reserveByID[id] = n end
        end
    end

    -- Pending purchases keyed by number, the same coercion (#209).
    local pendingByID = {}
    if type(data.pending) == "table" then
        for itemID, entry in pairs(data.pending) do
            local id = tonumber(itemID)
            if id and type(entry) == "table" then pendingByID[id] = entry end
        end
    end

    local rows = {}
    local seen = {}

    local function decorate(itemID, group, tabIndex)
        if seen[itemID] then return end
        seen[itemID] = true
        local override = overrides[itemID]
        local enabled = true
        if override and override.enabled ~= nil then enabled = override.enabled end
        local target = self:_RestockTarget(itemID, demand, reserveByID)
        local stk = stock[itemID] or 0
        -- What is in the mail counts as stock for the shortfall (#209); a
        -- foreign deposit can push the sum past the target, hence the clamp.
        local pend = pendingByID[itemID]
        local pp = pend and self:_RestockPendingParts(pend) or nil
        local pending = (pp and pp.total) or 0
        local toBuy = target - stk - pending
        if toBuy < 0 then toBuy = 0 end
        rows[#rows + 1] = {
            itemID = itemID,
            tabIndex = tabIndex,
            group = group,
            enabled = enabled,
            maxPrice = override and override.maxPrice,
            target = target,
            stock = stk,
            toBuy = toBuy,
            pending = pending,
            pendingAt = pp and pp.at or nil,
            pendingUnconfirmed = (pp and pp.isUnconfirmed) or nil,
            pendingConfirmed = pp and pp.confirmed or nil,
            pendingUnconfirmedQty = pp and pp.unconfirmed or nil,
            pendingUnconfirmedAt = pp and pp.unconfirmedAt or nil,
            pendingConfirmedAt = pp and pp.confirmedAt or nil,
            scanned = scanned,
        }
    end

    -- Three passes: the layout's display tabs, then reserve-only items, then
    -- items with a purchase in the mail that the layout does not name (#215).
    -- 1. Layout display tabs, ascending tabIndex. Each item is in at most one
    -- display tab (BankLayout.Validate), so grouping by tab is unambiguous.
    local tabIndices = {}
    for tabIndex, tab in pairs(layout.tabs or {}) do
        if type(tab) == "table" and tab.mode == "display" then
            tabIndices[#tabIndices + 1] = tabIndex
        end
    end
    table.sort(tabIndices, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)

    for _, tabIndex in ipairs(tabIndices) do
        local tab = layout.tabs[tabIndex]
        -- The live name first (#236). layout.tabs[i].name is snapshotted when
        -- the tab is captured and nothing refreshes it, so a rename in the bank
        -- left this list disagreeing with the Layout tab on the same screen. It
        -- stays as the fallback for the window before the bank has been opened
        -- this session, where the client answers nothing and a capture-time
        -- name beats the index. A synced layout can key tabs by string.
        local idx = tonumber(tabIndex)
        local groupName = idx and self:GetTabName(idx, tab.name)
            or ("Tab " .. tostring(tabIndex))

        -- Order items by their first slotOrder position, falling back to itemID,
        -- so the list reads in the same left-to-right order as the bank tab.
        local firstSlot = {}
        if type(tab.slotOrder) == "table" then
            for slotIndex, itemID in pairs(tab.slotOrder) do
                local id = tonumber(itemID)
                local sidx = tonumber(slotIndex)
                if id and sidx and (firstSlot[id] == nil or sidx < firstSlot[id]) then
                    firstSlot[id] = sidx
                end
            end
        end
        local ids = {}
        for itemID in pairs(tab.items or {}) do
            local id = tonumber(itemID)
            if id then ids[#ids + 1] = id end
        end
        table.sort(ids, function(a, b)
            local fa, fb = firstSlot[a], firstSlot[b]
            if fa and fb then
                if fa ~= fb then return fa < fb end
                return a < b
            elseif fa then
                return true     -- slotted items before unslotted
            elseif fb then
                return false
            end
            return a < b
        end)
        for _, id in ipairs(ids) do
            decorate(id, groupName, tonumber(tabIndex))
        end
    end

    -- 2. Reserve-only items (target > 0, no display-tab demand). Empty until the
    -- reserve producer ships (v0.35); kept for Option C forward-compat.
    local reserveIDs = {}
    for itemID in pairs(reserveByID) do
        if not seen[itemID] then reserveIDs[#reserveIDs + 1] = itemID end
    end
    table.sort(reserveIDs)
    for _, id in ipairs(reserveIDs) do
        decorate(id, "Reserves (not in a display tab)", nil)
    end

    -- 3. Items with a purchase in the mail that the layout does not name
    -- (#215). Only a row can clear an entry, so an entry with no row could
    -- never be cleared and re-applied the moment the item came back; with
    -- the layout emptied it sat behind the "no items in your layout"
    -- message with no route to it at all. Nothing here is buyable: no
    -- demand and no reserve means target 0, so toBuy clamps to 0.
    local pendingIDs = {}
    for itemID in pairs(pendingByID) do
        if not seen[itemID] then pendingIDs[#pendingIDs + 1] = itemID end
    end
    table.sort(pendingIDs)
    for _, id in ipairs(pendingIDs) do
        decorate(id, "In the mail (not in a display tab)", nil)
    end

    return rows
end

------------------------------------------------------------------------
-- Auctionator search + buy flow
-- (IDLE -> SEARCHING -> READY -> CONFIRMING [-> PRICED -> CONFIRMING] -> READY)
-- Ported from GuildBankRestock, adapted to the layout-driven buy list and GBL's
-- singleton session-state conventions. Every Auctionator/Item/C_AuctionHouse
-- access is existence-guarded and verified in-game; the pure helpers below carry
-- the unit coverage (the buy state machine is also fireEvent-tested).
--
-- A purchase starts only from a click (#199): StartCommoditiesPurchase requires
-- a hardware event, and a start issued from an event handler or a timer does
-- nothing at all. _RestockBeginPurchase has two callers, StartRestockBuy and
-- StartRestockBuyNext, both click handlers, and nothing else may call it.
--
-- With the confirm-at-price pause on (#211, the default), the price event
-- enters PRICED and waits for a Confirm click; ConfirmCommoditiesPurchase
-- carries no hardware-event flag, so the click can issue it at once or hand
-- it to the next THROTTLED_SYSTEM_READY, the one seam the flow already has.
--
-- Session state on self._restock (NOT persisted, NOT synced):
--   { state, activeItems = { {itemID, needed} }, resultRows = { [i]=row },
--     searchGen, listenerRegistered, foundCount,                 -- search
--     bought, boughtTotal = { [i] = copper }, skipped = { [i] = reason },   -- buy
--     pendingIndex, pendingItemID, pendingQty,
--     pendingTotal, priceIn, confirmIssued, errorNote, stepStartedAt,   -- one step
--     buyAll, throttleBusy, stepTimer, unanswered,                       -- the run
--     buyEventsRegistered, spentEstimate, walletBase, spentAtBase }     -- spend (#60)
-- The EventBus listener table lives on self._restockListener (stable across
-- searches so Unregister matches Register).
------------------------------------------------------------------------

--- True when Auctionator exposes the search API this flow needs. Gates the
-- Search button (RestockView) and is the hard guard in StartRestockSearch.
function GBL:IsAuctionatorReady()
    return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
        and Auctionator.API.v1.ConvertToSearchString ~= nil and Auctionator.EventBus ~= nil
end

--- True while the auction house is open (#211): the AUCTION_HOUSE_SHOW and
-- _CLOSED events are the direct signal (Core's OnAuctionHouseToggled keeps
-- the flag), and the default frame is the proxy that covers a client whose
-- events have not fired yet this session. TradeSkillMaster's UI leaves the
-- frame shown at a tiny scale, so both agree there. Search, Buy, Buy next
-- and Confirm all disable on it, and a start is refused pre-start without
-- it: nothing used to guard a Buy click at the bank but the existence of
-- the API.
-- @return boolean
function GBL:_RestockAuctionHouseOpen()
    if self._auctionHouseOpen then return true end
    return AuctionHouseFrame ~= nil and AuctionHouseFrame.IsShown ~= nil
        and AuctionHouseFrame:IsShown() and true or false
end

--- The states that read the search blocker: IDLE and READY. The button,
-- the banner, StartRestockSearch and the Shopping-tab hook all ask this
-- one place, so a state added later joins all four at once or none.
-- @param state string
-- @return boolean
function GBL:_RestockStateReadsBlocker(state)
    return state == "IDLE" or state == "READY"
end

-- Seconds between looks for Auctionator's Shopping frame after the Auction
-- House window shows and the frame is not there yet (#217).
local SHOPPING_TAB_POLL = 0.5
GBL.RESTOCK_SHOPPING_TAB_POLL = SHOPPING_TAB_POLL

--- Watch Auctionator's Shopping tab (#217). The shopping-tab precondition
-- below is read on a rebuild and nowhere else, so selecting the tab with
-- the Restock tab showing left Search greyed until the tab was left and
-- re-entered. Auctionator creates AuctionatorShoppingFrame on the first
-- Auction House show of the session (its tab container's OnLoad, inside
-- AuctionatorAHFrameMixin:OnShow, and under TradeSkillMaster's scaled-down
-- frame not until the scale reaches 0.5), so the hooks install lazily:
-- from every rebuild, and from _RestockOnAuctionHouseShown's poll while
-- the frame is not there. LibAHTab hides every Auctionator tab frame and
-- shows the selected one on each selection, Auctionator shows its default
-- tab twice on open (once synchronously, once a tick later), and the frame
-- hides with the window, so the hooks fire in bursts; the redraw behind
-- them is coalesced and compared before it draws. Goes with the
-- precondition when #194 deletes it.
-- @return boolean true once the hooks are installed
function GBL:_RestockWatchShoppingTab()
    if self._restockShoppingTabHooked then return true end
    local frame = AuctionatorShoppingFrame
    if not (frame and frame.HookScript) then return false end
    local function changed() self:_RestockShoppingTabChanged() end
    frame:HookScript("OnShow", changed)
    frame:HookScript("OnHide", changed)
    self._restockShoppingTabHooked = true
    self:SystemInfo("Restock tab: hooked Auctionator's shopping frame")
    return true
end

--- The Shopping tab came on or went off screen. One redraw is scheduled
-- for the next tick however many firings land in this one: LibAHTab hides
-- every Auctionator tab frame and shows the selected one on each
-- selection, Auctionator shows its default tab twice on open, and the
-- frame hides with the window, so the hooks arrive in bursts. The redraw
-- is skipped only while a search or a purchase is in flight, where a
-- rebuild would move the focus from under the player (#214) or redraw a
-- running search; RefreshRestockTab decides the rest, as every other
-- caller lets it (it no-ops unless the Restock tab is the built one).
--
-- Two further gates shipped in the first cut of this fix and were
-- withdrawn after the in-game run, where Search never came back: an
-- in-view check on the cached `_restockInView` flag, and a compare of the
-- blocker against the one the last build rendered. Both could suppress the
-- redraw the fix exists for, and neither had ever been observed true on a
-- real client (`_restockInView`'s only other reader is the wallet
-- baseline, where a wrong value is invisible). That is the 2026-09-17 rule
-- (never gate an action on a predicate whose real behaviour has not been
-- observed) and it cost this fix its whole point. What replaces them is
-- the line below: the next run says which of them was false.
function GBL:_RestockShoppingTabChanged()
    if self._restockShoppingTabRedraw then return end
    if not (C_Timer and C_Timer.After) then return end
    self._restockShoppingTabRedraw = true
    C_Timer.After(0, function()
        self._restockShoppingTabRedraw = nil
        -- Another tab, or no window: RefreshRestockTab declines, and a line
        -- per Auction House tab click while the player is reading their
        -- transactions is noise that pushes a run out of the 300-entry
        -- capture (the #199 rule about idle auction-house traffic).
        if self.activeTab ~= "restock" then return end
        local st = self._restock
        local state = st and st.state or "IDLE"
        local visible = AuctionatorShoppingFrame ~= nil and AuctionatorShoppingFrame.IsVisible ~= nil
            and AuctionatorShoppingFrame:IsVisible() and true or false
        if not self:_RestockStateReadsBlocker(state) then
            self:SystemInfo("Restock tab: shopping tab %s, state=%s skipped (in flight)",
                visible and "shown" or "hidden", state)
            return
        end
        if self.RefreshRestockTab then self:RefreshRestockTab() end
        -- After the redraw, so the line carries the precondition the build
        -- just rendered, which is what a greyed Search has to be read
        -- against: shopping-tab, ah-closed, no-scan, nothing, or none.
        self:SystemInfo("Restock tab: shopping tab %s, state=%s redrew blocker=%s",
            visible and "shown" or "hidden", state,
            tostring(self._restockRenderedBlocker or "not built"))
    end)
end

--- The Auction House window showed (Core's OnAuctionHouseToggled, ahead of
-- its redraw). Installs the watch when the frame is there; otherwise, with
-- Auctionator loaded, polls for it until it is or the window closes, since
-- Auctionator's own OnShow can run after ours in the same event burst and
-- under TradeSkillMaster not until the player switches to the default
-- frame. A tick that installs redraws through the same coalesced path.
function GBL:_RestockOnAuctionHouseShown()
    if self:_RestockWatchShoppingTab() then return end
    if not self:IsAuctionatorReady() then return end
    if self._restockShoppingTabPoll then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    self:SystemInfo("Restock tab: watching for Auctionator's shopping frame every %ss", tostring(SHOPPING_TAB_POLL))
    self._restockShoppingTabPoll = C_Timer.NewTicker(SHOPPING_TAB_POLL, function()
        if not self:_RestockAuctionHouseOpen() then
            self:_RestockStopShoppingTabPoll()
        elseif self:_RestockWatchShoppingTab() then
            self:_RestockStopShoppingTabPoll()
            self:_RestockShoppingTabChanged()
        end
    end)
end

--- Stop the Shopping-frame poll, if one is running.
function GBL:_RestockStopShoppingTabPoll()
    local poll = self._restockShoppingTabPoll
    if not poll then return end
    self._restockShoppingTabPoll = nil
    if poll.Cancel then poll:Cancel() end
end

local SEARCH_BLOCKERS = {
    { key = "auctionator", short = "needs Auctionator",
      text = "Restock needs the Auctionator addon to search and buy. Targets still display below.",
      holds = function(self) return self:IsAuctionatorReady() end },
    { key = "ah-closed", short = "open the Auction House",
      text = "Open the Auction House to search.",
      holds = function(self) return self:_RestockAuctionHouseOpen() end },
    -- Until #194 moves the search to Auctionator's public entry, which
    -- selects the tab itself, the Shopping tab has to be on screen.
    { key = "shopping-tab", short = "open the Shopping tab",
      text = "Open the Auctionator Shopping tab first, then search.",
      holds = function()
          return AuctionatorShoppingFrame ~= nil and AuctionatorShoppingFrame.IsVisible ~= nil
              and AuctionatorShoppingFrame:IsVisible() and true or false
      end },
    { key = "no-scan", short = "scan the bank first",
      text = "Waiting on the bank scan. Open the guild bank, or click Scan bank, so in-bank counts are right.",
      holds = function(self, opts) return (opts.scanResults or self:GetLastScanResults()) ~= nil end },
    { key = "nothing", short = "nothing to buy",
      text = "Nothing to buy: the bank and the mail cover every layout item.",
      holds = function(self, opts, ctx)
          ctx.buyList = self:_RestockBuildBuyList(opts)
          return #ctx.buyList > 0
      end },
}

--- The first precondition a search fails, or nil when it can run (#211).
-- One reader for the button, the banner and StartRestockSearch, in one
-- order, so the reason on screen is the reason the click would print. When
-- every precondition holds the buy list the last one built comes back too,
-- so a click does not build it twice.
-- @param opts table|nil forwarded to _RestockBuildBuyList (tests inject)
-- @return table|nil { key, text, short }, table|nil buyList (when nil)
function GBL:_RestockSearchBlocker(opts)
    opts = opts or {}
    local ctx = {}
    for _, b in ipairs(SEARCH_BLOCKERS) do
        if not b.holds(self, opts, ctx) then
            return { key = b.key, text = b.text, short = b.short }
        end
    end
    return nil, ctx.buyList
end

-- Auctionator's SearchEnd event constant, or nil if the API moved.
local function searchEndEvent()
    return Auctionator and Auctionator.Shopping and Auctionator.Shopping.Tab
        and Auctionator.Shopping.Tab.Events and Auctionator.Shopping.Tab.Events.SearchEnd
end

--- Pure: the buy list for a search = enabled rows that are short of target.
-- @param opts table|nil forwarded to _RestockBuildItemUniverse (tests inject)
-- @return table array of { itemID, needed = toBuy }
function GBL:_RestockBuildBuyList(opts)
    local list = {}
    for _, row in ipairs(self:_RestockBuildItemUniverse(opts)) do
        if row.enabled and (row.toBuy or 0) > 0 then
            list[#list + 1] = { itemID = row.itemID, needed = row.toBuy }
        end
    end
    return list
end

--- Pair Auctionator result rows back to the active items by itemID, and
-- stamp each with whether it is a commodity when the client can say
-- (C_AuctionHouse.GetItemKeyInfo, guarded): a BoE or a pet in a display
-- tab comes back with a price like anything else, and the commodity start
-- fails on it. Without the API the row is left as the search sent it.
-- @param activeItems table array of { itemID, needed }
-- @param results table|nil Auctionator results, each { itemKey = {itemID}, minPrice }
-- @return table resultRows ([i] = row for activeItems[i]), number foundCount
function GBL:_RestockMapResults(activeItems, results)
    local resultRows = {}
    local found = 0
    if type(activeItems) ~= "table" or type(results) ~= "table" then
        return resultRows, found
    end
    local keyInfo = C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo
    for i, ref in ipairs(activeItems) do
        for _, row in ipairs(results) do
            if row.itemKey and row.itemKey.itemID == ref.itemID then
                if keyInfo then
                    local ok, info = pcall(keyInfo, row.itemKey)
                    if ok and type(info) == "table" and info.isCommodity ~= nil then
                        row.isCommodity = info.isCommodity and true or false
                    end
                end
                resultRows[i] = row
                found = found + 1
                break
            end
        end
    end
    return resultRows, found
end

-- Stable listener object; created once and reused so Unregister matches Register.
local function getSearchListener(self)
    if not self._restockListener then
        local addon = self
        self._restockListener = {
            ReceiveEvent = function(_listener, eventName, results)
                if eventName ~= searchEndEvent() then return end
                addon:_RestockOnSearchEnd(results)
            end,
        }
    end
    return self._restockListener
end

local function unregisterSearchListener(self)
    local st = self._restock
    if st and st.listenerRegistered and Auctionator and Auctionator.EventBus then
        local ev = searchEndEvent()
        if ev then
            Auctionator.EventBus:Unregister(getSearchListener(self), { ev })
        end
        st.listenerRegistered = false
    end
end

--- Start an Auctionator search for everything the bank is short on. Guards:
-- Auctionator present, its Shopping tab open, a bank scan available, and a
-- non-empty buy list. Fire-and-forget; verified in-game. Offered in IDLE and
-- READY (#214): a search from READY tears the old run down first, the same
-- teardown a reset runs, so an unanswered confirm is parked before the buy
-- events it would have been credited on are dropped; the pending store is
-- not part of the run and stays.
function GBL:StartRestockSearch()
    local state = self._restock and self._restock.state or "IDLE"
    if not self:_RestockStateReadsBlocker(state) then return end
    -- From READY the old run goes first, and the park it performs feeds the
    -- buy list built next: a parked quantity is in the mail, so the row is
    -- reduced or dropped rather than offered again (the review of PR B).
    if state == "READY" then
        self:_RestockSearchTeardown("new search")
    end
    -- The preconditions are one ordered list (#211): the tab disables Search
    -- on the first one that fails and shows its text, and a click that gets
    -- through anyway prints the same text. After a teardown there is no run
    -- to stay in, so a refused search settles to IDLE with the list intact.
    local blocker, buyList = self:_RestockSearchBlocker()
    if blocker then
        self:Print(blocker.text)
        if state == "READY" then
            self._restock.state = "IDLE"
            self:RefreshRestockTab()
        end
        return
    end
    local ev = searchEndEvent()
    if not ev then
        self:Print("Auctionator's search API changed; cannot search.")
        return
    end

    self._restock = self._restock or { state = "IDLE" }
    local st = self._restock
    st.activeItems = buyList
    st.resultRows = {}
    st.foundCount = 0
    st.searchGen = (st.searchGen or 0) + 1
    local thisGen = st.searchGen

    local listener = getSearchListener(self)
    Auctionator.EventBus:RegisterSource(listener, ADDON_NAME)
    Auctionator.EventBus:Register(listener, { ev })
    st.listenerRegistered = true

    st.state = "SEARCHING"
    self:RefreshRestockTab()
    self:_RestockResolveNamesAndSearch(thisGen)
end

--- Resolve item names async (Auctionator searches by name), then fire the
-- search. The searchGen guard drops callbacks from a cancelled/restarted run.
function GBL:_RestockResolveNamesAndSearch(thisGen)
    local st = self._restock
    if not st then return end
    local items = st.activeItems or {}
    local pending = #items
    local names = {}
    if pending == 0 then return end
    for i, ref in ipairs(items) do
        local itemObj = Item and Item.CreateFromItemID and Item:CreateFromItemID(ref.itemID)
        if itemObj and itemObj.ContinueOnItemLoad then
            itemObj:ContinueOnItemLoad(function()
                if not self._restock or self._restock.searchGen ~= thisGen then return end
                names[i] = itemObj:GetItemName()
                pending = pending - 1
                if pending == 0 then
                    self:_RestockFireSearch(names, thisGen)
                end
            end)
        else
            -- No async item API (should not happen in-game); still converge so
            -- the search can fire with whatever names resolved.
            pending = pending - 1
            if pending == 0 then
                self:_RestockFireSearch(names, thisGen)
            end
        end
    end
end

--- Build Auctionator search strings from resolved names and fire one batch
-- search. Failure paths recover to IDLE so the tab cannot get stuck showing
-- "Searching..." with no SearchEnd ever arriving.
function GBL:_RestockFireSearch(names, thisGen)
    local st = self._restock
    if not st or st.searchGen ~= thisGen then return end
    if not self:IsAuctionatorReady() then
        self:Print("Auctionator became unavailable; search cancelled.")
        self:ResetRestockSearch()
        self:RefreshRestockTab()
        return
    end
    local terms = {}
    for _, name in pairs(names or {}) do
        if type(name) == "string" and name ~= "" then
            local ok, term = pcall(Auctionator.API.v1.ConvertToSearchString, ADDON_NAME,
                { searchString = name, isExact = true })
            if ok and term then
                terms[#terms + 1] = term
            end
        end
    end
    if #terms == 0 then
        self:Print("Could not build a search; item names did not load. Try again.")
        self:ResetRestockSearch()
        self:RefreshRestockTab()
        return
    end
    if not (AuctionatorShoppingFrame and AuctionatorShoppingFrame.DoSearch) then
        self:Print("Auctionator's search frame is unavailable; search cancelled.")
        self:ResetRestockSearch()
        self:RefreshRestockTab()
        return
    end
    if not pcall(function() AuctionatorShoppingFrame:DoSearch(terms) end) then
        self:Print("Auctionator search failed; try again.")
        self:ResetRestockSearch()
        self:RefreshRestockTab()
    end
end

-- A confirm whose result this search will never see (#209): the unanswered
-- record, or the purchase in flight when a reset unregisters the buy events
-- after its confirm went out. The gold may have moved, so it goes into the
-- pending store flagged unconfirmed instead of being forgotten. Three sites
-- since #215: _RestockOnStepTimeout and CancelRestockPurchase park at the
-- moment they create the record, and this one is the retry for a park the
-- store could not take yet, reached from the teardown that a reset and a
-- Search from READY share.
local function parkUnanswered(self, st)
    local u = st.unanswered
    if u then
        -- Parked at the moment it was created (#215), so this is only the
        -- retry for a park the store refused. The record is kept when the
        -- retry is refused too: it used to be nilled before the add and the
        -- boolean ignored, so a cold guild name forgot the purchase with no
        -- line anywhere.
        local added, why = true, nil
        if not u.parked then
            added, why = self:_RestockAddPending(u.itemID, u.qty, { unconfirmed = true })
        end
        -- Keeping the record blocks every buy, and this same teardown drops
        -- the buy events, so no result can arrive to clear it. That is only
        -- worth paying while a retry could still succeed. Nothing to record
        -- never can, so it is dropped with a line rather than wedging the
        -- flow for the session over a purchase the store cannot describe.
        if added or why == "nothing-to-record" then
            st.unanswered = nil
        end
        if not added then
            self:SystemWarn("Restock pending: it:%s x%s not recorded (%s)%s",
                tostring(u.itemID), tostring(u.qty), tostring(why),
                why == "no-store"
                    and "; retried when the Restock tab is next shown" or "")
        end
    end
    if st.state == "CONFIRMING" and st.confirmIssued and st.pendingItemID then
        self:_RestockAddPending(st.pendingItemID, st.pendingQty, { unconfirmed = true })
    end
end

-- The per-run progress, cleared when a search ends and when a run is torn
-- down: what was bought and skipped, the step flags, the spend (#60:
-- spentEstimate is what this search has spent, the priced total of each
-- success, and is what Spent and the budget read; the wallet baseline pair
-- bounds affordability while the wallet trails the purchase events).
local function clearRunProgress(st)
    st.bought = {}
    st.boughtTotal = {}
    st.skipped = {}
    st.buyAll = false
    st.confirmIssued = false
    st.priceIn = false
    st.throttleBusy = false
    st.cancelledStartDue = nil
    st.spentEstimate = 0
    st.spentAtBase = 0
end

--- Auctionator finished a search: map results to the active items, go READY.
function GBL:_RestockOnSearchEnd(results)
    local st = self._restock
    if not st or st.state ~= "SEARCHING" then return end
    unregisterSearchListener(self)
    local resultRows, found = self:_RestockMapResults(st.activeItems, results)
    st.resultRows = resultRows
    st.foundCount = found
    clearRunProgress(st)
    -- The baseline moves again only on tab show.
    st.walletBase = (GetMoney and GetMoney()) or 0
    st.state = "READY"
    self:RefreshRestockTab()
end

-- Every auction-house event the buy flow registers (#199). Registered on the
-- first buy and dropped on reset, so idle play at the auction house logs
-- nothing. Exported so the spec can pin a handler for each name: AceEvent
-- errors on a registration with no method, the mock does not.
local AH_EVENTS = {
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
    "COMMODITY_PRICE_UPDATED",
    "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED",
    "UI_ERROR_MESSAGE",
}
GBL._restockAHEvents = AH_EVENTS

-- The client's own throttle predicate, read for the log only (#199): nothing
-- is gated on it until a capture has shown what it reads around our calls.
local function throttleReadyText()
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
        local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if ok then return tostring(ready) end
    end
    return "na"
end

-- One system-channel line per auction-house event or flow step (#199), written
-- AFTER the decision it reports so the line says what happened. Restock has no
-- channel of its own; the system channel is captured, so a Buy all that stops
-- on Confirming purchase can be read back from the SavedVariables. busy= is
-- this flow's own throttle flag (below); ready= is the client's.
local function ahLog(self, what, detail)
    local st = self._restock
    local pending = "none"
    if st and st.pendingItemID then
        pending = format("it:%d x%d", st.pendingItemID, st.pendingQty or 0)
    end
    local elapsed = 0
    if st and st.stepStartedAt and GetTime then
        elapsed = GetTime() - st.stepStartedAt
    end
    self:SystemInfo("Restock AH: %s state=%s pending=%s t=+%.2fs busy=%s ready=%s%s",
        what, (st and st.state) or "none", pending, elapsed,
        (st and st.throttleBusy) and "yes" or "no", throttleReadyText(),
        detail and (" " .. detail) or "")
end

-- True while a purchase is in flight (CONFIRMING, or PRICED with a quote
-- waiting for the click): the window the throttle family and
-- UI_ERROR_MESSAGE are logged in, and the window the wallet baseline may
-- not move in.
local function purchaseInFlight(self)
    local st = self._restock
    return st ~= nil and (st.state == "CONFIRMING" or st.state == "PRICED")
end

-- The step timer (#199): one cancellable one-shot per arm, the repo's
-- C_Timer.NewTicker(n, cb, 1) idiom (src/Sync.lua), since C_Timer.After hands
-- back nothing to cancel. Every arm replaces the last, and every settled step
-- and a reset cancel it. One slot for every wait: a start or a confirm arms
-- it at STEP_TIMEOUT, a quote waiting for the click at PAUSE_TIMEOUT.
local function cancelStepTimer(self)
    local st = self._restock
    if st and st.stepTimer then
        if st.stepTimer.Cancel then st.stepTimer:Cancel() end
        st.stepTimer = nil
    end
end

local function armStepTimer(self, seconds)
    local st = self._restock
    cancelStepTimer(self)
    if not st or not (C_Timer and C_Timer.NewTicker) then return end
    st.stepTimer = C_Timer.NewTicker(seconds or STEP_TIMEOUT, function()
        self:_RestockOnStepTimeout()
    end, 1)
end

-- Forget the purchase in flight. The unanswered record (a confirm that got no
-- result) is deliberately not part of this: it outlives the step.
local function clearPending(st)
    st.confirmIssued = false
    st.priceIn = false
    st.pendingIndex = nil
    st.pendingItemID = nil
    st.pendingQty = nil
    st.pendingTotal = nil
    st.errorNote = nil
    st.focusConfirm = nil
end

-- Drop the purchase in flight before its confirm is out (#211): the cancel
-- at the auction house, the timer, the pending fields, back to READY with
-- the list intact. The start's own price may still be on its way (the cancel
-- is queued behind the start's response), so until that start's READY the
-- next price event is its answer and not the next purchase's:
-- cancelledStartDue says so and the READY handler clears it.
local function dropUnconfirmed(self, st, logWhat, logDetail)
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    if st.state == "CONFIRMING" and not st.priceIn then
        st.cancelledStartDue = true
    end
    ahLog(self, logWhat, logDetail)
    cancelStepTimer(self)
    clearPending(st)
    st.buyAll = false
    st.state = "READY"
end

--- Tear the run down (#214): park an unanswered confirm, drop a purchase that
-- has not been confirmed, unregister listeners and buy events, stop any
-- in-flight Auctionator search, invalidate stale async callbacks, and clear
-- results and buy progress. Leaves the state where it was: a reset then
-- goes to IDLE, a Search from READY goes on to SEARCHING. logWhat is the
-- log line's word: "reset" (Cancel, a failed search) or "new search".
function GBL:_RestockSearchTeardown(logWhat)
    self._restock = self._restock or { state = "IDLE" }
    local st = self._restock
    parkUnanswered(self, st)
    local note
    if purchaseInFlight(self) and st.pendingItemID then
        if st.confirmIssued then
            -- The gold is committed or refused server-side by now; a cancel
            -- here changes nothing (Auctionator never cancels after a confirm).
            note = "confirm already issued, no cancel"
        elseif C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
            C_AuctionHouse.CancelCommoditiesPurchase()
            note = "cancel issued"
        else
            note = "no cancel API"
        end
    end
    ahLog(self, logWhat or "reset", note)
    cancelStepTimer(self)
    unregisterSearchListener(self)
    self:_RestockUnregisterBuyEvents()
    if st.state ~= "IDLE" and AuctionatorShoppingFrame and AuctionatorShoppingFrame.StopSearch then
        pcall(function() AuctionatorShoppingFrame:StopSearch() end)
    end
    st.searchGen = (st.searchGen or 0) + 1
    st.activeItems = {}
    st.resultRows = {}
    st.foundCount = 0
    clearPending(st)
    -- st.unanswered is parkUnanswered's to clear, above: it keeps the record
    -- when the store refused the park, and clearing it here unconditionally
    -- was the third way a purchase was forgotten with no line (#215).
    clearRunProgress(st)
end

--- Reset the search/buy back to IDLE: the teardown, then IDLE. The path a
-- failed search and Cancel in SEARCHING take; Done went with #214.
function GBL:ResetRestockSearch()
    self:_RestockSearchTeardown()
    self._restock.state = "IDLE"
end

------------------------------------------------------------------------
-- Buy / confirm flow (READY -> CONFIRMING [-> PRICED -> CONFIRMING] -> READY,
-- one purchase per click since #199)
-- Per-item buys and Buy next (one purchase per click, walking the list past
-- rows the pre-start checks refuse), ported from GBR's sweep. Spends real
-- gold via C_AuctionHouse commodities; the budget cap, the wallet and budget
-- re-check against the priced total, the confirm-at-price pause and in-game
-- verification are the safeguards. The COMMODITY/THROTTLED handlers are
-- registered lazily on the first buy and unregistered in ResetRestockSearch.
--
-- Two rules, one per call (#199). A start goes out only from a click: it needs
-- a hardware event, and a click that lands while the throttle is busy starts
-- at once rather than waiting, since the client queues it and waiting would
-- lose the event. A confirm goes out on the THROTTLED_SYSTEM_READY that
-- follows the price: every start and confirm sets throttleBusy, the READY
-- after each response clears it, and a confirm that comes due while it is set
-- (the price event with the pause off, the Confirm click with it on) is
-- handed to the next READY. That is the one seam; no caller decides for
-- itself whether the throttle is free.
------------------------------------------------------------------------

local COPPER_PER_GOLD = 10000

--- True when a positive budget (gold) has been reached by the spent copper.
function GBL:_RestockBudgetExceeded(spentCopper, budgetGold)
    budgetGold = budgetGold or 0
    if budgetGold <= 0 then return false end
    return (spentCopper or 0) >= budgetGold * COPPER_PER_GOLD
end

--- Whether row i of the search can be bought (#214, one predicate for Buy
-- next, its count, and the tab's Buy buttons): a result with a usable price
-- on a commodity (a BoE or a pet comes back priced too, and the commodity
-- start fails on it), not bought, not skipped, a quantity to buy, and no
-- confirm of this search still waiting for its result (nothing starts
-- until that lands, so nothing is offered either).
-- @param st table the session state
-- @param i number index into activeItems
-- @return boolean
function GBL:_RestockRowBuyable(st, i)
    if not st or type(st.activeItems) ~= "table" then return false end
    local ref = st.activeItems[i]
    local row = st.resultRows and st.resultRows[i]
    if not ref or not row then return false end
    if type(row.minPrice) ~= "number" or row.minPrice <= 0 then return false end
    if row.isCommodity == false then return false end
    if (st.bought or {})[i] or (st.skipped or {})[i] then return false end
    if (ref.needed or 0) <= 0 then return false end
    if st.unanswered then return false end
    return true
end

--- First index eligible to buy.
function GBL:_RestockNextBuyable(st)
    if not st or type(st.activeItems) ~= "table" then return nil end
    for i in ipairs(st.activeItems) do
        if self:_RestockRowBuyable(st, i) then return i end
    end
    return nil
end

--- How many rows _RestockNextBuyable would still accept: the Buy next label.
function GBL:_RestockBuyableCount(st)
    if not st or type(st.activeItems) ~= "table" then return 0 end
    local n = 0
    for i in ipairs(st.activeItems) do
        if self:_RestockRowBuyable(st, i) then n = n + 1 end
    end
    return n
end

function GBL:_RestockRegisterBuyEvents()
    local st = self._restock
    if st and not st.buyEventsRegistered then
        for _, ev in ipairs(AH_EVENTS) do
            self:RegisterEvent(ev)
        end
        st.buyEventsRegistered = true
    end
end

function GBL:_RestockUnregisterBuyEvents()
    if self._restock and self._restock.buyEventsRegistered then
        for _, ev in ipairs(AH_EVENTS) do
            self:UnregisterEvent(ev)
        end
        self._restock.buyEventsRegistered = false
    end
end

-- Spent copper for the active search (#60): the priced total of each success,
-- added by creditPurchase. Exact for every purchase the flow made and blind
-- to everything else, which is the point: the wallet delta it replaced
-- counted gold spent anywhere while the window was closed, and greyed every
-- Buy button against a budget the search had never touched.
local function spentCopper(self)
    local st = self._restock
    if not st then return 0 end
    return st.spentEstimate or 0
end

-- Conservative remaining gold for affordability checks: GetMoney can read high
-- in the lag right after a purchase, so remaining is also bounded by the
-- wallet baseline less what has been spent since it was taken. The baseline
-- is a pair (walletBase, spentAtBase) so that moving it on tab show cannot
-- count a purchase twice: a baseline of the debited wallet alone, against
-- the search's whole spend, refused rows the wallet could cover.
local function affordableMoney(self)
    local wallet = (GetMoney and GetMoney()) or 0
    local st = self._restock
    if not st or not st.walletBase then return wallet end
    local lagFree = st.walletBase - (spentCopper(self) - (st.spentAtBase or 0))
    if lagFree < wallet then return lagFree end
    return wallet
end

--- The Restock tab was shown (#60): with nothing in flight, the wallet
-- baseline moves to the wallet as it is now, paired with the spend so far,
-- so gold spent elsewhere while the window was closed neither counts as
-- this search's spend nor refuses a row the wallet can cover. Called from
-- SelectTab, never from the rebuild a purchase result triggers, so the
-- lag-free bound survives the moment it exists for.
function GBL:_RestockOnTabShown()
    local st = self._restock
    if not st or purchaseInFlight(self) then return end
    -- A park the store refused blocks every buy and cannot be cleared by
    -- a result, because the teardown that refused it dropped the buy
    -- events. This is the first moment the store is reachable again.
    local u = st.unanswered
    if u and not u.parked then
        if self:_RestockAddPending(u.itemID, u.qty, { unconfirmed = true }) then
            st.unanswered = nil
        end
    end
    st.walletBase = (GetMoney and GetMoney()) or 0
    st.spentAtBase = st.spentEstimate or 0
end

local function itemName(self, itemID)
    local name = self.GetCachedItemInfo and itemID and self:GetCachedItemInfo(itemID)
    return name or ("item " .. tostring(itemID))
end

-- Mark a row bought, add what it cost to the lag-free spend estimate (the
-- priced total when the price event carried one, else the lowest-price lower
-- bound), and remember the purchase past this search (#209).
-- opts.settle marks the late credit for a purchase the step timer already
-- parked (#215): the quantity is already standing in the store, so it moves
-- to the confirmed part instead of being added a second time. A park that
-- was refused leaves nothing to settle, and the add is the fallback.
local function creditPurchase(self, st, index, itemID, total, qty, opts)
    if not index then return end
    st.bought = st.bought or {}
    st.bought[index] = true
    local row = st.resultRows and st.resultRows[index]
    local minPrice = (row and row.minPrice) or 0
    local cost = total or (minPrice * (qty or 0))
    st.boughtTotal = st.boughtTotal or {}
    st.boughtTotal[index] = cost
    st.spentEstimate = (st.spentEstimate or 0) + cost
    -- Settling is not a try-then-add: movePending also returns false when
    -- the parked quantity is simply gone, which a hand Clear and a
    -- settling deposit both do, and adding there reversed the player's own
    -- Clear or counted bank stock as still in the mail. opts.settle is the
    -- park having landed, so the add belongs to the other branch only.
    if opts and opts.settle then
        self:_RestockSettlePending(itemID, qty)
    else
        self:_RestockAddPending(itemID, qty)
    end
end

-- Settle a sweep, or a deferred single buy, back to READY.
local function stopRun(self)
    local st = self._restock
    st.buyAll = false
    st.state = "READY"
    self:RefreshRestockTab()
end

-- A step the flow will not confirm (#199): drop the purchase at the auction
-- house (nothing has been spent), say why, and move on. Reached from a price
-- that never came, a price that came back unavailable or unusable, and a
-- price the wallet or the budget refuses. Only Buy next marks the row skipped;
-- a single buy leaves it buyable, as the pre-start refusals do, since every
-- one of these can be transient. opts.keepRow leaves the row buyable under
-- Buy next too, for a step the player rather than the auction house ended
-- (a quote nobody confirmed).
local function failStep(self, reason, chatText, opts)
    local st = self._restock
    if not st then return end
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    if st.buyAll and st.pendingIndex and not (opts and opts.keepRow) then
        st.skipped = st.skipped or {}
        st.skipped[st.pendingIndex] = reason
    end
    self:Print(format("Did not buy %s: %s", itemName(self, st.pendingItemID), chatText))
    ahLog(self, "step failed", reason)
    cancelStepTimer(self)
    clearPending(st)
    self:_RestockAfterStep()
end

-- The confirm for the purchase in flight. Called only with the price in and
-- the throttle free, from whichever of the two arrived second.
local function issueConfirm(self, via, prefix)
    local st = self._restock
    if not (C_AuctionHouse and C_AuctionHouse.ConfirmCommoditiesPurchase) then
        ahLog(self, via, (prefix and (prefix .. " ") or "") .. "ignored (no confirm API)")
        return
    end
    st.confirmIssued = true
    st.throttleBusy = true
    ahLog(self, via, (prefix and (prefix .. " ") or "") .. "confirm issued")
    armStepTimer(self)
    C_AuctionHouse.ConfirmCommoditiesPurchase(st.pendingItemID, st.pendingQty)
end

--- Begin a commodity purchase for activeItems[index]. Handles the maxPrice skip
-- and the budget cap; on a real buy it goes CONFIRMING and waits for the WoW
-- events to price, confirm and report the result. Returns true when the start
-- went out and false from every pre-start refusal, which marks the row skipped
-- under Buy next. Called from a click handler and nowhere else (#199): the
-- start requires a hardware event, so a call from an event or a timer would
-- do nothing and the row would be given up on five seconds later.
function GBL:_RestockBeginPurchase(index)
    local st = self._restock
    if not st or st.state ~= "READY" then return false end
    local ref = st.activeItems and st.activeItems[index]
    local row = st.resultRows and st.resultRows[index]
    if not ref or not row or (st.bought and st.bought[index]) or (ref.needed or 0) <= 0 then
        return false
    end

    -- A confirm that got no result is still outstanding: its late result
    -- would be credited to whatever purchase was in flight, so nothing starts
    -- until it lands or the run is reset.
    if st.unanswered then
        self:Print(format("Waiting on the result of %s; check your mail, then search "
            .. "again to buy more.", itemName(self, st.unanswered.itemID)))
        ahLog(self, "skip", format("it:%d result outstanding for it:%d", ref.itemID, st.unanswered.itemID))
        stopRun(self)
        return false
    end

    -- Not a commodity (the item key said so at SearchEnd): the commodity
    -- start would fail on it. Marks nothing, like the gate below; the row
    -- reads "buy it by hand" and Buy next walks past it.
    if row.isCommodity == false then
        self:Print(format("%s is not a commodity; buy it by hand at the Auction House.",
            itemName(self, ref.itemID)))
        ahLog(self, "skip", format("it:%d not a commodity", ref.itemID))
        return false
    end

    -- Per-item maxPrice cap (override; no input UI yet, so usually unset).
    local override = self:GetRestockItemOverride(ref.itemID)
    local maxPrice = override and override.maxPrice
    if maxPrice and maxPrice > 0 and row.minPrice and row.minPrice > maxPrice * COPPER_PER_GOLD then
        st.skipped[index] = SKIP.MAX_PRICE
        self:Print(format("Skipped %s: lowest price is over your max of %d g.",
            itemName(self, ref.itemID), maxPrice))
        ahLog(self, "skip", format("it:%d %s", ref.itemID, SKIP.MAX_PRICE))
        return false
    end

    local budget = self:GetRestockBudget()
    -- Budget cap (already reached): stop the run.
    if self:_RestockBudgetExceeded(spentCopper(self), budget) then
        self:Print(format("Budget of %d g reached; stopping.", budget))
        ahLog(self, "skip", format("it:%d budget reached", ref.itemID))
        st.buyAll = false
        return false
    end
    -- Budget cap (this buy): skip an item whose estimated cost (lowest price x
    -- quantity, a lower bound) would push spend past the budget.
    local estCost = (row.minPrice or 0) * (ref.needed or 0)
    if budget > 0 and (spentCopper(self) + estCost) > budget * COPPER_PER_GOLD then
        self:Print(format("Skipping %s: it would exceed your budget of %d g.",
            itemName(self, ref.itemID), budget))
        ahLog(self, "skip", format("it:%d %s", ref.itemID, SKIP.BUDGET_THIS_BUY))
        if st.buyAll then st.skipped[index] = SKIP.BUDGET_THIS_BUY end
        return false
    end

    -- Affordability: never attempt a purchase the wallet cannot cover. estCost
    -- is a lower bound (price climbs as you buy up listings), which catches the
    -- clear cases; the priced total is checked again when it arrives. Uses the
    -- lag-safe remaining estimate so Buy next cannot outrun the wallet update.
    local money = affordableMoney(self)
    if estCost > money then
        self:Print(format("Not enough gold for %s: need about %s, have %s.",
            itemName(self, ref.itemID), self:FormatMoney(estCost), self:FormatMoney(money)))
        ahLog(self, "skip", format("it:%d %s", ref.itemID, SKIP.CANNOT_AFFORD))
        if st.buyAll then st.skipped[index] = SKIP.CANNOT_AFFORD end
        return false
    end

    -- The gate (#211): a start at the bank would go into nothing and the step
    -- timer would give the row up five seconds later. Marks nothing, like the
    -- no-API exit below, so a Buy next walk ends on the same row coming back
    -- (the tried guard in StartRestockBuyNext) rather than refusing every row.
    if not self:_RestockAuctionHouseOpen() then
        self:Print("Open the Auction House to buy.")
        ahLog(self, "skip", format("it:%d auction house not open", ref.itemID))
        return false
    end
    if not (C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase) then
        self:Print("Open the Auction House to buy.")
        ahLog(self, "skip", format("it:%d no auction-house API", ref.itemID))
        return false
    end

    -- No deferral on a busy throttle: the click is the hardware event the
    -- start needs, and waiting for the READY would lose it. The client queues
    -- a throttled message issued while busy (QUEUED, then SENT once free).
    self:_RestockRegisterBuyEvents()
    st.pendingIndex = index
    st.pendingItemID = (row.itemKey and row.itemKey.itemID) or ref.itemID
    st.pendingQty = ref.needed
    st.pendingTotal = nil
    st.priceIn = false
    st.confirmIssued = false
    st.errorNote = nil
    st.stepStartedAt = (GetTime and GetTime()) or nil
    st.state = "CONFIRMING"
    st.throttleBusy = true
    ahLog(self, "start", st.buyAll and "via=next" or "via=row")
    armStepTimer(self)
    C_AuctionHouse.StartCommoditiesPurchase(st.pendingItemID, st.pendingQty)
    self:RefreshRestockTab()
    return true
end

--- After a purchase settles (a result, a refused price, a timeout): back to
-- READY, and one line saying what the next click will find. Starts nothing:
-- this runs from event handlers and the step timer, and a start from either
-- does nothing (#199).
function GBL:_RestockAfterStep()
    local st = self._restock
    if not st then return end
    st.state = "READY"
    local buyNext = st.buyAll
    st.buyAll = false
    if not buyNext then
        ahLog(self, "step done", "single")
    elseif self:_RestockBudgetExceeded(spentCopper(self), self:GetRestockBudget()) then
        self:Print("Budget reached; stopping.")
        ahLog(self, "step done", "budget reached")
    else
        local nextIndex = self:_RestockNextBuyable(st)
        if nextIndex then
            ahLog(self, "step done", format("next=%d awaiting click", nextIndex))
        else
            self:Print("Nothing left to buy.")
            ahLog(self, "step done", "list done")
        end
    end
    self:RefreshRestockTab()
end

--- The step timer fired (#199): the auction house did not answer within
-- STEP_TIMEOUT. Two cases with two outcomes. No price after a start: nothing
-- was spent, so cancel and settle. No result after a confirm: the gold may
-- have moved and a cancel means nothing now, so the purchase is kept as
-- unanswered, which credits its late result and blocks new starts, the run
-- stops, and the player is told to check the mail.
function GBL:_RestockOnStepTimeout()
    local st = self._restock
    if not st then return end
    st.stepTimer = nil
    if st.state == "PRICED" then
        -- The quote waited PAUSE_TIMEOUT for a click that never came (#211).
        -- Nothing was spent, and the row stays buyable: the next click quotes
        -- it again, so a Buy next run is not marked skipped for it.
        failStep(self, "quote expired",
            format("the quote expired after %d seconds; click Buy again.", PAUSE_TIMEOUT),
            { keepRow = true })
    elseif st.state == "CONFIRMING" and st.priceIn and not st.confirmIssued then
        -- A Confirm click found the throttle busy and its READY never came.
        failStep(self, "throttle never freed",
            "the auction house never freed up for the confirm; click Buy again.",
            { keepRow = true })
    elseif st.state == "CONFIRMING" and not st.confirmIssued then
        failStep(self, SKIP.NO_PRICE_IN_TIME,
            format("the auction house did not price it within %d seconds.", STEP_TIMEOUT))
    elseif st.state == "CONFIRMING" then
        st.unanswered = {
            index = st.pendingIndex, itemID = st.pendingItemID,
            qty = st.pendingQty, total = st.pendingTotal,
        }
        -- Park it now (#215). This record used to live only on _restock and
        -- reach the store through a teardown the player may never run, so a
        -- reload forgot it and the next search offered the row again. The
        -- marker stays for the late result, which settles the parked
        -- quantity rather than adding a second one.
        st.unanswered.parked = self:_RestockAddPending(
            st.pendingItemID, st.pendingQty, { unconfirmed = true })
        local note = ""
        if st.errorNote then
            note = format(" The auction house reported: %s.", st.errorNote)
        end
        self:Print(format("No result for %s within %d seconds; stopping.%s "
            .. "Check your mail before buying it again.",
            itemName(self, st.pendingItemID), STEP_TIMEOUT, note))
        ahLog(self, "step failed", format("no result within %ds", STEP_TIMEOUT))
        clearPending(st)
        stopRun(self)
    end
end

--- Buy a single item (per-item button; a click).
function GBL:StartRestockBuy(index)
    local st = self._restock
    if not st or st.state ~= "READY" then return end
    st.buyAll = false
    if not self:_RestockBeginPurchase(index) then
        self:RefreshRestockTab()
    end
end

--- Buy next (a click): start the first row the pre-start checks accept,
-- walking past the ones they refuse inside this same click. One purchase per
-- click, because the start needs the click (#199). Spending is bounded by
-- affordability (the wallet) and, if one is set, the budget cap.
function GBL:StartRestockBuyNext()
    local st = self._restock
    if not st or st.state ~= "READY" then return end
    st.buyAll = true
    -- No row is buyable while a confirm of this search awaits its result
    -- (the tab greys every Buy and counts none), so a click that lands
    -- anyway says why once rather than walking an empty list in silence.
    if st.unanswered then
        self:Print(format("Waiting on the result of %s; check your mail, then search "
            .. "again to buy more.", itemName(self, st.unanswered.itemID)))
        ahLog(self, "skip", format("result outstanding for it:%d", st.unanswered.itemID))
        stopRun(self)
        return
    end
    local tried = {}
    local started = false
    while true do
        local index = self:_RestockNextBuyable(st)
        -- The no-API refusal marks nothing and clears nothing, so a row that
        -- came back once ends the walk rather than spinning on it.
        if not index or tried[index] or not st.buyAll then break end
        tried[index] = true
        if self:_RestockBeginPurchase(index) then
            started = true
            break
        end
    end
    if not started then
        if not next(tried) then self:Print("Nothing left to buy.") end
        st.buyAll = false
        self:RefreshRestockTab()
    end
end

--- Confirm the quoted purchase (the Confirm button; a click). PRICED only.
-- The confirm needs no hardware event, so it goes out here when the throttle
-- is free and is handed to the next THROTTLED_SYSTEM_READY when it is not,
-- with the step timer armed either way so a READY that never comes cannot
-- leave the purchase waiting (#211).
function GBL:ConfirmRestockPurchase()
    local st = self._restock
    if not st or st.state ~= "PRICED" then return end
    if not self:_RestockAuctionHouseOpen() then
        self:Print("Open the Auction House to buy.")
        ahLog(self, "confirm click", "ignored (auction house not open)")
        return
    end
    -- The quote passed the budget and the wallet when it arrived; both can
    -- have moved during the pause (a budget change, gold spent elsewhere), so
    -- the click reads them again (the review of PR B).
    local total = st.pendingTotal or 0
    local budget = self:GetRestockBudget()
    if budget > 0 and (spentCopper(self) + total) > budget * COPPER_PER_GOLD then
        ahLog(self, "confirm click", "refused (budget at price)")
        failStep(self, SKIP.BUDGET_AT_PRICE,
            format("the quote of %s is past your budget of %d g.", self:FormatMoney(total), budget))
        return
    end
    if total > affordableMoney(self) then
        ahLog(self, "confirm click", "refused (cannot afford at price)")
        failStep(self, SKIP.CANNOT_AFFORD_AT_PRICE,
            format("the quote of %s is more than you have.", self:FormatMoney(total)))
        return
    end
    st.state = "CONFIRMING"
    if st.throttleBusy then
        ahLog(self, "confirm click", "confirm waits for ready")
        armStepTimer(self)
    else
        issueConfirm(self, "confirm click")
    end
    self:RefreshRestockTab()
end

--- Drop the purchase in flight (the Cancel button in CONFIRMING and PRICED;
-- a click) and return to READY with the list intact (#211). Before the
-- confirm is out the purchase is cancelled at the auction house and nothing
-- was spent; after it, a cancel means nothing (Auctionator never cancels
-- after a confirm) and the purchase becomes the unanswered record the
-- result timeout keeps: no new start until its result lands, the late
-- result credits it. **It is also parked as pending here, from #215.** PR A
-- declined to park at this point because parking then replaced the
-- unanswered record, which left the row buyable and let the late result
-- land on the next purchase. Both are set now, so _RestockRowBuyable still
-- refuses every row while the record stands, and what the parked entry
-- buys is a purchase a reload cannot lose.
function GBL:CancelRestockPurchase()
    local st = self._restock
    if not st or not purchaseInFlight(self) then return end
    local wasState = st.state
    if st.confirmIssued and st.pendingItemID then
        st.unanswered = {
            index = st.pendingIndex, itemID = st.pendingItemID,
            qty = st.pendingQty, total = st.pendingTotal,
        }
        -- Parked at the click, like the step timeout (#215): the gold may
        -- have moved and a reload before the next teardown would forget it.
        st.unanswered.parked = self:_RestockAddPending(
            st.pendingItemID, st.pendingQty, { unconfirmed = true })
        ahLog(self, "cancelled", format("state=%s confirm already issued, kept as unanswered", wasState))
        self:Print(format("The confirm for %s is already out; waiting for its result. "
            .. "Check your mail before buying it again.", itemName(self, st.pendingItemID)))
        cancelStepTimer(self)
        clearPending(st)
        st.buyAll = false
        st.state = "READY"
    else
        dropUnconfirmed(self, st, "cancelled", format("state=%s cancel issued", wasState))
    end
    self:RefreshRestockTab()
end

--- The auction house closed with a purchase in flight (#211; called from
-- Core's OnAuctionHouseToggled). A quote, or a start still waiting for its
-- price, is dropped: the server discards its pending purchase on close, so a
-- Confirm after the house reopens would confirm nothing and end as a phantom
-- unanswered record. A confirm already out is left to its result and the
-- step timer, as anywhere else.
function GBL:_RestockOnAuctionHouseClosed()
    self:_RestockStopShoppingTabPoll()
    local st = self._restock
    if not st then return end
    if purchaseInFlight(self) and not st.confirmIssued then
        local item = itemName(self, st.pendingItemID)
        dropUnconfirmed(self, st, "cancelled (auction house window closed)", format("state=%s", st.state))
        -- No price follows a closed house, and the flag must not eat the next
        -- start's price after it reopens.
        st.cancelledStartDue = nil
        self:Print(format("The Auction House window closed; the purchase of %s was dropped "
            .. "and nothing was spent.", item))
    end
    -- With nothing in flight no result can arrive on a closed session, so
    -- the buy events go rather than logging every purchase the player makes
    -- by hand until the next reset; the next start registers them again. A
    -- confirm still out keeps them for its result and the step timer.
    if not purchaseInFlight(self) then
        self:_RestockUnregisterBuyEvents()
    end
end

--- WoW commodity events (registered lazily).

-- The throttle is free again: the flag clears, and a confirm whose price is
-- in goes out. It fires for every addon's calls, so with nothing in flight it
-- is silent.
function GBL:AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    local st = self._restock
    if not st then return end
    st.throttleBusy = false
    -- A cancelled start's response cycle ends here: whatever price it was
    -- going to send has come or never will.
    st.cancelledStartDue = nil
    if st.state == "PRICED" then
        ahLog(self, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "ignored (quote awaits confirm)")
        return
    end
    if st.state ~= "CONFIRMING" then return end
    if st.confirmIssued then
        ahLog(self, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "ignored (already issued)")
    elseif st.priceIn then
        issueConfirm(self, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    else
        ahLog(self, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "ignored (confirm waits for price)")
    end
end

-- A price event while our quote waits for the click (#211): the events carry
-- no item, so it is either the server re-quoting or another addon's start,
-- and the client holds one commodity purchase at a time, so in the second
-- case ours is gone. Either way the quote on the banner is not the one to
-- confirm: drop the pause and let the next click quote again. No cancel goes
-- out, since it would cancel whatever the server holds now.
local function supersededQuote(self, event, prefix)
    local st = self._restock
    ahLog(self, event, (prefix and (prefix .. " ") or "") .. "ignored (quote superseded, pause ended)")
    self:Print(format("The quote for %s changed or another purchase started; click Buy again.",
        itemName(self, st.pendingItemID)))
    cancelStepTimer(self)
    clearPending(st)
    st.buyAll = false
    st.state = "READY"
    self:RefreshRestockTab()
end

-- A purchase result while our quote waits for the click (#211): no confirm of
-- ours is out in PRICED, so the result is another addon's purchase, and the
-- client holds one commodity purchase at a time, so ours was replaced at the
-- server when theirs started. Credit nothing, drop the pause, and say so.
local function foreignResultInPause(self, event)
    local st = self._restock
    ahLog(self, event, "ignored (foreign, pause ended)")
    self:Print(format("The Auction House completed a different purchase; the quote for %s was dropped.",
        itemName(self, st.pendingItemID)))
    cancelStepTimer(self)
    clearPending(st)
    st.buyAll = false
    st.state = "READY"
    self:RefreshRestockTab()
end

-- The server's answer to our own StartCommoditiesPurchase, carrying the real
-- total for the quantity asked (#199). The wallet and the budget are checked
-- again here against it, since the pre-start estimate is a lower bound. The
-- confirm itself waits for the READY that follows this response; it goes out
-- here only when that READY has already come.
function GBL:COMMODITY_PRICE_UPDATED(_, unitPrice, totalPrice)
    local st = self._restock
    local prices = format("unit=%s total=%s",
        self:FormatMoney(unitPrice or 0), self:FormatMoney(totalPrice or 0))
    if not st or not purchaseInFlight(self) or not st.pendingItemID then
        ahLog(self, "COMMODITY_PRICE_UPDATED",
            format("%s ignored (state=%s)", prices, (st and st.state) or "none"))
        return
    end
    if st.confirmIssued then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " ignored (already issued)")
        return
    end
    if st.state == "PRICED" then
        supersededQuote(self, "COMMODITY_PRICE_UPDATED", prices)
        return
    end
    if st.cancelledStartDue then
        -- The answer to a start Cancel dropped before it arrived; the next
        -- purchase's own price follows that start's READY.
        st.cancelledStartDue = nil
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " ignored (price of a cancelled start)")
        return
    end
    if st.priceIn then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " ignored (price already in)")
        return
    end
    if type(totalPrice) ~= "number" or totalPrice <= 0 then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " refused (no usable total)")
        failStep(self, SKIP.NO_USABLE_PRICE, "the auction house sent no usable price for it.")
        return
    end
    if totalPrice > affordableMoney(self) then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " refused (cannot afford at price)")
        failStep(self, SKIP.CANNOT_AFFORD_AT_PRICE,
            format("the auction house quoted %s, more than you have.", self:FormatMoney(totalPrice)))
        return
    end
    local budget = self:GetRestockBudget()
    if budget > 0 and (spentCopper(self) + totalPrice) > budget * COPPER_PER_GOLD then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " refused (budget at price)")
        failStep(self, SKIP.BUDGET_AT_PRICE,
            format("the auction house quoted %s, past your budget of %d g.",
                self:FormatMoney(totalPrice), budget))
        return
    end
    st.priceIn = true
    st.pendingTotal = totalPrice
    if self:IsRestockConfirmAtPrice() then
        -- The pause (#211): the quote goes on the banner and the confirm
        -- waits for a click, with the one timer slot re-armed for the wait.
        -- focusConfirm is consumed by the one rebuild that enters PRICED,
        -- so a later rebuild cannot snap focus back onto Confirm.
        st.state = "PRICED"
        st.focusConfirm = true
        armStepTimer(self, PAUSE_TIMEOUT)
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " price in, awaiting confirm")
        self:RefreshRestockTab()
        return
    end
    if st.throttleBusy then
        ahLog(self, "COMMODITY_PRICE_UPDATED", prices .. " price in, confirm waits for ready")
    else
        issueConfirm(self, "COMMODITY_PRICE_UPDATED", prices)
    end
end

-- The server could not price our start. Auctionator's handling: cancel the
-- purchase and move on.
function GBL:COMMODITY_PRICE_UNAVAILABLE()
    local st = self._restock
    if not st or not purchaseInFlight(self) or not st.pendingItemID then
        ahLog(self, "COMMODITY_PRICE_UNAVAILABLE",
            format("ignored (state=%s)", (st and st.state) or "none"))
        return
    end
    if st.confirmIssued then
        ahLog(self, "COMMODITY_PRICE_UNAVAILABLE", "ignored (already issued)")
        return
    end
    if st.state == "PRICED" then
        supersededQuote(self, "COMMODITY_PRICE_UNAVAILABLE")
        return
    end
    if st.cancelledStartDue then
        st.cancelledStartDue = nil
        ahLog(self, "COMMODITY_PRICE_UNAVAILABLE", "ignored (answer to a cancelled start)")
        return
    end
    ahLog(self, "COMMODITY_PRICE_UNAVAILABLE", "handled")
    failStep(self, SKIP.NO_PRICE_AVAILABLE, "the auction house has no price for it right now.")
end

function GBL:COMMODITY_PURCHASE_SUCCEEDED()
    local st = self._restock
    if st and st.state == "CONFIRMING" and st.confirmIssued then
        ahLog(self, "COMMODITY_PURCHASE_SUCCEEDED", "handled")
        cancelStepTimer(self)
        creditPurchase(self, st, st.pendingIndex, st.pendingItemID, st.pendingTotal, st.pendingQty)
        self:Print(format("Bought %dx %s.", st.pendingQty or 0, itemName(self, st.pendingItemID)))
        clearPending(st)
        self:_RestockAfterStep()
        return
    end
    if st and st.unanswered then
        -- The result of a confirm the step timer gave up on. The events carry
        -- no purchase id, which is why nothing else may start while one is
        -- outstanding.
        local u = st.unanswered
        st.unanswered = nil
        ahLog(self, "COMMODITY_PURCHASE_SUCCEEDED", format("handled (late, it:%d x%d)", u.itemID or 0, u.qty or 0))
        creditPurchase(self, st, u.index, u.itemID, u.total, u.qty, { settle = u.parked })
        self:Print(format("Bought %dx %s (the result arrived late).", u.qty or 0, itemName(self, u.itemID)))
        self:RefreshRestockTab()
        return
    end
    if st and st.state == "PRICED" then
        foreignResultInPause(self, "COMMODITY_PURCHASE_SUCCEEDED")
    elseif st and st.state == "CONFIRMING" then  -- no confirm out: duplicate or foreign
        ahLog(self, "COMMODITY_PURCHASE_SUCCEEDED", "ignored (unsolicited)")
    else
        ahLog(self, "COMMODITY_PURCHASE_SUCCEEDED", format("ignored (state=%s)", (st and st.state) or "none"))
    end
end

function GBL:COMMODITY_PURCHASE_FAILED()
    local st = self._restock
    if st and st.state == "CONFIRMING" and st.confirmIssued then
        ahLog(self, "COMMODITY_PURCHASE_FAILED", "handled")
        self:Print("Purchase failed; stopping. Check your gold or try again.")
        cancelStepTimer(self)
        clearPending(st)
        stopRun(self)
        return
    end
    if st and st.unanswered then
        local u = st.unanswered
        st.unanswered = nil
        ahLog(self, "COMMODITY_PURCHASE_FAILED", format("handled (late, it:%d x%d)", u.itemID or 0, u.qty or 0))
        -- The purchase was parked when the timer gave up, and it turns out
        -- nothing was bought, so the parked quantity comes back out (#215).
        if u.parked then self:_RestockReversePending(u.itemID, u.qty) end
        self:Print(format("The purchase of %s failed after all; nothing was spent on it.",
            itemName(self, u.itemID)))
        self:RefreshRestockTab()
        return
    end
    if st and st.state == "PRICED" then
        foreignResultInPause(self, "COMMODITY_PURCHASE_FAILED")
    elseif st and st.state == "CONFIRMING" then  -- no confirm out: the step timer covers this start
        ahLog(self, "COMMODITY_PURCHASE_FAILED", "ignored (unsolicited)")
    else
        ahLog(self, "COMMODITY_PURCHASE_FAILED", format("ignored (state=%s)", (st and st.state) or "none"))
    end
end

-- Log-only handlers (#199). The throttle family and UI_ERROR_MESSAGE fire for
-- every addon's auction-house traffic, so they log only while a purchase is
-- in flight. A drop or an error while a confirm is out
-- is remembered for the result timeout's chat line and gates nothing: neither
-- has been observed around one of our calls yet.
function GBL:AUCTION_HOUSE_THROTTLED_MESSAGE_SENT()
    if purchaseInFlight(self) then ahLog(self, "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT") end
end

function GBL:AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED()
    if purchaseInFlight(self) then ahLog(self, "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED") end
end

function GBL:AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
    if purchaseInFlight(self) then
        ahLog(self, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        local st = self._restock
        if st.confirmIssued then st.errorNote = "message dropped" end
    end
end

function GBL:AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED()
    if purchaseInFlight(self) then ahLog(self, "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED") end
end

function GBL:UI_ERROR_MESSAGE(_, errorType, message)
    if purchaseInFlight(self) then
        ahLog(self, "UI_ERROR_MESSAGE", format("err=%s %s", tostring(errorType), tostring(message)))
        local st = self._restock
        if st.confirmIssued then st.errorNote = tostring(message) end
    end
end
