------------------------------------------------------------------------
-- GuildBankLedger — Ledger.lua
-- Transaction recording from GetGuildBankTransaction
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Timestamp computation
------------------------------------------------------------------------

--- Convert relative time offsets from WoW API to absolute Unix timestamp.
-- GetGuildBankTransaction returns year/month/day/hour as offsets from now.
-- Uses approximate month (30d) and year (365d) — acceptable given API's
-- hour-level precision.
-- @param year number Years ago (usually 0)
-- @param month number Months ago
-- @param day number Days ago
-- @param hour number Hours ago
-- @return number Absolute Unix timestamp
function GBL:ComputeAbsoluteTimestamp(year, month, day, hour)
    local now = GetServerTime()
    local offset = (year or 0) * 31536000
                 + (month or 0) * 2592000
                 + (day or 0) * 86400
                 + (hour or 0) * 3600
    return now - offset
end

------------------------------------------------------------------------
-- Item link parsing
------------------------------------------------------------------------

--- Extract numeric itemID from a WoW item link string.
-- @param itemLink string e.g. "|cff...|Hitem:12345:...|h[Name]|h|r"
-- @return number|nil The itemID, or nil if parsing fails
function GBL:ExtractItemID(itemLink)
    if not itemLink or type(itemLink) ~= "string" then
        return nil
    end
    return tonumber(itemLink:match("item:(%d+)"))
end

------------------------------------------------------------------------
-- Record creation
------------------------------------------------------------------------

--- Build a normalized item transaction record from WoW API return values.
-- @param txType string "deposit"|"withdraw"|"move"
-- @param name string Player name
-- @param itemLink string Item link
-- @param count number Stack count
-- @param tab number Source tab
-- @param destTab number|nil Destination tab (moves only)
-- @param year number Relative year offset
-- @param month number Relative month offset
-- @param day number Relative day offset
-- @param hour number Relative hour offset
-- @return table Transaction record
function GBL:CreateTxRecord(txType, name, itemLink, count, tab, destTab, year, month, day, hour)
    local itemID = self:ExtractItemID(itemLink)

    local classID, subclassID = 0, 0
    if itemID then
        local _, _, _, _, _, cID, scID = C_Item.GetItemInfoInstant(itemID)
        classID = cID or 0
        subclassID = scID or 0
    end

    local category = self:CategorizeItem(classID, subclassID)
    local timestamp = self:ComputeAbsoluteTimestamp(year, month, day, hour)
    local scanTime = GetServerTime()
    local scannedBy = UnitName("player") or "Unknown"

    local record = {
        type = txType,
        player = name,
        itemLink = itemLink,
        itemID = itemID,
        count = count or 0,
        tab = tab,
        destTab = (txType == "move") and destTab or nil,
        classID = classID,
        subclassID = subclassID,
        category = category,
        timestamp = timestamp,
        scanTime = scanTime,
        scannedBy = scannedBy,
    }

    record.id = self:ComputeTxHash(record)
    return record
end

--- Build a normalized money transaction record.
-- @param txType string "deposit"|"withdraw"|"repair"|"buyTab"|"depositSummary"
-- @param name string Player name
-- @param amount number Copper amount
-- @param year number Relative year offset
-- @param month number Relative month offset
-- @param day number Relative day offset
-- @param hour number Relative hour offset
-- @return table Money transaction record
function GBL:CreateMoneyTxRecord(txType, name, amount, year, month, day, hour)
    local timestamp = self:ComputeAbsoluteTimestamp(year, month, day, hour)
    local scanTime = GetServerTime()
    local scannedBy = UnitName("player") or "Unknown"

    local record = {
        type = txType,
        player = name,
        amount = amount or 0,
        timestamp = timestamp,
        scanTime = scanTime,
        scannedBy = scannedBy,
    }

    record.id = self:ComputeTxHash(record)
    return record
end

------------------------------------------------------------------------
-- Storage with dedup
------------------------------------------------------------------------

