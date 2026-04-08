--- dedup_spec.lua — Tests for Dedup module

local Helpers = require("spec.helpers")

describe("Dedup", function()
    local GBL
    local guildData

    before_each(function()
        Helpers.setupMocks()
        Helpers.MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()

        guildData = {
            seenTxHashes = {},
            transactions = {},
            moneyTransactions = {},
        }
    end)

    -- Helper: create a minimal item tx record
    local function itemRecord(opts)
        local rec = {
            type = opts.type or "withdraw",
            player = opts.player or "Thrall",
            itemID = opts.itemID or 12345,
            count = opts.count or 5,
            tab = opts.tab or 1,
            timestamp = opts.timestamp or Helpers.MockWoW.serverTime,
        }
        rec.id = GBL:ComputeTxHash(rec)
        return rec
    end

    -- Helper: create a minimal money tx record
    local function moneyRecord(opts)
        local rec = {
            type = opts.type or "deposit",
            player = opts.player or "Thrall",
            amount = opts.amount or 50000,
            timestamp = opts.timestamp or Helpers.MockWoW.serverTime,
        }
        rec.id = GBL:ComputeTxHash(rec)
        return rec
    end

    describe("ComputeTxHash", function()
        it("produces a deterministic hash for item transactions", function()
            local rec = itemRecord({})
            local hash1 = GBL:ComputeTxHash(rec)
            local hash2 = GBL:ComputeTxHash(rec)
            assert.equals(hash1, hash2)
            assert.is_string(hash1)
            assert.is_truthy(hash1:find("withdraw|Thrall|12345|5|1|"))
        end)

        it("produces a deterministic hash for money transactions", function()
            local rec = moneyRecord({})
            local hash = GBL:ComputeTxHash(rec)
            assert.is_truthy(hash:find("deposit|Thrall|50000|"))
        end)
    end)

    describe("IsDuplicate", function()
        it("detects identical transaction as duplicate", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            assert.is_true(GBL:IsDuplicate(rec, guildData))
        end)

        it("detects 30-min drift in same hour bucket as duplicate", function()
            local baseTime = 3600 * 100  -- exactly on an hour boundary
            local rec1 = itemRecord({ timestamp = baseTime + 600 })   -- :10
            local rec2 = itemRecord({ timestamp = baseTime + 2400 })  -- :40

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            -- rec2 is in the same hour bucket, should be duplicate
            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("detects 45-min drift across adjacent hour bucket as duplicate", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime + 3000 })  -- :50 in hour 100
            local rec2 = itemRecord({ timestamp = baseTime + 4500 })  -- :15 in hour 101

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            -- rec2 is in adjacent hour bucket, should be caught by 3-slot check
            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("does NOT detect 2-hour drift as duplicate", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime })
            local rec2 = itemRecord({ timestamp = baseTime + 7200 })  -- 2 hours later

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different player is not duplicate", function()
            local rec1 = itemRecord({ player = "Thrall" })
            local rec2 = itemRecord({ player = "Jaina" })

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different item is not duplicate", function()
            local rec1 = itemRecord({ itemID = 12345 })
            local rec2 = itemRecord({ itemID = 67890 })

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different count is not duplicate", function()
            local rec1 = itemRecord({ count = 5 })
            local rec2 = itemRecord({ count = 10 })

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different tab is not duplicate", function()
            local rec1 = itemRecord({ tab = 1 })
            local rec2 = itemRecord({ tab = 2 })

            local hash = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash, rec1.timestamp, guildData)

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)
    end)

    describe("MarkSeen", function()
        it("stores hash with count 1 on first call", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            local entry = guildData.seenTxHashes[hash]
            assert.equals(1, entry.count)
            assert.equals(rec.timestamp, entry.timestamp)
        end)

        it("increments count on subsequent calls", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            GBL:MarkSeen(hash, rec.timestamp, guildData)
            GBL:MarkSeen(hash, rec.timestamp, guildData)
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            local entry = guildData.seenTxHashes[hash]
            assert.equals(3, entry.count)
        end)

        it("migrates old number format to table", function()
            local hash = "old|format|hash"
            local oldTimestamp = 1000000
            guildData.seenTxHashes[hash] = oldTimestamp  -- old format

            GBL:MarkSeen(hash, 2000000, guildData)

            local entry = guildData.seenTxHashes[hash]
            assert.equals(2, entry.count)
            assert.equals(2000000, entry.timestamp)
        end)
    end)

    describe("GetSeenCount", function()
        it("returns 0 for unseen record", function()
            local rec = itemRecord({})
            assert.equals(0, GBL:GetSeenCount(rec, guildData))
        end)

        it("returns count for seen record", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            GBL:MarkSeen(hash, rec.timestamp, guildData)
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            assert.equals(2, GBL:GetSeenCount(rec, guildData))
        end)

        it("counts across adjacent hour slots", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime + 3500 })  -- end of hour 100
            local rec2 = itemRecord({ timestamp = baseTime + 3700 })  -- start of hour 101

            local hash1 = GBL:ComputeTxHash(rec1)
            GBL:MarkSeen(hash1, rec1.timestamp, guildData)

            -- rec2 is in adjacent slot, should see count from rec1
            assert.equals(1, GBL:GetSeenCount(rec2, guildData))
        end)

        it("handles old number format", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            guildData.seenTxHashes[hash] = rec.timestamp  -- old format

            assert.equals(1, GBL:GetSeenCount(rec, guildData))
        end)
    end)

    describe("FilterNewRecords", function()
        it("returns all records when none seen before", function()
            local rec1 = itemRecord({ player = "Thrall" })
            local rec2 = itemRecord({ player = "Jaina" })

            local result = GBL:FilterNewRecords({ rec1, rec2 }, guildData)
            assert.equals(2, #result)
        end)

        it("returns no records when all already seen", function()
            local rec = itemRecord({})
            GBL:MarkSeen(rec.id, rec.timestamp, guildData)

            local result = GBL:FilterNewRecords({ rec }, guildData)
            assert.equals(0, #result)
        end)

        it("allows duplicate transactions in same batch", function()
            -- Two identical withdrawals in the same hour
            local rec1 = itemRecord({})
            local rec2 = itemRecord({})  -- same hash

            local result = GBL:FilterNewRecords({ rec1, rec2 }, guildData)
            assert.equals(2, #result)
        end)

        it("stores second occurrence when first already seen", function()
            local rec1 = itemRecord({})
            -- First already stored
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            -- Batch has two identical entries
            local batch_a = itemRecord({})
            local batch_b = itemRecord({})

            local result = GBL:FilterNewRecords({ batch_a, batch_b }, guildData)
            -- Stored count is 1, batch count is 2, deficit is 1
            assert.equals(1, #result)
        end)

        it("handles mixed new and seen records", function()
            local seen = itemRecord({ player = "Thrall" })
            GBL:MarkSeen(seen.id, seen.timestamp, guildData)

            local batch = {
                itemRecord({ player = "Thrall" }),  -- already seen
                itemRecord({ player = "Jaina" }),   -- new
            }

            local result = GBL:FilterNewRecords(batch, guildData)
            assert.equals(1, #result)
            assert.equals("Jaina", result[1].player)
        end)

        it("handles triple identical transactions correctly", function()
            -- 1 already stored, batch has 3 identical
            local rec = itemRecord({})
            GBL:MarkSeen(rec.id, rec.timestamp, guildData)

            local batch = { itemRecord({}), itemRecord({}), itemRecord({}) }

            local result = GBL:FilterNewRecords(batch, guildData)
            -- Stored 1, batch has 3, deficit = 2
            assert.equals(2, #result)
        end)
    end)

    describe("PruneSeenHashes", function()
        it("removes old entries and preserves recent", function()
            local now = Helpers.MockWoW.serverTime
            guildData.seenTxHashes["old_hash"] = { count = 1, timestamp = now - (91 * 86400) }
            guildData.seenTxHashes["recent_hash"] = { count = 1, timestamp = now - (10 * 86400) }

            GBL:PruneSeenHashes(90, guildData)

            assert.is_nil(guildData.seenTxHashes["old_hash"])
            assert.is_not_nil(guildData.seenTxHashes["recent_hash"])
        end)

        it("handles old number format during pruning", function()
            local now = Helpers.MockWoW.serverTime
            guildData.seenTxHashes["old_num"] = now - (91 * 86400)  -- old format, old
            guildData.seenTxHashes["recent_num"] = now - (10 * 86400)  -- old format, recent

            GBL:PruneSeenHashes(90, guildData)

            assert.is_nil(guildData.seenTxHashes["old_num"])
            assert.is_not_nil(guildData.seenTxHashes["recent_num"])
        end)
    end)
end)
