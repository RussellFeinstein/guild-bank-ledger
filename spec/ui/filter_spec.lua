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
end)
