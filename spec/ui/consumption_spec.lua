------------------------------------------------------------------------
-- consumption_spec.lua — Tests for UI/ConsumptionView.lua aggregation logic
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local GBL

--- Build a test transaction record with overrides.
local function makeTx(overrides)
    local rec = {
        id = "hash",
        type = "withdraw",
        player = "Alice",
        itemLink = Helpers.makeItemLink(100, "Test Item", 1),
        itemID = 100,
        count = 1,
        tab = 1,
        category = "flask",
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

describe("ConsumptionView", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("FormatMoney", function()
        it("formats gold, silver, and copper", function()
            assert.equals("1g 23s 45c", GBL:FormatMoney(12345))
        end)

        it("formats gold only", function()
            assert.equals("5g", GBL:FormatMoney(50000))
        end)

        it("formats zero as 0c", function()
            assert.equals("0c", GBL:FormatMoney(0))
        end)

        it("formats nil as 0c", function()
            assert.equals("0c", GBL:FormatMoney(nil))
        end)

        it("formats negative amounts", function()
            assert.equals("-1g 50s", GBL:FormatMoney(-15000))
        end)
    end)

    describe("BuildConsumptionSummary", function()
        it("aggregates withdrawal counts correctly", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", count = 5 }),
                makeTx({ player = "Alice", type = "withdraw", count = 3 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1, #summary)
            assert.equals("Alice", summary[1].player)
            assert.equals(8, summary[1].totalWithdrawn)
        end)

        it("aggregates deposit counts correctly", function()
            local txns = {
                makeTx({ player = "Alice", type = "deposit", count = 10 }),
                makeTx({ player = "Alice", type = "deposit", count = 5 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(15, summary[1].totalDeposited)
        end)

        it("calculates net as deposited minus withdrawn", function()
            local txns = {
                makeTx({ player = "Alice", type = "deposit", count = 10 }),
                makeTx({ player = "Alice", type = "withdraw", count = 3 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(7, summary[1].net)  -- 10 - 3
        end)

        it("selects top 3 items by total activity", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 1, count = 10 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 2, count = 20 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 3, count = 5 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 4, count = 15 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            local topItems = summary[1].topItems
            assert.equals(3, #topItems)
            -- Sorted by count descending: 20, 15, 10
            assert.equals(2, topItems[1].itemID)
            assert.equals(4, topItems[2].itemID)
            assert.equals(1, topItems[3].itemID)
        end)

        it("handles player with only deposits (zero withdrawals)", function()
            local txns = {
                makeTx({ player = "Banker", type = "deposit", count = 50 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(0, summary[1].totalWithdrawn)
            assert.equals(50, summary[1].totalDeposited)
            assert.equals(50, summary[1].net)
        end)

        it("handles player with only withdrawals (zero deposits)", function()
            local txns = {
                makeTx({ player = "Consumer", type = "withdraw", count = 20 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(20, summary[1].totalWithdrawn)
            assert.equals(0, summary[1].totalDeposited)
            assert.equals(-20, summary[1].net)
        end)

        it("tracks lastActive timestamp", function()
            local txns = {
                makeTx({ player = "Alice", timestamp = 1000 }),
                makeTx({ player = "Alice", timestamp = 3000 }),
                makeTx({ player = "Alice", timestamp = 2000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(3000, summary[1].lastActive)
        end)

        it("returns empty for nil transactions", function()
            local summary = GBL:BuildConsumptionSummary(nil)
            assert.equals(0, #summary)
        end)
    end)

    describe("SortConsumptionSummary", function()
        it("sorts by totalWithdrawn descending", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", count = 5 }),
                makeTx({ player = "Bob", type = "withdraw", count = 20 }),
                makeTx({ player = "Charlie", type = "withdraw", count = 10 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            GBL:SortConsumptionSummary(summary, "totalWithdrawn", false)
            assert.equals("Bob", summary[1].player)
            assert.equals("Charlie", summary[2].player)
            assert.equals("Alice", summary[3].player)
        end)

        it("sorts by net ascending", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", count = 10 }),
                makeTx({ player = "Bob", type = "deposit", count = 5 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            GBL:SortConsumptionSummary(summary, "net", true)
            -- Alice: net = -10, Bob: net = 5
            assert.equals("Alice", summary[1].player)
            assert.equals("Bob", summary[2].player)
        end)

        it("sorts by player name ascending (case-insensitive)", function()
            local txns = {
                makeTx({ player = "Charlie" }),
                makeTx({ player = "alice" }),
                makeTx({ player = "Bob" }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            GBL:SortConsumptionSummary(summary, "player", true)
            assert.equals("alice", summary[1].player)
            assert.equals("Bob", summary[2].player)
            assert.equals("Charlie", summary[3].player)
        end)
    end)

    describe("GetPlayerItemBreakdown", function()
        it("returns per-item withdrawn/deposited for a player", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5 }),
                makeTx({ player = "Alice", type = "deposit", itemID = 100, count = 2 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 3 }),
                makeTx({ player = "Bob", type = "withdraw", itemID = 100, count = 99 }),
            }
            local breakdown = GBL:GetPlayerItemBreakdown(txns, "Alice")
            assert.equals(5, breakdown[100].withdrawn)
            assert.equals(2, breakdown[100].deposited)
            assert.equals(3, breakdown[200].withdrawn)
            -- Bob's transactions excluded — Alice's withdrawn is 5, not 99+5
            assert.equals(5, breakdown[100].withdrawn)
        end)

        it("returns empty for unknown player", function()
            local txns = { makeTx({ player = "Alice" }) }
            local breakdown = GBL:GetPlayerItemBreakdown(txns, "Nobody")
            local count = 0
            for _ in pairs(breakdown) do count = count + 1 end
            assert.equals(0, count)
        end)
    end)
end)
