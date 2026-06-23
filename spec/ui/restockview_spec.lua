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

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: passes HasLayoutWrite for SetStockReserve
        GBL:OnEnable()
    end)

    describe("GetRestockStatusDisplay", function()
        it("distinguishes buy / stocked / over by color, icon and text", function()
            local buy = GBL:GetRestockStatusDisplay({ target = 60, stock = 20, toBuy = 40 })
            local stocked = GBL:GetRestockStatusDisplay({ target = 60, stock = 60, toBuy = 0 })
            local over = GBL:GetRestockStatusDisplay({ target = 60, stock = 80, toBuy = 0 })

            assert.equals("buy", buy.status)
            assert.equals("stocked", stocked.status)
            assert.equals("over", over.status)

            assert.equals("Buy 40", buy.text)
            assert.equals("Stocked", stocked.text)
            assert.equals("Over 20", over.text)

            -- shape channel: "buy" has its own icon; "over" shares the check icon
            -- with "stocked" (both mean no buy needed) but stays distinguishable
            -- by color and text, so status is never conveyed by color alone.
            assert.is_true(buy.icon ~= stocked.icon)
            assert.equals(stocked.icon, over.icon)
            assert.is_true(stocked.text ~= over.text)
            -- color channel: distinct palette entries
            assert.is_true(buy.color ~= stocked.color)
            assert.is_true(stocked.color ~= over.color)
        end)

        it("treats a nil or empty row as stocked", function()
            assert.equals("stocked", GBL:GetRestockStatusDisplay(nil).status)
            assert.equals("stocked", GBL:GetRestockStatusDisplay({}).status)
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
        end

        it("renders the layout items grouped by tab name", function()
            configureLayout()
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
            assert.is_not_nil(findHeading(scroll, "Consumables"))
            assert.is_not_nil(findLabelContaining(scroll, "target 20"))
            -- triple-encoded status is wired into the row (text + icon channels)
            assert.is_not_nil(findLabelContaining(scroll, "Buy 20"))
            assert.is_not_nil(findLabelContaining(scroll, "|T"))
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

        it("renders a searching message in the SEARCHING state", function()
            GBL._restock = { state = "SEARCHING", activeItems = { { itemID = 1, needed = 1 } } }
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findLabelContaining(scroll, "Searching the Auction House"))
        end)

        it("renders search results in READY, formatting price with FormatMoney", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 55555, needed = 5 }, { itemID = 66666, needed = 3 } },
                resultRows = { [1] = { minPrice = 4200 } },  -- 55555 found (42s); 66666 missing
                foundCount = 1,
            }
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(scroll)
            assert.is_not_nil(findLabelContaining(scroll, "need 5"))
            assert.is_not_nil(findLabelContaining(scroll, GBL:FormatMoney(4200)))  -- not "0 g"
            assert.is_not_nil(findLabelContaining(scroll, "not found"))
            -- the new result labels must keep explicit SetFont flags (12.0.7 guard)
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

        it("renders a confirming message and a Cancel button in CONFIRMING", function()
            GBL._restock = { state = "CONFIRMING", activeItems = {}, resultRows = {} }
            local container = build()
            local scroll = findChild(container, "ScrollFrame")
            assert.is_not_nil(findLabelContaining(scroll, "Confirming purchase"))
            assert.is_not_nil(findButton(container, "Cancel"))
        end)

        it("wires each per-row Buy button to that row's item", function()
            GBL._restock = {
                state = "READY",
                activeItems = { { itemID = 111, needed = 5 }, { itemID = 222, needed = 3 } },
                resultRows = { [1] = { itemKey = { itemID = 111 }, minPrice = 1000 },
                               [2] = { itemKey = { itemID = 222 }, minPrice = 1000 } },
                bought = {}, skipped = {}, runStartMoney = 1000000,
            }
            MockWoW.money = 1000000
            local container = build()
            local btn = findButton(container, "Buy 3")  -- item 222 (needs 3)
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
                bought = {}, skipped = {}, runStartMoney = 1000000,
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
                bought = {}, skipped = {}, runStartMoney = 1000000,
            }
            MockWoW.money = 1000000  -- spent 0
            local container = build()
            local banner = findChild(container, "Label")
            assert.truthy(banner._text:find("Spent", 1, true))
            assert.truthy(banner._text:find("Gold", 1, true))  -- current wallet shown
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

        it("DOWN and UP move focus", function()
            GBL:_RestockView_NavKey("DOWN", false)
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

        it("returns false for an unhandled key", function()
            assert.is_false(GBL:_RestockView_NavKey("X", false))
        end)
    end)

    describe("OpenRestockTab", function()
        it("opens to the Restock tab for a sort-access user", function()
            GBL:OpenRestockTab()  -- GM (rankIndex 0) has sort access
            assert.equals("restock", GBL.tabGroup._selectedTab)
        end)

        it("declines and prints for a user without sort access", function()
            MockWoW.guild.rankIndex = 5  -- not GM; no sortAccess grant
            GBL:OpenRestockTab()
            assert.is_true(Helpers.printContains("sort access"))
            assert.is_nil(GBL.tabGroup)
        end)
    end)
end)
