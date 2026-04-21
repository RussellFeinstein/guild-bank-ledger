------------------------------------------------------------------------
-- GuildBankLedger — Core.lua
-- AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local VERSION = "0.28.3"

local GBL = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceComm-3.0",
    "AceSerializer-3.0"
)

------------------------------------------------------------------------
-- Version comparison
------------------------------------------------------------------------

--- Compare two semantic version strings (major.minor.patch).
-- @param a string|nil First version (e.g. "0.17.0")
-- @param b string|nil Second version
-- @return number -1 if a < b, 0 if equal, 1 if a > b
function GBL:CompareSemver(a, b)
    if a == b then return 0 end
    if not a then return -1 end
    if not b then return 1 end
    local aMajor, aMinor, aPatch = a:match("^(%d+)%.(%d+)%.(%d+)$")
    local bMajor, bMinor, bPatch = b:match("^(%d+)%.(%d+)%.(%d+)$")
    if not aMajor then return -1 end
    if not bMajor then return 1 end
    aMajor, aMinor, aPatch = tonumber(aMajor), tonumber(aMinor), tonumber(aPatch)
    bMajor, bMinor, bPatch = tonumber(bMajor), tonumber(bMinor), tonumber(bPatch)
    if aMajor ~= bMajor then return aMajor < bMajor and -1 or 1 end
    if aMinor ~= bMinor then return aMinor < bMinor and -1 or 1 end
    if aPatch ~= bPatch then return aPatch < bPatch and -1 or 1 end
    return 0
end

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
                knownPeers = {},
                accessControl = {
                    rankThreshold = nil,
                    restrictedMode = nil,
                    configuredBy = nil,
                    configuredAt = 0,
                },
                schemaVersion = 8,
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

    -- Early dedup pass: uses eventCounts from previous session. May miss
    -- duplicates whose prefix+slot lacks ground truth. Definitive cleanup
    -- runs after bank scan refreshes eventCounts (see OnBankOpened).
    if self.db and self.db.global and self.db.global.guilds then
        for _, guildData in pairs(self.db.global.guilds) do
            self:DeduplicateRecords(guildData)
        end
    end

    -- Rebuild UI tabs when access control settings change via sync
    self:RegisterMessage("GBL_ACCESS_CONTROL_CHANGED", "OnAccessControlChanged")

    -- Initialize sync system (M5)
    self:InitSync()
end

