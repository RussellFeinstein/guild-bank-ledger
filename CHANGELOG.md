# Changelog

All notable changes to GuildBankLedger will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.37.9] - 2026-08-13

### Fixed
- Vertical bars now show up where they are meant to. WoW treats a single bar as the start of a formatting code, so text that used one as a separator could lose it, and sometimes the letter after it. This affected the peer status tags on the Sync tab ("too old | sync refused" and the rest), the sending and receiving status line, the separators in the Consumption and Gold summaries, several `/gbl` command help lines that show you the options you can type, and a handful of entries in the in-game changelog.

## [0.37.8] - 2026-08-13

### Fixed
- Text the addon puts on screen no longer relies on characters WoW's fonts may not have. Dashes, arrows, multiplication signs and tick marks were drawing as blanks or boxes for some players depending on their font and locale, so a sort progress line could read "Executing 4 / 9" with a hole where the dash belonged, and a Layout tab row that matched the template showed a green mark that was not there at all, leaving colour as the only signal. All of it is plain text now, including the in-game changelog.

## [0.37.7] - 2026-08-13

### Changed
- A sync session now hands over a bounded slice and stops, instead of running until everything one member is missing has been transferred. A member catching up on months of history used to hold a partner for hours, and anything that interrupted that (combat, a loading screen, a disconnect) threw the session away and started it over. A session now carries roughly 300 records, tells the receiver how much is still waiting, and ends. The receiver asks again and picks up where it left off, so a backfill finishes across a series of short sessions and both members are back in the pool for other partners within minutes. Members who have not taken this update sync with it normally.

## [0.37.6] - 2026-08-13

### Changed
- Members now share notes with whoever is available instead of waiting for a preferred partner. Every member used to broadcast a summary of what it held every five minutes, keep a picture of everyone else's, and score that picture to decide who to sync with next. Sync spreads through the guild the way gossip does, so it arrives regardless of the order it travels in, and the bookkeeping was buying an ordering that does not matter. A member that finishes syncing now simply becomes available and answers the next member who says they have something new. Nothing about what gets synced changes, and this update syncs normally with members who have not taken it yet.

### Removed
- The five-minute guild-wide summary broadcast, and the queue that scored which member to sync with next.

## [0.37.5] - 2026-08-13

### Changed
- The ledger window no longer opens by itself when you open the guild bank. Most members never need it there, and it landed on top of the bank frame every time. Tick "Open with Guild Bank" in Settings to get the old behaviour back, or open it any time with `/gbl`. Note that anyone who had never changed this setting is now on the new default; anyone who had already turned it off is unaffected.

## [0.37.4] - 2026-08-13

### Fixed
- The Sync tab no longer tells you a peer is syncing when it is refusing them. A peer running a version too old to sync with was only marked as such while their messages were arriving; after a reload the mark was gone, and a peer who stayed quiet (sitting in a dungeon, where addon messages do not reach the guild) was shown as an older peer syncing normally. The tab now works the status out from the version the peer advertises, so it reads correctly whether or not they have said anything this session.
- Peers remembered from a previous session kept their version but lost the compatibility range that goes with it, so until they spoke again they were treated as though they predated the sync floor. That made the addon refuse a peer it can sync with, and label them as too old in the peer list.

### Changed
- Peer status tags read "too old | sync refused", "newer | update to sync", "newer | update available" and "older | syncing". A peer running a development build is now named as such instead of being reported as too old.

### Changed
- Sync gives up on a lost chunk faster and retries more times before abandoning a peer. Waiting eight seconds to notice a dropped chunk made sense when chunks were large; measured replies come back in about half a second, so most of that wait was dead time. The wait is now three seconds with eleven attempts instead of six, which keeps roughly the same overall patience for someone on a slow loading screen while wasting far less time on each lost packet.
- The sync summary reports how long peers took to acknowledge each chunk, and counts any chunk that went out larger than a single packet. Both are there to catch the sizing above going wrong on a route it was not measured on.

### Fixed
- Sync chunks are sized by what the whole message weighs, not by the records alone. Each chunk was meant to fit a single 255-byte packet, and none of them ever did: the per-item event counts that ride along with the records and the message header were both attached after the size check, and together they outweighed the records they travelled with. Every chunk was going out as three packets instead of one, and losing any one of the three meant sending the whole thing again, which is why a long catch-up sync could spend hours retrying and still not finish. Chunks now carry fewer records each and arrive in one piece.

## [0.37.2] - 2026-08-10

### Changed
- Compatible peers on an older version no longer show their Sync tab status in grey. Grey reads as "unable to sync" when the tag means the opposite, that syncing is working fine, and it was easy to confuse with the genuinely inactive states (grey is also the roster-only "online (no HELLO)" text and the dev-build row colour). The "older, syncing" note now renders in the normal text colour; warning colours are unchanged and still mark only peers that actually cannot sync.

## [0.37.1] - 2026-08-10

### Fixed
- The "Hide moves" filter no longer hides the Location column along with the move rows. Hiding moves is the default, so most users never saw the column at all, including the bank tab that deposits and withdrawals started recording in v0.37.0. The column now stays visible whatever the filters: it shows the tab for every transaction recorded from v0.37.0 on and stays blank for older rows, which never recorded one.

## [0.37.0] - 2026-08-10

### Changed
- **This is the last release that requires your whole guild to update together.** Until now the addon refused to sync with anyone running a different version, down to the patch number, so every release split the guild into groups that could not share data until everyone had updated. From this release on, clients sync across versions as long as both are on 0.37.0 or later. A future release will only break that again if the stored record format itself has to change, which is rare and deliberate.
- The Sync tab tells the three cases apart now. A peer running a different but compatible version is marked "older, syncing" in grey rather than warned about, a peer running a newer version still shows "update available", and only a peer we genuinely cannot sync with is coloured as a problem.

