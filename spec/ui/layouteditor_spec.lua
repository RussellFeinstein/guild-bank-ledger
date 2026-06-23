------------------------------------------------------------------------
-- layouteditor_spec.lua — Tests for UI/LayoutEditor.lua helpers.
--
-- The AceGUI rendering path itself is not unit-tested (mock coverage
-- is thin for InlineGroup/Label interactions). These tests cover the
-- pure helper `computeSlotRuns`, which is the correctness-critical
-- part of the v0.29.14 slot-map visualizer.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("LayoutEditor.computeSlotRuns", function()
    local computeSlotRuns

    before_each(function()
        Helpers.setupMocks()
        local GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        computeSlotRuns = GBL._layoutEditorComputeSlotRuns
        assert.is_function(computeSlotRuns,
            "expected GBL._layoutEditorComputeSlotRuns test hook")
    end)

    it("returns an empty list for an empty slotOrder", function()
        assert.same({}, computeSlotRuns({}))
    end)

    it("returns one run for a single item filling S1-S98", function()
        local so = {}
        for s = 1, 98 do so[s] = 42 end
        local runs = computeSlotRuns(so)
        assert.equals(1, #runs)
        assert.equals(1, runs[1].startSlot)
        assert.equals(98, runs[1].endSlot)
        assert.equals(42, runs[1].itemID)
        assert.equals(98, runs[1].length)
    end)

    it("splits into two runs for two contiguous blocks", function()
        local so = {}
        for s = 1, 49 do so[s] = 100 end
        for s = 50, 98 do so[s] = 200 end
        local runs = computeSlotRuns(so)
        assert.equals(2, #runs)
        assert.equals(100, runs[1].itemID)
        assert.equals(1, runs[1].startSlot)
        assert.equals(49, runs[1].endSlot)
        assert.equals(49, runs[1].length)
        assert.equals(200, runs[2].itemID)
        assert.equals(50, runs[2].startSlot)
        assert.equals(98, runs[2].endSlot)
        assert.equals(49, runs[2].length)
    end)

    it("never spans a gap — empty slot breaks the run", function()
        -- A at 1-10, gap at 11, A at 12-20. Two runs, not one.
        local so = {}
        for s = 1, 10 do so[s] = 100 end
        for s = 12, 20 do so[s] = 100 end
        local runs = computeSlotRuns(so)
        assert.equals(2, #runs)
        assert.equals(100, runs[1].itemID)
        assert.equals(1, runs[1].startSlot)
        assert.equals(10, runs[1].endSlot)
        assert.equals(100, runs[2].itemID)
        assert.equals(12, runs[2].startSlot)
        assert.equals(20, runs[2].endSlot)
    end)

    it("isolates single-slot anomalies between same-item runs (v0.29.12 shape)", function()
        -- The exact pattern that caused the v0.29.12 "hidden swap" bug:
        -- A at S1-S23, B at S24, A at S25-S49, B at S50-S98. Four runs —
        -- the two 1-wide B anomalies produce their own runs, visibly odd
        -- next to 23- and 49-wide A runs.
        local so = {}
        for s = 1, 23 do so[s] = 100 end      -- A block
        so[24] = 200                           -- B anomaly
        for s = 25, 49 do so[s] = 100 end     -- A block (resumes)
        for s = 50, 98 do so[s] = 200 end     -- B block
        local runs = computeSlotRuns(so)
        assert.equals(4, #runs)
        -- Run 1: A × 23
        assert.equals(100, runs[1].itemID)
        assert.equals(1, runs[1].startSlot)
        assert.equals(23, runs[1].endSlot)
        assert.equals(23, runs[1].length)
        -- Run 2: B × 1 (anomaly)
        assert.equals(200, runs[2].itemID)
        assert.equals(24, runs[2].startSlot)
        assert.equals(24, runs[2].endSlot)
        assert.equals(1, runs[2].length)
        -- Run 3: A × 25
        assert.equals(100, runs[3].itemID)
        assert.equals(25, runs[3].startSlot)
        assert.equals(49, runs[3].endSlot)
        assert.equals(25, runs[3].length)
        -- Run 4: B × 49
        assert.equals(200, runs[4].itemID)
        assert.equals(50, runs[4].startSlot)
        assert.equals(98, runs[4].endSlot)
        assert.equals(49, runs[4].length)
    end)

    it("handles non-contiguous slot keys (sparse slotOrder)", function()
        -- Items at non-adjacent slots produce distinct runs.
        local so = { [1] = 100, [5] = 100, [10] = 200 }
        local runs = computeSlotRuns(so)
        assert.equals(3, #runs)
        assert.equals(100, runs[1].itemID)
        assert.equals(1, runs[1].startSlot)
        assert.equals(1, runs[1].endSlot)
        assert.equals(100, runs[2].itemID)
        assert.equals(5, runs[2].startSlot)
        assert.equals(5, runs[2].endSlot)
        assert.equals(200, runs[3].itemID)
        assert.equals(10, runs[3].startSlot)
        assert.equals(10, runs[3].endSlot)
    end)

    it("is defensive against nil slotOrder", function()
        assert.same({}, computeSlotRuns(nil))
    end)
end)

describe("LayoutEditor.applyBulkToItems", function()
    local applyBulk
    local MAX_SLOTS = 98

    before_each(function()
        Helpers.setupMocks()
        local GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        applyBulk = GBL._layoutEditorApplyBulkToItems
        assert.is_function(applyBulk,
            "expected GBL._layoutEditorApplyBulkToItems test hook")
    end)

    it("returns 0 and is a no-op for an empty items table", function()
        local tab = { items = {}, slotOrder = {} }
        assert.equals(0, applyBulk(tab, 5, 1, MAX_SLOTS))
        assert.same({}, tab.items)
        assert.same({}, tab.slotOrder)
    end)

    it("sets slots and perSlot on every item when both provided", function()
        local tab = {
            items = {
                [100] = { slots = 1, perSlot = 20 },
                [200] = { slots = 2, perSlot = 5 },
                [300] = { slots = 3, perSlot = 10 },
            },
            slotOrder = {},
        }
        assert.equals(3, applyBulk(tab, 5, 1, MAX_SLOTS))
        assert.equals(5, tab.items[100].slots)
        assert.equals(1, tab.items[100].perSlot)
        assert.equals(5, tab.items[200].slots)
        assert.equals(1, tab.items[200].perSlot)
        assert.equals(5, tab.items[300].slots)
        assert.equals(1, tab.items[300].perSlot)
    end)

    it("leaves perSlot untouched when newPerSlot is nil", function()
        local tab = {
            items = {
                [100] = { slots = 1, perSlot = 20 },
                [200] = { slots = 2, perSlot = 5 },
            },
            slotOrder = {},
        }
        assert.equals(2, applyBulk(tab, 5, nil, MAX_SLOTS))
        assert.equals(5, tab.items[100].slots)
        assert.equals(20, tab.items[100].perSlot)
        assert.equals(5, tab.items[200].slots)
        assert.equals(5, tab.items[200].perSlot)
    end)

    it("leaves slots untouched when newSlots is nil", function()
        local tab = {
            items = {
                [100] = { slots = 3, perSlot = 20 },
            },
            slotOrder = { [1] = 100, [2] = 100, [3] = 100 },
        }
        assert.equals(1, applyBulk(tab, nil, 1, MAX_SLOTS))
        assert.equals(3, tab.items[100].slots)
        assert.equals(1, tab.items[100].perSlot)
        -- Pins untouched when only perSlot changes
        assert.equals(100, tab.slotOrder[1])
        assert.equals(100, tab.slotOrder[2])
        assert.equals(100, tab.slotOrder[3])
    end)

    it("trims slotOrder pins from highest slot when shrinking slots", function()
        local tab = {
            items = {
                [100] = { slots = 5, perSlot = 1 },
            },
            slotOrder = {
                [10] = 100, [11] = 100, [12] = 100, [13] = 100, [14] = 100,
            },
        }
        assert.equals(1, applyBulk(tab, 2, nil, MAX_SLOTS))
        assert.equals(2, tab.items[100].slots)
        -- 3 highest pins removed, 2 lowest kept
        assert.equals(100, tab.slotOrder[10])
        assert.equals(100, tab.slotOrder[11])
        assert.is_nil(tab.slotOrder[12])
        assert.is_nil(tab.slotOrder[13])
        assert.is_nil(tab.slotOrder[14])
    end)

    it("trims pins per-item when shrinking many at once", function()
        -- Bulk-shrink scenario where each item has its declared slot
        -- count fully pinned: shrinking from 5 to 1 should drop 4 pins
        -- per item (highest first) and leave each item's lowest pin
        -- alone — pin removal must be scoped to the item being trimmed,
        -- not bleed into adjacent items' pins.
        local tab = {
            items = {
                [100] = { slots = 5, perSlot = 1 },
                [200] = { slots = 5, perSlot = 1 },
            },
            slotOrder = {
                [1] = 100, [2] = 100, [3] = 100, [4] = 100, [5] = 100,
                [50] = 200, [51] = 200, [52] = 200, [53] = 200, [54] = 200,
            },
        }
        assert.equals(2, applyBulk(tab, 1, nil, MAX_SLOTS))
        -- Item 100: lowest pin (slot 1) kept, 4 highest removed.
        assert.equals(100, tab.slotOrder[1])
        assert.is_nil(tab.slotOrder[2])
        assert.is_nil(tab.slotOrder[3])
        assert.is_nil(tab.slotOrder[4])
        assert.is_nil(tab.slotOrder[5])
        -- Item 200: same — lowest (slot 50) kept, 4 highest removed.
        assert.equals(200, tab.slotOrder[50])
        assert.is_nil(tab.slotOrder[51])
        assert.is_nil(tab.slotOrder[52])
        assert.is_nil(tab.slotOrder[53])
        assert.is_nil(tab.slotOrder[54])
    end)

    it("does not trim pins when growing slots", function()
        local tab = {
            items = {
                [100] = { slots = 2, perSlot = 1 },
            },
            slotOrder = { [1] = 100, [2] = 100 },
        }
        assert.equals(1, applyBulk(tab, 5, nil, MAX_SLOTS))
        assert.equals(5, tab.items[100].slots)
        assert.equals(100, tab.slotOrder[1])
        assert.equals(100, tab.slotOrder[2])
    end)

    it("is defensive against nil tab or missing items", function()
        assert.equals(0, applyBulk(nil, 5, 1, MAX_SLOTS))
        assert.equals(0, applyBulk({}, 5, 1, MAX_SLOTS))
        assert.equals(0, applyBulk({ items = nil }, 5, 1, MAX_SLOTS))
    end)

    it("creates slotOrder when missing and shrinking", function()
        local tab = {
            items = { [100] = { slots = 5, perSlot = 1 } },
            -- slotOrder intentionally absent
        }
        assert.equals(1, applyBulk(tab, 2, nil, MAX_SLOTS))
        assert.is_table(tab.slotOrder)
    end)
end)

describe("LayoutEditor.applyBulkReserve", function()
    local applyBulkReserve

    before_each(function()
        Helpers.setupMocks()
        local GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        applyBulkReserve = GBL._layoutEditorApplyBulkReserve
        assert.is_function(applyBulkReserve,
            "expected GBL._layoutEditorApplyBulkReserve test hook")
    end)

    it("writes the keep value to every item's draft entry, returns the count", function()
        local draft = {}
        local n = applyBulkReserve({ [100] = {}, [200] = {} }, draft, 150)
        assert.equals(2, n)
        assert.equals(150, draft[100])
        assert.equals(150, draft[200])
    end)

    it("coerces string item keys to numbers (synced layout)", function()
        local draft = {}
        applyBulkReserve({ ["100"] = {}, ["200"] = {} }, draft, 75)
        assert.equals(75, draft[100])
        assert.equals(75, draft[200])
        assert.is_nil(draft["100"])
    end)

    it("writes 0 to mark every reserve for removal", function()
        local draft = { [100] = 250 }
        applyBulkReserve({ [100] = {} }, draft, 0)
        assert.equals(0, draft[100])
    end)

    it("is defensive against nil items or nil draft", function()
        assert.equals(0, applyBulkReserve(nil, {}, 5))
        assert.equals(0, applyBulkReserve({ [100] = {} }, nil, 5))
    end)
end)

describe("LayoutEditor._LayoutEditor_ApplyBulk", function()
    local MockWoW = Helpers.MockWoW
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
        GBL._layoutDraft = {
            tabs = {
                [1] = {
                    mode = "display",
                    items = {
                        [100] = { slots = 1, perSlot = 10 },
                        [200] = { slots = 2, perSlot = 5 },
                    },
                    slotOrder = {},
                },
            },
        }
        GBL._reserveDraft = {}
    end)

    it("applies a bulk Keep to every item on the tab", function()
        local ok, res = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, 300)
        assert.is_true(ok)
        assert.equals(300, GBL._reserveDraft[100])
        assert.equals(300, GBL._reserveDraft[200])
        assert.equals(2, res.applied)
    end)

    it("applies slots, perSlot and Keep together", function()
        local ok = GBL:_LayoutEditor_ApplyBulk(1, 4, 12, 50)
        assert.is_true(ok)
        assert.equals(4, GBL._layoutDraft.tabs[1].items[100].slots)
        assert.equals(12, GBL._layoutDraft.tabs[1].items[100].perSlot)
        assert.equals(50, GBL._reserveDraft[100])
        assert.equals(50, GBL._reserveDraft[200])
    end)

    it("a Keep of 0 marks every reserve for removal", function()
        GBL._reserveDraft = { [100] = 250, [200] = 99 }
        local ok = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, 0)
        assert.is_true(ok)
        assert.equals(0, GBL._reserveDraft[100])
        assert.equals(0, GBL._reserveDraft[200])
    end)

    it("coerces a string-keyed (synced) tab to number reserve keys", function()
        GBL._layoutDraft.tabs[1].items = { ["100"] = { slots = 1, perSlot = 10 } }
        local ok = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, 40)
        assert.is_true(ok)
        assert.equals(40, GBL._reserveDraft[100])
        assert.is_nil(GBL._reserveDraft["100"])
    end)

    it("rejects when no field is provided", function()
        local ok, err = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, nil)
        assert.is_false(ok)
        assert.matches("at least one", err)
    end)

    it("rejects a negative Keep", function()
        local ok, err = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, -5)
        assert.is_false(ok)
        assert.matches("Keep", err)
    end)

    it("leaves reserves untouched on a slots/perSlot-only apply", function()
        local ok, res = GBL:_LayoutEditor_ApplyBulk(1, 3, nil, nil)
        assert.is_true(ok)
        assert.is_nil(next(GBL._reserveDraft), "no reserve should be written")
        assert.is_nil(table.concat(res.parts, ","):find("keep"), "no keep= in summary")
    end)

    it("rejects slots below 1", function()
        local ok, err = GBL:_LayoutEditor_ApplyBulk(1, 0, nil, nil)
        assert.is_false(ok)
        assert.matches("Slots", err)
    end)

    it("rejects perSlot below 1", function()
        local ok, err = GBL:_LayoutEditor_ApplyBulk(1, nil, 0, nil)
        assert.is_false(ok)
        assert.matches("Per slot", err)
    end)

    it("floors a fractional Keep", function()
        local ok = GBL:_LayoutEditor_ApplyBulk(1, nil, nil, 5.7)
        assert.is_true(ok)
        assert.equals(5, GBL._reserveDraft[100])
    end)

    it("rejects when there is no draft for the tab", function()
        local ok, err = GBL:_LayoutEditor_ApplyBulk(8, nil, nil, 10)
        assert.is_false(ok)
        assert.matches("draft", err)
    end)
