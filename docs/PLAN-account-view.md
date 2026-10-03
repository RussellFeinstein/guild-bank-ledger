# The account view: every guild your characters are in, in one window

Written 2026-09-30 against `main` at `bf3334d` (v0.41.18), from three read-only surveys run the
same day (storage and guild identity, the view gates, the tracker and the sync boundary), two
design passes and two review passes. A player asked for the addon to track their alts across
different guild banks and show everything in one place. Russell asked for a spike on how that
could work, then set its terms: it is done properly, colliding guild names included; it is not
urgent; it is not built now; it is filed to be handled later as an additional feature.

Every claim about code below was checked by reading the function named beside it on that commit.
Citations are by path and function name, with a line number only where a line is quoted, because
#286 is what line-number citations in a design doc turn into. Two claims rest on the WoW wiki rather
than on code, and section 4 says which.

## 1. What this decides, and what it leaves alone

Decided here: the principle the feature keeps; how guild tables are keyed so two guilds with one
name never share a ledger; what the account roster records; how access is decided for a guild the
logged-in character is not in; how rows from several guilds reach one view without a record
changing; the view, its copy, its slash commands and its accessibility contract; the tests; the
order of the three issues; and what the public docs say when it ships.

Left alone: the sync protocol and the wire (nothing new crosses it, section 3), the bank family
(Sort, Layout and Restock act on the open bank and stay single-guild), alt linking as #52 frames it
(advertising links to other members, which this design never does), and any code. Nothing here is
built until Russell says so.

**The principle.** The guild stays the unit of record and of sync; the account becomes the unit
of viewing. The join is read-only, at view time, on this client only. Nothing new crosses the wire
and no record gains a field. Each guild's rows are shown under that guild's own stored policy, at
the rank this account holds in that guild and never at a rank held somewhere else, and any reading
taken for a guild the logged-in character is not in says when it was taken.

## 2. Ground truth

- **One file already holds every guild.** `GuildBankLedger.toc` declares `SavedVariables`, not
  `SavedVariablesPerCharacter`, and `OnInitialize` (`src/Core.lua`) opens the store with
  `AceDB:New("GuildBankLedgerDB", defaults, true)`, the third argument forcing one shared profile.
  Every guild any character on the account has scanned or synced sits under `db.global.guilds`.
  `db.global` has two keys in use, `characters` and `guilds`.
- **Guild tables are keyed by the bare guild name.** `GetGuildData` returns
  `self.db.global.guilds[guildName]` with the name from `GetGuildName`, which reads position 1 of
  `GetGuildInfo("player")` and caches the last non-nil answer in `_cachedGuildName`, never cleared.
  No code reads position 4 (the guild's realm), and nothing in `src`, `UI` or `spec` calls
  `C_Club`. So two same-named guilds on different realms share one table today, and a renamed
  guild starts a new table and leaves its history under the old name.
- **The wildcard turns a read into a write.** `guilds` is declared `{ ["*"] = {...} }`, and AceDB's
  `copyDefaults` (`spec/vendor/AceDB-3.0.lua`, the vendored copy) installs an `__index` that builds
  a table from the defaults and `rawset`s it on the first read of any missing key. Reading
  `guilds[someKey]` for a key that is not there creates a guild. `MigrateAllGuilds` and
  `DeduplicateAllGuilds` walk the table with `pairs`, which does not trigger it.
- **Access is answered for the current guild only.** `GetAccessLevel`, `GuildRankIndex`,
  `IsGuildMaster`, `HasSortAccess` and `HasLayoutWrite` take no guild argument and read the live
  `GetGuildInfo("player")`. `GuildRankIndex` falls back to `_lastKnownRank`, a session value. No
  rank is stored anywhere, and no `PLAYER_GUILD_UPDATE` handler exists (#287 lists what that
  leaves behind after a mid-session guild change).
- **The account roster is the seam.** `RecordOwnCharacter` writes
  `db.global.characters[Name-Realm] = GetServerTime()` from the `GUILD_ROSTER_UPDATE` handler,
  guarded on a resolved realm. The value is a number: no guild, no rank. Its one reader,
  `GetOwnCharacterNames` (`UI/UI.lua`), reads the keys; the only reader of a value is one assertion
  in `spec/core_spec.lua`'s "account character roster" describe. It is never transmitted and never
  backfilled, so it fills only as characters log in.
- **One function decides which rows a History tab renders.** `RecordsForView(guildData)`
  (`UI/UI.lua`) answers `sync_only` with two empty tables, `full` with the arrays as they are, and
  `own_transactions` through `FilterToOwnRecords`. `RefreshUI` and `SelectTab` both call it, and
  `.claude/rules/ui.md` holds it as the one gate. The three History views take arrays by parameter
  (`CreateLedgerView`, `BuildGoldLogTab`, `BuildConsumptionTab`) and never call `GetGuildData`.
- **A record cannot carry its guild.** `stripForSync` (`src/Sync.lua`) copies every key of a record
  and removes a fixed list, so a field added to a record reaches the wire. The guild a record
  belongs to is known only from which table holds it.
- **The name resolver falls through to the current guild.** `ResolvePlayerName(name, playerRealms)`
  uses the explicit table only when its entry is a string; otherwise it reads the current guild's
  `playerRealms`, then appends the local realm. Its doc comment records that a cross-guild fallback
  was removed in v0.30.5 because bare names from another guild's roster resolved to the wrong realm.
  Passing another guild's table is therefore not enough to resolve that guild's rows.
- **Sync never crosses guilds.** HELLO goes on the GUILD channel and everything else is a whisper.
  Every message is stamped with `guild = GetGuildName()`, and `OnSyncMessage` drops one whose
  `guild` differs (`if myGuild and data.guild ~= myGuild then`). Intake writes into
  `GetGuildData()` only.
- **Spec surface of the key.** 32 sites in three spec files index `db.global.guilds` by a literal
  name: 26 in `spec/savedvariables_spec.lua`, 4 in `spec/schema_version_spec.lua`, 2 in
  `spec/core_spec.lua`.
- **Two stale spots found on the way.** The comment above `spec/core_spec.lua`'s "account
  character roster" describe says "the wire-contract spec's absolute HELLO key set" keeps the
  roster off the wire; `spec/wire_contract_spec.lua` holds HELLO to parity between its two builders
  only, and `docs/DATA-MODEL.md` says a field added to both would not be caught. No spec asserts
  that `characters` reaches no message. And `MatchesFilters` (`UI/FilterBar.lua`) still compares
  `StripRealm(record.player)` to `StripRealm(filters.player)` for a `filters.player` nothing sets,
  the bare-name compare `.claude/rules/ui.md` bans.
- **The tracker.** No issue covered a cross-guild or account view before this doc. #52 (alt
  linking, post-1.0 by decision) is about advertising links to other members and names "a purely
  local per-player view" as an open question. #228 (My record) shows a member's own rows across
  every character on the account, within the current guild. #186 and #187 (the hub export) are per
  guild, and the views doc's section 1 rule ("No role's need is met by 'the website does that'")
  keeps the hub from being the one place.

