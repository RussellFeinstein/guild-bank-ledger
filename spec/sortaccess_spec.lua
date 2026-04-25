------------------------------------------------------------------------
-- sortaccess_spec.lua — Tests for HasSortAccess / HasLayoutWrite /
-- SaveSortAccess / MigrateSortAccessShape helpers.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW

describe("Sort access policy", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
    end)

    local function setPlayer(name, realm, rankIndex)
        MockWoW.player.name = name
        MockWoW.player.realm = realm or "TestRealm"
        MockWoW.guild.rankIndex = rankIndex or 5
    end

    local function policy(writeTier, sortTier)
        return {
            write = writeTier or { rankThreshold = nil, delegates = {} },
            sort  = sortTier  or { rankThreshold = nil, delegates = {} },
        }
    end

    describe("HasLayoutWrite", function()
        it("always returns true for the Guild Master (rank 0)", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:HasLayoutWrite())
        end)

        it("returns false by default for non-GMs (fresh install)", function()
            setPlayer("Member", "TestRealm", 5)
            assert.is_false(GBL:HasLayoutWrite())
        end)

        it("grants when rank meets the write-tier threshold", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess(policy({ rankThreshold = 2 })))
            setPlayer("Officer", "TestRealm", 2)
            assert.is_true(GBL:HasLayoutWrite())
            setPlayer("Member", "TestRealm", 3)
            assert.is_false(GBL:HasLayoutWrite())
        end)

        it("grants to a write-tier delegate regardless of rank", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess(policy(
                { delegates = { ["Delegate-TestRealm"] = true } })))
            setPlayer("Delegate", "TestRealm", 9)
            assert.is_true(GBL:HasLayoutWrite())
        end)

        it("does NOT grant to a sort-only-tier delegate", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess(policy(
                nil,
                { delegates = { ["Sorter-TestRealm"] = true } })))
            setPlayer("Sorter", "TestRealm", 9)
            assert.is_false(GBL:HasLayoutWrite())
        end)

        it("does NOT grant on sort-tier rank match alone", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess(policy(
                nil,
                { rankThreshold = 3 })))
            setPlayer("Officer", "TestRealm", 3)
            assert.is_false(GBL:HasLayoutWrite())
        end)
    end)

    describe("HasSortAccess with split tiers", function()
        it("returns true for the Guild Master", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:HasSortAccess())
        end)

        it("write-tier delegate has sort access (write implies sort)", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy({ delegates = { ["W-TestRealm"] = true } }))
            setPlayer("W", "TestRealm", 9)
            assert.is_true(GBL:HasSortAccess())
            assert.is_true(GBL:HasLayoutWrite())
        end)

        it("write-tier rank has sort access", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy({ rankThreshold = 2 }))
            setPlayer("Officer", "TestRealm", 2)
            assert.is_true(GBL:HasSortAccess())
            assert.is_true(GBL:HasLayoutWrite())
        end)

        it("sort-tier delegate has sort access but not write", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy(
                nil,
                { delegates = { ["S-TestRealm"] = true } }))
            setPlayer("S", "TestRealm", 9)
            assert.is_true(GBL:HasSortAccess())
            assert.is_false(GBL:HasLayoutWrite())
        end)

        it("sort-tier rank has sort access but not write", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy(
                nil,
                { rankThreshold = 4 }))
            setPlayer("Member", "TestRealm", 4)
            assert.is_true(GBL:HasSortAccess())
            assert.is_false(GBL:HasLayoutWrite())
        end)

        it("outsider has neither", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy(
                { rankThreshold = 1 },
                { rankThreshold = 3 }))
            setPlayer("Nobody", "TestRealm", 7)
            assert.is_false(GBL:HasSortAccess())
            assert.is_false(GBL:HasLayoutWrite())
        end)
    end)

    describe("MigrateSortAccessShape", function()
        it("migrates a legacy flat table into the write tier", function()
            local guildData = {
                sortAccess = {
                    rankThreshold = 3,
                    delegates = { ["Alice-Realm"] = true, ["Bob-Realm"] = true },
                    updatedBy = "OldGm-Realm",
                    updatedAt = 1234,
                },
            }
            GBL:MigrateSortAccessShape(guildData)
            assert.equals(3, guildData.sortAccess.write.rankThreshold)
            assert.is_true(guildData.sortAccess.write.delegates["Alice-Realm"])
            assert.is_true(guildData.sortAccess.write.delegates["Bob-Realm"])
            assert.is_nil(guildData.sortAccess.sort.rankThreshold)
            assert.same({}, guildData.sortAccess.sort.delegates)
            assert.equals("OldGm-Realm", guildData.sortAccess.updatedBy)
            assert.equals(1234, guildData.sortAccess.updatedAt)
        end)

        it("is idempotent: migrating twice yields the same shape", function()
            local guildData = {
                sortAccess = {
                    rankThreshold = 2,
                    delegates = { ["X-Realm"] = true },
                },
            }
            GBL:MigrateSortAccessShape(guildData)
            local snapshot = {
                write = {
                    rankThreshold = guildData.sortAccess.write.rankThreshold,
                    delegates = {},
                },
                sort  = {
                    rankThreshold = guildData.sortAccess.sort.rankThreshold,
                    delegates = {},
                },
            }
            for k, v in pairs(guildData.sortAccess.write.delegates) do
                snapshot.write.delegates[k] = v
            end
            for k, v in pairs(guildData.sortAccess.sort.delegates) do
                snapshot.sort.delegates[k] = v
            end

            GBL:MigrateSortAccessShape(guildData)
            assert.equals(snapshot.write.rankThreshold, guildData.sortAccess.write.rankThreshold)
            assert.same(snapshot.write.delegates, guildData.sortAccess.write.delegates)
            assert.equals(snapshot.sort.rankThreshold, guildData.sortAccess.sort.rankThreshold)
            assert.same(snapshot.sort.delegates, guildData.sortAccess.sort.delegates)
        end)

        it("creates an empty two-tier skeleton for nil sortAccess", function()
            local guildData = { sortAccess = nil }
            GBL:MigrateSortAccessShape(guildData)
            assert.is_table(guildData.sortAccess.write)
            assert.is_table(guildData.sortAccess.sort)
            assert.is_nil(guildData.sortAccess.write.rankThreshold)
            assert.same({}, guildData.sortAccess.write.delegates)
            assert.is_nil(guildData.sortAccess.sort.rankThreshold)
            assert.same({}, guildData.sortAccess.sort.delegates)
        end)

        it("preserves an already-migrated two-tier table", function()
            local guildData = {
                sortAccess = {
                    write = { rankThreshold = 1, delegates = { ["W-R"] = true } },
                    sort  = { rankThreshold = 4, delegates = { ["S-R"] = true } },
                    updatedBy = "Gm-R",
                    updatedAt = 999,
                },
            }
            GBL:MigrateSortAccessShape(guildData)
            assert.equals(1, guildData.sortAccess.write.rankThreshold)
            assert.is_true(guildData.sortAccess.write.delegates["W-R"])
            assert.equals(4, guildData.sortAccess.sort.rankThreshold)
            assert.is_true(guildData.sortAccess.sort.delegates["S-R"])
            assert.equals("Gm-R", guildData.sortAccess.updatedBy)
            assert.equals(999, guildData.sortAccess.updatedAt)
        end)
    end)

    describe("SaveSortAccess", function()
        it("rejects saves by non-GMs", function()
            setPlayer("Officer", "TestRealm", 1)
            local ok, err = GBL:SaveSortAccess(policy({ rankThreshold = 5 }))
            assert.is_false(ok)
            assert.matches("Guild Master", err)
        end)

        it("rejects non-table policy", function()
            setPlayer("Gm", "TestRealm", 0)
            local ok, err = GBL:SaveSortAccess("nope")
            assert.is_false(ok)
            assert.matches("must be a table", err)
        end)

        it("rejects non-numeric rankThreshold in either tier", function()
            setPlayer("Gm", "TestRealm", 0)
            local ok, err = GBL:SaveSortAccess({
                write = { rankThreshold = "bad" },
                sort  = {},
            })
            assert.is_false(ok)
            assert.matches("write", err)
            assert.matches("number", err)

            local ok2, err2 = GBL:SaveSortAccess({
                write = {},
                sort  = { rankThreshold = {} },
            })
            assert.is_false(ok2)
            assert.matches("sort", err2)
        end)

        it("rejects non-table delegates", function()
            setPlayer("Gm", "TestRealm", 0)
            local ok, err = GBL:SaveSortAccess({
                write = { delegates = "bad" },
                sort  = {},
            })
            assert.is_false(ok)
            assert.matches("delegates", err)
        end)

        it("stamps updatedBy and updatedAt on save", function()
            setPlayer("Gm", "TestRealm", 0)
            MockWoW.serverTime = 9999
            assert.is_true(GBL:SaveSortAccess(policy({ rankThreshold = 1 })))
            local sa = GBL:GetSortAccess()
            assert.equals(9999, sa.updatedAt)
            assert.equals("Gm-TestRealm", sa.updatedBy)
        end)

        it("returns a deep copy, never the live reference", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess(policy(
                { rankThreshold = 1, delegates = { ["A-Realm"] = true } }))
            local a = GBL:GetSortAccess()
            a.write.delegates["B-Realm"] = true
            local b = GBL:GetSortAccess()
            assert.is_nil(b.write.delegates["B-Realm"],
                "mutating the returned copy must not affect storage")
        end)

        it("writes both tiers independently", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess({
                write = { rankThreshold = 1, delegates = { ["W-R"] = true } },
                sort  = { rankThreshold = 4, delegates = { ["S-R"] = true } },
            })
            local sa = GBL:GetSortAccess()
            assert.equals(1, sa.write.rankThreshold)
            assert.is_true(sa.write.delegates["W-R"])
            assert.equals(4, sa.sort.rankThreshold)
            assert.is_true(sa.sort.delegates["S-R"])
        end)
    end)
end)
