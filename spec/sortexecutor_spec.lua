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

            -- The run summary gives a count; the per-op line gives the slot,
            -- which is what answers "why is this still in my bags".
            local blob = {}
            for _, e in ipairs(GBL:GetLog("sort") or {}) do
                blob[#blob + 1] = e.message or ""
            end
            blob = table.concat(blob, "\n")
            assert.is_truthy(blob:find("skipped", 1, true))
            assert.is_truthy(blob:find("Bag0/1", 1, true))
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
end)
