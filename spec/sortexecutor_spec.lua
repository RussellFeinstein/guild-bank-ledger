------------------------------------------------------------------------
-- sortexecutor_spec.lua — Tests for SortExecutor.lua (fire-and-forget pump)
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

local function openBank(GBL)
    MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
        Enum.PlayerInteractionType.GuildBanker)
    GBL.bankOpen = true
end

--- Drive C_Timer callbacks repeatedly until no more are pending OR a safety cap.
--- The pump self-reschedules via C_Timer.After and end-of-pass adds settle/scan
--- timers, so several rounds are needed for a run to complete.
local function drainTimers(maxRounds)
    maxRounds = maxRounds or 60
    for _ = 1, maxRounds do
        if #MockWoW.pendingTimers == 0 then return end
        MockWoW.fireTimers()
    end
end

--- Count items of itemID across all slots of a tab.
local function countItem(tabIndex, itemID)
    local tab = MockWoW.guildBank.tabs[tabIndex]
    if not tab then return 0 end
    local total = 0
    for _, slot in pairs(tab.slots) do
        local id = slot.itemLink and slot.itemLink:match("Hitem:(%d+)")
        if id and tonumber(id) == itemID then
            total = total + slot.count
        end
    end
    return total
end

describe("SortExecutor (fire-and-forget pump)", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        MockWoW.guild.name = "Test Guild"
        GBL:OnEnable()
        openBank(GBL)
        MockWoW.addTab("Tab 1", nil, true)
        MockWoW.addTab("Tab 2", nil, true)
    end)

    describe("ExecuteSortPlan entry conditions", function()
        it("refuses to run when the bank is closed", function()
            GBL.bankOpen = false
            local ok, err = GBL:ExecuteSortPlan({ ops = {} })
            assert.is_false(ok)
            assert.matches("bank", err)
        end)

        it("refuses an invalid plan", function()
            local ok, err = GBL:ExecuteSortPlan(nil)
            assert.is_false(ok)
            assert.matches("invalid", err)
        end)

        it("finishes immediately on an empty plan", function()
            local result
            local ok = GBL:ExecuteSortPlan({ ops = {} }, function(r) result = r end)
            assert.is_true(ok)
            assert.is_not_nil(result, "onComplete should fire synchronously")
            assert.is_true(result.ok, result.reason)
            assert.equals(0, result.total)
            assert.equals(0, result.done)
        end)

        it("refuses a second sort while one is running", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function() end)
            local ok, err = GBL:ExecuteSortPlan({ ops = {} })
            assert.is_false(ok)
            assert.matches("already running", err)
            GBL:CancelSortExecution()
            drainTimers()
        end)
    end)

    describe("pump issues moves fire-and-forget", function()
        it("issues a single whole-slot move and places the item", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            assert.equals(0, countItem(1, 100))
            assert.equals(20, countItem(2, 100))
            assert.equals(1, result.passes)
        end)

        it("issues a split op when src has more than op.count", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 50 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "split", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end)
            drainTimers()
            assert.is_true(result.ok, result.reason)
            assert.equals(30, countItem(1, 100))
            assert.equals(20, countItem(2, 100))
        end)

        it("issues N ops in order across N ticks", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 101, name = "Vial", count = 5 },
                [3] = { itemID = 102, name = "Phial", count = 5 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1, dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2, dstTab = 2, dstSlot = 2, itemID = 101, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 3, dstTab = 2, dstSlot = 3, itemID = 102, count = 5 },
                },
            }, function(r) result = r end)
            drainTimers()
            assert.is_true(result.ok, result.reason)
            assert.equals(3, result.total)
            assert.equals(3, result.done)
            assert.equals(0, countItem(1, 100)); assert.equals(5, countItem(2, 100))
            assert.equals(5, countItem(2, 101)); assert.equals(5, countItem(2, 102))
        end)
    end)

    describe("safety + abort paths", function()
        it("cancels mid-pump and reports cancelled", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 101, name = "Vial", count = 5 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1, dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2, dstTab = 2, dstSlot = 2, itemID = 101, count = 5 },
                },
            }, function(r) result = r end)
            -- Op 1 issued synchronously inside startPass; cancel before tick 2 fires.
            GBL:CancelSortExecution()
            drainTimers()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("cancelled", result.reason)
        end)

        it("aborts when the bank closes mid-pump", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 101, name = "Vial", count = 5 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1, dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2, dstTab = 2, dstSlot = 2, itemID = 101, count = 5 },
                },
            }, function(r) result = r end)
            GBL.bankOpen = false
            GBL:_SortExecutorOnBankClosed()
            drainTimers()
            assert.is_false(result.ok)
            assert.matches("bank closed", result.reason)
        end)

        it("end-of-pass without a layout finishes ok rather than re-planning to nothing", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()
            assert.is_true(result.ok, result.reason)
            assert.matches("no layout", result.reason)
            assert.equals(1, result.passes)
        end)
    end)

    describe("instrumentation", function()
        it("hitch sampler attaches at start and detaches at finish", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function() end)
            local frame = GBL:_sortExecutorGetHitchFrame()
            assert.is_not_nil(frame)
            local onUpdate = frame:GetScript("OnUpdate")
            assert.is_function(onUpdate)
            onUpdate(frame, 0.2)   -- primes
            onUpdate(frame, 0.2)   -- records a 200ms hitch
            drainTimers()
            assert.is_nil(frame:GetScript("OnUpdate"), "sampler detached at finish")
        end)

        it("pure recordHitch: threshold + bucket + count", function()
            local rec = GBL._sortExecutorRecordHitch
            local st = { hitchByBucket = {} }
            assert.is_false(rec(st, 0.05))
            assert.is_true(rec(st, 0.18))
            assert.equals(1, st.hitchCount)
            assert.equals(180, st.hitchMaxMs)
            assert.equals(1, st.hitchByBucket["<=250ms"])
            assert.is_true(rec(st, 1.5))
            assert.equals(1, st.hitchByBucket[">1000ms"])
            assert.is_false(rec(nil, 5.0))
        end)

        it("rescan ticks fired during a sort are counted", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 101, name = "Vial", count = 5 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1, dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2, dstTab = 2, dstSlot = 2, itemID = 101, count = 5 },
                },
            }, function(r) result = r end)
            GBL:_sortNoteRescanTick()
            GBL:_sortNoteRescanTick()
            drainTimers()
            assert.equals(2, result.rescanTicks)
        end)

        it("stall watchdog re-kicks the pump when no tick has fired in too long", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 101, name = "Vial", count = 5 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1, dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2, dstTab = 2, dstSlot = 2, itemID = 101, count = 5 },
                },
            }, function() end)
            local before = GBL:_sortExecutorGetPumpInfo()
            assert.is_truthy(before and before.pumping)
            -- Simulate a wedged pump timer: advance the clock past CADENCE+SLACK
            -- without firing pending timers, then fire one watchdog check.
            MockWoW.serverTime = MockWoW.serverTime + 30
            GBL:_sortExecutorCheckStall()
            local after = GBL:_sortExecutorGetPumpInfo()
            assert.is_truthy(after and after.opIndex > (before.opIndex or 0),
                "watchdog should have re-kicked the pump (opIndex advanced)")
            GBL:CancelSortExecution()
            drainTimers()
        end)

        it("emits a per-op SortInfo line", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function() end)
            drainTimers()
            local sawOp = false
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                if e.message and e.message:find("Sort op %d+/%d+:") then
                    sawOp = true; break
                end
            end
            assert.is_true(sawOp, "expected a per-op SortInfo line")
        end)
    end)

    describe("periodic rescan throttle (preserves ledger capture without slowing the pump)", function()
        --- Spy-wrap the three rescan APIs as no-op counters so the test env does
        --- not run the real Ledger periodic chain.
        local function spyRescanFns()
            local s = {
                startCalls = 0, stopCalls = 0, rescanCalls = 0,
                origStart = GBL.StartPeriodicRescan,
                origStop = GBL.StopPeriodicRescan,
                origRescan = GBL.RescanTransactionLogs,
            }
            GBL.StartPeriodicRescan = function(self) s.startCalls = s.startCalls + 1; self._rescanActive = true end
            GBL.StopPeriodicRescan = function(self) s.stopCalls = s.stopCalls + 1; self._rescanActive = false end
            GBL.RescanTransactionLogs = function() s.rescanCalls = s.rescanCalls + 1 end
            return s
        end
        local function restoreRescanFns(s)
            GBL.StartPeriodicRescan = s.origStart
            GBL.StopPeriodicRescan = s.origStop
            GBL.RescanTransactionLogs = s.origRescan
            GBL._rescanActive = false
        end
        --- Flush the OnBankOpened deferred-callback chain (which fires
        --- StartPeriodicRescan) through the spies so its pre-test calls do not
        --- contaminate per-test counters. Run AFTER spy install.
        local function flushBankOpenedChain(s)
            drainTimers()
            s.startCalls, s.stopCalls, s.rescanCalls = 0, 0, 0
        end

        it("pauses Ledger's periodic rescan during a sort and restores it at finish", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = true  -- simulate "Ledger's rescan was running pre-sort"
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            assert.equals(1, s.stopCalls, "StopPeriodicRescan fired at sort start")
            assert.is_false(GBL._rescanActive, "rescan paused during sort")
            drainTimers()
            assert.equals(1, s.startCalls, "StartPeriodicRescan fired at finish")
            assert.is_true(GBL._rescanActive, "rescan restored after finish")
            assert.is_true(result.ok, result.reason)
            restoreRescanFns(s)
        end)

        it("does not restart the rescan in finish if the user had it disabled", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = false  -- user had rescan disabled
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function() end)
            drainTimers()
            assert.equals(0, s.startCalls,
                "StartPeriodicRescan should not fire when rescan was not active at start")
            restoreRescanFns(s)
        end)

        it("flushes the transaction log every N ops while the rescan is paused", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = true  -- so the pump's flush-gate (rescanWasActive) is on
            -- 30 distinct moves T1 -> T2 -> trigger 2 flushes at ops 15 and 30.
            local ops, slots = {}, {}
            for i = 1, 30 do
                ops[i] = { op = "move", srcTab = 1, srcSlot = i,
                           dstTab = 2, dstSlot = i, itemID = 100, count = 5 }
                slots[i] = { itemID = 100, name = "Flask", count = 5 }
            end
            Helpers.populateTab(1, slots)
            local result
            GBL:ExecuteSortPlan({ ops = ops }, function(r) result = r end)
            drainTimers(120)
            assert.is_true(result.ok, result.reason)
            assert.equals(2, s.rescanCalls,
                "expected exactly 2 flushes for 30 ops at flush-every-15")
            restoreRescanFns(s)
        end)

        -- The flush fires on a count of issued ops, so a refused bag deposit
        -- must not advance it. Fourteen real moves plus a refusal is fourteen
        -- ops of bank traffic, and flushing there spends a synchronous
        -- QueryGuildBankLog burst on nothing.
        it("does not let a refused bag op advance the flush counter", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = true
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            local flushEvery = GBL._sortExecutorConstants.TRANSACTION_LOG_FLUSH_OPS
            local ops, slots = {}, {}
            for i = 1, flushEvery - 1 do
                ops[i] = { op = "move", srcTab = 1, srcSlot = i,
                           dstTab = 2, dstSlot = i, itemID = 100, count = 5 }
                slots[i] = { itemID = 100, name = "Flask", count = 5 }
            end
            ops[flushEvery] = { op = "move", srcTab = -1, srcSlot = 1,
                        dstTab = 2, dstSlot = 20, itemID = 100, count = 20 }
            Helpers.populateTab(1, slots)
            GBL:ExecuteSortPlan({ ops = ops }, function() end, { includeBags = true })
            drainTimers(120)
            assert.equals(0, s.rescanCalls,
                "one short of the flush count plus a refusal should not flush")
            restoreRescanFns(s)
        end)

        it("still flushes on the fifteenth issued op when a refusal follows", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = true
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            local flushEvery = GBL._sortExecutorConstants.TRANSACTION_LOG_FLUSH_OPS
            local ops, slots = {}, {}
            for i = 1, flushEvery do
                ops[i] = { op = "move", srcTab = 1, srcSlot = i,
                           dstTab = 2, dstSlot = i, itemID = 100, count = 5 }
                slots[i] = { itemID = 100, name = "Flask", count = 5 }
            end
            ops[flushEvery + 1] = { op = "move", srcTab = -1, srcSlot = 1,
                        dstTab = 2, dstSlot = 20, itemID = 100, count = 20 }
            Helpers.populateTab(1, slots)
            GBL:ExecuteSortPlan({ ops = ops }, function() end, { includeBags = true })
            drainTimers(120)
            assert.equals(1, s.rescanCalls,
                "the fifteenth issued op should still flush exactly once")
            restoreRescanFns(s)
        end)

        it("does not flush when rescan was not active at start (honours user disable)", function()
            local s = spyRescanFns()
            flushBankOpenedChain(s)
            GBL._rescanActive = false  -- user had it off
            local ops, slots = {}, {}
            for i = 1, 30 do
                ops[i] = { op = "move", srcTab = 1, srcSlot = i,
                           dstTab = 2, dstSlot = i, itemID = 100, count = 5 }
                slots[i] = { itemID = 100, name = "Flask", count = 5 }
            end
            Helpers.populateTab(1, slots)
            GBL:ExecuteSortPlan({ ops = ops }, function() end)
            drainTimers(120)
            assert.equals(0, s.rescanCalls,
                "should not flush when rescanWasActive=false")
            restoreRescanFns(s)
        end)
    end)

    describe("result shape (SortView contract)", function()
        it("carries ok/done/failed/total/replans/passes/reason", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_boolean(result.ok)
            assert.is_number(result.done)
            assert.is_number(result.failed)
            assert.is_number(result.total)
            assert.is_number(result.replans)
            assert.is_number(result.passes)
            assert.is_string(result.reason)
        end)
    end)

    ------------------------------------------------------------------
    -- Progress payload (the other half of the SortView contract, #162)
    --
    -- UI/SortView.lua consumed a richer protocol than this file spoke for
    -- four months, and nothing was red because the two sides have never been
    -- joined by a test. They still are not joined here, and cannot be:
    -- MockAce.SendMessage records into sentMessages and does not dispatch,
    -- while MockAce.fireMessage dispatches and is wired to nothing. So the
    -- consumer is proven against a hand-built payload in
    -- spec/ui/sortview_spec.lua and the producer is proven to emit that shape
    -- here. Neither assertion alone says anything about the other side.
    -- Making SendMessage dispatch would change every spec in the suite; it is
    -- filed against #166.
    ------------------------------------------------------------------
    describe("progress payload (SortView contract)", function()
        --- Every GBL_SORT_PROGRESS payload this run emitted, in order.
        local function progressPayloads()
            local out = {}
            for _, m in ipairs(MockAce.sentMessages) do
                if m.message == "GBL_SORT_PROGRESS" then
                    out[#out + 1] = m.args[1]
                end
            end
            return out
        end

        --- The first emitted payload satisfying `pred`.
        local function firstPayload(pred)
            for _, p in ipairs(progressPayloads()) do
                if pred(p) then return p end
            end
            return nil
        end

        --- Enough layout for endOfPass to re-plan against.
        local function simpleLayout()
            return {
                tabs = {
                    [1] = { mode = "display",
                            items = { [100] = { slots = 1, perSlot = 20 } },
                            slotOrder = { [1] = 100 } },
                    [2] = { mode = "overflow" },
                },
            }
        end

        it("reports an issued op on a later step", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 100, name = "Flask", count = 5 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 5 },
                },
            }, function() end)
            drainTimers()

            local p = firstPayload(function(m) return m.issuedOpIndex == 1 end)
            assert.is_not_nil(p, "op 1 was issued and no payload said so")
            assert.equals("step", p.phase)
            assert.equals(2, p.opIndex,
                "the outcome rides the NEXT op's step, so one row is current")
        end)

        -- The reason and the detail travel as two fields, not as the log
        -- line's single `why` string: that one already wraps the detail in
        -- parentheses, so a row rendering it would print nested brackets.
        it("reports a refusal with reason and detail as separate fields", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 3 } })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 3 },
                },
            }, function() end)
            drainTimers()

            local p = firstPayload(function(m) return m.failedOpIndex == 1 end)
            assert.is_not_nil(p, "op 1 was refused and no payload said so")
            assert.equals("short-stack", p.failedReason)
            assert.equals("have 3", p.failedDetail)
        end)

        -- `failed` used to be state.cursorStuck, which counts destination
        -- pickups that SWAPPED rather than placed: a successful move. The
        -- two fields have to be separately readable, and this run has one
        -- refusal and no swap, so equal values would be a coincidence.
        it("carries issued and refused, with refused distinct from cursorStuck", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [2] = { itemID = 100, name = "Flask", count = 3 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 9 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 3, itemID = 100, count = 3 },
                },
            }, function() end)
            drainTimers()

            local all = progressPayloads()
            local last = all[#all]
            assert.is_not_nil(last)
            assert.equals(2, last.issued, "two ops were issued")
            assert.equals(1, last.refused, "one op was refused")
            assert.equals(0, last.cursorStuck,
                "no destination swapped, so refused cannot be reading this")
        end)

        it("finish carries the same done and failed the result does", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            local fin = firstPayload(function(m) return m.phase == "finish" end)
            assert.is_not_nil(fin, "no finish payload")
            assert.equals(result.done, fin.done,
                "the tab and the chat line must not print two numbers")
            assert.equals(result.failed, fin.failed)
        end)

        -- A plan swap renumbers every row, so an index from the old plan
        -- would paint a marker onto an unrelated move. Two guards: the emit
        -- carries no outcome field, and startPass clears the stash so the
        -- next pass's first step cannot carry one either.
        it("does not carry an outcome index across a plan swap", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 5 },
                [5] = { itemID = 200, name = "Ore", count = 5 },
            })
            local realPlanSort = GBL.PlanSort
            local calls = 0
            GBL.PlanSort = function()
                calls = calls + 1
                if calls == 1 then
                    return {
                        ops = { { op = "move", srcTab = 1, srcSlot = 5,
                                  dstTab = 2, dstSlot = 5, itemID = 200, count = 5 } },
                        deficits = {}, unplaced = {},
                    }
                end
                return { ops = {}, deficits = {}, unplaced = {} }
            end
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 9 },
                },
            }, function() end, { layout = simpleLayout() })
            drainTimers(120)
            GBL.PlanSort = realPlanSort

            local swap = firstPayload(function(m) return m.phase == "planupdated" end)
            assert.is_not_nil(swap, "fixture needs a second pass, got " .. calls .. " replan(s)")
            assert.is_nil(swap.issuedOpIndex, "a plan swap must carry no old index")
            assert.is_nil(swap.failedOpIndex, "a plan swap must carry no old index")

            local seenSwap = false
            for _, p in ipairs(progressPayloads()) do
                if p.phase == "planupdated" then
                    seenSwap = true
                elseif seenSwap and p.phase == "step" then
                    assert.is_nil(p.failedOpIndex,
                        "pass 2's first step carried pass 1's last outcome")
                    break
                end
            end
        end)
    end)

    ------------------------------------------------------------------
    -- Bag deposits (#139)
    --
    -- An op whose srcTab is negative sources from a player bag. The
    -- pickup half switches to C_Container; the destination half is an
    -- ordinary guild bank pickup and does not change at all.
    ------------------------------------------------------------------
    describe("bag deposits", function()
        --- Count items of itemID across a mock bag.
        local function countBagItem(bagID, itemID)
            local bag = MockWoW.bags[bagID]
            if not bag then return 0 end
            local total = 0
            for _, slot in pairs(bag.slots) do
                if slot.itemID == itemID then total = total + slot.stackCount end
            end
            return total
        end

        --- Every sort-channel message this run produced, in order.
        local function sortLines()
            local out = {}
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                out[#out + 1] = e.message or ""
            end
            return out
        end

        --- The first sort line containing `needle` (literal, never a pattern).
        local function findLine(needle)
            for _, m in ipairs(sortLines()) do
                if m:find(needle, 1, true) then return m end
            end
            return nil
        end

        --- A layout the executor can re-plan against between passes.
        local function layoutWithDemand(perSlot)
            return {
                tabs = {
                    [1] = { mode = "display",
                            items = { [100] = { slots = 1, perSlot = perSlot } },
                            slotOrder = { [1] = 100 } },
                    [2] = { mode = "overflow" },
                },
            }
        end

        it("deposits a whole bag stack into the bank", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            assert.equals(0, countBagItem(0, 100))
            assert.equals(20, countItem(1, 100))
            assert.equals(1, result.bagOpsIssued)
            assert.equals(0, result.bagOpsSkipped)
        end)

        it("splits a partial stack out of a bag", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 50 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "split", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.is_true(result.ok, result.reason)
            assert.equals(30, countBagItem(0, 100))
            assert.equals(20, countItem(1, 100))
        end)

        it("threads includeBags into the run state", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true })

            local info = GBL:_sortExecutorGetPumpInfo()
            assert.is_true(info.includeBags)
            GBL:CancelSortExecution()
            drainTimers()
        end)

        -- ExecuteSortPlan stored only opts.layout and endOfPass re-planned
        -- with no third argument, so pass 2 would quietly go back to being
        -- bank-only and strand whatever was still in the bags. The snapshot
        -- has to be re-read, not cached, or it would still show the stack
        -- this pass just deposited.
        it("re-reads the bags for the end-of-pass replan", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local seen, called = nil, false
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function(selfRef, snapshot, layout, opts)
                seen, called = opts, true
                return realPlanSort(selfRef, snapshot, layout, opts)
            end
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true, layout = layoutWithDemand(20) })
            drainTimers()
            GBL.PlanSort = realPlanSort

            assert.is_true(called, "endOfPass should re-plan")
            assert.is_not_nil(seen, "replan passed no opts at all")
            assert.is_not_nil(seen.bagSnapshot, "replan lost the bag snapshot")
            -- Freshness: the deposit already happened, so a re-read shows an
            -- empty backpack. A snapshot cached at run start would still
            -- carry the 20 and the planner would re-plan a move of nothing.
            local backpack = seen.bagSnapshot[-1]
            assert.is_true(backpack == nil or backpack.itemCount == 0,
                "replan used a stale bag snapshot")
        end)

        it("omits the bag snapshot when includeBags is off", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            local seen, called = nil, false
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function(selfRef, snapshot, layout, opts)
                seen, called = opts, true
                return realPlanSort(selfRef, snapshot, layout, opts)
            end
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { layout = layoutWithDemand(20) })
            drainTimers()
            GBL.PlanSort = realPlanSort

            assert.is_true(called, "endOfPass should re-plan")
            assert.is_nil(seen and seen.bagSnapshot)
        end)
        -- Same trap the bag snapshot hit: the run's later passes plan with
        -- whatever endOfPass builds, so an opts field the first plan had
        -- and the replan does not is silently dropped halfway through a
        -- sort. Coverage has to be rebuilt there, and from the pass's own
        -- scan rather than the run's opening one.
        it("passes the end-of-pass scan's coverage to the replan", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            local seen
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function(selfRef, snapshot, layout, opts)
                seen = opts
                return realPlanSort(selfRef, snapshot, layout, opts)
            end
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { layout = layoutWithDemand(20) })
            drainTimers()
            GBL.PlanSort = realPlanSort

            assert.is_not_nil(seen, "replan passed no opts at all")
            assert.is_not_nil(seen.coverage, "replan lost the scan coverage")
            assert.same({ 1, 2 }, seen.coverage.viewableTabs)
        end)

        it("takes the replan coverage from the pass's own scan", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            MockWoW.guildBank.tabs[2].isViewable = false
            local seen
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function(selfRef, snapshot, layout, opts)
                seen = opts
                return realPlanSort(selfRef, snapshot, layout, opts)
            end
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { layout = layoutWithDemand(20) })
            drainTimers()
            GBL.PlanSort = realPlanSort

            assert.is_not_nil(seen and seen.coverage)
            assert.same({ 1 }, seen.coverage.viewableTabs)
        end)


        -- The dst pickup is the dangerous half: with an empty cursor it does
        -- not place, it PICKS UP whatever sits in the destination. So a
        -- refused src must return before it, never fall through.
        it("skips a locked bag slot without touching the destination", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            Helpers.populateTab(1, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.is_not_nil(result)
            assert.equals(20, countBagItem(0, 100))
            assert.equals(3, countItem(1, 777))
            assert.equals(0, result.bagOpsIssued)
            assert.equals(1, result.bagOpsSkipped)

            -- The run summary gives a count; the warning gives the slot AND
            -- the reason, which is what answers "why is this still in my
            -- bags". Probe the warning's own prefix rather than the bare
            -- words: "skipped" alone is also satisfied by the finish line
            -- and "Bag0/1" by the ordinary per-op line, so both passed
            -- before any reason was recorded.
            local warn = findLine("skipped: Bag0/1 locked")
            assert.is_not_nil(warn, "no warning naming the locked slot and its reason")
            assert.is_truthy(warn:find("wanted 20 x", 1, true),
                "the warning should say what it wanted: " .. tostring(warn))
        end)

        -- The wrong item has to be present in SUFFICIENT quantity, or the
        -- count check refuses first and this says nothing about the itemID
        -- check. Mutation testing caught exactly that: a 4-count decoy left
        -- the identity check unpinned. Depositing the wrong item into a
        -- layout slot is the failure being guarded against.
        it("skips a bag slot whose item no longer matches the op", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 999, name = "Something Else", count = 50 },
            })
            Helpers.populateTab(1, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(50, countBagItem(0, 999))
            assert.equals(0, countItem(1, 999))
            assert.equals(3, countItem(1, 777))
            assert.equals(1, result.bagOpsSkipped)
            -- The detail names what the slot actually holds, which is the
            -- whole diagnosis: the stack the plan aimed at is gone and
            -- something else took the slot.
            assert.is_not_nil(findLine("skipped: Bag0/1 item-mismatch (holds it:999)"),
                "the warning should name the item the slot now holds")
        end)

        it("skips an empty bag slot", function()
            Helpers.populateBag(0, {})
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 4,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.bagOpsSkipped)
            assert.equals(0, countItem(1, 100))
            assert.is_not_nil(findLine("skipped: Bag0/4 empty"),
                "an absent slot should be reported as empty, not as a mismatch")
        end)

        -- A stack the player partly spent between the plan and the op. The
        -- count is the diagnosis, so it rides the warning: "short-stack"
        -- alone does not say whether one was missing or nineteen.
        it("skips a bag slot that no longer holds enough", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 12 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.bagOpsSkipped)
            assert.equals(12, countBagItem(0, 100))
            assert.equals(0, countItem(1, 100))
            assert.is_not_nil(findLine("skipped: Bag0/1 short-stack (have 12)"),
                "the warning should say how much is actually there")
        end)

        -- Defensive, not reachable from the planner: admission only accepts a
        -- pseudo-tab that round-trips, so a tab this deep decodes to no bag at
        -- all. It renders as T-7/1 rather than a Bag ref on purpose, because
        -- calling an undecodable tab "Bag?" would be a lie about what the op
        -- named. The rule that a bag source must never print as a negative tab
        -- is about VALID bag tabs, which the neighbouring spec pins.
        it("skips an op whose source tab decodes to no bag", function()
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -7, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.bagOpsSkipped)
            assert.is_not_nil(findLine("skipped: T-7/1 no-bag"),
                "an undecodable source tab should be named as such")
        end)

        -- A client without the container API cannot lift from a bag at all.
        -- Reported as its own reason so a capture does not read as "the
        -- player emptied every one of these slots".
        it("skips every bag op when the container API is absent", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local realContainer = _G.C_Container
            _G.C_Container = nil
            local result
            local ok, err = pcall(function()
                GBL:ExecuteSortPlan({
                    ops = { { op = "move", srcTab = -1, srcSlot = 1,
                              dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
                }, function(r) result = r end, { includeBags = true })
                drainTimers()
            end)
            _G.C_Container = realContainer
            assert.is_true(ok, tostring(err))

            assert.equals(1, result.bagOpsSkipped)
            assert.equals(20, countBagItem(0, 100))
            assert.is_not_nil(findLine("skipped: Bag0/1 no-api"),
                "a missing container API should be named, not reported as empty")
        end)

        -- A partial take needs SplitContainerItem. Falling through to the
        -- whole-stack pickup when it is missing deposits everything the
        -- player had, not the surplus the plan asked for, and the bank half
        -- of the op cannot tell the difference. Refusing is recoverable;
        -- over-depositing is not.
        it("refuses a partial take when the split API is absent", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 60 },
            })
            local realSplit = _G.C_Container.SplitContainerItem
            _G.C_Container.SplitContainerItem = nil
            local result
            local ok, err = pcall(function()
                GBL:ExecuteSortPlan({
                    ops = { { op = "split", srcTab = -1, srcSlot = 1,
                              dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
                }, function(r) result = r end, { includeBags = true })
                drainTimers()
            end)
            _G.C_Container.SplitContainerItem = realSplit
            assert.is_true(ok, tostring(err))

            assert.equals(1, result.bagOpsSkipped)
            assert.equals(60, countBagItem(0, 100),
                "the whole stack must stay in the bag rather than be deposited")
            assert.is_not_nil(findLine("skipped: Bag0/1 no-api"),
                "the missing split API should be named")
        end)

        -- The plan is a snapshot. A player who tops a stack up between
        -- Preview and Execute turns a whole-stack "move" into one where the
        -- source holds more than the op asked for, and bags are mutated far
        -- more often than a guild bank is. Take what the op asked for: the
        -- destination was sized for that count, not for whatever the stack
        -- has grown to.
        it("takes only the wanted count when the bag stack grew", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 60 },
            })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true })
            drainTimers()

            assert.equals(40, countBagItem(0, 100),
                "only the 20 the op asked for should have left the bag")
        end)

        it("counts each refusal reason separately in the result", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
                [2] = { itemID = 100, name = "Flask", count = 12 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(2, result.bagOpsSkipped)
            assert.is_not_nil(result.bagSkipReasons, "no per-reason breakdown")
            assert.equals(1, result.bagSkipReasons["locked"])
            assert.equals(1, result.bagSkipReasons["short-stack"])
        end)

        -- "Ops issued" is the number the summary's average seconds-per-op is
        -- computed from, so counting a refusal as issued makes the run look
        -- faster than it was and claims work that never happened.
        it("does not count a refused deposit as an issued op", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true })
            drainTimers()

            -- Probe with the surrounding commas: a bare "0 ops issued" is a
            -- substring of "10 ops issued" and would pass on the wrong run.
            assert.is_not_nil(findLine("passes, 0 ops issued,"),
                "the summary should not claim an op it refused: "
                .. tostring(findLine("ops issued")))
        end)

        -- The abort path is the one that derives done from the issued count
        -- (the normal path takes total minus residual), so it is where a
        -- refusal counted as issued reaches the caller as work completed.
        it("reports no work done when the only issued op was refused", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            local result
            -- The first pump tick runs inside ExecuteSortPlan, so by the time
            -- it returns the bag op has already been refused and op 2 is
            -- still pending.
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 200, count = 10 },
                },
            }, function(r) result = r end, { includeBags = true })
            GBL:CancelSortExecution()
            drainTimers()

            assert.is_not_nil(result)
            assert.equals(0, result.done)
            assert.equals(2, result.total)
        end)

        ------------------------------------------------------------------
        -- The finish line (#139)
        --
        -- "N issued, M skipped" answers what the run did. It does not
        -- answer the question the user actually has, which is whether
        -- anything is still sitting in their bags, so the line carries the
        -- freshest replan's count of that too.
        ------------------------------------------------------------------
        it("reports an emptied bag as nothing left behind", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true, layout = layoutWithDemand(20) })
            drainTimers()

            assert.is_not_nil(
                findLine("Sort bags: 1 deposit(s) issued, 0 skipped, still in bags: 0"),
                "expected the finish line to report an empty bag: "
                .. tostring(findLine("Sort bags:")))
        end)

        -- Two replans, because one cannot tell "the last replan wins" from
        -- "the first replan wins": with a single pass the two are the same
        -- number. Mutation testing caught exactly that. The first replan
        -- still sees two stacks and returns a shorter plan, so a second pass
        -- runs; the second sees none.
        it("reports the last replan's bag count, not the first", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 15 },
            })
            Helpers.populateTab(1, { [5] = { itemID = 200, name = "Ore", count = 5 } })
            local calls = 0
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function()
                calls = calls + 1
                if calls == 1 then
                    return {
                        ops = { { op = "move", srcTab = 1, srcSlot = 5,
                                  dstTab = 2, dstSlot = 5, itemID = 200, count = 5 } },
                        deficits = {}, unplaced = {},
                        diag = { bagSupplies = 2, bagStay = 1 },
                    }
                end
                return { ops = {}, deficits = {}, unplaced = {},
                         diag = { bagSupplies = 0, bagStay = 0 } }
            end
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 15 },
                },
            }, function() end, { includeBags = true, layout = layoutWithDemand(20) })
            drainTimers(120)
            GBL.PlanSort = realPlanSort

            assert.is_true(calls >= 2,
                "fixture needs two replans to tell first from last, got " .. calls)
            assert.is_not_nil(findLine("still in bags: 0"),
                "expected the second replan's count: " .. tostring(findLine("Sort bags:")))
            assert.is_nil(findLine("still in bags: 2"),
                "the first replan's count should not survive to the finish line")
        end)

        -- Three reasons rather than two, because with two the unsorted order
        -- happens to match the sorted one and the mutation that drops the
        -- sort passes.
        it("orders the reason breakdown regardless of table order", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
                [2] = { itemID = 100, name = "Flask", count = 12 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 9,
                      dstTab = 1, dstSlot = 3, itemID = 100, count = 20 },
                },
            }, function() end, { includeBags = true })
            drainTimers()

            assert.is_not_nil(findLine("[empty:1 locked:1 short-stack:1]"),
                "expected the three reasons in sorted order: "
                .. tostring(findLine("Sort bags:")))
        end)

        -- The counts come from a replan rather than from the run's own
        -- tallies, and the unplaceable share renders only when there is one.
        it("renders the replan's bag counts with the unplaceable share", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local realPlanSort = GBL.PlanSort
            GBL.PlanSort = function()
                return { ops = {}, deficits = {}, unplaced = {},
                         diag = { bagSupplies = 3, bagStay = 1 } }
            end
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end,
               { includeBags = true, layout = layoutWithDemand(20) })
            drainTimers()
            GBL.PlanSort = realPlanSort

            assert.is_not_nil(findLine("still in bags: 3 (1 unplaceable)"),
                "expected the replan's own counts: " .. tostring(findLine("Sort bags:")))
            assert.equals(3, result.bagsStillInBags)
            assert.equals(1, result.bagsUnplaceable)
        end)

        -- A run that aborts before any replan has no honest number to give,
        -- and printing 0 there would say the bags are empty when nothing
        -- ever looked.
        it("says the bag count is unknown when no replan ran", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 15 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 15 },
                },
            }, function() end, { includeBags = true, layout = layoutWithDemand(20) })
            GBL:_SortExecutorOnBankClosed()
            drainTimers()

            assert.is_not_nil(findLine("still in bags: unknown (no replan)"),
                "an aborted run should not claim a count it never measured: "
                .. tostring(findLine("Sort bags:")))
        end)

        it("breaks the skipped count down by reason, in a stable order", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
                [2] = { itemID = 100, name = "Flask", count = 12 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 20 },
                },
            }, function() end, { includeBags = true })
            drainTimers()

            assert.is_not_nil(
                findLine("0 deposit(s) issued, 2 skipped [locked:1 short-stack:1]"),
                "expected a sorted per-reason breakdown: "
                .. tostring(findLine("Sort bags:")))
        end)

        -- Bags on and nothing to deposit is a real answer, and it is the one
        -- a capture needs to tell "the toggle was on and your bags held
        -- nothing the layout names" from "the toggle was off".
        it("writes the bag line even when the run moved nothing out of a bag", function()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 200, count = 10 } },
            }, function() end, { includeBags = true })
            drainTimers()

            assert.is_not_nil(findLine("Sort bags: 0 deposit(s) issued, 0 skipped"),
                "bags on with no bag ops should still say so")
        end)

        it("writes no bag line when bags were not included", function()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 200, count = 10 } },
            }, function() end)
            drainTimers()

            assert.is_nil(findLine("Sort bags:"),
                "a bank-only run should not carry a bag line")
        end)

        -- The finish line says what the bags did. Nothing said whether they
        -- were in scope at all, so a run that deposited nothing was
        -- indistinguishable from a run with the toggle off, from the very
        -- first line of the capture.
        it("records that bags were included on the start line", function()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 200, count = 10 } },
            }, function() end, { includeBags = true })
            drainTimers()

            local start = findLine("starting execution")
            assert.is_not_nil(start, "no start line")
            assert.is_truthy(start:find("bags=on", 1, true),
                "start line should say bags were included: " .. tostring(start))
        end)

        it("records that bags were excluded on the start line", function()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 200, count = 10 } },
            }, function() end)
            drainTimers()

            local start = findLine("starting execution")
            assert.is_not_nil(start, "no start line")
            assert.is_truthy(start:find("bags=off", 1, true),
                "start line should say bags were excluded: " .. tostring(start))
        end)

        it("carries on with later ops after a skip", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
                [2] = { itemID = 100, name = "Flask", count = 15 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 15 },
                },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.bagOpsIssued)
            assert.equals(1, result.bagOpsSkipped)
            assert.equals(15, countItem(1, 100))
        end)

        it("counts bank ops separately from bag ops", function()
            Helpers.populateTab(1, { [1] = { itemID = 200, name = "Ore", count = 10 } })
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 200, count = 10 },
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(2, result.done)
            assert.equals(1, result.bagOpsIssued)
            assert.equals(0, result.bagOpsSkipped)
            assert.is_not_nil(findLine("Sort bags: 1 deposit(s) issued, 0 skipped"),
                "the bank op should not be counted as a bag deposit: "
                .. tostring(findLine("Sort bags:")))
        end)

        -- Both counts non-zero and different, so the line cannot pass by
        -- reading the two the wrong way round.
        it("reports issued and skipped deposits as distinct counts", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 15 },
                [3] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = -1, srcSlot = 1,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = -1, srcSlot = 2,
                      dstTab = 1, dstSlot = 2, itemID = 100, count = 15 },
                    { op = "move", srcTab = -1, srcSlot = 3,
                      dstTab = 1, dstSlot = 3, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(2, result.bagOpsIssued)
            assert.equals(1, result.bagOpsSkipped)
            assert.is_not_nil(
                findLine("Sort bags: 2 deposit(s) issued, 1 skipped [locked:1]"),
                "expected two issued and one skipped: "
                .. tostring(findLine("Sort bags:")))
        end)

        it("logs a bag source as BagN/S and never as a negative tab", function()
            Helpers.populateBag(0, {
                [3] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 3,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function() end, { includeBags = true })
            drainTimers()

            local blob = {}
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                blob[#blob + 1] = e.message or ""
            end
            blob = table.concat(blob, "\n")
            assert.is_truthy(blob:find("Bag0/3", 1, true))
            assert.is_nil(blob:find("T-", 1, true))
        end)

        -- Every op refused means the bank never changes, so the replan
        -- returns the same op count and convergence has to stop the run.
        -- The cap on drainTimers is what would expose a loop.
        it("finishes rather than looping when every bag op is refused", function()
            Helpers.populateBag(0, {
                [1] = { itemID = 100, name = "Flask", count = 20, locked = true },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 20 } },
            }, function(r) result = r end,
               { includeBags = true, layout = layoutWithDemand(20) })
            drainTimers()

            assert.is_not_nil(result, "run never finished")
            assert.equals(1, result.bagOpsSkipped)
        end)
    end)

    -- A bank source can fail to lift for the same ordinary reasons a bag one
    -- can: the plan is a snapshot and the player moves things mid-run. The
    -- bag branch has always returned before the destination pickup for that
    -- reason (see "bag deposits" above); the bank branch fell through, and
    -- an empty cursor makes PickupGuildBankItem HARVEST the destination
    -- rather than place into it (#169).
    describe("bank source lifts", function()
        --- The first sort line containing `needle` (literal, never a pattern).
        local function findLine(needle)
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                local m = e.message or ""
                if m:find(needle, 1, true) then return m end
            end
            return nil
        end

        -- The red that proves the harvest. The bystander is an innocent
        -- stack the plan never mentions: nothing in this op names tab 2
        -- slot 1 as a source, so any change to it is the executor acting
        -- outside its own plan.
        it("leaves the destination alone when the bank source slot is empty", function()
            Helpers.populateTab(2, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.is_not_nil(result, "run never finished")
            assert.equals(3, countItem(2, 777),
                "the destination stack was picked up by an op that had nothing on the cursor")
            assert.equals(0, countItem(2, 100))
        end)

        -- Counting it is what makes it visible in a capture; naming the slot
        -- and the reason is what makes the capture actionable. "skipped"
        -- alone is also satisfied by the bags line, so probe the prefix.
        it("counts a failed lift and names the slot and the reason", function()
            Helpers.populateTab(2, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.skippedOps)
            assert.equals(1, (result.skipReasons or {})["empty"])
            local warn = findLine("skipped: T1/1 empty")
            assert.is_not_nil(warn, "no warning naming the refused slot and its reason")
            assert.is_truthy(warn:find("wanted 5 x", 1, true),
                "the warning should say what it wanted: " .. tostring(warn))
        end)

        -- A refused op is not an issued op. Both counters live under the
        -- issued branch for that reason, and the average is derived from
        -- the issued count, so a run of refusals must not move either.
        it("does not count a refused op as issued", function()
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 5 },
                },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(2, result.skippedOps)
            assert.is_not_nil(findLine("0 ops issued"),
                "the summary should report no ops issued when every op was refused")
        end)

        it("rides the run summary as a skipped term with a sorted histogram", function()
            Helpers.populateTab(1, { [3] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 3,
                      dstTab = 2, dstSlot = 3, itemID = 100, count = 5 },
                },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.skippedOps)
            assert.is_not_nil(findLine("skipped=1"),
                "the run summary should carry a skipped term")
            assert.is_not_nil(findLine("[empty:1]"),
                "the run summary should carry the reason histogram")
        end)

        -- Absent at zero. A term that is always present teaches a reader to
        -- stop seeing it, and every clean run would carry it.
        it("omits the skipped term when nothing was refused", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(0, result.skippedOps)
            assert.is_nil(findLine("skipped="),
                "a clean run should not carry the term")
        end)

        -- The guard reads the cursor, so a client without the API cannot run
        -- it. Degrade to today's behaviour rather than refusing everything:
        -- an unreadable cursor is not evidence that the lift failed.
        it("still issues an ordinary op when CursorHasItem is absent", function()
            local saved = _G.CursorHasItem
            _G.CursorHasItem = nil
            finally(function() _G.CursorHasItem = saved end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.is_not_nil(result, "run never finished")
            assert.equals(0, result.skippedOps, "no op should be refused on a client we cannot read")
            assert.equals(5, countItem(2, 100))
        end)

        -- The plan is a snapshot. A stack the player partly spent between
        -- Preview and Execute cannot satisfy the op, and a whole pickup of
        -- what is left would deposit the wrong amount into a slot sized for
        -- the planned one. liftFromBag has always refused here.
        it("refuses a bank source that no longer holds enough", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 3 } })
            Helpers.populateTab(2, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.skippedOps)
            assert.equals(3, countItem(1, 100), "the short stack should be left alone")
            assert.equals(3, countItem(2, 777), "the destination should be untouched")
            assert.is_not_nil(findLine("skipped: T1/1 short-stack (have 3)"),
                "the warning should say how much is actually there")
        end)

        -- The assertion that demotes #161. Phase 3 can emit a partial take
        -- labelled "move" (src/SortPlanner.lua), and the executor used to
        -- branch on that label and pick the whole stack up. Deciding from
        -- what the slot holds now makes a wrong label harmless here, the
        -- way it has always been harmless for a bag source.
        it("takes only op.count from a larger stack even when the op says move", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(0, result.skippedOps)
            assert.equals(5, countItem(2, 100), "the destination was sized for five")
            assert.equals(15, countItem(1, 100), "the rest should stay in the source slot")
        end)

        -- A spy rather than a state assertion, deliberately: the mock clamps
        -- a split to the stack size, so a full-count split and a whole pickup
        -- leave identical state and no fixture can tell them apart. What a
        -- real client does with a split whose count equals the stack is not
        -- recorded anywhere in this repo, which is exactly why the whole
        -- pickup is the branch taken and why the choice is pinned here.
        it("uses a whole pickup, not a split, when the stack is exactly op.count", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local splits, pickups = 0, {}
            local realSplit, realPickup = _G.SplitGuildBankItem, _G.PickupGuildBankItem
            _G.SplitGuildBankItem = function(...) splits = splits + 1; return realSplit(...) end
            _G.PickupGuildBankItem = function(t, s)
                pickups[#pickups + 1] = { t, s }; return realPickup(t, s)
            end
            finally(function()
                _G.SplitGuildBankItem, _G.PickupGuildBankItem = realSplit, realPickup
            end)

            GBL:ExecuteSortPlan({
                ops = { { op = "split", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function() end)
            drainTimers()

            assert.equals(0, splits, "an exact-count take should not go through the split API")
            assert.equals(1, pickups[1][1])
            assert.equals(1, pickups[1][2])
            assert.equals(5, countItem(2, 100))
        end)

        -- #160's re-audit: WoW pushes slot updates for the viewed tab only,
        -- so a non-viewed tab reads back whatever the last query saw. A slot
        -- an earlier op FILLED therefore reads empty, and the old code turned
        -- that into a whole-stack pickup into a slot sized for part of it.
        -- Refusing hands it to the next pass, which re-scans first.
        --
        -- This is the first spec anywhere to set viewGatedReads. The flag has
        -- been wired since v0.32.8 and never exercised.
        it("refuses a stale-empty read on a tab the client is not viewing", function()
            MockWoW.guildBank.viewGatedReads = true
            finally(function() MockWoW.guildBank.viewGatedReads = false end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 30 } })
            -- Snapshot tab 2 while slot 5 is empty, then leave tab 1 selected.
            _G.QueryGuildBankTab(2)
            MockWoW.guildBank.currentTab = 1

            local result
            GBL:ExecuteSortPlan({
                ops = {
                    -- Fills T2/S5. Tab 2 is not viewed, so no push refreshes
                    -- what a read of it will return.
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 5, itemID = 100, count = 30 },
                    -- Sources part of what op 1 just put there.
                    { op = "split", srcTab = 2, srcSlot = 5,
                      dstTab = 1, dstSlot = 1, itemID = 100, count = 10 },
                },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.skippedOps)
            assert.equals(30, countItem(2, 100), "the stack should stay where op 1 put it")
            assert.equals(0, countItem(1, 100), "the destination should not receive a whole stack")
            assert.is_not_nil(findLine("skipped: T2/5 empty"),
                "a stale-empty read should be named as empty")
        end)

        -- THE #169 RESIDUAL CASE, guarded again and this time on a measured
        -- predicate. A stale-HIGH read passes every pre-check and the lift
        -- still finds nothing, so with no guard nothing refuses the op and the
        -- destination pickup harvests an innocent stack.
        --
        -- Between v0.39.6 and this re-land the same fixture ran as a
        -- characterization test asserting the bystander WAS destroyed, so that
        -- re-landing a guard would turn it red and bring whoever did it back
        -- here. It did exactly that.
        it("catches a lift that fails after the read said it would succeed", function()
            MockWoW.guildBank.viewGatedReads = true
            finally(function() MockWoW.guildBank.viewGatedReads = false end)

            Helpers.populateTab(2, { [5] = { itemID = 100, name = "Flask", count = 30 } })
            Helpers.populateTab(1, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            -- Snapshot tab 2 while slot 5 is full, then leave tab 1 selected.
            _G.QueryGuildBankTab(2)
            MockWoW.guildBank.currentTab = 1
            -- The server-side truth moves on without a push to a non-viewed tab.
            MockWoW.guildBank.tabs[2].slots[5] = nil

            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "split", srcTab = 2, srcSlot = 5,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 10 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.skippedOps, "the failed lift should be refused")
            assert.equals(1, (result.skipReasons or {})["lift-failed"])
            assert.equals(3, countItem(1, 777),
                "the bystander at the destination must survive an unplaced lift")
        end)

        -- Three distinct reasons in one run, because that is the only
        -- arrangement in which a sorted histogram and an unsorted one differ.
        -- Every other spec here produces exactly one reason, so `parts` holds
        -- one element and table.sort cannot change the string: dropping the
        -- sort survived the mutation pass until this fixture existed. Three
        -- rather than two on purpose, since Lua makes a single comparison on
        -- two elements and whether that catches anything comes down to pairs
        -- order rather than to the fixture.
        it("sorts the histogram when a run collects several reasons", function()
            MockWoW.addTab("Tab 3", nil, true)
            MockWoW.guildBank.viewGatedReads = true
            finally(function() MockWoW.guildBank.viewGatedReads = false end)

            -- T1/S1 stays empty. T1/S2 holds less than its op asks for.
            Helpers.populateTab(1, { [2] = { itemID = 100, name = "Flask", count = 3 } })
            -- T2/S5 is snapshotted full and then emptied behind the view gate,
            -- so its read passes every pre-check and the lift still finds
            -- nothing. Only the cursor guard sees that one.
            Helpers.populateTab(2, { [5] = { itemID = 100, name = "Flask", count = 30 } })
            _G.QueryGuildBankTab(2)
            MockWoW.guildBank.currentTab = 1
            -- The third op needs a partial take and the split API is gone, so
            -- it refuses as no-api. A client without it cannot take a part of
            -- a stack at all, and the whole-stack pickup that would otherwise
            -- happen deposits more than the destination was sized for.
            local realSplit = _G.SplitGuildBankItem
            _G.SplitGuildBankItem = nil
            finally(function() _G.SplitGuildBankItem = realSplit end)

            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 3, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 3, dstSlot = 2, itemID = 100, count = 5 },
                    { op = "split", srcTab = 2, srcSlot = 5,
                      dstTab = 3, dstSlot = 3, itemID = 100, count = 10 },
                },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(3, result.skippedOps)
            assert.equals(1, (result.skipReasons or {})["empty"])
            assert.equals(1, (result.skipReasons or {})["short-stack"])
            assert.equals(1, (result.skipReasons or {})["no-api"])
            assert.is_not_nil(findLine("[empty:1 no-api:1 short-stack:1]"),
                "the histogram should read in sorted order, not in pairs order")
        end)

        -- THE REGRESSION PIN FOR THE v0.39.5 OUTAGE. Read this before adding
        -- any guard that reads a cursor predicate.
        --
        -- v0.39.5 refused an op when CursorHasItem() reported an empty cursor
        -- after a lift. In game that refused every op attempted, because the
        -- predicate does not report a guild bank item (or the lift is not
        -- synchronous; #171 is measuring which). The suite could not catch it:
        -- spec/mock_wow.lua's CursorHasItem returns `MockWoW.cursor ~= nil`,
        -- which is faithful to the mock's own model of the cursor and not to
        -- the client's, so the guard always passed here and always failed
        -- there.
        --
        -- MockWoW.cursorHasItemLies exists so that shape is reachable. A run
        -- must complete and move items with the predicate lying, because no
        -- action may depend on a predicate whose real behaviour is unverified.
        it("still sorts when CursorHasItem reports an empty cursor that is not", function()
            MockWoW.cursorHasItemLies = true
            finally(function() MockWoW.cursorHasItemLies = nil end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.is_not_nil(result, "run never finished")
            assert.equals(0, result.skippedOps,
                "a lying cursor predicate must not refuse a good op")
            assert.equals(5, countItem(2, 100), "the item should have moved")
            assert.equals(0, countItem(1, 100))
        end)

        -- The probe outlives the question it was built for: it is the tripwire
        -- that reports a predicate going blind before a guard can refuse a
        -- whole run of ops again. It keeps the two cursor counters and has
        -- lost its drain counter, which the same capture proved reports
        -- nothing at this call site.
        it("reports both cursor signals on its own line", function()
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 20 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            local line = findLine("Sort lift probe:")
            assert.is_not_nil(line, "the probe line should be written")
            -- The whole bracket, not a substring of it: "item:1" is also a
            -- substring of "guildbankitem:1", so the loose form passed even
            -- with the mock reporting the type this project measured it does
            -- not report.
            assert.is_truthy(line:find("GetCursorInfo [item:1]", 1, true),
                "GetCursorInfo's answer should be on the line: " .. line)
            assert.is_truthy(line:find("CursorHasItem true=1 false=0", 1, true), line)
            assert.is_falsy(line:find("drained", 1, true),
                "the drain counter reports nothing here and should be gone: " .. line)
        end)

        -- Two kinds in one run, because one kind is the arrangement in which a
        -- sorted histogram and an unsorted one cannot differ. A capture is read
        -- by comparing it against another capture, so pairs order here would
        -- make two recordings of the same run look like different runs.
        --
        -- KNOWN LIMIT, recorded rather than papered over: dropping the
        -- table.sort survives this fixture. Two kinds is the production
        -- maximum, since the pre-op clear means the cursor holds our item or
        -- nothing by the time the probe reads it, and Lua 5.1 hashes strings
        -- deterministically, so "item" and "none" happen to come out of pairs
        -- already in order on this build. The sort is insurance against a
        -- build where they do not, and no fixture using answers a real client
        -- can give will red it. Reaching a third kind would mean inventing a
        -- cursor type the client cannot produce, which protects the line
        -- rather than the behaviour.
        it("sorts the cursor histogram when a run collects more than one kind", function()
            MockWoW.guildBank.viewGatedReads = true
            finally(function() MockWoW.guildBank.viewGatedReads = false end)

            -- T1/1 is live and lifts. T2/5 is snapshotted full, emptied behind
            -- the view gate, and lifts nothing, so GetCursorInfo reads "none".
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            Helpers.populateTab(2, { [5] = { itemID = 101, name = "Ghost", count = 5 } })
            _G.QueryGuildBankTab(2)
            MockWoW.guildBank.currentTab = 1
            MockWoW.guildBank.tabs[2].slots[5] = nil

            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 3, dstSlot = 1, itemID = 100, count = 5 },
                    { op = "move", srcTab = 2, srcSlot = 5,
                      dstTab = 3, dstSlot = 2, itemID = 101, count = 5 },
                },
            }, function() end)
            drainTimers()

            local line = findLine("Sort lift probe:")
            assert.is_not_nil(line)
            assert.is_truthy(line:find("GetCursorInfo [item:1 none:1]", 1, true),
                "the histogram should read in sorted order, not in pairs order: " .. line)
        end)

        -- A bag lift is not probed: bags are not the open question, and
        -- C_Container reads are not view-gated, so including them would dilute
        -- the counts the capture is being read for.
        it("does not probe a bag lift", function()
            Helpers.populateBag(0, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.bagOpsIssued)
            assert.is_nil(result.liftProbe, "bag lifts should leave the probe untouched")
            assert.is_nil(findLine("Sort lift probe:"))
        end)

        -- The guard covers both source kinds. liftFromBag pre-checks more than
        -- liftFromBank can, but a split the server refuses is invisible to any
        -- pre-check, so the cursor read is what stops the destination pickup.
        it("refuses a bag lift that left the cursor empty", function()
            MockWoW.cursorInfoType = false
            finally(function() MockWoW.cursorInfoType = nil end)

            Helpers.populateBag(0, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            Helpers.populateTab(1, { [1] = { itemID = 777, name = "Bystander", count = 3 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(1, result.skippedOps)
            assert.equals(1, (result.skipReasons or {})["lift-failed"])
            assert.equals(3, countItem(1, 777), "the bystander must survive")
        end)

        -- A guard refusal lands AFTER liftFromBag has already reported success,
        -- so the bag counters have to be written on the far side of the guard
        -- or a refused deposit reads as an issued one. That mis-count is what
        -- makes "Sort bags: N deposit(s) issued" a lie, and it is the number a
        -- player checks to find out where their consumables went.
        it("counts a guard refusal of a bag source as a skip, not a deposit", function()
            MockWoW.cursorInfoType = false
            finally(function() MockWoW.cursorInfoType = nil end)

            Helpers.populateBag(0, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = -1, srcSlot = 1,
                          dstTab = 1, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end, { includeBags = true })
            drainTimers()

            assert.equals(0, result.bagOpsIssued, "a refused op is not a deposit")
            assert.equals(1, result.bagOpsSkipped)
            assert.equals(1, (result.bagSkipReasons or {})["lift-failed"])
        end)

        -- An unreadable cursor is not evidence that the lift failed, so a
        -- client without the API keeps the pre-guard behaviour rather than
        -- refusing everything. Same rule the CursorHasItem-absent spec pins.
        it("still issues every op on a client with no GetCursorInfo", function()
            local real = _G.GetCursorInfo
            _G.GetCursorInfo = nil
            finally(function() _G.GetCursorInfo = real end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(0, result.skippedOps)
            assert.equals(5, countItem(2, 100))
        end)

        -- THE FUSE. The guard is verified on one client on one patch and its
        -- failure mode is total: v0.39.5 refused every op it attempted across
        -- two runs of a 207-op plan, issued nothing either time, and did that
        -- in a build that was already on CurseForge. A predicate that has refused a run of ops without ever
        -- once passing is a broken predicate, not a bank full of failed lifts,
        -- so the guard turns itself off and says so rather than taking the
        -- feature down. That trades a theoretical harvest, never once observed
        -- in a capture, against an outage that has now happened.
        it("disables the guard after a run of refusals that never once passed", function()
            MockWoW.cursorInfoType = false
            finally(function() MockWoW.cursorInfoType = nil end)

            local ops, items = {}, {}
            for i = 1, 8 do
                items[i] = { itemID = 100 + i, name = "Thing" .. i, count = 5 }
                ops[i] = { op = "move", srcTab = 1, srcSlot = i,
                           dstTab = 2, dstSlot = i, itemID = 100 + i, count = 5 }
            end
            Helpers.populateTab(1, items)

            local result
            GBL:ExecuteSortPlan({ ops = ops }, function(r) result = r end)
            drainTimers()

            assert.equals(GBL.SORT_LIFT_GUARD_FUSE, result.skippedOps,
                "exactly the fuse's worth of ops should be refused")
            assert.is_true(result.liftGuardBlown)
            assert.is_not_nil(findLine("lift guard disabled"),
                "blowing the fuse has to be loud, or the next outage is silent")
            -- Everything past the fuse goes through.
            assert.equals(5, countItem(2, 108), "the last op should have moved")
        end)

        -- The fuse is armed by "never passed", not by a count alone. A run
        -- where the guard demonstrably works and then starts refusing is a run
        -- of real failed lifts, and turning the guard off there would be the
        -- harvest bug coming back under a different name.
        it("keeps the guard when it has passed at least once in the run", function()
            MockWoW.addTab("Tab 3", nil, true)
            MockWoW.guildBank.viewGatedReads = true
            finally(function() MockWoW.guildBank.viewGatedReads = false end)

            -- Six slots on tab 2 are snapshotted full and then emptied behind
            -- the view gate: each read passes every pre-check and each lift
            -- finds nothing, so only the cursor guard sees them.
            local stale = {}
            for i = 1, 6 do
                stale[i] = { itemID = 200 + i, name = "Ghost" .. i, count = 5 }
            end
            Helpers.populateTab(2, stale)
            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            _G.QueryGuildBankTab(2)
            MockWoW.guildBank.currentTab = 1
            for i = 1, 6 do MockWoW.guildBank.tabs[2].slots[i] = nil end

            -- Op 1 sources the viewed tab and works, which arms nothing.
            local ops = { { op = "move", srcTab = 1, srcSlot = 1,
                            dstTab = 3, dstSlot = 1, itemID = 100, count = 5 } }
            for i = 1, 6 do
                ops[#ops + 1] = { op = "move", srcTab = 2, srcSlot = i,
                                  dstTab = 3, dstSlot = i + 1,
                                  itemID = 200 + i, count = 5 }
            end

            local result
            GBL:ExecuteSortPlan({ ops = ops }, function(r) result = r end)
            drainTimers()

            assert.equals(6, result.skippedOps,
                "every failed lift should stay refused once the guard has proven it works")
            assert.is_falsy(result.liftGuardBlown)
            assert.equals(5, countItem(3, 100), "the good op should still have moved")
        end)

        -- The pre-op clear is what recovers from the op before it. A refused
        -- op leaves its item on the cursor, and the next lift cannot pick
        -- anything up while one is held, so a blind CursorHasItem gating this
        -- clear is how one refusal turns into a whole dead run.
        it("clears a loaded cursor before lifting even when CursorHasItem is blind", function()
            MockWoW.cursorHasItemLies = true
            finally(function()
                MockWoW.cursorHasItemLies = nil
                MockWoW.cursor = nil
            end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            MockWoW.cursor = {
                itemLink = "|cffffffff|Hitem:999::::::::70:::::|h[Junk]|h|r",
                itemID = 999, count = 1,
                src = { tabIndex = 2, slotIndex = 40 },
            }

            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(0, result.skippedOps)
            assert.equals(5, countItem(2, 100), "the op should still have moved")
            assert.equals(0, countItem(1, 999),
                "the held item must never be placed into the source slot")
        end)

        -- cursorStuck has read 0 in every capture this project has ever taken,
        -- because it was counted off the blind predicate. Counting it off
        -- GetCursorInfo is what makes the number mean something.
        it("counts a stuck cursor from GetCursorInfo", function()
            -- Blind the old predicate, or it answers this on its own and the
            -- test proves nothing about which one the counter reads.
            MockWoW.cursorHasItemLies = true
            finally(function() MockWoW.cursorHasItemLies = nil end)

            Helpers.populateTab(1, { [1] = { itemID = 100, name = "Flask", count = 5 } })
            -- A different item at the destination swaps rather than places, so
            -- the displaced stack comes back on the cursor.
            Helpers.populateTab(2, { [1] = { itemID = 777, name = "Other", count = 2 } })

            local result
            GBL:ExecuteSortPlan({
                ops = { { op = "move", srcTab = 1, srcSlot = 1,
                          dstTab = 2, dstSlot = 1, itemID = 100, count = 5 } },
            }, function(r) result = r end)
            drainTimers()

            assert.equals(1, result.cursorStuck,
                "the displaced stack left on the cursor should be counted")
        end)
    end)
end)
