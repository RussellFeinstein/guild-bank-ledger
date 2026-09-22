# Views and access: who sees what, and what reaches whom

Written 2026-09-21 against `main` at `eda34ea` (v0.40.0), from three read-only surveys run the same
day (the view and gate code, the tracker and docs, the project memory), a read of the maintainer's
own SavedVariables for the guild's real numbers, and four questions put to Russell before any
design was drawn. It sits above `docs/PLAN-visual-overhaul.md`, written the same day: that doc
decides the look and the chassis, this one decides the roles, what each role comes to the addon
for, the views that serve those needs, what each role may see, and what data reaches which client.
Where the two disagree, this one wins, and the visual doc's sections 5, 6, 9, 10 and 11 were
revised in the same PR to say what this one says.

Every number below was measured on that commit or read from the SavedVariables on 2026-09-21, with
the command or the file and line beside it. Every claim about code was checked by reading the
lines named; the one defect this doc reports was verified by reading the call chain and not by
running it, and its section says so.

## 1. What this decides, and what it leaves alone

Decided here: the roles, in terms of the rank and the two access families the addon already has;
what each role needs to see and do; the view set each access mode shows; what "own" means; the
member view and what it may honestly say; the promise the guild can make about privacy; the home of
the season scope; how the hub export fits; the accessibility contract and the test design for the
one new view; and what this moves in the visual doc and on the tracker.

Left alone: the Sort, Restock and Layout journeys (`docs/PLAN-restock-ux.md` and #55 and #206 own
them), the sync protocol (no rank check ever enters `src/Sync.lua`; section 10 says why again), the
look (the visual doc), the data layer, and any code: this is a design document and nothing is filed
until it has been read.

**The rule above every decision here (Russell, 2026-09-21): the ledger functions as a standalone
addon whether or not it is integrated with the hub.** No role's need is met by "the website does
that". kat's WGA Raid Hub is an optional consumer of the export in section 13 and never a
dependency of a view.

## 2. Ground truth

The guild is We Go Again. Read from `GuildBankLedger.lua` in the maintainer's SavedVariables on
2026-09-21 with a Lua one-liner over `GuildBankLedgerDB.global.guilds`:

