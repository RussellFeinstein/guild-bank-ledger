------------------------------------------------------------------------
-- sort_include_bags_spec.lua — the "Include bags" setting and its wiring
-- through the Core sort commands and the Sort tab (#139).
--
-- The planner and executor halves live in sortplanner_spec.lua and
-- sortexecutor_spec.lua. This file covers the seam between the saved
-- setting and those two: who reads it, what they build from it, and what
-- is deliberately left alone.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

local function openBank(GBL)
    MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
        Enum.PlayerInteractionType.GuildBanker)
    GBL.bankOpen = true
end

describe("Include bags in sort", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    --- A layout with one display demand for item 100 plus an overflow tab.
    local function installLayout(perSlot)
        local guildData = GBL:GetGuildData()
        guildData.bankLayout = {
            version = 1,
            updatedAt = 1000,
            tabs = {
                [1] = { mode = "display",
                        items = { [100] = { slots = 1, perSlot = perSlot } },
                        slotOrder = { [1] = 100 } },
                [2] = { mode = "overflow" },
            },
        }
    end

    --- RunSortExec is HasSortAccess-gated; grant the sort tier so the tests
    --- below exercise the wiring rather than the access check.
    local function grantSortAccess()
        local gd = GBL:GetGuildData()
        gd.sortAccess = {
            write = { rankThreshold = nil, delegates = {} },
            sort  = { rankThreshold = 9, delegates = {} },
            updatedAt = 1,
        }
    end

    --- Put a scan snapshot in place with the given tabs empty.
    local function installEmptyScan()
        MockWoW.addTab("Tab 1", nil, true)
        MockWoW.addTab("Tab 2", nil, true)
        GBL.lastScanResults = {
            [1] = { slots = {}, itemCount = 0 },
            [2] = { slots = {}, itemCount = 0 },
        }
        GBL.lastScanTime = MockWoW.serverTime
    end

    describe("the setting itself", function()
        it("defaults to off", function()
            assert.is_false(GBL.db.profile.sort.includeBags)
        end)

        it("reads back through IsSortIncludeBags", function()
            assert.is_false(GBL:IsSortIncludeBags())
            GBL.db.profile.sort.includeBags = true
            assert.is_true(GBL:IsSortIncludeBags())
        end)
    end)

    describe("BuildSortPlanOpts", function()
        it("returns nil when bags are off, so a bank-only plan is unchanged", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            assert.is_nil(GBL:BuildSortPlanOpts())
        end)

        it("carries a freshly scanned bag snapshot when bags are on", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL.db.profile.sort.includeBags = true

            local opts = GBL:BuildSortPlanOpts()
            assert.is_not_nil(opts)
            assert.is_not_nil(opts.bagSnapshot)
            assert.equals(1, opts.bagSnapshot[-1].itemCount)
        end)

        it("re-reads the bags on each call rather than caching", function()
            GBL.db.profile.sort.includeBags = true
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local first = GBL:BuildSortPlanOpts()
            Helpers.populateBag(0, {})
            local second = GBL:BuildSortPlanOpts()

            assert.equals(1, first.bagSnapshot[-1].itemCount)
            assert.is_true(second.bagSnapshot[-1] == nil
                or second.bagSnapshot[-1].itemCount == 0)
        end)
    end)

    describe("/gbl sortpreview", function()
        it("plans from bags when the setting is on", function()
            installLayout(20)
            installEmptyScan()
            Helpers.populateBag(0, {
                [3] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL.db.profile.sort.includeBags = true

            Helpers.clearPrints()
            GBL:PrintSortPreview()
            local blob = table.concat(MockWoW.prints, "\n")
            assert.is_truthy(blob:find("Bag0/3", 1, true))
            assert.is_nil(blob:find("T-", 1, true))
        end)

        it("leaves bags out when the setting is off", function()
            installLayout(20)
            installEmptyScan()
            Helpers.populateBag(0, {
                [3] = { itemID = 100, name = "Flask", count = 20 },
            })

            Helpers.clearPrints()
            GBL:PrintSortPreview()
            local blob = table.concat(MockWoW.prints, "\n")
            assert.is_nil(blob:find("Bag0/", 1, true))
            -- The stack is invisible, so the demand is still a deficit.
            assert.is_truthy(blob:find("0 moves", 1, true))
        end)
    end)

    describe("/gbl sortexec", function()
        it("passes includeBags through to the executor", function()
            installLayout(20)
            installEmptyScan()
            openBank(GBL)
            grantSortAccess()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL.db.profile.sort.includeBags = true

            local seen
            local realExec = GBL.ExecuteSortPlan
            GBL.ExecuteSortPlan = function(selfRef, plan, onComplete, opts)
                seen = opts
                return realExec(selfRef, plan, onComplete, opts)
            end
            GBL:RunSortExec()
            GBL.ExecuteSortPlan = realExec
            GBL:CancelSortExecution()

            assert.is_not_nil(seen, "RunSortExec never reached the executor")
            assert.is_true(seen.includeBags)
            assert.is_not_nil(seen.layout)
        end)

        it("does not set includeBags when the setting is off", function()
            installLayout(20)
            installEmptyScan()
            openBank(GBL)
            grantSortAccess()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 5 } })
            GBL.lastScanResults = {
                [1] = { slots = { [1] = {
                            itemLink = Helpers.makeItemLink(200, "Ore", 1),
                            count = 5, slotIndex = 1, tabIndex = 1 } },
                        itemCount = 1 },
                [2] = { slots = {}, itemCount = 0 },
            }

            local seen
            local realExec = GBL.ExecuteSortPlan
            GBL.ExecuteSortPlan = function(selfRef, plan, onComplete, opts)
                seen = opts
                return realExec(selfRef, plan, onComplete, opts)
            end
            GBL:RunSortExec()
            GBL.ExecuteSortPlan = realExec
            GBL:CancelSortExecution()

            assert.is_not_nil(seen, "RunSortExec never reached the executor")
            assert.is_falsy(seen.includeBags)
        end)
    end)

    -- PrintDeviations reads plan.demandMap and nothing else, and demandMap is
    -- derived purely from the layout. Bags cannot change it, so the command
    -- stays bank-only on purpose rather than by omission.
    describe("/gbl deviations", function()
        it("prints the same thing whether bags are on or off", function()
            installLayout(20)
            installEmptyScan()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })

            Helpers.clearPrints()
            GBL:PrintDeviations()
            local off = table.concat(MockWoW.prints, "\n")

            GBL.db.profile.sort.includeBags = true
            Helpers.clearPrints()
            GBL:PrintDeviations()
            local on = table.concat(MockWoW.prints, "\n")

            assert.equals(off, on)
        end)
    end)

    describe("Sort tab keyboard navigation", function()
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
            GBL:_SortView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
            GBL:_SortView_NavKey("TAB", false)
            assert.equals(2, GBL.A11Y.focusIndex)
            GBL:_SortView_NavKey("TAB", false)
            assert.equals(1, GBL.A11Y.focusIndex)
        end)

        it("Shift-TAB reverses and wraps", function()
            GBL.A11Y.focusIndex = 1
            GBL:_SortView_NavKey("TAB", true)
            assert.equals(2, GBL.A11Y.focusIndex)
        end)

        it("ENTER activates the focused widget", function()
            local fired = false
            b2.frame = b2.frame or {}
            b2:SetCallback("OnClick", function() fired = true end)
            GBL.A11Y.focusIndex = 2
            GBL:_SortView_ActivateFocused()
            assert.is_true(fired)
        end)

        it("ignores keys it does not handle", function()
            assert.is_false(GBL:_SortView_NavKey("ESCAPE", false))
        end)
    end)
end)
