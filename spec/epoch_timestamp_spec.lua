--- epoch_timestamp_spec.lua — Tests for epoch-0 timestamp fixes (v0.27.0)

local Helpers = require("spec.helpers")

describe("Epoch-0 timestamp fixes", function()
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
            eventCounts = {},
            schemaVersion = 8,
        }
    end)

    ---------------------------------------------------------------------------
    -- IsValidTimestamp
    ---------------------------------------------------------------------------

    describe("IsValidTimestamp", function()
        it("rejects 0", function()
            assert.is_false(GBL:IsValidTimestamp(0))
        end)

        it("rejects nil", function()
            assert.is_false(GBL:IsValidTimestamp(nil))
        end)

        it("rejects negative numbers", function()
            assert.is_false(GBL:IsValidTimestamp(-100))
        end)

        it("rejects pre-2004 timestamps", function()
            assert.is_false(GBL:IsValidTimestamp(1000000000))  -- Sep 2001
        end)

        it("rejects non-numbers", function()
            assert.is_false(GBL:IsValidTimestamp("1711700000"))
            assert.is_false(GBL:IsValidTimestamp(true))
        end)

        it("accepts valid WoW-era timestamps", function()
            assert.is_true(GBL:IsValidTimestamp(1711700000))   -- March 2024
            assert.is_true(GBL:IsValidTimestamp(1072915200))   -- Jan 1, 2004 (boundary)
            assert.is_true(GBL:IsValidTimestamp(1100000000))   -- Nov 2004
        end)
    end)

    ---------------------------------------------------------------------------
    -- SafeRecordTimestamp
    ---------------------------------------------------------------------------

    describe("SafeRecordTimestamp", function()
        it("returns record.timestamp when valid", function()
            local validTs = 3600 * 475100
            assert.equals(validTs, GBL:SafeRecordTimestamp({ timestamp = validTs }))
        end)

        it("returns GetServerTime when timestamp is nil", function()
            assert.equals(Helpers.MockWoW.serverTime,
                GBL:SafeRecordTimestamp({ timestamp = nil }))
        end)

        it("returns GetServerTime when timestamp is 0", function()
            assert.equals(Helpers.MockWoW.serverTime,
                GBL:SafeRecordTimestamp({ timestamp = 0 }))
        end)

        it("returns GetServerTime when timestamp is a string", function()
            assert.equals(Helpers.MockWoW.serverTime,
                GBL:SafeRecordTimestamp({ timestamp = "1711700000" }))
        end)

        it("returns GetServerTime when timestamp is negative", function()
            assert.equals(Helpers.MockWoW.serverTime,
                GBL:SafeRecordTimestamp({ timestamp = -100 }))
        end)
    end)

    ---------------------------------------------------------------------------
    -- ComputeTxHash with nil timestamp
    ---------------------------------------------------------------------------

    describe("ComputeTxHash", function()
        it("produces valid timeSlot when timestamp is nil", function()
            local record = {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = nil,
            }
            local hash, timeSlot = GBL:ComputeTxHash(record)
            assert.is_true(timeSlot > 0)
            -- Should use GetServerTime(), not 0
            local expectedSlot = math.floor(Helpers.MockWoW.serverTime / 3600)
            assert.equals(expectedSlot, timeSlot)
            assert.is_truthy(hash:find(tostring(expectedSlot)))
        end)

        it("produces valid timeSlot when timestamp is 0", function()
            local record = {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0,
            }
            -- 0 is truthy in Lua, so `0 or GetServerTime()` returns 0
            local _, timeSlot = GBL:ComputeTxHash(record)
            assert.equals(0, timeSlot)
        end)
    end)

    ---------------------------------------------------------------------------
    -- MarkSeen with invalid timestamps
    ---------------------------------------------------------------------------

    describe("MarkSeen", function()
        it("stores GetServerTime when timestamp is nil", function()
            GBL:MarkSeen("test:0", nil, guildData)
            assert.equals(Helpers.MockWoW.serverTime, guildData.seenTxHashes["test:0"])
        end)

        it("stores GetServerTime when timestamp is 0", function()
            GBL:MarkSeen("test:0", 0, guildData)
            assert.equals(Helpers.MockWoW.serverTime, guildData.seenTxHashes["test:0"])
        end)

        it("stores actual timestamp when valid", function()
            local validTs = 3600 * 475100
            GBL:MarkSeen("test:0", validTs, guildData)
            assert.equals(validTs, guildData.seenTxHashes["test:0"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- StoreTx / StoreMoneyTx boundary guards
    ---------------------------------------------------------------------------

    describe("StoreTx", function()
        it("sanitizes epoch-0 timestamp before storing", function()
            local record = {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            }
            GBL:StoreTx(record, guildData)
            assert.equals(Helpers.MockWoW.serverTime, record.timestamp)
        end)

        it("sanitizes nil timestamp before storing", function()
            local record = {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = nil, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            }
            GBL:StoreTx(record, guildData)
            assert.equals(Helpers.MockWoW.serverTime, record.timestamp)
        end)

        it("preserves valid timestamp", function()
            local validTs = 3600 * 475100
            local record = {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = validTs, id = "withdraw|Thrall|12345|5|1|475100:0",
                _occurrence = 0,
            }
            GBL:StoreTx(record, guildData)
            assert.equals(validTs, record.timestamp)
        end)
    end)

    describe("StoreMoneyTx", function()
        it("sanitizes epoch-0 timestamp before storing", function()
            local record = {
                type = "deposit", player = "Thrall",
                amount = 50000,
                timestamp = 0, id = "deposit|Thrall|50000|0:0",
                _occurrence = 0,
            }
            GBL:StoreMoneyTx(record, guildData)
            assert.equals(Helpers.MockWoW.serverTime, record.timestamp)
        end)
    end)

    ---------------------------------------------------------------------------
    -- MigrateRepairEpochTimestamps
    ---------------------------------------------------------------------------

    describe("MigrateRepairEpochTimestamps", function()
        it("repairs records with epoch-0 timestamps", function()
            guildData.schemaVersion = 7
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            assert.equals(8, guildData.schemaVersion)
            local record = guildData.transactions[1]
            assert.is_true(GBL:IsValidTimestamp(record.timestamp))
            -- ID should be rebuilt with new timeSlot
            assert.is_truthy(record.id:find("|%d+:%d+$"))
        end)

        it("recovers timestamp from ID timeSlot when possible", function()
            guildData.schemaVersion = 7
            -- ID has valid timeSlot 475100, but timestamp is 0
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|475100:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|475100:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            local record = guildData.transactions[1]
            assert.equals(475100 * 3600, record.timestamp)
        end)

        it("falls back to GetServerTime when ID timeSlot is also invalid", function()
            guildData.schemaVersion = 7
            -- ID has timeSlot 0
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            local record = guildData.transactions[1]
            assert.equals(Helpers.MockWoW.serverTime, record.timestamp)
        end)

        it("skips when schemaVersion >= 8", function()
            guildData.schemaVersion = 8
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })

            GBL:MigrateRepairEpochTimestamps(guildData)

            -- Should not have been modified
            assert.equals(0, guildData.transactions[1].timestamp)
        end)

        it("cleans up 1970-01-01 daily summaries", function()
            guildData.schemaVersion = 7
            guildData.dailySummaries = {
                ["1970-01-01"] = { withdrawCount = 5 },
                ["2024-03-15"] = { withdrawCount = 10 },
            }
            -- Need at least one bad record to trigger repair
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            assert.is_nil(guildData.dailySummaries["1970-01-01"])
            assert.is_not_nil(guildData.dailySummaries["2024-03-15"])
        end)

        it("cleans up 1970-* weekly summaries", function()
            guildData.schemaVersion = 7
            guildData.weeklySummaries = {
                ["1970-W01"] = { withdrawCount = 3 },
                ["1970-W52"] = { withdrawCount = 2 },
                ["2024-W11"] = { withdrawCount = 8 },
            }
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            assert.is_nil(guildData.weeklySummaries["1970-W01"])
            assert.is_nil(guildData.weeklySummaries["1970-W52"])
            assert.is_not_nil(guildData.weeklySummaries["2024-W11"])
        end)

        it("repairs money transactions too", function()
            guildData.schemaVersion = 7
            table.insert(guildData.moneyTransactions, {
                type = "deposit", player = "Thrall", amount = 50000,
                timestamp = 0, id = "deposit|Thrall|50000|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["deposit|Thrall|50000|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            local record = guildData.moneyTransactions[1]
            assert.is_true(GBL:IsValidTimestamp(record.timestamp))
        end)

        it("rebuilds seenTxHashes after repair", function()
            guildData.schemaVersion = 7
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 12345, count = 5, tab = 1,
                timestamp = 0, id = "withdraw|Thrall|12345|5|1|0:0",
                _occurrence = 0,
            })
            guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"] = 0

            GBL:MigrateRepairEpochTimestamps(guildData)

            -- Old key should be gone
            assert.is_nil(guildData.seenTxHashes["withdraw|Thrall|12345|5|1|0:0"])
            -- New key with corrected ID should exist
            local newId = guildData.transactions[1].id
            assert.is_not_nil(guildData.seenTxHashes[newId])
            assert.is_true(GBL:IsValidTimestamp(guildData.seenTxHashes[newId]))
        end)
    end)
end)
