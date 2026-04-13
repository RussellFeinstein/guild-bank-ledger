------------------------------------------------------------------------
-- GuildBankLedger — Core.lua
-- AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local VERSION = "0.13.0"

local GBL = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceComm-3.0",
    "AceSerializer-3.0"
)

-- AceDB defaults
local defaults = {
    global = {
        guilds = {
            ["*"] = {
                transactions = {},
                moneyTransactions = {},
                dailySummaries = {},
                weeklySummaries = {},
                snapshots = {},
                playerStats = {
                    ["*"] = {
                        withdrawals = {},
                        deposits = {},
                        totalWithdrawCount = 0,
                        totalDepositCount = 0,
                        moneyWithdrawn = 0,
                        moneyDeposited = 0,
                        firstSeen = 0,
                        lastSeen = 0,
                    },
                },
                teams = {},
                altLinks = {},
                stockAlerts = {},
                seenTxHashes = {},
                playerRealms = {},
                syncState = { lastSyncTimestamp = 0, syncVersion = 0, peers = {} },
                schemaVersion = 3,
            },
        },
    },
    profile = {
        minimap = { hide = false },
        ui = {
            scale = 1.0, width = 1000, height = 600,
            font = "Fonts\\FRIZQT__.TTF", fontSize = 12,
            colorblindMode = false, highContrast = false, lockFrame = false,
            openOnBankOpen = true,
            autoOpenMaxRank = 2,
        },
        scanning = {
            autoScan = true, scanDelay = 0.5, notifyOnScan = true,
            thankYouMessage = "Thanks for helping run the guild!",
            lockBankWhileScanning = false,
            rescanEnabled = true, rescanInterval = 3,
        },
        alerts = { enabled = true, chatNotify = true, soundNotify = true },
        export = { delimiter = ",", includeHeaders = true, dateFormat = "%Y-%m-%d %H:%M" },
        sync = { enabled = true, autoSync = true, chatLog = false },
        filters = { defaultDays = 7, defaultCategory = "ALL" },
    },
}

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function GBL:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildBankLedgerDB", defaults, true)
    self.bankOpen = false
    self.scanInProgress = false
    self.lastScanTime = 0
    self.version = VERSION

    self:RegisterChatCommand("gbl", "HandleSlashCommand")
    self:RegisterChatCommand("guildbankledger", "HandleSlashCommand")

    -- Minimap button (M3)
    self:SetupMinimapButton()
end

function GBL:OnEnable()
    -- Bank open/close detection (10.0.2+)
    if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker then
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
        self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    end

    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "OnItemInfoReceived")
    self:InstallBankCloseHook()

    -- Migrate occurrence scheme before sync starts (v0.12.0)
    self:MigrateAllGuilds()

    -- Initialize sync system (M5)
    self:InitSync()
end

------------------------------------------------------------------------
-- Data migration
------------------------------------------------------------------------

