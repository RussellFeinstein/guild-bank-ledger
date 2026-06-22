------------------------------------------------------------------------
-- GuildBankLedger — UI/RestockView.lua
-- Restock tab: render each catalog item's target / in-bank / to-buy with a
-- triple-encoded status, plus a coverage section for bank-target items not in
-- the catalog ("Add to catalog"). Render scaffold + focus-order registration.
--
-- The Auctionator search/buy flow and the Tab/arrow key capture (the visible
-- focus ring) land in later restock milestones; this file sets up the view and
-- registers the focus order they drive.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- Resolve an item name, mirroring SortView. GetCachedItemInfo async-requests
-- on a miss and returns nil until the data loads; the name fills in on the next
-- rebuild. We deliberately do NOT subscribe to GET_ITEM_INFO_RECEIVED here:
-- AceEvent is one-callback-per-(object,event), so registering it would shadow
-- ItemCache's own handler and break the cache. Auto-refresh on name-load is a
-- deferred polish item.
local function itemLabel(itemID)
    local name = nil
    if GBL.GetCachedItemInfo then
        name = GBL:GetCachedItemInfo(itemID)
    end
    return name or ("item " .. itemID)
end

-- Triple-encoding status icons (the shape channel; color + text are the other
-- two). Texture paths, defined locally so Accessibility.lua stays untouched.
local STATUS_ICONS = {
    buy     = "Interface\\BUTTONS\\UI-GroupLoot-Coin-Up",    -- coin: needs buying
    stocked = "Interface\\RAIDFRAME\\ReadyCheck-Ready",       -- check: target met
    over    = "Interface\\BUTTONS\\UI-GroupLoot-Pass-Up",     -- down arrow: surplus
}

