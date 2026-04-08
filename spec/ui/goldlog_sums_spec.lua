------------------------------------------------------------------------
-- goldlog_sums_spec.lua — Tests for ComputeGoldLogSums aggregation
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local GBL

--- Build a money transaction record with overrides.
local function makeMoneyTx(overrides)
    local rec = {
        id = "moneyhash",
        type = "deposit",
        player = "Alice",
        amount = 500000,  -- 50g
        timestamp = MockWoW.serverTime - 3600,
        scanTime = MockWoW.serverTime,
        scannedBy = "TestOfficer",
    }
    if overrides then
        for k, v in pairs(overrides) do
            rec[k] = v
        end
    end
    return rec
end

describe("ComputeGoldLogSums", function()
    before_each(function()
        Helpers.setupMocks()
        MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    it("returns zeros for empty array", function()
        local sums = GBL:ComputeGoldLogSums({})
        assert.equals(0, sums.totalDeposited)
        assert.equals(0, sums.totalWithdrawn)
        assert.equals(0, sums.net)
    end)

    it("returns zeros for nil input", function()
        local sums = GBL:ComputeGoldLogSums(nil)
        assert.equals(0, sums.totalDeposited)
        assert.equals(0, sums.totalWithdrawn)
        assert.equals(0, sums.net)
    end)

    it("sums deposits", function()
        local txns = {
            makeMoneyTx({ type = "deposit", amount = 500000 }),
            makeMoneyTx({ type = "deposit", amount = 300000, player = "Bob" }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(800000, sums.totalDeposited)
        assert.equals(0, sums.totalWithdrawn)
        assert.equals(800000, sums.net)
    end)

    it("sums withdrawals", function()
        local txns = {
            makeMoneyTx({ type = "withdraw", amount = 200000 }),
            makeMoneyTx({ type = "withdraw", amount = 100000, player = "Bob" }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(0, sums.totalDeposited)
        assert.equals(300000, sums.totalWithdrawn)
        assert.equals(-300000, sums.net)
    end)

    it("counts repair as withdrawal with per-type field", function()
        local txns = {
            makeMoneyTx({ type = "repair", amount = 75000 }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(75000, sums.totalWithdrawn)
        assert.equals(75000, sums.repair)
        assert.equals(0, sums.withdraw)
        assert.equals(-75000, sums.net)
    end)

    it("counts buyTab as withdrawal with per-type field", function()
        local txns = {
            makeMoneyTx({ type = "buyTab", amount = 1000000 }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(1000000, sums.totalWithdrawn)
        assert.equals(1000000, sums.buyTab)
        assert.equals(0, sums.withdraw)
        assert.equals(-1000000, sums.net)
    end)

    it("counts depositSummary as deposit with per-type field", function()
        local txns = {
            makeMoneyTx({ type = "depositSummary", amount = 250000 }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(250000, sums.totalDeposited)
        assert.equals(250000, sums.depositSummary)
        assert.equals(0, sums.deposit)
        assert.equals(250000, sums.net)
    end)

    it("computes correct per-type and total fields for mixed types", function()
        local txns = {
            makeMoneyTx({ type = "deposit", amount = 1000000 }),      -- +100g
            makeMoneyTx({ type = "withdraw", amount = 300000 }),      -- -30g
            makeMoneyTx({ type = "repair", amount = 150000 }),        -- -15g
            makeMoneyTx({ type = "depositSummary", amount = 200000 }),-- +20g
            makeMoneyTx({ type = "buyTab", amount = 500000 }),        -- -50g
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        -- Per-type fields
        assert.equals(1000000, sums.deposit)
        assert.equals(200000, sums.depositSummary)
        assert.equals(300000, sums.withdraw)
        assert.equals(150000, sums.repair)
        assert.equals(500000, sums.buyTab)
        -- Totals
        assert.equals(1200000, sums.totalDeposited)   -- 100g + 20g
        assert.equals(950000, sums.totalWithdrawn)     -- 30g + 15g + 50g
        assert.equals(250000, sums.net)                -- +25g
    end)

    it("treats zero-amount transactions as zero", function()
        local txns = {
            makeMoneyTx({ type = "deposit", amount = 0 }),
            makeMoneyTx({ type = "withdraw", amount = 0 }),
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(0, sums.totalDeposited)
        assert.equals(0, sums.totalWithdrawn)
        assert.equals(0, sums.net)
    end)

    it("treats nil amount as zero", function()
        local txns = {
            { id = "m1", type = "deposit", player = "Alice", timestamp = 100 },
        }
        local sums = GBL:ComputeGoldLogSums(txns)
        assert.equals(0, sums.totalDeposited)
        assert.equals(0, sums.net)
    end)
end)