## 3. The privacy argument

`docs/PLAN-views-and-access.md` section 10 makes the promise: every client holds the whole guild's
history, and Own Transactions is a presentation mode over that copy, so "the addon does not show
you other members' rows. Not: the data is not on your machine." Section 7 puts the roster on this
client only, never on the wire.

#52 warns that "sending an account's full character list to guild A would disclose that the player
also plays in guild B". That leak has an audience: guild A's members, learning something about
this player. The account view has one audience, the same person, on their own machine, reading rows
their own client already holds. Two tests decide whether it discloses anything new.

1. **Does any byte leave the machine?** No. The roster, the scope and the side table of section 7
   are read at view time; the wire, the guild filter in `OnSyncMessage` and intake are untouched.
   Section 13's absence spec pins it for every message the addon builds.
2. **Does anyone see a row they could not already see?** No, provided guild B's rows are gated by
   guild B's policy at the rank this account holds in guild B. That proviso carries the whole
   argument. The tempting shortcut, "the character is a GM somewhere, so show everything", would
   let the GM of guild A read guild B's full ledger while a rank-6 member there, which is exactly
   what guild B's GM set a threshold to prevent. So the rank is per guild and never crosses
   guilds, and `GetAccessLevelFor` (section 6) is where that rule lives.

The corollary is the whole access model: **the account may see, per guild, what it could see by
logging in a character of that guild, and no more.**

**A guild the account has left.** Today a character who has left guild B sees nothing of it in the
addon. The membership that granted a rank has ended, and the guild's promise is made by a current
GM to current members; a former officer keeping a live, filterable window into the ledger is not
something the guild agreed to. The person's own rows are their own history (views doc section 7:
"A character that left the guild still matches"). So the default is own rows only, capped below
whatever rank was last held (decision D1, section 16).

**A policy that changed since the last visit.** A guild's `accessControl` on this machine is
updated only by a HELLO merge while a character of that guild is online (`HandleHello` writes into
`GetGuildData()`), and a rank stamp only when that character logs in. The rule is to apply both as
stored and say when they were read. No age cutoff: a cutoff hides the person's own copy from them
for no privacy gain, and its honest fallback would be the Member view, which the left-guild rule
already gives.

## 4. The guild key

Guild tables are keyed so that two guilds with one name never share a ledger. This is step 1 of the
feature (issue 1, section 17), because the view would otherwise put two guilds' history under one
label, and because it fixes the rename loss on the way.

**The key is the guild name and the guild's realm.** `GetGuildKey()` returns
`<name>-<guild realm>` from the one `GetGuildInfo("player")` call that already supplies the name:
position 1 is the name, and position 4 is the guild's realm. The wiki
(warcraft.wiki.gg, `API_GetGuildInfo`, read through the fetch tool on 2026-09-30) describes position
4 as "The name of the realm the guild is in, or nil if the guild's realm is the same as your current
one", so the realm part is position 4 when present and the character's own realm otherwise,
normalised through `NormalizeRealm`. The key is readable at exactly the instant the name is, so the
cold window after login is today's and `WaitForGuildName` covers the bank-open path unchanged.
`GetGuildKey` caches its last non-nil answer in `_cachedGuildKey`, as `GetGuildName` does, with the
same mid-session caveat #287 records.

