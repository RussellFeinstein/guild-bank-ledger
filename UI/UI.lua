------------------------------------------------------------------------
-- GuildBankLedger — UI/UI.lua
-- Main AceGUI frame, tab switching, minimap button integration.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Main frame
------------------------------------------------------------------------

--- Create the main addon frame (lazy — only created once).
function GBL:CreateMainFrame()
    if self.mainFrame then return end

    local AceGUI = LibStub("AceGUI-3.0")

    local frame = AceGUI:Create("Frame")
    frame:SetTitle("GuildBankLedger")
    frame:SetWidth(self.db.profile.ui.width or 1000)
    frame:SetHeight(self.db.profile.ui.height or 600)
    frame:SetLayout("Fill")
    frame:SetCallback("OnClose", function(widget)
        widget:Hide()
    end)
    frame:Hide()

    -- Version label (top-right corner, respects font scaling)
    local versionLabel = frame.frame:CreateFontString(nil, "OVERLAY")
    local fontPath, fontSize = self:GetScaledFont()
    versionLabel:SetFont(fontPath, fontSize)
    versionLabel:SetPoint("TOPRIGHT", frame.frame, "TOPRIGHT", -30, -12)
    versionLabel:SetText("|cff888888v" .. self.version .. "|r")
    self._versionLabel = versionLabel

    -- Tab group
    local tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("List")
    tabGroup:SetCallback("OnGroupSelected", function(_widget, _event, group)
        self:SelectTab(group)
    end)
    frame:AddChild(tabGroup)

    self.mainFrame = frame
    self.tabGroup = tabGroup

    -- Build tab list based on access level and select default tab
    self:RebuildTabs()
end

