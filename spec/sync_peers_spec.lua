------------------------------------------------------------------------
-- spec/sync_peers_spec.lua — Sync peer identity and pairing
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync peer identity and pairing", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- Free-agent pairing
    --
    -- A peer that finishes a session becomes free and takes whatever the
    -- next HELLO offers. There is no manifest of other members' bucket
    -- hashes and no scored queue choosing a "best" next partner: gossip
    -- converges without either, and the bookkeeping cost was paid on every
    -- pop (a full bucket-hash walk per queued peer).
    --
    -- Two things the queue was quietly carrying have to survive it: not
    -- hammering a peer that just said BUSY, and not losing a sync
    -- opportunity to a combat window.
    ---------------------------------------------------------------------------

    describe("free-agent pairing", function()
        --- A HELLO from a compatible peer holding data we do not have.
        local function hello(fields)
            fields = fields or {}
            return {
                type = "HELLO",
                version = fields.version or GBL.version,
                minSyncVersion = fields.minSyncVersion or GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = fields.txCount or 999,
                dataHash = fields.dataHash or 987654,
                lastScanTime = fields.lastScanTime or 1000,
                isReply = fields.isReply,
            }
        end

        local function countSent(msgType, target)
            local count = 0
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == msgType
                    and (target == nil or sent.target == target) then
                    count = count + 1
                end
            end
            return count
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
                { name = "OfficerC-TestRealm", isOnline = true },
            }
        end)

        -----------------------------------------------------------------
        -- The scored machinery is gone
        -----------------------------------------------------------------

        it("has no manifest broadcast or pending-peer queue API", function()
            assert.is_nil(GBL.BroadcastManifest)
            assert.is_nil(GBL.HandleManifest)
            assert.is_nil(GBL.AddPendingPeer)
            assert.is_nil(GBL.PopPendingPeer)
            assert.is_nil(GBL.RemovePendingPeer)
            assert.is_nil(GBL.ProcessPendingPeers)
        end)

        it("no longer reports a pending peer count", function()
            assert.is_nil(GBL:GetSyncStatus().pendingPeersCount)
        end)

        -- An older peer keeps broadcasting MANIFEST at us for as long as
        -- they are on an older build. The dispatch chain has no else, so
        -- this is a no-op, and that is the whole compatibility story: no
        -- protocol bump, no floor raise.
        it("ignores a MANIFEST from an older peer without erroring", function()
            local msg = GBL:Serialize({
                type = "MANIFEST",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                dataHash = 4242,
                txCount = 500,
                buckets = { [1] = 11, [2] = 22 },
            })
            assert.has_no.errors(function()
                GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "GUILD", "OfficerB")
            end)
        end)

        -----------------------------------------------------------------
        -- BUSY backoff, without a queue to carry it
        -----------------------------------------------------------------

        it("marks a peer busy on BUSY and clears the mark when it expires",
        function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            assert.is_true(GBL:IsPeerBusy("OfficerB"))

            MockWoW.serverTime = 100000 + GBL.SYNC_BUSY_COOLDOWN + 1
            assert.is_false(GBL:IsPeerBusy("OfficerB"))
        end)

        it("does not request from a peer inside its BUSY cooldown", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerB", hello())

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -- The fast-path check needs its own pin: a mutation test showed the
        -- test above still passed with it removed, because the check inside
        -- the jitter callback caught the same case. That second check went
        -- away with the jitter, so this test is what keeps the surviving one
        -- honest. It also covers the audit line, without which a capture
        -- shows a HELLO arriving and simply nothing happening.
        it("skips a busy peer without requesting, and says why", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerB", hello())

            -- Counting timers used to be the discriminator here. Its stated
            -- reason died with the jitter timer, and the power it kept was
            -- incidental: a deleted busy check would still bump the count,
            -- but only via the receive timeout RequestSync arms for the
            -- request it should not be making. Asserting on the wire pins
            -- the contract for a reason that survives timer rearrangement.
            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))
            local logged = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=busy-cooldown", 1, true) then
                    logged = true
                end
            end
            assert.is_true(logged)
        end)

        it("requests from the same peer once the cooldown expires", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            MockWoW.serverTime = 100000 + GBL.SYNC_BUSY_COOLDOWN + 1
            GBL:HandleHello("OfficerB", hello())

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -- The check belongs at the automatic initiation sites, not inside
        -- RequestSync: a manual pull is the user asking, and refusing it
        -- silently would be its own bug.
        it("still allows a direct RequestSync to a busy peer", function()
            MockWoW.serverTime = 100000
            GBL:HandleBusy("OfficerB", {})
            MockAce.sentCommMessages = {}

            GBL:RequestSync("OfficerB", 0)

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerB"))
        end)

        -----------------------------------------------------------------
        -- Combat, without a queue to drain
        -----------------------------------------------------------------

        it("defers a combat-time HELLO and re-broadcasts when combat ends",
        function()
            MockWoW.inCombat = true
            GBL:HandleHello("OfficerB", hello())
            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))

            MockWoW.inCombat = false
            MockAce.sentCommMessages = {}
            GBL:OnCombatEnd()
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if not timer.cancelled and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(1, countSent("HELLO"),
                "combat end should re-advertise so pairing can resume")
        end)

        -- Twenty raid members ending combat together must not each fire a
        -- broadcast. Only a client that actually deferred something does.
        it("broadcasts nothing on combat end when nothing was deferred",
        function()
            MockAce.sentCommMessages = {}
            GBL:OnCombatEnd()
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if not timer.cancelled and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(0, countSent("HELLO"))
        end)

        -----------------------------------------------------------------
        -- Free after a session, and drop what we cannot take now
        -----------------------------------------------------------------

        it("drops a HELLO that arrives mid-receive rather than queuing it",
        function()
            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerC"))
            assert.equals("OfficerB", GBL:GetSyncStatus().receiveSource)
        end)

        it("takes the next HELLO immediately once the session ends", function()
            GBL:RequestSync("OfficerB", 0)
            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            GBL:FinishReceiving("OfficerB")
            MockAce.sentCommMessages = {}

            -- The peer re-advertises on its own heartbeat; we are free now.
            GBL:HandleHello("OfficerC", hello({ dataHash = 555111 }))

            assert.equals(1, countSent("SYNC_REQUEST", "OfficerC"))
        end)

        -----------------------------------------------------------------
        -- The pause guard the queue used to provide
        -----------------------------------------------------------------

        -- ProcessPendingPeers checked isSyncPaused before initiating, and the
        -- queue was the deferral. With both the queue and the jitter gone,
        -- HandleHello's own skip chain is the only place left to check it.
        -- The pause outlives its trigger by a cooldown, so this arm covers a
        -- window the combat-lockdown check above it no longer sees.
        it("does not request while a zone change has sync paused, and says why",
        function()
            -- OnLoadingScreenStart only pauses a live session, so enter one
            -- and end it, which leaves zonePaused set until its cooldown.
            GBL:RequestSync("OfficerC", 0)
            GBL:OnLoadingScreenStart()
            GBL:FinishReceiving("OfficerC")
            assert.is_true(GBL:GetSyncStatus().zonePaused)

            -- Clear before the HELLO, not after: once the request is issued
            -- inline, a clear that follows HandleHello wipes the very message
            -- this test is looking for and it passes without pinning anything.
            MockAce.sentCommMessages = {}
            GBL:HandleHello("OfficerB", hello())

            assert.equals(0, countSent("SYNC_REQUEST", "OfficerB"))

            -- Silence here is what made the old jitter callback's five returns
            -- undiagnosable, so the skip has to name itself in the capture.
            local logged = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=paused-zone", 1, true) then
                    logged = true
                end
            end
            assert.is_true(logged)
        end)
    end)

    ---------------------------------------------------------------------------
    -- BUSY message
    ---------------------------------------------------------------------------

    describe("BUSY message", function()
        it("HandleSyncRequest sends BUSY when already sending", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local gd = GBL:GetGuildData()
            -- Add data so first HandleSyncRequest enters sending state
            table.insert(gd.transactions, {
                type = "deposit", player = "Player1", tab = 1, itemID = 123,
                classID = 0, subclassID = 0, count = 1,
                timestamp = 1000 * 3600, id = "abc:277:0",
                _occurrence = 0, scanTime = 1000 * 3600, scannedBy = "OfficerA",
            })
            gd.seenTxHashes["abc:277:0"] = 1000 * 3600

            -- First request succeeds (enters sending state)
            GBL:HandleSyncRequest("PeerA", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().sending)
            MockAce.sentCommMessages = {}

            -- Second request should be declined with BUSY
            GBL:HandleSyncRequest("PeerB", request{
                sinceTimestamp = 0,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Verify BUSY was sent to PeerB (LibDeflate mock is identity,
            -- so sent text is raw AceSerializer output)
            local found = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                if msg.target == "PeerB" then
                    local ok, d = GBL:Deserialize(msg.text)
                    if ok and type(d) == "table" and d.type == "BUSY" then
                        found = true
                    end
                end
            end
            assert.is_true(found, "BUSY message should have been sent to PeerB")
        end)

        -- The retry above means the peer we are already serving may ask again
        -- while its first request is being answered. Answering that with BUSY
        -- would make it abort the very receive we are feeding, so a duplicate
        -- from the current target is ignored instead.
        it("ignores a repeat request from the peer we are already sending to", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local gd = GBL:GetGuildData()
            for i = 1, 12 do
                local ts = (1000 + i) * 3600
                table.insert(gd.transactions, {
                    type = "deposit", player = "Player1", tab = 1, itemID = 123,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = ts, id = "dup" .. i .. ":277:0",
                    _occurrence = 0, scanTime = ts, scannedBy = "OfficerA",
                })
            end

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)
            local progressBefore = GBL:GetSyncStatus().sendProgress
            MockAce.sentCommMessages = {}

            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, d = GBL:Deserialize(msg.text)
                assert.is_false(ok and type(d) == "table" and d.type == "BUSY",
                    "a repeat from the current target must not draw a BUSY")
            end
            assert.is_true(GBL:GetSyncStatus().sending,
                "the session in flight should survive the repeat")
            assert.equals(progressBefore, GBL:GetSyncStatus().sendProgress,
                "the repeat should not restart or advance the send")
        end)

        it("HandleBusy clears receiving state when waiting for that peer", function()
            -- Enter receiving state for PeerA
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)

            -- Receive BUSY from PeerA
            GBL:HandleBusy("PeerA", {})
            status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
            assert.is_nil(status.receiveSource)
        end)

        it("HandleBusy starts the peer's cooldown", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:HandleBusy("PeerA", {})
            assert.is_true(GBL:IsPeerBusy("PeerA"))
        end)

        -- Why a BUSY arrived is the difference between three responses that
        -- have nothing to do with each other: a peer already serving someone
        -- else, a peer that just entered combat, or a peer refusing to serve
        -- during a fight. A capture could not tell them apart, and three
        -- sends killed by BUSY in the 2026-08-12 window are still unexplained
        -- because of it (#97).
        it("HandleBusy records why the peer was busy", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:ClearLog("sync")

            GBL:HandleBusy("PeerA", { reason = "sending:SomeoneElse" })

            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message and e.message:find("Received BUSY from PeerA", 1, true)
                    and e.message:find("reason: sending:SomeoneElse", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "the BUSY line should carry the reason it arrived with")
        end)

        -- A peer from before the field existed sends no reason at all. The
        -- line still has to say something, and "unknown" is honest where a
        -- blank would read as a reason we failed to print.
        it("HandleBusy says unknown when the peer sent no reason", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            GBL:ClearLog("sync")

            GBL:HandleBusy("PeerA", {})

            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message and e.message:find("Received BUSY from PeerA", 1, true)
                    and e.message:find("reason: unknown", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "an older peer's reasonless BUSY should log unknown")
        end)

        it("HandleBusy is no-op on receiving state when not receiving", function()
            GBL:HandleBusy("PeerA", {})
            assert.is_false(GBL:GetSyncStatus().receiving)
            -- The cooldown still starts: they told us they were busy.
            assert.is_true(GBL:IsPeerBusy("PeerA"))
        end)

        it("HandleBusy does not clear state when receiving from different peer", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            local status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)

            -- BUSY from PeerB (different peer)
            GBL:HandleBusy("PeerB", {})
            status = GBL:GetSyncStatus()
            assert.is_true(status.receiving)
            assert.equals("PeerA", status.receiveSource)
        end)

        it("HandleBusy clears state even after receiving partial data", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            -- Simulate having received chunk 1
            GBL:HandleSyncData("PeerA", {
                chunk = 1, totalChunks = 2,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- BUSY after partial data should clear state (data already stored)
            GBL:HandleBusy("PeerA", {})
            local status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
        end)

        it("BUSY message dispatches through OnSyncMessage", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            -- Craft and send a BUSY message through the dispatch
            local msg = GBL:Serialize({
                type = "BUSY",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            msg = GBL._compressMessage(msg)
            GBL:OnSyncMessage(GBL.SYNC_PREFIX, msg, "WHISPER", "PeerA")

            local status = GBL:GetSyncStatus()
            assert.is_false(status.receiving)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Peer staleness
    ---------------------------------------------------------------------------

    describe("peer staleness", function()
        before_each(function()
            GBL:ResetSyncState()
            GBL.db.profile.sync.enabled = true
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
        end)

        it("GetSyncPeers returns peers seen recently", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Still within staleness window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS - 1
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
        end)

        it("GetSyncPeers filters out stale peers", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Past staleness window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            local peers = GBL:GetSyncPeers()
            assert.is_nil(peers["OfficerB"])
        end)

        it("stale peer reappears after new message", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Goes stale
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])

            -- New HELLO re-registers
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 10, lastScanTime = MockWoW.serverTime,
            })
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
            assert.equals(10, GBL:GetSyncPeers()["OfficerB"].txCount)
        end)

        it("GetAllPeers returns stale peers too", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
            assert.is_not_nil(GBL:GetAllPeers()["OfficerB"])
        end)

        it("heartbeat keeps idle peer alive in peer list", function()
            MockWoW.serverTime = 100000
            GBL:InitSync()
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past heartbeat interval but within stale window
            MockWoW.serverTime = 100200
            -- Fire heartbeat timer (broadcasts our HELLO)
            MockWoW.fireTimers()
            -- Simulate HELLO reply arriving from OfficerB, refreshing their lastSeen
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance to where original lastSeen would be stale, but refreshed one is not
            MockWoW.serverTime = 100400
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("peer without heartbeat refresh expires after PEER_STALE_SECONDS", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past stale window without any heartbeat or messages
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 1
            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("stale peer stays visible if guild roster says online", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Advance past stale window
            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            -- Set up roster with OfficerB online
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_true(peers["OfficerB"].rosterOnly)
        end)

        it("stale peer drops if guild roster says offline", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("recently-seen peer drops if guild roster says offline", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            -- Still within staleness window (peer messaged us recently)
            MockWoW.serverTime = 100000 + 30

            -- But roster says they went offline (e.g., disconnected during sync)
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            assert.is_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("recently-seen peer stays if roster unknown", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + 30

            -- Empty roster (nil return) — don't filter out
            MockWoW.guildRoster = {}
            assert.is_not_nil(GBL:GetSyncPeers()["OfficerB"])
        end)

        it("roster fallback does not mutate original syncState peer entry", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = GBL.version, txCount = 5, lastScanTime = 99999,
            })

            MockWoW.serverTime = 100000 + GBL.SYNC_PEER_STALE_SECONDS + 100

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            -- Get peers triggers roster fallback
            local peers = GBL:GetSyncPeers()
            assert.is_true(peers["OfficerB"].rosterOnly)

            -- Original should NOT have rosterOnly
            local all = GBL:GetAllPeers()
            assert.is_nil(all["OfficerB"].rosterOnly)
        end)

        it("UpdatePeer persists to guildData.knownPeers", function()
            MockWoW.serverTime = 100000
            GBL:UpdatePeer("OfficerB", {
                version = "0.22.3", txCount = 42, lastScanTime = 99999,
            })

            local kp = guildData.knownPeers["OfficerB"]
            assert.is_not_nil(kp)
            assert.equals("0.22.3", kp.version)
            assert.equals(42, kp.txCount)
            assert.equals(100000, kp.lastSeen)
        end)

        it("InitSync seeds session peers from knownPeers", function()
            MockWoW.serverTime = 100000
            -- Simulate persisted knownPeers from a prior session
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            assert.is_nil(GBL:GetAllPeers()["OfficerB"])

            GBL:InitSync()

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.is_not_nil(peer)
            assert.equals("0.20.0", peer.version)
            assert.equals(99000, peer.lastSeen)  -- stays stale
        end)

        -- UpdatePeer persists minSyncVersion into knownPeers specifically so
        -- the seed can carry it, and RequestSync's gate reads the floor off
        -- the seeded entry. Dropping it in the copy made every seeded peer
        -- look pre-floor (exact match required) until their first live HELLO,
        -- which also drove the peer list to call a compatible peer refused.
        it("InitSync seeds minSyncVersion from knownPeers", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                txCount = 10,
                lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.is_not_nil(peer)
            assert.equals(GBL.MIN_SYNC_VERSION, peer.minSyncVersion)
        end)

        it("seeded peer with roster online appears in GetSyncPeers", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_true(peers["OfficerB"].rosterOnly)
        end)

        it("seeded peer is overwritten by fresh HELLO", function()
            MockWoW.serverTime = 100000
            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10, lastSeen = 99000,
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            -- Fresh HELLO arrives
            MockWoW.serverTime = 100001
            GBL:UpdatePeer("OfficerB", {
                version = "0.23.0", txCount = 50, lastScanTime = 100001,
            })

            local peer = GBL:GetAllPeers()["OfficerB"]
            assert.equals("0.23.0", peer.version)
            assert.equals(100001, peer.lastSeen)

            -- Should be fresh, not roster-only
            local active = GBL:GetSyncPeers()
            assert.is_not_nil(active["OfficerB"])
            assert.is_nil(active["OfficerB"].rosterOnly)
        end)

        it("InitSync expires knownPeers older than 30 days", function()
            MockWoW.serverTime = 100000
            local expireSeconds = GBL.SYNC_KNOWN_PEER_EXPIRE_SECONDS

            guildData.knownPeers["OfficerB"] = {
                version = "0.20.0", txCount = 10,
                lastSeen = 100000 - expireSeconds - 1,  -- just expired
            }
            guildData.knownPeers["OfficerC"] = {
                version = "0.21.0", txCount = 20,
                lastSeen = 100000 - expireSeconds + 3600,  -- still valid
            }

            GBL:ResetSyncState()
            GBL:InitSync()

            -- OfficerB expired from knownPeers and not seeded
            assert.is_nil(guildData.knownPeers["OfficerB"])
            assert.is_nil(GBL:GetAllPeers()["OfficerB"])

            -- OfficerC still valid and seeded
            assert.is_not_nil(guildData.knownPeers["OfficerC"])
            assert.is_not_nil(GBL:GetAllPeers()["OfficerC"])
        end)

        -- The stale-peer skip this block used to test lived in
        -- PopPendingPeer, and there is nothing left for it to protect: a
        -- sync is now only ever started off a HELLO that just arrived, or
        -- off a session that just finished, and neither can name a peer we
        -- have not heard from. Staleness still matters for display, which
        -- GetSyncPeers' rosterOnly tests cover.

        it("heartbeat timer starts on InitSync", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            -- Should have a pending heartbeat ticker
            local found = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)

        it("heartbeat timer cancelled on DisableSync", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            -- Verify timer was started
            local heartbeat = nil
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    heartbeat = timer
                    break
                end
            end
            assert.is_not_nil(heartbeat)

            GBL:DisableSync()
            assert.is_true(heartbeat.cancelled)
        end)

        it("heartbeat timer cancelled on ResetSyncState", function()
            MockWoW.pendingTimers = {}
            GBL:InitSync()
            local heartbeat = nil
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_HELLO_HEARTBEAT_INTERVAL then
                    heartbeat = timer
                    break
                end
            end
            assert.is_not_nil(heartbeat)

            GBL:ResetSyncState()
            assert.is_true(heartbeat.cancelled)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Realm-qualified peer name handling (v0.30.5 hardening)
    ---------------------------------------------------------------------------

    describe("realm-qualified peer names", function()
        local function buildHelloPayload()
            return GBL:Serialize({
                type = "HELLO",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                version = GBL.version,
                txCount = 7,
                dataHash = "abc123",
                lastScanTime = 99999,
            })
        end

        it("Ambiguate('Name-Realm', 'none') is identity in the mock (matches retail)", function()
            assert.equals("Rexxybear-Tichondrius",
                Ambiguate("Rexxybear-Tichondrius", "none"))
        end)

        it("Ambiguate('Name-Realm', 'short') strips realm in the mock", function()
            assert.equals("Rexxybear", Ambiguate("Rexxybear-Tichondrius", "short"))
            assert.equals("Rexxybear", Ambiguate("Rexxybear-Tichondrius", "all"))
        end)

        it("same-realm-qualified HELLO sender keys peer by bare name", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear-TestRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Rexxybear"])
            assert.is_nil(peers["Rexxybear-TestRealm"])
        end)

        it("mixed-qualification same-realm HELLO arrivals collapse to one entry", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear-TestRealm")
            MockWoW.serverTime = 100050
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Rexxybear")

            local peers = GBL:GetAllPeers()
            local count = 0
            for _ in pairs(peers) do count = count + 1 end
            assert.equals(1, count)
            assert.is_not_nil(peers["Rexxybear"])
        end)

        it("OnSyncMessage ignores own message arriving as Name-Realm", function()
            MockWoW.player.name = "OfficerA"
            MockWoW.player.realm = "Tichondrius"
            local payload = buildHelloPayload()
            local compressed = GBL._compressMessage(payload)

            GBL:OnSyncMessage("GBL", compressed, "GUILD", "OfficerA-Tichondrius")

            local peers = GBL:GetAllPeers()
            assert.is_nil(peers["OfficerA"])
            assert.is_nil(peers["OfficerA-Tichondrius"])
        end)

        it("UpdatePeer keys knownPeers by bare name when called with same-realm Name-Realm", function()
            MockWoW.serverTime = 100000
            MockWoW.player.realm = "TestRealm"
            GBL:UpdatePeer("Rexxybear-TestRealm", {
                version = "0.30.5", txCount = 12, lastScanTime = 99999,
            })

            assert.is_not_nil(guildData.knownPeers["Rexxybear"])
            assert.is_nil(guildData.knownPeers["Rexxybear-TestRealm"])
        end)

        -- Migration tests for MigrateNormalizePeerNames + MigrateRecoverPeerRealms
        -- now live in spec/core_spec.lua under their own describe blocks.

        it("MigrateNormalizePeerNames skips already-migrated guilds", function()
            guildData.schemaVersion = 9
            guildData.knownPeers = {
                ["Stale-Realm"] = { version = "0.20.0", txCount = 1, lastSeen = 1 },
            }

            GBL:MigrateNormalizePeerNames(guildData)

            -- Already at schema 9 so the function returns without touching the table
            assert.is_not_nil(guildData.knownPeers["Stale-Realm"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cross-realm name matching
    ---------------------------------------------------------------------------

    describe("same-realm mixed-qualification matching", function()
        -- AceComm inconsistently qualifies same-realm sender names ("OfficerB"
        -- on one message, "OfficerB-TestRealm" on the next). CanonicalPeerKey
        -- collapses both to "OfficerB" so HandleAck / HandleSyncData see the
        -- same peer regardless of which form arrived. Cross-realm peers stay
        -- distinct (covered in connected-realm peer disambiguation tests).
        before_each(function()
            MockWoW.player.realm = "TestRealm"
        end)

        it("HandleAck accepts ACK when sender has realm but target does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes from same-realm-qualified name; canonicalizes to "OfficerB"
            GBL:HandleAck("OfficerB-TestRealm", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB%-TestRealm for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite realm suffix mismatch (same realm)")
        end)

        it("HandleAck accepts ACK when target has realm but sender does not", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            -- SYNC_REQUEST came from realm-qualified name on local realm
            GBL:HandleSyncRequest("OfficerB-TestRealm", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK comes without realm
            GBL:HandleAck("OfficerB", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerB for chunk 1") then
                    foundAck = true
                end
            end
            assert.is_true(foundAck,
                "ACK should be accepted despite missing realm suffix (same realm)")
        end)

        it("HandleSyncData accepts data from differently-qualified sender", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start receiving — receiveSource set with same-realm suffix
            GBL:RequestSync("OfficerB-TestRealm", 0)

            -- SYNC_DATA arrives without realm suffix (different channel format)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1,
                totalChunks = 1,
                transactions = {
                    {
                        type = "deposit", player = "Thrall",
                        itemID = 999, count = 1, timestamp = 2000,
                        scanTime = 2000, scannedBy = "OfficerB",
                        id = "deposit|Thrall|999|1|0|0:0",
                    },
                },
                moneyTransactions = {},
            })

            -- Should have stored the transaction (not rejected as wrong sender)
            assert.equals(1, #guildData.transactions)
        end)

        it("still rejects ACK from a completely different player", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- ACK from wrong person entirely
            GBL:HandleAck("OfficerC-Tichondrius", { chunk = 1 })

            -- Should NOT have processed the ACK
            local trail = GBL:GetAuditTrail()
            local foundAck = false
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from OfficerC") then
                    foundAck = true
                end
            end
            assert.is_false(foundAck,
                "ACK from different player should be rejected")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Connected-realm peer disambiguation
    ---------------------------------------------------------------------------

    describe("connected-realm peer disambiguation", function()
        local function buildHelloPayload()
            return GBL:Serialize({
                type = "HELLO",
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                version = GBL.version,
                txCount = 7,
                dataHash = "abc123",
                lastScanTime = 99999,
            })
        end

        before_each(function()
            MockWoW.player.realm = "TestRealm"
        end)

        it("cross-realm HELLO sender keys peer with realm suffix", function()
            MockWoW.serverTime = 100000
            local compressed = GBL._compressMessage(buildHelloPayload())
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-OtherRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Alice-OtherRealm"])
            assert.is_nil(peers["Alice"])
        end)

        it("two same-name peers on different realms stay distinct", function()
            MockWoW.serverTime = 100000
            local compressed = GBL._compressMessage(buildHelloPayload())
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-TestRealm")
            MockWoW.serverTime = 100050
            GBL:OnSyncMessage("GBL", compressed, "GUILD", "Alice-OtherRealm")

            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Alice"])             -- local realm peer
            assert.is_not_nil(peers["Alice-OtherRealm"])  -- cross-realm peer

            local count = 0
            for _ in pairs(peers) do count = count + 1 end
            assert.equals(2, count)
        end)

        it("IsGuildMemberOnline disambiguates same-name members across realms", function()
            MockWoW.guildRoster = {
                { name = "Alice", isOnline = true },             -- local realm Alice
                { name = "Alice-OtherRealm", isOnline = false }, -- cross-realm Alice
            }

            assert.is_true(GBL:IsGuildMemberOnline("Alice"))
            assert.is_true(GBL:IsGuildMemberOnline("Alice-TestRealm"))
            assert.is_false(GBL:IsGuildMemberOnline("Alice-OtherRealm"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- InitSync knownPeers seed consolidation (connected-realm follow-up)
    ---------------------------------------------------------------------------
    --
    -- Self-heals stuck-at-11 users: stale bare keys in knownPeers (left over
    -- from pre-v0.30.5 saved variables, or from the v0.30.5 schema-11
    -- premature-bump cold-roster bug) get re-canonicalized via playerRealms at
    -- session start, persistent state consolidates, runtime view is correct.

    describe("InitSync knownPeers seed consolidation", function()
        before_each(function()
            MockWoW.player.realm = "TestRealm"
            MockWoW.serverTime = 100000
            guildData.knownPeers = {}
            guildData.playerRealms = {}
            GBL:ResetSyncState()
        end)

        it("re-realms a stale bare cross-realm key via playerRealms", function()
            -- Setup: bare Katorriwl in knownPeers (from buggy schema-11),
            -- playerRealms knows the real realm.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99500,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            -- knownPeers consolidated: bare gone, qualified present
            assert.is_nil(guildData.knownPeers["Katorriwl"])
            assert.is_not_nil(guildData.knownPeers["Katorriwl-Stormrage"])
            assert.equals(5, guildData.knownPeers["Katorriwl-Stormrage"].txCount)

            -- syncState.peers seeded with the canonical key only
            local peers = GBL:GetAllPeers()
            assert.is_not_nil(peers["Katorriwl-Stormrage"])
            assert.is_nil(peers["Katorriwl"])
        end)

        it("collapses a bare same-realm key to bare (idempotent)", function()
            -- Bare entry that's actually a local-realm member: roster says local,
            -- helper re-realms then Ambiguate('guild') strips back to bare.
            guildData.knownPeers["Bob"] = {
                version = "0.30.5", txCount = 3, lastSeen = 99500,
            }
            guildData.playerRealms["Bob"] = "TestRealm"

            GBL:InitSync()

            -- Stays bare, no rewrite needed
            assert.is_not_nil(guildData.knownPeers["Bob"])
            assert.is_nil(guildData.knownPeers["Bob-TestRealm"])
            assert.is_not_nil(GBL:GetAllPeers()["Bob"])
        end)

        it("merges bare + qualified collision by recency", function()
            -- Both forms of the same character coexist in knownPeers (the bug).
            -- Bare form is older, qualified is newer; result should keep newer.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99000,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.5", txCount = 8, lastSeen = 99800,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            -- Only the qualified key survives, holding the newer record
            assert.is_nil(guildData.knownPeers["Katorriwl"])
            local kp = guildData.knownPeers["Katorriwl-Stormrage"]
            assert.is_not_nil(kp)
            assert.equals(8, kp.txCount)
            assert.equals("0.30.5", kp.version)
        end)

        it("keeps bare key when playerRealms has no entry for it", function()
            -- Departed peer or non-guildmate: no roster mapping, stays bare.
            guildData.knownPeers["Ghost"] = {
                version = "0.30.4", txCount = 1, lastSeen = 99000,
            }
            -- No playerRealms entry for Ghost

            GBL:InitSync()

            assert.is_not_nil(guildData.knownPeers["Ghost"])
            assert.is_not_nil(GBL:GetAllPeers()["Ghost"])
        end)

        it("syncState.peers seeding preserves recency on canonical-key collisions", function()
            -- When both legacy bare and canonical qualified forms exist in
            -- knownPeers (the upgrade scenario this PR addresses), both raw
            -- keys canonicalize to the same clean key. pairs() iteration order
            -- is undefined, so an unconditional write to syncState.peers[clean]
            -- could let an older snapshot overwrite a newer one in the runtime
            -- cache. The seed loop must recency-merge syncState.peers the same
            -- way it recency-merges knownPeers.
            --
            -- Direction A: bare is older, qualified is newer. Newer wins.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99000,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.5", txCount = 8, lastSeen = 99800,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            local peers = GBL:GetAllPeers()
            local newer = peers["Katorriwl-Stormrage"]
            assert.is_not_nil(newer)
            assert.equals(8, newer.txCount)
            assert.equals("0.30.5", newer.version)
            assert.equals(99800, newer.lastSeen)
            assert.is_nil(peers["Katorriwl"])
        end)

        it("syncState.peers seeding wins for the bare entry when bare is newer", function()
            -- Direction B: bare is newer, qualified is older. The recency
            -- check must pick bare's data even though both canonicalize to
            -- the qualified key. Without the check, pairs() ordering decides.
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.5", txCount = 12, lastSeen = 99900,
            }
            guildData.knownPeers["Katorriwl-Stormrage"] = {
                version = "0.30.4", txCount = 4, lastSeen = 99100,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:InitSync()

            local peers = GBL:GetAllPeers()
            local newer = peers["Katorriwl-Stormrage"]
            assert.is_not_nil(newer)
            assert.equals(12, newer.txCount)  -- bare's newer txCount won
            assert.equals("0.30.5", newer.version)
            assert.equals(99900, newer.lastSeen)
            assert.is_nil(peers["Katorriwl"])
        end)
    end)

    ---------------------------------------------------------------------------
    -- ConsolidatePeerKeys (runtime re-canonicalization)
    ---------------------------------------------------------------------------
    --
    -- Recovers from cold-startup states where stale bare entries got written
    -- to syncState.peers / knownPeers before playerRealms was populated or
    -- repaired. Called from GUILD_ROSTER_UPDATE in Core.lua.

    describe("ConsolidatePeerKeys", function()
        before_each(function()
            MockWoW.player.realm = "Tichondrius"
            MockWoW.serverTime = 100000
            guildData.knownPeers = {}
            guildData.playerRealms = {}
            GBL:ResetSyncState()
        end)

        it("rewrites stale bare entries in syncState.peers to qualified", function()
            -- Simulate the cold-startup outcome: bare Katorriwl wrote to
            -- syncState.peers because playerRealms was corrupt at the time.
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99500 }
            -- playerRealms is now clean (BuildRosterCache + repair has run)
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            assert.is_not_nil(syncPeers["Katorriwl-Stormrage"])
            assert.equals(5, syncPeers["Katorriwl-Stormrage"].txCount)
        end)

        it("rewrites stale bare entries in knownPeers too", function()
            guildData.knownPeers["Katorriwl"] = {
                version = "0.30.4", txCount = 5, lastSeen = 99500,
            }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(guildData.knownPeers["Katorriwl"])
            assert.is_not_nil(guildData.knownPeers["Katorriwl-Stormrage"])
        end)

        it("merges bare + qualified collisions by recency", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99000 }
            syncPeers["Katorriwl-Stormrage"] = { version = "0.30.5", txCount = 8, lastSeen = 99800 }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            local kp = syncPeers["Katorriwl-Stormrage"]
            assert.is_not_nil(kp)
            assert.equals(8, kp.txCount)  -- newer entry wins
        end)

        it("leaves bare same-realm entries bare (no-op)", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Bob"] = { version = "0.30.5", txCount = 3, lastSeen = 99500 }
            guildData.playerRealms["Bob"] = "Tichondrius"  -- local realm

            GBL:ConsolidatePeerKeys()

            assert.is_not_nil(syncPeers["Bob"])
            assert.is_nil(syncPeers["Bob-Tichondrius"])
        end)

        it("is idempotent (second run produces no further rewrites)", function()
            local syncPeers = GBL:GetAllPeers()
            syncPeers["Katorriwl"] = { version = "0.30.4", txCount = 5, lastSeen = 99500 }
            guildData.playerRealms["Katorriwl"] = "Stormrage"

            GBL:ConsolidatePeerKeys()
            GBL:ConsolidatePeerKeys()

            assert.is_nil(syncPeers["Katorriwl"])
            assert.is_not_nil(syncPeers["Katorriwl-Stormrage"])
        end)
    end)
end)
