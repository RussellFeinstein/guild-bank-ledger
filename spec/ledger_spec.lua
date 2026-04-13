--- ledger_spec.lua — Tests for Ledger module

local Helpers = require("spec.helpers")

describe("Ledger", function()
    local GBL
    local MockWoW

    before_each(function()
        Helpers.setupMocks()
        MockWoW = Helpers.MockWoW
        MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("ComputeAbsoluteTimestamp", function()
        it("converts hour offset correctly", function()
            local ts = GBL:ComputeAbsoluteTimestamp(0, 0, 0, 2)
            assert.equals(MockWoW.serverTime - 7200, ts)
        end)

        it("converts day and hour offsets", function()
            local ts = GBL:ComputeAbsoluteTimestamp(0, 0, 3, 5)
            local expected = MockWoW.serverTime - (3 * 86400) - (5 * 3600)
            assert.equals(expected, ts)
        end)

        it("converts month offset with 30-day approximation", function()
            local ts = GBL:ComputeAbsoluteTimestamp(0, 2, 0, 0)
            local expected = MockWoW.serverTime - (2 * 2592000)
            assert.equals(expected, ts)
        end)
    end)

    describe("ExtractItemID", function()
        it("parses itemID from a valid item link", function()
            local link = Helpers.makeItemLink(12345, "Flask of Power", 3)
            assert.equals(12345, GBL:ExtractItemID(link))
        end)

        it("returns nil for invalid link", function()
            assert.is_nil(GBL:ExtractItemID("not a link"))
            assert.is_nil(GBL:ExtractItemID(nil))
            assert.is_nil(GBL:ExtractItemID(42))
        end)
    end)

    describe("CreateTxRecord", function()
        it("builds complete record with category", function()
            local link = Helpers.makeItemLink(54321, "Healing Potion", 2)
            Helpers.setItemInfo(54321, 0, 1)  -- Consumable / Potion

            local rec = GBL:CreateTxRecord("withdraw", "Thrall", link, 5, 1, nil, 0, 0, 0, 1)

            assert.equals("withdraw", rec.type)
            assert.equals("Thrall-TestRealm", rec.player)
            assert.equals(54321, rec.itemID)
            assert.equals(5, rec.count)
            assert.equals(1, rec.tab)
            assert.is_nil(rec.destTab)
            assert.equals(0, rec.classID)
            assert.equals(1, rec.subclassID)
            assert.equals("consumable", rec.category)
            assert.equals(MockWoW.serverTime - 3600, rec.timestamp)
            assert.equals(MockWoW.serverTime, rec.scanTime)
            assert.equals("TestOfficer-TestRealm", rec.scannedBy)
            assert.is_string(rec.id)
        end)

        it("sets destTab for move transactions", function()
            local link = Helpers.makeItemLink(11111, "Ore", 1)
            local rec = GBL:CreateTxRecord("move", "Jaina", link, 20, 1, 3, 0, 0, 0, 0)

            assert.equals("move", rec.type)
            assert.equals(3, rec.destTab)
        end)
    end)

    describe("CreateMoneyTxRecord", function()
        it("builds complete money record", function()
            local rec = GBL:CreateMoneyTxRecord("deposit", "Thrall", 500000, 0, 0, 0, 2)

            assert.equals("deposit", rec.type)
            assert.equals("Thrall-TestRealm", rec.player)
            assert.equals(500000, rec.amount)
            assert.equals(MockWoW.serverTime - 7200, rec.timestamp)
            assert.equals(MockWoW.serverTime, rec.scanTime)
            assert.equals("TestOfficer-TestRealm", rec.scannedBy)
            assert.is_string(rec.id)
        end)
    end)

    describe("StoreTx", function()
        it("stores non-duplicate and rejects duplicate", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(12345, "Flask", 3)
            local rec = GBL:CreateTxRecord("deposit", "Thrall", link, 5, 1, nil, 0, 0, 0, 0)

            -- First store: success
            assert.is_true(GBL:StoreTx(rec, guildData))
            assert.equals(1, #guildData.transactions)

            -- Second store: duplicate
            assert.is_false(GBL:StoreTx(rec, guildData))
            assert.equals(1, #guildData.transactions)
        end)
    end)

    describe("UpdatePlayerStats", function()
        it("increments deposit counts", function()
            local guildData = GBL:GetGuildData()
            local rec = {
                type = "deposit",
                player = "Thrall",
                itemID = 12345,
                count = 10,
                timestamp = MockWoW.serverTime,
            }

            GBL:UpdatePlayerStats(rec, guildData)
            local stats = guildData.playerStats["Thrall"]

            assert.equals(10, stats.totalDepositCount)
            assert.equals(0, stats.totalWithdrawCount)
            assert.equals(MockWoW.serverTime, stats.firstSeen)
            assert.equals(MockWoW.serverTime, stats.lastSeen)
        end)

        it("increments withdrawal counts and money", function()
            local guildData = GBL:GetGuildData()

            -- Item withdrawal
            GBL:UpdatePlayerStats({
                type = "withdraw", player = "Jaina",
                itemID = 99, count = 3,
                timestamp = MockWoW.serverTime - 100,
            }, guildData)

            -- Money withdrawal
            GBL:UpdatePlayerStats({
                type = "withdraw", player = "Jaina",
                amount = 50000,
                timestamp = MockWoW.serverTime,
            }, guildData)

            local stats = guildData.playerStats["Jaina"]
            assert.equals(3, stats.totalWithdrawCount)
            assert.equals(50000, stats.moneyWithdrawn)
            assert.equals(MockWoW.serverTime - 100, stats.firstSeen)
            assert.equals(MockWoW.serverTime, stats.lastSeen)
        end)

        it("tracks repair as money withdrawal", function()
            local guildData = GBL:GetGuildData()
            GBL:UpdatePlayerStats({
                type = "repair", player = "Thrall",
                amount = 75000,
                timestamp = MockWoW.serverTime,
            }, guildData)
            local stats = guildData.playerStats["Thrall"]
            assert.equals(75000, stats.moneyWithdrawn)
            assert.equals(0, stats.moneyDeposited)
        end)

        it("tracks buyTab as money withdrawal", function()
            local guildData = GBL:GetGuildData()
            GBL:UpdatePlayerStats({
                type = "buyTab", player = "Jaina",
                amount = 1000000,
                timestamp = MockWoW.serverTime,
            }, guildData)
            local stats = guildData.playerStats["Jaina"]
            assert.equals(1000000, stats.moneyWithdrawn)
        end)

        it("tracks depositSummary as money deposit", function()
            local guildData = GBL:GetGuildData()
            GBL:UpdatePlayerStats({
                type = "depositSummary", player = "Thrall",
                amount = 250000,
                timestamp = MockWoW.serverTime,
            }, guildData)
            local stats = guildData.playerStats["Thrall"]
            assert.equals(250000, stats.moneyDeposited)
            assert.equals(0, stats.moneyWithdrawn)
        end)

        it("accumulates all 5 money types correctly", function()
            local guildData = GBL:GetGuildData()
            local player = "Varian"
            GBL:UpdatePlayerStats({ type = "deposit", player = player, amount = 1000000, timestamp = MockWoW.serverTime }, guildData)
            GBL:UpdatePlayerStats({ type = "depositSummary", player = player, amount = 500000, timestamp = MockWoW.serverTime }, guildData)
            GBL:UpdatePlayerStats({ type = "withdraw", player = player, amount = 200000, timestamp = MockWoW.serverTime }, guildData)
            GBL:UpdatePlayerStats({ type = "repair", player = player, amount = 100000, timestamp = MockWoW.serverTime }, guildData)
            GBL:UpdatePlayerStats({ type = "buyTab", player = player, amount = 50000, timestamp = MockWoW.serverTime }, guildData)

            local stats = guildData.playerStats[player]
            assert.equals(1500000, stats.moneyDeposited)
            assert.equals(350000, stats.moneyWithdrawn)
        end)
    end)

    describe("ReadTabTransactions", function()
        it("reads all transactions from a tab", function()
            local guildData = GBL:GetGuildData()
            local link1 = Helpers.makeItemLink(111, "Flask", 3)
            local link2 = Helpers.makeItemLink(222, "Potion", 2)

            MockWoW.addTab("Supplies", "icon", true)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Thrall", link1, 5, 1, nil, 1),
                Helpers.makeTransaction("withdraw", "Jaina", link2, 10, 1, nil, 2),
            })

            local stored = GBL:ReadTabTransactions(1, guildData)

            assert.equals(2, stored)
            assert.equals(2, #guildData.transactions)
            assert.equals("deposit", guildData.transactions[1].type)
            assert.equals("withdraw", guildData.transactions[2].type)
        end)
    end)

    describe("ReadMoneyTransactions", function()
        it("reads money transactions and normalizes 'withdrawal' to 'withdraw'", function()
            local guildData = GBL:GetGuildData()

            -- WoW API returns "withdrawal" (not "withdraw") for money
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 2),
                Helpers.makeMoneyTransaction("withdrawal", "Alice", 100000, 3),
            })

            local stored = GBL:ReadMoneyTransactions(guildData)

            assert.equals(3, stored)
            assert.equals(3, #guildData.moneyTransactions)
            assert.equals("deposit", guildData.moneyTransactions[1].type)
            assert.equals(500000, guildData.moneyTransactions[1].amount)
            assert.equals("Alice-TestRealm", guildData.moneyTransactions[1].player)
            assert.equals("repair", guildData.moneyTransactions[2].type)
            -- "withdrawal" from API is normalized to "withdraw" in storage
            assert.equals("withdraw", guildData.moneyTransactions[3].type)
            assert.equals(100000, guildData.moneyTransactions[3].amount)
        end)

        it("updates player stats for money transactions", function()
            local guildData = GBL:GetGuildData()

            -- Use "withdrawal" as WoW API returns it
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
                Helpers.makeMoneyTransaction("repair", "Alice", 75000, 2),
            })

            GBL:ReadMoneyTransactions(guildData)

            local stats = guildData.playerStats["Alice-TestRealm"]
            assert.equals(500000, stats.moneyDeposited)
            assert.equals(75000, stats.moneyWithdrawn)
        end)

        it("normalizes 'withdrawal' so consumption summary sees money withdrawals", function()
            local guildData = GBL:GetGuildData()

            -- "withdrawal" is what WoW actually returns for money withdrawals
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
                Helpers.makeMoneyTransaction("withdrawal", "Alice", 200000, 2),
            })

            GBL:ReadMoneyTransactions(guildData)

            -- Merge for consumption (same as SelectTab does)
            local allTx = {}
            for i = 1, #guildData.moneyTransactions do
                allTx[#allTx + 1] = guildData.moneyTransactions[i]
            end

            local summaries = GBL:BuildConsumptionSummary(allTx)
            assert.equals(1, #summaries)
            assert.equals(500000, summaries[1].moneyDeposited)
            assert.equals(200000, summaries[1].moneyWithdrawn)
            assert.equals(300000, summaries[1].moneyNet)
        end)
    end)

    describe("ReadTabTransactions — rescan dedup", function()
        it("rescan with same batch produces 0 new records", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(111, "Flask", 3)

            MockWoW.addTab("Supplies", "icon", true)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Thrall", link, 5, 1, nil, 1),
            })

            -- Initial scan
            local stored1 = GBL:ReadTabTransactions(1, guildData)
            assert.equals(1, stored1)

            -- Rescan with same batch
            local stored2 = GBL:ReadTabTransactions(1, guildData)
            assert.equals(0, stored2)
            assert.equals(1, #guildData.transactions)
        end)

        it("rescan detects new same-slot record (the v0.14 bug)", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(111, "Flask", 3)

            MockWoW.addTab("Supplies", "icon", true)
            -- Same player, same item, same count, same tab, same hour offset
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("withdraw", "Jaina", link, 20, 1, nil, 0),
            })

            -- Initial scan: 1 record
            local stored1 = GBL:ReadTabTransactions(1, guildData)
            assert.equals(1, stored1)

            -- New identical transaction appears (WoW API prepends newest first)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("withdraw", "Jaina", link, 20, 1, nil, 0),
                Helpers.makeTransaction("withdraw", "Jaina", link, 20, 1, nil, 0),
            })

            -- Rescan: should detect exactly 1 new record, not create duplicates
            local stored2 = GBL:ReadTabTransactions(1, guildData)
            assert.equals(1, stored2)
            assert.equals(2, #guildData.transactions)
        end)

        it("bank close resets cache so next bank open starts fresh", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(111, "Flask", 3)

            MockWoW.addTab("Supplies", "icon", true)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Thrall", link, 5, 1, nil, 1),
            })

            -- Initial scan
            GBL:ReadTabTransactions(1, guildData)

            -- Simulate bank close
            GBL._lastTabBatchCounts = {}
            GBL._lastMoneyBatchCounts = nil

            -- Re-open: initial scan again, should dedup against seenTxHashes
            local stored = GBL:ReadTabTransactions(1, guildData)
            assert.equals(0, stored)
            assert.equals(1, #guildData.transactions)
        end)
    end)

    describe("ReadMoneyTransactions — rescan dedup", function()
        it("rescan with same batch produces 0 new records", function()
            local guildData = GBL:GetGuildData()

            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
            })

            local stored1 = GBL:ReadMoneyTransactions(guildData)
            assert.equals(1, stored1)

            local stored2 = GBL:ReadMoneyTransactions(guildData)
            assert.equals(0, stored2)
            assert.equals(1, #guildData.moneyTransactions)
        end)

        it("rescan detects new same-slot money record", function()
            local guildData = GBL:GetGuildData()

            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 0),
            })

            local stored1 = GBL:ReadMoneyTransactions(guildData)
            assert.equals(1, stored1)

            -- New identical repair appears
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 0),
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 0),
            })

            local stored2 = GBL:ReadMoneyTransactions(guildData)
            assert.equals(1, stored2)
            assert.equals(2, #guildData.moneyTransactions)
        end)
    end)

    describe("ReadAllTransactions — end-to-end with money", function()
        it("reads both item and money transactions", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(111, "Flask", 3)

            MockWoW.addTab("Supplies", "icon", true)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Alice", link, 5, 1, nil, 1),
            })
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 2),
            })

            local totalStored = GBL:ReadAllTransactions(guildData)

            assert.equals(3, totalStored)
            assert.equals(1, #guildData.transactions)
            assert.equals(2, #guildData.moneyTransactions)
        end)

        it("consumption summary shows non-zero gold from stored money tx", function()
            local guildData = GBL:GetGuildData()
            local link = Helpers.makeItemLink(111, "Flask", 3)

            MockWoW.addTab("Supplies", "icon", true)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("withdraw", "Alice", link, 5, 1, nil, 1),
            })
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("deposit", "Alice", 500000, 1),
                Helpers.makeMoneyTransaction("repair", "Bob", 75000, 2),
            })

            GBL:ReadAllTransactions(guildData)

            -- Merge item + money transactions (same as SelectTab does)
            local allTx = {}
            for i = 1, #guildData.transactions do
                allTx[#allTx + 1] = guildData.transactions[i]
            end
            for i = 1, #guildData.moneyTransactions do
                allTx[#allTx + 1] = guildData.moneyTransactions[i]
            end

            local summaries = GBL:BuildConsumptionSummary(allTx)

            -- Find Alice and Bob
            local alice, bob
            for _, s in ipairs(summaries) do
                if s.player == "Alice-TestRealm" then alice = s end
                if s.player == "Bob-TestRealm" then bob = s end
            end

            assert.is_not_nil(alice)
            assert.equals(500000, alice.moneyDeposited)
            assert.equals(0, alice.moneyWithdrawn)
            assert.equals(500000, alice.moneyNet)

            assert.is_not_nil(bob)
            assert.equals(75000, bob.moneyWithdrawn)
            assert.equals(-75000, bob.moneyNet)
        end)
    end)
end)
