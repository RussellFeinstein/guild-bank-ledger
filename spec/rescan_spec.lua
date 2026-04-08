--- rescan_spec.lua — Tests for periodic transaction log re-scan

local Helpers = require("spec.helpers")

describe("Periodic Rescan", function()
    local GBL
    local MockWoW

    before_each(function()
        Helpers.setupMocks()
        MockWoW = Helpers.MockWoW
        MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        GBL.bankOpen = true
        GBL._initialScanComplete = true
    end)

    describe("RescanTransactionLogs", function()
        it("queries all item tabs plus money tab 9", function()
            MockWoW.guildBank.numTabs = 3
            MockWoW.guildBank.queriedLogs = {}

            GBL:RescanTransactionLogs(function() end)

            assert.is_true(MockWoW.guildBank.queriedLogs[1])
            assert.is_true(MockWoW.guildBank.queriedLogs[2])
            assert.is_true(MockWoW.guildBank.queriedLogs[3])
            assert.is_true(MockWoW.guildBank.queriedLogs[9])
        end)

        it("returns correct new count for money transactions", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
                Helpers.makeMoneyTransaction("repair", "Raider2", 30000, 0),
            })

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(2, result)
        end)

        it("returns correct new count for item transactions", function()
            MockWoW.guildBank.numTabs = 1
            local link = Helpers.makeItemLink(12345, "Flask", 1)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("withdraw", "Raider1", link, 5, 1, nil, 0),
                Helpers.makeTransaction("withdraw", "Raider2", link, 3, 1, nil, 1),
            })

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(2, result)
        end)

        it("returns combined count for items and money", function()
            MockWoW.guildBank.numTabs = 1
            local link = Helpers.makeItemLink(12345, "Flask", 1)
            Helpers.addTabTransactions(1, {
                Helpers.makeTransaction("deposit", "Officer1", link, 10, 1, nil, 0),
            })
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(2, result)
        end)

        it("deduplicates existing entries", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            -- First scan stores them
            local guildData = GBL:GetGuildData()
            GBL:ReadAllTransactions(guildData)

            -- Second scan via rescan should find 0 new
            local result
            GBL:RescanTransactionLogs(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(0, result)
        end)

        it("bails when bank is closed", function()
            GBL.bankOpen = false
            MockWoW.guildBank.queriedLogs = {}

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)

            assert.equals(0, result)
            assert.is_nil(MockWoW.guildBank.queriedLogs[9])
        end)

        it("bails if bank closes during 0.5s delay", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)

            -- Close bank before timer fires
            GBL.bankOpen = false
            MockWoW.fireTimers()

            assert.equals(0, result)
        end)

        it("bails if guild data is nil", function()
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil

            local result
            GBL:RescanTransactionLogs(function(count) result = count end)

            assert.equals(0, result)
        end)
    end)

    describe("StartPeriodicRescan", function()
        it("schedules timer when bank is open", function()
            GBL:StartPeriodicRescan()

            assert.is_true(GBL:IsPeriodicRescanActive())
        end)

        it("is no-op if initial scan not yet complete", function()
            GBL._initialScanComplete = false

            GBL:StartPeriodicRescan()

            assert.is_false(GBL:IsPeriodicRescanActive())
        end)

        it("is no-op if already running (idempotent)", function()
            GBL:StartPeriodicRescan()
            assert.is_true(GBL:IsPeriodicRescanActive())

            -- Call again — should not error or change state
            GBL:StartPeriodicRescan()

            assert.is_true(GBL:IsPeriodicRescanActive())
        end)

        it("is no-op when rescanEnabled is false", function()
            GBL.db.profile.scanning.rescanEnabled = false

            GBL:StartPeriodicRescan()

            assert.is_false(GBL:IsPeriodicRescanActive())
        end)

        it("is no-op when bank is closed", function()
            GBL.bankOpen = false

            GBL:StartPeriodicRescan()

            assert.is_false(GBL:IsPeriodicRescanActive())
        end)
    end)

    describe("StopPeriodicRescan", function()
        it("cancels the timer", function()
            GBL:StartPeriodicRescan()
            assert.is_true(GBL:IsPeriodicRescanActive())

            GBL:StopPeriodicRescan()

            assert.is_false(GBL:IsPeriodicRescanActive())
        end)

        it("is safe when not running", function()
            assert.has_no.errors(function()
                GBL:StopPeriodicRescan()
            end)
            assert.is_false(GBL:IsPeriodicRescanActive())
        end)

        it("sets _rescanActive to false", function()
            GBL:StartPeriodicRescan()
            assert.is_true(GBL._rescanActive)

            GBL:StopPeriodicRescan()
            assert.is_false(GBL._rescanActive)
        end)
    end)

    describe("periodic tick behavior", function()
        it("does NOT run compaction", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            local compactionCalled = false
            local origCompaction = GBL.RunCompaction
            GBL.RunCompaction = function() compactionCalled = true end

            GBL:StartPeriodicRescan()
            MockWoW.fireTimers()  -- interval tick
            MockWoW.fireTimers()  -- 0.5s delay

            GBL.RunCompaction = origCompaction
            assert.is_false(compactionCalled)
        end)

        it("refreshes UI only when new transactions found", function()
            MockWoW.guildBank.numTabs = 1

            local refreshCount = 0
            local origRefresh = GBL.RefreshUI
            GBL.RefreshUI = function() refreshCount = refreshCount + 1 end

            -- First tick: no transactions -> no refresh
            Helpers.addMoneyTransactions({})
            GBL:StartPeriodicRescan()
            MockWoW.fireTimers()  -- interval tick
            MockWoW.fireTimers()  -- 0.5s delay
            assert.equals(0, refreshCount)

            -- Second tick: add money transactions -> refresh
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })
            MockWoW.fireTimers()  -- next interval tick
            MockWoW.fireTimers()  -- 0.5s delay
            assert.equals(1, refreshCount)

            GBL.RefreshUI = origRefresh
        end)

        it("stops when rescanEnabled toggled off mid-tick", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({})

            GBL:StartPeriodicRescan()
            assert.is_true(GBL:IsPeriodicRescanActive())

            -- Disable before tick fires
            GBL.db.profile.scanning.rescanEnabled = false
            MockWoW.fireTimers()  -- interval tick (bails due to rescanEnabled=false)

            assert.is_false(GBL:IsPeriodicRescanActive())
        end)

        it("survives an error in ReadAllTransactions and schedules next tick", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            local origRead = GBL.ReadAllTransactions
            GBL.ReadAllTransactions = function() error("test explosion") end

            GBL:StartPeriodicRescan()
            MockWoW.fireTimers()  -- interval tick
            MockWoW.fireTimers()  -- 0.5s delay (error occurs here, caught by pcall)

            -- Should still be active (next tick scheduled)
            assert.is_true(GBL:IsPeriodicRescanActive())
            -- Verify a new timer was queued
            assert.is_true(#MockWoW.pendingTimers > 0)

            GBL.ReadAllTransactions = origRead
        end)
    end)

    describe("lifecycle integration", function()
        it("OnBankClosed stops periodic rescan", function()
            GBL:OnEnable()

            GBL:StartPeriodicRescan()
            assert.is_true(GBL:IsPeriodicRescanActive())

            GBL:OnBankClosed()
            assert.is_false(GBL:IsPeriodicRescanActive())
        end)
    end)
end)