**The club id is not the key.** `C_Club.GetGuildClubId()` returns a string that would survive a
rename, and the wiki lists it on every flavour the addon ships to. The same page marks it
`RequiresClubsInitialized`, and nothing here has measured when the clubs system is ready after a
login. `GetGuildData` gates recording, scanning and sync, so waiting on that API would put an
unmeasured stall in front of every write. The club id is stored on the guild table as `guildId`
whenever it reads, and used for one thing: re-attaching a table after a rename or a realm transfer.

**The reading owed before the build.** The key decides where every record lands, so its predicate
is observed in game before anything relies on it (the 2026-09-17 rule in `.claude/rules/sort.md`).
Two readings, both by `/dump` on a live client:

1. On a guild whose home realm is connected to the character's but not the same realm, what
   position 4 returns, and what it returns for a character of the same guild on the home realm. The
   wiki says nothing about connected realms. A nil there would key one guild two ways across the
   account's characters, and the design would move to the club id with a measured wait in front of
   it.
2. Whether `C_Club.GetGuildClubId()` answers at the first `GUILD_ROSTER_UPDATE` after a login, and
   at `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` for the guild bank, on Retail and on each Classic
   flavour the addon ships to.

**The move, lazy and per guild.** At the first `GetGuildData()` of a session that can compute the
key, and again on the first warm `GUILD_ROSTER_UPDATE` (the `_migrationsRetried` pattern in that
handler): if `rawget(guilds, key)` is nil, find a table to attach, in this order.

- A table whose `guildId` equals the live club id: a rename or transfer. It moves under the new
  key, and one system-channel line says so.
- `rawget(guilds, bareName)`: the legacy key. It moves under the new key, one line.
- Neither: the guild starts fresh under its key.

If a bare table exists and a table already sits under the key (a second same-named guild visited
after the first one took the shared table), the second guild keeps its own table, the bare one
stays with the first, and the line says that table's older history is mixed and cannot be split,
because records carry no guild. A bare table for a guild never visited again stays under the bare
name as a legacy key and is listed as such (section 9).

The move renames keys and changes no table, so it runs outside the per-guild schema ladder and
`schemaVersion` is untouched (`docs/DATA-MODEL.md` section 7 says why raising it strands guilds).
Every reader goes through `GetGuildData`, and the fingerprint caches key on the table's identity
(#276), so nothing else moves with it. The key is compared whole and never parsed: the guild's name
for display is stamped on the table as `guildName` at the move and at every `GetGuildData` that can
read it.

**The wire does not change.** Messages keep `guild = GetGuildName()`, the bare name, and
`OnSyncMessage` keeps comparing bare names. HELLO rides the GUILD channel and everything else is a
whisper to a guild member, so a same-named guild elsewhere never receives our messages and the bare
compare is enough. No `PROTOCOL_VERSION` bump, no floor raise. A `guildId` field could ride any
message later under the unknown-key passthrough if a reason appears.

**What it costs the specs.** The 32 literal-key sites move to one helper over the mock's guild
(`spec/mock_wow.lua`'s `GetGuildInfo` already returns `MockWoW.guild.realm` as position 4, nil by
default), and the mock gains `C_Club.GetGuildClubId`, nil by default and a fixed id in the
re-attach cases. `docs/DATA-MODEL.md` section 1 gains the key, `guildId` and the legacy-key rule.

Because this step also fixes the rename loss for every guild, it could be pulled into Data model
integrity ahead of the rest if Russell ever wants it sooner. Issue 1 says so.

## 5. The roster gains a guild key and a rank

`db.global.characters[Name-Realm]` changes from a number to a table. Additive, with readers that
accept both forms, and no schema rung: the roster is account level and the ladder is per guild.

```lua
db.global.characters["Katalt-TestRealm"] = {
    lastSeen  = 1760000000,              -- GetServerTime() at the write (today's number, moved)
    guildKey  = "Other Guild-OtherRealm", -- GetGuildKey() at the write (section 4)
    guildName = "Other Guild",           -- GetGuildInfo position 1, display only
    rank      = 5,                       -- position 3 (0 = Guild Master); nil if the read was empty
    rankName  = "Member",                -- position 2, display only
    stampedAt = 1760000000,              -- when the guild fields were read
}
-- a character seen with no guild:
db.global.characters["Loner-TestRealm"] = { lastSeen = 1760000000, guildKey = false, stampedAt = 1760000000 }
```

`rankName` is stored because `GuildControlGetRankName` answers only for the live guild.
`guildKey = false` means seen guildless; `nil`, or a number entry from before this change, means
unknown.

- **The writer.** `RecordOwnCharacter` stays the one writer and reads name, rank name, rank and
  realm from one `GetGuildInfo("player")` call, never from `GetGuildName` plus `GuildRankIndex`,
  which cache separately and can pair the old guild with a rank read later. Guild fields are written
  only when the key is readable; a nil is the cold state, not "guildless". Its two guards stay.
- **Guildless.** `guildKey = false` is written only from an `IsInGuild()`-false reading in a new
  `PLAYER_GUILD_UPDATE` handler, and from nowhere else: a cold read at login could stamp a guilded
  character as guildless. The wiki page for `GetGuildInfo` names `PLAYER_GUILD_UPDATE` as one of the
  two events to read the guild on. Whether it fires at a leave and at login, and whether
  `IsInGuild()` reads false at once, are readings for issue 2; if they do not behave, the stamp
  stays stale in the safe direction (section 6). The handler is the guild-change hook #287 asks
  for, and the roster is its first consumer.
- **Ghost stamps.** A character renamed, transferred or removed from a guild without logging in
  since keeps a stamp naming that guild at its old rank. On every `GUILD_ROSTER_UPDATE`, each stamp
  whose `guildKey` is the current guild's and whose character is not on the live roster (the
  `GetGuildRosterInfo` walk `BuildRosterCache` already makes) is set to `guildKey = nil`. So every
  guild's stamps are checked whenever any character of the account visits it.
