# 2026-05-21: Phantom split storm from a cold snapshot + dead timeout classifier

In-game sort log captured on the `layout-sort` branch at v0.32.8 (PR #30,
post-stamp in-game validation). A 5-op sort burned 21.3s with every op failing,
yet a rescan immediately after showed the work was never needed. The capture
pins two separate defects.

## Setup

- Build: `layout-sort` at `1374f12` (Stamp v0.32.8), DEV_BUILD nil.
- Guild: 7 tabs. Pre-sort plan reported 493 occupied slots; post-sort plans
  reported 498.
- Layout: enchant scrolls consolidated into display tab T5, overflow in T6.

## The capture

The plan (built twice, identical):

```
demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
phases: P0 merge=0 P1a assign=5 P1b spill=0 P2 pivot=0 P3 sweep=0 P4 pack=0
Sort plan: 5.5ms, 5 ops, 4 deficits, 0 unplaced (input: 493 slots / 7 tabs)
```

Execution (5 ops, all `split` from T6 into T5):

```
Sort op 1 no-op suspected [async]: split T6/S51->T5/S17 Enchant Ring - Eyes of the Eagle (it:243957) x1 (dst already held expected item; src unchanged)
Sort: op 1 timed out (no confirm within 4s) [other]
  op 1 was: split T6/S51 -> T5/S17 Enchant Ring - Eyes of the Eagle (it:243957) x1
  observed: src Enchant Ring - Eyes of the Eagle (it:243957) x3, dst Enchant Ring - Eyes of the Eagle (it:243957) x1, cursor empty
  (planner projected: src Enchant Ring - Eyes of the Eagle (it:243957) x3, dst empty)
...
Sort: complete in 21.3s - 5 ops (0 done, 5 failed, 1 replans, 0 reclass) preCheck=0 cursor=0 timeout[s=0,p=0,c=0,m=0,o=5] drifts=5 avg 4.25s/op
```

Then, after a warm rescan, every later plan:

```
Sort plan: 4.x ms, 0 ops, 3 deficits, 0 unplaced (input: 498 slots / 7 tabs)
```

## Finding 1 (root cause): the plan was built against a cold snapshot

Every op projected `dst empty` but observed `dst x1` of the same item, and the
source never drained. The planner thought five T5 display slots were empty and
planned to fill them from overflow. They already held the item.

The proof is the slot count: `493 → 498` the instant a warm rescan ran, a +5 that
matches the 5 ops exactly, and the warm plan then needs `0 ops`. If these had been
legitimate splits the server merely refused, the warm replan would still want to
do them. It does not, so the layout was already satisfied. The planner only wanted
to move the items because the scan that fed it did not see them.

The scanner reads `GetGuildBankItemLink` per slot after `QueryGuildBankTab`, with a
3s timeout fallback and a `not locked` skip (`Scanner.lua`). A tab whose slot data
had not yet arrived from the server (cold cache), or whose slots were transiently
locked, records those slots as absent. Nothing gates sort planning on snapshot
freshness: Preview and Execute plan against whatever `lastScanResults` holds.

This corroborates the `2026-05-20-prewarm-success-late-poll-recurrence.md` "Mode 1"
observation (ops 1-32 timing out as `[other]` with src unchanged and dst already
holding the item). That was read there as the server refusing a split into an
existing partial stack. The 2026-05-21 capture shows it is more likely the same
cold-snapshot phantom: the planner was blind to items already in place.

## Finding 2: the v0.32.8 timeout classifier was dead in-game

All five timeouts bucketed as `[other]` (`timeout[s=0,p=0,c=0,m=0,o=5]`). They are
textbook `merge-noop` (src unchanged, dst holds the expected item, cursor empty,
planner expected dst empty). They landed in `other` because `classifyTimeoutState`
prefix-matched `"it:<id> x"` at position 1 of the slot description, while
`describeSlot` returns `"<name> (it:<id>) x<n>"` once the item name resolves. The
prefix never matched in-game, so the `merge-noop` and `server-rejected` buckets, and
the 3-strike abort keyed off them, only ever worked in tests (where mocked items have
no cached name). The unit tests passed precisely because the bare `it:<id> x<n>` form
matched.

Note the abort would not have stopped this particular storm even when working: it
fires on 3 consecutive refusals of the same item, and this storm spans four distinct
items (Zul'jin appears twice at most). The fix here restores correct diagnostics, not
an early bail for the heterogeneous case.

## Shipped in this PR (#30, v0.32.8)

- `classifyTimeoutState` now classifies from structured live-slot snapshots
  (`snapshotLiveSlot`), not the display string. Regression test warms the ItemCache so
  `describeSlot` carries the in-game name and asserts the bucket + abort still fire.
- Scan diagnostics: per-tab `completedVia` (event vs query-timeout) and `lockedSkips`
  in a `Scan:` summary line, plus a per-tab occupied-slot breakdown on the sort plan
  line. Together they identify a cold tab and its mechanism in `/gbl sortlog`.

## Deferred (follow-up PR)

The freshness fix itself. Candidates: force a warm `StartFullScan` and wait before
sort Execute, or a scanner cold-read guard that retries tabs whose scan finished via
timeout or had locked slots. The captured `completedVia` / `lockedSkips` signals from
the next in-game run decide which.