end)

describe("LayoutEditor._LayoutEditor_ApplyReserveDraft", function()
    local MockWoW = Helpers.MockWoW
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: SetStockReserve needs layout-write
        GBL:OnEnable()
    end)

    it("writes new reserves from the draft to the live store", function()
        GBL._reserveDraft = { [100] = 250, [200] = 40 }
        GBL:_LayoutEditor_ApplyReserveDraft()
        local live = GBL:GetStockReserves()
        assert.equals(250, live[100])
        assert.equals(40, live[200])
    end)

    it("removes a reserve when the draft drops it to 0", function()
        GBL:SetStockReserve(100, 250)
        GBL._reserveDraft = { [100] = 0 }
        GBL:_LayoutEditor_ApplyReserveDraft()
        assert.is_nil(GBL:GetStockReserves()[100])
    end)

    it("leaves an unchanged reserve intact", function()
        GBL:SetStockReserve(100, 250)
        GBL._reserveDraft = { [100] = 250 }
        GBL:_LayoutEditor_ApplyReserveDraft()
        assert.equals(250, GBL:GetStockReserves()[100])
    end)

    it("is a no-op when there is no reserve draft", function()
        GBL._reserveDraft = nil
        assert.has_no.errors(function() GBL:_LayoutEditor_ApplyReserveDraft() end)
    end)

    it("keeps a live reserve absent from the draft (added by sync after open)", function()
        GBL:SetStockReserve(100, 250)
        GBL._reserveDraft = { [100] = 250 }   -- draft seeded when the editor opened
        GBL:SetStockReserve(200, 99)          -- a concurrent sync added 200 afterward
        GBL:_LayoutEditor_ApplyReserveDraft()
        assert.equals(250, GBL:GetStockReserves()[100])
        assert.equals(99, GBL:GetStockReserves()[200])
    end)