- **The readers.** `CharacterEntry(nameRealm)` turns a number into `{ lastSeen = n }`.
  `GetOwnCharacterNames` reads keys and does not change. New:
  - `KnownGuildKeys()`: a `pairs` walk over `db.global.guilds` keeping tables, joined with the keys
    the roster stamps name, current guild first and then by name.
  - `AccountMembership(guildKey)`: `{ current, bestRank, characters = {{ name, rank, rankName,
    lastSeen }}, stampedAt, guildName }`. `current` is true when any stamp names the key;
    `bestRank` is the lowest rank index among those.
  - `GetGuildDataFor(guildKey)`: `rawget(self.db.global.guilds, guildKey)`. Never an index
    (section 2), and a spec asserts every key a reader touched is still absent afterwards.
- **Derived, never stored:** which guild a character is in, whether the account is in a guild, and
  the best rank there all come from the stamps, so one fact has one home.
- `docs/DATA-MODEL.md` section 1's `global.characters` paragraph is rewritten in the same PR: the
  shape, the number form, `false` against `nil`, and "never transmitted" pointing at the absence
  spec rather than at the HELLO builder's literal.

## 6. Access for a guild you are not in

```lua
function GBL:AccessLevelForRank(guildData, rankIndex) -- pure: GetAccessLevel's four branches
function GBL:GetAccessLevel()          -- same answer as today: IsGuildMaster live, then
                                       -- AccessLevelForRank(GetGuildData(), GuildRankIndex())
function GBL:GetAccessLevelFor(guildKey) -- current key: GetAccessLevel(); else from the stamps
```

| Stored state of a guild that is not the current one | Level |
|---|---|
| no guild table (`rawget` is nil) | `sync_only`: nothing to show, nothing created |
| best stamped rank 0 | `full` |
| no `accessControl`, or no `rankThreshold` | `full` |
| a threshold, and no rank stamped (an older account, a cold read, a legacy key) | `restrictedMode or "own_transactions"`, failing closed as the live path does for a nil rank |
| best rank at or under the threshold | `full` |
| otherwise | `restrictedMode or "own_transactions"` |
| then, if no character of the account is stamped in this guild now | capped at `own_transactions`; `sync_only` stays `sync_only` |

- **Several characters in one guild.** The best rank among those stamped there now counts. The
  person can log that character in and see the ledger at that rank, so the account's view is that
  character's view. A character since seen in another guild lends nothing, because its stamp names
  the other guild.
- **The current guild stays live** (decision D2). `GetAccessLevel()`, the tab bar, the settings
  row, the Sync tab's GM controls and the bank family keep reading the logged-in character. An
  account logged in on a rank-6 alt whose main is GM of the same guild sees the Member view there,
  as today, while it would see another guild's full ledger from a stored rank 0. That asymmetry is
  deliberate: `GetAccessLevel` feeds `_AccessTabSignature`, so changing it changes every tab bar in
  guild use.
- **No `For` variants for the bank family.** Sort, Layout and Restock act on the open bank; a
  stored sort grant for another guild has nothing to act on.
- **Extracting `AccessLevelForRank`** keeps the rule in one place. With `IsGuildMaster` still read
  first, the live answer is the same in every branch, including a cached rank 0 during an empty
  read; section 13 pins that with a table over rank, threshold and mode.

## 7. Rows for a scope

```lua
-- self._viewScope = { kind = "current" } | { kind = "all" } | { kind = "guild", key = "<guild key>" }
-- Session state. Default "current" when GetGuildKey() answers, otherwise "all". Not persisted.

function GBL:RecordsForScope(scope)      -- the gate SelectTab and RefreshUI call
                                         -- returns transactions, moneyTransactions, banner lines
function GBL:RecordsForViewFor(guildKey) -- RecordsForView's contract for any guild on the account
GBL._guildOf = setmetatable({}, { __mode = "k" })  -- record table -> guild key
function GBL:GuildOfRecord(tx)
```

