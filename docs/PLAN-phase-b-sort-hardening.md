# Phase B Sort Hardening — Audit and Plan

## Status

- **Phase A** shipped as v0.32.5 on `main` (commit `eee8a83`). Pre-warm + warning banner prevented the TWW crafted-quality reagent crash; verified in-game on a 502-slot bank.
- **Phase B** scope: late-poll dominance, singleton-chain emit, planner state desync on splits, `[other]` timeout bucket overload. Originally identified in `~/.claude/projects/.../memory/project_sort_log_2026_05_14_late_poll_storm.md`; reproduced on 2026-05-20 (see `docs/sort-logs/2026-05-20-prewarm-success-late-poll-recurrence.md`).
- **This document** is the Phase B audit and milestone proposal. Current branch: `layout-sort`. Target version: `v0.32.8` (patch; v0.32.6 and v0.32.7 consumed by two intervening hotfixes).

## Data points

Two in-game sort logs in-repo:

- `docs/sort-logs/2026-05-14-late-poll-storm.md` — 7-tab / 515-slot bank, v0.32.3. Run A aborted at replan 5/5; Run B completed 64/64 with every op via the 4.0 s late-poll floor. Singleton-chain (Gateway Control Shard) and split desync (Flawless gems) both visible.
- `docs/sort-logs/2026-05-20-prewarm-success-late-poll-recurrence.md` — 7-tab / 502-slot bank, v0.32.4. Same patterns reproduce six days later. Pre-warm worked; the Phase B issues did not.

Both logs are now durable starting data; we are not relying on memory for these observations.

## Problem inventory

### B1. `[other]` timeout bucket overloaded *(diagnostic + behavioral; smallest)*

**Symptom.** `timeout[n=0,p=0,c=0,o=44]` (Run A 2026-05-14) and `timeout[n=0,p=0,c=0,o=38]` (2026-05-20). Every timeout falls into `other`; the histogram tells us nothing.

**Root cause.** `classifyTimeoutState` at `src/SortExecutor.lua:154-169` decides one of `"none"`/`"partial"`/`"complete"`/`"other"`. Two diagnostically distinct cases both fall through to `"other"`:

- `srcHasExpected && dstHasExpected && !cursorHeld` — the canonical same-item-stuck-merge / singleton-chain pattern. Op was a no-op because dst already held the item.
- `srcHasExpected && dstEmpty && !cursorHeld` — server-rejected the pickup before drop landed.

**Why the bucket split alone isn't enough.** The timeout handler at line 631 falls through and advances `state.opIndex` regardless of class. For the singleton-chain case, advancing past a refused op is exactly what compounds into the chain failure. B1 must therefore split the bucket AND add an abort-on-repeated-refusal counter: when N consecutive timeouts fall into `"merge-noop"` or `"server-rejected"` on the same itemID, finish() with a specific reason rather than continue.

**Disambiguation requirement.** A `[merge-noop]` is a *real success* if the planner intended a merge into the same item (dst was supposed to gain the count). It's a *failure* if the planner intended a move into an empty slot. The classifier therefore needs op intent (`op.plannerDstAt`) to differentiate. Without this, B1 mis-labels real merges as no-ops.

### B2. Late-poll dominance *(executor; medium)*

**Symptom.** Run B 2026-05-14: 64/64 ops confirmed via the 4.0 s `MOVE_CONFIRM_TIMEOUT` `[late-poll]` floor. None used the `[sync]` or `[async]` fast paths. Run A op 1 hit the fast path in 0.8 s, so the failure is state-dependent rather than wholesale event loss. Same pattern on 2026-05-20 (ops 33-94).

**Root cause hypothesis.** In retail, `GUILDBANKBAGSLOTS_CHANGED` fires for both halves of a `PickupGuildBankItem` pair:

- First event (pickup): src empty client-side, cursor held → handler at `src/SortExecutor.lua:702` gates out on `cursorHeld`.
- Second event (drop): cursor empty, dst should have the item, src should be drained → should advance.

