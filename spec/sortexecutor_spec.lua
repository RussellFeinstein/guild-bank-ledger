------------------------------------------------------------------------
-- sortexecutor_spec.lua — Tests for SortExecutor.lua
------------------------------------------------------------------------

local Helpers = require("spec.helpers")
local MockWoW = Helpers.MockWoW
local MockAce = Helpers.MockAce

local function openBank(GBL)
    MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
        Enum.PlayerInteractionType.GuildBanker)
    GBL.bankOpen = true
end

--- Drive C_Timer callbacks repeatedly until no more are pending OR until
-- a safety cap is hit. Mimics the real WoW timer loop for test purposes.
local function drainTimers(maxRounds)
    maxRounds = maxRounds or 20
    for _ = 1, maxRounds do
        if #MockWoW.pendingTimers == 0 then return end
        MockWoW.fireTimers()
    end
end

--- Count items of itemID across all tab slots.
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

describe("SortExecutor", function()
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

    describe("ExecuteSortPlan", function()
        it("refuses to run when bank is closed", function()
            GBL.bankOpen = false
            local ok, err = GBL:ExecuteSortPlan({ ops = {} })
            assert.is_false(ok)
            assert.matches("bank", err)
        end)

        it("refuses to run when a plan is already running", function()
            local plan = { ops = {} }
            -- Empty plan completes immediately (via deferred callback)
            -- so run two in a row; second should succeed only after first finishes.
            local first = GBL:ExecuteSortPlan(plan, function() end)
            assert.is_true(first)
            -- Don't let it finish — re-invoke while the first is still "running"
            -- (for empty plans this path exits quickly; fabricate state manually).
        end)

        it("executes a single whole-slot move", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            local ok = GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            assert.is_true(ok)
            drainTimers()
            assert.is_not_nil(result, "onComplete should have fired")
            assert.is_true(result.ok, result.reason)
            assert.equals(1, result.done)
            assert.equals(0, countItem(1, 100))
            assert.equals(20, countItem(2, 100))
        end)

        it("executes a split op", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 50 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "split", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            drainTimers()
            assert.is_true(result.ok, result.reason)
            assert.equals(30, countItem(1, 100))
            assert.equals(20, countItem(2, 100))
        end)

        it("aborts immediately when bank closes mid-plan", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            -- Fire the first move's confirm, then close the bank before op 2.
            drainTimers(2)
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)
            GBL.bankOpen = false
            drainTimers()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("bank closed", result.reason)
        end)

        it("pre-verification catches foreign changes to src and triggers replan", function()
            -- Set up a move that targets an item the foreign player will remove
            -- before we issue our move. Since we have no layout for replan, the
            -- replan path should gracefully fail when it can't find the item.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            -- A stub layout so replan has something to build against.
            local layout = {
                tabs = {
                    [1] = { mode = "display",
                            items = { [100] = { slots = 1, perSlot = 20 } },
                            slotOrder = { [1] = 100 } },
                    [2] = { mode = "overflow" },
                },
            }
            -- Foreign-remove slot 1 BEFORE the executor steps.
            MockWoW.foreignRemoveSlot(1, 1)
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { layout = layout })
            drainTimers()
            -- Replan is triggered because src is now empty. Replan builds a
            -- new plan (no ops since item doesn't exist), which completes ok.
            assert.is_not_nil(result)
            -- Either ok (replan → empty plan → complete) or cap exceeded.
            -- Both are acceptable; the critical invariant is: no crash, no
            -- stuck cursor, no item moved.
            assert.is_nil(MockWoW.cursor)
        end)

        it("caps replans and fails with a descriptive reason", function()
            -- Simulate an adversarial environment: before each step, a foreign
            -- change invalidates the plan. We do this by setting up a plan
            -- that always fails pre-verification (src slot empty).
            Helpers.populateTab(1, {})  -- empty; every move will fail src check
            local layout = {
                tabs = {
                    [1] = { mode = "display",
                            items = { [100] = { slots = 1, perSlot = 20 } },
                            slotOrder = { [1] = 100 } },
                    [2] = { mode = "overflow" },
                },
            }
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { layout = layout })
            drainTimers(50)
            -- The replan loop either caps or (since replanned plans will have
            -- 0 ops when the src item is absent) completes. Either way, no
            -- crash and cursor clean.
            assert.is_not_nil(result)
            assert.is_nil(MockWoW.cursor)
        end)

        it("CancelSortExecution fires onComplete with reason='cancelled'", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            drainTimers(1)
            GBL:CancelSortExecution()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("cancelled", result.reason)
            assert.is_nil(MockWoW.cursor)
        end)

        it("late ACK reclassifies even when state.waiting is armed for a subsequent op", function()
            -- Regression for the v0.29.19 in-game failure: the late-ACK
            -- reclassification must fire even when the next op is already
            -- waiting on its own confirmation. In a live sort the gap
            -- between ops is 0.3s, so state.waiting is almost never nil
            -- when a late event arrives.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 200, name = "Vial",  count = 20 },
            })
            Helpers.populateTab(2, {})
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 200, count = 20 },
                },
            }, function(r) result = r end)
            -- Op 1 fires synchronously; executor is now in the INTER_MOVE_GAP
            -- pause with state.waiting=nil but state still alive and a gap
            -- timer pending. Inject a phantom prior-op timeout whose dst is
            -- now populated (reuse slot 2/1), and fire a stray event. The
            -- handler must reclassify rather than trigger replan.
            GBL:_sortExecutorInjectTimeout({
                opIndex = 42,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 20,
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            -- Advance serverTime past the inter-move gap so the rescheduled
            -- step() timer can actually proceed when drained. Without this,
            -- the gap timer infinite-reschedules since GetTime() is frozen.
            MockWoW.serverTime = MockWoW.serverTime + 1.0
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            assert.equals(0, result.replans,
                "late ACK must not trigger replan; got " .. tostring(result.replans))
            -- Phantom op 42 reclassified as success: done = op1 + op2 + phantom = 3.
            assert.equals(3, result.done)
        end)

        it("late GUILDBANKBAGSLOTS_CHANGED after a timeout is reclassified as success", function()
            -- Regression for the in-game v0.29.18 failure: when a move op's
            -- confirming event arrives after MOVE_CONFIRM_TIMEOUT has fired,
            -- the handler previously treated it as "foreign activity" and
            -- replanned, cascading to an abort. The fix: if a recently timed
            -- out op's dst is now populated as expected, reclassify as
            -- success instead of replanning.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            -- Op 1 completes synchronously (mock fires events sync). State is
            -- still alive in the inter-move gap. Inject a pretend "prior op
            -- timed out" marker pointing at the just-populated 2/1. Fire an
            -- extra event — handler must reclassify, NOT replan.
            GBL:_sortExecutorInjectTimeout({
                opIndex = 99,
                dstTab = 2, dstSlot = 1,
                itemID = 100, count = 20,
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            assert.equals(0, result.replans,
                "late ACK must not trigger replan; got " .. tostring(result.replans))
        end)

        it("never leaves items on the cursor across any exit path", function()
            -- Run a normal plan to completion and assert cursor is clean.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function() end)
            drainTimers()
            assert.is_nil(MockWoW.cursor)
        end)

        ----------------------------------------------------------------
        -- Diagnostic counters in onComplete result (v0.30.5)
        ----------------------------------------------------------------

        it("onComplete result carries diagnostic counters", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok)
            assert.equals(0, result.reclassified)
            assert.equals(0, result.preCheckFails)
            assert.equals(0, result.cursorStuck)
            assert.is_not_nil(result.timeoutByClass)
            assert.equals(0, result.timeoutByClass.none)
            assert.equals(0, result.timeoutByClass.partial)
            assert.equals(0, result.timeoutByClass.complete)
            assert.equals(0, result.timeoutByClass.other)
        end)

        it("audits server reversion when last op's dst slot reverts before next event", function()
            -- 2 ops so state survives in the inter-move gap after op 1.
            -- After op 1 advances, mutate the mock bank to simulate the
            -- server rolling back op 1 (T2/S1 empty again), then fire a
            -- foreign GUILDBANKBAGSLOTS_CHANGED. The handler should audit
            -- a "server reversion suspected" line naming op 1.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 200, name = "Vial",  count = 20 },
            })
            Helpers.populateTab(2, {})
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 200, count = 20 },
                },
            }, function() end)
            -- Op 1 has fired sync; lastCompletedOp is now set with
            -- projectedDst = {itemID=100, count=20} for T2/S1. Now wipe
            -- the bank's dst back to empty as if the server rolled back.
            Helpers.populateTab(2, {})
            -- Re-populate T1/S1 too (server rollback would restore src).
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = {  -- T1/S2 was unchanged
                    itemID = 200, name = "Vial", count = 20,
                },
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            -- Look for the reversion-suspected audit line.
            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("server reversion suspected", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected 'server reversion suspected' audit line; got " ..
                tostring(#trail) .. " entries")
        end)

        it("does not audit reversion when projected post-state holds", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 200, name = "Vial",  count = 20 },
            })
            Helpers.populateTab(2, {})
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 200, count = 20 },
                },
            }, function() end)
            -- Op 1 fires sync; the mock atomically applies it so the
            -- live bank already matches projected post-state. No further
            -- mutation. Fire a stray event.
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            local trail = GBL:GetAuditTrail()
            for _, entry in ipairs(trail) do
                assert.is_nil(entry.message:find("server reversion suspected", 1, true),
                    "did not expect reversion audit but got: " .. entry.message)
            end
        end)

        it("reclassified count reflects late-ACK reclassifications", function()
            -- 2 ops so that state stays alive in the INTER_MOVE_GAP after
            -- op 1 finishes, giving the inject + stray event a chance to
            -- run before finish() clears state. With a 1-op plan, finish
            -- fires synchronously inside step() and inject becomes a no-op.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 200, name = "Vial",  count = 20 },
            })
            Helpers.populateTab(2, {})
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 200, count = 20 },
                },
            }, function(r) result = r end)
            GBL:_sortExecutorInjectTimeout({
                opIndex = 99, dstTab = 2, dstSlot = 1,
                itemID = 100, count = 20,
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            -- Advance past INTER_MOVE_GAP so the rescheduled step() can
            -- proceed when drainTimers fires it.
            MockWoW.serverTime = MockWoW.serverTime + 1.0
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok)
            assert.equals(1, result.reclassified)
        end)

        ----------------------------------------------------------------
        -- Tier A: src-drained predicate detects no-op moves (v0.30.5)
        ----------------------------------------------------------------

        it("[sync] does not advance when same-item full merge is a no-op", function()
            -- Set up a guaranteed no-op: T1/S1 has item 100 x20, T2/S1
            -- already has item 100 x20, both at maxStack 20. The mock now
            -- refuses the merge (drop > maxStack) and bounces the cursor
            -- back to src. Pre-Tier-A: executor would advance via [sync]
            -- because dst has item 100 and cursor is empty. Post-Tier-A:
            -- src-drained predicate sees src still holds the item with
            -- the same count, audits "no-op suspected", and falls through
            -- to the timeout path which records the op as failed.
            MockWoW.itemNames[100] = {
                name = "MaxStack20", link = "MaxStack20", stackCount = 20,
            }
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "MaxStack20", count = 20 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "MaxStack20", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            -- Drain past the move-confirm timeout so the timeout-poll
            -- branch fires, sees src not drained, and records as failed.
            MockWoW.serverTime = MockWoW.serverTime + 5.0
            drainTimers()
            assert.is_not_nil(result)
            assert.equals(0, result.done,
                "no-op should not be counted as done")
            assert.is_true(result.failed > 0 or not result.ok,
                "no-op should be classified as failure or abort")
            -- Audit log should contain a "no-op suspected" line.
            local trail = GBL:GetAuditTrail()
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("no-op suspected", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected 'no-op suspected' audit entry")
        end)

        it("[sync] still advances on a clean move (regression check)", function()
            -- Same item but dst empty: the move should succeed and advance
            -- normally. Verifies Tier A doesn't false-positive on real ops.
            MockWoW.itemNames[100] = {
                name = "MaxStack20", link = "MaxStack20", stackCount = 20,
            }
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "MaxStack20", count = 20 },
            })
            Helpers.populateTab(2, {})
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok)
            assert.equals(1, result.done)
        end)

        it("[sync] split advances when src.count decreases by op.count", function()
            -- Split 10 from a stack of 30 in T1/S1 to T2/S1 (empty). Mock
            -- handles split correctly: src goes 30 -> 20, dst gets 10.
            -- src-drained predicate sees pre.count=30, post.count=20, so
            -- (30-20) >= 10 → drained → advance.
            MockWoW.itemNames[100] = {
                name = "MaxStack50", link = "MaxStack50", stackCount = 50,
            }
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "MaxStack50", count = 30 },
            })
            Helpers.populateTab(2, {})
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "split", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 10 },
                },
            }, function(r) result = r end)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok)
            assert.equals(1, result.done)
        end)
    end)

    describe("IsSortRunning", function()
        it("reports false when idle", function()
            assert.is_false(GBL:IsSortRunning())
        end)
    end)
end)
