# Data model

What GuildBankLedger actually stores, as opposed to what the AceDB defaults block declares.

The two are not the same, and neither one is readable on its own. The defaults declare keys that
never reach disk, the record builders assign fields that are nil in practice, and several structures
are created lazily by code far from the declaration. This document reconciles them, written so the next
person does not have to derive it from the defaults, the builders, eleven migrations and a 7 MB
SavedVariables file at the same time.

Everything below was checked against a live SavedVariables file (12,310 transaction records, 2026-04-07
to 2026-08-07) as well as against the code. Where the two disagree, the stored data is treated as
authoritative.

The first pass wrote the disagreements down without resolving any of them. Each one now carries a
verdict instead: the issue that closes it, or the reason it is being left alone. They are collected
under the **Data model integrity** milestone. A disagreement in this document with no verdict is a gap
in the document, not a gap in the tracker.

## 1. The two SavedVariables

Both live in one file, `WTF/Account/<id>/SavedVariables/GuildBankLedger.lua`.

**`GuildBankLedgerDB`** is the AceDB store. Everything the addon records about a guild hangs off
`global.guilds["<Guild Name>"]`. It is account-wide, so a player's alts share one copy.

One key sits beside `guilds` rather than inside it: **`global.characters`**, `[Name-Realm] = lastSeen`,
written by `RecordOwnCharacter` (`src/Core.lua`) for the logged-in character on every
`GUILD_ROSTER_UPDATE` once the realm resolves, and never for the `"UnknownRealm"` sentinel. It is the
account's own characters and nothing else, so the Member view can show a person every character they
play rather than the one they are on (#222, `docs/PLAN-views-and-access.md` section 7). Account level
rather than per guild, on the reasoning #52 records: a character's home is the account, the guild is
where its rows are. It fills as characters log in and is never backfilled, because nothing on disk
says which of a guild's names belong to this account. It is never transmitted: the HELLO payload is
built from a literal in `src/Sync.lua` that does not name it, and nothing else reads it. Note that
HELLO is the one message type `spec/wire_contract_spec.lua` holds to builder parity rather than to an
absolute key set, so that spec would not catch a field added to both builders.

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
| `seenTxHashes` | `[full record id] = timestamp`. Dedup membership set (section 5). `GBL:MarkSeen` (`src/Dedup.lua`) stores the record's timestamp as the value, or the current server time when that timestamp is invalid |
| `eventCounts` | `[prefix .. hourSlot] = {count, asOf}`. Dedup ground truth (section 5) |
| `playerStats` | `[player] = {withdrawals, deposits, totalWithdrawCount, totalDepositCount, moneyWithdrawn, moneyDeposited, firstSeen, lastSeen}` |
| `playerRealms` | `[bareName] = realm`, or `false` when the bare name is ambiguous in the roster |
| `knownPeers` | `[canonical peer key] = {version, minSyncVersion, txCount, lastSeen}`. Written by `GBL:UpdatePeer` (`src/Sync.lua`) on every HELLO it handles. `InitSync` drops expired entries and re-keys the rest to canonical names, and `ConsolidatePeerKeys` re-keys them again after a roster update |
| `syncState` | `{lastSyncTimestamp, syncVersion, peers}`. See the name collision in section 3 |
| `accessControl` | `{rankThreshold, restrictedMode, configuredBy, configuredAt}` |
| `sortAccess` | `{rankThreshold, delegates, updatedBy, updatedAt}`. Two-tier sort policy |
| `bankLayout` | `{version, updatedBy, updatedAt, tabs}`. Tabs keyed by index, items keyed by itemID. Overflow-mode tabs may carry an optional numeric `overflowPriority` (fill order, lower first; layout schema 2, #57). `tabs[].name` is a capture-time snapshot of `GetGuildBankTabInfo`, used as a fallback for display and never as the tab's name: a rename in the bank does not reach it, and nothing rewrites it (#236) |
| `stockReserves` | `[itemID] = count` |
| `schemaVersion` | Integer. See section 7 |

### Keys that are declared but absent, and why that is normal

AceDB strips any value equal to its default before the SavedVariables file is written
(`removeDefaults` in AceDB-3.0, whose committed copy is `spec/vendor/AceDB-3.0.lua`). An empty table default that was never
modified therefore leaves no trace on disk. **Absence from the file means "never diverged from the
default", not "missing".** At runtime the key is present, because `copyDefaults` puts it back.

Every claim in this section is asserted by `spec/savedvariables_spec.lua` from #77, which
is why the counts below are worth keeping exact: the seventeen declared keys, the four that
are absent when untouched and the thirteen that survive once they diverge are each pinned,
and so is the arithmetic between them, so a key added to the defaults block and to neither
list fails the suite. Those cases run against a hand port of AceDB in `spec/mock_ace.lua`,
and eleven more run the same defaults through a real AceDB from `spec/vendor/` and compare
what each side leaves behind, because a port can only ever agree with itself.

Four declared keys are absent from the live file for that reason. `dailySummaries` and
`weeklySummaries` left this list when #62 removed their declarations along with the tiered
storage module, and `snapshots` left it when #71 removed its declaration, since no code path
had ever written it:

| Key | Status |
|---|---|
| `teams` | Reserved for the planned Teams feature (raid team assignment). Nothing writes it yet. Comment in the defaults block in `src/Core.lua`. Do not repurpose |
| `altLinks` | Alt linking is designed but unbuilt, issue #52 |
| `stockAlerts` | Reserved for the planned low-stock alerts feature. Comment in the defaults block in `src/Core.lua`. Do not repurpose |
| `restock` | Guild-local restock settings: `items`, `budget`, and from #209 `pending[itemID] = { qty, unconfirmedQty, buyer, buyers, at, unconfirmedAt }`, purchases not yet seen in the bank. Appears on first use. #215 split the one quantity in two and dropped the stored `unconfirmed` boolean, which `GBL:_RestockPendingParts` derives; that function also reads the pre-split shape (`qty` plus the boolean) as wholly unconfirmed, so no migration runs over entries already on disk. **The accepted cost is a rollback**: the first write to an entry brings it onto the new shape, and a pre-#215 build reads `qty` alone, so a parked purchase reads as zero pending and the row is offered again. That matters here because the repo is symlinked into AddOns while CurseForge serves whatever was last tagged, so running an older build is a real state rather than a hypothetical one. Not defended against, because defending it means keeping the boolean beside the quantity for a release and that is the two-sources-for-one-fact shape the split exists to remove |

`stockAlerts` was the model #71 followed for `teams`: a reserved key with a comment naming what
reserves it is fine, and a reserved key without one is indistinguishable from an oversight. Neither
comment carries a version. The one on `stockAlerts` dated the feature to a release `docs/ROADMAP.md`
had since given to alt linking, so #71 dropped it rather than chase it, since the reservation is what
matters.

### `eventCounts` was the reverse case, until #71

It was stored on disk but **not** declared in the defaults. It is created lazily in
`StoreBatchRecords` (`src/Dedup.lua`) and `HandleSyncData` (`src/Sync.lua`), and every reader
nil-guards it, so nothing broke. An undeclared key is never subject to default-stripping, so
`eventCounts` was always written out verbatim, empty or not.

**#71 declared it**, because it is dedup ground truth rather than an incidental cache. That changed
one observable thing: an empty `eventCounts` no longer reaches disk, because it is default-stripped
like every other declared key. Its absence from a file now means no count was ever kept, and is not a
regression. Two more properties are pinned against the port and against a real AceDB. A guild already
holding counts keeps them through a logout and the next login. And a read of a key the table does not
hold answers nil and stores nothing, because the template is an empty table with no wildcard. An entry
template declared the way `playerStats` declares one would break only the second: every slot
`CleanupWithEventCounts` probes would gain a zero entry, and the serve path, which walks the table with
`pairs`, would offer those zeros to peers.

The lazy creates and the nil-guards stay, although no production state reaches them now: every guild
table the addon reads comes from AceDB, which puts the key back. What still reaches them is spec
fixtures, two specs that set a guild's `eventCounts` to nil deliberately and the guild tables other
specs build by hand. Removing the guards means re-fixturing those specs first, which #71 left alone.
`CleanupWithEventCounts` also guards `next()`, which stays load-bearing whatever the defaults say.

## 3. Two structures share the name `peers`

This is the single easiest thing to get wrong when reading the sync code.

- **`guildData.syncState.peers`** is persisted, and holds `{lastSync, stored}` per peer.
- **`syncState.peers`** in `src/Sync.lua` is a module-local runtime table, and holds what each
  peer last advertised: `{version, minSyncVersion, txCount, dataHash, lastScanTime, lastSeen}`, plus
  `outdated` and `versionRelation` once a protocol or version check has refused that peer.
  `GBL:UpdatePeer` writes the full entry on each HELLO. Three other writers fill in around it:
  `InitSync` seeds entries from `knownPeers`, without `dataHash` or `lastScanTime`; `OnSyncMessage`
  creates a minimal `{lastSeen, txCount}` entry for a peer heard before its HELLO, and a full one
  marked outdated for a HELLO on another protocol version; and `HandleHello` marks a version
  refusal. It is not saved.

The persisted record of what version a peer runs is **`knownPeers`**, not either of the above.

**Verdict: being resolved, issue #72.** The inventory done for that issue turned up something the first
pass missed: **the persisted table is write-only.** `FinishReceiving` in `src/Sync.lua` is the one
site that writes it, and nothing in `src/`, `UI/` or `spec/` reads its values except to rewrite its
keys. Two migrations in `src/Core.lua` do that, `MigrateNormalizePeerNames` (which reads `lastSync`
only to decide which of two colliding keys survives) and `MigrateRecoverPeerRealms`, and the specs
that touch the table are those two migrations' tests. So those migrations canonicalize a table nobody
consults. Its sibling `syncState.lastSyncTimestamp` does have readers by contrast: `FinishReceiving`
writes it, and `HandleHello` and `FinishSending`'s bidirectional check each hand it to `RequestSync`,
which sends it as the request's `sinceTimestamp`. The serving side filters on that only in its
fallback for a request with no bucket hashes, which `SendSyncRequestTo` produces only when it has no
guild data, so it is read and transmitted more than it decides anything. So the resolution may be a
retirement rather than a rename, which would remove the collision outright instead of moving it. The
runtime table, for what it is worth, lives entirely in `src/Sync.lua` and is never saved, so renaming
that side needs no migration at all. Direction is #72's call.

## 4. Record shapes

Two builders, `GBL:CreateTxRecord` and `GBL:CreateMoneyTxRecord`, both in `src/Ledger.lua`.
The builders assign a fixed set of fields, but several are nil in practice and Lua drops nil keys, so
the shapes on disk are narrower than the builders suggest.

**Money record**, always 8 keys:

```lua
{ type = "withdraw", player = "Speaknglide-Area52", amount = 10000000,
  timestamp = 1775580307, scanTime = 1775587507, scannedBy = "Rexxybear-Tichondrius",
  _occurrence = 0, id = "withdraw|Speaknglide-Area52|10000000|493216:0" }
```

**Item record**, 12 to 17 keys. The measured distribution across all 12,310 transaction records in
the 2026-08-07 file, which predates v0.37.0 and so predates the tab fix in the first bullet below:

| Count | Shape |
|---|---|
| 3,978 | Item, locally scanned deposit or withdraw. 13 keys, no tab fields |
| 3,417 | Item, locally scanned move. 17 keys, all tab fields present |
| 3,349 | Money. 8 keys |
| 621 | Item, synced move. 16 keys, no `itemLink` |
| 614 | Item, synced deposit or withdraw. 12 keys, no `itemLink`, no tab fields |
| 223 | Item, corrupted on arrival. See section 8 |
| 108 | Item with no `itemID`, 105 of them with an empty `itemLink`. See sections 5 and 8 |

Three fields behave differently from the rest and account for most of the variation:

- **`tab` was only ever set on `move` records before v0.37.0**, which is what the table above
  measured. `GetGuildBankTransaction(tab, i)` takes the tab whose log is being read as its first
  argument, and returns `tab1`/`tab2` as the move pair, source and destination. A move is the only
  transaction that spans two tabs, so it is the only one that needs them; a deposit or withdraw
  happened in the tab already being read, and WoW returns nil for both. `ReadTabTransactions`
  (`src/Ledger.lua`) used to pass `tab1` straight through to the builder, so `record.tab` meant
  "source tab of a move" and was nil on everything else. The tab actually being read is the
  function's own `tab` parameter, in scope at the call site, and it was never recorded. So no deposit
  or withdraw record stored before v0.37.0 knows which tab it happened in, and none carries a
  **`tabName`** either, since `CreateTxRecord` derives that from `tab`. `destTab` and `destTabName`
  are set on moves only, and still are.

  **Verdict: fixed forward in v0.37.0, issue #67.** `ReadTabTransactions` passes `tab1 or tab`, so a
  deposit or withdraw scanned since then carries the tab it happened in, as `tab` and `tabName`, and
  the tab is in the identity prefix. That is why it rode the MIN_SYNC_VERSION floor release (#74),
  where the compatibility break was already being paid. Two seams came with it and are accepted
  rather than fixed: records stored before it stay tabless forever, since their true tab was never
  written anywhere and cannot be recovered, so historical deposits never match a tab filter while new
  ones do; and one event could briefly appear twice while old-form and new-form ids coexisted,
  bounded by WoW's roughly 25-entry per-tab log window. `BackfillTabNames` cannot repair the old
  ones, because there is no tab number to derive a name from.
- **`itemLink` and `category` do not cross the wire.** `stripForSync` (`src/Sync.lua`) removes them,
  along with `tabName`, `destTabName`, `scanTime`, `scannedBy` and `_occurrence`. On arrival
  `reconstructSyncRecord` rebuilds `category` from `classID` and `subclassID` for every item record
  it accepts, because since #68 (v0.37.0) `RepairSyncRecordItemFields` runs first and refills a
  missing `classID` or `subclassID` from the `itemID`. `itemLink` is never rebuilt, and money records
  carry no category. `tabName` and `destTabName` are refilled later by `BackfillTabNames`.
- **`scannedBy` carries a `sync:` prefix on anything received from a peer**, and the bare form
  (`"Rexxybear"` rather than `"Rexxybear-Tichondrius"`) appears on 961 records written before
  2026-04-13. Those are historical. Current writes are always realm-qualified.

## 5. Identity and dedup

Record identity is the triple **(prefix, hourSlot, occurrence)**, serialized into `record.id`:

```
record.id = prefix .. hourSlot .. ":" .. occurrence
```

`buildPrefix` (a file-local in `src/Dedup.lua`, exposed as `GBL:BuildTxPrefix`) has two forms and
picks by whether `itemID` is set:

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

- `buildPrefix` coerces a nil `tab` to `0`, and before v0.37.0 `tab` was nil on every deposit and
  withdrawal. So two deposits of the same item and count by the same player in the same hour into two
  different tabs shared a prefix and were separated only by occurrence. Closed by #67, which is what
  made that change identity affecting and therefore floor-bound. Records stored before it keep the
  `0`: their `tab` is still nil, and any rebuild of their ids reads the field.
- An item record with no `itemID` falls through to the **money** branch, so its prefix is
  `type|player|0|` and it collides with every other such record from the same player, type and hour.
  108 records on the live file are in this state. **Issue #69 owns both halves**, the scan-side cause
  and the 108 already stored, and it is deliberately unscheduled: the remedy depends on the cause, and
  if a cold item cache turns out to be it then a deferred re-read is right and deleting them would be
  wrong. Not in the Data model integrity milestone, so it does not block v1.0.

  Two things limit the damage while it waits. The same shape arriving over the wire is rejected by
  #68's shape discriminator, which requires exactly one of `itemID` or `amount`, so the population
  cannot grow through sync. And #75 repairs the sync-received records that lost `itemID` as part of its
  own sweep. Neither touches these 108, which were all scanned locally.

### One identity namespace, two arrays

Records live in two arrays but identity is pooled. `seenTxHashes` (`GBL:MarkSeen` in
`src/Dedup.lua`), `eventCounts` (`StoreBatchRecords` in `src/Dedup.lua`), the fingerprint
accumulator and its buckets (`ComputeDataHash`, `ComputeBucketHashes` and the sliced
`StepBucketHashScan` in `src/Fingerprint.lua`) and the `idIndex` that `HandleSyncData` builds at the
top of each chunk (`src/Sync.lua`) all walk `transactions` and `moneyTransactions` into one flat
structure with no namespace tag. `BuildStoredRecordIndex` (`src/Dedup.lua`) is the only one that
takes a `storageKey`, so it is the exception rather than the rule.

Nothing about that pooling is wrong on its own, because `buildPrefix` gives items five pipe fields
and money three, and a player name cannot contain a pipe. Well-formed item and money ids cannot
collide. It matters only in combination with the `itemID` fallthrough above: a record that reaches
the money branch by accident lands in a shared namespace rather than an item-only one.

The reachable consequence is in `GBL:NormalizeRecordId` (`src/Sync.lua`), which adopts the
sender's id for a local record it looks up as `idIndex[matchedKey]` and never checks which array
that record came from. An incoming item record with no `itemID` that prefix-matches a stored money
record would overwrite that money record's `id`, `_occurrence` and `timestamp`, and then be counted
as a duplicate and dropped. One event silently loses its identity and another is discarded.
**Verdict: closed by #68 rather than here.** Its shape check requires exactly one of `itemID` or
`amount`, and a record that lost its `itemID` has neither, so it is rejected at intake and never
reaches this path. Recorded because the hazard is in the receive path, not in #68's stated subject,
and its test list should cover it.

### The type string is identity, and normalized only on the local path

`type` is the first field of both prefixes. The money log is the one place where the API disagrees
with itself: `GetGuildBankMoneyTransaction` returns `"withdrawal"` where `GetGuildBankTransaction`
returns `"withdraw"` for the same user action. `CreateMoneyTxRecord` (`src/Ledger.lua`) rewrites it
in its first statement, before `ComputeTxHash` runs, so `"withdraw"` is what goes into every money
id ever stored.

**Verdict: correct as it stands, and not cosmetic.** The differing record shapes do not make the
string cosmetic, because nothing downstream reads the shape before reading the type. Every consumer
matches the stored string exactly and not one of them accepts both spellings: player stats
(`UpdatePlayerStats` in `src/Ledger.lua`, once for items and once for money), six sites in
`UI/ConsumptionView.lua` (three in `BuildConsumptionSummary`, one each in `ComputeGoldLogSums`,
`GetPlayerItemBreakdown` and `BuildGuildItemSummary`), both type dropdowns in `UI/UI.lua` (the one
`BuildGoldLogTab` builds and the one in `CreateFilterWidgets`), and the filter equality test in
`MatchesFilters` (`UI/FilterBar.lua`). An
un-normalized record therefore contributes 0 to every money total and matches no filter. That
silent zeroing is
the v0.4.1 bug the normalization fixed, and it is why a spec pins the builder as well as the read
path (`spec/ledger_spec.lua`).

It also fails accessibility in all three channels at once, which is worth stating separately given
that triple encoding is a v1.0 gate. `GetTxTypeDisplay` (`UI/Accessibility.lua`) resolves
color by comparison, icon by `A11Y.ICONS[txType]` and label by `A11Y.TX_LABELS[txType]`, so an
unrecognized type falls to `NEUTRAL`, a nil icon and the raw string as its own label. Color, shape
and text degrade together, which is exactly the failure triple encoding exists to prevent.

Changing any of this is identity affecting. `"withdraw"` is already in every stored money id, so
un-normalizing would need a migration, a wire-fixture update and a floor raise, and would leave a
permanent bucket-hash mismatch against un-migrated peers in the meantime: the bucket key is parsed
from the id's `|<hourSlot>:<occurrence>` suffix (`bucketKeyForRecord` in `src/Fingerprint.lua`, through
the shared `RECORD_ID_SLOT` pattern), so a type-only
change moves no record between buckets while changing its hash contribution, and the affected
bucket re-syncs forever without converging.

Two smaller points follow from the same normalization:

- **It widens the degenerate collision above, but does not cause it.** Before normalization an
  itemID-less item `withdraw` and a money `withdrawal` differed in their first prefix field.
  Afterwards they do not. `deposit` was already shared, since both APIs emit it verbatim, so the
  root cause is the `itemID` fallthrough and not the rewrite.
- **Sync intake did not normalize, and still does not.** Before #68, intake checked only that `type`
  was non-empty (section 8) and nothing inspected the value, so a `"withdrawal"` record from a peer
  would have been stored verbatim. No such record existed or could arrive: the census found zero
  across all 12,310 stored records, no tagged release ever shipped the un-normalized code (the money
  feature landed in v0.2.0 and the fix in v0.4.1 with no tag between them, the earliest tag in the
  repo being v0.5.0-alpha), the concurrent money-tab-index bug in the same commit meant money never
  loaded at all for a guild with fewer than eight tabs, and the exact version match `HandleHello`
  enforced at the time ruled out a mixed-version peer. **Verdict: closed by #68's enum check in
  v0.37.0.** `validateSyncRecord` (`src/Sync.lua`) rejects a type outside `VALID_RECORD_TYPES`, and
  `"withdrawal"` is not in it. That matters more since the same release replaced the exact match
  with a version floor, because peers on different releases now exchange records. Rejection is the
  right treatment rather than normalizing on intake, because no legitimate sender of that string can
  exist.

## 6. Timestamps

`timestamp` is the event time, computed from the relative offsets `GetGuildBankTransaction` returns.
`scanTime` is when this client stored the record, and on a synced record it is receipt time rather
than the sender's scan time. The `hourSlot` inside an id is `floor(timestamp / 3600)`, so it is hour
granular by construction.

`GBL:IsValidTimestamp` (`src/Dedup.lua`) accepts a number at or after `MIN_VALID_TIMESTAMP`
(2004-01-01, before WoW launched) and nothing else; there is no upper bound. A record that fails it
is not rejected. `StoreTx` and `StoreMoneyTx` replace its timestamp with the current server time,
and `reconstructSyncRecord` does the same on the sync path before either of them sees it. Test
fixtures use `3600 * 475100` and up so that they sit well above the floor.

When a synced record arrives with an id but no timestamp, `reconstructSyncRecord` recovers the
timestamp as `hourSlot * 3600`, which is the start of the hour rather than the original moment.

## 7. The schema ladder, and why the default is 8

`schemaVersion` defaults to **8** (the `defaults` table at the top of `src/Core.lua`) even though
migrations exist through 11. This
reads as a stale value and it is not one. Do not raise it.

The reason is AceDB before it is anything about the migration chain. `removeDefaults` strips any scalar
equal to its default before writing, and `copyDefaults` puts **the current default** back on load
for any key the stored table does not hold (both in AceDB-3.0; `spec/vendor/AceDB-3.0.lua` is the
committed copy). So every guild sitting at exactly 8 has no
`schemaVersion` in its file at all, and takes whatever the defaults block says next login. **The
default value is the stored value of every guild at that version.** Raising it to 11 does not skip a
warning, it silently advances all of those guilds to 11 without running migrations 9, 10 or 11, and
there is no later pass that notices. All three are realm canonicalization, and the loss is permanent.

The mechanism is executable from #77. `spec/savedvariables_spec.lua` round-trips a guild at
the default and reads 8 back with nothing on disk in between, and round-trips one at 11 and
finds 11 on disk, which is this paragraph as two assertions. **That file is the guard against
the default being raised**, and it shipped in PR #261 under #77. #76 shipped the other half,
`spec/schema_version_spec.lua`, which pins the ladder the default is the entry point to. Raising
the default reds the first file and leaves the second green, which is the split to expect.

The migration chain is the second half of the story. The 8 to 9, 9 to 10 and 10 to 11 migrations
gate on **strict equality**, not `>=`:

```lua
if not guildData or (guildData.schemaVersion or 0) ~= 8  then return 0 end   -- MigrateNormalizePeerNames
if not guildData or (guildData.schemaVersion or 0) ~= 9  then return 0 end   -- MigrateNormalizeStoredRealms
if not guildData or (guildData.schemaVersion or 0) ~= 10 then return 0 end   -- MigrateRecoverPeerRealms
```

Both sites carry comments explaining it. Several migrations short-circuit when the realm APIs are
cold, returning 0 without bumping the version, and the next session retries them. A loose `>=` gate
would let a guild sitting at 8 jump straight to 11 on a session where a later migration happened to
run first, permanently skipping the intermediate work. Strict equality forces the chain to be walked
in order, and 8 is its entry point. `GUILD_ROSTER_UPDATE` retriggers `MigrateAllGuilds` once per
session so a cold-roster short-circuit gets a warm retry without waiting for the next login.

**The 8 to 9 migration joined the strict pair in #263**, and the reason is worth keeping.
`MigrateNormalizePeerNames` gated on `>= 9`, the loose form every rung below it uses, so called on
its own it would advance a guild at 3 straight to 9. Nothing did call it that way, because
`MigrateAllGuilds` reaches it only at 8, but that left the **call order** as the only thing
protecting the low half of the ladder, and the call order is not what a reader checks when they
change a gate. It is `~= 8` now, and `spec/schema_version_spec.lua` asserts the order as a sequence
as well, because a guild that jumped straight to 11 also arrives at 11.

`MigrateOccurrenceScheme` was also the one loose gate reading `guildData.schemaVersion >= 2` with
no `or 0`, where the other seven read `(guildData.schemaVersion or 0) >= N`. Because it is rung 1,
a nil version raised there and took the whole walk with it. Closed in #263.

**Verdict: correct as it stands, and pinned by tests as of 2026-09-24.** This is the one
disagreement in this document that must not be resolved by making the two sides agree. Two files
carry it and it is worth knowing which does what, because they fail on different mutations.
`spec/savedvariables_spec.lua` (#77, PR #261) asserts the value and its round trip against a real
AceDB, so it is what reds if the default is raised. `spec/schema_version_spec.lua` (#76, extended by #263) asserts
the ladder the default is the entry point to: walked one rung at a time in order, each rung
bumping by exactly one, every write of the version that is not a rung, and that one guild's
failure does not strand the rest of the walk. Its sequence assertion is also what reds if a strict
gate is loosened to `>=`, since a guild above a gate is refused by both forms and only the ladder
sees the rung that then gets skipped. The below-the-rung side of the gates is covered in
`spec/core_spec.lua` (each "refuses to bump from schema 8", plus a "from schema 9" on the 10 to 11
migration). Neither file changes the default, which stays as it is.

One write is not a rung. It sits inside one, so "outside the ladder" is the wrong axis: what
matters is whether a write advances the progression. There were two until #263.

`MigrateCrossSlotDedup` **is** rung 5, and its first statement past its own gate drops the version
to 4 so its pass 1 can re-run the same-slot dedup, whose own gate is `>= 5`, then
leaves at 6. That write is deliberate and load-bearing: without it the nested call is entered at 5,
returns 0, and pass 1 silently does nothing.

**`GBL:DeduplicateRecords` was the second, and #263 removed it.** It set the version to 5 to
force that same legacy pass and was written to restore it afterwards, guarded by
`if savedSchema > 6` inside a branch entered only below 6, so the restore could never fire and
`MigrateCrossSlotDedup` left the guild at 6 wherever it started. The harm window was 1 to 3,
measured: from 4 or 5 the forced write lost nothing, because the nested 4 to 5 pass still ran and 6
is where the ladder would have left the guild anyway, while from 3 the forced 5 satisfied
`MigrateOccurrenceToPerSlot`'s `>= 4` gate before it ever ran and no later pass revisited it. The
same line raised on a nil version, because the gate read `(x or 0)` and the compare read the raw
value.

**The reachability argument is the part worth carrying, because the first version of it was
wrong.** It was written as "unreachable in production" on the strength of a measurement that no
migration below 6 has a non-bumping early return, so once `MigrateAllGuilds` has run no guild is
left under 6 (every start from 0 to 8, cold realm, cold roster). That measurement holds. The claim
built on it did not, because it assumed the ladder completes. `MigrateAllGuilds` walked
`pairs(guilds)` unprotected, AceAddon runs `OnEnable` under `safecall`, and the bank-open events
are registered before the ladder runs while the slash commands are registered earlier still. So a
raise in one guild left every later guild unmigrated and silent, and `GBL:OnBankOpened` or
`GBL:RunCleanup` could then hand one of them to `DeduplicateRecords`. **A branch is only
unreachable given everything upstream of it succeeds**, which is not a property a walk over
player data has for free.

#263 fixed the cause rather than the consumer: each guild migrates under `pcall` now, a failure is
named once per guild per session on the system channel (grep `Migration failed`) and in chat, the
hash cache is reset because a raise can leave it warm over ids a half-run rung rewrote, and the
walk carries on. `DeduplicateRecords` is the nil guard plus `CleanupWithEventCounts`, which is what
its own doc comment always claimed.

**`OnEnable` walks every guild twice, and isolating one walk is not isolating the startup.** The
dedup pass four lines below the ladder is the second walk, and the corruption class that makes a
rung raise reaches it too: `BuildTxPrefix` concatenates `record.player` and `ComputeTxHash` divides
`record.timestamp`, so a record holding a table or a nil where either belongs raises there as well.
With only the ladder isolated, the guild whose migration had just been caught re-raised one
statement later, the error left `OnEnable` through `safecall` exactly as before, and `InitSync` plus
every registration below it never ran. `GBL:DeduplicateAllGuilds` is that walk under the same
isolation (grep `Dedup pass failed`). The rule the pair leaves: **nothing in either loop may read
the guild table outside the protection**, or the isolation has a hole at its own first statement,
which is how the entry-version read was found.

Two limits the isolation left, both filed with their measurements, and one of them is now closed.
**#265, fixed in v0.41.11**: rungs 7 and 10 rewrote `record.id` and never called
`ResetHashCache`, and both caches in `src/Fingerprint.lua` key on the guild table and the record
count (the dataset hash has keyed on the table as well only since #276), and a rewrite in place
moves neither, so an id rewrite was invisible to them and the guild advertised a fingerprint of a
dataset that no longer existed. Each rung resets at its exit now, conditional on
the same flag that gates its `seenTxHashes` rebuild. Beside the two behavioural pins,
`spec/schema_version_spec.lua` section 8 carries a structural case that reads which ladder rungs
write `record.id` out of `src/Core.lua` and holds each of them to the contract, so a rung added
later cannot repeat this, and a refactor that routes the rewrites through a shared helper reds it
rather than passing having checked nothing. **#266**: a guild whose migration raises partway through either of those two rungs is left
with `seenTxHashes` keyed on the pre-rewrite ids, so `IsDuplicate` misses on every rewritten record
and sync re-imports the guild's own transactions from a peer.

That one reads like a defect the isolation created and it is not, which is worth keeping straight.
`GUILD_ROSTER_UPDATE` re-runs `MigrateAllGuilds` once per session (`self._migrationsRetried`) and
that fires long after `OnEnable` finished, so a guild the cold-realm short-circuit left at 8 runs
rungs 9, 10 and 11 with sync already live. CallbackHandler's `Dispatch` is unprotected, so a raise
there abandons the rest of the handler and surfaces as a client Lua error at most; it cannot undo
`InitSync`. The stale index has therefore been reachable on that path for as long as the retrigger
has existed. What the isolation changed is the `OnEnable` path, where the raise used to take
`OnEnable` down with it and keep that guild out of sync entirely: a much worse failure that happened
to mask this one. So the isolation widened the reach of a pre-existing defect rather than inventing
one, and the guild it now exposes is one that previously never migrated and never synced on any
login.

It is filed rather than fixed because both candidate repairs are larger than #263: extract the index
rebuild that rungs 7 and 10 and `CleanupWithEventCounts` each inline (three sites, none of them
identical, in a PR about isolation), or quarantine a guild in `_migrationFailed` from sync, which
needs a decision about what such a guild advertises on HELLO.

## 8. What validation guarantees, and what it does not

Before #68 (v0.37.0), sync intake performed exactly two checks, at the end of
`reconstructSyncRecord` (`src/Sync.lua`):

```lua
if not record.type   or record.type   == "" then return false end
if not record.player or record.player == "" then return false end
```

There was no enum check on `type`, no shape check, and no cross-field check, so a record whose `type`
read `"wN260370"` was accepted. What intake checks now is in the verdict at the end of this section.

The comment above those two lines named the failure they existed to catch: AceSerializer can mangle
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
`type` key at all. Six of the seventeen kept a non-empty `type` and a non-empty `player`, so those
two checks accepted them.

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
scanned locally rather than received, so they are not part of the above. Issue #69.

### How much of this is a live problem, and how much is cosmetic

The first pass did not separate the two, and the split matters because it decides what has to be fixed
and what merely could be. The line is `buildPrefix` (`src/Dedup.lua`), which reads `type`, `player`,
`itemID`, `count` and `tab` on item records and nothing else.

**The 195 that lost only `subclassID` still have ids that agree with their fields.** `subclassID` is
not in the prefix. Same for the 19 that gained a `stamp` key and lost nothing, and the 22 that lost
nothing at all. These cost a few bytes on re-send and are otherwise inert.

**The roughly 17 with a corrupt or missing `type` are live inconsistency.** Their `buildPrefix` output
disagrees with the id they carry, so `BuildStoredRecordIndex` (`src/Dedup.lua`) files them
under a prefix matching no id, `CountFromRecordIndex` undercounts, and `CleanupWithEventCounts` reasons
about a group of one. Anything that lost `itemID` is in the same class by a different route: it flips
to the money branch and collides.

### There is a recovery channel

`record.id` begins with `type` and `player` as its first two pipe-delimited fields, and it was computed
by a healthy sender before transmission. So a record that lost its `type` can usually get it back from
its own id. That holds only if `CleanupWithEventCounts` (`src/Core.lua`) has not already rebuilt the
id from the corrupt fields, which it does to every record of the guild whenever it removes anything.
That is the first thing to check before relying on it.

### The reject counter counts rejections as duplicates

Before #68, `HandleSyncData` incremented `itemDuped` when `reconstructSyncRecord` returned false, and
`moneyDuped` for a money record. No log, no counter, no warning. So total rejection was
indistinguishable from perfect convergence: the `Redundancy from <peer>` line would read 100% duped,
which the decision rule in `.claude/rules/sync.md` reads as redundancy worth designing a finer-grained
exchange for (its `>70%` band), when the peer had sent nothing the receiver could store. Every
redundancy reading taken before v0.37.0 is inflated by the rejection rate.

Since #68 a reject is counted apart from duplicates, per chunk and for the session, and counted again
under the field whose check failed. The end of the receive names both in a WARN line
(`Rejected N record(s) from <peer>: <fields>`), and the SYNC_RECEIPT sent back to the peer carries
them, because the peer holding the records is the only side that can act on them.

**Verdict: split across two issues.** #68 hardened intake in v0.37.0. `reconstructSyncRecord` now
opens with `RepairSyncRecordItemFields`, which recomputes a missing `classID` or `subclassID` from
`itemID` (where `CreateTxRecord` gets them anyway), and then `validateSyncRecord`, which rejects on
three checks: `type` in the six-value enum, exactly one of `itemID` or `amount`, and the known fields
holding the right type. #75 will repair what is already stored, using the same repair helper and the
id recovery channel above, deleting only records whose id is also unusable and taking their
`seenTxHashes` entries with them.

**Rejected: validating against a key whitelist.** The first pass listed this as the obvious fix and it
is the wrong one. Unknown keys passing through untouched is what makes the record schema
forward-extensible: `stripForSync` shallow-copies through `pairs()` and `buildPrefix` reads only fields
it names, so adding a field is free today. A whitelist would convert every future additive field into a
compatibility break requiring a floor raise. The garbage keys stay on the record, where nothing reads
them. Removing the twelve specific observed key names is a different and safe thing, and #75 treats it
as optional.

## 9. Numeric keys cross the wire, and now they are tested

The spec mock serializer is pass-through (`serializerMixin` in `spec/mock_ace.lua`: `Serialize` stashes the table
and returns `"SER:<n>"`, `Deserialize` hands the same table object back), so for the project's whole
life no test encoded a byte. Numeric key survival and payload size were in-game claims only.

**Closed in v0.36.1 by golden wire-contract fixtures.** `spec/wire_contract_spec.lua` runs a real
AceSerializer (`spec/vendor_helpers.lua` loads it, stashing and restoring the mock LibStub registry
around the load). `src/Sync.lua` exposes the record codec through `_StripForSync`,
`_ReconstructSyncRecord` and `_EstimateRecordBytes`, which have no production callers and exist only
so the format can be pinned. Numeric keys do survive, as numbers, with no string-keyed twin.

The library is a committed copy under `spec/vendor/`, not the `Libs/` tree: `Libs/` is gitignored and
fetched by the packager from `.pkgmeta` externals, so it exists only where the packager has run and
CI has none. Compression is deliberately out of the harness, since LibDeflate is a byte-exact codec
this addon neither configures nor extends. Payload size is therefore pinned as serialized bytes,
which is the figure `estimateRecordBytes` is documented against; the compressed size that governs
fragment count is measured live as `syncState.lastChunkBytes`.

**The scope named here was too narrow.** This section used to name `stockReserves` and
`bankLayout.tabs[].items`, both of which ride LAYOUT_DATA, a rare pull. The larger exposure is the
fingerprint bucket tables: `bucketKeyForRecord` (`src/Fingerprint.lua`) returns
`math.floor(...)`, a number, so `bucketHashes` on SYNC_REQUEST is numeric-keyed and crosses the wire
on **every sync**. (MANIFEST carried a second numeric-keyed `buckets` table until v0.37.6 retired it; the
SYNC_REQUEST half is unaffected, because it is computed independently and was never fed by the
manifest.) Had those degraded to strings, every bucket
comparison would miss, every sync would resend everything, and the symptom would be a high duplicate
rate, which is the one reading the redundancy line already cannot be trusted to explain.

`_RestockBuildItemUniverse` and the layout editor number-coerce their keys, which was a symptom of
the untested boundary rather than a fix for it.

**`bucketHashes` stopped being the whole picture in v0.37.11 (#108).** It kept its name, its numeric
keys and its meaning, but it now carries only the newest `SYNC_REQUEST_DETAIL_BUCKETS` (50) buckets.
Everything older rides a second field, `spans`: an array of `{ s, e, h }` where `s` and `e` are
bucket keys bounding a range and `h` is that range's fold. The spans tile
`[oldest key .. detailStart-1]` with no gaps, so a bucket the requester has never held still falls
inside a declared range on the serving side and shows up as a fold mismatch rather than slipping
through an uncovered hole. The request is therefore 58 entries at any history depth, where it used
to be one per bucket forever and had already crossed the whisper reliability ceiling.

`spans` is an array, so its own keys are numeric too, and they have to stay that way or `ipairs`
would walk nothing and every span would be skipped, which reads as "no spans declared" and quietly
falls back to offering all of old history. The wire fixture pins both tables.

The fold is order-dependent djb2 over `(key, hash)` pairs, **not** XOR (`GBL:FoldBucketRange`,
`src/Fingerprint.lua`). Bucket hashes are themselves XOR aggregates, so XORing them together
collapses to a single XOR over every record in the range, and two peers each holding records the
other lacks can then compute matching span folds over genuinely different data. Both sides recompute
that deterministically every session, so such a divergence would never be offered again: it is the
same cancellation objection that rejected prefix-only record hashing, one level up.

No floor raise accompanied the change. A peer that predates it sends a full `bucketHashes` and no
`spans`, and every key the spans do not cover takes the comparison this code has always made, so
both shapes are live on the wire at once.

Two facts the fixtures established that were not previously written down:

- **AceSerializer escapes a space to a two-byte sequence, and an unescaped space is dropped on
  decode.** Guild names contain spaces and ride every envelope, so the escape path runs constantly.
  Production is always correct here because it always serializes properly; the hazard is hand-built or
  externally-produced payloads, which is why the fixtures are generated rather than typed.
- **`estimateRecordBytes` really is an upper bound on real serialized size**, for every record shape
  in the fixture set. That claim had never been checked. It holds because record fields cannot contain
  the characters AceSerializer doubles, while pipes and colons, which ids are full of, pass through
  unescaped.

**Scope limit worth knowing.** The fixtures pin the copy in `spec/vendor/`. The packaged zip pulls
its libraries from upstream at package time per `.pkgmeta` `externals`, so an upstream AceSerializer
change is outside what these tests can guarantee. `spec/fixtures/generate_wire_fixtures.lua` narrows
that gap by diffing the vendored copy against `Libs/` whenever a developer has one.

### One dead key found while pinning the builders

HELLO, SYNC_DATA and BUSY were each built in two places, and the fixtures assert the pairs agree under
identical state. Doing that turned up a key that could never be set. The empty-chunk SYNC_DATA builder
wrote `eventCounts = batches[1]`, but the loop just above it extended the chunk list until
`#chunks >= #batches`, so reaching the `#chunks == 0` branch already implied `#batches == 0`. A send
that has event counts and no records routes through the other path instead and emits an empty chunk
from there. The dead write went with the packing rewrite in v0.37.3, and the branch is still reachable
with no event counts at all, so the two call sites' key sets still legitimately differ by `eventCounts`
and the parity assertion still has to allow for it.

**SYNC_DATA and BUSY now have one builder each** (`GBL:BuildSyncDataMessage`, `GBL:BuildBusyMessage`),
which is what #70 asked for. HELLO is untouched and remains a genuine pair, which is the part of that
issue's concern still open: its title named SYNC_DATA and BUSY only, and the floor release edits both
of its builders.

Collapsing a pair changes what a parity test can prove, and the fixtures were reshaped for it in the
same change. Two emitted messages compared to each other only mean something while two independent
builders exist; once both call sites read from one, a field dropped from the builder is dropped from
both and they still agree. That was measured rather than assumed: removing `guild` from
`BuildBusyMessage` left all 1660 tests green. So the shared-builder types now carry a hand-written
absolute key set, with the parity assertion kept beside it to catch a call site being re-inlined or
handed the wrong arguments.

There was a second untested boundary of the same kind, and it was the larger one. `spec/mock_ace.lua`
modelled AceDB's read path (`applyDefaults`) and had no `removeDefaults` at all. Default
stripping is the mechanism behind every claim in section 2 and behind the schemaVersion result in
section 7, and the suite could check none of it.

**Closed in #77.** Both halves of AceDB are transcribed from the library branch for branch
now, `removeDefaults` and `copyDefaults` alike, with `_simulateLogout` and `_simulateLogin`
on the mock db to express a session boundary. Three read-path gaps went with it, and the
one worth remembering is that the mock built a vivified table by deep-copying the
template, which copies the literal `"*"` key into it, so every `guildData.playerStats` in
the suite held a phantom player that no client can have. Seven production sites walk that
table with `pairs`, four of them inside migrations, and two resolve every name they find and
write it back (the `playerStats` merge in `MigrateSchemaV2ToV3`, and the one in
`RepairPlayerNames`, which is not a migration; both in `src/Core.lua`). So one migration had been storing a
resolved phantom for as long as the mock has existed. Nothing went red when it
disappeared, because nothing had ever asserted what that table contains, only what the
fixtures put in it.

## Open questions

One is left. The other two are answered, recorded here with their answers so they are not reopened
from scratch.

**Still open, and deliberately unscheduled: why 105 locally scanned records carry an empty
`itemLink`.** A cold item-info cache at scan time is the leading candidate, which would make a deferred
re-read the right remedy rather than skipping what are real transactions. Untraced, and worth tracing
before choosing, so it wants a capture rather than a fix. Issue #69, outside the milestone. The
population cannot grow through sync (#68 rejects the shape at intake), which is what makes leaving it
safe.

**Answered: the tab on deposits and withdrawals.** Recorded going forward by #67 since v0.37.0, which
rode the floor release because it is identity affecting. Old records cannot be back-filled: their true tab was never
written anywhere. See section 4 for the two seams that come with it.

**Answered: whether intake should validate against a key whitelist.** No. See section 8. The mechanism
behind the splicing is still a hypothesis, and deliberately so: the validation in #68 checks the
outcome rather than the hypothesis, so it is correct whether or not a lost AceComm fragment turns out
to be the cause. Each rejection is counted under the field whose check failed, and the receive's
WARN line and its SYNC_RECEIPT name those fields, so the evidence builds up as sync runs rather than
needing another archaeology pass. The field named is the check that failed, not the spliced key
itself: unknown keys pass intake untouched by design (section 8), so a garbage key alone is never a
reason to reject.

## Where the disagreements are tracked

All under the **Data model integrity** milestone.

| Section | Disagreement | Issue |
|---|---|---|
| 2 | `dailySummaries`, `weeklySummaries` declared, never written | closed (#62): keys and module removed |
| 2 | `snapshots`, `teams` declared, never written | closed (#71): `snapshots` removed, `teams` reserved for the Teams feature |
| 2 | `altLinks` declared, never written | #52 |
| 2 | `eventCounts` written, never declared | closed (#71): declared |
| 3 | Two structures named `peers`, the persisted one write-only | #72 |
| 4 | No deposit or withdraw record knows its tab | closed in v0.37.0 (#67) |
| 5 | Item records with no `itemID` collide in the money branch | #69 (locally scanned, unscheduled); sync-received closed in v0.37.0 (#68) |
| 5 | `NormalizeRecordId` can rewrite a money record from an item record | closed in v0.37.0 (#68) |
| 5 | Sync intake does not normalize the money `type` | closed in v0.37.0 (#68): rejected by the enum check |
| 7 | Nothing stops the `schemaVersion` default being raised | closed in #76 |
| 7 | `DeduplicateRecords` cannot restore the version it borrows, and raises on a nil | closed in #263 |
| 7 | One guild's failed migration strands every guild after it in the walk | closed in #263 |
| 8 | Intake accepts corrupted records | closed in v0.37.0 (#68) |
| 8 | 223 corrupted records already stored | #75 |
| 8 | Rejections counted as duplicates | closed in v0.37.0 (#68) |
| 9 | Numeric keys and payload size untested across the wire | closed in v0.36.1 |
| 9 | AceDB's write path unmodelled in the suite | closed in #77 |
| 9 | `eventCounts` is unreachable where the empty-chunk SYNC_DATA builder writes it | dead write closed in v0.37.3 |
| 9 | SYNC_DATA and BUSY each built in two places | closed in v0.37.13 (#70); HELLO still a pair |
| - | Per-player category totals declared, never accumulated | #64 |

The compatibility break several of these rode was #74, **and it has now been spent.** v0.37.0 shipped
the version floor along with #67 and #68. Two peers on different releases now sync, so any later
change to `buildPrefix` would silently duplicate the guild's dataset unless `MIN_SYNC_VERSION` is
raised again, and raising it re-imposes the lockstep split the floor removed. Treat every remaining
identity-affecting idea in this document as costing a forced guild-wide update from here on.

What that leaves open, in rough order of how much it still hurts: #75 (the 223 damaged records
already on disk, which #68 stops growing but does not repair, and which can now reuse
`GBL:RepairSyncRecordItemFields`), #69 (the same itemID-less shape produced by local scans rather
than by sync, still unscheduled), #72 and #64. None of those touch record
identity, so none of them cost a floor raise.
