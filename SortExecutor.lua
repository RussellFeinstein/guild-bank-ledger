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
local MOVE_CONFIRM_TIMEOUT = 4.0  -- seconds to wait for event before giving up
local MAX_REPLANS         = 5     -- per run
local SCAN_WAIT_TIMEOUT   = 10.0  -- seconds to wait for replan scan
-- Window after a timed-out op during which a late GUILDBANKBAGSLOTS_CHANGED
-- can retroactively reclassify that op as success. Without this, a genuine
-- late server ACK is misread as foreign activity and triggers replan.
local LATE_ACK_GRACE      = 5.0

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

--- Describe the current contents of a bank slot as a short string for audit:
--- "empty", "it:NNN x<count>", or "err" on missing data.
local function describeSlot(tabIndex, slotIndex)
    local link = GetGuildBankItemLink(tabIndex, slotIndex)
    if not link then return "empty" end
    local id = extractItemID(link)
    local _, c = GetGuildBankItemInfo(tabIndex, slotIndex)
    return string.format("it:%s x%d", tostring(id or "?"), c or 0)
end

--- Classify a timeout's observed src/dst/cursor state into one of:
--- "none"    — src unchanged, dst empty (server dropped the request outright)
--- "partial" — src emptied, cursor holds item (pickup done, drop never landed)
--- "complete"— src drained, dst has expected item (move succeeded, ACK lost)
--- "other"   — some other anomalous combination
local function classifyTimeoutState(op, srcDesc, dstDesc, cursorHasItem)
    local srcExpected = string.format("it:%d x", op.itemID)  -- prefix match
    local srcHasExpected = srcDesc:find(srcExpected, 1, true) == 1
    local dstHasExpected = dstDesc:find(srcExpected, 1, true) == 1
    local srcEmpty = (srcDesc == "empty")
    local dstEmpty = (dstDesc == "empty")
    if srcHasExpected and dstEmpty and not cursorHasItem then
        return "none"
    elseif srcEmpty and cursorHasItem then
        return "partial"
    elseif srcEmpty and dstHasExpected and not cursorHasItem then
        return "complete"
    else
        return "other"
    end
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

