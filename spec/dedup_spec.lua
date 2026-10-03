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
            local baseTime = 3600 * 475100
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
            local baseTime = 3600 * 475100
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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 475101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("adjacent hour with timestamps < 3600 apart IS duplicate", function()
            -- Same event scanned across hour boundary by different clients
            local rec1 = itemRecord({ timestamp = 3600 * 475100 + 2700 })  -- hour 100, min 45
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 475101 + 900 })   -- hour 101, min 15
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            -- diff = 1800 < 3600 → same event

            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("prevents money record false positive in adjacent hours", function()
            -- Same player repairs for the same amount in consecutive hours
            local rec1 = moneyRecord({ type = "repair", amount = 500000, timestamp = 3600 * 475100 })
            rec1._occurrence = 0
            rec1.id = rec1.id .. ":0"
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = moneyRecord({ type = "repair", amount = 500000, timestamp = 3600 * 475101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            -- diff = 3600, NOT < 3600 → genuinely different repair

            assert.is_false(GBL:IsDuplicate(rec2, guildData))
        end)

        it("legacy storedTs=0 falls back to match (backward compat)", function()
            -- Old records stored with timestamp 0 should still be treated as dups
            local rec = itemRecord({ timestamp = 3600 * 475100 })
            rec._occurrence = 0
            local key = "withdraw|Thrall|12345|5|1|475100:0"
            guildData.seenTxHashes[key] = 0  -- legacy: no timestamp stored

            local rec2 = itemRecord({ timestamp = 3600 * 475101 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            assert.is_true(GBL:IsDuplicate(rec2, guildData))
        end)

        it("table-format stored entry uses embedded timestamp", function()
            -- Old table format: { count = N, timestamp = T }
            local rec1Ts = 3600 * 475100 + 2700
            local key = "withdraw|Thrall|12345|5|1|475100:0"
            guildData.seenTxHashes[key] = { count = 1, timestamp = rec1Ts }

            -- Close enough → duplicate
            local rec2 = itemRecord({ timestamp = 3600 * 475101 + 900 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"
            assert.is_true(GBL:IsDuplicate(rec2, guildData))

            -- Too far → not duplicate
            local rec3 = itemRecord({ timestamp = 3600 * 475101 + 2700 })
            rec3._occurrence = 0
            rec3.id = rec3.id .. ":0"
            assert.is_false(GBL:IsDuplicate(rec3, guildData))
        end)

        -- Return value tests for ID normalization support
        it("returns matched key on fuzzy match", function()
            local baseTime = 3600 * 475100
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

            local rec2 = itemRecord({ player = "Jaina", timestamp = 3600 * 475200 })
            rec2._occurrence = 0
            rec2.id = rec2.id .. ":0"

            local isDup, matchedKey = GBL:IsDuplicate(rec2, guildData)
            assert.is_false(isDup)
            assert.is_nil(matchedKey)
        end)

        it("returns matched key with legacy table-format entry", function()
            local baseTime = 3600 * 475100
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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 })
            local rec2 = itemRecord({ timestamp = 3600 * 475101 })

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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 })
            local rec2 = itemRecord({ timestamp = 3600 * 475101 })
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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 })
            local rec2 = itemRecord({ timestamp = 3600 * 475100 })

            GBL:AssignOccurrenceIndices({ rec1, rec2 })

            assert.is_truthy(rec1.id:find(":0$"))
            assert.is_truthy(rec2.id:find(":1$"))

            -- Store both, then re-scan — both should dedup
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)
            GBL:MarkSeen(rec2.id, rec2.timestamp, guildData)

            local rescan1 = itemRecord({ timestamp = 3600 * 475100 })
            local rescan2 = itemRecord({ timestamp = 3600 * 475100 })
            GBL:AssignOccurrenceIndices({ rescan1, rescan2 })

            assert.is_true(GBL:IsDuplicate(rescan1, guildData))
            assert.is_true(GBL:IsDuplicate(rescan2, guildData))
        end)

        it("rescan with new same-prefix record does not shift old occurrence", function()
            -- Core regression test: adding a new same-prefix record in a
            -- different slot must NOT shift the old record's occurrence index.
            -- This was the bug that caused duplicate breastplate entries.

            -- Scan 1: one breastplate withdrawal in slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 475100 }) }
            GBL:AssignOccurrenceIndices(batch1)
            GBL:MarkSeen(batch1[1].id, batch1[1].timestamp, guildData)
            -- Stored as prefix|475100:0

            -- Scan 2: new breastplate in slot 102, old one still present
            -- (API returns newest first)
            local newTx = itemRecord({ timestamp = 3600 * 475102 })
            local oldTx = itemRecord({ timestamp = 3600 * 475100 })
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
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            GBL:AssignOccurrenceIndices(batch1)
            for _, r in ipairs(batch1) do
                GBL:MarkSeen(r.id, r.timestamp, guildData)
            end
            -- Stored: prefix|475100:0, prefix|475100:1

            -- Rescan with new record in slot 101 prepended
            local newTx = itemRecord({ timestamp = 3600 * 475101 })
            local old1 = itemRecord({ timestamp = 3600 * 475100 })
            local old2 = itemRecord({ timestamp = 3600 * 475100 })
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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 })
            local rec2 = itemRecord({ timestamp = 3600 * 475101 })
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
            local rec1 = itemRecord({ timestamp = 3600 * 475100 + 3000 })
            GBL:AssignOccurrenceIndices({ rec1 })
            GBL:MarkSeen(rec1.id, rec1.timestamp, guildData)

            local rec2 = itemRecord({ timestamp = 3600 * 475101 + 600 })
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

    -- The key a count for a record's own hour carries, read off the record id
    -- (#275). The serve builds a set of these for the records going out, and
    -- the count filter looks a boundary count up in it across its window.
    describe("BaseHashForRecord", function()
        it("drops the occurrence from an item record id", function()
            assert.equals("withdraw|Thrall|12345|5|1|100",
                GBL:BaseHashForRecord({ id = "withdraw|Thrall|12345|5|1|100:3" }))
        end)

        it("drops the occurrence from a money record id", function()
            assert.equals("withdrawal|Thrall|50000|100",
                GBL:BaseHashForRecord({ id = "withdrawal|Thrall|50000|100:0" }))
        end)

        -- It has to read the same slot the packer files the record under, or a
        -- count admitted through this record could be filed under a bucket the
        -- send never reaches and fall back into the trailing carriers. Both now
        -- read one pattern in src/Fingerprint.lua; this holds them to the
        -- reading bucketKeyForRecord has always made, written out here as the
        -- oracle, over ids shaped to sit either side of it. The timestamp lands
        -- in bucket 999, so a fallback cannot pass for an id read.
        it("reads the slot BucketKeyForRecord files the record under", function()
            local FALLBACK = 999
            for _, id in ipairs({
                "deposit|Alice-Stormrage|191301|20|3|493217:0",
                "repair|Alice-Stormrage|3500|493218:2",
                "withdraw|Thrall|12345|5|1|100:10",
                "a|b|12:3",
                "|12:3",
                "a||12:3",
                "a|12:3|4:5",
                "a|12:3:4",
                "a|x12:3",
                "a|12",
                "a|12:",
                "12:3",
                "",
            }) do
                local rec = { id = id, timestamp = FALLBACK * 21600 }
                local oracle = id:match("|(%d+):%d+$")
                local base = GBL:BaseHashForRecord(rec)
                if oracle then
                    assert.equals((id:gsub(":%d+$", "")), base, id)
                    local _, slot = GBL:SplitBaseHash(base)
                    assert.equals(tonumber(oracle), slot, id)
                    assert.equals(GBL:BucketKeyForTimeSlot(tonumber(oracle)),
                        GBL:BucketKeyForRecord(rec), id)
                else
                    assert.is_nil(base, id)
                    assert.equals(FALLBACK, GBL:BucketKeyForRecord(rec), id)
                end
            end
        end)

        -- Nil where BucketKeyForRecord would fall back to the timestamp: such a
        -- record has no slot in its id to match a count key against. The
        -- migrations' own gsub keeps an unparseable id whole, which is a
        -- different contract, and they do not call this.
        it("returns nil for an id with no slot and occurrence", function()
            assert.is_nil(GBL:BaseHashForRecord({ id = "legacy-hash" }))
            assert.is_nil(GBL:BaseHashForRecord({ id = "withdraw|Thrall|100" }))
            assert.is_nil(GBL:BaseHashForRecord({ id = "100:0" }))
        end)

        it("returns nil for a record with no id, or no record", function()
            assert.is_nil(GBL:BaseHashForRecord({ timestamp = 1 }))
            assert.is_nil(GBL:BaseHashForRecord(nil))
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
            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            guildData.seenTxHashes[baseHash .. ":0"] = 3600 * 475100
            guildData.seenTxHashes[baseHash .. ":1"] = 3600 * 475100
            assert.equals(2, GBL:CountStoredForHash(baseHash, 3600 * 475100, guildData))
        end)

        it("finds adjacent-slot matches with timestamp proximity", function()
            -- Stored at slot 100, querying for slot 101 (hour boundary drift)
            local storedHash = "withdraw|Thrall|12345|5|1|475100"
            local queryHash = "withdraw|Thrall|12345|5|1|475101"
            guildData.seenTxHashes[storedHash .. ":0"] = 3600 * 475100 + 3000
            -- diff = |3600*475101 - (3600*475100 + 3000)| = |600| < 3600
            assert.equals(1, GBL:CountStoredForHash(queryHash, 3600 * 475101, guildData))
        end)

        it("rejects adjacent-slot matches with distant timestamps", function()
            -- Stored at slot 99, querying for slot 100 with distant timestamp
            local storedHash = "withdraw|Thrall|12345|5|1|475099"
            local queryHash = "withdraw|Thrall|12345|5|1|475100"
            guildData.seenTxHashes[storedHash .. ":0"] = 3600 * 475099
            -- diff = |3600*475100 + 1800 - 3600*475099| = 5400 >= 3600
            assert.equals(0, GBL:CountStoredForHash(queryHash, 3600 * 475100 + 1800, guildData))
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
                timestamp = 3600 * 475100,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 475100 + 1000,  -- same slot
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(2, index["withdraw|Thrall|12345|5|1|"][475100])
        end)

        it("tracks different slots independently", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 475100,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 3600 * 475102,  -- different slot
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][475100])
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][475102])
        end)

        it("indexes nil timestamp at GetServerTime slot", function()
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = nil,
            })
            local index = GBL:BuildStoredRecordIndex(guildData, "transactions")
            local expectedSlot = math.floor(Helpers.MockWoW.serverTime / 3600)
            assert.equals(1, index["withdraw|Thrall|12345|5|1|"][expectedSlot])
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
            local r1 = itemRecord({ timestamp = 3600 * 475100, player = "Thrall" })
            local r2 = itemRecord({ timestamp = 3600 * 475100, player = "Jaina" })
            local batch = { r1, r2 }

            local stored, counts = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            assert.equals(2, stored)
            assert.equals(2, #guildData.transactions)
        end)

        it("deduplicates on initial scan against stored records", function()
            -- Pre-populate records array and seenTxHashes (from a previous session)
            local rec = itemRecord({ timestamp = 3600 * 475100 })
            local baseHash = rec.id
            rec._occurrence = 0
            rec.id = baseHash .. ":0"
            table.insert(guildData.transactions, rec)
            guildData.seenTxHashes[rec.id] = 3600 * 475100

            -- Batch with 1 record matching the stored one
            local batch = { itemRecord({ timestamp = 3600 * 475100 }) }

            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        it("rescan with same batch produces 0 new records", function()
            -- Initial scan
            local batch1 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475101, player = "Jaina" }),
            }
            local stored1, prevCounts = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)
            assert.equals(2, stored1)

            -- Rescan with identical batch
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475101, player = "Jaina" }),
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prevCounts)
            assert.equals(0, stored2)
        end)

        -- CORE REGRESSION TEST: the bug v0.14.0 failed to fix
        it("rescan with new same-SLOT record does not create duplicates", function()
            -- Scan 1: 1 record at slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 475100 }) }
            local stored1, prevCounts = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)
            assert.equals(1, stored1)
            assert.equals(1, #guildData.transactions)

            -- Rescan: 2 records at slot 100 (new one prepended by WoW API)
            -- Both have identical baseHashes — indistinguishable except by count
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100 }),  -- new (WoW puts newest first)
                itemRecord({ timestamp = 3600 * 475100 }),  -- old
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
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local stored3 = GBL:StoreBatchRecords(
                batch3, guildData, "transactions", prevCounts2)
            assert.equals(0, stored3)
            assert.equals(2, #guildData.transactions)
        end)

        it("multiple rescans accumulate correctly", function()
            -- Scan 1: 1 record
            local batch1 = { itemRecord({ timestamp = 3600 * 475100 }) }
            local _, prev1 = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)

            -- Rescan 2: 2 records (1 new)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local stored2, prev2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prev1)
            assert.equals(1, stored2)

            -- Rescan 3: 3 records (1 more new)
            local batch3 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local stored3 = GBL:StoreBatchRecords(
                batch3, guildData, "transactions", prev2)
            assert.equals(1, stored3)

            assert.equals(3, #guildData.transactions)
        end)

        it("handles hour-boundary drift during rescan", function()
            -- Scan 1: record at slot 100
            local batch1 = { itemRecord({ timestamp = 3600 * 475100 + 3500 }) }
            local _, prev = GBL:StoreBatchRecords(
                batch1, guildData, "transactions", nil)

            -- Rescan: hour rolled over, same record now computes to slot 101
            local batch2 = { itemRecord({ timestamp = 3600 * 475101 + 100 }) }
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
                itemRecord({ timestamp = 3600 * 475100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 475100, itemID = 222 }),
                itemRecord({ timestamp = 3600 * 475100, itemID = 111 }),  -- second of same item
            }
            local stored, prev = GBL:StoreBatchRecords(
                batch, guildData, "transactions", nil)
            assert.equals(3, stored)

            -- Rescan: 1 more of item 111
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 475100, itemID = 222 }),
                itemRecord({ timestamp = 3600 * 475100, itemID = 111 }),
                itemRecord({ timestamp = 3600 * 475100, itemID = 111 }),  -- new
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "transactions", prev)
            assert.equals(1, stored2)
            assert.equals(4, #guildData.transactions)
        end)

        it("works with money transactions", function()
            local r1 = moneyRecord({ timestamp = 3600 * 475100 })
            local batch = { r1 }
            local stored, prev = GBL:StoreBatchRecords(
                batch, guildData, "moneyTransactions", nil)
            assert.equals(1, stored)
            assert.equals(1, #guildData.moneyTransactions)

            -- Rescan with new money record prepended
            local batch2 = {
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
            }
            local stored2 = GBL:StoreBatchRecords(
                batch2, guildData, "moneyTransactions", prev)
            assert.equals(1, stored2)
            assert.equals(2, #guildData.moneyTransactions)
        end)

        it("validates records before storing", function()
            local bad = { type = "", player = "", timestamp = 3600 * 475100, itemID = 1, count = 1, tab = 1 }
            bad.id = GBL:ComputeTxHash(bad)
            local batch = { bad }

            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        -- REGRESSION (money): sync normalization gap
        it("does not duplicate money records when seenTxHashes has gaps", function()
            local baseHash = "deposit|Thrall|50000|475100"
            for occ = 0, 2 do
                local rec = moneyRecord({ timestamp = 3600 * 475100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.moneyTransactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end
            -- Gap: normalization removed :1, added slot 101
            guildData.seenTxHashes[baseHash .. ":1"] = nil
            guildData.seenTxHashes["deposit|Thrall|50000|475101:0"] = 3600 * 475101

            local batch = {
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(0, stored)
            assert.equals(3, #guildData.moneyTransactions)
        end)

        -- REGRESSION (money): records split across adjacent slots
        it("does not duplicate money records split across adjacent slots", function()
            local rec99 = moneyRecord({ timestamp = 3600 * 475099 + 3500 })
            rec99._occurrence = 0
            rec99.id = "deposit|Thrall|50000|99:0"
            table.insert(guildData.moneyTransactions, rec99)
            guildData.seenTxHashes[rec99.id] = rec99.timestamp

            local rec101 = moneyRecord({ timestamp = 3600 * 475101 + 100 })
            rec101._occurrence = 0
            rec101.id = "deposit|Thrall|50000|475101:0"
            table.insert(guildData.moneyTransactions, rec101)
            guildData.seenTxHashes[rec101.id] = rec101.timestamp

            local batch = {
                moneyRecord({ timestamp = 3600 * 475100 + 500 }),
                moneyRecord({ timestamp = 3600 * 475100 + 500 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(0, stored)
            assert.equals(2, #guildData.moneyTransactions)
        end)

        -- REGRESSION (money): occurrence assignment past gaps
        it("assigns money occurrence past gaps", function()
            local baseHash = "deposit|Thrall|50000|475100"
            for _, occ in ipairs({0, 2}) do
                local rec = moneyRecord({ timestamp = 3600 * 475100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.moneyTransactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end

            local batch = {
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)
            assert.equals(1, stored)
            assert.equals(3, #guildData.moneyTransactions)
            assert.is_truthy(guildData.moneyTransactions[3].id:find(":3$"))
        end)

        -- REGRESSION: sync normalization creates gaps in seenTxHashes
        it("does not duplicate when seenTxHashes has gaps from normalization", function()
            -- Simulate: 3 records stored at slot 100 with sequential indices
            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            for occ = 0, 2 do
                local rec = itemRecord({ timestamp = 3600 * 475100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.transactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end
            assert.equals(3, #guildData.transactions)

            -- Simulate sync normalization: :1 moved to different slot, creating gap
            guildData.seenTxHashes[baseHash .. ":1"] = nil
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475101:0"] = 3600 * 475101

            -- Bank reopen: initial scan with 3 records (same events)
            local batch = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            -- Must not create duplicates: records array already has 3
            assert.equals(0, stored)
            assert.equals(3, #guildData.transactions)
        end)

        -- Verifies WHY the gap fix works: BuildStoredRecordIndex counts from
        -- the records array (ground truth) rather than seenTxHashes (has gaps).
        it("BuildStoredRecordIndex counts correctly despite seenTxHashes gaps", function()
            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            for occ = 0, 2 do
                local rec = itemRecord({ timestamp = 3600 * 475100 })
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
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
            assert.equals(0, stored)
        end)

        -- REGRESSION: records split across both adjacent slots
        it("does not duplicate when records are split across adjacent slots", function()
            -- Simulate: 1 record at slot 99, 1 at slot 101 (from normalization)
            local rec99 = itemRecord({ timestamp = 3600 * 475099 + 3500 })
            rec99._occurrence = 0
            rec99.id = "withdraw|Thrall|12345|5|1|99:0"
            table.insert(guildData.transactions, rec99)
            guildData.seenTxHashes[rec99.id] = rec99.timestamp

            local rec101 = itemRecord({ timestamp = 3600 * 475101 + 100 })
            rec101._occurrence = 0
            rec101.id = "withdraw|Thrall|12345|5|1|475101:0"
            table.insert(guildData.transactions, rec101)
            guildData.seenTxHashes[rec101.id] = rec101.timestamp

            -- Bank reopen: both events now map to slot 100
            local batch = {
                itemRecord({ timestamp = 3600 * 475100 + 500 }),
                itemRecord({ timestamp = 3600 * 475100 + 500 }),
            }
            local stored = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            -- Records array already has 2 → 0 new
            assert.equals(0, stored)
            assert.equals(2, #guildData.transactions)
        end)

        -- REGRESSION: occurrence assignment must not collide with existing IDs
        it("assigns occurrence past gaps when storing new records", function()
            -- Stored: :0 and :2 exist (gap at :1 from normalization)
            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            for _, occ in ipairs({0, 2}) do
                local rec = itemRecord({ timestamp = 3600 * 475100 })
                rec._occurrence = occ
                rec.id = baseHash .. ":" .. occ
                table.insert(guildData.transactions, rec)
                guildData.seenTxHashes[rec.id] = rec.timestamp
            end

            -- New batch with 3 records (1 new beyond the 2 stored)
            local batch = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
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
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            assert.is_not_nil(guildData.eventCounts)
            assert.is_not_nil(guildData.eventCounts[baseHash])
            assert.equals(2, guildData.eventCounts[baseHash].count)
            assert.equals(Helpers.MockWoW.serverTime, guildData.eventCounts[baseHash].asOf)
        end)

        it("rescan updates count upward", function()
            -- Initial: 2 records
            local batch1 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local _, prevCounts = GBL:StoreBatchRecords(batch1, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            assert.equals(2, guildData.eventCounts[baseHash].count)

            -- Rescan: now 3 records (new event happened)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            GBL:StoreBatchRecords(batch2, guildData, "transactions", prevCounts)

            assert.equals(3, guildData.eventCounts[baseHash].count)
        end)

        it("count never decreases on rescan (aged out events)", function()
            -- Initial: 3 records
            local batch1 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            local _, prevCounts = GBL:StoreBatchRecords(batch1, guildData, "transactions", nil)

            local baseHash = "withdraw|Thrall|12345|5|1|475100"
            assert.equals(3, guildData.eventCounts[baseHash].count)

            -- Rescan: now only 2 records (1 aged out of API)
            local batch2 = {
                itemRecord({ timestamp = 3600 * 475100 }),
                itemRecord({ timestamp = 3600 * 475100 }),
            }
            GBL:StoreBatchRecords(batch2, guildData, "transactions", prevCounts)

            -- Count must not decrease
            assert.equals(3, guildData.eventCounts[baseHash].count)
        end)

        it("multiple prefixes get independent counts", function()
            local batch = {
                itemRecord({ timestamp = 3600 * 475100, player = "Thrall" }),
                itemRecord({ timestamp = 3600 * 475100, player = "Thrall" }),
                itemRecord({ timestamp = 3600 * 475100, player = "Jaina", itemID = 99999 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "transactions", nil)

            local hash1 = "withdraw|Thrall|12345|5|1|475100"
            local hash2 = "withdraw|Jaina|99999|5|1|475100"
            assert.equals(2, guildData.eventCounts[hash1].count)
            assert.equals(1, guildData.eventCounts[hash2].count)
        end)

        it("works with money transactions", function()
            local batch = {
                moneyRecord({ timestamp = 3600 * 475100 }),
                moneyRecord({ timestamp = 3600 * 475100 }),
            }
            GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)

            local baseHash = "deposit|Thrall|50000|475100"
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

    -- The per-entry decision stage 6 of the sliced serve (#115) applies to each
    -- eventCounts key as it walks the table across frames. It had a second
    -- caller, a synchronous collector, until that lost its last production
    -- caller with the slicing and was deleted.
    describe("EventCountRidesWithBuckets", function()
        it("keeps every entry when there is no bucket filter", function()
            assert.is_true(GBL:EventCountRidesWithBuckets(
                "withdraw|Thrall|12345|5|1|100", nil))
        end)

        it("keeps an entry whose slot lands in a listed bucket", function()
            -- slot 100 -> bucket 16
            assert.is_true(GBL:EventCountRidesWithBuckets(
                "withdraw|Thrall|12345|5|1|100", { [16] = true }))
        end)

        it("drops an entry whose bucket is not listed", function()
            -- slot 200 -> bucket 33
            assert.is_false(GBL:EventCountRidesWithBuckets(
                "deposit|Jaina|99999|5|2|200", { [16] = true }))
        end)

        -- The #270 widening, narrowed by #275. A count one hour across a bucket
        -- boundary from the records that can use it was dropped by the exact
        -- test above, so this client's cleanup found it and no session could
        -- ever offer it: 46 of 16,644 on the measured store. CleanupWithEventCounts
        -- reaches a count at slot -1 .. slot +1 of a record's own slot, so a
        -- record in the neighbouring bucket can use this entry. Since #275 the
        -- neighbour admits it only when a record the count can trim is in the
        -- send, which is what the third argument says: the base hashes of the
        -- records going out, keyed prefix .. slot like the count itself.
        local PREFIX = "withdraw|Thrall|12345|5|1|"

        it("keeps a boundary entry when the neighbour sends a record it can trim",
        function()
            -- slot 102 is the first hour of bucket 17, and a record of its
            -- prefix at slot 101 in bucket 16 is in the send.
            assert.is_true(GBL:EventCountRidesWithBuckets(
                PREFIX .. 102, { [16] = true }, { [PREFIX .. 101] = true }))
            -- slot 101 is the last hour of bucket 16, and a record of its
            -- prefix at slot 102 in bucket 17 is in the send.
            assert.is_true(GBL:EventCountRidesWithBuckets(
                PREFIX .. 101, { [17] = true }, { [PREFIX .. 102] = true }))
        end)

        -- The slot-only reading #275 was filed with, and why it was not built:
        -- a record of some other transaction in the same hour says nothing
        -- about whether the count can be used. On the live store that reading
        -- kept 3,870 of #270's 4,328 neighbour admissions, because most hours
        -- on a bucket edge hold some record.
        it("drops a boundary entry when the neighbour's record in its window is another prefix",
        function()
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 102, { [16] = true },
                { ["deposit|Jaina|99999|5|2|101"] = true }))
        end)

        -- One hour either side, and not two: the window is the cleanup's.
        it("drops a boundary entry when its prefix is in the neighbour two hours away",
        function()
            -- slot 100 is two hours below 102 and in bucket 16 like 101.
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 102, { [16] = true }, { [PREFIX .. 100] = true }))
            -- and 103 is two hours above 101, in bucket 17 like 102.
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 101, { [17] = true }, { [PREFIX .. 103] = true }))
        end)

        -- With no record index the predicate cannot know that anything the
        -- count can trim is going out, so a neighbour admits nothing. Stage 6
        -- always passes one on the bucket path; this is the answer for a
        -- caller that does not.
        it("drops a boundary entry for a neighbour when no record index is given",
        function()
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 102, { [16] = true }))
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 101, { [17] = true }))
        end)

        -- The own bucket is unaffected in both directions: an entry rides with
        -- its own bucket whether or not a record of its hour is going out,
        -- which is the rule that held before #270.
        it("keeps an entry whose own bucket is listed, with nothing in its window",
        function()
            -- interior of bucket 16
            assert.is_true(GBL:EventCountRidesWithBuckets(
                PREFIX .. 100, { [16] = true }, {}))
            -- first hour of bucket 17, own bucket listed
            assert.is_true(GBL:EventCountRidesWithBuckets(
                PREFIX .. 102, { [17] = true }, {}))
            -- last hour of bucket 16, own bucket listed
            assert.is_true(GBL:EventCountRidesWithBuckets(
                PREFIX .. 101, { [16] = true }, {}))
        end)

        -- The other half of the same widening, and the reason it is a window
        -- rather than "also send the neighbours". An interior slot has no
        -- record outside its own bucket that can reach it, so nothing about it
        -- changes, which is what keeps the drop case above meaning what it says.
        -- The neighbour is sending a record of the count's prefix in every
        -- one of its hours, so the predicate has to reach the window and find
        -- none of them inside it (an index-free call would return before the
        -- window was ever read).
        it("still drops an interior entry for a neighbouring bucket", function()
            local function everyHourOf(bucket)
                local sent = {}
                for s = bucket * 6, bucket * 6 + 5 do sent[PREFIX .. s] = true end
                return sent
            end
            -- slot 100 sits inside bucket 16, two hours clear of bucket 17
            -- (102) and five clear of bucket 15 (95).
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 100, { [17] = true }, everyHourOf(17)))
            assert.is_false(GBL:EventCountRidesWithBuckets(
                PREFIX .. 100, { [15] = true }, everyHourOf(15)))
        end)

        it("drops an entry whose base hash carries no slot", function()
            assert.is_false(GBL:EventCountRidesWithBuckets("nodigits", { [16] = true }))
        end)

        it("drops a nil base hash rather than throwing", function()
            assert.is_false(GBL:EventCountRidesWithBuckets(nil, { [16] = true }))
        end)
    end)

    -- The slot-to-bucket conversion had been written out by hand here, six
    -- hours per bucket spelled as a literal 6, while Fingerprint.lua held the
    -- same number as a named constant. One name now.
    describe("BucketKeyForTimeSlot", function()
        it("folds six hourly slots into one bucket", function()
            assert.equals(GBL:BucketKeyForTimeSlot(96), GBL:BucketKeyForTimeSlot(101))
            assert.are_not.equals(
                GBL:BucketKeyForTimeSlot(101), GBL:BucketKeyForTimeSlot(102))
        end)

        it("agrees with the bucket key a record with that slot would get",
        function()
            local slot = 472222
            local record = { id = "deposit|A|100|1|1|" .. slot .. ":0" }
            assert.equals(
                GBL:BucketKeyForRecord(record), GBL:BucketKeyForTimeSlot(slot))
        end)
    end)

    -- The key-to-bucket reading itself, lifted out of the predicate above so
    -- the packer can interleave counts with the records they describe (#114).
    -- The predicate answers yes or no; PrepareChunks needs the key. One writer
    -- of the arithmetic, two readers of it.
    describe("BucketKeyForEventCount", function()
        it("reads the bucket out of an event count key", function()
            -- slot 100 -> bucket 16
            assert.equals(16, GBL:BucketKeyForEventCount("withdraw|Thrall|12345|5|1|100"))
        end)

        it("agrees with the bucket a record at the same slot would get", function()
            local slot = 472222
            local record = { id = "deposit|A|100|1|1|" .. slot .. ":0" }
            assert.equals(
                GBL:BucketKeyForRecord(record),
                GBL:BucketKeyForEventCount("deposit|A|100|1|1|" .. slot))
        end)

        it("returns nil for a key carrying no slot", function()
            assert.is_nil(GBL:BucketKeyForEventCount("nodigits"))
        end)

        it("returns nil for a nil key rather than throwing", function()
            assert.is_nil(GBL:BucketKeyForEventCount(nil))
        end)

        -- Both readers must agree about the own bucket, or the packer could
        -- file an entry under a bucket the filter never selected.
        --
        -- The predicate answers from neither this reading alone (the defect
        -- #270 fixed) nor the ride set alone (the over-inclusion #275 fixed):
        -- an entry rides with its own bucket, and with a neighbour only when a
        -- record it can trim is going out there. What this pins is the bound
        -- that keeps #114's ordering, for the fullest index a send can build:
        -- a send carrying only the candidate bucket holds at most a record of
        -- the count's prefix in each of its six hours, and with every one of
        -- them present the predicate admits exactly when the candidate is in
        -- the ride set, never a bucket outside it, because PrepareChunks files
        -- the entry under that set and has nowhere else to emit it ahead of
        -- the records. With nothing in the send it is back to its own bucket.
        -- The index holds whole hours of the candidate rather than the count's
        -- window, so this does not restate the window it is checking.
        --
        -- What it cannot see, by construction: an index holding a record from
        -- a bucket the session does not carry. A send never builds one, except
        -- in the window where a sync chunk arriving mid-preparation rewrites a
        -- selected record's id across a bucket edge, and there the bucket test
        -- ahead of each lookup withholds the count, which is as safe as
        -- admitting it (the moved record's bucket is in the ride set either
        -- way). That test is a cost guard, and is left unpinned on purpose.
        it("admits within the ride set only, and all of it when the send can use it",
        function()
            local keys = {
                "withdraw|Thrall|12345|5|1|100",   -- interior of bucket 16
                "deposit|Jaina|99999|5|2|200",     -- interior of bucket 33
                "deposit|Sylvanas|1|1|1|101",      -- last hour of bucket 16
                "withdraw|Thrall|12345|5|1|102",   -- first hour of bucket 17
                "nodigits",
            }
            for _, key in ipairs(keys) do
                local own = GBL:BucketKeyForEventCount(key)
                local ride = GBL:EventCountRideBuckets(key)
                if own == nil then
                    assert.is_nil(ride, "a key with no bucket has no ride set: " .. key)
                else
                    local found = false
                    for _, bucket in ipairs(ride) do
                        if bucket == own then found = true end
                    end
                    assert.is_true(found,
                        "the own bucket must be in the ride set: " .. key)
                end

                -- For every candidate bucket, not just the ones a fixture
                -- happens to pick.
                local prefix = GBL:SplitBaseHash(key)
                for candidate = 14, 35 do
                    local inRide = false
                    for _, bucket in ipairs(ride or {}) do
                        if bucket == candidate then inRide = true end
                    end

                    local everyHour = {}
                    if prefix then
                        for s = candidate * 6, candidate * 6 + 5 do
                            everyHour[prefix .. s] = true
                        end
                    end

                    assert.equals(inRide,
                        GBL:EventCountRidesWithBuckets(
                            key, { [candidate] = true }, everyHour),
                        ("with a record of its prefix in every hour of the"
                            .. " candidate, %s at bucket %d should follow the"
                            .. " ride set"):format(key, candidate))
                    assert.equals(own ~= nil and candidate == own,
                        GBL:EventCountRidesWithBuckets(
                            key, { [candidate] = true }, {}),
                        ("with nothing in its window, %s at bucket %d should"
                            .. " ride with its own bucket only")
                            :format(key, candidate))
                end
            end
        end)

        -- The discriminator the rewritten case above exists for: a key whose
        -- own bucket is absent from the filter rides with the neighbour when a
        -- record it can trim is going out there. This is the assertion the
        -- own-bucket basis before #270 could not make.
        it("rides on a bucket that is not its own", function()
            local key = "withdraw|Thrall|12345|5|1|102"
            assert.equals(17, GBL:BucketKeyForEventCount(key))
            assert.is_true(GBL:EventCountRidesWithBuckets(key, { [16] = true },
                { ["withdraw|Thrall|12345|5|1|101"] = true }),
                "a boundary entry must ride with a neighbour sending a record it can trim")
        end)
    end)
    -- One shared reading of which buckets a count can be used by (#270). The
    -- packer indexes every entry under it, and the filter admits a subset of
    -- it (#275), because an entry admitted outside it would land back in the
    -- trailing carriers #114 emptied: PrepareChunks files an entry under a
    -- bucket and emits it at that bucket's first record, and a boundary
    -- count's own bucket has no records in the send.
    describe("EventCountRideBuckets", function()
        it("gives one bucket for a slot in the middle of a bucket", function()
            -- slot 100 -> bucket 16, and 99 and 101 are in 16 too
            local ride = GBL:EventCountRideBuckets("withdraw|Thrall|12345|5|1|100")
            assert.same({ 16 }, ride)
        end)

        it("gives the bucket below as well on the first hour of a bucket",
        function()
            -- slot 102 -> bucket 17, and slot 101 is in 16
            assert.same({ 16, 17 },
                GBL:EventCountRideBuckets("withdraw|Thrall|12345|5|1|102"))
        end)

        it("gives the bucket above as well on the last hour of a bucket",
        function()
            -- slot 101 -> bucket 16, and slot 102 is in 17
            assert.same({ 16, 17 },
                GBL:EventCountRideBuckets("withdraw|Thrall|12345|5|1|101"))
        end)

        it("gives nil for a key carrying no slot", function()
            assert.is_nil(GBL:EventCountRideBuckets("nodigits"))
        end)

        it("gives nil for a nil key rather than throwing", function()
            assert.is_nil(GBL:EventCountRideBuckets(nil))
        end)

        -- Every member has to be reachable from the window, and the window has
        -- to be the one CleanupWithEventCounts uses. Computed through
        -- BucketKeyForTimeSlot rather than by arithmetic on slot % 6, so the
        -- bucket width stays in one place.
        it("returns only buckets inside the cleanup window, from the same constant",
        function()
            local radius = GBL.EVENT_COUNT_SLOT_RADIUS
            assert.is_true(type(radius) == "number" and radius >= 1,
                "the window radius must be an exported number")

            for slot = 96, 108 do
                local ride = GBL:EventCountRideBuckets(
                    "withdraw|Thrall|12345|5|1|" .. slot)
                local allowed = {}
                for s = slot - radius, slot + radius do
                    allowed[GBL:BucketKeyForTimeSlot(s)] = true
                end
                for _, bucket in ipairs(ride) do
                    assert.is_true(allowed[bucket] == true,
                        ("slot %d: bucket %d is outside the window")
                            :format(slot, bucket))
                end
                -- and every bucket the window reaches is in the set
                local got = {}
                for _, bucket in ipairs(ride) do got[bucket] = true end
                for bucket in pairs(allowed) do
                    assert.is_true(got[bucket] == true,
                        ("slot %d: bucket %d missing from the ride set")
                            :format(slot, bucket))
                end
            end
        end)

        it("is ascending and free of duplicates", function()
            for slot = 96, 108 do
                local ride = GBL:EventCountRideBuckets(
                    "withdraw|Thrall|12345|5|1|" .. slot)
                for i = 2, #ride do
                    assert.is_true(ride[i] > ride[i - 1],
                        ("slot %d: ride set is not strictly ascending"):format(slot))
                end
            end
        end)
    end)
    -- The ride set above is only worth anything if it mirrors the window the
    -- cleanup loop actually uses, and the loop lives in another file. One
    -- exported constant is what holds them together, so these cases move it and
    -- check that BOTH ends follow. Without that, the two drift the way the
    -- filter and the cleanup already had.
    describe("the cleanup window and the ride set are one window", function()
        -- Slot 475103 is the last hour of its bucket, so a count at 475104 is
        -- one hour away and in the next bucket: the #270 shape exactly.
        local SLOT = 475103

        local function boundaryCluster()
            local records = {}
            for i = 1, 3 do
                records[i] = {
                    type = "withdraw", player = "Thrall", itemID = 12345,
                    count = 5, tab = 1,
                    timestamp = SLOT * 3600 + i * 10,
                }
            end
            local prefix = GBL:BuildTxPrefix(records[1])
            for i, rec in ipairs(records) do
                rec.id = prefix .. SLOT .. ":" .. (i - 1)
            end
            guildData.transactions = records
            guildData.eventCounts = {
                [prefix .. (SLOT + 1)] = { count = 1, asOf = SLOT * 3600 },
            }
            return prefix .. (SLOT + 1)
        end

        it("reaches a count one hour across a bucket boundary and trims on it",
        function()
            local key = boundaryCluster()
            assert.are_not.equals(
                GBL:BucketKeyForTimeSlot(SLOT), GBL:BucketKeyForEventCount(key),
                "fixture must straddle a bucket boundary or it proves nothing")

            GBL:CleanupWithEventCounts(guildData)
            assert.equals(1, #guildData.transactions,
                "the cleanup window has to reach a count one slot away")
        end)

        -- Three readers since #275: the serve's filter looks for a record of
        -- the count's prefix across the same window, from the count's side.
        it("moves the cleanup loop, the ride set and the filter together", function()
            local key = boundaryCluster()
            local prefix = GBL:SplitBaseHash(key)
            local recordsBucket = { [GBL:BucketKeyForTimeSlot(SLOT)] = true }
            local recordsSent = { [prefix .. SLOT] = true }
            local original = GBL.EVENT_COUNT_SLOT_RADIUS

            assert.equals(2, #GBL:EventCountRideBuckets(key),
                "a boundary key rides with two buckets at the shipped radius")
            assert.is_true(
                GBL:EventCountRidesWithBuckets(key, recordsBucket, recordsSent),
                "the filter admits the count one hour from a record it can trim")

            GBL.EVENT_COUNT_SLOT_RADIUS = 0
            local narrowed = GBL:EventCountRideBuckets(key)
            local admitted =
                GBL:EventCountRidesWithBuckets(key, recordsBucket, recordsSent)
            GBL:CleanupWithEventCounts(guildData)
            GBL.EVENT_COUNT_SLOT_RADIUS = original

            assert.equals(1, #narrowed,
                "the ride set must read the constant, not a literal")
            assert.is_false(admitted,
                "the filter must read the constant, not a literal")
            assert.equals(3, #guildData.transactions,
                "the cleanup loop must read the constant, not a literal")
        end)

        -- The window's shape has one writer, EventCountWindow, and the two
        -- count-side consumers walk it reflected. A symmetric window reads the
        -- same either way round, so these tip it to one side and check that
        -- the cleanup, the ride set and the filter still agree about one record
        -- and one count an hour later.
        it("keeps all three agreeing on a window that reaches one way only",
        function()
            local original = GBL.EventCountWindow
            for _, case in ipairs({
                -- a record can use a count up to an hour later
                { first = 0, last = 1, reaches = true },
                -- a record can use a count up to an hour earlier only
                { first = -1, last = 0, reaches = false },
            }) do
                local key = boundaryCluster()
                local prefix = GBL:SplitBaseHash(key)
                local recordsBucket = GBL:BucketKeyForTimeSlot(SLOT)

                GBL.EventCountWindow = function() return case.first, case.last end
                local rideReachesRecords = false
                for _, bucket in ipairs(GBL:EventCountRideBuckets(key)) do
                    if bucket == recordsBucket then rideReachesRecords = true end
                end
                local admitted = GBL:EventCountRidesWithBuckets(key,
                    { [recordsBucket] = true }, { [prefix .. SLOT] = true })
                GBL:CleanupWithEventCounts(guildData)
                GBL.EventCountWindow = original

                local label = ("window %d..%d"):format(case.first, case.last)
                assert.equals(case.reaches, rideReachesRecords,
                    label .. ": the ride set disagreed with the cleanup")
                assert.equals(case.reaches, admitted,
                    label .. ": the filter disagreed with the cleanup")
                assert.equals(case.reaches and 1 or 3, #guildData.transactions,
                    label .. ": the cleanup did not reach as the window says")
            end
        end)
    end)

    -- #342. The cleanup gathers each array's records by prefix and used to
    -- write them back in that order whether or not it removed anything. The
    -- serve's bucket walk holds a positional cursor across frames, so a
    -- cleanup landing between two of its steps moved records across the
    -- cursor: one walked twice, another never. On the saved store a cleanup
    -- that removed nothing still moved 4,336 of 14,057 item records.
    describe("an array the cleanup removed nothing from (#342)", function()
        local function item(player, slot)
            return {
                type = "deposit", player = player, itemID = 1, count = 1, tab = 1,
                timestamp = slot * 3600 + 10,
                id = "deposit|" .. player .. "|1|1|1|" .. slot .. ":0",
                _occurrence = 0,
            }
        end

        local function money(player, slot)
            return {
                type = "deposit", player = player, amount = 500,
                timestamp = slot * 3600 + 10,
                id = "deposit|" .. player .. "|500|" .. slot .. ":0",
                _occurrence = 0,
            }
        end

        local function snapshot(list)
            local copy = {}
            for i, rec in ipairs(list) do copy[i] = rec end
            return copy
        end

        local function assertInPlace(before, list, what)
            assert.equals(#before, #list, what .. ": the length moved")
            for i, rec in ipairs(before) do
                assert.equals(rec, list[i],
                    what .. ": position " .. i .. " holds another record")
            end
        end

        -- Two records of one prefix with another prefix between them, days
        -- apart, so gathering by prefix would put the third record second.
        local function splitPair(make)
            return { make("Bob-TestRealm", 475100), make("Al-TestRealm", 475200),
                make("Bob-TestRealm", 475300) }
        end

        it("stays in place when nothing is removed", function()
            guildData.transactions = splitPair(item)
            guildData.moneyTransactions = splitPair(money)
            -- One count, for a prefix no record carries: the pass runs and
            -- has nothing to trim.
            guildData.eventCounts = {
                ["deposit|Nobody|9|9|9|475100"] = { count = 1, asOf = 0 },
            }
            local items = snapshot(guildData.transactions)
            local gold = snapshot(guildData.moneyTransactions)

            local removed = GBL:CleanupWithEventCounts(guildData)

            assert.equals(0, removed, "the fixture must give the pass nothing to trim")
            assertInPlace(items, guildData.transactions, "items")
            assertInPlace(gold, guildData.moneyTransactions, "money")
        end)

        it("stays in place when only the other array is trimmed", function()
            -- Three copies of one event against a count of one: two go.
            local cluster = {}
            for i = 1, 3 do
                cluster[i] = item("Thrall-TestRealm", 475103)
                cluster[i].timestamp = 475103 * 3600 + i * 10
                cluster[i].id = "deposit|Thrall-TestRealm|1|1|1|475103:" .. (i - 1)
                cluster[i]._occurrence = i - 1
            end
            guildData.transactions = cluster
            guildData.moneyTransactions = splitPair(money)
            guildData.eventCounts = {
                ["deposit|Thrall-TestRealm|1|1|1|475103"] = { count = 1, asOf = 0 },
            }
            local gold = snapshot(guildData.moneyTransactions)

            local removed = GBL:CleanupWithEventCounts(guildData)

            assert.equals(2, removed, "the fixture must make the pass trim the items")
            assert.equals(1, #guildData.transactions)
            assertInPlace(gold, guildData.moneyTransactions, "money")
        end)
    end)

end)
