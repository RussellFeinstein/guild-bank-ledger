------------------------------------------------------------------------
-- GuildBankLedger — Sync.lua
-- Guild-wide transaction sync via AceComm
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Protocol constants
local PREFIX = "GBLSync"
local PROTOCOL_VERSION = 4
-- Chunk size tuning (v0.28.7 — true 1-fragment target)
-- Compressed payload targets ≤255 bytes so each chunk is 1 AceComm wire
-- fragment. v0.28.6 aimed for 2 fragments but actual compression ratio is
-- 23–26% of raw (not ~18% as predicted), so a 2500-byte raw budget landed at
-- ~660 bytes compressed = 3 fragments, giving ~45% per-attempt chunk loss.
-- At 900-byte raw budget with 26% worst-case compression, compressed stays
-- ≤240 bytes = 1 fragment. Per-attempt loss equals per-fragment loss
-- (~18% observed), giving ~0.003% 6-retry failure per chunk. Sync of
-- ~3300 records ≈ 18 minutes at the 1.0s gap floor; subsequent syncs are
-- much shorter after the bucket-delta filter converges.
local MAX_RECORDS_PER_CHUNK = 4
local CHUNK_BYTE_BUDGET = 900
local MAX_RETRIES = 5
local ACK_TIMEOUT = 8
local RECEIVE_CHUNK_TIMEOUT = 20
local MAX_NACK_RETRIES = 3
local HELLO_COOLDOWN = 60
local WHISPER_SAFE_BYTES = 2000
local ZONE_COOLDOWN = 5
local COMBAT_COOLDOWN = 2
local INTER_CHUNK_DELAY_NORMAL = 0.1
local INTER_CHUNK_DELAY_SLOW = 0.5
local FPS_THRESHOLD_LOW = 20
local FPS_THRESHOLD_RECOVER = 25
local FPS_SAMPLE_INTERVAL = 1.0
local CTL_BANDWIDTH_MIN = 400
local CTL_BACKOFF_DELAY = 1.0
local INTER_CHUNK_GAP_FLOOR = 1.0     -- v0.28.5: min seconds between chunk issues
                                       -- (server-side per-recipient whisper throttle)
local PEER_STALE_SECONDS = 300
local HELLO_HEARTBEAT_INTERVAL = 120
local EVENTCOUNTS_PER_BATCH = 10
local MAX_PENDING_PEERS = 10
local KNOWN_PEER_EXPIRE_SECONDS = 30 * 24 * 3600  -- 30 days
local INITIAL_CHUNK_TIMEOUT = 10
local BUSY_COOLDOWN = 30
local PEER_STARVATION_SECONDS = 60
local FORCED_HELLO_COOLDOWN = 10
local MANIFEST_INTERVAL = 300  -- 5 minutes
local MANIFEST_MAX_BUCKETS = 200
local WHISPER_TRACK_EXPIRE = 30
local MAX_RECEIVE_DURATION = 1800  -- 30 minutes absolute maximum receive time

-- Expose constants for testing and UI
GBL.SYNC_PROTOCOL_VERSION = PROTOCOL_VERSION
GBL.SYNC_CHUNK_SIZE = MAX_RECORDS_PER_CHUNK
GBL.SYNC_PREFIX = PREFIX
GBL.SYNC_MAX_RETRIES = MAX_RETRIES
GBL.SYNC_MAX_NACK_RETRIES = MAX_NACK_RETRIES
GBL.SYNC_PEER_STALE_SECONDS = PEER_STALE_SECONDS
GBL.SYNC_HELLO_HEARTBEAT_INTERVAL = HELLO_HEARTBEAT_INTERVAL
GBL.SYNC_EVENTCOUNTS_PER_BATCH = EVENTCOUNTS_PER_BATCH
GBL.SYNC_MAX_PENDING_PEERS = MAX_PENDING_PEERS
GBL.SYNC_KNOWN_PEER_EXPIRE_SECONDS = KNOWN_PEER_EXPIRE_SECONDS
GBL.SYNC_INITIAL_CHUNK_TIMEOUT = INITIAL_CHUNK_TIMEOUT
GBL.SYNC_BUSY_COOLDOWN = BUSY_COOLDOWN
GBL.SYNC_PEER_STARVATION_SECONDS = PEER_STARVATION_SECONDS
GBL.SYNC_MAX_RECEIVE_DURATION = MAX_RECEIVE_DURATION
GBL.SYNC_FORCED_HELLO_COOLDOWN = FORCED_HELLO_COOLDOWN
GBL.SYNC_MANIFEST_INTERVAL = MANIFEST_INTERVAL
GBL.SYNC_MANIFEST_MAX_BUCKETS = MANIFEST_MAX_BUCKETS
GBL.SYNC_COMBAT_COOLDOWN = COMBAT_COOLDOWN
GBL.SYNC_INTER_CHUNK_GAP_FLOOR = INTER_CHUNK_GAP_FLOOR

-- Diagnostic: CTL deferral tracking (module-level, survives state resets)
local ctlDeferTotal = 0  -- monotonic count per sync session

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

--- Calculate NACK timeout with progressive backoff.
-- 20s * 1.5^nackCount, capped at 45s.
-- @param nackCount number Number of NACKs already sent (0-based)
-- @return number Timeout in seconds
local function nackBackoff(nackCount)
    local delay = RECEIVE_CHUNK_TIMEOUT * (1.5 ^ nackCount)
    return math.min(delay, 45)
end

-- Expose for testing
GBL._compressMessage = compressMessage
GBL._decompressMessage = decompressMessage
GBL._nackBackoff = nackBackoff

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
    sendChunkSentAt = 0,

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

    -- Combat protection
    combatPaused = false,
    combatCooldownTimer = nil,

    -- FPS-adaptive throttling
    currentDelay = INTER_CHUNK_DELAY_NORMAL,
    fpsFrame = nil,
    lastFpsCheck = 0,

    -- Pending peers queue (retry after busy/combat/zone)
    pendingPeers = {},
    pendingPeersCount = 0,

    -- HELLO traffic management (M4)
    lastForcedHelloTime = 0,
    lastHelloReplyHash = {},  -- name → hash we last communicated to this peer

    -- GUILD manifest broadcast (M5)
    peerManifests = {},        -- name → { buckets={}, txCount, dataHash, receivedAt }
    lastManifestHash = 0,
    lastManifestTime = 0,
    manifestTimer = nil,

    -- Diagnostic counters (per-sync session)
    helloRepliesDuringSync = 0,
    nacksReceivedDuringSync = 0,

    -- CTL pacing: last known chunk compressed size (for dynamic threshold)
    lastChunkBytes = 0,

    -- Per-chunk instrumentation (v0.28.4)
    lastSendIssuedAt = 0,         -- GetTime() when the previous SendNextChunk issued a send
    sendChunkTransmittedAt = 0,   -- GetTime() when the AceComm callback fired sent==totalBytes
    nacksForCurrentChunk = 0,     -- NACKs received while retrying the current chunk
    chunkOutcomes = {},           -- [chunk] = { attempts, wireToAck, outcome }
}

--- Check if sync is paused due to zone change or combat.
-- @return boolean true if either pause flag is active
local function isSyncPaused()
    return syncState.zonePaused or syncState.combatPaused
end

-- Track names we're actively whispering via sync, so the system message
-- filter can distinguish addon-caused errors from user-caused errors.
local recentWhisperTargets = {}  -- stripped_name → GetServerTime()

-- Expose for testing
GBL._recentWhisperTargets = recentWhisperTargets

------------------------------------------------------------------------
-- Safe whisper wrapper
------------------------------------------------------------------------

--- Expire old entries from the whisper tracking set.
-- Entries older than WHISPER_TRACK_EXPIRE seconds are removed.
local function cleanWhisperTargets()
    local now = GetServerTime()
    for name, ts in pairs(recentWhisperTargets) do
        if now - ts > WHISPER_TRACK_EXPIRE then
            recentWhisperTargets[name] = nil
        end
    end
end

