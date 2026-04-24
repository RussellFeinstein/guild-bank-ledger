------------------------------------------------------------------------
-- GuildBankLedger — UI/LayoutEditor.lua
-- Layout tab: per-tab mode picker + item template editor + Sort Access.
--
-- Write operations are gated by HasSortAccess(). The Sort Access
-- sub-section (rank threshold + delegate list) is GM-only to edit.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local MAX_TABS = MAX_GUILDBANK_TABS or 8
local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98

local MODE_VALUES = { "display", "overflow", "ignore" }
local MODE_LABELS = {
    display = "Display (items kept at fixed slots/counts)",
    overflow = "Overflow (bulk stock; sort's dumping ground)",
    ignore   = "Ignore (never touched by sort)",
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function extractItemID(itemLink)
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

local function itemLabelFor(itemID)
    if not itemID then return "?" end
    local name = nil
    if GBL.GetCachedItemInfo then
        name = GBL:GetCachedItemInfo(itemID)
    end
    if name then
        return name .. "  |cff888888(id " .. itemID .. ")|r"
    end
    return "item " .. itemID
end

local function bankTabName(tabIndex)
    if GetGuildBankTabInfo then
        local name = GetGuildBankTabInfo(tabIndex)
        if name and name ~= "" then return name end
    end
    return "Tab " .. tabIndex
end

--- Group slotOrder entries into contiguous same-item runs.
--
-- Pure function. Given `slotOrder[slotIndex] = itemID`, returns a
-- slot-index-ordered list of `{startSlot, endSlot, itemID, length}`.
-- A run never crosses an empty slot — a nil entry breaks the sequence
-- even if the same itemID resumes immediately after. Isolated single
-- slots produce length-1 runs, which is what makes v0.29.12-style
-- one-slot anomalies visually obvious in the Layout editor.
local function computeSlotRuns(slotOrder)
    local runs = {}
    if type(slotOrder) ~= "table" then return runs end
    local currentID, currentStart, currentEnd = nil, nil, nil
    for s = 1, MAX_SLOTS do
        local id = slotOrder[s]
        if id == currentID and id ~= nil and currentEnd == s - 1 then
            currentEnd = s
        else
            if currentID ~= nil then
                table.insert(runs, {
                    startSlot = currentStart,
                    endSlot = currentEnd,
                    itemID = currentID,
                    length = currentEnd - currentStart + 1,
                })
            end
            if id ~= nil then
                currentID = id
                currentStart = s
                currentEnd = s
            else
                currentID = nil
                currentStart = nil
                currentEnd = nil
            end
        end
    end
    if currentID ~= nil then
        table.insert(runs, {
            startSlot = currentStart,
            endSlot = currentEnd,
            itemID = currentID,
            length = currentEnd - currentStart + 1,
        })
    end
    return runs
end

-- Expose the pure helper for the spec suite.
GBL._layoutEditorComputeSlotRuns = computeSlotRuns

------------------------------------------------------------------------
-- Working-copy state
--
-- The Layout editor works on a draft that mirrors GetBankLayout() and is
-- persisted on "Save". This lets the user tweak multiple fields before
-- committing.
------------------------------------------------------------------------

local function freshDraft(self)
    local layout = self:GetBankLayout()
    -- Ensure every tab index exists as SOMETHING, default "ignore" so the
    -- UI can show a row per tab.
    for i = 1, MAX_TABS do
        if not layout.tabs[i] then
            layout.tabs[i] = { mode = "ignore" }
        end
    end
    return layout
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the Layout tab inside a container.
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildLayoutTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local writable = self:HasSortAccess()
    local isGM = self:IsGuildMaster()

    -- Root scroll. A persistent SetStatusTable lets the ScrollFrame's
    -- scroll position survive RefreshLayoutTab rebuilds — without this,
    -- pressing Enter on any EditBox would rebuild the whole tab and
    -- scroll back to the top, making mid-page edits miserable.
    if not self._layoutScrollStatus then
        self._layoutScrollStatus = {}
    end
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("Flow")
    scroll:SetStatusTable(self._layoutScrollStatus)
    container:AddChild(scroll)
    self._layoutContainer = scroll

    -- Access summary banner
    local banner = AceGUI:Create("Label")
    banner:SetFullWidth(true)
    banner:SetFontObject(GameFontNormalSmall)
    if not writable then
        banner:SetText(
            "|cffffcc00Read-only view.|r Only the Guild Master and delegated ranks/characters can edit the layout. " ..
            "Ask the GM to grant you access via the Sort Access section below.")
    else
        local why
        if self:IsGuildMaster() then why = "GM"
        else why = "rank-or-delegate" end
        banner:SetText(format("|cff00ff88Write access:|r %s.", why))
    end
    scroll:AddChild(banner)

    -- Draft state — initialize from storage only if we don't already have
    -- one in progress. Refresh-on-mode-change must not wipe pending edits.
    -- Save and Discard both explicitly reset the draft.
    if not self._layoutDraft then
        self._layoutDraft = freshDraft(self)
        self._layoutDirty = false
    end

    -- ------------------------------------------------------------------
    -- Per-tab rows: mode picker + (if display) item template editor.
    -- ------------------------------------------------------------------
    self:_LayoutEditor_RenderTabs(scroll, writable)

    -- ------------------------------------------------------------------
    -- Save bar. Explicit save model: edits buffer in a draft until you
    -- click Save Layout. Dirty-state indicator makes it obvious when
    -- changes are pending.
    -- ------------------------------------------------------------------
    local statusBanner = AceGUI:Create("Label")
    statusBanner:SetFullWidth(true)
    statusBanner:SetFontObject(GameFontNormalSmall)
    if not writable then
        statusBanner:SetText(
            "|cff888888Edits require sort access. Viewing the saved layout read-only.|r")
    elseif self._layoutDirty then
        statusBanner:SetText(
            "|cffffcc00You have unsaved changes.|r " ..
            "Click |cffffffffSave Layout|r to commit them (and broadcast to the guild), " ..
            "or |cffffffffDiscard changes|r to throw them away.")
    else
        statusBanner:SetText(
            "|cff888888Layout is up to date. " ..
            "Changes you make here buffer until you click Save Layout.|r")
    end
    scroll:AddChild(statusBanner)

    local saveRow = AceGUI:Create("SimpleGroup")
    saveRow:SetFullWidth(true)
    saveRow:SetLayout("Flow")
    scroll:AddChild(saveRow)

    local spacer = AceGUI:Create("Label")
    spacer:SetWidth(20)
    saveRow:AddChild(spacer)

    local saveBtn = AceGUI:Create("Button")
    saveBtn:SetWidth(200)
    if not writable then
        saveBtn:SetText("Save Layout (no access)")
        saveBtn:SetDisabled(true)
    elseif self._layoutDirty then
        saveBtn:SetText("Save Layout")
        saveBtn:SetDisabled(false)
    else
        saveBtn:SetText("Saved \226\156\147")  -- "Saved ✓"
        saveBtn:SetDisabled(true)
    end
    saveBtn:SetCallback("OnClick", function()
        local ok, err = self:SaveBankLayout(self._layoutDraft)
        if ok then
            self:Print("Layout saved (v" .. self:GetBankLayout().version .. ").")
            self:AddAuditEntry("Layout: saved by " ..
                (UnitName("player") or "?") .. " (v" .. self:GetBankLayout().version .. ")")
            self._layoutDraft = nil   -- re-init from storage on next render
            self._layoutDirty = false
            self:RefreshLayoutTab()
        else
            self:Print("|cffff5555Layout save failed:|r " .. tostring(err))
        end
    end)
    saveRow:AddChild(saveBtn)

    local discardBtn = AceGUI:Create("Button")
    discardBtn:SetText("Discard changes")
    discardBtn:SetWidth(160)
    discardBtn:SetDisabled(not (writable and self._layoutDirty))
    discardBtn:SetCallback("OnClick", function()
        self._layoutDraft = nil   -- re-init from storage on next render
        self._layoutDirty = false
        self:RefreshLayoutTab()
    end)
    saveRow:AddChild(discardBtn)

    -- ------------------------------------------------------------------
    -- Sort Access section (GM-only to edit).
    -- ------------------------------------------------------------------
    local saHeading = AceGUI:Create("Heading")
    saHeading:SetFullWidth(true)
    saHeading:SetText("Sort Access")
    scroll:AddChild(saHeading)

    self:_LayoutEditor_RenderSortAccess(scroll, isGM)
end

--- Re-render the Layout tab (called after save / revert / capture /
--- field edits). Scroll position is preserved across the rebuild via
--- a persistent status table: the ScrollFrame reads scrollvalue from
--- it at construction time, and we nudge it back into sync after
--- content layout has settled (AceGUI applies scroll in LayoutFinished,
--- so restoring on the next frame is the reliable timing).
---
--- The rebuild itself is visible — Release briefly blanks everything,
--- Build repopulates starting at scroll=0, then SetScroll snaps to the
--- saved value. That snap flickers noticeably in-game. To mask it, we
--- set the TabGroup's content frame alpha to 0 for the duration, then
--- restore to 1 once scroll has been reapplied. `self.tabGroup.content`
--- is a stable frame owned by the TabGroup, so it persists across the
--- Release/Build cycle — the new ScrollFrame becomes a child of the
--- same (still-hidden) content, so nothing leaks through.
function GBL:RefreshLayoutTab()
    if self.activeTab ~= "layout" then return end
    if not self.tabGroup then return end

    local savedScroll = self._layoutScrollStatus
        and self._layoutScrollStatus.scrollvalue or 0

    local content = self.tabGroup.content
    if content and content.SetAlpha then content:SetAlpha(0) end

    self.tabGroup:ReleaseChildren()
    self:BuildLayoutTab(self.tabGroup)

    local function reveal()
        if self._layoutContainer and self._layoutContainer.SetScroll
           and savedScroll and savedScroll > 0 then
            self._layoutContainer:SetScroll(savedScroll)
        end
        if content and content.SetAlpha then content:SetAlpha(1) end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, reveal)
    else
        reveal()
    end