The handler keeps emitting `no-op suspected [async]` lines during the gap, meaning the second event IS firing but the advance predicates are rejecting. The most plausible reason: when the second event fires, the slot API reads return either the pre-drop state for dst (`slotHasAtLeast` fails) or the pre-drop state for src (`srcDrainedAsExpected` fails) due to client-side propagation lag. By 4.0 s later, propagation has completed and the late-poll branch advances.

The synchronous post-Pickup check at `src/SortExecutor.lua:539-567` runs immediately after the two Pickup calls; in retail this almost never advances because the server hasn't even started processing yet.

**Cost.** `MOVE_CONFIRM_TIMEOUT = 4.0` × 64 ops = 256 s per sort run, against a server that probably processed each op in well under a second.

**Fix shape (committed).** Interim polling cascade between event-time and the 4.0 s timeout floor. Poll the advance predicates at 0.25, 0.5, 1.0, 2.0 s. Advance on first success via new `[interim-poll]` tag. Keep the existing `[late-poll]` 4.0 s floor as backstop. Each poll callback checks `state.opIndex == myOpIndex && state.waiting` to short-circuit if a replan rewound state in the meantime.

**Mock isolation strategy.** The sync mock fires `GUILDBANKBAGSLOTS_CHANGED` synchronously inside `PickupGuildBankItem`, so existing tests advance on the sync path before any interim-poll C_Timer fires. To exercise the interim-poll branch in tests, add a `MockWoW.deferredBankEvents = true` mode that queues events for explicit `MockWoW.fireQueuedBankEvent()` instead of firing sync — mirroring the v0.32.5 pre-warm `Item:ContinueOnItemLoad` override pattern. Default stays sync; opt-in for the new tests.

### B3. Misleading projection-vs-live audit lines *(executor; small)*

**Symptom.** 2026-05-14 Run A on Flawless Quick Garnet at T6/S17: `planner expected: src x6, observed: src x7`. 2026-05-20 ops on Phoenix Oil: `planner expected: src x10, dst x15` vs `observed: src x15, dst x15`. The planner's `applyOpToState` mutates working state at plan-emit time without a rollback path, so when an executor op no-ops, the planner's frozen `plannerSrcAt` projection drifts by one or more from live state for every later op in the chain. The replan path already recovers; the misleading audit lines are the only visible damage.

**Target line range.** `src/SortExecutor.lua:629-647` — the timeout-path audit block. (The pre-check audit at lines 447-499 already prints live `describeSlot()` first, so it does not need to change.)

**Fix shape.** Rewrite the timeout-path audit so live observed values are the primary line; planner projection is a secondary `(planner projected: src ...)` line only when divergent. Add a `state.diag.projectionDrifts` counter, surfaced in the `finish()` summary line.

### B4. Singleton-chain emit *(planner; largest scope; split into B4a + B4b)*

**Symptom.** Run A 2026-05-14 ops 28-32 (during one replan) emit Gateway Control Shard x1 chain `T6/S6 → S5 → S4 → S3 → S2 → S1`. Item max stack 1. Each move server-refused. Same shape on 2026-05-20 ops 6-7.

**Why the hypothesis is still soft.** This looks like a 6-cycle permutation that Phase 2's `pivotBreakLoop` (`src/SortPlanner.lua:808-886`) should have detected and broken with a pivot. Either Phase 2 didn't classify these as a cycle, or it did but emitted them directly because each individual `canExecute` returned true. We need an actual Phase 2 trace from a reproducing sort before we can pick a fix shape responsibly.

**Decision: split into two milestones.**

- **B4a — instrument only.** Add Phase 2 audit lines tagged `sort plan Phase 2:` recording cycle detection events (cycle members, pivot chosen, refused-emit reasons). No behavior change. Ships in this PR. The next in-game sort that hits a singleton-chain will produce the trace.
- **B4b — diagnose-and-fix.** Deferred to a separate session after a real Phase 2 trace is captured. Three candidate fix shapes remain open (planner-side forced pivot for max-stack-1, executor-side same-item-chain abort, planner-side cycle-detection enhancement); pick after diagnosis. Out of this PR.

