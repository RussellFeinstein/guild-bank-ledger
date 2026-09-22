------------------------------------------------------------------------
-- GuildBankLedger — UI/RestockView.lua
-- Restock tab: the bank layout's item list, grouped by bank tab, in every
-- state of the search and buy flow (#214). Each row carries its target,
-- what the bank holds, what is in the mail, the shortfall and a
-- triple-encoded status; a searched row adds its price and a Buy button.
-- The banner says what the flow is doing, a second line carries the spend
-- and the gold, and the budget row sits above the list in every state.
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

local function colorToHex(c)
    return format("%02x%02x%02x",
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
end

------------------------------------------------------------------------
-- Row vocabulary (#214, section 5 of docs/PLAN-restock-ux.md)
--
-- One table of statuses, each triple-encoded: an icon (the shape channel),
-- a palette role read through GetAccessibleColor (the colour channel) and
-- text, so no state rides on colour alone (WCAG 1.4.1). Three texts take a
-- figure. The skip reasons render through GBL:RestockSkipText, beside the
-- codes in src/Restock.lua; the log keeps the code and the chat lines keep
-- their own wording. Exported for the spec, which walks the table.
------------------------------------------------------------------------

local ICON = {
    waiting  = "Interface\\RAIDFRAME\\ReadyCheck-Waiting",
    ready    = "Interface\\RAIDFRAME\\ReadyCheck-Ready",
    notready = "Interface\\RAIDFRAME\\ReadyCheck-NotReady",
    mailbox  = "Interface\\MINIMAP\\TRACKING\\Mailbox",
    coin     = "Interface\\BUTTONS\\UI-GroupLoot-Coin-Up",
    gold     = "Interface\\MONEYFRAME\\UI-GoldIcon",
    refresh  = "Interface\\BUTTONS\\UI-RefreshButton",
}

local RESTOCK_STATUS_TEXT = {
    unknown      = { text = "bank unknown", icon = ICON.waiting, color = "NEUTRAL" },
    instock      = { text = "in stock", icon = ICON.ready, color = "DEPOSIT" },
    inmail       = { text = "in the mail", icon = ICON.mailbox, color = "MOVE" },
    short        = { text = "short", icon = ICON.coin, color = "ALERT" },
    priced       = { text = "priced", icon = ICON.gold, color = "ALERT" },
    notcommodity = { text = "not a commodity, buy it by hand", icon = ICON.notready, color = "ALERT" },
    notfound     = { text = "not found", icon = ICON.notready, color = "WITHDRAW" },
    buying       = { text = "buying", icon = ICON.refresh, color = "MOVE" },
    quoted       = { text = "quoted %s, confirm?", icon = ICON.gold, color = "ALERT" },
    bought       = { text = "bought %d for %s", icon = ICON.ready, color = "DEPOSIT" },
    skipped      = { text = "skipped: %s", icon = ICON.notready, color = "ALERT" },
    awaiting     = { text = "awaiting result", icon = ICON.waiting, color = "ALERT" },
}
GBL._restockStatusText = RESTOCK_STATUS_TEXT

--- Classify a universe row against the session. Pure. The precedence: the
-- session first (the row in flight, then the confirm still awaiting its
-- result, then bought, then skipped), then the search (not a commodity,
-- priced, not found), then the universe (bank unknown, in the mail, in
-- stock, short). A search implies a scan, so the search readings sit ahead
-- of the unscanned one. During SEARCHING the results are not in, so the
-- search readings are skipped rather than every searched row reading "not
-- found". Priced needs a usable price: Auctionator's placeholder for a miss
-- carries minPrice 0, which Lua reads as true.
-- @param row table|nil universe row { itemID, target, stock, toBuy, pending, scanned }
-- @param st table|nil the session state (self._restock)
-- @return table { status, index?, needed?, minPrice?, total?, reason? }
function GBL:_RestockRowStatus(row, st)
    local out = { status = "instock" }
    if not row then return out end
    local index
    if st and st.state ~= "SEARCHING" and type(st.activeItems) == "table" then
        for i, ref in ipairs(st.activeItems) do
            if ref.itemID == row.itemID then
                index = i
                break
            end
        end
    end
    if index then
        local ref = st.activeItems[index]
        local result = st.resultRows and st.resultRows[index]
        out.index = index
        out.needed = ref.needed or 0
        out.minPrice = result and result.minPrice or nil
        if st.pendingIndex == index and (st.state == "CONFIRMING" or st.state == "PRICED") then
            out.status = (st.state == "PRICED") and "quoted" or "buying"
            out.total = st.pendingTotal
        elseif st.unanswered and st.unanswered.itemID == row.itemID then
            out.status = "awaiting"
        elseif st.bought and st.bought[index] then
            out.status = "bought"
            out.total = st.boughtTotal and st.boughtTotal[index] or nil
        elseif st.skipped and st.skipped[index] then
            out.status = "skipped"
            out.reason = st.skipped[index]
        elseif result and result.isCommodity == false then
            out.status = "notcommodity"
        elseif result and type(result.minPrice) == "number" and result.minPrice > 0 then
            out.status = "priced"
        else
            out.status = "notfound"
        end
        return out
    end
    if row.scanned == false then
        out.status = "unknown"
    elseif (row.toBuy or 0) > 0 then
        out.status = "short"
    elseif (row.pending or 0) > 0 and (row.stock or 0) < (row.target or 0) then
        out.status = "inmail"
    end
    return out
end

--- Triple-encoded display for a universe row's restock status: the
-- classification above plus its text, icon and colour from the table.
-- @param row table|nil universe row
-- @param st table|nil the session state
-- @return table { status, text, icon = texturePath, color = {r,g,b}, index?, needed?, minPrice?, total?, reason? }
function GBL:GetRestockStatusDisplay(row, st)
    local r = self:_RestockRowStatus(row, st)
    local entry = RESTOCK_STATUS_TEXT[r.status]
    local text = entry.text
    if r.status == "quoted" then
        text = format(text, self:FormatMoney(r.total or 0))
    elseif r.status == "bought" then
        text = format(text, r.needed or 0, self:FormatMoney(r.total or 0))
    elseif r.status == "skipped" then
        text = format(text, self:RestockSkipText(r.reason))
    end
    r.text = text
    r.icon = entry.icon
    r.color = self:GetAccessibleColor(entry.color)
    return r
end

--- The estimate on a Buy button: whole gold above one gold (the quote
-- carries the exact total, and a full gold/silver/copper string overran the
-- button), the exact figure below it.
-- @param copper number
-- @return string
function GBL:_RestockEstimateText(copper)
    copper = copper or 0
    if copper >= 10000 then
        return format("%dg", math.floor(copper / 10000))
    end
    return self:FormatMoney(copper)
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

-- The gold line (#214, section 7): what this search spent, against the
-- budget when one is set, and the wallet. One string, so the PLAYER_MONEY
-- handler rewrites the same label the build made.
local function goldText(self)
    local st = self._restock or {}
    local budget = self:GetRestockBudget()
    local spent = st.spentEstimate or 0
    local parts = {}
    if budget > 0 then
        parts[#parts + 1] = format("Spent %s of %d g.", self:FormatMoney(spent), budget)
    elseif spent > 0 then
        parts[#parts + 1] = format("Spent %s.", self:FormatMoney(spent))
    end
    parts[#parts + 1] = format("Gold: %s.", self:FormatMoney((GetMoney and GetMoney()) or 0))
    return table.concat(parts, "  ")
end

--- The wallet changed (Core's OnPlayerMoney): rewrite the gold line in
-- place while this tab is the active one. Never a rebuild, which would take
-- the focus from under the player mid-purchase. A hidden window keeps its
-- label (it reads fresh when the window reopens); a released one drops the
-- reference through its own OnRelease below, since AceGUI pools frames.
function GBL:_RestockOnMoneyChanged()
    local label = self._restockGoldLabel
    if not label or self.activeTab ~= "restock" then return end
    label:SetText(goldText(self))
end

function GBL:BuildRestockTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Session render state. The search flow drives the non-IDLE states;
    -- initialize the stub here so any state branch has a value to read.
    self._restock = self._restock or { state = "IDLE" }
    local st = self._restock
    local state = st.state or "IDLE"

    -- The Shopping-tab precondition watches its frame (#217); installed
    -- from here because the frame does not exist until the Auction House
    -- window has shown once this session.
    if self._RestockWatchShoppingTab then self:_RestockWatchShoppingTab() end

    -- Focus order is rebuilt every build, in reading order: the controls,
    -- the budget row, then the list's own buttons. Only interactive widgets
    -- are registered (a per-row tab stop over read-only rows would make
    -- keyboard navigation unusable), and only enabled ones: a stop the
    -- activator would refuse is a dead press, and thirty greyed Buys inside
    -- the pause put Confirm thirty presses away (the review of PR B). Every
    -- caller sets the widget's disabled state before registering it.
    self:ClearFocusOrder()
    local focusN = 0
    local function focus(widget)
        if widget.disabled then return end
        focusN = focusN + 1
        self:RegisterFocusable(widget, focusN)
    end

    -- The auction-house gate (#211): every buy control disables on it, with
    -- the reason on the banner. One read per build so the banner and the
    -- buttons cannot disagree.
    local ahOpen = self:_RestockAuctionHouseOpen()
    local AH_CLOSED_TEXT = "|cffffcc00Open the Auction House to buy.|r"
    -- The search's preconditions, in the design's order (section 4): the
    -- first that fails disables Search and is the reason on the banner, in
    -- IDLE and in READY, where Search is offered again (#214).
    local blocker = (state == "IDLE" or state == "READY") and self:_RestockSearchBlocker() or nil

    -- Status banner: the state line.
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
        local line = format("|cffffaa55Quoted %s for %d x %s. Confirm? Nothing is spent until you do.|r",
            self:FormatMoney(st.pendingTotal or 0), st.pendingQty or 0, itemLabel(st.pendingItemID))
        if not ahOpen then line = line .. "  " .. AH_CLOSED_TEXT end
        status:SetText(line)
    elseif state == "READY" then
        local line = format("Search complete: %d of %d found.",
            st.foundCount or 0, st.activeItems and #st.activeItems or 0)
        if st.unanswered then
            -- Nothing starts until that result lands (or a new search parks
            -- it), and every Buy below is greyed for it: say so here.
            line = line .. format("  |cffffcc00Waiting on the result of %s; check your mail, then search again.|r",
                itemLabel(st.unanswered.itemID))
        end
        if blocker and blocker.key == "ah-closed" then
            -- Search and every Buy are shut for the same reason: one sentence.
            line = line .. "  |cffffcc00Open the Auction House to search or buy.|r"
        else
            if blocker then line = line .. "  |cffffcc00" .. blocker.text .. "|r" end
            if not ahOpen then line = line .. "  " .. AH_CLOSED_TEXT end
        end
        status:SetText(line)
    elseif blocker then
        status:SetText("|cffffcc00" .. blocker.text .. "|r")
    else
        status:SetText("Each item shows its target, the amount in the bank, and how many to buy.")
    end
    container:AddChild(status)

    -- The gold line (#214): every state, rewritten in place on PLAYER_MONEY.
    local gold = AceGUI:Create("Label")
    gold:SetFullWidth(true)
    gold:SetFont(fontPath, fontSize, "")
    gold:SetText(goldText(self))
    gold:SetCallback("OnRelease", function()
        if self._restockGoldLabel == gold then self._restockGoldLabel = nil end
    end)
    container:AddChild(gold)
    self._restockGoldLabel = gold

    -- Controls row: Scan bank; Search in IDLE and READY; Buy next in READY;
    -- Confirm in PRICED; Cancel in SEARCHING, CONFIRMING and PRICED. Done
    -- went with #214: the list stays through a search, and a new Search
    -- from READY starts over.
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

    local confirmIndex
    if state == "IDLE" or state == "READY" then
        local searchBtn = AceGUI:Create("Button")
        searchBtn:SetText("Search auctions")
        searchBtn:SetWidth(140)
        searchBtn:SetDisabled(blocker ~= nil)
        searchBtn:SetCallback("OnClick", function()
            self:StartRestockSearch()
        end)
        controls:AddChild(searchBtn)
        focus(searchBtn)
    end
    if state == "READY" then
        -- One purchase per click: the start needs the click (#199).
        local left = self:_RestockBuyableCount(st)
        local buyNextBtn = AceGUI:Create("Button")
        buyNextBtn:SetText(format("Buy next (%d left)", left))
        buyNextBtn:SetWidth(150)
        buyNextBtn:SetDisabled(left == 0 or not ahOpen)
        buyNextBtn:SetCallback("OnClick", function()
            self:StartRestockBuyNext()
        end)
        controls:AddChild(buyNextBtn)
        focus(buyNextBtn)
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
    elseif state == "CONFIRMING" or state == "PRICED" then
        -- A purchase is in flight. Its Cancel returns to the list (#211):
        -- before the confirm is out it drops the purchase, after it the
        -- purchase is kept as unanswered. In PRICED the quote waits for
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

    -- Budget row (#214, section 7): above the list in every state, so the
    -- cap and the pause can be set before the first search. The committed
    -- value sits beside the box, so a typed value nobody pressed Enter on
    -- reads as such.
    local budgetRow = AceGUI:Create("SimpleGroup")
    budgetRow:SetFullWidth(true)
    budgetRow:SetLayout("Flow")
    container:AddChild(budgetRow)

    -- Both hold while a purchase is in flight: the flow read them at the
    -- price, and a budget lowered or the pause switched off under a waiting
    -- quote would spend past the one or confirm without the click.
    local inFlight = (state == "CONFIRMING" or state == "PRICED")
    local budget = self:GetRestockBudget()
    local budgetBox = AceGUI:Create("EditBox")
    budgetBox:SetLabel("Budget (gold, 0 = none)")
    budgetBox:SetWidth(160)
    budgetBox:SetText(tostring(budget))
    budgetBox:SetDisabled(inFlight)
    budgetBox:SetCallback("OnEnterPressed", function(_w, _e, value)
        self:SetRestockBudget(tonumber(value) or 0)
        self:RefreshRestockTab()
    end)
    budgetRow:AddChild(budgetBox)
    focus(budgetBox)

    local budgetLabel = AceGUI:Create("Label")
    budgetLabel:SetWidth(140)
    budgetLabel:SetFont(fontPath, fontSize, "")
    budgetLabel:SetText(budget > 0 and format("Budget: %d g", budget) or "Budget: none")
    budgetRow:AddChild(budgetLabel)

    -- The confirm-at-price pause (#211): on, a purchase shows its quoted
    -- total and waits for Confirm; off, it confirms on its own.
    local pauseCB = AceGUI:Create("CheckBox")
    pauseCB:SetLabel("Confirm at price")
    pauseCB:SetWidth(150)
    pauseCB:SetValue(self:IsRestockConfirmAtPrice())
    pauseCB:SetDisabled(inFlight)
    pauseCB:SetCallback("OnValueChanged", function(_w, _e, value)
        self:SetRestockConfirmAtPrice(value)
    end)
    budgetRow:AddChild(pauseCB)
    focus(pauseCB)

    -- Scrollable content: the list, in every state (#214, section 3).
    local content = AceGUI:Create("ScrollFrame")
    content:SetFullWidth(true)
    content:SetFullHeight(true)
    content:SetLayout("List")
    self:AddFillChild(container, content)
    self:_RestockView_RenderItems(content, focus)

    -- The rebuild that enters PRICED lands focus on Confirm (#211), so Enter
    -- confirms without a Tab walk first. Only that one: the price handler
    -- sets focusConfirm and this build consumes it, so a rebuild from a sync
    -- or a scan while the player has Tabbed onto Cancel cannot snap focus
    -- back onto Confirm under their Enter.
    if confirmIndex and st.focusConfirm then
        st.focusConfirm = nil
        self.A11Y.focusIndex = confirmIndex
        self:RestoreFocus()
    end

    -- Keyboard navigation capture (in-game only; the mock frame has no
    -- EnableKeyboard, so this branch is skipped under busted, and the rule
    -- in _RestockView_NavKey is what the suite pins). Tab enters the walk;
    -- arrows and Tab move; Enter and Space activate; Escape clears focus.
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

--- Refresh the Restock tab. Called from OnBankLayoutChanged and the flow's state changes.
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
-- Keyboard navigation
------------------------------------------------------------------------

--- Activate the currently focused widget: the shared walk activator in
-- UI/Accessibility.lua (OnClick for a button, a toggle for a CheckBox, a
-- disabled widget refused), kept under this tab's name for its key handler.
-- @return boolean true if a widget was fired
function GBL:_RestockView_ActivateFocused()
    return self:ActivateFocused()
end

--- Map a key press to a focus action: the shared rule in
-- UI/Accessibility.lua (GBL:FocusNavKey, #214 section 12), kept under this
-- tab's name for its key handler. Returns true if handled (the caller then
-- consumes the key).
-- @param key string OnKeyDown key name
-- @param shiftDown boolean whether Shift is held (Tab direction)
-- @return boolean handled
function GBL:_RestockView_NavKey(key, shiftDown)
    return self:FocusNavKey(key, shiftDown)
end

------------------------------------------------------------------------
-- Item list rendering
------------------------------------------------------------------------

--- Render the list: one row per universe entry under its tab heading, in
-- every state, decorated from the session (#214). A searched row that has
-- since left the layout is kept under its own heading rather than dropped:
-- Buy next still walks the search's snapshot, and a list that hid the row
-- would lie about what the next click buys. A row with a purchase in the
-- mail (#209) carries the modifier and a Clear button. Buttons register in
-- reading order through `focus`.
function GBL:_RestockView_RenderItems(content, focus)
    local AceGUI = LibStub("AceGUI-3.0")
    focus = focus or function() end
    local fontPath, fontSize = self:GetScaledFont()
    local st = self._restock or {}
    local state = st.state or "IDLE"
    local universe = self:_RestockBuildItemUniverse()
    -- Every Buy disables outside READY, once the search's own spend has
    -- reached the budget (#60: the search's spend, never the wallet delta),
    -- or while the auction house is closed (#211).
    local buyBlocked = state ~= "READY"
        or self:_RestockBudgetExceeded(st.spentEstimate or 0, self:GetRestockBudget())
        or not self:_RestockAuctionHouseOpen()
        or st.unanswered ~= nil
    -- The annotations read the palette (#44), not a grey literal.
    local neutral = colorToHex(self:GetAccessibleColor("NEUTRAL"))

    local seen = {}
    for _, row in ipairs(universe) do seen[row.itemID] = true end
    local orphans = {}
    if state ~= "IDLE" and state ~= "SEARCHING" and type(st.activeItems) == "table" then
        for _, ref in ipairs(st.activeItems) do
            if not seen[ref.itemID] then
                orphans[#orphans + 1] = {
                    itemID = ref.itemID, group = "Searched, no longer in the layout",
                    target = 0, stock = 0, toBuy = 0, pending = 0, scanned = true, orphan = true,
                }
            end
        end
    end

    if #universe == 0 and #orphans == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText("|cffffcc00No items in your bank layout yet. Set up display tabs in the "
            .. "Layout tab to choose what the guild stocks.|r")
        content:AddChild(lbl)
        return
    end

    local function renderRow(row)
        local disp = self:GetRestockStatusDisplay(row, st)
        local iconEsc = disp.icon and ("|T" .. disp.icon .. ":14|t ") or ""
        local statusText = format("|cff%s%s|r", colorToHex(disp.color), disp.text)
        local pending = row.pending or 0
        local figures
        if row.orphan then
            figures = "not in the layout"
        else
            figures = format("target %d || bank %s", row.target or 0,
                row.scanned == false and "?" or tostring(row.stock or 0))
            if pending > 0 then
                -- What was bought and not yet seen in the bank (#209). An
                -- unconfirmed entry is a confirm whose result never arrived.
                local age = self:_RestockFormatAge(GetServerTime() - (row.pendingAt or 0))
                if row.pendingUnconfirmed then
                    figures = figures .. format(" || %d bought, result unknown (%s), check your mail", pending, age)
                else
                    figures = figures .. format(" || in the mail %d (%s)", pending, age)
                end
            end
            if row.scanned ~= false then
                figures = figures .. format(" || short %d", row.toBuy or 0)
            end
        end
        if disp.minPrice then
            figures = figures .. format(" || lowest %s", self:FormatMoney(disp.minPrice))
        end
        local rowText = format("%s%s  |cff%s%s|r  %s",
            iconEsc, itemLabel(row.itemID), neutral, figures, statusText)

        -- A priced row carries a Buy; whether it can be pressed is the
        -- flow's own predicate (the one Buy next reads), plus the state and
        -- the gate. A button that cannot be pressed stays out of the walk.
        local buyable = disp.status == "priced"
        local buyDisabled = buyBlocked or not self:_RestockRowBuyable(st, disp.index)
        if not buyable and pending == 0 then
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFont(fontPath, fontSize, "")
            lbl:SetText(rowText)
            content:AddChild(lbl)
            return
        end

        local grp = AceGUI:Create("SimpleGroup")
        grp:SetFullWidth(true)
        grp:SetLayout("Flow")
        content:AddChild(grp)

        local lbl = AceGUI:Create("Label")
        lbl:SetRelativeWidth(0.7)
        lbl:SetFont(fontPath, fontSize, "")
        lbl:SetText(rowText)
        grp:AddChild(lbl)

        if buyable then
            local idx = disp.index
            local buyBtn = AceGUI:Create("Button")
            -- The estimate: the lowest price times the quantity, a lower
            -- bound (the price climbs as listings are bought up), hence the
            -- tilde. The quote carries the real total.
            buyBtn:SetText(format("Buy %d (~%s)", disp.needed,
                self:_RestockEstimateText((disp.minPrice or 0) * disp.needed)))
            buyBtn:SetWidth(140)
            if buyBtn.SetAutoWidth then buyBtn:SetAutoWidth(true) end
            buyBtn:SetDisabled(buyDisabled)
            buyBtn:SetCallback("OnClick", function()
                self:StartRestockBuy(idx)
            end)
            grp:AddChild(buyBtn)
            focus(buyBtn)
        end
        if pending > 0 then
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
        end
    end

    -- The universe is emitted tab-by-tab (then reserves), so each group is a
    -- contiguous run. Break on (tabIndex, name) so two display tabs that happen
    -- to share a name still get their own heading.
    local lastKey = nil
    local function renderGroup(rows)
        for _, row in ipairs(rows) do
            local heading = row.group or "Items"
            local key = tostring(row.tabIndex) .. "|" .. heading
            if key ~= lastKey then
                local h = AceGUI:Create("Heading")
                h:SetFullWidth(true)
                h:SetText(heading)
                content:AddChild(h)
                lastKey = key
            end
            renderRow(row)
        end
    end
    renderGroup(universe)
    renderGroup(orphans)
end