--- Build the tab list based on the player's access level.
-- Called on frame creation and when access control settings change.
function GBL:RebuildTabs()
    if not self.tabGroup then return end

    local accessLevel = self:GetAccessLevel()
    local tabs
    if accessLevel == "sync_only" then
        tabs = {
            { value = "sync", text = "Sync" },
            { value = "changelog", text = "Changelog" },
            { value = "about", text = "About" },
        }
    else
        tabs = {
            { value = "transactions", text = "Transactions" },
            { value = "goldlog", text = "Gold Log" },
            { value = "consumption", text = "Consumption" },
            { value = "sync", text = "Sync" },
            { value = "changelog", text = "Changelog" },
            { value = "about", text = "About" },
        }
    end

    self.tabGroup:SetTabs(tabs)

    -- Hook BuildTabs to right-align utility tabs (Sync, Changelog)
    if not self._buildTabsHooked then
        local origBuildTabs = self.tabGroup.BuildTabs
        self.tabGroup.BuildTabs = function(widget)
            origBuildTabs(widget)
            if not widget.tablist or not widget.tabs then return end

            local rightIndices = {}
            for i, def in ipairs(widget.tablist) do
                if def.value == "sync" or def.value == "changelog" or def.value == "about" then
                    rightIndices[#rightIndices + 1] = i
                end
            end
            if #rightIndices == 0 then return end

            local hastitle = widget.titletext
                and widget.titletext:GetText()
                and widget.titletext:GetText() ~= ""
            local yOff = -(hastitle and 14 or 7)

            for j = #rightIndices, 1, -1 do
                local tab = widget.tabs[rightIndices[j]]
                tab:ClearAllPoints()
                if j == #rightIndices then
                    tab:SetPoint("TOPRIGHT", widget.frame, "TOPRIGHT", 0, yOff)
                else
                    tab:SetPoint("RIGHT", widget.tabs[rightIndices[j + 1]], "LEFT", 10, 0)
                end
            end
        end
        self._buildTabsHooked = true
        self.tabGroup:BuildTabs()
    end

    -- Ensure activeTab is valid for the current tab set
    local validTab = false
    for _, t in ipairs(tabs) do
        if t.value == self.activeTab then validTab = true; break end
    end
    if not validTab then
        self.activeTab = tabs[1].value
    end

    self.tabGroup:SelectTab(self.activeTab)
end

--- Toggle the main frame visibility.
function GBL:ToggleMainFrame()
    self:CreateMainFrame()

    local shown = self.mainFrame.frame and self.mainFrame.frame:IsShown()
    if shown then
        self.mainFrame:Hide()
    else
        self.mainFrame:Show()
        self:RefreshUI()
    end
end

--- Refresh the active tab's content.
-- Uses per-tab refresh when possible to preserve filter/sort state.
-- Falls back to full tab rebuild if the tab hasn't been built yet.
function GBL:RefreshUI()
    if not self.tabGroup then return end

    self:UpdateVersionLabel()

    local guildData = self:GetGuildData()
    local tab = self.activeTab or "transactions"

    if tab == "goldlog" and self._goldLogContainer then
        -- Update stored data reference, re-render with existing filters
        self._goldLogTransactions = guildData and guildData.moneyTransactions or {}
        self:RefreshGoldLog()
    elseif tab == "transactions" and self._ledgerContainer then
        self._ledgerTransactions = guildData and guildData.transactions or {}
        self:RefreshLedgerView()
    elseif tab == "consumption" and self._consumptionContainer then
        local transactions = guildData and guildData.transactions or {}
        local moneyTransactions = guildData and guildData.moneyTransactions or {}
        local allTx = {}
        for i = 1, #transactions do allTx[#allTx + 1] = transactions[i] end
        for i = 1, #moneyTransactions do allTx[#allTx + 1] = moneyTransactions[i] end
        self._consumptionTransactions = allTx
        self:RefreshConsumptionView()
    else
        -- Tab not built yet or sync tab — full rebuild
        self.tabGroup:SelectTab(tab)
    end
end

--- Update the version label to reflect peer-based update availability.
function GBL:UpdateVersionLabel()
    if not self._versionLabel then return end
    local highest = self:GetHighestPeerVersion()
    if highest and self:CompareSemver(self.version, highest) < 0 then
        self._versionLabel:SetText("|cffff8800v" .. self.version
            .. " — update available (v" .. highest .. ")!|r")
    else
        self._versionLabel:SetText("|cff888888v" .. self.version .. "|r")
    end
end

--- Switch between tabs.
-- @param tabName string "transactions", "goldlog", "consumption", or "sync"
function GBL:SelectTab(tabName)
    if not self.tabGroup then return end
    self.activeTab = tabName
    self.tabGroup:ReleaseChildren()

    local accessLevel = self:GetAccessLevel()

    -- Settings row (visible to full-access users only)
    if accessLevel == "full" then
        self:AddSettingsRow(self.tabGroup)
    end

    -- Restricted mode banner
    if accessLevel == "own_transactions" then
        self:AddRestrictedBanner(self.tabGroup, "Showing your transactions only.")
    elseif accessLevel == "sync_only" then
        self:AddRestrictedBanner(self.tabGroup, "Restricted view — limited tabs available.")
    end

    local guildData = self:GetGuildData()
    local transactions = guildData and guildData.transactions or {}
    local moneyTransactions = guildData and guildData.moneyTransactions or {}

    -- Pre-filter to own transactions in restricted mode
    if accessLevel == "own_transactions" then
        local myName = UnitName("player") or ""
        transactions = self:FilterByPlayer(transactions, myName)
        moneyTransactions = self:FilterByPlayer(moneyTransactions, myName)
    end

    if tabName == "transactions" then
        self:BuildTransactionsTab(self.tabGroup, transactions)
    elseif tabName == "goldlog" then
        self:BuildGoldLogTab(self.tabGroup, moneyTransactions)
    elseif tabName == "consumption" then
        -- Merge item + money transactions for consumption aggregation
        local allTx = {}
        for i = 1, #transactions do allTx[#allTx + 1] = transactions[i] end
        for i = 1, #moneyTransactions do allTx[#allTx + 1] = moneyTransactions[i] end
        self:BuildConsumptionTab(self.tabGroup, allTx)
    elseif tabName == "sync" then
        self:BuildSyncTab(self.tabGroup)
    elseif tabName == "changelog" then
        self:BuildChangelogTab(self.tabGroup)
    elseif tabName == "about" then
        self:BuildAboutTab(self.tabGroup)
    end
end

--- Filter a records array to only records from the given player.
-- @param records table Array of transaction records
-- @param playerName string Player name (without realm)
-- @return table Filtered array
function GBL:FilterByPlayer(records, playerName)
    local filtered = {}
    for _, record in ipairs(records) do
        if record.player and self:StripRealm(record.player) == playerName then
            filtered[#filtered + 1] = record
        end
    end
    return filtered
end

--- Show a yellow banner indicating restricted access mode.
-- @param container AceGUI container to add the banner to
-- @param text string Banner message
function GBL:AddRestrictedBanner(container, text)
    local AceGUI = LibStub("AceGUI-3.0")
    local label = AceGUI:Create("Label")
    label:SetFullWidth(true)
    label:SetText("|cffffcc00" .. text .. "|r")
    label:SetFontObject(GameFontNormalSmall)
    container:AddChild(label)
end

------------------------------------------------------------------------
-- Settings row (full-access users)
------------------------------------------------------------------------

--- Add officer settings checkboxes to a container.
-- @param container AceGUI container
function GBL:AddSettingsRow(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local row = AceGUI:Create("SimpleGroup")
    row:SetFullWidth(true)
    row:SetLayout("Flow")
    container:AddChild(row)

    local openCB = AceGUI:Create("CheckBox")
    openCB:SetLabel("Open with Guild Bank")
    openCB:SetWidth(200)
    openCB:SetValue(self.db.profile.ui.openOnBankOpen)
    openCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.ui.openOnBankOpen = value
    end)
    row:AddChild(openCB)

    local lockCB = AceGUI:Create("CheckBox")
    lockCB:SetLabel("Lock while scanning")
    lockCB:SetWidth(200)
    lockCB:SetValue(self.db.profile.scanning.lockBankWhileScanning)
    lockCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.scanning.lockBankWhileScanning = value
    end)
    row:AddChild(lockCB)

    local rescanCB = AceGUI:Create("CheckBox")
    rescanCB:SetLabel("Auto re-scan")
    rescanCB:SetWidth(200)
    rescanCB:SetValue(self.db.profile.scanning.rescanEnabled)
    rescanCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.scanning.rescanEnabled = value
        if value and self:IsBankOpen() then
            self:StartPeriodicRescan()
        else
            self:StopPeriodicRescan()
        end
    end)
    row:AddChild(rescanCB)

    local minimapCB = AceGUI:Create("CheckBox")
    minimapCB:SetLabel("Show minimap button")
    minimapCB:SetWidth(200)
    minimapCB:SetValue(not self.db.profile.minimap.hide)
    minimapCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        self.db.profile.minimap.hide = not value
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDBIcon then
            if value then
                LDBIcon:Show("GuildBankLedger")
            else
                LDBIcon:Hide("GuildBankLedger")
            end
        end
    end)
    row:AddChild(minimapCB)
end

------------------------------------------------------------------------
-- Transactions tab
------------------------------------------------------------------------

function GBL:BuildTransactionsTab(container, transactions)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Filter bar
    local filterGroup = AceGUI:Create("SimpleGroup")
    filterGroup:SetFullWidth(true)
    filterGroup:SetLayout("Flow")
    container:AddChild(filterGroup)

    -- Ledger view (ScrollFrame for scrollable transaction list)
    local ledgerGroup = AceGUI:Create("ScrollFrame")
    ledgerGroup:SetFullWidth(true)
    ledgerGroup:SetFullHeight(true)
    ledgerGroup:SetLayout("Flow")

    local filters = self:CreateDefaultFilters()

    -- Apply pending search text from consumption tab player click
    if self._pendingSearchText then
        filters.searchText = self._pendingSearchText
        self._pendingSearchText = nil
    end

    -- Create filter widgets (references ledgerGroup via closure)
    self:CreateFilterWidgets(filterGroup, filters, function()
        self._ledgerCurrentPage = 1  -- reset pagination on filter change
        self:CreateLedgerView(ledgerGroup, transactions, filters)
    end)

    container:AddChild(ledgerGroup)
    ledgerGroup.frame:SetPoint("BOTTOMRIGHT", container.content, "BOTTOMRIGHT", 0, 0)

    -- Store references for refresh
    self._ledgerContainer = ledgerGroup
    self._ledgerTransactions = transactions
    self._ledgerFilters = filters

    self:CreateLedgerView(ledgerGroup, transactions, filters)
