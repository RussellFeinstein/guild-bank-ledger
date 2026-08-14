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
| `syncState` | `{lastSyncTimestamp, syncVersion, peers}`. See the name collision in section 3 |
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
| `snapshots` | Never written by any code path. Remove or annotate as reserved, issue #71 |
| `teams` | Never written by any code path. Remove or annotate as reserved, issue #71 |
| `altLinks` | Alt linking is designed but unbuilt, issue #52 |
| `stockAlerts` | Reserved for the planned low-stock alerts feature. Comment at `src/Core.lua:94-96`. Do not repurpose |
| `restock` | Guild-local restock settings. Appears on first use |

`stockAlerts` is the model for the other two: a reserved key with a comment naming what reserves it is
fine, and a reserved key without one is indistinguishable from an oversight. Its own comment does need
a small correction, which belongs with #71 since that issue is already editing this block: it dates the
alerts feature to v1.3.0, while `docs/ROADMAP.md` has stock alerts at v1.5.0 and v1.3.0 is alt linking.
Drop the version from the comment rather than chase it, since the reservation is what matters.

### `eventCounts` is the reverse case

It is stored on disk but **not** declared in the defaults. It is created lazily at
`src/Dedup.lua:405` and `src/Sync.lua:2196`, and every reader nil-guards it (`src/Core.lua:2701-2702`,
`src/Dedup.lua:427`, `:443`), so nothing breaks. The asymmetry worth knowing is that an undeclared
key is never subject to default-stripping, so `eventCounts` is always written out verbatim while a
declared-and-empty key never is.

**Verdict: being declared, issue #71.** This is dedup ground truth rather than an incidental cache, so
the tidy move is the right one. Declaring it changes one observable thing: an empty `eventCounts` stops
reaching disk, because it starts being default-stripped like every other declared key. Harmless given
the nil-guards, and recorded here so the next person does not read that absence as a regression. The
nil-guards stay regardless. Three specs set the key to nil deliberately, and `src/Core.lua:2701-2702`
guards `next()` rather than nil, which stays load-bearing whatever the defaults say.

## 3. Two structures share the name `peers`

This is the single easiest thing to get wrong when reading the sync code.

- **`guildData.syncState.peers`** is persisted, and holds `{lastSync, stored}` per peer.
- **`syncState.peers`** in `src/Sync.lua` is a module-local runtime table, and holds
  `{version, txCount, dataHash, lastScanTime, lastSeen}` per peer. Written by `GBL:UpdatePeer`
  (`src/Sync.lua:2460`). It is not saved.

The persisted record of what version a peer runs is **`knownPeers`**, not either of the above.

**Verdict: being resolved, issue #72.** The inventory done for that issue turned up something the first
pass missed: **the persisted table is write-only.** It is written at exactly one site
(`src/Sync.lua:2335`, in `FinishReceiving`) and its values are read nowhere in `src/`, `UI/` or
`spec/`. The only other code that touches it is two migrations rewriting its keys
(`src/Core.lua:1345`, `:1548`), so those migrations canonicalize a table nobody consults. Its sibling
`syncState.lastSyncTimestamp` is genuinely live by contrast (written `:2333`, read `:1032`, `:2038`,
`:2644`). So the resolution may be a retirement rather than a rename, which would remove the collision
outright instead of moving it. The runtime table, for what it is worth, is 25 occurrences across 23
lines of one file with no persisted state, so renaming that side needs no migration at all. Direction
is #72's call.

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
| 108 | Item with no `itemID`, 105 of them with an empty `itemLink`. See sections 5 and 8 |

Three fields behave differently from the rest and account for most of the variation:

