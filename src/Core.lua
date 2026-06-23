------------------------------------------------------------------------
-- GuildBankLedger — Core.lua
-- AceAddon bootstrap, lifecycle, slash commands, bank open/close detection
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local VERSION = "0.34.1"
local DEV_BUILD = nil  -- MUST be nil on main; set to a string (e.g. "sync") on dev branches

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
    -- Strip an optional pre-release suffix (e.g. "-dev.<id>") so a dev build
    -- compares as the same release line as its base. The wire-side equality
    -- check at Sync.lua HandleHello is unaffected because it uses ~= directly.
    local aBase = a:match("^([^-]+)") or a
    local bBase = b:match("^([^-]+)") or b
    local aMajor, aMinor, aPatch = aBase:match("^(%d+)%.(%d+)%.(%d+)$")
    local bMajor, bMinor, bPatch = bBase:match("^(%d+)%.(%d+)%.(%d+)$")
    if not aMajor then return -1 end
    if not bMajor then return 1 end
    aMajor, aMinor, aPatch = tonumber(aMajor), tonumber(aMinor), tonumber(aPatch)
    bMajor, bMinor, bPatch = tonumber(bMajor), tonumber(bMinor), tonumber(bPatch)
    if aMajor ~= bMajor then return aMajor < bMajor and -1 or 1 end
    if aMinor ~= bMinor then return aMinor < bMinor and -1 or 1 end
    if aPatch ~= bPatch then return aPatch < bPatch and -1 or 1 end
    return 0
end

------------------------------------------------------------------------
-- Dev-build identity
------------------------------------------------------------------------

-- Internal: tests set self._testDevBuild on the GBL instance to override
-- DEV_BUILD without touching the file. Production code never sets it.
function GBL:_GetDevBuildId()
    return self._testDevBuild or DEV_BUILD
end

--- Returns the version string used on the wire and in user-visible labels.
-- When DEV_BUILD is set, appends "-dev.<id>" so the existing exact-match
-- rejection at Sync.lua's HandleHello refuses to sync with production peers.
function GBL:GetSyncVersion()
    local dev = self:_GetDevBuildId()
    if dev then return VERSION .. "-dev." .. dev end
    return VERSION
end

