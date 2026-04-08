------------------------------------------------------------------------
-- GuildBankLedger — UI/FilterBar.lua
-- Transaction filter logic (pure data layer).
-- Widget creation for the filter bar is added in a later commit.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Default filter criteria
------------------------------------------------------------------------

--- Create a default filter criteria table.
-- All filters are in their "pass everything" state.
-- @return table filter criteria
function GBL:CreateDefaultFilters()
    return {
        searchText = "",           -- substring match on player or itemLink
        dateRange  = "30d",        -- "1h", "3h", "1d", "7d", "30d", "all"
        customStartTime = nil,     -- number or nil (only when dateRange == "custom")
        customEndTime   = nil,     -- number or nil
        category   = "ALL",        -- "ALL" or a category key
        txType     = "ALL",        -- "ALL", "withdraw", "deposit", "move"
        player     = "ALL",        -- "ALL" or a player name
        tab        = 0,            -- 0 = all tabs, or a specific tab number
        hideMoves  = true,         -- hide move transactions by default
    }
end

------------------------------------------------------------------------
-- Filter matching
------------------------------------------------------------------------

--- Check whether a single transaction record matches all filter criteria.
-- All criteria are AND-combined.
-- @param record table transaction record
-- @param filters table filter criteria from CreateDefaultFilters
-- @return boolean true if the record passes all filters
function GBL:MatchesFilters(record, filters)
    if not record or not filters then
        return false
    end

    -- Money transactions (no itemID) skip item-specific filters
    local isMoneyTx = not record.itemID

    -- Search text (case-insensitive substring against player or itemLink)
    if filters.searchText and filters.searchText ~= "" then
        local needle = filters.searchText:lower()
        local playerMatch = record.player and record.player:lower():find(needle, 1, true)
        local itemMatch = record.itemLink and record.itemLink:lower():find(needle, 1, true)
        -- Money tx: match on player name only (no itemLink)
        if not playerMatch and not itemMatch then
            return false
        end
    end

    -- Date range
    if filters.dateRange and filters.dateRange ~= "all" then
        local now = GetServerTime()
        local cutoff

        if filters.dateRange == "1h" then
            cutoff = now - 3600
        elseif filters.dateRange == "3h" then
            cutoff = now - (3 * 3600)
        elseif filters.dateRange == "1d" then
            cutoff = now - (24 * 3600)
        elseif filters.dateRange == "7d" then
            cutoff = now - (7 * 24 * 3600)
        elseif filters.dateRange == "30d" then
            cutoff = now - (30 * 24 * 3600)
        elseif filters.dateRange == "custom" then
            local startTime = filters.customStartTime
            local endTime = filters.customEndTime
            -- Swap if start > end
            if startTime and endTime and startTime > endTime then
                startTime, endTime = endTime, startTime
            end
            if startTime and record.timestamp < startTime then
                return false
            end
            if endTime and record.timestamp > endTime then
                return false
            end
            -- Custom range handled, skip cutoff check
            cutoff = nil
        end

        if cutoff and (not record.timestamp or record.timestamp < cutoff) then
            return false
        end
    end

    -- Category (skip for money transactions — they have no category)
    if not isMoneyTx and filters.category and filters.category ~= "ALL" then
        if record.category ~= filters.category then
            return false
        end
    end

    -- Transaction type
    if filters.txType and filters.txType ~= "ALL" then
        if record.type ~= filters.txType then
            return false
        end
    end

    -- Player
    if filters.player and filters.player ~= "ALL" then
        if record.player ~= filters.player then
            return false
        end
    end

    -- Tab (skip for money transactions — they have no tab)
    if not isMoneyTx and filters.tab and filters.tab ~= 0 then
        if record.tab ~= filters.tab then
            return false
        end
    end

    -- Hide moves
    if filters.hideMoves and record.type == "move" then
        return false
    end

    return true
end

------------------------------------------------------------------------
-- Bulk filtering
------------------------------------------------------------------------

--- Filter an array of transactions by criteria.
-- @param transactions table array of transaction records
-- @param filters table filter criteria
-- @return table filtered array (new table, does not mutate input)
function GBL:FilterTransactions(transactions, filters)
    if not transactions then return {} end
    if not filters then return transactions end

    local result = {}
    for i = 1, #transactions do
        if self:MatchesFilters(transactions[i], filters) then
            result[#result + 1] = transactions[i]
        end
    end
    return result
end

--- Count how many transactions match without building a result array.
-- @param transactions table array of transaction records
-- @param filters table filter criteria
-- @return number count of matching records
function GBL:CountFilterResults(transactions, filters)
    if not transactions then return 0 end
    if not filters then return #transactions end

    local count = 0
    for i = 1, #transactions do
        if self:MatchesFilters(transactions[i], filters) then
            count = count + 1
        end
    end
    return count
end

------------------------------------------------------------------------
-- Dropdown population helpers
------------------------------------------------------------------------

--- Get a sorted list of unique player names from transactions.
-- @param transactions table array of transaction records
-- @return table sorted array of player name strings
function GBL:GetUniquePlayers(transactions)
    if not transactions then return {} end

    local seen = {}
    for i = 1, #transactions do
        local name = transactions[i].player
        if name then
            seen[name] = true
        end
    end

    local result = {}
    for name in pairs(seen) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

--- Get a sorted list of unique tab numbers from transactions.
-- @param transactions table array of transaction records
-- @return table sorted array of tab numbers
function GBL:GetUniqueTabs(transactions)
    if not transactions then return {} end

    local seen = {}
    for i = 1, #transactions do
        local tab = transactions[i].tab
        if tab then
            seen[tab] = true
        end
    end

    local result = {}
    for tab in pairs(seen) do
        result[#result + 1] = tab
    end
    table.sort(result)
    return result
end
