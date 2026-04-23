------------------------------------------------------------------------
-- GuildBankLedger — SortExecutor.lua
-- Consumes a plan from SortPlanner and executes the moves one at a time
-- with throttling, per-step pre-verification, cursor safety, bank-close
-- abort, and replan-on-foreign-activity.
--
-- Public API:
--   GBL:ExecuteSortPlan(plan, onComplete)
--     Starts executing `plan`. `onComplete(result)` is called when the
--     run ends (success, abort, or cap-exceeded). `result` is:
--       { ok = true|false, reason = string, done = N, failed = M,
--         total = K, replans = R }
--   GBL:CancelSortExecution()
--     Cancels the current run. Calls ClearCursor, fires onComplete with
--     reason="cancelled".
--   GBL:IsSortRunning() -> boolean
--
-- Invariants:
--   * Never leave an item on cursor across yields; every exit path that
--     might hold one calls ClearCursor().
--   * Never exceed MAX_REPLANS (5) replans per run.
--   * Abort immediately on bank close (PLAYER_INTERACTION_MANAGER_FRAME_HIDE
--     for GuildBanker). The caller detects this via onComplete.
--   * Minimum INTER_MOVE_GAP seconds between issued moves.
--   * After issuing a move, wait up to MOVE_CONFIRM_TIMEOUT seconds for
--     GUILDBANKBAGSLOTS_CHANGED to fire; then verify the expected state.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local INTER_MOVE_GAP      = 0.3   -- seconds between moves
local MOVE_CONFIRM_TIMEOUT = 2.0  -- seconds to wait for event before giving up
local MAX_REPLANS         = 5     -- per run
local SCAN_WAIT_TIMEOUT   = 5.0   -- seconds to wait for replan scan

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function extractItemID(itemLink)
    if type(itemLink) ~= "string" then return nil end
    local id = itemLink:match("Hitem:(%d+)")
    return id and tonumber(id) or nil
end

--- Post-state verification: check that a slot contains AT LEAST the expected
-- contents. Used after a move completes.
local function slotHasAtLeast(tabIndex, slotIndex, itemID, count)
    local link = GetGuildBankItemLink(tabIndex, slotIndex)
    if not link then return false end
    local id = extractItemID(link)
    if id ~= itemID then return false end
    local _, c = GetGuildBankItemInfo(tabIndex, slotIndex)
    return (c or 0) >= count
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local state = nil
-- Shape when running:
-- {
--   plan = { ops = {...}, ... },
--   layout = {...},           -- kept for replan
--   opIndex = N,              -- next op to issue
--   replans = R,
--   done = N, failed = M,
--   waiting = nil | { tabIndex, slotIndex, itemID, count, startedAt, retries },
--   onComplete = fn,
--   gapUntil = seconds,
-- }

local function isRunning()
    return state ~= nil
end

function GBL:IsSortRunning()
    return isRunning()
end

-- Forward declarations so mutual references resolve at load time.
local step
local finish
local registerBankEvents
local unregisterBankEvents

function registerBankEvents()
    GBL:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", "_SortExecutor_OnSlotsChanged")
    -- Core.lua already owns PLAYER_INTERACTION_MANAGER_FRAME_HIDE; we detect
    -- bank-closed through GBL:IsBankOpen() at step boundaries plus the
    -- dedicated handler below which we register on top (AceEvent allows
    -- multiple handlers since we share the addon object).
    GBL:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "_SortExecutor_OnFrameHide")
end

function unregisterBankEvents()
    pcall(function()
        GBL:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    end)
    -- Leave PLAYER_INTERACTION_MANAGER_FRAME_HIDE registered — Core re-uses it.
    -- Our handler is idempotent when not running.
end

function finish(ok, reason)
    if not state then return end
    local cb = state.onComplete
    local result = {
        ok = ok,
        reason = reason,
        done = state.done,
        failed = state.failed,
        total = #state.plan.ops,
        replans = state.replans,
    }
    ClearCursor()
    unregisterBankEvents()
    state = nil
    if cb then
        local success, err = pcall(cb, result)
        if not success then
            GBL:Print("SortExecutor onComplete error: " .. tostring(err))
        end
    end