- **`tab` is only ever set on `move` records.** `GetGuildBankTransaction(tab, i)` takes the tab whose
  log is being read as its first argument, and returns `tab1`/`tab2` as the move pair, source and
  destination. A move is the only transaction that spans two tabs, so it is the only one that needs
  them; a deposit or withdraw happened in the tab already being read, and WoW returns nil for both.
  `ReadTabTransactions` (`src/Ledger.lua:255`) passes `tab1` through to the builder (`:266-269`), so
  `record.tab` means "source tab of a move" and is nil on everything else. The tab actually being read
  is the function's own `tab` parameter, in scope at the call site and never recorded. So no deposit or
  withdraw record knows which tab it happened in. `destTab` and `destTabName` follow the same rule, and
  so does **`tabName`**, which `src/Ledger.lua:95` derives from the same nil. `BackfillTabNames` cannot
  repair it, because there is no tab number to derive a name from.

  **Verdict: being fixed forward, issue #67.** The true tab goes into `record.tab`, which puts it in
  the identity prefix, so it rides the MIN_SYNC_VERSION floor release (#74) where the compatibility
  break is already being paid. Two seams come with it and are accepted rather than fixed: old records
  stay tabless forever, since their true tab was never written anywhere and cannot be recovered, so
  historical deposits never match a tab filter while new ones do; and one event can briefly appear
  twice while old-form and new-form ids coexist, bounded by WoW's roughly 25-entry per-tab log window.
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
  and are separated only by occurrence. Closed by #67, which is what makes that change identity
  affecting and therefore floor-bound.
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

Records live in two arrays but identity is pooled. `seenTxHashes` (`src/Dedup.lua:127-130`),
`eventCounts` (`src/Dedup.lua:405`), the fingerprint accumulator and its buckets
(`src/Fingerprint.lua:70-76`, `:129-145`) and the `idIndex` that `HandleSyncData` builds
(`src/Sync.lua:2129-2135`) all walk `transactions` and `moneyTransactions` into one flat structure
with no namespace tag. `BuildStoredRecordIndex` (`src/Dedup.lua:219-228`) is the only one that
takes a `storageKey`, so it is the exception rather than the rule.

Nothing about that pooling is wrong on its own, because `buildPrefix` gives items five pipe fields
and money three, and a player name cannot contain a pipe. Well-formed item and money ids cannot
collide. It matters only in combination with the `itemID` fallthrough above: a record that reaches
the money branch by accident lands in a shared namespace rather than an item-only one.

The reachable consequence is in `NormalizeRecordId` (`src/Sync.lua:2071-2095`), which adopts the
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
returns `"withdraw"` for the same user action. `CreateMoneyTxRecord` rewrites it
(`src/Ledger.lua:133`), before `ComputeTxHash` runs, so `"withdraw"` is what goes into every money
id ever stored.

**Verdict: correct as it stands, and not cosmetic.** The differing record shapes do not make the
string cosmetic, because nothing downstream reads the shape before reading the type. Every consumer
matches the stored string exactly and not one of them accepts both spellings: player stats
(`src/Ledger.lua:229`, `:238`), daily summaries (`src/Storage.lua:101`, `:111`), six sites in
`UI/ConsumptionView.lua` (`:92`, `:101`, `:118`, `:192`, `:356`, `:420`), both type dropdowns
(`UI/UI.lua:623`, `:1441`), and the filter equality test (`UI/FilterBar.lua:105`). An
un-normalized record therefore contributes 0 to every money total, matches no filter, and is
deleted at day 30 by compaction with nothing folded into the summary first. That silent zeroing is
the v0.4.1 bug the normalization fixed, and it is why a spec pins the builder as well as the read
path (`spec/ledger_spec.lua`).

It also fails accessibility in all three channels at once, which is worth stating separately given
that triple encoding is a v1.0 gate. `GetTxTypeDisplay` (`UI/Accessibility.lua:218-233`) resolves
color by comparison, icon by `A11Y.ICONS[txType]` and label by `A11Y.TX_LABELS[txType]`, so an
unrecognized type falls to `NEUTRAL`, a nil icon and the raw string as its own label. Color, shape
and text degrade together, which is exactly the failure triple encoding exists to prevent.

Changing any of this is identity affecting. `"withdraw"` is already in every stored money id, so
un-normalizing would need a migration, a wire-fixture update and a floor raise, and would leave a
permanent bucket-hash mismatch against un-migrated peers in the meantime: the bucket key is parsed
from the id's `|<hourSlot>:<occurrence>` suffix (`src/Fingerprint.lua:106-116`), so a type-only
change moves no record between buckets while changing its hash contribution, and the affected
bucket re-syncs forever without converging.

Two smaller points follow from the same normalization:

- **It widens the degenerate collision above, but does not cause it.** Before normalization an
  itemID-less item `withdraw` and a money `withdrawal` differed in their first prefix field.
  Afterwards they do not. `deposit` was already shared, since both APIs emit it verbatim, so the
  root cause is the `itemID` fallthrough and not the rewrite.
- **Sync intake does not normalize.** `reconstructSyncRecord` (`src/Sync.lua:1146-1192`) never
  inspects the value, and intake checks only that `type` is non-empty (section 8), so a
  `"withdrawal"` record from a peer would be stored verbatim. No such record exists or can arrive:
  the census found zero across all 12,310 stored records, no tagged release ever shipped the
  un-normalized code (the money feature landed in v0.2.0 and the fix in v0.4.1 with no tag between
  them, the earliest tag in the repo being v0.5.0-alpha), the concurrent money-tab-index bug in the
  same commit meant money never loaded at all for a guild with fewer than eight tabs, and the exact
  version match in `HandleHello` rules out a mixed-version peer today. **Verdict: closed by #68's
  enum check**, which rejects it. Rejection is the right treatment rather than normalizing on
  intake, because no legitimate sender of that string can exist.

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

The reason is AceDB before it is anything about the migration chain. `removeDefaults` strips any scalar
equal to its default before writing (`Libs/AceDB-3.0/AceDB-3.0.lua:173`), and `copyDefaults` puts
**the current default** back on load (`:126-127`). So every guild sitting at exactly 8 has no
`schemaVersion` in its file at all, and takes whatever the defaults block says next login. **The
default value is the stored value of every guild at that version.** Raising it to 11 does not skip a
warning, it silently advances all of those guilds to 11 without running migrations 9, 10 or 11, and
there is no later pass that notices. All three are realm canonicalization, and the loss is permanent.

The migration chain is the second half of the story. The 9 to 10 and 10 to 11 migrations gate on
**strict equality**, not `>=`:

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

**Verdict: correct as it stands, and being pinned by a test, issue #76.** This is the one disagreement
in this document that must not be resolved by making the two sides agree. Nothing in the suite fails
today if someone raises the default in good faith, so the fix is a regression test that asserts the
value and asserts the gates behaviourally, not a change to either.

Third place the version is written, outside the ladder and worth knowing: `GBL:DeduplicateRecords`
temporarily sets it to 5 to force the legacy cross-slot pass and restores it afterwards
(`src/Core.lua:2678-2685`).

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
scanned locally rather than received, so they are not part of the above. Issue #69.

### How much of this is a live problem, and how much is cosmetic

The first pass did not separate the two, and the split matters because it decides what has to be fixed
and what merely could be. The line is `buildPrefix`, which reads `type`, `player`, `itemID`, `count`
and `tab` on item records and nothing else (`src/Dedup.lua:39-51`).

**The 195 that lost only `subclassID` still have ids that agree with their fields.** `subclassID` is
not in the prefix. Same for the 19 that gained a `stamp` key and lost nothing, and the 22 that lost
nothing at all. These cost a few bytes on re-send and are otherwise inert.

**The roughly 17 with a corrupt or missing `type` are live inconsistency.** Their `buildPrefix` output
disagrees with the id they carry, so `BuildStoredRecordIndex` (`src/Dedup.lua:219-228`) files them
under a prefix matching no id, `CountFromRecordIndex` undercounts, and `CleanupWithEventCounts` reasons
about a group of one. Anything that lost `itemID` is in the same class by a different route: it flips
to the money branch and collides.

### There is a recovery channel

`record.id` begins with `type` and `player` as its first two pipe-delimited fields, and it was computed
by a healthy sender before transmission. So a record that lost its `type` can usually get it back from
its own id. That holds only if `CleanupWithEventCounts` has not already rebuilt the id from the corrupt
fields (`src/Core.lua:2795-2833` runs whenever it removes anything), which is the first thing to check
before relying on it.

### The reject counter counts rejections as duplicates

`HandleSyncData` increments `itemDuped` when `reconstructSyncRecord` returns false (`src/Sync.lua:2143`,
money at `:2169`). No log, no counter, no warning. So total rejection is indistinguishable from perfect
convergence: the `Redundancy from <peer>` line would read 100% duped, which the decision rule in
`CLAUDE.md` reads as "the bucket filter is doing most of the work, skip." Every redundancy reading
taken so far has been inflated by the rejection rate.

**Verdict: split across two issues.** #68 hardens intake going forward: repair before rejection
(recompute `classID` and `subclassID` from `itemID`, which is where `CreateTxRecord` gets them anyway),
then reject on three checks (`type` in the enum, exactly one of `itemID` or `amount`, known fields hold
the right type), plus a real reject counter. #75 repairs what is already stored, using the same repair
helper and the id recovery channel above, deleting only records whose id is also unusable and taking
their `seenTxHashes` entries with them.

**Rejected: validating against a key whitelist.** The first pass listed this as the obvious fix and it
is the wrong one. Unknown keys passing through untouched is what makes the record schema
forward-extensible: `stripForSync` shallow-copies through `pairs()` and `buildPrefix` reads only fields
it names, so adding a field is free today. A whitelist would convert every future additive field into a
compatibility break requiring a floor raise. The garbage keys stay on the record, where nothing reads
them. Removing the twelve specific observed key names is a different and safe thing, and #75 treats it
as optional.

## 9. Numeric keys cross the wire, and now they are tested

The spec mock serializer is pass-through (`spec/mock_ace.lua:161-176`: `Serialize` stashes the table
and returns `"SER:<n>"`, `Deserialize` hands the same table object back), so for the project's whole
life no test encoded a byte. Numeric key survival and payload size were in-game claims only.

**Closed in v0.36.1 by golden wire-contract fixtures.** `spec/wire_contract_spec.lua` runs a real
AceSerializer (`spec/wire_helpers.lua` loads it, stashing and restoring the mock LibStub registry
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
fingerprint bucket tables: `bucketKeyForRecord` (`src/Fingerprint.lua:106-116`) returns
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

HELLO, SYNC_DATA and BUSY are each built in two places, and the fixtures assert the pairs agree under
identical state. Doing that turned up a key that can never be set. The empty-chunk SYNC_DATA builder
writes `eventCounts = batches[1]`, but the loop just above it extends the chunk list until
`#chunks >= #batches`, so reaching the `#chunks == 0` branch already implies `#batches == 0`. A send
that has event counts and no records routes through the other builder instead and emits an empty chunk
from there. Harmless, since the key simply never appears, but it means the two builders' key sets
legitimately differ by `eventCounts` and the parity assertion has to allow for it. Folded into #70,
which owns the duplicated builders. Note that #70's title names SYNC_DATA and BUSY only: HELLO is a
third pair, and the floor release edits both of its builders.

There is a second untested boundary of the same kind, and it is the larger one. `spec/mock_ace.lua`
models AceDB's read path (`applyDefaults`, `:52-79`) and has no `removeDefaults` at all. Default
stripping is the mechanism behind every claim in section 2 and behind the schemaVersion result in
section 7, and the suite cannot check any of it. Issue #77.

## Open questions

One is left. The other two are answered, recorded here with their answers so they are not reopened
from scratch.

**Still open, and deliberately unscheduled: why 105 locally scanned records carry an empty
`itemLink`.** A cold item-info cache at scan time is the leading candidate, which would make a deferred
re-read the right remedy rather than skipping what are real transactions. Untraced, and worth tracing
before choosing, so it wants a capture rather than a fix. Issue #69, outside the milestone. The
population cannot grow through sync (#68 rejects the shape at intake), which is what makes leaving it
safe.

**Answered: the tab on deposits and withdrawals.** Recorded going forward by #67, riding the floor
release because it is identity affecting. Old records cannot be back-filled: their true tab was never
written anywhere. See section 4 for the two seams that come with it.

**Answered: whether intake should validate against a key whitelist.** No. See section 8. The mechanism
behind the splicing is still a hypothesis, and deliberately so: the validation in #68 checks the
outcome rather than the hypothesis, so it is correct whether or not a lost AceComm fragment turns out
to be the cause. Rejections get logged with the offending key names, so when sync traffic resumes there
is evidence rather than another archaeology pass.

## Where the disagreements are tracked

All under the **Data model integrity** milestone.

| Section | Disagreement | Issue |
|---|---|---|
| 2 | `dailySummaries`, `weeklySummaries` declared, never written | #62 |
| 2 | `snapshots`, `teams` declared, never written | #71 |
| 2 | `altLinks` declared, never written | #52 |
| 2 | `eventCounts` written, never declared | #71 |
| 3 | Two structures named `peers`, the persisted one write-only | #72 |
| 4 | No deposit or withdraw record knows its tab | closed in v0.37.0 (#67) |
| 5 | Item records with no `itemID` collide in the money branch | #69 (locally scanned, unscheduled); sync-received closed in v0.37.0 (#68) |
| 5 | `NormalizeRecordId` can rewrite a money record from an item record | closed in v0.37.0 (#68) |
| 5 | Sync intake does not normalize the money `type` | #68 |
| 7 | Nothing stops the `schemaVersion` default being raised | #76 |
| 8 | Intake accepts corrupted records | closed in v0.37.0 (#68) |
| 8 | 223 corrupted records already stored | #75 |
| 8 | Rejections counted as duplicates | closed in v0.37.0 (#68) |
| 9 | Numeric keys and payload size untested across the wire | closed in v0.36.1 |
| 9 | AceDB's write path unmodelled in the suite | #77 |
| 9 | `eventCounts` is unreachable where the empty-chunk SYNC_DATA builder writes it | #70 |
| - | Per-player category totals declared, never accumulated | #64 |

The compatibility break several of these rode was #74, **and it has now been spent.** v0.37.0 shipped
the version floor along with #67 and #68. Two peers on different releases now sync, so any later
change to `buildPrefix` would silently duplicate the guild's dataset unless `MIN_SYNC_VERSION` is
raised again, and raising it re-imposes the lockstep split the floor removed. Treat every remaining
identity-affecting idea in this document as costing a forced guild-wide update from here on.

What that leaves open, in rough order of how much it still hurts: #75 (the 223 damaged records
already on disk, which #68 stops growing but does not repair, and which can now reuse
`GBL:RepairSyncRecordItemFields`), #69 (the same itemID-less shape produced by local scans rather
than by sync, still unscheduled), #62, #71, #72, #76, #77 and #64. None of those touch record
identity, so none of them cost a floor raise.