--- Emit a progress message for UI subscribers (notably UI/SortView).
--- Payload is a flat table with the sort's current state so listeners can
--- update without reading executor-local state. `phase` tags the reason for
--- the emission so a UI can choose to redraw differently, e.g. highlight
--- the active row on "step" vs. draw a "sort complete" overlay on "finish".
local function emitProgress(phase, extras)
    if not state then return end
    local payload = {
        phase = phase,
        opIndex = state.opIndex,
        done = state.done,
        failed = state.failed,
        replans = state.replans,
        total = #state.plan.ops,
        currentOp = state.plan.ops[state.opIndex],
    }
    if extras then
        for k, v in pairs(extras) do payload[k] = v end
    end
    GBL:SendMessage("GBL_SORT_PROGRESS", payload)
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
        reclassified = state.reclassified,
        preCheckFails = state.preCheckFails,
        cursorStuck = state.cursorStuck,
        timeoutByClass = state.timeoutByClass,
    }

    -- Single-line execution summary so the audit trail / chat log shows
    -- the full picture per run without the reader scrolling. Wall-clock
    -- elapsed since ExecuteSortPlan ran. Avg per-op uses ops attempted
    -- (done + failed) so it reflects the real pacing the user observed,
    -- not the planner's optimistic op count.
    local elapsed = (GetTime() and state.startedAt) and (GetTime() - state.startedAt) or 0
    local attempted = state.done + state.failed
    local avg = attempted > 0 and (elapsed / attempted) or 0
    local tbc = state.timeoutByClass
    GBL:AddAuditEntry(string.format(
        "Sort: %s in %.1fs — %d ops (%d done, %d failed, %d replans, %d reclass)"
        .. " preCheck=%d cursor=%d timeout[n=%d,p=%d,c=%d,o=%d] avg %.2fs/op",
        ok and "complete" or ("aborted (" .. (reason or "?") .. ")"),
        elapsed, #state.plan.ops, state.done, state.failed,
        state.replans, state.reclassified,
        state.preCheckFails, state.cursorStuck,
        tbc.none, tbc.partial, tbc.complete, tbc.other,
        avg))

    -- Emit the final progress message BEFORE clearing state so listeners
    -- get the completion summary without needing a separate event shape.
    emitProgress("finish", { ok = ok, reason = reason })
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
    emitProgress("replan", { replanReason = reason })

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
        -- Broadcast the new plan so UI listeners can rebuild their move
        -- list against the CURRENT plan, not the stale pre-replan one.
        -- Without this, per-op row markers drift onto the wrong moves
        -- and the progress counter references a plan the executor is
        -- no longer working on.
        emitProgress("planupdated", { plan = newPlan })
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
    local srcLink = GetGuildBankItemLink(op.srcTab, op.srcSlot)
    local srcID = srcLink and extractItemID(srcLink) or nil
    local _, srcCount = GetGuildBankItemInfo(op.srcTab, op.srcSlot)
    srcCount = srcCount or 0
    if srcID ~= op.itemID or srcCount < op.count then
        GBL:AddAuditEntry(string.format(
            "Sort op %d/%d pre-check fail src T%d/S%d: expected it:%d x>=%d, got %s x%d",
            myOpIndex, #state.plan.ops,
            op.srcTab, op.srcSlot, op.itemID, op.count,
            srcID and ("it:" .. srcID) or "empty", srcCount))
        state.preCheckFails = state.preCheckFails + 1
        doReplan("src mismatch at op " .. myOpIndex)
        return
    end

    -- Pre-verify dst: must be empty OR hold the same item (merge).
    local dstLink = GetGuildBankItemLink(op.dstTab, op.dstSlot)
    if dstLink then
        local dstID = extractItemID(dstLink)
        if dstID ~= op.itemID then
            local _, dstCount = GetGuildBankItemInfo(op.dstTab, op.dstSlot)
            GBL:AddAuditEntry(string.format(
                "Sort op %d/%d pre-check fail dst T%d/S%d: expected empty or it:%d, got it:%d x%d",
                myOpIndex, #state.plan.ops,
                op.dstTab, op.dstSlot, op.itemID,
                dstID, dstCount or 0))
            GBL:AddAuditEntry(string.format(
                "  op %d was: %s T%d/S%d -> T%d/S%d it:%d x%d",
                myOpIndex, op.op or "move",
                op.srcTab, op.srcSlot, op.dstTab, op.dstSlot,
                op.itemID, op.count))
            state.preCheckFails = state.preCheckFails + 1
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

    -- Notify UI subscribers that this op is now executing. SortView uses
    -- this to highlight the active row in its move list.
    emitProgress("step")

    -- Issue the move.
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
            emitProgress("complete", { completedOpIndex = myOpIndex })
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
        state.cursorStuck = state.cursorStuck + 1
        state.waiting = nil
        GBL:AddAuditEntry(
            string.format("Sort: op %d failed (cursor stuck after placement)", myOpIndex))
        state.opIndex = myOpIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        emitProgress("failed", { failedOpIndex = myOpIndex, reason = "cursor-stuck" })
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
        local completedAtTimeout = slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count)
        if completedAtTimeout then
            state.done = state.done + 1
            state.lastTimedOutOp = nil
        else
            state.failed = state.failed + 1
            -- Record the timeout so a late GUILDBANKBAGSLOTS_CHANGED arriving
            -- within LATE_ACK_GRACE can reclassify this as a success rather
            -- than triggering a foreign-activity replan.
            state.lastTimedOutOp = {
                opIndex = myOpIndex,
                dstTab = op.dstTab, dstSlot = op.dstSlot,
                itemID = op.itemID, count = op.count,
                at = GetTime(),
            }
            -- Dump live state so the audit trail reveals WHY the timeout
            -- fired — did the move never happen, partially happen (pickup
            -- done, drop failed), or fully happen with a silent ACK?
            local srcDesc = describeSlot(op.srcTab, op.srcSlot)
            local dstDesc = describeSlot(op.dstTab, op.dstSlot)
            local cursorHas = _G.CursorHasItem and _G.CursorHasItem() or false
            local class = classifyTimeoutState(op, srcDesc, dstDesc, cursorHas)
            if state.timeoutByClass[class] then
                state.timeoutByClass[class] = state.timeoutByClass[class] + 1
            else
                state.timeoutByClass.other = state.timeoutByClass.other + 1
            end
            GBL:AddAuditEntry(string.format(
                "Sort: op %d timed out (no confirm within %ds) [%s]",
                myOpIndex, MOVE_CONFIRM_TIMEOUT, class))
            GBL:AddAuditEntry(string.format(
                "  op %d was: %s T%d/S%d -> T%d/S%d it:%d x%d",
                myOpIndex, op.op or "move",
                op.srcTab, op.srcSlot, op.dstTab, op.dstSlot,
                op.itemID, op.count))
            GBL:AddAuditEntry(string.format(
                "  observed: src %s, dst %s, cursor %s",
                srcDesc, dstDesc, cursorHas and "held" or "empty"))
        end
        state.waiting = nil
        state.opIndex = myOpIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        if completedAtTimeout then
            emitProgress("complete", { completedOpIndex = myOpIndex })
        else
            emitProgress("failed", { failedOpIndex = myOpIndex, reason = "timeout" })
        end
        step()
    end)
