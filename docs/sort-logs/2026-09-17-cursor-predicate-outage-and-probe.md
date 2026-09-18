# 2026-09-17: a cursor predicate took the sort down, and the probe that named it

- **Date**: 2026-09-17
- **Addon versions**: 0.39.5 (the outage), 0.39.6 (the measurement)
- **Bank**: 7 tabs, 557 to 629 slots across the day
- **Source**: in-game capture from `GuildBankLedgerAuditDB`, sort channel.

Sessions 8 and 10 of the capture store, addressed by index rather than by line.
Two captures, taken hours apart, that only mean anything read together. The first is a shipped build refusing every op it attempted. The second is the build that withdrew the refusal and measured the predicates instead. Between them they settle which cursor API can be trusted after a guild bank lift, and they refute a finding this project had already written down twice.

## What was run

**v0.39.5, two runs.** A 207-op plan, executed twice against the same bank, cancelled by hand both times once it was clear nothing was moving.

```
00:04:32  Sort: starting execution of 207 ops, cadence 1.0s bags=on
00:04:32  Sort op 1/207: split T6/23->T2/15 Potion of Recklessness (it:241289) x20 (viewed T7)
00:04:32  Sort op 1/207 skipped: T6/23 lift-failed, wanted 20 x Potion of Recklessness
...
00:05:04  Sort: aborted (cancelled) in 31.5s - 1 passes, 0 ops issued, 207 remaining,
          avg 0.00s/op (cursorStuck=0 stalls=0 rescans=0 skipped=30) [lift-failed:30]
00:05:23  Sort: aborted (cancelled) in 6.2s - 1 passes, 0 ops issued, 207 remaining,
          avg 0.00s/op (cursorStuck=0 stalls=0 rescans=0 skipped=5) [lift-failed:5]
```

Every op attempted was refused: 30 in the first run, 5 in the second, 0 issued in either. The refusal came from a guard added in v0.39.5 (#169) that read `CursorHasItem()` after the source lift and treated false as a failed lift.

**v0.39.6, one run.** The guard withdrawn, a probe in its place recording what each predicate answered and acting on neither.

```
00:xx  Sort: starting execution of 227 ops, cadence 1.0s bags=on
       Sort: pass 1 left 60 move(s); re-running
       Sort plan: 11.2ms, 0 ops, 1 deficits, 0 unplaced (input: 625 slots / 7 tabs)
       Sort: complete in 310.7s - 2 passes, 287 ops issued, 0 remaining,
             avg 1.08s/op (cursorStuck=0 stalls=0 rescans=19)
       Sort bags: 49 deposit(s) issued, 0 skipped, still in bags: 0
       Sort lift probe: src drained=0 not-drained=238 unknown=0,
             GetCursorInfo [item:238], CursorHasItem true=0 false=238
       Sort hitch summary: 5 hitches, max 3330ms [<=150ms:3 <=250ms:1 >1000ms:1]
```

## The figures

**Nothing in the bank was damaged by the outage.** Three consecutive plan lines spanning both v0.39.5 runs are identical: 207 ops, `input: 557 slots`, `[T1:89 T2:89 T3:86 T4:76 T5:75 T6:81 T7:61]`. Across 35 refused ops not one slot changed.

**The v0.39.6 run is ground truth.** 287 ops issued, 0 skipped, 0 remaining, and the replan after the final pass came back at 0 ops. 238 bank lifts plus 49 bag deposits accounts for every issued op, so the probe covered every bank lift in the run and every one of them demonstrably worked.

Against that known-good outcome:

| Signal | Answer | Correct? |
|---|---|---|
| `CursorHasItem()` | false, 238 of 238 | never |
| `GetCursorInfo()` | `item`, 238 of 238 | always |
| source slot count re-read after the lift | undrained, 238 of 238 | never |

**162 of the 238 lifts sourced the tab that was selected at the time**, counted from the `(viewed T<n>)` rider each op line carries, which comes from `GetCurrentGuildBankTab`. The other 76 sourced a different tab. Both groups read the same way on all three signals.

## What this accounts for

**`CursorHasItem()` does not report a guild bank item.** That is the whole of the v0.39.5 outage. A guard that refused on it refused everything, and the same blind spot explains why `cursorStuck` reads 0 in every capture this repo holds: the counter and both per-tick `ClearCursor()` calls were gated on it, so for a bank item none of them ever fired. None of those zeroes was evidence of a clean cursor.

**`GetCursorInfo()` is the predicate to build on.** It matched ground truth on every lift in the run.

**Source drain is refuted at this call site, and it was the favoured signal going in.** The probe deliberately led with drain, on a standing project finding that `PickupGuildBankItem` updates the client's slot view optimistically and so source drain is the authoritative discriminator for a completed move. The probe's own code comment warned only that a non-viewed tab reads from cache. That caveat does not cover this: two thirds of the lifts had their source tab live on screen and read undrained anyway. The slot API does not see a lift within the same frame, and the optimistic update happens at the display layer. Drain stays authoritative read across frames, which is what `endOfPass` already relies on, and is unusable synchronously.

**A mixed run is better evidence than the two-run protocol that was planned for this.** #171 asked for one run with the source tab pinned and one tab-hopping, to separate a real drain from a stale cached read. Having both inside one run holds everything else constant, which two separate runs could not.

## The limit worth stating

`GetCursorInfo()` is now verified on one client, on one patch, by one run. That is exactly the standard v0.39.5 failed to meet, and it is not a standard that stays met: a client change makes it stale without any warning. The re-landed guard therefore carries a fuse. A run in which it refuses several ops without ever once passing reads as a broken predicate rather than a bank full of failed lifts, so it disables itself for the rest of the run and says so at WARN. That trades a harvest no capture has ever recorded against an outage that has.

## For the reader of the next capture

The line to look at is `Sort lift probe:`. `GetCursorInfo [item:N]` with N matching the run's bank lifts is the healthy shape. Anything else, `none:` entries in particular, means the predicate has moved and the guard is about to start refusing work that would have succeeded. ` guard=disabled` on the end of that line means the fuse already blew and the run finished unguarded.
