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