`RecordsForView(guildData)` stays the per-guild gate, and `RecordsForScope` calls it for `current`
exactly as `SelectTab` and `RefreshUI` do today, so every member-view spec stays green by
construction. `RecordsForViewFor` has the same contract over `GetAccessLevelFor` and
`GetGuildDataFor`.

**Where a row's guild lives.** In a weak-keyed side table, stamped by `RecordsForScope` for every
row it hands out under `all`; under `current` nothing is stamped. Three alternatives were weighed
and rejected:

- A field on the record: it reaches the wire through `stripForSync` and lands on disk.
- Wrapper rows `{ record = tx, guild = key }`: every renderer, `MatchesFilters`,
  `SortTransactions` and `BuildConsumptionSummary` read `tx.field` directly, so all of them would
  change.
- A parallel array: `CreateLedgerView` filters into a fresh array and sorts it, which breaks the
  alignment on the first render.

A record table belongs to exactly one guild table, since no path moves records between guilds, so
the record's identity is a sound key, and a record dropped by dedup leaves the side table with the
garbage collector.

**Build, order, cost.** Under `all`, `RecordsForScope` walks `KnownGuildKeys()`, calls
`RecordsForViewFor` for each, stamps each row and appends into two fresh arrays; under one named
guild it makes one call and copies nothing. It sorts nothing, since every renderer sorts what it
renders. The new work is one linear pass of appends and side-table writes; what grows is each
renderer's existing sort, from one guild's rows to the sum. `RefreshUI` runs on every bank open,
storing scan and finished sync receive, so under `all` each of those re-merges. A cache keyed on
the scope and each guild's table identity and record count (the shape `PeekBucketHashes` uses since
#276) is the lever if the first reading on an account with three or more large guilds says the
merge shows; it is not built before that reading.

**Sorting by guild.** `SortTransactions(transactions, column, ascending)` takes a column key and
reads `a[column]`, and the guild is not on the record. The column definition carries
`value = function(tx) return GBL:GuildOfRecord(tx) end`, and `SortTransactions` looks the getter
up by key before falling back to `a[column]`. That is the shape #86 moves the cell text dispatch
to.

## 8. Resolving names per guild

`FilterToOwnRecords(records, guildKey)` gains an optional key. It reads `playerRealms` from
`GetGuildDataFor(guildKey)`, since each guild carries its own ambiguity marks (`BuildRosterCache`
writes `false` for a bare name two roster realms share), and resolves through a resolver with no
fall-through:

```lua
-- Explicit table or nothing: no read of the current guild's roster, no local-realm guess.
-- Returns the qualified name, or nil to refuse.
function GBL:ResolvePlayerNameIn(name, playerRealms, fallbackRealm)
```

| Input | Result |
|---|---|
| a qualified name | as it is |
| `playerRealms[name]` is a realm | `name-realm` |
| `playerRealms[name]` is `false` | refused |
| no entry, and a `fallbackRealm` | `name-fallbackRealm` |
| no entry, and no `fallbackRealm` | refused |

For the current guild the fallback is `GetLocalRealm()`, which gives today's three branches
exactly. For another guild it is the realm of the account's character stamped there (the realm in
its roster key), which stands where the local realm stood when that character's client recorded the
rows; with no stamp there is no fallback. The cost: a bare-name row from before 2026-04-13 in a
guild the account has no stamp for is hidden rather than guessed. Under a promise that the addon
shows nobody else's rows, hiding is the safe direction.

## 9. The view

The view is built on the visual overhaul's chassis, after #227 (the Table and Transactions), #228
(My record) and #229 (Gold and Players) have shipped, so no AceGUI form of it is designed.

**The scope control** is a `WowStyle1DropdownTemplate` dropdown through `MenuUtil` at the right end
of the History group's in-tab switch row (`docs/PLAN-visual-overhaul.md` section 5). Not the
per-view filter row: filters are per view and rebuilt from `CreateDefaultFilters` on every build,
while the scope is shared by the three History views. Not the shell: the scope does not govern Bank
or Sync.

**Its entries:**

- "This guild: <name>", absent on a character with no guild.
- "All guilds (N)".
- One entry per other guild, labelled by state: "Other Guild (as Katalt, Member)", "Old Guild (no
  character there now)", "New Guild (no records yet)", "Old Name (legacy, not visited since the
  key change)". Two keys that share a name show the realm after it.

A guild table with no records and no stamp naming it is not listed.

**Each History view under each scope:**

