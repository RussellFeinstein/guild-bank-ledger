# 2026-05-21: Cold tab confirmed = destination tab not viewed

In-game capture on `layout-sort` at v0.32.8 (PR #30) with the passive `viewed=TN`
instrument. The user filled T5 while manually clicking between tabs and noticed it
"adjusted the speed and whether things were failing." That observation plus the
`viewed=` stamp pins the cold-tab cause decisively.

## The correlation

For deposits into T5:
- `viewed=T5` (destination open) -> ops **succeed**, many in ~0.6s (ops 100-116, 135-184).
- `viewed=T4` or `viewed=T6` (some other tab open) -> the same ops **fail** as
  `server-rejected` / "deposit NOT observed within 20s" (ops 93-99 `viewed=T4`,
  ops 119-134 `viewed=T6`).

## It's observation, not the deposit

Ops 125-128 (Mark of the Worldsoul, source `T6/S54`, `viewed=T6`) are all marked
`server-rejected`, yet the source stack drains across them: **x13 -> x12 -> x11 -> x10**.
Each "failed" op actually deposited server-side; the source drain is visible because T6
(the source tab) was the viewed tab, while the destination T5 read stale-empty because
T5 was not viewed. The run finishes at `T5:92` and the next plan is `0 ops` — every one
of the 26 "failures" was a false negative.

## Mechanism

`GetGuildBankItemInfo` returns fresh slot data only for the currently-viewed guild bank
tab; other tabs return cached data. The executor's `opSucceeded` confirms a deposit by
reading the destination slot, so it can only confirm when the destination tab is viewed.
Deposits land regardless of the viewed tab; only their observation is gated. Operating on
a non-viewed SOURCE is fine (the `viewed=T5` ops moved items out of T6 without T6 viewed).

## Implication

Correctness is unaffected — the bank sorts fully. The cost is false `server-rejected`
failures and 4s waits whenever the destination tab is not the one being viewed. The fix
is to make the executor view the destination tab during execution
(`QueryGuildBankTab(destTab)` on destination-tab-change), so destination reads are fresh
and `opSucceeded` fires at ~0.6s. The query fires `GUILDBANKBAGSLOTS_CHANGED`, so it
should be issued while an op is in-flight or with a brief replan-suppression window (the
refresh is wanted: it drives the confirmation).

## Note on speed

Even with the destination viewed, confirmations are bimodal (~0.6s or ~3s). The ~3s mode
is deposits landing between the 2s interim poll and the 4s late-poll, caught by the async
event around 3s. A future interim-poll offset around 3s would tighten that, but it is
secondary to the viewed-tab fix.