--- Returns true when the addon is built as an isolated dev build.
function GBL:IsDevBuild()
    return self:_GetDevBuildId() ~= nil
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
                -- stockAlerts: reserved for planned v1.3.0 low-stock alerts feature
                -- (threshold-based chat pings). Semantically distinct from stockReserves
                -- below (which holds sort/restock target counts). Do not repurpose.
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
                bankLayout = {
                    version = 0,
                    updatedBy = nil,
                    updatedAt = 0,
                    tabs = {},
                },
                stockReserves = {},
                restock = { items = {}, budget = 0 },
                sortAccess = {
                    rankThreshold = nil,  -- nil = GM-only; N = rank index N and above
                    delegates = {},       -- ["Char-Realm"] = true
                    updatedBy = nil,
                    updatedAt = 0,
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
        sync = { enabled = true, autoSync = true, chatLog = false, debugChat = false },
        sort = { chatLog = false, debugChat = false },
        system = { chatLog = false, debugChat = false },
        filters = { defaultDays = 7, defaultCategory = "ALL" },
        chatFilters = { muteAmbientNPCs = false },
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
    self.version = self:GetSyncVersion()

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

    -- Refresh layout-dependent tabs when a newer bank layout arrives via sync
    self:RegisterMessage("GBL_LAYOUT_CHANGED", "OnBankLayoutChanged")

    -- Initialize sync system (M5)
    self:InitSync()

    if self:IsDevBuild() then
        self:Print("|cffffcc00v" .. self.version .. "|r |cffff8800-- sync isolated from production peers|r")
    end
end

function GBL:OnAccessControlChanged()
    if self.tabGroup then
        self:RebuildTabs()
    end
end

--- A newer bank layout arrived via sync (advertise-and-pull). Refresh whichever
-- layout-dependent tab is open; each refresh self-guards on the active tab.
function GBL:OnBankLayoutChanged()
    if self.RefreshLayoutTab then self:RefreshLayoutTab() end
    if self.RefreshSortTab then self:RefreshSortTab() end
    -- The Restock list is layout-driven, so a new layout/reserve must refresh it too.
    if self.RefreshRestockTab then self:RefreshRestockTab() end
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
            newHashes[record.id] = self:SafeRecordTimestamp(record)
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
-- Priority: already-qualified → explicit playerRealms arg → current guild's
-- roster cache → local realm fallback. The cross-guild fallback that used
-- to iterate self.db.global.guilds was removed: bare names from a different
-- guild's roster could resolve to a wrong realm for users who'd been in
-- multiple guilds. Migrations pass the per-guild table explicitly via the
-- playerRealms arg so they remain correct.
-- @param name string Bare or already-qualified name
-- @param playerRealms table|nil Optional per-guild realm lookup (migration path)
-- @return string Name-Realm format
function GBL:ResolvePlayerName(name, playerRealms)
    if not name or name == "" then return name end
    -- Already has realm suffix
    if name:find("%-") then return name end
    -- Check provided playerRealms table first (migration path)
    if playerRealms and type(playerRealms[name]) == "string" then
        return name .. "-" .. playerRealms[name]
    end
    -- Check persistent roster cache via GetGuildData
    -- (may return nil during early login before guild info loads)
    local guildData = self:GetGuildData()
    if guildData and guildData.playerRealms
       and type(guildData.playerRealms[name]) == "string" then
        return name .. "-" .. guildData.playerRealms[name]
    end
    -- Fallback: append local realm (always normalized via GetLocalRealm)
    return name .. "-" .. self:GetLocalRealm()
end

--- Strip realm suffix from a character name.
-- For peer matching and filter comparison only - records should always
-- store the full Name-Realm format.
-- @param name string Character name, possibly realm-qualified
-- @return string Base name without realm suffix
function GBL:StripRealm(name)
    if not name then return "" end
    return name:match("^([^%-]+)") or name
end

--- Normalize a realm name to its no-space form.
-- Real WoW APIs return realm in two shapes: GetNormalizedRealmName() drops
-- spaces ("AeriePeak"), while GetRealmName() and the realm portion of a
-- hyphenated name from GetGuildRosterInfo can keep them ("Aerie Peak").
-- Persisted realm strings must use the normalized form so that records
-- arriving from sync (potentially raw realm) collapse against locally-scanned
-- records (already normalized via the GetNormalizedRealmName fallback path).
-- @param realm string|nil Realm name in any form
-- @return string|nil Realm with whitespace stripped
function GBL:NormalizeRealm(realm)
    if not realm or realm == "" then return realm end
    return (realm:gsub("%s", ""))
end

--- Return the local realm name in normalized (no-space) form.
-- Centralizes the GetNormalizedRealmName -> GetRealmName fallback so all
-- callers use identical logic and cannot drift apart.
-- @return string Normalized local realm name, or "UnknownRealm" if neither API resolves
function GBL:GetLocalRealm()
    local realm = GetNormalizedRealmName()
        or (GetRealmName and GetRealmName() and GetRealmName():gsub("%s", ""))
    return realm or "UnknownRealm"
end

--- True when the given realm string matches the local realm (raw or normalized).
-- Used by CanonicalPeerKey to decide whether to strip the realm suffix. We
-- intentionally do NOT delegate to Ambiguate("guild") because retail's
-- Ambiguate strips realm for ALL guildmates of a connected-realm group,
-- which would collapse distinct same-name characters across connected realms
-- into one peer key. Custom local-realm-only logic preserves cross-realm
-- distinguishability.
-- @param realm string|nil Realm portion of a Name-Realm pair
-- @return boolean true if realm == local realm (raw or normalized)
function GBL:_isLocalRealm(realm)
    if type(realm) ~= "string" or realm == "" then return false end
    local localRealm = self:GetLocalRealm()
    if not localRealm or localRealm == "" or localRealm == "UnknownRealm" then
        return false
    end
    if realm == localRealm then return true end
    return self:NormalizeRealm(realm) == self:NormalizeRealm(localRealm)
end

--- Canonicalize a sender / target name for peer identity keying.
-- Strip rules (custom; do NOT delegate to Ambiguate):
--   * Qualified Name-Realm: strip when realm equals the local realm
--     (raw-or-normalized), preserve as-is otherwise. Cross-realm guildmates
--     in connected-realm groups keep their realm suffix so two distinct
--     same-name characters across realms stay distinct.
--   * Bare name: re-realm via guildData.playerRealms (built by
--     BuildRosterCache, persisted across sessions) when the bare name maps
--     to a unique realm. Bare names with no roster entry, or with the `false`
--     ambiguity sentinel (multiple roster realms share the bare name), pass
--     through unchanged — guessing the wrong realm would silently misroute.
-- For genuine bare-name semantics (recentWhisperTargets chat-suppression,
-- UI filter inputs) use GBL:StripRealm directly, not this helper.
-- @param name string|nil Sender / target name in any qualification
-- @return string|nil Canonical peer key (input unchanged for nil / empty / no-mapping)
function GBL:CanonicalPeerKey(name)
    if not name or name == "" then return name end
    if name:find("-", 1, true) then
        local base, realm = name:match("^([^%-]+)%-(.+)$")
        if base and realm and self:_isLocalRealm(realm) then
            return base
        end
        -- Cross-realm or unparseable: preserve full Name-Realm form so two
        -- distinct same-name characters across connected realms stay distinct.
        return name
    end
    -- Bare name: re-realm via the persistent roster cache when uniquely known.
    -- Without this, a bare arrival from a connected-realm peer would key
    -- distinctly from the same character's qualified arrivals.
    local guildData = self:GetGuildData()
    local realm = guildData and guildData.playerRealms and guildData.playerRealms[name]
    -- Three defensive guards in one condition:
    --   1. type(realm) == "string" — rejects the `false` ambiguity sentinel
    --      (set by BuildRosterCache when a bare name maps to multiple realms
    --      in the roster) and skips re-realming, so ambiguous bare arrivals
    --      stay bare instead of being misrouted to the last-write-wins realm.
    --   2. realm ~= "" — rejects empty strings (defensive; shouldn't happen).
    --   3. not realm:find("-") — rejects corrupt hyphen-bearing realm strings
    --      from a long-fixed code path; retail realms never contain hyphens.
    --      RepairCorruptedPlayerRealms cleans these up at next BuildRosterCache.
    if type(realm) == "string" and realm ~= "" and not realm:find("-", 1, true) then
        if self:_isLocalRealm(realm) then return name end
        return name .. "-" .. realm
    end
    return name
end

--- Repair corrupted playerRealms entries in place.
-- Realm strings with embedded hyphens ("Stormrage-Stormrage-Stormrage...")
-- are corruption from a long-since-fixed code path; retail realm names never
-- contain hyphens. BuildRosterCache only overwrites entries for currently-
-- rostered (and present at scan time) members, so corrupt entries for offline
-- or departed peers can persist indefinitely. Fix: extract the first
-- hyphen-free segment as the canonical realm; drop the entry if no segment is
-- recoverable.
-- @param playerRealms table The playerRealms table to repair (mutated in place)
-- @return number Number of entries repaired or removed
function GBL:RepairCorruptedPlayerRealms(playerRealms)
    if type(playerRealms) ~= "table" then return 0 end
    local repaired = 0
    local keys = {}
    for k in pairs(playerRealms) do keys[#keys+1] = k end
    for _, k in ipairs(keys) do
        local v = playerRealms[k]
        if type(v) == "string" and v:find("-", 1, true) then
            local cleaned = v:match("^([^%-]+)")
            if cleaned and cleaned ~= "" then
                playerRealms[k] = cleaned
            else
                playerRealms[k] = nil
            end
            repaired = repaired + 1
        end
    end
    return repaired
end

--- Build/update the persistent guild roster cache.
-- Maps bare player names to their realm, persisted in SavedVariables.
-- Called on GUILD_ROSTER_UPDATE so the mapping survives guild departures.
-- Two-pass design: collect distinct realms per bare name first, then write.
-- A bare name appearing at two or more realms in the roster (rare but
-- possible in connected-realm guilds) is marked with the `false` sentinel
-- so CanonicalPeerKey skips re-realming and keeps the bare arrival bare —
-- guessing the wrong realm would silently misroute peer state.
function GBL:BuildRosterCache()
    if not self.db then return end
    local numMembers = GetNumGuildMembers()
    local guildData = self:GetGuildData()
    if not guildData or not numMembers or numMembers == 0 then return end
    if not guildData.playerRealms then guildData.playerRealms = {} end
    -- Repair any corrupt realm strings before adding fresh roster entries so
    -- offline/departed peers don't carry corruption forward. (Also leaves
    -- the `false` ambiguity sentinel untouched — it's not a string.)
    self:RepairCorruptedPlayerRealms(guildData.playerRealms)
    local localRealm = self:GetLocalRealm()

    -- Pass 1: collect distinct realms per bare name from the current roster
    local seen = {}  -- base -> { realm1, realm2, ... } (deduped)
    for i = 1, numMembers do
        local fullName = GetGuildRosterInfo(i)
        if fullName then
            local base, realm = fullName:match("^([^%-]+)%-(.+)$")
            if not (base and realm) then
                base = fullName
                realm = localRealm
            end
            if base and realm and realm ~= "" then
                local normalized = self:NormalizeRealm(realm)
                local list = seen[base]
                if not list then
                    seen[base] = { normalized }
                else
                    local already = false
                    for _, r in ipairs(list) do
                        if r == normalized then already = true; break end
                    end
                    if not already then
                        list[#list+1] = normalized
                    end
                end
            end
        end
    end

    -- Pass 2: unique → string realm; ambiguous → `false` sentinel
    for base, realms in pairs(seen) do
        if #realms == 1 then
            guildData.playerRealms[base] = realms[1]
        else
            guildData.playerRealms[base] = false
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
                guildData.playerRealms[base] = self:NormalizeRealm(realm)
            end
        end
        if record.scannedBy then
            local senderPart = record.scannedBy:match("^sync:(.+)$")
            if senderPart then
                local base, realm = senderPart:match("^([^%-]+)%-(.+)$")
                if base and realm then
                    guildData.playerRealms[base] = self:NormalizeRealm(realm)
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
            guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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
            guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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
                guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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

    -- Pass 1: re-run same-slot dedup. The counting bug continued creating
    -- new duplicates between v0.14.2 (which ran this pass once) and now.
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
                guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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
                newHashes[record.id] = self:SafeRecordTimestamp(record)
            end
        end
        for _, record in ipairs(guildData.moneyTransactions or {}) do
            if record.id then
                newHashes[record.id] = self:SafeRecordTimestamp(record)
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

--- Schema 8 -> 9: collapse same-realm-qualified peer keys to bare names.
-- The sync layer originally keyed peers via Ambiguate(name, "none"), which in
-- production WoW does NOT strip realm. Result: knownPeers and syncState.peers
-- accumulated multiple entries for the same player ("Rexxybear" vs
-- "Rexxybear-Tichondrius") whenever AceComm delivered the sender with a
-- different qualification across messages. This migration walks both tables
-- and collapses keys whose realm portion equals the local realm; cross-realm
-- keys (different connected-realm) are preserved so that two characters
-- sharing a first name across realms stay distinct. Same-realm collisions are
-- merged by keeping the entry with the highest recency timestamp (lastSeen
-- for knownPeers, lastSync for the post-sync checkpoint table).
--
-- If the local realm cannot be resolved (GetLocalRealm returns the
-- "UnknownRealm" sentinel because realm APIs are not warm yet) the migration
-- returns early without bumping schemaVersion, so the next session retries
-- when realm info is available.
--
-- Idempotent: bare keys and cross-realm keys pass through untouched.
function GBL:MigrateNormalizePeerNames(guildData)
    if not guildData or (guildData.schemaVersion or 0) >= 9 then return 0 end

    local localRealm = self:GetLocalRealm()
    if localRealm == "UnknownRealm" then return 0 end
    local localNormalized = self:NormalizeRealm(localRealm)

    local function normalize(t, recencyField)
        if type(t) ~= "table" then return 0 end
        local merged = 0
        local keys = {}
        for k in pairs(t) do keys[#keys+1] = k end
        for _, k in ipairs(keys) do
            local base, realm = k:match("^([^%-]+)%-(.+)$")
            if base and realm then
                local realmNormalized = self:NormalizeRealm(realm)
                if realm == localRealm or realmNormalized == localNormalized then
                    local existing = t[base]
                    local incoming = t[k]
                    if not existing then
                        t[base] = incoming
                    elseif (incoming[recencyField] or 0) > (existing[recencyField] or 0) then
                        t[base] = incoming
                    end
                    t[k] = nil
                    merged = merged + 1
                end
                -- Cross-realm key: leave alone so distinct same-name peers stay distinct.
            end
            -- Bare key: pass through.
        end
        return merged
    end

    local mergedKnown = normalize(guildData.knownPeers, "lastSeen")
    local mergedPersisted = 0
    if guildData.syncState then
        mergedPersisted = normalize(guildData.syncState.peers, "lastSync")
    end

    guildData.schemaVersion = 9
    return mergedKnown + mergedPersisted
end

--- Schema 9 -> 10: collapse spaced-realm strings stored from older code paths.
-- Pre-NormalizeRealm, BuildRosterCache and MigrateSchemaV2ToV3 stored realm
-- portions raw (e.g. "Aerie Peak") while the local-realm fallback in
-- ResolvePlayerName always produced normalized form ("AeriePeak"). The
-- asymmetry let the same player surface as two different record.player values
-- ("Alice-Aerie Peak" vs "Alice-AeriePeak") and as two playerRealms entries
-- with the same key but different realm. This migration walks both
-- guildData.playerRealms and the record.player / record.scannedBy fields,
-- normalizes any space-bearing realm portion in place, and merges colliding
-- playerRealms entries by keeping the first encountered value (post-fix the
-- normalized form should agree).
-- Idempotent: realm strings without spaces pass through untouched.
-- @return number Number of strings rewritten across playerRealms + records
function GBL:MigrateNormalizeStoredRealms(guildData)
    -- Strict prerequisite: only run after schema 9 has been reached. The
    -- prior MigrateNormalizePeerNames short-circuits on cold realm APIs
    -- (schemaVersion stays at 8); a loose `>= 10` gate here would let this
    -- migration bump straight to 10 from 8, permanently skipping the 8 -> 9
    -- work on the next session. Strict equality keeps the chain in order.
    if not guildData or (guildData.schemaVersion or 0) ~= 9 then return 0 end

    local rewrites = 0
    local recordsRewritten = false

    if type(guildData.playerRealms) == "table" then
        local keys = {}
        for k in pairs(guildData.playerRealms) do keys[#keys+1] = k end
        for _, base in ipairs(keys) do
            local realm = guildData.playerRealms[base]
            if type(realm) == "string" and realm:find("%s") then
                guildData.playerRealms[base] = self:NormalizeRealm(realm)
                rewrites = rewrites + 1
            end
        end
    end

    -- Rewrites that mutate record.player invalidate record.id (ComputeTxHash
    -- includes player) and seenTxHashes; the per-record loop recomputes id
    -- inline and we rebuild seenTxHashes once at the end.
    local function rewriteRecordRealms(records)
        if type(records) ~= "table" then return end
        for _, record in ipairs(records) do
            local playerChanged = false
            if type(record.player) == "string" then
                local base, realm = record.player:match("^([^%-]+)%-(.+)$")
                if base and realm and realm:find("%s") then
                    record.player = base .. "-" .. self:NormalizeRealm(realm)
                    rewrites = rewrites + 1
                    playerChanged = true
                end
            end
            if type(record.scannedBy) == "string" then
                local senderPart = record.scannedBy:match("^sync:(.+)$")
                if senderPart then
                    local base, realm = senderPart:match("^([^%-]+)%-(.+)$")
                    if base and realm and realm:find("%s") then
                        record.scannedBy = "sync:" .. base .. "-" .. self:NormalizeRealm(realm)
                        rewrites = rewrites + 1
                    end
                end
            end
            -- ComputeTxHash hashes the player field; if we changed it, the
            -- record's id is now stale and must be rebuilt before sync sees
            -- it (or sync would re-import this record under its new id).
            if playerChanged and record.id then
                local baseHash = self:ComputeTxHash(record)
                local occ = record._occurrence or 0
                record.id = baseHash .. ":" .. occ
                recordsRewritten = true
            end
        end
    end

    rewriteRecordRealms(guildData.transactions)
    rewriteRecordRealms(guildData.moneyTransactions)

    -- Rebuild seenTxHashes if any record ids changed. Walks both transaction
    -- tables and reseeds the dedup index from the new ids. Mirrors the same
    -- pattern as MigrateRepairEpochTimestamps.
    if recordsRewritten and type(guildData.seenTxHashes) == "table" then
        local newHashes = {}
        for _, record in ipairs(guildData.transactions or {}) do
            if record.id then
                newHashes[record.id] = self:SafeRecordTimestamp(record)
            end
        end
        for _, record in ipairs(guildData.moneyTransactions or {}) do
            if record.id then
                newHashes[record.id] = self:SafeRecordTimestamp(record)
            end
        end
        for k in pairs(guildData.seenTxHashes) do
            guildData.seenTxHashes[k] = nil
        end
        for k, v in pairs(newHashes) do
            guildData.seenTxHashes[k] = v
        end
    end

    guildData.schemaVersion = 10
    return rewrites
end

--- Schema 10 -> 11: best-effort recovery of peer realms after the v0.30.5
-- unconditional-strip schema-9 migration ran (which lost the realm portion
-- of every peer key). Walks bare keys in knownPeers and syncState.peers,
-- consults the live guild roster, and re-realms keys whose bare name maps
-- to exactly one roster entry. Cross-realm matches get their realm; same-realm
-- matches re-canonicalize back to bare via CanonicalPeerKey. Multi-match
-- (same name on multiple realms in the roster) and no-match (offline /
-- departed peer) keys are left bare and live with the collision risk.
--
-- Cold-API short-circuits: returns early without bumping schemaVersion when
-- either GetLocalRealm() reports "UnknownRealm" or GetNumGuildMembers() is 0
-- (cold roster). The migration retries on the next session, or sooner via the
-- warm-roster retrigger of MigrateAllGuilds in GUILD_ROSTER_UPDATE. Idempotent:
-- on a second run the roster lookup either finds the same realm (re-rewrites
-- to the same key) or is unavailable (key stays put).
--
-- Best-effort by design: the lost realm info is unrecoverable for offline
-- peers and ambiguous for multi-realm name collisions.
-- @return number Number of keys rewritten across knownPeers + syncState.peers
function GBL:MigrateRecoverPeerRealms(guildData)
    -- Strict prerequisite: only run after schema 10 has been reached. Same
    -- skip-chain concern as MigrateNormalizeStoredRealms: a loose `>= 11`
    -- gate would let this migration bump straight from 8 to 11 if earlier
    -- migrations short-circuited on cold realm APIs.
    if not guildData or (guildData.schemaVersion or 0) ~= 10 then return 0 end

    local localRealm = self:GetLocalRealm()
    if localRealm == "UnknownRealm" then return 0 end

    -- Build bareName -> realm lookup, but only for unambiguous matches.
    -- A name appearing at two realms in the roster (rare but possible in
    -- connected-realm guilds) drops out of the lookup so we don't guess.
    local lookup = {}
    local ambiguous = {}
    local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
    -- Cold roster (numMembers == 0) means the lookup would build empty and
    -- recovery would no-op. Returning early without bumping schemaVersion
    -- lets the migration retry on a later session (or via the warm-roster
    -- retrigger in GUILD_ROSTER_UPDATE).
    if numMembers == 0 then return 0 end
    for i = 1, numMembers do
        local fullName = GetGuildRosterInfo(i)
        if fullName then
            local base, realm = fullName:match("^([^%-]+)%-(.+)$")
            if not base then
                base = fullName
                realm = localRealm
            end
            -- Normalize before storing so the lookup agrees with the
            -- normalized form used everywhere else (record.player after the
            -- 9 -> 10 migration, HELLO sender canonicalization, etc.).
            -- GetGuildRosterInfo can return raw spaced realm names ("Aerie
            -- Peak") for cross-realm guildmates depending on the realm
            -- topology; without this normalize the recovered key would split
            -- across "Name-Aerie Peak" and "Name-AeriePeak".
            realm = self:NormalizeRealm(realm)
            if not ambiguous[base] then
                if lookup[base] and lookup[base] ~= realm then
                    lookup[base] = nil
                    ambiguous[base] = true
                else
                    lookup[base] = realm
                end
            end
        end
    end

    local rewrites = 0
    local function recover(t)
        if type(t) ~= "table" then return end
        local keys = {}
        for k in pairs(t) do keys[#keys+1] = k end
        for _, k in ipairs(keys) do
            if not k:find("%-") then  -- only consider bare keys
                local realm = lookup[k]
                if realm then
                    local rewritten = self:CanonicalPeerKey(k .. "-" .. realm)
                    if rewritten ~= k then
                        if not t[rewritten] then
                            t[rewritten] = t[k]
                            t[k] = nil
                            rewrites = rewrites + 1
                        end
                        -- If t[rewritten] already exists, leave both for now;
                        -- shouldn't happen in practice (we just stripped to bare).
                    end
                end
            end
        end
    end

    recover(guildData.knownPeers)
    if guildData.syncState then
        recover(guildData.syncState.peers)
    end

    guildData.schemaVersion = 11
    return rewrites
end

--- Run migration for all guild data namespaces.
function GBL:MigrateAllGuilds()
    if not self.db or not self.db.global or not self.db.global.guilds then return end
    for _, guildData in pairs(self.db.global.guilds) do
        -- Repair playerRealms corruption FIRST so any migration that consults
        -- the cache (and InitSync's seed loop downstream) sees clean data.
        -- BuildRosterCache also calls this on every GUILD_ROSTER_UPDATE, but
        -- that fires AFTER OnEnable -> InitSync, leaving a cold-startup window
        -- where the seed loop would canonicalize bare names to bare via the
        -- corruption-rejecting fallback in CanonicalPeerKey.
        if guildData.playerRealms then
            self:RepairCorruptedPlayerRealms(guildData.playerRealms)
        end
        self:MigrateOccurrenceScheme(guildData)
        self:MigrateSchemaV2ToV3(guildData)
        self:MigrateOccurrenceToPerSlot(guildData)
        self:MigrateDeduplicateRecords(guildData)
        self:MigrateCrossSlotDedup(guildData)
        self:MigrateAccessControl(guildData)
        self:MigrateRepairEpochTimestamps(guildData)
        self:MigrateSortAccessShape(guildData)
        self:MigrateNormalizePeerNames(guildData)
        self:MigrateNormalizeStoredRealms(guildData)
        self:MigrateRecoverPeerRealms(guildData)
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
            guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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
    self:SystemInfo("Repaired " .. fixed .. " player names after roster load")
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

    -- One-time retrigger of the migration ladder once roster is warm. Closes
    -- the cold-roster gap for migrations like MigrateRecoverPeerRealms that
    -- short-circuit on cold APIs at OnEnable time. Strict-gated migrations
    -- whose schemaVersion already advanced are no-ops.
    if not self._migrationsRetried then
        local n = GetNumGuildMembers and GetNumGuildMembers() or 0
        if n > 0 then
            self._migrationsRetried = true
            self:MigrateAllGuilds()
        end
    end

    -- Re-canonicalize peer-state tables. CanonicalPeerKey output can change
    -- between OnEnable (cold roster, possibly corrupt playerRealms) and now
    -- (warm roster, repaired playerRealms). Stale bare entries written by
    -- the InitSync seed loop or by HELLO arrivals during the cold window get
    -- swept into their qualified canonical form here. Idempotent.
    if self.ConsolidatePeerKeys then
        self:ConsolidatePeerKeys()
    end

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

    -- Roster/rank can warm after the window was first built (cold-roster login)
    -- or change mid-session (promotion/demotion). Sort/Layout tab visibility is
    -- derived from guild rank, so re-evaluate and rebuild the tabs if (and only
    -- if) the access-gated set changed.
    if self.RefreshAccessTabsIfChanged then self:RefreshAccessTabsIfChanged() end
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
                            self:SystemInfo("Post-scan cleanup: removed "
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
    -- Stop a running sort before the rest of close cleanup. The executor no longer
    -- registers frame-hide itself (it would shadow this handler), so Core drives the
    -- abort. Guarded for load-order safety; no-op when no sort is running.
    if self._SortExecutorOnBankClosed then self:_SortExecutorOnBankClosed() end
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
-- Sort access (bank sort + stocking policy)
-- Distinct from GetAccessLevel/HasFullAccess above: sort access controls
-- who can edit the bank layout and who can press Execute on the Sort tab.
--
-- Two independent tiers:
--   * sortAccess.write — grants layout-write + sort (edit templates, capture,
--     pin slots, change stock reserves; inherently can also Execute).
--   * sortAccess.sort  — grants sort only (press Execute on the Sort tab);
--     cannot edit the layout.
--
-- Each tier has rankThreshold (number|nil; nil = GM-only) and delegates
-- (set of "Name-Realm"). Write ⇒ sort — anyone in the write tier is treated
-- as having sort access regardless of the sort tier's membership.
--
-- GM always has both. Writes to sortAccess itself remain GM-only (otherwise
-- a delegate could escalate by adding themselves).
------------------------------------------------------------------------

--- Return the normalized "Name-Realm" of the current player.
local function normalizedPlayerName()
    local name, realm = UnitName("player")
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    local fallback = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    if fallback and fallback ~= "" then
        return name .. "-" .. fallback
    end
    return name
end

--- Empty two-tier policy skeleton.
local function emptySortAccess()
    return {
        write = { rankThreshold = nil, delegates = {} },
        sort  = { rankThreshold = nil, delegates = {} },
        updatedBy = nil,
        updatedAt = 0,
    }
end

--- Convert a single-tier or legacy sortAccess table into the two-tier shape.
-- Idempotent — feeding an already-migrated table returns the equivalent shape.
-- Legacy flat-shape (top-level rankThreshold/delegates) moves into the write
-- tier so no existing delegate loses permission on upgrade.
-- @param sa table|nil
-- @return table new-shape sortAccess
local function migrateSortAccessTable(sa)
    if not sa then return emptySortAccess() end

    local hasNew = type(sa.write) == "table" or type(sa.sort) == "table"
    local hasLegacy = sa.rankThreshold ~= nil or sa.delegates ~= nil

    if hasNew then
        local out = emptySortAccess()
        if type(sa.write) == "table" then
            out.write.rankThreshold = sa.write.rankThreshold
            if type(sa.write.delegates) == "table" then
                for name, v in pairs(sa.write.delegates) do
                    if v and type(name) == "string" and name ~= "" then
                        out.write.delegates[name] = true
                    end
                end
            end
        end
        if type(sa.sort) == "table" then
            out.sort.rankThreshold = sa.sort.rankThreshold
            if type(sa.sort.delegates) == "table" then
                for name, v in pairs(sa.sort.delegates) do
                    if v and type(name) == "string" and name ~= "" then
                        out.sort.delegates[name] = true
                    end
                end
            end
        end
        out.updatedBy = sa.updatedBy
        out.updatedAt = sa.updatedAt or 0
        return out
    end

    if hasLegacy then
        local out = emptySortAccess()
        out.write.rankThreshold = sa.rankThreshold
        if type(sa.delegates) == "table" then
            for name, v in pairs(sa.delegates) do
                if v and type(name) == "string" and name ~= "" then
                    out.write.delegates[name] = true
                end
            end
        end
        out.updatedBy = sa.updatedBy
        out.updatedAt = sa.updatedAt or 0
        return out
    end

    return emptySortAccess()
end

--- Migrate sortAccess in-place for a single guildData entry. Idempotent.
function GBL:MigrateSortAccessShape(guildData)
    if not guildData then return end
    guildData.sortAccess = migrateSortAccessTable(guildData.sortAccess)
end

--- Internal: does the current player pass a single tier's membership check?
-- @param tier table|nil { rankThreshold, delegates }
-- @return boolean
local function playerInTier(tier)
    if type(tier) ~= "table" then return false end
    local me = normalizedPlayerName()
    if me and type(tier.delegates) == "table" and tier.delegates[me] then
        return true
    end
    if tier.rankThreshold ~= nil then
        local _, _, rankIndex = GetGuildInfo("player")
        if rankIndex and rankIndex <= tier.rankThreshold then return true end
    end
    return false
end

--- Check whether the current player can edit the bank layout.
-- Layout write implies sort access.
-- @return boolean
function GBL:HasLayoutWrite()
    if self:IsGuildMaster() then return true end
    local guildData = self:GetGuildData()
    if not guildData or not guildData.sortAccess then return false end
    return playerInTier(guildData.sortAccess.write)
end

--- Check whether the current player can execute a sort (write implies sort).
-- @return boolean
function GBL:HasSortAccess()
    if self:HasLayoutWrite() then return true end
    local guildData = self:GetGuildData()
    if not guildData or not guildData.sortAccess then return false end
    return playerInTier(guildData.sortAccess.sort)
end

--- Return a deep copy of the two-tier sort-access policy. Never returns
-- the live ref. Transparently upgrades legacy flat-shape tables.
function GBL:GetSortAccess()
    local guildData = self:GetGuildData()
    if not guildData then return emptySortAccess() end
    local sa = migrateSortAccessTable(guildData.sortAccess)
    return sa
end

--- Save a new sort-access policy. GM-only.
-- @param policy table shaped { write = {rankThreshold, delegates},
--                              sort  = {rankThreshold, delegates} }
-- @return ok, err
function GBL:SaveSortAccess(policy)
    if not self:IsGuildMaster() then
        return false, "only the Guild Master can change sort access"
    end
    if type(policy) ~= "table" then
        return false, "policy must be a table"
    end

    local function validateTier(tier, label)
        if tier == nil then return { rankThreshold = nil, delegates = {} } end
        if type(tier) ~= "table" then
            return nil, label .. " tier must be a table"
        end
        if tier.rankThreshold ~= nil and type(tier.rankThreshold) ~= "number" then
            return nil, label .. " rankThreshold must be a number or nil"
        end
        if tier.delegates ~= nil and type(tier.delegates) ~= "table" then
            return nil, label .. " delegates must be a table"
        end
        local delegates = {}
        if tier.delegates then
            for name, v in pairs(tier.delegates) do
                if v and type(name) == "string" and name ~= "" then
                    delegates[name] = true
                end
            end
        end
        return { rankThreshold = tier.rankThreshold, delegates = delegates }
    end

    local writeTier, err = validateTier(policy.write, "write")
    if not writeTier then return false, err end
    local sortTier, err2 = validateTier(policy.sort, "sort")
    if not sortTier then return false, err2 end

    local guildData = self:GetGuildData()
    if not guildData then return false, "no active guild" end

    guildData.sortAccess = {
        write = writeTier,
        sort  = sortTier,
        updatedBy = normalizedPlayerName(),
        updatedAt = GetServerTime(),
    }

    -- Propagate to guildmates and refresh our own tab visibility. sortAccess
    -- gates the Sort/Layout tabs, so a grant must reach the granted member's
    -- client to take effect. Mirrors the accessControl save path in
    -- UI/SyncStatus.lua: a forced HELLO carries the new policy (rate-limited, so
    -- rapid edits do not storm) and the local message rebuilds our tabs.
    if self.BroadcastHello then self:BroadcastHello(true) end
    self:SendMessage("GBL_ACCESS_CONTROL_CHANGED")

    return true, nil
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
    local head, rest = input:match("^(%S*)%s*(.*)$")
    local command = (head or ""):lower()

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
    elseif command == "sortlog" then
        self:ShowSortLog()
    elseif command == "logs" then
        self:HandleLogsCommand(rest)
    elseif command == "cleanup" then
        self:RunCleanup()
    elseif command == "sortpreview" then
        self:PrintSortPreview()
    elseif command == "sortexec" then
        self:RunSortExec()
    elseif command == "sortcancel" then
        self:CancelSortExecution()
        self:Print("Sort cancellation requested.")
    elseif command == "deviations" or command == "devs" then
        self:PrintDeviations()
    elseif command == "bubbletest" then
        if self.DumpBubbleDiagnostics then
            self:DumpBubbleDiagnostics()
        else
            self:Print("ChatFilters module not loaded.")
        end
    elseif command == "epoch0" then
        self:DumpEpochZeroRecords()
    elseif command == "restock" then
        if self.OpenRestockTab then
            self:OpenRestockTab()
        else
            self:Print("Restock module not loaded.")
        end
    else
        self:Print("Unknown command: " .. command .. ". Type /gbl help for usage.")
    end
end

--- Compare the current bank scan against the layout's expected demand map
-- and print every mismatch. Useful after a sort to confirm the result, or
-- before a sort to see what's deviant. Uses the same expected layout the
-- planner does (including items[id].slots extensions beyond slotOrder).
function GBL:PrintDeviations()
    if not self.PlanSort then
        self:Print("SortPlanner not loaded.")
        return
    end
    local snapshot = self:GetLastScanResults()
    if not snapshot then
        self:Print("No scan yet. Open the bank and run /gbl scan first.")
        return
    end
    local layout = self:GetBankLayout()
    if not layout or not next(layout.tabs) then
        self:Print("No bank layout configured.")
        return
    end

    local plan = self:PlanSort(snapshot, layout)
    local expected = plan.demandMap or {}

    -- Ignore tabs are excluded from comparison; they're never touched by sort.
    local ignoreSet = {}
    for tabIndex, tab in pairs(layout.tabs) do
        if tab.mode == "ignore" then ignoreSet[tabIndex] = true end
    end

    local function slotActual(tabIndex, slotIndex)
        local tr = snapshot[tabIndex]
        local s = tr and tr.slots and tr.slots[slotIndex]
        if not s then return nil, 0 end
        local id = s.itemLink and s.itemLink:match("Hitem:(%d+)")
        id = id and tonumber(id) or nil
        return id, s.count or 0
    end

    local function itemName(itemID)
        if GBL.GetCachedItemInfo then
            local n = self:GetCachedItemInfo(itemID)
            if n then return n .. " (id " .. itemID .. ")" end
        end
        return "item:" .. tostring(itemID)
    end

    local mismatches, extras, missingEmpty, wrongCount = 0, 0, 0, 0
    local lines = {}
    -- Sort tabs ascending so output is predictable.
    local tabs = {}
    for t in pairs(layout.tabs) do table.insert(tabs, t) end
    table.sort(tabs)
    for _, tabIndex in ipairs(tabs) do
        if not ignoreSet[tabIndex] then
            local tab = layout.tabs[tabIndex]
            local expectedSlots = expected[tabIndex]
            if tab.mode == "display" and expectedSlots then
                for s = 1, MAX_GUILDBANK_SLOTS_PER_TAB or 98 do
                    local exp = expectedSlots[s]
                    local actualID, actualCount = slotActual(tabIndex, s)
                    if exp then
                        if not actualID then
                            table.insert(lines, string.format(
                                "  T%d/S%d  expected %s x%d, EMPTY",
                                tabIndex, s, itemName(exp.itemID), exp.perSlot))
                            missingEmpty = missingEmpty + 1
                            mismatches = mismatches + 1
                        elseif actualID ~= exp.itemID then
                            table.insert(lines, string.format(
                                "  T%d/S%d  expected %s x%d, got %s x%d",
                                tabIndex, s, itemName(exp.itemID), exp.perSlot,
                                itemName(actualID), actualCount))
                            mismatches = mismatches + 1
                        elseif actualCount ~= exp.perSlot then
                            table.insert(lines, string.format(
                                "  T%d/S%d  expected %s x%d, count is x%d",
                                tabIndex, s, itemName(exp.itemID), exp.perSlot, actualCount))
                            wrongCount = wrongCount + 1
                            mismatches = mismatches + 1
                        end
                    else
                        if actualID then
                            table.insert(lines, string.format(
                                "  T%d/S%d  unclaimed, holds %s x%d (extra)",
                                tabIndex, s, itemName(actualID), actualCount))
                            extras = extras + 1
                        end
                    end
                end
            end
        end
    end

    self:Print(string.format("|cffffcc00Deviation check:|r %d mismatch(es), %d extra(s)",
        mismatches, extras))
    if mismatches > 0 then
        self:Print(string.format("  breakdown: %d empty (should hold item), %d wrong count, %d wrong item",
            missingEmpty, wrongCount,
            mismatches - missingEmpty - wrongCount))
    end
    if #lines == 0 then
        self:Print("  |cff00ff88Bank matches layout exactly.|r")
        return
    end
    -- Cap output so a disastrous state doesn't flood chat.
    local cap = 40
    for i = 1, math.min(cap, #lines) do
        self:Print(lines[i])
    end
    if #lines > cap then
        self:Print(string.format("  ... and %d more (output capped at %d lines; run /gbl synclog for the audit trail)",
            #lines - cap, cap))
    end
end

--- Debug helper: execute the current plan end-to-end via SortExecutor.
-- GM / delegated-rank / delegate only. Prints progress on completion.
function GBL:RunSortExec()
    if not self:HasSortAccess() then
        self:Print("You do not have sort access. Ask the GM to grant rank or delegate.")
        return
    end
    if not self:IsBankOpen() then
        self:Print("Open the guild bank first.")
        return
    end
    if self:IsSortRunning() then
        self:Print("A sort is already running. Use /gbl sortcancel to stop it.")
        return
    end
    local snapshot = self:GetLastScanResults()
    if not snapshot then
        self:Print("No scan results yet. Run /gbl scan first.")
        return
    end
    local layout = self:GetBankLayout()
    if not layout or not next(layout.tabs) then
        self:Print("No bank layout configured yet.")
        return
    end
    local plan = self:PlanSort(snapshot, layout)
    if not plan.ops or #plan.ops == 0 then
        self:Print("Plan is a no-op. Nothing to execute.")
        return
    end
    self:Print(format("Executing %d moves...", #plan.ops))
    self:ExecuteSortPlan(plan, function(result)
        if result.ok then
            self:Print(format("Sort complete: %d ops done, %d failed, %d replans.",
                result.done, result.failed, result.replans))
        else
            self:Print(format("Sort aborted (%s): %d/%d done, %d failed, %d replans.",
                result.reason, result.done, result.total, result.failed, result.replans))
        end
    end, { layout = layout })
end

--- Debug helper: print the current planned sort moves to chat.
-- Also prints a diagnostic breakdown (tab modes, demand/supply counts, keep
-- slots) so "no moves needed" outcomes can be distinguished between "bank
-- genuinely matches layout" vs. "layout has no demands" vs. "scan is stale."
function GBL:PrintSortPreview()
    if not self.PlanSort then
        self:Print("SortPlanner not loaded.")
        return
    end
    local snapshot = self:GetLastScanResults()
    if not snapshot then
        self:Print("No scan results yet. Open the bank and run /gbl scan first.")
        return
    end
    local layout = self:GetBankLayout()
    if not layout or not next(layout.tabs) then
        self:Print("No bank layout configured yet. Nothing to sort.")
        return
    end

    -- Layout breakdown.
    local displayTabs, overflowTab, ignoreTabs = {}, nil, {}
    local totalDemands = 0
    for tabIndex, tab in pairs(layout.tabs) do
        if tab.mode == "display" then
            -- Count demands by items[id].slots (authoritative); this matches
            -- what the planner actually uses.
            local dCount = 0
            if tab.items then
                for _, row in pairs(tab.items) do
                    if type(row) == "table" and type(row.slots) == "number" then
                        dCount = dCount + row.slots
                    end
                end
            end
            totalDemands = totalDemands + dCount
            table.insert(displayTabs, { tabIndex = tabIndex, demands = dCount })
        elseif tab.mode == "overflow" then
            overflowTab = tabIndex
        elseif tab.mode == "ignore" then
            table.insert(ignoreTabs, tabIndex)
        end
    end
    table.sort(displayTabs, function(a, b) return a.tabIndex < b.tabIndex end)
    table.sort(ignoreTabs)

    -- Snapshot breakdown.
    local snapshotStr = {}
    local totalSupplies = 0
    for tabIndex, tabResult in pairs(snapshot) do
        local n = 0
        if tabResult and tabResult.slots then
            for _, _slot in pairs(tabResult.slots) do
                n = n + 1
            end
        end
        totalSupplies = totalSupplies + n
        table.insert(snapshotStr, { tabIndex = tabIndex, n = n })
    end
    table.sort(snapshotStr, function(a, b) return a.tabIndex < b.tabIndex end)

    local lastScan = "Never"
    if self.lastScanTime and self.lastScanTime > 0 then
        lastScan = date("%H:%M:%S", self.lastScanTime)
    end

    self:Print("|cffffcc00Sort diagnostic:|r")
    self:Print(format("  Layout v%s, last scan %s",
        tostring(layout.version or "?"), lastScan))
    local displaySummary = {}
    for _, e in ipairs(displayTabs) do
        table.insert(displaySummary, format("T%d=%d", e.tabIndex, e.demands))
    end
    self:Print(format("  Display tabs: [%s] (%d demands total)",
        table.concat(displaySummary, ", "), totalDemands))
    self:Print(format("  Overflow tab: %s", tostring(overflowTab or "none")))
    if #ignoreTabs > 0 then
        self:Print(format("  Ignore tabs: [%s]",
            table.concat(ignoreTabs, ", ")))
    end
    local snapSummary = {}
    for _, e in ipairs(snapshotStr) do
        table.insert(snapSummary, format("T%d=%d", e.tabIndex, e.n))
    end
    self:Print(format("  Scan contents: [%s] (%d occupied slots total)",
        table.concat(snapSummary, ", "), totalSupplies))

    local plan = self:PlanSort(snapshot, layout)
    local opsN = #(plan.ops or {})
    local defN = 0; for _ in pairs(plan.deficits or {}) do defN = defN + 1 end
    local unpN = #(plan.unplaced or {})
    self:Print(format("  Plan: %d moves, %d deficits, %d unplaced",
        opsN, defN, unpN))

    -- Per-tab origin breakdown (v0.29.17 diagnostics): shows how many
    -- demands per display tab are pinned (from Capture) vs auto-placed
    -- (extended adjacent to a pin, or first-empty fallback). A big
    -- first-empty count alongside many pinned demands is the gem-tab
    -- restock pattern — new stacks landing at the end of the tab
    -- because their item's pin has no room to extend.
    local orderedTabs = {}
    for t in pairs(plan.demandMap or {}) do table.insert(orderedTabs, t) end
    table.sort(orderedTabs)
    for _, t in ipairs(orderedTabs) do
        local c = { pinned = 0, extR = 0, extL = 0, firstE = 0 }
        for _, dem in pairs(plan.demandMap[t]) do
            if     dem.origin == "pinned"       then c.pinned = c.pinned + 1
            elseif dem.origin == "extend-right" then c.extR   = c.extR + 1
            elseif dem.origin == "extend-left"  then c.extL   = c.extL + 1
            elseif dem.origin == "first-empty"  then c.firstE = c.firstE + 1
            end
        end
        local auto = c.extR + c.extL + c.firstE
        if c.pinned + auto > 0 then
            self:Print(format(
                "  T%d origins: %d pinned + %d auto-placed (%d extend-right, %d extend-left, %d first-empty)",
                t, c.pinned, auto, c.extR, c.extL, c.firstE))
        end
    end

    if opsN == 0 and defN == 0 and unpN == 0 then
        if totalDemands == 0 then
            self:Print("  |cffffaa55Reason: layout has no display-tab demands — no template to sort toward. " ..
                       "Use Capture or Add Item on the Layout tab.|r")
        else
            self:Print("  |cff00ff88Reason: every demand is already satisfied by a slot at the correct count.|r")
        end
        return
    end

    local lines = self:SummarizeSortPlan(plan)
    self:Print("|cffffcc00Planned moves (" .. #lines .. " lines):|r")
    for _, line in ipairs(lines) do
        self:Print("  " .. line)
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
    self:Print("|cffffcc00GuildBankLedger v" .. self.version .. " - Commands:|r")
    self:Print("  /gbl         - Toggle the ledger window")
    self:Print("  /gbl show    - Toggle the ledger window")
    self:Print("  /gbl status  - Show addon status")
    self:Print("  /gbl scan    - Manually scan the guild bank")
    self:Print("  /gbl cleanup - Remove duplicate records from the database")
    self:Print("  /gbl sortpreview - Preview the current sort plan (debug)")
    self:Print("  /gbl sortexec    - Execute the current sort plan (GM/delegated only)")
    self:Print("  /gbl sortcancel  - Cancel a running sort")
    self:Print("  /gbl synclog     - Show the sync-channel session log")
    self:Print("  /gbl sortlog     - Show the sort-channel session log")
    self:Print("  /gbl logs        - Show the master log (sync + sort + system)")
    self:Print("  /gbl logs dump [N]                       - Dump last N master entries to chat")
    self:Print("  /gbl logs clear sync|sort|system|all     - Truncate channel(s)")
    self:Print("  /gbl logs debug sync|sort|system on|off  - Toggle DEBUG-to-chat for a channel")
    self:Print("  /gbl help    - Show this help message")
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
                guildData.seenTxHashes[record.id] = self:SafeRecordTimestamp(record)
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

------------------------------------------------------------------------
-- Log viewers (sync / sort / master) -- copy-pastable AceGUI pop-ups
--
-- One-shot snapshot windows, no live-refresh. Callers reach this through
-- /gbl synclog, /gbl sortlog, and /gbl logs (see HandleSlashCommand).
------------------------------------------------------------------------

local LOG_TITLES = {
    sync   = "GBL Sync Log",
    sort   = "GBL Sort Log",
    system = "GBL System Log",
}

--- Format an entry for the master view (channel + level prefix).
local function masterLine(entry)
    local ts = date("%H:%M:%S", entry.ts or 0)
    return string.format("[%s] [%s] [%s] %s",
        ts, (entry.channel or "?"):upper(),
        entry.level or "INFO", entry.message or "")
end

--- Format an entry for a single-channel view (no channel prefix needed).
local function channelLine(entry)
    local ts = date("%H:%M:%S", entry.ts or 0)
    if entry.level and entry.level ~= "INFO" then
        return string.format("[%s] [%s] %s", ts, entry.level, entry.message or "")
    end
    return "[" .. ts .. "] " .. (entry.message or "")
end

--- Internal: render a snapshot in an AceGUI MultiLineEditBox pop-up.
-- Falls back to chat dump when AceGUI is unavailable.
function GBL:_ShowLogFrame(title, entries, formatter)
    if #entries == 0 then
        self:Print(title .. ": no entries yet.")
        return
    end

    local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
    if not AceGUI then
        -- Chat fallback (RCPL_Log.DumpToChat pattern).
        self:Print(title .. " (" .. #entries .. " entries):")
        for i = 1, #entries do
            self:Print(formatter(entries[i]))
        end
        return
    end

    local lines = {}
    for i = 1, #entries do
        lines[i] = formatter(entries[i])
    end
    local text = table.concat(lines, "\n")

    local frame = AceGUI:Create("Frame")
    frame:SetTitle(title .. " (" .. #entries .. " entries)")
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

--- Pop up the sync-channel log (also reached via /gbl synclog).
function GBL:ShowSyncLog()
    self:_ShowLogFrame(LOG_TITLES.sync, self:GetLog("sync"), channelLine)
end

--- Pop up the sort-channel log (also reached via /gbl sortlog).
function GBL:ShowSortLog()
    self:_ShowLogFrame(LOG_TITLES.sort, self:GetLog("sort"), channelLine)
end

--- Pop up the system-channel log.
function GBL:ShowSystemLog()
    self:_ShowLogFrame(LOG_TITLES.system, self:GetLog("system"), channelLine)
end

--- Pop up the master log (sync + sort + system, interleaved by timestamp).
function GBL:ShowMasterLog()
    local merged = self:GetMasterLog()
    self:_ShowLogFrame("GBL Master Log", merged, masterLine)
end

--- Dump the master log to chat (default 50 entries).
-- @param limit number Max entries to print
function GBL:DumpMasterLog(limit)
    limit = tonumber(limit) or 50
    local merged = self:GetMasterLog({ limit = limit })
    if #merged == 0 then
        self:Print("Master log: no entries.")
        return
    end
    self:Print(string.format("Master log dump (%d of available):", #merged))
    for i = 1, #merged do
        self:Print(masterLine(merged[i]))
    end
end

------------------------------------------------------------------------
-- Slash command helper: /gbl logs ...
------------------------------------------------------------------------

local LOG_CHANNEL_KEYS = { sync = true, sort = true, system = true, all = true }

--- Dispatch /gbl logs subcommands. Format:
--   /gbl logs                          → master pop-up
--   /gbl logs dump [N]                 → chat dump of master log
--   /gbl logs clear sync|sort|system|all
--   /gbl logs debug sync|sort|system on|off
function GBL:HandleLogsCommand(rest)
    rest = rest and strtrim(rest) or ""

    if rest == "" then
        self:ShowMasterLog()
        return
    end

    local sub, tail = rest:match("^(%S+)%s*(.*)$")
    sub = (sub or ""):lower()

    if sub == "dump" then
        local n = tonumber(tail)
        self:DumpMasterLog(n)
        return
    end

    if sub == "clear" then
        local target = (tail or ""):lower()
        if not LOG_CHANNEL_KEYS[target] then
            self:Print("Usage: /gbl logs clear sync|sort|system|all")
            return
        end
        if target == "all" then
            self:ClearLog(nil)
            self:Print("Cleared sync, sort, and system logs.")
        else
            self:ClearLog(target)
            self:Print("Cleared " .. target .. " log.")
        end
        return
    end

    if sub == "debug" then
        local channel, state = tail:match("^(%S+)%s+(%S+)$")
        channel = channel and channel:lower() or nil
        state = state and state:lower() or nil
        if not channel or not LOG_CHANNEL_KEYS[channel] or channel == "all"
           or (state ~= "on" and state ~= "off") then
            self:Print("Usage: /gbl logs debug sync|sort|system on|off")
            return
        end
        local enable = state == "on"
        if not (self.db and self.db.profile and self.db.profile[channel]) then
            self:Print("Channel " .. channel .. " has no profile config.")
            return
        end
        self.db.profile[channel].debugChat = enable
        self:Print(channel .. " debug-to-chat " .. (enable and "enabled" or "disabled") .. ".")
        return
    end

    self:Print("Usage: /gbl logs [dump N | clear sync|sort|system|all | debug sync|sort|system on|off]")
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
