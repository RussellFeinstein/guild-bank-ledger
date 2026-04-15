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

            -- Money transactions (repair and buyTab are withdrawals from the bank)
            local amount = tx.amount or 0
            if amount > 0 then
                if tx.type == "withdraw" or tx.type == "repair" or tx.type == "buyTab" then
                    p.moneyWithdrawn = p.moneyWithdrawn + amount
                elseif tx.type == "deposit" or tx.type == "depositSummary" then
                    p.moneyDeposited = p.moneyDeposited + amount
                end
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

        -- Compute net consumed/contributed per item
        p.netConsumed = 0    -- items taken and kept
        p.netContributed = 0 -- items given more than taken
        local itemList = {}
        for itemID, counts in pairs(p.itemCounts) do
            local itemNet = counts.withdrawn - counts.deposited
            if itemNet > 0 then
                p.netConsumed = p.netConsumed + itemNet
            elseif itemNet < 0 then
                p.netContributed = p.netContributed + (-itemNet)
            end
            -- Top items by net consumption (only items actually kept)
            if itemNet > 0 then
                itemList[#itemList + 1] = {
                    itemID = itemID,
                    count = itemNet,
                    itemLink = counts.itemLink,
                }
            end
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
-- Gold log sums
------------------------------------------------------------------------

--- Compute totals for a set of money transactions, broken down by type.
-- @param filteredTransactions table array of money transaction records (already filtered)
-- @return table { totalDeposited, totalWithdrawn, net, deposit, depositSummary, withdraw, repair, buyTab } in copper
function GBL:ComputeGoldLogSums(filteredTransactions)
    local sums = {
        totalDeposited = 0, totalWithdrawn = 0, net = 0,
        deposit = 0, depositSummary = 0,
        withdraw = 0, repair = 0, buyTab = 0,
    }
    if not filteredTransactions then return sums end

    for i = 1, #filteredTransactions do
        local tx = filteredTransactions[i]
        local amount = tx.amount or 0
        if amount > 0 then
            -- Same classification as BuildConsumptionSummary (keep in sync)
            local t = tx.type
            if t == "deposit" then
                sums.deposit = sums.deposit + amount
                sums.totalDeposited = sums.totalDeposited + amount
            elseif t == "depositSummary" then
                sums.depositSummary = sums.depositSummary + amount
                sums.totalDeposited = sums.totalDeposited + amount
            elseif t == "withdraw" then
                sums.withdraw = sums.withdraw + amount
                sums.totalWithdrawn = sums.totalWithdrawn + amount
            elseif t == "repair" then
                sums.repair = sums.repair + amount
                sums.totalWithdrawn = sums.totalWithdrawn + amount
            elseif t == "buyTab" then
                sums.buyTab = sums.buyTab + amount
                sums.totalWithdrawn = sums.totalWithdrawn + amount
            end
        end
    end

    sums.net = sums.totalDeposited - sums.totalWithdrawn
    return sums
end

------------------------------------------------------------------------
-- Sorting
------------------------------------------------------------------------

