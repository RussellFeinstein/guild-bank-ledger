------------------------------------------------------------------------
-- filter_spec.lua — Tests for UI/FilterBar.lua filter logic
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local GBL

--- Build a test transaction record.
local function makeTxRecord(overrides)
    local rec = {
        id = "hash1",
        type = "withdraw",
        player = "Alice",
        itemLink = Helpers.makeItemLink(12345, "Flask of Power", 3),
        itemID = 12345,
        count = 5,
        tab = 1,
        classID = 0,
        subclassID = 5,
        category = "flask",
        timestamp = MockWoW.serverTime - 3600,  -- 1 hour ago
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

describe("FilterBar", function()
    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("CreateDefaultFilters", function()
        it("returns a filter table with all-pass defaults", function()
            local f = GBL:CreateDefaultFilters()
            assert.equals("", f.searchText)
            assert.equals("30d", f.dateRange)
            assert.equals("ALL", f.category)
            assert.equals("ALL", f.txType)
            assert.equals("ALL", f.player)
            assert.equals(0, f.tab)
        end)
    end)

    describe("MatchesFilters", function()
        it("matches with default (all-pass) filters", function()
            local filters = GBL:CreateDefaultFilters()
            local rec = makeTxRecord()
            assert.is_true(GBL:MatchesFilters(rec, filters))
        end)

        it("filters by player exact name", function()
            local filters = GBL:CreateDefaultFilters()
            filters.player = "Bob"
            assert.is_false(GBL:MatchesFilters(makeTxRecord({ player = "Alice" }), filters))
            assert.is_true(GBL:MatchesFilters(makeTxRecord({ player = "Bob" }), filters))
        end)

        it("filters by search text substring (case-insensitive) on player", function()
            local filters = GBL:CreateDefaultFilters()
            filters.searchText = "ali"
            assert.is_true(GBL:MatchesFilters(makeTxRecord({ player = "Alice" }), filters))
            assert.is_false(GBL:MatchesFilters(makeTxRecord({ player = "Bob" }), filters))
        end)

        it("filters by search text substring on itemLink", function()
            local filters = GBL:CreateDefaultFilters()
            filters.searchText = "flask"
            assert.is_true(GBL:MatchesFilters(makeTxRecord(), filters))
            filters.searchText = "potion"
            assert.is_false(GBL:MatchesFilters(makeTxRecord(), filters))
        end)

        it("filters by date range 7d", function()
            local filters = GBL:CreateDefaultFilters()
            filters.dateRange = "7d"
            -- 1 hour ago should pass
            assert.is_true(GBL:MatchesFilters(
                makeTxRecord({ timestamp = MockWoW.serverTime - 3600 }), filters))
            -- 10 days ago should fail
            assert.is_false(GBL:MatchesFilters(
                makeTxRecord({ timestamp = MockWoW.serverTime - (10 * 86400) }), filters))
        end)

        it("filters by date range 30d", function()
            local filters = GBL:CreateDefaultFilters()
            filters.dateRange = "30d"
            -- 20 days ago should pass
            assert.is_true(GBL:MatchesFilters(
                makeTxRecord({ timestamp = MockWoW.serverTime - (20 * 86400) }), filters))
            -- 60 days ago should fail
            assert.is_false(GBL:MatchesFilters(
                makeTxRecord({ timestamp = MockWoW.serverTime - (60 * 86400) }), filters))
        end)

        it("filters by category", function()
            local filters = GBL:CreateDefaultFilters()
            filters.category = "herb"
            assert.is_false(GBL:MatchesFilters(makeTxRecord({ category = "flask" }), filters))
            assert.is_true(GBL:MatchesFilters(makeTxRecord({ category = "herb" }), filters))
        end)

        it("filters by transaction type", function()
            local filters = GBL:CreateDefaultFilters()
            filters.txType = "deposit"
            assert.is_false(GBL:MatchesFilters(makeTxRecord({ type = "withdraw" }), filters))
            assert.is_true(GBL:MatchesFilters(makeTxRecord({ type = "deposit" }), filters))
        end)

        it("filters by tab number", function()
            local filters = GBL:CreateDefaultFilters()
            filters.tab = 3
            assert.is_false(GBL:MatchesFilters(makeTxRecord({ tab = 1 }), filters))
            assert.is_true(GBL:MatchesFilters(makeTxRecord({ tab = 3 }), filters))
        end)

        it("applies combined AND filters", function()
            local filters = GBL:CreateDefaultFilters()
            filters.category = "flask"
            filters.player = "Alice"
            filters.txType = "withdraw"
            -- All match
            assert.is_true(GBL:MatchesFilters(makeTxRecord({
                category = "flask", player = "Alice", type = "withdraw",
            }), filters))
            -- Category mismatch
            assert.is_false(GBL:MatchesFilters(makeTxRecord({
                category = "herb", player = "Alice", type = "withdraw",
            }), filters))
        end)

        it("returns false for nil record", function()
            assert.is_false(GBL:MatchesFilters(nil, GBL:CreateDefaultFilters()))
        end)
    end)

    describe("FilterTransactions", function()
        it("returns matching subset", function()
            local txns = {
                makeTxRecord({ player = "Alice", type = "withdraw" }),
                makeTxRecord({ player = "Bob", type = "deposit" }),
                makeTxRecord({ player = "Alice", type = "deposit" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.player = "Alice"
            local result = GBL:FilterTransactions(txns, filters)
            assert.equals(2, #result)
        end)

        it("returns empty table for zero matches", function()
            local txns = {
                makeTxRecord({ player = "Alice" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.player = "Nobody"
            local result = GBL:FilterTransactions(txns, filters)
            assert.equals(0, #result)
        end)

        it("returns all when filters are nil", function()
            local txns = { makeTxRecord(), makeTxRecord() }
            local result = GBL:FilterTransactions(txns, nil)
            assert.equals(2, #result)
        end)

        it("returns empty table when transactions are nil", function()
            local result = GBL:FilterTransactions(nil, GBL:CreateDefaultFilters())
            assert.equals(0, #result)
        end)
    end)

    describe("GetUniquePlayers", function()
        it("returns sorted unique player names", function()
            local txns = {
                makeTxRecord({ player = "Charlie" }),
                makeTxRecord({ player = "Alice" }),
                makeTxRecord({ player = "Bob" }),
                makeTxRecord({ player = "Alice" }),
            }
            local players = GBL:GetUniquePlayers(txns)
            assert.equals(3, #players)
            assert.equals("Alice", players[1])
            assert.equals("Bob", players[2])
            assert.equals("Charlie", players[3])
        end)
    end)

    describe("GetUniqueTabs", function()
        it("returns sorted unique tab numbers", function()
            local txns = {
                makeTxRecord({ tab = 3 }),
                makeTxRecord({ tab = 1 }),
                makeTxRecord({ tab = 3 }),
                makeTxRecord({ tab = 2 }),
            }
            local tabs = GBL:GetUniqueTabs(txns)
            assert.equals(3, #tabs)
            assert.equals(1, tabs[1])
            assert.equals(2, tabs[2])
            assert.equals(3, tabs[3])
        end)
    end)

    describe("CountFilterResults", function()
        it("counts matching records without building array", function()
            local txns = {
                makeTxRecord({ player = "Alice" }),
                makeTxRecord({ player = "Bob" }),
                makeTxRecord({ player = "Alice" }),
            }
            local filters = GBL:CreateDefaultFilters()
            filters.player = "Alice"
            assert.equals(2, GBL:CountFilterResults(txns, filters))
        end)
    end)

    describe("Money transaction filtering", function()
        --- Build a money transaction record (no itemID, itemLink, category, tab).
        local function makeMoneyRecord(overrides)
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

        it("passes money tx with default filters", function()
            local filters = GBL:CreateDefaultFilters()
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord(), filters))
        end)

        it("passes money tx when category filter is set", function()
            local filters = GBL:CreateDefaultFilters()
            filters.category = "flask"
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord(), filters))
        end)

        it("passes money tx when tab filter is set", function()
            local filters = GBL:CreateDefaultFilters()
            filters.tab = 2
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord(), filters))
        end)

        it("filters money tx by player", function()
            local filters = GBL:CreateDefaultFilters()
            filters.player = "Bob"
            assert.is_false(GBL:MatchesFilters(makeMoneyRecord({ player = "Alice" }), filters))
        end)

        it("filters money tx by date range", function()
            local filters = GBL:CreateDefaultFilters()
            filters.dateRange = "7d"
            -- Recent tx passes
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord(), filters))
            -- Old tx fails
            assert.is_false(GBL:MatchesFilters(makeMoneyRecord({
                timestamp = MockWoW.serverTime - (8 * 86400),
            }), filters))
        end)

        it("filters money tx by type", function()
            local filters = GBL:CreateDefaultFilters()
            filters.txType = "repair"
            assert.is_false(GBL:MatchesFilters(makeMoneyRecord({ type = "deposit" }), filters))
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord({ type = "repair" }), filters))
        end)

        it("matches money tx by player name in search", function()
            local filters = GBL:CreateDefaultFilters()
            filters.searchText = "Alice"
            assert.is_true(GBL:MatchesFilters(makeMoneyRecord({ player = "Alice" }), filters))
        end)

        it("mixed item + money tx both pass default filters", function()
            local filters = GBL:CreateDefaultFilters()
            local txns = {
                makeTxRecord({ player = "Alice" }),
                makeMoneyRecord({ player = "Alice" }),
            }
            local result = GBL:FilterTransactions(txns, filters)
            assert.equals(2, #result)
        end)
    end)

    describe("GOLD_LOG_COLUMNS", function()
        it("includes an amount column", function()
            local found = false
            for _, col in ipairs(GBL.GOLD_LOG_COLUMNS) do
                if col.key == "amount" then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)
    end)
end)
