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
--      total, replans, passes }.  `opts` = { layout = layoutForReplan,
--      skipPreWarm = bool }.  `layout` is required for auto-rerun.
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
local function netPingStr()
    if not _G.GetNetStats then return "ping ?" end
    local _, _, lagHome, lagWorld = _G.GetNetStats()
    return string.format("ping home %dms / world %dms", lagHome or -1, lagWorld or -1)
end

--- The currently-viewed guild bank tab, stamped on the per-op line. Pure read.
local function viewedTabStr()
    local v = _G.GetCurrentGuildBankTab and _G.GetCurrentGuildBankTab()
    return v and ("T" .. tostring(v)) or "T?"
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
--   totalIssued = N, cursorStuck = N,
--   pumping = bool,              -- true while a pass is issuing; the cancel
--   pumpToken = N,               -- invalidates a stale/late pump timer
--   onComplete = fn, startedAt = t, lastProgressAt = t,
--   hitch*/stallCount = instrumentation,
--   preWarming = true during pre-warm,
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
    if state.preWarming then return end
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

--- Called by Ledger's RescanTransactionLogs when a periodic rescan fires while
--- a sort runs. Counts the ticks (surfaced in the finish summary) and logs the
--- first 40 so a capture shows whether rescans competed with the sort.
function GBL:_sortNoteRescanTick()
    if not state then return end
    state.rescanTicks = (state.rescanTicks or 0) + 1
    if state.rescanTicks <= 40 then
        GBL:SortInfo(string.format(
            "Sort env: periodic rescan fired during sort (#%d, op %d/%d)",
            state.rescanTicks, state.opIndex or 0, #state.plan.ops))
    end
end

--- Emit a progress message for UI subscribers (notably UI/SortView). SortView
--- rebuilds its move list on "planupdated" (payload.plan) and highlights the
--- active row on "step" (payload.opIndex); its onComplete reads the result
--- table from finish, not this payload.
local function emitProgress(phase, extras)
    if not state then return end
    local payload = {
        phase = phase,
        opIndex = state.opIndex,
        done = state.totalIssued,
        failed = state.cursorStuck,
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
        rescanTicks = state.rescanTicks,
        hitchCount = state.hitchCount,
        hitchMaxMs = state.hitchMaxMs,
        hitchByBucket = state.hitchByBucket,
        stallCount = state.stallCount,
        syncActiveAtStart = state.syncActiveAtStart,
    }

    local elapsed = (GetTime() and state.startedAt) and (GetTime() - state.startedAt) or 0
    local issued = state.totalIssued or 0
    local avg = issued > 0 and (elapsed / issued) or 0
    GBL:SortInfo(string.format(
        "Sort: %s in %.1fs - %d passes, %d ops issued, %d remaining, avg %.2fs/op"
        .. " (cursorStuck=%d stalls=%d rescans=%d)",
        ok and "complete" or ("aborted (" .. (reason or "?") .. ")"),
        elapsed, passes, issued, failed,
        avg, state.cursorStuck or 0, state.stallCount or 0, state.rescanTicks or 0))

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
    -- the completion summary.
    emitProgress("finish", { ok = ok, reason = reason })
    ClearCursor()
    if state.pumpTimer and state.pumpTimer.Cancel then state.pumpTimer:Cancel() end
    stopHitchSampler()
    stopStallWatchdog()
    -- Restore the user's periodic rescan if we paused it at sort start. Ledger's
    -- StartPeriodicRescan self-guards on bankOpen / _initialScanComplete /
    -- rescanEnabled / already-active (Ledger.lua:472-475), so a bank-close exit
    -- safely no-ops here.
    if state.rescanWasActive and GBL.StartPeriodicRescan then
        GBL:StartPeriodicRescan()
        GBL:SortInfo("Sort: resumed the periodic rescan")
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
local function issueOp(op)
    if _G.CursorHasItem and _G.CursorHasItem() then ClearCursor() end
    local srcCount = 0
    if _G.GetGuildBankItemInfo then
        local _, c = _G.GetGuildBankItemInfo(op.srcTab, op.srcSlot)
        srcCount = c or 0
    end
    if op.op == "split" and srcCount > (op.count or 0) then
        SplitGuildBankItem(op.srcTab, op.srcSlot, op.count)
    else
        PickupGuildBankItem(op.srcTab, op.srcSlot)
    end
    PickupGuildBankItem(op.dstTab, op.dstSlot)
    if _G.CursorHasItem and _G.CursorHasItem() then
        ClearCursor()
        if state then state.cursorStuck = (state.cursorStuck or 0) + 1 end
    end
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
    emitProgress("step", { opIndex = state.opIndex })
    local itemDesc = (op.itemID and GBL.DescribeItem)
        and GBL:DescribeItem(op.itemID) or ("it:" .. tostring(op.itemID))
    GBL:SortInfo(string.format(
        "Sort op %d/%d: %s T%d/S%d->T%d/S%d %s x%d (viewed %s)",
        state.opIndex, #state.plan.ops, op.op or "move",
        op.srcTab or 0, op.srcSlot or 0, op.dstTab or 0, op.dstSlot or 0,
        itemDesc, op.count or 0, viewedTabStr()))

    issueOp(op)
    state.opIndex = state.opIndex + 1
    state.totalIssued = (state.totalIssued or 0) + 1
    -- Flush the transaction log every N issued ops while we have Ledger's
    -- periodic rescan paused, so the per-tab bank log doesn't overflow before we
    -- capture its older entries. Gated on rescanWasActive: if the user had the
    -- rescan disabled, we do not sneak it back in here. The same call Ledger's
    -- ticker makes; pcall + a no-op callback are defensive.
    if state.rescanWasActive
       and state.totalIssued % TRANSACTION_LOG_FLUSH_OPS == 0 then
        pcall(function()
            if GBL.RescanTransactionLogs then
                GBL:RescanTransactionLogs(function() end)
            end
        end)
    end
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
            local newPlan = GBL:PlanSort(snapshot, state.layout)
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
-- Pre-warm (Item:CreateFromItemLink for crafted-quality crash mitigation)
------------------------------------------------------------------------

-- Atlas marker present in the link of every TWW crafted-quality reagent. A
-- 2026-05-20 in-game crash bottomed out in Blizzard's GetItemReagentQualityInfo
-- when a tab redraw fired after PickupGuildBankItem; pre-warming the item cache
-- is best-effort mitigation, the Sort-tab warning banner is the load-bearing
-- user protection.
local CRAFTED_QUALITY_ATLAS = "Professions-ChatIcon-Quality-"

local PREWARM_CAP_SECONDS = 3.0

--- True if any op in the plan touches a slot whose LIVE item link contains the
--- TWW crafted-quality atlas marker. Used by the Sort tab to render a warning.
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

--- Pre-warm Blizzard's item-data cache for every unique item link in the plan,
--- then invoke `onReady(reason)` exactly once (after all loads or a 3.0s cap).
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
            noteLoaded()
        end
    end

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
-- @param opts table|nil { layout = layoutForRerun, skipPreWarm = bool }
-- @return ok, errMessage
function GBL:ExecuteSortPlan(plan, onComplete, opts)
    if isRunning() then return false, "sort already running" end
    if not plan or not plan.ops then return false, "invalid plan" end
    if not self:IsBankOpen() then return false, "bank not open" end

    state = {
        plan = plan,
        firstPassOps = #plan.ops,
        layout = opts and opts.layout or nil,
        opIndex = 1,
        passes = 0,
        lastPassOps = nil,
        residual = nil,
        totalIssued = 0,
        cursorStuck = 0,
        pumping = false,
        pumpToken = 0,
        pumpTimer = nil,
        onComplete = onComplete,
        startedAt = GetTime(),
        lastProgressAt = GetTime(),
        rescanTicks = 0,
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
    GBL:SortInfo(string.format(
        "Sort: starting execution of %d ops, cadence %.1fs (%s)",
        #plan.ops, CADENCE, netPingStr()))
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

    -- Pre-warm phase: best-effort load of every unique item link before issuing
    -- the first PickupGuildBankItem (TWW crafted-quality crash mitigation).
    if opts and opts.skipPreWarm then
        startPass(plan)
        return true, nil
    end

    state.preWarming = true
    preWarmForPlan(plan, function(_reason)
        if not state then return end
        state.preWarming = nil
        if not GBL:IsBankOpen() then
            finish(false, "bank closed during prewarm")
            return
        end
        startPass(plan)
    end)
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
