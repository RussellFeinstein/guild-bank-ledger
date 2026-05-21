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
-- v0.32.8 B2: gap to use after an interim-poll advance (vs the default
-- INTER_MOVE_GAP after a sync or async-event advance). Interim polls fire
-- at 0.25/0.5/1.0/2.0 s; an advance via these has had less real time on
-- the server than a 4.0 s late-poll path, so we give the server a slightly
-- longer cushion before issuing the next op.
local INTER_MOVE_GAP_AFTER_INTERIM = 0.5
-- v0.32.8 B2: schedule poll attempts at these offsets after Pickup. Each
-- poll re-runs the same advance predicates the sync path uses; first one
-- to pass advances the op via the [interim-poll] audit tag.
local INTERIM_POLL_OFFSETS = { 0.25, 0.5, 1.0, 2.0 }

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
--- "empty", "<name> (it:NNN) x<count>", or "err" on missing data.
local function describeSlot(tabIndex, slotIndex)
    local link = GetGuildBankItemLink(tabIndex, slotIndex)
    if not link then return "empty" end
    local id = extractItemID(link)
    local _, c = GetGuildBankItemInfo(tabIndex, slotIndex)
    local name = (id and GBL.DescribeItem) and GBL:DescribeItem(id) or
        ("it:" .. tostring(id or "?"))
    return string.format("%s x%d", name, c or 0)
end

--- Render a planner-stamped slot snapshot ({itemID, count} or nil) as the
--- same shorthand used by describeSlot, so pre-check-fail audit lines can
--- show planner-expected vs bank-reality side-by-side.
local function describePlannerSlot(snap)
    if not snap then return "empty" end
    local name = (snap.itemID and GBL.DescribeItem)
        and GBL:DescribeItem(snap.itemID) or ("it:" .. tostring(snap.itemID))
    return string.format("%s x%d", name, snap.count or 0)
end