--- Send a sync whisper to target, with online pre-check and tracking.
-- Returns false if the target is confirmed offline (whisper not sent).
-- @param prefix string AceComm prefix
-- @param msg string Compressed message
-- @param target string Target player name
-- @param prio string|nil Priority ("NORMAL", "ALERT", etc.)
-- @param callbackFn function|nil AceComm progress callback
-- @param callbackArg any|nil Callback argument
-- @return boolean true if whisper was sent, false if target offline
function GBL:SendSyncWhisper(prefix, msg, target, prio, callbackFn, callbackArg)
    local online = self:IsGuildMemberOnline(target)
    if online == false then
        self:AddAuditEntry("Blocked whisper to offline player: " .. target)
        return false
    end
    recentWhisperTargets[self:StripRealm(target)] = GetServerTime()
    self:SendCommMessage(prefix, msg, "WHISPER", target, prio, callbackFn, callbackArg)
    return true
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
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
    -- Suppress "No player named 'X' is currently playing." errors caused by
    -- sync whispers to players who went offline (roster lag race condition).
    -- Only suppresses errors for players the addon recently whispered.
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_chatFrame, _event, msg)
            if not msg then return false end
            local pattern = ERR_CHAT_PLAYER_NOT_FOUND_S
                and ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("%%s", "(.+)")
            if not pattern then return false end
            local playerName = msg:match(pattern)
            if not playerName then return false end

            cleanWhisperTargets()
            local bare = GBL:StripRealm(playerName)
            if not recentWhisperTargets[bare] then return false end
            -- DO NOT remove tracking entry — AceComm CTL splits one message
            -- into multiple whispers, each generating a separate error. Keep
            -- suppressing for the full WHISPER_TRACK_EXPIRE window.

            -- Abort sending if stuck (callback never fires on failed whisper →
            -- sendHardTimer is the only safety net at 120s, which is too long)
            if syncState.sending and syncState.sendTarget
                and GBL:StripRealm(syncState.sendTarget) == bare then
                GBL:AddAuditEntry("Target " .. syncState.sendTarget
                    .. " confirmed offline (system error) — aborting send")
                GBL:FinishSending()
            end
            return true  -- suppress the system message
        end)
    end
    -- Seed session peers from persisted knownPeers (cross-session discovery).
    -- Seeded peers keep their original lastSeen (stale), so they won't be
    -- targeted for sync. The roster fallback in GetSyncPeers shows them
    -- as "online (no HELLO)" if the guild roster confirms they're online.
    local guildData = self:GetGuildData()
    if guildData and guildData.knownPeers then
        local now = GetServerTime()
        for name, info in pairs(guildData.knownPeers) do
            if now - (info.lastSeen or 0) < KNOWN_PEER_EXPIRE_SECONDS then
                syncState.peers[name] = {
                    version = info.version,
                    txCount = info.txCount or 0,
                    lastSeen = info.lastSeen or 0,
                }
            else
                guildData.knownPeers[name] = nil
            end
        end
    end
    self:StartHelloHeartbeat()
    -- Start manifest broadcast heartbeat
    if not syncState.manifestTimer then
        syncState.manifestTimer = C_Timer.NewTicker(MANIFEST_INTERVAL, function()
            self:BroadcastManifest()
        end)
    end
end

--- Enable sync at runtime (from UI toggle).
function GBL:EnableSync()
    self.db.profile.sync.enabled = true
    self:RegisterComm(PREFIX, "OnSyncMessage")
    self:RegisterEvent("LOADING_SCREEN_ENABLED", "OnLoadingScreenStart")
    self:RegisterEvent("LOADING_SCREEN_DISABLED", "OnLoadingScreenEnd")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
    self:StartHelloHeartbeat()
    self:BroadcastHello()
    -- Start manifest broadcast heartbeat
    if not syncState.manifestTimer then
        syncState.manifestTimer = C_Timer.NewTicker(MANIFEST_INTERVAL, function()
            self:BroadcastManifest()
        end)
    end
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
    syncState.combatPaused = false
    if syncState.combatCooldownTimer then
        syncState.combatCooldownTimer:Cancel()
        syncState.combatCooldownTimer = nil
    end
    if syncState.helloHeartbeat then
        syncState.helloHeartbeat:Cancel()
        syncState.helloHeartbeat = nil
    end
    self:StopFpsMonitor()
    syncState.pendingPeers = {}
    syncState.pendingPeersCount = 0
    syncState.lastForcedHelloTime = 0
    syncState.lastHelloReplyHash = {}
    syncState.peerManifests = {}
    syncState.lastManifestHash = 0
    syncState.lastManifestTime = 0
    if syncState.manifestTimer then
        syncState.manifestTimer:Cancel()
        syncState.manifestTimer = nil
    end
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

    -- During sync: suppress heartbeat broadcasts, but send a keepalive
    -- every ~280s to prevent peer staleness (PEER_STALE_SECONDS = 300).
    -- Forced HELLOs (post-sync, epidemic) bypass this guard.
    if not force and (syncState.sending or syncState.receiving) then
        if now - syncState.lastHelloTime < (PEER_STALE_SECONDS - 20) then return end
        -- Fall through to send keepalive HELLO
    end

    -- Rate-limit forced HELLOs to prevent storms during epidemic propagation
    if force then
        if now - syncState.lastForcedHelloTime < FORCED_HELLO_COOLDOWN then return end
        syncState.lastForcedHelloTime = now
    end

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
        accessControl = guildData.accessControl,
    })
    msg = compressMessage(msg)

    self:SendCommMessage(PREFIX, msg, "GUILD")
    self:AddAuditEntry("Sent HELLO (tx: " .. txCount
        .. ", hash: " .. dataHash .. ")")

    -- Broadcast-mark: all peers receive this GUILD broadcast, so mark them
    -- as knowing our current hash. Suppresses redundant WHISPER replies.
    for name in pairs(syncState.lastHelloReplyHash) do
        syncState.lastHelloReplyHash[name] = dataHash
    end
end

------------------------------------------------------------------------
-- GUILD manifest broadcast
------------------------------------------------------------------------

--- Broadcast a compact bucket hash manifest on GUILD so all peers
-- learn our bucket-level state without N² WHISPER exchanges.
-- Only broadcasts if our data has changed since the last manifest.
function GBL:BroadcastManifest()
    if not self.db.profile.sync.enabled then return end

    -- Suppress manifests during active sync to preserve CTL bandwidth
    if syncState.sending or syncState.receiving then return end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local dataHash = self:GetDataHash(guildData)
    if dataHash == syncState.lastManifestHash then return end

    local buckets = self:ComputeBucketHashes(guildData)

    -- Truncate to most recent MANIFEST_MAX_BUCKETS if exceeded
    local bucketCount = 0
    for _ in pairs(buckets) do bucketCount = bucketCount + 1 end
    if bucketCount > MANIFEST_MAX_BUCKETS then
        -- Keep the highest keys (most recent)
        local keys = {}
        for k in pairs(buckets) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys - MANIFEST_MAX_BUCKETS do
            buckets[keys[i]] = nil
        end
    end

    local txCount = #guildData.transactions + #guildData.moneyTransactions
    local msg = self:Serialize({
        type = "MANIFEST",
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        dataHash = dataHash,
        txCount = txCount,
        buckets = buckets,
    })
    msg = compressMessage(msg)

    self:SendCommMessage(PREFIX, msg, "GUILD")
    syncState.lastManifestHash = dataHash
    syncState.lastManifestTime = GetServerTime()
    self:AddAuditEntry("Sent MANIFEST (" .. bucketCount .. " buckets, hash: " .. dataHash .. ")")
end

--- Handle an incoming MANIFEST from another guild member.
-- Caches the peer's bucket hashes for smart peer selection.
-- @param sender string Sender name
-- @param data table Deserialized MANIFEST payload
function GBL:HandleManifest(sender, data)
    if not data.buckets then return end

    local clean = Ambiguate(sender, "none")
    syncState.peerManifests[clean] = {
        buckets = data.buckets,
        txCount = data.txCount or 0,
        dataHash = data.dataHash or 0,
        receivedAt = GetServerTime(),
    }

    -- Also update peer info (like a lightweight HELLO)
    if syncState.peers[clean] then
        syncState.peers[clean].txCount = data.txCount or syncState.peers[clean].txCount
        syncState.peers[clean].dataHash = data.dataHash or syncState.peers[clean].dataHash
        syncState.peers[clean].lastSeen = GetServerTime()
    end

    self:AddAuditEntry("Received MANIFEST from " .. clean
        .. " (hash: " .. tostring(data.dataHash) .. ", tx: " .. (data.txCount or 0) .. ")")
end

