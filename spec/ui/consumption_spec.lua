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

        it("respects category filter", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, category = "flask" }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 3, category = "herb" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.category = "flask"
            local breakdown = GBL:GetPlayerItemBreakdown(txns, "Alice", filters)
            assert.equals(5, breakdown[100].withdrawn)
            assert.is_nil(breakdown[200])
        end)
    end)

    describe("ExtractItemName", function()
        it("extracts name from valid WoW item link", function()
            local link = Helpers.makeItemLink(100, "Flask of Power", 3)
            assert.equals("Flask of Power", GBL:ExtractItemName(link, 100))
        end)

        it("returns Item #ID for nil itemLink", function()
            assert.equals("Item #42", GBL:ExtractItemName(nil, 42))
        end)

        it("returns Unknown Item for nil link and nil ID", function()
            assert.equals("Unknown Item", GBL:ExtractItemName(nil, nil))
        end)

        it("returns stripped text for malformed link without brackets", function()
            assert.equals("no brackets here", GBL:ExtractItemName("no brackets here", 99))
        end)
    end)

    describe("GetBreakdownForDisplay", function()
        before_each(function()
            -- Set up item info for category lookup
            Helpers.setItemInfo(100, 0, 3)  -- classID=0 subclassID=3 → flask
            Helpers.setItemInfo(200, 7, 9)  -- classID=7 subclassID=9 → herb
        end)

        it("returns sorted array with category fields", function()
            local breakdown = {
                [100] = { withdrawn = 3, deposited = 1, itemLink = Helpers.makeItemLink(100, "Flask of Power", 3) },
                [200] = { withdrawn = 10, deposited = 0, itemLink = Helpers.makeItemLink(200, "Dreamfoil", 1) },
            }
            local display = GBL:GetBreakdownForDisplay(breakdown)
            assert.equals(2, #display)
            -- Sorted by total desc: Dreamfoil (10) > Flask (4)
            assert.equals(200, display[1].itemID)
            assert.equals("Dreamfoil", display[1].itemName)
            assert.equals("herb", display[1].category)
            assert.equals("Herb", display[1].categoryDisplay)
            assert.equals(10, display[1].withdrawn)
            assert.equals(0, display[1].deposited)
            assert.equals(10, display[1].total)

            assert.equals(100, display[2].itemID)
            assert.equals("Flask of Power", display[2].itemName)
            assert.equals("flask", display[2].category)
            assert.equals("Flask", display[2].categoryDisplay)
        end)

        it("returns empty array for empty breakdown", function()
            local display = GBL:GetBreakdownForDisplay({})
            assert.equals(0, #display)
        end)

        it("returns empty array for nil breakdown", function()
            local display = GBL:GetBreakdownForDisplay(nil)
            assert.equals(0, #display)
        end)

        it("falls back to Item #ID when itemLink is nil", function()
            Helpers.setItemInfo(300, 0, 0)  -- consumable
            local breakdown = {
                [300] = { withdrawn = 5, deposited = 0, itemLink = nil },
            }
            local display = GBL:GetBreakdownForDisplay(breakdown)
            assert.equals(1, #display)
            assert.equals("Item #300", display[1].itemName)
        end)
    end)

    describe("Consumption sort state", function()
        it("toggles direction on same column", function()
            GBL.consumptionSortColumn = "totalWithdrawn"
            GBL.consumptionSortAscending = false

            GBL:SetConsumptionSort("totalWithdrawn")
            assert.equals("totalWithdrawn", GBL.consumptionSortColumn)
            assert.is_true(GBL.consumptionSortAscending)
        end)

        it("switches to ascending on new column", function()
            GBL.consumptionSortColumn = "totalWithdrawn"
            GBL.consumptionSortAscending = false

            GBL:SetConsumptionSort("player")
            assert.equals("player", GBL.consumptionSortColumn)
            assert.is_true(GBL.consumptionSortAscending)
        end)
    end)

    describe("GetConsumptionSortIndicator", function()
        it("returns label with [desc] for active descending column", function()
            GBL.consumptionSortColumn = "totalWithdrawn"
            GBL.consumptionSortAscending = false
            assert.equals("Withdrawn [desc]", GBL:GetConsumptionSortIndicator("totalWithdrawn", "Withdrawn"))
        end)

        it("returns label with [asc] for active ascending column", function()
            GBL.consumptionSortColumn = "player"
            GBL.consumptionSortAscending = true
            assert.equals("Player [asc]", GBL:GetConsumptionSortIndicator("player", "Player"))
        end)

        it("returns plain label for non-active column", function()
            GBL.consumptionSortColumn = "totalWithdrawn"
            assert.equals("Player", GBL:GetConsumptionSortIndicator("player", "Player"))
        end)
    end)

    describe("FormatTopItems", function()
        it("shows only the #1 most active item", function()
            local topItems = {
                { itemID = 1, count = 10, itemLink = Helpers.makeItemLink(1, "Flask", 1) },
                { itemID = 2, count = 5, itemLink = Helpers.makeItemLink(2, "Food", 1) },
                { itemID = 3, count = 3, itemLink = Helpers.makeItemLink(3, "Elixir", 1) },
            }
            assert.equals("Flask", GBL:FormatTopItems(topItems))
        end)

        it("returns empty string for nil topItems", function()
            assert.equals("", GBL:FormatTopItems(nil))
        end)

        it("returns empty string for empty topItems", function()
            assert.equals("", GBL:FormatTopItems({}))
        end)

        it("shows full item name without truncation", function()
            local topItems = {
                { itemID = 1, count = 10, itemLink = Helpers.makeItemLink(1, "Super Long Item Name Here", 1) },
            }
            local result = GBL:FormatTopItems(topItems)
            assert.equals("Super Long Item Name Here", result)
        end)
    end)

    describe("BuildConsumptionSummary with category filter", function()
        it("only counts items matching category filter", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, category = "flask" }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 3, category = "herb" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.category = "flask"
            local summary = GBL:BuildConsumptionSummary(txns, filters)
            assert.equals(1, #summary)
            assert.equals(5, summary[1].totalWithdrawn)
        end)

        it("excludes player entirely when no items match filter", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", category = "flask" }),
                makeTx({ player = "Bob", type = "withdraw", category = "herb" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.category = "herb"
            local summary = GBL:BuildConsumptionSummary(txns, filters)
            assert.equals(1, #summary)
            assert.equals("Bob", summary[1].player)
        end)
    end)

    describe("topItems contains itemLink", function()
        it("preserves itemLink in topItems entries", function()
            local link = Helpers.makeItemLink(100, "Flask of Power", 3)
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, itemLink = link }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1, #summary[1].topItems)
            assert.equals(link, summary[1].topItems[1].itemLink)
        end)
    end)
end)
