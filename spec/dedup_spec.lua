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

        it("adjacent hour with timestamps >= 3600 apart is NOT duplicate", function()
            -- Genuinely different events: same player, same item, same count,
            -- but in consecutive hours scanned by the same client (diff = exactly 3600)
            local rec1 = itemRecord({ timestamp = 3600 * 100 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("adjacent hour with timestamps < 3600 apart IS duplicate", function()
            -- Same event scanned across hour boundary by different clients
            local rec1 = itemRecord({ timestamp = 3600 * 100 + 2700 })  -- hour 100, min 45
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 101 + 900 })   -- hour 101, min 15
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            -- diff = 1800 < 3600 → same event

            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("prevents money record false positive in adjacent hours", function()
            -- Same player repairs for the same amount in consecutive hours
            local rec1 = moneyRecord({ type = "repair", amount = 500000, timestamp = 3600 * 100 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = moneyRecord({ type = "repair", amount = 500000, timestamp = 3600 * 101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            -- diff = 3600, NOT < 3600 → genuinely different repair

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("legacy storedTs=0 falls back to match (backward compat)", function()
            -- Old records stored with timestamp 0 should still be treated as dups
            local rec = itemRecord({ timestamp = 3600 * 100 })
            rec._occurrence = 0
            local key = "withdraw|Thrall|12345|5|1|100:0"
            guildData.seenTxHashes[key] = 0  -- legacy: no timestamp stored

            local rec2 = itemRecord({ timestamp = 3600 * 101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("table-format stored entry uses embedded timestamp", function()
            -- Old table format: { count = N, timestamp = T }
            local rec1Ts = 3600 * 100 + 2700
            local key = "withdraw|Thrall|12345|5|1|100:0"
            guildData.seenTxHashes[key] = { count = 1, timestamp = rec1Ts }

            -- Close enough → duplicate
            local rec2 = itemRecord({ timestamp = 3600 * 101 + 900 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            assert.is_true(GBL:IsDuplicate(rec2, guildData))

            -- Too far → not duplicate
            local rec3 = itemRecord({ timestamp = 3600 * 101 + 2700 })
            rec3._occurrence = 0
            rec3.id = rec3.id .. ":0"
            assert.is_false(GBL:IsDuplicate(rec3, guildData))
        end)

        -- Return value tests for ID normalization support
        it("returns matched key on fuzzy match", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime + 3000 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = baseTime + 4500 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            local isDup, matchedKey = GBL:IsDuplicate(rec2, guildData)
            assert.is_true(isDup)
            assert.is_not_nil(matchedKey)
            assert.equals(rec1.id, matchedKey)
        end)

        it("returns nil key on exact match", function()
            local rec = itemRecord({})
            rec.id = rec.id .. ":0"
            rec._occurrence = 0
            GBL:MarkSeen(rec.id, rec.timestamp, guildData)

            local isDup, matchedKey = GBL:IsDuplicate(rec, guildData)
            assert.is_true(isDup)
            assert.is_nil(matchedKey)
        end)

        it("returns false and nil on no match", function()
            local rec1 = itemRecord({ player = "Thrall" })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ player = "Jaina", timestamp = 3600 * 200 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            local isDup, matchedKey = GBL:IsDuplicate(rec2, guildData)
            assert.is_false(isDup)
            assert.is_nil(matchedKey)
        end)

        it("returns matched key with legacy table-format entry", function()
            local baseTime = 3600 * 100
            local rec1 = itemRecord({ timestamp = baseTime + 3000 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            -- Store as legacy table format
            guildData.seenTxHashes[rec1.id] = { timestamp = rec1.timestamp, count = 1 }

            local rec2 = itemRecord({ timestamp = baseTime + 4500 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            local isDup, matchedKey = GBL:IsDuplicate(rec2, guildData)
            assert.is_true(isDup)
            assert.equals(rec1.id, matchedKey)
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

    ---------------------------------------------------------------------------
    -- Per-slot occurrence counting (v0.14.0)
    -- Counter scope: per baseHash (prefix + timeSlot), not per prefix alone.
    -- Records in different hour slots have independent counters, preventing
    -- occurrence index shift when new same-prefix records appear between rescans.
    ---------------------------------------------------------------------------

    describe("per-slot occurrence counting", function()
        it("counts independently per hour slot", function()
            -- Two records with same prefix but different timeSlots
            -- Each slot has its own counter — both get :0
            local rec1 = itemRecord({ timestamp = 3600 * 100 })
            local rec2 = itemRecord({ timestamp = 3600 * 101 })

            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":0$"))
            assert.equals(0, rec1._occurrence)
            assert.equals(0, rec2._occurrence)
        end)

        it("prevents false-positive dedup for adjacent-hour same-prefix events", function()
            -- Two genuinely different events, same prefix, adjacent hours.
            -- Both get :0 (per-slot counting), but IsDuplicate's < 3600
            -- timestamp check correctly separates them (diff == exactly 3600).
            local rec1 = itemRecord({ timestamp = 3600 * 100 })
            local rec2 = itemRecord({ timestamp = 3600 * 101 })
            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            -- Both should get :0 (independent per-slot counters)
            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":0$"))

            -- Store first
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            -- Second event should NOT be a duplicate
            -- (same occurrence :0, adjacent slot probed, but |diff| == 3600 >= 3600)
            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("same-hour duplicates still dedup correctly", function()
            -- Two identical records in the same hour still get :0 and :1
            local rec1 = itemRecord({ timestamp = 3600 * 100 })
            local rec2 = itemRecord({ timestamp = 3600 * 100 })

            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":1$"))

            -- Store both, then re-scan — both should dedup
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)
            GBL:MarkSeen(rec2.id, rec2.timestamp, guildData)

            local rescan1 = itemRecord({ timestamp = 3600 * 100 })
            local rescan2 = itemRecord({ timestamp = 3600 * 100 })
            GBL:AssignOccurrenceIndices({ rescan1, rescan2 })

            assert.is_true(GBL:IsDuplicate(rescan1, guildData))
            assert.is_true(GBL:IsDuplicate(rescan2, guildData))
        end)

        it("rescan with new same-prefix record does not shift old occurrence", function()
            -- Core regression test: adding a new same-prefix record in a
            -- different slot must NOT shift the old record's occurrence index.
            -- This was the bug that caused duplicate breastplate entries.

            -- Scan 1: one breastplate withdrawal in slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 100 }) }
            GBL:AssignOccurrenceIndices(batch1)
            GBL:MarkSeen(batch1[1].id, batch1[1].timestamp, guildData)
            -- Stored as prefix|100:0

            -- Scan 2: new breastplate in slot 102, old one still present
            -- (API returns newest first)
            local newTx = itemRecord({ timestamp = 3600 * 102 })
            local oldTx = itemRecord({ timestamp = 3600 * 100 })
            local batch2 = { newTx, oldTx }
            GBL:AssignOccurrenceIndices(batch2)

            -- Per-slot: each slot has its own counter, both get :0
            assert.is_truthy(newTx.id:find(":0$"))
            assert.is_truthy(oldTx.id:find(":0$"))

            -- Old tx should dedup (same ID as stored)
            assert.is_true(GBL:IsDuplicate(oldTx, guildData))
            -- New tx should NOT dedup
            assert.is_false(GBL:IsDuplicate(newTx, guildData))
        end)

        it("batch growth with adjacent-hour record preserves old dedup", function()
            -- Two same-slot records stored, then a new different-slot record
            -- appears — old records must still dedup.
            local batch1 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            GBL:AssignOccurrenceIndices(batch1)
            for _, r in ipairs(batch1) do
                GBL:MarkSeen(r.id, r.timestamp, guildData)
            end
            -- Stored: prefix|100:0, prefix|100:1

            -- Rescan with new record in slot 101 prepended
            local newTx = itemRecord({ timestamp = 3600 * 101 })
            local old1 = itemRecord({ timestamp = 3600 * 100 })
            local old2 = itemRecord({ timestamp = 3600 * 100 })
            local batch2 = { newTx, old1, old2 }
            GBL:AssignOccurrenceIndices(batch2)

            -- Old records keep :0 and :1 (same slot, same counter)
            assert.is_true(GBL:IsDuplicate(old1, guildData))
            assert.is_true(GBL:IsDuplicate(old2, guildData))
            -- New record is genuinely new
            assert.is_false(GBL:IsDuplicate(newTx, guildData))
        end)

        it("adjacent-hour events both get :0 but IsDuplicate separates via timestamp", function()
            -- Explicitly verifies the < 3600 timestamp guard prevents
            -- false dedup when both records have occurrence :0
            local rec1 = itemRecord({ timestamp = 3600 * 100 })
            local rec2 = itemRecord({ timestamp = 3600 * 101 })
            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            assert.equals(0, rec1._occurrence)
            assert.equals(0, rec2._occurrence)

            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            -- rec2 has same :0 occurrence and adjacent slot — will be found in probe
            -- but diff = 3600 (NOT < 3600), so NOT a duplicate
            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("same event near hour boundary deduped by timestamp proximity", function()
            -- Same event scanned at different times: minute 50 of hour 100
            -- and minute 10 of hour 101 (diff = 1200s < 3600 → same event)
            local rec1 = itemRecord({ timestamp = 3600 * 100 + 3000 })
            GBL:AssignOccurrenceIndices({ rec1 })
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 101 + 600 })
            GBL:AssignOccurrenceIndices({ rec2 })  -- separate batch (different scan)

            assert.equals(0, rec1._occurrence)
            assert.equals(0, rec2._occurrence)

            -- diff = 600 < 3600 → same event → duplicate
            assert.is_true(GBL:IsDuplicate(rec2, guildData))
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
