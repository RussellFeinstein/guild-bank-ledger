# 2026-09-18: seventeen refusals across two clean runs, every one of which the Sort tab reported as zero

Two back-to-back runs with bags on, taken while building #162. Both converged
to nothing remaining, and between them they refused seventeen ops while
`cursorStuck` read zero in both. That pair of figures is the whole finding:
until this branch the Sort tab's failure counter read `cursorStuck`, so it
would have shown `0 failed` through both runs.

The lines were read out of the live ring with `/gbl sortlog` and pasted in
session, not out of the saved store, so the by-index rule for
`GuildBankLedgerAuditDB` does not apply here; the order below is the ring's
own, oldest first. Neither run stamps its version, and nothing in these lines
would differ between v0.39.9 and this branch: #162 changed the
`GBL_SORT_PROGRESS` message and not the sort log, which is exactly what makes
this capture evidence about the input and silent about the output.

## What was run

| | Run 1 | Run 2 |
|---|---|---|
| Started | 21:04:17 | 21:06:50 |
| Bags | on | on |
| Planned ops | 55 | 57 |
| Passes | 3 (55, 37, 2) | 2 (57, 47) |
| Ended | complete, 0 remaining | complete, 0 remaining |
| Ops issued | 82 | 99 |
| Ops refused | 12 | 5 |
| Cursor probe | `GetCursorInfo [item:77], CursorHasItem true=0 false=77` | `GetCursorInfo [item:88], CursorHasItem true=0 false=88` |

## The figures

Run 1:

```
[21:04:17] Sort: starting execution of 55 ops, cadence 1.0s (ping home 78ms / world 79ms) bags=on
[21:06:19] Sort: complete in 121.5s - 3 passes, 82 ops issued, 0 remaining, avg 1.48s/op (cursorStuck=0 stalls=0 rescans=5 skipped=12) [empty:11 short-stack:1]
[21:06:19] Sort bags: 5 deposit(s) issued, 2 skipped [empty:2], still in bags: 0
[21:06:19] Sort lift probe: GetCursorInfo [item:77], CursorHasItem true=0 false=77
[21:06:19] Sort hitch summary: 2 hitches, max 167ms [<=150ms:1 <=250ms:1]
```

Run 2:

```
[21:06:50] Sort: starting execution of 57 ops, cadence 1.0s (ping home 79ms / world 77ms) bags=on
[21:08:53] Sort: complete in 122.8s - 2 passes, 99 ops issued, 0 remaining, avg 1.24s/op (cursorStuck=0 stalls=0 rescans=6 skipped=5) [empty:3 short-stack:2]
[21:08:53] Sort bags: 11 deposit(s) issued, 1 skipped [short-stack:1], still in bags: 0
[21:08:53] Sort lift probe: GetCursorInfo [item:88], CursorHasItem true=0 false=88
[21:08:53] Sort hitch summary: 4 hitches, max 164ms [<=150ms:2 <=250ms:2]
```

Counted from the WARN lines rather than read off the summary, in both
directions:

| Measure | Run 1 | Run 2 |
|---|---|---|
| Op slots across all passes | 55 + 37 + 2 = 94 | 57 + 47 = 104 |
| Issued | 82 | 99 |
| WARN refusal lines counted | 12 | 5 |
| Slots minus refusals | 94 - 12 = 82 | 104 - 5 = 99 |
| `empty` | 11 (pass 1 ops 4-9, 19, 20, 50, 52, 53) | 3 (pass 1 ops 12, 24, 48) |
| `short-stack` | 1 (pass 1 op 55) | 2 (pass 1 ops 1, 36) |
| Bag-sourced refusals | 2 (ops 19, 20) | 1 (op 1) |
| `cursorStuck` | 0 | 0 |
| Refusals in pass 2 or later | 0 | 0 |

Every refusal in both runs names one item, `it:271883`, which is the stack
that was moved between Preview and Execute on purpose to produce them. A
future reader should not take seventeen refusals as a systemic read failure:
they are one manipulated item plus the chain behind it.

Every `short-stack` carried its count as a detail, from both source kinds:

```
[21:05:12] [WARN] Sort op 55/55 skipped: T6/94 short-stack (have 82), wanted 164 x Concentrated Silvermoon Health Potion (it:271883)
[21:06:50] [WARN] Sort op 1/57 skipped: Bag2/11 short-stack (have 100), wanted 200 x Concentrated Silvermoon Health Potion (it:271883)
[21:07:26] [WARN] Sort op 36/57 skipped: T6/87 short-stack (have 38), wanted 200 x Concentrated Silvermoon Health Potion (it:271883)
```

## What this accounts for

- **The counter defect #162 fixes, with numbers.** On the code this branch
  replaces, the Sort tab's live line and its completion line both read
  `payload.failed = state.cursorStuck`. That was 0 in both runs while 12 and
  5 ops were refused, so the tab would have reported `0 failed` through
  seventeen refusals, and the chat line agreed with it because the residual
  was also 0. Nothing on screen said anything had been declined. The
  re-audit found this by reading the field; this is the same finding arriving
  as a measurement.
- **The refusal vocabulary and its details (#169, v0.39.5 to v0.39.7),
  exercised in volume.** Seventeen refusals across both source kinds and two
  reasons, with the count carried as a detail on every `short-stack`. That
  pair of fields is precisely what #162 renders onto a row, so the input to
  the new markers is verified live even though their output is not.
- **`state.skippedOps` and the bag counters stay consistent.** The run total
  sits at or above the bag figure in both runs (12 against 2, 5 against 1),
  which is the property the separate counters exist to keep.
- **The cursor predicate, for a third capture (#171).** 165 more lifts, and
  `CursorHasItem` was blind to every one of them while `GetCursorInfo` saw
  them all. The guard never blew its fuse, because none of the seventeen
  refusals came from the guard: all were pre-checks inside `liftFromBank` and
  `liftFromBag`, and the probe line carries no ` guard=disabled`.
- **#165 item 1, arithmetically, again.** `rescans=5` at 82 ops issued and
  `rescans=6` at 99, which is `floor(issued / 15)` exactly in both runs. The
  figure is still counting the sort's own transaction-log flushes.
- **Convergence absorbing a refusal chain.** Run 1's refused split into
  T6/91 at op 19 left that slot empty, so op 50's `move T6/91->T6/86` found
  nothing and every Phase 4 shuffle chained through those slots followed. One
  manipulated stack produced twelve refusals and the run still finished at 0
  remaining in three passes, with no refusal at all in passes 2 or 3.

## The limit worth stating

**This capture says nothing about what #162 changed.** The sort log is a
separate renderer that this PR does not touch, and the issue's entire subject
is what the move list draws. The markers, the reason on the row, and the
`N issued, M refused` line are all unverified by anything here. That still
needs someone to look at the tab, which is the whole reason the plan called
for an in-game run rather than a capture.

Nor does it exercise the `empty` and `short-stack` pre-checks against a
client that disagrees with the scan. Both runs produced their refusals from a
stack moved by hand between Preview and Execute, which is the reachable case
but not the only one.

## For the reader of the next capture

Read `skipped=N` and its histogram before anything else on a run that moved
less than it planned, and read `cursorStuck` beside it rather than instead of
it: they count unrelated things and only one of them is a failure. Then the
`Sort bags:` line, whose skipped figure must sit at or below the run total.
The probe line is still worth a glance on any run that refused a lot, because
` guard=disabled` there would mean the refusals came from the cursor guard
rather than from the slot pre-checks, and those want different explanations.
