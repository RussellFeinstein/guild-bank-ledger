------------------------------------------------------------------------
-- GuildBankLedger — Sync.lua
-- Guild-wide transaction sync via AceComm
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Protocol constants
local PREFIX = "GBLSync"
local PROTOCOL_VERSION = 1
local CHUNK_SIZE = 25
local ACK_TIMEOUT = 15
local RECEIVE_TIMEOUT = 30
local HELLO_DELAY = 5
local HELLO_COOLDOWN = 60

-- Expose constants for testing and UI
GBL.SYNC_PROTOCOL_VERSION = PROTOCOL_VERSION
GBL.SYNC_CHUNK_SIZE = CHUNK_SIZE
GBL.SYNC_PREFIX = PREFIX

-- Module state (session-only, not persisted)
local syncState = {
    sending = false,
    sendTarget = nil,
    sendChunks = {},
    sendChunkIndex = 0,
    sendTimer = nil,
    sendHardTimer = nil,

    receiving = false,
    receiveSource = nil,
    receiveExpected = 0,
    receiveGot = 0,
    receiveStored = 0,
    receiveTimer = nil,

    peers = {},
    auditTrail = {},
    lastHelloTime = 0,
}

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

--- Initialize sync system. Called from Core:OnEnable().
-- Registers AceComm prefix and schedules first HELLO broadcast.
function GBL:InitSync()
    if not self.db.profile.sync.enabled then return end
    self:RegisterComm(PREFIX, "OnSyncMessage")
    C_Timer.After(HELLO_DELAY, function()
        self:BroadcastHello()
    end)
end

--- Enable sync at runtime (from UI toggle).
function GBL:EnableSync()
    self.db.profile.sync.enabled = true
    self:RegisterComm(PREFIX, "OnSyncMessage")
    self:BroadcastHello()
end

--- Disable sync at runtime (from UI toggle).
function GBL:DisableSync()
    self.db.profile.sync.enabled = false
    syncState.sending = false
    syncState.receiving = false
    if syncState.sendTimer then
        syncState.sendTimer.cancelled = true
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer.cancelled = true
        syncState.sendHardTimer = nil
    end
    if syncState.receiveTimer then
        syncState.receiveTimer.cancelled = true
        syncState.receiveTimer = nil
    end
end

------------------------------------------------------------------------
-- HELLO broadcast
------------------------------------------------------------------------

--- Broadcast a HELLO message to the guild channel.
-- Includes addon version, protocol version, tx count, and last scan time.
-- Throttled by HELLO_COOLDOWN seconds between broadcasts.
function GBL:BroadcastHello()
    if not self.db.profile.sync.enabled then return end

    local now = GetServerTime()
    if now - syncState.lastHelloTime < HELLO_COOLDOWN then return end
    syncState.lastHelloTime = now

    local guildData = self:GetGuildData()
    if not guildData then return end

    local txCount = #guildData.transactions + #guildData.moneyTransactions

    local msg = self:Serialize({
        type = "HELLO",
        version = self.version,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
        txCount = txCount,
        lastScanTime = self.lastScanTime or 0,
    })

    self:SendCommMessage(PREFIX, msg, "GUILD")
    self:AddAuditEntry("Sent HELLO (tx: " .. txCount .. ")")
end

------------------------------------------------------------------------
-- Message dispatch
------------------------------------------------------------------------

