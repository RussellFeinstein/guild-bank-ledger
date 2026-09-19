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
    -- #178 probe tally for the current scan. See noteLinkless below. It sits
    -- here rather than on the tab result so the snapshot shape stays exactly
    -- as it is, and so removing the probe is a pure delete.
    linkless = nil,
}

local function freshLinkless()
    return { total = 0, textureOnly = 0, countOnly = 0, both = 0, neither = 0 }
end

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
    scanState.linkless = freshLinkless()
end

--- Record what a slot with no item link reported (#178).
-- Such a slot is skipped exactly as an empty slot is, and nothing in ScanTab
-- can tell the two apart: the item link is the only signal the admit path has
-- ever read, so it never reaches GetGuildBankItemInfo when the link is nil.
-- This measures whether the info call answers for such a slot, so the bank
-- `nolink` counter #178 asks for can be built on an observed predicate rather
-- than on a guess about the API.
--
-- **A zero reading is a statement about the client's item cache, not about the
-- API.** The case is produced by a cold cache, so a capture taken on a warm
-- client reads zero whatever GetGuildBankItemInfo is capable of. Only a
-- reading above zero closes the question.
--
-- Temporary by design: it goes when the counter lands.
local function noteLinkless(texture, count)
    local lk = scanState.linkless
    if not lk then return end

    lk.total = lk.total + 1
    local hasTexture = texture ~= nil
    -- A count of zero is an empty slot, not an occupancy signal.
    local hasCount = (count or 0) > 0

    if hasTexture and hasCount then
        lk.both = lk.both + 1
    elseif hasTexture then
        lk.textureOnly = lk.textureOnly + 1
    elseif hasCount then
        lk.countOnly = lk.countOnly + 1
    else
        lk.neither = lk.neither + 1
    end
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
        -- Read the info first so the link-less branch can say whether the slot
        -- reported anything (#178). For a linked slot this is the same call
        -- the admit path always made, so nothing about admission moves: the
        -- link still gates it, and a locked slot is still only counted when it
        -- has a link.
        local texture, count, locked = GetGuildBankItemInfo(tabIndex, slotIndex)
        local itemLink = GetGuildBankItemLink(tabIndex, slotIndex)
        if itemLink then
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
        else
            noteLinkless(texture, count)
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
    -- What the scan could look at, recorded here and nowhere else. A tab
    -- missing from the results is hidden from this rank or unpurchased,
    -- and the planner reads both as an empty tab without this (#137).
    -- Copied because scanState is working memory, not a record.
    local covered = {}
    for i, tabIndex in ipairs(scanState.viewableTabs) do covered[i] = tabIndex end
    self.lastScanCoverage = { viewableTabs = covered }
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

    -- #178 probe. The denominator is every slot with no item link, which on
    -- any real bank is mostly ordinary empty slots, so the figure that matters
    -- leads: how many of them reported occupancy anyway. Read it back from a
    -- capture with:
    --   lua scripts/audit-sessions.lua <path> --session N --channel system
    local lk = scanState.linkless or {}
    local withData = (lk.textureOnly or 0) + (lk.countOnly or 0) + (lk.both or 0)
    self:SystemInfo(
        "Scan linkless: %d no-link slot(s), %d with data "
        .. "[texture-only=%d count-only=%d both=%d neither=%d]",
        lk.total or 0, withData, lk.textureOnly or 0, lk.countOnly or 0,
        lk.both or 0, lk.neither or 0)

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

--- Get the tabs the most recent finished scan was able to read.
-- An empty viewableTabs list is a different fact from nil: it means a
-- scan ran and saw no tab, so every declared tab is hidden, while nil
-- means no scan has finished and nothing may be concluded from it.
-- @return table|nil { viewableTabs = { tabIndex, ... } }
function GBL:GetLastScanCoverage()
    return self.lastScanCoverage
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
    -- A fractional tab lands inside the range check and decodes to a
    -- fractional bagID, which C_Container would take as a bag index.
    -- Nothing produces one today; this is the boundary that keeps it
    -- that way, so it refuses rather than rounds.
    if bagID ~= math.floor(bagID) then return nil end
    return bagID
end

--- Render a slot reference for logs and UI: "T3/12" for bank tabs,
--- "Bag0/5" for bag pseudo-tabs. Sort-side render sites route through
--- this rather than formatting a tab index themselves, which is what
--- keeps a negative tab from ever surfacing as "T-1".
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
--- Slot entries carry an itemID field that bank slots from ScanTab do
--- NOT: the scan already resolved it for the noLink check, so emitting
--- it saves the planner a pattern match per bag slot. SortPlanner reads
--- `slot.itemID or extractItemID(slot.itemLink)` and so takes either
--- shape. Do not assume a bank snapshot slot has the field.
-- @return table { [pseudoTab] = { slots, itemCount, boundSkips,
--   lockedSkips, noLink } }, empty when C_Container is unavailable
function GBL:ScanBags()
    local results = {}
    if not (C_Container and C_Container.GetContainerNumSlots
            and C_Container.GetContainerItemInfo) then
        return results
    end

    -- Scanner loads before BankLayout in the .toc, so ExtractItemID is
    -- resolved at call time and can legitimately be absent. SortPlanner
    -- and Restock carry the same inline fallback; without it every bag
    -- slot counts as noLink and the sort sees empty bags.
    local BankLayout = self.BankLayout
    local extract = BankLayout and BankLayout.ExtractItemID
    if not extract then
        extract = function(itemLink)
            if type(itemLink) ~= "string" then return nil end
            local id = itemLink:match("Hitem:(%d+)")
            return id and tonumber(id) or nil
        end
    end

    local bagIDs = { 0, 1, 2, 3, 4 }
    -- The reagent bag index comes from the client. Admit it only if it
    -- round-trips through the pseudo-tab encoding: a value outside 0-5
    -- would encode to a tab BagIDFromTab cannot decode, so the executor
    -- could never turn the resulting op back into a bag slot.
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagent and self:BagIDFromTab(self:TabFromBagID(reagent)) == reagent then
        table.insert(bagIDs, reagent)
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
                        if not warmed[itemID] and self.GetMaxStack then
                            warmed[itemID] = true
                            -- Kick the async stack-size load now so the
                            -- planner's maxStack lookups are warm by sort
                            -- time rather than the follow-up sort. Guarded
                            -- for the same load-order reason as extract
                            -- above: warming is an optimisation and must
                            -- not take the scan down with it.
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
