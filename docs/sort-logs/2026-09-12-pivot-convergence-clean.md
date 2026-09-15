# 2026-09-12: the pass-cap stop is gone, and the planner-side fixes account for it

Follow-up capture to `2026-08-27-bags-near-full-overflow.md`, which ended by saying that
if #143 and #138 landed and the pass-cap stop stopped happening, the next file would be
the record of what they fixed. This is that file.

Two sorts on v0.39.3, one with bags off and one with bags on, both against a near-full
bank. Both converged. Nothing in either session reproduces the shape #144 was filed for.

Read out of the live `GuildBankLedgerAuditDB` by session index (sessions 9 and 10), not
by bracketing lines around a key: key order in the SavedVariables is `pairs()` order, so
a session's `dropped` block can sit above its own `startedAt` and a line-bracketed range
picks up the next session's counters.

## What was run

| | Sort A | Sort B |
|---|---|---|
| Started | 00:28:46 | 00:31:45 |
| Bags | off | on |
| Planned | 61 ops | 62 ops |
| Bank at start | 603 of 686 slots | 603 of 686 slots |

Two tabs were at 98 of 98 and three more above 90, so this was not a sparse bank with
room to absorb a bad plan. The sort channel across both sessions holds 531 entries and
every one is INFO: no WARN, no ERROR, and therefore no bag refusal was exercised. The
six refusal reasons still rest entirely on mocks.

## The figures

Both runs finished on their own, in two passes, with nothing left:

```
00:30:10 Sort: complete in 83.6s - 2 passes, 65 ops issued, 0 remaining, avg 1.29s/op (cursorStuck=0 stalls=0 rescans=4)
00:33:07 Sort: complete in 81.2s - 2 passes, 63 ops issued, 0 remaining, avg 1.29s/op (cursorStuck=0 stalls=0 rescans=4)
00:33:07 Sort bags: 37 deposit(s) issued, 0 skipped, still in bags: 0
```

Pass 2 of Sort A was four moves and pass 2 of Sort B was one, each followed by a
zero-op plan, which is convergence rather than a cap:

```
00:29:57 Sort: pass 1 left 4 move(s); re-running
00:30:10 Sort plan: 9.9ms, 0 ops, 3 deficits, 0 unplaced (input: 603 slots / 7 tabs) unviewable:none [T1:59 T2:98 T3:98 T4:95 T5:92 T6:93 T7:68]
00:32:57 Sort: pass 1 left 1 move(s); re-running
00:33:07 Sort plan: 6.5ms, 0 ops, 2 deficits, 0 unplaced (input: 635 slots / 7 tabs) bags:0/74(fill=0,spill=0,stay=0,ignored=27,bound=47,locked=0,nolink=0) unviewable:none [T1:90 T2:98 T3:98 T4:95 T5:92 T6:94 T7:68]
```

Across both v0.39.3 sessions, counted rather than eyeballed:

| Measure | Value |
|---|---|
| Plan lines emitted | 36 |
| Of those reading `0 unplaced` | 36 |
| `phases` lines emitted | 36 |
| Of those reading `abort=0` | 36 |
| Distinct plan signatures | 16 |
| `P2 pivot` values seen | 0 (x21), 1 (x11), 2 (x3), 4 (x1) |

The original #144 capture was `P2 pivot=9(abort=2)` with `2 unplaced`, repeated every
pass until the five-pass cap. Sixteen different plans over two sessions and a bank that
moved from 506 to 635 occupied slots never once produced an abort or an unplaced entry.

The `3 deficits` and `2 deficits` terms are layout shortfalls, not sort failures: the
bank holds less of three items than the templates ask for. They are a restock signal and
say nothing about convergence.

## What this accounts for

The 2026-09-09 comment on #144 named the test and the candidates. Both planner-side ways
of manufacturing the residual were closed before this capture:

- **#146 (v0.39.1)** stopped a full stack topping up a partial, so the planner no longer
  creates the mid-run partial in the first place.
- **#147 (v0.39.2)** made a same-item pair refused for max stack resolve through a pivot
  instead of returning zero ops and two `cycle-no-pivot` entries every pass.
- **#143 (v0.39.2)** stopped Phase 4 shoving aside a stack the plan had already reported
  unplaced.

That comment said a rerun still stopping at the pass cap would point at the two
executor-side candidates this issue lists, the chain scramble under the fire-and-forget
cadence and the replan scan reading slots before the last deposits land. The rerun did
not stop. So the three planner-side fixes account for what #144 recorded, and neither
executor-side candidate is needed to explain anything observed here.

## The limit worth stating

This is an absence of recurrence across sixteen plans and a range of bank states. It is
not the original fixture passing. The 2026-09-12 bank is not the 2026-09-08 bank, and the
per-pass slot dump #144 asked for was never built, so nothing here proves the old shape
could not still be reached by some arrangement neither capture contained. What it does
establish is that the shape does not occur in ordinary use on a near-full bank, which is
the condition under which it was originally hit twice.

If it returns, the discriminator is unchanged and still unbuilt: a per-pass dump of the
slots involved.

## For the reader of the next capture

- `abort=` inside the `phases` line is the term that matters for this class of bug. A
  nonzero value means Phase 2 gave up on a cycle, and every such assignment is recorded
  unplaced, so `abort>0` and `unplaced>0` normally travel together.
- A run that ends with `Sort: complete` converged. A run that ends with `Sort: aborted`
  was interrupted, by a bank close or a cancel, and says nothing about convergence. The
  2026-09-11 session has three aborted runs for that reason and they are not evidence.
- `still in bags: unknown (no replan)` is what an aborted bags run reports. Only a run
  that reached a replan can state the figure.
