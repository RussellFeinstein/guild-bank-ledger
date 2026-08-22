------------------------------------------------------------------------
-- spec/sync_helpers.lua — shared plumbing for the spec/sync_*_spec.lua suite
------------------------------------------------------------------------
--
-- The sync tests were one 11,900-line file until #116 split them by topic.
-- These four helpers were file-locals in it, which meant any other spec file
-- wanting the same bootstrapping had to rebuild it (wire_contract_spec did).
-- They live here now so the nine sync spec files share one copy and a tenth
-- file can reuse it.
--
-- No `_spec` in the name, so .busted's `pattern = "_spec"` never collects this
-- as a test file. Same arrangement as spec/wire_helpers.lua, and loaded the
-- same way: `local Sync = require("spec.sync_helpers")`.
--
-- The timer helpers close over MockWoW only. That table is created once when
-- spec/helpers.lua is first required and mutated in place by install(), so
-- capturing it here at require time sees exactly what the spec files see.

local Helpers = require("spec.helpers")
local MockAce = Helpers.MockAce
local MockWoW = Helpers.MockWoW

local M = {}

--- Build the addon and its guild data the way every sync spec needs them.
-- Call from a before_each and assign both returns: the tests read GBL and
-- guildData as upvalues throughout.
-- @return table,table The addon object and the current guild's data table
function M.setup()
    Helpers.setupMocks()
    MockWoW.guild.name = "Test Guild"
    MockWoW.player.name = "OfficerA"
    local GBL = Helpers.loadAddon()
    GBL:OnInitialize()
    GBL.db.profile.sync.enabled = true
    GBL.db.profile.sync.autoSync = true
    local guildData = GBL:GetGuildData()
    -- Reset sync session state
    GBL:ResetSyncState()
    -- Clear sent messages from initialization
    MockAce.sentCommMessages = {}
    MockAce.sentMessages = {}
    return GBL, guildData
end

--- A SYNC_REQUEST payload from a peer running our own version.
-- Since v0.37.0 the serving side gates on the request's version fields, so
-- a payload without them is read as a pre-floor peer and refused. Tests
-- that are not about the gate say "same version as us" through this.
-- @param GBL table The addon object (the version is read off it)
-- @param fields table|nil Payload fields to carry through
function M.request(GBL, fields)
    fields = fields or {}
    if fields.version == nil then fields.version = GBL.version end
    return fields
end

--- Fire the pending one-shot ACK timer, and fail if there is not one.
-- The delay comes from the caller as GBL.SYNC_ACK_TIMEOUT rather than a
-- literal, and a miss is an error rather than a quiet no-op. Both matter: these
-- sites used to match a hardcoded 8, so when ACK_TIMEOUT became 3 they would
-- have matched nothing, and the tests that assert "still sending" after a
-- timeout would have passed without ever firing one.
-- @param delay number The production ACK_TIMEOUT
function M.fireAckTimeout(delay)
    for _, timer in ipairs(MockWoW.pendingTimers) do
        if timer.delay == delay and not timer.cancelled then
            timer.callback()
            return
        end
    end
    error(("no pending ACK timer at %ss to fire"):format(tostring(delay)), 2)
end

--- Fire the adaptive inter-chunk delay that HandleAck schedules the next chunk
-- on (INTER_CHUNK_DELAY_NORMAL 0.1s, or 0.5s once FPS adaptation kicks in).
-- HandleAck does not send inline, so without this there is no chunk in flight
-- and no ACK timer behind it. Takes the newest match, which is the one the ACK
-- just scheduled, and fails rather than no-op when there is none.
function M.fireNextChunkDelay()
    for i = #MockWoW.pendingTimers, 1, -1 do
        local timer = MockWoW.pendingTimers[i]
        if not timer.cancelled and timer.delay
            and timer.delay > 0.05 and timer.delay <= 1.0 then
            timer.callback()
            return timer.delay
        end
    end
    error("no pending inter-chunk delay timer to fire", 2)
end

--- Deliver a SYNC_REQUEST and let the serve preparation finish.
--
-- Preparing a serve runs across frames on a zero-delay chain (#115), so a
-- large enough dataset does not reach the first chunk inside the call. Small
-- ones still do: the whole preparation fits in one tick's budget and completes
-- synchronously, which is why the great majority of the specs in this suite
-- call HandleSyncRequest directly and are none the wiser.
--
-- Use this wherever a test seeds more records than SYNC_PREP_RECORDS_PER_TICK
-- covers, or asserts on something only the finished preparation produces.
-- Draining when there was nothing to drain is harmless.
-- @param GBL table The addon object
-- @param sender string The requesting peer
-- @param payload table The SYNC_REQUEST payload
function M.serveRequest(GBL, sender, payload)
    GBL:HandleSyncRequest(sender, payload)
    Helpers.drainZeroDelayTimers()
end

--- ACK every chunk and fire the inter-chunk gap until the send finishes.
--
-- Only the first chunk leaves synchronously, so any assertion about what a
-- session actually offered has to drive the rest the way a healthy peer would.
-- The clock has to move as well: SendNextChunk enforces a wall-clock gap floor
-- between issues, and against a frozen GetTime it just reschedules itself and
-- the send never leaves chunk one.
--
-- Bounded rather than looping until done, so a send that stops making progress
-- ends the test instead of hanging it.
-- @param GBL table The addon object
-- @param target string The peer being served
function M.drainSend(GBL, target)
    for _ = 1, 4000 do
        if not GBL:GetSyncStatus().sending then break end
        local idx = tonumber(GBL:GetSyncStatus().sendProgress:match("^(%d+)"))
        GBL:HandleAck(target, { chunk = idx })
        MockWoW.serverTime = MockWoW.serverTime + 2
        local fired = false
        for i = #MockWoW.pendingTimers, 1, -1 do
            local t = MockWoW.pendingTimers[i]
            if not t.cancelled and not t.fired and t.delay
                and t.delay > 0 and t.delay <= 2.0 then
                t.fired = true
                t.callback()
                fired = true
                break
            end
        end
        if not fired then break end
    end
end

--- Fire the latest uncancelled receive timeout timer (any delay).
-- With NACK backoff, delays change (20→30→45), so we can't match on exact delay.
-- Finds the last (newest) uncancelled ticker and fires it.
function M.fireReceiveTimeout()
    for i = #MockWoW.pendingTimers, 1, -1 do
        local timer = MockWoW.pendingTimers[i]
        if not timer.cancelled and timer.delay and timer.delay >= 10 then
            timer.callback()
            return true
        end
    end
    return false
end

return M
