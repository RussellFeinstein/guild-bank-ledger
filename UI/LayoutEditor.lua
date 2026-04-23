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

    -- Root scroll
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("Flow")
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

    -- Draft state attached to the widget so OnSave reads the latest.
    self._layoutDraft = freshDraft(self)

    -- ------------------------------------------------------------------
    -- Per-tab rows: mode picker + (if display) item template editor.
    -- ------------------------------------------------------------------
    self:_LayoutEditor_RenderTabs(scroll, writable)

    -- ------------------------------------------------------------------
    -- Save bar.
    -- ------------------------------------------------------------------
    local saveRow = AceGUI:Create("SimpleGroup")
    saveRow:SetFullWidth(true)
    saveRow:SetLayout("Flow")
    scroll:AddChild(saveRow)

    local spacer = AceGUI:Create("Label")
    spacer:SetWidth(20)
    saveRow:AddChild(spacer)

    local saveBtn = AceGUI:Create("Button")
    saveBtn:SetText(writable and "Save Layout" or "Save Layout (disabled)")
    saveBtn:SetWidth(200)
    saveBtn:SetDisabled(not writable)
    saveBtn:SetCallback("OnClick", function()
        local ok, err = self:SaveBankLayout(self._layoutDraft)
        if ok then
            self:Print("Layout saved (v" .. self:GetBankLayout().version .. ").")
            self:AddAuditEntry("Layout: saved by " ..
                (UnitName("player") or "?") .. " (v" .. self:GetBankLayout().version .. ")")
            self._layoutDraft = freshDraft(self)
            self:RefreshLayoutTab()
        else
            self:Print("|cffff5555Layout save failed:|r " .. tostring(err))
        end
    end)
    saveRow:AddChild(saveBtn)

    local revertBtn = AceGUI:Create("Button")
    revertBtn:SetText("Revert")
    revertBtn:SetWidth(120)
    revertBtn:SetDisabled(not writable)
    revertBtn:SetCallback("OnClick", function()
        self._layoutDraft = freshDraft(self)
        self:RefreshLayoutTab()
    end)
    saveRow:AddChild(revertBtn)

    -- ------------------------------------------------------------------
    -- Sort Access section (GM-only to edit).
    -- ------------------------------------------------------------------
    local saHeading = AceGUI:Create("Heading")
    saHeading:SetFullWidth(true)
    saHeading:SetText("Sort Access")
    scroll:AddChild(saHeading)

    self:_LayoutEditor_RenderSortAccess(scroll, isGM)
end

--- Re-render the Layout tab (called after save / revert / capture).
function GBL:RefreshLayoutTab()
    if self.activeTab ~= "layout" then return end
    if not self.tabGroup then return end
    self.tabGroup:ReleaseChildren()
    self:BuildLayoutTab(self.tabGroup)
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
    captureBtn:SetCallback("OnClick", function()
        local captured, err = self:CaptureTabLayout(tabIndex)
        if not captured then
            self:Print("|cffff5555Capture failed:|r " .. tostring(err))
            return
        end
        draft.tabs[tabIndex] = captured
        self:Print(format("Captured tab %d: %d distinct items.",
            tabIndex, (function()
                local n = 0; for _ in pairs(captured.items) do n = n + 1 end; return n
            end)()))
        self:RefreshLayoutTab()
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
            -- Append to slotOrder: fill unused slotOrder entries.
            local taken = {}
            for s, _ in pairs(tab.slotOrder) do taken[s] = true end
            local remaining = slots
            for s = 1, MAX_SLOTS do
                if remaining <= 0 then break end
                if not taken[s] then
                    tab.slotOrder[s] = id
                    remaining = remaining - 1
                end
            end
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
            row.slots = n
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
            self:RefreshLayoutTab()
        end)
        rowGroup:AddChild(removeBtn)
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

    -- Rank threshold picker
    local rankRow = AceGUI:Create("SimpleGroup")
    rankRow:SetFullWidth(true)
    rankRow:SetLayout("Flow")
    parent:AddChild(rankRow)

    local rankList = { "GM only" }
    local rankOrder = { -1 }
    for i = 0, math.max(0, numRanks - 1) do
        local rankName = GuildControlGetRankName and GuildControlGetRankName(i + 1) or ("Rank " .. i)
        rankList[#rankList + 1] = format("Rank %d and above (%s)", i, rankName)
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
