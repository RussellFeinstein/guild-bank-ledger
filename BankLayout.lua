------------------------------------------------------------------------
-- GuildBankLedger — BankLayout.lua
-- Per-tab layout templates: display / overflow / ignore modes.
-- Display tabs hold a curated set of items at specific slot counts and
-- per-slot stack sizes. SortPlanner consumes this to plan moves.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local MAX_TABS = MAX_GUILDBANK_TABS or 8

local LAYOUT_SCHEMA_VERSION = 1

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function extractItemID(itemLink)
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

local function emptyTable(t)
    for k in pairs(t) do t[k] = nil end
end

--- Get the guild-scoped storage table, backfilling missing layout/reserve fields.
-- Returns nil if there is no active guild yet.
local function getStore(self)
    local guild = self:GetGuildData()
    if not guild then return nil end
    if not guild.bankLayout then
        guild.bankLayout = { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    end
    if not guild.stockReserves then
        guild.stockReserves = {}
    end
    return guild
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

GBL.BankLayout = GBL.BankLayout or {}
local BankLayout = GBL.BankLayout

--- Schema version constant exposed for tests and migrations.
BankLayout.SCHEMA_VERSION = LAYOUT_SCHEMA_VERSION

--- Return a deep copy of the current layout (never the live reference).
-- @return table { version, updatedBy, updatedAt, tabs = { [tabIndex] = {...} } }
function GBL:GetBankLayout()
    local guild = getStore(self)
    if not guild then
        return { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    end
    -- Defensive copy so callers can't mutate storage accidentally.
    local src = guild.bankLayout
    local tabs = {}
    for tabIndex, tab in pairs(src.tabs or {}) do
        local copy = { mode = tab.mode, name = tab.name }
        if tab.mode == "display" then
            copy.items = {}
            for itemID, row in pairs(tab.items or {}) do
                copy.items[itemID] = { slots = row.slots, perSlot = row.perSlot }
            end
            copy.slotOrder = {}
            for slotIndex, itemID in pairs(tab.slotOrder or {}) do
                copy.slotOrder[slotIndex] = itemID
            end
        end
        tabs[tabIndex] = copy
    end
    return {
        version = src.version or 0,
        updatedBy = src.updatedBy,
        updatedAt = src.updatedAt or 0,
        tabs = tabs,
    }
end

--- Return a deep copy of the stockReserves table. Keys are numeric itemIDs.
function GBL:GetStockReserves()
    local guild = getStore(self)
    if not guild then return {} end
    local copy = {}
    for itemID, reserve in pairs(guild.stockReserves or {}) do
        copy[itemID] = reserve
    end
    return copy
end

--- Validate a prospective layout. Returns ok, errorMessage.
-- @param layout table with .tabs = { [tabIndex] = tab }
function BankLayout.Validate(layout)
    if type(layout) ~= "table" or type(layout.tabs) ~= "table" then
        return false, "layout.tabs must be a table"
    end

    local overflowCount = 0
    local seenItems = {}

    for tabIndex, tab in pairs(layout.tabs) do
        if type(tabIndex) ~= "number" or tabIndex < 1 or tabIndex > MAX_TABS then
            return false, "invalid tabIndex: " .. tostring(tabIndex)
        end
        if type(tab) ~= "table" then
            return false, "tab " .. tabIndex .. " is not a table"
        end
        local mode = tab.mode
        if mode == "overflow" then
            overflowCount = overflowCount + 1
        elseif mode == "display" then
            if type(tab.items) ~= "table" then
                return false, "display tab " .. tabIndex .. " missing items"
            end
            local slotsUsed = 0
            for itemID, row in pairs(tab.items) do
                if type(itemID) ~= "number" then
                    return false, "tab " .. tabIndex .. " item key must be numeric itemID"
                end
                if type(row) ~= "table" or type(row.slots) ~= "number" or type(row.perSlot) ~= "number" then
                    return false, "tab " .. tabIndex .. " item " .. itemID .. " row malformed"
                end
                if row.slots < 1 or row.perSlot < 1 then
                    return false, "tab " .. tabIndex .. " item " .. itemID .. " slots/perSlot must be >= 1"
                end
                if seenItems[itemID] then
                    return false, "item " .. itemID .. " appears in multiple display tabs ("
                        .. seenItems[itemID] .. " and " .. tabIndex .. ")"
                end
                seenItems[itemID] = tabIndex
                slotsUsed = slotsUsed + row.slots
            end
            if slotsUsed > MAX_SLOTS then
                return false, "tab " .. tabIndex .. " uses " .. slotsUsed
                    .. " slots > " .. MAX_SLOTS
            end
            if tab.slotOrder then
                for slotIndex, itemID in pairs(tab.slotOrder) do
                    if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > MAX_SLOTS then
                        return false, "tab " .. tabIndex .. " slotOrder has invalid slot " .. tostring(slotIndex)
                    end
                    if not tab.items[itemID] then
                        return false, "tab " .. tabIndex .. " slotOrder references itemID " .. tostring(itemID)
                            .. " with no matching items[] entry"
                    end
                end
            end
        elseif mode ~= "ignore" then
            return false, "tab " .. tabIndex .. " has unknown mode " .. tostring(mode)
        end
    end

    if overflowCount ~= 1 then
        return false, "exactly one tab must be mode=overflow (found " .. overflowCount .. ")"
    end

    return true, nil
end

--- Save a layout to storage. Returns ok, errorMessage.
-- @param layout table produced by GetBankLayout (or constructed fresh).
-- @param updatedBy string|nil player name of the editor (defaults to UnitName("player")).
function GBL:SaveBankLayout(layout, updatedBy)
    if not self:HasLayoutWrite() then
        return false, "you do not have layout-write access for this guild"
    end

    local ok, err = BankLayout.Validate(layout)
    if not ok then return false, err end

    local guild = getStore(self)
    if not guild then return false, "no active guild" end

    local prev = guild.bankLayout or { version = 0 }
    local nextVersion = (prev.version or 0) + 1

    local store = { version = nextVersion, tabs = {}, updatedAt = GetServerTime(),
                    updatedBy = updatedBy or (UnitName and UnitName("player")) or nil }
    for tabIndex, tab in pairs(layout.tabs) do
        local copy = { mode = tab.mode, name = tab.name }
        if tab.mode == "display" then
            copy.items = {}
            for itemID, row in pairs(tab.items or {}) do
                copy.items[itemID] = { slots = row.slots, perSlot = row.perSlot }
            end
            copy.slotOrder = {}
            for slotIndex, itemID in pairs(tab.slotOrder or {}) do
                copy.slotOrder[slotIndex] = itemID
            end
        end
        store.tabs[tabIndex] = copy
    end
    guild.bankLayout = store
    return true, nil
end

--- Set the reserve count for an item (beyond display-tab totals).
-- A reserve of 0 or nil removes the entry.
function GBL:SetStockReserve(itemID, reserve)
    if not self:HasLayoutWrite() then
        return false, "you do not have layout-write access for this guild"
    end
    if type(itemID) ~= "number" then return false, "itemID must be numeric" end
    local guild = getStore(self)
    if not guild then return false, "no active guild" end
    if not reserve or reserve <= 0 then
        guild.stockReserves[itemID] = nil
    else
        guild.stockReserves[itemID] = math.floor(reserve)
    end
    return true, nil
end

--- Capture the live contents of a tab into a display-tab template.
-- Reads the most recent scan results (GetLastScanResults) for the tab and
-- emits {items, slotOrder} matching what is currently present.
-- Stacks of the same item inside the captured tab are collapsed: slots ← count
-- of distinct slots holding the item, perSlot ← the most common stack size
-- observed (ties break toward the larger number so oversize stacks don't get
-- locked in as the template target).
--
-- @param tabIndex number
-- @return table|nil template table { mode="display", items=..., slotOrder=..., name= }
-- @return string|nil error message on failure
function GBL:CaptureTabLayout(tabIndex)
    if type(tabIndex) ~= "number" then
        return nil, "tabIndex must be numeric"
    end
    local results = self.lastScanResults
    if not results or not results[tabIndex] then
        return nil, "no scan results for tab " .. tabIndex
    end
    local tabResult = results[tabIndex]

    local items = {}          -- itemID -> { slots, stackCounts = { perSlot -> occurrences } }
    local slotOrder = {}

    for slotIndex = 1, MAX_SLOTS do
        local slot = tabResult.slots and tabResult.slots[slotIndex]
        if slot then
            local itemID = extractItemID(slot.itemLink)
            if itemID then
                slotOrder[slotIndex] = itemID
                local entry = items[itemID]
                if not entry then
                    entry = { slots = 0, stackCounts = {} }
                    items[itemID] = entry
                end
                entry.slots = entry.slots + 1
                local sz = slot.count or 1
                entry.stackCounts[sz] = (entry.stackCounts[sz] or 0) + 1
            end
        end
    end

    local finalItems = {}
    for itemID, entry in pairs(items) do
        -- Pick the mode stack size; tiebreak toward larger.
        local bestSize, bestOccur = 1, -1
        for sz, occur in pairs(entry.stackCounts) do
            if occur > bestOccur or (occur == bestOccur and sz > bestSize) then
                bestSize = sz
                bestOccur = occur
            end
        end
        finalItems[itemID] = { slots = entry.slots, perSlot = bestSize }
    end

    local tabName = nil
    if GetGuildBankTabInfo then
        local name = GetGuildBankTabInfo(tabIndex)
        tabName = name
    end

    return {
        mode = "display",
        name = tabName,
        items = finalItems,
        slotOrder = slotOrder,
    }, nil
end

--- Utility: clear the layout entirely (used by tests and a future /gbl reset).
function GBL:ResetBankLayout()
    local guild = getStore(self)
    if not guild then return end
    guild.bankLayout = { version = 0, updatedBy = nil, updatedAt = 0, tabs = {} }
    emptyTable(guild.stockReserves)
end

--- Expose extractItemID for reuse by SortPlanner / tests.
BankLayout.ExtractItemID = extractItemID