### Fixed
- Records arriving over sync are now checked before being stored. Roughly one in nine records ever received had a field name garbled in transit, and the addon accepted them: a transaction whose type read as gibberish was stored as happily as a real one. Records damaged in the common way (losing the item's category information) are now repaired from the item ID instead of being lost, and anything still malformed is refused.
- Refused records are counted and reported as refusals rather than as duplicates. They were previously indistinguishable, which meant a peer sending nothing but corrupt data looked exactly like a peer whose data already matched yours.
- Deposits and withdrawals now record which bank tab they happened in. Only moves ever did, so the tab column in the Ledger tab was blank for most rows and per-tab history was unanswerable. Two deposits of the same item and count by the same player in the same hour into two different tabs were also told apart only by the order they were scanned in, which this closes.
  - **One-time side effect worth knowing about:** whatever is still sitting in the guild bank log when you update (roughly 25 entries per tab) gets recorded a second time, because those entries are now filed under a different identity. Expect a handful of doubled rows right after updating. It stops on its own once the bank log rolls over, and it does not affect anything already stored.

## [0.36.1] - 2026-08-10

### Changed
- Nothing in this release changes how the addon behaves. It adds a test suite that checks the sync message format against the real compression and serialization libraries instead of a test stand-in, so the next release can change that format without silently breaking older clients. Updating is worthwhile only so your version matches the rest of your guild.

## [0.36.0] - 2026-07-02

### Added
- Diagnostic logs now persist across reloads. Sync, sort, and system log entries are saved to a new saved variable (GuildBankLedgerAuditDB) so you can hand troubleshooting data to the developer after the fact instead of copying chat mid-session. Each session is stamped with the addon and sync protocol version, capped per channel, and rotates out oldest-first (10 sessions kept). Nothing is ever sent anywhere: sharing a capture stays a manual step, and a future opt-in uploader will ask first. Manage with the new `/gbl audit on|off|status|clear` command (`off` is the kill switch, `clear` wipes all captures on the account).

### Changed
- The bank layout serve line in the sync log now records at INFO instead of DEBUG, so the payload size shows up in normal diagnostics without turning debug mode on. The size is the early warning for a layout growing past the whisper ceiling.
- Sync bandwidth stalls are now measured in detail. Each stall episode logs a "CTL recovered" summary (deferral count, overlapping retry timers, stall length, lowest bandwidth seen, recovery rate) and the end-of-send stats line adds overlapped-timer and longest-stall counts. A sync that gives up while bandwidth is still starved records that last stall too, on its own "CTL still starved at send end" line, so the longest-stall figure counts the stall that ended the sync instead of reporting zero for it. Measurement only, no behavior change: these numbers decide whether the long-standing stall fix should target duplicate retry timers or slower retries.

### Fixed
- README described sync chunking as 15 records per chunk; the shipped values since 0.28.7 are 4 records within a 900-byte budget, sized to fit a single wire fragment.

## [0.35.0] - 2026-06-24

### Added
- A per-item "Keep" field on each Layout editor row. It sets the total to keep in stock for that item, and Restock now buys up to whichever is larger: the layout total or the Keep amount. This lets you raise the buy-to target above what the tab layout alone needs, for example keeping a deep reserve of a key flask. Leaving Keep at 0 keeps the layout total as the target, exactly as before.
- A "Keep" field in the Layout editor's "Apply to all" bulk row, so you can set the reserve for every item on a tab in one click (next to the existing bulk Slots and Per slot). Setting it to 0 clears the reserves on that tab.

### Changed
- The Restock tab now shows a two-state stock status per item: "Buy N" when the bank is below the item's target, or "In stock" when it is at or above it. The earlier separate "Over N" state is gone, since being above the target is not a problem. Each row's target and bank counts now read "target N | bank M" instead of the parenthetical "(target N, bank M)".
- Simplified the About tab labels: the Ko-fi and CurseForge copy boxes now read just "Ko-fi" and "CurseForge", and the license line reads "MIT License".

### Removed
- The crafted-quality crash mitigation on the Sort tab: both the warning banner on the preview and the pre-warm step that loaded item data before each sort. The pre-warm added up to a 3-second delay before every sort to guard against a Blizzard-side client crash that recent sorts over crafted-quality reagents (Flawless gems and similar) no longer hit. Sorts now start right away; if the crash resurfaces the mitigation can be restored.

## [0.34.2] - 2026-06-23

### Fixed
- The main window now closes when you press Escape. Previously Escape only worked when "Open with Guild Bank" had auto-opened the window (it was closing through the bank), so a window opened manually with `/gbl` or the minimap button could only be closed with the Close button (issue #40).

## [0.34.1] - 2026-06-23

### Added
- The About tab now credits Katorri with creating the Restock feature, which is based on the Guild Bank Restock addon.

### Fixed
- The About tab, the Changelog page controls, and the window's version label no longer use a two-argument font call that WoW 12.0.7 rejects. It is the same issue that blanked the Restock tab before its 0.34.0 fix; the remaining cases now pass the required third argument.

## [0.34.0] - 2026-06-23

**Restock**: refill the guild bank to its layout targets, with optional Auction House buying.

### Added
- A Restock tab (and `/gbl restock`) that helps officers refill the guild bank to its layout targets. It lists every item in your bank layout, grouped by tab, with its target count, how many are currently in the bank, and how many are short. The tab is visible to members with sort access, the same as the Sort tab.
- Auction House buying through the optional Auctionator addon. With Auctionator installed and its Shopping tab open, the Restock tab can price every item the bank is short on and buy the shortfall, one item at a time or as a single Buy-all sweep. Buying spends real gold through WoW's commodity purchase flow. Restock refuses any purchase you cannot afford, and you can set a per-run gold budget to cap a sweep.

## [0.33.0] - 2026-06-17

### Added
- A diagnostic command, `/gbl epoch0`, that lists stored transactions stuck in the epoch-0 (1969-12-31) time bucket and reports how many there are, whether their timestamps are valid, and which guildmate supplied each one. It is an investigation aid for the long-standing issue where a few stale records keep showing up as differing during sync even when both sides already hold them. Run it, then check `/gbl synclog` for the summary line.

### Fixed
- Closed one more path where a guildmate behind a client whose data had stopped changing could stall. The v0.32.12 fix re-pinged a behind peer when it contacted us and we held more data than it did. The check that runs right after we finish sending data to a peer was still skipping silently in the same situation, so a behind peer could stall there instead. It now sends the same throttled re-ping (at most once a minute per peer).

## [0.32.12] - 2026-06-09

### Added
- Sync debug logging to diagnose guildmates who never catch up to a client that is ahead of them. When sync debug is on, the log now records when a HELLO reply is held back because our data has not changed since we last told that peer, and annotates the "likely superset" skip with whether the peer got a fresh ping that round. This makes the suspected silent stall (an ahead client that never nudges a behind peer, and a behind peer that therefore never asks) visible in a capture. Enable with `/gbl logs debug sync on`, reproduce, then `/gbl synclog`.

### Fixed
- Guildmates who were behind a client whose data had stopped changing now get caught up instead of stalling. The addon only pings a peer when its own data changes, so once an ahead client went idle it stopped telling a behind peer it had more, and the behind peer never asked, leaving the two stuck out of sync indefinitely. The ahead client now re-pings a behind peer (at most once a minute per peer) so the catch-up starts even when nothing new is happening.

### Changed
- Sync now sends the most recent transactions first when catching a guildmate up. It used to send oldest first, so a member who only lacked recent activity had to wait through the entire history (often thousands of records they already had) before reaching what they actually needed, and any interruption (combat, zoning, a disconnect) before the end meant the catch-up made almost no progress. Sending newest first means an interrupted sync still delivers current activity, and the next comparison between the two clients is smaller, so the guild converges faster. What ends up stored is unchanged: records are matched by identity, so the order they arrive in does not change the result.

## [0.32.11] - 2026-06-09

### Added
- The bank layout template now syncs to guildmates who have sort access. Before this, granting an officer sort access shared the permission but not the layout itself, so their Sort tab had nothing to work with. The Guild Master's layout (and stock reserve counts) now travels with the addon's normal guild sync: a granted officer's client pulls it automatically and can sort against it. Only the layout's timestamp rides the regular guild ping; the full template transfers point to point and only to members who can actually sort, so it stays off the wire for almost everyone. A dropped transfer is re-fetched on the next ping until both clients match.

### Changed
- The Layout tab's "Layout-write access: GM" banner now also shows who else the Guild Master has granted layout-write access to (the rank threshold and delegate count), so the configured policy is visible at a glance instead of only the viewer's own access path.

## [0.32.10] - 2026-06-04

### Changed
- The Sort tab is now hidden from guild members without sort access, and the Layout tab is hidden from anyone without layout-write access (sort-only users no longer see a Layout tab they cannot edit). Previously the Sort tab was shown to everyone even though only authorized members could use it.

### Fixed
- Sort access grants now reach the officers they are given to. The Guild Master's sort-access policy (rank threshold and delegate list) was stored only on the GM's own client and never shared, so granting another officer access had no effect on their game. The policy now travels with the addon's normal guild sync, and a grant takes effect on the granted player's client without a reload.
- The Sort and Layout tabs now appear as soon as your access is granted or your guild rank loads, without a reload. They were previously re-evaluated only when the window was first opened or when an access-control change synced in, so a rank-based grant, or opening the window before the guild roster finished loading at login, could leave the tabs missing for the rest of the session.

## [0.32.9] - 2026-05-22

### Changed
- Sort engine replaced with a fire-and-forget pump. Each move fires once per second on a fixed cadence with no per-move confirmation wait, then at the end of a pass the bank is re-scanned and re-planned; if any moves remain, another pass runs automatically (up to 5 passes). The previous per-move confirmation that waited for a slots-changed event with re-queries at 1.5 and 3.0 seconds is gone. In-game runs that used to take roughly 632 seconds for 184 moves should run closer to 190 seconds in one pass.
- Sort runs are now self-healing if the client's frame loop wedges mid-run (the "stops partway and needs a restart" hang). A stall watchdog re-kicks the pump after about six seconds of no progress so the run resumes when the loop catches up, instead of needing the bank to be closed and the sort restarted.
- Sort automatically throttles the periodic transaction-log re-scan for its duration so it does not slow the pump. The re-scan would otherwise hitch the main thread every three seconds and stretch per-move time from one second to three or four; in-game captures showed exactly that. While the sort is running, the addon flushes the transaction log every fifteen moves instead (well under the bank's per-tab log cap), so every move is still captured to the ledger. Your re-scan setting is restored when the sort ends.
- The sort log buffer now holds 3000 entries (was 1000) so a full large sort run stays in the "open sort log" view without dropping its start.

### Removed
- The interim-poll cascade (0.25 / 0.5 / 1.0 / 2.0 seconds), the cross-tab re-queries at 1.5 and 3.0 seconds, the 4-second confirmation timeout, the 3-strike consecutive-refusal abort, and the related per-move timeout classification. These were the machinery the old confirmation model used to know each move had landed before issuing the next; the new pump does not wait for confirmation, so they are gone. The per-move confirm tag (for example `[async-event via requery@1.5]`) and the `Sort confirm histogram` summary line are gone with them.

## [0.32.8] - 2026-05-20

### Changed
- Sort timeout summary format expanded. The single-line execution audit now reads `timeout[s=N,p=N,c=N,m=N,dp=N,o=N] drifts=N` where `s` is server-rejected (the bucket previously labeled `n`/none), `p` is partial, `c` is complete, `m` is the new merge-noop bucket, `dp` is drain-pending, `o` is residual other, and `drifts` counts timeouts where the planner's emit-time projection diverged from the live observed values. The new merge-noop bucket captures the singleton-chain refusal pattern that previously hid inside `other`.
- Sort timeout audit no longer prints the planner-projected line on every timeout. It now prints only when the planner's projection actually diverges from the live observed values, formatted as `(planner projected: src ..., dst ...)`. Healthy timeouts get one fewer noise line in the log.

### Fixed
- Sort now aborts with a specific reason after three consecutive server refusals on the same item rather than compounding into a chain of refused moves until the replan cap aborts. The new abort fires before the executor advances past the third refused op, ending the run with a reason like `repeated server refusal on item N (3 consecutive merge-noop)`. Failing early means the user can see which item is stuck without scrolling the whole sort log.
- Sort now confirms each op via an interim polling cascade at 0.25, 0.5, 1.0, and 2.0 seconds after the Pickup pair rather than always waiting for the 4.0-second late-poll backstop. In-game captures showed every op confirming via the 4.0-second floor even when the server processed in well under a second, dominating wall-clock sort time. Successful interim advances use a slightly longer 0.5-second inter-move cushion than the default 0.3 seconds to give the server breathing room after the faster confirmation.
- Sort no longer carries a per-item refusal counter across a replan. Previously two refusals followed by foreign-activity replan followed by one refusal on the same item would falsely trip the 3-strike abort even though the plan structure between strikes 2 and 3 had changed.
- Sort timeout classification now reads the live slot contents directly instead of matching against the formatted audit text. In-game that text carries the resolved item name, so the old prefix match never fired: every real timeout fell into the residual `other` bucket, leaving the merge-noop bucket and its 3-strike abort dead outside the test environment. The buckets and the early abort now work against real bank data.
- Sort no longer aborts a sort that is actually working. A guild-bank split deposits into the destination before the client reflects the source-stack decrement, so within the 4-second confirmation window the source still looks full and the op read as a `merge-noop` refusal. Three in a row aborted a sort that was placing items correctly. A split whose destination was empty (or held a different item) before the op and now holds the expected item is classified `drain-pending` (shown in the timeout summary as `dp=N`) and excluded from the 3-strike abort, so the sort runs to completion. The per-op audit records the deposit-landed-source-pending state.
- Sort's 3-strike abort is narrowed to genuine refusals only. A slow deposit can leave the destination still empty at the 4-second check (classified `server-rejected`) even though the deposit is simply in flight, and that previously counted toward the abort. The abort now counts only a move or merge into a slot that already held the same item (a real max-stack bounce); any op into an empty or different-item slot is treated as an in-flight deposit. A planner mistake like merging two full max-stack stacks still aborts as it should.
- Sort confirms a split or move into an empty (or different-item) slot as soon as the destination holds the item, instead of waiting for the source-stack count to drain. In-game the deposit lands in about 0.6 seconds while the source-drain can lag past the 4-second confirmation window, so the old rule spent the full window on every such op. The common case now confirms in about a second, roughly 4x faster end to end. A merge into a slot that already holds the same item still requires the source to drain, because there the destination alone cannot tell a real merge from an optimistic bounce.
- Sort keeps the destination tab's slot data fresh during each op so a cross-tab deposit confirms inside its own confirmation window instead of one op later. WoW pushes slot updates only for the currently-viewed guild bank tab, so a deposit into a tab you were not viewing landed on the server but stayed invisible to the addon until the next op happened to re-pull that tab, surfacing as a false refusal and a roughly 5-second stall on every cross-tab op. The executor now re-queries the destination tab in the background while the op is in flight (it does not change the tab you are viewing), and the resulting slots-changed event confirms the deposit. A stray refresh event whose slots still match the just-completed op's projected state is treated as the executor's own echo rather than another player's activity, so it no longer triggers a needless replan.

### Added
- Sort planner Phase 2 cycle resolution now emits debug audit lines describing what the planner saw: which slot is cycle-blocked and what item blocks it, which pivot slot was chosen, or whether the cycle aborted with no pivot available. Lines route through `GBL:SortDebug` so they only land in the sort log buffer when `db.profile.sort.debugChat` is on. The greedy emit loop also logs the failing predicate (`src-shortfall`, `dst-mismatch`, or `max-stack-overflow`) on any refused canExecute. Emissions cap at 20 per plan to avoid flooding the debug channel on degenerate inputs.
- Bank scans now log a per-tab summary line (for example `Scan: T1=80(event) T5=0(timeout,locked=5) (498 total)`) showing each tab's occupied-slot count, whether its data arrived from the server event or the query-timeout fallback, and how many slots were skipped because they were locked. A display tab that reads empty via the timeout path while it actually holds items is the fingerprint of a stale scan feeding a phantom sort plan.
- The sort plan summary line now ends with a per-tab occupied-slot breakdown (for example `[T1:80 T5:0 T6:120]`), so a cold tab is visible in `/gbl sortlog` without opening the master log. Comparing a cold pre-sort plan's breakdown to the warm post-sort plan's breakdown shows exactly which tab gained the slots the stale snapshot missed.
- Sort audit records deposit-confirmation latency. Each no-op-suspected line stamps the elapsed time since the op was issued, and an op whose deposit has not landed by the 4-second timeout is watched for up to 20 seconds with a line noting when the deposit actually lands (or that it did not). This measures how long guild-bank deposits take to confirm so the per-op confirmation timing can be tuned from real data.
- Sort audit lines record the currently-viewed guild bank tab (shown as `viewed=TN`) on each op's done and timeout lines and on the deposit-observer lines. This tests whether deposits into a tab the client is not actively viewing explain the slow first-deposits into a freshly-filled tab.

## [0.32.7] - 2026-05-20

### Fixed
- Closing the guild bank after running a sort once in a session now performs the normal close cleanup again. Previously the sort's bank-close handler permanently replaced the core one, so after the first sort the periodic rescan kept running, the auto-opened ledger window did not close, and the post-close sync broadcast was skipped until the next reload.

## [0.32.6] - 2026-05-20

### Fixed
- Sort no longer risks a duplicate move or a client crash when another guild member changes the bank during the brief pre-warm step at the start of a sort. Previously a bank update arriving in that window could make the sort replan and issue its first move before item data finished loading (re-opening the crafted-quality crash that pre-warm guards against), then issue the same move again once pre-warm finished. The sort now ignores bank updates during pre-warm and never issues a second move while one is still in flight.

## [0.32.5] - 2026-05-20

### Fixed
- Sort pre-warms item data for every unique item link in the plan before issuing the first `PickupGuildBankItem`, mitigating a Wow.exe ACCESS_VIOLATION inside Blizzard's `SetItemCraftingQualityOverlay`/`GetItemReagentQualityInfo` that fired during the tab redraw after sort moves on tabs containing TWW crafted-quality reagents (Flawless gems and similar). The pre-warm uses `Item:CreateFromItemLink(link):ContinueOnItemLoad(cb)` with a 3.0 s cap. Audit line `Sort pre-warm: N items, M loaded in T.Ts (reason)` lands in the sort log before the first op. Verified in-game on a 502-slot bank with the full Flawless gem set — sort runs to completion without a client crash.

### Added
- Warning banner in the Sort tab preview. When the plan touches any slot whose live item link carries the TWW crafted-quality atlas marker, a color-coded banner renders above the move list explaining that pre-warm is a best-effort mitigation against a Blizzard-side crash and that recurring crashes during similar sorts are a signal to organize those items manually first.

## [0.32.4] - 2026-05-13

### Added
- Window position and size now persist across reloads. Dragging or resizing the ledger window automatically saves the position and dimensions; they are restored on the next login or `/reload`.
- Minimum window size enforced (810×500) to prevent the tab bar and filter row from becoming unusable when the window is resized too small.

### Fixed
- Scroll area now correctly fills the full available height after the window is resized. Previously, the scroll container's height was only calculated at tab-build time and was not updated when the window was made taller.

## [0.32.3] - 2026-05-12

### Fixed
- ChatFilters: `CHAT_MSG_MONSTER_SAY`/`YELL` event handlers now bail out immediately when inside any instance (party, raid, pvp, arena, scenario). Blizzard marks NPC sender values as "secret" in instanced content, causing a Lua error when the name was used as a table key. The filter has no purpose in instances anyway — the guild bank does not exist there. Also tightened the `_IsMutedAmbientNPC` sender guard from a nil-check to a `type() == "string"` check so any non-string value (secret or otherwise) is rejected before reaching the table lookup.

## [0.32.2] - 2026-05-11

### Changed
- Documentation honest-status sweep across CurseForge description, README, and ROADMAP. Replaced the blanket "stable and in active guild use" framing with a three-tier model (mature / active / under audit). Split the forward-plan list into Pre-1.0 readiness gates and Post-1.0 features. Stock is now two roadmap slots (passive Stock tab, then toggleable Stock alerts). Analytics added to Post-1.0 with the full six-section scope from the design plan. Fixed README's stale "sync audit log" reference (panel removed in v0.32.0). Updated ROADMAP Shipped section to v0.1.0--v0.32.1 with sort+layout, logging, and peer-canonicalization milestones called out.
- Softened the "Full keyboard navigation (Tab/Shift+Tab)" claim in CurseForge description and README. The supporting functions (`RegisterFocusable`, `AdvanceFocus`, `SetFocusIndicator` in `UI/Accessibility.lua`) have existed since v0.3.0 but were almost entirely unused outside `UI/ChangelogView.lua`. No AceGUI key handler was wired, so Tab/Shift+Tab did not advance focus across widgets. Completing the wiring is now codified as a v1.0 release gate in ROADMAP Pre-1.0 readiness.

### Added
- Project CLAUDE.md gains a "Design Principles" section pinning accessibility-first as a blocking design requirement, with the May 2026 widget-wiring discovery captured as the rationale. Every new UI feature must list its keyboard-navigation path, focus indicators, color-encoding fallbacks, font-scaling behavior, and screen-reader hooks during the design phase, with end-to-end verification before any user-facing doc claims the feature works.

## [0.32.1] - 2026-05-09

### Changed
- Reorganized addon source files into the `src/` subfolder. Internal-only change with no user-visible behavior. Updates the `.toc` load paths, the test harness `dofile` paths, the `.busted` `lpath`, the CI `Verify DEV_BUILD is nil` step, the `pre-push` hook, and path references across `CLAUDE.md`, `CONTRIBUTING.md`, the GitHub PR template, and `docs/`. Historical CHANGELOG entries and in-source comments retain the old root-level filenames since they describe the codebase as it stood at the time.

## [0.32.0] - 2026-05-08

### Added
- New `Logger.lua` module owns the session log and exposes per-channel writers on `GBL`: `SyncInfo / SyncWarn / SyncError / SyncDebug` (plus `Sort*` and `System*`), with a lower-level `LogSync(level, fmt, ...)` form for runtime-computed levels. Severity is one of DEBUG / INFO / WARN / ERROR. printf-style formatting goes through `pcall(string.format)` so a bad format string falls back to the literal pattern instead of crashing.
- `/gbl sortlog` opens a copy-pastable pop-up of the sort-channel session log.
- `/gbl logs` opens the master log: sync, sort, and system channels merged in timestamp order with `[CHANNEL] [LEVEL]` prefixes.
- `/gbl logs dump [N]` prints the last N master entries to chat (default 50).
- `/gbl logs clear sync|sort|system|all` truncates a channel.
- `/gbl logs debug sync|sort|system on|off` toggles per-channel DEBUG-to-chat mirroring.
- "Open Sort Log" button on the Sort tab and "Open Master Log" button on the Sync tab, alongside the existing "Open Sync Log" button. All three open the same AceGUI MultiLineEditBox pop-up the slash commands use.

### Changed
- Sync and Sort diagnostics moved to separate ring buffers (sync cap 2000, sort cap 1000, system cap 500). Reading the sync log no longer requires mentally filtering out per-op sort lines, and vice versa. Per-channel chat mirroring is gated by `db.profile.<channel>.chatLog` (INFO/WARN/ERROR) and `debugChat` (DEBUG). DEBUG entries drop entirely when `debugChat` is off, preserving the prior `chatOnly=true` "do not pollute the buffer with per-chunk noise" property without a separate side channel.
- `GBL:AddAuditEntry(msg, chatOnly?)` is now a deprecated shim that routes plain calls to `SyncInfo` and `chatOnly=true` to `SyncDebug`. `GBL:GetAuditTrail()` is a permanent alias for `GetLog("sync")` that also exposes the legacy `entry.timestamp` field for older readers.
- Sync tab no longer carries an always-visible audit panel. Logs are a diagnostic artifact, not live UI furniture; they surface only on demand via the slash commands or the new buttons. Removes the constant re-render of the Sync-tab log panel that nobody was actively reading.
- Sync diagnostics that were already WARN- or ERROR-shaped are now tagged at the right severity (version mismatch, oversized chunks, ACK timeout retries / aborts, hard timeout, receive timeout, NACK-limit aborts, sender-offline aborts). Sort diagnostics are similarly tagged: phantom-success suspicions, pre-check failures, server reversions, cursor-stuck failures, and timeouts surface as WARN; success / lifecycle / replan / reclassification surface as INFO.

## [0.31.1] - 2026-05-05

### Fixed
- Layout editor's Add-item input is reachable again on captured display tabs. The row was sitting at the bottom of the per-tab scroll content (below the item rows and slot map) where AceGUI's trailing-widget scroll bug clipped it from the wheel-scrollable area, so users couldn't add new items by hand once a tab had been captured. Moved the row up to sit just below Capture / Unpin All, alongside the other write controls. Same widgets, same callback, same `HasLayoutWrite()` gate. This is the second instance of the v0.30.4 save-bar workaround pattern; the underlying AceGUI content-height bookkeeping bug is unchanged.
- Sort tab scroll now reaches the bottom of the window on tall plans. The ScrollFrame was missing the bottom-right anchor that Transactions / Gold Log / Consumption already use, so AceGUI's default Flow-layout height stopped the scroll short of the window edge and hid the tail of long move lists. Added the same `scroll.frame:SetPoint("BOTTOMRIGHT", container.content, ...)` fill-remainder anchor.

### Changed
- Sort tab Plan summary, live progress label, and Moves heading are now pinned above the scroll instead of scrolling away with the move list. Moved them into a new SimpleGroup header that sits between the controls row and the ScrollFrame so the running "op N / M" counter and the plan totals stay visible while the user scrolls through long move lists. The op rows, Deficits section, and Unplaced section continue to scroll. Same widget refs as before (`_sortProgressLabel` is still rebuilt on every Preview and updated live by `_SortView_OnProgress`).

## [0.31.0] - 2026-05-05

### Added
- Optional filter to mute `Silvermoon Citizen` ambient chatter (off by default; checkbox lives on a new personal-preferences row visible to all access levels). Hides both the chat-frame line and the world speech bubble. Chat-frame side suppresses `CHAT_MSG_MONSTER_SAY` / `_YELL` / `_EMOTE`; bubble side listens for SAY/YELL via AceEvent, queues the stripped message text, and polls `C_ChatBubbles.GetAllChatBubbles()` every 50ms to hide bubbles whose text matches (exact, with substring fallback for engine-side wrapping). Bubbles are hidden via `SetAlpha(0)` + `Hide` on both the bubble frame and its visible regions, plus reparenting to a hidden frame, so retail's bubble-show cycle does not re-expose them. Muted-name set is data-driven (`ChatFilters.lua`), so adding a future NPC is a one-line code change. enUS-only by virtue of the localized sender name.
- `/gbl bubbletest` slash command: dumps whether `C_ChatBubbles` is available, the current toggle state, the queued suppression set, and every active bubble's FontString text with a `[MATCH]` annotation when the queue would suppress it. Useful for diagnosing cases where chat is muted but the bubble survives.

## [0.30.6] - 2026-05-05

### Added
- Dev-build sync isolation: a `DEV_BUILD` constant in `Core.lua` flips the wire version to `X.Y.Z-dev.<id>` so isolated dev installs cannot exchange records with production peers. The existing exact-match rejection at `Sync.lua` HandleHello refuses both directions and writes a single `(version mismatch; this build is v...)` audit line; the `-dev.<id>` substring in the printed version is the disambiguator between dev-isolation and real version skew. UI surfaces the dev state via a `[DEV]` title-bar suffix, a one-line login chat notification, an orange "Dev build (vX.Y.Z) -- sync isolated" banner at the top of the Sync tab when local is dev, and a greyed-out Online Peers list when local is dev (the banner above explains why none are reachable). CI guard rejects any PR where the constant is non-nil. The local `run_tests.sh` is intentionally unguarded so dev iteration on the dev branch keeps working.

### Changed
- `GBL:CompareSemver` strips an optional pre-release suffix (e.g. `-dev.<id>`) before parsing so dev builds compare as the same release line as their base for the ahead/behind UI labeling. The wire-side equality check at `Sync.lua` HandleHello is unaffected (uses string `~=` directly).

## [0.30.5] - 2026-05-05

### Added
- **`GBL:CanonicalPeerKey(name)`** in `Core.lua` is the canonical accessor for peer-identity keying across the sync layer. Strips the realm suffix only when it matches the local realm (raw or normalized comparison via the new `GBL:_isLocalRealm` helper); preserves it for cross-realm names so connected-realm guilds with two characters sharing a first name across realms keep them as distinct peer entries. For bare-name input the helper consults `guildData.playerRealms` (built by `BuildRosterCache`, persisted across sessions) and re-realms via roster lookup so bare and qualified arrivals of the same character converge on the same canonical key.
- **`GBL:NormalizeRealm(realm)`**, **`GBL:GetLocalRealm()`**, and **`GBL:_isLocalRealm(realm)`** helpers in `Core.lua` centralize realm-string handling. `NormalizeRealm` strips whitespace ("Aerie Peak" → "AeriePeak"); `GetLocalRealm` centralizes the `GetNormalizedRealmName() or GetRealmName():gsub("%s","")` fallback; `_isLocalRealm` answers "does this realm match local realm" with raw-or-normalized equality.
- **`GBL:RepairCorruptedPlayerRealms(t)`** trims hyphen-bearing strings from a `playerRealms` table (corruption from a long-fixed code path; retail realms never contain hyphens). Called from `MigrateAllGuilds` early at OnEnable (before any migration consults the cache) and from `BuildRosterCache` on every `GUILD_ROSTER_UPDATE`. Offline-peer corruption that `BuildRosterCache` couldn't overwrite (because the peer wasn't currently rostered) now self-heals on first reload.
- **`GBL:ConsolidatePeerKeys()`** walks `syncState.peers` and `guildData.knownPeers`, re-runs `CanonicalPeerKey` on each key, and merges duplicates by recency. Called from `GUILD_ROSTER_UPDATE` after `BuildRosterCache` so any peer-state staleness from earlier in the session (or from prior sessions whose canonicalization differed) sweeps to current canonical form. Idempotent.
- Schema 8 → 9 (revised). `MigrateNormalizePeerNames` is now realm-aware: collapses same-realm peer keys to bare with recency-merge; preserves cross-realm. Returns early when realm APIs are not yet warm so the next session retries.
- Schema 9 → 10 (new). `MigrateNormalizeStoredRealms` rewrites raw spaced realms in `playerRealms`, `record.player`, and `record.scannedBy`. Recomputes `record.id` inline after a player rewrite (since `ComputeTxHash` derives the id from the player field) and rebuilds `seenTxHashes` once at the end.
- Schema 10 → 11 (new). `MigrateRecoverPeerRealms` is a best-effort recovery pass for users who ran the intermediate v0.30.5 development build that unconditionally stripped realm from peer keys. Walks bare keys in `knownPeers` and `syncState.peers`, consults the live guild roster, and re-realms keys whose bare name appears at exactly one realm. Multi-realm name collisions and offline / departed peers stay bare. Returns 0 without bumping `schemaVersion` when the roster API is cold (`numMembers == 0`) so the migration retries on a later session or via the `GUILD_ROSTER_UPDATE` retrigger.
- **Migration ladder retrigger.** `GUILD_ROSTER_UPDATE` now retriggers `MigrateAllGuilds` once per session (gated by `_migrationsRetried`) so migrations that short-circuit on cold realm APIs at OnEnable get a warm retry without waiting for the next login.
- **`BuildRosterCache` ambiguity tracking.** When a bare name maps to multiple distinct realms in the current guild's roster, `playerRealms[bareName] = false` (sentinel). `CanonicalPeerKey` rejects the sentinel and keeps ambiguous bare arrivals bare rather than guessing the wrong realm.
- **`InitSync` knownPeers seed loop consolidation.** Each persisted key runs through `CanonicalPeerKey` at session start; if the canonical form differs, both `knownPeers` and the runtime `syncState.peers` consolidate by recency. Self-heals stuck saved variables on next `/reload` without a separate migration.

### Fixed
- **Sync peer list no longer shows the same player as multiple realm-tagged entries.** Pre-fix the sync layer used `Ambiguate(name, "none")` at sixteen sites intending to strip the realm suffix from incoming sender names, but in retail WoW that context returns the name unchanged (only `"all"` and `"short"` actually strip). When AceComm delivered the same peer's messages with different qualifications across the session (`"Rexxybear"` vs `"Rexxybear-Tichondrius"`), each variant became a separate peer key, bloating the Online Peers list and the persisted `knownPeers` store. All sixteen sites now route through `GBL:CanonicalPeerKey`. The own-message ignore check at the top of `OnSyncMessage` is also fixed (it previously failed in retail because the realm-qualified sender never compared equal to `UnitName("player")`, so the addon was processing its own broadcasts as if from a stranger). The three peer-state assignment sites in `RequestSync`, `HandleSyncRequest`, and the `HandleSyncData` auto-bootstrap path now canonicalize their input so peer-comparison checks line up with peer keys.
- **Connected-realm guilds now correctly distinguish same-name members across realms.** Empirical observation in-game: retail's `Ambiguate(name, "guild")` strips realm for ALL guildmates of a connected-realm group, not just same-realm as the API docs imply. An intermediate development build that delegated the strip to `Ambiguate("guild")` would have collided two distinct Alices across connected realms in one guild into a single peer key. The shipped fix uses custom local-realm-only logic via `GBL:_isLocalRealm` so cross-realm distinguishability is preserved. `IsGuildMemberOnline` also routes both the parameter and each roster `fullName` through `CanonicalPeerKey` for correct disambiguation.
- **Player records stored with raw spaced realm strings vs normalized form.** `BuildRosterCache` and `MigrateSchemaV2ToV3` previously captured the realm portion raw (`"Aerie Peak"`), while the local-realm fallback in `ResolvePlayerName` always produced the normalized form (`"AeriePeak"`). The asymmetry let the same player surface as two different `record.player` values across the dedup boundary on realms with spaces in their name. All three storage sites now route through `NormalizeRealm`. Schema 9-to-10 migration `MigrateNormalizeStoredRealms` rewrites stored realms in place. Idempotent.
- **Schema-11 cold-roster premature-bump.** When `GetLocalRealm()` was valid but `GetNumGuildMembers()` returned 0 (cold roster), `MigrateRecoverPeerRealms` walked an empty roster, recovered nothing, and still bumped `schemaVersion` to 11. Affected users got stuck at 11 with the recovery never having actually run. Fixed by returning 0 without bumping when `numMembers == 0` so the migration retries.
- **Hyphen-corrupted `playerRealms` entries from a long-fixed code path** persisted in saved variables for offline peers because `BuildRosterCache` only writes for currently-rostered members. `RepairCorruptedPlayerRealms` now trims them at OnEnable (via `MigrateAllGuilds`) and on every `GUILD_ROSTER_UPDATE`. `CanonicalPeerKey` defensively rejects hyphen-bearing realm strings as a belt-and-suspenders measure.
- **`ResolvePlayerName` cross-guild fallback removed.** The previous implementation iterated all guilds' `playerRealms` as a last resort, which could resolve a bank-log name to a realm from a guild the user no longer belongs to. New priority: explicit `pr` arg → current guild's `playerRealms` → local realm fallback. Migrations pass per-guild tables explicitly via the `pr` arg so they remain correct.
- **Schema migration ladder skip-chain (Codex P1).** Later migrations in the ladder (`MigrateNormalizeStoredRealms`, `MigrateRecoverPeerRealms`) had loose `>= target` gates that would let the ladder bump straight from schema 8 to 10 or 11 if `MigrateNormalizePeerNames` short-circuited on cold realm APIs, permanently skipping the 8 → 9 work. Now strict-gated on `schemaVersion == prev_target` so the chain stays in order.
- **Stale `record.id` after realm rewrite (Codex P1).** `MigrateNormalizeStoredRealms` previously mutated `record.player` without rebuilding `record.id` (which `ComputeTxHash` derives from the player field) or `seenTxHashes`. Sync would re-import the same transaction under its new id and dedup wouldn't catch it. Fixed by recomputing the id inline after a rewrite and rebuilding `seenTxHashes` once at the end, mirroring `MigrateRepairEpochTimestamps`'s pattern.
- **Schema-11 recovery realm normalization (Codex P2 follow-up).** `MigrateRecoverPeerRealms` was building its bare-name to realm lookup from `GetGuildRosterInfo` without normalizing the realm portion. `GetGuildRosterInfo` can return raw spaced realm names (`"Aerie Peak"`) for cross-realm guildmates depending on the realm topology. The unnormalized realm then flowed into `CanonicalPeerKey` at the rewrite site, which preserved the cross-realm form as-is. Result: recovered keys like `"Alice-Aerie Peak"` while every other call site of `CanonicalPeerKey` produced `"Alice-AeriePeak"`, silently splitting the same peer across two keys after the recovery migration. Affected users on multi-word realms (Aerie Peak, Burning Blade, Argent Dawn, etc.). Fix: normalize realm once after the no-base fallback before storing in the lookup.
- **InitSync seed loop `syncState.peers` recency check (Codex P3 follow-up).** The seed loop wrote to `syncState.peers[clean]` unconditionally per `pairs()` iteration. When `knownPeers` contains both legacy bare and canonical qualified forms of the same peer, both raw keys canonicalize to the same clean key, and `pairs()` iteration order is undefined, so an older snapshot could nondeterministically overwrite a newer one in the runtime cache. The `knownPeers` consolidation right below already had a recency check; the `syncState.peers` write did not. Fix: wrap the runtime write in the same recency check.

### Changed
- **`CanonicalPeerKey` does not delegate to `Ambiguate("guild")`.** See Fixed: empirical in-game testing showed that retail `Ambiguate("guild")` strips realm for ALL connected-realm guildmates regardless of which connected realm. Custom local-realm-only logic via `_isLocalRealm` ships instead so cross-realm distinguishability is preserved.
- **Test mock for `Ambiguate` now matches retail semantics.** `"none"` is identity, `"all"`/`"short"` always strip, `"guild"` strips only when the realm matches `MockWoW.player.realm` (compared against both raw and normalized forms). Tests cannot pass with `Ambiguate(x, "none")` and silently break in production any more. (The mock is now effectively unused for production paths since `CanonicalPeerKey` no longer delegates, but it stays in place for any future test that legitimately wants the documented semantics.)
- **Test mock `GetGuildRosterInfo`** now returns 14 values matching retail (added `lastLogoff` as the 14th return). Production code reads up to position 9 today, but the gap was a footgun for any future "last seen X days ago" feature.
- **Test mock `GetNormalizedRealmName` vs `GetRealmName`** now correctly diverge: `GetRealmName` returns `MockWoW.player.realm` raw, `GetNormalizedRealmName` returns it with whitespace stripped. Tests can override either via `MockWoW.player.realm` (raw) or `MockWoW.player.normalizedRealm` (explicit override).

## [0.30.4] - 2026-04-28

### Added
- **Bulk-apply slots / per-slot to every item on a display tab.** A new "Set all items to:" row appears between the slot budget and the per-item rows on display tabs with at least one item. Fill in slots and/or per-slot, click Apply to all, and every item on that tab gets the new shape (e.g. set every gem on the gems tab to "5 slots × 1 per slot" in one action instead of editing dozens of rows individually). Leave a field blank to keep its current value for each item. Shrinking slots trims that item's pinned positions from the highest slot down, the same per-item pin-trim behavior the per-row OnEnterPressed handler already uses, so a previously-captured layout doesn't keep dangling pins above the new count. Edits buffer in the layout draft like any other Layout edit; click Save Layout to commit.
- **`ItemCache` now caches `itemStackCount` (8th return of `GetItemInfo`)** alongside name and link, with a new `GBL:GetMaxStack(itemID)` accessor. Used by the sort planner; warm path is the existing `GetCachedItemInfo` call sites and the `GET_ITEM_INFO_RECEIVED` handler.
- **`PlanSort(snapshot, layout, opts)`** gains an optional third argument used by tests. `opts.maxStackByItem` is an `{ [itemID]=number }` map that overrides the ItemCache lookup. Production callers continue to pass `(snapshot, layout)` and read max stack from ItemCache.
- **Sort planner timing diagnostic.** Every call to `PlanSort` now writes a single line to the audit trail of the form `Sort plan: 12.3ms, 47 ops, 0 deficits, 1 unplaced (input: 240 slots / 4 tabs)`. Visible via `/gbl synclog`. Captures both first-plan and replan latency on the same code path. Motivation: in-game observation that large plans (and the replans triggered when the executor detects foreign activity) cause a single-frame hitch. The line gives concrete ms-per-input-size data points to inform whether the planner needs to be split across frames via coroutines.
- **Per-phase sort instrumentation.** `PlanSort` now emits two additional audit lines whenever a plan has work to do: a `phases:` line breaking ops down by phase (`P0 merge=N(free=M)`, `P1a assign=N`, `P1b spill=N(top=,r=,l=,fe=,unp=)`, `P2 pivot=N(abort=M)`, `P3 sweep=N`, `P4 pack=N`) and a `demands:` line counting demand origins (`pinned`, `ext-R`, `ext-L`, `first-empty`). The same counters are exposed on the returned plan as `plan.diag` for tests and UI consumers. Empty/no-op plans stay quiet so replan cycles do not spam the audit trail. SortExecutor adds a single-line completion summary at every run end (`Sort: complete in 24.3s - 24 ops (24 done, 0 failed, 0 replans, 0 reclass) preCheck=0 cursor=0 timeout[n=0,p=0,c=0,o=0] avg 1.0s/op`) and the same counters land on the `onComplete` result table (`reclassified`, `preCheckFails`, `cursorStuck`, `timeoutByClass`).
- **Planner-vs-reality diagnostic on every op.** Each emitted op now carries `plannerSrcAt` and `plannerDstAt` snapshots, frozen views of what the planner thought the src/dst slots held at the moment that op was emitted. When a pre-check fails or an op times out, the audit trail now includes a `planner expected: ...` line that pairs with the `observed:` (or `got:`) line, directly answering "did the snapshot read this slot wrong, or did an earlier op in the plan fail to do what the planner projected?" Captured by helper `snapshotSlot` inside `PlanSort`; threaded into `emitAssignment`, the Phase 2 pivot move, and the Phase 3 sweep emission.
- **Per-op success timeline in audit.** Every op the executor advances past now emits a one-liner `Sort op N done: <move|split> T<src>/S<src>->T<dst>/S<dst> <name> (it:NNN) xN (X.Xs)` with elapsed time. Distinguishes the resolution path with a `[sync]` / `[late-poll]` suffix so the post-mortem can tell event-driven success from timeout-fallback success. Combined with the existing pre-check-fail and timeout entries, `/gbl synclog` now serves as a complete per-op timeline of any sort run.
- **Items-only layouts surface adjacency in `demands:` line.** Pass 2b (the slot fallback that runs when an item has more `slots` than `slotOrder` covers, the path that handles items-only layouts entirely) now labels each demand based on adjacency to existing same-item claims. Previously every demand in an items-only layout collapsed to `first-empty=N` (so 437 demands looked like 437 unrelated fallback adds); now the same layout surfaces as `first-empty=K, extend-right=437-K` where K is the number of distinct items, matching the natural "one seed per item, contiguous extension after" structure.
- **Item-name resolution in audit lines.** `it:NNN` is now rendered as `<name> (it:NNN)` everywhere `GBL:DescribeItem(itemID)` is called and the item is in the cache (pre-check fail / timeout / op-success / `describeSlot` all use the helper). Cold-cache items still fall back to bare `it:NNN`, and the helper deliberately does NOT warm the cache (audit emission paths should not trigger async loads).
- **Server-reversion detection.** SortExecutor now stamps each successful op with the live pre-op state of its src and dst slots, then projects the expected post-op state. The per-op-success audit line gains a trailing `src=<post> dst=<post>` showing what the WoW client believes the slots hold immediately after the op. When a foreign-activity GUILDBANKBAGSLOTS_CHANGED event fires (the second event after a Pickup pair, which is the server's authoritative response), the executor compares the live slot state against the projection. If they diverge, the audit gets a `Sort: server reversion suspected on op N (move T<src>->T<dst>)` line followed by the projected-vs-observed diff for src and/or dst. This is the diagnostic that distinguishes "the [sync] success path advanced on the WoW client's optimistic view of a Pickup that the server later rolled back" from genuine concurrent foreign bank activity. The replan still fires either way; the difference is whether the audit trail names the rejected op so a follow-up fix can target it.

### Changed
- **Layout tab now uses nested tabs.** The previous monolithic vertical scroll (eight bank-tab sections stacked above a Sort Access section) is replaced with an inner tab strip: one inner tab per bank tab (Tab 1..Tab 8) plus a final Sort Access tab. Editing one bank tab at a time keeps slot maps and item lists short, and Sort Access policy gets its own focused screen. The active inner tab persists across rebuilds so edits do not bounce the view back to Tab 1. Save and Discard sit at the top of each bank-tab inner tab (always reachable via a quick scroll-to-top regardless of how long the items list / slot map gets) and operate on the full draft (changes across all bank tabs save together). Sort Access keeps its own immediate-save semantics. Each inner tab keeps its own scroll position, so switching back to a tab returns the user to where they were instead of scroll=0. Mouse-wheel scrolling works inside every inner tab (the ScrollFrame lives inside each inner tab's content rather than wrapping the whole TabGroup, which is the canonical AceGUI fill-remainder pattern used elsewhere in the addon).
- **Sort: overflow tab now merges partial stacks of the same item, and the planner actively compacts the stock tab at every stage.** A new Phase 0 pre-merges same-item partials in overflow before any cross-tab routing happens, walking each run and pouring partial stacks together up to the per-item max stack size; Phase 1B's `pickOverflowSlot` is now capacity-aware and tops up an existing same-item partial before extending into a new slot, with a single supply allowed to split across multiple destinations. Phase 4 retains its position-compaction job; the merge logic moved to Phase 0. The combined effect: a run that previously ended as `[160, 160, 100]` of Healing Potions (max stack 200) now ends as `[200, 200, 20]`, AND a stock tab that was previously reported "out of space" because partial stacks consumed slots is now correctly seen as having room. Repeat sorts remain idempotent. Items whose max stack size has not yet loaded into the client cache (cold cache after `/reload`) skip the merge for that item only and fall back to grouping; a follow-up sort once the data finishes loading completes the work.

### Fixed
- **Sort planner refuses to emit ops that would over-stack same-item slots.** `canExecute` and `applyOpToState` now accept an optional `getMaxStack` lookup; when a same-item dst is already at capacity, `canExecute` returns false (the op stays in `remaining[]` until something drains the dst, or bails via the existing cycle/pivot path) and `applyOpToState` asserts to surface bypass bugs. Without this, Phase 4 packing could cascade an op chain like `move S28→S29 x200; split S29→S30 x200` where S29 already held x200 (working state went to x400, plan looked fine on paper, but the WoW server refused the merge and the executor's pre-check eventually caught the divergence after several ops). The guard is per-item and gracefully no-ops when maxStack is nil (cold-cache fallback for items not yet loaded into ItemCache).
- **Sort executor no longer reports `[sync]` success on no-op moves.** Every advance path (sync, async event, late-poll, late-ACK reclassify) now requires a src-drained predicate in addition to the existing dst+cursor predicates. The WoW client optimistically updates bank slots on Pickup, so when dst already holds same-item at max-stack capacity a true no-op (drop refused, cursor returns to src) looked identical to a successful move from the dst+cursor perspective alone. The src-drained check verifies that for "move" ops src is empty (or holds a different item), and for "split" ops src.count has decreased by ≥ op.count. When the predicate fails, the audit logs a `Sort op N no-op suspected [sync|async|...]` line and the executor falls through to the timeout-poll path which records the op as a real failure and triggers replan rather than advancing past a phantom success. Also added a cursor-empty gate to the OnSlotsChanged async-success branch so the executor doesn't advance mid-Pickup-pair when the pickup half's GUILDBANKBAGSLOTS_CHANGED arrives before the drop has resolved.

## [0.30.3] - 2026-04-27

### Changed
- Repository workflow: disabled auto branch deletion on merge and adopted long-lived per-area topic branches (`ui`, `sync`, `accessibility`, `layout-sort`) for recurring maintainer work. Short-lived `chore/*`, `infra/*`, `hotfix/*` branches still cover one-off and cross-cutting changes. Documented in the new `CLAUDE.md` Branch Workflow section and reflected in `CONTRIBUTING.md`. No addon behavior change.

## [0.30.2] - 2026-04-27

### Added
- **Sync audit trail now distinguishes silent receiver-side aborts from wire loss.** Two diagnostic-only additions, no behavior change:
  - **Receiver auto-bootstrap audit line.** When a `SYNC_DATA` chunk arrives while the receiver is not in an active receive session AND the chunk index is greater than 1, the audit log now records `Auto-bootstrap at chunk N from <sender> (prior abort signal likely missed)`. This signals that the receiver missed an earlier abort hand-off (combat with lost BUSY, or a sender-side state desync) and is recovering data mid-stream from chunk N onward. Bootstraps at `chunk = 1` stay silent (legitimate fresh start, e.g. addon reload between SYNC_REQUEST and the first chunk).
  - **Sender liveness tag on ACK timeout retries.** The `ACK timeout — retrying chunk N (attempt X/Y), fragments~=Z, gapSinceWire=Ts, nacksThisChunk=N` audit line now appends `, target=<online|offline|unknown>` from `IsGuildMemberOnline`. `unknown` covers both "not in roster" and "roster not yet populated" (the latter only relevant for the first few seconds after `PLAYER_ENTERING_WORLD`). Lets future capture analysis count how many timeouts happened against a peer who was already offline (failed-to-detect-disconnect) versus a peer who was nominally online (true wire loss or in-instance silent abort).

The motivation is observability before action: prior captures showed `chunkFail≈45–50%` patterns that conflate true wire loss, combat-with-lost-BUSY, full peer disconnect, and a separate auto-bootstrap desync path. Fixing chunk sizing without first measuring the cause distribution risks treating the wrong failure mode. These two log lines let the next 2–3 real failure captures be cross-correlated to pick the right v0.30.3 fix.

## [0.30.1] - 2026-04-25

### Changed
- Internal refactor: extracted a `GBL:SafeRecordTimestamp(record)` helper in `Dedup.lua` to replace ten copies of the `IsValidTimestamp(record.timestamp) and record.timestamp or GetServerTime()` ternary across `Core.lua` (nine migration paths) and `Sync.lua` (one in `NormalizeRecordId`). No behavior change. Three of the call sites that had been wrapped onto two physical lines collapse back to one. Re-enables the 120-character line-length lint on `Core.lua` (the `.luacheckrc` file-specific override placed in v0.28.12 is now removed).

## [0.30.0] — 2026-04-24

### Added
- **Sort Access now has two independent tiers.** The Layout tab's Sort Access section is split into **Layout Write access** (edit templates, capture, pin slots, change stock reserves — inherently includes sort) and **Sort-only access** (press Execute on the Sort tab but cannot edit the layout). Each tier has its own rank threshold and its own delegate list, configured independently. Only the Guild Master can change the policy. The intent is to let the GM hand out sort execution widely (anyone in the sort tier can run a sort) while keeping layout edits locked down to a small trusted group.
- **Defense-in-depth gate at the storage API.** `SaveBankLayout` and `SetStockReserve` in `BankLayout.lua` now reject any caller who does not pass `HasLayoutWrite()`. Previously the check lived only in the UI callback layer; a future UI bug that forgot the check could have silently mutated the layout. This is belt-and-suspenders — the UI gate still runs first.
- **`GBL:HasLayoutWrite()`** as the canonical "can edit the layout" check. `HasSortAccess()` keeps its meaning (can press Execute), now with broader semantics: write implies sort, so anyone in the write tier is automatically counted as having sort access regardless of the sort tier's membership.

### Changed
- **Existing `sortAccess` configurations migrate into the new Layout Write tier.** On upgrade, anyone who had sort access before (via the old single-tier rank threshold or delegate list) keeps layout write access — no one silently loses a permission. The sort-only tier starts empty; populate it in the Layout tab if you want to grant sort without layout write. Migration is idempotent and runs automatically at addon load.



### Fixed
- **Sort progress counter no longer exceeds the plan total after a replan.** v0.29.23's display used `(done+failed) / total` — but `done` and `failed` accumulate across replans while `total` is the current (possibly-smaller) plan's size, so once a replan reissued work the numerator could overshoot (users saw `34/33`, `35/33`). Switched the display to `op N / T` using the executor's live `opIndex` and current-plan `total`, which is always in-range and reflects "where are we in the plan that's actually running."
- **Move list and per-op markers now realign after a replan.** SortExecutor's `doReplan` now emits a `phase="planupdated"` progress message with the new plan right after it's built. SortView swaps the cached `_sortLastPlan` to the new plan, clears the stale `_sortOpStatus` (old indices referred to different moves), and rebuilds the move list so the displayed rows match what the executor is actually working on. During execution, `_SortView_Preview` now uses the cached plan instead of re-running `PlanSort` — otherwise a rescan-triggered rebuild could show a plan different from the one executing.

## [0.29.25] — 2026-04-24

### Fixed
- **Sort progress markers now render in WoW's default font.** v0.29.23 used `▶` / `✓` / `✗` Unicode glyphs that FRIZQT__ doesn't ship; users saw colored tofu boxes instead. Swapped to colored ASCII: `>` for currently executing, `+` for completed (including late-ACK reclassified), `x` for failed. Same colors, intelligible shapes.
- **Per-op status markers now survive Sort tab rebuilds mid-sort.** `Ledger.lua` fires `RefreshUI` every time a rescan sees new transactions — and every successful move creates one — which routed through `UI/UI.lua`'s generic `SelectTab("sort")` fallback, re-entering `BuildSortTab` and wiping `self._sortOpRows`. Only the top progress label recovered (via the next event). Per-op markers were lost because they were transition-triggered and those events had already fired. Fix: the progress handler now writes every transition into a persistent `self._sortOpStatus` table (and the progress label text into `self._sortProgressText`) in addition to the live SetText calls. On rebuild, the Preview loop repaints each row from the status table and the progress label from the text cache. Tab-switching away and back mid-sort now preserves the full visual state too.

## [0.29.24] — 2026-04-24

### Changed
- **Every sort now ends by tidying the overflow (stock) tab.** Added a Phase 4 to `SortPlanner` that, after Phase 3's defensive sweep, reshapes the overflow tab into a deterministic contiguous layout starting at slot 1: stacks sorted by (itemID ASC, count DESC, original slot ASC), closing gaps and grouping same-item stacks. Previously the overflow was a dumping ground — Phase 1B/3 only grouped *new* spills via adjacency, so pre-existing scattered stacks stayed scattered. Repeat sorts are now idempotent (already-compact overflow → zero Phase 4 ops). Swap cycles within the overflow resolve through the same `findPivot` Phase 2 uses. Partial-stack merging (e.g. 10+10 → 20) is out of scope here — the planner has no max-stack knowledge; that's a follow-up.
- **Internal: extracted Phase 2's pivot-break loop into a reusable `pivotBreakLoop` local** so Phase 2 and Phase 4 share the same cycle-breaking machinery. No behavioral change to Phase 2.

## [0.29.23] — 2026-04-23

### Added
- **Live sort progress in the Sort tab.** While a sort is running, the Sort view now shows a running `Executing — N / T (X done, Y failed, Z replans)` line at the top of the move list, updated on every op transition via a new `GBL_SORT_PROGRESS` message. Each individual move row gets a status marker prepended as it advances: `▶` for currently executing, `✓` for completed (including late-ACK reclassification), and `✗` for failed. No network cost — sort execution is 100% local, and the UI updates are direct `SetText` calls on persistent widget references, not full tab rebuilds.
- **`GBL_SORT_PROGRESS` AceEvent message.** Emitted by SortExecutor on every state transition: `start`, `step`, `complete`, `failed`, `replan`, `reclassify`, `finish`. Payload includes `opIndex`, `done`, `failed`, `replans`, `total`, `currentOp`, and per-phase extras (`completedOpIndex`, `failedOpIndex`, `reclassifiedOpIndex`, `replanReason`, `ok`, `reason`). External consumers (UI, chat formatters, audit plumbing) can subscribe without poking into executor-local state.

## [0.29.22] — 2026-04-23

### Fixed
- **Late-ACK reclassification now fires during an in-flight op, not just when idle.** v0.29.19 added the grace window but gated it on `state.waiting == nil` — which in a live sort is almost never true (the inter-move gap is 0.3s, so a delayed 4-second ACK almost always arrives while the next op is already armed). The handler now checks `lastTimedOutOp` independently of `state.waiting`, so a late server ACK retroactively reclassifies the prior op as success even if the executor has already moved on. The second-pass check for the current in-flight op runs separately, so the event still advances the plan when it confirms the current op. This should collapse the noisy "op N timed out, op N+1 pre-check fail" audit lines down to clean "op N confirmed by late event" lines on realistic sorts.

### Changed
- **Dialed back the Capture button diagnostics to happy-path-silent.** v0.29.21 added loud chat output on every Capture click to chase a reported regression (turned out to be transient UI state that cleared on /reload). The pcall-wrapped error handler and the pinned-slot count in the success message both stay — they're cheap and useful. The per-branch state prints are removed since the regression isn't reproducible.

## [0.29.21] — 2026-04-23

### Added
- **Capture-button diagnostics in the Layout editor.** Clicking Capture now emits a chat line at every branch: the initial click (`Capture: click on tab N...`), the guard state (`scan=true/false slots=true/false dirty=... writable=...`), and a pcall-wrapped capture attempt so an unexpected Lua error in `CaptureTabLayout` surfaces as a visible message instead of a silent failure. The success message now also reports the number of pinned slots alongside distinct items. Purpose: chase down a reported regression where Capture on a freshly-switched-to-Display tab appeared to do nothing.

## [0.29.20] — 2026-04-23

### Added
- **Timeout-time state diagnostics in SortExecutor.** When a move op times out, the audit trail now dumps three extra lines per timeout: (1) a one-word classification — `[none]` (move never executed), `[partial]` (pickup done, drop failed), `[complete]` (move succeeded, ACK was lost), or `[other]` (anomalous); (2) the full op details (src/dst tab+slot, itemID, count, op type); (3) observed live state of src, dst, and cursor. Purpose: distinguish server-drop vs. late-ACK vs. cursor-leak scenarios without round-tripping for more data. Also added the same op-details line to dst-mismatch pre-check failures so the cascading-replan case is legible in the audit trail.

## [0.29.19] — 2026-04-23

### Fixed
- **Late ACK after move timeout no longer triggers a cascade abort.** The SortExecutor waits up to `MOVE_CONFIRM_TIMEOUT` seconds after issuing each move for `GUILDBANKBAGSLOTS_CHANGED`; when the timeout fired first, the subsequent (legitimate but late) event was misclassified as "foreign activity" and triggered a replan. Replan's fresh scan saw the move already settled, but the new plan still listed the just-completed move as op 1 in some cases, producing a pre-check failure loop that chewed through all 5 replans before aborting. Observed in-game with 2/222 ops completed before abort. The executor now tracks the most recent timed-out op for a short grace window (`LATE_ACK_GRACE = 5s`) and, if a stray `GUILDBANKBAGSLOTS_CHANGED` arrives while idle AND the timed-out op's dst slot is now populated as expected, retroactively reclassifies the op as success rather than replanning.

### Changed
- **`MOVE_CONFIRM_TIMEOUT` raised from 2s → 4s** to reduce how often legitimate server ACKs race the timeout on high-latency realms. Sort throughput is unchanged in the happy path (fast ACKs still advance immediately); this only matters for slow ACKs that would otherwise get misclassified.
- **`SCAN_WAIT_TIMEOUT` raised from 5s → 10s.** Full-bank scans on 7+ populated tabs were observed taking ~4s in-game, too close to the 5s cap — one slow scan was enough to abort an otherwise-recoverable sort run.

## [0.29.18] — 2026-04-23

### Added
- **"Unpin all slots" button per display tab.** Sits next to "Capture current layout" in the Layout editor. Clicking wipes `tab.slotOrder` and leaves `items` intact — so the same item list is retained but every slot position becomes planner-decided at sort time. The intended use case (and v0.29.17 diagnostic target): you captured a tab with N items pinned to specific slots, then bumped Slots on some items to restock, and the new stacks scattered to the end of the tab instead of landing adjacent to their same-item group. One click of Unpin All lets the planner pack everything by adjacency on the next sort.
- **Per-item "Unpin" button** on every item row in the Layout editor. Clears `slotOrder` entries just for that one item; the rest stay pinned. Useful when you want most of a captured tab frozen but one high-churn item to flow freely. Disabled when the item has no pinned slots.
- **Pin-count label on every item row.** Between the `= N` total and the action buttons, each row now shows `N pinned` (yellow) or `not pinned` (gray) so the pin state is visible at a glance without scrolling down to the slot map.

### Mode guidance
There are now three legible modes per display tab:
1. **Fully pinned** — `Capture` a tab; every slot is pinned to a specific item. Sort enforces exact positions. Best for tabs you've deliberately arranged and don't want shuffled.
2. **Fully declarative** — `Capture` then `Unpin all slots`, or just `Add Item` without ever capturing. Items are listed with slot counts but no positions. Planner packs items by adjacency at sort time. Best for gem/stock tabs where you care about "these items exist" more than exact placement.
3. **Mixed** — Capture to fix some items, then `Unpin` the rows that should flow freely. Use when a handful of items deserve fixed positions but the rest should restock cleanly.

## [0.29.17] — 2026-04-23

### Added
- **Demand origin tracking in SortPlanner.** Each demand now carries an `origin` field — one of `"pinned"` (slotOrder entry from Capture), `"extend-right"` / `"extend-left"` (Pass 2a adjacency extension from a pinned claim), or `"first-empty"` (Pass 2b fallback when no adjacency is possible). Exposed on `plan.demandMap[tabIndex][slotIndex].origin`. The gem-tab restock pattern — pinned gems forcing new stacks to scatter to the end of the tab — is now visible in diagnostics as a high first-empty count alongside a high pinned count.
- **`/gbl sortpreview` per-tab origin breakdown.** After the `Plan: N moves, …` line, each display tab prints `T2 origins: 47 pinned + 3 auto-placed (0 extend-right, 0 extend-left, 3 first-empty)`. Each planned-move line is now annotated with `(dst pinned)` / `(dst extend-right)` / etc. so you can trace why each move lands where it lands.
- **Layout editor slot map header shows the three-way split.** Previous wording `"98/98 pinned"` is replaced with `"47 pinned + 3 auto-placed; 48 empty"`. The per-item line under "auto-placed at sort time" now distinguishes `(3 auto-placed)` from `(1 pinned + 3 auto-placed)` — the second form is the gem-tab pattern where an item has captured stacks plus new ones.

## [0.29.16] — 2026-04-23

### Fixed
- **Layout tab edits no longer show a visible scroll-snap flicker.** v0.29.15 preserved scroll position across rebuilds, but the Release → Build → SetScroll sequence was still visible as a brief blank-then-snap. The TabGroup's content frame is now hidden (alpha 0) for the duration of the rebuild and revealed (alpha 1) after scroll has been re-applied, masking the flicker entirely. From the user's perspective the tab appears static during edits.

## [0.29.15] — 2026-04-23

### Fixed
- **Layout tab no longer scrolls to the top every time you press Enter in an EditBox.** The tab rebuilds itself on every edit (to keep the slot budget label, save/discard buttons, and slot map panel in sync with the draft state), but that rebuild also recreated the ScrollFrame — throwing away scroll position. Editing a Slots or Per slot value halfway down the page would jump you back to the top, making anything past the first tab untenable to configure. The ScrollFrame now persists its scroll position across rebuilds via `SetStatusTable` on a table owned by the addon, and is re-applied once the new layout settles so the user stays where they were.

## [0.29.14] — 2026-04-23

### Added
- **Slot map panel in the Layout editor.** Every display tab now shows its `slotOrder` as a compact run-length list right under the item-row table — e.g. `S1-S23 (23): Silvermoon Health Potion × 20`, `S24 (1): Light's Potential × 20`, `S25-S49 (25): Silvermoon Health Potion × 20`. A 1-slot run wedged between two long runs of another item now stands out visually, which is exactly what the v0.29.12 "hidden swap" incident needed. When a recent bank scan is loaded, each run is compared against live slot contents and annotated with a green ✓ (all match) or red ✗ (N mismatches) plus per-slot detail lines naming what's actually sitting there. Items whose `items[id].slots` exceeds their pinned slotOrder count list below as "auto-placed at sort time" — matches the v0.29.13 ownership split (Capture pins, everything else is planner-placed).
- **Pure `computeSlotRuns(slotOrder)` helper** exposed as `GBL._layoutEditorComputeSlotRuns` for the spec suite. Seven new tests cover empty input, contiguous fills, gap-breaks-run, the v0.29.12 anomaly shape (four runs including two 1-slot outliers), sparse non-adjacent keys, and nil inputs.

## [0.29.13] — 2026-04-23

### Changed
- **Layout editor no longer pre-pins `slotOrder` positions for Add Item or Slots-up edits.** The UI used to call a `pickSlotForItem` heuristic (right-extend → left-extend → first-empty) to pre-populate `slotOrder` every time a user added an item or bumped its Slots count. That pre-pin was indistinguishable from a real captured position — the planner would then rigidly enforce it as if the user had deliberately chosen that slot. The same adjacency logic already lives in `SortPlanner` Pass 2, so the prefill was pure duplication that just muddied the semantics of `slotOrder`. `slotOrder` is now written only by Capture (which reflects an observed bank state) and left untouched by Add Item / Slots-up (the planner places those demands adjacent to any existing pins at plan time). Result: saved layouts are smaller, `slotOrder` always means "pin these exact positions because I observed them," and the behavior for Add-Item-then-Sort is byte-identical to before. Slots-down still trims stale `slotOrder` pins, and Remove still clears entries for the removed item.

### Fixed
- **No more silent partial state from Add Item on a full captured tab.** Previously, if you added an item to a nearly-full captured tab, `items[id].slots` would be set but only some of the requested slots would get `slotOrder` entries (the rest silently dropped when `pickSlotForItem` ran out of empty slots). Validation caught the aggregate over-budget at save time, but not the specific "this item couldn't be placed" failure. With the prefill gone, the over-budget case surfaces cleanly at save time against the authoritative `items[id].slots` sum.

### Tests
- New `spec/sortplanner_spec.lua` test: a layout with three items, `items[].slots` set, and `slotOrder={}` produces the exact same final bank placement as the old pre-pinned variant — X/Y/Z packed contiguously at slots 1-5, 6-10, 11-15 in sortedID order.

## [0.29.12] — 2026-04-23

### Added
- **`/gbl deviations` (alias `/gbl devs`)** compares the current bank scan to the layout's expected demand map and prints every slot that doesn't match. Three categories of deviation are reported: wrong item, wrong count (same item), and empty-where-expected; plus "extras" for items sitting in unclaimed slots. Output is capped at 40 lines so a disastrous state doesn't flood chat; full detail stays in the audit trail.
- **Auto-run deviation check after Execute.** The Sort tab already rescans after Execute (v0.29.9); it now also runs `PrintDeviations` once the fresh scan lands, so you immediately see what didn't match without having to type the command.
- **`plan.demandMap` exposed by `PlanSort`.** Maps `tabIndex` → `slotIndex` → `{itemID, perSlot}` for every display demand including `items[id].slots` extensions. Consumed by the deviations check and available to other diagnostics. Backward-compatible additive field; consumers that don't read it are unaffected.
- **Pre-check failure audit entries now include the observed state.** Instead of `"Sort: replan (src mismatch at op N)"`, the audit now records `"Sort op N/M pre-check fail src T1/S5: expected it:12345 x>=20, got it:99999 x10"`. Makes it obvious whether foreign activity, a split-size drift, or a planner bug caused the replan.

## [0.29.11] — 2026-04-23

### Fixed
- **Sort now keeps each item's span contiguous in the display tab.** When `items[id].slots` exceeded the captured `slotOrder` entries (e.g., you captured 25 slots and then edited Slots up to 49), the planner's Pass 2 used to fill "first unclaimed slot" and could land items in the middle of another item's section depending on itemID ordering. The planner now extends an item's contiguous group RIGHT first, then LEFT, only falling back to arbitrary empty slots when both ends are blocked. Result: a group that started at 50-74 grows to 50-98 before it ever reaches back to slot 49.
- **Overflow (stock) tab stays organized by item.** Before, spills routed to the first empty overflow slot regardless of what was next to it — a stray Power Potion would land between a Health block and whatever else was in stock. The planner now prefers slots adjacent to existing same-item stacks (right-extend first, then left-extend), so stock grows by item group instead of filling the next free slot.
- **Layout editor's Add Item and Slots field apply the same adjacency rule.** New item rows and Slots-increase edits now extend the item's contiguous group instead of picking the first empty slotOrder position. Keeps saved layouts neat without requiring a recapture.

## [0.29.10] — 2026-04-23

### Fixed
- **First-bank-open scan after login no longer misses every item.** The scanner was scanning each tab immediately after calling `QueryGuildBankTab`, but on first open the client has no slot data yet — so 98 slots read as nil, the event handler was unregistered too early, and when the server's actual response arrived the scanner had already moved on. Result: the first scan after login saw the bank as empty, and the Sort tab reported everything as "missing." The scanner now waits for `GUILDBANKBAGSLOTS_CHANGED` before scanning a tab, with a 3-second timeout fallback for tabs that genuinely have nothing to send.

## [0.29.9] — 2026-04-23

### Fixed
- **Sort tab now auto-refreshes after Execute.** Preview was previously re-running against the pre-sort snapshot (the cached scan is stale until you rescan), so the plan looked unchanged even after sort had actually run. The tab now triggers a fresh scan when Execute completes, shows a "Rescanning bank after sort…" placeholder while it waits, then re-previews against the post-sort state.

## [0.29.8] — 2026-04-23

### Fixed
- **Sort planner now honors `items[id].slots` as the authoritative demand count.** Before, the planner counted demands from `slotOrder` entries only — so if you captured a layout with 3 slots of an item and then edited the Slots field in the Layout UI to 5, the 2 extra slots were silently dropped from the plan (reported as "no discrepancy"). The planner now emits demands up to `items[id].slots`, adding extras at the first unclaimed slot indices. Both directions are handled: increasing Slots adds demands at new positions; decreasing Slots caps demands at the new count and routes the surplus to overflow.
- **Phase 3 sweep no longer mis-evicts items placed by dynamically-added demands.** The sweep consulted raw `slotOrder` rather than the effective demand set, so items placed at Pass 2's extended positions were treated as stragglers and routed to overflow on the next op. Fixed by checking the effective demand map.
- **Layout editor's Slots input now keeps `slotOrder` in sync.** Increasing Slots adds slot-order entries at the first unclaimed indices; decreasing Slots trims from the highest slot index down. Prevents the mismatch above from ever being saved again.

### Added
- **`/gbl sortpreview` now prints a diagnostic breakdown.** Shows per-display-tab demand counts, overflow/ignore tab assignments, scan contents by tab, and an explicit reason when the plan is empty ("layout has no display-tab demands" vs. "every demand is already satisfied") — makes it obvious whether a 0-op result is a config issue or the bank truly matches.
- Two new regression tests in `spec/sortplanner_spec.lua`: `items[id].slots` exceeds `slotOrder` count (pass extras into unclaimed slots) and `slotOrder` exceeds `items[id].slots` (cap at items count and send surplus to overflow).

## [0.29.7] — 2026-04-23

**Milestone M-sort-2.5: Planner algorithm upgrade**

### Changed
- **Sort planner rewritten from three-pass greedy to assign-then-schedule.** Same public contract (`PlanSort(snapshot, layout)` returns the same shape), no UI or saved-variable changes — a drop-in upgrade. Phase 1 assigns every demand to the best available source (same-tab direct → overflow → cross-tab; largest-count first within each tier). Phase 2 schedules the moves against a mutating state model and breaks swap cycles with a pivot slot (same-tab empty preferred, overflow fallback). Phase 3 sweeps any stragglers.
- **Direct intra-tab moves skip the overflow round-trip.** An item in the wrong slot of the right tab now moves straight to its template slot — one op instead of two (evict + pull back).
- **Oversize stacks serve multiple demands from a single source.** An oversize stack is no longer pre-split to overflow before the planner has looked at other demands; it splits directly into each destination that needs the item.
- **Largest-source-first source selection minimizes split count.** When multiple same-item stacks can fill a demand, the planner picks the largest first so a single split ends the work.
- **Swap cycles are detected and resolved with a pivot.** 2-cycles cost 3 ops (was 4 via overflow), 3-cycles cost 4 ops (was 6). Unreachable cycles — no empty unclaimed slot anywhere — are now reported as `unplaced` entries with `reason = "cycle-no-pivot"` instead of silently emitting half-broken ops.

### Added
- `plan.unplaced[].reason` field — one of `"overflow-full"`, `"cycle-no-pivot"`, `"no-overflow-defined"`. Backward-compatible (old callers ignore it); the existing SortExecutor and UI/SortView are unaffected.
- 9 new planner tests in `spec/sortplanner_spec.lua` pinning the algorithmic wins (direct move, oversize split sharing, same-tab pivot, overflow pivot fallback, 3-cycle break, largest-first, unreachable-cycle unplaced, oversize-keep excess harvest).
- `spec/sortplanner_perf_spec.lua` — benchmark asserting a worst-case plan (8 tabs × 98 slots, 90 demands) completes in under 250 ms.

## [0.29.6] — 2026-04-23

### Changed
- **Layout tab save-bar is now self-explanatory.** The explicit save model (edits buffer in a draft until you click Save) is unchanged — that's deliberate so validation and sync broadcasts happen once per logical change, not per keystroke — but the UI now makes the state obvious. A status banner above the save row reads "You have unsaved changes…" when the draft differs from storage, or "Layout is up to date…" when clean. The save button is disabled and labels itself "Saved ✓" when there's nothing to commit, "Save Layout" when dirty. "Revert" was renamed to "Discard changes" and disables when clean. Capture now explicitly notes "Click Save Layout to commit" in its success message.

## [0.29.5] — 2026-04-23

### Fixed
- **Capture current layout** now works in more states. Previously it silently did nothing when the addon had no stored scan for the target tab (no visible feedback either — the failure print was easy to miss). It now: (a) warns if the bank is closed, (b) kicks off a scan automatically if no scan exists, (c) polls for scan completion up to 5 seconds, (d) applies the capture when data arrives, and (e) surfaces a specific error if the scan never produced data for the target tab (e.g., the character can't view it). Prints a green success line on completion.

## [0.29.4] — 2026-04-23

### Fixed
- **Layout tab dropdowns are now interactive.** Mode changes (display / overflow / ignore) were being wiped immediately on refresh because `BuildLayoutTab` re-initialized the in-progress draft from saved storage on every render. The draft now persists across rebuilds and is only reset explicitly on Save or Revert.
- **Sort Access rank dropdown now shows all options and defaults correctly.** It was built as an array instead of a hash keyed by option value, so AceGUI rendered the first two entries as blank. The dropdown now shows "None (GM only)" followed by "Rank N and above (rankname)" for each guild rank.

## [0.29.3] — 2026-04-23

**Milestone M-sort-2 (UI): Layout editor + Sort tab**

### Added
- **Layout tab** — one section per guild-bank tab with a Mode dropdown (Display / Overflow / Ignore). Display tabs gain an item-template editor: a row per item with Slots / Per-slot inputs and a live slot-budget readout; a "Capture current layout" button that snapshots a hand-arranged tab into the template; and an Add-item input that accepts either a numeric itemID or a pasted item link. Save / Revert buttons on the bottom. Tab is only visible to characters with sort access; all controls are read-only when viewed without access.
- **Sort tab** — Preview button builds a plan from the latest scan and renders the planned moves, deficits, and unplaced items with human-readable item names. Execute button runs the plan through `SortExecutor` (gated by `HasSortAccess()`), Cancel button aborts. A Scan-bank shortcut is included so you don't have to leave the tab to refresh.
- **Sort Access** sub-section inside the Layout tab — GM-only rank-threshold dropdown (populated from guild ranks) + delegate add/remove. Non-GMs see the current policy read-only.
- Tab visibility is now access-aware: the Layout tab only appears for characters with sort access. Others still see Sort for read-only preview.

### Notes
- This completes M-sort-2. Next milestone (M-sort-3) adds the Stock tab + bag restocker.

## [0.29.2] — 2026-04-23

**Milestone M-sort-2 (backbone): Sort executor + sort-access policy**

### Added
- `SortAccess` policy — a new AceDB field (`sortAccess`) and `GBL:HasSortAccess()` helper that mirror the existing access-control pattern. The Guild Master configures a rank threshold and an optional list of named delegates; any character who is the GM, at-or-above the threshold, or explicitly delegated can edit bank layouts and execute sort. Writes to the policy itself remain GM-only so delegates can't self-escalate. Default is GM-only on fresh install.
- `SortExecutor` module — executes a plan one op at a time with a 0.3s inter-move throttle, pre-step verification against live bank state, `GUILDBANKBAGSLOTS_CHANGED`-driven confirmation plus a 2-second polling fallback, replan-on-foreign-activity (capped at 5 replans per run), bank-close abort, and cursor-leak safety on every exit path. Audit entries trace every step, retry, replan, and failure.
- Two new slash commands for end-to-end in-game testing without UI:
  - `/gbl sortexec` — executes the currently saved layout's plan against the latest scan (GM/delegate-gated).
  - `/gbl sortcancel` — cancels a running sort.
- Mock WoW APIs for bank movement (`PickupGuildBankItem`, `SplitGuildBankItem`, `ClearCursor`, `CursorHasItem`) with cursor state tracking and `GUILDBANKBAGSLOTS_CHANGED` firing, plus test helpers to simulate foreign deposits/withdrawals. 10 new executor tests in `spec/sortexecutor_spec.lua` and 9 new access-policy tests in `spec/sortaccess_spec.lua`.

### Notes
- This is the non-UI half of M-sort-2. Layout editing and sort preview/execute UI come next. The executor can be fully exercised via the slash commands above.

## [0.29.1] — 2026-04-23

**Milestone M-sort-1.1: Audit cleanup for M-sort-1**

### Added
- CLAUDE.md Architecture section now lists `BankLayout` and `SortPlanner` alongside the existing modules, per the mandatory doc-sync-on-every-commit policy.
- Four regression tests in `spec/sortplanner_spec.lua`:
  - Ignore tabs are invisible to sort even when they hold an item the template wants — planner reports a deficit rather than pulling from ignore.
  - Keep-slot harvest protection: an already-correct slot is never cannibalized to fill another slot, even if it is the only source for that item. Pins the bug caught during M-sort-1 development.
  - Multiple display tabs: orphan items in a non-claiming display tab are evicted to overflow, then pulled into the claiming tab.
  - Overflow-full scenarios produce exactly one unplaced entry per stuck slot (no duplicates across passes).

### Fixed
- `SortPlanner` no longer emits duplicate `unplaced` entries when the overflow tab is full. Pass 1 now clears the working-bank copy of a slot it has recorded as unplaced so later passes don't re-process it. No effect on well-formed scenarios; only affects the overflow-saturated edge case.

### Notes
- No user-visible behavior change outside the overflow-full edge case. Pure audit follow-up.

## [0.29.0] — 2026-04-23

**Milestone M-sort-1: Bank sorting foundation (data + planner)**

### Added
- New `BankLayout` module: per-guild saved templates that describe each tab's role (`display`, `overflow`, or `ignore`). Display tabs list the items they hold along with how many slots each occupies and the target stack size per slot. Exactly one overflow tab is required; ignored tabs are untouched by sort. Includes `CaptureTabLayout` — reads the most recent scan of a tab and produces a template that mirrors its current contents, so officers can hand-arrange a tab once and save the result as the canonical layout.
- New `SortPlanner` module: given a bank scan and a saved layout, produces an ordered list of moves that will reshape the bank to match. Splits oversize stacks, pulls from other display tabs or the overflow tab to fill deficits, routes unassigned items to overflow, and reports shortfalls it could not satisfy. Pure function — no WoW API calls, fully deterministic, straightforward to test.
- AceDB schema: new per-guild `bankLayout` and `stockReserves` tables.
- Layout validation: exactly one overflow tab, no duplicate items across display tabs, per-tab slot budget ≤ 98, every `slotOrder` entry backed by a matching `items[]` row.

### Notes
- This milestone ships data + planner only. No execution, no UI, no sync wiring yet — those arrive in M-sort-2 through M-sort-4 on the `feature/sort-stock` branch.

## [0.28.12] - 2026-04-24

### Added
- GitHub Actions CI workflow (`.github/workflows/ci.yml`). Runs busted tests and luacheck on every pull request and on every push to `main`. Job context is `test-and-lint`, which Phase C will require as a passing status check before merge.

### Changed
- `.luacheckrc` extended to keep luacheck clean under CI: added `GameFontNormalLarge`, `GetItemInfo`, `GetRealmName`, `GetNormalizedRealmName` to read-only globals; ignored warning code 542 (intentional empty-if-branch pattern used for early-out comments); suppressed `max_line_length` for `Core.lua` (TODO: extract a `SafeRecordTimestamp` helper for the six repeated migration lines) and `UI/ChangelogView.lua` (changelog strings are intentionally one line per entry).

### Removed
- Dead `local savedSchema` capture in `Core.lua`'s migration pass-1 path. The variable was assigned but never read.

## [0.28.11] - 2026-04-24

### Added
- `CONTRIBUTING.md` with quick-start setup, commit + versioning conventions, test expectations, code style, and WoW-specific gotchas for new contributors.
- `.github/PULL_REQUEST_TEMPLATE.md` with structured Summary / Testing / Screenshots / Checklist sections.
- `.github/CODEOWNERS` so the maintainer is auto-requested as reviewer on every PR.
- README "Contributing" section linking to `CONTRIBUTING.md`.

## [0.28.10] — 2026-04-24

### Fixed
- Removed blank space at the bottom of all six tabs — Transactions, Gold Log, Consumption, Sync, Changelog, and About — by anchoring each tab's content frame to the container's `BOTTOMRIGHT`. Thanks @katogaming88 for spotting it and fixing the first three tabs in #1; extended to Sync / Changelog / About in a follow-up on the same PR.

## [0.28.9] — 2026-04-24

### Added
- LuaLS workspace config (`.luarc.json`) so contributors get consistent IDE diagnostics out of the box (Lua 5.1 runtime + WoW API globals).
- Internal design doc (`docs/sync-bucket-analysis.md`) capturing the v0.26.0-era throughput audit that justifies the 6-hour fingerprint bucket size — preserved for reproducibility now that the analysis lives outside the memory index.

### Changed
- CurseForge listing copy refreshed (Beta tag, reorganized sections, updated category counts). No code change.

### Fixed
- `.gitignore` now excludes `.claude/walkthrough/` and `.claude/settings.local.json` so machine-local Claude Code state stops appearing in `git status`.

## [0.28.8] — 2026-04-23

### Added
- Receiver-side redundancy metric in sync audit. New `Redundancy from <peer>` line in `FinishReceiving` reports total dupes/received plus item-vs-money split (e.g., `Redundancy from PeerX: 78% duped (1023/1314 received) — items: 65% (412/635), money: 90% (611/679)`). Per-chunk audit lines also gain a running `X% dup` annotation in the "total so far" segment. Diagnostics-only — no protocol or behavior change. Suppression rules: line omitted entirely when no records were received; items/money segments individually omitted when their record type is absent. Purpose: measure how often the bucket-filtered sync ships records the receiver already has, to inform whether a future manifest-exchange protocol change is justified by observed redundancy in real syncs.

## [0.28.7] — 2026-04-22

### Fixed
- Sync reliability: chunk budget reduced to a true 1-fragment target (`MAX_RECORDS_PER_CHUNK`: 10→4, `CHUNK_BYTE_BUDGET`: 2500→900). v0.28.6 aimed for 2 fragments but real cross-realm compression ratio is 23–26%, not ~18% as assumed — compressed chunks landed at 659–737 bytes (3 fragments) and the sync aborted at chunk 38/331 with `p_frag_est=44.9%`. At 900 raw bytes with 26% worst-case compression, compressed stays ≤240 bytes = 1 AceComm fragment per chunk. Per-attempt loss drops from ~45% (v0.28.6) to ~18%; 6-retry failure drops from ~0.8% to ~0.003% per chunk; likelihood of a full bootstrap sync completing goes from ~6% to ~97% on a cross-realm peer. Total sync time ~18 min for a ~3300-record bootstrap (subsequent syncs much shorter after bucket-delta convergence).

### Added
- Diagnostics bundle for per-sync A/B comparison:
  - **Retry cause tagging.** Each retry is tagged with its trigger (`ackTimeout` or `nack`). Aborts are split by cause: `combatAbort`, `zoneAbort`, `busyAbort`, `sendFailed` (target offline). Previous single-bucket `aborted` lost the distinction between a noisy test session and a genuine wire-loss problem.
  - **Corrected `p_frag_est` math.** Old metric computed `failedAttempts/totalAttempts` (chunk-fail rate) but labeled it per-fragment. New output reports both: `chunkFail` (raw retry rate attributed to wire loss only) and `p_frag` (back-solved per-fragment estimate using observed average fragments per chunk). At n=1 frag the two are equal; at higher n the inversion kicks in so comparisons across chunk-size changes are valid.
  - **Per-peer attribution.** `FinishSending` now emits three per-peer audit lines: `Sync outcomes for <peer>`, `Retry causes for <peer>`, `Compression for <peer>` (min/med/max compression percentage). With rotating cross-realm testers, per-peer is the only meaningful axis — a version that works on same-realm but fails cross-realm is no longer averaged away.
  - **Per-chunk compression capture.** Each chunk's compressed bytes and ratio stored in `chunkOutcomes`, aggregated at end-of-sync. The v0.28.6 compression-ratio miss (23–26% vs ~18% predicted) would have been visible from one sync's audit line rather than requiring hand-parsing multiple chunk lines.

## [0.28.6] — 2026-04-22

### Fixed
- Sync reliability: chunk density reduced further (`MAX_RECORDS_PER_CHUNK`: 25→10, `CHUNK_BYTE_BUDGET`: 3200→2500) so compressed chunks fit in 2 AceComm wire fragments instead of 4. v0.28.5 logs showed the v0.28.5 chunk revert (25/3200) did not actually cross the 3-fragment threshold — compressed payload stayed at ~836 bytes, still 4 fragments. Observed per-attempt chunk-loss rate on cross-realm whispers was ~67%, implying ~24% per-fragment drop. Halving the fragment count per chunk cuts per-attempt loss to ~42% and the 6-retry failure probability to under 1% per chunk. Total sync time roughly doubles in chunk count but actually completes instead of aborting.
- A conservative 1-fragment fallback (5 records / 1500 byte budget) is pinned as a commented block in `Sync.lua` and documented in `CLAUDE.md` — flip to it if v0.28.6 still aborts on cross-realm syncs.

## [0.28.5] — 2026-04-22

### Fixed
- Sync reliability: inter-chunk gap floor of 1.0s added between chunk transmissions to avoid WoW's server-side per-recipient whisper throttle, which silently drops the 3rd+ rapid-succession addon message to a single peer. Paired sender/receiver logs captured with v0.28.4 instrumentation confirmed this was the dominant failure mode — chunk 3 vanished deterministically across 6 ACK-timeout retries plus 2 NACK retransmits, while CTL and client-side pacing reported healthy. The floor is independent of `CTL_BACKOFF_DELAY` and the post-ACK `GetSyncDelay()`; the first chunk is exempt, zone/combat pause resumes already exceed it, and ACK-timeout retries naturally satisfy it.
- Chunk density reverted from v0.28.0's aggressive tuning back to v0.27.0 values (`MAX_RECORDS_PER_CHUNK`: 35→25, `CHUNK_BYTE_BUDGET`: 5000→3200). Compressed chunks drop from ~4 AceComm wire fragments to ~3, making each chunk cheaper in the throttle budget and more resilient to residual fragment-level loss. Trade-off accepted: ~40% more chunks per sync, but total sync time is longer only because syncs now complete instead of aborting.

## [0.28.4] — 2026-04-22

### Added
- Sync diagnostic instrumentation — additive audit-log fields to distinguish between four competing failure hypotheses (fragment loss, server-side throttle, receiver-buffer contention, wire-vs-ACK timing) without changing protocol behavior:
  - `Sending chunk` entries now include `CTLq=A/N/B` — ChatThrottleLib priority-queue depths (ALERT/NORMAL/BULK) — when `ChatThrottleLib.Prio` is exposed. Distinguishes "CTL clear" from "CTL has bandwidth but other addons have queued traffic ahead of us."
  - `Sending chunk` entries now include `gap=X.XXs` — wall-clock delta since the previous chunk was issued. Directly tests the server-side per-recipient throttle hypothesis by correlating failures with sub-second inter-chunk spacing.
  - Successful ACK entries (first, every 10th, last) now include `wire-to-ACK=X.XXs` — elapsed time from AceComm wire-completion callback to ACK receipt. Discriminates "AceComm callback fires before wire transmission actually completes" from genuine peer/network latency.
  - ACK timeout entries now include `fragments~=N`, `gapSinceWire=X.XXs`, and `nacksThisChunk=N` — converts the previously terse timeout line into the primary forensic row for every failed chunk.
  - `FinishSending` now emits `Sync outcomes: a on 1st, b on 2nd, c on 3rd+, d aborted, p_frag_est=X.X%` — per-sync retry histogram with a rough fragment-loss-probability estimate (clamped to [0, 50%], reported `n/a` when fewer than 3 chunks are observed). Quantifies the fragment-loss hypothesis directly.

## [0.28.3] — 2026-04-21

### Changed
- Interface version updated from 120001 to 120005 (WoW 12.0.5)

### Added
- GitHub Action to auto-detect WoW interface version bumps and create PRs (`toc-update.yml`)

## [0.28.2] — 2026-04-21

### Fixed
- Sync send pacing: `HasSyncBandwidth` now requires CTL.avail > compressed chunk size (dynamic threshold) instead of a fixed 200 bytes, eliminating burst-queue pattern where 6-7 chunks would drain CTL to zero followed by 60-90 second stalls.
- CTL_BANDWIDTH_MIN raised back to 400 (floor) and CTL_BACKOFF_DELAY increased to 1.0s for efficient polling during recovery.
- HELLO replies suppressed during active sync — prevents third-party peers from consuming CTL bandwidth needed for SYNC_DATA transmission.

## [0.28.1] — 2026-04-20

### Added
- Sync diagnostic logging to identify two observed failure modes: CTL deferral death spiral (Mode A) and AceComm message loss (Mode B).
- CTL deferral entries now include `CTL.avail` value, monotonic counter, and `GetTime()` precision timestamps for chain analysis.
- CTL deferral audit entries rate-limited: first 10 verbose, then every 20th — prevents eviction of protocol events in long syncs.
- "Sending chunk" entries now include `CTL.avail` at send time (headroom diagnostic).
- AceComm transmit callback logged ("Chunk X transmitted") with queue-to-wire duration and post-transmit CTL.avail — absence between send and ACK timeout proves message stuck in queue.
- HELLO replies during active sync tagged `[DURING SYNC — CTL cost]` with per-session counter.
- NACK receipt entries include `CTL.avail` to prove sender-stuck-in-deferral feedback loop.
- Per-sync summary at FinishSending: CTL deferrals, HELLO replies during sync, NACKs received.

### Changed
- Audit trail cap increased from 200 to 2000 entries to capture full sync lifecycle.

## [0.28.0] — 2026-04-19

### Changed
- Sync throughput optimized: HELLO and MANIFEST broadcasts suppressed during active sync (keepalive every ~280s prevents peer staleness), CTL backoff delay reduced from 1.0s to 0.25s, CTL bandwidth threshold lowered from 400 to 200 bytes.
- Chunk density increased: byte budget raised from 3200 to 5000 and record cap from 25 to 35, reducing chunk count by ~36% for large syncs.

## [0.27.0] — 2026-04-19

### Fixed
- Records with Unix epoch 0 timestamps repaired — multiple `or 0` fallbacks replaced with validated timestamps across Dedup, Sync, Ledger, Core, Fingerprint, and ConsumptionView.
- Schema migration 7→8 repairs existing epoch-0 records (recovers timestamps from ID when possible) and cleans up bogus 1970-01-01 compacted summaries.

### Added
- "Open Sync Log" button in Sync tab for quick access to the copy-pastable sync log.
- Bottleneck diagnostics in audit trail: per-chunk RTT, CTL bandwidth backoff, compression ratio, pending peer queue time.
- `IsValidTimestamp` validation helper prevents future epoch-0 writes at all storage boundaries (StoreTx, StoreMoneyTx, MarkSeen).

### Changed
- Sync logging unified into single `AddAuditEntry` system — `SyncLog` function removed; chat and audit trail now report identical information via `chatOnly` parameter.
- Enriched audit messages: hard timeout includes duration, ACK retry includes "ACK timeout" prefix, NACK includes retry limit, received chunks include running totals.
- BUSY abort-send and BUSY clear-receive now create audit entries (previously chat-only).

## [0.26.0] — 2026-04-17

### Added
- Sync aborts immediately when entering combat (M+, raid) and notifies the partner via BUSY — previously the sync stalled through ~95 seconds of NACK timeout cycles.
- Separate 2-second combat cooldown prevents sync from resuming during rapid trash-pack combat cycling.
- HandleBusy now also aborts sending when the send target reports busy — previously only aborted receiving.
- Sync status UI shows "Paused (combat)" when combat pause is active.

## [0.25.5] — 2026-04-17

### Fixed
- Periodic rescan no longer double-stores records that arrived via sync — session caches are invalidated after each sync chunk so the next rescan uses ground-truth record counts.

## [0.25.4] — 2026-04-17

### Fixed
- Sync no longer requests data from peers with fewer records — avoids receiving 100% duplicate chunks that waste bandwidth and slow down the outbound sync that actually matters.
- Bidirectional check after sending now skips reverse-requesting from peers with fewer records, deferring to the peer's post-sync HELLO for convergence.

## [0.25.3] — 2026-04-17

### Fixed
- Sync receiving state no longer gets permanently stuck when a sync request goes unanswered — `RequestSync` now uses `ScheduleReceiveTimeout()` with proper NACK backoff and retry limits instead of a single-fire timer that expired after one attempt.
- BUSY response from a peer now clears receiving state even when partial data has been received, preventing permanent sync blockage.
- Added 30-minute safety net (`MAX_RECEIVE_DURATION`) to auto-abort any stuck receive session, providing defense-in-depth against future edge cases.

## [0.25.2] — 2026-04-16

### Fixed
- Sync whispers to offline players no longer generate "No player named" system errors in chat — online status is checked before every whisper, and any errors from roster-lag race conditions are suppressed.
- In-progress sync aborts cleanly when the target peer goes offline instead of hanging for up to 120 seconds.

## [0.25.1] — 2026-04-16

### Fixed
- Online peers list showed peers for up to 5 minutes after they went offline — roster is now cross-checked even for recently-seen peers.

## [0.25.0] — 2026-04-16

### Added
- **Epidemic gossip sync**: data propagates exponentially across guild members — each peer becomes a seed after receiving data, leveraging N independent bandwidth budgets for O(log N) convergence instead of O(N).
- Concurrent send + receive: clients can send data to one peer while simultaneously receiving from another, doubling sync throughput per client.
- Smart peer selection: pending peer queue uses priority scoring (divergence, BUSY cooldown, starvation prevention) instead of FIFO — most divergent peers sync first.
- GUILD manifest broadcast: bucket hash manifests broadcast every 5 minutes so all peers know each other's data state without N² WHISPER exchanges.
- Hash-gated HELLO reply suppression: WHISPER replies to broadcast HELLOs are suppressed when our data hasn't changed, reducing O(N²) traffic to near-zero in large guilds.
- Forced HELLO rate limiting: post-sync forced HELLOs capped at one per 10 seconds to prevent broadcast storms during rapid epidemic propagation.

### Changed
- Bidirectional check delay reduced from 3s to 0.5s — peers discover new data faster after sync.
- Post-receive HELLO broadcast delay reduced from 2s to 0.5–2s with jitter — faster re-seeding without storms.
- Pending peers queue processing delay reduced from 1s to 0.2s — faster epidemic chain reactions.
- Sync initiation jitter reduced from 0–2s to 0–1s — sufficient for oscillation prevention with bucket-based delta sync.

## [0.24.0] — 2026-04-15

### Added
- "Show minimap button" toggle in settings — hides the minimap icon while keeping the LibDataBroker launcher active for display addons (Titan Panel, ChocolateBar, etc.). (Requested by Rox)

## [0.23.0] — 2026-04-15

### Changed
- Sync chunk budget doubled (1600→3200 bytes) and record cap raised (15→25) — halves chunk count for faster syncs.
- ACK timeout reduced from 15s to 8s with more retries (3→5) — faster recovery from message loss.
- ACK and NACK messages now sent with ALERT priority for faster delivery through ChatThrottleLib.

### Fixed
- Stale ACKs from retried chunks no longer orphan active timers, which could cause 120-second sync stalls.

## [0.22.4] — 2026-04-15

### Added
- Peers in M+ dungeons or raid boss fights now stay visible in the Online Peers list as "online (no HELLO)" using guild roster fallback — previously they disappeared after 5 minutes.
- Known peers are persisted across sessions so addon users appear immediately on login even if currently in instanced content.
- Stale known peer entries automatically expire after 30 days without a HELLO.

## [0.22.3] — 2026-04-15

### Fixed
- Sync status now shows both "Sending" and "Receiving" when active simultaneously — previously only showed sending due to `if/elseif` precedence bug.
- Receive progress displays "waiting..." instead of confusing "0/0" while awaiting first chunk from peer.

## [0.22.2] — 2026-04-15

### Fixed
- Pending peers queue no longer attempts sync with peers confirmed offline by guild roster — `PopPendingPeer()` now checks `IsGuildMemberOnline()` before returning a queued peer.
- `FinishReceiving()` now removes the sender from the pending queue, preventing immediate re-request after a sync completes or aborts.

## [0.22.1] — 2026-04-15

### Fixed
- Automatic duplicate cleanup now runs after bank scan refreshes eventCounts, fixing a bug where duplicates from prior sync sessions survived because the OnEnable cleanup lacked fresh API ground truth to detect them.

## [0.22.0] — 2026-04-15

### Added
- **BUSY message type** — When a sync request is declined (sender already busy), a BUSY response is sent immediately so the requester doesn't wait 60s for data that will never come.
- **Pending peers queue** — Missed sync opportunities (busy, combat, zone change) are queued and automatically retried after the current sync completes. Capped at 10 peers.
- **Post-sync HELLO broadcast** — After receiving new data, broadcasts updated dataset fingerprint so peers discover the new data and can request it.
- **Post-sync queue processing** — After completing a receive, automatically syncs with the next queued peer.
- **Bidirectional sync** — After finishing sending data to a peer, checks if that peer has data we need and requests it (3s delay for processing).
- **Combat guard** — Sync initiation deferred during combat (PLAYER_REGEN_ENABLED resumes pending queue).
- **Mutual sync jitter** — 0-2s random delay on sync initiation to prevent collisions when multiple peers respond to the same HELLO.
- **Sender offline detection** — During receive timeout, checks guild roster to abort early if the sender went offline instead of waiting for NACK retries.
- **NACK backoff** — Progressive timeout delays (20s → 30s → 45s) instead of fixed 20s intervals for NACK retries.

### Changed
- **Shorter first-chunk timeout** — Initial receive timeout reduced from 20s to 10s since in-game addon messages have no network latency.
- **GetSyncStatus** now includes `pendingPeersCount` and `receiveNackCount` fields.

## [0.21.0] — 2026-04-14

### Added
- **About tab** — New right-aligned tab with addon info, author credit (RexxyBear), copyable Ko-fi and CurseForge URLs, library credits, and license info. Visible to all access levels.
- **GitHub Sponsors integration** — `.github/FUNDING.yml` enables the Sponsor button on the repository (GitHub Sponsors + Ko-fi).
- **Support section in README** — Ko-fi and GitHub Sponsors links.
- **`.toc` donation metadata** — `X-Donate` field for CurseForge integration.

## [0.20.1] — 2026-04-14

### Changed
- **Roadmap: moved Export to post-1.0** — Export feature (CSV, Discord Markdown, BBCode) deprioritized from beta release path to post-1.0. Stabilization is now the next milestone after beta preparation.

## [0.20.0] — 2026-04-14

### Changed
- **Documentation sync for beta preparation** — Updated README with accurate feature list (guild-wide sync, changelog tab, version label, peer version status, access control, 4 colorblind modes). Replaced stale ROADMAP with forward-looking release plan (v0.20.x beta prep, v0.21.0 export/beta, v1.0.0 public release, post-1.0 features). Updated CurseForge description from "Alpha" to "Beta" with correct consumption dashboard description. Updated .toc Notes to mention sync.

### Fixed
- **Changelog tab showing blank content** — pagination nav bar was added as a sibling before the ScrollFrame, preventing it from getting proper height in AceGUI's List layout. Moved nav controls inside the ScrollFrame so it remains the only direct container child.

### Removed
- `docs/IMPLEMENTATION_PLAN.md` — Obsolete planning document (v0.11.0 era), superseded by ROADMAP.md and CHANGELOG.md.
- `docs/PLAN.md` — Obsolete planning document, superseded by ROADMAP.md.

## [0.19.3] — 2026-04-14

### Changed
- **Sync and Changelog tabs right-aligned** — utility tabs (Sync, Changelog) are now pushed to the right side of the tab bar, visually separating them from the data tabs (Transactions, Gold Log, Consumption). Hooks AceGUI TabGroup's `BuildTabs` to reanchor on resize.

## [0.19.2] — 2026-04-14

### Changed
- **Changelog tab pagination** — changelog now loads 10 versions per page with Previous/Next navigation, eliminating the slow full-render on tab open. Nav bar hidden when data fits a single page. Buttons use dual-channel disabled state (text change + grayed) for accessibility. Page label respects font scaling.

## [0.19.1] — 2026-04-14

### Fixed
- **Sync chunk 1 oversized** — eventCounts metadata (dedup ground truth) was stuffed entirely into chunk 1, causing it to exceed AceComm's ~2KB WHISPER safe limit on full syncs. EventCounts are now partitioned into batches and spread across chunks. Fully backwards-compatible (no protocol version bump).

## [0.19.0] — 2026-04-14

### Changed
- **Consumption tab redesigned as guild-wide overview** — replaced collapsible per-player rows with a three-section dashboard: Guild Totals (items + gold in/out/net), Top Consumers (flat ranked table, top 10 players with full gold breakdown), and Most Used Items (top 15 items with 7d/30d/all-time withdrawal trend columns).
- Click a player name in Top Consumers to jump to the Transactions tab filtered by that player.

### Removed
- Collapsible player expand/collapse rows in the Consumption tab (replaced by flat tables).

## [0.18.1] — 2026-04-14

### Fixed
- **Changelog tab content truncated** — each version entry was rendered as a single AceGUI Label widget, which has a fixed single-line height and truncated multi-line text with "...". Refactored to emit one widget per visual line (version header, section headers, bullet items) so the full changelog is readable in-game.

## [0.18.0] — 2026-04-14

### Added
- **Directional peer version status** — sync peer list now distinguishes "newer — update available" (blue, when the peer has a newer version) from "outdated — no sync" (red-orange, when the peer is behind). Previously both cases showed the same ambiguous text.
- **Version label** — addon version now displayed in the top-right corner of the main frame. When any online peer has a newer version, the label turns orange with "update available (vX.Y.Z)!" text. Uses `GetScaledFont()` for accessibility.
- **`CompareSemver` utility** — new `GBL:CompareSemver(a, b)` method for numeric semver comparison (-1/0/1). Used by sync and UI for version directionality.
- **`GetHighestPeerVersion` getter** — scans active peers and returns the highest version string for update detection.

## [0.17.0] — 2026-04-14

### Added
- **Event count metadata** — `StoreBatchRecords` now persists API-observed event counts per prefix+hour as ground truth for dedup cleanup. Counts propagate via sync (max wins) and survive across sessions.
- **Count-based cleanup** — new `CleanupWithEventCounts` replaces the anchor-based heuristic for post-schema-6 data. Uses persisted event counts to correctly distinguish diverged-index duplicates (trim) from genuine repeated events (preserve).
- **Post-sync cleanup** — `FinishReceiving` runs count-based cleanup after merging synced records, preventing diverged-index duplicates from accumulating between sync cycles.
- **eventCounts in sync protocol** — SYNC_DATA chunk 1 includes event counts; receiver merges with max(). Fully backwards-compatible with older peers (nil handled gracefully, no protocol version bump).
- **eventCounts pruning** — `PruneEventCounts` mirrors `PruneSeenHashes` lifecycle (90-day default in compaction, configurable in purge).

### Changed
- **`DeduplicateRecords`** — legacy anchor-based cleanup now only runs for pre-schema-6 data. Post-schema-6 data uses the authoritative count-based cleanup.

### Fixed
- **Genuine synced records no longer deleted by cleanup** — the "diverged-index duplicate vs genuine second event" problem is resolved. Both contradictory test cases now pass: count=1 trims excess, count=2 preserves both.

## [0.16.0] — 2026-04-14

### Added
- **Changelog tab** — new tab in the addon UI (next to Sync) displaying the full version history with color-coded sections. Available to all users including those in restricted access modes. Changelog data is embedded in `UI/ChangelogView.lua` and rendered via AceGUI ScrollFrame.

## [0.15.2] — 2026-04-14

### Fixed
- **Sync re-introducing duplicates after cleanup** — after independent migrations reassign occurrence indices on each client, `IsDuplicate` fails to match records with diverged indices. Fix: `DeduplicateRecords` now runs on every login/reload (before sync starts), cleaning dirty data from any source before the session begins.

### Added
- **`DeduplicateRecords` function** — schema-independent two-pass dedup (same-slot + cross-slot) extracted from `RunCleanup`. Runs automatically on every startup; also used by `/gbl cleanup`.

## [0.15.1] — 2026-04-13

### Fixed
- **ItemCache error on uncached items** — `C_Item.RequestLoadItemData` expects an `ItemLocation` struct, not a numeric itemID. Replaced with `C_Item.RequestLoadItemDataByID(itemID)` which accepts a plain item ID. Caused a Lua error when opening the ledger UI with items not yet cached by the WoW client.

## [0.15.0] — 2026-04-13

### Added
- **Access control system** — GM (rank 0) can set a rank threshold that determines who gets full addon access. Players below the threshold are restricted to one of two modes, also configurable by the GM:
  - **Sync Only** — restricted users see only the Sync tab
  - **Own Transactions Only** — restricted users see all tabs but data is filtered to only their own transactions
- **Access control configuration UI** — GM-only section on the Sync tab with rank threshold dropdown, restriction mode dropdown, and Apply button
- **Access control sync** — settings propagate to guild members via the HELLO protocol; newer timestamps overwrite older ones
- **Restricted mode banner** — yellow label shown to restricted users explaining their access level
- **Schema migration v6→v7** — initializes the accessControl field on guild data

### Changed
- Settings row (Open with Guild Bank, Lock while scanning, Auto re-scan) now visible to all full-access users, not just a hardcoded officer rank
- Auto-open on bank visit works for all users except those in Sync Only mode (previously gated to a hardcoded officer rank)
- Tab list is now dynamic — rebuilds when access control settings change

### Fixed
- **Automatic migration now runs full dedup cleanup** — the v5→v6 migration skipped the same-slot dedup pass (v4→v5 logic) because `schemaVersion` was already 5 from v0.14.2. But the counting bug continued creating new same-slot duplicates between v0.14.2 and v0.14.3. The migration now re-runs both passes so duplicates are cleaned up on login without requiring `/gbl cleanup`.

### Removed
- `IsOfficerRank()` function and `autoOpenMaxRank` profile setting — replaced by the guild-wide access control system

## [0.14.3] — 2026-04-13

### Fixed
- **Duplicate records from seenTxHashes gaps after sync** — sync normalization (`NormalizeRecordId`) could remove an occurrence entry (e.g. `:1`) from `seenTxHashes` while moving it to a different slot, creating a gap. `CountStoredAtSlot` stopped at the gap and returned 0, causing `StoreBatchRecords` to store all records as "new" on the next bank open. Fix: initial scan now counts from the actual records array (`BuildStoredRecordIndex`) instead of `seenTxHashes`. Ground truth cannot have gaps.
- **Duplicate records from split adjacent slots** — `CountStoredForHash` returned at the first adjacent slot with matches, without checking the other side. Records split across slots 99 and 101 (from normalization) caused a query for slot 100 to only find one side, undercounting and creating duplicates. Fix: `CountFromRecordIndex` sums counts across all three slots (exact ± 1).
- **Occurrence ID collision after normalization** — new records could be assigned `:1` when `:1` was removed by normalization but `:2` still existed, causing ID collisions. Fix: `MaxOccurrenceAtSlot` scans past gaps to find the true next available index.

### Added
- **Schema migration v5→v6** — `MigrateCrossSlotDedup` removes cross-slot duplicates missed by the v4→v5 migration (which grouped by baseHash including slot). Groups by prefix (slot-independent), clusters by timestamp proximity (< 3600s), and anchors on earliest local scan. Rebuilds indices and stats.
- **`/gbl cleanup` enhanced** — now runs both same-slot (v4→v5) and cross-slot (v5→v6) dedup passes.

## [0.14.2] — 2026-04-13

### Fixed
- **Existing bug duplicates removed on upgrade** — one-time schema migration (v4→v5) identifies and removes duplicate records created by the occurrence index shift bug. Groups records by baseHash, anchors on the earliest local scan (which is always correct), and removes all excess copies. Rebuilds occurrence indices, `seenTxHashes`, and `playerStats` from surviving records. Prevents duplicate propagation via sync.

### Added
- **`/gbl cleanup` command** — manually re-runs the deduplication pass. Safety net for guild members who update late and receive stale duplicates via sync.

## [0.14.1] — 2026-04-13

### Fixed
- **Within-slot duplicate records on rescan** — v0.14.0 fixed cross-slot occurrence index shift but left the within-slot case broken: when a new identical transaction appeared in the same hour (same player, item, count, tab), WoW API's newest-first ordering caused it to steal occurrence `:0` from the existing record, creating a duplicate on every rescan. Root cause: `AssignOccurrenceIndices` assigns indices by batch position, which shifts when new records are prepended. Fix: replaced position-dependent occurrence indexing with count-based batch dedup (`StoreBatchRecords`). Compares "how many records exist per baseHash" against a session-local cache (rescans) or `seenTxHashes` (initial scan), storing only the difference. Immune to API ordering changes. Also handles hour-boundary drift via adjacent-slot probing.

## [0.14.0] — 2026-04-13

### Fixed
- **Duplicate records from occurrence index shift** — withdrawing the same item at different times caused each new withdrawal to shift the occurrence indices of all previously-stored same-prefix records, making them fail dedup on the next rescan. Example: 3 real breastplate withdrawals scanned incrementally could produce 6 records. Root cause: `AssignOccurrenceIndices` counted by prefix (without timeslot), so records in different hour slots shared a single counter. Fix: counter scope changed to per-baseHash (prefix + timeSlot), making each hour slot's counter independent. The `< 3600` timestamp check in `IsDuplicate` already prevents false-positive dedup between genuinely different events in adjacent slots.

### Changed
- **Schema migration v3→v4** — on first load, existing records are reindexed from cross-slot to per-slot occurrence indices and `seenTxHashes` is rebuilt. Existing duplicate records are preserved (indistinguishable from genuine same-hour events); future rescans will not create new duplicates.
- **Sync protocol version bumped to 4** — prevents cross-version sync between clients with old (cross-slot) and new (per-slot) occurrence schemes.

## [0.13.2] — 2026-04-13

### Fixed
- **Player name consolidation failure** — v0.13.0 migration ran before guild roster loaded, so `ResolvePlayerName` couldn't look up cross-realm players' actual realms (e.g., Katorri got assigned to local realm instead of Stormrage). Root cause: `GetGuildData()` returns nil during `OnEnable` because `GetGuildInfo("player")` isn't ready yet. Fix: migration now passes `playerRealms` directly instead of calling `GetGuildData()`, and `ResolvePlayerName` searches all guilds' caches as a fallback. Added `RepairPlayerNames()` which runs once after `GUILD_ROSTER_UPDATE` to fix records that were incorrectly resolved, rebuilds hashes, and merges duplicate playerStats.

## [0.13.1] — 2026-04-13

### Fixed
- **Outdated peers now visible in Online Peers** — peers with mismatched protocol or addon versions are tracked in the peer list instead of silently dropped. Displayed as "outdated — no sync" in red to indicate they are visible but will not participate in sync.

## [0.13.0] — 2026-04-13

### Added
- **Item name resolution for synced records** — new `ItemCache.lua` module lazily resolves item names from IDs using `GetItemInfo` + `GET_ITEM_INFO_RECEIVED`. Synced records that previously showed "Item #XXXXX" or blank item columns now display actual item names after a brief async load.
- **Guild roster cache** — persistent `playerRealms` mapping in SavedVariables tracks which realm each guild member belongs to. Updated on every `GUILD_ROSTER_UPDATE`. Survives guild departures.
- **StoreTx/StoreMoneyTx validation** — defense-in-depth: records with empty `type` or `player` are rejected at storage time, preventing corrupted records from entering the database.

### Changed
- **Player names always stored as Name-Realm** — all transaction records, playerStats keys, and summary player sets now use realm-qualified names (e.g., "Alice-Tichondrius" instead of "Alice"). Cross-realm and cross-faction guilds no longer fragment player data.
- **Sync restricted to exact version match** — peers on different addon versions are refused sync with an audit trail warning. Prevents data corruption when data formats change between versions. Protocol version bumped to 3.
- **Schema migration v2→v3** — on first load, all existing bare player names are resolved to Name-Realm format, corrupted records are removed, record IDs and seenTxHashes are rebuilt, playerStats entries are merged on collision, and daily/weekly summary player sets are normalized.

### Fixed
- **Sync chunk count off-by-one** — "send complete" log previously reported x+1/x chunks (e.g., "6/5 chunks"). The counter was incremented past the last chunk before `FinishSending()` read it. Now reports the correct count.
- **Consumption view player fragmentation** — players appearing as both "Alice" and "Alice-Realm" in the consumption view are now correctly merged into a single entry.
- **Player filter with realm names** — filter comparison now uses `StripRealm()` on both sides, so filtering works whether the user types a bare name or Name-Realm format.

## [0.12.2] — 2026-04-12

### Fixed
- **Corrupted sync records** — AceSerializer field boundary corruption during sync could produce records with mangled keys (`typyer`, `typelassID`, etc.), losing type and player fields. `reconstructSyncRecord` now validates required fields and rejects corrupted records. Migration cleanup removes 6 existing corrupted records from SavedVariables.

## [0.12.1] — 2026-04-12

### Added
- **Chat Log toggle** on Sync tab — checkbox controls whether sync progress messages are printed to chat. Defaults to off. Warnings (e.g., oversized chunks) always print regardless of this setting. All sync chat output now routed through `SyncLog()` helper.

## [0.12.0] — 2026-04-12

### Fixed
- **Cross-client false positives (~50%) for same-prefix adjacent-hour events** — `AssignOccurrenceIndices` counted per-baseHash (which includes timeSlot), so two genuinely different events with the same prefix in adjacent hours both got occurrence `:0`. When a second client's timeSlot shifted by +1 hour, the incoming record's ID exactly matched a different event on the receiver, bypassing fuzzy matching entirely. Now counts by prefix (without timeSlot) so events get sequential occurrences `:0`, `:1`, `:2` regardless of hour slot.

### Added
- One-time data migration (`MigrateOccurrenceScheme`) reassigns all existing record occurrence indices to the new prefix-based scheme and rebuilds `seenTxHashes`. Guarded by `schemaVersion` bump (1 → 2). Deterministic sort (timestamp + old ID tiebreaker) ensures identical results across clients.
- 8 new tests: prefix-based occurrence counting (3 dedup tests) + migration correctness (5 core tests). 433 total tests.

## [0.11.3] — 2026-04-12

### Added
- 20 regression tests for sync convergence fixes (v0.11.0–v0.11.2): bucket key consistency after normalization, multi-record normalization, hash cache invalidation, bidirectional convergence proof, occurrence index edge cases, reconstructSyncRecord pipeline, mixed outcomes in same bucket, NormalizeRecordId edge cases, seenTxHashes atomic update, and full end-to-end two-peer convergence cycle (425 total tests)

## [0.11.2] — 2026-04-12

### Fixed
- **Bucket hashes still mismatching after ID normalization** — `ComputeBucketHashes` grouped records by `tx.timestamp`, but two peers with the same record (same ID) could have different timestamps from scanning at different times. The record landed in different 6-hour buckets on each side, causing 4 buckets to re-sync 627 records endlessly (all duped, 0 normalized). Bucket keys are now derived from the timeSlot embedded in the record ID (which is normalized), ensuring consistent bucket placement across peers regardless of timestamp differences.

## [0.11.1] — 2026-04-12

### Fixed
- **Sync still looping after v0.11.0** — deterministic tiebreaker (smaller ID wins) left records unnormalized when the receiver's ID was smaller, since the sender never got feedback. Switched to sender-wins: receiver always adopts the sender's ID and timestamp, converging fully in one sync cycle. The sync protocol serializes direction (one side sends per cycle), preventing oscillation.
- **Bucket hash mismatch after normalization** — normalizing the record ID without also normalizing the timestamp caused the same record to land in different 6-hour buckets on each peer. The "last bucket" would re-sync endlessly. Timestamps are now normalized alongside IDs.

## [0.11.0] — 2026-04-12

### Added
- **Sync ID normalization** — when two peers have the same transaction recorded under different IDs (due to different scan times producing different timeSlots), the receiver now converges the IDs to stop the perpetual sync loop where peers with identical data kept triggering syncs on every HELLO.
- `NormalizeRecordId` method in Sync.lua with pre-built ID lookup table for O(1) record access
- `BuildTxPrefix` exposed on Dedup module for external use
- `IsDuplicate` now returns a second value (the matched seenTxHashes key) on fuzzy matches, enabling callers to detect and resolve ID divergence
- Compaction now guards against running during sync receive (`_syncReceiving` flag)
- Sync completion audit trail now reports number of IDs converged per session
- 12 new tests (405 total) covering normalization, edge cases, and hash convergence

## [0.10.2] — 2026-04-12

### Fixed
- **Sync dedup false positives** — genuinely new transactions were incorrectly rejected as duplicates when the same player performed the same action (e.g. guild repair for the same amount) in consecutive hours. The fuzzy ±1 hour dedup now checks timestamp proximity (< 3600s) to distinguish same-event re-scans from genuinely different events. Recovers missing records during sync that were previously lost to false-positive matching.

## [0.10.1] — 2026-04-12

### Fixed
- **Stale peers wiped while still online** — peers expired from the Online list after 5 minutes even when still logged in, because HELLO broadcasts only fired on discrete events (login, bank open/close) with no periodic heartbeat. Added a HELLO heartbeat timer (every 2 minutes) that keeps peers alive as long as the addon is running. Heartbeat is properly cancelled on sync disable and addon teardown.

## [0.10.0] — 2026-04-11

### Added
- **LibDeflate compression** — all sync messages are now compressed with LibDeflate before transmission, significantly reducing wire size. Chunk capacity increased from 5 to 15 records (budget from 600 to 1600 bytes pre-serialized). Audit trail shows pre/post compression sizes for SYNC_DATA chunks.

### Changed
- **Sync protocol version bumped to 2** — v0.10.0 clients are incompatible with older versions. Both sync peers must upgrade together.

## [0.9.7] — 2026-04-11

### Fixed
- **Stale peers in Online list** — peers now expire from the "Online peers" tab after 5 minutes without contact. Previously, peers accumulated for the entire session even after logging off. `GetAllPeers()` still available for diagnostics.

## [0.9.6] — 2026-04-11

### Changed
- **Bucket hash granularity** — sync fingerprint buckets now use 6-hour windows instead of daily bins, reducing the blast radius when a single new record triggers a hash mismatch. Fewer records re-sent per delta sync.

## [0.9.5] — 2026-04-11

### Fixed
- **Audit trail flooding** — per-chunk log entries (send, transmit, ACK check, ACK) were evicting the handshake/bucket-filter entries needed for diagnostics. Chunk progress now logs every 10th chunk instead of every chunk. RECV entries suppressed for ACK/NACK/SYNC_DATA. Audit trail cap raised from 50 to 200.

## [0.9.4] — 2026-04-11

### Added
- `/gbl synclog` — opens a copy-pastable editbox with the full sync audit trail for easy diagnostics

## [0.9.3] — 2026-04-11

### Fixed
- **Peer discovery after reload** — guild members are now discoverable immediately after login/reload without opening the guild bank. Previously, the initial HELLO fired 5 seconds after login when guild data was not yet available, silently aborting. Now deferred to GUILD_ROSTER_UPDATE when data is guaranteed ready
- **Known-peer reply gate** — peers that were already known (from before a reload) would not reply to new HELLOs, making the reloading player invisible. Removed the `isNewPeer` gate; all broadcast HELLOs now receive a reply
- **Broadcast debounce swallowing peers** — when multiple peers heard a HELLO, the debounce coalesced all replies into one broadcast, so the sender only discovered one peer. Replies are now sent individually via WHISPER to each sender

### Changed
- HELLO replies use targeted WHISPER instead of guild-wide broadcast, with an `isReply` flag to prevent ping-pong loops
- Hash comparison audit trail now includes bucket count for fingerprint diagnostics
- SYNC_REQUEST audit trail now includes serialized byte size for diagnosing WHISPER size issues
- sinceTimestamp fallback path (no bucket hashes) now logs explicitly instead of being silent

## [0.9.2] — 2026-04-11

### Changed
- Verbose sync audit trail: HELLO now logs remote hash/count/version, hash comparison logs both values and trigger reason (hash mismatch vs count), bucket filter logs total/matching/differing day counts with dates, received chunks break out item vs money new/duped counts, sync completion logs post-sync total tx count and updated hash

## [0.9.1] — 2026-04-11

### Fixed
- **Hash-mismatch sync gap** — peers with the same transaction count but different data now trigger bidirectional sync. Previously, sync only triggered when one peer had MORE records, so two officers who scanned different tabs at different times would never exchange data. The dataHash fingerprint correctly detected the mismatch but the sync trigger ignored it.

### Changed
- Sync decision in HandleHello now uses hash comparison as the primary trigger, with count-based comparison as backward-compatible fallback for peers without hash support

## [0.9.0] — 2026-04-11

### Added
- **Receive-side NACK retry** — when a chunk times out, the receiver requests a specific re-send via NACK instead of aborting the entire sync. Sender re-transmits from stored chunks. Retries up to 3 times per chunk before giving up
- **Zone change protection** — sync pauses during loading screens (`LOADING_SCREEN_ENABLED`/`DISABLED`) and resumes after a 5-second cooldown, preventing silent message loss during zone transitions
- **FPS-adaptive throttling** — monitors client framerate via OnUpdate; increases inter-chunk delay from 0.1s to 0.5s when FPS drops below 20, recovers when FPS exceeds 25 (hysteresis prevents oscillation)
- **ChatThrottleLib awareness** — checks `ChatThrottleLib.avail` before sending; defers chunks by 1 second when other addons are consuming bandwidth, yielding to avoid mutual message drops
- `GetSyncStatus()` now includes `zonePaused` field for UI display

### Changed
- Reduced `MAX_RECORDS_PER_CHUNK` from 15 to 5 — smaller chunks mean less data at risk per timeout
- Replaced fixed 0.1s inter-chunk delay with adaptive `GetSyncDelay()` that responds to FPS conditions
- Receive timeout now uses `RECEIVE_CHUNK_TIMEOUT` (20s) and sends NACK instead of aborting

## [0.8.0] — 2026-04-11

### Added
- **Fingerprint-based sync** — HELLO now includes a `dataHash` (XOR-aggregated djb2 of all record IDs). When both `dataHash` and `txCount` match between peers, sync is skipped entirely — zero WHISPER traffic for the common "already in sync" case
- **Bucket-filtered sync** — SYNC_REQUEST includes per-day bucket fingerprints. When datasets differ, only records from differing days are sent instead of everything, dramatically reducing transfer size for partial sync and retries after failure
- `Fingerprint.lua` module: `HashString` (djb2), `XOR32` (with pure-Lua fallback for tests), `ComputeDataHash`, `ComputeBucketHashes`, `GetDataHash` (cached)

### Changed
- `FinishReceiving` always checkpoints `lastSyncTimestamp` (previously reset to 0 when still behind, causing full re-sends). Bucket fingerprints handle the "still behind" case more precisely

## [0.7.17] — 2026-04-11

### Changed
- Reverted inter-chunk delay back to 100ms — 1s delay reduced throughput without improving reliability

## [0.7.15] — 2026-04-11

### Changed
- Reduced CHUNK_BYTE_BUDGET from 1400 to 600 — produces ~3 records per chunk (~800 bytes) to improve AceComm WHISPER reliability in cross-realm guilds

## [0.7.14] — 2026-04-11

### Fixed
- Crash syncing records from older/newer addon versions with missing fields: `reconstructSyncRecord` now guarantees `id`, `timestamp`, `scanTime`, `scannedBy` are always non-nil regardless of what the sender provides — computes missing `id` from record fields, recovers `timestamp` from id or falls back to current time, and `MarkSeen` guards against nil hash

## [0.7.13] — 2026-04-10

### Fixed
- Cross-realm sync failures: replaced `Ambiguate` with realm-stripping `baseName()` for peer identity matching in HandleAck and HandleSyncData — Ambiguate is context-dependent (behaves differently per client's realm), causing silent ACK rejection in cross-realm guilds where GUILD and WHISPER channels may format sender names differently

### Added
- Diagnostic audit entries: "RECV" logs raw channel + sender for all incoming messages, "ACK check" logs raw sender vs target before comparison — aids cross-realm debugging

## [0.7.12] — 2026-04-10

### Fixed
- Sync chunks could exceed WHISPER ~2000-byte limit and be silently dropped — PrepareChunks now uses estimated serialized size (1400-byte budget) instead of fixed record count, preventing ACK timeout loops on oversized chunks
- Money transactions now stripped via stripForSync before sync sending — previously sent raw with scanTime/scannedBy fields, wasting payload bytes and leaking mutable references

### Changed
- CHUNK_SIZE (10) replaced with MAX_RECORDS_PER_CHUNK (15) as a hard cap alongside new size-based splitting — typical chunks will be 7–9 records based on estimated byte size

## [0.7.11] — 2026-04-10

### Fixed
- Sync request could stall permanently if sender never responded — `receiving` stayed true with no timeout, blocking all future syncs. Now aborts after 30s with a chat message.

### Added
- Chat print when sync request is declined (sender already busy)
- Chat print per chunk on the send side (record count + byte size)
- Chat print for oversized chunk warnings (red text)
- Chat print for hard timeout (AceComm never finished transmitting)
- Audit trail entry when HELLO decides not to sync (with reason: counts equal, already receiving, or autoSync off)

## [0.7.10] — 2026-04-10

### Added
- Chat output for all sync events: request, chunk progress (new/duped counts), retries, timeouts, completion summary with elapsed time
- ACK receipt logging in audit trail
- Dedup breakdown per chunk (new vs duplicate record counts)
- Sync completion summary: total new, total duped, chunks received, elapsed seconds

## [0.7.9] — 2026-04-10

### Fixed
- Crash when syncing records from older addon versions that lack a `timestamp` field (`attempt to compare nil with number` in UpdatePlayerStats)
- Sync receiver now recovers missing `timestamp` from the id's timeSlot when receiving old-format records

## [0.7.8] — 2026-04-10

### Changed
- Sync chunk size increased from 3 to 10 records per chunk — ~3x faster sync throughput with fewer round-trips
- Sync payloads now strip 6 additional reconstructable fields (category, tabName, destTabName, scanTime, scannedBy, _occurrence) — smaller messages, more records fit per chunk
- Received sync records automatically reconstruct stripped fields (category from classID, occurrence from id, scanTime set to receipt time)

## [0.7.7] — 2026-04-10

### Fixed
- Sync data chunks too large for reliable WHISPER delivery — reduced from 25 to 3 transactions per chunk (~900 bytes vs ~6400 bytes), preventing silent AceComm reassembly failures
- Single dropped chunk no longer kills entire sync — ACK timeouts now retry the same chunk up to 3 times before aborting
- HandleAck timer cancellation still using `.cancelled = true` instead of `:Cancel()` (missed in v0.7.6 timer fix pass)

## [0.7.6] — 2026-04-10

### Fixed
- Sync timers never firing in WoW — `C_Timer.After` returns nil so timeouts could not be tracked or cancelled; switched all sync timers to `C_Timer.NewTicker(..., 1)` which returns a cancellable handle
- Timer cancellation using `.cancelled = true` (only worked in tests, not WoW API); replaced with `:Cancel()` method calls
- Manual "Broadcast Hello" button now bypasses the 60s cooldown

### Added
- Audit trail entry when receiving a HELLO from a peer (e.g. "Received HELLO from Katorri (tx: 556)")
- Diagnostic audit entries for chunk send lifecycle: bytes queued, transmission complete, and ACK wait

## [0.7.5] — 2026-04-10

### Fixed
- Peer discovery failure: new-peer HELLO reply was silently blocked by the 60s cooldown, preventing mutual peer detection until one side independently triggered a broadcast (e.g. closing the guild bank)
- HELLO cooldown consumed even when broadcast fails due to missing guild data at login — subsequent retries blocked for 60s

### Added
- HELLO broadcast on guild bank open for immediate peer discovery
- Debounced new-peer HELLO replies bypass the cooldown; multiple new peers discovered within 2s coalesce into a single reply (prevents HELLO flood in large guilds)

## [0.7.4] — 2026-04-10

### Added
- HELLO response: receiving a HELLO from a new peer now triggers a HELLO back so both sides discover each other (previously required both players to independently trigger a broadcast)
- Version indicator in Sync tab peer list — peers on a different version show "(outdated)" in orange

## [0.7.3] — 2026-04-10

### Fixed
- Sync data rejected by receiver due to name format mismatch between GUILD and WHISPER channels — HELLO arrives with "PlayerName" but SYNC_DATA arrives with "PlayerName-RealmName"; now uses `Ambiguate` on all sender comparisons in HandleSyncData and HandleAck
- Updated sync comments and UI strings from "officers" to "guild members" (sync is guild-wide, officer rank only gates UI)

## [0.7.2] — 2026-04-10

### Fixed
- Column text wrapping to new lines on all tabs — disabled word wrap on all fixed-width Label and InteractiveLabel cells (headers, data rows, summary panel, breakdown rows)

## [0.7.1] — 2026-04-10

### Fixed
- Sync ACK timeout — timer started immediately on message queue instead of after AceComm finished transmitting; large chunks exceeded the 10s timeout before the receiver even got the data
- Self-message filtering broken in retail WoW — realm-qualified sender names (e.g. "Player-Realm") never matched `UnitName("player")` output; now uses `Ambiguate`

### Changed
- Sync chunk size reduced from 200 to 25 transactions per message to fit within AceComm bandwidth constraints
- ACK timeout increased from 10s to 15s to allow for receiver dedup + round-trip
- `itemLink` stripped from sync payload (reconstructable from `itemID`) to reduce message size by ~30%
- Added 120s hard timeout safety net in case AceComm send callback never fires

## [0.7.0] — 2026-04-08

### Added
- Gold summary panel on Gold Log tab with per-type breakdown (deposits, withdrawals, repairs, tab purchases, net) rendered to the right of transaction columns with vertical divider
- Date range filters: added Last Hour, Last 3 Hours, Last 24 Hours to all tabs
- Pagination for Transactions tab (100 rows per page)

### Fixed
- Re-scan no longer resets selected date range and filters — `RefreshUI` now uses per-tab refresh functions that preserve filter state
- Runtime crash: `attempt to register unknown event "GUILD_BANK_LOG_UPDATE"` — corrected to `GUILDBANKLOG_UPDATE` (WoW uses `GUILDBANK` as a single token in event names)

## [0.6.2] — 2026-04-07

### Fixed
- Re-scan not detecting new transactions (withdrawals, deposits) while guild bank remains open — restored event-driven `GUILDBANKLOG_UPDATE` listener so reads happen after server responds, not after an arbitrary delay

## [0.6.1] — 2026-04-07

### Fixed
- Periodic re-scan not functioning in-game due to unreliable `C_Timer.After` return value tracking and event-driven overhead
- Re-scan chain silently breaking on Lua errors (now protected with pcall)

### Changed
- Reduced default re-scan interval from 5s to 3s (effective ~3.5s cycles, within 2-4s target)
- Simplified re-scan to use fixed 0.5s delay instead of event-driven debounce with 2s fallback
- Re-scan state tracked via boolean flag instead of timer handle (works across all WoW versions)

## [0.6.0] — 2026-04-07

### Added
- Periodic re-scan of all transaction logs while guild bank is open (every 5 seconds)
- Catches item and money transactions before they roll off the 25-entry-per-tab WoW API limit
- Auto-starts after initial scan completes, stops on bank close
- "Auto re-scan" toggle in settings row
- Re-scan status shown in `/gbl status` output

## [0.5.0] — 2026-04-07

**Milestone M5: Multi-Officer Sync**

### Added
- Multi-officer transaction sync via AceComm addon channel (prefix `GBLSync`)
- HELLO broadcast on login and bank close — announces version, tx count, and last scan time to guild
- Automatic sync: when a peer's HELLO shows more transactions, requests delta sync with chunked transfer (200 tx/chunk with ACK flow)
- Sync tab in main UI with enable/disable toggle, auto-sync toggle, and Broadcast Hello button
- Peer list showing online officers with version, tx count, and last seen time
- Sync audit trail (last 50 events) displayed in the Sync tab
- Sync progress messages (`GBL_SYNC_STARTED`, `GBL_SYNC_PROGRESS`, `GBL_SYNC_COMPLETE`) for UI updates
- ACK timeout (10s) — aborts stalled transfers, retries on next HELLO
- Receive timeout (30s) — resets stuck receive state if sender goes offline mid-sync
- Major version mismatch detection — warns in audit log and refuses sync across incompatible versions
- HELLO cooldown (60s) prevents broadcast flooding
- Wrong-sender guard — rejects SYNC_DATA from a third party during an active receive session
- 68 new tests (241 total) covering HELLO, sync request/response, chunking, dedup, dispatch, audit trail, and edge cases

### Changed
- Core addon now mixes in `AceComm-3.0` and `AceSerializer-3.0`
- Bank close now broadcasts HELLO to notify peers of fresh scan data
- Delta sync filters by `scanTime` (when record was created) instead of `timestamp` (when event happened) — ensures recently-scanned old transactions are not missed

## [0.4.1] — 2026-04-07

### Fixed
- Gold/money transactions now appear in the Transactions tab (were previously only visible in Consumption)
- Added "Amount" column to ledger view showing formatted gold amounts for money transactions
- Money transaction types (Repair, Tab Purchase, Deposit Summary) now appear in the Type filter dropdown
- Player stats now correctly track repair, buyTab, and depositSummary money types (were silently dropped)
- Money transactions no longer show misleading "0" in Count column or blank Item/Category/Location fields
- Transaction scan now uses debounced GUILDBANKLOG_UPDATE handler (0.5s after last event) so money tab data arrives before reading — previous next-frame read was too fast and missed money log responses
- Money log now queried at `MAX_GUILDBANK_TABS+1` (constant 9), not `GetNumGuildBankTabs()+1` — guilds with <8 tabs were querying the wrong tab index, so money data was never loaded from the server
- WoW API returns `"withdrawal"` for money transactions but code checked for `"withdraw"` — added normalization in CreateMoneyTxRecord so all downstream code matches correctly

### Changed
- Ledger "Action" column widened to 80px to fit "Tab Purchase" label; "Item" narrowed to 180px to accommodate new Amount column

## [0.4.0] — 2026-04-07

**Milestone M4: Consumption Detail + UI Polish**

### Added
- Click-to-expand player rows in consumption tab — click a player to see per-item breakdown with item name, category, withdrawn/deposited counts
- Sortable column headers on consumption tab (Player, Withdrawn, Deposited, Net, Last Active) with [asc]/[desc] indicators
- Category filter dropdown on consumption tab (reuses existing filter pipeline)
- Top Item column showing the #1 most active item name (extracted from item link)
- `ExtractItemName()` utility for extracting display names from WoW item links
- `GetBreakdownForDisplay()` transforms raw breakdown data into sorted display arrays with category labels
- `FormatTopItems()` formats top items as truncated comma-separated names
- 21 new tests (173 total) covering breakdown display, sort state, indicators, category filtering, item name extraction, edge cases

### Changed
- Ledger view column widths tightened to fit 720px usable frame (645px total: 130+90+70+200+40+80+35)
- Consumption tab filter bar now includes date range, category dropdown, and reset button (was date-only)

### Fixed
- Guild bank open no longer stutters — transaction scanning and compaction deferred via `C_Timer.After(0)` so the bank frame renders first

## [0.3.3] — 2026-04-07

### Fixed
- Sort direction indicators showed as boxes (UTF-8 unsupported by WoW font); changed to [asc]/[desc] text

### Added
- Revised roadmap (`docs/ROADMAP.md`) with sync moved to M5 and audit checklists per milestone

## [0.3.2] — 2026-04-07

### Fixed
- UI rows overflowed frame — ledger and consumption views now use AceGUI ScrollFrame for scrollable content
- LibDBIcon-1.0 `.toc` path pointed to nonexistent `lib.xml`; corrected to `LibDBIcon-1.0.lua`
- Interface version updated from 110105 to 120001 (WoW Midnight Season 1)

## [0.3.1] — 2026-04-07

### Fixed
- `fetch-libs.sh` pointed to nonexistent GitHub repos under `BigWigsMods/`; corrected to `WoWUIDev/Ace3`, `lua-wow/LibStub`, `zerosnake0/LibDBIcon-1.0`
- AceConfigDialog-3.0 and AceConfigCmd-3.0 are nested inside AceConfig-3.0 in the Ace3 repo; script now copies them correctly

### Removed
- LibSharedMedia-3.0 from `.toc` load list (no standalone GitHub repo; addon doesn't use it yet)

## [0.3.0] — 2026-04-07

**Milestone M3: UI**

### Added
- Main UI window toggled via `/gbl` or minimap button (left-click)
- Transaction ledger view with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar: text search, date range (7d/30d/all), category, transaction type, reset button
- Per-player consumption summary with net contribution, top items, last active
- Minimap button via LibDataBroker + LibDBIcon
- Accessibility: 4 colorblind-safe palettes auto-detected from WoW CVar, high contrast mode (WCAG AAA)
- Triple encoding for transaction types: shape icon + color + text label (WCAG 1.4.1)
- Keyboard navigation (Tab/Shift+Tab) with visible 2px yellow focus indicator, focus trap (WCAG 2.1.1, 2.4.7)
- Font size scaling (8-24pt) via addon settings
- Frame position clamping to screen bounds
- Library fetch script (`fetch-libs.sh`) for development setup
- 78 new tests (152 total) covering accessibility, filters, consumption, keyboard nav

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.6] — 2026-04-07

### Added
- Keyboard navigation: Tab/Shift+Tab focus traversal with wrap (focus trap per WCAG 2.1.1)
- Focus indicator: 2px yellow border tracked on each focusable widget (WCAG 2.4.7)
- Focus restore on frame reopen
- Frame position clamping to screen bounds
- 9 new keyboard nav and frame clamping tests (152 total)

## [0.2.5] — 2026-04-07

### Added
- Main UI window (`UI/UI.lua`) with tabbed view: Transactions and Consumption
- Scrolling transaction list (`UI/LedgerView.lua`) with sortable columns (Timestamp, Player, Action, Item, Count, Category, Tab)
- Filter bar widgets: search box, date range, category, type dropdowns, reset button
- Consumption table with per-player summaries, net contribution, last active
- Minimap button via LibDataBroker + LibDBIcon (left-click toggles window)
- `.toc` updated with all M3 library and UI file entries
- 4 new integration tests (143 total)

### Changed
- `/gbl` (no args) now opens the UI window instead of showing help
- `/gbl show` added as alias for toggling the UI
- Help moved to `/gbl help` only

## [0.2.4] — 2026-04-07

### Added
- Per-player consumption aggregation (`UI/ConsumptionView.lua`): withdrawal/deposit totals, net contribution, money tracking, top items, last active timestamp
- Sortable consumption summaries by any column (player, withdrawn, deposited, net, last active)
- Per-player item breakdown with withdrawn/deposited per item
- Money formatting utility (`FormatMoney`: copper to "Xg Ys Zc")
- 18 new consumption tests (139 total)

## [0.2.3] — 2026-04-07

### Added
- Transaction filter logic (`UI/FilterBar.lua`) with AND-combined criteria: text search, date range (7d/30d/all), category, transaction type, player, tab
- AceGUI-3.0 mock framework for UI unit testing
- LibDataBroker-1.1 and LibDBIcon-1.0 mocks
- 19 new filter tests (121 total)

## [0.2.2] — 2026-04-06

### Added
- Accessibility module (`UI/Accessibility.lua`) with WCAG 2.1 AA-adapted design
- 4 colorblind-safe palettes: normal, protanopia, deuteranopia, tritanopia (auto-detected from WoW CVar)
- High-contrast palette variants (WCAG AAA 7:1+ contrast)
- Triple encoding for transaction types: shape icon + color + text label (WCAG 1.4.1)
- Font scaling utilities with 8-24pt clamping
- Timestamp formatting from profile settings
- 28 new accessibility tests (102 total)

## [0.2.1] — 2026-04-06

### Added
- Library fetch script (`fetch-libs.sh`) for local development setup — downloads Ace3 and supporting libraries from GitHub
- `.pkgmeta` externals for M3 libraries: AceGUI-3.0, AceConfig-3.0, AceConfigDialog-3.0, AceConfigCmd-3.0, LibDBIcon-1.0, LibDataBroker-1.1, LibSharedMedia-3.0

## [0.2.0] — 2026-04-06

**Milestone M2: Ledger + Dedup + Categories + Storage**

### Added
- Transaction recording from guild bank logs via `GetGuildBankTransaction` API
- Item categorization by WoW classID/subclassID (flasks, herbs, ore, gems, weapons, armor, and 30+ categories)
- Hour-bucket deduplication engine with 3-slot adjacent check for multi-officer drift tolerance
- Money transaction tracking (deposits, withdrawals, repairs, tab purchases)
- Per-player statistics: deposit/withdrawal counts, money totals, first/last seen timestamps
- Tiered storage compaction: full records (0-30d), daily summaries (30-90d), weekly summaries (90d+)
- Automatic compaction on bank open with scan-in-progress guard
- Storage statistics and size estimation
- Data purge command for manual cleanup
- 50 new unit tests (73 total) covering Ledger, Dedup, Categories, and Storage modules

## [0.1.0] — 2026-04-06

**Milestone M1: Scaffold + Scanner**

### Added
- AceAddon bootstrap with OnInitialize/OnEnable/OnDisable lifecycle
- Guild bank open/close detection via `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`
- Slot-level guild bank scanning across all viewable tabs
- Chained tab scanning with configurable delay via `C_Timer.After`
- Slash commands: `/gbl status`, `/gbl scan`, `/gbl help`
- AceDB saved variables with profile support
- Full test infrastructure with WoW API and Ace3 mocks
- 20 unit tests covering Core and Scanner modules
- Project scaffolding: .toc, .pkgmeta, .luacheckrc, .busted, LICENSE (MIT)
