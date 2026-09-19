# 2026-09-19: the pre-#145 baseline reads frag=4 extra=2, and every refusal came from a slot the run had written on a tab it was not viewing

Four sort runs on v0.39.14, two with bags on and two with bags off, taken to
give #145 the baseline #181 was built to measure. The last of them converged
to nothing remaining, and its final replan carries the number. The same four
runs refused eight ops between them, and all eight share one shape the
2026-09-18 record named as its unexercised case.

The lines are from session 10 of `GuildBankLedgerAuditDB`, read by index
with `scripts/audit-sessions.lua` after the client logged out (the store
rotated its oldest session out to admit this one). Timestamps are UTC as the
store holds them; the same lines were first read off the live master log in
session, four hours earlier on the client's clock. The sync channel was busy
throughout (a 486-chunk send ran under all four runs) and none of its lines
are quoted, because every one of them names a peer.

## What was run

| | Run A | Run B | Run C | Run D |
|---|---|---|---|---|
| Started | 18:59:42 | 19:04:22 | 19:06:21 | 19:07:00 |
| Bags | on | on | off | off |
| Planned ops | 179 | 23 | 67 | 126 |
| Passes | 3 (179, 50, 2) | 2 (23, 2) | 1, cancelled at op 12 | 2 (126, 44) |
| Ended | 23 remaining | complete, 0 remaining | aborted (cancelled), 56 remaining | complete, 0 remaining |
| Ops issued | 224 | 25 | 11 | 169 |
| Ops refused | 7 | 0 | 0 | 1 |
| Bag deposits | 44 issued, 0 skipped, still in bags 0 | 0 issued | bags off | bags off |
| Cursor probe | `GetCursorInfo [item:180], CursorHasItem true=0 false=180` | `[item:25], true=0 false=25` | `[item:11], true=0 false=11` | `[item:169], true=0 false=169` |

Run A stopped with 23 remaining under the executor's non-decreasing rule:
its third pass planned 2 ops and the replan after it planned 23. Run B is
those 23, run on the same bank a quarter of a minute later, and it finished.
Run C was cancelled by hand after 11 ops to withdraw more stacks before run
D. Between runs B and C, and again before run D, stacks were withdrawn from
display tabs by hand (the bank read 638, then 604, then 601 occupied slots),
so runs C and D refill display demands from overflow, which is what
`P1a assign=34` and `P1a assign=37` on their plan lines are.

## The figures

The line #145 is measured against, run D's final replan, the last plan of a
bags-off run that ended at 0 remaining:

```
[19:10:09] [SORT] [INFO] Sort plan: 8.2ms, 0 ops, 0 deficits, 0 unplaced (input: 631 slots / 7 tabs, locked=0) unviewable:none [T1:91 T2:98 T3:98 T4:95 T5:92 T6:89 T7:68]
[19:10:09] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=0
[19:10:09] [SORT] [INFO]   demands: 474 total (pinned=0, ext-R=423, ext-L=0, first-empty=51)
[19:10:09] [SORT] [INFO]   overflow: items=53 frag=4 partials=53 extra=2 unknown=0
[19:10:09] [SORT] [INFO]   overflow split: Inky Black Potion (it:124640) T6x2 T7x6, Gateway Control Shard (it:188152) T6x8 T7x6, Light's Potential (it:241309) T6x3 T7x2, Thalassian Phoenix Oil (it:243733) T6x12 T7x35
```

The same reading from the bags-on pair, run B's final replan, which also
ended at 0 remaining:

```
[19:05:05] [SORT] [INFO] Sort plan: 13.6ms, 0 ops, 0 deficits, 0 unplaced (input: 638 slots / 7 tabs, locked=0) bags:0/66(stay=0,ignored=17,bound=49,locked=0,nolink=0,fillops=0,spillops=0) unviewable:none [T1:91 T2:98 T3:98 T4:95 T5:92 T6:96 T7:68]
[19:05:05] [SORT] [INFO]   overflow: items=53 frag=5 partials=52 extra=2 unknown=0
[19:05:05] [SORT] [INFO]   overflow split: Inky Black Potion (it:124640) T6x2 T7x6, Auto-Hammer (it:132514) T6x1 T7x16, Gateway Control Shard (it:188152) T6x10 T7x6, Light's Potential (it:241309) T6x4 T7x2, Thalassian Phoenix Oil (it:243733) T6x13 T7x35
```

The run summaries:

