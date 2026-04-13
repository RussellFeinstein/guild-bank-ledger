------------------------------------------------------------------------
-- GuildBankLedger — Sync.lua
-- Guild-wide transaction sync via AceComm
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Protocol constants
local PREFIX = "GBLSync"
local PROTOCOL_VERSION = 4
local MAX_RECORDS_PER_CHUNK = 15
local CHUNK_BYTE_BUDGET = 1600
local MAX_RETRIES = 3
local ACK_TIMEOUT = 15
local RECEIVE_CHUNK_TIMEOUT = 20
local MAX_NACK_RETRIES = 3
local HELLO_COOLDOWN = 60
local WHISPER_SAFE_BYTES = 2000
local ZONE_COOLDOWN = 5
local INTER_CHUNK_DELAY_NORMAL = 0.1
local INTER_CHUNK_DELAY_SLOW = 0.5
local FPS_THRESHOLD_LOW = 20
local FPS_THRESHOLD_RECOVER = 25
local FPS_SAMPLE_INTERVAL = 1.0
local CTL_BANDWIDTH_MIN = 400
local CTL_BACKOFF_DELAY = 1.0
local PEER_STALE_SECONDS = 300
local HELLO_HEARTBEAT_INTERVAL = 120

-- Expose constants for testing and UI
GBL.SYNC_PROTOCOL_VERSION = PROTOCOL_VERSION
GBL.SYNC_CHUNK_SIZE = MAX_RECORDS_PER_CHUNK
GBL.SYNC_PREFIX = PREFIX
GBL.SYNC_MAX_RETRIES = MAX_RETRIES
GBL.SYNC_MAX_NACK_RETRIES = MAX_NACK_RETRIES
GBL.SYNC_PEER_STALE_SECONDS = PEER_STALE_SECONDS
GBL.SYNC_HELLO_HEARTBEAT_INTERVAL = HELLO_HEARTBEAT_INTERVAL

------------------------------------------------------------------------
-- Compression (LibDeflate)
------------------------------------------------------------------------

--- Compress a serialized string for addon channel transmission.
-- @param serialized string AceSerializer output
-- @return string Compressed and encoded string
local function compressMessage(serialized)
    local LibDeflate = LibStub("LibDeflate")
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

--- Decompress a received addon channel string.
-- @param encoded string Compressed+encoded message
-- @return string|nil Decompressed serialized string, or nil on failure
local function decompressMessage(encoded)
    local LibDeflate = LibStub("LibDeflate")
    local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
    if not compressed then return nil end
    return LibDeflate:DecompressDeflate(compressed)
end

-- Expose for testing
GBL._compressMessage = compressMessage
GBL._decompressMessage = decompressMessage

-- Module state (session-only, not persisted)
local syncState = {
    sending = false,
    sendTarget = nil,
    sendChunks = {},
    sendChunkIndex = 0,
    sendTimer = nil,
    sendHardTimer = nil,
    sendRetryCount = 0,
    sendStartTime = 0,
    sendTotalRecords = 0,

    receiving = false,
    receiveSource = nil,
    receiveExpected = 0,
    receiveGot = 0,
    receiveStored = 0,
    receiveDuped = 0,
    receiveTimer = nil,
    receiveStartTime = 0,
    receiveNackCount = 0,

    peers = {},
    auditTrail = {},
    lastHelloTime = 0,

    -- Zone change protection
    zonePaused = false,
    zoneCooldownTimer = nil,

    -- FPS-adaptive throttling
    currentDelay = INTER_CHUNK_DELAY_NORMAL,
    fpsFrame = nil,
    lastFpsCheck = 0,
}

------------------------------------------------------------------------
-- Chat logging
------------------------------------------------------------------------

--- Print a sync message to chat if chatLog is enabled.
-- @param ... Arguments passed to self:Print()
function GBL:SyncLog(...)
    if self.db and self.db.profile.sync.chatLog then
        self:Print(...)
    end
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

--- Initialize sync system. Called from Core:OnEnable().
-- Registers AceComm prefix. Initial HELLO is deferred until
-- GUILD_ROSTER_UPDATE confirms guild data is available (see Core.lua).
function GBL:InitSync()
    if not self.db.profile.sync.enabled then return end
    self:RegisterComm(PREFIX, "OnSyncMessage")
    self:RegisterEvent("LOADING_SCREEN_ENABLED", "OnLoadingScreenStart")
    self:RegisterEvent("LOADING_SCREEN_DISABLED", "OnLoadingScreenEnd")
    self:StartHelloHeartbeat()
end

--- Enable sync at runtime (from UI toggle).
function GBL:EnableSync()
    self.db.profile.sync.enabled = true
    self:RegisterComm(PREFIX, "OnSyncMessage")
    self:RegisterEvent("LOADING_SCREEN_ENABLED", "OnLoadingScreenStart")
    self:RegisterEvent("LOADING_SCREEN_DISABLED", "OnLoadingScreenEnd")
    self:StartHelloHeartbeat()
    self:BroadcastHello()
end

--- Start the periodic HELLO heartbeat so peers don't expire while we're online.
-- Cancels any existing heartbeat first (guards against double-init).
function GBL:StartHelloHeartbeat()
    if syncState.helloHeartbeat then
        syncState.helloHeartbeat:Cancel()
    end
    syncState.helloHeartbeat = C_Timer.NewTicker(HELLO_HEARTBEAT_INTERVAL, function()
        if GBL.db.profile.sync.enabled then
            GBL:BroadcastHello()
        end
    end)
end

--- Disable sync at runtime (from UI toggle).
function GBL:DisableSync()
    self.db.profile.sync.enabled = false
    syncState.sending = false
    syncState.receiving = false
    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
        syncState.sendHardTimer = nil
    end
    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
        syncState.receiveTimer = nil
    end
    syncState.zonePaused = false
    if syncState.zoneCooldownTimer then
        syncState.zoneCooldownTimer:Cancel()
        syncState.zoneCooldownTimer = nil
    end
    if syncState.helloHeartbeat then
        syncState.helloHeartbeat:Cancel()
        syncState.helloHeartbeat = nil
    end
    self:StopFpsMonitor()
end

------------------------------------------------------------------------
-- HELLO broadcast
------------------------------------------------------------------------

--- Broadcast a HELLO message to the guild channel.
-- Includes addon version, protocol version, tx count, and last scan time.
-- Throttled by HELLO_COOLDOWN seconds between broadcasts.
function GBL:BroadcastHello(force)
    if not self.db.profile.sync.enabled then return end

    local now = GetServerTime()
    if not force and now - syncState.lastHelloTime < HELLO_COOLDOWN then return end

    local guildData = self:GetGuildData()
    if not guildData then return end

    syncState.lastHelloTime = now

    local txCount = #guildData.transactions + #guildData.moneyTransactions
    local dataHash = self:GetDataHash(guildData)

    local msg = self:Serialize({
        type = "HELLO",
        version = self.version,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        txCount = txCount,
        dataHash = dataHash,
        lastScanTime = self.lastScanTime or 0,
    })
    msg = compressMessage(msg)

    self:SendCommMessage(PREFIX, msg, "GUILD")
    self:AddAuditEntry("Sent HELLO (tx: " .. txCount
        .. ", hash: " .. dataHash .. ")")