| Scope | Transactions and Gold | Players (today's Consumption) | My record (#228) |
|---|---|---|---|
| this guild | as today | as today | as #228 designs it |
| one other guild | that guild's rows under `RecordsForViewFor`, one banner line | that guild's totals, headed "<Guild> overview" | own rows in that guild, its strip |
| all guilds | merged rows with a Guild column, one banner line per guild | per-player totals pooled across guilds, each guild gated first, headed "All guilds overview"; a name counts once | section 10 |

**The banner** replaces the one-line restricted banner when the scope is not `current`, one line
per guild, carried by its words alone, ASCII:

- "Other Guild: showing your rows only (Member), as of your last visit on Katalt, 2026-09-12."
- "Other Guild: all rows, as of your last visit on Katgm (Guild Master), 2026-09-28."
- "Old Guild: you have no character there now; showing your own rows."
- "Other Guild: nothing to show (Sync only)."
- "Other Guild: no character seen there since updating; showing your own rows."

**The Guild column** is `{ key = "guild", label = "Guild", width = 110, scoped = true, value =
GuildOfRecord }` in `GBL.LEDGER_COLUMNS` and `GBL.GOLD_LOG_COLUMNS`, after the time column.
`GetVisibleColumns` drops `scoped` columns unless the scope is `all`. On the Table it is one more
column definition.

**The tab bar does not change with the scope.** `AccessTabs()` stays the one producer and never
reads `_viewScope`, so the live guild's view family is the door: a character in a `sync_only` guild
cannot reach the merged view from that character, and logging in another one is the way through. A
character with no guild gets the full tab set today (`GetAccessLevel` answers `full` with no guild
data) and defaults to `all`, with every guild gated by its stamps; that `full` never reaches another
guild's rows, because `GetAccessLevelFor` does not consult it for a key that is not current. A
scope change re-renders through `RefreshUI`, never `RebuildTabs`, so no filter state is lost.

**The Bank and Sync tabs** never read the scope, and the control is not on their row.

**Copy.** The Players heading reads "<Guild> overview" or "All guilds overview" under a scope, in
place of today's "Guild Overview" (`UI/UI.lua`, the consumption renderer). The empty state under a
scope that is not current reads "No transactions recorded for <Guild> on this account.", since a
guild you are not in cannot be scanned. The frame title stays; the chassis footer adds
"Scope: All guilds (2)".

## 10. My record across guilds

Under `all`, #228's view gains three things, each a line of text.

- The strip pools the member's own rows across guilds through the two existing computers,
  `ComputeGoldLogSums` and `BuildConsumptionSummary`: "Across your guilds, the guild covered
  7,529g of your repairs."
- One line per guild under it: "Test Guild: 5,000g of repairs, 60 consumables taken. Other
  Guild: 2,529g, 40."
- The own-rows table gains the Guild column.

**The unnamed guild line keeps its five-name floor per guild and is never pooled.** A pooled total
over two guilds, each under the floor, would pass the floor while letting an officer of one guild
subtract their own guild's known total and read the other's. A guild under its floor contributes
its "Not enough guild activity in this window to show totals" sentence and nothing else.

## 11. Slash parity

- `/gbl guilds` prints `KnownGuildKeys()`: for each guild the account's characters there, the best
  rank, the last visit and the level `GetAccessLevelFor` grants, so the chat answer and the
  dropdown's answer are the same answer.
- `/gbl show all` and `/gbl show guild <name>` open the window on that scope through the setter the
  dropdown uses. Each asks `HasAccessTab("transactions")` first and prints the reason when the
  answer is no, which is the pattern `OpenRestockTab` follows since #244.

## 12. Accessibility contract

In the shape of `docs/PLAN-visual-overhaul.md` section 7. The Table, filter row, footer and banner
rows there apply as written; these are the elements this feature adds.

| Element | Keyboard path | Focus ring | Colour fallback | Font scaling | Screen-reader text |
|---|---|---|---|---|---|
| Scope dropdown | in the walk after the in-tab switch buttons; Enter opens, Up and Down move, Enter selects, Escape closes | ring on the button | the value is text | from the font object; long names wrap | "Scope: All guilds, 2 guilds" |
| Scope banner lines | not focusable; read as text | none | mode, character and date are words, never a colour or an icon | from the font object; wraps | each line |
| Guild column header | as the Table header; Enter sorts; arrow plus "sorted by Guild" in the footer | ring on the header | arrow plus footer text | from the font object | "Guild, sorted ascending" |
| Guild cell | as the Table's rows; Up and Down | `selected` fill plus ring on the row | the name in `ink`; no colour per guild | row height from the font | the row's cells, guild after time |
| My record per-guild lines | not focusable | none | text | from the font object; wraps | each line |
| Footer scope text | not focusable | none | text | from the font object | "Scope: All guilds" |
| `/gbl guilds` output | chat | none | plain text, one guild per line | chat font | the lines |

A colour per guild was considered and declined: it would be a fourth colour family carrying no
meaning the name does not already carry.

## 13. Testing

Red first in every issue, in the repo's shapes.

**Issue 1, the key.** `spec/core_spec.lua`, a new describe "guild key":
- the key is built from positions 1 and 4 of one read;
- a nil position 4 keys on the character's realm;
- the key is nil while the name is cold, and cached once read;
- `guildId` is stored when `C_Club.GetGuildClubId` answers and absent when it does not;
- a bare table moves under its key with its system line;
- a renamed guild's table re-attaches by `guildId` under the new key;
- a second same-named guild keeps its own table, with the mixed-history line;
- a legacy bare table is left in place;
- every key no code wrote is still absent by `rawget`.

`spec/sync_lifecycle_spec.lua`'s "rejects messages from a different guild" stays green unchanged,
since the wire compares bare names. `spec/savedvariables_spec.lua` round-trips a keyed and a
legacy table through the vendored AceDB. The 32 literal-key sites move to the helper in the red
commit.

**Issue 2, the data.** `spec/core_spec.lua`, the "account character roster" describe extended:
- key, name and rank are stamped from one read, and nothing guild-shaped is written while cold;
- `guildKey = false` comes only from an `IsInGuild`-false `PLAYER_GUILD_UPDATE`;
- a ghost stamp is cleared against the live roster;
- a number entry from before the change reads as `lastSeen` with no guild;
- `AccountMembership` takes the best rank across two characters and is not current with none
  stamped;
- `KnownGuildKeys` lists a guild known only from a stamp and creates nothing;
- the existing value assertion moves to `.lastSeen`, and the describe's comment about a HELLO key
  set is corrected.

`spec/access_control_spec.lua`, a new describe "GetAccessLevelFor":
- the current key answers through the live path;
- rank 0 is full; a rank over the threshold gets the mode; a nil rank under a threshold fails
  closed; no threshold is full;
- **a rank held in another guild is never applied** (the live GM of one guild, stamped rank 6 in
  another with threshold 3, gets `own_transactions` there);
- ranks 5 and 2 under threshold 3 give full;
- a guild the account left is capped at own rows, and `sync_only` stays;
- an unknown key answers `sync_only` and creates no table;
- a table over rank, threshold and mode asserts `AccessLevelForRank` agrees with `GetAccessLevel`
  for the live key, which pins the extraction.

`spec/ui/member_view_spec.lua`, the "FilterToOwnRecords" cases extended: a bare name resolves
through the named guild's `playerRealms`, not the current guild's; it is refused with no entry and
no stamped realm; and a name the named guild marks ambiguous is refused even when the current guild
resolves it.

`spec/wire_contract_spec.lua`, a new describe "the roster never reaches the wire". With two
characters in two guilds and one guildless, it decodes the output of every builder (HELLO and its
reply, the request, a served SYNC_DATA, BUSY, LAYOUT_REQUEST and LAYOUT_DATA, SYNC_RECEIPT). It
asserts that no key is `characters`, `guilds` or `scope`, and that no string value equals a roster
key or the other guild's name. It is proven by adding the roster to one builder and watching it go
red. This closes the gap section 2 names.

`spec/savedvariables_spec.lua`: a table entry and a number entry in `characters` both round-trip
unchanged.

**Issue 3, the view.** `spec/ui/account_view_spec.lua`, new, with two guild tables `rawset` under
their keys and the roster from section 5:
- `all` merges both guilds' gated rows, and no record gains a key (every record's key set compared
  before and after);
