------------------------------------------------------------------------
-- GuildBankLedger — UI/SortView.lua
-- Sort tab: preview the plan, execute (HasSortAccess-gated), cancel,
-- progress display.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function itemLabel(itemID)
    local name = nil
    if GBL.GetCachedItemInfo then
        name = GBL:GetCachedItemInfo(itemID)
    end
    return name or ("item " .. itemID)
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

function GBL:BuildSortTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local canExecute = self:HasSortAccess()

    -- Subscribe to progress events from SortExecutor. Registering on
    -- every build is safe because AceEvent's RegisterMessage is
    -- idempotent (same handler name overwrites the previous subscription).
    -- The handler updates targeted widgets rather than rebuilding the tab,
    -- so per-op events cost microseconds, not a full UI recreation.
    self:RegisterMessage("GBL_SORT_PROGRESS", "_SortView_OnProgress")

    -- Reset per-build widget tables; BuildSortTab is the one place we
    -- recreate the widgets, so caller-retained refs elsewhere would
    -- dangle.
    self._sortOpRows = {}
    self._sortProgressLabel = nil

    -- Status banner
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    status:SetFontObject(GameFontNormalSmall)
    if not self:IsBankOpen() then
        status:SetText("|cffffcc00Open the guild bank to preview and execute sort.|r")
    elseif self._sortViewRescanning then
        status:SetText("|cffffaa55Rescanning bank after sort \226\128\148 preview will update automatically.|r")
    elseif self:IsSortRunning() then
        status:SetText("|cffffaa55Sort in progress \226\128\148 see progress below.|r")
    else
        status:SetText("Ready. Click Preview to inspect the planned moves.")
    end
    container:AddChild(status)

    -- Controls row
    local controls = AceGUI:Create("SimpleGroup")
    controls:SetFullWidth(true)
    controls:SetLayout("Flow")
    container:AddChild(controls)

    -- Content area (scrollable)
    local content = AceGUI:Create("ScrollFrame")
    content:SetFullWidth(true)
    content:SetFullHeight(true)
    content:SetLayout("List")
    container:AddChild(content)
    self._sortContent = content

    local previewBtn = AceGUI:Create("Button")
    previewBtn:SetText("Preview")
    previewBtn:SetWidth(120)
    previewBtn:SetDisabled(self:IsSortRunning())
    previewBtn:SetCallback("OnClick", function()
        self:_SortView_Preview()
    end)
    controls:AddChild(previewBtn)

    local execBtn = AceGUI:Create("Button")
    execBtn:SetText(canExecute and "Execute" or "Execute (no access)")
    execBtn:SetWidth(140)
    execBtn:SetDisabled(not canExecute or self:IsSortRunning())
    execBtn:SetCallback("OnClick", function()
        self:_SortView_Execute()
    end)
    controls:AddChild(execBtn)

    local cancelBtn = AceGUI:Create("Button")
    cancelBtn:SetText("Cancel")
    cancelBtn:SetWidth(100)
    cancelBtn:SetDisabled(not self:IsSortRunning())
    cancelBtn:SetCallback("OnClick", function()
        self:CancelSortExecution()
        self:RefreshSortTab()
    end)
    controls:AddChild(cancelBtn)

    local scanBtn = AceGUI:Create("Button")
    scanBtn:SetText("Scan bank")
    scanBtn:SetWidth(120)
    scanBtn:SetDisabled(not self:IsBankOpen() or self.scanInProgress)
    scanBtn:SetCallback("OnClick", function()
        self:ManualScan()
    end)
    controls:AddChild(scanBtn)

    -- Initial content
    self:_SortView_Preview()
end

--- Refresh the Sort tab — called after state transitions.
function GBL:RefreshSortTab()
    if self.activeTab ~= "sort" then return end
    if not self.tabGroup then return end
    self.tabGroup:ReleaseChildren()
    self:BuildSortTab(self.tabGroup)
end

------------------------------------------------------------------------
-- Preview
------------------------------------------------------------------------

