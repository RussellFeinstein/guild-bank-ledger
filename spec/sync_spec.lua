------------------------------------------------------------------------
-- spec/sync_spec.lua — Tests for Sync.lua (M5)
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW

describe("Sync", function()
    local GBL
    local guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "Test Guild"
        MockWoW.player.name = "OfficerA"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL.db.profile.sync.enabled = true
        GBL.db.profile.sync.autoSync = true
        guildData = GBL:GetGuildData()
        -- Reset sync session state
        GBL:ResetSyncState()
        -- Clear sent messages from initialization
        MockAce.sentCommMessages = {}
        MockAce.sentMessages = {}
    end)

    ---------------------------------------------------------------------------
    -- HELLO
    ---------------------------------------------------------------------------

    describe("BroadcastHello", function()
        it("sends HELLO with correct tx count and version", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("GBLSync", sent.prefix)
            assert.equals("GUILD", sent.distribution)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.equals(GBL.version, data.version)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, data.protocolVersion)
            assert.equals(0, data.txCount)
        end)

        it("includes correct tx count when guild has transactions", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 100 })
            table.insert(guildData.moneyTransactions, { type = "deposit", player = "X", timestamp = 100 })

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(2, data.txCount)
        end)

        it("respects cooldown — second HELLO within 60s is suppressed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()
            GBL:BroadcastHello()

            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("does nothing when sync is disabled", function()
            GBL.db.profile.sync.enabled = false
            GBL:BroadcastHello()
            assert.equals(0, #MockAce.sentCommMessages)
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleHello
    ---------------------------------------------------------------------------

    describe("HandleHello", function()
        it("updates peer list with sender info", function()
            GBL:HandleHello("OfficerB", {
                version = "0.5.0",
                txCount = 10,
                lastScanTime = 1000,
            })

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.equals("0.5.0", peers["OfficerB"].version)
            assert.equals(10, peers["OfficerB"].txCount)
        end)

        it("triggers SYNC_REQUEST when remote has more transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 50,
                lastScanTime = 1000,
            })

            -- Should have sent a SYNC_REQUEST whisper
            assert.is_true(#MockAce.sentCommMessages > 0)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("SYNC_REQUEST", data.type)
        end)

        it("does NOT trigger sync when counts are equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("does NOT trigger sync when remote has fewer", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 100 })
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("warns on major version mismatch and refuses sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = "1.0.0",
                txCount = 999,
                lastScanTime = 1000,
            })

            -- Should NOT send a SYNC_REQUEST despite high txCount
            assert.equals(0, #MockAce.sentCommMessages)
            -- Should have an audit entry about the mismatch
            local trail = GBL:GetAuditTrail()
            assert.is_true(#trail > 0)
            assert.truthy(trail[1].message:find("major version mismatch"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleSyncRequest + chunking
    ---------------------------------------------------------------------------

    describe("HandleSyncRequest", function()
        it("sends matching transactions as SYNC_DATA", function()
            -- Add some transactions
            for i = 1, 3 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "Player" .. i,
                    itemID = 1000 + i, count = i, tab = 1,
                    timestamp = 1000 + i, scanTime = 1000 + i,
                    scannedBy = "OfficerA", id = "hash" .. i,
                })
            end

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Should have sent at least one SYNC_DATA message
            assert.is_true(#MockAce.sentCommMessages > 0)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.equals(3, #data.transactions)
            assert.equals(1, data.chunk)
            assert.equals(1, data.totalChunks)
        end)

        it("filters by sinceTimestamp", function()
            table.insert(guildData.transactions, {
                type = "deposit", player = "Old", timestamp = 500,
                id = "old1",
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "New", timestamp = 2000,
                id = "new1",
            })

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 1000 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(1, #data.transactions)
            assert.equals("New", data.transactions[1].player)
        end)

        it("sends empty sync when no matching transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.equals(0, #data.transactions)
            assert.equals(0, #data.moneyTransactions)
        end)
    end)

    describe("PrepareChunks", function()
        it("splits at CHUNK_SIZE boundary", function()
            local txList = {}
            for i = 1, 250 do
                txList[i] = { type = "deposit", player = "P", timestamp = i, id = "h" .. i }
            end

            local chunks = GBL:PrepareChunks(txList, {})
            assert.equals(2, #chunks)
            assert.equals(200, #chunks[1].transactions)
            assert.equals(50, #chunks[2].transactions)
        end)

        it("returns empty table for no transactions", function()
            local chunks = GBL:PrepareChunks({}, {})
            assert.equals(0, #chunks)
        end)

        it("mixes item and money transactions across chunks", function()
            local txList = {}
            for i = 1, 150 do
                txList[i] = { type = "deposit", player = "P", timestamp = i }
            end
            local moneyList = {}
            for i = 1, 100 do
                moneyList[i] = { type = "deposit", player = "P", amount = i * 100, timestamp = i }
            end

            local chunks = GBL:PrepareChunks(txList, moneyList)
            assert.equals(2, #chunks)
            -- First chunk: 150 item tx + 50 money tx = 200
            assert.equals(150, #chunks[1].transactions)
            assert.equals(50, #chunks[1].moneyTransactions)
            -- Second chunk: remaining 50 money tx
            assert.equals(0, #chunks[2].transactions)
            assert.equals(50, #chunks[2].moneyTransactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleSyncData (receiver side)
    ---------------------------------------------------------------------------

    describe("HandleSyncData", function()
        it("stores non-duplicate transactions via StoreTx", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 2000, scanTime = 2000,
                        scannedBy = "OfficerB",
                        id = "deposit|Thrall|12345|5|1|0",
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            assert.equals("Thrall", guildData.transactions[1].player)
        end)

        it("drops duplicate transactions via dedup", function()
            -- Pre-mark a hash as seen
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|0"] = 2000

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 2000, scanTime = 2000,
                        scannedBy = "OfficerB",
                        id = "deposit|Thrall|12345|5|1|0",
                    },
                },
                moneyTransactions = {},
            })

            -- Should NOT have stored (duplicate)
            assert.equals(0, #guildData.transactions)
        end)

        it("sends ACK after processing chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            -- Should have sent an ACK
            assert.is_true(#MockAce.sentCommMessages > 0)
            local ack = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", ack.distribution)
            assert.equals("OfficerB", ack.target)

            local ok, data = GBL:Deserialize(ack.text)
            assert.is_true(ok)
            assert.equals("ACK", data.type)
            assert.equals(1, data.chunk)
        end)

        it("fires GBL_SYNC_COMPLETE on last chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            -- Check for GBL_SYNC_COMPLETE message
            local found = false
            for _, msg in ipairs(MockAce.sentMessages) do
                if msg.message == "GBL_SYNC_COMPLETE" then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("updates syncState.lastSyncTimestamp on completion", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            assert.is_true(guildData.syncState.lastSyncTimestamp > 0)
        end)

        it("stores money transactions from sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {
                    {
                        type = "repair", player = "Jaina",
                        amount = 50000, timestamp = 3000,
                        scanTime = 3000, scannedBy = "OfficerB",
                        id = "repair|Jaina|50000|0",
                    },
                },
            })

            assert.equals(1, #guildData.moneyTransactions)
            assert.equals("Jaina", guildData.moneyTransactions[1].player)
        end)
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

        it("caps at 50 entries", function()
            for i = 1, 60 do
                GBL:AddAuditEntry("Event " .. i)
            end

            local trail = GBL:GetAuditTrail()
            assert.equals(50, #trail)
            assert.equals("Event 60", trail[1].message)
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
            assert.equals("Thrall", guildData.transactions[1].player)
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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 5000 })

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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            MockAce.sentCommMessages = {}

            -- OfficerC sends an ACK (not our target)
            GBL:HandleAck("OfficerC", { chunk = 1 })

            -- Should not have sent next chunk (wrong sender)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("DisableSync during active send cleans up state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

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

        it("corrupted message data is silently dropped", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Send a non-serialized string
            GBL:OnSyncMessage("GBLSync", "not-valid-data", "GUILD", "OfficerB")

            -- Should not crash, should not update peers
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"])
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

        it("resets lastSyncTimestamp to 0 when still behind after sync", function()
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

            -- Still behind (30 < 50) — lastSyncTimestamp should reset to 0
            assert.equals(0, guildData.syncState.lastSyncTimestamp)

            -- Audit trail should mention the fallback
            local trail = GBL:GetAuditTrail()
            local found = false
            for _, e in ipairs(trail) do
                if e.message:find("next sync will be full") then found = true end
            end
            assert.is_true(found)
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

        it("receive timeout resets stuck receive state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving (multi-chunk)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })
            assert.is_true(GBL:IsSyncing())

            -- Simulate timeout by firing the pending timer
            local timers = MockWoW.pendingTimers
            -- Find and fire the receive timeout timer
            local found = false
            for i = #timers, 1, -1 do
                local timer = timers[i]
                if timer and timer.callback and not timer.cancelled then
                    timer.callback()
                    found = true
                    break
                end
            end
            assert.is_true(found, "should have a receive timeout timer")

            -- Should no longer be syncing
            assert.is_false(GBL:IsSyncing())
        end)
    end)

    ---------------------------------------------------------------------------
    -- MajorVersion helper
    ---------------------------------------------------------------------------

    describe("MajorVersion", function()
        it("extracts major version from semver string", function()
            assert.equals(0, GBL:MajorVersion("0.5.0"))
            assert.equals(1, GBL:MajorVersion("1.0.0"))
            assert.equals(2, GBL:MajorVersion("2.3.1"))
        end)

        it("returns 0 for nil or invalid input", function()
            assert.equals(0, GBL:MajorVersion(nil))
            assert.equals(0, GBL:MajorVersion(""))
            assert.equals(0, GBL:MajorVersion("abc"))
        end)
    end)
end)
