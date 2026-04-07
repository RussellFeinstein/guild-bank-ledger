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
    frame:SetWidth(self.db.profile.ui.width or 800)
    frame:SetHeight(self.db.profile.ui.height or 600)
    frame:SetLayout("Fill")
    frame:SetCallback("OnClose", function(widget)
        widget:Hide()
    end)
    frame:Hide()

    -- Tab group
    local tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("List")
    tabGroup:SetTabs({
        { value = "transactions", text = "Transactions" },
        { value = "consumption", text = "Consumption" },
    })
    tabGroup:SetCallback("OnGroupSelected", function(_widget, _event, group)
        self:SelectTab(group)
    end)
    frame:AddChild(tabGroup)

    self.mainFrame = frame
    self.tabGroup = tabGroup
    self.activeTab = "transactions"
end

--- Toggle the main frame visibility.
function GBL:ToggleMainFrame()
    self:CreateMainFrame()

    if self.mainFrame._shown then
        self.mainFrame:Hide()
    else
        self.mainFrame:Show()
        self:RefreshUI()
    end
end

--- Refresh the active tab's content.
function GBL:RefreshUI()
    if not self.tabGroup then return end
    self.tabGroup:SelectTab(self.activeTab or "transactions")
end

--- Switch between tabs.
-- @param tabName string "transactions" or "consumption"
function GBL:SelectTab(tabName)
    if not self.tabGroup then return end
    self.activeTab = tabName
    self.tabGroup:ReleaseChildren()

    local guildData = self:GetGuildData()
    local transactions = guildData and guildData.transactions or {}

    if tabName == "transactions" then
        self:BuildTransactionsTab(self.tabGroup, transactions)
    elseif tabName == "consumption" then
        self:BuildConsumptionTab(self.tabGroup, transactions)
    end
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

    -- Create filter widgets (references ledgerGroup via closure)
    self:CreateFilterWidgets(filterGroup, filters, function()
        self:CreateLedgerView(ledgerGroup, transactions, filters)
    end)

    container:AddChild(ledgerGroup)

    -- Store references for refresh
    self._ledgerContainer = ledgerGroup
    self._ledgerTransactions = transactions
    self._ledgerFilters = filters

    self:CreateLedgerView(ledgerGroup, transactions, filters)
end

------------------------------------------------------------------------
-- Consumption tab
------------------------------------------------------------------------

function GBL:BuildConsumptionTab(container, transactions)
    local AceGUI = LibStub("AceGUI-3.0")

    -- Date range filter only for consumption
    local filterGroup = AceGUI:Create("SimpleGroup")
    filterGroup:SetFullWidth(true)
    filterGroup:SetLayout("Flow")
    container:AddChild(filterGroup)

    -- Content area (ScrollFrame for scrollable consumption list)
    local contentGroup = AceGUI:Create("ScrollFrame")

    local filters = self:CreateDefaultFilters()

    -- Date dropdown
    local dateDropdown = AceGUI:Create("Dropdown")
    dateDropdown:SetLabel("Date Range")
    dateDropdown:SetWidth(120)
    dateDropdown:SetList({
        ["all"] = "All Time",
        ["7d"] = "Last 7 Days",
        ["30d"] = "Last 30 Days",
    })
    dateDropdown:SetValue("all")
    dateDropdown:SetCallback("OnValueChanged", function(_widget, _event, value)
        filters.dateRange = value
        self:RenderConsumptionTable(contentGroup, transactions, filters)
    end)
    filterGroup:AddChild(dateDropdown)
    contentGroup:SetFullWidth(true)
    contentGroup:SetFullHeight(true)
    contentGroup:SetLayout("Flow")
    container:AddChild(contentGroup)

    self:RenderConsumptionTable(contentGroup, transactions, filters)
end

--- Render the consumption summary table.
function GBL:RenderConsumptionTable(container, transactions, filters)
    container:ReleaseChildren()

    local AceGUI = LibStub("AceGUI-3.0")
    local summaries = self:BuildConsumptionSummary(transactions, filters)
    self:SortConsumptionSummary(summaries, "totalWithdrawn", false)

    if #summaries == 0 then
        local emptyLabel = AceGUI:Create("Label")
        emptyLabel:SetFullWidth(true)
        emptyLabel:SetText("No consumption data available.")
        container:AddChild(emptyLabel)
        return
    end

    -- Header row
    local headerGroup = AceGUI:Create("SimpleGroup")
    headerGroup:SetFullWidth(true)
    headerGroup:SetLayout("Flow")
    container:AddChild(headerGroup)

    local headers = {
        { label = "Player",     width = 120 },
        { label = "Withdrawn",  width = 80 },
        { label = "Deposited",  width = 80 },
        { label = "Net",        width = 80 },
        { label = "Last Active", width = 140 },
    }
    for _, h in ipairs(headers) do
        local lbl = AceGUI:Create("Label")
        lbl:SetWidth(h.width)
        lbl:SetText("|cffffcc00" .. h.label .. "|r")
        headerGroup:AddChild(lbl)
    end

    -- Data rows
    for _, p in ipairs(summaries) do
        local rowGroup = AceGUI:Create("SimpleGroup")
        rowGroup:SetFullWidth(true)
        rowGroup:SetLayout("Flow")
        container:AddChild(rowGroup)

        -- Player
        local playerLabel = AceGUI:Create("Label")
        playerLabel:SetWidth(120)
        playerLabel:SetText(p.player)
        rowGroup:AddChild(playerLabel)

        -- Withdrawn
        local wLabel = AceGUI:Create("Label")
        wLabel:SetWidth(80)
        wLabel:SetText(tostring(p.totalWithdrawn))
        rowGroup:AddChild(wLabel)

        -- Deposited
        local dLabel = AceGUI:Create("Label")
        dLabel:SetWidth(80)
        dLabel:SetText(tostring(p.totalDeposited))
        rowGroup:AddChild(dLabel)

        -- Net (with sign indicator)
        local netLabel = AceGUI:Create("Label")
        netLabel:SetWidth(80)
        local netStr = p.net > 0 and ("+" .. p.net) or tostring(p.net)
        netLabel:SetText(netStr)
        rowGroup:AddChild(netLabel)

        -- Last Active
        local laLabel = AceGUI:Create("Label")
        laLabel:SetWidth(140)
        laLabel:SetText(self:FormatTimestamp(p.lastActive))
        rowGroup:AddChild(laLabel)
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

    -- Search box
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search")
    searchBox:SetWidth(150)
    searchBox:SetText("")
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
        ["all"] = "All Time",
        ["7d"] = "Last 7 Days",
        ["30d"] = "Last 30 Days",
    })
    dateDropdown:SetValue("all")
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
        dateDropdown:SetValue("all")
        catDropdown:SetValue("ALL")
        typeDropdown:SetValue("ALL")
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
