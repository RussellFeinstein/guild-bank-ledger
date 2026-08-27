------------------------------------------------------------------------
-- GuildBankLedger — UI/ChangelogView.lua
-- Changelog tab: embedded version history and in-game renderer.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Section rendering order and colors
------------------------------------------------------------------------

local SECTION_ORDER = { "Added", "Changed", "Fixed", "Removed", "Deprecated", "Security" }

local CHANGELOG_PAGE_SIZE = 10

local SECTION_COLORS = {
    Added      = "|cff55ff55",
    Changed    = "|cff55bbff",
    Fixed      = "|cffffaa55",
    Removed    = "|cffff5555",
    Deprecated = "|cff999999",
    Security   = "|cffcc66ff",
}

------------------------------------------------------------------------
-- Changelog data — newest first, concise summaries only.
-- Format: { version, date, { SectionType = { entries } }, milestone? }
------------------------------------------------------------------------

GBL.CHANGELOG_DATA = {
    -- v0.38.1
    {"0.38.1", "2026-08-27", {
        Fixed = {
            "Sorting a full or nearly full overflow tab no longer shuffles for minutes and then stops with moves still outstanding. When a tab held many identical full stacks of the same item, the sort was picking which stack went in which slot by where each one currently sat, and moving them changed that. Every pass re-aimed the next one, so the work never shrank the way it should, and the sort gave up part-done rather than finishing. Stacks that are interchangeable now stay where they are, so a pass only ever does what is left.",
        },
    }},

    -- v0.38.0
    {"0.38.0", "2026-08-26", {
        Added = {
            "A bank layout can now declare more than one overflow tab. Stock fills overflow tabs in tab order by default, and an optional per-tab routing priority (lower fills first) overrides that order. At least one overflow tab is still required. The Layout editor gains a Routing priority field and a fill-order readout on overflow tabs, and the sort preview lists every overflow tab in fill order.",
        },
    }},

    -- v0.37.18
    {"0.37.18", "2026-08-25", {
        Added = {
            "A test now bans the os and io standard libraries from shipped code. WoW's sandbox provides neither, but the test suite runs where both exist, which is how the crash below stayed invisible to a green suite for five months.",
        },
        Fixed = {
            "Members whose guild rank cannot see any bank tab no longer hit a script error after opening the guild bank. The error lived on a dead code path and quietly stopped duplicate cleanup and the periodic re-scan from starting for exactly those members.",
        },
        Removed = {
            "The tiered storage layer. It was meant to fold records older than 30 days into daily summaries and older than 90 days into weekly ones, and it never ran once: its entry point lost a race with the bank scan on every bank open. It is also incompatible with sync (a member who compacted would look far behind to everyone else, who would push the old records straight back), and keeping every transaction in full is the intended design. Nothing about what the addon shows or stores day to day changes.",
        },
    }},

    -- v0.37.17
    {"0.37.17", "2026-08-22", {
        Fixed = {
            "Members with a lot of history can hand over their records again. This is the second half of the fix started in v0.37.14, and the part that finishes it. Answering a guildmate's request meant reading through the whole stored history in one go, and on a large history the game could cut that work short with a script error before a single record went out. Because it failed at the same point every time, the guildmate's retry failed the same way, so the member was not a slow source of records but a permanently silent one, with nothing in either player's log to say so. The work is now spread across frames, a slice at a time, so it finishes no matter how much history is stored and the game stays responsive while it happens. Small histories are unaffected: they still complete instantly, exactly as before.",
            "Cancelling a sync now also stops the preparation behind it. Entering combat, changing zones, being told a guildmate is busy, or switching sync off could each leave the preparation running invisibly, and it would go on to finish and record that it had handed over records it never sent. The next sync then skipped those records as already delivered. A loading screen was the worst case, writing a completed transfer into the log for a sync that never sent anything.",
        },
        Changed = {
            "The sync log now records what preparing a sync actually did: how much history was examined, how much was selected to send, and how long it took. This is what a capture needs to confirm the fix above is working on a real client rather than only in tests.",
            "A guildmate who turns down a request because they are still preparing one now says so, rather than reporting it the same way as a transfer already in progress. Preparing takes under a second and a transfer takes minutes, so the two mean very different things to whoever is waiting.",
        },
    }},

    -- v0.37.16
    {"0.37.16", "2026-08-21", {
        Changed = {
            "A sync log now records one line per exchange with a guildmate saying what it decided and why, instead of several lines that each said part of it. The decisions that explain a member who never catches up were only visible with debug logging turned on beforehand, so a capture sent in after the fact could never contain them. They are in the ordinary log now, and the log is shorter than it was.",
            "When a guildmate turns down a sync request, the reply now says why: they are already sending to someone else (and to whom), or they are in combat. Turning one down used to be silent about the cause, and the three possible causes call for completely different responses.",
            "Reading a guildmate's HELLO no longer re-measures your whole stored history to print a diagnostic number. On a large history during a busy moment that was real work being done for a line in a log, and it happened for every ping from every member.",
        },
    }},

    -- v0.37.15
    {"0.37.15", "2026-08-21", {
        Fixed = {
            "Your client no longer hands over its records while you are in combat. Answering that request means reading through everything the addon has stored, and on a large history that is enough work in one go that the game can cut it short with a script error, which is what happened to a member in the middle of a raid. Requests that arrive during a fight, or in the moments just after one or after a loading screen, are now turned down with a note saying to try again shortly. The guildmate asking retries on their own a little later, so nothing is lost apart from the wait.",
        },
    }},

    -- v0.37.14
    {"0.37.14", "2026-08-21", {
        Fixed = {
            "Members with a lot of history are less likely to stall when a guildmate asks them for records. Answering that request made the addon re-measure the whole stored history several times in a row, and on a large history during a busy moment such as a raid, the game could cut the work short with a script error before any records were sent. The measurement is now reused instead of repeated. This is the first half of the fix; the remaining work to spread the job over several frames is still to come.",
        },
    }},

    -- v0.37.13
    {"0.37.13", "2026-08-21", {
        Changed = {
            "Internal cleanup, with no change to how the addon behaves. Two of the messages the addon sends while syncing, the one carrying bank records and the one saying it is busy, were each assembled in two separate places in the code. A later change could have been made to one copy and not the other, and because a receiving client simply reads whatever fields it finds, the two would have disagreed about what to send without anything reporting an error. Each message is now built in one place.",
        },
    }},

    -- v0.37.12
    {"0.37.12", "2026-08-18", {
        Changed = {
            "The sync log now reports compression the same way in every line. While a sync was sending, each chunk line said how much the data had shrunk, while the summary at the end of the send said how much of the original size was left, so one chunk could read as 31 percent in one line and 69 percent in the other. Both now report the compressed size as a percentage of the size before compression.",
        },
    }},

    -- v0.37.11
    {"0.37.11", "2026-08-14", {
        Fixed = {
            "Members with a long history can ask for records again. The message your client sends to ask a guildmate what it is missing carried one entry for every six-hour window the guild had ever recorded, so it grew a little every day, and past a certain size it stopped arriving reliably. After that the member kept waiting for records that were never coming, while the guildmate on the other end saw no request at all and had nothing to act on. The request now describes recent activity in full and summarizes older history, so it stays the same small size whether the guild has a month of records or several years of them. Members who have not taken this update still sync with it normally in both directions.",
            "A request that goes missing is now asked again. If nothing comes back at all, your client repeats the request up to three times before giving up, rather than asking the guildmate to resend a batch of records it never started sending. Guildmates also stop treating a repeated request as a reason to say they are busy, which used to cancel the very transfer that was underway.",
        },
        Added = {
            "The sync log now records messages that arrive damaged. A sync message travels in pieces, and losing one in transit could leave the addon holding an unreadable fragment that it discarded without a word, so a member could look like they had gone quiet when they were talking the whole time. Those are now written to the sync log along with how many bytes made it, which is what /gbl synclog needs to tell a bad connection apart from an idle one.",
        },
    }},

    -- v0.37.10
    {"0.37.10", "2026-08-14", {
        Changed = {
            "Your client now asks a guildmate for their records the moment it decides to, instead of waiting up to a second first. The wait was there to stop several people answering the same broadcast at once, but the addon already handles that by telling the extra askers to try again shortly. The delay could also quietly abandon a sync it had just decided to start, with nothing written to the log to say so, which made stalled members hard to diagnose. Syncs that get skipped for a reason now say which reason in the sync log.",
        },
    }},

    -- v0.37.9
    {"0.37.9", "2026-08-13", {
        Fixed = {
            "Vertical bars now show up where they are meant to. WoW treats a single bar as the start of a formatting code, so text using one as a separator could lose it, and sometimes the letter after it. This affected the peer status tags on the Sync tab, the sending and receiving status line, the separators in the Consumption and Gold summaries, several /gbl command help lines that show you the options you can type, and a handful of entries in this changelog.",
        },
    }},

    -- v0.37.8
    {"0.37.8", "2026-08-13", {
        Fixed = {
            "Text the addon puts on screen no longer relies on characters WoW's fonts may not have. Dashes, arrows, multiplication signs and tick marks were drawing as blanks or boxes for some players depending on their font and locale, so a sort progress line could read 'Executing 4 / 9' with a hole where the dash belonged, and a Layout tab row that matched the template showed a green mark that was not there at all, leaving colour as the only signal. All of it is plain text now, including this changelog.",
        },
    }},

    -- v0.37.7
    {"0.37.7", "2026-08-13", {
        Changed = {
            "A sync session now hands over a bounded slice and stops, instead of running until everything one member is missing has been transferred. A member catching up on months of history used to hold a partner for hours, and anything that interrupted that (combat, a loading screen, a disconnect) threw the session away and started it over. A session now carries roughly 300 records, tells the receiver how much is still waiting, and ends. The receiver asks again and picks up where it left off, so a backfill finishes across a series of short sessions and both members are back in the pool for other partners within minutes. Members who have not taken this update sync with it normally.",
        },
    }},

    -- v0.37.6
    {"0.37.6", "2026-08-13", {
        Changed = {
            "Members now share notes with whoever is available instead of waiting for a preferred partner. Every member used to broadcast a summary of what it held every five minutes, keep a picture of everyone else's, and score that picture to decide who to sync with next. Sync spreads through the guild the way gossip does, so it arrives regardless of the order it travels in, and the bookkeeping was buying an ordering that does not matter. A member that finishes syncing now simply becomes available and answers the next member who says they have something new. Nothing about what gets synced changes, and this update syncs normally with members who have not taken it yet.",
        },
        Removed = {
            "The five-minute guild-wide summary broadcast, and the queue that scored which member to sync with next.",
        },
    }},

    -- v0.37.5
    {"0.37.5", "2026-08-13", {
        Changed = {
            "The ledger window no longer opens by itself when you open the guild bank. Most members never need it there, and it landed on top of the bank frame every time. Tick 'Open with Guild Bank' in Settings to get the old behaviour back, or open it any time with /gbl. Note that anyone who had never changed this setting is now on the new default; anyone who had already turned it off is unaffected.",
        },
    }},

    -- v0.37.4
    {"0.37.4", "2026-08-13", {
        Fixed = {
            "The Sync tab no longer tells you a peer is syncing when it is refusing them. A peer running a version too old to sync with was only marked as such while their messages were arriving; after a reload the mark was gone, and a peer who stayed quiet (sitting in a dungeon, where addon messages do not reach the guild) was shown as an older peer syncing normally. The tab now works the status out from the version the peer advertises, so it reads correctly whether or not they have said anything this session.",
            "Peers remembered from a previous session kept their version but lost the compatibility range that goes with it, so until they spoke again they were treated as though they predated the sync floor. That made the addon refuse a peer it can sync with, and label them as too old in the peer list.",
        },
        Changed = {
            "Peer status tags read 'too old || sync refused', 'newer || update to sync', 'newer || update available' and 'older || syncing'. A peer running a development build is now named as such instead of being reported as too old.",
        },
    }},

    -- v0.37.3
    {"0.37.3", "2026-08-13", {
        Fixed = {
            "Sync chunks are sized by what the whole message weighs, not by the records alone. Each chunk was meant to fit a single 255-byte packet, and none of them ever did: the per-item event counts that ride along with the records and the message header were both attached after the size check, and together they outweighed the records they travelled with. Every chunk was going out as three packets instead of one, and losing any one of the three meant sending the whole thing again, which is why a long catch-up sync could spend hours retrying and still not finish. Chunks now carry fewer records each and arrive in one piece.",
        },
        Changed = {
            "Sync gives up on a lost chunk faster and retries more times before abandoning a peer. Waiting eight seconds to notice a dropped chunk made sense when chunks were large; measured replies come back in about half a second, so most of that wait was dead time. The wait is now three seconds with eleven attempts instead of six, which keeps roughly the same overall patience for someone on a slow loading screen while wasting far less time on each lost packet.",
            "The sync summary reports how long peers took to acknowledge each chunk, and counts any chunk that went out larger than a single packet. Both are there to catch the sizing above going wrong on a route it was not measured on.",
        },
    }},

    -- v0.37.2
    {"0.37.2", "2026-08-10", {
        Changed = {
            "Compatible peers on an older version no longer show their Sync tab status in grey. Grey reads as 'unable to sync' when that tag means syncing is working, and it matched the genuinely inactive states (the roster-only 'online (no HELLO)' text, the dev-build rows). The 'older, syncing' note now renders in the normal text colour; warning colours still mark only peers that actually cannot sync.",
        },
    }},

    -- v0.37.1
    {"0.37.1", "2026-08-10", {
        Fixed = {
            "The 'Hide moves' filter no longer hides the Location column along with the move rows. Hiding moves is the default, so most users never saw the column at all, including the bank tab that deposits and withdrawals started recording in v0.37.0. The column now stays visible whatever the filters: it shows the tab for every transaction recorded from v0.37.0 on and stays blank for older rows, which never recorded one.",
        },
    }},

    -- v0.37.0
    {"0.37.0", "2026-08-10", {
        Changed = {
            "This is the last release that requires your whole guild to update together. Until now the addon refused to sync with anyone on a different version, down to the patch number, so every release split the guild into groups that could not share data until everyone updated. From here on, clients sync across versions as long as both are on 0.37.0 or later. That will only break again if the stored record format itself has to change, which is rare and deliberate.",
            "The Sync tab tells the three cases apart. A peer on a different but compatible version reads 'older, syncing' in grey rather than being flagged, a newer peer still shows 'update available', and only a peer we genuinely cannot sync with is coloured as a problem.",
        },
        Fixed = {
            "Deposits and withdrawals now record which bank tab they happened in. Only moves ever did, so the tab column was blank for most rows and per-tab history was unanswerable. One-time side effect: whatever is still in the guild bank log when you update (about 25 entries per tab) gets recorded a second time, because those entries are now filed under a different identity. Expect a handful of doubled rows right after updating. It stops on its own once the bank log rolls over.",
            "Records arriving over sync are checked before being stored. Roughly one in nine records ever received had a field name garbled in transit, and the addon accepted them. Records damaged in the common way are now repaired from the item ID instead of being lost, and anything still malformed is refused.",
            "Refused records are counted and reported as refusals rather than as duplicates, which previously made a peer sending nothing but corrupt data look exactly like a peer whose data already matched yours.",
        },
    }},

    -- v0.36.1
    {"0.36.1", "2026-08-10", {
        Changed = {
            "Nothing in this release changes how the addon behaves. It adds tests that check the sync message format against the real compression and serialization libraries instead of a test stand-in, so the next release can change that format without silently breaking older clients. Worth updating only so your version matches the rest of your guild.",
        },
    }},

    -- v0.36.0
    {"0.36.0", "2026-07-02", {
        Added = {
            "Diagnostic logs now persist across reloads, saved to a separate saved variable so you can hand troubleshooting data to the developer after the fact instead of copying chat mid-session. Capped per channel and rotated (10 sessions kept). Nothing is ever sent anywhere; sharing a capture stays a manual step. Manage with /gbl audit on||off||status||clear.",
            "Sync bandwidth stalls are measured in detail: each stall logs a 'CTL recovered' summary and the end-of-send stats line adds overlapped-timer and longest-stall counts. A sync that gives up while bandwidth is still starved records that last stall too, on its own 'CTL still starved at send end' line, so the longest-stall figure counts the stall that ended the sync rather than reporting zero for it. Measurement only; these numbers decide the shape of the stall fix.",
        },
        Changed = {
            "The bank layout serve line in the sync log records at INFO instead of DEBUG, so the payload size shows up in normal diagnostics.",
        },
        Fixed = {
            "README described sync chunking as 15 records per chunk; the shipped values since 0.28.7 are 4 records in a 900-byte budget.",
        },
    }},

    -- v0.35.0
    {"0.35.0", "2026-06-24", {
        Added = {
            "A per-item 'Keep' field on each Layout editor row. It sets the total to keep in stock, and Restock buys up to whichever is larger: the layout total or the Keep amount. Use it to keep a deeper reserve than the tab layout alone needs (a key flask, say). Keep at 0 leaves the layout total as the target.",
            "A 'Keep' field in the Layout editor's 'Apply to all' bulk row, so you can set the reserve for every item on a tab in one click (next to bulk Slots and Per slot). Setting it to 0 clears the reserves on that tab.",
        },
        Changed = {
            "The Restock tab now shows a two-state stock status per item: 'Buy N' below the target, 'In stock' at or above it (the separate 'Over N' state is gone). Each row's counts read 'target N || bank M' instead of '(target N, bank M)'.",
            "Simplified the About tab labels: the Ko-fi and CurseForge copy boxes now read just 'Ko-fi' and 'CurseForge', and the license line reads 'MIT License'.",
        },
        Removed = {
            "The crafted-quality crash mitigation on the Sort tab: both the warning banner and the pre-warm step that added up to a 3-second delay before every sort. Recent sorts over crafted-quality reagents no longer hit the crash, so sorts now start right away.",
        },
    }},

    -- v0.34.2
    {"0.34.2", "2026-06-23", {
        Fixed = {
            "The main window now closes when you press Escape. Previously Escape only worked when 'Open with Guild Bank' had auto-opened it; a window opened manually with /gbl or the minimap could only be closed with the Close button.",
        },
    }},

    -- v0.34.1
    {"0.34.1", "2026-06-23", {
        Added = {
            "The About tab now credits Katorri with creating the Restock feature, which is based on the Guild Bank Restock addon.",
        },
        Fixed = {
            "The About tab, the Changelog page controls, and the window version label no longer use a two-argument font call that WoW 12.0.7 rejects (the same issue that blanked the Restock tab before its 0.34.0 fix).",
        },
    }},

    -- v0.34.0
    {"0.34.0", "2026-06-23", {
        Added = {
            "A Restock tab (and /gbl restock) that helps officers refill the guild bank to its layout targets. It lists every layout item grouped by bank tab with its target, current stock, and how many are short. Visible to members with sort access.",
            "Auction House buying through the optional Auctionator addon. With Auctionator installed and its Shopping tab open, Restock prices the shortfall and buys it, one item at a time or as a Buy-all sweep. Buying spends real gold; Restock refuses purchases you cannot afford and supports a per-run gold budget cap.",
        },
    }},

    -- v0.33.0
    {"0.33.0", "2026-06-17", {
        Added = {
            "A diagnostic command, /gbl epoch0, that lists stored transactions stuck in the epoch-0 (1969-12-31) time bucket and reports how many there are, whether their timestamps are valid, and which guildmate supplied each one. An investigation aid for the issue where a few stale records keep showing up as differing during sync even when both sides already hold them.",
        },
        Fixed = {
            "Closed one more path where a guildmate behind a client whose data had stopped changing could stall. The v0.32.12 fix re-pinged a behind peer when it contacted us; the check that runs right after we finish sending to a peer was still skipping silently in the same situation, so it now sends the same throttled re-ping (at most once a minute per peer).",
        },
    }},

    -- v0.32.12
    {"0.32.12", "2026-06-09", {
        Added = {
            "Sync debug logging to diagnose guildmates who never catch up to a client that is ahead of them. With sync debug on, the log now shows when a discovery ping is held back because your data has not changed, so a silent stall is visible in a capture. Turn it on with /gbl logs debug sync on, then view it with /gbl synclog.",
        },
        Changed = {
            "Sync sends the most recent transactions first when catching a guildmate up. An interrupted catch-up now still delivers current activity instead of working through old history first, and what ends up stored is unchanged since records are matched by identity.",
        },
        Fixed = {
            "Guildmates who had fallen behind a client whose data had stopped changing now get caught up instead of stalling. The addon only pinged a peer when its own data changed, so once a caught-up client went idle it stopped telling a behind peer it had more, and the behind peer never asked. The ahead client now re-pings a behind peer (at most once a minute) so the catch-up starts even when nothing new is happening.",
        },
    }},

    -- v0.32.11
    {"0.32.11", "2026-06-09", {
        Added = {
            "The bank layout now syncs to guildmates who have sort access, so granting an officer sort access actually gives their Sort tab something to work with. The Guild Master's layout and stock reserve counts travel with the addon's normal guild sync. Only the layout's timestamp rides the regular guild ping; the full layout transfers privately and only to members who can sort, so it stays off the wire for everyone else. A dropped transfer is re-fetched on the next ping until both clients match.",
        },
        Changed = {
            "The Layout tab's 'Layout-write access: GM' line now also shows who else has been granted layout-write access (the rank threshold and delegate count), so you can see the policy you configured at a glance instead of only your own access.",
        },
    }},

    -- v0.32.10
    {"0.32.10", "2026-06-04", {
        Changed = {
            "The Sort tab is now hidden from guild members without sort access, and the Layout tab is hidden from anyone without layout-write access (sort-only users no longer see a Layout tab they cannot edit). Previously the Sort tab was shown to everyone even though only authorized members could use it.",
        },
        Fixed = {
            "Sort access grants now reach the officers they are given to. The Guild Master's sort-access policy (rank threshold and delegate list) was stored only on the GM's own client and never shared, so granting another officer access had no effect on their game. The policy now travels with the addon's normal guild sync, and a grant takes effect on the granted player's client without a reload.",
            "The Sort and Layout tabs now appear as soon as your access is granted or your guild rank loads, without a reload. They were previously re-evaluated only when the window was first opened or when an access-control change synced in.",
        },
    }},

    -- v0.32.9
    {"0.32.9", "2026-05-22", {
        Changed = {
            "Sort engine replaced with a fire-and-forget pump. Each move fires once per second with no per-move confirmation wait, then at the end of a pass the bank is re-scanned and re-planned; if any moves remain, another pass runs automatically (up to 5 passes). In-game runs that used to take roughly 632 seconds for 184 moves should run closer to 190 seconds in one pass.",
            "Sort runs are now self-healing if the client's frame loop wedges mid-run. A stall watchdog re-kicks the pump after about six seconds of no progress so the run resumes when the loop catches up, instead of needing the bank closed and the sort restarted.",
            "Sort automatically throttles the periodic transaction-log re-scan for its duration so it does not slow the pump. While the sort runs, the addon flushes the transaction log every fifteen moves instead of every three seconds, so every move is still captured to the ledger but the re-scan does not hitch the pump. Your re-scan setting is restored when the sort ends.",
            "The sort log buffer now holds 3000 entries (was 1000) so a full large sort run stays in the open sort log view without dropping its start.",
        },
        Removed = {
            "The per-move confirmation machinery: the interim polling cascade at 0.25, 0.5, 1.0, and 2.0 seconds, the cross-tab re-queries at 1.5 and 3.0 seconds, the 4-second confirmation timeout, the 3-strike consecutive-refusal abort, and the related timeout classification. These were the old engine's way of knowing each move had landed before issuing the next; the new pump does not wait for confirmation, so they are gone along with the per-move confirm tag and the Sort confirm histogram summary line.",
        },
    }},

    -- v0.32.8
    {"0.32.8", "2026-05-20", {
        Changed = {
            "Sort timeout summary format expanded. The single-line execution audit now reads timeout[s=N,p=N,c=N,m=N,dp=N,o=N] drifts=N where s is server-rejected (the bucket previously labeled n/none), p is partial, c is complete, m is the new merge-noop bucket, dp is drain-pending, o is residual other, and drifts counts timeouts where the planner's emit-time projection diverged from live observed values. The new merge-noop bucket captures the singleton-chain refusal pattern that previously hid inside 'other'.",
            "Sort timeout audit no longer prints the planner-projected line on every timeout. It now prints only when the planner's projection actually diverges from the live observed values, formatted as '(planner projected: src ..., dst ...)'. Healthy timeouts get one fewer noise line in the log.",
        },
        Fixed = {
            "Sort now aborts with a specific reason after three consecutive server refusals on the same item rather than compounding into a chain of refused moves until the replan cap aborts. The new abort fires before the executor advances past the third refused op, ending the run with a reason like 'repeated server refusal on item N (3 consecutive merge-noop)'. Failing early means the user can see which item is stuck without scrolling the whole sort log.",
            "Sort now confirms each op via an interim polling cascade at 0.25, 0.5, 1.0, and 2.0 seconds after the Pickup pair rather than always waiting for the 4.0-second late-poll backstop. In-game captures showed every op confirming via the 4.0-second floor even when the server processed in well under a second, dominating wall-clock sort time. Successful interim advances use a slightly longer 0.5-second inter-move cushion than the default 0.3 to give the server breathing room after the faster confirmation.",
            "Sort no longer carries a per-item refusal counter across a replan. Previously two refusals followed by foreign-activity replan followed by one refusal on the same item would falsely trip the 3-strike abort even though the plan structure between strikes 2 and 3 had changed.",
            "Sort timeout classification now reads the live slot contents directly instead of matching against the formatted audit text. In-game that text carries the resolved item name, so the old prefix match never fired: every real timeout fell into the residual 'other' bucket, leaving the merge-noop bucket and its 3-strike abort dead outside the test environment. The buckets and the early abort now work against real bank data.",
            "Sort no longer aborts a sort that is actually working. A guild-bank split deposits into the destination before the client reflects the source-stack decrement, so within the 4-second confirmation window the source still looks full and the op read as a merge-noop refusal. Three in a row aborted a sort that was placing items correctly. A split whose destination was empty (or held a different item) before the op and now holds the expected item is classified drain-pending (shown in the timeout summary as dp=N) and excluded from the 3-strike abort, so the sort runs to completion.",
            "Sort's 3-strike abort is narrowed to genuine refusals only. A slow deposit can leave the destination still empty at the 4-second check (classified server-rejected) even though the deposit is simply in flight, and that previously counted toward the abort. The abort now counts only a move or merge into a slot that already held the same item (a real max-stack bounce); any op into an empty or different-item slot is treated as an in-flight deposit. A planner mistake like merging two full max-stack stacks still aborts as it should.",
            "Sort confirms a split or move into an empty (or different-item) slot as soon as the destination holds the item, instead of waiting for the source-stack count to drain. In-game the deposit lands in about 0.6 seconds while the source-drain can lag past the 4-second confirmation window, so the old rule spent the full window on every such op. The common case now confirms in about a second, roughly 4x faster end to end. A merge into a slot that already holds the same item still requires the source to drain, because there the destination alone cannot tell a real merge from an optimistic bounce.",
            "Sort keeps the destination tab's slot data fresh during each op so a cross-tab deposit confirms inside its own confirmation window instead of one op later. WoW pushes slot updates only for the currently-viewed guild bank tab, so a deposit into a tab you were not viewing landed on the server but stayed invisible to the addon until the next op happened to re-pull that tab, surfacing as a false refusal and a roughly 5-second stall on every cross-tab op. The executor now re-queries the destination tab in the background while the op is in flight (it does not change the tab you are viewing), and the resulting slots-changed event confirms the deposit. A stray refresh event whose slots still match the just-completed op's projected state is treated as the executor's own echo rather than another player's activity, so it no longer triggers a needless replan.",
        },
        Added = {
            "Sort planner Phase 2 cycle resolution now emits debug audit lines describing what the planner saw: which slot is cycle-blocked and what item blocks it, which pivot slot was chosen, or whether the cycle aborted with no pivot available. Lines route through GBL:SortDebug so they only land in the sort log buffer when db.profile.sort.debugChat is on. The greedy emit loop also logs the failing predicate (src-shortfall, dst-mismatch, or max-stack-overflow) on any refused canExecute. Emissions cap at 20 per plan to avoid flooding the debug channel on degenerate inputs.",
            "Bank scans now log a per-tab summary line (for example Scan: T1=80(event) T5=0(timeout,locked=5) (498 total)) showing each tab's occupied-slot count, whether its data arrived from the server event or the query-timeout fallback, and how many slots were skipped because they were locked. A display tab that reads empty via the timeout path while it actually holds items is the fingerprint of a stale scan feeding a phantom sort plan.",
            "The sort plan summary line now ends with a per-tab occupied-slot breakdown (for example [T1:80 T5:0 T6:120]), so a cold tab is visible in /gbl sortlog without opening the master log. Comparing a cold pre-sort plan's breakdown to the warm post-sort plan's breakdown shows exactly which tab gained the slots the stale snapshot missed.",
            "Sort audit records deposit-confirmation latency. Each no-op-suspected line stamps the elapsed time since the op was issued, and an op whose deposit has not landed by the 4-second timeout is watched for up to 20 seconds with a line noting when the deposit actually lands (or that it did not). This measures how long guild-bank deposits take to confirm so the per-op confirmation timing can be tuned from real data.",
            "Sort audit lines record the currently-viewed guild bank tab (shown as viewed=TN) on each op's done and timeout lines and on the deposit-observer lines. This tests whether deposits into a tab the client is not actively viewing explain the slow first-deposits into a freshly-filled tab.",
        },
    }},

    -- v0.32.7
    {"0.32.7", "2026-05-20", {
        Fixed = {
            "Closing the guild bank after running a sort once in a session now performs the normal close cleanup again: the periodic rescan stops, the auto-opened ledger window closes, and the next sync broadcast goes out. Previously the sort's bank-close handler permanently replaced the core one for the rest of the session.",
        },
    }},

    -- v0.32.6
    {"0.32.6", "2026-05-20", {
        Fixed = {
            "Sort no longer risks a duplicate move or a client crash when another guild member changes the bank during the brief pre-warm step at the start of a sort. A bank update arriving in that window could make the sort move an item before its data finished loading, then move it again once pre-warm finished. The sort now ignores bank updates during pre-warm and never issues a second move while one is still in flight.",
        },
    }},

    -- v0.32.5
    {"0.32.5", "2026-05-20", {
        Fixed = {
            "Sort pre-warms item data for every unique item link in the plan before issuing the first PickupGuildBankItem. Mitigates a Wow.exe crash inside Blizzard's SetItemCraftingQualityOverlay that fired during the tab redraw after sort moves on tabs containing TWW crafted-quality reagents (Flawless gems and similar). The pre-warm uses Item:CreateFromItemLink:ContinueOnItemLoad with a 3.0s cap and lands an audit line in the sort log before the first op.",
        },
        Added = {
            "Warning banner in the Sort tab preview. When the plan touches any slot whose live item link carries the TWW crafted-quality atlas marker, a color-coded banner renders above the move list explaining that pre-warm is a best-effort mitigation against a Blizzard-side crash. Recurring crashes during similar sorts are a signal to organize those items manually first.",
        },
    }},

    -- v0.32.4
    {"0.32.4", "2026-05-13", {
        Added = {
            "Window position and size now persist across reloads. Dragging or resizing the ledger window automatically saves the position and dimensions; they are restored on the next login or /reload.",
            "Minimum window size enforced (810x500) to prevent the tab bar and filter row from becoming unusable when the window is resized too small.",
        },
        Fixed = {
            "Scroll area now correctly fills the full available height after the window is resized. Previously the scroll container height was only calculated at tab-build time and was not updated when the window was made taller.",
        },
    }},

    -- v0.32.3
    {"0.32.3", "2026-05-12", {
        Fixed = {
            "ChatFilters: NPC chat event handlers now exit immediately when inside any instance (party, raid, M+, pvp, arena, scenario). Blizzard marks NPC sender values as 'secret' in instanced content, causing a Lua crash when the name was used as a table key. The filter has no purpose in instances - the guild bank doesn't exist there. The sender guard was also tightened from a nil-check to type() == 'string' so any non-string value is safely rejected before the table lookup.",
        },
    }},

    -- v0.32.2
    {"0.32.2", "2026-05-11", {
        Changed = {
            "Documentation honest-status sweep across the CurseForge description, README, and ROADMAP. The blanket 'stable and in active guild use' framing is replaced with a three-tier model (mature / active / under audit). Forward plans split into Pre-1.0 readiness gates and Post-1.0 features. Stock is two slots: passive Stock tab in v1.4.0, toggleable Stock alerts in v1.5.0. Analytics added to Post-1.0 v1.1.0 with the full six-section scope. ROADMAP Shipped section updated to v0.1.0-v0.32.1 with sort+layout, logging, and peer-canonicalization milestones called out.",
            "Softened the 'Full keyboard navigation (Tab/Shift+Tab)' claim in the CurseForge description and README. The supporting functions in UI/Accessibility.lua have existed since v0.3.0 but the wiring across widgets does not exist. Completing the wiring is now codified as a v1.0 release gate in ROADMAP Pre-1.0 readiness.",
        },
        Added = {
            "Project CLAUDE.md Design Principles section pinning accessibility-first as a blocking design requirement. Every new UI feature must list its keyboard-navigation path, focus indicators, color-encoding fallbacks, font-scaling behavior, and screen-reader hooks during the design phase, with end-to-end verification before any user-facing doc claims the feature works.",
        },
    }},

    -- v0.32.1
    {"0.32.1", "2026-05-09", {
        Changed = {
            "Reorganized addon source files into the src/ subfolder. Internal-only change with no user-visible behavior. The 14 production .lua modules (Core, Logger, Scanner, Categories, ChatFilters, Dedup, Ledger, Storage, Fingerprint, ItemCache, Sync, BankLayout, SortPlanner, SortExecutor) now live under src/; UI/, Libs/, spec/, scripts/, and docs/ are unchanged. Build, test, and CI surfaces (.toc, spec/helpers.lua, .busted, ci.yml, pre-push hook) updated to match.",
        },
    }},

    -- v0.32.0
    {"0.32.0", "2026-05-08", {
        Added = {
            "New Logger module owns the session log and exposes per-channel writers on GBL: SyncInfo / SyncWarn / SyncError / SyncDebug, plus matching Sort* and System* families. Lower-level GBL:LogSync(level, fmt, ...) covers runtime-computed levels. Severity is one of DEBUG / INFO / WARN / ERROR. printf-style formatting goes through pcall(string.format) so a bad format string falls back to the literal pattern instead of crashing.",
            "/gbl sortlog opens a copy-pastable pop-up of the sort-channel session log.",
            "/gbl logs opens the master log: sync, sort, and system channels merged in timestamp order with [CHANNEL] [LEVEL] prefixes.",
            "/gbl logs dump [N] prints the last N master entries to chat (default 50).",
            "/gbl logs clear sync||sort||system||all truncates a channel.",
            "/gbl logs debug sync||sort||system on||off toggles per-channel DEBUG-to-chat mirroring.",
            "Open Sort Log button on the Sort tab and Open Master Log button on the Sync tab, alongside the existing Open Sync Log button. All three open the same AceGUI MultiLineEditBox pop-up the slash commands use.",
        },
        Changed = {
            "Sync and Sort diagnostics moved to separate ring buffers (sync cap 2000, sort cap 1000, system cap 500). Reading the sync log no longer requires mentally filtering out per-op sort lines, and vice versa. Per-channel chat mirroring is gated by db.profile.<channel>.chatLog (INFO/WARN/ERROR) and debugChat (DEBUG). DEBUG entries drop entirely when debugChat is off, preserving the prior chatOnly=true 'do not pollute the buffer with per-chunk noise' property without a separate side channel.",
            "GBL:AddAuditEntry(msg, chatOnly?) is now a deprecated shim that routes plain calls to SyncInfo and chatOnly=true to SyncDebug. GBL:GetAuditTrail() is a permanent alias for GetLog('sync') that also exposes the legacy entry.timestamp field for older readers.",
            "Sync tab no longer carries an always-visible audit panel. Logs are a diagnostic artifact, not live UI furniture; they surface only on demand via the slash commands or the new buttons. Removes the constant re-render of the Sync-tab log panel that nobody was actively reading.",
            "Sync diagnostics that were already WARN- or ERROR-shaped are now tagged at the right severity (version mismatch, oversized chunks, ACK timeout retries / aborts, hard timeout, receive timeout, NACK-limit aborts, sender-offline aborts). Sort diagnostics are similarly tagged: phantom-success suspicions, pre-check failures, server reversions, cursor-stuck failures, and timeouts surface as WARN; success / lifecycle / replan / reclassification surface as INFO.",
        },
    }},

    -- v0.31.1
    {"0.31.1", "2026-05-05", {
        Fixed = {
            "Layout editor's Add item input is reachable again on captured display tabs. The row was sitting at the bottom of the per-tab scroll content (below the item rows and slot map) where AceGUI's trailing-widget scroll bug clipped it from the wheel-scrollable area, so users couldn't add new items by hand once a tab had been captured. Moved the row up to sit just below Capture / Unpin All, alongside the other write controls. Same widgets, same callback, same layout-write gate. Second instance of the v0.30.4 save-bar workaround pattern; the underlying AceGUI bug is unchanged.",
            "Sort tab scroll now reaches the bottom of the window on tall plans. The ScrollFrame was missing the bottom-right anchor that Transactions / Gold Log / Consumption already use, so AceGUI's default Flow-layout height stopped the scroll short of the window edge and hid the tail of long move lists.",
        },
        Changed = {
            "Sort tab Plan summary, live progress label, and Moves heading are now pinned above the scroll instead of scrolling away with the move list. The op rows, Deficits, and Unplaced sections continue to scroll. The running 'op N / M' counter stays visible during long sorts.",
        },
    }},

    -- v0.31.0
    {"0.31.0", "2026-05-05", {
        Added = {
            "Optional filter to mute Silvermoon Citizen ambient chatter near the guild bank. Off by default. Toggle lives on a new personal-preferences row at the top of the ledger window, visible to all access levels. Hides both the chat-frame line and the world speech bubble. Chat-frame side suppresses CHAT_MSG_MONSTER_SAY/_YELL/_EMOTE; bubble side listens for SAY/YELL via AceEvent, queues the stripped message text, and a 50ms ticker walks C_ChatBubbles.GetAllChatBubbles() to hide bubbles whose FontString text matches (exact, with substring fallback for engine-side wrapping). Bubbles are hidden via SetAlpha(0) plus Hide on the bubble frame and its visible regions, plus reparenting to a hidden frame, since plain Hide is sometimes re-shown by the engine. Muted-name set is data-driven so a future addition is a one-line code change. enUS-only by virtue of the localized sender name.",
            "/gbl bubbletest slash command dumps whether C_ChatBubbles is available, the current toggle state, the queued suppression set, and every active bubble's FontString text with a [MATCH] annotation when it would be suppressed. Useful for diagnosing cases where chat is muted but a bubble survives.",
        },
    }},

    -- v0.30.6
    {"0.30.6", "2026-05-05", {
        Added = {
            "Dev-build sync isolation. A new DEV_BUILD constant in Core.lua, when set to a string on a dev branch, flips the wire version to X.Y.Z-dev.<id> so an isolated dev install cannot exchange records with production peers. The existing exact-match rejection at Sync.lua HandleHello refuses sync in both directions and writes a single '(version mismatch; this build is v...)' audit line; the -dev.<id> substring in the printed version is the disambiguator. The UI surfaces the dev state via a [DEV] suffix in the main window title, a one-line login chat notification, an orange 'Dev build (vX.Y.Z) -- sync isolated' banner at the top of the Sync tab when local is dev, and a greyed-out Online Peers list when local is dev (the banner above explains why none are reachable). A CI workflow step rejects any PR where DEV_BUILD is non-nil; the local test runner is intentionally unguarded so dev iteration keeps working.",
        },
        Changed = {
            "GBL:CompareSemver strips an optional pre-release suffix (e.g. -dev.<id>) before parsing so dev builds compare as the same release line as their base for the ahead/behind UI labeling. The wire-side equality check at Sync.lua HandleHello is unaffected.",
        },
    }},

    -- v0.30.5
    {"0.30.5", "2026-05-05", {
        Fixed = {
            "Sync peer list no longer shows the same player as multiple realm-tagged entries. The sync layer previously used Ambiguate(name, 'none') at sixteen sites intending to strip the realm suffix from incoming sender names, but in retail WoW that context returns the name unchanged. When AceComm delivered the same peer's messages with different qualifications ('Rexxybear' vs 'Rexxybear-Tichondrius') each variant became a separate peer key, bloating the Online Peers list and the persisted knownPeers store. All sixteen sites now route through a new GBL:CanonicalPeerKey helper. The own-message ignore at the top of OnSyncMessage is also fixed (it previously failed in retail because the realm-qualified sender never compared equal to UnitName('player'), so the addon was processing its own broadcasts as if from a stranger).",
            "Connected-realm guilds now correctly distinguish same-name members across realms. Empirical in-game testing showed that retail's Ambiguate(name, 'guild') strips realm for ALL guildmates of a connected-realm group, not just same-realm. An intermediate development build that delegated to Ambiguate('guild') would have collided two distinct Alices across connected realms in one guild into a single peer key. The shipped CanonicalPeerKey uses custom local-realm-only logic via a new _isLocalRealm helper so cross-realm distinguishability is preserved. IsGuildMemberOnline also routes both the parameter and each roster fullName through CanonicalPeerKey for correct disambiguation.",
            "Player records stored with raw spaced realm strings vs the normalized form that the addon's own fallback path produces. BuildRosterCache and the v2-to-v3 migration captured realm portions raw ('Aerie Peak'), while ResolvePlayerName's local-realm fallback always produced 'AeriePeak'. The asymmetry let the same player surface as two different record.player values across the dedup boundary on realms with spaces in their name. A new GBL:NormalizeRealm helper plus a schema 9-to-10 migration MigrateNormalizeStoredRealms rewrites stored realms in place. The local-realm fallback is also centralized in a new GBL:GetLocalRealm helper so producer and consumer share identical logic.",
            "Schema-11 migration MigrateRecoverPeerRealms no longer prematurely bumps schemaVersion when the roster API is cold. Previously, when GetLocalRealm() was valid but GetNumGuildMembers() returned 0 the migration walked an empty roster, recovered nothing, and still bumped to schema 11; affected users got stuck at 11 with the recovery never having actually run. Fix: return 0 without bumping when numMembers == 0 so the migration retries on a later session or via the GUILD_ROSTER_UPDATE retrigger.",
            "Hyphen-corrupted playerRealms entries from a long-fixed code path now self-heal. Affected entries (a realm string containing a hyphen, like 'Stormrage-Stormrage-Stormrage...') persisted in saved variables for offline peers because BuildRosterCache only writes for currently-rostered members. New RepairCorruptedPlayerRealms helper trims them at OnEnable and on every GUILD_ROSTER_UPDATE. CanonicalPeerKey defensively rejects hyphen-bearing realms as a belt-and-suspenders measure.",
            "ResolvePlayerName no longer falls back through other guilds' playerRealms. The previous implementation iterated self.db.global.guilds as a last resort, which could resolve a bank-log name to a realm from a guild the user no longer belongs to. New priority: explicit playerRealms arg, current guild's playerRealms, local realm fallback. Migrations pass per-guild tables explicitly so they remain correct.",
            "Schema migration ladder skip-chain (Codex P1). Later migrations had loose '>= target' gates that would let the ladder bump straight from schema 8 to 10 or 11 if MigrateNormalizePeerNames short-circuited on cold realm APIs, permanently skipping the 8 -> 9 work. Now strict-gated on schemaVersion == prev_target so the chain stays in order.",
            "Stale record.id after realm rewrite (Codex P1). MigrateNormalizeStoredRealms previously mutated record.player without rebuilding record.id (which ComputeTxHash derives from the player field) or seenTxHashes. Sync would re-import the same transaction under its new id and dedup wouldn't catch it. Fixed by recomputing the id inline after a rewrite and rebuilding seenTxHashes once at the end.",
            "Schema-11 recovery realm normalization (Codex P2 follow-up). MigrateRecoverPeerRealms was building its bare-name to realm lookup from GetGuildRosterInfo without normalizing the realm portion. GetGuildRosterInfo can return raw spaced realm names ('Aerie Peak') for cross-realm guildmates depending on the realm topology. The unnormalized realm then flowed into CanonicalPeerKey at the rewrite site, which preserved the cross-realm form as-is. Result: recovered keys like 'Alice-Aerie Peak' while every other call site of CanonicalPeerKey produced 'Alice-AeriePeak', silently splitting the same peer across two keys after the recovery migration. Affected users on multi-word realms (Aerie Peak, Burning Blade, Argent Dawn, etc.). Fix: normalize realm once before storing in the lookup.",
            "InitSync seed loop syncState.peers writes are now recency-checked (Codex P3 follow-up). The seed loop wrote to syncState.peers[clean] unconditionally per pairs() iteration. When knownPeers contains both legacy bare and canonical qualified forms of the same peer, both raw keys canonicalize to the same clean key, and pairs() iteration order is undefined, so an older snapshot could nondeterministically overwrite a newer one in the runtime cache. The knownPeers consolidation already had a recency check; the syncState.peers write did not. Fix: wrap the runtime write in the same recency check.",
        },
        Added = {
            "Schema-11 migration MigrateRecoverPeerRealms is a best-effort recovery pass for users who ran an intermediate development build that unconditionally stripped realm from peer keys. Walks bare keys in knownPeers and syncState.peers, consults the live guild roster, and re-realms keys whose bare name appears at exactly one realm. Multi-realm name collisions and offline / departed peers stay bare.",
            "Migration ladder retrigger on first warm GUILD_ROSTER_UPDATE so migrations that short-circuit on cold realm APIs at OnEnable get a warm retry without waiting for the next login.",
            "BuildRosterCache now tracks bare-name ambiguity. When a bare name maps to multiple distinct realms in the roster, playerRealms[bareName] is set to false (sentinel). CanonicalPeerKey rejects the sentinel and keeps ambiguous bare arrivals bare rather than guessing the wrong realm.",
            "ConsolidatePeerKeys runtime sweep on GUILD_ROSTER_UPDATE re-canonicalizes syncState.peers and knownPeers so any peer-state staleness from earlier in the session (or from prior sessions whose canonicalization differed) sweeps to current canonical form. Idempotent.",
            "InitSync seed loop consolidation. Each persisted knownPeers key runs through CanonicalPeerKey at session start; if the canonical form differs, both knownPeers and the runtime syncState.peers consolidate by recency. Self-heals stuck saved variables on next /reload.",
        },
    }},

    -- v0.30.4
    {"0.30.4", "2026-04-28", {
        Added = {
            "Bulk-apply slots / per-slot to every item on a display tab. A new 'Set all items to:' row in the Layout tab editor lets you set every item on a tab to a common shape in one action: fill in Slots and/or Per slot, click Apply to all, and every existing item on that tab gets the new values. Useful for tabs where every item should match (e.g. set every gem on the gems tab to '5 slots x 1 per slot' instead of editing each row by hand). Leave a field blank to keep its current value for each item. Shrinking slots trims that item's pinned positions from the highest slot down. Edits buffer in the draft until Save Layout.",
            "ItemCache now caches itemStackCount alongside name and link, with a new GBL:GetMaxStack(itemID) accessor used by the sort planner.",
            "Sort planner now writes a single timing line to the audit trail (visible in /gbl synclog) for every plan: Sort plan: 12.3ms, 47 ops, 0 deficits, 1 unplaced (input: 240 slots / 4 tabs). Captures both first-plan and replan latency on the same code path. Motivation: large plans and their replans cause a single-frame hitch in-game; this line gives the ms-per-input-size data needed to decide whether the planner needs to be split across frames.",
            "Per-phase sort instrumentation. /gbl synclog now also shows a phases line breaking each plan's ops down by phase (P0 merge, P1a assign, P1b spill with topup/extend/first-empty/unplaced split, P2 pivot, P3 sweep, P4 pack) and a demands line counting demand origins (pinned, extend-right, extend-left, first-empty). The same counters are exposed on the returned plan as plan.diag. Empty no-op plans stay quiet. SortExecutor also writes a one-line completion summary at every run end with elapsed time, ops/done/failed/replans/reclassify counts, pre-check fails, cursor-stuck count, and per-class timeout counts.",
            "Planner-vs-reality diagnostic on every op. Each emitted op now carries a frozen snapshot of what the planner thought the src/dst slots held when it emitted that op. When a pre-check fails or an op times out, the audit trail now adds a 'planner expected' line that pairs with the 'observed' / 'got' line, so a recurring 'dst occupied by wrong item' across replans now self-explains: either the snapshot read this slot wrong or an earlier op didn't do what the planner projected.",
            "Per-op success timeline in the audit. Every op the executor advances past now writes a one-liner with src/dst, item name and id, count, and elapsed time, tagged [sync] or [late-poll] depending on which success path resolved it. Combined with the existing pre-check-fail and timeout entries, /gbl synclog now serves as a complete per-op timeline of any sort run.",
            "Items-only layouts now show natural adjacency in the demands line. Pass 2b (the slot fallback that handles items-only layouts) labels each demand based on adjacency to existing same-item claims, so what previously looked like 437 unrelated 'first-empty' fallback adds now surfaces as one seed per item plus extend-right for the contiguous extension (the structure already in the layout but invisible before this change).",
            "Item-name resolution in the audit log. Plain it:NNN tokens are now rendered as <name> (it:NNN) wherever the cache has the item, in pre-check-fail, timeout, op-success, and slot-state lines. Cold-cache items still fall back to bare it:NNN; the helper deliberately does not warm the cache so audit emission paths cannot trigger async loads.",
            "Server-reversion detection. The per-op-success audit line now ends with src=<post> dst=<post> showing the client's view of both slots right after the op. When a foreign-activity event fires (the second GUILDBANKBAGSLOTS_CHANGED, which is the server's authoritative response), the executor compares live state to the projected post-op state and audits a 'server reversion suspected on op N' line if they diverge. This is the diagnostic that distinguishes 'the [sync] path advanced on the client's optimistic view of a Pickup that the server later rolled back' from genuine concurrent foreign bank activity.",
        },
        Changed = {
            "Layout tab now uses nested tabs. The previous monolithic vertical scroll (eight bank-tab sections stacked above a Sort Access section) is replaced with an inner tab strip: one inner tab per bank tab (Tab 1..Tab 8) plus a final Sort Access tab. Editing one bank tab at a time keeps slot maps and item lists short, and Sort Access policy gets its own focused screen. The active inner tab persists across rebuilds so edits do not bounce the view back to Tab 1. Save and Discard sit at the top of each bank-tab inner tab and operate on the full draft (changes across all bank tabs save together). Each inner tab keeps its own scroll position, so switching back to a tab returns the user to where they were. Mouse-wheel scrolling works inside every inner tab.",
            "Sort: the planner now actively compacts the stock (overflow) tab at every stage, not just at the end. A new Phase 0 pre-merges same-item partials in overflow before any cross-tab routing happens, and Phase 1B prefers to top up existing same-item partial slots before extending into a new slot. The combined effect: a run that previously ended as two stacks of 160 Healing Potions (max 200) now ends as 200 then 20, AND a stock tab that was previously reported 'out of space' because partial stacks consumed slots is now correctly seen as having room. Repeat sorts remain no-ops. Items whose max stack size has not yet loaded into the client cache (cold cache after /reload) skip the merge for that item only and fall back to grouping; a second sort completes the work once the data arrives.",
        },
        Fixed = {
            "Sort planner now refuses to emit ops that would over-stack same-item slots beyond their per-item max stack. Previously Phase 4 packing could cascade an op chain that built up x400 of an item with maxStack 200 in the planner's working state, look fine on paper, then fail at the server which refused the merge. The guard lives in canExecute and applyOpToState and is per-item, so items whose stack size hasn't loaded into the cache yet keep the existing cold-cache fallback (no guard, may need a follow-up sort).",
            "Sort executor no longer reports success on no-op moves. The WoW client optimistically updates bank slots when you call Pickup, so when the destination already holds the same item at max stack a real no-op (drop refused, cursor returns to source) looks identical to a successful move from the dst+cursor predicates alone. Each advance path (sync, async event, late-poll, late-ACK reclassify) now also verifies that src actually drained as expected: for move ops src must be empty or hold a different item; for split ops src.count must have decreased by at least op.count. When the predicate fails, the audit logs a 'no-op suspected' line naming the op and the executor falls through to the timeout-poll path which records it as a real failure and triggers replan rather than advancing past a phantom success.",
        },
    }},

    -- v0.30.3
    {"0.30.3", "2026-04-27", {
        Changed = {
            "Repository workflow change with no addon behavior impact: auto branch deletion on merge is disabled, and recurring maintainer work now lives on long-lived per-area topic branches (ui, sync, accessibility, layout-sort). Short-lived chore/, infra/, and hotfix/ branches still cover one-off and cross-cutting changes. Documented in the CLAUDE.md Branch Workflow section.",
        },
    }},

    -- v0.30.2
    {"0.30.2", "2026-04-27", {
        Added = {
            "Sync audit trail now records when a SYNC_DATA chunk arrives at chunk N>1 while no receive session is active - that means the receiver missed an earlier abort signal (combat with a lost BUSY, or a sender desync) and is recovering data mid-stream. Look for 'Auto-bootstrap at chunk N from <sender>' in /gbl synclog.",
            "Sync ACK timeout retry log now appends 'target=online||offline||unknown' so future capture analysis can tell apart 'peer was already offline and we kept retrying' from 'peer was nominally online but timed out anyway' (likely true wire loss or in-instance silent abort). 'unknown' covers both 'not in roster' and 'roster not yet populated' - the latter only happens for a few seconds right after login.",
        },
    }},

    -- v0.30.1
    {"0.30.1", "2026-04-25", {
        Changed = {
            "Internal refactor with no behavior change: a new GBL:SafeRecordTimestamp helper replaces ten copies of the same 'use record.timestamp if valid, else GetServerTime' ternary across the migration paths in Core.lua and the sender-wins reconciliation in Sync.lua. Also re-enables the 120-character line-length lint on Core.lua, since the long lines that originally forced an override are gone.",
        },
    }},

    -- v0.30.0
    {"0.30.0", "2026-04-24", {
        Added = {
            "Sort Access now has two independent tiers. The Layout tab's Sort Access section is split into Layout Write access (edit templates, capture, pin slots, change stock reserves - inherently includes sort) and Sort-only access (press Execute on the Sort tab but cannot edit the layout). Each tier has its own rank threshold and its own delegate list. Only the Guild Master can change the policy. Grant sort execution widely while keeping layout edits locked down.",
            "Defense-in-depth gate at the storage API. SaveBankLayout and SetStockReserve now reject any caller that does not pass HasLayoutWrite(), in addition to the existing UI callback check.",
        },
        Changed = {
            "Existing sortAccess configurations migrate into the new Layout Write tier on upgrade, so no one silently loses a permission. The sort-only tier starts empty; populate it in the Layout tab if you want to grant sort without layout write.",
        },
    }},

    -- v0.29.26
    {"0.29.26", "2026-04-24", {
        Fixed = {
            "Sort progress counter no longer shows impossible values like '34/33' after a replan. The old display used (done+failed)/total, but done and failed accumulate across replans while total is the current plan's size, so the numerator could exceed the denominator once a replan reissued work. Switched to 'op N / T' using the executor's live op index and current-plan total - always in range and reflects 'where are we in the plan that's actually running.'",
            "Move list and per-op status markers now realign after a replan. Previously the UI kept rendering the original plan's rows while the executor had moved on to a different post-replan plan, so row markers drifted onto the wrong moves and the counter referenced a plan that was no longer executing. SortExecutor now broadcasts the new plan via a 'planupdated' progress phase, and SortView swaps the cached plan, clears stale op markers, and rebuilds the move list to match what's actually running.",
        },
    }},

    -- v0.29.25
    {"0.29.25", "2026-04-24", {
        Fixed = {
            "Sort progress markers on each move row now render in WoW's default font. v0.29.23 used Unicode triangle/check/cross glyphs that FRIZQT__ doesn't ship, so users saw colored boxes instead. Replaced with colored ASCII: '>' (yellow) for the op currently in flight, '+' (green) for completed (including late-ACK reclassified), 'x' (red) for failed. Same colors, actual shapes.",
            "Per-op status markers now survive Sort tab rebuilds mid-sort. Previously, every successful move created a transaction log entry; the ledger rescan reacted by firing RefreshUI, which (for the Sort tab) full-rebuilt the tab and wiped all per-row widget refs. The top progress line recovered on the next event but the per-op markers on already-completed rows were lost forever. Fixed by persisting a '_sortOpStatus' table and a cached progress-text string that the Preview loop repaints into freshly-built widgets on every rebuild - so a rescan, a tab switch, or any other rebuild now preserves the full visual state.",
        },
    }},

    -- v0.29.24
    {"0.29.24", "2026-04-24", {
        Changed = {
            "Every sort now ends by tidying the overflow (stock) tab. A new Phase 4 in the planner reshapes the overflow tab into a deterministic contiguous layout starting at slot 1: stacks sorted by itemID, larger stacks first within a group, no gaps. Previously the overflow was a dumping ground - Phase 1B and Phase 3 only grouped *new* spills using adjacency, so any pre-existing scattered stacks or gaps stayed scattered. Repeat sorts are now idempotent (already-compact overflow -> zero compaction ops). Partial-stack merging (e.g. merging two half-stacks of Linen Cloth) is explicitly out of scope here - the planner has no max-stack-size knowledge; that's a follow-up.",
        },
    }},

    -- v0.29.23
    {"0.29.23", "2026-04-23", {
        Added = {
            "Live progress display in the Sort tab while a sort is executing. A running 'Executing - N/T (X done, Y failed, Z replans)' line updates at the top of the move list every time an op starts, completes, fails, or gets reclassified by the late-ACK path. Each move row also gets a status marker prefixed to it as it advances: > for the op currently in flight, [ok] for completed (including late-ACK success), [x] for failed. Sort execution is 100% local so these updates have no bandwidth cost - they're just direct SetText calls on widgets we already have references to.",
            "On sort completion, the progress line switches to 'Sort complete - N done, M failed, K replans. Rescanning...' immediately, then the tab refreshes with the post-sort plan once the rescan lands. No more waiting on the scan to see whether the sort succeeded.",
        },
    }},

    -- v0.29.22
    {"0.29.22", "2026-04-23", {
        Fixed = {
            "Late server ACKs for move ops are now reclassified correctly even when the next op is already in flight. v0.29.19 added the grace window but only fired it when no op was waiting - in a live sort the 0.3s inter-move gap means an op is almost always armed, so the grace window essentially never fired. The handler now checks both 'is this a late ACK for a timed-out prior op' and 'does this advance the current in-flight op' as independent concerns. Expected effect: cleaner audit trails (fewer 'op N timed out / op N+1 pre-check fail' cascades) and more accurate done/failed counters after a sort completes.",
        },
        Changed = {
            "Removed the loud Capture-button diagnostics added in v0.29.21 now that the reported regression wasn't reproducible (it cleared on /reload). Kept the pcall-wrapped error handler and the pinned-slot count in the success message - cheap, informative, won't spam chat.",
        },
    }},

    -- v0.29.21
    {"0.29.21", "2026-04-23", {
        Added = {
            "Diagnostic output on the Layout editor's Capture button. When clicked, the button now always prints at least one chat line - the initial click, the guard state (scan/slots/writable), and either a success or a wrapped-pcall error message. Added to chase down a reported regression where Capture on a freshly-switched-to-Display tab looked like it was doing nothing.",
            "Capture success message now reports both the distinct-item count and the pinned-slot count ('Captured tab 5: 34 distinct item(s), 66 slot(s) pinned') so you can tell at a glance whether slotOrder got populated from the scan.",
        },
    }},

    -- v0.29.20
    {"0.29.20", "2026-04-23", {
        Added = {
            "Timeout-time diagnostics in the sort executor. When an op times out, the audit trail now dumps a classification ([none] / [partial] / [complete] / [other]), the op's full details, and the observed live state of the source/destination slots and cursor. This distinguishes 'server dropped the request,' 'pickup worked but drop didn't,' and 'move completed but ACK was lost' cases without needing to re-run the sort.",
            "Pre-check failures on destination slot mismatches now also log the op's full context (src/dst tab+slot, itemID, count), making it legible in the audit trail why a replan was triggered and what op the planner scheduled there.",
        },
    }},

    -- v0.29.19
    {"0.29.19", "2026-04-23", {
        Fixed = {
            "Sort no longer aborts mid-run when the server takes slightly longer than 2s to confirm a move. The executor used to classify the (legitimate but late) GUILDBANKBAGSLOTS_CHANGED event as 'foreign activity' and trigger a replan; the replan's fresh snapshot then saw the move already settled and the resulting plan sometimes pre-check-failed on op 1, cascading through all 5 replan retries before aborting. Now: if a recent op timed out and its destination slot is now populated as expected, the late event retroactively reclassifies the op as success and execution continues.",
            "Raised MOVE_CONFIRM_TIMEOUT from 2s to 4s to give high-latency realms more headroom before a legitimate server ACK is misclassified as a timeout. Happy-path sorts are unchanged (fast ACKs advance immediately); this only affects slow ACKs that would otherwise stall the run.",
            "Raised SCAN_WAIT_TIMEOUT from 5s to 10s. Full-bank scans on populated 7+ tab banks were observed taking ~4s in-game - uncomfortably close to the old 5s cap - and a single slow scan during a replan was enough to abort an otherwise-recoverable sort.",
        },
    }},

    -- v0.29.18
    {"0.29.18", "2026-04-23", {
        Added = {
            "'Unpin all slots' button on each display tab in the Layout editor. Wipes slotOrder (keeps items). Use when a captured layout is forcing new restock stacks to scatter to the end of the tab - after unpinning, the planner packs everything by adjacency at sort time.",
            "Per-item 'Unpin' button on every item row. Clears pinned slots for just that item while the rest of the tab stays pinned. Useful for 'mostly frozen, except this one high-churn item' setups. Disabled when the item has no pinned slots.",
            "Each item row now shows a pin count ('3 pinned' in yellow, or 'not pinned' in gray) between the = total and the action buttons, so you can see at a glance which items are fixed to positions and which aren't.",
            "Three modes now legible in the editor: Fully pinned (Capture everything, positions locked), Fully declarative (no pins, planner places at sort time), or Mixed (pin some, let others flow). Pick the mode that matches how much you care about exact placement vs. tolerating reorganization.",
        },
    }},

    -- v0.29.17
    {"0.29.17", "2026-04-23", {
        Added = {
            "Demand origin tracking in the sort planner. Each demand is tagged 'pinned' (from Capture), 'extend-right' / 'extend-left' (planner adjacency), or 'first-empty' (fallback when no adjacency is possible). The gem-tab restock pattern - pinned captures forcing new stacks to scatter - is now visible in diagnostics as a high first-empty count alongside many pinned demands.",
            "/gbl sortpreview now breaks down each display tab's demands by origin (pinned / auto-placed / extend-right / extend-left / first-empty) and annotates each planned move line with its destination origin so you can trace why each move lands where it lands.",
            "Layout editor slot map header now shows 'N pinned + M auto-placed; K empty' instead of just 'N/98 pinned.' The per-item 'auto-placed at sort time' list distinguishes all-new items from mixed ones ('1 pinned + 3 auto-placed') - the second form is the gem-tab pattern where Capture locked in old stacks and a later Slots bump added new ones.",
        },
    }},

    -- v0.29.16
    {"0.29.16", "2026-04-23", {
        Fixed = {
            "Layout tab edits no longer show a visible scroll-snap flicker. v0.29.15 preserved scroll position across rebuilds, but the Release -> Build -> SetScroll sequence was still visible as a brief blank-then-snap. The TabGroup's content frame is now hidden for the duration of the rebuild and revealed after scroll has been re-applied, so the tab appears static during edits.",
        },
    }},

    -- v0.29.15
    {"0.29.15", "2026-04-23", {
        Fixed = {
            "Layout tab no longer scrolls to the top every time you press Enter in an edit field. The tab rebuilds on every field change (to keep the slot budget, save/discard buttons, and slot map in sync), and that rebuild was also re-creating the ScrollFrame - throwing away scroll position. Editing Slots or Per slot halfway down the page used to jump you back to the top; the ScrollFrame now persists its scroll offset across rebuilds and snaps back to where you were.",
        },
    }},

    -- v0.29.14
    {"0.29.14", "2026-04-23", {
        Added = {
            "Slot map panel in the Layout editor. Every display tab now shows its slotOrder as a compact run-length list (e.g. 'S1-S23 (23): Silvermoon Health Potion x 20') right under the item rows. A 1-slot run wedged between two long runs of the same other item now stands out visually - which is exactly what the v0.29.12 hidden-swap incident needed.",
            "Slot map compares against the current bank scan when one is available: green [ok] if every slot in the run matches, red [x] with per-slot detail lines naming what's actually sitting there otherwise. Items whose Slots count exceeds their pinned slotOrder entries list below as 'auto-placed at sort time,' matching the v0.29.13 ownership split (Capture pins, planner places everything else at sort time).",
        },
    }},

    -- v0.29.13
    {"0.29.13", "2026-04-23", {
        Changed = {
            "Layout editor no longer pre-pins slotOrder positions for Add Item or Slots-up. The UI used to heuristically pin positions on edit - indistinguishable from a real Capture - which the planner then rigidly enforced. Same adjacency logic now runs at plan time instead, so slotOrder unambiguously means 'pin because observed,' saved layouts are smaller, and the post-sort bank state is byte-identical to before. Capture, Slots-down trim, and Remove cleanup are unchanged.",
        },
        Fixed = {
            "Adding an item to a full captured tab no longer leaves partial slotOrder state. Previously items[id].slots would be set but only some of the requested slots got slotOrder entries when the tab was nearly full; the over-budget error surfaced only at save time. With the prefill gone, the authoritative items[].slots sum is what validation checks - single clean failure mode.",
        },
    }},

    -- v0.29.12
    {"0.29.12", "2026-04-23", {
        Added = {
            "/gbl deviations (alias /gbl devs) compares the current bank to the layout's expected demand map and prints every slot that doesn't match - wrong item, wrong count, empty-where-expected, or extras in unclaimed slots.",
            "Auto-run deviation check after Execute. The Sort tab already rescans after Execute (v0.29.9); it now also prints the deviation report when the fresh scan lands, so any mismatch between plan and result is immediately visible.",
            "Pre-check failure audit entries now include the observed state (e.g. 'expected it:12345 x>=20, got it:99999 x10') instead of a bare 'src mismatch' message - makes it obvious whether the failure was foreign activity, a stack-size drift, or a planner bug.",
        },
    }},

    -- v0.29.11
    {"0.29.11", "2026-04-23", {
        Fixed = {
            "Sort now keeps each item's span contiguous in the display tab. When items[id].slots exceeded the captured slotOrder entries, the planner used to fill first unclaimed slot and could drop items into another item's section depending on itemID ordering. It now extends an item's group RIGHT first, then LEFT, only falling back to arbitrary slots when both ends are blocked.",
            "Overflow (stock) tab stays organized by item. Spills used to land in the first empty slot regardless of what was next to it; they now prefer slots adjacent to existing same-item stacks.",
            "Layout editor's Add Item and Slots field use the same adjacency rule so saved layouts stay neat without a recapture.",
        },
    }},

    -- v0.29.10
    {"0.29.10", "2026-04-23", {
        Fixed = {
            "First bank scan after login no longer misses every item. The scanner was reading slots immediately after requesting tab data, but on first open the client has no data yet - 98 nil slots, event unregistered, real data ignored when it arrived. The scanner now waits for the server's response event before scanning, with a 3-second timeout fallback for empty tabs that don't fire the event.",
        },
    }},

    -- v0.29.9
    {"0.29.9", "2026-04-23", {
        Fixed = {
            "Sort tab now auto-refreshes after Execute. Preview was re-running against the pre-sort snapshot (stale), so the plan looked unchanged after sort had actually run. The tab now triggers a rescan on completion, shows a 'Rescanning...' placeholder, then re-previews against the post-sort state.",
        },
    }},

    -- v0.29.8
    {"0.29.8", "2026-04-23", {
        Fixed = {
            "Sort planner now honors items[id].slots as the authoritative demand count. Before, if you captured a layout with 3 slots of an item then edited Slots to 5 in the Layout UI, the 2 extra slots were silently dropped and sort saw 'no discrepancy' even when the bank was obviously off. The planner now emits demands up to items[id].slots, adding extras at the first unclaimed slot indices.",
            "Layout editor's Slots input now syncs slotOrder on edit so the mismatch above can't reappear. Increasing Slots pins new positions at the first unclaimed indices; decreasing Slots trims from the highest slot index down.",
            "Phase 3 sweep no longer mis-evicts items placed by dynamically-added demands (was a consequence of the above fix - discovered via the regression tests).",
        },
        Added = {
            "/gbl sortpreview now prints a diagnostic breakdown: per-display-tab demand counts, overflow/ignore tab indices, scan contents by tab, and a plain-English reason when the plan is empty. Tells you whether a 0-op result is a config issue (no demands) or the bank genuinely matches the layout.",
        },
    }},

    -- v0.29.7
    {"0.29.7", "2026-04-23", {
        Changed = {
            "Sort planner rewritten from three-pass greedy to assign-then-schedule. Same inputs and outputs - drop-in upgrade. Items in the wrong slot of the right tab now move directly instead of round-tripping through overflow; oversize stacks feed multiple demands from a single source; the planner picks the largest source first to minimize split count; and swap cycles are detected and resolved with a pivot (3 ops for a 2-cycle, 4 for a 3-cycle, down from 4 and 6).",
            "Unreachable swap cycles (no empty unclaimed slot anywhere) are now reported as unplaced with a 'cycle-no-pivot' reason instead of emitting half-broken ops.",
        },
    }, milestone = "M-sort-2.5: Planner algorithm upgrade"},

    -- v0.29.6
    {"0.29.6", "2026-04-23", {
        Changed = {
            "Layout tab save-bar is now self-explanatory: status banner reads 'You have unsaved changes' vs 'Layout is up to date', the save button is disabled and labels itself 'Saved [ok]' when clean, and 'Revert' was renamed to 'Discard changes'. Edits still buffer until Save (deliberate, so validation and sync run once per logical change), just with clearer signals.",
        },
    }},

    -- v0.29.5
    {"0.29.5", "2026-04-23", {
        Fixed = {
            "Capture current layout now auto-triggers a scan when none exists, polls for completion, and gives clear success/failure feedback. Previously it silently failed when no scan had been performed yet.",
        },
    }},

    -- v0.29.4
    {"0.29.4", "2026-04-23", {
        Fixed = {
            "Layout tab dropdowns (mode + per-item Slots/Per-slot) now accept edits. The draft state was being wiped on every refresh, so changes applied then immediately reverted.",
            "Sort Access rank dropdown now shows all options including 'None (GM only)' as the default. It was previously rendering blank entries due to an array-vs-hash mismatch in the AceGUI dropdown call.",
        },
    }},

    -- v0.29.3
    {"0.29.3", "2026-04-23", {
        Added = {
            "Layout tab - per-tab mode picker (display/overflow/ignore), item template rows with Slots + Per-slot inputs, live slot-budget readout, Capture-current-layout button, and Add-item input that takes an itemID or a pasted item link.",
            "Sort tab - Preview builds and displays the planned moves with human-readable item names, deficits, and unplaced items. Execute runs the plan through SortExecutor with progress prints. Cancel aborts.",
            "Sort Access section (on the Layout tab) - GM sets a rank threshold and named delegates. Non-GMs see the policy read-only. Layout tab visibility itself now depends on sort access.",
        },
    }, milestone = "M-sort-2 (UI): Layout editor + Sort tab"},

    -- v0.29.2
    {"0.29.2", "2026-04-23", {
        Added = {
            "SortAccess policy - GM configures a rank threshold and named delegates to control who can edit layouts and execute sort. Default is GM-only; policy writes are GM-only so delegates can't self-escalate.",
            "SortExecutor - executes plans one op at a time with throttling, pre-step verification against live bank, replan-on-foreign-activity (cap 5), bank-close abort, and cursor-leak safety on every exit path.",
            "Slash commands: /gbl sortexec (run the current plan) and /gbl sortcancel (cancel a running sort), both gated by HasSortAccess.",
        },
    }, milestone = "M-sort-2 (backbone): Executor + Access policy"},

    -- v0.29.1
    {"0.29.1", "2026-04-23", {
        Added = {
            "CLAUDE.md architecture list now includes BankLayout and SortPlanner.",
            "Four sort-planner regression tests: ignore-tab invisibility, keep-slot protection, multi-tab orphan routing, and no-duplicate-unplaced under overflow saturation.",
        },
        Fixed = {
            "SortPlanner no longer produces duplicate unplaced entries when the overflow tab is full - Pass 1 now drops the working-bank copy of any slot it records as unplaced so later passes don't re-process it.",
        },
    }, milestone = "M-sort-1.1: Audit cleanup"},

    -- v0.29.0
    {"0.29.0", "2026-04-23", {
        Added = {
            "Bank layout model: per-guild saved templates that describe each tab's role (display, overflow, or ignore). Display tabs list the items they hold along with how many slots each occupies and the target stack size per slot. Includes a Capture tool that reads the current contents of a hand-arranged tab and saves it as the canonical layout.",
            "Sort planner: given a bank scan and a saved layout, produces an ordered list of moves that will reshape the bank to match - splitting oversize stacks, pulling from other display tabs or the overflow tab to fill deficits, and routing unassigned items to overflow. Pure function, fully tested. No execution or UI yet; those arrive in subsequent milestones.",
            "Debug: /gbl sortpreview prints the current sort plan to chat.",
        },
    }, milestone = "M-sort-1: Bank sorting foundation"},

    -- v0.28.12
    {"0.28.12", "2026-04-24", {
        Added = {
            "GitHub Actions CI workflow runs busted tests and luacheck on every pull request and on every push to main. Phase C will require passing CI before merge.",
        },
    }},

    -- v0.28.11
    {"0.28.11", "2026-04-24", {
        Added = {
            "Contributor docs: CONTRIBUTING.md, PR template, CODEOWNERS, and a README \"Contributing\" section. Aimed at external contributors but also documents internal conventions.",
        },
    }},

    -- v0.28.10
    {"0.28.10", "2026-04-24", {
        Fixed = {
            "Removed blank space at the bottom of all six tabs (Transactions, Gold Log, Consumption, Sync, Changelog, About). Thanks @katogaming88 for spotting and fixing the first three in #1.",
        },
    }},

    -- v0.28.9
    {"0.28.9", "2026-04-24", {
        Added = {
            "LuaLS workspace config so contributors get consistent IDE diagnostics out of the box.",
            "Internal design doc preserving the v0.26.0 throughput audit that justifies the 6h fingerprint bucket size.",
        },
        Changed = {
            "CurseForge listing copy refreshed (Beta tag, reorganized sections). No code change.",
        },
        Fixed = {
            ".gitignore now excludes .claude/walkthrough/ and .claude/settings.local.json so machine-local Claude Code state stops appearing in git status.",
        },
    }},

    -- v0.28.8
    {"0.28.8", "2026-04-23", {
        Added = {
            "Receiver-side redundancy metric in sync audit. New "
                .. "\"Redundancy from <peer>\" line reports total dupes/received "
                .. "with item-vs-money split; per-chunk audit gains a running "
                .. "\"X% dup\" annotation. Diagnostics-only - no protocol or "
                .. "behavior change. Informs whether bucket-granularity "
                .. "redundancy justifies a future manifest-exchange protocol change.",
        },
    }},

    -- v0.28.7
    {"0.28.7", "2026-04-22", {
        Fixed = {
            "Sync reliability: chunks shrunk to 1 AceComm wire fragment (4 records / 900 byte budget) after v0.28.6's 2-fragment target missed - actual compression ratio is 23-26%, not ~18% as assumed. Cross-realm syncs now complete instead of aborting mid-stream.",
        },
        Added = {
            "Diagnostics: retry cause tagging (ackTimeout/nack split out from combat/zone/busy/offline aborts), corrected p_frag math, per-peer outcome lines, and end-of-sync compression-ratio summary (min/med/max) so A/B analysis across chunk-size changes is now one-line rather than multi-line parse.",
        },
    }},
    -- v0.28.6
    {"0.28.6", "2026-04-22", {
        Fixed = {
            "Sync reliability: chunks shrunk to 2 AceComm wire fragments (10 records / 2500 byte budget) so cross-realm whisper delivery succeeds within 6 retries",
        },
    }},
    -- v0.28.5
    {"0.28.5", "2026-04-22", {
        Fixed = {
            "Sync reliability: 1.0s inter-chunk gap floor avoids WoW's server-side whisper throttle that was silently dropping the 3rd rapid-succession message",
            "Chunk density reverted to v0.27.0 values (25 records / 3200 byte budget) to reduce fragment count per chunk",
        },
    }},
    -- v0.28.4
    {"0.28.4", "2026-04-22", {
        Added = {
            "Sync diagnostics: CTL queue depth, inter-chunk gap, wire-to-ACK latency, enriched ACK-timeout context, and per-sync retry histogram with p_frag_est",
        },
    }},
    -- v0.28.3
    {"0.28.3", "2026-04-21", {
        Changed = {
            "Interface version updated to 120005 (WoW 12.0.5)",
        },
    }},
    -- v0.28.2
    {"0.28.2", "2026-04-21", {
        Fixed = {
            "Sync send pacing: dynamic CTL threshold based on chunk size eliminates burst-stall pattern",
            "HELLO replies suppressed during active sync to preserve CTL bandwidth for data transfer",
            "CTL backoff delay increased to 1.0s for efficient polling during bandwidth recovery",
        },
    }},
    -- v0.28.1
    {"0.28.1", "2026-04-20", {
        Added = {
            "Sync diagnostic logging: CTL.avail values, deferral counters with GetTime() precision, transmit callback timing, HELLO reply during-sync tags, NACK CTL state, per-sync summary stats",
        },
        Changed = {
            "Audit trail cap increased from 200 to 2000 entries to capture full sync lifecycle",
            "CTL deferral entries rate-limited: first 10 verbose, then every 20th - prevents audit eviction",
        },
    }},
    -- v0.28.0
    {"0.28.0", "2026-04-19", {
        Changed = {
            "Sync throughput optimized: broadcasts suppressed during active sync with keepalive every ~280s, CTL backoff reduced to 0.25s, bandwidth threshold lowered to 200",
            "Chunk density increased: byte budget 3200->5000, record cap 25->35, reducing chunk count by ~36% for large syncs",
        },
    }},
    -- v0.27.0
    {"0.27.0", "2026-04-19", {
        Fixed = {
            "Records with Unix epoch 0 timestamps repaired - multiple 'or 0' fallbacks replaced with validated timestamps",
            "Schema migration 7->8 repairs existing epoch-0 records and cleans up bogus 1970-01-01 compacted summaries",
        },
        Added = {
            "\"Open Sync Log\" button in Sync tab for quick access to the copy-pastable sync log",
            "Bottleneck diagnostics in audit trail: per-chunk RTT, CTL bandwidth backoff, compression ratio, pending peer queue time",
            "IsValidTimestamp validation helper prevents future epoch-0 writes at all storage boundaries",
        },
        Changed = {
            "Sync logging unified into single AddAuditEntry system - SyncLog function removed; chat and audit trail now report identical information",
        },
    }},
    -- v0.26.0
    {"0.26.0", "2026-04-17", {
        Added = {
            "Sync aborts immediately when entering combat and notifies partner via BUSY - no more 95-second NACK timeout stalls during M+ or raid",
            "Separate 2-second combat cooldown prevents sync from resuming during rapid trash-pack combat cycling",
            "HandleBusy now also aborts sending when the send target reports busy",
            "Sync status UI shows \"Paused (combat)\" when combat pause is active",
        },
    }},
    -- v0.25.5
    {"0.25.5", "2026-04-17", {
        Fixed = {
            "Periodic rescan no longer double-stores records that arrived via sync - session caches are invalidated after each sync chunk",
        },
    }},
    -- v0.25.4
    {"0.25.4", "2026-04-17", {
        Fixed = {
            "Sync no longer requests data from peers with fewer records - avoids receiving duplicate chunks that waste bandwidth",
            "Bidirectional check after sending skips reverse-requesting from peers with fewer records",
        },
    }},
    -- v0.25.3
    {"0.25.3", "2026-04-17", {
        Fixed = {
            "Sync receiving state no longer gets permanently stuck when a sync request goes unanswered - properly retries with backoff and aborts after 3 attempts",
            "BUSY response from a peer now clears receiving state even with partial data received, preventing stuck sync",
            "Added 30-minute safety net to auto-abort any stuck receive session",
        },
    }},
    -- v0.25.2
    {"0.25.2", "2026-04-16", {
        Fixed = {
            "Sync whispers to offline players no longer generate \"No player named\" system errors in chat",
            "In-progress sync aborts cleanly when target peer goes offline instead of hanging",
        },
    }},
    -- v0.25.1
    {"0.25.1", "2026-04-16", {
        Fixed = {
            "Online peers list showed peers for up to 5 minutes after disconnect - roster is now cross-checked for recently-seen peers",
        },
    }},
    -- v0.25.0
    {"0.25.0", "2026-04-16", {
        Added = {
            "Epidemic gossip sync - data propagates exponentially across guild; each peer becomes a seed after receiving",
            "Concurrent send + receive - send to one peer while receiving from another simultaneously",
            "Smart peer selection - priority scoring replaces FIFO queue (most divergent peers sync first)",
            "GUILD manifest broadcast - bucket hashes broadcast every 5 min for state discovery",
            "Hash-gated HELLO reply suppression - near-zero WHISPER traffic in large guilds",
            "Forced HELLO rate limiting - prevents broadcast storms during rapid propagation",
        },
        Changed = {
            "Bidirectional check delay: 3s -> 0.5s",
            "Post-receive HELLO delay: 2s -> 0.5-2s with jitter",
            "Pending peers processing delay: 1s -> 0.2s",
            "Sync initiation jitter: 0-2s -> 0-1s",
        },
    }},
    -- v0.24.0
    {"0.24.0", "2026-04-15", {
        Added = {
            "\"Show minimap button\" toggle - hide the minimap icon while keeping the LDB launcher for display addons (requested by Rox)",
        },
    }},
    -- v0.23.0
    {"0.23.0", "2026-04-15", {
        Changed = {
            "Sync chunk budget doubled and record cap raised (15->25) - halves chunk count for faster syncs",
            "ACK timeout reduced from 15s to 8s with more retries (3->5) - faster recovery from message loss",
            "ACK and NACK messages now sent with ALERT priority for faster delivery",
        },
        Fixed = {
            "Stale ACKs from retried chunks no longer orphan active timers (could cause 120s stalls)",
        },
    }},
    -- v0.22.4
    {"0.22.4", "2026-04-15", {
        Added = {
            "Peers in M+ or raids stay visible via guild roster fallback",
            "Known peers persisted across sessions for instant discovery on login",
        },
    }},
    -- v0.22.3
    {"0.22.3", "2026-04-15", {
        Fixed = {
            "Sync status now shows both Sending and Receiving when active simultaneously",
            "Receive progress shows waiting instead of 0/0 while awaiting first chunk",
        },
    }},
    -- v0.22.2
    {"0.22.2", "2026-04-15", {
        Fixed = {
            "Pending peers queue no longer requests sync from peers detected as offline",
            "FinishReceiving now removes the sender from the pending queue to prevent immediate re-request",
        },
    }},
    -- v0.22.1
    {"0.22.1", "2026-04-15", {
        Fixed = {
            "Automatic duplicate cleanup now runs after bank scan refreshes eventCounts",
        },
    }},
    -- v0.22.0
    {"0.22.0", "2026-04-15", {
        Added = {
            "BUSY message: declined sync requests now respond immediately instead of 60s dead air",
            "Pending peers queue: missed sync opportunities automatically retried after current sync",
            "Post-sync HELLO broadcast to trigger reciprocal sync",
            "Bidirectional sync: checks if peer has data we need after sending",
            "Combat guard: sync deferred during combat, resumes after",
            "Sync jitter: 0-2s random delay prevents mutual request collisions",
            "Sender offline detection: aborts early if sender disconnects mid-sync",
            "NACK backoff: progressive timeouts (20s, 30s, 45s) for retries",
        },
        Changed = {
            "First-chunk timeout reduced from 20s to 10s for faster failure detection",
        },
    }},
    -- v0.21.0
    {"0.21.0", "2026-04-14", {
        Added = {
            "About tab with addon info, Ko-fi donation link, CurseForge link, and credits",
            "GitHub Sponsors integration and README support section",
        },
    }},
    -- v0.20.1
    {"0.20.1", "2026-04-14", {
        Changed = {
            "Roadmap: moved Export feature to post-1.0; Stabilization is now the next milestone",
        },
    }},
    -- v0.20.0
    {"0.20.0", "2026-04-14", {
        Changed = {
            "Documentation sync for beta preparation: README, ROADMAP, CurseForge description updated",
        },
        Fixed = {
            "Changelog tab showing blank content - nav bar moved inside scroll frame",
        },
        Removed = {
            "Obsolete planning docs (IMPLEMENTATION_PLAN.md, PLAN.md) deleted",
        },
    }},
    -- v0.19.3
    {"0.19.3", "2026-04-14", {
        Changed = {
            "Sync and Changelog tabs right-aligned in tab bar to separate from data tabs",
        },
    }},
    -- v0.19.2
    {"0.19.2", "2026-04-14", {
        Changed = {
            "Changelog tab now paginates (10 versions per page) for faster loading",
            "Previous/Next navigation with accessible disabled-state labels",
        },
    }},
    -- v0.19.1
    {"0.19.1", "2026-04-14", {
        Fixed = {
            "Sync chunk 1 no longer oversized - eventCounts spread across chunks",
        },
    }},
    -- v0.19.0
    {"0.19.0", "2026-04-14", {
        Changed = {
            "Consumption tab redesigned as guild-wide overview dashboard",
            "Three sections: Guild Totals, Top Consumers (top 10), Most Used Items (top 15)",
            "Most Used Items shows withdrawal counts with 7d/30d/all-time trend columns",
            "Top Consumers shows full gold in/out/net breakdown per player",
            "Click player name in Top Consumers to jump to Transactions tab filtered by that player",
        },
        Removed = {
            "Collapsible player rows replaced by flat ranked tables",
        },
    }},
    -- v0.18.1
    {"0.18.1", "2026-04-14", {
        Fixed = {
            "Changelog tab now displays full content instead of truncating with '...'",
        },
    }},
    -- v0.18.0
    {"0.18.0", "2026-04-14", {
        Added = {
            "Directional peer version status - shows who needs to update",
            "Version label in top-right corner with peer-based update detection",
            "CompareSemver utility and GetHighestPeerVersion getter",
        },
    }},
    -- v0.17.0
    {"0.17.0", "2026-04-14", {
        Added = {
            "Event count metadata - persists API-observed counts for accurate dedup",
            "Count-based cleanup replaces heuristic anchor logic",
            "Post-sync cleanup trims diverged-index duplicates automatically",
            "eventCounts synced between peers (max wins, backwards-compatible)",
        },
        Fixed = {"Genuine synced records no longer deleted by cleanup"},
    }},
    -- v0.16.0
    {"0.16.0", "2026-04-14", {
        Added = {"Changelog tab in addon UI - scrollable version history"},
    }},
    -- v0.15.x
    {"0.15.2", "2026-04-14", {
        Fixed = {"Sync re-introducing duplicates after cleanup"},
        Added = {"DeduplicateRecords function for startup dedup"},
    }},
    {"0.15.1", "2026-04-13", {
        Fixed = {"ItemCache error on uncached items (wrong API for numeric itemID)"},
    }},
    {"0.15.0", "2026-04-13", {
        Added = {
            "GM-configurable access control system",
            "Access control sync via HELLO protocol",
        },
        Changed = {
            "Settings visible to all full-access users",
            "Tab list rebuilds dynamically on access changes",
        },
        Fixed = {"Migration now runs full dedup cleanup"},
        Removed = {"IsOfficerRank() replaced by access control"},
    }},
    -- v0.14.x
    {"0.14.3", "2026-04-13", {
        Fixed = {
            "Duplicate records from seenTxHashes gaps after sync",
            "Duplicate records from split adjacent slots",
            "Occurrence ID collision after normalization",
        },
    }},
    {"0.14.2", "2026-04-13", {
        Fixed = {"Existing duplicate records removed on upgrade"},
        Added = {"/gbl cleanup command"},
    }},
    {"0.14.1", "2026-04-13", {
        Fixed = {"Within-slot duplicate records on rescan"},
    }},
    {"0.14.0", "2026-04-13", {
        Fixed = {"Duplicate records from occurrence index shift"},
        Changed = {"Per-slot occurrence reindexing, sync protocol v4"},
    }},
    -- v0.13.x
    {"0.13.2", "2026-04-13", {
        Fixed = {"Player name consolidation failure at login"},
    }},
    {"0.13.1", "2026-04-13", {
        Fixed = {"Outdated peers now visible in Online Peers"},
    }},
    {"0.13.0", "2026-04-13", {
        Added = {
            "Item name resolution for synced records",
            "Guild roster cache for cross-realm tracking",
        },
        Changed = {
            "Player names always stored as Name-Realm",
            "Sync restricted to exact version match",
        },
        Fixed = {
            "Sync chunk count off-by-one",
            "Consumption view player fragmentation",
        },
    }},
    -- v0.12.x
    {"0.12.2", "2026-04-12", {
        Fixed = {"Corrupted sync records from serialization"},
    }},
    {"0.12.1", "2026-04-12", {
        Added = {"Chat Log toggle on Sync tab"},
    }},
    {"0.12.0", "2026-04-12", {
        Fixed = {"Cross-client false positives for adjacent-hour events"},
        Added = {"Occurrence scheme migration (v1 to v2)"},
    }},
    -- v0.11.x
    {"0.11.3", "2026-04-12", {
        Added = {"20 regression tests for sync convergence"},
    }},
    {"0.11.2", "2026-04-12", {
        Fixed = {"Bucket hashes mismatching after ID normalization"},
    }},
    {"0.11.1", "2026-04-12", {
        Fixed = {
            "Sync looping after normalization (sender-wins)",
            "Bucket hash mismatch from timestamp divergence",
        },
    }},
    {"0.11.0", "2026-04-12", {
        Added = {
            "Sync ID normalization for convergence",
            "Compaction guard during sync receive",
        },
    }},
    -- v0.10.x
    {"0.10.2", "2026-04-12", {
        Fixed = {"Sync dedup false positives for consecutive-hour events"},
    }},
    {"0.10.1", "2026-04-12", {
        Fixed = {"Stale peers wiped while still online (added heartbeat)"},
    }},
    {"0.10.0", "2026-04-11", {
        Added = {"LibDeflate compression for sync messages"},
        Changed = {"Sync protocol version bumped to 2"},
    }},
    -- v0.9.x
    {"0.9.7", "2026-04-11", {
        Fixed = {"Stale peers in Online list (5-minute expiry)"},
    }},
    {"0.9.6", "2026-04-11", {
        Changed = {"Sync buckets use 6-hour windows instead of daily"},
    }},
    {"0.9.5", "2026-04-11", {
        Fixed = {"Audit trail flooding from chunk logging"},
    }},
    {"0.9.4", "2026-04-11", {
        Added = {"/gbl synclog command"},
    }},
    {"0.9.3", "2026-04-11", {
        Fixed = {
            "Peer discovery after reload",
            "Known-peer reply gate blocking rediscovery",
        },
        Changed = {"HELLO replies use targeted WHISPER"},
    }},
    {"0.9.2", "2026-04-11", {
        Changed = {"Verbose sync audit trail diagnostics"},
    }},
    {"0.9.1", "2026-04-11", {
        Fixed = {"Hash-mismatch sync gap between peers"},
        Changed = {"Hash comparison as primary sync trigger"},
    }},
    {"0.9.0", "2026-04-11", {
        Added = {
            "Receive-side NACK retry for sync",
            "Zone change protection during sync",
            "FPS-adaptive throttling",
        },
        Changed = {"Smaller sync chunks (15 to 5 records)"},
    }},
    -- v0.8.x
    {"0.8.0", "2026-04-11", {
        Added = {
            "Fingerprint-based sync (hash comparison)",
            "Bucket-filtered delta sync",
        },
    }},
    -- v0.7.x
    {"0.7.17", "2026-04-11", {
        Changed = {"Reverted inter-chunk delay to 100ms"},
    }},
    {"0.7.15", "2026-04-11", {
        Changed = {"Reduced chunk byte budget for reliability"},
    }},
    {"0.7.14", "2026-04-11", {
        Fixed = {"Crash syncing records with missing fields"},
    }},
    {"0.7.13", "2026-04-10", {
        Fixed = {"Cross-realm sync name format mismatch"},
    }},
    {"0.7.12", "2026-04-10", {
        Fixed = {"Sync chunks exceeding WHISPER size limit"},
    }},
    {"0.7.11", "2026-04-10", {
        Fixed = {"Sync request stalling permanently"},
    }},
    {"0.7.10", "2026-04-10", {
        Added = {"Chat output for sync events"},
    }},
    {"0.7.9", "2026-04-10", {
        Fixed = {"Crash syncing records without timestamp"},
    }},
    {"0.7.8", "2026-04-10", {
        Changed = {
            "Sync chunk size increased to 10",
            "Sync strips reconstructable fields",
        },
    }},
    {"0.7.7", "2026-04-10", {
        Fixed = {
            "Sync chunks too large for WHISPER",
            "Single dropped chunk now retries",
        },
    }},
    {"0.7.6", "2026-04-10", {
        Fixed = {
            "Sync timers never firing in WoW",
            "Manual Hello button cooldown bypass",
        },
    }},
    {"0.7.5", "2026-04-10", {
        Fixed = {"Peer discovery failure from cooldown"},
        Added = {"HELLO on guild bank open"},
    }},
    {"0.7.4", "2026-04-10", {
        Added = {
            "HELLO response for mutual peer discovery",
            "Version indicator in peer list",
        },
    }},
    {"0.7.3", "2026-04-10", {
        Fixed = {"Sync data rejected from name format mismatch"},
    }},
    {"0.7.2", "2026-04-10", {
        Fixed = {"Column text wrapping to new lines"},
    }},
    {"0.7.1", "2026-04-10", {
        Fixed = {
            "Sync ACK timeout starting too early",
            "Self-message filtering in retail WoW",
        },
        Changed = {"Chunk size reduced, ACK timeout increased"},
    }},
    {"0.7.0", "2026-04-08", {
        Added = {
            "Gold summary panel on Gold Log tab",
            "Date range filters (1h, 3h, 24h)",
            "Pagination for Transactions tab",
        },
        Fixed = {"Re-scan no longer resets filters"},
    }},
    -- v0.6.x
    {"0.6.2", "2026-04-07", {
        Fixed = {"Re-scan not detecting new transactions"},
    }},
    {"0.6.1", "2026-04-07", {
        Fixed = {"Periodic re-scan not functioning in-game"},
    }},
    {"0.6.0", "2026-04-07", {
        Added = {
            "Periodic re-scan while guild bank open",
            "Auto re-scan toggle",
        },
    }},
    -- v0.5.0
    {"0.5.0", "2026-04-07", {
        Added = {
            "Multi-officer sync via AceComm",
            "Sync tab with controls, peer list, audit trail",
            "ACK timeout and receive timeout",
            "HELLO broadcast on login and bank close",
        },
    }, "Milestone M5: Multi-Officer Sync"},
    -- v0.4.x
    {"0.4.1", "2026-04-07", {
        Fixed = {
            "Gold transactions in Transactions tab",
            "Money tab queried at correct index",
            "Type normalization (withdrawal to withdraw)",
        },
    }},
    {"0.4.0", "2026-04-07", {
        Added = {
            "Click-to-expand player rows in consumption",
            "Sortable consumption column headers",
            "Category filter on consumption tab",
        },
        Fixed = {"Guild bank open stutter (deferred scanning)"},
    }, "Milestone M4: Consumption Detail + UI Polish"},
    -- v0.3.x
    {"0.3.3", "2026-04-07", {
        Fixed = {"Sort direction indicators (UTF-8 to text)"},
    }},
    {"0.3.2", "2026-04-07", {
        Fixed = {
            "UI rows overflowed frame (added ScrollFrame)",
            "Interface version updated to 120001",
        },
    }},
    {"0.3.1", "2026-04-07", {
        Fixed = {"fetch-libs.sh repo URLs corrected"},
    }},
    {"0.3.0", "2026-04-07", {
        Added = {
            "Main UI window with tabs",
            "Transaction ledger with sortable columns",
            "Filter bar and consumption summary",
            "Minimap button",
            "Accessibility features (WCAG 2.1 AA)",
            "Keyboard navigation",
        },
    }, "Milestone M3: UI"},
    -- v0.2.x
    {"0.2.6", "2026-04-07", {
        Added = {"Keyboard navigation and focus handling"},
    }},
    {"0.2.5", "2026-04-07", {
        Added = {"Main UI window, filter widgets, minimap button"},
    }},
    {"0.2.4", "2026-04-07", {
        Added = {
            "Per-player consumption aggregation",
            "Money formatting utility",
        },
    }},
    {"0.2.3", "2026-04-07", {
        Added = {"Transaction filter logic"},
    }},
    {"0.2.2", "2026-04-06", {
        Added = {
            "Accessibility module (WCAG 2.1 AA)",
            "Colorblind-safe palettes",
            "Triple encoding for transaction types",
        },
    }},
    {"0.2.1", "2026-04-06", {
        Added = {"Library fetch script for development"},
    }},
    {"0.2.0", "2026-04-06", {
        Added = {
            "Transaction recording from guild bank logs",
            "Item categorization by classID/subclassID",
            "Hour-bucket deduplication",
            "Money transaction tracking",
            "Per-player statistics",
            "Tiered storage compaction",
        },
    }, "Milestone M2: Ledger + Dedup + Categories + Storage"},
    -- v0.1.0
    {"0.1.0", "2026-04-06", {
        Added = {
            "AceAddon bootstrap with lifecycle",
            "Guild bank open/close detection",
            "Slot-level guild bank scanning",
            "Slash commands and AceDB saved variables",
        },
    }, "Milestone M1: Scaffold + Scanner"},
}

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------

