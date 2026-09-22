# Restock design: the journey before the rebuild (#56)

Written 2026-09-20 against `main` at `63b32cc` (v0.39.19), after the 2026-09-19 walk on #56, the two
auction-house captures on #199 and the double purchase filed as #209. It is the design the Restock
rework (milestone 2) is rebuilt from: every section names the issue it answers, says what the code
does today with the function and the quoted text beside each anchor (line numbers rot; the text is
the citation), states the decision, and ends with the questions only a run in game can settle. The
rebuild order at the end is filed as issues when this doc lands, one gated PR per step, and each
step's plan starts from the test list written here.

This supersedes the roadmap table in `docs/PLAN-restock-integration.md` (its Bulk mode row is #59,
its TSM price preview row is #196) and corrects that plan's risk 4: bought items arrive by mail, not
in bags. The rest of that document is the record of how the tab was scoped and ported, and stays.

Decisions taken at plan approval on 2026-09-20, each open to reversal in review of this doc: Done is
retired; a confirm-at-price pause is on by default; `maxPrice` and the local override store are
retired; the one-off purchase is one control rather than a per-row input; #209 is designed here and
built first, ahead of the UI rebuild.

## 1. The journey today

Buying one stack takes thirteen steps behind five preconditions (a bank layout with display tabs,
sort access, Auctionator installed, the bank scanned once this session, and Auctionator's Shopping
tab on screen). Three of the five fail with a chat line while the Search button stays live:
`StartRestockSearch` prints "Restock needs the Auctionator addon", "Open the Auctionator Shopping
tab first, then search" and "Open the guild bank first so Restock knows current stock" and returns,
and the button disables only on `IsAuctionatorReady()` (`UI/RestockView.lua`,
`searchBtn:SetDisabled(not self:IsAuctionatorReady())`).

The 2026-09-19 walk (on #56) read the tab in both auction-house UIs. Before the first scan every row
shows its full target as the amount to buy and nothing says the number is provisional. Space and the
arrow keys drive the tab instead of the character: an arrow moves focus onto Scan bank, and Space
fires it. With TradeSkillMaster's auction UI up, Search is enabled and refuses into chat, naming a
tab that is not on screen (#193). In the default UI a 36-item search takes just under a second an
item. Every row then reads `lowest <price>`; the three other row states were not reached because
every layout item was a priced commodity. The budget box shows a typed value after clicking away and
commits only on Enter. A single Buy spends the shortfall with no confirmation from the addon and no
dialog from the game. Buy all wedged on "Confirming purchase..." after its first purchase (#199,
fixed in v0.39.19). Bought items land in the mailbox, and a new search inside that window offered
them again; on 2026-09-20 that bought three rows twice for 6241g (#209). The READY list says `need
N` where the IDLE list says `Buy N`.

The buy flow is measured, twice (#199). A commodity purchase is two calls. The start asks the server
for a quote and needs a hardware event: `StartCommoditiesPurchase` is documented `#hwevent`, and a
start issued from any handler or timer does nothing and raises nothing (four of four handler starts
swallowed, nineteen of nineteen click starts sent). The quote arrives as `COMMODITY_PRICE_UPDATED`, and the
confirm goes out on the `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` that follows it (twenty of twenty
confirms issued that way succeeded). A click while the throttle is busy is queued by the client and
works (four of four). Everything the flow sees is on the system channel as `Restock AH:` lines and
comes back out of the capture with `lua scripts/audit-sessions.lua <path> --session N --channel
system`.

## 2. The journey designed

Open the tab: the list is right if the bank has been open this session, and says what it is waiting
on if not. Click Search: one click, and if it cannot run, the button is disabled and the banner says
why. Buy row by row, or Buy next: one click starts a purchase, the quoted total shows, one more
click confirms it (or none, with the pause off). Collect the mail, deposit, and the list is right
again, because each purchase stays counted as "in the mail" until the ledger sees the deposit.

Five preconditions become four disabled states with reasons and one that the design removes (#194).
Thirteen steps become: open the tab, Search, then two clicks per purchase, then the mail and the
deposit, which are the game's steps and not the addon's.

## 3. State model

Today (`src/Restock.lua`, "Session state on self._restock"): `IDLE`, `SEARCHING`, `READY`,
`CONFIRMING`. READY replaces the item list with the result list, CONFIRMING replaces it with one
line ("Confirming purchase..."), and both Done and Cancel call `ResetRestockSearch`, which will
"stop any in-flight Auctionator search" and "clear results and buy progress" and lands in IDLE. Done
is the only way out of a search, and Search is not offered in READY.

**The item list renders in every state.** IDLE shows targets; READY shows the same list with a
price and a Buy button on each row that has one; CONFIRMING and the new `PRICED` state mark the row
in flight inline and disable the other Buy buttons. Nothing replaces the list.

**Done is retired.** The controls row offers Scan bank and the budget in every state; Search in IDLE
and READY whenever its preconditions hold (section 4); Buy next in READY; Cancel in SEARCHING,
CONFIRMING and PRICED; Confirm in PRICED. A search from READY starts a new search: `bought` and
`skipped` are per search and reset, the pending store (section 6) is not. Closing the window or
leaving the auction house keeps the READY list with its prices; the Search button is disabled with
the reason until the auction house is open again.

**Cancel** keeps its two meanings: in SEARCHING it stops the Auctionator search; in CONFIRMING and
PRICED it drops the purchase at the auction house (`CancelCommoditiesPurchase`, nothing spent) and
returns to READY with the list intact rather than to IDLE. CONFIRMING also covers the wait after the
confirm went out, where a cancel means nothing ("confirm already issued, no cancel"); that branch
keeps its no-cancel rule and, since step 1, parks the purchase in the pending store flagged
unconfirmed, because the gold may have moved and the reset unregisters the events its result would
arrive on. The reset to IDLE that `ResetRestockSearch` performs stays as the path a failed search
takes (Auctionator gone, names did not load).

**A confirm with no result** (`st.unanswered`, kept when "a cancel means nothing now") blocks new
starts within its search and was dropped by `ResetRestockSearch` and by `_RestockOnSearchEnd`
(`st.unanswered = nil` at both) until step 1, which parks it in the pending store flagged
unconfirmed at both sites (`parkUnanswered`), so the row says "N bought, result unknown, check your
mail" instead of forgetting the gold. The block stays for the life of the search; parking happens
where the record used to be dropped, so the window in which a late result can be taken for the
next purchase (the events carry no id) is the one v0.39.19 already had, not a wider one.

Tests: each state renders the item list (the READY rows carry prices, the CONFIRMING row carries its
marker); Search is offered in READY and starts a new search that resets `bought` and `skipped` and
leaves the pending store alone; Cancel in PRICED cancels the purchase and returns to READY with
`activeItems` intact; a new Search with `st.unanswered` set writes the pending entry with
`unconfirmed = true`.

**Built 2026-09-20 in PR A of #211 (v0.40.0), the flow half.** PRICED exists, and Cancel in
CONFIRMING and PRICED (`CancelRestockPurchase`) returns to READY with the list intact; with the
confirm already out it keeps the purchase as the unanswered record (no new start until the result
lands, the late result credits it) rather than parking it, since the code review found a parked
purchase left the row buyable with the buy events registered and the late result would have landed
on the next purchase. Done, Search in READY and the list in every state are the view half, #214.
One thing the step 1 review added: a purchase result arriving in PRICED is another addon's
purchase (no confirm of ours is out, and the client holds one commodity purchase at a time, so
ours was replaced at the server); it ends the pause with a chat line and credits nothing.

**Built 2026-09-21 in PR B of #214 (v0.41.0), the view half.** The list renders in every state,
decorated per row from the session; Done is gone; Search is offered in READY and runs the reset's
teardown first (`_RestockSearchTeardown`, shared with `ResetRestockSearch`), so the unanswered
confirm is parked before the buy events drop and the pending store is left alone. A searched row
that has since left the layout is kept under its own heading, and a searched row whose live
shortfall dropped to 0 keeps its Buy: Buy next walks the search's snapshot, and a list that hid a
row it would still buy would lie; a re-search is one click away. The code review of PR B moved the
teardown ahead of the buy list (the parked quantity is subtracted before the new list is built),
gave the confirm still awaiting its result its own row status with every Buy greyed and the reason
on the banner, and dropped the buy events when the house closes with nothing in flight.

## 4. Preconditions as disabled states (#43, #193, #194)

Search is disabled with its reason on the banner, text-carried (no colour-only state), one reason at
a time in this order:

| Precondition | Read from | Banner text | Refresh on |
|---|---|---|---|
| Auctionator present | `IsAuctionatorReady()` (exists) | "Restock needs the Auctionator addon to search and buy. Targets still display below." (exists) | addon load |
| Auction house open | `AuctionHouseFrame` and `AuctionHouseFrame:IsShown()`, guarded | "Open the Auction House to search." | `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED` |
| Not behind TSM's UI (#193) | `TSM_API` and `TSM_API.IsUIVisible("AUCTION")`, dot-called, guarded | "The Auction House is showing TradeSkillMaster's UI. Click its Switch button for the default UI, then search." | the same two events, plus the tab's own rebuild |
| Bank scanned this session (#43) | `GetLastScanResults()` (exists) | "Waiting on the bank scan. Open the guild bank, or click Scan bank, so in-bank counts are right." | `GBL_SCAN_COMPLETE` |
| Something to buy | the buy list (section 9 counts one-offs) | "Nothing to buy: the bank is at target for every layout item." | any rebuild |

The Shopping-tab precondition ("Open the Auctionator Shopping tab first") goes with #194: the public
`Auctionator.API.v1.MultiSearchAdvanced` selects the tab itself. Until #194 lands it stays as a
disabled state with today's wording. Whether that search runs behind TSM's frame (the default frame
is shown at scale 0.001) is the first in-game question below; if it does, the TSM row above is not
needed and #193 closes on the observation.

**Every refresh goes through Core.** AceEvent keeps one callback per object per event,
`RegisterMessage` included, Sort reads the same scan, and this repo has been bitten by the shadow
three times (`UI/RestockView.lua`, "registering it would shadow"; `src/SortExecutor.lua`; the Frame
Hide incident). Nothing registers `GBL_SCAN_COMPLETE`, `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED`
or `PLAYER_MONEY` anywhere in `src/` or `UI/` today. Each gets one handler in `src/Core.lua` shaped
like `OnBankLayoutChanged` ("each refresh self-guards on the active tab"): `OnScanComplete`
refreshes Sort and Restock, which also makes the Scan bank button refresh the tab (today
`ManualScan` calls `StartFullScan` and nothing else; the rows corrected on the walk only because the
bank-open chain's `ScanTransactions` callback calls `RefreshUI`); `OnAuctionHouseToggled` refreshes
Restock.

**Before the first scan the rows say so.** `stock` reads 0 for every item with no scan, so `toBuy`
reads the full target (#43's case). The row shows `bank ?` and no shortfall figure until a scan has
completed, and the status is "bank unknown" rather than "short N".

Tests: each precondition failing alone disables Search and puts its text on the banner; two failing
shows the first in the table's order; the TSM row is chosen only with `TSM_API` present and its
predicate true, and today's wording with `TSM_API` nil; a stubbed `GBL_SCAN_COMPLETE` through the
Core handler rebuilds the tab; rows before the first scan carry no shortfall.

**Built 2026-09-20 in PR A of #211, all but two rows.** The table is `SEARCH_BLOCKERS` in
`src/Restock.lua`, read by `_RestockSearchBlocker`, and Search disables on the first failing entry
with its text on the banner. The TSM row is not built: question 1 below decides it, and until then
the Shopping-tab row keeps today's wording. The `bank ?` rows are the view half (#214). The two
Core handlers are `OnAuctionHouseToggled` and `OnScanComplete`, and the second refreshes Restock
only: the step 1 review found the Sort tab already polls `scanInProgress`, so a rebuild from the
handler would double its refreshes and fire on every executor end-of-pass scan. The review also
found that Buy, Buy next and Confirm carried no auction-house gate (the only guard on a start was
the existence of the API); all three disable with the same reason as Search, and a start is
refused pre-start without the frame. The gate reads the `AUCTION_HOUSE_SHOW`/`_CLOSED` flag first
and the frame second (the review: an addon can hide the frame with the session open), and a close
drops a quote or a start still waiting for its price, since the server discards its pending
purchase with the session.

**Built 2026-09-21 in PR B (#214).** `_RestockBuildItemUniverse` puts `scanned` on every row and
the row reads `bank ?` and `bank unknown` with no shortfall until a scan has completed. #217
(Search stayed disabled after the Shopping tab was selected, nothing re-read the blocker on that
change) shipped 2026-09-22 as v0.41.1: the frame's OnShow and OnHide redraw the tab once per burst, in IDLE
and READY, only when the reading changed, installed lazily because Auctionator creates the frame on
the first Auction House show; the hook goes with the precondition at #194. #218 (a countdown on
the PRICED banner) follows.

## 5. Row vocabulary (#44, #56, #205, #209)

One table of status texts, `RESTOCK_STATUS_TEXT`, read by `GetRestockStatusDisplay` (the row), the
chat lines and the log, the way `SortReasonText` serves the sort tab and the preview (#45: two
renderers of one field disagreed once already). Each status is triple-encoded: an icon, a palette
colour through `GetAccessibleColor`, and text. The grey annotations (`|cffaaaaaa`, three sites, #44)
read a palette colour instead of a literal.

A row reads: icon, name, `target N`, `bank N` (or `bank ?` before a scan), `in the mail N` when
pending, `short N`, the status, and a Buy button when one applies. `short` is the one word for the
figure in every state; the button says `Buy N (~Xg)` with X the lowest price times N (a lower bound,
hence the tilde).

| Status | When | Buy button |
|---|---|---|
| bank unknown | no scan this session | no |
| in stock | short 0 | no |
| short | short N, no search yet | no |
| sourced elsewhere (#205) | the layout item is flagged not bought here | never; not searched |
| priced | READY, the row has a lowest price | `Buy N (~Xg)` |
| not a commodity | READY, found with no unit price (the `found` case today) | no; "buy it by hand" |
| not found | READY, no listing | no |
| buying | CONFIRMING, this row | no (all Buys disabled) |
| quoted Xg, confirm? | PRICED, this row | Confirm / Cancel in the controls row |
| bought N for Xg | this search, from the priced total | no |
| skipped: <reason> | this search, from `st.skipped[i]` | no |

The skip reasons are the ones `st.skipped[i]` already carries since v0.39.19 ("max price", "budget
on this buy", "cannot afford", "budget at price", "no price within 5s", "no price available", "no
usable price"), rendered through the table as "over your budget (raise the budget to bring it
back)", "not enough gold", "over your max price", "no price from the auction house". A budget change
already clears the budget ones (`SetRestockBudget`, "the open search skipped for the budget"); the
row text says so.

"In the mail" is a modifier, not a status: the shortfall is `max(0, target - bank - pending)` and
the row carries `in the mail N (2h ago)` with a Clear button beside it (section 6).

Tests: every status in the table has text, an icon and a colour, and no two share a text; every
reason `failStep` and the pre-start refusals write has a row text; the row for a pending item
renders the modifier and the reduced shortfall; the grey sites are gone.

**Built 2026-09-21 in PR B of #214 (v0.41.0), with three decisions.** `RESTOCK_STATUS_TEXT` in
`UI/RestockView.lua` holds eleven statuses, the ten above less "sourced elsewhere" (#205, not yet
built) plus `in the mail` as a status of its own for a row whose shortfall the mail covers (the
#215 reading), each with text, an icon and a palette role; `_RestockRowStatus` is the pure
classifier, session over search over universe. The skip reasons are eight, not seven (`cannot
afford at price` was missing here), constants in `src/Restock.lua` with `RestockSkipText` beside
them; `quote expired` and `throttle never freed` never reach `st.skipped`. The table serves the
row: the log keeps the raw code, which a capture is searched by, and the chat lines keep their own
wording, which carries the figures, so this section's "the chat lines and the log" read the row
only. The button says `Buy N (~X)`, the estimate rounded to whole gold above one gold. After the
review: twelve statuses (`awaiting result` for the confirm with no result yet), "not a commodity"
keyed on the item key's `isCommodity` (Auctionator prices gear and pets like anything else),
"priced" needing a usable price, and one buyable predicate shared by Buy next and the tab.

## 6. Pending purchases (#209)

Today `_RestockBuildItemUniverse` computes `toBuy = target - stk` from the latest scan, `st.bought`
lives for one search, and nothing carries a purchase forward: an auction-house purchase arrives by
mail and is not in the bank until the officer collects it and deposits it. Any search in that window
offers the row again.

**Store.** `guild.restock.pending[itemID] = { qty, buyer, buyers, at, unconfirmed }`: per guild,
persisted in the same `restock` table as `budget` (`src/Core.lua`, `restock = { items = {}, budget =
0, pending = {} }`), local to the account and not synced, because the mail is the buyer's. `qty` is
added on `COMMODITY_PURCHASE_SUCCEEDED` and on the late credit, `buyer` is the buying character as
`ResolvePlayerName` writes it on ledger records, `buyers` is the set of characters on the account
that bought into the entry (the store is per account, so an alt's purchase joins the main's and
either one's deposit settles it), `at` is `GetServerTime()` of the first purchase, `unconfirmed` is
set by the two parking sites in section 3 and stays set until the entry clears.

**Read.** The universe row carries `pending`, the shortfall is `max(0, target - stock - pending)`,
the buy list uses that shortfall, and the row shows the modifier with its age.

**Cleared by the ledger, not by the bank scan.** A scan cannot tell the buyer's deposit from another
member's: a foreign deposit would clear the entry early and re-offer the row, which is the bug, and
a withdrawal in the window would leave it stuck. The ledger already records every deposit with `type
= "deposit"`, `player`, `itemID` and `count` (`src/Ledger.lua`, the item record builder), and the
periodic rescan runs while the bank is open. Two intake paths store a record for the first time, and
each stores it once: a scan through `StoreBatchRecords` (`src/Dedup.lua`, count-based dedup) and a
sync receive through `StoreTx` (`src/Ledger.lua`, `IsDuplicate`), so the hook `_RestockOnRecordStored`
has two call sites (not `UpdatePlayerStats`, which the migration rebuilds call over old records). The
rule: a stored record with `type == "deposit"`, `player == buyer`, that `itemID`, and a timestamp at
or after `at` less a one-hour window (`RESTOCK_PENDING_WINDOW`; ledger timestamps are hour-coarse,
`ComputeAbsoluteTimestamp(year, month, day, hour)`, in a rounding direction nobody has recorded, so
the window rather than the hour of `at`) drops the entry's `qty` by the record's `count`; at zero it
is removed; a partial deposit leaves the remainder. Built 2026-09-20 as rebuild step 1; the section
was corrected then, since the first draft said the sync copy took the scan's path.

**Manual clear.** A Clear button on the row removes the entry: a deposit from an alt (#52 is
unbuilt, so the ledger cannot match it), items that went somewhere else, or an unconfirmed purchase
the mail settled. An entry older than a day says so on the row.

**Limits, stated.** A deposit of the same item by the buyer up to two hours before the purchase,
stored for the first time after it, matches the rule and clears the entry early; the manual clear and
the age are the answer, and the failure lands on the side of an early re-offer, which the
confirm-at-price pause then shows as a quote to decline. The window is a reading, not a constant:
each deposit line logs the record's offset from the purchase (`recorded +Ns after the purchase`), and
a run of positive readings is the case for tightening it to zero. Store-time dedup is not the whole
story either: the bank-open chain runs `CleanupWithEventCounts` after the scan because a synced copy
and the buyer's own scan of one deposit can land under two ids, and the hook fires once per stored
copy, so that pair would reduce the entry twice. It needs the synced copy to arrive before the
buyer's own client scans the deposit it just made, with the periodic rescan running every few
seconds at the bank, which is why it is accepted rather than guarded: a guard keyed on the record's
prefix would also skip the second of two real deposits of the same count in one hour, which is how
two stacks are deposited. A late result after the entry was parked is credited to whatever
purchase is in flight, or ignored; the entry stays unconfirmed until the ledger or the officer clears
it. Pending is per account, so an officer's alt sees the entry with
the buyer's name and cannot match its own deposit to it.

Tests (the first rebuild step's plan starts here): a purchase then a scan before the deposit leaves
the entry intact and the shortfall reduced; a stored deposit record of the full quantity by the
buyer at or after the purchase hour clears it; a partial deposit reduces it; a deposit by another
member changes nothing; a withdrawal changes nothing; a deposit of another item changes nothing; a
record stored twice (the dedup path) counts once; a manual clear removes the entry; a late credit
adds to it; a new Search with an unanswered confirm creates an entry with `unconfirmed`; the
shortfall clamps at zero when a foreign deposit fills the gap; the entry survives a reset of session
state.

## 7. Budget and spend (#60)

Today the READY banner reads Spent as `_RestockSpent(st.runStartMoney, GetMoney())`, the wallet
delta since the search; `budgetBlocked` and the pre-start budget refusal read the same delta; and
`runStartMoney` is set once, in `_RestockOnSearchEnd` ("baseline for the budget cap"). Close the
window in READY, spend anywhere else, reopen: the Spent figure counts gold restock never spent and
every Buy button disables with nothing on screen saying why (#60's three symptoms).

**Budget and Spent read `spentEstimate`.** Since v0.39.19 it adds the priced total on each success
(`creditPurchase`, "priced total when the price event carried one"), so it is exact for every
purchase the flow made and blind to everything else. The banner, `budgetBlocked`, the pre-start
refusal and the refusal at price all read it.

**Affordability keeps a wallet baseline.** `affordableMoney` bounds `GetMoney()` with `runStartMoney
- spent` because the wallet trails the purchase events; that bound is right and stays. It is
re-baselined when the tab is shown (`SelectTab`, the window opening) with nothing in flight, never
on the rebuild a purchase result triggers, so the lag-free bound survives the moment it exists for.
The safe direction of a stale baseline is a refusal, and the refusal at price re-reads the wallet.

**The budget lives above the list in every state**, an EditBox committed on Enter with the committed
value beside it ("Budget: 5000 g" or "Budget: none"), so a typed value that was not committed reads
as such. The confirm-at-price toggle (section 8) sits beside it.

**Gold shows in every state**, on a second banner line with Spent, updated in place from a Core
`PLAYER_MONEY` handler while the tab is active (a label `SetText`, not a rebuild, since the refresh
flicker is a known cost of the full rebuild).

Tests: the Spent figure and `budgetBlocked` ignore a wallet change with no purchase; a purchase's
priced total moves both; the baseline moves on tab show with nothing in flight and not on a rebuild
from a purchase result; the budget box renders in IDLE and READY and its committed value is shown
apart from the typed one; the gold label updates on the money event without a rebuild.

**Built 2026-09-20 in PR A of #211, with one correction from the step 1 review.** Re-baselining
`runStartMoney` alone double-subtracts: `affordableMoney` was `runStartMoney - spentCopper`, and a
baseline of the debited wallet against the search's whole spend refuses a 5,000g row with 7,000g
in hand after a 3,000g purchase. The baseline is a pair, `walletBase` and `spentAtBase`, moved
together by `_RestockOnTabShown` (from `SelectTab` when the tab comes into view, never from
`RefreshRestockTab` and never from the `SelectTab` that `RefreshUI` runs after a sync receive or a
rescan while the tab is already showing, which the review found could land inside the wallet lag
after a purchase), and remaining is `walletBase - (spentEstimate - spentAtBase)`. `_RestockSpent`,
the wallet delta, is gone. The budget box above the list and the gold line are the view half
(#214).

**Built 2026-09-21 in PR B (#214).** The budget row (the box, `Budget: N g` or `Budget: none`, the
confirm-at-price toggle) sits above the list in every state, both held while a purchase is in
flight, and Confirm re-checks the quote against the budget and the wallet at the click; the gold
line is a second banner label rewritten in place by Core's `OnPlayerMoney` while the tab is
active, never a rebuild, its reference dropped by the label's own `OnRelease`.

## 8. The buy step (#56, #199)

Each purchase is one click to start and, with the pause on, one click to confirm. The button carries
the estimate (`Buy 11 (~5228g)`); the quote carries the real total.

**Confirm at price**, a per-profile setting (`db.profile.restock.confirmAtPrice`, default on, a
CheckBox beside the budget). With it on, `COMMODITY_PRICE_UPDATED` runs today's checks (a usable
total, the wallet, the budget) and then, instead of issuing the confirm, cancels the step timer,
enters `PRICED`, and puts the quote on the banner: "Quoted 5227g 97s for 11 x Item. Confirm?" with
Confirm and Cancel. Confirm needs no hardware event (`ConfirmCommoditiesPurchase` carries no
`#hwevent`), so the click runs `issueConfirm` at once when the throttle is free and defers to the
next `THROTTLED_SYSTEM_READY` when it is not, the one seam the flow already has; the click re-arms
the step timer. Cancel drops the purchase and returns to READY. A second `COMMODITY_PRICE_UPDATED`
in PRICED re-runs the checks and re-prices the banner (today it is "ignored (price already in)",
which is right only because nothing waits there). With the toggle off the flow is v0.39.19's: the
confirm goes out on the READY after the price.

**Inline progress.** CONFIRMING and PRICED mark the row ("buying", "quoted Xg") and disable the
other Buy buttons; the list stays. The result lands on the row ("bought 11 for 5227g 97s") and keeps
its chat line and its log line. Buy next keeps its `(N left)` count and walks past refused rows
inside the click, as today.

**Focus.** A Buy click moves focus to Confirm so Enter confirms; Escape cancels (section 12).

In-game question, gating this step: what the server does with a quote left unconfirmed for minutes
(whether it expires, and whether a start after it needs a cancel first). Until read, the pause
carries a 60s timeout that cancels the purchase and says so.

Tests: with the pause on, a price event enters PRICED and issues no confirm; Confirm issues it (at
once when the throttle is free, on the next READY when busy); Cancel in PRICED cancels and returns
to READY; a second price event in PRICED re-checks the budget and updates the total; the step timer
is off in PRICED and re-armed by Confirm; with the pause off the flow matches the v0.39.19 spec; the
row in flight renders its marker and every other Buy is disabled.

**Built 2026-09-20 in PR A of #211.** The pause reuses the one step timer (`armStepTimer(self,
seconds)`, `RESTOCK_PAUSE_TIMEOUT = 60` until question 3 is read), and a Confirm click that finds
the throttle busy arms it as well, so a READY that never comes ends as `throttle never freed`
rather than a wait with no timer. A quote the pause gives up on leaves the row buyable under Buy
next too (`failStep`'s `keepRow`), since the player rather than the auction house ended the step.
The inline row marker is the view half (#214); until it lands PRICED replaces the list with one
line, as CONFIRMING does. Two review changes to this section: a second `COMMODITY_PRICE_UPDATED`
(or a `_UNAVAILABLE`) in PRICED ends the pause with no cancel instead of re-pricing the banner,
because the events carry no item and the price may be another addon's start, in which case ours is
gone from the server and a cancel would cancel theirs; and the price of a start Cancel dropped
before it arrived is consumed as that start's answer until its READY, so it cannot become the next
purchase's quote. Confirm is focused on the one rebuild that enters PRICED and on no later one.

## 9. One-off purchase (#59)

Restock buys to a target; stocking up before a season means raising Store and remembering to put it
back. `_RestockBuildBuyList` is the chokepoint (`needed = row.toBuy`, its one source)
and `StartRestockSearch` refuses an empty list ("Nothing to buy").

**One control, not a per-row input.** Above the list: an item Dropdown over the layout's display
items, a quantity EditBox, and Add. Each Add writes `st.oneOffs[itemID] = qty` (session-only, on
`self._restock`), rendered as a "One-off" group at the top of the list with `short N` and a Remove
per row. The buy list folds the one-off into `needed`, Search runs when only one-offs exist, a
bought one-off leaves the group, and a purchased one-off enters the pending store like any other so
the row says the mail is coming. A per-row input was declined: it would register a focusable on
every row and turn the keyboard walk into forty stops.

Tests: a one-off on an item at target produces a buy list of that quantity; a one-off on a short
item adds to the shortfall; Search runs with only one-offs; Remove empties the group; the group is
gone after a reload (session state).

## 10. Do-not-buy (#205)

Some layout items are never bought at the auction house (Gateway Control Shards) and Restock treats
them as any shortfall. The local `enabled` override exists, is honoured, has no writer, and is the
wrong store: `restock.items` is per-guild-local and unsynced, so a flag there stops one officer and
not the next.

**Model.** `noBuy = true` on the layout item, beside `slots` and `perSlot`. `copyTab` is a whitelist
(`src/BankLayout.lua`, `copy.items[itemID] = { slots = row.slots, perSlot = row.perSlot }`) and
gains the key; `Validate` accepts a boolean or nil; the LAYOUT_DATA round-trip specs carry it.
`LAYOUT_SCHEMA_VERSION` stays at 2: the change is additive, and the mixed-version hazard (an older
client adopts the layout with the key stripped by its own `copyTab` and, if it then saves,
last-writer-wins carries the loss until a current client re-saves) is accepted as #57's was, with no
floor raise, and stated in the CHANGELOG when it ships.

**Layout tab.** A "Sourced elsewhere" CheckBox on the item row, write-gated like Slots, Per slot and
Store, draft-until-Save like them. The row is eight widgets wide already; section 11 splits it.

**Restock tab.** The universe row carries `noBuy`; the buy list skips it; the status is "sourced
elsewhere" (section 5), no Buy button, not searched. A one-off (section 9) on such an item is
allowed: the officer asked for it by name.

**The local override store is retired.** `enabled` is superseded by the flag; `maxPrice` has no
input and no writer, and the budget and the refusal at price are the spend guards, so
`GetRestockItemOverride`, `SetRestockItemOverride` and `restock.items` go, with a one-line migration
that drops the table. If a per-item price ceiling is wanted later, it belongs on the layout item
beside Store, guild-wide, and not in a local store.

Tests: a layout with `noBuy` round-trips through `copyTab`, `Validate` and the LAYOUT_DATA payload;
a `noBuy` row is not in the buy list and renders the third status; the Layout row's control writes
the draft and Save persists it; the override store is gone and the universe no longer reads it.

## 11. Layout tab, restock half (#206, #61)

Keep becomes Store (#61: six user-facing strings in `UI/LayoutEditor.lua`, the bulk row's
`keepInput:SetLabel("Keep")`, the per-item row's, the two validation lines, the chat line and the
hint "Set Keep to 0 to clear the reserves on this tab"; `stockReserves` and its accessors do not
move). The rename brings the hint the field never had, under the bulk row and as the field's
tooltip: "Store: how many the guild bank should hold. Restock buys up to the larger of slots x per
slot and Store." The row's `= N` label (`totalLabel:SetText(format("= %d", row.slots *
row.perSlot))`) becomes the effective target, `= N` when Store is at or below it and `= N, target M`
when Store is above.

The item row splits into two lines: name, Slots, Per slot and the total on the first; Store, the
effective target, Sourced elsewhere (#205) and Remove on the second. The whole-tab items in #206
(the keyboard walk, the refresh, the mid-edit sync, render specs) ride whichever rebuild reaches the
file first; this doc claims the restock half only.

The "Reserves (not in a display tab)" group is retired from the Restock list: Store lives on a
display-tab row, so nothing can produce an item with a reserve and no layout demand, and the comment
"reserve producer ships (v0.35)" predates the field. A reserve left behind for an
item no longer in any display tab is ignored by the universe and pruned by `SaveBankLayout`, which
already bumps the cursor the reserves ride on.

Tests: the six strings read Store and the Keep assertions in `spec/ui/layouteditor_spec.lua` move
with them; the effective-target label reads both forms; the Reserves group no longer renders and a
stray reserve is pruned on Save.

**Built 2026-09-21 in PR B (#214), the Store half.** The six strings read Store, the hint sits
under the bulk row and on every Store field's tooltip, and the row's total reads `= N` or `= N,
target M`. The item row did not split into two lines (that rides #205's row control), and the
Reserves group stays until the prune on Save lands (#206).

## 12. Keyboard

Today `_RestockView_NavKey` consumes TAB, UP, DOWN, ENTER, NUMPADENTER and SPACE whenever the tab is
active and the capture calls `SetPropagateKeyboardInput(not handled)`. UP and DOWN call
`AdvanceFocus` from index 0, so an arrow pressed to turn the character focuses Scan bank, and Space
then fires it: the walk's step 2.

**The rule.** With nothing focused (`A11Y.focusIndex == 0`) the capture consumes nothing; Tab is the
only entry into the walk. With a widget focused, Tab and Shift-Tab move, UP and DOWN move, Enter and
Space activate, and Escape clears focus and consumes only itself. A Buy click focuses Confirm during
the pause. The Sort tab shares the walk and the defect; its copy of the rule is filed for the
accessibility milestone rather than built here.

**Built 2026-09-21 in PR B (#214) for both tabs.** The rule is `GBL:FocusNavKey` in
`UI/Accessibility.lua`, which both tabs' key handlers delegate to (the code review of PR B: the
two handlers were character-identical and already shared the walk), and Escape calls the new
`GBL:ResetFocus`; the capture block is invisible to the suite (#166), so the wiring is read in
game. The Sort tab's copy was filed as #219 that day and closed by the same PR. A greyed widget is
not a Tab stop, and Enter on the budget box gives it keyboard focus.

**Every new element, per the project's accessibility rule:**

| Element | Keyboard path | Focus ring | Colour fallback | Font scaling | Screen reader |
|---|---|---|---|---|---|
| Search disabled with reason | none (disabled) | none | text on the banner | `GetScaledFont` | the banner text |
| Budget box and committed label | Tab; Enter focuses the box, Enter again commits; held while a purchase is in flight | `SetFocusIndicator` | text | yes | the label and box text |
| Confirm-at-price toggle | Tab; Space toggles | yes | CheckBox state plus label | yes | label |
| Confirm and Cancel (PRICED) | Confirm focused on Buy; Enter confirms; Tab then Enter cancels; Escape clears focus | yes | text | yes | the banner carries the quote |
| Clear (pending) | Tab, only on rows with an entry | yes | text | yes | "Clear N in the mail" |
| One-off control | Tab through Dropdown, box, Add | yes | text | yes | labels |
| Row status | none (read-only) | none | icon plus text | yes | the status text |
| Per-row Buy | Tab, only when it can be pressed; Enter / Space | yes | text (the estimate) | yes | `Buy N (~X)` |
| Gold line | none (read-only) | none | text | yes | the line |
| Store field, hint and tooltip | Tab; Enter focuses, Enter commits; the tooltip on hover | `SetFocusIndicator` | text | yes | the hint text |
| Effective-target label | none (read-only) | none | text | yes | `= N` or `= N, target M` |
| Orphan heading | none (read-only) | none | text | yes | the heading |

## 13. Rebuild order

One gated PR per step, cut from `main` in order, each with its plan started from the test list in
its section, red first, mutations before the PR, one `/code-review` per PR before the stamp. Each is
filed as an issue when this doc lands, labelled, naming its section here.

1. **Pending purchases** (#209; section 6). First because it is the one open item that loses gold.
   `src/Restock.lua` (store, universe, credit), the ledger hook in `src/Dedup.lua`, the row modifier
   and Clear in `UI/RestockView.lua`, the unanswered case from section 3. Patch bump.
2. **The flow and the tab** (sections 3, 4, 5, 7, 8, 12; #43's restock half, #44, #60, and #61 with
   the #206 restock sweep riding the UI half). Two PRs if the diff asks for it: the model (states,
   the Core handlers, `spentEstimate` as the budget read, the pause) then the view (the list in
   every state, the status table, the banner, the budget's home, the keyboard rule). Minor bump: a
   new setting and a new visible control.
   Split on 2026-09-20 at the re-audit: PR A, `feat/restock-flow-states` (v0.40.0), is the model with
   #60 and the gate, closing #211; the view half is #214, `feat/restock-tab-rebuild` (v0.41.0). The
   v0.40.0 run filed #217 (shipped v0.41.1, 2026-09-22) and #218, which follow #214 in the order.
3. **Auctionator's public search** (#194; section 4), then #193's hint as the observation dictates.
   The first in-game question below gates the hint.
4. **One-off purchase** (#59; section 9).
5. **Do-not-buy** (#205; sections 10 and 11's row split), after the rebuild and ahead of #196, as
   the milestone description places it. Then #196 and #195 as ordered; each hangs off the flow
   above.

## 14. Open in-game questions

Each gates the step named, never the doc.

1. With TradeSkillMaster's auction UI up, does `MultiSearchAdvanced` run and fire `SearchEnd` behind
   the tiny default frame? (Step 3; decides whether #193's row in section 4 is built.)
2. What does Auctionator's temporary shopping list do to the player's list panel between sessions?
   (Step 3, #194.)
3. What does the server do with a quote left unconfirmed for minutes: does it expire, and does a
   start after it need a cancel first? (Step 2; the pause ships with a 60s timeout until read.)
4. The budget refusal at price, and a refusal at price followed by a Buy next click (whether the
   cancel issued from the price handler took effect). (Step 2, carried from #199.)
5. How long the mail takes for a commodity purchase, and whether `GetInboxNumItems` at a mailbox
   could confirm an entry the ledger has not cleared. (Step 1, a possible second signal; not built
   on until read.)

## 15. What stays as it is

The buy flow's two rules from #199 (a start only from a click; the confirm on the ready after the
price), the one throttle seam, the step timer and its two outcomes, the unanswered record, the
`Restock AH:` log lines, Buy next's walk, the skip reasons, the budget-change clear, the
accessibility walk's registration order, `GetRestockStatusDisplay` as the one renderer of row
status, and `spec/ui/restockview_spec.lua` and `spec/restock_buy_spec.lua` as the regression net
every step extends and never weakens.