--- Snapshot a live bank slot into a comparable {itemID, count} table.
--- Used to capture the pre-op state right before Pickup so we can detect
--- a later server-side reversion (the WoW client updates optimistically;
--- the only authoritative signal is a follow-up GUILDBANKBAGSLOTS_CHANGED
--- event reflecting the server's actual decision).
local function snapshotLiveSlot(tabIndex, slotIndex)
    local link = GetGuildBankItemLink(tabIndex, slotIndex)
    if not link then return nil end
    local id = extractItemID(link)
    local _, c = GetGuildBankItemInfo(tabIndex, slotIndex)
    return { itemID = id, count = c or 0 }
end

--- Compare two slot snapshots ({itemID, count} or nil). Returns true iff
--- both are nil OR both have matching itemID and count.
local function slotEquals(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    return a.itemID == b.itemID and a.count == b.count
end

--- Verify the operation's src actually drained as expected.
--- Returns true iff the live src state shows the move/split happened.
---
--- The WoW client optimistically updates bank slots on Pickup, so the
--- executor's existing dst+cursor success check (`slotHasAtLeast(dst) and
--- not CursorHasItem()`) trivially passes when dst already held the same
--- item at max-stack capacity — a same-item full-merge is a true no-op
--- (drop refused, cursor returns to src) but looks like success from the
--- dst+cursor predicate alone. This src-drained predicate is what
--- distinguishes a real success from a phantom one:
---
---   * "move" op:  src must be empty OR hold a different item.
---   * "split" op: src.count must have decreased by at least op.count.
---
--- Used by every advance path in the executor (sync, async, late-poll).
local function srcDrainedAsExpected(w)
    if not w then return false end
    local srcPost = snapshotLiveSlot(w.srcTab or 0, w.srcSlot or 0)
    if w.opLabel == "split" then
        local pre = (w.srcPreOp and w.srcPreOp.count) or 0
        local post = (srcPost and srcPost.count) or 0
        return (pre - post) >= (w.count or 0)
    end
    -- Move (default): src empty OR different item.
    return (srcPost == nil) or (srcPost.itemID ~= w.itemID)
end

--- v0.32.8 B2: cancel any interim-poll timers attached to the given
--- waiting record. Called from every advance / abort / cleanup path so
--- a poll firing after state tears down can't double-advance or trip
--- assertions. Tolerant of missing `pollTimers` field (legacy waiters,
--- or a waiter cleaned up partway).
local function cancelPollTimers(w)
    if not w or not w.pollTimers then return end
    for _, t in ipairs(w.pollTimers) do
        if t and t.Cancel then t:Cancel() end
    end
    w.pollTimers = {}
end

--- Audit a "no-op suspected" line for an op whose dst+cursor look like
--- success but whose src never drained. Surfaces phantom success cases
--- so the post-mortem identifies which op was rejected by the server
--- without the executor advancing past it.
local function auditOpNoop(w, branch)
    if not w then return end
    local itemDesc = (w.itemID and GBL.DescribeItem)
        and GBL:DescribeItem(w.itemID) or ("it:" .. tostring(w.itemID))
    GBL:SortWarn(string.format(
        "Sort op %d no-op suspected [%s]: %s T%d/S%d->T%d/S%d %s x%d "
        .. "(dst already held expected item; src unchanged)",
        w.opIndex, branch, w.opLabel or "move",
        w.srcTab or 0, w.srcSlot or 0,
        w.tabIndex, w.slotIndex,
        itemDesc, w.count or 0))
end

--- Classify a timeout's observed src/dst/cursor state into one of:
--- "server-rejected" — src unchanged, dst empty (server dropped the pickup
---                     before drop landed). 3-strike abort candidate.
--- "partial"         — src emptied, cursor holds item (pickup done, drop
---                     never landed).
--- "complete"        — src drained, dst has expected item (move succeeded,
---                     ACK lost). Also covers the merge case where the
---                     planner intended a same-item merge and got one.
--- "merge-noop"      — src unchanged, dst has expected item, cursor empty,
---                     and planner intended dst to be EMPTY at emit time.
---                     Op was a no-op because some other item arrived at
---                     dst between emit and execute, or the planner
---                     emitted into a slot that was already populated.
---                     3-strike abort candidate. Pre-v0.32.8 this fell
---                     into "other".
--- "drain-pending"   — like merge-noop (src unchanged, dst has expected item,
---                     cursor empty, planner expected dst empty) BUT the live
---                     pre-op dst was empty/other, so THIS op deposited the
---                     item we now see and only the source-drain lags. A
---                     guild-bank split deposits into dst before the client
---                     reflects the source decrement. NOT a refusal: excluded
---                     from the 3-strike abort so a real (if slow) sort runs
---                     to completion instead of bailing on its own progress.
--- "other"           — some other anomalous combination.
---
--- Classifies from structured live-slot snapshots (srcLive / dstLive are
--- {itemID, count} tables or nil for empty, as returned by snapshotLiveSlot),
--- NOT from the human-readable describeSlot string. In-game DescribeItem
--- prefixes the resolved item name (e.g. "Flask (it:NNN) xN"), so the old
--- "it:NNN x" position-1 prefix match never fired and every non-empty timeout
--- collapsed into "other" — the merge-noop / server-rejected buckets and the
--- 3-strike abort keyed off them were dead outside the no-item-name test env.
local function classifyTimeoutState(op, srcLive, dstLive, cursorHasItem, dstPreLive)
    local srcHasExpected = srcLive ~= nil and srcLive.itemID == op.itemID
    local dstHasExpected = dstLive ~= nil and dstLive.itemID == op.itemID
    local srcEmpty = (srcLive == nil)
    local dstEmpty = (dstLive == nil)
    if srcHasExpected and dstEmpty and not cursorHasItem then
        return "server-rejected"
    elseif srcEmpty and cursorHasItem then
        return "partial"
    elseif srcEmpty and dstHasExpected and not cursorHasItem then
        return "complete"
    elseif srcHasExpected and dstHasExpected and not cursorHasItem then
        -- Planner intent disambiguates a real merge-success-with-lost-ACK
        -- (treated as "complete") from a no-op refusal (treated as
        -- "merge-noop"). The planner's emit-time projection of dst is
        -- frozen on the op as plannerDstAt. If the planner expected dst
        -- to already hold this item, the timeout-observed dst state is
        -- consistent with the intended merge and the ACK was just lost.
        local pdst = op.plannerDstAt
        local pdstHasSameItem = pdst and pdst.itemID == op.itemID
            and (pdst.count or 0) > 0
        if pdstHasSameItem then
            return "complete"
        end
        -- src still holds the item AND dst now holds it too, planner expected
        -- dst empty. Discriminate a fresh deposit whose source-drain merely
        -- lags (a guild-bank split deposits into dst before the client
        -- reflects the source decrement) from a genuine no-op (dst already
        -- held this item pre-op, so nothing was deposited and the move was
        -- refused). dstPreLive is the live pre-op dst snapshot: nil or a
        -- different item means THIS op deposited what we now see.
        local depositedFresh = (dstPreLive == nil) or (dstPreLive.itemID ~= op.itemID)
        if depositedFresh then
            return "drain-pending"
        end
        return "merge-noop"
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
--   preWarming = true while the pre-warm phase runs; suppresses the
--     slots-changed handler so foreign bank activity during the window
--     can't replan/step before items are loaded (see ExecuteSortPlan).
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
    -- We do NOT register PLAYER_INTERACTION_MANAGER_FRAME_HIDE here. Core owns it
    -- (Core.lua OnEnable), and AceEvent keeps one callback per (object, event):
    -- registering it again on the shared GBL object would overwrite Core's handler
    -- and never restore it, silently disabling Core's OnBankClosed cleanup after
    -- the first sort. Instead Core's OnBankClosed calls GBL:_SortExecutorOnBankClosed
    -- to abort a running sort. Bank-close is also caught at step boundaries via
    -- GBL:IsBankOpen() as a backstop.
end

function unregisterBankEvents()
    pcall(function()
        GBL:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    end)
end

--- Project the EXPECTED post-op state for a slot, given the op intent
--- and the pre-op state. For a "move" op, src ends empty and dst gains
--- (or merges) the moved stack. For a "split" op, src loses op.count
--- and dst gains op.count. Used by the foreign-activity branch later
--- to compare actual bank state against what we'd see if the server
--- had honored the op.
local function projectPostSrc(w)
    if not w or not w.srcPreOp then return nil end
    if w.opLabel == "split" then
        local remaining = (w.srcPreOp.count or 0) - (w.count or 0)
        if remaining <= 0 then return nil end
        return { itemID = w.srcPreOp.itemID, count = remaining }
    end
    return nil  -- move drains src
end

local function projectPostDst(w)
    if not w then return nil end
    local pre = w.dstPreOp
    if not pre then
        return { itemID = w.itemID, count = w.count }
    end
    if pre.itemID == w.itemID then
        return { itemID = w.itemID, count = (pre.count or 0) + (w.count or 0) }
    end
    -- Foreign item at dst at pre-op time means a swap; we don't model that
    -- in projection (rare and the planner shouldn't emit such ops post-fix).
    return { itemID = w.itemID, count = w.count }
end

--- Emit a one-line audit entry for a successfully completed op. Captures
--- src→dst, item, count, op label, wall-clock elapsed, and the OBSERVED
--- post-op state of both slots (which in real WoW reflects the client's
--- optimistic model, not necessarily the server's authoritative answer).
--- Side-effect: stashes a "last completed op" record on state so the
--- foreign-activity branch can detect server reversion against the same
--- post-op projection.
local function auditOpSuccess(w, suffix)
    if not w then return end
    local elapsed = w.startedAt and (GetTime() - w.startedAt) or 0
    local itemDesc = (w.itemID and GBL.DescribeItem)
        and GBL:DescribeItem(w.itemID) or ("it:" .. tostring(w.itemID))
    local srcPost = snapshotLiveSlot(w.srcTab or 0, w.srcSlot or 0)
    local dstPost = snapshotLiveSlot(w.tabIndex, w.slotIndex)
    GBL:SortInfo(string.format(
        "Sort op %d done: %s T%d/S%d->T%d/S%d %s x%d (%.1fs)%s src=%s dst=%s",
        w.opIndex, w.opLabel or "move",
        w.srcTab or 0, w.srcSlot or 0,
        w.tabIndex, w.slotIndex,
        itemDesc, w.count, elapsed,
        suffix and (" " .. suffix) or "",
        describePlannerSlot(srcPost),
        describePlannerSlot(dstPost)))

    -- Stash for server-reversion detection on the next foreign-activity
    -- event. We compare slot state at that future time against the
    -- projected post-op state computed here.
    if state then
        state.lastCompletedOp = {
            opIndex = w.opIndex,
            opLabel = w.opLabel,
            srcTab = w.srcTab, srcSlot = w.srcSlot,
            dstTab = w.tabIndex, dstSlot = w.slotIndex,
            itemID = w.itemID, count = w.count,
            srcPreOp = w.srcPreOp,
            dstPreOp = w.dstPreOp,
            projectedSrc = projectPostSrc(w),
            projectedDst = projectPostDst(w),
            completedAt = GetTime(),
        }
    end
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
        projectionDrifts = state.projectionDrifts or 0,
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
    GBL:SortInfo(string.format(
        "Sort: %s in %.1fs - %d ops (%d done, %d failed, %d replans, %d reclass)"
        .. " preCheck=%d cursor=%d timeout[s=%d,p=%d,c=%d,m=%d,dp=%d,o=%d]"
        .. " drifts=%d avg %.2fs/op",
        ok and "complete" or ("aborted (" .. (reason or "?") .. ")"),
        elapsed, #state.plan.ops, state.done, state.failed,
        state.replans, state.reclassified,
        state.preCheckFails, state.cursorStuck,
        tbc["server-rejected"], tbc.partial, tbc.complete,
        tbc["merge-noop"], tbc["drain-pending"], tbc.other,
        state.projectionDrifts or 0,
        avg))

    -- Emit the final progress message BEFORE clearing state so listeners
    -- get the completion summary without needing a separate event shape.
    emitProgress("finish", { ok = ok, reason = reason })
    ClearCursor()
    -- v0.32.8 B2: clear any interim-poll timers still pending before we
    -- drop state. The poll callbacks' state-first guard would handle a
    -- post-finish fire, but explicit cancel avoids a class of bugs where
    -- a future change to the guard accidentally drops the check.
    cancelPollTimers(state.waiting)
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
    -- v0.32.8 B2: cancel any pending interim-poll timers before clearing
    -- state.waiting; otherwise the timers fire against a stale opIndex and
    -- their state-first guard correctly no-ops, but cancelling here is
    -- cheaper and clearer.
    cancelPollTimers(state.waiting)
    state.waiting = nil
    -- v0.32.8 B1.F1: replan changes plan structure, so the per-item
    -- consecutive-refusal counter no longer reflects the same plan.
    -- Without this reset, 2 refusals + replan + 1 refusal on the same
    -- item would falsely trip the 3-strike abort even though the plan
    -- between strikes 2 and 3 changed.
    state.consecutiveRefusedByItem = {}

    GBL:SortInfo(
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

    -- An op is already in flight. Its confirmation path (the slots-changed
    -- handler or the timeout poll) drives the next step; refuse to issue a
    -- second op on top of it. Without this guard two step() drivers (e.g. a
    -- replan resume and the pre-warm completion callback) could double-issue
    -- the same op. Placed after the bank-open check so a redundant step()
    -- during a bank-close still aborts correctly.
    if state.waiting then return end

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
        GBL:SortWarn(string.format(
            "Sort op %d/%d pre-check fail src T%d/S%d: expected %s x>=%d, got %s",
            myOpIndex, #state.plan.ops,
            op.srcTab, op.srcSlot,
            GBL.DescribeItem and GBL:DescribeItem(op.itemID) or ("it:" .. op.itemID),
            op.count,
            describeSlot(op.srcTab, op.srcSlot)))
        if op.plannerSrcAt then
            GBL:SortWarn(string.format(
                "  planner expected src at emit: %s",
                describePlannerSlot(op.plannerSrcAt)))
        end
        state.preCheckFails = state.preCheckFails + 1
        doReplan("src mismatch at op " .. myOpIndex)
        return
    end

    -- Pre-verify dst: must be empty OR hold the same item (merge).
    local dstLink = GetGuildBankItemLink(op.dstTab, op.dstSlot)
    if dstLink then
        local dstID = extractItemID(dstLink)
        if dstID ~= op.itemID then
            GBL:SortWarn(string.format(
                "Sort op %d/%d pre-check fail dst T%d/S%d: expected empty or %s, got %s",
                myOpIndex, #state.plan.ops,
                op.dstTab, op.dstSlot,
                GBL.DescribeItem and GBL:DescribeItem(op.itemID) or ("it:" .. op.itemID),
                describeSlot(op.dstTab, op.dstSlot)))
            -- Planner-expected dst at the moment THIS op was emitted.
            -- A divergence between this and bank reality identifies an
            -- earlier op that the planner thought would clear/transform
            -- the dst slot but in practice didn't. plannerDstAt is set
            -- on every emitted op (nil means the planner expected the
            -- slot to be empty at emit time).
            GBL:SortWarn(string.format(
                "  planner expected dst at emit: %s",
                describePlannerSlot(op.plannerDstAt)))
            GBL:SortWarn(string.format(
                "  op %d was: %s T%d/S%d -> T%d/S%d %s x%d",
                myOpIndex, op.op or "move",
                op.srcTab, op.srcSlot, op.dstTab, op.dstSlot,
                GBL.DescribeItem and GBL:DescribeItem(op.itemID) or ("it:" .. op.itemID),
                op.count))
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
        srcTab = op.srcTab, srcSlot = op.srcSlot,
        itemID = op.itemID, count = op.count,
        opIndex = myOpIndex,
        opLabel = op.op or "move",
        startedAt = GetTime(),
        -- Pre-op live state at the exact moment we're about to issue
        -- the Pickup pair. Together with the post-op observed state and
        -- the projected post-op state (computed from the op intent),
        -- this lets the foreign-activity branch later detect server
        -- reversion: if the dst slot snaps back to its pre-op contents
        -- AFTER we advanced past this op, the server rejected the move.
        srcPreOp = snapshotLiveSlot(op.srcTab, op.srcSlot),
        dstPreOp = snapshotLiveSlot(op.dstTab, op.dstSlot),
        -- v0.32.8 B2: timers scheduled by the interim-poll cascade; cleared
        -- by cancelPollTimers() on every advance / abort path.
        pollTimers = {},
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
        -- (covers sync paths and rare event-merge cases). Both predicates
        -- (dst has expected item AND cursor empty) trivially pass when dst
        -- already held same-item at max-stack capacity (a no-op merge);
        -- the additional src-drained predicate is what distinguishes a real
        -- success from a phantom one. When it fails, fall through to the
        -- timeout-poll path which will classify as [other] failure and
        -- replan rather than advance past a no-op.
        if slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count) and
           not (_G.CursorHasItem and _G.CursorHasItem()) then
            local w = state.waiting
            if srcDrainedAsExpected(w) then
                state.done = state.done + 1
                state.consecutiveRefusedByItem = {}  -- v0.32.8 B1
                cancelPollTimers(w)                   -- v0.32.8 B2
                state.waiting = nil
                state.opIndex = myOpIndex + 1
                state.gapUntil = GetTime() + INTER_MOVE_GAP
                auditOpSuccess(w, "[sync]")
                emitProgress("complete", { completedOpIndex = myOpIndex })
                C_Timer.After(INTER_MOVE_GAP, function()
                    if isRunning() then step() end
                end)
                return
            else
                auditOpNoop(w, "sync")
                -- Fall through: interim-poll cascade + timeout-poll
                -- path will catch this as a real failure and trigger replan.
            end
        end
    end

    -- Cursor stuck after placement? Clear and fail this op, advance.
    if _G.CursorHasItem and _G.CursorHasItem() then
        ClearCursor()
        cancelPollTimers(state.waiting)             -- v0.32.8 B2
        state.failed = state.failed + 1
        state.cursorStuck = state.cursorStuck + 1
        state.waiting = nil
        GBL:SortWarn(
            string.format("Sort: op %d failed (cursor stuck after placement)", myOpIndex))
        state.opIndex = myOpIndex + 1
        state.gapUntil = GetTime() + INTER_MOVE_GAP
        emitProgress("failed", { failedOpIndex = myOpIndex, reason = "cursor-stuck" })
        C_Timer.After(INTER_MOVE_GAP, function()
            if isRunning() then step() end
        end)
        return
    end

    -- v0.32.8 B2: interim polling cascade. The sync post-Pickup check above
    -- runs synchronously after the Pickup pair; in retail the server hasn't
    -- yet processed the move so the predicates almost always fail there.
    -- Without this cascade, the next chance to advance is the 4.0 s
    -- MOVE_CONFIRM_TIMEOUT — that's wall-clock waste of ~3.5 s per op when
    -- the server actually processed in well under a second. Schedule polls
    -- at 0.25/0.5/1.0/2.0 s; first to pass advances via [interim-poll].
    -- The late-poll at 4.0 s remains as backstop.
    --
    -- State-alive guard: in synchronous-mock environments the async-event
    -- handler invoked by PickupGuildBankItem can advance, then call step()
    -- recursively, which can reach the "all done" branch and finish() the
    -- sort (clearing state). When control returns to the outer step() here,
    -- state is nil and we must NOT schedule interim polls.
    if not state or not state.waiting or state.waiting.opIndex ~= myOpIndex then
        -- The op already advanced (sync or async path) before we got here;
        -- nothing to poll for.
        return
    end
    do
        local waiter = state.waiting
        for _, offset in ipairs(INTERIM_POLL_OFFSETS) do
            local t = C_Timer.After(offset, function()
                -- State-first guard: pre-warm cancel / bank close can tear
                -- down state from under us. Then verify this poll is still
                -- attached to the same in-flight op (replan or advance
                -- would have changed state.opIndex or state.waiting).
                if not state or state.opIndex ~= myOpIndex
                   or not state.waiting or state.waiting.opIndex ~= myOpIndex then
                    return
                end
                local w = state.waiting
                if slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count) and
                   not (_G.CursorHasItem and _G.CursorHasItem()) and
                   srcDrainedAsExpected(w) then
                    state.done = state.done + 1
                    state.consecutiveRefusedByItem = {}
                    cancelPollTimers(w)
                    state.waiting = nil
                    state.opIndex = myOpIndex + 1
                    -- Slightly longer cushion than INTER_MOVE_GAP: the
                    -- server had less real time to confirm than a late-poll
                    -- path would have given it.
                    state.gapUntil = GetTime() + INTER_MOVE_GAP_AFTER_INTERIM
                    auditOpSuccess(w, "[interim-poll]")
                    emitProgress("complete", { completedOpIndex = myOpIndex })
                    C_Timer.After(INTER_MOVE_GAP_AFTER_INTERIM, function()
                        if isRunning() then step() end
                    end)
                end
                -- Predicates failed: poll silently rejected; next poll or
                -- the late-poll backstop will resolve.
            end)
            if waiter and waiter.pollTimers then
                table.insert(waiter.pollTimers, t)
            end
        end
    end

    -- Safety timeout: verify-by-polling if no event resolves us in time.
    C_Timer.After(MOVE_CONFIRM_TIMEOUT, function()
        if not state or not state.waiting or state.waiting.opIndex ~= myOpIndex then
            return  -- already advanced
        end
        -- The dst-has-expected-item check is necessary but not sufficient:
        -- when dst already held same-item at max-stack capacity, a no-op
        -- looks identical to a success. The src-drained predicate
        -- distinguishes real completion from a phantom.
        local completedAtTimeout =
            slotHasAtLeast(op.dstTab, op.dstSlot, op.itemID, op.count)
            and srcDrainedAsExpected(state.waiting)
        if completedAtTimeout then
            state.done = state.done + 1
            state.lastTimedOutOp = nil
            auditOpSuccess(state.waiting, "[late-poll]")
            -- v0.32.8 B1: any forward progress resets the per-item
            -- consecutive-refusal counter so a recovered op doesn't
            -- inherit pre-recovery strikes.
            state.consecutiveRefusedByItem = {}
        else
            state.failed = state.failed + 1
            -- Record the timeout so a late GUILDBANKBAGSLOTS_CHANGED arriving
            -- within LATE_ACK_GRACE can reclassify this as a success rather
            -- than triggering a foreign-activity replan.
            state.lastTimedOutOp = {
                opIndex = myOpIndex,
                srcTab = op.srcTab, srcSlot = op.srcSlot,
                dstTab = op.dstTab, dstSlot = op.dstSlot,
                itemID = op.itemID, count = op.count,
                opLabel = op.op or "move",
                srcPreOp = state.waiting and state.waiting.srcPreOp,
                at = GetTime(),
            }
            -- Dump live state so the audit trail reveals WHY the timeout
            -- fired — did the move never happen, partially happen (pickup
            -- done, drop failed), or fully happen with a silent ACK?
            local srcDesc = describeSlot(op.srcTab, op.srcSlot)
            local dstDesc = describeSlot(op.dstTab, op.dstSlot)
            local cursorHas = _G.CursorHasItem and _G.CursorHasItem() or false
            -- Classify from structured live-slot state, not the display
            -- strings above: describeSlot carries the resolved item name
            -- in-game, which would defeat the classifier's item match.
            local class = classifyTimeoutState(
                op,
                snapshotLiveSlot(op.srcTab, op.srcSlot),
                snapshotLiveSlot(op.dstTab, op.dstSlot),
                cursorHas,
                state.waiting and state.waiting.dstPreOp)
            if state.timeoutByClass[class] then
                state.timeoutByClass[class] = state.timeoutByClass[class] + 1
            else
                state.timeoutByClass.other = state.timeoutByClass.other + 1
            end
            GBL:SortWarn(string.format(
                "Sort: op %d timed out (no confirm within %ds) [%s]",
                myOpIndex, MOVE_CONFIRM_TIMEOUT, class))
            GBL:SortWarn(string.format(
                "  op %d was: %s T%d/S%d -> T%d/S%d %s x%d",
                myOpIndex, op.op or "move",
                op.srcTab, op.srcSlot, op.dstTab, op.dstSlot,
                GBL.DescribeItem and GBL:DescribeItem(op.itemID) or ("it:" .. op.itemID),
                op.count))
            GBL:SortWarn(string.format(
                "  observed: src %s, dst %s, cursor %s",
                srcDesc, dstDesc, cursorHas and "held" or "empty"))
            -- v0.32.8 Phase-1 instrument: a drain-pending timeout means THIS
            -- op's deposit landed (dst filled from empty/other) but the source
            -- decrement hasn't surfaced in the client by the 4s window. It is
            -- in-flight progress, not a server refusal, so it does NOT feed the
            -- 3-strike abort and the sort runs to completion. Capturing this
            -- confirms the split actually succeeds before we switch the
            -- confirmation rule to recognize the deposit directly.
            if class == "drain-pending" then
                GBL:SortWarn(string.format(
                    "  -> deposit landed (dst was empty/other pre-op); "
                    .. "source-drain pending past %ds, treated as in-flight",
                    MOVE_CONFIRM_TIMEOUT))
            end
            -- v0.32.8 B3: emit the planner-projected secondary line ONLY
            -- when it diverges from the live observed values. Planner
            -- state mutates at emit time without a rollback path, so on
            -- a chain of failed ops the planner's projection drifts from
            -- live by one or more for every later op. Suppressing the
            -- redundant "planner expected: x = observed: x" line keeps
            -- the audit signal-to-noise high. When divergent, increment
            -- state.projectionDrifts so finish() can report cumulative
            -- drift count.
            local plannerSrcStr = describePlannerSlot(op.plannerSrcAt)
            local plannerDstStr = describePlannerSlot(op.plannerDstAt)
            if plannerSrcStr ~= srcDesc or plannerDstStr ~= dstDesc then
                GBL:SortWarn(string.format(
                    "  (planner projected: src %s, dst %s)",
                    plannerSrcStr, plannerDstStr))
                state.projectionDrifts = (state.projectionDrifts or 0) + 1
            end

            -- v0.32.8 B1: consecutive-refusal abort. Track per-item count
            -- of server-rejected / merge-noop timeouts; abort with a
            -- specific reason on 3 strikes rather than fall through to
            -- step() and compound into a singleton-chain failure.
            local refused = (class == "server-rejected" or class == "merge-noop")
            if refused then
                local n = (state.consecutiveRefusedByItem[op.itemID] or 0) + 1
                state.consecutiveRefusedByItem[op.itemID] = n
                if n >= 3 then
                    finish(false, string.format(
                        "repeated server refusal on item %d (%d consecutive %s)",
                        op.itemID, n, class))
                    return
                end
            else
                state.consecutiveRefusedByItem = {}
            end
        end
        -- v0.32.8 B2: any interim-poll timers will have already fired by
        -- the time we reach the 4.0s late-poll, so this cancel is mostly
        -- defensive; it keeps the cleanup path uniform with the other
        -- advance/abort sites.
        cancelPollTimers(state.waiting)
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

    -- Pre-warm phase: events are registered before pre-warm starts (so the
    -- frame-hide abort works during the window), but we issue no moves yet.
    -- Ignore foreign bank activity here: replanning/stepping now would issue
    -- the first move on a cold item cache, re-opening the crafted-quality
    -- crash pre-warm exists to prevent. The first step()'s src/dst pre-check
    -- catches any divergence once pre-warm completes.
    if state.preWarming then return end

    -- First, check if this event is the late ACK for a recently-timed-out
    -- op. The server may have processed the move after we'd already armed
    -- the next op's waiting state, so this check must run independent of
    -- whether state.waiting is currently populated. Without this, the
    -- reclassification only fires when no in-flight op exists, which is
    -- almost never true during a live sort (the gap between ops is 0.3s).
    local reclassified = false
    local lto = state.lastTimedOutOp
    if lto and (GetTime() - lto.at) <= LATE_ACK_GRACE and
       slotHasAtLeast(lto.dstTab, lto.dstSlot, lto.itemID, lto.count) and
       srcDrainedAsExpected(lto) then
        state.done = state.done + 1
        state.failed = state.failed - 1
        state.reclassified = state.reclassified + 1
        state.consecutiveRefusedByItem = {}  -- v0.32.8 B1
        GBL:SortInfo(string.format(
            "Sort: op %d confirmed by late event after timeout - reclassified as success",
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
        -- Cursor-empty gate: the pickup half of a Pickup pair fires its
        -- own GUILDBANKBAGSLOTS_CHANGED before the drop. At that moment
        -- src is empty (just emptied) AND cursor is held. Without this
        -- guard, srcDrainedAsExpected vacuously passes (src empty for a
        -- "move"), the executor advances mid-operation, and the still-
        -- pending drop runs against a torn-down state. Only advance once
        -- the drop has resolved (cursor empty).
        local cursorHeld = _G.CursorHasItem and _G.CursorHasItem()
        if slotHasAtLeast(w.tabIndex, w.slotIndex, w.itemID, w.count)
           and not cursorHeld then
            -- Same caveat as the [sync] path: dst-has-item passes trivially
            -- when dst already held same-item at max-stack capacity. The
            -- src-drained predicate is what distinguishes real ACK from
            -- the optimistic-but-rejected client update.
            if srcDrainedAsExpected(w) then
                state.done = state.done + 1
                state.consecutiveRefusedByItem = {}  -- v0.32.8 B1
                cancelPollTimers(w)                   -- v0.32.8 B2
                state.waiting = nil
                state.lastTimedOutOp = nil
                state.opIndex = state.opIndex + 1
                state.gapUntil = GetTime() + INTER_MOVE_GAP
                auditOpSuccess(w)
                emitProgress("complete", { completedOpIndex = w.opIndex })
                step()
            else
                auditOpNoop(w, "async")
                -- Don't advance; let MOVE_CONFIRM_TIMEOUT resolve this as
                -- a real failure. state.waiting stays armed.
            end
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
        -- Server-reversion detection: if the most recently advanced op's
        -- src/dst slots no longer match the projected post-op state, the
        -- server very likely rejected our previous Pickup pair and this
        -- event is the rollback. The WoW client always optimistically
        -- updates on Pickup so the [sync] / async success paths can't
        -- tell apart "server processed" from "server will reject" — but
        -- THIS event (the second one) carries the authoritative answer.
        local lco = state.lastCompletedOp
        if lco then
            local liveSrc = snapshotLiveSlot(lco.srcTab, lco.srcSlot)
            local liveDst = snapshotLiveSlot(lco.dstTab, lco.dstSlot)
            local srcReverted = not slotEquals(liveSrc, lco.projectedSrc)
            local dstReverted = not slotEquals(liveDst, lco.projectedDst)
            if srcReverted or dstReverted then
                GBL:SortWarn(string.format(
                    "Sort: server reversion suspected on op %d (%s T%d/S%d->T%d/S%d)",
                    lco.opIndex, lco.opLabel or "move",
                    lco.srcTab, lco.srcSlot, lco.dstTab, lco.dstSlot))
                if srcReverted then
                    GBL:SortWarn(string.format(
                        "  src T%d/S%d: projected %s, observed %s",
                        lco.srcTab, lco.srcSlot,
                        describePlannerSlot(lco.projectedSrc),
                        describePlannerSlot(liveSrc)))
                end
                if dstReverted then
                    GBL:SortWarn(string.format(
                        "  dst T%d/S%d: projected %s, observed %s",
                        lco.dstTab, lco.dstSlot,
                        describePlannerSlot(lco.projectedDst),
                        describePlannerSlot(liveDst)))
                end
            end
        end
        doReplan("foreign activity (unexpected event)")
    end
end

-- Called by Core:OnBankClosed (the single owner of the frame-hide event) so a
-- running sort aborts on any bank close. Not an AceEvent handler: a second
-- RegisterEvent on the shared GBL object would overwrite Core's handler, not
-- stack. Core's handler already gates on the GuildBanker interaction type.
function GBL:_SortExecutorOnBankClosed()
    if not state then return end
    finish(false, "bank closed")
end

------------------------------------------------------------------------
-- Pre-warm (Item:CreateFromItemLink for crafted-quality crash mitigation)
------------------------------------------------------------------------

-- Atlas marker present in the link of every TWW crafted-quality reagent
-- (e.g. Flawless Quick Amethyst). A 2026-05-20 in-game crash bottomed out
-- in Blizzard's GetItemReagentQualityInfo when GUILDBANKBAGSLOTS_CHANGED
-- triggered a tab redraw after PickupGuildBankItem; the resident reagent
-- in any slot with this marker can crash the redraw if Blizzard's quality
-- cache is cold. Pre-warm is best-effort mitigation; the warning banner
-- on the Sort tab is the load-bearing user protection.
local CRAFTED_QUALITY_ATLAS = "Professions-ChatIcon-Quality-"

local PREWARM_CAP_SECONDS = 3.0

--- True if any op in the plan touches a slot whose LIVE item link
--- contains the TWW crafted-quality atlas marker. Requires the bank
--- to be open (GetGuildBankItemLink returns nil otherwise). Used by
--- the Sort tab preview to render a warning banner.
local function planHasCraftedQualityItems(plan)
    if not plan or not plan.ops then return false end
    for _, op in ipairs(plan.ops) do
        local link = GetGuildBankItemLink(op.srcTab, op.srcSlot)
        if link and link:find(CRAFTED_QUALITY_ATLAS, 1, true) then
            return true
        end
    end
    return false
end

GBL._sortExecutor_PlanHasCraftedQualityItems = planHasCraftedQualityItems

--- Pre-warm Blizzard's item-data cache for every unique item link in
--- the plan, then invoke `onReady(reason)`. Best-effort mitigation for
--- the crafted-quality-reagent crash. `Item:CreateFromItemLink` with
--- `ContinueOnItemLoad` is Blizzard's canonical "make sure this link
--- is fully resolved including bonus IDs" primitive; we wait for all
--- callbacks to fire OR a 3.0s cap, whichever lands first.
---
--- onReady is invoked exactly once. Cancel and bank-close DURING
--- pre-warm are not detected here — the post-resolve continuation in
--- ExecuteSortPlan re-checks state and IsBankOpen() before calling
--- step(), so a stale resolve after cancellation is harmless.
local function preWarmForPlan(plan, onReady)
    local seen = {}
    local links = {}
    for _, op in ipairs(plan.ops or {}) do
        local link = GetGuildBankItemLink(op.srcTab, op.srcSlot)
        if link and not seen[link] then
            seen[link] = true
            links[#links + 1] = link
        end
    end

    local total = #links
    local loaded = 0
    local startedAt = GetTime()
    local resolved = false

    local function resolve(reason)
        if resolved then return end
        resolved = true
        local elapsed = (GetTime() or 0) - (startedAt or 0)
        GBL:SortInfo(string.format(
            "Sort pre-warm: %d items, %d loaded in %.1fs (%s)",
            total, loaded, elapsed, reason))
        onReady(reason)
    end

    if total == 0 then
        resolve("no-items")
        return
    end

    local function noteLoaded()
        if resolved then return end
        loaded = loaded + 1
        if loaded >= total then
            resolve("complete")
        end
    end

    for _, link in ipairs(links) do
        local item = (_G.Item and _G.Item.CreateFromItemLink)
            and _G.Item:CreateFromItemLink(link) or nil
        if item and item.ContinueOnItemLoad then
            item:ContinueOnItemLoad(noteLoaded)
        else
            -- Item mixin unavailable (very old client or missing global).
            -- Treat as already-loaded so we don't hang on the cap.
            noteLoaded()
        end
    end

    -- Hard cap. Without this, a hung Blizzard callback would freeze the
    -- sort entirely. Pre-warm is best-effort — if it didn't finish in
    -- time, audit "cap" and let the executor proceed regardless.
    C_Timer.After(PREWARM_CAP_SECONDS, function()
        if not resolved then resolve("cap") end
    end)
end

GBL._sortExecutorPreWarmCapSeconds = PREWARM_CAP_SECONDS

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Begin executing a plan.
-- @param plan table from SortPlanner
-- @param onComplete function(result) called when the run ends
-- @param opts table|nil { layout = layoutForReplan, skipPreWarm = bool }
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
        timeoutByClass = {
            ["server-rejected"] = 0,
            partial = 0,
            complete = 0,
            ["merge-noop"] = 0,
            ["drain-pending"] = 0,
            other = 0,
        },
        -- Per-item consecutive refusal counter (v0.32.8 B1). Increments on
        -- every server-rejected / merge-noop timeout for the same itemID.
        -- Resets on any other class or any success. On count >= 3 the
        -- executor aborts via finish(false, ...). Without this, the
        -- singleton-chain pattern compounds into chain failure rather
        -- than failing fast.
        consecutiveRefusedByItem = {},
        -- v0.32.8 B3: count of timeouts where the planner's emit-time
        -- projection of src/dst diverged from the live observed values.
        -- Surfaced in the finish() summary. Non-zero means the planner's
        -- in-memory state has drifted from server reality during this
        -- run; expected when the executor took the timeout path for any
        -- ops since the planner doesn't rollback its working state on
        -- a no-op.
        projectionDrifts = 0,
    }
    registerBankEvents()
    GBL:SortInfo(
        string.format("Sort: starting execution of %d ops", #plan.ops))
    emitProgress("start")

    -- Pre-warm phase: best-effort load of every unique item link in the
    -- plan before issuing the first PickupGuildBankItem, mitigating the
    -- TWW crafted-quality crash that bottomed out in Blizzard's
    -- GetItemReagentQualityInfo. Skip when there are no ops or when the
    -- caller (test path) opts out.
    if (opts and opts.skipPreWarm) or #plan.ops == 0 then
        step()
        return true, nil
    end

    -- Suppress the slots-changed handler for the duration of pre-warm. No
    -- async event can interleave between registerBankEvents() above and this
    -- assignment (synchronous Lua), so there is no gap to leak through.
    state.preWarming = true
    preWarmForPlan(plan, function(_reason)
        -- State already torn down by an external Cancel or by the
        -- PLAYER_INTERACTION_MANAGER_FRAME_HIDE event handler. finish()
        -- has run, onComplete already fired — nothing to do.
        if not state then return end
        -- Pre-warm done: re-enable normal slots-changed handling before the
        -- first step() arms an in-flight op.
        state.preWarming = nil
        if not GBL:IsBankOpen() then
            finish(false, "bank closed during prewarm")
            return
        end
        step()
    end)
    return true, nil
end

--- Cancel a running sort.
function GBL:CancelSortExecution()
    if not state then return end
    GBL:SortInfo(
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

-- Test hook: drive the internal step() directly. Used to verify the
-- in-flight guard refuses to issue a second op while one is already armed.
function GBL:_sortExecutorStep()
    return step()
end

-- Test hook: inspect the per-item refusal counter. Returns the count for
-- a given itemID (0 if absent). Used by tests that need to assert the
-- counter state mid-sort without driving through finish().
function GBL:_sortExecutorGetRefusalCount(itemID)
    if not state or not state.consecutiveRefusedByItem then return 0 end
    return state.consecutiveRefusedByItem[itemID] or 0
end

-- Test hook: synthetically set the per-item refusal counter. Used to
-- verify reset paths (replan, success) without forcing the executor
-- through three real refusals first.
function GBL:_sortExecutorSetRefusalCount(itemID, count)
    if not state then return end
    state.consecutiveRefusedByItem[itemID] = count
end

-- Test hook: expose the pure classifier so unit tests can exercise each
-- branch (server-rejected / partial / complete / merge-noop / drain-pending /
-- other) without simulating a full server-rejection scenario in the mock bank.
-- srcLive / dstLive / dstPreLive are {itemID, count} snapshots (or nil for empty).
function GBL:_sortExecutorClassifyTimeoutState(op, srcLive, dstLive, cursorHasItem, dstPreLive)
    return classifyTimeoutState(op, srcLive, dstLive, cursorHasItem, dstPreLive)
end
