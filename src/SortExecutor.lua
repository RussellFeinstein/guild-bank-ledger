------------------------------------------------------------------------
-- GuildBankLedger — SortExecutor.lua
-- Consumes a plan from SortPlanner and executes it fire-and-forget: it
-- issues one move per CADENCE on a self-rescheduling timer without waiting
-- for each deposit to confirm, then at end-of-pass re-scans, re-plans, and
-- runs another pass until the bank matches the layout (auto-rerun) or no
-- further progress is possible.
--
-- Why fire-and-forget: confirming each op waits on the server deposit
-- (1.8-3.3s/op measured), which cannot be beaten by any confirmation
-- strategy. The reference addon Guild Bank Sort fires one move per second
-- with no confirmation and reruns for residuals; that model is ~3x faster.
-- Correctness comes from convergence (re-scan + re-plan), not per-op proof.
--
-- Public API:
--   GBL:ExecuteSortPlan(plan, onComplete, opts)
--     Starts executing `plan`. `onComplete(result)` fires when the run ends
--     (success, abort, or cap). `result` = { ok, reason, done, failed,
--      total, replans, passes }.  `opts` = { layout = layoutForReplan }.
--      `layout` is required for auto-rerun.
--   GBL:CancelSortExecution()
--   GBL:IsSortRunning() -> boolean
--
-- Invariants:
--   * Never leave an item on the cursor across ticks: each tick clears a
--     stuck cursor before and after issuing.
--   * Never exceed MAX_PASSES passes per run.
--   * Abort on bank close: Core's OnBankClosed calls
--     GBL:_SortExecutorOnBankClosed (the executor does not register the
--     frame-hide event, which would shadow Core's handler); IsBankOpen() is
--     also checked at each tick as a backstop.
--   * The pump issues no slots-changed-driven confirmation, so the executor
--     registers no bank events; the end-of-pass scan reads server truth.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local CADENCE           = 1.0   -- seconds between issued moves (fire-and-forget)
local SETTLE_DELAY      = 3.5   -- wait after the last move before the end-of-pass scan
                                -- (above the worst observed ~3.3s deposit latency)
local MAX_PASSES        = 5     -- auto-rerun cap per run
-- Flush the transaction log every N issued ops while the periodic rescan is
-- paused. Each tab's transaction log holds about 25 entries before older ones
-- evict, so N is set well below that with margin for the asymmetric case where
-- every op deposits to the same tab. Count-based (not time-based) so a future
-- cadence tuning stays safe automatically.
local TRANSACTION_LOG_FLUSH_OPS = 15
local SCAN_WAIT_TIMEOUT = 10.0  -- seconds to wait for an end-of-pass scan to finish
-- Stall watchdog: re-kick the pump if it has made no progress for longer than
-- one cadence plus this slack with no tick having fired (a lost frame-driven
-- timer / client freeze, the same mechanism as the historical op-88 hang).
local STALL_SLACK = 5.0

-- The source-lift guard (see issueOp) reads GetCursorInfo. That predicate is
-- verified against one client on one patch, and the guard's failure mode is
-- total: v0.39.5 gated the same action on CursorHasItem and refused every
-- op it attempted, across two runs of a 207-op plan that issued nothing at
-- all, in a build already on CurseForge. So the guard carries a
-- fuse. This many refusals in a run where it has never once passed reads as a
-- broken predicate rather than a bank full of failed lifts, and it disables
-- itself for the rest of the run. Exported for the spec.
local LIFT_GUARD_FUSE = 5
GBL.SORT_LIFT_GUARD_FUSE = LIFT_GUARD_FUSE

-- A frame longer than HITCH_THRESHOLD is a "hitch" (client stutter / load
-- pause). A sampler OnUpdate frame records these during a sort so a capture
-- shows whether the pump kept the render loop responsive; a freeze surfaces as
-- one giant elapsed.
local HITCH_THRESHOLD  = 0.1   -- seconds
local HITCH_BUCKETS_MS = { 150, 250, 500, 1000 }  -- last bucket is ">1000ms"

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- A one-line snapshot of network latency from GetNetStats (home + world ms
--- ping). Logged at sort start and finish so a post-mortem can separate a
--- laggy session from our cadence.
--- Is something on the cursor? Returns nil when the client cannot say, which
--- is not the same answer as "no" and must never be read as one: an
--- unreadable cursor is not evidence that a lift failed.
---
--- GetCursorInfo rather than CursorHasItem, on measurement. The 2026-09-17
--- capture ran 238 bank lifts that all demonstrably succeeded (the bank
--- converged and the replan came back empty) and read
--- `GetCursorInfo [item:238], CursorHasItem true=0 false=238`, so
--- CursorHasItem is blind to a guild bank cursor and GetCursorInfo is not.
--- 162 of those lifts sourced the tab that was selected at the time, so this
--- is not a view-gating artifact (#171).
local function cursorLoaded()
    if not _G.GetCursorInfo then return nil end
    return _G.GetCursorInfo() ~= nil
end

local function netPingStr()
    if not _G.GetNetStats then return "ping ?" end
    local _, _, lagHome, lagWorld = _G.GetNetStats()
    return string.format("ping home %dms / world %dms", lagHome or -1, lagWorld or -1)
end

--- The currently-viewed guild bank tab, or nil when the client cannot say.
--- Pure read. A read of any other tab's slots answers as of that tab's last
--- query, which is what liftFromBank's ledger check is about (#191).
local function viewedTab()
    return _G.GetCurrentGuildBankTab and _G.GetCurrentGuildBankTab() or nil
end

--- The viewed tab as the per-op line stamps it.
local function viewedTabStr()
    local v = viewedTab()
    return v and ("T" .. tostring(v)) or "T?"
end

--- Key for the per-pass ledger of slots this run has written (#191).
local function slotKey(tabIndex, slotIndex)
    return tostring(tabIndex) .. "/" .. tostring(slotIndex)
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local state = nil
-- A single reused frame for the per-frame hitch sampler (OnUpdate attached per
-- sort, detached in finish) and the stall-watchdog ticker handle.
local hitchFrame = nil
local stallTicker = nil
-- Shape when running:
-- {
--   plan = current pass plan,    -- swapped each pass; emitProgress total/op
--   firstPassOps = N,            -- original op count, for the result summary
--   layout = {...},              -- required for end-of-pass re-plan
--   opIndex = N,                 -- next op to issue in the current pass
--   passes = P, lastPassOps = N, residual = R,
--   totalIssued = N, cursorStuck = N, skippedOps = N,
--   staleSourceLifts = N,        -- bank lifts taken on the plan's word (#191)
--   wroteThisPass = { ["T/S"] = true },  -- slots this pass has written; reset
--                                        -- by startPass, read by liftFromBank
--   lastOutcome* = the previous op's result, riding forward onto the next
--                  step message and cleared by startPass (#162),
--   pumping = bool,              -- true while a pass is issuing; the cancel
--   pumpToken = N,               -- invalidates a stale/late pump timer
--   onComplete = fn, startedAt = t, lastProgressAt = t,
--   hitch*/stallCount = instrumentation,
-- }

local function isRunning()
    return state ~= nil
end

function GBL:IsSortRunning()
    return isRunning()
end

-- Forward declarations so mutual references resolve at load time.
local finish
local pumpOne
local endOfPass

--- Mark forward progress (an op was issued). The stall watchdog measures
--- wall-clock time since this; a wedged pump shows up as a large gap.
local function noteProgress()
    if state then state.lastProgressAt = GetTime() end
end

--- Pure frame-hitch recorder. A frame whose elapsed exceeds HITCH_THRESHOLD is
--- a hitch; tally count / max / bucket on `st`. Exposed for unit tests because
--- the mock does not drive OnUpdate. Returns true iff a hitch was recorded.
local function recordHitch(st, elapsedSeconds)
    if not st then return false end
    if (elapsedSeconds or 0) <= HITCH_THRESHOLD then return false end
    local ms = elapsedSeconds * 1000
    st.hitchCount = (st.hitchCount or 0) + 1
    if ms > (st.hitchMaxMs or 0) then st.hitchMaxMs = ms end
    local label = ">1000ms"
    for _, ub in ipairs(HITCH_BUCKETS_MS) do
        if ms <= ub then label = "<=" .. ub .. "ms" break end
    end
    st.hitchByBucket = st.hitchByBucket or {}
    st.hitchByBucket[label] = (st.hitchByBucket[label] or 0) + 1
    return true
end
GBL._sortExecutorRecordHitch = recordHitch

--- Attach the hitch sampler's OnUpdate for the current sort, on a single reused
--- frame. Skips the first sample (the engine's first post-SetScript elapsed is
--- unreliable and would log a spurious startup hitch).
local function startHitchSampler()
    if not hitchFrame and _G.CreateFrame then
        hitchFrame = _G.CreateFrame("Frame")
    end
    if not hitchFrame then return end
    if state then state.hitchPrimed = false end
    hitchFrame:SetScript("OnUpdate", function(_, elapsed)
        if not state then return end
        if not state.hitchPrimed then state.hitchPrimed = true return end
        recordHitch(state, elapsed)
    end)
    if hitchFrame.Show then hitchFrame:Show() end
end

local function stopHitchSampler()
    if not hitchFrame then return end
    hitchFrame:SetScript("OnUpdate", nil)
    if hitchFrame.Hide then hitchFrame:Hide() end
end

--- Stall watchdog + self-heal. The pump self-reschedules with C_Timer.After,
--- which only fires on a rendered frame; if that timer is lost (a client freeze
--- / backgrounded loop, the historical op-88 hang), the pump goes silent. This
--- fires only when pumping AND no tick has run for longer than one cadence plus
--- slack, then re-kicks the pump (bumping pumpToken so a late original timer
--- no-ops rather than double-issuing). Frame-loop-driven, so on a full freeze it
--- cannot fire until the loop resumes, but then it recovers the run.
local function checkStall()
    if not state then return end
    if not GBL:IsBankOpen() then return end
    if not state.pumping then return end  -- between passes the scan-wait timeout guards
    local now = GetTime()
    if now - (state.lastProgressAt or now) <= (CADENCE + STALL_SLACK) then return end
    state.stallCount = (state.stallCount or 0) + 1
    GBL:SortWarn(string.format(
        "Sort STALLED: %.0fs since last move (op %d/%d, viewed %s) - re-kicking pump",
        now - (state.lastProgressAt or now),
        state.opIndex or 0, #state.plan.ops, viewedTabStr()))
    state.pumpToken = (state.pumpToken or 0) + 1  -- invalidate any late timer
    pumpOne()
end

local function startStallWatchdog()
    if stallTicker and stallTicker.Cancel then stallTicker:Cancel() end
    stallTicker = nil
    if _G.C_Timer and _G.C_Timer.NewTicker then
        stallTicker = _G.C_Timer.NewTicker(5, function()
            if not state then
                if stallTicker and stallTicker.Cancel then stallTicker:Cancel() end
                stallTicker = nil
                return
            end
            checkStall()
        end)
    end
end

local function stopStallWatchdog()
    if stallTicker and stallTicker.Cancel then stallTicker:Cancel() end
    stallTicker = nil
end

--- Called by Ledger's RescanTransactionLogs whenever a rescan actually starts
--- while a sort runs. That covers the executor's own transaction-log flush and
--- any rescan begun from outside, and this is the only place either is counted.
---
--- Counting here rather than at the flush call site is the whole point (#165).
--- RescanTransactionLogs returns early on a closed bank and on missing guild
--- data BEFORE it reaches this call, so a counter at the call site records an
--- intent rather than an outcome, which is #90's reply=sent under another name.
---
--- The executor stops Ledger's ticker for the run, so an external rescan is an
--- anomaly rather than routine: the reachable path is the Auto re-scan checkbox
--- (UI/UI.lua) ticked mid-sort on a run that began with the rescan already off,
--- which is the one case the stop never covers because there was nothing to
--- stop. It is named once and counted after that. The old code logged the first
--- 40 under a name that claimed they competed with the pump, and every one of
--- them was the sort's own flush.
function GBL:_sortNoteRescanTick()
    if not state then return end
    if state.inOwnFlush then
        state.flushes = (state.flushes or 0) + 1
        return
    end
    state.externalRescans = (state.externalRescans or 0) + 1
    if state.externalRescans == 1 then
        GBL:SortWarn(
            "Sort env: a periodic rescan fired during the sort (op %d/%d)",
            state.opIndex or 0, #state.plan.ops)
    end
end

--- Emit a progress message for UI subscribers (notably UI/SortView). SortView
--- rebuilds its move list on "planupdated" (payload.plan), highlights the
--- active row on "step" (payload.opIndex), and settles the row behind it from
--- the issuedOpIndex / failedOpIndex a "step" carries forward; its onComplete
--- reads the result table from finish, not this payload.
---
--- Every field here means what it says (#162). `issued` is not `done`: the
--- pump is fire-and-forget, so issuing an op is not proof it landed, and only
--- finish knows the residual-based done/failed, which it attaches itself.
--- `refused` counts ops issueOp declined; it used to read `cursorStuck`, which
--- counts destination pickups that SWAPPED rather than placed and is therefore
--- a successful move. That field is still here, under its own name.
local function emitProgress(phase, extras)
    if not state then return end
    local payload = {
        phase = phase,
        opIndex = state.opIndex,
        issued = state.totalIssued,
        refused = state.skippedOps or 0,
        cursorStuck = state.cursorStuck or 0,
        replans = math.max(0, (state.passes or 1) - 1),
        total = #state.plan.ops,
        currentOp = state.plan.ops[state.opIndex],
    }
    if extras then
        for k, v in pairs(extras) do payload[k] = v end
    end
    GBL:SendMessage("GBL_SORT_PROGRESS", payload)
end

------------------------------------------------------------------------
-- Finish
------------------------------------------------------------------------

function finish(ok, reason)
    if not state then return end

    -- Stall backstop: a freeze-then-bank-close can tear down state before any
    -- watchdog tick fires, so report a final no-progress gap here (GetTime is
    -- wall-clock, advances across a background).
    do
        local sinceProgress = state.lastProgressAt and (GetTime() - state.lastProgressAt) or 0
        if state.pumping and sinceProgress > (CADENCE + STALL_SLACK) then
            state.stallCount = (state.stallCount or 0) + 1
            GBL:SortWarn(string.format(
                "Sort: ended after %.0fs with no move (likely client freeze/stall; op %d/%d)",
                sinceProgress, state.opIndex or 0, #state.plan.ops))
        end
    end

    local total = state.firstPassOps or #state.plan.ops
    local residual = state.residual
    local done, failed
    if residual ~= nil then
        done = math.max(0, total - residual)
        failed = residual
    else
        -- Aborted mid-pump (bank close / cancel): best-effort.
        done = math.min(state.totalIssued or 0, total)
        failed = math.max(0, total - done)
    end
    local passes = state.passes or 1

    local cb = state.onComplete
    local result = {
        ok = ok,
        reason = reason,
        done = done,
        failed = failed,
        total = total,
        replans = math.max(0, passes - 1),
        passes = passes,
        cursorStuck = state.cursorStuck,
        flushes = state.flushes or 0,
        externalRescans = state.externalRescans or 0,
        hitchCount = state.hitchCount,
        hitchMaxMs = state.hitchMaxMs,
        hitchByBucket = state.hitchByBucket,
        stallCount = state.stallCount,
        syncActiveAtStart = state.syncActiveAtStart,
        bagOpsIssued = state.bagOpsIssued or 0,
        bagOpsSkipped = state.bagOpsSkipped or 0,
        bagSkipReasons = state.bagSkipReasons or {},
        skippedOps = state.skippedOps or 0,
        skipReasons = state.skipReasons or {},
        staleSourceLifts = state.staleSourceLifts or 0,
        liftProbe = state.liftProbe,
        liftGuardBlown = state.liftGuardBlown,
        -- nil rather than 0 when no replan ran: the caller has to be able to
        -- tell "the bags are empty" from "nothing measured them".
        bagsStillInBags = state.lastBagSupplies,
        bagsUnplaceable = state.lastBagStay,
    }

    local elapsed = (GetTime() and state.startedAt) and (GetTime() - state.startedAt) or 0
    local issued = state.totalIssued or 0
    local avg = issued > 0 and (elapsed / issued) or 0
    -- Refusals ride the run summary rather than a line of their own: a
    -- refused op is part of how the run went, unlike what is left in the
    -- player's bags. Absent at zero, because a term on every clean run is
    -- a term readers stop seeing.
    local refusedOps = state.skippedOps or 0
    local skipTerm, skipHist = "", ""
    if refusedOps > 0 then
        skipTerm = string.format(" skipped=%d", refusedOps)
        local parts = {}
        for tag, n in pairs(state.skipReasons or {}) do
            parts[#parts + 1] = string.format("%s:%d", tag, n)
        end
        -- Sorted so two captures of the same run read identically rather
        -- than in pairs order.
        table.sort(parts)
        skipHist = " [" .. table.concat(parts, " ") .. "]"
    end
    -- extrescans rides only when non-zero: under the stop-the-ticker design
    -- it is normally 0, and a term that is always 0 trains a reader to skip
    -- the one capture where it is not (#165).
    local extTerm = ""
    if (state.externalRescans or 0) > 0 then
        extTerm = string.format(" extrescans=%d", state.externalRescans)
    end
    -- Bank lifts taken on the plan's word because the read was the run's
    -- own write on a tab that was off screen (#191). Absent at zero like
    -- skipped=; present whenever a pivot sat on a tab that was not on
    -- screen, which is what the next capture reads it for.
    local staleTerm = ""
    if (state.staleSourceLifts or 0) > 0 then
        staleTerm = string.format(" stalesrc=%d", state.staleSourceLifts)
    end
    GBL:SortInfo(string.format(
        "Sort: %s in %.1fs - %d passes, %d ops issued, %d remaining, avg %.2fs/op"
        .. " (cursorStuck=%d stalls=%d flushes=%d%s%s%s)%s",
        ok and "complete" or ("aborted (" .. (reason or "?") .. ")"),
        elapsed, passes, issued, failed,
        avg, state.cursorStuck or 0, state.stallCount or 0, state.flushes or 0,
        staleTerm, extTerm, skipTerm, skipHist))

    -- Bag deposits get their own line rather than a rider on the summary
    -- above: what is still sitting in the user's bags is the thing they
    -- read this line to find out, and it is not answerable from the run's
    -- own counts (#139).
    --
    -- Written whenever bags were included, even at 0 and 0. A suppressed
    -- line reads exactly like a run with the toggle off, which is the one
    -- distinction a capture most needs here.
    if state.includeBags then
        local skipped = state.bagOpsSkipped or 0
        local parts = {}
        for tag, n in pairs(state.bagSkipReasons or {}) do
            parts[#parts + 1] = string.format("%s:%d", tag, n)
        end
        table.sort(parts)
        -- No replan means nothing ever looked at the bags after the pass, so
        -- there is no honest count to give. Printing 0 would say they are
        -- empty; this says nobody checked.
        local stillIn = "unknown (no replan)"
        if state.lastBagSupplies then
            stillIn = tostring(state.lastBagSupplies)
            if (state.lastBagStay or 0) > 0 then
                stillIn = stillIn .. string.format(" (%d unplaceable)", state.lastBagStay)
            end
        end
        GBL:SortInfo(string.format(
            "Sort bags: %d deposit(s) issued, %d skipped%s, still in bags: %s",
            state.bagOpsIssued or 0, skipped,
            (skipped > 0 and #parts > 0)
                and (" [" .. table.concat(parts, " ") .. "]") or "",
            stillIn))
    end

    -- What the two cursor predicates answered across the run's bank lifts.
    -- This is the tripwire for the guard above: a capture where GetCursorInfo
    -- has gone quiet looks exactly like a bank full of failed lifts until
    -- this line separates them. Sorted, so two captures of the same run read
    -- identically rather than in pairs order.
    if state.liftProbe then
        local pr = state.liftProbe
        local kinds = {}
        for kind, n in pairs(pr.types or {}) do
            kinds[#kinds + 1] = string.format("%s:%d", kind, n)
        end
        table.sort(kinds)
        GBL:SortInfo(string.format(
            "Sort lift probe: GetCursorInfo [%s], CursorHasItem true=%d false=%d%s",
            table.concat(kinds, " "), pr.hasItem or 0, pr.noItem or 0,
            state.liftGuardBlown and " guard=disabled" or ""))
    end

    -- Hitch histogram on its own line: validates the pump kept the loop awake.
    do
        local parts = {}
        for tag, n in pairs(state.hitchByBucket or {}) do
            parts[#parts + 1] = string.format("%s:%d", tag, n)
        end
        table.sort(parts)
        GBL:SortInfo(string.format("Sort hitch summary: %d hitches, max %dms%s",
            state.hitchCount or 0, math.floor(state.hitchMaxMs or 0),
            (#parts > 0) and (" [" .. table.concat(parts, " ") .. "]") or ""))
    end
    GBL:SortInfo("Sort: net at finish - " .. netPingStr())

    -- Emit the final progress message BEFORE clearing state so listeners get
    -- the completion summary. done/failed are the residual-based locals the
    -- result table uses, so the Sort tab's completion line and the chat print
    -- cannot report two different numbers under one word (#162). The stash
    -- rides out here too: the last op of the run has no following step to
    -- carry its outcome forward.
    emitProgress("finish", {
        ok = ok,
        reason = reason,
        done = done,
        failed = failed,
        issuedOpIndex = state.lastOutcomeIssued,
        failedOpIndex = state.lastOutcomeFailed,
        failedReason = state.lastOutcomeReason,
        failedDetail = state.lastOutcomeDetail,
    })
    ClearCursor()
    if state.pumpTimer and state.pumpTimer.Cancel then state.pumpTimer:Cancel() end
    stopHitchSampler()
    stopStallWatchdog()
    -- Restore the user's periodic rescan if we paused it at sort start. Ledger's
    -- StartPeriodicRescan self-guards on bankOpen / _initialScanComplete /
    -- rescanEnabled / already-active, so a bank-close exit safely no-ops here.
    --
    -- The line reports the outcome, not the attempt (#165). OnBankClosed clears
    -- bankOpen BEFORE aborting the sort, so on that path the restart no-ops and
    -- the old unconditional line claimed a resume that never happened. Reading
    -- IsPeriodicRescanActive covers all four of those guards without restating
    -- any of them, which is what keeps it from drifting when they change.
    -- Silence when it did not resume: the abort reason is already on the
    -- summary line above, so a second line explaining it is noise.
    if state.rescanWasActive and GBL.StartPeriodicRescan then
        GBL:StartPeriodicRescan()
        if GBL.IsPeriodicRescanActive and GBL:IsPeriodicRescanActive() then
            GBL:SortInfo("Sort: resumed the periodic rescan")
        end
    end
    state = nil
    if cb then
        local success, err = pcall(cb, result)
        if not success then
            GBL:Print("SortExecutor onComplete error: " .. tostring(err))
        end
    end
end

------------------------------------------------------------------------
-- Pump: issue moves fire-and-forget, one per cadence.
------------------------------------------------------------------------

--- Issue one planned op with no confirmation. The Split/Pickup-src + Pickup-dst
--- sequence is the WoW-API-mandated way to relocate a guild bank stack. Cursor
--- safety brackets the issue so a failed place never carries an item into the
--- next tick.
--- Lift the source half of an op onto the cursor from a player bag (#139).
--- Returns false when the slot is not what the plan expected, in which case
--- NOTHING has been picked up and the caller must not run the destination
--- half. That is the whole point of the guard: PickupGuildBankItem on an
--- empty cursor does not place, it picks the destination slot up, so falling
--- through after a refused source would harvest an innocent bank stack.
---
--- The plan is a snapshot in time and the player can move things while the
--- pump runs, so a mismatch here is ordinary, not an error. Convergence
--- handles it: the next pass re-scans and re-plans.
---
--- @return boolean lifted, string|nil reason, string|nil detail
---   These six are liftFromBag's own vocabulary; liftFromBank below shares
---   empty, short-stack and no-api and has no use for the other three. Each
---   calls for a
---   different response from whoever reads the capture: no-bag and no-api
---   mean the op could never have run on this client, locked and empty mean
---   the slot moved under the plan, item-mismatch and short-stack mean it
---   moved in a way worth naming precisely, so those two carry a detail.
local function liftFromBag(op)
    local bagID = GBL:BagIDFromTab(op.srcTab)
    if not bagID then return false, "no-bag" end
    if not (C_Container and C_Container.GetContainerItemInfo) then
        return false, "no-api"
    end

    local info = C_Container.GetContainerItemInfo(bagID, op.srcSlot)
    if type(info) ~= "table" then return false, "empty" end
    if info.isLocked then return false, "locked" end
    if info.itemID and op.itemID and info.itemID ~= op.itemID then
        -- The raw id form rather than DescribeItem: this names the item the
        -- plan did NOT ask for, so its name is exactly the one the item
        -- cache was never warmed for, and "it:999" beats an empty string.
        return false, "item-mismatch", "holds it:" .. tostring(info.itemID)
    end

    local have = info.stackCount or 0
    local want = op.count or 0
    -- A want of zero is a malformed op rather than a short stack, but it
    -- cannot reach here from the planner and the warning prints the wanted
    -- count anyway, so it shares the reason rather than widening the
    -- vocabulary with a value nothing can produce.
    if have < want or want <= 0 then
        return false, "short-stack", "have " .. tostring(have)
    end

    -- Take exactly what the op asked for. The plan is a snapshot, so a
    -- stack the player topped up between Preview and Execute holds more
    -- than the op wants, and bags are mutated far more often than a guild
    -- bank is. The destination was sized for op.count, so a whole-stack
    -- pickup would over-deposit; the split is decided from what the slot
    -- holds NOW rather than from op.op, which was decided at plan time.
    if have > want then
        -- No split API means no partial take. Refusing costs one skipped
        -- op that the next pass retries; falling through to the whole-stack
        -- pickup would deposit everything the player had, and the
        -- destination half of the op cannot tell the difference.
        if not C_Container.SplitContainerItem then return false, "no-api" end
        C_Container.SplitContainerItem(bagID, op.srcSlot, want)
    elseif C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bagID, op.srcSlot)
    else
        return false, "no-api"
    end
    return true
end

--- Lift a bank source the run itself wrote on a tab that is off screen, on
--- the plan's word rather than the read's (#191). See liftFromBank's header
--- for why the read cannot be trusted there. The label is the only thing
--- consulted: "split" takes `want` and anything else takes the stack whole,
--- which is opLabel's rule read back. The read is logged beside the plan so
--- the next capture can say what would have been refused.
---
--- @return boolean lifted, string|nil reason
local function liftPerPlan(op, have, want)
    state.staleSourceLifts = (state.staleSourceLifts or 0) + 1
    local label = (op.op == "split") and "split" or "move"
    -- INFO rather than WARN: this is the fix working, not a refusal. The
    -- read rides along so the next capture can compare it with what the run
    -- put there, which is the measurement #191 asks for.
    GBL:SortInfo(string.format(
        "Sort op %d/%d: stale source %s (written this pass, viewing %s)"
        .. " reads %d, lifting %d per plan as %s",
        state.opIndex or 0, #state.plan.ops,
        GBL:FormatSlotRef(op.srcTab, op.srcSlot), viewedTabStr(),
        have, want, label))
    if label == "split" then
        if not _G.SplitGuildBankItem then return false, "no-api" end
        SplitGuildBankItem(op.srcTab, op.srcSlot, want)
    else
        PickupGuildBankItem(op.srcTab, op.srcSlot)
    end
    return true
end

--- Lift a bank source slot. Shaped like liftFromBag above, and for the same
--- reasons: the split is decided from what the slot holds NOW rather than from
--- the plan-time `op.op`, and a slot that cannot satisfy the op is refused
--- rather than picked up whole, because the destination was sized for
--- `op.count` and the destination half cannot tell the difference (#169).
---
--- Deciding from the slot is what makes a mislabelled partial harmless here
--- (#161): Phase 3 can emit a partial take labelled "move", and this path
--- reads the label in exactly one case, liftPerPlan below.
---
--- These checks are reason quality rather than safety. The cursor guard in
--- issueOp is what makes a failed lift safe, and it covers the cases no
--- pre-check can see: a split the server refuses, a slot locked between the
--- read and the call, a read that was stale HIGH.
---
--- A read that is stale LOW is the case nothing covered, and it has one
--- producer (#191). A tab the client is not viewing answers a slot read as
--- of that tab's last query, so a slot this run wrote earlier in the pass,
--- on a tab that is off screen, reads whatever it held when that tab was
--- last queried or viewed. The 2026-09-19 capture refused eight ops in that
--- shape and none outside it, every one a pivot on the overflow tab with
--- another tab on screen, and a three-op pivot cycle lost its third op
--- every time. So a source in state.wroteThisPass whose tab is not the
--- viewed one is not judged by the count: liftPerPlan lets the plan's
--- label decide split or whole (the single-writer label #161 made, pinned
--- by applyPlan's assertion in spec/sortplanner_spec.lua), logs the read
--- beside it so a capture can say what would have been refused, and leaves
--- a lift that really fails to the guard. The ledger is per pass because
--- every pass after the first starts with a full scan that re-queries
--- every tab, and it is written past the guard, so a refused op flags
--- nothing.
---
--- @return boolean lifted, string|nil reason, string|nil detail
local function liftFromBank(op)
    if not _G.GetGuildBankItemInfo then return false, "no-api" end
    local _, have = _G.GetGuildBankItemInfo(op.srcTab, op.srcSlot)
    have = have or 0
    local want = op.count or 0

    -- The run's own write, off screen: the read is the last query's, so the
    -- plan decides and the read is only reported (#191). A want of zero
    -- stays with the checks below, which name it.
    local ledger = state and state.wroteThisPass
    if want > 0 and ledger and ledger[slotKey(op.srcTab, op.srcSlot)]
       and viewedTab() ~= op.srcTab then
        return liftPerPlan(op, have, want)
    end

    if have <= 0 then return false, "empty" end

    -- A want of zero is a malformed op rather than a short stack, but it
    -- cannot reach here from the planner and the warning prints the wanted
    -- count anyway, so it shares the reason rather than widening the
    -- vocabulary with a value nothing can produce.
    if have < want or want <= 0 then
        return false, "short-stack", "have " .. tostring(have)
    end

    if have > want then
        if not _G.SplitGuildBankItem then return false, "no-api" end
        SplitGuildBankItem(op.srcTab, op.srcSlot, want)
    else
        -- Exactly enough: take the stack whole. What a real client does with
        -- a split whose count equals the stack is not recorded anywhere here,
        -- and the whole pickup is the branch we know the shape of.
        PickupGuildBankItem(op.srcTab, op.srcSlot)
    end
    return true
end

--- Measure, and act on nothing. This started as the instrument that settled
--- the v0.39.5 outage and it stays as the tripwire for the next one: the
--- guard below acts on GetCursorInfo, so a capture has to say what that
--- predicate answered, or a client where it goes blind looks identical to a
--- bank full of failed lifts.
---
--- It used to lead with a third signal, the source slot's count re-read after
--- the lift, on the project finding that `PickupGuildBankItem` updates the
--- client's slot view optimistically and so source drain is the authoritative
--- discriminator for a completed move. **That is true across frames and false
--- here.** The 2026-09-17 capture read `src drained=0 not-drained=238` over
--- 238 lifts that all succeeded, 162 of them sourcing the tab that was
--- selected at the time, so it is not the view-gating caveat either: the slot
--- API simply does not see a lift within the same frame, and the optimistic
--- update happens at the display layer. The counter reported nothing at this
--- call site and is gone. Do not add it back (#171).
local function probeAfterLift()
    if not state then return end
    local p = state.liftProbe
    if not p then
        p = { hasItem = 0, noItem = 0, types = {} }
        state.liftProbe = p
    end

    local kind = "no-api"
    if _G.GetCursorInfo then
        kind = tostring(_G.GetCursorInfo() or "none")
    end
    p.types[kind] = (p.types[kind] or 0) + 1
    if _G.CursorHasItem then
        if _G.CursorHasItem() then p.hasItem = p.hasItem + 1
        else p.noItem = p.noItem + 1 end
    end
end

--- Count a refused bag deposit. Shared because a bag source can now be
--- refused at two places: by liftFromBag's own pre-checks, and by the cursor
--- guard below, which fires after liftFromBag has already reported success.
--- Writing the counter at only the first of those makes "Sort bags: N
--- deposit(s) issued" count ops that never reached the destination.
local function noteBagSkip(reason)
    if not state then return end
    state.bagOpsSkipped = (state.bagOpsSkipped or 0) + 1
    state.bagSkipReasons = state.bagSkipReasons or {}
    local key = reason or "unknown"
    state.bagSkipReasons[key] = (state.bagSkipReasons[key] or 0) + 1
end

--- @return boolean issued, string|nil reason, string|nil detail
---   false when a source was refused and the op was skipped without touching
---   the destination; the reason and detail come from liftFromBag,
---   liftFromBank, or the cursor guard. A refused source must never fall
---   through to the destination pickup, which on an empty cursor harvests
---   rather than places.
local function issueOp(op)
    -- Unconditional, and that is the point. This was gated on CursorHasItem,
    -- which does not report a guild bank item, so for a bank source it never
    -- once ran. It is the recovery path for the op before it: a refused op
    -- leaves its item on the cursor and a client will not pick a second one
    -- up while one is held, so a single refusal without this clear turns
    -- every following lift into a silent no-op. That is the most consistent
    -- reading of the v0.39.5 capture, where every attempted op refused and not
    -- one slot changed, and it is a reading rather than a measurement (#171).
    ClearCursor()

    local isBag = (op.srcTab or 0) < 0
    if isBag then
        local lifted, reason, detail = liftFromBag(op)
        if not lifted then
            noteBagSkip(reason)
            return false, reason, detail
        end
    else
        local lifted, reason, detail = liftFromBank(op)
        if not lifted then return false, reason, detail end
        probeAfterLift()
    end

    -- THE SOURCE-LIFT GUARD (#169, re-landed on measurement in #171).
    --
    -- Nothing may reach the destination pickup on an empty cursor, because
    -- PickupGuildBankItem does not place there, it picks the destination slot
    -- up. The pre-checks in both lifts cover a source that is gone or short;
    -- this covers what no pre-check can see, a split the server refuses or a
    -- slot locked between the read and the call.
    --
    -- GetCursorInfo, never CursorHasItem. v0.39.5 gated this on CursorHasItem
    -- without watching it run against a guild bank cursor, and in game it
    -- refused every op it attempted and took the sort down in a shipped build.
    -- The 2026-09-17 capture measured both against 238 lifts that all
    -- demonstrably succeeded: GetCursorInfo answered every one correctly and
    -- CursorHasItem answered none.
    --
    -- The fuse is what that outage bought. A predicate that has refused
    -- LIFT_GUARD_FUSE ops in a run without passing once is broken, not
    -- reporting a bank full of failed lifts, so it stands down and says so.
    -- That trades a harvest no capture has ever recorded against an outage
    -- that has. It is armed by "never passed" and not by the count alone: a
    -- guard that has demonstrably worked and then starts refusing is seeing
    -- real failures, and disabling it there is the harvest bug returning
    -- under another name.
    -- The refusal itself never depends on the bookkeeping state existing: a
    -- safety action conditioned on its own telemetry is one missing table
    -- away from silently not happening.
    local loaded = cursorLoaded()
    if loaded == false and not (state and state.liftGuardBlown) then
        if state then
            state.liftGuardRefusals = (state.liftGuardRefusals or 0) + 1
            if not state.liftGuardPassed
               and state.liftGuardRefusals >= LIFT_GUARD_FUSE then
                state.liftGuardBlown = true
                GBL:SortWarn(
                    "Sort: lift guard disabled after %d refusals with no op "
                    .. "passing - the cursor check looks blind on this "
                    .. "client, continuing unguarded (#171)",
                    state.liftGuardRefusals)
            end
        end
        if isBag then noteBagSkip("lift-failed") end
        return false, "lift-failed"
    end
    if loaded and state then state.liftGuardPassed = true end

    -- Past the guard, so this op reaches its destination and counts.
    if isBag and state then
        state.bagOpsIssued = (state.bagOpsIssued or 0) + 1
    end

    PickupGuildBankItem(op.dstTab, op.dstSlot)
    -- The destination is now the run's own write. Recorded here, past the
    -- guard, for the reason bagOpsIssued is: a refused op reached no
    -- destination, and flagging one would wave a later lift from it past
    -- the pre-check on the strength of a write that never happened (#191).
    if state and state.wroteThisPass then
        state.wroteThisPass[slotKey(op.dstTab, op.dstSlot)] = true
    end
    -- A destination holding a different item swaps rather than places, which
    -- hands the displaced stack back on the cursor. Counted off GetCursorInfo
    -- for the same reason the guard reads it: cursorStuck read 0 in every
    -- capture this project has ever taken, and none of those zeroes was
    -- evidence.
    if cursorLoaded() then
        ClearCursor()
        if state then state.cursorStuck = (state.cursorStuck or 0) + 1 end
    end
    return true
end

--- Schedule the next pump tick. The captured token lets a watchdog re-kick
--- invalidate this timer (so a late original fire doesn't double-issue).
local function scheduleNextPump()
    if not state then return end
    local token = state.pumpToken
    state.pumpTimer = C_Timer.After(CADENCE, function()
        if not state or state.pumpToken ~= token or not state.pumping then return end
        pumpOne()
    end)
end

pumpOne = function()
    if not state or not state.pumping then return end
    if not GBL:IsBankOpen() then finish(false, "bank closed"); return end

    local op = state.plan.ops[state.opIndex]
    if not op then
        -- Pass exhausted: settle, then re-scan and re-plan.
        state.pumping = false
        endOfPass()
        return
    end

    noteProgress()
    -- One message per op, carrying the PREVIOUS op's outcome (#162). This
    -- emit fires before issueOp, so this op's outcome is not known yet, and a
    -- second emit after it would have to mark one index both current and
    -- settled, which the consumer cannot order. Riding the outcome one tick
    -- forward leaves exactly one row current with the settled run behind it.
    emitProgress("step", {
        opIndex = state.opIndex,
        issuedOpIndex = state.lastOutcomeIssued,
        failedOpIndex = state.lastOutcomeFailed,
        failedReason = state.lastOutcomeReason,
        failedDetail = state.lastOutcomeDetail,
    })
    state.lastOutcomeIssued = nil
    state.lastOutcomeFailed = nil
    state.lastOutcomeReason = nil
    state.lastOutcomeDetail = nil
    local itemDesc = (op.itemID and GBL.DescribeItem)
        and GBL:DescribeItem(op.itemID) or ("it:" .. tostring(op.itemID))
    -- Slot refs go through GBL:FormatSlotRef so a bag source reads "Bag0/3"
    -- rather than the "T-1/3" a bare tab format would print (#139).
    GBL:SortInfo(string.format(
        "Sort op %d/%d: %s %s->%s %s x%d (viewed %s)",
        state.opIndex, #state.plan.ops, op.op or "move",
        GBL:FormatSlotRef(op.srcTab or 0, op.srcSlot or 0),
        GBL:FormatSlotRef(op.dstTab or 0, op.dstSlot or 0),
        itemDesc, op.count or 0, viewedTabStr()))

    -- A refused bag source is ordinary, not an error: the plan is a snapshot
    -- and the player can move things mid-run. Name the slot AND the reason at
    -- WARN anyway, because "why is this still in my bags" is answered by
    -- which slot was refused and why, not by the run summary's count (#139).
    local issued, skipReason, skipDetail = issueOp(op)
    if issued then
        state.totalIssued = (state.totalIssued or 0) + 1
        state.lastOutcomeIssued = state.opIndex
        -- Flush the transaction log every N issued ops while we have Ledger's
        -- periodic rescan paused, so the per-tab bank log doesn't overflow
        -- before we capture its older entries. Gated on rescanWasActive: if the
        -- user had the rescan disabled, we do not sneak it back in here. The
        -- same call Ledger's ticker makes; pcall + a no-op callback are
        -- defensive. Inside this branch because a refused op moved nothing, so
        -- it added no bank log entry to capture and must not spend a
        -- synchronous QueryGuildBankLog burst.
        if state.rescanWasActive
           and state.totalIssued % TRANSACTION_LOG_FLUSH_OPS == 0 then
            -- Flag the call so _sortNoteRescanTick can tell our own flush from
            -- a rescan started elsewhere. The note fires synchronously near the
            -- top of RescanTransactionLogs, before its debounce, so the flag
            -- cannot outlive this pcall. The clear is guarded because a
            -- teardown inside the call would leave `state` nil.
            state.inOwnFlush = true
            pcall(function()
                if GBL.RescanTransactionLogs then
                    GBL:RescanTransactionLogs(function() end)
                end
            end)
            if state then state.inOwnFlush = false end
        end
    else
        local why = skipReason or "refused"
        -- Counted for both source kinds. The bag counters stay separate so
        -- the "Sort bags:" line keeps meaning what it always did; this pair
        -- is the run total, so it sits at or above the bag figure.
        state.skippedOps = (state.skippedOps or 0) + 1
        state.skipReasons = state.skipReasons or {}
        local tag = skipReason or "refused"
        state.skipReasons[tag] = (state.skipReasons[tag] or 0) + 1
        -- Reason and detail stay apart on the wire, because `why` below folds
        -- the detail into parentheses for the log line and a row rendering
        -- that would print nested brackets (#162). `tag` rather than
        -- skipReason, which can be nil.
        state.lastOutcomeFailed = state.opIndex
        state.lastOutcomeReason = tag
        state.lastOutcomeDetail = skipDetail
        if skipDetail then why = why .. " (" .. skipDetail .. ")" end
        GBL:SortWarn(string.format(
            "Sort op %d/%d skipped: %s %s, wanted %d x %s",
            state.opIndex, #state.plan.ops,
            GBL:FormatSlotRef(op.srcTab or 0, op.srcSlot or 0),
            why, op.count or 0, itemDesc))
    end
    -- Advances either way: the op is done with, issued or refused, and the
    -- pump must not re-try it. Convergence re-plans what is left.
    state.opIndex = state.opIndex + 1
    scheduleNextPump()
end

--- Begin a pass over `plan`: reset the index, swap the live plan (so SortView
--- rebuilds against it), and start pumping.
local function startPass(plan)
    if not state then return end
    state.plan = plan
    state.opIndex = 1
    state.lastPassOps = #plan.ops
    state.passes = (state.passes or 0) + 1
    state.pumping = true
    state.pumpToken = (state.pumpToken or 0) + 1
    -- A new plan renumbers every row, so the previous pass's trailing outcome
    -- would settle an unrelated move (#162). Two guards, both needed: this
    -- clear, and the planupdated emit below carrying no outcome field.
    state.lastOutcomeIssued = nil
    state.lastOutcomeFailed = nil
    state.lastOutcomeReason = nil
    state.lastOutcomeDetail = nil
    -- Every pass follows a full scan that re-queried every tab, so what the
    -- run wrote last pass reads true again and the ledger starts empty (#191).
    state.wroteThisPass = {}
    noteProgress()
    -- After pass 1 the plan changed; tell SortView to rebuild its move list.
    if state.passes > 1 then
        emitProgress("planupdated", { plan = plan })
    end
    pumpOne()
end

------------------------------------------------------------------------
-- End of pass: settle, re-scan, re-plan, decide to rerun or finish.
------------------------------------------------------------------------

endOfPass = function()
    if not state then return end

    -- Settle: let the last fire-and-forget deposits commit on the server before
    -- we scan, so the scan does not read them as residual and rerun needlessly.
    C_Timer.After(SETTLE_DELAY, function()
        if not state then return end
        if not GBL:IsBankOpen() then finish(false, "bank closed"); return end
        if not state.layout then
            -- No layout means we cannot re-plan; treat the pass as the result.
            state.residual = 0
            finish(true, "complete (no layout for rerun)")
            return
        end

        GBL:StartFullScan()
        local deadline = GetTime() + SCAN_WAIT_TIMEOUT
        local function waitForScan()
            if not state then return end
            if GBL.scanInProgress then
                if GetTime() > deadline then
                    finish(false, "scan-wait timeout at end of pass")
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
            -- Re-read the bags rather than reusing the run's opening
            -- snapshot: this pass just deposited out of them, so a cached
            -- copy would plan moves for stacks that are already in the bank.
            -- Every opts field the run needs is rebuilt here from this
            -- pass's own scan, never carried from the opening plan (#139,
            -- #137).
            local replanOpts
            local coverage = GBL.GetLastScanCoverage and GBL:GetLastScanCoverage()
            if coverage then
                replanOpts = { coverage = coverage }
            end
            if state.includeBags and GBL.ScanBags then
                replanOpts = replanOpts or {}
                replanOpts.bagSnapshot = GBL:ScanBags()
            end
            local newPlan = GBL:PlanSort(snapshot, state.layout, replanOpts)
            -- Record what the freshest plan still sees in the bags, so the
            -- finish line reports the last replan rather than the first.
            -- Pass 1's figure is the state before the run did anything,
            -- which is the one number guaranteed to be stale by the time it
            -- is printed. Every terminal branch below runs after this, so
            -- complete, converged and the pass cap all report the same way.
            if newPlan and newPlan.diag then
                state.lastBagSupplies = newPlan.diag.bagSupplies or 0
                state.lastBagStay = newPlan.diag.bagStay or 0
            end
            local newOps = (newPlan and newPlan.ops) and #newPlan.ops or 0
            local prevOps = state.lastPassOps or math.huge

            if newOps == 0 then
                state.residual = 0
                finish(true, "complete")
                return
            end
            if newOps >= prevOps then
                -- The planner cannot improve on the last pass (a genuine deficit
                -- or an unresolvable cascade). Stop rather than loop.
                state.residual = newOps
                finish(true, string.format("converged, %d move(s) unresolved", newOps))
                return
            end
            if (state.passes or 1) >= MAX_PASSES then
                state.residual = newOps
                finish(false, string.format("stopped at %d passes, %d move(s) remain",
                    MAX_PASSES, newOps))
                return
            end
            -- Progress made and within the cap: run another pass.
            GBL:SortInfo(string.format(
                "Sort: pass %d left %d move(s); re-running", state.passes or 1, newOps))
            startPass(newPlan)
        end
        C_Timer.After(0.1, waitForScan)
    end)
end

------------------------------------------------------------------------
-- Bank-close abort (driven by Core, not a self-registered event)
------------------------------------------------------------------------

-- Called by Core:OnBankClosed (the single owner of the frame-hide event) so a
-- running sort aborts on any bank close. Not an AceEvent handler: a second
-- RegisterEvent on the shared GBL object would overwrite Core's handler.
function GBL:_SortExecutorOnBankClosed()
    if not state then return end
    finish(false, "bank closed")
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Begin executing a plan.
-- @param plan table from SortPlanner
-- @param onComplete function(result) called when the run ends
-- @param opts table|nil { layout = layoutForRerun, includeBags = boolean }
--   includeBags (#139) says the plan may contain ops sourced from player
--   bags, and that the end-of-pass replan should re-read them. It is kept
--   for the whole run, not consulted once at the start.
-- @return ok, errMessage
function GBL:ExecuteSortPlan(plan, onComplete, opts)
    if isRunning() then return false, "sort already running" end
    if not plan or not plan.ops then return false, "invalid plan" end
    if not self:IsBankOpen() then return false, "bank not open" end

    state = {
        plan = plan,
        firstPassOps = #plan.ops,
        layout = opts and opts.layout or nil,
        -- #139: remembered for the whole run, not just pass 1. endOfPass
        -- re-reads the bags for its replan; without this the second pass
        -- would silently revert to bank-only and strand the rest.
        includeBags = (opts and opts.includeBags) and true or false,
        bagOpsIssued = 0,
        bagOpsSkipped = 0,
        bagSkipReasons = {},
        skippedOps = 0,
        skipReasons = {},
        staleSourceLifts = 0,
        opIndex = 1,
        passes = 0,
        lastPassOps = nil,
        residual = nil,
        totalIssued = 0,
        cursorStuck = 0,
        -- Source-lift guard bookkeeping, per run rather than per pass: a
        -- blind predicate does not get a second chance at the next pass.
        liftGuardRefusals = 0,
        liftGuardPassed = false,
        liftGuardBlown = false,
        pumping = false,
        pumpToken = 0,
        pumpTimer = nil,
        onComplete = onComplete,
        startedAt = GetTime(),
        lastProgressAt = GetTime(),
        flushes = 0,
        externalRescans = 0,
        inOwnFlush = false,
        syncActiveAtStart = (GBL.IsSyncing and GBL:IsSyncing()) and true or false,
        hitchCount = 0,
        hitchMaxMs = 0,
        hitchByBucket = {},
        stallCount = 0,
    }

    startHitchSampler()
    startStallWatchdog()
    -- Capture the user's pre-pause rescan state BEFORE the env log line so the
    -- line reflects what the user actually had set, not what we are about to
    -- change it to.
    state.rescanWasActive = (GBL.IsPeriodicRescanActive and GBL:IsPeriodicRescanActive()) and true or false
    -- bags= is what every later bag line is read against: without it a run
    -- that deposited nothing cannot be told from one with the toggle off.
    GBL:SortInfo(string.format(
        "Sort: starting execution of %d ops, cadence %.1fs (%s) bags=%s",
        #plan.ops, CADENCE, netPingStr(),
        state.includeBags and "on" or "off"))
    local autoSyncOn = GBL.db and GBL.db.profile and GBL.db.profile.sync
        and GBL.db.profile.sync.autoSync
    GBL:SortInfo(string.format(
        "Sort env: sync %s at start, periodic rescan %s, autoSync %s",
        state.syncActiveAtStart and "ACTIVE" or "idle",
        state.rescanWasActive and "running" or "stopped",
        autoSyncOn and "on" or "off"))
    -- Pause Ledger's periodic rescan for the sort's duration: each rescan tick
    -- hitches the main thread on a `numTabs+1` synchronous QueryGuildBankLog
    -- burst, which delays the pump's frame-driven C_Timer.After and stretches
    -- per-op time from 1s to 3-4s. We restore the user's setting in finish, and
    -- replace the periodic rescan with a count-based flush in pumpOne so the
    -- ledger keeps capturing moves without overflowing the bank's per-tab log.
    if state.rescanWasActive and GBL.StopPeriodicRescan then
        GBL:StopPeriodicRescan()
        GBL:SortInfo(string.format(
            "Sort: throttled the periodic rescan to every %d ops for the sort's duration",
            TRANSACTION_LOG_FLUSH_OPS))
    end
    emitProgress("start")

    -- Empty plan: nothing to do.
    if #plan.ops == 0 then
        state.residual = 0
        finish(true, "complete")
        return true, nil
    end

    startPass(plan)
    return true, nil
end

--- Cancel a running sort.
function GBL:CancelSortExecution()
    if not state then return end
    GBL:SortInfo(string.format(
        "Sort: cancelled at op %d of %d", state.opIndex, #state.plan.ops))
    finish(false, "cancelled")
end

------------------------------------------------------------------------
-- Test hooks
------------------------------------------------------------------------

GBL._sortExecutorConstants = {
    CADENCE = CADENCE,
    SETTLE_DELAY = SETTLE_DELAY,
    MAX_PASSES = MAX_PASSES,
    SCAN_WAIT_TIMEOUT = SCAN_WAIT_TIMEOUT,
    STALL_SLACK = STALL_SLACK,
    -- Read by the flush-throttle specs. A spec matching the literal 15
    -- silently stops discriminating if this moves up: N-1 issued ops
    -- produce no flush under any larger value, so the test passes for the
    -- wrong reason rather than failing.
    TRANSACTION_LOG_FLUSH_OPS = TRANSACTION_LOG_FLUSH_OPS,
}

-- Drive one pump tick directly (the mock does not auto-run timers).
function GBL:_sortExecutorPumpOnce()
    return pumpOne()
end

-- Inspect live pump state for mid-run assertions.
function GBL:_sortExecutorGetPumpInfo()
    if not state then return nil end
    return {
        opIndex = state.opIndex,
        passes = state.passes,
        pumping = state.pumping,
        planOps = #state.plan.ops,
        totalIssued = state.totalIssued,
        cursorStuck = state.cursorStuck,
        includeBags = state.includeBags,
        bagOpsIssued = state.bagOpsIssued,
        bagOpsSkipped = state.bagOpsSkipped,
    }
end

-- The reused frame-hitch sampler frame, so a test can drive its OnUpdate and
-- assert attach/detach.
function GBL:_sortExecutorGetHitchFrame()
    return hitchFrame
end

-- Run one stall-watchdog check against the live state.
function GBL:_sortExecutorCheckStall()
    return checkStall()
end
