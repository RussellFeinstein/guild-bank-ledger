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
function GBL:QueryAndScanTab()
    local tabIndex = scanState.viewableTabs[scanState.tabIndex]
    if not tabIndex then
        self:FinalizeScan()
        return
    end

    scanState.currentTab = tabIndex
    scanState.waitingForData = true

    -- Register for slot data event
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")

    -- Request tab data from server
    QueryGuildBankTab(tabIndex)

    -- Also try scanning immediately (data may already be cached)
    self:TryScanCurrentTab()
end

--- Attempt to scan the current tab's slots.
-- Called after QueryGuildBankTab and on GUILDBANKBAGSLOTS_CHANGED.
function GBL:TryScanCurrentTab()
    if not scanState.inProgress then
        return
    end

    local tabIndex = scanState.currentTab
    self:ScanTab(tabIndex)

    scanState.waitingForData = false
    self:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    self:ScanNextTab()
end

--- Scan all 98 slots in a single tab.
-- @param tabIndex number The tab to scan
function GBL:ScanTab(tabIndex)
    local tabResult = { slots = {}, itemCount = 0 }

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
-- Event handler
------------------------------------------------------------------------

function GBL:GUILDBANKBAGSLOTS_CHANGED()
    if scanState.inProgress and scanState.waitingForData then
        self:TryScanCurrentTab()
    end
end