### B5. Replan-time scan-vs-server race *(deferred)*

2026-05-20 replan 2 showed `expected src Phoenix Oil x15, got empty` after the `StartFullScan → wait → PlanSort` sequence at `src/SortExecutor.lua:382-410`. The scan read a slot mid-server-mutation. This is a real bug, but it's separate from the in-sort planner desync (B3) and not a regression on existing behavior (the replan loop still recovers via subsequent rescans). Tracked as a follow-up; not in this PR.

## Test coverage gaps

Surveyed in detail by an Explore agent. The mock infrastructure correctly models cursor-bounce on refused merges. Missing coverage (each folded into the relevant milestone below, not optional per `feedback_test_scope_no_minimum.md`):

- No test produces `timeoutByClass.other > 0` (B1)
- No test for foreign-activity branch with `state.waiting = nil` (B2)
- No test for planner-predicted vs server-refused divergence (B3)
- No test for max-stack-1 multi-destination chain shape (B4a, instrumentation only)
- No test for split into same-tab partial that's already at exactly `perSlot` (also B2; same fix scope)

## Cross-cutting risks

1. **`INTER_MOVE_GAP = 0.3 s` may be too tight for retail.** Phase C (`0.3 s → 0.1 s`) is blocked by Phase B. After interim-poll advance specifically, use `0.5 s` gap (not the default `0.3 s`) to give the server breathing room. Worth instrumenting per-op server-side latency before any Phase C change.
2. **`srcDrainedAsExpected` is load-bearing.** The v0.30.5 fix (`project_wow_pickup_optimism.md`) prevents same-item-full no-op false-positives. B2's interim polling does NOT loosen this predicate — it just calls the same predicates more often. Preserve.
3. **Replan amplification.** Interim polling makes the executor advance earlier on success but ALSO classify failures earlier. If a B1 abort-on-repeated-refusal triggers before replan would have recovered, we surface failures earlier. Net behavior should be acceptable (faster honest failures beat slow false successes), but worth measuring.
4. **`applyOpToState` assertions are protective.** The `dst occupied by wrong item` assert at `src/SortPlanner.lua:118` has caught planner bugs before. B4a is instrumentation-only and does not touch these; B4b must not bypass them.
5. **Concurrency with the v0.32.5 pre-warm phase.** Pre-warm runs before `step()`; cancel and bank-close during pre-warm route through `finish()`. B2's interim-poll cascade must verify the pre-warm-to-step handoff still works — pre-warm test fixtures should exercise interim polling alongside the existing pre-warm paths.
6. **Bucket-name backwards-compat.** `state.timeoutByClass` is initialized at line 912 as `{ none = 0, partial = 0, complete = 0, other = 0 }` and the finish() audit line at lines 339-347 prints `timeout[n=%d,p=%d,c=%d,o=%d]`. Adding `merge-noop` and `server-rejected` requires extending BOTH the init and the format string. Any external consumer of the audit line (none currently; future `docs/PLAN-audit-log-upload.md` would consume it) needs to handle the new schema.
7. **Specs that string-match audit lines.** `spec/sortexecutor_spec.lua` greps `GBL:GetLog("sort")` for substrings like `"server reversion suspected"` and `"Sort pre-warm:"`. B1 and B3 audit-line changes might affect these. **Pre-PR sweep**: `grep -rn "timeoutByClass\|timeout\\[\|:find(\"Sort" spec/ UI/ src/` before merging each milestone.
8. **`finish()` summary line consumers.** The `timeout[...]` format is part of the slash-command output (`/gbl sortlog`). `UI/SortView.lua` consumes the `GBL_SORT_PROGRESS` message rather than parsing this line, but verify in the pre-PR sweep.

## Out-of-scope reminders

- Phase C (`INTER_MOVE_GAP` 0.3 s → 0.1 s) — blocked by B2. Do not touch the gap before late-poll dominance is resolved.
- M-sort-3 (Stock + bag restock) — feature work, not hardening.
- M-sort-4 (Sync integration + polish) — feature work, not hardening.
- Layout refresh flicker — UI polish, not hardening.
- B4b (singleton-chain fix) — deferred after B4a instrumentation captures a real trace.
- B5 (replan-time scan race) — deferred to a follow-up.

