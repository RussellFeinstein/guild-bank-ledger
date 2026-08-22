------------------------------------------------------------------------
-- spec/sync_send_spec.lua — Sync send path
--
-- Split out of spec/sync_spec.lua (#116). Shared plumbing lives in
-- spec/sync_helpers.lua.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW
local Sync = require("spec.sync_helpers")

local fireAckTimeout = Sync.fireAckTimeout
local fireNextChunkDelay = Sync.fireNextChunkDelay
local fireReceiveTimeout = Sync.fireReceiveTimeout

describe("Sync send path", function()
    local GBL
    local guildData

    local function request(fields) return Sync.request(GBL, fields) end

    before_each(function()
        GBL, guildData = Sync.setup()
    end)

    ---------------------------------------------------------------------------
    -- ACK timer callback behavior
    ---------------------------------------------------------------------------

    describe("ACK timer callback", function()
        it("MAX_RECORDS_PER_CHUNK constant is 4", function()
            assert.equals(4, GBL.SYNC_CHUNK_SIZE)
        end)

        it("ACK timer starts after send callback, not immediately", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to NOT invoke callback
            local storedCallback, storedArg
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                storedCallback = cbFn
                storedArg = cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Count ACK timers — hard timer exists but ACK timer should NOT yet
            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(0, ackTimerCount, "ACK timer should not exist before callback")

            -- Now invoke the callback (message fully sent)
            assert.is_not_nil(storedCallback)
            storedCallback(storedArg, 100, 100)

            -- ACK timer should now exist
            ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(1, ackTimerCount, "ACK timer should exist after callback")

            GBL.SendCommMessage = origSend
        end)

        it("ACK timer does not start on partial send progress", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local storedCallback, storedArg
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                storedCallback = cbFn
                storedArg = cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Invoke callback with partial progress
            storedCallback(storedArg, 50, 1000)

            local ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(0, ackTimerCount, "ACK timer should not exist on partial send")

            -- Complete the send
            storedCallback(storedArg, 1000, 1000)

            ackTimerCount = 0
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == GBL.SYNC_ACK_TIMEOUT and not timer.cancelled then
                    ackTimerCount = ackTimerCount + 1
                end
            end
            assert.equals(1, ackTimerCount, "ACK timer should exist after full send")

            GBL.SendCommMessage = origSend
        end)

        it("ACK entry includes wire-to-ACK latency when wire anchor is set", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Capture + invoke AceComm progress callback so wire anchor is set.
            local storedCallback, storedArg
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                storedCallback = cbFn
                storedArg = cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "wireack1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Complete the send so sendChunkTransmittedAt is stamped
            assert.is_not_nil(storedCallback)
            storedCallback(storedArg, 100, 100)

            -- Send the ACK for chunk 1 (which is always logged: first chunk)
            GBL:HandleAck("OfficerB", { chunk = 1 })

            local trail = GBL:GetAuditTrail()
            local ackEntry
            for _, entry in ipairs(trail) do
                if entry.message:find("ACK from") and entry.message:find("chunk 1/") then
                    ackEntry = entry.message
                    break
                end
            end
            assert.is_not_nil(ackEntry, "chunk 1 ACK entry should be logged")
            assert.is_not_nil(ackEntry:find("wire%-to%-ACK="),
                "ACK entry should include wire-to-ACK=: " .. tostring(ackEntry))

            GBL.SendCommMessage = origSend
        end)

        it("hard timeout fires if callback never completes", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to suppress callback entirely
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                -- Do NOT invoke callback
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should be sending
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Find and fire the hard timeout (120s)
            local fired = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 120 and not timer.cancelled then
                    timer.callback()
                    fired = true
                    break
                end
            end
            assert.is_true(fired, "hard timeout timer should exist")
            assert.is_false(GBL:GetSyncStatus().sending, "should have aborted")

            GBL.SendCommMessage = origSend
        end)
    end)

    ---------------------------------------------------------------------------
    -- Retry logic
    ---------------------------------------------------------------------------

    describe("retry logic", function()
        it("retries same chunk on ACK timeout instead of aborting", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add tx (fits in 1 chunk with MAX_RECORDS_PER_CHUNK=25)
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should be sending chunk 1
            assert.is_true(GBL:GetSyncStatus().sending)
            local sentBefore = #MockAce.sentCommMessages

            -- Advance time past the inter-chunk gap floor so the retry fires
            -- immediately (in production a retry follows one ACK_TIMEOUT after the last send).
            MockWoW.serverTime = MockWoW.serverTime + 10

            -- Fire ACK timeout — should retry, not abort
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

            assert.is_true(GBL:GetSyncStatus().sending, "should still be sending after retry")
            -- A new SYNC_DATA message should have been sent (the retry)
            assert.is_true(#MockAce.sentCommMessages > sentBefore,
                "retry should send another message")
        end)

        it("aborts after MAX_RETRIES exceeded", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Override SendCommMessage to suppress callback (no ACK possible)
            local origSend = GBL.SendCommMessage
            GBL.SendCommMessage = function(self, prefix, text, dist, target, prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                -- Simulate immediate transmit so ACK timer starts
                if cbFn then cbFn(cbArg, 100, 100) end
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "h1",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Fire ACK timeout MAX_RETRIES times (should keep retrying).
            -- Advance time between firings so the inter-chunk gap floor is
            -- satisfied for each retry (one ACK_TIMEOUT elapses per retry in production).
            for attempt = 1, GBL.SYNC_MAX_RETRIES do
                MockWoW.serverTime = MockWoW.serverTime + 10
                fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
                assert.is_true(GBL:GetSyncStatus().sending,
                    "should still be sending after retry " .. attempt)
            end

            -- One more timeout — should abort
            MockWoW.serverTime = MockWoW.serverTime + 10
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            assert.is_false(GBL:GetSyncStatus().sending,
                "should have aborted after max retries")

            GBL.SendCommMessage = origSend
        end)

        it("resets retry counter on successful ACK", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Enough records to span more than one chunk, so there is a chunk 2
            -- for the reset retry counter to be observed on. Four records fit a
            -- single chunk and always have, which left the second half of this
            -- test firing at a timer that was never there.
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            -- Advance past the gap floor so the retry issues immediately.
            MockWoW.serverTime = MockWoW.serverTime + 10

            -- Fire one ACK timeout (retry attempt 1)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

            -- Advance past the gap floor again BEFORE the ACK, so the chunk 2
            -- send it schedules is not additionally deferred by the gap floor.
            MockWoW.serverTime = MockWoW.serverTime + 10
            GBL:HandleAck("OfficerB", { chunk = 1 })

            -- Chunk 2 goes out on the adaptive inter-chunk delay, not inline.
            fireNextChunkDelay()

            -- Fire ACK timeout for chunk 2 — retry counter should be reset,
            -- so this should retry (not abort)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            assert.is_true(GBL:GetSyncStatus().sending,
                "retry counter should have reset — still sending")
        end)
    end)

    ---------------------------------------------------------------------------
    -- ACK timeout target liveness tag (v0.30.2)
    ---------------------------------------------------------------------------

    describe("ACK timeout target liveness", function()
        local function fireOneAckTimeout()
            MockWoW.serverTime = MockWoW.serverTime + 10
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
        end

        local function findRetryEntry()
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                -- Match the distinctive "retrying chunk" substring; the
                -- audit message itself contains an em dash before it
                -- (pre-existing pre-v0.30.2 wording), so don't anchor on that.
                if entry.message:find("retrying chunk", 1, true) then
                    return entry.message
                end
            end
            return nil
        end

        -- Sets up state with target online (HandleSyncRequest gates on
        -- IsGuildMemberOnline via SendSyncWhisper at Sync.lua:222). Tests
        -- that need a different liveness must flip the roster AFTER setup,
        -- before firing the ACK timeout — that mirrors the real-world
        -- scenario of a peer who goes offline mid-stream.
        local function setupSendingState()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = true },
            }
            for i = 1, 4 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "h" .. i,
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)
        end

        it("appends target=online when send target is in roster and online", function()
            setupSendingState()
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=online"),
                "retry entry should include target=online; got: " .. entry)
        end)

        it("appends target=offline when send target goes offline mid-stream", function()
            setupSendingState()
            -- Peer disconnects after we already started sending
            MockWoW.guildRoster = {
                { name = "OfficerB-TestRealm", isOnline = false },
            }
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=offline"),
                "retry entry should include target=offline; got: " .. entry)
        end)

        it("appends target=unknown when send target leaves the guild mid-stream", function()
            setupSendingState()
            -- Peer drops out of roster entirely — IsGuildMemberOnline returns nil
            MockWoW.guildRoster = {}
            fireOneAckTimeout()

            local entry = findRetryEntry()
            assert.is_not_nil(entry, "expected an ACK timeout retry entry")
            assert.is_not_nil(entry:match("target=unknown"),
                "retry entry should include target=unknown; got: " .. entry)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Inter-chunk gap floor (v0.28.5)
    ---------------------------------------------------------------------------

    describe("inter-chunk gap floor", function()
        it("exposes SYNC_INTER_CHUNK_GAP_FLOOR constant as 1.0", function()
            assert.equals(1.0, GBL.SYNC_INTER_CHUNK_GAP_FLOOR)
        end)

        it("first chunk is not deferred by gap floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "gapfloor_first:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- First chunk should have gone out immediately (no prior
            -- lastSendIssuedAt means gap check short-circuits on the > 0 guard).
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" and data.chunk == 1 then
                    foundSyncData = true
                    break
                end
            end
            assert.is_true(foundSyncData,
                "first chunk should send immediately without gap-floor deferral")
        end)

        it("second chunk issued inside the gap window defers until floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.serverTime = 1000

            -- Enough records to need at least 2 chunks at 25/chunk
            for i = 1, 30 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i,
                    id = "gapfloor_second_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local function countSyncData()
                local c = 0
                for _, msg in ipairs(MockAce.sentCommMessages) do
                    local ok, data = GBL:Deserialize(msg.text)
                    if ok and data.type == "SYNC_DATA" then c = c + 1 end
                end
                return c
            end
            local function fireFirstShortTimer(maxDelay)
                for _, timer in ipairs(MockWoW.pendingTimers) do
                    if not timer.cancelled and not timer.fired
                        and timer.delay and timer.delay <= maxDelay
                        and timer.delay > 0 then
                        timer.callback()
                        timer.fired = true
                        return timer.delay
                    end
                end
                return nil
            end

            local afterChunk1 = countSyncData()
            assert.is_true(afterChunk1 >= 1, "chunk 1 should have been sent")

            -- Acknowledge chunk 1 — this schedules a post-ACK SendNextChunk via
            -- GetSyncDelay(). Fire only that timer (not the 120s hard timer)
            -- so we isolate the gap-floor behavior.
            GBL:HandleAck("OfficerB", { chunk = 1 })
            local firedDelay = fireFirstShortTimer(1.0)
            assert.is_not_nil(firedDelay,
                "should have found the post-ACK SendNextChunk timer to fire")

            -- With no time advancement, the deferred timer is still pending
            -- and chunk 2 is NOT yet sent.
            assert.equals(afterChunk1, countSyncData(),
                "chunk 2 should NOT send while still inside the gap window")

            -- Advance past the gap floor and fire the deferred SendNextChunk.
            MockWoW.serverTime = MockWoW.serverTime + 2.0
            local firedDefer = fireFirstShortTimer(1.0)
            assert.is_not_nil(firedDefer,
                "should have found the gap-floor deferral timer to fire")
            assert.is_true(countSyncData() > afterChunk1,
                "chunk 2 should send once gap floor has elapsed")
        end)

        it("ACK-timeout retry does not defer when gap already exceeds floor", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            MockWoW.serverTime = 1000

            -- Suppress auto-callback so we control the ACK timer manually.
            local origSend = GBL.SendCommMessage
            local savedCb, savedArg
            GBL.SendCommMessage = function(_self, prefix, text, dist, target, _prio, cbFn, cbArg)
                table.insert(MockAce.sentCommMessages, {
                    prefix = prefix, text = text, distribution = dist, target = target,
                })
                savedCb, savedArg = cbFn, cbArg
            end

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "gapfloor_acktimeout:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Complete the send so the ACK timer is scheduled.
            assert.is_not_nil(savedCb)
            savedCb(savedArg, 100, 100)

            -- Advance past ACK_TIMEOUT; retries from here satisfy gap ≥ floor.
            MockWoW.serverTime = MockWoW.serverTime + 10

            local sentBefore = #MockAce.sentCommMessages
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)
            local sentAfter = #MockAce.sentCommMessages
            assert.is_true(sentAfter > sentBefore,
                "ACK-timeout retry should fire immediately when gap > floor")

            GBL.SendCommMessage = origSend
        end)
    end)

    ---------------------------------------------------------------------------
    -- NACK retry
    ---------------------------------------------------------------------------

    describe("NACK retry", function()
        it("NACK is sent with ALERT priority", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver state
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "Thrall-TestRealm",
                    itemID = 12345, count = 5, tab = 1,
                    timestamp = 1000, id = "nacktest:0", _occurrence = 0,
                }},
                moneyTransactions = {},
            })
            MockAce.sentCommMessages = {}

            -- Manually send a NACK
            GBL:SendNack("OfficerB", 2)

            assert.is_true(#MockAce.sentCommMessages >= 1)
            local nackSent = MockAce.sentCommMessages[#MockAce.sentCommMessages]
            assert.equals("ALERT", nackSent.prio,
                "NACK should be sent with ALERT priority")
        end)

        it("receiver sends NACK on chunk timeout instead of aborting", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver state: received chunk 1, waiting for chunk 2
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nack1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            -- Fire the receive timeout — should NACK, not abort
            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving,
                "should still be receiving after NACK")
            -- Should have sent a NACK message
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("NACK", data.type)
            assert.equals(2, data.chunk)
        end)

        it("sender re-transmits chunk on NACK receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender with 2 chunks
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "nk" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(GBL:GetSyncStatus().sending)

            local sentBefore = #MockAce.sentCommMessages

            -- Send NACK for chunk 1
            GBL:HandleNack("OfficerB", { chunk = 1 })

            -- Advance past the inter-chunk gap floor so the NACK retransmit
            -- satisfies gap >= 1.0s (production NACKs arrive several seconds
            -- after the failed send).
            MockWoW.serverTime = MockWoW.serverTime + 2

            -- Fire the 0.5s delayed re-send
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                    break
                end
            end

            assert.is_true(#MockAce.sentCommMessages > sentBefore,
                "should have re-sent chunk after NACK")
        end)

        it("receiver aborts after MAX_NACK_RETRIES for same chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up receiver — got chunk 1, waiting for chunk 2
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 3,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nklim1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout MAX_NACK_RETRIES times (with backoff: 20→30→45)
            for attempt = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
                if attempt < GBL.SYNC_MAX_NACK_RETRIES then
                    assert.is_true(GBL:GetSyncStatus().receiving,
                        "should still be receiving after NACK attempt " .. attempt)
                end
            end

            -- One more — should abort
            fireReceiveTimeout()
            assert.is_false(GBL:GetSyncStatus().receiving,
                "should have aborted after max NACK retries")
        end)

        it("NACK counter resets on successful chunk receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 1, totalChunks = 4,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5000,
                    scanTime = 5000, id = "nkrst1:0", itemID = 100, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout twice (2 NACKs sent, with backoff)
            for _ = 1, 2 do
                fireReceiveTimeout()
            end

            -- Now receive chunk 2 — should reset counter
            GBL:HandleSyncData("OfficerB", {
                type = "SYNC_DATA", chunk = 2, totalChunks = 4,
                transactions = {{
                    type = "deposit", player = "X", timestamp = 5001,
                    scanTime = 5001, id = "nkrst2:0", itemID = 101, count = 1, tab = 1,
                }},
                moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire timeout MAX_NACK_RETRIES times — should still be receiving
            -- because counter was reset (backoff restarts from 20s)
            for _ = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
            end
            -- Should still be receiving (counter was reset after chunk 2)
            assert.is_true(GBL:GetSyncStatus().receiving,
                "NACK counter should have reset — still receiving")
        end)

        it("NACK from wrong sender is ignored", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "nkign:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local sentBefore = #MockAce.sentCommMessages

            -- NACK from wrong sender
            GBL:HandleNack("OfficerC", { chunk = 1 })

            -- Fire any pending timers
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            -- No new messages should have been sent (NACK was ignored)
            assert.equals(sentBefore, #MockAce.sentCommMessages)
        end)

        it("NACK for out-of-range chunk is ignored", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sender with 1 chunk
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "nkoor:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local sentBefore = #MockAce.sentCommMessages

            -- NACK for chunk 0 (invalid)
            GBL:HandleNack("OfficerB", { chunk = 0 })
            -- NACK for chunk 99 (out of range)
            GBL:HandleNack("OfficerB", { chunk = 99 })

            -- Fire any pending timers
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    timer.callback()
                    timer.fired = true
                end
            end

            assert.equals(sentBefore, #MockAce.sentCommMessages)
        end)

        -- Silence at zero chunks means the request itself went missing, so
        -- the thing to repeat is the request. NACKing chunk 1 asks a peer to
        -- retransmit a chunk it never built, and HandleNack drops it on the
        -- floor because it is not sending: the retry signal crossed the wire
        -- and was discarded. Once chunks are arriving the NACK is right again.
        it("resends the request when the timeout fires at zero chunks", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving,
                "should still be receiving after the first resend")
            assert.is_true(#MockAce.sentCommMessages >= 1)
            local ok, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_true(ok)
            assert.equals("SYNC_REQUEST", data.type)
        end)

        it("resends with the timestamp the original request used", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 4242)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.equals(4242, data.sinceTimestamp)
        end)

        it("resends a manifest, not an empty request", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local ts = 80000 * GBL.BUCKET_SECONDS
            table.insert(guildData.transactions, {
                type = "deposit", player = "P", itemID = 1, count = 1, tab = 1,
                timestamp = ts, scanTime = ts, scannedBy = "OfficerA",
                id = "resend_rec:0",
            })

            GBL:RequestSync("OfficerB", 0)
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.is_table(data.bucketHashes)
            assert.is_not_nil(data.bucketHashes[80000])
        end)

        it("still NACKs a stall once chunks have started arriving", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            local _, data = GBL:Deserialize(
                MockAce.sentCommMessages[#MockAce.sentCommMessages].text)
            assert.equals("NACK", data.type)
            assert.equals(2, data.chunk)
        end)

        it("RequestSync timeout resends and aborts after MAX_NACK_RETRIES", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            for _ = 1, GBL.SYNC_MAX_NACK_RETRIES do
                fireReceiveTimeout()
                assert.is_true(GBL:GetSyncStatus().receiving,
                    "should still be receiving while resends remain")
            end

            -- One more timeout, and the budget is spent
            fireReceiveTimeout()
            assert.is_false(GBL:IsSyncing(),
                "should no longer be syncing after the retry budget is spent")
            assert.is_false(GBL:GetSyncStatus().receiving)
        end)

        it("MAX_RECEIVE_DURATION safety net aborts stuck receive", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            GBL:RequestSync("OfficerB", 0)
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Simulate receiving having started long ago by backdating receiveStartTime
            local status = GBL:GetSyncStatus()
            -- Access internal state via GetSyncStatus — need to set it directly
            -- Use a SYNC_DATA chunk to get past initial state, then backdate
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 100,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Backdate receiveStartTime to exceed MAX_RECEIVE_DURATION
            GBL:SetReceiveStartTime(
                MockWoW.serverTime - GBL.SYNC_MAX_RECEIVE_DURATION - 1)

            -- Fire timeout — should abort due to duration safety net
            fireReceiveTimeout()
            assert.is_false(GBL:GetSyncStatus().receiving,
                "should abort after MAX_RECEIVE_DURATION exceeded")
        end)
    end)

    ---------------------------------------------------------------------------
    -- NACK backoff
    ---------------------------------------------------------------------------

    describe("NACK backoff", function()
        it("computes correct backoff values", function()
            assert.equals(20, GBL._nackBackoff(0))
            assert.equals(30, GBL._nackBackoff(1))
            assert.equals(45, GBL._nackBackoff(2))
            assert.equals(45, GBL._nackBackoff(3))  -- capped at 45
            assert.equals(45, GBL._nackBackoff(10)) -- still capped
        end)

        it("uses progressive delays for successive NACKs", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1 of 3 (triggers timeout for chunk 2)
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- First timeout should be at 20s (nackCount=0)
            local firstTimer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    firstTimer = t
                    break
                end
            end
            assert.is_not_nil(firstTimer)
            assert.equals(20, firstTimer.delay)

            -- Fire the first NACK (schedules a new timer with backoff)
            firstTimer.callback()
            local secondTimer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    secondTimer = t
                    break
                end
            end
            assert.is_not_nil(secondTimer)
            assert.equals(30, secondTimer.delay)
        end)

        it("resets backoff after successful chunk receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Receive chunk 1 of 4
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 4,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- Fire 2 NACKs to advance backoff
            fireReceiveTimeout()
            fireReceiveTimeout()

            -- Receive chunk 2 (resets nackCount)
            GBL:HandleSyncData("OfficerB", {
                chunk = 2, totalChunks = 4,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })

            -- New timeout should be 20s (reset backoff)
            local timer = nil
            for i = #MockWoW.pendingTimers, 1, -1 do
                local t = MockWoW.pendingTimers[i]
                if not t.cancelled and t.delay >= 10 then
                    timer = t
                    break
                end
            end
            assert.is_not_nil(timer)
            assert.equals(20, timer.delay)
        end)
    end)

    ---------------------------------------------------------------------------
    -- FPS-adaptive throttling
    ---------------------------------------------------------------------------

    describe("FPS-adaptive throttling", function()
        it("uses slow delay when FPS below threshold", function()
            MockWoW.framerate = 15
            GBL:StartFpsMonitor()

            -- Fire OnUpdate with enough elapsed time
            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")
            assert.is_not_nil(onUpdate)

            -- Advance time past sample interval
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)

            assert.equals(0.5, GBL:GetSyncDelay())
            GBL:StopFpsMonitor()
        end)

        it("recovers to normal delay when FPS above recover threshold", function()
            MockWoW.framerate = 15
            GBL:StartFpsMonitor()

            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")

            -- Trigger low FPS
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)
            assert.equals(0.5, GBL:GetSyncDelay())

            -- Recover FPS
            MockWoW.framerate = 30
            MockWoW.serverTime = MockWoW.serverTime + 2
            onUpdate(frame, 2)

            assert.equals(0.1, GBL:GetSyncDelay())
            GBL:StopFpsMonitor()
        end)

        it("FPS monitor starts on sync begin and stops on FinishSending", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            local framesBefore = #MockWoW.frames
            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "fps1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- FPS frame should have been created
            assert.is_true(#MockWoW.frames > framesBefore,
                "FPS monitor frame should be created on sync start")

            -- Finish sending
            GBL:FinishSending()
            assert.equals(0.1, GBL:GetSyncDelay(),
                "delay should reset to normal after FinishSending")
        end)

        it("HandleAck uses adaptive delay value", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up sending with slow delay
            for i = 1, 8 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000 + i, id = "fps2_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Simulate low FPS — manually set delay
            MockWoW.framerate = 10
            local frame = MockWoW.frames[#MockWoW.frames]
            local onUpdate = frame:GetScript("OnUpdate")
            if onUpdate then
                MockWoW.serverTime = MockWoW.serverTime + 2
                onUpdate(frame, 2)
            end
            assert.equals(0.5, GBL:GetSyncDelay())

            -- Send ACK — the scheduled delay should use adaptive value
            GBL:HandleAck("OfficerB", { chunk = 1 })

            -- Verify a one-shot timer was created with the slow delay
            local foundSlowDelay = false
            for _, timer in ipairs(MockWoW.pendingTimers) do
                if timer.delay == 0.5 and not timer.fired then
                    foundSlowDelay = true
                    break
                end
            end
            assert.is_true(foundSlowDelay,
                "HandleAck should schedule next chunk with adaptive delay (0.5s)")
        end)
    end)

    describe("ChatThrottleLib awareness", function()
        it("defers SendNextChunk when CTL bandwidth is low", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up CTL with low bandwidth
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            -- HandleSyncRequest calls SendNextChunk which should defer
            -- No SYNC_DATA sent immediately because CTL bandwidth is low
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" then
                    foundSyncData = true
                end
            end
            assert.is_false(foundSyncData,
                "should defer SYNC_DATA when CTL bandwidth is low")

            _G.ChatThrottleLib = nil
        end)

        it("sends normally when CTL bandwidth is sufficient", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = { avail = 1000 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl2:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Should have sent normally (no CTL deferral)
            local trail = GBL:GetAuditTrail()
            local ctlDeferred = false
            for _, entry in ipairs(trail) do
                if entry.message:find("CTL bandwidth low") then
                    ctlDeferred = true
                    break
                end
            end
            assert.is_false(ctlDeferred)
            assert.is_true(#MockAce.sentCommMessages >= 1)

            _G.ChatThrottleLib = nil
        end)

        it("sends normally when ChatThrottleLib is absent", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = nil
            assert.is_true(GBL:HasSyncBandwidth())

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl3:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_true(#MockAce.sentCommMessages >= 1)
        end)

        it("graceful fallback when CTL has no avail field", function()
            _G.ChatThrottleLib = {}
            assert.is_true(GBL:HasSyncBandwidth())
            _G.ChatThrottleLib = nil
        end)

        it("defers at avail=300 (below floor threshold of 400)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            _G.ChatThrottleLib = { avail = 300 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_thresh:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- avail=300 < CTL_BANDWIDTH_MIN=400 floor → should defer
            local foundSyncData = false
            for _, msg in ipairs(MockAce.sentCommMessages) do
                local ok, data = GBL:Deserialize(msg.text)
                if ok and data.type == "SYNC_DATA" then
                    foundSyncData = true
                end
            end
            assert.is_false(foundSyncData,
                "avail=300 should defer (below 400 floor)")

            _G.ChatThrottleLib = nil
        end)

        it("uses dynamic threshold based on last chunk size", function()
            _G.ChatThrottleLib = { avail = 500 }

            -- Before any chunk sent, lastChunkBytes=0, threshold=max(400,0)=400
            assert.is_true(GBL:HasSyncBandwidth(),
                "avail=500 > floor=400 → should allow")

            -- Simulate a previous chunk being 800 bytes
            GBL._syncState_setLastChunkBytes(800)
            assert.is_false(GBL:HasSyncBandwidth(),
                "avail=500 < dynamic threshold 800 → should defer")

            _G.ChatThrottleLib = { avail = 900 }
            assert.is_true(GBL:HasSyncBandwidth(),
                "avail=900 > dynamic threshold 800 → should allow")

            GBL._syncState_setLastChunkBytes(0)
            _G.ChatThrottleLib = nil
        end)

        it("increments ctlDeferTotal on each deferral", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_counter:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            assert.is_true(GBL:GetCtlDeferTotal() >= 1,
                "ctlDeferTotal should increment on CTL deferral")

            _G.ChatThrottleLib = nil
        end)

        it("rate-limits CTL deferral audit entries", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_ratelimit:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Fire timers repeatedly to simulate multiple deferrals
            for _ = 1, 25 do
                MockWoW.fireTimers()
            end

            -- Count CTL audit entries
            local trail = GBL:GetAuditTrail()
            local ctlEntries = 0
            for _, entry in ipairs(trail) do
                if entry.message:find("CTL low") then
                    ctlEntries = ctlEntries + 1
                end
            end

            -- Should have first 10 verbose + 20th = 11, NOT all 25+
            assert.is_true(ctlEntries <= 15,
                "CTL deferral entries should be rate-limited (got " .. ctlEntries .. ")")

            _G.ChatThrottleLib = nil
        end)

        it("records a drain sample and opens an episode on deferral", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_sample:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local drain = GBL._ctlDrain
            assert.is_true(#drain.samples >= 1, "expected a drain sample")
            local s = drain.samples[#drain.samples]
            assert.equals(100, s.avail)
            assert.is_true(s.threshold >= 400)
            assert.is_not_nil(drain.episodeStart, "expected an open episode")
            assert.equals(1, drain.episodeDefers)
            assert.equals(100, drain.minAvail)

            _G.ChatThrottleLib = nil
        end)

        it("counts overlapping deferral timers without dedup'ing them", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_overlap:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local drain = GBL._ctlDrain
            local pendingAfterFirst = drain.timersPending
            assert.is_true(pendingAfterFirst >= 1)
            local timersBefore = #MockWoW.pendingTimers

            -- A second caller invokes SendNextChunk while the first deferral
            -- timer is still pending: the overlap is COUNTED and the second
            -- timer is STILL scheduled (measurement only, no dedup). Exactly
            -- one new timer is expected because the CTL defer path returns
            -- before any other C_Timer.After site (StartFpsMonitor is an
            -- OnUpdate frame, not a timer).
            GBL:SendNextChunk()
            assert.equals(pendingAfterFirst + 1, drain.timersPending)
            assert.is_true(drain.overlapCount >= 1)
            assert.is_true(drain.overlapTotal >= 1)
            assert.equals(timersBefore + 1, #MockWoW.pendingTimers,
                "second deferral timer must still be scheduled")

            _G.ChatThrottleLib = nil
        end)

        it("emits a CTL recovered summary when bandwidth returns", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_recover:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_not_nil(GBL._ctlDrain.episodeStart)

            -- Bandwidth returns; the pending deferral timer re-enters
            -- SendNextChunk, which should summarize and close the episode.
            -- Relies on MockAce dispatching send callbacks synchronously, so
            -- the episode-close code runs inside this single fireTimers()
            -- (which snapshots pendingTimers and cannot cascade).
            _G.ChatThrottleLib.avail = 4000
            MockWoW.fireTimers()

            local found = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.message:find("CTL recovered", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "expected a CTL recovered summary line")
            assert.is_nil(GBL._ctlDrain.episodeStart, "episode should be closed")

            _G.ChatThrottleLib = nil
        end)

        it("Sync stats line carries overlapped timers and longest stall", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_stats:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local found = false
            for _, entry in ipairs(GBL:GetLog("sync")) do
                -- Assert the VALUES for the no-CTL case, not just the field
                -- names, so a misplaced counter reset cannot pass unnoticed.
                if entry.message:find("Sync stats: ", 1, true)
                    and entry.message:find("0 overlapped timers", 1, true)
                    and entry.message:find("longest stall 0.0", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected the extended Sync stats line in FinishSending")
        end)

        it("folds a still-open drain episode into the longest stall", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 100 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_truncated:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            assert.is_not_nil(GBL._ctlDrain.episodeStart, "expected an open episode")

            -- Mode A shape: the send aborts while CTL is still starved (in
            -- production the 120s sendHardTimer), so SendNextChunk's recovery
            -- block never runs and the episode is open at FinishSending. That
            -- episode is the longest of the session by definition, because it
            -- is the one that ended it.
            MockWoW.serverTime = MockWoW.serverTime + 12
            GBL:FinishSending()

            local stats, truncated
            for _, entry in ipairs(GBL:GetLog("sync")) do
                if entry.message:find("Sync stats: ", 1, true) then
                    stats = entry.message
                end
                if entry.message:find("CTL still starved at send end", 1, true) then
                    truncated = entry.message
                end
            end

            assert.is_not_nil(stats, "expected a Sync stats line")
            assert.is_nil(stats:find("longest stall 0.0", 1, true),
                "a truncated episode must not report a 0.0s longest stall")
            assert.is_not_nil(truncated,
                "expected a truncated-episode line naming the open stall")
            assert.is_not_nil(truncated:find("1 deferrals", 1, true),
                "truncated line should carry the episode deferral count")
            assert.is_nil(GBL._ctlDrain.episodeStart,
                "episode should be closed after FinishSending")

            _G.ChatThrottleLib = nil
        end)

        it("no drain episode when ChatThrottleLib is absent", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = nil

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_absent:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            assert.is_nil(GBL._ctlDrain.episodeStart)
            -- Only the session boundary marker lands; no deferral samples.
            assert.equals(1, #GBL._ctlDrain.samples)
            assert.equals("session", GBL._ctlDrain.samples[1].marker)
        end)

        it("Sending chunk entry includes CTLq= when CTL.Prio is present", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = {
                avail = 5000,
                Prio = {
                    ALERT  = { nSize = 0 },
                    NORMAL = { nSize = 2 },
                    BULK   = { nSize = 0 },
                },
            }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctlq1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local trail = GBL:GetAuditTrail()
            local foundCtlq = false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sending chunk") and entry.message:find("CTLq=") then
                    foundCtlq = true
                    break
                end
            end
            assert.is_true(foundCtlq,
                "Sending chunk entry should include CTLq= when CTL.Prio is present")

            _G.ChatThrottleLib = nil
        end)

        -- The per-chunk line used to report percent reduction while the
        -- FinishSending summary reported compressed-over-raw, so one chunk read
        -- as "31% compressed" in one line and 69% in the other. Both are
        -- percent-of-raw now; a capture is unreadable if they ever diverge again.
        it("reports compression as percent of raw in both send lines", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ratioconv1:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local chunkLine, summaryLine
            for _, entry in ipairs(trail) do
                if entry.message:find("Sending chunk") then
                    chunkLine = chunkLine or entry.message
                end
                if entry.message:find("Compression for OfficerB") then
                    summaryLine = summaryLine or entry.message
                end
            end

            assert.is_truthy(chunkLine, "should emit a Sending chunk line")
            assert.is_truthy(summaryLine, "should emit a Compression for <peer> line")
            assert.is_truthy(chunkLine:find("% of raw", 1, true),
                "per-chunk line should report percent of raw, got: " .. tostring(chunkLine))
            assert.is_nil(chunkLine:find("compressed", 1, true),
                "per-chunk line should not use the old percent-reduction wording")
            assert.is_truthy(summaryLine:find("of raw", 1, true),
                "summary line should name the percent-of-raw convention, got: "
                .. tostring(summaryLine))
        end)

        it("suppresses HELLO replies during sync", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")
            _G.ChatThrottleLib = { avail = 5000 }

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "ctl_hellotag:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local msgsBefore = #MockAce.sentCommMessages

            -- Simulate receiving a HELLO while sending
            GBL:HandleHello("ThirdPartyPeer", {
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = GBL:GetGuildName(),
                txCount = 1,
                dataHash = 999,
            })

            -- No reply whisper should have been sent
            local replyCount = 0
            for i = msgsBefore + 1, #MockAce.sentCommMessages do
                local ok, data = GBL:Deserialize(MockAce.sentCommMessages[i].text)
                if ok and data.type == "HELLO" and data.isReply then
                    replyCount = replyCount + 1
                end
            end
            assert.equals(0, replyCount,
                "HELLO reply should be suppressed during sync")

            -- But suppression should be logged
            local trail = GBL:GetAuditTrail()
            local foundSuppressed = false
            for _, entry in ipairs(trail) do
                if entry.message:find("reply=sync-active", 1, true) then
                    foundSuppressed = true
                    break
                end
            end
            assert.is_true(foundSuppressed,
                "the round line should record the reply suppressed by a live session")

            _G.ChatThrottleLib = nil
        end)
    end)

    ---------------------------------------------------------------------------
    -- Chunk count accuracy
    ---------------------------------------------------------------------------

    describe("chunk count in FinishSending", function()
        it("reports correct chunk count (N/N, not N+1/N)", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Add enough records for 2 chunks
            for i = 1, 20 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "ChunkTest",
                    timestamp = 1000 + i, scanTime = 1000 + i,
                    id = "chunk_count_test_" .. i .. ":0",
                })
            end

            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            -- Capture the audit trail
            local trail = GBL:GetAuditTrail()
            local sendComplete = nil
            for _, entry in ipairs(trail) do
                if entry.message:find("Send complete") then
                    sendComplete = entry.message
                end
            end

            if sendComplete then
                -- Extract "X/Y chunks" from the message
                local sent, total = sendComplete:match("(%d+)/(%d+) chunks")
                if sent and total then
                    assert.equals(sent, total,
                        "sent count should equal total count, got: " .. sendComplete)
                end
            end
        end)
    end)

    ---------------------------------------------------------------------------
    -- Per-sync retry histogram (v0.28.4 → v0.28.7 diagnostics)
    ---------------------------------------------------------------------------

    describe("FinishSending outcomes histogram", function()
        it("emits three per-peer diagnostic entries after Sync stats", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "hist_basic:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local foundOutcomes, foundCauses, foundCompression = false, false, false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sync outcomes for OfficerB")
                    and entry.message:find("on 1st")
                    and entry.message:find("on 2nd")
                    and entry.message:find("on 3rd%+")
                    and entry.message:find("aborted:")
                    and entry.message:find("combat") and entry.message:find("zone")
                    and entry.message:find("busy") and entry.message:find("offline") then
                    foundOutcomes = true
                end
                if entry.message:find("Retry causes for OfficerB")
                    and entry.message:find("ackTimeout=")
                    and entry.message:find("nack=")
                    and entry.message:find("chunkFail=")
                    and entry.message:find("p_frag=") then
                    foundCauses = true
                end
                if entry.message:find("Compression for OfficerB") then
                    foundCompression = true
                end
            end
            assert.is_true(foundOutcomes, "should emit Sync outcomes for <peer> line")
            assert.is_true(foundCauses, "should emit Retry causes for <peer> line")
            assert.is_true(foundCompression, "should emit Compression for <peer> line")
        end)

        it("reports p_frag=n/a when fewer than 3 chunks observed", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "hist_nacount:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleAck("OfficerB", { chunk = 1 })
            MockWoW.fireTimers()

            local trail = GBL:GetAuditTrail()
            local causesEntry
            for _, entry in ipairs(trail) do
                if entry.message:find("Retry causes for") then
                    causesEntry = entry.message
                    break
                end
            end
            assert.is_not_nil(causesEntry, "retry causes entry should exist")
            assert.is_not_nil(causesEntry:find("p_frag=n/a"),
                "single-chunk sync should report p_frag=n/a, got: "
                    .. tostring(causesEntry))
        end)
    end)

    ---------------------------------------------------------------------------
    -- v0.28.7 diagnostics bundle: per-retry cause tags and per-chunk compression
    ---------------------------------------------------------------------------

    describe("v0.28.7 retry cause tagging", function()
        it("tags ackTimeout in chunkOutcomes.retryReasons on ACK timer retry", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "ack_tag_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1], "chunk 1 outcome should exist")
            assert.same({}, syncState.chunkOutcomes[1].retryReasons)

            -- Advance time past gap floor + ACK timeout so the retry fires cleanly
            MockWoW.serverTime = MockWoW.serverTime + 10
            -- Fire only the ACK timer (avoid firing gap-floor timers that would
            -- cascade through the retry and re-arm new timers indefinitely)
            fireAckTimeout(GBL.SYNC_ACK_TIMEOUT)

            assert.is_table(syncState.chunkOutcomes[1].retryReasons)
            local found = false
            for _, r in ipairs(syncState.chunkOutcomes[1].retryReasons) do
                if r == "ackTimeout" then found = true end
            end
            assert.is_true(found,
                "retryReasons should contain 'ackTimeout' after ACK timeout retry")
        end)

        it("tags nack in retryReasons on NACK receipt", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "nack_tag_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })
            GBL:HandleNack("OfficerB", { chunk = 1 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1])
            local found = false
            for _, r in ipairs(syncState.chunkOutcomes[1].retryReasons) do
                if r == "nack" then found = true end
            end
            assert.is_true(found, "retryReasons should contain 'nack' after NACK")
        end)

        it("tags outcome=combatAbort on the in-flight chunk at combat start", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            for i = 1, 2 do
                table.insert(guildData.transactions, {
                    type = "deposit", player = "X", timestamp = 1000 + i,
                    scanTime = 1000, id = "combat_abort_" .. i .. ":0",
                })
            end
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            local activeIdx = syncState.sendChunkIndex
            -- Grab a reference before FinishSending reassigns chunkOutcomes = {}
            local outcomesRef = syncState.chunkOutcomes
            assert.is_not_nil(outcomesRef[activeIdx])
            assert.equals("pending", outcomesRef[activeIdx].outcome)

            GBL:OnCombatStart()

            assert.equals("combatAbort",
                outcomesRef[activeIdx].outcome,
                "active chunk outcome should be combatAbort after OnCombatStart")
        end)

        it("captures compressed bytes and ratio per chunk", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            table.insert(guildData.transactions, {
                type = "deposit", player = "X", timestamp = 1000,
                scanTime = 1000, id = "compression_capture:0",
            })
            GBL:HandleSyncRequest("OfficerB", request{ sinceTimestamp = 0 })

            local syncState = GBL:GetSyncStateForTests()
            assert.is_not_nil(syncState.chunkOutcomes[1])
            assert.is_true(syncState.chunkOutcomes[1].bytes > 0,
                "chunkOutcomes[1].bytes should be > 0 after send")
            -- Mock LibDeflate is identity, so ratio is 1.0. Real LibDeflate < 1.
            assert.is_true(syncState.chunkOutcomes[1].ratio > 0,
                "chunkOutcomes[1].ratio should be > 0 after send")
        end)
    end)

    ---------------------------------------------------------------------------
    -- Sender offline detection
    ---------------------------------------------------------------------------

    describe("sender offline detection", function()
        it("aborts receive when sender is offline", function()
            -- Set up guild roster with OfficerB offline
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
                { name = "OfficerB-TestRealm", isOnline = false },
            }

            -- Start receiving from OfficerB
            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            assert.is_true(GBL:GetSyncStatus().receiving)

            -- Fire receive timeout — should detect offline and abort
            fireReceiveTimeout()

            assert.is_false(GBL:GetSyncStatus().receiving)
            -- Check audit trail mentions offline
            local trail = GBL:GetAuditTrail()
            local foundOffline = false
            for _, entry in ipairs(trail) do
                if entry.message:find("offline") then
                    foundOffline = true
                    break
                end
            end
            assert.is_true(foundOffline, "audit trail should mention offline")
        end)

        it("proceeds with NACK when sender is online", function()
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
                { name = "OfficerB-TestRealm", isOnline = true },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            -- Fire timeout — should send NACK (sender is online)
            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
            assert.is_true(#MockAce.sentCommMessages >= 1)
        end)

        it("proceeds with NACK when sender not found in roster", function()
            MockWoW.guildRoster = {
                { name = "OfficerA-TestRealm", isOnline = true },
            }

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            -- Fire timeout — nil return means proceed with NACK
            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
        end)

        it("proceeds with NACK when roster is empty", function()
            MockWoW.guildRoster = {}

            GBL:HandleSyncData("OfficerB", {
                chunk = 1, totalChunks = 3,
                transactions = {}, moneyTransactions = {},
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            MockAce.sentCommMessages = {}

            fireReceiveTimeout()

            assert.is_true(GBL:GetSyncStatus().receiving)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Offline abort during sync operations
    ---------------------------------------------------------------------------

    describe("offline abort", function()
        it("SendChunk aborts send when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            -- Set up a sending state
            local tx = {
                id = "tx1", tab = 1, type = "deposit", player = "Someone",
                timestamp = MockWoW.serverTime - 100, itemID = 12345,
                itemName = "Test Item", count = 1,
            }
            table.insert(guildData.transactions, tx)

            -- Simulate receiving a sync request from OnlinePeer
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }
            GBL:UpdatePeer("OnlinePeer", {
                version = GBL.version, txCount = 0, dataHash = 99,
                lastScanTime = MockWoW.serverTime,
            })

            local requestMsg = GBL:Serialize({
                type = "SYNC_REQUEST",
                sinceTimestamp = 0,
                version = GBL.version,
                protocolVersion = GBL.SYNC_PROTOCOL_VERSION,
                guild = "Test Guild",
            })
            requestMsg = GBL._compressMessage(requestMsg)
            GBL:OnSyncMessage("GBLSync", requestMsg, "WHISPER", "OnlinePeer")

            assert.is_true(GBL:IsSyncing())

            -- Now mark peer as offline and trigger next chunk
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = false },
            }
            MockAce.sentCommMessages = {}

            -- Advance past the inter-chunk gap floor so SendNextChunk proceeds
            -- to the offline check instead of deferring.
            MockWoW.serverTime = MockWoW.serverTime + 2

            -- Fire the ACK-triggered timer to attempt next chunk
            -- Since the first chunk was sent while online, we need to simulate
            -- the send completing and then the next attempt
            GBL:SendNextChunk()

            -- Should have aborted — sending state cleared
            assert.is_false(GBL:IsSyncing())
        end)

        it("RequestSync aborts receive when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            MockAce.sentCommMessages = {}
            GBL:RequestSync("OfflinePeer", 0)

            -- Should not have sent the request
            assert.equals(0, #MockAce.sentCommMessages)
            -- Receiving state should be cleaned up
            assert.is_false(GBL:IsSyncing())
        end)

        it("SendNack skips send when target is offline", function()
            GBL:RegisterComm(GBL.SYNC_PREFIX, "OnSyncMessage")

            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            MockAce.sentCommMessages = {}
            GBL:SendNack("OfflinePeer", 1)

            -- No message sent
            assert.equals(0, #MockAce.sentCommMessages)
        end)
    end)

    ---------------------------------------------------------------------------
    -- SendSyncWhisper (safe whisper wrapper)
    ---------------------------------------------------------------------------

    describe("SendSyncWhisper", function()
        it("blocks whisper to offline target", function()
            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "OfflinePeer")
            assert.is_false(result)
            assert.equals(0, #MockAce.sentCommMessages)
        end)

        it("allows whisper to online target", function()
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "OnlinePeer")
            assert.is_true(result)
            assert.equals(1, #MockAce.sentCommMessages)
            assert.equals("WHISPER", MockAce.sentCommMessages[1].distribution)
            assert.equals("OnlinePeer", MockAce.sentCommMessages[1].target)
        end)

        it("allows whisper when target not in roster (unknown)", function()
            MockWoW.guildRoster = {}
            MockAce.sentCommMessages = {}

            local result = GBL:SendSyncWhisper("GBLSync", "test", "UnknownPeer")
            assert.is_true(result)
            assert.equals(1, #MockAce.sentCommMessages)
        end)

        it("tracks whisper target in recentWhisperTargets", function()
            MockWoW.guildRoster = {
                { name = "OnlinePeer-TestRealm", isOnline = true },
            }

            GBL:SendSyncWhisper("GBLSync", "test", "OnlinePeer")
            assert.is_not_nil(GBL._recentWhisperTargets["OnlinePeer"])
            assert.equals(MockWoW.serverTime, GBL._recentWhisperTargets["OnlinePeer"])
        end)

        it("does not track offline target", function()
            MockWoW.guildRoster = {
                { name = "OfflinePeer-TestRealm", isOnline = false },
            }

            GBL:SendSyncWhisper("GBLSync", "test", "OfflinePeer")
            assert.is_nil(GBL._recentWhisperTargets["OfflinePeer"])
        end)
    end)
end)