--- Format a single changelog version entry into a WoW-colored string.
-- @param entry table { version, date, sections, milestone? }
-- @return string Formatted string with WoW color codes and newlines
function GBL:FormatChangelogEntry(entry)
    local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]
    local lines = {}

    -- Version header
    lines[#lines + 1] = string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date)

    -- Milestone label
    if milestone then
        lines[#lines + 1] = "  |cffffcc00" .. milestone .. "|r"
    end

    -- Section entries in standard order
    for _, sType in ipairs(SECTION_ORDER) do
        local entries = sections[sType]
        if entries then
            local color = SECTION_COLORS[sType] or "|cffcccccc"
            lines[#lines + 1] = "  " .. color .. sType .. ":|r"
            for _, text in ipairs(entries) do
                lines[#lines + 1] = "    - " .. text
            end
        end
    end

    -- Trailing blank line for spacing
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the Changelog tab inside a container.
-- Paginates by version entry (CHANGELOG_PAGE_SIZE per page).
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildChangelogTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local data = self.CHANGELOG_DATA or {}
    local totalEntries = #data

    -- Pagination math
    self._changelogCurrentPage = self._changelogCurrentPage or 1
    local totalPages = math.max(1, math.ceil(totalEntries / CHANGELOG_PAGE_SIZE))
    local page = math.max(1, math.min(self._changelogCurrentPage, totalPages))
    self._changelogCurrentPage = page
    local startIdx = (page - 1) * CHANGELOG_PAGE_SIZE + 1
    local endIdx = math.min(startIdx + CHANGELOG_PAGE_SIZE - 1, totalEntries)

    -- Scrollable content (only direct child of container, so List layout
    -- gives it proper height — adding siblings before it breaks sizing).
    -- Pinned via the shared AddFillChild helper for resize-stable height.
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("List")
    self:AddFillChild(container, scroll)

    -- Navigation bar inside scroll (only when multiple pages)
    if totalPages > 1 then
        local navGroup = AceGUI:Create("SimpleGroup")
        navGroup:SetFullWidth(true)
        navGroup:SetLayout("Flow")
        scroll:AddChild(navGroup)

        -- Previous button
        local prevBtn = AceGUI:Create("Button")
        prevBtn:SetWidth(100)
        if page <= 1 then
            prevBtn:SetText("- Previous -")
            prevBtn:SetDisabled(true)
        else
            prevBtn:SetText("< Previous")
            prevBtn:SetDisabled(false)
        end
        prevBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page - 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(prevBtn)

        -- Page label
        local pageLabel = AceGUI:Create("Label")
        pageLabel:SetWidth(140)
        pageLabel:SetText(string.format("  Page %d of %d", page, totalPages))
        pageLabel:SetJustifyH("CENTER")
        local fontPath, fontSize = self:GetScaledFont()
        pageLabel:SetFont(fontPath, fontSize, "")
        navGroup:AddChild(pageLabel)

        -- Next button
        local nextBtn = AceGUI:Create("Button")
        nextBtn:SetWidth(100)
        if page >= totalPages then
            nextBtn:SetText("- Next -")
            nextBtn:SetDisabled(true)
        else
            nextBtn:SetText("Next >")
            nextBtn:SetDisabled(false)
        end
        nextBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page + 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(nextBtn)

        -- Register buttons for keyboard navigation
        self:ClearFocusOrder()
        self:RegisterFocusable(prevBtn, 1)
        self:RegisterFocusable(nextBtn, 2)
    end

    -- Render version entries for current page
    -- (AceGUI Labels are single-line; multi-line \n text gets truncated)
    for i = startIdx, endIdx do
        local entry = data[i]
        local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]

        -- Version header (larger font)
        local header = AceGUI:Create("Label")
        header:SetFullWidth(true)
        header:SetFontObject(GameFontNormalLarge)
        header:SetText(string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date))
        scroll:AddChild(header)

        -- Milestone label
        if milestone then
            local ml = AceGUI:Create("Label")
            ml:SetFullWidth(true)
            ml:SetText("  |cffffcc00" .. milestone .. "|r")
            scroll:AddChild(ml)
        end

        -- Section entries in standard order
        for _, sType in ipairs(SECTION_ORDER) do
            local entries = sections[sType]
            if entries then
                local color = SECTION_COLORS[sType] or "|cffcccccc"
                local sl = AceGUI:Create("Label")
                sl:SetFullWidth(true)
                sl:SetText("  " .. color .. sType .. ":|r")
                scroll:AddChild(sl)

                for _, text in ipairs(entries) do
                    local el = AceGUI:Create("Label")
                    el:SetFullWidth(true)
                    el:SetText("    - " .. text)
                    scroll:AddChild(el)
                end
            end
        end

        -- Spacer between entries
        local spacer = AceGUI:Create("Label")
        spacer:SetFullWidth(true)
        spacer:SetText(" ")
        scroll:AddChild(spacer)
    end
end