end

------------------------------------------------------------------------
-- Per-tab rendering
------------------------------------------------------------------------

function GBL:_LayoutEditor_RenderTabs(parent, writable)
    local AceGUI = LibStub("AceGUI-3.0")
    local draft = self._layoutDraft

    for tabIndex = 1, MAX_TABS do
        local tab = draft.tabs[tabIndex] or { mode = "ignore" }
        draft.tabs[tabIndex] = tab

        local group = AceGUI:Create("InlineGroup")
        group:SetFullWidth(true)
        group:SetLayout("Flow")
        group:SetTitle("Tab " .. tabIndex .. ": " .. bankTabName(tabIndex))
        parent:AddChild(group)

        -- Mode dropdown
        local dropdown = AceGUI:Create("Dropdown")
        dropdown:SetLabel("Mode")
        dropdown:SetList({
            display  = MODE_LABELS.display,
            overflow = MODE_LABELS.overflow,
            ignore   = MODE_LABELS.ignore,
        }, MODE_VALUES)
        dropdown:SetValue(tab.mode)
        dropdown:SetWidth(380)
        dropdown:SetDisabled(not writable)
        dropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
            draft.tabs[tabIndex] = { mode = value }
            if value == "display" then
                draft.tabs[tabIndex].items = {}
                draft.tabs[tabIndex].slotOrder = {}
            end
            self._layoutDirty = true
            self:RefreshLayoutTab()
        end)
        group:AddChild(dropdown)

        if tab.mode == "display" then
            self:_LayoutEditor_RenderDisplayDetails(group, tabIndex, writable)
        end
    end