function GBL:_SortView_Preview()
    local AceGUI = LibStub("AceGUI-3.0")
    local content = self._sortContent
    if not content then return end
    content:ReleaseChildren()

    -- If a post-sort rescan is in flight, show a placeholder instead of
    -- re-planning against a stale snapshot. The rescan callback will
    -- RefreshSortTab once the fresh scan lands.
    if self._sortViewRescanning then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("|cffffaa55Waiting for fresh scan results\226\128\166|r")
        content:AddChild(lbl)
        return
    end

    local snapshot = self:GetLastScanResults()
    if not snapshot then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("|cffffcc00No scan yet. Open the bank and click \"Scan bank\".|r")
        content:AddChild(lbl)
        return
    end

    local layout = self:GetBankLayout()
    if not layout or not next(layout.tabs) then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("|cffffcc00No bank layout configured. Open the Layout tab to set one up.|r")
        content:AddChild(lbl)
        return
    end

    local plan = self:PlanSort(snapshot, layout)
    self._sortLastPlan = plan

    -- Summary line
    local opsN = #(plan.ops or {})
    local defN = 0; for _ in pairs(plan.deficits or {}) do defN = defN + 1 end
    local unpN = #(plan.unplaced or {})

    local summary = AceGUI:Create("Label")
    summary:SetFullWidth(true)
    summary:SetText(format(
        "|cff00ff88Plan:|r %d moves · |cffffaa55%d deficits|r · |cffff5555%d unplaced|r",
        opsN, defN, unpN))
    content:AddChild(summary)

    -- Live progress label, updated by _SortView_OnProgress via direct
    -- SetText on this widget — no rebuild needed. Shown blank until the
    -- first progress event arrives.
    local progress = AceGUI:Create("Label")
    progress:SetFullWidth(true)
    progress:SetFontObject(GameFontNormalSmall)
    progress:SetText(" ")
    content:AddChild(progress)
    self._sortProgressLabel = progress

    if opsN == 0 and defN == 0 and unpN == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("|cff00ff88Bank already matches layout — nothing to do.|r")
        content:AddChild(lbl)
        return
    end

    -- Ops list
    if opsN > 0 then
        local h = AceGUI:Create("Heading")
        h:SetFullWidth(true)
        h:SetText(format("Moves (%d)", opsN))
        content:AddChild(h)
        for idx, op in ipairs(plan.ops) do
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFontObject(GameFontNormalSmall)
            lbl:SetText(format("  %s  %d × %s   T%d/%d → T%d/%d",
                op.op, op.count, itemLabel(op.itemID),
                op.srcTab, op.srcSlot, op.dstTab, op.dstSlot))
            content:AddChild(lbl)
            -- Retain the label ref keyed by op index so the progress
            -- handler can prefix it with a status marker.
            self._sortOpRows[idx] = { widget = lbl, op = op }
        end
    end

    -- Deficits
    if defN > 0 then
        local h = AceGUI:Create("Heading")
        h:SetFullWidth(true)
        h:SetText("Deficits (items needed that aren't in the bank)")
        content:AddChild(h)
        for itemID, count in pairs(plan.deficits) do
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFontObject(GameFontNormalSmall)
            lbl:SetText(format("  |cffffaa55missing %d × %s|r", count, itemLabel(itemID)))
            content:AddChild(lbl)
        end
    end

    -- Unplaced
    if unpN > 0 then
        local h = AceGUI:Create("Heading")
        h:SetFullWidth(true)
        h:SetText("Unplaced (couldn't route — overflow full)")
        content:AddChild(h)
        for _, u in ipairs(plan.unplaced) do
            local lbl = AceGUI:Create("Label")
            lbl:SetFullWidth(true)
            lbl:SetFontObject(GameFontNormalSmall)
            lbl:SetText(format("  |cffff5555%d × %s at T%d/%d|r",
                u.count, itemLabel(u.itemID), u.tabIndex, u.slotIndex))
            content:AddChild(lbl)
        end
    end
end

------------------------------------------------------------------------
-- Execute
------------------------------------------------------------------------

