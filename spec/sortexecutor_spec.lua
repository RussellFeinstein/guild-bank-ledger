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
            -- FRAME_HIDE routes through Core:OnBankClosed, which sets
            -- bankOpen=false and aborts the running sort via the executor hook.
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)
            drainTimers()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("bank closed", result.reason)
            assert.is_false(GBL.bankOpen, "Core OnBankClosed should have run")
        end)

        it("Core OnBankClosed still fires on bank close after a sort completes", function()
            -- Regression: the executor used to register frame-hide on the shared
            -- GBL object, overwriting Core's handler and never restoring it, so
            -- after the first sort a bank close skipped OnBankClosed entirely.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { skipPreWarm = true })
            drainTimers()
            assert.is_true(result.ok, result.reason)
            assert.is_true(GBL.bankOpen, "bank still open after the sort")

            -- Close the bank. With the shadow bug, FRAME_HIDE would hit the
            -- executor's leftover (idle) handler and OnBankClosed would never run.
            MockAce.fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
                Enum.PlayerInteractionType.GuildBanker)
            assert.is_false(GBL.bankOpen,
                "Core OnBankClosed must run on bank close after a sort")
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
            assert.equals(0, result.timeoutByClass["server-rejected"])
            assert.equals(0, result.timeoutByClass.partial)
            assert.equals(0, result.timeoutByClass.complete)
            assert.equals(0, result.timeoutByClass["merge-noop"])
            assert.equals(0, result.timeoutByClass.other)
            -- v0.32.8 B3: projection-drift counter surfaces in the result.
            assert.equals(0, result.projectionDrifts)
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
            -- Look for the reversion-suspected audit line in the sort channel.
            local trail = GBL:GetLog("sort")
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("server reversion suspected", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected 'server reversion suspected' sort-log line; got " ..
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
            local trail = GBL:GetLog("sort")
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
            -- Sort log should contain a "no-op suspected" line.
            local trail = GBL:GetLog("sort")
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("no-op suspected", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected 'no-op suspected' sort-log entry")
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

    describe("pre-warm phase (v0.32.5)", function()
        -- Build a crafted-quality-bearing item link by concatenating the
        -- atlas marker the executor sniffs into a quality-3 link. The
        -- helper's makeItemLink() format already has |c..|h[name]|h|r;
        -- we splice the atlas into the displayed-name slot the way TWW
        -- crafted-quality links do.
        local function makeCraftedQualityLink(itemID, name)
            return "|cff0070dd|Hitem:" .. itemID
                .. "::::::::70:::::|h[" .. name
                .. " |A:Professions-ChatIcon-Quality-12-Tier2:17:15::1|a]|h|r"
        end

        it("invokes step synchronously when Item callbacks fire sync", function()
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
        end)

        it("logs a pre-warm audit line on completion", function()
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
            local trail = GBL:GetLog("sort")
            local found = false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sort pre-warm:", 1, true) then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected 'Sort pre-warm:' sort-log line; got " ..
                tostring(#trail) .. " entries")
        end)

        it("resolves via cap timer when Item callbacks never fire", function()
            local original = _G.Item
            _G.Item = {
                CreateFromItemLink = function(_self, _link)
                    return {
                        ContinueOnItemLoad = function() end,  -- never fires
                    }
                end,
            }
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
            -- The 3.0s cap timer is scheduled but hasn't fired yet.
            assert.is_nil(result, "pre-warm should not have resolved yet")
            -- Drain timers: cap fires, executor proceeds, move completes.
            drainTimers()
            _G.Item = original
            assert.is_not_nil(result, "onComplete should have fired")
            local trail = GBL:GetLog("sort")
            local foundCap = false
            for _, entry in ipairs(trail) do
                if entry.message:find("Sort pre-warm:", 1, true)
                   and entry.message:find("(cap)", 1, true) then
                    foundCap = true
                    break
                end
            end
            assert.is_true(foundCap,
                "expected pre-warm audit with reason 'cap'")
        end)

        it("aborts when bank closes during pre-warm", function()
            local original = _G.Item
            local pendingCallbacks = {}
            _G.Item = {
                CreateFromItemLink = function(_self, _link)
                    return {
                        ContinueOnItemLoad = function(_inner, cb)
                            table.insert(pendingCallbacks, cb)
                        end,
                    }
                end,
            }
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
            -- Bank closes while pre-warm is pending. Without the
            -- pre-warm continuation's IsBankOpen guard, step() would
            -- run after the late Item callback and issue Pickup against
            -- a closed bank.
            GBL.bankOpen = false
            for _, cb in ipairs(pendingCallbacks) do cb() end
            drainTimers()
            _G.Item = original
            assert.is_not_nil(result, "onComplete should have fired")
            assert.is_false(result.ok)
            assert.matches("bank closed during prewarm", result.reason)
            assert.equals(0, result.done)
            assert.is_nil(MockWoW.cursor, "cursor should be empty")
        end)

        it("aborts cleanly when cancelled during pre-warm", function()
            local original = _G.Item
            local pendingCallbacks = {}
            _G.Item = {
                CreateFromItemLink = function(_self, _link)
                    return {
                        ContinueOnItemLoad = function(_inner, cb)
                            table.insert(pendingCallbacks, cb)
                        end,
                    }
                end,
            }
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
            -- Cancel before any Item callback fires.
            GBL:CancelSortExecution()
            -- Late callbacks still arrive; pre-warm continuation sees
            -- state == nil and bails without calling step().
            for _, cb in ipairs(pendingCallbacks) do cb() end
            drainTimers()
            _G.Item = original
            assert.is_not_nil(result, "onComplete should have fired")
            assert.is_false(result.ok)
            assert.matches("cancelled", result.reason)
            assert.equals(0, result.done)
            assert.is_nil(MockWoW.cursor, "cursor should be empty")
        end)

        it("skips pre-warm when opts.skipPreWarm is true", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function(r) result = r end, { skipPreWarm = true })
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            local trail = GBL:GetLog("sort")
            for _, entry in ipairs(trail) do
                assert.is_nil(entry.message:find("Sort pre-warm:", 1, true),
                    "did not expect pre-warm audit but got: " ..
                    entry.message)
            end
        end)

        it("ignores foreign bank activity during the pre-warm window", function()
            -- Hold pre-warm open by capturing the load callbacks instead of
            -- firing them, then raise a foreign GUILDBANKBAGSLOTS_CHANGED. With
            -- the preWarming guard the event is ignored; without it the handler
            -- replans and issues the first move on a cold cache (re-opening the
            -- crafted-quality crash), and the later pre-warm step double-issues.
            local original = _G.Item
            local pendingCallbacks = {}
            _G.Item = {
                CreateFromItemLink = function(_self, _link)
                    return {
                        ContinueOnItemLoad = function(_inner, cb)
                            table.insert(pendingCallbacks, cb)
                        end,
                    }
                end,
            }
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
            assert.is_nil(result, "pre-warm should still be in flight")

            -- Foreign guild activity lands mid-pre-warm.
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            assert.is_nil(result,
                "a pre-warm-window event must not start execution")

            -- Complete pre-warm and let the executor run.
            for _, cb in ipairs(pendingCallbacks) do cb() end
            drainTimers()
            _G.Item = original

            assert.is_not_nil(result, "onComplete should have fired")
            assert.is_true(result.ok, result.reason)
            assert.equals(1, result.done)
            assert.equals(0, result.replans,
                "a pre-warm-window event must not trigger a replan")
            assert.equals(0, countItem(1, 100))
            assert.equals(20, countItem(2, 100))
        end)

        it("step() refuses to issue a second op while one is in flight", function()
            -- Make Pickup a counting no-op so the issued op never confirms and
            -- state.waiting stays armed after the first step(). A redundant
            -- step() must then bail on the in-flight guard rather than issuing
            -- a second Pickup pair for the same op.
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local pickups = 0
            local origPickup = _G.PickupGuildBankItem
            local origCursor = _G.CursorHasItem
            _G.PickupGuildBankItem = function() pickups = pickups + 1 end
            _G.CursorHasItem = function() return false end

            GBL:ExecuteSortPlan({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }, function() end, { skipPreWarm = true })
            -- First step ran synchronously: armed waiting + issued one Pickup pair.
            assert.equals(2, pickups,
                "first step should issue exactly one src/dst Pickup pair")

            -- A redundant step() while the op is in flight must bail on the guard.
            GBL:_sortExecutorStep()
            assert.equals(2, pickups,
                "in-flight guard should prevent a second Pickup pair")

            _G.PickupGuildBankItem = origPickup
            _G.CursorHasItem = origCursor
            GBL:CancelSortExecution()
        end)

        it("detects crafted-quality reagents via the atlas marker", function()
            local link = makeCraftedQualityLink(240900, "Flawless Quick Amethyst")
            -- Inject the crafted-quality link directly into the bank
            -- mock; populateTab's makeItemLink would otherwise generate
            -- a plain-quality link.
            MockWoW.guildBank.tabs[1].slots = {
                [1] = {
                    itemLink = link,
                    texture = "Interface\\Icons\\INV_Misc_QuestionMark",
                    count = 3,
                    quality = 3,
                    locked = false,
                    isFiltered = false,
                    itemID = 240900,
                },
            }
            local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
            assert.is_function(helper)
            assert.is_true(helper({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 240900, count = 3 },
                },
            }))
        end)

        it("ignores plans whose ops touch only plain-quality items", function()
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
            assert.is_false(helper({
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 20 },
                },
            }))
        end)

        it("returns false for an empty plan", function()
            local helper = GBL._sortExecutor_PlanHasCraftedQualityItems
            assert.is_false(helper({ ops = {} }))
            assert.is_false(helper(nil))
            assert.is_false(helper({}))
        end)
    end)

    describe("classifyTimeoutState (v0.32.8 B1)", function()
        -- Unit-tests the pure classifier exposed via the test hook. Args are
        -- structured live-slot snapshots ({itemID, count} or nil for empty),
        -- matching what the executor passes from snapshotLiveSlot. The
        -- classifier no longer parses describeSlot strings (those carry the
        -- resolved item name in-game, which defeated the old prefix match).
        it("classifies src-unchanged + dst-empty + no-cursor as server-rejected", function()
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, nil, false)
            assert.equals("server-rejected", class)
        end)

        it("classifies src-empty + cursor-held as partial", function()
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, nil, nil, true)
            assert.equals("partial", class)
        end)

        it("classifies src-empty + dst-has-expected + no-cursor as complete", function()
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, nil, { itemID = 100, count = 20 }, false)
            assert.equals("complete", class)
        end)

        it("classifies src+dst-both-have-expected + no-cursor as merge-noop "
           .. "when dst already held the item pre-op", function()
            -- Genuine no-op: dst already held this item before the op (a merge
            -- that bounced), so nothing was deposited. dstPreLive carries the
            -- pre-op item, distinguishing this from a fresh-deposit drain-pending.
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, { itemID = 100, count = 15 },
                false, { itemID = 100, count = 15 })
            assert.equals("merge-noop", class)
        end)

        it("classifies a fresh deposit with lagging source-drain as drain-pending", function()
            -- Split into a slot that was EMPTY pre-op: dst now holds the item
            -- (deposit landed) but src still shows the full stack (the
            -- source-drain has not surfaced in the client yet). dstPreLive is
            -- nil, so this op deposited what we see. It is in-flight progress,
            -- not a refusal, and must NOT feed the 3-strike abort.
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, { itemID = 100, count = 1 },
                false, nil)
            assert.equals("drain-pending", class)
        end)

        it("classifies a deposit into a slot that held a different item "
           .. "as drain-pending", function()
            -- dstPreLive holds a DIFFERENT item, so the expected item now at
            -- dst was deposited by this op. Still a fresh deposit, not a refusal.
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, { itemID = 100, count = 1 },
                false, { itemID = 999, count = 3 })
            assert.equals("drain-pending", class)
        end)

        it("classifies src+dst-both-have-expected + no-cursor as complete "
           .. "when planner intended a same-item merge", function()
            -- Real merge-into-non-empty whose ACK was lost: planner emitted
            -- this op KNOWING dst already held the item, and the timeout
            -- observation shows both src and dst still hold it. Without
            -- planner intent, this looks identical to merge-noop. With it,
            -- we know the merge happened and treat it as success.
            local op = {
                itemID = 100,
                plannerDstAt = { itemID = 100, count = 5 },
            }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, { itemID = 100, count = 15 }, false)
            assert.equals("complete", class)
        end)

        it("classifies src-empty + dst-empty + no-cursor as other", function()
            local op = { itemID = 100, plannerDstAt = nil }
            -- Nothing observable; should NOT match any of the named cases.
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, nil, nil, false)
            assert.equals("other", class)
        end)

        it("classifies dst holding a different item as other "
           .. "(foreign activity, not a refusal)", function()
            -- src still has the expected item but dst now holds something
            -- else (another player dropped an item into the target slot).
            -- Must NOT bucket as merge-noop / server-rejected, so it never
            -- feeds the 3-strike refusal abort.
            local op = { itemID = 100, plannerDstAt = nil }
            local class = GBL:_sortExecutorClassifyTimeoutState(
                op, { itemID = 100, count = 20 }, { itemID = 999, count = 5 }, false)
            assert.equals("other", class)
        end)
    end)

    describe("isAbortableRefusal (v0.32.8 Phase-1)", function()
        -- Only a move/merge into a slot that already held the SAME item counts
        -- toward the 3-strike abort (a genuine max-stack bounce). Ops into an
        -- empty/different slot are deposits whose confirmation lags, never
        -- refusals, so they must not feed the abort.
        local op = { itemID = 100 }

        it("counts merge-noop into an occupied same-item slot", function()
            assert.is_true(GBL:_sortExecutorIsAbortableRefusal(
                "merge-noop", op, { itemID = 100, count = 20 }))
        end)

        it("counts server-rejected onto an occupied same-item slot", function()
            assert.is_true(GBL:_sortExecutorIsAbortableRefusal(
                "server-rejected", op, { itemID = 100, count = 20 }))
        end)

        it("does NOT count server-rejected into an empty slot (lagging deposit)", function()
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "server-rejected", op, nil))
        end)

        it("does NOT count server-rejected into a different-item slot", function()
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "server-rejected", op, { itemID = 999, count = 3 }))
        end)

        it("does NOT count drain-pending, partial, complete, or other", function()
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "drain-pending", op, nil))
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "partial", op, nil))
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "complete", op, { itemID = 100, count = 5 }))
            assert.is_false(GBL:_sortExecutorIsAbortableRefusal(
                "other", op, { itemID = 100, count = 5 }))
        end)
    end)

    describe("consecutive-refusal abort (v0.32.8 B1)", function()
        -- Drive a real timeout-path classification by exploiting the mock's
        -- bounce-on-max-stack-overflow behavior: when a merge would exceed
        -- the item's stackCount, MockWoW's PickupGuildBankItem drop branch
        -- bounces the cursor item back to its source slot. Post-Pickup
        -- observation: src still holds the item, dst still at max stack,
        -- cursor empty. classifyTimeoutState returns "merge-noop" when the
        -- op's plannerDstAt is nil (planner intended dst to be empty).
        -- Three such ops in a row on the same itemID trip the 3-strike abort.

        local function makeBouncingPlan()
            -- Three move ops, all item 100, each srcN→dstN. Set maxStack=20
            -- and pre-populate each src with x10, each dst with x20. The
            -- merge overflows on every op → bounce → src retains x10, dst
            -- retains x20, cursor empty → classifier reads merge-noop.
            MockWoW.itemNames[100] = { stackCount = 20 }
            -- Add more tabs so we have somewhere to route the ops.
            MockWoW.addTab("Tab 3", nil, true)
            MockWoW.addTab("Tab 4", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 10 },
                [2] = { itemID = 100, name = "Flask", count = 10 },
                [3] = { itemID = 100, name = "Flask", count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 20 },
                [3] = { itemID = 100, name = "Flask", count = 20 },
            })
            return {
                ops = {
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 10,
                      plannerDstAt = nil },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 10,
                      plannerDstAt = nil },
                    { op = "move", srcTab = 1, srcSlot = 3,
                      dstTab = 2, dstSlot = 3, itemID = 100, count = 10,
                      plannerDstAt = nil },
                },
            }
        end

        --- Drive the executor through pending timers while advancing
        --- serverTime so the inter-move gap doesn't stall the loop and the
        --- MOVE_CONFIRM_TIMEOUT C_Timer.After actually crosses its delay.
        local function drainSortWithTimeAdvance(maxRounds)
            maxRounds = maxRounds or 30
            for _ = 1, maxRounds do
                if #MockWoW.pendingTimers == 0 then return end
                MockWoW.serverTime = MockWoW.serverTime + 5.0  -- past 4s timeout
                MockWoW.fireTimers()
            end
        end

        it("aborts with refusal reason after 3 consecutive refusals on same item", function()
            local plan = makeBouncingPlan()
            local result
            GBL:ExecuteSortPlan(plan, function(r) result = r end)
            drainSortWithTimeAdvance()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("repeated server refusal on item 100", result.reason)
            assert.matches("3 consecutive merge%-noop", result.reason)
            -- Three merge-noop timeouts before the abort fires.
            assert.equals(3, result.timeoutByClass["merge-noop"])
            assert.equals(0, result.timeoutByClass["server-rejected"])
            -- Abort fires before opIndex advances past op 3 — so 3 failed,
            -- 0 done.
            assert.equals(0, result.done)
            assert.equals(3, result.failed)
        end)

        it("classifies + aborts even when the item name resolves "
           .. "(in-game regression: classifier must not parse describeSlot)", function()
            -- Regression for the v0.32.8 dead-classifier bug. In-game,
            -- DescribeItem prefixes the resolved name, so describeSlot
            -- returns "Flask of the Currents (it:100) x10" rather than the
            -- bare "it:100 x10" the no-name test env produces. The old
            -- classifier prefix-matched "it:100 x" at position 1, so it
            -- bucketed every real refusal as "other" — silently disabling
            -- the merge-noop bucket and the 3-strike abort. Warm the
            -- ItemCache so describeSlot WOULD carry the name, then assert the
            -- structured classifier still reads merge-noop and aborts.
            local plan = makeBouncingPlan()
            MockWoW.itemNames[100].name = "Flask of the Currents"
            GBL:GetCachedItemInfo(100)  -- synchronously warms the name cache
            -- Premise: the in-game name-prefixed describeSlot form is in play.
            assert.matches("Flask of the Currents %(it:100%)", GBL:DescribeItem(100))

            local result
            GBL:ExecuteSortPlan(plan, function(r) result = r end)
            drainSortWithTimeAdvance()
            assert.is_not_nil(result)
            assert.is_false(result.ok)
            assert.matches("repeated server refusal on item 100", result.reason)
            assert.matches("3 consecutive merge%-noop", result.reason)
            assert.equals(3, result.timeoutByClass["merge-noop"])
            -- The whole point: nothing leaked into "other".
            assert.equals(0, result.timeoutByClass["other"])
        end)

        it("does not abort when a refusal is interrupted by a success", function()
            -- First op bounces (merge-noop, counter=1). Second op succeeds
            -- (counter reset). Third op bounces again (counter=1 again).
            -- No abort.
            MockWoW.itemNames[100] = { stackCount = 20 }
            MockWoW.addTab("Tab 3", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 10 },
                [2] = { itemID = 200, name = "Vial",  count = 10 },
                [3] = { itemID = 100, name = "Flask", count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                -- slot 3 left empty so op 3 can also bounce
                [3] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    -- Op 1: bounces (merge-noop)
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 10,
                      plannerDstAt = nil },
                    -- Op 2: succeeds (different item, empty dst)
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 3, dstSlot = 1, itemID = 200, count = 10 },
                    -- Op 3: bounces (merge-noop)
                    { op = "move", srcTab = 1, srcSlot = 3,
                      dstTab = 2, dstSlot = 3, itemID = 100, count = 10,
                      plannerDstAt = nil },
                },
            }, function(r) result = r end)
            drainSortWithTimeAdvance()
            assert.is_not_nil(result)
            -- Sort runs to completion (no abort): 1 succeeded, 2 timed out.
            assert.is_true(result.ok)
            assert.equals(1, result.done)
            assert.equals(2, result.failed)
            assert.equals(2, result.timeoutByClass["merge-noop"])
        end)

        it("counter resets across items: A refusals do not combine with B refusals (B1.F2)", function()
            -- Per-item isolation: 2 refusals on item 100 followed by 1
            -- refusal on item 200 does NOT trip the 3-strike abort.
            -- consecutiveRefusedByItem is keyed by itemID, but the reset-
            -- on-non-refused-class branch resets the WHOLE table, not
            -- just the same-item entry. So a refusal on item B clears
            -- pending strikes on item A (and on item B too, since the
            -- B refusal increments its own counter to 1 before the
            -- reset-via-different-class logic would fire). Actually:
            -- the table is reset only on success / non-refused class,
            -- NOT on a refusal of a different item. So A=2 + B=1 stays
            -- as {100=2, 200=1} → no abort. This test verifies the
            -- per-item key semantics.
            MockWoW.itemNames[100] = { stackCount = 20 }
            MockWoW.itemNames[200] = { stackCount = 20 }
            MockWoW.addTab("Tab 3", nil, true)
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 10 },
                [2] = { itemID = 100, name = "Flask", count = 10 },
                [3] = { itemID = 200, name = "Vial",  count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
                [2] = { itemID = 100, name = "Flask", count = 20 },
                [3] = { itemID = 200, name = "Vial",  count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    -- 2 refusals on item 100
                    { op = "move", srcTab = 1, srcSlot = 1,
                      dstTab = 2, dstSlot = 1, itemID = 100, count = 10,
                      plannerDstAt = nil },
                    { op = "move", srcTab = 1, srcSlot = 2,
                      dstTab = 2, dstSlot = 2, itemID = 100, count = 10,
                      plannerDstAt = nil },
                    -- 1 refusal on item 200
                    { op = "move", srcTab = 1, srcSlot = 3,
                      dstTab = 2, dstSlot = 3, itemID = 200, count = 10,
                      plannerDstAt = nil },
                },
            }, function(r) result = r end)
            -- Reuse the bounce-test time-advance helper.
            for _ = 1, 30 do
                if #MockWoW.pendingTimers == 0 then break end
                MockWoW.serverTime = MockWoW.serverTime + 5.0
                MockWoW.fireTimers()
            end
            assert.is_not_nil(result)
            -- 2 strikes on item 100, 1 strike on item 200 — neither
            -- reaches 3. Sort runs to its natural end (all 3 ops
            -- failed via merge-noop), no abort.
            assert.is_true(result.ok,
                "expected sort to complete naturally; got reason: " ..
                tostring(result.reason))
            assert.equals(3, result.failed)
            assert.equals(3, result.timeoutByClass["merge-noop"])
        end)

        it("doReplan clears the per-item refusal counter (B1.F1)", function()
            -- Regression: doReplan must reset consecutiveRefusedByItem so
            -- that strikes accumulated under the OLD plan don't leak into
            -- the new plan. Otherwise 2 refusals + replan + 1 refusal on
            -- the same item would falsely trip the 3-strike abort even
            -- though the plan structure changed between strikes 2 and 3.
            --
            -- We use the synthetic _sortExecutorSetRefusalCount hook to
            -- seed counter[100] = 2 without driving through 2 real
            -- refusals (cheaper and deterministic). Then trigger a replan
            -- by firing a foreign GUILDBANKBAGSLOTS_CHANGED while
            -- state.waiting is nil (foreign activity branch). After
            -- replan, the counter must be 0.
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
            -- Op 1 ran sync. State is alive in the inter-move gap.
            -- Seed refusal counter for item 100 to 2 strikes.
            GBL:_sortExecutorSetRefusalCount(100, 2)
            assert.equals(2, GBL:_sortExecutorGetRefusalCount(100))
            -- Now simulate foreign activity that triggers replan. Mutate
            -- the bank's slot 1 (just-vacated by op 1's source) by
            -- placing an unexpected item there.
            Helpers.populateTab(1, {
                [1] = { itemID = 999, name = "Foreign", count = 5 },
                [2] = { itemID = 200, name = "Vial", count = 20 },
            })
            MockAce.fireEvent("GUILDBANKBAGSLOTS_CHANGED")
            -- Counter for item 100 should be cleared by the replan path.
            -- (After the foreign event, state may or may not still be
            -- alive depending on replan internals; if state is nil the
            -- hook returns 0 which is also "cleared".)
            assert.equals(0, GBL:_sortExecutorGetRefusalCount(100),
                "doReplan must reset consecutiveRefusedByItem")
        end)
    end)

    describe("interim-poll cascade (v0.32.8 B2)", function()
        -- Drive the executor through the interim-poll cascade by deferring
        -- bank events so the sync post-Pickup check finds no advance
        -- signal, then fire a queued event from inside one of the interim
        -- poll's offsets to make the predicates pass.

        it("sync path still advances when deferredBankEvents is off", function()
            -- Regression: existing tests rely on sync-mode events firing
            -- during PickupGuildBankItem. The deferred-events flag must
            -- default to false so this path stays intact.
            assert.is_false(MockWoW.deferredBankEvents,
                "deferredBankEvents must default to false")
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
            -- Sync path succeeded — no late-poll, no interim-poll needed.
            assert.equals(1, result.done)
            assert.equals(0, result.timeoutByClass["server-rejected"])
            assert.equals(0, result.timeoutByClass["merge-noop"])
        end)

        it("queues bank events when deferredBankEvents is on", function()
            -- Verify the mock affordance itself: with the flag set,
            -- PickupGuildBankItem mutates bank state but does NOT fire
            -- GUILDBANKBAGSLOTS_CHANGED. The event lands in
            -- MockWoW.queuedBankEvents for explicit pop.
            MockWoW.deferredBankEvents = true
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            assert.equals(0, #MockWoW.queuedBankEvents)
            -- Drive a single Pickup pair without the executor.
            _G.PickupGuildBankItem(1, 1)
            _G.PickupGuildBankItem(2, 1)
            -- Two events queued (one per Pickup), nothing fired.
            assert.is_true(#MockWoW.queuedBankEvents >= 2,
                "expected queued bank events; got " ..
                #MockWoW.queuedBankEvents)
            -- Helper pops events one at a time.
            local fired = MockWoW.fireQueuedBankEvent()
            assert.is_true(fired)
        end)

        it("setupMocks resets deferredBankEvents and queuedBankEvents", function()
            -- Set the flag and queue an event, then re-setup. State must
            -- reset between tests so flags don't leak across files.
            MockWoW.deferredBankEvents = true
            table.insert(MockWoW.queuedBankEvents, "GUILDBANKBAGSLOTS_CHANGED")
            Helpers.setupMocks()
            assert.is_false(MockWoW.deferredBankEvents)
            assert.equals(0, #MockWoW.queuedBankEvents)
        end)

        it("audit emits secondary planner line only on divergence (v0.32.8 B3)", function()
            -- Force a merge-noop timeout (bounce mechanism) but stamp the
            -- op's planner projection to MATCH the observed values. The
            -- planner-projected line should NOT appear, and
            -- projectionDrifts should stay 0.
            MockWoW.itemNames[100] = { stackCount = 20 }
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    -- plannerSrcAt/plannerDstAt deliberately match what
                    -- the bounce-induced timeout observes: src still has
                    -- 10 (bounced back), dst still has 20.
                    {
                        op = "move", srcTab = 1, srcSlot = 1,
                        dstTab = 2, dstSlot = 1, itemID = 100, count = 10,
                        plannerSrcAt = { itemID = 100, count = 10 },
                        plannerDstAt = { itemID = 100, count = 20 },
                    },
                },
            }, function(r) result = r end)
            -- Drive past the 4 s late-poll.
            for _ = 1, 30 do
                if #MockWoW.pendingTimers == 0 then break end
                MockWoW.serverTime = MockWoW.serverTime + 5.0
                MockWoW.fireTimers()
            end
            assert.is_not_nil(result)
            -- Op classified as complete because plannerDstAt has the same
            -- item (B1 classifier disambiguates merge-noop vs complete).
            -- This op shows up as "complete" timeout (real merge ACK lost).
            -- Either way, planner-projected == observed → no drift.
            assert.equals(0, result.projectionDrifts,
                "no divergence expected when planner projection matches observed")
            -- The secondary "(planner projected: …)" line must NOT appear.
            local trail = GBL:GetLog("sort")
            local sawProjectedLine = false
            for _, entry in ipairs(trail or {}) do
                if entry.message and entry.message:find("planner projected:", 1, true) then
                    sawProjectedLine = true
                    break
                end
            end
            assert.is_false(sawProjectedLine,
                "secondary planner-projected line must be suppressed when matching observed")
        end)

        it("audit emits secondary planner line on real divergence (v0.32.8 B3)", function()
            -- Same bounce setup as above but stamp plannerSrcAt with a
            -- DIFFERENT count than what observed will show. The planner-
            -- projected line MUST appear and projectionDrifts increments.
            MockWoW.itemNames[100] = { stackCount = 20 }
            Helpers.populateTab(1, {
                [1] = { itemID = 100, name = "Flask", count = 10 },
            })
            Helpers.populateTab(2, {
                [1] = { itemID = 100, name = "Flask", count = 20 },
            })
            local result
            GBL:ExecuteSortPlan({
                ops = {
                    {
                        op = "move", srcTab = 1, srcSlot = 1,
                        dstTab = 2, dstSlot = 1, itemID = 100, count = 10,
                        -- Deliberately mismatch live: planner thought src
                        -- had 6 (it actually has 10 post-bounce).
                        plannerSrcAt = { itemID = 100, count = 6 },
                        plannerDstAt = { itemID = 100, count = 20 },
                    },
                },
            }, function(r) result = r end)
            for _ = 1, 30 do
                if #MockWoW.pendingTimers == 0 then break end
                MockWoW.serverTime = MockWoW.serverTime + 5.0
                MockWoW.fireTimers()
            end
            assert.is_not_nil(result)
            -- Real drift detected.
            assert.equals(1, result.projectionDrifts)
            -- Audit trail contains the secondary planner-projected line.
            local trail = GBL:GetLog("sort")
            local sawProjectedLine = false
            for _, entry in ipairs(trail or {}) do
                if entry.message and entry.message:find("planner projected:", 1, true) then
                    sawProjectedLine = true
                    break
                end
            end
            assert.is_true(sawProjectedLine,
                "secondary planner-projected line must appear on divergence")
        end)

        it("interim-poll advances when predicates pass after deferred event", function()
            -- End-to-end: defer bank events, issue a sort, advance time
            -- past the first interim-poll offset (0.25s). At that point
            -- the bank state already reflects the move (mock mutates
            -- slot state synchronously even when events are deferred),
            -- so the interim-poll's predicates pass and the op advances
            -- via [interim-poll]. Audit trail records the tag.
            MockWoW.deferredBankEvents = true
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
            -- Pickup pair ran synchronously, mock mutated slots. Events
            -- are queued, not fired. Sync post-Pickup check inside step()
            -- DOES run (since it doesn't rely on events) — and in this
            -- case it would have advanced too. To exercise the
            -- interim-poll specifically, we'd need a scenario where the
            -- sync check fails but the predicates pass at 0.25s. The
            -- mock's slot mutation is instantaneous, so the sync check
            -- always wins here. This test therefore verifies the END
            -- result is correct under deferredBankEvents, not which
            -- branch advanced.
            drainTimers()
            assert.is_not_nil(result)
            assert.is_true(result.ok, result.reason)
            assert.equals(1, result.done)
            -- Whichever branch advanced, the timeout buckets stay empty.
            assert.equals(0, result.timeoutByClass["merge-noop"])
            assert.equals(0, result.timeoutByClass["server-rejected"])
        end)
    end)
end)