------------------------------------------------------------------------
-- HELLO reply
------------------------------------------------------------------------

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
        accessControl = guildData.accessControl,
    })
    msg = compressMessage(msg)

    if not self:SendSyncWhisper(PREFIX, msg, target) then return end
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
            local peerVer = data.version or "?"
            local relation = "peer_behind"
            if peerVer ~= "?" and self:CompareSemver(self.version, peerVer) < 0 then
                relation = "local_behind"
            end
            syncState.peers[cleanSender] = {
                version = peerVer,
                txCount = data.txCount or 0,
                dataHash = data.dataHash,
                lastScanTime = data.lastScanTime or 0,
                lastSeen = GetServerTime(),
                outdated = true,
                versionRelation = relation,
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
    elseif msgType == "BUSY" then
        self:HandleBusy(sender, data)
    elseif msgType == "MANIFEST" then
        self:HandleManifest(sender, data)
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

    -- Accept access control settings if the remote copy is newer
    if data.accessControl and type(data.accessControl) == "table"
        and (data.accessControl.configuredAt or 0) > 0 then
        local gd = self:GetGuildData()
        if gd then
            local localAC = gd.accessControl or {}
            local localTS = localAC.configuredAt or 0
            local remoteTS = data.accessControl.configuredAt or 0
            if remoteTS > localTS then
                gd.accessControl = {
                    rankThreshold = data.accessControl.rankThreshold,
                    restrictedMode = data.accessControl.restrictedMode,
                    configuredBy = data.accessControl.configuredBy,
                    configuredAt = remoteTS,
                }
                self:AddAuditEntry("Updated access control from "
                    .. tostring(data.accessControl.configuredBy)
                    .. " (threshold=" .. tostring(data.accessControl.rankThreshold)
                    .. ", mode=" .. tostring(data.accessControl.restrictedMode) .. ")")
                self:SendMessage("GBL_ACCESS_CONTROL_CHANGED")
            end
        end
    end

    -- Reply to broadcast HELLOs so the sender discovers us.
    -- Hash-gated: only reply when our data changed since we last told this peer,
    -- or on first contact. Suppresses O(N²) reply traffic in large guilds.
    if not data.isReply then
        local cleanSenderReply = Ambiguate(sender, "none")
        local gd = self:GetGuildData()
        local currentHash = gd and self:GetDataHash(gd) or 0
        local lastHash = syncState.lastHelloReplyHash[cleanSenderReply]
        if lastHash == nil or currentHash ~= lastHash then
            if syncState.sending or syncState.receiving then
                syncState.helloRepliesDuringSync =
                    (syncState.helloRepliesDuringSync or 0) + 1
                self:AddAuditEntry("Suppressed HELLO reply to "
                    .. cleanSenderReply .. " [sync active]")
            else
                self:SendHelloReply(sender)
            end
            syncState.lastHelloReplyHash[cleanSenderReply] = currentHash
        end
    end

    -- Exact version match — refuse sync on any version difference
    if data.version and data.version ~= self.version then
        local cleanSender = Ambiguate(sender, "none")
        if syncState.peers[cleanSender] then
            syncState.peers[cleanSender].outdated = true
            local cmp = self:CompareSemver(self.version, data.version)
            syncState.peers[cleanSender].versionRelation =
                (cmp < 0) and "local_behind" or "peer_behind"
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
        if localCount > remoteCount then
            -- We have strictly more records — likely a superset.
            -- Peer will request from us; bidirectional check handles edge cases.
            self:AddAuditEntry("Skipped request from " .. sender
                .. " — likely superset (local=" .. localCount
                .. " > remote=" .. remoteCount .. ")")
            return
        end
        -- Hashes differ and peer has equal or more records — request sync
        shouldSync = true
        syncReason = "hash mismatch"
    elseif not data.dataHash and remoteCount > localCount then
        -- No hash support (old version) — fall back to count comparison
        shouldSync = true
        syncReason = "count (no hash, remote has more)"
    end

    if shouldSync and not syncState.receiving and self.db.profile.sync.autoSync then
        -- Defer sync if in combat to avoid FPS impact
        if InCombatLockdown and InCombatLockdown() then
            self:AddPendingPeer(sender)
            self:AddAuditEntry("Deferred sync from " .. sender .. " — in combat")
        else
            -- Add 0-2s random jitter to prevent mutual SYNC_REQUEST oscillation
            -- when multiple peers respond to the same HELLO simultaneously
            self:AddAuditEntry("Sync triggered by " .. syncReason
                .. " — requesting from " .. sender .. " (with jitter)")
            local jitter = math.random() * 1
            C_Timer.After(jitter, function()
                if syncState.receiving then
                    -- Already receiving — queue instead
                    self:AddPendingPeer(sender)
                    return
                end
                if not self.db.profile.sync.enabled then return end
                local gd = self:GetGuildData()
                if not gd then return end
                local sinceTs = gd.syncState.lastSyncTimestamp or 0
                self:RequestSync(sender, sinceTs)
            end)
        end
    else
        -- Log why we didn't sync so stalls are diagnosable
        local reason
        if not shouldSync then
            reason = "datasets match or no sync needed (local=" .. localCount
                .. ", remote=" .. remoteCount .. ")"
        elseif syncState.receiving then
            reason = "already receiving from " .. (syncState.receiveSource or "?")
            -- Queue for retry after current sync completes
            self:AddPendingPeer(sender)
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
    -- Guard against epoch-0 from ID recovery (timeSlot 0 * 3600 = 0)
    if not GBL:IsValidTimestamp(record.timestamp) then
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
    syncState.receiveItemStored = 0
    syncState.receiveItemDuped = 0
    syncState.receiveMoneyStored = 0
    syncState.receiveMoneyDuped = 0
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
    if not self:SendSyncWhisper(PREFIX, msg, target) then
        self:AddAuditEntry("Target offline — aborting sync request to " .. target)
        self:FinishReceiving(target)
        return
    end
    self:AddAuditEntry("Requesting sync from " .. target
        .. " (since " .. sinceTimestamp
        .. ", " .. bucketCount .. " bucket days"
        .. ", " .. msgBytes .. " bytes)")
    self:SendMessage("GBL_SYNC_STARTED", target)

    -- Request timeout — NACK with backoff, then abort after MAX_NACK_RETRIES
    syncState.receiveNackCount = 0
    self:ScheduleReceiveTimeout()
end

--- Handle an incoming SYNC_REQUEST — gather and send matching transactions.
-- @param sender string Requester name
-- @param data table Deserialized request payload
function GBL:HandleSyncRequest(sender, data)
    if syncState.sending then
        self:AddAuditEntry("Declined sync from " .. sender
            .. " (already sending to " .. (syncState.sendTarget or "?") .. ")")
        -- Send BUSY so requester doesn't wait 60s for data that will never come
        local msg = self:Serialize({
            type = "BUSY",
            protocolVersion = PROTOCOL_VERSION,
            guild = self:GetGuildName(),
        })
        msg = compressMessage(msg)
        self:SendSyncWhisper(PREFIX, msg, sender)
        self:AddAuditEntry("Sent BUSY to " .. sender)
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local txToSend = {}
    local moneyToSend = {}
    local diffDays  -- bucket keys that differ (nil = send all)

    if data.bucketHashes then
        -- Bucket-filtered sync: only send records from days where hashes differ
        local localBuckets = self:ComputeBucketHashes(guildData)
        diffDays = {}
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

    -- Collect eventCounts for the buckets we're sending (nil diffDays = send all)
    local sendEventCounts = self:CollectEventCountsForBuckets(guildData, diffDays)

    -- Partition eventCounts into batches to spread across chunks
    local batches = self:PartitionEventCounts(sendEventCounts)

    -- Extend chunks array if more batches than record chunks
    while #batches > #chunks do
        chunks[#chunks + 1] = { transactions = {}, moneyTransactions = {} }
    end

    if #chunks == 0 then
        -- Nothing to send — send an empty chunk so receiver finishes cleanly
        local msg = self:Serialize({
            type = "SYNC_DATA",
            chunk = 1,
            totalChunks = 1,
            transactions = {},
            moneyTransactions = {},
            eventCounts = batches[1],
            protocolVersion = PROTOCOL_VERSION,
            guild = self:GetGuildName(),
        })
        msg = compressMessage(msg)
        self:SendSyncWhisper(PREFIX, msg, sender)
        self:AddAuditEntry("Sent empty sync to " .. sender)
        return
    end

    syncState.sending = true
    syncState.sendTarget = sender
    syncState.sendChunks = chunks
    syncState.sendChunkIndex = 0
    syncState.sendStartTime = GetServerTime()
    syncState.sendTotalRecords = #txToSend + #moneyToSend
    syncState.sendEventCountBatches = batches
    self:StartFpsMonitor()

    local totalTx = #txToSend + #moneyToSend
    self:AddAuditEntry("Sending " .. totalTx
        .. " tx to " .. sender .. " in " .. #chunks .. " chunk(s)")

    ctlDeferTotal = 0
    syncState.helloRepliesDuringSync = 0
    syncState.nacksReceivedDuringSync = 0
    syncState.lastSendIssuedAt = 0
    syncState.sendChunkTransmittedAt = 0
    syncState.nacksForCurrentChunk = 0
    syncState.chunkOutcomes = {}
    self:SendNextChunk()
end

------------------------------------------------------------------------
-- Chunking
------------------------------------------------------------------------

--- Partition an eventCounts table into fixed-size batches for spread across chunks.
-- Each batch contains at most batchSize entries.
-- @param eventCounts table { [baseHash] = { count=N, asOf=T } }
-- @param batchSize number max entries per batch
-- @return table array of sub-tables, each a slice of the eventCounts map
function GBL:PartitionEventCounts(eventCounts, batchSize)
    if not eventCounts then return {} end
    batchSize = batchSize or EVENTCOUNTS_PER_BATCH

    local batches = {}
    local current = {}
    local count = 0

    for baseHash, entry in pairs(eventCounts) do
        current[baseHash] = entry
        count = count + 1
        if count >= batchSize then
            batches[#batches + 1] = current
            current = {}
            count = 0
        end
    end

    -- Seal the last partial batch
    if count > 0 then
        batches[#batches + 1] = current
    end

    return batches
end

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

    -- Zone/combat protection — defer until safe
    if isSyncPaused() then
        self:AddAuditEntry("SendNextChunk deferred — zone/combat transition in progress")
        return
    end

    -- ChatThrottleLib awareness — defer if other addons are using bandwidth
    if not self:HasSyncBandwidth() then
        ctlDeferTotal = ctlDeferTotal + 1
        -- Rate limit: first 10 verbose, then every 20th
        if ctlDeferTotal <= 10 or ctlDeferTotal % 20 == 0 then
            local CTL = _G.ChatThrottleLib
            local availStr = CTL and CTL.avail and string.format("%.0f", CTL.avail) or "?"
            local threshold = math.max(CTL_BANDWIDTH_MIN, syncState.lastChunkBytes or 0)
            local suffix = ""
            if ctlDeferTotal > 10 then
                suffix = ", " .. ctlDeferTotal .. " total"
            end
            self:AddAuditEntry("CTL low (avail=" .. availStr
                .. ", need=" .. threshold
                .. ", #" .. ctlDeferTotal
                .. ", t=" .. string.format("%.3f", GetTime())
                .. suffix
                .. ") — deferring " .. CTL_BACKOFF_DELAY .. "s")
        end
        C_Timer.After(CTL_BACKOFF_DELAY, function()
            self:SendNextChunk()
        end)
        return
    end

    -- v0.28.5: inter-chunk gap floor. WoW's chat server applies a per-recipient
    -- addon-whisper throttle independent of CTL's client-side meter, and drops
    -- the 3rd+ rapid-succession message. Enforce a minimum gap between chunk
    -- issues. First chunk (lastSendIssuedAt == 0) is exempt via the > 0 guard.
    if syncState.lastSendIssuedAt and syncState.lastSendIssuedAt > 0 then
        local gap = GetTime() - syncState.lastSendIssuedAt
        if gap < INTER_CHUNK_GAP_FLOOR then
            C_Timer.After(INTER_CHUNK_GAP_FLOOR - gap, function()
                self:SendNextChunk()
            end)
            return
        end
    end

    syncState.sendChunkIndex = syncState.sendChunkIndex + 1
    local idx = syncState.sendChunkIndex
    local chunk = syncState.sendChunks[idx]

    if not chunk then
        syncState.sendChunkIndex = syncState.sendChunkIndex - 1
        self:FinishSending()
        return
    end

    -- v0.28.4: record send attempt and inter-chunk gap for H2 diagnostics
    local nowTime = GetTime()
    local interChunkGap = (syncState.lastSendIssuedAt and syncState.lastSendIssuedAt > 0)
        and (nowTime - syncState.lastSendIssuedAt) or nil
    syncState.lastSendIssuedAt = nowTime
    syncState.chunkOutcomes = syncState.chunkOutcomes or {}
    if not syncState.chunkOutcomes[idx] then
        syncState.chunkOutcomes[idx] = {
            attempts = 0,
            retryReasons = {},
            outcome = "pending",
            wireToAck = nil,
            bytes = 0,
            ratio = 0,
        }
    end
    syncState.chunkOutcomes[idx].attempts = syncState.chunkOutcomes[idx].attempts + 1

    local serialized = self:Serialize({
        type = "SYNC_DATA",
        chunk = idx,
        totalChunks = #syncState.sendChunks,
        transactions = chunk.transactions,
        moneyTransactions = chunk.moneyTransactions,
        eventCounts = syncState.sendEventCountBatches
            and syncState.sendEventCountBatches[idx] or nil,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    local msg = compressMessage(serialized)
    syncState.lastChunkBytes = #msg

    local rawLen = #serialized
    local msgLen = #msg
    -- v0.28.7: capture per-chunk compression for FinishSending summary
    if syncState.chunkOutcomes and syncState.chunkOutcomes[idx] then
        syncState.chunkOutcomes[idx].bytes = msgLen
        syncState.chunkOutcomes[idx].ratio = msgLen / math.max(rawLen, 1)
    end
    local chunkRecords = #chunk.transactions + #chunk.moneyTransactions
    local total = #syncState.sendChunks
    local ctlAvailAtSend = ""
    do
        local CTL = _G.ChatThrottleLib
        if CTL and CTL.avail then
            ctlAvailAtSend = ", CTL.avail=" .. string.format("%.0f", CTL.avail)
            -- v0.28.4: also capture priority-queue depths (ALERT/NORMAL/BULK)
            if CTL.Prio then
                local qA = (CTL.Prio.ALERT and CTL.Prio.ALERT.nSize) or 0
                local qN = (CTL.Prio.NORMAL and CTL.Prio.NORMAL.nSize) or 0
                local qB = (CTL.Prio.BULK and CTL.Prio.BULK.nSize) or 0
                ctlAvailAtSend = ctlAvailAtSend .. ", CTLq=" .. qA .. "/" .. qN .. "/" .. qB
            end
        end
    end
    local gapStr = interChunkGap and string.format(", gap=%.2fs", interChunkGap) or ""
    local chunkMsg = "Sending chunk " .. idx .. "/" .. total
        .. " to " .. (syncState.sendTarget or "?")
        .. " (" .. chunkRecords .. " records, " .. rawLen .. "→" .. msgLen .. " bytes"
        .. ", " .. math.floor((1 - msgLen / math.max(rawLen, 1)) * 100) .. "% compressed"
        .. ctlAvailAtSend .. gapStr .. ")"
    -- Chat: every chunk; audit trail: 1st, every 10th, and last
    self:AddAuditEntry(chunkMsg, true)
    if idx == 1 or idx == total or idx % 10 == 0 then
        self:AddAuditEntry(chunkMsg)
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
            self:AddAuditEntry("Send hard timeout (120s) — AceComm never finished, aborting")
            self:FinishSending()
        end
    end, 1)

    -- Record send time for RTT measurement
    syncState.sendChunkSentAt = GetTime()

    -- ACK timer deferred until message fully transmitted via AceComm callback.
    -- AceComm calls callbackFn(callbackArg, bytesSent, totalLen) per CTL piece.
    if not self:SendSyncWhisper(PREFIX, msg, syncState.sendTarget, "NORMAL",
        function(_cbArg, sent, totalBytes)
            if sent < totalBytes then return end
            -- v0.28.4: record wire-completion time — anchor for wire-to-ACK latency
            syncState.sendChunkTransmittedAt = GetTime()
            -- Diagnostic: log transmit completion timing
            local queueDuration = string.format("%.2f",
                GetTime() - (syncState.sendChunkSentAt or GetTime()))
            local postAvail = _G.ChatThrottleLib and _G.ChatThrottleLib.avail
                and string.format("%.0f", _G.ChatThrottleLib.avail) or "?"
            self:AddAuditEntry("Chunk " .. idx .. " transmitted ("
                .. queueDuration .. "s queue-to-wire, CTL.avail=" .. postAvail .. ")")
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
                    -- v0.28.4: enriched diagnostic context (H1/H2/H3 discriminators)
                    local fragments = math.ceil((syncState.lastChunkBytes or 0) / 255)
                    local wireAnchor = syncState.sendChunkTransmittedAt or 0
                    local gapSinceWire = (wireAnchor > 0)
                        and string.format("%.2fs", GetTime() - wireAnchor) or "?"
                    local liveness = self:IsGuildMemberOnline(syncState.sendTarget)
                    local livenessStr = (liveness == true) and "online"
                        or (liveness == false) and "offline" or "unknown"
                    self:AddAuditEntry("ACK timeout — retrying chunk " .. retryChunk
                        .. " (attempt " .. (syncState.sendRetryCount + 1) .. "/"
                        .. (MAX_RETRIES + 1) .. ")"
                        .. ", fragments~=" .. fragments
                        .. ", gapSinceWire=" .. gapSinceWire
                        .. ", nacksThisChunk=" .. (syncState.nacksForCurrentChunk or 0)
                        .. ", target=" .. livenessStr)
                    -- v0.28.7: tag retry cause for FinishSending histogram
                    if syncState.chunkOutcomes and syncState.chunkOutcomes[retryChunk] then
                        table.insert(syncState.chunkOutcomes[retryChunk].retryReasons, "ackTimeout")
                    end
                    self:SendNextChunk()
                else
                    -- v0.28.4: record abort outcome for this chunk
                    if syncState.chunkOutcomes and syncState.chunkOutcomes[idx] then
                        syncState.chunkOutcomes[idx].outcome = "aborted"
                    end
                    self:AddAuditEntry("ACK timeout from "
                        .. (syncState.sendTarget or "unknown")
                        .. " after " .. (MAX_RETRIES + 1) .. " attempts — aborting")
                    self:FinishSending()
                end
            end, 1)
        end) then
        self:AddAuditEntry("Target " .. (syncState.sendTarget or "?")
            .. " went offline — aborting send")
        -- v0.28.7: tag outcome for histogram attribution
        if syncState.chunkOutcomes and syncState.chunkOutcomes[idx]
            and syncState.chunkOutcomes[idx].outcome == "pending" then
            syncState.chunkOutcomes[idx].outcome = "sendFailed"
        end
        self:FinishSending()
        return
    end
end

--- Clean up sending state after sync completes or aborts.
function GBL:FinishSending()
    local target = syncState.sendTarget or "?"
    local sent = syncState.sendChunkIndex
    local total = #syncState.sendChunks
    local elapsed = GetServerTime() - syncState.sendStartTime

    self:AddAuditEntry("Send complete to " .. target
        .. " — " .. sent .. "/" .. total .. " chunks"
        .. ", " .. syncState.sendTotalRecords .. " records, " .. elapsed .. "s")
    self:AddAuditEntry("Sync stats: " .. ctlDeferTotal .. " CTL deferrals"
        .. ", " .. (syncState.helloRepliesDuringSync or 0) .. " HELLO replies suppressed"
        .. ", " .. (syncState.nacksReceivedDuringSync or 0) .. " NACKs received")

    -- v0.28.7: per-peer outcomes + cause attribution + compression summary
    -- Replaces v0.28.4's single `Sync outcomes:` line. Splits aborted causes
    -- (ackTimeout/combat/zone/busy/offline) so a noisy test session can be
    -- distinguished from a genuine reliability issue. Back-solves per-fragment
    -- loss using observed avg fragments rather than `lastChunkBytes` so that
    -- A/B data across versions is comparable even when chunk size differs.
    local on1, on2, on3plus = 0, 0, 0
    local outcomes = { ok = 0, aborted = 0, combatAbort = 0,
                       zoneAbort = 0, busyAbort = 0, sendFailed = 0 }
    local causes = { ackTimeout = 0, nack = 0 }
    local chunksSeen, totalAttempts, wireLossRetries = 0, 0, 0
    local sumFrags = 0
    local ratios = {}

    for _, o in pairs(syncState.chunkOutcomes or {}) do
        chunksSeen = chunksSeen + 1
        local attempts = o.attempts or 0
        totalAttempts = totalAttempts + attempts

        if o.outcome == "ok" then
            if attempts <= 1 then on1 = on1 + 1
            elseif attempts == 2 then on2 = on2 + 1
            else on3plus = on3plus + 1 end
        end

        if outcomes[o.outcome] ~= nil then
            outcomes[o.outcome] = outcomes[o.outcome] + 1
        end

        for _, reason in ipairs(o.retryReasons or {}) do
            if causes[reason] ~= nil then
                causes[reason] = causes[reason] + 1
                wireLossRetries = wireLossRetries + 1
            end
        end

        if o.bytes and o.bytes > 0 then
            sumFrags = sumFrags + math.ceil(o.bytes / 255)
        end
        if o.ratio and o.ratio > 0 then
            table.insert(ratios, o.ratio)
        end
    end

    local chunkFail, pFragStr = "n/a", "n/a"
    if chunksSeen >= 3 and totalAttempts > 0 then
        local cf = wireLossRetries / totalAttempts
        if cf > 0.5 then cf = 0.5 end
        chunkFail = string.format("%.1f%%", cf * 100)
        local avgFrags = (chunksSeen > 0) and (sumFrags / chunksSeen) or 1
        if avgFrags < 1 then avgFrags = 1 end
        local pf = 1 - (1 - cf) ^ (1 / avgFrags)
        pFragStr = string.format("%.1f%% (n=%.1f frags/chunk)", pf * 100, avgFrags)
    end

    local ratioSummary = "n/a"
    if #ratios > 0 then
        table.sort(ratios)
        local minR, maxR = ratios[1], ratios[#ratios]
        local medR = ratios[math.floor(#ratios / 2) + 1]
        ratioSummary = string.format("%.0f%% / %.0f%% / %.0f%% (min/med/max)",
            minR * 100, medR * 100, maxR * 100)
    end

    self:AddAuditEntry("Sync outcomes for " .. target .. ": "
        .. on1 .. " on 1st, " .. on2 .. " on 2nd, " .. on3plus .. " on 3rd+, "
        .. "aborted: " .. outcomes.aborted .. " ackTimeout + "
        .. outcomes.combatAbort .. " combat + " .. outcomes.zoneAbort .. " zone + "
        .. outcomes.busyAbort .. " busy + " .. outcomes.sendFailed .. " offline")
    self:AddAuditEntry("Retry causes for " .. target .. ": "
        .. "ackTimeout=" .. causes.ackTimeout .. ", nack=" .. causes.nack
        .. " | chunkFail=" .. chunkFail .. ", p_frag=" .. pFragStr)
    self:AddAuditEntry("Compression for " .. target .. ": " .. ratioSummary)

    syncState.sending = false
    syncState.sendTarget = nil
    syncState.sendChunks = {}
    syncState.sendChunkIndex = 0
    syncState.sendRetryCount = 0
    syncState.sendStartTime = 0
    syncState.sendTotalRecords = 0
    syncState.sendChunkSentAt = 0
    syncState.sendEventCountBatches = nil
    syncState.lastChunkBytes = 0
    syncState.lastSendIssuedAt = 0
    syncState.sendChunkTransmittedAt = 0
    syncState.nacksForCurrentChunk = 0
    syncState.chunkOutcomes = {}
    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
        syncState.sendHardTimer = nil
    end
    self:StopFpsMonitor()

    -- Bidirectional check: after sending, do we need data from this peer?
    -- Brief delay to let the peer process our data (their FinishReceiving).
    local cleanTarget = Ambiguate(target, "none")
    if self.db.profile.sync.autoSync then
        C_Timer.After(0.5, function()
            if syncState.receiving then return end
            if isSyncPaused() then return end
            if not self.db.profile.sync.enabled then return end
            if InCombatLockdown and InCombatLockdown() then return end

            local peerInfo = syncState.peers[cleanTarget]
            if not peerInfo or not peerInfo.dataHash then
                -- No hash info — process pending queue instead
                self:ProcessPendingPeers()
                return
            end

            local gd = self:GetGuildData()
            if not gd then return end
            local localHash = self:GetDataHash(gd)
            local localCount = #gd.transactions + #gd.moneyTransactions

            local remoteTxCount = peerInfo.txCount or 0
            if peerInfo.dataHash ~= localHash
                or remoteTxCount ~= localCount then
                if localCount > remoteTxCount then
                    self:AddAuditEntry("Bidirectional check: skipped — likely superset (local="
                        .. localCount .. " > remote=" .. remoteTxCount .. ")")
                    self:ProcessPendingPeers()
                else
                    self:AddAuditEntry("Bidirectional check: hashes still differ with "
                        .. cleanTarget .. " — requesting sync")
                    local since = gd.syncState.lastSyncTimestamp or 0
                    self:RequestSync(cleanTarget, since)
                end
            else
                self:AddAuditEntry("Bidirectional check: hashes match with "
                    .. cleanTarget .. " — no sync needed")
                self:ProcessPendingPeers()
            end
        end)
    else
        -- autoSync disabled — still process pending queue
        C_Timer.After(0.2, function()
            if syncState.receiving then return end
            self:ProcessPendingPeers()
        end)
    end
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
    local newTs = GBL:SafeRecordTimestamp(incomingRecord)

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
        if data.chunk and data.chunk > 1 then
            self:AddAuditEntry("Auto-bootstrap at chunk " .. data.chunk
                .. " from " .. sender
                .. " (prior abort signal likely missed)")
        end
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

    -- Merge remote eventCounts (max wins, backwards-compat with old peers)
    if data.eventCounts then
        if not guildData.eventCounts then guildData.eventCounts = {} end
        for baseHash, remote in pairs(data.eventCounts) do
            if type(remote) == "table" and type(remote.count) == "number" then
                local localEntry = guildData.eventCounts[baseHash]
                if not localEntry or remote.count > localEntry.count then
                    guildData.eventCounts[baseHash] = {
                        count = remote.count,
                        asOf = remote.asOf or 0,
                    }
                end
            end
        end
    end

    syncState.receiveNormalized = (syncState.receiveNormalized or 0) + normalized

    local stored = itemStored + moneyStored
    -- Invalidate rescan session caches so the next periodic rescan uses
    -- BuildStoredRecordIndex (ground truth) instead of stale batch counts.
    if stored > 0 then
        self._lastTabBatchCounts = nil
        self._lastMoneyBatchCounts = nil
    end
    local duped = itemDuped + moneyDuped
    syncState.receiveGot = syncState.receiveGot + 1
    syncState.receiveStored = syncState.receiveStored + stored
    syncState.receiveDuped = syncState.receiveDuped + duped
    syncState.receiveItemStored = (syncState.receiveItemStored or 0) + itemStored
    syncState.receiveItemDuped = (syncState.receiveItemDuped or 0) + itemDuped
    syncState.receiveMoneyStored = (syncState.receiveMoneyStored or 0) + moneyStored
    syncState.receiveMoneyDuped = (syncState.receiveMoneyDuped or 0) + moneyDuped
    syncState.receiveExpected = data.totalChunks or 1

    -- Reset receive timeout — NACK with backoff for missing chunk
    syncState.receiveNackCount = 0  -- reset on successful chunk receipt

    -- Only set timeout if more chunks expected
    if not (data.chunk and data.totalChunks and data.chunk >= data.totalChunks) then
        self:ScheduleReceiveTimeout()
    elseif syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
        syncState.receiveTimer = nil
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
    self:SendSyncWhisper(PREFIX, ackMsg, sender, "ALERT")

    local runningTotal = syncState.receiveStored + syncState.receiveDuped
    local dupPctSuffix = ""
    if runningTotal > 0 then
        local dupPct = math.floor(100 * syncState.receiveDuped / runningTotal + 0.5)
        dupPctSuffix = ", " .. dupPct .. "% dup"
    end
    self:AddAuditEntry("Received chunk " .. (data.chunk or "?") .. "/"
        .. (data.totalChunks or "?") .. " from " .. sender
        .. " (" .. chunkTotal .. " records: "
        .. itemStored .. " item new, " .. itemDuped .. " item duped, "
        .. moneyStored .. " money new, " .. moneyDuped .. " money duped"
        .. " | total so far: " .. syncState.receiveStored .. " new" .. dupPctSuffix .. ")")

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

    local ackedChunk = data and data.chunk or syncState.sendChunkIndex
    -- Discard stale ACKs from retried chunks to prevent orphaning active timers
    if ackedChunk ~= syncState.sendChunkIndex then
        self:AddAuditEntry("Discarded stale ACK for chunk " .. ackedChunk
            .. " (expected " .. syncState.sendChunkIndex .. ")")
        return
    end

    if syncState.sendTimer then
        syncState.sendTimer:Cancel()
        syncState.sendTimer = nil
    end

    -- v0.28.4: record outcome + wire-to-ACK latency for this chunk (H4 diagnostic)
    local wireAnchor = syncState.sendChunkTransmittedAt or 0
    local wireToAck = (wireAnchor > 0) and (GetTime() - wireAnchor) or nil
    if syncState.chunkOutcomes and syncState.chunkOutcomes[ackedChunk] then
        syncState.chunkOutcomes[ackedChunk].outcome = "ok"
        syncState.chunkOutcomes[ackedChunk].wireToAck = wireToAck
    end

    local total = #syncState.sendChunks
    -- Only audit-log every 10th ACK and the last one
    if ackedChunk == 1 or ackedChunk == total or ackedChunk % 10 == 0 then
        local rtt = string.format(", %.1fs RTT", GetTime() - (syncState.sendChunkSentAt or GetTime()))
        local wireStr = wireToAck and string.format(", wire-to-ACK=%.2fs", wireToAck) or ""
        self:AddAuditEntry("ACK from " .. sender .. " for chunk " .. ackedChunk
            .. "/" .. total .. rtt .. wireStr)
    end

    syncState.sendRetryCount = 0
    syncState.nacksForCurrentChunk = 0  -- v0.28.4: advancing to next chunk

    -- Adaptive delay between chunks (slows down when FPS is low)
    C_Timer.After(self:GetSyncDelay(), function()
        self:SendNextChunk()
    end)
end

--- Clean up receiving state and persist sync metadata.
-- @param sender string The peer we synced from
function GBL:FinishReceiving(sender)
    -- Remove sender from pending queue — no point re-requesting immediately
    self:RemovePendingPeer(sender)

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

    -- Post-sync cleanup: trim excess records using merged eventCounts
    if guildData then
        local cleanupRemoved = self:CleanupWithEventCounts(guildData)
        if cleanupRemoved > 0 then
            totalStored = math.max(0, totalStored - cleanupRemoved)
            self:AddAuditEntry("Post-sync cleanup: removed " .. cleanupRemoved
                .. " excess record(s)")
        end
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

    self:AddAuditEntry("Sync complete from " .. (sender or "unknown")
        .. " — " .. totalStored .. " new, " .. totalDuped .. " duped"
        .. ", " .. totalNormalized .. " normalized"
        .. ", " .. chunksGot .. " chunks, " .. elapsed .. "s"
        .. " | total tx now: " .. totalTxAfter .. ", hash: " .. newHash)

    -- v0.28.8: redundancy metric — measures bucket-granularity inefficiency.
    -- Suppressed if zero records received (empty sync).
    local itemStored_s = syncState.receiveItemStored or 0
    local itemDuped_s = syncState.receiveItemDuped or 0
    local moneyStored_s = syncState.receiveMoneyStored or 0
    local moneyDuped_s = syncState.receiveMoneyDuped or 0
    local totalGot = totalStored + totalDuped
    if totalGot > 0 then
        local totalDupPct = math.floor(100 * totalDuped / totalGot + 0.5)
        local segments = {}
        local itemTotal = itemStored_s + itemDuped_s
        if itemTotal > 0 then
            local itemPct = math.floor(100 * itemDuped_s / itemTotal + 0.5)
            segments[#segments + 1] = "items: " .. itemPct
                .. "% (" .. itemDuped_s .. "/" .. itemTotal .. ")"
        end
        local moneyTotal = moneyStored_s + moneyDuped_s
        if moneyTotal > 0 then
            local moneyPct = math.floor(100 * moneyDuped_s / moneyTotal + 0.5)
            segments[#segments + 1] = "money: " .. moneyPct
                .. "% (" .. moneyDuped_s .. "/" .. moneyTotal .. ")"
        end
        local line = "Redundancy from " .. (sender or "unknown") .. ": "
            .. totalDupPct .. "% duped (" .. totalDuped .. "/" .. totalGot .. " received)"
        if #segments > 0 then
            line = line .. " — " .. table.concat(segments, ", ")
        end
        self:AddAuditEntry(line)
    end

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
    syncState.receiveItemStored = 0
    syncState.receiveItemDuped = 0
    syncState.receiveMoneyStored = 0
    syncState.receiveMoneyDuped = 0
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

    -- Post-sync: process pending peers queue after a brief delay
    if syncState.pendingPeersCount > 0 and self.db.profile.sync.autoSync then
        C_Timer.After(0.2, function()
            if syncState.receiving then return end
            if isSyncPaused() then return end
            if InCombatLockdown and InCombatLockdown() then return end
            self:ProcessPendingPeers()
        end)
    end

    -- Post-sync HELLO: broadcast updated dataset so peers discover our new data
    -- and can request what we now have. Only if we actually stored new records.
    if totalStored > 0 then
        C_Timer.After(0.5 + math.random() * 1.5, function()
            if not self.db.profile.sync.enabled then return end
            self:BroadcastHello(true)  -- force=true bypasses cooldown
            self:AddAuditEntry("Post-sync HELLO broadcast (received "
                .. totalStored .. " new records)")
        end)
    end
end

------------------------------------------------------------------------
-- Peer tracking
------------------------------------------------------------------------

--- Update the session peer list with data from a HELLO message.
-- @param sender string Peer name
-- @param data table HELLO payload
function GBL:UpdatePeer(sender, data)
    local clean = Ambiguate(sender, "none")
    syncState.peers[clean] = {
        version = data.version,
        txCount = data.txCount or 0,
        dataHash = data.dataHash,
        lastScanTime = data.lastScanTime or 0,
        lastSeen = GetServerTime(),
    }
    -- Persist for cross-session discovery (survives relog)
    local guildData = self:GetGuildData()
    if guildData then
        guildData.knownPeers[clean] = {
            version = data.version,
            txCount = data.txCount or 0,
            lastSeen = GetServerTime(),
        }
    end
end

------------------------------------------------------------------------
-- Pending peers queue
------------------------------------------------------------------------

--- Add a peer to the pending sync queue (idempotent, capped at MAX_PENDING_PEERS).
-- Peers are queued when a sync opportunity is missed (busy, combat, zone change)
-- and processed after the current sync completes.
-- @param name string Peer character name
function GBL:AddPendingPeer(name)
    local clean = Ambiguate(name, "none")
    if syncState.pendingPeers[clean] then return end
    if syncState.pendingPeersCount >= MAX_PENDING_PEERS then return end

    -- Compute priority metadata for smart peer selection
    local txCountDiff = 0
    local peerInfo = syncState.peers[clean]
    if peerInfo then
        local gd = self:GetGuildData()
        if gd then
            local localCount = #gd.transactions + #gd.moneyTransactions
            txCountDiff = math.abs(localCount - (peerInfo.txCount or 0))
        end
    end

    syncState.pendingPeers[clean] = {
        addedAt = GetServerTime(),
        txCountDiff = txCountDiff,
        busyUntil = 0,
    }
    syncState.pendingPeersCount = syncState.pendingPeersCount + 1
    self:AddAuditEntry("Queued pending peer: " .. clean)
end

--- Remove a peer from the pending sync queue.
-- @param name string Peer character name
function GBL:RemovePendingPeer(name)
    local clean = Ambiguate(name, "none")
    if syncState.pendingPeers[clean] then
        syncState.pendingPeers[clean] = nil
        syncState.pendingPeersCount = syncState.pendingPeersCount - 1
    end
end

--- Pop the highest-priority valid peer from the pending queue.
-- Uses scored selection: txCountDiff (divergence), BUSY cooldown, starvation prevention.
-- Skips stale/offline peers. Returns nil if empty.
-- @return string|nil Peer name to sync with
function GBL:PopPendingPeer()
    local now = GetServerTime()
    local bestName = nil
    local bestScore = -math.huge

    -- First pass: find the highest-scoring valid peer
    for name, entry in pairs(syncState.pendingPeers) do
        local peer = syncState.peers[name]
        if not peer or (now - (peer.lastSeen or 0) > PEER_STALE_SECONDS) then
            -- Stale — remove silently (cleaned up below)
        else
            local online = self:IsGuildMemberOnline(name)
            if online == false then
                -- Offline — remove silently (cleaned up below)
            else
                -- Compute priority score
                local score = (entry.txCountDiff or 0) * 10
                -- Manifest-based bucket diff (more precise than txCount)
                local manifest = syncState.peerManifests[name]
                if manifest and manifest.buckets then
                    local gd = self:GetGuildData()
                    if gd then
                        local localBuckets = self:ComputeBucketHashes(gd)
                        local diffCount = 0
                        for key, hash in pairs(manifest.buckets) do
                            if hash ~= (localBuckets[key] or 0) then
                                diffCount = diffCount + 1
                            end
                        end
                        for key in pairs(localBuckets) do
                            if not manifest.buckets[key] then
                                diffCount = diffCount + 1
                            end
                        end
                        score = score + diffCount * 20
                    end
                end
                -- Starvation prevention: boost after PEER_STARVATION_SECONDS in queue
                if (entry.addedAt or 0) < now - PEER_STARVATION_SECONDS then
                    score = score + 1000
                end
                -- Deprioritize recently-BUSY peers
                if (entry.busyUntil or 0) > now then
                    score = score - 500
                end
                if score > bestScore then
                    bestScore = score
                    bestName = name
                end
            end
        end
    end

    -- Second pass: clean up stale/offline entries
    local toRemove = {}
    for name, _ in pairs(syncState.pendingPeers) do
        local peer = syncState.peers[name]
        if not peer or (now - (peer.lastSeen or 0) > PEER_STALE_SECONDS) then
            toRemove[#toRemove + 1] = name
            self:AddAuditEntry("Skipped stale pending peer: " .. name)
        else
            local online = self:IsGuildMemberOnline(name)
            if online == false then
                toRemove[#toRemove + 1] = name
                self:AddAuditEntry("Skipped offline pending peer: " .. name)
            end
        end
    end
    for _, name in ipairs(toRemove) do
        syncState.pendingPeers[name] = nil
        syncState.peerManifests[name] = nil  -- clean stale manifests too
        syncState.pendingPeersCount = syncState.pendingPeersCount - 1
    end

    -- Remove the selected peer from the queue (preserve addedAt for diagnostics)
    local addedAt
    if bestName then
        addedAt = syncState.pendingPeers[bestName]
            and syncState.pendingPeers[bestName].addedAt or nil
        syncState.pendingPeers[bestName] = nil
        syncState.pendingPeersCount = syncState.pendingPeersCount - 1
    end

    return bestName, addedAt
end

--- Process the next peer in the pending sync queue.
-- Called after FinishReceiving and FinishSending when the sync lock is free.
-- Skips peers whose data has already converged (hash match).
function GBL:ProcessPendingPeers()
    if syncState.receiving then return end
    if isSyncPaused() then return end
    if not self.db.profile.sync.enabled then return end
    if not self.db.profile.sync.autoSync then return end

    local peer, peerAddedAt = self:PopPendingPeer()
    if not peer then return end

    local guildData = self:GetGuildData()
    if not guildData then return end

    -- Verify hashes still differ (data may have converged via another sync)
    local peerInfo = syncState.peers[peer]
    if peerInfo and peerInfo.dataHash then
        local localHash = self:GetDataHash(guildData)
        local localCount = #guildData.transactions + #guildData.moneyTransactions
        if peerInfo.dataHash == localHash and (peerInfo.txCount or 0) == localCount then
            self:AddAuditEntry("Skipped queued peer " .. peer
                .. " — hashes now match")
            -- Try next peer in queue
            self:ProcessPendingPeers()
            return
        end
    end

    local queueTime = peerAddedAt and (GetServerTime() - peerAddedAt) or 0
    self:AddAuditEntry("Processing queued peer: " .. peer .. " (queued " .. queueTime .. "s)")
    local sinceTimestamp = guildData.syncState.lastSyncTimestamp or 0
    self:RequestSync(peer, sinceTimestamp)
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Append an entry to the session audit trail (capped at 200).
-- @param message string Human-readable log entry
function GBL:AddAuditEntry(message, chatOnly)
    if self.db and self.db.profile.sync.chatLog then
        self:Print("Sync: " .. message)
    end
    if chatOnly then return end
    table.insert(syncState.auditTrail, 1, {
        timestamp = GetServerTime(),
        message = message,
    })
    while #syncState.auditTrail > 2000 do
        table.remove(syncState.auditTrail)
    end
end

--- Check if a guild member is currently online via the guild roster.
-- @param name string Character name (bare or realm-qualified)
-- @return boolean|nil true if online, false if offline, nil if not found
function GBL:IsGuildMemberOnline(name)
    local target = self:StripRealm(name)
    local numMembers = GetNumGuildMembers()
    if not numMembers or numMembers == 0 then return nil end
    for i = 1, numMembers do
        local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if fullName then
            local base = self:StripRealm(fullName)
            if base == target then
                return isOnline
            end
        end
    end
    return nil  -- not found in roster
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
        combatPaused = syncState.combatPaused,
        pendingPeersCount = syncState.pendingPeersCount,
        receiveNackCount = syncState.receiveNackCount,
    }
end

--- Return active peers (seen within PEER_STALE_SECONDS, or online per guild roster).
-- Peers whose HELLO is stale but who are still online according to the guild roster
-- are included with rosterOnly=true so the UI can display them without sync attempting
-- to contact them (guild addon messages don't reliably cross instance boundaries).
-- @return table Map of name → { version, txCount, lastScanTime, lastSeen, rosterOnly? }
function GBL:GetSyncPeers()
    local now = GetServerTime()
    local active = {}
    for name, info in pairs(syncState.peers) do
        if now - (info.lastSeen or 0) <= PEER_STALE_SECONDS then
            -- Cross-check guild roster to catch peers who went offline
            -- since their last message (e.g., disconnect during sync)
            if self:IsGuildMemberOnline(name) ~= false then
                active[name] = info
            end
        else
            -- Stale HELLO — check guild roster as fallback
            local online = self:IsGuildMemberOnline(name)
            if online then
                local copy = {}
                for k, v in pairs(info) do copy[k] = v end
                copy.rosterOnly = true
                active[name] = copy
            end
        end
    end
    return active
end

--- Return the highest version string among active peers (or nil).
-- @return string|nil Highest peer version
function GBL:GetHighestPeerVersion()
    local peers = self:GetSyncPeers()
    local highest = nil
    for _, info in pairs(peers) do
        local pv = info.version
        if pv and pv ~= "?" then
            if not highest or self:CompareSemver(pv, highest) > 0 then
                highest = pv
            end
        end
    end
    return highest
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
    syncState.sendChunkSentAt = 0
    syncState.sendEventCountBatches = nil
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
    syncState.combatPaused = false
    if syncState.combatCooldownTimer then
        syncState.combatCooldownTimer:Cancel()
    end
    syncState.combatCooldownTimer = nil
    syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL
    syncState.fpsFrame = nil
    syncState.lastFpsCheck = 0
    syncState.pendingPeers = {}
    syncState.pendingPeersCount = 0
    syncState.lastForcedHelloTime = 0
    syncState.lastHelloReplyHash = {}
    syncState.peerManifests = {}
    syncState.lastManifestHash = 0
    syncState.lastManifestTime = 0
    if syncState.manifestTimer then
        syncState.manifestTimer:Cancel()
        syncState.manifestTimer = nil
    end
    syncState.helloRepliesDuringSync = 0
    syncState.nacksReceivedDuringSync = 0
    syncState.lastChunkBytes = 0
    syncState.lastSendIssuedAt = 0
    syncState.sendChunkTransmittedAt = 0
    syncState.nacksForCurrentChunk = 0
    syncState.chunkOutcomes = {}
    ctlDeferTotal = 0
    for k in pairs(recentWhisperTargets) do
        recentWhisperTargets[k] = nil
    end
end

--- Get CTL deferral total. Exposed for testing only.
-- @return number Total CTL deferrals since last sync start
function GBL:GetCtlDeferTotal()
    return ctlDeferTotal
end

--- Set lastChunkBytes directly. Exposed for testing only.
-- @param n number Compressed chunk size in bytes
function GBL._syncState_setLastChunkBytes(n)
    syncState.lastChunkBytes = n
end

--- Return the module-local syncState table. Exposed for testing only.
function GBL:GetSyncStateForTests()
    return syncState
end

--- Set receiveStartTime directly. Exposed for testing only.
-- @param ts number Timestamp to set
function GBL:SetReceiveStartTime(ts)
    syncState.receiveStartTime = ts
end

------------------------------------------------------------------------
-- Receive timeout scheduling (NACK backoff)
------------------------------------------------------------------------

--- Schedule (or reschedule) the receive timeout with NACK backoff.
-- Cancels any existing receive timer first. Uses progressive delays:
-- 20s → 30s → 45s (capped). After MAX_NACK_RETRIES, aborts the sync.
function GBL:ScheduleReceiveTimeout()
    if syncState.receiveTimer then
        syncState.receiveTimer:Cancel()
    end
    local timeout = nackBackoff(syncState.receiveNackCount)
    syncState.receiveTimer = C_Timer.NewTicker(timeout, function()
        if not syncState.receiving then return end

        -- Safety net: abort if receiving has been stuck for too long
        if syncState.receiveStartTime > 0
            and (GetServerTime() - syncState.receiveStartTime) > MAX_RECEIVE_DURATION then
            self:AddAuditEntry("Receive timeout: stuck for >"
                .. MAX_RECEIVE_DURATION .. "s — aborting")
            self:FinishReceiving(syncState.receiveSource)
            return
        end

        -- Check if sender went offline (abort early instead of wasting NACKs)
        local online = self:IsGuildMemberOnline(syncState.receiveSource)
        if online == false then
            self:AddAuditEntry("Sender " .. (syncState.receiveSource or "?")
                .. " offline — aborting receive")
            self:FinishReceiving(syncState.receiveSource)
            return
        end

        if syncState.receiveNackCount >= MAX_NACK_RETRIES then
            self:AddAuditEntry("NACK limit reached for chunk "
                .. (syncState.receiveGot + 1) .. " from "
                .. (syncState.receiveSource or "unknown") .. " — aborting")
            self:FinishReceiving(syncState.receiveSource)
        else
            self:SendNack(syncState.receiveSource, syncState.receiveGot + 1)
            -- Reschedule with increased backoff
            self:ScheduleReceiveTimeout()
        end
    end, 1)
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
    if not self:SendSyncWhisper(PREFIX, msg, target, "ALERT") then return end
    self:AddAuditEntry("Sent NACK for chunk " .. chunkIndex
        .. " to " .. target .. " (attempt " .. syncState.receiveNackCount
        .. "/" .. MAX_NACK_RETRIES .. ")")
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

    local ctlState = ""
    do
        local CTL = _G.ChatThrottleLib
        if CTL and CTL.avail then
            ctlState = ", CTL.avail=" .. string.format("%.0f", CTL.avail)
        end
    end
    syncState.nacksReceivedDuringSync = (syncState.nacksReceivedDuringSync or 0) + 1
    syncState.nacksForCurrentChunk = (syncState.nacksForCurrentChunk or 0) + 1
    self:AddAuditEntry("NACK from " .. sender .. " for chunk " .. requestedChunk
        .. " — re-transmitting" .. ctlState)

    -- v0.28.7: tag retry cause on the chunk we're re-requesting
    if syncState.chunkOutcomes and syncState.chunkOutcomes[requestedChunk] then
        table.insert(syncState.chunkOutcomes[requestedChunk].retryReasons, "nack")
    end
    -- Rewind to the requested chunk and re-send after a brief delay
    syncState.sendChunkIndex = requestedChunk - 1
    C_Timer.After(0.5, function()
        self:SendNextChunk()
    end)
end

------------------------------------------------------------------------
-- BUSY response
------------------------------------------------------------------------

--- Handle an incoming BUSY response from a peer we requested sync from.
-- Clears receiving state immediately (instead of waiting 60s for NACKs to expire)
-- and queues the peer for retry after the current sync completes.
-- @param sender string Peer who is busy
-- @param data table Deserialized BUSY payload (unused, reserved)
function GBL:HandleBusy(sender, data) -- luacheck: ignore 212/data
    local cleanSender = Ambiguate(sender, "none")
    self:AddAuditEntry("Received BUSY from " .. cleanSender)

    -- Clear receiving state if we're waiting for this peer (even with partial data).
    -- Already-stored records are safe; next sync uses bucket hashes to avoid re-sending.
    if syncState.receiving
        and self:StripRealm(sender) == self:StripRealm(syncState.receiveSource) then
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

        self:AddAuditEntry(cleanSender .. " busy — cleared receive state, will retry later")
    end

    -- Also abort sending if BUSY came from our send target
    -- (partner entered combat or became busy while we were sending to them)
    if syncState.sending
        and self:StripRealm(sender) == self:StripRealm(syncState.sendTarget) then
        -- v0.28.7: tag outcome on the chunk that was in flight when BUSY arrived
        local busyIdx = syncState.sendChunkIndex
        if busyIdx and syncState.chunkOutcomes and syncState.chunkOutcomes[busyIdx]
            and syncState.chunkOutcomes[busyIdx].outcome == "pending" then
            syncState.chunkOutcomes[busyIdx].outcome = "busyAbort"
        end
        if syncState.sendTimer then
            syncState.sendTimer:Cancel()
            syncState.sendTimer = nil
        end
        if syncState.sendHardTimer then
            syncState.sendHardTimer:Cancel()
            syncState.sendHardTimer = nil
        end
        syncState.sending = false
        syncState.sendTarget = nil
        syncState.sendChunks = {}
        syncState.sendChunkIndex = 0
        syncState.sendRetryCount = 0
        syncState.sendStartTime = 0
        syncState.sendTotalRecords = 0
        syncState.sendEventCountBatches = nil
        self:StopFpsMonitor()

        self:AddAuditEntry(cleanSender .. " busy — aborting send")
    end

    -- Queue for retry regardless of whether we cleared state
    self:AddPendingPeer(cleanSender)
    -- Deprioritize busy peers — they'll be selected after non-busy peers
    if syncState.pendingPeers[cleanSender] then
        syncState.pendingPeers[cleanSender].busyUntil = GetServerTime() + BUSY_COOLDOWN
    end
end

------------------------------------------------------------------------
-- Combat protection
------------------------------------------------------------------------

--- Abort sync immediately when combat starts.
-- Sends BUSY to partner, aborts in-progress sync, and sets combatPaused.
-- No-op if not actively sending or receiving.
-- Called by PLAYER_REGEN_DISABLED event.
function GBL:OnCombatStart()
    if not syncState.sending and not syncState.receiving then return end

    syncState.combatPaused = true

    -- Cancel any pending combat cooldown from a prior rapid combat cycle
    if syncState.combatCooldownTimer then
        syncState.combatCooldownTimer:Cancel()
        syncState.combatCooldownTimer = nil
    end

    self:AddAuditEntry("Combat started — aborting sync")

    -- Capture partner names BEFORE calling Finish (which clears them)
    local sendTarget = syncState.sendTarget
    local receiveSource = syncState.receiveSource

    -- Cancel all sync timers to prevent false timeouts during combat
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

    -- v0.28.7: tag the in-flight chunk as combatAbort before FinishSending runs
    if syncState.sending and syncState.chunkOutcomes then
        local combatIdx = syncState.sendChunkIndex
        if combatIdx and syncState.chunkOutcomes[combatIdx]
            and syncState.chunkOutcomes[combatIdx].outcome == "pending" then
            syncState.chunkOutcomes[combatIdx].outcome = "combatAbort"
        end
    end
    -- Abort active sync
    if syncState.sending then
        self:FinishSending()
    end
    if syncState.receiving then
        self:FinishReceiving(receiveSource or "?")
    end

    -- Notify partners via BUSY so they abort immediately
    local busyMsg = self:Serialize({
        type = "BUSY",
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    busyMsg = compressMessage(busyMsg)

    if sendTarget then
        self:SendSyncWhisper(PREFIX, busyMsg, sendTarget, "ALERT")
        self:AddAuditEntry("Sent BUSY to send target: " .. sendTarget)
    end
    if receiveSource and receiveSource ~= sendTarget then
        self:SendSyncWhisper(PREFIX, busyMsg, receiveSource, "ALERT")
        self:AddAuditEntry("Sent BUSY to receive source: " .. receiveSource)
    end
end

--- Resume pending sync after combat ends.
-- Called by PLAYER_REGEN_ENABLED event.
function GBL:OnCombatEnd()
    if syncState.combatPaused then
        -- Cancel any prior cooldown timer (rapid combat in/out)
        if syncState.combatCooldownTimer then
            syncState.combatCooldownTimer:Cancel()
        end
        syncState.combatCooldownTimer = C_Timer.NewTicker(COMBAT_COOLDOWN, function()
            syncState.combatPaused = false
            syncState.combatCooldownTimer = nil
            self:AddAuditEntry("Combat cooldown complete — sync resumed")
            if syncState.pendingPeersCount > 0 and not syncState.receiving
                and not isSyncPaused() and self.db.profile.sync.autoSync then
                self:ProcessPendingPeers()
            end
        end, 1)
        return
    end

    -- Legacy path: pending peers without combat pause (e.g., deferred from HandleHello)
    if syncState.pendingPeersCount > 0 and not syncState.receiving then
        C_Timer.After(2, function()
            if syncState.receiving then return end
            if isSyncPaused() then return end
            self:ProcessPendingPeers()
        end)
    end
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

    -- v0.28.7: tag the in-flight chunk so the histogram attributes the gap
    -- to a zone pause, not to a successful ACK on the pre-pause chunk. The
    -- sync resumes post-cooldown but this chunk's ACK timer was cancelled,
    -- so its outcome is genuinely indeterminate until the next chunk fires.
    if syncState.sending and syncState.chunkOutcomes then
        local zoneIdx = syncState.sendChunkIndex
        if zoneIdx and syncState.chunkOutcomes[zoneIdx]
            and syncState.chunkOutcomes[zoneIdx].outcome == "pending" then
            syncState.chunkOutcomes[zoneIdx].outcome = "zoneAbort"
        end
    end

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

        -- Don't resume if still in combat (zone change during combat scenario)
        if syncState.combatPaused then
            self:AddAuditEntry("Zone cooldown complete but still in combat — deferring")
            return
        end

        self:AddAuditEntry("Zone cooldown complete — sync resumed")

        -- Resume sending if we were the sender
        if syncState.sending then
            self:SendNextChunk()
        end

        -- Restart receive timeout if we were receiving (uses backoff)
        if syncState.receiving then
            self:ScheduleReceiveTimeout()
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
    if not CTL.avail then return true end
    -- Require enough headroom for a full chunk, not just a fixed minimum.
    -- This prevents burst-queuing multiple chunks when CTL is high.
    local threshold = math.max(CTL_BANDWIDTH_MIN, syncState.lastChunkBytes or 0)
    if CTL.avail < threshold then
        return false
    end
    return true
end