- 13,396 item records, of which 6,082 are tab-to-tab moves, 5,267 withdrawals and 2,030 deposits;
  5,394 money records (4,212 repairs, 1,105 withdrawals, 77 deposits); 17 records with a corrupted
  `type` (the data-model milestone's business, #75). 384 distinct names across both arrays.
- 45 characters have synced (`knownPeers`), 20 of them seen within the last day. Grouped by name
  stem that is about 20 people; an estimate, since the addon records no alt links (#52).
- Access control as the GM set it on 2026-04-22: `rankThreshold = 3`,
  `restrictedMode = "own_transactions"`. Sort access: `sort` tier rank 3, `write` tier rank 2, no
  delegates. Layout version 175: five display tabs, two overflow, one ignored; 46 stock reserves.
- What the ledger holds per name: 309 of 384 carry at least one repair record, and 181 were active
  (a repair or a withdrawal) in the last 90 days. All-time repair gold per name: median 1,933g, 90th
  percentile 8,945g, largest 35,014g. The 6th to 11th most active names over the last 90 days ran
  7,200g to 7,700g of repairs each and, where they withdrew anything, took 45 to 125 consumables
  plus a few enhancements and gems. Withdrawn units by category over all time: consumables 58,867,
  enhancements 2,908, cogwheel gems 1,788, hydraulic gems 486, vantus runes 144, flasks 132.

Russell's answers, 2026-09-21, to four questions asked before the model was drawn (the 2026-09-01
lesson: an org chart written from genre convention is an assumed field, so the owner is interviewed
first):

- Ranks 0 to 3 are "leadership plus raid leads": people who run raids or manage the bank day to day,
  not only officers. Everyone else is below the line and in Own Transactions mode.
- A member below the line comes to the addon for **what the guild gave them** (withdrawals read as
  value received: repairs paid, consumables taken, over a season) and **their own record**. They
  did not pick "what is in the bank now". And "they mostly don't open it, but could if there was a
  reason to".
- Own Transactions is set for **privacy**: members should not see who else took what. Guild totals
  without names are fine.
- Where members read the ledger going forward: "not yet clear, probably both, different questions"
  (in game: what did I take and what did the guild give me; on the hub: history and reports under
  the hub's own access model). The standalone rule in section 1 came a few minutes later and
  stands above this answer.

## 3. The roles, grounded

The addon already has two access families, and the roles are defined by them rather than by a
chart of the guild.

The view family is `GBL:GetAccessLevel()` (`src/Core.lua:1985-2002`): the GM is `full`; with no
threshold configured everyone is `full`; a rank at or above the threshold is `full`; below it the
level is `restrictedMode or "sync_only"`. Three values, stored in `guildData.accessControl` and
carried on every HELLO (`src/Sync.lua:725`), merged last-writer-wins on `configuredAt`
(`src/Sync.lua:1062-1067`). The bank family is `HasLayoutWrite()` and `HasSortAccess()`
(`src/Core.lua:2141-2155`), two tiers each holding a rank threshold and a delegate list, carried on
HELLO once configured.

| Role | Rank in this guild | View family | Bank family |
|---|---|---|---|
| GM | 0 | `full`, sets access control and sort access | write and sort |
| Officer | 1 to 2 | `full` | write and sort |
| Bank hand or raid lead | 3 | `full` | sort (Sort and Restock; no Layout) |
| Member | below 3, the majority | `own_transactions` | none |
| Sync-only | a mode a guild may choose; today the default when a threshold is set with no mode (`src/Core.lua:2001`) | `sync_only` | none |
| The hub | outside the guild's clients | receives the export from a `full` user (section 13) | none |

"Officer" and "bank hand" are labels for this doc. The addon never reads a rank name; it reads the
index, and a guild that draws its lines elsewhere sets different thresholds.

## 4. What each role comes for

**The leadership set (ranks 0 to 3).** Who took what and when (Transactions, with the type, item,
count and tab); where the gold went, with a manual withdrawal told from a repair at a glance
(Gold; #204's first note); who is drawing on the bank and what the guild spends, with the GM's own
administrative moves excluded so the list means something (Players; #204's second note); the bank
kept in shape (Sort), stocked (Restock) and described (Layout), each gated by the bank family; the
sync state and, for the GM, the two policies (Sync); the export for the hub (section 13). Their
first view is Transactions, as today (decided, section 19); for members it is My record.

**The member.** One question in two forms: what did the guild give me, and what is my record. In
the numbers of section 2 that is a real statement: a member active this tier has had thousands of
gold of repairs covered and taken dozens of consumables, and today the addon tells them nothing of
it, because the one view built for them shows a filtered ledger under a "Consumption" heading that
reads as a table of one. Section 8 is the answer. Members did not ask for current stock, so no
stock view is built for them (the post-1.0 Stock tab stays where it is), and a member who wants to
know what the bank holds opens the bank.

**The hub.** A website that reads a string an officer copies in game (#186, #187), matches
characters by name, and reports under its own access model. It needs the export's shape and a
sample early and the button late. It gets no view of its own here.

## 5. The live defect: members have never seen a filtered list

**Built (#222, 2026-09-22).** `GBL:RecordsForView(guildData)` in `UI/UI.lua` is the one place an
access level decides which rows a tab renders, read by both `SelectTab` and `RefreshUI`, and it
hands `sync_only` two empty tables. `FilterToOwnRecords` matches `ResolvePlayerName(record.player)`
against `GetOwnCharacterNames()`, the account roster plus the logged-in character; both skip the
`UnknownRealm` sentinel, so a cold realm empties the set rather than keying it to something no
record carries. `FilterByPlayer` and its bare-name compare are gone with their three tests, and
`spec/ui/member_view_spec.lua` renders the three history tabs in the mode. `GetAccessLevel` reads
a configured threshold with no mode as `own_transactions`, and `GBL:GuildRankIndex` caches the
last rank read so a momentary nil does not flip the tab signature. The Sync tab's dropdown reads
Member and Sync only over the same wire values. Section 16's roster cases are in
`spec/core_spec.lua`.

Three things this section proposed that the build changed, each from the code review:

- **The ambiguous bare name fails closed.** This section accepts the resolver's limit for
  pre-2026-04-13 rows, but a `playerRealms[name] == false` name resolves to the local realm on
  both sides, so a stranger's rows would render as the member's own under a promise that says
  otherwise. Those records are refused instead, at the cost of hiding the member's own rows of
  that shape. A bare name with no roster entry at all still cannot be told apart.
- **The window right after login stays open**, and cannot be closed in `GetAccessLevel`:
  `GetGuildInfo` returns the guild name and the rank together, so while the rank is unknown there
  is no guild data to read a threshold from and the function has already answered `full`. What
  ships covers a known guild whose rank read comes back empty. Closing the login window needs the
  last guild remembered on disk, which is a second persisted key and a behaviour change; it
  belongs with My record rather than with a hotfix.
- **The account roster fills as characters log in and is never backfilled**, because nothing on
  disk says which of a guild's names belong to this account. The user-facing copy says "the
  characters you have logged in on since updating" rather than every character.

What follows is the reading that produced the fix, kept as the record of how the defect looked.

Verified by reading the call chain on `eda34ea`; the red spec in section 16 is the run.

`GBL:ToggleMainFrame` (`UI/UI.lua:258-267`) calls `CreateMainFrame`, whose last act is
`RebuildTabs` (`UI/UI.lua:104`), which selects the first tab and builds it through `SelectTab`
(`UI/UI.lua:316-384`). In `own_transactions` mode `SelectTab` pre-filters both record arrays to
the current character before building (`UI/UI.lua:345-349`). `ToggleMainFrame` then calls
`RefreshUI` (`UI/UI.lua:273-300`), which reassigns the full `guildData.transactions` and
`guildData.moneyTransactions` to `_ledgerTransactions`, `_goldLogTransactions` and
`_consumptionTransactions` with no filter, and re-renders the built tab from them. So the filtered
list exists between two calls in the same function and is replaced before the frame is seen. The
banner above it still says "Showing your transactions only." (`UI/UI.lua:335`). `RefreshUI` also
runs on bank open (`src/Core.lua:1807, 1825, 1838`), after every scan (`src/Ledger.lua:507`) and
after every sync receive (`src/Sync.lua:3629`).

No spec renders the mode: `spec/access_control_spec.lua` tests `GetAccessLevel` and the bare-name
`FilterByPlayer` (lines 162-188) and never builds a tab. The defect has been in every release since
v0.15.0, the commit that added the mode (`374c7ce`).

Three facts beside it, each part of the same fix:

- `FilterByPlayer` compares `StripRealm(record.player)` to the bare current name
  (`UI/UI.lua:402-410`). A same-named character on another realm passes the filter. The guild
  already records that ambiguity (`playerRealms[bare] = false`, `docs/DATA-MODEL.md`).
- It matches the current character only, so a member's alts see none of each other's rows, and the
  member who raids on two characters has two half records.
- `GetAccessLevel` answers `full` when `GetGuildInfo` has no rank yet (`src/Core.lua:1995`), so a
  member who opens the frame in the seconds after login gets the whole ledger until
  `RefreshAccessTabsIfChanged` (`UI/UI.lua:250-254`) rebuilds on the first roster tick.

This is the one item this doc files regardless of anything else in it, marked `live`
(section 18), because the guild's configured privacy stance has been paper since April.

## 6. The three modes: wire values kept, what each shows

The stored and advertised values stay `full`, `own_transactions` and `sync_only`. That is not
inertia. `RebuildTabs` (`UI/UI.lua:157-185`) treats every level other than `sync_only` as the full
tab set, and only the exact string `own_transactions` triggers the pre-filter, so a new mode value
arriving by HELLO from an updated GM would give every member on an older client the whole ledger.
A renamed mode is a privacy regression for the length of the adoption window. The wire value is
one thing and the label is another:

| Wire value | Label (Sync tab dropdown, CurseForge, README) | Shows |
|---|---|---|
| `full` | Full | the leadership set: History (Transactions, Gold, Players), Bank per the bank family, Sync, Help, Export |
| `own_transactions` | Member | My record (section 8), Sync, Help |
| `sync_only` | Sync only | Sync, Help |

Decided (section 19): when a threshold is set and no mode is chosen, the default becomes Member
rather than Sync only, from the hotfix on. `restrictedMode or "sync_only"`
(`src/Core.lua:2001`) makes the mode with no member value the one a GM gets by not choosing. The
change is one line in the level computation and one in the dropdown's default
(`UI/SyncStatus.lua:224`), display-side, no wire change. Until every client updates, a guild in
that state shows two tab sets by version, which is the ordinary cost of a display change and not a
split.

## 7. "Own" means the account

A member's record is every character they play in this guild, not the one they are logged in on.
The addon can know that without asking anyone: SavedVariables are account-wide, so each character
that loads the addon can write itself into one table on this machine.

- **The roster:** `db.global.characters[Name-Realm] = lastSeen`, written for the character
  logging in, using the qualified form `ResolvePlayerName` produces. Not in `OnEnable`
  (`src/Core.lua:181`): the realm APIs can still be cold there and `GetLocalRealm` answers with
  the `"UnknownRealm"` sentinel (`src/Core.lua:427-430`), so the write sits in the
  `GUILD_ROSTER_UPDATE` handler beside `BuildRosterCache` (`src/Core.lua:1747-1749`), guarded on a
  resolved realm, and a `-UnknownRealm` key is never written. Account level rather than per guild, on the reasoning #52 already
  recorded (a character's home is the account; the guild is where its rows are). AceDB writes the
  same set to `profileKeys` on disk today, which is cited as precedent that recording it is nothing
  new, and not as a dependency (`Libs/` is absent in CI).
- **Never transmitted.** Recording locally is not a privacy event by the project's own rule
  (`lessons.md`, 2026-07-03: the opt-in boundary is where data leaves the machine). #52's
  advertised alt links stay post-1.0 and separate; nothing here changes what crosses the wire.
- **Matching:** the own-rows helper compares `ResolvePlayerName(record.player)`
  (`src/Core.lua:372-386`: a qualified name as is, a bare name through `playerRealms`, then the
  local realm) against the roster's qualified names. The 961 pre-2026-04-13 bare-name records
  resolve through `playerRealms` the way every migration does, and a same-named character on
  another realm does not match. One limit, the resolver's own: a bare-name record whose name
  `playerRealms` marks ambiguous (`false`) falls back to the local realm, so a pre-2026-04-13 row
  by a same-named character on another realm is attributed to the member. That is how every
  migration already reads those 961 rows, it affects no record written since the qualified form
  landed, and the doc records it rather than adding a second resolver.
- **A character that left the guild still matches.** Its rows are still that person's history in
  this guild, and it produces no new rows. A renamed or transferred character keeps its old rows
  under the old name; that is documented behaviour, not repaired.

## 8. My record: the member view

One view, not two. Russell named two things (what the guild gave me, my record) and the honest
shape is one view with the first as a strip over the second, because the strip can only say what
the record shape supports and that is three figures, not a page.

**The strip.** For the selected window, from the member's own rows across the roster:

    Since 2026-08-22 the guild covered 7,529g of your repairs.
    You took 100 consumables, 16 enhancements, 9 gems and 2 vantus runes, and deposited 12 items.

Gold is exact on repairs (`type == "repair"`, `amount`) and on gold withdrawals, and the strip
says both. Items are counts per category and never gold: the addon holds no prices, so no line
here values a flask. Taken and deposited are two gross figures, not a net (a net needs a sentence
of arithmetic under it; decided, section 19). The figures come through
`ComputeGoldLogSums` (`UI/ConsumptionView.lua:172`) and `BuildConsumptionSummary`
(`UI/ConsumptionView.lua:55`), the two computers that already carry a "keep in sync" comment,
and not through a third copy. Records whose `category` is `unknown` (195 synced records that lost
`subclassID`, `docs/DATA-MODEL.md`) count under "other items" rather than vanishing.

**The window.** One date list with three entries: last 30 days, this season, all time. No hour or
day windows on this view. That is what makes the guild line below safe, and a member reading their
own record over the last hour is not a case anyone asked for.

**The guild line.** Under the strip, for the same window, unnamed:

    Across the guild: 412,000g of repairs and 12,800 consumables this season.

Hidden, with text in its place, while the window holds fewer than five distinct names ("Not
enough guild activity in this window to show totals"): on the first day of a season a total is a
name. Never a player count, never a top-items table, never a ranking. Russell's "guild totals
without names are fine" is permission; the standalone rule is what makes the line worth having,
since the addon is where a member sees the guild's scale at all.

**The rows.** The member's own item and gold rows in one Table (the visual doc's component),
newest first, the status cell telling repair from withdraw from deposit from move by icon, text
and colour, with the item, count and tab where they apply. Five sortable columns (Time, Action,
Item, Amount, Tab): the leadership Transactions view's columns with Player and Category folded
out, since every row is theirs and the category is what the strip already totals; Amount holds an
item count or a gold figure by row.

**The empty state.** One sentence: "The guild has not covered any repairs or withdrawals for you
yet." The guild line still shows when its window passes the floor.

**Getting there.** My record is the Member set's first and only History view, so it is what the
frame opens on. The "Open with Guild Bank" toggle moves from the full-only settings row
(`UI/UI.lua:326, 438-445`) to the personal row, so a member can have the frame at the bank; its
default stays off.

The member framing #204 records as homeless ("what the guild provided rather than who consumed
what") lives here and nowhere else. Players stays a leadership view (section 9); it is not reframed
for everyone, because the two audiences ask different questions of the same rows.

## 9. The leadership set

Full access shows what the visual doc's section 6 draws, on the chassis, in this order: History
(Transactions, Gold, Players as the in-tab switch), Bank (Sort, Restock; Layout when the write tier
holds), Sync (the peer Table; access control and sort access for the GM), Help (Changelog, About),
and the export (section 13). Players is the Consumption view renamed as the post-1.0 roadmap already
says, with #204's exclusion list (the GM's administrative moves) as an officer setting on the
guild, not a preference. Nothing in the bank half changes here.

## 10. Data reach, and the promise the guild can make

Every client holds the whole guild's history. Sync is guild-wide with no rank checks, that is a
locked rule (`feedback_sync_no_officer_gate`), and the reason is structural rather than a
preference: gossip converges because every node relays, and a member's client is the node that
carries a record from one raid night to the next. A rank-gated sync was rejected in April and is
rejected again here for the same reason. `own_transactions` is therefore a presentation mode over
a complete local copy, and SavedVariables are a text file (`project_gated_tab_ideas`: "a
convenience/organizational tool, not a security boundary", accepted by design).

So the promise is: **the addon does not show you other members' rows.** Not: the data is not on
your machine. The CurseForge description's Access Control section (`docs/CURSEFORGE-DESCRIPTION.md`,
"Own Transactions Only: restricted users see all tabs but only their own data") and the README's
access-control bullet are reworded in the hotfix PR to say the first thing and to name the Member
view, since a claim on the CurseForge page that the code does not keep is the exact shape the
accessibility rule already forbids.

What reaches which client, for the record:

| Data | Reaches | How |
|---|---|---|
| Item and money records | every client | SYNC_DATA, no gate |
| `accessControl`, `sortAccess` | every client | HELLO, last-writer-wins |
| `bankLayout`, `stockReserves` | clients with sort access (they pull); served to any requester | LAYOUT_REQUEST and LAYOUT_DATA |
| The season (section 12) | every client | HELLO, top-level field, last-writer-wins |
| The roster (section 7), `restock.*`, `profile.*`, the audit capture, the scan snapshot | this client only | never on the wire |
| The export (section 13) | the hub, by hand | a string a `full` user copies |

## 11. Restricted-tab history (#88)

#88 asks whether a member should see synced history for bank tabs their rank cannot view. Under a
threshold, the Member set answers it by construction: a member sees only their own rows, and
nobody has a row on a tab they cannot open. For ranks 0 to 3 it is documented behaviour: a rank-3
bank hand could read the history of a tab a guild restricts to officers. In We Go Again rank 3 can
open every tab (decided, section 19), so the case does not arise here and the note is for other
guilds, whose tab permissions are their own. For a guild with
no threshold at all, everyone is `full` (`src/Core.lua:1992`) and #88 is wholly open; that guild
has chosen to draw no line, and the doc says so rather than filtering on its behalf. #88 closes
as documented behaviour with this wording once the hotfix has shipped.

## 12. The season is a guild fact

#63 asks for a season scope and leaves its home undecided (guild-wide beside `sortAccess`, or per
user beside `db.profile.filters`). It is guild-wide. A season is a fact about the guild; the
member strip's "this season" must agree with the leadership views' "this season"; and the addon is
standalone, so no website owns the definition.

Its home on the wire is a **top-level HELLO field with its own timestamp**, the shape
`layoutUpdatedAt` has (`src/Sync.lua:735`): `season = { start, updatedAt, updatedBy }`, present
only once set, merged last-writer-wins on `updatedAt`, ignored by any peer that does not read it.
Additive, so no floor raise, on the reasoning #108 and #97 recorded. It must not live inside
`accessControl`: the HELLO receiver copies that table's four named keys (`src/Sync.lua:1062-1067`),
so a key added there is stripped by every current peer and re-advertised without it under the same
`configuredAt`, and the guild's season becomes whichever client spoke last. The wire-contract suite
cannot see an additive HELLO field (HELLO keeps parity alone, the 2026-08-10 lesson), so the PR
that builds it asserts the field on both builders directly and proves the assertion by removing it
from one.

Set by the GM from the Sync tab's access-control group, beside the threshold and the mode, because
it is guild state and not a preference (the visual doc keeps guild state off the Settings panel
for that reason), and by the GM alone, the same gate as the two policies beside it (decided,
section 19). The per-user date presets
(`db.profile.filters`, declared and unread) stay per user and are where the three-entry list of
section 8 and the leadership views' longer list keep their defaults.

## 13. The hub seam

The export (#186, #187, milestone 9) is the only data that leaves the guild's clients, and it
leaves by hand: a `full` user (`HasFullAccess`, `src/Core.lua:2006`, which has waited for this
caller) runs `/gbl export` and copies the string; a button on the History group follows the shell.
What the string carries is #186's business (records and a header; never the layout, the sync
state or the roster). The high-water mark is per client (#187).

The in-game and hub split is provisional and recorded as Russell gave it: in game, the questions a
person has at the bank and the member's own record; on the hub, history reporting under kat's
access model. The standalone rule sits above it: every view in this doc is built whether or not
the hub ever reads an export, and the hub's access model governs the hub, not the addon (#88 is
answered here, not there).

## 14. Who sees what

| Role | My record | Transactions | Gold | Players | Sort | Restock | Layout | Sync | Access control | Help | Export | Holds on disk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| GM | hidden | acts | acts | acts | acts | acts | acts | acts | sets | sees | acts | full history |
| Officer (write tier) | hidden | acts | acts | acts | acts | acts | acts | acts | hidden | sees | acts | full history |
| Bank hand (sort tier) | hidden | acts | acts | acts | acts | acts | hidden | acts | hidden | sees | acts | full history |
| Member | acts (own rows, the window) | hidden | hidden | hidden | hidden | hidden | hidden | sees | hidden | sees | hidden | full history |
| Sync-only | hidden | hidden | hidden | hidden | hidden | hidden | hidden | sees | hidden | sees | hidden | full history |
| The hub | none | none | none | none | none | none | none | none | none | none | receives | the export only |

"Acts" is filters, sorts, presses; "sees" is read-only. `/gbl sortpreview` and `/gbl deviations`
follow the Sort column once gated (section 18); today they are ungated but bail without a layout
(`src/Core.lua:2358, 2518`), and only sort-access clients pull one (`src/Sync.lua:1106`), so that
is parity rather than a leak. The last column is section 10 in table form.

## 15. Accessibility contract for My record

In the shape of the visual doc's section 7, which every rebuilt view signs; the Table, filter and
footer rows there apply as written. The elements this view adds:

| Element | Keyboard path | Focus ring | Colour fallback | Font scaling | Screen-reader text |
|---|---|---|---|---|---|
| Window list (30 days, season, all) | first in the walk after the tab strip; Enter opens, Escape closes | ring | the value is text | from the font object | "Window: this season" |
| The strip | not focusable; read as text | none | text-carried, no colour | from the font object, wraps at the frame width | the two sentences |
| The guild line | not focusable | none | text-carried; the hidden state is a sentence, not an absence | from the font object | the sentence |
| Own rows | as the Table's rows; Up/Down; no row action | `selected` fill plus ring | the status cell is icon, text and colour | row height from the font | the row's cells, the type first |
| Empty state | not focusable | none | text | from the font object | the sentence |

The status cell on a member's row carries the same triple encoding as the leadership ledgers
(`GetTxTypeDisplay`, `UI/Accessibility.lua:209`), which is the first time the README's claim would
be true on the view most members see. The verification pass (ROADMAP gate 2) covers this view
with the rest, on screen.

## 16. Testing

Two PRs come out of this doc, and both lead with their test list.

**The hotfix (section 18, item 1), red first.** One spec, `spec/ui/member_view_spec.lua`, with a
fixture guild in `own_transactions` mode (threshold 3, the player at rank 5) holding four rows
inside the 30-day window: the member's own, a foreign member's, a same-named character on another
realm, and the member's alt (in the roster). Because the mock AceGUI `SelectTab` is a no-op
(`project_ui_smoke_test_gaps`, #121), the spec calls `GBL:SelectTab("transactions")` itself, then
`GBL:RefreshUI()` twice, then drives the sync-receive path's refresh, and after each asserts on the
array handed to the renderer (`_ledgerTransactions`) and on the built rows: the own row and the alt
row present, the foreign and the cross-realm rows absent. Before the fix the assertion after the
first `RefreshUI` is what goes red, and the spec names that line. Three more cases: the
`goldlog` and `consumption` tabs the same way (Consumption under a filtered set still reads
"1 active player" over the member's own totals until My record replaces it; the hotfix changes
the rows, not that label); a nil rank with a threshold configured answers the restricted mode
(fail closed, the GM included, until the first roster tick rebuilds the tabs through
`RefreshAccessTabsIfChanged`); and the three bare-name `FilterByPlayer` tests in
`spec/access_control_spec.lua:162-188` updated as a visible step to the qualified comparison. The
roster gets its own small spec: nothing is written while the realm is unresolved, the first warm
`GUILD_ROSTER_UPDATE` writes the qualified name, a second character adds a second key, and nothing
is on any HELLO or SYNC_DATA builder's output (the wire-contract parity test covers the second
half by construction).

**My record (section 18, item 4), on the chassis.** The strip through `ComputeGoldLogSums` and
`BuildConsumptionSummary` against a hand-built fixture whose expected figures are written from
the record shape and not pasted from output; the guild line's floor at four and five names; the
three-entry window; the empty state; the rows through the Table seam of the visual doc's section
8. The season field (item 5): asserted on both HELLO builders directly and proven by a one-sided
mutation, since the parity test cannot see a symmetric addition.

No test runs for this PR: it changes no code.

## 17. What this does to the visual doc and to #204

Revised in `docs/PLAN-visual-overhaul.md` in the same PR: section 5's tab-strip paragraph (a member
without sort access got "History, Sync and Help"; a Member now gets My record, Sync and Help),
section 6 (My record added; "Players under the member-facing framing" removed; the tab list per
role is section 6 and 14 of this doc), section 9 (the hotfix ahead of step 0; My record as step 2b,
after the Table and before Gold and Players), section 10 (its table regenerated as section 18
here) and section 11 (the questions this doc answers removed). Sections 4, 7 and 8 stand.

#204's member journey is My record. Its officer journey, its one vocabulary and its pagination
model are unchanged and still ride the Table step. #204 closes after Gold and Players and My record
have both landed, not at step 3 alone.

## 18. What this proposes for the tracker (nothing is filed)

In build order. `live` means broken in production now and goes first. The `Flag`, `Runs` and
`Needs` columns follow the tracking-issue shape.

| # | Item | Flag | Runs | Needs | What |
|---|---|---|---|---|---|
| 1 | Members see the whole ledger under the Own Transactions banner | live | first, on `hotfix/` off `main`, ahead of everything on #188 | | one own-rows helper shared by `SelectTab` and `RefreshUI`, qualified matching through `ResolvePlayerName`, the account roster written on the first warm roster tick, a nil rank fails closed, the red spec of section 16, the three `FilterByPlayer` tests updated, README and CurseForge reworded per section 10, a patch stamp and CHANGELOG entry (it touches `UI/UI.lua`, so it is a release) |
| 2 | `/gbl sortpreview` and `/gbl deviations` gated on `HasSortAccess` | | beside | | parity with `sortexec` (`src/Core.lua:2464`); not live (section 14) |
| 3 | Open with Guild Bank moves to the personal row | | with 1, or with the shell | Russell | a member can have the frame at the bank; default stays off |
| 4 | My record on the chassis | | after the visual doc's step 2 (the Table) | | section 8 and 15; the Member set's tab list; #204's member half |
| 5 | The season as a guild fact | | after the shell (the visual doc's step 1) | | a top-level HELLO field per section 12, GM-set from the Sync tab's access-control group; the three-entry and the long date lists reading it; #63 |
| 6 | #88 closed as documented behaviour | | after 1 | | section 11's wording |
| 7 | #204 re-scoped | | after 4 and the visual doc's step 3 | | the member journey is My record; closes when both have landed |
| 8 | The visual doc's section 10 rows | | as that doc orders them | | carried forward unchanged except that My record is a step of its own and the tab list per role comes from here |
| 9 | The export button on the History group | | in milestone 9, after the shell | kat (the format, #186) | `/gbl export` first; the button when the shell exists |

Nothing above asks for a change to the order on #188 (Russell, 2026-09-22): these items and the
visual doc's are filed once both docs have been read, and a separate spike then reorders the
tracker and the work order with everything in front of it. Item 1 is the one placement that spike
inherits, because a live item takes position 1 wherever it sits, by the tracker's own rule.

## 19. Decisions taken on this doc (Russell, 2026-09-21)

Seven questions were open when the doc was written; all seven were put to Russell the same night
and are recorded here, each folded into the section it belongs to.

- **The nil default** (section 6): a threshold with no mode means Member from the hotfix on.
- **Gross, two figures** on the strip (section 8): taken and deposited stated separately.
- **The guild line stays** (section 8), with the five-name floor and the 30-day minimum window.
- **The GM alone sets the season** (section 12), the same gate as access control and sort access.
- **Rank 3 can open every bank tab** in We Go Again (section 11), so the rank-3 residual does not
  arise here, and #88 closes as documented behaviour with that note.
- **Leadership opens on Transactions**, as today (section 4).
- **Help is a bottom tab**, as the canvas draws it (the visual doc's section 5).

The one item still marked for Russell in section 18 is whether "Open with Guild Bank" moves to the
personal row (item 3); it was not put as a question and rides the hotfix or the shell as he
prefers.

## 20. Sources

- `src/Core.lua` (`GetAccessLevel` 1985-2002, `HasFullAccess` 2006, `HasLayoutWrite` 2141,
  `HasSortAccess` 2150, `ResolvePlayerName` 372-386, `OnEnable` 181, the slash commands' layout
  bail 2358 and 2518, `openOnBankOpen` 130 and 1802), `UI/UI.lua` (`CreateMainFrame` 14-105,
  `RebuildTabs` 154-237, the tab signature 241-254, `ToggleMainFrame` 258-267, `RefreshUI` 273-300,
  `SelectTab` 316-384, `FilterByPlayer` 402-410, the settings rows 430-512),
  `src/Sync.lua` (the HELLO builders 716-737 and 795-810, the `accessControl` merge 1053-1075,
  the layout pull gate 1106, the post-receive refresh 3629), `UI/ConsumptionView.lua`
  (`BuildConsumptionSummary` 55, `ComputeGoldLogSums` 172), `UI/SyncStatus.lua` (the access-control
  group 169-258), `spec/access_control_spec.lua`, `spec/ui/tab_visibility_spec.lua`,
  `spec/wire_contract_spec.lua` (HELLO parity 552-561).
- `docs/DATA-MODEL.md`, `docs/ROADMAP.md`, `docs/CURSEFORGE-DESCRIPTION.md`, `README.md`,
  `docs/PLAN-visual-overhaul.md`, `docs/PLAN-restock-ux.md` (section 12's contract shape).
- Issues #204, #88, #63, #52, #186, #187, #65, #206, #55, #214, #121, #75; milestones 9 and 10; the
  tracking issue #188.
- Project memory: `project_member_facing_value` (April 2026, the framing), `project_deployment_model`,
  `project_gated_tab_ideas`, `project_alt_linking_design`, `project_ledger_export`,
  `feedback_sync_no_officer_gate`, `project_ui_smoke_test_gaps`; lessons 2026-07-03 (the opt-in
  boundary), 2026-08-10 (HELLO parity is blind to additions), 2026-08-13 (grep the prose),
  2026-09-08 (a mechanism sentence is not the code), and the global 2026-09-01 lesson (interview
  the owner before drawing the org chart).
- The SavedVariables read: `GuildBankLedger.lua` under the retail account's `SavedVariables`, read
  with a Lua one-liner on 2026-09-21; the numbers in section 2 are from that read and no name
  appears in this doc.