end

function GBL:_LayoutEditor_RenderDisplayDetails(parent, tabIndex, writable)
    local AceGUI = LibStub("AceGUI-3.0")
    local draft = self._layoutDraft
    local tab = draft.tabs[tabIndex]
    tab.items = tab.items or {}
    tab.slotOrder = tab.slotOrder or {}

    -- Capture button row
    local captureRow = AceGUI:Create("SimpleGroup")
    captureRow:SetFullWidth(true)
    captureRow:SetLayout("Flow")
    parent:AddChild(captureRow)

    local captureBtn = AceGUI:Create("Button")
    captureBtn:SetText("Capture current layout")
    captureBtn:SetWidth(200)
    captureBtn:SetDisabled(not writable)

    local function applyCapture()
        local captured, err = self:CaptureTabLayout(tabIndex)
        if not captured then
            self:Print(format("|cffff5555Capture tab %d failed:|r %s",
                tabIndex, tostring(err)))
            return
        end
        local n = 0
        for _ in pairs(captured.items) do n = n + 1 end
        draft.tabs[tabIndex] = captured
        self._layoutDirty = true
        self:Print(format("|cff00ff88Captured tab %d:|r %d distinct item(s). " ..
            "Click |cffffffffSave Layout|r to commit.",
            tabIndex, n))
        self:RefreshLayoutTab()
    end

    captureBtn:SetCallback("OnClick", function()
        -- Guard: bank must be open so scan has real data to read.
        if not self:IsBankOpen() then
            self:Print("|cffffcc00Open the guild bank before capturing.|r")
            return
        end
        -- Already-complete scan covering this tab? Just apply.
        if self.lastScanResults and self.lastScanResults[tabIndex] then
            applyCapture()
            return
        end
        -- Otherwise trigger a scan and poll for its completion.
        self:Print(format("Scanning bank before capturing tab %d...", tabIndex))
        if not self.scanInProgress then
            self:StartFullScan()
        end
        local deadline = GetTime() + 5
        local function poll()
            if self.lastScanResults and self.lastScanResults[tabIndex] then
                applyCapture()
            elseif GetTime() < deadline then
                C_Timer.After(0.25, poll)
            else
                self:Print(format(
                    "|cffff5555Capture tab %d failed:|r scan did not complete " ..
                    "within 5s, or tab %d is not viewable to this character.",
                    tabIndex, tabIndex))
            end
        end
        C_Timer.After(0.25, poll)
    end)
    captureRow:AddChild(captureBtn)

    local captureHint = AceGUI:Create("Label")
    captureHint:SetWidth(400)
    captureHint:SetText(
        "|cff888888Reads the latest scan for this tab and rebuilds the template " ..
        "to match it exactly (items, slot order, stack sizes).|r")
    captureHint:SetFontObject(GameFontNormalSmall)
    captureRow:AddChild(captureHint)

    -- Item rows table
    local totalSlots = 0
    for _, row in pairs(tab.items) do totalSlots = totalSlots + row.slots end
    local budgetLabel = AceGUI:Create("Label")
    budgetLabel:SetFullWidth(true)
    budgetLabel:SetFontObject(GameFontNormalSmall)
    local budgetColor = (totalSlots > MAX_SLOTS) and "|cffff5555" or "|cff888888"
    budgetLabel:SetText(format("%sSlot budget: %d / %d used|r",
        budgetColor, totalSlots, MAX_SLOTS))
    parent:AddChild(budgetLabel)

    -- Collect itemIDs so we can render a sorted list deterministically.
    local itemIDs = {}
    for itemID in pairs(tab.items) do itemIDs[#itemIDs + 1] = itemID end
    table.sort(itemIDs)

    if #itemIDs == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetFullWidth(true)
        empty:SetText("|cff888888(no items configured — use Capture or Add Item)|r")
        parent:AddChild(empty)
    else
        for _, itemID in ipairs(itemIDs) do
            self:_LayoutEditor_RenderItemRow(parent, tabIndex, itemID, writable)
        end
    end

    -- Slot map: visualize slotOrder runs with live-scan comparison so a
    -- user can see which slots are pinned to what and where the bank
    -- currently diverges from the layout. Motivated by v0.29.12's
    -- "hidden slot-swap" incident where two layouts with identical
    -- per-item counts looked identical in the editor despite one
    -- having S24 and S50 swapped.
    if #itemIDs > 0 then
        self:_LayoutEditor_RenderSlotMap(parent, tabIndex)
    end

    -- Add-item row
    if writable then
        local addRow = AceGUI:Create("SimpleGroup")
        addRow:SetFullWidth(true)
        addRow:SetLayout("Flow")
        parent:AddChild(addRow)

        local input = AceGUI:Create("EditBox")
        input:SetLabel("Add item (itemID or paste item link)")
        input:SetWidth(260)
        input:DisableButton(true)
        addRow:AddChild(input)

        local slotsInput = AceGUI:Create("EditBox")
        slotsInput:SetLabel("Slots")
        slotsInput:SetWidth(80)
        slotsInput:SetText("1")
        slotsInput:DisableButton(true)
        addRow:AddChild(slotsInput)

        local perSlotInput = AceGUI:Create("EditBox")
        perSlotInput:SetLabel("Per slot")
        perSlotInput:SetWidth(80)
        perSlotInput:SetText("20")
        perSlotInput:DisableButton(true)
        addRow:AddChild(perSlotInput)

        local addBtn = AceGUI:Create("Button")
        addBtn:SetText("Add")
        addBtn:SetWidth(80)
        addBtn:SetCallback("OnClick", function()
            local raw = input:GetText() or ""
            local id = extractItemID(raw) or tonumber(raw)
            if not id then
                self:Print("Enter a numeric itemID or paste an item link.")
                return
            end
            local slots = tonumber(slotsInput:GetText()) or 1
            local perSlot = tonumber(perSlotInput:GetText()) or 1
            if slots < 1 or perSlot < 1 then
                self:Print("Slots and Per slot must be >= 1.")
                return
            end
            tab.items[id] = { slots = slots, perSlot = perSlot }
            -- slotOrder is intentionally NOT populated here. Only Capture
            -- writes pinned slot positions; SortPlanner Pass 2 places
            -- Add-Item entries at plan time using the same right/left/
            -- first-empty adjacency the UI used to do, so the planned
            -- layout is identical without the semantic ambiguity of
            -- heuristically-pinned positions the user never chose.
            self._layoutDirty = true
            self:RefreshLayoutTab()
        end)
        addRow:AddChild(addBtn)
    end
end

function GBL:_LayoutEditor_RenderItemRow(parent, tabIndex, itemID, writable)
    local AceGUI = LibStub("AceGUI-3.0")
    local draft = self._layoutDraft
    local tab = draft.tabs[tabIndex]
    local row = tab.items[itemID]
    if not row then return end

    local rowGroup = AceGUI:Create("SimpleGroup")
    rowGroup:SetFullWidth(true)
    rowGroup:SetLayout("Flow")
    parent:AddChild(rowGroup)

    local label = AceGUI:Create("Label")
    label:SetWidth(260)
    label:SetText(itemLabelFor(itemID))
    rowGroup:AddChild(label)

    local slotsInput = AceGUI:Create("EditBox")
    slotsInput:SetLabel("Slots")
    slotsInput:SetWidth(80)
    slotsInput:SetText(tostring(row.slots))
    slotsInput:SetDisabled(not writable)
    slotsInput:DisableButton(true)
    slotsInput:SetCallback("OnEnterPressed", function(_w, _e, value)
        local n = tonumber(value)
        if n and n >= 1 then
            local old = row.slots or 0
            row.slots = n
            -- On decrease, trim stale slotOrder pins from the highest
            -- slot down so a previously-captured layout that got shrunk
            -- doesn't retain dangling pins above the new count. On
            -- increase we intentionally leave slotOrder alone — planner
            -- Pass 2 extends the claim adjacent to existing pins at plan
            -- time, which is the same algorithm the UI used to run.
            if n < old then
                local toRemove = old - n
                for s = MAX_SLOTS, 1, -1 do
                    if toRemove <= 0 then break end
                    if tab.slotOrder[s] == itemID then
                        tab.slotOrder[s] = nil
                        toRemove = toRemove - 1
                    end
                end
            end
            self._layoutDirty = true
            self:RefreshLayoutTab()
        end
    end)
    rowGroup:AddChild(slotsInput)

    local perSlotInput = AceGUI:Create("EditBox")
    perSlotInput:SetLabel("Per slot")
    perSlotInput:SetWidth(80)
    perSlotInput:SetText(tostring(row.perSlot))
    perSlotInput:SetDisabled(not writable)
    perSlotInput:DisableButton(true)
    perSlotInput:SetCallback("OnEnterPressed", function(_w, _e, value)
        local n = tonumber(value)
        if n and n >= 1 then
            row.perSlot = n
            self._layoutDirty = true
            self:RefreshLayoutTab()
        end
    end)
    rowGroup:AddChild(perSlotInput)

    local totalLabel = AceGUI:Create("Label")
    totalLabel:SetWidth(80)
    totalLabel:SetText(format("= %d", row.slots * row.perSlot))
    totalLabel:SetFontObject(GameFontNormalSmall)
    rowGroup:AddChild(totalLabel)

    if writable then
        local removeBtn = AceGUI:Create("Button")
        removeBtn:SetText("Remove")
        removeBtn:SetWidth(80)
        removeBtn:SetCallback("OnClick", function()
            tab.items[itemID] = nil
            -- Remove from slotOrder too.
            for s, id in pairs(tab.slotOrder) do
                if id == itemID then tab.slotOrder[s] = nil end
            end
            self._layoutDirty = true
            self:RefreshLayoutTab()
        end)
        rowGroup:AddChild(removeBtn)
    end
end

------------------------------------------------------------------------
-- Slot map (v0.29.14)
------------------------------------------------------------------------

--- Render a "Slot map" panel for a display tab.
--
-- Goal: surface `slotOrder` (which the editor's aggregate per-item rows
-- never show) and flag slots where the current bank scan disagrees with
-- the layout. Pure display — no editing controls. Writable flag isn't
-- needed here because nothing is editable.
function GBL:_LayoutEditor_RenderSlotMap(parent, tabIndex)
    local AceGUI = LibStub("AceGUI-3.0")
    local draft = self._layoutDraft
    local tab = draft and draft.tabs and draft.tabs[tabIndex]
    if not tab or tab.mode ~= "display" then return end

    local slotOrder = tab.slotOrder or {}
    local items = tab.items or {}

    -- Count pinned and unpinned slots per item so the summary can
    -- distinguish "pinned by Capture" from "planner-placed at sort time".
    local pinnedByItem, totalPinned = {}, 0
    for s = 1, MAX_SLOTS do
        local id = slotOrder[s]
        if id then
            pinnedByItem[id] = (pinnedByItem[id] or 0) + 1
            totalPinned = totalPinned + 1
        end
    end
    local unpinnedByItem, totalUnpinned = {}, 0
    for id, row in pairs(items) do
        local want = (row and row.slots) or 0
        local have = pinnedByItem[id] or 0
        if want > have then
            unpinnedByItem[id] = want - have
            totalUnpinned = totalUnpinned + (want - have)
        end
    end

    -- Live-scan comparison; all reads are nil-safe so the panel renders
    -- cleanly whether or not a scan has been taken yet.
    local scanTab = self.lastScanResults and self.lastScanResults[tabIndex]
    local scanSlots = scanTab and scanTab.slots or nil

    local runs = computeSlotRuns(slotOrder)
    local runMismatches = {}
    local totalMismatches = 0
    for i, run in ipairs(runs) do
        local list = {}
        if scanSlots then
            for s = run.startSlot, run.endSlot do
                local bankSlot = scanSlots[s]
                local bankID = bankSlot and extractItemID(bankSlot.itemLink) or nil
                if bankID ~= run.itemID then
                    table.insert(list, { slot = s, actualID = bankID })
                    totalMismatches = totalMismatches + 1
                end
            end
        end
        runMismatches[i] = list
    end

    local heading = AceGUI:Create("Heading")
    heading:SetFullWidth(true)
    heading:SetText("Slot map")
    parent:AddChild(heading)

    -- Header summary line.
    local summary = AceGUI:Create("Label")
    summary:SetFullWidth(true)
    summary:SetFontObject(GameFontNormalSmall)
    local parts = { format("%d/%d pinned", totalPinned, MAX_SLOTS) }
    if totalUnpinned > 0 then
        parts[#parts] = parts[#parts]
            .. format(" (%d auto-placed at sort time)", totalUnpinned)
    end
    if scanSlots then
        if totalMismatches == 0 then
            table.insert(parts, "|cff00ff88matches current bank|r")
        else
            table.insert(parts, format(
                "|cffff5555%d of %d slots differ from current bank|r",
                totalMismatches, MAX_SLOTS))
        end
    else
        table.insert(parts, "|cff888888(no scan loaded — comparison unavailable)|r")
    end
    summary:SetText(table.concat(parts, "; "))
    parent:AddChild(summary)

    -- Per-run lines.
    for i, run in ipairs(runs) do
        local itemRow = items[run.itemID]
        local perSlot = (itemRow and itemRow.perSlot) or 0
        local mismatches = runMismatches[i]
        local rangeStr
        if run.length == 1 then
            rangeStr = format("S%d", run.startSlot)
        else
            rangeStr = format("S%d-S%d", run.startSlot, run.endSlot)
        end
        local baseText = format("|cffcccccc%s (%d):|r  %s × %d",
            rangeStr, run.length, itemLabelFor(run.itemID), perSlot)
        local line = AceGUI:Create("Label")
        line:SetFullWidth(true)
        line:SetFontObject(GameFontNormalSmall)
        if not scanSlots then
            line:SetText(baseText)
        elseif #mismatches == 0 then
            line:SetText(baseText .. "  |cff00ff88✓|r")
        else
            line:SetText(format("%s  |cffff5555✗ %d mismatch(es)|r",
                baseText, #mismatches))
        end
        parent:AddChild(line)

        -- Detail for mismatched slots (capped at 5 per run to avoid flood).
        if scanSlots and #mismatches > 0 then
            for j = 1, math.min(5, #mismatches) do
                local m = mismatches[j]
                local detail = AceGUI:Create("Label")
                detail:SetFullWidth(true)
                detail:SetFontObject(GameFontNormalSmall)
                local actualStr
                if m.actualID then
                    actualStr = "has " .. itemLabelFor(m.actualID)
                else
                    actualStr = "is empty"
                end
                detail:SetText(format("    |cffff8888S%d %s|r",
                    m.slot, actualStr))
                parent:AddChild(detail)
            end
            if #mismatches > 5 then
                local more = AceGUI:Create("Label")
                more:SetFullWidth(true)
                more:SetFontObject(GameFontNormalSmall)
                more:SetText(format("    |cff888888(+%d more not shown)|r",
                    #mismatches - 5))
                parent:AddChild(more)
            end
        end
    end

    -- Unpinned capacity: items with slots > pinned count render here so
    -- the user can see "Light's Potential has 5 slots the planner will
    -- place at sort time" instead of those slots silently going missing
    -- from the slot map.
    if totalUnpinned > 0 then
        local header = AceGUI:Create("Label")
        header:SetFullWidth(true)
        header:SetFontObject(GameFontNormalSmall)
        header:SetText(format(
            "|cffccccff%d slot(s) auto-placed at sort time:|r", totalUnpinned))
        parent:AddChild(header)

        local sortedIDs = {}
        for id in pairs(unpinnedByItem) do table.insert(sortedIDs, id) end
        table.sort(sortedIDs)
        for _, id in ipairs(sortedIDs) do
            local itemRow = items[id]
            local perSlot = (itemRow and itemRow.perSlot) or 0
            local line = AceGUI:Create("Label")
            line:SetFullWidth(true)
            line:SetFontObject(GameFontNormalSmall)
            line:SetText(format("    %s × %d  (%d slot(s))",
                itemLabelFor(id), perSlot, unpinnedByItem[id]))
            parent:AddChild(line)
        end
    end
end

------------------------------------------------------------------------
-- Sort Access sub-section
------------------------------------------------------------------------

function GBL:_LayoutEditor_RenderSortAccess(parent, isGM)
    local AceGUI = LibStub("AceGUI-3.0")

    local sa = self:GetSortAccess()
    local numRanks = (GuildControlGetNumRanks and GuildControlGetNumRanks()) or 0

    local summary = AceGUI:Create("Label")
    summary:SetFullWidth(true)
    summary:SetFontObject(GameFontNormalSmall)
    local who = "GM only"
    if sa.rankThreshold ~= nil then
        who = "GM + ranks ≤ " .. sa.rankThreshold
    end
    local delegateCount = 0
    for _ in pairs(sa.delegates) do delegateCount = delegateCount + 1 end
    if delegateCount > 0 then
        who = who .. " + " .. delegateCount .. " delegate(s)"
    end
    summary:SetText("|cff00ff88Current policy:|r " .. who)
    parent:AddChild(summary)

    if not isGM then
        local note = AceGUI:Create("Label")
        note:SetFullWidth(true)
        note:SetFontObject(GameFontNormalSmall)
        note:SetText("|cffffcc00Only the Guild Master can change sort access.|r")
        parent:AddChild(note)
        -- Still render the delegate list read-only so delegates can see themselves.
    end

    -- Rank threshold picker.
    -- AceGUI Dropdown:SetList(items, order) expects `items` to be a HASH
    -- keyed by the option value (the thing passed to SetValue / OnValueChanged).
    -- We use -1 as the sentinel for "no rank-based access, GM only".
    local rankRow = AceGUI:Create("SimpleGroup")
    rankRow:SetFullWidth(true)
    rankRow:SetLayout("Flow")
    parent:AddChild(rankRow)

    local rankList = { [-1] = "None (GM only)" }
    local rankOrder = { -1 }
    for i = 0, math.max(0, numRanks - 1) do
        local rankName = GuildControlGetRankName and GuildControlGetRankName(i + 1) or ("Rank " .. i)
        rankList[i] = format("Rank %d and above (%s)", i, rankName)
        rankOrder[#rankOrder + 1] = i
    end

    local rankDD = AceGUI:Create("Dropdown")
    rankDD:SetLabel("Grant to rank and above")
    rankDD:SetWidth(360)
    rankDD:SetList(rankList, rankOrder)
    rankDD:SetValue(sa.rankThreshold == nil and -1 or sa.rankThreshold)
    rankDD:SetDisabled(not isGM)
    rankDD:SetCallback("OnValueChanged", function(_w, _e, value)
        local nextPolicy = {
            rankThreshold = (value == -1) and nil or value,
            delegates = sa.delegates,
        }
        local ok, err = self:SaveSortAccess(nextPolicy)
        if ok then
            self:Print("Sort Access updated.")
            self:RefreshLayoutTab()
        else
            self:Print("|cffff5555SortAccess save failed:|r " .. tostring(err))
        end
    end)
    rankRow:AddChild(rankDD)

    -- Delegate list
    local delegateHeading = AceGUI:Create("Label")
    delegateHeading:SetFullWidth(true)
    delegateHeading:SetText("|cff00ff88Delegates|r")
    parent:AddChild(delegateHeading)

    local names = {}
    for n in pairs(sa.delegates) do names[#names + 1] = n end
    table.sort(names)

    if #names == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetFullWidth(true)
        empty:SetFontObject(GameFontNormalSmall)
        empty:SetText("|cff888888(no delegates)|r")
        parent:AddChild(empty)
    else
        for _, name in ipairs(names) do
            local rowGroup = AceGUI:Create("SimpleGroup")
            rowGroup:SetFullWidth(true)
            rowGroup:SetLayout("Flow")
            parent:AddChild(rowGroup)

            local lbl = AceGUI:Create("Label")
            lbl:SetWidth(300)
            lbl:SetText(name)
            rowGroup:AddChild(lbl)

            if isGM then
                local rem = AceGUI:Create("Button")
                rem:SetText("Remove")
                rem:SetWidth(90)
                rem:SetCallback("OnClick", function()
                    local nextDelegates = {}
                    for k, v in pairs(sa.delegates) do nextDelegates[k] = v end
                    nextDelegates[name] = nil
                    local ok, err = self:SaveSortAccess({
                        rankThreshold = sa.rankThreshold,
                        delegates = nextDelegates,
                    })
                    if ok then self:RefreshLayoutTab() else self:Print(err) end
                end)
                rowGroup:AddChild(rem)
            end
        end
    end

    if isGM then
        local addRow = AceGUI:Create("SimpleGroup")
        addRow:SetFullWidth(true)
        addRow:SetLayout("Flow")
        parent:AddChild(addRow)

        local input = AceGUI:Create("EditBox")
        input:SetLabel("Add delegate (Name-Realm)")
        input:SetWidth(280)
        input:DisableButton(true)
        addRow:AddChild(input)

        local addBtn = AceGUI:Create("Button")
        addBtn:SetText("Add")
        addBtn:SetWidth(80)
        addBtn:SetCallback("OnClick", function()
            local v = input:GetText() or ""
            v = v:match("^%s*(.-)%s*$")  -- trim
            if v == "" then return end
            local nextDelegates = {}
            for k, vv in pairs(sa.delegates) do nextDelegates[k] = vv end
            nextDelegates[v] = true
            local ok, err = self:SaveSortAccess({
                rankThreshold = sa.rankThreshold,
                delegates = nextDelegates,
            })
            if ok then self:RefreshLayoutTab() else self:Print(err) end
        end)
        addRow:AddChild(addBtn)
    end
end
