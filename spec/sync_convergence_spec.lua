------------------------------------------------------------------------
-- spec/sync_convergence_spec.lua — Sync convergence
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync convergence", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
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
end)
