# 2026-05-20: Pre-warm success + late-poll-storm recurrence

In-game sort log captured during Phase A verification of the
`hotfix/sort-crafted-quality-prewarm` branch. Two purposes:

1. Confirm Phase A objective (no Wow.exe crash on tabs containing TWW
   crafted-quality reagents).
2. Capture fresh Phase B starting data — the late-poll storm pattern
   first documented on 2026-05-14 reproduces under the same conditions.

## Setup

- Build: branch `hotfix/sort-crafted-quality-prewarm` rebased onto
  `origin/main` at `183cdce` (post-v0.32.4).
- Guild: Tichondrius, 7 tabs, 502 occupied slots.
- Pre-condition: WoW Retail 12.0.5 build 67602. Same client build as
  the 2026-05-20 crash report. Tab 6 contains the full Flawless gem
  set (`Professions-ChatIcon-Quality-12-Tier2` atlas) plus phoenix oil,
  potions, enchant scrolls, plans.

## Phase A verdict: success

```
Sort pre-warm: 49 items, 49 loaded in 0.0s (complete)
Sort: starting execution of 106 ops
```

```
Sort pre-warm: 1 items, 1 loaded in 0.0s (complete)
Sort: starting execution of 1 ops
```

- Pre-warm audit lines fire as designed in both runs.
- No Wow.exe crash on either run despite the plan touching every
  Flawless gem in tab 6 (`Flawless Quick Amethyst it:240900`,
  `Flawless Deadly Garnet it:240904`, `Flawless Deadly Lapis it:240914`,
  `Flawless Versatile Garnet it:240910`, ...).
- Warning banner appeared in Sort tab preview when the plan was loaded.

`Item:CreateFromItemLink:ContinueOnItemLoad` pre-warm is sufficient
to prevent the access violation in `GetItemReagentQualityInfo` for
the items this guild owns. Whether it generalizes to every
crafted-quality item across every quality tier is unverified; the
banner remains the load-bearing user protection.

## Phase B observations (next-session starting data)

Run 1 (12:26:39 → 12:34:13 = 453.7 s wall, 94 ops, 62 done, 38 failed,
2 replans). Two distinct failure modes coexist on this run.

### Mode 1: split-into-existing-stack refused at server

Ops 1–32 timed out as `[other]`. The observed post-state shows
src unchanged AND dst already holds the expected item — i.e. the
server refused the split-into-an-existing-partial-stack, the cursor
bounced back to src, and the WoW client never raised
`GUILDBANKBAGSLOTS_CHANGED` for a state change because there was
no state change.

Representative entry (op 1):

```
[12:26:43] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[12:26:43]   op 1 was: split T6/S53 -> T6/S45 Thalassian Phoenix Oil (it:243733) x5
[12:26:43]   observed: src x15, dst x15, cursor empty
[12:26:43]   planner expected: src x15, dst x15
```

Note the planner's expected pre-op state matches observed state exactly:
the planner thinks src is 15 (post a hypothetical earlier split) and
dst is 15, and intends to add 5 more from src into dst. The server
refused. Repeated `no-op suspected [sync]/[async]` warnings precede
each timeout, confirming the v0.30.5 `srcDrainedAsExpected` check
correctly identified each rejected attempt.

Why the server refused: unknown. Candidates: max-stack guard (the
planner's `maxStackByItem` cache disagrees with the server's view),
identical-stack-merge refusal, server-side rate limiting on rapid
split ops to the same source slot. Phase B should isolate.

### Mode 2: late-poll dominance

Ops 33–94 all confirmed via `[late-poll]` at exactly the 4.0 s
`MOVE_CONFIRM_TIMEOUT` floor. None of the `[sync]` or `[async]` fast
paths advanced state on these ops, despite each move actually
succeeding (verified via `src=empty, dst=...` in each audit line).

Identical pattern to `project_sort_log_2026_05_14_late_poll_storm.md`:
something about the executor's confirmation-event handling state
prevents the fast-path advance once an op has been in flight long
enough. 4.0 s/op × 62 late-poll ops = 248 s of wall time spent
waiting for the timeout floor on ops that actually succeeded.

### Replans

Two replans on the same run:

```
[12:27:16] Sort: replan 1/5 (foreign activity (unexpected event))
[12:27:21] Sort op 1/99 pre-check fail src T6/S53: expected
            Thalassian Phoenix Oil (it:243733) x>=5, got empty
[12:27:21]   planner expected src at emit: Thalassian Phoenix Oil x15
[12:27:21] Sort: replan 2/5 (src mismatch at op 1)
```

Replan 1 is the Mode-1 cascade — after a no-op cluster a stray
`GUILDBANKBAGSLOTS_CHANGED` arrives and the no-in-flight-op branch
in `_SortExecutor_OnSlotsChanged` reads it as foreign activity.

Replan 2 is interesting: after the rescan, the planner's view of
T6/S53 says `Phoenix Oil x15` but the bank shows `empty`. The scan
must have caught the slot mid-mutation, or the post-replan scan
fired before the previous op's server-side update settled.

### Singleton-chain trace (Gateway Control Shard, max stack 1)

Same singleton-chain emit pattern from 2026-05-14:

```
[12:27:16] [WARN] Sort op 6 no-op suspected [sync]: move T6/S1->T1/S29
            Gateway Control Shard (it:188152) x1
            (dst already held expected item; src unchanged)
[12:27:20] [WARN] Sort op 7 no-op suspected [sync]: move T6/S2->T1/S30
            Gateway Control Shard (it:188152) x1
            (dst already held expected item; src unchanged)
```

Two consecutive ops on a max-stack-1 item, both rejected. Planner
emitted a chain that depended on the previous move completing.
When the first move was server-refused (Mode 1 again), the planner's
working state desync'd and the second move targeted an already-
occupied slot.

## Run 2 (control)

Identical executor on a 1-op plan completed in 0.6 s via the `[sync]`
fast path:

```
Sort pre-warm: 1 items, 1 loaded in 0.0s (complete)
Sort op 1 done: split T6/S35->T6/S34 Silvermoon Health Potion
            (it:241305) x20 (0.6s) src=x40 dst=x200
Sort: complete in 0.6s - 1 ops (1 done, 0 failed, 0 replans, 0 reclass)
```

Note that the dst was already `x200` (presumably max stack) and the
split still succeeded — so the "dst at max stack refuses merge"
candidate from Mode 1 is NOT a sufficient explanation. Run-1 Mode-1
failures were on x15 dst slots well under max.

Mode-1 reproduction needs more isolated data: split a partial stack
into another partial stack of the same item in the same tab, observe
server response. Worth its own controlled exhibition tab in Phase B.

## Phase B candidate hypotheses

Listed for the Phase B session to evaluate. Not committed; this is
starting data, not a plan.

1. **Mode 1 (server-refused splits) is split-rate-limited.** The
   server may throttle consecutive split ops on the same source slot
   below some interval that's faster than `INTER_MOVE_GAP=0.3`s but
   slower than the `MOVE_CONFIRM_TIMEOUT=4.0`s gap. Test: bench a
   solo split with a 1.0 s gap.
2. **Mode 2 (late-poll dominance) is caused by Mode 1 contamination.**
   After Mode-1 cascades on the same tab, state.waiting accumulates
   in a way that prevents the cursor-empty gate in
   `_SortExecutor_OnSlotsChanged` from firing on subsequent (genuine)
   move confirmations. Test: clean exhibition tab, no Mode-1 setup,
   measure ratio of `[sync]` vs `[late-poll]` resolutions.
3. **Replan 2's "src empty" mismatch is the scanner racing the
   server.** After a replan-triggered StartFullScan, the scan reads
   slot state before the server has finished propagating the prior
   op's effect. Test: instrument scan completion time relative to
   the last successful op's audit timestamp.
4. **Singleton-chain emit is a planner-state-desync amplifier.** Once
   one op no-ops without rollback, the planner's working state
   diverges and emits a chain that compounds.

## Numbers for the record

- Pre-warm: 0.0 s for 49 items, 0.0 s for 1 item. Negligible overhead.
- Banner: rendered correctly on a plan touching crafted-quality items.
- Run 1: 7.5 min wall, 94 ops, 62 done (66%), 38 failed (40%), avg
  4.54 s/op. Bank ended in correct shape; no items destroyed.
- Run 2: 0.6 s wall, 1 op, 1 done. Fast path worked.
- No `Wow.exe` access violation observed.
