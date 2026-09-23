------------------------------------------------------------------------
-- restock_buy_spec.lua — Tests for the Auctionator buy/confirm flow (M4c).
--
-- The buy state machine is driven by WoW commodity events. MockAce.fireEvent
-- dispatches them to the registered handlers, and the mock C_AuctionHouse /
-- GetMoney (spec/mock_wow.lua) record purchases and model the wallet, so the
-- real-gold path is unit-tested here rather than only in-game.
--
-- The event order these tests drive is the one measured on 2026-09-19 and
-- 2026-09-20 (#199): a start is answered by COMMODITY_PRICE_UPDATED in the
-- frame of the server's response, and AUCTION_HOUSE_THROTTLED_SYSTEM_READY
-- follows every response about 0.2s later. The confirm goes out on the READY
-- that follows the price (six of six in the 2026-09-20 capture). A start goes
-- out only from a click: C_AuctionHouse.StartCommoditiesPurchase requires a
-- hardware event, and one issued from an event handler or a timer does
-- nothing at all (four of four). The mock cannot model that gate, so what
-- this file pins is the call graph: nothing but the two click entry points
-- ever reaches a start.
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
        -- The auction house is open unless a case closes it (#211): a start
        -- is refused pre-start without the frame. The mock has none.
        _G.AuctionHouseFrame = { IsShown = function() return true end }
        -- The v0.39.20 sequence (the confirm goes out on the READY after the
        -- price) is what every case below pins; the pause is on by default
        -- in production and only the "confirm at price" describe turns it on.
        GBL.db.profile.restock = GBL.db.profile.restock or {}
        GBL.db.profile.restock.confirmAtPrice = false
    end)

    after_each(function()
        _G.AuctionHouseFrame = nil
    end)

    -- Put the addon directly into a READY state with given items/results so the
    -- buy flow can be exercised without running an Auctionator search. The
    -- spend model (#60): spentEstimate is what the search has spent, and the
    -- wallet baseline pair (walletBase, spentAtBase) bounds affordability.
    local function readyState(items, results, opts)
        opts = opts or {}
        GBL._restock = {
            state = "READY",
            activeItems = items,
            resultRows = results,
            bought = {},
            skipped = {},
            searchGen = 1,
            walletBase = opts.walletBase or 0,
            spentAtBase = opts.spentAtBase or 0,
            spentEstimate = opts.spentEstimate or 0,
            buyAll = false,
        }
    end

    local function oneItem()
        MockWoW.money = 1000000
        readyState(
            { { itemID = 100, needed = 5 } },
            { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
            { walletBase = 1000000 })
    end

    local function twoItems()
        MockWoW.money = 10000000
        readyState(
            { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
            { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 },
              [2] = { itemKey = { itemID = 200 }, minPrice = 900 } },
            { walletBase = 10000000 })
    end

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
    local function printCount(needle)
        local n = 0
        for _, line in ipairs(MockWoW.prints) do
            if line:find(needle, 1, true) then n = n + 1 end
        end
        return n
    end

    -- The shared timer family is in spec/helpers.lua (#117), which carries the
    -- filter rules and the three harness traps. These four wrappers stay
    -- because the delay they name is the intent: the one step timer is armed
    -- at RESTOCK_STEP_TIMEOUT for a start or a confirm and at
    -- RESTOCK_PAUSE_TIMEOUT while a quote waits for the player (#211), and a
    -- settled step or a reset leaves neither pending.
    local function liveStepTimers() return Helpers.timersAt(GBL.RESTOCK_STEP_TIMEOUT) end
    local function livePauseTimers() return Helpers.timersAt(GBL.RESTOCK_PAUSE_TIMEOUT) end
    local function fireStepTimers() return Helpers.fireTimersAt(GBL.RESTOCK_STEP_TIMEOUT) end
    local function firePauseTimers() return Helpers.fireTimersAt(GBL.RESTOCK_PAUSE_TIMEOUT) end

    -- The measured good sequence for one purchase, after its start: the price
    -- in the response frame, then the READY that carries the confirm out.
    local function priceThenReady(unit, total)
        MockAce.fireEvent("COMMODITY_PRICE_UPDATED", unit, total)
        MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    end

    describe("per-item buy", function()
        it("starts, prices, confirms on the ready that follows, succeeds, and marks bought", function()
            oneItem()
            GBL:StartRestockBuy(1)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[1].itemID)
            assert.equals(5, MockWoW.commodityPurchases.start[1].quantity)

            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)  -- not inside the response frame
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(100, MockWoW.commodityPurchases.confirm[1].itemID)
            assert.equals(5, MockWoW.commodityPurchases.confirm[1].quantity)

            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)  -- per-item stops after one
        end)

        it("records the priced total beside the bought flag, for the row (#214)", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.equals(21000, GBL._restock.boughtTotal[1])
            GBL:ResetRestockSearch()
            assert.is_nil(next(GBL._restock.boughtTotal))
        end)

        it("returns to READY and clears pending on a failed purchase", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
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
                { walletBase = 1000000 })

            GBL:StartRestockBuy(1)
            assert.is_truthy(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- nothing bought
        end)

        it("confirms only once however often the price and the ready repeat", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)  -- repeat
            assert.equals(1, count("ignored (price already in)"))
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- repeat
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, count("ignored (already issued)"))
        end)

        it("refuses a per-item buy once the budget is already spent", function()
            GBL:SetRestockBudget(10)  -- 10 gold cap
            MockWoW.money = 1000000
            readyState(
                { { itemID = 100, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 100 } },
                { walletBase = 1000000, spentEstimate = 200000 })  -- 20g spent this search, over the cap
            GBL:StartRestockBuy(1)
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)
        end)

        it("reads the budget off what the search spent, not off the wallet (#60)", function()
            GBL:SetRestockBudget(10)  -- 10 gold cap
            readyState(
                { { itemID = 100, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 100 } },
                { walletBase = 1000000 })  -- 100 gold baseline
            MockWoW.money = 800000  -- 20g left the wallet elsewhere; this search spent nothing
            GBL:StartRestockBuy(1)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
        end)

        it("refuses a buy the wallet cannot afford", function()
            MockWoW.money = 1000  -- 10 silver on hand
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 } },  -- 5g each
                { walletBase = 1000 })
            GBL:StartRestockBuy(1)
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- never attempted
        end)
    end)

    describe("Buy next", function()
        it("works without a budget, bounded by affordability", function()
            oneItem()  -- no budget set
            GBL:StartRestockBuyNext()
            assert.equals("CONFIRMING", GBL._restock.state)  -- started, no budget needed
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("skips an unaffordable item and starts the affordable one in the same click", function()
            MockWoW.money = 100000  -- 10 gold on hand
            readyState(
                { { itemID = 100, needed = 5 },   -- 5 x 5g = 25g, unaffordable
                  { itemID = 200, needed = 1 } },  -- 1 x 1g = 1g, affordable
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 10000 } },
                { walletBase = 100000 })

            GBL:StartRestockBuyNext()
            assert.is_truthy(GBL._restock.skipped[1])            -- item 1 unaffordable
            assert.equals("CONFIRMING", GBL._restock.state)    -- item 2 in flight
            assert.equals(200, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("counts spend so far even if the wallet has not updated (lag-safe)", function()
            -- Wallet reads full the whole time (simulating GetMoney lag); the
            -- lag-free estimate must still refuse item 2 on the next click.
            MockWoW.money = 100000  -- 10g, never decremented
            readyState(
                { { itemID = 100, needed = 1 },   -- 6g
                  { itemID = 200, needed = 1 } },  -- 6g; 6+6 = 12g > 10g on hand
                { [1] = { itemKey = { itemID = 100 }, minPrice = 60000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 60000 } },
                { walletBase = 100000 })

            GBL:StartRestockBuyNext()
            priceThenReady(60000, 60000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- item 1 bought
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)
            GBL:StartRestockBuyNext()
            assert.is_truthy(GBL._restock.skipped[2])            -- 4g left (lag-free) < 6g
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
        end)

        it("buys the list one click at a time", function()
            twoItems()  -- plenty, no budget
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)          -- settled, nothing started
            assert.equals(1, #MockWoW.commodityPurchases.start)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- the success's own READY
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- still nothing: no click

            GBL:StartRestockBuyNext()
            assert.equals("CONFIRMING", GBL._restock.state)
            priceThenReady(900, 1800)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.is_true(GBL._restock.bought[2])
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(2, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, count("Restock AH: step done state=READY pending=none t=+0.00s busy=yes ready=true next=2 awaiting click"))
            assert.equals(1, count("list done"))
            assert.is_true(Helpers.printContains("Nothing left to buy"))
        end)

        it("settles to READY when the budget is reached after a purchase, and refuses the next click", function()
            GBL:SetRestockBudget(100)  -- 100 gold cap
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 3 }, { itemID = 300, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 1000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 1000 },
                  [3] = { itemKey = { itemID = 300 }, minPrice = 1000 } },
                { walletBase = 2000000 })  -- 200 gold on hand
            MockWoW.money = 2000000

            GBL:StartRestockBuyNext()          -- begins item 1
            priceThenReady(200000, 1000000)    -- quoted exactly 100g: passes at price, reaches the cap
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")

            assert.is_true(GBL._restock.bought[1])
            assert.is_nil(GBL._restock.bought[2])         -- item 2 never bought
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("Restock AH: step done "))
            assert.equals(1, count("budget reached"))
            assert.is_true(Helpers.printContains("Budget reached; stopping"))
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- only one buy started

            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- refused pre-start
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            -- The refusal ends the walk: row 3 is not tried and told the same thing.
            assert.equals(1, count("Restock AH: skip "))
            assert.equals(1, printCount("Budget of 100 g reached"))
            assert.is_nil(GBL._restock.skipped[3])
            assert.equals(0, printCount("Nothing left to buy"))
        end)

        it("skips an item whose estimated cost would exceed the budget", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(10)  -- 10 gold
            readyState(
                { { itemID = 100, needed = 100 } },  -- 100 x 5g = 500g, far over 10g
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 } },  -- 5g each
                { walletBase = 10000000 })

            GBL:StartRestockBuyNext()
            assert.is_truthy(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.start)  -- never started
            assert.equals(0, printCount("Nothing left to buy"))    -- a row was tried and refused, which is not that
        end)

        it("says so when a click finds nothing to buy", function()
            oneItem()
            GBL._restock.bought[1] = true
            GBL:StartRestockBuyNext()
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.is_true(Helpers.printContains("Nothing left to buy"))
        end)

        it("ignores a duplicate success between clicks (no mis-credit to the next item)", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- item 1 done
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)

            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- duplicate/late success
            assert.is_nil(GBL._restock.bought[2])             -- not mis-credited
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("ignored (state=READY)"))

            GBL:StartRestockBuyNext()
            assert.equals("CONFIRMING", GBL._restock.state)   -- item 2 in flight
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")  -- success with no confirm out
            assert.is_nil(GBL._restock.bought[2])             -- still not mis-credited
            assert.equals(1, count("ignored (unsolicited)"))
        end)
    end)

    describe("confirms on the ready that follows the price (#199)", function()
        it("holds the confirm until the ready after the price, and says so on both lines", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            local price = findLine("Restock AH: COMMODITY_PRICE_UPDATED ")
            assert.is_not_nil(price)
            assert.truthy(price:find("price in, confirm waits for ready", 1, true))
            assert.is_true(GBL._restock.priceIn)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(100, MockWoW.commodityPurchases.confirm[1].itemID)
            local ready = findLine("Restock AH: AUCTION_HOUSE_THROTTLED_SYSTEM_READY ")
            assert.is_not_nil(ready)
            assert.truthy(ready:find("confirm issued", 1, true))
            assert.equals("CONFIRMING", GBL._restock.state)
        end)

        it("does not confirm on a ready before the price is in, and confirms on the price once it is", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.is_not_nil(findLine("ignored (confirm waits for price)"))
            assert.equals("CONFIRMING", GBL._restock.state)

            -- The throttle has reported ready since our start, so the price
            -- event is not inside a response frame that a call would drown in.
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            local price = findLine("Restock AH: COMMODITY_PRICE_UPDATED ")
            assert.truthy(price:find("confirm issued", 1, true))
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.is_not_nil(findLine("AUCTION_HOUSE_THROTTLED_SYSTEM_READY state=CONFIRMING pending=it:100 x5 t=+0.00s busy=no ready=true ignored (already issued)"))
        end)

        it("logs and ignores a price that arrives outside CONFIRMING", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)  -- a late or foreign price
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals("READY", GBL._restock.state)
            assert.is_not_nil(findLine("COMMODITY_PRICE_UPDATED state=READY"))
            assert.is_not_nil(findLine("ignored (state=READY)"))
        end)

        it("refuses a price event with no usable total instead of confirming blind", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED")  -- carries nothing
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals(1, count("refused (no usable total)"))
            assert.equals(1, count("Restock AH: step failed "))
            assert.equals(1, count("no usable price"))
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(GBL._restock.skipped[1])  -- a single buy stays buyable

            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 0, 0)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(2, #MockWoW.commodityPurchases.cancel)
        end)
    end)

    describe("starts a purchase only from a click (#199)", function()
        it("settles after a success and starts the next row on the next click", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- not started inside the success
            assert.is_true(GBL._restock.bought[1])
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(1, GBL:_RestockBuyableCount(GBL._restock))
            assert.is_true(GBL._restock.throttleBusy)           -- the success's READY is still due

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- and not on the READY either
            assert.is_false(GBL._restock.throttleBusy)

            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(200, MockWoW.commodityPurchases.start[2].itemID)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.is_true(GBL._restock.buyAll)
        end)

        it("starts at once from a click in the busy window after a success, and the confirm still waits for the ready", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.is_true(GBL._restock.throttleBusy)           -- the 0.2s before the success's READY

            GBL:StartRestockBuyNext()                            -- a click in that window
            assert.equals(2, #MockWoW.commodityPurchases.start)  -- issued at once: waiting would lose the click
            assert.equals("CONFIRMING", GBL._restock.state)
            local start = findLine("pending=it:200 x2")
            assert.is_not_nil(start)
            assert.truthy(start:find("Restock AH: start state=CONFIRMING", 1, true))
            assert.truthy(start:find(" busy=yes ", 1, true))

            -- The client queues a message issued while busy and holds the
            -- READY until it has been answered (capture lines 79-82).
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT")
            assert.equals(1, count("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED state=CONFIRMING pending=it:200 x2"))
            assert.equals(1, count("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT state=CONFIRMING pending=it:200 x2"))
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 900, 1800)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)  -- item 1's only
            assert.equals(1, count("unit=" .. GBL:FormatMoney(900) .. " total=" .. GBL:FormatMoney(1800) .. " price in, confirm waits for ready"))
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(2, #MockWoW.commodityPurchases.confirm)
            assert.equals(200, MockWoW.commodityPurchases.confirm[2].itemID)
            assert.equals(2, count("confirm issued"))
        end)

        it("walks past refused rows inside the same click and starts the first it can", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(100)  -- 100 gold
            readyState(
                { { itemID = 100, needed = 1 },    -- 1g
                  { itemID = 200, needed = 1000 }, -- 1000 x 1g = 1000g, over the budget on its own
                  { itemID = 300, needed = 1 } },  -- 1g
                { [1] = { itemKey = { itemID = 100 }, minPrice = 10000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 10000 },
                  [3] = { itemKey = { itemID = 300 }, minPrice = 10000 } },
                { walletBase = 10000000 })
            GBL:StartRestockBuyNext()
            priceThenReady(10000, 10000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(1, count("Restock AH: step done "))

            GBL:StartRestockBuyNext()
            assert.is_truthy(GBL._restock.skipped[2])
            assert.equals(2, #MockWoW.commodityPurchases.start)   -- item 3 started in the same call
            assert.equals(300, MockWoW.commodityPurchases.start[2].itemID)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, count("Restock AH: skip "))
            assert.equals(1, count("Restock AH: step done "))     -- no step line between the skip and the start
            -- The skip precedes the start it made room for. GetLog is
            -- newest-first, so the start sits earlier in the list.
            local lines = ahLines()
            local skipAt, startAt
            for i, m in ipairs(lines) do
                if m:find("Restock AH: skip ", 1, true) then skipAt = i end
                if m:find("pending=it:300 x1", 1, true) and m:find("Restock AH: start ", 1, true) then startAt = i end
            end
            assert.is_true(startAt < skipAt)
        end)

        it("returns from a click without spinning when the auction-house API is missing", function()
            twoItems()
            C_AuctionHouse.StartCommoditiesPurchase = nil
            GBL:StartRestockBuyNext()
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("no auction-house API"))
            assert.equals(1, printCount("Open the Auction House to buy"))
            assert.is_nil(GBL._restock.skipped[1])   -- not the row's fault
            assert.equals(0, printCount("Nothing left to buy"))
        end)

        it("refuses the click once while a result is outstanding", function()
            twoItems()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            fireStepTimers()
            assert.is_not_nil(GBL._restock.unanswered)

            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("result outstanding for it:100"))
            assert.equals(1, printCount("Waiting on the result"))
        end)

        it("never starts a purchase from an event or a timer", function()
            twoItems()
            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
            local everything = {
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED" },
                { "COMMODITY_PRICE_UPDATED", 4200, 21000 },
                { "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED" },
                { "COMMODITY_PURCHASE_SUCCEEDED" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" },
                { "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" },
                { "UI_ERROR_MESSAGE", 1, "x" },
                { "COMMODITY_PRICE_UNAVAILABLE" },
                { "COMMODITY_PURCHASE_FAILED" },
                { "COMMODITY_PRICE_UPDATED", 900, 1800 },
                { "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" },
            }
            for _, ev in ipairs(everything) do
                MockAce.fireEvent(unpack(ev))
                assert.equals(1, #MockWoW.commodityPurchases.start, ev[1])
            end
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(0, liveStepTimers())

            -- The two timer outcomes: no price after a start, no result after a confirm.
            twoItems()
            GBL:StartRestockBuyNext()
            fireStepTimers()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            fireStepTimers()
            assert.equals(3, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
        end)
    end)

    describe("a step cannot wait forever (#199)", function()
        it("exports the timeout the step timers are armed with", function()
            assert.equals(5, GBL.RESTOCK_STEP_TIMEOUT)
        end)

        it("cancels a start that gets no price, skips the row under Buy next, and waits for the next click", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- the throttle is free, only the price is missing
            assert.equals(1, #MockWoW.commodityPurchases.start)
            fireStepTimers()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_truthy(GBL._restock.skipped[1])
            assert.is_nil(GBL._restock.bought[1])
            assert.equals(1, count("Restock AH: step failed "))
            assert.equals(1, count("no price within"))
            assert.equals(1, #MockWoW.commodityPurchases.start)   -- item 2 waits for a click
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(0, #MockWoW.commodityPurchases.confirm)

            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(200, MockWoW.commodityPurchases.start[2].itemID)
            assert.equals("CONFIRMING", GBL._restock.state)
        end)

        it("cancels a start that got neither price nor ready and settles; the next click starts regardless", function()
            twoItems()
            GBL:StartRestockBuyNext()
            fireStepTimers()                                       -- five seconds of nothing at all
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_truthy(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.is_nil(GBL._restock.skipped[2])                 -- item 2 was never attempted
            assert.equals(0, liveStepTimers())
            assert.is_true(GBL._restock.throttleBusy)              -- no READY ever came

            GBL:StartRestockBuyNext()                              -- a click is a click
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, liveStepTimers())
        end)

        it("cancels a single buy that gets no price and leaves the row buyable", function()
            oneItem()
            GBL:StartRestockBuy(1)
            fireStepTimers()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(GBL._restock.pendingItemID)
            assert.is_true(Helpers.printContains("did not price it"))
        end)

        it("stops without cancelling when a confirm gets no result, and credits the late result to that row", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            fireStepTimers()
            assert.equals(0, #MockWoW.commodityPurchases.cancel)  -- a cancel means nothing after a confirm
            assert.is_nil(GBL._restock.bought[1])
            assert.is_false(GBL._restock.buyAll)
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)   -- item 2 never started
            assert.equals(1, count("Restock AH: step failed "))
            assert.equals(1, count("no result within"))
            assert.is_true(Helpers.printContains("mail"))
            assert.equals(1, GBL._restock.unanswered.index)
            assert.equals(100, GBL._restock.unanswered.itemID)

            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")     -- the late result
            assert.is_true(GBL._restock.bought[1])
            assert.equals(21000, GBL._restock.spentEstimate)
            assert.is_nil(GBL._restock.unanswered)
            assert.equals(1, count("handled (late, it:100 x5)"))
        end)

        it("starts nothing while a result is outstanding, and frees the run on a late failure", function()
            twoItems()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            fireStepTimers()
            assert.is_not_nil(GBL._restock.unanswered)

            GBL:StartRestockBuy(2)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.is_not_nil(findLine("result outstanding for it:100"))
            assert.is_true(Helpers.printContains("Waiting on the result"))

            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")        -- the late answer: nothing bought
            assert.is_nil(GBL._restock.unanswered)
            assert.is_nil(GBL._restock.bought[1])
            assert.equals(1, count("handled (late, it:100 x5)"))
            assert.is_true(Helpers.printContains("failed after all"))

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- the late answer's own READY
            GBL:StartRestockBuy(2)
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals("CONFIRMING", GBL._restock.state)
        end)

        it("names a drop or an error the auction house reported when the result never comes", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("UI_ERROR_MESSAGE", 123, "Not enough money")
            fireStepTimers()
            assert.is_true(Helpers.printContains("The auction house reported: Not enough money"))
            assert.is_true(Helpers.printContains("mail"))
            assert.is_not_nil(GBL._restock.unanswered)
        end)

        it("cancels the step timer when the step settles", function()
            oneItem()
            GBL:StartRestockBuy(1)
            assert.equals(1, liveStepTimers())
            priceThenReady(4200, 21000)
            assert.equals(1, liveStepTimers())  -- the confirm's own timer replaced the start's
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(0, liveStepTimers())
            assert.is_true(GBL._restock.bought[1])
        end)

        it("cancels the step timer on reset", function()
            oneItem()
            GBL:StartRestockBuy(1)
            assert.equals(1, liveStepTimers())
            GBL:ResetRestockSearch()
            assert.equals(0, liveStepTimers())
            assert.equals("IDLE", GBL._restock.state)
        end)

        it("leaves no live timer between steps and one per step", function()
            twoItems()
            GBL:StartRestockBuyNext()
            assert.equals(1, liveStepTimers())
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(0, liveStepTimers())  -- settled: nothing is waiting for anything
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(0, liveStepTimers())
            GBL:StartRestockBuyNext()
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, liveStepTimers())  -- item 2's start, nothing of item 1's
        end)
    end)

    describe("checks the priced total before confirming (#199)", function()
        it("refuses a total the wallet cannot cover, cancels, and settles for the next click", function()
            MockWoW.money = 1000000  -- 100g
            readyState(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 },  -- estimate 2.1g, fine
                  [2] = { itemKey = { itemID = 200 }, minPrice = 900 } },
                { walletBase = 1000000 })
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 400000, 2000000)  -- 200g quoted
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_truthy(GBL._restock.skipped[1])
            assert.equals(1, count("Restock AH: step failed "))
            assert.equals(1, count("refused (cannot afford at price)"))
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(1, #MockWoW.commodityPurchases.start)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.start)
            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(200, MockWoW.commodityPurchases.start[2].itemID)
        end)

        it("refuses a total past the budget, cancels, and leaves a single buy's row buyable", function()
            MockWoW.money = 10000000
            GBL:SetRestockBudget(10)  -- 10 gold
            readyState(
                { { itemID = 100, needed = 5 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },  -- estimate 2.1g, fine
                { walletBase = 10000000 })
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 30000, 150000)  -- 15g quoted
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals(1, count("Restock AH: step failed "))
            assert.equals(1, count("refused (budget at price)"))
            assert.equals("READY", GBL._restock.state)
        end)

        it("adds the priced total to the spend estimate on success", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(5000, 25000)  -- above the 21000 lower bound
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(25000, GBL._restock.spentEstimate)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:StartRestockBuyNext()
            priceThenReady(900, 1800)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(25000 + 1800, GBL._restock.spentEstimate)
        end)
    end)

    describe("cancels what it will not confirm (#199)", function()
        it("skips a row whose price is unavailable, cancels, and settles for the next click", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UNAVAILABLE")
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.is_truthy(GBL._restock.skipped[1])
            assert.is_not_nil(findLine("Restock AH: step failed "))
            assert.is_not_nil(findLine("no price available"))
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals("CONFIRMING", GBL._restock.state)
        end)

        it("logs and ignores a price-unavailable outside CONFIRMING", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            MockAce.fireEvent("COMMODITY_PRICE_UNAVAILABLE")  -- late or foreign
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_true(GBL._restock.bought[1])
            assert.equals("READY", GBL._restock.state)
            assert.is_not_nil(findLine("COMMODITY_PRICE_UNAVAILABLE state=READY"))
        end)

        it("ignores a price-unavailable once the confirm is out, so the real result still lands", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            MockAce.fireEvent("COMMODITY_PRICE_UNAVAILABLE")
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, count("COMMODITY_PRICE_UNAVAILABLE state=CONFIRMING pending=it:100 x5 t=+0.00s busy=yes ready=true ignored (already issued)"))
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[1])
            assert.equals(21000, GBL._restock.spentEstimate)
        end)

        it("ignores a purchase-failed with no confirm out, leaving the step to its timer", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")  -- late or foreign
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, liveStepTimers())
            assert.equals(1, count("COMMODITY_PURCHASE_FAILED state=CONFIRMING pending=it:100 x5 t=+0.00s busy=yes ready=true ignored (unsolicited)"))
            assert.is_false(Helpers.printContains("Purchase failed"))
            priceThenReady(4200, 21000)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("cancels on reset before the confirm has gone out, and not after", function()
            oneItem()
            GBL:StartRestockBuy(1)
            GBL:ResetRestockSearch()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            local reset = findLine("Restock AH: reset ")
            assert.is_not_nil(reset)
            assert.truthy(reset:find("cancel issued", 1, true))
            assert.equals("IDLE", GBL._restock.state)
            assert.is_false(GBL._restock.throttleBusy)

            GBL:ClearLog("system")
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            GBL:ResetRestockSearch()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)  -- unchanged
            reset = findLine("Restock AH: reset ")
            assert.is_not_nil(reset)
            assert.truthy(reset:find("confirm already issued", 1, true))

            GBL:ClearLog("system")
            oneItem()
            GBL:ResetRestockSearch()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)  -- nothing pending, nothing cancelled
        end)
    end)

    describe("a budget change brings back the rows it skipped (#199)", function()
        local function twoOverBudget()
            MockWoW.money = 100000000
            GBL:SetRestockBudget(10)  -- 10 gold
            readyState(
                { { itemID = 100, needed = 100 }, { itemID = 200, needed = 100 } },  -- 500g each row
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 50000 } },
                { walletBase = 100000000 })
        end

        it("records why a row was skipped", function()
            twoOverBudget()
            GBL:StartRestockBuyNext()
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.equals("budget on this buy", GBL._restock.skipped[1])
            assert.equals("budget on this buy", GBL._restock.skipped[2])
            assert.equals(0, GBL:_RestockBuyableCount(GBL._restock))
        end)

        it("clears budget skips when the budget changes, and the next click buys them", function()
            twoOverBudget()
            GBL:StartRestockBuyNext()
            GBL:SetRestockBudget(10000)
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_nil(GBL._restock.skipped[2])
            assert.equals(2, GBL:_RestockBuyableCount(GBL._restock))
            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("clears a refusal at price for the budget too, and leaves the other reasons alone", function()
            MockWoW.money = 100000000
            GBL:SetRestockBudget(10)
            GBL:SetRestockItemOverride(300, { maxPrice = 1 })
            readyState(
                { { itemID = 100, needed = 5 },    -- estimate 2.1g, quoted 15g: refused at price
                  { itemID = 200, needed = 1 },    -- no price comes: timeout
                  { itemID = 300, needed = 1 } },  -- over its max price
                { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 4200 },
                  [3] = { itemKey = { itemID = 300 }, minPrice = 50000 } },
                { walletBase = 100000000 })
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 30000, 150000)  -- 15g, past 10g
            assert.equals("budget at price", GBL._restock.skipped[1])
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            fireStepTimers()
            assert.equals("no price within 5s", GBL._restock.skipped[2])
            GBL:StartRestockBuyNext()
            assert.equals("max price", GBL._restock.skipped[3])
            assert.equals(2, #MockWoW.commodityPurchases.start)

            GBL:SetRestockBudget(10000)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals("no price within 5s", GBL._restock.skipped[2])
            assert.equals("max price", GBL._restock.skipped[3])
        end)

        it("leaves skips alone when the budget is set to what it already was", function()
            twoOverBudget()
            GBL:StartRestockBuyNext()
            GBL:SetRestockBudget(10)
            assert.equals("budget on this buy", GBL._restock.skipped[1])
            assert.equals("budget on this buy", GBL._restock.skipped[2])
        end)

        it("survives a budget change with no search open", function()
            GBL._restock = nil
            assert.is_true((GBL:SetRestockBudget(5)))
            GBL._restock = { state = "IDLE" }
            assert.is_true((GBL:SetRestockBudget(6)))
        end)
    end)

    describe("pure buy helpers", function()
        it("_RestockSpent is gone: the wallet delta is not the spend (#60)", function()
            assert.is_nil(GBL._RestockSpent)
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

        it("_RestockBuyableCount counts what _RestockNextBuyable would accept", function()
            local st = {
                activeItems = {
                    { itemID = 1, needed = 0 },  -- needs nothing
                    { itemID = 2, needed = 5 },  -- bought
                    { itemID = 3, needed = 5 },  -- skipped
                    { itemID = 4, needed = 5 },  -- no result
                    { itemID = 5, needed = 5 },  -- eligible
                    { itemID = 6, needed = 1 },  -- eligible
                },
                resultRows = { [1] = { minPrice = 1 }, [2] = { minPrice = 1 }, [3] = { minPrice = 1 },
                               [5] = { minPrice = 1 }, [6] = { minPrice = 1 } },
                bought = { [2] = true },
                skipped = { [3] = true },
            }
            assert.equals(2, GBL:_RestockBuyableCount(st))
            st.bought[5], st.bought[6] = true, true
            assert.equals(0, GBL:_RestockBuyableCount(st))
            assert.is_nil(GBL:_RestockNextBuyable(st))
            assert.equals(0, GBL:_RestockBuyableCount(nil))
        end)
    end)

    describe("auction-house event log (#199)", function()
        it("logs the start of a purchase with the item, the quantity, how it was started and the throttle flags", function()
            oneItem()
            GBL:StartRestockBuy(1)
            local line = findLine("Restock AH: start state=")
            assert.is_not_nil(line)
            assert.truthy(line:find("it:100 x5", 1, true))
            assert.truthy(line:find(" via=row", 1, true))
            assert.truthy(line:find("state=CONFIRMING", 1, true))
            assert.truthy(line:find(" busy=yes ready=true ", 1, true))
            assert.equals(1, count("Restock AH: start state="))

            GBL:ResetRestockSearch()
            oneItem()
            GBL:StartRestockBuyNext()
            assert.is_not_nil(findLine(" via=next"))
            assert.is_nil(findLine("sweep="))
        end)

        it("logs a price update with its unit and total price, and the throttle still busy", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            local line = findLine("Restock AH: COMMODITY_PRICE_UPDATED ")
            assert.is_not_nil(line)
            assert.truthy(line:find("unit=" .. GBL:FormatMoney(4200), 1, true))
            assert.truthy(line:find("total=" .. GBL:FormatMoney(21000), 1, true))
            assert.truthy(line:find(" busy=yes ", 1, true))
            assert.truthy(line:find("price in, confirm waits for ready", 1, true))
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
        end)

        it("says whether the ready issued the confirm", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals(0, count("confirm issued"))
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
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)

            local before = #ahLines()
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(before + 1, #ahLines())
            local ignored = findLine("ignored (state=READY)")
            assert.is_not_nil(ignored)
            -- The prefix carries the state every line is read by, so pin it
            -- once on a line outside CONFIRMING (a hardcoded prefix survived).
            assert.equals(1, ignored:find("Restock AH: COMMODITY_PURCHASE_SUCCEEDED state=READY ", 1, true))
            assert.is_true(GBL._restock.bought[1])
            assert.equals(1, #MockWoW.commodityPurchases.confirm)

            before = #ahLines()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
            MockAce.fireEvent("UI_ERROR_MESSAGE", 123, "You are too far away")
            assert.equals(before, #ahLines())
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("logs the throttle events by name while a purchase is in flight", function()
            oneItem()
            GBL:StartRestockBuy(1)
            local names = {
                "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
                "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
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

        it("logs the step transition and the next purchase of the list", function()
            twoItems()
            GBL:StartRestockBuyNext()
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            local handled = findLine("handled")
            assert.is_not_nil(handled)
            assert.truthy(handled:find("it:100 x5", 1, true))
            local step = findLine("Restock AH: step done ")
            assert.is_not_nil(step)
            assert.truthy(step:find("next=2 awaiting click", 1, true))
            assert.is_nil(findLine("deferred"))
            assert.equals(1, count("Restock AH: start state="))
            assert.equals("READY", GBL._restock.state)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, count("Restock AH: start state="))
            GBL:StartRestockBuyNext()
            assert.equals(2, count("Restock AH: start state="))
            assert.is_not_nil(findLine("pending=it:200 x2"))
            assert.equals("CONFIRMING", GBL._restock.state)

            priceThenReady(900, 1800)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_not_nil(findLine("list done"))
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
                { walletBase = 10000000 })
            GBL:StartRestockBuyNext()
            local skip = findLine("Restock AH: skip ")
            assert.is_not_nil(skip)
            assert.truthy(skip:find("it:100", 1, true))
            assert.truthy(skip:find("budget", 1, true))
            assert.is_truthy(GBL._restock.skipped[1])
            assert.is_not_nil(findLine("pending=it:200 x2"))
            assert.equals("CONFIRMING", GBL._restock.state)
        end)
    end)

    -- A purchase outlives the search that made it (#209): the mail is not
    -- the bank, so what was bought is remembered per guild until the ledger
    -- sees the buyer deposit it.
    describe("remembers a purchase past the search (#209)", function()
        local function pending(itemID)
            return GBL:GetRestockData().pending[itemID]
        end

        it("records a confirmed purchase with the buyer and the server time", function()
            MockWoW.serverTime = 3600 * 475200
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            assert.is_nil(pending(100))  -- nothing until the result
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            local e = pending(100)
            assert.equals(5, e.qty)
            assert.equals(GBL:ResolvePlayerName(MockWoW.player.name), e.buyer)
            assert.equals(3600 * 475200, e.at)
            assert.is_nil(e.unconfirmed)
        end)

        it("records nothing on a failed purchase", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")
            assert.is_nil(pending(100))
        end)

        it("records a late success and nothing on a late failure", function()
            twoItems()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            fireStepTimers()
            assert.is_not_nil(GBL._restock.unanswered)
            assert.is_nil(pending(100))
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")     -- the late result
            assert.equals(5, pending(100).qty)
            assert.is_nil(pending(100).unconfirmed)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:StartRestockBuy(2)
            priceThenReady(900, 1800)
            fireStepTimers()
            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")        -- the late answer: nothing bought
            assert.is_nil(pending(200))
        end)

        it("parks an unanswered confirm as unconfirmed when the search is reset", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            fireStepTimers()
            assert.is_not_nil(GBL._restock.unanswered)
            GBL:ResetRestockSearch()
            assert.is_nil(GBL._restock.unanswered)
            local e = pending(100)
            assert.equals(5, e.qty)
            assert.is_true(e.unconfirmed)
            assert.equals(1, count("Restock AH: reset "))
        end)

        it("parks a confirmed purchase Cancel abandons, and nothing when the cancel went out", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            GBL:ResetRestockSearch()                                -- the events are gone with it
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.is_true(pending(100).unconfirmed)
            assert.equals(5, pending(100).qty)

            oneItem()
            GBL:StartRestockBuy(1)                                  -- no price yet, no confirm out
            GBL:ResetRestockSearch()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals(5, pending(100).qty)                      -- unchanged: nothing was spent
        end)

        it("does not offer a bought row to the next search from the same scan", function()
            MockWoW.money = 1000000
            local opts = {
                layout = { version = 1, updatedAt = 0, tabs = {
                    [1] = { mode = "display", name = "A", items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                } },
                reserves = {},
                scanResults = {},
            }
            assert.equals(1, #GBL:_RestockBuildBuyList(opts))
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            GBL:ResetRestockSearch()                                -- Done, then Search again
            assert.equals(0, #GBL:_RestockBuildBuyList(opts))
            assert.equals(5, pending(100).qty)                      -- the entry survives the reset
        end)
    end)
    ------------------------------------------------------------------------
    -- Confirm at price (#211, section 8): with the pause on, the price event
    -- enters PRICED and waits for a click; Confirm issues the confirm through
    -- the one throttle seam, Cancel drops the purchase, and the step timer is
    -- re-armed for the pause so nothing waits forever.
    ------------------------------------------------------------------------
    describe("confirm at price (#211)", function()
        before_each(function()
            GBL:SetRestockConfirmAtPrice(true)
        end)

        local function pending(itemID)
            return GBL:GetRestockData().pending[itemID]
        end

        it("defaults on, and the setting round-trips", function()
            GBL.db.profile.restock = nil
            GBL = Helpers.loadAddon()
            GBL:OnInitialize()
            assert.is_true(GBL:IsRestockConfirmAtPrice())
            GBL:SetRestockConfirmAtPrice(false)
            assert.is_false(GBL:IsRestockConfirmAtPrice())
            GBL:SetRestockConfirmAtPrice(true)
            assert.is_true(GBL:IsRestockConfirmAtPrice())
        end)

        it("enters PRICED on the price and issues no confirm until the click", function()
            oneItem()
            GBL:StartRestockBuy(1)
            assert.equals(1, liveStepTimers())
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals("PRICED", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(21000, GBL._restock.pendingTotal)
            assert.is_true(GBL._restock.priceIn)
            assert.equals(0, liveStepTimers())
            assert.equals(1, livePauseTimers())  -- the one timer slot, re-armed for the pause
            assert.equals(1, count("price in, awaiting confirm"))
            -- The READY that follows the price clears the throttle and confirms nothing.
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals("PRICED", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.is_false(GBL._restock.throttleBusy)
        end)

        it("confirms on the click when the throttle is free, then succeeds as before", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(100, MockWoW.commodityPurchases.confirm[1].itemID)
            assert.equals(5, MockWoW.commodityPurchases.confirm[1].quantity)
            assert.equals(0, livePauseTimers())
            assert.equals(1, liveStepTimers())
            assert.equals(1, count("confirm click"))
            assert.equals(1, count("confirm issued"))
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.is_true(GBL._restock.bought[1])
            assert.equals(21000, GBL._restock.spentEstimate)
            assert.equals(5, pending(100).qty)
        end)

        it("waits for the ready when the click lands inside the busy window, with a timer behind it", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)  -- READY not yet come
            assert.is_true(GBL._restock.throttleBusy)
            GBL:ConfirmRestockPurchase()
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, count("confirm waits for ready"))
            assert.equals(1, liveStepTimers())
            assert.equals(0, livePauseTimers())
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("gives up a confirm whose ready never comes", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            GBL:ConfirmRestockPurchase()
            fireStepTimers()
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals("READY", GBL._restock.state)
            assert.is_not_nil(findLine("throttle never freed"))
            assert.is_nil(GBL._restock.bought[1])
            assert.is_nil(GBL._restock.skipped[1])
        end)

        it("Cancel in PRICED drops the purchase and keeps the list", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            GBL:CancelRestockPurchase()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals("READY", GBL._restock.state)
            assert.equals(2, #GBL._restock.activeItems)
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_nil(GBL._restock.bought[1])
            assert.is_false(GBL._restock.buyAll)
            assert.equals(0, livePauseTimers())
            assert.equals(0, liveStepTimers())
            assert.is_not_nil(findLine("Restock AH: cancelled "))
            assert.is_nil(pending(100))
            -- The row is still buyable: the next click quotes it again.
            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(100, MockWoW.commodityPurchases.start[2].itemID)
        end)

        it("Cancel in CONFIRMING cancels before the confirm is out, and parks the purchase after", function()
            oneItem()
            GBL:StartRestockBuy(1)
            GBL:CancelRestockPurchase()                             -- no price yet
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #GBL._restock.activeItems)
            assert.is_nil(pending(100))

            -- Confirm out: nothing to cancel, and the result is still coming,
            -- so the purchase is kept as unanswered (the timeout's record):
            -- no new start until it lands, and the late result credits it.
            twoItems()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            GBL:CancelRestockPurchase()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)   -- unchanged
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(pending(100))                             -- not parked: the result is still due
            assert.equals(100, GBL._restock.unanswered.itemID)
            assert.equals(5, GBL._restock.unanswered.qty)
            assert.is_not_nil(findLine("confirm already issued, kept as unanswered"))
            assert.equals(0, liveStepTimers())
            GBL:StartRestockBuy(2)                                  -- refused while it is outstanding
            assert.equals(2, #MockWoW.commodityPurchases.start)    -- the two starts above, none here
            assert.is_true(Helpers.printContains("Waiting on the result"))
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")       -- the late result credits it
            assert.is_nil(GBL._restock.unanswered)
            assert.equals(5, pending(100).qty)
            assert.is_nil(pending(100).unconfirmed)
            assert.is_true(GBL._restock.bought[1])
            GBL:StartRestockBuy(2)
            assert.equals(3, #MockWoW.commodityPurchases.start)
        end)

        it("ends the pause on a second price or a price-unavailable, without a cancel", function()
            -- The events carry no item, so a price arriving while our quote
            -- waits is either a re-quote or another addon's start; either
            -- way the quote on the banner is no longer ours to confirm. No
            -- cancel goes out, since it would cancel whatever the server holds.
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 5000, 25000)
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("quote superseded, pause ended"))
            assert.is_true(Helpers.printContains("click Buy again"))
            assert.equals(0, livePauseTimers())
            assert.equals(2, GBL:_RestockBuyableCount(GBL._restock))

            GBL:ClearLog("system")
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("COMMODITY_PRICE_UNAVAILABLE")
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals(1, count("quote superseded, pause ended"))
        end)

        it("ignores the price of a start that Cancel dropped before it arrived", function()
            twoItems()
            GBL:StartRestockBuyNext()                               -- row 1 starts
            GBL:CancelRestockPurchase()                             -- before its price
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            GBL:StartRestockBuy(2)                                  -- row 2 starts in the same window
            assert.equals("CONFIRMING", GBL._restock.state)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)  -- row 1's price lands first
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.is_false(GBL._restock.priceIn)
            assert.equals(1, count("ignored (price of a cancelled start)"))
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")  -- the cancelled start's cycle ends
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 900, 1800)    -- row 2's own price
            assert.equals("PRICED", GBL._restock.state)
            assert.equals(1800, GBL._restock.pendingTotal)

            -- A cancelled start whose price never comes: the READY clears the
            -- expectation, so the next start's price is taken as its own.
            GBL:CancelRestockPurchase()
            twoItems()
            GBL:StartRestockBuy(1)
            GBL:CancelRestockPurchase()
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:StartRestockBuy(2)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 900, 1800)
            assert.equals("PRICED", GBL._restock.state)
        end)

        it("drops a quote or an unpriced start when the auction house closes, and leaves a confirm out alone", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals("PRICED", GBL._restock.state)
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_CLOSED")
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals(0, livePauseTimers())
            assert.equals(1, count("cancelled (auction house window closed)"))

            _G.AuctionHouseFrame = { IsShown = function() return true end }
            GBL:StartRestockBuy(1)                                  -- CONFIRMING, no price yet
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_CLOSED")
            assert.equals("READY", GBL._restock.state)
            assert.equals(2, #MockWoW.commodityPurchases.cancel)

            _G.AuctionHouseFrame = { IsShown = function() return true end }
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_CLOSED")       -- the result may still come
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(2, #MockWoW.commodityPurchases.cancel)
            assert.equals(1, liveStepTimers())
        end)

        it("gives up a quote nobody confirmed and leaves the row buyable", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            firePauseTimers()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_nil(GBL._restock.bought[1])
            assert.is_not_nil(findLine("quote expired"))
            assert.is_true(Helpers.printContains("expired"))
            assert.equals(1, count("Restock AH: step done "))
            assert.equals(2, GBL:_RestockBuyableCount(GBL._restock))
            assert.equals(0, livePauseTimers())
            assert.equals(0, liveStepTimers())
        end)

        it("reads a result with no confirm out as someone else's purchase and ends the pause", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(GBL._restock.bought[1])
            assert.is_nil(pending(100))
            assert.equals(0, GBL._restock.spentEstimate)
            assert.equals(0, livePauseTimers())
            assert.equals(1, count("foreign"))
            assert.is_true(Helpers.printContains("different purchase"))

            GBL:ClearLog("system")
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("COMMODITY_PURCHASE_FAILED")
            assert.equals("READY", GBL._restock.state)
            assert.is_nil(GBL._restock.bought[1])
            assert.equals(1, count("foreign"))
            assert.equals(0, livePauseTimers())
        end)

        it("logs the throttle family while a quote waits", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT")
            assert.equals(1, count("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT state=PRICED"))
        end)

        it("never starts a purchase from a PRICED event or the pause timer", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals("PRICED", GBL._restock.state)
            local everything = {
                { "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" },
                { "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED" },
                { "UI_ERROR_MESSAGE", 1, "x" },
                { "COMMODITY_PRICE_UPDATED", 4300, 21500 },
                { "COMMODITY_PRICE_UNAVAILABLE" },
            }
            for _, ev in ipairs(everything) do
                MockAce.fireEvent(unpack(ev))
                assert.equals(1, #MockWoW.commodityPurchases.start, ev[1])
            end
            -- The second price ended the pause (quote superseded); a fresh quote for the pause timer.
            assert.equals("READY", GBL._restock.state)
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 900, 1800)
            firePauseTimers()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
        end)

        it("cancels a PRICED purchase on reset", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            GBL:ResetRestockSearch()
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals("IDLE", GBL._restock.state)
            assert.equals(0, livePauseTimers())
            assert.is_nil(pending(100))
        end)

        it("with the pause off the confirm still goes out on the ready after the price", function()
            GBL:SetRestockConfirmAtPrice(false)
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
            assert.equals(0, livePauseTimers())
        end)

        it("Confirm and Cancel do nothing outside a purchase", function()
            -- The buttons only render in PRICED and CONFIRMING, but a click
            -- handler outlives the rebuild it was made in; neither call may
            -- confirm or cancel a purchase that is not there.
            twoItems()
            GBL:ConfirmRestockPurchase()
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(0, liveStepTimers())
            GBL:CancelRestockPurchase()
            assert.equals("READY", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.cancel)
            assert.equals(2, #GBL._restock.activeItems)

            GBL:StartRestockBuyNext()  -- CONFIRMING, before the price
            GBL:ConfirmRestockPurchase()
            assert.equals("CONFIRMING", GBL._restock.state)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
        end)
    end)

    ------------------------------------------------------------------------
    -- The auction-house gate (#211): a start needs the house open, and the
    -- only guard before this was the existence of the API.
    ------------------------------------------------------------------------
    describe("auction house gate (#211)", function()
        it("refuses a start with the auction house closed, marking nothing", function()
            _G.AuctionHouseFrame = { IsShown = function() return false end }
            twoItems()
            GBL:StartRestockBuyNext()
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.is_false(GBL._restock.buyAll)
            assert.equals(1, count("auction house not open"))
            assert.is_nil(GBL._restock.skipped[1])
            assert.is_nil(GBL._restock.skipped[2])
            assert.is_true(Helpers.printContains("Open the Auction House"))
            assert.is_false(GBL:_RestockAuctionHouseOpen())

            _G.AuctionHouseFrame = nil  -- no frame at all reads as closed too
            GBL:StartRestockBuy(1)
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.is_false(GBL:_RestockAuctionHouseOpen())
        end)

        it("starts once the house is open", function()
            twoItems()
            assert.is_true(GBL:_RestockAuctionHouseOpen())
            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
        end)

        it("reads the auction-house events as well as the frame", function()
            -- The events are the direct signal; the frame is a proxy an addon
            -- can hide while the session stays open. Either says open.
            _G.AuctionHouseFrame = nil
            assert.is_false(GBL:_RestockAuctionHouseOpen())
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            assert.is_true(GBL:_RestockAuctionHouseOpen())
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_CLOSED")
            assert.is_false(GBL:_RestockAuctionHouseOpen())
            _G.AuctionHouseFrame = { IsShown = function() return true end }
            assert.is_true(GBL:_RestockAuctionHouseOpen())
        end)
    end)

    ------------------------------------------------------------------------
    -- The shipped default is the pause, so the walks the rest of this file
    -- pins with it off are pinned with it on here too (#211 review).
    ------------------------------------------------------------------------
    describe("Buy next with the pause on (#211)", function()
        before_each(function()
            GBL:SetRestockConfirmAtPrice(true)
        end)

        local function pending(itemID)
            return GBL:GetRestockData().pending[itemID]
        end

        it("walks two rows with a Confirm click each and settles between them", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals("PRICED", GBL._restock.state)
            assert.is_true(GBL._restock.buyAll)
            GBL:ConfirmRestockPurchase()
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.is_true(GBL._restock.bought[1])
            assert.equals(1, count("next=2 awaiting click"))
            assert.equals(1, #MockWoW.commodityPurchases.start)

            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
            assert.equals(200, MockWoW.commodityPurchases.start[2].itemID)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 900, 1800)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_true(GBL._restock.bought[2])
            assert.equals(21000 + 1800, GBL._restock.spentEstimate)
            assert.equals(5, pending(100).qty)
            assert.equals(2, pending(200).qty)
            assert.equals(1, count("list done"))
        end)

        it("reaches the budget through a confirmed quote and refuses the next click", function()
            GBL:SetRestockBudget(100)
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 200000, 1000000)  -- exactly 100g
            assert.equals("PRICED", GBL._restock.state)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("budget reached"))
            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(1, printCount("Budget of 100 g reached"))
        end)

        it("keeps the walk's skip bookkeeping across an expired quote", function()
            MockWoW.money = 100000  -- 10g
            readyState(
                { { itemID = 100, needed = 5 },   -- 25g: unaffordable, skipped
                  { itemID = 200, needed = 1 },   -- 1g: quoted, left to expire
                  { itemID = 300, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 50000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 10000 },
                  [3] = { itemKey = { itemID = 300 }, minPrice = 10000 } },
                { walletBase = 100000 })
            GBL:StartRestockBuyNext()
            assert.is_truthy(GBL._restock.skipped[1])
            assert.equals(200, MockWoW.commodityPurchases.start[1].itemID)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 10000, 10000)
            firePauseTimers()
            assert.equals("READY", GBL._restock.state)
            assert.is_truthy(GBL._restock.skipped[1])   -- still skipped
            assert.is_nil(GBL._restock.skipped[2])      -- the expired row is not
            assert.equals(2, GBL:_RestockBuyableCount(GBL._restock))
            GBL:StartRestockBuyNext()                   -- row 2 again, not row 3
            assert.equals(200, MockWoW.commodityPurchases.start[2].itemID)
        end)

        it("credits a late result that lands during the next row's pause to the unanswered record", function()
            twoItems()
            GBL:StartRestockBuyNext()
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            GBL:ConfirmRestockPurchase()
            fireStepTimers()                            -- no result: kept as unanswered, run stops
            assert.is_not_nil(GBL._restock.unanswered)
            assert.equals("READY", GBL._restock.state)
            GBL:StartRestockBuyNext()                   -- refused while it is outstanding
            assert.equals(1, #MockWoW.commodityPurchases.start)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.is_nil(GBL._restock.unanswered)
            assert.equals(5, pending(100).qty)
            GBL:StartRestockBuyNext()
            assert.equals(2, #MockWoW.commodityPurchases.start)
        end)
    end)

    ------------------------------------------------------------------------
    -- Spend and affordability (#60): Spent and the budget read what this
    -- search spent, and the wallet baseline moves only on tab show with
    -- nothing in flight, as a pair with the spend at that moment.
    ------------------------------------------------------------------------
    describe("spend and affordability (#60)", function()
        it("re-baselines on tab show with nothing in flight, without counting a purchase twice", function()
            -- The review's example: search at 10,000g, buy 3,000g, reopen the tab,
            -- and a 5,000g row must still be affordable with 7,000g in the wallet.
            MockWoW.money = 100000000  -- 10,000g
            readyState(
                { { itemID = 100, needed = 1 }, { itemID = 200, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 30000000 },   -- 3,000g
                  [2] = { itemKey = { itemID = 200 }, minPrice = 50000000 } },  -- 5,000g
                { walletBase = 100000000 })
            GBL:StartRestockBuy(1)
            priceThenReady(30000000, 30000000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            MockWoW.money = 70000000   -- the wallet caught up
            GBL:_RestockOnTabShown()
            assert.equals(70000000, GBL._restock.walletBase)
            assert.equals(30000000, GBL._restock.spentAtBase)
            assert.equals(30000000, GBL._restock.spentEstimate)  -- Spent is untouched
            GBL:StartRestockBuy(2)
            assert.equals(2, #MockWoW.commodityPurchases.start)  -- 5,000g affordable
        end)

        it("does not re-baseline while a purchase is in flight", function()
            oneItem()
            GBL:StartRestockBuy(1)
            MockWoW.money = 5000000  -- the wallet moved; the baseline must not
            GBL:_RestockOnTabShown()
            assert.equals(1000000, GBL._restock.walletBase)
            GBL:SetRestockConfirmAtPrice(true)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 21000)
            assert.equals("PRICED", GBL._restock.state)
            GBL:_RestockOnTabShown()
            assert.equals(1000000, GBL._restock.walletBase)
        end)

        it("still bounds a wallet that reads high right after a purchase", function()
            MockWoW.money = 100000  -- 10g, never decremented
            readyState(
                { { itemID = 100, needed = 1 }, { itemID = 200, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 60000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 60000 } },
                { walletBase = 100000 })
            GBL:StartRestockBuy(1)
            priceThenReady(60000, 60000)
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            GBL:StartRestockBuy(2)
            assert.equals(1, #MockWoW.commodityPurchases.start)  -- 4g left lag-free, 6g needed
            assert.is_true(Helpers.printContains("Not enough gold"))
        end)

        it("ignores gold spent elsewhere for the budget and counts the priced total", function()
            GBL:SetRestockBudget(5)
            MockWoW.money = 10000000
            readyState(
                { { itemID = 100, needed = 1 }, { itemID = 200, needed = 1 } },
                { [1] = { itemKey = { itemID = 100 }, minPrice = 10000 },
                  [2] = { itemKey = { itemID = 200 }, minPrice = 10000 } },
                { walletBase = 10000000 })
            MockWoW.money = 1000000  -- 900g gone elsewhere; not this search's spend
            GBL:StartRestockBuy(1)
            assert.equals(1, #MockWoW.commodityPurchases.start)
            priceThenReady(45000, 45000)  -- 4.5g quoted
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals(45000, GBL._restock.spentEstimate)
            GBL:StartRestockBuy(2)         -- 4.5g + 1g > 5g
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.is_true(Helpers.printContains("exceed your budget"))
        end)
    end)
    ------------------------------------------------------------------------
    -- The code review of PR B (#214): one buyable predicate the tab and Buy
    -- next share, Confirm re-checking the quote, the buy events dropped
    -- when the house closes with nothing in flight, the budget set.
    ------------------------------------------------------------------------
    describe("review of the flow (#214)", function()
        it("counts a row buyable only with a usable price on a commodity, and never while a result is outstanding", function()
            twoItems()
            assert.equals(2, GBL:_RestockBuyableCount(GBL._restock))
            GBL._restock.resultRows[1].isCommodity = false
            assert.equals(1, GBL:_RestockBuyableCount(GBL._restock))
            assert.is_false(GBL:_RestockRowBuyable(GBL._restock, 1))
            GBL._restock.resultRows[2].minPrice = 0
            assert.equals(0, GBL:_RestockBuyableCount(GBL._restock))
            GBL._restock.resultRows[1].isCommodity = nil
            GBL._restock.resultRows[2].minPrice = 900
            GBL._restock.unanswered = { index = 1, itemID = 100, qty = 5 }
            assert.equals(0, GBL:_RestockBuyableCount(GBL._restock))
            assert.is_nil(GBL:_RestockNextBuyable(GBL._restock))
        end)

        it("refuses to start a non-commodity pre-start, with the reason in the log and no skip mark", function()
            twoItems()
            GBL._restock.resultRows[1].isCommodity = false
            GBL:StartRestockBuy(1)
            assert.equals(0, #MockWoW.commodityPurchases.start)
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("it:100 not a commodity"))
            GBL:StartRestockBuyNext()
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(200, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("Confirm re-checks the quote against the budget and the wallet as they are now", function()
            GBL.db.profile.restock.confirmAtPrice = true
            oneItem()
            GBL:SetRestockBudget(10)
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 90000)   -- 9g, inside the budget
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals("PRICED", GBL._restock.state)
            GBL:SetRestockBudget(5)                                      -- lowered during the pause
            GBL:ConfirmRestockPurchase()
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("refused (budget at price)"))
            assert.equals(1, count("step failed"))

            GBL:SetRestockBudget(0)
            GBL:StartRestockBuy(1)
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 4200, 90000)
            MockAce.fireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
            assert.equals("PRICED", GBL._restock.state)
            MockWoW.money = 1000                                          -- the wallet emptied elsewhere
            GBL:ConfirmRestockPurchase()
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
            assert.equals(2, #MockWoW.commodityPurchases.cancel)
            assert.equals("READY", GBL._restock.state)
            assert.equals(1, count("refused (cannot afford at price)"))
            assert.equals(2, count("step failed"))
        end)

        it("drops the buy events when the house closes with nothing in flight, and keeps them with a confirm out", function()
            oneItem()
            GBL:StartRestockBuy(1)
            priceThenReady(4200, 21000)                                   -- the confirm is out
            GBL:_RestockOnAuctionHouseClosed()
            assert.is_true(GBL._restock.buyEventsRegistered)
            assert.is_not_nil(MockAce.registeredEvents["COMMODITY_PURCHASE_SUCCEEDED"])
            MockAce.fireEvent("COMMODITY_PURCHASE_SUCCEEDED")
            assert.equals("READY", GBL._restock.state)
            GBL:_RestockOnAuctionHouseClosed()
            assert.is_false(GBL._restock.buyEventsRegistered)
            assert.is_nil(MockAce.registeredEvents["COMMODITY_PURCHASE_SUCCEEDED"])
            assert.equals(1, #GBL._restock.activeItems)                   -- the list stays
            -- The next start registers them again.
            GBL._restock.bought = {}
            GBL._restock.boughtTotal = {}
            GBL:StartRestockBuy(1)
            assert.is_true(GBL._restock.buyEventsRegistered)
        end)

        it("clears the budget skips by membership in the reason set, not by prefix", function()
            twoItems()
            GBL._restock.skipped = { [1] = GBL._restockSkipReasons.BUDGET_AT_PRICE, [2] = "budgetary" }
            GBL:SetRestockBudget(50)
            assert.is_nil(GBL._restock.skipped[1])
            assert.equals("budgetary", GBL._restock.skipped[2])
        end)
    end)
end)
