------------------------------------------------------------------------
-- GuildBankLedger — Restock.lua
-- Pure restock math (target / stock / toBuy) plus the displayed item
-- universe and per-guild-local restock settings. No AceGUI, no Auctionator
-- (those land in the RestockView / search-flow milestones).
--
-- Target model (Option C): per-item guild target = max(layoutDemand, reserve).
-- Demand comes from display-tab templates; reserve from GetStockReserves
-- (dormant until a producer ships). toBuy = max(0, target - stock), where
-- stock aggregates the latest scan across all tabs.
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
        guild.restock = { items = {}, budget = 0 }
    end
    local r = guild.restock
    if not r.items then r.items = {} end
    if r.budget == nil then r.budget = 0 end
    return r
end

--- Return the live per-guild restock store (backfilled), or nil if no guild.
-- @return table|nil { items = {...}, budget = number }
function GBL:GetRestockData()
    return getStore(self)
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

--- Per-run gold budget cap (0 = no cap).
-- @return number budget (>= 0)
function GBL:GetRestockBudget()
    local data = getStore(self)
    if not data then return 0 end
    return data.budget or 0
end

--- Set the per-run gold budget cap (clamped to >= 0).
-- @param n number
-- @return boolean ok, string|nil err
function GBL:SetRestockBudget(n)
    local data = getStore(self)
    if not data then return false, "no active guild" end
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    data.budget = math.floor(n)
    return true, nil
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
--   { itemID, tabIndex?, group, enabled, maxPrice?, target, stock, toBuy }
function GBL:_RestockBuildItemUniverse(opts)
    opts = opts or {}
    local layout = opts.layout or self:GetBankLayout()
    local reserves = opts.reserves or self:GetStockReserves()
    local scanResults = opts.scanResults or self:GetLastScanResults()
    local data = opts.data or self:GetRestockData() or {}
    local overrides = data.items or {}

    local demand = self:_RestockLayoutDemand(layout)
    local stock = self:_RestockAggregateStock(scanResults)

    -- Reserves keyed by number (see the key-coercion note above).
    local reserveByID = {}
    if type(reserves) == "table" then
        for itemID, n in pairs(reserves) do
            local id = tonumber(itemID)
            if id then reserveByID[id] = n end
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
        local toBuy = target - stk
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
        }
    end

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
        local groupName = tab.name
        if groupName == nil or groupName == "" then
            groupName = "Tab " .. tostring(tabIndex)
        end

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

    return rows
end

------------------------------------------------------------------------
-- Auctionator search + buy flow (IDLE -> SEARCHING -> READY -> CONFIRMING)
-- Ported from GuildBankRestock, adapted to the layout-driven buy list and GBL's
-- singleton session-state conventions. Every Auctionator/Item/C_AuctionHouse
-- access is existence-guarded and verified in-game; the pure helpers below carry
-- the unit coverage (the buy state machine is also fireEvent-tested).
--
-- Session state on self._restock (NOT persisted, NOT synced):
--   { state, activeItems = { {itemID, needed} }, resultRows = { [i]=row },
--     searchGen, listenerRegistered, foundCount,                 -- search
--     bought, skipped, pendingIndex, pendingItemID, pendingQty,  -- buy
--     buyAll, buyEventsRegistered, confirmIssued, runStartMoney, spentEstimate }
-- The EventBus listener table lives on self._restockListener (stable across
-- searches so Unregister matches Register).
------------------------------------------------------------------------

--- True when Auctionator exposes the search API this flow needs. Gates the
-- Search button (RestockView) and is the hard guard in StartRestockSearch.
function GBL:IsAuctionatorReady()
    return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
        and Auctionator.API.v1.ConvertToSearchString ~= nil and Auctionator.EventBus ~= nil
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

