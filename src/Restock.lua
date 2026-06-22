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
