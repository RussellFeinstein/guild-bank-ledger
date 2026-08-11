------------------------------------------------------------------------
-- syncstatus_tag_spec.lua — Peer-list version tag (_PeerVersionTag).
--
-- Three states since the v0.37.0 sync floor: a refused peer gets a
-- warning colour, a compatible peer on a different version gets a quiet
-- note, and a same-version peer gets no tag. The compatible-older note
-- must NOT render grey (a0a0a0): grey is the inactive colour used for
-- roster-only text and dev-build rows, and a compatible peer is syncing.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("Peer version tag", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    -- Versions derived relative to the runtime version so stamp commits
    -- change nothing here (see the 2026-05-05 version-literal lesson).
    local function olderVersion() return "0.1.0" end
    local function newerVersion(v)
        local major = tonumber(v:match("^(%d+)")) or 0
        return (major + 1) .. ".0.0"
    end

    it("tags a refused newer peer as needing a local update", function()
        local tag = GBL:_PeerVersionTag(
            { outdated = true, versionRelation = "local_behind" },
            newerVersion(GBL.version))
        assert.is_truthy(tag:find("update to sync", 1, true))
        assert.is_truthy(tag:find("|cff44aaff", 1, true))
    end)

    it("tags a refused older peer as too old, in warning colour", function()
        local tag = GBL:_PeerVersionTag(
            { outdated = true, versionRelation = "peer_behind" },
            olderVersion())
        assert.is_truthy(tag:find("too old", 1, true))
        assert.is_truthy(tag:find("|cffff4400", 1, true))
    end)

    it("tags a compatible older peer as syncing, never in grey", function()
        local tag = GBL:_PeerVersionTag({}, olderVersion())
        assert.is_truthy(tag:find("older, syncing", 1, true))
        assert.is_nil(tag:find("a0a0a0", 1, true),
            "compatible peers must not render in the inactive grey")
    end)

    it("tags a compatible newer peer as an available update", function()
        local tag = GBL:_PeerVersionTag({}, newerVersion(GBL.version))
        assert.is_truthy(tag:find("update available", 1, true))
        assert.is_truthy(tag:find("|cff44aaff", 1, true))
    end)

    it("returns no tag for a same-version peer", function()
        assert.equals("", GBL:_PeerVersionTag({}, GBL.version))
    end)

    it("returns no tag for an unknown-version peer", function()
        assert.equals("", GBL:_PeerVersionTag({}, "?"))
    end)
end)
