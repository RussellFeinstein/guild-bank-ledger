------------------------------------------------------------------------
-- member_view_spec.lua - the Member view's own-rows filter (#222)
--
-- The guild's Own Transactions mode has been paper since v0.15.0.
-- SelectTab pre-filters the two record arrays and builds the tab from
-- them; RefreshUI, two calls later inside ToggleMainFrame and again on
-- every bank open, scan and sync receive, reassigns the unfiltered
-- arrays over them and re-renders. No spec rendered the mode, so the
-- defect shipped in every release since.
--
-- These cases build each history tab in the mode and assert three
-- things: the array the renderer was handed (_ledgerTransactions and
-- its two siblings), what the render path produced (_ledgerFiltered),
-- and the player cell of every row that reached the screen.
--
-- The mock AceGUI SelectTab is a no-op (#121), so the spec calls
-- GBL:SelectTab itself, the way RebuildTabs does in the client.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Member view (own_transactions)", function()
    local GBL

    local ME = "TestOfficer-TestRealm"
    local ALT = "TestAlt-TestRealm"
    local FOREIGN = "Fluphie-TestRealm"
    local TWIN = "TestOfficer-OtherRealm"   -- same name, another realm: not us

    -- Every label rendered into the container, at any depth. The player
    -- cell is one of them, so a foreign name on screen shows up here.
    local function renderedLabels(container)
        local seen = {}
        local function walk(node)
            for _, c in ipairs(node._children or {}) do
                if c._type == "Label" and c._text then seen[c._text] = true end
                walk(c)
            end
        end
        walk(container)
        return seen
    end

    -- name -> true for every record in an array.
    local function playersIn(records)
        local seen = {}
        for _, r in ipairs(records or {}) do seen[r.player] = true end
        return seen
    end

    local function record(player, offsetHours, itemID)
        return {
            id = player .. ":" .. tostring(offsetHours),
            timestamp = MockWoW.serverTime - (offsetHours * 3600),
            player = player,
            type = "deposit",
            itemID = itemID or 111,
            itemLink = "[Test Item]",
            count = 1,
            tab = 1,
        }
    end

    local function moneyRecord(player, offsetHours)
        return {
            id = player .. ":money:" .. tostring(offsetHours),
            timestamp = MockWoW.serverTime - (offsetHours * 3600),
            player = player,
            type = "deposit",
            amount = 10000,
        }
    end

    -- A guild in Own Transactions mode with the player below the
    -- threshold, four item rows and two money rows, and an account
    -- roster holding this character and one alt.
    local function memberFixture()
        MockWoW.guild.name = "Test Guild"
        MockWoW.player.name = "TestOfficer"
        MockWoW.player.realm = "TestRealm"
        MockWoW.guild.rankIndex = 5

        local gd = GBL:GetGuildData()
        gd.accessControl = {
            rankThreshold = 3,
            restrictedMode = "own_transactions",
        }
        gd.transactions = {
            record(ME, 1), record(FOREIGN, 2), record(TWIN, 3), record(ALT, 4),
        }
        gd.moneyTransactions = {
            moneyRecord(ME, 1), moneyRecord(FOREIGN, 2),
        }
        GBL.db.global.characters = {
            [ME] = MockWoW.serverTime,
            [ALT] = MockWoW.serverTime,
        }
        return gd
    end

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    describe("RefreshUI", function()
        it("hands the renderer the account's rows only, not the whole guild's", function()
            memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            -- This is the call ToggleMainFrame makes straight after the
            -- build, and it is the line the defect lives on.
            GBL:RefreshUI()

            local handed = playersIn(GBL._ledgerTransactions)
            assert.is_true(handed[ME], "the member's own row should survive RefreshUI")
            assert.is_true(handed[ALT], "the member's alt is the same account")
            assert.is_nil(handed[FOREIGN], "another member's row reached the renderer")
            assert.is_nil(handed[TWIN], "a same-named character on another realm is not us")
        end)

        it("keeps them filtered across repeated refreshes", function()
            memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            GBL:RefreshUI()
            GBL:RefreshUI()

            local handed = playersIn(GBL._ledgerTransactions)
            assert.is_nil(handed[FOREIGN])
            assert.equals(2, #GBL._ledgerTransactions)
        end)

        it("renders no other member's row on screen", function()
            memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            GBL:RefreshUI()

            local rendered = renderedLabels(GBL.tabGroup)
            assert.is_true(rendered[ME], "the member's own row should be on screen")
            assert.is_true(rendered[ALT])
            assert.is_nil(rendered[FOREIGN], "another member's row was rendered")
            assert.is_nil(rendered[TWIN])
            -- What the render path itself produced, not just its input.
            assert.equals(2, #(GBL._ledgerFiltered or {}))
        end)

        it("filters the gold log the same way", function()
            memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("goldlog")
            GBL:RefreshUI()

            local handed = playersIn(GBL._goldLogTransactions)
            assert.is_true(handed[ME])
            assert.is_nil(handed[FOREIGN])
        end)

        it("filters consumption, which merges both arrays", function()
            memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("consumption")
            GBL:RefreshUI()

            local handed = playersIn(GBL._consumptionTransactions)
            assert.is_true(handed[ME])
            assert.is_true(handed[ALT])
            assert.is_nil(handed[FOREIGN])
            assert.is_nil(handed[TWIN])
        end)

        it("does not put another member's row back when a sync receive arrives", function()
            local gd = memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            GBL:RefreshUI()

            -- What a received chunk does: append to the guild's array, then
            -- refresh the open tab (src/Sync.lua:3629).
            gd.transactions[#gd.transactions + 1] = record(FOREIGN, 5)
            GBL:RefreshUI()

            local handed = playersIn(GBL._ledgerTransactions)
            assert.is_nil(handed[FOREIGN])
            assert.equals(2, #GBL._ledgerTransactions)
        end)

        it("filters nothing for a full-access user", function()
            memberFixture()
            local gd = GBL:GetGuildData()
            gd.accessControl = nil
            MockWoW.guild.rankIndex = 0
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            GBL:RefreshUI()

            local handed = playersIn(GBL._ledgerTransactions)
            assert.is_true(handed[ME])
            assert.is_true(handed[FOREIGN])
            assert.is_true(handed[TWIN])
            assert.equals(4, #GBL._ledgerTransactions)
        end)
    end)

    describe("FilterToOwnRecords", function()
        it("matches on the qualified name, not the bare one", function()
            memberFixture()
            local kept = GBL:FilterToOwnRecords({
                record(ME, 1), record(TWIN, 2), record(FOREIGN, 3),
            })

            assert.equals(1, #kept)
            assert.equals(ME, kept[1].player)
        end)

        it("resolves a bare-name record through the guild's roster cache", function()
            memberFixture()
            local gd = GBL:GetGuildData()
            gd.playerRealms = { TestOfficer = "TestRealm", Fluphie = "TestRealm" }

            local kept = GBL:FilterToOwnRecords({
                { player = "TestOfficer", type = "deposit" },
                { player = "Fluphie", type = "deposit" },
            })

            assert.equals(1, #kept)
            assert.equals("TestOfficer", kept[1].player)
        end)

        it("keeps every character on the account", function()
            memberFixture()
            local kept = GBL:FilterToOwnRecords({ record(ALT, 1), record(ME, 2) })
            assert.equals(2, #kept)
        end)

        it("returns an empty array when nothing matches", function()
            memberFixture()
            assert.equals(0, #GBL:FilterToOwnRecords({ record(FOREIGN, 1) }))
            assert.equals(0, #GBL:FilterToOwnRecords({}))
        end)

        it("counts the logged-in character even before the roster is written", function()
            memberFixture()
            GBL.db.global.characters = {}
            local kept = GBL:FilterToOwnRecords({ record(ME, 1), record(FOREIGN, 2) })

            assert.equals(1, #kept)
            assert.equals(ME, kept[1].player)
        end)

        -- The resolver falls back to the local realm for a bare name the
        -- roster marks ambiguous (playerRealms[name] = false, two characters
        -- of that name on connected realms), so both the viewer's name and a
        -- stranger's resolve to the same string. Under a promise that the
        -- addon shows nobody else's rows, that has to fail closed.
        it("does not claim a bare name the roster marks ambiguous", function()
            memberFixture()
            local gd = GBL:GetGuildData()
            gd.playerRealms = { TestOfficer = false }

            local kept = GBL:FilterToOwnRecords({ { player = "TestOfficer", type = "deposit" } })

            assert.equals(0, #kept)
        end)

        it("claims nothing while the realm APIs are cold", function()
            memberFixture()
            GBL.db.global.characters = {}
            MockWoW.player.realm = nil
            MockWoW.player.normalizedRealm = nil
            local gd = GBL:GetGuildData()
            gd.playerRealms = {}

            -- ResolvePlayerName would key the player as Name-UnknownRealm,
            -- which matches no record, so the set must not carry it.
            local own = GBL:GetOwnCharacterNames()
            assert.is_nil(own["TestOfficer-UnknownRealm"])
            assert.equals(0, #GBL:FilterToOwnRecords({ record(ME, 1) }))
        end)
    end)

    describe("RecordsForView", function()
        it("hands a sync_only client nothing", function()
            local gd = memberFixture()
            gd.accessControl = { rankThreshold = 3, restrictedMode = "sync_only" }

            local tx, money = GBL:RecordsForView(gd)

            assert.equals(0, #tx)
            assert.equals(0, #money)
        end)
    end)

    -- The filter widgets re-render the tab from an array captured when the
    -- tab was built. In this mode that array is a snapshot the next refresh
    -- replaces, so a row that arrived since the build disappeared the moment
    -- the member touched a filter. For a full-access user the captured array
    -- is the live guild table, which is why nothing showed it.
    describe("filter widgets after a refresh", function()
        local function findWidget(node, wtype, label)
            for _, c in ipairs(node._children or {}) do
                if c._type == wtype and (label == nil or c._label == label) then return c end
                local nested = findWidget(c, wtype, label)
                if nested then return nested end
            end
            return nil
        end

        it("re-renders the ledger from the rows that arrived since the build", function()
            local gd = memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("transactions")
            GBL:RefreshUI()
            assert.equals(2, #GBL._ledgerFiltered)

            gd.transactions[#gd.transactions + 1] = record(ALT, 6)
            GBL:RefreshUI()
            assert.equals(3, #GBL._ledgerFiltered)

            local search = findWidget(GBL.tabGroup, "EditBox", "Search")
            assert.is_not_nil(search)
            search:Fire("OnEnterPressed", "")

            assert.equals(3, #GBL._ledgerFiltered)
        end)

        it("re-renders the gold log from the rows that arrived since the build", function()
            local gd = memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("goldlog")
            GBL:RefreshUI()

            gd.moneyTransactions[#gd.moneyTransactions + 1] = moneyRecord(ALT, 6)
            GBL:RefreshUI()

            local handed
            local orig = GBL.RenderGoldLog
            GBL.RenderGoldLog = function(self, c, records, filters)
                handed = records
                return orig(self, c, records, filters)
            end
            local search = findWidget(GBL.tabGroup, "EditBox", "Search")
            assert.is_not_nil(search)
            search:Fire("OnEnterPressed", "")
            GBL.RenderGoldLog = orig

            assert.equals(2, #handed)
        end)

        it("re-renders consumption from the rows that arrived since the build", function()
            local gd = memberFixture()
            GBL:CreateMainFrame()
            GBL:SelectTab("consumption")
            GBL:RefreshUI()

            gd.transactions[#gd.transactions + 1] = record(ALT, 6)
            GBL:RefreshUI()

            local handed
            local orig = GBL.RenderConsumptionDashboard
            GBL.RenderConsumptionDashboard = function(self, c, records, filters)
                handed = records
                return orig(self, c, records, filters)
            end
            local cat = findWidget(GBL.tabGroup, "Dropdown", "Category")
            assert.is_not_nil(cat)
            cat:Fire("OnValueChanged", "ALL")
            GBL.RenderConsumptionDashboard = orig

            -- Three item rows plus the one money row the member owns.
            assert.equals(4, #handed)
        end)
    end)
end)