end

------------------------------------------------------------------------
-- Gold Log tab
------------------------------------------------------------------------

--- Gold log column definitions.
GBL.GOLD_LOG_COLUMNS = {
    { key = "timestamp", label = "Timestamp",  width = 145 },
    { key = "player",    label = "Player",     width = 120 },
    { key = "type",      label = "Action",     width = 115 },
    { key = "amount",    label = "Amount",     width = 120 },
}

-- Gold log pagination and sort state (session-only)
GBL.GOLD_LOG_PAGE_SIZE = 100
GBL.goldLogSortColumn = "timestamp"
GBL.goldLogSortAscending = false

function GBL:SetGoldLogSort(column)
    if self.goldLogSortColumn == column then
        self.goldLogSortAscending = not self.goldLogSortAscending
    else
        self.goldLogSortColumn = column
        self.goldLogSortAscending = true
    end
end

function GBL:GetGoldLogSortIndicator(column, label)
    if self.goldLogSortColumn ~= column then
        return label
    end
    if self.goldLogSortAscending then
        return label .. " [asc]"
    else
        return label .. " [desc]"
    end
end

function GBL:BuildGoldLogTab(container, moneyTransactions)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Filter bar
    local filterGroup = AceGUI:Create("SimpleGroup")
    filterGroup:SetFullWidth(true)
    filterGroup:SetLayout("Flow")
    container:AddChild(filterGroup)

    -- Content area (full width — summary renders to the right of data columns)
    local contentGroup = AceGUI:Create("ScrollFrame")
    contentGroup:SetFullWidth(true)
    contentGroup:SetFullHeight(true)
    contentGroup:SetLayout("Flow")
    container:AddChild(contentGroup)
    contentGroup.frame:SetPoint("BOTTOMRIGHT", container.content, "BOTTOMRIGHT", 0, 0)

    local filters = self:CreateDefaultFilters()

    -- Search box
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search")
    searchBox:SetWidth(150)
    searchBox:SetText("")
    searchBox:SetCallback("OnEnterPressed", function(_widget, _event, text)
        filters.searchText = text
        self._goldLogCurrentPage = 1
        self:RenderGoldLog(contentGroup, moneyTransactions, filters)
    end)
    filterGroup:AddChild(searchBox)

    -- Date range dropdown
    local dateDropdown = AceGUI:Create("Dropdown")
    dateDropdown:SetLabel("Date Range")
    dateDropdown:SetWidth(120)
    dateDropdown:SetList({
        ["1h"] = "Last Hour",
        ["3h"] = "Last 3 Hours",
        ["1d"] = "Last 24 Hours",
        ["7d"] = "Last 7 Days",
        ["30d"] = "Last 30 Days",
        ["all"] = "All Time",
    }, { "1h", "3h", "1d", "7d", "30d", "all" })
    dateDropdown:SetValue("30d")
    dateDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.dateRange = value
        self._goldLogCurrentPage = 1
        self:RenderGoldLog(contentGroup, moneyTransactions, filters)
    end)
    filterGroup:AddChild(dateDropdown)

    -- Type dropdown (money-specific types only)
    local typeDropdown = AceGUI:Create("Dropdown")
    typeDropdown:SetLabel("Type")
    typeDropdown:SetWidth(120)
    typeDropdown:SetList({
        ["ALL"] = "All Types",
        ["withdraw"] = "Withdraw",
        ["deposit"] = "Deposit",
        ["repair"] = "Repair",
    })
    typeDropdown:SetValue("ALL")
    typeDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.txType = value
        self._goldLogCurrentPage = 1
        self:RenderGoldLog(contentGroup, moneyTransactions, filters)
    end)
    filterGroup:AddChild(typeDropdown)

    -- Reset button
    local resetBtn = AceGUI:Create("Button")
    resetBtn:SetText("Reset")
    resetBtn:SetWidth(80)
    resetBtn:SetCallback("OnClick", function()
        local defaults = GBL:CreateDefaultFilters()
        for k, v in pairs(defaults) do
            filters[k] = v
        end
        searchBox:SetText("")
        dateDropdown:SetValue("30d")
        typeDropdown:SetValue("ALL")
        self._goldLogCurrentPage = 1
        self:RenderGoldLog(contentGroup, moneyTransactions, filters)
    end)
    filterGroup:AddChild(resetBtn)

    -- Store references for refresh
    self._goldLogContainer = contentGroup
    self._goldLogTransactions = moneyTransactions
    self._goldLogFilters = filters

    self:RenderGoldLog(contentGroup, moneyTransactions, filters)
end