--- Sort columns for consumption summary.
local SORT_KEYS = {
    player = "player",
    totalWithdrawn = "totalWithdrawn",
    totalDeposited = "totalDeposited",
    netConsumed = "netConsumed",
    netContributed = "netContributed",
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
-- Item name extraction
------------------------------------------------------------------------

--- Extract the display name from a WoW item link.
-- WoW links: |cff...|Hitem:...|h[Item Name]|h|r
-- @param itemLink string|nil WoW item link
-- @param itemID number|nil fallback item ID
-- @return string extracted name, or fallback
function GBL:ExtractItemName(itemLink, itemID)
    if itemLink then
        local name = itemLink:match("%[(.-)%]")
        if name and name ~= "" then
            return name
        end
        -- Strip color codes as fallback
        local stripped = itemLink:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        if stripped ~= "" then
            return stripped
        end
    end
    if itemID then
        local cachedName = self:GetCachedItemInfo(itemID)
        if cachedName then return cachedName end
        return "Item #" .. tostring(itemID)
    end
    return "Unknown Item"
end

------------------------------------------------------------------------
-- Breakdown for display
------------------------------------------------------------------------

--- Transform a raw item breakdown into a sorted display array.
-- Filters out zero-net items (fully returned) by default.
-- @param breakdown table itemID -> { withdrawn=N, deposited=N, itemLink=string }
-- @return table array of { itemID, itemName, itemLink, category, categoryDisplay, withdrawn, deposited, net }
function GBL:GetBreakdownForDisplay(breakdown)
    if not breakdown then return {} end

    local result = {}
    for itemID, data in pairs(breakdown) do
        local net = data.withdrawn - data.deposited
        -- Skip items with zero net (fully returned)
        if net ~= 0 then
            local category = self:GetItemCategory(itemID)
            result[#result + 1] = {
                itemID = itemID,
                itemName = self:ExtractItemName(data.itemLink, itemID),
                itemLink = data.itemLink,
                category = category,
                categoryDisplay = self:GetCategoryDisplayName(category),
                withdrawn = data.withdrawn,
                deposited = data.deposited,
                net = net,
                total = data.withdrawn + data.deposited,
            }
        end
    end

    -- Sort by absolute net descending (biggest consumers/contributors first)
    table.sort(result, function(a, b)
        return math.abs(a.net) > math.abs(b.net)
    end)

    return result
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

------------------------------------------------------------------------
-- Guild-wide totals
------------------------------------------------------------------------

--- Compute guild-wide totals from player summaries.
-- @param summaries table array of player summary records from BuildConsumptionSummary
-- @return table { itemsDeposited, itemsWithdrawn, itemsNet, goldDeposited, goldWithdrawn, goldNet, playerCount }
function GBL:BuildGuildTotals(summaries)
    local totals = {
        itemsDeposited = 0,
        itemsWithdrawn = 0,
        itemsNet = 0,
        goldDeposited = 0,
        goldWithdrawn = 0,
        goldNet = 0,
        playerCount = 0,
    }
    if not summaries then return totals end

    totals.playerCount = #summaries
    for i = 1, #summaries do
        local p = summaries[i]
        totals.itemsDeposited = totals.itemsDeposited + (p.totalDeposited or 0)
        totals.itemsWithdrawn = totals.itemsWithdrawn + (p.totalWithdrawn or 0)
        totals.goldDeposited = totals.goldDeposited + (p.moneyDeposited or 0)
        totals.goldWithdrawn = totals.goldWithdrawn + (p.moneyWithdrawn or 0)
    end
    totals.itemsNet = totals.itemsDeposited - totals.itemsWithdrawn
    totals.goldNet = totals.goldDeposited - totals.goldWithdrawn
    return totals
end

------------------------------------------------------------------------
-- Guild-wide item usage summary
------------------------------------------------------------------------

--- Build a guild-wide item usage summary with time-bucketed withdrawal counts.
-- Only items with at least one withdrawal are included.
-- 7d/30d buckets are computed relative to GetServerTime(), independent of date range filters.
-- @param transactions table array of transaction records
-- @param categoryFilter string|nil category to filter by, or "ALL"/nil for all
-- @return table array of { itemID, itemName, itemLink, category, categoryDisplay, usedAll, used30d, used7d }
function GBL:BuildGuildItemSummary(transactions, categoryFilter)
    if not transactions then return {} end

    local now = GetServerTime()
    local cutoff7d = now - (7 * 24 * 3600)
    local cutoff30d = now - (30 * 24 * 3600)

    local byItem = {}
    for i = 1, #transactions do
        local tx = transactions[i]
        -- Only count withdrawals with an itemID
        if tx.itemID and tx.type == "withdraw" then
            -- Apply category filter if specified
            if not categoryFilter or categoryFilter == "ALL" or tx.category == categoryFilter then
                local itemID = tx.itemID
                if not byItem[itemID] then
                    byItem[itemID] = {
                        itemID = itemID,
                        itemLink = tx.itemLink,
                        usedAll = 0,
                        used30d = 0,
                        used7d = 0,
                    }
                end
                local item = byItem[itemID]
                local count = tx.count or 0
                local ts = tx.timestamp or 0

                item.usedAll = item.usedAll + count
                if ts >= cutoff30d then
                    item.used30d = item.used30d + count
                end
                if ts >= cutoff7d then
                    item.used7d = item.used7d + count
                end

                -- Keep the most recent itemLink
                if tx.itemLink then
                    item.itemLink = tx.itemLink
                end
            end
        end
    end

    -- Build result array
    local result = {}
    for _, item in pairs(byItem) do
        item.itemName = self:ExtractItemName(item.itemLink, item.itemID)
        item.category = self:GetItemCategory(item.itemID)
        item.categoryDisplay = self:GetCategoryDisplayName(item.category)
        result[#result + 1] = item
    end

    -- Sort by usedAll descending
    table.sort(result, function(a, b) return a.usedAll > b.usedAll end)

    return result
end
