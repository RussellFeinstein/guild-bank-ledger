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
            assert.equals("Thrall", rec.player)
            assert.equals(54321, rec.itemID)
            assert.equals(5, rec.count)
            assert.equals(1, rec.tab)
            assert.is_nil(rec.destTab)
            assert.equals(0, rec.classID)
            assert.equals(1, rec.subclassID)
            assert.equals("consumable", rec.category)
            assert.equals(MockWoW.serverTime - 3600, rec.timestamp)
            assert.equals(MockWoW.serverTime, rec.scanTime)
            assert.equals("TestOfficer", rec.scannedBy)
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
            assert.equals("Thrall", rec.player)
            assert.equals(500000, rec.amount)
            assert.equals(MockWoW.serverTime - 7200, rec.timestamp)
            assert.equals(MockWoW.serverTime, rec.scanTime)
            assert.equals("TestOfficer", rec.scannedBy)
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
end)
