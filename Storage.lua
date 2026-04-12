------------------------------------------------------------------------
-- GuildBankLedger — Storage.lua
-- Tiered storage, compaction, and pruning
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Compaction thresholds (seconds)
local DAILY_AGE = 30 * 86400   -- 30 days
local WEEKLY_AGE = 90 * 86400  -- 90 days

------------------------------------------------------------------------
-- Date key helpers
------------------------------------------------------------------------

--- Get a daily key ("YYYY-MM-DD") for a Unix timestamp.
-- @param timestamp number Unix timestamp
-- @return string Date key in UTC
function GBL:GetDateKey(timestamp)
    return os.date("!%Y-%m-%d", timestamp)
end

--- Get an ISO week key ("YYYY-Wxx") for a Unix timestamp.
-- Manual calculation because Lua 5.1 %V is unreliable in WoW.
-- @param timestamp number Unix timestamp
-- @return string Week key in UTC
function GBL:GetWeekKey(timestamp)
    -- Get the date components in UTC
    local d = os.date("!*t", timestamp)

    -- ISO 8601 week calculation:
    -- Week 1 is the week containing the first Thursday of January.
    -- Days are Mon=1..Sun=7 (Lua wday: Sun=1..Sat=7, so convert)
    local wday = d.wday - 1
    if wday == 0 then wday = 7 end  -- Sunday = 7

    -- Find the Thursday of this week
    local thursdayOffset = 4 - wday
    local thursdayTime = timestamp + thursdayOffset * 86400
    local thursdayDate = os.date("!*t", thursdayTime)

    -- Week number = how many weeks into the year Thursday falls
    -- Use yday from os.date("!*t") to avoid local/UTC timezone mismatch
    local weekNum = math.ceil(thursdayDate.yday / 7)

    return format("%04d-W%02d", thursdayDate.year, weekNum)
end

------------------------------------------------------------------------
-- Aggregation
------------------------------------------------------------------------

--- Initialize an empty daily summary.
local function newDailySummary(dateKey)
    return {
        date = dateKey,
        itemDeposits = {},
        itemWithdrawals = {},
        moneyDeposited = 0,
        moneyWithdrawn = 0,
        txCount = 0,
        players = {},
    }
end

--- Initialize an empty weekly summary.
local function newWeeklySummary(weekKey)
    return {
        week = weekKey,
        itemDeposits = {},
        itemWithdrawals = {},
        moneyDeposited = 0,
        moneyWithdrawn = 0,
        txCount = 0,
        players = {},
    }
end

--- Merge item counts from src into dest table.
local function mergeItemCounts(dest, src)
    for itemID, count in pairs(src) do
        dest[itemID] = (dest[itemID] or 0) + count
    end
end

--- Aggregate an item transaction record into a daily summary.
-- @param summary table Daily summary
-- @param record table Transaction record
function GBL:AggregateToDailySummary(summary, record)
    summary.txCount = summary.txCount + 1
    if record.player then
        summary.players[record.player] = true
    end

    if record.itemID then
        -- Item transaction
        if record.type == "deposit" then
            summary.itemDeposits[record.itemID] =
                (summary.itemDeposits[record.itemID] or 0) + (record.count or 0)
        elseif record.type == "withdraw" then
            summary.itemWithdrawals[record.itemID] =
                (summary.itemWithdrawals[record.itemID] or 0) + (record.count or 0)
        end
    end

    if record.amount then
        -- Money transaction
        if record.type == "deposit" or record.type == "depositSummary" then
            summary.moneyDeposited = summary.moneyDeposited + (record.amount or 0)
        elseif record.type == "withdraw" or record.type == "repair"
               or record.type == "buyTab" then
            summary.moneyWithdrawn = summary.moneyWithdrawn + (record.amount or 0)
        end
    end
end

--- Aggregate a daily summary into a weekly summary.
-- @param weekly table Weekly summary
-- @param daily table Daily summary
function GBL:AggregateDailyToWeekly(weekly, daily)
    weekly.txCount = weekly.txCount + daily.txCount
    mergeItemCounts(weekly.itemDeposits, daily.itemDeposits)
    mergeItemCounts(weekly.itemWithdrawals, daily.itemWithdrawals)
    weekly.moneyDeposited = weekly.moneyDeposited + daily.moneyDeposited
    weekly.moneyWithdrawn = weekly.moneyWithdrawn + daily.moneyWithdrawn
    for player in pairs(daily.players) do
        weekly.players[player] = true
    end
end

------------------------------------------------------------------------
-- Compaction
------------------------------------------------------------------------