--- Pure: pair Auctionator result rows back to the active items by itemID.
-- @param activeItems table array of { itemID, needed }
-- @param results table|nil Auctionator results, each { itemKey = {itemID}, minPrice }
-- @return table resultRows ([i] = row for activeItems[i]), number foundCount
function GBL:_RestockMapResults(activeItems, results)
    local resultRows = {}
    local found = 0
    if type(activeItems) ~= "table" or type(results) ~= "table" then
        return resultRows, found
    end
    for i, ref in ipairs(activeItems) do
        for _, row in ipairs(results) do
            if row.itemKey and row.itemKey.itemID == ref.itemID then
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
-- non-empty buy list. Fire-and-forget; verified in-game.
function GBL:StartRestockSearch()
    if not self:IsAuctionatorReady() then
        self:Print("Restock needs the Auctionator addon to search the Auction House.")
        return
    end
    if not (AuctionatorShoppingFrame and AuctionatorShoppingFrame.IsVisible
            and AuctionatorShoppingFrame:IsVisible()) then
        self:Print("Open the Auctionator Shopping tab first, then search.")
        return
    end
    if not self:GetLastScanResults() then
        self:Print("Open the guild bank first so Restock knows current stock.")
        return
    end
    local ev = searchEndEvent()
    if not ev then
        self:Print("Auctionator's search API changed; cannot search.")
        return
    end

    local buyList = self:_RestockBuildBuyList()
    if #buyList == 0 then
        self:Print("Nothing to buy: the bank is at target for every layout item.")
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

--- Auctionator finished a search: map results to the active items, go READY.
function GBL:_RestockOnSearchEnd(results)
    local st = self._restock
    if not st or st.state ~= "SEARCHING" then return end
    unregisterSearchListener(self)
    local resultRows, found = self:_RestockMapResults(st.activeItems, results)
    st.resultRows = resultRows
    st.foundCount = found
    st.bought = {}
    st.skipped = {}
    st.buyAll = false
    st.confirmIssued = false
    st.runStartMoney = (GetMoney and GetMoney()) or 0  -- baseline for the budget cap
    st.spentEstimate = 0  -- lag-free lower bound on spend (GetMoney can trail events)
    st.state = "READY"
    self:RefreshRestockTab()
end

--- Reset the search/buy back to IDLE: unregister listeners and buy events, stop
-- any in-flight Auctionator search, invalidate stale async callbacks, and clear
-- results and buy progress.
function GBL:ResetRestockSearch()
    self._restock = self._restock or { state = "IDLE" }
    local st = self._restock
    unregisterSearchListener(self)
    self:_RestockUnregisterBuyEvents()
    if (st.state == "SEARCHING" or st.state == "READY" or st.state == "CONFIRMING")
            and AuctionatorShoppingFrame and AuctionatorShoppingFrame.StopSearch then
        pcall(function() AuctionatorShoppingFrame:StopSearch() end)
    end
    st.searchGen = (st.searchGen or 0) + 1
    st.activeItems = {}
    st.resultRows = {}
    st.foundCount = 0
    st.bought = {}
    st.skipped = {}
    st.pendingIndex = nil
    st.pendingItemID = nil
    st.pendingQty = nil
    st.buyAll = false
    st.confirmIssued = false
    st.spentEstimate = 0
    st.state = "IDLE"
end

------------------------------------------------------------------------
-- Buy / confirm flow (M4c: READY -> CONFIRMING -> READY)
-- Per-item buys and a budget-capped Buy-all sweep, ported from GBR. Spends real
-- gold via C_AuctionHouse commodities; the budget cap, per-item review, WoW's
-- own per-purchase dialog, and in-game verification are the safeguards. The
-- COMMODITY/THROTTLED handlers are registered lazily on the first buy and
-- unregistered in ResetRestockSearch; each guards state == "CONFIRMING".
------------------------------------------------------------------------

local COPPER_PER_GOLD = 10000

--- Gold spent so far this run (copper), clamped at 0.
function GBL:_RestockSpent(startMoney, curMoney)
    local spent = (startMoney or 0) - (curMoney or 0)
    if spent < 0 then return 0 end
    return spent
end

--- True when a positive budget (gold) has been reached by the spent copper.
function GBL:_RestockBudgetExceeded(spentCopper, budgetGold)
    budgetGold = budgetGold or 0
    if budgetGold <= 0 then return false end
    return (spentCopper or 0) >= budgetGold * COPPER_PER_GOLD
end

--- First index eligible to buy: has a result, not bought, not skipped, needed > 0.
function GBL:_RestockNextBuyable(st)
    if not st or type(st.activeItems) ~= "table" then return nil end
    local bought = st.bought or {}
    local skipped = st.skipped or {}
    local resultRows = st.resultRows or {}
    for i, ref in ipairs(st.activeItems) do
        if resultRows[i] and not bought[i] and not skipped[i] and (ref.needed or 0) > 0 then
            return i
        end
    end
    return nil
