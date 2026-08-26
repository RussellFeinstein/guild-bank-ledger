------------------------------------------------------------------------
-- GuildBankLedger — Scanner.lua
-- Guild bank slot scanning (inventory snapshots)
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98

------------------------------------------------------------------------
-- Scan state
------------------------------------------------------------------------

-- Current scan context (reset each scan)
local scanState = {
    inProgress = false,
    currentTab = 0,
    totalTabs = 0,
    viewableTabs = {},   -- ordered list of viewable tab indices
    tabIndex = 0,        -- index into viewableTabs
    results = {},        -- tabIndex -> { slots = { slotIndex -> itemData } }
    startTime = 0,
    pendingTimer = nil,
    waitingForData = false,
}

local function resetScanState()
    scanState.inProgress = false
    scanState.currentTab = 0
    scanState.totalTabs = 0
    scanState.viewableTabs = {}
    scanState.tabIndex = 0
    scanState.results = {}
    scanState.startTime = 0
    scanState.pendingTimer = nil
    scanState.waitingForData = false
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Start a full scan of all viewable guild bank tabs.
function GBL:StartFullScan()
    if scanState.inProgress then
        return
    end

    if not self:IsBankOpen() then
        return
    end

    resetScanState()
    scanState.inProgress = true
    scanState.startTime = GetServerTime()
    self.scanInProgress = true

    -- Build list of viewable tabs
    local numTabs = GetNumGuildBankTabs()
    scanState.totalTabs = numTabs

    for i = 1, numTabs do
        local _name, _icon, isViewable = GetGuildBankTabInfo(i)
        if isViewable then
            table.insert(scanState.viewableTabs, i)
        end
    end

    if #scanState.viewableTabs == 0 then
        self:FinalizeScan()
        return
    end

    -- Start scanning first viewable tab
    scanState.tabIndex = 1
    self:QueryAndScanTab()
end

--- Query the current tab and prepare to scan it.
-- The old immediate-scan fast-path was removed because on first bank open
-- the client has no slot data yet — GetGuildBankItemLink returns nil for
-- every slot, the scan unregisters the event, and the actual data arrival
-- is then ignored. The correct flow is: register → query → wait for the
-- server's GUILDBANKBAGSLOTS_CHANGED → scan. A timeout fallback covers
-- the edge case where a tab never fires the event (e.g., a truly empty
-- tab, or a network stall).
function GBL:QueryAndScanTab()
    local tabIndex = scanState.viewableTabs[scanState.tabIndex]
    if not tabIndex then
        self:FinalizeScan()
        return
    end

    scanState.currentTab = tabIndex
    scanState.waitingForData = true

    -- Register BEFORE the query so we can't miss the response.
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")

    -- Request tab data from server.
    QueryGuildBankTab(tabIndex)

    -- Fallback: if the event doesn't fire within the timeout, scan anyway.
    -- Guards on scanState so a late timer firing for a previous tab is a no-op.
    local tabAtStart = tabIndex
    local SCAN_TIMEOUT = self.db.profile.scanning.queryTimeout or 3.0
    scanState.pendingTimer = C_Timer.After(SCAN_TIMEOUT, function()
        if scanState.inProgress and scanState.waitingForData
           and scanState.currentTab == tabAtStart then
            GBL:TryScanCurrentTab(false)
        end
    end)
end

--- Attempt to scan the current tab's slots.
-- Called after QueryGuildBankTab and on GUILDBANKBAGSLOTS_CHANGED.
-- @param viaEvent boolean true when driven by GUILDBANKBAGSLOTS_CHANGED,
--   false when driven by the query-timeout fallback. Recorded per tab so a
--   cold-snapshot can be diagnosed after the fact. nil defaults to "timeout".
function GBL:TryScanCurrentTab(viaEvent)
    if not scanState.inProgress then
        return
    end

    local tabIndex = scanState.currentTab
    self:ScanTab(tabIndex)

    -- Record how this tab's data arrived: a real GUILDBANKBAGSLOTS_CHANGED
    -- event (warm) vs the query-timeout fallback (server data may never have
    -- arrived — the cold-cache fingerprint behind phantom sort plans).
    if scanState.results[tabIndex] then
        scanState.results[tabIndex].completedVia = viaEvent and "event" or "timeout"
    end

    scanState.waitingForData = false
    self:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    self:ScanNextTab()
