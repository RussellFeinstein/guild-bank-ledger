------------------------------------------------------------------------
-- persistence_spec.lua — Window position/size persistence wiring.
--
-- Covers v0.32.4 wiring:
--   * SetStatusTable is pointed at db.profile.ui (writes persist via AceDB)
--   * SetResizeBounds (or SetMinResize on classic) enforces an 810x500 floor
--   * Each resize sizer has an OnMouseUp hook registered
--   * The fill-anchor registry: AddFillChild + _RefillScrollContainers
--     + tab-switch cleanup
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

local function lastAnchor(frame)
    local list = frame._anchors
    if not list or #list == 0 then return nil end
    return list[#list]
end

describe("UI window persistence (v0.32.4)", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    ----------------------------------------------------------------
    -- CreateMainFrame wiring
    ----------------------------------------------------------------

    describe("CreateMainFrame", function()
        it("routes SetStatusTable at db.profile.ui so MoverSizer writes persist", function()
            GBL:CreateMainFrame()
            -- Same table identity, not a copy: the AceGUI MoverSizer mutates
            -- this table in place, so it must be the live AceDB profile.
            assert.equals(GBL.db.profile.ui, GBL.mainFrame._statusTable)
        end)

        it("enforces an 810x500 minimum window size", function()
            GBL:CreateMainFrame()
            -- Retail uses SetResizeBounds (10.0+); classic uses SetMinResize.
            -- Production code prefers the former when present; either path
            -- must end with the same floor recorded on the mock frame.
            local bounds = GBL.mainFrame.frame._resizeBounds
                or GBL.mainFrame.frame._minResize
            assert.is_table(bounds, "expected SetResizeBounds or SetMinResize to be called")
            assert.equals(810, bounds[1])
            assert.equals(500, bounds[2])
        end)

        it("registers an OnMouseUp hook on each resize sizer", function()
            GBL:CreateMainFrame()
            for _, name in ipairs({ "sizer_se", "sizer_s", "sizer_e" }) do
                local hooks = GBL.mainFrame[name]._hookScripts.OnMouseUp
                assert.is_table(hooks, name .. " missing OnMouseUp hook")
                assert.is_true(#hooks >= 1, name .. " hook list is empty")
            end
        end)

        it("is idempotent on repeat calls", function()
            GBL:CreateMainFrame()
            local first = GBL.mainFrame
            GBL:CreateMainFrame()
            assert.equals(first, GBL.mainFrame)
        end)
    end)

    ----------------------------------------------------------------
    -- Fill-anchor registry
    ----------------------------------------------------------------

    describe("AddFillChild registry", function()
        local AceGUI

        before_each(function()
            GBL:CreateMainFrame()
            -- Start each registry test with a clean slate; CreateMainFrame's
            -- RebuildTabs path builds the default tab and may register a
            -- container as a side effect.
            GBL._scrollFillContainers = nil
            AceGUI = LibStub("AceGUI-3.0")
        end)

        it("stores the parent/widget pair for later re-anchoring", function()
            local parent = AceGUI:Create("SimpleGroup")
            local scroll = AceGUI:Create("ScrollFrame")
            GBL:AddFillChild(parent, scroll)
            assert.equals(1, #GBL._scrollFillContainers)
            assert.equals(scroll, GBL._scrollFillContainers[1].widget)
            assert.equals(parent, GBL._scrollFillContainers[1].parent)
        end)

        it("anchors the child to parent.content BOTTOMRIGHT on registration", function()
            local parent = AceGUI:Create("SimpleGroup")
            local scroll = AceGUI:Create("ScrollFrame")
            scroll.frame._anchors = {}   -- isolate from any prior pool state
            GBL:AddFillChild(parent, scroll)
            local anchor = lastAnchor(scroll.frame)
            assert.is_table(anchor, "expected SetPoint to be called on the scroll frame")
            assert.equals("BOTTOMRIGHT", anchor[1])
            assert.equals(parent.content, anchor[2])
            assert.equals("BOTTOMRIGHT", anchor[3])
        end)

        it("adds the scroll widget as a child of the parent container", function()
            local parent = AceGUI:Create("SimpleGroup")
            local scroll = AceGUI:Create("ScrollFrame")
            GBL:AddFillChild(parent, scroll)
            -- AceGUI mock tracks children in _children; the scroll widget must
            -- end up there so the layout cascade can find it.
            local found = false
            for _, child in ipairs(parent._children) do
                if child == scroll then found = true; break end
            end
            assert.is_true(found, "scroll widget not added to parent")
        end)

        it("appends multiple registrations preserving order", function()
            local p1, s1 = AceGUI:Create("SimpleGroup"), AceGUI:Create("ScrollFrame")
            local p2, s2 = AceGUI:Create("SimpleGroup"), AceGUI:Create("ScrollFrame")
            GBL:AddFillChild(p1, s1)
            GBL:AddFillChild(p2, s2)
            assert.equals(2, #GBL._scrollFillContainers)
            assert.equals(s1, GBL._scrollFillContainers[1].widget)
            assert.equals(s2, GBL._scrollFillContainers[2].widget)
        end)
    end)

    ----------------------------------------------------------------
    -- Resize-driven re-anchor (onResizeStop)
    ----------------------------------------------------------------

    describe("onResizeStop", function()
        local AceGUI

        before_each(function()
            GBL:CreateMainFrame()
            GBL._scrollFillContainers = nil
            AceGUI = LibStub("AceGUI-3.0")
        end)

        local function fireResize(sizerName)
            local hooks = GBL.mainFrame[sizerName]._hookScripts.OnMouseUp
            for _, fn in ipairs(hooks) do fn() end
        end

        it("re-applies BOTTOMRIGHT on every registered container", function()
            local p1, s1 = AceGUI:Create("SimpleGroup"), AceGUI:Create("ScrollFrame")
            local p2, s2 = AceGUI:Create("SimpleGroup"), AceGUI:Create("ScrollFrame")
            s1.frame._anchors = {}
            s2.frame._anchors = {}
            GBL:AddFillChild(p1, s1)
            GBL:AddFillChild(p2, s2)
            local before1, before2 = #s1.frame._anchors, #s2.frame._anchors
            fireResize("sizer_se")
            assert.is_true(#s1.frame._anchors > before1, "s1 was not re-anchored")
            assert.is_true(#s2.frame._anchors > before2, "s2 was not re-anchored")
            assert.equals("BOTTOMRIGHT", lastAnchor(s1.frame)[1])
            assert.equals(p1.content,    lastAnchor(s1.frame)[2])
            assert.equals("BOTTOMRIGHT", lastAnchor(s2.frame)[1])
            assert.equals(p2.content,    lastAnchor(s2.frame)[2])
        end)

        it("fires on all three sizers (corner, south, east)", function()
            local parent = AceGUI:Create("SimpleGroup")
            local scroll = AceGUI:Create("ScrollFrame")
            scroll.frame._anchors = {}
            GBL:AddFillChild(parent, scroll)
            local baseline = #scroll.frame._anchors
            fireResize("sizer_se")
            fireResize("sizer_s")
            fireResize("sizer_e")
            -- One re-anchor per fire on top of the initial registration anchor.
            assert.equals(baseline + 3, #scroll.frame._anchors)
        end)

        it("is a no-op when no containers are registered", function()
            GBL._scrollFillContainers = nil
            -- Must not error even with an empty registry.
            assert.has_no.errors(function() fireResize("sizer_se") end)
        end)

        it("skips entries whose widget or parent is missing fields", function()
            -- Defensive coverage for the `if widget and widget.frame and ...`
            -- guard in _RefillScrollContainers: a corrupt entry must not break
            -- the rest of the iteration.
            local goodParent = AceGUI:Create("SimpleGroup")
            local goodScroll = AceGUI:Create("ScrollFrame")
            goodScroll.frame._anchors = {}
            GBL._scrollFillContainers = {
                { widget = nil, parent = goodParent },
                { widget = goodScroll, parent = nil },
                { widget = goodScroll, parent = goodParent },
            }
            local before = #goodScroll.frame._anchors
            assert.has_no.errors(function()
                GBL:_RefillScrollContainers()
            end)
            -- The third (well-formed) entry must still have been re-anchored.
            assert.is_true(#goodScroll.frame._anchors > before)
        end)
    end)

    ----------------------------------------------------------------
    -- Tab-switch cleanup
    ----------------------------------------------------------------

    describe("SelectTab", function()
        local AceGUI

        before_each(function()
            GBL:CreateMainFrame()
            AceGUI = LibStub("AceGUI-3.0")
        end)

        it("clears prior fill-anchor registrations before building the next tab", function()
            -- Seed a fake registration from a prior tab build.
            local stale = { widget = AceGUI:Create("ScrollFrame"), parent = AceGUI:Create("SimpleGroup") }
            GBL._scrollFillContainers = { stale }

            -- Switching tabs releases the prior children; the registry must
            -- not carry the stale reference forward into the new tab build.
            GBL:SelectTab("changelog")

            local list = GBL._scrollFillContainers or {}
            for _, entry in ipairs(list) do
                assert.is_not.equals(stale.widget, entry.widget,
                    "stale registration survived tab switch")
            end
        end)
    end)

    ----------------------------------------------------------------
    -- Convention enforcement: every state-light tab builder
    -- registers at least one fill child via AddFillChild.
    --
    -- This is the regression net for "future BuildXxxTab forgets the
    -- helper and silently re-opens the resize-anchor-loss bug."
    --
    -- Skipped intentionally: BuildSortTab and BuildLayoutTab need
    -- state plumbing (RegisterMessage, bank snapshot, guild data,
    -- _layoutDraft, plus the AceGUI mock's no-op SelectTab) larger
    -- than this PR's scope.  See project_ui_smoke_test_gaps memory
    -- for the path to closing those gaps.
    ----------------------------------------------------------------

    describe("every state-light tab builder registers a fill child", function()
        local AceGUI

        before_each(function()
            -- Some builders touch self.activeTab or self.tabGroup, both
            -- of which CreateMainFrame populates.  Reset the registry
            -- after CreateMainFrame so each test sees only its own
            -- builder's contribution.
            GBL:CreateMainFrame()
            GBL._scrollFillContainers = nil
            AceGUI = LibStub("AceGUI-3.0")
        end)

        -- Some builders crash partway through under the test mock
        -- (e.g. Label.label:SetWordWrap is a real AceGUI feature the
        -- mock does not stub).  That post-helper crash is unrelated to
        -- the convention being tested: as long as AddFillChild was
        -- reached BEFORE the crash, the convention holds.  pcall the
        -- builder and assert on the registry afterward.
        local function buildAndCheck(buildFn)
            pcall(buildFn)
            local count = GBL._scrollFillContainers and #GBL._scrollFillContainers or 0
            assert.is_true(count >= 1,
                "builder did not call AddFillChild before any subsequent crash")
        end

        local function freshContainer()
            return AceGUI:Create("SimpleGroup")
        end

        it("BuildTransactionsTab", function()
            buildAndCheck(function() GBL:BuildTransactionsTab(freshContainer(), {}) end)
        end)

        it("BuildGoldLogTab", function()
            buildAndCheck(function() GBL:BuildGoldLogTab(freshContainer(), {}) end)
        end)

        it("BuildConsumptionTab", function()
            buildAndCheck(function() GBL:BuildConsumptionTab(freshContainer(), {}) end)
        end)

        it("BuildAboutTab", function()
            buildAndCheck(function() GBL:BuildAboutTab(freshContainer()) end)
        end)

        it("BuildChangelogTab", function()
            buildAndCheck(function() GBL:BuildChangelogTab(freshContainer()) end)
        end)

        it("BuildSyncTab", function()
            buildAndCheck(function() GBL:BuildSyncTab(freshContainer()) end)
        end)
    end)
end)
