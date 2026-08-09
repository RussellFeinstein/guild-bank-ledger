# Data model

What GuildBankLedger actually stores, as opposed to what the AceDB defaults block declares.

The two are not the same, and neither one is readable on its own. The defaults declare keys that
never reach disk, the record builders assign fields that are nil in practice, and several structures
are created lazily by code far from the declaration. This document is the reconciliation, written so
the next person does not have to derive it from the defaults, the builders, eleven migrations and a
7 MB SavedVariables file at the same time.

Everything below was checked against a live SavedVariables file (12,310 transaction records, 2026-04-07
to 2026-08-07) as well as against the code. Where the two disagree, the stored data is treated as
authoritative and the disagreement is written down rather than resolved.

## 1. The two SavedVariables

Both live in one file, `WTF/Account/<id>/SavedVariables/GuildBankLedger.lua`.

**`GuildBankLedgerDB`** is the AceDB store. Everything the addon records about a guild hangs off
`global.guilds["<Guild Name>"]`. It is account-wide, so a player's alts share one copy.

**`GuildBankLedgerAuditDB`** is a raw global, deliberately not AceDB and deliberately not guild-keyed.
Its collection unit is the account's SavedVariables file, and each session carries player, realm and
guild in its own header. See the Conventions section of `CLAUDE.md` for why it must not be migrated
into AceDB. Shape:

```
GuildBankLedgerAuditDB = {
  schemaVersion = <n>,
  sessions = {                          -- 10-session rotation, oldest out
    { addonVersion, protocolVersion, player, realm, guild, startedAt,
      dropped = { sync = <n>, sort = <n>, system = <n> },
      entries = { sync = { {ts, level, message}, ... }, sort = {...}, system = {...} } },
    ...
  },
}
```

## 2. What is stored per guild

Thirteen keys reach disk:

| Key | Shape |
|---|---|
| `transactions` | Array of item transaction records (section 4) |
| `moneyTransactions` | Array of money transaction records (section 4) |
| `seenTxHashes` | `[full record id] = true`. Dedup membership set (section 5) |
| `eventCounts` | `[prefix .. hourSlot] = {count, asOf}`. Dedup ground truth (section 5) |
| `playerStats` | `[player] = {withdrawals, deposits, totalWithdrawCount, totalDepositCount, moneyWithdrawn, moneyDeposited, firstSeen, lastSeen}` |
| `playerRealms` | `[bareName] = realm`, or `false` when the bare name is ambiguous in the roster |
| `knownPeers` | `[canonical peer key] = {version, txCount, lastSeen}`. Written by `UpdatePeer`, `src/Sync.lua:2472` |
| `syncState` | `{lastSyncTimestamp, syncVersion, peers}`. See the name collision in section 6 |
| `accessControl` | `{rankThreshold, restrictedMode, configuredBy, configuredAt}` |
| `sortAccess` | `{rankThreshold, delegates, updatedBy, updatedAt}`. Two-tier sort policy |
| `bankLayout` | `{version, updatedBy, updatedAt, tabs}`. Tabs keyed by index, items keyed by itemID |
| `stockReserves` | `[itemID] = count` |
| `schemaVersion` | Integer. See section 7 |

### Keys that are declared but absent, and why that is normal

AceDB strips any value equal to its default before the SavedVariables file is written
(`removeDefaults`, `Libs/AceDB-3.0/AceDB-3.0.lua:134`). An empty table default that was never
modified therefore leaves no trace on disk. **Absence from the file means "never diverged from the
default", not "missing".** At runtime the key is present, because `copyDefaults` puts it back.

Seven declared keys are absent from the live file for that reason:

| Key | Status |
|---|---|
| `dailySummaries`, `weeklySummaries` | Tiered-storage compaction never ran. Being retired, issue #62 |
| `snapshots` | Never written |
| `teams` | Never written |
| `altLinks` | Alt linking is designed but unbuilt, issue #52 |
| `stockAlerts` | Reserved for planned v1.3.0 low-stock alerts. Comment at `src/Core.lua:94-96`. Do not repurpose |
| `restock` | Guild-local restock settings. Appears on first use |

### `eventCounts` is the reverse case

It is stored on disk but **not** declared in the defaults. It is created lazily at
`src/Dedup.lua:405` and `src/Sync.lua:2196`, and every reader nil-guards it (`src/Core.lua:2701-2702`,
`src/Dedup.lua:427`, `:443`), so nothing breaks. The asymmetry worth knowing is that an undeclared
key is never subject to default-stripping, so `eventCounts` is always written out verbatim while a
declared-and-empty key never is.

## 3. Two structures share the name `peers`

This is the single easiest thing to get wrong when reading the sync code.

