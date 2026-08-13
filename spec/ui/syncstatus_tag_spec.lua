------------------------------------------------------------------------
-- syncstatus_tag_spec.lua — Peer-list version tag (_PeerVersionTag).
--
-- The tag is derived from the peer's advertised version and floor, never
-- from the session-only `outdated` flag. That flag is set by live message
-- intake, so it cannot exist for a peer seeded out of knownPeers at login,
-- and a below-floor peer who never transmits this session used to render
-- as though sync worked. Stateless classification survives a /reload by
-- construction; a persisted flag would only move the staleness.
--
-- Colour rules: warning red for a refusal the viewer can act on, blue for
-- an update note, grey (a0a0a0) only for genuinely inactive rows. A
-- compatible peer is syncing and must never render grey.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

describe("Peer version tag", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    -- Versions derived relative to the runtime version and the floor so
    -- stamp commits change nothing here (2026-05-05 version-literal lesson).
    local function belowFloor() return "0.1.0" end

    local function newerVersion(v)
        local major = tonumber(v:match("^(%d+)")) or 0
        return (major + 1) .. ".0.0"
    end

    --- Older than us but still at or above the floor, so genuinely compatible.
    local function compatibleOlder()
        local maj, min, patch = GBL.version:match("^(%d+)%.(%d+)%.(%d+)")
        patch = tonumber(patch)
        if patch and patch > 0 then
            local candidate = maj .. "." .. min .. "." .. (patch - 1)
            if GBL:CompareSemver(candidate, GBL.MIN_SYNC_VERSION) >= 0 then
                return candidate
            end
        end
        return GBL.MIN_SYNC_VERSION
    end

    it("tags a peer below the floor as refused, in warning colour", function()
        local tag = GBL:_PeerVersionTag(
            { version = belowFloor() }, belowFloor())
        assert.is_truthy(tag:find("too old | sync refused", 1, true))
        assert.is_truthy(tag:find("|cffff4400", 1, true))
    end)

    -- The reload repro. A below-floor peer refused during a previous
    -- session, then seeded from knownPeers after /reload: no `outdated`
    -- flag anywhere, and no HELLO this session because they are in an
    -- instance. The old flag-driven tag called this one "older, syncing".
    it("tags a seeded below-floor peer as refused without the outdated flag",
    function()
        local info = { version = belowFloor(), rosterOnly = true }
        assert.is_nil(info.outdated)
        local tag = GBL:_PeerVersionTag(info, belowFloor())
        assert.is_truthy(tag:find("too old | sync refused", 1, true))
    end)

    it("tags a peer whose floor is above us as needing a local update",
    function()
        local ahead = newerVersion(GBL.version)
        local tag = GBL:_PeerVersionTag(
            { version = ahead, minSyncVersion = ahead }, ahead)
        assert.is_truthy(tag:find("newer | update to sync", 1, true))
        assert.is_truthy(tag:find("|cff44aaff", 1, true))
    end)

    it("tags a compatible older peer as syncing, never in grey", function()
        local older = compatibleOlder()
        local tag = GBL:_PeerVersionTag(
            { version = older, minSyncVersion = GBL.MIN_SYNC_VERSION }, older)
        assert.is_truthy(tag:find("older | syncing", 1, true))
        assert.is_nil(tag:find("a0a0a0", 1, true),
            "compatible peers must not render in the inactive grey")
    end)

    it("tags a compatible newer peer as an available update", function()
        local ahead = newerVersion(GBL.version)
        local tag = GBL:_PeerVersionTag(
            { version = ahead, minSyncVersion = GBL.MIN_SYNC_VERSION }, ahead)
        assert.is_truthy(tag:find("newer | update available", 1, true))
        assert.is_truthy(tag:find("|cff44aaff", 1, true))
    end)

    -- A dev build refuses everyone in both directions by design. Calling it
    -- "too old" points the viewer at an update that does not exist and is
    -- not theirs to make, so it gets the inactive grey instead of the
    -- warning red.
    it("tags a dev-build peer as refused, in the inactive grey", function()
        local dev = GBL.version .. "-dev.branch"
        local tag = GBL:_PeerVersionTag({ version = dev }, dev)
        assert.is_truthy(tag:find("dev build | sync refused", 1, true))
        assert.is_truthy(tag:find("|cffa0a0a0", 1, true))
    end)

    it("returns no tag for a same-version peer", function()
        assert.equals("", GBL:_PeerVersionTag(
            { version = GBL.version, minSyncVersion = GBL.MIN_SYNC_VERSION },
            GBL.version))
    end)

    it("returns no tag for an unknown-version peer", function()
        assert.equals("", GBL:_PeerVersionTag({}, "?"))
    end)
end)