--- Migrate occurrence indices from per-baseHash to per-prefix counting.
-- Old scheme: two events with the same prefix but different timeSlots both
-- got occurrence :0, causing cross-client false positives on exact match.
-- New scheme: occurrences are sequential per-prefix regardless of timeSlot.
-- @param guildData table Guild data from AceDB
function GBL:MigrateOccurrenceScheme(guildData)
    if not guildData or guildData.schemaVersion >= 2 then return end

    -- Remove corrupted records (AceSerializer field boundary corruption)
    local function isCorrupted(record)
        if not record.type or record.type == "" then return true end
        if not record.player or record.player == "" then return true end
        for key in pairs(record) do
            if type(key) == "string" and key ~= "type" and key:match("^typ") then
                return true
            end
        end
        return false
    end
    local function removeCorrupted(arr)
        for i = #arr, 1, -1 do
            if isCorrupted(arr[i]) then
                table.remove(arr, i)
            end
        end
    end
    removeCorrupted(guildData.transactions)
    removeCorrupted(guildData.moneyTransactions)

    -- Collect all records
    local allRecords = {}
    for _, tx in ipairs(guildData.transactions) do
        allRecords[#allRecords + 1] = tx
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        allRecords[#allRecords + 1] = tx
    end

    if #allRecords == 0 then
        guildData.schemaVersion = 2
        return
    end

    -- Group records by prefix
    local groups = {}
    for _, record in ipairs(allRecords) do
        local prefix = self:BuildTxPrefix(record)
        if not groups[prefix] then
            groups[prefix] = {}
        end
        groups[prefix][#groups[prefix] + 1] = record
    end

    -- Sort each group by timestamp (tiebreak on old ID for determinism)
    for _, group in pairs(groups) do
        table.sort(group, function(a, b)
            if (a.timestamp or 0) == (b.timestamp or 0) then
                return (a.id or "") < (b.id or "")
            end
            return (a.timestamp or 0) < (b.timestamp or 0)
        end)

        -- Reassign occurrence indices
        for i, record in ipairs(group) do
            local occ = i - 1
            -- Strip old :N suffix, recompute
            local baseHash = record.id and record.id:gsub(":%d+$", "") or ""
            record.id = baseHash .. ":" .. occ
            record._occurrence = occ
        end
    end

    -- Rebuild seenTxHashes from scratch
    local newHashes = {}
    for _, record in ipairs(allRecords) do
        if record.id then
            newHashes[record.id] = record.timestamp or 0
        end
    end

    -- Clear and replace (preserve table reference for AceDB)
    for k in pairs(guildData.seenTxHashes) do
        guildData.seenTxHashes[k] = nil
    end
    for k, v in pairs(newHashes) do
        guildData.seenTxHashes[k] = v
    end

    guildData.schemaVersion = 2
    self:ResetHashCache()
end

------------------------------------------------------------------------
-- Player name helpers
------------------------------------------------------------------------

--- Resolve a bare player name to Name-Realm format.
-- Priority: already-qualified → roster cache → local realm fallback.
-- @param name string Bare or already-qualified name
-- @return string Name-Realm format
function GBL:ResolvePlayerName(name)
    if not name or name == "" then return name end
    -- Already has realm suffix
    if name:find("%-") then return name end
    -- Check persistent roster cache
    local guildData = self:GetGuildData()
    if guildData and guildData.playerRealms and guildData.playerRealms[name] then
        return name .. "-" .. guildData.playerRealms[name]
    end
    -- Fallback: append local realm
    local realm = GetNormalizedRealmName()
        or (GetRealmName and GetRealmName() and GetRealmName():gsub("%s", ""))
        or "UnknownRealm"
    return name .. "-" .. realm
end

--- Strip realm suffix from a character name.
-- For peer matching and filter comparison only — records should always
-- store the full Name-Realm format.
-- @param name string Character name, possibly realm-qualified
-- @return string Base name without realm suffix
function GBL:StripRealm(name)
    if not name then return "" end
    return name:match("^([^%-]+)") or name
end

--- Build/update the persistent guild roster cache.
-- Maps bare player names to their realm, persisted in SavedVariables.
-- Called on GUILD_ROSTER_UPDATE so the mapping survives guild departures.
function GBL:BuildRosterCache()
    if not self.db then return end
    local numMembers = GetNumGuildMembers()
    local guildData = self:GetGuildData()
    if not guildData or not numMembers or numMembers == 0 then return end
    if not guildData.playerRealms then guildData.playerRealms = {} end
    local localRealm = GetNormalizedRealmName()
        or (GetRealmName and GetRealmName() and GetRealmName():gsub("%s", ""))
    for i = 1, numMembers do
        local fullName = GetGuildRosterInfo(i)
        if fullName then
            local base, realm = fullName:match("^([^%-]+)%-(.+)$")
            if base and realm then
                guildData.playerRealms[base] = realm
            elseif localRealm then
                guildData.playerRealms[fullName] = localRealm
            end
        end
    end
end

------------------------------------------------------------------------
-- Schema migration v2 → v3: Name-Realm normalization
------------------------------------------------------------------------

--- Migrate player names from bare to Name-Realm format.
-- Also removes corrupted records and merges duplicate playerStats entries.
-- @param guildData table Guild data from AceDB
function GBL:MigrateSchemaV2ToV3(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 3 then return end

    if not guildData.playerRealms then guildData.playerRealms = {} end

    -- Step 1: Harvest realm hints from existing records
    -- Synced records may already have realm-qualified player names
    local allRecords = {}
    for _, tx in ipairs(guildData.transactions or {}) do
        allRecords[#allRecords + 1] = tx
    end
    for _, tx in ipairs(guildData.moneyTransactions or {}) do
        allRecords[#allRecords + 1] = tx
    end

    for _, record in ipairs(allRecords) do
        if record.player then
            local base, realm = record.player:match("^([^%-]+)%-(.+)$")
            if base and realm then
                guildData.playerRealms[base] = realm
            end
        end
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                local base, realm = senderPart:match("^([^%-]+)%-(.+)$")
                if base and realm then
                    guildData.playerRealms[base] = realm
                end
            end
        end
    end

    -- Step 2: Remove corrupted records
    local function isCorrupted(record)
        if not record.type or record.type == "" then return true end
        if not record.player or record.player == "" then return true end
        for key in pairs(record) do
            if type(key) == "string" and key ~= "type" and key:match("^typ") then
                return true
            end
        end
        return false
    end
    local function removeCorrupted(arr)
        for i = #arr, 1, -1 do
            if isCorrupted(arr[i]) then
                table.remove(arr, i)
            end
        end
    end
    removeCorrupted(guildData.transactions)
    removeCorrupted(guildData.moneyTransactions)

    -- Step 3: Normalize player names in all records
    for _, record in ipairs(guildData.transactions) do
        record.player = self:ResolvePlayerName(record.player)
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                record.scannedBy = "sync:" .. self:ResolvePlayerName(senderPart)
            else
                record.scannedBy = self:ResolvePlayerName(record.scannedBy)
            end
        end
    end
    for _, record in ipairs(guildData.moneyTransactions) do
        record.player = self:ResolvePlayerName(record.player)
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                record.scannedBy = "sync:" .. self:ResolvePlayerName(senderPart)
            else
                record.scannedBy = self:ResolvePlayerName(record.scannedBy)
            end
        end
    end

    -- Step 4: Normalize daily/weekly summary player sets
    for _, summary in pairs(guildData.dailySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[self:ResolvePlayerName(name)] = true
            end
            summary.players = newPlayers
        end
    end
    for _, summary in pairs(guildData.weeklySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[self:ResolvePlayerName(name)] = true
            end
            summary.players = newPlayers
        end
    end

    -- Step 5: Recompute all record IDs (player name is in the hash prefix)
    local newAllRecords = {}
    for _, tx in ipairs(guildData.transactions) do
        newAllRecords[#newAllRecords + 1] = tx
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        newAllRecords[#newAllRecords + 1] = tx
    end

    if #newAllRecords > 0 then
        local groups = {}
        for _, record in ipairs(newAllRecords) do
            local prefix = self:BuildTxPrefix(record)
            if not groups[prefix] then groups[prefix] = {} end
            groups[prefix][#groups[prefix] + 1] = record
        end

        for _, group in pairs(groups) do
            table.sort(group, function(a, b)
                if (a.timestamp or 0) == (b.timestamp or 0) then
                    return (a.id or "") < (b.id or "")
                end
                return (a.timestamp or 0) < (b.timestamp or 0)
            end)
            for i, record in ipairs(group) do
                local occ = i - 1
                local baseHash = self:ComputeTxHash(record)
                record.id = baseHash .. ":" .. occ
                record._occurrence = occ
            end
        end
    end

    -- Step 6: Rebuild seenTxHashes from scratch
    for k in pairs(guildData.seenTxHashes) do
        guildData.seenTxHashes[k] = nil
    end
    for _, record in ipairs(newAllRecords) do
        if record.id then
            guildData.seenTxHashes[record.id] = record.timestamp or 0
        end
    end

    -- Step 7: Merge playerStats
    local newStats = {}
    for name, stats in pairs(guildData.playerStats) do
        local resolved = self:ResolvePlayerName(name)
        if newStats[resolved] then
            -- Merge: sum counts, min firstSeen, max lastSeen
            local existing = newStats[resolved]
            existing.totalWithdrawCount = (existing.totalWithdrawCount or 0)
                + (stats.totalWithdrawCount or 0)
            existing.totalDepositCount = (existing.totalDepositCount or 0)
                + (stats.totalDepositCount or 0)
            existing.moneyWithdrawn = (existing.moneyWithdrawn or 0)
                + (stats.moneyWithdrawn or 0)
            existing.moneyDeposited = (existing.moneyDeposited or 0)
                + (stats.moneyDeposited or 0)
            if (stats.firstSeen or 0) > 0 then
                if existing.firstSeen == 0 then
                    existing.firstSeen = stats.firstSeen
                else
                    existing.firstSeen = math.min(existing.firstSeen, stats.firstSeen)
                end
            end
            if (stats.lastSeen or 0) > 0 then
                existing.lastSeen = math.max(existing.lastSeen or 0, stats.lastSeen)
            end
            -- Merge withdrawal/deposit category breakdowns
            for cat, count in pairs(stats.withdrawals or {}) do
                existing.withdrawals[cat] = (existing.withdrawals[cat] or 0) + count
            end
            for cat, count in pairs(stats.deposits or {}) do
                existing.deposits[cat] = (existing.deposits[cat] or 0) + count
            end
        else
            -- Copy stats entry (shallow copy for tables)
            newStats[resolved] = {
                withdrawals = {},
                deposits = {},
                totalWithdrawCount = stats.totalWithdrawCount or 0,
                totalDepositCount = stats.totalDepositCount or 0,
                moneyWithdrawn = stats.moneyWithdrawn or 0,
                moneyDeposited = stats.moneyDeposited or 0,
                firstSeen = stats.firstSeen or 0,
                lastSeen = stats.lastSeen or 0,
            }
            for cat, count in pairs(stats.withdrawals or {}) do
                newStats[resolved].withdrawals[cat] = count
            end
            for cat, count in pairs(stats.deposits or {}) do
                newStats[resolved].deposits[cat] = count
            end
        end
    end

    -- Replace playerStats (clear and repopulate to preserve AceDB table ref)
    for k in pairs(guildData.playerStats) do
        guildData.playerStats[k] = nil
    end
    for k, v in pairs(newStats) do
        guildData.playerStats[k] = v
    end

    guildData.schemaVersion = 3
    self:ResetHashCache()
end

--- Run migration for all guild data namespaces.
function GBL:MigrateAllGuilds()
    if not self.db or not self.db.global or not self.db.global.guilds then return end
    for _, guildData in pairs(self.db.global.guilds) do
        self:MigrateOccurrenceScheme(guildData)
        self:MigrateSchemaV2ToV3(guildData)
    end
end

function GBL:OnDisable()
    self:UnregisterAllEvents()
    if self.bankOpen then
        self:OnBankClosed()
    end
end

------------------------------------------------------------------------
-- Event handlers
------------------------------------------------------------------------

function GBL:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_event, interactionType)
    if interactionType ~= Enum.PlayerInteractionType.GuildBanker then
        return
    end
    self:OnBankOpened()
end

function GBL:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(_event, interactionType)
    if interactionType ~= Enum.PlayerInteractionType.GuildBanker then
        return
    end
    self:OnBankClosed()
end

function GBL:GUILD_ROSTER_UPDATE()
    -- Update the persistent player→realm mapping
    self:BuildRosterCache()

    -- On the first roster update after login, guild data becomes available.
    -- Broadcast HELLO now so other addon users discover us immediately.
    if not self._sentPostLoginHello and self.db.profile.sync.enabled then
        local guildName = GetGuildInfo("player")
        if guildName then
            self._sentPostLoginHello = true
            self:BroadcastHello(true) -- force past cooldown
        end
    end
end

------------------------------------------------------------------------
-- Bank open/close
------------------------------------------------------------------------

function GBL:OnBankOpened()
    self.bankOpen = true
    self._initialScanComplete = false

    -- GetGuildInfo("player") can return nil if the roster hasn't loaded yet.
    -- Retry a few times before giving up.
    self:WaitForGuildName(function()
        if not self.bankOpen then return end
        self:SendMessage("GBL_BANK_OPENED")
        self:BroadcastHello()

        if self.db.profile.ui.openOnBankOpen and self:IsOfficerRank() then
            self:CreateMainFrame()
            local shown = self.mainFrame.frame and self.mainFrame.frame:IsShown()
            if not shown then
                self.mainFrame:Show()
                self:RefreshUI()
                self._autoOpenedFrame = true
            end
        end

        if self.db.profile.scanning.autoScan then
            self:StartFullScan()
        end

        -- Backfill tab names on old records while bank is open
        self:BackfillTabNames()

        -- Defer transaction scan and compaction so the bank frame renders first
        C_Timer.After(0, function()
            if not self.bankOpen then return end
            self:ScanTransactions(function(newCount)
                if not self.bankOpen then return end
                self:PrintScanResult(newCount)
                self:RefreshUI()
                C_Timer.After(0, function()
                    if not self.bankOpen then return end
                    local guildData = self:GetGuildData()
                    if guildData then
                        self:RunCompaction(guildData)
                    end
                    self._initialScanComplete = true
                    self:StartPeriodicRescan()
                end)
            end)
        end)
    end)
end

--- Wait for GetGuildInfo to return a guild name, then call the callback.
-- Retries up to 10 times at 0.5s intervals. Bails if bank is closed.
-- @param callback function Called once guild name is available
function GBL:WaitForGuildName(callback)
    local maxRetries = 10
    local retryDelay = 0.5

    local function tryResolve(attempt)
        if not self.bankOpen then return end
        if self:GetGuildName() then
            callback()
            return
        end
        if attempt >= maxRetries then
            self:Print("Could not determine guild name. Try reopening the bank.")
            return
        end
        C_Timer.After(retryDelay, function()
            tryResolve(attempt + 1)
        end)
    end

    tryResolve(1)
end

function GBL:OnBankClosed()
    local wasScanning = self.scanInProgress
    self.bankOpen = false
    self.scanInProgress = false
    self._initialScanComplete = false
    self:StopPeriodicRescan()
    self:SendMessage("GBL_BANK_CLOSED")

    if wasScanning then
        self:CancelPendingScan()
    end

    -- Close the ledger window if it was auto-opened with the bank
    if self._autoOpenedFrame and self.mainFrame then
        self.mainFrame:Hide()
        self._autoOpenedFrame = nil
    end

    -- Broadcast HELLO so other guild members know we have fresh data
    self:BroadcastHello()
end

function GBL:IsBankOpen()
    return self.bankOpen
end

------------------------------------------------------------------------
-- Bank close lock (prevent manual close during scan)
------------------------------------------------------------------------

--- Check whether a manual bank close should be blocked.
-- Returns true only if: lock is on, scan is running, and NOT in combat.
-- @return boolean true if the close should be blocked
function GBL:ShouldBlockBankClose()
    if not self.db.profile.scanning.lockBankWhileScanning then
        return false
    end
    if not self.scanInProgress then
        return false
    end
    -- Never block if combat or other forced close
    if InCombatLockdown and InCombatLockdown() then
        return false
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return false
    end
    return true
end

--- Install a pre-hook on the guild bank close function.
-- Blocks manual close while scanning if the lock setting is enabled.
function GBL:InstallBankCloseHook()
    if self._bankCloseHooked then return end
    self._bankCloseHooked = true

    -- Hook C_PlayerInteractionManager.ClearInteraction (10.0.2+)
    if C_PlayerInteractionManager and C_PlayerInteractionManager.ClearInteraction then
        local originalClear = C_PlayerInteractionManager.ClearInteraction
        C_PlayerInteractionManager.ClearInteraction = function(interactionType, ...)
            if interactionType == Enum.PlayerInteractionType.GuildBanker
                and GBL:ShouldBlockBankClose() then
                GBL:Print("Scan in progress — bank close blocked. Uncheck 'Lock while scanning' to disable.")
                return
            end
            return originalClear(interactionType, ...)
        end
    end

    -- Also hook CloseGuildBankFrame if it exists (older API / addons that call it)
    if CloseGuildBankFrame then
        local originalClose = CloseGuildBankFrame
        _G.CloseGuildBankFrame = function(...)
            if GBL:ShouldBlockBankClose() then
                GBL:Print("Scan in progress — bank close blocked.")
                return
            end
            return originalClose(...)
        end
    end
end

------------------------------------------------------------------------
-- Guild info
------------------------------------------------------------------------

function GBL:GetGuildName()
    local guildName = GetGuildInfo("player")
    if guildName then
        self._cachedGuildName = guildName
    end
    return self._cachedGuildName
end

--- Check if the player's guild rank is at or above the officer threshold.
-- GetGuildInfo returns rankIndex (0 = GM, 1 = next rank, etc).
-- Lower index = higher rank.
-- @return boolean true if player rank <= autoOpenMaxRank
function GBL:IsOfficerRank()
    local _, _, rankIndex = GetGuildInfo("player")
    if not rankIndex then return false end
    local threshold = self.db.profile.ui.autoOpenMaxRank or 2
    return rankIndex <= threshold
end

function GBL:GetGuildData()
    local guildName = self:GetGuildName()
    if not guildName then return nil end
    return self.db.global.guilds[guildName]
end

------------------------------------------------------------------------
-- Tab name backfill
------------------------------------------------------------------------

--- Fill in tabName on old transaction records that only have tab numbers.
-- Only works while the bank is open (GetGuildBankTabInfo available).
function GBL:BackfillTabNames()
    local guildData = self:GetGuildData()
    if not guildData then return end

    for _, tx in ipairs(guildData.transactions) do
        if tx.tab and not tx.tabName then
            tx.tabName = self:GetTabName(tx.tab)
        end
        if tx.destTab and not tx.destTabName then
            tx.destTabName = self:GetTabName(tx.destTab)
        end
    end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

function GBL:HandleSlashCommand(input)
    input = input and strtrim(input) or ""
    local command = input:lower()

    if command == "" or command == "show" then
        self:ToggleMainFrame()
    elseif command == "status" then
        self:PrintStatus()
    elseif command == "scan" then
        self:ManualScan()
    elseif command == "help" then
        self:PrintHelp()
    elseif command == "syncdiag" then
        self:PrintSyncDiag()
    elseif command == "synclog" then
        self:ShowSyncLog()
    else
        self:Print("Unknown command: " .. command .. ". Type /gbl help for usage.")
    end
end

function GBL:PrintStatus()
    local guildName = self:GetGuildName() or "Not in a guild"
    local txCount = 0
    local moneyCount = 0
    local guildData = self:GetGuildData()
    if guildData then
        txCount = #guildData.transactions
        moneyCount = #guildData.moneyTransactions
    end

    local lastScan = "Never"
    if self.lastScanTime > 0 then
        lastScan = date("%Y-%m-%d %H:%M:%S", self.lastScanTime)
    end

    self:Print("|cffffcc00GuildBankLedger v" .. self.version .. "|r")
    self:Print("Guild: " .. guildName)
    self:Print("Transactions: " .. txCount)
    self:Print("Money transactions: " .. moneyCount)
    self:Print("Last scan: " .. lastScan)
    self:Print("Bank open: " .. (self.bankOpen and "Yes" or "No"))

    local rescanStatus = "Off"
    if self.db.profile.scanning.rescanEnabled and self:IsPeriodicRescanActive() then
        rescanStatus = format("Every %ds", self.db.profile.scanning.rescanInterval)
    elseif self.db.profile.scanning.rescanEnabled then
        rescanStatus = "Enabled (bank closed)"
    end
    self:Print("Auto re-scan: " .. rescanStatus)
end

function GBL:PrintHelp()
    self:Print("|cffffcc00GuildBankLedger v" .. self.version .. " — Commands:|r")
    self:Print("  /gbl         — Toggle the ledger window")
    self:Print("  /gbl show    — Toggle the ledger window")
    self:Print("  /gbl status  — Show addon status")
    self:Print("  /gbl scan    — Manually scan the guild bank")
    self:Print("  /gbl help    — Show this help message")
end

function GBL:PrintSyncDiag()
    self:Print("|cffffcc00Sync Diagnostics:|r")
    self:Print("Local version: [" .. tostring(self.version) .. "] type=" .. type(self.version))
    local peers = self:GetAllPeers()
    local hasPeers = false
    for name, info in pairs(peers) do
        hasPeers = true
        local pv = info.version
        local match = (pv == self.version) and "|cff00ff00MATCH|r" or "|cffff0000MISMATCH|r"
        self:Print("  " .. name .. ": [" .. tostring(pv) .. "] type=" .. type(pv) .. " " .. match)
    end
    if not hasPeers then
        self:Print("  No peers discovered yet")
    end
end

--- Show the sync audit trail in a copy-pastable editbox.
function GBL:ShowSyncLog()
    local trail = self:GetAuditTrail()
    if #trail == 0 then
        self:Print("No sync log entries yet.")
        return
    end

    local lines = {}
    for i = 1, #trail do
        local entry = trail[i]
        local ts = date("%H:%M:%S", entry.timestamp)
        lines[#lines + 1] = "[" .. ts .. "] " .. entry.message
    end
    local text = table.concat(lines, "\n")

    local AceGUI = LibStub("AceGUI-3.0")
    local frame = AceGUI:Create("Frame")
    frame:SetTitle("GBL Sync Log")
    frame:SetWidth(600)
    frame:SetHeight(400)
    frame:SetLayout("Fill")

    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel("")
    editBox:DisableButton(true)
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:SetText(text)
    frame:AddChild(editBox)
end

function GBL:ManualScan()
    if not self:IsBankOpen() then
        self:Print("Guild bank is not open.")
        return
    end
    if self.scanInProgress then
        self:Print("Scan already in progress.")
        return
    end
    self:StartFullScan()
end

------------------------------------------------------------------------
-- Scan result message
------------------------------------------------------------------------

--- Print the transaction scan result with optional thank-you message.
-- Only prints when new transactions were found.
-- @param newCount number Count of newly recorded transactions
function GBL:PrintScanResult(newCount)
    if not newCount or newCount == 0 then return end

    local guildData = self:GetGuildData()
    local total = 0
    if guildData then
        total = #guildData.transactions + #guildData.moneyTransactions
    end

    local result = format("Recorded %d new transaction%s.",
        newCount, newCount == 1 and "" or "s")

    -- Append thank-you message if configured
    local thankYou = self.db.profile.scanning.thankYouMessage
    if thankYou and thankYou ~= "" then
        local player = UnitName("player") or "you"
        thankYou = thankYou:gsub("{count}", tostring(newCount))
        thankYou = thankYou:gsub("{total}", tostring(total))
        thankYou = thankYou:gsub("{player}", player)
        self:Print(result .. " " .. thankYou)
    else
        self:Print(result)
    end
end