--- Store an item transaction record after dedup check.
-- @param record table Transaction record from CreateTxRecord
-- @param guildData table Guild data from AceDB
-- @return boolean True if stored (not duplicate)
function GBL:StoreTx(record, guildData)
    if not guildData then return false end

    if self:IsDuplicate(record, guildData) then
        return false
    end

    self:MarkSeen(record.id, record.timestamp, guildData)
    table.insert(guildData.transactions, record)
    self:UpdatePlayerStats(record, guildData)
    return true
end

--- Store a money transaction record after dedup check.
-- @param record table Money transaction record
-- @param guildData table Guild data from AceDB
-- @return boolean True if stored (not duplicate)
function GBL:StoreMoneyTx(record, guildData)
    if not guildData then return false end

    if self:IsDuplicate(record, guildData) then
        return false
    end

    self:MarkSeen(record.id, record.timestamp, guildData)
    table.insert(guildData.moneyTransactions, record)
    self:UpdatePlayerStats(record, guildData)
    return true
end

------------------------------------------------------------------------
-- Player statistics
------------------------------------------------------------------------

--- Update per-player statistics from a transaction record.
-- @param record table Transaction record (item or money)
-- @param guildData table Guild data from AceDB
function GBL:UpdatePlayerStats(record, guildData)
    if not guildData or not record.player then return end

    -- AceDB wildcard metatable auto-vivifies the player entry
    local stats = guildData.playerStats[record.player]

    -- Update timestamps
    if stats.firstSeen == 0 or record.timestamp < stats.firstSeen then
        stats.firstSeen = record.timestamp
    end
    if record.timestamp > stats.lastSeen then
        stats.lastSeen = record.timestamp
    end

    -- Item transactions
    if record.itemID then
        if record.type == "deposit" then
            stats.totalDepositCount = stats.totalDepositCount + (record.count or 0)
        elseif record.type == "withdraw" then
            stats.totalWithdrawCount = stats.totalWithdrawCount + (record.count or 0)
        end
    end

    -- Money transactions
    if record.amount then
        if record.type == "deposit" then
            stats.moneyDeposited = stats.moneyDeposited + record.amount
        elseif record.type == "withdraw" then
            stats.moneyWithdrawn = stats.moneyWithdrawn + record.amount
        end
    end
end

------------------------------------------------------------------------
-- Transaction log reading
------------------------------------------------------------------------

--- Read all item transactions from a single guild bank tab.
-- @param tab number Tab index
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
function GBL:ReadTabTransactions(tab, guildData)
    if not guildData then return 0 end

    QueryGuildBankLog(tab)

    local numTx = GetNumGuildBankTransactions(tab)
    local stored = 0

    for i = 1, numTx do
        local txType, name, itemLink, count, tab1, tab2, year, month, day, hour =
            GetGuildBankTransaction(tab, i)

        if txType and name then
            local record = self:CreateTxRecord(
                txType, name, itemLink, count, tab1, tab2,
                year, month, day, hour
            )
            if self:StoreTx(record, guildData) then
                stored = stored + 1
            end
        end
    end

    return stored
end

--- Read all money transactions from the guild bank money log.
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
function GBL:ReadMoneyTransactions(guildData)
    if not guildData then return 0 end

    local moneyTab = GetNumGuildBankTabs() + 1
    QueryGuildBankLog(moneyTab)

    local numTx = GetNumGuildBankMoneyTransactions()
    local stored = 0

    for i = 1, numTx do
        local txType, name, amount, year, month, day, hour =
            GetGuildBankMoneyTransaction(i)

        if txType and name then
            local record = self:CreateMoneyTxRecord(
                txType, name, amount,
                year, month, day, hour
            )
            if self:StoreMoneyTx(record, guildData) then
                stored = stored + 1
            end
        end
    end

    return stored
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

--- Scan all transaction logs (item + money) and store new records.
-- Called from Core.lua OnBankOpened.
function GBL:ScanTransactions()
    local guildData = self:GetGuildData()
    if not guildData then return end

    local totalStored = 0
    local numTabs = GetNumGuildBankTabs()

    for tab = 1, numTabs do
        totalStored = totalStored + self:ReadTabTransactions(tab, guildData)
    end

    totalStored = totalStored + self:ReadMoneyTransactions(guildData)

    self:SendMessage("GBL_LEDGER_SCAN_COMPLETE", totalStored)
end
