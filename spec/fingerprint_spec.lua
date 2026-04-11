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

        it("groups records by day key", function()
            -- Day 20000 = timestamp 20000 * 86400
            local day1Ts = 20000 * 86400 + 3600
            local day2Ts = 20001 * 86400 + 3600

            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = day1Ts,
            })
            table.insert(guildData.transactions, {
                id = "deposit|B|200|1|1|200:0", timestamp = day2Ts,
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[20000])
            assert.is_not_nil(buckets[20001])
            assert.are_not.equals(buckets[20000], buckets[20001])
        end)

        it("records on same day contribute to same bucket", function()
            local dayTs1 = 20000 * 86400 + 100
            local dayTs2 = 20000 * 86400 + 50000

            table.insert(guildData.transactions, {
                id = "deposit|A|100|1|1|100:0", timestamp = dayTs1,
            })
            local buckets1 = GBL:ComputeBucketHashes(guildData)

            table.insert(guildData.transactions, {
                id = "deposit|B|200|1|1|200:0", timestamp = dayTs2,
            })
            local buckets2 = GBL:ComputeBucketHashes(guildData)

            -- Same day key, but hash should change with the second record
            assert.are_not.equals(buckets1[20000], buckets2[20000])
        end)

        it("includes money transactions", function()
            local dayTs = 20000 * 86400 + 3600

            table.insert(guildData.moneyTransactions, {
                id = "repair|A|5000|100:0", timestamp = dayTs,
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_not_nil(buckets[20000])
            assert.is_true(buckets[20000] > 0)
        end)

        it("skips records with nil id", function()
            local dayTs = 20000 * 86400 + 3600

            table.insert(guildData.transactions, {
                timestamp = dayTs, -- no id
            })

            local buckets = GBL:ComputeBucketHashes(guildData)
            assert.is_nil(buckets[20000])
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
end)