```
[18:59:42] [SORT] [INFO] Sort: starting execution of 179 ops, cadence 1.0s (ping home 77ms / world 98ms) bags=on
[19:04:05] [SORT] [INFO] Sort: complete in 262.3s - 3 passes, 224 ops issued, 23 remaining, avg 1.17s/op (cursorStuck=0 stalls=0 flushes=14 skipped=7) [empty:1 short-stack:6]
[19:04:05] [SORT] [INFO] Sort bags: 44 deposit(s) issued, 0 skipped, still in bags: 0
[19:04:05] [SORT] [INFO] Sort hitch summary: 5 hitches, max 2802ms [<=150ms:3 >1000ms:2]
[19:04:22] [SORT] [INFO] Sort: starting execution of 23 ops, cadence 1.0s (ping home 77ms / world 98ms) bags=on
[19:05:05] [SORT] [INFO] Sort: complete in 42.6s - 2 passes, 25 ops issued, 0 remaining, avg 1.70s/op (cursorStuck=0 stalls=0 flushes=1)
[19:06:21] [SORT] [INFO] Sort: starting execution of 67 ops, cadence 1.0s (ping home 78ms / world 77ms) bags=off
[19:06:32] [SORT] [INFO] Sort: aborted (cancelled) in 10.6s - 1 passes, 11 ops issued, 56 remaining, avg 0.97s/op (cursorStuck=0 stalls=0 flushes=0)
[19:07:00] [SORT] [INFO] Sort: starting execution of 126 ops, cadence 1.0s (ping home 78ms / world 78ms) bags=off
[19:10:09] [SORT] [INFO] Sort: complete in 189.0s - 2 passes, 169 ops issued, 0 remaining, avg 1.12s/op (cursorStuck=0 stalls=0 flushes=11 skipped=1) [empty:1]
[19:10:09] [SORT] [INFO] Sort hitch summary: 3 hitches, max 821ms [<=1000ms:1 <=150ms:2]
```

Counted from the op and WARN lines rather than read off the summaries:

| Measure | Run A | Run B | Run D |
|---|---|---|---|
| Op slots across all passes | 179 + 50 + 2 = 231 | 23 + 2 = 25 | 126 + 44 = 170 |
| Issued | 224 | 25 | 169 |
| WARN refusal lines counted | 7 | 0 | 1 |
| Slots minus refusals | 231 - 7 = 224 | 25 | 170 - 1 = 169 |
| `short-stack` | 6 (pass 1 ops 145, 157, 164, 167, 176, 179, all `T7/69 short-stack (have 1)`) | 0 | 0 |
| `empty` | 1 (pass 2 op 50, `T7/70 empty`) | 0 | 1 (pass 1 op 126, `T7/69 empty`) |
| Refusals with the source tab viewed | 0 | 0 | 0 |
| `flushes` against `floor(issued / 15)` | 14 = 14 | 1 = 1 | 11 = 11 |
| `cursorStuck` | 0 | 0 | 0 |

How the `overflow:` line moved through a run, run D, the same bank read at
three points:

| Plan | `items` | `frag` | `partials` | `extra` | What the input was |
|---|---|---|---|---|---|
| Pass 1 (19:06:58) | 53 | 5 | 63 | 12 | the bank after run C's eleven splits out of overflow and the hand withdrawals |
| Pass 2 (19:09:16) | 53 | 4 | 69 | 18 | the bank after pass 1 filled 37 display demands by splitting overflow stacks |
| Final replan (19:10:09) | 53 | 4 | 53 | 2 | the bank after pass 2's `P0 merge=12(free=4)` and `P4 pack=32` |

Run A read the same way: `items=52 frag=5 partials=51 extra=2` going in,
`items=53 frag=6 partials=69 extra=18` at the start of pass 2, and
`items=53 frag=5 partials=52 extra=2` from pass 3 on.

## What this accounts for

- **The #145 baseline, which is the reason the capture was taken.** On a
  converged bank with two overflow tabs, `frag` equals the number of items
  held in both tabs and nothing else: run D's four fragmented items are
  exactly the four whose split entry names both `T6` and `T7`, and run B's
  five are its five. Within-tab fragmentation is zero after Phase 4, which is
  what #181 predicted the pre-#145 steady state would read (two runs per
  cross-tab item, because each tab packs from slot 1). `extra=2` is the
  cross-tab residue: two items carry a partial in each tab, and Phase 0 cannot
  reach across. So #145, on this bank, is measured as `frag` 4 to 0, `extra` 2
  to 0, `partials` 53 to 51, and the `overflow split:` line absent, with
  `items=53` unchanged. A #145 that reads `frag` above zero on a converged
  bank has not done what it says.
- **The README's final-replan rule, with numbers.** The same bank read
  `partials=63 extra=12` before run D's first pass and `partials=69 extra=18`
  before its second, because filling display demands splits overflow stacks
  and leaves partials behind. Only the final replan's `53` and `2` describe
  what one tab cannot fix on its own. Quoting a first-pass line as the
  baseline would overstate #145's target by a factor of six.
