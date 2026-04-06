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
        }
    end)

    -- Helper: create a minimal item tx record
    local function itemRecord(opts)
        return {
            type = opts.type or "withdraw",
            player = opts.player or "Thrall",
            itemID = opts.itemID or 12345,
            count = opts.count or 5,
            tab = opts.tab or 1,
            timestamp = opts.timestamp or Helpers.MockWoW.serverTime,
        }
    end

    -- Helper: create a minimal money tx record
    local function moneyRecord(opts)
        return {
            type = opts.type or "deposit",
            player = opts.player or "Thrall",
            amount = opts.amount or 50000,
            timestamp = opts.timestamp or Helpers.MockWoW.serverTime,
        }
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
        it("stores hash with timestamp", function()
            local rec = itemRecord({})
            local hash = GBL:ComputeTxHash(rec)
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            assert.equals(rec.timestamp, guildData.seenTxHashes[hash])
        end)
    end)

    describe("PruneSeenHashes", function()
        it("removes old entries and preserves recent", function()
            local now = Helpers.MockWoW.serverTime
            guildData.seenTxHashes["old_hash"] = now - (91 * 86400)   -- 91 days ago
            guildData.seenTxHashes["recent_hash"] = now - (10 * 86400)  -- 10 days ago

            GBL:PruneSeenHashes(90, guildData)

            assert.is_nil(guildData.seenTxHashes["old_hash"])
            assert.is_not_nil(guildData.seenTxHashes["recent_hash"])
        end)
    end)
end)
