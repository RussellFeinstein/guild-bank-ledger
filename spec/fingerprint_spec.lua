--- fingerprint_spec.lua — Tests for Fingerprint.lua hash functions
local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

describe("Fingerprint", function()
    local GBL, guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        guildData = GBL:GetGuildData()
        GBL:ResetHashCache()
    end)

    ---------------------------------------------------------------------------
    -- HashString
    ---------------------------------------------------------------------------

    describe("HashString", function()
        it("returns a number for any string input", function()
            assert.is_number(GBL:HashString("hello"))
            assert.is_number(GBL:HashString(""))
            assert.is_number(GBL:HashString("deposit|Thrall|12345|5|1|472222:0"))
        end)

        it("returns the same value for the same string", function()
            local h1 = GBL:HashString("test string")
            local h2 = GBL:HashString("test string")
            assert.equals(h1, h2)
        end)

        it("returns different values for different strings", function()
            local h1 = GBL:HashString("deposit|Thrall|12345|5|1|472222:0")
            local h2 = GBL:HashString("withdraw|Jaina|67890|10|2|472222:0")
            assert.are_not.equals(h1, h2)
        end)

        it("handles empty string", function()
            local h = GBL:HashString("")
            assert.is_number(h)
            assert.equals(5381, h) -- djb2 initial value with no characters
        end)

        it("handles nil input", function()
            assert.equals(0, GBL:HashString(nil))
        end)

        it("stays within 32-bit range", function()
            local h = GBL:HashString(string.rep("x", 200))
            assert.is_true(h >= 0)
            assert.is_true(h < 4294967296)
        end)
    end)

    ---------------------------------------------------------------------------
    -- XOR32
    ---------------------------------------------------------------------------

    describe("XOR32", function()
        it("XOR of identical values is 0", function()
            assert.equals(0, GBL:XOR32(12345, 12345))
            assert.equals(0, GBL:XOR32(0, 0))
        end)

        it("XOR is commutative", function()
            local a, b = 12345, 67890
            assert.equals(GBL:XOR32(a, b), GBL:XOR32(b, a))
        end)

        it("XOR is associative", function()
            local a, b, c = 111, 222, 333
            local left = GBL:XOR32(GBL:XOR32(a, b), c)
            local right = GBL:XOR32(a, GBL:XOR32(b, c))
            assert.equals(left, right)
        end)

        it("identity: XOR with 0 returns the value", function()
            assert.equals(42, GBL:XOR32(42, 0))
            assert.equals(0, GBL:XOR32(0, 0))
        end)

        it("handles 32-bit boundary values", function()
            local max32 = 4294967295
            assert.equals(max32, GBL:XOR32(0, max32))
            assert.equals(0, GBL:XOR32(max32, max32))
        end)
    end)

    ---------------------------------------------------------------------------
    -- ComputeDataHash
    ---------------------------------------------------------------------------

    describe("ComputeDataHash", function()
        it("returns 0 for empty dataset", function()
            assert.equals(0, GBL:ComputeDataHash(guildData))
        end)

        it("returns 0 for nil guildData", function()
            assert.equals(0, GBL:ComputeDataHash(nil))
        end)

        it("returns non-zero for dataset with records", function()
            table.insert(guildData.transactions, {
                id = "deposit|Thrall|12345|5|1|472222:0",
                timestamp = 1700000000,
            })
            assert.is_not.equals(0, GBL:ComputeDataHash(guildData))
        end)

        it("same records in different order produce same hash", function()
            local rec1 = { id = "deposit|A|100|1|1|100:0", timestamp = 100 }
            local rec2 = { id = "withdraw|B|200|2|2|200:0", timestamp = 200 }

            table.insert(guildData.transactions, rec1)
            table.insert(guildData.transactions, rec2)
            local hash1 = GBL:ComputeDataHash(guildData)

            guildData.transactions = { rec2, rec1 }
            local hash2 = GBL:ComputeDataHash(guildData)

            assert.equals(hash1, hash2)
        end)

        it("adding a record changes the hash", function()
            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = 100,
            })
            local hash1 = GBL:ComputeDataHash(guildData)

            table.insert(guildData.transactions, {
                id = "deposit|B|200|2|2|200:0", timestamp = 200,
            })
            local hash2 = GBL:ComputeDataHash(guildData)

            assert.are_not.equals(hash1, hash2)
        end)

        it("includes both item and money transactions", function()
            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = 100,
            })
            local hashItemOnly = GBL:ComputeDataHash(guildData)

            table.insert(guildData.moneyTransactions, {
                id = "repair|B|5000|200:0", timestamp = 200,
            })
            local hashBoth = GBL:ComputeDataHash(guildData)

            assert.are_not.equals(hashItemOnly, hashBoth)
        end)

        it("skips records with nil id", function()
            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = 100,
            })
            local hashWithOne = GBL:ComputeDataHash(guildData)

            table.insert(guildData.transactions, {
                timestamp = 200, -- no id
            })
            local hashWithNilId = GBL:ComputeDataHash(guildData)

            assert.equals(hashWithOne, hashWithNilId)
        end)

        it("identical datasets produce identical hashes", function()
            local records = {
                { id = "deposit|A|100|1|1|100:0", timestamp = 100 },
                { id = "withdraw|B|200|2|2|200:0", timestamp = 200 },
                { id = "move|C|300|1|3|300:0", timestamp = 300 },
            }

            for _, r in ipairs(records) do
                table.insert(guildData.transactions, r)
            end
            local hash1 = GBL:ComputeDataHash(guildData)

            -- Create a second dataset with same records
            local guildData2 = GBL:GetGuildData()
            guildData2.transactions = {}
            guildData2.moneyTransactions = {}
            for _, r in ipairs(records) do
                table.insert(guildData2.transactions, r)
            end
            local hash2 = GBL:ComputeDataHash(guildData2)

            assert.equals(hash1, hash2)
        end)
    end)

    ---------------------------------------------------------------------------
    -- ComputeBucketHashes
    ---------------------------------------------------------------------------

    describe("ComputeBucketHashes", function()
        it("returns empty table for empty dataset", function()
            local buckets = GBL:ComputeBucketHashes(guildData)
            local count = 0
            for _ in pairs(buckets) do count = count + 1 end
            assert.equals(0, count)
        end)

        it("groups records by 6-hour bucket key derived from ID timeSlot", function()
            -- Bucket key = floor(timeSlot / 6) where timeSlot is from record ID
            local slot1 = 480001  -- hour 480001, bucket = 80000
            local slot2 = 480025  -- hour 480025, bucket = 80004 (different day)
            local bucket1 = math.floor(slot1 / 6)
            local bucket2 = math.floor(slot2 / 6)

            assert.are_not.equals(bucket1, bucket2)

            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|" .. slot1 .. ":0", timestamp = slot1 * 3600,
            })
            table.insert(guildData.transactions, {
                id = "deposit|B|200|1|1|" .. slot2 .. ":0", timestamp = slot2 * 3600,
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[bucket1])
            assert.is_not_nil(buckets[bucket2])
            assert.are_not.equals(buckets[bucket1], buckets[bucket2])
        end)

        it("records within same 6-hour window share a bucket", function()
            -- Two timeSlots 5 hours apart — same 6h bucket (floor(ts/6) equal)
            local slot1 = 480000          -- hour 480000
            local slot2 = 480000 + 5      -- hour 480005 (still in same 6h window)
            local bucketKey = math.floor(slot1 / 6)

            assert.equals(math.floor(slot2 / 6), bucketKey)

            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|" .. slot1 .. ":0", timestamp = slot1 * 3600,
            })
            local buckets1 = GBL:ComputeBucketHashes(guildData)

            table.insert(guildData.transactions, {
                id = "deposit|B|200|1|1|" .. slot2 .. ":0", timestamp = slot2 * 3600,
            })
            local buckets2 = GBL:ComputeBucketHashes(guildData)

            -- Same bucket key, but hash should change with the second record
            assert.are_not.equals(buckets1[bucketKey], buckets2[bucketKey])
        end)

        it("records 7 hours apart fall in different buckets", function()
            local slot1 = 480000          -- hour 480000
            local slot2 = 480000 + 7      -- hour 480007 (second 6h window)
            local bucket1 = math.floor(slot1 / 6)
            local bucket2 = math.floor(slot2 / 6)

            assert.are_not.equals(bucket1, bucket2)

            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|" .. slot1 .. ":0", timestamp = slot1 * 3600,
            })
            table.insert(guildData.transactions, {
                id = "deposit|B|200|1|1|" .. slot2 .. ":0", timestamp = slot2 * 3600,
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[bucket1])
            assert.is_not_nil(buckets[bucket2])
        end)

        it("includes money transactions", function()
            local slot = 480001
            local bucketKey = math.floor(slot / 6)

            table.insert(guildData.moneyTransactions, {
                id = "repair|A|5000|" .. slot .. ":0", timestamp = slot * 3600,
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[bucketKey])
            assert.is_true(buckets[bucketKey] > 0)
        end)

        it("skips records with nil id", function()
            local dayTs = 20000 * 86400 + 3600
            -- No id → no bucket entry (can't parse timeSlot)
            table.insert(guildData.transactions, {
                timestamp = dayTs, -- no id
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            -- Should be empty (no parseable records)
            local count = 0
            for _ in pairs(buckets) do count = count + 1 end
            assert.equals(0, count)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Bucket key after normalization (v0.11.2 regression)
    ---------------------------------------------------------------------------

    describe("bucket key after normalization", function()
        it("bucket key follows normalized ID, not timestamp", function()
            -- Record starts with timeSlot=107 (bucket = floor(107/6) = 17)
            local record = {
                id = "deposit|A|100|1|1|107:0",
                timestamp = 3600 * 107,
            }
            table.insert(guildData.transactions, record)

            local bucketsBefore = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(bucketsBefore[17])  -- floor(107/6) = 17

            -- Simulate normalization: change ID to timeSlot=100 (bucket = floor(100/6) = 16)
            record.id = "deposit|A|100|1|1|100:0"
            record.timestamp = 3600 * 100
            GBL:ResetHashCache()

            local bucketsAfter = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(bucketsAfter[16])  -- floor(100/6) = 16
            assert.is_nil(bucketsAfter[17])       -- old bucket gone
        end)

        it("bucket key uses ID timeSlot not timestamp when they disagree", function()
            -- ID has timeSlot=100 (bucket 16), but timestamp points to slot 108 (bucket 18)
            local record = {
                id = "deposit|A|100|1|1|100:0",
                timestamp = 3600 * 108,  -- would give bucket 18 via fallback
            }

            -- BucketKeyForRecord should use ID's timeSlot, not timestamp
            assert.equals(math.floor(100 / 6), GBL:BucketKeyForRecord(record))

            table.insert(guildData.transactions, record)
            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[math.floor(100 / 6)])
            assert.is_nil(buckets[math.floor(108 / 6)])
        end)

        it("ComputeBucketHashes reflects record in new bucket after cross-bucket normalization", function()
            -- Record starts in bucket 17 (timeSlot=107)
            local oldId = "deposit|A|100|1|1|107:0"
            local newId = "deposit|A|100|1|1|100:0"
            local record = { id = oldId, timestamp = 3600 * 107 }
            table.insert(guildData.transactions, record)

            local bucketsBefore = GBL:ComputeBucketHashes(guildData)
            assert.equals(GBL:HashString(oldId), bucketsBefore[17])

            -- Normalize to bucket 16 (timeSlot=100)
            record.id = newId
            record.timestamp = 3600 * 100
            GBL:ResetHashCache()

            local bucketsAfter = GBL:ComputeBucketHashes(guildData)
            assert.is_nil(bucketsAfter[17])
            assert.equals(GBL:HashString(newId), bucketsAfter[16])
        end)
    end)

    ---------------------------------------------------------------------------
    -- FoldBucketRange (span fingerprints for the hierarchical sync request)
    ---------------------------------------------------------------------------

    describe("FoldBucketRange", function()
        it("folds an empty range to the djb2 seed", function()
            assert.equals(5381, GBL:FoldBucketRange({}, 1, 100))
            assert.equals(5381, GBL:FoldBucketRange({ [500] = 7 }, 1, 100))
        end)

        it("matches a hand-computed fold for a single bucket", function()
            -- h = 5381; h = h*33 + key; h = h*33 + hash
            -- 5381*33 + 10 = 177583; 177583*33 + 7 = 5860246
            assert.equals(5860246, GBL:FoldBucketRange({ [10] = 7 }, 10, 10))
        end)

        it("ignores buckets outside the range", function()
            local inRangeOnly = GBL:FoldBucketRange({ [10] = 7 }, 10, 10)
            local withNeighbours = GBL:FoldBucketRange(
                { [5] = 3, [10] = 7, [15] = 9 }, 10, 10)
            assert.equals(inRangeOnly, withNeighbours)
        end)

        it("distinguishes bucket sets that XOR to the same value", function()
            -- The reason the span fold is not XOR. 3 XOR 5 == 1 XOR 7 == 6, so an
            -- XOR-of-XORs fold would call these two ranges identical and the
            -- divergence would be invisible to sync forever.
            local a = { [10] = 3, [11] = 5 }
            local b = { [10] = 1, [11] = 7 }
            assert.equals(GBL:XOR32(3, 5), GBL:XOR32(1, 7))
            assert.are_not.equals(
                GBL:FoldBucketRange(a, 10, 11),
                GBL:FoldBucketRange(b, 10, 11))
        end)

        it("is order dependent across buckets", function()
            local a = { [10] = 7, [11] = 9 }
            local b = { [10] = 9, [11] = 7 }
            assert.are_not.equals(
                GBL:FoldBucketRange(a, 10, 11),
                GBL:FoldBucketRange(b, 10, 11))
        end)

        it("does not cancel a repeated hash value", function()
            -- Under XOR, two buckets holding the same hash fold to 0, which is
            -- also what an empty range folds to.
            local repeated = GBL:FoldBucketRange({ [10] = 5, [11] = 5 }, 10, 11)
            assert.are_not.equals(5381, repeated)
            assert.are_not.equals(0, repeated)
        end)

        it("changes when any bucket hash changes", function()
            local base = GBL:FoldBucketRange({ [10] = 7, [11] = 9 }, 10, 11)
            local moved = GBL:FoldBucketRange({ [10] = 7, [11] = 10 }, 10, 11)
            assert.are_not.equals(base, moved)
        end)

        it("changes when a bucket is added inside the range", function()
            local without = GBL:FoldBucketRange({ [10] = 7, [12] = 9 }, 10, 12)
            local with = GBL:FoldBucketRange({ [10] = 7, [11] = 4, [12] = 9 }, 10, 12)
            assert.are_not.equals(without, with)
        end)

        it("stays within 32-bit range", function()
            local buckets = {}
            for key = 1, 200 do buckets[key] = 4294967295 end
            local h = GBL:FoldBucketRange(buckets, 1, 200)
            assert.is_true(h >= 0)
            assert.is_true(h < 4294967296)
            assert.equals(math.floor(h), h)
        end)
    end)

    ---------------------------------------------------------------------------
    -- BuildRequestManifest (bounded SYNC_REQUEST payload)
    ---------------------------------------------------------------------------

    describe("BuildRequestManifest", function()
        -- Build a bucket table with contiguous keys first..last.
        local function contiguous(first, last)
            local buckets = {}
            for key = first, last do buckets[key] = (key * 7919) % 4294967296 end
            return buckets
        end

        local function count(t)
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end

        it("passes nil through so the request omits bucketHashes entirely", function()
            local detail, spans = GBL:BuildRequestManifest(nil)
            assert.is_nil(detail)
            assert.is_nil(spans)
        end)

        it("returns an empty detail table and no spans for an empty dataset", function()
            local detail, spans = GBL:BuildRequestManifest({})
            assert.same({}, detail)
            assert.is_nil(spans)
        end)

        it("sends pure detail and no spans below the detail budget", function()
            local detail, spans = GBL:BuildRequestManifest(contiguous(1, 10))
            assert.equals(10, count(detail))
            assert.is_nil(spans)
        end)

        it("sends pure detail and no spans at exactly the detail budget", function()
            local n = GBL.SYNC_REQUEST_DETAIL_BUCKETS
            local detail, spans = GBL:BuildRequestManifest(contiguous(1, n))
            assert.equals(n, count(detail))
            assert.is_nil(spans)
        end)

        it("opens a single span at one bucket past the detail budget", function()
            local n = GBL.SYNC_REQUEST_DETAIL_BUCKETS
            local buckets = contiguous(1, n + 1)
            local detail, spans = GBL:BuildRequestManifest(buckets)

            assert.equals(n, count(detail))
            assert.equals(1, #spans)
            assert.equals(1, spans[1].s)
            assert.equals(1, spans[1].e)   -- detailStart (2) - 1
            assert.equals(GBL:FoldBucketRange(buckets, 1, 1), spans[1].h)
        end)

        it("keeps the newest buckets as detail", function()
            local n = GBL.SYNC_REQUEST_DETAIL_BUCKETS
            local buckets = contiguous(1, n + 20)
            local detail = GBL:BuildRequestManifest(buckets)

            assert.equals(n, count(detail))
            for key = 21, n + 20 do
                assert.equals(buckets[key], detail[key])
            end
            for key = 1, 20 do
                assert.is_nil(detail[key])
            end
        end)

        it("opens no more spans than there are older buckets", function()
            local n = GBL.SYNC_REQUEST_DETAIL_BUCKETS
            local _, spans = GBL:BuildRequestManifest(contiguous(1, n + 3))
            assert.equals(3, #spans)
        end)

        it("caps spans at the span budget for a long history", function()
            local buckets = contiguous(1, 300)
            local detail, spans = GBL:BuildRequestManifest(buckets)

            assert.equals(GBL.SYNC_REQUEST_DETAIL_BUCKETS, count(detail))
            assert.equals(GBL.SYNC_REQUEST_SPAN_COUNT, #spans)
        end)

        it("tiles the older range with no gaps and no overlap", function()
            local buckets = contiguous(1, 300)
            local detail, spans = GBL:BuildRequestManifest(buckets)

            local detailStart = math.huge
            for key in pairs(detail) do
                if key < detailStart then detailStart = key end
            end

            assert.equals(1, spans[1].s)
            for i = 2, #spans do
                assert.equals(spans[i - 1].e + 1, spans[i].s)
            end
            assert.equals(detailStart - 1, spans[#spans].e)
        end)

        it("spreads older buckets evenly across the spans", function()
            local buckets = contiguous(1, 300)
            local _, spans = GBL:BuildRequestManifest(buckets)

            -- 250 older buckets over 8 spans: two of 32, six of 31.
            local sizes = {}
            for _, span in ipairs(spans) do
                local n = 0
                for key in pairs(buckets) do
                    if key >= span.s and key <= span.e then n = n + 1 end
                end
                table.insert(sizes, n)
            end
            assert.same({ 32, 32, 31, 31, 31, 31, 31, 31 }, sizes)
        end)

        it("tiles across gaps so a bucket the requester lacks is still covered", function()
            -- Older keys 1, 5, 100, 200 with the detail window far above them.
            -- A peer holding a bucket at key 50, which this requester does not
            -- have at all, must still land inside a span rather than in an
            -- uncovered hole: that is what makes the peer's extra bucket show
            -- up as a fold mismatch instead of being silently skipped.
            local buckets = { [1] = 11, [5] = 22, [100] = 33, [200] = 44 }
            for key = 1000, 1000 + GBL.SYNC_REQUEST_DETAIL_BUCKETS - 1 do
                buckets[key] = key
            end

            local _, spans = GBL:BuildRequestManifest(buckets)
            assert.equals(4, #spans)
            assert.equals(1, spans[1].s)
            assert.equals(999, spans[#spans].e)
            for i = 2, #spans do
                assert.equals(spans[i - 1].e + 1, spans[i].s)
            end

            local covered = false
            for _, span in ipairs(spans) do
                if 50 >= span.s and 50 <= span.e then covered = true end
            end
            assert.is_true(covered)
        end)

        it("folds each span over exactly its own declared range", function()
            local buckets = contiguous(1, 300)
            local _, spans = GBL:BuildRequestManifest(buckets)
            for _, span in ipairs(spans) do
                assert.equals(GBL:FoldBucketRange(buckets, span.s, span.e), span.h)
            end
        end)

        it("does not mutate the bucket table it is given", function()
            local buckets = contiguous(1, 300)
            local before = count(buckets)
            GBL:BuildRequestManifest(buckets)
            assert.equals(before, count(buckets))
            assert.equals((1 * 7919) % 4294967296, buckets[1])
        end)
    end)

    ---------------------------------------------------------------------------
    -- GetDataHash (cached)
    ---------------------------------------------------------------------------

    describe("GetDataHash", function()
        it("returns 0 for nil guildData", function()
            assert.equals(0, GBL:GetDataHash(nil))
        end)

        it("returns cached hash when txCount unchanged", function()
            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = 100,
            })
            local hash1 = GBL:GetDataHash(guildData)
            local hash2 = GBL:GetDataHash(guildData)
            assert.equals(hash1, hash2)
        end)

        it("recomputes hash when txCount changes", function()
            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = 100,
            })
            local hash1 = GBL:GetDataHash(guildData)

            table.insert(guildData.transactions, {
                id = "deposit|B|200|2|2|200:0", timestamp = 200,
            })
            local hash2 = GBL:GetDataHash(guildData)

            assert.are_not.equals(hash1, hash2)
        end)
    end)

    ---------------------------------------------------------------------------
    -- GetBucketHashes
    --
    -- The cached form of ComputeBucketHashes (#115). What is worth pinning is
    -- not that caching is fast but that it invalidates on exactly the right
    -- events, because a stale bucket map does not look broken: it silently
    -- decides which records a sync offers.
    ---------------------------------------------------------------------------

    describe("GetBucketHashes", function()
        local function addRecord(id, timestamp)
            table.insert(guildData.transactions, { id = id, timestamp = timestamp })
        end

        it("returns an empty map for nil guildData", function()
            assert.same({}, GBL:GetBucketHashes(nil))
        end)

        it("agrees with an uncached ComputeBucketHashes", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            addRecord("deposit|B|200|2|2|472228:0", 1700100000)

            assert.same(GBL:ComputeBucketHashes(guildData), GBL:GetBucketHashes(guildData))
        end)

        it("recomputes when a record is added", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local first = GBL:GetBucketHashes(guildData)
            local before = {}
            for k, v in pairs(first) do before[k] = v end

            addRecord("deposit|B|200|2|2|472228:0", 1700100000)

            assert.are_not.same(before, GBL:GetBucketHashes(guildData))
            assert.same(GBL:ComputeBucketHashes(guildData), GBL:GetBucketHashes(guildData))
        end)

        -- The contract every id-rewriting caller depends on. Only record.id
        -- feeds a bucket hash, so rewriting one in place changes the correct
        -- answer while leaving the record count identical, and the cache cannot
        -- see it. That is why the migrations and CleanupWithEventCounts call
        -- ResetHashCache, and why anything added later that rewrites an id has
        -- to do the same.
        it("does not notice an id rewritten in place until the cache is reset", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local stale = GBL:GetBucketHashes(guildData)[math.floor(472222 / 6)]
            assert.is_number(stale)

            guildData.transactions[1].id = "deposit|A|100|1|1|999999:0"

            -- Same count, so the cache still answers with the old bucket.
            assert.equals(stale, GBL:GetBucketHashes(guildData)[math.floor(472222 / 6)])

            GBL:ResetHashCache()

            local fresh = GBL:GetBucketHashes(guildData)
            assert.is_nil(fresh[math.floor(472222 / 6)])
            assert.is_number(fresh[math.floor(999999 / 6)])
        end)

        -- A count-only key would collide here: same number of records, a
        -- different guild's data. The map decides which records get sent, so
        -- serving the wrong one would offer the wrong records.
        it("does not serve one guild's map for another with the same count", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local first = GBL:GetBucketHashes(guildData)
            local firstKey = math.floor(472222 / 6)
            assert.is_number(first[firstKey])

            local other = {
                transactions = { { id = "deposit|Z|900|9|9|888888:0", timestamp = 1700200000 } },
                moneyTransactions = {},
            }

            local otherMap = GBL:GetBucketHashes(other)
            assert.is_nil(otherMap[firstKey])
            assert.is_number(otherMap[math.floor(888888 / 6)])
        end)
    end)

    ---------------------------------------------------------------------------
    -- PeekBucketHashes
    --
    -- The read-only companion to GetBucketHashes, for a caller that wants the
    -- map only if it is already sitting there. HandleHello prints a bucket
    -- count on every inbound HELLO, and computing it meant a full walk over
    -- every record per heartbeat, worst exactly during a receive: the record
    -- count moves with each stored chunk, so the cache is invalid every time
    -- and the walk runs on the busiest client in the guild.
    ---------------------------------------------------------------------------

    describe("PeekBucketHashes", function()
        local function addRecord(id, timestamp)
            table.insert(guildData.transactions, { id = id, timestamp = timestamp })
        end

        local function countingCompute(fn)
            local calls = 0
            local orig = GBL.ComputeBucketHashes
            GBL.ComputeBucketHashes = function(...)
                calls = calls + 1
                return orig(...)
            end
            local ok, err = pcall(fn)
            GBL.ComputeBucketHashes = orig
            if not ok then error(err, 0) end
            return calls
        end

        it("returns nil when the cache is cold", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:ResetHashCache()

            assert.is_nil(GBL:PeekBucketHashes(guildData))
        end)

        it("computes nothing, even with records waiting", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:ResetHashCache()

            local calls = countingCompute(function()
                GBL:PeekBucketHashes(guildData)
            end)

            assert.equals(0, calls)
        end)

        it("hands back the same map GetBucketHashes built", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local warm = GBL:GetBucketHashes(guildData)

            local calls = countingCompute(function()
                assert.equals(warm, GBL:PeekBucketHashes(guildData))
            end)

            assert.equals(0, calls)
        end)

        it("goes cold again when the cache is reset", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:GetBucketHashes(guildData)
            assert.is_not_nil(GBL:PeekBucketHashes(guildData))

            GBL:ResetHashCache()

            assert.is_nil(GBL:PeekBucketHashes(guildData))
        end)

        -- Warm is not the same as current. The peek reports what the cache
        -- holds and nothing more, so a count that moved since is still served.
        -- That is the deal a diagnostic reader is getting: a bucket count is a
        -- slowly changing number, and a few records out of date beats making
        -- the busiest client in the guild walk its whole history to print it.
        it("serves a map whose count has moved on", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local warm = GBL:GetBucketHashes(guildData)
            addRecord("deposit|B|200|2|2|472228:0", 1700100000)

            local calls = countingCompute(function()
                assert.equals(warm, GBL:PeekBucketHashes(guildData))
            end)

            assert.equals(0, calls)
        end)

        -- Source identity is checked even though the count is not. A stale
        -- count misreports a diagnostic by a few; another guild's map is a
        -- different number entirely, about data this client is not looking at.
        it("returns nil when the cache belongs to another guild", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:GetBucketHashes(guildData)

            local other = { transactions = {}, moneyTransactions = {} }

            assert.is_nil(GBL:PeekBucketHashes(other))
        end)

        it("returns nil for nil guildData", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:GetBucketHashes(guildData)

            assert.is_nil(GBL:PeekBucketHashes(nil))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Sliced bucket hashing
    --
    -- ComputeBucketHashes walks every record and hashes every id in one go.
    -- That is the first of the passes that trips the script watchdog when a
    -- large-history client serves a SYNC_REQUEST (#115), so the serving
    -- pipeline needs to do the same work a slice at a time across frames.
    --
    -- The scan lives here rather than in Sync.lua because the hashing, the
    -- bucket key derivation and the cache it stamps are all file-local to this
    -- module. Handing those out to be driven from elsewhere would mean
    -- exporting three internals to save one.
    ---------------------------------------------------------------------------

    -- The third accessor. PeekBucketHashes answers "is there something to
    -- print" and ignores the count on purpose; this one answers "can I use
    -- this as the truth" and does not. The serving pipeline asks it first, so
    -- getting the distinction wrong would mean serving off a stale map, which
    -- decides which records a peer is offered.
    describe("_FreshBucketHashes", function()
        local function addRecord(id, timestamp)
            table.insert(guildData.transactions, { id = id, timestamp = timestamp })
        end

        it("returns nil when the cache is cold", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:ResetHashCache()

            assert.is_nil(GBL:_FreshBucketHashes(guildData))
        end)

        it("hands back the warm map when the count still matches", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            local warm = GBL:GetBucketHashes(guildData)

            assert.equals(warm, GBL:_FreshBucketHashes(guildData))
        end)

        -- The whole point of the separate accessor: PeekBucketHashes still
        -- returns a map here, and this one must not.
        it("returns nil once the record count has moved", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:GetBucketHashes(guildData)
            addRecord("deposit|B|200|2|2|472228:0", 1700100000)

            assert.is_not_nil(GBL:PeekBucketHashes(guildData))
            assert.is_nil(GBL:_FreshBucketHashes(guildData))
        end)

        it("returns nil when the cache belongs to another guild", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            GBL:GetBucketHashes(guildData)

            assert.is_nil(GBL:_FreshBucketHashes(
                { transactions = {}, moneyTransactions = {} }))
        end)

        it("returns nil for nil guildData", function()
            assert.is_nil(GBL:_FreshBucketHashes(nil))
        end)
    end)

    describe("sliced bucket hashing", function()
        local function addRecord(id, timestamp)
            table.insert(guildData.transactions, { id = id, timestamp = timestamp })
        end

        local function addMoney(id, timestamp)
            table.insert(guildData.moneyTransactions, { id = id, timestamp = timestamp })
        end

        -- Drive a scan to completion, returning how many steps it took.
        local function runScan(budget)
            local scan = GBL:StartBucketHashScan(guildData)
            local steps, done = 0, false
            while not done do
                local _, finished = GBL:StepBucketHashScan(guildData, scan, budget)
                done = finished
                steps = steps + 1
                if steps > 500 then error("scan did not finish") end
            end
            return scan, steps
        end

        local function seed(n)
            for i = 1, n do
                addRecord("deposit|P" .. i .. "|100|1|1|" .. (472200 + i) .. ":0",
                    1700000000 + i)
            end
        end

        it("agrees with an uncached ComputeBucketHashes", function()
            seed(10)
            addMoney("withdrawal|M|500|1|1|472222:0", 1700000000)
            local expected = GBL:ComputeBucketHashes(guildData)
            GBL:ResetHashCache()

            local scan = runScan(3)

            assert.same(expected, scan.buckets)
        end)

        it("needs more than one step when the record count exceeds the budget",
        function()
            seed(10)
            GBL:ResetHashCache()

            local _, steps = runScan(3)

            assert.is_true(steps > 1,
                "a 10-record dataset on a budget of 3 must take several steps")
        end)

        it("spends no more than the budget on one step", function()
            seed(10)
            GBL:ResetHashCache()

            local scan = GBL:StartBucketHashScan(guildData)
            local spent = GBL:StepBucketHashScan(guildData, scan, 4)

            assert.is_true(spent <= 4, "a step must respect its budget")
        end)

        it("warms the cache when it completes", function()
            seed(4)
            GBL:ResetHashCache()
            assert.is_nil(GBL:PeekBucketHashes(guildData))

            local scan = runScan(2)

            assert.equals(scan.buckets, GBL:PeekBucketHashes(guildData))
        end)

        -- The stamp records the count captured when the walk started, not the
        -- count now. A record appended mid-scan is not in the map, so a stamp
        -- claiming the current count would hand the next reader a map that is
        -- quietly missing records. Reporting the old count makes the next read
        -- see a mismatch and recompute, which is the safe direction to be wrong.
        -- Money records are what give this test teeth. The scan walks items
        -- then money through one cursor, so the boundary between them is a
        -- captured length. Re-reading it mid-scan would slide the boundary: the
        -- appended item would be walked as if it had always been there and the
        -- last money record would fall off the end, and with items only there
        -- is no boundary to slide and the bug is invisible.
        it("does not fold in a record appended mid-scan", function()
            seed(3)
            addMoney("withdrawal|M1|500|1|1|472240:0", 1700200000)
            addMoney("withdrawal|M2|600|1|1|472246:0", 1700300000)
            local expected = GBL:ComputeBucketHashes(guildData)
            GBL:ResetHashCache()

            local scan = GBL:StartBucketHashScan(guildData)
            GBL:StepBucketHashScan(guildData, scan, 2)
            addRecord("deposit|LATE|999|1|1|472299:0", 1700900000)

            local done = false
            while not done do
                local _, finished = GBL:StepBucketHashScan(guildData, scan, 2)
                done = finished
            end

            -- Exactly the map the dataset had when the scan started: both money
            -- records in, the late item out.
            assert.same(expected, scan.buckets)
            assert.is_nil(scan.buckets[math.floor(472299 / 6)],
                "a record appended mid-scan must not appear in this map")
            assert.is_not_nil(scan.buckets[math.floor(472246 / 6)],
                "the last money record must still have been walked")

            -- And the stamp must not claim the map is current: the next read
            -- recomputes and the late record shows up.
            assert.is_not_nil(GBL:GetBucketHashes(guildData)[math.floor(472299 / 6)])
        end)

        it("completes immediately on an empty dataset", function()
            GBL:ResetHashCache()

            local scan = GBL:StartBucketHashScan(guildData)
            local _, done = GBL:StepBucketHashScan(guildData, scan, 100)

            assert.is_true(done)
            assert.same({}, scan.buckets)
        end)

        it("covers money records as well as items", function()
            addRecord("deposit|A|100|1|1|472222:0", 1700000000)
            addMoney("withdrawal|M|500|1|1|472240:0", 1700200000)
            local expected = GBL:ComputeBucketHashes(guildData)
            GBL:ResetHashCache()

            local scan = runScan(1)

            assert.same(expected, scan.buckets)
            assert.is_not_nil(scan.buckets[math.floor(472240 / 6)])
        end)
    end)
end)