--- AceComm callback — dispatches incoming sync messages by type.
-- @param prefix string AceComm prefix
-- @param message string Serialized message data
-- @param distribution string Channel type ("GUILD", "WHISPER", etc.)
-- @param sender string Sender character name
function GBL:OnSyncMessage(_prefix, message, _distribution, sender)
    if not self.db.profile.sync.enabled then return end

    -- Ignore our own messages (Ambiguate handles realm-qualified names in retail)
    local myName = UnitName("player")
    if Ambiguate(sender, "none") == myName then return end

    local success, data = self:Deserialize(message)
    if not success or type(data) ~= "table" then return end

    -- Protocol version gate (only on typed messages that carry the field)
    if data.protocolVersion and data.protocolVersion ~= PROTOCOL_VERSION then
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

    local msgType = data.type
    if msgType == "HELLO" then
        self:HandleHello(sender, data)
    elseif msgType == "SYNC_REQUEST" then
        self:HandleSyncRequest(sender, data)
    elseif msgType == "SYNC_DATA" then
        self:HandleSyncData(sender, data)
    elseif msgType == "ACK" then
        self:HandleAck(sender, data)
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
    local isNewPeer = not syncState.peers[sender]
    self:UpdatePeer(sender, data)

    -- Reply with our own HELLO so the sender discovers us too.
    -- Uses the normal cooldown to avoid infinite HELLO ping-pong.
    if isNewPeer then
        self:BroadcastHello()
    end

    -- Major version mismatch — warn and refuse sync
    if data.version and self:MajorVersion(data.version) ~= self:MajorVersion(self.version) then
        self:AddAuditEntry("WARNING: " .. sender .. " on v"
            .. tostring(data.version) .. " (major version mismatch)")
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local localCount = #guildData.transactions + #guildData.moneyTransactions
    local remoteCount = data.txCount or 0

    if remoteCount > localCount
        and not syncState.receiving
        and self.db.profile.sync.autoSync
    then
        local sinceTimestamp = guildData.syncState.lastSyncTimestamp or 0
        self:RequestSync(sender, sinceTimestamp)
    end
end

------------------------------------------------------------------------
-- Payload helpers
------------------------------------------------------------------------

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
    copy.itemLink = nil
    return copy
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
    syncState.receiveExpected = 0

    sinceTimestamp = sinceTimestamp or 0

    local msg = self:Serialize({
        type = "SYNC_REQUEST",
        sinceTimestamp = sinceTimestamp,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })

    self:SendCommMessage(PREFIX, msg, "WHISPER", target)
    self:AddAuditEntry("Requesting sync from " .. target
        .. " (since " .. sinceTimestamp .. ")")
    self:SendMessage("GBL_SYNC_STARTED", target)
end