- `GuildOfRecord` names the source of every merged row, and the Guild column shows only under
  `all`;
- rows come newest first across guilds after the renderer's sort, and `RefreshUI` keeps the scope
  and re-merges after a receive adds to the other guild;
- a `sync_only` guild contributes nothing, a guild the account left contributes own rows only, and
  a guild with no table lists as "no records yet" and renders nothing;
- a character with no guild defaults to `all` and never reads the live guild;
- the banner carries one line per guild with the character and the date;
- Players under `all` counts a name once, and `AccessTabs()` does not change with the scope;
- `/gbl show all` opens on `all`, and `/gbl guilds` prints the computed level.

`spec/ascii_strings_spec.lua` covers the new copy by construction.

## 14. Order and placement

Three issues, one milestone, and nothing starts before Russell says so (2026-09-30).

1. **The key** (section 4). First, because the view would otherwise label two guilds' history as
   one. Its readings come before its branch.
2. **The data** (sections 5, 6 and 8, the `PLAYER_GUILD_UPDATE` handler, `/gbl guilds`, the
   absence spec). After the key, because stamps carry it. Decisions D1 and D2 are owed before it is
   cut.
3. **The view** (sections 7, 9, 10, 11 and 12). After the data, and after #227, #228 and #229, so
   it is built once on the Table.

The roster has no backfill, so stamps exist only from the first login after issue 2 ships. When the
feature is picked up, shipping issue 2 well ahead of issue 3 gives the view a populated roster on
the day it lands. On #188 the three sit in the "Not buildable yet" table, where an item has no
position and its wait is written beside it.

## 15. Public docs and copy, when it ships

- `docs/CURSEFORGE-DESCRIPTION.md`, Access Control, a new bullet: "**Your guilds**: the History
  tabs can show every guild your characters have been in, one at a time or all at once with a
  Guild column. Each guild's rows follow that guild's own access policy at the rank your character
  last held there, as of your last visit on that character; a guild you have left shows your own
  rows only. Nothing about your other guilds is ever sent to anyone."
- `README.md`: the same sentence on the access-control bullet, and an "Account view" feature
  bullet.
- `docs/PLAN-views-and-access.md`: section 7 gains a paragraph that the roster carries the guild
  key and rank; section 10's table gains "the scope, the stamps, the side table: this client only".
