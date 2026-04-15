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

        -- Mimic AceDB wildcard metatable for playerStats auto-vivification
        local statsDefaults = {
            withdrawals = {},
            deposits = {},
            totalWithdrawCount = 0,
            totalDepositCount = 0,
            moneyWithdrawn = 0,
            moneyDeposited = 0,
            firstSeen = 0,
            lastSeen = 0,
        }
        local playerStatsMT = {
            __index = function(t, k)
                local new = {}
                for dk, dv in pairs(statsDefaults) do
                    new[dk] = type(dv) == "table" and {} or dv
                end
                t[k] = new
                return new
            end,
        }
        guildData = {
            seenTxHashes = {},
            transactions = {},
            moneyTransactions = {},
            playerStats = setmetatable({}, playerStatsMT),
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

    describe("SplitBaseHash", function()
        it("extracts prefix and slot from item baseHash", function()
            local prefix, slot = GBL:SplitBaseHash("withdraw|Thrall|12345|5|1|100")
            assert.equals("withdraw|Thrall|12345|5|1|", prefix)
            assert.equals(100, slot)
        end)

        it("extracts prefix and slot from money baseHash", function()
            local prefix, slot = GBL:SplitBaseHash("deposit|Thrall|50000|100")
            assert.equals("deposit|Thrall|50000|", prefix)
            assert.equals(100, slot)
        end)

        it("returns nil for nil input", function()
            local prefix, slot = GBL:SplitBaseHash(nil)
            assert.is_nil(prefix)
            assert.is_nil(slot)
        end)
    end)

    describe("CountStoredAtSlot", function()
        it("counts sequential occurrences", function()
            guildData.seenTxHashes["BH:0"] = 100
            guildData.seenTxHashes["BH:1"] = 100
            guildData.seenTxHashes["BH:2"] = 100
            assert.equals(3, GBL:CountStoredAtSlot("BH", guildData))
        end)

        it("returns 0 for no stored entries", function()
            assert.equals(0, GBL:CountStoredAtSlot("BH", guildData))
        end)

        it("stops at gaps", function()
            guildData.seenTxHashes["BH:0"] = 100
            guildData.seenTxHashes["BH:2"] = 100  -- gap at :1
            assert.equals(1, GBL:CountStoredAtSlot("BH", guildData))
        end)
    end)

    describe("CountStoredForHash", function()
        it("finds exact-slot matches first", function()
            local baseHash = "withdraw|Thrall|12345|5|1|100"
            guildData.seenTxHashes[baseHash .. ":0"] = 3600 * 100
            guildData.seenTxHashes[baseHash .. ":1"] = 3600 * 100
            assert.equals(2, GBL:CountStoredForHash(baseHash, 3600 * 100, guildData))
        end)

        it("finds adjacent-slot matches with timestamp proximity", function()
            -- Stored at slot 100, querying for slot 101 (hour boundary drift)
            local storedHash = "withdraw|Thrall|12345|5|1|100"
            local queryHash = "withdraw|Thrall|12345|5|1|101"
            guildData.seenTxHashes[storedHash .. ":0"] = 3600 * 100 + 3000
            -- diff = |3600*101 - (3600*100 + 3000)| = |600| < 3600
            assert.equals(1, GBL:CountStoredForHash(queryHash, 3600 * 101, guildData))
        end)

        it("rejects adjacent-slot matches with distant timestamps", function()
            -- Stored at slot 99, querying for slot 100 with distant timestamp
            local storedHash = "withdraw|Thrall|12345|5|1|99"
            local queryHash = "withdraw|Thrall|12345|5|1|100"
            guildData.seenTxHashes[storedHash .. ":0"] = 3600 * 99
            -- diff = |3600*100 + 1800 - 3600*99| = 5400 >= 3600
            assert.equals(0, GBL:CountStoredForHash(queryHash, 3600 * 100 + 1800, guildData))
        end)
    end)

    describe("MaxOccurrenceAtSlot", function()
        it("returns 0 for empty seenTxHashes", function()
            assert.equals(0, GBL:MaxOccurrenceAtSlot("BH", guildData))
        end)

        it("returns next index for sequential entries", function()
            guildData.seenTxHashes["BH:0"] = 100
            guildData.seenTxHashes["BH:1"] = 100
            assert.equals(2, GBL:MaxOccurrenceAtSlot("BH", guildData))
        end)

        it("scans past gaps to find true max", function()
            guildData.seenTxHashes["BH:0"] = 100
            -- gap at :1
            guildData.seenTxHashes["BH:2"] = 100
            assert.equals(3, GBL:MaxOccurrenceAtSlot("BH", guildData))
        end)

        it("handles large gap after normalization", function()
            guildData.seenTxHashes["BH:0"] = 100
            guildData.seenTxHashes["BH:5"] = 100
            assert.equals(6, GBL:MaxOccurrenceAtSlot("BH", guildData))
        end)
    end)

    describe("BuildStoredRecordIndex", function()
        it("indexes records by prefix and slot", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 100,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 100 + 1000,  -- same slot
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(2, index["withdraw|Thrall|12345|5|1|"][100])
        end)

        it("tracks different slots independently", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 100,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 102,  -- different slot
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][100])
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][102])
        end)

        it("indexes nil timestamp at slot 0", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = nil,
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][0])
        end)

        it("indexes zero timestamp at slot 0", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0,
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][0])
        end)
    end)

    describe("CountFromRecordIndex", function()
        it("sums exact and both adjacent slots", function()
            local index = {
                ["withdraw|Thrall|12345|5|1|"] = {
                    [99] = 1,
                    [101] = 1,
                },
            }
            -- Querying slot 100: should find slot 99 (1) + slot 101 (1) = 2
            assert.equals(2, GBL:CountFromRecordIndex(
                index, "withdraw|Thrall|12345|5|1|100"))
        end)

        it("includes exact slot in sum", function()
            local index = {
                ["withdraw|Thrall|12345|5|1|"] = {
                    [100] = 2,
                    [101] = 1,
                },
            }
            assert.equals(3, GBL:CountFromRecordIndex(
                index, "withdraw|Thrall|12345|5|1|100"))
        end)

        it("returns 0 for unknown prefix", function()
            local index = {}
            assert.equals(0, GBL:CountFromRecordIndex(
                index, "withdraw|Thrall|12345|5|1|100"))
        end)
    end)

    describe("FindDriftedCount", function()
        it("finds count at adjacent slot", function()
            local prevCounts = { ["withdraw|Thrall|12345|5|1|100"] = 3 }
            assert.equals(3, GBL:FindDriftedCount("withdraw|Thrall|12345|5|1|101", prevCounts))
        end)

        it("returns 0 when no adjacent match", function()
            local prevCounts = { ["withdraw|Thrall|12345|5|1|100"] = 3 }
            assert.equals(0, GBL:FindDriftedCount("withdraw|Thrall|12345|5|1|103", prevCounts))
        end)

        it("sums both adjacent slots", function()
            local prevCounts = {
                ["withdraw|Thrall|12345|5|1|99"] = 2,
                ["withdraw|Thrall|12345|5|1|101"] = 1,
            }
            assert.equals(3, GBL:FindDriftedCount("withdraw|Thrall|12345|5|1|100", prevCounts))
        end)
    end)

    describe("StoreBatchRecords", function()
        it("stores all records on initial scan (no prevCounts)", function()
            local r1 = itemRecord({ timestamp = 3600 * 100, player = "Thrall" })
            local r2 = itemRecord({ timestamp = 3600 * 100, player = "Jaina" })
            local batch = { r1, r2 }

            local stored, counts = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            assert.equals(2, stored)
            assert.equals(2, #guildData.transactions)
        end)

        it("deduplicates on initial scan against stored records", function()
            -- Pre-populate records array and seenTxHashes (from a previous session)
            local rec = itemRecord({ timestamp = 3600 * 100 })
            local baseHash = rec.id
            rec._occurrence = 0
            rec.id = baseHash .. ":0"
            table.insert(guildData.transactions, rec)
            guildData.seenTxHashes[rec.id] = 3600 * 100

            -- Batch with 1 record matching the stored one
            local batch = { itemRecord({ timestamp = 3600 * 100 }) }

            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        it("rescan with same batch produces 0 new records", function()
            -- Initial scan
            local batch1 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 101, player = "Jaina" }),
            }
            local stored1, prevCounts = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)
            assert.equals(2, stored1)

            -- Rescan with identical batch
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 101, player = "Jaina" }),
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prevCounts)
            assert.equals(0, stored2)
        end)

        -- CORE REGRESSION TEST: the bug v0.14.0 failed to fix
        it("rescan with new same-SLOT record does not create duplicates", function()
            -- Scan 1: 1 record at slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 100 }) }
            local stored1, prevCounts = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)
            assert.equals(1, stored1)
            assert.equals(1, #guildData.transactions)

            -- Rescan: 2 records at slot 100 (new one prepended by WoW API)
            -- Both have identical baseHashes — indistinguishable except by count
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100 }),  -- new (WoW puts newest first)
                itemRecord({ timestamp = 3600 * 100 }),  -- old
            }
            local stored2, prevCounts2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prevCounts)

            -- Should store exactly 1 new record (2 in batch - 1 previously known)
            assert.equals(1, stored2)
            assert.equals(2, #guildData.transactions)

            -- Verify occurrence indices are sequential
            assert.is_truthy(guildData.transactions[1].id:find(":0$"))
            assert.is_truthy(guildData.transactions[2].id:find(":1$"))

            -- Third rescan with same 2 records: 0 new
            local batch3 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored3 = GBL:StoreBatchRecords(
                batch3, guildData, "transactions", prevCounts2)
            assert.equals(0, stored3)
            assert.equals(2, #guildData.transactions)
        end)

        it("multiple rescans accumulate correctly", function()
            -- Scan 1: 1 record
            local batch1 = { itemRecord({ timestamp = 3600 * 100 }) }
            local _, prev1 = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)

            -- Rescan 2: 2 records (1 new)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored2, prev2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prev1)
            assert.equals(1, stored2)

            -- Rescan 3: 3 records (1 more new)
            local batch3 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored3 = GBL:StoreBatchRecords(
                batch3, guildData, "transactions", prev2)
            assert.equals(1, stored3)

            assert.equals(3, #guildData.transactions)
        end)

        it("handles hour-boundary drift during rescan", function()
            -- Scan 1: record at slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 100 + 3500 }) }
            local _, prev = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)

            -- Rescan: hour rolled over, same record now computes to slot 101
            local batch2 = { itemRecord({ timestamp = 3600 * 101 + 100 }) }
            -- prevCounts has slot 100, current batch has slot 101
            -- FindDriftedCount should match via adjacent slot
            local stored = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prev)
            assert.equals(0, stored)
            assert.equals(1, #guildData.transactions)
        end)

        it("handles mixed baseHashes in one batch", function()
            -- 2 different items in same batch
            local batch = {
                itemRecord({ timestamp = 3600 * 100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 100, itemID = 222 }),
                itemRecord({ timestamp = 3600 * 100, itemID = 111 }),  -- second of same item
            }
            local stored, prev = GBL:StoreBatchRecords(
                batch, guildData, "transactions", nil)
            assert.equals(3, stored)

            -- Rescan: 1 more of item 111
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 100, itemID = 222 }),
                itemRecord({ timestamp = 3600 * 100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 100, itemID = 111 }),  -- new
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prev)
            assert.equals(1, stored2)
            assert.equals(4, #guildData.transactions)
        end)

        it("works with money transactions", function()
            local r1 = moneyRecord({ timestamp = 3600 * 100 })
            local batch = { r1 }
            local stored, prev = GBL:StoreBatchRecords(
                batch, guildData, "moneyTransactions", nil)
            assert.equals(1, stored)
            assert.equals(1, #guildData.moneyTransactions)

            -- Rescan with new money record prepended
            local batch2 = {
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "moneyTransactions", prev)
            assert.equals(1, stored2)
            assert.equals(2, #guildData.moneyTransactions)
        end)

        it("validates records before storing", function()
            local bad = { type = "", player = "", timestamp = 3600 * 100, itemID = 1, count = 1, tab = 1 }
            bad.id = GBL:ComputeTxHash(bad)
            local batch = { bad }

            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        -- REGRESSION (money): sync normalization gap
        it("does not duplicate money records when seenTxHashes has gaps", function()
            local baseHash = "deposit|Thrall|50000|100"
            for occ = 0, 2 do
                local rec = moneyRecord({ timestamp = 3600 * 100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.moneyTransactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end
            -- Gap: normalization removed :1, added slot 101
            guildData.seenTxHashes[baseHash .. ":1"] = nil
            guildData.seenTxHashes["deposit|Thrall|50000|101:0"] = 3600 * 101

            local batch = {
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(0, stored)
            assert.equals(3, #guildData.moneyTransactions)
        end)

        -- REGRESSION (money): records split across adjacent slots
        it("does not duplicate money records split across adjacent slots", function()
            local rec99 = moneyRecord({ timestamp = 3600 * 99 + 3500 })
            rec99._occurrence = 0
            rec99.id = "deposit|Thrall|50000|99:0"
            table.insert(guildData.moneyTransactions, rec99)
            guildData.seenTxHashes[rec99.id] = rec99.timestamp

            local rec101 = moneyRecord({ timestamp = 3600 * 101 + 100 })
            rec101._occurrence = 0
            rec101.id = "deposit|Thrall|50000|101:0"
            table.insert(guildData.moneyTransactions, rec101)
            guildData.seenTxHashes[rec101.id] = rec101.timestamp

            local batch = {
                moneyRecord({ timestamp = 3600 * 100 + 500 }),
                moneyRecord({ timestamp = 3600 * 100 + 500 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(0, stored)
            assert.equals(2, #guildData.moneyTransactions)
        end)

        -- REGRESSION (money): occurrence assignment past gaps
        it("assigns money occurrence past gaps", function()
            local baseHash = "deposit|Thrall|50000|100"
            for _, occ in ipairs({0, 2}) do
                local rec = moneyRecord({ timestamp = 3600 * 100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.moneyTransactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end

            local batch = {
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(1, stored)
            assert.equals(3, #guildData.moneyTransactions)
            assert.is_truthy(guildData.moneyTransactions[3].id:find(":3$"))
        end)

        -- REGRESSION: sync normalization creates gaps in seenTxHashes
        it("does not duplicate when seenTxHashes has gaps from normalization", function()
            -- Simulate: 3 records stored at slot 100 with sequential indices
            local baseHash = "withdraw|Thrall|12345|5|1|100"
            for occ = 0, 2 do
                local rec = itemRecord({ timestamp = 3600 * 100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.transactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end
            assert.equals(3, #guildData.transactions)

            -- Simulate sync normalization: :1 moved to different slot, creating gap
            guildData.seenTxHashes[baseHash .. ":1"] = nil
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|101:0"] = 3600 * 101

            -- Bank reopen: initial scan with 3 records (same events)
            local batch = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            -- Must not create duplicates: records array already has 3
            assert.equals(0, stored)
            assert.equals(3, #guildData.transactions)
        end)

        -- Verifies WHY the gap fix works: BuildStoredRecordIndex counts from
        -- the records array (ground truth) rather than seenTxHashes (has gaps).
        it("BuildStoredRecordIndex counts correctly despite seenTxHashes gaps", function()
            local baseHash = "withdraw|Thrall|12345|5|1|100"
            for occ = 0, 2 do
                local rec = itemRecord({ timestamp = 3600 * 100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.transactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end

            -- Create gap in seenTxHashes (simulating sync normalization)
            guildData.seenTxHashes[baseHash .. ":1"] = nil

            -- seenTxHashes would undercount (CountStoredAtSlot stops at gap)
            assert.equals(1, GBL:CountStoredAtSlot(baseHash, guildData))

            -- But BuildStoredRecordIndex counts from records array: 3
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(3, GBL:CountFromRecordIndex(index, baseHash))

            -- Therefore StoreBatchRecords stores 0 new (not 2 like the old code)
            local batch = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        -- REGRESSION: records split across both adjacent slots
        it("does not duplicate when records are split across adjacent slots", function()
            -- Simulate: 1 record at slot 99, 1 at slot 101 (from normalization)
            local rec99 = itemRecord({ timestamp = 3600 * 99 + 3500 })
            rec99._occurrence = 0
            rec99.id = "withdraw|Thrall|12345|5|1|99:0"
            table.insert(guildData.transactions, rec99)
            guildData.seenTxHashes[rec99.id] = rec99.timestamp

            local rec101 = itemRecord({ timestamp = 3600 * 101 + 100 })
            rec101._occurrence = 0
            rec101.id = "withdraw|Thrall|12345|5|1|101:0"
            table.insert(guildData.transactions, rec101)
            guildData.seenTxHashes[rec101.id] = rec101.timestamp

            -- Bank reopen: both events now map to slot 100
            local batch = {
                itemRecord({ timestamp = 3600 * 100 + 500 }),
                itemRecord({ timestamp = 3600 * 100 + 500 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            -- Records array already has 2 → 0 new
            assert.equals(0, stored)
            assert.equals(2, #guildData.transactions)
        end)

        -- REGRESSION: occurrence assignment must not collide with existing IDs
        it("assigns occurrence past gaps when storing new records", function()
            -- Stored: :0 and :2 exist (gap at :1 from normalization)
            local baseHash = "withdraw|Thrall|12345|5|1|100"
            for _, occ in ipairs({0, 2}) do
                local rec = itemRecord({ timestamp = 3600 * 100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.transactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end

            -- New batch with 3 records (1 new beyond the 2 stored)
            local batch = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            assert.equals(1, stored)
            assert.equals(3, #guildData.transactions)
            -- New record should get :3 (past the gap), not :1 (which would be wrong)
            -- or :2 (which would collide)
            assert.is_truthy(guildData.transactions[3].id:find(":3$"))
        end)
    end)

    describe("eventCounts persistence", function()
        it("initial scan persists count per baseHash", function()
            -- Two records with the same prefix+hour
            local batch = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|100"
            assert.is_not_nil(guildData.eventCounts)
            assert.is_not_nil(guildData.eventCounts[baseHash])
            assert.equals(2, guildData.eventCounts[baseHash].count)
            assert.equals(Helpers.MockWoW.serverTime, guildData.eventCounts[baseHash].asOf)
        end)

        it("rescan updates count upward", function()
            -- Initial: 2 records
            local batch1 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local _, prevCounts = GBL:StoreBatchRecords(batch1, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|100"
            assert.equals(2, guildData.eventCounts[baseHash].count)

            -- Rescan: now 3 records (new event happened)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            GBL:StoreBatchRecords(batch2, guildData, "transactions", prevCounts)

            assert.equals(3, guildData.eventCounts[baseHash].count)
        end)

        it("count never decreases on rescan (aged out events)", function()
            -- Initial: 3 records
            local batch1 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            local _, prevCounts = GBL:StoreBatchRecords(batch1, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|100"
            assert.equals(3, guildData.eventCounts[baseHash].count)

            -- Rescan: now only 2 records (1 aged out of API)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 100 }),
                itemRecord({ timestamp = 3600 * 100 }),
            }
            GBL:StoreBatchRecords(batch2, guildData, "transactions", prevCounts)

            -- Count must not decrease
            assert.equals(3, guildData.eventCounts[baseHash].count)
        end)

        it("multiple prefixes get independent counts", function()
            local batch = {
                itemRecord({ timestamp = 3600 * 100, player = "Thrall" }),
                itemRecord({ timestamp = 3600 * 100, player = "Thrall" }),
                itemRecord({ timestamp = 3600 * 100, player = "Jaina", itemID = 99999 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            local hash1 = "withdraw|Thrall|12345|5|1|100"
            local hash2 = "withdraw|Jaina|99999|5|1|100"
            assert.equals(2, guildData.eventCounts[hash1].count)
            assert.equals(1, guildData.eventCounts[hash2].count)
        end)

        it("works with money transactions", function()
            local batch = {
                moneyRecord({ timestamp = 3600 * 100 }),
                moneyRecord({ timestamp = 3600 * 100 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)

            local baseHash = "deposit|Thrall|50000|100"
            assert.is_not_nil(guildData.eventCounts[baseHash])
            assert.equals(2, guildData.eventCounts[baseHash].count)
        end)

        it("does not create entry for empty batch", function()
            GBL:StoreBatchRecords({}, guildData, "transactions", nil)
            -- eventCounts table created but empty
            assert.is_not_nil(guildData.eventCounts)
            local count = 0
            for _ in pairs(guildData.eventCounts) do count = count + 1 end
            assert.equals(0, count)
        end)
    end)

    describe("PruneEventCounts", function()
        it("removes old entries and preserves recent", function()
            local now = Helpers.MockWoW.serverTime
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 2, asOf = now - (91 * 86400) },
                ["withdraw|Jaina|99999|5|1|200"] = { count = 1, asOf = now - (10 * 86400) },
            }
            GBL:PruneEventCounts(90, guildData)

            assert.is_nil(guildData.eventCounts["withdraw|Thrall|12345|5|1|100"])
            assert.is_not_nil(guildData.eventCounts["withdraw|Jaina|99999|5|1|200"])
        end)

        it("handles corrupted entries (non-table)", function()
            local now = Helpers.MockWoW.serverTime
            guildData.eventCounts = {
                ["bad_entry"] = "garbage",
                ["good_entry"] = { count = 1, asOf = now },
            }
            GBL:PruneEventCounts(90, guildData)

            assert.is_nil(guildData.eventCounts["bad_entry"])
            assert.is_not_nil(guildData.eventCounts["good_entry"])
        end)

        it("uses default 90 days when nil passed", function()
            local now = Helpers.MockWoW.serverTime
            guildData.eventCounts = {
                ["old"] = { count = 1, asOf = now - (91 * 86400) },
                ["recent"] = { count = 1, asOf = now - (89 * 86400) },
            }
            GBL:PruneEventCounts(nil, guildData)

            assert.is_nil(guildData.eventCounts["old"])
            assert.is_not_nil(guildData.eventCounts["recent"])
        end)

        it("handles nil guildData gracefully", function()
            -- Should not error
            GBL:PruneEventCounts(90, nil)
            GBL:PruneEventCounts(90, {})
        end)
    end)

    describe("CollectEventCountsForBuckets", function()
        it("returns all when no filter provided", function()
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 2, asOf = 1000 },
                ["deposit|Jaina|99999|5|2|200"] = { count = 1, asOf = 2000 },
            }
            local result = GBL:CollectEventCountsForBuckets(guildData, nil)
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            assert.equals(2, count)
        end)

        it("filters by 6-hour bucket keys", function()
            -- slot 100 → bucket 16, slot 200 → bucket 33
            guildData.eventCounts = {
                ["withdraw|Thrall|12345|5|1|100"] = { count = 2, asOf = 1000 },
                ["deposit|Jaina|99999|5|2|200"] = { count = 1, asOf = 2000 },
            }
            local diffBuckets = { [16] = true }  -- only bucket 16
            local result = GBL:CollectEventCountsForBuckets(guildData, diffBuckets)

            assert.is_not_nil(result["withdraw|Thrall|12345|5|1|100"])
            assert.is_nil(result["deposit|Jaina|99999|5|2|200"])
        end)

        it("returns empty table when no eventCounts", function()
            local result = GBL:CollectEventCountsForBuckets(guildData, nil)
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            assert.equals(0, count)
        end)

        it("handles nil guildData gracefully", function()
            local result = GBL:CollectEventCountsForBuckets(nil, nil)
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            assert.equals(0, count)
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