--- Compact item transactions older than 30 days into daily summaries.
-- Uses forward pass with new array (O(n), not in-place reverse removal).
-- @param guildData table Guild data from AceDB
function GBL:CompactToDailySummaries(guildData)
    if not guildData then return end

    local cutoff = GetServerTime() - DAILY_AGE
    local kept = {}

    for _, record in ipairs(guildData.transactions) do
        if record.timestamp >= cutoff then
            table.insert(kept, record)
        else
            local dateKey = self:GetDateKey(record.timestamp)
            if not guildData.dailySummaries[dateKey] then
                guildData.dailySummaries[dateKey] = newDailySummary(dateKey)
            end
            self:AggregateToDailySummary(guildData.dailySummaries[dateKey], record)
        end
    end
    guildData.transactions = kept

    -- Also compact money transactions
    local keptMoney = {}
    for _, record in ipairs(guildData.moneyTransactions) do
        if record.timestamp >= cutoff then
            table.insert(keptMoney, record)
        else
            local dateKey = self:GetDateKey(record.timestamp)
            if not guildData.dailySummaries[dateKey] then
                guildData.dailySummaries[dateKey] = newDailySummary(dateKey)
            end
            self:AggregateToDailySummary(guildData.dailySummaries[dateKey], record)
        end
    end
    guildData.moneyTransactions = keptMoney
end

--- Compact daily summaries older than 90 days into weekly summaries.
-- @param guildData table Guild data from AceDB
function GBL:CompactToWeeklySummaries(guildData)
    if not guildData then return end

    local cutoff = GetServerTime() - WEEKLY_AGE

    for dateKey, daily in pairs(guildData.dailySummaries) do
        -- Parse the date key back to a timestamp for age comparison
        local y, m, d = dateKey:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(m),
                                 day = tonumber(d), hour = 0 })
            if ts < cutoff then
                local weekKey = self:GetWeekKey(ts)
                if not guildData.weeklySummaries[weekKey] then
                    guildData.weeklySummaries[weekKey] = newWeeklySummary(weekKey)
                end
                self:AggregateDailyToWeekly(guildData.weeklySummaries[weekKey], daily)
                guildData.dailySummaries[dateKey] = nil
            end
        end
    end
end

--- Run full compaction cycle: daily, weekly, and hash pruning.
-- Guarded against running while a scan is in progress.
-- @param guildData table Guild data from AceDB
function GBL:RunCompaction(guildData)
    if not guildData then return end
    if self.scanInProgress then return end
    if self._syncReceiving then return end

    self:CompactToDailySummaries(guildData)
    self:CompactToWeeklySummaries(guildData)
    self:PruneSeenHashes(90, guildData)
end

------------------------------------------------------------------------
-- Statistics and maintenance
------------------------------------------------------------------------

--- Count keys in a table (for hash-keyed tables like summaries).
local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Get record counts per storage tier.
-- @param guildData table Guild data from AceDB
-- @return table { transactions, moneyTransactions, dailySummaries, weeklySummaries, seenHashes }
function GBL:GetStorageStats(guildData)
    if not guildData then
        return { transactions = 0, moneyTransactions = 0,
                 dailySummaries = 0, weeklySummaries = 0, seenHashes = 0 }
    end
    return {
        transactions = #guildData.transactions,
        moneyTransactions = #guildData.moneyTransactions,
        dailySummaries = countKeys(guildData.dailySummaries),
        weeklySummaries = countKeys(guildData.weeklySummaries),
        seenHashes = countKeys(guildData.seenTxHashes),
    }
end

--- Estimate storage size in bytes (rough approximation).
-- @param guildData table Guild data from AceDB
-- @return number Estimated bytes
function GBL:EstimateStorageSize(guildData)
    if not guildData then return 0 end
    local stats = self:GetStorageStats(guildData)
    return stats.transactions * 200
         + stats.moneyTransactions * 150
         + stats.dailySummaries * 300
         + stats.weeklySummaries * 400
         + stats.seenHashes * 60
end

--- Purge all data older than daysToKeep.
-- Destructive operation for manual use (e.g. /gbl purge).
-- @param daysToKeep number Keep data newer than this many days
-- @param guildData table Guild data from AceDB
function GBL:PurgeOldData(daysToKeep, guildData)
    if not guildData or not daysToKeep then return end

    local cutoff = GetServerTime() - (daysToKeep * 86400)

    -- Purge full transactions
    local kept = {}
    for _, rec in ipairs(guildData.transactions) do
        if rec.timestamp >= cutoff then
            table.insert(kept, rec)
        end
    end
    guildData.transactions = kept

    -- Purge money transactions
    local keptMoney = {}
    for _, rec in ipairs(guildData.moneyTransactions) do
        if rec.timestamp >= cutoff then
            table.insert(keptMoney, rec)
        end
    end
    guildData.moneyTransactions = keptMoney

    -- Purge daily summaries
    for dateKey in pairs(guildData.dailySummaries) do
        local y, m, d = dateKey:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(m),
                                 day = tonumber(d), hour = 0 })
            if ts < cutoff then
                guildData.dailySummaries[dateKey] = nil
            end
        end
    end

    -- Purge weekly summaries
    local cutoffDate = os.date("!*t", cutoff)
    local cutoffYear = cutoffDate.year
    local cutoffWeek = math.ceil(cutoffDate.yday / 7)
    for weekKey in pairs(guildData.weeklySummaries) do
        local y, w = weekKey:match("^(%d+)-W(%d+)$")
        if y then
            local wy = tonumber(y)
            local ww = tonumber(w)
            if wy < cutoffYear or (wy == cutoffYear and ww < cutoffWeek) then
                guildData.weeklySummaries[weekKey] = nil
            end
        end
    end

    -- Purge seen hashes
    self:PruneSeenHashes(daysToKeep, guildData)
end
