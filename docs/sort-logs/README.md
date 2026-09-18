# Sort capture records

What a sort run actually did, read out of the game and written down. Every
sort run in game gets one of these (Russell, 2026-09-16). Several of the sort
fixes were built from one of these files, and one of them closed an issue on
its own: #144 was answered by the 2026-09-12 capture rather than by a build.

`docs/` is stripped from the packaged addon, so nothing here ships.

## Getting the lines out

The addon persists per-login sessions into `GuildBankLedgerAuditDB`, which
WoW saves inside the SavedVariables file:

```
<WoW>/_retail_/WTF/Account/<accountID>/SavedVariables/GuildBankLedger.lua
```

That is one file per addon, so the whole transaction ledger sits in it too.
Nothing in the addon renders a **saved** session: `/gbl sortlog` and
`/gbl logs` read the live in-memory ring, which a `/reload` empties. Reading
a past session means reading the file, and `scripts/audit-sessions.lua` does
that:

```bash
lua scripts/audit-sessions.lua "<path>/GuildBankLedger.lua"
lua scripts/audit-sessions.lua "<path>/GuildBankLedger.lua" --session 9 --md
```

With no options it lists the saved sessions with their versions, per-channel
counts and dropped counters. `--session N --md` prints the skeleton of a
record with the run lines already grouped, which is what you paste into a new
file here. `--session N --channel sync` prints one channel in full.

**Do this within a few loads of the run.** The store keeps ten sessions and a
`/reload` that logs anything consumes one, so a capture is about nine loads
from being overwritten. The 2026-09-12 record was written with two loads to
spare and only because somebody went looking.

**Sessions are addressed by index, never by line.** WoW serialises a table in
`pairs()` order, so a session's `dropped` block can sit above its own
`startedAt` and the lines below one session's entries belong to the next
session's header. Reading by line produced a wrong conclusion on 2026-09-08.
The script and its fixture both exist to make that impossible to repeat.

## Writing the record

Two shapes. Most runs get the **record**: what was run, the figures, and a
note for whoever reads the next one. A run that answers an open question gets
the **finding**, which adds what the evidence accounts for and what it does
not; `2026-09-12-pivot-convergence-clean.md` is the model.

Sections, in order:

- **`# YYYY-MM-DD: <claim>`**: the H1 is what the capture shows, not a label.
  "the pass-cap stop is gone, and the planner-side fixes account for it",
  not "sort capture".
- **A short preamble**: one or two sentences on what was run. Name the
  session index and say the lines were read by index.
- **`## What was run`**: a table with one column per run: started, bags
  on or off, planned ops, how it ended, and what the cursor probe answered.
  That last row is the one to read first on any run that moved less than it
  planned (#171).
- **`## The figures`**: the summary lines verbatim in fenced blocks, then a
  measure table. Count rather than eyeball: a first pass at the 09-12 record
  undercounted its own evidence six times over.
- **`## What this accounts for`**: one bullet per shipped fix the capture
  bears on, naming the issue and the version.
- **`## The limit worth stating`**: what the capture does not prove. An
  absence of recurrence is not the original fixture passing.
- **`## For the reader of the next capture`**: which terms to read first.

Three rules:

- **No guild, player or realm name.** The session header carries all three and
  a record names none of them. The skeleton generator leaves them out, and a
  spec holds it to that.
- **Quoted log lines stay verbatim**, arrows and all. The prose around them
  follows the repo's style, so it has no em dashes and no arrows.
- **A record is not its own pull request.** Commit it onto whatever branch is
  open. `docs/` is stripped from the package, so a record never affects a
  version stamp or a release. The labeler adds `area: sort` from
  `docs/sort-logs/**`, which will ride along onto a PR about something else;
  read the labels before merging, as always.

## The records

| File | What it shows |
|---|---|
| [2026-05-14-late-poll-storm.md](2026-05-14-late-poll-storm.md) | Two runs on v0.32.3. One aborted at the replan cap, one completed 64 of 64 once the late-poll floor was in. Carries the full raw log. |
| [2026-05-20-prewarm-success-late-poll-recurrence.md](2026-05-20-prewarm-success-late-poll-recurrence.md) | The crafted-quality pre-warm fix verified, and the 05-14 pattern reproducing six days later. |
| [2026-05-21-deposit-latency-coldtab.md](2026-05-21-deposit-latency-coldtab.md) | The deposit-latency distribution that the confirm-on-deposit work was built from. About 0.6s common, a tail past 20s on a cold tab. |
| [2026-05-21-split-confirmation-lag.md](2026-05-21-split-confirmation-lag.md) | Split deposits landing while the source drain lags. Overturns the cold-snapshot theory. |
| [2026-05-21-viewed-tab-confirmed.md](2026-05-21-viewed-tab-confirmed.md) | The cold tab pinned to the destination tab not being the viewed one. Opens by retracting its own proposed fix. |
| [2026-08-27-bags-near-full-overflow.md](2026-08-27-bags-near-full-overflow.md) | Bags into two nearly full overflow tabs on v0.39.0. The bag half worked; the pass-cap stop was something else. |
| [2026-09-12-pivot-convergence-clean.md](2026-09-12-pivot-convergence-clean.md) | Two runs on v0.39.3 converging in two passes. Closed #144 on evidence rather than a build. |
| [2026-09-17-cursor-predicate-outage-and-probe.md](2026-09-17-cursor-predicate-outage-and-probe.md) | The v0.39.5 outage and the v0.39.6 probe that explained it. 238 lifts that all worked show `CursorHasItem` blind to a guild bank cursor and source drain unreadable in the frame of the lift. |