end

function GBL:_RestockRegisterBuyEvents()
    local st = self._restock
    if st and not st.buyEventsRegistered then
        self:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        self:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
        self:RegisterEvent("COMMODITY_PURCHASE_FAILED")
        st.buyEventsRegistered = true
    end
end

function GBL:_RestockUnregisterBuyEvents()
    if self._restock and self._restock.buyEventsRegistered then
        self:UnregisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        self:UnregisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
        self:UnregisterEvent("COMMODITY_PURCHASE_FAILED")
        self._restock.buyEventsRegistered = false
    end
end

-- Spent copper for the active run: the greater of the wallet delta (which can
-- trail the purchase events) and our own lag-free running estimate.
local function spentCopper(self)
    local st = self._restock
    if not st then return 0 end
    local actual = self:_RestockSpent(st.runStartMoney, (GetMoney and GetMoney()) or 0)
    local estimate = st.spentEstimate or 0
    if estimate > actual then return estimate end
    return actual
end

-- Conservative remaining gold for affordability checks: GetMoney can read high
-- in the lag right after a purchase, so also bound remaining by the lag-free
-- spend estimate (runStartMoney - spentCopper). Prevents a sweep from attempting
-- the next buy against a wallet that has not been debited yet.
local function affordableMoney(self)
    local wallet = (GetMoney and GetMoney()) or 0
    local st = self._restock
    if not st then return wallet end
    local lagFree = (st.runStartMoney or wallet) - spentCopper(self)
    if lagFree < wallet then return lagFree end
    return wallet
end

local function itemName(self, itemID)
    local name = self.GetCachedItemInfo and itemID and self:GetCachedItemInfo(itemID)
    return name or ("item " .. tostring(itemID))
end

--- Begin a commodity purchase for activeItems[index]. Handles the maxPrice skip
-- and the budget cap; on a real buy it goes CONFIRMING and waits for the WoW
-- events to confirm and report the result.
function GBL:_RestockBeginPurchase(index)
    local st = self._restock
    if not st or st.state ~= "READY" then return end
    local ref = st.activeItems and st.activeItems[index]
    local row = st.resultRows and st.resultRows[index]
    if not ref or not row or (st.bought and st.bought[index]) or (ref.needed or 0) <= 0 then
        self:_RestockAfterStep()
        return
    end

    -- Per-item maxPrice cap (override; no input UI yet, so usually unset).
    local override = self:GetRestockItemOverride(ref.itemID)
    local maxPrice = override and override.maxPrice
    if maxPrice and maxPrice > 0 and row.minPrice and row.minPrice > maxPrice * COPPER_PER_GOLD then
        st.skipped[index] = true
        self:Print(format("Skipped %s: lowest price is over your max of %d g.",
            itemName(self, ref.itemID), maxPrice))
        self:_RestockAfterStep()
        return
    end

    local budget = self:GetRestockBudget()
    -- Budget cap (already reached): stop the run.
    if self:_RestockBudgetExceeded(spentCopper(self), budget) then
        self:Print(format("Budget of %d g reached; stopping.", budget))
        st.buyAll = false
        st.state = "READY"
        self:RefreshRestockTab()
        return
    end
    -- Budget cap (this buy): skip an item whose estimated cost (lowest price x
    -- quantity, a lower bound) would push spend past the budget.
    local estCost = (row.minPrice or 0) * (ref.needed or 0)
    if budget > 0 and (spentCopper(self) + estCost) > budget * COPPER_PER_GOLD then
        self:Print(format("Skipping %s: it would exceed your budget of %d g.",
            itemName(self, ref.itemID), budget))
        if st.buyAll then
            st.skipped[index] = true
            self:_RestockAfterStep()
        else
            self:RefreshRestockTab()
        end
        return
    end

    -- Affordability: never attempt a purchase the wallet cannot cover. WoW can
    -- leave the confirm stuck when funds are short, so refuse up front. estCost
    -- is a lower bound (price climbs as you buy up listings), which catches the
    -- clear cases; the Cancel button covers any residual stuck confirm. Uses the
    -- lag-safe remaining estimate so a sweep cannot outrun the wallet update.
    local money = affordableMoney(self)
    if estCost > money then
        self:Print(format("Not enough gold for %s: need about %s, have %s.",
            itemName(self, ref.itemID), self:FormatMoney(estCost), self:FormatMoney(money)))
        if st.buyAll then
            st.skipped[index] = true
            self:_RestockAfterStep()
        else
            self:RefreshRestockTab()
        end
        return
    end

    if not (C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase) then
        self:Print("Open the Auction House to buy.")
        return
    end

    self:_RestockRegisterBuyEvents()
    st.pendingIndex = index
    st.pendingItemID = (row.itemKey and row.itemKey.itemID) or ref.itemID
    st.pendingQty = ref.needed
    st.confirmIssued = false
    st.state = "CONFIRMING"
    self:RefreshRestockTab()
    C_AuctionHouse.StartCommoditiesPurchase(st.pendingItemID, st.pendingQty)
