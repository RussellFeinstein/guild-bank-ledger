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
    buy     = "Interface\\BUTTONS\\UI-GroupLoot-Coin-Up",  -- coin: needs buying
    stocked = "Interface\\RAIDFRAME\\ReadyCheck-Ready",    -- check: target met or exceeded
}

local function colorToHex(c)
    return format("%02x%02x%02x",
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
end

--- Triple-encoded display for a universe row's restock status.
-- color + icon + text are three independent channels (WCAG 1.4.1: never rely
-- on color alone). Pure; depends only on the row's toBuy (0 = at or above max).
-- @param row table|nil universe row { target, stock, toBuy }
-- @return table { status, color = {r,g,b}, icon = texturePath, text }
function GBL:GetRestockStatusDisplay(row)
    local toBuy = (row and row.toBuy) or 0
    if toBuy > 0 then
        return {
            status = "buy",
            color = self:GetAccessibleColor("ALERT"),
            icon = STATUS_ICONS.buy,
            text = "Buy " .. toBuy,
        }
    end
    -- At or above the max is simply "in stock". Being over the max is not a
    -- problem, so there is no separate "over" state. Triple-encoded (check
    -- icon + DEPOSIT color + text), never color alone (WCAG 1.4.1).
    return {
        status = "instock",
        color = self:GetAccessibleColor("DEPOSIT"),
        icon = STATUS_ICONS.stocked,
        text = "In stock",
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

    -- The auction-house gate (#211): every buy control disables on it, with
    -- the reason on the banner. One read per build so the banner and the
    -- buttons cannot disagree.
    local ahOpen = self:_RestockAuctionHouseOpen()
    local AH_CLOSED_TEXT = "|cffffcc00Open the Auction House to buy.|r"
    -- The search's preconditions, in the design's order (section 4): the
    -- first that fails disables Search and is the banner text in IDLE.
    local blocker = (state == "IDLE") and self:_RestockSearchBlocker() or nil

    -- Status banner.
    local fontPath, fontSize = self:GetScaledFont()
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    status:SetFont(fontPath, fontSize, "")
    if state == "SEARCHING" then
        status:SetText("|cffffaa55Searching the Auction House...|r")
    elseif state == "CONFIRMING" then
        status:SetText("|cffffaa55Confirming purchase...|r")
    elseif state == "PRICED" then
        -- The quote (#211): the real total for the quantity, waiting for the
        -- Confirm click. Text carries the state; the colour is a second channel.
        local line = format("|cffffaa55Quoted %s for %d x %s. Confirm?|r",
            self:FormatMoney(self._restock.pendingTotal or 0),
            self._restock.pendingQty or 0, itemLabel(self._restock.pendingItemID))
        if not ahOpen then line = line .. "  " .. AH_CLOSED_TEXT end
        status:SetText(line)
    elseif state == "READY" then
        local budget = self:GetRestockBudget()
        local line = format("Search complete: %d of %d found.",
            self._restock.foundCount or 0,
            self._restock.activeItems and #self._restock.activeItems or 0)
        -- Spent is what this search spent (#60), never the wallet delta.
        local spent = self._restock.spentEstimate or 0
        if budget > 0 then
            line = line .. format("  Spent %s of %d g.", self:FormatMoney(spent), budget)
        elseif spent > 0 then
            line = line .. format("  Spent %s.", self:FormatMoney(spent))
        end
        line = line .. format("  Gold: %s.", self:FormatMoney((GetMoney and GetMoney()) or 0))
        if not ahOpen then line = line .. "  " .. AH_CLOSED_TEXT end
        status:SetText(line)
    elseif blocker then
        status:SetText("|cffffcc00" .. blocker.text .. "|r")
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
    -- a way back to IDLE; CONFIRMING and PRICED offer the purchase's own
    -- Cancel, and PRICED the Confirm the quote waits for (#211).
    local confirmIndex
    if state == "IDLE" then
        local searchBtn = AceGUI:Create("Button")
        searchBtn:SetText("Search auctions")
        searchBtn:SetWidth(140)
        searchBtn:SetDisabled(blocker ~= nil)
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
        -- One purchase per click: the start needs the click (#199).
        local left = self:_RestockBuyableCount(self._restock)
        local buyNextBtn = AceGUI:Create("Button")
        buyNextBtn:SetText(format("Buy next (%d left)", left))
        buyNextBtn:SetWidth(150)
        buyNextBtn:SetDisabled(left == 0 or not ahOpen)
        buyNextBtn:SetCallback("OnClick", function()
            self:StartRestockBuyNext()
        end)
        controls:AddChild(buyNextBtn)
        focus(buyNextBtn)

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

        -- The confirm-at-price pause (#211): on, a purchase shows its quoted
        -- total and waits for Confirm; off, it confirms on its own as before.
        local pauseCB = AceGUI:Create("CheckBox")
        pauseCB:SetLabel("Confirm at price")
        pauseCB:SetWidth(150)
        pauseCB:SetValue(self:IsRestockConfirmAtPrice())
        pauseCB:SetCallback("OnValueChanged", function(_w, _e, value)
            self:SetRestockConfirmAtPrice(value)
        end)
        controls:AddChild(pauseCB)
        focus(pauseCB)

        local doneBtn = AceGUI:Create("Button")
        doneBtn:SetText("Done")
        doneBtn:SetWidth(120)
        doneBtn:SetCallback("OnClick", function()
            self:ResetRestockSearch()
            self:RefreshRestockTab()
        end)
        controls:AddChild(doneBtn)
        focus(doneBtn)
    elseif state == "CONFIRMING" or state == "PRICED" then
        -- A purchase is in flight. Its Cancel returns to the list (#211):
        -- before the confirm is out it drops the purchase, after it the
        -- purchase is kept as in the mail. In PRICED the quote waits for
        -- Confirm, which the rebuild focuses so Enter confirms.
        if state == "PRICED" then
            local confirmBtn = AceGUI:Create("Button")
            confirmBtn:SetText("Confirm")
            confirmBtn:SetWidth(120)
            confirmBtn:SetDisabled(not ahOpen)
            confirmBtn:SetCallback("OnClick", function()
                self:ConfirmRestockPurchase()
            end)
            controls:AddChild(confirmBtn)
            focus(confirmBtn)
            confirmIndex = focusN
        end
        local cancelBtn = AceGUI:Create("Button")
        cancelBtn:SetText("Cancel")
        cancelBtn:SetWidth(120)
        cancelBtn:SetCallback("OnClick", function()
            self:CancelRestockPurchase()
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
    elseif state == "PRICED" then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText("|cffffaa55Waiting for Confirm. Cancel drops the purchase; nothing is spent until you confirm.|r")
        content:AddChild(lbl)
    elseif state == "READY" then
        self:_RestockView_RenderResults(content, focus)
    else
        self:_RestockView_RenderItems(content, focus)
    end

    -- The rebuild that enters PRICED lands focus on Confirm (#211), so Enter
    -- confirms and Escape (PR B) cancels without a Tab walk first.
    if confirmIndex then
        self.A11Y.focusIndex = confirmIndex
        self:RestoreFocus()
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

--- Activate the currently focused widget: OnClick for a button, a toggle for
-- a CheckBox (which ignores OnClick, so the confirm-at-price box would read
-- as a dead key otherwise; the same branch the Sort tab has).
-- @return boolean true if a widget was fired
function GBL:_RestockView_ActivateFocused()
    local order = self.A11Y and self.A11Y.focusOrder
    local idx = (self.A11Y and self.A11Y.focusIndex) or 0
    local widget = order and idx > 0 and order[idx]
    -- Same disabled check as the Sort tab: firing OnClick bypasses the
    -- one AceGUI's own handler does, and this tab disables Buy buttons
    -- when a budget cap is reached. The purchase path re-checks the
    -- budget itself, so this is defence in depth rather than the only
    -- gate, but a disabled button that responds to a key is still wrong.
    if widget and widget.disabled then return false end
    if widget and widget.type == "CheckBox" and widget.GetValue and widget.SetValue then
        local newValue = not widget:GetValue()
        widget:SetValue(newValue)
        if widget.Fire then widget:Fire("OnValueChanged", newValue) end
        return true
    end
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

--- Render the item list: one row per universe entry under its tab heading.
-- A row with a purchase in the mail (#209) carries the modifier and a Clear
-- button, the one interactive widget in this list, registered in reading
-- order through `focus`.
function GBL:_RestockView_RenderItems(content, focus)
    local AceGUI = LibStub("AceGUI-3.0")
    focus = focus or function() end
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
        local pending = row.pending or 0
        local mailText = ""
        if pending > 0 then
            -- What was bought and not yet seen in the bank (#209). An
            -- unconfirmed entry is a confirm whose result never arrived.
            local age = self:_RestockFormatAge(GetServerTime() - (row.pendingAt or 0))
            if row.pendingUnconfirmed then
                mailText = format(" || %d bought, result unknown (%s), check your mail", pending, age)
            else
                mailText = format(" || in the mail %d (%s)", pending, age)
            end
        end
        local rowText = format("%s%s  |cffaaaaaatarget %d || bank %d%s|r  %s",
            iconEsc, itemLabel(row.itemID), row.target or 0, row.stock or 0, mailText, statusText)

        if pending > 0 then
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
            local clearBtn = AceGUI:Create("Button")
            clearBtn:SetText("Clear")
            clearBtn:SetWidth(80)
            clearBtn:SetCallback("OnClick", function()
                self:ClearRestockPending(itemID)
                self:RefreshRestockTab()
            end)
            grp:AddChild(clearBtn)
            focus(clearBtn)
        else
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            content:AddChild(lbl)
        end
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
    -- Every Buy disables once the search's own spend has reached the budget
    -- (#60: the search's spend, never the wallet delta) or while the auction
    -- house is closed (#211).
    local buyBlocked = self:_RestockBudgetExceeded(st.spentEstimate or 0, self:GetRestockBudget())
        or not self:_RestockAuctionHouseOpen()

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
            buyBtn:SetDisabled(buyBlocked)
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
