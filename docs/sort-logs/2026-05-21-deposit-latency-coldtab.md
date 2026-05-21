# 2026-05-21: Deposit-latency capture, confirm-on-deposit, and the cold-tab tail

In-game capture on `layout-sort` at v0.32.8 (PR #30), with the Phase-1
instrumentation (deposit-latency observer + abort narrowed to genuine refusals).
This is the run that gave us the deposit-latency distribution and drove the Phase-2
confirm-on-deposit fix. The instrument-first sequence (measure before building) was
the user's explicit call (see memory `feedback_instrument_before_building`).

## Outcome: the bank fully sorted

Letting the run complete (no abort on lagging deposits) worked: the final plans report
`0 ops, 3 deficits` with `[T1:43 T2:98 T3:98 T4:92 T5:92 T6:72 T7:2]` (T5 was 0 at the
start of the saga). The 3 deficits are unfillable (not enough supply), not failures.

## Deposit-latency distribution (the data we came for)

- **Common case: ~0.6s.** The `no-op suspected ... at +0.Xs` lines are almost all
  `+0.4s` to `+0.7s`. The executor was throwing away ~3.4s/op waiting for source-drain.
- **Slow tail: 10-19s.** The observer caught `deposit landed at +10.1s / +12.6s /
  +18.1s / +19.2s`.
- **Cold-tab first-deposits: >20s.** Every op into T5 while it was still sparse
  (S1-S36) logged `deposit NOT observed within 20s`. Once T5 was warm, the next run's
  T5 deposits (S38-S92) were back to ~0.6s. So the >20s tail is "first deposits into a
  sparsely-populated tab," not a property of the items.
- **Full-stack moves are fast both ways** (~1s, source included): the T6->T6
  consolidation moves confirmed via `[interim-poll]` at 0.5-1.0s with `src=empty`. Only
  partial `x1` splits have the source-drain lag.

Implication: a per-op *wait* long enough to catch the cold tail (>20s) is a non-starter.

## Shipped: Phase 2 confirm-on-deposit (v0.32.8)

`opSucceeded(w)`: a split/move into an empty (or different-item) slot is confirmed the
moment the destination holds the item, dropping the source-drain wait there; a merge
into an occupied same-item slot still requires source-drain (the optimistic-bounce case
from `project_wow_pickup_optimism`). The warm case drops from 4s to ~1s per op (~4x).
Cold-tab stragglers advance unconfirmed (no abort) and reconcile on a re-scan, as today.

Safety: deposits are server-driven (they fire the slots-changed event) and persist,
proven by the bank converging correctly across hundreds of them. The change is gated on
`dstPreOp` (empty/other), so it never relaxes the rule for merges.

## Cold-tab: still open, now instrumented (passively)

We do not yet know *why* first-deposits into a sparse tab are >20s. Candidates:
observation staleness (the deposit lands server-side but `GetGuildBankItemInfo` returns
cached data for a tab we are not "viewing"), server lazy-init of a sparse tab, or server
throttle after sustained activity. The T4-fast / T5-slow asymmetry fits none cleanly.

Grounding: the executor never calls `QueryGuildBankTab` (only the scanner does), and WoW
actively tracks one "viewed" tab. v0.32.8 adds a **passive** `viewed=TN`
(`GetCurrentGuildBankTab`) stamp on the done / timeout / deposit-observer audit lines, so
the next capture can correlate the viewed tab with deposit latency without perturbing the
executor. If slow deposits correlate with `viewed != dst`, the fix is to query/view the
destination tab on tab-change (with event suppression). If the viewed tab is constant
across fast and slow, that rules out the viewed-tab cause and points at server-side.

## Other follow-ups seen in this capture

- **Planner bug:** it emits an impossible full-stack `x200 -> x200` Lightfused Mana
  Potion merge (two slots both at max stack), which can never succeed and causes the
  genuine `merge-noop` abort. A Phase 4 (overflow-pack) fix: do not emit a consolidation
  between two full max-stack stacks.
- **replan-scan-timeout:** a 1041s run aborted with "scan-wait timeout during replan"
  after a foreign-activity replan (the known replan-scan-race). Faster runs
  (confirm-on-deposit) shrink the window for this.
- **No rescan on abort:** after an aborted run the next plan reused the pre-run scan
  (stale preview). Worth a rescan-on-abort.