end)

describe("LayoutEditor Keep field", function()
    local MockWoW = Helpers.MockWoW
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
        GBL.RefreshLayoutTab = function() end  -- isolate the row callback from the rebuild
        GBL._layoutDraft = {
            tabs = {
                [1] = {
                    mode = "display",
                    items = { [100] = { slots = 2, perSlot = 20 } },
                    slotOrder = {},
                },
            },
        }
        GBL._reserveDraft = {}
        GBL._layoutDirty = false
    end)

    local function findKeep(parent)
        local rowGroup = parent._children[1]
        for _, child in ipairs(rowGroup._children) do
            if child._type == "EditBox" and child._label == "Keep" then
                return child
            end
        end
    end

    it("renders a Keep EditBox on the item row", function()
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, 100, true)
        assert.is_not_nil(findKeep(parent), "expected a 'Keep' EditBox on the item row")
    end)

    it("writes the entered value into the reserve draft and marks dirty", function()
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, 100, true)
        findKeep(parent):Fire("OnEnterPressed", "150")
        assert.equals(150, GBL._reserveDraft[100])
        assert.is_true(GBL._layoutDirty)
    end)

    it("shows the existing draft reserve as the field value", function()
        GBL._reserveDraft = { [100] = 75 }
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, 100, true)
        assert.equals("75", findKeep(parent):GetText())
    end)

    it("disables the Keep field for non-writable viewers", function()
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, 100, false)
        assert.is_true(findKeep(parent)._disabled)
    end)

    it("coerces a string itemID (synced layout) to the number-keyed reserve", function()
        GBL._reserveDraft = { [100] = 75 }   -- number-keyed, as GetStockReserves returns
        GBL._layoutDraft.tabs[1].items = { ["100"] = { slots = 2, perSlot = 20 } }
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, "100", true)
        local keep = findKeep(parent)
        assert.equals("75", keep:GetText())        -- read the number-keyed reserve
        keep:Fire("OnEnterPressed", "150")
        assert.equals(150, GBL._reserveDraft[100]) -- wrote a number key
        assert.is_nil(GBL._reserveDraft["100"])    -- not a string key
    end)

    it("clears the item's reserve (sets 0) when the row is removed", function()
        GBL:SetStockReserve(100, 250)
        GBL._reserveDraft = { [100] = 250 }
        local AceGUI = LibStub("AceGUI-3.0")
        local parent = AceGUI:Create("SimpleGroup")
        GBL:_LayoutEditor_RenderItemRow(parent, 1, 100, true)
        local removeBtn
        for _, child in ipairs(parent._children[1]._children) do
            if child._type == "Button" and child:GetText() == "Remove" then
                removeBtn = child
            end
        end
        assert.is_not_nil(removeBtn, "expected a Remove button on the row")
        removeBtn:Fire("OnClick")
        assert.equals(0, GBL._reserveDraft[100])     -- explicit removal marker
        GBL:_LayoutEditor_ApplyReserveDraft()
        assert.is_nil(GBL:GetStockReserves()[100])   -- Save clears the live reserve
    end)
end)

describe("LayoutEditor._LayoutGrantSummary", function()
    local MockWoW = Helpers.MockWoW
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
    end)

    local function setWrite(tier)
        local gd = GBL:GetGuildData()
        gd.sortAccess = {
            write = tier,
            sort  = { rankThreshold = nil, delegates = {} },
            updatedAt = 1,
        }
    end

    it("says GM only when nothing beyond the GM is granted", function()
        assert.equals("GM only", GBL:_LayoutGrantSummary())
    end)

    it("names the rank threshold", function()
        setWrite({ rankThreshold = 3, delegates = {} })
        local s = GBL:_LayoutGrantSummary()
        assert.matches("ranks", s)
        assert.matches("3", s)
    end)

    it("counts delegates", function()
        setWrite({ rankThreshold = nil, delegates = { ["A-R"] = true, ["B-R"] = true } })
        assert.matches("2 delegate", GBL:_LayoutGrantSummary())
    end)

    it("combines rank threshold and delegate count", function()
        setWrite({ rankThreshold = 2, delegates = { ["A-R"] = true } })
        local s = GBL:_LayoutGrantSummary()
        assert.matches("ranks", s)
        assert.matches("1 delegate", s)
    end)
end)