function GBL:OnAccessControlChanged()
    if self.tabGroup then
        self:RebuildTabs()
    end
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
            newHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
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
-- @param playerRealms table|nil Optional realm lookup table (used by migration
--   when GetGuildData() is unavailable because guild info hasn't loaded yet)
-- @return string Name-Realm format
function GBL:ResolvePlayerName(name, playerRealms)
    if not name or name == "" then return name end
    -- Already has realm suffix
    if name:find("%-") then return name end
    -- Check provided playerRealms table first (migration path)
    if playerRealms and playerRealms[name] then
        return name .. "-" .. playerRealms[name]
    end
    -- Check persistent roster cache via GetGuildData
    -- (may return nil during early login before guild info loads)
    local guildData = self:GetGuildData()
    if guildData and guildData.playerRealms and guildData.playerRealms[name] then
        return name .. "-" .. guildData.playerRealms[name]
    end
    -- Search all guilds' playerRealms as last resort before local realm fallback
    if self.db and self.db.global and self.db.global.guilds then
        for _, gd in pairs(self.db.global.guilds) do
            if gd.playerRealms and gd.playerRealms[name] then
                return name .. "-" .. gd.playerRealms[name]
            end
        end
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
    -- Pass playerRealms directly — GetGuildData() may return nil during early login
    local pr = guildData.playerRealms
    local function resolve(n) return self:ResolvePlayerName(n, pr) end

    for _, record in ipairs(guildData.transactions) do
        record.player = resolve(record.player)
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                record.scannedBy = "sync:" .. resolve(senderPart)
            else
                record.scannedBy = resolve(record.scannedBy)
            end
        end
    end
    for _, record in ipairs(guildData.moneyTransactions) do
        record.player = resolve(record.player)
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                record.scannedBy = "sync:" .. resolve(senderPart)
            else
                record.scannedBy = resolve(record.scannedBy)
            end
        end
    end

    -- Step 4: Normalize daily/weekly summary player sets
    for _, summary in pairs(guildData.dailySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[resolve(name)] = true
            end
            summary.players = newPlayers
        end
    end
    for _, summary in pairs(guildData.weeklySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[resolve(name)] = true
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
            guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
        end
    end

    -- Step 7: Merge playerStats
    local newStats = {}
    for name, stats in pairs(guildData.playerStats) do
        local resolved = resolve(name)
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

--- Migrate occurrence indices from cross-slot prefix counting to per-slot counting.
-- v0.12.0 introduced cross-slot prefix counting to prevent false-positive dedup,
-- but this causes occurrence index shift when new same-prefix records appear
-- between rescans (e.g. withdrawing the same item at different times). Per-slot
-- counting is safe because the < 3600 timestamp check in IsDuplicate correctly
-- distinguishes genuinely different events from the same event seen in adjacent
-- hour slots.
-- Does NOT remove records — bug duplicates and genuine same-hour duplicates are
-- indistinguishable (both share the same baseHash and near-identical timestamps).
-- @param guildData table Guild data from AceDB
function GBL:MigrateOccurrenceToPerSlot(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 4 then return end

    -- Collect all records
    local allRecords = {}
    for _, tx in ipairs(guildData.transactions or {}) do
        allRecords[#allRecords + 1] = tx
    end
    for _, tx in ipairs(guildData.moneyTransactions or {}) do
        allRecords[#allRecords + 1] = tx
    end

    if #allRecords == 0 then
        guildData.schemaVersion = 4
        return
    end

    -- Group records by baseHash (prefix + timeSlot, strip old :N suffix)
    local groups = {}
    for _, record in ipairs(allRecords) do
        local baseHash = record.id and record.id:gsub(":%d+$", "") or ""
        if not groups[baseHash] then groups[baseHash] = {} end
        groups[baseHash][#groups[baseHash] + 1] = record
    end

    -- Sort each group by timestamp (tiebreak on old ID for determinism)
    -- and reassign sequential per-slot occurrence indices
    for _, group in pairs(groups) do
        table.sort(group, function(a, b)
            if (a.timestamp or 0) == (b.timestamp or 0) then
                return (a.id or "") < (b.id or "")
            end
            return (a.timestamp or 0) < (b.timestamp or 0)
        end)

        for i, record in ipairs(group) do
            local occ = i - 1
            local baseHash = record.id and record.id:gsub(":%d+$", "") or ""
            record.id = baseHash .. ":" .. occ
            record._occurrence = occ
        end
    end

    -- Rebuild seenTxHashes from scratch
    for k in pairs(guildData.seenTxHashes) do
        guildData.seenTxHashes[k] = nil
    end
    for _, record in ipairs(allRecords) do
        if record.id then
            guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
        end
    end

    guildData.schemaVersion = 4
    self:ResetHashCache()
end

--- Remove bug-duplicate records created by the occurrence index shift bug.
-- Groups records by baseHash, identifies the anchor count from the earliest
-- local scan (which is always correct — no prior records to shift against),
-- and removes all excess records. Rebuilds occurrence indices, seenTxHashes,
-- and playerStats from surviving records.
-- @param guildData table Guild data from AceDB
-- @return number Number of records removed
function GBL:MigrateDeduplicateRecords(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 5 then return 0 end

    local totalRemoved = 0

    -- Process both item and money transactions
    for _, storageKey in ipairs({ "transactions", "moneyTransactions" }) do
        local records = guildData[storageKey]
        if records and #records > 0 then
            -- Group by baseHash (strip :N occurrence suffix from id)
            local groups = {}
            local groupOrder = {}
            for _, record in ipairs(records) do
                local baseHash = record.id and record.id:gsub(":%d+$", "") or ""
                if not groups[baseHash] then
                    groups[baseHash] = {}
                    groupOrder[#groupOrder + 1] = baseHash
                end
                groups[baseHash][#groups[baseHash] + 1] = record
            end

            -- For each group, determine anchor count and filter
            local surviving = {}
            for _, baseHash in ipairs(groupOrder) do
                local group = groups[baseHash]
                if #group <= 1 then
                    -- Single record, no duplicates possible
                    surviving[#surviving + 1] = group[1]
                else
                    -- Sub-group by scanTime
                    local byScanTime = {}
                    local scanOrder = {}
                    for _, record in ipairs(group) do
                        local st = record.scanTime or 0
                        if not byScanTime[st] then
                            byScanTime[st] = {}
                            scanOrder[#scanOrder + 1] = st
                        end
                        byScanTime[st][#byScanTime[st] + 1] = record
                    end
                    table.sort(scanOrder)

                    -- Find anchor: earliest LOCAL scan (scannedBy not "sync:...")
                    local anchorCount = nil
                    local anchorScanTime = nil
                    for _, st in ipairs(scanOrder) do
                        local subGroup = byScanTime[st]
                        local isLocal = false
                        for _, rec in ipairs(subGroup) do
                            if not rec.scannedBy
                                or not rec.scannedBy:match("^sync:") then
                                isLocal = true
                                break
                            end
                        end
                        if isLocal then
                            anchorCount = #subGroup
                            anchorScanTime = st
                            break
                        end
                    end

                    -- Fallback: no local scans, use smallest sub-group
                    if not anchorCount then
                        local minCount = #group
                        for _, st in ipairs(scanOrder) do
                            if #byScanTime[st] < minCount then
                                minCount = #byScanTime[st]
                                anchorScanTime = st
                            end
                        end
                        anchorCount = minCount
                    end

                    -- Keep records from anchor sub-group
                    if #group > anchorCount then
                        local anchorRecords = byScanTime[anchorScanTime]
                        for _, rec in ipairs(anchorRecords) do
                            surviving[#surviving + 1] = rec
                        end
                        totalRemoved = totalRemoved + (#group - anchorCount)
                    else
                        -- No duplicates in this group
                        for _, rec in ipairs(group) do
                            surviving[#surviving + 1] = rec
                        end
                    end
                end
            end

            -- Replace the storage array (preserve AceDB table ref)
            for i = #records, 1, -1 do
                records[i] = nil
            end
            for i, rec in ipairs(surviving) do
                records[i] = rec
            end
        end
    end

    if totalRemoved > 0 then
        -- Rebuild occurrence indices for surviving records
        local allRecords = {}
        for _, tx in ipairs(guildData.transactions or {}) do
            allRecords[#allRecords + 1] = tx
        end
        for _, tx in ipairs(guildData.moneyTransactions or {}) do
            allRecords[#allRecords + 1] = tx
        end

        local idGroups = {}
        for _, record in ipairs(allRecords) do
            local baseHash = self:ComputeTxHash(record)
            if not idGroups[baseHash] then idGroups[baseHash] = {} end
            idGroups[baseHash][#idGroups[baseHash] + 1] = record
        end
        for _, idGroup in pairs(idGroups) do
            table.sort(idGroup, function(a, b)
                if (a.timestamp or 0) == (b.timestamp or 0) then
                    return (a.scanTime or 0) < (b.scanTime or 0)
                end
                return (a.timestamp or 0) < (b.timestamp or 0)
            end)
            for i, record in ipairs(idGroup) do
                local occ = i - 1
                record._occurrence = occ
                record.id = self:ComputeTxHash(record) .. ":" .. occ
            end
        end

        -- Rebuild seenTxHashes
        for k in pairs(guildData.seenTxHashes) do
            guildData.seenTxHashes[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.id then
                guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
            end
        end

        -- Rebuild playerStats from scratch
        local statsDefaults = {
            withdrawals = {}, deposits = {},
            totalWithdrawCount = 0, totalDepositCount = 0,
            moneyWithdrawn = 0, moneyDeposited = 0,
            firstSeen = 0, lastSeen = 0,
        }
        for k in pairs(guildData.playerStats) do
            guildData.playerStats[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.player then
                if not guildData.playerStats[record.player]
                    or not guildData.playerStats[record.player].totalWithdrawCount then
                    guildData.playerStats[record.player] = {}
                    for dk, dv in pairs(statsDefaults) do
                        guildData.playerStats[record.player][dk] =
                            type(dv) == "table" and {} or dv
                    end
                end
                self:UpdatePlayerStats(record, guildData)
            end
        end
    end

    guildData.schemaVersion = 5
    self:ResetHashCache()
    return totalRemoved
end

--- Remove duplicate records via full two-pass cleanup.
-- Pass 1: re-runs same-slot dedup (v4→v5 logic) to catch duplicates created
-- by the counting bug between the v0.14.2 migration and this fix.
-- Pass 2: cross-slot dedup via PREFIX grouping (slot-independent) with
-- timestamp proximity clustering to catch duplicates the v4→v5 migration
-- missed (it grouped by baseHash which includes the slot).
-- @param guildData table Guild data from AceDB
-- @return number Number of records removed
function GBL:MigrateCrossSlotDedup(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 6 then return 0 end

    -- Pass 1: re-run same-slot dedup — the counting bug continued creating
    -- new duplicates between v0.14.2 (which ran this pass once) and now.
    local savedSchema = guildData.schemaVersion
    guildData.schemaVersion = 4
    local pass1Removed = self:MigrateDeduplicateRecords(guildData)
    -- MigrateDeduplicateRecords sets schemaVersion=5; continue to pass 2

    local totalRemoved = 0

    for _, storageKey in ipairs({ "transactions", "moneyTransactions" }) do
        local records = guildData[storageKey]
        if records and #records > 0 then
            -- Group by prefix (slot-independent)
            local groups = {}
            local groupOrder = {}
            for _, record in ipairs(records) do
                local prefix = self:BuildTxPrefix(record)
                if not groups[prefix] then
                    groups[prefix] = {}
                    groupOrder[#groupOrder + 1] = prefix
                end
                groups[prefix][#groups[prefix] + 1] = record
            end

            local surviving = {}
            for _, prefix in ipairs(groupOrder) do
                local group = groups[prefix]
                if #group <= 1 then
                    surviving[#surviving + 1] = group[1]
                else
                    -- Sort by timestamp to identify event clusters
                    table.sort(group, function(a, b)
                        return (a.timestamp or 0) < (b.timestamp or 0)
                    end)

                    -- Cluster records by timestamp proximity (< 3600 = same event)
                    local clusters = {}
                    local currentCluster = { group[1] }
                    for i = 2, #group do
                        local diff = math.abs(
                            (group[i].timestamp or 0) - (group[i-1].timestamp or 0))
                        if diff < 3600 then
                            currentCluster[#currentCluster + 1] = group[i]
                        else
                            clusters[#clusters + 1] = currentCluster
                            currentCluster = { group[i] }
                        end
                    end
                    clusters[#clusters + 1] = currentCluster

                    -- Within each cluster, find anchor count from earliest local scan
                    for _, cluster in ipairs(clusters) do
                        if #cluster <= 1 then
                            surviving[#surviving + 1] = cluster[1]
                        else
                            -- Sub-group by scanTime
                            local byScanTime = {}
                            local scanOrder = {}
                            for _, rec in ipairs(cluster) do
                                local st = rec.scanTime or 0
                                if not byScanTime[st] then
                                    byScanTime[st] = {}
                                    scanOrder[#scanOrder + 1] = st
                                end
                                byScanTime[st][#byScanTime[st] + 1] = rec
                            end
                            table.sort(scanOrder)

                            -- Anchor: earliest local scan
                            local anchorCount, anchorScanTime
                            for _, st in ipairs(scanOrder) do
                                local subGroup = byScanTime[st]
                                for _, rec in ipairs(subGroup) do
                                    if not rec.scannedBy
                                        or not rec.scannedBy:match("^sync:") then
                                        anchorCount = #subGroup
                                        anchorScanTime = st
                                        break
                                    end
                                end
                                if anchorCount then break end
                            end

                            -- Fallback: no local scans, use smallest sub-group
                            if not anchorCount then
                                local minCount = #cluster
                                for _, st in ipairs(scanOrder) do
                                    if #byScanTime[st] < minCount then
                                        minCount = #byScanTime[st]
                                        anchorScanTime = st
                                    end
                                end
                                anchorCount = minCount
                            end

                            if #cluster > anchorCount then
                                local anchorRecords = byScanTime[anchorScanTime]
                                for _, rec in ipairs(anchorRecords) do
                                    surviving[#surviving + 1] = rec
                                end
                                totalRemoved = totalRemoved + (#cluster - anchorCount)
                            else
                                for _, rec in ipairs(cluster) do
                                    surviving[#surviving + 1] = rec
                                end
                            end
                        end
                    end
                end
            end

            -- Replace storage array (preserve AceDB table ref)
            for i = #records, 1, -1 do records[i] = nil end
            for i, rec in ipairs(surviving) do records[i] = rec end
        end
    end

    if totalRemoved > 0 then
        -- Rebuild occurrence indices, seenTxHashes, and playerStats
        local allRecords = {}
        for _, tx in ipairs(guildData.transactions or {}) do
            allRecords[#allRecords + 1] = tx
        end
        for _, tx in ipairs(guildData.moneyTransactions or {}) do
            allRecords[#allRecords + 1] = tx
        end

        -- Reassign occurrence indices per baseHash
        local idGroups = {}
        for _, record in ipairs(allRecords) do
            local baseHash = self:ComputeTxHash(record)
            if not idGroups[baseHash] then idGroups[baseHash] = {} end
            idGroups[baseHash][#idGroups[baseHash] + 1] = record
        end
        for _, idGroup in pairs(idGroups) do
            table.sort(idGroup, function(a, b)
                if (a.timestamp or 0) == (b.timestamp or 0) then
                    return (a.scanTime or 0) < (b.scanTime or 0)
                end
                return (a.timestamp or 0) < (b.timestamp or 0)
            end)
            for i, record in ipairs(idGroup) do
                local occ = i - 1
                record._occurrence = occ
                record.id = self:ComputeTxHash(record) .. ":" .. occ
            end
        end

        -- Rebuild seenTxHashes
        for k in pairs(guildData.seenTxHashes) do
            guildData.seenTxHashes[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.id then
                guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
            end
        end

        -- Rebuild playerStats
        local statsDefaults = {
            withdrawals = {}, deposits = {},
            totalWithdrawCount = 0, totalDepositCount = 0,
            moneyWithdrawn = 0, moneyDeposited = 0,
            firstSeen = 0, lastSeen = 0,
        }
        for k in pairs(guildData.playerStats) do
            guildData.playerStats[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.player then
                if not guildData.playerStats[record.player]
                    or not guildData.playerStats[record.player].totalWithdrawCount then
                    guildData.playerStats[record.player] = {}
                    for dk, dv in pairs(statsDefaults) do
                        guildData.playerStats[record.player][dk] =
                            type(dv) == "table" and {} or dv
                    end
                end
                self:UpdatePlayerStats(record, guildData)
            end
        end
    end

    guildData.schemaVersion = 6
    self:ResetHashCache()
    return totalRemoved + pass1Removed
end

--- Migrate v6 → v7: add accessControl field for GM-configurable rank gating.
function GBL:MigrateAccessControl(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 7 then return end
    if not guildData.accessControl then
        guildData.accessControl = {
            rankThreshold = nil,
            restrictedMode = nil,
            configuredBy = nil,
            configuredAt = 0,
        }
    end
    guildData.schemaVersion = 7
end

--- Repair records with epoch-0 timestamps (schema 7 → 8).
-- Scans all transactions for invalid timestamps, attempts recovery from
-- the timeSlot encoded in the record ID, then falls back to GetServerTime().
-- Also cleans up compacted summaries attributed to 1970-01-01.
function GBL:MigrateRepairEpochTimestamps(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 8 then return end

    local repaired = 0
    local function repairRecords(records)
        for _, record in ipairs(records or {}) do
            if not self:IsValidTimestamp(record.timestamp) then
                -- Try to recover from ID timeSlot
                local recovered = false
                if record.id then
                    local timeSlot = record.id:match("|(%d+):%d+$")
                    if timeSlot then
                        local ts = tonumber(timeSlot) * 3600
                        if self:IsValidTimestamp(ts) then
                            record.timestamp = ts
                            recovered = true
                        end
                    end
                end
                if not recovered then
                    record.timestamp = GetServerTime()
                end
                -- Rebuild ID with corrected timestamp
                local baseHash = self:ComputeTxHash(record)
                local occ = record._occurrence or 0
                record.id = baseHash .. ":" .. occ
                repaired = repaired + 1
            end
        end
    end

    repairRecords(guildData.transactions)
    repairRecords(guildData.moneyTransactions)

    -- Clean up compacted data attributed to epoch-0 dates
    if guildData.dailySummaries then
        guildData.dailySummaries["1970-01-01"] = nil
    end
    if guildData.weeklySummaries then
        for key in pairs(guildData.weeklySummaries) do
            if key:find("^1970%-") then
                guildData.weeklySummaries[key] = nil
            end
        end
    end

    -- Rebuild seenTxHashes from corrected records
    if repaired > 0 then
        local newHashes = {}
        for _, record in ipairs(guildData.transactions or {}) do
            if record.id then
                newHashes[record.id] = self:IsValidTimestamp(record.timestamp)
                    and record.timestamp or GetServerTime()
            end
        end
        for _, record in ipairs(guildData.moneyTransactions or {}) do
            if record.id then
                newHashes[record.id] = self:IsValidTimestamp(record.timestamp)
                    and record.timestamp or GetServerTime()
            end
        end
        for k in pairs(guildData.seenTxHashes) do
            guildData.seenTxHashes[k] = nil
        end
        for k, v in pairs(newHashes) do
            guildData.seenTxHashes[k] = v
        end
    end

    guildData.schemaVersion = 8
end

--- Run migration for all guild data namespaces.
function GBL:MigrateAllGuilds()
    if not self.db or not self.db.global or not self.db.global.guilds then return end
    for _, guildData in pairs(self.db.global.guilds) do
        self:MigrateOccurrenceScheme(guildData)
        self:MigrateSchemaV2ToV3(guildData)
        self:MigrateOccurrenceToPerSlot(guildData)
        self:MigrateDeduplicateRecords(guildData)
        self:MigrateCrossSlotDedup(guildData)
        self:MigrateAccessControl(guildData)
        self:MigrateRepairEpochTimestamps(guildData)
    end
end

--- Repair player names after roster becomes available.
-- Fixes records that got the wrong realm during early migration (before
-- GUILD_ROSTER_UPDATE fired). Runs once per session after roster loads.
-- Idempotent — safe to call multiple times.
function GBL:RepairPlayerNames()
    local guildData = self:GetGuildData()
    if not guildData then return end

    local pr = guildData.playerRealms or {}
    local fixed = 0

    -- Check if any records need repair (bare names or wrong realm)
    for _, record in ipairs(guildData.transactions) do
        local resolved = self:ResolvePlayerName(record.player, pr)
        if resolved ~= record.player then
            record.player = resolved
            fixed = fixed + 1
        end
    end
    for _, record in ipairs(guildData.moneyTransactions) do
        local resolved = self:ResolvePlayerName(record.player, pr)
        if resolved ~= record.player then
            record.player = resolved
            fixed = fixed + 1
        end
    end

    if fixed == 0 then return end

    -- Recompute IDs and rebuild hashes (same as migration steps 5-7)
    local allRecords = {}
    for _, tx in ipairs(guildData.transactions) do
        allRecords[#allRecords + 1] = tx
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        allRecords[#allRecords + 1] = tx
    end

    local groups = {}
    for _, record in ipairs(allRecords) do
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

    for k in pairs(guildData.seenTxHashes) do
        guildData.seenTxHashes[k] = nil
    end
    for _, record in ipairs(allRecords) do
        if record.id then
            guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
        end
    end

    -- Merge duplicate playerStats
    local resolve = function(n) return self:ResolvePlayerName(n, pr) end
    local newStats = {}
    for name, stats in pairs(guildData.playerStats) do
        local resolved = resolve(name)
        if newStats[resolved] then
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
            for cat, count in pairs(stats.withdrawals or {}) do
                existing.withdrawals[cat] = (existing.withdrawals[cat] or 0) + count
            end
            for cat, count in pairs(stats.deposits or {}) do
                existing.deposits[cat] = (existing.deposits[cat] or 0) + count
            end
        else
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
    for k in pairs(guildData.playerStats) do
        guildData.playerStats[k] = nil
    end
    for k, v in pairs(newStats) do
        guildData.playerStats[k] = v
    end

    -- Normalize summary player sets
    for _, summary in pairs(guildData.dailySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[resolve(name)] = true
            end
            summary.players = newPlayers
        end
    end
    for _, summary in pairs(guildData.weeklySummaries or {}) do
        if summary.players then
            local newPlayers = {}
            for name in pairs(summary.players) do
                newPlayers[resolve(name)] = true
            end
            summary.players = newPlayers
        end
    end

    self:ResetHashCache()
    self:AddAuditEntry("Repaired " .. fixed .. " player names after roster load")
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

    -- One-time repair: fix player names that got wrong realm during early migration
    if not self._playerNamesRepaired then
        self._playerNamesRepaired = true
        self:RepairPlayerNames()
    end

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

        if self.db.profile.ui.openOnBankOpen and self:GetAccessLevel() ~= "sync_only" then
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
                        -- Post-scan dedup: eventCounts was refreshed by
                        -- StoreBatchRecords during scanning, so
                        -- CleanupWithEventCounts now has fresh API ground
                        -- truth to detect duplicates from prior sync.
                        local removed = self:DeduplicateRecords(guildData)
                        if removed > 0 then
                            self:AddAuditEntry("Post-scan cleanup: removed "
                                .. removed .. " duplicate record(s)")
                            self:RefreshUI()
                        end
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
    -- Clear session-local batch caches so next bank open starts fresh
    self._lastTabBatchCounts = {}
    self._lastMoneyBatchCounts = nil
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

--- Check if the player is the Guild Master (rank 0).
-- @return boolean true if rank index is exactly 0
function GBL:IsGuildMaster()
    local _, _, rankIndex = GetGuildInfo("player")
    if not rankIndex then return false end
    return rankIndex == 0
end

--- Determine the player's access level based on guild-wide accessControl settings.
-- @return string "full", "own_transactions", or "sync_only"
function GBL:GetAccessLevel()
    if self:IsGuildMaster() then return "full" end

    local guildData = self:GetGuildData()
    if not guildData then return "full" end

    local ac = guildData.accessControl
    if not ac or not ac.rankThreshold then return "full" end

    local _, _, rankIndex = GetGuildInfo("player")
    if not rankIndex then return "full" end

    if rankIndex <= ac.rankThreshold then
        return "full"
    end

    return ac.restrictedMode or "sync_only"
end

--- Convenience check for full addon access.
-- @return boolean true if the player has unrestricted access
function GBL:HasFullAccess()
    return self:GetAccessLevel() == "full"
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
    elseif command == "cleanup" then
        self:RunCleanup()
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
    self:Print("  /gbl cleanup — Remove duplicate records from the database")
    self:Print("  /gbl help    — Show this help message")
end

--- Run both dedup passes (same-slot + cross-slot) without schema guards.
-- Called on every login/reload and after each sync receive to ensure
-- dirty data from any source is cleaned up promptly.
-- @param guildData table Guild data from AceDB
-- @return number Number of duplicate records removed
function GBL:DeduplicateRecords(guildData)
    if not guildData then return 0 end

    -- Legacy anchor-based cleanup: only for data that hasn't been migrated yet.
    -- Once eventCounts is populated, CleanupWithEventCounts is authoritative.
    local legacyRemoved = 0
    if (guildData.schemaVersion or 0) < 6 then
        local savedSchema = guildData.schemaVersion
        guildData.schemaVersion = 5
        legacyRemoved = self:MigrateCrossSlotDedup(guildData)
        if savedSchema > 6 then guildData.schemaVersion = savedSchema end
    end

    -- Count-based cleanup (uses API-observed ground truth)
    local countRemoved = self:CleanupWithEventCounts(guildData)

    return legacyRemoved + countRemoved
end

--- Remove excess records using persisted eventCounts as ground truth.
-- Groups records by prefix, clusters by timestamp proximity, then trims
-- each cluster to the max known eventCount for its baseHash (±1 slot).
-- Safe default: clusters with no eventCount data are never trimmed.
-- @param guildData table Guild data from AceDB
-- @return number Total records removed
function GBL:CleanupWithEventCounts(guildData)
    if not guildData or not guildData.eventCounts
        or not next(guildData.eventCounts) then
        return 0
    end

    local totalRemoved = 0

    for _, storageKey in ipairs({ "transactions", "moneyTransactions" }) do
        local records = guildData[storageKey]
        if records and #records > 0 then
            -- Group by prefix (slot-independent)
            local groups = {}
            local groupOrder = {}
            for _, record in ipairs(records) do
                local prefix = self:BuildTxPrefix(record)
                if not groups[prefix] then
                    groups[prefix] = {}
                    groupOrder[#groupOrder + 1] = prefix
                end
                groups[prefix][#groups[prefix] + 1] = record
            end

            local surviving = {}
            for _, prefix in ipairs(groupOrder) do
                local group = groups[prefix]
                if #group <= 1 then
                    surviving[#surviving + 1] = group[1]
                else
                    -- Sort by timestamp to identify event clusters
                    table.sort(group, function(a, b)
                        return (a.timestamp or 0) < (b.timestamp or 0)
                    end)

                    -- Cluster records by timestamp proximity (< 3600 = same hour event)
                    local clusters = {}
                    local currentCluster = { group[1] }
                    for i = 2, #group do
                        local diff = math.abs(
                            (group[i].timestamp or 0) - (group[i-1].timestamp or 0))
                        if diff < 3600 then
                            currentCluster[#currentCluster + 1] = group[i]
                        else
                            clusters[#clusters + 1] = currentCluster
                            currentCluster = { group[i] }
                        end
                    end
                    clusters[#clusters + 1] = currentCluster

                    for _, cluster in ipairs(clusters) do
                        -- Find max eventCount across all relevant baseHashes (±1 slot)
                        local slotsChecked = {}
                        for _, rec in ipairs(cluster) do
                            local slot = math.floor((rec.timestamp or GetServerTime()) / 3600)
                            slotsChecked[slot] = true
                        end

                        local maxKnownCount = 0
                        for slot in pairs(slotsChecked) do
                            for s = slot - 1, slot + 1 do
                                local baseHash = prefix .. s
                                local entry = guildData.eventCounts[baseHash]
                                if entry and type(entry) == "table"
                                    and type(entry.count) == "number"
                                    and entry.count > maxKnownCount then
                                    maxKnownCount = entry.count
                                end
                            end
                        end

                        if maxKnownCount == 0 or #cluster <= maxKnownCount then
                            -- No count data or within bounds: keep all
                            for _, rec in ipairs(cluster) do
                                surviving[#surviving + 1] = rec
                            end
                        else
                            -- Trim to maxKnownCount, preferring oldest by scanTime
                            table.sort(cluster, function(a, b)
                                return (a.scanTime or 0) < (b.scanTime or 0)
                            end)
                            for i = 1, maxKnownCount do
                                surviving[#surviving + 1] = cluster[i]
                            end
                            totalRemoved = totalRemoved + (#cluster - maxKnownCount)
                        end
                    end
                end
            end

            -- Replace storage array (preserve AceDB table ref)
            for i = #records, 1, -1 do records[i] = nil end
            for i, rec in ipairs(surviving) do records[i] = rec end
        end
    end

    if totalRemoved > 0 then
        -- Rebuild occurrence indices, seenTxHashes, and playerStats
        local allRecords = {}
        for _, tx in ipairs(guildData.transactions or {}) do
            allRecords[#allRecords + 1] = tx
        end
        for _, tx in ipairs(guildData.moneyTransactions or {}) do
            allRecords[#allRecords + 1] = tx
        end

        -- Reassign occurrence indices per baseHash
        local idGroups = {}
        for _, record in ipairs(allRecords) do
            local baseHash = self:ComputeTxHash(record)
            if not idGroups[baseHash] then idGroups[baseHash] = {} end
            idGroups[baseHash][#idGroups[baseHash] + 1] = record
        end
        for _, idGroup in pairs(idGroups) do
            table.sort(idGroup, function(a, b)
                if (a.timestamp or 0) == (b.timestamp or 0) then
                    return (a.scanTime or 0) < (b.scanTime or 0)
                end
                return (a.timestamp or 0) < (b.timestamp or 0)
            end)
            for i, record in ipairs(idGroup) do
                local occ = i - 1
                record._occurrence = occ
                record.id = self:ComputeTxHash(record) .. ":" .. occ
            end
        end

        -- Rebuild seenTxHashes
        for k in pairs(guildData.seenTxHashes) do
            guildData.seenTxHashes[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.id then
                guildData.seenTxHashes[record.id] = self:IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()
            end
        end

        -- Rebuild playerStats
        local statsDefaults = {
            withdrawals = {}, deposits = {},
            totalWithdrawCount = 0, totalDepositCount = 0,
            moneyWithdrawn = 0, moneyDeposited = 0,
            firstSeen = 0, lastSeen = 0,
        }
        for k in pairs(guildData.playerStats) do
            guildData.playerStats[k] = nil
        end
        for _, record in ipairs(allRecords) do
            if record.player then
                if not guildData.playerStats[record.player]
                    or not guildData.playerStats[record.player].totalWithdrawCount then
                    guildData.playerStats[record.player] = {}
                    for dk, dv in pairs(statsDefaults) do
                        guildData.playerStats[record.player][dk] =
                            type(dv) == "table" and {} or dv
                    end
                end
                self:UpdatePlayerStats(record, guildData)
            end
        end

        self:ResetHashCache()
    end

    return totalRemoved
end

--- Manually run the deduplication cleanup with user feedback.
function GBL:RunCleanup()
    local guildData = self:GetGuildData()
    if not guildData then
        self:Print("No guild data found.")
        return
    end

    local totalRemoved = self:DeduplicateRecords(guildData)

    if totalRemoved > 0 then
        self:Print(format("Cleanup: removed %d duplicate record%s (%d item tx, %d money tx remain).",
            totalRemoved, totalRemoved == 1 and "" or "s",
            #guildData.transactions, #guildData.moneyTransactions))
    else
        self:Print("Cleanup: no duplicates found.")
    end
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
