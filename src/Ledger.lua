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

--- Name a guild bank tab, in four steps (#236): the live name, then one
-- this session has already read from the current guild's bank, then the
-- caller's stored name, then the index. Every live reader goes through
-- here; a transaction record is the exception and keeps the name it was
-- created under.
--
-- The session cache is what makes this work away from the bank.
-- BackfillTabNames (src/Core.lua) says the live read "only works while the
-- bank is open", and the Restock tab is worked at the auction house, so the
-- live branch answers nothing exactly where the name is wanted. A
-- remembered name is a reading rather than a guess, and it is per session,
-- so a rename is picked up on the next bank visit.
--
-- The cache is kept per guild (#287). A player can leave one guild and join
-- another without logging out, and BackfillTabNames stores what this
-- answers on records for good, so a name the first guild's bank gave must
-- never answer for the second. It is keyed by GetGuildName, the key
-- GetGuildData uses, which answers the last name it read, so a remembered
-- name still answers in the frames after a loading screen where
-- GetGuildInfo answers nothing. With no guild name known nothing is filed.
--
-- `fallback` is for the window before the bank has been opened at all,
-- where a capture-time name still beats "Tab 3". It is type-tested and its
-- escape introducer is doubled, because a synced layout copies
-- `tabs[].name` verbatim (`copyTab`, src/BankLayout.lua) and `Validate`
-- never looks at it, so a peer can put anything there and it lands in
-- SetText on two tabs.
-- @param tab number Tab index
-- @param fallback string|nil a stored name to use when nothing else names it
-- @return string Tab name, or fallback to "Tab N"
function GBL:GetTabName(tab, fallback)
    if not tab then return nil end
    local key = tonumber(tab) or tab
    local guildName = self:GetGuildName()
    if GetGuildBankTabInfo then
        local name = GetGuildBankTabInfo(tab)
        if name and name ~= "" then
            if guildName then
                self._tabNamesSeen = self._tabNamesSeen or {}
                local names = self._tabNamesSeen[guildName] or {}
                self._tabNamesSeen[guildName] = names
                names[key] = name
            end
            return name
        end
    end
    local names = self._tabNamesSeen and self._tabNamesSeen[guildName]
    local seen = names and names[key]
    if seen then return seen end
    if type(fallback) == "string" and fallback ~= "" then
        -- A lone "|" is WoW's escape introducer, and this one came from a
        -- peer's layout through copyTab, which validates nothing.
        return (fallback:gsub("|", "||"))
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
    local scannedBy = self:ResolvePlayerName(UnitName("player") or "Unknown")

    -- Resolve tab names (available while bank is open)
    local tabName = self:GetTabName(tab)
    local destTabName = (txType == "move" and destTab) and self:GetTabName(destTab) or nil

    local record = {
        type = txType,
        player = self:ResolvePlayerName(name),
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
    local scannedBy = self:ResolvePlayerName(UnitName("player") or "Unknown")

    local record = {
        type = txType,
        player = self:ResolvePlayerName(name),
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
-- @param opts table|nil { timestampRewritten = true } from the sync intake
function GBL:StoreTx(record, guildData, opts)
    if not guildData then return false end
    if not record.type or record.type == "" then return false end
    if not record.player or record.player == "" then return false end

    -- The rewrite happens in place, so a later reader cannot tell a record
    -- that carried this time from one that was given it. The restock hook
    -- is the one reader that has to know (#215): it compares the timestamp
    -- against a purchase time, and a rewritten one always passes. **The
    -- caller is where that normally comes from**: the one production
    -- caller is the sync receive, and reconstructSyncRecord runs this same
    -- check before us, so the branch below never fires there and a guard
    -- resting on it alone was dead code. Kept for a direct caller.
    local timestampRewritten = (opts and opts.timestampRewritten) or false
    if not self:IsValidTimestamp(record.timestamp) then
        record.timestamp = GetServerTime()
        timestampRewritten = true
    end

    if self:IsDuplicate(record, guildData) then
        return false
    end

    self:MarkSeen(record.id, record.timestamp, guildData)
    table.insert(guildData.transactions, record)
    self:UpdatePlayerStats(record, guildData)
    -- A first-time item deposit may settle a pending restock purchase
    -- (#209). StoreBatchRecords has the same call for the scan path, and
    -- needs no third argument because it does not rewrite a timestamp.
    if self._RestockOnRecordStored then
        self:_RestockOnRecordStored(record, guildData,
            timestampRewritten and { timestampRewritten = true } or nil)
    end
    return true
end

--- Store a money transaction record after dedup check.
-- @param record table Money transaction record
-- @param guildData table Guild data from AceDB
-- @return boolean True if stored (not duplicate)
function GBL:StoreMoneyTx(record, guildData)
    if not guildData then return false end
    if not record.type or record.type == "" then return false end
    if not record.player or record.player == "" then return false end

    if not self:IsValidTimestamp(record.timestamp) then
        record.timestamp = GetServerTime()
    end

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
-- Uses count-based batch dedup: compares how many records exist per
-- baseHash against the session cache (rescan) or seenTxHashes (initial).
-- Immune to occurrence index shift from WoW API ordering changes.
-- @param tab number Tab index
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
-- @return table { read, new, skipped, refused } for the ledger log (#85)
function GBL:ReadTabTransactions(tab, guildData)
    if not guildData then return 0 end

    local numTx = GetNumGuildBankTransactions(tab)
    local batch = {}
    -- An entry with no type or name is never recorded. The client does
    -- return a nil name: Blizzard's own UI shows it as Unknown (#335).
    local skipped = 0

    for i = 1, numTx do
        local txType, name, itemLink, count, tab1, tab2, year, month, day, hour =
            GetGuildBankTransaction(tab, i)

        if not (txType and name) then
            skipped = skipped + 1
        else
            -- WoW fills tab1 only for moves, where it is the source tab. For a
            -- deposit or withdrawal it is nil, so fall back to the log we are
            -- actually reading, which IS the tab the transaction happened in.
            -- Without the fallback those records carried no tab at all (#67).
            local record = self:CreateTxRecord(
                txType, name, itemLink, count, tab1 or tab, tab2,
                year, month, day, hour
            )
            batch[#batch + 1] = record
        end
    end

    -- Session-local cache: nil on first scan, populated on subsequent rescans
    if not self._lastTabBatchCounts then self._lastTabBatchCounts = {} end
    local prevCounts = self._lastTabBatchCounts[tab]

    local stored, currentCounts, refused = self:StoreBatchRecords(
        batch, guildData, "transactions", prevCounts)

    self._lastTabBatchCounts[tab] = currentCounts
    return stored, { read = numTx, new = stored, skipped = skipped, refused = refused or 0 }
end

--- Read all money transactions from the guild bank money log.
-- Uses count-based batch dedup (same approach as ReadTabTransactions).
-- @param guildData table Guild data from AceDB
-- @return number Count of newly stored (non-duplicate) records
-- @return table { read, new, skipped, refused } for the ledger log (#85)
function GBL:ReadMoneyTransactions(guildData)
    if not guildData then return 0 end

    local numTx = GetNumGuildBankMoneyTransactions()
    local batch = {}
    local skipped = 0

    for i = 1, numTx do
        local txType, name, amount, year, month, day, hour =
            GetGuildBankMoneyTransaction(i)

        if not (txType and name) then
            skipped = skipped + 1
        else
            local record = self:CreateMoneyTxRecord(
                txType, name, amount,
                year, month, day, hour
            )
            batch[#batch + 1] = record
        end
    end

    local prevCounts = self._lastMoneyBatchCounts

    local stored, currentCounts, refused = self:StoreBatchRecords(
        batch, guildData, "moneyTransactions", prevCounts)

    self._lastMoneyBatchCounts = currentCounts
    return stored, { read = numTx, new = stored, skipped = skipped, refused = refused or 0 }
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

--- Read all available transaction data and return count of new records.
-- @param guildData table Guild data from AceDB
-- @return number count of newly stored records
-- @return table|nil what each log answered, for the ledger log (#85):
--   { tabs = { [i] = { key = "T1", read, new, skipped, refused } },
--     items = n, money = n }, the money log last under key "M"
function GBL:ReadAllTransactions(guildData)
    if not guildData then return 0 end

    local summary = { tabs = {}, items = 0, money = 0 }
    local numTabs = GetNumGuildBankTabs()

    for tab = 1, numTabs do
        local stored, detail = self:ReadTabTransactions(tab, guildData)
        detail.key = "T" .. tab
        summary.tabs[#summary.tabs + 1] = detail
        summary.items = summary.items + stored
    end
    local moneyStored, moneyDetail = self:ReadMoneyTransactions(guildData)
    moneyDetail.key = "M"
    summary.tabs[#summary.tabs + 1] = moneyDetail
    summary.money = moneyStored

    return summary.items + summary.money, summary
end

------------------------------------------------------------------------
-- The ledger log (#85)
------------------------------------------------------------------------

-- The read timers. Exported so the specs fire them by name.
local SCAN_DEBOUNCE, SCAN_FALLBACK = 0.5, 2
local RESCAN_DEBOUNCE, RESCAN_FALLBACK = 0.3, 1.5
GBL.LEDGER_SCAN_DEBOUNCE = SCAN_DEBOUNCE
GBL.LEDGER_SCAN_FALLBACK = SCAN_FALLBACK
GBL.LEDGER_RESCAN_DEBOUNCE = RESCAN_DEBOUNCE
GBL.LEDGER_RESCAN_FALLBACK = RESCAN_FALLBACK

--- Write one read's summary line, and a WARN for anything it could not
-- record. The open read is INFO on every visit. A rescan runs every few
-- seconds at the bank, so it is INFO only when it stored something or a
-- log's counts moved since the previous read, and DEBUG otherwise.
--
-- The previous read is kept for the session and for one guild (the
-- guildData table), never reset with the batch caches at bank close.
-- The WARNs compare against the most this session has already warned
-- about for that log, not the previous read: the same nameless or
-- refused entry is read again after every bank reopen and every cache
-- reset, and a tab that has not answered reads 0 and then comes back
-- (#336), so a comparison with the previous read would repeat them.
-- @param kind string "open" or "rescan"
-- @param via string "event" or "timeout", the timer that ran the read
-- @param guildData table The guild the read was for
-- @param summary table The second return of ReadAllTransactions
local function logRead(self, kind, via, guildData, summary)
    local last = self._lastLogRead
    if not (last and last.guildData == guildData) then last = nil end
    local warned = (last and last.warned) or { skipped = {}, refused = {} }

    local reads, parts, rose, refusedAt = {}, {}, {}, {}
    local read, skipped, refused = 0, 0, 0
    local moved = (last == nil)
    for _, d in ipairs(summary.tabs or {}) do
        parts[#parts + 1] = string.format("%s=%d/%d", d.key, d.new or 0, d.read or 0)
        read, skipped, refused = read + (d.read or 0),
            skipped + (d.skipped or 0), refused + (d.refused or 0)
        local prev = last and last.reads[d.key]
        if not prev or prev.read ~= d.read or prev.skipped ~= d.skipped then
            moved = true
        end
        if (d.skipped or 0) > (warned.skipped[d.key] or 0) then
            rose[#rose + 1] = d.key .. "=" .. d.skipped
            warned.skipped[d.key] = d.skipped
        end
        if (d.refused or 0) > (warned.refused[d.key] or 0) then
            refusedAt[#refusedAt + 1] = d.key .. "=" .. d.refused
            warned.refused[d.key] = d.refused
        end
        reads[d.key] = { read = d.read, skipped = d.skipped }
    end
    self._lastLogRead = { guildData = guildData, reads = reads, warned = warned }

    local new = (summary.items or 0) + (summary.money or 0)
    local level = "DEBUG"
    if kind == "open" or new > 0 or moved then level = "INFO" end
    self:LogLedger(level,
        "Bank log read: on=%s via=%s new=%d items=%d money=%d read=%d skipped=%d refused=%d [%s]",
        kind, via, new, summary.items or 0, summary.money or 0, read, skipped, refused,
        table.concat(parts, " "))
    if #rose > 0 then
        self:LedgerWarn("Bank log read: on=%s entries with no type or name, not recorded: %s",
            kind, table.concat(rose, " "))
    end
    if #refusedAt > 0 then
        self:LedgerWarn("Bank log read: on=%s records refused at store (no type or player): %s",
            kind, table.concat(refusedAt, " "))
    end
end

--- logRead, protected: a fault in the log line must not stop the read
-- chain it is reporting on (the rescan reschedules from its callback).
local function safeLogRead(self, kind, via, guildData, summary)
    if not summary then return end
    local ok, err = pcall(logRead, self, kind, via, guildData, summary)
    if not ok then
        self:LedgerError("Bank log read: on=%s could not be logged: %s", kind, tostring(err))
    end
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

    -- @param via string "event" or "timeout": which timer ran the read
    local function finishScan(via)
        if completed then return end
        completed = true
        debounceTimer = nil
        pcall(function() self:UnregisterEvent("GUILDBANKLOG_UPDATE") end)

        if not self.bankOpen then
            self:LedgerInfo("Bank log read: on=open via=%s abandoned, the guild bank"
                .. " window closed before the read", via)
            if callback then callback(0) end
            return
        end

        -- Protected like the rescan's read: the callback is what marks the
        -- first scan complete and starts the periodic rescan.
        local ok, totalStored, summary = pcall(self.ReadAllTransactions, self, guildData)
        if ok then
            safeLogRead(self, "open", via, guildData, summary)
        else
            self:LedgerError("Bank log read: on=open via=%s failed: %s",
                via, tostring(totalStored))
            totalStored = 0
        end
        self:SendMessage("GBL_LEDGER_SCAN_COMPLETE", totalStored)
        if callback then callback(totalStored) end
    end

    -- Listen for server response, debounced so the read waits for every
    -- tab. The cancel needs a handle, and the live client's C_Timer.After
    -- returns none (#118), so there each event schedules its own read and
    -- the first one to fire wins (#336). The mock returns a handle.
    self.GUILDBANKLOG_UPDATE = function()
        if completed then return end
        if debounceTimer then
            debounceTimer.cancelled = true
        end
        debounceTimer = C_Timer.After(SCAN_DEBOUNCE, function() finishScan("event") end)
    end
    self:RegisterEvent("GUILDBANKLOG_UPDATE")

    -- Query all logs (item tabs + money tab)
    for tab = 1, numTabs do
        QueryGuildBankLog(tab)
    end
    QueryGuildBankLog(moneyTab)

    -- Fallback: if event never fires (data already cached), read after 2s
    C_Timer.After(SCAN_FALLBACK, function() finishScan("timeout") end)

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

    -- v0.32.9 confounder investigation: a real rescan is about to run. If a sort
    -- is in progress, let it count this so the sort env summary shows how many
    -- periodic rescans competed with the sort.
    if self.IsSortRunning and self:IsSortRunning() and self._sortNoteRescanTick then
        self:_sortNoteRescanTick()
    end

    local completed = false
    local debounceTimer = nil

    -- @param via string "event" or "timeout": which timer ran the read
    local function finishRescan(via)
        if completed then return end
        completed = true
        pcall(function() self:UnregisterEvent("GUILDBANKLOG_UPDATE") end)

        -- Protected read so errors never break the rescan chain
        local freshGuildData
        local ok, newCount, summary = pcall(function()
            if not self.bankOpen then return 0 end
            freshGuildData = self:GetGuildData()
            if not freshGuildData then return 0 end
            return self:ReadAllTransactions(freshGuildData)
        end)
        if ok and summary then
            safeLogRead(self, "rescan", via, freshGuildData, summary)
        elseif ok then
            -- DEBUG, not the open read's INFO: every bank close ends a
            -- rescan chain this way.
            self:LedgerDebug("Bank log read: on=rescan via=%s abandoned, %s", via,
                self.bankOpen and "no guild data" or "the guild bank window closed before the read")
        else
            self:LedgerError("Bank log read: on=rescan via=%s failed: %s",
                via, tostring(newCount))
        end
        if callback then callback(ok and newCount or 0) end
    end

    -- Listen for server response, debounced as ScanTransactions is, with
    -- the same live-client caveat (#118, #336).
    self.GUILDBANKLOG_UPDATE = function()
        if completed then return end
        if debounceTimer then
            debounceTimer.cancelled = true
        end
        debounceTimer = C_Timer.After(RESCAN_DEBOUNCE, function() finishRescan("event") end)
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
    C_Timer.After(RESCAN_FALLBACK, function() finishRescan("timeout") end)
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
