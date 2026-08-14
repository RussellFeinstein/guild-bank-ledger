------------------------------------------------------------------------
-- GuildBankLedger — Sync.lua
-- Guild-wide transaction sync via AceComm
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Protocol constants
local PREFIX = "GBLSync"
local PROTOCOL_VERSION = 4
-- Oldest addon version this build will exchange records with.
--
-- Until v0.37.0 the gate was exact-match, so every release, patch included,
-- split the guild into non-communicating islands until every member updated.
-- This replaces that with a range: we sync with a peer at or above our floor
-- whose own floor we also meet. v0.37.0 spends one last lockstep update to
-- establish the baseline, and normal releases after it cost nothing.
--
-- Raise this ONLY for a wire, record-identity or fingerprint break, never for
-- an ordinary release. Raising it re-imposes the split it exists to remove.
local MIN_SYNC_VERSION = "0.37.0"
-- Chunk size tuning (#92 — the budget covers the whole message)
--
-- AceComm splits a message into 255-byte wire fragments, and whole-chunk loss
-- compounds per fragment: 1-(1-p)^n. One fragment per chunk has been the design
-- target since v0.28.7 and has never once held. The 2026-08-10 capture measured
-- n=3.0 fragments per chunk, chunkFail 46.1% against p_frag 18.7%.
--
-- Two causes, both fixed here. The 900-byte budget could never fire at 4 records
-- per chunk (4 records estimate ~790, so the record cap always won first), and
-- it only ever weighed records: the event count rider and the envelope attach at
-- serialize time, after chunking. Measured on a real first chunk: 1,637 raw
-- bytes, of which 736 were the records the budget counted, 768 were the ten
-- event count entries it did not, and 133 were the envelope.
--
-- So the budget now governs the whole serialized message, and PrepareChunks
-- fills each chunk with records and event count entries against it together.
--
-- Where 510 comes from: wire = raw × ratio, and the ratio measured across every
-- capture is 23–49% (money-heavy chunks compress worst). Guaranteeing one
-- fragment at the worst ratio ever seen gives raw ≤ 255 / 0.50 = 510. This is
-- the same formula that produced the 900, with the measured worst ratio instead
-- of an assumed 26% and with the whole message counted instead of the records
-- alone. Do not re-derive it from a median: the v0.28.5→28.6→28.7 arc missed
-- three times running by predicting ratios, which is why this takes the max.
local MAX_RECORDS_PER_CHUNK = 4
local CHUNK_TARGET_BYTES = 510
-- ACK_TIMEOUT and MAX_RETRIES move together, and the product is the number that
-- matters: it is how long a chunk keeps trying before the send gives up.
--
-- 8s dates from v0.23.0, when a chunk was 25 records across several fragments.
-- At one fragment the 2026-08-10 capture measured wire-to-ACK at 0.50-0.67s on
-- every logged success, so 8s spent most of each retry cycle waiting on a timer
-- that had already told us what it was going to. 3s keeps ~4.5x headroom over
-- the worst observation and cuts the cost of a lost fragment by more than half.
--
-- MAX_RETRIES rises with it so patience does not collapse: 6 attempts x 8s was
-- ~40s, 6 x 3s would be ~18s, and a receiver on a 20-30s loading screen would
-- start failing sends that survive today. 11 x 3s restores ~33s. Exhausting an
-- 11-attempt ladder at ~19% per-attempt loss is ~1e-8, and a genuinely offline
-- target still aborts early through the offline check rather than the ladder.
local MAX_RETRIES = 10
local ACK_TIMEOUT = 3
local RECEIVE_CHUNK_TIMEOUT = 20
local MAX_NACK_RETRIES = 3
local HELLO_COOLDOWN = 60
local SUPERSET_NUDGE_THROTTLE = 60  -- min seconds between re-nudges to one behind peer
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
local KNOWN_PEER_EXPIRE_SECONDS = 30 * 24 * 3600  -- 30 days
local INITIAL_CHUNK_TIMEOUT = 10
-- How long to leave a peer alone after they tell us they are busy. Nothing
-- else backs off for us: there is no queue holding a retry, so this is the
-- whole mechanism.
local BUSY_COOLDOWN = 30
local FORCED_HELLO_COOLDOWN = 10
-- How many records one session aims to carry, before rounding up to whole
-- bucket boundaries. At the post-#92 density of roughly one record per chunk
-- and the 1.0s inter-chunk gap floor, 300 is about five minutes on the wire.
-- That is short enough that both peers rejoin the gossip pool quickly and far
-- enough inside MAX_RECEIVE_DURATION (1800s) that a session ends because it
-- finished rather than because it ran out of time. Expect it to halve in
-- duration if the chunk budget rises to fill both wire fragments (#96).
local SESSION_RECORD_CAP = 300
local LAYOUT_REQUEST_THROTTLE = 30  -- min seconds between bank-layout pull requests
local WHISPER_TRACK_EXPIRE = 30
local MAX_RECEIVE_DURATION = 1800  -- 30 minutes absolute maximum receive time

-- Expose constants for testing and UI
GBL.SYNC_PROTOCOL_VERSION = PROTOCOL_VERSION
GBL.MIN_SYNC_VERSION = MIN_SYNC_VERSION
GBL.SYNC_CHUNK_SIZE = MAX_RECORDS_PER_CHUNK
GBL.SYNC_CHUNK_TARGET_BYTES = CHUNK_TARGET_BYTES
GBL.SYNC_PREFIX = PREFIX
GBL.SYNC_MAX_RETRIES = MAX_RETRIES
GBL.SYNC_ACK_TIMEOUT = ACK_TIMEOUT
GBL.SYNC_MAX_NACK_RETRIES = MAX_NACK_RETRIES
GBL.SYNC_PEER_STALE_SECONDS = PEER_STALE_SECONDS
GBL.SYNC_HELLO_HEARTBEAT_INTERVAL = HELLO_HEARTBEAT_INTERVAL
GBL.SYNC_KNOWN_PEER_EXPIRE_SECONDS = KNOWN_PEER_EXPIRE_SECONDS
GBL.SYNC_INITIAL_CHUNK_TIMEOUT = INITIAL_CHUNK_TIMEOUT
GBL.SYNC_BUSY_COOLDOWN = BUSY_COOLDOWN
GBL.SYNC_MAX_RECEIVE_DURATION = MAX_RECEIVE_DURATION
GBL.SYNC_FORCED_HELLO_COOLDOWN = FORCED_HELLO_COOLDOWN
GBL.SYNC_SUPERSET_NUDGE_THROTTLE = SUPERSET_NUDGE_THROTTLE
GBL.SYNC_SESSION_RECORD_CAP = SESSION_RECORD_CAP
GBL.SYNC_LAYOUT_REQUEST_THROTTLE = LAYOUT_REQUEST_THROTTLE
GBL.SYNC_COMBAT_COOLDOWN = COMBAT_COOLDOWN
GBL.SYNC_INTER_CHUNK_GAP_FLOOR = INTER_CHUNK_GAP_FLOOR

------------------------------------------------------------------------
-- Version compatibility (v0.37.0)
------------------------------------------------------------------------

--- True when a version string is a bare release number with no pre-release
-- suffix. A dev build carries "-dev.<id>".
local function isPlainSemver(v)
    return type(v) == "string" and v:match("^%d+%.%d+%.%d+$") ~= nil
end

--- Decide whether we may exchange records with a peer.
--
-- The dev-build check has to come before any CompareSemver call, because
-- CompareSemver deliberately strips "-dev.<id>" to compare release lines. A
-- range test that reached it would read a dev build and its base release as
-- compatible and undo the isolation DEV_BUILD exists to provide.
--
-- A peer that advertises no floor is running a pre-v0.37.0 build, and the old
-- exact-match rule is the right reading of it: nothing below the floor release
-- carries the guarantees the range rests on.
--
-- @param remoteVersion string|nil Peer's addon version
-- @param remoteMin string|nil Peer's advertised MIN_SYNC_VERSION
-- @return boolean ok
-- @return string reason One of exact|range|no-version|dev-isolated|
--                       pre-floor-peer|below-floor|local-below-their-floor
function GBL:IsVersionCompatible(remoteVersion, remoteMin)
    if remoteVersion == self.version then return true, "exact" end
    if not remoteVersion then return false, "no-version" end
    if not isPlainSemver(self.version) or not isPlainSemver(remoteVersion) then
        return false, "dev-isolated"
    end
    if not isPlainSemver(remoteMin) then return false, "pre-floor-peer" end
    if self:CompareSemver(remoteVersion, MIN_SYNC_VERSION) < 0 then
        return false, "below-floor"
    end
    if self:CompareSemver(self.version, remoteMin) < 0 then
        return false, "local-below-their-floor"
    end
    return true, "range"
end

--- Classify a peer's version for display: can we sync with them, and which
-- side is ahead.
--
-- Derived from the advertised version and floor, never from the session-only
-- `outdated` flag. That flag is written by live message intake, so a peer
-- seeded out of knownPeers at login does not have one, and a below-floor peer
-- who spends the session in an instance (where guild addon messages do not
-- reliably cross the boundary) would otherwise render as though sync worked.
-- Classifying from the versions is stale-proof by construction; persisting the
-- flag would only move the staleness somewhere harder to see.
--
-- @param info table|nil Peer info (reads .version and .minSyncVersion)
-- @param peerVersion string|nil Override for info.version
-- @return string One of incompatible_old, incompatible_new, dev_peer,
--   older_ok, newer_ok, same, unknown
function GBL:ClassifyPeerVersion(info, peerVersion)
    local version = peerVersion or (info and info.version)
    if not version or version == "?" then return "unknown" end

    local compatible, refusal =
        self:IsVersionCompatible(version, info and info.minSyncVersion)

    if not compatible then
        -- A dev build refuses everyone in both directions by design. Calling
        -- it "too old" would point the viewer at an update that does not
        -- exist and is not theirs to make.
        if refusal == "dev-isolated" then return "dev_peer" end
        -- Which side has to move. Their floor sitting above our version
        -- settles it directly; otherwise the versions do.
        local weAreBehind = (refusal == "local-below-their-floor")
            or self:CompareSemver(self.version, version) < 0
        return weAreBehind and "incompatible_new" or "incompatible_old"
    end

    local cmp = self:CompareSemver(self.version, version)
    if cmp == 0 then return "same" end
    return (cmp < 0) and "newer_ok" or "older_ok"
end

--- One line explaining a refusal, naming both versions so a log read months
-- later says which side needed to move. Used by all three gate sites.
-- @param who string Canonical peer key
-- @param reason string A reason code from IsVersionCompatible
-- @param remoteVersion string|nil
-- @param remoteMin string|nil
-- @return string
function GBL:DescribeVersionRefusal(who, reason, remoteVersion, remoteMin)
    local why
    if reason == "no-version" then
        why = "advertised no version"
    elseif reason == "dev-isolated" then
        why = "dev build isolation"
    elseif reason == "pre-floor-peer" then
        why = "predates the sync floor, so an exact match is required"
    elseif reason == "below-floor" then
        why = "below our v" .. MIN_SYNC_VERSION .. " sync floor"
    elseif reason == "local-below-their-floor" then
        why = "we are below their v" .. tostring(remoteMin) .. " sync floor"
    else
        why = "incompatible"
    end
    return string.format("%s on v%s refused: %s (this build is v%s)",
        tostring(who), tostring(remoteVersion or "?"), why, tostring(self.version))
end

-- Diagnostic: CTL deferral tracking (module-level, survives state resets)
local ctlDeferTotal = 0  -- monotonic count per sync session

-- CTL drain instrumentation (measurement only, no behavior change). Samples
-- the meter at every deferral, counts overlapping deferral timer chains
-- WITHOUT dedup'ing them, and times drain episodes. The capture campaign uses
-- these to attribute a Mode A stall to timer-chain multiplication (several of
-- SendNextChunk's callers can each start a self-rearming deferral chain) vs
-- external bandwidth contention, BEFORE any adaptive-backoff fix is built.
local ctlDrain = {
    samples = {},        -- chronological ring of { t, avail, threshold }
    sampleCap = 200,
    timersPending = 0,   -- CTL deferral timers currently scheduled
    overlapCount = 0,    -- schedules that saw >= 1 timer already pending (episode)
    overlapTotal = 0,    -- same, whole send session
    episodeStart = nil,  -- GetTime() of the open episode's first deferral
    episodeDefers = 0,
    minAvail = nil,      -- lowest observed CTL.avail this episode
    minAvailAt = nil,
    maxStall = 0,        -- longest completed episode this send session (s)
}
GBL._ctlDrain = ctlDrain  -- exposed for tests and /run inspection

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

    -- Peers who told us they are busy, and when we may approach them again.
    -- peerKey → GetServerTime() the cooldown expires. Entries expire by
    -- comparison rather than sweep; the table is bounded by peer count.
    peerBusyUntil = {},

    -- Set when a sync opportunity arrived during combat. Combat end
    -- re-advertises only if this is set, so a raid leaving combat together
    -- does not produce one broadcast per member.
    helloAfterCombat = false,

    -- What each peer got last session: targetKey -> { bucketKey -> local hash
    -- at send time }. Feeds the session cap's demotion set so a bucket we
    -- already sent, and have not changed since, waits behind everything else.
    capLastTranche = {},
    -- Buckets held back from the session now sending, announced to the
    -- receiver on the final chunk.
    sendRemainingBuckets = 0,

    -- HELLO traffic management (M4)
    lastForcedHelloTime = 0,
    lastHelloReplyHash = {},  -- name → hash we last communicated to this peer
    lastSupersetNudge = {},   -- peerKey → GetServerTime() of our last superset re-nudge
    incompatibleReplied = {}, -- peerKey → true once we have told them we refuse

    -- Bank layout advertise-and-pull (v0.32.11): timestamp of our last
    -- LAYOUT_REQUEST. Single in-flight guard so a newer-layout cursor seen on
    -- several peers' HELLOs does not fan out one request per peer.
    lastLayoutRequestAt = 0,

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
-- Keyed by StripRealm output, NOT CanonicalPeerKey: a "no player named X"
-- system message arrives bare and we want the suppression window to cover
-- all qualifications of that name (same name on either realm both share
-- the suppression). Bare-name semantics is intentional here; for peer
-- identity use CanonicalPeerKey.
local recentWhisperTargets = {}  -- stripped_name -> GetServerTime()

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
                    .. " confirmed offline (system error) - aborting send")
                GBL:FinishSending()
            end
            return true  -- suppress the system message
        end)
    end
    -- Seed session peers from persisted knownPeers (cross-session discovery).
    -- Seeded peers keep their original lastSeen (stale), so they won't be
    -- targeted for sync. The roster fallback in GetSyncPeers shows them
    -- as "online (no HELLO)" if the guild roster confirms they're online.
    -- Each key is run through CanonicalPeerKey so stale bare entries from
    -- pre-v0.30.5 saved variables (or from the buggy schema-11 cold-roster
    -- premature-bump) consolidate into their qualified form once playerRealms
    -- is warm. knownPeers itself is rewritten in place to converge persistent
    -- state too.
    local guildData = self:GetGuildData()
    if guildData and guildData.knownPeers then
        local now = GetServerTime()
        local rawKeys = {}
        for k in pairs(guildData.knownPeers) do rawKeys[#rawKeys+1] = k end
        for _, name in ipairs(rawKeys) do
            local info = guildData.knownPeers[name]
            if info and now - (info.lastSeen or 0) < KNOWN_PEER_EXPIRE_SECONDS then
                local clean = self:CanonicalPeerKey(name)
                -- Recency-merge syncState.peers: when both legacy bare and
                -- canonical qualified forms canonicalize to the same clean key
                -- (the upgrade scenario the v0.30.5 bundle addresses), pairs()
                -- iteration order is undefined so an unconditional write would
                -- nondeterministically let an older snapshot overwrite a newer
                -- one. Mirrors the recency check used for knownPeers below.
                local existingPeer = syncState.peers[clean]
                if not existingPeer or (info.lastSeen or 0) > (existingPeer.lastSeen or 0) then
                    syncState.peers[clean] = {
                        version = info.version,
                        -- The floor rides along because RequestSync's gate
                        -- reads it off the seeded entry, and the peer list
                        -- classifies from it. Without it a seeded post-floor
                        -- peer looks pre-floor (exact match required) until
                        -- their first live HELLO.
                        minSyncVersion = info.minSyncVersion,
                        txCount = info.txCount or 0,
                        lastSeen = info.lastSeen or 0,
                    }
                end
                if clean ~= name then
                    local existing = guildData.knownPeers[clean]
                    if existing then
                        if (info.lastSeen or 0) > (existing.lastSeen or 0) then
                            guildData.knownPeers[clean] = info
                        end
                    else
                        guildData.knownPeers[clean] = info
                    end
                    guildData.knownPeers[name] = nil
                end
            else
                guildData.knownPeers[name] = nil
            end
        end
    end
    self:StartHelloHeartbeat()
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
    syncState.peerBusyUntil = {}
    syncState.helloAfterCombat = false
    syncState.capLastTranche = {}
    syncState.lastForcedHelloTime = 0
    syncState.lastHelloReplyHash = {}
    syncState.lastSupersetNudge = {}
    syncState.incompatibleReplied = {}
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
        minSyncVersion = MIN_SYNC_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        txCount = txCount,
        dataHash = dataHash,
        lastScanTime = self.lastScanTime or 0,
        accessControl = guildData.accessControl,
        -- Only ride sortAccess on the wire once a GM has configured it
        -- (updatedAt > 0); keeps HELLO lean for guilds with no policy.
        sortAccess = (guildData.sortAccess and (guildData.sortAccess.updatedAt or 0) > 0)
            and guildData.sortAccess or nil,
        -- Advertise only the layout cursor (one timestamp), never the template
        -- itself. A populated layout is several KB; putting it on every HELLO
        -- broadcast would regress sync reliability for the whole guild. Peers
        -- that can sort and see a newer cursor pull the full template via
        -- LAYOUT_REQUEST. Gated on version > 0 (a saved, validated layout).
        layoutUpdatedAt = (guildData.bankLayout and (guildData.bankLayout.version or 0) > 0)
            and guildData.bankLayout.updatedAt or nil,
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
-- BUSY backoff
------------------------------------------------------------------------

--- True while a peer's BUSY cooldown is still running.
--
-- Checked at the sites that start a sync on their own initiative, not
-- inside RequestSync: a manual or forced pull is someone asking for it,
-- and refusing that silently would be its own bug.
--
-- This replaces the busyUntil field the pending-peer queue used to carry.
-- With no queue holding a retry, leaving a busy peer alone for a while is
-- the entire backoff, and recovery is their next HELLO.
-- @param name string Peer name in any form
-- @return boolean
function GBL:IsPeerBusy(name)
    local clean = self:CanonicalPeerKey(name)
    return (syncState.peerBusyUntil[clean] or 0) > GetServerTime()
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
        minSyncVersion = MIN_SYNC_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        txCount = txCount,
        dataHash = dataHash,
        lastScanTime = self.lastScanTime or 0,
        isReply = true,
        accessControl = guildData.accessControl,
        sortAccess = (guildData.sortAccess and (guildData.sortAccess.updatedAt or 0) > 0)
            and guildData.sortAccess or nil,
        layoutUpdatedAt = (guildData.bankLayout and (guildData.bankLayout.version or 0) > 0)
            and guildData.bankLayout.updatedAt or nil,
    })
    msg = compressMessage(msg)

    if not self:SendSyncWhisper(PREFIX, msg, target) then return end
    self:AddAuditEntry("Sent HELLO reply to " .. target
        .. " (tx: " .. txCount .. ", hash: " .. dataHash .. ")")
