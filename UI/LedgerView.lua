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
    { key = "timestamp", label = "Timestamp",  width = 145 },
    { key = "player",    label = "Player",     width = 110 },
    { key = "type",      label = "Action",     width = 100 },
    { key = "itemLink",  label = "Item",       width = 220 },
    { key = "count",     label = "Count",      width = 55  },
    { key = "category",  label = "Category",   width = 100 },
    { key = "tab",       label = "Location",   width = 130 },
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

-- Pagination: rows rendered per page
GBL.LEDGER_PAGE_SIZE = 100

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

--- Get the visible columns based on current filters.
-- Hides the Location column when moves are hidden.
-- @param filters table current filter criteria
-- @return table array of column definitions to render
function GBL:GetVisibleColumns(filters)
    local cols = {}
    for _, col in ipairs(self.LEDGER_COLUMNS) do
        local hide = col.key == "tab" and filters and filters.hideMoves
        if not hide then
            cols[#cols + 1] = col
        end
    end
    return cols
end

--- Create the ledger view (transaction list) inside a container.
-- @param container AceGUI container widget
-- @param transactions table array of transaction records
-- @param filters table current filter criteria
function GBL:CreateLedgerView(container, transactions, filters)
    container:ReleaseChildren()

    local AceGUI = LibStub("AceGUI-3.0")

    -- Apply filters and sort
    local filtered = self:FilterTransactions(transactions or {}, filters)
    self:SortTransactions(filtered, self.ledgerSortColumn, self.ledgerSortAscending)

    local visibleCols = self:GetVisibleColumns(filters)

    -- Pagination
    local pageSize = self.LEDGER_PAGE_SIZE
    local totalPages = math.max(1, math.ceil(#filtered / pageSize))
    local currentPage = math.min(self._ledgerCurrentPage or 1, totalPages)
    self._ledgerCurrentPage = currentPage
    local startIdx = (currentPage - 1) * pageSize + 1
    local endIdx = math.min(currentPage * pageSize, #filtered)

    -- Status line
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    if #filtered > pageSize then
        status:SetText("Showing " .. startIdx .. "-" .. endIdx .. " of " .. #filtered .. " transactions")
    else
        status:SetText(#filtered .. " transactions")
    end
    container:AddChild(status)

    -- Column headers
    local headerGroup = AceGUI:Create("SimpleGroup")
    headerGroup:SetFullWidth(true)
    headerGroup:SetLayout("Flow")
    container:AddChild(headerGroup)

    for _, col in ipairs(visibleCols) do
        local btn = AceGUI:Create("InteractiveLabel")
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
        local emptyLabel = AceGUI:Create("Label")
        emptyLabel:SetFullWidth(true)
        emptyLabel:SetText(
            (#(transactions or {}) == 0)
                and "No transactions recorded yet. Open your guild bank to start scanning."
                or "No transactions match your filters."
        )
        container:AddChild(emptyLabel)
        return
    end

    -- Column value getters
    local function getCellText(tx, col)
        if col.key == "timestamp" then
            return self:FormatTimestamp(tx.timestamp)
        elseif col.key == "player" then
            return tx.player or "Unknown"
        elseif col.key == "type" then
            return self:GetTxTypeDisplay(tx.type).label
        elseif col.key == "itemLink" then
            return tx.itemLink or ""
        elseif col.key == "count" then
            return tostring(tx.count or 0)
        elseif col.key == "category" then
            return tx.category or ""
        elseif col.key == "tab" then
            local tabText = tx.tabName or tostring(tx.tab or "")
            if tx.type == "move" then
                local destText = tx.destTabName or tostring(tx.destTab or "")
                tabText = tabText .. ">" .. destText
            end
            return tabText
        end
        return ""
    end

    -- Transaction rows (current page only)
    for i = startIdx, endIdx do
        local tx = filtered[i]
        local rowGroup = AceGUI:Create("SimpleGroup")
        rowGroup:SetFullWidth(true)
        rowGroup:SetLayout("Flow")
        container:AddChild(rowGroup)

        for _, col in ipairs(visibleCols) do
            local lbl = AceGUI:Create("Label")
            lbl:SetWidth(col.width)
            lbl:SetText(getCellText(tx, col))
            rowGroup:AddChild(lbl)
        end
    end

    -- TODO: Pagination controls not rendering in AceGUI ScrollFrame — fix layout
    -- Page data is capped to 100 rows; controls needed to navigate pages.

    -- Store filtered data for refresh
    self._ledgerFiltered = filtered
end

--- Refresh the ledger view with current data and filters.
function GBL:RefreshLedgerView()
    if self._ledgerContainer and self._ledgerTransactions then
        self._ledgerCurrentPage = 1  -- reset pagination on refresh
        self:CreateLedgerView(
            self._ledgerContainer,
            self._ledgerTransactions,
            self._ledgerFilters
        )
    end
end
