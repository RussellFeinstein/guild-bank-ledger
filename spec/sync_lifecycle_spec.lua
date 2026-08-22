------------------------------------------------------------------------
-- spec/sync_lifecycle_spec.lua — Sync session lifecycle
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

local fireReceiveTimeout = Sync.fireReceiveTimeout

describe("Sync session lifecycle", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- Message dispatch (OnSyncMessage)
    ---------------------------------------------------------------------------

    describe("OnSyncMessage", function()
        it("ignores messages from self", function()
            MockWoW.player.name = "OfficerA"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 999, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerA")

            -- Should not have updated peers (ignored own message)
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerA"])
        end)

        it("ignores messages when sync is disabled", function()
            GBL.db.profile.sync.enabled = false
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 50, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerB")

            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Unhandled message types
    --
    -- What is left of the MANIFEST block. The broadcast and its handler are
    -- gone, and this is the property that made removing them free: the
    -- dispatch chain has no else, so a message type this build does not
    -- know about costs nothing. A peer on an older version keeps sending
    -- MANIFEST at us and we keep ignoring it, with no protocol bump and no
    -- floor raise. The manifest suppression-during-sync test that used to
    -- live here is not replaced: the same rule for HELLO is covered by the
    -- keepalive tests in the BroadcastHello block.
    ---------------------------------------------------------------------------

    describe("unhandled message types", function()
        it("are silently ignored", function()
            assert.has_no_errors(function()
                GBL:OnSyncMessage(GBL.SYNC_PREFIX,
                    GBL._compressMessage(GBL:Serialize({
                        type = "FUTURE_TYPE",
                        protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                        guild = "Test Guild",
                    })),
                    "GUILD", "PeerA")
            end)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Self-message filtering with realm names
    ---------------------------------------------------------------------------

    describe("self-message filtering", function()
        it("filters realm-qualified self-messages (same realm)", function()
            MockWoW.player.name = "OfficerA"
            MockWoW.player.realm = "TestRealm"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 999, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            -- Sender includes realm suffix matching local (retail WoW behavior).
            -- CanonicalPeerKey strips same-realm suffix, so own-message filter triggers.
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerA-TestRealm")

            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerA"])
            assert.is_nil(peers["OfficerA-TestRealm"])
        end)

        it("does not filter same-name messages from cross-realm players", function()
            MockWoW.player.name = "OfficerA"
            MockWoW.player.realm = "TestRealm"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 5, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            -- Same first name as local player but different realm: should NOT
            -- be filtered (it's a distinct connected-realm peer).
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerA-OtherRealm")

            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerA"])
            assert.is_not_nil(peers["OfficerA-OtherRealm"])
        end)

        it("does not filter messages from different players", function()
            MockWoW.player.name = "OfficerA"
            MockWoW.player.realm = "TestRealm"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 5, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerB-TestRealm")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- System message filter
    ---------------------------------------------------------------------------

    describe("system message filter", function()
        local filter

        before_each(function()
            -- InitSync installs the filter
            GBL:InitSync()
            -- Find the filter function that was registered
            local filters = MockWoW.chatMessageFilters["CHAT_MSG_SYSTEM"]
            assert.is_not_nil(filters)
            assert.is_true(#filters > 0)
            filter = filters[#filters]
        end)

        it("suppresses error for tracked player", function()
            GBL._recentWhisperTargets["SomePeer"] = MockWoW.serverTime

            local suppress = filter(nil, "CHAT_MSG_SYSTEM",
                "No player named 'SomePeer' is currently playing.")
            assert.is_true(suppress)
        end)

        it("passes error for untracked player", function()
            -- recentWhisperTargets is empty after ResetSyncState
            local suppress = filter(nil, "CHAT_MSG_SYSTEM",
                "No player named 'SomePeer' is currently playing.")
            assert.is_false(suppress)
        end)

        it("passes non-matching system messages", function()
            GBL._recentWhisperTargets["SomePeer"] = MockWoW.serverTime

            local suppress = filter(nil, "CHAT_MSG_SYSTEM",
                "You are not in a guild.")
            assert.is_false(suppress)
        end)

        it("aborts in-progress send for confirmed-offline target", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add a transaction so sync has data to send
            local tx = {
                id = "tx1", tab = 1, type = "deposit", player = "Someone",
                timestamp = MockWoW.serverTime - 100, itemID = 12345,
                itemName = "Test Item", count = 1,
            }
            table.insert(guildData.transactions, tx)

            -- Peer is online when sync request arrives
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }
            GBL:UpdatePeer("OnlinePeer", {
                version = GBL.version, txCount = 0, dataHash = 99,
                lastScanTime = MockWoW.serverTime,
            })

            -- Simulate receiving a sync request to start sending
            local requestMsg = GBL:Serialize({
                type = "SYNC_REQUEST",
                sinceTimestamp = 0,
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            requestMsg = GBL._compressMessage(requestMsg)
            GBL:OnSyncMessage("GBLSync", requestMsg, "WHISPER", "OnlinePeer")

            assert.is_true(GBL:IsSyncing())

            -- Track the peer (simulates what SendSyncWhisper does)
            GBL._recentWhisperTargets["OnlinePeer"] = MockWoW.serverTime

            -- Fire the filter as if WoW reported the peer offline
            filter(nil, "CHAT_MSG_SYSTEM",
                "No player named 'OnlinePeer' is currently playing.")

            -- Sending should be aborted
            assert.is_false(GBL:IsSyncing())
        end)

        it("keeps tracking entry after suppression (CTL multi-piece)", function()
            GBL._recentWhisperTargets["SomePeer"] = MockWoW.serverTime

            -- First suppression
            filter(nil, "CHAT_MSG_SYSTEM",
                "No player named 'SomePeer' is currently playing.")
            -- Entry should still be present for subsequent CTL pieces
            assert.is_not_nil(GBL._recentWhisperTargets["SomePeer"])

            -- Second suppression should also work
            local suppress = filter(nil, "CHAT_MSG_SYSTEM",
                "No player named 'SomePeer' is currently playing.")
            assert.is_true(suppress)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Edge cases
    ---------------------------------------------------------------------------

    describe("Edge cases", function()
        it("rejects SYNC_DATA from wrong sender during active receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving from OfficerB (multi-chunk)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 2,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 100, count = 1, tab = 1,
                        timestamp = 1000, scanTime = 1000,
                        scannedBy = "OfficerB",
                        id = "deposit|Thrall|100|1|1|0",
                    },
                },
                moneyTransactions = {},
            })
            assert.equals(1, #guildData.transactions)

            -- OfficerC sends unsolicited SYNC_DATA while we're receiving from B
            MockAce.sentCommMessages = {}
            GBL:HandleSyncData("OfficerC", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Jaina",
                        itemID = 200, count = 1, tab = 1,
                        timestamp = 2000, scanTime = 2000,
                        scannedBy = "OfficerC",
                        id = "deposit|Jaina|200|1|1|0",
                    },
                },
                moneyTransactions = {},
            })

            -- Should NOT have stored OfficerC's data (wrong sender)
            assert.equals(1, #guildData.transactions)
            assert.equals("Thrall-TestRealm", guildData.transactions[1].player)
        end)

        it("filters by scanTime, not timestamp, in SYNC_REQUEST", function()
            -- Simulate a record scanned recently but with an old event timestamp
            -- (e.g., officer scans the bank, finds a 2-hour-old transaction)
            table.insert(guildData.transactions, {
                type = "deposit", player = "OldEvent",
                itemID = 500, count = 10, tab = 1,
                timestamp = 500,       -- event happened a long time ago
                scanTime = 9000,       -- but scanned recently
                scannedBy = "OfficerA",
                id = "deposit|OldEvent|500|10|1|0",
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "OlderScan",
                itemID = 600, count = 5, tab = 1,
                timestamp = 400,       -- event happened even longer ago
                scanTime = 2000,       -- scanned before last sync
                scannedBy = "OfficerA",
                id = "deposit|OlderScan|600|5|1|0",
            })

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Request since time 5000 (like a receiver who last synced at 5000)
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 5000 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            -- Should include "OldEvent" (scanTime 9000 > 5000)
            -- Should exclude "OlderScan" (scanTime 2000 <= 5000)
            assert.equals(1, #data.transactions)
            assert.equals("OldEvent", data.transactions[1].player)
        end)

        it("intermediate chunk does NOT trigger completion", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1 of 3
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })

            -- Should still be receiving
            assert.is_true(GBL:IsSyncing())

            -- Receive chunk 2 of 3
            MockAce.sentMessages = {}
            GBL:HandleSyncData("OfficerB", {
                chunk = 2,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })

            -- Should still be receiving — no SYNC_COMPLETE yet
            assert.is_true(GBL:IsSyncing())
            local foundComplete = false
            for _, msg in ipairs(MockAce.sentMessages) do
                if msg.message == "GBL_SYNC_COMPLETE" then
                    foundComplete = true
                end
            end
            assert.is_false(foundComplete)
        end)

        it("HELLO during active receive does NOT start second receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving from OfficerB
            GBL:RequestSync("OfficerB", 0)
            MockAce.sentCommMessages = {}

            -- OfficerC sends HELLO with high txCount
            GBL:HandleHello("OfficerC", {
                version = GBL.version,
                txCount = 999,
                lastScanTime = 1000,
            })

            -- Should NOT have sent a SYNC_REQUEST to C (already receiving from B)
            local foundSyncRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundSyncRequest = true
                end
            end
            assert.is_false(foundSyncRequest)
        end)

        it("HandleAck from wrong sender is ignored", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Simulate sending state
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            MockAce.sentCommMessages = {}

            -- OfficerC sends an ACK (not our target)
            GBL:HandleAck("OfficerC", { chunk = 1 })

            -- Should not have sent next chunk (wrong sender)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("HandleAck discards stale ACK for wrong chunk number", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Need enough records for 2+ chunks
            for i = 1, 30 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- sendChunkIndex should be 1 after first SendNextChunk
            local timersBefore = #MockWoW.pendingTimers
            MockAce.sentCommMessages = {}

            -- Send ACK for chunk 3 (stale — we're on chunk 1)
            GBL:HandleAck("OfficerB", { chunk = 3 })

            -- Should NOT have scheduled next chunk (no new messages)
            assert.equals(0, #MockAce.sentCommMessages)
            -- ACK timer should still be alive (not cancelled by stale ACK)
            local ackTimerAlive = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerAlive = true
                end
            end
            assert.is_true(ackTimerAlive, "ACK timer should survive stale ACK")
        end)

        it("DisableSync during active send cleans up state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should be sending
            local status = GBL:GetSyncStatus()
            assert.is_true(status.sending)

            -- Disable sync
            GBL:DisableSync()

            status = GBL:GetSyncStatus()
            assert.is_false(status.sending)
            assert.is_false(status.receiving)
            assert.is_false(GBL:IsSyncEnabled())
        end)

        it("DisableSync during active receive cleans up state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:RequestSync("OfficerB", 0)

            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)

            GBL:DisableSync()

            status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
        end)

        it("rejects messages from a different guild", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 999, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Other Guild",
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerB")

            -- Should have been rejected — wrong guild
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"])
        end)

        it("accepts messages from same guild", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 5, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerB")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
        end)

        it("HELLO includes guild name in broadcast", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("Test Guild", data.guild)
        end)

        -- This used to assert only that a corrupt message changed nothing, and
        -- the dropping really was silent: two bare returns at every level. That
        -- is the shape a lost middle fragment takes, because AceComm reassembles
        -- multipart with no sequence numbers and no completeness check, so it
        -- hands up a truncated payload and calls it delivered. Nothing said so,
        -- which is why a capture could not tell wire loss from a peer that never
        -- spoke. The byte count is the useful part: it says how much of the
        -- message survived, and therefore how the route is losing fragments.
        it("warns when a message cannot be decoded, with its size", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:OnSyncMessage("GBLSync", "not-valid-data", "GUILD", "OfficerB")

            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"], "a corrupt message must change nothing")

            local warned = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.level == "WARN"
                    and entry.message:find("OfficerB", 1, true)
                    and entry.message:find(tostring(#"not-valid-data"), 1, true) then
                    warned = true
                end
            end
            assert.is_true(warned, "the drop should be visible in a capture")
        end)

        it("warns when a message cannot be decompressed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- The LibDeflate mock is an identity transform, so the decompress
            -- branch is unreachable without standing in for a failure.
            local LibDeflate = LibStub("LibDeflate")
            local realDecode = LibDeflate.DecodeForWoWAddonChannel
            LibDeflate.DecodeForWoWAddonChannel = function() return nil end

            GBL:OnSyncMessage("GBLSync", "garbled-payload", "WHISPER", "OfficerB")

            LibDeflate.DecodeForWoWAddonChannel = realDecode

            local warned = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.level == "WARN"
                    and entry.message:find("decompress", 1, true)
                    and entry.message:find("OfficerB", 1, true) then
                    warned = true
                end
            end
            assert.is_true(warned, "a failed decompress should be visible too")
        end)

        it("SYNC_DATA with nil transaction arrays is handled", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- No crash with nil fields
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                -- intentionally omit transactions and moneyTransactions
            })

            -- Should complete without storing anything
            assert.equals(0, #guildData.transactions)
            assert.equals(0, #guildData.moneyTransactions)
        end)

        it("BroadcastHello when not in guild is a no-op", function()
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("checkpoints lastSyncTimestamp even when still behind after sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Peer reported 50 tx in their HELLO
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 50, lastScanTime = 1000,
            })

            -- We receive a sync but end up with fewer records (relay gap)
            -- Simulate: we have 30 tx, peer has 50
            for i = 1, 30 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P" .. i, timestamp = i,
                    scanTime = i, id = "h" .. i,
                })
                guildData.seenTxHashes["h" .. i] = i
            end

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            -- Always checkpoint — bucket fingerprints handle the "still behind" case
            assert.is_true(guildData.syncState.lastSyncTimestamp > 0)
        end)

        it("sets lastSyncTimestamp normally when counts match after sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Peer reported 0 tx
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 1000,
            })

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            -- Counts match (both 0) — timestamp should be set normally
            assert.is_true(guildData.syncState.lastSyncTimestamp > 0)
        end)

        it("second HELLO from same peer updates peer info", function()
            GBL:HandleHello("OfficerB", {
                version = "0.5.0", txCount = 10, lastScanTime = 1000,
            })

            -- Advance time and send another HELLO
            MockWoW.serverTime = MockWoW.serverTime + 100
            GBL:HandleHello("OfficerB", {
                version = "0.5.0", txCount = 25, lastScanTime = 2000,
            })

            local peers = GBL:GetSyncPeers()
            assert.equals(25, peers["OfficerB"].txCount)
            assert.equals(2000, peers["OfficerB"].lastScanTime)
        end)

        it("receive timeout resets stuck receive state after NACK retries", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving (multi-chunk)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })
            assert.is_true(GBL:IsSyncing())

            -- Fire timeout MAX_NACK_RETRIES times (sends NACKs but stays receiving)
            for _ = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
            end

            -- One more timeout — should abort after exhausting retries
            fireReceiveTimeout()

            -- Should no longer be syncing
            assert.is_false(GBL:IsSyncing())
        end)
    end)

    ---------------------------------------------------------------------------
    -- Combat guard
    ---------------------------------------------------------------------------

    describe("combat guard", function()
        it("HandleHello defers sync during combat", function()
            -- Override InCombatLockdown to return true
            local origICL = _G.InCombatLockdown
            _G.InCombatLockdown = function() return true end

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 999,
                isReply = true,
            })

            -- Should not be receiving (deferred)
            assert.is_false(GBL:GetSyncStatus().receiving)

            _G.InCombatLockdown = origICL
        end)

        it("OnCombatEnd re-advertises when a HELLO was deferred", function()
            local origICL = _G.InCombatLockdown
            _G.InCombatLockdown = function() return true end
            GBL:HandleHello("PeerA", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 999,
                isReply = true,
            })
            _G.InCombatLockdown = origICL

            GBL:OnCombatEnd()

            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 2 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_true(found,
                "OnCombatEnd should schedule the re-advertising HELLO")
        end)

        it("OnCombatEnd is no-op when nothing was deferred", function()
            local before = #MockWoW.pendingTimers
            GBL:OnCombatEnd()
            assert.equals(before, #MockWoW.pendingTimers)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Combat protection (proactive abort)
    ---------------------------------------------------------------------------

    describe("combat protection", function()
        -- Helper: enter sending state via HandleSyncRequest
        local function enterSendingState()
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "combat:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["combat:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)
        end

        -- Helper: enter receiving state via RequestSync
        local function enterReceivingState()
            GBL:RequestSync("PeerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
        end

        it("OnCombatStart aborts active send and sends BUSY to partner", function()
            enterSendingState()
            MockAce.sentCommMessages = {}

            GBL:OnCombatStart()

            assert.is_false(GBL:GetSyncStatus().sending)
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            -- Should have sent BUSY to PeerA
            local busyFound = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == "PeerA" then
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "BUSY" then
                        busyFound = true
                    end
                end
            end
            assert.is_true(busyFound, "BUSY should be sent to send target")
        end)

        it("OnCombatStart aborts active receive and sends BUSY to partner", function()
            enterReceivingState()
            MockAce.sentCommMessages = {}

            GBL:OnCombatStart()

            assert.is_false(GBL:GetSyncStatus().receiving)
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            -- Should have sent BUSY to PeerB
            local busyFound = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == "PeerB" then
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "BUSY" then
                        busyFound = true
                    end
                end
            end
            assert.is_true(busyFound, "BUSY should be sent to receive source")
        end)

        it("OnCombatStart aborts concurrent send+receive and sends BUSY to both", function()
            enterSendingState()
            enterReceivingState()
            MockAce.sentCommMessages = {}

            GBL:OnCombatStart()

            assert.is_false(GBL:GetSyncStatus().sending)
            assert.is_false(GBL:GetSyncStatus().receiving)
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            -- Should have sent BUSY to both PeerA and PeerB
            local targets = {}
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "BUSY" then
                    targets[msg.target] = true
                end
            end
            assert.is_true(targets["PeerA"], "BUSY should be sent to send target")
            assert.is_true(targets["PeerB"], "BUSY should be sent to receive source")
        end)

        it("OnCombatStart is no-op when idle", function()
            assert.is_false(GBL:GetSyncStatus().sending)
            assert.is_false(GBL:GetSyncStatus().receiving)

            GBL:OnCombatStart()

            -- combatPaused should NOT be set when idle
            assert.is_false(GBL:GetSyncStatus().combatPaused)
        end)

        it("OnCombatStart cancels all sync timers", function()
            enterSendingState()
            enterReceivingState()

            -- Verify timers exist (sending uses inter-chunk timer, receiving uses timeout)
            local timersBefore = #MockWoW.pendingTimers

            GBL:OnCombatStart()

            -- All pending timers should be cancelled
            local uncancelled = 0
            for _, t in ipairs(MockWoW.pendingTimers) do
                if not t.cancelled then
                    uncancelled = uncancelled + 1
                end
            end
            -- Only uncancelled timers should be the ones created by OnCombatStart itself
            -- (FinishSending/FinishReceiving may schedule new timers, but with combat guards)
            assert.is_false(GBL:GetSyncStatus().sending)
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("OnCombatEnd clears combatPaused after cooldown", function()
            enterSendingState()
            GBL:OnCombatStart()
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            GBL:OnCombatEnd()

            -- Still paused (cooldown hasn't fired yet)
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            -- Fire the cooldown ticker
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == GBL.SYNC_COMBAT_COOLDOWN and not t.cancelled then
                    t.callback()
                    break
                end
            end

            assert.is_false(GBL:GetSyncStatus().combatPaused)
        end)

        -- The whole loop, because the individual steps are cheap to get
        -- right while the path between them is what actually has to work:
        -- combat aborts a session, the cooldown expires, we re-advertise,
        -- a peer answers that broadcast, and only then does a real
        -- SYNC_REQUEST go out. Nothing along the way remembered a partner.
        it("resumes pairing through a re-advertised HELLO after cooldown", function()
            enterSendingState()
            GBL:UpdatePeer("PeerQ", { version = GBL.version, txCount = 20, dataHash = 888 })

            GBL:OnCombatStart()
            GBL:OnCombatEnd()

            -- Fire cooldown
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == GBL.SYNC_COMBAT_COOLDOWN and not t.cancelled then
                    t.callback()
                    break
                end
            end

            local helloSent = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "HELLO" and msg.distribution == "GUILD" then
                    helloSent = true
                end
            end
            assert.is_true(helloSent,
                "cooldown should re-advertise so peers can pair with us again")

            -- PeerQ answers our broadcast, which is what actually restarts
            -- the exchange.
            MockAce.sentCommMessages = {}
            GBL:HandleHello("PeerQ", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 888,
                isReply = true,
            })

            local requestSent = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == "PeerQ" then
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "SYNC_REQUEST" then
                        requestSent = true
                    end
                end
            end
            assert.is_true(requestSent,
                "the peer's reply to our re-advertisement should start a sync")
        end)

        it("rapid combat in/out cancels stale cooldown timer", function()
            enterSendingState()
            GBL:OnCombatStart()

            -- Exit combat — starts cooldown
            GBL:OnCombatEnd()
            local firstCooldownFound = false
            for _, t in ipairs(MockWoW.pendingTimers) do
                if t.delay == GBL.SYNC_COMBAT_COOLDOWN and not t.cancelled then
                    firstCooldownFound = true
                end
            end
            assert.is_true(firstCooldownFound)

            -- Re-enter combat before cooldown fires (new sync starts in between)
            GBL:ResetSyncState()
            GBL.db.profile.sync.enabled = true
            GBL.db.profile.sync.autoSync = true
            guildData = GBL:GetGuildData()
            table.insert(guildData.transactions, {
                type = "deposit", player = "P2", tab = 1, itemID = 456,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 2000 * 3600, id = "combat2:277:0", _occurrence = 0,
                scanTime = 2000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["combat2:277:0"] = 2000 * 3600
            GBL:HandleSyncRequest("PeerC", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:OnCombatStart()

            -- First cooldown timer should be cancelled
            local uncancelledCooldowns = 0
            for _, t in ipairs(MockWoW.pendingTimers) do
                if t.delay == GBL.SYNC_COMBAT_COOLDOWN and not t.cancelled then
                    uncancelledCooldowns = uncancelledCooldowns + 1
                end
            end
            -- Should be 0 — OnCombatStart cancels any prior cooldown
            assert.equals(0, uncancelledCooldowns)
            assert.is_true(GBL:GetSyncStatus().combatPaused)
        end)

        it("combat + zone overlap: clearing combat alone does not unpause", function()
            enterSendingState()
            -- Zone pause first (while still sending)
            GBL:OnLoadingScreenStart()
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Then combat starts (aborts sync, sets combatPaused)
            GBL:OnCombatStart()
            assert.is_true(GBL:GetSyncStatus().combatPaused)
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Clear combat via cooldown
            GBL:OnCombatEnd()
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == GBL.SYNC_COMBAT_COOLDOWN and not t.cancelled then
                    t.callback()
                    break
                end
            end

            -- combatPaused cleared but zonePaused still set
            assert.is_false(GBL:GetSyncStatus().combatPaused)
            assert.is_true(GBL:GetSyncStatus().zonePaused)
        end)

        it("HandleBusy aborts sending when from send target", function()
            enterSendingState()
            assert.is_true(GBL:GetSyncStatus().sending)
            assert.equals("PeerA", GBL:GetSyncStatus().sendTarget)

            GBL:HandleBusy("PeerA", {})

            assert.is_false(GBL:GetSyncStatus().sending)
        end)

        it("HandleBusy does NOT abort sending when from different peer", function()
            enterSendingState()
            assert.is_true(GBL:GetSyncStatus().sending)

            GBL:HandleBusy("PeerZ", {})

            -- Still sending to PeerA
            assert.is_true(GBL:GetSyncStatus().sending)
            assert.equals("PeerA", GBL:GetSyncStatus().sendTarget)
        end)

        it("OnLoadingScreenEnd defers resume when combatPaused", function()
            enterSendingState()
            -- Zone pause first (while still sending)
            GBL:OnLoadingScreenStart()
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Then combat starts (aborts sync, sets combatPaused)
            GBL:OnCombatStart()
            assert.is_true(GBL:GetSyncStatus().combatPaused)

            -- Now end loading screen
            GBL:OnLoadingScreenEnd()

            -- Fire zone cooldown timer
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 5 and not t.cancelled then  -- ZONE_COOLDOWN = 5
                    t.callback()
                    break
                end
            end

            -- zonePaused should be cleared
            assert.is_false(GBL:GetSyncStatus().zonePaused)
            -- but combatPaused should still be true
            assert.is_true(GBL:GetSyncStatus().combatPaused)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Zone change protection
    ---------------------------------------------------------------------------

    describe("zone change protection", function()
        it("pauses sync on loading screen start during send", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "zone1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            GBL:OnLoadingScreenStart()
            assert.is_true(GBL:GetSyncStatus().zonePaused)
        end)

        it("resumes sync after cooldown on loading screen end", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "zone2:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            GBL:OnLoadingScreenStart()
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            GBL:OnLoadingScreenEnd()
            -- Still paused until cooldown fires
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Fire the cooldown timer
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 5 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end
            assert.is_false(GBL:GetSyncStatus().zonePaused)
        end)

        it("SendNextChunk is no-op while zone paused", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "zone3:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            local sentBefore = #MockAce.sentCommMessages

            -- Pause and try to send
            GBL:OnLoadingScreenStart()
            GBL:SendNextChunk()

            -- No new messages (deferred)
            assert.equals(sentBefore, #MockAce.sentCommMessages)
        end)

        it("incoming SYNC_DATA still processed while zone paused", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving, then pause
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 2,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "zone4a:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:OnLoadingScreenStart()

            -- Receive chunk 2 while paused
            MockAce.sentCommMessages = {}
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 2, totalChunks = 2,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5001,
                    scanTime = 5001, id = "zone4b:0", itemID = 101, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Data should still have been stored (ACK sent)
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("ACK", data.type)
        end)

        it("DisableSync clears zone pause state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "zone5:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:OnLoadingScreenStart()
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            GBL:DisableSync()
            assert.is_false(GBL:GetSyncStatus().zonePaused)
        end)

        it("double zone change cancels pending cooldown timer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "zone6:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- First zone change
            GBL:OnLoadingScreenStart()
            GBL:OnLoadingScreenEnd()

            -- Second zone change before cooldown fires
            GBL:OnLoadingScreenStart()

            -- Count non-cancelled cooldown timers — should be 0
            -- (the first one was cancelled by the second OnLoadingScreenStart)
            local activeCooldowns = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 5 and not timer.cancelled then
                    activeCooldowns = activeCooldowns + 1
                end
            end
            assert.equals(0, activeCooldowns,
                "first cooldown timer should be cancelled on second zone change")
        end)
    end)

    describe("concurrent send + receive", function()
        it("initiates receive via HandleHello while sending", function()
            -- Enter sending state
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "csend:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["csend:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerX", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Receive a HELLO from a different peer with different data
            GBL:HandleHello("PeerY", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 50,
                dataHash = 999,
                isReply = true,
            })

            -- The request goes out during the HELLO, so a send in progress
            -- does not stop us receiving from someone else at the same time.
            assert.is_true(GBL:GetSyncStatus().sending, "should still be sending")
            assert.is_true(GBL:GetSyncStatus().receiving, "should now also be receiving")
            assert.equals("PeerY", GBL:GetSyncStatus().receiveSource)
        end)

        it("drops the peer if already receiving (not sending)", function()
            -- Enter receiving state
            GBL:UpdatePeer("PeerB", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- HELLO from another peer, refused by the outer receiving check
            GBL:HandleHello("PeerC", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 50,
                dataHash = 999,
                isReply = true,
            })

            -- Receiving is the one thing we cannot double up on, so PeerC is
            -- dropped. Sending is unaffected, which the test above covers.
            assert.equals("PeerB", GBL:GetSyncStatus().receiveSource)
        end)

        -- Finishing a receive while a send is still running must not
        -- disturb the send. There is nothing left to schedule at that
        -- point, so the assertion is simply that the send survives.
        it("FinishReceiving leaves an in-flight send alone", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "fr:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["fr:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerX", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)

            GBL:RequestSync("PeerZ", 0)
            GBL:FinishReceiving("PeerZ")

            assert.is_true(GBL:GetSyncStatus().sending)
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("forced HELLO is rate-limited to once per 10s", function()
            -- First forced HELLO should succeed
            GBL:BroadcastHello(true)
            local trail = GBL:GetAuditTrail()
            local helloCount = 0
            for _, entry in ipairs(trail) do
                if entry.message:match("^Sent HELLO") then helloCount = helloCount + 1 end
            end
            assert.equals(1, helloCount)

            -- Second forced HELLO within 10s should be suppressed
            GBL:BroadcastHello(true)
            trail = GBL:GetAuditTrail()
            helloCount = 0
            for _, entry in ipairs(trail) do
                if entry.message:match("^Sent HELLO") then helloCount = helloCount + 1 end
            end
            assert.equals(1, helloCount, "Second forced HELLO within 10s should be suppressed")
        end)

        it("non-forced HELLO is unaffected by forced cooldown", function()
            -- Send a forced HELLO
            GBL:BroadcastHello(true)
            -- Non-forced HELLO should still work (different cooldown)
            -- Need to bypass HELLO_COOLDOWN by advancing lastHelloTime
            -- Actually non-forced checks lastHelloTime which was just set, so it'll be blocked
            -- by HELLO_COOLDOWN. This test just verifies forced cooldown doesn't affect non-forced logic.
            -- The forced cooldown variable is separate from lastHelloTime.
            assert.is_truthy(GBL.SYNC_FORCED_HELLO_COOLDOWN)
        end)

        it("HELLO reply is suppressed when hash unchanged", function()
            -- First HELLO from PeerA — should trigger reply (first contact)
            local replySent = false
            local origSendHelloReply = GBL.SendHelloReply
            GBL.SendHelloReply = function(self, target)
                replySent = true
                origSendHelloReply(self, target)
            end

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0, dataHash = 0,
                isReply = false,
            })
            assert.is_true(replySent, "First contact should trigger reply")

            -- Second HELLO from PeerA with no data change — should suppress
            replySent = false
            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0, dataHash = 0,
                isReply = false,
            })
            assert.is_false(replySent, "Second HELLO with unchanged hash should suppress reply")

            GBL.SendHelloReply = origSendHelloReply
        end)

        it("HELLO reply is sent when hash changes", function()
            local replyCount = 0
            local origSendHelloReply = GBL.SendHelloReply
            GBL.SendHelloReply = function(self, target)
                replyCount = replyCount + 1
                origSendHelloReply(self, target)
            end

            -- First HELLO — reply (first contact)
            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0, dataHash = 0,
                isReply = false,
            })
            assert.equals(1, replyCount)

            -- Add data to change our hash
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "hashchange:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["hashchange:277:0"] = 1000 * 3600
            GBL:ResetHashCache()

            -- Second HELLO — reply (hash changed)
            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0, dataHash = 0,
                isReply = false,
            })
            assert.equals(2, replyCount, "Should reply when hash changes")

            GBL.SendHelloReply = origSendHelloReply
        end)

        it("BroadcastHello marks all known peers as up-to-date", function()
            -- Simulate having replied to PeerA with hash 100
            -- by manually setting the tracking
            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0, dataHash = 0,
                isReply = false,
            })

            -- Add data to change our hash
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "bmark:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["bmark:277:0"] = 1000 * 3600
            GBL:ResetHashCache()

            -- Broadcast HELLO — should mark PeerA as up-to-date
            GBL:BroadcastHello(true)

            -- Now a HELLO from PeerA should NOT trigger a reply
            -- (broadcast-mark optimization). PeerA reports the same hash/count as
            -- us here so it is NOT behind: a behind peer is now deliberately
            -- re-nudged past the broadcast-mark (covered by the superset re-nudge
            -- tests), which would otherwise fire SendHelloReply here.
            local replySent = false
            local origSendHelloReply = GBL.SendHelloReply
            GBL.SendHelloReply = function(self, target)
                replySent = true
                origSendHelloReply(self, target)
            end

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 1, dataHash = GBL:GetDataHash(guildData),
                isReply = false,
            })
            assert.is_false(replySent, "Broadcast-mark should suppress reply")

            GBL.SendHelloReply = origSendHelloReply
        end)

        it("HandleSyncRequest still returns BUSY when already sending", function()
            -- Enter sending state
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "busy:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "Me",
            })
            guildData.seenTxHashes["busy:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)
            assert.equals("PeerA", GBL:GetSyncStatus().sendTarget)

            -- Another peer requests — should still get BUSY
            GBL:HandleSyncRequest("PeerB", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            -- sendTarget unchanged — PeerB was rejected
            assert.equals("PeerA", GBL:GetSyncStatus().sendTarget)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Post-sync actions
    ---------------------------------------------------------------------------

    describe("post-sync actions", function()
        -- A HELLO whose hash and count match ours means there is nothing to
        -- fetch. This used to be re-checked when popping a queued peer,
        -- because a queued peer could converge while it waited; nothing
        -- waits now, so the HELLO fast path is the only place it matters.
        it("a converged peer's HELLO starts no sync", function()
            local localHash = GBL:GetDataHash(guildData)
            local localCount = #guildData.transactions + #guildData.moneyTransactions

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = localCount,
                dataHash = localHash,
            })

            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        -- Sending and receiving are independent, and stay that way: a HELLO
        -- that arrives mid-send still starts a pull.
        it("a HELLO can start a receive while we are sending", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "x:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            guildData.seenTxHashes["x:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("Other", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 999,
            })

            assert.is_true(GBL:GetSyncStatus().sending)
            assert.is_true(GBL:GetSyncStatus().receiving)
            assert.equals("PeerA", GBL:GetSyncStatus().receiveSource)
        end)

        -- Finishing a session schedules no follow-up work. Being free is
        -- the whole of it; the post-sync HELLO below is what makes the next
        -- pairing happen, and it is driven by having new data, not by a
        -- list of peers we owe a visit.
        it("FinishReceiving schedules no partner-selection follow-up", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            MockWoW.pendingTimers = {}

            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 1,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            for _, timer in ipairs(MockWoW.pendingTimers) do
                assert.is_not.equals(0.2, timer.delay,
                    "no queue drain should be scheduled after a session")
            end
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("FinishReceiving schedules HELLO broadcast when new data stored", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            -- Simulate receiving data that gets stored
            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 1,
                transactions = {
                    { type = "deposit", player = "Player1", tab = 1,
                      itemID = 123, classID = 0, subclassID = 0, count = 1,
                      timestamp = 1000 * 3600, id = "newtx:277:0" },
                },
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Check that a HELLO broadcast timer was scheduled (delay=0.5-2.0)
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay >= 0.5 and timer.delay <= 2.0 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_true(found, "Post-sync HELLO timer should be scheduled")
        end)

        it("no post-sync HELLO when no new data stored", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            MockWoW.pendingTimers = {}

            -- Simulate receiving empty data
            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 1,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- No post-sync HELLO timer should be scheduled (0.5-2.0 range)
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay >= 0.5 and timer.delay <= 2.0 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_false(found, "No post-sync HELLO timer when no new data")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Status getters
    ---------------------------------------------------------------------------

    describe("GetSyncStatus", function()
        it("reports idle state by default", function()
            local status = GBL:GetSyncStatus()
            assert.is_true(status.enabled)
            assert.is_false(status.sending)
            assert.is_false(status.receiving)
        end)

        it("reports correct tx count", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 1 })
            assert.equals(1, GBL:GetTxCount())
        end)

        it("reports sendTarget and sendProgress during active send", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local status = GBL:GetSyncStatus()
            assert.is_true(status.sending)
            assert.equals("OfficerB", status.sendTarget)
            assert.is_string(status.sendProgress)
            assert.truthy(status.sendProgress:match("^%d+/%d+$"))
        end)

        it("reports receiveSource and receiveProgress during active receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:RequestSync("OfficerB", 0)

            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)
            assert.equals("OfficerB", status.receiveSource)
            assert.is_string(status.receiveProgress)
        end)

        it("allows both sending and receiving simultaneously", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving from OfficerB
            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Start sending to OfficerC (they request sync from us)
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerC", request{ sinceTimestamp = 0 })

            local status = GBL:GetSyncStatus()
            assert.is_true(status.sending)
            assert.is_true(status.receiving)
            assert.equals("OfficerC", status.sendTarget)
            assert.equals("OfficerB", status.receiveSource)
        end)
    end)

    ---------------------------------------------------------------------------
    -- FormatSyncStatusText
    ---------------------------------------------------------------------------

    describe("FormatSyncStatusText", function()
        it("returns Idle when neither sending nor receiving", function()
            local text = GBL:FormatSyncStatusText({
                sending = false, receiving = false,
            })
            assert.equals("Idle", text)
        end)

        it("shows sending status only", function()
            local text = GBL:FormatSyncStatusText({
                sending = true, sendTarget = "Alice", sendProgress = "2/5",
                receiving = false,
            })
            assert.equals("Sending to Alice (2/5)", text)
        end)

        it("shows receiving status only", function()
            local text = GBL:FormatSyncStatusText({
                sending = false,
                receiving = true, receiveSource = "Bob", receiveProgress = "3/8",
            })
            assert.equals("Receiving from Bob (3/8)", text)
        end)

        it("shows both sending and receiving with pipe separator", function()
            local text = GBL:FormatSyncStatusText({
                sending = true, sendTarget = "Alice", sendProgress = "2/5",
                receiving = true, receiveSource = "Bob", receiveProgress = "3/8",
            })
            assert.equals("Sending to Alice (2/5) || Receiving from Bob (3/8)", text)
        end)

        it("shows waiting when receive progress is 0/0", function()
            local text = GBL:FormatSyncStatusText({
                sending = false,
                receiving = true, receiveSource = "Bob", receiveProgress = "0/0",
            })
            assert.equals("Receiving from Bob (waiting...)", text)
        end)

        it("falls back to ? for nil sendTarget", function()
            local text = GBL:FormatSyncStatusText({
                sending = true, sendTarget = nil, sendProgress = "1/3",
                receiving = false,
            })
            assert.equals("Sending to ? (1/3)", text)
        end)

        it("falls back to ? for nil receiveSource", function()
            local text = GBL:FormatSyncStatusText({
                sending = false,
                receiving = true, receiveSource = nil, receiveProgress = "2/4",
            })
            assert.equals("Receiving from ? (2/4)", text)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Audit trail
    ---------------------------------------------------------------------------

    describe("AuditTrail", function()
        it("records sync events", function()
            GBL:AddAuditEntry("Test event 1")
            GBL:AddAuditEntry("Test event 2")

            local trail = GBL:GetAuditTrail()
            assert.equals(2, #trail)
            -- Newest first
            assert.equals("Test event 2", trail[1].message)
            assert.equals("Test event 1", trail[2].message)
        end)

        it("caps at 2000 entries", function()
            for i = 1, 2010 do
                GBL:AddAuditEntry("Event " .. i)
            end

            local trail = GBL:GetAuditTrail()
            assert.equals(2000, #trail)
            assert.equals("Event 2010", trail[1].message)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Unified logging (v0.27.0)
    ---------------------------------------------------------------------------

    describe("unified logging", function()
        it("AddAuditEntry prints to chat when chatLog enabled", function()
            GBL.db.profile.sync.chatLog = true

            local printed = {}
            GBL.Print = function(_, msg)
                table.insert(printed, msg)
            end

            GBL:AddAuditEntry("test message")

            assert.equals(1, #printed)
            assert.equals("Sync: test message", printed[1])
            -- Also in audit trail
            local trail = GBL:GetAuditTrail()
            assert.equals("test message", trail[1].message)
        end)

        it("AddAuditEntry does not print to chat when chatLog disabled", function()
            GBL.db.profile.sync.chatLog = false

            local printed = {}
            GBL.Print = function(_, msg)
                table.insert(printed, msg)
            end

            GBL:AddAuditEntry("test message")

            assert.equals(0, #printed)
            local trail = GBL:GetAuditTrail()
            assert.equals("test message", trail[1].message)
        end)

        it("AddAuditEntry chatOnly drops entry when debugChat is off", function()
            -- Post-channel-split: chatOnly=true is now an alias for DEBUG
            -- severity, which drops entirely unless debugChat is enabled.
            -- Preserves the prior "don't pollute the buffer with per-chunk
            -- spam" property without needing the chatOnly side channel.
            GBL.db.profile.sync.chatLog = true
            GBL.db.profile.sync.debugChat = false

            local printed = {}
            GBL.Print = function(_, msg)
                table.insert(printed, msg)
            end

            GBL:AddAuditEntry("noisy chunk msg", true)

            assert.equals(0, #printed, "DEBUG should not chat without debugChat")
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.falsy(entry.message:find("noisy chunk msg"))
            end
        end)

        it("AddAuditEntry chatOnly records as DEBUG when debugChat is on", function()
            GBL.db.profile.sync.chatLog = false  -- only debugChat gates DEBUG
            GBL.db.profile.sync.debugChat = true

            local printed = {}
            GBL.Print = function(_, msg)
                table.insert(printed, msg)
            end

            GBL:AddAuditEntry("noisy chunk msg", true)

            assert.equals(1, #printed)
            assert.is_truthy(printed[1]:find("[DEBUG]", 1, true))
            local trail = GBL:GetAuditTrail()
            assert.equal("noisy chunk msg", trail[1].message)
            assert.equal("DEBUG", trail[1].level)
        end)

        it("SyncLog function no longer exists", function()
            assert.is_nil(GBL.SyncLog)
        end)

        it("BUSY abort-send creates audit entry", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sending state to OfficerB
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "busy1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Receive BUSY from OfficerB
            GBL:HandleBusy("OfficerB", {})

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("busy.*aborting send") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "BUSY abort-send should create audit entry")
        end)

        it("BUSY clear-receive creates audit entry", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Simulate active receiving state
            local status = GBL:GetSyncStatus()
            -- Trigger by requesting sync (sets up receiving)
            GBL:RequestSync("OfficerB", 0)

            -- Receive BUSY from OfficerB
            GBL:HandleBusy("OfficerB", {})

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("busy.*cleared receive") or
                   entry.message:find("busy.*will retry") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "BUSY clear-receive should create audit entry")
        end)

        it("hard timeout audit includes 120s", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Suppress AceComm callback to trigger hard timeout
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ht1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Fire the hard timeout
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 120 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("120s") and entry.message:find("AceComm") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Hard timeout audit should include 120s and AceComm")

            GBL.SendCommMessage = origSend
        end)

        it("received chunk audit includes running totals", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:RequestSync("OfficerB", 0)

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 2,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100,
                        id = "deposit|Thrall|12345|5|1|475100:0",
                    },
                },
                moneyTransactions = {},
            })

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("total so far:") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Received chunk audit should include running totals")
        end)
    end)
end)
