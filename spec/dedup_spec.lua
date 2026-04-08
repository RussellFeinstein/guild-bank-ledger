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
            playerStats = {},
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

    describe("AssignOccurrenceIndices", function()
        it("assigns :0 to unique records", function()
            local rec1 = itemRecord({ player = "Thrall" })
            local rec2 = itemRecord({ player = "Jaina" })

            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":0$"))
        end)

        it("assigns incrementing indices to identical records", function()
            local rec1 = itemRecord({})
            local rec2 = itemRecord({})
            local rec3 = itemRecord({})

            GBL:AssignOccurrenceIndices({ rec1, rec2, rec3 })

            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":1$"))
            assert.is_truthy(rec3.id:find(":2$"))
        end)

        it("tracks occurrences per unique base hash", function()
            local a1 = itemRecord({ player = "Thrall" })
            local b1 = itemRecord({ player = "Jaina" })
            local a2 = itemRecord({ player = "Thrall" })

            GBL:AssignOccurrenceIndices({ a1, b1, a2 })

            assert.is_truthy(a1.id:find(":0$"))
            assert.is_truthy(b1.id:find(":0$"))
            assert.is_truthy(a2.id:find(":1$"))
        end)
    end)

    describe("IsDuplicate", function()
        it("detects identical transaction as duplicate", function()
            local rec = itemRecord({})
            rec.id = rec.id .. ":0"
            rec._occurrence = 0
            GBL:MarkSeen(rec.id, rec.timestamp, guildData)

            assert.is_true(GBL:IsDuplicate(rec, guildData))
        end)

        it("detects adjacent hour slot as duplicate", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime + 3000 })  -- :50 in hour 100
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = baseTime + 4500 })  -- :15 in hour 101
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("does NOT detect 2-hour drift as duplicate", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = baseTime + 7200 })  -- 2 hours later
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different player is not duplicate", function()
            local rec1 = itemRecord({ player = "Thrall" })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ player = "Jaina" })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("different occurrence index is not duplicate", function()
            local rec1 = itemRecord({})
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({})
            rec2._occurrence = 1
            rec2.id = rec2.id .. ":1"

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)
    end)

    describe("MarkSeen", function()
        it("stores hash with timestamp", function()
            local rec = itemRecord({})
            local hash = rec.id .. ":0"
            GBL:MarkSeen(hash, rec.timestamp, guildData)

            assert.equals(rec.timestamp, guildData.seenTxHashes[hash])
        end)
    end)

    describe("duplicate identical transactions", function()
        it("two identical withdrawals both get stored via occurrence indices", function()
            local rec1 = itemRecord({})
            local rec2 = itemRecord({})  -- same fields = same base hash
            local batch = { rec1, rec2 }

            GBL:AssignOccurrenceIndices(batch)

            -- First passes dedup
            assert.is_false(GBL:IsDuplicate(rec1, guildData))
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            -- Second also passes (different occurrence index)
            assert.is_false(GBL:IsDuplicate(rec2, guildData))
            GBL:MarkSeen(rec2.id, rec2.timestamp, guildData)
        end)

        it("re-scan of same batch produces no new stores", function()
            -- First scan
            local batch1 = { itemRecord({}), itemRecord({}) }
            GBL:AssignOccurrenceIndices(batch1)
            for _, r in ipairs(batch1) do
                GBL:MarkSeen(r.id, r.timestamp, guildData)
            end

            -- Re-scan: same entries, same occurrence indices
            local batch2 = { itemRecord({}), itemRecord({}) }
            GBL:AssignOccurrenceIndices(batch2)

            for _, r in ipairs(batch2) do
                assert.is_true(GBL:IsDuplicate(r, guildData))
            end
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

        it("handles table format entries during pruning", function()
            local now = Helpers.MockWoW.serverTime
            guildData.seenTxHashes["old_table"] = { count = 2, timestamp = now - (91 * 86400) }
            guildData.seenTxHashes["recent_table"] = { count = 1, timestamp = now - (10 * 86400) }

            GBL:PruneSeenHashes(90, guildData)

            assert.is_nil(guildData.seenTxHashes["old_table"])
            assert.is_not_nil(guildData.seenTxHashes["recent_table"])
        end)
    end)
end)