end

------------------------------------------------------------------------
-- Event handlers
------------------------------------------------------------------------

function GBL:_SortExecutor_OnSlotsChanged()
    if not state then return end

    -- First, check if this event is the late ACK for a recently-timed-out
    -- op. The server may have processed the move after we'd already armed
    -- the next op's waiting state, so this check must run independent of
    -- whether state.waiting is currently populated. Without this, the
    -- reclassification only fires when no in-flight op exists, which is
    -- almost never true during a live sort (the gap between ops is 0.3s).
    local reclassified = false
    local lto = state.lastTimedOutOp
    if lto and (GetTime() - lto.at) <= LATE_ACK_GRACE and
       slotHasAtLeast(lto.dstTab, lto.dstSlot, lto.itemID, lto.count) then
        state.done = state.done + 1
        state.failed = state.failed - 1
        state.reclassified = state.reclassified + 1
        GBL:AddAuditEntry(string.format(
            "Sort: op %d confirmed by late event after timeout — reclassified as success",
            lto.opIndex))
        emitProgress("reclassify", { reclassifiedOpIndex = lto.opIndex })
        state.lastTimedOutOp = nil
        reclassified = true
        -- Fall through: the same event may *also* be the ACK for the
        -- current in-flight op, or there may be genuine foreign activity
        -- to replan around. Don't short-circuit here.
    end

    local w = state.waiting
    if w then
        if slotHasAtLeast(w.tabIndex, w.slotIndex, w.itemID, w.count) then
            state.done = state.done + 1
            state.waiting = nil
            state.lastTimedOutOp = nil
            state.opIndex = state.opIndex + 1
            state.gapUntil = GetTime() + INTER_MOVE_GAP
            emitProgress("complete", { completedOpIndex = w.opIndex })
            step()
        end
        -- Slot doesn't match the in-flight op yet — still mid-sequence
        -- (pickup fired, place hasn't) or unrelated event. The
        -- MOVE_CONFIRM_TIMEOUT handler will resolve this op if no further
        -- event advances us.
        return
    end

    -- No in-flight op. If we reclassified a late ACK, the event is fully
    -- explained. Otherwise it's genuine foreign activity → replan.
    if not reclassified then
        doReplan("foreign activity (unexpected event)")
    end
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
        -- Diagnostic counters dumped by finish() into a single audit line.
        startedAt = GetTime(),
        reclassified = 0,
        preCheckFails = 0,
        cursorStuck = 0,
        timeoutByClass = { none = 0, partial = 0, complete = 0, other = 0 },
    }
    registerBankEvents()
    GBL:AddAuditEntry(
        string.format("Sort: starting execution of %d ops", #plan.ops))
    emitProgress("start")
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
    SCAN_WAIT_TIMEOUT = SCAN_WAIT_TIMEOUT,
    LATE_ACK_GRACE = LATE_ACK_GRACE,
}

function GBL:_sortExecutorInjectTimeout(info)
    -- Test hook: pretend op `info.opIndex` (targeting `info.dstTab`/`info.dstSlot`
    -- with `info.itemID` x `info.count`) just timed out and its failure was
    -- recorded. The next GUILDBANKBAGSLOTS_CHANGED will be classified as a
    -- late ACK if the dst slot is now populated.
    if not state then return end
    state.failed = state.failed + 1
    state.lastTimedOutOp = {
        opIndex = info.opIndex,
        dstTab = info.dstTab, dstSlot = info.dstSlot,
        itemID = info.itemID, count = info.count,
        at = GetTime(),
    }
end
