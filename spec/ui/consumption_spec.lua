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

    describe("Money transaction aggregation", function()
        --- Build a money-only transaction (no itemID/itemLink/category/tab).
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

        it("aggregates money deposits", function()
            local txns = {
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 500000 }),
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 300000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1, #summary)
            assert.equals(800000, summary[1].moneyDeposited)
            assert.equals(800000, summary[1].moneyNet)
        end)

        it("aggregates repair withdrawals", function()
            local txns = {
                makeMoneyTx({ player = "Alice", type = "repair", amount = 100000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(100000, summary[1].moneyWithdrawn)
            assert.equals(-100000, summary[1].moneyNet)
        end)

        it("aggregates buyTab as withdrawal", function()
            local txns = {
                makeMoneyTx({ player = "Bob", type = "buyTab", amount = 1000000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1000000, summary[1].moneyWithdrawn)
        end)

        it("aggregates depositSummary as deposit", function()
            local txns = {
                makeMoneyTx({ player = "Bob", type = "depositSummary", amount = 200000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(200000, summary[1].moneyDeposited)
        end)

        it("computes correct moneyNet with mixed types", function()
            local txns = {
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 800000 }),
                makeMoneyTx({ player = "Alice", type = "repair", amount = 50000 }),
                makeMoneyTx({ player = "Alice", type = "withdraw", amount = 100000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(800000, summary[1].moneyDeposited)
            assert.equals(150000, summary[1].moneyWithdrawn)
            assert.equals(650000, summary[1].moneyNet)
        end)

        it("merges item + money tx for same player", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5 }),
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 500000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1, #summary)
            assert.equals("Alice", summary[1].player)
            assert.equals(5, summary[1].totalWithdrawn)
            assert.equals(500000, summary[1].moneyDeposited)
        end)

        it("money-only player appears in summary", function()
            local txns = {
                makeMoneyTx({ player = "Banker", type = "deposit", amount = 1000000 }),
            }
            local summary = GBL:BuildConsumptionSummary(txns)
            assert.equals(1, #summary)
            assert.equals("Banker", summary[1].player)
            assert.equals(0, summary[1].netConsumed)
            assert.equals(1000000, summary[1].moneyDeposited)
        end)

        it("money tx passes through FilterTransactions with default filters", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw" }),
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 500000 }),
            }
            local filters = GBL:CreateDefaultFilters()
            local filtered = GBL:FilterTransactions(txns, filters)
            assert.equals(2, #filtered)
        end)

        it("money tx survives category filter", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", category = "flask" }),
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 500000 }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.category = "flask"
            local filtered = GBL:FilterTransactions(txns, filters)
            -- Item tx matches flask, money tx passes (no category = skip check)
            assert.equals(2, #filtered)
        end)
    end)

    ---------------------------------------------------------------------------
    -- BuildGuildTotals
    ---------------------------------------------------------------------------

    describe("BuildGuildTotals", function()
        it("sums items and gold across multiple players", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", count = 5 }),
                makeTx({ player = "Alice", type = "deposit", count = 3 }),
                makeTx({ player = "Bob", type = "withdraw", count = 10 }),
                makeTx({ player = "Bob", type = "deposit", count = 2 }),
            }
            local summaries = GBL:BuildConsumptionSummary(txns)
            local totals = GBL:BuildGuildTotals(summaries)
            assert.equals(2, totals.playerCount)
            assert.equals(5, totals.itemsDeposited)    -- 3 + 2
            assert.equals(15, totals.itemsWithdrawn)   -- 5 + 10
            assert.equals(-10, totals.itemsNet)        -- 5 - 15
        end)

        it("sums gold across players", function()
            local makeMoneyTx = function(overrides)
                local rec = {
                    id = "moneyhash", type = "deposit", player = "Alice",
                    amount = 500000, timestamp = MockWoW.serverTime - 3600,
                    scanTime = MockWoW.serverTime, scannedBy = "TestOfficer",
                }
                if overrides then for k, v in pairs(overrides) do rec[k] = v end end
                return rec
            end
            local txns = {
                makeMoneyTx({ player = "Alice", type = "deposit", amount = 800000 }),
                makeMoneyTx({ player = "Alice", type = "repair", amount = 50000 }),
                makeMoneyTx({ player = "Bob", type = "deposit", amount = 200000 }),
            }
            local summaries = GBL:BuildConsumptionSummary(txns)
            local totals = GBL:BuildGuildTotals(summaries)
            assert.equals(2, totals.playerCount)
            assert.equals(1000000, totals.goldDeposited)  -- 800k + 200k
            assert.equals(50000, totals.goldWithdrawn)     -- 50k repair
            assert.equals(950000, totals.goldNet)          -- 1M - 50k
        end)

        it("returns zeros for empty summaries", function()
            local totals = GBL:BuildGuildTotals({})
            assert.equals(0, totals.playerCount)
            assert.equals(0, totals.itemsDeposited)
            assert.equals(0, totals.itemsWithdrawn)
            assert.equals(0, totals.itemsNet)
            assert.equals(0, totals.goldDeposited)
            assert.equals(0, totals.goldWithdrawn)
            assert.equals(0, totals.goldNet)
        end)

        it("returns zeros for nil summaries", function()
            local totals = GBL:BuildGuildTotals(nil)
            assert.equals(0, totals.playerCount)
        end)

        it("handles gold-only player (no items)", function()
            local makeMoneyTx = function(overrides)
                local rec = {
                    id = "moneyhash", type = "deposit", player = "Banker",
                    amount = 500000, timestamp = MockWoW.serverTime - 3600,
                    scanTime = MockWoW.serverTime, scannedBy = "TestOfficer",
                }
                if overrides then for k, v in pairs(overrides) do rec[k] = v end end
                return rec
            end
            local txns = {
                makeMoneyTx({ player = "Banker", type = "deposit", amount = 1000000 }),
            }
            local summaries = GBL:BuildConsumptionSummary(txns)
            local totals = GBL:BuildGuildTotals(summaries)
            assert.equals(1, totals.playerCount)
            assert.equals(0, totals.itemsDeposited)
            assert.equals(0, totals.itemsWithdrawn)
            assert.equals(1000000, totals.goldDeposited)
        end)
    end)

    ---------------------------------------------------------------------------
    -- BuildGuildItemSummary
    ---------------------------------------------------------------------------

    describe("BuildGuildItemSummary", function()
        it("aggregates withdrawals across multiple players for same item", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5 }),
                makeTx({ player = "Bob", type = "withdraw", itemID = 100, count = 3 }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(1, #items)
            assert.equals(100, items[1].itemID)
            assert.equals(8, items[1].usedAll)
        end)

        it("excludes deposit-only items", function()
            local txns = {
                makeTx({ player = "Alice", type = "deposit", itemID = 100, count = 10 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 5 }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(1, #items)
            assert.equals(200, items[1].itemID)
        end)

        it("buckets withdrawals into 7d / 30d / All correctly", function()
            local now = MockWoW.serverTime
            local txns = {
                -- Within 7d
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 2,
                    timestamp = now - (3 * 24 * 3600) }),
                -- Between 7d and 30d
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5,
                    timestamp = now - (15 * 24 * 3600) }),
                -- Older than 30d
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 10,
                    timestamp = now - (60 * 24 * 3600) }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(1, #items)
            assert.equals(2, items[1].used7d)     -- only the 3d-old tx
            assert.equals(7, items[1].used30d)    -- 3d + 15d old
            assert.equals(17, items[1].usedAll)   -- all three
        end)

        it("includes withdrawal at exactly 7d boundary", function()
            local now = MockWoW.serverTime
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 1,
                    timestamp = now - (7 * 24 * 3600) }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(1, #items)
            assert.equals(1, items[1].used7d)   -- boundary: >= cutoff
        end)

        it("respects category filter", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, category = "flask" }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 3, category = "herb" }),
            }
            local items = GBL:BuildGuildItemSummary(txns, "flask")
            assert.equals(1, #items)
            assert.equals(100, items[1].itemID)
            assert.equals(5, items[1].usedAll)
        end)

        it("returns all items with category ALL", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, category = "flask" }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 3, category = "herb" }),
            }
            local items = GBL:BuildGuildItemSummary(txns, "ALL")
            assert.equals(2, #items)
        end)

        it("returns empty for nil transactions", function()
            local items = GBL:BuildGuildItemSummary(nil)
            assert.equals(0, #items)
        end)

        it("returns empty for empty transactions", function()
            local items = GBL:BuildGuildItemSummary({})
            assert.equals(0, #items)
        end)

        it("sorts by usedAll descending", function()
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 3 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 200, count = 10 }),
                makeTx({ player = "Alice", type = "withdraw", itemID = 300, count = 7 }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(3, #items)
            assert.equals(200, items[1].itemID)  -- 10
            assert.equals(300, items[2].itemID)  -- 7
            assert.equals(100, items[3].itemID)  -- 3
        end)

        it("includes category and name fields", function()
            Helpers.setItemInfo(100, 0, 3)  -- flask
            local link = Helpers.makeItemLink(100, "Flask of Power", 3)
            local txns = {
                makeTx({ player = "Alice", type = "withdraw", itemID = 100, count = 5, itemLink = link }),
            }
            local items = GBL:BuildGuildItemSummary(txns)
            assert.equals(1, #items)
            assert.equals("Flask of Power", items[1].itemName)
            assert.equals("flask", items[1].category)
            assert.equals("Flask", items[1].categoryDisplay)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Column definitions and sort state
    ---------------------------------------------------------------------------

    describe("Consumer and item column definitions", function()
        it("CONSUMER_COLUMNS has 6 columns", function()
            assert.equals(6, #GBL.CONSUMER_COLUMNS)
        end)

        it("TOP_ITEM_COLUMNS has 5 columns", function()
            assert.equals(5, #GBL.TOP_ITEM_COLUMNS)
        end)

        it("all CONSUMER_COLUMNS sort keys exist in SORT_KEYS", function()
            for _, col in ipairs(GBL.CONSUMER_COLUMNS) do
                if col.sortKey then
                    -- SortConsumptionSummary uses SORT_KEYS internally
                    -- Verify sorting doesn't error
                    local summaries = { { player = "A", netConsumed = 0, netContributed = 0,
                        moneyWithdrawn = 0, moneyDeposited = 0, moneyNet = 0, lastActive = 0 } }
                    GBL:SortConsumptionSummary(summaries, col.sortKey, true)
                end
            end
        end)
    end)

    describe("Item sort state", function()
        it("toggles direction on same column", function()
            GBL.itemSortColumn = "usedAll"
            GBL.itemSortAscending = false
            GBL:SetItemSort("usedAll")
            assert.equals("usedAll", GBL.itemSortColumn)
            assert.is_true(GBL.itemSortAscending)
        end)

        it("switches to ascending on new column", function()
            GBL.itemSortColumn = "usedAll"
            GBL.itemSortAscending = false
            GBL:SetItemSort("used7d")
            assert.equals("used7d", GBL.itemSortColumn)
            assert.is_true(GBL.itemSortAscending)
        end)

        it("shows sort indicator for active column", function()
            GBL.itemSortColumn = "used7d"
            GBL.itemSortAscending = true
            assert.equals("7d [asc]", GBL:GetItemSortIndicator("used7d", "7d"))
        end)

        it("shows plain label for inactive column", function()
            GBL.itemSortColumn = "used7d"
            assert.equals("All", GBL:GetItemSortIndicator("usedAll", "All"))
        end)
    end)
end)
