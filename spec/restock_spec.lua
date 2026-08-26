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

        it("excludes every overflow tab of a multi-overflow layout (#57)", function()
            local d = GBL:_RestockLayoutDemand(layout({
                [1] = { mode = "display", items = { [100] = { slots = 2, perSlot = 10 } } },
                [2] = { mode = "overflow", items = { [101] = { slots = 5, perSlot = 5 } } },
                [5] = { mode = "overflow", overflowPriority = 1,
                        items = { [102] = { slots = 5, perSlot = 5 } } },
            }))
            assert.equals(20, d[100])
            assert.is_nil(d[101])
            assert.is_nil(d[102])
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

        it("builds rows only from layout display-tab items", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "Gems",
                            items = { [100] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(1, #rows)
            assert.equals(100, rows[1].itemID)
            assert.equals(20, rows[1].target)
            assert.equals("Gems", rows[1].group)
            assert.equals(1, rows[1].tabIndex)
        end)

        it("excludes items in overflow or ignore tabs", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow", items = { [200] = { slots = 1, perSlot = 5 } } },
                    [3] = { mode = "ignore", items = { [300] = { slots = 1, perSlot = 5 } } },
                }),
                reserves = {},
            })
            assert.equals(1, #rows)
            assert.equals(100, rows[1].itemID)
        end)

        it("excludes items on every overflow tab of a multi-overflow layout (#57)", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow", items = { [200] = { slots = 1, perSlot = 5 } } },
                    [5] = { mode = "overflow", overflowPriority = 1,
                            items = { [201] = { slots = 1, perSlot = 5 } } },
                }),
                reserves = {},
            })
            assert.equals(1, #rows)
            assert.equals(100, rows[1].itemID)
        end)

        it("excludes an item present only in a bank scan, not the layout", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 999, count = 50 } } }),
            })
            local seen999 = false
            for _, r in ipairs(rows) do if r.itemID == 999 then seen999 = true end end
            assert.is_false(seen999)
        end)

        it("decorates stock and toBuy from the scan", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 3, perSlot = 20 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 100, count = 25 } } }),
            })
            assert.equals(60, rows[1].target)
            assert.equals(25, rows[1].stock)
            assert.equals(35, rows[1].toBuy)
        end)

        it("layers a reserve-only item under the Reserves group (Option C)", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = { [200] = 25 },
            })
            local res
            for _, r in ipairs(rows) do if r.itemID == 200 then res = r end end
            assert.is_table(res)
            assert.equals(25, res.target)
            assert.is_nil(res.tabIndex)
            assert.equals("Reserves (not in a display tab)", res.group)
        end)

        it("keeps the demand target when a reserve is below demand", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = { [100] = 5 },  -- below demand of 20
            })
            assert.equals(1, #rows)            -- shows once, under its tab
            assert.equals(20, rows[1].target)  -- max(20, 5)
            assert.equals(1, rows[1].tabIndex)
        end)

        it("matches string-keyed layout items to number-keyed stock (sync robustness)", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { ["55555"] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 55555, count = 8 } } }),
            })
            assert.equals(1, #rows)             -- not duplicated by a number/string key split
            assert.equals(55555, rows[1].itemID)
            assert.equals(20, rows[1].target)   -- demand resolved despite the string key
            assert.equals(8, rows[1].stock)     -- stock matched despite the string key
            assert.equals(12, rows[1].toBuy)
        end)

        it("groups items under their tab name in ascending tab order", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [2] = { mode = "display", name = "Gems",
                            items = { [200] = { slots = 1, perSlot = 5 } } },
                    [1] = { mode = "display", name = "Consumables",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [3] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(2, #rows)
            assert.equals("Consumables", rows[1].group)  -- tabIndex 1 first
            assert.equals(100, rows[1].itemID)
            assert.equals("Gems", rows[2].group)
            assert.equals(200, rows[2].itemID)
        end)

        it("falls back to a Tab N heading when a display tab has no name", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals("Tab 1", rows[1].group)
        end)

        it("reflects a per-item override on a layout item", function()
            GBL:SetRestockItemOverride(100, { enabled = false, maxPrice = 999 })
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(1, #rows)
            assert.is_false(rows[1].enabled)
            assert.equals(999, rows[1].maxPrice)
        end)

        it("orders items within a tab by slotOrder position, then by itemID", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = {
                                [100] = { slots = 1, perSlot = 5 },
                                [200] = { slots = 1, perSlot = 5 },
                                [300] = { slots = 1, perSlot = 5 },
                            },
                            slotOrder = { [1] = 300, [2] = 100 } },  -- 300, then 100; 200 unslotted
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(3, #rows)
            assert.equals(300, rows[1].itemID)  -- slot 1
            assert.equals(100, rows[2].itemID)  -- slot 2
            assert.equals(200, rows[3].itemID)  -- unslotted, falls to itemID order (last)
        end)

        it("orders a tab's items by itemID when there is no slotOrder", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = {
                                [300] = { slots = 1, perSlot = 5 },
                                [100] = { slots = 1, perSlot = 5 },
                                [200] = { slots = 1, perSlot = 5 },
                            } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals(100, rows[1].itemID)
            assert.equals(200, rows[2].itemID)
            assert.equals(300, rows[3].itemID)
        end)

        it("dedups an item that is a string-keyed layout entry and a number-keyed reserve", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { ["55555"] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = { [55555] = 100 },  -- number-keyed reserve for the same item
            })
            assert.equals(1, #rows)             -- one row, not one per key form
            assert.equals(55555, rows[1].itemID)
            assert.equals(100, rows[1].target)  -- max(demand 20, reserve 100)
            assert.equals(1, rows[1].tabIndex)  -- shown under its display tab, not Reserves
        end)

        it("is empty when the layout has no display tabs", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({ [1] = { mode = "overflow" } }),
                reserves = {},
            })
            assert.equals(0, #rows)
        end)
    end)
end)
