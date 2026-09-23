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

        -- The mode a GM gets by setting a threshold and choosing nothing is
        -- Member, not Sync only (#222, views doc section 6): the quiet
        -- default should be the one that still shows a member their own
        -- record. Display-side only; the stored and advertised values are
        -- unchanged, so an older client reads it as it always did.
        it("defaults restricted mode to own_transactions when nil", function()
            MockWoW.guild.rankIndex = 5
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = nil,
            }
            assert.equals("own_transactions", GBL:GetAccessLevel())
        end)

        -- Fail closed while the rank is cold (#222). GetGuildInfo answers no
        -- rank for the first seconds after login, and answering "full" there
        -- handed a member the whole ledger until the first roster tick ran
        -- RefreshAccessTabsIfChanged. The GM is caught by it too and gets the
        -- restricted view for those seconds, which is the cheaper mistake.
        it("returns the restricted mode when no rank has ever been read", function()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = nil
            GBL._lastKnownRank = nil
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 3,
                restrictedMode = "own_transactions",
            }
            assert.equals("own_transactions", GBL:GetAccessLevel())
        end)

        -- GetGuildInfo answers nothing at all for a few frames after a
        -- loading screen, and reading that as a change would flip the
        -- access-derived tab signature: RebuildTabs would collapse the tab
        -- list for a sync_only guild and park the player on the Sync tab
        -- with their filters gone, for a transient that told us nothing.
        it("keeps the level it last read through a momentary loss of rank", function()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = 2
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 3,
                restrictedMode = "sync_only",
            }
            assert.equals("full", GBL:GetAccessLevel())

            MockWoW.guild.rankIndex = nil
            assert.equals("full", GBL:GetAccessLevel())
        end)

        it("still follows a demotion, which arrives as a rank", function()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = 2
            local guildData = GBL:GetGuildData()
            guildData.accessControl = {
                rankThreshold = 3,
                restrictedMode = "own_transactions",
            }
            assert.equals("full", GBL:GetAccessLevel())

            MockWoW.guild.rankIndex = 5
            assert.equals("own_transactions", GBL:GetAccessLevel())
        end)

        it("stays full with no rank and no threshold configured", function()
            MockWoW.guild.name = "Test Guild"
            MockWoW.guild.rankIndex = nil
            local guildData = GBL:GetGuildData()
            guildData.accessControl = nil
            assert.equals("full", GBL:GetAccessLevel())
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

    -- FilterByPlayer and its three cases are gone with #222. It compared
    -- StripRealm(record.player) against the bare current name, so a
    -- same-named character on another realm passed and the member's own
    -- alts did not, and its only two callers were the pre-filter in
    -- SelectTab. The qualified comparison and the account's own rows are
    -- FilterToOwnRecords, covered in spec/ui/member_view_spec.lua along
    -- with the two paths that render through it.

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
