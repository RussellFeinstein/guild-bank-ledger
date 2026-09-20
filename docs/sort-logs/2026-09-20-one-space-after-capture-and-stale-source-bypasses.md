# 2026-09-20: the first sort on one overflow space reads frag=0 extra=0, and 34 stale-source bypasses lifted nothing a pre-check would have refused

The after capture for #145 (v0.39.17) and the in-game half of #191 (v0.39.16),
taken on the evening of 2026-09-19 local. The bank converged in one completed
run with the final replan reading `frag=0 extra=0`, against the 2026-09-19
baseline's `frag=4 extra=2`; the one-time reshuffle the space costs was 153
pack moves, 55 of them across the tab boundary. The stale-source ledger fired
34 times and never once lifted a count the slot read disagreed with: the two
reads it did disagree with were zero, both on a bag deposit into the tab that
was off screen, and both lifts failed at the cursor guard. The baseline's
stale non-zero read did not recur.

## What was run

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Started | 00:37:30 | 00:43:57 | 00:45:22 |
| Bags | off | on | on |
| Planned | 159 ops | 249 ops | 228 ops |
| Ended | aborted (cancelled) at op 23 | aborted (bank closed) at op 24 | complete, 2 passes, 0 remaining |
| Ops issued | 22 | 23 | 232 (226 + 6) |
| Refused | 0 | 0 | 2 (`lift-failed`) |
| `stalesrc=` | not printed (absent at zero) | not printed | 34 |
| Probe | GetCursorInfo [item:22] | GetCursorInfo [item:23] | GetCursorInfo [item:178 none:2] |

Addon version 0.39.17, session 9 of the capture. Run 1 was the bags-off sort
the after capture asked for and Russell cancelled it by hand at op 23; run 2
lost the bank window at op 24. Run 3 is the one that converged, with bags on,
so its final figures include 54 deposits.

## The figures

### Before: the first plan of the session, bags off

```
[00:20:41] Sort plan: 14.6ms, 159 ops, 0 deficits, 0 unplaced (input: 627 slots / 7 tabs, locked=0) unviewable:none [T1:91 T2:98 T3:98 T4:93 T5:90 T6:89 T7:68]
[00:20:41]   phases: P0 merge=2(free=2,cross=2) P1a assign=4 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=153(cross=55)
[00:20:41]   demands: 474 total (pinned=0, ext-R=423, ext-L=0, first-empty=51)
[00:20:41]   overflow: items=53 frag=4 partials=53 extra=2 unknown=0
[00:20:41]   overflow split: Inky Black Potion (it:124640) T6x2 T7x6, Gateway Control Shard (it:188152) T6x8 T7x6, Light's Potential (it:241309) T6x3 T7x2, Thalassian Phoenix Oil (it:243733) T6x12 T7x35
```

The same four split items and the same `frag=4 partials=53 extra=2` as the
baseline's final replan, which is the input #145 was measured against. Of the
159 ops, 153 are Phase 4 pack moves and 55 of those cross the tab boundary; the
two Phase 0 pours are the two cross-tab partials the baseline could not merge.

### Run 3, the end of pass 1 and pass 2

```
[00:49:24] Sort plan: 12.4ms, 6 ops, 0 deficits, 0 unplaced (input: 635 slots / 7 tabs, locked=0) bags:1/67(stay=0,ignored=17,bound=49,locked=0,nolink=0,fillops=0,spillops=1) unviewable:none [T1:91 T2:98 T3:98 T4:95 T5:92 T6:97 T7:64]
[00:49:24]   phases: P0 merge=0(free=0,cross=0) P1a assign=0 P1b spill=1(top=0,r=1,l=0,fe=0,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=5(cross=3)
[00:49:24]   demands: 474 total (pinned=0, ext-R=423, ext-L=0, first-empty=51)
[00:49:24]   overflow: items=53 frag=3 partials=49 extra=0 unknown=0
[00:49:24]   overflow split: Thalassian Phoenix Oil (it:243733) T6x10 T7x37, Inky Black Potion (it:124640) T6x7 T7x1, Auto-Hammer (it:132514) T6x16 T7x1
[00:49:24] Sort: pass 1 left 6 move(s); re-running
[00:49:24] Sort op 1/6: move Bag2/18->T7/63 Concentrated Silvermoon Health Potion (it:271883) x62 (viewed T7)
[00:49:25] Sort op 2/6: move T7/65->T6/11 Auto-Hammer (it:132514) x20 (viewed T7)
[00:49:26] Sort op 3/6: move T6/7->T7/8 Thalassian Phoenix Oil (it:243733) x20 (viewed T7)
[00:49:27] Sort op 4/6: move T7/66->T7/10 Thalassian Phoenix Oil (it:243733) x20 (viewed T6)
[00:49:28] Sort op 5/6: move T7/32->T6/7 Inky Black Potion (it:124640) x200 (viewed T6)
[00:49:29] Sort op 6/6: move T7/67->T7/32 Thalassian Phoenix Oil (it:243733) x20 (viewed T7)
```

