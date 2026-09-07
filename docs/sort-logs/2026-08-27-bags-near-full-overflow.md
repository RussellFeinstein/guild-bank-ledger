# 2026-08-27: bags into a near-full overflow, and a pass-cap stop that was not the bags

Second in-game capture of the bags-as-a-sort-source work (#139), on
`feat/sort-include-bags` at v0.39.0. The first run (2026-08-26, 401 ops over four
passes, 43 deposits, converged to zero) is the one PR #141's body describes. This one
was taken deliberately against a much tighter bank: two overflow tabs at 97/98 and
84/98, so the spill had almost nowhere to go.

The bag half worked. The sort did not finish, and the reason has nothing to do with
bags. That separation is the whole value of the capture, and it is why this file exists
before the third run rather than after it.

## What the bag path did

| Pass | Plan line term | Deposits |
|---|---|---|
| 1 | `bags:23(fill=0,spill=31)` | 31 |
| 2 (replan) | `bags:4(fill=0,spill=7)` | 7 |

Thirty-eight of thirty-eight deposits landed. No refusal, no cursor left holding
anything, and no op anywhere in the capture targeted a bag, which is the source-only
invariant holding under pressure rather than in a fixture.

`fill=0` on both passes is correct and worth reading rather than skimming: every display
tab already held its full template, so no bag stack could fill a demand and all of them
went to overflow. A capture where `fill` is zero and `spill` is not is the ordinary
shape of a farming run into an already-tidy bank.

The pass-2 term shrinking from 23 admitted to 4 is the property the replan is supposed
to show. The executor re-reads the bags in `endOfPass` rather than reusing the pass-1
snapshot, and this is what that looks like when it works: the stacks deposited in pass 1
are gone from the bags by the time pass 2 plans.

## What did not finish

The run stopped at `MAX_PASSES = 5` with one bank-only move outstanding, and
`3 deficits, 4 unplaced` persisting across the last three passes. Passes 3, 4 and 5
re-issued the same two ops, a `split T1/x->T6/4` and a move into `T6/16`.

Phase 4 pack counts across the run were 69, 92, 43, 8, 6, 5. That is the shape #140
fixed: the counts fall steeply and then flatten out small rather than oscillating or
growing, so the packing churn is not what is happening here. What is left is a small
cycle involving a tab that is one slot from full.

## Verdict: not filed

This is recorded, not tracked. The candidate explanation is a pivot-slot shortage in an
overflow tab at 97/98, which is the same neighbourhood as #143 (Phase 4's unplaced-slot
skip) and #138 (`pivotBreakLoop` budget exhaustion dropping assignments from the plan
report), both already open and both due immediately after this PR merges. Filing a third
issue from one unreproduced observation would put a guess on the tracker beside two
issues that were derived from the code.

The condition for filing is the next combined run. If a near-full overflow tab again
ends at the pass cap with the same two ops re-issued, it is real and it gets an issue
with this capture as its evidence. If #143 and #138 land first and it stops happening,
this file is the record of what they fixed.

## For the reader of the next capture

- `bags=on` on the start line says the run was in bags mode at all. Absent means the
  checkbox was off and every bag term below is meaningless.
- The plan-line term is emitted whenever a bag snapshot was handed in, so
  `bags:0/17(...)` is a real and informative line: seventeen stacks seen, none
  admitted, and the `ignored=`, `bound=`, `locked=` and `nolink=` counters say why.
- `Sort bags:` at the end reports `still in bags` from the LAST replan, not the first
  plan. A run that aborted before any replan says `unknown (no replan)` rather than
  reporting the pre-run figure as if it were the outcome.
