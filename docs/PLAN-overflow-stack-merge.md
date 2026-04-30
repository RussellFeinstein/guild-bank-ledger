<!-- Promoted from ~/.claude/plans/note-that-tomorrow-we-elegant-elephant.md on 2026-04-28 -->

# Overflow stack merging — Phase 4 enhancement

## Context

In-game observation: the stock (overflow) tab ends up with multiple partial stacks of the same item after a sort, e.g. two stacks of 160 Healing Potions when the item's max stack size is 200. SortPlanner Phase 4 currently groups same-item stacks contiguously and sorts them `(itemID ASC, count DESC, origSlot ASC)`, but it has no max-stack knowledge and never merges partial stacks into full ones.

CLAUDE.md already calls this out as a known limitation:
> "no partial-stack merging — the planner has no max-stack knowledge"

This is the next sort-tab fix to ship.

## Goal

After a sort completes, every same-item run on the overflow tab should be a sequence of full stacks followed by at most one partial stack at the end. Repeat sorts must remain idempotent.

## Approach

### 1. Plumb max stack size into the planner

ItemCache.lua currently caches only `(name, link)` from `GetItemInfo`. `GetItemInfo`'s 8th return value is `itemStackCount` — extend the cache tuple to include it.

- **`ItemCache.lua`** — add `stackCount` to the cached fields; expose `GBL.ItemCache:GetMaxStack(itemID)` returning the cached value or `nil` when not yet known.
- **Snapshot path** — when Scanner builds the snapshot, opportunistically populate stack count for each observed itemID via the cache (already happens for name/link).
- **`SortPlanner.lua`** — accept an optional `maxStackByItem` map in the planner input (or look it up from ItemCache directly). When `nil` for a given itemID, fall back to current behavior (no merging) so a cold cache never blocks a sort.

### 2. Merge step in Phase 4

In `SortPlanner.lua` lines 682–730, after the existing `ovStacks` sort by `(itemID, -count, origSlot)`:

1. Walk each same-item run.
2. Two-pointer merge: pour from the smallest stack into the largest until the largest reaches `maxStack`, then advance.
3. Emit additional move ops that target an already-occupied destination slot — SortExecutor's pre-check (lines 287–306) already accepts moves onto a same-item partial stack, so no new op type is needed. WoW's native `PickupGuildBankItem` pair handles the merge.
4. After merging, re-emit the contiguous-run move plan so the final layout is `[full, full, ..., partial]` per item.

Idempotence requirement: if the run is already in canonical merged form, the planner must produce zero moves. Add an early-exit check before emitting merge ops.

### 3. Edge cases

- **Cold cache** — `GetMaxStack` returns nil. Skip merging for that item; do not block other items.
- **Mixed-count groups where total < maxStack** — collapse to a single stack.
- **Cycle handling** — merging onto an occupied slot doesn't introduce new cycles because the destination's content (same item) is being absorbed, not displaced. Existing pivot-slot logic in Phase 2 is unaffected.
- **Slot count after merge** — merging reduces the number of overflow slots used; the new contiguous run is shorter. Phase 4's gap-closure pass already handles this.

## Critical files

- `SortPlanner.lua` — Phase 4 block (lines 682–730); add merge sub-phase before contiguous-run emission
- `ItemCache.lua` — extend cached tuple with `stackCount`
- `Scanner.lua` — ensure snapshot population path warms `stackCount` (likely already covered if it goes through ItemCache)
- `spec/sortplanner_spec.lua` — extend the Phase 4 suite (lines 1039–1189)

## Testing

New tests in the existing Phase 4 suite at `spec/sortplanner_spec.lua`:

1. Two partial stacks of same item, sum ≤ maxStack → merge into one stack.
2. Three stacks summing to >1 maxStack → produce `[full, partial]`.
3. Already-merged canonical form → zero moves (idempotence).
4. Cold-cache item (maxStack unknown) → falls back to current grouping, no merge attempted, no error.
5. Mixed-item overflow with one item mergeable and one not → only the mergeable item is touched.

Run: `bash run_tests.sh` and `bash run_tests.sh --lint`.

In-game verification: load the addon, scan the bank, verify multi-stack same-item runs (Healing Potions are the reproducer the user reported), trigger sort, confirm post-sort that same-item stacks are merged to max stack size with at most one trailing partial.