- **Every refusal came from a slot the run itself had written, on a tab it
  was not viewing, and read the count that slot held at that tab's last
  query (#191).** All eight refusals are on `T7`, all while `T6` was the viewed tab,
  and none is on a slot the run had left alone. In run A's first pass the
  pivot slot `T7/69` was first written at op 85 (`move T6/3->T7/69 Gateway
  Control Shard x1`) while `T7` was on screen (`T7` was the viewed tab for
  ops 80 to 89 and `T6` from op 90 on). Every later lift from `T7/69` read
  `have 1`, the shard's count, after
  the run had put a stack of 14, 200, 15, 100, 200 and 62 there in turn (ops
  119, 146, 158, 165, 168, 177), and every one of the six was refused
  `short-stack (have 1)`. Every lift in the same pass from a `T7` slot whose
  contents were in place before or during that view succeeded: `T7/1` (filled
  from bags at op 75), `T7/22` (ops 80 and 81) and `T7/65` (op 84) all lifted
  at ops 165, 168 and 177. The two `empty` refusals are the same shape with a fresh scan as
  the last query: run A pass 2 wrote `T7/70` at op 47 and read it empty at op
  50; run D wrote `T7/69` at op 124 and read it empty at op 126. The
  2026-09-18 record's limit said its pre-checks had only been exercised
  against a stack moved by hand between Preview and Execute; this is the
  other case, and it costs a three-op pivot cycle its third op every time the
  pivot sits on a tab that is not on screen.
- **The non-decreasing rule fired on a bank that was not converged.** Run
  A's pass 3 was two ops because six refusals had left their stacks parked,
  and the replan that followed wanted 23, so the executor read growth and
  stopped with 23 remaining. Run B then issued 25 ops and reached 0. The rule
  did what it says; what it compared against was a pass shrunk by refusals
  rather than by convergence.
- **The cursor predicate, for a fourth capture (#171).** 385 more bank lifts
  across the four runs, `CursorHasItem` blind to every one and
  `GetCursorInfo` seeing them all. No probe line carries ` guard=disabled`;
  every refusal was a pre-check inside `liftFromBank`.
- **`flushes=` is still `floor(issued / 15)`** in all four runs (14, 1, 0, 11
  against 224, 25, 11, 169), as #165 measured it.
- **The bag path, on a large deposit.** 44 deposits issued and none skipped
  in run A, `still in bags: 0` from the last replan, and `bags:0/66` on every
  plan after it: the 34 admitted stacks went in and stayed in. The two hitches
  over a second in that run both fall inside the deposit block, which is also
  where the client logged its lowest frame rates.
- **The link-less probe's last readings (#178, #184).** Nine scans, every one
  `0 with data`, denominators from 46 to 103 no-link slots. Warm readings on a
  client that had been logged in for an hour, so they settle nothing, as
  expected; v0.39.15 removed the line.

## The limit worth stating

**This capture does not say where the refused stacks went.** `cursorStuck`
read 0 in every run, so no post-place swap was detected, and the executor
does not log what a slot held after an op. The only trace of the six stacks
parked in `T7/69` is run A's 23-op residual and run B's 25 ops, which is
consistent with the parked stacks being picked up by the next scan and
packed, and with nothing else.

**The mechanism is inferred from the pattern, not measured.** Eight refusals
in one shape and zero outside it is strong, but no line here reads the same
slot with the tab on screen and off it. A capture that does that, or a spec
against a mock whose non-viewed tabs answer from their last query (the mock
already has `viewGatedReads`), is what turns the inference into a finding.
#191's build added the spec; the capture half is still owed, and its
`stalesrc=` term is where to read it.

**The bags-on pair's bank was not the bags-off pair's bank.** Stacks were
withdrawn by hand between them, so run B's `frag=5` and run D's `frag=4` are
two readings of two states, not a change the sort made. The `Auto-Hammer`
entry that leaves the split line between them left because its one `T6`
stack was moved to a display tab (run D op 13), not because the tabs were
merged.

**The 18:59:21 preview was built on a bank snapshot the withdrawals had
already outdated.** It planned 184 ops against 625 occupied slots, and the
scan eleven seconds later read 583. Nothing ran from it, and the plan that
did run followed a fresh scan, but it is the Preview-and-Scan seam in the
open.

## For the reader of the next capture

On a bank with more than one overflow tab, read the final replan's
`overflow:` line and nothing earlier: `frag` there is the number of items
split across tabs, `extra` the partials that split costs, and the two are
what #145 changes. Then the refusals, and for each one the viewed tab on its
own line against the tab of its source slot: a refusal whose source is on
the viewed tab is the hand-moved case from 2026-09-18, and one whose source
is on another tab and was written earlier in the pass is this record's case.
A run that stops with a residual after a pass of two or three ops has
probably hit the second shape, and the next run will finish it.
