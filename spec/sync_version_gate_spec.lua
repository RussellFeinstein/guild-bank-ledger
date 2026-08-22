------------------------------------------------------------------------
-- spec/sync_version_gate_spec.lua — Sync version gate
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local Sync = require("spec.sync_helpers")

describe("Sync version gate", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- MIN_SYNC_VERSION floor (#74)
    --
    -- Before v0.37.0 any version difference refused sync, so every release split
    -- the guild until everyone updated. These pin the range gate that replaces
    -- it. GBL.version is assigned directly rather than driven through
    -- OnInitialize so each test states the pair of versions it is about.
    ---------------------------------------------------------------------------
    describe("MIN_SYNC_VERSION floor", function()
        --- A HELLO from a peer that speaks the floor protocol.
        local function floorHello(version, minVersion)
            return {
                version = version,
                minSyncVersion = minVersion or GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 999,
                dataHash = 4242,
                lastScanTime = 1000,
            }
        end

        local function sentTypes()
            local types = {}
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then types[data.type] = (types[data.type] or 0) + 1 end
            end
            return types
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "floorbase:0",
            })
        end)

        it("declares a floor at or below its own version", function()
            -- A forward-dated placeholder would ship a build that refuses every
            -- peer including itself, so this fails on every stacked commit
            -- rather than at release time.
            local plainVersion = GBL:GetSyncVersion():match("^([^-]+)")
            assert.is_truthy(GBL.MIN_SYNC_VERSION)
            assert.is_true(GBL:CompareSemver(GBL.MIN_SYNC_VERSION, plainVersion) <= 0,
                "MIN_SYNC_VERSION must not exceed VERSION")
        end)

        it("refuses a peer below the floor", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", floorHello("0.20.0", "0.20.0"))

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
            assert.is_true(GBL:GetSyncPeers()["OfficerB"].outdated)
        end)

        it("refuses a peer whose own floor is above us", function()
            GBL.version = "0.37.0"
            -- They shipped a later break and will not accept us either.
            GBL:HandleHello("OfficerB", floorHello("0.50.0", "0.45.0"))

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
            assert.equals("local_behind", GBL:GetSyncPeers()["OfficerB"].versionRelation)
        end)

        it("falls back to exact match for a peer advertising no floor", function()
            -- A pre-v0.37.0 peer. Its records may predate any of the guarantees
            -- the floor rests on, so the old rule still applies to it.
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", {
                version = "0.39.0",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 999,
                dataHash = 4242,
            })

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
        end)

        it("accepts an identical pre-floor peer under the exact-match fallback", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", {
                version = "0.40.0",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 999,
                dataHash = 4242,
            })

            assert.equals(1, sentTypes()["SYNC_REQUEST"] or 0)
        end)

        it("refuses a peer that sends no version at all", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", {
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 999,
                dataHash = 4242,
            })

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
        end)

        it("keeps a dev build isolated from an in-range production peer", function()
            -- The trap: CompareSemver strips -dev.<id>, so a range check that
            -- reached it would read this pair as compatible and break the
            -- isolation DEV_BUILD exists to enforce.
            GBL.version = "0.40.0-dev.cross-version-sync"
            GBL:HandleHello("OfficerB", floorHello("0.40.0"))

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
        end)

        it("keeps a production build isolated from an in-range dev peer", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", floorHello("0.40.0-dev.someone-else"))

            assert.is_nil(sentTypes()["SYNC_REQUEST"])
        end)

        it("syncs with a matching dev build", function()
            GBL.version = "0.40.0-dev.cross-version-sync"
            GBL:HandleHello("OfficerB", floorHello("0.40.0-dev.cross-version-sync"))

            assert.equals(1, sentTypes()["SYNC_REQUEST"] or 0)
        end)

        it("replies to an incompatible peer once per session, not once per HELLO", function()
            -- Without this the refusal is silent and the peer never learns why,
            -- but replying on every heartbeat would whisper them forever.
            GBL.version = "0.40.0"
            for _ = 1, 4 do
                GBL:HandleHello("OfficerB", floorHello("0.20.0", "0.20.0"))
            end

            local replies = 0
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "HELLO" and data.isReply then
                    replies = replies + 1
                end
            end
            assert.equals(1, replies)
        end)

        it("does not reply to an incompatible peer's reply", function()
            GBL.version = "0.40.0"
            local hello = floorHello("0.20.0", "0.20.0")
            hello.isReply = true
            GBL:HandleHello("OfficerB", hello)

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                assert.is_false(ok and data.type == "HELLO" and data.isReply == true)
            end
        end)

        it("still adopts access control from an incompatible peer", function()
            -- The settings merges sit above the gate on purpose: a GM's policy
            -- has to reach members through a mixed-version window.
            GBL.version = "0.40.0"
            local hello = floorHello("0.20.0", "0.20.0")
            hello.accessControl = {
                rankThreshold = 3,
                restrictedMode = true,
                configuredBy = "GuildMaster",
                configuredAt = 5000,
            }
            GBL:HandleHello("OfficerB", hello)

            assert.equals(3, guildData.accessControl.rankThreshold)
        end)

        describe("serving side", function()
            it("refuses a SYNC_REQUEST from a peer below the floor", function()
                GBL.version = "0.40.0"
                GBL:HandleSyncRequest("OfficerB", request{
                    sinceTimestamp = 0,
                    version = "0.20.0",
                    minSyncVersion = "0.20.0",
                })

                assert.is_nil(sentTypes()["SYNC_DATA"])
            end)

            it("refuses a SYNC_REQUEST carrying no version", function()
                -- The pre-floor request shape, written out rather than through
                -- request() precisely because the missing version is the point.
                -- HandleHello alone cannot stop this: RequestSync skips HELLO.
                GBL.version = "0.40.0"
                GBL:HandleSyncRequest("OfficerB", { sinceTimestamp = 0 })

                assert.is_nil(sentTypes()["SYNC_DATA"])
            end)

            it("does not answer an incompatible requester with BUSY", function()
                -- BUSY reads as "try again shortly" and would drive their retry
                -- loop for as long as they stay on the old version.
                GBL.version = "0.40.0"
                GBL:HandleSyncRequest("OfficerB", request{
                    sinceTimestamp = 0,
                    version = "0.20.0",
                    minSyncVersion = "0.20.0",
                })

                assert.is_nil(sentTypes()["BUSY"])
            end)

            it("serves a compatible requester", function()
                GBL.version = "0.40.0"
                GBL:HandleSyncRequest("OfficerB", request{
                    sinceTimestamp = 0,
                    version = "0.38.0",
                    minSyncVersion = GBL.MIN_SYNC_VERSION,
                })

                assert.equals(1, sentTypes()["SYNC_DATA"] or 0)
            end)

            it("keeps a dev build from serving a production requester", function()
                GBL.version = "0.40.0-dev.cross-version-sync"
                GBL:HandleSyncRequest("OfficerB", request{
                    sinceTimestamp = 0,
                    version = "0.40.0",
                    minSyncVersion = GBL.MIN_SYNC_VERSION,
                })

                assert.is_nil(sentTypes()["SYNC_DATA"])
            end)
        end)

        describe("pull side", function()
            it("declines to request from a known-incompatible peer", function()
                -- ProcessPendingPeers reaches RequestSync without passing the
                -- HELLO gate, so the check has to exist here too.
                GBL.version = "0.40.0"
                GBL:HandleHello("OfficerB", floorHello("0.20.0", "0.20.0"))
                MockAce.sentCommMessages = {}

                GBL:RequestSync("OfficerB", 0)

                assert.is_nil(sentTypes()["SYNC_REQUEST"])
                assert.is_false(GBL:GetSyncStatus().receiving)
            end)

            it("requests from a known-compatible peer", function()
                GBL.version = "0.40.0"
                GBL:HandleHello("OfficerB", floorHello("0.38.0"))
                MockAce.sentCommMessages = {}
                GBL:ResetSyncState()

                GBL:RequestSync("OfficerB", 0)

                assert.equals(1, sentTypes()["SYNC_REQUEST"] or 0)
            end)
        end)

        describe("payload", function()
            it("puts the version and floor on SYNC_REQUEST", function()
                GBL:RequestSync("OfficerB", 0)

                local found
                for _, msg in ipairs(MockAce.sentCommMessages) do
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "SYNC_REQUEST" then found = data end
                end
                assert.is_not_nil(found)
                assert.equals(GBL.version, found.version)
                assert.equals(GBL.MIN_SYNC_VERSION, found.minSyncVersion)
            end)

            it("remembers a peer's floor across sessions", function()
                -- InitSync seeds the session peer list from knownPeers, and the
                -- pull-side gate reads the floor from that seeded entry.
                GBL:HandleHello("OfficerB", floorHello("0.38.0", "0.37.0"))

                assert.equals("0.37.0", GBL:GetSyncPeers()["OfficerB"].minSyncVersion)
                assert.equals("0.37.0", guildData.knownPeers["OfficerB"].minSyncVersion)
            end)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Exact version matching
    ---------------------------------------------------------------------------

    describe("exact version matching", function()
        it("allows sync when versions match exactly", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Add local data so sync makes sense
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1:0",
            })
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 999,
                dataHash = 12345,
                lastScanTime = 1000,
            })
            -- Should proceed to sync logic (not blocked by version gate)
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.falsy(entry.message:find("version mismatch"))
            end
        end)

        it("protocol version gate rejects old protocol messages", function()
            assert.equals(4, GBL.SYNC_PROTOCOL_VERSION)
        end)

        it("tracks outdated peers from protocol-mismatched HELLO", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Simulate a HELLO with old protocol version
            local msg = GBL:Serialize({
                type = "HELLO",
                version = "0.12.2",
                protocolVersion = 2,
                guild = "TestGuild",
                txCount = 50,
                dataHash = 999,
            })
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "OutdatedPeer")

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OutdatedPeer"])
            assert.equals("0.12.2", peers["OutdatedPeer"].version)
            assert.is_true(peers["OutdatedPeer"].outdated)
        end)

        it("sets versionRelation=peer_behind for older protocol peer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO",
                version = "0.12.2",
                protocolVersion = 2,
                guild = "TestGuild",
                txCount = 50,
                dataHash = 999,
            })
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "OldPeer")

            local peers = GBL:GetSyncPeers()
            assert.equals("peer_behind", peers["OldPeer"].versionRelation)
        end)

        it("sets versionRelation=local_behind for newer protocol peer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local msg = GBL:Serialize({
                type = "HELLO",
                version = "99.0.0",
                protocolVersion = 999,
                guild = "TestGuild",
                txCount = 50,
                dataHash = 999,
            })
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "NewerPeer")

            local peers = GBL:GetSyncPeers()
            assert.equals("local_behind", peers["NewerPeer"].versionRelation)
        end)

        it("sets versionRelation=peer_behind for addon version mismatch (older peer)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleHello("OldPeer", {
                version = "0.1.0",
                txCount = 10,
                lastScanTime = 1000,
            })

            local peers = GBL:GetSyncPeers()
            assert.is_true(peers["OldPeer"].outdated)
            assert.equals("peer_behind", peers["OldPeer"].versionRelation)
        end)

        it("sets versionRelation=local_behind for addon version mismatch (newer peer)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleHello("NewerPeer", {
                version = "99.0.0",
                txCount = 10,
                lastScanTime = 1000,
            })

            local peers = GBL:GetSyncPeers()
            assert.is_true(peers["NewerPeer"].outdated)
            assert.equals("local_behind", peers["NewerPeer"].versionRelation)
        end)

        it("GetHighestPeerVersion returns nil with no peers", function()
            assert.is_nil(GBL:GetHighestPeerVersion())
        end)

        it("GetHighestPeerVersion returns highest among active peers", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add peers with different versions via protocol-mismatched HELLOs
            for _, info in ipairs({
                { name = "PeerA", version = "0.15.0" },
                { name = "PeerB", version = "0.18.1" },
                { name = "PeerC", version = "0.16.0" },
            }) do
                local msg = GBL:Serialize({
                    type = "HELLO",
                    version = info.version,
                    protocolVersion = 999,
                    guild = "TestGuild",
                    txCount = 10,
                    dataHash = 123,
                })
                GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", info.name)
            end

            assert.equals("0.18.1", GBL:GetHighestPeerVersion())
        end)
    end)

    ---------------------------------------------------------------------------
    -- Peer version classification
    --
    -- ClassifyPeerVersion answers "can we sync with this peer, and which
    -- side is ahead" from the peer's advertised version and floor alone.
    -- The session-only `outdated` flag is deliberately not an input: it is
    -- written by live message intake, so a peer seeded from knownPeers at
    -- login never has one, and a below-floor peer who spends the session in
    -- an instance would otherwise read as syncable.
    ---------------------------------------------------------------------------

    describe("ClassifyPeerVersion", function()
        --- Shift a semver by whole patch releases.
        local function bumpPatch(v, by)
            local maj, min, patch = v:match("^(%d+)%.(%d+)%.(%d+)")
            return maj .. "." .. min .. "." .. (tonumber(patch) + by)
        end

        --- Older than us but at or above the floor, so genuinely compatible.
        local function compatibleOlder()
            return bumpPatch(GBL.MIN_SYNC_VERSION, 1)
        end

        local function aheadVersion()
            local major = tonumber(GBL.version:match("^(%d+)")) or 0
            return (major + 1) .. ".0.0"
        end

        -- State the local version rather than inheriting the build's, the
        -- way the MIN_SYNC_VERSION block does. Two reasons: a dev branch
        -- sets DEV_BUILD, and a dev version refuses every peer by design,
        -- so without this every case below would classify as dev_peer and
        -- the block would be testing the isolation rather than the
        -- classifier. It also keeps the versions derived from the floor,
        -- which only moves on a deliberate compatibility break.
        before_each(function()
            GBL.version = bumpPatch(GBL.MIN_SYNC_VERSION, 2)
        end)

        it("classifies a below-floor peer as incompatible_old", function()
            assert.equals("incompatible_old",
                GBL:ClassifyPeerVersion({ version = "0.1.0" }))
        end)

        it("classifies a peer whose floor is above us as incompatible_new",
        function()
            local ahead = aheadVersion()
            assert.equals("incompatible_new", GBL:ClassifyPeerVersion({
                version = ahead, minSyncVersion = ahead,
            }))
        end)

        it("classifies a compatible older peer as older_ok", function()
            assert.equals("older_ok", GBL:ClassifyPeerVersion({
                version = compatibleOlder(),
                minSyncVersion = GBL.MIN_SYNC_VERSION,
            }))
        end)

        it("classifies a compatible newer peer as newer_ok", function()
            assert.equals("newer_ok", GBL:ClassifyPeerVersion({
                version = aheadVersion(),
                minSyncVersion = GBL.MIN_SYNC_VERSION,
            }))
        end)

        it("classifies our own version as same", function()
            assert.equals("same", GBL:ClassifyPeerVersion({
                version = GBL.version, minSyncVersion = GBL.MIN_SYNC_VERSION,
            }))
        end)

        it("classifies a dev-build peer as dev_peer", function()
            assert.equals("dev_peer", GBL:ClassifyPeerVersion({
                version = GBL.version .. "-dev.branch",
            }))
        end)

        it("classifies missing and unknown versions as unknown", function()
            assert.equals("unknown", GBL:ClassifyPeerVersion(nil))
            assert.equals("unknown", GBL:ClassifyPeerVersion({}))
            assert.equals("unknown", GBL:ClassifyPeerVersion({ version = "?" }))
        end)

        -- The whole point of the classifier: the verdict comes from the
        -- versions, so a stale flag cannot contradict it in either
        -- direction.
        it("ignores the outdated flag entirely", function()
            local compatible = {
                version = compatibleOlder(),
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                outdated = true,
                versionRelation = "peer_behind",
            }
            assert.equals("older_ok", GBL:ClassifyPeerVersion(compatible))

            -- And the reload case: refused peer, flag long gone.
            assert.equals("incompatible_old",
                GBL:ClassifyPeerVersion({ version = "0.1.0" }))
        end)
    end)
end)
