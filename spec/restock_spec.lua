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

        -- #236: the layout snapshots a tab's name when the tab is captured and
        -- nothing refreshes it, so a rename in the bank left this list naming
        -- tabs the Layout tab on the same screen already called something else.
        it("reads the bank tab's current name over the stored one", function()
            MockWoW.addTab("Raid Use 1")
            MockWoW.addTab("Raid Use 2")
            MockWoW.addTab("Raid Use 3")
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [3] = { mode = "display", name = "Potions",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [4] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals("Raid Use 3", rows[1].group)
        end)

        it("keeps the stored name for a tab the client cannot name yet", function()
            -- Before the bank has been opened this session GetGuildBankTabInfo
            -- answers nothing, and the capture-time name beats the index.
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [3] = { mode = "display", name = "Potions",
                            items = { [100] = { slots = 1, perSlot = 5 } } },
                    [4] = { mode = "overflow" },
                }),
                reserves = {},
            })
            assert.equals("Potions", rows[1].group)
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

        -- Before a scan every row says so (#214, #43's restock half): the
        -- view reads bank ? and no shortfall off this flag. toBuy is left
        -- alone, since the no-scan precondition already keeps an unscanned
        -- bank out of the buy list.
        it("flags every row unscanned until a scan has completed (#214)", function()
            local lay = layout({
                [1] = { mode = "display", name = "Gems", items = { [100] = { slots = 2, perSlot = 10 } } },
                [2] = { mode = "overflow" },
            })
            local rows = GBL:_RestockBuildItemUniverse({ layout = lay, reserves = {} })
            assert.is_false(rows[1].scanned)
            assert.equals(20, rows[1].toBuy)
            rows = GBL:_RestockBuildItemUniverse({ layout = lay, reserves = {}, scanResults = scan({}) })
            assert.is_true(rows[1].scanned)
            assert.equals(20, rows[1].toBuy)
        end)

        it("is empty when the layout has no display tabs", function()
            local rows = GBL:_RestockBuildItemUniverse({
                layout = layout({ [1] = { mode = "overflow" } }),
                reserves = {},
            })
            assert.equals(0, #rows)
        end)
    end)

    -- Pending purchases (#209): bought at the auction house and not yet seen
    -- in the bank. Per guild, persisted beside the budget, cleared by the
    -- ledger's deposit records for the buyer and never by the bank scan.
    describe("pending purchases (#209)", function()
        local buyer

        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = 0
            GBL:OnEnable()
            buyer = GBL:ResolvePlayerName(MockWoW.player.name)
        end)

        -- Every line the store writes to the system channel.
        local function pendingLines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Restock pending:", 1, true) == 1 then
                    out[#out + 1] = e.message
                end
            end
            return out
        end

        local function oneItemUniverse(pending, stock)
            return GBL:_RestockBuildItemUniverse({
                layout = layout({
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 20 } } },
                    [2] = { mode = "overflow" },
                }),
                reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 100, count = stock } } }),
                data = { items = {}, budget = 0, pending = pending },
            })
        end

        describe("store", function()
            it("backfills an empty pending table on the guild store", function()
                local data = GBL:GetRestockData()
                assert.is_table(data.pending)
                assert.is_nil(next(data.pending))
            end)

            it("adds an entry with the buyer, the server time and the quantity", function()
                MockWoW.serverTime = 3600 * 475200
                assert.is_true(GBL:_RestockAddPending(100, 5))
                local e = GBL:GetRestockData().pending[100]
                assert.equals(5, e.qty)
                assert.equals(buyer, e.buyer)
                assert.equals(3600 * 475200, e.at)
                assert.is_nil(e.unconfirmed)
                assert.equals(1, #pendingLines())
                assert.truthy(pendingLines()[1]:find("it:100 x5 added, 5 in the mail", 1, true))
            end)

            it("accumulates a second purchase and keeps the earliest at", function()
                MockWoW.serverTime = 3600 * 475200
                GBL:_RestockAddPending(100, 5)
                MockWoW.serverTime = 3600 * 475200 + 900
                GBL:_RestockAddPending(100, 3)
                local e = GBL:GetRestockData().pending[100]
                assert.equals(8, e.qty)
                assert.equals(3600 * 475200, e.at)
                assert.equals(buyer, e.buyer)
                assert.is_true(e.buyers[buyer])
            end)

            it("records a second character on the account as a buyer too", function()
                GBL:_RestockAddPending(100, 5)
                MockWoW.player.name = "Altchar"
                GBL:_RestockAddPending(100, 3)
                local e = GBL:GetRestockData().pending[100]
                assert.equals(buyer, e.buyer)  -- the first buyer names the entry
                assert.is_true(e.buyers[buyer])
                assert.is_true(e.buyers["Altchar-TestRealm"])
            end)

            -- #215 replaced the stored boolean with two quantities, so a
            -- confirmed add beside an unconfirmed one no longer swallows both
            -- into one number under one flag ("15 bought, result unknown").
            it("keeps an unconfirmed quantity apart from a later confirmed add", function()
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                local parts = GBL:_RestockPendingParts(GBL:GetRestockData().pending[100])
                assert.equals(5, parts.unconfirmed)
                assert.is_true(parts.isUnconfirmed)
                assert.truthy(pendingLines()[1]:find("(result unknown)", 1, true))
                GBL:_RestockAddPending(100, 2)
                parts = GBL:_RestockPendingParts(GBL:GetRestockData().pending[100])
                assert.equals(2, parts.confirmed)
                assert.equals(5, parts.unconfirmed)
                assert.equals(7, parts.total)
            end)

            it("refuses a non-numeric item or a zero quantity", function()
                assert.is_false(GBL:_RestockAddPending("nope", 5))
                assert.is_false(GBL:_RestockAddPending(100, 0))
                assert.is_nil(next(GBL:GetRestockData().pending))
                assert.equals(0, #pendingLines())
            end)

            it("clears an entry by hand", function()
                GBL:_RestockAddPending(100, 5)
                assert.is_true(GBL:ClearRestockPending(100))
                assert.is_nil(GBL:GetRestockData().pending[100])
                assert.truthy(pendingLines()[1]:find("it:100 cleared by hand (x5)", 1, true))
                assert.is_false(GBL:ClearRestockPending(100))
            end)
        end)

        -- #215: an unanswered confirm is parked the moment the step timer
        -- gives up, so a reload cannot lose it. That is only safe if a late
        -- result can settle the parked quantity and a late failure can
        -- reverse it, and one summed qty under one boolean expresses neither.
        describe("the two parts, and the guards (#215)", function()
            it("keeps a confirmed and an unconfirmed quantity apart on one entry", function()
                GBL:_RestockAddPending(100, 10)
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                local e = GBL:GetRestockData().pending[100]
                assert.equals(10, e.qty)
                assert.equals(5, e.unconfirmedQty)
                local parts = GBL:_RestockPendingParts(e)
                assert.equals(10, parts.confirmed)
                assert.equals(5, parts.unconfirmed)
                assert.equals(15, parts.total)
                assert.is_true(parts.isUnconfirmed)
            end)

            it("derives the unconfirmed flag rather than storing a second copy of it", function()
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                local e = GBL:GetRestockData().pending[100]
                assert.is_nil(e.unconfirmed)
                assert.is_true(GBL:_RestockPendingParts(e).isUnconfirmed)
            end)

            -- _RestockAddPending keeps the earliest at, so without a second
            -- stamp a park landing on an old entry would render the old
            -- purchase age for one made seconds ago.
            it("stamps the unconfirmed part with its own time", function()
                MockWoW.serverTime = 3600 * 475200
                GBL:_RestockAddPending(100, 10)
                MockWoW.serverTime = 3600 * 475200 + 10800
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                local e = GBL:GetRestockData().pending[100]
                assert.equals(3600 * 475200, e.at)
                assert.equals(3600 * 475200 + 10800, e.unconfirmedAt)
            end)

            -- The fixture is the shape _RestockAddPending wrote before the
            -- split, read off the function rather than off any of the four
            -- prose copies, which disagree with each other.
            it("reads an entry written before the split", function()
                local old = { qty = 5, buyer = buyer, buyers = { [buyer] = true },
                              at = 1, unconfirmed = true }
                local parts = GBL:_RestockPendingParts(old)
                assert.equals(0, parts.confirmed)
                assert.equals(5, parts.unconfirmed)
                assert.equals(5, parts.total)
                assert.is_true(parts.isUnconfirmed)

                local plain = GBL:_RestockPendingParts({ qty = 5, buyer = buyer, at = 1 })
                assert.equals(5, plain.confirmed)
                assert.equals(0, plain.unconfirmed)
                assert.is_false(plain.isUnconfirmed)
            end)

            it("settles the unconfirmed part into the confirmed one", function()
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                assert.is_true(GBL:_RestockSettlePending(100, 5))
                local parts = GBL:_RestockPendingParts(GBL:GetRestockData().pending[100])
                assert.equals(5, parts.confirmed)
                assert.equals(0, parts.unconfirmed)
                assert.is_false(parts.isUnconfirmed)
            end)

            it("reverses the unconfirmed part and removes an entry left at nothing", function()
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                assert.is_true(GBL:_RestockReversePending(100, 5))
                assert.is_nil(GBL:GetRestockData().pending[100])
            end)

            it("reverses only the unconfirmed part of a mixed entry", function()
                GBL:_RestockAddPending(100, 10)
                GBL:_RestockAddPending(100, 5, { unconfirmed = true })
                assert.is_true(GBL:_RestockReversePending(100, 5))
                local parts = GBL:_RestockPendingParts(GBL:GetRestockData().pending[100])
                assert.equals(10, parts.confirmed)
                assert.equals(0, parts.unconfirmed)
            end)

            it("settles and reverses nothing when there is no entry", function()
                assert.is_false(GBL:_RestockSettlePending(100, 5))
                assert.is_false(GBL:_RestockReversePending(100, 5))
            end)

            -- entry.buyers = entry.buyers or { [entry.buyer] = true } raised
            -- "table index is nil" on an entry carrying no buyer.
            it("does not error on an entry with no buyer", function()
                GBL:GetRestockData().pending[100] = { qty = 5, at = 1 }
                assert.is_true(GBL:_RestockAddPending(100, 2))
                local e = GBL:GetRestockData().pending[100]
                assert.equals(7, e.qty)
                assert.equals(buyer, e.buyer)
                assert.is_true(e.buyers[buyer])
            end)

            -- The universe tolerated a string key while both readers indexed
            -- by number, so such an entry rendered with a Clear that did
            -- nothing and could never be settled.
            it("clears an entry a foreign writer keyed by string", function()
                GBL:GetRestockData().pending["100"] = { qty = 5, buyer = buyer, at = 1 }
                assert.is_true(GBL:ClearRestockPending(100))
                assert.is_nil(GBL:GetRestockData().pending["100"])
                assert.is_nil(GBL:GetRestockData().pending[100])
            end)

            it("re-keys a string-keyed entry by number on the next write", function()
                GBL:GetRestockData().pending["100"] = { qty = 5, buyer = buyer, at = 1 }
                GBL:_RestockAddPending(100, 3)
                assert.is_nil(GBL:GetRestockData().pending["100"])
                assert.equals(8, GBL:GetRestockData().pending[100].qty)
            end)
        end)

        describe("universe", function()
            it("subtracts the pending quantity from the shortfall and carries it on the row", function()
                local rows = oneItemUniverse({ [100] = { qty = 5, buyer = buyer, at = 1 } }, 10)
                assert.equals(20, rows[1].target)
                assert.equals(10, rows[1].stock)
                assert.equals(5, rows[1].pending)
                assert.equals(1, rows[1].pendingAt)
                assert.is_nil(rows[1].pendingUnconfirmed)
                assert.equals(5, rows[1].toBuy)
            end)

            it("clamps the shortfall at zero when a foreign deposit fills the gap", function()
                local rows = oneItemUniverse({ [100] = { qty = 5, buyer = buyer, at = 1 } }, 18)
                assert.equals(5, rows[1].pending)
                assert.equals(0, rows[1].toBuy)
            end)

            it("reads a string-keyed pending entry and the unconfirmed flag", function()
                local rows = oneItemUniverse(
                    { ["100"] = { qty = 2, buyer = buyer, at = 1, unconfirmed = true } }, 0)
                assert.equals(2, rows[1].pending)
                assert.is_true(rows[1].pendingUnconfirmed)
                assert.equals(18, rows[1].toBuy)
            end)

            it("renders an entry for an item that is not in the layout at all", function()
                local rows = oneItemUniverse({ [900] = { qty = 3, buyer = buyer, at = 1 } }, 0)
                local orphan
                for _, r in ipairs(rows) do if r.itemID == 900 then orphan = r end end
                assert.is_not_nil(orphan)
                assert.equals(3, orphan.pending)
                assert.equals(0, orphan.target)
                assert.equals(0, orphan.toBuy)
                assert.truthy(orphan.group:find("mail", 1, true))
            end)

            it("renders it even when the layout has no display tab left", function()
                local rows = GBL:_RestockBuildItemUniverse({
                    layout = layout({ [1] = { mode = "overflow" } }),
                    reserves = {},
                    scanResults = scan({}),
                    data = { items = {}, budget = 0,
                             pending = { [900] = { qty = 3, buyer = buyer, at = 1 } } },
                })
                assert.equals(1, #rows)
                assert.equals(900, rows[1].itemID)
                assert.equals(3, rows[1].pending)
            end)

            it("carries zero pending on a row with no entry", function()
                local rows = oneItemUniverse({}, 0)
                assert.equals(0, rows[1].pending)
                assert.is_nil(rows[1].pendingAt)
                assert.equals(20, rows[1].toBuy)
            end)

            it("drops a covered row from the buy list and reduces the rest", function()
                local list = GBL:_RestockBuildBuyList({
                    layout = layout({
                        [1] = { mode = "display", name = "A",
                                items = { [100] = { slots = 1, perSlot = 20 },
                                          [200] = { slots = 1, perSlot = 10 } } },
                        [2] = { mode = "overflow" },
                    }),
                    reserves = {},
                    scanResults = scan({}),
                    data = { items = {}, budget = 0,
                             pending = { [100] = { qty = 20, buyer = buyer, at = 1 },
                                         [200] = { qty = 4, buyer = buyer, at = 1 } } },
                })
                assert.equals(1, #list)
                assert.equals(200, list[1].itemID)
                assert.equals(6, list[1].needed)
            end)
        end)

        -- The ledger hook. A hand-built record exercises the rule; the two
        -- intake paths (StoreBatchRecords for a scan, StoreTx for a sync
        -- receive) prove the call sites.
        describe("cleared by the ledger", function()
            local guildData

            local function deposit(over)
                local rec = {
                    type = "deposit", player = buyer, itemID = 100, count = 5,
                    timestamp = 3600 * 475200,
                }
                for k, v in pairs(over or {}) do rec[k] = v end
                return rec
            end

            before_each(function()
                guildData = GBL:GetGuildData()
                MockWoW.serverTime = 3600 * 475200
                GBL:_RestockAddPending(100, 5)
            end)

            it("clears the entry on a full deposit by the buyer at or after the purchase", function()
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ timestamp = 3600 * 475200 + 1234 }), guildData))
                assert.is_nil(guildData.restock.pending[100])
                assert.truthy(pendingLines()[1]:find("it:100 deposit x5 by " .. buyer
                    .. ", cleared (recorded +1234s after the purchase)", 1, true))
            end)

            it("takes a deposit by any character that bought into the entry", function()
                MockWoW.player.name = "Altchar"
                GBL:_RestockAddPending(100, 4)
                MockWoW.player.name = "TestOfficer"
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ player = "Altchar-TestRealm", count = 4 }), guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ player = "Jaina-TestRealm" }), guildData))
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ timestamp = 3600 * 475200 - 600 }), guildData))
                assert.is_nil(guildData.restock.pending[100])
                assert.truthy(pendingLines()[1]:find("(recorded -600s after the purchase)", 1, true))
            end)

            it("reduces the entry on a partial deposit and clears it on the rest", function()
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ count = 2 }), guildData))
                assert.equals(3, guildData.restock.pending[100].qty)
                assert.truthy(pendingLines()[1]:find("it:100 deposit x2 by " .. buyer .. ", 3 left", 1, true))
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ count = 9 }), guildData))
                assert.is_nil(guildData.restock.pending[100])
            end)

            it("drains the confirmed part before the unconfirmed one", function()
                GBL:_RestockAddPending(100, 4, { unconfirmed = true })
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ count = 5 }), guildData))
                local parts = GBL:_RestockPendingParts(guildData.restock.pending[100])
                assert.equals(0, parts.confirmed)
                assert.equals(4, parts.unconfirmed)
            end)

            it("clears a string-keyed entry from a deposit", function()
                guildData.restock.pending[100] = nil
                guildData.restock.pending["100"] = { qty = 5, buyer = buyer, at = 3600 * 475200 }
                assert.is_true(GBL:_RestockOnRecordStored(deposit(), guildData))
                assert.is_nil(guildData.restock.pending["100"])
            end)

            -- #215 finding 2: a sync-received copy of an old deposit whose
            -- timestamp is corrupt or epoch-0 (#93) reads as now once StoreTx
            -- has rewritten it, passes the window, and clears an entry whose
            -- purchase is still in the mail.
            it("refuses a record whose timestamp StoreTx rewrote", function()
                assert.is_false(GBL:_RestockOnRecordStored(
                    deposit(), guildData, { timestampRewritten = true }))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("is told by StoreTx, so a corrupt sync copy does not clear the entry", function()
                local link = Helpers.makeItemLink(100, "Flask", 3)
                local rec = GBL:CreateTxRecord("deposit", MockWoW.player.name, link, 5, 1, nil, 0, 0, 0, 0)
                rec.timestamp = 0
                assert.is_true(GBL:StoreTx(rec, guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("ignores a deposit by another member", function()
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ player = "Jaina-TestRealm" }), guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("ignores a withdrawal and a move of the item", function()
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ type = "withdraw" }), guildData))
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ type = "move" }), guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("ignores a deposit of another item and a money record", function()
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ itemID = 200 }), guildData))
                assert.is_false(GBL:_RestockOnRecordStored(
                    { type = "deposit", player = buyer, amount = 5000, timestamp = 3600 * 475200 }, guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("ignores a deposit timestamped before the window and takes one inside it", function()
                local before = 3600 * 475200 - GBL.RESTOCK_PENDING_WINDOW - 1
                assert.is_false(GBL:_RestockOnRecordStored(deposit({ timestamp = before }), guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
                local edge = 3600 * 475200 - GBL.RESTOCK_PENDING_WINDOW
                assert.is_true(GBL:_RestockOnRecordStored(deposit({ timestamp = edge }), guildData))
                assert.is_nil(guildData.restock.pending[100])
            end)

            it("reads the guild the record was stored for, not the active one", function()
                local other = { restock = { pending = { [100] = { qty = 5, buyer = buyer, at = 3600 * 475200 } } } }
                assert.is_true(GBL:_RestockOnRecordStored(deposit(), other))
                assert.is_nil(other.restock.pending[100])
                assert.equals(5, guildData.restock.pending[100].qty)
                assert.is_false(GBL:_RestockOnRecordStored(deposit(), { restock = {} }))
                assert.is_false(GBL:_RestockOnRecordStored(deposit(), {}))
            end)

            it("fires from StoreBatchRecords once per stored record, not on the rescan of the same batch", function()
                local link = Helpers.makeItemLink(100, "Flask", 3)
                local batch = { GBL:CreateTxRecord("deposit", MockWoW.player.name, link, 2, 1, nil, 0, 0, 0, 0) }
                local stored, counts = GBL:StoreBatchRecords(batch, guildData, "transactions", nil)
                assert.equals(1, stored)
                assert.equals(3, guildData.restock.pending[100].qty)
                local again = { GBL:CreateTxRecord("deposit", MockWoW.player.name, link, 2, 1, nil, 0, 0, 0, 0) }
                assert.equals(0, (GBL:StoreBatchRecords(again, guildData, "transactions", counts)))
                assert.equals(3, guildData.restock.pending[100].qty)
            end)

            it("does not fire for a money record stored through StoreBatchRecords", function()
                local batch = { GBL:CreateMoneyTxRecord("deposit", MockWoW.player.name, 50000, 0, 0, 0, 0) }
                assert.equals(1, (GBL:StoreBatchRecords(batch, guildData, "moneyTransactions", nil)))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)

            it("fires from StoreTx once, not on the duplicate", function()
                local link = Helpers.makeItemLink(100, "Flask", 3)
                local rec = GBL:CreateTxRecord("deposit", MockWoW.player.name, link, 5, 1, nil, 0, 0, 0, 0)
                assert.is_true(GBL:StoreTx(rec, guildData))
                assert.is_nil(guildData.restock.pending[100])
                GBL:_RestockAddPending(100, 5)
                assert.is_false(GBL:StoreTx(rec, guildData))
                assert.equals(5, guildData.restock.pending[100].qty)
            end)
        end)

        describe("_RestockFormatAge", function()
            it("renders seconds, minutes, hours and days", function()
                assert.equals("0s ago", GBL:_RestockFormatAge(-5))
                assert.equals("45s ago", GBL:_RestockFormatAge(45))
                assert.equals("2m ago", GBL:_RestockFormatAge(150))
                assert.equals("3h ago", GBL:_RestockFormatAge(3 * 3600 + 59))
                assert.equals("2d ago", GBL:_RestockFormatAge(2 * 86400 + 3600))
            end)
        end)
    end)
end)
