------------------------------------------------------------------------
-- spec/devbuild_spec.lua -- Tests for dev-build sync isolation
--
-- Tests cover the override layering (`self._testDevBuild`) without
-- depending on the file-level `local DEV_BUILD` value, so a dev who
-- flips DEV_BUILD on in Core.lua to dogfood the feature in-game does
-- not break the test suite. The CI workflow's `Verify DEV_BUILD is nil`
-- step is the production-state enforcer.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("Dev-build isolation", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    it("override layering: _testDevBuild produces the dev suffix", function()
        GBL._testDevBuild = "sync"
        assert.equals("0.30.5-dev.sync", GBL:GetSyncVersion())
        assert.is_true(GBL:IsDevBuild())
    end)

    it("override layering: clearing _testDevBuild reverts to file-level state", function()
        local baselineVersion = GBL:GetSyncVersion()
        local baselineIsDev = GBL:IsDevBuild()

        GBL._testDevBuild = "sync"
        assert.equals("0.30.5-dev.sync", GBL:GetSyncVersion())
        assert.is_true(GBL:IsDevBuild())

        GBL._testDevBuild = nil
        assert.equals(baselineVersion, GBL:GetSyncVersion())
        assert.equals(baselineIsDev, GBL:IsDevBuild())
    end)

    it("OnInitialize captures the dev-suffixed self.version", function()
        -- Override MUST be set before OnInitialize since self.version is
        -- captured at init time.
        GBL._testDevBuild = "sync"
        GBL:OnInitialize()
        assert.equals("0.30.5-dev.sync", GBL.version)
    end)

    it("dev suffix uses the override id verbatim", function()
        GBL._testDevBuild = "anything-goes-123"
        assert.equals("0.30.5-dev.anything-goes-123", GBL:GetSyncVersion())
    end)
end)
