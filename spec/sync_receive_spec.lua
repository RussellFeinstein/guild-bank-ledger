------------------------------------------------------------------------
-- spec/sync_receive_spec.lua — Sync receive and intake
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync receive and intake", function()
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