function GBL:_SortView_Execute()
    if not self:HasSortAccess() then
        self:Print("You do not have sort access.")
        return
    end
    if not self:IsBankOpen() then
        self:Print("Open the guild bank first.")
        return
    end
    if self:IsSortRunning() then
        self:Print("A sort is already running.")
        return
    end

    local plan = self._sortLastPlan
    if not plan or not plan.ops or #plan.ops == 0 then
        self:Print("No plan to execute — click Preview first.")
        return
    end
    local layout = self:GetBankLayout()
    self:Print(format("Executing %d moves...", #plan.ops))
    self:ExecuteSortPlan(plan, function(result)
        if result.ok then
            self:Print(format("Sort complete: %d done, %d failed, %d replans.",
                result.done, result.failed, result.replans))
        else
            self:Print(format("Sort aborted (%s): %d/%d done, %d failed, %d replans.",
                result.reason, result.done, result.total, result.failed, result.replans))
        end
        -- After execute, the cached snapshot is stale — Preview would show
        -- the pre-sort plan. Rescan first, then refresh so Preview reflects
        -- post-sort state.
        self:_SortView_RescanAndRefresh()
    end, { layout = layout })
    self:RefreshSortTab()
end

------------------------------------------------------------------------
-- Progress
------------------------------------------------------------------------

--- Render the op-row label text with an optional status marker. Separate
--- function so the progress handler can re-render a single row without
--- duplicating the formatting logic.
local function formatOpRow(op, marker)
    local prefix = marker or "  "
    return format("%s%s  %d × %s   T%d/%d → T%d/%d",
        prefix, op.op, op.count,
        (GBL.GetCachedItemInfo and GBL:GetCachedItemInfo(op.itemID))
            or ("item " .. op.itemID),
        op.srcTab, op.srcSlot, op.dstTab, op.dstSlot)
end

--- Handle a GBL_SORT_PROGRESS message from the executor. Called many
--- times per sort (once per op transition). Must be cheap — direct widget
--- SetText only; never a full rebuild.
function GBL:_SortView_OnProgress(_msg, payload)
    if self.activeTab ~= "sort" then return end
    if not payload then return end
    local phase = payload.phase

    -- Update the progress label at the top of the move list.
    if self._sortProgressLabel then
        local text
        if phase == "finish" then
            if payload.ok then
                text = format(
                    "|cff00ff88Sort complete|r — %d done, %d failed, %d replans. Rescanning...",
                    payload.done or 0, payload.failed or 0, payload.replans or 0)
            else
                text = format(
                    "|cffff5555Sort aborted|r (%s) — %d done, %d failed, %d replans.",
                    tostring(payload.reason or "?"),
                    payload.done or 0, payload.failed or 0, payload.replans or 0)
            end
        elseif phase == "replan" then
            text = format(
                "|cffffaa55Replan %d|r (%s) — %d done, %d failed so far.",
                payload.replans or 0, tostring(payload.replanReason or "?"),
                payload.done or 0, payload.failed or 0)
        elseif phase == "start" then
            text = format("|cffffaa55Starting|r — 0 / %d moves.", payload.total or 0)
        else
            -- step / complete / failed / reclassify — show current progress.
            local doneOrFailed = (payload.done or 0) + (payload.failed or 0)
            text = format(
                "|cffffaa55Executing|r — %d / %d  (%d done, %d failed, %d replans)",
                doneOrFailed, payload.total or 0,
                payload.done or 0, payload.failed or 0, payload.replans or 0)
        end
        self._sortProgressLabel:SetText(text)
    end

    -- Mark the last completed / failed op row, and the next-to-run row.
    if self._sortOpRows then
        local completed = payload.completedOpIndex
        if completed and self._sortOpRows[completed] then
            local entry = self._sortOpRows[completed]
            entry.widget:SetText(formatOpRow(entry.op, "|cff00ff88✓|r "))
        end
        local failedIdx = payload.failedOpIndex
        if failedIdx and self._sortOpRows[failedIdx] then
            local entry = self._sortOpRows[failedIdx]
            entry.widget:SetText(formatOpRow(entry.op, "|cffff5555✗|r "))
        end
        local reclassified = payload.reclassifiedOpIndex
        if reclassified and self._sortOpRows[reclassified] then
            local entry = self._sortOpRows[reclassified]
            entry.widget:SetText(formatOpRow(entry.op, "|cff00ff88✓|r "))
        end
        -- Highlight the current op (the one about to run or in flight).
        if phase == "step" and payload.opIndex and
           self._sortOpRows[payload.opIndex] then
            local entry = self._sortOpRows[payload.opIndex]
            entry.widget:SetText(formatOpRow(entry.op, "|cffffaa55▶|r "))
        end
    end
end

--- Trigger a fresh bank scan and refresh the Sort tab when it completes.
-- Used after Execute so Preview always reflects the post-sort snapshot.
-- Also runs a deviation check (chat print) so the user sees exactly what
-- didn't match the layout — useful for catching executor failures or
-- planner-demand mismatches that otherwise would be invisible.
function GBL:_SortView_RescanAndRefresh()
    self._sortViewRescanning = true
    self._sortLastPlan = nil
    self:RefreshSortTab()  -- show "rescanning" placeholder immediately

    if not self:IsBankOpen() then
        self._sortViewRescanning = false
        self:RefreshSortTab()
        return
    end
    if not self.scanInProgress then
        self:StartFullScan()
    end

    local deadline = GetTime() + 5
    local function poll()
        if not self.scanInProgress then
            self._sortViewRescanning = false
            self:RefreshSortTab()
            -- Post-sort deviation check: highlights any slot that didn't
            -- land as the planner expected. Prints to chat so it ends up
            -- in the audit trail / combat log for later inspection.
            if self.PrintDeviations then
                self:PrintDeviations()
            end
        elseif GetTime() < deadline then
            C_Timer.After(0.25, poll)
        else
            -- Scan didn't finish in time; refresh anyway so the user isn't
            -- stuck on the placeholder.
            self._sortViewRescanning = false
            self:RefreshSortTab()
        end
    end
    C_Timer.After(0.25, poll)
end
