------------------------------------------------------------------------
-- sortview_spec.lua — the Sort tab's render and keyboard paths.
--
-- Narrow by design. Issue #54 is the full coverage pass and stays open;
-- what is here are the three behaviours a pre-merge review found nothing
-- was holding, each of which a shipped doc already claims:
--
--   1. Every slot reference on the tab renders through FormatSlotRef.
--      The move list did; the Unplaced list did not, so a bag source
--      surfaced as "T-1/5" under a heading blaming the overflow tabs.
--      That is the exact rendering the helper exists to prevent, and the
--      /gbl sortpreview path printed "Bag0/5" for the same entry, so the
--      two surfaces disagreed about the same plan.
--
--   2. Keyboard activation respects a disabled widget. AceGUI's own
--      CheckBox OnClick checks `self.disabled` before firing
--      OnValueChanged; driving SetValue and Fire directly, which is what
--      the focus walk has to do for a checkbox, walks straight past it.
--      The Include bags box is disabled during a run precisely because
--      toggling it nils the cached plan, and the file's own comment says
--      re-planning mid-run misaligns every row marker.
--
--   3. The key-to-action mapping. Deleting the DOWN, UP and
--      ENTER/SPACE branches of _SortView_NavKey left the whole suite
--      green, while README, the CurseForge description and the changelog
--      all state those keys work. RestockView has this coverage already;
--      the Sort copy was written without it.
--
-- The plan is injected rather than planned: setting _sortLastPlan with a
-- sort "running" takes the branch the file documents as authoritative
-- during execution, which is the cheapest way to render an exact plan.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

--- Recursive: first Label whose text contains substr.
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

