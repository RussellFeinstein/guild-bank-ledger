------------------------------------------------------------------------
-- access_control_spec.lua — Tests for access control (rank gating)
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Access Control", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        MockWoW.guild.rankName = "Guild Master"
        MockWoW.guild.rankIndex = 0
        GBL:OnEnable()
    end)

    describe("IsGuildMaster", function()
        it("returns true for rank 0", function()
            MockWoW.guild.rankIndex = 0
            assert.is_true(GBL:IsGuildMaster())
        end)

        it("returns false for rank 1", function()
            MockWoW.guild.rankIndex = 1
            assert.is_false(GBL:IsGuildMaster())
        end)

        it("returns false for rank 5", function()
            MockWoW.guild.rankIndex = 5
            assert.is_false(GBL:IsGuildMaster())
        end)

        it("returns false when guild info is nil", function()
            MockWoW.guild.name = nil
            assert.is_false(GBL:IsGuildMaster())
        end)
    end)

    describe("GetAccessLevel", function()
        it("returns full when no accessControl is configured", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = { rankThreshold = nil }
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns full when accessControl table is absent", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = nil
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns full for GM regardless of threshold", function()
            MockWoW.guild.rankIndex = 0
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 0,
                restrictedMode = "sync_only",
            }
            -- GM with threshold 0 means "only GM has access",
            -- but GM always gets full
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns full for rank within threshold", function()
            MockWoW.guild.rankIndex = 2
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 3,
                restrictedMode = "sync_only",
            }
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns full for rank at exact threshold", function()
            MockWoW.guild.rankIndex = 3
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 3,
                restrictedMode = "sync_only",
            }
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns sync_only for rank below threshold", function()
            MockWoW.guild.rankIndex = 4
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
            }
            assert.equals("sync_only", GBL:GetAccessLevel())
        end)

        it("returns own_transactions for rank below threshold with that mode", function()
            MockWoW.guild.rankIndex = 3
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "own_transactions",
            }
            assert.equals("own_transactions", GBL:GetAccessLevel())
        end)

        it("defaults restricted mode to sync_only when nil", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = nil,
            }
            assert.equals("sync_only", GBL:GetAccessLevel())
        end)

        it("returns full when guild data is nil", function()
            -- No guild name → no guild data
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("returns full when rank info is unavailable", function()
            -- GetGuildInfo returns nil when roster hasn't loaded
            MockWoW.guild.name = nil
            MockWoW.guild.rankIndex = nil
            assert.equals("full", GBL:GetAccessLevel())
        end)
    end)

    describe("HasFullAccess", function()
        it("returns true when access level is full", function()
            MockWoW.guild.rankIndex = 0
            assert.is_true(GBL:HasFullAccess())
        end)

        it("returns false when access level is sync_only", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
            }
            assert.is_false(GBL:HasFullAccess())
        end)

        it("returns false when access level is own_transactions", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "own_transactions",
            }
            assert.is_false(GBL:HasFullAccess())
        end)
    end)

    describe("FilterByPlayer", function()
        it("filters records to the given player", function()
            local records = {
                { player = "Alice-Realm1", type = "deposit" },
                { player = "Bob-Realm1", type = "withdraw" },
                { player = "Alice-Realm1", type = "withdraw" },
                { player = "Charlie-Realm2", type = "deposit" },
            }
            local filtered = GBL:FilterByPlayer(records, "Alice")
            assert.equals(2, #filtered)
            assert.equals("Alice-Realm1", filtered[1].player)
            assert.equals("Alice-Realm1", filtered[2].player)
        end)

        it("returns empty table when no matches", function()
            local records = {
                { player = "Bob-Realm1", type = "withdraw" },
            }
            local filtered = GBL:FilterByPlayer(records, "Alice")
            assert.equals(0, #filtered)
        end)

        it("handles empty records array", function()
            local filtered = GBL:FilterByPlayer({}, "Alice")
            assert.equals(0, #filtered)
        end)
    end)

    describe("MigrateAccessControl", function()
        it("initializes accessControl on schema v6 data", function()
            local guildData = {
                schemaVersion = 6,
                transactions = {},
                moneyTransactions = {},
            }
            GBL:MigrateAccessControl(guildData)
            assert.equals(7, guildData.schemaVersion)
            assert.is_not_nil(guildData.accessControl)
            assert.is_nil(guildData.accessControl.rankThreshold)
            assert.is_nil(guildData.accessControl.restrictedMode)
            assert.equals(0, guildData.accessControl.configuredAt)
        end)

        it("does not overwrite existing accessControl", function()
            local guildData = {
                schemaVersion = 6,
                transactions = {},
                moneyTransactions = {},
                accessControl = {
                    rankThreshold = 2,
                    restrictedMode = "sync_only",
                    configuredBy = "GM-Realm",
                    configuredAt = 12345,
                },
            }
            GBL:MigrateAccessControl(guildData)
            assert.equals(7, guildData.schemaVersion)
            assert.equals(2, guildData.accessControl.rankThreshold)
            assert.equals("sync_only", guildData.accessControl.restrictedMode)
        end)

        it("is idempotent (no-op at schema v7)", function()
            local guildData = {
                schemaVersion = 7,
                accessControl = {
                    rankThreshold = 3,
                    restrictedMode = "own_transactions",
                    configuredBy = "GM-Realm",
                    configuredAt = 99999,
                },
            }
            GBL:MigrateAccessControl(guildData)
            assert.equals(7, guildData.schemaVersion)
            assert.equals(3, guildData.accessControl.rankThreshold)
        end)

        it("handles nil guildData", function()
            -- Should not error
            GBL:MigrateAccessControl(nil)
        end)
    end)
end)
