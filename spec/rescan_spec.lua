--- rescan_spec.lua — Tests for periodic money log re-scan

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

    describe("RescanMoneyLog", function()
        it("queries money tab 9", function()
            MockWoW.guildBank.numTabs = 2
            MockWoW.guildBank.queriedLogs = {}

            GBL:RescanMoneyLog(function() end)

            assert.is_true(MockWoW.guildBank.queriedLogs[9])
            -- Should NOT query item tabs
            assert.is_nil(MockWoW.guildBank.queriedLogs[1])
            assert.is_nil(MockWoW.guildBank.queriedLogs[2])
        end)

        it("returns correct new count", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
                Helpers.makeMoneyTransaction("repair", "Raider2", 30000, 0),
            })

            local result
            GBL:RescanMoneyLog(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(2, result)
        end)

        it("deduplicates existing entries", function()
            MockWoW.guildBank.numTabs = 1
            local txs = {
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            }
            Helpers.addMoneyTransactions(txs)

            -- First scan stores them
            local guildData = GBL:GetGuildData()
            GBL:ReadMoneyTransactions(guildData)

            -- Second scan via rescan should find 0 new
            local result
            GBL:RescanMoneyLog(function(count) result = count end)
            MockWoW.fireTimers()

            assert.equals(0, result)
        end)

        it("bails when bank is closed", function()
            GBL.bankOpen = false
            MockWoW.guildBank.queriedLogs = {}

            local result
            GBL:RescanMoneyLog(function(count) result = count end)

            assert.equals(0, result)
            assert.is_nil(MockWoW.guildBank.queriedLogs[9])
        end)

        it("bails if bank closes during 0.5s delay", function()
            MockWoW.guildBank.numTabs = 1
            Helpers.addMoneyTransactions({
                Helpers.makeMoneyTransaction("repair", "Raider1", 50000, 0),
            })

            local result
            GBL:RescanMoneyLog(function(count) result = count end)

            -- Close bank before timer fires
            GBL.bankOpen = false
            MockWoW.fireTimers()

            assert.equals(0, result)
        end)

        it("bails if guild data is nil", function()
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil

            local result
            GBL:RescanMoneyLog(function(count) result = count end)

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
            local firstTimer = GBL._rescanTimer

            GBL:StartPeriodicRescan()

            assert.equals(firstTimer, GBL._rescanTimer)
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

            -- First tick: no money transactions -> no refresh
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
            MockWoW.fireTimers()  -- interval tick
            MockWoW.fireTimers()  -- 0.5s delay

            assert.is_nil(GBL._rescanTimer)
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