end

------------------------------------------------------------------------
-- Bank layout sync (advertise-and-pull, v0.32.11)
--
-- HELLO carries only layoutUpdatedAt (a cursor). A peer that HasSortAccess and
-- sees a newer cursor sends a LAYOUT_REQUEST; the holder replies with
-- LAYOUT_DATA carrying the full template + stock reserves. No ACK: each HELLO
-- re-advertises the cursor, so a dropped LAYOUT_DATA is re-pulled on the next
-- gossip tick until the receiver's cursor matches. Convergence, not per-message
-- proof (same philosophy as the sort executor).
------------------------------------------------------------------------

--- Send a LAYOUT_REQUEST to a peer, throttled to one in-flight request so a
-- newer cursor seen on several peers' HELLOs does not fan out N requests.
-- @param peer string raw sender name (canonicalized before use)
function GBL:MaybeRequestLayout(peer)
    local now = GetServerTime()
    if now - (syncState.lastLayoutRequestAt or 0) < LAYOUT_REQUEST_THROTTLE then
        return
    end
    local key = self:CanonicalPeerKey(peer)
    local msg = compressMessage(self:Serialize({
        type = "LAYOUT_REQUEST",
        guild = self:GetGuildName(),
    }))
    if self:SendSyncWhisper(PREFIX, msg, key) then
        syncState.lastLayoutRequestAt = now
        self:SyncDebug("Requested bank layout from %s", key)
    end
end