end

--- After a buy or skip: continue the sweep, or settle back to READY.
function GBL:_RestockAfterStep()
    local st = self._restock
    if not st then return end
    -- Settle out of CONFIRMING first so the next _RestockBeginPurchase passes
    -- its state == "READY" guard.
    st.state = "READY"
    if not st.buyAll then
        self:RefreshRestockTab()
        return
    end
    if self:_RestockBudgetExceeded(spentCopper(self), self:GetRestockBudget()) then
        st.buyAll = false
        self:Print("Budget reached; Buy-all stopped.")
        self:RefreshRestockTab()
        return
    end
    local nextIndex = self:_RestockNextBuyable(st)
    if not nextIndex then
        st.buyAll = false
        self:Print("Buy-all complete.")
        self:RefreshRestockTab()
        return
    end
    self:_RestockBeginPurchase(nextIndex)
end

--- Buy a single item (per-item button).
function GBL:StartRestockBuy(index)
    local st = self._restock
    if not st or st.state ~= "READY" then return end
    st.buyAll = false
    self:_RestockBeginPurchase(index)
end

--- Buy every eligible item in sequence. Spending is bounded by affordability
-- (the wallet) and, if one is set, the budget cap.
function GBL:StartRestockBuyAll()
    local st = self._restock
    if not st or st.state ~= "READY" then return end
    local nextIndex = self:_RestockNextBuyable(st)
    if not nextIndex then
        self:Print("Nothing to buy.")
        return
    end
    st.buyAll = true
    self:_RestockBeginPurchase(nextIndex)
end

--- WoW commodity events (registered lazily; each guards state == CONFIRMING).
function GBL:AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    local st = self._restock
    if not st or st.state ~= "CONFIRMING" then return end
    if st.confirmIssued then return end  -- throttle-ready can fire repeatedly
    if st.pendingItemID and st.pendingQty
            and C_AuctionHouse and C_AuctionHouse.ConfirmCommoditiesPurchase then
        st.confirmIssued = true
        C_AuctionHouse.ConfirmCommoditiesPurchase(st.pendingItemID, st.pendingQty)
    end
end

function GBL:COMMODITY_PURCHASE_SUCCEEDED()
    local st = self._restock
    if not st or st.state ~= "CONFIRMING" then return end
    if not st.confirmIssued then return end  -- ignore a duplicate or unsolicited success
    st.confirmIssued = false
    local index = st.pendingIndex
    if index then
        st.bought[index] = true
        -- Lag-free lower bound on spend: GetMoney can trail the purchase event.
        local row = st.resultRows and st.resultRows[index]
        local minPrice = (row and row.minPrice) or 0
        st.spentEstimate = (st.spentEstimate or 0) + minPrice * (st.pendingQty or 0)
    end
    self:Print(format("Bought %dx %s.", st.pendingQty or 0, itemName(self, st.pendingItemID)))
    st.pendingIndex = nil
    st.pendingItemID = nil
    st.pendingQty = nil
    self:_RestockAfterStep()
end

function GBL:COMMODITY_PURCHASE_FAILED()
    local st = self._restock
    if not st or st.state ~= "CONFIRMING" then return end
    self:Print("Purchase failed; stopping. Check your gold or try again.")
    st.confirmIssued = false
    st.pendingIndex = nil
    st.pendingItemID = nil
    st.pendingQty = nil
    st.buyAll = false
    st.state = "READY"
    self:RefreshRestockTab()
end