### After: the final replan and the summary

```
[00:49:38] Sort plan: 6.6ms, 0 ops, 0 deficits, 0 unplaced (input: 636 slots / 7 tabs, locked=0) bags:0/66(stay=0,ignored=17,bound=49,locked=0,nolink=0,fillops=0,spillops=0) unviewable:none [T1:91 T2:98 T3:98 T4:95 T5:92 T6:98 T7:64]
[00:49:38]   phases: P0 merge=0(free=0,cross=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0,stranded=0) P3 sweep=0 P4 pack=0(cross=0)
[00:49:38]   demands: 474 total (pinned=0, ext-R=423, ext-L=0, first-empty=51)
[00:49:38]   overflow: items=53 frag=0 partials=50 extra=0 unknown=0
[00:49:38] Sort: complete in 255.8s - 2 passes, 232 ops issued, 0 remaining, avg 1.10s/op (cursorStuck=0 stalls=0 flushes=15 stalesrc=34 skipped=2) [lift-failed:2]
[00:49:38] Sort bags: 54 deposit(s) issued, 0 skipped, still in bags: 0
[00:49:38] Sort lift probe: GetCursorInfo [item:178 none:2], CursorHasItem true=0 false=180
```

No `overflow split:` line follows the final `overflow:` line, and the eight
previews and deviation prints that follow it, out to 00:57:42, all read 0 ops
and the same `frag=0 partials=50 extra=0`.

### The two refusals, with what wrote their slots

```
[00:46:00] Sort op 36/228: split Bag2/18->T7/66 Concentrated Silvermoon Health Potion (it:271883) x18 (viewed T6)
[00:46:01] Sort op 37/228: move Bag2/18->T7/68 Concentrated Silvermoon Health Potion (it:271883) x62 (viewed T6)
[00:46:24] Sort op 60/228: move Bag3/14->T7/32 Inky Black Potion (it:124640) x200 (viewed T6)
[00:46:26] Sort op 62/228: move Bag3/3->T7/33 Inky Black Potion (it:124640) x100 (viewed T6)
[00:46:50] Sort op 85/228: move T7/68->T7/63 Concentrated Silvermoon Health Potion (it:271883) x62 (viewed T6)
[00:46:50] Sort op 85/228: stale source T7/68 (written this pass, viewing T6) reads 0, lifting 62 per plan as move
[00:46:50] [WARN] Sort op 85/228 skipped: T7/68 lift-failed, wanted 62 x Concentrated Silvermoon Health Potion (it:271883)
[00:47:09] Sort op 104/228: move T7/32->T6/7 Inky Black Potion (it:124640) x200 (viewed T6)
[00:47:09] Sort op 104/228: stale source T7/32 (written this pass, viewing T6) reads 0, lifting 200 per plan as move
[00:47:09] [WARN] Sort op 104/228 skipped: T7/32 lift-failed, wanted 200 x Inky Black Potion (it:124640)
[00:47:12] Sort op 107/228: move T7/61->T7/32 Thalassian Phoenix Oil (it:243733) x20 (viewed T6)
[00:47:13] Sort op 108/228: move T7/66->T7/61 Concentrated Silvermoon Health Potion (it:271883) x200 (viewed T6)
[00:47:13] Sort op 108/228: stale source T7/66 (written this pass, viewing T6) reads 200, lifting 200 per plan as move
```

## What this accounts for

- **Run 3's ops.** 228 planned in pass 1, 2 refused, 226 issued; 6 planned and
  issued in pass 2; 232 on the summary. The probe's 180 bank lifts (178 with an
  item on the cursor, 2 with none) are 232 minus the 54 bag deposits, plus the
  2 refused bank lifts that reached the probe and put nothing on the cursor.
- **The bag line.** 54 deposits issued and `still in bags: 0` from the final
  replan's `bags:0/66`; the 66 seen are the 17 ignored and 49 bound the layout
  never names.
- **`stalesrc=34` against the bypass lines.** 34 `stale source` lines in pass
  1, none in pass 2 (a pass begins with an empty ledger after a full scan).
- **`skipped=2 [lift-failed:2]`.** Both refusals are bypass lines whose read
  was 0; no `empty` and no `short-stack` refusal anywhere in the session. The
  baseline had eight.
- **The two earlier runs.** Run 1 issued 22 ops and was cancelled by hand at
  op 23; run 2 issued 23 and lost the bank window; neither refused an op.
  Between them the bank was replanned at 159 then 249 ops (bags on adds 55
  spills), so the 228-op plan run 3 started from is not the 159-op reshuffle
  in full, but its `P4 pack=144(cross=60)` is the same reshuffle less what the
  two partial runs had already moved.