end

------------------------------------------------------------------------
-- Replan
------------------------------------------------------------------------

local function doReplan(reason)
    if not state then return end
    if state.replans >= MAX_REPLANS then
        finish(false, "replan cap exceeded (" .. reason .. ")")
        return
    end
    state.replans = state.replans + 1
    ClearCursor()
    state.waiting = nil

    GBL:AddAuditEntry(
        string.format("Sort: replan %d/%d (%s)", state.replans, MAX_REPLANS, reason))

    -- Start a fresh scan, then rebuild the plan from the new snapshot.
    GBL:StartFullScan()
    local deadline = GetTime() + SCAN_WAIT_TIMEOUT
    local function waitForScan()
        if not state then return end
        if GBL.scanInProgress then
            if GetTime() > deadline then
                finish(false, "scan-wait timeout during replan")
                return
            end
            C_Timer.After(0.25, waitForScan)
            return
        end
        local snapshot = GBL:GetLastScanResults()
        if not snapshot then
            finish(false, "scan returned no snapshot")
            return
        end
        local newPlan = GBL:PlanSort(snapshot, state.layout)
        state.plan = newPlan
        state.opIndex = 1
        state.waiting = nil
        -- Resume stepping.
        step()
    end
    C_Timer.After(0.1, waitForScan)
end

------------------------------------------------------------------------
-- Step: issue the next op.
------------------------------------------------------------------------

step = function()
    if not state then return end

    -- Bank closed? Abort.
    if not GBL:IsBankOpen() then
        finish(false, "bank closed")
        return
    end

    -- All done?
    if state.opIndex > #state.plan.ops then
        finish(true, "complete")
        return
    end

    -- Throttle: honor the inter-move gap.
    local now = GetTime()
    if state.gapUntil and now < state.gapUntil then
        C_Timer.After(state.gapUntil - now, function()
            if isRunning() then step() end
        end)
        return
    end

    local op = state.plan.ops[state.opIndex]
    local myOpIndex = state.opIndex

    -- Pre-verify src: must have at least op.count of op.itemID.
    if not slotHasAtLeast(op.srcTab, op.srcSlot, op.itemID, op.count) then
        doReplan("src mismatch at op " .. myOpIndex)
        return
    end

    -- Pre-verify dst: must be empty OR hold the same item (merge).
    local dstLink = GetGuildBankItemLink(op.dstTab, op.dstSlot)
    if dstLink then
        local dstID = extractItemID(dstLink)
        if dstID ~= op.itemID then
            doReplan("dst occupied by wrong item at op " .. myOpIndex)
            return
        end
    end

    -- Arm confirmation state BEFORE issuing so events during the pickup/place
    -- sequence find it populated. The handler ignores events whose post-state
    -- doesn't yet match; the event fired after the final PickupGuildBankItem
    -- advances us.
    state.waiting = {
        tabIndex = op.dstTab, slotIndex = op.dstSlot,
        itemID = op.itemID, count = op.count,
        opIndex = myOpIndex,
        startedAt = GetTime(),
    }

    -- Issue the move.
    local _, srcCount = GetGuildBankItemInfo(op.srcTab, op.srcSlot)
    if op.op == "split" and srcCount and srcCount > op.count then
        SplitGuildBankItem(op.srcTab, op.srcSlot, op.count)
    else
        PickupGuildBankItem(op.srcTab, op.srcSlot)
    end
    PickupGuildBankItem(op.dstTab, op.dstSlot)

    -- Synchronous environments (like the mock) already ran the handler by
    -- now. If state.waiting still matches `myOpIndex`, the handler hasn't
    -- advanced us (either no event fired or post-state didn't match).
    -- In WoW itself, GUILDBANKBAGSLOTS_CHANGED is async, so this branch
    -- effectively just schedules the fallback timer.
    if state and state.waiting and state.waiting.opIndex == myOpIndex then
        -- Final direct check — if the mutation already landed, advance now
        -- (covers sync paths and rare event-merge cases).
        if slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count) and
           not (_G.CursorHasItem and _G.CursorHasItem()) then
            state.done = state.done + 1
            state.waiting = nil
            state.opIndex = myOpIndex + 1
            state.gapUntil = GetTime() + INTER_MOVE_GAP
            C_Timer.After(INTER_MOVE_GAP, function()
                if isRunning() then step() end
            end)
            return
        end
    end

    -- Cursor stuck after placement? Clear and fail this op, advance.
    if _G.CursorHasItem and _G.CursorHasItem() then
        ClearCursor()
        state.failed = state.failed + 1
        state.waiting = nil
        GBL:AddAuditEntry(
            string.format("Sort: op %d failed (cursor stuck after placement)", myOpIndex))
        state.opIndex = myOpIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        C_Timer.After(INTER_MOVE_GAP, function()
            if isRunning() then step() end
        end)
        return
    end

    -- Safety timeout: verify-by-polling if no event resolves us in time.
    C_Timer.After(MOVE_CONFIRM_TIMEOUT, function()
        if not state or not state.waiting or state.waiting.opIndex ~= myOpIndex then
            return  -- already advanced
        end
        if slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count) then
            state.done = state.done + 1
        else
            state.failed = state.failed + 1
            GBL:AddAuditEntry(
                string.format("Sort: op %d timed out (no confirm within %ds)",
                    myOpIndex, MOVE_CONFIRM_TIMEOUT))
        end
        state.waiting = nil
        state.opIndex = myOpIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        step()
    end)
