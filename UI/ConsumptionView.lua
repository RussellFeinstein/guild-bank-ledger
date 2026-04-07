------------------------------------------------------------------------
-- GuildBankLedger — UI/ConsumptionView.lua
-- Per-player consumption aggregation logic (pure data layer).
-- Rendering layer is added in a later commit.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Money formatting
------------------------------------------------------------------------

--- Format a copper amount as "Xg Ys Zc".
-- @param copper number amount in copper
-- @return string formatted money string
function GBL:FormatMoney(copper)
    if not copper or copper == 0 then
        return "0c"
    end

    local negative = copper < 0
    if negative then copper = -copper end

    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local copperRem = copper % 100

    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = gold .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    if copperRem > 0 or #parts == 0 then
        parts[#parts + 1] = copperRem .. "c"
    end

    local result = table.concat(parts, " ")
    if negative then
        result = "-" .. result
    end
    return result
end

------------------------------------------------------------------------
-- Consumption aggregation
------------------------------------------------------------------------

--- Build a per-player consumption summary from transactions.
-- @param transactions table array of transaction records
-- @param filters table|nil optional filter criteria (applied before aggregation)
-- @return table array of player summary records
function GBL:BuildConsumptionSummary(transactions, filters)
    if not transactions then return {} end

    -- Apply filters if given
    local txns = transactions
    if filters then
        txns = self:FilterTransactions(transactions, filters)
    end

    -- Aggregate by player
    local byPlayer = {}
    for i = 1, #txns do
        local tx = txns[i]
        local name = tx.player
        if name then
            if not byPlayer[name] then
                byPlayer[name] = {
                    player = name,
                    totalWithdrawn = 0,
                    totalDeposited = 0,
                    net = 0,
                    moneyWithdrawn = 0,
                    moneyDeposited = 0,
                    moneyNet = 0,
                    lastActive = 0,
                    itemCounts = {},  -- itemID -> { withdrawn=N, deposited=N }
                }
            end
            local p = byPlayer[name]

            -- Track timestamps
            if tx.timestamp and tx.timestamp > p.lastActive then
                p.lastActive = tx.timestamp
            end

            -- Item transactions
            local count = tx.count or 0
            if tx.type == "withdraw" then
                p.totalWithdrawn = p.totalWithdrawn + count
            elseif tx.type == "deposit" then
                p.totalDeposited = p.totalDeposited + count
            end

            -- Money transactions
            local amount = tx.amount or 0
            if tx.type == "withdraw" and amount > 0 then
                p.moneyWithdrawn = p.moneyWithdrawn + amount
            elseif tx.type == "deposit" and amount > 0 then
                p.moneyDeposited = p.moneyDeposited + amount
            end

            -- Per-item tracking (for top items and breakdown)
            local itemID = tx.itemID
            if itemID then
                if not p.itemCounts[itemID] then
                    p.itemCounts[itemID] = {
                        withdrawn = 0,
                        deposited = 0,
                        itemLink = tx.itemLink,
                    }
                end
                if tx.type == "withdraw" then
                    p.itemCounts[itemID].withdrawn = p.itemCounts[itemID].withdrawn + count
                elseif tx.type == "deposit" then
                    p.itemCounts[itemID].deposited = p.itemCounts[itemID].deposited + count
                end
            end
        end
    end

    -- Build result array with computed fields
    local result = {}
    for _, p in pairs(byPlayer) do
        p.net = p.totalDeposited - p.totalWithdrawn
        p.moneyNet = p.moneyDeposited - p.moneyWithdrawn

        -- Top 3 items by total activity (withdrawn + deposited)
        local itemList = {}
        for itemID, counts in pairs(p.itemCounts) do
            itemList[#itemList + 1] = {
                itemID = itemID,
                count = counts.withdrawn + counts.deposited,
                itemLink = counts.itemLink,
            }
        end
        table.sort(itemList, function(a, b) return a.count > b.count end)
        p.topItems = {}
        for j = 1, math.min(3, #itemList) do
            p.topItems[j] = itemList[j]
        end

        result[#result + 1] = p
    end

    return result
end

------------------------------------------------------------------------
-- Sorting
------------------------------------------------------------------------

--- Sort columns for consumption summary.
local SORT_KEYS = {
    player = "player",
    totalWithdrawn = "totalWithdrawn",
    totalDeposited = "totalDeposited",
    net = "net",
    lastActive = "lastActive",
    moneyWithdrawn = "moneyWithdrawn",
    moneyDeposited = "moneyDeposited",
    moneyNet = "moneyNet",
}

--- Sort a consumption summary array by a column.
-- @param summaries table array of player summary records
-- @param column string sort column key
-- @param ascending boolean true for ascending, false for descending
-- @return table the same array, sorted in place
function GBL:SortConsumptionSummary(summaries, column, ascending)
    if not summaries or #summaries == 0 then return summaries end

    local key = SORT_KEYS[column] or "player"

    table.sort(summaries, function(a, b)
        local av, bv = a[key], b[key]
        -- Handle string comparison for player name
        if type(av) == "string" and type(bv) == "string" then
            if ascending then
                return av:lower() < bv:lower()
            else
                return av:lower() > bv:lower()
            end
        end
        -- Numeric comparison
        if ascending then
            return (av or 0) < (bv or 0)
        else
            return (av or 0) > (bv or 0)
        end
    end)

    return summaries
end

------------------------------------------------------------------------
-- Per-player item breakdown
------------------------------------------------------------------------

--- Get a per-item breakdown for a specific player.
-- @param transactions table array of transaction records
-- @param playerName string the player to filter for
-- @param filters table|nil optional additional filters
-- @return table itemID -> { withdrawn=N, deposited=N, itemLink=string }
function GBL:GetPlayerItemBreakdown(transactions, playerName, filters)
    if not transactions or not playerName then return {} end

    local txns = transactions
    if filters then
        txns = self:FilterTransactions(transactions, filters)
    end

    local breakdown = {}
    for i = 1, #txns do
        local tx = txns[i]
        if tx.player == playerName and tx.itemID then
            local itemID = tx.itemID
            if not breakdown[itemID] then
                breakdown[itemID] = {
                    withdrawn = 0,
                    deposited = 0,
                    itemLink = tx.itemLink,
                }
            end
            local count = tx.count or 0
            if tx.type == "withdraw" then
                breakdown[itemID].withdrawn = breakdown[itemID].withdrawn + count
            elseif tx.type == "deposit" then
                breakdown[itemID].deposited = breakdown[itemID].deposited + count
            end
        end
    end

    return breakdown
end