- `.claude/rules/ui.md`: the `RecordsForScope` rule beside `RecordsForView`'s.
- `docs/DATA-MODEL.md`: the key with issue 1, the roster with issue 2.

## 16. Decisions and risks

**Open decisions, each with its default.** Both change code in issue 2, so both are answered on this
doc's review or at the re-audit before issue 2 is cut.

- **D1. A guild the account has left.** Default: own rows only (section 3). Alternative: the last
  rank held, labelled "as of". Changes the cap in `GetAccessLevelFor`.
- **D2. The current guild's rank source.** Default: the logged-in character (section 6).
  Alternative: the account's best stamped rank there too, which lets a GM's alt see the full ledger
  of the same guild and changes `GetAccessLevel`, the tab signature and the GM controls in guild use.

**Settled here, reversible on review:** the scope is session state and is not saved, so the window
never opens on a partly stale merged view unasked; a stored policy has no age cutoff; the control
sits on the History switch row.

**Risks:**

- **Position 4 on connected realms** (section 4). Unread; decides between the name-and-realm key
  and the club id. Read before issue 1 is cut.
- **`PLAYER_GUILD_UPDATE` and `IsInGuild` timing** (section 5). If they misbehave, `false` is
  never written and a guild the character left keeps its stamp until that character logs in, which
  is the safe direction and is said in the banner's date.
- **Cost of the merge under `all`** (section 7). Measured on the first account with three or more
  large guilds; the cache's place is named.
- **The wildcard** (section 2). Every new reader uses `rawget`, and a spec asserts nothing was
  created.
- **The resolver's fall-through** (section 8). The new resolver is the fix, and a spec pins it.
- **Mixed history under a collided legacy table** (section 4). Unsplittable, since records carry no
  guild; said once in the log and once in the scope list.
- **A mid-session guild change** (#287's class). `_cachedGuildName` and `_cachedGuildKey` keep
  answering the old guild until a relog; the `PLAYER_GUILD_UPDATE` handler is the hook the fix for
  that would hang on.

## 17. The issues this files

Filed with this doc on 2026-09-30, under the milestone "Account view", each body carrying its work
in full and closing with "Done when":

1. #302: Key guild tables by name and guild realm, so two guilds with one name never share a
   ledger. `type: bug`, `area: storage`. Section 4.
2. #303: Record each character's guild and rank, so the account can be shown each guild under that
   guild's own policy. `type: enhancement`, `area: storage`. Sections 5, 6 and 8. Waits on #302,
   D1 and D2.
3. #304: History views show one guild, another of the account's guilds, or all of them at once.
   `type: enhancement`, `area: ui`. Sections 7 and 9 to 13. Waits on #303, #227, #228 and #229.

All three sit in #188's "Not buildable yet" table until Russell says to start.

## 18. Sources

- The code at `bf3334d`: `src/Core.lua` (`OnInitialize`, `RecordOwnCharacter`, `BuildRosterCache`,
  `ResolvePlayerName`, `NormalizeRealm`, `GetLocalRealm`, `MigrateAllGuilds`,
  `DeduplicateAllGuilds`, `WaitForGuildName`, `GetGuildName`, `GuildRankIndex`, `IsGuildMaster`,
  `GetAccessLevel`, `GetGuildData`, `HasLayoutWrite`, `HasSortAccess`, `HandleSlashCommand`, the
  `GUILD_ROSTER_UPDATE` handler); `src/Sync.lua` (`stripForSync`, `OnSyncMessage`, `HandleHello`);
  `src/Fingerprint.lua` (`PeekBucketHashes`); `UI/UI.lua` (`AccessTabs`, `HasAccessTab`,
  `RebuildTabs`, `RefreshUI`, `SelectTab`, `GetOwnCharacterNames`, `FilterToOwnRecords`,
  `RecordsForView`, `AddRestrictedBanner`, `GOLD_LOG_COLUMNS`); `UI/LedgerView.lua`
  (`LEDGER_COLUMNS`, `SortTransactions`, `GetVisibleColumns`, `CreateLedgerView`); `UI/FilterBar.lua`
  (`CreateDefaultFilters`, `MatchesFilters`, `FilterTransactions`); `UI/ConsumptionView.lua`
  (`BuildConsumptionSummary`, `ComputeGoldLogSums`); `UI/RestockView.lua` (`OpenRestockTab`);
  `spec/vendor/AceDB-3.0.lua` (`copyDefaults`); `spec/mock_wow.lua` (`GetGuildInfo`);
  `spec/wire_contract_spec.lua`; `spec/core_spec.lua`.
- `docs/PLAN-views-and-access.md` sections 1, 7, 8 and 10; `docs/PLAN-visual-overhaul.md` sections
  5 and 7; `docs/DATA-MODEL.md` sections 1 and 7; `.claude/rules/ui.md`; `.claude/rules/sort.md`
  (the 2026-09-17 rule).
- warcraft.wiki.gg, `API_GetGuildInfo` and `API_C_Club.GetGuildClubId`, read through the fetch tool
  on 2026-09-30.
- Issues #52, #186, #187, #188, #227, #228, #229, #276, #286, #287.