--- Every Label text in the tree, joined, for absence assertions.
local function allText(container, acc)
    acc = acc or {}
    for _, c in ipairs(container._children or {}) do
        if c._text then acc[#acc + 1] = tostring(c._text) end
        allText(c, acc)
    end
    return acc
end

describe("SortView", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: passes HasSortAccess
        GBL:OnEnable()
    end)

    local function buildTab()
        local AceGUI = LibStub("AceGUI-3.0")
        local container = AceGUI:Create("SimpleGroup")
        GBL:BuildSortTab(container)
        return container
    end

    describe("Unplaced list", function()
        -- A plan whose single unplaced entry came out of the backpack
        -- (bag 0, which encodes as pseudo-tab -1).
        local function bagUnplacedPlan()
            return {
                ops = {},
                deficits = {},
                unplaced = {
                    { itemID = 2447, count = 3, tabIndex = -1, slotIndex = 5,
                      reason = "overflow-full" },
                },
            }
        end

        it("renders a bag source as Bag0/5", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = bagUnplacedPlan()

            local container = buildTab()

            assert.is_not_nil(findLabelContaining(container, "Bag0/5"),
                "the Unplaced row should name the bag slot the item is in")
        end)

        it("never renders a bag source as a negative bank tab", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = bagUnplacedPlan()

            local container = buildTab()

            for _, text in ipairs(allText(container)) do
                assert.is_nil(text:find("T-", 1, true),
                    "no rendered row may contain a negative tab ref: " .. text)
            end
        end)

        it("still renders a bank source as a tab ref", function()
            GBL.IsSortRunning = function() return true end
            local plan = bagUnplacedPlan()
            plan.unplaced[1].tabIndex = 4
            plan.unplaced[1].slotIndex = 12
            GBL._sortLastPlan = plan

            local container = buildTab()

            assert.is_not_nil(findLabelContaining(container, "T4/12"),
                "a bank slot should still render as T4/12")
        end)
    end)

    -- The heading used to assert a cause for every entry under it. #137
    -- shipped a fifth reason, overflow-unviewable, and the tab now draws an
    -- amber line naming the invisible tab directly above a heading blaming
    -- full overflow tabs. Both cannot be true, so the cause moves onto the
    -- rows and the heading stops claiming one.
    describe("Unplaced reasons (#45)", function()
        local function planWith(reason, tabIndex, slotIndex)
            return {
                ops = {}, deficits = {},
                unplaced = {
                    { itemID = 2447, count = 3,
                      tabIndex = tabIndex or 2, slotIndex = slotIndex or 7,
                      reason = reason },
                },
            }
        end

        local function renderText(plan)
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = plan
            return table.concat(allText(buildTab()), "\n")
        end

        it("names the reason on the row", function()
            local R = GBL._sortPlannerReasons
            local blob = renderText(planWith(R.OVERFLOW_FULL))

            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_FULL), 1, true))
        end)

        it("gives a hidden overflow tab its own words", function()
            local R = GBL._sortPlannerReasons
            local blob = renderText(planWith(R.OVERFLOW_UNVIEWABLE))

            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_UNVIEWABLE), 1, true))
        end)

        it("stops the heading blaming full overflow tabs", function()
            local R = GBL._sortPlannerReasons
            local blob = renderText(planWith(R.OVERFLOW_UNVIEWABLE))

            assert.is_nil(blob:find("no room in overflow tabs", 1, true),
                "the heading must not blame full overflow tabs for a hidden one")
        end)

        it("renders an unrecognised reason rather than dropping the row", function()
            local blob = renderText(planWith("over-stack-demand"))

            assert.is_truthy(blob:find("over-stack-demand", 1, true))
            assert.is_truthy(blob:find("T2/7", 1, true))
        end)

        it("names both reasons on a mixed plan", function()
            local R = GBL._sortPlannerReasons
            local plan = planWith(R.OVERFLOW_FULL)
            table.insert(plan.unplaced, { itemID = 2447, count = 4,
                tabIndex = 3, slotIndex = 9, reason = R.CYCLE_NO_PIVOT })
            local blob = renderText(plan)

            assert.is_truthy(blob:find(GBL:SortReasonText(R.OVERFLOW_FULL), 1, true))
            assert.is_truthy(blob:find(GBL:SortReasonText(R.CYCLE_NO_PIVOT), 1, true))
        end)

        it("still routes a bag source through FormatSlotRef", function()
            local R = GBL._sortPlannerReasons
            local blob = renderText(planWith(R.OVERFLOW_FULL, -1, 5))

            assert.is_truthy(blob:find("Bag0/5", 1, true))
            assert.is_nil(blob:find("T-", 1, true))
        end)
    end)

    describe("keyboard activation", function()
        --- The Include bags checkbox, found through the registered focus
        --- order rather than by walking widgets, because the focus order is
        --- what the key handler actually indexes into.
        local function focusIncludeBags()
            local order = GBL.A11Y and GBL.A11Y.focusOrder or {}
            for i, w in ipairs(order) do
                if w._type == "CheckBox" and w._label == "Include bags" then
                    GBL.A11Y.focusIndex = i
                    return w
                end
            end
            return nil
        end

        it("toggles an enabled checkbox", function()
            buildTab()
            local cb = focusIncludeBags()
            assert.is_not_nil(cb, "Include bags should be in the focus order")
            assert.is_falsy(cb.disabled, "precondition: the box is enabled when idle")

            local before = GBL:IsSortIncludeBags()
            assert.is_true(GBL:_SortView_ActivateFocused())

            assert.is_not.equals(before, GBL:IsSortIncludeBags())
        end)

        it("refuses to toggle the checkbox while a sort is running", function()
            GBL.IsSortRunning = function() return true end
            buildTab()
            local cb = focusIncludeBags()
            assert.is_not_nil(cb, "Include bags should be in the focus order")
            assert.is_true(cb.disabled, "precondition: the box is disabled mid-sort")

            local before = GBL:IsSortIncludeBags()
            local handled = GBL:_SortView_ActivateFocused()

            assert.equals(before, GBL:IsSortIncludeBags(),
                "a disabled checkbox must not change the setting")
            assert.is_false(handled,
                "an unhandled key should propagate rather than read as consumed")
        end)

        it("refuses to fire a disabled button", function()
            buildTab()
            local order = GBL.A11Y and GBL.A11Y.focusOrder or {}
            local target, index
            for i, w in ipairs(order) do
                if w._type == "Button" then target, index = w, i break end
            end
            assert.is_not_nil(target, "expected at least one focusable button")

            local fired = false
            target:SetCallback("OnClick", function() fired = true end)
            target:SetDisabled(true)
            GBL.A11Y.focusIndex = index

            assert.is_false(GBL:_SortView_ActivateFocused())
            assert.is_false(fired, "a disabled button must not run its callback")
        end)
    end)

    describe("_SortView_NavKey", function()
        it("advances focus on TAB and retreats on Shift+TAB", function()
            buildTab()
            GBL.A11Y.focusIndex = 1

            assert.is_true(GBL:_SortView_NavKey("TAB", false))
            assert.equals(2, GBL.A11Y.focusIndex)

            assert.is_true(GBL:_SortView_NavKey("TAB", true))
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("advances focus on DOWN and retreats on UP", function()
            buildTab()
            GBL.A11Y.focusIndex = 1

            assert.is_true(GBL:_SortView_NavKey("DOWN", false))
            assert.equals(2, GBL.A11Y.focusIndex)

            assert.is_true(GBL:_SortView_NavKey("UP", false))
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("activates the focused widget on ENTER, NUMPADENTER and SPACE", function()
            for _, key in ipairs({ "ENTER", "NUMPADENTER", "SPACE" }) do
                Helpers.setupMocks()
                GBL = Helpers.loadAddon()
                GBL:OnInitialize()
                MockWoW.guild.name = "Test Guild"
                MockWoW.guild.rankIndex = 0
                GBL:OnEnable()
                buildTab()

                local order = GBL.A11Y.focusOrder
                local fired = false
                for i, w in ipairs(order) do
                    if w._type == "Button" then
                        w:SetCallback("OnClick", function() fired = true end)
                        GBL.A11Y.focusIndex = i
                        break
                    end
                end

                assert.is_true(GBL:_SortView_NavKey(key, false),
                    key .. " should be handled")
                assert.is_true(fired, key .. " should activate the focused widget")
            end
        end)

        it("leaves an unrelated key unhandled so it keeps propagating", function()
            buildTab()
            GBL.A11Y.focusIndex = 1
            assert.is_false(GBL:_SortView_NavKey("ESCAPE", false))
            assert.equals(1, GBL.A11Y.focusIndex)
        end)
    end)

    -- A tab the scan could not see is the one thing the move list cannot
    -- show, because the whole point is that nothing was planned for it
    -- (#137). The warning has to survive the empty-plan early return, or
    -- the case it exists for renders as "nothing to do".
    describe("unviewable overflow tabs", function()
        local function planWithHidden(hidden, ops)
            return {
                ops = ops or {},
                deficits = {},
                unplaced = {},
                unviewableOverflowTabs = hidden,
            }
        end

        it("names the tab the sort routed around", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = planWithHidden({ 5 })

            local container = buildTab()

            assert.is_not_nil(findLabelContaining(container, "Overflow tab 5"),
                "the tab should say which overflow tab was skipped")
        end)

        it("shows the warning on a plan with nothing else in it", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = planWithHidden({ 5 })

            local container = buildTab()
            local blob = table.concat(allText(container), "\n")

            assert.is_truthy(blob:find("nothing to do", 1, true),
                "fixture should be taking the empty-plan path")
            assert.is_truthy(blob:find("Overflow tab 5", 1, true))
        end)

        it("names each hidden tab", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = planWithHidden({ 5, 7 })

            local container = buildTab()

            assert.is_not_nil(findLabelContaining(container, "Overflow tab 5"))
            assert.is_not_nil(findLabelContaining(container, "Overflow tab 7"))
        end)

        it("says nothing when no tab was hidden", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = planWithHidden({})

            local container = buildTab()

            for _, text in ipairs(allText(container)) do
                assert.is_nil(text:find("Overflow tab", 1, true))
            end
        end)

        it("tolerates a plan built before the field existed", function()
            GBL.IsSortRunning = function() return true end
            GBL._sortLastPlan = { ops = {}, deficits = {}, unplaced = {} }

            local container = buildTab()

            assert.is_not_nil(container)
        end)
    end)
end)
