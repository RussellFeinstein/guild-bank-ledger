------------------------------------------------------------------------
-- restock_search_spec.lua — Tests for the Auctionator search flow (pure parts)
--
-- The Auctionator/Item API calls are fire-and-forget (not mocked) and verified
-- in-game. These tests cover the parts that do NOT need Auctionator: buy-list
-- construction, result pairing, the SearchEnd handler's mapping/transition,
-- reset, and the graceful no-Auctionator guard.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

local function layout(tabs)
    return { version = 1, updatedAt = 0, tabs = tabs }
end

-- Build a scan-results table from { [tabIndex] = { [slotIndex] = {itemID, count} } }.
local function scan(tabs)
    local results = {}
    for tabIndex, slots in pairs(tabs) do
        local slotTable = {}
        for slotIndex, s in pairs(slots) do
            slotTable[slotIndex] = {
                itemLink = Helpers.makeItemLink(s.itemID, s.name or "Item", s.quality or 1),
                count = s.count,
            }
        end
        results[tabIndex] = { slots = slotTable }
    end
    return results
end

describe("Restock search", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
    end)

    describe("_RestockBuildBuyList", function()
        it("includes only enabled rows that are short of target", function()
            local list = GBL:_RestockBuildBuyList({
                layout = layout({
                    [1] = { mode = "display", name = "A", items = {
                        [100] = { slots = 3, perSlot = 20 },  -- target 60
                        [200] = { slots = 1, perSlot = 5 },   -- target 5
                    } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })  -- no scan -> stock 0 -> both short
            assert.equals(2, #list)
            local needed = {}
            for _, e in ipairs(list) do needed[e.itemID] = e.needed end
            assert.equals(60, needed[100])
            assert.equals(5, needed[200])
        end)

        it("excludes a fully-stocked item (toBuy 0)", function()
            local list = GBL:_RestockBuildBuyList({
                layout = layout({
                    [1] = { mode = "display", name = "A", items = {
                        [100] = { slots = 1, perSlot = 10 },  -- target 10
                    } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 100, count = 10 } } }),
            })
            assert.equals(0, #list)
        end)

        it("excludes a disabled item via override", function()
            GBL:SetRestockItemOverride(100, { enabled = false })
            local list = GBL:_RestockBuildBuyList({
                layout = layout({
                    [1] = { mode = "display", name = "A", items = {
                        [100] = { slots = 1, perSlot = 10 },
                    } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(0, #list)
        end)
    end)

    describe("_RestockMapResults", function()
        it("pairs results to active items by itemID, regardless of result order", function()
            local activeItems = { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 } }
            local results = {
                { itemKey = { itemID = 200 }, minPrice = 5000 },
                { itemKey = { itemID = 100 }, minPrice = 12000 },
            }
            local rows, found = GBL:_RestockMapResults(activeItems, results)
            assert.equals(2, found)
            assert.equals(12000, rows[1].minPrice)  -- itemID 100 -> position 1
            assert.equals(5000, rows[2].minPrice)   -- itemID 200 -> position 2
        end)

        it("leaves a missing item unpaired and counts only those found", function()
            local activeItems = { { itemID = 100, needed = 5 }, { itemID = 999, needed = 3 } }
            local results = { { itemKey = { itemID = 100 }, minPrice = 12000 } }
            local rows, found = GBL:_RestockMapResults(activeItems, results)
            assert.equals(1, found)
            assert.is_not_nil(rows[1])
            assert.is_nil(rows[2])
        end)

        it("returns empty for nil results", function()
            local rows, found = GBL:_RestockMapResults({ { itemID = 1, needed = 1 } }, nil)
            assert.same({}, rows)
            assert.equals(0, found)
        end)
    end)

    describe("_RestockOnSearchEnd", function()
        it("maps results and transitions SEARCHING -> READY", function()
            GBL._restock = {
                state = "SEARCHING",
                activeItems = { { itemID = 100, needed = 5 } },
                resultRows = {},
                searchGen = 1,
            }
            GBL:_RestockOnSearchEnd({ { itemKey = { itemID = 100 }, minPrice = 4200 } })
            assert.equals("READY", GBL._restock.state)
            assert.equals(4200, GBL._restock.resultRows[1].minPrice)
            assert.equals(1, GBL._restock.foundCount)
        end)

        it("ignores results when not in the SEARCHING state", function()
            GBL._restock = { state = "IDLE", activeItems = {}, resultRows = {}, searchGen = 1 }
            GBL:_RestockOnSearchEnd({ { itemKey = { itemID = 100 }, minPrice = 4200 } })
            assert.equals("IDLE", GBL._restock.state)
        end)
    end)

    describe("ResetRestockSearch", function()
        it("clears state, bumps searchGen, and returns to IDLE", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 100, needed = 5 } },
                resultRows = { [1] = { minPrice = 1 } },
                searchGen = 3,
            }
            GBL:ResetRestockSearch()
            assert.equals("IDLE", GBL._restock.state)
            assert.equals(0, #GBL._restock.activeItems)
            assert.same({}, GBL._restock.resultRows)
            assert.equals(4, GBL._restock.searchGen)  -- bumped 3 -> 4
        end)
    end)

    describe("StartRestockSearch", function()
        it("no-ops gracefully when Auctionator is absent", function()
            -- Auctionator is not mocked, so the first guard fires and IDLE holds.
            GBL._restock = { state = "IDLE" }
            GBL:StartRestockSearch()
            assert.equals("IDLE", GBL._restock.state)
            -- Assert the specific guard-1 message so this can't pass on a
            -- different guard (three guard messages contain "Auctionator").
            assert.is_true(Helpers.printContains("needs the Auctionator addon"))
        end)
    end)
end)