end

--- Send a targeted HELLO reply to a specific peer via WHISPER.
-- Used when we receive a broadcast HELLO so the sender discovers us.
-- NOT subject to HELLO_COOLDOWN — targeted replies cannot cascade.
-- @param target string Character name to reply to
function GBL:SendHelloReply(target)
    if not self.db.profile.sync.enabled then return end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local txCount = #guildData.transactions + #guildData.moneyTransactions
    local dataHash = self:GetDataHash(guildData)

    local msg = self:Serialize({
        type = "HELLO",
        version = self.version,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        txCount = txCount,
        dataHash = dataHash,
        lastScanTime = self.lastScanTime or 0,
        isReply = true,
    })
    msg = compressMessage(msg)

    self:SendCommMessage(PREFIX, msg, "WHISPER", target)
    self:AddAuditEntry("Sent HELLO reply to " .. target
        .. " (tx: " .. txCount .. ", hash: " .. dataHash .. ")")
end

------------------------------------------------------------------------
-- Message dispatch
------------------------------------------------------------------------

--- AceComm callback — dispatches incoming sync messages by type.
-- @param prefix string AceComm prefix
-- @param message string Serialized message data
-- @param distribution string Channel type ("GUILD", "WHISPER", etc.)
-- @param sender string Sender character name
function GBL:OnSyncMessage(_prefix, message, distribution, sender)
    if not self.db.profile.sync.enabled then return end

    -- Ignore our own messages (Ambiguate handles realm-qualified names in retail)
    local myName = UnitName("player")
    if Ambiguate(sender, "none") == myName then return end

    local decompressed = decompressMessage(message)
    if not decompressed then return end
    local success, data = self:Deserialize(decompressed)
    if not success or type(data) ~= "table" then return end

    local msgType = data.type

    -- Only log non-chunk messages to avoid flooding the audit trail
    if msgType ~= "ACK" and msgType ~= "NACK" and msgType ~= "SYNC_DATA" then
        self:AddAuditEntry("RECV " .. tostring(distribution) .. " from "
            .. tostring(sender) .. " (" .. tostring(msgType) .. ")")
    end

    -- Protocol version gate (only on typed messages that carry the field)
    -- Track outdated peers in the peer list before rejecting their messages,
    -- so they appear in the Online Peers UI as "outdated (no sync)".
    if data.protocolVersion and data.protocolVersion ~= PROTOCOL_VERSION then
        if msgType == "HELLO" then
            local cleanSender = Ambiguate(sender, "none")
            syncState.peers[cleanSender] = {
                version = data.version or "?",
                txCount = data.txCount or 0,
                dataHash = data.dataHash,
                lastScanTime = data.lastScanTime or 0,
                lastSeen = GetServerTime(),
                outdated = true,
            }
        end
        self:AddAuditEntry("Ignored message from " .. sender
            .. " (protocol v" .. tostring(data.protocolVersion) .. ")")
        return
    end

    -- Guild isolation — reject messages from a different guild
    if data.guild then
        local myGuild = self:GetGuildName()
        if myGuild and data.guild ~= myGuild then
            return
        end
    end

    -- Track peer liveness from ANY valid message, not just HELLO.
    -- Ensures peers appear in the online list even if their HELLO was missed.
    local cleanSender = Ambiguate(sender, "none")
    if syncState.peers[cleanSender] then
        syncState.peers[cleanSender].lastSeen = GetServerTime()
    elseif msgType ~= "HELLO" then
        -- Minimal peer entry — HELLO handler will overwrite with full data
        syncState.peers[cleanSender] = {
            lastSeen = GetServerTime(),
            txCount = 0,
        }
    end

    if msgType == "HELLO" then
        self:HandleHello(sender, data)
    elseif msgType == "SYNC_REQUEST" then
        self:HandleSyncRequest(sender, data)
    elseif msgType == "SYNC_DATA" then
        self:HandleSyncData(sender, data)
    elseif msgType == "ACK" then
        self:HandleAck(sender, data)
    elseif msgType == "NACK" then
        self:HandleNack(sender, data)
    end
end

------------------------------------------------------------------------
-- HELLO handling
------------------------------------------------------------------------

--- Process an incoming HELLO from another guild member.
-- Updates peer list. If they have more data and autoSync is on,
-- initiates a sync request.
-- @param sender string Sender name
-- @param data table Deserialized HELLO payload
function GBL:HandleHello(sender, data)
    self:UpdatePeer(sender, data)

    self:AddAuditEntry("Received HELLO from " .. sender
        .. " (tx: " .. (data.txCount or 0)
        .. ", hash: " .. tostring(data.dataHash or "none")
        .. ", v" .. tostring(data.version or "?")
        .. ", reply=" .. tostring(data.isReply or false) .. ")")

    -- Reply to broadcast HELLOs so the sender discovers us.
    -- Uses WHISPER (targeted) — each peer replies individually.
    -- Do NOT reply to reply HELLOs (prevents infinite ping-pong).
    if not data.isReply then
        self:SendHelloReply(sender)
    end

    -- Exact version match — refuse sync on any version difference
    if data.version and data.version ~= self.version then
        local cleanSender = Ambiguate(sender, "none")
        if syncState.peers[cleanSender] then
            syncState.peers[cleanSender].outdated = true
        end
        self:AddAuditEntry("WARNING: " .. sender .. " on v"
            .. tostring(data.version) .. " (version mismatch, need v" .. self.version .. ")")
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local localCount = #guildData.transactions + #guildData.moneyTransactions
    local remoteCount = data.txCount or 0

    local localDataHash = data.dataHash and self:GetDataHash(guildData) or nil

    -- Surface bucket info so we can verify binning is working
    local buckets = self:ComputeBucketHashes(guildData)
    local bucketCount = 0
    for _ in pairs(buckets) do bucketCount = bucketCount + 1 end

    self:AddAuditEntry("Hash compare: local=" .. tostring(localDataHash or "none")
        .. " (" .. localCount .. " tx, " .. bucketCount .. " buckets)"
        .. ", remote=" .. tostring(data.dataHash or "none")
        .. " (" .. remoteCount .. " tx)")

    -- Fast path: skip when datasets are identical (hash + count match)
    if localDataHash and data.dataHash == localDataHash and localCount == remoteCount then
        self:AddAuditEntry("Skipped sync from " .. sender
            .. " — datasets identical (hash: " .. localDataHash
            .. ", tx: " .. localCount .. ")")
        return
    end

    -- Determine if sync is needed
    local shouldSync = false
    local syncReason
    if localDataHash and data.dataHash ~= localDataHash then
        -- Hashes differ — we have records they don't, or vice versa
        shouldSync = true
        syncReason = "hash mismatch"
    elseif not data.dataHash and remoteCount > localCount then
        -- No hash support (old version) — fall back to count comparison
        shouldSync = true
        syncReason = "count (no hash, remote has more)"
    end

    if shouldSync and not syncState.receiving and self.db.profile.sync.autoSync then
        self:AddAuditEntry("Sync triggered by " .. syncReason
            .. " — requesting from " .. sender)
        local sinceTimestamp = guildData.syncState.lastSyncTimestamp or 0
        self:RequestSync(sender, sinceTimestamp)
    else
        -- Log why we didn't sync so stalls are diagnosable
        local reason
        if not shouldSync then
            reason = "datasets match or no sync needed (local=" .. localCount
                .. ", remote=" .. remoteCount .. ")"
        elseif syncState.receiving then
            reason = "already receiving from " .. (syncState.receiveSource or "?")
        elseif not self.db.profile.sync.autoSync then
            reason = "autoSync disabled"
        end
        if reason then
            self:AddAuditEntry("Skipped sync from " .. sender .. " (" .. reason .. ")")
        end
    end
