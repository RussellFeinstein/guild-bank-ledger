------------------------------------------------------------------------
-- GuildBankLedger — UI/RestockView.lua
-- Restock tab: render each bank-layout item's target / in-bank / to-buy with a
-- triple-encoded status, grouped by bank tab. Render scaffold + focus-order
-- registration.
--
-- The Auctionator search and buy flow lives here; the visible focus ring is a
-- deferred accessibility-branch change.
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
    -- Only interactive widgets are registered: the item list is read-only, so a
    -- per-row tab stop would make keyboard navigation unusable.
    self:ClearFocusOrder()
    local focusN = 0
    local function focus(widget)
        focusN = focusN + 1
        self:RegisterFocusable(widget, focusN)
    end

    local state = self._restock.state or "IDLE"

    -- Status banner.
    local fontPath, fontSize = self:GetScaledFont()
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    status:SetFont(fontPath, fontSize, "")
    if state == "SEARCHING" then
        status:SetText("|cffffaa55Searching the Auction House...|r")
    elseif state == "CONFIRMING" then
        status:SetText("|cffffaa55Confirming purchase...|r")
    elseif state == "READY" then
        local budget = self:GetRestockBudget()
        local line = format("Search complete: %d of %d found.",
            self._restock.foundCount or 0,
            self._restock.activeItems and #self._restock.activeItems or 0)
        if budget > 0 then
            local spent = self:_RestockSpent(self._restock.runStartMoney,
                (GetMoney and GetMoney()) or 0)
            line = line .. format("  Spent %s of %d g.", self:FormatMoney(spent), budget)
        end
        line = line .. format("  Gold: %s.", self:FormatMoney((GetMoney and GetMoney()) or 0))
        status:SetText(line)
    elseif not self:IsAuctionatorReady() then
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

    -- State-specific action button. IDLE offers a search; SEARCHING/READY offer
    -- a way back to IDLE.
    if state == "IDLE" then
        local searchBtn = AceGUI:Create("Button")
        searchBtn:SetText("Search auctions")
        searchBtn:SetWidth(140)
        searchBtn:SetDisabled(not self:IsAuctionatorReady())
        searchBtn:SetCallback("OnClick", function()
            self:StartRestockSearch()
        end)
        controls:AddChild(searchBtn)
        focus(searchBtn)
    elseif state == "SEARCHING" then
        local cancelBtn = AceGUI:Create("Button")
        cancelBtn:SetText("Cancel")
        cancelBtn:SetWidth(120)
        cancelBtn:SetCallback("OnClick", function()
            self:ResetRestockSearch()
            self:RefreshRestockTab()
        end)
        controls:AddChild(cancelBtn)
        focus(cancelBtn)
    elseif state == "READY" then
        local budget = self:GetRestockBudget()
        local buyAllBtn = AceGUI:Create("Button")
        buyAllBtn:SetText("Buy all")
        buyAllBtn:SetWidth(110)
        buyAllBtn:SetDisabled(self:_RestockNextBuyable(self._restock) == nil)
        buyAllBtn:SetCallback("OnClick", function()
            self:StartRestockBuyAll()
        end)
        controls:AddChild(buyAllBtn)
        focus(buyAllBtn)

        local budgetBox = AceGUI:Create("EditBox")
        budgetBox:SetLabel("Budget (gold, 0 = none)")
        budgetBox:SetWidth(160)
        budgetBox:SetText(tostring(budget))
        budgetBox:SetCallback("OnEnterPressed", function(_w, _e, value)
            self:SetRestockBudget(tonumber(value) or 0)
            self:RefreshRestockTab()
        end)
        controls:AddChild(budgetBox)
        focus(budgetBox)

        local doneBtn = AceGUI:Create("Button")
        doneBtn:SetText("Done")
        doneBtn:SetWidth(120)
        doneBtn:SetCallback("OnClick", function()
            self:ResetRestockSearch()
            self:RefreshRestockTab()
        end)
        controls:AddChild(doneBtn)
        focus(doneBtn)
    elseif state == "CONFIRMING" then
        -- A purchase is in flight. Offer an escape so a stuck confirm (AH closed,
        -- item no longer a commodity) cannot wedge the tab until /reload.
        local cancelBtn = AceGUI:Create("Button")
        cancelBtn:SetText("Cancel")
        cancelBtn:SetWidth(120)
        cancelBtn:SetCallback("OnClick", function()
            self:ResetRestockSearch()
            self:RefreshRestockTab()
        end)
        controls:AddChild(cancelBtn)
        focus(cancelBtn)
    end

    -- Scrollable content.
    local content = AceGUI:Create("ScrollFrame")
    content:SetFullWidth(true)
    content:SetFullHeight(true)
    content:SetLayout("List")
    self:AddFillChild(container, content)

    if state == "SEARCHING" then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        local n = self._restock.activeItems and #self._restock.activeItems or 0
        lbl:SetText(format("Searching the Auction House for %d item(s)...", n))
        content:AddChild(lbl)
    elseif state == "CONFIRMING" then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText("|cffffaa55Confirming purchase...|r")
        content:AddChild(lbl)
    elseif state == "READY" then
        self:_RestockView_RenderResults(content, focus)
    else
        self:_RestockView_RenderItems(content)
    end

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

--- Refresh the Restock tab. Called from OnBankLayoutChanged and (M4) state changes.
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
-- Item list rendering
------------------------------------------------------------------------

function GBL:_RestockView_RenderItems(content)
    local AceGUI = LibStub("AceGUI-3.0")
    local fontPath, fontSize = self:GetScaledFont()

    local universe = self:_RestockBuildItemUniverse()
    if #universe == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText("|cffffcc00No items in your bank layout yet. Set up display tabs in the "
            .. "Layout tab to choose what the guild stocks.|r")
        content:AddChild(lbl)
        return
    end

    -- The universe is emitted tab-by-tab (then reserves), so each group is a
    -- contiguous run. Break on (tabIndex, name) so two display tabs that happen
    -- to share a name still get their own heading.
    local lastKey = nil
    for _, row in ipairs(universe) do
        local heading = row.group or "Items"
        local key = tostring(row.tabIndex) .. "|" .. heading
        if key ~= lastKey then
            local h = AceGUI:Create("Heading")
            h:SetFullWidth(true)
            h:SetText(heading)
            content:AddChild(h)
            lastKey = key
        end

        local disp = self:GetRestockStatusDisplay(row)
        local iconEsc = disp.icon and ("|T" .. disp.icon .. ":14|t ") or ""
        local statusText = format("|cff%s%s|r", colorToHex(disp.color), disp.text)
        local rowText = format("%s%s  |cffaaaaaa(target %d, bank %d)|r  %s",
            iconEsc, itemLabel(row.itemID), row.target or 0, row.stock or 0, statusText)

        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText(rowText)
        content:AddChild(lbl)
    end
