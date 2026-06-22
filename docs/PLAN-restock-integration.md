# Restock integration plan (GuildBankRestock into GuildBankLedger)

## Overview

GuildBankRestock (GBR) is being merged into GuildBankLedger (GBL) as a single gated **Restock** tab,
rather than shipping two cooperating addons. GBR's standalone frame, minimap button, slash commands,
Personal context, and per-user profiles are dropped. The Restock tab reads GBL's guild-synced bank
layout and stock reserves in-process, so the whole guild agrees on what to stock without a separate
addon to version.

This document supersedes the earlier integration draft (PR #27). It folds in the decisions locked
with Katorri on 2026-06-17 and a verification pass against GBL v0.33.0.

Intended outcome: an officer with sort access opens the Restock tab, sees each catalog item's
target / in-bank / to-buy, and runs an Auctionator search-and-buy that tops the guild bank up to its
target. Targets come from GBL, not per-user profiles, so the whole guild stocks to the same numbers.

## Locked decisions

- **Merge, not tandem.** Work lives on a long-lived topic branch `restock` off `main` (a fifth area
  alongside `ui`, `sync`, `accessibility`, `layout-sort`).
- **Target formula (Option C):** per-item guild target = `max(layoutDemand(itemID), reserve(itemID))`,
  keyed by itemID, guild-wide. `toBuy = max(0, target - stock)`. Layout demand is the sum of
  `slots * perSlot` over display tabs.
- **Profiles dropped.** GBL's layout plus reserves is the target source, so GBR's per-user profiles
  (positional `catIdx_itemIdx` keys, which break on reorder) are redundant. GBR's Categories are
  ported as the searchable catalog (per-item id, optional rank, default qty, header grouping).
- **No data migration.** `GuildBankRestockDB` is not read; users re-enter any per-item settings.
  Personal context is dropped.
- **Access control.** Running a buy is gated on `GBL:HasSortAccess()`. Setting a target (writing a
  reserve) is gated on `GBL:HasLayoutWrite()`, the same gate the layout already uses. Reserves do not
  affect Sort, so there is no cross-feature surprise.
- **Item coverage.** Items that have a GBL target but are not in the catalog are shown in a synthetic
  group with an "Add to catalog" action.
- **Auctionator** is an optional dependency (the tab shows a notice when it is absent). **TSM** is a
  later, separate optional dependency for price preview.
- **Accessibility** is wired from the first commit (keyboard navigation plus triple encoding). It is
  a v1.0 release gate.

## Branch and versioning model

`restock` is a long-lived topic branch. Each version below is one checkpoint PR from `restock` to
`main` with a single stamp commit at PR-open (the bundle-and-PR rule): bump `VERSION`, the `.toc`
`## Version` field, the `src/Core.lua` `VERSION` constant, move `CHANGELOG.md` `[Unreleased]` into a
versioned block, add a `UI/ChangelogView.lua` `CHANGELOG_DATA` entry, and update the `CLAUDE.md`
`Current:` line. `src/Core.lua` `DEV_BUILD` is set to `"restock"` during development and reset to
`nil` in the stamp commit (CI enforces nil on merge to main; a local `scripts/hooks/pre-push` hook
mirrors the check). Rebase onto `origin/main` at the start of each session and after each merge. Run
`bash run_tests.sh` and `bash run_tests.sh --lint` before every commit (topic branches are not
CI-verified between PRs).

## Ordered roadmap

| Version | Adds | Observable behavior |
|---|---|---|
| v0.34.0 Restock core | Tab, catalog, target/stock/toBuy, restock-to-target, Auctionator buy flow, item coverage, accessibility | Buys layout-pinned items up to `slots*perSlot`. With no reserve UI yet, reserves contribute 0, so behavior is layout-demand-only. |
| v0.35.0 Reserve targets | Inline "set total to store" control (write-gated) calling `SetStockReserve` | Un-pinned items become targetable. Completes Option C. First real producer for the dormant `stockReserves`. |
| v0.36.0 Bulk mode | Bulk/Restock mode toggle plus a qty column | One-off "buy N of X regardless of stock" alongside restock-to-target. |
| v0.37.0 TSM price preview | TSM optional dependency plus market-price and est-cost columns, budget estimate | Pre-search cost preview, with a graceful "(no TSM)" fallback. |

## v0.34.0 milestones

> Naming note: GBL already has `src/Categories.lua` (a classID classifier). The ported lists are a
> catalog: the file is `src/RestockCategories.lua` and the API is `GBL:GetRestockCatalog()`.

### M1 Catalog data
- New `src/RestockCategories.lua`: consolidate GBR's seven `Categories/*.lua` files into one GBL
  module. GBR's `local _, ns = ...; ns.CATEGORIES` vararg pattern does not carry, so inline the data
  as a table on `GBL`.
  - `GBL:GetRestockCatalog()` returns `{ {name, items={ {id, rank?, qty, enabled} | {header} }}, ... }`
    (seven groups; preserve header sentinel rows).
  - `GBL:GetRestockCatalogItemIDs()` returns `{ [itemID]=row }`, flattened, headers excluded, deduped.
  - `rank` is optional (Runes has none); empty groups are tolerated (Food is empty).
- Modified: `GuildBankLedger.toc` (add the file in the Core block); `spec/helpers.lua` (load and
  reset the module).
- Tests `spec/restock_categories_spec.lua`: group count (7) and names, actual per-group counts
  (Gems 40, Enchants 34 items plus 8 header rows, Potions 16, Flasks 8, Oils 2, Food 0, Runes 1),
  rank-optional, empty-group tolerance, dedup and header exclusion.
- Done when busted loads the catalog and returns all seven groups intact.

### M2 Core pure logic and per-guild data model
- New `src/Restock.lua` (pure compute, no AceGUI or Auctionator):
  - `_RestockLayoutDemand(layout)` returns `{itemID=count}` (sum `slots*perSlot` over display tabs).
  - `_RestockAggregateStock(scanResults)` returns `{itemID=count}` (sum `slot.count` across all tabs;
    reuse `BankLayout.ExtractItemID`; a nil scan returns an empty map).
  - `_RestockTarget(itemID, demandMap, reserves)` returns `max(demand or 0, reserve or 0)`.
  - `_restockComputeToBuy(itemID, demandMap, reserves, stockMap)` returns `max(0, target - stock)`.
  - `_RestockBuildItemUniverse(opts)` returns ordered rows decorated with target/stock/toBuy and any
    persisted overrides; a union deduped by itemID of catalog, manually-added, and GBL-target items
    not otherwise present (tagged `source="target"`, the item-coverage requirement).
  - DB accessors: `GetRestockData` (backfill and return), `Get/SetRestockItemOverride(itemID, {enabled, maxPrice})`,
    `Add/RemoveRestockCatalogItem(itemID)`, `Get/SetRestockBudget`.
- Modified `src/Core.lua`: add `restock = { items={}, added={}, budget=0 }` to the `guilds["*"]`
  defaults next to `stockReserves`. AceDB's `["*"]` wildcard backfills the nested table into existing
  guild data, so no `schemaVersion` migration is needed. Add `src/Restock.lua` to the `.toc` after
  `src/BankLayout.lua`; load it in `spec/helpers.lua`.
- Tests `spec/restock_spec.lua`: target is demand-only when reserves are empty; target is
  `max(demand, reserve)` once a reserve is injected (proves Option C layers in with no rework); stock
  aggregation across tabs and a nil scan; toBuy clamps at 0; the universe includes a demand-only item
  not in the catalog; dedup; overrides.
- Done when the toBuy and universe helpers pass for demand-only, reserve-layered, and coverage cases,
  with reserves contributing 0 today.

### M3 View, item coverage, accessibility
- New `UI/RestockView.lua` (a thin shell over the M2 pure logic; mirror `UI/SortView.lua`):
  - `GBL:BuildRestockTab(container)` branches on `self._restock.state`. Initialize the session stub
    `self._restock = { state = "IDLE" }` here so the branch has a value before the search flow
    populates the rest. `GBL:RefreshRestockTab()` guards on `activeTab=="restock"` and rebuilds.
  - `_RestockView_RenderCatalog`: rows showing name (item link) / target / in-bank / toBuy, plus a
    synthetic "Bank targets (not in catalog)" group for `source="target"` rows with an
    "Add to catalog" button.
  - `GBL:GetRestockStatusDisplay(row)`: triple encoding (color plus icon plus text) for the states
    "Buy N", stocked, and over-stocked. Reuse the `UI/Accessibility.lua` palette and icon helpers.
  - Accessibility: call `ClearFocusOrder()` then `RegisterFocusable(widget, order)` in reading order;
    `AdvanceFocus` on Tab and Shift-Tab; `GetScaledFont` on labels. `SetFocusIndicator` currently
    sets a `_focused` flag only; a visible focus ring and the `OnKeyDown` /
    `SetPropagateKeyboardInput` key capture are net-new work here (GBR `Tabs.lua:727-761` is the
    working reference).
- Modified: add `UI/RestockView.lua` to the `.toc` immediately before `UI/UI.lua` (UI.lua must load
  last); load it in `spec/helpers.lua`.
- Tests `spec/ui/restockview_spec.lua` (pure helpers only; the mock `SelectTab` is a no-op, so the
  render path is verified in-game): status display is distinct per state; focus order is populated and
  `AdvanceFocus` wraps; exported-helper reachability (a rename guard).
- Done when, in-game, the catalog and coverage group render behind `HasSortAccess`, "Add to catalog"
  persists, an absent Auctionator shows the notice, and the pure helpers pass busted.

### M4 Tab wiring, Auctionator search/buy flow, docs
- Modified `UI/UI.lua`: add `{value="restock", text="Restock"}` in `RebuildTabs()` after the Sort-tab
  insert, gated on `HasSortAccess`; add an `elseif tabName=="restock"` branch to `SelectTab` calling
  `BuildRestockTab`. The tab set already rebuilds on `GBL_ACCESS_CONTROL_CHANGED`, so the tab appears
  on grant. `src/Core.lua`: add an `elseif command=="restock"` branch to the slash dispatch before
  the final `else`, opening the tab. `.toc`: add `Auctionator` to `## OptionalDeps`. Docs: add the
  three new modules to the `CLAUDE.md` architecture list, and add a Restock tab plus Auctionator
  setup section to `README.md` and `docs/CURSEFORGE-DESCRIPTION.md`.
- Auctionator flow ported into `src/Restock.lua`, fire-and-forget, no standalone frame. Session state
  on the GBL singleton: `self._restock = { state, activeItems, resultRows, bought, skipped,
  pending..., searchGen, runStartMoney }` (not persisted, not synced, must not survive `/reload`).
  States IDLE, SEARCHING, READY, CONFIRMING; tab content swaps per state. Functions mirror GBR:
  - `StartRestockSearch` (Auctionator guard, build the buy list, increment `searchGen`),
  - `_RestockResolveNames` (`Item:CreateFromItemID:ContinueOnItemLoad`, guarded by `searchGen`),
  - `_RestockFireAuctionatorSearch` (`Auctionator.API.v1.ConvertToSearchString` then
    `AuctionatorShoppingFrame:DoSearch`),
  - `_RestockSearchEndListener` (Auctionator EventBus SearchEnd, map rows, go READY),
  - `_RestockBuyNext` (`C_AuctionHouse.StartCommoditiesPurchase`, then the confirm step on
    `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` via `C_AuctionHouse.ConfirmCommoditiesPurchase`),
  - `ResetRestockSearch`.
  Register `COMMODITY_PURCHASE_SUCCEEDED`, `COMMODITY_PURCHASE_FAILED`, and
  `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` lazily in Start and unregister them in Reset; each handler
  guards `state==CONFIRMING`.
- Tests `spec/restock_search_spec.lua` (pure): reset wipes the right fields; next-item skip logic
  (bought, skipped, missing row); result-row pairing by itemID; a stale `searchGen` callback is
  dropped; budget copper math. The Auctionator and AH calls stay fire-and-forget (guarded, not
  unit-tested).
- Done when the tab appears for `HasSortAccess` users and toggles with access and `/reload`,
  `/gbl restock` opens it, and the full search to READY to buy to confirm loop runs in-game.

### M5 Stamp commit (v0.34.0)
A single dedicated commit: bump `VERSION`, the `.toc` `## Version`, the `src/Core.lua` `VERSION`, and
reset `DEV_BUILD` to `nil`; move `CHANGELOG.md` `[Unreleased]` into the version block; add the top
`UI/ChangelogView.lua` `CHANGELOG_DATA` entry (milestone label); update the `CLAUDE.md` `Current:`
line. Done when every artifact reads the same version, `DEV_BUILD` is nil (the CI gate passes), and
`CHANGELOG_DATA[1]` version equals `VERSION`. Then open the checkpoint PR.

## Per-guild restock data model

At `db.global.guilds[g].restock`, all per-guild-local. The guild-consistent part (the targets)
already arrives through the synced `bankLayout` and `stockReserves`, so there is no new sync message.

| Field | Shape | Notes |
|---|---|---|
| `items` | `[itemID] = {enabled, maxPrice?}` (`qty` added in v0.36) | itemID-keyed, not GBR's positional `catIdx_itemIdx` |
| `added` | `[itemID] = true` | manually-added catalog augmentation (item coverage) |
| `budget` | gold cap per run (0 = none) | |

The rank filter is session-only UI state. The in-flight search state (`self._restock`) is session-only
on the singleton and must not survive `/reload`.

## Pure-function core (the testable part)

- `layoutDemand(itemID)` is the sum of `slots*perSlot` over display tabs from `GBL:GetBankLayout()`.
- `reserve(itemID)` is `GBL:GetStockReserves()[itemID] or 0` (dormant until v0.35 adds a producer).
- `target = max(demand, reserve)`.
- `stock(itemID)` is the aggregate of `GBL:GetLastScanResults()` across tabs (GBL auto-scans on bank
  open, so GBR's scan loop is not ported).
- `toBuy = max(0, target - stock)`.
- The displayed universe is catalog, manually-added, and GBL-target-not-in-either, deduped by itemID.

## Risks and gotchas

1. Un-pinned items are unbuyable until v0.35. In v0.34, an item with no layout demand and no reserve
   has target 0. That is expected (the reserve UI is the answer, shipping next). Call it out in the
   v0.34 in-game notes so it does not read as a bug.
2. Positional to itemID reconciliation. GBR keys by `catIdx_itemIdx`; GBL keys everything by itemID.
   Dedup the universe by itemID (an item can be both catalog and layout-pinned).
3. Reserves are dormant (first consumer). `GetStockReserves()` is empty in the wild; tests must inject
   reserves to prove the `max()` layering.
4. Stock lags purchases. Bought items land in the buyer's bags, not the bank; `toBuy` only drops after
   deposit plus rescan. This is inherited GBR behavior.
5. Commodity-only. `StartCommoditiesPurchase` works for commodities only; surface non-commodity
   catalog items gracefully (found but unbuyable).
6. The mock `SelectTab` is a no-op, so the render path is not testable in busted. Keep the view a thin
   shell over pure helpers and test those.
7. The accessibility indicator is net-new. The visible focus ring and key capture are real work in M3
   (a v1.0 gate).
8. Background events versus active tab. Update `self._restock` unconditionally; guard
   `RefreshRestockTab` on `activeTab=="restock"` (mirror `_SortView_OnProgress`).
9. Cold scan. If the bank has not been opened this session, `GetLastScanResults()` is nil and all
   stock reads as 0, so `toBuy` equals the full target. The view should offer a "scan the bank first"
   affordance so a cold cache does not read as "buy everything."

## Verification

- Busted (CI): `spec/restock_categories_spec.lua`, `spec/restock_spec.lua`,
  `spec/ui/restockview_spec.lua`, `spec/restock_search_spec.lua`, plus per-version specs for later
  versions. Run `bash run_tests.sh` and `bash run_tests.sh --lint` before each commit.
- In-game (with `DEV_BUILD="restock"`): the tab is gated by `HasSortAccess` and toggles on
  grant/revoke and a cold-roster `/reload`; `/gbl restock` opens it; the catalog renders with async
  names; the coverage group shows a pinned non-catalog item and "Add to catalog" persists; the
  Auctionator search to READY to buy to confirm loop runs; the budget cap stops the run; closing
  mid-search aborts cleanly; an absent Auctionator shows the notice; Tab and arrow keys cycle focus
  and the triple-encoded status reads without color; toBuy is unchanged until deposit plus rescan.

## Source being ported

GBR (v0.9.13) is the source. Key files for the port:

- `Categories/*.lua` (seven files): the catalog data, ported into `src/RestockCategories.lua`.
- `GuildBankRestock.lua`: the search and buy orchestration and the AH event handlers.
- `UI.lua`: the buy button calling `C_AuctionHouse.StartCommoditiesPurchase`.
- `Tabs.lua:727-761`: the working keyboard-nav mechanism (OnKeyDown plus
  `SetPropagateKeyboardInput`), the reference for M3's net-new key capture.
- `Profiles.lua`: the positional profile system, dropped (GBL targets replace it).

## GBL reuse points (read, not edited)

- `src/BankLayout.lua`: `GetBankLayout`, `GetStockReserves`, `SetStockReserve`, `ExtractItemID`.
- `src/Scanner.lua`: `GetLastScanResults`.
- `src/Core.lua`: `HasSortAccess`, `HasLayoutWrite` (and `IsGuildMaster`).
- `UI/SortView.lua`: the closest existing tab template.
- `UI/Accessibility.lua`: focus helpers and triple-encoding palette/icons.
