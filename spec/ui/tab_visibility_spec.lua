------------------------------------------------------------------------
-- tab_visibility_spec.lua — Access-gated tab visibility (Sort/Layout).
--
-- Sort tab is gated on HasSortAccess (execute-only or write tier); the
-- Layout tab is gated on HasLayoutWrite, so sort-only users do not see it.
-- RefreshAccessTabsIfChanged rebuilds the tab bar when the roster/rank
-- warms (cold-roster login) or a grant arrives, but only on a real change.
--
-- Assertions inspect tabGroup._tabs (what SetTabs stored) rather than the
-- rendered tab buttons, so they do not depend on the no-op mock SelectTab.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Access-gated tab visibility", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    local function setPlayer(name, realm, rankIndex)
        MockWoW.guild.name = "Test Guild"
        MockWoW.player.name = name
        MockWoW.player.realm = realm or "TestRealm"
        MockWoW.guild.rankIndex = rankIndex or 5
    end

    local function grant(tier, rankThreshold)
        local gd = GBL:GetGuildData()
        gd.sortAccess = {
            write = { rankThreshold = nil, delegates = {} },
            sort  = { rankThreshold = nil, delegates = {} },
            updatedAt = 100,
        }
        gd.sortAccess[tier].rankThreshold = rankThreshold
    end

    -- value -> true for every tab currently in the tab bar.
    local function tabSet()
        local vals = {}
        for _, t in ipairs(GBL.tabGroup._tabs or {}) do vals[t.value] = true end
        return vals
    end

    describe("RebuildTabs", function()
        it("hides Sort and Layout from a member with no sort access", function()
            setPlayer("Member", "TestRealm", 5)
            GBL:CreateMainFrame()
            GBL:RebuildTabs()

            local v = tabSet()
            assert.is_true(v.transactions, "expected the full (non sync_only) tab set")
            assert.is_nil(v.sort)
            assert.is_nil(v.restock)
            assert.is_nil(v.layout)
        end)

        it("shows Sort but not Layout for a sort-only user", function()
            setPlayer("Officer", "TestRealm", 4)
            grant("sort", 4)  -- sort tier to rank<=4, write tier still GM-only
            GBL:CreateMainFrame()
            GBL:RebuildTabs()

            local v = tabSet()
            assert.is_true(v.sort)
            assert.is_true(v.restock)
            assert.is_nil(v.layout)
        end)

        it("shows both Sort and Layout for a layout-write user", function()
            setPlayer("Officer", "TestRealm", 2)
            grant("write", 2)  -- write tier to rank<=2 (implies sort)
            GBL:CreateMainFrame()
            GBL:RebuildTabs()

            local v = tabSet()
            assert.is_true(v.sort)
            assert.is_true(v.restock)
            assert.is_true(v.layout)
        end)

        it("shows both tabs for the Guild Master", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:CreateMainFrame()
            GBL:RebuildTabs()

            local v = tabSet()
            assert.is_true(v.sort)
            assert.is_true(v.restock)
            assert.is_true(v.layout)
        end)
    end)

    describe("RefreshAccessTabsIfChanged", function()
        it("does not rebuild when the access-gated set is unchanged", function()
            setPlayer("Member", "TestRealm", 5)
            GBL:CreateMainFrame()  -- stores the current access signature

            local calls = 0
            local orig = GBL.RebuildTabs
            GBL.RebuildTabs = function(s) calls = calls + 1; return orig(s) end
            GBL:RefreshAccessTabsIfChanged()
            GBL.RebuildTabs = orig

            assert.equals(0, calls)
        end)

        it("rebuilds and reveals the Sort tab when a grant arrives", function()
            setPlayer("Officer", "TestRealm", 4)
            GBL:CreateMainFrame()
            assert.is_nil(tabSet().sort, "precondition: no sort access yet")

            -- Simulate a synced grant / roster warm making HasSortAccess true.
            grant("sort", 4)
            GBL:RefreshAccessTabsIfChanged()

            assert.is_true(tabSet().sort)
            assert.is_true(tabSet().restock)
        end)

        it("no-ops safely when the window was never opened", function()
            setPlayer("Member", "TestRealm", 5)
            -- No CreateMainFrame: tabGroup is nil.
            assert.has_no.errors(function() GBL:RefreshAccessTabsIfChanged() end)
        end)
    end)

    describe("_SortNoLayoutMessage", function()
        it("tells layout-write users to open the Layout tab", function()
            setPlayer("Gm", "TestRealm", 0)  -- GM has layout write
            local msg = GBL:_SortNoLayoutMessage()
            assert.is_truthy(msg:find("Open the Layout tab", 1, true))
        end)

        it("tells sort-only / no-access users to ask an officer", function()
            setPlayer("Member", "TestRealm", 5)  -- no layout write
            local msg = GBL:_SortNoLayoutMessage()
            assert.is_truthy(msg:find("Ask a guild officer", 1, true))
        end)
    end)
end)
