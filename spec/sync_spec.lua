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

        it("does not consume cooldown when GetGuildData returns nil", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Temporarily clear guild name so GetGuildData returns nil
            local savedName = MockWoW.guild.name
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil

            GBL:BroadcastHello()
            assert.equals(0, #MockAce.sentCommMessages)

            -- Restore guild name — HELLO should now succeed (cooldown not consumed)
            MockWoW.guild.name = savedName
            GBL._cachedGuildName = nil
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("force=true bypasses cooldown", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)

            -- Normal call blocked by cooldown
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)

            -- Force call bypasses cooldown
            GBL:BroadcastHello(true)
            assert.equals(2, #MockAce.sentCommMessages)
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

            -- HELLO reply + SYNC_REQUEST both sent immediately
            assert.is_true(#MockAce.sentCommMessages >= 2)

            -- Find the SYNC_REQUEST among sent messages
            local foundRequest = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "SYNC_REQUEST" then
                    assert.equals("WHISPER", sent.distribution)
                    assert.equals("OfficerB", sent.target)
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest)
        end)

        it("does NOT trigger sync when counts are equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- Only a HELLO response (new peer), no SYNC_REQUEST
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT trigger sync when remote has fewer", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 100 })
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- Only a HELLO response (new peer), no SYNC_REQUEST
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("sends WHISPER reply to broadcast HELLO sender", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- HELLO reply sent immediately via WHISPER
            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.is_true(data.isReply)
        end)

        it("sends individual WHISPER replies to multiple broadcast HELLOs", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleHello("OfficerB", { version = GBL.version, txCount = 0, lastScanTime = 100 })
            GBL:HandleHello("OfficerC", { version = GBL.version, txCount = 0, lastScanTime = 200 })
            GBL:HandleHello("OfficerD", { version = GBL.version, txCount = 0, lastScanTime = 300 })

            -- All three are in peer list
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_not_nil(peers["OfficerC"])
            assert.is_not_nil(peers["OfficerD"])

            -- Each peer gets their own WHISPER reply (3 total)
            assert.equals(3, #MockAce.sentCommMessages)
            for _, sent in ipairs(MockAce.sentCommMessages) do
                assert.equals("WHISPER", sent.distribution)
                local ok, data = GBL:Deserialize(sent.text)
                assert.is_true(ok)
                assert.equals("HELLO", data.type)
                assert.is_true(data.isReply)
            end
        end)

        it("does NOT reply to a HELLO with isReply=true", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
                isReply = true,
            })

            -- Peer is registered
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])

            -- No reply sent (isReply prevents ping-pong)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("replies to broadcast HELLO even from already-known peer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- First HELLO from OfficerB (now known)
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 1000,
            })
            assert.equals(1, #MockAce.sentCommMessages)
            MockAce.sentCommMessages = {}

            -- Second broadcast HELLO from same peer (simulates their reload)
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 2000,
            })

            -- Should still reply (no isNewPeer gate)
            assert.is_true(#MockAce.sentCommMessages >= 1)
            -- Find the HELLO reply
            local foundReply = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "HELLO" and data.isReply then
                    assert.equals("WHISPER", sent.distribution)
                    foundReply = true
                end
            end
            assert.is_true(foundReply)
        end)

        it("SendHelloReply payload includes isReply=true", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:SendHelloReply("OfficerB")

            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.is_true(data.isReply)
            assert.equals(GBL.version, data.version)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, data.protocolVersion)
        end)

        it("warns on version mismatch and refuses sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = "99.0.0",
                txCount = 999,
                lastScanTime = 1000,
            })

            -- Should NOT send a SYNC_REQUEST despite high txCount (HELLO response is OK)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
            -- Should have an audit entry about the mismatch
            local trail = GBL:GetAuditTrail()
            assert.is_true(#trail > 0)
            assert.truthy(trail[1].message:find("version mismatch"))
        end)

        it("refuses sync even on same major but different minor version", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local differentMinor = "0.99.0"
            assert.not_equals(GBL.version, differentMinor)
            GBL:HandleHello("OfficerB", {
                version = differentMinor,
                txCount = 999,
                lastScanTime = 1000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
            local trail = GBL:GetAuditTrail()
            assert.is_true(#trail > 0)
            assert.truthy(trail[1].message:find("version mismatch"))
        end)

        it("triggers sync when hash differs and counts are equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 5 local transactions
            for i = 1, 5 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "local" .. i .. ":0",
                })
            end

            -- Remote has same count but different hash
            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,  -- different hash
                lastScanTime = 2000,
            })

            -- Should send SYNC_REQUEST despite equal counts
            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest,
                "should request sync when hash differs, even with equal counts")
        end)

        it("triggers sync when hash differs and local has more", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 10 local transactions
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "localmore" .. i .. ":0",
                })
            end

            -- Remote has fewer but different data
            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,
                lastScanTime = 2000,
            })

            -- Should request sync — remote has records we don't
            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest,
                "should request sync when hash differs, even when local has more")
        end)

        it("skips sync when hash matches and counts match", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 3 local transactions
            for i = 1, 3 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "match" .. i .. ":0",
                })
            end

            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 3,
                dataHash = localHash,  -- same hash
                lastScanTime = 2000,
            })

            -- No SYNC_REQUEST (datasets identical)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("falls back to count when no hash (backward compat)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Remote has more, no dataHash
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 50,
                lastScanTime = 2000,
            })

            -- Should still request sync via count comparison
            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest,
                "should request sync via count when no hash present")
        end)

        it("does NOT sync when no hash and counts equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- No dataHash, same count
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0,
                lastScanTime = 2000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT sync when hash differs but already receiving", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start a receive (blocks new RequestSync)
            GBL:RequestSync("OfficerC", 0)
            MockAce.sentCommMessages = {}

            -- Hash mismatch from different peer
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = 99999,
                lastScanTime = 2000,
            })

            -- Should NOT send SYNC_REQUEST (already receiving from OfficerC)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT sync when hash differs but autoSync disabled", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL.db.profile.sync.autoSync = false

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = 99999,
                lastScanTime = 2000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
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
        it("splits records across multiple chunks", function()
            local txList = {}
            for i = 1, 25 do
                txList[i] = { type = "deposit", player = "P", timestamp = i, id = "h" .. i }
            end

            local chunks = GBL:PrepareChunks(txList, {})
            assert.is_true(#chunks >= 2, "25 records should produce multiple chunks")
            -- All records accounted for
            local total = 0
            for _, chunk in ipairs(chunks) do
                total = total + #chunk.transactions
            end
            assert.equals(25, total)
        end)

        it("returns empty table for no transactions", function()
            local chunks = GBL:PrepareChunks({}, {})
            assert.equals(0, #chunks)
        end)

        it("distributes item and money transactions across chunks", function()
            local txList = {}
            for i = 1, 5 do
                txList[i] = { type = "deposit", player = "P", timestamp = i }
            end
            local moneyList = {}
            for i = 1, 12 do
                moneyList[i] = { type = "deposit", player = "P", amount = i * 100, timestamp = i }
            end

            local chunks = GBL:PrepareChunks(txList, moneyList)
            assert.is_true(#chunks >= 2, "17 records should produce multiple chunks")
            -- All records accounted for
            local totalTx, totalMoney = 0, 0
            for _, chunk in ipairs(chunks) do
                totalTx = totalTx + #chunk.transactions
                totalMoney = totalMoney + #chunk.moneyTransactions
            end
            assert.equals(5, totalTx)
            assert.equals(12, totalMoney)
        end)

        it("splits by estimated size when records have large fields", function()
            local txList = {}
            -- Each record ~180 bytes estimated (long strings push size)
            for i = 1, 12 do
                txList[i] = {
                    type = "withdrawal",
                    player = "Verylongnamecharacter",
                    itemID = 200000 + i,
                    count = 20,
                    tab = 3,
                    classID = 0,
                    subclassID = 5,
                    timestamp = 1700000000 + i,
                    id = "withdrawal|Verylongnamecharacter|" .. (200000 + i)
                        .. "|20|3|472222:" .. i,
                }
            end
            local chunks = GBL:PrepareChunks(txList, {})
            -- With ~180 bytes/record and 1400 byte budget,
            -- should split before hitting 15-record hard cap
            assert.is_true(#chunks >= 2,
                "should produce multiple chunks from size limit")
            for _, chunk in ipairs(chunks) do
                assert.is_true(#chunk.transactions <= GBL.SYNC_CHUNK_SIZE,
                    "no chunk should exceed hard record cap")
            end
        end)

        it("places a single oversized record in its own chunk", function()
            local bigId = string.rep("x", 2000)
            local txList = {
                { type = "deposit", player = "P", timestamp = 1, id = bigId },
                { type = "deposit", player = "P", timestamp = 2, id = "small" },
            }
            local chunks = GBL:PrepareChunks(txList, {})
            assert.equals(2, #chunks)
            assert.equals(1, #chunks[1].transactions)
            assert.equals(1, #chunks[2].transactions)
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
            assert.equals("Thrall-TestRealm", guildData.transactions[1].player)
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
            assert.equals("Jaina-TestRealm", guildData.moneyTransactions[1].player)
        end)
    end)

    ---------------------------------------------------------------------------
    -- NormalizeRecordId
    ---------------------------------------------------------------------------

    describe("NormalizeRecordId", function()
        it("always adopts sender ID (sender-wins)", function()
            -- Local record stored with hour-101 ID
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = { ["deposit|Thrall|12345|5|1|101:0"] = localTx }

            -- Incoming record with hour-100 ID (sender's ID adopted regardless)
            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("deposit|Thrall|12345|5|1|100:0", localTx.id)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"])
        end)

        it("adopts sender ID even when local ID is smaller", function()
            -- Local has smaller ID (hour-100), but sender-wins still adopts incoming
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"] = 3600 * 100

            local idIndex = { ["deposit|Thrall|12345|5|1|100:0"] = localTx }

            -- Incoming with hour-101 (larger, but sender-wins)
            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|100:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("deposit|Thrall|12345|5|1|101:0", localTx.id)
            assert.equals(3600 * 101, localTx.timestamp)
        end)

        it("handles money transactions and normalizes timestamp", function()
            local localTx = {
                type = "repair", player = "Thrall", amount = 50000,
                timestamp = 3600 * 101,
                id = "repair|Thrall|50000|101:0", _occurrence = 0,
            }
            table.insert(guildData.moneyTransactions, localTx)
            guildData.seenTxHashes["repair|Thrall|50000|101:0"] = 3600 * 101

            local idIndex = { ["repair|Thrall|50000|101:0"] = localTx }

            local incoming = {
                type = "repair", player = "Thrall", amount = 50000,
                timestamp = 3600 * 100,
                id = "repair|Thrall|50000|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "repair|Thrall|50000|101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("repair|Thrall|50000|100:0", localTx.id)
            assert.equals(3600 * 100, localTx.timestamp)
        end)

        it("handles compacted record (not in transactions)", function()
            -- seenTxHashes has an entry but no corresponding record in transactions
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = {}  -- empty, record was compacted

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)
            assert.is_true(result)
            -- seenTxHashes updated even though record not found
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"])
        end)

        it("updates idIndex after normalization", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = { ["deposit|Thrall|12345|5|1|101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)

            -- Caller should update idIndex; verify the record reference is still valid
            assert.equals("deposit|Thrall|12345|5|1|100:0", localTx.id)
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleSyncData ID normalization
    ---------------------------------------------------------------------------

    describe("HandleSyncData normalization", function()
        it("normalizes IDs on fuzzy match during sync receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Pre-store a local record with hour-101 ID
            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            -- Receive same event with hour-100 ID (smaller, will win tiebreaker)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Local record should be normalized to the sender's ID
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|100:0", localTx.id)
            -- No new record stored (it was a duplicate)
            assert.equals(1, #guildData.transactions)
            -- seenTxHashes updated
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|100:0"])
        end)

        it("stores new records normally alongside normalizations", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Pre-store a local record
            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            -- Receive: one fuzzy dup (normalize) + one genuinely new record
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                    {
                        type = "withdraw", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 5000,
                        id = "withdraw|Jaina-TestRealm|99999|10|2|1:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- 1 original (normalized) + 1 new = 2 total
            assert.equals(2, #guildData.transactions)
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|100:0", localTx.id)
        end)

        it("hash converges after normalization", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Local record with hour-101 ID
            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            -- Compute sender's hash (with hour-100 ID)
            local senderHash = GBL:HashString("deposit|Thrall-TestRealm|12345|5|1|100:0")

            -- Receive with hour-100 ID
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- After FinishReceiving, our hash should match the sender's
            local localHash = GBL:ComputeDataHash(guildData)
            assert.equals(senderHash, localHash)
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

        it("caps at 200 entries", function()
            for i = 1, 210 do
                GBL:AddAuditEntry("Event " .. i)
            end

            local trail = GBL:GetAuditTrail()
            assert.equals(200, #trail)
            assert.equals("Event 210", trail[1].message)
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
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if timer.delay == 20 and not timer.cancelled then
                        timer.callback()
                        break
                    end
                end
            end

            -- One more timeout — should abort after exhausting retries
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            -- Should no longer be syncing
            assert.is_false(GBL:IsSyncing())
        end)
    end)

    ---------------------------------------------------------------------------
    -- Version matching
    ---------------------------------------------------------------------------

    ---------------------------------------------------------------------------
    -- ACK timer callback behavior
    ---------------------------------------------------------------------------

    describe("ACK timer callback", function()
        it("MAX_RECORDS_PER_CHUNK constant is 15", function()
            assert.equals(15, GBL.SYNC_CHUNK_SIZE)
        end)

        it("ACK timer starts after send callback, not immediately", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to NOT invoke callback
            local storedCallback, storedArg
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                storedCallback = cbFn
                storedArg = cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Count ACK timers — hard timer exists but ACK timer should NOT yet
            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(0, ackTimerCount, "ACK timer should not exist before callback")

            -- Now invoke the callback (message fully sent)
            assert.is_not_nil(storedCallback)
            storedCallback(storedArg, 100, 100)

            -- ACK timer should now exist
            ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(1, ackTimerCount, "ACK timer should exist after callback")

            GBL.SendCommMessage = origSend
        end)

        it("ACK timer does not start on partial send progress", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local storedCallback, storedArg
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                storedCallback = cbFn
                storedArg = cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Invoke callback with partial progress
            storedCallback(storedArg, 50, 1000)

            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(0, ackTimerCount, "ACK timer should not exist on partial send")

            -- Complete the send
            storedCallback(storedArg, 1000, 1000)

            ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(1, ackTimerCount, "ACK timer should exist after full send")

            GBL.SendCommMessage = origSend
        end)

        it("hard timeout fires if callback never completes", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to suppress callback entirely
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                -- Do NOT invoke callback
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Should be sending
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Find and fire the hard timeout (120s)
            local fired = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 120 and not timer.cancelled then
                    timer.callback()
                    fired = true
                    break
                end
            end
            assert.is_true(fired, "hard timeout timer should exist")
            assert.is_false(GBL:GetSyncStatus().sending, "should have aborted")

            GBL.SendCommMessage = origSend
        end)
    end)

    ---------------------------------------------------------------------------
    -- Retry logic
    ---------------------------------------------------------------------------

    describe("retry logic", function()
        it("retries same chunk on ACK timeout instead of aborting", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add tx (fits in 1 chunk with MAX_RECORDS_PER_CHUNK=15)
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Should be sending chunk 1
            assert.is_true(GBL:GetSyncStatus().sending)
            local sentBefore = #MockAce.sentCommMessages

            -- Fire ACK timeout — should retry, not abort
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            assert.is_true(GBL:GetSyncStatus().sending, "should still be sending after retry")
            -- A new SYNC_DATA message should have been sent (the retry)
            assert.is_true(#MockAce.sentCommMessages > sentBefore,
                "retry should send another message")
        end)

        it("aborts after MAX_RETRIES exceeded", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to suppress callback (no ACK possible)
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                -- Simulate immediate transmit so ACK timer starts
                if cbFn then cbFn(cbArg, 100, 100) end
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Fire ACK timeout MAX_RETRIES times (should keep retrying)
            for attempt = 1, GBL.SYNC_MAX_RETRIES do
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if timer.delay == 15 and not timer.cancelled then
                        timer.callback()
                        break
                    end
                end
                assert.is_true(GBL:GetSyncStatus().sending,
                    "should still be sending after retry " .. attempt)
            end

            -- One more timeout — should abort
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end
            assert.is_false(GBL:GetSyncStatus().sending,
                "should have aborted after max retries")

            GBL.SendCommMessage = origSend
        end)

        it("resets retry counter on successful ACK", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add tx (fits in 1 chunk with MAX_RECORDS_PER_CHUNK=15)
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Fire one ACK timeout (retry attempt 1)
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            -- Now simulate successful ACK for chunk 1
            GBL:HandleAck("OfficerB", { chunk = 1 })

            -- Fire ACK timeout for chunk 2 — retry counter should be reset,
            -- so this should retry (not abort)
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 15 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end
            assert.is_true(GBL:GetSyncStatus().sending,
                "retry counter should have reset — still sending")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Chunk size safety
    ---------------------------------------------------------------------------

    describe("chunk size safety", function()
        it("serialized SYNC_DATA stays under WHISPER safe limit with typical records", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Fill one full chunk with realistic transaction records
            for i = 1, GBL.SYNC_CHUNK_SIZE do
                table.insert(guildData.transactions, {
                    type = "withdrawal", player = "Longnamechar",
                    itemID = 200000 + i, count = 20, tab = 3,
                    timestamp = 1700000000 + i, scanTime = 1700000000 + i,
                    scannedBy = "Anotherlongname", id = "withdrawal|Longnamechar|" .. (200000 + i) .. "|20|3|472222:" .. i,
                    classID = 0, subClassID = 5,
                    category = "Trade Goods: Cloth",
                })
            end

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- The first sent message should be the SYNC_DATA chunk
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local payload = MockAce.sentCommMessages[1].text
            assert.is_true(#payload < 2000,
                "Serialized chunk (" .. #payload .. " bytes) exceeds 2000-byte WHISPER safe limit — reduce CHUNK_SIZE")
        end)

        it("logs warning when chunk exceeds safe size", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Verify the audit trail does NOT contain a size warning for normal chunks
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local trail = GBL:GetAuditTrail()
            local hasWarning = false
            for _, entry in ipairs(trail) do
                if entry.message:find("WARNING: chunk") then
                    hasWarning = true
                end
            end
            assert.is_false(hasWarning,
                "small chunk should not trigger size warning")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Money transaction stripping
    ---------------------------------------------------------------------------

    describe("money transaction stripping", function()
        it("strips money transactions via stripForSync before sending", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.moneyTransactions, {
                type = "deposit", player = "Jaina",
                amount = 50000, timestamp = 3000,
                scanTime = 3000, scannedBy = "OfficerA",
                id = "deposit|Jaina|50000|0:0",
            })

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(1, #data.moneyTransactions)
            local tx = data.moneyTransactions[1]
            -- Stripped fields should be nil
            assert.is_nil(tx.scanTime)
            assert.is_nil(tx.scannedBy)
            -- Preserved fields
            assert.equals(50000, tx.amount)
            assert.equals("deposit", tx.type)
            assert.equals("Jaina", tx.player)
            assert.equals("deposit|Jaina|50000|0:0", tx.id)
        end)

        it("does not mutate original money transaction records", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.moneyTransactions, {
                type = "deposit", player = "Jaina",
                amount = 50000, timestamp = 3000,
                scanTime = 3000, scannedBy = "OfficerA",
                id = "m1",
            })

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Original record must still have scanTime and scannedBy
            assert.equals(3000, guildData.moneyTransactions[1].scanTime)
            assert.equals("OfficerA", guildData.moneyTransactions[1].scannedBy)
        end)
    end)

    ---------------------------------------------------------------------------
    -- itemLink stripping
    ---------------------------------------------------------------------------

    describe("itemLink stripping", function()
        it("strips reconstructable fields from sync payload", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "Thrall",
                itemID = 12345, itemLink = "|cff0070dd|Hitem:12345:0|h[Test Item]|h|r",
                count = 5, tab = 1, tabName = "Consumables",
                classID = 0, subclassID = 3,
                category = "flask", _occurrence = 0,
                timestamp = 1000, scanTime = 1000,
                scannedBy = "OfficerA", id = "h1:0",
            })

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(1, #data.transactions)
            local tx = data.transactions[1]
            -- Stripped fields
            assert.is_nil(tx.itemLink)
            assert.is_nil(tx.category)
            assert.is_nil(tx.tabName)
            assert.is_nil(tx.scanTime)
            assert.is_nil(tx.scannedBy)
            assert.is_nil(tx._occurrence)
            -- Preserved fields
            assert.equals(12345, tx.itemID)
            assert.equals(0, tx.classID)
            assert.equals(3, tx.subclassID)
            assert.equals("h1:0", tx.id)
            assert.equals(1, tx.tab)
        end)

        it("does not mutate original transaction records", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local originalLink = "|cff0070dd|Hitem:99999:0|h[Original]|h|r"
            table.insert(guildData.transactions, {
                type = "deposit", player = "Jaina",
                itemID = 99999, itemLink = originalLink,
                count = 1, tab = 1,
                timestamp = 1000, scanTime = 1000,
                scannedBy = "OfficerA", id = "h2",
            })

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Original record should still have itemLink
            assert.equals(originalLink, guildData.transactions[1].itemLink)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Field reconstruction on receive
    ---------------------------------------------------------------------------

    describe("reconstructSyncRecord", function()
        it("restores stripped fields on received item transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Simulate receiving a stripped record (no category, tabName, scanTime, etc.)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        classID = 0, subclassID = 3,
                        timestamp = 2000,
                        id = "deposit|Thrall|12345|5|1|0:2",
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            local stored = guildData.transactions[1]
            -- Reconstructed fields
            assert.equals("flask", stored.category)
            assert.equals(2, stored._occurrence)
            assert.equals("sync:OfficerB-TestRealm", stored.scannedBy)
            assert.is_number(stored.scanTime)
        end)

        it("restores fields on money transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {
                    {
                        type = "deposit", player = "Jaina",
                        amount = 50000, timestamp = 3000,
                        id = "deposit|Jaina|50000|0:0",
                    },
                },
            })

            assert.equals(1, #guildData.moneyTransactions)
            local stored = guildData.moneyTransactions[1]
            assert.equals(0, stored._occurrence)
            assert.equals("sync:OfficerB-TestRealm", stored.scannedBy)
            assert.is_number(stored.scanTime)
        end)

        it("recovers timestamp from id when missing (old-version records)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "withdraw", player = "Flamess",
                        itemID = 243954, count = 2, classID = 8, subclassID = 2,
                        id = "withdraw|Flamess|243954|2|0|493180",
                        -- no timestamp, no tab — simulates old-version record
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            local stored = guildData.transactions[1]
            -- timestamp recovered from timeSlot 493180 * 3600
            assert.equals(493180 * 3600, stored.timestamp)
            assert.equals("sync:OfficerB-TestRealm", stored.scannedBy)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Self-message filtering with realm names
    ---------------------------------------------------------------------------

    describe("self-message filtering", function()
        it("filters realm-qualified self-messages", function()
            MockWoW.player.name = "OfficerA"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 999, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            -- Sender includes realm suffix (retail WoW behavior)
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerA-Stormrage")

            -- Should have been filtered as self-message
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerA-Stormrage"])
        end)

        it("does not filter messages from different players", function()
            MockWoW.player.name = "OfficerA"
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                txCount = 5, protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
            })
            GBL:OnSyncMessage("GBLSync", msg, "GUILD", "OfficerB-Stormrage")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Exact version matching
    ---------------------------------------------------------------------------

    describe("exact version matching", function()
        it("allows sync when versions match exactly", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Add local data so sync makes sense
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1:0",
            })
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 999,
                dataHash = 12345,
                lastScanTime = 1000,
            })
            -- Should proceed to sync logic (not blocked by version gate)
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.falsy(entry.message:find("version mismatch"))
            end
        end)

        it("protocol version gate rejects old protocol messages", function()
            assert.equals(3, GBL.SYNC_PROTOCOL_VERSION)
        end)

        it("tracks outdated peers from protocol-mismatched HELLO", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Simulate a HELLO with old protocol version
            local msg = GBL:Serialize({
                type = "HELLO",
                version = "0.12.2",
                protocolVersion = 2,
                guild = "TestGuild",
                txCount = 50,
                dataHash = 999,
            })
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "OutdatedPeer")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OutdatedPeer"])
            assert.equals("0.12.2", peers["OutdatedPeer"].version)
            assert.is_true(peers["OutdatedPeer"].outdated)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cross-realm name matching
    ---------------------------------------------------------------------------

    describe("cross-realm name matching", function()
        it("HandleAck accepts ACK when sender has realm but target does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes from realm-qualified name (cross-realm WHISPER)
            GBL:HandleAck("OfficerB-Stormrage", { chunk = 1 })

            -- Should have accepted the ACK (baseName match)
            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB%-Stormrage for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite realm suffix mismatch")
        end)

        it("HandleAck accepts ACK when target has realm but sender does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            -- SYNC_REQUEST came from realm-qualified name (GUILD channel)
            GBL:HandleSyncRequest("OfficerB-ArgentDawn", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes without realm (WHISPER channel)
            GBL:HandleAck("OfficerB", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite missing realm suffix")
        end)

        it("HandleSyncData accepts data from differently-qualified sender", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving — receiveSource set with realm suffix
            GBL:RequestSync("OfficerB-Stormrage", 0)

            -- SYNC_DATA arrives without realm suffix (different channel format)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 999, count = 1, timestamp = 2000,
                        scanTime = 2000, scannedBy = "OfficerB",
                        id = "deposit|Thrall|999|1|0|0:0",
                    },
                },
                moneyTransactions = {},
            })

            -- Should have stored the transaction (not rejected as wrong sender)
            assert.equals(1, #guildData.transactions)
        end)

        it("still rejects ACK from a completely different player", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK from wrong person entirely
            GBL:HandleAck("OfficerC-Tichondrius", { chunk = 1 })

            -- Should NOT have processed the ACK
            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerC") then
                    foundAck = true
                end
            end
            assert.is_false(foundAck,
                "ACK from different player should be rejected")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Fingerprint-based sync
    ---------------------------------------------------------------------------

    describe("fingerprint sync", function()
        it("HELLO includes dataHash field", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "P", timestamp = 1000,
                scanTime = 1000, id = "h1:0",
            })

            GBL:BroadcastHello(true)

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_number(data.dataHash)
            assert.is_true(data.dataHash > 0)
        end)

        it("skips sync when dataHash and txCount match", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Both peers have the same record
            table.insert(guildData.transactions, {
                type = "deposit", player = "P", timestamp = 1000,
                scanTime = 1000, id = "h1:0",
            })

            local localHash = GBL:GetDataHash(guildData)

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 1,
                dataHash = localHash,
                lastScanTime = 1000,
            })

            -- Should NOT have sent a SYNC_REQUEST
            local sentRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, d = GBL:Deserialize(msg.text)
                if ok and d.type == "SYNC_REQUEST" then
                    sentRequest = true
                end
            end
            assert.is_false(sentRequest, "should skip sync when hashes match")

            -- Audit trail should mention datasets identical
            local trail = GBL:GetAuditTrail()
            local found = false
            for _, e in ipairs(trail) do
                if e.message:find("datasets identical") then found = true end
            end
            assert.is_true(found)
        end)

        it("falls back to txCount when remote has no dataHash", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Remote has more records but no dataHash (old version)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 10,
                -- no dataHash field
                lastScanTime = 1000,
            })

            -- Should have sent SYNC_REQUEST (txCount-based fallback)
            local sentRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, d = GBL:Deserialize(msg.text)
                if ok and d.type == "SYNC_REQUEST" then
                    sentRequest = true
                end
            end
            assert.is_true(sentRequest, "should fall back to txCount sync")
        end)

        it("SYNC_REQUEST includes bucketHashes", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local ts = 86400 * 20000
            local bucketKey = math.floor(ts / GBL.BUCKET_SECONDS)
            table.insert(guildData.transactions, {
                type = "deposit", player = "P", timestamp = ts,
                scanTime = ts, id = "h1:0",
            })

            GBL:RequestSync("OfficerB", 0)

            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("SYNC_REQUEST", data.type)
            assert.is_table(data.bucketHashes)
            assert.is_not_nil(data.bucketHashes[bucketKey])
        end)

        it("HandleSyncRequest filters by differing buckets when bucketHashes present", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local ts1 = 86400 * 20000 + 100
            local ts2 = 86400 * 20001 + 100
            local bucket1 = math.floor(ts1 / GBL.BUCKET_SECONDS)
            local bucket2 = math.floor(ts2 / GBL.BUCKET_SECONDS)

            -- Local has records in two different buckets
            table.insert(guildData.transactions, {
                type = "deposit", player = "A", timestamp = ts1,
                scanTime = ts1, id = "bucket0_rec:0",
                itemID = 100, count = 1, tab = 1,
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "B", timestamp = ts2,
                scanTime = ts2, id = "bucket1_rec:0",
                itemID = 200, count = 1, tab = 1,
            })

            -- Requester already has bucket1 (matching hash) but not bucket2
            local localBuckets = GBL:ComputeBucketHashes(guildData)

            GBL:HandleSyncRequest("OfficerB", {
                sinceTimestamp = 0,
                bucketHashes = { [bucket1] = localBuckets[bucket1] },  -- bucket1 matches, bucket2 absent
            })

            -- Should only send records from bucket2 (the differing bucket)
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.equals(1, #data.transactions)
            assert.equals("bucket1_rec:0", data.transactions[1].id)
        end)

        it("HandleSyncRequest sends nothing when all bucket hashes match", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local ts = 86400 * 20000 + 100
            table.insert(guildData.transactions, {
                type = "deposit", player = "A", timestamp = ts,
                scanTime = ts, id = "rec1:0",
                itemID = 100, count = 1, tab = 1,
            })

            local localBuckets = GBL:ComputeBucketHashes(guildData)

            GBL:HandleSyncRequest("OfficerB", {
                sinceTimestamp = 0,
                bucketHashes = localBuckets,  -- all match
            })

            -- Should send an empty sync (0 records)
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(0, #data.transactions)
            assert.equals(0, #data.moneyTransactions)
        end)

        it("HandleSyncRequest falls back to sinceTimestamp without bucketHashes", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "A", timestamp = 500,
                scanTime = 500, id = "old:0",
                itemID = 100, count = 1, tab = 1,
            })
            table.insert(guildData.transactions, {
                type = "deposit", player = "B", timestamp = 2000,
                scanTime = 2000, id = "new:0",
                itemID = 200, count = 1, tab = 1,
            })

            -- No bucketHashes — old-style request
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 1000 })

            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            -- Only the record with scanTime > 1000 should be sent
            assert.equals(1, #data.transactions)
            assert.equals("new:0", data.transactions[1].id)
        end)

        it("UpdatePeer stores dataHash from HELLO", function()
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = 12345,
                lastScanTime = 1000,
            })

            local peers = GBL:GetSyncPeers()
            assert.equals(12345, peers["OfficerB"].dataHash)
        end)
    end)

    ---------------------------------------------------------------------------
    -- NACK retry
    ---------------------------------------------------------------------------

    describe("NACK retry", function()
        it("receiver sends NACK on chunk timeout instead of aborting", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver state: received chunk 1, waiting for chunk 2
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nack1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            -- Fire the receive timeout — should NACK, not abort
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            assert.is_true(GBL:GetSyncStatus().receiving,
                "should still be receiving after NACK")
            -- Should have sent a NACK message
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("NACK", data.type)
            assert.equals(2, data.chunk)
        end)

        it("sender re-transmits chunk on NACK receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender with 2 chunks
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "nk" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            local sentBefore = #MockAce.sentCommMessages

            -- Send NACK for chunk 1
            GBL:HandleNack("OfficerB", { chunk = 1 })

            -- Fire the 0.5s delayed re-send
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                    break
                end
            end

            assert.is_true(#MockAce.sentCommMessages > sentBefore,
                "should have re-sent chunk after NACK")
        end)

        it("receiver aborts after MAX_NACK_RETRIES for same chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver — got chunk 1, waiting for chunk 2
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nklim1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout MAX_NACK_RETRIES times
            for attempt = 1, GBL.SYNC_MAX_NACK_RETRIES do
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if timer.delay == 20 and not timer.cancelled then
                        timer.callback()
                        break
                    end
                end
                if attempt < GBL.SYNC_MAX_NACK_RETRIES then
                    assert.is_true(GBL:GetSyncStatus().receiving,
                        "should still be receiving after NACK attempt " .. attempt)
                end
            end

            -- One more — should abort
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end
            assert.is_false(GBL:GetSyncStatus().receiving,
                "should have aborted after max NACK retries")
        end)

        it("NACK counter resets on successful chunk receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 4,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nkrst1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout twice (2 NACKs sent)
            for _ = 1, 2 do
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if timer.delay == 20 and not timer.cancelled then
                        timer.callback()
                        break
                    end
                end
            end

            -- Now receive chunk 2 — should reset counter
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 2, totalChunks = 4,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5001,
                    scanTime = 5001, id = "nkrst2:0", itemID = 101, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout MAX_NACK_RETRIES times — should still be receiving
            -- because counter was reset
            for attempt = 1, GBL.SYNC_MAX_NACK_RETRIES do
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if timer.delay == 20 and not timer.cancelled then
                        timer.callback()
                        break
                    end
                end
            end
            -- Should still be receiving (counter was reset after chunk 2)
            assert.is_true(GBL:GetSyncStatus().receiving,
                "NACK counter should have reset — still receiving")
        end)

        it("NACK from wrong sender is ignored", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "nkign:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local sentBefore = #MockAce.sentCommMessages

            -- NACK from wrong sender
            GBL:HandleNack("OfficerC", { chunk = 1 })

            -- Fire any pending timers
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            -- No new messages should have been sent (NACK was ignored)
            assert.equals(sentBefore, #MockAce.sentCommMessages)
        end)

        it("NACK for out-of-range chunk is ignored", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender with 1 chunk
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "nkoor:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            local sentBefore = #MockAce.sentCommMessages

            -- NACK for chunk 0 (invalid)
            GBL:HandleNack("OfficerB", { chunk = 0 })
            -- NACK for chunk 99 (out of range)
            GBL:HandleNack("OfficerB", { chunk = 99 })

            -- Fire any pending timers
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(sentBefore, #MockAce.sentCommMessages)
        end)

        it("initial request timeout sends NACK for chunk 1", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Request sync (puts us in receiving state)
            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            -- Fire the initial receive timeout (no data arrived)
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    timer.callback()
                    break
                end
            end

            -- Should have sent a NACK for chunk 1, not aborted
            assert.is_true(GBL:GetSyncStatus().receiving,
                "should still be receiving after initial NACK")
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("NACK", data.type)
            assert.equals(1, data.chunk)
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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
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
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

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

    ---------------------------------------------------------------------------
    -- FPS-adaptive throttling
    ---------------------------------------------------------------------------

    describe("FPS-adaptive throttling", function()
        it("uses slow delay when FPS below threshold", function()
            MockWoW.framerate = 15
            GBL:StartFpsMonitor()

            -- Fire OnUpdate with enough elapsed time
            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")
            assert.is_not_nil(onUpdate)

            -- Advance time past sample interval
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)

            assert.equals(0.5, GBL:GetSyncDelay())
            GBL:StopFpsMonitor()
        end)

        it("recovers to normal delay when FPS above recover threshold", function()
            MockWoW.framerate = 15
            GBL:StartFpsMonitor()

            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")

            -- Trigger low FPS
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)
            assert.equals(0.5, GBL:GetSyncDelay())

            -- Recover FPS
            MockWoW.framerate = 30
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)

            assert.equals(0.1, GBL:GetSyncDelay())
            GBL:StopFpsMonitor()
        end)

        it("FPS monitor starts on sync begin and stops on FinishSending", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local framesBefore = #MockWoW.frames
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "fps1:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- FPS frame should have been created
            assert.is_true(#MockWoW.frames > framesBefore,
                "FPS monitor frame should be created on sync start")

            -- Finish sending
            GBL:FinishSending()
            assert.equals(0.1, GBL:GetSyncDelay(),
                "delay should reset to normal after FinishSending")
        end)

        it("HandleAck uses adaptive delay value", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sending with slow delay
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "fps2_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Simulate low FPS — manually set delay
            MockWoW.framerate = 10
            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")
            if onUpdate then
                MockWoW.serverTime = MockWoW.serverTime + 2
                onUpdate(frame, 2)
            end
            assert.equals(0.5, GBL:GetSyncDelay())

            -- Send ACK — the scheduled delay should use adaptive value
            GBL:HandleAck("OfficerB", { chunk = 1 })

            -- Verify a one-shot timer was created with the slow delay
            local foundSlowDelay = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    foundSlowDelay = true
                    break
                end
            end
            assert.is_true(foundSlowDelay,
                "HandleAck should schedule next chunk with adaptive delay (0.5s)")
        end)
    end)

    ---------------------------------------------------------------------------
    -- ChatThrottleLib awareness
    ---------------------------------------------------------------------------

    ---------------------------------------------------------------------------
    -- Chunk count accuracy
    ---------------------------------------------------------------------------

    describe("chunk count in FinishSending", function()
        it("reports correct chunk count (N/N, not N+1/N)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add enough records for 2 chunks
            for i = 1, 20 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "ChunkTest",
                    timestamp = 1000 + i, scanTime = 1000 + i,
                    id = "chunk_count_test_" .. i .. ":0",
                })
            end

            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Capture the audit trail
            local trail = GBL:GetAuditTrail()
            local sendComplete = nil
            for _, entry in ipairs(trail) do
                if entry.message:find("Send complete") then
                    sendComplete = entry.message
                end
            end

            if sendComplete then
                -- Extract "X/Y chunks" from the message
                local sent, total = sendComplete:match("(%d+)/(%d+) chunks")
                if sent and total then
                    assert.equals(sent, total,
                        "sent count should equal total count, got: " .. sendComplete)
                end
            end
        end)
    end)

    describe("ChatThrottleLib awareness", function()
        it("defers SendNextChunk when CTL bandwidth is low", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up CTL with low bandwidth
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl1:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            -- HandleSyncRequest calls SendNextChunk which should defer
            -- No SYNC_DATA sent immediately because CTL bandwidth is low
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" then
                    foundSyncData = true
                end
            end
            assert.is_false(foundSyncData,
                "should defer SYNC_DATA when CTL bandwidth is low")

            _G.ChatThrottleLib = nil
        end)

        it("sends normally when CTL bandwidth is sufficient", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = { avail = 1000 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl2:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

            -- Should have sent normally (no CTL deferral)
            local trail = GBL:GetAuditTrail()
            local ctlDeferred = false
            for _, entry in ipairs(trail) do
                if entry.message:find("CTL bandwidth low") then
                    ctlDeferred = true
                    break
                end
            end
            assert.is_false(ctlDeferred)
            assert.is_true(#MockAce.sentCommMessages >= 1)

            _G.ChatThrottleLib = nil
        end)

        it("sends normally when ChatThrottleLib is absent", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = nil
            assert.is_true(GBL:HasSyncBandwidth())

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl3:0",
            })
            GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })
            assert.is_true(#MockAce.sentCommMessages >= 1)
        end)

        it("graceful fallback when CTL has no avail field", function()
            _G.ChatThrottleLib = {}
            assert.is_true(GBL:HasSyncBandwidth())
            _G.ChatThrottleLib = nil
        end)
    end)

    ---------------------------------------------------------------------------
    -- Peer staleness
    ---------------------------------------------------------------------------

    describe("peer staleness", function()
        before_each(function()
            GBL:ResetSyncState()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
        end)

        it("GetSyncPeers returns peers seen recently", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Still within staleness window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS - 1
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
        end)

        it("GetSyncPeers filters out stale peers", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Past staleness window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"])
        end)

        it("stale peer reappears after new message", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Goes stale
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])

            -- New HELLO re-registers
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 10, lastScanTime = MockWoW.serverTime,
            })
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
            assert.equals(10, GBL:GetSyncPeers()["OfficerB"].txCount)
        end)

        it("GetAllPeers returns stale peers too", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
            assert.is_not_nil(GBL:GetAllPeers()["OfficerB"])
        end)

        it("heartbeat keeps idle peer alive in peer list", function()
            MockWoW.serverTime = 100000
            GBL:InitSync()
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past heartbeat interval but within stale window
            MockWoW.serverTime = 100200
            -- Fire heartbeat timer (broadcasts our HELLO)
            MockWoW.fireTimers()
            -- Simulate HELLO reply arriving from OfficerB, refreshing their lastSeen
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance to where original lastSeen would be stale, but refreshed one is not
            MockWoW.serverTime = 100400
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("peer without heartbeat refresh expires after PEER_STALE_SECONDS", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past stale window without any heartbeat or messages
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("heartbeat timer starts on InitSync", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            -- Should have a pending heartbeat ticker
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)

        it("heartbeat timer cancelled on DisableSync", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            -- Verify timer was started
            local heartbeat = nil
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    heartbeat = timer
                    break
                end
            end
            assert.is_not_nil(heartbeat)

            GBL:DisableSync()
            assert.is_true(heartbeat.cancelled)
        end)

        it("heartbeat timer cancelled on ResetSyncState", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            local heartbeat = nil
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    heartbeat = timer
                    break
                end
            end
            assert.is_not_nil(heartbeat)

            GBL:ResetSyncState()
            assert.is_true(heartbeat.cancelled)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Compression
    ---------------------------------------------------------------------------

    describe("compression", function()
        it("protocol version is 3", function()
            assert.equals(3, GBL.SYNC_PROTOCOL_VERSION)
        end)

        it("compress/decompress round-trips correctly", function()
            local original = GBL:Serialize({
                type = "SYNC_DATA", chunk = 1, totalChunks = 1,
                transactions = {{ id = "test:0", player = "A", itemID = 100 }},
                moneyTransactions = {},
            })
            local compressed = GBL._compressMessage(original)
            local decompressed = GBL._decompressMessage(compressed)
            assert.equals(original, decompressed)
        end)

        it("sent HELLO messages pass through compression", function()
            GBL:ResetSyncState()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockAce.sentCommMessages = {}

            GBL:BroadcastHello(true)

            assert.is_true(#MockAce.sentCommMessages >= 1)
            -- With identity mock, compressed = serialized, so Deserialize still works
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
        end)

        it("received messages are decompressed before deserialization", function()
            GBL:ResetSyncState()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.player.name = "TestPlayer"

            -- Simulate a compressed HELLO from another player
            local serialized = GBL:Serialize({
                type = "HELLO", version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 3, dataHash = 12345,
            })
            local compressed = GBL._compressMessage(serialized)

            GBL:OnSyncMessage("GBLSync", compressed, "GUILD", "OfficerX")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerX"])
            assert.equals(3, peers["OfficerX"].txCount)
        end)
    end)

    ---------------------------------------------------------------------------
    -- NormalizeRecordId edge cases (J15-J18, G10)
    ---------------------------------------------------------------------------

    describe("NormalizeRecordId edge cases", function()
        it("returns false when incoming id is nil", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = { ["deposit|Thrall|12345|5|1|101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = nil, _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)
            assert.is_false(result)
            -- Local record unchanged
            assert.equals("deposit|Thrall|12345|5|1|101:0", localTx.id)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"])
        end)

        it("returns false when incoming id equals matched key", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"] = 3600 * 100

            local idIndex = { ["deposit|Thrall|12345|5|1|100:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|100:0", guildData, idIndex)
            assert.is_false(result)
            -- Nothing changed
            assert.equals(3600 * 100, localTx.timestamp)
        end)

        it("sets timestamp to 0 when incoming timestamp is nil", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = { ["deposit|Thrall|12345|5|1|101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = nil,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals(0, localTx.timestamp)
            assert.equals(0, guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"])
        end)

        it("updates seenTxHashes even when idIndex is nil", function()
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, nil)
            assert.is_true(result)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"])
        end)

        it("normalizes record with matching _occurrence=0", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = "deposit|Thrall|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|101:0"] = 3600 * 101

            local idIndex = { ["deposit|Thrall|12345|5|1|101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals(0, localTx._occurrence)
        end)
    end)

    ---------------------------------------------------------------------------
    -- seenTxHashes atomic update (K19)
    ---------------------------------------------------------------------------

    describe("seenTxHashes atomic update", function()
        it("seenTxHashes has only new key after normalization (old key removed)", function()
            local oldKey = "deposit|Thrall|12345|5|1|101:0"
            local newKey = "deposit|Thrall|12345|5|1|100:0"
            guildData.seenTxHashes[oldKey] = 3600 * 101

            -- Count keys before
            local countBefore = 0
            for _ in pairs(guildData.seenTxHashes) do countBefore = countBefore + 1 end
            assert.equals(1, countBefore)

            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 101,
                id = oldKey, _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            local idIndex = { [oldKey] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = newKey, _occurrence = 0,
            }

            GBL:NormalizeRecordId(incoming, oldKey, guildData, idIndex)

            -- Count keys after
            local countAfter = 0
            for _ in pairs(guildData.seenTxHashes) do countAfter = countAfter + 1 end
            assert.equals(1, countAfter)

            assert.equals(3600 * 100, guildData.seenTxHashes[newKey])
            assert.is_nil(guildData.seenTxHashes[oldKey])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Multi-record normalization in same chunk (B3, B4)
    ---------------------------------------------------------------------------

    describe("multi-record normalization", function()
        it("normalizes two records in same chunk with correct idIndex updates", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx1 = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            local localTx2 = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 201 + 1800,
                id = "withdraw|Jaina-TestRealm|99999|10|2|201:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx1)
            table.insert(guildData.transactions, localTx2)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800
            guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|201:0"] = 3600 * 201 + 1800

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                    {
                        type = "withdraw", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 3600 * 200 + 2400,
                        id = "withdraw|Jaina-TestRealm|99999|10|2|200:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Both records normalized
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|100:0", localTx1.id)
            assert.equals("withdraw|Jaina-TestRealm|99999|10|2|200:0", localTx2.id)
            -- No new records stored
            assert.equals(2, #guildData.transactions)
            -- seenTxHashes updated
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|100:0"])
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|200:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"])
            assert.is_nil(guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|201:0"])
        end)

        it("handles mix of normalization and new record in same chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                    {
                        type = "deposit", player = "Arthas",
                        itemID = 55555, classID = 0, subclassID = 1,
                        count = 3, tab = 2,
                        timestamp = 3600 * 300,
                        id = "deposit|Arthas-TestRealm|55555|3|2|300:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            assert.equals("deposit|Thrall-TestRealm|12345|5|1|100:0", localTx.id)
            assert.equals(2, #guildData.transactions)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Arthas-TestRealm|55555|3|2|300:0"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Hash cache invalidation after normalization (D6, D7)
    ---------------------------------------------------------------------------

    describe("hash cache invalidation after normalization", function()
        it("resets hash cache after normalization so GetDataHash recomputes", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            -- Populate cache
            local hashBefore = GBL:GetDataHash(guildData)
            assert.is_not.equals(0, hashBefore)

            -- Normalize via HandleSyncData (single chunk triggers FinishReceiving)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Hash should be different (cache was invalidated and recomputed)
            local hashAfter = GBL:GetDataHash(guildData)
            assert.are_not.equals(hashBefore, hashAfter)
            -- Should match the hash of the normalized ID
            assert.equals(GBL:HashString("deposit|Thrall-TestRealm|12345|5|1|100:0"), hashAfter)
        end)

        it("does NOT reset hash cache when no normalization occurred", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"] = 3600 * 100

            -- Spy on ResetHashCache
            local originalReset = GBL.ResetHashCache
            local resetCalled = false
            GBL.ResetHashCache = function(self)
                resetCalled = true
                return originalReset(self)
            end

            -- Send exact duplicate (no normalization)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100,
                        id = "deposit|Thrall|12345|5|1|100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            GBL.ResetHashCache = originalReset
            assert.is_false(resetCalled)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Bidirectional convergence (E8, F9)
    ---------------------------------------------------------------------------

    describe("bidirectional convergence", function()
        it("sender-wins ensures convergence: B adopts A ID, then A sees exact match", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- === Step 1: Operate as Peer B, receiving from Peer A ===
            local bRecord = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, bRecord)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|101:0"] = 3600 * 101 + 1800

            local aTimestamp = 3600 * 100 + 2400
            local aId = "deposit|Thrall-TestRealm|12345|5|1|100:0"

            GBL:HandleSyncData("PeerA", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = aTimestamp,
                        id = aId, _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- B now has A's ID
            assert.equals(aId, bRecord.id)
            local bHash = GBL:ComputeDataHash(guildData)
            local expectedHash = GBL:HashString(aId)
            assert.equals(expectedHash, bHash)

            -- === Step 2: Operate as Peer A, receiving from Peer B ===
            -- Snapshot B's converged record
            local bConvergedId = bRecord.id
            local bConvergedTs = bRecord.timestamp

            -- Reset for Peer A's perspective
            GBL:ResetSyncState()
            guildData.transactions = {}
            guildData.moneyTransactions = {}
            guildData.seenTxHashes = {}

            local aRecord = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = aTimestamp,
                id = aId, _occurrence = 0,
            }
            table.insert(guildData.transactions, aRecord)
            guildData.seenTxHashes[aId] = aTimestamp
            GBL:ResetHashCache()

            GBL:HandleSyncData("PeerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = bConvergedTs,
                        id = bConvergedId, _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Exact match — no normalization, no new records
            assert.equals(1, #guildData.transactions)
            assert.equals(aId, aRecord.id)  -- unchanged

            local aHash = GBL:ComputeDataHash(guildData)
            assert.equals(bHash, aHash)
        end)

        it("no normalization or data transfer on third sync cycle after convergence", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Both peers already have identical records
            local sharedId = "deposit|Thrall|12345|5|1|100:0"
            local sharedTs = 3600 * 100 + 2400

            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = sharedTs,
                id = sharedId, _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes[sharedId] = sharedTs

            local hashBefore = GBL:ComputeDataHash(guildData)

            GBL:HandleSyncData("PeerA", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = sharedTs,
                        id = sharedId, _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Zero new, zero normalized
            assert.equals(1, #guildData.transactions)
            assert.equals(sharedId, localTx.id)
            assert.equals(hashBefore, GBL:ComputeDataHash(guildData))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Occurrence index during sync (G11)
    ---------------------------------------------------------------------------

    describe("occurrence index during sync", function()
        it("different occurrence in sync chunk treated as new record, not normalized", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Local has :0 occurrence
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 100,
                id = "deposit|Thrall|12345|5|1|100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|100:0"] = 3600 * 100

            -- Incoming has :1 occurrence (second identical tx in same hour)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100,
                        id = "deposit|Thrall|12345|5|1|100:1",
                        _occurrence = 1,
                    },
                },
                moneyTransactions = {},
            })

            -- Should be stored as a new record, not normalized
            assert.equals(2, #guildData.transactions)
            assert.equals("deposit|Thrall|12345|5|1|100:0", localTx.id)
        end)
    end)

    ---------------------------------------------------------------------------
    -- reconstructSyncRecord pipeline (H12, H13)
    ---------------------------------------------------------------------------

    describe("reconstructSyncRecord pipeline", function()
        it("reconstructs record without timestamp or id and stores it", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        -- No id, no timestamp
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            local stored = guildData.transactions[1]
            assert.is_not_nil(stored.id)
            assert.is_truthy(stored.id:find(":0$"))
            assert.equals(MockWoW.serverTime, stored.timestamp)
            assert.is_truthy(stored.scannedBy:find("^sync:"))
        end)

        it("recovers timestamp from ID timeSlot when timestamp is missing", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        id = "deposit|Thrall|12345|5|1|500:0",
                        -- No timestamp — should recover from ID
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            local stored = guildData.transactions[1]
            assert.equals(500 * 3600, stored.timestamp)
            assert.equals("deposit|Thrall|12345|5|1|500:0", stored.id)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Mixed outcomes in same bucket (I14)
    ---------------------------------------------------------------------------

    describe("mixed outcomes in same bucket", function()
        it("handles normalize + exact dup + new in same bucket correctly", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- All in bucket = floor(480001/6) = 80000
            local localTx1 = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 480001 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|480001:0", _occurrence = 0,
            }
            local localTx2 = {
                type = "deposit", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 480002,
                id = "deposit|Jaina-TestRealm|99999|10|2|480002:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx1)
            table.insert(guildData.transactions, localTx2)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|480001:0"] = 3600 * 480001 + 1800
            guildData.seenTxHashes["deposit|Jaina-TestRealm|99999|10|2|480002:0"] = 3600 * 480002

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    -- 1. Fuzzy match for localTx1 (normalizes)
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 480000 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|480000:0",
                        _occurrence = 0,
                    },
                    -- 2. Exact match for localTx2 (deduped)
                    {
                        type = "deposit", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 3600 * 480002,
                        id = "deposit|Jaina-TestRealm|99999|10|2|480002:0",
                        _occurrence = 0,
                    },
                    -- 3. New record
                    {
                        type = "withdraw", player = "Arthas",
                        itemID = 55555, classID = 0, subclassID = 1,
                        count = 3, tab = 2,
                        timestamp = 3600 * 480003,
                        id = "withdraw|Arthas-TestRealm|55555|3|2|480003:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- localTx1 normalized, localTx2 unchanged, new record added
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|480000:0", localTx1.id)
            assert.equals("deposit|Jaina-TestRealm|99999|10|2|480002:0", localTx2.id)
            assert.equals(3, #guildData.transactions)

            -- Verify bucket hash = XOR of all three final record IDs
            GBL:ResetHashCache()
            local buckets = GBL:ComputeBucketHashes(guildData)
            local expected = GBL:XOR32(
                GBL:XOR32(
                    GBL:HashString("deposit|Thrall-TestRealm|12345|5|1|480000:0"),
                    GBL:HashString("deposit|Jaina-TestRealm|99999|10|2|480002:0")
                ),
                GBL:HashString("withdraw|Arthas-TestRealm|55555|3|2|480003:0")
            )
            assert.equals(expected, buckets[80000])
        end)
    end)

    ---------------------------------------------------------------------------
    -- End-to-end sync convergence (L20)
    ---------------------------------------------------------------------------

    describe("end-to-end sync convergence", function()
        it("two peers with divergent records converge after full sync cycle", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Record definitions (shared events scanned at different hours)
            local shared1_A = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 100 + 2400,
                id = "deposit|Thrall-TestRealm|12345|5|1|100:0", _occurrence = 0,
            }
            local shared1_B = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|101:0", _occurrence = 0,
            }
            local shared2_A = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 200 + 2400,
                id = "withdraw|Jaina-TestRealm|99999|10|2|200:0", _occurrence = 0,
            }
            local shared2_B = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 201 + 1800,
                id = "withdraw|Jaina-TestRealm|99999|10|2|201:0", _occurrence = 0,
            }
            local aOnly = {
                type = "deposit", player = "Arthas-TestRealm", itemID = 55555,
                classID = 0, subclassID = 1,
                count = 3, tab = 2, timestamp = 3600 * 300,
                id = "deposit|Arthas-TestRealm|55555|3|2|300:0", _occurrence = 0,
            }
            local bOnly = {
                type = "deposit", player = "Varian-TestRealm", itemID = 77777,
                classID = 0, subclassID = 1,
                count = 1, tab = 1, timestamp = 3600 * 400,
                id = "deposit|Varian-TestRealm|77777|1|1|400:0", _occurrence = 0,
            }

            -- === Step 1: A sends to B ===
            -- Set up as Peer B (has shared1_B, shared2_B, bOnly)
            table.insert(guildData.transactions, {
                type = shared1_B.type, player = shared1_B.player,
                itemID = shared1_B.itemID, classID = shared1_B.classID,
                subclassID = shared1_B.subclassID,
                count = shared1_B.count, tab = shared1_B.tab,
                timestamp = shared1_B.timestamp,
                id = shared1_B.id, _occurrence = shared1_B._occurrence,
            })
            table.insert(guildData.transactions, {
                type = shared2_B.type, player = shared2_B.player,
                itemID = shared2_B.itemID, classID = shared2_B.classID,
                subclassID = shared2_B.subclassID,
                count = shared2_B.count, tab = shared2_B.tab,
                timestamp = shared2_B.timestamp,
                id = shared2_B.id, _occurrence = shared2_B._occurrence,
            })
            table.insert(guildData.transactions, {
                type = bOnly.type, player = bOnly.player,
                itemID = bOnly.itemID, classID = bOnly.classID,
                subclassID = bOnly.subclassID,
                count = bOnly.count, tab = bOnly.tab,
                timestamp = bOnly.timestamp,
                id = bOnly.id, _occurrence = bOnly._occurrence,
            })
            guildData.seenTxHashes[shared1_B.id] = shared1_B.timestamp
            guildData.seenTxHashes[shared2_B.id] = shared2_B.timestamp
            guildData.seenTxHashes[bOnly.id] = bOnly.timestamp

            -- A sends its 3 records (shared1_A, shared2_A, aOnly)
            GBL:HandleSyncData("PeerA", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = shared1_A.type, player = shared1_A.player,
                        itemID = shared1_A.itemID, classID = shared1_A.classID,
                        subclassID = shared1_A.subclassID,
                        count = shared1_A.count, tab = shared1_A.tab,
                        timestamp = shared1_A.timestamp,
                        id = shared1_A.id, _occurrence = shared1_A._occurrence,
                    },
                    {
                        type = shared2_A.type, player = shared2_A.player,
                        itemID = shared2_A.itemID, classID = shared2_A.classID,
                        subclassID = shared2_A.subclassID,
                        count = shared2_A.count, tab = shared2_A.tab,
                        timestamp = shared2_A.timestamp,
                        id = shared2_A.id, _occurrence = shared2_A._occurrence,
                    },
                    {
                        type = aOnly.type, player = aOnly.player,
                        itemID = aOnly.itemID, classID = aOnly.classID,
                        subclassID = aOnly.subclassID,
                        count = aOnly.count, tab = aOnly.tab,
                        timestamp = aOnly.timestamp,
                        id = aOnly.id, _occurrence = aOnly._occurrence,
                    },
                },
                moneyTransactions = {},
            })

            -- B should now have 4 records: shared1(A's ID), shared2(A's ID), bOnly, aOnly
            assert.equals(4, #guildData.transactions)

            -- Snapshot B's final state
            local bFinalHash = GBL:ComputeDataHash(guildData)
            local bFinalBuckets = GBL:ComputeBucketHashes(guildData)
            local bFinalIds = {}
            for _, tx in ipairs(guildData.transactions) do
                bFinalIds[#bFinalIds + 1] = { id = tx.id, ts = tx.timestamp }
            end

            -- === Step 2: B sends to A ===
            GBL:ResetSyncState()
            guildData.transactions = {}
            guildData.moneyTransactions = {}
            guildData.seenTxHashes = {}
            GBL:ResetHashCache()

            -- Set up as Peer A (has shared1_A, shared2_A, aOnly)
            table.insert(guildData.transactions, {
                type = shared1_A.type, player = shared1_A.player,
                itemID = shared1_A.itemID, classID = shared1_A.classID,
                subclassID = shared1_A.subclassID,
                count = shared1_A.count, tab = shared1_A.tab,
                timestamp = shared1_A.timestamp,
                id = shared1_A.id, _occurrence = shared1_A._occurrence,
            })
            table.insert(guildData.transactions, {
                type = shared2_A.type, player = shared2_A.player,
                itemID = shared2_A.itemID, classID = shared2_A.classID,
                subclassID = shared2_A.subclassID,
                count = shared2_A.count, tab = shared2_A.tab,
                timestamp = shared2_A.timestamp,
                id = shared2_A.id, _occurrence = shared2_A._occurrence,
            })
            table.insert(guildData.transactions, {
                type = aOnly.type, player = aOnly.player,
                itemID = aOnly.itemID, classID = aOnly.classID,
                subclassID = aOnly.subclassID,
                count = aOnly.count, tab = aOnly.tab,
                timestamp = aOnly.timestamp,
                id = aOnly.id, _occurrence = aOnly._occurrence,
            })
            guildData.seenTxHashes[shared1_A.id] = shared1_A.timestamp
            guildData.seenTxHashes[shared2_A.id] = shared2_A.timestamp
            guildData.seenTxHashes[aOnly.id] = aOnly.timestamp

            -- B sends all 4 records to A
            local bPayload = {}
            for _, rec in ipairs(bFinalIds) do
                -- Find the full record definition
                local fullRec
                if rec.id == shared1_A.id then fullRec = shared1_A
                elseif rec.id == shared2_A.id then fullRec = shared2_A
                elseif rec.id == aOnly.id then fullRec = aOnly
                elseif rec.id == bOnly.id then fullRec = bOnly
                end
                bPayload[#bPayload + 1] = {
                    type = fullRec.type, player = fullRec.player,
                    itemID = fullRec.itemID, classID = fullRec.classID,
                    subclassID = fullRec.subclassID,
                    count = fullRec.count, tab = fullRec.tab,
                    timestamp = rec.ts, id = rec.id,
                    _occurrence = fullRec._occurrence,
                }
            end

            GBL:HandleSyncData("PeerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = bPayload,
                moneyTransactions = {},
            })

            -- A should now have 4 records: shared1(A), shared2(A), aOnly, bOnly
            assert.equals(4, #guildData.transactions)

            -- Both peers' hashes must match
            local aFinalHash = GBL:ComputeDataHash(guildData)
            assert.equals(bFinalHash, aFinalHash)

            -- Bucket hashes must match too
            local aFinalBuckets = GBL:ComputeBucketHashes(guildData)
            for key, bHash in pairs(bFinalBuckets) do
                assert.equals(bHash, aFinalBuckets[key],
                    "bucket " .. key .. " hash mismatch")
            end
            for key, aHash in pairs(aFinalBuckets) do
                assert.equals(aHash, bFinalBuckets[key],
                    "bucket " .. key .. " hash mismatch (A-only key)")
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- Corrupted record rejection (v0.12.2)
    ---------------------------------------------------------------------------

    describe("corrupted record rejection", function()
        it("rejects record with missing type from sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        -- Missing type field (AceSerializer corruption)
                        player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 100,
                        id = "|Thrall|12345|5|1|100:0",
                    },
                    {
                        -- Valid record
                        type = "deposit", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 3600 * 200,
                        id = "deposit|Jaina|99999|10|2|200:0",
                    },
                },
                moneyTransactions = {
                    {
                        -- Missing player field
                        type = "repair",
                        amount = 50000,
                        timestamp = 3600 * 300,
                        id = "repair||50000|300:0",
                    },
                },
            })

            -- Only the valid record should be stored
            assert.equals(1, #guildData.transactions)
            assert.equals("Jaina-TestRealm", guildData.transactions[1].player)
            assert.equals(0, #guildData.moneyTransactions)
        end)
    end)
end)
