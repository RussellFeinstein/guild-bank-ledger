------------------------------------------------------------------------
-- spec/sync_request_spec.lua — Sync request and serve
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync request and serve", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- HandleSyncRequest + chunking
    ---------------------------------------------------------------------------

    describe("HandleSyncRequest", function()
        it("sends matching transactions as SYNC_DATA", function()
            -- Two records, because this is about the message shape and the
            -- chunk numbering on a single-chunk send. Enough records to need a
            -- second chunk would change what is being asserted, not improve it.
            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "Player" .. i,
                    itemID = 1000 + i, count = i, tab = 1,
                    timestamp = 1000 + i, scanTime = 1000 + i,
                    scannedBy = "OfficerA", id = "hash" .. i,
                })
            end

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should have sent at least one SYNC_DATA message
            assert.is_true(#MockAce.sentCommMessages > 0)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.equals(2, #data.transactions)
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 1000 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(1, #data.transactions)
            assert.equals("New", data.transactions[1].player)
        end)

        it("sends empty sync when no matching transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.equals(0, #data.transactions)
            assert.equals(0, #data.moneyTransactions)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Combat serve gate (issue #126)
    ---------------------------------------------------------------------------

    -- Serving was the one door in the combat policy with no check on it.
    -- HandleHello defers requesting while InCombatLockdown reads true, and a
    -- live session entering combat is aborted outright, but an idle client
    -- never sets combatPaused (OnCombatStart returns early when nothing is in
    -- flight), so a raider could be handed a full synchronous backfill
    -- mid-pull. That is the context of the watchdog kills in #115.
    describe("combat serve gate", function()
        local function sentTo(target)
            local types = {}
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == target then
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and type(data) == "table" then
                        types[data.type] = (types[data.type] or 0) + 1
                    end
                end
            end
            return types
        end

        local function inCombat(fn)
            local origICL = _G.InCombatLockdown
            _G.InCombatLockdown = function() return true end
            local ok, err = pcall(fn)
            _G.InCombatLockdown = origICL
            if not ok then error(err, 0) end
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            for i = 1, 3 do
                local ts = (1000 + i) * 3600
                table.insert(guildData.transactions, {
                    type = "deposit", player = "Player1", tab = 1, itemID = 123,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = ts, id = "combatgate" .. i .. ":277:0",
                    _occurrence = 0, scanTime = ts, scannedBy = "OfficerA",
                })
            end
            MockAce.sentCommMessages = {}
        end)

        it("declines with BUSY while in combat", function()
            inCombat(function()
                GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            end)

            local sent = sentTo("PeerA")
            assert.equals(1, sent["BUSY"] or 0,
                "a request arriving in combat should draw a BUSY")
            assert.is_nil(sent["SYNC_DATA"],
                "no records should be served during combat")
            assert.is_false(GBL:GetSyncStatus().sending,
                "no send session should be opened during combat")
        end)

        it("names the reason in the sync log", function()
            inCombat(function()
                GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            end)

            -- Silence would leave a capture unable to tell this apart from a
            -- request that never arrived, which is the whole #115 symptom.
            local logged = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message
                    and entry.message:find("Declined sync from PeerA", 1, true)
                    and entry.message:find("combat", 1, true) then
                    logged = true
                end
            end
            assert.is_true(logged, "the decline has to name itself in the capture")
        end)

        -- InCombatLockdown reads false the instant regen returns, while a
        -- chain pull is still going, so the flag covers the tail the live API
        -- cannot express.
        it("declines during the post-combat cooldown tail", function()
            GBL:RequestSync("OfficerC", 0)
            GBL:OnCombatStart()
            assert.is_true(GBL:GetSyncStatus().combatPaused)
            assert.is_false(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })

            local sent = sentTo("PeerA")
            assert.equals(1, sent["BUSY"] or 0)
            assert.is_nil(sent["SYNC_DATA"])
            assert.is_false(GBL:GetSyncStatus().sending)
        end)

        it("declines during the zone cooldown tail", function()
            -- OnLoadingScreenStart only pauses a live session, so enter one
            -- and end it, which leaves zonePaused set until its cooldown.
            GBL:RequestSync("OfficerC", 0)
            GBL:OnLoadingScreenStart()
            GBL:FinishReceiving("OfficerC")
            assert.is_true(GBL:GetSyncStatus().zonePaused)
            MockAce.sentCommMessages = {}

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })

            local sent = sentTo("PeerA")
            assert.equals(1, sent["BUSY"] or 0)
            assert.is_nil(sent["SYNC_DATA"])
            assert.is_false(GBL:GetSyncStatus().sending)
        end)

        -- The version gate stays ahead of this one. BUSY reads as "try again
        -- shortly", which would drive an incompatible peer's retry loop for as
        -- long as it stays on the old version, in combat or out of it.
        it("keeps refusing an incompatible requester silently in combat", function()
            GBL.version = "0.40.0"

            inCombat(function()
                GBL:HandleSyncRequest("PeerA", request{
                    sinceTimestamp = 0,
                    version = "0.20.0",
                    minSyncVersion = "0.20.0",
                })
            end)

            local sent = sentTo("PeerA")
            assert.is_nil(sent["BUSY"], "an incompatible peer gets silence, never BUSY")
            assert.is_nil(sent["SYNC_DATA"])
        end)

        it("serves normally out of combat", function()
            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })

            local sent = sentTo("PeerA")
            assert.is_true((sent["SYNC_DATA"] or 0) > 0, "an idle client should still serve")
            assert.is_nil(sent["BUSY"])
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

            -- Audit trail should record the identical verdict
            local trail = GBL:GetAuditTrail()
            local found = false
            for _, e in ipairs(trail) do
                if e.message:find("verdict=identical", 1, true) then found = true end
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

            GBL:HandleSyncRequest("OfficerB", request{
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

            GBL:HandleSyncRequest("OfficerB", request{
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
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 1000 })

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
    -- Hierarchical request manifest (requesting side)
    ---------------------------------------------------------------------------

    describe("bounded request manifest", function()
        local BASE = 80000

        local function addRecordInBucket(key, tag)
            local ts = key * GBL.BUCKET_SECONDS
            table.insert(guildData.transactions, {
                type = "deposit", player = "P" .. tag,
                itemID = 1000, count = 1, tab = 1,
                timestamp = ts, scanTime = ts,
                scannedBy = "OfficerA", id = "rec_" .. tag .. ":0",
            })
        end

        local function sentRequest()
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "SYNC_REQUEST" then return data end
            end
        end

        local function manifestSize(req)
            local n = 0
            for _ in pairs(req.bucketHashes) do n = n + 1 end
            return n + #(req.spans or {})
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
        end)

        it("declares no spans when the history fits the detail window", function()
            for i = 1, 10 do addRecordInBucket(BASE + i, "r" .. i) end

            GBL:RequestSync("OfficerB", 0)

            local req = sentRequest()
            assert.is_not_nil(req)
            assert.is_nil(req.spans)
            assert.equals(10, manifestSize(req))
        end)

        it("declares no spans at exactly the detail window", function()
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS do
                addRecordInBucket(BASE + i, "r" .. i)
            end

            GBL:RequestSync("OfficerB", 0)

            local req = sentRequest()
            assert.is_nil(req.spans)
            assert.equals(GBL.SYNC_REQUEST_DETAIL_BUCKETS, manifestSize(req))
        end)

        it("summarizes older history as spans once past the window", function()
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS + 200 do
                addRecordInBucket(BASE + i, "r" .. i)
            end

            GBL:RequestSync("OfficerB", 0)

            local req = sentRequest()
            local detailCount = 0
            for _ in pairs(req.bucketHashes) do detailCount = detailCount + 1 end
            assert.equals(GBL.SYNC_REQUEST_DETAIL_BUCKETS, detailCount)
            assert.equals(GBL.SYNC_REQUEST_SPAN_COUNT, #req.spans)
        end)

        it("stays the same size as the history grows", function()
            -- The whole point of #108: the request used to carry one entry per
            -- bucket forever, so it outgrew the whisper ceiling and stopped
            -- arriving. Ten times the history must not mean a larger request.
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS + 50 do
                addRecordInBucket(BASE + i, "a" .. i)
            end
            GBL:RequestSync("OfficerB", 0)
            local small = manifestSize(sentRequest())

            MockAce.sentCommMessages = {}
            GBL:ResetSyncState()
            for i = 1, 500 do addRecordInBucket(BASE - i, "b" .. i) end
            GBL:RequestSync("OfficerB", 0)
            local large = manifestSize(sentRequest())

            assert.equals(small, large)
            assert.equals(
                GBL.SYNC_REQUEST_DETAIL_BUCKETS + GBL.SYNC_REQUEST_SPAN_COUNT,
                large)
        end)

        it("still carries the version fields the serving gate reads", function()
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS + 5 do
                addRecordInBucket(BASE + i, "r" .. i)
            end

            GBL:RequestSync("OfficerB", 0)

            local req = sentRequest()
            assert.equals(GBL.version, req.version)
            assert.equals(GBL.MIN_SYNC_VERSION, req.minSyncVersion)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, req.protocolVersion)
        end)

        it("omits bucketHashes entirely when there is no guild data", function()
            -- Preserves the serving side's sinceTimestamp fallback, which keys
            -- off the field being absent rather than empty.
            GBL.db.profile.guilds = {}
            MockWoW.guild.name = nil

            GBL:RequestSync("OfficerB", 0)

            local req = sentRequest()
            if req then
                assert.is_nil(req.spans)
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- Hierarchical request manifest (serving side)
    ---------------------------------------------------------------------------

    describe("span-aware bucket diff", function()
        -- Bucket key 80000 is 86400 * 20000 seconds, comfortably inside the
        -- era IsValidTimestamp accepts. Record ids carry no pipe, so bucket
        -- placement falls back to the timestamp, same as the older specs here.
        local BASE = 80000

        local function addRecordInBucket(key, tag)
            local ts = key * GBL.BUCKET_SECONDS
            table.insert(guildData.transactions, {
                type = "deposit", player = "P" .. tag,
                itemID = 1000, count = 1, tab = 1,
                timestamp = ts, scanTime = ts,
                scannedBy = "OfficerA", id = "rec_" .. tag .. ":0",
            })
        end

        -- Only the first chunk leaves synchronously, so a send has to be
        -- driven to completion before asking what it offered.
        local function drainSend(target)
            for _ = 1, 4000 do
                if not GBL:GetSyncStatus().sending then break end
                local idx = tonumber(
                    GBL:GetSyncStatus().sendProgress:match("^(%d+)"))
                GBL:HandleAck(target, { chunk = idx })
                MockWoW.serverTime = MockWoW.serverTime + 2
                local fired = false
                for i = #MockWoW.pendingTimers, 1, -1 do
                    local t = MockWoW.pendingTimers[i]
                    if not t.cancelled and not t.fired and t.delay
                        and t.delay > 0 and t.delay <= 2.0 then
                        t.fired = true
                        t.callback()
                        fired = true
                        break
                    end
                end
                if not fired then break end
            end
        end

        local function serve(payload)
            GBL:HandleSyncRequest("OfficerB", request(payload))
            drainSend("OfficerB")

            local ids = {}
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "SYNC_DATA" then
                    for _, tx in ipairs(data.transactions or {}) do
                        ids[tx.id] = true
                    end
                end
            end
            return ids
        end

        local function countKeys(t)
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
        end)

        it("clears every bucket inside a span whose fold matches", function()
            addRecordInBucket(BASE, "old1")
            addRecordInBucket(BASE + 1, "old2")
            addRecordInBucket(BASE + 2, "old3")
            addRecordInBucket(BASE + 10, "recent")

            local localBuckets = GBL:ComputeBucketHashes(guildData)
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = { [BASE + 10] = localBuckets[BASE + 10] },
                spans = {
                    { s = BASE, e = BASE + 9,
                      h = GBL:FoldBucketRange(localBuckets, BASE, BASE + 9) },
                },
            }

            assert.equals(0, countKeys(ids))
        end)

        it("offers every local bucket in a span whose fold differs", function()
            addRecordInBucket(BASE, "old1")
            addRecordInBucket(BASE + 1, "old2")
            addRecordInBucket(BASE + 2, "old3")
            addRecordInBucket(BASE + 10, "recent")

            local localBuckets = GBL:ComputeBucketHashes(guildData)
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = { [BASE + 10] = localBuckets[BASE + 10] },
                spans = {
                    { s = BASE, e = BASE + 9,
                      h = GBL:FoldBucketRange(localBuckets, BASE, BASE + 9) + 1 },
                },
            }

            assert.is_true(ids["rec_old1:0"])
            assert.is_true(ids["rec_old2:0"])
            assert.is_true(ids["rec_old3:0"])
            assert.is_nil(ids["rec_recent:0"])
        end)

        it("offers a bucket older than every declared span", function()
            addRecordInBucket(BASE - 5, "ancient")
            addRecordInBucket(BASE, "old1")
            addRecordInBucket(BASE + 10, "recent")

            local localBuckets = GBL:ComputeBucketHashes(guildData)
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = { [BASE + 10] = localBuckets[BASE + 10] },
                spans = {
                    { s = BASE, e = BASE + 9,
                      h = GBL:FoldBucketRange(localBuckets, BASE, BASE + 9) },
                },
            }

            assert.is_true(ids["rec_ancient:0"])
            assert.is_nil(ids["rec_old1:0"])
            assert.is_nil(ids["rec_recent:0"])
        end)

        it("offers a bucket sitting in a hole in the detail window", function()
            addRecordInBucket(BASE + 10, "listed")
            addRecordInBucket(BASE + 12, "unlisted")

            local localBuckets = GBL:ComputeBucketHashes(guildData)
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = { [BASE + 10] = localBuckets[BASE + 10] },
            }

            assert.is_true(ids["rec_unlisted:0"])
            assert.is_nil(ids["rec_listed:0"])
        end)

        it("sends nothing when the requester hands back our own manifest", function()
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS + 20 do
                addRecordInBucket(BASE + i, "r" .. i)
            end

            local detail, spans = GBL:BuildRequestManifest(
                GBL:ComputeBucketHashes(guildData))
            assert.is_not_nil(spans)

            local ids = serve{
                sinceTimestamp = 0, bucketHashes = detail, spans = spans,
            }

            assert.equals(0, countKeys(ids))
        end)

        it("offers the one changed bucket out of a long history", function()
            for i = 1, GBL.SYNC_REQUEST_DETAIL_BUCKETS + 20 do
                addRecordInBucket(BASE + i, "r" .. i)
            end

            -- Snapshot the requester's view, then add a record to an old
            -- bucket so exactly one span's fold moves underneath it.
            local detail, spans = GBL:BuildRequestManifest(
                GBL:ComputeBucketHashes(guildData))
            addRecordInBucket(BASE + 3, "late")

            local ids = serve{
                sinceTimestamp = 0, bucketHashes = detail, spans = spans,
            }

            assert.is_true(ids["rec_late:0"])
            assert.is_true(ids["rec_r3:0"])   -- rides along, same span
            assert.is_nil(ids["rec_r60:0"])   -- untouched detail bucket
        end)

        it("ignores malformed spans and falls back to the detail compare", function()
            addRecordInBucket(BASE, "old1")

            -- Nothing legible covers BASE, so it goes through the per-bucket
            -- compare and is offered. Erring toward sending is the safe way to
            -- misread a request.
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = {},
                spans = {
                    { s = "not a number", e = BASE + 9, h = 1 },
                    { s = BASE, e = BASE + 9 },           -- no fold
                    "not even a table",
                },
            }

            assert.is_true(ids["rec_old1:0"])
        end)

        it("treats a request carrying no spans exactly as before", function()
            -- The compatibility proof for a peer that predates the manifest:
            -- it sends its whole bucket table and no spans, and every key must
            -- take the same per-bucket comparison it always took.
            addRecordInBucket(BASE, "old1")
            addRecordInBucket(BASE + 1, "old2")

            local localBuckets = GBL:ComputeBucketHashes(guildData)
            local ids = serve{
                sinceTimestamp = 0,
                bucketHashes = { [BASE] = localBuckets[BASE] },
            }

            assert.is_nil(ids["rec_old1:0"])
            assert.is_true(ids["rec_old2:0"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Send order (newest-first)
    ---------------------------------------------------------------------------

    describe("send order (newest-first)", function()
        local BASE = 86400 * 20000  -- WoW-era seconds (multiple of BUCKET_SECONDS)

        it("SortSendListNewestFirst orders records newest-bucket-first", function()
            local B = GBL.BUCKET_SECONDS
            -- Supplied out of order; the sort must put the newest bucket first.
            local list = {
                { id = "b2:0", timestamp = BASE + 2 * B + 10 },
                { id = "b7:0", timestamp = BASE + 7 * B + 10 },
                { id = "b4:0", timestamp = BASE + 4 * B + 10 },
                { id = "b9:0", timestamp = BASE + 9 * B + 10 },
            }
            GBL:SortSendListNewestFirst(list)
            local ids = {}
            for i, r in ipairs(list) do ids[i] = r.id end
            assert.same({ "b9:0", "b7:0", "b4:0", "b2:0" }, ids)
        end)

        it("SortSendListNewestFirst no-ops on empty or single-element lists", function()
            assert.same({}, GBL:SortSendListNewestFirst({}))
            local one = { { id = "x:0", timestamp = BASE } }
            assert.equals(one, GBL:SortSendListNewestFirst(one))
            assert.equals("x:0", one[1].id)
        end)

        it("HandleSyncRequest puts the newest buckets in the first chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local B = GBL.BUCKET_SECONDS
            -- Five records in distinct buckets, inserted oldest-first. The chunk
            -- record cap is 4, so the oldest bucket (1) must spill to a later
            -- chunk; the first chunk leads with the newest (5).
            for _, b in ipairs({ 1, 2, 3, 4, 5 }) do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "A", timestamp = BASE + b * B + 10,
                    scanTime = BASE + b * B + 10, id = "b" .. b .. ":0",
                    itemID = 100, count = 1, tab = 1,
                })
            end

            -- Empty bucketHashes => every local bucket differs => all sent.
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0, bucketHashes = {} })

            -- The first chunk sends synchronously; inspect it without firing timers.
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals("SYNC_DATA", data.type)
            assert.is_true(#data.transactions >= 1)
            assert.equals("b5:0", data.transactions[1].id)  -- newest bucket leads
            for _, tx in ipairs(data.transactions) do
                assert.is_true(tx.id ~= "b1:0",
                    "oldest bucket must not ride in the first chunk")
            end

            -- The diagnostic line records the span being sent.
            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message:find("Send order newest%-first") then found = true end
            end
            assert.is_true(found, "expected a newest-first send-order audit line")
        end)

        it("merge result is identical regardless of receive order", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Three distinct records; ids are the dedup key. Format mirrors the
            -- proven HandleSyncData records above.
            local function rec(n)
                return {
                    type = "deposit", player = "P" .. n,
                    itemID = 1000 + n, count = n, tab = 1,
                    timestamp = BASE + n * 100, scanTime = BASE + n * 100,
                    scannedBy = "OfficerB",
                    id = "deposit|P" .. n .. "|" .. (1000 + n) .. "|" .. n .. "|1|0",
                }
            end

            -- Fresh tables per call so the two runs never share mutated records.
            -- Each batch is the same multiset and includes an intra-batch
            -- duplicate of rec(1), in opposite orders.
            local function receiveAndCollect(makeBatch)
                guildData.transactions = {}
                guildData.moneyTransactions = {}
                guildData.seenTxHashes = {}
                guildData.eventCounts = {}
                GBL:ResetSyncState()
                GBL:HandleSyncData("OfficerB", {
                    chunk = 1, totalChunks = 1,
                    transactions = makeBatch(), moneyTransactions = {},
                })
                local ids = {}
                for _, tx in ipairs(guildData.transactions) do ids[#ids + 1] = tx.id end
                table.sort(ids)
                return ids
            end

            local idsForward = receiveAndCollect(function()
                return { rec(1), rec(2), rec(1), rec(3) }
            end)
            local idsReverse = receiveAndCollect(function()
                return { rec(3), rec(1), rec(2), rec(1) }
            end)

            assert.equals(3, #idsForward)  -- the intra-batch duplicate was dropped
            assert.same(idsForward, idsReverse)  -- receive order did not change the merge
        end)
    end)

    ---------------------------------------------------------------------------
    -- Bounded sync sessions
    --
    -- A fresh install used to pull the sender's whole history in one
    -- session. At roughly one record per chunk and a 1.0s gap floor that is
    -- hours, during which both peers BUSY everyone else and neither starts
    -- anything, and MAX_RECEIVE_DURATION aborts it at 30 minutes anyway. So
    -- large backfills could not complete in one session at all: they only
    -- ever progressed through the abort-recovery path.
    --
    -- The sender now caps each session at whole 6-hour buckets worth about
    -- SESSION_RECORD_CAP records, newest first, and says how many buckets
    -- are left on the final chunk. Whole buckets matter: a half-sent bucket
    -- hashes differently from either side and gets re-sent entire next
    -- time, while a complete one converges and drops out of the diff.
    ---------------------------------------------------------------------------

    describe("session cap", function()
        local BUCKET = 6 * 3600

        --- Build n records inside one 6-hour bucket.
        local function recordsInBucket(bucketKey, n, prefix)
            local out = {}
            for i = 1, n do
                out[#out + 1] = {
                    type = "deposit", player = "P1", tab = 1, itemID = 100 + i,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = bucketKey * BUCKET + i,
                    scanTime = bucketKey * BUCKET + i,
                    id = prefix .. ":" .. bucketKey .. ":" .. i,
                    _occurrence = 0, scannedBy = "OfficerA",
                }
            end
            return out
        end

        local function bucketKeysOf(list)
            local seen = {}
            for _, rec in ipairs(list) do
                seen[GBL:BucketKeyForRecord(rec)] = true
            end
            return seen
        end

        describe("_SelectSessionBuckets", function()
            it("takes whole buckets newest first until the cap is met", function()
                local newest = recordsInBucket(475100, 2, "a")
                local middle = recordsInBucket(475099, 2, "b")
                local oldest = recordsInBucket(475098, 2, "c")
                local all = {}
                for _, set in ipairs({ newest, middle, oldest }) do
                    for _, r in ipairs(set) do all[#all + 1] = r end
                end

                local tx, money, sent, remaining =
                    GBL:_SelectSessionBuckets(all, {}, 3)

                -- 2 records is under the cap of 3, so it takes a second whole
                -- bucket and stops: 4 records, never a partial bucket.
                assert.equals(4, #tx)
                assert.equals(0, #money)
                assert.is_true(sent[475100])
                assert.is_true(sent[475099])
                assert.is_nil(sent[475098])
                assert.equals(1, remaining)
            end)

            it("always sends at least one bucket, even over the cap", function()
                local big = recordsInBucket(475100, 10, "big")
                local tx, _, sent, remaining = GBL:_SelectSessionBuckets(big, {}, 3)

                assert.equals(10, #tx)
                assert.is_true(sent[475100])
                assert.equals(0, remaining)
            end)

            it("counts item and money records against one cap", function()
                local items = recordsInBucket(475100, 2, "i")
                local money = recordsInBucket(475099, 2, "m")

                local tx, mn, _, remaining =
                    GBL:_SelectSessionBuckets(items, money, 2)

                -- The newest bucket alone meets the cap, so the money bucket
                -- waits even though it is a different list.
                assert.equals(2, #tx)
                assert.equals(0, #mn)
                assert.equals(1, remaining)
            end)

            it("returns empty results for empty input", function()
                local tx, money, sent, remaining = GBL:_SelectSessionBuckets({}, {}, 300)
                assert.same({}, tx)
                assert.same({}, money)
                assert.same({}, sent)
                assert.equals(0, remaining)
            end)

            -- The one real deadlock. If the differing buckets are ones the
            -- receiver already holds from a third peer, a plain newest-first
            -- cap re-sends the same all-duplicate tranche every session and
            -- older differing buckets never get a turn. Buckets we already
            -- sent to this peer, whose contents have not changed since, sort
            -- behind everything else.
            it("demotes buckets already sent to this peer unchanged", function()
                local newest = recordsInBucket(475100, 2, "a")
                local older = recordsInBucket(475099, 2, "b")
                local all = {}
                for _, set in ipairs({ newest, older }) do
                    for _, r in ipairs(set) do all[#all + 1] = r end
                end

                local demote = { [475100] = true }
                local tx, _, sent, remaining =
                    GBL:_SelectSessionBuckets(all, {}, 2, demote)

                assert.is_true(sent[475099], "the un-demoted bucket goes first")
                assert.is_nil(sent[475100])
                assert.equals(2, #tx)
                assert.equals(1, remaining)
            end)

            it("preserves input order inside a bucket", function()
                local recs = recordsInBucket(475100, 3, "ord")
                local tx = GBL:_SelectSessionBuckets(recs, {}, 300)
                assert.equals(recs[1].id, tx[1].id)
                assert.equals(recs[2].id, tx[2].id)
                assert.equals(recs[3].id, tx[3].id)
            end)
        end)

        describe("capped sends", function()
            --- Seed more records than one session may carry, spread over
            --- enough buckets that the cap has somewhere to stop.
            local function seedOverCap()
                local perBucket = math.ceil(GBL.SYNC_SESSION_RECORD_CAP / 2)
                for b = 0, 3 do
                    for _, rec in ipairs(
                        recordsInBucket(475100 - b, perBucket, "seed" .. b)) do
                        table.insert(guildData.transactions, rec)
                        guildData.seenTxHashes[rec.id] = rec.timestamp
                    end
                end
                GBL:ResetHashCache()
            end

            local function sentChunks()
                local out = {}
                for _, msg in ipairs(MockAce.sentCommMessages) do
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "SYNC_DATA" then out[#out + 1] = data end
                end
                return out
            end

            --- ACK each chunk and fire the inter-chunk gap so the whole
            --- session actually goes out, the way a healthy peer drives it.
            --- The clock has to move: SendNextChunk enforces a wall-clock gap
            --- floor between issues, and against a frozen GetTime it just
            --- reschedules itself and the send never leaves chunk one.
            local function drainSend(target)
                for _ = 1, 4000 do
                    if not GBL:GetSyncStatus().sending then break end
                    local idx = tonumber(
                        GBL:GetSyncStatus().sendProgress:match("^(%d+)"))
                    GBL:HandleAck(target, { chunk = idx })
                    MockWoW.serverTime = MockWoW.serverTime + 2
                    local fired = false
                    for i = #MockWoW.pendingTimers, 1, -1 do
                        local t = MockWoW.pendingTimers[i]
                        if not t.cancelled and not t.fired and t.delay
                            and t.delay > 0 and t.delay <= 2.0 then
                            t.fired = true
                            t.callback()
                            fired = true
                            break
                        end
                    end
                    if not fired then break end
                end
            end

            local function recordsSent()
                local total = 0
                for _, chunk in ipairs(sentChunks()) do
                    total = total + #(chunk.transactions or {})
                        + #(chunk.moneyTransactions or {})
                end
                return total
            end

            it("sends fewer records than it holds, and says how many buckets wait",
            function()
                seedOverCap()
                local held = #guildData.transactions

                GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
                drainSend("OfficerB")

                local sent = recordsSent()
                assert.is_true(sent > 0, "a capped session still sends something")
                assert.is_true(sent < held,
                    "a capped session should hold records back")

                local capped = false
                for _, entry in ipairs(GBL:GetAuditTrail()) do
                    if entry.message and entry.message:find("capped", 1, true) then
                        capped = true
                    end
                end
                assert.is_true(capped, "the cap should be visible in a capture")
            end)

            -- Only the last chunk carries it, and only when there is
            -- something left, so an uncapped send puts nothing new on the
            -- wire at all.
            it("puts remaining on the final chunk only", function()
                seedOverCap()
                GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
                drainSend("OfficerB")

                local chunks = sentChunks()
                assert.is_true(#chunks > 0)
                for i = 1, #chunks - 1 do
                    assert.is_nil(chunks[i].remaining,
                        "only the final chunk announces what is left")
                end
                assert.is_true((chunks[#chunks].remaining or 0) > 0)
            end)

            it("omits remaining when everything fits in one session", function()
                table.insert(guildData.transactions, recordsInBucket(475100, 1, "small")[1])
                guildData.seenTxHashes["small:475100:1"] = 475100 * BUCKET + 1
                GBL:ResetHashCache()

                GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
                drainSend("OfficerB")

                for _, chunk in ipairs(sentChunks()) do
                    assert.is_nil(chunk.remaining)
                end
            end)

            -- Rotation: asking again gets the buckets that waited, not the
            -- same tranche forever.
            it("serves the deferred buckets on the next request", function()
                seedOverCap()
                GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
                drainSend("OfficerB")
                local firstPass = {}
                for _, chunk in ipairs(sentChunks()) do
                    for _, rec in ipairs(chunk.transactions or {}) do
                        firstPass[GBL:BucketKeyForRecord(rec)] = true
                    end
                end

                MockAce.sentCommMessages = {}
                GBL:FinishSending()
                GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
                drainSend("OfficerB")

                local secondPassHasNew = false
                for _, chunk in ipairs(sentChunks()) do
                    for _, rec in ipairs(chunk.transactions or {}) do
                        if not firstPass[GBL:BucketKeyForRecord(rec)] then
                            secondPassHasNew = true
                        end
                    end
                end
                assert.is_true(secondPassHasNew,
                    "the second session must reach buckets the first deferred")
            end)
        end)

        describe("receiver side", function()
            local function chunkFrom(fields)
                local base = {
                    chunk = 1, totalChunks = 1,
                    transactions = {}, moneyTransactions = {},
                    protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                    guild = "Test Guild",
                }
                for k, v in pairs(fields or {}) do base[k] = v end
                return base
            end

            it("records what the sender said is left", function()
                GBL:RequestSync("OfficerB", 0)
                GBL:HandleSyncData("OfficerB", chunkFrom{
                    chunk = 1, totalChunks = 2, remaining = nil,
                })
                GBL:HandleSyncData("OfficerB", chunkFrom{
                    chunk = 2, totalChunks = 2, remaining = 7,
                })

                local found = false
                for _, entry in ipairs(GBL:GetAuditTrail()) do
                    if entry.message
                        and entry.message:find("Partial session", 1, true)
                        and entry.message:find("7", 1, true) then
                        found = true
                    end
                end
                assert.is_true(found,
                    "a partial session should be visible in a capture")
            end)

            it("says nothing about partial sessions on a complete one", function()
                GBL:RequestSync("OfficerB", 0)
                GBL:HandleSyncData("OfficerB", chunkFrom{})

                for _, entry in ipairs(GBL:GetAuditTrail()) do
                    if entry.message then
                        assert.is_nil(entry.message:find("Partial session", 1, true))
                    end
                end
            end)

            -- The seam is the sender's post-receive HELLO and the nudges,
            -- not a timer we own. Scheduling our own continuation here is
            -- the contingency, held back until a capture shows the gossip
            -- seam is actually too slow.
            it("schedules no continuation of its own", function()
                GBL:RequestSync("OfficerB", 0)
                MockWoW.pendingTimers = {}
                GBL:HandleSyncData("OfficerB", chunkFrom{ remaining = 4 })

                for _, timer in ipairs(MockWoW.pendingTimers) do
                    assert.is_not.equals(3.0, timer.delay,
                        "no self-scheduled continuation in the free model")
                end
                assert.is_false(GBL:GetSyncStatus().receiving)
            end)

            -- Two real sessions back to back. The second sender says nothing
            -- about buckets left over, so reporting one means the first
            -- session's count survived a teardown it should not have.
            -- (ResetSyncState is deliberately not used here: it clears the
            -- sync log, which is the evidence this test reads.)
            it("clears the count when a new session starts", function()
                GBL:RequestSync("OfficerB", 0)
                GBL:HandleSyncData("OfficerB", chunkFrom{ remaining = 4 })
                GBL:RequestSync("OfficerC", 0)
                GBL:HandleSyncData("OfficerC", chunkFrom{})

                local partials = 0
                for _, entry in ipairs(GBL:GetAuditTrail()) do
                    if entry.message and entry.message:find("Partial session", 1, true) then
                        partials = partials + 1
                    end
                end
                assert.equals(1, partials,
                    "a stale count must not follow into the next session")
            end)
        end)
    end)
end)
