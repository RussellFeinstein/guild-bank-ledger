------------------------------------------------------------------------
-- tab_switch_spec.lua - the tab-switch paths (#121)
--
-- Five production sites hand a tab value to the AceGUI TabGroup and
-- expect its OnGroupSelected to come back and build that tab:
-- RebuildTabs selecting the default tab (UI/UI.lua), RefreshUI's
-- "not built yet" branch, the Consumption player link switching to
-- Transactions, OpenRestockTab (UI/RestockView.lua), and the Layout
-- tab's inner TabGroup building its own content (UI/LayoutEditor.lua).
-- None of them had ever run in a spec, because the mock's SelectTab
-- recorded the value and fanned out to nothing.
--
-- Every case asserts on something the build rendered rather than on a
-- flag the switch set, so a mock that records without building cannot
-- satisfy them, and the needles are tab-unique: "Reset Filters" is
-- CreateFilterWidgets and nothing else, while a bare "Search" box is
-- also in the Gold Log and a "Gold:" line is also in Consumption.
--
-- The tab list matters: real SelectTab fires only when the value
-- matches a tab the group currently holds (AceGUI-3.0 TabGroup,
-- "if found then"), and BuildTabs hides the frames past a shrunken
-- list without clearing their value, so the "not in the bar" case uses
-- a member whose bar never held a Layout tab rather than a user
-- demoted out of one.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Tab switching through the TabGroup", function()
    local GBL

    -- Every widget in the tree, depth first.
    local function walk(node, visit)
        for _, child in ipairs(node._children or {}) do
            visit(child)
            walk(child, visit)
        end
    end

    -- True when any widget's text carries the needle (plain find). Reads
    -- the FontString as well as the widget: production sets some cells
    -- through `lbl.label:SetText(...)`, which the mock records there.
    local function rendersText(container, needle)
        local found = false
        walk(container, function(w)
            if found then return end
            local own = type(w._text) == "string" and w._text or ""
            local inner = w.label and type(w.label._text) == "string" and w.label._text or ""
            if own:find(needle, 1, true) or inner:find(needle, 1, true) then
                found = true
            end
        end)
        return found
    end

    local function widgetWithText(container, wtype, text)
        local hit
        walk(container, function(w)
            if not hit and w._type == wtype and w._text == text then hit = w end
        end)
        return hit
    end

    local function widgetWithLabel(container, wtype, label)
        local hit
        walk(container, function(w)
            if not hit and w._type == wtype and w._label == label then hit = w end
        end)
        return hit
    end

    -- value -> true for the tabs currently in the bar.
    local function tabSet()
        local vals = {}
        for _, t in ipairs(GBL.tabGroup._tabs or {}) do vals[t.value] = true end
        return vals
    end

    -- The Transactions tab is the one every access tier opens on. Its
    -- Reset button is the only "Reset Filters" in the addon; the Gold Log's
    -- reads "Reset", and both tabs carry a Search box.
    local function transactionsRendered()
        return widgetWithText(GBL.tabGroup, "Button", "Reset Filters") ~= nil
    end

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankIndex = 0   -- GM: every tab in the bar
        GBL:OnEnable()
    end)

    it("builds the default tab when the window is created", function()
        GBL:CreateMainFrame()

        assert.equals("transactions", GBL.activeTab)
        assert.is_true(transactionsRendered(),
            "RebuildTabs selects the default tab and nothing built it")
    end)

    it("builds the Layout tab when the group selects it", function()
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("layout")

        assert.equals("layout", GBL.activeTab)
        assert.is_true(rendersText(GBL.tabGroup, "Layout-write access:"),
            "the Layout tab's access banner is not on screen")
    end)

    it("builds the inner Layout tab's own content", function()
        -- UI/LayoutEditor.lua ends BuildLayoutTab with innerTG:SelectTab,
        -- and the inner OnGroupSelected is the only thing that renders a
        -- bank tab's editor. Two fan-outs deep, which is the shape the
        -- smoke-test gap was named for.
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("layout")

        local heading
        walk(GBL.tabGroup, function(w)
            if not heading and w._type == "Heading"
                and type(w._text) == "string" and w._text:find("Tab 1", 1, true) then
                heading = w
            end
        end)
        assert.is_not_nil(heading, "the inner tab's per-tab heading never rendered")
    end)

    it("builds the Sort tab when the group selects it", function()
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("sort")

        assert.equals("sort", GBL.activeTab)
        assert.is_not_nil(widgetWithText(GBL.tabGroup, "Button", "Preview"),
            "the Sort tab's Preview button is not on screen")
    end)

    it("opens the window on the Restock tab from OpenRestockTab", function()
        GBL:OpenRestockTab()

        assert.equals("restock", GBL.activeTab)
        -- The window has to be on screen: this is the /gbl restock entry,
        -- and the Show is also what makes SelectTab's closing
        -- _restockInView read true, which the wallet baseline depends on.
        assert.is_true(GBL:IsMainFrameShown(), "the window was never shown")
        assert.is_true(GBL._restockInView)
        assert.is_true(rendersText(GBL.tabGroup, "Budget:"),
            "the Restock tab's budget row is not on screen")
    end)

    it("switches to Transactions when a consumption row's player is clicked", function()
        local gd = GBL:GetGuildData()
        gd.transactions = {
            {
                id = "Fluphie:1",
                timestamp = MockWoW.serverTime - 3600,
                player = "Fluphie-TestRealm",
                type = "withdraw",
                itemID = 111,
                itemLink = "[Test Item]",
                count = 2,
                tab = 1,
            },
        }

        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("consumption")

        local link = widgetWithText(GBL.tabGroup, "InteractiveLabel", "Fluphie-TestRealm")
        assert.is_not_nil(link, "the consumption player cell never rendered")

        link:Fire("OnClick")

        assert.equals("transactions", GBL.activeTab)
        assert.is_true(transactionsRendered(),
            "the player link switched tabs without building Transactions")
        -- The click parks the name on _pendingSearchText and the build
        -- consumes it into the filters, so the rendered box is where the
        -- cross-tab navigation actually shows up (UI/UI.lua).
        local search = widgetWithLabel(GBL.tabGroup, "EditBox", "Search")
        assert.is_not_nil(search)
        assert.equals("Fluphie-TestRealm", search._text)
    end)

    it("builds a tab RefreshUI finds unbuilt", function()
        -- RefreshUI's three per-tab branches all need their container, and
        -- everything else falls to a full rebuild through the group. That
        -- branch runs on every bank open, storing scan and sync receive.
        GBL:CreateMainFrame()
        GBL.activeTab = "sync"

        GBL:RefreshUI()

        assert.is_not_nil(widgetWithText(GBL.tabGroup, "Button", "Broadcast Hello"),
            "RefreshUI left the Sync tab unbuilt")
    end)

    it("hides the tab buttons a shrunken bar no longer uses", function()
        -- BuildTabs hides the frames past the new list rather than dropping
        -- them, and it leaves their value on them, so SelectTab can still
        -- match one. That is the library's behaviour and the mock keeps it;
        -- what a shrink must not do is leave the retired buttons on screen.
        GBL:CreateMainFrame()
        local wide = #GBL.tabGroup._tabs

        MockWoW.player.name = "Member"
        MockWoW.guild.rankIndex = 5
        GBL:RebuildTabs()

        local narrow = #GBL.tabGroup._tabs
        assert.is_true(narrow < wide, "precondition: the member's bar is shorter")

        local shown = 0
        for _, t in ipairs(GBL.tabGroup.tabs) do
            if t:IsShown() then shown = shown + 1 end
        end
        assert.equals(narrow, shown)
    end)

    it("moves a demoted player off a tab their rank lost", function()
        -- RebuildTabs validates activeTab against the new list. Without
        -- that check the stale hidden frame still matches, so a demoted
        -- officer keeps the whole template editor on screen.
        GBL:CreateMainFrame()
        GBL.tabGroup:SelectTab("layout")
        assert.equals("layout", GBL.activeTab, "precondition: sitting on Layout")

        MockWoW.player.name = "Member"
        MockWoW.guild.rankIndex = 5
        GBL:RebuildTabs()

        assert.is_nil(tabSet().layout, "precondition: the member has no Layout tab")
        assert.equals("transactions", GBL.activeTab)
        assert.is_false(rendersText(GBL.tabGroup, "Layout-write access:"),
            "the Layout editor survived the demotion")
    end)

    it("builds nothing for a value the tab bar does not hold", function()
        -- A member has no Layout tab, so the value matches nothing and
        -- real AceGUI fires no callback at all. The window stays where
        -- it was rather than rendering a tab this rank cannot have.
        MockWoW.player.name = "Member"
        MockWoW.guild.rankIndex = 5
        GBL:CreateMainFrame()
        assert.is_nil(tabSet().layout, "precondition: this rank has no Layout tab")

        GBL.tabGroup:SelectTab("layout")

        assert.equals("transactions", GBL.activeTab)
        assert.is_false(rendersText(GBL.tabGroup, "Layout-write access:"))
        assert.is_true(transactionsRendered(), "the tab that was showing went away")
    end)

    it("records a refused selection without building it", function()
        -- _selectedTab is written above the guard, like the library's own
        -- status.selected, so it names the last value handed in rather than
        -- the last tab built. Anything proving a tab opened reads activeTab.
        MockWoW.player.name = "Member"
        MockWoW.guild.rankIndex = 5
        GBL:CreateMainFrame()

        GBL.tabGroup:SelectTab("layout")

        assert.equals("layout", GBL.tabGroup._selectedTab)
        assert.equals("transactions", GBL.activeTab)
    end)

    ------------------------------------------------------------------------
    -- OpenRestockTab against the bar (#244)
    --
    -- The /gbl restock entry gates on HasSortAccess and then hands the
    -- group a literal, so the tab bar never gets a say. The two access
    -- families are independent (docs/PLAN-views-and-access.md section 3):
    -- the view family decides the tab set and the bank family decides the
    -- bank tools, so a guild can leave a rank in sync_only while it still
    -- holds sort access. That is legal configuration and it is the
    -- arrangement these cases use.
    --
    -- Two different failures come out of it, which is why there are two
    -- refusal cases. A bar that SHRANK out of Restock keeps a hidden frame
    -- carrying the value, so the literal matches and the whole tab renders
    -- under the restricted banner. A bar that NEVER held it matches
    -- nothing, so the window silently stays where it was and the player is
    -- told nothing at all.
    ------------------------------------------------------------------------

    -- A rank the guild put in sync_only that still holds sort access.
    local function syncOnlyWithSortAccess()
        local gd = GBL:GetGuildData()
        gd.accessControl = { rankThreshold = 1, restrictedMode = "sync_only" }
        gd.sortAccess = {
            write = { rankThreshold = nil, delegates = {} },
            sort  = { rankThreshold = 9, delegates = {} },
            updatedAt = 100,
        }
        MockWoW.player.name = "Hand"
        MockWoW.guild.rankIndex = 5
    end

    it("refuses /gbl restock when the rank's bar lost the Restock tab", function()
        -- The window came up wide, so every tab frame exists. Access
        -- control then puts this rank in sync_only: RebuildTabs builds the
        -- three-tab bar and moves activeTab to sync, but BuildTabs only
        -- hides the surplus frames and leaves their value on them.
        GBL:CreateMainFrame()
        assert.is_true(tabSet().restock, "precondition: the bar came up wide")

        syncOnlyWithSortAccess()
        GBL:RebuildTabs()
        assert.is_nil(tabSet().restock, "precondition: the bar lost Restock")
        assert.equals("sync", GBL.activeTab, "precondition: parked on Sync")

        GBL:OpenRestockTab()

        assert.equals("sync", GBL.activeTab)
        assert.is_false(rendersText(GBL.tabGroup, "Budget:"),
            "the Restock tab rendered for a rank whose bar does not hold it")
        assert.is_true(Helpers.printContains("not one of the tabs"))
    end)

    it("says so when the bar never held Restock, rather than doing nothing", function()
        -- No stale frame here: the bar is built narrow from the start, so
        -- the value matches nothing and today the click is a silent no-op.
        syncOnlyWithSortAccess()
        GBL:CreateMainFrame()
        assert.is_nil(tabSet().restock, "precondition: the bar came up narrow")
        assert.equals("sync", GBL.activeTab)

        GBL:OpenRestockTab()

        assert.equals("sync", GBL.activeTab)
        assert.is_true(Helpers.printContains("not one of the tabs"),
            "the command did nothing and said nothing")
    end)

    it("opens no window at all when the rank cannot reach Restock", function()
        -- The sort-access refusal above it opens nothing either, so the two
        -- refusals behave alike from the player's side.
        syncOnlyWithSortAccess()

        GBL:OpenRestockTab()

        assert.is_nil(GBL.tabGroup, "a refused /gbl restock opened the window")
        assert.is_true(Helpers.printContains("not one of the tabs"))
    end)

    it("opens a cold window onto Restock without building Transactions", function()
        -- CreateMainFrame's RebuildTabs builds whatever activeTab holds, so
        -- /gbl restock on a closed window rendered the whole
        -- virtual-scrolling ledger and released it on the next line. The
        -- in-view flag rides on the same change: SelectTab closes with
        -- `(tabName == "restock") and IsMainFrameShown()`, and
        -- CreateMainFrame hides the frame before RebuildTabs, so a tab
        -- built in there is built hidden and the flag has to be put right
        -- once the window is up. A false flag moves the wallet baseline
        -- again on the next refresh, inside the purchase lag (#60).
        local built = {}
        for _, name in ipairs({ "BuildTransactionsTab", "BuildRestockTab" }) do
            local orig = GBL[name]
            GBL[name] = function(gbl, ...)
                built[name] = (built[name] or 0) + 1
                return orig(gbl, ...)
            end
        end

        GBL:OpenRestockTab()

        assert.equals("restock", GBL.activeTab)
        assert.equals(1, built.BuildRestockTab or 0)
        assert.equals(0, built.BuildTransactionsTab or 0,
            "the cold open built the ledger and threw it away")
        assert.is_true(GBL._restockInView,
            "the window is up on Restock and the in-view flag says otherwise")
    end)
end)
