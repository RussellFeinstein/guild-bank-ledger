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

    describe("auction-house event log (#199)", function()
        -- Every line the buy flow writes to the system channel. GetLog is
        -- newest-first, so these read by content and count, never by index.
        local function ahLines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Restock AH:", 1, true) == 1 then
                    out[#out + 1] = e.message
                end
            end
            return out
        end
        local function count(needle)
            local n = 0
            for _, m in ipairs(ahLines()) do
                if m:find(needle, 1, true) then n = n + 1 end
            end
            return n
        end
        local function findLine(needle)
            for _, m in ipairs(ahLines()) do
                if m:find(needle, 1, true) then return m end
            end
            return nil
        end
        local function oneItem()
            MockWoW.money = 1000000
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                { runStartMoney = 1000000 })
        end
        local function twoItems()
            MockWoW.money = 10000000
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 900 } },
                { runStartMoney = 10000000 })
        end

        it("logs the start of a purchase with the item, the quantity and the sweep flag", function()
            oneItem()
            GBL:StartRestockBuy(1)
            local line = findLine("Restock AH: start ")
            assert.is_not_nil(line)
            assert.truthy(line:find("it:100 x5", 1, true))
            assert.truthy(line:find("sweep=no", 1, true))
            assert.truthy(line:find("state=CONFIRMING", 1, true))
            assert.equals(1, count("Restock AH: start "))

            GBL:ResetRestockSearch()
            oneItem()
            GBL:StartRestockBuyAll()
            assert.is_not_nil(findLine("sweep=yes"))
        end)

        it("logs a price update with its unit and total price and changes nothing", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            local line = findLine("Restock AH: COMMODITY_PRICE_UPDATED ")
            assert.is_not_nil(line)
            assert.truthy(line:find("unit=" .. GBL:FormatMoney(4200), 1, true))
            assert.truthy(line:find("total=" .. GBL:FormatMoney(21000), 1, true))
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
        end)

        it("says whether throttle-ready issued the confirm", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, count("confirm issued"))
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, count("ignored (already issued)"))
            assert.equals(1, count("confirm issued"))
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("logs a commodity event outside CONFIRMING and keeps the throttle family quiet there", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)

            local before = #ahLines()
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(before + 1, #ahLines())
            assert.is_not_nil(findLine("ignored (state=READY)"))
            assert.is_true(GBL._restock.bought[1])
            assert.equals(1, #MockWoW.commodityPurchases.confirm)

            before = #ahLines()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
            MockAce.fireEvent("UI_ERROR_MESSAGE", 123, "You are too far away")
            assert.equals(before, #ahLines())
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("logs the throttle and price-unavailable events by name while a purchase is in flight", function()
            oneItem()
            GBL:StartRestockBuy(1)
            local names = {
                "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
                "COMMODITY_PRICE_UNAVAILABLE",
            }
            for _, n in ipairs(names) do MockAce.fireEvent(n) end
            for _, n in ipairs(names) do
                assert.equals(1, count("Restock AH: " .. n .. " "), n)
            end
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
        end)

        it("logs a UI error during a purchase with its text", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("UI_ERROR_MESSAGE", 123, "Not enough money")
            local line = findLine("Restock AH: UI_ERROR_MESSAGE ")
            assert.is_not_nil(line)
            assert.truthy(line:find("err=123", 1, true))
            assert.truthy(line:find("Not enough money", 1, true))
            assert.equals("CONFIRMING", GBL._restock.state)
        end)

        it("logs the step transition and the next purchase of a sweep", function()
            twoItems()
            GBL:StartRestockBuyAll()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            local handled = findLine("handled")
            assert.is_not_nil(handled)
            assert.truthy(handled:find("it:100 x5", 1, true))
            local step = findLine("next=2")
            assert.is_not_nil(step)
            assert.equals(1, step:find("Restock AH: step done ", 1, true))
            assert.equals(2, count("Restock AH: start "))
            assert.is_not_nil(findLine("pending=it:200 x2"))
            assert.equals("CONFIRMING", GBL._restock.state)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_not_nil(findLine("sweep complete"))
            assert.equals("READY", GBL._restock.state)
        end)

        it("registers the event set on the first buy with a handler for each, and drops it on reset", function()
            local events = GBL._restockAHEvents
            assert.is_table(events)
            assert.equals(10, #events)
            oneItem()
            GBL:StartRestockBuy(1)
            for _, name in ipairs(events) do
                assert.is_not_nil(MockAce.registeredEvents[name], name)
                assert.equals("function", type(GBL[name]), name)
            end

            GBL:ResetRestockSearch()
            local reset = findLine("Restock AH: reset ")
            assert.is_not_nil(reset)
            assert.truthy(reset:find("state=CONFIRMING", 1, true))
            for _, name in ipairs(events) do
                assert.is_nil(MockAce.registeredEvents[name], name)
            end
        end)

        it("logs a skip with its reason", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(1)  -- 1 gold
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 },  -- 5g each, past the budget
                  [2] = { itemKey = { itemID = 200 }, minPrice = 900 } },
                { runStartMoney = 10000000 })
            GBL:StartRestockBuyAll()
            local skip = findLine("Restock AH: skip ")
            assert.is_not_nil(skip)
            assert.truthy(skip:find("it:100", 1, true))
            assert.truthy(skip:find("budget", 1, true))
            assert.is_true(GBL._restock.skipped[1])
            assert.is_not_nil(findLine("pending=it:200 x2"))
            assert.equals("CONFIRMING", GBL._restock.state)
        end)
    end)
end)
