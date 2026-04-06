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

        it("does not open bank when not in a guild", function()
            MockWoW.guild.name = nil
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_false(GBL:IsBankOpen())
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
            assert.is_true(Helpers.printContains("0.2.0"))
            assert.is_true(Helpers.printContains("Test Guild"))
        end)

        it("help prints available commands", function()
            GBL:HandleSlashCommand("help")
            assert.is_true(Helpers.printContains("/gbl status"))
            assert.is_true(Helpers.printContains("/gbl scan"))
            assert.is_true(Helpers.printContains("/gbl help"))
        end)
    end)
end)
