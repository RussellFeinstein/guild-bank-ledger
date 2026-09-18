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

    -- The tab is coded for four row markers and only one has ever drawn.
    -- 0a368d5 (2026-05-22) replaced the confirmation-based executor with the
    -- fire-and-forget pump, deleted every producer of completedOpIndex /
    -- reclassifiedOpIndex / failedOpIndex, and left the consumer standing
    -- (#162). Nothing went red because neither side had a test: this is the
    -- first spec _SortView_OnProgress has ever had, and GBL_SORT_PROGRESS had
    -- never been fired anywhere in the suite.
    --
    -- Three setup lines are load-bearing, each with its own early return
    -- behind it, and each one silently turns a test into a no-op:
    --   activeTab      the handler returns at :525 without it.
    --   tabGroup       RefreshSortTab returns at :277 without it, so the
    --                  planupdated and repaint tests would assert against a
    --                  tree nothing rebuilt and pass while doing nothing.
    --   IsSortRunning  _SortView_Preview clears _sortOpStatus at :299 when a
    --                  sort is NOT running, wiping the markers under test on
    --                  the way through a rebuild.
    --
    -- Every assertion here reads rendered label text. _sortOpStatus is an
    -- internal flag, and a test naming it passes whether or not a marker ever
    -- draws, which is exactly how the focus-ring stub shipped.
    describe("progress markers (#162)", function()
        -- Anchored on the slot pair, which is unique per row and survives a
        -- marker being prefixed to the row.
        local ROW_ANCHOR = { "T1/3 -> T5/1", "Bag0/7 -> T5/2", "Bag1/25 -> T5/3" }

        local function opsPlan()
            return {
                ops = {
                    { op = "move",  srcTab =  1, srcSlot =  3,
                      dstTab = 5, dstSlot = 1, itemID = 2589, count = 20 },
                    { op = "split", srcTab = -1, srcSlot =  7,
                      dstTab = 5, dstSlot = 2, itemID = 2770, count = 12 },
                    { op = "move",  srcTab = -2, srcSlot = 25,
                      dstTab = 5, dstSlot = 3, itemID = 4306, count =  8 },
                },
                deficits = {},
                unplaced = {},
            }
        end

        --- Rendered text of the move-list row for op `idx`, or nil.
        local function rowText(container, idx)
            local lbl = findLabelContaining(container, ROW_ANCHOR[idx])
            return lbl and lbl._text or nil
        end

        --- Assert row `idx` renders with `marker` as its prefix.
        local function assertMarker(container, idx, marker, why)
            local row = rowText(container, idx)
            assert.is_not_nil(row, "row " .. idx .. " is not in the move list")
            assert.equals(marker, row:sub(1, #marker),
                (why or ("row " .. idx)) .. ": " .. row)
        end

        local function fire(payload)
            Helpers.MockAce.fireMessage("GBL_SORT_PROGRESS", payload)
        end

        before_each(function()
            GBL.IsSortRunning = function() return true end
            GBL.activeTab = "sort"
            GBL._sortLastPlan = opsPlan()
        end)

        -- The case the markers exist for, and the only route #169's seven
        -- refusal reasons have to a player who is not reading the sort log.
        it("marks a refused op and names its reason and detail", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()

            fire({ phase = "step", opIndex = 3, total = 3, failedOpIndex = 2,
                   failedReason = "short-stack", failedDetail = "have 12" })

            assertMarker(container, 2, MARK.failed, "a refused op")
            local row = rowText(container, 2)
            assert.is_truthy(row:find("short-stack", 1, true),
                "a refused row should name the reason: " .. row)
            assert.is_truthy(row:find("have 12", 1, true),
                "a refused row should carry the detail: " .. row)
        end)

        it("marks an issued op and leaves exactly one row current", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()

            fire({ phase = "step", opIndex = 1, total = 3 })
            fire({ phase = "step", opIndex = 2, total = 3, issuedOpIndex = 1 })

            assertMarker(container, 1, MARK.issued, "the op just issued")
            assertMarker(container, 2, MARK.current, "the op the pump is on")

            local currents = 0
            for idx = 1, 3 do
                local row = rowText(container, idx) or ""
                if row:sub(1, #MARK.current) == MARK.current then
                    currents = currents + 1
                end
            end
            assert.equals(1, currents, "exactly one row should be current")
        end)

        it("marks the named op current", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()

            fire({ phase = "step", opIndex = 2, total = 3 })

            assertMarker(container, 2, MARK.current)
        end)

        it("clears markers left by a previous run", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()
            GBL.tabGroup = container

            fire({ phase = "step", opIndex = 2, total = 3, issuedOpIndex = 1 })
            assertMarker(container, 1, MARK.issued)

            fire({ phase = "start", total = 3 })
            GBL:RefreshSortTab()

            assertMarker(container, 1, "  ", "a cleared row")
        end)

        it("renders the finish line from done and failed", function()
            local container = buildTab()

            fire({ phase = "finish", ok = true, done = 7, failed = 2,
                   replans = 1, total = 3 })

            assert.is_not_nil(
                findLabelContaining(container, "7 done, 2 failed, 1 replans"),
                "the completion line should report the residual-based counts")
        end)

        it("renders an aborted finish with its reason", function()
            local container = buildTab()

            fire({ phase = "finish", ok = false, reason = "bank closed",
                   done = 4, failed = 5, replans = 0, total = 3 })

            local lbl = findLabelContaining(container, "bank closed")
            assert.is_not_nil(lbl, "an abort should name its reason")
            assert.is_truthy(lbl._text:find("4 done, 5 failed", 1, true),
                lbl._text)
        end)

        -- The file's own comment says these counters accumulate across
        -- replans while total is the current plan's size, so the numerator
        -- can outrun the denominator. Nothing pinned the clamp.
        it("clamps the op counter to the plan size", function()
            local container = buildTab()

            fire({ phase = "step", opIndex = 5, total = 3, issued = 3,
                   refused = 0, replans = 0 })

            assert.is_not_nil(findLabelContaining(container, "op 3 / 3"),
                "the counter should clamp rather than print op 5 / 3")
        end)

        it("swaps the plan, clears markers and rebuilds on planupdated", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()
            GBL.tabGroup = container

            fire({ phase = "step", opIndex = 2, total = 3, issuedOpIndex = 1 })
            assertMarker(container, 1, MARK.issued)

            local newPlan = {
                ops = { { op = "move", srcTab = 7, srcSlot = 1, dstTab = 5,
                          dstSlot = 9, itemID = 858, count = 4 } },
                deficits = {}, unplaced = {},
            }
            fire({ phase = "planupdated", plan = newPlan, total = 1 })

            assert.equals(newPlan, GBL._sortLastPlan)
            assert.is_not_nil(findLabelContaining(container, "T7/1 -> T5/9"),
                "the rebuilt move list should show the new plan")
            assert.is_nil(rowText(container, 1),
                "the old plan's rows should be gone")
        end)

        it("repaints markers and reasons after a rebuild", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()
            GBL.tabGroup = container

            fire({ phase = "step", opIndex = 3, total = 3, issuedOpIndex = 1 })
            fire({ phase = "step", opIndex = 3, total = 3, failedOpIndex = 2,
                   failedReason = "locked" })
            GBL:RefreshSortTab()

            assertMarker(container, 1, MARK.issued)
            assertMarker(container, 2, MARK.failed)
            assertMarker(container, 3, MARK.current)
            local row = rowText(container, 2)
            assert.is_truthy(row:find("locked", 1, true),
                "the reason should survive the rebuild too: " .. row)
        end)

        -- mark() records into _sortOpStatus whether or not a widget exists,
        -- and the nil-row arm is reachable through #163: a planupdated
        -- dropped while the user is on another tab leaves the rendered plan a
        -- pass behind, so a step can name an index this move list has no row
        -- for. Recording anyway is what turns that into a stale display
        -- rather than an error, and lets the repaint catch up.
        it("records a marker for an index the move list has no row for", function()
            local MARK = GBL._sortStatusMarkers
            local container = buildTab()
            GBL.tabGroup = container

            fire({ phase = "step", opIndex = 5, total = 5, issuedOpIndex = 4 })

            local bigger = opsPlan()
            bigger.ops[4] = { op = "move", srcTab = 7, srcSlot = 1,
                              dstTab = 5, dstSlot = 9, itemID = 858, count = 4 }
            GBL._sortLastPlan = bigger
            GBL:RefreshSortTab()

            local lbl = findLabelContaining(container, "T7/1 -> T5/9")
            assert.is_not_nil(lbl, "row 4 should be in the rebuilt move list")
            assert.equals(MARK.issued, lbl._text:sub(1, #MARK.issued),
                "the marker recorded without a widget should repaint: "
                .. lbl._text)
        end)

        it("tolerates a phase it does not know", function()
            local container = buildTab()

            fire({ phase = "reclassify", opIndex = 2, total = 3, issued = 1,
                   refused = 0, replans = 0 })

            assert.is_not_nil(findLabelContaining(container, "op 2 / 3"))
        end)
    end)
end)