end

--- Scan all 98 slots in a single tab.
-- @param tabIndex number The tab to scan
function GBL:ScanTab(tabIndex)
    local tabResult = { slots = {}, itemCount = 0, lockedSkips = 0 }

    for slotIndex = 1, MAX_SLOTS do
        local itemLink = GetGuildBankItemLink(tabIndex, slotIndex)
        if itemLink then
            local texture, count, locked = GetGuildBankItemInfo(tabIndex, slotIndex)
            if not locked then
                tabResult.slots[slotIndex] = {
                    itemLink = itemLink,
                    texture = texture,
                    count = count or 1,
                    slotIndex = slotIndex,
                    tabIndex = tabIndex,
                }
                tabResult.itemCount = tabResult.itemCount + 1
            else
                -- Slot holds an item but is transiently locked (e.g. mid
                -- server mutation). Skipped from the snapshot — count it so a
                -- sort planned against this scan can be diagnosed.
                tabResult.lockedSkips = tabResult.lockedSkips + 1
            end
        end
    end

    scanState.results[tabIndex] = tabResult
end

--- Advance to the next viewable tab, or finalize if done.
function GBL:ScanNextTab()
    if not scanState.inProgress then
        return
    end

    scanState.tabIndex = scanState.tabIndex + 1

    if scanState.tabIndex > #scanState.viewableTabs then
        self:FinalizeScan()
        return
    end

    -- Chain next tab with delay to avoid server throttle
    local delay = self.db.profile.scanning.scanDelay or 0.5
    scanState.pendingTimer = C_Timer.After(delay, function()
        if scanState.inProgress and self:IsBankOpen() then
            self:QueryAndScanTab()
        end
    end)
end

--- Complete the scan and store results.
function GBL:FinalizeScan()
    local results = scanState.results
    local elapsed = GetServerTime() - scanState.startTime
    local totalItems = 0

    for _, tabResult in pairs(results) do
        totalItems = totalItems + tabResult.itemCount
    end

    self.lastScanTime = GetServerTime()
    self.lastScanResults = results
    self.scanInProgress = false
    scanState.inProgress = false

    if self.db.profile.scanning.notifyOnScan then
        local tabCount = #scanState.viewableTabs
        self:Print(format("Scan complete: %d items across %d tabs (%ds)",
            totalItems, tabCount, elapsed))
    end

    -- Per-tab diagnostic summary: occupied count, how the tab's data arrived
    -- (event vs query-timeout), and any locked-slot skips. A display tab
    -- reading 0(timeout) or locked=N while reality holds items is the
    -- cold-snapshot fingerprint behind phantom sort plans.
    local parts = {}
    for _, tabIndex in ipairs(scanState.viewableTabs) do
        local tr = results[tabIndex]
        if tr then
            local seg = string.format("T%d=%d(%s", tabIndex, tr.itemCount,
                tr.completedVia or "?")
            if (tr.lockedSkips or 0) > 0 then
                seg = seg .. string.format(",locked=%d", tr.lockedSkips)
            end
            table.insert(parts, seg .. ")")
        end
    end
    self:SystemInfo("Scan: %s (%d total, %ds)",
        table.concat(parts, " "), totalItems, elapsed)

    self:SendMessage("GBL_SCAN_COMPLETE", results, totalItems)
end