end

------------------------------------------------------------------------
-- Payload helpers
------------------------------------------------------------------------

-- baseName is now GBL:StripRealm() in Core.lua — used at call sites below

--- Strip reconstructable fields from a transaction record for sync.
-- Removes itemLink (large, reconstructable from itemID) to reduce payload.
-- Returns a shallow copy — does not mutate the original record.
-- @param record table Transaction record
-- @return table Stripped copy
local function stripForSync(record)
    local copy = {}
    for k, v in pairs(record) do
        copy[k] = v
    end
    -- Strip reconstructable/derivable fields to maximize records per chunk
    copy.itemLink = nil      -- large, reconstructable from itemID
    copy.category = nil      -- derivable from classID + subclassID
    copy.tabName = nil       -- derivable from tab number (backfilled on bank open)
    copy.destTabName = nil   -- derivable from destTab number
    copy.scanTime = nil      -- receiver sets receipt time
    copy.scannedBy = nil     -- receiver knows the sender
    copy._occurrence = nil   -- embedded in the id string already
    return copy
end

--- Estimate the serialized byte size of a single record.
-- Conservative upper bound matching AceSerializer output.
-- Does NOT call Serialize() — safe for tests and fast for large batches.
-- @param record table A stripped transaction record
-- @return number Estimated byte count
local function estimateRecordBytes(record)
    local bytes = 6  -- table wrapper overhead (^T ... ^t)
    for k, v in pairs(record) do
        bytes = bytes + #tostring(k) + 3     -- key + delimiters
        bytes = bytes + #tostring(v) + 3     -- value + delimiters
    end
    return bytes
end

--- Restore fields stripped by stripForSync on received records.
-- Called on each record before StoreTx/StoreMoneyTx during sync receive.
-- Must be resilient to any combination of missing fields — the sender
-- may be running any past or future addon version.
-- Guarantees after return: record.id, record.timestamp, record.scanTime,
-- record.scannedBy are always non-nil.
-- @param record table Transaction record received via sync
-- @param sender string Name of the peer who sent this record
local function reconstructSyncRecord(record, sender)
    -- 1. Ensure timestamp exists (needed for id computation below)
    --    Priority: explicit timestamp → recover from id → fallback to now
    if not record.timestamp and record.id then
        local timeSlot = record.id:match("(%d+):?%d*$")
        if timeSlot then
            record.timestamp = tonumber(timeSlot) * 3600
        end
    end
    if not record.timestamp then
        record.timestamp = GetServerTime()
    end

    -- 2. Ensure id exists (needed for dedup)
    --    Priority: explicit id → compute from fields
    if not record.id then
        record.id = GBL:ComputeTxHash(record) .. ":0"
    end

    -- 3. Restore _occurrence from id suffix (format: "baseHash:N")
    record._occurrence = tonumber(record.id:match(":(%d+)$")) or 0

    -- 4. Restore category from classID + subclassID (item records only)
    if record.itemID and record.classID then
        record.category = GBL:CategorizeItem(record.classID, record.subclassID or 0)
    end

    -- 5. Set scanTime to receipt time; mark sync origin
    record.scanTime = GetServerTime()
    record.scannedBy = "sync:" .. GBL:ResolvePlayerName(sender or "unknown")
    -- tabName/destTabName intentionally left nil — BackfillTabNames fills them

    -- 6. Validate required fields — reject corrupted records
    --    AceSerializer can mangle field boundaries during transit, producing
    --    garbage keys like "typyer" (type+player merged). Reject anything
    --    missing the two fields every record must have.
    if not record.type or record.type == "" then return false end
    if not record.player or record.player == "" then return false end

    -- 7. Ensure player name is realm-qualified
    record.player = GBL:ResolvePlayerName(record.player)
    return true
end

------------------------------------------------------------------------
-- Sync request / response
------------------------------------------------------------------------