end

--- Render the READY-state results: one row per searched item with its lowest
-- price (or "not found"), a "Bought"/"over max price" marker, and a per-item Buy
-- button for found items. Buy buttons are disabled once the budget is reached.
function GBL:_RestockView_RenderResults(content, focus)
    local AceGUI = LibStub("AceGUI-3.0")
    focus = focus or function() end
    local fontPath, fontSize = self:GetScaledFont()
    local st = self._restock or {}
    local activeItems = st.activeItems or {}
    local resultRows = st.resultRows or {}
    local bought = st.bought or {}
    local skipped = st.skipped or {}
    local budgetBlocked = self:_RestockBudgetExceeded(
        self:_RestockSpent(st.runStartMoney, (GetMoney and GetMoney()) or 0),
        self:GetRestockBudget())

    if #activeItems == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText("No items were searched.")
        content:AddChild(lbl)
        return
    end

    for i, ref in ipairs(activeItems) do
        local row = resultRows[i]
        local detail
        local buyable = false
        if bought[i] then
            detail = "|cff88ff88Bought|r"
        elseif skipped[i] then
            detail = "|cffffcc00skipped|r"
        elseif row and row.minPrice then
            detail = format("|cffaaaaaalowest %s|r", self:FormatMoney(row.minPrice))
            buyable = (ref.needed or 0) > 0
        elseif row then
            detail = "|cff88ff88found|r"
            buyable = (ref.needed or 0) > 0
        else
            detail = "|cffff8888not found|r"
        end

        local rowText = format("%s  |cffaaaaaa(need %d)|r  %s",
            itemLabel(ref.itemID), ref.needed or 0, detail)

        if buyable then
            local grp = AceGUI:Create("SimpleGroup")
            grp:SetFullWidth(true)
            grp:SetLayout("Flow")
            content:AddChild(grp)

            local lbl = AceGUI:Create("Label")
            lbl:SetRelativeWidth(0.7)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            grp:AddChild(lbl)

            local idx = i
            local buyBtn = AceGUI:Create("Button")
            buyBtn:SetText(format("Buy %d", ref.needed or 0))
            buyBtn:SetWidth(110)
            buyBtn:SetDisabled(budgetBlocked)
            buyBtn:SetCallback("OnClick", function()
                self:StartRestockBuy(idx)
            end)
            grp:AddChild(buyBtn)
            focus(buyBtn)
        else
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            content:AddChild(lbl)
        end
    end
end