--- Cancel a pending scan (e.g., bank closed mid-scan).
function GBL:CancelPendingScan()
    if scanState.pendingTimer then
        scanState.pendingTimer.cancelled = true
        scanState.pendingTimer = nil
    end

    if scanState.waitingForData then
        pcall(function() self:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED") end)
    end

    resetScanState()
    self.scanInProgress = false
end

--- Get the most recent scan results.
-- @return table|nil Results table keyed by tab index
function GBL:GetLastScanResults()
    return self.lastScanResults
end

------------------------------------------------------------------------
-- Bag scanning (#139: include bags in sort)
------------------------------------------------------------------------

-- Bags enter the sort pipeline as NEGATIVE pseudo-tab indices so the
-- planner can treat them as ordinary source-only tabs without ever
-- colliding with bank tabs 1..8 or entering layout.tabs, whose
-- BankLayout.Validate rejects tabIndex < 1 by design.
local BAG_ID_MIN, BAG_ID_MAX = 0, 5

--- Encode a bagID (0-5) as a planner pseudo-tab index (-1..-6).
function GBL:TabFromBagID(bagID)
    return -(bagID + 1)
end

--- Decode a pseudo-tab index back to a bagID, or nil when the tab is a
--- bank tab or outside the bag range.
function GBL:BagIDFromTab(tab)
    if type(tab) ~= "number" or tab >= 0 then return nil end
    local bagID = -tab - 1
    if bagID < BAG_ID_MIN or bagID > BAG_ID_MAX then return nil end
    return bagID
end

--- Render a slot reference for logs and UI: "T3/12" for bank tabs,
--- "Bag0/5" for bag pseudo-tabs. Every sort-side render site routes
--- through this so a negative tab can never surface as "T-1".
function GBL:FormatSlotRef(tab, slot)
    local bagID = self:BagIDFromTab(tab)
    if bagID then
        return string.format("Bag%d/%d", bagID, slot)
    end
    return string.format("T%d/%d", tab, slot)
end

--- Synchronously scan the player's bags (0-4, plus the reagent bag when
--- the client has one) into a bank-shaped snapshot keyed by pseudo-tab.
--- No query round-trip and no events: C_Container reads are local.
---
--- This is source-only data for the sort planner (opts.bagSnapshot).
--- Skipped with per-bag counters: bound items (the server refuses them
--- at the guild bank), locked slots, and slots without a parseable item
--- link (caged pets, item data not yet streamed).
-- @return table { [pseudoTab] = { slots, itemCount, boundSkips,
--   lockedSkips, noLink } }, empty when C_Container is unavailable
function GBL:ScanBags()
    local results = {}
    if not (C_Container and C_Container.GetContainerNumSlots
            and C_Container.GetContainerItemInfo) then
        return results
    end

    -- Resolved at call time: Scanner loads before BankLayout in the .toc.
    local BankLayout = self.BankLayout
    local extract = BankLayout and BankLayout.ExtractItemID

    local bagIDs = { 0, 1, 2, 3, 4 }
    if Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag then
        table.insert(bagIDs, Enum.BagIndex.ReagentBag)
    end

    local warmed = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
        if numSlots > 0 then
            local tabIndex = self:TabFromBagID(bagID)
            local tabResult = {
                slots = {}, itemCount = 0,
                boundSkips = 0, lockedSkips = 0, noLink = 0,
            }
            for slotIndex = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bagID, slotIndex)
                if type(info) == "table" then
                    local itemID = extract and extract(info.hyperlink) or nil
                    if info.isBound then
                        tabResult.boundSkips = tabResult.boundSkips + 1
                    elseif info.isLocked then
                        tabResult.lockedSkips = tabResult.lockedSkips + 1
                    elseif not itemID then
                        tabResult.noLink = tabResult.noLink + 1
                    else
                        tabResult.slots[slotIndex] = {
                            itemLink = info.hyperlink,
                            texture = info.iconFileID,
                            count = info.stackCount or 1,
                            slotIndex = slotIndex,
                            tabIndex = tabIndex,
                            itemID = itemID,
                        }
                        tabResult.itemCount = tabResult.itemCount + 1
                        if not warmed[itemID] then
                            warmed[itemID] = true
                            -- Kick the async stack-size load now so the
                            -- planner's maxStack lookups are warm by sort
                            -- time rather than the follow-up sort.
                            self:GetMaxStack(itemID)
                        end
                    end
                end
            end
            results[tabIndex] = tabResult
        end
    end
    return results
end

------------------------------------------------------------------------
-- Event handler
------------------------------------------------------------------------

function GBL:GUILDBANKBAGSLOTS_CHANGED()
    if scanState.inProgress and scanState.waitingForData then
        self:TryScanCurrentTab(true)
    end
end