--- Send a SYNC_REQUEST to a specific peer.
-- @param target string Target player name
-- @param sinceTimestamp number Only request transactions after this time
function GBL:RequestSync(target, sinceTimestamp)
    if syncState.receiving then return end

    syncState.receiving = true
    syncState.receiveSource = target
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveDuped = 0
    syncState.receiveNormalized = 0
    syncState.receiveExpected = 0
    syncState.receiveStartTime = GetServerTime()

    sinceTimestamp = sinceTimestamp or 0

    local guildData = self:GetGuildData()
    local bucketHashes = guildData and self:ComputeBucketHashes(guildData) or nil

    local msg = self:Serialize({
        type = "SYNC_REQUEST",
        sinceTimestamp = sinceTimestamp,
        bucketHashes = bucketHashes,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    msg = compressMessage(msg)

    local bucketCount = 0
    if bucketHashes then
        for _ in pairs(bucketHashes) do bucketCount = bucketCount + 1 end
    end

    local msgBytes = #msg
    self:SendCommMessage(PREFIX, msg, "WHISPER", target)
    self:SyncLog("Sync: requesting data from " .. target .. "...")
    self:AddAuditEntry("Requesting sync from " .. target
        .. " (since " .. sinceTimestamp
        .. ", " .. bucketCount .. " bucket days"
        .. ", " .. msgBytes .. " bytes)")
    self:SendMessage("GBL_SYNC_STARTED", target)

    -- Request timeout — if no SYNC_DATA arrives, NACK for chunk 1 instead of aborting
    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
    end
    syncState.receiveNackCount = 0
    syncState.receiveTimer = C_Timer.NewTicker(RECEIVE_CHUNK_TIMEOUT, function()
        if not syncState.receiving then return end
        if syncState.receiveGot == 0 then
            if syncState.receiveNackCount >= MAX_NACK_RETRIES then
                self:SyncLog("Sync: no response from " .. target
                    .. " after " .. MAX_NACK_RETRIES .. " retries — aborting")
                self:AddAuditEntry("Request timeout — no data from "
                    .. target .. " after " .. MAX_NACK_RETRIES .. " retries")
                self:FinishReceiving(target)
            else
                self:SendNack(target, 1)
            end
        end
    end, 1)
end

--- Handle an incoming SYNC_REQUEST — gather and send matching transactions.
-- @param sender string Requester name
-- @param data table Deserialized request payload
function GBL:HandleSyncRequest(sender, data)
    if syncState.sending then
        self:SyncLog("Sync: declined request from " .. sender
            .. " (already sending to " .. (syncState.sendTarget or "?") .. ")")
        self:AddAuditEntry("Declined sync from " .. sender
            .. " (already sending to " .. (syncState.sendTarget or "?") .. ")")
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local txToSend = {}
    local moneyToSend = {}

    if data.bucketHashes then
        -- Bucket-filtered sync: only send records from days where hashes differ
        local localBuckets = self:ComputeBucketHashes(guildData)
        local diffDays = {}
        local totalLocalDays = 0
        local totalRemoteDays = 0
        local matchingDays = 0

        for _ in pairs(localBuckets) do totalLocalDays = totalLocalDays + 1 end
        for _ in pairs(data.bucketHashes) do totalRemoteDays = totalRemoteDays + 1 end

        for dayKey, localHash in pairs(localBuckets) do
            if localHash ~= (data.bucketHashes[dayKey] or 0) then
                diffDays[dayKey] = true
            else
                matchingDays = matchingDays + 1
            end
        end

        -- Build human-readable date list for differing buckets
        local diffCount = 0
        local diffDateList = {}
        for dayKey in pairs(diffDays) do
            diffCount = diffCount + 1
            -- Bucket key = floor(timeSlot / 6), so timestamp = key * 6 * 3600
            local ts = dayKey * 6 * 3600
            diffDateList[#diffDateList + 1] = date("%Y-%m-%d %H:00", ts)
        end
        table.sort(diffDateList)

        for _, tx in ipairs(guildData.transactions) do
            local dayKey = self:BucketKeyForRecord(tx)
            if diffDays[dayKey] then
                txToSend[#txToSend + 1] = stripForSync(tx)
            end
        end
        for _, tx in ipairs(guildData.moneyTransactions) do
            local dayKey = self:BucketKeyForRecord(tx)
            if diffDays[dayKey] then
                moneyToSend[#moneyToSend + 1] = stripForSync(tx)
            end
        end

        self:AddAuditEntry("Bucket filter: " .. totalLocalDays .. " local bucket(s), "
            .. totalRemoteDays .. " remote bucket(s), "
            .. matchingDays .. " matching, " .. diffCount .. " differing")
        if diffCount > 0 then
            self:AddAuditEntry("Differing dates: " .. table.concat(diffDateList, ", "))
        end
        self:AddAuditEntry("Sending " .. #txToSend .. " item tx + "
            .. #moneyToSend .. " money tx from differing days")
    else
        -- Fallback: old-style sinceTimestamp filtering (no bucket hashes from requester)
        local sinceTimestamp = data.sinceTimestamp or 0
        local totalLocal = #guildData.transactions + #guildData.moneyTransactions
        self:AddAuditEntry("No bucket hashes in request — falling back to sinceTimestamp="
            .. sinceTimestamp .. " (local has " .. totalLocal .. " total tx)")
        for _, tx in ipairs(guildData.transactions) do
            local when = tx.scanTime or tx.timestamp or 0
            if when > sinceTimestamp then
                txToSend[#txToSend + 1] = stripForSync(tx)
            end
        end
        for _, tx in ipairs(guildData.moneyTransactions) do
            local when = tx.scanTime or tx.timestamp or 0
            if when > sinceTimestamp then
                moneyToSend[#moneyToSend + 1] = stripForSync(tx)
            end
        end
        self:AddAuditEntry("sinceTimestamp filter: sending " .. #txToSend
            .. " item tx + " .. #moneyToSend .. " money tx")
    end

    -- Prepare and send chunks
    local chunks = self:PrepareChunks(txToSend, moneyToSend)

    if #chunks == 0 then
        -- Nothing to send — send an empty chunk so receiver finishes cleanly
        local msg = self:Serialize({
            type = "SYNC_DATA",
            chunk = 1,
            totalChunks = 1,
            transactions = {},
            moneyTransactions = {},
            protocolVersion = PROTOCOL_VERSION,
            guild = self:GetGuildName(),
        })
        msg = compressMessage(msg)
        self:SendCommMessage(PREFIX, msg, "WHISPER", sender)
        self:AddAuditEntry("Sent empty sync to " .. sender)
        return
    end

    syncState.sending = true
    syncState.sendTarget = sender
    syncState.sendChunks = chunks
    syncState.sendChunkIndex = 0
    syncState.sendStartTime = GetServerTime()
    syncState.sendTotalRecords = #txToSend + #moneyToSend
    self:StartFpsMonitor()

    local totalTx = #txToSend + #moneyToSend
    self:SyncLog("Sync: sending " .. totalTx .. " records to " .. sender
        .. " in " .. #chunks .. " chunk(s)")
    self:AddAuditEntry("Sending " .. totalTx
        .. " tx to " .. sender .. " in " .. #chunks .. " chunk(s)")

    self:SendNextChunk()
end

------------------------------------------------------------------------
-- Chunking
------------------------------------------------------------------------

--- Split transaction arrays into size-aware chunks.
-- Each chunk stays under CHUNK_BYTE_BUDGET estimated bytes and
-- MAX_RECORDS_PER_CHUNK records (hard cap).
-- @param transactions table Array of stripped item transaction records
-- @param moneyTransactions table Array of stripped money transaction records
-- @return table Array of chunk tables, each with .transactions and .moneyTransactions
function GBL:PrepareChunks(transactions, moneyTransactions)
    local chunks = {}
    local currentTx = {}
    local currentMoney = {}
    local count = 0
    local estimatedBytes = 0

    local function sealChunk()
        if #currentTx > 0 or #currentMoney > 0 then
            chunks[#chunks + 1] = {
                transactions = currentTx,
                moneyTransactions = currentMoney,
            }
        end
        currentTx = {}
        currentMoney = {}
        count = 0
        estimatedBytes = 0
    end

    for _, tx in ipairs(transactions) do
        local recBytes = estimateRecordBytes(tx)
        if count > 0 and (estimatedBytes + recBytes > CHUNK_BYTE_BUDGET
                          or count >= MAX_RECORDS_PER_CHUNK) then
            sealChunk()
        end
        currentTx[#currentTx + 1] = tx
        count = count + 1
        estimatedBytes = estimatedBytes + recBytes
    end

    for _, tx in ipairs(moneyTransactions) do
        local recBytes = estimateRecordBytes(tx)
        if count > 0 and (estimatedBytes + recBytes > CHUNK_BYTE_BUDGET
                          or count >= MAX_RECORDS_PER_CHUNK) then
            sealChunk()
        end
        currentMoney[#currentMoney + 1] = tx
        count = count + 1
        estimatedBytes = estimatedBytes + recBytes
    end

    sealChunk()
    return chunks
end

--- Send the next chunk in the queue. Aborts if no more chunks remain.
function GBL:SendNextChunk()
    if not syncState.sending then return end

    -- Zone change protection — defer until loading screen ends
    if syncState.zonePaused then
        self:AddAuditEntry("SendNextChunk deferred — zone transition in progress")
        return
    end

    -- ChatThrottleLib awareness — defer if other addons are using bandwidth
    if not self:HasSyncBandwidth() then
        C_Timer.After(CTL_BACKOFF_DELAY, function()
            self:SendNextChunk()
        end)
        return
    end

    syncState.sendChunkIndex = syncState.sendChunkIndex + 1
    local idx = syncState.sendChunkIndex
    local chunk = syncState.sendChunks[idx]

    if not chunk then
        syncState.sendChunkIndex = syncState.sendChunkIndex - 1
        self:FinishSending()
        return
    end

    local serialized = self:Serialize({
        type = "SYNC_DATA",
        chunk = idx,
        totalChunks = #syncState.sendChunks,
        transactions = chunk.transactions,
        moneyTransactions = chunk.moneyTransactions,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    local msg = compressMessage(serialized)

    local rawLen = #serialized
    local msgLen = #msg
    local chunkRecords = #chunk.transactions + #chunk.moneyTransactions
    local total = #syncState.sendChunks
    self:SyncLog("Sync: sending chunk " .. idx .. "/" .. total
        .. " to " .. (syncState.sendTarget or "?")
        .. " (" .. chunkRecords .. " records, " .. rawLen .. "b→" .. msgLen .. "b)")
    -- Only audit-log every 10th chunk and the last one to avoid flooding the trail
    if idx == 1 or idx == total or idx % 10 == 0 then
        self:AddAuditEntry("Sending chunk " .. idx .. "/" .. total
            .. " to " .. (syncState.sendTarget or "?")
            .. " (" .. chunkRecords .. " records, " .. rawLen .. "→" .. msgLen .. " bytes)")
    end

    if msgLen > WHISPER_SAFE_BYTES then
        self:Print("|cffff0000Sync WARNING:|r chunk " .. idx .. " is " .. msgLen
            .. "b (>" .. WHISPER_SAFE_BYTES .. ") — may be dropped!")
        self:AddAuditEntry("WARNING: chunk " .. idx .. " is " .. msgLen
            .. " bytes (>" .. WHISPER_SAFE_BYTES
            .. ") — may be silently dropped by AceComm WHISPER")
    end

    -- Hard timeout safety net — fires if AceComm callback never completes.
    -- Use C_Timer.NewTicker(n, cb, 1) for a cancellable one-shot timer;
    -- C_Timer.After returns nil in WoW so it can't be cancelled or tracked.
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
    end
    syncState.sendHardTimer = C_Timer.NewTicker(120, function()
        if syncState.sending then
            self:SyncLog("Sync: hard timeout (120s) — AceComm never finished transmitting, aborting")
            self:AddAuditEntry("Send hard timeout — aborting")
            self:FinishSending()
        end
    end, 1)

    -- ACK timer deferred until message fully transmitted via AceComm callback.
    -- AceComm calls callbackFn(callbackArg, bytesSent, totalLen) per CTL piece.
    self:SendCommMessage(PREFIX, msg, "WHISPER", syncState.sendTarget, "NORMAL",
        function(_cbArg, sent, totalBytes)
            if sent < totalBytes then return end
            -- Message fully transmitted — now start ACK timer
            if syncState.sendTimer then
                syncState.sendTimer:Cancel()
            end
            syncState.sendTimer = C_Timer.NewTicker(ACK_TIMEOUT, function()
                if not syncState.sending then return end
                if syncState.sendRetryCount < MAX_RETRIES then
                    syncState.sendRetryCount = syncState.sendRetryCount + 1
                    syncState.sendChunkIndex = syncState.sendChunkIndex - 1
                    local retryChunk = syncState.sendChunkIndex + 1
                    self:SyncLog("Sync: ACK timeout, retrying chunk " .. retryChunk
                        .. " (attempt " .. (syncState.sendRetryCount + 1)
                        .. "/" .. (MAX_RETRIES + 1) .. ")")
                    self:AddAuditEntry("Retrying chunk " .. retryChunk
                        .. " (attempt " .. (syncState.sendRetryCount + 1) .. "/"
                        .. (MAX_RETRIES + 1) .. ")")
                    self:SendNextChunk()
                else
                    self:SyncLog("Sync: ACK timeout from "
                        .. (syncState.sendTarget or "?")
                        .. " after " .. (MAX_RETRIES + 1) .. " attempts — aborting")
                    self:AddAuditEntry("ACK timeout from "
                        .. (syncState.sendTarget or "unknown")
                        .. " after " .. (MAX_RETRIES + 1) .. " attempts — aborting")
                    self:FinishSending()
                end
            end, 1)
        end)
end

--- Clean up sending state after sync completes or aborts.
function GBL:FinishSending()
    local target = syncState.sendTarget or "?"
    local sent = syncState.sendChunkIndex
    local total = #syncState.sendChunks
    local elapsed = GetServerTime() - syncState.sendStartTime

    self:SyncLog("Sync: send complete to " .. target
        .. " (" .. sent .. "/" .. total .. " chunks, " .. elapsed .. "s)")
    self:AddAuditEntry("Send complete to " .. target
        .. " — " .. sent .. "/" .. total .. " chunks"
        .. ", " .. syncState.sendTotalRecords .. " records, " .. elapsed .. "s")

    syncState.sending = false
    syncState.sendTarget = nil
    syncState.sendChunks = {}
    syncState.sendChunkIndex = 0
    syncState.sendRetryCount = 0
    syncState.sendStartTime = 0
    syncState.sendTotalRecords = 0
    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
        syncState.sendHardTimer = nil
    end
    self:StopFpsMonitor()
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

--- Normalize a local record's ID and timestamp to match an incoming record.
-- Always adopts the sender's ID and timestamp (sender-wins) so that the
-- receiver fully converges with the sender in a single sync cycle.
-- Also normalizes timestamp to ensure consistent bucket hash placement
-- (bucket hashes group by timestamp; divergent timestamps cause the same
-- record to land in different buckets, triggering perpetual re-syncs).
-- @param incomingRecord table Received record with its ID
-- @param matchedKey string The local seenTxHashes key that fuzzy-matched
-- @param guildData table Guild data from AceDB
-- @param idIndex table Pre-built lookup of record.id → record reference
-- @return boolean True if normalization happened
function GBL:NormalizeRecordId(incomingRecord, matchedKey, guildData, idIndex)
    local incomingId = incomingRecord.id
    if not incomingId or incomingId == matchedKey then return false end

    -- Sender-wins: always adopt the incoming ID so the receiver fully
    -- converges with the sender in one cycle. The sync protocol serializes
    -- direction (one side sends per cycle), preventing oscillation.
    local newTs = incomingRecord.timestamp or 0

    -- Find local record via pre-built index
    local localRecord = idIndex and idIndex[matchedKey] or nil
    if localRecord then
        localRecord.id = incomingId
        localRecord._occurrence = incomingRecord._occurrence
        -- Normalize timestamp for consistent bucket hash placement
        localRecord.timestamp = newTs
    end
    -- If record compacted/pruned: only seenTxHashes updated (harmless)

    -- Atomic seenTxHashes update: add new FIRST, then remove old
    guildData.seenTxHashes[incomingId] = newTs
    guildData.seenTxHashes[matchedKey] = nil

    return true
end

--- Process an incoming SYNC_DATA chunk — dedup, normalize IDs, and store.
-- When a fuzzy duplicate is detected, adopts the sender's ID and timestamp
-- (sender-wins) so the receiver fully converges in a single sync cycle.
-- Sends an ACK back to the sender after processing.
-- @param sender string Sender name
-- @param data table Deserialized chunk payload
function GBL:HandleSyncData(sender, data)
    if not syncState.receiving then
        -- Unexpected but valid data — start receiving
        if not data.transactions and not data.moneyTransactions then return end
        syncState.receiving = true
        syncState.receiveSource = sender
        syncState.receiveGot = 0
        syncState.receiveStored = 0
    elseif self:StripRealm(sender) ~= self:StripRealm(syncState.receiveSource) then
        -- Reject data from a different sender during active receive
        self:AddAuditEntry("Ignored SYNC_DATA from " .. sender
            .. " (receiving from " .. (syncState.receiveSource or "?") .. ")")
        return
    end

    self._syncReceiving = true

    local guildData = self:GetGuildData()
    if not guildData then return end

    -- Build ID lookup table for O(1) record access during normalization
    local idIndex = {}
    for _, tx in ipairs(guildData.transactions) do
        if tx.id then idIndex[tx.id] = tx end
    end
    for _, tx in ipairs(guildData.moneyTransactions) do
        if tx.id then idIndex[tx.id] = tx end
    end

    local itemStored, itemDuped = 0, 0
    local moneyStored, moneyDuped = 0, 0
    local normalized = 0
    local chunkTotal = #(data.transactions or {}) + #(data.moneyTransactions or {})

    for _, tx in ipairs(data.transactions or {}) do
        if not reconstructSyncRecord(tx, sender) then
            itemDuped = itemDuped + 1
        else
            local isDup, matchedKey = self:IsDuplicate(tx, guildData)
            if isDup then
                if matchedKey and matchedKey ~= tx.id then
                    if self:NormalizeRecordId(tx, matchedKey, guildData, idIndex) then
                        normalized = normalized + 1
                        local rec = idIndex[matchedKey]
                        if rec then
                            idIndex[tx.id] = rec
                            idIndex[matchedKey] = nil
                        end
                    end
                end
                itemDuped = itemDuped + 1
            else
                if self:StoreTx(tx, guildData) then
                    itemStored = itemStored + 1
                    idIndex[tx.id] = tx
                end
            end
        end
    end

    for _, tx in ipairs(data.moneyTransactions or {}) do
        if not reconstructSyncRecord(tx, sender) then
            moneyDuped = moneyDuped + 1
        else
            local isDup, matchedKey = self:IsDuplicate(tx, guildData)
            if isDup then
                if matchedKey and matchedKey ~= tx.id then
                    if self:NormalizeRecordId(tx, matchedKey, guildData, idIndex) then
                        normalized = normalized + 1
                        local rec = idIndex[matchedKey]
                        if rec then
                            idIndex[tx.id] = rec
                            idIndex[matchedKey] = nil
                        end
                    end
                end
                moneyDuped = moneyDuped + 1
            else
                if self:StoreMoneyTx(tx, guildData) then
                    moneyStored = moneyStored + 1
                    idIndex[tx.id] = tx
                end
            end
        end
    end

    syncState.receiveNormalized = (syncState.receiveNormalized or 0) + normalized

    local stored = itemStored + moneyStored
    local duped = itemDuped + moneyDuped
    syncState.receiveGot = syncState.receiveGot + 1
    syncState.receiveStored = syncState.receiveStored + stored
    syncState.receiveDuped = syncState.receiveDuped + duped
    syncState.receiveExpected = data.totalChunks or 1

    -- Reset receive timeout — NACK for missing chunk instead of aborting
    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
    end
    syncState.receiveNackCount = 0  -- reset on successful chunk receipt

    -- Only set timeout if more chunks expected
    if not (data.chunk and data.totalChunks and data.chunk >= data.totalChunks) then
        syncState.receiveTimer = C_Timer.NewTicker(RECEIVE_CHUNK_TIMEOUT, function()
            if not syncState.receiving then return end
            if syncState.receiveNackCount >= MAX_NACK_RETRIES then
                self:SyncLog("Sync: chunk " .. (syncState.receiveGot + 1) .. "/"
                    .. syncState.receiveExpected .. " failed after "
                    .. MAX_NACK_RETRIES .. " retries — aborting")
                self:AddAuditEntry("NACK limit reached for chunk "
                    .. (syncState.receiveGot + 1) .. " from "
                    .. (syncState.receiveSource or "unknown") .. " — aborting")
                self:FinishReceiving(syncState.receiveSource)
            else
                self:SendNack(syncState.receiveSource, syncState.receiveGot + 1)
            end
        end, 1)
    end

    -- Send ACK
    local ackMsg = self:Serialize({
        type = "ACK",
        chunk = data.chunk,
        stored = stored,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    ackMsg = compressMessage(ackMsg)
    self:SendCommMessage(PREFIX, ackMsg, "WHISPER", sender)

    self:SyncLog("Sync: chunk " .. (data.chunk or "?") .. "/"
        .. (data.totalChunks or "?") .. " from " .. sender
        .. " — " .. stored .. " new, " .. duped .. " duped"
        .. " (total so far: " .. syncState.receiveStored .. " new)")

    self:AddAuditEntry("Received chunk " .. (data.chunk or "?") .. "/"
        .. (data.totalChunks or "?") .. " from " .. sender
        .. " (" .. chunkTotal .. " records: "
        .. itemStored .. " item new, " .. itemDuped .. " item duped, "
        .. moneyStored .. " money new, " .. moneyDuped .. " money duped)")

    self:SendMessage("GBL_SYNC_PROGRESS", sender,
        data.chunk or 0, data.totalChunks or 0, stored)

    -- Complete if this was the last chunk
    if data.chunk and data.totalChunks and data.chunk >= data.totalChunks then
        self:FinishReceiving(sender)
    end
end

--- Process an incoming ACK from the receiver.
-- Cancels the timeout and schedules the next chunk.
-- @param sender string Sender name
-- @param data table Deserialized ACK payload
function GBL:HandleAck(sender, data)
    if not syncState.sending or self:StripRealm(sender) ~= self:StripRealm(syncState.sendTarget) then return end

    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end

    local ackedChunk = data and data.chunk or syncState.sendChunkIndex
    local total = #syncState.sendChunks
    -- Only audit-log every 10th ACK and the last one
    if ackedChunk == 1 or ackedChunk == total or ackedChunk % 10 == 0 then
        self:AddAuditEntry("ACK from " .. sender .. " for chunk " .. ackedChunk
            .. "/" .. total)
    end

    syncState.sendRetryCount = 0

    -- Adaptive delay between chunks (slows down when FPS is low)
    C_Timer.After(self:GetSyncDelay(), function()
        self:SendNextChunk()
    end)
end

--- Clean up receiving state and persist sync metadata.
-- @param sender string The peer we synced from
function GBL:FinishReceiving(sender)
    local totalStored = syncState.receiveStored

    local guildData = self:GetGuildData()
    if guildData then
        -- Always checkpoint — bucket fingerprints handle the "still behind"
        -- case more precisely than timestamp rewind. This prevents re-sending
        -- everything on the next sync after a partial failure.
        guildData.syncState.lastSyncTimestamp = GetServerTime()

        guildData.syncState.peers[Ambiguate(sender, "none")] = {
            lastSync = GetServerTime(),
            stored = totalStored,
        }
    end

    local totalDuped = syncState.receiveDuped
    local totalNormalized = syncState.receiveNormalized or 0
    local elapsed = GetServerTime() - syncState.receiveStartTime
    local chunksGot = syncState.receiveGot

    -- CRITICAL: If any IDs were normalized in-place, the hash cache is stale
    -- (keyed by txCount which didn't change). Must reset before GetDataHash
    -- or the next HELLO sends a stale hash → infinite sync loop.
    if totalNormalized > 0 then
        self:ResetHashCache()
    end

    local totalTxAfter = guildData
        and (#guildData.transactions + #guildData.moneyTransactions) or 0
    local newHash = guildData and self:GetDataHash(guildData) or 0

    local normalizedMsg = totalNormalized > 0
        and (", " .. totalNormalized .. " IDs converged") or ""
    self:SyncLog("Sync complete from " .. (sender or "?") .. ": "
        .. totalStored .. " new, " .. totalDuped .. " duped"
        .. normalizedMsg
        .. " (" .. chunksGot .. " chunks, " .. elapsed .. "s)")
    self:AddAuditEntry("Sync complete from " .. (sender or "unknown")
        .. " — " .. totalStored .. " new, " .. totalDuped .. " duped"
        .. ", " .. totalNormalized .. " normalized"
        .. ", " .. chunksGot .. " chunks, " .. elapsed .. "s"
        .. " | total tx now: " .. totalTxAfter .. ", hash: " .. newHash)

    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
        syncState.receiveTimer = nil
    end

    syncState.receiving = false
    syncState.receiveSource = nil
    syncState.receiveExpected = 0
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveDuped = 0
    syncState.receiveNormalized = 0
    syncState.receiveStartTime = 0
    syncState.receiveNackCount = 0
    self._syncReceiving = false

    self:SendMessage("GBL_SYNC_COMPLETE", sender, totalStored)

    -- Refresh UI if visible
    if self.mainFrame and self.mainFrame.frame
        and self.mainFrame.frame:IsShown() then
        self:RefreshUI()
    end
end

------------------------------------------------------------------------
-- Peer tracking
------------------------------------------------------------------------

--- Update the session peer list with data from a HELLO message.
-- @param sender string Peer name
-- @param data table HELLO payload
function GBL:UpdatePeer(sender, data)
    syncState.peers[Ambiguate(sender, "none")] = {
        version = data.version,
        txCount = data.txCount or 0,
        dataHash = data.dataHash,
        lastScanTime = data.lastScanTime or 0,
        lastSeen = GetServerTime(),
    }
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Append an entry to the session audit trail (capped at 200).
-- @param message string Human-readable log entry
function GBL:AddAuditEntry(message)
    table.insert(syncState.auditTrail, 1, {
        timestamp = GetServerTime(),
        message = message,
    })
    while #syncState.auditTrail > 200 do
        table.remove(syncState.auditTrail)
    end
end

------------------------------------------------------------------------
-- Public getters (for UI and tests)
------------------------------------------------------------------------

--- Return a snapshot of current sync status.
-- @return table Status fields
function GBL:GetSyncStatus()
    return {
        enabled = self.db.profile.sync.enabled,
        sending = syncState.sending,
        receiving = syncState.receiving,
        sendTarget = syncState.sendTarget,
        receiveSource = syncState.receiveSource,
        sendProgress = syncState.sendChunkIndex .. "/" .. #syncState.sendChunks,
        receiveProgress = syncState.receiveGot .. "/" .. syncState.receiveExpected,
        zonePaused = syncState.zonePaused,
    }
end

--- Return active peers (seen within PEER_STALE_SECONDS).
-- @return table Map of name → { version, txCount, lastScanTime, lastSeen }
function GBL:GetSyncPeers()
    local now = GetServerTime()
    local active = {}
    for name, info in pairs(syncState.peers) do
        if now - (info.lastSeen or 0) <= PEER_STALE_SECONDS then
            active[name] = info
        end
    end
    return active
end

--- Return all peers seen this session, including stale ones (for diagnostics).
-- @return table Map of name → { version, txCount, lastScanTime, lastSeen }
function GBL:GetAllPeers()
    return syncState.peers
end

--- Return the session audit trail.
-- @return table Array of { timestamp, message }, newest first
function GBL:GetAuditTrail()
    return syncState.auditTrail
end

--- Return total transaction count for the current guild.
-- @return number Combined item + money transaction count
function GBL:GetTxCount()
    local guildData = self:GetGuildData()
    if not guildData then return 0 end
    return #guildData.transactions + #guildData.moneyTransactions
end

--- Check if sync is enabled in profile settings.
-- @return boolean
function GBL:IsSyncEnabled()
    return self.db.profile.sync.enabled
end

--- Check if a sync transfer is currently in progress.
-- @return boolean
function GBL:IsSyncing()
    return syncState.sending or syncState.receiving
end

--- Reset session sync state. Exposed for testing.
function GBL:ResetSyncState()
    syncState.sending = false
    syncState.sendTarget = nil
    syncState.sendChunks = {}
    syncState.sendChunkIndex = 0
    syncState.sendTimer = nil
    syncState.sendHardTimer = nil
    syncState.sendRetryCount = 0
    syncState.sendStartTime = 0
    syncState.sendTotalRecords = 0
    syncState.receiving = false
    syncState.receiveSource = nil
    syncState.receiveExpected = 0
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveDuped = 0
    syncState.receiveTimer = nil
    syncState.receiveStartTime = 0
    syncState.receiveNackCount = 0
    syncState.peers = {}
    syncState.auditTrail = {}
    syncState.lastHelloTime = 0
    if syncState.helloHeartbeat then
        syncState.helloHeartbeat:Cancel()
        syncState.helloHeartbeat = nil
    end
    syncState.zonePaused = false
    syncState.zoneCooldownTimer = nil
    syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL
    syncState.fpsFrame = nil
    syncState.lastFpsCheck = 0
end

------------------------------------------------------------------------
-- NACK retry
------------------------------------------------------------------------

--- Send a NACK to request re-transmission of a specific chunk.
-- @param target string Peer to request from
-- @param chunkIndex number The chunk number to request
function GBL:SendNack(target, chunkIndex)
    syncState.receiveNackCount = syncState.receiveNackCount + 1
    local msg = self:Serialize({
        type = "NACK",
        chunk = chunkIndex,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    msg = compressMessage(msg)
    self:SendCommMessage(PREFIX, msg, "WHISPER", target)
    self:SyncLog("Sync: requesting re-send of chunk " .. chunkIndex
        .. " from " .. target .. " (attempt " .. syncState.receiveNackCount
        .. "/" .. MAX_NACK_RETRIES .. ")")
    self:AddAuditEntry("Sent NACK for chunk " .. chunkIndex
        .. " to " .. target .. " (attempt " .. syncState.receiveNackCount .. ")")
end

--- Handle an incoming NACK — re-transmit the requested chunk.
-- @param sender string Sender name
-- @param data table Deserialized NACK payload
function GBL:HandleNack(sender, data)
    if not syncState.sending or self:StripRealm(sender) ~= self:StripRealm(syncState.sendTarget) then
        return
    end

    local requestedChunk = data and data.chunk
    if not requestedChunk or requestedChunk < 1
        or requestedChunk > #syncState.sendChunks then
        return
    end

    -- Cancel any pending ACK timer (the NACK replaces it)
    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end

    self:AddAuditEntry("NACK from " .. sender .. " for chunk " .. requestedChunk
        .. " — re-transmitting")

    -- Rewind to the requested chunk and re-send after a brief delay
    syncState.sendChunkIndex = requestedChunk - 1
    C_Timer.After(0.5, function()
        self:SendNextChunk()
    end)
end

------------------------------------------------------------------------
-- Zone change protection
------------------------------------------------------------------------

--- Pause sync when a loading screen begins.
-- Cancels all active timers to prevent false timeouts during loading.
function GBL:OnLoadingScreenStart()
    if not syncState.sending and not syncState.receiving then return end
    syncState.zonePaused = true
    self:AddAuditEntry("Loading screen detected — sync paused")

    -- Cancel pending cooldown from a prior zone change (double zone change)
    if syncState.zoneCooldownTimer then
        syncState.zoneCooldownTimer:Cancel()
        syncState.zoneCooldownTimer = nil
    end

    -- Cancel active timers to prevent false timeouts during loading
    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
        syncState.sendHardTimer = nil
    end
    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
        syncState.receiveTimer = nil
    end
end

--- Resume sync after loading screen ends, with a brief cooldown.
function GBL:OnLoadingScreenEnd()
    if not syncState.zonePaused then return end

    -- Cancel any pending cooldown timer (safety)
    if syncState.zoneCooldownTimer then
        syncState.zoneCooldownTimer:Cancel()
    end

    syncState.zoneCooldownTimer = C_Timer.NewTicker(ZONE_COOLDOWN, function()
        syncState.zonePaused = false
        syncState.zoneCooldownTimer = nil
        self:AddAuditEntry("Zone cooldown complete — sync resumed")

        -- Resume sending if we were the sender
        if syncState.sending then
            self:SendNextChunk()
        end

        -- Restart receive timeout if we were receiving
        if syncState.receiving then
            syncState.receiveTimer = C_Timer.NewTicker(RECEIVE_CHUNK_TIMEOUT, function()
                if not syncState.receiving then return end
                if syncState.receiveNackCount >= MAX_NACK_RETRIES then
                    self:FinishReceiving(syncState.receiveSource)
                else
                    self:SendNack(syncState.receiveSource, syncState.receiveGot + 1)
                end
            end, 1)
        end
    end, 1)
end

------------------------------------------------------------------------
-- FPS-adaptive throttling
------------------------------------------------------------------------

--- Return the current adaptive inter-chunk delay.
-- @return number Delay in seconds
function GBL:GetSyncDelay()
    return syncState.currentDelay or INTER_CHUNK_DELAY_NORMAL
end

--- Start monitoring FPS to adapt sync speed.
-- Creates an OnUpdate frame that samples FPS periodically.
function GBL:StartFpsMonitor()
    if syncState.fpsFrame then return end

    syncState.fpsFrame = CreateFrame("Frame")
    syncState.lastFpsCheck = GetTime()
    syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL

    local self_ref = self
    syncState.fpsFrame:SetScript("OnUpdate", function(_, _elapsed)
        local now = GetTime()
        if now - syncState.lastFpsCheck < FPS_SAMPLE_INTERVAL then return end
        syncState.lastFpsCheck = now

        local fps = GetFramerate()
        if fps < FPS_THRESHOLD_LOW and syncState.currentDelay < INTER_CHUNK_DELAY_SLOW then
            syncState.currentDelay = INTER_CHUNK_DELAY_SLOW
            self_ref:AddAuditEntry("FPS low (" .. math.floor(fps)
                .. ") — sync delay increased to " .. INTER_CHUNK_DELAY_SLOW .. "s")
        elseif fps > FPS_THRESHOLD_RECOVER and syncState.currentDelay > INTER_CHUNK_DELAY_NORMAL then
            syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL
            self_ref:AddAuditEntry("FPS recovered (" .. math.floor(fps)
                .. ") — sync delay restored to " .. INTER_CHUNK_DELAY_NORMAL .. "s")
        end
    end)
end

--- Stop FPS monitoring and reset delay to normal.
function GBL:StopFpsMonitor()
    if syncState.fpsFrame then
        syncState.fpsFrame:SetScript("OnUpdate", nil)
        syncState.fpsFrame:Hide()
        syncState.fpsFrame = nil
    end
    syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL
end

------------------------------------------------------------------------
-- ChatThrottleLib awareness
------------------------------------------------------------------------

--- Check if enough bandwidth is available for sending a sync chunk.
-- Reads ChatThrottleLib.avail (a local table field — zero network cost).
-- @return boolean true if bandwidth is available or CTL is absent
function GBL:HasSyncBandwidth()
    local CTL = _G.ChatThrottleLib
    if not CTL then return true end
    if CTL.avail and CTL.avail < CTL_BANDWIDTH_MIN then
        return false
    end
    return true
end
