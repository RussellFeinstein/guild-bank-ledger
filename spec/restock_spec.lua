------------------------------------------------------------------------
-- restock_spec.lua — Tests for Restock.lua (pure math + universe + DB)
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- Build a layout-shaped table for the pure demand fn.
local function layout(tabs)
    return { version = 1, updatedAt = 0, tabs = tabs }
end

-- Build a scan-results-shaped table from { [tabIndex] = { [slotIndex] = {itemID, count, ...} } }.
local function scan(tabs)
    local results = {}
    for tabIndex, slots in pairs(tabs) do
        local slotTable = {}
        for slotIndex, s in pairs(slots) do
            slotTable[slotIndex] = {
                itemLink = Helpers.makeItemLink(s.itemID, s.name or "Item", s.quality or 1),
                count = s.count,
                locked = s.locked or false,
            }
        end
        results[tabIndex] = { slots = slotTable }
    end
    return results
end

describe("Restock", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    describe("_RestockLayoutDemand", function()
        it("sums slots*perSlot over display tabs", function()
            local d = GBL:_RestockLayoutDemand(layout({
                [1] = { mode = "display", items = {
                    [100] = { slots = 3, perSlot = 20 },  -- 60
                    [101] = { slots = 1, perSlot = 5 },   -- 5
                } },
                [2] = { mode = "display", items = {
                    [102] = { slots = 2, perSlot = 10 },  -- 20
                } },
                [3] = { mode = "overflow" },
            }))
            assert.equals(60, d[100])
            assert.equals(5, d[101])
            assert.equals(20, d[102])
        end)

        it("excludes ignore and overflow tabs", function()
            local d = GBL:_RestockLayoutDemand(layout({
                [1] = { mode = "ignore", items = { [100] = { slots = 5, perSlot = 5 } } },
                [2] = { mode = "overflow", items = { [101] = { slots = 5, perSlot = 5 } } },
            }))
            assert.is_nil(d[100])
            assert.is_nil(d[101])
        end)

        it("returns empty for nil or malformed layout", function()
            assert.same({}, GBL:_RestockLayoutDemand(nil))
            assert.same({}, GBL:_RestockLayoutDemand({}))
            assert.same({}, GBL:_RestockLayoutDemand({ tabs = {} }))
        end)
    end)

    describe("_RestockAggregateStock", function()
        it("sums counts across all tabs and same-item stacks", function()
            local s = GBL:_RestockAggregateStock(scan({
                [1] = { [1] = { itemID = 100, count = 20 }, [2] = { itemID = 100, count = 15 } },
                [2] = { [1] = { itemID = 101, count = 5 } },
            }))
            assert.equals(35, s[100])  -- 20 + 15 across two slots
            assert.equals(5, s[101])
        end)

        it("counts locked slots and ignores empty/missing links", function()
            local s = GBL:_RestockAggregateStock({
                [1] = { slots = {
                    [1] = { itemLink = Helpers.makeItemLink(100, "X"), count = 3, locked = true },
                    [2] = { itemLink = nil, count = 99 },  -- empty slot, no link
                } },
            })
            assert.equals(3, s[100])
        end)

        it("returns empty for nil scan", function()
            assert.same({}, GBL:_RestockAggregateStock(nil))
        end)
    end)

    describe("_RestockTarget / _restockComputeToBuy", function()
        it("target is demand-only when reserves empty", function()
            assert.equals(60, GBL:_RestockTarget(100, { [100] = 60 }, {}))
        end)

        it("target is max(demand, reserve)", function()
            assert.equals(80, GBL:_RestockTarget(100, { [100] = 60 }, { [100] = 80 }))
            assert.equals(60, GBL:_RestockTarget(100, { [100] = 60 }, { [100] = 40 }))
        end)

        it("target honors a reserve-only item with no demand", function()
            assert.equals(25, GBL:_RestockTarget(200, {}, { [200] = 25 }))
        end)

        it("toBuy = max(0, target - stock) and clamps when overstocked", function()
            assert.equals(40, GBL:_restockComputeToBuy(100, { [100] = 60 }, {}, { [100] = 20 }))
            assert.equals(0, GBL:_restockComputeToBuy(100, { [100] = 60 }, {}, { [100] = 99 }))
        end)
    end)

    describe("per-guild restock settings", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = 0
            GBL:OnEnable()
        end)

        it("budget get/set clamps at 0", function()
            assert.equals(0, GBL:GetRestockBudget())
            GBL:SetRestockBudget(500)
            assert.equals(500, GBL:GetRestockBudget())
            GBL:SetRestockBudget(-10)
            assert.equals(0, GBL:GetRestockBudget())
        end)

        it("item override set then clear", function()
            GBL:SetRestockItemOverride(100, { enabled = false, maxPrice = 1234 })
            local o = GBL:GetRestockItemOverride(100)
            assert.is_false(o.enabled)
            assert.equals(1234, o.maxPrice)
            GBL:SetRestockItemOverride(100, nil)
            assert.is_nil(GBL:GetRestockItemOverride(100))
        end)

        it("add/remove catalog augmentation", function()
            GBL:AddRestockCatalogItem(99999)
            assert.is_true(GBL:GetRestockData().added[99999])
            GBL:RemoveRestockCatalogItem(99999)
            assert.is_nil(GBL:GetRestockData().added[99999])
        end)

        it("rejects a non-numeric itemID", function()
            local ok = GBL:SetRestockItemOverride("nope", {})
            assert.is_false(ok)
        end)
    end)

    describe("_RestockBuildItemUniverse", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = 0
            GBL:OnEnable()
        end)

        it("includes every catalog item tagged source=catalog", function()
            local rows = GBL:_RestockBuildItemUniverse({ layout = layout({}), reserves = {} })
            local catalogCount = 0
            for _, r in ipairs(rows) do
                if r.source == "catalog" then catalogCount = catalogCount + 1 end
            end
            assert.equals(123, catalogCount)
        end)

        it("surfaces a demand-only non-catalog item as source=target", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", items = { [88888] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            local found
            for _, r in ipairs(rows) do if r.itemID == 88888 then found = r end end
            assert.is_table(found)
            assert.equals("target", found.source)
            assert.equals(20, found.target)
            assert.equals(20, found.toBuy)  -- nothing in stock
        end)

        it("surfaces an added non-catalog item as source=added", function()
            GBL:AddRestockCatalogItem(77777)
            local rows = GBL:_RestockBuildItemUniverse({ layout = layout({}), reserves = {} })
            local found
            for _, r in ipairs(rows) do if r.itemID == 77777 then found = r end end
            assert.is_table(found)
            assert.equals("added", found.source)
        end)

        it("dedups an item that is both catalog and demand-pinned", function()
            -- 240968 is a catalog gem; also pin it in a display tab.
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", items = { [240968] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            local count, row = 0, nil
            for _, r in ipairs(rows) do
                if r.itemID == 240968 then count = count + 1; row = r end
            end
            assert.equals(1, count)
            assert.equals("catalog", row.source)
            assert.equals(5, row.target)  -- demand applies even though the row is catalog-sourced
        end)

        it("reflects an item override on its row", function()
            GBL:SetRestockItemOverride(240968, { enabled = false, maxPrice = 999 })
            local rows = GBL:_RestockBuildItemUniverse({ layout = layout({}), reserves = {} })
            local row
            for _, r in ipairs(rows) do if r.itemID == 240968 then row = r end end
            assert.is_false(row.enabled)
            assert.equals(999, row.maxPrice)
        end)
    end)
end)
