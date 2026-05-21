# 2026-05-21: Split deposits succeed but source-drain confirmation lags

In-game sort logs captured on the `layout-sort` branch at v0.32.8 (PR #30). Two
captures, before and after a classifier fix. Together they overturn an initial
cold-snapshot theory: the sort's splits actually succeed, but the executor's
confirmation predicate times out before the source-stack drain surfaces in the
client, so it false-flags successful splits as refusals.

## Capture A (pre-classifier-fix): 5-op storm bucketed `[other]`

A 5-op plan, every op a `split` from overflow (T6) into a display slot the planner
projected empty, observed as already holding `x1`, src unchanged. All timed out:

```
Sort: complete in 21.3s - 5 ops (0 done, 5 failed, 1 replans, 0 reclass) timeout[s=0,p=0,c=0,m=0,o=5] drifts=5
```

Two things were initially read from this:
1. The timeouts all fell into `[other]`. Correct cause: `classifyTimeoutState`
   prefix-matched `"it:<id> x"` against the `describeSlot` string, but in-game
   `describeSlot` carries the resolved item name (`"Flask (it:NNN) xN"`), so the
   match never fired and every non-empty timeout collapsed to `other`. The
   merge-noop / server-rejected buckets and the 3-strike abort were dead outside
   the no-item-name test env. **Fixed**: classify from structured live-slot
   snapshots (`snapshotLiveSlot`), not the display string.
2. The slot count jumped `493 -> 498` after a warm rescan and the next plan showed
   `0 ops`. This was read as a cold snapshot (the scan missing occupied slots).
   **Capture B shows that read was wrong.** The +5 was the five splits actually
   landing on the server; `0 ops` after meant the layout was now satisfied.

## Capture B (post-classifier-fix): the decisive evidence

With the classifier fixed, timeouts bucket as `merge-noop` and the abort fires:

```
Sort: aborted (repeated server refusal on item 240890 (3 consecutive merge-noop)) in 43.4s - 230 ops (0 done, 5 failed) timeout[s=0,p=0,c=0,m=5,o=0] drifts=5
```

Run three times in a row (manual re-runs), each aborting after the first item to
hit 3 consecutive timeouts. The per-tab breakdown (new in this PR) and the
cross-run numbers prove the splits succeed:

| Run | ops before abort | T4 occupied before -> after |
|---|---|---|
| 1 | 3 (S1,S2,S3) | 0 -> 3 |
| 2 | 5 (S4..S8) | 3 -> 8 |
| 3 | 5 (S9..S13) | 8 -> 13 |

- Every op that "failed" left a filled destination slot behind; the planner
  advances monotonically S1 -> S13. A genuine no-op into an already-occupied slot
  would not fill the slot, and the planner would re-target it, not advance.
- Source stacks drain across runs: Flawless Deadly Peridot at T6/S9 reads x12 in
  run 2, then x9 in run 3 (run 2 did exactly 3 splits on it); Flawless Quick
  Peridot reads x10 then x7 (run 1 did 3). If the splits were phantom, the source
  would never drain.

So: the splits land. Within a run, the destination shows the deposit (the op fired
a `GUILDBANKBAGSLOTS_CHANGED`), but the source count still reads full at the 4s
confirmation window. The `srcDrainedAsExpected` predicate therefore (correctly, by
its own rule) calls each a no-op. A guild-bank split appears to confirm its deposit
and its source-decrement as two separate server updates; the deposit lands inside
the 4s window, the drain after it.

## Why the src-drain rule exists, and why it backfires here

`srcDrainedAsExpected` is the authoritative discriminator (see
`project_wow_pickup_optimism`) because the client optimistically shows a
destination merge that can later bounce, so dst-has-item alone gives false
positives. But that bounce risk is specific to merging into an already-occupied
same-item slot. A split into an EMPTY slot has nothing to bounce back to, so the
deposit is reliable and the lagging source-drain only produces false negatives.

## Shipped in this PR (Phase 1, v0.32.8)

- Classifier reads structured slot state (Capture A finding).
- Scan diagnostics: per-tab `completedVia` / `lockedSkips`, and the per-tab
  occupied breakdown on the plan line (these are what made Capture B legible).
- New `drain-pending` timeout class (reported as `dp=N`): a timeout where the
  destination was empty/other pre-op and now holds the item but the source has not
  drained. Distinguished from `merge-noop` (dst already held the item pre-op) by
  the already-captured `dstPreOp` snapshot. Excluded from the 3-strike abort, so a
  real sort runs to completion instead of bailing on its own progress, and the
  audit records the deposit-landed-source-pending state per op. This both lets us
  confirm the splits succeed across a full run and is the precursor to the proper
  fix.

## Next (Phase 2, after a confirming capture on this build)

Recognize a split into an empty (or different-item) slot as a success on the
deposit (the `GUILDBANKBAGSLOTS_CHANGED` showing dst filled from empty), without
waiting on the lagging source-drain. Keep requiring source-drain only for merges
into an existing same-item stack. That confirms each op in well under a second
instead of timing out, so the sort completes in one fast pass with no false abort.
The cold-snapshot freshness fix is not needed; the scan is accurate.
