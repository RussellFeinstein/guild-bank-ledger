------------------------------------------------------------------------
-- core_spec.lua — Tests for Core.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

describe("Core", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    describe("initialization", function()
        it("creates the addon without error", function()
            assert.is_not_nil(GBL)
            assert.equals("GuildBankLedger", GBL._name)
        end)

        it("creates AceDB with correct SavedVariables name", function()
            GBL:OnInitialize()
            assert.is_not_nil(MockAce.dbInstance)
            assert.equals("GuildBankLedgerDB", MockAce.dbInstance._svName)
        end)

        it("registers slash commands", function()
            GBL:OnInitialize()
            assert.is_not_nil(MockAce.registeredSlashCommands["gbl"])
            assert.is_not_nil(MockAce.registeredSlashCommands["guildbankledger"])
        end)
    end)

    describe("bank open/close detection", function()
        before_each(function()
            GBL:OnInitialize()
            MockWoW.guild.name = "Test Guild"
            GBL:OnEnable()
        end)

        it("detects guild bank open via correct event", function()
            assert.is_not_nil(MockAce.registeredEvents["PLAYER_INTERACTION_MANAGER_FRAME_SHOW"])
        end)

        it("sets bankOpen on GuildBanker interaction", function()
            assert.is_false(GBL:IsBankOpen())
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_true(GBL:IsBankOpen())
        end)

        it("ignores non-GuildBanker interaction types", function()
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 99)
            assert.is_false(GBL:IsBankOpen())
        end)

        it("sets bankOpen false on bank close", function()
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_true(GBL:IsBankOpen())

            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_false(GBL:IsBankOpen())
        end)

        it("marks bank open but does not scan when not in a guild", function()
            MockWoW.guild.name = nil
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            -- Bank frame is physically open
            assert.is_true(GBL:IsBankOpen())
            -- But no scan starts because guild name is nil
            assert.is_false(GBL.scanInProgress)
        end)
    end)

    describe("IsBankOpen", function()
        it("returns correct state", function()
            GBL:OnInitialize()
            assert.is_false(GBL:IsBankOpen())

            GBL.bankOpen = true
            assert.is_true(GBL:IsBankOpen())

            GBL.bankOpen = false
            assert.is_false(GBL:IsBankOpen())
        end)
    end)

    describe("GetGuildName", function()
        before_each(function()
            GBL:OnInitialize()
        end)

        it("returns nil when not in a guild", function()
            MockWoW.guild.name = nil
            assert.is_nil(GBL:GetGuildName())
        end)

        it("returns guild name when in a guild", function()
            MockWoW.guild.name = "Test Guild"
            assert.equals("Test Guild", GBL:GetGuildName())
        end)
    end)

    describe("slash commands", function()
        before_each(function()
            GBL:OnInitialize()
            Helpers.clearPrints()
        end)

        it("status prints version and guild info", function()
            MockWoW.guild.name = "Test Guild"
            GBL:HandleSlashCommand("status")
            assert.is_true(Helpers.printContains("0.7.1"))
            assert.is_true(Helpers.printContains("Test Guild"))
        end)

        it("help prints available commands", function()
            GBL:HandleSlashCommand("help")
            assert.is_true(Helpers.printContains("/gbl status"))
            assert.is_true(Helpers.printContains("/gbl scan"))
            assert.is_true(Helpers.printContains("/gbl help"))
        end)

        it("empty command calls ToggleMainFrame", function()
            local called = false
            local origToggle = GBL.ToggleMainFrame
            GBL.ToggleMainFrame = function() called = true end
            GBL:HandleSlashCommand("")
            GBL.ToggleMainFrame = origToggle
            assert.is_true(called)
        end)

        it("'show' command calls ToggleMainFrame", function()
            local called = false
            local origToggle = GBL.ToggleMainFrame
            GBL.ToggleMainFrame = function() called = true end
            GBL:HandleSlashCommand("show")
            GBL.ToggleMainFrame = origToggle
            assert.is_true(called)
        end)
    end)

    describe("minimap button", function()
        it("registers LibDataBroker data object on init", function()
            GBL:OnInitialize()
            local ldb = MockAce.ldb
            assert.is_not_nil(ldb._objects["GuildBankLedger"])
        end)

        it("registers with LibDBIcon on init", function()
            GBL:OnInitialize()
            local icon = MockAce.ldbIcon
            assert.is_not_nil(icon._registered["GuildBankLedger"])
        end)
    end)
end)
