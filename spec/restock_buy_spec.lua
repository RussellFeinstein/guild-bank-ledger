------------------------------------------------------------------------
-- restock_buy_spec.lua — Tests for the Auctionator buy/confirm flow (M4c).
--
-- The buy state machine is driven by WoW commodity events. MockAce.fireEvent
-- dispatches them to the registered handlers, and the mock C_AuctionHouse /
-- GetMoney (spec/mock_wow.lua) record purchases and model the wallet, so the
-- real-gold path is unit-tested here rather than only in-game.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

describe("Restock buy", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
    end)

    -- Put the addon directly into a READY state with given items/results so the
    -- buy flow can be exercised without running an Auctionator search.
    local function readyState(items, results, opts)
        opts = opts or {}
        GBL._restock = {
            state = "READY",
            activeItems = items,
            resultRows = results,
            bought = {},
            skipped = {},
            searchGen = 1,
            runStartMoney = opts.runStartMoney or 0,
            buyAll = false,
        }
    end

    describe("per-item buy", function()
        it("starts, confirms on throttle-ready, succeeds, and marks bought", function()
            MockWoW.money = 1000000
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                { runStartMoney = 1000000 })

            GBL:StartRestockBuy(1)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[1].itemID)
            assert.equals(5, MockWoW.commodityPurchases.start[1].quantity)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(100, MockWoW.commodityPurchases.confirm[1].itemID)

            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)  -- per-item stops after one
        end)

        it("returns to READY and clears pending on a failed purchase", function()
            MockWoW.money = 1000000
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                { runStartMoney = 1000000 })

            GBL:StartRestockBuy(1)
            assert.equals("CONFIRMING", GBL._restock.state)
            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(GBL._restock.pendingIndex)
            assert.is_nil(GBL._restock.bought[1])
        end)

        it("skips an item whose lowest price is over its maxPrice", function()
            GBL:SetRestockItemOverride(100, { maxPrice = 1 })  -- 1 gold cap
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 } },  -- 5g > 1g
                { runStartMoney = 1000000 })

            GBL:StartRestockBuy(1)
            assert.is_true(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- nothing bought
        end)

        it("confirms only once when throttle-ready fires twice", function()
            MockWoW.money = 1000000
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                { runStartMoney = 1000000 })
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- repeat
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("refuses a per-item buy once the budget is already spent", function()
            GBL:SetRestockBudget(10)  -- 10 gold cap
            readyState(
                { { itemID = 100, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 100 } },
                { runStartMoney = 1000000 })  -- 100 gold baseline
            MockWoW.money = 800000  -- spent 20g, over the 10g cap
            GBL:StartRestockBuy(1)
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)
        end)

        it("refuses a buy the wallet cannot afford", function()
            MockWoW.money = 1000  -- 10 silver on hand
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 } },  -- 5g each
                { runStartMoney = 1000 })
            GBL:StartRestockBuy(1)
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- never attempted
        end)
    end)

    describe("Buy-all sweep", function()
        it("works without a budget, bounded by affordability", function()
            MockWoW.money = 1000000  -- enough on hand
            readyState(  -- no budget set
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                { runStartMoney = 1000000 })

            GBL:StartRestockBuyAll()
            assert.equals("CONFIRMING", GBL._restock.state)  -- sweep started, no budget needed
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("skips an unaffordable item but continues to an affordable one", function()
            MockWoW.money = 100000  -- 10 gold on hand
            readyState(
                { { itemID = 100, needed = 5 },   -- 5 x 5g = 25g, unaffordable
                  { itemID = 200, needed = 1 } },  -- 1 x 1g = 1g, affordable
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 10000 } },
                { runStartMoney = 100000 })

            GBL:StartRestockBuyAll()
            assert.is_true(GBL._restock.skipped[1])            -- item 1 unaffordable
            assert.equals("CONFIRMING", GBL._restock.state)    -- item 2 in flight
            assert.equals(200, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("counts spend so far even if the wallet has not updated (lag-safe)", function()
            -- Wallet reads full the whole time (simulating GetMoney lag); the
            -- lag-free estimate must still stop item 2.
            MockWoW.money = 100000  -- 10g, never decremented
            readyState(
                { { itemID = 100, needed = 1 },   -- 6g
                  { itemID = 200, needed = 1 } },  -- 6g; 6+6 = 12g > 10g on hand
                { [1] = { itemKey = { itemID = 100 }, minPrice = 60000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 60000 } },
                { runStartMoney = 100000 })

            GBL:StartRestockBuyAll()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- item 1 bought
            assert.is_true(GBL._restock.bought[1])
            assert.is_true(GBL._restock.skipped[2])            -- 4g left (lag-free) < 6g
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
        end)

        it("completes an uncapped sweep over multiple affordable items", function()
            MockWoW.money = 10000000  -- plenty, no budget
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 1000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 1000 } },
                { runStartMoney = 10000000 })

            GBL:StartRestockBuyAll()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.is_true(GBL._restock.bought[2])
            assert.equals("READY", GBL._restock.state)  -- terminated cleanly
            assert.is_false(GBL._restock.buyAll)
            assert.equals(2, #MockWoW.commodityPurchases.start)
        end)

        it("sweeps through every eligible item until none remain", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(5000)
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 1000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 1000 } },
                { runStartMoney = 10000000 })

            GBL:StartRestockBuyAll()
            assert.equals("CONFIRMING", GBL._restock.state)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.equals("CONFIRMING", GBL._restock.state)  -- auto-advanced to item 2

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[2])
            assert.equals("READY", GBL._restock.state)  -- sweep complete
            assert.is_false(GBL._restock.buyAll)
            assert.equals(2, #MockWoW.commodityPurchases.start)
        end)

        it("stops when the budget is reached mid-sweep", function()
            GBL:SetRestockBudget(100)  -- 100 gold cap
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 1000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 1000 } },
                { runStartMoney = 2000000 })  -- 200 gold on hand
            MockWoW.money = 2000000

            GBL:StartRestockBuyAll()           -- begins item 1
            MockWoW.money = 500000             -- spent 150g, now over the 100g cap
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")

            assert.is_true(GBL._restock.bought[1])
            assert.is_nil(GBL._restock.bought[2])         -- item 2 never bought
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- only one buy started
        end)

        it("skips an item whose estimated cost would exceed the budget", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(10)  -- 10 gold
            readyState(
                { { itemID = 100, needed = 100 } },  -- 100 x 5g = 500g, far over 10g
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 } },  -- 5g each
                { runStartMoney = 10000000 })

            GBL:StartRestockBuyAll()
            assert.is_true(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- never started
        end)

        it("ignores a duplicate success mid-sweep (no mis-credit to the next item)", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(5000)
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 1000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 1000 } },
                { runStartMoney = 10000000 })

            GBL:StartRestockBuyAll()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- item 1 done, advance to item 2
            assert.is_true(GBL._restock.bought[1])
            assert.equals("CONFIRMING", GBL._restock.state)   -- item 2 in flight

            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- duplicate/late success
            assert.is_nil(GBL._restock.bought[2])             -- not mis-credited
        end)
    end)

    describe("pure buy helpers", function()
        it("_RestockSpent clamps at 0", function()
            assert.equals(0, GBL:_RestockSpent(100, 200))
            assert.equals(50, GBL:_RestockSpent(200, 150))
        end)

        it("_RestockBudgetExceeded compares spent copper to the budget in gold", function()
            assert.is_false(GBL:_RestockBudgetExceeded(0, 0))        -- no budget set
            assert.is_false(GBL:_RestockBudgetExceeded(50000, 0))    -- no budget set
            assert.is_false(GBL:_RestockBudgetExceeded(99999, 10))   -- 9.99g < 10g
            assert.is_true(GBL:_RestockBudgetExceeded(100000, 10))   -- 10g >= 10g
        end)

        it("_RestockNextBuyable skips needed=0, bought, and result-less rows", function()
            local st = {
                activeItems = {
                    { itemID = 1, needed = 0 },  -- has a result but needs nothing
                    { itemID = 2, needed = 5 },  -- bought
                    { itemID = 3, needed = 5 },  -- eligible
                },
                resultRows = { [1] = { minPrice = 1 }, [2] = { minPrice = 1 }, [3] = { minPrice = 1 } },
                bought = { [2] = true },
                skipped = {},
            }
            assert.equals(3, GBL:_RestockNextBuyable(st))  -- needed=0 is what excludes idx 1
        end)

        it("_RestockNextBuyable returns nil when nothing is eligible", function()
            local st = {
                activeItems = { { itemID = 1, needed = 5 } },
                resultRows = {},  -- no result for index 1
                bought = {},
                skipped = {},
            }
            assert.is_nil(GBL:_RestockNextBuyable(st))
        end)
    end)
end)
