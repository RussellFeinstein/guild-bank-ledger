------------------------------------------------------------------------
-- restockview_spec.lua — Tests for UI/RestockView.lua
--
-- Covers the pure status-display helper and the render scaffold. The render
-- path runs in the mock (per the changelog_spec precedent); these tests assert
-- structure (ScrollFrame + grouped rows), the focus-order registration, the
-- Auctionator-absent notice, and the empty-state message.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

-- Recursive widget search by AceGUI type.
local function findChild(container, widgetType)
    for _, c in ipairs(container._children or {}) do
        if c._type == widgetType then return c end
        local nested = findChild(c, widgetType)
        if nested then return nested end
    end
    return nil
end

-- Recursive: first Heading whose text matches.
local function findHeading(container, text)
    for _, c in ipairs(container._children or {}) do
        if c._type == "Heading" and c._text == text then return c end
        local nested = findHeading(c, text)
        if nested then return nested end
    end
    return nil
end

-- Recursive: first Label whose text contains substr.
local function findLabelContaining(container, substr)
    for _, c in ipairs(container._children or {}) do
        if c._type == "Label" and c._text and c._text:find(substr, 1, true) then
            return c
        end
        local nested = findLabelContaining(c, substr)
        if nested then return nested end
    end
    return nil
end

-- Recursive: first Button whose text starts with prefix. The Search
-- button carries the blocking precondition in its own label (#217), so a
-- test that only cares which control it is matches the prefix.
local function findButtonStarting(container, prefix)
    for _, c in ipairs(container._children or {}) do
        if c._type == "Button" and c._text and c._text:sub(1, #prefix) == prefix then return c end
        local nested = findButtonStarting(c, prefix)
        if nested then return nested end
    end
    return nil
end

-- Recursive: first Button whose text matches.
local function findButton(container, text)
    for _, c in ipairs(container._children or {}) do
        if c._type == "Button" and c._text == text then return c end
        local nested = findButton(c, text)
        if nested then return nested end
    end
    return nil
end

describe("RestockView", function()
    local GBL

    -- One builder and one two-item READY fixture for every describe below.
    -- readyTwo saves the layout its two items come from: the view renders
    -- from the universe, so a fixture without a layout would exercise the
    -- orphan path ("Searched, no longer in the layout") and read as a test
    -- of something else.
    local function build()
        local AceGUI = LibStub("AceGUI-3.0")
        local container = AceGUI:Create("SimpleGroup")
        GBL:BuildRestockTab(container)
        return container
    end

    local function findCheckBox(container, label)
        for _, c in ipairs(container._children or {}) do
            if c._type == "CheckBox" and c._label == label then return c end
            local nested = findCheckBox(c, label)
            if nested then return nested end
        end
        return nil
    end

    local function layoutTwo()
        local ok = GBL:SaveBankLayout({
            tabs = {
                [1] = { mode = "display", name = "Mats",
                        items = { [111] = { slots = 1, perSlot = 5 }, [222] = { slots = 1, perSlot = 3 } } },
                [2] = { mode = "overflow" },
            },
        })
        assert.is_true(ok)
    end

    local function readyTwo()
        layoutTwo()
        GBL.lastScanResults = GBL.lastScanResults or {}
        GBL._restock = {
            state = "READY",
            activeItems = { { itemID = 111, needed = 5 }, { itemID = 222, needed = 3 } },
            resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 },
                           [2] = { itemKey = { itemID = 222 }, minPrice = 1000 } },
            bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
        }
        MockWoW.money = 1000000
    end

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: passes HasLayoutWrite for SetStockReserve
        GBL:OnEnable()
        -- The auction house is open unless a case closes it (#211): every buy
        -- control disables without the frame, and the mock has none.
        _G.AuctionHouseFrame = { IsShown = function() return true end }
    end)

    after_each(function()
        _G.AuctionHouseFrame = nil
    end)

    describe("GetRestockStatusDisplay", function()
        it("distinguishes short / in stock by colour, icon and text", function()
            local short = GBL:GetRestockStatusDisplay({ target = 60, stock = 20, toBuy = 40, scanned = true })
            local atMax = GBL:GetRestockStatusDisplay({ target = 60, stock = 60, toBuy = 0, scanned = true })
            local overMax = GBL:GetRestockStatusDisplay({ target = 60, stock = 80, toBuy = 0, scanned = true })

            assert.equals("short", short.status)
            assert.equals("instock", atMax.status)

            assert.equals("short", short.text)
            assert.equals("in stock", atMax.text)

            -- At or above the max is one state: over the max reads identically
            -- to exactly at it (no separate "over" callout).
            assert.equals(atMax.status, overMax.status)
            assert.equals(atMax.text, overMax.text)

            -- Triple-encoded: the two states differ on all three channels (icon,
            -- color, text), so status is never conveyed by color alone.
            assert.is_true(short.icon ~= atMax.icon)
            assert.is_true(short.color ~= atMax.color)
            assert.is_true(short.text ~= atMax.text)
        end)

        it("treats a nil or empty row as in stock", function()
            assert.equals("instock", GBL:GetRestockStatusDisplay(nil).status)
            assert.equals("instock", GBL:GetRestockStatusDisplay({}).status)
        end)
    end)

    ------------------------------------------------------------------------
    -- The row vocabulary (#214, section 5): one table of statuses, each
    -- triple-encoded, read through one pure classifier with a fixed
    -- precedence, and the skip reasons rendered from the code's own list.
    ------------------------------------------------------------------------
    describe("row vocabulary (#214)", function()
        local function session(fields)
            local s = {
                state = "READY",
                activeItems = { { itemID = 100, needed = 5 } },
                resultRows = { [1] = { itemKey = { itemID = 100 }, minPrice = 4200 } },
                bought = {}, boughtTotal = {}, skipped = {},
            }
            for k, v in pairs(fields or {}) do s[k] = v end
            return s
        end
        local function row(fields)
            local r = { itemID = 100, target = 20, stock = 15, toBuy = 5, pending = 0, scanned = true }
            for k, v in pairs(fields or {}) do r[k] = v end
            return r
        end

        it("gives every status text, an icon and a palette colour, with no two texts alike", function()
            local _, palette = next(GBL.A11Y.PALETTES)
            local seen, n = {}, 0
            for status, entry in pairs(GBL._restockStatusText) do
                n = n + 1
                assert.is_string(entry.text, status)
                assert.is_true(#entry.text > 0, status)
                assert.is_string(entry.icon, status)
                assert.is_table(palette[entry.color], status .. " names no palette role")
                assert.is_nil(seen[entry.text], "two statuses share '" .. entry.text .. "'")
                seen[entry.text] = status
            end
            assert.equals(12, n)
        end)

        it("reads bank unknown before a scan, with no shortfall on the row", function()
            local d = GBL:GetRestockStatusDisplay(row({ scanned = false, stock = 0, toBuy = 20 }), nil)
            assert.equals("unknown", d.status)
            assert.equals("bank unknown", d.text)
        end)

        it("reads in the mail when the pending covers the shortfall, in stock when the bank does", function()
            local mail = GBL:GetRestockStatusDisplay(row({ stock = 0, pending = 20, toBuy = 0 }), nil)
            assert.equals("inmail", mail.status)
            assert.equals("in the mail", mail.text)
            local bank = GBL:GetRestockStatusDisplay(row({ stock = 25, pending = 20, toBuy = 0 }), nil)
            assert.equals("instock", bank.status)
        end)

        it("decorates a searched row from the session: priced, not a commodity, not found", function()
            local priced = GBL:GetRestockStatusDisplay(row(), session())
            assert.equals("priced", priced.status)
            assert.equals(1, priced.index)
            assert.equals(4200, priced.minPrice)
            assert.equals(5, priced.needed)
            local other = GBL:GetRestockStatusDisplay(row(),
                session({ resultRows = { [1] = { itemKey = { itemID = 100 }, minPrice = 4200, isCommodity = false } } }))
            assert.equals("notcommodity", other.status)
            local missing = GBL:GetRestockStatusDisplay(row(), session({ resultRows = {} }))
            assert.equals("notfound", missing.status)
            -- A result with no usable price is not found either: Auctionator's
            -- placeholder for a miss carries minPrice 0, which Lua reads as true.
            local zero = GBL:GetRestockStatusDisplay(row(),
                session({ resultRows = { [1] = { itemKey = { itemID = 100 }, minPrice = 0 } } }))
            assert.equals("notfound", zero.status)
            -- A row the search never covered keeps the universe reading.
            assert.equals("short", GBL:GetRestockStatusDisplay(row({ itemID = 200 }), session()).status)
            -- So does every searched row while the search is out: the results
            -- are not in, and "not found" would be a lie for the duration.
            assert.equals("short", GBL:GetRestockStatusDisplay(row(),
                session({ state = "SEARCHING", resultRows = {} })).status)
        end)

        it("reads bought with its total, and skipped with the reason's prose", function()
            local bought = GBL:GetRestockStatusDisplay(row(),
                session({ bought = { [1] = true }, boughtTotal = { [1] = 21000 } }))
            assert.equals("bought", bought.status)
            assert.equals("bought 5 for " .. GBL:FormatMoney(21000), bought.text)
            local skipped = GBL:GetRestockStatusDisplay(row(), session({ skipped = { [1] = "budget at price" } }))
            assert.equals("skipped", skipped.status)
            assert.equals("skipped: " .. GBL:RestockSkipText("budget at price"), skipped.text)
        end)

        it("marks the row in flight as buying or quoted ahead of every other reading", function()
            local buying = GBL:GetRestockStatusDisplay(row({ stock = 0, pending = 20, toBuy = 0 }),
                session({ state = "CONFIRMING", pendingIndex = 1 }))
            assert.equals("buying", buying.status)
            local quoted = GBL:GetRestockStatusDisplay(row(),
                session({ state = "PRICED", pendingIndex = 1, pendingTotal = 52250 }))
            assert.equals("quoted", quoted.status)
            assert.equals("quoted " .. GBL:FormatMoney(52250) .. ", confirm?", quoted.text)
            -- Session over search over universe: a bought row that is also
            -- priced and covered by the mail reads bought.
            local d = GBL:GetRestockStatusDisplay(row({ stock = 0, pending = 5, toBuy = 0 }),
                session({ bought = { [1] = true }, boughtTotal = { [1] = 100 } }))
            assert.equals("bought", d.status)
        end)

        it("renders every skip reason the code writes, and an unknown code as itself", function()
            local reasons = GBL._restockSkipReasons
            assert.is_table(reasons)
            local n, seen = 0, {}
            for _, code in pairs(reasons) do
                n = n + 1
                local text = GBL:RestockSkipText(code)
                assert.is_string(text, code)
                assert.is_true(text ~= code, "no prose for '" .. code .. "'")
                seen[text] = (seen[text] or 0) + 1
            end
            assert.equals(8, n)
            -- The two budget reasons share the budget hint, the two afford
            -- reasons share theirs, and the three price reasons share theirs.
            assert.equals(2, seen[GBL:RestockSkipText(reasons.BUDGET_THIS_BUY)])
            assert.truthy(GBL:RestockSkipText(reasons.BUDGET_THIS_BUY):find("budget", 1, true))
            assert.equals(2, seen[GBL:RestockSkipText(reasons.CANNOT_AFFORD)])
            assert.equals(3, seen[GBL:RestockSkipText(reasons.NO_PRICE_AVAILABLE)])
            assert.equals("mystery", GBL:RestockSkipText("mystery"))
        end)
    end)

    describe("BuildRestockTab", function()
        local function build()
            local AceGUI = LibStub("AceGUI-3.0")
            local container = AceGUI:Create("SimpleGroup")
            GBL:BuildRestockTab(container)
            return container
        end

        -- Configure a valid layout (one display tab + the required overflow) so
        -- the item list has something to render.
        local function configureLayout()
            local ok = GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "Consumables",
                            items = { [55555] = { slots = 2, perSlot = 10 } } },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_true(ok)
            GBL.lastScanResults = {}   -- a scan that saw nothing: the rows read a shortfall, not bank ?
        end

        it("renders the layout items grouped by tab name", function()
            configureLayout()
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            assert.is_not_nil(findLabelContaining(scroll, "target 20"))
            -- triple-encoded status is wired into the row (text + icon channels)
            assert.is_not_nil(findLabelContaining(scroll, "short 20"))
            assert.is_not_nil(findLabelContaining(scroll, "|T"))
        end)

        it("draws the bank tab's current name, not the one the layout stored", function()
            -- #236: Russell's guild renamed tab 1 after the layout captured it,
            -- and this list kept calling it by the old name while the Layout tab
            -- on the same screen showed the new one.
            configureLayout()
            MockWoW.addTab("Raid Use 1")
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Raid Use 1"))
            assert.is_nil(findHeading(scroll, "Consumables"))
        end)

        it("renders a heading per display tab", function()
            local ok = GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "Consumables",
                            items = { [55555] = { slots = 1, perSlot = 10 } } },
                    [2] = { mode = "display", name = "Gems",
                            items = { [66666] = { slots = 1, perSlot = 10 } } },
                    [3] = { mode = "overflow" },
                },
            })
            assert.is_true(ok)
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            assert.is_not_nil(findHeading(scroll, "Gems"))
        end)

        it("renders the item list under the banner in SEARCHING, with Cancel", function()
            configureLayout()
            GBL._restock = { state = "SEARCHING", activeItems = { { itemID = 55555, needed = 20 } } }
            local container = build()
            local banner = findChild(container, "Label")
            assert.truthy(banner._text:find("Searching the Auction House", 1, true))
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            local row = findLabelContaining(scroll, "target 20")
            assert.is_not_nil(row)
            assert.truthy(row._text:find("short 20", 1, true))
            assert.is_nil(findLabelContaining(scroll, "not found"))
            assert.is_not_nil(findButton(container, "Cancel"))
            assert.is_nil(findButtonStarting(container, "Search auctions"))
        end)

        it("decorates the list in READY with each searched row's price and Buy, formatting price with FormatMoney", function()
            local ok = GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "Consumables",
                            items = { [55555] = { slots = 1, perSlot = 5 }, [66666] = { slots = 1, perSlot = 3 } } },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_true(ok)
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 55555, needed = 5 }, { itemID = 66666, needed = 3 } },
                resultRows = { [1] = { itemKey = { itemID = 55555 }, minPrice = 4200 } },  -- 66666 missing
                foundCount = 1, bought = {}, skipped = {},
                walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            local priced = findLabelContaining(scroll, "lowest " .. GBL:FormatMoney(4200))
            assert.is_not_nil(priced)
            assert.truthy(priced._text:find("target 5", 1, true))
            assert.truthy(priced._text:find("priced", 1, true))
            assert.is_not_nil(findButton(scroll, "Buy 5 (~" .. GBL:_RestockEstimateText(21000) .. ")"))
            assert.is_not_nil(findLabelContaining(scroll, "not found"))
            assert.is_nil(findButton(scroll, "Buy 3 (~" .. GBL:_RestockEstimateText(0) .. ")"))
            -- the result labels must keep explicit SetFont flags (12.0.7 guard)
            local function walk(w)
                for _, c in ipairs(w._children or {}) do
                    if c._type == "Label" and c._setFont then
                        assert.is_not_nil(c._setFont[3], "result Label SetFont flags must not be nil")
                    end
                    walk(c)
                end
            end
            walk(container)
        end)

        it("keeps the list in CONFIRMING, marks the row in flight, disables the other Buys, and offers Cancel", function()
            local ok = GBL:SaveBankLayout({
                tabs = {
                    [1] = { mode = "display", name = "Consumables",
                            items = { [55555] = { slots = 1, perSlot = 5 }, [66666] = { slots = 1, perSlot = 3 } } },
                    [2] = { mode = "overflow" },
                },
            })
            assert.is_true(ok)
            GBL._restock = {
                state = "CONFIRMING",
                activeItems = { { itemID = 55555, needed = 5 }, { itemID = 66666, needed = 3 } },
                resultRows = { [1] = { itemKey = { itemID = 55555 }, minPrice = 4200 },
                               [2] = { itemKey = { itemID = 66666 }, minPrice = 1000 } },
                bought = {}, skipped = {}, pendingIndex = 1, pendingItemID = 55555, pendingQty = 5,
                walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local container = build()
            local banner = findChild(container, "Label")
            assert.truthy(banner._text:find("Confirming purchase", 1, true))
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            assert.is_not_nil(findLabelContaining(scroll, "buying"))
            local other = findButton(scroll, "Buy 3 (~" .. GBL:_RestockEstimateText(3000) .. ")")
            assert.is_not_nil(other)
            assert.is_true(other.disabled)
            assert.is_not_nil(findButton(container, "Cancel"))
            assert.is_nil(findButton(container, "Done"))
        end)

        it("renders a searched row that left the layout under its own heading rather than dropping it", function()
            configureLayout()   -- 55555 only; 77777 was searched and then removed from the layout
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 77777, needed = 2 } },
                resultRows = { [1] = { itemKey = { itemID = 77777 }, minPrice = 500 } },
                bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local scroll = findChild(build(), "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            assert.is_not_nil(findHeading(scroll, "Searched, no longer in the layout"))
            assert.is_not_nil(findButton(scroll, "Buy 2 (~" .. GBL:_RestockEstimateText(1000) .. ")"))
        end)

        it("renders Buy next with the buyable count and disables it at zero (#199)", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 }, { itemID = 222, needed = 3 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 },
                               [2] = { itemKey = { itemID = 222 }, minPrice = 1000 } },
                bought = { [1] = true }, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local container = build()
            assert.is_nil(findButton(container, "Buy all"))
            local btn = findButton(container, "Buy next (1 left)")
            assert.is_not_nil(btn)
            assert.is_falsy(btn.disabled)
            btn:Fire("OnClick")
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(222, MockWoW.commodityPurchases.start[1].itemID)

            GBL._restock.state = "READY"
            GBL._restock.bought[2] = true
            container = build()
            btn = findButton(container, "Buy next (0 left)")
            assert.is_not_nil(btn)
            assert.is_true(btn.disabled)
        end)

        it("wires each per-row Buy button to that row's item", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 }, { itemID = 222, needed = 3 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 },
                               [2] = { itemKey = { itemID = 222 }, minPrice = 1000 } },
                bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local container = build()
            local btn = findButton(container, "Buy 3 (~" .. GBL:_RestockEstimateText(3000) .. ")")  -- item 222 (needs 3)
            assert.is_not_nil(btn)
            btn:Fire("OnClick")
            assert.equals(1, #MockWoW.commodityPurchases.start)
            assert.equals(222, MockWoW.commodityPurchases.start[1].itemID)
        end)

        it("stores the entered value from the budget EditBox", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 } },
                bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000
            local container = build()
            local box = findChild(container, "EditBox")
            assert.is_not_nil(box)
            box:Fire("OnEnterPressed", "250")
            assert.equals(250, GBL:GetRestockBudget())
        end)

        it("shows the spent-of-budget line when a budget is set", function()
            GBL:SetRestockBudget(100)
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 } },
                bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000  -- spent 0
            local container = build()
            local banner = findLabelContaining(container, "Gold:")
            assert.truthy(banner._text:find("Spent", 1, true))
            assert.truthy(banner._text:find("Gold", 1, true))  -- current wallet shown
        end)

        it("shows what the search has spent even without a budget, and nothing before anything was spent (#199)", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 } },
                bought = {}, skipped = {}, walletBase = 1000000, spentAtBase = 0, spentEstimate = 0,
            }
            MockWoW.money = 1000000  -- spent 0, no budget
            local banner = findLabelContaining(build(), "Gold:")
            assert.is_nil(banner._text:find("Spent", 1, true))

            GBL._restock.spentEstimate = 100000  -- spent 10g, no budget
            banner = findLabelContaining(build(), "Gold:")
            assert.truthy(banner._text:find("Spent " .. GBL:FormatMoney(100000) .. ".", 1, true))
            assert.is_nil(banner._text:find(GBL:FormatMoney(100000) .. " of ", 1, true))  -- "1 of 1 found" is the count

            GBL:SetRestockBudget(100)
            banner = findLabelContaining(build(), "Gold:")
            assert.truthy(banner._text:find("Spent " .. GBL:FormatMoney(100000) .. " of 100 g.", 1, true))
        end)

        it("shows the empty-state pointing at the Layout tab when no layout is set", function()
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
            assert.is_not_nil(findLabelContaining(scroll, "Layout tab"))
        end)

        it("registers interactive widgets in the focus order", function()
            build()
            assert.is_true(#GBL.A11Y.focusOrder > 0)
        end)

        -- Pending purchases (#209): the row says what is in the mail, the
        -- shortfall is reduced by it, and a Clear button sits in the focus
        -- order for the case the ledger cannot settle.
        describe("a row with a purchase in the mail (#209)", function()
            local buyer

            before_each(function()
                configureLayout()
                buyer = GBL:ResolvePlayerName(MockWoW.player.name)
                MockWoW.serverTime = 3600 * 475200
            end)

            it("renders the modifier with its age, the reduced shortfall, and a Clear button", function()
                GBL:GetRestockData().pending[55555] = { qty = 8, buyer = buyer, at = 3600 * 475200 - 7200 }
                local container = build()
                local scroll = findChild(container, "ScrollFrame")
                local row = findLabelContaining(scroll, "in the mail 8 (2h ago)")
                assert.is_not_nil(row)
                assert.truthy(row._text:find("target 20", 1, true))
                assert.truthy(row._text:find("short 12", 1, true))
                local clear = findButton(scroll, "Clear")
                assert.is_not_nil(clear)
                local inOrder = false
                for _, w in ipairs(GBL.A11Y.focusOrder) do
                    if w == clear then inOrder = true end
                end
                assert.is_true(inOrder)
            end)

            it("says the result is unknown for an unconfirmed entry", function()
                GBL:GetRestockData().pending[55555] =
                    { qty = 3, buyer = buyer, at = 3600 * 475200 - 90, unconfirmed = true }
                local container = build()
                local scroll = findChild(container, "ScrollFrame")
                assert.is_not_nil(findLabelContaining(scroll,
                    "3 bought, result unknown (1m ago), check your mail"))
                assert.is_nil(findLabelContaining(scroll, "in the mail"))
            end)

            -- #215: one summed figure under the unconfirmed wording said both
            -- parts were in doubt ("11 bought, result unknown"). Each part is
            -- named with its own age now, since the entry keeps the earliest
            -- purchase time and the unconfirmed part keeps its own.
            it("names the two parts apart, each with its own age", function()
                GBL:_RestockAddPending(55555, 8)
                MockWoW.serverTime = 3600 * 475200 + 7200
                GBL:_RestockAddPending(55555, 3, { unconfirmed = true })
                local container = build()
                local scroll = findChild(container, "ScrollFrame")
                local row = findLabelContaining(scroll, "in the mail 8 (2h ago)")
                assert.is_not_nil(row)
                assert.truthy(row._text:find("3 bought, result unknown (0s ago), check your mail", 1, true))
                assert.is_nil(row._text:find("11 bought", 1, true))
            end)

            -- The entry had no row at all, so the only control that can clear
            -- it was unreachable and it re-applied when the item came back.
            it("renders an entry for an item the layout does not name", function()
                GBL:GetRestockData().pending[99999] = { qty = 4, buyer = buyer, at = 3600 * 475200 }
                local container = build()
                local scroll = findChild(container, "ScrollFrame")
                assert.is_not_nil(findLabelContaining(scroll, "in the mail 4"))
                assert.is_not_nil(findButton(scroll, "Clear"))
            end)

            it("removes the entry and rebuilds without the modifier when Clear is pressed", function()
                GBL:GetRestockData().pending[55555] = { qty = 20, buyer = buyer, at = 3600 * 475200 }
                GBL.activeTab = "restock"
                GBL.tabGroup = LibStub("AceGUI-3.0"):Create("TabGroup")
                GBL:BuildRestockTab(GBL.tabGroup)
                local before = findChild(GBL.tabGroup, "ScrollFrame")
                assert.is_not_nil(findLabelContaining(before, "in the mail"))
                findButton(before, "Clear"):Fire("OnClick")
                assert.is_nil(GBL:GetRestockData().pending[55555])
                local after = findChild(GBL.tabGroup, "ScrollFrame")
                assert.is_nil(findLabelContaining(after, "in the mail"))
                assert.is_nil(findButton(after, "Clear"))
                assert.is_not_nil(findLabelContaining(after, "short 20"))
            end)

            it("registers no button on a row with nothing in the mail", function()
                build()
                local n = #GBL.A11Y.focusOrder
                GBL:GetRestockData().pending[55555] = { qty = 1, buyer = buyer, at = 3600 * 475200 }
                build()
                assert.equals(n + 1, #GBL.A11Y.focusOrder)
            end)
        end)

        it("shows an Auctionator-required notice when Auctionator is absent", function()
            local container = build()
            local banner = findChild(container, "Label")
            assert.is_not_nil(banner)
            assert.truthy(banner._text:find("Auctionator", 1, true))
        end)

        it("passes explicit font flags to every label (WoW 12.0 rejects a nil arg #3 to SetFont)", function()
            configureLayout()
            local container = build()
            local checked = 0
            local function walk(w)
                for _, c in ipairs(w._children or {}) do
                    if c._type == "Label" and c._setFont then
                        assert.is_not_nil(c._setFont[3], "Label SetFont flags must not be nil")
                        checked = checked + 1
                    end
                    walk(c)
                end
            end
            walk(container)
            assert.is_true(checked > 0)
        end)

        it("exposes the view functions (rename guard)", function()
            assert.is_function(GBL.BuildRestockTab)
            assert.is_function(GBL.RefreshRestockTab)
            assert.is_function(GBL.GetRestockStatusDisplay)
        end)

        it("OnBankLayoutChanged refreshes the Restock tab", function()
            -- The list is layout-driven, so a layout/reserve change must refresh it.
            local called = false
            local orig = GBL.RefreshRestockTab
            GBL.RefreshRestockTab = function() called = true end
            GBL:OnBankLayoutChanged()
            GBL.RefreshRestockTab = orig
            assert.is_true(called)
        end)
    end)

    describe("keyboard navigation", function()
        local b1, b2

        before_each(function()
            local AceGUI = LibStub("AceGUI-3.0")
            b1 = AceGUI:Create("Button")
            b2 = AceGUI:Create("Button")
            GBL:ClearFocusOrder()
            GBL:RegisterFocusable(b1, 1)
            GBL:RegisterFocusable(b2, 2)
            GBL.A11Y.focusIndex = 0
        end)

        it("TAB advances focus and wraps", function()
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(2, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("TAB", false)  -- wraps to first
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("Shift-TAB reverses and wraps", function()
            GBL.A11Y.focusIndex = 1
            GBL:_RestockView_NavKey("TAB", true)  -- wraps backward to last
            assert.equals(2, GBL.A11Y.focusIndex)
        end)

        it("DOWN and UP move focus once a widget has it", function()
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("DOWN", false)
            assert.equals(2, GBL.A11Y.focusIndex)
            GBL:_RestockView_NavKey("UP", false)
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("ENTER activates the focused widget's OnClick", function()
            local clicked = false
            b1:SetCallback("OnClick", function() clicked = true end)
            GBL.A11Y.focusIndex = 1
            local handled = GBL:_RestockView_NavKey("ENTER", false)
            assert.is_true(handled)
            assert.is_true(clicked)
        end)

        it("ENTER with no focus returns false", function()
            GBL.A11Y.focusIndex = 0
            assert.is_false(GBL:_RestockView_NavKey("ENTER", false))
        end)

        it("ENTER does not fire a disabled widget", function()
            -- This tab disables Buy buttons once a budget cap is reached,
            -- and firing OnClick directly skips the check AceGUI's own
            -- click handler does. The purchase path re-checks the budget,
            -- so this is defence in depth, but a disabled button that
            -- answers a key still lies about what it will do.
            local clicked = false
            b1:SetCallback("OnClick", function() clicked = true end)
            b1:SetDisabled(true)
            GBL.A11Y.focusIndex = 1

            local handled = GBL:_RestockView_NavKey("ENTER", false)

            assert.is_false(clicked, "a disabled button must not run its callback")
            assert.is_false(handled,
                "an unhandled key should propagate rather than read as consumed")
        end)

        it("returns false for an unhandled key", function()
            assert.is_false(GBL:_RestockView_NavKey("X", false))
        end)

        -- The rule (#214, section 12): with nothing focused only Tab enters
        -- the walk, so an arrow pressed to turn the character cannot land on
        -- Scan bank; Escape clears focus and consumes only itself, so the next
        -- Escape closes the window as before.
        it("consumes nothing but TAB while nothing is focused (#214)", function()
            for _, key in ipairs({ "UP", "DOWN", "ENTER", "NUMPADENTER", "SPACE" }) do
                assert.is_false(GBL:_RestockView_NavKey(key, false), key)
                assert.equals(0, GBL.A11Y.focusIndex, key)
            end
            assert.is_true(GBL:_RestockView_NavKey("TAB", false))
            assert.equals(1, GBL.A11Y.focusIndex)
            assert.is_true(GBL:_RestockView_NavKey("DOWN", false))
            assert.equals(2, GBL.A11Y.focusIndex)
        end)

        it("ESCAPE clears focus when a widget has it, and propagates when none does (#214)", function()
            assert.is_false(GBL:_RestockView_NavKey("ESCAPE", false))
            GBL:_RestockView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            assert.is_true(GBL:_RestockView_NavKey("ESCAPE", false))
            assert.equals(0, GBL.A11Y.focusIndex)
            assert.is_false(b1._focused)
            assert.is_false(GBL:_RestockView_NavKey("ESCAPE", false))
        end)
    end)

    describe("OpenRestockTab", function()
        it("opens to the Restock tab for a sort-access user", function()
            GBL:OpenRestockTab()  -- GM (rankIndex 0) has sort access
            -- activeTab, not the group's _selectedTab: that field records
            -- the value handed in even when the bar holds no such tab and
            -- nothing was built (#121), so it cannot carry this claim.
            assert.equals("restock", GBL.activeTab)
            assert.is_true(GBL:IsMainFrameShown())
        end)

        it("declines and prints for a user without sort access", function()
            MockWoW.guild.rankIndex = 5  -- not GM; no sortAccess grant
            GBL:OpenRestockTab()
            assert.is_true(Helpers.printContains("sort access"))
            assert.is_nil(GBL.tabGroup)
        end)
    end)
    ------------------------------------------------------------------------
    -- The flow's states on the tab (#211): Search disabled with its reason,
    -- the confirm-at-price toggle, the PRICED controls with Confirm first in
    -- the focus order, and the auction-house gate on every buy control.
    ------------------------------------------------------------------------
    describe("flow states (#211)", function()
        before_each(function()
            _G.Auctionator = {
                API = { v1 = { ConvertToSearchString = function() return "x" end } },
                EventBus = {},
                Shopping = { Tab = { Events = { SearchEnd = "SearchEnd" } } },
            }
            _G.AuctionHouseFrame = { IsShown = function() return true end }
            _G.AuctionatorShoppingFrame = { IsVisible = function() return true end }
        end)

        after_each(function()
            _G.Auctionator = nil
            _G.AuctionHouseFrame = nil
            _G.AuctionatorShoppingFrame = nil
        end)

        it("disables Search in IDLE with the blocker's text on the banner", function()
            _G.AuctionHouseFrame = nil
            local container = build()
            local banner = findChild(container, "Label")
            assert.truthy(banner._text:find("Open the Auction House to search.", 1, true))
            local btn = findButton(container, "Search auctions (open the Auction House)")
            assert.is_not_nil(btn)
            assert.is_true(btn.disabled)
        end)

        it("renders the confirm-at-price toggle from the setting and writes it back", function()
            readyTwo()
            GBL:SetRestockConfirmAtPrice(true)
            local cb = findCheckBox(build(), "Confirm at price")
            assert.is_not_nil(cb)
            assert.is_true(cb:GetValue())
            cb:SetValue(false)
            cb:Fire("OnValueChanged", false)
            assert.is_false(GBL:IsRestockConfirmAtPrice())
            cb = findCheckBox(build(), "Confirm at price")
            assert.is_false(cb:GetValue())
        end)

        it("Space on the focused toggle flips it (the CheckBox branch of the activator)", function()
            readyTwo()
            GBL:SetRestockConfirmAtPrice(true)
            build()
            local idx
            for i, w in ipairs(GBL.A11Y.focusOrder) do
                if w._type == "CheckBox" then idx = i end
            end
            assert.is_not_nil(idx)
            GBL.A11Y.focusIndex = idx
            assert.is_true(GBL:_RestockView_NavKey("SPACE", false))
            assert.is_false(GBL:IsRestockConfirmAtPrice())
        end)

        it("renders the quote, Confirm and Cancel in PRICED, with Confirm focused", function()
            readyTwo()
            GBL._restock.state = "PRICED"
            GBL._restock.pendingIndex = 1
            GBL._restock.pendingItemID = 111
            GBL._restock.pendingQty = 5
            GBL._restock.pendingTotal = 52250
            GBL._restock.focusConfirm = true   -- set by the price event that entered PRICED
            local container = build()
            local banner = findChild(container, "Label")
            assert.truthy(banner._text:find("Quoted " .. GBL:FormatMoney(52250), 1, true))
            assert.truthy(banner._text:find("5 x", 1, true))
            assert.truthy(banner._text:find("Confirm?", 1, true))
            local confirm = findButton(container, "Confirm")
            assert.is_not_nil(confirm)
            assert.is_not_nil(findButton(container, "Cancel"))
            assert.is_nil(findButton(container, "Buy next (2 left)"))
            assert.equals(confirm, GBL.A11Y.focusOrder[GBL.A11Y.focusIndex])
            assert.is_nil(GBL._restock.focusConfirm)  -- consumed by that one build

            -- Enter confirms: the activator reaches the focused Confirm.
            assert.is_true(GBL:_RestockView_NavKey("ENTER", false))
            assert.equals(1, #MockWoW.commodityPurchases.confirm)
        end)

        it("focuses Confirm only on the rebuild that enters PRICED, never on a later one", function()
            -- A rebuild from a sync or a scan between the player's Tab to
            -- Cancel and their Enter must not snap focus back onto Confirm.
            readyTwo()
            GBL:SetRestockConfirmAtPrice(true)
            GBL:StartRestockBuy(1)
            local MockAce = Helpers.MockAce
            MockAce.fireEvent("COMMODITY_PRICE_UPDATED", 1000, 5000)
            assert.equals("PRICED", GBL._restock.state)
            local container = build()
            local confirm = findButton(container, "Confirm")
            assert.equals(confirm, GBL.A11Y.focusOrder[GBL.A11Y.focusIndex])
            GBL:_RestockView_NavKey("TAB", false)      -- onto Cancel
            local cancel = findButton(container, "Cancel")
            assert.equals(cancel, GBL.A11Y.focusOrder[GBL.A11Y.focusIndex])
            container = build()                        -- an unrelated rebuild
            assert.is_nil(GBL.A11Y.focusOrder[GBL.A11Y.focusIndex])  -- the walk starts over, nothing focused
            assert.equals(0, GBL.A11Y.focusIndex)
            assert.equals(0, #MockWoW.commodityPurchases.confirm)
        end)

        it("wires Cancel in CONFIRMING and PRICED to the purchase cancel, not the reset", function()
            readyTwo()
            GBL._restock.state = "CONFIRMING"
            GBL._restock.pendingIndex = 1
            GBL._restock.pendingItemID = 111
            GBL._restock.pendingQty = 5
            findButton(build(), "Cancel"):Fire("OnClick")
            assert.equals("READY", GBL._restock.state)
            assert.equals(2, #GBL._restock.activeItems)
            assert.equals(1, #MockWoW.commodityPurchases.cancel)

            GBL._restock.state = "PRICED"
            GBL._restock.pendingIndex = 2
            GBL._restock.pendingItemID = 222
            GBL._restock.pendingQty = 3
            GBL._restock.pendingTotal = 3000
            findButton(build(), "Cancel"):Fire("OnClick")
            assert.equals("READY", GBL._restock.state)
            assert.equals(2, #GBL._restock.activeItems)
            assert.equals(2, #MockWoW.commodityPurchases.cancel)
        end)

        it("disables Buy next and every Buy with the auction house closed, and says so", function()
            readyTwo()
            _G.AuctionHouseFrame = { IsShown = function() return false end }
            local container = build()
            assert.is_true(findButton(container, "Buy next (2 left)").disabled)
            assert.is_true(findButton(container, "Buy 5 (~" .. GBL:_RestockEstimateText(5000) .. ")").disabled)
            assert.is_true(findButton(container, "Buy 3 (~" .. GBL:_RestockEstimateText(3000) .. ")").disabled)
            assert.truthy(findChild(container, "Label")._text:find("Open the Auction House to search or buy.", 1, true))

            _G.AuctionHouseFrame = { IsShown = function() return true end }
            container = build()
            assert.is_falsy(findButton(container, "Buy next (2 left)").disabled)
            assert.is_falsy(findButton(container, "Buy 5 (~" .. GBL:_RestockEstimateText(5000) .. ")").disabled)
        end)

        it("disables Confirm with the auction house closed", function()
            readyTwo()
            GBL._restock.state = "PRICED"
            GBL._restock.pendingIndex = 1
            GBL._restock.pendingItemID = 111
            GBL._restock.pendingQty = 5
            GBL._restock.pendingTotal = 52250
            _G.AuctionHouseFrame = { IsShown = function() return false end }
            local container = build()
            assert.is_true(findButton(container, "Confirm").disabled)
            assert.is_falsy(findButton(container, "Cancel").disabled)
        end)

        it("shows Spent from what the search spent, not from the wallet (#60)", function()
            readyTwo()
            MockWoW.money = 900000  -- 10g left the wallet elsewhere
            local banner = findLabelContaining(build(), "Gold:")
            assert.is_nil(banner._text:find("Spent", 1, true))
            GBL._restock.spentEstimate = 100000
            banner = findLabelContaining(build(), "Gold:")
            assert.truthy(banner._text:find("Spent " .. GBL:FormatMoney(100000) .. ".", 1, true))
        end)

        it("re-baselines the wallet when the tab comes into view, not on a rebuild while it is showing", function()
            GBL:CreateMainFrame()
            GBL.mainFrame:Show()
            readyTwo()
            MockWoW.money = 700000
            GBL._restock.spentEstimate = 300000
            GBL:SelectTab("restock")
            assert.equals(700000, GBL._restock.walletBase)
            assert.equals(300000, GBL._restock.spentAtBase)

            -- RefreshUI after a sync receive or a rescan store lands here
            -- too; with the tab already showing the baseline stays put.
            MockWoW.money = 100000
            GBL:SelectTab("restock")
            assert.equals(700000, GBL._restock.walletBase)

            -- Another tab, then back: the tab came into view again.
            GBL:SelectTab("sort")
            GBL:SelectTab("restock")
            assert.equals(100000, GBL._restock.walletBase)

            -- The window closed and reopened on this tab.
            MockWoW.money = 50000
            GBL.mainFrame:Fire("OnClose")
            GBL:SelectTab("restock")
            assert.equals(50000, GBL._restock.walletBase)
        end)
    end)
    ------------------------------------------------------------------------
    -- The tab over the flow (#214): Done retired, Search offered from the
    -- list in READY, the budget row above the list in every state, the gold
    -- line updated in place, and the list rendered in every state.
    ------------------------------------------------------------------------
    describe("the tab in every state (#214)", function()
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
            GBL.lastScanResults = {}   -- a scan that saw nothing: every layout item is short
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

        it("offers Search in READY and never Done, disabling it on a blocker with the reason on the banner", function()
            readyTwo()
            local container = build()
            assert.is_nil(findButton(container, "Done"))
            local search = findButton(container, "Search auctions")
            assert.is_not_nil(search)
            assert.is_falsy(search.disabled)
            assert.is_not_nil(findButton(container, "Buy next (2 left)"))

            _G.AuctionHouseFrame = { IsShown = function() return false end }
            container = build()
            search = findButton(container, "Search auctions (open the Auction House)")
            assert.is_not_nil(search)
            assert.is_true(search.disabled)
            assert.truthy(findChild(container, "Label")._text:find("Open the Auction House to search or buy.", 1, true))
        end)

        it("starts a new search from READY: progress reset, the pending store kept, the list still there", function()
            readyTwo()
            GBL:GetRestockData().pending[111] = { qty = 1, buyer = "Someone", at = 1 }
            GBL._restock.bought = { [2] = true }
            GBL._restock.boughtTotal = { [2] = 3000 }
            GBL._restock.skipped = { [1] = "max price" }
            findButton(build(), "Search auctions"):Fire("OnClick")
            assert.equals("SEARCHING", GBL._restock.state)
            assert.is_nil(next(GBL._restock.bought))
            assert.is_nil(next(GBL._restock.boughtTotal))
            assert.is_nil(next(GBL._restock.skipped))
            assert.is_not_nil(GBL:GetRestockData().pending[111])
            local scroll = findChild(build(), "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Mats"))
        end)

        it("renders the budget row above the list in every state, with the committed value and the toggle", function()
            layoutTwo()
            GBL:SetRestockConfirmAtPrice(true)
            for _, state in ipairs({ "IDLE", "SEARCHING", "READY", "CONFIRMING", "PRICED" }) do
                GBL._restock = { state = state, activeItems = {}, resultRows = {}, bought = {}, skipped = {},
                                 pendingIndex = 1, pendingItemID = 111, pendingQty = 5, pendingTotal = 5000 }
                local container = build()
                local box = findChild(container, "EditBox")
                assert.is_not_nil(box, state)
                assert.is_not_nil(findLabelContaining(container, "Budget: none"), state)
                local cb = findCheckBox(container, "Confirm at price")
                assert.is_not_nil(cb, state)
                assert.is_true(cb:GetValue(), state)
            end

            GBL._restock = { state = "IDLE" }
            local container = build()
            findChild(container, "EditBox"):Fire("OnEnterPressed", "500")
            assert.equals(500, GBL:GetRestockBudget())
            container = build()
            assert.is_not_nil(findLabelContaining(container, "Budget: 500 g"))
            assert.is_nil(findLabelContaining(container, "Budget: none"))

            -- The toggle writes back and is in the focus order before the list.
            local cb = findCheckBox(container, "Confirm at price")
            cb:SetValue(false)
            cb:Fire("OnValueChanged", false)
            assert.is_false(GBL:IsRestockConfirmAtPrice())
            local idx
            for i, w in ipairs(GBL.A11Y.focusOrder) do
                if w == cb then idx = i end
            end
            assert.is_not_nil(idx)
        end)

        it("shows the gold line in every state and rewrites it in place on PLAYER_MONEY", function()
            layoutTwo()
            MockWoW.money = 1234500
            for _, state in ipairs({ "IDLE", "SEARCHING", "READY", "CONFIRMING", "PRICED" }) do
                GBL._restock = { state = state, activeItems = {}, resultRows = {}, bought = {}, skipped = {},
                                 pendingIndex = 1, pendingItemID = 111, pendingQty = 5, pendingTotal = 5000,
                                 spentEstimate = 0 }
                assert.is_not_nil(findLabelContaining(build(), "Gold: " .. GBL:FormatMoney(1234500)), state)
            end

            GBL.activeTab = "restock"
            GBL:CreateMainFrame()
            GBL.mainFrame:Show()
            GBL.tabGroup = LibStub("AceGUI-3.0"):Create("TabGroup")
            GBL:BuildRestockTab(GBL.tabGroup)
            local gold = findLabelContaining(GBL.tabGroup, "Gold:")
            local builds = 0
            local orig = GBL.BuildRestockTab
            GBL.BuildRestockTab = function(...) builds = builds + 1; return orig(...) end
            MockWoW.money = 999
            GBL:OnPlayerMoney()
            GBL.BuildRestockTab = orig
            assert.equals(0, builds)
            assert.truthy(gold._text:find("Gold: " .. GBL:FormatMoney(999), 1, true))

            -- Another tab active: nothing is written.
            GBL.activeTab = "sort"
            MockWoW.money = 5
            GBL:OnPlayerMoney()
            assert.truthy(gold._text:find("Gold: " .. GBL:FormatMoney(999), 1, true))
        end)

        it("reads bank ? on every row before a scan, with the banner waiting on it", function()
            layoutTwo()
            GBL.lastScanResults = nil
            GBL._restock = { state = "IDLE" }
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            local row = findLabelContaining(scroll, "bank ?")
            assert.is_not_nil(row)
            assert.is_nil(row._text:find("short", 1, true))
            assert.truthy(row._text:find("bank unknown", 1, true))
            assert.truthy(findChild(container, "Label")._text:find("Waiting on the bank scan", 1, true))
        end)

        it("colours the row annotations from the palette, not a grey literal", function()
            readyTwo()
            local scroll = findChild(build(), "ScrollFrame")
            local hex = string.format("%02x%02x%02x", 204, 204, 204)   -- NEUTRAL in the normal palette
            local row = findLabelContaining(scroll, "target 5")
            assert.is_nil(row._text:find("|cffaaaaaa", 1, true))
            assert.truthy(row._text:find("|cff" .. hex, 1, true))
        end)
    end)
    ------------------------------------------------------------------------
    -- The code review of PR B (#214): the unanswered row, one buyable
    -- predicate, the controls held while a purchase is in flight, the walk
    -- skipping refused stops, the gold label's lifetime, orphans during a
    -- search, the estimate on the button.
    ------------------------------------------------------------------------
    describe("review of the tab (#214)", function()
        before_each(function()
            _G.Auctionator = {
                API = { v1 = { ConvertToSearchString = function() return "x" end } },
                EventBus = { RegisterSource = function() end, Register = function() end,
                             Unregister = function() end },
                Shopping = { Tab = { Events = { SearchEnd = "SearchEnd" } } },
            }
            _G.AuctionatorShoppingFrame = { IsVisible = function() return true end,
                                            DoSearch = function() end, StopSearch = function() end }
            GBL.lastScanResults = {}
        end)

        after_each(function()
            _G.Auctionator = nil
            _G.AuctionatorShoppingFrame = nil
        end)

        it("marks the unanswered row awaiting its result, disables every Buy, and says so on the banner", function()
            readyTwo()
            GBL._restock.unanswered = { index = 1, itemID = 111, qty = 5, total = 5000 }
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            local row = findLabelContaining(scroll, "awaiting result")
            assert.is_not_nil(row)
            assert.truthy(row._text:find("item 111", 1, true))
            -- The awaiting row carries no Buy of its own; every other Buy is greyed.
            assert.is_nil(findButton(scroll, "Buy 5 (~" .. GBL:_RestockEstimateText(5000) .. ")"))
            assert.is_true(findButton(scroll, "Buy 3 (~" .. GBL:_RestockEstimateText(3000) .. ")").disabled)
            local next_ = findButton(container, "Buy next (0 left)")
            assert.is_not_nil(next_)
            assert.is_true(next_.disabled)
            assert.truthy(findChild(container, "Label")._text:find("Waiting on the result of item 111", 1, true))
        end)

        it("offers a Buy exactly where the flow would start one: not for a non-commodity, not without a price", function()
            readyTwo()
            GBL._restock.resultRows[1].isCommodity = false
            GBL._restock.resultRows[2].minPrice = 0
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findLabelContaining(scroll, "not a commodity, buy it by hand"))
            assert.is_not_nil(findLabelContaining(scroll, "not found"))
            assert.is_nil(findButton(scroll, "Buy 5 (~" .. GBL:_RestockEstimateText(5000) .. ")"))
            assert.is_nil(findButton(scroll, "Buy 3 (~" .. GBL:_RestockEstimateText(0) .. ")"))
            assert.is_not_nil(findButton(container, "Buy next (0 left)"))
        end)

        it("holds the budget box and the pause toggle while a purchase is in flight", function()
            readyTwo()
            for _, state in ipairs({ "CONFIRMING", "PRICED" }) do
                GBL._restock.state = state
                GBL._restock.pendingIndex = 1
                GBL._restock.pendingItemID = 111
                GBL._restock.pendingQty = 5
                GBL._restock.pendingTotal = 5000
                local container = build()
                assert.is_true(findChild(container, "EditBox").disabled, state)
                assert.is_true(findCheckBox(container, "Confirm at price").disabled, state)
            end
            GBL._restock.state = "READY"
            local container = build()
            assert.is_falsy(findChild(container, "EditBox").disabled)
            assert.is_falsy(findCheckBox(container, "Confirm at price").disabled)
        end)

        it("registers no refused Buy in the focus walk, so Tab from Confirm reaches Cancel and back", function()
            readyTwo()
            GBL._restock.state = "PRICED"
            GBL._restock.pendingIndex = 1
            GBL._restock.pendingItemID = 111
            GBL._restock.pendingQty = 5
            GBL._restock.pendingTotal = 5000
            build()
            for _, w in ipairs(GBL.A11Y.focusOrder) do
                assert.is_falsy(w._type == "Button" and w.disabled, "a disabled button in the walk")
            end
        end)

        it("stops writing the gold line once its label is released, and keeps writing while the frame is only hidden", function()
            layoutTwo()
            GBL._restock = { state = "IDLE" }
            GBL.activeTab = "restock"
            GBL:CreateMainFrame()
            GBL.mainFrame:Show()
            GBL.tabGroup = LibStub("AceGUI-3.0"):Create("TabGroup")
            GBL:BuildRestockTab(GBL.tabGroup)
            local gold = findLabelContaining(GBL.tabGroup, "Gold:")

            -- Hidden, not released (the window closed on this tab): the line
            -- is still the live label and reads fresh when the window reopens.
            GBL.mainFrame:Fire("OnClose")
            MockWoW.money = 777
            GBL:OnPlayerMoney()
            assert.truthy(gold._text:find("Gold: " .. GBL:FormatMoney(777), 1, true))

            -- Released (another tab built over it): the reference is gone with it.
            GBL.tabGroup:ReleaseChildren()
            MockWoW.money = 888
            GBL:OnPlayerMoney()
            assert.is_nil(gold._text:find("Gold: " .. GBL:FormatMoney(888), 1, true))
            assert.is_nil(GBL._restockGoldLabel)
        end)

        it("builds no orphan row while a search is out", function()
            layoutTwo()
            GBL._restock = { state = "SEARCHING", activeItems = { { itemID = 999, needed = 2 } } }
            local scroll = findChild(build(), "ScrollFrame")
            assert.is_nil(findHeading(scroll, "Searched, no longer in the layout"))
            GBL._restock.state = "READY"
            GBL._restock.resultRows = { [1] = { itemKey = { itemID = 999 }, minPrice = 500 } }
            GBL._restock.bought, GBL._restock.skipped = {}, {}
            scroll = findChild(build(), "ScrollFrame")
            assert.is_not_nil(findHeading(scroll, "Searched, no longer in the layout"))
        end)

        it("rounds the estimate on the button to whole gold above one gold, and asks for the width it needs", function()
            assert.equals("2g", GBL:_RestockEstimateText(21000))
            assert.equals("740g", GBL:_RestockEstimateText(7407360))
            assert.equals("10s", GBL:_RestockEstimateText(1000))
            assert.equals("0c", GBL:_RestockEstimateText(0))
            readyTwo()
            local btn = findButton(findChild(build(), "ScrollFrame"), "Buy 5 (~50s)")
            assert.is_not_nil(btn)
            assert.is_true(btn._autoWidth)
        end)
    end)
    ------------------------------------------------------------------------
    -- The Shopping-tab precondition re-reads itself (#217): the blocker is
    -- read on a rebuild and nowhere else, so selecting Auctionator's Shopping
    -- tab with the Restock tab showing left Search greyed until the tab was
    -- left and re-entered. Auctionator creates AuctionatorShoppingFrame on
    -- the first Auction House show of the session, so the hook installs
    -- lazily: from every rebuild, and from a poll after AUCTION_HOUSE_SHOW
    -- while the frame is not there. A burst of firings redraws once, on the
    -- next tick, and only a search or a purchase in flight holds it back:
    -- the in-view flag and the blocker compare the first cut also gated on
    -- were withdrawn after the in-game run, where Search never came back.
    ------------------------------------------------------------------------
    describe("shopping tab refresh (#217)", function()
        local function shoppingFrame(visible)
            local f = { _visible = visible, hooks = {} }
            f.IsVisible = function(self) return self._visible end
            f.HookScript = function(self, script, fn)
                self.hooks[script] = self.hooks[script] or {}
                table.insert(self.hooks[script], fn)
            end
            return f
        end
        -- Fires the hooks registered before the call: a hook body that
        -- rebuilds the tab must not extend the list it is being walked from.
        local function fire(f, script)
            local hooks = {}
            for i, fn in ipairs(f.hooks[script] or {}) do hooks[i] = fn end
            for _, fn in ipairs(hooks) do fn(f) end
        end
        local function hookCount(f, script)
            return #(f.hooks[script] or {})
        end
        local function searchButton()
            return findButtonStarting(GBL.tabGroup, "Search auctions")
        end
        -- What the live path leaves behind: RefreshRestockTab reads
        -- activeTab and tabGroup, and nothing else gates the redraw.
        local function buildLive()
            GBL.activeTab = "restock"
            GBL.tabGroup = LibStub("AceGUI-3.0"):Create("TabGroup")
            GBL:BuildRestockTab(GBL.tabGroup)
        end
        local function countBuilds(fn)
            local builds = 0
            local orig = GBL.BuildRestockTab
            GBL.BuildRestockTab = function(...) builds = builds + 1; return orig(...) end
            fn()
            Helpers.drainZeroDelayTimers()
            GBL.BuildRestockTab = orig
            return builds
        end
        local function polls()
            local out = {}
            for _, t in ipairs(MockWoW.pendingTimers) do
                if not t.cancelled and t.delay == GBL.RESTOCK_SHOPPING_TAB_POLL then out[#out + 1] = t end
            end
            return out
        end

        before_each(function()
            _G.Auctionator = {
                API = { v1 = { ConvertToSearchString = function() return "x" end } },
                EventBus = {},
                Shopping = { Tab = { Events = { SearchEnd = "SearchEnd" } } },
            }
            layoutTwo()
            GBL.lastScanResults = {}
            MockWoW.cancelTimers()
        end)

        after_each(function()
            _G.Auctionator = nil
            _G.AuctionatorShoppingFrame = nil
        end)

        it("installs the OnShow and OnHide hooks once across two rebuilds", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            buildLive()
            assert.equals(1, hookCount(f, "OnShow"))
            assert.equals(1, hookCount(f, "OnHide"))
        end)

        it("OnShow with the Restock tab active redraws it and Search reads enabled", function()
            local f = shoppingFrame(false)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            local btn = searchButton()
            assert.is_true(btn.disabled)
            assert.is_not_nil(findLabelContaining(GBL.tabGroup, "Open the Auctionator Shopping tab first"))

            f._visible = true
            assert.equals(1, countBuilds(function() fire(f, "OnShow") end))
            btn = searchButton()
            assert.is_not_nil(btn)
            assert.is_falsy(btn.disabled)
            assert.is_nil(findLabelContaining(GBL.tabGroup, "Open the Auctionator Shopping tab first"))
        end)

        it("OnHide re-disables Search with the shopping-tab text", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            assert.is_falsy(searchButton().disabled)

            f._visible = false
            assert.equals(1, countBuilds(function() fire(f, "OnHide") end))
            assert.is_true(searchButton().disabled)
            assert.is_not_nil(findLabelContaining(GBL.tabGroup, "Open the Auctionator Shopping tab first"))
        end)

        it("redraws once for a burst of firings in one frame", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            assert.equals(1, countBuilds(function()
                f._visible = false; fire(f, "OnHide")
                f._visible = true;  fire(f, "OnShow")
                f._visible = false; fire(f, "OnHide")
            end))
            assert.is_true(searchButton().disabled)
            -- The next burst is its own redraw: the flag is cleared by the
            -- tick, not left set for the session.
            assert.equals(1, countBuilds(function()
                f._visible = true; fire(f, "OnShow")
            end))
            assert.is_falsy(searchButton().disabled)
        end)

        it("says on the button itself why Search is unavailable, and offers the full reason as a tooltip", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            GBL.lastScanResults = nil          -- no bank scan this session
            buildLive()

            local btn = findButton(GBL.tabGroup, "Search auctions (scan the bank first)")
            assert.is_not_nil(btn)
            assert.is_true(btn.disabled)
            assert.is_true(btn._autoWidth)
            -- The plain label belongs to the state where the click works.
            assert.is_nil(findButton(GBL.tabGroup, "Search auctions"))

            -- The full sentence is the tooltip, so the short tag on the
            -- button does not have to carry the whole instruction.
            local shown
            _G.GameTooltip = {
                SetOwner = function() end,
                SetText = function(_s, text) shown = text end,
                Show = function() end,
                Hide = function() end,
            }
            btn:Fire("OnEnter", btn)
            assert.is_not_nil(shown)
            assert.truthy(shown:find("Waiting on the bank scan", 1, true))
            _G.GameTooltip = nil
        end)

        it("names each precondition on the button", function()
            local f = shoppingFrame(false)
            _G.AuctionatorShoppingFrame = f
            GBL.lastScanResults = nil
            buildLive()
            assert.is_not_nil(findButton(GBL.tabGroup, "Search auctions (open the Shopping tab)"))

            _G.AuctionHouseFrame = nil
            GBL._auctionHouseOpen = nil
            buildLive()
            assert.is_not_nil(findButton(GBL.tabGroup, "Search auctions (open the Auction House)"))
            _G.AuctionHouseFrame = { IsShown = function() return true end }

            _G.Auctionator = nil
            buildLive()
            assert.is_not_nil(findButton(GBL.tabGroup, "Search auctions (needs Auctionator)"))
        end)

        it("drops the tag and the tooltip once nothing blocks the search", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            GBL.lastScanResults = {}
            buildLive()
            local btn = findButton(GBL.tabGroup, "Search auctions")
            assert.is_not_nil(btn)
            assert.is_falsy(btn.disabled)

            local shown
            _G.GameTooltip = {
                SetOwner = function() end,
                SetText = function(_s, text) shown = text end,
                Show = function() end,
                Hide = function() end,
            }
            btn:Fire("OnEnter", btn)
            assert.is_nil(shown)
            _G.GameTooltip = nil
        end)

        it("OnShow with another tab active changes nothing", function()
            local f = shoppingFrame(false)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            GBL.activeTab = "sort"
            f._visible = true
            assert.equals(0, countBuilds(function() fire(f, "OnShow") end))
        end)

        it("does not redraw while a search or a purchase is in flight", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            readyTwo()
            buildLive()
            for _, state in ipairs({ "SEARCHING", "PRICED", "CONFIRMING" }) do
                GBL._restock.state = state
                f._visible = false
                assert.equals(0, countBuilds(function() fire(f, "OnHide") end), state)
                f._visible = true
                assert.equals(0, countBuilds(function() fire(f, "OnShow") end), state)
            end
        end)

        it("raises nothing without the frame and installs on the first rebuild that finds one", function()
            _G.AuctionatorShoppingFrame = nil
            assert.has_no.errors(buildLive)
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            buildLive()
            assert.equals(1, hookCount(f, "OnShow"))
            assert.equals(1, hookCount(f, "OnHide"))
        end)

        it("installs at AUCTION_HOUSE_SHOW without a poll when the frame is already there", function()
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            GBL.activeTab = "sort"
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            assert.equals(1, hookCount(f, "OnShow"))
            assert.equals(0, #polls())
        end)

        it("polls after AUCTION_HOUSE_SHOW while the frame is not there, and a tick that finds it installs and redraws", function()
            _G.AuctionatorShoppingFrame = nil
            buildLive()
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            assert.is_true(searchButton().disabled)
            local poll = polls()
            assert.equals(1, #poll)

            -- Ticks that find nothing keep polling and raise nothing.
            assert.has_no.errors(function() poll[1].callback(); poll[1].callback() end)
            assert.is_false(poll[1].cancelled)

            -- Auctionator built its tabs and showed Shopping: the next tick lands.
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            assert.equals(1, countBuilds(function() poll[1].callback() end))
            assert.equals(1, hookCount(f, "OnShow"))
            assert.is_true(poll[1].cancelled)
            assert.is_falsy(searchButton().disabled)
        end)

        it("starts one poll, and AUCTION_HOUSE_CLOSED cancels it", function()
            _G.AuctionatorShoppingFrame = nil
            buildLive()
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            assert.equals(1, #polls())
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_CLOSED")
            assert.equals(0, #polls())
            local f = shoppingFrame(true)
            _G.AuctionatorShoppingFrame = f
            MockWoW.fireTimers()
            assert.equals(0, hookCount(f, "OnShow"))
        end)

        it("does not poll without Auctionator", function()
            _G.Auctionator = nil
            _G.AuctionatorShoppingFrame = nil
            buildLive()
            GBL:OnAuctionHouseToggled("AUCTION_HOUSE_SHOW")
            assert.equals(0, #polls())
        end)
    end)
end)
