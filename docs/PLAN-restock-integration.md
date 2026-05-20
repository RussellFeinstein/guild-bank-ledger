# Restock Integration Plan

Integrating Guild Bank Restock (GBR) into GuildBankLedger (GBL) as a new tab.

## Scope

- **In scope:** Guild bank restock only — scan guild bank, manage profiles, kick off Auctionator AH search
- **Out of scope:** Personal context (bags/bank scan) — can be added later
- **Auctionator dependency:** Optional. Tab is visible but shows a "Restock requires Auctionator" notice if the addon is not loaded

## New files

| File | Purpose |
|---|---|
| `src/RestockCategories.lua` | Item lists ported from GBR's `Categories/` folder (Gems, Enchants, Potions, Flasks, Oils, Food, Runes). Each entry has `id`, optional `rank`, optional `qty`, optional `header`. |
| `src/Restock.lua` | Core restock logic: profile management, toBuy calculation, Auctionator search kick-off, guild bank stock state. Registered as a GBL AceAddon module. |
| `UI/RestockView.lua` | New "Restock" tab in GBL's tabbed window. Renders category item lists, profile controls, Bulk/Restock mode toggle, budget field, Start Search button. |

## Files modified

| File | Change |
|---|---|
| `GuildBankLedger.toc` | Add new files to load order (after existing src/ and UI/ entries) |
| `src/Core.lua` | Register RestockView tab; add `/gbl restock` sub-command if needed |
| `src/Storage.lua` | Add `restock` key to AceDB defaults schema |
| `UI/UI.lua` | Wire up the new Restock tab in the tab switcher |

## What is dropped from GBR

- Standalone `GuildBankRestockFrame` and minimap button
- `/restock`, `/bankrestock`, `/rs` slash commands
- `GuildBankRestockDB` saved variables (data migrated or discarded on first load)
- Personal inventory scan (`Personal.lua`)
- `Sidebar.lua` and the Guild/Personal context switcher

## Data model (under `GuildBankLedgerDB`)

```lua
-- Added to AceDB defaults in src/Storage.lua
restock = {
    mode          = "bulk",       -- "bulk" | "restock"
    activeProfile = nil,
    profiles      = {},           -- name -> { ["catIdx_itemIdx"] = targetQty, _inc = {key->true} }
    items         = {},           -- ["catIdx_itemIdx"] -> { enabled, qty, maxPrice }
    budget        = 0,
    rankFilter    = nil,
    guildBankStock = {},          -- itemID -> count (session-only; not persisted)
    guildBankScanned = false,     -- session-only
}
```

## Key design decisions

### Guild bank scanning
GBR's `GuildBank.lua` scan loop (`QueryGuildBankTab` → `GUILDBANKBAGSLOTS_CHANGED` → `GetGuildBankItemLink/Info`) can coexist with GBL's `Scanner.lua`. GBR's scan is a separate, manual "Scan for Restock" pass that writes into `Restock.guildBankStock`. It does NOT replace GBL's transaction scanner. The scan button attaches to the guild bank frame the same way GBR currently does.

### Profile system
Port GBR's `Profiles.lua` logic directly into `src/Restock.lua`. Profiles are per-guild-name (keyed under the guild's AceDB subtable). Functions: `CreateProfile`, `DeleteProfile`, `SetActiveProfile`, `GetProfileTarget`, `SetProfileTarget`, `SaveProfileAs`, `RecalculateToBuy`.

### Auctionator guard
At the top of `StartSearch` (and in the UI when rendering the tab), check:
```lua
if not Auctionator or not Auctionator.API or not Auctionator.API.v1 then
    -- show "Restock requires Auctionator" notice and bail
end
```

### Item categories
`src/RestockCategories.lua` declares a module-level table `GBL_RESTOCK_CATEGORIES` (or exposed via the module's namespace). Structure matches GBR's: array of `{ name = "Label", items = { {id, qty, rank, enabled}, ... } }`. Header sentinel entries `{ header = "Label" }` are preserved for UI grouping.

### Access control
The Restock tab is visible to all guild members (same as sync). The "Start Search" button has no rank gate — any member with the addon installed can use it. (Rationale: restocking the guild bank from your own gold is a personal choice, not an officer action.)

### Saved variable migration
On first load after integration, GBL ignores any existing `GuildBankRestockDB` — no migration. Users will need to re-enter their profiles. This is acceptable because profile data is small and re-entry is fast.

## Implementation order

1. **`src/RestockCategories.lua`** — item lists only, no logic. Easy to verify standalone.
2. **`src/Restock.lua`** — core module: AceDB schema addition, profile functions, toBuy logic, `StartSearch`, event handlers (`COMMODITY_PURCHASE_SUCCEEDED`, `COMMODITY_PURCHASE_FAILED`, `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`), guild bank scan integration.
3. **`UI/RestockView.lua`** — tab renderer: Bulk/Restock toggle, profile nav, category item list with checkboxes/qty/target/toBuy/maxPrice columns, budget field, Start Search button, scan status.
4. **Wiring** — `.toc` load order, `UI/UI.lua` tab registration, `src/Core.lua` slash command if needed.
5. **Tests** — `spec/restock_spec.lua` covering profile logic and toBuy calculation (Auctionator interaction is not unit-testable; cover it with manual verification notes).

## Open questions

- Should the Restock tab be hidden entirely (not just disabled) when Auctionator is absent, or always shown with a notice?
- Should `guildBankStock` be persisted across sessions (so you don't need to re-scan after a `/reload`) or stay session-only?
- Should the scan button on the guild bank frame always appear, or only when the Restock tab has been visited at least once?
- Access control: should there be a guild rank gate on Start Search, matching GBL's sort/layout access model? (Current decision: no gate.)
