------------------------------------------------------------------------
-- spec/sync_hello_spec.lua — Sync HELLO
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

describe("Sync HELLO", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- HELLO
    ---------------------------------------------------------------------------

    describe("BroadcastHello", function()
        it("sends HELLO with correct tx count and version", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("GBLSync", sent.prefix)
            assert.equals("GUILD", sent.distribution)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.equals(GBL.version, data.version)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, data.protocolVersion)
            assert.equals(0, data.txCount)
        end)

        it("includes correct tx count when guild has transactions", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 100 })
            table.insert(guildData.moneyTransactions, { type = "deposit", player = "X", timestamp = 100 })

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(2, data.txCount)
        end)

        it("respects cooldown — second HELLO within 60s is suppressed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()
            GBL:BroadcastHello()

            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("does nothing when sync is disabled", function()
            GBL.db.profile.sync.enabled = false
            GBL:BroadcastHello()
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("does not consume cooldown when GetGuildData returns nil", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Temporarily clear guild name so GetGuildData returns nil
            local savedName = MockWoW.guild.name
            MockWoW.guild.name = nil
            GBL._cachedGuildName = nil

            GBL:BroadcastHello()
            assert.equals(0, #MockAce.sentCommMessages)

            -- Restore guild name — HELLO should now succeed (cooldown not consumed)
            MockWoW.guild.name = savedName
            GBL._cachedGuildName = nil
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("force=true bypasses cooldown", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)

            -- Normal call blocked by cooldown
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)

            -- Force call bypasses cooldown
            GBL:BroadcastHello(true)
            assert.equals(2, #MockAce.sentCommMessages)
        end)

        it("suppresses heartbeat during active send", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            -- Send initial HELLO to establish lastHelloTime
            GBL:BroadcastHello()
            assert.equals(1, #MockAce.sentCommMessages)

            -- Add records and enter sending state
            for i = 1, 40 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P", timestamp = 3600 * 475100 + i,
                    scanTime = 3600 * 475100 + i, id = "bh:supptest:" .. i,
                })
            end
            guildData.seenTxHashes = guildData.seenTxHashes or {}
            for i = 1, 40 do
                guildData.seenTxHashes["bh:supptest:" .. i] = 3600 * 475100 + i
            end
            GBL:ResetHashCache()
            MockAce.sentCommMessages = {}
            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Advance time past cooldown but before keepalive threshold (280s)
            MockWoW.serverTime = MockWoW.serverTime + 120
            MockAce.sentCommMessages = {}
            GBL:BroadcastHello()

            -- Should be suppressed — no new GUILD messages
            local guildMsgs = 0
            for _, m in ipairs(MockAce.sentCommMessages) do
                if m.distribution == "GUILD" then guildMsgs = guildMsgs + 1 end
            end
            assert.equals(0, guildMsgs, "BroadcastHello should be suppressed during active send")
        end)

        it("sends keepalive HELLO during sync after 280s", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            -- Enter sending state
            for i = 1, 40 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P", timestamp = 3600 * 475100 + i,
                    scanTime = 3600 * 475100 + i, id = "bh:keepalive:" .. i,
                })
            end
            guildData.seenTxHashes = guildData.seenTxHashes or {}
            for i = 1, 40 do
                guildData.seenTxHashes["bh:keepalive:" .. i] = 3600 * 475100 + i
            end
            GBL:ResetHashCache()
            MockAce.sentCommMessages = {}
            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Advance time past keepalive threshold (280s)
            MockWoW.serverTime = MockWoW.serverTime + 290
            MockAce.sentCommMessages = {}
            GBL:BroadcastHello()

            -- Should send keepalive HELLO on GUILD
            local guildMsgs = 0
            for _, m in ipairs(MockAce.sentCommMessages) do
                if m.distribution == "GUILD" then guildMsgs = guildMsgs + 1 end
            end
            assert.equals(1, guildMsgs, "BroadcastHello should send keepalive after 280s")
        end)

        it("force=true bypasses sync suppression", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            -- Enter sending state
            for i = 1, 40 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P", timestamp = 3600 * 475100 + i,
                    scanTime = 3600 * 475100 + i, id = "bh:forcetest:" .. i,
                })
            end
            guildData.seenTxHashes = guildData.seenTxHashes or {}
            for i = 1, 40 do
                guildData.seenTxHashes["bh:forcetest:" .. i] = 3600 * 475100 + i
            end
            GBL:ResetHashCache()
            MockAce.sentCommMessages = {}
            GBL:HandleSyncRequest("PeerA", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Advance time past cooldown but before keepalive
            MockWoW.serverTime = MockWoW.serverTime + 120
            MockAce.sentCommMessages = {}
            GBL:BroadcastHello(true)

            -- Force should bypass sync suppression
            local guildMsgs = 0
            for _, m in ipairs(MockAce.sentCommMessages) do
                if m.distribution == "GUILD" then guildMsgs = guildMsgs + 1 end
            end
            assert.equals(1, guildMsgs, "force=true should bypass sync suppression")
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleHello
    ---------------------------------------------------------------------------

    describe("HandleHello", function()
        it("updates peer list with sender info", function()
            GBL:HandleHello("OfficerB", {
                version = "0.5.0",
                txCount = 10,
                lastScanTime = 1000,
            })

            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.equals("0.5.0", peers["OfficerB"].version)
            assert.equals(10, peers["OfficerB"].txCount)
        end)

        it("triggers SYNC_REQUEST when remote has more transactions", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 50,
                lastScanTime = 1000,
            })

            -- HELLO reply + SYNC_REQUEST both sent
            assert.is_true(#MockAce.sentCommMessages >= 2)

            -- Find the SYNC_REQUEST among sent messages
            local foundRequest = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "SYNC_REQUEST" then
                    assert.equals("WHISPER", sent.distribution)
                    assert.equals("OfficerB", sent.target)
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest)
        end)

        it("does NOT trigger sync when counts are equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- Only a HELLO response (new peer), no SYNC_REQUEST
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT trigger sync when remote has fewer", function()
            table.insert(guildData.transactions, { type = "deposit", player = "X", timestamp = 100 })
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- Only a HELLO response (new peer), no SYNC_REQUEST
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("sends WHISPER reply to broadcast HELLO sender", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
            })

            -- HELLO reply sent immediately via WHISPER
            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.is_true(data.isReply)
        end)

        it("sends individual WHISPER replies to multiple broadcast HELLOs", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleHello("OfficerB", { version = GBL.version, txCount = 0, lastScanTime = 100 })
            GBL:HandleHello("OfficerC", { version = GBL.version, txCount = 0, lastScanTime = 200 })
            GBL:HandleHello("OfficerD", { version = GBL.version, txCount = 0, lastScanTime = 300 })

            -- All three are in peer list
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])
            assert.is_not_nil(peers["OfficerC"])
            assert.is_not_nil(peers["OfficerD"])

            -- Each peer gets their own WHISPER reply (3 total)
            assert.equals(3, #MockAce.sentCommMessages)
            for _, sent in ipairs(MockAce.sentCommMessages) do
                assert.equals("WHISPER", sent.distribution)
                local ok, data = GBL:Deserialize(sent.text)
                assert.is_true(ok)
                assert.equals("HELLO", data.type)
                assert.is_true(data.isReply)
            end
        end)

        it("does NOT reply to a HELLO with isReply=true", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                lastScanTime = 1000,
                isReply = true,
            })

            -- Peer is registered
            local peers = GBL:GetSyncPeers()
            assert.is_not_nil(peers["OfficerB"])

            -- No reply sent (isReply prevents ping-pong)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("suppresses reply to known peer when hash unchanged", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- First HELLO from OfficerB (now known) — should reply
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 1000,
            })
            assert.equals(1, #MockAce.sentCommMessages)
            MockAce.sentCommMessages = {}

            -- Second broadcast HELLO from same peer — hash unchanged, suppress reply
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 2000,
            })

            -- Should NOT reply (hash-gated suppression)
            local foundReply = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "HELLO" and data.isReply then
                    foundReply = true
                end
            end
            assert.is_false(foundReply, "Hash unchanged — reply should be suppressed")
        end)

        -- This used to require debugChat, because the suppression was recorded
        -- at DEBUG and nothing else. That is what #90 was about: the entry
        -- never reached a shared capture, so a guildmate reporting a stall
        -- could not hand over the one fact that explains it. It rides the INFO
        -- round line now, with no setting to turn on first.
        it("records a hash-unchanged reply suppression without debug enabled", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- First HELLO establishes lastHelloReplyHash for OfficerB (reply sent).
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 1000,
            })
            MockAce.sentCommMessages = {}

            -- Second broadcast HELLO with unchanged hash: reply is suppressed and
            -- the diagnostic should fire (this is the suspected silent deadlock
            -- condition when the peer is also behind us).
            GBL:HandleHello("OfficerB", {
                version = GBL.version, txCount = 0, lastScanTime = 2000,
            })

            -- No reply went out this round.
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                assert.is_false(ok and data.type == "HELLO" and data.isReply == true)
            end

            -- Recorded at INFO, which is the only level AuditCapture keeps.
            local found = false
            for _, e in ipairs(GBL:GetLog("sync")) do
                if e.level == "INFO"
                    and e.message:find("HELLO round OfficerB:", 1, true)
                    and e.message:find("reply=hash-suppressed", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected the round line to record the hash-gate suppression at INFO")
        end)

        it("advertises the sync floor on broadcast HELLO", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_string(GBL.MIN_SYNC_VERSION)
            assert.equals(GBL.MIN_SYNC_VERSION, data.minSyncVersion)
        end)

        it("advertises the sync floor on HELLO reply", function()
            -- Both builders, because a peer that only ever sees our reply must
            -- still learn our floor. The wire-contract parity test guards the
            -- pair from drifting apart.
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:SendHelloReply("OfficerB")

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_string(GBL.MIN_SYNC_VERSION)
            assert.equals(GBL.MIN_SYNC_VERSION, data.minSyncVersion)
        end)

        it("SendHelloReply payload includes isReply=true", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:SendHelloReply("OfficerB")

            assert.equals(1, #MockAce.sentCommMessages)
            local sent = MockAce.sentCommMessages[1]
            assert.equals("WHISPER", sent.distribution)
            assert.equals("OfficerB", sent.target)

            local ok, data = GBL:Deserialize(sent.text)
            assert.is_true(ok)
            assert.equals("HELLO", data.type)
            assert.is_true(data.isReply)
            assert.equals(GBL.version, data.version)
            assert.equals(GBL.SYNC_PROTOCOL_VERSION, data.protocolVersion)
        end)

        it("warns on version mismatch and refuses sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = "99.0.0",
                txCount = 999,
                lastScanTime = 1000,
            })

            -- Should NOT send a SYNC_REQUEST despite high txCount (HELLO response is OK)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
            -- Refusals say "refused" plus the reason. Before v0.37.0 the only
            -- reason was "version mismatch"; the floor gave refusals a reason
            -- vocabulary, and this peer advertises no floor of its own.
            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message:find("refused", 1, true) then found = true end
            end
            assert.is_true(found, "expected a refusal entry in the sync log")
        end)

        it("refuses sync even on same major but different minor version", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            local differentMinor = "0.99.0"
            assert.not_equals(GBL.version, differentMinor)
            GBL:HandleHello("OfficerB", {
                version = differentMinor,
                txCount = 999,
                lastScanTime = 1000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
            local found = false
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message:find("refused", 1, true) then found = true end
            end
            assert.is_true(found, "expected a refusal entry in the sync log")
        end)

        it("dev build refuses HELLO from production peer", function()
            -- Capture the production version BEFORE setting the override so
            -- the test is independent of the source file's VERSION literal.
            local productionVersion = GBL:GetSyncVersion():match("^([^-]+)")

            -- Re-init so self.version captures the dev suffix.
            GBL._testDevBuild = "sync"
            GBL:OnInitialize()
            assert.equals(productionVersion .. "-dev.sync", GBL.version)

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = productionVersion,
                txCount = 999,
                lastScanTime = 1000,
            })

            -- No SYNC_REQUEST sent.
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, e in ipairs(trail) do
                if e.message:find("refused", 1, true)
                    and e.message:find("-dev.sync", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected version-mismatch audit entry naming the dev suffix")
        end)

        it("HELLO carrying a -dev.<id> version is rejected", function()
            -- Use a sentinel id distinct from any plausible real DEV_BUILD
            -- value so the test is robust whether the source file currently
            -- has DEV_BUILD set (dogfooding) or nil (production state).
            local productionVersion = GBL:GetSyncVersion():match("^([^-]+)")
            local foreignDevVersion = productionVersion .. "-dev.production-test-sentinel-xyz"
            assert.not_equals(GBL.version, foreignDevVersion)

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:HandleHello("OfficerB", {
                version = foreignDevVersion,
                txCount = 999,
                lastScanTime = 1000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end

            local trail = GBL:GetAuditTrail()
            local found = false
            for _, e in ipairs(trail) do
                if e.message:find("refused", 1, true)
                    and e.message:find("-dev.production-test-sentinel-xyz", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected version-mismatch audit entry naming the foreign dev suffix")
        end)

        it("accepts a peer above the floor that advertises one", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL.version = "0.40.0"

            for i = 1, 5 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "floorok" .. i .. ":0",
                })
            end

            GBL:HandleHello("OfficerB", {
                version = "0.38.0",
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = GBL:GetDataHash(guildData) + 1,
                lastScanTime = 2000,
            })

            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then foundRequest = true end
            end
            assert.is_true(foundRequest,
                "a peer inside the compatible range should be synced with")
        end)

        it("triggers sync when hash differs and counts are equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 5 local transactions
            for i = 1, 5 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "local" .. i .. ":0",
                })
            end

            -- Remote has same count but different hash
            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,  -- different hash
                lastScanTime = 2000,
            })

            -- Should send SYNC_REQUEST despite equal counts
            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest,
                "should request sync when hash differs, even with equal counts")
        end)

        it("skips request when hash differs but local has more (superset skip)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 10 local transactions
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "localmore" .. i .. ":0",
                })
            end

            -- Remote has fewer records and different hash
            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,
                lastScanTime = 2000,
            })

            -- Should NOT request sync — local is likely a superset
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type,
                        "should skip sync request when local has more records (superset skip)")
                end
            end

            -- Audit trail should explain why
            local found = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=superset-skip", 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "the round line should record the superset skip")
        end)

        it("re-nudges a behind peer whose reply was hash-gate suppressed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "localmore" .. i .. ":0",
                })
            end
            local localHash = GBL:GetDataHash(guildData)
            local hello = {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,
            }

            -- First HELLO: peer behind, reply sent, registers lastHelloReplyHash.
            hello.lastScanTime = 2000
            GBL:HandleHello("OfficerB", hello)
            MockAce.sentCommMessages = {}

            -- Second HELLO: hash unchanged so the normal reply is suppressed, but
            -- because the peer is behind us the superset branch re-nudges.
            hello.lastScanTime = 3000
            GBL:HandleHello("OfficerB", hello)

            local nudged = false
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "HELLO" and data.isReply
                    and sent.distribution == "WHISPER" and sent.target == "OfficerB" then
                    nudged = true
                end
            end
            assert.is_true(nudged, "behind peer should be re-nudged with a HELLO reply")

            local audited = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("Nudged behind peer", 1, true) then
                    audited = true
                end
            end
            assert.is_true(audited, "audit trail should record the nudge")
        end)

        it("throttles superset re-nudges to one per window per peer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "localmore" .. i .. ":0",
                })
            end
            local localHash = GBL:GetDataHash(guildData)
            local hello = {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,
            }

            -- First HELLO sends a reply; second triggers the (throttled) nudge.
            hello.lastScanTime = 2000
            GBL:HandleHello("OfficerB", hello)
            hello.lastScanTime = 3000
            GBL:HandleHello("OfficerB", hello)
            MockAce.sentCommMessages = {}

            -- Third HELLO immediately (same server time, within the throttle):
            -- no second nudge.
            hello.lastScanTime = 4000
            GBL:HandleHello("OfficerB", hello)

            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                assert.is_false(ok and data.type == "HELLO" and data.isReply == true,
                    "no second nudge within the throttle window")
            end
        end)

        it("does not nudge on first contact (reply already sent)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            for i = 1, 10 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "localmore" .. i .. ":0",
                })
            end
            local localHash = GBL:GetDataHash(guildData)

            -- Single HELLO from a never-seen behind peer: the reply gate sends a
            -- normal reply (replyDecision "sent"), so the superset branch must not
            -- also fire a nudge. Exactly one HELLO reply, no "Nudged" audit line.
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = localHash + 1,
                lastScanTime = 2000,
            })

            local replyCount = 0
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "HELLO" and data.isReply then
                    replyCount = replyCount + 1
                end
            end
            assert.equals(1, replyCount, "first contact sends exactly one reply, no extra nudge")

            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message then
                    assert.is_nil(entry.message:find("Nudged behind peer", 1, true),
                        "no nudge on first contact")
                end
            end
        end)

        it("skips sync when hash matches and counts match", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add 3 local transactions
            for i = 1, 3 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "match" .. i .. ":0",
                })
            end

            local localHash = GBL:GetDataHash(guildData)
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 3,
                dataHash = localHash,  -- same hash
                lastScanTime = 2000,
            })

            -- No SYNC_REQUEST (datasets identical)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("falls back to count when no hash (backward compat)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Remote has more, no dataHash
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 50,
                lastScanTime = 2000,
            })

            -- Should still request sync via count comparison
            local foundRequest = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_REQUEST" then
                    foundRequest = true
                end
            end
            assert.is_true(foundRequest,
                "should request sync via count when no hash present")
        end)

        it("does NOT sync when no hash and counts equal", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- No dataHash, same count
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 0,
                lastScanTime = 2000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT sync when hash differs but already receiving", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Start a receive (blocks new RequestSync)
            GBL:RequestSync("OfficerC", 0)
            MockAce.sentCommMessages = {}

            -- Hash mismatch from different peer
            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = 99999,
                lastScanTime = 2000,
            })

            -- Should NOT send SYNC_REQUEST (already receiving from OfficerC)
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)

        it("does NOT sync when hash differs but autoSync disabled", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL.db.profile.sync.autoSync = false

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 5,
                dataHash = 99999,
                lastScanTime = 2000,
            })

            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok then
                    assert.not_equals("SYNC_REQUEST", data.type)
                end
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- HELLO round line (issue #90)
    --
    -- Every processed HELLO writes exactly one INFO line saying what the round
    -- decided and what the reply gate did. Before it, the decisions that
    -- explain a stalled peer were DEBUG, and DEBUG never reaches a shared
    -- capture at all: Logger drops it ahead of the capture tap, and
    -- AuditCapture rejects it again unconditionally. A guildmate's capture of
    -- a real stall showed HELLOs arriving and nothing else, which reads
    -- exactly like the whisper never landing.
    --
    -- One line, not several, because it replaces the per-round chatter it
    -- folds in. Promoting the three DEBUG lines instead would have pushed
    -- per-round capture cost up against a 1000-entry cap that one large send
    -- already eats half of.
    ---------------------------------------------------------------------------

    describe("HELLO round line", function()
        local function hello(fields)
            fields = fields or {}
            return {
                type = "HELLO",
                version = fields.version or GBL.version,
                minSyncVersion = fields.minSyncVersion or GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = fields.txCount or 0,
                dataHash = fields.dataHash,
                lastScanTime = fields.lastScanTime or 1000,
                isReply = fields.isReply,
            }
        end

        local function seed(n)
            for i = 1, n do
                local ts = (1000 + i) * 3600
                table.insert(guildData.transactions, {
                    type = "deposit", player = "P" .. i, tab = 1, itemID = 100 + i,
                    classID = 0, subclassID = 0, count = 1,
                    timestamp = ts, id = "round" .. i .. ":277:0",
                    _occurrence = 0, scanTime = ts, scannedBy = "OfficerA",
                })
            end
        end

        -- Exactly one, every time. A round that emitted two would mean a path
        -- fell through an exit without returning, and a round that emitted
        -- none is the silence this issue exists to remove.
        local function roundLine()
            local found = {}
            for _, e in ipairs(GBL:GetAuditTrail()) do
                if e.message and e.message:find("HELLO round ", 1, true) then
                    found[#found + 1] = e
                end
            end
            assert.equals(1, #found,
                "expected exactly one round line, got " .. #found)
            assert.equals("INFO", found[1].level,
                "the round line has to be INFO or a shared capture never sees it")
            return found[1].message
        end

        before_each(function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:ClearLog("sync")
        end)

        it("reports a request with its trigger", function()
            seed(1)
            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=requested", 1, true))
            assert.is_truthy(line:find("trigger=hash-mismatch", 1, true))
            assert.is_truthy(line:find("reply=sent", 1, true))
            assert.is_truthy(line:find("local=1tx", 1, true))
            assert.is_truthy(line:find("remote=99tx", 1, true))
        end)

        -- The other trigger: a peer too old to advertise a hash at all, where
        -- the only thing to compare is the record count.
        it("reports a request triggered by count when the peer sends no hash", function()
            seed(1)
            GBL:HandleHello("OfficerB", hello{ txCount = 99 })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=requested", 1, true))
            assert.is_truthy(line:find("trigger=count-no-hash", 1, true))
        end)

        it("reports identical datasets", function()
            seed(2)
            GBL:HandleHello("OfficerB", hello{
                txCount = 2, dataHash = GBL:GetDataHash(guildData),
            })

            assert.is_truthy(roundLine():find("verdict=identical", 1, true))
        end)

        -- The cost argument this whole change rests on. A processed round used
        -- to write three INFO entries (the arrival, the hash compare, the
        -- verdict), and every one lands in a 1000-entry capture buffer that a
        -- single large send already eats about 40 percent of. Promoting the
        -- DEBUG diagnostics on top of that would have made it four. A round
        -- that also whispers still writes the send line, which is a record of
        -- an outgoing action rather than of this round's reasoning.
        it("costs one audit entry for a round that sends nothing", function()
            seed(2)
            GBL:HandleHello("OfficerB", hello{
                txCount = 2, dataHash = GBL:GetDataHash(guildData), isReply = true,
            })

            assert.equals(1, #GBL:GetAuditTrail(),
                "a round that sends nothing should write exactly one line")
        end)

        -- reply=sent is a claim about a whisper, and SendHelloReply gives up
        -- quietly on three paths: sync disabled, no guild data, and a target
        -- the roster says is offline. A round line asserting a reply that
        -- never left is worse than no round line, because the whole point is
        -- that a capture can be trusted about what this client did.
        it("does not claim a reply was sent when the whisper was blocked", function()
            seed(1)
            local orig = GBL.IsGuildMemberOnline
            GBL.IsGuildMemberOnline = function() return false end
            local ok, err = pcall(function()
                GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })
            end)
            GBL.IsGuildMemberOnline = orig
            if not ok then error(err, 0) end

            local line = roundLine()
            assert.is_truthy(line:find("reply=send-failed", 1, true))
            assert.is_nil(line:find("reply=sent", 1, true))
        end)

        it("names the peer and its version", function()
            seed(1)
            GBL:HandleHello("OfficerB", hello{
                txCount = 99, dataHash = 12345, version = "0.37.99",
            })

            local line = roundLine()
            assert.is_truthy(line:find("HELLO round OfficerB:", 1, true))
            assert.is_truthy(line:find("peer=v0.37.99", 1, true))
        end)

        it("reports a superset skip", function()
            seed(5)
            GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=superset-skip", 1, true))
            assert.is_truthy(line:find("local=5tx", 1, true))
            assert.is_truthy(line:find("remote=1tx", 1, true))
        end)

        -- The correlation the third DEBUG line existed to record: we are
        -- ahead, our data has not moved, so the hash gate stopped telling this
        -- peer anything and they never ask. The verdict says the nudge fired.
        it("reports a superset nudge and the suppressed reply that caused it", function()
            seed(5)
            GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=superset-nudge", 1, true))
            assert.is_truthy(line:find("reply=hash-suppressed", 1, true))
        end)

        -- The nudge fires only when the reply gate suppressed us AND the
        -- whisper actually leaves. A peer the roster says is offline gets the
        -- throttle stamped anyway (retrying every heartbeat at someone we
        -- cannot reach is what the throttle is for), but the round must not
        -- claim a nudge that never went out.
        it("does not claim a nudge when the whisper could not be sent", function()
            seed(5)
            GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })
            GBL:ClearLog("sync")

            local orig = GBL.IsGuildMemberOnline
            GBL.IsGuildMemberOnline = function() return false end
            local ok, err = pcall(function()
                GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })
            end)
            GBL.IsGuildMemberOnline = orig
            if not ok then error(err, 0) end

            local line = roundLine()
            assert.is_truthy(line:find("verdict=superset-skip", 1, true))
            assert.is_nil(line:find("verdict=superset-nudge", 1, true))
            for _, e in ipairs(GBL:GetAuditTrail()) do
                assert.is_nil(e.message:find("Nudged behind peer", 1, true),
                    "no nudge line for a whisper that never left")
            end
        end)

        it("reports a version refusal", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", hello{
                version = "0.20.0", minSyncVersion = "0.20.0",
            })

            assert.is_truthy(roundLine():find("verdict=refused-version", 1, true))
        end)

        -- An incompatible peer is answered once per session and then left in
        -- silence. The repeat rounds still have to say what they decided, or a
        -- deliberately quiet client is indistinguishable from a broken one:
        -- that was the whole DEBUG problem, and the repeat refusal was one of
        -- the three lines that had it.
        it("reports the repeat refusal as a suppressed reply", function()
            GBL.version = "0.40.0"
            GBL:HandleHello("OfficerB", hello{
                version = "0.20.0", minSyncVersion = "0.20.0",
            })
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{
                version = "0.20.0", minSyncVersion = "0.20.0",
            })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=refused-version", 1, true))
            assert.is_truthy(line:find("reply=suppressed", 1, true))
        end)

        it("reports a round that found no guild data", function()
            local orig = GBL.GetGuildData
            GBL.GetGuildData = function() return nil end
            local ok, err = pcall(function()
                GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })
            end)
            GBL.GetGuildData = orig
            if not ok then error(err, 0) end

            local line = roundLine()
            assert.is_truthy(line:find("verdict=no-guild-data", 1, true))
            -- Truthful by structure: SendHelloReply gives up on the same
            -- missing guild data, so the reply genuinely did not go out.
            assert.is_truthy(line:find("reply=send-failed", 1, true))
        end)

        it("reports a sync skipped by the combat cooldown", function()
            seed(1)
            GBL:RequestSync("OfficerC", 0)
            GBL:OnCombatStart()
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_truthy(roundLine():find("verdict=paused-combat", 1, true))
        end)

        it("reports a round that needed no sync", function()
            seed(2)
            -- Same count, no hash advertised: nothing to compare, nothing to do.
            GBL:HandleHello("OfficerB", hello{ txCount = 2 })

            assert.is_truthy(roundLine():find("verdict=no-sync-needed", 1, true))
        end)

        it("reports a peer left alone on its busy cooldown", function()
            seed(1)
            GBL:HandleBusy("OfficerB", {})
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_truthy(roundLine():find("verdict=busy-cooldown", 1, true))
        end)

        it("reports a sync deferred by combat", function()
            seed(1)
            local origICL = _G.InCombatLockdown
            _G.InCombatLockdown = function() return true end
            local ok, err = pcall(function()
                GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })
            end)
            _G.InCombatLockdown = origICL
            if not ok then error(err, 0) end

            assert.is_truthy(roundLine():find("verdict=combat-deferred", 1, true))
        end)

        it("reports a sync skipped by the zone cooldown", function()
            seed(1)
            GBL:RequestSync("OfficerC", 0)
            GBL:OnLoadingScreenStart()
            GBL:FinishReceiving("OfficerC")
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_truthy(roundLine():find("verdict=paused-zone", 1, true))
        end)

        -- One round, two facts: the reply gate saw a live session and stayed
        -- quiet, and the request was dropped for the same reason.
        it("reports a round that landed mid-receive", function()
            seed(1)
            GBL:RequestSync("OfficerC", 0)
            GBL:ClearLog("sync")

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            local line = roundLine()
            assert.is_truthy(line:find("verdict=receiving", 1, true))
            assert.is_truthy(line:find("reply=sync-active", 1, true))
        end)

        it("reports autoSync being off", function()
            seed(1)
            GBL.db.profile.sync.autoSync = false

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_truthy(roundLine():find("verdict=autosync-off", 1, true))
        end)

        it("marks the reply gate as not applicable on a reply HELLO", function()
            seed(1)
            GBL:HandleHello("OfficerB", hello{
                txCount = 99, dataHash = 12345, isReply = true,
            })

            assert.is_truthy(roundLine():find("reply=n/a", 1, true))
        end)

        -- The bucket count is a diagnostic, and computing one costs a walk over
        -- every record. It rides along only when the cache already has it.
        it("omits the bucket count when the cache is cold", function()
            seed(1)
            GBL:ResetHashCache()

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_nil(roundLine():find("buckets=", 1, true))
        end)

        it("carries the bucket count when the cache is warm", function()
            seed(1)
            GBL:GetBucketHashes(guildData)

            GBL:HandleHello("OfficerB", hello{ txCount = 99, dataHash = 12345 })

            assert.is_truthy(roundLine():find("buckets=1", 1, true))
        end)

        it("computes no bucket hashes of its own", function()
            seed(3)
            GBL:ResetHashCache()

            local calls = 0
            local orig = GBL.ComputeBucketHashes
            GBL.ComputeBucketHashes = function(...)
                calls = calls + 1
                return orig(...)
            end
            local ok, err = pcall(function()
                GBL:HandleHello("OfficerB", hello{ txCount = 1, dataHash = 12345 })
            end)
            GBL.ComputeBucketHashes = orig
            if not ok then error(err, 0) end

            assert.equals(0, calls,
                "an inbound HELLO must not walk the whole history to print a count")
        end)
    end)

    ---------------------------------------------------------------------------
    -- HandleHello while busy
    --
    -- These blocks used to pin a scored pending-peer queue. A HELLO we
    -- cannot act on right now is dropped instead: the peer keeps
    -- advertising on its own heartbeat, and we answer once we are free.
    -- The free-agent pairing block above covers the replacement.
    ---------------------------------------------------------------------------

    describe("HandleHello while already receiving", function()
        it("does not start a second sync", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            GBL:HandleHello("PeerB", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 999,
                isReply = true,
            })

            assert.equals("PeerA", GBL:GetSyncStatus().receiveSource)
        end)

        it("logs why it skipped so a stall is diagnosable", function()
            GBL:UpdatePeer("PeerA", { version = GBL.version, txCount = 10, dataHash = 123 })
            GBL:RequestSync("PeerA", 0)

            GBL:HandleHello("PeerB", {
                version = GBL.version,
                minSyncVersion = GBL.MIN_SYNC_VERSION,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
                txCount = 20,
                dataHash = 999,
                isReply = true,
            })

            local found = false
            for _, entry in ipairs(GBL:GetAuditTrail()) do
                if entry.message and entry.message:find("verdict=receiving", 1, true)
                    and entry.message:find("from=PeerA", 1, true) then
                    found = true
                end
            end
            assert.is_true(found,
                "the round line should say the round was dropped mid-receive, and by whom")
        end)
    end)

    ---------------------------------------------------------------------------
    -- HELLO-driven sync initiation
    ---------------------------------------------------------------------------

    describe("sync initiation from HELLO", function()
        it("requests during the HELLO, not behind a timer", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:HandleHello("PeerA", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                txCount = 50,
                dataHash = 999,
                isReply = true,
            })

            -- Asserted with no timer fired in between, which is also the guard
            -- against the deferral coming back: anything that puts the request
            -- behind a timer again leaves this false. The decision to sync and
            -- the request being one event is what makes a capture readable,
            -- since a deferred request could be dropped with nothing logged.
            assert.is_true(GBL:GetSyncStatus().receiving)
            assert.equals("PeerA", GBL:GetSyncStatus().receiveSource)

            local requests = 0
            for _, sent in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(sent.text)
                if ok and data.type == "SYNC_REQUEST" and sent.target == "PeerA" then
                    requests = requests + 1
                end
            end
            assert.equals(1, requests)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Access control propagation via HELLO
    ---------------------------------------------------------------------------

    describe("HELLO access control propagation", function()
        it("includes accessControl in HELLO payload", function()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
                configuredBy = "GM-TestRealm",
                configuredAt = 1000,
            }

            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_not_nil(data.accessControl)
            assert.equals(2, data.accessControl.rankThreshold)
            assert.equals("sync_only", data.accessControl.restrictedMode)
            assert.equals("GM-TestRealm", data.accessControl.configuredBy)
            assert.equals(1000, data.accessControl.configuredAt)
        end)

        it("updates local accessControl from newer remote HELLO", function()
            guildData.accessControl = {
                rankThreshold = nil,
                restrictedMode = nil,
                configuredBy = nil,
                configuredAt = 0,
            }

            GBL:HandleHello("GMPlayer", {
                version = GBL.version,
                txCount = 0,
                accessControl = {
                    rankThreshold = 3,
                    restrictedMode = "own_transactions",
                    configuredBy = "GMPlayer-TestRealm",
                    configuredAt = 5000,
                },
            })

            assert.equals(3, guildData.accessControl.rankThreshold)
            assert.equals("own_transactions", guildData.accessControl.restrictedMode)
            assert.equals("GMPlayer-TestRealm", guildData.accessControl.configuredBy)
            assert.equals(5000, guildData.accessControl.configuredAt)
        end)

        it("does not overwrite with older accessControl", function()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
                configuredBy = "GM-TestRealm",
                configuredAt = 9000,
            }

            GBL:HandleHello("OtherPlayer", {
                version = GBL.version,
                txCount = 0,
                accessControl = {
                    rankThreshold = 5,
                    restrictedMode = "own_transactions",
                    configuredBy = "OtherGM-TestRealm",
                    configuredAt = 1000,
                },
            })

            -- Should not have changed
            assert.equals(2, guildData.accessControl.rankThreshold)
            assert.equals("sync_only", guildData.accessControl.restrictedMode)
            assert.equals(9000, guildData.accessControl.configuredAt)
        end)

        it("ignores HELLO without accessControl field", function()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
                configuredBy = "GM-TestRealm",
                configuredAt = 5000,
            }

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
            })

            -- Should not have changed
            assert.equals(2, guildData.accessControl.rankThreshold)
            assert.equals("sync_only", guildData.accessControl.restrictedMode)
        end)

        it("ignores accessControl with zero configuredAt", function()
            guildData.accessControl = {
                rankThreshold = 2,
                restrictedMode = "sync_only",
                configuredBy = "GM-TestRealm",
                configuredAt = 5000,
            }

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                accessControl = {
                    rankThreshold = nil,
                    restrictedMode = nil,
                    configuredBy = nil,
                    configuredAt = 0,
                },
            })

            -- Should not have changed (zero configuredAt is treated as unconfigured)
            assert.equals(2, guildData.accessControl.rankThreshold)
        end)

        it("fires GBL_ACCESS_CONTROL_CHANGED on update", function()
            guildData.accessControl = {
                rankThreshold = nil,
                configuredAt = 0,
            }

            GBL:HandleHello("GMPlayer", {
                version = GBL.version,
                txCount = 0,
                accessControl = {
                    rankThreshold = 1,
                    restrictedMode = "sync_only",
                    configuredBy = "GMPlayer-TestRealm",
                    configuredAt = 1000,
                },
            })

            -- Check that SendMessage was called with the change event
            local found = false
            for _, msg in ipairs(MockAce.sentMessages) do
                if msg.message == "GBL_ACCESS_CONTROL_CHANGED" then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected GBL_ACCESS_CONTROL_CHANGED message")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Sort access (sortAccess) propagation via HELLO
    ---------------------------------------------------------------------------

    describe("HELLO sort access propagation", function()
        -- A configured two-tier policy: sort tier granted to rank<=2 plus one
        -- named delegate. updatedAt>0 marks it as GM-configured.
        local function configured(updatedAt)
            return {
                write = { rankThreshold = nil, delegates = {} },
                sort  = { rankThreshold = 2, delegates = { ["Officer-TestRealm"] = true } },
                updatedBy = "GM-TestRealm",
                updatedAt = updatedAt,
            }
        end

        it("includes sortAccess in HELLO payload when configured", function()
            guildData.sortAccess = configured(5000)

            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_not_nil(data.sortAccess)
            assert.equals(2, data.sortAccess.sort.rankThreshold)
            assert.is_true(data.sortAccess.sort.delegates["Officer-TestRealm"])
            assert.equals(5000, data.sortAccess.updatedAt)
        end)

        it("omits sortAccess from HELLO when unconfigured (updatedAt 0)", function()
            guildData.sortAccess = {
                write = { rankThreshold = nil, delegates = {} },
                sort  = { rankThreshold = nil, delegates = {} },
                updatedAt = 0,
            }

            GBL:BroadcastHello()

            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_nil(data.sortAccess)
        end)

        it("updates local sortAccess from a newer remote HELLO", function()
            guildData.sortAccess = configured(1000)

            GBL:HandleHello("GMPlayer", {
                version = GBL.version,
                txCount = 0,
                sortAccess = {
                    write = { rankThreshold = nil, delegates = {} },
                    sort  = { rankThreshold = 1, delegates = {} },
                    updatedBy = "GMPlayer-TestRealm",
                    updatedAt = 5000,
                },
            })

            assert.equals(5000, guildData.sortAccess.updatedAt)
            assert.equals(1, guildData.sortAccess.sort.rankThreshold)
            -- Whole policy replaced (not merged): the old delegate is gone.
            assert.is_nil(guildData.sortAccess.sort.delegates["Officer-TestRealm"])
        end)

        it("does not overwrite with an older sortAccess", function()
            guildData.sortAccess = configured(9000)

            GBL:HandleHello("OtherPlayer", {
                version = GBL.version,
                txCount = 0,
                sortAccess = {
                    write = { rankThreshold = 4, delegates = {} },
                    sort  = { rankThreshold = 4, delegates = {} },
                    updatedBy = "OtherGM-TestRealm",
                    updatedAt = 1000,
                },
            })

            assert.equals(9000, guildData.sortAccess.updatedAt)
            assert.equals(2, guildData.sortAccess.sort.rankThreshold)
        end)

        it("normalizes a legacy flat policy arriving on the wire", function()
            guildData.sortAccess = configured(1000)

            -- Older peer sends the pre-two-tier flat shape (top-level
            -- rankThreshold/delegates). It must migrate into the write tier.
            GBL:HandleHello("OldPeer", {
                version = GBL.version,
                txCount = 0,
                sortAccess = {
                    rankThreshold = 3,
                    delegates = { ["Legacy-TestRealm"] = true },
                    updatedBy = "OldGM-TestRealm",
                    updatedAt = 6000,
                },
            })

            assert.equals(6000, guildData.sortAccess.updatedAt)
            assert.equals(3, guildData.sortAccess.write.rankThreshold)
            assert.is_true(guildData.sortAccess.write.delegates["Legacy-TestRealm"])
            assert.is_not_nil(guildData.sortAccess.sort)
        end)

        it("ignores a HELLO without a sortAccess field", function()
            guildData.sortAccess = configured(5000)

            GBL:HandleHello("OfficerB", { version = GBL.version, txCount = 0 })

            assert.equals(5000, guildData.sortAccess.updatedAt)
            assert.equals(2, guildData.sortAccess.sort.rankThreshold)
        end)

        it("ignores sortAccess with zero updatedAt", function()
            guildData.sortAccess = configured(5000)

            GBL:HandleHello("OfficerB", {
                version = GBL.version,
                txCount = 0,
                sortAccess = {
                    write = { rankThreshold = nil, delegates = {} },
                    sort  = { rankThreshold = nil, delegates = {} },
                    updatedAt = 0,
                },
            })

            assert.equals(5000, guildData.sortAccess.updatedAt)
        end)

        it("fires GBL_ACCESS_CONTROL_CHANGED on a sortAccess update", function()
            guildData.sortAccess = configured(1000)

            GBL:HandleHello("GMPlayer", {
                version = GBL.version,
                txCount = 0,
                sortAccess = configured(5000),
            })

            local found = false
            for _, msg in ipairs(MockAce.sentMessages) do
                if msg.message == "GBL_ACCESS_CONTROL_CHANGED" then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected GBL_ACCESS_CONTROL_CHANGED message")
        end)

        it("SaveSortAccess broadcasts the policy and signals a local rebuild", function()
            MockWoW.player.name = "GM"
            MockWoW.guild.rankIndex = 0  -- GM passes IsGuildMaster
            GBL.db.profile.sync.enabled = true
            MockAce.sentMessages = {}
            MockAce.sentCommMessages = {}

            local ok = GBL:SaveSortAccess({
                write = { rankThreshold = nil, delegates = {} },
                sort  = { rankThreshold = 2, delegates = {} },
            })
            assert.is_true(ok)

            local signaled = false
            for _, msg in ipairs(MockAce.sentMessages) do
                if msg.message == "GBL_ACCESS_CONTROL_CHANGED" then
                    signaled = true
                    break
                end
            end
            assert.is_true(signaled, "Expected GBL_ACCESS_CONTROL_CHANGED after save")

            assert.is_true(#MockAce.sentCommMessages > 0, "Expected a HELLO broadcast")
            local okD, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(okD)
            assert.is_not_nil(data.sortAccess)
            assert.equals(2, data.sortAccess.sort.rankThreshold)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Bank layout advertise-and-pull via HELLO
    ---------------------------------------------------------------------------

    describe("HELLO bank layout advertise-and-pull", function()
        local function layoutStore(updatedAt)
            return {
                version = 3,
                updatedAt = updatedAt,
                updatedBy = "GM-TestRealm",
                tabs = {
                    [1] = {
                        mode = "display",
                        items = { [100] = { slots = 2, perSlot = 5 } },
                        slotOrder = { [1] = 100, [2] = 100 },
                    },
                    [2] = { mode = "overflow" },
                },
            }
        end

        local function validRemote(updatedAt)
            return {
                type = "LAYOUT_DATA",
                bankLayout = layoutStore(updatedAt),
                stockReserves = { [100] = 250 },
            }
        end

        local function sentOfType(t)
            local out = {}
            for _, m in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(m.text)
                if ok and data.type == t then out[#out + 1] = data end
            end
            return out
        end

        local function messageFired(name)
            for _, m in ipairs(MockAce.sentMessages) do
                if m.message == name then return true end
            end
            return false
        end

        -- Advertise (cursor only, never the template) ----------------------

        it("advertises layoutUpdatedAt on HELLO when a layout is configured", function()
            guildData.bankLayout = layoutStore(5000)
            GBL:BroadcastHello()
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.equals(5000, data.layoutUpdatedAt)
        end)

        it("omits layoutUpdatedAt when no layout is saved (version 0)", function()
            guildData.bankLayout = { version = 0, updatedAt = 0, tabs = {} }
            GBL:BroadcastHello()
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[1].text)
            assert.is_true(ok)
            assert.is_nil(data.layoutUpdatedAt)
        end)

        it("advertises layoutUpdatedAt on the HELLO reply too", function()
            guildData.bankLayout = layoutStore(7000)
            MockAce.sentCommMessages = {}
            GBL:SendHelloReply("SomePeer")
            local replies = sentOfType("HELLO")
            assert.is_true(#replies >= 1)
            assert.equals(7000, replies[1].layoutUpdatedAt)
        end)

        -- Pull gate (need it AND it's newer) -------------------------------

        it("requests the layout when the player can sort and the cursor is newer", function()
            MockWoW.guild.rankIndex = 0  -- GM ⇒ HasSortAccess
            guildData.bankLayout = layoutStore(1000)
            MockAce.sentCommMessages = {}
            GBL:HandleHello("GMPlayer", {
                version = GBL.version, txCount = 0, layoutUpdatedAt = 5000,
            })
            assert.equals(1, #sentOfType("LAYOUT_REQUEST"))
        end)

        it("does not request when the player cannot sort", function()
            MockWoW.guild.rankIndex = 5  -- not GM
            guildData.sortAccess = nil    -- no grant ⇒ HasSortAccess false
            guildData.bankLayout = { version = 0, updatedAt = 0, tabs = {} }
            MockAce.sentCommMessages = {}
            GBL:HandleHello("GMPlayer", {
                version = GBL.version, txCount = 0, layoutUpdatedAt = 5000,
            })
            assert.equals(0, #sentOfType("LAYOUT_REQUEST"))
        end)

        it("does not request when the advertised cursor is not newer", function()
            MockWoW.guild.rankIndex = 0
            guildData.bankLayout = layoutStore(9000)
            MockAce.sentCommMessages = {}
            GBL:HandleHello("GMPlayer", {
                version = GBL.version, txCount = 0, layoutUpdatedAt = 5000,
            })
            assert.equals(0, #sentOfType("LAYOUT_REQUEST"))
        end)

        it("throttles repeated requests to one in-flight", function()
            MockWoW.guild.rankIndex = 0
            guildData.bankLayout = layoutStore(1000)
            MockAce.sentCommMessages = {}
            GBL:HandleHello("PeerA", {
                version = GBL.version, txCount = 0, layoutUpdatedAt = 5000,
            })
            GBL:HandleHello("PeerB", {
                version = GBL.version, txCount = 0, layoutUpdatedAt = 5000,
            })
            assert.equals(1, #sentOfType("LAYOUT_REQUEST"))
        end)

        -- Serve ------------------------------------------------------------

        it("serves LAYOUT_DATA with template and reserves on request", function()
            guildData.bankLayout = layoutStore(5000)
            guildData.stockReserves = { [100] = 250 }
            MockAce.sentCommMessages = {}
            GBL:HandleLayoutRequest("Requester", {})
            local served = sentOfType("LAYOUT_DATA")
            assert.equals(1, #served)
            assert.equals(5000, served[1].bankLayout.updatedAt)
            assert.equals(250, served[1].stockReserves[100])
        end)

        it("serves nothing when no layout is configured", function()
            guildData.bankLayout = { version = 0, updatedAt = 0, tabs = {} }
            MockAce.sentCommMessages = {}
            GBL:HandleLayoutRequest("Requester", {})
            assert.equals(0, #sentOfType("LAYOUT_DATA"))
        end)

        it("records the serve size in the sync log without debug mode", function()
            -- Regression: the serve line was SyncDebug, which drops entirely
            -- when debugChat is off, so captures never saw the payload size.
            guildData.bankLayout = layoutStore(5000)
            GBL.db.profile.sync.debugChat = false
            GBL:ClearLog("sync")
            MockAce.sentCommMessages = {}
            GBL:HandleLayoutRequest("Requester", {})
            local found = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.message:find("Serving bank layout", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected the layout serve size line at INFO")
        end)

        it("forces a HELLO advertising the new cursor when a layout is saved", function()
            MockWoW.guild.rankIndex = 0  -- GM ⇒ HasLayoutWrite
            MockAce.sentCommMessages = {}
            local ok = GBL:SaveBankLayout({
                tabs = {
                    [1] = {
                        mode = "display",
                        items = { [100] = { slots = 1, perSlot = 5 } },
                        slotOrder = { [1] = 100 },
                    },
                    [2] = { mode = "overflow" },
                },
            }, "GM")
            assert.is_true(ok)
            local hellos = sentOfType("HELLO")
            assert.is_true(#hellos >= 1)
            assert.is_not_nil(hellos[1].layoutUpdatedAt)
        end)

        -- Adopt ------------------------------------------------------------

        it("adopts received LAYOUT_DATA and fires GBL_LAYOUT_CHANGED", function()
            guildData.bankLayout = { version = 0, updatedAt = 0, tabs = {} }
            MockAce.sentMessages = {}
            GBL:HandleLayoutData("Peer", validRemote(5000))
            assert.equals(5000, guildData.bankLayout.updatedAt)
            assert.equals(250, guildData.stockReserves[100])
            assert.is_true(messageFired("GBL_LAYOUT_CHANGED"))
        end)

        it("rejects invalid LAYOUT_DATA without firing a refresh", function()
            guildData.bankLayout = { version = 0, updatedAt = 0, tabs = {} }
            MockAce.sentMessages = {}
            local bad = validRemote(5000)
            bad.bankLayout.tabs[2] = nil  -- drop the sole overflow tab
            GBL:HandleLayoutData("Peer", bad)
            assert.equals(0, guildData.bankLayout.version)
            assert.is_false(messageFired("GBL_LAYOUT_CHANGED"))
        end)
    end)
end)