local function colorToHex(c)
    return format("%02x%02x%02x",
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
end

-- Headings for the non-catalog universe sections.
local SOURCE_HEADINGS = {
    added  = "Your added items",
    target = "Bank targets (not in catalog)",
}

--- Triple-encoded display for a universe row's restock status.
-- color + icon + text are three independent channels (WCAG 1.4.1: never rely
-- on color alone). Pure; depends only on the row's target/stock/toBuy.
-- @param row table|nil universe row { target, stock, toBuy }
-- @return table { status, color = {r,g,b}, icon = texturePath, text }
function GBL:GetRestockStatusDisplay(row)
    local target = (row and row.target) or 0
    local stock = (row and row.stock) or 0
    local toBuy = (row and row.toBuy) or 0
    if toBuy > 0 then
        return {
            status = "buy",
            color = self:GetAccessibleColor("ALERT"),
            icon = STATUS_ICONS.buy,
            text = "Buy " .. toBuy,
        }
    elseif stock > target then
        return {
            status = "over",
            color = self:GetAccessibleColor("NEUTRAL"),
            icon = STATUS_ICONS.over,
            text = "Over " .. (stock - target),
        }
    end
    return {
        status = "stocked",
        color = self:GetAccessibleColor("DEPOSIT"),
        icon = STATUS_ICONS.stocked,
        text = "Stocked",
    }
end

-- Auctionator is an OptionalDep; the search/buy controls (M4) need it, but the
-- catalog still renders read-only without it.
local function auctionatorAvailable()
    return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

function GBL:BuildRestockTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Session render state. The search flow (M4) drives the non-IDLE states;
    -- initialize the stub here so any state branch has a value to read.
    self._restock = self._restock or { state = "IDLE" }

    -- Focus order is rebuilt every build. M3a registers the interactive widgets
    -- in reading order; the key capture that walks this order is wired later.
    -- Only interactive widgets are registered: the catalog is read-only and a
    -- 123-row tab stop list would make keyboard navigation unusable.
    self:ClearFocusOrder()
    local focusN = 0
    local function focus(widget)
        focusN = focusN + 1
        self:RegisterFocusable(widget, focusN)
    end

    -- Status banner.
    local fontPath, fontSize = self:GetScaledFont()
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    status:SetFont(fontPath, fontSize, "")
    if not auctionatorAvailable() then
        status:SetText("|cffffcc00Restock needs the Auctionator addon to search and buy. "
            .. "Targets still display below.|r")
    elseif not self:GetLastScanResults() then
        status:SetText("|cffffcc00Open the guild bank (or click Scan bank) so in-bank counts "
            .. "are accurate.|r")
    else
        status:SetText("Each item shows its target, the amount in the bank, and how many to buy.")
    end
    container:AddChild(status)

    -- Controls row.
    local controls = AceGUI:Create("SimpleGroup")
    controls:SetFullWidth(true)
    controls:SetLayout("Flow")
    container:AddChild(controls)

    local scanBtn = AceGUI:Create("Button")
    scanBtn:SetText("Scan bank")
    scanBtn:SetWidth(120)
    scanBtn:SetDisabled(not self:IsBankOpen() or self.scanInProgress)
    scanBtn:SetCallback("OnClick", function()
        self:ManualScan()
    end)
    controls:AddChild(scanBtn)
    focus(scanBtn)

    -- Scrollable content.
    local content = AceGUI:Create("ScrollFrame")
    content:SetFullWidth(true)
    content:SetFullHeight(true)
    content:SetLayout("List")
    self:AddFillChild(container, content)

    self:_RestockView_RenderCatalog(content, focus)

    -- Keyboard navigation capture (in-game only; the mock frame has no
    -- EnableKeyboard, so this branch is skipped under busted). Tab/arrows cycle
    -- the registered focusables; Enter/Space activates the focused button. The
    -- visible focus ring is a deferred accessibility-branch change, so until it
    -- lands focus moves without a drawn border.
    local capture = content.frame
    if capture and capture.EnableKeyboard then
        capture:EnableKeyboard(true)
        capture:SetScript("OnKeyDown", function(frame, key)
            if self.activeTab ~= "restock" then
                if frame.SetPropagateKeyboardInput then
                    frame:SetPropagateKeyboardInput(true)
                end
                return
            end
            local handled = self:_RestockView_NavKey(key, IsShiftKeyDown and IsShiftKeyDown())
            if frame.SetPropagateKeyboardInput then
                frame:SetPropagateKeyboardInput(not handled)
            end
        end)
    end
end

--- Refresh the Restock tab — called after Add-to-catalog and (M4) state changes.
function GBL:RefreshRestockTab()
    if self.activeTab ~= "restock" then return end
    if not self.tabGroup then return end
    self.tabGroup:ReleaseChildren()
    self:BuildRestockTab(self.tabGroup)
end

--- Open the main window and switch to the Restock tab (the /gbl restock entry).
-- Gated on sort access; the tab only exists in the bar for those users.
function GBL:OpenRestockTab()
    if not (self.HasSortAccess and self:HasSortAccess()) then
        self:Print("Restock requires sort access for this guild.")
        return
    end
    self:CreateMainFrame()
    self.mainFrame:Show()
    if self.tabGroup then
        self.tabGroup:SelectTab("restock")
    end
end

------------------------------------------------------------------------
-- Keyboard navigation (Option C: focus moves now; the visible focus ring is a
-- deferred accessibility-branch change to SetFocusIndicator).
------------------------------------------------------------------------

--- Activate the currently focused widget by firing its OnClick callback.
-- @return boolean true if a widget was fired
function GBL:_RestockView_ActivateFocused()
    local order = self.A11Y and self.A11Y.focusOrder
    local idx = (self.A11Y and self.A11Y.focusIndex) or 0
    local widget = order and idx > 0 and order[idx]
    if widget and widget.Fire then
        widget:Fire("OnClick")
        return true
    end
    return false
end

--- Map a key press to a focus action. Returns true if handled (the caller then
-- consumes the key). The frame handler passes the live Shift state.
-- @param key string OnKeyDown key name
-- @param shiftDown boolean whether Shift is held (Tab direction)
-- @return boolean handled
function GBL:_RestockView_NavKey(key, shiftDown)
    if key == "TAB" then
        self:AdvanceFocus(shiftDown and -1 or 1)
        return true
    elseif key == "DOWN" then
        self:AdvanceFocus(1)
        return true
    elseif key == "UP" then
        self:AdvanceFocus(-1)
        return true
    elseif key == "ENTER" or key == "NUMPADENTER" or key == "SPACE" then
        return self:_RestockView_ActivateFocused()
    end
    return false
end

------------------------------------------------------------------------
-- Catalog rendering
------------------------------------------------------------------------

function GBL:_RestockView_RenderCatalog(content, focus)
    local AceGUI = LibStub("AceGUI-3.0")
    focus = focus or function() end
    local fontPath, fontSize = self:GetScaledFont()

    local universe = self:_RestockBuildItemUniverse()
    if #universe == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("|cffffcc00No catalog items to show.|r")
        content:AddChild(lbl)
        return
    end

    local lastHeading = nil
    for _, row in ipairs(universe) do
        local heading
        if row.source == "catalog" then
            heading = row.group or "Catalog"
        else
            heading = SOURCE_HEADINGS[row.source] or "Other"
        end
        if heading ~= lastHeading then
            local h = AceGUI:Create("Heading")
            h:SetFullWidth(true)
            h:SetText(heading)
            content:AddChild(h)
            lastHeading = heading
        end

        local disp = self:GetRestockStatusDisplay(row)
        local iconEsc = disp.icon and ("|T" .. disp.icon .. ":14|t ") or ""
        local statusText = format("|cff%s%s|r", colorToHex(disp.color), disp.text)
        local rowText = format("%s%s  |cffaaaaaa(target %d, bank %d)|r  %s",
            iconEsc, itemLabel(row.itemID), row.target or 0, row.stock or 0, statusText)

        if row.source == "target" then
            -- Coverage row: label + an Add-to-catalog button, side by side.
            local grp = AceGUI:Create("SimpleGroup")
            grp:SetFullWidth(true)
            grp:SetLayout("Flow")
            content:AddChild(grp)

            local lbl = AceGUI:Create("Label")
            lbl:SetRelativeWidth(0.7)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            grp:AddChild(lbl)

            local itemID = row.itemID
            local addBtn = AceGUI:Create("Button")
            addBtn:SetText("Add to catalog")
            addBtn:SetWidth(140)
            addBtn:SetCallback("OnClick", function()
                self:AddRestockCatalogItem(itemID)
                self:RefreshRestockTab()
            end)
            grp:AddChild(addBtn)
            focus(addBtn)
        else
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            content:AddChild(lbl)
        end
    end
end