--- Handle an incoming SYNC_REQUEST — gather and send matching transactions.
-- @param sender string Requester name
-- @param data table Deserialized request payload
function GBL:HandleSyncRequest(sender, data)
    if syncState.sending then
        self:AddAuditEntry("Declined sync from " .. sender .. " (already sending)")
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local sinceTimestamp = data.sinceTimestamp or 0

    -- Gather transactions scanned after sinceTimestamp.
    -- Use scanTime (when the record was created locally), NOT timestamp
    -- (when the event happened). A recent bank scan may find transactions
    -- from hours ago — those have old timestamps but new scanTimes.
    local txToSend = {}
    for _, tx in ipairs(guildData.transactions) do
        local when = tx.scanTime or tx.timestamp or 0
        if when > sinceTimestamp then
            txToSend[#txToSend + 1] = stripForSync(tx)
        end
    end
    local moneyToSend = {}
    for _, tx in ipairs(guildData.moneyTransactions) do
        local when = tx.scanTime or tx.timestamp or 0
        if when > sinceTimestamp then
            moneyToSend[#moneyToSend + 1] = tx
        end
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
        self:SendCommMessage(PREFIX, msg, "WHISPER", sender)
        self:AddAuditEntry("Sent empty sync to " .. sender)
        return
    end

    syncState.sending = true
    syncState.sendTarget = sender
    syncState.sendChunks = chunks
    syncState.sendChunkIndex = 0

    self:AddAuditEntry("Sending " .. (#txToSend + #moneyToSend)
        .. " tx to " .. sender .. " in " .. #chunks .. " chunk(s)")

    self:SendNextChunk()
end

------------------------------------------------------------------------
-- Chunking
------------------------------------------------------------------------

--- Split transaction arrays into CHUNK_SIZE-bounded chunks.
-- @param transactions table Array of item transaction records
-- @param moneyTransactions table Array of money transaction records
-- @return table Array of chunk tables, each with .transactions and .moneyTransactions
function GBL:PrepareChunks(transactions, moneyTransactions)
    local chunks = {}
    local currentTx = {}
    local currentMoney = {}
    local count = 0

    for _, tx in ipairs(transactions) do
        currentTx[#currentTx + 1] = tx
        count = count + 1
        if count >= CHUNK_SIZE then
            chunks[#chunks + 1] = {
                transactions = currentTx,
                moneyTransactions = currentMoney,
            }
            currentTx = {}
            currentMoney = {}
            count = 0
        end
    end

    for _, tx in ipairs(moneyTransactions) do
        currentMoney[#currentMoney + 1] = tx
        count = count + 1
        if count >= CHUNK_SIZE then
            chunks[#chunks + 1] = {
                transactions = currentTx,
                moneyTransactions = currentMoney,
            }
            currentTx = {}
            currentMoney = {}
            count = 0
        end
    end

    if #currentTx > 0 or #currentMoney > 0 then
        chunks[#chunks + 1] = {
            transactions = currentTx,
            moneyTransactions = currentMoney,
        }
    end

    return chunks
end

--- Send the next chunk in the queue. Aborts if no more chunks remain.
function GBL:SendNextChunk()
    if not syncState.sending then return end

    syncState.sendChunkIndex = syncState.sendChunkIndex + 1
    local idx = syncState.sendChunkIndex
    local chunk = syncState.sendChunks[idx]

    if not chunk then
        self:FinishSending()
        return
    end

    local msg = self:Serialize({
        type = "SYNC_DATA",
        chunk = idx,
        totalChunks = #syncState.sendChunks,
        transactions = chunk.transactions,
        moneyTransactions = chunk.moneyTransactions,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })

    -- Hard timeout safety net — fires if AceComm callback never completes
    if not syncState.sendHardTimer then
        syncState.sendHardTimer = C_Timer.After(120, function()
            if syncState.sending then
                self:AddAuditEntry("Send hard timeout — aborting")
                self:FinishSending()
            end
        end)
    end

    -- ACK timer deferred until message fully transmitted via AceComm callback.
    -- AceComm calls callbackFn(callbackArg, bytesSent, totalLen) per CTL piece.
    self:SendCommMessage(PREFIX, msg, "WHISPER", syncState.sendTarget, "NORMAL",
        function(_cbArg, sent, total)
            if sent < total then return end
            -- Message fully transmitted — now start ACK timer
            if syncState.sendTimer then
                syncState.sendTimer.cancelled = true
            end
            syncState.sendTimer = C_Timer.After(ACK_TIMEOUT, function()
                if syncState.sending then
                    self:AddAuditEntry("ACK timeout from "
                        .. (syncState.sendTarget or "unknown") .. " — aborting")
                    self:FinishSending()
                end
            end)
        end)
end

--- Clean up sending state after sync completes or aborts.
function GBL:FinishSending()
    syncState.sending = false
    syncState.sendTarget = nil
    syncState.sendChunks = {}
    syncState.sendChunkIndex = 0
    if syncState.sendTimer then
        syncState.sendTimer.cancelled = true
        syncState.sendTimer = nil
    end
    if syncState.sendHardTimer then
        syncState.sendHardTimer.cancelled = true
        syncState.sendHardTimer = nil
    end
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

--- Process an incoming SYNC_DATA chunk — dedup and store transactions.
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
    elseif Ambiguate(sender, "none") ~= Ambiguate(syncState.receiveSource, "none") then
        -- Reject data from a different sender during active receive
        self:AddAuditEntry("Ignored SYNC_DATA from " .. sender
            .. " (receiving from " .. (syncState.receiveSource or "?") .. ")")
        return
    end

    local guildData = self:GetGuildData()
    if not guildData then return end

    local stored = 0

    for _, tx in ipairs(data.transactions or {}) do
        if self:StoreTx(tx, guildData) then
            stored = stored + 1
        end
    end

    for _, tx in ipairs(data.moneyTransactions or {}) do
        if self:StoreMoneyTx(tx, guildData) then
            stored = stored + 1
        end
    end

    syncState.receiveGot = syncState.receiveGot + 1
    syncState.receiveStored = syncState.receiveStored + stored
    syncState.receiveExpected = data.totalChunks or 1

    -- Reset receive timeout (fires if no more chunks arrive)
    if syncState.receiveTimer then
        syncState.receiveTimer.cancelled = true
    end
    syncState.receiveTimer = C_Timer.After(RECEIVE_TIMEOUT, function()
        if syncState.receiving then
            self:AddAuditEntry("Receive timeout from "
                .. (syncState.receiveSource or "unknown") .. " — aborting")
            self:FinishReceiving(syncState.receiveSource)
        end
    end)

    -- Send ACK
    local ackMsg = self:Serialize({
        type = "ACK",
        chunk = data.chunk,
        stored = stored,
        protocolVersion = PROTOCOL_VERSION,
        guild = self:GetGuildName(),
    })
    self:SendCommMessage(PREFIX, ackMsg, "WHISPER", sender)

    self:AddAuditEntry("Received chunk " .. (data.chunk or "?") .. "/"
        .. (data.totalChunks or "?") .. " from " .. sender
        .. " (" .. stored .. " new)")

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
function GBL:HandleAck(sender, _data)
    if not syncState.sending or Ambiguate(sender, "none") ~= Ambiguate(syncState.sendTarget, "none") then return end

    if syncState.sendTimer then
        syncState.sendTimer.cancelled = true
        syncState.sendTimer = nil
    end

    -- Small delay between chunks to avoid flooding
    C_Timer.After(0.1, function()
        self:SendNextChunk()
    end)
end

--- Clean up receiving state and persist sync metadata.
-- @param sender string The peer we synced from
function GBL:FinishReceiving(sender)
    local totalStored = syncState.receiveStored

    local guildData = self:GetGuildData()
    if guildData then
        -- Compare counts with what the peer reported in their last HELLO.
        -- If we're still behind after this sync, a relayed record was likely
        -- filtered by the delta timestamp. Reset to 0 so the next request
        -- does a full sync instead of repeating the same miss.
        local localCount = #guildData.transactions + #guildData.moneyTransactions
        local peerInfo = syncState.peers[sender]
        local peerCount = peerInfo and peerInfo.txCount or 0
        if localCount < peerCount then
            guildData.syncState.lastSyncTimestamp = 0
            self:AddAuditEntry("Still behind " .. sender
                .. " (" .. localCount .. " vs " .. peerCount
                .. ") — next sync will be full")
        else
            guildData.syncState.lastSyncTimestamp = GetServerTime()
        end

        guildData.syncState.peers[sender] = {
            lastSync = GetServerTime(),
            stored = totalStored,
        }
    end

    self:AddAuditEntry("Sync complete from " .. (sender or "unknown")
        .. " (" .. totalStored .. " new)")

    if syncState.receiveTimer then
        syncState.receiveTimer.cancelled = true
        syncState.receiveTimer = nil
    end

    syncState.receiving = false
    syncState.receiveSource = nil
    syncState.receiveExpected = 0
    syncState.receiveGot = 0
    syncState.receiveStored = 0

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
    syncState.peers[sender] = {
        version = data.version,
        txCount = data.txCount or 0,
        lastScanTime = data.lastScanTime or 0,
        lastSeen = GetServerTime(),
    }
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Extract the major version number from a version string.
-- @param versionStr string e.g. "0.5.0"
-- @return number Major version (0 if unparseable)
function GBL:MajorVersion(versionStr)
    if not versionStr then return 0 end
    return tonumber(versionStr:match("^(%d+)")) or 0
end

--- Append an entry to the session audit trail (capped at 50).
-- @param message string Human-readable log entry
function GBL:AddAuditEntry(message)
    table.insert(syncState.auditTrail, 1, {
        timestamp = GetServerTime(),
        message = message,
    })
    while #syncState.auditTrail > 50 do
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
    }
end

--- Return the session peer list.
-- @return table Map of name → { version, txCount, lastScanTime, lastSeen }
function GBL:GetSyncPeers()
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
    syncState.receiving = false
    syncState.receiveSource = nil
    syncState.receiveExpected = 0
    syncState.receiveGot = 0
    syncState.receiveStored = 0
    syncState.receiveTimer = nil
    syncState.peers = {}
    syncState.auditTrail = {}
    syncState.lastHelloTime = 0
end
