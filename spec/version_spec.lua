------------------------------------------------------------------------
-- Tests for GBL:CompareSemver
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("CompareSemver", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
    end)

    it("returns 0 for equal versions", function()
        assert.equal(0, GBL:CompareSemver("1.2.3", "1.2.3"))
    end)

    it("returns 0 for identical zero versions", function()
        assert.equal(0, GBL:CompareSemver("0.0.0", "0.0.0"))
    end)

    it("returns -1 when a has lower major", function()
        assert.equal(-1, GBL:CompareSemver("0.9.0", "1.0.0"))
    end)

    it("returns 1 when a has higher major", function()
        assert.equal(1, GBL:CompareSemver("2.0.0", "1.9.9"))
    end)

    it("returns -1 when a has lower minor", function()
        assert.equal(-1, GBL:CompareSemver("1.2.0", "1.3.0"))
    end)

    it("returns 1 when a has higher minor", function()
        assert.equal(1, GBL:CompareSemver("1.3.0", "1.2.0"))
    end)

    it("returns -1 when a has lower patch", function()
        assert.equal(-1, GBL:CompareSemver("1.2.3", "1.2.4"))
    end)

    it("returns 1 when a has higher patch", function()
        assert.equal(1, GBL:CompareSemver("1.2.4", "1.2.3"))
    end)

    it("compares numerically, not lexicographically", function()
        assert.equal(-1, GBL:CompareSemver("0.9.0", "0.16.0"))
        assert.equal(1, GBL:CompareSemver("0.16.0", "0.9.0"))
    end)

    it("returns -1 when a is nil", function()
        assert.equal(-1, GBL:CompareSemver(nil, "1.0.0"))
    end)

    it("returns 1 when b is nil", function()
        assert.equal(1, GBL:CompareSemver("1.0.0", nil))
    end)

    it("returns 0 when both are nil", function()
        assert.equal(0, GBL:CompareSemver(nil, nil))
    end)

    it("returns -1 for malformed a", function()
        assert.equal(-1, GBL:CompareSemver("bad", "1.0.0"))
    end)

    it("returns 1 for malformed b", function()
        assert.equal(1, GBL:CompareSemver("1.0.0", "bad"))
    end)

    it("returns 0 for both malformed (equal strings)", function()
        assert.equal(0, GBL:CompareSemver("bad", "bad"))
    end)

    it("handles large version numbers", function()
        assert.equal(-1, GBL:CompareSemver("1.0.99", "1.1.0"))
        assert.equal(1, GBL:CompareSemver("10.0.0", "9.99.99"))
    end)
end)
