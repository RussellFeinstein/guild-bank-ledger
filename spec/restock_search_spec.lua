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

        it("stamps whether each result is a commodity from the item key, when the client can say (#214)", function()
            _G.C_AuctionHouse = _G.C_AuctionHouse or {}
            local asked = {}
            _G.C_AuctionHouse.GetItemKeyInfo = function(key)
                asked[#asked + 1] = key.itemID
                return { isCommodity = (key.itemID ~= 200) }
            end
            local rows = GBL:_RestockMapResults(
                { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
                { { itemKey = { itemID = 100 }, minPrice = 4200 }, { itemKey = { itemID = 200 }, minPrice = 900 } })
            _G.C_AuctionHouse.GetItemKeyInfo = nil
            assert.is_true(rows[1].isCommodity)
            assert.is_false(rows[2].isCommodity)
            assert.same({ 100, 200 }, asked)

            -- Without the API the row is left as the search sent it.
            rows = GBL:_RestockMapResults({ { itemID = 100, needed = 5 } },
                { { itemKey = { itemID = 100 }, minPrice = 4200 } })
            assert.is_nil(rows[1].isCommodity)
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
            assert.is_nil(next(GBL._restock.boughtTotal))
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
    ------------------------------------------------------------------------
    -- Preconditions as disabled states (#211, section 4): one pure reader,
    -- _RestockSearchBlocker, names the first failing precondition in the
    -- table's order, and StartRestockSearch prints its text and returns.
    ------------------------------------------------------------------------
    describe("_RestockSearchBlocker (#211)", function()
        local searchable = {
            layout = layout({
                [1] = { mode = "display", name = "A", items = { [100] = { slots = 1, perSlot = 5 } } },
                [2] = { mode = "overflow" },
            }),
            reserves = {},
            scanResults = {},  -- a scan that saw nothing: item 100 is short 5
        }

        local function stubAuctionator()
            _G.Auctionator = {
                API = { v1 = { ConvertToSearchString = function() return "x" end } },
                EventBus = {},
                Shopping = { Tab = { Events = { SearchEnd = "SearchEnd" } } },
            }
        end

        before_each(function()
            stubAuctionator()
            _G.AuctionHouseFrame = { IsShown = function() return true end }
            _G.AuctionatorShoppingFrame = { IsVisible = function() return true end }
        end)

        after_each(function()
            _G.Auctionator = nil
            _G.AuctionHouseFrame = nil
            _G.AuctionatorShoppingFrame = nil
        end)

        it("is nil when every precondition holds, and hands back the buy list it built", function()
            local blocker, buyList = GBL:_RestockSearchBlocker(searchable)
            assert.is_nil(blocker)
            assert.equals(1, #buyList)
            assert.equals(100, buyList[1].itemID)
            assert.equals(5, buyList[1].needed)
        end)

        it("names each precondition alone, with the text the banner shows", function()
            _G.Auctionator = nil
            local b = GBL:_RestockSearchBlocker(searchable)
            assert.equals("auctionator", b.key)
            assert.truthy(b.text:find("needs the Auctionator addon", 1, true))
            stubAuctionator()

            _G.AuctionHouseFrame = nil
            b = GBL:_RestockSearchBlocker(searchable)
            assert.equals("ah-closed", b.key)
            assert.equals("Open the Auction House to search.", b.text)
            _G.AuctionHouseFrame = { IsShown = function() return false end }
            assert.equals("ah-closed", GBL:_RestockSearchBlocker(searchable).key)
            _G.AuctionHouseFrame = { IsShown = function() return true end }

            _G.AuctionatorShoppingFrame = { IsVisible = function() return false end }
            b = GBL:_RestockSearchBlocker(searchable)
            assert.equals("shopping-tab", b.key)
            assert.equals("Open the Auctionator Shopping tab first, then search.", b.text)
            _G.AuctionatorShoppingFrame = { IsVisible = function() return true end }

            b = GBL:_RestockSearchBlocker({ layout = searchable.layout, reserves = {} })  -- no scan
            assert.equals("no-scan", b.key)
            assert.truthy(b.text:find("Waiting on the bank scan", 1, true))

            b = GBL:_RestockSearchBlocker({
                layout = searchable.layout, reserves = {},
                scanResults = scan({ [1] = { [1] = { itemID = 100, count = 5 } } }),  -- at target
            })
            assert.equals("nothing", b.key)
            assert.equals("Nothing to buy: the bank and the mail cover every layout item.", b.text)
        end)

        it("reports the first failing precondition in the table's order", function()
            _G.AuctionHouseFrame = nil                                                   -- 2 fails
            _G.AuctionatorShoppingFrame = { IsVisible = function() return false end }   -- 3 fails
            assert.equals("ah-closed", GBL:_RestockSearchBlocker({ layout = searchable.layout, reserves = {} }).key)
            _G.AuctionHouseFrame = { IsShown = function() return true end }
            assert.equals("shopping-tab", GBL:_RestockSearchBlocker({ layout = searchable.layout, reserves = {} }).key)
        end)

        it("StartRestockSearch prints the blocker's text and stays IDLE", function()
            _G.AuctionHouseFrame = nil
            GBL._restock = { state = "IDLE" }
            GBL:StartRestockSearch()
            assert.equals("IDLE", GBL._restock.state)
            assert.is_true(Helpers.printContains("Open the Auction House to search."))
        end)
    end)
    ------------------------------------------------------------------------
    -- Search from READY (#214, section 3): a new search tears the old run
    -- down first (the reset's teardown, shared), so bought, skipped and the
    -- buy events go, an unanswered confirm is parked as unconfirmed before
    -- the events it would have been credited on are dropped, and the pending
    -- store is left alone. CONFIRMING and PRICED refuse.
    ------------------------------------------------------------------------
    describe("Search from READY (#214)", function()
        local MockAce = Helpers.MockAce

        before_each(function()
            _G.Auctionator = {
                API = { v1 = { ConvertToSearchString = function() return "x" end } },
                EventBus = { RegisterSource = function() end, Register = function() end,
                             Unregister = function() end },
                Shopping = { Tab = { Events = { SearchEnd = "SearchEnd" } } },
            }
            _G.AuctionHouseFrame = { IsShown = function() return true end }
            _G.AuctionatorShoppingFrame = { IsVisible = function() return true end,
                                            DoSearch = function() end, StopSearch = function() end }
            assert.is_true(GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "A",
                            items = { [100] = { slots = 1, perSlot = 5 }, [200] = { slots = 1, perSlot = 2 } } },
                    [2] = { mode = "overflow" },
                },
            }))
            GBL.lastScanResults = {}   -- a scan that saw nothing: both items short
            GBL._restock = {
                state = "READY", searchGen = 3,
                activeItems = { { itemID = 100, needed = 5 }, { itemID = 200, needed = 2 } },
                resultRows = { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                bought = { [1] = true }, boughtTotal = { [1] = 21000 }, skipped = { [2] = "max price" },
                walletBase = 1000000, spentAtBase = 0, spentEstimate = 21000,
            }
            GBL:_RestockRegisterBuyEvents()
            -- Names resolve at once (the mock Item has no CreateFromItemID).
            _G.Item.CreateFromItemID = function(_self, id)
                return { ContinueOnItemLoad = function(_i, cb) cb() end,
                         GetItemName = function() return "Item " .. id end }
            end
        end)

        after_each(function()
            _G.Auctionator = nil
            _G.AuctionHouseFrame = nil
            _G.AuctionatorShoppingFrame = nil
            _G.Item.CreateFromItemID = nil
        end)

        it("tears the run down and starts: progress cleared, the buy events dropped, a new generation", function()
            GBL:StartRestockSearch()
            local st = GBL._restock
            assert.equals("SEARCHING", st.state)
            assert.is_true(st.searchGen > 3)   -- the old run's callbacks are dead
            assert.equals(2, #st.activeItems)
            assert.is_nil(next(st.bought))
            assert.is_nil(next(st.boughtTotal))
            assert.is_nil(next(st.skipped))
            assert.is_false(st.buyEventsRegistered)
            assert.is_nil(MockAce.registeredEvents["COMMODITY_PRICE_UPDATED"])
        end)

        it("parks an unanswered confirm as unconfirmed before the events drop, and keeps the store", function()
            GBL:GetRestockData().pending[200] = { qty = 1, buyer = "Someone", at = 1 }
            GBL._restock.unanswered = { index = 1, itemID = 100, qty = 5, total = 21000 }
            GBL:StartRestockSearch()
            assert.is_nil(GBL._restock.unanswered)
            local entry = GBL:GetRestockData().pending[100]
            assert.is_not_nil(entry)
            assert.equals(5, entry.qty)
            assert.is_true(entry.unconfirmed)
            assert.is_not_nil(GBL:GetRestockData().pending[200])
        end)

        it("parks before it builds the new list, so a parked quantity is not offered again", function()
            GBL._restock.unanswered = { index = 1, itemID = 100, qty = 5, total = 21000 }
            GBL:StartRestockSearch()
            assert.equals("SEARCHING", GBL._restock.state)
            -- Item 100's whole target is now in the mail as unconfirmed, so
            -- the new list holds only item 200.
            assert.equals(1, #GBL._restock.activeItems)
            assert.equals(200, GBL._restock.activeItems[1].itemID)
            local words = 0
            for _, e in ipairs(GBL:GetLog("system")) do
                if e.message:find("Restock AH: new search", 1, true) then words = words + 1 end
                assert.is_nil(e.message:find("Restock AH: reset", 1, true), "a Search is not a reset")
            end
            assert.equals(1, words)
        end)

        it("goes IDLE with the reason when the park leaves nothing to buy", function()
            assert.is_true(GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "A", items = { [100] = { slots = 1, perSlot = 5 } } },
                    [2] = { mode = "overflow" },
                },
            }))
            GBL._restock.activeItems = { { itemID = 100, needed = 5 } }
            GBL._restock.unanswered = { index = 1, itemID = 100, qty = 5, total = 21000 }
            GBL:StartRestockSearch()
            assert.equals("IDLE", GBL._restock.state)
            assert.is_true(Helpers.printContains("Nothing to buy"))
            assert.is_true(GBL:GetRestockData().pending[100].unconfirmed)
        end)

        it("refuses from CONFIRMING and PRICED", function()
            for _, state in ipairs({ "CONFIRMING", "PRICED" }) do
                GBL._restock.state = state
                GBL._restock.searchGen = 3
                GBL:StartRestockSearch()
                assert.equals(state, GBL._restock.state)
                assert.equals(3, GBL._restock.searchGen)
            end
        end)
    end)
end)
