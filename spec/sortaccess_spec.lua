------------------------------------------------------------------------
-- sortaccess_spec.lua — Tests for HasSortAccess / SaveSortAccess helpers.
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

    describe("HasSortAccess", function()
        it("always returns true for the Guild Master (rank 0)", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:HasSortAccess())
        end)

        it("returns false by default for non-GMs (fresh install)", function()
            setPlayer("Member", "TestRealm", 5)
            assert.is_false(GBL:HasSortAccess())
        end)

        it("grants access when rank meets threshold", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({ rankThreshold = 2 }))
            setPlayer("Officer", "TestRealm", 2)
            assert.is_true(GBL:HasSortAccess())
            setPlayer("Member", "TestRealm", 3)
            assert.is_false(GBL:HasSortAccess())
        end)

        it("grants access to a named delegate regardless of rank", function()
            setPlayer("Gm", "TestRealm", 0)
            assert.is_true(GBL:SaveSortAccess({
                delegates = { ["Delegate-TestRealm"] = true },
            }))
            setPlayer("Delegate", "TestRealm", 9)  -- bottom rank
            assert.is_true(GBL:HasSortAccess())
            setPlayer("Someone", "TestRealm", 9)
            assert.is_false(GBL:HasSortAccess())
        end)

        it("combines rank + delegates (either path grants)", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess({
                rankThreshold = 1,
                delegates = { ["Friend-TestRealm"] = true },
            })
            setPlayer("Officer", "TestRealm", 1)
            assert.is_true(GBL:HasSortAccess())
            setPlayer("Friend", "TestRealm", 8)
            assert.is_true(GBL:HasSortAccess())
            setPlayer("Nobody", "TestRealm", 7)
            assert.is_false(GBL:HasSortAccess())
        end)
    end)

    describe("SaveSortAccess", function()
        it("rejects saves by non-GMs", function()
            setPlayer("Officer", "TestRealm", 1)
            local ok, err = GBL:SaveSortAccess({ rankThreshold = 5 })
            assert.is_false(ok)
            assert.matches("Guild Master", err)
        end)

        it("stamps updatedBy and updatedAt on save", function()
            setPlayer("Gm", "TestRealm", 0)
            MockWoW.serverTime = 9999
            assert.is_true(GBL:SaveSortAccess({ rankThreshold = 1 }))
            local sa = GBL:GetSortAccess()
            assert.equals(9999, sa.updatedAt)
            assert.equals("Gm-TestRealm", sa.updatedBy)
        end)

        it("increments changes independently (no version number, uses updatedAt)", function()
            setPlayer("Gm", "TestRealm", 0)
            MockWoW.serverTime = 100
            GBL:SaveSortAccess({ rankThreshold = 1 })
            MockWoW.serverTime = 200
            GBL:SaveSortAccess({ rankThreshold = 2 })
            assert.equals(200, GBL:GetSortAccess().updatedAt)
        end)

        it("returns a deep copy, never the live reference", function()
            setPlayer("Gm", "TestRealm", 0)
            GBL:SaveSortAccess({
                rankThreshold = 1,
                delegates = { ["A-Realm"] = true },
            })
            local a = GBL:GetSortAccess()
            a.delegates["B-Realm"] = true
            local b = GBL:GetSortAccess()
            assert.is_nil(b.delegates["B-Realm"],
                "mutating the returned copy must not affect storage")
        end)
    end)
end)
