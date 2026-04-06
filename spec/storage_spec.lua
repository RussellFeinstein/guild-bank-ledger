--- storage_spec.lua — Tests for Storage module

local Helpers = require("spec.helpers")

describe("Storage", function()
    local GBL
    local MockWoW
    local guildData

    before_each(function()
        Helpers.setupMocks()
        MockWoW = Helpers.MockWoW
        MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()

        guildData = GBL:GetGuildData()
    end)

    -- Helper: create a minimal item transaction record at a given age
    local function txRecord(daysAgo, opts)
        opts = opts or {}
        return {
            type = opts.type or "withdraw",
            player = opts.player or "Thrall",
            itemID = opts.itemID or 12345,
            count = opts.count or 5,
            tab = opts.tab or 1,
            timestamp = MockWoW.serverTime - (daysAgo * 86400),
        }
    end

    -- Helper: create a minimal money transaction record at a given age
    local function moneyTxRecord(daysAgo, opts)
        opts = opts or {}
        return {
            type = opts.type or "deposit",
            player = opts.player or "Thrall",
            amount = opts.amount or 50000,
            timestamp = MockWoW.serverTime - (daysAgo * 86400),
        }
    end

    describe("CompactToDailySummaries", function()
        it("does not compact records within 30 days", function()
            table.insert(guildData.transactions, txRecord(10))
            table.insert(guildData.transactions, txRecord(25))

            GBL:CompactToDailySummaries(guildData)

            assert.equals(2, #guildData.transactions)
        end)

        it("compacts records older than 30 days to daily summaries", function()
            table.insert(guildData.transactions, txRecord(5))   -- keep
            table.insert(guildData.transactions, txRecord(35))  -- compact
            table.insert(guildData.transactions, txRecord(40))  -- compact

            GBL:CompactToDailySummaries(guildData)

            assert.equals(1, #guildData.transactions)

            -- Should have created daily summaries
            local count = 0
            for _ in pairs(guildData.dailySummaries) do count = count + 1 end
            assert.equals(2, count)
        end)

        it("aggregates item counts correctly in daily summary", function()
            -- Two withdrawals on the same day, same item
            local ts = MockWoW.serverTime - (35 * 86400)
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Thrall",
                itemID = 111, count = 5, tab = 1, timestamp = ts,
            })
            table.insert(guildData.transactions, {
                type = "withdraw", player = "Jaina",
                itemID = 111, count = 3, tab = 1, timestamp = ts + 100,
            })

            GBL:CompactToDailySummaries(guildData)

            local dateKey = GBL:GetDateKey(ts)
            local summary = guildData.dailySummaries[dateKey]
            assert.is_not_nil(summary)
            assert.equals(8, summary.itemWithdrawals[111])
            assert.equals(2, summary.txCount)
            assert.is_true(summary.players["Thrall"])
            assert.is_true(summary.players["Jaina"])
        end)

        it("aggregates money amounts correctly", function()
            local ts = MockWoW.serverTime - (35 * 86400)
            table.insert(guildData.moneyTransactions, {
                type = "deposit", player = "Thrall",
                amount = 100000, timestamp = ts,
            })
            table.insert(guildData.moneyTransactions, {
                type = "withdraw", player = "Jaina",
                amount = 30000, timestamp = ts + 50,
            })

            GBL:CompactToDailySummaries(guildData)

            assert.equals(0, #guildData.moneyTransactions)
            local dateKey = GBL:GetDateKey(ts)
            local summary = guildData.dailySummaries[dateKey]
            assert.is_not_nil(summary)
            assert.equals(100000, summary.moneyDeposited)
            assert.equals(30000, summary.moneyWithdrawn)
        end)
    end)

    describe("CompactToWeeklySummaries", function()
        it("compacts daily summaries older than 90 days to weekly", function()
            -- Create a daily summary 100 days ago
            local ts = MockWoW.serverTime - (100 * 86400)
            local dateKey = GBL:GetDateKey(ts)
            guildData.dailySummaries[dateKey] = {
                date = dateKey,
                itemDeposits = { [111] = 10 },
                itemWithdrawals = { [222] = 5 },
                moneyDeposited = 50000,
                moneyWithdrawn = 10000,
                txCount = 4,
                players = { Thrall = true },
            }

            -- Create a daily summary 60 days ago (should NOT compact)
            local ts2 = MockWoW.serverTime - (60 * 86400)
            local dateKey2 = GBL:GetDateKey(ts2)
            guildData.dailySummaries[dateKey2] = {
                date = dateKey2,
                itemDeposits = {},
                itemWithdrawals = {},
                moneyDeposited = 0,
                moneyWithdrawn = 0,
                txCount = 1,
                players = { Jaina = true },
            }

            GBL:CompactToWeeklySummaries(guildData)

            -- Old daily should be removed, recent should remain
            assert.is_nil(guildData.dailySummaries[dateKey])
            assert.is_not_nil(guildData.dailySummaries[dateKey2])

            -- Weekly summary should exist
            local weeklyCount = 0
            for _, weekly in pairs(guildData.weeklySummaries) do
                weeklyCount = weeklyCount + 1
                assert.equals(4, weekly.txCount)
                assert.equals(10, weekly.itemDeposits[111])
                assert.equals(50000, weekly.moneyDeposited)
            end
            assert.equals(1, weeklyCount)
        end)

        it("aggregates multiple daily summaries into one weekly", function()
            -- Two daily summaries in the same ISO week, 95 days ago
            local ts1 = MockWoW.serverTime - (95 * 86400)
            local ts2 = ts1 + 86400  -- next day

            local dk1 = GBL:GetDateKey(ts1)
            local dk2 = GBL:GetDateKey(ts2)

            guildData.dailySummaries[dk1] = {
                date = dk1,
                itemDeposits = { [111] = 3 },
                itemWithdrawals = {},
                moneyDeposited = 0, moneyWithdrawn = 0,
                txCount = 1, players = { Thrall = true },
            }
            guildData.dailySummaries[dk2] = {
                date = dk2,
                itemDeposits = { [111] = 7 },
                itemWithdrawals = {},
                moneyDeposited = 0, moneyWithdrawn = 0,
                txCount = 2, players = { Jaina = true },
            }

            GBL:CompactToWeeklySummaries(guildData)

            assert.is_nil(guildData.dailySummaries[dk1])
            assert.is_nil(guildData.dailySummaries[dk2])

            -- Find the weekly summary
            local found = false
            for _, weekly in pairs(guildData.weeklySummaries) do
                if weekly.itemDeposits[111] then
                    assert.equals(10, weekly.itemDeposits[111])
                    assert.equals(3, weekly.txCount)
                    assert.is_true(weekly.players["Thrall"])
                    assert.is_true(weekly.players["Jaina"])
                    found = true
                end
            end
            assert.is_true(found, "Expected a weekly summary with aggregated data")
        end)
    end)

    describe("RunCompaction", function()
        it("removes compacted records from transactions array", function()
            table.insert(guildData.transactions, txRecord(5))
            table.insert(guildData.transactions, txRecord(35))
            guildData.seenTxHashes["old"] = MockWoW.serverTime - (100 * 86400)

            GBL:RunCompaction(guildData)

            assert.equals(1, #guildData.transactions)
            -- Old hash should be pruned
            assert.is_nil(guildData.seenTxHashes["old"])
        end)

        it("is idempotent", function()
            table.insert(guildData.transactions, txRecord(35))

            GBL:RunCompaction(guildData)
            local stats1 = GBL:GetStorageStats(guildData)

            GBL:RunCompaction(guildData)
            local stats2 = GBL:GetStorageStats(guildData)

            assert.same(stats1, stats2)
        end)

        it("handles empty transaction list", function()
            GBL:RunCompaction(guildData)
            assert.equals(0, #guildData.transactions)
            assert.equals(0, #guildData.moneyTransactions)
        end)
    end)

    describe("GetStorageStats", function()
        it("returns correct counts", function()
            table.insert(guildData.transactions, txRecord(1))
            table.insert(guildData.transactions, txRecord(2))
            table.insert(guildData.moneyTransactions, moneyTxRecord(1))
            guildData.seenTxHashes["hash1"] = MockWoW.serverTime

            local stats = GBL:GetStorageStats(guildData)
            assert.equals(2, stats.transactions)
            assert.equals(1, stats.moneyTransactions)
            assert.equals(0, stats.dailySummaries)
            assert.equals(0, stats.weeklySummaries)
            assert.equals(1, stats.seenHashes)
        end)
    end)

    describe("PurgeOldData", function()
        it("removes data older than threshold", function()
            table.insert(guildData.transactions, txRecord(5))
            table.insert(guildData.transactions, txRecord(15))
            table.insert(guildData.moneyTransactions, moneyTxRecord(5))
            table.insert(guildData.moneyTransactions, moneyTxRecord(15))

            GBL:PurgeOldData(10, guildData)

            assert.equals(1, #guildData.transactions)
            assert.equals(1, #guildData.moneyTransactions)
        end)

        it("preserves recent weekly summaries when purging", function()
            -- Add a recent weekly summary (should survive purge)
            local recentWeek = GBL:GetWeekKey(MockWoW.serverTime - (7 * 86400))
            guildData.weeklySummaries[recentWeek] = {
                week = recentWeek,
                itemDeposits = {}, itemWithdrawals = {},
                moneyDeposited = 0, moneyWithdrawn = 0,
                txCount = 3, players = {},
            }

            -- Add an old weekly summary (should be purged)
            local oldWeek = GBL:GetWeekKey(MockWoW.serverTime - (200 * 86400))
            guildData.weeklySummaries[oldWeek] = {
                week = oldWeek,
                itemDeposits = {}, itemWithdrawals = {},
                moneyDeposited = 0, moneyWithdrawn = 0,
                txCount = 5, players = {},
            }

            GBL:PurgeOldData(30, guildData)

            assert.is_not_nil(guildData.weeklySummaries[recentWeek])
            assert.is_nil(guildData.weeklySummaries[oldWeek])
        end)
    end)
end)
