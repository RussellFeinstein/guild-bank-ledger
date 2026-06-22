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
                if type(row) == "table" then
                    local n = (row.slots or 0) * (row.perSlot or 0)
                    demand[itemID] = (demand[itemID] or 0) + n
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
        guild.restock = { items = {}, added = {}, budget = 0 }
    end
    local r = guild.restock
    if not r.items then r.items = {} end
    if not r.added then r.added = {} end
    if r.budget == nil then r.budget = 0 end
    return r
end

--- Return the live per-guild restock store (backfilled), or nil if no guild.
-- @return table|nil { items = {...}, added = {...}, budget = number }
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

--- Add an item to the local catalog augmentation (item coverage).
-- @param itemID number
-- @return boolean ok, string|nil err
function GBL:AddRestockCatalogItem(itemID)
    if type(itemID) ~= "number" then return false, "itemID must be numeric" end
    local data = getStore(self)
    if not data then return false, "no active guild" end
    data.added[itemID] = true
    return true, nil
end

--- Remove an item from the local catalog augmentation.
-- @param itemID number
-- @return boolean ok, string|nil err
function GBL:RemoveRestockCatalogItem(itemID)
    if type(itemID) ~= "number" then return false, "itemID must be numeric" end
    local data = getStore(self)
    if not data then return false, "no active guild" end
    data.added[itemID] = nil
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
-- Union deduped by itemID of: catalog (group order) -> manually-added items
-- not in the catalog -> GBL-target items (demand or reserve) not otherwise
-- present. Each row is a NEW table (catalog rows stay read-only).
--
-- opts (all optional, default to the live getters so tests can inject):
--   layout, reserves, scanResults, data
-- @return table array of rows:
--   { itemID, source = "catalog"|"added"|"target", group?, rank?, qty?,
--     enabled, maxPrice?, target, stock, toBuy }
function GBL:_RestockBuildItemUniverse(opts)
    opts = opts or {}
    local layout = opts.layout or self:GetBankLayout()
    local reserves = opts.reserves or self:GetStockReserves()
    local scanResults = opts.scanResults or self:GetLastScanResults()
    local data = opts.data or self:GetRestockData() or {}
    local overrides = data.items or {}
    local added = data.added or {}

    local demand = self:_RestockLayoutDemand(layout)
    local stock = self:_RestockAggregateStock(scanResults)
    local catalog = self:GetRestockCatalog()
    local catalogIDs = self:GetRestockCatalogItemIDs()

    local rows = {}
    local seen = {}

    local function addRow(itemID, source, catalogRow, groupName)
        if seen[itemID] then return end
        seen[itemID] = true
        local override = overrides[itemID]
        local enabled
        if override and override.enabled ~= nil then
            enabled = override.enabled
        elseif catalogRow then
            enabled = catalogRow.enabled
        else
            enabled = true
        end
        local target = self:_RestockTarget(itemID, demand, reserves)
        local stk = stock[itemID] or 0
        local toBuy = target - stk
        if toBuy < 0 then toBuy = 0 end
        rows[#rows + 1] = {
            itemID = itemID,
            source = source,
            group = groupName,
            rank = catalogRow and catalogRow.rank,
            qty = catalogRow and catalogRow.qty,
            enabled = enabled,
            maxPrice = override and override.maxPrice,
            target = target,
            stock = stk,
            toBuy = toBuy,
        }
    end

    -- 1. Catalog, in group then row order.
    for _, group in ipairs(catalog) do
        for _, crow in ipairs(group.items) do
            if crow.id then
                addRow(crow.id, "catalog", crow, group.name)
            end
        end
    end

    -- 2. Manually-added items not already in the catalog. Sorted by itemID so
    -- the rows (and the focus order M3 wires from them) are stable across rebuilds.
    local addedIDs = {}
    for itemID in pairs(added) do
        if not catalogIDs[itemID] then
            addedIDs[#addedIDs + 1] = itemID
        end
    end
    table.sort(addedIDs)
    for _, itemID in ipairs(addedIDs) do
        addRow(itemID, "added", nil, nil)
    end

    -- 3. GBL-target items (demand or reserve) not otherwise present, deduped and
    -- sorted so the coverage group renders in a stable order.
    local targetSet = {}
    for itemID in pairs(demand) do
        if not seen[itemID] then targetSet[itemID] = true end
    end
    for itemID in pairs(reserves) do
        if not seen[itemID] then targetSet[itemID] = true end
    end
    local targetIDs = {}
    for itemID in pairs(targetSet) do
        targetIDs[#targetIDs + 1] = itemID
    end
    table.sort(targetIDs)
    for _, itemID in ipairs(targetIDs) do
        addRow(itemID, "target", nil, nil)
    end

    return rows
end
