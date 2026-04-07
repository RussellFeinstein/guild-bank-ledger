------------------------------------------------------------------------
-- GuildBankLedger — UI/LedgerView.lua
-- Scrolling transaction list with sortable columns and virtual scroll.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Column definitions
------------------------------------------------------------------------

GBL.LEDGER_COLUMNS = {
    { key = "timestamp", label = "Timestamp",  width = 140 },
    { key = "player",    label = "Player",     width = 100 },
    { key = "type",      label = "Action",     width = 80  },
    { key = "itemLink",  label = "Item",       width = 200 },
    { key = "count",     label = "Count",      width = 50  },
    { key = "category",  label = "Category",   width = 100 },
    { key = "tab",       label = "Tab",        width = 50  },
}

------------------------------------------------------------------------
-- Sorting
------------------------------------------------------------------------

--- Sort transactions by a column key.
-- @param transactions table array of transaction records
-- @param column string column key from LEDGER_COLUMNS
-- @param ascending boolean sort direction
-- @return table sorted array (in-place)
function GBL:SortTransactions(transactions, column, ascending)
    if not transactions or #transactions == 0 then return transactions end

    table.sort(transactions, function(a, b)
        local av = a[column]
        local bv = b[column]

        -- Nil handling
        if av == nil and bv == nil then return false end
        if av == nil then return ascending end
        if bv == nil then return not ascending end

        -- String comparison
        if type(av) == "string" and type(bv) == "string" then
            if ascending then
                return av:lower() < bv:lower()
            else
                return av:lower() > bv:lower()
            end
        end

        -- Numeric comparison
        if ascending then
            return av < bv
        else
            return av > bv
        end
    end)

    return transactions
end

------------------------------------------------------------------------
-- Ledger view state
------------------------------------------------------------------------

-- Sorting state (managed per-session)
GBL.ledgerSortColumn = "timestamp"
GBL.ledgerSortAscending = false  -- newest first by default

--- Toggle sort on a column. If same column, flip direction. If new column, ascending.
-- @param column string column key
function GBL:SetLedgerSort(column)
    if self.ledgerSortColumn == column then
        self.ledgerSortAscending = not self.ledgerSortAscending
    else
        self.ledgerSortColumn = column
        self.ledgerSortAscending = true
    end
end

--- Get the sort indicator text for a column header.
-- @param column string column key
-- @return string the column label with sort arrow, or just the label
function GBL:GetSortIndicator(column, label)
    if self.ledgerSortColumn ~= column then
        return label
    end
    if self.ledgerSortAscending then
        return label .. " [asc]"
    else
        return label .. " [desc]"
    end
end

------------------------------------------------------------------------
-- Ledger view rendering (AceGUI)
------------------------------------------------------------------------

--- Create the ledger view (transaction list) inside a container.
-- @param container AceGUI container widget
-- @param transactions table array of transaction records
-- @param filters table current filter criteria
function GBL:CreateLedgerView(container, transactions, filters)
    container:ReleaseChildren()

    -- Apply filters and sort
    local filtered = self:FilterTransactions(transactions or {}, filters)
    self:SortTransactions(filtered, self.ledgerSortColumn, self.ledgerSortAscending)

    -- Status line
    local status = LibStub("AceGUI-3.0"):Create("Label")
    status:SetFullWidth(true)
    status:SetText(#filtered .. " transactions")
    container:AddChild(status)

    -- Column headers
    local headerGroup = LibStub("AceGUI-3.0"):Create("SimpleGroup")
    headerGroup:SetFullWidth(true)
    headerGroup:SetLayout("Flow")
    container:AddChild(headerGroup)

    for _, col in ipairs(self.LEDGER_COLUMNS) do
        local btn = LibStub("AceGUI-3.0"):Create("InteractiveLabel")
        btn:SetWidth(col.width)
        btn:SetText(self:GetSortIndicator(col.key, col.label))
        btn:SetCallback("OnClick", function()
            self:SetLedgerSort(col.key)
            self:RefreshLedgerView()
        end)
        headerGroup:AddChild(btn)
    end

    -- Empty state
    if #filtered == 0 then
        local emptyLabel = LibStub("AceGUI-3.0"):Create("Label")
        emptyLabel:SetFullWidth(true)
        emptyLabel:SetText(
            (#(transactions or {}) == 0)
                and "No transactions recorded yet. Open your guild bank to start scanning."
                or "No transactions match your filters."
        )
        container:AddChild(emptyLabel)
        return
    end

    -- Transaction rows (ScrollFrame parent handles scrolling)
    local rowCount = #filtered

    for i = 1, rowCount do
        local tx = filtered[i]
        local rowGroup = LibStub("AceGUI-3.0"):Create("SimpleGroup")
        rowGroup:SetFullWidth(true)
        rowGroup:SetLayout("Flow")
        container:AddChild(rowGroup)

        -- Timestamp
        local tsLabel = LibStub("AceGUI-3.0"):Create("Label")
        tsLabel:SetWidth(self.LEDGER_COLUMNS[1].width)
        tsLabel:SetText(self:FormatTimestamp(tx.timestamp))
        rowGroup:AddChild(tsLabel)

        -- Player
        local playerLabel = LibStub("AceGUI-3.0"):Create("Label")
        playerLabel:SetWidth(self.LEDGER_COLUMNS[2].width)
        playerLabel:SetText(tx.player or "Unknown")
        rowGroup:AddChild(playerLabel)

        -- Action (with triple encoding)
        local display = self:GetTxTypeDisplay(tx.type)
        local actionLabel = LibStub("AceGUI-3.0"):Create("Label")
        actionLabel:SetWidth(self.LEDGER_COLUMNS[3].width)
        actionLabel:SetText(display.label)
        rowGroup:AddChild(actionLabel)

        -- Item
        local itemLabel = LibStub("AceGUI-3.0"):Create("Label")
        itemLabel:SetWidth(self.LEDGER_COLUMNS[4].width)
        itemLabel:SetText(tx.itemLink or "")
        rowGroup:AddChild(itemLabel)

        -- Count
        local countLabel = LibStub("AceGUI-3.0"):Create("Label")
        countLabel:SetWidth(self.LEDGER_COLUMNS[5].width)
        countLabel:SetText(tostring(tx.count or 0))
        rowGroup:AddChild(countLabel)

        -- Category
        local catLabel = LibStub("AceGUI-3.0"):Create("Label")
        catLabel:SetWidth(self.LEDGER_COLUMNS[6].width)
        catLabel:SetText(tx.category or "")
        rowGroup:AddChild(catLabel)

        -- Tab
        local tabLabel = LibStub("AceGUI-3.0"):Create("Label")
        tabLabel:SetWidth(self.LEDGER_COLUMNS[7].width)
        tabLabel:SetText(tostring(tx.tab or ""))
        rowGroup:AddChild(tabLabel)
    end

    -- Store filtered data for refresh
    self._ledgerFiltered = filtered
end

--- Refresh the ledger view with current data and filters.
function GBL:RefreshLedgerView()
    if self._ledgerContainer and self._ledgerTransactions then
        self:CreateLedgerView(
            self._ledgerContainer,
            self._ledgerTransactions,
            self._ledgerFilters
        )
    end
end