--- Serve our layout to a requester. Not access-gated (the layout is not
-- sensitive and epidemic spread needs any holder to serve), but only sent when
-- we actually have a configured layout to give.
function GBL:HandleLayoutRequest(sender, _data)
    local payload = self.BuildLayoutPayload and self:BuildLayoutPayload()
    if not payload then return end
    local key = self:CanonicalPeerKey(sender)
    local msg = compressMessage(self:Serialize({
        type = "LAYOUT_DATA",
        guild = self:GetGuildName(),
        nchunks = 1,   -- reserved for future chunking; always 1 for now
        chunk = 1,
        bankLayout = payload.bankLayout,
        stockReserves = payload.stockReserves,
    }))
    -- AceComm WHISPER drops payloads over ~WHISPER_SAFE_BYTES. Log the size so a
    -- real layout that exceeds the ceiling is visible (chunking is the fix).
    if #msg > WHISPER_SAFE_BYTES then
        self:SyncWarn("Layout payload for %s is %d B (> %d safe); transfer may drop, chunking needed",
            key, #msg, WHISPER_SAFE_BYTES)
    else
        -- INFO, not DEBUG: the serve size is the only signal for how close a
        -- real layout sits to the whisper ceiling, so it must land in the log
        -- without debug mode on.
        self:SyncInfo("Serving bank layout to %s (%d B)", key, #msg)
    end
    self:SendSyncWhisper(PREFIX, msg, key)
end

--- Adopt a layout payload from a peer (validated, last-writer-wins). Fires
-- GBL_LAYOUT_CHANGED on a real change so an open Sort/Layout tab refreshes.
function GBL:HandleLayoutData(sender, data)
    local key = self:CanonicalPeerKey(sender)
    if not self.AdoptRemoteBankLayout then return end
    local changed, err = self:AdoptRemoteBankLayout(data, key)
    if changed then
        local ts = data.bankLayout and data.bankLayout.updatedAt
        self:SyncInfo("Adopted bank layout from %s (updatedAt=%s)", key, tostring(ts))
        self:SendMessage("GBL_LAYOUT_CHANGED")
    elseif err then
        self:SyncWarn("Rejected bank layout from %s: %s", key, err)
    end
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

    -- Ignore our own messages. AceComm passes sender as "Name-Realm" in retail
    -- when cross-realm, "Name" or "Name-Realm" inconsistently for same-realm.
    -- CanonicalPeerKey strips realm only when it matches the local realm
    -- (custom logic, not Ambiguate), so own broadcasts always reduce to the
    -- bare name returned by UnitName("player"). For peer-identity keying
    -- elsewhere in this file always use CanonicalPeerKey, never raw
    -- StripRealm: the latter would silently collapse cross-realm same-name
    -- peers in connected-realm guilds.
    local myName = UnitName("player")
    if self:CanonicalPeerKey(sender) == myName then return end

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
            local cleanSender = self:CanonicalPeerKey(sender)
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
    local cleanSender = self:CanonicalPeerKey(sender)
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
    elseif msgType == "LAYOUT_REQUEST" then
        self:HandleLayoutRequest(sender, data)
    elseif msgType == "LAYOUT_DATA" then
        self:HandleLayoutData(sender, data)
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

    -- Accept the sort-access policy if the remote copy is newer (last-writer-
    -- wins on updatedAt, the timestamp SaveSortAccess stamps). Mirrors the
    -- accessControl merge above. sortAccess gates Sort/Layout tab visibility, so
    -- a GM's grant only takes effect on the granted member once it arrives here.
    if data.sortAccess and type(data.sortAccess) == "table"
        and (data.sortAccess.updatedAt or 0) > 0 then
        local gd = self:GetGuildData()
        if gd then
            local localTS = (gd.sortAccess and gd.sortAccess.updatedAt) or 0
            local remoteTS = data.sortAccess.updatedAt or 0
            if remoteTS > localTS then
                gd.sortAccess = data.sortAccess
                -- Normalize whatever arrived into the canonical two-tier shape
                -- (idempotent; also upgrades a legacy flat policy from an older
                -- peer). updatedAt/updatedBy survive the migration.
                self:MigrateSortAccessShape(gd)
                self:AddAuditEntry("Updated sort access from "
                    .. tostring(data.sortAccess.updatedBy)
                    .. " (updatedAt=" .. tostring(remoteTS) .. ")")
                self:SendMessage("GBL_ACCESS_CONTROL_CHANGED")
            end
        end
    end

    -- Bank layout advertise-and-pull. We only fetch the template if we can
    -- actually use it (HasSortAccess) AND the peer advertises a newer cursor.
    -- Members who cannot sort never request it, so the big payload stays off
    -- the wire for almost everyone. The GM and granted officers converge on
    -- the newest layout; the throttle keeps a single request in flight.
    if data.layoutUpdatedAt and self:HasSortAccess() then
        local gd = self:GetGuildData()
        local localTS = (gd and gd.bankLayout and gd.bankLayout.updatedAt) or 0
        if data.layoutUpdatedAt > localTS then
            self:MaybeRequestLayout(sender)
        end
    end

    -- Version gate (v0.37.0). Everything above this line runs for every peer on
    -- purpose: access control, the sort policy and the layout cursor are guild
    -- settings, and a GM's change has to reach members through a mixed-version
    -- window. Only record exchange is gated.
    --
    -- Placed above the reply block so an incompatible peer is answered once per
    -- session rather than on every heartbeat. They still need one reply to
    -- discover us and log their own refusal; after that the silence is the
    -- point.
    local compatible, refusal = self:IsVersionCompatible(data.version, data.minSyncVersion)
    if not compatible then
        local cleanSender = self:CanonicalPeerKey(sender)
        local explanation = self:DescribeVersionRefusal(
            cleanSender, refusal, data.version, data.minSyncVersion)
        if syncState.peers[cleanSender] then
            syncState.peers[cleanSender].outdated = true
            -- Which side needs to update. Their floor being above our version
            -- settles it directly; otherwise compare the two versions.
            local weAreBehind = (refusal == "local-below-their-floor")
                or (data.version ~= nil
                    and self:CompareSemver(self.version, data.version) < 0)
            syncState.peers[cleanSender].versionRelation =
                weAreBehind and "local_behind" or "peer_behind"
        end

        local told = syncState.incompatibleReplied[cleanSender]
        if not told then
            -- Marked before the send, not after: a whisper that fails is not
            -- worth retrying every heartbeat for the life of the mismatch.
            syncState.incompatibleReplied[cleanSender] = true
            self:SyncWarn(explanation)
            if not data.isReply then
                self:SendHelloReply(sender)
            end
        else
            self:SyncDebug("Still refusing: %s", explanation)
        end
        return
    end

    -- Reply to broadcast HELLOs so the sender discovers us.
    -- Hash-gated: only reply when our data changed since we last told this peer,
    -- or on first contact. Suppresses O(N²) reply traffic in large guilds.
    -- replyDecision records what the gate did this round so the superset skip
    -- below can log whether the behind peer got a fresh HELLO (diagnostic only;
    -- stays nil for an isReply HELLO, which never runs the gate).
    local replyDecision
    if not data.isReply then
        local cleanSenderReply = self:CanonicalPeerKey(sender)
        local gd = self:GetGuildData()
        local currentHash = gd and self:GetDataHash(gd) or 0
        local lastHash = syncState.lastHelloReplyHash[cleanSenderReply]
        if lastHash == nil or currentHash ~= lastHash then
            if syncState.sending or syncState.receiving then
                syncState.helloRepliesDuringSync =
                    (syncState.helloRepliesDuringSync or 0) + 1
                self:AddAuditEntry("Suppressed HELLO reply to "
                    .. cleanSenderReply .. " [sync active]")
                replyDecision = "suppressed-sync-active"
            else
                self:SendHelloReply(sender)
                replyDecision = "sent"
            end
            syncState.lastHelloReplyHash[cleanSenderReply] = currentHash
        else
            -- Reply suppressed because our data has not changed since we last
            -- told this peer. If the peer is behind us, this is the silent
            -- deadlock: they get no fresh HELLO, never see we are ahead, and
            -- never request, while our superset check below skips. Logged at
            -- DEBUG so it only surfaces during a deliberate sync capture.
            replyDecision = "suppressed-hash-unchanged"
            self:SyncDebug(
                "Suppressed HELLO reply to %s: hash unchanged since last reply "
                .. "(their tx=%d, our tx=%d)",
                cleanSenderReply, data.txCount or 0,
                gd and (#gd.transactions + #gd.moneyTransactions) or 0)
        end
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
            .. " - datasets identical (hash: " .. localDataHash
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
                .. " - likely superset (local=" .. localCount
                .. " > remote=" .. remoteCount .. ")")
            -- Correlate the skip with the reply gate above: if we are ahead AND
            -- the reply was suppressed-hash-unchanged AND no SYNC_REQUEST follows
            -- from this peer, the silent hash-gate deadlock is confirmed.
            self:SyncDebug(
                "Superset skip detail for %s: replyThisRound=%s",
                self:CanonicalPeerKey(sender), tostring(replyDecision))
            -- Behind peer + suppressed-hash-unchanged reply is the silent
            -- deadlock: we are ahead, our data is stable, so the hash gate
            -- stopped telling this peer we are ahead and they never request.
            -- Re-send the HELLO reply (throttled per peer) so their HandleHello
            -- re-evaluates and pulls. An isReply HELLO drives their shouldSync
            -- path, so this is a real nudge, not just discovery. Only fires for
            -- the hash-unchanged case (replyDecision "sent" already pinged them
            -- this round; "suppressed-sync-active" means we are mid-sync).
            if replyDecision == "suppressed-hash-unchanged" then
                local nudgeKey = self:CanonicalPeerKey(sender)
                local nudgeNow = GetServerTime()
                if nudgeNow - (syncState.lastSupersetNudge[nudgeKey] or 0)
                        >= SUPERSET_NUDGE_THROTTLE then
                    self:SendHelloReply(sender)
                    syncState.lastSupersetNudge[nudgeKey] = nudgeNow
                    self:AddAuditEntry("Nudged behind peer " .. nudgeKey
                        .. " to pull (superset, hash-gate bypass)")
                end
            end
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
        -- A peer who just told us they were busy is left alone until their
        -- cooldown runs out. Nothing holds a retry for us; their next HELLO
        -- brings the opportunity back.
        if self:IsPeerBusy(sender) then
            self:AddAuditEntry("Skipped sync from " .. sender
                .. " (busy cooldown)")
        elseif InCombatLockdown and InCombatLockdown() then
            -- Defer sync if in combat to avoid FPS impact. The opportunity
            -- is not stored; combat end re-advertises and the pairing comes
            -- back around through the usual HELLO exchange.
            syncState.helloAfterCombat = true
            self:AddAuditEntry("Deferred sync from " .. sender .. " - in combat")
        elseif isSyncPaused() then
            -- Combat and zone pauses outlive their triggers by a cooldown, so
            -- this arm covers the window where the lockdown check above is
            -- already false. It sits after that check so a HELLO arriving in
            -- combat still takes the defer arm and sets helloAfterCombat.
            self:AddAuditEntry("Skipped sync from " .. sender .. " ("
                .. (syncState.zonePaused and "zone" or "combat")
                .. " cooldown)")
        else
            -- Requested inline. The deferral this used to sit behind bought
            -- nothing BUSY does not already buy, and its callback re-checked
            -- five conditions that could each drop the request with nothing
            -- logged, which is invisible in a capture.
            self:AddAuditEntry("Sync triggered by " .. syncReason
                .. " - requesting from " .. sender)
            self:RequestSync(sender, guildData.syncState.lastSyncTimestamp or 0)
        end
    else
        -- Log why we didn't sync so stalls are diagnosable
        local reason
        if not shouldSync then
            reason = "datasets match or no sync needed (local=" .. localCount
                .. ", remote=" .. remoteCount .. ")"
        elseif syncState.receiving then
            -- Dropped rather than queued. They re-advertise on their own
            -- heartbeat, and we answer it once this session is done.
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

-- For peer identity, all sites below call GBL:CanonicalPeerKey (Core.lua):
-- bare for same-realm, realm-qualified for cross-realm (custom local-realm-
-- only strip; deliberately not Ambiguate("guild") which would over-strip in
-- connected-realm guilds). GBL:StripRealm is reserved for genuine bare-name
-- use cases (recentWhisperTargets chat-suppression, UI filter inputs).

--- Re-canonicalize peer-state keys in place across syncState.peers and
-- guildData.knownPeers. Idempotent. Used to clean up stale entries written
-- by an earlier code path (or by InitSync's seed loop running before the
-- roster cache was warm), so that current-canonical state reflects the
-- current CanonicalPeerKey output. Called by Core.lua's GUILD_ROSTER_UPDATE
-- handler after BuildRosterCache, and from InitSync's seed loop via the
-- inline rewrite there.
function GBL:ConsolidatePeerKeys()
    local guildData = self:GetGuildData()
    if not guildData then return end

    local function reKey(t)
        if type(t) ~= "table" then return end
        local rawKeys = {}
        for k in pairs(t) do rawKeys[#rawKeys+1] = k end
        for _, name in ipairs(rawKeys) do
            local info = t[name]
            if info then
                local clean = self:CanonicalPeerKey(name)
                if clean ~= name then
                    local existing = t[clean]
                    if existing then
                        if (info.lastSeen or 0) > (existing.lastSeen or 0) then
                            t[clean] = info
                        end
                    else
                        t[clean] = info
                    end
                    t[name] = nil
                end
            end
        end
    end

    reKey(syncState.peers)
    reKey(guildData.knownPeers)
end

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

--- Serialized length of a string once AceSerializer has escaped it.
-- Records cannot contain these characters, which is why estimateRecordBytes
-- gets away with a raw length. Guild names can: "Knights of the Round" costs
-- three extra bytes, and the envelope carries one on every chunk.
-- @param s string
-- @return number Length after escaping
local function escapedLength(s)
    s = tostring(s or "")
    local extra = 0
    for i = 1, #s do
        local b = s:byte(i)
        -- AceSerializer doubles space, control codes, ^ and ~
        if b == 32 or b < 32 or b == 94 or b == 126 then
            extra = extra + 1
        end
    end
    return #s + extra
end

--- Estimate the serialized byte size of one event count entry.
-- The same arithmetic as estimateRecordBytes, for a keyed nested table. The
-- eventCounts table's own wrapper belongs to the envelope, not to any entry, so
-- summing this over entries bounds the map without counting a wrapper per item.
-- @param baseHash string The entry key (a record id with its occurrence removed)
-- @param entry table { count=N, asOf=T }
-- @return number Estimated byte count
local function estimateEventCountBytes(baseHash, entry)
    local bytes = #tostring(baseHash) + 3    -- key + delimiters
    bytes = bytes + 6                        -- nested table wrapper
    for k, v in pairs(entry or {}) do
        bytes = bytes + #tostring(k) + 3
        bytes = bytes + #tostring(v) + 3
    end
    return bytes
end

--- Estimate the serialized byte size of a SYNC_DATA envelope carrying nothing.
-- Computed once per send and reserved from the chunk target, so what the packer
-- fills is the room a message actually has left. The field names are fixed and
-- so is the type string; the guild name is measured escaped.
--
-- chunk and totalChunks get a fixed five-digit allowance because the real
-- totalChunks is unknowable until packing has finished, and packing is what
-- this number governs. Five digits covers any sync this addon can produce.
-- @param guildName string
-- @return number Estimated byte count
local function estimateEnvelopeBytes(guildName)
    local bytes = 6  -- table wrapper overhead
    local function field(key, valueLength)
        bytes = bytes + #key + 3 + valueLength + 3
    end
    field("type", #"SYNC_DATA")
    field("chunk", 5)
    field("totalChunks", 5)
    field("protocolVersion", #tostring(PROTOCOL_VERSION))
    field("guild", escapedLength(guildName))
    -- The session cap's leftover count. It rides only the final chunk, but
    -- the allowance is permanent: the budget has to hold for every chunk,
    -- and the final one is not knowable while packing.
    field("remaining", 5)
    -- The three payload containers, each an empty table wrapper of its own.
    field("transactions", 6)
    field("moneyTransactions", 6)
    field("eventCounts", 6)
    return bytes
end

-- Every transaction type the addon records. A type outside this set is
-- transit damage, not a record from a newer version: adding a type would be a
-- compatibility break needing a floor raise, so it cannot arrive unannounced.
local VALID_RECORD_TYPES = {
    deposit = true, withdraw = true, move = true,
    repair = true, buyTab = true, depositSummary = true,
}

-- Fields whose type is known. Anything not named here passes through untouched:
-- that forward tolerance is what makes adding a field free, and a whitelist here
-- would turn every future field into a break. See #68.
local NUMERIC_RECORD_FIELDS = {
    "itemID", "count", "tab", "destTab", "classID", "subclassID",
    "amount", "timestamp",
}
local STRING_RECORD_FIELDS = { "type", "player", "id" }

--- Recompute an item record's classID and subclassID from its itemID.
--
-- 195 of the 223 corrupted records measured in DATA-MODEL.md section 8 lost
-- only subclassID, which is derivable from itemID through the same call
-- CreateTxRecord uses (src/Ledger.lua). Rejecting them would discard
-- recoverable data, so repair runs before validation rather than after.
--
-- @param record table Record being taken in, mutated in place
-- @return boolean true if anything was repaired
function GBL:RepairSyncRecordItemFields(record)
    if type(record.itemID) ~= "number" then return false end
    if type(record.classID) == "number" and type(record.subclassID) == "number" then
        return false
    end
    if not (C_Item and C_Item.GetItemInfoInstant) then return false end

    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(record.itemID)
    record.classID = classID or 0
    record.subclassID = subclassID or 0
    -- The category was derived from the fields we just replaced.
    record.category = self:CategorizeItem(record.classID, record.subclassID)
    return true
end

--- Check an incoming record's shape before anything reads its fields.
--
-- Runs first, not last. Two of these checks are unreachable from the bottom of
-- reconstructSyncRecord: a non-number timestamp is silently replaced by receipt
-- time (IsValidTimestamp tests the type), which files the record in the wrong
-- bucket forever, and a non-string id crashes the id:match calls outright.
--
-- @param record table Record received via sync
-- @return boolean ok
-- @return string|nil field The field that failed, for the reject counter
local function validateSyncRecord(record)
    for _, field in ipairs(STRING_RECORD_FIELDS) do
        if record[field] ~= nil and type(record[field]) ~= "string" then
            return false, field
        end
    end
    for _, field in ipairs(NUMERIC_RECORD_FIELDS) do
        if record[field] ~= nil and type(record[field]) ~= "number" then
            return false, field
        end
    end

    if not record.type or record.type == "" then return false, "type" end
    if not VALID_RECORD_TYPES[record.type] then return false, "type" end
    if not record.player or record.player == "" then return false, "player" end

    -- Exactly one of itemID / amount, the discriminator buildPrefix already
    -- uses. A record with neither takes the money branch and collides with
    -- every other such record from the same player, type and hour; a record
    -- with both is not a shape this addon produces.
    local hasItem = record.itemID ~= nil
    local hasAmount = record.amount ~= nil
    if hasItem == hasAmount then return false, "itemID/amount" end

    return true
end

--- Restore fields stripped by stripForSync on received records.
-- Called on each record before StoreTx/StoreMoneyTx during sync receive.
-- Must be resilient to any combination of missing fields — the sender
-- may be running any past or future addon version.
-- Guarantees after return: record.id, record.timestamp, record.scanTime,
-- record.scannedBy are always non-nil.
-- @param record table Transaction record received via sync
-- @param sender string Name of the peer who sent this record
-- @return boolean accepted
-- @return string|nil field The field that failed validation, when rejected
local function reconstructSyncRecord(record, sender)
    -- 0. Repair, then validate, before anything below reads a field.
    GBL:RepairSyncRecordItemFields(record)
    local valid, badField = validateSyncRecord(record)
    if not valid then return false, badField end

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

    -- 6. Ensure player name is realm-qualified
    record.player = GBL:ResolvePlayerName(record.player)
    return true
end

------------------------------------------------------------------------
-- Wire-contract test seams
--
-- The record codec is two file-local functions, so nothing outside this file
-- could reach it and the wire format went untested for the project's whole
-- life (docs/DATA-MODEL.md section 9). These three wrappers exist so
-- spec/wire_contract_spec.lua can pin the format against the real
-- AceSerializer instead of the pass-through mock. No production caller.
------------------------------------------------------------------------

--- @see stripForSync
function GBL:_StripForSync(record)
    return stripForSync(record)
end

--- @see reconstructSyncRecord
function GBL:_ReconstructSyncRecord(record, sender)
    return reconstructSyncRecord(record, sender)
end

--- @see estimateRecordBytes
function GBL:_EstimateRecordBytes(record)
    return estimateRecordBytes(record)
end

--- @see estimateEventCountBytes
function GBL:_EstimateEventCountBytes(baseHash, entry)
    return estimateEventCountBytes(baseHash, entry)
end

--- @see estimateEnvelopeBytes
function GBL:_EstimateEnvelopeBytes(guildName)
    return estimateEnvelopeBytes(guildName)
end

------------------------------------------------------------------------
-- Sync request / response
------------------------------------------------------------------------

--- Build and whisper one SYNC_REQUEST.
-- Split out of RequestSync so the retry that fires when nothing comes back can
-- put the identical payload on the wire without re-entering the receive-state
-- setup, and so only one place knows the request's shape.
--
-- The manifest is what keeps this message small. It used to carry one entry per
-- 6-hour bucket over the guild's whole history, which crossed AceComm's whisper
-- reliability ceiling at around 230 buckets and then kept growing, so requests
-- from a peer with a long history simply stopped arriving.
-- @param target string Target player name
-- @param sinceTimestamp number Only request transactions after this time
-- @return boolean true when the whisper was handed to AceComm
function GBL:SendSyncRequestTo(target, sinceTimestamp)
    local guildData = self:GetGuildData()
    local bucketHashes = guildData and self:ComputeBucketHashes(guildData) or nil
    -- nil in, nil out: a request with no bucketHashes key at all is what puts
    -- the serving side onto its sinceTimestamp fallback.
    local detail, spans = self:BuildRequestManifest(bucketHashes)

    local msg = self:Serialize({
        type = "SYNC_REQUEST",
        sinceTimestamp = sinceTimestamp,
        bucketHashes = detail,
        spans = spans,
        -- The serving side gates on these: a request reaching HandleSyncRequest
        -- never passed through HandleHello, so this is the only version signal
        -- the holder gets before handing over records.
        version = self.version,
        minSyncVersion = MIN_SYNC_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    msg = compressMessage(msg)

    local msgBytes = #msg
    if msgBytes > WHISPER_SAFE_BYTES then
        -- The manifest is bounded, so this should never fire. If it does, the
        -- request is back to being dropped on lossy routes with nothing to say
        -- so, which is the failure this whole shape exists to end.
        self:SyncWarn("SYNC_REQUEST to %s is %d B (> %d safe); the manifest "
            .. "should have bounded this", target, msgBytes, WHISPER_SAFE_BYTES)
    end

    if not self:SendSyncWhisper(PREFIX, msg, target) then return false end

    local detailCount = 0
    if detail then
        for _ in pairs(detail) do detailCount = detailCount + 1 end
    end
    self:AddAuditEntry("Requesting sync from " .. target
        .. " (since " .. sinceTimestamp
        .. ", " .. detailCount .. " detail bucket(s), "
        .. (spans and #spans or 0) .. " span(s)"
        .. ", " .. msgBytes .. " bytes)")
    return true
end

--- Send a SYNC_REQUEST to a specific peer.
-- @param target string Target player name
-- @param sinceTimestamp number Only request transactions after this time
function GBL:RequestSync(target, sinceTimestamp)
    if syncState.receiving then return end

    -- Not every caller has passed HELLO's gate: the bidirectional check
    -- after a send reaches here on its own, and so does a manual pull. This
    -- is one of the three doors the version floor is checked at, and the
    -- only one with no HELLO behind it.
    -- Only refuse on a peer we actually know: an entry with no version yet
    -- (created by non-HELLO traffic) is left to the HELLO path to resolve.
    local peerInfo = syncState.peers[self:CanonicalPeerKey(target)]
    if peerInfo and peerInfo.version then
        local compatible, reason =
            self:IsVersionCompatible(peerInfo.version, peerInfo.minSyncVersion)
        if not compatible then
            self:SyncWarn("Not requesting. " .. self:DescribeVersionRefusal(
                self:CanonicalPeerKey(target), reason,
                peerInfo.version, peerInfo.minSyncVersion))
            return
        end
    end

    syncState.receiving = true
    syncState.receiveSource = self:CanonicalPeerKey(target)
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveDuped = 0
    syncState.receiveItemStored = 0
    syncState.receiveItemDuped = 0
    syncState.receiveMoneyStored = 0
    syncState.receiveMoneyDuped = 0
    syncState.receiveItemRejected = 0
    syncState.receiveMoneyRejected = 0
    syncState.receiveRejectFields = {}
    syncState.receiveRemaining = nil
    syncState.receiveNormalized = 0
    syncState.receiveItemRejected = 0
    syncState.receiveMoneyRejected = 0
    syncState.receiveRejectFields = {}
    syncState.receiveExpected = 0
    syncState.receiveStartTime = GetServerTime()

    sinceTimestamp = sinceTimestamp or 0

    if not self:SendSyncRequestTo(target, sinceTimestamp) then
        self:SyncError("Target offline, aborting sync request to " .. target)
        self:FinishReceiving(target)
        return
    end
    self:SendMessage("GBL_SYNC_STARTED", target)

    -- Request timeout — NACK with backoff, then abort after MAX_NACK_RETRIES
    syncState.receiveNackCount = 0
    self:ScheduleReceiveTimeout()
end

--- Handle an incoming SYNC_REQUEST — gather and send matching transactions.
-- @param sender string Requester name
-- @param data table Deserialized request payload
function GBL:HandleSyncRequest(sender, data)
    -- The serving half of the version gate. A request can arrive without ever
    -- passing through HandleHello (RequestSync whispers directly), so refusing
    -- only there would let an incompatible peer help itself to our records.
    -- Silence rather than BUSY: BUSY means "try again shortly", which would
    -- keep them retrying for as long as they stay on the old version.
    local compatible, reason = self:IsVersionCompatible(data.version, data.minSyncVersion)
    if not compatible then
        self:SyncWarn("Ignoring SYNC_REQUEST. " .. self:DescribeVersionRefusal(
            self:CanonicalPeerKey(sender), reason, data.version, data.minSyncVersion))
        return
    end

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
    -- Computed on both paths. The bucket diff below needs it, and so does the
    -- per-target tranche memory that keeps a capped session rotating, which
    -- would otherwise serve the same slice forever to a peer whose request
    -- carried no hashes.
    local localBuckets = self:ComputeBucketHashes(guildData)

    if data.bucketHashes then
        -- Bucket-filtered sync: only send records from buckets that differ.
        -- Since the hierarchical manifest, a request describes its recent
        -- window bucket by bucket and everything older as a handful of coarse
        -- spans, so a bucket is judged by whichever of the two covers it.
        diffDays = {}
        local totalLocalDays = 0
        local totalRemoteDays = 0
        local matchingDays = 0

        for _ in pairs(localBuckets) do totalLocalDays = totalLocalDays + 1 end
        for _ in pairs(data.bucketHashes) do totalRemoteDays = totalRemoteDays + 1 end

        -- Fold our own buckets over each declared span once, up front. A span
        -- that matches clears every bucket inside it in one comparison; a span
        -- that differs offers all of them, because the fold says something in
        -- the range moved but not what (drilling down would cost a round trip,
        -- and the session cap already bounds what one session hands over).
        local spans = {}
        local differingSpans = 0
        if type(data.spans) == "table" then
            for _, span in ipairs(data.spans) do
                if type(span) == "table" and type(span.s) == "number"
                    and type(span.e) == "number" and type(span.h) == "number" then
                    local differs =
                        self:FoldBucketRange(localBuckets, span.s, span.e) ~= span.h
                    if differs then differingSpans = differingSpans + 1 end
                    spans[#spans + 1] = { s = span.s, e = span.e, differs = differs }
                end
            end
        end

        for dayKey, localHash in pairs(localBuckets) do
            local covering
            for i = 1, #spans do
                if dayKey >= spans[i].s and dayKey <= spans[i].e then
                    covering = spans[i]
                    break
                end
            end

            if covering then
                if covering.differs then
                    diffDays[dayKey] = true
                else
                    matchingDays = matchingDays + 1
                end
            elseif localHash ~= (data.bucketHashes[dayKey] or 0) then
                -- Not covered by any span, so it is either in the requester's
                -- detail window or older than anything it declared. Both cases
                -- take the comparison this line has always made: a bucket the
                -- requester never mentioned reads as hash 0 and is offered.
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

        local spanNote = ""
        if #spans > 0 then
            spanNote = ", " .. #spans .. " span(s) (" .. differingSpans .. " differing)"
        end
        self:AddAuditEntry("Bucket filter: " .. totalLocalDays .. " local bucket(s), "
            .. totalRemoteDays .. " remote detail bucket(s)" .. spanNote .. ", "
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
        self:AddAuditEntry("No bucket hashes in request - falling back to sinceTimestamp="
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

    -- Send the most recent buckets first. A far-behind peer needs current
    -- activity, which lives in the newest buckets; routing those into the
    -- early chunks means an aborted sync (combat/zone/disconnect/ACK timeout)
    -- still delivers useful records instead of front-loading old history the
    -- peer already has. The receiver dedups by record id, so merge order never
    -- changes the stored result (see the order-independence spec).
    self:SortSendListNewestFirst(txToSend)
    self:SortSendListNewestFirst(moneyToSend)
    if #txToSend > 0 or #moneyToSend > 0 then
        local newestRec = txToSend[1] or moneyToSend[1]
        local oldestRec = txToSend[#txToSend] or moneyToSend[#moneyToSend]
        local newestTs = self:BucketKeyForRecord(newestRec) * 6 * 3600
        local oldestTs = self:BucketKeyForRecord(oldestRec) * 6 * 3600
        self:AddAuditEntry("Send order newest-first: "
            .. date("%Y-%m-%d %H:00", newestTs) .. " back to "
            .. date("%Y-%m-%d %H:00", oldestTs))
    end

    -- Cap the session to whole buckets. The peer gets the rest next time they
    -- ask, and both of us are back in the gossip pool in minutes rather than
    -- hours. Buckets already sent to this peer whose local hash has not moved
    -- since sort last, so a receiver-superset diff cannot pin us to the same
    -- tranche forever (see _SelectSessionBuckets).
    local sendTarget = self:CanonicalPeerKey(sender)
    local demoteSet
    local lastTranche = syncState.capLastTranche[sendTarget]
    if lastTranche then
        demoteSet = {}
        for key, hashWhenSent in pairs(lastTranche) do
            if localBuckets[key] == hashWhenSent then demoteSet[key] = true end
        end
    end

    local sentBuckets, deferredBuckets
    txToSend, moneyToSend, sentBuckets, deferredBuckets =
        self:_SelectSessionBuckets(txToSend, moneyToSend, SESSION_RECORD_CAP, demoteSet)

    local tranche = {}
    for key in pairs(sentBuckets) do tranche[key] = localBuckets[key] end
    syncState.capLastTranche[sendTarget] = tranche

    -- Collect eventCounts for the buckets we're sending. On the bucket path
    -- that is the capped set, so counts ride only with the records they
    -- describe. On the fallback path there are no bucket keys to filter by,
    -- so it stays nil (send all) and the carrier-chunk path from #92 is
    -- unchanged.
    local countBuckets = diffDays and sentBuckets or nil
    local sendEventCounts = self:CollectEventCountsForBuckets(guildData, countBuckets)

    -- Prepare and send chunks
    local chunks = self:PrepareChunks(txToSend, moneyToSend, sendEventCounts)

    if #chunks == 0 then
        -- Nothing to send — send an empty chunk so receiver finishes cleanly.
        -- Reaching here means no records AND no event counts: anything with
        -- event counts to share gets a carrier chunk from PrepareChunks and
        -- goes out through SendNextChunk instead.
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
        self:SendSyncWhisper(PREFIX, msg, sender)
        self:AddAuditEntry("Sent empty sync to " .. sender)
        return
    end

    syncState.sending = true
    syncState.sendTarget = self:CanonicalPeerKey(sender)
    syncState.sendChunks = chunks
    syncState.sendChunkIndex = 0
    syncState.sendStartTime = GetServerTime()
    syncState.sendTotalRecords = #txToSend + #moneyToSend
    syncState.sendRemainingBuckets = deferredBuckets or 0
    self:StartFpsMonitor()

    local totalTx = #txToSend + #moneyToSend
    local capNote = ""
    if (deferredBuckets or 0) > 0 then
        capNote = ", capped: " .. deferredBuckets .. " bucket(s) deferred"
    end
    self:AddAuditEntry("Sending " .. totalTx
        .. " tx to " .. sender .. " in " .. #chunks .. " chunk(s)" .. capNote)

    ctlDeferTotal = 0
    -- Per-session drain instrumentation reset. timersPending is deliberately
    -- NOT reset: it tracks real scheduled timers, and a stale timer from a
    -- prior session still decrements it in its callback. A stale chain that
    -- lives into this session counts toward overlaps on purpose: it IS a
    -- concurrent chain issuing sends here, whichever session spawned it.
    ctlDrain.overlapTotal = 0
    ctlDrain.maxStall = 0
    ctlDrain.episodeStart = nil
    ctlDrain.episodeDefers = 0
    ctlDrain.overlapCount = 0
    ctlDrain.minAvail = nil
    ctlDrain.minAvailAt = nil
    ctlDrain.episodePaused = nil
    -- Session boundary marker: the samples ring accumulates across sessions
    -- (only the test reset clears it), so /run inspection needs a separator.
    ctlDrain.samples[#ctlDrain.samples + 1] =
        { t = GetTime(), marker = "session", target = syncState.sendTarget }
    while #ctlDrain.samples > ctlDrain.sampleCap do
        table.remove(ctlDrain.samples, 1)
    end
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

--- Cut a send list down to one session's worth of whole buckets.
--
-- Whole buckets, never a partial one. A half-sent bucket hashes differently
-- from either side's copy, so it matches nobody and comes back entire on the
-- next request; a complete bucket converges and drops out of the diff for
-- good. That is the difference between a backfill that makes progress across
-- sessions and one that re-sends the same records forever.
--
-- Newest first, because a peer that is far behind needs current activity more
-- than old history, except for buckets in demoteSet, which sort behind
-- everything else. That set is the deadlock fix: when the buckets that differ
-- are ones the receiver already holds from a third peer, an unqualified
-- newest-first cap re-sends the same all-duplicate tranche every session and
-- older differing buckets starve. Buckets we already sent to this peer whose
-- contents have not changed since are exactly the ones to try last.
--
-- @param txList table Item records, already newest-first
-- @param moneyList table Money records, already newest-first
-- @param cap number Target record count before bucket rounding
-- @param demoteSet table|nil bucketKey -> true, buckets to try last
-- @return table filtered item records
-- @return table filtered money records
-- @return table bucketKey -> true for the buckets this session carries
-- @return number how many buckets were held back
function GBL:_SelectSessionBuckets(txList, moneyList, cap, demoteSet)
    local counts = {}
    local order = {}
    local function tally(list)
        for _, rec in ipairs(list) do
            local key = self:BucketKeyForRecord(rec)
            if not counts[key] then
                counts[key] = 0
                order[#order + 1] = key
            end
            counts[key] = counts[key] + 1
        end
    end
    tally(txList)
    tally(moneyList)

    if #order == 0 then return {}, {}, {}, 0 end

    table.sort(order, function(a, b)
        local aDemoted = (demoteSet and demoteSet[a]) and 1 or 0
        local bDemoted = (demoteSet and demoteSet[b]) and 1 or 0
        if aDemoted ~= bDemoted then return aDemoted < bDemoted end
        return a > b
    end)

    -- A bucket larger than the whole cap still goes out whole. Nothing here
    -- special-cases it: taken is zero on the first pass, so the first bucket
    -- is selected before the cap can refuse anything, and refusing it would
    -- mean never sending that bucket at all.
    local selected = {}
    local taken = 0
    local remaining = 0
    for _, key in ipairs(order) do
        if taken < cap then
            selected[key] = true
            taken = taken + counts[key]
        else
            remaining = remaining + 1
        end
    end

    local function filter(list)
        local out = {}
        for _, rec in ipairs(list) do
            if selected[self:BucketKeyForRecord(rec)] then out[#out + 1] = rec end
        end
        return out
    end

    return filter(txList), filter(moneyList), selected, remaining
end

--- Sort a sync send list so the most recent 6-hour buckets come first.
-- PrepareChunks packs records into chunks in list order, so a newest-first
-- list puts current activity in the early chunks. A peer that is far behind
-- needs those recent records first; if the sync aborts before the tail it has
-- still made progress instead of resending old history the peer already has.
-- Keyed on BucketKeyForRecord (the same basis the bucket filter uses), with
-- the record id as a deterministic tiebreaker so the order is total. Sorts in
-- place. Order is irrelevant to correctness: the receiver dedups by id, so this
-- only changes which records arrive first, never the merged result.
-- @param list table Array of stripped sync records
-- @return table The same list, sorted newest-bucket-first
function GBL:SortSendListNewestFirst(list)
    if not list or #list < 2 then return list end
    local bucketOf = {}
    for i = 1, #list do
        bucketOf[list[i]] = self:BucketKeyForRecord(list[i])
    end
    table.sort(list, function(a, b)
        local ka, kb = bucketOf[a], bucketOf[b]
        if ka ~= kb then return ka > kb end
        return (a.id or "") > (b.id or "")
    end)
    return list
end

--- Split records and event counts into chunks that fit one wire fragment.
-- The budget governs the whole serialized message, so the envelope is reserved
-- up front and records and event count entries are filled against what is left
-- (#92; before this, the budget weighed records only and the rider rode free).
-- MAX_RECORDS_PER_CHUNK remains a hard cap on top of the byte target.
--
-- Every chunk takes at least one item even when that item overshoots the budget
-- on its own, which a long cross-realm id can. Without that the packer would
-- seal empty chunks forever; with it the overshoot is visible instead, as a
-- chunk that exceeds one fragment in the FinishSending summary.
-- @param transactions table Array of stripped item transaction records
-- @param moneyTransactions table Array of stripped money transaction records
-- @param eventCounts table|nil { [baseHash] = { count=N, asOf=T } } to spread
-- @return table Array of chunks, each with .transactions, .moneyTransactions
--               and an optional .eventCounts
function GBL:PrepareChunks(transactions, moneyTransactions, eventCounts)
    local budget = CHUNK_TARGET_BYTES - estimateEnvelopeBytes(self:GetGuildName())

    local chunks = {}
    local chunkBytes = {}    -- running estimate per sealed chunk, same indices
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
            chunkBytes[#chunks] = estimatedBytes
        end
        currentTx = {}
        currentMoney = {}
        count = 0
        estimatedBytes = 0
    end

    for _, tx in ipairs(transactions) do
        local recBytes = estimateRecordBytes(tx)
        if count > 0 and (estimatedBytes + recBytes > budget
                          or count >= MAX_RECORDS_PER_CHUNK) then
            sealChunk()
        end
        currentTx[#currentTx + 1] = tx
        count = count + 1
        estimatedBytes = estimatedBytes + recBytes
    end

    for _, tx in ipairs(moneyTransactions) do
        local recBytes = estimateRecordBytes(tx)
        if count > 0 and (estimatedBytes + recBytes > budget
                          or count >= MAX_RECORDS_PER_CHUNK) then
            sealChunk()
        end
        currentMoney[#currentMoney + 1] = tx
        count = count + 1
        estimatedBytes = estimatedBytes + recBytes
    end

    sealChunk()

    -- Top each chunk up with event count entries while it stays inside the
    -- budget, opening carrier chunks once the record chunks are full. The
    -- cursor only moves forward: an entry never revisits a chunk it has already
    -- passed, so packing stays linear in the number of entries.
    if eventCounts then
        local idx = 1
        for baseHash, entry in pairs(eventCounts) do
            local entryBytes = estimateEventCountBytes(baseHash, entry)
            while true do
                if idx > #chunks then
                    chunks[idx] = { transactions = {}, moneyTransactions = {} }
                    chunkBytes[idx] = 0
                end
                -- A carrier chunk that is still completely empty takes the entry
                -- whatever it weighs. That is the minimum-progress guarantee: it
                -- is the only branch that can place an oversized entry, and it
                -- is why the cursor cannot advance forever.
                if chunkBytes[idx] + entryBytes <= budget or chunkBytes[idx] == 0 then
                    local chunk = chunks[idx]
                    chunk.eventCounts = chunk.eventCounts or {}
                    chunk.eventCounts[baseHash] = entry
                    chunkBytes[idx] = chunkBytes[idx] + entryBytes
                    break
                end
                idx = idx + 1
            end
        end
    end

    return chunks
end

--- Send the next chunk in the queue. Aborts if no more chunks remain.
function GBL:SendNextChunk()
    if not syncState.sending then return end

    -- Zone/combat protection — defer until safe
    if isSyncPaused() then
        -- An open drain episode spans this pause: its stall figure will
        -- include zone/combat dead time, not just CTL starvation. Flag it so
        -- the summary line says so and the capture reader can discount it.
        if ctlDrain.episodeStart then
            ctlDrain.episodePaused = true
        end
        self:AddAuditEntry("SendNextChunk deferred - zone/combat transition in progress")
        return
    end

    -- ChatThrottleLib awareness — defer if other addons are using bandwidth
    if not self:HasSyncBandwidth() then
        ctlDeferTotal = ctlDeferTotal + 1

        -- Drain instrumentation (measurement only; the deferral behavior
        -- below is unchanged).
        local CTL = _G.ChatThrottleLib
        local availNow = (CTL and CTL.avail) or -1
        local threshold = math.max(CTL_BANDWIDTH_MIN, syncState.lastChunkBytes or 0)
        local nowT = GetTime()
        local samples = ctlDrain.samples
        samples[#samples + 1] = { t = nowT, avail = availNow, threshold = threshold }
        while #samples > ctlDrain.sampleCap do
            table.remove(samples, 1)
        end
        if not ctlDrain.episodeStart then
            ctlDrain.episodeStart = nowT
            ctlDrain.episodeDefers = 0
            ctlDrain.overlapCount = 0
            ctlDrain.minAvail = nil
            ctlDrain.minAvailAt = nil
        end
        ctlDrain.episodeDefers = ctlDrain.episodeDefers + 1
        if availNow >= 0 and (not ctlDrain.minAvail or availNow < ctlDrain.minAvail) then
            ctlDrain.minAvail = availNow
            ctlDrain.minAvailAt = nowT
        end
        if ctlDrain.timersPending > 0 then
            ctlDrain.overlapCount = ctlDrain.overlapCount + 1
            ctlDrain.overlapTotal = ctlDrain.overlapTotal + 1
        end
        ctlDrain.timersPending = ctlDrain.timersPending + 1

        -- Rate limit: first 10 verbose, then every 20th
        if ctlDeferTotal <= 10 or ctlDeferTotal % 20 == 0 then
            local availStr = availNow >= 0 and string.format("%.0f", availNow) or "?"
            local suffix = ""
            if ctlDeferTotal > 10 then
                suffix = ", " .. ctlDeferTotal .. " total"
            end
            self:AddAuditEntry("CTL low (avail=" .. availStr
                .. ", need=" .. threshold
                .. ", #" .. ctlDeferTotal
                .. ", t=" .. string.format("%.3f", nowT)
                .. suffix
                .. ") - deferring " .. CTL_BACKOFF_DELAY .. "s")
        end
        C_Timer.After(CTL_BACKOFF_DELAY, function()
            ctlDrain.timersPending = math.max(0, ctlDrain.timersPending - 1)
            self:SendNextChunk()
        end)
        return
    end

    -- CTL drain episode ended: bandwidth is back. Summarize so a capture can
    -- attribute the stall (overlaps => timer-chain multiplication; pinned
    -- min-avail with slow recovery => external contention). An episode still
    -- open when the send session ends is not summarized; the next session's
    -- init resets it.
    if ctlDrain.episodeStart then
        local nowT = GetTime()
        local stall = nowT - ctlDrain.episodeStart
        local CTL = _G.ChatThrottleLib
        local availNow = (CTL and CTL.avail) or -1
        local rateStr = "?"
        if ctlDrain.minAvail and ctlDrain.minAvailAt and availNow >= 0 then
            local dt = nowT - ctlDrain.minAvailAt
            if dt > 0.001 then
                rateStr = string.format("%.0f", (availNow - ctlDrain.minAvail) / dt)
            end
        end
        self:SyncInfo("CTL recovered: %d deferrals, %d overlapped, stall %.1fs,"
                .. " min avail %s, recovery %s B/s%s",
            ctlDrain.episodeDefers, ctlDrain.overlapCount, stall,
            ctlDrain.minAvail and string.format("%.0f", ctlDrain.minAvail) or "?",
            rateStr,
            ctlDrain.episodePaused and " (zone/combat pause overlapped; stall includes dead time)" or "")
        if stall > ctlDrain.maxStall then
            ctlDrain.maxStall = stall
        end
        ctlDrain.episodeStart = nil
        ctlDrain.episodeDefers = 0
        ctlDrain.overlapCount = 0
        ctlDrain.minAvail = nil
        ctlDrain.minAvailAt = nil
        ctlDrain.episodePaused = nil
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

    -- Attached at serialize time rather than baked into the chunk so a NACK
    -- or timeout retransmit of the final chunk still carries it. Only on the
    -- final chunk, and only when something is actually left: an uncapped
    -- session puts nothing new on the wire, which is what keeps the builder
    -- key-parity check in the wire contract green.
    local remaining
    if idx == #syncState.sendChunks and (syncState.sendRemainingBuckets or 0) > 0 then
        remaining = syncState.sendRemainingBuckets
    end

    local serialized = self:Serialize({
        type = "SYNC_DATA",
        chunk = idx,
        totalChunks = #syncState.sendChunks,
        transactions = chunk.transactions,
        moneyTransactions = chunk.moneyTransactions,
        eventCounts = chunk.eventCounts,
        remaining = remaining,
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
        .. " (" .. chunkRecords .. " records, " .. rawLen .. "->" .. msgLen .. " bytes"
        .. ", " .. math.floor((1 - msgLen / math.max(rawLen, 1)) * 100) .. "% compressed"
        .. ctlAvailAtSend .. gapStr .. ")"
    -- Chat: every chunk; audit trail: 1st, every 10th, and last
    self:AddAuditEntry(chunkMsg, true)
    if idx == 1 or idx == total or idx % 10 == 0 then
        self:AddAuditEntry(chunkMsg)
    end

    if msgLen > WHISPER_SAFE_BYTES then
        self:Print("|cffff0000Sync WARNING:|r chunk " .. idx .. " is " .. msgLen
            .. "b (>" .. WHISPER_SAFE_BYTES .. "), may be dropped!")
        self:SyncWarn("chunk " .. idx .. " is " .. msgLen
            .. " bytes (>" .. WHISPER_SAFE_BYTES
            .. "), may be silently dropped by AceComm WHISPER")
    end

    -- Hard timeout safety net — fires if AceComm callback never completes.
    -- Use C_Timer.NewTicker(n, cb, 1) for a cancellable one-shot timer;
    -- C_Timer.After returns nil in WoW so it can't be cancelled or tracked.
    if syncState.sendHardTimer then
        syncState.sendHardTimer:Cancel()
    end
    syncState.sendHardTimer = C_Timer.NewTicker(120, function()
        if syncState.sending then
            self:SyncError("Send hard timeout (120s), AceComm never finished, aborting")
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
                    self:SyncWarn("ACK timeout, retrying chunk " .. retryChunk
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
                    self:SyncError("ACK timeout from "
                        .. (syncState.sendTarget or "unknown")
                        .. " after " .. (MAX_RETRIES + 1) .. " attempts, aborting")
                    self:FinishSending()
                end
            end, 1)
        end) then
        self:SyncError("Target " .. (syncState.sendTarget or "?")
            .. " went offline, aborting send")
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
        .. " - " .. sent .. "/" .. total .. " chunks"
        .. ", " .. syncState.sendTotalRecords .. " records, " .. elapsed .. "s")

    -- Close a drain episode that is still open, BEFORE the stats line reads
    -- maxStall. SendNextChunk's recovery block only fires when bandwidth
    -- returns, so a send that aborts mid-stall (in production the 120s
    -- sendHardTimer at ScheduleSendTimeout) leaves the episode open and its
    -- stall unrecorded. That episode is the longest of the session by
    -- definition, because it is the one that ended it, so dropping it made
    -- "longest stall" read 0.0s on exactly the sessions that stalled to death.
    -- Tagged distinctly from "CTL recovered" so a capture can tell a truncated
    -- episode (still starved, duration is a lower bound) from a recovered one.
    if ctlDrain.episodeStart then
        local openStall = GetTime() - ctlDrain.episodeStart
        if openStall > ctlDrain.maxStall then
            ctlDrain.maxStall = openStall
        end
        self:SyncInfo("CTL still starved at send end: %d deferrals, %d overlapped,"
                .. " stall %.1fs and counting, min avail %s%s",
            ctlDrain.episodeDefers, ctlDrain.overlapCount, openStall,
            ctlDrain.minAvail and string.format("%.0f", ctlDrain.minAvail) or "?",
            ctlDrain.episodePaused
                and " (zone/combat pause overlapped; stall includes dead time)" or "")
        ctlDrain.episodeStart = nil
        ctlDrain.episodeDefers = 0
        ctlDrain.overlapCount = 0
        ctlDrain.minAvail = nil
        ctlDrain.minAvailAt = nil
        ctlDrain.episodePaused = nil
    end

    -- Keep the "Sync stats: " and " CTL deferrals" tokens verbatim; captures
    -- and downstream parsing key on them.
    self:AddAuditEntry("Sync stats: " .. ctlDeferTotal .. " CTL deferrals"
        .. ", " .. ctlDrain.overlapTotal .. " overlapped timers"
        .. ", longest stall " .. string.format("%.1f", ctlDrain.maxStall) .. "s"
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
    local wireToAcks = {}
    local overSized = 0

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
            -- The one-fragment invariant, measured rather than assumed. #92
            -- sized the packer for the worst compression ratio ever recorded,
            -- but every one of those ratios was measured on a message three
            -- times this size, and LibDeflate does worse on smaller inputs. A
            -- non-zero count here is that assumption failing.
            if o.bytes > 255 then
                overSized = overSized + 1
            end
        end
        if o.ratio and o.ratio > 0 then
            table.insert(ratios, o.ratio)
        end
        if o.outcome == "ok" and o.wireToAck and o.wireToAck > 0 then
            table.insert(wireToAcks, o.wireToAck)
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
        .. ", chunkFail=" .. chunkFail .. ", p_frag=" .. pFragStr)
    self:AddAuditEntry("Compression for " .. target .. ": " .. ratioSummary
        .. ", " .. overSized .. " chunk(s) over 1 fragment")

    -- Wire-to-ACK has been recorded per chunk since v0.28.7 and never
    -- aggregated. It is what says whether ACK_TIMEOUT has headroom: the
    -- timeout is only sane while its max sits well below it.
    local latencySummary = "n/a"
    if #wireToAcks > 0 then
        table.sort(wireToAcks)
        latencySummary = string.format("%.2fs / %.2fs / %.2fs (min/med/max)",
            wireToAcks[1], wireToAcks[math.floor(#wireToAcks / 2) + 1],
            wireToAcks[#wireToAcks])
    end
    self:AddAuditEntry("Wire-to-ACK for " .. target .. ": " .. latencySummary
        .. ", timeout " .. ACK_TIMEOUT .. "s")

    syncState.sending = false
    syncState.sendTarget = nil
    syncState.sendChunks = {}
    syncState.sendChunkIndex = 0
    syncState.sendRetryCount = 0
    syncState.sendStartTime = 0
    syncState.sendTotalRecords = 0
    syncState.sendRemainingBuckets = 0
    syncState.sendChunkSentAt = 0
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
    local cleanTarget = self:CanonicalPeerKey(target)
    if self.db.profile.sync.autoSync then
        C_Timer.After(0.5, function()
            if syncState.receiving then return end
            if isSyncPaused() then return end
            if not self.db.profile.sync.enabled then return end
            if InCombatLockdown and InCombatLockdown() then return end

            local peerInfo = syncState.peers[cleanTarget]
            if not peerInfo or not peerInfo.dataHash then
                -- Nothing to compare against. We are free either way, and
                -- the next HELLO from anyone brings the next opportunity.
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
                    self:AddAuditEntry("Bidirectional check: skipped - likely superset (local="
                        .. localCount .. " > remote=" .. remoteTxCount .. ")")
                    -- Symmetric with the HandleHello superset re-nudge (v0.32.12):
                    -- we are ahead and skipping, so a behind peer past the hash-gate
                    -- HELLO-reply suppression gets no further signal and can starve
                    -- (the pure-skip gap the v0.28.x amplifier note flagged at this
                    -- site). Re-send the HELLO reply, throttled per peer through the
                    -- same lastSupersetNudge map the HandleHello nudge uses so the two
                    -- sites cannot double-nudge within one window. SendHelloReply is
                    -- an isReply HELLO, which drives the peer's shouldSync path, so it
                    -- is a real pull trigger rather than mere discovery.
                    local nudgeNow = GetServerTime()
                    if nudgeNow - (syncState.lastSupersetNudge[cleanTarget] or 0)
                            >= SUPERSET_NUDGE_THROTTLE then
                        self:SendHelloReply(cleanTarget)
                        syncState.lastSupersetNudge[cleanTarget] = nudgeNow
                        self:AddAuditEntry("Nudged behind peer " .. cleanTarget
                            .. " to pull (superset, bidirectional hash-gate bypass)")
                    end
                elseif self:IsPeerBusy(cleanTarget) then
                    self:AddAuditEntry("Bidirectional check: skipped "
                        .. cleanTarget .. " - busy cooldown")
                else
                    self:AddAuditEntry("Bidirectional check: hashes still differ with "
                        .. cleanTarget .. " - requesting sync")
                    local since = gd.syncState.lastSyncTimestamp or 0
                    self:RequestSync(cleanTarget, since)
                end
            else
                self:AddAuditEntry("Bidirectional check: hashes match with "
                    .. cleanTarget .. " - no sync needed")
            end
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
        syncState.receiveSource = self:CanonicalPeerKey(sender)
        syncState.receiveGot = 0
        syncState.receiveStored = 0
        if data.chunk and data.chunk > 1 then
            self:AddAuditEntry("Auto-bootstrap at chunk " .. data.chunk
                .. " from " .. sender
                .. " (prior abort signal likely missed)")
        end
    elseif self:CanonicalPeerKey(sender) ~= self:CanonicalPeerKey(syncState.receiveSource) then
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
    local itemRejected, moneyRejected = 0, 0
    local normalized = 0
    local chunkTotal = #(data.transactions or {}) + #(data.moneyTransactions or {})

    -- Which field failed, counted per chunk so the summary can name the damage
    -- shape without a log line per record.
    syncState.receiveRejectFields = syncState.receiveRejectFields or {}
    local rejectFields = syncState.receiveRejectFields

    for _, tx in ipairs(data.transactions or {}) do
        local accepted, badField = reconstructSyncRecord(tx, sender)
        if not accepted then
            -- Counted apart from duplicates on purpose. Folding rejects into
            -- the dupe count made total rejection look like perfect
            -- convergence: the redundancy line would read 100% duped, which the
            -- decision rule in CLAUDE.md reads as "the bucket filter is working".
            itemRejected = itemRejected + 1
            rejectFields[badField or "unknown"] =
                (rejectFields[badField or "unknown"] or 0) + 1
            self:SyncDebug("Rejected item record from %s: bad %s",
                tostring(sender), tostring(badField))
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
        local accepted, badField = reconstructSyncRecord(tx, sender)
        if not accepted then
            moneyRejected = moneyRejected + 1
            rejectFields[badField or "unknown"] =
                (rejectFields[badField or "unknown"] or 0) + 1
            self:SyncDebug("Rejected money record from %s: bad %s",
                tostring(sender), tostring(badField))
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
    syncState.receiveItemRejected =
        (syncState.receiveItemRejected or 0) + itemRejected
    syncState.receiveMoneyRejected =
        (syncState.receiveMoneyRejected or 0) + moneyRejected

    local stored = itemStored + moneyStored
    -- Invalidate rescan session caches so the next periodic rescan uses
    -- BuildStoredRecordIndex (ground truth) instead of stale batch counts.
    if stored > 0 then
        self._lastTabBatchCounts = nil
        self._lastMoneyBatchCounts = nil
    end
    local duped = itemDuped + moneyDuped
    -- Assigned unconditionally, so a chunk without the field clears whatever
    -- an earlier one set. Only the final chunk carries it, so anything else
    -- arriving means the session is still running.
    syncState.receiveRemaining = data.remaining
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
        .. " - total so far: " .. syncState.receiveStored .. " new" .. dupPctSuffix .. ")")

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
    if not syncState.sending then return end
    if self:CanonicalPeerKey(sender) ~= self:CanonicalPeerKey(syncState.sendTarget) then return end

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
    local totalStored = syncState.receiveStored
    -- Read before the cleanup below, which decrements totalStored, and before
    -- the teardown that zeroes the counters.
    local remainingBuckets = syncState.receiveRemaining or 0
    local madeProgress = totalStored > 0 or (syncState.receiveNormalized or 0) > 0

    local guildData = self:GetGuildData()
    if guildData then
        -- Always checkpoint — bucket fingerprints handle the "still behind"
        -- case more precisely than timestamp rewind. This prevents re-sending
        -- everything on the next sync after a partial failure.
        guildData.syncState.lastSyncTimestamp = GetServerTime()

        guildData.syncState.peers[self:CanonicalPeerKey(sender)] = {
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
        .. " - " .. totalStored .. " new, " .. totalDuped .. " duped"
        .. ", " .. totalNormalized .. " normalized"
        .. ", " .. chunksGot .. " chunks, " .. elapsed .. "s"
        .. " - total tx now: " .. totalTxAfter .. ", hash: " .. newHash)

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
            line = line .. " - " .. table.concat(segments, ", ")
        end
        self:AddAuditEntry(line)
    end

    -- Rejects get their own line and their own vocabulary. Folded into the dupe
    -- count they were invisible, and worse than invisible: a peer sending
    -- nothing but corrupt records read as a peer we had fully converged with.
    local rejected = (syncState.receiveItemRejected or 0)
        + (syncState.receiveMoneyRejected or 0)
    if rejected > 0 then
        local fields = {}
        for field, count in pairs(syncState.receiveRejectFields or {}) do
            fields[#fields + 1] = field .. " x" .. count
        end
        table.sort(fields)
        self:SyncWarn("Rejected %d record(s) from %s: %s",
            rejected, tostring(sender or "unknown"), table.concat(fields, ", "))
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
    syncState.receiveItemRejected = 0
    syncState.receiveMoneyRejected = 0
    syncState.receiveRejectFields = {}
    syncState.receiveRemaining = nil
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

    -- A capped session leaves buckets behind. Nothing is scheduled to chase
    -- them: the post-sync HELLO below advertises what we now hold, the
    -- sender sees we are still behind and nudges, and the next slice starts
    -- through the ordinary pairing path. Recording it makes the seam between
    -- slices measurable in a capture, which is what decides whether a
    -- self-scheduled continuation is worth building.
    if remainingBuckets > 0 then
        self:AddAuditEntry("Partial session from " .. tostring(sender) .. ": "
            .. remainingBuckets .. " bucket(s) remaining"
            .. (madeProgress and "" or " (no progress)"))
    end

    -- We are free again the moment this returns. Nothing is scheduled to
    -- pick a next partner: the post-sync HELLO below tells the guild what
    -- we now hold, and whoever needs it asks.

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
    local clean = self:CanonicalPeerKey(sender)
    syncState.peers[clean] = {
        version = data.version,
        minSyncVersion = data.minSyncVersion,
        txCount = data.txCount or 0,
        dataHash = data.dataHash,
        lastScanTime = data.lastScanTime or 0,
        lastSeen = GetServerTime(),
    }
    -- Persist for cross-session discovery (survives relog). The floor rides
    -- along because InitSync seeds the session peer list from here and
    -- RequestSync's gate reads it off the seeded entry.
    local guildData = self:GetGuildData()
    if guildData then
        guildData.knownPeers[clean] = {
            version = data.version,
            minSyncVersion = data.minSyncVersion,
            txCount = data.txCount or 0,
            lastSeen = GetServerTime(),
        }
    end
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Deprecated: route to Logger.lua. Preserved as a thin shim so test
-- fixtures and any external callers keep working through the transition.
-- New code calls GBL:SyncInfo / SyncWarn / SyncError / SyncDebug directly
-- (or the lower-level GBL:LogSync).
-- @param message string Human-readable log entry
-- @param chatOnly boolean|nil If true, treat as DEBUG-level (chat-only-by-default).
function GBL:AddAuditEntry(message, chatOnly)
    if chatOnly then
        self:SyncDebug(message)
    else
        self:SyncInfo(message)
    end
end

--- Check if a guild member is currently online via the guild roster.
-- Compares names via CanonicalPeerKey on both the parameter and each roster
-- fullName, so connected-realm same-name members stay distinct (a query for
-- "Alice-OtherRealm" does not match the local-realm "Alice").
-- @param name string Character name (bare or realm-qualified)
-- @return boolean|nil true if online, false if offline, nil if not found
function GBL:IsGuildMemberOnline(name)
    local target = self:CanonicalPeerKey(name)
    local numMembers = GetNumGuildMembers()
    if not numMembers or numMembers == 0 then return nil end
    for i = 1, numMembers do
        local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if fullName and self:CanonicalPeerKey(fullName) == target then
            return isOnline
        end
    end
    return nil  -- not found in roster
end

--- Scan a guild's records for entries that fall in the epoch-0 window
-- (BucketKeyForRecord == 0). This is the symptom of the long-standing epoch-0
-- leak: a record whose id encodes timeSlot 0 stays in bucket 0 even after its
-- timestamp is repaired, because BucketKeyForRecord reads the id's timeSlot,
-- not the timestamp, and reconstructSyncRecord (sync intake) repairs only the
-- timestamp and never rebuilds the id. Read-only. Classifies offenders by
-- record type, by the peer that supplied them (scannedBy), and by whether the
-- timestamp itself is still invalid, so an in-game capture can show whether the
-- bucket-0 population is local or sync-borne before we choose a remediation.
-- (Rebuilding ids at intake from a clock-derived timeSlot is unsafe: two peers
-- would mint different ids and move the churn into live buckets, so the fix
-- shape depends on what these records actually are.)
-- @param guildData table Guild data (transactions + moneyTransactions)
-- @return table { count, items, money, validTs, invalidTs, sources, byScannedBy, samples }
function GBL:CollectEpochZeroRecords(guildData)
    local out = {
        count = 0, items = 0, money = 0,
        validTs = 0, invalidTs = 0,
        sources = 0, byScannedBy = {}, samples = {},
    }
    if not guildData then return out end

    local function scan(records, isMoney)
        for _, rec in ipairs(records or {}) do
            if self:BucketKeyForRecord(rec) == 0 then
                out.count = out.count + 1
                if isMoney then
                    out.money = out.money + 1
                else
                    out.items = out.items + 1
                end
                if self:IsValidTimestamp(rec.timestamp) then
                    out.validTs = out.validTs + 1
                else
                    out.invalidTs = out.invalidTs + 1
                end
                local src = rec.scannedBy or "?"
                if (out.byScannedBy[src] or 0) == 0 then
                    out.sources = out.sources + 1
                end
                out.byScannedBy[src] = (out.byScannedBy[src] or 0) + 1
                if #out.samples < 10 then
                    table.insert(out.samples, {
                        id = rec.id, type = rec.type, player = rec.player,
                        timestamp = rec.timestamp, scannedBy = rec.scannedBy,
                    })
                end
            end
        end
    end

    scan(guildData.transactions, false)
    scan(guildData.moneyTransactions, true)
    return out
end

--- Print a bucket-0 (epoch-0) diagnostic to chat and record a one-line summary
-- to the sync log. Reached via /gbl epoch0. Investigation aid for the epoch-0
-- leak; see CollectEpochZeroRecords.
function GBL:DumpEpochZeroRecords()
    local guildData = self:GetGuildData()
    if not guildData then
        self:Print("Epoch-0 dump: no guild data available.")
        return
    end
    local r = self:CollectEpochZeroRecords(guildData)
    self:Print(string.format("Epoch-0 (bucket 0) records: %d (%d item, %d money)",
        r.count, r.items, r.money))
    if r.count == 0 then
        self:SyncInfo("Epoch-0 dump: clean (no bucket-0 records)")
        return
    end
    self:Print(string.format("  timestamps: %d valid, %d invalid (< 2004)",
        r.validTs, r.invalidTs))
    self:Print(string.format("  sources (scannedBy): %d", r.sources))
    for src, n in pairs(r.byScannedBy) do
        self:Print(string.format("    %s: %d", tostring(src), n))
    end
    self:Print("  samples:")
    for _, s in ipairs(r.samples) do
        self:Print(string.format("    id=%s ts=%s by=%s",
            tostring(s.id), tostring(s.timestamp), tostring(s.scannedBy)))
    end
    self:SyncInfo(
        "Epoch-0 dump: %d records (%d item / %d money; %d valid-ts / %d invalid-ts; %d sources)",
        r.count, r.items, r.money, r.validTs, r.invalidTs, r.sources)
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
        receiveNackCount = syncState.receiveNackCount,
        receiveItemDuped = syncState.receiveItemDuped,
        receiveMoneyDuped = syncState.receiveMoneyDuped,
        receiveItemRejected = syncState.receiveItemRejected,
        receiveMoneyRejected = syncState.receiveMoneyRejected,
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

--- Return the sync-channel session log (compat alias for GBL:GetLog("sync")).
-- Kept permanently because ~40 spec sites read this; retire only if those
-- assertions are rewritten. Note: entry shape changed from
-- { timestamp, message } to { ts, level, channel, message }; the legacy
-- `timestamp` and `message` keys are added inline so downstream string-search
-- assertions on entry.message keep working unchanged.
-- @return table Array of entries, newest first
function GBL:GetAuditTrail()
    local snap = self:GetLog("sync")
    -- Expose `timestamp` alongside `ts` for legacy callers (e.g. UI/SyncStatus
    -- previously rendered entry.timestamp; tests assert on entry.message).
    -- Mutating in-place is safe because every entry has a stable shape.
    for i = 1, #snap do
        if snap[i].timestamp == nil then
            snap[i].timestamp = snap[i].ts
        end
    end
    return snap
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
    syncState.sendRemainingBuckets = 0
    syncState.sendChunkSentAt = 0
    syncState.receiving = false
    syncState.receiveSource = nil
    syncState.receiveExpected = 0
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveRemaining = nil
    syncState.receiveDuped = 0
    syncState.receiveTimer = nil
    syncState.receiveStartTime = 0
    syncState.receiveNackCount = 0
    syncState.peers = {}
    syncState.auditTrail = {}    -- legacy field, unused; kept zero for any direct readers
    self:ClearLog("sync")        -- clear the real sync buffer in Logger.lua
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
    syncState.peerBusyUntil = {}
    syncState.helloAfterCombat = false
    syncState.capLastTranche = {}
    syncState.lastForcedHelloTime = 0
    syncState.lastHelloReplyHash = {}
    syncState.lastSupersetNudge = {}
    syncState.incompatibleReplied = {}
    syncState.helloRepliesDuringSync = 0
    syncState.nacksReceivedDuringSync = 0
    syncState.lastLayoutRequestAt = 0
    syncState.lastChunkBytes = 0
    syncState.lastSendIssuedAt = 0
    syncState.sendChunkTransmittedAt = 0
    syncState.nacksForCurrentChunk = 0
    syncState.chunkOutcomes = {}
    ctlDeferTotal = 0
    ctlDrain.samples = {}
    ctlDrain.timersPending = 0
    ctlDrain.overlapTotal = 0
    ctlDrain.maxStall = 0
    ctlDrain.episodeStart = nil
    ctlDrain.episodeDefers = 0
    ctlDrain.overlapCount = 0
    ctlDrain.minAvail = nil
    ctlDrain.minAvailAt = nil
    ctlDrain.episodePaused = nil
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
            self:SyncError("Receive timeout: stuck for >"
                .. MAX_RECEIVE_DURATION .. "s, aborting")
            self:FinishReceiving(syncState.receiveSource)
            return
        end

        -- Check if sender went offline (abort early instead of wasting NACKs)
        local online = self:IsGuildMemberOnline(syncState.receiveSource)
        if online == false then
            self:SyncError("Sender " .. (syncState.receiveSource or "?")
                .. " offline, aborting receive")
            self:FinishReceiving(syncState.receiveSource)
            return
        end

        if syncState.receiveNackCount >= MAX_NACK_RETRIES then
            self:SyncError("NACK limit reached for chunk "
                .. (syncState.receiveGot + 1) .. " from "
                .. (syncState.receiveSource or "unknown") .. ", aborting")
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
    if not syncState.sending or self:CanonicalPeerKey(sender) ~= self:CanonicalPeerKey(syncState.sendTarget) then
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
        .. " - re-transmitting" .. ctlState)

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
    local cleanSender = self:CanonicalPeerKey(sender)
    self:AddAuditEntry("Received BUSY from " .. cleanSender)

    -- Clear receiving state if we're waiting for this peer (even with partial data).
    -- Already-stored records are safe; next sync uses bucket hashes to avoid re-sending.
    if syncState.receiving
        and self:CanonicalPeerKey(sender) == self:CanonicalPeerKey(syncState.receiveSource) then
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
        syncState.receiveRemaining = nil
        syncState.receiveStartTime = 0
        syncState.receiveNackCount = 0
        self._syncReceiving = false

        self:AddAuditEntry(cleanSender .. " busy - cleared receive state, will retry later")
    end

    -- Also abort sending if BUSY came from our send target
    -- (partner entered combat or became busy while we were sending to them)
    if syncState.sending
        and self:CanonicalPeerKey(sender) == self:CanonicalPeerKey(syncState.sendTarget) then
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
        syncState.sendRemainingBuckets = 0
        self:StopFpsMonitor()

        self:AddAuditEntry(cleanSender .. " busy - aborting send")
    end

    -- Leave them alone for a while, regardless of whether we cleared state.
    -- Nothing schedules a retry: they will advertise again, and we answer
    -- once the cooldown has passed.
    syncState.peerBusyUntil[cleanSender] = GetServerTime() + BUSY_COOLDOWN
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

    self:AddAuditEntry("Combat started - aborting sync")

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

--- Resume sync after combat ends.
--
-- There is no queue of deferred peers to drain any more, so resuming means
-- re-advertising: a forced HELLO tells the guild what we hold, behind peers
-- request from us, and peers ahead of us reply (or nudge, when the hash gate
-- suppressed the reply), which drives our own pull. Both directions come
-- back without anyone having remembered a partner.
--
-- Gated on helloAfterCombat so only a client that actually deferred
-- something broadcasts. Twenty raid members leaving combat together would
-- otherwise send twenty broadcasts, and FORCED_HELLO_COOLDOWN alone would
-- not stop that: the throttle is per client, not guild-wide.
--
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
            self:AddAuditEntry("Combat cooldown complete - sync resumed")
            -- Combat aborted a live session, so our peers were left mid-
            -- exchange. Re-advertise whatever we ended up holding.
            syncState.helloAfterCombat = false
            if not isSyncPaused() and self.db.profile.sync.enabled then
                self:BroadcastHello(true)
            end
        end, 1)
        return
    end

    if syncState.helloAfterCombat then
        syncState.helloAfterCombat = false
        C_Timer.After(2, function()
            if isSyncPaused() then return end
            if not self.db.profile.sync.enabled then return end
            self:BroadcastHello(true)
            self:AddAuditEntry("Combat ended - re-advertising to resume pairing")
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
    self:AddAuditEntry("Loading screen detected - sync paused")

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
            self:AddAuditEntry("Zone cooldown complete but still in combat - deferring")
            return
        end

        self:AddAuditEntry("Zone cooldown complete - sync resumed")

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
                .. ") - sync delay increased to " .. INTER_CHUNK_DELAY_SLOW .. "s")
        elseif fps > FPS_THRESHOLD_RECOVER and syncState.currentDelay > INTER_CHUNK_DELAY_NORMAL then
            syncState.currentDelay = INTER_CHUNK_DELAY_NORMAL
            self_ref:AddAuditEntry("FPS recovered (" .. math.floor(fps)
                .. ") - sync delay restored to " .. INTER_CHUNK_DELAY_NORMAL .. "s")
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