## Milestones

Five commits on `layout-sort` (one per milestone plus a stamp commit). Branch PRs to `main` as one batch.

### Commit 1 — B1: Split the `[other]` timeout bucket and abort on repeated refusal

- `src/SortExecutor.lua`:
  - Extend `classifyTimeoutState` (line 154) to disambiguate using `op.plannerDstAt`:
    - `"merge-noop"` for `srcHasExpected && dstHasExpected && !cursorHeld` when `plannerDstAt` was empty (the move was supposed to land into an empty slot but dst already had the item — a real failure).
    - `"server-rejected"` for `srcHasExpected && dstEmpty && !cursorHeld`.
    - `"other"` residual.
  - Extend `state.timeoutByClass` init (line 912) with the two new keys.
  - Extend `finish()` summary format (line 339-347) to include them.
  - Add `state.consecutiveRefusedByItem[itemID]` counter; increment on `"merge-noop"` or `"server-rejected"` timeout; reset on any other class or any success. On count >= 3, `finish(false, "repeated server refusal on item " .. itemID)` rather than fall-through to `step()`.
- `spec/sortexecutor_spec.lua`: produce each new bucket via deterministic mock setup; assert counters increment; assert 3-consecutive-refusals on same itemID triggers early abort with the expected `result.reason`.
- Run `bash run_tests.sh --verbose` and `--lint`. Pre-PR sweep for audit-line string-matchers.

### Commit 2 — B2: Interim polling + deferred-event mock mode

- `src/SortExecutor.lua`:
  - After the synchronous post-Pickup check (around line 539-567), schedule a cascade of `C_Timer.After` polls at 0.25, 0.5, 1.0, 2.0 s.
  - Each poll callback: if `state.opIndex == myOpIndex && state.waiting && state.waiting.opIndex == myOpIndex`, run the same advance predicates as `[late-poll]`; on success, advance with audit tag `[interim-poll]` and set `state.gapUntil = GetTime() + 0.5` (not the default `INTER_MOVE_GAP`).
  - On any advance: cancel any remaining poll timers tied to this op. (Use a `state.waiting.pollTimers` array.)
- `spec/mock_wow.lua`:
  - Add `MockWoW.deferredBankEvents` flag (default false). When true, `fireBankEvent()` queues into `MockWoW.queuedBankEvents` instead of firing sync.
  - Add `MockWoW.fireQueuedBankEvent()` helper that pops + fires one event.
- `spec/sortexecutor_spec.lua`:
  - With deferred events, sync path does not advance; interim poll at 0.25 s sees advance predicates pass → advance via `[interim-poll]`.
  - With deferred events AND failing predicates (foreign change at dst), interim polls all reject; late-poll at 4.0 s catches up.
  - Replan triggered mid-interim-poll cascade cancels pending poll timers cleanly (no spurious advance).
  - Foreign event firing with `state.waiting = nil`: handler hits the replan branch (closes the existing coverage gap).
  - Split into same-tab partial at `perSlot`: planner emits the op, executor refuses, B1's repeated-refusal counter trips on the 3rd attempt.
- Run tests + lint. Pre-PR sweep.

### Commit 3 — B3: Clarify timeout-path audit lines

- `src/SortExecutor.lua` lines 629-647:
  - Print live values as primary: `observed: src ..., dst ..., cursor ...`
  - Print planner projection as secondary only when divergent: `(planner projected: src ..., dst ...)`.
  - Add `state.diag.projectionDrifts` counter; increment when divergent.
  - Surface `projectionDrifts` in the `finish()` summary line.
- `spec/sortexecutor_spec.lua`: regression test that simulates an executor no-op then issues the next op; assert audit line uses live values, secondary projection line appears, counter increments.
- Run tests + lint. Pre-PR sweep.

### Commit 4 — B4a: Phase 2 instrumentation

