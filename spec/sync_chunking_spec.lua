------------------------------------------------------------------------
-- spec/sync_chunking_spec.lua — Sync chunking
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync chunking", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    describe("PrepareChunks", function()
        it("splits records across multiple chunks", function()
            local txList = {}
            for i = 1, 50 do
                txList[i] = { type = "deposit", player = "P", timestamp = i, id = "h" .. i }
            end

            local chunks = GBL:PrepareChunks(txList, {})
            assert.is_true(#chunks >= 2, "50 records should produce multiple chunks")
            -- All records accounted for
            local total = 0
            for _, chunk in ipairs(chunks) do
                total = total + #chunk.transactions
            end
            assert.equals(50, total)
        end)

        it("returns empty table for no transactions", function()
            local chunks = GBL:PrepareChunks({}, {})
            assert.equals(0, #chunks)
        end)

        it("distributes item and money transactions across chunks", function()
            local txList = {}
            for i = 1, 20 do
                txList[i] = { type = "deposit", player = "P", timestamp = i }
            end
            local moneyList = {}
            for i = 1, 20 do
                moneyList[i] = { type = "deposit", player = "P", amount = i * 100, timestamp = i }
            end

            local chunks = GBL:PrepareChunks(txList, moneyList)
            assert.is_true(#chunks >= 2, "40 records should produce multiple chunks")
            -- All records accounted for
            local totalTx, totalMoney = 0, 0
            for _, chunk in ipairs(chunks) do
                totalTx = totalTx + #chunk.transactions
                totalMoney = totalMoney + #chunk.moneyTransactions
            end
            assert.equals(20, totalTx)
            assert.equals(20, totalMoney)
        end)

        it("splits by estimated size when records have large fields", function()
            local txList = {}
            -- Each record ~180 bytes estimated (long strings push size)
            for i = 1, 35 do
                txList[i] = {
                    type = "withdraw",
                    player = "Verylongnamecharacter",
                    itemID = 200000 + i,
                    count = 20,
                    tab = 3,
                    classID = 0,
                    subclassID = 5,
                    timestamp = 1700000000 + i,
                    id = "withdraw|Verylongnamecharacter|" .. (200000 + i)
                        .. "|20|3|472222:" .. i,
                }
            end
            local chunks = GBL:PrepareChunks(txList, {})
            -- Splits on either the byte budget or the record cap, whichever
            -- triggers first. With 35 records and any reasonable per-record
            -- size, this should always produce multiple chunks.
            assert.is_true(#chunks >= 2,
                "should produce multiple chunks from size limit")
            for _, chunk in ipairs(chunks) do
                assert.is_true(#chunk.transactions <= GBL.SYNC_CHUNK_SIZE,
                    "no chunk should exceed hard record cap")
            end
        end)

        it("places a single oversized record in its own chunk", function()
            local bigId = string.rep("x", 6000)
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
    -- PrepareChunks: the event count rider (#92)
    --
    -- Event counts used to be partitioned into fixed batches of 10 and stapled
    -- onto chunks by index after packing, so they never touched the budget. The
    -- packer now takes them as an argument and fills each chunk to a
    -- whole-message target that counts records, entries and the envelope
    -- together. spec/wire_contract_spec.lua pins the estimators against the real
    -- serializer; these pin the packing behaviour.
    ---------------------------------------------------------------------------

    describe("PrepareChunks with event counts", function()
        --- Small realistic records, well under the target on their own.
        local function makeRecords(n, kind)
            local list = {}
            for i = 1, n do
                list[i] = {
                    type = kind or "deposit",
                    player = "Alice-Stormrage",
                    itemID = 191318 + i,
                    count = 20,
                    tab = 3,
                    classID = 0,
                    subclassID = 3,
                    timestamp = 1775580307 - i,
                    id = ("deposit|Alice-Stormrage|%d|20|3|493216:0"):format(191318 + i),
                }
            end
            return list
        end

        local function makeEventCounts(n)
            local ec = {}
            for i = 1, n do
                ec[("deposit|Alice-Stormrage|%d|20|3|493216"):format(191318 + i)] =
                    { count = i, asOf = 1775580307 }
            end
            return ec
        end

        --- What the whole serialized message is estimated to weigh.
        local function wholeMessageEstimate(chunk)
            local bytes = GBL:_EstimateEnvelopeBytes(GBL:GetGuildName())
            for _, rec in ipairs(chunk.transactions) do
                bytes = bytes + GBL:_EstimateRecordBytes(rec)
            end
            for _, rec in ipairs(chunk.moneyTransactions) do
                bytes = bytes + GBL:_EstimateRecordBytes(rec)
            end
            for key, entry in pairs(chunk.eventCounts or {}) do
                bytes = bytes + GBL:_EstimateEventCountBytes(key, entry)
            end
            return bytes
        end

        local function countPairs(t)
            local n = 0
            for _ in pairs(t or {}) do n = n + 1 end
            return n
        end

        it("keeps every chunk's whole-message estimate inside the target", function()
            local chunks = GBL:PrepareChunks(makeRecords(20), {}, makeEventCounts(20))
            assert.is_true(#chunks > 0, "expected chunks")
            for i, chunk in ipairs(chunks) do
                local estimate = wholeMessageEstimate(chunk)
                assert.is_true(estimate <= GBL.SYNC_CHUNK_TARGET_BYTES,
                    ("chunk %d estimates %d bytes, over the %d target"):format(
                        i, estimate, GBL.SYNC_CHUNK_TARGET_BYTES))
            end
        end)

        it("packs every event count entry exactly once", function()
            local ec = makeEventCounts(25)
            local chunks = GBL:PrepareChunks(makeRecords(8), {}, ec)

            -- pairs() order is nondeterministic, so this counts rather than
            -- asserting which chunk any given entry landed on.
            local seen = {}
            local total = 0
            for _, chunk in ipairs(chunks) do
                for key, entry in pairs(chunk.eventCounts or {}) do
                    assert.is_nil(seen[key], "entry packed twice: " .. key)
                    seen[key] = true
                    total = total + 1
                    assert.equals(ec[key].count, entry.count)
                end
            end
            assert.equals(25, total)
        end)

        it("adds carrier chunks when event counts outrun the record chunks", function()
            -- Two records fill at most one chunk; 40 entries cannot ride along.
            local chunks = GBL:PrepareChunks(makeRecords(2), {}, makeEventCounts(40))
            assert.is_true(#chunks > 1,
                "event counts beyond the record chunks need carrier chunks")

            local total = 0
            for _, chunk in ipairs(chunks) do
                total = total + countPairs(chunk.eventCounts)
            end
            assert.equals(40, total)
        end)

        it("packs event counts when there are no records at all", function()
            local chunks = GBL:PrepareChunks({}, {}, makeEventCounts(15))
            assert.is_true(#chunks > 0, "event counts alone still need chunks")

            local total = 0
            for _, chunk in ipairs(chunks) do
                assert.equals(0, #chunk.transactions)
                assert.equals(0, #chunk.moneyTransactions)
                total = total + countPairs(chunk.eventCounts)
            end
            assert.equals(15, total)
        end)

        it("returns no chunks when there is nothing to send", function()
            assert.equals(0, #GBL:PrepareChunks({}, {}, {}))
            assert.equals(0, #GBL:PrepareChunks({}, {}, nil))
        end)

        it("still places a record that overshoots the target on its own", function()
            -- A long cross-realm id can exceed the target by itself. The packer
            -- must make progress rather than seal an empty chunk forever.
            local txList = {
                { type = "deposit", player = "P", timestamp = 1, id = string.rep("x", 900) },
                { type = "deposit", player = "P", timestamp = 2, id = "small" },
            }
            local chunks = GBL:PrepareChunks(txList, {}, {})
            local total = 0
            for _, chunk in ipairs(chunks) do total = total + #chunk.transactions end
            assert.equals(2, total, "no record may be dropped")
            assert.equals(1, #chunks[1].transactions,
                "the oversized record takes a chunk of its own")
        end)

        it("still places an event count entry that overshoots on its own", function()
            local ec = { [string.rep("k", 900)] = { count = 1, asOf = 1775580307 } }
            local chunks = GBL:PrepareChunks({}, {}, ec)
            local total = 0
            for _, chunk in ipairs(chunks) do
                total = total + countPairs(chunk.eventCounts)
            end
            assert.equals(1, total, "no entry may be dropped")
        end)

        it("keeps the record cap as a backstop", function()
            local chunks = GBL:PrepareChunks(makeRecords(30), {}, {})
            for _, chunk in ipairs(chunks) do
                assert.is_true(#chunk.transactions + #chunk.moneyTransactions
                    <= GBL.SYNC_CHUNK_SIZE, "no chunk may exceed the record cap")
            end
        end)

        it("keeps the newest-first record order the sender chose", function()
            local records = makeRecords(12)
            local chunks = GBL:PrepareChunks(records, {}, makeEventCounts(6))

            local flat = {}
            for _, chunk in ipairs(chunks) do
                for _, rec in ipairs(chunk.transactions) do
                    flat[#flat + 1] = rec.id
                end
            end
            assert.equals(#records, #flat)
            for i, rec in ipairs(records) do
                assert.equals(rec.id, flat[i], "packing reordered the send list")
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- PrepareChunks: counts ride with the records they describe (#114)
    --
    -- Event counts contribute nothing to the fingerprint, so a session that
    -- delivers all of a bucket's records and then aborts before the counts
    -- leaves both sides' hashes for that bucket matching. The diff never
    -- selects it again, no peer offers it again, and the receiver cannot
    -- re-derive the counts locally, so the loss is permanent and network-wide.
    -- The packer therefore emits a bucket's entries when it reaches the first
    -- record of that bucket, which makes
    --
    --     max(entry chunk) <= first-record chunk <= last-record chunk
    --
    -- hold per bucket, and that is what makes any truncation of the chunk list
    -- carry the counts of every bucket it completed.
    --
    -- Every fixture in the rider suite above sits in ONE bucket (slot 493216
    -- for the records and for the entries alike), so that suite cannot see this
    -- property in either direction: a single-bucket send satisfies it for free.
    -- These fixtures span several buckets, which is what makes them able to
    -- fail.
    ---------------------------------------------------------------------------

    describe("PrepareChunks interleaves event counts per bucket", function()
        -- A bucket key is floor(timeSlot / 6), so slots six apart are adjacent
        -- buckets. Deriving the slot from the bucket keeps the two fixture
        -- builders honest about describing the same bucket.
        local function slotOf(bucket) return bucket * 6 end

        local function bucketRecords(bucket, n, firstItem, kind)
            local list = {}
            local slot = slotOf(bucket)
            for i = 1, n do
                local itemID = firstItem + i
                list[i] = {
                    type = kind or "deposit",
                    player = "Alice-Stormrage",
                    itemID = itemID,
                    count = 20,
                    tab = 3,
                    classID = 0,
                    subclassID = 3,
                    timestamp = slot * 3600 + i,
                    id = ("%s|Alice-Stormrage|%d|20|3|%d:0")
                        :format(kind or "deposit", itemID, slot),
                }
            end
            return list
        end

        local function bucketCounts(bucket, n, firstItem, kind)
            local ec = {}
            local slot = slotOf(bucket)
            for i = 1, n do
                ec[("%s|Alice-Stormrage|%d|20|3|%d")
                    :format(kind or "deposit", firstItem + i, slot)] =
                    { count = i, asOf = slot * 3600 }
            end
            return ec
        end

        local function concatLists(...)
            local out = {}
            for _, list in ipairs({ ... }) do
                for _, v in ipairs(list) do out[#out + 1] = v end
            end
            return out
        end

        local function mergeMaps(...)
            local out = {}
            for _, map in ipairs({ ... }) do
                for k, v in pairs(map) do out[k] = v end
            end
            return out
        end

        local function countPairs(t)
            local n = 0
            for _ in pairs(t or {}) do n = n + 1 end
            return n
        end

        --- Per bucket: the first and last chunk holding one of its records, and
        --- the last chunk holding one of its entries.
        local function indexByBucket(chunks)
            local firstRecord, lastRecord, lastEntry = {}, {}, {}
            for i, chunk in ipairs(chunks) do
                for _, list in ipairs({ chunk.transactions, chunk.moneyTransactions }) do
                    for _, rec in ipairs(list) do
                        local b = GBL:BucketKeyForRecord(rec)
                        if not firstRecord[b] then firstRecord[b] = i end
                        lastRecord[b] = i
                    end
                end
                for key in pairs(chunk.eventCounts or {}) do
                    local b = GBL:BucketKeyForEventCount(key)
                    if b and i > (lastEntry[b] or 0) then lastEntry[b] = i end
                end
            end
            return firstRecord, lastRecord, lastEntry
        end

        --- The property the ordering exists for. A send aborts by stopping
        --- part-way down the chunk list, so every prefix of it has to be a
        --- consistent delivery: any bucket whose records are all inside the
        --- prefix must have all of its counts inside it too. A bucket only
        --- partly delivered is fine, because its hash still differs and the
        --- diff re-selects it next session.
        local function assertAbortSafe(chunks, lists, counts)
            local totalRecords, totalEntries = {}, {}
            for _, list in ipairs(lists) do
                for _, rec in ipairs(list) do
                    local b = GBL:BucketKeyForRecord(rec)
                    totalRecords[b] = (totalRecords[b] or 0) + 1
                end
            end
            for key in pairs(counts) do
                local b = GBL:BucketKeyForEventCount(key)
                totalEntries[b] = (totalEntries[b] or 0) + 1
            end

            local seenRecords, seenEntries = {}, {}
            for prefix = 1, #chunks do
                local chunk = chunks[prefix]
                for _, list in ipairs({ chunk.transactions, chunk.moneyTransactions }) do
                    for _, rec in ipairs(list) do
                        local b = GBL:BucketKeyForRecord(rec)
                        seenRecords[b] = (seenRecords[b] or 0) + 1
                    end
                end
                for key in pairs(chunk.eventCounts or {}) do
                    local b = GBL:BucketKeyForEventCount(key)
                    if b then seenEntries[b] = (seenEntries[b] or 0) + 1 end
                end

                for bucket, total in pairs(totalRecords) do
                    if (seenRecords[bucket] or 0) == total then
                        assert.equals(totalEntries[bucket] or 0,
                            seenEntries[bucket] or 0,
                            ("abort after chunk %d of %d: bucket %d has all %d "
                             .. "records but %d of %d counts"):format(
                                prefix, #chunks, bucket, total,
                                seenEntries[bucket] or 0, totalEntries[bucket] or 0))
                    end
                end
            end
        end

        --- Three buckets, each with more records than one chunk holds, and
        --- counts for each. Bucket-contiguous, which is the order
        --- SortSendListNewestFirst produces.
        local function threeBucketSend()
            return concatLists(
                    bucketRecords(82202, 6, 191300),
                    bucketRecords(82203, 6, 191400),
                    bucketRecords(82204, 6, 191500)),
                mergeMaps(
                    bucketCounts(82202, 4, 191300),
                    bucketCounts(82203, 4, 191400),
                    bucketCounts(82204, 4, 191500))
        end

        it("puts a bucket's counts no later than its first record", function()
            local records, counts = threeBucketSend()
            local chunks = GBL:PrepareChunks(records, {}, counts)

            local firstRecord, _, lastEntry = indexByBucket(chunks)
            assert.is_true(countPairs(lastEntry) > 0, "no entries were packed")

            for bucket, entryChunk in pairs(lastEntry) do
                assert.is_not_nil(firstRecord[bucket],
                    ("bucket %d packed entries but no records"):format(bucket))
                assert.is_true(entryChunk <= firstRecord[bucket],
                    ("bucket %d: last entry in chunk %d, first record in chunk %d")
                        :format(bucket, entryChunk, firstRecord[bucket]))
            end
        end)

        -- The property the invariant exists for. A send aborts by stopping
        -- part-way down the chunk list, so every prefix of it has to be a
        -- consistent delivery: any bucket whose records are all inside the
        -- prefix must have all of its counts inside it too. A bucket only
        -- partly delivered is fine, because its hash still differs and the
        -- diff re-selects it.
        it("carries a completed bucket's counts in every prefix that completes it",
        function()
            local records, counts = threeBucketSend()
            assertAbortSafe(GBL:PrepareChunks(records, {}, counts), { records }, counts)
        end)

        -- One bucket can own records in both send lists. The emission mark is
        -- shared across the two walks, so the entries go out at the first
        -- record of either and never twice.
        it("emits a bucket's counts once when its records span both lists", function()
            local items = bucketRecords(82202, 2, 191300)
            local money = bucketRecords(82202, 2, 191350, "repair")
            local counts = bucketCounts(82202, 3, 191300)
            local chunks = GBL:PrepareChunks(items, money, counts)

            local seen, total = {}, 0
            for _, chunk in ipairs(chunks) do
                for key in pairs(chunk.eventCounts or {}) do
                    assert.is_nil(seen[key], "entry packed twice: " .. key)
                    seen[key] = true
                    total = total + 1
                end
            end
            assert.equals(3, total)

            local firstRecord, _, lastEntry = indexByBucket(chunks)
            assert.is_true(lastEntry[82202] <= firstRecord[82202],
                "counts must not trail the records of a bucket spanning both lists")
        end)

        -- A bucket can own records ONLY in the money list, and the emission
        -- mark is shared across the two walks, so the money walk has to be able
        -- to emit a bucket the item walk never reached. Dropping that call
        -- survived the test above, because there the bucket had records in both
        -- lists and the item walk always got there first. Without it the counts
        -- fall through to the leftover pass, which still delivers them but puts
        -- them wherever room is left, and once the packed chunks are full that
        -- is in carriers after the records they describe. Few records and many
        -- counts is the shape that makes the difference visible.
        it("puts a money-only bucket's counts before its records", function()
            local items = bucketRecords(82202, 8, 191300)
            local money = bucketRecords(82207, 1, 191500, "repair")
            local counts = mergeMaps(
                bucketCounts(82202, 2, 191300),
                bucketCounts(82207, 12, 191500, "repair"))

            local chunks = GBL:PrepareChunks(items, money, counts)
            local firstRecord, _, lastEntry = indexByBucket(chunks)

            assert.is_not_nil(lastEntry[82207], "the money-only bucket packed no counts")
            assert.is_not_nil(firstRecord[82207], "the money-only bucket packed no records")
            assert.is_true(lastEntry[82207] <= firstRecord[82207],
                ("money-only bucket: last count in chunk %d, first record in chunk "
                 .. "%d of %d"):format(
                    lastEntry[82207], firstRecord[82207], #chunks))

            assertAbortSafe(chunks, { items, money }, counts)
        end)

        -- A chunk holding entries and no records is legal mid-stream, so the
        -- seal test cannot be "has it got a record in it". Without an
        -- emptiness-based guard the oversized record joins the entry chunk and
        -- the chunk carries both.
        it("seals an entry-only chunk before an oversized record", function()
            local slot = slotOf(82202)
            local oversized = {
                type = "deposit", player = "P", timestamp = slot * 3600,
                id = "deposit|" .. string.rep("x", 900) .. "|" .. slot .. ":0",
            }
            local chunks = GBL:PrepareChunks({ oversized }, {}, bucketCounts(82202, 1, 191300))

            assert.is_true(#chunks >= 2,
                "the entry and the oversized record cannot share a chunk")
            assert.equals(0, #chunks[1].transactions,
                "the first chunk carries the count, not the record")
            assert.equals(1, countPairs(chunks[1].eventCounts))
            assert.equals(1, #chunks[2].transactions)
            assert.is_nil(chunks[2].eventCounts)
        end)

        -- Entries whose bucket sends no records have no record to ride ahead
        -- of, and a key with no readable slot has no bucket at all. Both keep
        -- the forward-cursor top-up and carrier behaviour from #92, so this
        -- guards the old path through the new code rather than a new promise.
        it("still delivers counts for buckets that sent no records, and unreadable keys",
        function()
            local records = bucketRecords(82202, 2, 191300)
            local counts = mergeMaps(
                bucketCounts(82202, 2, 191300),
                bucketCounts(89999, 2, 191600))
            counts["nodigits"] = { count = 1, asOf = 1775563200 }

            local chunks = GBL:PrepareChunks(records, {}, counts)

            local seen, total = {}, 0
            for _, chunk in ipairs(chunks) do
                for key in pairs(chunk.eventCounts or {}) do
                    assert.is_nil(seen[key], "entry packed twice: " .. key)
                    seen[key] = true
                    total = total + 1
                end
            end
            assert.equals(5, total, "every entry must ride exactly once")
            assert.is_true(seen["nodigits"], "an unreadable key must still ride")
        end)

        -- The invariant is over bucket KEYS, and the two sides reach a key by
        -- different readings: a count key always yields its trailing slot,
        -- while a record whose id the "|slot:occ" pattern cannot read falls
        -- back to floor(timestamp / BUCKET_SECONDS). Where those disagree the
        -- record's own count is filed under a different bucket and rides with
        -- that one. What still holds, and what this pins, is the structural
        -- half: a group reaches the leftover pass exactly when no record
        -- produced its key, so a leftover entry has no first-record chunk to be
        -- late for, every entry still rides exactly once, and no completed
        -- bucket is reported as owing counts that were never filed under it.
        it("still delivers the count of a record whose id carries no slot", function()
            local unparseable = {
                type = "deposit", player = "Alice-Stormrage", itemID = 191301,
                count = 20, tab = 3, classID = 0, subclassID = 3,
                timestamp = 1,
                id = "deposit|Alice-Stormrage|191301|20|3|noslot",
            }
            local counts = bucketCounts(82202, 1, 191300)
            local onlyKey = next(counts)

            -- If these ever agree the case has stopped exercising what it is
            -- here for, and the test would pass for the wrong reason.
            assert.are_not.equals(
                GBL:BucketKeyForRecord(unparseable),
                GBL:BucketKeyForEventCount(onlyKey),
                "fixture no longer exercises the two readings disagreeing")

            local chunks = GBL:PrepareChunks({ unparseable }, {}, counts)

            local seen, total = {}, 0
            for _, chunk in ipairs(chunks) do
                for key in pairs(chunk.eventCounts or {}) do
                    assert.is_nil(seen[key], "entry packed twice: " .. key)
                    seen[key] = true
                    total = total + 1
                end
            end
            assert.equals(1, total, "the count must still ride exactly once")
            assert.is_true(seen[onlyKey], "the count must be the one that rode")

            assertAbortSafe(chunks, { { unparseable } }, counts)
        end)

        it("keeps every chunk inside the target across many buckets", function()
            local records, counts = {}, {}
            for b = 82200, 82211 do
                records = concatLists(records, bucketRecords(b, 3, 191000 + b))
                counts = mergeMaps(counts, bucketCounts(b, 3, 191000 + b))
            end
            local chunks = GBL:PrepareChunks(records, {}, counts)

            local envelope = GBL:_EstimateEnvelopeBytes(GBL:GetGuildName())
            for i, chunk in ipairs(chunks) do
                local bytes = envelope
                for _, list in ipairs({ chunk.transactions, chunk.moneyTransactions }) do
                    for _, rec in ipairs(list) do
                        bytes = bytes + GBL:_EstimateRecordBytes(rec)
                    end
                end
                for key, entry in pairs(chunk.eventCounts or {}) do
                    bytes = bytes + GBL:_EstimateEventCountBytes(key, entry)
                end
                assert.is_true(bytes <= GBL.SYNC_CHUNK_TARGET_BYTES,
                    ("chunk %d estimates %d bytes, over the %d target"):format(
                        i, bytes, GBL.SYNC_CHUNK_TARGET_BYTES))
            end

            local flat, total = {}, 0
            for _, chunk in ipairs(chunks) do
                for _, rec in ipairs(chunk.transactions) do flat[#flat + 1] = rec.id end
                total = total + countPairs(chunk.eventCounts)
            end
            assert.equals(#records, #flat, "no record may be dropped")
            for i, rec in ipairs(records) do
                assert.equals(rec.id, flat[i], "packing reordered the send list")
            end

            local expected = 0
            for _ in pairs(counts) do expected = expected + 1 end
            assert.equals(expected, total, "no entry may be dropped or duplicated")
        end)

        -- The fallback path: a request with no bucketHashes leaves the serve
        -- with no bucket keys to filter by, so every count rides whether or not
        -- its bucket is in the send. That makes orphan entries the norm there
        -- rather than the exception, which is why it gets an end-to-end check.
        it("delivers every count on the no-bucketHashes fallback path", function()
            for _, rec in ipairs(concatLists(
                bucketRecords(82202, 3, 191300),
                bucketRecords(82203, 3, 191400))) do
                rec.scanTime = rec.timestamp
                rec.scannedBy = "Alice-Stormrage"
                guildData.transactions[#guildData.transactions + 1] = rec
            end
            guildData.eventCounts = mergeMaps(
                bucketCounts(82202, 2, 191300),
                bucketCounts(82203, 2, 191400),
                bucketCounts(89999, 2, 191600))

            local expected = 0
            for _ in pairs(guildData.eventCounts) do expected = expected + 1 end

            Sync.serveRequest(GBL, "PeerA", request({ sinceTimestamp = 0 }))
            Sync.drainSend(GBL, "PeerA")

            local seen, total = {}, 0
            for i = 1, #MockAce.sentCommMessages do
                local ok, data = GBL:Deserialize(MockAce.sentCommMessages[i].text)
                if ok and data.type == "SYNC_DATA" and data.eventCounts then
                    for key in pairs(data.eventCounts) do
                        if not seen[key] then
                            seen[key] = true
                            total = total + 1
                        end
                    end
                end
            end
            assert.equals(expected, total,
                "the fallback path must put every event count on the wire")
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
                    type = "withdraw", player = "Longnamechar",
                    itemID = 200000 + i, count = 20, tab = 3,
                    timestamp = 1700000000 + i, scanTime = 1700000000 + i,
                    scannedBy = "Anotherlongname", id = "withdraw|Longnamechar|" .. (200000 + i) .. "|20|3|472222:" .. i,
                    classID = 0, subclassID = 5,
                    category = "Trade Goods: Cloth",
                })
            end

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- The first sent message should be the SYNC_DATA chunk
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local payload = MockAce.sentCommMessages[1].text
            -- Mock LibDeflate is identity (no compression). In production, LibDeflate
            -- compresses ~60-80%, keeping wire size well under WHISPER_SAFE_BYTES (2000).
            -- Here we verify raw serialized size stays within a reasonable bound.
            -- Budget is 5000 bytes for record estimates; full SYNC_DATA wrapper adds overhead.
            assert.is_true(#payload < 7000,
                "Raw serialized chunk (" .. #payload .. " bytes) exceeds byte budget + overhead")
        end)

        it("logs warning when chunk exceeds safe size", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Verify the audit trail does NOT contain a size warning for normal chunks
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

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

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Original record should still have itemLink
            assert.equals(originalLink, guildData.transactions[1].itemLink)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Compression
    ---------------------------------------------------------------------------

    describe("compression", function()
        it("protocol version is 4", function()
            assert.equals(4, GBL.SYNC_PROTOCOL_VERSION)
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
    -- eventCounts spread across chunks (receive side)
    ---------------------------------------------------------------------------

    describe("eventCounts spread across chunks", function()
        it("merges eventCounts from multiple chunks", function()
            guildData.eventCounts = {}

            -- Chunk 1 carries first batch
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["key1"] = { count = 5, asOf = 1000 },
                    ["key2"] = { count = 3, asOf = 1000 },
                },
            })

            -- Chunk 2 carries second batch
            GBL:HandleSyncData("OfficerB", {
                chunk = 2,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["key3"] = { count = 7, asOf = 1000 },
                },
            })

            -- Chunk 3 carries no eventCounts
            GBL:HandleSyncData("OfficerB", {
                chunk = 3,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
            })

            assert.equals(5, guildData.eventCounts["key1"].count)
            assert.equals(3, guildData.eventCounts["key2"].count)
            assert.equals(7, guildData.eventCounts["key3"].count)
        end)

        it("later chunk eventCounts merge with max-wins", function()
            guildData.eventCounts = {
                ["existing"] = { count = 2, asOf = 500 },
            }

            -- Chunk 3 sends higher count for existing key
            GBL:HandleSyncData("OfficerB", {
                chunk = 3,
                totalChunks = 5,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["existing"] = { count = 8, asOf = 2000 },
                },
            })

            assert.equals(8, guildData.eventCounts["existing"].count)
        end)

        it("retransmitted chunk is idempotent", function()
            guildData.eventCounts = {}

            local chunkData = {
                chunk = 2,
                totalChunks = 3,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["key1"] = { count = 5, asOf = 1000 },
                },
            }

            -- Receive same chunk twice (retransmit)
            GBL:HandleSyncData("OfficerB", chunkData)
            GBL:HandleSyncData("OfficerB", chunkData)

            -- Count is still 5, not doubled
            assert.equals(5, guildData.eventCounts["key1"].count)
        end)

        it("chunk with eventCounts but no records merges correctly", function()
            guildData.eventCounts = {}

            GBL:HandleSyncData("OfficerB", {
                chunk = 5,
                totalChunks = 5,
                transactions = {},
                moneyTransactions = {},
                eventCounts = {
                    ["pure_counts"] = { count = 10, asOf = 3000 },
                },
            })

            assert.equals(10, guildData.eventCounts["pure_counts"].count)
        end)
    end)
end)