--- Build an array of summary line descriptors for the gold log.
-- Each entry: { label=string, value=string, color=table|nil, isHeader=bool }
-- Rendered to the right of data rows in RenderGoldLog.
function GBL:BuildGoldLogSummaryLines(sums)
    local depositColor = self:GetAccessibleColor("DEPOSIT")
    local withdrawColor = self:GetAccessibleColor("WITHDRAW")
    local netColor = sums.net >= 0 and depositColor or withdrawColor

    local lines = {}
    local function add(label, amount, color, indent)
        local text = self:FormatMoney(math.abs(amount))
        if amount < 0 then text = "-" .. text end
        if amount > 0 and label == "Net" then text = "+" .. text end
        lines[#lines + 1] = {
            label = (indent and "  " or "") .. label,
            value = text,
            color = color,
        }
    end
    local function header(text)
        lines[#lines + 1] = { label = text, value = "", color = nil, isHeader = true }
    end
    local function spacer()
        lines[#lines + 1] = { label = "", value = "", color = nil }
    end

    header("Income")
    if sums.deposit > 0 then add("Deposits", sums.deposit, depositColor, true) end
    if sums.depositSummary > 0 then add("Deposit Summary", sums.depositSummary, depositColor, true) end
    add("Total In", sums.totalDeposited, depositColor, false)

    spacer()
    header("Outflow")
    if sums.withdraw > 0 then add("Withdrawals", sums.withdraw, withdrawColor, true) end
    if sums.repair > 0 then add("Repairs", sums.repair, withdrawColor, true) end
    if sums.buyTab > 0 then add("Tab Purchases", sums.buyTab, withdrawColor, true) end
    add("Total Out", sums.totalWithdrawn, withdrawColor, false)

    spacer()
    add("Net", sums.net, netColor, false)

    return lines
end

--- Render the gold log transaction list with summary to the right of data columns.
function GBL:RenderGoldLog(container, moneyTransactions, filters)
    container:ReleaseChildren()

    local AceGUI = LibStub("AceGUI-3.0")

    -- Filter and sort
    local filtered = self:FilterTransactions(moneyTransactions or {}, filters)
    self:SortTransactions(filtered, self.goldLogSortColumn, self.goldLogSortAscending)

    -- Pagination
    local pageSize = self.GOLD_LOG_PAGE_SIZE
    local totalPages = math.max(1, math.ceil(#filtered / pageSize))
    local currentPage = math.min(self._goldLogCurrentPage or 1, totalPages)
    self._goldLogCurrentPage = currentPage
    local startIdx = (currentPage - 1) * pageSize + 1
    local endIdx = math.min(currentPage * pageSize, #filtered)

    -- Compute summary lines (rendered to the right of data rows)
    local sums = self:ComputeGoldLogSums(filtered)
    local summaryLines = self:BuildGoldLogSummaryLines(sums)

    local function colorHex(c)
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end

    -- Append summary labels to a row at the given summary line index.
    local SUMMARY_DIV_W = 20   -- width of the vertical divider
    local SUMMARY_LABEL_W = 140
    local SUMMARY_VALUE_W = 130
    local function appendDivider(rowGroup)
        local div = AceGUI:Create("Label")
        div:SetWidth(SUMMARY_DIV_W)
        div:SetText("|cff666666\124\124")
        rowGroup:AddChild(div)
    end

    local function appendSummary(rowGroup, lineIdx)
        local line = summaryLines[lineIdx]
        if not line then return end

        if line.isHeader then
            local hdr = AceGUI:Create("Label")
            hdr:SetWidth(SUMMARY_LABEL_W + SUMMARY_VALUE_W)
            hdr.label:SetWordWrap(false)
            hdr:SetText("|cffffcc00" .. line.label .. "|r")
            rowGroup:AddChild(hdr)
        elseif not (line.label == "" and line.value == "") then
            local lbl = AceGUI:Create("Label")
            lbl:SetWidth(SUMMARY_LABEL_W)
            lbl.label:SetWordWrap(false)
            lbl:SetText(line.label)
            rowGroup:AddChild(lbl)

            local val = AceGUI:Create("Label")
            val:SetWidth(SUMMARY_VALUE_W)
            val.label:SetWordWrap(false)
            val:SetText(line.color and (colorHex(line.color) .. line.value .. "|r") or line.value)
            rowGroup:AddChild(val)
        end
    end

    -- Status line
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    if #filtered > pageSize then
        status:SetText("Showing " .. startIdx .. "-" .. endIdx .. " of " .. #filtered .. " gold transactions")
    else
        status:SetText(#filtered .. " gold transactions")
    end
    container:AddChild(status)

    -- Column headers + "Summary" header on the right
    local headerGroup = AceGUI:Create("SimpleGroup")
    headerGroup:SetFullWidth(true)
    headerGroup:SetLayout("Flow")
    container:AddChild(headerGroup)

    for _, col in ipairs(self.GOLD_LOG_COLUMNS) do
        local btn = AceGUI:Create("InteractiveLabel")
        btn:SetWidth(col.width)
        btn.label:SetWordWrap(false)
        btn:SetText(self:GetGoldLogSortIndicator(col.key, col.label))
        btn:SetCallback("OnClick", function()
            self:SetGoldLogSort(col.key)
            self._goldLogCurrentPage = 1
            self:RenderGoldLog(container, moneyTransactions, filters)
        end)
        headerGroup:AddChild(btn)
    end

    if #filtered > 0 then
        local divHdr = AceGUI:Create("Label")
        divHdr:SetWidth(SUMMARY_DIV_W)
        divHdr:SetText("|cff666666\124\124")
        headerGroup:AddChild(divHdr)

        local summaryHeader = AceGUI:Create("Label")
        summaryHeader:SetWidth(SUMMARY_LABEL_W + SUMMARY_VALUE_W)
        summaryHeader:SetText("|cffffcc00Summary|r")
        headerGroup:AddChild(summaryHeader)
    end

    -- Empty state
    if #filtered == 0 then
        local emptyLabel = AceGUI:Create("Label")
        emptyLabel:SetFullWidth(true)
        emptyLabel:SetText(
            (#(moneyTransactions or {}) == 0)
                and "No gold transactions recorded yet. Open your guild bank to start scanning."
                or "No gold transactions match your filters."
        )
        container:AddChild(emptyLabel)
        return
    end

    -- Data rows with summary to the right
    local summaryLineIdx = 1
    local numRows = math.max(endIdx - startIdx + 1, #summaryLines)

    for rowNum = 1, numRows do
        local rowGroup = AceGUI:Create("SimpleGroup")
        rowGroup:SetFullWidth(true)
        rowGroup:SetLayout("Flow")
        container:AddChild(rowGroup)

        -- Data columns (left side)
        local dataIdx = startIdx + rowNum - 1
        if dataIdx <= endIdx then
            local tx = filtered[dataIdx]
            for _, col in ipairs(self.GOLD_LOG_COLUMNS) do
                local lbl = AceGUI:Create("Label")
                lbl:SetWidth(col.width)
                lbl.label:SetWordWrap(false)
                if col.key == "timestamp" then
                    lbl:SetText(self:FormatTimestamp(tx.timestamp))
                elseif col.key == "player" then
                    lbl:SetText(tx.player or "Unknown")
                elseif col.key == "type" then
                    lbl:SetText(self:GetTxTypeDisplay(tx.type).label)
                elseif col.key == "amount" then
                    lbl:SetText(self:FormatMoney(tx.amount))
                end
                rowGroup:AddChild(lbl)
            end
        else
            -- Padding row (no data, just summary on right)
            local colWidth = 0
            for _, col in ipairs(self.GOLD_LOG_COLUMNS) do colWidth = colWidth + col.width end
            local pad = AceGUI:Create("Label")
            pad:SetWidth(colWidth)
            pad:SetText("")
            rowGroup:AddChild(pad)
        end

        -- Vertical divider (continues on every row)
        appendDivider(rowGroup)

        -- Summary content (right side, only on first N rows)
        if summaryLineIdx <= #summaryLines then
            appendSummary(rowGroup, summaryLineIdx)
            summaryLineIdx = summaryLineIdx + 1
        end
    end

    -- TODO: Pagination controls not rendering in AceGUI ScrollFrame — fix layout
    -- Page data is capped to 100 rows; controls needed to navigate pages.
end

--- Refresh the gold log with current data and filters.
function GBL:RefreshGoldLog()
    if self._goldLogContainer and self._goldLogTransactions then
        self._goldLogCurrentPage = 1  -- reset pagination on refresh
        self:RenderGoldLog(
            self._goldLogContainer,
            self._goldLogTransactions,
            self._goldLogFilters
        )
    end
end

------------------------------------------------------------------------
-- Consumption tab — sort state
------------------------------------------------------------------------

-- Consumer table sort state (session-only)
GBL.consumptionSortColumn = "netConsumed"
GBL.consumptionSortAscending = false

--- Toggle sort on a consumption column.
-- @param column string sort column key
function GBL:SetConsumptionSort(column)
    if self.consumptionSortColumn == column then
        self.consumptionSortAscending = not self.consumptionSortAscending
    else
        self.consumptionSortColumn = column
        self.consumptionSortAscending = true
    end
end

--- Get the sort indicator text for a consumption column header.
-- @param column string column key
-- @param label string base label text
-- @return string label with [asc]/[desc] or plain
function GBL:GetConsumptionSortIndicator(column, label)
    if self.consumptionSortColumn ~= column then
        return label
    end
    if self.consumptionSortAscending then
        return label .. " [asc]"
    else
        return label .. " [desc]"
    end
end

-- Item table sort state (separate from consumer table)
GBL.itemSortColumn = "usedAll"
GBL.itemSortAscending = false

--- Toggle sort on a top items column.
-- @param column string sort column key
function GBL:SetItemSort(column)
    if self.itemSortColumn == column then
        self.itemSortAscending = not self.itemSortAscending
    else
        self.itemSortColumn = column
        self.itemSortAscending = true
    end
end

--- Get the sort indicator text for an item column header.
-- @param column string column key
-- @param label string base label text
-- @return string label with [asc]/[desc] or plain
function GBL:GetItemSortIndicator(column, label)
    if self.itemSortColumn ~= column then
        return label
    end
    if self.itemSortAscending then
        return label .. " [asc]"
    else
        return label .. " [desc]"
    end
end

--- Build the top item display string from a player summary's topItems.
-- Shows only the #1 most active item for readability.
-- @param topItems table array of { itemID, count, itemLink }
-- @return string top item name or empty string
function GBL:FormatTopItems(topItems)
    if not topItems or #topItems == 0 then
        return ""
    end
    return self:ExtractItemName(topItems[1].itemLink, topItems[1].itemID)
end

------------------------------------------------------------------------
-- Consumption tab — column definitions
------------------------------------------------------------------------

--- Consumer table columns (top consumers section).
GBL.CONSUMER_COLUMNS = {
    { key = "player",         label = "Player",    width = 120, sortKey = "player" },
    { key = "netConsumed",    label = "Items Out",  width = 80,  sortKey = "netConsumed" },
    { key = "netContributed", label = "Items In",   width = 80,  sortKey = "netContributed" },
    { key = "moneyWithdrawn", label = "Gold Out",  width = 100, sortKey = "moneyWithdrawn" },
    { key = "moneyDeposited", label = "Gold In",   width = 100, sortKey = "moneyDeposited" },
    { key = "moneyNet",       label = "Gold Net",  width = 100, sortKey = "moneyNet" },
}

--- Top items table columns (most used items section).
GBL.TOP_ITEM_COLUMNS = {
    { key = "itemName",  label = "Item",     width = 180, sortKey = nil },
    { key = "category",  label = "Category", width = 100, sortKey = nil },
    { key = "used7d",    label = "7d",       width = 65,  sortKey = "used7d" },
    { key = "used30d",   label = "30d",      width = 65,  sortKey = "used30d" },
    { key = "usedAll",   label = "All",      width = 65,  sortKey = "usedAll" },
}

--- Maximum rows in the top consumers table.
GBL.MAX_CONSUMERS = 10

--- Maximum rows in the top items table.
GBL.MAX_TOP_ITEMS = 15

function GBL:BuildConsumptionTab(container, transactions)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Filter bar
    local filterGroup = AceGUI:Create("SimpleGroup")
    filterGroup:SetFullWidth(true)
    filterGroup:SetLayout("Flow")
    container:AddChild(filterGroup)

    -- Content area (ScrollFrame for scrollable dashboard)
    local contentGroup = AceGUI:Create("ScrollFrame")

    local filters = self:CreateDefaultFilters()

    -- Date dropdown
    local dateDropdown = AceGUI:Create("Dropdown")
    dateDropdown:SetLabel("Date Range")
    dateDropdown:SetWidth(120)
    dateDropdown:SetList({
        ["1h"] = "Last Hour",
        ["3h"] = "Last 3 Hours",
        ["1d"] = "Last 24 Hours",
        ["7d"] = "Last 7 Days",
        ["30d"] = "Last 30 Days",
        ["all"] = "All Time",
    }, { "1h", "3h", "1d", "7d", "30d", "all" })
    dateDropdown:SetValue("30d")
    dateDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.dateRange = value
        self:RenderConsumptionDashboard(contentGroup, transactions, filters)
    end)
    filterGroup:AddChild(dateDropdown)

    -- Category dropdown
    local catDropdown = AceGUI:Create("Dropdown")
    catDropdown:SetLabel("Category")
    catDropdown:SetWidth(120)
    local catList = { ["ALL"] = "All Categories" }
    if GBL.GetAllCategories then
        local cats = GBL:GetAllCategories()
        for _, cat in ipairs(cats) do
            catList[cat] = cat
        end
    end
    catDropdown:SetList(catList)
    catDropdown:SetValue("ALL")
    catDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.category = value
        self:RenderConsumptionDashboard(contentGroup, transactions, filters)
    end)
    filterGroup:AddChild(catDropdown)

    -- Reset button
    local resetBtn = AceGUI:Create("Button")
    resetBtn:SetText("Reset")
    resetBtn:SetWidth(80)
    resetBtn:SetCallback("OnClick", function()
        local defaults = GBL:CreateDefaultFilters()
        for k, v in pairs(defaults) do
            filters[k] = v
        end
        dateDropdown:SetValue("30d")
        catDropdown:SetValue("ALL")
        self:RenderConsumptionDashboard(contentGroup, transactions, filters)
    end)
    filterGroup:AddChild(resetBtn)

    contentGroup:SetFullWidth(true)
    contentGroup:SetFullHeight(true)
    contentGroup:SetLayout("Flow")
    container:AddChild(contentGroup)
    contentGroup.frame:SetPoint("BOTTOMRIGHT", container.content, "BOTTOMRIGHT", 0, 0)

    -- Store references for refresh
    self._consumptionContainer = contentGroup
    self._consumptionTransactions = transactions
    self._consumptionFilters = filters

    self:RenderConsumptionDashboard(contentGroup, transactions, filters)
end

--- Refresh the consumption view with current data and filters.
function GBL:RefreshConsumptionView()
    if self._consumptionContainer and self._consumptionTransactions then
        self:RenderConsumptionDashboard(
            self._consumptionContainer,
            self._consumptionTransactions,
            self._consumptionFilters
        )
    end
end

--- Render the guild-wide consumption dashboard.
-- Three sections: guild totals, top consumers, most used items.
function GBL:RenderConsumptionDashboard(container, transactions, filters)
    container:ReleaseChildren()

    local AceGUI = LibStub("AceGUI-3.0")

    -- Build data for guild totals + top consumers (full filters including date range)
    local summaries = self:BuildConsumptionSummary(transactions, filters)
    self:SortConsumptionSummary(summaries, self.consumptionSortColumn, self.consumptionSortAscending)
    local totals = self:BuildGuildTotals(summaries)

    -- Build data for top items (category filter only — time buckets are independent)
    local categoryFilter = filters and filters.category or "ALL"
    local itemSummaries = self:BuildGuildItemSummary(transactions, categoryFilter)

    -- Sort items
    local itemSortKey = self.itemSortColumn or "usedAll"
    table.sort(itemSummaries, function(a, b)
        local av = a[itemSortKey] or 0
        local bv = b[itemSortKey] or 0
        if self.itemSortAscending then
            return av < bv
        else
            return av > bv
        end
    end)

    -- Color helpers
    local depositColor = self:GetAccessibleColor("DEPOSIT")
    local withdrawColor = self:GetAccessibleColor("WITHDRAW")
    local function colorHex(c)
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end

    -- Empty state
    if #summaries == 0 and #itemSummaries == 0 then
        local emptyLabel = AceGUI:Create("Label")
        emptyLabel:SetFullWidth(true)
        emptyLabel:SetText("No consumption data available.")
        container:AddChild(emptyLabel)
        return
    end

    --------------------------------------------------------------------
    -- Section 1: Guild Totals
    --------------------------------------------------------------------
    local totalsHeader = AceGUI:Create("Label")
    totalsHeader:SetFullWidth(true)
    totalsHeader:SetText("|cffffcc00Guild Overview|r")
    container:AddChild(totalsHeader)

    -- Player count
    local playerLine = AceGUI:Create("Label")
    playerLine:SetFullWidth(true)
    playerLine:SetText(totals.playerCount .. " active player" .. (totals.playerCount ~= 1 and "s" or ""))
    container:AddChild(playerLine)

    -- Items line
    local itemsNetColor = totals.itemsNet >= 0 and depositColor or withdrawColor
    local itemsLine = AceGUI:Create("Label")
    itemsLine:SetFullWidth(true)
    itemsLine:SetText(
        "Items:  " ..
        colorHex(depositColor) .. totals.itemsDeposited .. " deposited|r  |  " ..
        colorHex(withdrawColor) .. totals.itemsWithdrawn .. " withdrawn|r  |  " ..
        "Net: " .. colorHex(itemsNetColor) .. (totals.itemsNet >= 0 and "+" or "") .. totals.itemsNet .. "|r"
    )
    container:AddChild(itemsLine)

    -- Gold line
    local goldNetColor = totals.goldNet >= 0 and depositColor or withdrawColor
    local goldLine = AceGUI:Create("Label")
    goldLine:SetFullWidth(true)
    goldLine:SetText(
        "Gold:   " ..
        colorHex(depositColor) .. self:FormatMoney(totals.goldDeposited) .. " in|r  |  " ..
        colorHex(withdrawColor) .. self:FormatMoney(totals.goldWithdrawn) .. " out|r  |  " ..
        "Net: " .. colorHex(goldNetColor) ..
        (totals.goldNet >= 0 and "+" or "") .. self:FormatMoney(totals.goldNet) .. "|r"
    )
    container:AddChild(goldLine)

    -- Spacer
    local spacer1 = AceGUI:Create("Label")
    spacer1:SetFullWidth(true)
    spacer1:SetText(" ")
    container:AddChild(spacer1)

    --------------------------------------------------------------------
    -- Section 2: Top Consumers
    --------------------------------------------------------------------
    local consumerHeader = AceGUI:Create("Label")
    consumerHeader:SetFullWidth(true)
    consumerHeader:SetText("|cffffcc00Top Consumers|r")
    container:AddChild(consumerHeader)

    if #summaries == 0 then
        local emptyConsumers = AceGUI:Create("Label")
        emptyConsumers:SetFullWidth(true)
        emptyConsumers:SetText("No player activity in this period.")
        container:AddChild(emptyConsumers)
    else
        -- Column headers
        local cHeaderGroup = AceGUI:Create("SimpleGroup")
        cHeaderGroup:SetFullWidth(true)
        cHeaderGroup:SetLayout("Flow")
        container:AddChild(cHeaderGroup)

        for _, col in ipairs(self.CONSUMER_COLUMNS) do
            if col.sortKey then
                local btn = AceGUI:Create("InteractiveLabel")
                btn:SetWidth(col.width)
                btn.label:SetWordWrap(false)
                btn:SetText("|cffffcc00" .. self:GetConsumptionSortIndicator(col.sortKey, col.label) .. "|r")
                btn:SetCallback("OnClick", function()
                    self:SetConsumptionSort(col.sortKey)
                    self:RenderConsumptionDashboard(container, transactions, filters)
                end)
                cHeaderGroup:AddChild(btn)
            else
                local lbl = AceGUI:Create("Label")
                lbl:SetWidth(col.width)
                lbl.label:SetWordWrap(false)
                lbl:SetText("|cffffcc00" .. col.label .. "|r")
                cHeaderGroup:AddChild(lbl)
            end
        end

        -- Consumer data rows (top N)
        local consumerCount = math.min(#summaries, self.MAX_CONSUMERS)
        for idx = 1, consumerCount do
            local p = summaries[idx]
            local rowGroup = AceGUI:Create("SimpleGroup")
            rowGroup:SetFullWidth(true)
            rowGroup:SetLayout("Flow")
            container:AddChild(rowGroup)

            -- Player (clickable → navigate to Transactions tab)
            local playerBtn = AceGUI:Create("InteractiveLabel")
            playerBtn:SetWidth(self.CONSUMER_COLUMNS[1].width)
            playerBtn.label:SetWordWrap(false)
            playerBtn:SetText(p.player)
            playerBtn:SetCallback("OnClick", function()
                self._pendingSearchText = p.player
                self.tabGroup:SelectTab("transactions")
            end)
            rowGroup:AddChild(playerBtn)

            -- Items Out
            local outLabel = AceGUI:Create("Label")
            outLabel:SetWidth(self.CONSUMER_COLUMNS[2].width)
            outLabel.label:SetWordWrap(false)
            outLabel:SetText(tostring(p.netConsumed))
            rowGroup:AddChild(outLabel)

            -- Items In
            local inLabel = AceGUI:Create("Label")
            inLabel:SetWidth(self.CONSUMER_COLUMNS[3].width)
            inLabel.label:SetWordWrap(false)
            inLabel:SetText(tostring(p.netContributed))
            rowGroup:AddChild(inLabel)

            -- Gold Out
            local goldOutLabel = AceGUI:Create("Label")
            goldOutLabel:SetWidth(self.CONSUMER_COLUMNS[4].width)
            goldOutLabel.label:SetWordWrap(false)
            goldOutLabel:SetText(self:FormatMoney(p.moneyWithdrawn))
            rowGroup:AddChild(goldOutLabel)

            -- Gold In
            local goldInLabel = AceGUI:Create("Label")
            goldInLabel:SetWidth(self.CONSUMER_COLUMNS[5].width)
            goldInLabel.label:SetWordWrap(false)
            goldInLabel:SetText(self:FormatMoney(p.moneyDeposited))
            rowGroup:AddChild(goldInLabel)

            -- Gold Net (colored)
            local goldNetLabel = AceGUI:Create("Label")
            goldNetLabel:SetWidth(self.CONSUMER_COLUMNS[6].width)
            goldNetLabel.label:SetWordWrap(false)
            local netColor = p.moneyNet >= 0 and depositColor or withdrawColor
            local netText = (p.moneyNet >= 0 and "+" or "") .. self:FormatMoney(p.moneyNet)
            goldNetLabel:SetText(colorHex(netColor) .. netText .. "|r")
            rowGroup:AddChild(goldNetLabel)
        end

        if #summaries > self.MAX_CONSUMERS then
            local moreLabel = AceGUI:Create("Label")
            moreLabel:SetFullWidth(true)
            moreLabel:SetText("|cff999999..." .. (#summaries - self.MAX_CONSUMERS) .. " more players|r")
            container:AddChild(moreLabel)
        end
    end

    -- Spacer
    local spacer2 = AceGUI:Create("Label")
    spacer2:SetFullWidth(true)
    spacer2:SetText(" ")
    container:AddChild(spacer2)

    --------------------------------------------------------------------
    -- Section 3: Most Used Items
    --------------------------------------------------------------------
    local itemHeader = AceGUI:Create("Label")
    itemHeader:SetFullWidth(true)
    itemHeader:SetText("|cffffcc00Most Used Items|r")
    container:AddChild(itemHeader)

    if #itemSummaries == 0 then
        local emptyItems = AceGUI:Create("Label")
        emptyItems:SetFullWidth(true)
        emptyItems:SetText("No item withdrawals recorded.")
        container:AddChild(emptyItems)
    else
        -- Column headers
        local iHeaderGroup = AceGUI:Create("SimpleGroup")
        iHeaderGroup:SetFullWidth(true)
        iHeaderGroup:SetLayout("Flow")
        container:AddChild(iHeaderGroup)

        for _, col in ipairs(self.TOP_ITEM_COLUMNS) do
            if col.sortKey then
                local btn = AceGUI:Create("InteractiveLabel")
                btn:SetWidth(col.width)
                btn.label:SetWordWrap(false)
                btn:SetText("|cffffcc00" .. self:GetItemSortIndicator(col.sortKey, col.label) .. "|r")
                btn:SetCallback("OnClick", function()
                    self:SetItemSort(col.sortKey)
                    self:RenderConsumptionDashboard(container, transactions, filters)
                end)
                iHeaderGroup:AddChild(btn)
            else
                local lbl = AceGUI:Create("Label")
                lbl:SetWidth(col.width)
                lbl.label:SetWordWrap(false)
                lbl:SetText("|cffffcc00" .. col.label .. "|r")
                iHeaderGroup:AddChild(lbl)
            end
        end

        -- Item data rows (top N)
        local itemCount = math.min(#itemSummaries, self.MAX_TOP_ITEMS)
        for idx = 1, itemCount do
            local item = itemSummaries[idx]
            local rowGroup = AceGUI:Create("SimpleGroup")
            rowGroup:SetFullWidth(true)
            rowGroup:SetLayout("Flow")
            container:AddChild(rowGroup)

            -- Item name
            local nameLabel = AceGUI:Create("Label")
            nameLabel:SetWidth(self.TOP_ITEM_COLUMNS[1].width)
            nameLabel.label:SetWordWrap(false)
            nameLabel:SetText(item.itemName)
            rowGroup:AddChild(nameLabel)

            -- Category
            local catLabel = AceGUI:Create("Label")
            catLabel:SetWidth(self.TOP_ITEM_COLUMNS[2].width)
            catLabel.label:SetWordWrap(false)
            catLabel:SetText(item.categoryDisplay)
            rowGroup:AddChild(catLabel)

            -- 7d
            local d7Label = AceGUI:Create("Label")
            d7Label:SetWidth(self.TOP_ITEM_COLUMNS[3].width)
            d7Label.label:SetWordWrap(false)
            d7Label:SetText(tostring(item.used7d))
            rowGroup:AddChild(d7Label)

            -- 30d
            local d30Label = AceGUI:Create("Label")
            d30Label:SetWidth(self.TOP_ITEM_COLUMNS[4].width)
            d30Label.label:SetWordWrap(false)
            d30Label:SetText(tostring(item.used30d))
            rowGroup:AddChild(d30Label)

            -- All
            local allLabel = AceGUI:Create("Label")
            allLabel:SetWidth(self.TOP_ITEM_COLUMNS[5].width)
            allLabel.label:SetWordWrap(false)
            allLabel:SetText(tostring(item.usedAll))
            rowGroup:AddChild(allLabel)
        end

        if #itemSummaries > self.MAX_TOP_ITEMS then
            local moreLabel = AceGUI:Create("Label")
            moreLabel:SetFullWidth(true)
            moreLabel:SetText("|cff999999..." .. (#itemSummaries - self.MAX_TOP_ITEMS) .. " more items|r")
            container:AddChild(moreLabel)
        end
    end
end

------------------------------------------------------------------------
-- Filter widgets
------------------------------------------------------------------------

--- Create the filter bar widgets inside a container.
-- @param container AceGUI container
-- @param filters table filter criteria (modified in place)
-- @param onChange function callback when any filter changes
function GBL:CreateFilterWidgets(container, filters, onChange)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Search box (initialized from filters.searchText for cross-tab navigation)
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search")
    searchBox:SetWidth(150)
    searchBox:SetText(filters.searchText or "")
    searchBox:SetCallback("OnEnterPressed", function(_widget, _event, text)
        filters.searchText = text
        if onChange then onChange() end
    end)
    container:AddChild(searchBox)

    -- Date range dropdown
    local dateDropdown = AceGUI:Create("Dropdown")
    dateDropdown:SetLabel("Date Range")
    dateDropdown:SetWidth(120)
    dateDropdown:SetList({
        ["1h"] = "Last Hour",
        ["3h"] = "Last 3 Hours",
        ["1d"] = "Last 24 Hours",
        ["7d"] = "Last 7 Days",
        ["30d"] = "Last 30 Days",
        ["all"] = "All Time",
    }, { "1h", "3h", "1d", "7d", "30d", "all" })
    dateDropdown:SetValue("30d")
    dateDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.dateRange = value
        if onChange then onChange() end
    end)
    container:AddChild(dateDropdown)

    -- Category dropdown
    local catDropdown = AceGUI:Create("Dropdown")
    catDropdown:SetLabel("Category")
    catDropdown:SetWidth(120)
    local catList = { ["ALL"] = "All Categories" }
    if GBL.GetAllCategories then
        local cats = GBL:GetAllCategories()
        for _, cat in ipairs(cats) do
            catList[cat] = cat
        end
    end
    catDropdown:SetList(catList)
    catDropdown:SetValue("ALL")
    catDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.category = value
        if onChange then onChange() end
    end)
    container:AddChild(catDropdown)

    -- Transaction type dropdown
    local typeDropdown = AceGUI:Create("Dropdown")
    typeDropdown:SetLabel("Type")
    typeDropdown:SetWidth(100)
    typeDropdown:SetList({
        ["ALL"] = "All Types",
        ["withdraw"] = "Withdraw",
        ["deposit"] = "Deposit",
        ["move"] = "Move",
    })
    typeDropdown:SetValue("ALL")
    typeDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.txType = value
        if onChange then onChange() end
    end)
    container:AddChild(typeDropdown)

    -- Hide moves checkbox
    local hideMovesCB = AceGUI:Create("CheckBox")
    hideMovesCB:SetLabel("Hide moves")
    hideMovesCB:SetWidth(110)
    hideMovesCB:SetValue(filters.hideMoves)
    hideMovesCB:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.hideMoves = value
        if onChange then onChange() end
    end)
    container:AddChild(hideMovesCB)

    -- Reset button
    local resetBtn = AceGUI:Create("Button")
    resetBtn:SetText("Reset Filters")
    resetBtn:SetWidth(100)
    resetBtn:SetCallback("OnClick", function()
        local defaults = GBL:CreateDefaultFilters()
        for k, v in pairs(defaults) do
            filters[k] = v
        end
        searchBox:SetText("")
        dateDropdown:SetValue("30d")
        catDropdown:SetValue("ALL")
        typeDropdown:SetValue("ALL")
        hideMovesCB:SetValue(defaults.hideMoves)
        if onChange then onChange() end
    end)
    container:AddChild(resetBtn)
end

------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------

--- Set up the minimap button via LibDataBroker + LibDBIcon.
function GBL:SetupMinimapButton()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub("LibDBIcon-1.0", true)
    if not LDB or not LDBIcon then return end

    local dataObj = LDB:NewDataObject("GuildBankLedger", {
        type = "launcher",
        icon = "Interface\\Icons\\INV_Misc_Bag_10",
        OnClick = function(_, button)
            if button == "LeftButton" then
                GBL:ToggleMainFrame()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("GuildBankLedger")
            tooltip:AddLine("|cff999999Left-click:|r Toggle ledger window")
            tooltip:AddLine("|cff999999Right-click:|r Options")
        end,
    })

    LDBIcon:Register("GuildBankLedger", dataObj, self.db.profile.minimap)
end