end

------------------------------------------------------------------------
-- Event handlers
------------------------------------------------------------------------

function GBL:_SortExecutor_OnSlotsChanged()
    if not state then return end
    local w = state.waiting
    if not w then
        -- Event fired while we're not in a move (between ops or during throttle).
        -- That's foreign activity — trigger replan.
        doReplan("foreign activity (unexpected event)")
        return
    end
    if slotHasAtLeast(w.tabIndex, w.slotIndex, w.itemID, w.count) then
        state.done = state.done + 1
        state.waiting = nil
        state.opIndex = state.opIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        step()
    end
    -- Slot doesn't match yet — still mid-sequence (pickup fired, place hasn't)
    -- or foreign activity. Fallthrough: the MOVE_CONFIRM_TIMEOUT handler will
    -- make a final decision if no further event advances us.
end

function GBL:_SortExecutor_OnFrameHide(_event, interactionType)
    if not state then return end
    if Enum and Enum.PlayerInteractionType and
       interactionType == Enum.PlayerInteractionType.GuildBanker then
        finish(false, "bank closed")
    end
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Begin executing a plan.
-- @param plan table from SortPlanner
-- @param onComplete function(result) called when the run ends
-- @param opts table|nil { layout = layoutForReplan }
-- @return ok, errMessage
function GBL:ExecuteSortPlan(plan, onComplete, opts)
    if isRunning() then return false, "sort already running" end
    if not plan or not plan.ops then return false, "invalid plan" end
    if not self:IsBankOpen() then return false, "bank not open" end

    state = {
        plan = plan,
        layout = opts and opts.layout or nil,
        opIndex = 1,
        replans = 0,
        done = 0, failed = 0,
        waiting = nil,
        onComplete = onComplete,
        gapUntil = 0,
    }
    registerBankEvents()
    GBL:AddAuditEntry(
        string.format("Sort: starting execution of %d ops", #plan.ops))
    step()
    return true, nil
end

--- Cancel a running sort.
function GBL:CancelSortExecution()
    if not state then return end
    GBL:AddAuditEntry(
        string.format("Sort: cancelled at op %d of %d", state.opIndex, #state.plan.ops))
    finish(false, "cancelled")
end

-- Expose internals for tests
GBL._sortExecutorConstants = {
    INTER_MOVE_GAP = INTER_MOVE_GAP,
    MOVE_CONFIRM_TIMEOUT = MOVE_CONFIRM_TIMEOUT,
    MAX_REPLANS = MAX_REPLANS,
}
