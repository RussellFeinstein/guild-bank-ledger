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
-- Tab name lookup
------------------------------------------------------------------------

--- Get the display name for a guild bank tab.
-- @param tab number Tab index
-- @return string Tab name, or fallback to "Tab N"
function GBL:GetTabName(tab)
    if not tab then return nil end
    if GetGuildBankTabInfo then
        local name = GetGuildBankTabInfo(tab)
        if name and name ~= "" then
            return name
        end
    end
    return "Tab " .. tostring(tab)
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

    -- Resolve tab names (available while bank is open)
    local tabName = self:GetTabName(tab)
    local destTabName = (txType == "move" and destTab) and self:GetTabName(destTab) or nil

    local record = {
        type = txType,
        player = name,
        itemLink = itemLink,
        itemID = itemID,
        count = count or 0,
        tab = tab,
        tabName = tabName,
        destTab = (txType == "move") and destTab or nil,
        destTabName = destTabName,
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
-- WoW API returns "withdrawal" for money but "withdraw" for items;
-- we normalize to "withdraw" so all downstream code uses one string.
-- @param txType string "deposit"|"withdrawal"|"withdraw"|"repair"|"buyTab"|"depositSummary"
-- @param name string Player name
-- @param amount number Copper amount
-- @param year number Relative year offset
-- @param month number Relative month offset
-- @param day number Relative day offset
-- @param hour number Relative hour offset
-- @return table Money transaction record
function GBL:CreateMoneyTxRecord(txType, name, amount, year, month, day, hour)
    -- Normalize WoW API type: "withdrawal" → "withdraw" for consistency with item tx
    if txType == "withdrawal" then txType = "withdraw" end

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

    -- Update timestamps (guard nil — synced records from older versions may lack timestamp)
    if record.timestamp then
        if stats.firstSeen == 0 or record.timestamp < stats.firstSeen then
            stats.firstSeen = record.timestamp
        end
        if record.timestamp > stats.lastSeen then
            stats.lastSeen = record.timestamp
        end
    end

    -- Item transactions
    if record.itemID then
        if record.type == "deposit" then
            stats.totalDepositCount = stats.totalDepositCount + (record.count or 0)
        elseif record.type == "withdraw" then
            stats.totalWithdrawCount = stats.totalWithdrawCount + (record.count or 0)
        end
    end

    -- Money transactions (repair and buyTab are withdrawals, depositSummary is a deposit)
    if record.amount then
        if record.type == "deposit" or record.type == "depositSummary" then
            stats.moneyDeposited = stats.moneyDeposited + record.amount
        elseif record.type == "withdraw" or record.type == "repair" or record.type == "buyTab" then
            stats.moneyWithdrawn = stats.moneyWithdrawn + record.amount
        end
    end
end

------------------------------------------------------------------------
-- Transaction log reading
------------------------------------------------------------------------

--- Read all item transactions from a single guild bank tab.
-- Reads the batch, assigns occurrence indices to distinguish identical
-- transactions, then stores non-duplicates.
-- @param tab number Tab index
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
function GBL:ReadTabTransactions(tab, guildData)
    if not guildData then return 0 end

    local numTx = GetNumGuildBankTransactions(tab)
    local batch = {}

    for i = 1, numTx do
        local txType, name, itemLink, count, tab1, tab2, year, month, day, hour =
            GetGuildBankTransaction(tab, i)

        if txType and name then
            local record = self:CreateTxRecord(
                txType, name, itemLink, count, tab1, tab2,
                year, month, day, hour
            )
            table.insert(batch, record)
        end
    end

    -- Assign occurrence indices so identical transactions get unique hashes
    self:AssignOccurrenceIndices(batch)

    local stored = 0
    for _, record in ipairs(batch) do
        if self:StoreTx(record, guildData) then
            stored = stored + 1
        end
    end

    return stored
end

--- Read all money transactions from the guild bank money log.
-- Reads the batch, assigns occurrence indices to distinguish identical
-- transactions, then stores non-duplicates.
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
function GBL:ReadMoneyTransactions(guildData)
    if not guildData then return 0 end

    local numTx = GetNumGuildBankMoneyTransactions()
    local batch = {}

    for i = 1, numTx do
        local txType, name, amount, year, month, day, hour =
            GetGuildBankMoneyTransaction(i)

        if txType and name then
            local record = self:CreateMoneyTxRecord(
                txType, name, amount,
                year, month, day, hour
            )
            table.insert(batch, record)
        end
    end

    -- Assign occurrence indices so identical transactions get unique hashes
    self:AssignOccurrenceIndices(batch)

    local stored = 0
    for _, record in ipairs(batch) do
        if self:StoreMoneyTx(record, guildData) then
            stored = stored + 1
        end
    end

    return stored
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

--- Read all available transaction data and return count of new records.
-- @param guildData table Guild data from AceDB
-- @return number count of newly stored records
function GBL:ReadAllTransactions(guildData)
    if not guildData then return 0 end

    local totalStored = 0
    local numTabs = GetNumGuildBankTabs()

    for tab = 1, numTabs do
        totalStored = totalStored + self:ReadTabTransactions(tab, guildData)
    end
    totalStored = totalStored + self:ReadMoneyTransactions(guildData)

    return totalStored
end

--- Query all transaction logs and read them when the server responds.
-- Uses GUILDBANKLOG_UPDATE event with a debounced read.
-- Each event resets a 0.5s timer so we wait for ALL tab responses
-- (including money tab) to arrive before reading.
-- @param callback function(totalStored) called when all logs are read
function GBL:ScanTransactions(callback)
    local guildData = self:GetGuildData()
    if not guildData then
        if callback then callback(0) end
        return 0
    end

    local numTabs = GetNumGuildBankTabs()
    -- Money log is always at MAX_GUILDBANK_TABS+1 (constant 9), NOT numTabs+1.
    -- GetNumGuildBankTabs() returns purchased tabs (1-8), but the money log
    -- index is fixed at 9 regardless of how many tabs the guild has.
    local moneyTab = (MAX_GUILDBANK_TABS or 8) + 1
    local completed = false
    local debounceTimer = nil

    local function finishScan()
        if completed then return end
        completed = true
        debounceTimer = nil
        pcall(function() self:UnregisterEvent("GUILDBANKLOG_UPDATE") end)

        if not self.bankOpen then
            if callback then callback(0) end
            return
        end

        local totalStored = self:ReadAllTransactions(guildData)
        self:SendMessage("GBL_LEDGER_SCAN_COMPLETE", totalStored)
        if callback then callback(totalStored) end
    end

    -- Listen for server response — debounce so we wait for all tabs
    -- including money tab to arrive before reading
    self.GUILDBANKLOG_UPDATE = function()
        if completed then return end
        -- Cancel previous timer and restart — ensures we wait 0.5s
        -- after the LAST event, giving all tab responses time to arrive
        if debounceTimer then
            debounceTimer.cancelled = true
        end
        debounceTimer = C_Timer.After(0.5, finishScan)
    end
    self:RegisterEvent("GUILDBANKLOG_UPDATE")

    -- Query all logs (item tabs + money tab)
    for tab = 1, numTabs do
        QueryGuildBankLog(tab)
    end
    QueryGuildBankLog(moneyTab)

    -- Fallback: if event never fires (data already cached), read after 2s
    C_Timer.After(2, finishScan)

    return 0
end

------------------------------------------------------------------------
-- Periodic re-scan (all tabs + money)
------------------------------------------------------------------------

--- Lightweight re-scan of all transaction logs.
-- Queries all item tabs + money tab 9, waits for GUILDBANKLOG_UPDATE
-- event (with 1.5s fallback), then reads. Dedup prevents duplicates.
-- @param callback function(newCount) called with count of new records
function GBL:RescanTransactionLogs(callback)
    if not self.bankOpen then
        if callback then callback(0) end
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then
        if callback then callback(0) end
        return
    end

    local completed = false
    local debounceTimer = nil

    local function finishRescan()
        if completed then return end
        completed = true
        pcall(function() self:UnregisterEvent("GUILDBANKLOG_UPDATE") end)

        -- Protected read so errors never break the rescan chain
        local ok, newCount = pcall(function()
            if not self.bankOpen then return 0 end
            local freshGuildData = self:GetGuildData()
            if not freshGuildData then return 0 end
            return self:ReadAllTransactions(freshGuildData)
        end)
        if callback then callback(ok and newCount or 0) end
    end

    -- Listen for server response — 0.3s debounce so we wait for all tabs
    self.GUILDBANKLOG_UPDATE = function()
        if completed then return end
        if debounceTimer then
            debounceTimer.cancelled = true
        end
        debounceTimer = C_Timer.After(0.3, finishRescan)
    end
    self:RegisterEvent("GUILDBANKLOG_UPDATE")

    -- Query all logs (item tabs + money tab)
    local numTabs = GetNumGuildBankTabs()
    local moneyTab = (MAX_GUILDBANK_TABS or 8) + 1
    for tab = 1, numTabs do
        QueryGuildBankLog(tab)
    end
    QueryGuildBankLog(moneyTab)

    -- Fallback if event never fires (data already cached)
    C_Timer.After(1.5, finishRescan)
end

--- Start the periodic transaction log re-scan timer.
-- Runs whenever the bank is open and rescan is enabled.
-- Self-chaining: each tick schedules the next after completing.
-- Uses a boolean flag for state tracking (immune to C_Timer.After
-- return-value differences across WoW versions).
function GBL:StartPeriodicRescan()
    if not self.bankOpen then return end
    if not self._initialScanComplete then return end
    if not self.db.profile.scanning.rescanEnabled then return end
    if self:IsPeriodicRescanActive() then return end

    self._rescanActive = true
    local interval = self.db.profile.scanning.rescanInterval or 3

    local function tick()
        -- Check stop conditions at start of every tick
        if not self._rescanActive then return end
        if not self.bankOpen then
            self._rescanActive = false
            return
        end
        if not self.db.profile.scanning.rescanEnabled then
            self._rescanActive = false
            return
        end

        -- Protected call so errors never break the chain
        local ok, err = pcall(function()
            self:RescanTransactionLogs(function(newCount)
                if newCount and newCount > 0 then
                    self:Print(format("Re-scan: %d new transaction%s.",
                        newCount, newCount == 1 and "" or "s"))
                    self:RefreshUI()
                end

                -- Schedule next tick (re-check conditions)
                if self._rescanActive
                    and self.bankOpen
                    and self.db.profile.scanning.rescanEnabled then
                    C_Timer.After(interval, tick)
                else
                    self._rescanActive = false
                end
            end)
        end)

        -- If pcall caught an error, log it and still schedule next tick
        if not ok then
            if self.db.profile.scanning.notifyOnScan then
                self:Print("Re-scan error: " .. tostring(err))
            end
            if self._rescanActive and self.bankOpen then
                C_Timer.After(interval, tick)
            else
                self._rescanActive = false
            end
        end
    end

    C_Timer.After(interval, tick)
end

--- Stop the periodic re-scan timer.
function GBL:StopPeriodicRescan()
    self._rescanActive = false
end

--- Check whether the periodic re-scan timer is running.
-- @return boolean
function GBL:IsPeriodicRescanActive()
    return self._rescanActive == true
end