- `src/SortPlanner.lua` Phase 2 (`pivotBreakLoop` line 808, `greedyDrain` line 754, `emitAssignment` line 293):
  - Add `sort plan Phase 2:` audit lines via `GBL:SortInfo` recording: cycle detected (members), pivot chosen (slot or "no-pivot abort"), refused-emit reasons (which `canExecute` predicate failed). No behavior change.
- `spec/sortplanner_spec.lua`: 6-slot permutation of a max-stack-1 item; assert Phase 2 audit lines fire with the expected cycle members. Also add multi-destination chain shape test (the singleton-chain gap from the survey).
- Run tests + lint.

### Commit 5 — Stamp v0.32.6 at PR-open

- `VERSION`: 0.32.5 → 0.32.6.
- `GuildBankLedger.toc` `## Version:`: 0.32.5 → 0.32.6.
- `src/Core.lua` `local VERSION`: 0.32.5 → 0.32.6. `DEV_BUILD` stays `nil`.
- `CLAUDE.md` "Current:" line: 0.32.5 → 0.32.6.
- `CHANGELOG.md`: new `## [0.32.6] - <date>` block with **Changed** (timeout-class taxonomy, audit-line format) and **Fixed** (interim-poll cascade reduces wall-clock sort time when retail event timing drifts; abort on repeated server refusal stops cascading no-ops) and **Added** (Phase 2 instrumentation audit lines).
- `UI/ChangelogView.lua` `CHANGELOG_DATA`: matching v0.32.6 entry.

### Verification (in-game, post-implementation)

Two consecutive sort runs on the same guild bank (Tichondrius), mirroring the 2026-05-14 and 2026-05-20 capture pattern. Two runs catches state-dependent regressions that a single run can miss (Run B in the 2026-05-14 log behaved differently from Run A because the first run partially-recovered the bank). Cross-guild reproduction is out of scope for a patch release.

1. Reproduce the bank state similar to the existing captures (7 tabs, Flawless gems on tab 6, multiple Phoenix Oil partial stacks, at least one max-stack-1 item).
2. Run sort; capture `/gbl sortlog`. Run again; capture again.
3. Compare both against in-repo logs:
   - `timeout[n=*,p=*,c=*,m=*,r=*,o=*]` shows non-zero entries in the new buckets when timeouts occur (B1 working).
   - Majority of per-op confirmations via `[interim-poll]`; `[late-poll]` only as backstop (B2 working). Wall-clock time should drop significantly from the ~4.5 s/op average in the existing captures.
   - No `expected: src xN, observed: src xN+1` audit lines on healthy ops; secondary `(planner projected: ...)` lines appear only when divergent (B3 working).
   - Phase 2 audit lines fire for any cycle-shaped emit (B4a working).
4. Promote BOTH captured logs to `docs/sort-logs/<date>-phase-b-verification.md` as a single doc with both runs.

### Branch and PR

- Branch: `layout-sort` (already exists; this is its area).
- During-work commits: 4 milestone commits (B1, B2, B3, B4a). No version-artifact touches mid-stack (project's bundle-and-PR carve-out).
- Stamp commit at PR-open (Commit 5).
- PR title: `Phase B sort hardening: bucket split, interim polling, audit clarity, Phase 2 instrumentation (v0.32.6)`
- PR body links to this plan doc and the two in-repo sort logs.

## Deferred-item tracking

B4b (singleton-chain fix) and B5 (replan-time scan race) are intentionally deferred from this PR. Both get auto-memory entries so future sessions surface them when opening the project:

- `~/.claude/projects/.../memory/project_singleton_chain_pending_diagnosis.md` — B4b context. Notes that B4a's instrumentation must run in a production sort that hits the chain before fix design starts. Cross-links the two in-repo sort logs.
- `~/.claude/projects/.../memory/project_replan_scan_race.md` — B5 context. Notes the 2026-05-20 replan 2 evidence (`expected src Phoenix Oil x15, got empty`) and the scan-vs-server race location at `src/SortExecutor.lua:382-410`.

Both memory entries land in the same commit as the plan doc on `layout-sort` so the tracking is durable from day one.
