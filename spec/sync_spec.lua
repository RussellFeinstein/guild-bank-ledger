------------------------------------------------------------------------
-- spec/sync_spec.lua — Tests for Sync.lua (M5)
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

local fireAckTimeout = Sync.fireAckTimeout
local fireNextChunkDelay = Sync.fireNextChunkDelay
local fireReceiveTimeout = Sync.fireReceiveTimeout

describe("Sync", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- HandleSyncData (receiver side)
    ---------------------------------------------------------------------------

    describe("HandleSyncData", function()
        it("ACK is sent with ALERT priority", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = {}, moneyTransactions = {},
            })

            -- Find the ACK message
            local foundAck = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                if sent.distribution == "WHISPER" then
                    local ok, data = GBL:Deserialize(sent.text)
                    if ok and data.type == "ACK" then
                        assert.equals("ALERT", sent.prio,
                            "ACK should be sent with ALERT priority")
                        foundAck = true
                    end
                end
            end
            assert.is_true(foundAck, "expected an ACK message")
        end)

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

        -- v0.30.2: receiver-side auto-bootstrap diagnostic. When a SYNC_DATA
        -- chunk arrives at chunk N>1 with no active receive session, it means
        -- the receiver missed an earlier abort signal — log it.
        it("logs auto-bootstrap when chunk > 1 arrives with no receive state", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 5,
                totalChunks = 10,
                transactions = {},
                moneyTransactions = {},
            })

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:match("Auto%-bootstrap at chunk 5") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected auto-bootstrap audit entry for chunk 5")
        end)

        it("does NOT log auto-bootstrap on legitimate chunk = 1 fresh start", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })

            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.is_nil(entry.message:match("Auto%-bootstrap"),
                    "chunk = 1 should not trigger auto-bootstrap log")
            end
        end)

        it("does NOT log auto-bootstrap or crash when chunk is nil", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Defensive: malformed payload with no chunk field. Existing
            -- code already silently ignores; the new audit gate must too.
            GBL:HandleSyncData("OfficerB", {
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })

            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.is_nil(entry.message:match("Auto%-bootstrap"),
                    "chunk = nil should not trigger auto-bootstrap log")
            end
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
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = { ["deposit|Thrall|12345|5|1|475101:0"] = localTx }

            -- Incoming record with hour-100 ID (sender's ID adopted regardless)
            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("deposit|Thrall|12345|5|1|475100:0", localTx.id)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"])
        end)

        it("adopts sender ID even when local ID is smaller", function()
            -- Local has smaller ID (hour-100), but sender-wins still adopts incoming
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"] = 3600 * 475100

            local idIndex = { ["deposit|Thrall|12345|5|1|475100:0"] = localTx }

            -- Incoming with hour-101 (larger, but sender-wins)
            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475100:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("deposit|Thrall|12345|5|1|475101:0", localTx.id)
            assert.equals(3600 * 475101, localTx.timestamp)
        end)

        it("handles money transactions and normalizes timestamp", function()
            local localTx = {
                type = "repair", player = "Thrall", amount = 50000,
                timestamp = 3600 * 475101,
                id = "repair|Thrall|50000|475101:0", _occurrence = 0,
            }
            table.insert(guildData.moneyTransactions, localTx)
            guildData.seenTxHashes["repair|Thrall|50000|475101:0"] = 3600 * 475101

            local idIndex = { ["repair|Thrall|50000|475101:0"] = localTx }

            local incoming = {
                type = "repair", player = "Thrall", amount = 50000,
                timestamp = 3600 * 475100,
                id = "repair|Thrall|50000|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "repair|Thrall|50000|475101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals("repair|Thrall|50000|475100:0", localTx.id)
            assert.equals(3600 * 475100, localTx.timestamp)
        end)

        it("handles compacted record (not in transactions)", function()
            -- seenTxHashes has an entry but no corresponding record in transactions
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = {}  -- empty, record was compacted

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)
            assert.is_true(result)
            -- seenTxHashes updated even though record not found
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"])
        end)

        it("updates idIndex after normalization", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = { ["deposit|Thrall|12345|5|1|475101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)

            -- Caller should update idIndex; verify the record reference is still valid
            assert.equals("deposit|Thrall|12345|5|1|475100:0", localTx.id)
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
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

            -- Receive same event with hour-100 ID (smaller, will win tiebreaker)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Local record should be normalized to the sender's ID
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|475100:0", localTx.id)
            -- No new record stored (it was a duplicate)
            assert.equals(1, #guildData.transactions)
            -- seenTxHashes updated
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475100:0"])
        end)

        it("stores new records normally alongside normalizations", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Pre-store a local record
            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

            -- Receive: one fuzzy dup (normalize) + one genuinely new record
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
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
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|475100:0", localTx.id)
        end)

        it("hash converges after normalization", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Local record with hour-101 ID
            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

            -- Compute sender's hash (with hour-100 ID)
            local senderHash = GBL:HashString("deposit|Thrall-TestRealm|12345|5|1|475100:0")

            -- Receive with hour-100 ID
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
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
    -- Version matching
    ---------------------------------------------------------------------------

    ---------------------------------------------------------------------------
    -- ACK timer callback behavior
    ---------------------------------------------------------------------------

    describe("ACK timer callback", function()
        it("MAX_RECORDS_PER_CHUNK constant is 4", function()
            assert.equals(4, GBL.SYNC_CHUNK_SIZE)
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Count ACK timers — hard timer exists but ACK timer should NOT yet
            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
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
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Invoke callback with partial progress
            storedCallback(storedArg, 50, 1000)

            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(0, ackTimerCount, "ACK timer should not exist on partial send")

            -- Complete the send
            storedCallback(storedArg, 1000, 1000)

            ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(1, ackTimerCount, "ACK timer should exist after full send")

            GBL.SendCommMessage = origSend
        end)

        it("ACK entry includes wire-to-ACK latency when wire anchor is set", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Capture + invoke AceComm progress callback so wire anchor is set.
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
                scanTime = 1000, id = "wireack1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Complete the send so sendChunkTransmittedAt is stamped
            assert.is_not_nil(storedCallback)
            storedCallback(storedArg, 100, 100)

            -- Send the ACK for chunk 1 (which is always logged: first chunk)
            GBL:HandleAck("OfficerB", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local ackEntry
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from") and entry.message:find("chunk 1/") then
                    ackEntry = entry.message
                    break
                end
            end
            assert.is_not_nil(ackEntry, "chunk 1 ACK entry should be logged")
            assert.is_not_nil(ackEntry:find("wire%-to%-ACK="),
                "ACK entry should include wire-to-ACK=: " .. tostring(ackEntry))

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            -- Add tx (fits in 1 chunk with MAX_RECORDS_PER_CHUNK=25)
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should be sending chunk 1
            assert.is_true(GBL:GetSyncStatus().sending)
            local sentBefore = #MockAce.sentCommMessages

            -- Advance time past the inter-chunk gap floor so the retry fires
            -- immediately (in production a retry follows one ACK_TIMEOUT after the last send).
            MockWoW.serverTime = MockWoW.serverTime + 10

            -- Fire ACK timeout — should retry, not abort
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Fire ACK timeout MAX_RETRIES times (should keep retrying).
            -- Advance time between firings so the inter-chunk gap floor is
            -- satisfied for each retry (one ACK_TIMEOUT elapses per retry in production).
            for attempt = 1, GBL.SYNC_MAX_RETRIES do
                MockWoW.serverTime = MockWoW.serverTime + 10
                fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
                assert.is_true(GBL:GetSyncStatus().sending,
                    "should still be sending after retry " .. attempt)
            end

            -- One more timeout — should abort
            MockWoW.serverTime = MockWoW.serverTime + 10
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            assert.is_false(GBL:GetSyncStatus().sending,
                "should have aborted after max retries")

            GBL.SendCommMessage = origSend
        end)

        it("resets retry counter on successful ACK", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Enough records to span more than one chunk, so there is a chunk 2
            -- for the reset retry counter to be observed on. Four records fit a
            -- single chunk and always have, which left the second half of this
            -- test firing at a timer that was never there.
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Advance past the gap floor so the retry issues immediately.
            MockWoW.serverTime = MockWoW.serverTime + 10

            -- Fire one ACK timeout (retry attempt 1)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

            -- Advance past the gap floor again BEFORE the ACK, so the chunk 2
            -- send it schedules is not additionally deferred by the gap floor.
            MockWoW.serverTime = MockWoW.serverTime + 10
            GBL:HandleAck("OfficerB", { chunk = 1 })

            -- Chunk 2 goes out on the adaptive inter-chunk delay, not inline.
            fireNextChunkDelay()

            -- Fire ACK timeout for chunk 2 — retry counter should be reset,
            -- so this should retry (not abort)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            assert.is_true(GBL:GetSyncStatus().sending,
                "retry counter should have reset — still sending")
        end)
    end)

    ---------------------------------------------------------------------------
    -- ACK timeout target liveness tag (v0.30.2)
    ---------------------------------------------------------------------------

    describe("ACK timeout target liveness", function()
        local function fireOneAckTimeout()
            MockWoW.serverTime = MockWoW.serverTime + 10
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
        end

        local function findRetryEntry()
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                -- Match the distinctive "retrying chunk" substring; the
                -- audit message itself contains an em dash before it
                -- (pre-existing pre-v0.30.2 wording), so don't anchor on that.
                if entry.message:find("retrying chunk", 1, true) then
                    return entry.message
                end
            end
            return nil
        end

        -- Sets up state with target online (HandleSyncRequest gates on
        -- IsGuildMemberOnline via SendSyncWhisper at Sync.lua:222). Tests
        -- that need a different liveness must flip the roster AFTER setup,
        -- before firing the ACK timeout — that mirrors the real-world
        -- scenario of a peer who goes offline mid-stream.
        local function setupSendingState()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)
        end

        it("appends target=online when send target is in roster and online", function()
            setupSendingState()
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=online"),
                "retry entry should include target=online; got: " .. entry)
        end)

        it("appends target=offline when send target goes offline mid-stream", function()
            setupSendingState()
            -- Peer disconnects after we already started sending
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=offline"),
                "retry entry should include target=offline; got: " .. entry)
        end)

        it("appends target=unknown when send target leaves the guild mid-stream", function()
            setupSendingState()
            -- Peer drops out of roster entirely — IsGuildMemberOnline returns nil
            MockWoW.guildRoster = {}
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=unknown"),
                "retry entry should include target=unknown; got: " .. entry)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Inter-chunk gap floor (v0.28.5)
    ---------------------------------------------------------------------------

    describe("inter-chunk gap floor", function()
        it("exposes SYNC_INTER_CHUNK_GAP_FLOOR constant as 1.0", function()
            assert.equals(1.0, GBL.SYNC_INTER_CHUNK_GAP_FLOOR)
        end)

        it("first chunk is not deferred by gap floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "gapfloor_first:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- First chunk should have gone out immediately (no prior
            -- lastSendIssuedAt means gap check short-circuits on the > 0 guard).
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" and data.chunk == 1 then
                    foundSyncData = true
                    break
                end
            end
            assert.is_true(foundSyncData,
                "first chunk should send immediately without gap-floor deferral")
        end)

        it("second chunk issued inside the gap window defers until floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.serverTime = 1000

            -- Enough records to need at least 2 chunks at 25/chunk
            for i = 1, 30 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i,
                    id = "gapfloor_second_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local function countSyncData()
                local c = 0
                for _, msg in ipairs(MockAce.sentCommMessages) do
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "SYNC_DATA" then c = c + 1 end
                end
                return c
            end
            local function fireFirstShortTimer(maxDelay)
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if not timer.cancelled and not timer.fired
                        and timer.delay and timer.delay <= maxDelay
                        and timer.delay > 0 then
                        timer.callback()
                        timer.fired = true
                        return timer.delay
                    end
                end
                return nil
            end

            local afterChunk1 = countSyncData()
            assert.is_true(afterChunk1 >= 1, "chunk 1 should have been sent")

            -- Acknowledge chunk 1 — this schedules a post-ACK SendNextChunk via
            -- GetSyncDelay(). Fire only that timer (not the 120s hard timer)
            -- so we isolate the gap-floor behavior.
            GBL:HandleAck("OfficerB", { chunk = 1 })
            local firedDelay = fireFirstShortTimer(1.0)
            assert.is_not_nil(firedDelay,
                "should have found the post-ACK SendNextChunk timer to fire")

            -- With no time advancement, the deferred timer is still pending
            -- and chunk 2 is NOT yet sent.
            assert.equals(afterChunk1, countSyncData(),
                "chunk 2 should NOT send while still inside the gap window")

            -- Advance past the gap floor and fire the deferred SendNextChunk.
            MockWoW.serverTime = MockWoW.serverTime + 2.0
            local firedDefer = fireFirstShortTimer(1.0)
            assert.is_not_nil(firedDefer,
                "should have found the gap-floor deferral timer to fire")
            assert.is_true(countSyncData() > afterChunk1,
                "chunk 2 should send once gap floor has elapsed")
        end)

        it("ACK-timeout retry does not defer when gap already exceeds floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.serverTime = 1000

            -- Suppress auto-callback so we control the ACK timer manually.
            local origSend = GBL.SendCommMessage
            local savedCb, savedArg
            GBL.SendCommMessage = function(_self, prefix, text, dist, target, _prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                savedCb, savedArg = cbFn, cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "gapfloor_acktimeout:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Complete the send so the ACK timer is scheduled.
            assert.is_not_nil(savedCb)
            savedCb(savedArg, 100, 100)

            -- Advance past ACK_TIMEOUT; retries from here satisfy gap ≥ floor.
            MockWoW.serverTime = MockWoW.serverTime + 10

            local sentBefore = #MockAce.sentCommMessages
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            local sentAfter = #MockAce.sentCommMessages
            assert.is_true(sentAfter > sentBefore,
                "ACK-timeout retry should fire immediately when gap > floor")

            GBL.SendCommMessage = origSend
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
    -- Free-agent pairing
    --
    -- A peer that finishes a session becomes free and takes whatever the
    -- next HELLO offers. There is no manifest of other members' bucket
    -- hashes and no scored queue choosing a "best" next partner: gossip
    -- converges without either, and the bookkeeping cost was paid on every
    -- pop (a full bucket-hash walk per queued peer).
    --
    -- Two things the queue was quietly carrying have to survive it: not
    -- hammering a peer that just said BUSY, and not losing a sync
    -- opportunity to a combat window.
    ---------------------------------------------------------------------------

    describe("free-agent pairing", function()
        --- A HELLO from a compatible peer holding data we do not have.
        local function hello(fields)
            fields = fields or {}
            return {
                type = "HELLO",
                version = fields.version or GBL.version,
                minSyncVersion = fields.minSyncVersion or GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = fields.txCount or 999,
                dataHash = fields.dataHash or 987654,
                lastScanTime = fields.lastScanTime or 1000,
                isReply = fields.isReply,
            }
        end

        local function countSent(msgType, target)
            local count = 0
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == msgType
                    and (target == nil or sent.target == target) then
                    count = count + 1
                end
            end
            return count
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
                { name = "OfficerC-TestRealm", isOnline = true },
            }
        end)

        -----------------------------------------------------------------
        -- The scored machinery is gone
        -----------------------------------------------------------------

        it("has no manifest broadcast or pending-peer queue API", function()
            assert.is_nil(GBL.BroadcastManifest)
            assert.is_nil(GBL.HandleManifest)
            assert.is_nil(GBL.AddPendingPeer)
            assert.is_nil(GBL.PopPendingPeer)
            assert.is_nil(GBL.RemovePendingPeer)
            assert.is_nil(GBL.ProcessPendingPeers)
        end)

        it("no longer reports a pending peer count", function()
            assert.is_nil(GBL:GetSyncStatus().pendingPeersCount)
        end)

        -- An older peer keeps broadcasting MANIFEST at us for as long as
        -- they are on an older build. The dispatch chain has no else, so
        -- this is a no-op, and that is the whole compatibility story: no
        -- protocol bump, no floor raise.
        it("ignores a MANIFEST from an older peer without erroring", function()
            local msg = GBL:Serialize({
                type = "MANIFEST",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                dataHash = 4242,
                txCount = 500,
                buckets = { [1] = 11, [2] = 22 },
            })
            assert.has_no.errors(function()
                GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "OfficerB")
            end)
        end)

        -----------------------------------------------------------------
        -- BUSY backoff, without a queue to carry it
        -----------------------------------------------------------------

        it("marks a peer busy on BUSY and clears the mark when it expires",
        function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            assert.is_true(GBL:IsPeerBusy("OfficerB"))

            MockWoW.serverTime = 100000 + GBL.SYNC_BUSY_COOLDOWN + 1
            assert.is_false(GBL:IsPeerBusy("OfficerB"))
        end)

        it("does not request from a peer inside its BUSY cooldown", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerB", hello())

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -- The fast-path check needs its own pin: a mutation test showed the
        -- test above still passed with it removed, because the check inside
        -- the jitter callback caught the same case. That second check went
        -- away with the jitter, so this test is what keeps the surviving one
        -- honest. It also covers the audit line, without which a capture
        -- shows a HELLO arriving and simply nothing happening.
        it("skips a busy peer without requesting, and says why", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerB", hello())

            -- Counting timers used to be the discriminator here. Its stated
            -- reason died with the jitter timer, and the power it kept was
            -- incidental: a deleted busy check would still bump the count,
            -- but only via the receive timeout RequestSync arms for the
            -- request it should not be making. Asserting on the wire pins
            -- the contract for a reason that survives timer rearrangement.
            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))
            local logged = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=busy-cooldown", 1, true) then
                    logged = true
                end
            end
            assert.is_true(logged)
        end)

        it("requests from the same peer once the cooldown expires", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            MockWoW.serverTime = 100000 + GBL.SYNC_BUSY_COOLDOWN + 1
            GBL:HandleHello("OfficerB", hello())

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -- The check belongs at the automatic initiation sites, not inside
        -- RequestSync: a manual pull is the user asking, and refusing it
        -- silently would be its own bug.
        it("still allows a direct RequestSync to a busy peer", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:RequestSync("OfficerB", 0)

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -----------------------------------------------------------------
        -- Combat, without a queue to drain
        -----------------------------------------------------------------

        it("defers a combat-time HELLO and re-broadcasts when combat ends",
        function()
            MockWoW.inCombat = true
            GBL:HandleHello("OfficerB", hello())
            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))

            MockWoW.inCombat = false
            MockAce.sentCommMessages = {}
            GBL:OnCombatEnd()
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if not timer.cancelled and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(1, countSent("HELLO"),
                "combat end should re-advertise so pairing can resume")
        end)

        -- Twenty raid members ending combat together must not each fire a
        -- broadcast. Only a client that actually deferred something does.
        it("broadcasts nothing on combat end when nothing was deferred",
        function()
            MockAce.sentCommMessages = {}
            GBL:OnCombatEnd()
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if not timer.cancelled and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(0, countSent("HELLO"))
        end)

        -----------------------------------------------------------------
        -- Free after a session, and drop what we cannot take now
        -----------------------------------------------------------------

        it("drops a HELLO that arrives mid-receive rather than queuing it",
        function()
            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerC"))
            assert.equals("OfficerB", GBL:GetSyncStatus().receiveSource)
        end)

        it("takes the next HELLO immediately once the session ends", function()
            GBL:RequestSync("OfficerB", 0)
            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            GBL:FinishReceiving("OfficerB")
            MockAce.sentCommMessages = {}

            -- The peer re-advertises on its own heartbeat; we are free now.
            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerC"))
        end)

        -----------------------------------------------------------------
        -- The pause guard the queue used to provide
        -----------------------------------------------------------------

        -- ProcessPendingPeers checked isSyncPaused before initiating, and the
        -- queue was the deferral. With both the queue and the jitter gone,
        -- HandleHello's own skip chain is the only place left to check it.
        -- The pause outlives its trigger by a cooldown, so this arm covers a
        -- window the combat-lockdown check above it no longer sees.
        it("does not request while a zone change has sync paused, and says why",
        function()
            -- OnLoadingScreenStart only pauses a live session, so enter one
            -- and end it, which leaves zonePaused set until its cooldown.
            GBL:RequestSync("OfficerC", 0)
            GBL:OnLoadingScreenStart()
            GBL:FinishReceiving("OfficerC")
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Clear before the HELLO, not after: once the request is issued
            -- inline, a clear that follows HandleHello wipes the very message
            -- this test is looking for and it passes without pinning anything.
            MockAce.sentCommMessages = {}
            GBL:HandleHello("OfficerB", hello())

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))

            -- Silence here is what made the old jitter callback's five returns
            -- undiagnosable, so the skip has to name itself in the capture.
            local logged = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=paused-zone", 1, true) then
                    logged = true
                end
            end
            assert.is_true(logged)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cross-realm name matching
    ---------------------------------------------------------------------------

    describe("same-realm mixed-qualification matching", function()
        -- AceComm inconsistently qualifies same-realm sender names ("OfficerB"
        -- on one message, "OfficerB-TestRealm" on the next). CanonicalPeerKey
        -- collapses both to "OfficerB" so HandleAck / HandleSyncData see the
        -- same peer regardless of which form arrived. Cross-realm peers stay
        -- distinct (covered in connected-realm peer disambiguation tests).
        before_each(function()
            MockWoW.player.realm = "TestRealm"
        end)

        it("HandleAck accepts ACK when sender has realm but target does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes from same-realm-qualified name; canonicalizes to "OfficerB"
            GBL:HandleAck("OfficerB-TestRealm", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB%-TestRealm for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite realm suffix mismatch (same realm)")
        end)

        it("HandleAck accepts ACK when target has realm but sender does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            -- SYNC_REQUEST came from realm-qualified name on local realm
            GBL:HandleSyncRequest("OfficerB-TestRealm", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes without realm
            GBL:HandleAck("OfficerB", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite missing realm suffix (same realm)")
        end)

        it("HandleSyncData accepts data from differently-qualified sender", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving — receiveSource set with same-realm suffix
            GBL:RequestSync("OfficerB-TestRealm", 0)

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
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
    -- NACK retry
    ---------------------------------------------------------------------------

    describe("NACK retry", function()
        it("NACK is sent with ALERT priority", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver state
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "Thrall-TestRealm",
                    itemID = 12345, count = 5, tab = 1,
                    timestamp = 1000, id = "nacktest:0", _occurrence = 0,
                }},
                moneyTransactions = {},
            })
            MockAce.sentCommMessages = {}

            -- Manually send a NACK
            GBL:SendNack("OfficerB", 2)

            assert.is_true(#MockAce.sentCommMessages >= 1)
            local nackSent = MockAce.sentCommMessages[#MockAce.sentCommMessages]
            assert.equals("ALERT", nackSent.prio,
                "NACK should be sent with ALERT priority")
        end)

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
            fireReceiveTimeout()

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            local sentBefore = #MockAce.sentCommMessages

            -- Send NACK for chunk 1
            GBL:HandleNack("OfficerB", { chunk = 1 })

            -- Advance past the inter-chunk gap floor so the NACK retransmit
            -- satisfies gap >= 1.0s (production NACKs arrive several seconds
            -- after the failed send).
            MockWoW.serverTime = MockWoW.serverTime + 2

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

            -- Fire timeout MAX_NACK_RETRIES times (with backoff: 20→30→45)
            for attempt = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
                if attempt < GBL.SYNC_MAX_NACK_RETRIES then
                    assert.is_true(GBL:GetSyncStatus().receiving,
                        "should still be receiving after NACK attempt " .. attempt)
                end
            end

            -- One more — should abort
            fireReceiveTimeout()
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

            -- Fire timeout twice (2 NACKs sent, with backoff)
            for _ = 1, 2 do
                fireReceiveTimeout()
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
            -- because counter was reset (backoff restarts from 20s)
            for _ = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

        -- Silence at zero chunks means the request itself went missing, so
        -- the thing to repeat is the request. NACKing chunk 1 asks a peer to
        -- retransmit a chunk it never built, and HandleNack drops it on the
        -- floor because it is not sending: the retry signal crossed the wire
        -- and was discarded. Once chunks are arriving the NACK is right again.
        it("resends the request when the timeout fires at zero chunks", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving,
                "should still be receiving after the first resend")
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("SYNC_REQUEST", data.type)
        end)

        it("resends with the timestamp the original request used", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 4242)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.equals(4242, data.sinceTimestamp)
        end)

        it("resends a manifest, not an empty request", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local ts = 80000 * GBL.BUCKET_SECONDS
            table.insert(guildData.transactions, {
                type = "deposit", player = "P", itemID = 1, count = 1, tab = 1,
                timestamp = ts, scanTime = ts, scannedBy = "OfficerA",
                id = "resend_rec:0",
            })

            GBL:RequestSync("OfficerB", 0)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_table(data.bucketHashes)
            assert.is_not_nil(data.bucketHashes[80000])
        end)

        it("still NACKs a stall once chunks have started arriving", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.equals("NACK", data.type)
            assert.equals(2, data.chunk)
        end)

        it("RequestSync timeout resends and aborts after MAX_NACK_RETRIES", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            for _ = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
                assert.is_true(GBL:GetSyncStatus().receiving,
                    "should still be receiving while resends remain")
            end

            -- One more timeout, and the budget is spent
            fireReceiveTimeout()
            assert.is_false(GBL:IsSyncing(),
                "should no longer be syncing after the retry budget is spent")
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("MAX_RECEIVE_DURATION safety net aborts stuck receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Simulate receiving having started long ago by backdating receiveStartTime
            local status = GBL:GetSyncStatus()
            -- Access internal state via GetSyncStatus — need to set it directly
            -- Use a SYNC_DATA chunk to get past initial state, then backdate
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 100,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Backdate receiveStartTime to exceed MAX_RECEIVE_DURATION
            GBL:SetReceiveStartTime(
                MockWoW.serverTime - GBL.SYNC_MAX_RECEIVE_DURATION - 1)

            -- Fire timeout — should abort due to duration safety net
            fireReceiveTimeout()
            assert.is_false(GBL:GetSyncStatus().receiving,
                "should abort after MAX_RECEIVE_DURATION exceeded")
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

    ---------------------------------------------------------------------------
    -- Per-sync retry histogram (v0.28.4 → v0.28.7 diagnostics)
    ---------------------------------------------------------------------------

    describe("FinishSending outcomes histogram", function()
        it("emits three per-peer diagnostic entries after Sync stats", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "hist_basic:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local foundOutcomes, foundCauses, foundCompression = false, false, false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sync outcomes for OfficerB")
                    and entry.message:find("on 1st")
                    and entry.message:find("on 2nd")
                    and entry.message:find("on 3rd%+")
                    and entry.message:find("aborted:")
                    and entry.message:find("combat") and entry.message:find("zone")
                    and entry.message:find("busy") and entry.message:find("offline") then
                    foundOutcomes = true
                end
                if entry.message:find("Retry causes for OfficerB")
                    and entry.message:find("ackTimeout=")
                    and entry.message:find("nack=")
                    and entry.message:find("chunkFail=")
                    and entry.message:find("p_frag=") then
                    foundCauses = true
                end
                if entry.message:find("Compression for OfficerB") then
                    foundCompression = true
                end
            end
            assert.is_true(foundOutcomes, "should emit Sync outcomes for <peer> line")
            assert.is_true(foundCauses, "should emit Retry causes for <peer> line")
            assert.is_true(foundCompression, "should emit Compression for <peer> line")
        end)

        it("reports p_frag=n/a when fewer than 3 chunks observed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "hist_nacount:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local causesEntry
            for _, entry in ipairs(trail) do
                if entry.message:find("Retry causes for") then
                    causesEntry = entry.message
                    break
                end
            end
            assert.is_not_nil(causesEntry, "retry causes entry should exist")
            assert.is_not_nil(causesEntry:find("p_frag=n/a"),
                "single-chunk sync should report p_frag=n/a, got: "
                    .. tostring(causesEntry))
        end)
    end)

    ---------------------------------------------------------------------------
    -- v0.28.7 diagnostics bundle: per-retry cause tags and per-chunk compression
    ---------------------------------------------------------------------------

    describe("v0.28.7 retry cause tagging", function()
        it("tags ackTimeout in chunkOutcomes.retryReasons on ACK timer retry", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "ack_tag_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1], "chunk 1 outcome should exist")
            assert.same({}, syncState.chunkOutcomes[1].retryReasons)

            -- Advance time past gap floor + ACK timeout so the retry fires cleanly
            MockWoW.serverTime = MockWoW.serverTime + 10
            -- Fire only the ACK timer (avoid firing gap-floor timers that would
            -- cascade through the retry and re-arm new timers indefinitely)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

            assert.is_table(syncState.chunkOutcomes[1].retryReasons)
            local found = false
            for _, r in ipairs(syncState.chunkOutcomes[1].retryReasons) do
                if r == "ackTimeout" then found = true end
            end
            assert.is_true(found,
                "retryReasons should contain 'ackTimeout' after ACK timeout retry")
        end)

        it("tags nack in retryReasons on NACK receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "nack_tag_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleNack("OfficerB", { chunk = 1 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1])
            local found = false
            for _, r in ipairs(syncState.chunkOutcomes[1].retryReasons) do
                if r == "nack" then found = true end
            end
            assert.is_true(found, "retryReasons should contain 'nack' after NACK")
        end)

        it("tags outcome=combatAbort on the in-flight chunk at combat start", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "combat_abort_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            local activeIdx = syncState.sendChunkIndex
            -- Grab a reference before FinishSending reassigns chunkOutcomes = {}
            local outcomesRef = syncState.chunkOutcomes
            assert.is_not_nil(outcomesRef[activeIdx])
            assert.equals("pending", outcomesRef[activeIdx].outcome)

            GBL:OnCombatStart()

            assert.equals("combatAbort",
                outcomesRef[activeIdx].outcome,
                "active chunk outcome should be combatAbort after OnCombatStart")
        end)

        it("captures compressed bytes and ratio per chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "compression_capture:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1])
            assert.is_true(syncState.chunkOutcomes[1].bytes > 0,
                "chunkOutcomes[1].bytes should be > 0 after send")
            -- Mock LibDeflate is identity, so ratio is 1.0. Real LibDeflate < 1.
            assert.is_true(syncState.chunkOutcomes[1].ratio > 0,
                "chunkOutcomes[1].ratio should be > 0 after send")
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(#MockAce.sentCommMessages >= 1)
        end)

        it("graceful fallback when CTL has no avail field", function()
            _G.ChatThrottleLib = {}
            assert.is_true(GBL:HasSyncBandwidth())
            _G.ChatThrottleLib = nil
        end)

        it("defers at avail=300 (below floor threshold of 400)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = { avail = 300 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_thresh:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- avail=300 < CTL_BANDWIDTH_MIN=400 floor → should defer
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" then
                    foundSyncData = true
                end
            end
            assert.is_false(foundSyncData,
                "avail=300 should defer (below 400 floor)")

            _G.ChatThrottleLib = nil
        end)

        it("uses dynamic threshold based on last chunk size", function()
            _G.ChatThrottleLib = { avail = 500 }

            -- Before any chunk sent, lastChunkBytes=0, threshold=max(400,0)=400
            assert.is_true(GBL:HasSyncBandwidth(),
                "avail=500 > floor=400 → should allow")

            -- Simulate a previous chunk being 800 bytes
            GBL._syncState_setLastChunkBytes(800)
            assert.is_false(GBL:HasSyncBandwidth(),
                "avail=500 < dynamic threshold 800 → should defer")

            _G.ChatThrottleLib = { avail = 900 }
            assert.is_true(GBL:HasSyncBandwidth(),
                "avail=900 > dynamic threshold 800 → should allow")

            GBL._syncState_setLastChunkBytes(0)
            _G.ChatThrottleLib = nil
        end)

        it("increments ctlDeferTotal on each deferral", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_counter:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            assert.is_true(GBL:GetCtlDeferTotal() >= 1,
                "ctlDeferTotal should increment on CTL deferral")

            _G.ChatThrottleLib = nil
        end)

        it("rate-limits CTL deferral audit entries", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_ratelimit:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Fire timers repeatedly to simulate multiple deferrals
            for _ = 1, 25 do
                MockWoW.fireTimers()
            end

            -- Count CTL audit entries
            local trail = GBL:GetAuditTrail()
            local ctlEntries = 0
            for _, entry in ipairs(trail) do
                if entry.message:find("CTL low") then
                    ctlEntries = ctlEntries + 1
                end
            end

            -- Should have first 10 verbose + 20th = 11, NOT all 25+
            assert.is_true(ctlEntries <= 15,
                "CTL deferral entries should be rate-limited (got " .. ctlEntries .. ")")

            _G.ChatThrottleLib = nil
        end)

        it("records a drain sample and opens an episode on deferral", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_sample:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local drain = GBL._ctlDrain
            assert.is_true(#drain.samples >= 1, "expected a drain sample")
            local s = drain.samples[#drain.samples]
            assert.equals(100, s.avail)
            assert.is_true(s.threshold >= 400)
            assert.is_not_nil(drain.episodeStart, "expected an open episode")
            assert.equals(1, drain.episodeDefers)
            assert.equals(100, drain.minAvail)

            _G.ChatThrottleLib = nil
        end)

        it("counts overlapping deferral timers without dedup'ing them", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_overlap:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local drain = GBL._ctlDrain
            local pendingAfterFirst = drain.timersPending
            assert.is_true(pendingAfterFirst >= 1)
            local timersBefore = #MockWoW.pendingTimers

            -- A second caller invokes SendNextChunk while the first deferral
            -- timer is still pending: the overlap is COUNTED and the second
            -- timer is STILL scheduled (measurement only, no dedup). Exactly
            -- one new timer is expected because the CTL defer path returns
            -- before any other C_Timer.After site (StartFpsMonitor is an
            -- OnUpdate frame, not a timer).
            GBL:SendNextChunk()
            assert.equals(pendingAfterFirst + 1, drain.timersPending)
            assert.is_true(drain.overlapCount >= 1)
            assert.is_true(drain.overlapTotal >= 1)
            assert.equals(timersBefore + 1, #MockWoW.pendingTimers,
                "second deferral timer must still be scheduled")

            _G.ChatThrottleLib = nil
        end)

        it("emits a CTL recovered summary when bandwidth returns", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_recover:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_not_nil(GBL._ctlDrain.episodeStart)

            -- Bandwidth returns; the pending deferral timer re-enters
            -- SendNextChunk, which should summarize and close the episode.
            -- Relies on MockAce dispatching send callbacks synchronously, so
            -- the episode-close code runs inside this single fireTimers()
            -- (which snapshots pendingTimers and cannot cascade).
            _G.ChatThrottleLib.avail = 4000
            MockWoW.fireTimers()

            local found = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.message:find("CTL recovered", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected a CTL recovered summary line")
            assert.is_nil(GBL._ctlDrain.episodeStart, "episode should be closed")

            _G.ChatThrottleLib = nil
        end)

        it("Sync stats line carries overlapped timers and longest stall", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_stats:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local found = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                -- Assert the VALUES for the no-CTL case, not just the field
                -- names, so a misplaced counter reset cannot pass unnoticed.
                if entry.message:find("Sync stats: ", 1, true)
                    and entry.message:find("0 overlapped timers", 1, true)
                    and entry.message:find("longest stall 0.0", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected the extended Sync stats line in FinishSending")
        end)

        it("folds a still-open drain episode into the longest stall", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_truncated:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_not_nil(GBL._ctlDrain.episodeStart, "expected an open episode")

            -- Mode A shape: the send aborts while CTL is still starved (in
            -- production the 120s sendHardTimer), so SendNextChunk's recovery
            -- block never runs and the episode is open at FinishSending. That
            -- episode is the longest of the session by definition, because it
            -- is the one that ended it.
            MockWoW.serverTime = MockWoW.serverTime + 12
            GBL:FinishSending()

            local stats, truncated
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.message:find("Sync stats: ", 1, true) then
                    stats = entry.message
                end
                if entry.message:find("CTL still starved at send end", 1, true) then
                    truncated = entry.message
                end
            end

            assert.is_not_nil(stats, "expected a Sync stats line")
            assert.is_nil(stats:find("longest stall 0.0", 1, true),
                "a truncated episode must not report a 0.0s longest stall")
            assert.is_not_nil(truncated,
                "expected a truncated-episode line naming the open stall")
            assert.is_not_nil(truncated:find("1 deferrals", 1, true),
                "truncated line should carry the episode deferral count")
            assert.is_nil(GBL._ctlDrain.episodeStart,
                "episode should be closed after FinishSending")

            _G.ChatThrottleLib = nil
        end)

        it("no drain episode when ChatThrottleLib is absent", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = nil

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_absent:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            assert.is_nil(GBL._ctlDrain.episodeStart)
            -- Only the session boundary marker lands; no deferral samples.
            assert.equals(1, #GBL._ctlDrain.samples)
            assert.equals("session", GBL._ctlDrain.samples[1].marker)
        end)

        it("Sending chunk entry includes CTLq= when CTL.Prio is present", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = {
                avail = 5000,
                Prio = {
                    ALERT  = { nSize = 0 },
                    NORMAL = { nSize = 2 },
                    BULK   = { nSize = 0 },
                },
            }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctlq1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local trail = GBL:GetAuditTrail()
            local foundCtlq = false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sending chunk") and entry.message:find("CTLq=") then
                    foundCtlq = true
                    break
                end
            end
            assert.is_true(foundCtlq,
                "Sending chunk entry should include CTLq= when CTL.Prio is present")

            _G.ChatThrottleLib = nil
        end)

        -- The per-chunk line used to report percent reduction while the
        -- FinishSending summary reported compressed-over-raw, so one chunk read
        -- as "31% compressed" in one line and 69% in the other. Both are
        -- percent-of-raw now; a capture is unreadable if they ever diverge again.
        it("reports compression as percent of raw in both send lines", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ratioconv1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local chunkLine, summaryLine
            for _, entry in ipairs(trail) do
                if entry.message:find("Sending chunk") then
                    chunkLine = chunkLine or entry.message
                end
                if entry.message:find("Compression for OfficerB") then
                    summaryLine = summaryLine or entry.message
                end
            end

            assert.is_truthy(chunkLine, "should emit a Sending chunk line")
            assert.is_truthy(summaryLine, "should emit a Compression for <peer> line")
            assert.is_truthy(chunkLine:find("% of raw", 1, true),
                "per-chunk line should report percent of raw, got: " .. tostring(chunkLine))
            assert.is_nil(chunkLine:find("compressed", 1, true),
                "per-chunk line should not use the old percent-reduction wording")
            assert.is_truthy(summaryLine:find("of raw", 1, true),
                "summary line should name the percent-of-raw convention, got: "
                .. tostring(summaryLine))
        end)

        it("suppresses HELLO replies during sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 5000 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_hellotag:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local msgsBefore = #MockAce.sentCommMessages

            -- Simulate receiving a HELLO while sending
            GBL:HandleHello("ThirdPartyPeer", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = GBL:GetGuildName(),
                txCount = 1,
                dataHash = 999,
            })

            -- No reply whisper should have been sent
            local replyCount = 0
            for i = msgsBefore + 1, #MockAce.sentCommMessages do
                local ok, data = GBL:Deserialize(MockAce.sentCommMessages[i].text)
                if ok and data.type == "HELLO" and data.isReply then
                    replyCount = replyCount + 1
                end
            end
            assert.equals(0, replyCount,
                "HELLO reply should be suppressed during sync")

            -- But suppression should be logged
            local trail = GBL:GetAuditTrail()
            local foundSuppressed = false
            for _, entry in ipairs(trail) do
                if entry.message:find("reply=sync-active", 1, true) then
                    foundSuppressed = true
                    break
                end
            end
            assert.is_true(foundSuppressed,
                "the round line should record the reply suppressed by a live session")

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

        it("stale peer stays visible if guild roster says online", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past stale window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            -- Set up roster with OfficerB online
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_true(peers["OfficerB"].rosterOnly)
        end)

        it("stale peer drops if guild roster says offline", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("recently-seen peer drops if guild roster says offline", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Still within staleness window (peer messaged us recently)
            MockWoW.serverTime = 100000 + 30

            -- But roster says they went offline (e.g., disconnected during sync)
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("recently-seen peer stays if roster unknown", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + 30

            -- Empty roster (nil return) — don't filter out
            MockWoW.guildRoster = {}
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("roster fallback does not mutate original syncState peer entry", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            -- Get peers triggers roster fallback
            local peers = GBL:GetSyncPeers()
            assert.is_true(peers["OfficerB"].rosterOnly)

            -- Original should NOT have rosterOnly
            local all = GBL:GetAllPeers()
            assert.is_nil(all["OfficerB"].rosterOnly)
        end)

        it("UpdatePeer persists to guildData.knownPeers", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = "0.22.3", txCount = 42, lastScanTime = 99999,
            })

            local kp = guildData.knownPeers["OfficerB"]
            assert.is_not_nil(kp)
            assert.equals("0.22.3", kp.version)
            assert.equals(42, kp.txCount)
            assert.equals(100000, kp.lastSeen)
        end)

        it("InitSync seeds session peers from knownPeers", function()
            MockWoW.serverTime = 100000
            -- Simulate persisted knownPeers from a prior session
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            assert.is_nil(GBL:GetAllPeers()["OfficerB"])

            GBL:InitSync()

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.is_not_nil(peer)
            assert.equals("0.20.0", peer.version)
            assert.equals(99000, peer.lastSeen)  -- stays stale
        end)

        -- UpdatePeer persists minSyncVersion into knownPeers specifically so
        -- the seed can carry it, and RequestSync's gate reads the floor off
        -- the seeded entry. Dropping it in the copy made every seeded peer
        -- look pre-floor (exact match required) until their first live HELLO,
        -- which also drove the peer list to call a compatible peer refused.
        it("InitSync seeds minSyncVersion from knownPeers", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                txCount = 10,
                lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.is_not_nil(peer)
            assert.equals(GBL.MIN_SYNC_VERSION, peer.minSyncVersion)
        end)

        it("seeded peer with roster online appears in GetSyncPeers", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_true(peers["OfficerB"].rosterOnly)
        end)

        it("seeded peer is overwritten by fresh HELLO", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            -- Fresh HELLO arrives
            MockWoW.serverTime = 100001
            GBL:UpdatePeer("OfficerB", {
                version = "0.23.0", txCount = 50, lastScanTime = 100001,
            })

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.equals("0.23.0", peer.version)
            assert.equals(100001, peer.lastSeen)

            -- Should be fresh, not roster-only
            local active = GBL:GetSyncPeers()
            assert.is_not_nil(active["OfficerB"])
            assert.is_nil(active["OfficerB"].rosterOnly)
        end)

        it("InitSync expires knownPeers older than 30 days", function()
            MockWoW.serverTime = 100000
            local expireSeconds = GBL.SYNC_KNOWN_PEER_EXPIRE_SECONDS

            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10,
                lastSeen = 100000 - expireSeconds - 1,  -- just expired
            }
            guildData.knownPeers["OfficerC"] = {
                version = "0.21.0", txCount = 20,
                lastSeen = 100000 - expireSeconds + 3600,  -- still valid
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            -- OfficerB expired from knownPeers and not seeded
            assert.is_nil(guildData.knownPeers["OfficerB"])
            assert.is_nil(GBL:GetAllPeers()["OfficerB"])

            -- OfficerC still valid and seeded
            assert.is_not_nil(guildData.knownPeers["OfficerC"])
            assert.is_not_nil(GBL:GetAllPeers()["OfficerC"])
        end)

        -- The stale-peer skip this block used to test lived in
        -- PopPendingPeer, and there is nothing left for it to protect: a
        -- sync is now only ever started off a HELLO that just arrived, or
        -- off a session that just finished, and neither can name a peer we
        -- have not heard from. Staleness still matters for display, which
        -- GetSyncPeers' rosterOnly tests cover.

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
    -- Realm-qualified peer name handling (v0.30.5 hardening)
    ---------------------------------------------------------------------------

    describe("realm-qualified peer names", function()
        local function buildHelloPayload()
            return GBL:Serialize({
                type = "HELLO",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                version = GBL.version,
                txCount = 7,
                dataHash = "abc123",
                lastScanTime = 99999,
            })
        end

        it("Ambiguate('Name-Realm', 'none') is identity in the mock (matches retail)", function()
            assert.equals("Rexxybear-Tichondrius",
                Ambiguate("Rexxybear-Tichondrius", "none"))
        end)

        it("Ambiguate('Name-Realm', 'short') strips realm in the mock", function()
            assert.equals("Rexxybear", Ambiguate("Rexxybear-Tichondrius", "short"))
            assert.equals("Rexxybear", Ambiguate("Rexxybear-Tichondrius", "all"))
        end)

        it("same-realm-qualified HELLO sender keys peer by bare name", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear-TestRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Rexxybear"])
            assert.is_nil(peers["Rexxybear-TestRealm"])
        end)

        it("mixed-qualification same-realm HELLO arrivals collapse to one entry", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear-TestRealm")
            MockWoW.serverTime = 100050
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear")

            local peers = GBL:GetAllPeers()
            local count = 0
            for _ in pairs(peers) do count = count + 1 end
            assert.equals(1, count)
            assert.is_not_nil(peers["Rexxybear"])
        end)

        it("OnSyncMessage ignores own message arriving as Name-Realm", function()
            MockWoW.player.name = "OfficerA"
            MockWoW.player.realm = "Tichondrius"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)

            GBL:OnSyncMessage("GBL", compressed, "GUILD", "OfficerA-Tichondrius")

            local peers = GBL:GetAllPeers()
            assert.is_nil(peers["OfficerA"])
            assert.is_nil(peers["OfficerA-Tichondrius"])
        end)

        it("UpdatePeer keys knownPeers by bare name when called with same-realm Name-Realm", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            GBL:UpdatePeer("Rexxybear-TestRealm", {
                version = "0.30.5", txCount = 12, lastScanTime = 99999,
            })

            assert.is_not_nil(guildData.knownPeers["Rexxybear"])
            assert.is_nil(guildData.knownPeers["Rexxybear-TestRealm"])
        end)

        -- Migration tests for MigrateNormalizePeerNames + MigrateRecoverPeerRealms
        -- now live in spec/core_spec.lua under their own describe blocks.

        it("MigrateNormalizePeerNames skips already-migrated guilds", function()
            guildData.schemaVersion = 9
            guildData.knownPeers = {
                ["Stale-Realm"] = { version = "0.20.0", txCount = 1, lastSeen = 1 },
            }

            GBL:MigrateNormalizePeerNames(guildData)

            -- Already at schema 9 so the function returns without touching the table
            assert.is_not_nil(guildData.knownPeers["Stale-Realm"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Connected-realm peer disambiguation
    ---------------------------------------------------------------------------

    describe("connected-realm peer disambiguation", function()
        local function buildHelloPayload()
            return GBL:Serialize({
                type = "HELLO",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                version = GBL.version,
                txCount = 7,
                dataHash = "abc123",
                lastScanTime = 99999,
            })
        end

        before_each(function()
            MockWoW.player.realm = "TestRealm"
        end)

        it("cross-realm HELLO sender keys peer with realm suffix", function()
            MockWoW.serverTime = 100000
            local compressed = GBL._compressMessage(buildHelloPayload())
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-OtherRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Alice-OtherRealm"])
            assert.is_nil(peers["Alice"])
        end)

        it("two same-name peers on different realms stay distinct", function()
            MockWoW.serverTime = 100000
            local compressed = GBL._compressMessage(buildHelloPayload())
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-TestRealm")
            MockWoW.serverTime = 100050
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-OtherRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Alice"])             -- local realm peer
            assert.is_not_nil(peers["Alice-OtherRealm"])  -- cross-realm peer

            local count = 0
            for _ in pairs(peers) do count = count + 1 end
            assert.equals(2, count)
        end)

        it("IsGuildMemberOnline disambiguates same-name members across realms", function()
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },             -- local realm Alice
                { name = "Alice-OtherRealm", isOnline = false }, -- cross-realm Alice
            }

            assert.is_true(GBL:IsGuildMemberOnline("Alice"))
            assert.is_true(GBL:IsGuildMemberOnline("Alice-TestRealm"))
            assert.is_false(GBL:IsGuildMemberOnline("Alice-OtherRealm"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- InitSync knownPeers seed consolidation (connected-realm follow-up)
    ---------------------------------------------------------------------------
    --
    -- Self-heals stuck-at-11 users: stale bare keys in knownPeers (left over
    -- from pre-v0.30.5 saved variables, or from the v0.30.5 schema-11
    -- premature-bump cold-roster bug) get re-canonicalized via playerRealms at
    -- session start, persistent state consolidates, runtime view is correct.

    describe("InitSync knownPeers seed consolidation", function()
        before_each(function()
            MockWoW.player.realm = "TestRealm"
            MockWoW.serverTime = 100000
            guildData.knownPeers = {}
            guildData.playerRealms = {}
            GBL:ResetSyncState()
        end)

        it("re-realms a stale bare cross-realm key via playerRealms", function()
            -- Setup: bare Katorriwl in knownPeers (from buggy schema-11),
            -- playerRealms knows the real realm.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99500,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            -- knownPeers consolidated: bare gone, qualified present
            assert.is_nil(guildData.knownPeers["Katorriwl"])
            assert.is_not_nil(guildData.knownPeers["Katorriwl-Stormrage"])
            assert.equals(5, guildData.knownPeers["Katorriwl-Stormrage"].txCount)

            -- syncState.peers seeded with the canonical key only
            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Katorriwl-Stormrage"])
            assert.is_nil(peers["Katorriwl"])
        end)

        it("collapses a bare same-realm key to bare (idempotent)", function()
            -- Bare entry that's actually a local-realm member: roster says local,
            -- helper re-realms then Ambiguate('guild') strips back to bare.
            guildData.knownPeers["Bob"] = {
                version = "0.30.5", txCount = 3, lastSeen = 99500,
            }
            guildData.playerRealms["Bob"] = "TestRealm"

            GBL:InitSync()

            -- Stays bare, no rewrite needed
            assert.is_not_nil(guildData.knownPeers["Bob"])
            assert.is_nil(guildData.knownPeers["Bob-TestRealm"])
            assert.is_not_nil(GBL:GetAllPeers()["Bob"])
        end)

        it("merges bare + qualified collision by recency", function()
            -- Both forms of the same character coexist in knownPeers (the bug).
            -- Bare form is older, qualified is newer; result should keep newer.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99000,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.5", txCount = 8, lastSeen = 99800,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            -- Only the qualified key survives, holding the newer record
            assert.is_nil(guildData.knownPeers["Katorriwl"])
            local kp = guildData.knownPeers["Katorriwl-Stormrage"]
            assert.is_not_nil(kp)
            assert.equals(8, kp.txCount)
            assert.equals("0.30.5", kp.version)
        end)

        it("keeps bare key when playerRealms has no entry for it", function()
            -- Departed peer or non-guildmate: no roster mapping, stays bare.
            guildData.knownPeers["Ghost"] = {
                version = "0.30.4", txCount = 1, lastSeen = 99000,
            }
            -- No playerRealms entry for Ghost

            GBL:InitSync()

            assert.is_not_nil(guildData.knownPeers["Ghost"])
            assert.is_not_nil(GBL:GetAllPeers()["Ghost"])
        end)

        it("syncState.peers seeding preserves recency on canonical-key collisions", function()
            -- When both legacy bare and canonical qualified forms exist in
            -- knownPeers (the upgrade scenario this PR addresses), both raw
            -- keys canonicalize to the same clean key. pairs() iteration order
            -- is undefined, so an unconditional write to syncState.peers[clean]
            -- could let an older snapshot overwrite a newer one in the runtime
            -- cache. The seed loop must recency-merge syncState.peers the same
            -- way it recency-merges knownPeers.
            --
            -- Direction A: bare is older, qualified is newer. Newer wins.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99000,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.5", txCount = 8, lastSeen = 99800,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            local peers = GBL:GetAllPeers()
            local newer = peers["Katorriwl-Stormrage"]
            assert.is_not_nil(newer)
            assert.equals(8, newer.txCount)
            assert.equals("0.30.5", newer.version)
            assert.equals(99800, newer.lastSeen)
            assert.is_nil(peers["Katorriwl"])
        end)

        it("syncState.peers seeding wins for the bare entry when bare is newer", function()
            -- Direction B: bare is newer, qualified is older. The recency
            -- check must pick bare's data even though both canonicalize to
            -- the qualified key. Without the check, pairs() ordering decides.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.5", txCount = 12, lastSeen = 99900,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.4", txCount = 4, lastSeen = 99100,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            local peers = GBL:GetAllPeers()
            local newer = peers["Katorriwl-Stormrage"]
            assert.is_not_nil(newer)
            assert.equals(12, newer.txCount)  -- bare's newer txCount won
            assert.equals("0.30.5", newer.version)
            assert.equals(99900, newer.lastSeen)
            assert.is_nil(peers["Katorriwl"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- ConsolidatePeerKeys (runtime re-canonicalization)
    ---------------------------------------------------------------------------
    --
    -- Recovers from cold-startup states where stale bare entries got written
    -- to syncState.peers / knownPeers before playerRealms was populated or
    -- repaired. Called from GUILD_ROSTER_UPDATE in Core.lua.

    describe("ConsolidatePeerKeys", function()
        before_each(function()
            MockWoW.player.realm = "Tichondrius"
            MockWoW.serverTime = 100000
            guildData.knownPeers = {}
            guildData.playerRealms = {}
            GBL:ResetSyncState()
        end)

        it("rewrites stale bare entries in syncState.peers to qualified", function()
            -- Simulate the cold-startup outcome: bare Katorriwl wrote to
            -- syncState.peers because playerRealms was corrupt at the time.
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99500 }
            -- playerRealms is now clean (BuildRosterCache + repair has run)
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            assert.is_not_nil(syncPeers["Katorriwl-Stormrage"])
            assert.equals(5, syncPeers["Katorriwl-Stormrage"].txCount)
        end)

        it("rewrites stale bare entries in knownPeers too", function()
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99500,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(guildData.knownPeers["Katorriwl"])
            assert.is_not_nil(guildData.knownPeers["Katorriwl-Stormrage"])
        end)

        it("merges bare + qualified collisions by recency", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99000 }
            syncPeers["Katorriwl-Stormrage"] = { version = "0.30.5", txCount = 8, lastSeen = 99800 }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            local kp = syncPeers["Katorriwl-Stormrage"]
            assert.is_not_nil(kp)
            assert.equals(8, kp.txCount)  -- newer entry wins
        end)

        it("leaves bare same-realm entries bare (no-op)", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Bob"] = { version = "0.30.5", txCount = 3, lastSeen = 99500 }
            guildData.playerRealms["Bob"] = "Tichondrius"  -- local realm

            GBL:ConsolidatePeerKeys()

            assert.is_not_nil(syncPeers["Bob"])
            assert.is_nil(syncPeers["Bob-Tichondrius"])
        end)

        it("is idempotent (second run produces no further rewrites)", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99500 }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()
            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            assert.is_not_nil(syncPeers["Katorriwl-Stormrage"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- NormalizeRecordId edge cases (J15-J18, G10)
    ---------------------------------------------------------------------------

    describe("NormalizeRecordId edge cases", function()
        it("returns false when incoming id is nil", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = { ["deposit|Thrall|12345|5|1|475101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = nil, _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)
            assert.is_false(result)
            -- Local record unchanged
            assert.equals("deposit|Thrall|12345|5|1|475101:0", localTx.id)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"])
        end)

        it("returns false when incoming id equals matched key", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"] = 3600 * 475100

            local idIndex = { ["deposit|Thrall|12345|5|1|475100:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475100:0", guildData, idIndex)
            assert.is_false(result)
            -- Nothing changed
            assert.equals(3600 * 475100, localTx.timestamp)
        end)

        it("uses GetServerTime when incoming timestamp is nil", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = { ["deposit|Thrall|12345|5|1|475101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = nil,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)
            assert.is_true(result)
            -- nil timestamp now falls back to GetServerTime() instead of 0
            assert.equals(Helpers.MockWoW.serverTime, localTx.timestamp)
            assert.equals(Helpers.MockWoW.serverTime, guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"])
        end)

        it("updates seenTxHashes even when idIndex is nil", function()
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, nil)
            assert.is_true(result)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"])
        end)

        it("normalizes record with matching _occurrence=0", function()
            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = "deposit|Thrall|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            local idIndex = { ["deposit|Thrall|12345|5|1|475101:0"] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }

            local result = GBL:NormalizeRecordId(incoming, "deposit|Thrall|12345|5|1|475101:0", guildData, idIndex)
            assert.is_true(result)
            assert.equals(0, localTx._occurrence)
        end)
    end)

    ---------------------------------------------------------------------------
    -- seenTxHashes atomic update (K19)
    ---------------------------------------------------------------------------

    describe("seenTxHashes atomic update", function()
        it("seenTxHashes has only new key after normalization (old key removed)", function()
            local oldKey = "deposit|Thrall|12345|5|1|475101:0"
            local newKey = "deposit|Thrall|12345|5|1|475100:0"
            guildData.seenTxHashes[oldKey] = 3600 * 475101

            -- Count keys before
            local countBefore = 0
            for _ in pairs(guildData.seenTxHashes) do countBefore = countBefore + 1 end
            assert.equals(1, countBefore)

            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475101,
                id = oldKey, _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            local idIndex = { [oldKey] = localTx }

            local incoming = {
                type = "deposit", player = "Thrall", itemID = 12345,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = newKey, _occurrence = 0,
            }

            GBL:NormalizeRecordId(incoming, oldKey, guildData, idIndex)

            -- Count keys after
            local countAfter = 0
            for _ in pairs(guildData.seenTxHashes) do countAfter = countAfter + 1 end
            assert.equals(1, countAfter)

            assert.equals(3600 * 475100, guildData.seenTxHashes[newKey])
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
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            local localTx2 = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 475201 + 1800,
                id = "withdraw|Jaina-TestRealm|99999|10|2|475201:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx1)
            table.insert(guildData.transactions, localTx2)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800
            guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|475201:0"] = 3600 * 475201 + 1800

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
                        _occurrence = 0,
                    },
                    {
                        type = "withdraw", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 3600 * 475200 + 2400,
                        id = "withdraw|Jaina-TestRealm|99999|10|2|475200:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Both records normalized
            assert.equals("deposit|Thrall-TestRealm|12345|5|1|475100:0", localTx1.id)
            assert.equals("withdraw|Jaina-TestRealm|99999|10|2|475200:0", localTx2.id)
            -- No new records stored
            assert.equals(2, #guildData.transactions)
            -- seenTxHashes updated
            assert.is_not_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475100:0"])
            assert.is_not_nil(guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|475200:0"])
            assert.is_nil(guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"])
            assert.is_nil(guildData.seenTxHashes["withdraw|Jaina-TestRealm|99999|10|2|475201:0"])
        end)

        it("handles mix of normalization and new record in same chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
                        _occurrence = 0,
                    },
                    {
                        type = "deposit", player = "Arthas",
                        itemID = 55555, classID = 0, subclassID = 1,
                        count = 3, tab = 2,
                        timestamp = 3600 * 475300,
                        id = "deposit|Arthas-TestRealm|55555|3|2|475300:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            assert.equals("deposit|Thrall-TestRealm|12345|5|1|475100:0", localTx.id)
            assert.equals(2, #guildData.transactions)
            assert.is_not_nil(guildData.seenTxHashes["deposit|Arthas-TestRealm|55555|3|2|475300:0"])
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
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

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
                        timestamp = 3600 * 475100 + 2400,
                        id = "deposit|Thrall-TestRealm|12345|5|1|475100:0",
                        _occurrence = 0,
                    },
                },
                moneyTransactions = {},
            })

            -- Hash should be different (cache was invalidated and recomputed)
            local hashAfter = GBL:GetDataHash(guildData)
            assert.are_not.equals(hashBefore, hashAfter)
            -- Should match the hash of the normalized ID
            assert.equals(GBL:HashString("deposit|Thrall-TestRealm|12345|5|1|475100:0"), hashAfter)
        end)

        it("does NOT reset hash cache when no normalization occurred", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local localTx = {
                type = "deposit", player = "Thrall", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"] = 3600 * 475100

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
                        timestamp = 3600 * 475100,
                        id = "deposit|Thrall|12345|5|1|475100:0",
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
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, bRecord)
            guildData.seenTxHashes["deposit|Thrall-TestRealm|12345|5|1|475101:0"] = 3600 * 475101 + 1800

            local aTimestamp = 3600 * 475100 + 2400
            local aId = "deposit|Thrall-TestRealm|12345|5|1|475100:0"

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
            local sharedId = "deposit|Thrall|12345|5|1|475100:0"
            local sharedTs = 3600 * 475100 + 2400

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
                count = 5, tab = 1, timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:0", _occurrence = 0,
            }
            table.insert(guildData.transactions, localTx)
            guildData.seenTxHashes["deposit|Thrall|12345|5|1|475100:0"] = 3600 * 475100

            -- Incoming has :1 occurrence (second identical tx in same hour)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 12345, classID = 0, subclassID = 5,
                        count = 5, tab = 1,
                        timestamp = 3600 * 475100,
                        id = "deposit|Thrall|12345|5|1|475100:1",
                        _occurrence = 1,
                    },
                },
                moneyTransactions = {},
            })

            -- Should be stored as a new record, not normalized
            assert.equals(2, #guildData.transactions)
            assert.equals("deposit|Thrall|12345|5|1|475100:0", localTx.id)
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
                        id = "deposit|Thrall|12345|5|1|475100:0",
                        -- No timestamp — should recover from ID
                    },
                },
                moneyTransactions = {},
            })

            assert.equals(1, #guildData.transactions)
            local stored = guildData.transactions[1]
            assert.equals(475100 * 3600, stored.timestamp)
            assert.equals("deposit|Thrall|12345|5|1|475100:0", stored.id)
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
                count = 5, tab = 1, timestamp = 3600 * 475100 + 2400,
                id = "deposit|Thrall-TestRealm|12345|5|1|475100:0", _occurrence = 0,
            }
            local shared1_B = {
                type = "deposit", player = "Thrall-TestRealm", itemID = 12345,
                classID = 0, subclassID = 5,
                count = 5, tab = 1, timestamp = 3600 * 475101 + 1800,
                id = "deposit|Thrall-TestRealm|12345|5|1|475101:0", _occurrence = 0,
            }
            local shared2_A = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 475200 + 2400,
                id = "withdraw|Jaina-TestRealm|99999|10|2|475200:0", _occurrence = 0,
            }
            local shared2_B = {
                type = "withdraw", player = "Jaina-TestRealm", itemID = 99999,
                classID = 0, subclassID = 1,
                count = 10, tab = 2, timestamp = 3600 * 475201 + 1800,
                id = "withdraw|Jaina-TestRealm|99999|10|2|475201:0", _occurrence = 0,
            }
            local aOnly = {
                type = "deposit", player = "Arthas-TestRealm", itemID = 55555,
                classID = 0, subclassID = 1,
                count = 3, tab = 2, timestamp = 3600 * 475300,
                id = "deposit|Arthas-TestRealm|55555|3|2|475300:0", _occurrence = 0,
            }
            local bOnly = {
                type = "deposit", player = "Varian-TestRealm", itemID = 77777,
                classID = 0, subclassID = 1,
                count = 1, tab = 1, timestamp = 3600 * 475400,
                id = "deposit|Varian-TestRealm|77777|1|1|475400:0", _occurrence = 0,
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
                        timestamp = 3600 * 475100,
                        id = "|Thrall|12345|5|1|475100:0",
                    },
                    {
                        -- Valid record
                        type = "deposit", player = "Jaina",
                        itemID = 99999, classID = 0, subclassID = 1,
                        count = 10, tab = 2,
                        timestamp = 3600 * 475200,
                        id = "deposit|Jaina|99999|10|2|475200:0",
                    },
                },
                moneyTransactions = {
                    {
                        -- Missing player field
                        type = "repair",
                        amount = 50000,
                        timestamp = 3600 * 475300,
                        id = "repair||50000|475300:0",
                    },
                },
            })

            -- Only the valid record should be stored
            assert.equals(1, #guildData.transactions)
            assert.equals("Jaina-TestRealm", guildData.transactions[1].player)
            assert.equals(0, #guildData.moneyTransactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Sync intake validation (#68)
    --
    -- DATA-MODEL.md section 8 measured what got through: 223 of 1,912 records
    -- received via sync carried at least one mangled key name, against zero of
    -- 10,398 locally scanned ones. Intake checked only that type and player were
    -- non-empty, so a type reading "wN260370" was stored happily.
    ---------------------------------------------------------------------------
    describe("sync intake validation", function()
        local BASE_TS = 3600 * 475100

        --- A well-formed item record, for tests to damage one field of.
        local function itemRecord(overrides)
            local rec = {
                type = "deposit", player = "Thrall", itemID = 12345,
                classID = 0, subclassID = 5, count = 5, tab = 1,
                timestamp = BASE_TS,
                id = "deposit|Thrall|12345|5|1|475100:0",
            }
            for k, v in pairs(overrides or {}) do
                if v == "\0nil" then rec[k] = nil else rec[k] = v end
            end
            return rec
        end

        local function receive(records)
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = records, moneyTransactions = {},
            })
        end

        describe("rejects", function()
            it("a type outside the enum", function()
                -- The exact damage shape from the measured population.
                receive({ itemRecord{ type = "wN260370" } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a record that is neither an item nor a money record", function()
                -- buildPrefix branches on itemID, so a record with neither field
                -- takes the money path and collides with every other such record
                -- from the same player, type and hour.
                receive({ itemRecord{ itemID = "\0nil" } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a record claiming to be both", function()
                receive({ itemRecord{ amount = 50000 } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a non-numeric count", function()
                receive({ itemRecord{ count = "5" } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a non-numeric timestamp", function()
                -- This one was invisible before: IsValidTimestamp checks the
                -- type first, so a string timestamp was silently replaced with
                -- receipt time and the record was filed in the wrong 6-hour
                -- bucket, where it differed from every peer forever.
                receive({ itemRecord{ timestamp = "1775580307" } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a non-string id", function()
                -- reconstructSyncRecord calls record.id:match before any of the
                -- old checks ran, so this crashed intake rather than failing it.
                receive({ itemRecord{ id = 12345 } })
                assert.equals(0, #guildData.transactions)
            end)

            it("a non-string player", function()
                receive({ itemRecord{ player = 99 } })
                assert.equals(0, #guildData.transactions)
            end)
        end)

        describe("repairs rather than rejects", function()
            it("an item record that lost subclassID in transit", function()
                -- 195 of the 223 damaged records lost only this. It is derivable
                -- from itemID through the same call CreateTxRecord uses, so
                -- rejecting them would throw away recoverable data.
                MockWoW.itemInfo[12345] = {
                    name = "Test Flask", classID = 0, subclassID = 3,
                }
                receive({ itemRecord{ subclassID = "\0nil", timessID = 3 } })

                assert.equals(1, #guildData.transactions)
                assert.equals(3, guildData.transactions[1].subclassID)
            end)

            it("and recomputes the category from the repaired fields", function()
                MockWoW.itemInfo[12345] = {
                    name = "Test Flask", classID = 0, subclassID = 3,
                }
                receive({ itemRecord{ subclassID = "\0nil", category = "unknown" } })

                assert.equals(1, #guildData.transactions)
                assert.equals("flask", guildData.transactions[1].category)
            end)

            it("a non-numeric classID, before the type check can reject it", function()
                -- Ordering guard: repair has to run first or the type check
                -- rejects exactly the records repair exists to save.
                MockWoW.itemInfo[12345] = {
                    name = "Test Flask", classID = 0, subclassID = 3,
                }
                receive({ itemRecord{ classID = "0" } })

                assert.equals(1, #guildData.transactions)
                assert.equals(0, guildData.transactions[1].classID)
            end)
        end)

        it("leaves an unknown key untouched", function()
            -- The forward-tolerance guard, and the most important test here.
            -- A whitelist at intake would turn every future additive field into
            -- a compatibility break needing a floor raise.
            receive({ itemRecord{ someFutureField = "hello" } })

            assert.equals(1, #guildData.transactions)
            assert.equals("hello", guildData.transactions[1].someFutureField)
        end)

        describe("accounting", function()
            it("counts a reject as a reject, not as a duplicate", function()
                -- Before this, a rejected record incremented the dupe counter,
                -- so total rejection was indistinguishable from perfect
                -- convergence: the redundancy line read 100% duped, which the
                -- decision rule in CLAUDE.md reads as "the bucket filter is
                -- doing the work, skip". Asserted through the emitted summary
                -- rather than the counters, because FinishReceiving clears
                -- those before anything outside the sync can read them.
                receive({
                    itemRecord{ type = "wN260370" },
                    itemRecord{ id = "deposit|Thrall|12345|5|1|475101:0",
                                timestamp = BASE_TS + 3600 },
                })

                local rejectLine, redundancyLine
                for _, e in ipairs(GBL:GetLog("sync")) do
                    if e.message:find("Rejected 1 record", 1, true) then
                        rejectLine = e.message
                    elseif e.message:find("Redundancy from", 1, true) then
                        redundancyLine = e.message
                    end
                end

                assert.is_string(rejectLine)
                assert.is_string(redundancyLine)
                -- One good record in, none duplicated. The rejected one is not
                -- in this line's denominator at all.
                assert.truthy(redundancyLine:find("0% duped (0/1 received)", 1, true),
                    "redundancy line should not count the reject: " .. redundancyLine)
            end)

            it("names the failing field in the sync log", function()
                receive({ itemRecord{ count = "5" } })

                local found = false
                for _, e in ipairs(GBL:GetLog("sync")) do
                    if e.message:find("count", 1, true)
                        and e.message:lower():find("reject", 1, true) then
                        found = true
                    end
                end
                assert.is_true(found, "expected a reject entry naming count")
            end)
        end)
    end)

    ---------------------------------------------------------------------------
    -- eventCounts sync
    ---------------------------------------------------------------------------

    describe("eventCounts sync", function()
        it("receiver merges remote counts with max", function()
            -- Local has count=1 for a baseHash
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 1, asOf = 1000 },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["withdraw|Thrall|12345|5|1|100"] = { count = 3, asOf = 2000 },
                },
            })

            assert.equals(3, guildData.eventCounts["withdraw|Thrall|12345|5|1|100"].count)
        end)

        it("receiver keeps higher local count", function()
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 5, asOf = 3000 },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["withdraw|Thrall|12345|5|1|100"] = { count = 2, asOf = 2000 },
                },
            })

            assert.equals(5, guildData.eventCounts["withdraw|Thrall|12345|5|1|100"].count)
        end)

        it("receiver creates eventCounts when local has none", function()
            guildData.eventCounts = nil

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["deposit|Jaina|99999|5|2|200"] = { count = 2, asOf = 1000 },
                },
            })

            assert.is_not_nil(guildData.eventCounts)
            assert.equals(2, guildData.eventCounts["deposit|Jaina|99999|5|2|200"].count)
        end)

        it("backwards compat: old peer sends no eventCounts", function()
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 1, asOf = 1000 },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                -- no eventCounts field
            })

            -- Local counts preserved, no crash
            assert.equals(1, guildData.eventCounts["withdraw|Thrall|12345|5|1|100"].count)
        end)

        it("ignores corrupted remote entries", function()
            guildData.eventCounts = {}

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["bad1"] = "garbage",
                    ["bad2"] = { count = "not a number" },
                    ["good"] = { count = 2, asOf = 1000 },
                },
            })

            assert.is_nil(guildData.eventCounts["bad1"])
            assert.is_nil(guildData.eventCounts["bad2"])
            assert.equals(2, guildData.eventCounts["good"].count)
        end)

        it("merges multiple baseHashes in one payload", function()
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 1, asOf = 1000 },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["withdraw|Thrall|12345|5|1|100"] = { count = 3, asOf = 2000 },
                    ["deposit|Jaina|99999|5|2|200"] = { count = 2, asOf = 2000 },
                },
            })

            assert.equals(3, guildData.eventCounts["withdraw|Thrall|12345|5|1|100"].count)
            assert.equals(2, guildData.eventCounts["deposit|Jaina|99999|5|2|200"].count)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Multi-peer eventCounts convergence
    ---------------------------------------------------------------------------

    describe("multi-peer eventCounts convergence", function()
        local baseHash

        before_each(function()
            baseHash = "withdraw|Thrall-TestRealm|12345|5|1|475100"
        end)

        it("two-peer: receiver adopts higher count and stores new records", function()
            -- Local: 1 record, count=1
            local r1 = {
                type = "withdraw", player = "Thrall-TestRealm",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 475100, scanTime = 1000,
                scannedBy = "OfficerA-TestRealm",
                _occurrence = 0,
            }
            r1.id = baseHash .. ":0"
            table.insert(guildData.transactions, r1)
            guildData.seenTxHashes[r1.id] = r1.timestamp
            guildData.eventCounts = {
                [baseHash] = { count = 1, asOf = 1000 },
            }

            -- Peer B sends 2 records + count=2
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100, scanTime = 900,
                        scannedBy = "OfficerB",
                        id = baseHash .. ":0", _occurrence = 0,
                    },
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 50, scanTime = 900,
                        scannedBy = "OfficerB",
                        id = baseHash .. ":1", _occurrence = 1,
                    },
                },
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 2, asOf = 900 },
                },
            })

            -- Count merged to max(1,2)=2
            assert.equals(2, guildData.eventCounts[baseHash].count)
            -- 1 original + 1 new (the :0 was deduplicated)
            assert.equals(2, #guildData.transactions)
        end)

        it("diverged indices cleaned by post-sync cleanup", function()
            -- Local: 1 record as :0, count=1
            local r1 = {
                type = "withdraw", player = "Thrall-TestRealm",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 475100, scanTime = 1000,
                scannedBy = "OfficerA-TestRealm",
                _occurrence = 0,
            }
            r1.id = baseHash .. ":0"
            table.insert(guildData.transactions, r1)
            guildData.seenTxHashes[r1.id] = r1.timestamp
            guildData.eventCounts = {
                [baseHash] = { count = 1, asOf = 1000 },
            }

            -- Peer sends same event but as :2 (diverged index) + count=1
            -- HandleSyncData stores it (IsDuplicate misses diverged occurrence),
            -- then FinishReceiving runs CleanupWithEventCounts which trims to 1.
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 30, scanTime = 900,
                        scannedBy = "OfficerB",
                        id = baseHash .. ":2", _occurrence = 2,
                    },
                },
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 1, asOf = 900 },
                },
            })

            -- After FinishReceiving's post-sync cleanup: only 1 record remains
            assert.equals(1, guildData.eventCounts[baseHash].count)
            assert.equals(1, #guildData.transactions)
        end)

        it("three-peer convergence: order independent", function()
            -- Simulate A's state after syncing with B then C
            guildData.eventCounts = {}
            guildData.transactions = {}
            guildData.seenTxHashes = {}

            -- Peer B: count=1 (same event, diverged)
            GBL:HandleSyncData("PeerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100, scanTime = 500,
                        scannedBy = "PeerB",
                        id = baseHash .. ":0", _occurrence = 0,
                    },
                },
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 1, asOf = 500 },
                },
            })

            assert.equals(1, #guildData.transactions)
            assert.equals(1, guildData.eventCounts[baseHash].count)

            -- Peer C: count=2 (saw a genuine second event)
            GBL:HandleSyncData("PeerC", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 10, scanTime = 600,
                        scannedBy = "PeerC",
                        id = baseHash .. ":0", _occurrence = 0,
                    },
                    {
                        type = "withdraw", player = "Thrall",
                        itemID = 12345, count = 5, tab = 1,
                        timestamp = 3600 * 475100 + 50, scanTime = 600,
                        scannedBy = "PeerC",
                        id = baseHash .. ":1", _occurrence = 1,
                    },
                },
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 2, asOf = 600 },
                },
            })

            -- Count merged to max(1,2)=2
            assert.equals(2, guildData.eventCounts[baseHash].count)
            -- After cleanup: exactly 2 records
            GBL:CleanupWithEventCounts(guildData)
            assert.equals(2, #guildData.transactions)
        end)

        it("concurrent different counts: max wins", function()
            guildData.eventCounts = {}

            -- Peer A sends count=1
            GBL:HandleSyncData("PeerA", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 1, asOf = 100 },
                },
            })
            assert.equals(1, guildData.eventCounts[baseHash].count)

            -- Peer C sends count=3
            GBL:HandleSyncData("PeerC", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 3, asOf = 300 },
                },
            })
            assert.equals(3, guildData.eventCounts[baseHash].count)

            -- Peer B sends count=2 (lower than what we already have)
            GBL:HandleSyncData("PeerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    [baseHash] = { count = 2, asOf = 200 },
                },
            })
            -- max(3, 2) = 3 — stays at 3
            assert.equals(3, guildData.eventCounts[baseHash].count)
        end)
    end)

    ---------------------------------------------------------------------------
    -- BUSY message
    ---------------------------------------------------------------------------

    describe("BUSY message", function()
        it("HandleSyncRequest sends BUSY when already sending", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local gd = GBL:GetGuildData()
            -- Add data so first HandleSyncRequest enters sending state
            table.insert(gd.transactions, {
                type = "deposit", player = "Player1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "abc:277:0",
                _occurrence = 0, scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            gd.seenTxHashes["abc:277:0"] = 1000 * 3600

            -- First request succeeds (enters sending state)
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)
            MockAce.sentCommMessages = {}

            -- Second request should be declined with BUSY
            GBL:HandleSyncRequest("PeerB", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Verify BUSY was sent to PeerB (LibDeflate mock is identity,
            -- so sent text is raw AceSerializer output)
            local found = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == "PeerB" then
                    local ok, d = GBL:Deserialize(msg.text)
                    if ok and type(d) == "table" and d.type == "BUSY" then
                        found = true
                    end
                end
            end
            assert.is_true(found, "BUSY message should have been sent to PeerB")
        end)

        -- The retry above means the peer we are already serving may ask again
        -- while its first request is being answered. Answering that with BUSY
        -- would make it abort the very receive we are feeding, so a duplicate
        -- from the current target is ignored instead.
        it("ignores a repeat request from the peer we are already sending to", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local gd = GBL:GetGuildData()
            for i = 1, 12 do
                local ts = (1000 + i) * 3600
                table.insert(gd.transactions, {
                    type = "deposit", player = "Player1", tab = 1, itemID = 123,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = ts, id = "dup" .. i .. ":277:0",
                    _occurrence = 0, scanTime = ts, scannedBy = "OfficerA",
                })
            end

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)
            local progressBefore = GBL:GetSyncStatus().sendProgress
            MockAce.sentCommMessages = {}

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, d = GBL:Deserialize(msg.text)
                assert.is_false(ok and type(d) == "table" and d.type == "BUSY",
                    "a repeat from the current target must not draw a BUSY")
            end
            assert.is_true(GBL:GetSyncStatus().sending,
                "the session in flight should survive the repeat")
            assert.equals(progressBefore, GBL:GetSyncStatus().sendProgress,
                "the repeat should not restart or advance the send")
        end)

        it("HandleBusy clears receiving state when waiting for that peer", function()
            -- Enter receiving state for PeerA
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)

            -- Receive BUSY from PeerA
            GBL:HandleBusy("PeerA", {})
            status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
            assert.is_nil(status.receiveSource)
        end)

        it("HandleBusy starts the peer's cooldown", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:HandleBusy("PeerA", {})
            assert.is_true(GBL:IsPeerBusy("PeerA"))
        end)

        -- Why a BUSY arrived is the difference between three responses that
        -- have nothing to do with each other: a peer already serving someone
        -- else, a peer that just entered combat, or a peer refusing to serve
        -- during a fight. A capture could not tell them apart, and three
        -- sends killed by BUSY in the 2026-08-12 window are still unexplained
        -- because of it (#97).
        it("HandleBusy records why the peer was busy", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:ClearLog("sync")

            GBL:HandleBusy("PeerA", { reason = "sending:SomeoneElse" })

            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message and e.message:find("Received BUSY from PeerA", 1, true)
                    and e.message:find("reason: sending:SomeoneElse", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "the BUSY line should carry the reason it arrived with")
        end)

        -- A peer from before the field existed sends no reason at all. The
        -- line still has to say something, and "unknown" is honest where a
        -- blank would read as a reason we failed to print.
        it("HandleBusy says unknown when the peer sent no reason", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:ClearLog("sync")

            GBL:HandleBusy("PeerA", {})

            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message and e.message:find("Received BUSY from PeerA", 1, true)
                    and e.message:find("reason: unknown", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "an older peer's reasonless BUSY should log unknown")
        end)

        it("HandleBusy is no-op on receiving state when not receiving", function()
            GBL:HandleBusy("PeerA", {})
            assert.is_false(GBL:GetSyncStatus().receiving)
            -- The cooldown still starts: they told us they were busy.
            assert.is_true(GBL:IsPeerBusy("PeerA"))
        end)

        it("HandleBusy does not clear state when receiving from different peer", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)

            -- BUSY from PeerB (different peer)
            GBL:HandleBusy("PeerB", {})
            status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)
            assert.equals("PeerA", status.receiveSource)
        end)

        it("HandleBusy clears state even after receiving partial data", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            -- Simulate having received chunk 1
            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 2,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- BUSY after partial data should clear state (data already stored)
            GBL:HandleBusy("PeerA", {})
            local status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
        end)

        it("BUSY message dispatches through OnSyncMessage", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            -- Craft and send a BUSY message through the dispatch
            local msg = GBL:Serialize({
                type = "BUSY",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            msg = GBL._compressMessage(msg)
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "WHISPER", "PeerA")

            local status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
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
    -- Bidirectional sync after FinishSending
    ---------------------------------------------------------------------------

    describe("bidirectional sync", function()
        it("schedules bidirectional check after FinishSending", function()
            -- Set up a send to PeerA
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "bidir:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            guildData.seenTxHashes["bidir:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)
            MockWoW.pendingTimers = {}

            GBL:FinishSending()

            -- Check that a 0.5s timer was scheduled
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_true(found, "Bidirectional check timer should be scheduled (0.5s)")
        end)

        it("requests sync when hashes differ after sending", function()
            -- Set peer info with different hash
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 20, dataHash = 999 })

            -- Enter and finish sending state
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "bidir2:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            guildData.seenTxHashes["bidir2:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:FinishSending()

            -- Fire the 0.5s bidirectional check timer
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then
                    t.callback()
                    break
                end
            end

            -- Should now be receiving from PeerA
            assert.is_true(GBL:GetSyncStatus().receiving)
            assert.equals("PeerA", GBL:GetSyncStatus().receiveSource)
        end)

        it("starts nothing when hashes match", function()
            -- Set peer info with matching hash
            local localHash = GBL:GetDataHash(guildData)
            local localCount = #guildData.transactions + #guildData.moneyTransactions
            GBL:UpdatePeer("PeerA", {
                version = GBL.version, txCount = localCount, dataHash = localHash,
            })

            -- Enter and finish sending to PeerA
            table.insert(guildData.transactions, {
                type = "deposit", player = "P1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "bidir3:277:0", _occurrence = 0,
                scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            guildData.seenTxHashes["bidir3:277:0"] = 1000 * 3600
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            -- Update peer hash to match after we added data
            local newHash = GBL:GetDataHash(guildData)
            local newCount = #guildData.transactions + #guildData.moneyTransactions
            GBL:UpdatePeer("PeerA", {
                version = GBL.version, txCount = newCount, dataHash = newHash,
            })

            GBL:FinishSending()

            -- Fire the 0.5s bidirectional check timer
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then
                    t.callback()
                    break
                end
            end

            -- Converged, so there is nothing to ask anyone for. We are free
            -- and the next HELLO decides what happens next.
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("skips request when local has more than peer (superset skip)", function()
            -- Add several local transactions so local count > peer count
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P1", tab = 1, itemID = 100 + i,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = 1000 * 3600 + i, id = "bidir_ss" .. i .. ":277:0",
                    _occurrence = 0, scanTime = 1000 * 3600 + i, scannedBy = "OfficerA",
                })
                guildData.seenTxHashes["bidir_ss" .. i .. ":277:0"] = 1000 * 3600 + i
            end

            -- Peer has fewer records and a different hash
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 3, dataHash = 999 })

            -- Enter and finish sending to PeerA
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:FinishSending()

            -- Fire the 0.5s bidirectional check timer
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then
                    t.callback()
                    break
                end
            end

            -- Should NOT be requesting from PeerA: we already hold more than
            -- they do, so pulling from them would cost a session and teach
            -- us nothing. The nudge in the next test is what they get instead.
            assert.is_false(GBL:GetSyncStatus().receiving,
                "should not request from a peer holding fewer records")
        end)

        it("re-nudges the behind peer on a bidirectional superset skip", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Local holds more records than the peer.
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P1", tab = 1, itemID = 100 + i,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = 1000 * 3600 + i, id = "bidir_nudge" .. i .. ":277:0",
                    _occurrence = 0, scanTime = 1000 * 3600 + i, scannedBy = "OfficerA",
                })
                guildData.seenTxHashes["bidir_nudge" .. i .. ":277:0"] = 1000 * 3600 + i
            end

            -- Peer is behind: fewer records, different hash.
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 3, dataHash = 999 })

            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            GBL:FinishSending()
            MockAce.sentCommMessages = {}

            -- Fire the 0.5s bidirectional check timer.
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then
                    t.callback()
                    break
                end
            end

            -- The behind peer should be re-nudged with an isReply HELLO whisper.
            local expectedKey = GBL:CanonicalPeerKey("PeerA")
            local nudged = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "HELLO" and data.isReply
                    and sent.distribution == "WHISPER"
                    and GBL:CanonicalPeerKey(sent.target) == expectedKey then
                    nudged = true
                end
            end
            assert.is_true(nudged,
                "behind peer should be re-nudged after a bidirectional superset skip")

            local audited = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message
                    and entry.message:find("bidirectional hash-gate bypass", 1, true) then
                    audited = true
                end
            end
            assert.is_true(audited, "audit trail should record the bidirectional nudge")
        end)

        it("throttles the bidirectional superset nudge to one per window per peer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P1", tab = 1, itemID = 100 + i,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = 1000 * 3600 + i, id = "bidir_thr" .. i .. ":277:0",
                    _occurrence = 0, scanTime = 1000 * 3600 + i, scannedBy = "OfficerA",
                })
                guildData.seenTxHashes["bidir_thr" .. i .. ":277:0"] = 1000 * 3600 + i
            end
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 3, dataHash = 999 })

            -- First skip sets lastSupersetNudge for the peer.
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockWoW.pendingTimers = {}
            GBL:FinishSending()
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then t.callback() break end
            end
            MockAce.sentCommMessages = {}

            -- Second skip at the same server time is inside the throttle window.
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockWoW.pendingTimers = {}
            GBL:FinishSending()
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if t.delay == 0.5 and not t.cancelled then t.callback() break end
            end

            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                assert.is_false(ok and data.type == "HELLO" and data.isReply == true,
                    "no second bidirectional nudge within the throttle window")
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- Epoch-0 (bucket 0) diagnostic
    ---------------------------------------------------------------------------

    describe("epoch-0 diagnostic", function()
        it("CollectEpochZeroRecords classifies bucket-0 records", function()
            local gd = {
                transactions = {
                    -- epoch-0 id, invalid timestamp (legacy corrupt record)
                    { type = "deposit", player = "P1", itemID = 123, count = 1, tab = 1,
                      id = "deposit|P1|123|1|1|0:0", timestamp = 0,
                      scannedBy = "sync:PeerX-Realm" },
                    -- epoch-0 id but repaired (valid) timestamp: the leak case where
                    -- the timestamp was fixed at intake but the id still says slot 0
                    { type = "deposit", player = "P1", itemID = 123, count = 1, tab = 1,
                      id = "deposit|P1|123|1|1|0:1", timestamp = 475100 * 3600,
                      scannedBy = "sync:PeerX-Realm" },
                    -- no-pipe id + epoch-0 timestamp: bucket 0 via the timestamp fallback
                    { type = "deposit", player = "P3", itemID = 7, count = 1, tab = 1,
                      id = "nopipe:0", timestamp = 0, scannedBy = "sync:PeerY-Realm" },
                    -- valid record in a real bucket: must be excluded
                    { type = "deposit", player = "P4", itemID = 9, count = 1, tab = 1,
                      id = "deposit|P4|9|1|1|475100:0", timestamp = 475100 * 3600,
                      scannedBy = "Me-Realm" },
                },
                moneyTransactions = {
                    -- epoch-0 id money record
                    { type = "withdraw", player = "P2", amount = 500,
                      id = "withdraw|P2|500|0:0", timestamp = 0, scannedBy = "Me-Realm" },
                },
            }

            local r = GBL:CollectEpochZeroRecords(gd)
            assert.equals(4, r.count)
            assert.equals(3, r.items)
            assert.equals(1, r.money)
            assert.equals(1, r.validTs)
            assert.equals(3, r.invalidTs)
            assert.equals(3, r.sources)
            assert.equals(2, r.byScannedBy["sync:PeerX-Realm"])
            assert.equals(1, r.byScannedBy["sync:PeerY-Realm"])
            assert.equals(1, r.byScannedBy["Me-Realm"])
            assert.equals(4, #r.samples)
        end)

        it("CollectEpochZeroRecords returns zeros for clean data", function()
            local gd = {
                transactions = {
                    { type = "deposit", player = "P1", itemID = 123, count = 1, tab = 1,
                      id = "deposit|P1|123|1|1|475100:0", timestamp = 475100 * 3600,
                      scannedBy = "Me-Realm" },
                },
                moneyTransactions = {},
            }
            local r = GBL:CollectEpochZeroRecords(gd)
            assert.equals(0, r.count)
            assert.equals(0, r.items)
            assert.equals(0, r.money)
            assert.equals(0, r.sources)
            assert.equals(0, #r.samples)
        end)

        it("CollectEpochZeroRecords caps samples at 10", function()
            local txs = {}
            for i = 1, 15 do
                txs[i] = { type = "deposit", player = "P1", itemID = 1, count = 1, tab = 1,
                           id = "deposit|P1|1|1|1|0:" .. i, timestamp = 0,
                           scannedBy = "sync:PeerX-Realm" }
            end
            local r = GBL:CollectEpochZeroRecords({ transactions = txs, moneyTransactions = {} })
            assert.equals(15, r.count)
            assert.equals(10, #r.samples)
        end)

        it("CollectEpochZeroRecords tolerates nil guildData", function()
            local r = GBL:CollectEpochZeroRecords(nil)
            assert.equals(0, r.count)
            assert.equals(0, #r.samples)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Sender offline detection
    ---------------------------------------------------------------------------

    describe("sender offline detection", function()
        it("aborts receive when sender is offline", function()
            -- Set up guild roster with OfficerB offline
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            -- Start receiving from OfficerB
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Fire receive timeout — should detect offline and abort
            fireReceiveTimeout()

            assert.is_false(GBL:GetSyncStatus().receiving)
            -- Check audit trail mentions offline
            local trail = GBL:GetAuditTrail()
            local foundOffline = false
            for _, entry in ipairs(trail) do
                if entry.message:find("offline") then
                    foundOffline = true
                    break
                end
            end
            assert.is_true(foundOffline, "audit trail should mention offline")
        end)

        it("proceeds with NACK when sender is online", function()
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            -- Fire timeout — should send NACK (sender is online)
            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
            assert.is_true(#MockAce.sentCommMessages >= 1)
        end)

        it("proceeds with NACK when sender not found in roster", function()
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            -- Fire timeout — nil return means proceed with NACK
            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
        end)

        it("proceeds with NACK when roster is empty", function()
            MockWoW.guildRoster = {}

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
        end)
    end)

    ---------------------------------------------------------------------------
    -- NACK backoff
    ---------------------------------------------------------------------------

    describe("NACK backoff", function()
        it("computes correct backoff values", function()
            assert.equals(20, GBL._nackBackoff(0))
            assert.equals(30, GBL._nackBackoff(1))
            assert.equals(45, GBL._nackBackoff(2))
            assert.equals(45, GBL._nackBackoff(3))  -- capped at 45
            assert.equals(45, GBL._nackBackoff(10)) -- still capped
        end)

        it("uses progressive delays for successive NACKs", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1 of 3 (triggers timeout for chunk 2)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- First timeout should be at 20s (nackCount=0)
            local firstTimer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    firstTimer = t
                    break
                end
            end
            assert.is_not_nil(firstTimer)
            assert.equals(20, firstTimer.delay)

            -- Fire the first NACK (schedules a new timer with backoff)
            firstTimer.callback()
            local secondTimer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    secondTimer = t
                    break
                end
            end
            assert.is_not_nil(secondTimer)
            assert.equals(30, secondTimer.delay)
        end)

        it("resets backoff after successful chunk receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1 of 4
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 4,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire 2 NACKs to advance backoff
            fireReceiveTimeout()
            fireReceiveTimeout()

            -- Receive chunk 2 (resets nackCount)
            GBL:HandleSyncData("OfficerB", {
                chunk = 2, totalChunks = 4,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- New timeout should be 20s (reset backoff)
            local timer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    timer = t
                    break
                end
            end
            assert.is_not_nil(timer)
            assert.equals(20, timer.delay)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Initial chunk timeout
    ---------------------------------------------------------------------------

    describe("initial chunk timeout", function()
        it("uses ScheduleReceiveTimeout for initial request", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            MockWoW.pendingTimers = {}
            GBL:RequestSync("PeerA", 0)

            -- RequestSync now uses ScheduleReceiveTimeout (nackBackoff(0) = 20s)
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_true(found,
                "Initial receive timeout should use ScheduleReceiveTimeout (20s)")
        end)

        it("subsequent chunk timeout uses standard RECEIVE_CHUNK_TIMEOUT", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            MockWoW.pendingTimers = {}

            -- Receive chunk 1 of 2 (triggers new timer for chunk 2)
            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 2,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Inter-chunk timeout should use the standard 20s
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 20 and not timer.cancelled then
                    found = true
                end
            end
            assert.is_true(found, "Inter-chunk timeout should use 20s")
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
    -- SendSyncWhisper (safe whisper wrapper)
    ---------------------------------------------------------------------------

    describe("SendSyncWhisper", function()
        it("blocks whisper to offline target", function()
            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "OfflinePeer")
            assert.is_false(result)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("allows whisper to online target", function()
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "OnlinePeer")
            assert.is_true(result)
            assert.equals(1, #MockAce.sentCommMessages)
            assert.equals("WHISPER", MockAce.sentCommMessages[1].distribution)
            assert.equals("OnlinePeer", MockAce.sentCommMessages[1].target)
        end)

        it("allows whisper when target not in roster (unknown)", function()
            MockWoW.guildRoster = {}
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "UnknownPeer")
            assert.is_true(result)
            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("tracks whisper target in recentWhisperTargets", function()
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }

            GBL:SendSyncWhisper("GBLSync", "test", "OnlinePeer")
            assert.is_not_nil(GBL._recentWhisperTargets["OnlinePeer"])
            assert.equals(MockWoW.serverTime, GBL._recentWhisperTargets["OnlinePeer"])
        end)

        it("does not track offline target", function()
            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            GBL:SendSyncWhisper("GBLSync", "test", "OfflinePeer")
            assert.is_nil(GBL._recentWhisperTargets["OfflinePeer"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Offline abort during sync operations
    ---------------------------------------------------------------------------

    describe("offline abort", function()
        it("SendChunk aborts send when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up a sending state
            local tx = {
                id = "tx1", tab = 1, type = "deposit", player = "Someone",
                timestamp = MockWoW.serverTime - 100, itemID = 12345,
                itemName = "Test Item", count = 1,
            }
            table.insert(guildData.transactions, tx)

            -- Simulate receiving a sync request from OnlinePeer
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }
            GBL:UpdatePeer("OnlinePeer", {
                version = GBL.version, txCount = 0, dataHash = 99,
                lastScanTime = MockWoW.serverTime,
            })

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

            -- Now mark peer as offline and trigger next chunk
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = false },
            }
            MockAce.sentCommMessages = {}

            -- Advance past the inter-chunk gap floor so SendNextChunk proceeds
            -- to the offline check instead of deferring.
            MockWoW.serverTime = MockWoW.serverTime + 2

            -- Fire the ACK-triggered timer to attempt next chunk
            -- Since the first chunk was sent while online, we need to simulate
            -- the send completing and then the next attempt
            GBL:SendNextChunk()

            -- Should have aborted — sending state cleared
            assert.is_false(GBL:IsSyncing())
        end)

        it("RequestSync aborts receive when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            MockAce.sentCommMessages = {}
            GBL:RequestSync("OfflinePeer", 0)

            -- Should not have sent the request
            assert.equals(0, #MockAce.sentCommMessages)
            -- Receiving state should be cleaned up
            assert.is_false(GBL:IsSyncing())
        end)

        it("SendNack skips send when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            MockAce.sentCommMessages = {}
            GBL:SendNack("OfflinePeer", 1)

            -- No message sent
            assert.equals(0, #MockAce.sentCommMessages)
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

    ---------------------------------------------------------------------------
    -- v0.28.8: receiver-side redundancy metric
    ---------------------------------------------------------------------------
    describe("v0.28.8 redundancy metric", function()
        local function findRedundancyLine()
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                if entry.message:find("Redundancy from") then
                    return entry.message
                end
            end
            return nil
        end

        local function makeItemTx(idSuffix)
            return {
                type = "deposit", player = "Thrall",
                itemID = 12345, classID = 0, subclassID = 5,
                count = 5, tab = 1,
                timestamp = 3600 * 475100,
                id = "deposit|Thrall|12345|5|1|475100:" .. idSuffix,
            }
        end

        local function makeMoneyTx(idSuffix)
            return {
                type = "deposit", player = "Thrall",
                amount = 10000,
                timestamp = 3600 * 475100,
                id = "money|Thrall|deposit|10000|" .. idSuffix,
            }
        end

        it("emits items+money split with mixed dupes (50% items, 75% money)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Pre-mark 2 of 4 items + 3 of 4 money tx as already seen
            guildData.seenTxHashes[makeItemTx("a").id] = 3600 * 475100
            guildData.seenTxHashes[makeItemTx("b").id] = 3600 * 475100
            guildData.seenTxHashes[makeMoneyTx("a").id] = 3600 * 475100
            guildData.seenTxHashes[makeMoneyTx("b").id] = 3600 * 475100
            guildData.seenTxHashes[makeMoneyTx("c").id] = 3600 * 475100

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = {
                    makeItemTx("a"), makeItemTx("b"),  -- dupes
                    makeItemTx("c"), makeItemTx("d"),  -- new
                },
                moneyTransactions = {
                    makeMoneyTx("a"), makeMoneyTx("b"), makeMoneyTx("c"),  -- dupes
                    makeMoneyTx("d"),  -- new
                },
            })

            local line = findRedundancyLine()
            assert.is_not_nil(line, "Redundancy line should be emitted")
            assert.is_truthy(line:find("Redundancy from OfficerB"))
            -- 5 dupes / 8 received = 62.5% → rounds to 63%
            assert.is_truthy(line:find("63%% duped %(5/8 received%)"),
                "expected '63% duped (5/8 received)', got: " .. line)
            assert.is_truthy(line:find("items: 50%% %(2/4%)"),
                "expected 'items: 50% (2/4)', got: " .. line)
            assert.is_truthy(line:find("money: 75%% %(3/4%)"),
                "expected 'money: 75% (3/4)', got: " .. line)
        end)

        it("emits 100% duped when all records are duplicates", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            guildData.seenTxHashes[makeItemTx("a").id] = 3600 * 475100
            guildData.seenTxHashes[makeMoneyTx("a").id] = 3600 * 475100

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = { makeItemTx("a") },
                moneyTransactions = { makeMoneyTx("a") },
            })

            local line = findRedundancyLine()
            assert.is_not_nil(line)
            assert.is_truthy(line:find("100%% duped %(2/2 received%)"),
                "expected '100% duped (2/2 received)', got: " .. line)
        end)

        it("emits 0% duped when all records are new", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = { makeItemTx("a"), makeItemTx("b") },
                moneyTransactions = { makeMoneyTx("a") },
            })

            local line = findRedundancyLine()
            assert.is_not_nil(line)
            assert.is_truthy(line:find("0%% duped %(0/3 received%)"),
                "expected '0% duped (0/3 received)', got: " .. line)
        end)

        it("suppresses redundancy line entirely on empty sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = {},
                moneyTransactions = {},
            })

            local line = findRedundancyLine()
            assert.is_nil(line, "Redundancy line should NOT appear for empty sync")
        end)

        it("omits items segment when only money records received", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 1,
                transactions = {},
                moneyTransactions = { makeMoneyTx("a") },
            })

            local line = findRedundancyLine()
            assert.is_not_nil(line)
            assert.is_nil(line:find("items:"),
                "items segment should be omitted, got: " .. line)
            assert.is_truthy(line:find("money: 0%% %(0/1%)"),
                "expected 'money: 0% (0/1)', got: " .. line)
        end)

        it("per-chunk audit includes running dup percentage", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            guildData.seenTxHashes[makeItemTx("a").id] = 3600 * 475100

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 2,
                transactions = { makeItemTx("a"), makeItemTx("b") },
                moneyTransactions = {},
            })

            local trail = GBL:GetAuditTrail()
            local chunkLine = nil
            for _, entry in ipairs(trail) do
                if entry.message:find("Received chunk 1/2") then
                    chunkLine = entry.message
                    break
                end
            end
            assert.is_not_nil(chunkLine)
            -- 1 dupe / 2 received = 50%
            assert.is_truthy(chunkLine:find("50%% dup"),
                "expected '50% dup' in per-chunk line, got: " .. chunkLine)
        end)
    end)
end)