## What the two readings say

### #145: accepted, and the cost with a number on it

The final replan reads `items=53 frag=0 partials=50 extra=0 unknown=0` with no
split line, against the baseline's `frag=4 partials=53 extra=2`. The
prediction was `partials=51`: the bags-on run topped one more partial up
from a deposit, which a bags-off run could not have done, so 50 is the same
outcome one deposit further along. `items=53` is unchanged, as it had to be.

The one-time cost on this bank is the first plan's `P4 pack=153(cross=55)`:
153 of 159 ops are the pack, and 55 of those cross the boundary. The re-audit's
cost model ("one move per later run, not per later stack") described a run of
interchangeable stacks whose range shifts by one, and that still holds; what
the first sort after #145 does is different in kind, because the pre-#145
state was two tabs each packed from their own slot 1 in itemID order, and
merging two sorted sequences into one moves nearly every stack after the
first point they diverge. That is a one-time price and this session paid it:
every plan after the converged replan reads 0 ops, and `cross=0` on both terms.

### #191: no refusal on a written slot, and the rescue case unobserved

Every bypass line in run 3, with the last write to its slot and whether that
write happened with the slot's tab on screen (the ledger records the write
and not the view, so it fires either way):

| Bypasses | Last write on screen | Read agreed with the plan | Read disagreed |
|---|---|---|---|
| 26 | yes | 26 | 0 |
| 8 | no | 6 | 2 (both read 0, both `lift-failed`) |

So the 26 on-screen writes were live reads the ledger bypassed for nothing,
which is the over-firing the fix accepted, and it cost nothing: the lift took
what the plan said, which was what the slot held. Of the 8 off-screen writes,
6 read exactly the plan's count. The baseline's shape, a written slot on the
off-screen tab reading the count from that tab's last view (`T7/69` reading
`have 1` through six writes of 14, 200, 15, 100, 200 and 62), did not appear
once. The two disagreements read 0, and 0 was the truth at the moment of the
lift: the cursor guard found nothing to pick up both times.

What those two were: bag deposits into `T7` while `T6` was on screen. `T7/68`
was written by op 37, a whole-stack move of the 62 potions left in `Bag2/18`
one second after op 36 had split 18 out of the same bag slot into `T7/66`. The
62 never landed: pass 2's first op is `move Bag2/18->T7/63 x62`, the end-of-pass
scan still saw them in the bag, and the split's 18 did land (`T7/66` read
200 at op 108). `T7/32` was written by op 60, a whole-stack deposit of 200
potions; at op 104, 45 seconds later, the lift found nothing; at pass 2 the
200 were at `T7/32` and lifted cleanly (op 5/6). Between those two reads op
107 placed 20 oil into `T7/32`, and pass 2 found that oil at `T7/67` (op 6/6
brings it back to `T7/32` after the potions leave). The order the server
applied those three writes in is not recoverable from this side.

The reading for #191, then: the fix removed the refusals the baseline had
(eight to zero, on a run with more cross-tab traffic than the baseline's),
harmed nothing across 34 bypasses, and was never once needed for a stale
non-zero read in this session. Its claim about the client's cache rests on
the baseline capture alone until a run reads `stalesrc=` beside a bypass
whose read disagrees with the plan by something other than zero.

## The limit worth stating

A bag deposit can fail without a refusal, and `liftFromBag` cannot see it.
Op 37 took the remainder of a bag slot one second after op 36 had split from
the same slot; the container call raised nothing, the cursor guard passed
(the item was on the cursor), the destination pickup was issued, and the
stack was still in the bag two minutes later. The `locked` refusal in
`liftFromBag` reads the client's lock flag, which had not set. The run
recovered because the end-of-pass scan re-read the bags and pass 2 re-issued
the deposit, so the cost was one pass and one `lift-failed` at op 85, and the
existing rule holds: a refusal is ordinary, counted, and left to convergence.
What is not yet known is whether the two takes from one bag slot in
consecutive ops is the trigger; a future capture with `Sort bags:` reading a
non-zero `still in bags` after a converged run would say so.

## For the reader of the next capture

- `stalesrc=N` counts bypasses, not rescues. Read it beside the `stale source`
  lines and count how many read a value other than the plan's: that number is
  the mechanism doing work, and in this session it was zero. A `reads 0` that
  then fails is the plan being wrong about its own write, as CLAUDE.md says.
- The `overflow:` figures to compare against are now `frag=0 partials=50
  extra=0` on this bank with bags on; a bags-off run should read 50 or 51.
- Two takes from one bag slot in consecutive ops (a split, then the whole
  remainder) is the shape to watch for a deposit that never lands.