- **`guildData.syncState.peers`** is persisted, and holds `{lastSync, stored}` per peer.
- **`syncState.peers`** in `src/Sync.lua` is a module-local runtime table, and holds
  `{version, txCount, dataHash, lastScanTime, lastSeen}` per peer. Written by `GBL:UpdatePeer`
  (`src/Sync.lua:2460`). It is not saved.

The persisted record of what version a peer runs is **`knownPeers`**, not either of the above.

## 4. Record shapes

Two builders, `GBL:CreateTxRecord` and `GBL:CreateMoneyTxRecord` (`src/Ledger.lua:79` and `:131`).
The builders assign a fixed set of fields, but several are nil in practice and Lua drops nil keys, so
the shapes on disk are narrower than the builders suggest.

**Money record**, always 8 keys:

```lua
{ type = "withdraw", player = "Speaknglide-Area52", amount = 10000000,
  timestamp = 1775580307, scanTime = 1775587507, scannedBy = "Rexxybear-Tichondrius",
  _occurrence = 0, id = "withdraw|Speaknglide-Area52|10000000|493216:0" }
```

**Item record**, 12 to 17 keys. The measured distribution across all 12,310 transaction records:

| Count | Shape |
|---|---|
| 3,978 | Item, locally scanned deposit or withdraw. 13 keys, no tab fields |
| 3,417 | Item, locally scanned move. 17 keys, all tab fields present |
| 3,349 | Money. 8 keys |
| 621 | Item, synced move. 16 keys, no `itemLink` |
| 614 | Item, synced deposit or withdraw. 12 keys, no `itemLink`, no tab fields |
| 223 | Item, corrupted on arrival. See section 8 |
| 108 | Item with no `itemID`, 105 of them with an empty `itemLink`. See section 8 |

Three fields behave differently from the rest and account for most of the variation:

- **`tab` is only ever set on `move` records.** `ReadTabTransactions` (`src/Ledger.lua:255`) passes
  the API's `tab1` return value through to the builder (`:266-269`), and WoW only populates
  `tab1`/`tab2` for moves. The loop's own `tab` argument, which is the tab actually being read, is
  never recorded. So no deposit or withdraw record knows which tab it happened in. `destTab` and
  `destTabName` follow the same rule.
- **`itemLink` and `category` do not cross the wire.** `stripForSync` removes them, and only
  `category` is recomputed on arrival, and only when `itemID` and `classID` are both present
  (`src/Sync.lua:1173`). Money records never get it back. `tabName` and `destTabName` are also
  stripped and are refilled later by `BackfillTabNames`.
- **`scannedBy` carries a `sync:` prefix on anything received from a peer**, and the bare form
  (`"Rexxybear"` rather than `"Rexxybear-Tichondrius"`) appears on 961 records written before
  2026-04-13. Those are historical. Current writes are always realm-qualified.

## 5. Identity and dedup

Record identity is the triple **(prefix, hourSlot, occurrence)**, serialized into `record.id`:

```
record.id = prefix .. hourSlot .. ":" .. occurrence
```

`buildPrefix` (`src/Dedup.lua:39-51`) has two forms and picks by whether `itemID` is set:

```
items:  type|player|itemID|count|tab|
money:  type|player|amount|
```

Three structures key off this, differently, and the differences are load-bearing:

| Structure | Key | Purpose |
|---|---|---|
| `record.id` | prefix + hourSlot + `":"` + occurrence | Identity of one event |
| `seenTxHashes` | the **full id, including `:occurrence`** | Have we stored this exact event |
| `eventCounts` | prefix + hourSlot, **no occurrence suffix** | How many events legitimately share a prefix |

`_occurrence` is **positional**: it is assigned in local scan order, not derived from the event. That
is why the prefix fields are hard to change. Remove a field from the prefix and identity starts
depending on the order a client happened to scan in, so two peers can each accept the other's record
as already held and converge on different data. Anything that changes `buildPrefix` changes every id
ever stored, and needs a migration and a wire-fixture update.

Two consequences of the current prefix that are worth knowing:

- Because `tab` is nil on deposits and withdrawals, `buildPrefix` coerces it to `0`. Two deposits of
  the same item and count by the same player in the same hour into two different tabs share a prefix
  and are separated only by occurrence.
- An item record with no `itemID` falls through to the **money** branch, so its prefix is
  `type|player|0|` and it collides with every other such record from the same player, type and hour.
  108 records on the live file are in this state.

## 6. Timestamps

`timestamp` is the event time, computed from the relative offsets `GetGuildBankTransaction` returns.
`scanTime` is when this client stored the record, and on a synced record it is receipt time rather
than the sender's scan time. The `hourSlot` inside an id is `floor(timestamp / 3600)`, so it is hour
granular by construction.

`IsValidTimestamp` (`src/Dedup.lua:18`) rejects anything outside the WoW era at the storage boundary.
Test fixtures use `3600 * 475100` and up for this reason.

When a synced record arrives with an id but no timestamp, `reconstructSyncRecord` recovers the
timestamp as `hourSlot * 3600`, which is the start of the hour rather than the original moment.

## 7. The schema ladder, and why the default is 8

`schemaVersion` defaults to **8** (`src/Core.lua:122`) even though migrations exist through 11. This
reads as a stale value and it is not one. Do not raise it.

The 9 to 10 and 10 to 11 migrations gate on **strict equality**, not `>=`:

```lua
if not guildData or (guildData.schemaVersion or 0) ~= 9  then return 0 end   -- src/Core.lua:1371
if not guildData or (guildData.schemaVersion or 0) ~= 10 then return 0 end   -- src/Core.lua:1479
```

Both sites carry comments explaining it. Several migrations short-circuit when the realm APIs are
cold, returning 0 without bumping the version, and the next session retries them. A loose `>=` gate
would let a guild sitting at 8 jump straight to 11 on a session where a later migration happened to
run first, permanently skipping the intermediate work. Strict equality forces the chain to be walked
in order, and 8 is its entry point. `GUILD_ROSTER_UPDATE` retriggers `MigrateAllGuilds` once per
session so a cold-roster short-circuit gets a warm retry without waiting for the next login.

## 8. What validation guarantees, and what it does not

Sync intake performs exactly two checks (`src/Sync.lua:1186-1187`):

```lua
if not record.type   or record.type   == "" then return false end
if not record.player or record.player == "" then return false end
```

There is no enum check on `type`, no shape check, and no cross-field check. A record whose `type`
reads `"wN260370"` is accepted.

The comment above those lines already names the failure it exists to catch: AceSerializer can mangle
field boundaries in transit, producing spliced keys like `typyer` from `type` and `player`. What was
not known until this document is how often it happens and what gets through.

**Measured on the live file: 223 of 1,912 records received via sync (11.66%) carry at least one
mangled key name. Zero of 10,398 locally scanned records do.** The damage is consistent: a prefix of
one key name joined to a suffix of another, with the original key lost.

| Observed key | Count | Real field it replaced |
|---|---|---|
| `timessID` | 102 | `subclassID` |
| `timestampID` | 93 | `subclassID` |
| `stamp` | 19 | nothing, added alongside a complete record |
| `typyer`, `typeer`, `typeyer`, `typ`, `typtemID`, `typelassID`, `subclsID`, `timesD`, `categornTime` | 1 each | assorted |

Sorted by what was lost: 195 records lost only `subclassID`, 22 lost nothing, and 6 lost `type`
together with several other fields. Seventeen ended up with a `type` outside the six-value enum
(`deposit`, `withdraw`, `move`, `repair`, `buyTab`, `depositSummary`), eleven of those having no
`type` key at all. Six of the seventeen kept a non-empty `type` and a non-empty `player`, so the
guard above would still accept them today.

Two things this does **not** establish:

- **It is not fixed.** The newest corrupted record was received 2026-05-22 20:13 UTC, and the newest
  record of any kind received via sync was 2026-05-22 20:19 UTC, six minutes later. Nothing has
  arrived via sync since. The absence of recent corruption is explained by the absence of recent
  sync intake, not by a repair.
- **The mechanism is a hypothesis.** The splice pattern is consistent with a lost AceComm fragment
  producing a payload that still deserializes into a valid table, which would fit the documented
  per-fragment drop rate, but it has not been traced. Treat it as the leading candidate, not a
  finding.

All 223 are item-shaped. No money record is affected, though a corrupted money record that lost its
`amount` would be indistinguishable from an item record that lost its `itemID`, so read that as "none
detected" rather than "none occurred".

The 105 records with an empty `itemLink` (section 4) are a separate and untraced issue: all 105 were
scanned locally rather than received, so they are not part of the above.

## 9. Numeric keys cross the wire untested

`stockReserves` is `[itemID] = count` and `bankLayout.tabs[].items` is keyed by itemID. Both are sent
between clients. The spec mock serializer is pass-through (`spec/mock_ace.lua:162` returns
`"SER:<n>"` and stashes the table), so **no test proves numeric keys survive a real AceSerializer
round trip**, and no test measures real payload size. Both are verified in-game only.

`_RestockBuildItemUniverse` and the layout editor already number-coerce their keys, which is a
symptom of this: a synced layout that arrived string-keyed would otherwise fail to match number-keyed
stock.

## Open questions

Recorded here so they are not rediscovered from scratch:

- Why deposits and withdrawals do not record the tab being read, and what fixing it would cost, given
  that it moves every affected record id.
- Whether the key-splicing corruption is a lost AceComm fragment, and whether intake should validate
  against a key whitelist rather than two non-empty fields.
- Why 105 locally scanned records carry an empty `itemLink`.
